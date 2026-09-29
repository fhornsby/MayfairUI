module mayfair.widgets.scene;

import mayfair.accessibility;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.trace;
import mayfair.layout;
import mayfair.theme;
import mayfair.css;
import mayfair.widgets.widget;
import mayfair.widgets.input;
import mayfair.widgets.styling;
import mayfair.widgets.popup;
import mayfair.widgets.titlebar : TitleBar;
import mayfair.widgets.label : Label;
import mayfair.widgets.layouts : Alignment;
import mayfair.animation;
import core.time : MonoTime;

/// Light or dark, as a desktop's preference or a scene's own choice. JavaFX's ColourScheme, and
/// `system` for following the desktop's.
enum ColourScheme { system, light, dark }

/*
    A Scene is what a window shows: one widget, the tree hanging off it, and the colour behind it.

    It isn't a widget, deliberately. It's the join between the window and the tree, which is a
    different job from being a box in a layout: it owns the two things every widget needs to come
    alive (the Yoga config its node is made with, the ThorVG scene its shape is added to), it paints
    the background, and it resizes its root to fill the window. Keeping that out of the widget tree
    is what lets the root be whatever widget the app wrote, rather than something the library
    supplies and the app has to hang its real content off.
*/
class Scene
{
public:
    /// The colour behind everything. JavaFX's Scene.fill.
    mixin(declareProperty!(Colour, "fill", "Theme.background_colour", q{
        if (background)
        {
            tvg_shape_set_fill_color(background, _fill.tupleof);
            paintRequested = true;
        }
    }));

    this(Widget root) nothrow @nogc
    {
        _root = root;
    }

    /// The widget at the top of the tree.
    inout(Widget) root() inout nothrow @nogc { return _root; }

    /// Stylesheets for everything in the scene, over the built-in theme. JavaFX's getStylesheets().
    final StylesheetList stylesheets()
    {
        if (!_stylesheets)
            _stylesheets = new StylesheetList(&restyleAll);
        return _stylesheets;
    }

    /// A theme to use in place of the built-in one. JavaFX's Scene.userAgentStylesheet.
    mixin(declareProperty!(Stylesheet, "userAgentStylesheet", "null", q{ restyleAll(); }));

    /// Whether stylesheets' @media (prefers-colour-scheme) rules see it as light or dark: the
    /// desktop's choice, unless it's given one of its own.
    mixin(declareProperty!(ColourScheme, "colourScheme", "ColourScheme.system", q{ restyleAll(); }));

    /// Light or dark, as the scene is styled now.
    ColourScheme effectiveColourScheme() const nothrow @nogc
    {
        return _colourScheme == ColourScheme.system ? platformColourScheme : _colourScheme;
    }

    /*
        Everything below goes in one ThorVG scene so that HiDPI is a single transform on it, and
        painting can work in points and never mention scale. A scene with no effects and full opacity
        needs no intermediate buffer and doesn't coarsen ThorVG's dirty regions: only a fixed-size
        scene (Scene::size(), which the C API doesn't expose) turns per-shape damage tracking off.
    */
    void attach(Tvg_Canvas canvas) nothrow
    {
        // The shadow a window casts when it draws its own frame goes under everything, and the
        // outline round it over everything (see setFrame)
        frameShadow = tvg_scene_new();
        foreach (ref ring; frameShadowRings)
        {
            ring = tvg_shape_new();
            tvg_shape_set_fill_rule(ring, TVG_FILL_RULE_EVEN_ODD); // a ring: the window's own rect is a hole
            tvg_scene_add(frameShadow, ring);
        }
        tvg_canvas_add(canvas, frameShadow);

        paints = tvg_scene_new();
        tvg_canvas_add(canvas, paints);

        frameOutline = tvg_shape_new();
        tvg_canvas_add(canvas, frameOutline);

        // One config for every node in the tree: Yoga reads the point scale factor from each node's
        // own config when it rounds to the pixel grid, and a child doesn't inherit its parent's.
        // setScale() sets the factor on it once there's a window to ask about scale.
        config = YGConfigNew();

        background = tvg_shape_new();
        tvg_shape_set_fill_color(background, _fill.tupleof);
        tvg_scene_add(paints, background); // added first, so it's drawn behind the tree

        _root.styleClass.add("root"); // what a theme's .root rule, and its variables, are for
        _root.mount(this, paints);
        if (_titleBar)
            mountTitleBar();

        // The root fills the window. It's in percentages so a resize doesn't have to restyle it:
        // layout() passes the window size for them to resolve against.
        YGNodeStyleSetWidthPercent(_root.node, 100);
        YGNodeStyleSetHeightPercent(_root.node, 100);
    }

    /*
        Lets go of the canvas and the config, as the window closes. The tree is unmounted first,
        while the canvas is still there: the canvas frees every paint when it goes, and a widget
        still holding one -- or still playing an animation that draws into one, as a LottieView
        does -- would be left using freed memory. Unmounted, each widget has let go of its paints
        and put anything under way back to rest, and could be shown again in another scene.

        The nodes aren't the scene's to free -- each belongs to its widget, which frees it when it
        goes -- so they're only moved off the config first.
    */
    void detach() nothrow
    {
        try
        {
            while (popups.length)
                hidePopup(popups[$ - 1]);
            if (_titleBar)
                _titleBar.unmountTree();
            _root.unmountTree();
        }
        catch (Exception) {}
        releaseConfig(_root);
        YGConfigFree(config);
    }

    /// Device pixels per point. Widgets work in points and don't need this; text is the exception,
    /// because a glyph has to land on the pixel grid to rasterise the same way twice.
    float scale() const nothrow @nogc { return _scale; }

    /// Pixels the renderer draws per point: the display's scale times any render scale of the
    /// renderer's own (see setScale). What a bitmap is made at to be drawn one texel to a pixel.
    float pixelScale() const nothrow @nogc { return paintScale; }

    /*
        Both halves of HiDPI in one place: what Yoga rounds layout to, and what turns the points
        everything else works in into device pixels.

        `renderScale` is separate, and is the renderer's business rather than the display's: a
        renderer that draws bigger than the window and scales down on the way to the screen asks for
        it here. It multiplies the scene transform and nothing else. Layout still rounds to device
        pixels and text still lands on the device pixel grid, because those are about where things
        sit on the screen being looked at, not how many pixels the renderer drew getting there.
    */
    void setScale(float scale, float renderScale = 1.0f) nothrow @nogc
    {
        _scale = scale;
        YGConfigSetPointScaleFactor(config, scale);
        tvg_paint_scale(paints, scale * renderScale);
        tvg_paint_scale(frameShadow, scale * renderScale);
        tvg_paint_scale(frameOutline, scale * renderScale);
        paintScale = scale * renderScale;
        if (frameClip)
            tvg_paint_scale(frameClip, paintScale);

        // Anything grid-fitted was fitted to the old pixel grid. A widget drawing plain geometry
        // wouldn't care, but hinted glyph outlines are baked for one scale, and paintTree skips a
        // widget whose rectangle hasn't moved -- which in points it may well not have.
        if (_root)
            _root.invalidateTree();
    }

    /// Sizes and positions the whole tree for a window `w` x `h` points.
    void layout(float windowWidth, float windowHeight) nothrow @nogc
    {
        // Inside the frame's margin, where there is one: the window's shadow is round the outside
        const m = frameMargin;
        const w = windowWidth - 2 * m > 0 ? windowWidth - 2 * m : 0;
        const h = windowHeight - 2 * m > 0 ? windowHeight - 2 * m : 0;
        contentWidth = w;
        contentHeight = h;
        // The title bar along the top at its own height, and the root in what's below it
        float top = 0;
        if (_titleBar)
        {
            YGNodeCalculateLayout(_titleBar.node, w, float.nan, YGDirectionLTR);
            _titleBar.cellX = m;
            _titleBar.cellY = m;
            top = YGNodeLayoutGetHeight(_titleBar.node);
        }
        _root.cellX = m;
        _root.cellY = m + top;
        YGNodeCalculateLayout(_root.node, w, h - top > 0 ? h - top : 0, YGDirectionLTR);
        // Each popup as big as it asks, but inside the window, with a margin if there's room for one
        foreach (p; popups)
        {
            float room(float window, float own)
            {
                const inside = window > 4 * Theme.popup_margin ? window - 2 * Theme.popup_margin : window;
                return own == own && own < inside ? own : inside;
            }
            YGNodeStyleSetMaxWidth(p.node, room(w, p.maxWidth));
            YGNodeStyleSetMaxHeight(p.node, room(h, p.maxHeight));
            YGNodeCalculateLayout(p.node, float.nan, float.nan, YGDirectionLTR);
            p.place(m, m, w, h);
        }
        popupsMoved = false;
    }

    /// Whether anything needs laying out again: the tree, a popup, or which popups there are.
    bool layoutNeeded() nothrow @nogc
    {
        if (popupsMoved || YGNodeIsDirty(_root.node) || (_titleBar && YGNodeIsDirty(_titleBar.node)))
            return true;
        foreach (p; popups)
            if (YGNodeIsDirty(p.node))
                return true;
        return false;
    }

    /// Updates every shape to match the layout.
    void paint(float windowWidth, float windowHeight) nothrow @nogc
    {
        const m = frameMargin, r = frameRadius;
        const w = contentWidth, h = contentHeight;
        tvg_shape_reset(background);
        tvg_shape_append_rect(background, m, m, w, h, 0, 0, true);
        paintFrame(m, r, w, h);
        _root.paintTree(0, 0);
        if (_titleBar)
            _titleBar.paintTree(0, 0);
        foreach (p; popups)
        {
            if (p._scrim)
            {
                tvg_shape_reset(p._scrim);
                tvg_shape_append_rect(p._scrim, 0, 0, w, h, 0, 0, true);
                tvg_paint_set_opacity(p._scrim, cast(ubyte)(p._shownAmount * 255));
            }
            p.paintTree(0, 0, 0, 0, p._shownAmount);
        }
    }

    /*
        The bar along the top of the window, drawn by the app: see TitleBar. Given one, the window
        draws its own decorations; without, the desktop draws them where it will, and the App
        gives it a plain one where it won't. The root goes below it.
    */
    final TitleBar titleBar() nothrow @nogc { return _titleBar; }

    /// ditto
    final Scene titleBar(TitleBar bar)
    {
        if (_titleBar && paints)
            _titleBar.unmountTree();
        _titleBar = bar;
        titleBarChosen = bar !is null;
        if (bar)
        {
            bar.styleOwner = _root; // the root's palette, and font
            if (paints)
                mountTitleBar();
        }
        popupsMoved = windowChildrenChanged = true;
        paintRequested = true;
        return this;
    }

    /// The popups showing, from the bottom up: menus, drop-down lists, tooltips, dialogs.
    const(Popup)[] showingPopups() const nothrow @nogc { return popups; }

    /// The widget with focus, whether or not the window has it right now; null for none. JavaFX's focusOwner.
    Widget focusedWidget() nothrow @nogc { return focusOwner; }

package:
    // What a widget needs from its scene, and nothing user code has any business touching.
    YGConfigRef config;
    Tvg_Paint paints;
    bool paintRequested; // set by Widget.invalidate(), so the app knows to paint
    bool accessibilityChanged = true; // set by Widget.invalidateAccessible(), and by focus moving
    bool cssRequested = true; // set by markCssDirty(), for the next style pass

package:
    // What a widget asks of its scene.

    /// Gives `w` focus, or takes it from everything if `w` is null. `shown` is whether it came
    /// from the keyboard, and so should be drawn.
    void setFocus(Widget w, bool shown)
    {
        if (w !is focusOwner)
            accessibilityChanged = true;
        auto previous = focusOwner;
        focusOwner = w;
        focusShown = shown;
        if (previous && previous !is w)
            refreshFocus(previous);
        if (w)
            refreshFocus(w);
        // Tab to something scrolled out of view and it's scrolled into it. A click doesn't, as it
        // would move what's being clicked out from under the pointer.
        if (w && shown && w !is previous)
            w.scrollIntoView();
    }

    bool focusOwnerIs(const Widget w) const nothrow @nogc { return focusOwner is w; }

    /// Takes focus away if it's in the tree under `w`, which is being disabled or removed.
    void forgetFocusWithin(Widget w)
    {
        if (isWithin(focusOwner, w))
            setFocus(null, false);
    }

    /// Lets go of everything the scene knows about the tree under `gone`, which is being removed.
    void forget(Widget gone)
    {
        foreach_reverse (p; popups.dup)
            if (p !is gone && p._showingIn && isWithin(p.owner, gone))
                hidePopup(p);
        forgetFocusWithin(gone);
        if (isWithin(tooltipFor, gone))
        {
            hideTooltip();
            tooltipFor = null;
        }
        if (isWithin(grabbed, gone))
        {
            // The press is over, for the ancestors too: there's nothing left for it to be released on
            for (auto w = grabbed; w; w = w.parent)
                w._setPressed(false);
            grabbed = null;
            buttonsDown = 0;
        }
        if (isWithin(hovered, gone))
        {
            // The pointer is still over the parent, as far as anyone knows until the next repick
            for (auto w = hovered; w !is gone.parent; w = w.parent)
                w._setHover(false);
            hovered = gone.parent;
        }
    }

package(mayfair):
    ColourScheme platformColourScheme = ColourScheme.light; // the desktop's, as the App last heard it

    /// Everything to be restyled: a stylesheet or the colour scheme changed.
    void restyleAll() nothrow @nogc
    {
        if (!_root)
            return;
        markCssDirty(_root, true);
        if (_titleBar)
            markCssDirty(_titleBar, true);
        foreach (p; popups)
            markCssDirty(p, true);
        cssRequested = true;
    }

    /*
        The accessibility tree, as AccessKit wants it: every node if `full`, which is what it asks
        for when a screen reader first connects, and otherwise only the widgets that changed since
        the last update. The window is a node of its own, id 0, above the root widget.

        Widgets work in points, and AccessKit wants the window's coordinates, so the window node
        carries a transform from one to the other and every widget's bounds go through it.
        `pointsToWindow` is that factor, and `title` the window's name.
    */
    accesskit_tree_update* buildAccessibilityUpdate(bool full, const(char)[] title, double pointsToWindow)
    {
        auto update = accesskit_tree_update_with_focus(accessibleFocus());
        trace("a11y  %s update, focus %llu", full ? "full".ptr : "partial".ptr, accessibleFocus());
        if (full)
        {
            auto info = accesskit_tree_info_new(windowNodeId);
            enum toolkit = "Mayfair";
            accesskit_tree_info_set_toolkit_name_with_length(info, toolkit.ptr, toolkit.length);
            accesskit_tree_update_set_tree_info(update, info);
        }
        if (full || pointsToWindow != sentPointsToWindow || windowChildrenChanged)
        {
            sentPointsToWindow = pointsToWindow;
            windowChildrenChanged = false;
            auto window = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);
            accesskit_node_set_label_with_length(window, title.ptr, title.length);
            accesskit_node_set_transform(window, accesskit_affine_scale(pointsToWindow));
            foreach (top; topLevel)
            {
                if (top.accessibleHidden)
                    top.pushAccessibleChildren(window);
                else
                    accesskit_node_push_child(window, top.accessibleId);
            }
            accesskit_tree_update_push_node(update, windowNodeId, window);
        }
        foreach (top; topLevel)
            pushChanged(update, top, full);
        accessibilityChanged = false;
        return update;
    }

    /// Whether buildAccessibilityUpdate() would have anything to say.
    bool accessibilityPending(double pointsToWindow) const nothrow @nogc
    {
        return accessibilityChanged || windowChildrenChanged || pointsToWindow != sentPointsToWindow;
    }

    /*
        Does what AccessKit was asked to do to the node with id `target`, if it's still here. A node
        a widget added below itself, like a text run, isn't a widget, so the request goes to the
        widget that added it -- the nearest one above it -- which knows what the node is.
    */
    void performAccessibleAction(ulong target, accesskit_action requested, ref const AccessibleActionData data)
    {
        AccessibleAction action;
        if (!fromAccessKit(requested, action))
            return;
        foreach (top; topLevel)
            if (auto w = findAccessible(top, target))
            {
                w.performAccessibleAction(action, data);
                return;
            }
    }

    /// The pointer shape for where the pointer is: the first widget up from the one it's over
    /// that says what it wants. Disabled widgets get the default.
    Cursor currentCursor() nothrow @nogc
    {
        for (auto w = hovered; w; w = w.parent)
        {
            if (w.disabled)
                return Cursor.default_;
            if (w.cursor != Cursor.inherit)
                return w.cursor;
        }
        return Cursor.default_;
    }

    /// Whether anything has been invalidated since the last time this was asked.
    bool takePaintRequest() nothrow @nogc
    {
        const requested = paintRequested;
        paintRequested = false;
        return requested;
    }

    /*
        The mouse, as the app hears it from the window, in points from the window's top left.

        This is JavaFX's Scene mouse handling in miniature. Whatever the pointer is over has hover
        set on it and every ancestor, and hears entered and exited as that changes. Whatever a
        button goes down on keeps getting the events until every button is up again -- an
        implicit grab -- so a widget that saw a press always sees its release, even if the pointer
        has left the widget, or the window, by then.
    */
    void mouseMoved(float x, float y)
    {
        pointAt(x, y);
        hoverOver(pickAt(x, y));
        if (grabbed)
            bubble(grabbed, MouseEventType.dragged, MouseButton.none, 0);
        else if (hovered)
            bubble(hovered, MouseEventType.moved, MouseButton.none, 0);
    }

    void mousePressed(float x, float y, MouseButton button, int clicks)
    {
        pointAt(x, y);
        hoverOver(pickAt(x, y));
        // A press outside the popups that hide on one hides them, and does nothing else. On a popup
        // lower down -- a menu under its submenu -- it hides those over it.
        hideTooltip();
        if (!grabbed && hidePopupsOver(hovered))
            return;
        if (!grabbed)
            grabbed = hovered;
        if (!grabbed)
            return;
        buttonsDown |= 1 << button;
        if (button == MouseButton.primary)
            for (auto w = grabbed; w; w = w.parent)
                w._setPressed(true);
        bubble(grabbed, MouseEventType.pressed, button, clicks);
        if (button == MouseButton.secondary)
            showContextMenu(hovered, pointerX, pointerY);
    }

    void mouseReleased(float x, float y, MouseButton button, int clicks)
    {
        pointAt(x, y);
        hoverOver(pickAt(x, y));
        if (!grabbed)
            return;
        auto target = grabbed;
        buttonsDown &= ~(1 << button);
        if (!buttonsDown)
            grabbed = null;

        bubble(target, MouseEventType.released, button, clicks);
        // A click goes to the deepest widget both the press and the release were over: press on a
        // button's text and let go on its edge, and it's still the button that was clicked
        for (auto w = target; w; w = w.parent)
        {
            if (w.hover)
            {
                bubble(w, MouseEventType.clicked, button, clicks);
                break;
            }
        }
        if (button == MouseButton.primary)
            for (auto w = target; w; w = w.parent)
                w._setPressed(false);
    }

    /// The wheel or a touchpad scrolled by `dx`, `dy` points with the pointer at `x`, `y`. It goes
    /// to what's under the pointer and bubbles up. See ScrollEvent.
    void scrolled(float x, float y, float dx, float dy, ScrollDevice device = ScrollDevice.wheel, double time = 0)
    {
        hideTooltip();
        pointAt(x, y);
        hoverOver(pickAt(x, y));
        if (!hovered)
            return;
        auto event = ScrollEvent(dx, dy, pointerX, pointerY);
        event.shift = heldShift;
        event.control = heldControl;
        event.alt = heldAlt;
        event.meta = heldMeta;
        event.target = hovered;
        event.device = device;
        event.time = time;
        for (auto w = hovered; w && !event.consumed;)
        {
            auto next = w.parent;
            w.deliver(event);
            w = next;
        }
    }

    /// Which modifier keys are held, for the mouse events that follow to carry.
    void modifiers(bool shift, bool control, bool alt, bool meta) nothrow @nogc
    {
        heldShift = shift;
        heldControl = control;
        heldAlt = alt;
        heldMeta = meta;
    }

    /// The pointer left the window, so it's over nothing.
    void mouseLeft()
    {
        pointerInside = false;
        hoverOver(null);
    }

    /*
        Works out again what the pointer is over, for after the layout has moved things. The pointer
        hasn't moved, so nothing else would: resize the window under a still mouse and the button
        that slides out from under it would stay lit. JavaFX does the same on every pulse that laid
        anything out. It has to wait until the new layout has been painted, since picking goes by
        where things were painted.
    */
    void repick()
    {
        if (pointerInside)
            hoverOver(pickAt(pointerX, pointerY));
    }

    /*
        The keyboard. A key goes to the widget with focus, or the root if nothing has it, and
        bubbles up. Whatever nothing consumed, the scene has its own uses for: Tab and Shift+Tab
        move focus, and anything else is offered round the tree as a shortcut.
    */
    void keyPressed(KeyEvent event)
    {
        hideTooltip();
        bubble(event);
        if (event.consumed)
            return;
        if (event.code == KeyCode.application || event.code == KeyCode.menu
            || (event.code == KeyCode.f10 && event.shift))
        {
            if (focusOwner)
            {
                const b = focusOwner.boundsIn(null);
                showContextMenu(focusOwner, b.minX, b.maxY);
            }
            return;
        }
        if (event.code == KeyCode.escape && popups.length && popups[$ - 1].autoHide && !popups[$ - 1].modal)
        {
            hidePopup(popups[$ - 1]);
            return;
        }
        // Ctrl+Tab too, for getting out of something that takes Tab itself, as a text area does
        if (event.code == KeyCode.tab && !event.alt && !event.meta)
        {
            traverse(event.shift ? -1 : 1);
            return;
        }
        offerShortcut(event);
    }

    void keyReleased(KeyEvent event)
    {
        bubble(event);
        if (!event.consumed)
            offerShortcut(event);
    }

    /// Text typed into the widget with focus, bubbling up from it.
    void keyTyped(string text)
    {
        KeyEvent event;
        event.type = KeyEventType.typed;
        event.character = text;
        bubble(event);
    }

    /// An input method's composition changed, which the widget with focus hears first.
    void inputMethodTextChanged(string composed, int caret, int selectionLength)
    {
        auto event = InputMethodEvent(composed, caret, selectionLength);
        bubble(event);
    }

    /// The widget text input is for right now, or null: the focused widget, if it takes text.
    Widget textInputOwner() nothrow @nogc
    {
        if (focusOwner && focusOwner.focused && focusOwner.acceptsTextInput && !focusOwner.disabled)
            return focusOwner;
        return null;
    }

    /// The window gained or lost keyboard focus, and so did whatever widget has focus in it.
    void windowFocus(bool focused)
    {
        windowFocused = focused;
        shadeFrame();
        paintRequested = true;
        if (_titleBar)
            _titleBar.windowFocused(focused);
        if (focusOwner)
            refreshFocus(focusOwner);
    }

package(mayfair):
    /*
        The frame a window draws round itself when it draws its own decorations: its content inset
        by `margin` points, with rounded corners of `radius`, a shadow in the margin -- lighter
        while the window hasn't focus -- and a faint outline, so its edge can be seen against a
        window of the same colour behind it. No margin for a maximised window, which has no edges
        to show. See the App, which says which.
    */
    void setFrame(float margin, float radius) nothrow @nogc
    {
        if (margin == frameMargin && radius == frameRadius)
            return;
        frameMargin = margin;
        frameRadius = radius;
        shadeFrame();
        if (_root)
            _root.invalidateTree();
        if (_titleBar)
            _titleBar.invalidateTree();
        popupsMoved = true; // lays everything out again, in the new content area
        paintRequested = true;
    }

    float frameMargin = 0, frameRadius = 0;
    float contentWidth = 0, contentHeight = 0; // as of the last layout

    WindowControls windowControls; // what the title bar's buttons ask the window to do, from the App
    void* nativeWindow;            // the SDL_Window it's in, from the App, for what the desktop shows over it
    bool titleBarChosen;           // the app gave it its title bar, rather than the App a plain one

    /// The window was maximised or restored, for the title bar's button to say which it does.
    void windowMaximised(bool on)
    {
        if (_titleBar)
            _titleBar.windowMaximised(on);
    }

    void mountTitleBar() nothrow
    {
        _titleBar.mount(this, paints);
        markCssDirty(_titleBar, true);
    }

    Popup[] popups;             // showing, bottom to top
    bool popupsMoved;           // one's been shown or hidden, so layout has to run
    bool windowChildrenChanged; // the window's accessibility node has to list them again

    /// Shows `p`, which Popup.show() has placed and given an owner, over everything else.
    void showPopup(Popup p)
    {
        // A layer of its own, over everything before it: the dimming behind a modal one, then
        // the popup in a scene of its own, which is what casts the shadow
        p._showingIn = this;
        p._layer = tvg_scene_new();
        if (p.modal)
        {
            p._scrim = tvg_shape_new();
            tvg_shape_set_fill_color(p._scrim, Theme.popup_scrim.tupleof);
            tvg_scene_add(p._layer, p._scrim);
        }
        auto inner = tvg_scene_new();
        const s = Theme.popup_shadow;
        tvg_scene_add_effect_drop_shadow(inner, s.r, s.g, s.b, s.a, 90, Theme.popup_shadow_offset,
                                         Theme.popup_shadow_blur, 50);
        tvg_scene_add(p._layer, inner);
        tvg_scene_add(paints, p._layer);
        popups ~= p;
        p.mount(this, inner);
        markCssDirty(p, true);
        popupsMoved = windowChildrenChanged = true;
        paintRequested = accessibilityChanged = true;
        if (p.takesFocus)
        {
            p._focusBefore = focusOwner;
            p._focusShownBefore = focusShown;
            Widget[] order;
            p.collectTraversable(order);
            setFocus(order.length ? order[0] : p, focusShown);
        }
        p.opened();
    }

    /// Hides `p`, and every popup shown over it since.
    void hidePopup(Popup p)
    {
        ptrdiff_t at = -1;
        foreach (i, q; popups)
            if (q is p)
                at = i;
        if (at < 0)
            return;
        while (popups.length > at + 1)
            hidePopup(popups[$ - 1]);
        const hadFocus = isWithin(focusOwner, p);
        forget(p);
        p.unmountTree();
        tvg_scene_remove(paints, p._layer); // and everything in it
        p._layer = p._scrim = null;
        popups = popups[0 .. at] ~ popups[at + 1 .. $];
        p._showingIn = null;
        // Focus back where it was, if it went into the popup and that's still here to have it
        if (hadFocus && p._focusBefore && p._focusBefore.scene is this && !p._focusBefore.disabled)
            setFocus(p._focusBefore, p._focusShownBefore);
        p._focusBefore = null;
        popupsMoved = windowChildrenChanged = true;
        paintRequested = accessibilityChanged = true;
        p.closed();
    }

    /// The root, and each popup: the tops of what's in the window.
    Widget[] topLevel() nothrow
    {
        Widget[] all;
        if (_titleBar)
            all ~= _titleBar;
        all ~= _root;
        foreach (p; popups)
            all ~= p;
        return all;
    }

private:
    float _scale = 1.0f;
    Widget _root;
    TitleBar _titleBar;
    Tvg_Paint frameShadow, frameOutline, frameClip;
    Tvg_Paint[16] frameShadowRings;
    float paintScale = 1; // the scene's scale, device pixels to the point and any render scale

    void paintFrame(float m, float r, float w, float h) nothrow @nogc
    {
        // Only when something about it changed: it's a dozen shapes, the same every frame otherwise
        const dark = effectiveColourScheme == ColourScheme.dark;
        const key = FrameKey(m, r, w, h, windowFocused, dark);
        if (key == paintedFrame)
            return;
        paintedFrame = key;

        tvg_shape_reset(frameOutline);
        foreach (ring; frameShadowRings)
            tvg_shape_reset(ring);
        if (m <= 0)
        {
            if (frameClip)
            {
                tvg_paint_set_mask_method(paints, null, TVG_MASK_METHOD_NONE);
                frameClip = null;
            }
            return;
        }

        /*
            The shadow: rings round the window, each a little bigger than the last and faint, so
            where more of them overlap -- near the window -- it's darker. Each ring's alpha is
            worked out so that, stacked, they follow the edge of a Gaussian blur: half the
            shadow's strength at the window's edge, fading smoothly to nothing three blur widths
            out. A blur's look, for a few flat shapes rather than blurring the window's area every
            frame -- which, under the corners' mask, costs ThorVG's GPU engine 20 ms a frame.
        */
        import std.mathspecial : erfc;
        const s = windowFocused ? Theme.window_shadow : Theme.window_shadow_backdrop;
        const sigma = windowFocused ? Theme.window_shadow_blur : Theme.window_shadow_blur * 0.75f;
        const down = windowFocused ? Theme.window_shadow_offset : Theme.window_shadow_offset / 2;
        enum n = frameShadowRings.length;
        const spread = 3 * sigma;
        // How dark the shadow is at `d` points out from the window's edge
        double shadowAt(double d) { return s.a / 255.0 * 0.5 * erfc(d / (sigma * 1.41421356)); }
        // Band k lies between rings k-1 and k, and is covered by rings k to n. Seen through them it
        // should be as dark as the shadow at its middle, which fixes each ring's alpha in turn.
        foreach (k, ring; frameShadowRings)
        {
            const inner = spread * k / n, outer = spread * (k + 1) / n;
            const here = shadowAt((inner + outer) / 2);
            const next = k + 1 < n ? shadowAt((outer + spread * (k + 2) / n) / 2) : 0.0;
            const alpha = 1 - (1 - here) / (1 - next);
            tvg_shape_append_rect(ring, m - outer, m - outer + down, w + 2 * outer, h + 2 * outer, r + outer, r + outer, true);
            tvg_shape_append_rect(ring, m, m, w, h, r, r, true);
            tvg_shape_set_fill_color(ring, 0, 0, 0, cast(ubyte)(alpha * 255 + 0.5));
        }

        /*
            The content, rounded at the corners: masked by a rounded rectangle, not clipped. A clip
            on the whole scene, with the clips inside it that scroll panes make, takes ThorVG's GPU
            engine over a second a frame; a mask costs it a few milliseconds. The mask is in the
            space of what it's on's parent -- the canvas -- so it's scaled as the scene is.
        */
        if (!frameClip)
        {
            frameClip = tvg_shape_new();
            tvg_paint_scale(frameClip, paintScale);
            tvg_paint_set_mask_method(paints, frameClip, TVG_MASK_METHOD_ALPHA);
        }
        tvg_shape_reset(frameClip);
        tvg_shape_append_rect(frameClip, m, m, w, h, r, r, true);
        tvg_shape_set_fill_color(frameClip, 255, 255, 255, 255); // a mask goes by its pixels' alpha
        // A hairline round it, half a point in, so it's all inside the window
        tvg_shape_append_rect(frameOutline, m + 0.5f, m + 0.5f, w - 1, h - 1, r - 0.5f, r - 0.5f, true);
        const c = dark ? Theme.window_outline_dark : Theme.window_outline;
        tvg_shape_set_fill_color(frameOutline, 0, 0, 0, 0);
        tvg_shape_set_stroke_width(frameOutline, 1);
        tvg_shape_set_stroke_color(frameOutline, c.tupleof);
    }

    /// The shadow's strength follows focus, as GNOME's does: drawn again on the next paint.
    void shadeFrame() nothrow @nogc
    {
        paintedFrame = FrameKey.init;
        paintRequested = true;
    }

    // What the frame was last drawn for
    struct FrameKey
    {
        float margin = -1, radius = 0, width = 0, height = 0;
        bool focused, dark;
    }
    FrameKey paintedFrame;

    StylesheetList _stylesheets;
    Tvg_Paint background;

    float pointerX = 0, pointerY = 0;
    bool heldShift, heldControl, heldAlt, heldMeta;
    bool pointerInside;  // whether the pointer is in the window, as far as the last event said
    Widget hovered;      // the deepest widget under the pointer
    Widget grabbed;      // the widget a button went down on, while any button is down
    uint buttonsDown;    // a bit per MouseButton

    Widget focusOwner;   // the widget with focus, whether or not the window has it right now
    bool focusShown;     // whether focus got there by keyboard, so should be drawn
    bool windowFocused = true;

    MouseEvent mouseEvent(MouseEventType type, MouseButton button, int clicks) nothrow @nogc
    {
        auto event = MouseEvent(type, button, clicks, pointerX, pointerY);
        event.shift = heldShift;
        event.control = heldControl;
        event.alt = heldAlt;
        event.meta = heldMeta;
        return event;
    }

    /*
        What's at `x`, `y`: the topmost popup there, or the tree -- unless a popup that hides on a
        press elsewhere, or a modal one, is showing, when the rest of the window is out of reach.
        A popup the pointer passes through, like a tooltip, is never what's there. What a popup
        keeps within reach -- a menu's menu bar -- is still there, unless a modal one is showing.
    */
    Widget pickAt(float x, float y) nothrow @nogc
    {
        bool blocked, modal;
        foreach_reverse (p; popups)
        {
            if (p.pointerTransparent)
                continue;
            if (auto hit = p.pick(x, y))
                return hit;
            blocked = blocked || p.autoHide || p.modal;
            modal = modal || p.modal;
        }
        Widget hit;
        if (_titleBar)
            hit = _titleBar.pick(x, y);
        if (!hit)
            hit = _root.pick(x, y);
        if (modal || (blocked && !reachable(hit)))
            return null;
        return hit;
    }

    /// Whether `w` is within what a showing popup keeps within reach of the pointer.
    bool reachable(Widget w, const Popup only = null) nothrow @nogc
    {
        foreach (p; popups)
            if (!only || p is only)
                foreach (r; p._reachable)
                    if (isWithin(w, r))
                        return true;
        return false;
    }

    /*
        A press landed on `target`, which may be nothing: hides the popups over it that hide on a
        press outside them, down to a modal one or the one it's in -- or the one that keeps it
        within reach, which leaves it to that to say what the press does. Whether that's all the
        press does: it was outside any popup, so there's nothing for it to go to.
    */
    bool hidePopupsOver(Widget target)
    {
        bool hid;
        for (ptrdiff_t i = cast(ptrdiff_t) popups.length - 1; i >= 0; i--)
        {
            auto p = popups[i];
            if (p.pointerTransparent)
                continue; // a tooltip over a menu doesn't stop the menu going
            if (p.modal || !p.autoHide || isWithin(target, p) || reachable(target, p))
                break;
            hidePopup(p); // and anything over it
            hid = true;
            i = cast(ptrdiff_t) popups.length; // from the top again, as it's shorter now
        }
        return hid && !target;
    }

    /*
        Tooltips. Resting on a widget with one -- or on something inside it without one of its own
        -- shows it after a moment, below it and in the middle. Moving to another soon after one
        was showing shows the next straight away, so running the pointer along a toolbar reads
        each in turn. A press, a key or a scroll puts it away.
    */
    Popup tooltip;
    Label tooltipText;
    Widget tooltipFor;       // what the pointer's resting on that has one
    Timeline tooltipDelay;
    MonoTime tooltipHiddenAt;

    void tooltipHover(Widget leaf)
    {
        Widget w = leaf;
        while (w && !w.tooltip.length)
            w = w.parent;
        if (w is tooltipFor)
            return;
        const wasShowing = tooltip && tooltip.showing;
        hideTooltip();
        tooltipFor = w;
        if (!w || w.disabled)
            return;
        if (!tooltipDelay)
            tooltipDelay = new Timeline(KeyFrame(Theme.tooltip_delay, { showTooltip(); }));
        const recently = wasShowing || MonoTime.currTime - tooltipHiddenAt < Theme.tooltip_browse_time;
        if (recently)
            showTooltip();
        else
            tooltipDelay.playFromStart();
    }

    void showTooltip()
    {
        if (!tooltipFor || tooltipFor.scene !is this || !tooltipFor.tooltip.length)
            return;
        if (!tooltip)
        {
            tooltipText = new Label("").wrapText(true).maxWidth(Theme.tooltip_max_width);
            tooltip = new Popup(tooltipText).autoHide(false).takesFocus(false).pointerTransparent(true);
            tooltip.styleClass.add("tooltip");
            tooltip.setAccessibleHidden(true); // the widget's description says it already
        }
        tooltipText.setText(tooltipFor.tooltip);
        tooltip.show(tooltipFor, Side.below, 6, Alignment.centre);
    }

    void hideTooltip()
    {
        if (tooltipDelay)
            tooltipDelay.stop();
        if (tooltip && tooltip.showing)
        {
            tooltip.hide();
            tooltipHiddenAt = MonoTime.currTime;
        }
    }

    /// Shows the context menu of `w`, or of the nearest widget round it with one, at `x`, `y`.
    void showContextMenu(Widget w, float x, float y)
    {
        while (w && !w.contextMenu)
            w = w.parent;
        if (w && !w.disabled)
            w.contextMenu.showAt(w, x, y);
    }

    /// Offers a key nothing took as a shortcut: to the popup with focus, or the tree and its title bar.
    void offerShortcut(ref KeyEvent event)
    {
        auto scope_ = focusScope;
        scope_.offerShortcut(event);
        if (!event.consumed && scope_ is _root && _titleBar)
            _titleBar.offerShortcut(event);
    }

    /// Where Tab moves and shortcuts go: the topmost popup that has focus, or the whole tree.
    Widget focusScope() nothrow @nogc
    {
        foreach_reverse (p; popups)
            if (p.modal || (p.takesFocus && isWithin(focusOwner, p)))
                return p;
        return _root;
    }

    void pointAt(float x, float y)
    {
        pointerX = x;
        pointerY = y;
        pointerInside = true;
    }

    /// Moves focus to the next widget Tab can reach, or the previous one if `direction` is -1.
    void traverse(int direction)
    {
        Widget[] order;
        auto scope_ = focusScope;
        if (scope_ is _root && _titleBar)
            _titleBar.collectTraversable(order); // the bar first, as it's first in the window
        scope_.collectTraversable(order);
        if (!order.length)
            return;
        ptrdiff_t at = -1;
        foreach (i, w; order)
            if (w is focusOwner)
                at = i;
        const n = cast(ptrdiff_t) order.length;
        const next = at < 0 ? (direction > 0 ? 0 : n - 1) : (at + direction + n) % n;
        setFocus(order[next], true);
    }

    /// Brings a widget's focused() and focusVisible() up to date, telling it if they changed.
    void refreshFocus(Widget w)
    {
        const focused = w is focusOwner && windowFocused;
        w.setFocusState(focused, focused && focusShown);
    }

    /// Moves the hover to `leaf` and its ancestors, telling whichever widgets it left and reached.
    void hoverOver(Widget leaf)
    {
        if (leaf is hovered)
            return;

        // Exits first, deepest first; then entries, outermost first. JavaFX's order.
        for (auto w = hovered; w; w = w.parent)
        {
            if (w.hover && !isWithin(leaf, w))
            {
                w._setHover(false);
                tell(w, MouseEventType.exited);
            }
        }
        hovered = leaf;
        enter(leaf);
        tooltipHover(leaf);
    }

    void enter(Widget w)
    {
        if (!w || w.hover)
            return;
        enter(w.parent);
        w._setHover(true);
        tell(w, MouseEventType.entered);
    }

    /// Delivers an event to one widget only.
    void tell(Widget w, MouseEventType type)
    {
        auto event = mouseEvent(type, MouseButton.none, 0);
        event.target = w;
        w.deliver(event);
    }

    /*
        Delivers an event to `from`, then up the tree until something consumes it. Each parent is
        read before its child hears the event, so a handler that removes its own widget doesn't cut
        the ancestors out: they were on the way when the event started, as in JavaFX.
    */
    void bubble(Widget from, MouseEventType type, MouseButton button, int clicks)
    {
        auto event = mouseEvent(type, button, clicks);
        event.target = from;
        for (auto w = from; w && !event.consumed;)
        {
            auto next = w.parent;
            w.deliver(event);
            w = next;
        }
    }

    void bubble(E)(ref E event) if (is(E == KeyEvent) || is(E == InputMethodEvent))
    {
        auto from = focusOwner ? focusOwner : _root;
        event.target = from;
        for (auto w = from; w && !event.consumed;)
        {
            auto next = w.parent;
            w.deliver(event);
            w = next;
        }
    }

    enum ulong windowNodeId = 0;
    double sentPointsToWindow = 0;

    /// The node with focus, as AccessKit sees it: the focused widget, or the nearest ancestor it
    /// can see if that one's hidden, or the window if nothing has focus.
    ulong accessibleFocus() nothrow @nogc
    {
        for (auto w = focusOwner; w; w = w.parent)
            if (!w.accessibleHidden)
                return w.accessibleId;
        return windowNodeId;
    }

    void pushChanged(accesskit_tree_update* update, Widget w, bool full)
    {
        if (!w.visible)
            return; // nor is anything under it; it'll all be sent again when it's shown
        if ((full || w.accessibleDirty) && !w.accessibleHidden)
        {
            auto n = w.buildAccessible(update);
            const children = accesskit_node_children(n);
            trace("a11y  node %llu role %d, %zu children, first %llu", w.accessibleId, accesskit_node_role(n),
                  children.length, children.length ? children.values[0] : 0);
            accesskit_tree_update_push_node(update, w.accessibleId, n);
        }
        w.accessibleDirty = false;
        foreach (child; w.children)
            pushChanged(update, cast() child, full);
    }

    static Widget findAccessible(Widget w, ulong id)
    {
        if (w.isAccessibleNode(id))
            return w;
        foreach (child; w.children)
            if (auto found = findAccessible(cast() child, id))
                return found;
        return null;
    }

    static bool isWithin(Widget leaf, Widget ancestor) nothrow @nogc
    {
        for (auto w = leaf; w; w = w.parent)
            if (w is ancestor)
                return true;
        return false;
    }
}

/// What a window can be asked to do by the title bar Mayfair draws for it. The App is one.
interface WindowControls
{
    void close();
    void minimise();
    void toggleMaximised();
    bool maximised();
    /// Shows the window system's own menu for the window, at `x`, `y` points in it.
    void showMenu(float x, float y);
    /// Whether the title bar hears the press that moves the window, and starts the move itself with
    /// beginMove() once the press is a drag. If not, the window system has taken the press already.
    bool movesByDrag();
    /// Has the window system move the window by the pointer, while the press that's down lasts.
    bool beginMove();
}
