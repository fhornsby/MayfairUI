module harness;

import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : Duration, msecs, seconds;
import std.conv : to;
import std.format : format;
public import sdl;   // tests name keys and events by SDL's names
import mayfair;

/*
    End-to-end tests: a real App, in a real window, driven by real SDL events.

    Each test builds a widget tree, and a script runs on a thread of its own while the App runs
    on the main thread, as it would in an app. The script pushes input into SDL's queue, exactly
    where the window system's own events arrive, so everything between there and the widgets --
    queuing, the frame phases, hit testing, focus, bubbling -- is what's being tested. To look at
    or change widgets it goes through ui(), which runs code on the UI thread and waits for it,
    and which is Platform.runLater, so that's tested along the way.

    Real input is shut out while tests run: an SDL event filter drops mouse, keyboard and window
    focus events that the harness didn't make. A pointer that happens to be over a test window, or
    the user switching to another window, would otherwise change what the tests see.

    Tests need a display, as the App does. The clipboard and primary selection are the desktop's
    own, so a test that uses them saves them first and puts them back.
*/

/// One step of input or checking, run on the script's thread.
final class Driver
{
    /// Runs `task` on the UI thread and waits for it to finish.
    void ui(void delegate() task)
    {
        if (appGone)
            return; // it crashed, and that's been reported: nothing's left to run anything
        auto done = new Semaphore;
        Throwable failed;
        Platform.runLater({
            try
                task();
            catch (Throwable t)
                failed = t;
            done.notify();
        });
        if (!done.wait(10.seconds))
        {
            fail("timed out waiting for the UI thread");
            appGone = true; // don't wait ten seconds for each step that follows
        }
        else if (failed)
            fail("UI thread threw: " ~ failed.msg);
    }

    /// Waits until everything pushed so far has been handled and drawn. A task runs in the frame's
    /// update phase, after the input before it and before that frame is drawn; the second one runs
    /// in a later frame, so the first's has been drawn by then.
    void settle()
    {
        ui({});
        ui({});
    }

    /// Records a failure if `ok` is false. Callable from the script or from inside ui().
    void check(bool ok, lazy string what, string file = __FILE__, size_t line = __LINE__)
    {
        if (!ok)
            fail(what, file, line);
    }

    /// Records a failure if `actual` isn't `expected`, showing both.
    void expect(T, U)(T actual, U expected, string what = "", string file = __FILE__, size_t line = __LINE__)
    {
        if (actual != expected)
            fail(format!"%sexpected %s, got %s"(what.length ? what ~ ": " : "", expected, actual), file, line);
    }

    void fail(string what, string file = __FILE__, size_t line = __LINE__)
    {
        lock.lock();
        scope(exit) lock.unlock();
        failures ~= format!"%s(%s): %s"(file, line, what);
    }

    /// A key pressed and released.
    void key(SDL_Keycode code, SDL_Keymod mods = SDL_Keymod.KMOD_NONE)
    {
        foreach (down; [true, false])
        {
            SDL_Event e;
            e.type = down ? SDL_EventType.SDL_EVENT_KEY_DOWN : SDL_EventType.SDL_EVENT_KEY_UP;
            e.key.windowID = windowID;
            e.key.which = harnessDevice;
            e.key.key = code;
            e.key.mod = mods;
            e.key.down = down;
            SDL_PushEvent(&e);
        }
        settle();
    }

    /// Holds `mods` down for the mouse events after, as Ctrl or Shift held while clicking: SDL reads
    /// a mouse event's modifiers from the keyboard's state, not the event. KMOD_NONE lets go.
    void hold(SDL_Keymod mods)
    {
        ui({ SDL_SetModState(mods); });
    }

    /// Text typed, as a keyboard or an input method committing it would send it.
    void type(string text)
    {
        SDL_Event e;
        e.type = SDL_EventType.SDL_EVENT_TEXT_INPUT;
        e.text.windowID = windowID;
        e.text.reserved = harnessDevice;
        e.text.text = keep(text);
        SDL_PushEvent(&e);
        settle();
    }

    /// An input method's composition so far. `caret` is in characters, or -1.
    void compose(string text, int caret = -1)
    {
        SDL_Event e;
        e.type = SDL_EventType.SDL_EVENT_TEXT_EDITING;
        e.edit.windowID = windowID;
        e.edit.reserved = harnessDevice;
        e.edit.text = keep(text);
        e.edit.start = caret;
        e.edit.length = -1;
        SDL_PushEvent(&e);
        settle();
    }

    /// The pointer moved to `x`, `y`, in points from the window's top left.
    void move(float x, float y)
    {
        SDL_Event e;
        e.type = SDL_EventType.SDL_EVENT_MOUSE_MOTION;
        e.motion.windowID = windowID;
        e.motion.which = harnessDevice;
        e.motion.x = x * pointsToWindow;
        e.motion.y = y * pointsToWindow;
        SDL_PushEvent(&e);
        settle();
    }

    /// Something dragged from another app over the window, to `x`, `y` in points: SDL says only
    /// where it is until it's dropped, not what it is.
    void dragOver(float x, float y)
    {
        if (!dragging)
            dropEvent(SDL_EventType.SDL_EVENT_DROP_BEGIN, x, y);
        dragging = true;
        dropEvent(SDL_EventType.SDL_EVENT_DROP_POSITION, x, y);
        settle();
    }

    /// `files` dropped at `x`, `y`, dragged there first: an event for each, as SDL sends them.
    void dropFiles(float x, float y, string[] files...)
    {
        dragOver(x, y);
        foreach (f; files)
            dropEvent(SDL_EventType.SDL_EVENT_DROP_FILE, x, y, f);
        endDrag(x, y);
    }

    /// `text` dropped at `x`, `y`, dragged there first.
    void dropText(float x, float y, string text)
    {
        import std.algorithm : splitter;
        import std.array : empty;
        dragOver(x, y);
        // A line at a time, as SDL sends it, without its line breaks, or any empty lines
        foreach (line; text.splitter!(c => c == '\n' || c == '\r'))
            if (!line.empty)
                dropEvent(SDL_EventType.SDL_EVENT_DROP_TEXT, x, y, line);
        endDrag(x, y);
    }

    /// The drag left the window, or was let go of with nothing in it: the end, with no data.
    void dragLeave()
    {
        endDrag(0, 0);
    }

    /// The wheel or a touchpad, with the pointer at `x`, `y`, in SDL's amounts: notches of a
    /// wheel (120ths of one, for a high-resolution wheel), or tenths of one for a touchpad, which
    /// on Wayland come in 2560ths, rarely on the wheel's 120ths: -0.3125, say, rather than -0.3. `dy` is positive away from the user, `dx` to the right.
    void scroll(float x, float y, float dy, float dx = 0)
    {
        SDL_Event e;
        e.type = SDL_EventType.SDL_EVENT_MOUSE_WHEEL;
        e.wheel.windowID = windowID;
        e.wheel.which = harnessDevice;
        e.wheel.x = dx;
        e.wheel.y = dy;
        e.wheel.mouse_x = x * pointsToWindow;
        e.wheel.mouse_y = y * pointsToWindow;
        SDL_PushEvent(&e);
        settle();
        // A wheel's notch is eased into, and a touchpad may glide: wait for it to come to rest
        Thread.sleep(400.msecs);
        settle();
    }

    /// A wheel turned `dy` notches at `x`, `y`, without waiting for anything: for watching it ease.
    void wheel(float x, float y, float dy)
    {
        SDL_Event e;
        e.type = SDL_EventType.SDL_EVENT_MOUSE_WHEEL;
        e.wheel.windowID = windowID;
        e.wheel.which = harnessDevice;
        e.wheel.y = dy;
        e.wheel.mouse_x = x * pointsToWindow;
        e.wheel.mouse_y = y * pointsToWindow;
        SDL_PushEvent(&e);
    }

    /*
        Fingers moving on a touchpad: `count` movements of `dy` (in SDL's touchpad units, a tenth
        of a notch's worth each) `interval` apart, then lifted. Returns straight away, with any
        glide still on its way.
    */
    void swipe(float x, float y, float dy, int count, Duration interval = 16.msecs)
    {
        foreach (i; 0 .. count)
        {
            SDL_Event e;
            e.type = SDL_EventType.SDL_EVENT_MOUSE_WHEEL;
            e.wheel.windowID = windowID;
            e.wheel.which = harnessDevice;
            e.wheel.y = dy;
            e.wheel.mouse_x = x * pointsToWindow;
            e.wheel.mouse_y = y * pointsToWindow;
            SDL_PushEvent(&e);
            Thread.sleep(interval);
        }
        settle();
    }

    void press(float x, float y, ubyte clicks = 1, ubyte button = 1) { mouseButton(true, x, y, clicks, button); }
    void release(float x, float y, ubyte clicks = 1, ubyte button = 1) { mouseButton(false, x, y, clicks, button); }

    /// Moves to `x`, `y` and clicks there, `clicks` being which click of a run this is: 2 for the
    /// second of a double click.
    void click(float x, float y, ubyte clicks = 1, ubyte button = 1)
    {
        move(x, y);
        press(x, y, clicks, button);
        release(x, y, clicks, button);
    }

    /// Clicks the middle of `w`, or `dx` points in from its left edge.
    void click(Widget w, float dx = float.nan, ubyte clicks = 1, ubyte button = 1)
    {
        Bounds b;
        ui({ b = w.boundsInScene; });
        click(dx == dx ? b.minX + dx : b.centreX, b.centreY, clicks, button);
    }

    /// The test's window, for asking SDL about it. Only from inside ui().
    SDL_Window* window() { return SDL_GetWindowFromID(windowID); }

    /// Saves the clipboard and primary selection, to put back at the end of the test.
    void preserveClipboard()
    {
        ui({
            savedClipboard = Clipboard.text;
            savedPrimary = Clipboard.primary;
            restoreClipboard = true;
        });
    }

    /// The window input goes to: the test's own, or another one the script has opened.
    SDL_WindowID windowID;

    /// SDL's window coordinates to the point, in the test's window.
    float pointsToWindow = 1;

private:
    shared bool appGone;
    string[] kept;
    string savedClipboard, savedPrimary;
    bool restoreClipboard;

    bool dragging; // between a drag's first event over the window and its end

    void dropEvent(SDL_EventType type, float x, float y, string data = null)
    {
        SDL_Event e;
        e.type = type;
        e.drop.windowID = windowID;
        e.drop.reserved = harnessDevice;
        e.drop.x = x * pointsToWindow;
        e.drop.y = y * pointsToWindow;
        e.drop.data = data is null ? null : keep(data);
        SDL_PushEvent(&e);
    }

    void endDrag(float x, float y)
    {
        dropEvent(SDL_EventType.SDL_EVENT_DROP_COMPLETE, x, y);
        dragging = false;
        settle();
    }

    void mouseButton(bool down, float x, float y, ubyte clicks, ubyte button)
    {
        SDL_Event e;
        e.type = down ? SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP;
        e.button.windowID = windowID;
        e.button.which = harnessDevice;
        e.button.x = x * pointsToWindow;
        e.button.y = y * pointsToWindow;
        e.button.button = button;
        e.button.clicks = clicks;
        e.button.down = down;
        SDL_PushEvent(&e);
        settle();
    }

    // SDL keeps a pushed text event's pointer rather than copying the text, so it has to outlive
    // the event: the driver holds on to it, and it's null-terminated for C
    const(char)* keep(string text)
    {
        kept ~= text ~ '\0';
        return kept[$ - 1].ptr;
    }
}

/// Runs one test: builds its tree, shows it, and runs `script` against it. A test with any
/// failed check fails.
void run(string name, Widget delegate() build, void delegate(Driver) script)
{
    // MAYFAIR_TESTS=popups, say, runs only the tests whose names start with that
    import std.process : environment;
    import std.algorithm : startsWith;
    if (!name.startsWith(environment.get("MAYFAIR_TESTS", "")))
        return;
    auto d = new Driver;
    const before = failures.length;

    // Each App's SDL_Quit lets go of D-Bus altogether, so the next one connects afresh: libdbus
    // otherwise keeps the session bus's address for good, and tests.files couldn't point the
    // file choosers at its own bus. An environment variable, as SDL_Quit forgets hints.
    import core.sys.posix.stdlib : setenv;
    setenv("SDL_SHUTDOWN_DBUS_ON_QUIT", "1", 1);

    auto app = new App(name);
    app.scene = new Scene(build());
    app.scene.setColourScheme(ColourScheme.dark); // the same colours whatever the desktop's set to

    auto driver = new Thread({
        scope(exit)
        {
            if (d.restoreClipboard)
                d.ui({ Clipboard.text = d.savedClipboard; Clipboard.primary = d.savedPrimary; });
            SDL_Event quit;
            quit.type = SDL_EventType.SDL_EVENT_QUIT;
            SDL_PushEvent(&quit);
        }
        // The first task runs once the window is up and the first frame drawn
        d.ui({
            int count;
            auto windows = SDL_GetWindows(&count);
            auto window = windows[count - 1];
            d.windowID = SDL_GetWindowID(window);
            d.pointsToWindow = SDL_GetWindowDisplayScale(window) / SDL_GetWindowPixelDensity(window);
            SDL_free(windows);
            SDL_SetEventFilter(&onlyHarnessInput, null);
        });
        d.settle();
        try
            script(d);
        catch (Throwable t)
            d.fail("script threw: " ~ t.msg);
    });
    // The script's thread mustn't keep the process alive if the App dies under it
    driver.isDaemon = true;
    driver.start();
    try
        app.run();
    catch (Throwable t)
    {
        // A crash in the UI is this test's failure, not the end of the run
        d.fail(format!"the App crashed: %s at %s(%s)"(t.msg, t.file, t.line));
        d.appGone = true;
    }
    driver.join();
    SDL_SetEventFilter(null, null);

    if (failures.length == before)
    {
        passed++;
        writeLine("pass  " ~ name);
    }
    else
    {
        writeLine("FAIL  " ~ name);
        foreach (f; failures[before .. $])
            writeLine("      " ~ f);
    }
}

/// How many tests passed and failed, for the runner's summary.
size_t passedCount() { return passed; }
size_t failedChecks() { return failures.length; }

private:

// What the harness puts in an event's device field, so the filter can tell its events apart
enum uint harnessDevice = 0x4D46_5445; // "MFTE"

__gshared Mutex lock;
__gshared string[] failures;
__gshared size_t passed;

shared static this()
{
    lock = new Mutex;
}

void writeLine(string line)
{
    import std.stdio : stdout, writeln;
    writeln(line);
    stdout.flush();
}

// Keeps out input that didn't come from the harness. Called by SDL on whichever thread pushed or
// received the event.
extern(C) bool onlyHarnessInput(void* userdata, SDL_Event* e) nothrow @nogc
{
    switch (e.type)
    {
        case SDL_EventType.SDL_EVENT_MOUSE_MOTION: return e.motion.which == harnessDevice;
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP: return e.button.which == harnessDevice;
        case SDL_EventType.SDL_EVENT_MOUSE_WHEEL: return e.wheel.which == harnessDevice;
        case SDL_EventType.SDL_EVENT_KEY_DOWN:
        case SDL_EventType.SDL_EVENT_KEY_UP: return e.key.which == harnessDevice;
        case SDL_EventType.SDL_EVENT_TEXT_INPUT: return e.text.reserved == harnessDevice;
        case SDL_EventType.SDL_EVENT_TEXT_EDITING: return e.edit.reserved == harnessDevice;
        // A drag from another app: the desktop's own, should one pass over the window, would upset the tests
        case SDL_EventType.SDL_EVENT_DROP_BEGIN:
        case SDL_EventType.SDL_EVENT_DROP_POSITION:
        case SDL_EventType.SDL_EVENT_DROP_FILE:
        case SDL_EventType.SDL_EVENT_DROP_TEXT:
        case SDL_EventType.SDL_EVENT_DROP_COMPLETE: return e.drop.reserved == harnessDevice;
        // Where the real pointer is and which window has focus are the desktop's business; the
        // tests assume the pointer is where they put it and the window keeps focus
        case SDL_EventType.SDL_EVENT_WINDOW_MOUSE_ENTER:
        case SDL_EventType.SDL_EVENT_WINDOW_MOUSE_LEAVE:
        case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED:
        case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_LOST:
            return false;
        default:
            return true;
    }
}
