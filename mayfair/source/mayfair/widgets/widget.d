module mayfair.widgets.widget;

import core.atomic : atomicExchange, atomicLoad, cas;
import mayfair.accessibility;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.layout;
import mayfair.css;
import mayfair.widgets.scene;
import mayfair.widgets.popup : Popup;
import mayfair.widgets.input;
import mayfair.widgets.region;
import mayfair.widgets.styling;

/// Space around the four sides of something, in points: padding inside a widget, or a margin
/// outside it. JavaFX's Insets, in the same order: top, right, bottom, left.
struct Insets
{
    float top = 0, right = 0, bottom = 0, left = 0;

    /// The same on every side.
    this(float all) nothrow @nogc
    {
        top = right = bottom = left = all;
    }

    this(float top, float right, float bottom, float left) nothrow @nogc
    {
        this.top = top;
        this.right = right;
        this.bottom = bottom;
        this.left = left;
    }

    /// `vertical` above and below, `horizontal` either side.
    this(float vertical, float horizontal) nothrow @nogc
    {
        top = bottom = vertical;
        left = right = horizontal;
    }
}

/// A rectangle, in points. JavaFX's Bounds.
struct Bounds
{
    float minX = 0, minY = 0, width = 0, height = 0;

    float maxX() const nothrow @nogc { return minX + width; }
    float maxY() const nothrow @nogc { return minY + height; }
    float centreX() const nothrow @nogc { return minX + width / 2; }
    float centreY() const nothrow @nogc { return minY + height / 2; }

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

    Its settings are properties, as in JavaFX: `padding` gets one, `padding(Insets(8))` sets it
    and returns the widget as its own type so calls chain, and `paddingProperty` is the property
    itself, to bind or listen to. State it reports rather than takes -- whether it's hovered, has
    focus, is disabled -- is a read-only property: watched and bound to, never set from outside.

    Layout goes through those properties: sizes, padding, margin and grow here, and spacing and
    alignment on the containers (Row, Column). Underneath is Yoga, a flexbox engine, and `node` is
    its node, for the layout they don't cover -- the escape hatch, as overriding layoutChildren()
    is in JavaFX. Anything set there that a property also sets goes with whichever was set last.
*/
class Widget
{
public:
    YGNodeRef node;    /// Yoga's node: see above. For layout the properties don't reach.
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
        // Retired after the node, so freed before it -- the list is last in, first out -- which lets
        // the cell go while the node it holds is still there to be cut loose
        if (cellNode)
            retireNode(cellNode);
    }

    /// The widgets below this one, in order.
    final inout(Widget)[] children() inout nothrow @nogc { return _children; }

    /// Adds `child` below this widget, taking it from wherever it was first. Returns this, so calls chain.
    final Widget add(Widget child)
    {
        if (!takesChildren)
            throw new Exception(typeid(this).name ~ " doesn't take children with add(): "
                                ~ "what it holds is its own, or set through a property of its own, like a ScrollPane's content");
        return adopt(child);
    }

    /*
        Adds `child` below this widget at `index` (the end, if it's past it), whether or not add()
        would: for a widget adding its own parts, as a button does its label. Returns this.
    */
    protected final Widget adopt(Widget child, size_t index = size_t.max)
    {
        if (child.parent)
            child.parent.remove(child);
        child.parent = this;
        if (index > _children.length)
            index = _children.length;
        _children = _children[0 .. index] ~ child ~ _children[index .. $];
        if (placesChildren)
        {
            // Not in this one's Yoga tree but in a cell of its own, which this one sizes and places
            child.cellNode = YGNodeNewWithConfig(scene ? scene.config : cast(YGConfigRef) YGConfigGetDefault());
            YGNodeInsertChild(child.cellNode, child.node, 0);
            YGNodeSetContext(child.cellNode, cast(void*) this);
            YGNodeSetDirtiedFunc(child.cellNode, &cellDirtied);
            childLayoutChanged();
        }
        else
            YGNodeInsertChild(node, child.node, index);
        placeChild(child);
        invalidateAccessible(); // its list of children changed
        child.refreshDisabled(); // it's disabled now if this is
        if (scene)
            child.mount(scene, childrensLayer, paintAfter(child)); // this tree is already live, so the newcomer has to catch up
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
            if (child.cellNode)
            {
                YGNodeRemoveChild(child.cellNode, child.node);
                YGNodeFree(child.cellNode);
                child.cellNode = null;
                child.cellX = child.cellY = 0;
                childLayoutChanged();
            }
            else
                YGNodeRemoveChild(node, child.node);
            _children = _children[0 .. i] ~ _children[i + 1 .. $];
            child.parent = null;
            child.placeInParent(); // on its own again, so nothing of this one's placing applies
            child.refreshDisabled(); // no longer disabled by this
            invalidateAccessible();
            childRemoved(child);
            break;
        }
        return this;
    }

    /*
        Layout, JavaFX's Region properties, over Yoga's flexbox.

        A size left at useComputedSize (the default) is worked out from what's inside: a label's
        text, a row's children. Set, prefWidth and prefHeight are the size it asks for, and the
        min and max bound what a parent can make of it when there's more or less room.

        The computed max is where controls and containers differ, as they do in JavaFX. A control
        -- a button, a label -- is as big as it wants to be and no bigger, so a Column's fillWidth
        leaves it its own width and growing in a Row doesn't widen it. A container, or a plain
        Widget, has no limit, and fills whatever it's given. Either can be changed:

            new Button("OK").maxWidth(float.infinity)    // a button as wide as its column
            new Row().maxHeight(Widget.usePrefSize)      // a row that stays its own height

        A text field is between the two, again as JavaFX's is: it stretches along a line but keeps
        its own height.
    */
    enum float useComputedSize = float.nan;       /// JavaFX's Region.USE_COMPUTED_SIZE
    enum float usePrefSize = -float.infinity;     /// JavaFX's Region.USE_PREF_SIZE, for a min or max

    mixin(declareStyleableProperty!(float, "minWidth", "min-width", "float.nan", q{ placeInParent(); }));
    mixin(declareStyleableProperty!(float, "prefWidth", "width", "float.nan", q{ placeInParent(); }));
    mixin(declareStyleableProperty!(float, "maxWidth", "max-width", "float.nan", q{ placeInParent(); }));
    mixin(declareStyleableProperty!(float, "minHeight", "min-height", "float.nan", q{ placeInParent(); }));
    mixin(declareStyleableProperty!(float, "prefHeight", "height", "float.nan", q{ placeInParent(); }));
    mixin(declareStyleableProperty!(float, "maxHeight", "max-height", "float.nan", q{ placeInParent(); }));

    /// Sets the preferred width and height at once. Returns this, so calls chain.
    final This prefSize(this This)(float width, float height)
    {
        setPrefWidth(width);
        setPrefHeight(height);
        return cast(This) this;
    }

    /// Space inside the widget's edges, around what it holds.
    mixin(declareStyleableProperty!(Insets, "padding", "padding", "Insets.init", q{ applyPadding(); }));

    /// The same padding on every side. Returns this, so calls chain.
    final This padding(this This)(float all)
    {
        setPadding(Insets(all));
        return cast(This) this;
    }

    /// Space outside the widget's edges, between it and its neighbours. JavaFX sets this as a
    /// constraint on the parent (HBox.setMargin); here the widget holds it itself.
    mixin(declareProperty!(Insets, "margin", "Insets.init", q{ applyMargin(); }));

    /*
        How much of the spare room along its parent's main axis this widget takes: none by default,
        and in proportion to the others that grow when it's more than that. JavaFX says the same
        with HBox.setHgrow(node, Priority.ALWAYS), which is 1 here.

        It's CSS's `flex: <grow>`, not `flex-grow` on its own, and the difference is the point.
        flex-grow alone starts each widget at its own content size and shares out only what's left,
        so two widgets that both grow come out different sizes as soon as they hold different
        content, and a row of labelled boxes is visibly uneven. Growing here starts them all from
        nothing, so equal shares are equal. For the other behaviour, set flex-grow on `node`.

        As in JavaFX, it's bounded by the max: a button that grows stays its own width unless its
        maxWidth is raised too.
    */
    mixin(declareProperty!(float, "grow", "0", q{ placeInParent(); }));

    /*
        Style: see mayfair.widgets.styling for how it's worked out.

        A widget is selected by its type (`Button`), its style classes (`.button`, and any an app
        adds), its id (`#save`), and its state (`:hover`, `:focused`, `:disabled`...). Its inline
        style, a string of declarations, beats any stylesheet; its own stylesheets style everything
        below it too, on top of the Scene's.

            save.styleClass.add("primary");
            save.id("save").style("colour: red;");
            sidebar.stylesheets.add(stylesheet!(import("sidebar.css")));
    */
    final StyleClassList styleClass() nothrow
    {
        if (!_styleClass)
            _styleClass = new StyleClassList(this);
        return _styleClass;
    }

    /// Adds style classes. Returns this, so calls chain.
    final This styleClass(this This)(string[] names...)
    {
        styleClass.add(names);
        return cast(This) this;
    }

    /// What `#name` selects it by. JavaFX's id.
    mixin(declareProperty!(string, "id", "null", q{ markCssDirty(this, true); }));

    /// Declarations for this widget alone, as a stylesheet's rule would have them:
    /// `padding: 8; colour: red`. JavaFX's style. They beat any stylesheet.
    mixin(declareProperty!(string, "style", "null", q{ parseInlineStyle(); markCssDirty(this, false); }));

    /// Stylesheets for this widget and everything below it. JavaFX's Parent.getStylesheets().
    final StylesheetList stylesheets()
    {
        if (!ownStylesheets)
            ownStylesheets = new StylesheetList({ markCssDirty(this, true); });
        return ownStylesheets;
    }

    /*
        Input. The Scene works out which widget the mouse is over and hands it the event; see
        MouseEvent for how it travels from there. These set what happens when this widget hears
        one, and are for code using the widget. A widget's own behaviour -- a button arming when
        pressed -- goes in handleMouse() instead, which runs after these and only if they didn't
        consume the event, so the app gets the first say.
    */
    final void setOnMousePressed(MouseHandler handler) nothrow @nogc { on(MouseEventType.pressed, handler); }
    final This onMousePressed(this This)(MouseHandler handler) { on(MouseEventType.pressed, handler); return cast(This) this; }
    final void setOnMouseReleased(MouseHandler handler) nothrow @nogc { on(MouseEventType.released, handler); }
    final This onMouseReleased(this This)(MouseHandler handler) { on(MouseEventType.released, handler); return cast(This) this; }
    final void setOnMouseClicked(MouseHandler handler) nothrow @nogc { on(MouseEventType.clicked, handler); }
    final This onMouseClicked(this This)(MouseHandler handler) { on(MouseEventType.clicked, handler); return cast(This) this; }
    final void setOnMouseEntered(MouseHandler handler) nothrow @nogc { on(MouseEventType.entered, handler); }
    final This onMouseEntered(this This)(MouseHandler handler) { on(MouseEventType.entered, handler); return cast(This) this; }
    final void setOnMouseExited(MouseHandler handler) nothrow @nogc { on(MouseEventType.exited, handler); }
    final This onMouseExited(this This)(MouseHandler handler) { on(MouseEventType.exited, handler); return cast(This) this; }
    final void setOnMouseMoved(MouseHandler handler) nothrow @nogc { on(MouseEventType.moved, handler); }
    final This onMouseMoved(this This)(MouseHandler handler) { on(MouseEventType.moved, handler); return cast(This) this; }
    final void setOnMouseDragged(MouseHandler handler) nothrow @nogc { on(MouseEventType.dragged, handler); }
    final This onMouseDragged(this This)(MouseHandler handler) { on(MouseEventType.dragged, handler); return cast(This) this; }

    /*
        Appearance: JavaFX's Region background and border, and Node opacity and scale. Mostly set
        by the theme's stylesheet; see Background for what a layered one can do.
    */
    mixin(declareStyleableProperty!(Background, "background",
        "background-colour, background-radius, background-insets", "Background.init", q{ syncRegionPaints(); }));
    mixin(declareStyleableProperty!(Border, "border",
        "border-colour, border-width, border-radius, border-insets", "Border.init", q{ syncRegionPaints(); }));

    /// An SVG path to draw the background and border as, stretched to the widget, in place of a
    /// rectangle: JavaFX's shape. See SvgPath. Empty for a rectangle.
    mixin(declareStyleableProperty!(string, "shapePath", "shape", "null", q{ parseShape(); }));

    /// How opaque it is, and everything below it, from 0 to 1.
    mixin(declareStyleableProperty!(float, "opacity", "opacity", "1", q{ invalidate(); }));

    /// How much bigger it's drawn than it's laid out, about its centre, with everything below it:
    /// a pressed button shrinking slightly, say. Layout doesn't see it.
    mixin(declareStyleableProperty!(float, "scaleX", "scale-x", "1", q{ invalidate(); }));
    mixin(declareStyleableProperty!(float, "scaleY", "scale-y", "1", q{ invalidate(); })); /// ditto

    /// The pointer's shape while it's over this widget, and anything below it that doesn't say
    /// otherwise. A disabled widget shows the default whatever it says.
    mixin(declareStyleableProperty!(Cursor, "cursor", "cursor", "Cursor.inherit"));

    /// Where this widget is in the window, in points from its top left, as it was last drawn: what
    /// the user sees. Empty until it's been drawn. JavaFX's localToScene(getBoundsInLocal()).
    final Bounds boundsInScene() const nothrow @nogc
    {
        if (painted.x != painted.x)
            return Bounds.init; // NaN: never drawn
        return Bounds(painted.x, painted.y, painted.w, painted.h);
    }

    /// Whether the pointer is over this widget, or over anything below it.
    mixin(declareReadOnlyProperty!(bool, "hover", "false", q{ pseudoClassChanged(this, pseudo!"hover", _hover); }, "package"));

    /// Whether the primary button went down on this widget, or on anything below it, and is still down.
    mixin(declareReadOnlyProperty!(bool, "pressed", "false", q{ pseudoClassChanged(this, pseudo!"pressed", _pressed); }, "package"));

    /// Key events go to the widget with focus and bubble up from it. The same rules as the mouse
    /// handlers above apply: the app's handler first, then the widget's own handleKey().
    final void setOnKeyPressed(KeyHandler handler) nothrow @nogc { on(KeyEventType.pressed, handler); }
    final This onKeyPressed(this This)(KeyHandler handler) { on(KeyEventType.pressed, handler); return cast(This) this; }
    final void setOnKeyReleased(KeyHandler handler) nothrow @nogc { on(KeyEventType.released, handler); }
    final This onKeyReleased(this This)(KeyHandler handler) { on(KeyEventType.released, handler); return cast(This) this; }

    /*
        Text. A widget that takes typed text says so with acceptsTextInput(true), and while it has
        focus the window has text input switched on: typed events arrive, carrying the text in
        `character`, and an input method's composition arrives as InputMethodEvents, with its
        candidate window put by the widget. Typed text is not the same as key presses -- one key
        can type nothing, a dead key and a letter can type one character, and an input method
        commits whole words -- so a text field listens to typed events for what to insert, and to
        pressed ones only for editing keys like Backspace and the arrows.
    */
    final void setOnKeyTyped(KeyHandler handler) nothrow @nogc { on(KeyEventType.typed, handler); }
    final This onKeyTyped(this This)(KeyHandler handler) { on(KeyEventType.typed, handler); return cast(This) this; }

    /// Called as an input method composes text, before it's committed. JavaFX's onInputMethodTextChanged.
    final void setOnInputMethodTextChanged(InputMethodHandler handler) nothrow @nogc { inputMethodHandler = handler; }
    final This onInputMethodTextChanged(this This)(InputMethodHandler handler)
    {
        inputMethodHandler = handler;
        return cast(This) this;
    }

    /// The wheel or a touchpad scrolled with the pointer over this widget, or over anything below
    /// it that didn't consume it. JavaFX's onScroll. See ScrollEvent.
    final void setOnScroll(ScrollHandler handler) nothrow @nogc { scrollHandler = handler; }
    final This onScroll(this This)(ScrollHandler handler)
    {
        scrollHandler = handler;
        return cast(This) this;
    }

    /// Whether this widget takes typed text. Off by default.
    mixin(declareProperty!(bool, "acceptsTextInput", "false"));

    /*
        Focus. One widget in a scene has it, and hears the keyboard first. Tab and Shift+Tab move it
        through the widgets that are focus traversable, in tree order; clicking a control gives it
        focus too. focused() is only true while the window itself has keyboard focus, as in JavaFX,
        so a control can rely on losing it when the user switches away.
    */
    /// Whether Tab can move focus here. Off by default; widgets that take input switch it on.
    mixin(declareProperty!(bool, "focusTraversable", "false", q{ invalidateAccessible(); }));

    /// Whether this widget has focus, and its window has the keyboard.
    mixin(declareReadOnlyProperty!(bool, "focused", "false", q{ pseudoClassChanged(this, pseudo!"focused", _focused); }, "private"));

    /// Whether this is the widget with focus in its scene, whether or not the window has
    /// keyboard focus right now -- which focused() also asks.
    final bool isFocusOwner() nothrow @nogc { return scene && scene.focusOwnerIs(this); }

    /// Whether the widget has focus and should show it: it got it from the keyboard. A control
    /// draws its focus ring by this rather than focused(), so clicking one doesn't ring it.
    mixin(declareReadOnlyProperty!(bool, "focusVisible", "false", q{ pseudoClassChanged(this, pseudo!"focus-visible", _focusVisible); }, "private"));

    /// Takes focus. Does nothing until the widget is in a live scene, or while it's disabled.
    final void requestFocus()
    {
        if (scene && !disabled)
            scene.setFocus(this, false);
    }

    /// Takes focus as the keyboard gives it, ring and all: for a control that moves focus with
    /// keys of its own, as a radio group does with the arrows.
    protected final void requestFocusFromKeyboard()
    {
        if (scene && !disabled)
            scene.setFocus(this, true);
    }

    /*
        Switches this widget and everything below it off, or back on: JavaFX's disable. A disabled
        widget hears no input and can't have focus, and controls draw themselves faded. Disabling a
        row of buttons disables every button in it. This is whether the widget is switched off
        itself; `disabled` is whether it's off at all, by this or by anything above it.
    */
    mixin(declareProperty!(bool, "disable", "false", q{ refreshDisabled(); }));

    /// Whether this widget is switched off, by its own `disable` or an ancestor's. JavaFX's disabled.
    mixin(declareReadOnlyProperty!(bool, "disabled", "false", q{ pseudoClassChanged(this, pseudo!"disabled", _disabled); }, "private"));

    /// Gives this widget its shape and brings everything below it to life. Called by Scene.
    /*
        Accessibility: what this widget is to a screen reader. See mayfair.accessibility.

        Every widget is a node in the accessibility tree, and the kit fills in what it knows --
        where the widget is, what's below it, whether it's disabled, and that it can take focus if
        it's focus traversable. A widget that means something adds the rest in
        describeAccessible(): its name, its text, what it can do. The properties here let code
        using a widget change what it says without subclassing, as JavaFX's do.
    */
    /// What kind of thing this widget is.
    mixin(declareProperty!(AccessibleRole, "accessibleRole", "AccessibleRole.node", q{ invalidateAccessible(); }));

    /// What a screen reader calls this widget, in place of what it would say itself: "Close" for
    /// a button that shows only an ×. Null to go back to that.
    mixin(declareProperty!(string, "accessibleText", "null", q{ invalidateAccessible(); }));

    /// More about this widget than its name, read after it.
    mixin(declareProperty!(string, "accessibleHelp", "null", q{ invalidateAccessible(); }));

    /*
        Whether it's there at all: shown, laid out, clickable, reachable by Tab and a screen reader.
        Not visible, it takes no room, as GNOME's widgets do -- a dialog without text leaves no gap
        where the text would be. Everything below it goes with it. JavaFX's visible, with managed.
    */
    mixin(declareProperty!(bool, "visible", "true", q{ visibilityChanged(); }));

    /// A short line about it, shown when the pointer rests on it, and read out by a screen reader
    /// as its description if accessibleHelp doesn't say otherwise. JavaFX's tooltip.
    mixin(declareProperty!(string, "tooltip", "null", q{ invalidateAccessible(); }));

    /// A menu for it: shown where it's pressed with the secondary button, or below it by the Menu
    /// key or Shift+F10 while it has focus. What's inside it without a menu of its own has its.
    mixin(declareProperty!(Popup, "contextMenu", "null"));

    /*
        Leaves this widget out of the accessibility tree, and puts its children where it would have
        been. For a widget that's part of how another is drawn rather than a thing in its own
        right: a button's text is its name, not a label inside it.
    */
    mixin(declareProperty!(bool, "accessibleHidden", "false", q{
        invalidateAccessible();
        if (parent)
            parent.invalidateAccessible(); // its children, as a screen reader sees them, changed
    }));

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
        the order the shapes sit in `layer`: the scene's ThorVG scene, or the layer of the nearest
        widget above that gave its children one (see clipChildren). `before` is the shape the new
        ones go in front of, so that a widget added to a live tree is drawn where it sits in the
        tree rather than over everything; null puts them at the end.
    */
    final void mount(Scene scene, Tvg_Paint layer, Tvg_Paint before = null) nothrow
    {
        this.scene = scene;
        this.layer = layer;
        markCssDirty(this, true); // new to this scene's stylesheets
        YGNodeSetConfig(node, scene.config);
        if (cellNode)
            YGNodeSetConfig(cellNode, scene.config);
        // New to this tree, as far as assistive technology is concerned, even if it's been in it before
        accessibleDirty = true;
        scene.accessibilityChanged = true;
        shape = tvg_shape_new();
        if (before)
            tvg_scene_insert(layer, shape, before);
        else
            tvg_scene_add(layer, shape);
        mountBefore = before;
        syncRegionPaints();
        mounted();
        mountBefore = null;
        // Into this one's layer for them, if it made one, where they're all there is
        foreach (child; _children)
            child.mount(scene, childrensLayer, _childLayer ? null : before);
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
        Paints this widget and everything below it. `px`, `py` is the parent's position in points,
        in its layer: Yoga gives a node its position relative to its parent, so the walk down adds
        them up. `sx`, `sy` is how far the layers it's in are scrolled, so where it's seen in the
        window is that much less.

        A widget whose rectangle is unchanged since it was last painted, and which hasn't been
        invalidated, is left alone. For a rounded rect re-appending the geometry would be free, but a
        line of text is hundreds of Bezier segments decomposed out of FreeType, and any repaint
        anywhere in the window comes through here. The walk still has to continue into the children,
        because a parent can keep its own rectangle while a child moves inside it.
    */
    final void paintTree(float px, float py, float sx = 0, float sy = 0,
                         float parentOpacity = 1, ref const Tvg_Matrix parentMatrix = identity) nothrow @nogc
    {
        const w = YGNodeLayoutGetWidth(node);
        const h = YGNodeLayoutGetHeight(node);
        const x = px + layoutX();
        const y = py + layoutY();
        laidOut(x, y, w, h);

        // Opacity and scale are the parent's times its own, for every paint of this widget's. Set
        // only when they change, and before paint(), which can then set its own opacities on top.
        const opacity = _visible ? parentOpacity * clamp01(_opacity) : 0; // not visible: drawn clear
        Tvg_Matrix matrix = parentMatrix;
        if (_scaleX != 1 || _scaleY != 1)
        {
            const cx = x + w / 2, cy = y + h / 2;
            const own = Tvg_Matrix(_scaleX, 0, cx * (1 - _scaleX), 0, _scaleY, cy * (1 - _scaleY), 0, 0, 1);
            matrix = multiply(parentMatrix, own);
        }
        if (opacity != appliedOpacity || matrix != appliedMatrix)
        {
            appliedOpacity = opacity;
            appliedMatrix = matrix;
            forEachOwnPaint((Tvg_Paint p) nothrow @nogc {
                tvg_paint_set_opacity(p, cast(ubyte)(opacity * 255 + 0.5f));
                tvg_paint_set_transform(p, &matrix);
            });
            repaint = true;
        }

        // drawn.x starts as NaN, which compares unequal to anything, so the first pass always paints
        const moved = x != drawn.x || y != drawn.y || w != drawn.w || h != drawn.h;
        if (repaint || moved)
        {
            paintRegion(x, y, w, h);
            tvg_shape_reset(shape);
            paint(x, y, w, h);
            if (moved)
            {
                invalidateAccessible(); // its bounds
                if (_childClip)
                {
                    tvg_shape_reset(_childClip);
                    const inside = insidePadding(Rect(x, y, w, h));
                    tvg_shape_append_rect(_childClip, inside.x, inside.y, inside.w, inside.h, 0, 0, true);
                }
            }
            drawn = Rect(x, y, w, h);
            repaint = false;
        }
        painted = Rect(x - sx, y - sy, w, h);

        foreach (child; _children)
            child.paintTree(x, y, sx + _childOffsetX, sy + _childOffsetY, opacity, matrix);
    }

    /// How opaque it's drawn, its ancestors' opacity included, as of the last paint. For a widget
    /// setting a paint's opacity of its own in paint(), to multiply by.
    final float effectiveOpacity() const nothrow @nogc { return appliedOpacity; }

    /*
        Scrolls whatever scrolls around this widget -- a ScrollPane, or several one inside another
        -- so that it's in view, or as much of it as fits. Tab does this for the widget it moves
        focus to, and so does a screen reader asking to see one.
    */
    final void scrollIntoView()
    {
        scrollIntoView(Bounds(0, 0, YGNodeLayoutGetWidth(node), YGNodeLayoutGetHeight(node)));
    }

    /// The same for part of it: `rect`, from its top left. A text area's caret, say.
    final void scrollIntoView(Bounds rect)
    {
        for (auto p = parent; p; p = p.parent)
        {
            if (!p._childLayer)
                continue;
            const at = boundsIn(p);
            p.reveal(Bounds(at.minX + rect.minX, at.minY + rect.minY, rect.width, rect.height));
        }
    }

    /// Where this widget is in the coordinates `ancestor`'s children are laid out in: from its top
    /// left, and not moved by its scrolling, though by any scrolling in between.
    final Bounds boundsIn(Widget ancestor) nothrow @nogc
    {
        float x = 0, y = 0;
        for (Widget w = this; w && w !is ancestor; w = w.parent)
        {
            x += w.layoutX();
            y += w.layoutY();
            if (w.parent && w.parent !is ancestor)
            {
                x -= w.parent._childOffsetX;
                y -= w.parent._childOffsetY;
            }
        }
        const w = YGNodeLayoutGetWidth(node), h = YGNodeLayoutGetHeight(node);
        return Bounds(x, y, w, h);
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
        Whether add() can give it children: a container can, where a control keeps its own -- a
        button's label, a scroll pane's view -- or has none, like a label, which Yoga measures
        itself and wouldn't lay children out in. As JavaFX's controls aren't Panes.
    */
    bool takesChildren() const nothrow @nogc { return true; }

    /*
        Whether this widget places its children itself, rather than leaving them to flexbox: a
        Stack or a Grid, which flexbox has no way to say. See CustomLayout, which is how to write
        one. Each child is then laid out in a Yoga tree of its own, in a cell this widget sizes and
        places, so the child's own layout -- a label's text, a row's children -- is Yoga's as ever.
    */
    bool placesChildren() const nothrow @nogc { return false; }

    /// Called when `child` has been taken out from below this widget.
    void childRemoved(Widget child) {}

    /*
        Something to do in the next update, when it's safe to allocate and change properties: for
        a widget that finds out in paint() -- where it can do neither -- that there's work, as a
        text area does that it's been given a new width to wrap to. update() then runs before the
        next layout.
    */
    final void requestUpdate() nothrow @nogc
    {
        updateRequested = true;
        for (auto p = parent; p && !p.cssChildDirty; p = p.parent)
            p.cssChildDirty = true;
        if (scene)
            scene.cssRequested = true;
    }

    /// What requestUpdate() asked for.
    void update() {}

    /*
        Called each time the style pass has restyled this widget, after its styleable properties
        are set: for a widget that reads the stylesheet some other way, as a LottieView looks up
        the colours for its animation's slots. Its variables may have changed with it, or
        with an ancestor's, or with the colour scheme.
    */
    void restyled() {}

    /// computeMaxWidth() or computeMaxHeight() would say something different now: has the parent
    /// place it again, as it does when its max is set.
    final void maxChanged() nothrow @nogc { placeInParent(); }

    /// Whether Tab stops here, of a focus-traversable widget: all of them do, but a radio group
    /// is one stop, the selected one, and the arrow keys move within it.
    bool isTabStop() { return true; }

    /// The max a widget has while maxWidth and maxHeight are left computed: float.infinity for no
    /// limit, which suits a container, or usePrefSize for a control. JavaFX's computeMaxWidth.
    float computeMaxWidth() const nothrow @nogc { return float.infinity; }
    float computeMaxHeight() const nothrow @nogc { return float.infinity; } /// ditto

    /*
        How this widget places `child` in its layout: how much it grows, and whether it stretches
        across. Called when the child is added and when any of its sizes or its grow change; a
        container calls it again for every child when its own settings change. Place the child
        with child.place().

        By default the child grows as it asks and stretches as Yoga's alignItems says. Row and
        Column hold their children to their max, as JavaFX's HBox and VBox do.
    */
    void placeChild(Widget child) nothrow @nogc
    {
        child.place(child._grow, false, false, YGAlignAuto);
    }

    /*
        Another shape for this widget to draw with, for when one isn't enough: text in one colour
        over a background in another, or something clipped separately. Call it from mounted(); it
        goes in draw order after the widget's own shape and any added before it, and before its
        children. Like `shape`, it goes when the widget is unmounted, and paint() has to reset it.
    */
    final Tvg_Paint addPaint(Tvg_Paint p = null) nothrow
    {
        if (!p)
            p = tvg_shape_new();
        if (mountBefore)
            tvg_scene_insert(layer, p, mountBefore);
        else
            tvg_scene_add(layer, p);
        extraPaints ~= p;
        return p;
    }

    /*
        Puts this widget's children in a layer of their own, clipped to the inside of its padding:
        what a scroll pane does, so that what's scrolled out of view isn't seen, and can't be
        clicked. Call it from mounted(). The layer goes where addPaint() would put a paint, so
        paints added after it are drawn over the children.

        The children are drawn where the layout puts them, less whatever scrollChildren() says,
        which moves the whole layer at once: scrolling doesn't redraw them.
    */
    final void clipChildren() nothrow
    {
        auto clip = tvg_scene_new(); // holds the clip, so the one inside can move and it stays put
        _childClipHolder = clip;
        _childClip = tvg_shape_new();
        tvg_paint_set_clip(clip, _childClip);
        _childLayer = tvg_scene_new();
        tvg_scene_add(clip, _childLayer);
        addPaint(clip);
    }

    /// Moves this widget's children by `-x`, `-y` from where the layout puts them, all together:
    /// how far it's scrolled. Only for a widget that's called clipChildren().
    final void scrollChildren(float x, float y) nothrow @nogc
    {
        if (x == _childOffsetX && y == _childOffsetY)
            return;
        _childOffsetX = x;
        _childOffsetY = y;
        if (_childLayer)
            tvg_paint_translate(_childLayer, -x, -y);
        // Everything below has moved, as a screen reader sees it: see buildAccessible()
        foreach (child; _children)
            child.invalidateAccessibleTree();
        invalidateAccessible();
        if (scene)
            scene.paintRequested = true;
    }

    /*
        Called on every paint pass, after layout and before paint(), with where the layout put this
        widget. For a widget whose drawing depends on more than its own rectangle -- a scroll pane's
        bars, on how big its content came out -- which can call invalidate() here to be painted.
    */
    void laidOut(float x, float y, float w, float h) nothrow @nogc {}

    /// Whether the point `x`, `y`, in points from the window's top left, is this widget's even
    /// though a child is drawn there: a scroll pane's bar, over its content. Nothing by default.
    bool claimsPoint(float x, float y) nothrow @nogc { return false; }

    /// Scrolls, if this widget scrolls, so that `rect` shows: a rectangle in its children's
    /// coordinates, as childBounds() gives them. See scrollIntoView().
    void reveal(Bounds rect) {}

    /// Called once the shapes are gone, when the widget is removed from a live tree. Where anything
    /// mid-way -- an animation, a half-finished press -- goes back to rest, ready to be added again.
    void unmounted() {}

    /// The same for scrolling: see ScrollEvent.
    void handleScroll(ref ScrollEvent event) {}

    /// Puts this widget in state `pc`, or takes it out, for selectors that ask about it: a
    /// checked box's `:selected`, say. JavaFX's pseudoClassStateChanged.
    final void pseudoClassStateChanged(PseudoClass pc, bool on) nothrow @nogc
    {
        pseudoClassChanged(this, pc, on);
    }

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
        if (action == AccessibleAction.scrollIntoView)
        {
            scrollIntoView();
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
    // Style: see mayfair.widgets.styling
    bool cssDirty = true, cssBelow, cssChildDirty; // to restyle: it, what's below it, something below it
    bool updateRequested;                          // see requestUpdate()
    final void runUpdate() { update(); }
    Widget styleOwner;                 // for a popup: what it's shown for, whose variables it takes
    YGNodeRef cellNode;                // the cell it's in, if its parent places its children
    float cellX = 0, cellY = 0;        // where in its parent that cell is
    bool arrangeNeeded = true;         // for a widget that places its children: they need placing again
    bool placingCells;                 // and it's measuring or placing them itself, right now

    /// Something about the children of a widget that places them has changed: measure and place again.
    final void childLayoutChanged() nothrow @nogc
    {
        arrangeNeeded = true;
        if (YGNodeHasMeasureFunc(node)) // as a CustomLayout's has: Yoga marks no other node dirty by hand
            YGNodeMarkDirty(node);
        invalidate();
    }
    final void runRestyled() { restyled(); }
    final void unmountTree() { unmount(); } // for a Scene letting go of its canvas: see Scene.detach
    ulong pseudoClasses;          // its states, a PseudoClass bit each
    Declared[] declared;          // the declarations that won, by name
    Declaration[] inlineDeclarations; // `style`, parsed
    StylesheetList ownStylesheets;
    TransitionSpec[] transitionSpecs;          // what its `transition` says
    RunningTransition[] runningTransitions;    // those on their way
    bool styled;                               // since it was last added to a scene

    /// Whether it has style class `name`, without making it a list if it has none.
    final bool hasStyleClass(string name) const nothrow @nogc
    {
        return _styleClass && _styleClass.contains(name);
    }

    final const(string)[] styleClassNames() const nothrow @nogc
    {
        return _styleClass ? _styleClass.names : null;
    }

    /// Whether the widget's max is its preferred size, set or computed, across and down.
    final bool widthHeldToPref() const nothrow @nogc
    {
        return (_maxWidth == _maxWidth ? _maxWidth : computeMaxWidth()) == usePrefSize;
    }

    final bool heightHeldToPref() const nothrow @nogc /// ditto
    {
        return (_maxHeight == _maxHeight ? _maxHeight : computeMaxHeight()) == usePrefSize;
    }

    /*
        Places this widget in its parent's layout, for placeChild(): growing by `grow` along the
        parent's main axis, and stretching across it if `stretchWidth` or `stretchHeight` says so,
        with `alignSelf` as Yoga's for it. `across` is where a stretched widget sits when its max
        stops it short of the parent's width or height: 0 at the start, 0.5 in the middle, 1 at
        the end. Yoga always puts it at the start, so paintTree() moves it (see shortfall()).

        Flexbox won't stretch a child that has a size of its own across, where JavaFX stretches
        anything whose max allows, so a stretched axis leaves Yoga's size auto and makes the
        preferred size the least it can be instead: the container still sizes to fit it, and it
        still fills the container.

        What that can't do is let it be squeezed: JavaFX sizes a container from its children's
        preferred sizes but will shrink a stretched child to its min when the container's made
        smaller, and flexbox has nothing across that says both, as flex-basis and flex-shrink do
        along. So a stretched widget with a preferred size set stays at least that big. One sized
        from its content, as controls are, has nothing to stay at, and shrinks as JavaFX's does.
    */
    final void place(float grow, bool stretchWidth, bool stretchHeight, YGAlign alignSelf,
                     float across = 0) nothrow @nogc
    {
        _acrossX = stretchWidth ? across : 0;
        _acrossY = stretchHeight ? across : 0;
        YGNodeStyleSetFlexGrow(node, grow);
        YGNodeStyleSetFlexShrink(node, grow > 0 ? 1 : 0);
        if (grow > 0)
            YGNodeStyleSetFlexBasis(node, 0);
        else
            YGNodeStyleSetFlexBasisAuto(node);
        YGNodeStyleSetAlignSelf(node, alignSelf);
        applySize(stretchWidth, stretchHeight);
    }

    ulong accessibleId;
    bool accessibleDirty = true; // a new widget has never been described

    /// Describes this widget as an AccessKit node, which the caller takes ownership of. Nodes the
    /// widget adds below itself go straight into `update`.
    final accesskit_node* buildAccessible(accesskit_tree_update* update)
    {
        auto n = accesskit_node_new(toAccessKit(_accessibleRole));
        /*
            Bounds are where it's seen in the window, scrolling and all. AccessKit could take a
            scroll as a transform on the node that scrolls, leaving the bounds below it alone, but
            it only registers with AT-SPI a node that comes into view when that node itself
            changes -- so a row scrolled into view by its pane's transform alone is one a screen
            reader can't reach. So everything below a scrolling widget is sent again as it scrolls
            (see scrollChildren), and AccessKit hides what's out of view as it goes.
        */
        if (painted.x == painted.x) // not NaN: it's been painted, so it's somewhere
            accesskit_node_set_bounds(n, accesskit_rect(painted.x, painted.y,
                                                        painted.x + painted.w, painted.y + painted.h));
        if (_childClip)
            accesskit_node_set_clips_children(n);
        pushAccessibleChildren(n);
        if (disabled)
            accesskit_node_set_disabled(n);
        else if (_focusTraversable)
            accesskit_node_add_action(n, ACCESSKIT_ACTION_FOCUS);
        for (auto p = parent; p; p = p.parent)
        {
            if (p._childClip)
            {
                accesskit_node_add_action(n, ACCESSKIT_ACTION_SCROLL_INTO_VIEW);
                break;
            }
        }

        auto described = AccessibleNode(n, update, painted.x - drawn.x, painted.y - drawn.y);
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
        else if (_tooltip.length)
            described.description(_tooltip);
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
            if (!child._visible)
                continue;
            if (child._accessibleHidden)
                child.pushAccessibleChildren(n);
            else
                accesskit_node_push_child(n, child.accessibleId);
        }
    }


    /// Sets focused() and focusVisible(), and tells the widget if either changed.
    final void setFocusState(bool focused, bool visible)
    {
        if (focused == this.focused && visible == focusVisible)
            return;
        _setFocused(focused);
        _setFocusVisible(visible);
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
        if (_disable || !_visible)
            return;
        if (_focusTraversable && isTabStop)
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
        if (!_visible)
            return null;
        // A widget that has never been painted has a NaN rectangle, which contains nothing
        const inside = x >= painted.x && x < painted.x + painted.w && y >= painted.y && y < painted.y + painted.h;
        if (inside && claimsPoint(x, y))
            return this;
        if (!_childClip || insidePadding(painted).contains(x, y)) // clipped children can only be hit inside it
            foreach_reverse (child; _children)
                if (auto hit = child.pick(x, y))
                    return hit;
        return inside ? this : null;
    }

    /// Lets this widget hear `event`, unless it's disabled: the app's handler first, then its own.
    final void deliver(ref ScrollEvent event)
    {
        if (disabled)
            return;
        event.x = event.sceneX - painted.x;
        event.y = event.sceneY - painted.y;
        if (scrollHandler)
            scrollHandler(event);
        if (!event.consumed)
            handleScroll(event);
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
    struct Rect
    {
        float x = float.nan, y, w, h;
        bool contains(float px, float py) const nothrow @nogc { return px >= x && px < x + w && py >= y && py < y + h; }
    }

    Widget[] _children;
    Rect drawn;        // the rectangle this widget was last painted at, in its layer
    Rect painted;      // the same, where it's seen in the window: less any scrolling
    Tvg_Paint layer;   // what its shapes are in: see mount()
    Tvg_Paint _childLayer, _childClip; // from clipChildren()
    Tvg_Paint _childClipHolder;        // the scene the clip's on, which isn't this widget's to fade or scale
    StyleClassList _styleClass;
    Tvg_Paint[] regionPaints;          // background fills then border strokes, drawn before `shape`
    SvgPath svgShape;                  // `shapePath`, parsed
    Tvg_Point[] svgScratch;             // its points, placed, as it's drawn

    void parseShape()
    {
        import core.stdc.stdio : fprintf, stderr;
        svgShape = SvgPath.init;
        if (_shapePath.length)
        {
            try
                svgShape = SvgPath.parse(_shapePath);
            catch (Exception e)
                fprintf(stderr, "shape: %.*s\n", cast(int) e.msg.length, e.msg.ptr);
        }
        svgScratch = new Tvg_Point[svgShape.points.length];
        invalidate();
    }

    // The outline a background or border layer is drawn as: the shape if there is one, else a rounded rectangle
    void appendOutline(Tvg_Paint p, float x, float y, float w, float h, CornerRadii radii) nothrow @nogc
    {
        if (!svgShape.empty)
            svgShape.appendScaled(p, x, y, w, h, svgScratch);
        else
            appendRoundedRect(p, x, y, w, h, radii);
    }
    float appliedOpacity = 1;
    Tvg_Matrix appliedMatrix = identity;

    static immutable Tvg_Matrix identity = Tvg_Matrix(1, 0, 0, 0, 1, 0, 0, 0, 1);

    static Tvg_Matrix multiply(ref const Tvg_Matrix a, ref const Tvg_Matrix b) nothrow @nogc
    {
        return Tvg_Matrix(a.e11 * b.e11 + a.e12 * b.e21, a.e11 * b.e12 + a.e12 * b.e22, a.e11 * b.e13 + a.e12 * b.e23 + a.e13,
                          a.e21 * b.e11 + a.e22 * b.e21, a.e21 * b.e12 + a.e22 * b.e22, a.e21 * b.e13 + a.e22 * b.e23 + a.e23,
                          0, 0, 1);
    }

    static float clamp01(float v) nothrow @nogc { return v < 0 ? 0 : v > 1 ? 1 : v; }

    // Every paint that's this widget's own: its region, its shape, and any it added -- not the
    // layer its children are in, if it made one, as they see to their own
    void forEachOwnPaint(scope void delegate(Tvg_Paint) nothrow @nogc action) nothrow @nogc
    {
        if (!shape)
            return;
        foreach (p; regionPaints)
            action(p);
        action(shape);
        foreach (p; extraPaints)
            if (p !is _childClipHolder)
                action(p);
    }

    // As many paints as the background and border have layers, in the layer before `shape`
    void syncRegionPaints() nothrow
    {
        if (!shape)
            return;
        const want = _background.fills.length + _border.strokes.length;
        while (regionPaints.length < want)
        {
            auto p = tvg_shape_new();
            tvg_scene_insert(layer, p, shape);
            tvg_paint_set_opacity(p, cast(ubyte)(appliedOpacity * 255 + 0.5f));
            tvg_paint_set_transform(p, &appliedMatrix);
            regionPaints ~= p;
        }
        while (regionPaints.length > want)
        {
            tvg_scene_remove(layer, regionPaints[$ - 1]);
            regionPaints = regionPaints[0 .. $ - 1];
        }
        invalidate();
    }

    void paintRegion(float x, float y, float w, float h) nothrow @nogc
    {
        foreach (i, ref f; _background.fills)
        {
            auto p = regionPaints[i];
            tvg_shape_reset(p);
            tvg_shape_set_fill_color(p, f.fill.tupleof);
            appendOutline(p, x + f.insets.left, y + f.insets.top, w - f.insets.left - f.insets.right,
                          h - f.insets.top - f.insets.bottom, f.radii);
        }
        foreach (i, ref b; _border.strokes)
        {
            // Inside the edge: the stroke is centred on its path, so the path is half its width in
            auto p = regionPaints[_background.fills.length + i];
            const half = b.width / 2;
            tvg_shape_reset(p);
            tvg_shape_set_fill_color(p, 0, 0, 0, 0);
            tvg_shape_set_stroke_width(p, b.width);
            tvg_shape_set_stroke_color(p, b.colour.tupleof);
            appendOutline(p, x + b.insets.left + half, y + b.insets.top + half,
                          w - b.insets.left - b.insets.right - b.width, h - b.insets.top - b.insets.bottom - b.width,
                          b.radii.less(half));
        }
    }

    void parseInlineStyle()
    {
        import core.stdc.stdio : fprintf, stderr;
        inlineDeclarations = null;
        if (!_style.length)
            return;
        try
            inlineDeclarations = parseDeclarations(_style);
        catch (CssException e)
            fprintf(stderr, "%.*s's style: %.*s\n", cast(int) typeid(this).name.length, typeid(this).name.ptr,
                    cast(int) e.msg.length, e.msg.ptr);
    }
    float _childOffsetX = 0, _childOffsetY = 0; // from scrollChildren()
    bool repaint;      // set by invalidate(), for changes the rectangle doesn't show
    MouseHandler[MouseEventType.max + 1] mouseHandlers;
    KeyHandler[KeyEventType.max + 1] keyHandlers;
    InputMethodHandler inputMethodHandler;
    ScrollHandler scrollHandler;
    Tvg_Paint[] extraPaints; // from addPaint(), drawn after `shape` and before the children
    Tvg_Paint mountBefore;   // while mounting, where the shapes go: see mount()
    float _acrossX = 0, _acrossY = 0; // see place()

    /*
        How far to move this widget along one axis from where Yoga put it: `across` of whatever
        its parent's inside has left over beyond it and its margins, rounded to the pixel grid as
        Yoga rounds everything else. Nothing unless it stretches on that axis and falls short.
    */
    float shortfall(float across, float size, YGEdge start, YGEdge end,
                    typeof(&YGNodeLayoutGetWidth) parentSize) nothrow @nogc
    {
        import core.stdc.math : roundf;
        if (across == 0 || !parent)
            return 0;
        // What it's laid out in: its parent's node, or the cell its parent put it in
        auto container = cellNode ? cellNode : parent.node;
        const inside = parentSize(container)
                     - YGNodeLayoutGetPadding(container, start) - YGNodeLayoutGetPadding(container, end)
                     - YGNodeLayoutGetBorder(container, start) - YGNodeLayoutGetBorder(container, end);
        const left = inside - size - YGNodeLayoutGetMargin(node, start) - YGNodeLayoutGetMargin(node, end);
        const scale = scene ? YGConfigGetPointScaleFactor(scene.config) : 1;
        return roundf(left * across * scale) / scale;
    }

    void on(MouseEventType type, MouseHandler handler) nothrow @nogc
    {
        mouseHandlers[type] = handler;
    }

    void on(KeyEventType type, KeyHandler handler) nothrow @nogc
    {
        keyHandlers[type] = handler;
    }

    /// The first shape drawn after everything under `w` in its layer: the next sibling's, or
    /// failing that, the next sibling of the nearest ancestor with one in the same layer. Null if
    /// nothing comes after.
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
            if (w.parent._childLayer)
                return null; // the end of the parent's layer, which is all its children have
        }
        return null;
    }

    void invalidateAccessibleTree() nothrow @nogc
    {
        invalidateAccessible();
        foreach (child; _children)
            child.invalidateAccessibleTree();
    }

    /// The layer this widget's children are drawn in.
    Tvg_Paint childrensLayer() nothrow @nogc { return _childLayer ? _childLayer : layer; }

    /// `r` less this widget's padding, as the layout worked it out.
    Rect insidePadding(Rect r) nothrow @nogc
    {
        const l = YGNodeLayoutGetPadding(node, YGEdgeLeft), t = YGNodeLayoutGetPadding(node, YGEdgeTop);
        return Rect(r.x + l, r.y + t, r.w - l - YGNodeLayoutGetPadding(node, YGEdgeRight),
                    r.h - t - YGNodeLayoutGetPadding(node, YGEdgeBottom));
    }

    // Where the layout put this widget in its parent, with any nudge its alignment gives it (see place())
    float layoutX() nothrow @nogc
    {
        return cellX + YGNodeLayoutGetLeft(node) + shortfall(_acrossX, YGNodeLayoutGetWidth(node), YGEdgeLeft,
                                                     YGEdgeRight, &YGNodeLayoutGetWidth);
    }

    float layoutY() nothrow @nogc
    {
        return cellY + YGNodeLayoutGetTop(node) + shortfall(_acrossY, YGNodeLayoutGetHeight(node), YGEdgeTop,
                                                    YGEdgeBottom, &YGNodeLayoutGetHeight);
    }

    /// Takes the shapes of this widget and everything below it out of the scene.
    void unmount()
    {
        foreach (child; _children)
            child.unmount();
        // Off the scene's config, which the scene frees when it's done while this node lives on
        YGNodeSetConfig(node, cast(YGConfigRef) YGConfigGetDefault());
        if (cellNode)
            YGNodeSetConfig(cellNode, cast(YGConfigRef) YGConfigGetDefault());
        foreach (p; extraPaints)
            tvg_scene_remove(layer, p); // and with a clip, its layer, now empty
        extraPaints = null;
        foreach (p; regionPaints)
            tvg_scene_remove(layer, p);
        regionPaints = null;
        appliedOpacity = 1;
        appliedMatrix = identity;
        stopTransitions(this);
        styled = false; // styled afresh, with nothing to transition from, if it comes back
        _childLayer = _childClip = _childClipHolder = null;
        tvg_scene_remove(layer, shape); // the layer owned it, so this frees it
        shape = null;
        scene = null;
        layer = null;
        painted = drawn = Rect.init; // NaN again: nothing to hit, and painted in full if it comes back
        _setHover(false);
        _setPressed(false);
        _setFocused(false);
        _setFocusVisible(false);
        unmounted();
    }

    /*
        Works out `disabled` again -- this widget's own `disable`, or its parent's `disabled` -- and
        if that changed, tells the widget and goes on down to its children, whose depends on it.
        Called when `disable` is set and when the widget moves to a different parent.
    */
    void visibilityChanged()
    {
        YGNodeStyleSetDisplay(node, _visible ? YGDisplayFlex : YGDisplayNone);
        invalidate();
        invalidateAccessibleTree(); // gone from what a screen reader sees, or back, with all it holds
        if (parent)
            parent.invalidateAccessible();
        if (!_visible && scene)
            scene.forgetFocusWithin(this);
    }

    void refreshDisabled()
    {
        const now = _disable || (parent && parent.disabled);
        if (now == disabled)
            return;
        _setDisabled(now);
        if (now && scene)
            scene.forgetFocusWithin(this); // a disabled widget can't have focus
        invalidateAccessible();
        disabledChanged();
        foreach (child; _children)
            child.refreshDisabled();
    }

    // Asks the parent to place this widget again, or places it on its own if it has none
    void placeInParent() nothrow @nogc
    {
        if (parent)
            parent.placeChild(this);
        else
            place(_grow, false, false, YGAlignAuto);
    }

    /*
        The sizes, passed on to Yoga. NaN means "work it out", which Yoga calls auto for a size and
        undefined for a bound, and so does a bound of no limit, or of the preferred size when that's
        worked out from the content: holding to it is up to the parent (see Row). A stretched axis
        is as place() describes.
    */
    void applySize(bool stretchWidth, bool stretchHeight) nothrow @nogc
    {
        // A scene's root is the window's size, whatever it asks for, as JavaFX's is: it's in
        // percentages, which the scene's layout resolves against the window (see Scene.attach)
        if (scene && !parent && scene.root is this)
        {
            YGNodeStyleSetWidthPercent(node, 100);
            YGNodeStyleSetHeightPercent(node, 100);
            YGNodeStyleSetMinWidth(node, float.nan);
            YGNodeStyleSetMaxWidth(node, float.nan);
            YGNodeStyleSetMinHeight(node, float.nan);
            YGNodeStyleSetMaxHeight(node, float.nan);
            return;
        }
        applyAxis!(YGNodeStyleSetWidth, YGNodeStyleSetWidthAuto, YGNodeStyleSetMinWidth, YGNodeStyleSetMaxWidth)
                  (node, _minWidth, _prefWidth, _maxWidth, stretchWidth);
        applyAxis!(YGNodeStyleSetHeight, YGNodeStyleSetHeightAuto, YGNodeStyleSetMinHeight, YGNodeStyleSetMaxHeight)
                  (node, _minHeight, _prefHeight, _maxHeight, stretchHeight);
    }

    void applyPadding() nothrow @nogc
    {
        YGNodeStyleSetPadding(node, YGEdgeTop, _padding.top);
        YGNodeStyleSetPadding(node, YGEdgeRight, _padding.right);
        YGNodeStyleSetPadding(node, YGEdgeBottom, _padding.bottom);
        YGNodeStyleSetPadding(node, YGEdgeLeft, _padding.left);
    }

    void applyMargin() nothrow @nogc
    {
        YGNodeStyleSetMargin(node, YGEdgeTop, _margin.top);
        YGNodeStyleSetMargin(node, YGEdgeRight, _margin.right);
        YGNodeStyleSetMargin(node, YGEdgeBottom, _margin.bottom);
        YGNodeStyleSetMargin(node, YGEdgeLeft, _margin.left);
    }
}

// One axis of Widget.applySize: the size, and the min and max bounding it
private void applyAxis(alias setSize, alias setAuto, alias setMin, alias setMax)
                      (YGNodeRef node, float min, float pref, float max, bool stretch) nothrow @nogc
{
    import std.math : isFinite;
    if (min == Widget.usePrefSize)
        min = pref; // NaN if the preferred size is worked out, and then a Row's no-shrinking holds it
    if (max == Widget.usePrefSize)
        max = pref;
    if (stretch)
    {
        setAuto(node);
        if (pref == pref && !(pref <= min))
            min = pref;
    }
    else if (pref == pref)
        setSize(node, pref);
    else
        setAuto(node);
    setMin(node, min);
    setMax(node, isFinite(max) ? max : float.nan);
}

/// A cell's child changed its layout: its parent, which places it, has to measure and place again.
private extern(C) void cellDirtied(YGNodeConstRef cell) nothrow @nogc
{
    // Unless it's the parent's own doing: sizing a cell to measure or place what's in it changes
    // the cell, and that's not the child changing -- taken for one, it would lay out forever
    if (auto parent = cast(Widget) YGNodeGetContext(cell))
        if (!parent.placingCells)
            parent.childLayoutChanged();
}

/// Puts every node in the tree under `w` back on Yoga's default config, so the scene's can be freed.
package void releaseConfig(Widget w) nothrow @nogc
{
    YGNodeSetConfig(w.node, cast(YGConfigRef) YGConfigGetDefault());
    if (w.cellNode)
        YGNodeSetConfig(w.cellNode, cast(YGConfigRef) YGConfigGetDefault());
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
