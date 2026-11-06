module mayfair.windowing.window;

import core.stdc.string : strcmp;
import std.string : toStringz;
import sdl;
import sdl.surface;
import sdl.error;
import mayfair.log;
import mayfair.renderers;
import mayfair.widgets;
import mayfair.widgets.styling : applyCss;
import mayfair.theme : Theme;
import mayfair.trace;
import mayfair.accessibility;
import mayfair.windowing.accessibility;
import mayfair.windowing.app;
import mayfair.windowing.backend;

/*
    A window: a Scene, in a window of the desktop's, with a renderer of its own drawing it. The
    App has one from the start, its main window, that App's own setSize, scene and the rest are
    for; an app opens more as it wants them:

        auto preferences = new Window("Preferences");
        preferences.scene = new Scene(buildPreferences());
        preferences.setSize(480, 360);
        preferences.setOwner(app.window).setModal(true);
        preferences.show();

    and close() takes one away again, as the user closing it does. They all run in the App's one
    loop, on the UI thread, which is the only thread to touch one from (Platform.runLater gets
    there from others). The App's run() returns once the last is closed.

    Each frame's phases (see App) run for every window that needs them: the App hands each the
    events that are its, and asks each in turn to update, lay out, paint and present.
*/
class Window
{
    this(string title)
    {
        _title = title;
    }

    /// What it shows. Set it before it's shown, or change it while it's closed.
    @property void scene(Scene scene)
    {
        assert(!sdl, "a window's scene is set before it's shown");
        _scene = scene;
    }

    @property inout(Scene) scene() inout
    {
        return _scene;
    }

    /// The window the scene `of` is shown in, if it's in one: for a widget whose handler wants to
    /// close the window it's in, say. Null otherwise.
    static Window of(Scene of)
    {
        if (auto app = App.current)
            foreach (w; app.windows)
                if (w._scene is of)
                    return w;
        return null;
    }

    /// ditto
    static Window of(Widget widget)
    {
        return widget && widget.scene ? of(widget.scene) : null;
    }

    string title() const { return _title; }

    /// Changes its title: the desktop's, and the title bar Mayfair draws, if it drew the plain one.
    Window setTitle(string title)
    {
        _title = title;
        if (sdl)
            SDL_SetWindowTitle(sdl, title.toStringz());
        if (_scene && _scene.titleBar && !_scene.titleBarChosen)
            _scene.titleBar.setTitle(title);
        return this;
    }

    /// Its size, inside: what its scene has, and not counting any frame. Set it before it's shown.
    Window setSize(int width, int height)
    {
        this.width = width;
        this.height = height;
        return this;
    }

    /// Whether it opens maximised: as it was left last time, say. Set it before it's shown.
    Window setMaximised(bool maximised)
    {
        _startMaximised = maximised;
        return this;
    }

    /*
        The size it was last when it wasn't maximised, fullscreen or tiled -- its inside, as
        setSize takes -- and whether it was maximised: what an app keeps, to open as it was left.
        Kept up as it's resized, so they're still there once it's closed.
    */
    int restoredWidth() const { return _restoredWidth; }
    int restoredHeight() const { return _restoredHeight; } /// ditto
    bool wasMaximised() const { return _wasMaximised; }   /// ditto

    /*
        The smallest it can be made, as JavaFX's Stage.minWidth and minHeight: the size below
        which the layout stops working, as the desktop won't let it be dragged smaller. Its inside,
        as setSize's is: a frame's shadow margin is added on. 0 for no limit, as it starts. Set
        before it's shown or while it is.
    */
    Window setMinSize(int width, int height)
    {
        _minWidth = width;
        _minHeight = height;
        applySizeLimits();
        return this;
    }

    /// The biggest it can be made, as JavaFX's Stage.maxWidth and maxHeight; 0 for no limit, as
    /// it starts. A window with one can't fill the screen, so most want none.
    Window setMaxSize(int width, int height)
    {
        _maxWidth = width;
        _maxHeight = height;
        applySizeLimits();
        return this;
    }

    /*
        Whether it's translucent, what's behind it showing through blurred. Only where the
        compositor blurs (see Widget.backdropBlur): elsewhere it's an ordinary opaque window,
        as what's behind showing through unblurred makes its text hard to read. How translucent is
        the theme's, in its .root:translucent rule. Set it before it's shown; whether it is now, as
        the compositor's blur comes and goes, is the scene's translucentProperty.
    */
    Window setTranslucent(bool translucent)
    {
        _translucent = translucent;
        return this;
    }

    bool translucent() const
    {
        return _translucent;
    }

    /*
        The window it belongs to: a dialog's, say. The desktop keeps it above that one, and
        centres it over it where it places windows itself, and it closes when that one does. Set
        before it's shown.
    */
    Window setOwner(Window owner)
    {
        assert(owner !is this);
        _owner = owner;
        return this;
    }

    Window owner() { return _owner; }

    /*
        Whether, while it's open, its owner takes no input: a dialog that has to be answered
        first. A click on the owner brings this to the front instead. Needs an owner; set before
        it's shown.
    */
    Window setModal(bool modal)
    {
        _modal = modal;
        return this;
    }

    bool modal() const { return _modal; }

    /*
        What's to happen when the user closes it -- by its close button, or the desktop's -- before
        it does: false keeps it open, to ask about unsaved changes first, say. Not asked when the
        app closes it itself with close(), or ends with App.quit().
    */
    Window onCloseRequest(bool delegate() handler)
    {
        _onCloseRequest = handler;
        return this;
    }

    /// What's to happen once it's closed, by the user or by close(), while the app runs on: not
    /// as run() ends. Its scene's been taken down by then.
    Window onClosed(void delegate() handler)
    {
        _onClosed = handler;
        return this;
    }

    /*
        Opens it, in the App made last (see App.current), or brings it to the front if it's open.
        Before the App's run() it's opened as run() starts, after the main window. On the UI thread.
    */
    void show()
    {
        auto app = App.current;
        assert(app, "a window is shown in an App: make one first");
        if (_shown)
        {
            raise();
            return;
        }
        _shown = true;
        _closing = false;
        app.adopt(this);
    }

    /*
        Closes it, without asking its onCloseRequest: once what's being handled now is done, so
        a handler of its own scene's can close it. Windows it owns close with it. Closing the last
        window ends the App's run().
    */
    void close()
    {
        if (!_shown)
            return;
        _closing = true;
        foreach (w; App.current ? App.current.windows.dup : null)
            if (w._owner is this)
                w.close();
        if (sdl) {
            backend.hiding();
            SDL_HideWindow(sdl);
        }
        else if (auto app = App.current)
            app.forget(this); // never opened, as run() hasn't started: nothing to take down
    }

    /// Whether it's open, or is to be once the App runs.
    bool showing() const { return _shown && !_closing; }

    /// Brings it to the front, out of being minimised if it is: for a media player's Raise, or a
    /// second launch handing over to the first. While it's not open, does nothing.
    void raise() nothrow @nogc
    {
        if (!sdl)
            return;
        if (SDL_GetWindowFlags(sdl) & SDL_WindowFlags.SDL_WINDOW_MINIMIZED)
            SDL_RestoreWindow(sdl);
        SDL_RaiseWindow(sdl);
    }

    /// The desktop's window, while it's open: for what Mayfair doesn't wrap. Null otherwise.
    SDL_Window* nativeWindow() nothrow @nogc { return sdl; }

package(mayfair):
    SDL_Window* sdl;
    Renderer renderer;
    Scene _scene;
    string _title;
    int width = 800, height = 500;
    bool _shown;          // show()n, and not closed since
    bool _closing;        // close()d, to be taken down once the frame's update is done
    Window _owner;
    bool _modal;
    bool delegate() _onCloseRequest;
    void delegate() _onClosed;

    // Accessibility
    AccessibilityAdapter accessibility;

    // Frame state
    bool needsLayout = true;
    bool needsPaint;
    bool needsPresent;
    int viewWidth, viewHeight; // drawable size in pixels, set by layout()
    float scale = 1.0f;        // device pixels per point, set by updateScale()
    bool scaleApplied;         // whether updateScale() has told the scene anything yet
    ulong framePeriod = 16_666_667; // nanoseconds between display refreshes, set by updateRefreshRate()
    bool repickPending;        // things moved, by layout or scrolling, so what's under the pointer may have too

    // Text input: which widget it's on for, and where SDL was last told it is
    Widget textInputWidget;
    SDL_Rect textInputRect;
    int textInputCursor;

    WindowBackend backend;     // what the desktop does for it that SDL doesn't: see mayfair.windowing.backend
    bool _translucent;         // asked to be translucent, where the compositor blurs: see setTranslucent()
    bool translucentNow;       // and is, as the scene was last told
    bool drawsDecorations;     // Mayfair draws the title bar and edges, rather than the desktop
    bool frameChanged;         // maximised, restored, fullscreen or resized: the frame and shape to see to

    int _minWidth, _minHeight, _maxWidth, _maxHeight; // the window's inside; 0 for none
    bool _startMaximised, _wasMaximised;              // see setMaximised and wasMaximised
    int _restoredWidth, _restoredHeight;              // see restoredWidth
    int _margin;                                      // its frame's, round the inside

    SDL_WindowID id() nothrow @nogc { return sdl ? SDL_GetWindowID(sdl) : 0; }

    /// Whether a modal window it owns is open, so its input is to go to that instead.
    bool blockedByModal() nothrow @nogc
    {
        auto app = App.current;
        if (!app)
            return false;
        foreach (w; app.windows)
            if (w._owner is this && w._modal && w.sdl && !w._closing)
                return true;
        return false;
    }

    /// The modal window it owns that's open, to bring to the front when it's clicked.
    Window modalChild() nothrow @nogc
    {
        foreach (w; App.current.windows)
            if (w._owner is this && w._modal && w.sdl && !w._closing)
                return w.modalChild() ? w.modalChild() : w;
        return null;
    }

    /*
        Makes the desktop's window, with the first of `candidates` that starts in it, and brings
        the scene to life in it, on `desktop`. False if no renderer could start.
    */
    bool open(Renderer[] candidates, DesktopBackend desktop, uint accessibilityEventType)
    {
        // Who draws the title bar: the app, if it gave the scene one; otherwise the desktop, where
        // it will -- and where it won't, as on GNOME, a plain one of Mayfair's.
        drawsDecorations = (_scene && _scene.titleBarChosen) || !desktop.decoratesWindows();

        // Without HIGH_PIXEL_DENSITY the drawable stays at 1x and the compositor upscales it
        auto flags = SDL_WindowFlags.SDL_WINDOW_RESIZABLE | SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        // Drawing its own frame, it's transparent, and bigger by the margin its shadow's in, so
        // what's inside is the size asked for
        const margin = drawsDecorations ? cast(int) Theme.window_margin : 0;
        _margin = margin;
        _restoredWidth = width;
        _restoredHeight = height;
        if (_startMaximised)
            flags |= SDL_WindowFlags.SDL_WINDOW_MAXIMIZED;
        if (drawsDecorations)
            flags |= SDL_WindowFlags.SDL_WINDOW_BORDERLESS | SDL_WindowFlags.SDL_WINDOW_TRANSPARENT;
        // One that's to be translucent needs its alpha from the start, though until the
        // compositor's said it blurs it's drawn opaque.
        else if (_translucent && desktop.mayBlur())
            flags |= SDL_WindowFlags.SDL_WINDOW_TRANSPARENT;

        // The first renderer that starts, in a window made for it. Most share one; OpenGL needs its
        // own, as SDL can't make a window an OpenGL one once it's made.
        SDL_WindowFlags madeFor;
        foreach (i, candidate; candidates) {
            if (!sdl || candidate.windowFlags() != madeFor) {
                if (sdl)
                    SDL_DestroyWindow(sdl);
                madeFor = candidate.windowFlags();
                desktop.beforeSdl(drawsDecorations);
                sdl = SDL_CreateWindow(_title.toStringz(), width + 2 * margin, height + 2 * margin, flags | madeFor);
                desktop.afterSdl(drawsDecorations);
                if (!sdl) {
                    logError("SDL_CreateWindow failed: %s", SDL_GetError());
                    return false;
                }
                applySizeLimits();
                // Above its owner, and modal over it if it's to be
                if (_owner && _owner.sdl) {
                    SDL_SetWindowParent(sdl, _owner.sdl);
                    if (_modal)
                        SDL_SetWindowModal(sdl, true);
                }
                version (Emscripten)
                    SDL_SetWindowFillDocument(sdl, true); // the page is the window: it fills it, and follows it as it's resized
                int cw, ch;
                SDL_GetWindowSize(sdl, &cw, &ch);
                trace("window %dx%d asked %dx%d, decorations %s, flags %llx", cw, ch, width + 2 * margin,
                      height + 2 * margin, drawsDecorations ? "ours".ptr : "the desktop's".ptr, SDL_GetWindowFlags(sdl));
            }
            if (candidate.initialise(sdl)) {
                renderer = candidate;
                break;
            }
            candidate.release();
            if (i + 1 < candidates.length)
                logInfo("Using the %s renderer, as %s couldn't start", candidates[i + 1].name(), candidate.name());
        }
        if (!renderer) {
            logError("No renderer could start");
            if (sdl)
                SDL_DestroyWindow(sdl);
            sdl = null;
            return false;
        }

        if (!_scene)
            _scene = new Scene(new Widget); // nothing to show, but everything below still works
        if (drawsDecorations)
        {
            // The app's title bar, or a plain one, and the window's edges and bar for moving and sizing it
            if (!_scene.titleBar)
            {
                _scene.titleBar(new TitleBar(_title));
                _scene.titleBarChosen = false;
            }
            else if (!_scene.titleBar.title.length)
                _scene.titleBar.setTitle(_title);
            _scene.windowControls = new Controls;
            SDL_SetWindowHitTest(sdl, &hitTest, cast(void*) this);
        }
        backend = desktop.newWindow();
        backend.open(sdl, drawsDecorations);
        if (drawsDecorations)
            applyFrame();
        _scene.nativeWindow = sdl;
        _scene.attach(renderer.canvas);
        _scene.platformColourScheme = systemColourScheme();
        applyTranslucency(); // before it's styled, as the theme styles :translucent
        applyCss(_scene); // styled before it's first laid out
        updateScale(); // needs both the window and the scene, so it goes after the two of them
        updateRefreshRate();

        // After the scene is attached, since a screen reader already running asks for the tree
        // straight away, and before the loop, which is what answers it
        if (accessibilityEventType)
            accessibility.open(sdl, accessibilityEventType);
        needsLayout = true;
        return true;
    }

    /// Takes the scene down and lets go of the window, in the order each needs the next.
    void takeDown()
    {
        if (!sdl)
            return;
        if (textInputWidget)
            SDL_StopTextInput(sdl);
        textInputWidget = null;
        accessibility.close();
        _scene.detach();
        _scene.nativeWindow = null;
        _scene.windowControls = null;
        renderer.release();
        renderer = null;
        backend.close();
        backend = null;
        SDL_DestroyWindow(sdl);
        sdl = null;
        needsLayout = true;
        needsPaint = needsPresent = false;
        scaleApplied = false;
        translucentNow = false;
    }

    /*
        HiDPI. Layout and paint work in points; the scene transform turns those into device pixels, so
        a point is the same physical size whatever the display. SDL_GetWindowDisplayScale() is the right
        factor: it combines the window's pixel density with the scale the user asked for (a 150% Windows
        display, or a Wayland fractional scale), which is what UI should be sized by. Yoga's point scale
        factor makes it round layout so edges land on whole device pixels, which matters most at the
        fractional scales, where otherwise adjacent boxes meet on a half pixel and the seam shows.
    */
    void updateScale() nothrow @nogc {
        const reported = SDL_GetWindowDisplayScale(sdl);
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

    /// Makes the window translucent or opaque as the compositor's blur comes and goes, if it's to be.
    void applyTranslucency() {
        const on = _translucent && backend.blurs();
        if (on == translucentNow)
            return;
        translucentNow = on;
        _scene._setTranslucent(on);
        trace("translucent %s", on ? "yes".ptr : "no".ptr);
    }

    /// How often the window's display refreshes, which is how often a running animation gets a frame.
    void updateRefreshRate() nothrow @nogc {
        const mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(sdl));
        const hz = mode && mode.refresh_rate > 0 ? mode.refresh_rate : 60.0f;
        framePeriod = cast(ulong)(1e9 / hz);
        trace("refresh %.2f Hz", hz);
    }

    /*
        SDL gives mouse positions in window coordinates. Those are points only when the pixel density
        and the display scale agree, which they don't on, say, a 150% Windows display without a high
        density drawable, so go through pixels, which both are defined against.
    */
    float toPoints(float windowCoordinate) nothrow @nogc {
        return windowCoordinate * SDL_GetWindowPixelDensity(sdl) / scale;
    }

    /// Points back to SDL's window coordinates, the opposite of toPoints().
    int toWindow(float points) nothrow @nogc {
        return cast(int)(points * scale / SDL_GetWindowPixelDensity(sdl) + 0.5f);
    }

    /*
        1. Events, for one of this window's own window events: records what it changes. Whether
        it's also for the widgets, for update() to hand on, is what it returns.
    */
    bool handleWindowEvent(ref const SDL_Event event) nothrow @nogc {
        switch (event.type) {
            case SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                needsLayout = true;
                return false;
            case SDL_EventType.SDL_EVENT_WINDOW_EXPOSED:
                needsPresent = true;
                return false;
            case SDL_EventType.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
                updateScale(); // it moved to a display with a different scale
                return false;
            case SDL_EventType.SDL_EVENT_WINDOW_DISPLAY_CHANGED:
                updateRefreshRate();
                return false;
            case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED:
            case SDL_EventType.SDL_EVENT_WINDOW_FOCUS_LOST:
                accessibility.windowFocus(event.type == SDL_EventType.SDL_EVENT_WINDOW_FOCUS_GAINED);
                return true;
            case SDL_EventType.SDL_EVENT_WINDOW_MOUSE_LEAVE:
            case SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                return true;
            case SDL_EventType.SDL_EVENT_WINDOW_SHOWN:
            case SDL_EventType.SDL_EVENT_WINDOW_MOVED:
            case SDL_EventType.SDL_EVENT_WINDOW_RESIZED:
            case SDL_EventType.SDL_EVENT_WINDOW_MAXIMIZED:
            case SDL_EventType.SDL_EVENT_WINDOW_RESTORED:
                accessibility.windowBoundsChanged();
                if (event.type == SDL_EventType.SDL_EVENT_WINDOW_RESIZED)
                    frameChanged = true; // its shape, for the new size
                if (event.type != SDL_EventType.SDL_EVENT_WINDOW_MOVED)
                    noteSize();
                return event.type == SDL_EventType.SDL_EVENT_WINDOW_MAXIMIZED
                    || event.type == SDL_EventType.SDL_EVENT_WINDOW_RESTORED;
            case SDL_EventType.SDL_EVENT_WINDOW_ENTER_FULLSCREEN:
            case SDL_EventType.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:
                frameChanged = true;
                return false;
            default:
                return false;
        }
    }

    /// 2. Update, before the input's handed on: the frame's shape, and what's under the pointer.
    void beforeInput() {
        if (frameChanged) {
            frameChanged = false;
            applyFrame();
        }
        if (repickPending) {
            repickPending = false;
            _scene.repick();
        }
    }

    /// 2. Update: one of the events handleEvent() kept for the widgets, handed to them.
    void dispatchInputEvent(ref const SDL_Event event, const(char)[] text) {
        // While a modal window it owns is open, that's where its input goes: the pointer and the
        // keyboard are kept from this one's widgets, and a click brings the modal one forward
        if (isUserInput(event.type) && blockedByModal()) {
            if (event.type == SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN)
                if (auto child = modalChild())
                    child.raise();
            return;
        }
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
            case SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                requestClose();
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
                // AccessKit's requests
                if (event.user.code == AccessibilityAdapter.Request.activate)
                    accessibility.requestFullTree();
                else {
                    ulong target;
                    accesskit_action action;
                    AccessibleActionData data;
                    AccessibilityAdapter.takeAction(cast(void*) event.user.data1, target, action, data); // ours to free
                    _scene.performAccessibleAction(target, action, data);
                }
                break;
        }
    }

    /// The user's asked for it to close: it does, unless its onCloseRequest says not to.
    void requestClose() {
        if (blockedByModal()) {
            if (auto child = modalChild())
                child.raise(); // the dialog over it is to be answered first
            return;
        }
        if (_onCloseRequest && !_onCloseRequest())
            return;
        close();
    }

    /// 2. Update, after the input and the animations: restyling, and what SDL's to be told.
    void afterInput() {
        applyCss(_scene); // what the input and animations changed, restyled before layout
        updateTextInput();
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
                SDL_StartTextInput(sdl);
                textInputRect = SDL_Rect.init;
                textInputCursor = -1; // tell it where, below, even if it's the old place
            } else {
                SDL_StopTextInput(sdl);
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
            SDL_SetTextInputArea(sdl, &rect, cursor);
        }
    }

    /*
        Tells assistive technology what changed. After rendering, because a widget's bounds are where
        it was painted. It isn't a frame phase of its own, as it's the widgets describing themselves,
        which is their code, not the kit's, and so free to allocate.
    */
    void updateAccessibility() {
        const pointsToWindow = scale / SDL_GetWindowPixelDensity(sdl);
        if (accessibility.updateNeeded(_scene, pointsToWindow))
            accessibility.update(_scene, _title, pointsToWindow);
    }

    /// 3. Layout: Yoga works out every box's size and position for the current window size.
    void layout() nothrow @nogc {
        SDL_GetWindowSizeInPixels(sdl, &viewWidth, &viewHeight); // pixels: what the renderer needs
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

    /// Runs whichever of layout, paint and present are needed, in order. False if none were.
    bool render(out ulong layoutNs, out ulong paintNs, out ulong presentNs) nothrow @nogc {
        if (!needsLayout && !needsPaint && !needsPresent)
            return false;
        const start = traceNow();

        if (needsLayout) {
            needsLayout = false;
            layout();
        }
        const afterLayout = traceNow();
        layoutNs = afterLayout - start;
        if (viewWidth <= 0 || viewHeight <= 0)
            return false; // minimised
        if (needsPaint) {
            needsPaint = false;
            paint();
            // Where to blur behind, worked out from where things were just painted, for the present to commit
            if (backend.blurs())
                backend.blurBehind(_scene);
        }
        const afterPaint = traceNow();
        paintNs = afterPaint - afterLayout;
        if (needsPresent) {
            needsPresent = false;
            present();
        }
        presentNs = traceNow() - afterPaint;
        return true;
    }

    /*
        What the title bar Mayfair draws asks the window to do.
    */
    final class Controls : WindowControls {
        void close() { requestClose(); }
        void minimise() { SDL_MinimizeWindow(sdl); }
        void toggleMaximised() {
            if (maximised)
                SDL_RestoreWindow(sdl);
            else
                SDL_MaximizeWindow(sdl);
        }
        bool maximised() { return (SDL_GetWindowFlags(sdl) & SDL_WindowFlags.SDL_WINDOW_MAXIMIZED) != 0; }
        void showMenu(float x, float y) { SDL_ShowWindowSystemMenu(sdl, toWindow(x), toWindow(y)); }
        bool movesByDrag() { return backend.movesByDrag(); }
        bool beginMove() { return backend.beginMove(); }
    }

    /*
        The frame round a window drawing its own decorations: a margin with its shadow in, and rounded
        corners -- unless it's maximised, fullscreen or tiled, when its edges are the screen's or
        another window's. And the window's shape to match: the shadow beyond the band just outside the
        edge that sizes it lets clicks through to what's underneath, as it would if the desktop had
        drawn it.
    */
    void applyFrame() {
        if (!drawsDecorations)
            return;
        const flat = backend.tiled()
                  || (SDL_GetWindowFlags(sdl) & (SDL_WindowFlags.SDL_WINDOW_MAXIMIZED | SDL_WindowFlags.SDL_WINDOW_FULLSCREEN)) != 0;
        _scene.setFrame(flat ? 0 : Theme.window_margin, flat ? 0 : Theme.window_radius);
        needsLayout = true;
        updateShape(flat);
    }

    void updateShape(bool flat) {
        // Only for a renderer SDL doesn't draw through: SDL applies a shape's alpha to what it draws
        // itself, which would cut the CPU renderer's shadow off where the shape does
        if (strcmp(renderer.name(), "cpu") == 0)
            return;
        int w, h;
        SDL_GetWindowSize(sdl, &w, &h);
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
        SDL_SetWindowShape(sdl, shape);
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
        // Under a modal window, the press is only to bring that forward: nothing's moved or sized
        if (blockedByModal())
            return SDL_HitTestResult.SDL_HITTEST_NORMAL;
        const sized = !(SDL_GetWindowFlags(sdl) & (SDL_WindowFlags.SDL_WINDOW_MAXIMIZED | SDL_WindowFlags.SDL_WINDOW_FULLSCREEN));
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
        // Where the backend moves the window, the press is the title bar's, to tell a double click
        // from a drag by; elsewhere, the window system moves the window from the press
        if (backend && backend.movesByDrag())
            return SDL_HitTestResult.SDL_HITTEST_NORMAL;
        return bar.dragsWindowAt(x + m - band, y + m - band) ? SDL_HitTestResult.SDL_HITTEST_DRAGGABLE
                                                             : SDL_HitTestResult.SDL_HITTEST_NORMAL;
    }

    // The size limits on the window, if there is one yet: the frame's margin on each side of each
    void applySizeLimits() {
        if (!sdl)
            return;
        int limit(int v) { return v > 0 ? v + 2 * _margin : 0; }
        SDL_SetWindowMinimumSize(sdl, limit(_minWidth), limit(_minHeight));
        SDL_SetWindowMaximumSize(sdl, limit(_maxWidth), limit(_maxHeight));
    }

    // Notes the window's size, as it's resized, maximised or restored (see restoredWidth)
    void noteSize() nothrow @nogc {
        const f = SDL_GetWindowFlags(sdl);
        _wasMaximised = (f & SDL_WindowFlags.SDL_WINDOW_MAXIMIZED) != 0;
        if ((f & (SDL_WindowFlags.SDL_WINDOW_MAXIMIZED | SDL_WindowFlags.SDL_WINDOW_FULLSCREEN
                  | SDL_WindowFlags.SDL_WINDOW_MINIMIZED)) || (backend && backend.tiled()))
            return;
        int w, h;
        SDL_GetWindowSize(sdl, &w, &h);
        if (w > 2 * _margin && h > 2 * _margin) {
            _restoredWidth = w - 2 * _margin;
            _restoredHeight = h - 2 * _margin;
        }
    }
}

/// The desktop's light or dark preference, which SDL reads from the XDG portal on Linux. Light
/// when there's none to read, as JavaFX's default is.
package(mayfair) ColourScheme systemColourScheme() nothrow @nogc {
    return SDL_GetSystemTheme() == SDL_SystemTheme.SDL_SYSTEM_THEME_DARK ? ColourScheme.dark : ColourScheme.light;
}

private:

/// Whether an event is the user's pointer or keyboard: what a modal window keeps from its owner.
bool isUserInput(uint type) nothrow @nogc
{
    switch (type) {
        case SDL_EventType.SDL_EVENT_MOUSE_MOTION:
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
        case SDL_EventType.SDL_EVENT_MOUSE_WHEEL:
        case SDL_EventType.SDL_EVENT_KEY_DOWN:
        case SDL_EventType.SDL_EVENT_KEY_UP:
        case SDL_EventType.SDL_EVENT_TEXT_INPUT:
        case SDL_EventType.SDL_EVENT_TEXT_EDITING:
            return true;
        default:
            return false;
    }
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

KeyEvent keyEvent(ref const SDL_KeyboardEvent key, KeyEventType type) nothrow @nogc
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

/// SDL's button index as a MouseButton.
MouseButton mouseButton(ubyte sdlButton) nothrow @nogc
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

extern(C) SDL_HitTestResult hitTest(SDL_Window* window, const(SDL_Point)* area, void* data) nothrow @nogc
{
    auto w = cast(Window) data;
    return w.hitTestAt(w.toPoints(area.x), w.toPoints(area.y));
}

version (Emscripten)
{
    // SDL 3.4's, newer than the sdl-d binding, and Emscripten's SDL is 3.4
    extern (C) bool SDL_SetWindowFillDocument(SDL_Window* window, bool fill) nothrow @nogc;
}
