module mayfair.windowing.app;
import std.stdio;
import sdl;
import sdl.hints;
import sdl.error;
import sdl.surface;
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
import mayfair.filechooser : FileChooser;
import mayfair.windowing.decorations;
import mayfair.windowing.wayland : WindowMover;


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
WindowMover mover;         // moves the window by Mayfair's title bar on Wayland, once a press turns into a drag
//Garbage collection: see collectGarbage()
size_t liveAfterCollect;   // bytes in use after the last collection
ulong lastCollectPause;    // how long it took, in nanoseconds, on traceNow()'s clock
size_t collections;        // druntime's count of collections, as of the loop's last look, while tracing
size_t collectionsBetween; // how many of them collectGarbage() made
size_t collectionsTraced, collectionsBetweenTraced; // both, as of the last frame traced

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
            if (event.window.windowID == SDL_GetWindowID(window)) {
                accessibility.windowBoundsChanged();
                if (event.type != SDL_EventType.SDL_EVENT_WINDOW_SHOWN && event.type != SDL_EventType.SDL_EVENT_WINDOW_MOVED
                    && event.type != SDL_EventType.SDL_EVENT_WINDOW_RESIZED)
                    queueInputEvent(event);
                if (event.type == SDL_EventType.SDL_EVENT_WINDOW_RESIZED)
                    frameChanged = true; // its shape, for the new size
            }
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_ENTER_FULLSCREEN:
        case SDL_EventType.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:
            if (event.window.windowID == SDL_GetWindowID(window))
                frameChanged = true;
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
    if (frameChanged) {
        frameChanged = false;
        applyFrame();
    }
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
        case SDL_EventType.SDL_EVENT_WINDOW_MAXIMIZED:
            _scene.windowMaximised(true);
            frameChanged = true;
            break;
        case SDL_EventType.SDL_EVENT_WINDOW_RESTORED:
            _scene.windowMaximised(false);
            frameChanged = true;
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
    // A renderer whose present waits for the display paces frames itself, and a timer of the
    // loop's own, knowing nothing of when the display refreshes, would make it miss them. So the
    // timer only stops it running flat out if the present stops waiting: a hidden window, say.
    const frameDue = lastUpdate + (renderer.pacedByDisplay() ? framePeriod / 2 : framePeriod);
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

    // "animating" tells a frame an animation asked for from one an event caused, for plotting frame pacing.
    // "gc" is how many collections there were since the frame before, druntime's own and
    // collectGarbage()'s, and "between" how many were collectGarbage()'s, in the wait before it.
    trace("frame %dx%d  layout %.2f  paint %.2f  present %.2f  total %.2f ms  animating %d  gc %d  between %d",
          viewWidth, viewHeight, traceMs(start, afterLayout), traceMs(afterLayout, afterPaint),
          traceMs(afterPaint, traceNow()), traceMs(start, traceNow()), cast(int) animationsRunning(),
          cast(int)(collections - collectionsTraced), cast(int)(collectionsBetween - collectionsBetweenTraced));
    collectionsTraced = collections;
    collectionsBetweenTraced = collectionsBetween;
}

/*
    What the title bar Mayfair draws asks the window to do.
*/
final class Controls : WindowControls {
    void close() {
        SDL_Event quit;
        quit.type = SDL_EventType.SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
    }
    void minimise() { SDL_MinimizeWindow(window); }
    void toggleMaximised() {
        if (maximised)
            SDL_RestoreWindow(window);
        else
            SDL_MaximizeWindow(window);
    }
    bool maximised() { return (SDL_GetWindowFlags(window) & SDL_WindowFlags.SDL_WINDOW_MAXIMIZED) != 0; }
    void showMenu(float x, float y) { SDL_ShowWindowSystemMenu(window, toWindow(x), toWindow(y)); }
    bool movesByDrag() { return mover.available; }
    bool beginMove() {
        return mover.move(SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                                 SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER, null));
    }
}

bool drawsDecorations; // Mayfair draws the title bar and edges, rather than the desktop
bool frameChanged;     // maximised, restored, fullscreen or resized: the frame and shape to see to

/*
    The frame round a window drawing its own decorations: a margin with its shadow in, and rounded
    corners -- unless it's maximised or fullscreen, when its edges are the screen's. And the
    window's shape to match: the shadow beyond the band just outside the edge that sizes it lets
    clicks through to what's underneath, as it would if the desktop had drawn it.
*/
void applyFrame() {
    if (!drawsDecorations)
        return;
    const flat = (SDL_GetWindowFlags(window) & (SDL_WindowFlags.SDL_WINDOW_MAXIMIZED | SDL_WindowFlags.SDL_WINDOW_FULLSCREEN)) != 0;
    _scene.setFrame(flat ? 0 : Theme.window_margin, flat ? 0 : Theme.window_radius);
    needsLayout = true;
    updateShape(flat);
}

void updateShape(bool flat) {
    import core.stdc.string : strcmp;
    // Only for a renderer SDL doesn't draw through: SDL applies a shape's alpha to what it draws
    // itself, which would cut the CPU renderer's shadow off where the shape does
    if (strcmp(renderer.name(), "webgpu") != 0)
        return;
    int w, h;
    SDL_GetWindowSize(window, &w, &h);
    if (w <= 0 || h <= 0)
        return;
    auto shape = SDL_CreateSurface(w, h, SDL_PixelFormat.SDL_PIXELFORMAT_ARGB8888);
    if (!shape)
        return;
    scope(exit) SDL_DestroySurface(shape);
    // Maximised or fullscreen, all of it takes clicks. (Not a null shape, which is how SDL says to
    // remove one, as SDL 3.4 crashes on it under Wayland.)
    SDL_FillSurfaceRect(shape, null, 0);
    const inset = flat ? 0 : toWindow(Theme.window_margin - Theme.window_resize_band);
    auto solid = SDL_Rect(inset, inset, w - 2 * inset, h - 2 * inset);
    SDL_FillSurfaceRect(shape, &solid, 0xFFFFFFFF);
    SDL_SetWindowShape(window, shape);
}

/*
    Where on the window a press is, for the window system, when Mayfair draws its decorations: an
    edge or a corner to size it by -- unless it's maximised, when there's nothing to size -- the
    title bar to move it by, where there's no control, or the app's. Also asked as the pointer
    moves, which is how the pointer gets its resizing shapes at the edges.
*/
SDL_HitTestResult hitTestAt(float x, float y) nothrow @nogc {
    enum inside = 4;  // points in from the window's visible edge that size it, as well as the band outside
    enum corner = 16; // and along it from a corner that size both ways
    // Measured from the visible edge, inside the frame's margin
    const m = _scene ? _scene.frameMargin : 0;
    const band = m > 0 ? Theme.window_resize_band : 0;
    x -= m - band;
    y -= m - band;
    const edge = band + inside;
    const w = viewWidth / scale - 2 * (m - band), h = viewHeight / scale - 2 * (m - band);
    if (x < 0 || y < 0 || x >= w || y >= h)
        return SDL_HitTestResult.SDL_HITTEST_NORMAL; // out in the shadow
    const sized = !(SDL_GetWindowFlags(window) & (SDL_WindowFlags.SDL_WINDOW_MAXIMIZED | SDL_WindowFlags.SDL_WINDOW_FULLSCREEN));
    if (sized) {
        const left = x < edge, right = x >= w - edge, top = y < edge, bottom = y >= h - edge;
        const nearLeft = x < corner, nearRight = x >= w - corner, nearTop = y < corner, nearBottom = y >= h - corner;
        if ((top && nearLeft) || (left && nearTop)) return SDL_HitTestResult.SDL_HITTEST_RESIZE_TOPLEFT;
        if ((top && nearRight) || (right && nearTop)) return SDL_HitTestResult.SDL_HITTEST_RESIZE_TOPRIGHT;
        if ((bottom && nearLeft) || (left && nearBottom)) return SDL_HitTestResult.SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if ((bottom && nearRight) || (right && nearBottom)) return SDL_HitTestResult.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (top) return SDL_HitTestResult.SDL_HITTEST_RESIZE_TOP;
        if (bottom) return SDL_HitTestResult.SDL_HITTEST_RESIZE_BOTTOM;
        if (left) return SDL_HitTestResult.SDL_HITTEST_RESIZE_LEFT;
        if (right) return SDL_HitTestResult.SDL_HITTEST_RESIZE_RIGHT;
    }
    auto bar = _scene ? _scene.titleBar : null;
    if (!bar)
        return SDL_HitTestResult.SDL_HITTEST_NORMAL;
    // A menu open: the press is to close it, so it goes to the scene
    foreach (p; _scene.popups)
        if (p.autoHide || p.modal)
            return SDL_HitTestResult.SDL_HITTEST_NORMAL;
    // With the mover, the press is the title bar's, to tell a double click from a drag by;
    // without it, the window system moves the window from the press
    if (mover.available)
        return SDL_HitTestResult.SDL_HITTEST_NORMAL;
    return bar.dragsWindowAt(x + m - band, y + m - band) ? SDL_HitTestResult.SDL_HITTEST_DRAGGABLE
                                                         : SDL_HitTestResult.SDL_HITTEST_NORMAL;
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

        // Who draws the title bar: the app, if it gave the scene one; otherwise the desktop, where
        // it will -- and where it won't, as on GNOME, a plain one of Mayfair's. Decided before SDL
        // starts, as SDL would otherwise have libdecor draw it, with GTK.
        const appBar = _scene && _scene.titleBarChosen;
        const wayland = onWayland();
        drawsDecorations = appBar || (wayland && !compositorDecorates());
        if (drawsDecorations && wayland)
        {
            keepLibdecorPluginsAway(true);
            quietStderr(true); // libdecor says, twice, that it found no plugins: what was meant
        }

        if (!SDL_Init(SDL_INIT_VIDEO)) {
            quietStderr(false);
            fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
            return;
        }
        scope(exit) SDL_Quit();
        traceOpen();
        scope(exit) traceClose();

        // Without HIGH_PIXEL_DENSITY the drawable stays at 1x and the compositor upscales it
        auto flags = SDL_WindowFlags.SDL_WINDOW_RESIZABLE | SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        // Drawing its own frame, it's transparent, and bigger by the margin its shadow's in, so
        // what's inside is the size asked for
        const margin = drawsDecorations ? cast(int) Theme.window_margin : 0;
        if (drawsDecorations)
            flags |= SDL_WindowFlags.SDL_WINDOW_BORDERLESS | SDL_WindowFlags.SDL_WINDOW_TRANSPARENT;
        window = SDL_CreateWindow(title.toStringz(), width + 2 * margin, height + 2 * margin, flags);
        if (drawsDecorations && wayland)
        {
            quietStderr(false);
            keepLibdecorPluginsAway(false);
        }
        if (!window) {
            fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
            return;
        }
        scope(exit) SDL_DestroyWindow(window);
        scope(exit) mover.close(); // before the window, and SDL's connection, go
        {
            int cw, ch;
            SDL_GetWindowSize(window, &cw, &ch);
            trace("window %dx%d asked %dx%d, decorations %s, flags %llx", cw, ch, width + 2 * margin,
                  height + 2 * margin, drawsDecorations ? "ours".ptr : "the desktop's".ptr, SDL_GetWindowFlags(window));
        }

        renderer = chooseRenderer();
        // scope(exit) runs in reverse order, so the renderer is released before the window is destroyed
        scope(exit) renderer.release();
        scope(exit) releaseKeptDecodings(); // before the renderer's engine goes, and after the scene's pictures
        if (!renderer.initialise(window))
            return;

        if (!_scene)
            _scene = new Scene(new Widget); // nothing to show, but everything below still works
        if (drawsDecorations)
        {
            // The app's title bar, or a plain one, and the window's edges and bar for moving and sizing it
            if (!_scene.titleBar)
            {
                _scene.titleBar(new TitleBar(title));
                _scene.titleBarChosen = false;
            }
            else if (!_scene.titleBar.title.length)
                _scene.titleBar.setTitle(title);
            if (wayland)
                mover.open(SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                                  SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null));
            _scene.windowControls = new Controls;
            SDL_SetWindowHitTest(window, &hitTest, cast(void*) this);
            applyFrame();
        }
        _scene.nativeWindow = window;
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

        // Collections before now -- building the widgets, say -- aren't any frame's
        if (tracing()) {
            import core.memory : GC;
            collections = collectionsTraced = GC.profileStats().numCollections;
        }

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
            // Before the wait, which it then shortens by as long as it took
            collectGarbage(animationsRunning());
            const waitStart = traceNow();
            bool gotEvent;
            // While something's animating, the next frame is when the display's ready for it, and
            // not before: the repick below waits for it too, rather than the loop going round as
            // fast as it can -- which, with a present mode that doesn't wait for the display, is
            // hundreds of frames a second nobody sees
            if (animationsRunning()) {
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
            mover.dispatch();
            trace("loop  in SDL_WaitEvent %.2f ms, then handled %d events in %.2f ms",
                  traceMs(waitStart, woke), handled, traceMs(woke, traceNow()));

            update();

            if (running) {
                if (tracing()) {
                    import core.memory : GC;
                    collections = GC.profileStats().numCollections; // for the frame's trace line
                }
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

private extern(C) SDL_HitTestResult hitTest(SDL_Window* window, const(SDL_Point)* area, void* data) nothrow @nogc
{
    auto app = cast(App) data;
    return app.hitTestAt(app.toPoints(area.x), app.toPoints(area.y));
}

/*
    Keeps libdecor from loading a plugin -- the GTK one, on GNOME -- while SDL makes the window, by
    pointing it at a folder with none in it, and then puts the setting back as it was. libdecor
    then draws nothing, and Mayfair draws the title bar.
*/
private void keepLibdecorPluginsAway(bool away) nothrow @nogc
{
    import core.stdc.stdlib : getenv;
    import core.sys.posix.stdlib : setenv, unsetenv;
    import core.stdc.string : strlen;
    __gshared char[1024] saved;
    __gshared bool hadOne;
    enum none = "/proc/self/fdinfo/nonexistent\0"; // a folder that's never there
    if (away) {
        const was = getenv("LIBDECOR_PLUGIN_DIR");
        hadOne = was !is null && strlen(was) < saved.length;
        if (hadOne)
            saved[0 .. strlen(was) + 1] = was[0 .. strlen(was) + 1];
        setenv("LIBDECOR_PLUGIN_DIR", none.ptr, 1);
    } else if (hadOne) {
        setenv("LIBDECOR_PLUGIN_DIR", saved.ptr, 1);
    } else {
        unsetenv("LIBDECOR_PLUGIN_DIR");
    }
}

/*
    Stops anything reaching stderr, or lets it again: for libdecor, which, kept from its plugins,
    says so as SDL starts and makes the window. Anything SDL itself has to say about that goes
    through SDL_GetError, which is still reported.
*/
private void quietStderr(bool quiet) nothrow @nogc
{
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.sys.posix.unistd : close, dup, dup2;
    __gshared int saved = -1;
    enum stderrFd = 2;
    if (quiet && saved < 0) {
        saved = dup(stderrFd);
        const nul = open("/dev/null", O_WRONLY);
        if (nul >= 0) {
            dup2(nul, stderrFd);
            close(nul);
        }
    } else if (!quiet && saved >= 0) {
        dup2(saved, stderrFd);
        close(saved);
        saved = -1;
    }
}
