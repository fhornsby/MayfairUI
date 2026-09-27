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
        paints = tvg_scene_new();
        tvg_canvas_add(canvas, paints);

        // One config for every node in the tree: Yoga reads the point scale factor from each node's
        // own config when it rounds to the pixel grid, and a child doesn't inherit its parent's.
        // setScale() sets the factor on it once there's a window to ask about scale.
        config = YGConfigNew();

        background = tvg_shape_new();
        tvg_shape_set_fill_color(background, _fill.tupleof);
        tvg_scene_add(paints, background); // added first, so it's drawn behind the tree

        _root.styleClass.add("root"); // what a theme's .root rule, and its variables, are for
        _root.mount(this, paints);

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
            _root.unmountTree();
        catch (Exception) {}
        releaseConfig(_root);
        YGConfigFree(config);
    }

    /// Device pixels per point. Widgets work in points and don't need this; text is the exception,
    /// because a glyph has to land on the pixel grid to rasterise the same way twice.
    float scale() const nothrow @nogc { return _scale; }

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

        // Anything grid-fitted was fitted to the old pixel grid. A widget drawing plain geometry
        // wouldn't care, but hinted glyph outlines are baked for one scale, and paintTree skips a
        // widget whose rectangle hasn't moved -- which in points it may well not have.
        if (_root)
            _root.invalidateTree();
    }

    /// Sizes and positions the whole tree for a window `w` x `h` points.
    void layout(float w, float h) nothrow @nogc
    {
        YGNodeCalculateLayout(_root.node, w, h, YGDirectionLTR);
    }

    /// Updates every shape to match the layout.
    void paint(float w, float h) nothrow @nogc
    {
        tvg_shape_reset(background);
        tvg_shape_append_rect(background, 0, 0, w, h, 0, 0, true);
        _root.paintTree(0, 0);
    }

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
        forgetFocusWithin(gone);
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
        if (full || pointsToWindow != sentPointsToWindow)
        {
            sentPointsToWindow = pointsToWindow;
            auto window = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);
            accesskit_node_set_label_with_length(window, title.ptr, title.length);
            accesskit_node_set_transform(window, accesskit_affine_scale(pointsToWindow));
            if (_root.accessibleHidden)
                _root.pushAccessibleChildren(window);
            else
                accesskit_node_push_child(window, _root.accessibleId);
            accesskit_tree_update_push_node(update, windowNodeId, window);
        }
        pushChanged(update, _root, full);
        accessibilityChanged = false;
        return update;
    }

    /// Whether buildAccessibilityUpdate() would have anything to say.
    bool accessibilityPending(double pointsToWindow) const nothrow @nogc
    {
        return accessibilityChanged || pointsToWindow != sentPointsToWindow;
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
        if (auto w = findAccessible(_root, target))
            w.performAccessibleAction(action, data);
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
        hoverOver(_root.pick(x, y));
        if (grabbed)
            bubble(grabbed, MouseEventType.dragged, MouseButton.none, 0);
        else if (hovered)
            bubble(hovered, MouseEventType.moved, MouseButton.none, 0);
    }

    void mousePressed(float x, float y, MouseButton button, int clicks)
    {
        pointAt(x, y);
        hoverOver(_root.pick(x, y));
        if (!grabbed)
            grabbed = hovered;
        if (!grabbed)
            return;
        buttonsDown |= 1 << button;
        if (button == MouseButton.primary)
            for (auto w = grabbed; w; w = w.parent)
                w._setPressed(true);
        bubble(grabbed, MouseEventType.pressed, button, clicks);
    }

    void mouseReleased(float x, float y, MouseButton button, int clicks)
    {
        pointAt(x, y);
        hoverOver(_root.pick(x, y));
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
    void scrolled(float x, float y, float dx, float dy)
    {
        pointAt(x, y);
        hoverOver(_root.pick(x, y));
        if (!hovered)
            return;
        auto event = ScrollEvent(dx, dy, pointerX, pointerY);
        event.shift = heldShift;
        event.control = heldControl;
        event.alt = heldAlt;
        event.meta = heldMeta;
        event.target = hovered;
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
            hoverOver(_root.pick(pointerX, pointerY));
    }

    /*
        The keyboard. A key goes to the widget with focus, or the root if nothing has it, and
        bubbles up. Whatever nothing consumed, the scene has its own uses for: Tab and Shift+Tab
        move focus, and anything else is offered round the tree as a shortcut.
    */
    void keyPressed(KeyEvent event)
    {
        bubble(event);
        if (event.consumed)
            return;
        // Ctrl+Tab too, for getting out of something that takes Tab itself, as a text area does
        if (event.code == KeyCode.tab && !event.alt && !event.meta)
        {
            traverse(event.shift ? -1 : 1);
            return;
        }
        _root.offerShortcut(event);
    }

    void keyReleased(KeyEvent event)
    {
        bubble(event);
        if (!event.consumed)
            _root.offerShortcut(event);
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
        if (focusOwner)
            refreshFocus(focusOwner);
    }

private:
    float _scale = 1.0f;
    Widget _root;
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
        _root.collectTraversable(order);
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
