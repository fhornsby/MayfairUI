module mayfair.widgets.widget;

import core.atomic : atomicExchange, atomicLoad, cas;
import mayfair.accessibility;
import mayfair.renderers.thorvg;
import mayfair.layout;
import mayfair.widgets.scene;
import mayfair.widgets.input;

/// A rectangle, in points. JavaFX's Bounds.
struct Bounds
{
    float minX = 0, minY = 0, width = 0, height = 0;

    float maxX() const nothrow @nogc { return minX + width; }
    float maxY() const nothrow @nogc { return minY + height; }
    float centerX() const nothrow @nogc { return minX + width / 2; }
    float centerY() const nothrow @nogc { return minY + height / 2; }

    bool contains(float x, float y) const nothrow @nogc
    {
        return x >= minX && x < maxX && y >= minY && y < maxY;
    }
}

/*
    A widget is a box in the layout (its Yoga node) and something drawn (its ThorVG shape).

    The node exists from the moment the widget is constructed, so a tree can be built, styled and
    rearranged with no window in sight -- which is what lets user code read as a plain expression and
    never mention a context. The shape can't: ThorVG hands out paints only once its engine is running,
    which needs a renderer, which needs a window. So the shape waits for mount(), which Scene calls on
    the whole tree once there's a canvas, and add() calls on a newcomer if the tree is already live.

    What a widget never sees either way is the scale. One transform on the Scene turns points into
    device pixels and its config carries the factor Yoga rounds layout with, so a widget styles,
    lays out and paints in points throughout.
*/
class Widget
{
public:
    YGNodeRef node;
    Tvg_Paint shape;   /// Null until mounted.
    Widget parent;     /// Null for a scene's root, and for a tree not yet added to anything.
    Scene scene;       /// Null until mounted.

    this() nothrow @nogc
    {
        node = YGNodeNew(); // on Yoga's default config; mount() re-points it at the scene's
        // Its accessibility node's id: unique for the life of the process, so a screen reader
        // holding one never finds it has come to mean a different widget
        accessibleId = newAccessibleId();
    }

    /*
        The node is the widget's, so it goes when the widget does. That's at the garbage collector's
        convenience, though, which may be on another thread in the middle of the UI thread using
        Yoga, so the node isn't freed here but retired, and freeRetiredNodes() frees it on the UI
        thread at a safe point.

        Each node goes when its own widget does, in whatever order the collector gets to them.
        That's safe because YGNodeFree cuts a node loose from its parent and its children before
        deleting it, and the others are still there to be cut loose from, their widgets having not
        been freed yet. What would not be safe is freeing a whole tree from its root, as the
        children's widgets would then free theirs again.
    */
    ~this() nothrow @nogc
    {
        if (node)
            retireNode(node);
    }

    /// The widgets below this one, in order.
    final inout(Widget)[] children() inout nothrow @nogc { return _children; }

    /// Adds `child` below this widget, taking it from wherever it was first. Returns this, so calls chain.
    final Widget add(Widget child)
    {
        if (child.parent)
            child.parent.remove(child);
        child.parent = this;
        _children ~= child;
        YGNodeInsertChild(node, child.node, _children.length - 1);
        invalidateAccessible(); // its list of children changed
        if (scene)
            child.mount(scene, paintAfter(child)); // this tree is already live, so the newcomer has to catch up
        return this;
    }

    /*
        Takes `child` out from below this widget, and everything below it with it. It keeps its
        node, its children and its handlers, so it can be added again, here or anywhere else; what
        it loses is its shapes, and any hover, press or focus it had.

        The children array is replaced rather than shuffled in place, so a walk over the tree that's
        part way through it -- a handler removing its own widget, say -- carries on over the old one.
    */
    final Widget remove(Widget child)
    {
        foreach (i, c; _children)
        {
            if (c !is child)
                continue;
            if (scene)
            {
                scene.forget(child);
                child.unmount();
            }
            YGNodeRemoveChild(node, child.node);
            _children = _children[0 .. i] ~ _children[i + 1 .. $];
            child.parent = null;
            invalidateAccessible();
            break;
        }
        return this;
    }

    /*
        Style. These are the handful of flex properties worth a name of their own; anything else is
        set on `node` directly with Yoga's own API. They work before or after mount, because the node
        is there from the start. Each returns Widget rather than the type it was called on, so a long
        chain ends up statically typed as a Widget: name the widget first if you need it as itself.
    */
    /*
        Takes a share of the space along the parent's main axis, in proportion to `factor`.

        This is CSS's `flex: <factor>` shorthand, not `flex-grow` on its own, and the difference is
        the whole point. flex-grow alone leaves flex-basis at auto, which starts every widget at its
        own content size and shares out only what's left over -- so two widgets that both "grow
        equally" come out different sizes as soon as they hold different content, and a row of
        labelled boxes ends up visibly uneven. A basis of 0 starts them all from nothing, so the
        share really is the whole space.

        A widget that wants its content size respected and then to grow sets flex-grow on `node`
        directly, the same as any other property without a name here.
    */
    final Widget grow(float factor) nothrow @nogc
    {
        YGNodeStyleSetFlexGrow(node, factor);
        YGNodeStyleSetFlexShrink(node, 1);
        YGNodeStyleSetFlexBasis(node, 0);
        return this;
    }

    final Widget padding(float points) nothrow @nogc
    {
        YGNodeStyleSetPadding(node, YGEdgeAll, points);
        return this;
    }

    final Widget gap(float points) nothrow @nogc
    {
        YGNodeStyleSetGap(node, YGGutterAll, points);
        return this;
    }

    /*
        Input. The Scene works out which widget the mouse is over and hands it the event; see
        MouseEvent for how it travels from there. These set what happens when this widget hears
        one, and are for code using the widget. A widget's own behaviour -- a button arming when
        pressed -- goes in handleMouse() instead, which runs after these and only if they didn't
        consume the event, so the app gets the first say.
    */
    final Widget onMousePressed(MouseHandler handler) nothrow @nogc { return on(MouseEventType.pressed, handler); }
    final Widget onMouseReleased(MouseHandler handler) nothrow @nogc { return on(MouseEventType.released, handler); }
    final Widget onMouseClicked(MouseHandler handler) nothrow @nogc { return on(MouseEventType.clicked, handler); }
    final Widget onMouseEntered(MouseHandler handler) nothrow @nogc { return on(MouseEventType.entered, handler); }
    final Widget onMouseExited(MouseHandler handler) nothrow @nogc { return on(MouseEventType.exited, handler); }
    final Widget onMouseMoved(MouseHandler handler) nothrow @nogc { return on(MouseEventType.moved, handler); }
    final Widget onMouseDragged(MouseHandler handler) nothrow @nogc { return on(MouseEventType.dragged, handler); }

    final Cursor cursor() const nothrow @nogc { return _cursor; }

    /// The pointer's shape while it's over this widget, and anything below it that doesn't say
    /// otherwise. A disabled widget shows the default whatever it says. Returns this, so calls chain.
    final Widget cursor(Cursor c) nothrow @nogc
    {
        _cursor = c;
        return this;
    }

    /// Where this widget is in the window, in points from its top left, as it was last drawn: what
    /// the user sees. Empty until it's been drawn. JavaFX's localToScene(getBoundsInLocal()).
    final Bounds boundsInScene() const nothrow @nogc
    {
        if (painted.x != painted.x)
            return Bounds.init; // NaN: never drawn
        return Bounds(painted.x, painted.y, painted.w, painted.h);
    }

    /// Whether the pointer is over this widget, or over anything below it.
    final bool hover() const nothrow @nogc { return _hover; }

    /// Whether the primary button went down on this widget, or on anything below it, and is still down.
    final bool pressed() const nothrow @nogc { return _pressed; }

    /// Key events go to the widget with focus and bubble up from it. The same rules as the mouse
    /// handlers above apply: the app's handler first, then the widget's own handleKey().
    final Widget onKeyPressed(KeyHandler handler) nothrow @nogc { return on(KeyEventType.pressed, handler); }
    final Widget onKeyReleased(KeyHandler handler) nothrow @nogc { return on(KeyEventType.released, handler); }

    /*
        Text. A widget that takes typed text says so with acceptsTextInput(true), and while it has
        focus the window has text input switched on: typed events arrive, carrying the text in
        `character`, and an input method's composition arrives as InputMethodEvents, with its
        candidate window put by the widget. Typed text is not the same as key presses -- one key
        can type nothing, a dead key and a letter can type one character, and an input method
        commits whole words -- so a text field listens to typed events for what to insert, and to
        pressed ones only for editing keys like Backspace and the arrows.
    */
    final Widget onKeyTyped(KeyHandler handler) nothrow @nogc { return on(KeyEventType.typed, handler); }

    /// Called as an input method composes text, before it's committed. JavaFX's onInputMethodTextChanged.
    final Widget onInputMethodTextChanged(InputMethodHandler handler) nothrow @nogc
    {
        inputMethodHandler = handler;
        return this;
    }

    final bool acceptsTextInput() const nothrow @nogc { return _acceptsTextInput; }

    /// Whether this widget takes typed text. Off by default. Returns this, so calls chain.
    final Widget acceptsTextInput(bool on) nothrow @nogc
    {
        _acceptsTextInput = on;
        return this;
    }

    /*
        Focus. One widget in a scene has it, and hears the keyboard first. Tab and Shift+Tab move it
        through the widgets that are focus traversable, in tree order; clicking a control gives it
        focus too. focused() is only true while the window itself has keyboard focus, as in JavaFX,
        so a control can rely on losing it when the user switches away.
    */
    final bool focusTraversable() const nothrow @nogc { return _focusTraversable; }

    /// Whether Tab can move focus here. Off by default; widgets that take input switch it on.
    final Widget focusTraversable(bool on) nothrow @nogc
    {
        _focusTraversable = on;
        invalidateAccessible(); // whether it offers the focus action
        return this;
    }

    final bool focused() const nothrow @nogc { return _focused; }

    /// Whether this is the widget with focus in its scene, whether or not the window has
    /// keyboard focus right now -- which focused() also asks.
    final bool isFocusOwner() nothrow @nogc { return scene && scene.focusOwnerIs(this); }

    /// Whether the widget has focus and should show it: it got it from the keyboard. A control
    /// draws its focus ring by this rather than focused(), so clicking one doesn't ring it.
    final bool focusVisible() const nothrow @nogc { return _focusVisible; }

    /// Takes focus. Does nothing until the widget is in a live scene, or while it's disabled.
    final void requestFocus()
    {
        if (scene && !disabled)
            scene.setFocus(this, false);
    }

    /// Whether this widget is switched off itself. See disabled() for whether it's off at all.
    final bool disable() const nothrow @nogc { return _disable; }

    /*
        Switches this widget and everything below it off, or back on: JavaFX's disable. A disabled
        widget hears no input and can't have focus, and controls draw themselves faded. Disabling a
        row of buttons disables every button in it. Returns this, so calls chain.
    */
    final Widget disable(bool on)
    {
        if (on == _disable)
            return this;
        _disable = on;
        // Below a disabled ancestor nothing was enabled to begin with, so nothing has changed
        if (!(parent && parent.disabled))
        {
            if (on && scene)
                scene.forgetFocusWithin(this);
            disabledTreeChanged();
        }
        return this;
    }

    /// Whether this widget, or anything above it, is disabled.
    final bool disabled() const nothrow @nogc
    {
        return _disable || (parent && parent.disabled);
    }

    /// Gives this widget its shape and brings everything below it to life. Called by Scene.
    /*
        Accessibility: what this widget is to a screen reader. See mayfair.accessibility.

        Every widget is a node in the accessibility tree, and the kit fills in what it knows --
        where the widget is, what's below it, whether it's disabled, and that it can take focus if
        it's focus traversable. A widget that means something adds the rest in
        describeAccessible(): its name, its text, what it can do. The properties here let code
        using a widget change what it says without subclassing, as JavaFX's do.
    */
    final AccessibleRole accessibleRole() const nothrow @nogc { return _accessibleRole; }

    /// What kind of thing this widget is. Returns this, so calls chain.
    final Widget accessibleRole(AccessibleRole role) nothrow @nogc
    {
        _accessibleRole = role;
        invalidateAccessible();
        return this;
    }

    final string accessibleText() const nothrow @nogc { return _accessibleText; }

    /// What a screen reader calls this widget, in place of what it would say itself: "Close" for
    /// a button that shows only an ×. Null to go back to that. Returns this, so calls chain.
    final Widget accessibleText(string text) nothrow @nogc
    {
        _accessibleText = text;
        invalidateAccessible();
        return this;
    }

    final string accessibleHelp() const nothrow @nogc { return _accessibleHelp; }

    /// More about this widget than its name, read after it. Returns this, so calls chain.
    final Widget accessibleHelp(string text) nothrow @nogc
    {
        _accessibleHelp = text;
        invalidateAccessible();
        return this;
    }

    final bool accessibleHidden() const nothrow @nogc { return _accessibleHidden; }

    /*
        Leaves this widget out of the accessibility tree, and puts its children where it would have
        been. For a widget that's part of how another is drawn rather than a thing in its own
        right: a button's text is its name, not a label inside it. Returns this, so calls chain.
    */
    final Widget accessibleHidden(bool hidden) nothrow @nogc
    {
        _accessibleHidden = hidden;
        invalidateAccessible();
        if (parent)
            parent.invalidateAccessible(); // its children, as a screen reader sees them, changed
        return this;
    }

    /// Marks this widget's accessibility node as needing to be sent again, for when something it
    /// says about itself changed -- new text, say. Where it is and what's below it are noticed without being told.
    final void invalidateAccessible() nothrow @nogc
    {
        accessibleDirty = true;
        if (scene)
            scene.accessibilityChanged = true;
    }

    /*
        Gives this widget its shape and brings everything below it to life. Called by Scene.

        Draw order is tree order -- a parent, then its children, then its next sibling -- and it's
        the order the shapes sit in the ThorVG scene. `before` is the shape the new ones go in
        front of, so that a widget added to a live tree is drawn where it sits in the tree rather
        than over everything; null puts them at the end.
    */
    final void mount(Scene scene, Tvg_Paint before = null) nothrow
    {
        this.scene = scene;
        YGNodeSetConfig(node, scene.config);
        // New to this tree, as far as assistive technology is concerned, even if it's been in it before
        accessibleDirty = true;
        scene.accessibilityChanged = true;
        shape = tvg_shape_new();
        if (before)
            tvg_scene_insert(scene.paints, shape, before);
        else
            tvg_scene_add(scene.paints, shape);
        mountBefore = before;
        mounted();
        mountBefore = null;
        foreach (child; _children)
            child.mount(scene, before);
    }

    /// Marks this widget as needing to be drawn again, for when something other than the layout
    /// changed it -- new text, a new colour. Geometry changes are noticed without being told.
    final void invalidate() nothrow @nogc
    {
        repaint = true;
        if (scene)
            scene.paintRequested = true;
    }

    /// Marks this widget and everything below it as needing to be drawn again.
    final void invalidateTree() nothrow @nogc
    {
        repaint = true;
        foreach (child; _children)
            child.invalidateTree();
    }

    /*
        Paints this widget and everything below it. `px`, `py` is the parent's position in the window
        in points: Yoga gives a node its position relative to its parent, so the walk down adds them up.

        A widget whose rectangle is unchanged since it was last painted, and which hasn't been
        invalidated, is left alone. For a rounded rect re-appending the geometry would be free, but a
        line of text is hundreds of Bezier segments decomposed out of FreeType, and any repaint
        anywhere in the window comes through here. The walk still has to continue into the children,
        because a parent can keep its own rectangle while a child moves inside it.
    */
    final void paintTree(float px, float py) nothrow @nogc
    {
        const x = px + YGNodeLayoutGetLeft(node);
        const y = py + YGNodeLayoutGetTop(node);
        const w = YGNodeLayoutGetWidth(node);
        const h = YGNodeLayoutGetHeight(node);

        // painted.x starts as NaN, which compares unequal to anything, so the first pass always paints
        if (repaint || x != painted.x || y != painted.y || w != painted.w || h != painted.h)
        {
            tvg_shape_reset(shape);
            paint(x, y, w, h);
            if (x != painted.x || y != painted.y || w != painted.w || h != painted.h)
                invalidateAccessible(); // its bounds
            painted = Rect(x, y, w, h);
            repaint = false;
        }

        foreach (child; _children)
            child.paintTree(x, y);
    }

protected:
    /// Called once, as soon as there's a shape. Where anything about a widget's appearance that
    /// doesn't change goes, such as its fill colour. Styling the node doesn't need to wait for this.
    void mounted() nothrow {}

    /// Draws this widget where the layout put it, in points. The shape has been reset, so this only
    /// appends geometry. A widget that draws nothing, like a row that only groups its children,
    /// leaves this alone: an empty path costs nothing to render.
    void paint(float x, float y, float w, float h) nothrow @nogc {}

    /*
        Another shape for this widget to draw with, for when one isn't enough: text in one colour
        over a background in another, or something clipped separately. Call it from mounted(); it
        goes in draw order after the widget's own shape and any added before it, and before its
        children. Like `shape`, it goes when the widget is unmounted, and paint() has to reset it.
    */
    final Tvg_Paint addPaint() nothrow
    {
        auto p = tvg_shape_new();
        if (mountBefore)
            tvg_scene_insert(scene.paints, p, mountBefore);
        else
            tvg_scene_add(scene.paints, p);
        extraPaints ~= p;
        return p;
    }

    /// Called once the shapes are gone, when the widget is removed from a live tree. Where anything
    /// mid-way -- an animation, a half-finished press -- goes back to rest, ready to be added again.
    void unmounted() nothrow {}

    /// A widget's own response to the mouse, FLTK's handle(). Runs after any handler the app set
    /// with onMouse...(), unless that consumed the event. Consume what this uses, so it goes no further.
    void handleMouse(ref MouseEvent event) {}

    /// The same for the keyboard, while this widget or something below it has focus.
    void handleKey(ref KeyEvent event) {}

    /// The same for an input method composing text.
    void handleInputMethod(ref InputMethodEvent event) {}

    /// Where the caret is, in points from the widget's left edge, for an input method to put its
    /// candidate window by. Only asked of a widget that accepts text input.
    float textInputCaret() nothrow @nogc { return 0; }

    /*
        A key nothing with focus wanted, offered to every enabled widget in the tree until one
        consumes it: FLTK's FL_SHORTCUT. It's for keys that mean something wherever focus is, like
        Enter for a default button.
    */
    void handleShortcut(ref KeyEvent event) {}

    /// Called when focused() or focusVisible() changes.
    void focusChanged() {}

    /// Called when disabled() changes, whether it was this widget or an ancestor that was switched.
    void disabledChanged() {}

    /// Adds what only this widget knows to its accessibility node: see AccessibleNode. Call
    /// invalidateAccessible() when any of it changes.
    void describeAccessible(ref AccessibleNode node) {}

    /// Whether `id` is a node this widget added below itself with AccessibleNode.addChild(), so
    /// that actions on it come here.
    bool ownsAccessibleNode(ulong id) { return false; }

    /*
        Does what assistive technology asked: JavaFX's executeAccessibleAction. Returns whether it
        did anything. `data` holds whatever the action needs beyond its name, such as the text for
        setValue. A widget that adds an action in describeAccessible() handles it here, and passes
        anything else on to this, which handles requestFocus.
    */
    bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        if (action == AccessibleAction.requestFocus && _focusTraversable)
        {
            requestFocus();
            return true;
        }
        return false;
    }

package(mayfair):
    /// Where an input method should put its candidate window: this widget's rectangle as last
    /// painted, and the caret within it, in points.
    final void textInputArea(out float x, out float y, out float w, out float h, out float caret) nothrow @nogc
    {
        x = painted.x;
        y = painted.y;
        w = painted.w;
        h = painted.h;
        caret = textInputCaret();
    }

package:
    ulong accessibleId;
    bool accessibleDirty = true; // a new widget has never been described

    /// Describes this widget as an AccessKit node, which the caller takes ownership of. Nodes the
    /// widget adds below itself go straight into `update`.
    final accesskit_node* buildAccessible(accesskit_tree_update* update)
    {
        auto n = accesskit_node_new(toAccessKit(_accessibleRole));
        if (painted.x == painted.x) // not NaN: it's been painted, so it's somewhere
            accesskit_node_set_bounds(n, accesskit_rect(painted.x, painted.y,
                                                        painted.x + painted.w, painted.y + painted.h));
        pushAccessibleChildren(n);
        if (disabled)
            accesskit_node_set_disabled(n);
        else if (_focusTraversable)
            accesskit_node_add_action(n, ACCESSKIT_ACTION_FOCUS);

        auto described = AccessibleNode(n, update);
        try
            describeAccessible(described);
        catch (Exception e)
        {
            // What the widget managed to say before it threw is still better than nothing, and
            // one widget mustn't cost the rest of the tree its update
            import core.stdc.stdio : fprintf, stderr;
            fprintf(stderr, "%.*s.describeAccessible failed: %.*s\n", cast(int) typeid(this).name.length,
                    typeid(this).name.ptr, cast(int) e.msg.length, e.msg.ptr);
        }
        // The app's words win over the widget's own
        if (_accessibleText.length)
            described.label(_accessibleText);
        if (_accessibleHelp.length)
            described.description(_accessibleHelp);
        return n;
    }

    /// Whether `id` is this widget's node, or one it added below itself.
    final bool isAccessibleNode(ulong id)
    {
        return id == accessibleId || ownsAccessibleNode(id);
    }

    /// Runs `action` if this widget can: not while it's disabled.
    final bool performAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        return !disabled && executeAccessibleAction(action, data);
    }

    /// Adds the ids of the children a screen reader sees, which are those of hidden ones' children
    /// in their place.
    final void pushAccessibleChildren(accesskit_node* n) nothrow @nogc
    {
        foreach (child; _children)
        {
            if (child._accessibleHidden)
                child.pushAccessibleChildren(n);
            else
                accesskit_node_push_child(n, child.accessibleId);
        }
    }

    bool _hover, _pressed; // kept up to date by the Scene
    bool _focused, _focusVisible;

    /// Sets focused() and focusVisible(), and tells the widget if either changed.
    final void setFocusState(bool focused, bool visible)
    {
        if (focused == _focused && visible == _focusVisible)
            return;
        _focused = focused;
        _focusVisible = visible;
        focusChanged();
    }

    /// Lets this widget hear `event`, unless it's disabled: the app's handler first, then its own.
    final void deliver(ref KeyEvent event)
    {
        if (disabled)
            return;
        if (auto handler = keyHandlers[event.type])
            handler(event);
        if (!event.consumed)
            handleKey(event);
    }

    /// Lets this widget hear `event`, unless it's disabled: the app's handler first, then its own.
    final void deliver(ref InputMethodEvent event)
    {
        if (disabled)
            return;
        if (inputMethodHandler)
            inputMethodHandler(event);
        if (!event.consumed)
            handleInputMethod(event);
    }

    /// Offers `event` as a shortcut to this widget and everything below it, until one consumes it.
    final void offerShortcut(ref KeyEvent event)
    {
        if (_disable)
            return; // and so is everything below
        handleShortcut(event);
        foreach (child; _children)
        {
            if (event.consumed)
                return;
            child.offerShortcut(event);
        }
    }

    /// Adds this widget and those below it that Tab can move focus to, in tree order.
    final void collectTraversable(ref Widget[] into)
    {
        if (_disable)
            return;
        if (_focusTraversable)
            into ~= this;
        foreach (child; _children)
            child.collectTraversable(into);
    }

    /*
        The deepest widget at `x`, `y`, in points from the window's top left, or null. It goes by
        where things were last painted, which is where the user saw them when they clicked. Later
        children are drawn over earlier ones, so they're asked first.
    */
    final Widget pick(float x, float y) nothrow @nogc
    {
        foreach_reverse (child; _children)
            if (auto hit = child.pick(x, y))
                return hit;
        // A widget that has never been painted has a NaN rectangle, which contains nothing
        if (x >= painted.x && x < painted.x + painted.w && y >= painted.y && y < painted.y + painted.h)
            return this;
        return null;
    }

    /// Lets this widget hear `event`, unless it's disabled: the app's handler first, then its own.
    final void deliver(ref MouseEvent event)
    {
        if (disabled)
            return;
        event.x = event.sceneX - painted.x;
        event.y = event.sceneY - painted.y;
        if (auto handler = mouseHandlers[event.type])
            handler(event);
        if (!event.consumed)
            handleMouse(event);
    }

private:
    struct Rect { float x = float.nan, y, w, h; }

    Widget[] _children;
    Rect painted;      // the rectangle this widget was last painted at
    bool repaint;      // set by invalidate(), for changes the rectangle doesn't show
    MouseHandler[MouseEventType.max + 1] mouseHandlers;
    KeyHandler[KeyEventType.max + 1] keyHandlers;
    InputMethodHandler inputMethodHandler;
    bool _acceptsTextInput;
    bool _focusTraversable;
    AccessibleRole _accessibleRole;
    string _accessibleText, _accessibleHelp;
    bool _accessibleHidden;
    Cursor _cursor;
    Tvg_Paint[] extraPaints; // from addPaint(), drawn after `shape` and before the children
    Tvg_Paint mountBefore;   // while mounting, where the shapes go: see mount()
    bool _disable;

    Widget on(MouseEventType type, MouseHandler handler) nothrow @nogc
    {
        mouseHandlers[type] = handler;
        return this;
    }

    Widget on(KeyEventType type, KeyHandler handler) nothrow @nogc
    {
        keyHandlers[type] = handler;
        return this;
    }

    /// The first shape drawn after everything under `w`: the next sibling's, or failing that, the
    /// next sibling of the nearest ancestor with one. Null if nothing comes after.
    static Tvg_Paint paintAfter(Widget w) nothrow @nogc
    {
        for (; w.parent; w = w.parent)
        {
            auto siblings = w.parent._children;
            foreach (i, sibling; siblings)
            {
                if (sibling !is w)
                    continue;
                if (i + 1 < siblings.length)
                    return siblings[i + 1].shape; // a widget's own shape comes before its children's
                break;
            }
        }
        return null;
    }

    /// Takes the shapes of this widget and everything below it out of the scene.
    void unmount() nothrow
    {
        foreach (child; _children)
            child.unmount();
        // Off the scene's config, which the scene frees when it's done while this node lives on
        YGNodeSetConfig(node, cast(YGConfigRef) YGConfigGetDefault());
        foreach (p; extraPaints)
            tvg_scene_remove(scene.paints, p);
        extraPaints = null;
        tvg_scene_remove(scene.paints, shape); // the scene owned it, so this frees it
        shape = null;
        scene = null;
        painted = Rect.init; // NaN again: nothing to hit, and painted in full if it comes back
        _hover = _pressed = _focused = _focusVisible = false;
        unmounted();
    }

    /// Tells this widget, and those below it that aren't disabled in their own right, that
    /// disabled() has changed for them.
    void disabledTreeChanged()
    {
        invalidateAccessible();
        disabledChanged();
        foreach (child; _children)
            if (!child._disable)
                child.disabledTreeChanged();
    }
}

/// Puts every node in the tree under `w` back on Yoga's default config, so the scene's can be freed.
package void releaseConfig(Widget w) nothrow @nogc
{
    YGNodeSetConfig(w.node, cast(YGConfigRef) YGConfigGetDefault());
    foreach (child; w._children)
        releaseConfig(child);
}

/*
    Nodes whose widgets have been collected, waiting to be freed on the UI thread. A finalizer
    can't allocate, so the list is threaded through the nodes themselves, by their context pointer:
    its widget is gone, so nothing will read it as anything else again. Pushing is a lock-free
    compare-and-swap, because finalizers can run on any thread, and several at once.
*/
private shared size_t retiredNodes; // the first node's address; a plain integer is what atomics swap simply

private void retireNode(YGNodeRef node) nothrow @nogc
{
    size_t head;
    do
    {
        head = atomicLoad(retiredNodes);
        YGNodeSetContext(node, cast(void*) head);
    }
    while (!cas(&retiredNodes, head, cast(size_t) node));
}

/// Frees every retired node. Call on the UI thread, where nothing else is using Yoga at the time.
/// Returns how many it freed.
package(mayfair) size_t freeRetiredNodes() nothrow @nogc
{
    size_t freed;
    auto node = cast(YGNodeRef) atomicExchange(&retiredNodes, cast(size_t) 0);
    while (node)
    {
        auto next = cast(YGNodeRef) YGNodeGetContext(node);
        YGNodeFree(node);
        node = next;
        freed++;
    }
    return freed;
}

unittest
{
    import core.memory : GC;

    // Made in a function of their own, so no pointer to them is left on this one's stack
    static void makeGarbage()
    {
        foreach (i; 0 .. 100)
        {
            auto parent = new Widget;
            parent.add(new Widget);
        }
    }
    freeRetiredNodes();
    makeGarbage();
    GC.collect();
    GC.collect();
    // The collector is conservative, so a stray word can keep the odd one alive; most must go
    assert(freeRetiredNodes() > 100);
}
