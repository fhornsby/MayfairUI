module mayfair.windowing.app;
import std.stdio;
import mayfair.log;
import sdl;
import sdl.hints;
import sdl.error;
import sdl.surface;
import sdl.cpuinfo : SDL_GetNumLogicalCPUCores;
import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp, strlen;
import std.string;
import core.time : Duration, MonoTime;
import mayfair.animation;
import mayfair.autowire : currentServices, newServices, Services;
import mayfair.renderers;
import mayfair.widgets;
import mayfair.widgets.styling : applyCss;
import mayfair.theme : Theme;
import mayfair.trace;
import mayfair.accessibility;
import mayfair.windowing.platform;
import mayfair.filechooser : FileChooser;
import mayfair.windowing.decorations;
import mayfair.windowing.window;


/*
    Each time round the loop in run(), a frame goes through five phases in order:

      1. Events   handleEvent()  turn SDL events into changes to the UI's state
      2. Update   update()       run the app's own code: callbacks, timers, animations
      3. Layout   layout()       work out sizes and positions
      4. Paint    paint()        update the ThorVG scene to match
      5. Present  present()      the GPU draws the scene and the frame goes to the window

    A phase only runs when something earlier said it's needed (needsLayout, needsPaint, needsPresent),
    so an expose event only re-presents, and nothing runs while the app is idle. The exception is an
    animation: while one is running the loop stops waiting for events and wakes once a display refresh
    to advance it, then goes back to sleeping once it's done.

    There's one loop however many windows the app has open (see Window): events are handed to the
    window they're for, and layout, paint and present run for each window that needs them.

    Phases 1 and 3-5 run every frame, so they're @nogc nothrow, and the event watch (a C callback) needs
    them to be. Update isn't: it's where code written by the app's users runs, and that's free to use the
    GC. So handleEvent() only records what happened, and update() is where the app hears about it.
*/
class App
{
private:
//App variables
string title;
//The windows, the main one first, in the order they were shown; and the main one
Window[] _windows;
Window _main;
//The pointer's shape, and SDL's cursors for each, made as they're first wanted
Cursor shownCursor = Cursor.default_;
SDL_Cursor*[Cursor.max + 1] cursors;
//Accessibility
uint accessibilityEventType; // the SDL event type AccessKit's requests arrive as
//What later windows are made like, once the main one's open (see adopt)
bool desktopDecorates;     // whether the desktop draws windows' title bars, where it's asked
bool wayland;              // whether SDL's on Wayland
const(char)* rendererName; // the renderer the first window started
//Frame state
bool running;
ulong lastUpdate;          // when update() last ran, on traceNow()'s clock
//What views' @autowired fields are filled with (see mayfair.autowire)
Services services;
//Input waiting for update() to hand to the scenes, in the order it came, whichever window it's for
struct QueuedInput {
    SDL_Event event;
    size_t textStart, textLength; // where a text event's text was copied to in inputText
}
QueuedInput[64] inputEvents;
size_t inputEventCount;
char[4096] inputText;
size_t inputTextUsed;
//Garbage collection: see collectGarbage()
size_t liveAfterCollect;   // bytes in use after the last collection
ulong lastCollectPause;    // how long it took, in nanoseconds, on traceNow()'s clock
size_t collections;        // druntime's count of collections, as of the loop's last look, while tracing
size_t collectionsBetween; // how many of them collectGarbage() made
size_t collectionsTraced, collectionsBetweenTraced; // both, as of the last frame traced

/// The open window SDL knows by `id`, if it's one of ours.
Window windowFor(SDL_WindowID id) nothrow @nogc {
    if (!id)
        return null;
    foreach (w; _windows)
        if (w.sdl && SDL_GetWindowID(w.sdl) == id)
            return w;
    return null;
}

/*
    Mouse and keyboard events are for widgets, whose handlers are the app's code and run in update(),
    so here they are only queued. Only where a run of motion ends up matters, so it's kept as one
    event: a fast mouse sends several per frame.
*/
void queueInputEvent(ref const SDL_Event event) nothrow @nogc {
    if (event.type == SDL_EventType.SDL_EVENT_MOUSE_MOTION && inputEventCount > 0
        && inputEvents[inputEventCount - 1].event.type == SDL_EventType.SDL_EVENT_MOUSE_MOTION
        && inputEvents[inputEventCount - 1].event.motion.windowID == event.motion.windowID) {
        inputEvents[inputEventCount - 1].event = event;
        return;
    }
    if (inputEventCount == inputEvents.length) {
        trace("input dropped an event, queue full");
        return;
    }
    QueuedInput queued;
    queued.event = event;

    // A text event's text is SDL's, and it frees it on the next poll, which comes before update()
    // gets to it. So it's copied as it arrives.
    const(char)* text = event.type == SDL_EventType.SDL_EVENT_TEXT_INPUT ? event.text.text
                      : event.type == SDL_EventType.SDL_EVENT_TEXT_EDITING ? event.edit.text : null;
    if (text) {
        const length = strlen(text);
        if (inputTextUsed + length > inputText.length) {
            trace("input dropped %zu bytes of text, buffer full", length);
            return;
        }
        inputText[inputTextUsed .. inputTextUsed + length] = text[0 .. length];
        queued.textStart = inputTextUsed;
        queued.textLength = length;
        inputTextUsed += length;
    }
    inputEvents[inputEventCount++] = queued;
}

/// 1. Events: records what one SDL event changes. Anything the app's own code needs to hear about
/// is passed on in update(), so this can stay @nogc.
void handleEvent(ref const SDL_Event event) nothrow @nogc {
    if (event.type >= SDL_EventType.SDL_EVENT_WINDOW_FIRST && event.type <= SDL_EventType.SDL_EVENT_WINDOW_LAST) {
        trace("event %-19s %5d %5d  window %u  queued %.2f ms ago", windowEventName(event.type),
              event.window.data1, event.window.data2, event.window.windowID, traceMs(event.common.timestamp, traceNow()));
        if (auto w = windowFor(event.window.windowID))
            if (w.handleWindowEvent(event))
                queueInputEvent(event);
        return;
    }

    switch (event.type) {
        case SDL_EventType.SDL_EVENT_SYSTEM_THEME_CHANGED:
            // The desktop went light or dark: restyled in the next update, if the scene follows it
            const scheme = systemColourScheme();
            foreach (w; _windows)
                if (w.sdl && scheme != w._scene.platformColourScheme) {
                    w._scene.platformColourScheme = scheme;
                    w._scene.restyleAll();
                }
            break;
        case SDL_EventType.SDL_EVENT_QUIT:
            running = false;
            break;
        case SDL_EventType.SDL_EVENT_KEY_DOWN:
        case SDL_EventType.SDL_EVENT_KEY_UP:
            if (windowFor(event.key.windowID))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_TEXT_INPUT:
            if (windowFor(event.text.windowID))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_TEXT_EDITING:
            if (windowFor(event.edit.windowID))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_MOTION:
            if (windowFor(event.motion.windowID))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
            if (windowFor(event.button.windowID))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_WHEEL:
            if (windowFor(event.wheel.windowID))
                queueInputEvent(event);
            break;
        default:
            // AccessKit's requests, posted from its own thread, and Platform.runLater()'s tasks.
            // They're for the widgets, so they wait for update() like the rest of the input, and
            // in order with it.
            if ((event.type == accessibilityEventType && windowFor(event.user.windowID))
                || event.type == laterEventType)
                queueInputEvent(event);
            break;
    }
}

/// Which window an event queued for update() is for: null for Platform.runLater()'s, which
/// are no window's. Looked up as it's handed on, as the window may have closed since.
Window windowOf(ref const SDL_Event event) nothrow @nogc {
    if (event.type >= SDL_EventType.SDL_EVENT_WINDOW_FIRST && event.type <= SDL_EventType.SDL_EVENT_WINDOW_LAST)
        return windowFor(event.window.windowID);
    switch (event.type) {
        case SDL_EventType.SDL_EVENT_KEY_DOWN:
        case SDL_EventType.SDL_EVENT_KEY_UP:
            return windowFor(event.key.windowID);
        case SDL_EventType.SDL_EVENT_TEXT_INPUT: return windowFor(event.text.windowID);
        case SDL_EventType.SDL_EVENT_TEXT_EDITING: return windowFor(event.edit.windowID);
        case SDL_EventType.SDL_EVENT_MOUSE_MOTION: return windowFor(event.motion.windowID);
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
            return windowFor(event.button.windowID);
        case SDL_EventType.SDL_EVENT_MOUSE_WHEEL: return windowFor(event.wheel.windowID);
        default:
            return event.type == accessibilityEventType ? windowFor(event.user.windowID) : null;
    }
}

/*
    2. Update: where the app's own code runs -- widget handlers for the input queued above, then
    animations. Not @nogc, as that code may use the GC.

    If the last frame laid anything out, the pointer is checked against the new layout first, since
    it may be over something else now without having moved.

    It's also where the nodes of collected widgets are freed, being the UI thread with nothing else
    using Yoga, and where windows closed during it are taken down, once nothing of theirs is
    running.

    Whatever it changes, it says so the way it would anywhere else: a widget invalidates itself, or
    marks its Yoga node dirty. So afterwards each window asks its scene rather than being told.
*/
void update() {
    freeRetiredNodes();
    foreach (w; _windows)
        if (w.sdl)
            w.beforeInput();
    // By index, and to the count as it stands now: a handler can show a window, which goes on the end
    for (size_t i = 0; i < inputEventCount; i++) {
        auto queued = inputEvents[i];
        const text = inputText[queued.textStart .. queued.textStart + queued.textLength];
        if (queued.event.type == laterEventType) {
            foreach (task; Platform.take()) {
                // A task that throws is the app's bug, not a reason to stop the UI
                try
                    task();
                catch (Exception e)
                    logError("Platform.runLater task failed: %.*s", cast(int) e.msg.length, e.msg.ptr);
            }
        }
        else if (auto w = windowOf(queued.event))
            if (!w._closing)
                w.dispatchInputEvent(queued.event, text);
    }
    inputEventCount = 0;
    inputTextUsed = 0;

    lastUpdate = traceNow();
    pulseAnimations(MonoTime.currTime);
    // By index, as a window's handlers may show another
    for (size_t i = 0; i < _windows.length; i++)
        if (_windows[i].sdl && !_windows[i]._closing)
            _windows[i].afterInput();
    updateCursor();
    takeDownClosed();
}

/// Takes down the windows closed since the last time, and stops once none are left.
void takeDownClosed() {
    for (size_t i = 0; i < _windows.length;) {
        auto w = _windows[i];
        if (!w._closing) {
            i++;
            continue;
        }
        // Owned windows first: SDL takes them down with their owner, which would leave them dangling
        foreach (child; _windows)
            if (child._owner is w && !child._closing)
                child.close();
        if (w.sdl && w._owner && w._owner.sdl)
            SDL_RaiseWindow(w._owner.sdl); // the one it was over, back to the front
        w.takeDown();
        w._shown = false;
        w._closing = false;
        import std.algorithm : remove;
        _windows = _windows.remove(i);
        if (w._onClosed) {
            try
                w._onClosed();
            catch (Exception e)
                logError("A window's onClosed failed: %.*s", cast(int) e.msg.length, e.msg.ptr);
        }
        i = 0; // its handler, or its owned windows, may have closed others
    }
    if (running && !_windows.length) {
        trace("loop  the last window's closed");
        running = false;
    }
}

/// Shows the pointer shape the widget under it asks for, in whichever window it's over.
void updateCursor() {
    auto focus = windowFor(SDL_GetWindowID(SDL_GetMouseFocus()));
    if (!focus)
        return;
    const wanted = focus._scene.currentCursor();
    if (wanted == shownCursor)
        return;
    shownCursor = wanted;
    if (!cursors[wanted])
        cursors[wanted] = SDL_CreateSystemCursor(systemCursor(wanted));
    if (cursors[wanted])
        SDL_SetCursor(cursors[wanted]);
}

/*
    How long the loop can wait for an event before a running animation needs its next pulse, in
    milliseconds. One changing every frame wants the next display refresh, rounded down so it's
    early rather than late; one waiting for a set moment, like a caret's next blink, wants that
    moment, rounded up so it doesn't wake just short of it and have to go round again. With
    windows on displays of different rates, the fastest's.
*/
int msUntilNextPulse() nothrow @nogc {
    const wanted = untilNextPulse();
    const now = traceNow();
    ulong period = ulong.max;
    bool paced = true;
    foreach (w; _windows)
        if (w.sdl) {
            if (w.framePeriod < period)
                period = w.framePeriod;
            paced &= w.renderer.pacedByDisplay();
        }
    if (period == ulong.max)
        period = 16_666_667;
    // A renderer whose present waits for the display paces frames itself, and a timer of the
    // loop's own, knowing nothing of when the display refreshes, would make it miss them. So the
    // timer only stops it running flat out if the present stops waiting: a hidden window, say.
    const frameDue = lastUpdate + (paced ? period / 2 : period);
    const untilFrame = frameDue > now ? cast(long)((frameDue - now) / 1_000_000) : 0;
    if (wanted == Duration.zero)
        return cast(int) untilFrame;
    const ns = wanted.total!"nsecs";
    const ms = (ns + 999_999) / 1_000_000;
    return cast(int)(ms > untilFrame ? (ms < int.max ? ms : int.max) : untilFrame);
}

/*
    Collects garbage while the loop would otherwise be waiting. Left to itself, druntime collects
    when an allocation finds the heap full, and on this thread that's in update(): layout, paint
    and present are @nogc, but update() runs the app's code, and is part of the frame, so its pause
    makes the frame late. Collecting here, between frames, keeps the heap from filling up, so that
    mostly doesn't happen. It isn't prevented: GC.disable() would do that, but then a background
    thread allocating while the loop sleeps would grow the heap with nothing to collect it, and
    druntime's own collections are what keep that in check.

    It only collects once enough has been allocated to be worth the pause: a keystroke's few bytes
    aren't worth scanning the heap for. Enough is Theme.gc_min_growth, or a quarter of what was live
    after the last collection if that's more, as a big heap takes longer to scan. While something's
    animating the next frame is due soon, so it only collects if the last collection's pause fits
    before then -- unless the heap has grown past Theme.gc_max_growth, when a frame is worth losing
    to keep it in check. The time it takes comes out of the wait: the wait is to the next frame, not
    for a length of time.
*/
void collectGarbage(bool animating) nothrow {
    import core.memory : GC;
    const used = GC.stats().usedSize;
    const grown = used > liveAfterCollect ? used - liveAfterCollect : 0;
    const enough = liveAfterCollect / 4 > Theme.gc_min_growth ? liveAfterCollect / 4 : Theme.gc_min_growth;
    if (grown < enough)
        return;
    if (animating && grown < Theme.gc_max_growth
        && cast(ulong) msUntilNextPulse() * 1_000_000 < lastCollectPause)
        return; // no time before the next frame: the next wait, or the one after
    const start = traceNow();
    GC.collect();
    collectionsBetween++;
    const end = traceNow();
    lastCollectPause = end - start;
    liveAfterCollect = GC.stats().usedSize;
    trace("gc    collected %.1f MB in %.2f ms, %.1f MB live", (used - liveAfterCollect) / 1048576.0,
          traceMs(start, end), liveAfterCollect / 1048576.0);
}

/// Runs whichever of layout, paint and present each window needs, in order.
void render() nothrow @nogc {
    foreach (w; _windows) {
        if (!w.sdl)
            continue;
        ulong layoutNs, paintNs, presentNs;
        if (!w.render(layoutNs, paintNs, presentNs))
            continue;
        // "animating" tells a frame an animation asked for from one an event caused, for plotting frame pacing.
        // "gc" is how many collections there were since the frame before, druntime's own and
        // collectGarbage()'s, and "between" how many were collectGarbage()'s, in the wait before it.
        trace("frame %dx%d  layout %.2f  paint %.2f  present %.2f  total %.2f ms  animating %d  gc %d  between %d  window %u",
              w.viewWidth, w.viewHeight, layoutNs / 1e6, paintNs / 1e6, presentNs / 1e6,
              (layoutNs + paintNs + presentNs) / 1e6, cast(int) animationsRunning(),
              cast(int)(collections - collectionsTraced), cast(int)(collectionsBetween - collectionsBetweenTraced),
              SDL_GetWindowID(w.sdl));
        collectionsTraced = collections;
        collectionsBetweenTraced = collectionsBetween;
    }
}

/*
    The renderers a window opened after the first tries: a new one of the kind the first
    started, software or not, as the first has already turned down what it was going to; then
    the CPU's, which always can.
*/
Renderer[] renderersLikeFirst() nothrow {
    version (Emscripten)
        return [cast(Renderer) new CpuRenderer];
    else {
    if (rendererName && strcmp(rendererName, "webgpu") == 0)
        return [cast(Renderer) new WebGpuRenderer(true), new CpuRenderer];
    if (rendererName && strcmp(rendererName, "opengl") == 0)
        return [cast(Renderer) new OpenGlRenderer(true), new CpuRenderer];
    return [cast(Renderer) new CpuRenderer];
    }
}

/// Opens `w`, now the loop's running. False, with it taken out again, if it couldn't be.
bool open(Window w) {
    auto candidates = rendererName ? renderersLikeFirst() : chooseRenderers();
    if (!w.open(candidates, desktopDecorates, wayland, accessibilityEventType)) {
        import std.algorithm : remove;
        foreach (i, other; _windows)
            if (other is w) {
                _windows = _windows.remove(i);
                break;
            }
        w._shown = false;
        return false;
    }
    if (!rendererName)
        rendererName = w.renderer.name();
    trace("open  window %u, renderer %s", SDL_GetWindowID(w.sdl), w.renderer.name());
    return true;
}

package(mayfair):

/// Takes on a window being shown: opened now if the loop's running, or as it starts.
void adopt(Window w) {
    _windows ~= w;
    if (running)
        open(w);
}

/// Lets go of a window closed before it was ever opened.
void forget(Window w) {
    import std.algorithm : remove;
    foreach (i, other; _windows)
        if (other is w) {
            _windows = _windows.remove(i);
            break;
        }
    w._shown = false;
    w._closing = false;
}

public:

    this(string title){
        this.title = title;
        _main = new Window(title);
        services = newServices();
        // The App made last is the one views find their services in: one runs at a time
        currentApp = this;
        currentServices = services;
        // How text is antialiased, from the desktop's settings (see mayfair.desktop), before
        // anything's drawn: the first time they're read
        import mayfair.text.raster : useDesktopTextSettings;
        useDesktopTextSettings();
    }

    /*
        Services: what the app's views share -- a database, a web API's client, the user's
        settings -- by type, for their @autowired fields (see mayfair.autowire). Register them
        before loading the views that ask for them:

            app.registerService(new Library("books.db"))
               .registerService!Storage(new DiskStorage);   // for fields that are a Storage

        Each replaces anything registered as the same type before. Safe from any thread.
    */
    App registerService(T)(T service) if (is(T == class) || is(T == interface)) {
        services.add!T(service);
        return this;
    }

    /// The service registered as T. Throws an AutowireException if there isn't one.
    T service(T)() if (is(T == class) || is(T == interface)) {
        return services.get!T();
    }

    /// Whether a service is registered as T.
    bool hasService(T)() if (is(T == class) || is(T == interface)) {
        return services.has!T();
    }

    /// Takes away the service registered as T, if there is one.
    void unregisterService(T)() if (is(T == class) || is(T == interface)) {
        services.remove!T();
    }

    /// The App made last, the one running if one is: how code with no App to hand reaches its
    /// services, App.current.service!Library(). The same on every thread; null before one's made.
    static App current() nothrow @nogc {
        return currentApp;
    }

    /*
        The main window: the one run() opens, which setSize, scene and the others below are for.
        Others are opened with Window's show() (see Window).
    */
    Window window() { return _main; }

    /// The windows open, the main one first, and any shown before run() that it's to open.
    Window[] windows() nothrow @nogc { return _windows; }

    // The main window's, for an app with just the one: see Window for each
    void setSize(int width, int height){ _main.setSize(width, height); }
    void setMaximised(bool maximised){ _main.setMaximised(maximised); }
    int restoredWidth() const { return _main.restoredWidth; }
    int restoredHeight() const { return _main.restoredHeight; }
    bool wasMaximised() const { return _main.wasMaximised; }
    void setMinSize(int width, int height){ _main.setMinSize(width, height); }
    void setMaxSize(int width, int height){ _main.setMaxSize(width, height); }
    @property void scene(Scene scene){ _main.scene = scene; }
    @property inout(Scene) scene() inout { return _main._scene; }
    void setTranslucent(bool translucent) { _main.setTranslucent(translucent); }
    bool translucent() const { return _main.translucent; }
    void raise() nothrow @nogc { _main.raise(); }

    /*
        The app's id: reverse-DNS, as "org.gnome.Maps", and the name of its .desktop file without
        the .desktop. The desktop matches the window to that file by it -- for its icon and name in
        the dock and the task switcher -- as Wayland's app_id and X11's WM_CLASS. Without one the
        window shows as an unknown app. Set it before run().
    */
    void setId(string id){
        _id = id;
    }

    private string _id;

    /*
        Ends run(), closing every window, once what's being handled now is done: for a Quit menu
        item, say. Needs no App to hand, and is safe from any thread. Before run() it does nothing.
        The windows' onCloseRequest isn't asked.
    */
    static void quit() nothrow @nogc {
        SDL_Event event;
        event.type = SDL_EventType.SDL_EVENT_QUIT;
        SDL_PushEvent(&event);
    }

    /// Opens the main window, and any shown already, and runs until the last is closed or quit() is called.
    void run(){
        SDL_SetHint(SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "1");
        // Closing the last window ends the loop here, once that window's had its say (see
        // Window.onCloseRequest), rather than SDL sending a quit as it's asked to close
        SDL_SetHint(SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");

        // Before stderr is quietened below, so a word about MAYFAIR_RENDERER gets out
        auto candidates = chooseRenderers();

        // Who draws the title bar: the app, if it gave the scene one; otherwise the desktop, where
        // it will -- and where it won't, as on GNOME, a plain one of Mayfair's. Decided before SDL
        // starts, as SDL would otherwise have libdecor draw it, with GTK.
        const appBar = _main._scene && _main._scene.titleBarChosen;
        wayland = onWayland();
        desktopDecorates = !wayland || compositorDecorates();
        const drawsDecorations = appBar || (wayland && !desktopDecorates);
        if (drawsDecorations && wayland)
        {
            keepLibdecorPluginsAway(true);
            quietStderr(true); // libdecor says, twice, that it found no plugins: what was meant
        }

        // Before SDL starts, which is when it reads them: the window's app_id, and the app's name
        SDL_SetAppMetadata(title.toStringz(), null, _id.length ? _id.toStringz() : null);
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            quietStderr(false);
            keepLibdecorPluginsAway(false);
            logError("SDL_Init failed: %s", SDL_GetError());
            return;
        }
        if (drawsDecorations && wayland)
        {
            quietStderr(false);
            keepLibdecorPluginsAway(false);
        }
        scope(exit) SDL_Quit();
        traceOpen();
        scope(exit) traceClose();
        // Which SDL chose, now it has: the window's blur and moving go by that, not the guess
        const driver = SDL_GetCurrentVideoDriver();
        wayland = driver && strcmp(driver, "wayland") == 0;

        // ThorVG's engine is held for as long as the loop runs, as well as by each window's
        // renderer, so it outlasts the windows closing: the decodings images keep are ThorVG's
        // (see releaseKeptDecodings), and go before it does
        import mayfair.renderers.thorvg : tvg_engine_init, tvg_engine_term;
        tvg_engine_init(SDL_GetNumLogicalCPUCores());
        scope(exit) tvg_engine_term();
        scope(exit) releaseKeptDecodings();
        rendererName = null;

        // AccessKit's requests come as an SDL event, one type for every window's
        accessibilityEventType = SDL_RegisterEvents(1);

        // The main window first, then any shown before run(), in the order they were
        {
            import std.algorithm : countUntil, remove;
            const at = _windows.countUntil(_main);
            if (at >= 0)
                _windows = _windows.remove(at);
            _windows = _main ~ _windows;
            _main._shown = true;
            _main._closing = false;
        }
        // Whatever happens, every window's taken down before SDL goes (scope(exit)s run in reverse)
        scope(exit) {
            foreach_reverse (w; _windows) {
                w.takeDown();
                w._shown = w._closing = false;
            }
            _windows = null;
        }
        running = true; // from here, a window shown is opened straight away
        if (!openMain(candidates))
            return;
        foreach (w; _windows[1 .. $].dup)
            open(w);
        trace("start video driver %s, renderer %s", SDL_GetCurrentVideoDriver(), rendererName);

        SDL_AddEventWatch(&windowEventWatch, cast(void*) this);
        scope(exit) SDL_RemoveEventWatch(&windowEventWatch, cast(void*) this);

        // Platform.runLater() can wake the loop from now on, with tasks given before it started too
        laterEventType = SDL_RegisterEvents(1);
        Platform.wakeWith(&postLaterEvent);
        scope(exit) Platform.wakeWith(null);

        scope(exit) foreach (ref c; cursors) if (c) { SDL_DestroyCursor(c); c = null; }

        // Collections before now -- building the widgets, say -- aren't any frame's
        if (tracing()) {
            import core.memory : GC;
            collections = collectionsTraced = GC.profileStats().numCollections;
        }

        // First frame, without waiting for an event
        render();

        version (Emscripten)
        {
            // A browser page can't sit and wait: it hands control back to the browser after each
            // frame, and the browser calls it again when it's ready for the next. So in a browser
            // each frame is one turn of the loop, waiting for nothing. Starting the browser's loop
            // throws past run() and main(), leaving everything above as it is for as long as the
            // page is open: none of the scope(exit)s run, and the D runtime isn't shut down.
            browserApp = this;
            emscripten_set_main_loop(&browserFrame, 0, true);
        }
        while (running && turn(true)) {}
        running = false;
    }

    // Opens the main window with the renderers to try first
    private bool openMain(Renderer[] candidates) {
        if (!_main.open(candidates, desktopDecorates, wayland, accessibilityEventType)) {
            _windows = _windows[1 .. $];
            _main._shown = false;
            return false;
        }
        rendererName = _main.renderer.name();
        return true;
    }

    /*
        One turn of the loop: sleep until an event arrives -- if `wait` says to -- then handle
        everything pending before rendering once. Rendering after SDL has handled all the events
        matters when resizing on Wayland: SDL applies a new size and only then tells the compositor
        it accepted it, and a frame committed in between doesn't count as the answer. It also means a
        burst of events costs one frame instead of one each. While an animation runs, the wait is
        cut short when its next frame is due. False if SDL can't wait any more, to stop.
    */
    private bool turn(bool wait) {
        SDL_Event event;
        // Before the wait, which it then shortens by as long as it took
        collectGarbage(animationsRunning());
        const waitStart = traceNow();
        bool gotEvent;
        bool repickPending;
        foreach (w; _windows)
            repickPending |= w.repickPending;
        // While something's animating, the next frame is when the display's ready for it, and
        // not before: the repick below waits for it too, rather than the loop going round as
        // fast as it can -- which, with a present mode that doesn't wait for the display, is
        // hundreds of frames a second nobody sees
        if (!wait) {
            gotEvent = SDL_PollEvent(&event);
        } else if (animationsRunning()) {
            gotEvent = SDL_WaitEventTimeout(&event, msUntilNextPulse());
        } else if (repickPending) {
            gotEvent = SDL_PollEvent(&event); // it's for update(), which should run now
        } else if (FileChooser.waiting()) {
            // The dialog's answer comes over D-Bus, and SDL only reads that when it pumps
            // events: waiting on the window system alone, it'd sit there until the next
            // input. So while one's up, the loop looks in now and then.
            gotEvent = SDL_WaitEventTimeout(&event, 100);
        } else {
            if (!SDL_WaitEvent(&event))
                return false;
            gotEvent = true;
        }
        const woke = traceNow();

        int handled = 0;
        if (gotEvent) {
            do {
                handleEvent(event);
                handled++;
            } while (SDL_PollEvent(&event));
        }
        // The time in SDL_WaitEvent includes SDL handling what the window system sent, e.g. libdecor
        // redrawing the title bar during a resize, as well as time spent idle
        foreach (w; _windows)
            if (w.sdl) {
                w.mover.dispatch();
                w.blur.dispatch();
                w.applyTranslucency(); // the compositor can stop blurring, or start
            }
        trace("loop  in SDL_WaitEvent %.2f ms, then handled %d events in %.2f ms",
              traceMs(waitStart, woke), handled, traceMs(woke, traceNow()));

        update();

        if (running) {
            if (tracing()) {
                import core.memory : GC;
                collections = GC.profileStats().numCollections; // for the frame's trace line
            }
            render();
            foreach (w; _windows)
                if (w.sdl)
                    w.updateAccessibility();
        }
        return true;
    }

}

version (Emscripten)
{
    // The browser's loop, which calls browserFrame once a frame: see App.run
    private extern (C) void emscripten_set_main_loop(void function() nothrow, int fps, bool simulateInfiniteLoop) nothrow;
    private extern (C) void emscripten_cancel_main_loop() nothrow;
    private __gshared App browserApp;

    private extern (C) void browserFrame() nothrow
    {
        try
        {
            if (!browserApp.running || !browserApp.turn(false))
                emscripten_cancel_main_loop();
        }
        catch (Throwable t)
        {
            // Nothing above to catch it, as there is in run(): say what it was, and stop
            try logError("%.*s", cast(int) t.toString().length, t.toString().ptr); catch (Throwable) {}
            emscripten_cancel_main_loop();
        }
    }
}

/*
    Which renderers to try, in order. WebGPU first, everywhere: it's the default. When it can't
    start, or the only Vulkan is in software -- a VM whose virtual GPU passes OpenGL through but not
    Vulkan, say -- OpenGL, if it's on real hardware; then the CPU, which always can. The CPU one is
    also there for compositors where resizing a GPU surface is slow (GNOME resizes a Vulkan surface
    far less smoothly than KDE does). MAYFAIR_RENDERER=webgpu, opengl or cpu uses that one only,
    software or not.
*/
private Renderer[] chooseRenderers() nothrow
{
    version (Emscripten)
        return [cast(Renderer) new CpuRenderer]; // the only one in the browser, for now
    else {
    const(char)* choice = getenv("MAYFAIR_RENDERER");
    if (choice && *choice) {
        if (strcmp(choice, "cpu") == 0) return [cast(Renderer) new CpuRenderer];
        if (strcmp(choice, "opengl") == 0) return [cast(Renderer) new OpenGlRenderer(true)];
        if (strcmp(choice, "webgpu") == 0) return [cast(Renderer) new WebGpuRenderer(true)];
        logWarning("Unknown MAYFAIR_RENDERER '%s', using the default", choice);
    }
    return [cast(Renderer) new WebGpuRenderer, new OpenGlRenderer, new CpuRenderer];
    }
}

private SDL_SystemCursor systemCursor(Cursor c) nothrow @nogc
{
    final switch (c) {
        case Cursor.inherit:
        case Cursor.default_:         return SDL_SystemCursor.SDL_SYSTEM_CURSOR_DEFAULT;
        case Cursor.text:             return SDL_SystemCursor.SDL_SYSTEM_CURSOR_TEXT;
        case Cursor.hand:             return SDL_SystemCursor.SDL_SYSTEM_CURSOR_POINTER;
        case Cursor.crosshair:        return SDL_SystemCursor.SDL_SYSTEM_CURSOR_CROSSHAIR;
        case Cursor.wait:             return SDL_SystemCursor.SDL_SYSTEM_CURSOR_WAIT;
        case Cursor.move:             return SDL_SystemCursor.SDL_SYSTEM_CURSOR_MOVE;
        case Cursor.notAllowed:       return SDL_SystemCursor.SDL_SYSTEM_CURSOR_NOT_ALLOWED;
        case Cursor.resizeHorizontal: return SDL_SystemCursor.SDL_SYSTEM_CURSOR_EW_RESIZE;
        case Cursor.resizeVertical:   return SDL_SystemCursor.SDL_SYSTEM_CURSOR_NS_RESIZE;
    }
}

/// The App made last, for App.current.
private __gshared App currentApp;

/// The SDL event type Platform.runLater() wakes the loop with. One App runs at a time, so one will do.
private __gshared uint laterEventType;

private void postLaterEvent() nothrow @nogc
{
    SDL_Event event;
    event.type = laterEventType;
    SDL_PushEvent(&event); // safe from any thread
}

/// A readable name for the window events worth tracing.
private const(char)* windowEventName(uint type) nothrow @nogc
{
    switch (type) {
        case SDL_EventType.SDL_EVENT_WINDOW_SHOWN: return "SHOWN";
        case SDL_EventType.SDL_EVENT_WINDOW_EXPOSED: return "EXPOSED";
        case SDL_EventType.SDL_EVENT_WINDOW_RESIZED: return "RESIZED";
        case SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: return "PIXEL_SIZE_CHANGED";
        default: return "(other window event)";
    }
}

/*
    On Windows and macOS the OS takes over the main loop while the user drags the window edge, so the loop
    above can't render. SDL sends live-resize expose events (data1 == 1) from inside that OS loop instead, and
    event watches are called straight away, so those frames are rendered here. The size events queued during
    the drag aren't handled until it ends, so layout is redone every time. Wayland and X11 never send these.
*/
private extern(C) bool windowEventWatch(void* userdata, SDL_Event* event) nothrow @nogc
{
    auto self = cast(App) userdata;
    if (event.type == SDL_EventType.SDL_EVENT_WINDOW_EXPOSED && event.window.data1 == 1)
        if (auto w = self.windowFor(event.window.windowID)) {
            w.needsLayout = true;
            ulong layoutNs, paintNs, presentNs;
            w.render(layoutNs, paintNs, presentNs);
        }
    return true;
}

unittest
{
    import mayfair.autowire : AutowireException;

    static class Library
    {
    }

    static interface Storage
    {
    }

    static class Disk : Storage
    {
    }

    auto app = new App("Services");
    assert(App.current is app);
    auto library = new Library;
    app.registerService(library).registerService!Storage(new Disk);
    assert(app.service!Library() is library && app.hasService!Storage && !app.hasService!Disk);
    app.unregisterService!Library();
    assert(!app.hasService!Library);
    try
    {
        app.service!Library();
        assert(false);
    }
    catch (AutowireException e)
    {
    }

    // A new App starts with no services, and is the current one
    auto next = new App("Next");
    assert(App.current is next && !next.hasService!Storage && app.hasService!Storage);
}
