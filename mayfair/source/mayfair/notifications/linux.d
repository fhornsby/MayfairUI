module mayfair.notifications.linux;

/*
    Notifications on Linux and the BSDs, over D-Bus: to the freedesktop.org notification service
    (org.freedesktop.Notifications), which GNOME's shell, KDE's Plasma and every notification
    daemon provide, and which is how any desktop -- Oriel too -- can show them without knowing
    anything of the app; or, in a Flatpak, where an app can't reach that service, to the desktop
    portal's (org.freedesktop.portal.Notification), which passes them on. Nothing of GNOME's, and
    no GLib: libdbus, opened when the first notification's shown (see mayfair.notifications.dbus).

    The protocol is the portal's in a Flatpak and the service's everywhere else; MAYFAIR_NOTIFICATIONS
    =portal or =freedesktop says otherwise, to try one out.

    The bus is another process, and the UI thread mustn't wait on it, so a thread of the backend's
    own has the connection: show() and close() queue what's wanted and wake it, and it sends them
    and listens for what the user does, which it hands back to the notifications. It sleeps in
    poll() with nothing to do, so it costs nothing between notifications. As the program ends it's
    stopped, and the connection closed, before the runtime frees what the thread uses.

    What each protocol does that the other doesn't: the service says when a notification's gone,
    dismissed or timed out; the portal only says what was clicked, after which the desktop takes
    the notification away, so it's taken as gone then.
*/

version (Posix):

import core.sync.mutex : Mutex;
import core.thread : Thread;
import mayfair.log : logWarning;
import mayfair.notifications;
import mayfair.notifications.dbus;

// The backends whose bus threads are running, to be stopped as the program ends
__gshared DBusNotifications[] running;
__gshared Mutex runningLock;

shared static this() { runningLock = new Mutex; }

shared static ~this()
{
    DBusNotifications[] all;
    synchronized (runningLock)
        all = running;
    foreach (b; all)
        b.stop();
}

/// Which D-Bus service notifications go to.
enum Protocol
{
    freedesktop,    /// org.freedesktop.Notifications
    portal,         /// org.freedesktop.portal.Notification, for a sandboxed app
}

/// The protocol for this process: the portal's in a Flatpak, the service's otherwise.
Protocol chooseProtocol()
{
    import std.file : exists;
    import std.process : environment;
    switch (environment.get("MAYFAIR_NOTIFICATIONS", ""))
    {
        case "portal": return Protocol.portal;
        case "freedesktop": return Protocol.freedesktop;
        default: return exists("/.flatpak-info") ? Protocol.portal : Protocol.freedesktop;
    }
}

/// Notifications over D-Bus, from a thread of their own (see above).
final class DBusNotifications : NotificationBackend
{
    this(Protocol protocol = chooseProtocol())
    {
        this.protocol = protocol;
        lock = new Mutex;
    }

    void show(Notification n) { post(Request(true, n, n.content)); }
    void close(Notification n) { post(Request(false, n)); }

private:
    struct Request
    {
        bool show;              // or close
        Notification n;
        NotificationContent content;
    }

    Protocol protocol;
    Mutex lock;
    Request[] queue;        // what's to be sent, for the bus thread
    int[2] wake = [-1, -1]; // a pipe the bus thread polls, written to when there's something in the queue
    Thread thread;
    bool gone;              // the bus thread couldn't connect, or lost the bus: nothing more is sent
    bool stopping;          // the program's ending: the bus thread's to stop

    /*
        Stops the bus thread and waits for it, as the program ends. D doesn't stop a daemon thread
        at the end, but frees the memory it uses around it, so a thread woken then would touch
        what's gone: this is called first, from the module's destructor.
    */
    void stop()
    {
        import core.sys.posix.unistd : write;
        synchronized (lock)
        {
            if (!thread || gone)
                return;
            stopping = true;
        }
        ubyte one = 1;
        write(wake[1], &one, 1);
        thread.join(false);
    }

    void post(Request r)
    {
        import core.sys.posix.unistd : write;
        synchronized (lock)
        {
            if (gone)
                return;
            if (!thread && !start())
                return;
            queue ~= r;
        }
        ubyte one = 1;
        write(wake[1], &one, 1);
    }

    bool start()
    {
        import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;
        import core.sys.posix.unistd : pipe;
        if (pipe(wake) != 0)
        {
            gone = true;
            return false;
        }
        fcntl(wake[0], F_SETFL, O_NONBLOCK);
        fcntl(wake[1], F_SETFL, O_NONBLOCK);
        thread = new Thread(&run);
        thread.isDaemon = true; // it never ends on its own, and mustn't keep the program from ending
        thread.start();
        synchronized (runningLock)
            running ~= this;
        return true;
    }

    // ---- From here on, the bus thread's

    LibDBus d;
    DBusConnection* conn;
    uint[Notification] serverId;        // freedesktop: what's showing, and the service's id for it
    Notification[uint] byServerId;
    string[Notification] portalId;      // portal: what's showing, and the id it was given
    Notification[string] byPortalId;
    size_t nextPortalId;

    void run()
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN, POLLHUP, POLLERR;
        if (!connect())
        {
            synchronized (lock)
                gone = true;
            return;
        }
        int fd;
        d.fn.connection_get_unix_fd(conn, &fd);
        for (;;)
        {
            receive();
            pollfd[2] fds = [pollfd(fd, POLLIN), pollfd(wake[0], POLLIN)];
            const ready = poll(fds.ptr, 2, -1);
            synchronized (lock)
                if (stopping)
                    break;
            if (ready < 0)
                continue; // a signal interrupted it
            if (fds[0].revents & (POLLHUP | POLLERR))
            {
                logWarning("Lost the session bus: no more notifications");
                break;
            }
            if (fds[1].revents & POLLIN)
                sendQueued();
            if (!d.fn.connection_read_write(conn, 0))
            {
                logWarning("Lost the session bus: no more notifications");
                break;
            }
        }
        d.fn.connection_close(conn);
        d.fn.connection_unref(conn);
        conn = null;
        synchronized (lock)
            gone = true;
    }

    bool connect()
    {
        if (!d.open())
        {
            logWarning("No libdbus, so no notifications");
            return false;
        }
        DBusError err;
        d.fn.error_init(&err);
        conn = d.fn.bus_get_private(DBusBusType.session, &err);
        if (!conn)
        {
            warn("Couldn't connect to the session bus for notifications", err);
            return false;
        }
        d.fn.connection_set_exit_on_disconnect(conn, 0);
        const rule = protocol == Protocol.portal ? "type='signal',interface='org.freedesktop.portal.Notification'"
                                                 : "type='signal',interface='org.freedesktop.Notifications'";
        d.fn.bus_add_match(conn, rule.ptr, &err);
        if (d.fn.error_is_set(&err))
            warn("Couldn't listen for what's done with notifications", err);
        return true;
    }

    void sendQueued()
    {
        import core.sys.posix.unistd : read;
        ubyte[64] drained;
        while (read(wake[0], drained.ptr, drained.length) > 0) {}
        Request[] todo;
        synchronized (lock)
        {
            todo = queue;
            queue = null;
        }
        foreach (ref r; todo)
        {
            if (protocol == Protocol.portal)
                r.show ? portalShow(r.n, r.content) : portalClose(r.n);
            else
                r.show ? freedesktopShow(r.n, r.content) : freedesktopClose(r.n);
        }
    }

    // What the desktop's said: what was clicked, and what's gone
    void receive()
    {
        for (DBusMessage* m; (m = d.fn.connection_pop_message(conn)) !is null; d.fn.message_unref(m))
        {
            DBusError err;
            d.fn.error_init(&err);
            scope (exit) d.fn.error_free(&err);
            if (d.fn.message_is_signal(m, "org.freedesktop.Notifications", "ActionInvoked"))
            {
                uint id;
                const(char)* key;
                if (d.fn.message_get_args(m, &err, typeUint32, &id, typeString, &key, typeInvalid))
                    if (auto n = id in byServerId)
                        n.activated(actionIndex(copied(key)));
            }
            else if (d.fn.message_is_signal(m, "org.freedesktop.Notifications", "NotificationClosed"))
            {
                uint id, reason;
                if (d.fn.message_get_args(m, &err, typeUint32, &id, typeUint32, &reason, typeInvalid))
                    if (auto n = id in byServerId)
                    {
                        auto gone = *n;
                        forget(gone);
                        gone.dismissed();
                    }
            }
            else if (d.fn.message_is_signal(m, "org.freedesktop.portal.Notification", "ActionInvoked"))
            {
                const(char)* id, action;
                if (d.fn.message_get_args(m, &err, typeString, &id, typeString, &action, typeInvalid))
                    if (auto n = copied(id) in byPortalId)
                    {
                        auto clicked = *n;
                        clicked.activated(actionIndex(copied(action)));
                        forget(clicked); // the desktop takes it away once it's been clicked
                        clicked.dismissed();
                    }
            }
        }
    }

    void forget(Notification n)
    {
        if (auto id = n in serverId)
        {
            byServerId.remove(*id);
            serverId.remove(n);
        }
        if (auto id = n in portalId)
        {
            byPortalId.remove(*id);
            portalId.remove(n);
        }
    }

    // ---- org.freedesktop.Notifications

    void freedesktopShow(Notification n, ref const NotificationContent c)
    {
        string name, id;
        notifyingApp(name, id);
        const replaces = n in serverId ? serverId[n] : 0;
        auto reply = call("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                          "org.freedesktop.Notifications", "Notify", (Writer w) {
            w.str(name).u32(replaces).str(iconArgument(c.icon)).str(c.title).str(c.text)
             .strings(actionList(c))
             .array("{sv}", (Writer hints) {
                 hints.entry("urgency", "y", (Writer v) { v.byte_(urgencyByte(c.urgency)); });
                 if (id.length)
                     hints.entry("desktop-entry", "s", (Writer v) { v.str(id); });
             })
             .i32(-1); // the server's own timeout
        });
        if (!reply)
            return;
        scope (exit) d.fn.message_unref(reply);
        DBusError err;
        d.fn.error_init(&err);
        uint shown;
        if (!d.fn.message_get_args(reply, &err, typeUint32, &shown, typeInvalid))
        {
            warn("The notification service's answer couldn't be read", err);
            return;
        }
        forget(n);
        serverId[n] = shown;
        byServerId[shown] = n;
    }

    void freedesktopClose(Notification n)
    {
        auto id = n in serverId;
        if (!id)
            return;
        const which = *id;
        forget(n); // so the service's NotificationClosed doesn't run onClosed again: close() has
        send("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
             "CloseNotification", (Writer w) { w.u32(which); });
    }

    // ---- org.freedesktop.portal.Notification

    void portalShow(Notification n, ref const NotificationContent c)
    {
        import std.conv : to;
        string id;
        if (auto had = n in portalId)
            id = *had;
        else
            id = "mayfair-" ~ to!string(nextPortalId++);
        auto reply = call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                          "org.freedesktop.portal.Notification", "AddNotification", (Writer w) {
            w.str(id).array("{sv}", (Writer o) {
                o.entry("title", "s", (Writer v) { v.str(c.title); });
                if (c.text.length)
                    o.entry("body", "s", (Writer v) { v.str(c.text); });
                o.entry("priority", "s", (Writer v) { v.str(priority(c.urgency)); });
                if (c.icon.length)
                    portalIcon(o, c.icon);
                if (c.clickable)
                    o.entry("default-action", "s", (Writer v) { v.str("default"); });
                if (c.actions.length)
                    o.entry("buttons", "aa{sv}", (Writer v) {
                        v.array("a{sv}", (Writer buttons) {
                            foreach (i, label; c.actions)
                                buttons.array("{sv}", (Writer b) {
                                    b.entry("label", "s", (Writer l) { l.str(label); });
                                    b.entry("action", "s", (Writer a) { a.str(to!string(i)); });
                                });
                        });
                    });
            });
        });
        if (!reply)
            return;
        d.fn.message_unref(reply);
        forget(n);
        portalId[n] = id;
        byPortalId[id] = n;
    }

    void portalClose(Notification n)
    {
        auto id = n in portalId;
        if (!id)
            return;
        const which = *id;
        forget(n);
        send("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
             "org.freedesktop.portal.Notification", "RemoveNotification", (Writer w) { w.str(which); });
    }

    // A themed icon by its name, or a file's bytes, as the portal has them: a serialised GIcon
    void portalIcon(Writer o, string icon)
    {
        import std.algorithm : canFind;
        import std.file : read;
        if (!icon.canFind('/'))
        {
            o.entry("icon", "(sv)", (Writer v) {
                v.struct_((Writer s) { s.str("themed").variant("as", (Writer names) { names.strings([icon]); }); });
            });
            return;
        }
        const(ubyte)[] data;
        try
            data = cast(const(ubyte)[]) read(icon);
        catch (Exception)
            return; // no icon rather than no notification
        o.entry("icon", "(sv)", (Writer v) {
            v.struct_((Writer s) { s.str("bytes").variant("ay", (Writer b) { b.bytes(data); }); });
        });
    }

    // ---- Calls

    /// Calls `method`, its arguments appended by `args`, and waits for the reply: null if there was an error.
    DBusMessage* call(string service, string path, string iface, string method, scope void delegate(Writer) args)
    {
        auto m = message(service, path, iface, method, args);
        if (!m)
            return null;
        scope (exit) d.fn.message_unref(m);
        DBusError err;
        d.fn.error_init(&err);
        auto reply = d.fn.connection_send_with_reply_and_block(conn, m, 5000, &err);
        if (!reply)
            warn("A notification couldn't be shown", err);
        return reply;
    }

    /// The same, without waiting for a reply.
    void send(string service, string path, string iface, string method, scope void delegate(Writer) args)
    {
        auto m = message(service, path, iface, method, args);
        if (!m)
            return;
        d.fn.connection_send(conn, m, null);
        d.fn.connection_flush(conn);
        d.fn.message_unref(m);
    }

    DBusMessage* message(string service, string path, string iface, string method, scope void delegate(Writer) args)
    {
        import std.string : toStringz;
        auto m = d.fn.message_new_method_call(service.toStringz, path.toStringz, iface.toStringz, method.toStringz);
        if (!m)
            return null;
        DBusMessageIter it;
        d.fn.message_iter_init_append(m, &it);
        args(Writer(&d, &it));
        return m;
    }

    void warn(string what, ref DBusError err)
    {
        const name = copied(err.name), message = copied(err.message);
        logWarning("%.*s: %.*s (%.*s)", cast(int) what.length, what.ptr, cast(int) message.length, message.ptr,
                   cast(int) name.length, name.ptr);
        if (d.fn.error_is_set(&err))
            d.fn.error_free(&err);
    }
}

/*
    What the service is told the actions are: a key and a label for each, "default" for clicking
    the notification itself, then each button by its index. The label "default" has is only shown
    by a daemon that lists every action, as a menu, say.
*/
string[] actionList(const NotificationContent c) pure @safe
{
    import std.conv : to;
    string[] list;
    if (c.clickable)
        list ~= ["default", "Open"];
    foreach (i, label; c.actions)
        list ~= [to!string(i), label];
    return list;
}

/// Which handler an action's key is for: a button's index, or -1 for the notification itself.
int actionIndex(string key) pure @safe
{
    import std.conv : to, ConvException;
    if (key == "default")
        return -1;
    try
        return to!int(key);
    catch (ConvException)
        return int.max; // not one of ours: no handler
}

/// The service's app_icon: a theme's icon by name, or a file as a file:// URI.
string iconArgument(string icon) @safe
{
    import std.algorithm : canFind;
    import std.path : absolutePath;
    import std.uri : encode;
    return icon.canFind('/') ? "file://" ~ encode(absolutePath(icon)) : icon;
}

ubyte urgencyByte(Urgency u) pure nothrow @safe @nogc
{
    final switch (u)
    {
        case Urgency.low: return 0;
        case Urgency.normal: return 1;
        case Urgency.critical: return 2;
    }
}

string priority(Urgency u) pure nothrow @safe @nogc
{
    final switch (u)
    {
        case Urgency.low: return "low";
        case Urgency.normal: return "normal";
        case Urgency.critical: return "urgent";
    }
}

unittest
{
    NotificationContent c;
    c.actions = ["Play", "Show in folder"];
    assert(actionList(c) == ["0", "Play", "1", "Show in folder"]);
    c.clickable = true;
    assert(actionList(c) == ["default", "Open", "0", "Play", "1", "Show in folder"]);
    assert(actionIndex("default") == -1 && actionIndex("1") == 1 && actionIndex("other") == int.max);

    assert(iconArgument("audio-x-generic") == "audio-x-generic");
    assert(iconArgument("/tmp/my art.png") == "file:///tmp/my%20art.png");
    assert(urgencyByte(Urgency.critical) == 2 && priority(Urgency.critical) == "urgent");
}
