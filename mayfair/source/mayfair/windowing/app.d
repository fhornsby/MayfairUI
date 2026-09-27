module mayfair.windowing.app;
import std.stdio;
import sdl;
import sdl.hints;
import sdl.error;
import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp, strlen;
import std.string;
import core.time : Duration, MonoTime;
import mayfair.animation;
import mayfair.renderers;
import mayfair.widgets;
import mayfair.widgets.styling : applyCss;
import mayfair.theme : Theme;
import mayfair.trace;
import mayfair.accessibility;
import mayfair.windowing.accessibility;
import mayfair.windowing.platform;


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

    Phases 1 and 3-5 run every frame, so they're @nogc nothrow, and the event watch (a C callback) needs
    them to be. Update isn't: it's where code written by the app's users runs, and that's free to use the
    GC. So handleEvent() only records what happened, and update() is where the app hears about it.
*/
class App
{
private:
// Window window;
//SDL3 Variables
SDL_Window* window;
//Rendering
Renderer renderer;
//Layout
Scene _scene;
//App variables
string title;
//The pointer's shape, and SDL's cursors for each, made as they're first wanted
Cursor shownCursor = Cursor.default_;
SDL_Cursor*[Cursor.max + 1] cursors;
//Accessibility
AccessibilityAdapter accessibility;
uint accessibilityEventType; // the SDL event type AccessKit's requests arrive as
int height, width;
bool resizable;
//Frame state
bool running;
bool needsLayout = true;
bool needsPaint;
bool needsPresent;
int viewWidth, viewHeight; // drawable size in pixels, set by layout()
float scale = 1.0f;        // device pixels per point, set by updateScale()
bool scaleApplied;         // whether updateScale() has told the scene anything yet
ulong framePeriod;         // nanoseconds between display refreshes, set by updateRefreshRate()
ulong lastUpdate;          // when update() last ran, on traceNow()'s clock
//Input waiting for update() to hand to the scene
struct QueuedInput {
    SDL_Event event;
    size_t textStart, textLength; // where a text event's text was copied to in inputText
}
QueuedInput[64] inputEvents;
size_t inputEventCount;
char[4096] inputText;
size_t inputTextUsed;
//Text input: which widget it's on for, and where SDL was last told it is
Widget textInputWidget;
SDL_Rect textInputRect;
int textInputCursor;
bool repickPending;        // things moved, by layout or scrolling, so what's under the pointer may have too

/*
    HiDPI. Layout and paint work in points; the scene transform turns those into device pixels, so
    a point is the same physical size whatever the display. SDL_GetWindowDisplayScale() is the right
    factor: it combines the window's pixel density with the scale the user asked for (a 150% Windows
    display, or a Wayland fractional scale), which is what UI should be sized by. Yoga's point scale
    factor makes it round layout so edges land on whole device pixels, which matters most at the
    fractional scales, where otherwise adjacent boxes meet on a half pixel and the seam shows.
*/
void updateScale() nothrow @nogc {
    const reported = SDL_GetWindowDisplayScale(window);
    const next = reported > 0 ? reported : 1.0f; // 0 means SDL couldn't tell us
    // The first call has to go through even when the scale is exactly 1, because it is also what
    // hands the scene the renderer's supersample factor
    if (scaleApplied && next == scale)
        return;
    scale = next;
    scaleApplied = true;
    _scene.setScale(scale, renderer.renderScale());
    needsLayout = true;
    trace("scale %.2f device pixels per point", scale);
}

/// How often the window's display refreshes, which is how often a running animation gets a frame.
void updateRefreshRate() nothrow @nogc {
    const mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(window));
    const hz = mode && mode.refresh_rate > 0 ? mode.refresh_rate : 60.0f;
    framePeriod = cast(ulong)(1e9 / hz);
    trace("refresh %.2f Hz", hz);
}

/*
    Mouse and keyboard events are for widgets, whose handlers are the app's code and run in update(),
    so here they are only queued. Only where a run of motion ends up matters, so it's kept as one
    event: a fast mouse sends several per frame.
*/
void queueInputEvent(ref const SDL_Event event) nothrow @nogc {
    if (event.type == SDL_EventType.SDL_EVENT_MOUSE_MOTION && inputEventCount > 0
        && inputEvents[inputEventCount - 1].event.type == SDL_EventType.SDL_EVENT_MOUSE_MOTION) {
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

/*
    SDL gives mouse positions in window coordinates. Those are points only when the pixel density
    and the display scale agree, which they don't on, say, a 150% Windows display without a high
    density drawable, so go through pixels, which both are defined against.
*/
float toPoints(float windowCoordinate) nothrow @nogc {
    return windowCoordinate * SDL_GetWindowPixelDensity(window) / scale;
}

/// 1. Events: records what one SDL event changes. Anything the app's own code needs to hear about
/// is passed on in update(), so this can stay @nogc.
void handleEvent(ref const SDL_Event event) nothrow @nogc {
    if (event.type >= SDL_EventType.SDL_EVENT_WINDOW_FIRST && event.type <= SDL_EventType.SDL_EVENT_WINDOW_LAST)
        trace("event %-19s %5d %5d  queued %.2f ms ago", windowEventName(event.type),
              event.window.data1, event.window.data2, traceMs(event.common.timestamp, traceNow()));

    switch (event.type) {
        case SDL_EventType.SDL_EVENT_SYSTEM_THEME_CHANGED:
            // The desktop went light or dark: restyled in the next update, if the scene follows it
            const scheme = systemColourScheme();
            if (scheme != _scene.platformColourScheme) {
                _scene.platformColourScheme = scheme;
                _scene.restyleAll();
            }
            break;
        case SDL_EventType.SDL_EVENT_QUIT:
            running = false;
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            if (event.window.windowID == SDL_GetWindowID(window))
                needsLayout = true;
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_EXPOSED:
            if (event.window.windowID == SDL_GetWindowID(window))
                needsPresent = true;
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
            // The window moved to a display with a different scale
            if (event.window.windowID == SDL_GetWindowID(window))
                updateScale();
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_DISPLAY_CHANGED:
            if (event.window.windowID == SDL_GetWindowID(window))
                updateRefreshRate();
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED:
        case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_LOST:
            if (event.window.windowID == SDL_GetWindowID(window)) {
                accessibility.windowFocus(event.type == SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED);
                queueInputEvent(event);
            }
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_MOUSE_LEAVE:
            if (event.window.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_SHOWN:
        case SDL_EventType.SDL_EVENT_WINDOW_MOVED:
        case SDL_EventType.SDL_EVENT_WINDOW_RESIZED:
        case SDL_EventType.SDL_EVENT_WINDOW_MAXIMIZED:
        case SDL_EventType.SDL_EVENT_WINDOW_RESTORED:
            if (event.window.windowID == SDL_GetWindowID(window))
                accessibility.windowBoundsChanged();
            break;
        case SDL_EventType.SDL_EVENT_KEY_DOWN:
        case SDL_EventType.SDL_EVENT_KEY_UP:
            if (event.key.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_TEXT_INPUT:
            if (event.text.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_TEXT_EDITING:
            if (event.edit.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_MOTION:
            if (event.motion.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
            if (event.button.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_WHEEL:
            if (event.wheel.windowID == SDL_GetWindowID(window))
                queueInputEvent(event);
            break;
        default:
            // AccessKit's requests, posted from its own thread, and Platform.runLater()'s tasks.
            // They're for the widgets, so they wait for update() like the rest of the input, and
            // in order with it.
            if ((event.type == accessibilityEventType && event.user.windowID == SDL_GetWindowID(window))
                || event.type == laterEventType)
                queueInputEvent(event);
            break;
    }
}

/*
    2. Update: where the app's own code runs -- widget handlers for the input queued above, then
    animations. Not @nogc, as that code may use the GC.

    If the last frame laid anything out, the pointer is checked against the new layout first, since
    it may be over something else now without having moved.

    It's also where the nodes of collected widgets are freed, being the UI thread with nothing else
    using Yoga.

    Whatever it changes, it says so the way it would anywhere else: a widget invalidates itself, or
    marks its Yoga node dirty. So afterwards this asks the scene rather than being told.
*/
void update() {
    freeRetiredNodes();
    if (repickPending) {
        repickPending = false;
        _scene.repick();
    }
    foreach (ref queued; inputEvents[0 .. inputEventCount])
        dispatchInputEvent(queued.event, inputText[queued.textStart .. queued.textStart + queued.textLength]);
    inputEventCount = 0;
    inputTextUsed = 0;

    lastUpdate = traceNow();
    pulseAnimations(MonoTime.currTime);
    applyCss(_scene); // what the input and animations changed, restyled before layout

    updateTextInput();
    updateCursor();

    if (_scene.takePaintRequest())
        needsPaint = true;
    if (_scene.layoutNeeded())
        needsLayout = true;
}

/*
    Keeps SDL's text input switched on exactly while a widget that takes text has focus: on, it's
    what makes typed and input method events arrive, and on some platforms brings up an on-screen
    keyboard, so it's not left on for widgets that don't want it. While it's on, the input method is
    kept told where the widget is, so its candidate window sits by the text. That goes by where the
    widget was last painted, which update() is always after.
*/
void updateTextInput() {
    auto owner = _scene.textInputOwner();
    if (owner !is textInputWidget) {
        textInputWidget = owner;
        if (owner) {
            SDL_StartTextInput(window);
            textInputRect = SDL_Rect.init;
            textInputCursor = -1; // tell it where, below, even if it's the old place
        } else {
            SDL_StopTextInput(window);
        }
    }
    if (!owner)
        return;

    float x, y, w, h, caret;
    owner.textInputArea(x, y, w, h, caret);
    if (x != x) // NaN: not painted yet, so there's nowhere to say
        return;
    SDL_Rect rect = { toWindow(x), toWindow(y), toWindow(w), toWindow(h) };
    const cursor = toWindow(caret);
    if (rect != textInputRect || cursor != textInputCursor) {
        textInputRect = rect;
        textInputCursor = cursor;
        SDL_SetTextInputArea(window, &rect, cursor);
    }
}

/// Shows the pointer shape the widget under it asks for.
void updateCursor() {
    const wanted = _scene.currentCursor();
    if (wanted == shownCursor)
        return;
    shownCursor = wanted;
    if (!cursors[wanted])
        cursors[wanted] = SDL_CreateSystemCursor(systemCursor(wanted));
    if (cursors[wanted])
        SDL_SetCursor(cursors[wanted]);
}

/// The desktop's light or dark preference, which SDL reads from the XDG portal on Linux. Light
/// when there's none to read, as JavaFX's default is.
ColourScheme systemColourScheme() nothrow @nogc {
    return SDL_GetSystemTheme() == SDL_SystemTheme.SDL_SYSTEM_THEME_DARK ? ColourScheme.dark : ColourScheme.light;
}

/// Points back to SDL's window coordinates, the opposite of toPoints().
int toWindow(float points) nothrow @nogc {
    return cast(int)(points * scale / SDL_GetWindowPixelDensity(window) + 0.5f);
}

/*
    How many points one of SDL's wheel amounts is. SDL gives a wheel in notches, and a touchpad in
    tenths of a notch's worth of finger movement -- SDL divides the pixels Wayland gives it by ten
    -- and doesn't say which it's giving. The difference matters: a notch wants JavaFX's 40
    points, where a touchpad should follow the fingers.

    The amounts tell them apart. A wheel moves in whole notches, or a high-resolution one in
    eighths of one, where a touchpad's movement comes in 256ths of a pixel and is almost never
    exactly that. When it is, a touchpad's step is taken for a wheel's -- one in a few hundred,
    and a fraction of a notch at most. If SDL ever says which it is, this is the place to use it.
*/
float wheelPoints(float amount) nothrow @nogc {
    if (fromWheel(amount))
        return amount * Theme.scroll_step;
    return amount * 10; // SDL's tenth of a notch was 10 pixels, which on a touchpad are points
}

/// Whether one of SDL's amounts is a wheel's, as wheelPoints() tells: whole eighths of a notch.
bool fromWheel(float amount) nothrow @nogc {
    import std.math : abs, round;
    const eighths = amount * 8;
    return abs(eighths - round(eighths)) < 1e-4f;
}

void dispatchInputEvent(ref const SDL_Event event, const(char)[] text) {
    // Mouse events don't carry the modifiers in SDL, so they're read as each is handed on
    const mods = SDL_GetModState();
    _scene.modifiers((mods & SDL_Keymod.KMOD_SHIFT) != 0, (mods & SDL_Keymod.KMOD_CTRL) != 0,
                     (mods & SDL_Keymod.KMOD_ALT) != 0, (mods & SDL_Keymod.KMOD_GUI) != 0);
    switch (event.type) {
        case SDL_EventType.SDL_EVENT_MOUSE_MOTION:
            _scene.mouseMoved(toPoints(event.motion.x), toPoints(event.motion.y));
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
            _scene.mousePressed(toPoints(event.button.x), toPoints(event.button.y),
                                mouseButton(event.button.button), event.button.clicks);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
            _scene.mouseReleased(toPoints(event.button.x), toPoints(event.button.y),
                                 mouseButton(event.button.button), event.button.clicks);
            break;
        case SDL_EventType.SDL_EVENT_MOUSE_WHEEL:
            const device = fromWheel(event.wheel.x) && fromWheel(event.wheel.y) ? ScrollDevice.wheel : ScrollDevice.touchpad;
            float dx = wheelPoints(event.wheel.x), dy = wheelPoints(event.wheel.y);
            // Shift turns the wheel sideways, as it does everywhere else on the desktop
            if ((mods & SDL_Keymod.KMOD_SHIFT) && dx == 0) {
                dx = dy;
                dy = 0;
            }
            // SDL's x is positive to the right, where a ScrollEvent's is the way the content moves
            _scene.scrolled(toPoints(event.wheel.mouse_x), toPoints(event.wheel.mouse_y), -dx, dy, device,
                            event.wheel.timestamp / 1e9);
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_MOUSE_LEAVE:
            _scene.mouseLeft();
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED:
            _scene.windowFocus(true);
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_LOST:
            _scene.windowFocus(false);
            break;
        case SDL_EventType.SDL_EVENT_KEY_DOWN:
            _scene.keyPressed(keyEvent(event.key, KeyEventType.pressed));
            break;
        case SDL_EventType.SDL_EVENT_KEY_UP:
            _scene.keyReleased(keyEvent(event.key, KeyEventType.released));
            break;
        case SDL_EventType.SDL_EVENT_TEXT_INPUT:
            _scene.keyTyped(text.idup);
            break;
        case SDL_EventType.SDL_EVENT_TEXT_EDITING:
            _scene.inputMethodTextChanged(text.idup, event.edit.start, event.edit.length);
            break;
        default:
            if (event.type == laterEventType) {
                foreach (task; Platform.take()) {
                    // A task that throws is the app's bug, not a reason to stop the UI
                    try
                        task();
                    catch (Exception e)
                        fprintf(stderr, "Platform.runLater task failed: %.*s\n", cast(int) e.msg.length, e.msg.ptr);
                }
            }
            else if (event.type == accessibilityEventType) {
                if (event.user.code == AccessibilityAdapter.Request.activate)
                    accessibility.requestFullTree();
                else {
                    ulong target;
                    accesskit_action action;
                    AccessibleActionData data;
                    AccessibilityAdapter.takeAction(cast(void*) event.user.data1, target, action, data); // ours to free
                    _scene.performAccessibleAction(target, action, data);
                }
            }
            break;
    }
}

/*
    How long the loop can wait for an event before a running animation needs its next pulse, in
    milliseconds. One changing every frame wants the next display refresh, rounded down so it's
    early rather than late; one waiting for a set moment, like a caret's next blink, wants that
    moment, rounded up so it doesn't wake just short of it and have to go round again.
*/
int msUntilNextPulse() nothrow @nogc {
    const wanted = untilNextPulse();
    const now = traceNow();
    const frameDue = lastUpdate + framePeriod;
    const untilFrame = frameDue > now ? cast(long)((frameDue - now) / 1_000_000) : 0;
    if (wanted == Duration.zero)
        return cast(int) untilFrame;
    const ns = wanted.total!"nsecs";
    const ms = (ns + 999_999) / 1_000_000;
    return cast(int)(ms > untilFrame ? (ms < int.max ? ms : int.max) : untilFrame);
}

/*
    Tells assistive technology what changed. After rendering, because a widget's bounds are where
    it was painted. It isn't a frame phase of its own, as it's the widgets describing themselves,
    which is their code, not the kit's, and so free to allocate.
*/
void updateAccessibility() {
    const pointsToWindow = scale / SDL_GetWindowPixelDensity(window);
    if (accessibility.updateNeeded(_scene, pointsToWindow))
        accessibility.update(_scene, title, pointsToWindow);
}

/// 3. Layout: Yoga works out every box's size and position for the current window size.
void layout() nothrow @nogc {
    SDL_GetWindowSizeInPixels(window, &viewWidth, &viewHeight); // pixels: what the renderer needs
    _scene.layout(viewWidth / scale, viewHeight / scale); // points: what layout and paint work in
    needsPaint = true;
    repickPending = true;
}

/// 4. Paint: updates the ThorVG scene to match the layout. ThorVG only re-processes paints that changed.
void paint() nothrow @nogc {
    _scene.paint(viewWidth / scale, viewHeight / scale);
    needsPresent = true;
    repickPending = true; // scrolling moves things with no layout
}

/// 5. Present: the GPU draws the scene, and the frame is handed to the window.
void present() nothrow @nogc {
    if (renderer.resize(viewWidth, viewHeight))
        renderer.present();
}

/// Runs whichever of layout, paint and present are needed, in order.
void render() nothrow @nogc {
    if (!needsLayout && !needsPaint && !needsPresent)
        return;
    const start = traceNow();

    if (needsLayout) {
        needsLayout = false;
        layout();
    }
    const afterLayout = traceNow();
    if (viewWidth <= 0 || viewHeight <= 0)
        return; // minimised
    if (needsPaint) {
        needsPaint = false;
        paint();
    }
    const afterPaint = traceNow();
    if (needsPresent) {
        needsPresent = false;
        present();
    }

    trace("frame %dx%d  layout %.2f  paint %.2f  present %.2f  total %.2f ms", viewWidth, viewHeight,
          traceMs(start, afterLayout), traceMs(afterLayout, afterPaint), traceMs(afterPaint, traceNow()),
          traceMs(start, traceNow()));
}

public:



    this(string title){
        this.title = title;
        this.width = 800;
        this.height = 500;
    }

    void setSize(int width, int height){
        this.width = width;
        this.height = height;
    }

    /// What the window shows. Set it before run(); the tree in it is brought to life there, once
    /// there's a renderer whose canvas its shapes can go in.
    @property void scene(Scene scene){
        this._scene = scene;
    }

    @property inout(Scene) scene() inout {
        return _scene;
    }

    void run(){
        SDL_SetHint(SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "1");
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
            return;
        }
        scope(exit) SDL_Quit();
        traceOpen();
        scope(exit) traceClose();

        // Without HIGH_PIXEL_DENSITY the drawable stays at 1x and the compositor upscales it
        window = SDL_CreateWindow(title.toStringz(), width, height,
                                  SDL_WindowFlags.SDL_WINDOW_RESIZABLE | SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (!window) {
            fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
            return;
        }
        scope(exit) SDL_DestroyWindow(window);

        renderer = chooseRenderer();
        // scope(exit) runs in reverse order, so the renderer is released before the window is destroyed
        scope(exit) renderer.release();
        if (!renderer.initialise(window))
            return;

        if (!_scene)
            _scene = new Scene(new Widget); // nothing to show, but everything below still works
        _scene.attach(renderer.canvas);
        scope(exit) _scene.detach();
        _scene.platformColourScheme = systemColourScheme();
        applyCss(_scene); // styled before it's first laid out
        updateScale(); // needs both the window and the scene, so it goes after the two of them
        updateRefreshRate();
        trace("start video driver %s, renderer %s", SDL_GetCurrentVideoDriver(), renderer.name());

        SDL_AddEventWatch(&windowEventWatch, cast(void*) this);
        scope(exit) SDL_RemoveEventWatch(&windowEventWatch, cast(void*) this);

        // Platform.runLater() can wake the loop from now on, with tasks given before it started too
        laterEventType = SDL_RegisterEvents(1);
        Platform.wakeWith(&postLaterEvent);
        scope(exit) Platform.wakeWith(null);

        // After the scene is attached, since a screen reader already running asks for the tree
        // straight away, and before the loop, which is what answers it
        accessibilityEventType = SDL_RegisterEvents(1);
        if (accessibilityEventType)
            accessibility.open(window, accessibilityEventType);
        scope(exit) accessibility.close();
        scope(exit) foreach (c; cursors) if (c) SDL_DestroyCursor(c);

        // First frame, without waiting for an event
        running = true;
        render();

        // Sleep until an event arrives, then handle everything pending before rendering once.
        // Rendering after SDL has handled all the events matters when resizing on Wayland: SDL applies a new
        // size and only then tells the compositor it accepted it, and a frame committed in between doesn't
        // count as the answer. It also means a burst of events costs one frame instead of one each.
        // While an animation runs, the wait is cut short when its next frame is due.
        SDL_Event event;
        while (running) {
            const waitStart = traceNow();
            bool gotEvent;
            if (repickPending) {
                gotEvent = SDL_PollEvent(&event); // it's for update(), which should run now
            } else if (animationsRunning()) {
                gotEvent = SDL_WaitEventTimeout(&event, msUntilNextPulse());
            } else {
                if (!SDL_WaitEvent(&event))
                    break;
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
            trace("loop  in SDL_WaitEvent %.2f ms, then handled %d events in %.2f ms",
                  traceMs(waitStart, woke), handled, traceMs(woke, traceNow()));

            update();

            if (running) {
                render();
                updateAccessibility();
            }
        }
    }

}

/*
    Which renderer to use. WebGPU is the default everywhere. The CPU one is there for machines without
    working Vulkan, and for compositors where resizing a GPU surface is slow (GNOME resizes a Vulkan
    surface far less smoothly than KDE does). Set MAYFAIR_RENDERER=cpu or webgpu to choose.
*/
private Renderer chooseRenderer() nothrow
{
    const(char)* choice = getenv("MAYFAIR_RENDERER");
    if (choice && *choice) {
        if (strcmp(choice, "cpu") == 0) return new CpuRenderer;
        if (strcmp(choice, "webgpu") == 0) return new WebGpuRenderer;
        fprintf(stderr, "Unknown MAYFAIR_RENDERER '%s', using the default\n", choice);
    }
    return new WebGpuRenderer;
}

private KeyEvent keyEvent(ref const SDL_KeyboardEvent key, KeyEventType type) nothrow @nogc
{
    KeyEvent event;
    event.type = type;
    event.code = cast(KeyCode) key.key; // KeyCode's values are SDL's
    event.shift = (key.mod & SDL_Keymod.KMOD_SHIFT) != 0;
    event.control = (key.mod & SDL_Keymod.KMOD_CTRL) != 0;
    event.alt = (key.mod & SDL_Keymod.KMOD_ALT) != 0;
    event.meta = (key.mod & SDL_Keymod.KMOD_GUI) != 0;
    event.repeat = key.repeat;
    return event;
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

/// The SDL event type Platform.runLater() wakes the loop with. One App runs at a time, so one will do.
private __gshared uint laterEventType;

private void postLaterEvent() nothrow @nogc
{
    SDL_Event event;
    event.type = laterEventType;
    SDL_PushEvent(&event); // safe from any thread
}

/// SDL's button index as a MouseButton.
private MouseButton mouseButton(ubyte sdlButton) nothrow @nogc
{
    switch (sdlButton) {
        case 1: return MouseButton.primary;
        case 2: return MouseButton.middle;
        case 3: return MouseButton.secondary;
        case 4: return MouseButton.back;
        case 5: return MouseButton.forward;
        default: return MouseButton.none;
    }
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
    if (event.type == SDL_EventType.SDL_EVENT_WINDOW_EXPOSED && event.window.data1 == 1
        && event.window.windowID == SDL_GetWindowID(self.window)) {
        self.needsLayout = true;
        self.render();
    }
    return true;
}
