import core.stdc.stdlib : exit;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind;
import std.format : format;
import std.stdio : writefln;
import std.string : splitLines;
import harness;
import mayfair;
import mayfair.terminal;

/*
    End-to-end tests for the Terminal, on Mayfair's own harness (see mayfair/tests): real windows
    driven by real SDL events, and real programs running in them.

        cd tests && dub run
*/
void main()
{
    shell();
    keys();
    sizes();
    history();
    selecting();
    mouseReporting();
    writefln("%s passed, %s failed checks", passedCount, failedChecks);
    exit(failedChecks ? 1 : 0);
}

/// Waits for what the terminal shows to pass `ok`, and fails if it doesn't in time.
private string waitFor(Driver d, Terminal t, bool delegate(string) ok, string what,
                       Duration timeout = 5.seconds, string file = __FILE__, size_t line = __LINE__)
{
    string text;
    const deadline = MonoTime.currTime + timeout;
    while (MonoTime.currTime < deadline)
    {
        d.ui({ text = t.screenText; });
        if (ok(text))
            return text;
        Thread.sleep(20.msecs);
    }
    d.fail(format!"%s: the screen shows\n%s"(what, text), file, line);
    return text;
}

/// Waits for a line of the screen to be exactly `want`.
private string waitForLine(Driver d, Terminal t, string want, string file = __FILE__, size_t line = __LINE__)
{
    return waitFor(d, t, (s) => s.splitLines.canFind(want), "a line reading " ~ want, 5.seconds, file, line);
}

/// The middle of the cell at `column`, `line`, in the window.
private void cellCentre(Driver d, Terminal t, int column, int line, out float x, out float y)
{
    float cx, cy;
    d.ui({
        const b = t.boundsInScene, c = t.cellBounds(column, line);
        cx = b.minX + c.centreX;
        cy = b.minY + c.centreY;
    });
    x = cx;
    y = cy;
}

/// A shell: what's typed runs, the title it sets is the terminal's, and its exit is heard.
void shell()
{
    Terminal t;
    int exitedWith = int.min;
    run("terminal: shell", {
        t = new Terminal(["/bin/sh"]).environment(["PS1=$ ", "ENV="]).prefSize(600, 300);
        t.onExited((int status) { exitedWith = status; });
        return cast(Widget) new Column().padding(10).add(t);
    }, (Driver d) {
        waitFor(d, t, (s) => s.canFind("$"), "a prompt");
        d.ui({ t.requestFocus(); });
        d.type("echo hello");
        d.key(SDL_Keycode.SDLK_RETURN);
        waitForLine(d, t, "hello");

        d.type(`printf '\033]0;A title\007'`);
        d.key(SDL_Keycode.SDLK_RETURN);
        const deadline = MonoTime.currTime + 5.seconds;
        string title;
        while (MonoTime.currTime < deadline && title != "A title")
        {
            d.ui({ title = t.windowTitle; });
            Thread.sleep(20.msecs);
        }
        d.expect(title, "A title", "the title the shell set");

        d.type("exit 7");
        d.key(SDL_Keycode.SDLK_RETURN);
        waitFor(d, t, (s) => exitedWith != int.min, "the shell exiting");
        d.ui({
            d.check(t.exited, "exited");
            d.expect(t.exitStatus, 7, "with the code it was given");
            d.expect(exitedWith, 7, "and onExited heard it");
            d.check(t.screenText.canFind("hello"), "what it showed stays");
        });
    });
}

/// Keys reach the program encoded as xterm's are -- Tab included, which doesn't move focus -- and
/// Ctrl+C interrupts it.
void keys()
{
    Terminal t;
    Button after;
    run("terminal: keys", {
        t = new Terminal(["/bin/cat", "-vT"]).prefSize(600, 200);
        after = new Button("After");
        return cast(Widget) new Column().padding(10).add(t).add(after);
    }, (Driver d) {
        d.ui({ t.requestFocus(); });
        d.settle();
        d.key(SDL_Keycode.SDLK_UP);
        d.key(SDL_Keycode.SDLK_B, SDL_Keymod.KMOD_LCTRL);
        d.key(SDL_Keycode.SDLK_X, SDL_Keymod.KMOD_LALT);
        d.key(SDL_Keycode.SDLK_TAB);
        d.key(SDL_Keycode.SDLK_F5);
        d.key(SDL_Keycode.SDLK_RETURN);
        // cat -vT writes what it read back, control characters and tabs spelt out
        waitForLine(d, t, "^[[A^B^[x^I^[[15~");
        d.ui({ d.check(t.isFocusOwner, "Tab went to the program, not to the next widget"); });

        d.type("typed é");
        d.key(SDL_Keycode.SDLK_RETURN);
        waitForLine(d, t, "typed M-CM-)");

        d.key(SDL_Keycode.SDLK_C, SDL_Keymod.KMOD_LCTRL);
        waitFor(d, t, (s) { bool e; d.ui({ e = t.exited; }); return e; }, "cat interrupted");
        d.ui({ d.expect(t.exitStatus, -2, "by SIGINT"); });
    });
}

/// The program's told the terminal's size, and told again when it changes.
void sizes()
{
    Terminal t;
    run("terminal: sizes", {
        t = new Terminal(["/bin/sh"]).environment(["PS1=$ ", "ENV="]).prefSize(500, 200);
        return cast(Widget) new Column().padding(10).fillWidth(false).add(t);
    }, (Driver d) {
        waitFor(d, t, (s) => s.canFind("$"), "a prompt");
        d.ui({ t.requestFocus(); });
        int columns, lines;
        d.ui({ columns = t.columns; lines = t.lines; });
        d.check(columns > 20 && lines > 5, format!"a size from its own: %sx%s"(columns, lines));
        d.type("stty size");
        d.key(SDL_Keycode.SDLK_RETURN);
        waitForLine(d, t, format!"%s %s"(lines, columns));

        d.type("clear");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({ t.prefSize(700, 300); });
        d.settle();
        int wider, taller;
        d.ui({ wider = t.columns; taller = t.lines; });
        d.check(wider > columns && taller > lines, format!"bigger: %sx%s"(wider, taller));
        d.type("stty size");
        d.key(SDL_Keycode.SDLK_RETURN);
        waitForLine(d, t, format!"%s %s"(taller, wider));
    });
}

/// What's scrolled off the top is kept: the wheel and Shift+Page Up go back to it, and typing
/// comes back down.
void history()
{
    Terminal t;
    run("terminal: history", {
        t = new Terminal(["/bin/sh", "-c", "seq 1 100; exec cat"]).prefSize(500, 200);
        return cast(Widget) new Column().padding(10).add(t);
    }, (Driver d) {
        waitForLine(d, t, "100");
        d.ui({ t.requestFocus(); });
        float x, y;
        cellCentre(d, t, 2, 2, x, y);
        d.wheel(x, y, 5); // up, 15 lines
        d.settle();
        auto text = waitFor(d, t, (s) => !s.splitLines.canFind("100"), "scrolled back");
        d.check(text.splitLines.canFind("85"), "fifteen lines back:\n" ~ text);

        d.type("x");
        waitForLine(d, t, "100");

        d.key(SDL_Keycode.SDLK_PAGEUP, SDL_Keymod.KMOD_LSHIFT);
        waitFor(d, t, (s) => !s.splitLines.canFind("100"), "a page back");
        d.key(SDL_Keycode.SDLK_END, SDL_Keymod.KMOD_LSHIFT);
        waitForLine(d, t, "100");
    });
}

/// Dragging and double-clicking select, which is the primary selection; Ctrl+Shift+C copies it,
/// and Ctrl+Shift+V pastes.
void selecting()
{
    Terminal t;
    run("terminal: selecting", {
        t = new Terminal(["/bin/sh", "-c", "printf 'alpha beta gamma\\n'; exec cat"]).prefSize(500, 200);
        return cast(Widget) new Column().padding(10).add(t);
    }, (Driver d) {
        d.preserveClipboard();
        waitForLine(d, t, "alpha beta gamma");
        float x, y;
        cellCentre(d, t, 7, 0, x, y);
        d.click(x, y, 1);
        d.press(x, y, 2);
        d.release(x, y, 2);
        d.settle();
        d.ui({
            d.expect(t.selectedText, "beta", "a double click selects the word");
            d.expect(Clipboard.primary, "beta", "as the primary selection");
        });

        float x0, x4;
        cellCentre(d, t, 0, 0, x0, y);
        cellCentre(d, t, 4, 0, x4, y);
        d.press(x0 - 2, y);
        d.move(x0 + 10, y);
        d.move(x4 + 2, y);
        d.release(x4 + 2, y);
        d.settle();
        d.ui({ d.expect(t.selectedText, "alpha", "dragging selects what it went over"); });

        d.key(SDL_Keycode.SDLK_C, cast(SDL_Keymod)(SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        d.ui({ d.expect(Clipboard.text, "alpha", "copied"); });

        d.ui({ Clipboard.text = "pasted"; });
        d.key(SDL_Keycode.SDLK_V, cast(SDL_Keymod)(SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        waitForLine(d, t, "pasted");
    });
}

/// A program that asks for the mouse gets clicks as escape sequences, in the encoding it asked for.
void mouseReporting()
{
    Terminal t;
    run("terminal: mouse reporting", {
        t = new Terminal(["/bin/sh", "-c", "printf '\\033[?1000h\\033[?1006h'; exec cat -v"]).prefSize(500, 200);
        return cast(Widget) new Column().padding(10).add(t);
    }, (Driver d) {
        Thread.sleep(300.msecs); // for the program to ask
        d.settle();
        float x, y;
        cellCentre(d, t, 2, 1, x, y);
        d.click(x, y);
        d.key(SDL_Keycode.SDLK_RETURN);
        waitForLine(d, t, "^[[<0;3;2M^[[<0;3;2m");
        d.ui({ d.expect(t.selectedText, null, "and it selected nothing"); });
    });
}
