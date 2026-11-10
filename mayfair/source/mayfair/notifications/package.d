module mayfair.notifications;

import core.sync.mutex : Mutex;
import mayfair.windowing.platform : Platform;

/*
    Desktop notifications: a message the desktop shows outside the app's windows -- in a bubble,
    and in its list of notifications -- for something the user should know about even when
    they're looking at something else. Android's NotificationManager; JavaFX has none.

        new Notification("Download finished")
            .text("song.flac is ready to play")
            .icon("audio-x-generic")
            .action("Play", { play("song.flac"); })
            .onClicked({ window.raise(); })
            .show();

    What it can show, and what the user can do with it, is the desktop's to decide: a title, some
    text, an icon, and buttons for its actions are what nearly every desktop shows. Clicking the
    notification itself runs onClicked; a button, its action; and onClosed runs when it's gone,
    dismissed or timed out, where the desktop says so. Each runs on the UI thread, as
    Platform.runLater's tasks do. show() again, with anything changed, updates it in place.

    An icon is a name from the icon theme ("mail-unread"), or a file's path. The App's id (see
    App.setId) tells the desktop which app it's from, for the app's name and icon beside it.

    How it's sent depends on the platform, behind a NotificationBackend:

        Linux and the BSDs   the freedesktop.org notification service, over D-Bus, which GNOME,
                             KDE and every other desktop's notification daemon provides; or,
                             in a Flatpak, the desktop portal's (see mayfair.notifications.linux)
        elsewhere            nothing yet

    A desktop with its own way, or a test, can give one of its own with Notification.setBackend.
*/
final class Notification
{
    /// A notification titled `title`, not shown yet.
    this(string title)
    {
        _title = title;
        lock = new Mutex;
    }

    /// The title: what it's about, in a few words.
    Notification title(string title) { _title = title; return this; }
    string title() const { return _title; } /// ditto

    /// The text under the title. Plain text; some desktops show less of it than others.
    Notification text(string text) { _text = text; return this; }
    string text() const { return _text; } /// ditto

    /// An icon: a name from the icon theme, or a file's path. The app's own, if not given.
    Notification icon(string nameOrPath) { _icon = nameOrPath; return this; }
    string icon() const { return _icon; } /// ditto

    /// How much it matters: a critical one stays until it's dismissed, on most desktops.
    Notification urgency(Urgency urgency) { _urgency = urgency; return this; }
    Urgency urgency() const { return _urgency; } /// ditto

    /// Adds a button labelled `label`, which runs `handler`.
    Notification action(string label, void delegate() handler)
    {
        _actions ~= Action(label, handler);
        return this;
    }

    /// Runs `handler` when the notification itself is clicked.
    Notification onClicked(void delegate() handler) { _clicked = handler; return this; }

    /// Runs `handler` when it's gone: dismissed, timed out, or closed by close().
    Notification onClosed(void delegate() handler) { _closed = handler; return this; }

    /// Shows it, or, shown already, updates it to what it says now.
    Notification show()
    {
        synchronized (lock)
            _showing = true;
        backend().show(this);
        return this;
    }

    /// Takes it away, if it's showing.
    void close()
    {
        synchronized (lock)
        {
            if (!_showing)
                return;
            _showing = false;
        }
        backend().close(this);
        if (_closed)
            deliver(_closed);
    }

    /// Whether it's showing, as far as the app knows: since show(), and until it's closed.
    bool showing() { synchronized (lock) return _showing; }

    /// What notifications are shown with from now on: a desktop's own, say, or a test's.
    static void setBackend(NotificationBackend backend)
    {
        synchronized (Notification.classinfo)
            chosen = backend;
    }

    /// What this one says, as a backend sends it: a copy, so another thread can have it.
    NotificationContent content() const
    {
        NotificationContent c;
        c.title = _title;
        c.text = _text;
        c.icon = _icon;
        c.urgency = _urgency;
        foreach (a; _actions)
            c.actions ~= a.label;
        c.clickable = _clicked !is null;
        return c;
    }

    /*
        For a backend: runs the handler for what the user did, on the UI thread. `action` is
        the index of a button, or -1 for the notification itself; `closed` that it's gone. A
        notification closed by close() has its onClosed run by close(), not this.
    */
    void activated(int action)
    {
        void delegate() handler;
        if (action < 0)
            handler = _clicked;
        else if (action < _actions.length)
            handler = _actions[action].handler;
        if (handler)
            deliver(handler);
    }

    /// ditto
    void dismissed()
    {
        synchronized (lock)
            _showing = false;
        if (_closed)
            deliver(_closed);
    }

    /// How a backend's news reaches the UI thread: Platform.runLater, unless a test says otherwise.
    static __gshared void function(void delegate()) deliver = &runLater;

private:
    struct Action
    {
        string label;
        void delegate() handler;
    }

    string _title, _text, _icon;
    Urgency _urgency = Urgency.normal;
    Action[] _actions;
    void delegate() _clicked, _closed;
    bool _showing;
    Mutex lock;

    static void runLater(void delegate() task) { Platform.runLater(task); }

    static NotificationBackend backend()
    {
        synchronized (Notification.classinfo)
        {
            if (!chosen)
                chosen = platformBackend();
            return chosen;
        }
    }

    // Guarded by Notification.classinfo's monitor, which needs no module constructor: one here
    // would make a cycle with mayfair.notifications.linux's, which this imports
    __gshared NotificationBackend chosen;
}

/// How much a notification matters.
enum Urgency : ubyte
{
    low,        /// Can wait: some desktops show it quietly, or only in their list
    normal,
    critical,   /// Needs attention: most desktops keep it until it's dismissed
}

/// What a notification says: its content, as a backend sends it.
struct NotificationContent
{
    string title, text, icon;
    Urgency urgency = Urgency.normal;
    string[] actions;    /// The buttons' labels, in order
    bool clickable;      /// Whether clicking it does anything
}

/*
    How notifications reach the desktop. show() and close() are called on the UI thread, and
    shouldn't keep it waiting: a backend talking to another process does that on a thread of its
    own. It tells a notification what the user did with Notification.activated and dismissed,
    from any thread.
*/
interface NotificationBackend
{
    /// Shows `n`, or updates it if it's showing.
    void show(Notification n);

    /// Takes `n` away.
    void close(Notification n);
}

/// The app's name and id, for the desktop to say which app a notification is from. The App sets them.
package(mayfair) void setNotifyingApp(string name, string id)
{
    synchronized (Notification.classinfo)
    {
        appName = name;
        appId = id;
    }
}

/// ditto
package(mayfair) void notifyingApp(out string name, out string id)
{
    synchronized (Notification.classinfo)
    {
        name = appName;
        id = appId;
    }
}

private:

__gshared string appName, appId; // guarded by Notification.classinfo's monitor, as `chosen` is

/// The platform's own way of showing notifications.
NotificationBackend platformBackend()
{
    version (Emscripten)
        return new NoNotifications("in the browser");
    else version (OSX)
        return new NoNotifications("on macOS yet");
    else version (Posix)
    {
        import mayfair.notifications.linux : DBusNotifications;
        return new DBusNotifications;
    }
    else
        return new NoNotifications("on this platform yet");
}

/// Where there's no way to show them: each is dropped, and the first says so in the log.
final class NoNotifications : NotificationBackend
{
    this(string where) { this.where = where; }

    void show(Notification n)
    {
        import mayfair.log : logWarning;
        if (!warned)
            logWarning("Notifications aren't shown %.*s", cast(int) where.length, where.ptr);
        warned = true;
    }

    void close(Notification n) {}

    private string where;
    private bool warned;
}

unittest
{
    // A backend of the test's own: what's shown and closed, and handlers run at once
    static class Recorder : NotificationBackend
    {
        Notification[] shown, closed;
        void show(Notification n) { shown ~= n; }
        void close(Notification n) { closed ~= n; }
    }
    auto recorder = new Recorder;
    Notification.setBackend(recorder);
    const was = Notification.deliver;
    scope (exit) Notification.deliver = was;
    Notification.deliver = (void delegate() task) { task(); };

    string happened;
    auto n = new Notification("Download finished")
        .text("song.flac")
        .icon("audio-x-generic")
        .urgency(Urgency.low)
        .action("Play", { happened ~= "play "; })
        .action("Show in folder", { happened ~= "folder "; })
        .onClicked({ happened ~= "clicked "; })
        .onClosed({ happened ~= "closed "; });

    const c = n.content;
    assert(c.title == "Download finished" && c.text == "song.flac" && c.icon == "audio-x-generic");
    assert(c.urgency == Urgency.low && c.actions == ["Play", "Show in folder"] && c.clickable);
    assert(!n.showing);

    n.show();
    assert(recorder.shown == [n] && n.showing);
    n.activated(1);
    n.activated(-1);
    n.activated(7); // a button it hasn't got: nothing
    n.dismissed();
    assert(happened == "folder clicked closed ", happened);
    assert(!n.showing);

    n.close(); // not showing: nothing to close
    assert(recorder.closed.length == 0 && happened == "folder clicked closed ");
    n.show();
    n.close();
    assert(recorder.closed == [n] && !n.showing);
    assert(happened == "folder clicked closed closed ", "close() runs onClosed itself");
    assert(!new Notification("Plain").content.clickable, "nothing to click without onClicked");
}
