module tests.notifications;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : startsWith;
import std.json : JSONValue, parseJSON;
import std.process;
import std.stdio : File;
import std.string : strip;
import harness;
import mayfair;
import mayfair.notifications.linux : DBusNotifications, Protocol;

/// Desktop notifications: what the desktop's asked to show -- over the freedesktop service and
/// over the portal -- and what the user does with them reaching the app, on the UI thread.
///
/// The desktop is tests/portal/fake_notifications.py on a bus of the test's own, so nothing shows.
void desktopNotifications()
{
    auto fake = FakeNotifications.start();
    if (!fake)
        return;
    scope(exit) fake.stop();
    scope(exit) Notification.setBackend(null); // the platform's own again, for whatever runs next

    string[] happened; // what the handlers did, on the UI thread
    run("notifications: desktop notifications", {
        Notification.setBackend(new DBusNotifications(Protocol.freedesktop));
        return cast(Widget) new Label("Notifications");
    }, (Driver d) {
        // Waits for `what` to have happened, and says whether it did
        bool waitFor(string what)
        {
            const deadline = MonoTime.currTime + 5.seconds;
            bool seen;
            do
            {
                d.ui({
                    foreach (h; happened)
                        if (h == what)
                            seen = true;
                });
                if (!seen)
                    Thread.sleep(20.msecs);
            }
            while (!seen && MonoTime.currTime < deadline);
            return seen;
        }

        // The freedesktop service: a button pressed, then gone
        d.ui({
            new Notification("Press the first button").text("song.flac").icon("audio-x-generic")
                .urgency(Urgency.critical)
                .action("Play", { happened ~= "play"; }).action("Show in folder", { happened ~= "folder"; })
                .onClosed({ happened ~= "gone"; }).show();
        });
        auto call = fake.nextCall();
        d.expect(call["method"].str, "Notify");
        d.expect(call["summary"].str, "Press the first button");
        d.expect(call["body"].str, "song.flac");
        d.expect(call["app_icon"].str, "audio-x-generic");
        d.expect(call["actions"].toString, `["0","Play","1","Show in folder"]`, "a key and a label for each button");
        d.expect(call["hints"]["urgency"].integer, 2, "critical");
        d.check(call["app_name"].str.length > 0, "the app's name");
        d.check(waitFor("play"), "the button's action ran");
        d.check(waitFor("gone"), "and onClosed, once the desktop took it away");
        d.ui({ d.check(happened.length == 2, "and not the other button's"); });

        // Clicking the notification itself
        d.ui({ new Notification("Click me").onClicked({ happened ~= "clicked"; }).show(); });
        call = fake.nextCall();
        d.expect(call["actions"].toString, `["default","Open"]`, "clicking it is the default action");
        d.check(waitFor("clicked"), "onClicked ran");

        // Dismissed
        d.ui({ new Notification("Dismiss me").onClosed({ happened ~= "dismissed"; }).show(); });
        fake.nextCall();
        d.check(waitFor("dismissed"), "onClosed ran when it was dismissed");

        // Updated in place, then closed by the app: onClosed once, though the service says so too
        Notification progress;
        d.ui({ progress = new Notification("Copying").text("1%").onClosed({ happened ~= "progress closed"; }).show(); });
        const first = fake.nextCall()["id"].integer;
        d.ui({ progress.text("50%").show(); });
        call = fake.nextCall();
        d.expect(call["replaces_id"].integer, first, "the same notification, updated");
        d.expect(call["body"].str, "50%");
        d.ui({ progress.close(); });
        call = fake.nextCall();
        d.expect(call["method"].str, "CloseNotification");
        d.expect(call["id"].integer, first);
        d.check(waitFor("progress closed"), "onClosed ran");
        Thread.sleep(300.msecs); // the service's own NotificationClosed, which mustn't run it again
        d.ui({
            size_t times;
            foreach (h; happened)
                if (h == "progress closed")
                    times++;
            d.expect(times, 1, "onClosed once");
            d.check(!progress.showing, "and it's not showing");
        });

        // The portal, as a Flatpak's notifications go
        d.ui({
            Notification.setBackend(new DBusNotifications(Protocol.portal));
            new Notification("Press the first button").text("from the portal")
                .action("Play", { happened ~= "portal play"; }).onClosed({ happened ~= "portal gone"; }).show();
        });
        call = fake.nextCall();
        d.expect(call["method"].str, "AddNotification");
        d.expect(call["notification"]["body"].str, "from the portal");
        const buttons = call["notification"]["buttons"];
        d.expect(buttons.array.length, 1, "one button");
        d.expect(buttons[0]["label"].str, "Play");
        d.expect(buttons[0]["action"].str, "0", "its action's key, its index");
        d.check(waitFor("portal play"), "the button's action ran");
        d.check(waitFor("portal gone"), "and it's taken as gone once clicked");
    });
}

private:

/// A private session bus with the fake desktop on it, and the app pointed at it while it lasts.
final class FakeNotifications
{
    Pid bus;
    ProcessPipes fake;
    bool pointed;        // DBUS_SESSION_BUS_ADDRESS is ours, and has to be put back
    string savedAddress; // what it was, or null if there wasn't one

    static FakeNotifications start()
    {
        import std.file : thisExePath;
        import std.path : buildPath, dirName;
        import std.stdio : stdin;

        auto p = new FakeNotifications;
        try
        {
            auto address = pipe();
            p.bus = spawnProcess(["dbus-daemon", "--session", "--nofork", "--print-address"],
                                 stdin, address.writeEnd, File("/dev/null", "w"));
            const bus = address.readEnd.readln().strip;
            p.fake = pipeProcess(["python3", buildPath(thisExePath.dirName, "portal", "fake_notifications.py"), bus],
                                 Redirect.stdout);
            if (!p.fake.stdout.readln().startsWith(`{"ready"`))
                throw new Exception("the fake desktop didn't start");
            p.savedAddress = environment.get("DBUS_SESSION_BUS_ADDRESS");
            environment["DBUS_SESSION_BUS_ADDRESS"] = bus;
            p.pointed = true;
        }
        catch (Exception e)
        {
            import std.stdio : stderr;
            stderr.writeln("skip  notifications: no private bus and fake desktop: ", e.msg);
            p.stop();
            return null;
        }
        return p;
    }

    /// The next call the fake had, as it printed it, or an empty one if none came in 5 s
    JSONValue nextCall()
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;

        auto fd = pollfd(fake.stdout.fileno, POLLIN);
        const line = poll(&fd, 1, 5000) > 0 ? fake.stdout.readln() : null;
        return line.length ? parseJSON(line) : parseJSON(`{"method": ""}`);
    }

    void stop()
    {
        if (pointed)
        {
            if (savedAddress !is null)
                environment["DBUS_SESSION_BUS_ADDRESS"] = savedAddress;
            else
                environment.remove("DBUS_SESSION_BUS_ADDRESS");
        }
        foreach (pid; [fake.pid, bus])
            if (pid !is null)
            {
                kill(pid);
                wait(pid);
            }
    }
}
