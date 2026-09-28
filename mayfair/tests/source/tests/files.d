module tests.files;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : startsWith;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.process;
import std.stdio : File;
import std.string : strip;
import harness;
import mayfair;

/// File choosers: what the desktop's portal is asked for -- title, filters, where to start, one
/// file or many, over which window -- and what it answers reaching the app, cancelling included.
///
/// The portal is tests/portal/fake_portal.py on a bus of the test's own, so no real dialog shows.
void fileChoosers()
{
    auto portal = FakePortal.start();
    if (!portal)
        return;
    scope(exit) portal.stop();

    import std.file : getcwd, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    // Where to save: SDL only suggests a name in a folder that's there
    const folder = buildPath(tempDir, format!"mayfair-files-%s"(thisProcessID));
    mkdirRecurse(folder);
    scope(exit) rmdirRecurse(folder);

    Button open, many, save, saveNowhere, cancel;
    string[][] answers; // each answer, as a list: a single path, or none, is a list of one or none
    run("files: file choosers", {
        open = new Button("Open");
        many = new Button("Many");
        save = new Button("Save");
        saveNowhere = new Button("Save nowhere");
        cancel = new Button("Cancel");
        void answer(string path) { answers ~= path ? [path] : []; }
        open.onAction({
            new FileChooser().title("Open a picture").acceptText("Use")
                .addFilter("Pictures", "png", "*.jpg").addFilter("All files", "*")
                .initialDirectory("/tmp").showOpenDialog(open, &answer);
        });
        many.onAction({ new FileChooser().showOpenMultipleDialog(many, (paths) { answers ~= paths; }); });
        save.onAction({
            new FileChooser().initialDirectory(folder).initialFileName("Untitled.txt").showSaveDialog(save, &answer);
        });
        saveNowhere.onAction({
            new FileChooser().initialDirectory("/no/such/folder").initialFileName("Untitled.txt")
                .showSaveDialog(saveNowhere, &answer);
        });
        cancel.onAction({ new FileChooser().title("Cancel me").showOpenDialog(cancel, &answer); });
        return cast(Widget) new Column().padding(20).spacing(10).fillWidth(false).add(open).add(many).add(save)
            .add(saveNowhere).add(cancel);
    }, (Driver d) {
        // Clicks `button`, and hands back what the portal was asked, once the app has its answer
        JSONValue ask(Button button, size_t answered)
        {
            d.click(button);
            const call = portal.nextCall();
            const deadline = MonoTime.currTime + 5.seconds;
            size_t got;
            do
            {
                d.ui({ got = answers.length; });
                if (got > answered)
                    break;
                Thread.sleep(20.msecs);
            }
            while (MonoTime.currTime < deadline);
            d.check(got > answered, "an answer came back");
            return call;
        }

        auto call = ask(open, 0);
        d.expect(call["method"].str, "OpenFile");
        d.expect(call["title"].str, "Open a picture");
        d.check(call["parent_window"].str.startsWith("wayland:") || call["parent_window"].str.startsWith("x11:"),
                "over the window: " ~ call["parent_window"].toString);
        const options = call["options"];
        d.expect(options["accept_label"].str, "Use");
        d.expect(options["current_folder"].str, "/tmp", "where it starts");
        d.check("multiple" !in options || !options["multiple"].boolean, "one file");
        d.expect(options["filters"].toString,
                 `[["Pictures",[[0,"*.png"],[0,"*.jpg"]]],["All files",[[0,"*"]]]]`, "the kinds of file");
        d.ui({ d.expect(answers[0], ["/tmp/mayfair/a.png"], "the path chosen"); });

        call = ask(many, 1);
        d.check(call["options"]["multiple"].boolean, "several files");
        d.check("filters" !in call["options"], "any file, with no filters");
        d.ui({ d.expect(answers[1], ["/tmp/mayfair/a.png", "/tmp/mayfair/b c.png"], "every path, undone from URIs"); });

        call = ask(save, 2);
        d.expect(call["method"].str, "SaveFile");
        d.expect(call["options"]["current_folder"].str, folder, "the folder to save in");
        d.expect(call["options"]["current_name"].str, "Untitled.txt", "the name suggested");
        d.ui({ d.expect(answers[2], [buildPath(folder, "Untitled.txt")]); });

        // A folder that isn't there is none, and the name's still suggested
        call = ask(saveNowhere, 3);
        d.expect(call["options"]["current_folder"].str, getcwd(), "the working directory in its place");
        d.expect(call["options"]["current_name"].str, "Untitled.txt", "and the name kept");

        ask(cancel, 4);
        d.ui({ d.expect(answers[4].length, 0, "cancelling gives nothing"); });
    });
}

private:

/// A private session bus with the fake portal on it, and the app pointed at it while it lasts.
final class FakePortal
{
    Pid bus;
    ProcessPipes portal;
    bool pointed;        // DBUS_SESSION_BUS_ADDRESS is ours, and has to be put back
    string savedAddress; // what it was, or null if there wasn't one

    static FakePortal start()
    {
        import std.file : thisExePath;
        import std.path : buildPath, dirName;
        import std.stdio : stdin;

        auto p = new FakePortal;
        try
        {
            // The bus's own chatter -- services it starts for the app -- isn't the tests' business
            auto address = pipe();
            p.bus = spawnProcess(["dbus-daemon", "--session", "--nofork", "--print-address"],
                                 stdin, address.writeEnd, File("/dev/null", "w"));
            const bus = address.readEnd.readln().strip;
            p.portal = pipeProcess(["python3", buildPath(thisExePath.dirName, "portal", "fake_portal.py"), bus],
                                   Redirect.stdout);
            if (!p.portal.stdout.readln().startsWith(`{"ready"`))
                throw new Exception("the fake portal didn't start");
            p.savedAddress = environment.get("DBUS_SESSION_BUS_ADDRESS");
            environment["DBUS_SESSION_BUS_ADDRESS"] = bus;
            p.pointed = true;
        }
        catch (Exception e)
        {
            import std.stdio : stderr;
            stderr.writeln("skip  files: no private bus and fake portal: ", e.msg);
            p.stop();
            return null;
        }
        return p;
    }

    /// The next call the portal had, as it printed it, or an empty one if none came in 5 s
    JSONValue nextCall()
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;

        auto fd = pollfd(portal.stdout.fileno, POLLIN);
        const line = poll(&fd, 1, 5000) > 0 ? portal.stdout.readln() : null;
        return line.length ? parseJSON(line)
                           : parseJSON(`{"method": "", "title": "", "parent_window": "", "options": {}}`);
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
        foreach (pid; [portal.pid, bus])
            if (pid !is null)
            {
                kill(pid);
                wait(pid);
            }
    }
}
