module mayfair.widgets.layouts;

import mayfair.layout;
import mayfair.css;
import mayfair.properties;
import mayfair.widgets.widget;

/// Where along one line something sits: a grid's column or row, a popup against what it's for.
enum Alignment { start, centre, end }

/// Where children sit in a container with room to spare. JavaFX's Pos.
enum Pos
{
    topLeft, topCentre, topRight,
    centreLeft, centre, centreRight,
    bottomLeft, bottomCentre, bottomRight,
}

/*
    Arranges its children in a row, left to right. Draws nothing itself. JavaFX's HBox.

        new Row().spacing(8).alignment(Pos.centreLeft)

    Children get their preferred widths, plus a share of any room to spare if they grow (see
    Widget.grow). Across the row they stretch to its height, as JavaFX's fillHeight does, unless
    that's switched off -- then `alignment` says where in the height they sit.

    Either way a child keeps to its max, as in JavaFX, so a control -- whose max is its preferred
    size -- neither stretches nor grows, and sits where `alignment` puts it; a container does both.
    See Widget.maxWidth.
*/
class Row : Widget
{
public:
    this() nothrow @nogc
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        arrange();
    }

    /// Space between one child and the next, in points.
    mixin(declareStyleableProperty!(float, "spacing", "gap", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));

    /// Where the children sit when there's room to spare.
    mixin(declareStyleableProperty!(Pos, "alignment", "alignment", "Pos.topLeft", q{ arrange(); }));

    /// Whether children stretch to the row's height, as far as their max allows. On by default, as
    /// in JavaFX.
    mixin(declareStyleableProperty!(bool, "fillHeight", "fill-height", "true", q{ arrange(); }));

protected:
    override void placeChild(Widget child) nothrow @nogc
    {
        const stretch = _fillHeight && !child.heightHeldToPref;
        child.place(child.widthHeldToPref ? 0 : child.grow, false, stretch,
                    stretch ? YGAlignStretch : YGAlignAuto, fraction(vertical(_alignment)));
    }

private:
    void arrange() nothrow @nogc
    {
        placeChildren(node, horizontal(_alignment), vertical(_alignment));
        foreach (child; children)
            placeChild(child);
    }
}

/*
    Arranges its children in a column, top to bottom. Draws nothing itself. JavaFX's VBox.

    The same as Row turned on its side: children stretch to the column's width, as far as their max
    allows, unless fillWidth is off, and `alignment` says where across it those that don't sit.
*/
class Column : Widget
{
public:
    this() nothrow @nogc
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
        arrange();
    }

    /// Space between one child and the next, in points.
    mixin(declareStyleableProperty!(float, "spacing", "gap", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));

    /// Where the children sit when there's room to spare.
    mixin(declareStyleableProperty!(Pos, "alignment", "alignment", "Pos.topLeft", q{ arrange(); }));

    /// Whether children stretch to the column's width, as far as their max allows. On by default,
    /// as in JavaFX.
    mixin(declareStyleableProperty!(bool, "fillWidth", "fill-width", "true", q{ arrange(); }));

protected:
    override void placeChild(Widget child) nothrow @nogc
    {
        const stretch = _fillWidth && !child.widthHeldToPref;
        child.place(child.heightHeldToPref ? 0 : child.grow, stretch, false,
                    stretch ? YGAlignStretch : YGAlignAuto, fraction(horizontal(_alignment)));
    }

private:
    void arrange() nothrow @nogc
    {
        placeChildren(node, vertical(_alignment), horizontal(_alignment));
        foreach (child; children)
            placeChild(child);
    }
}

/*
    A container that places its children itself, for a layout flexbox can't say: Stack, Dock and
    Grid are each one, and an app's own is written the same way.

        class Diagonal : CustomLayout
        {
            override void measureContent(float width, float height, out float w, out float h) nothrow @nogc { ... }
            override void arrange(float width, float height) nothrow @nogc { ... }
        }

    Each child sits in a cell of its own -- an invisible box, which this sizes and places -- and
    inside it the child is laid out as it would be anywhere: a label wraps to the cell's width, a
    row lays out its children. setCell() says how a child sits in its cell, measureCell() asks how
    big it would like to be, and layoutCell() gives it its cell's size and place.

    measureContent() is asked whenever the layout around needs this one's size; arrange() once its
    own size is settled, just before it's painted, and again whenever a child's size could have
    changed. Both run inside the frame, so neither may allocate: anything they need is made when
    the children change.
*/
abstract class CustomLayout : Widget
{
public:
    this() nothrow @nogc
    {
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureCustomLayout);
    }

protected:
    override bool placesChildren() const nothrow @nogc { return true; }

    /// How big the content wants to be, inside the padding, given at most `width` across and
    /// `height` down -- either NaN for no limit.
    abstract void measureContent(float width, float height, out float w, out float h) nothrow @nogc;

    /// Lays every child out with layoutCell(), in content `width` by `height`, measured from the
    /// top left inside the padding.
    abstract void arrange(float width, float height) nothrow @nogc;

    /*
        How `child` sits in its cell: filling it across and down where `fillWidth` and
        `fillHeight` say, as far as its max allows, and otherwise at `alignment`. A control, held
        to its preferred size, never fills. Call it from placeChild(), which runs when the child
        is added and when its sizes change.
    */
    final void setCell(Widget child, bool fillWidth, bool fillHeight, Pos alignment) nothrow @nogc
    {
        auto cell = child.cellNode;
        if (!cell)
            return;
        const stretchWidth = fillWidth && !child.widthHeldToPref;
        const stretchHeight = fillHeight && !child.heightHeldToPref;
        YGNodeStyleSetFlexDirection(cell, YGFlexDirectionColumn);
        placeChildren(cell, vertical(alignment), horizontal(alignment));
        child.place(stretchHeight ? 1 : 0, stretchWidth, false, stretchWidth ? YGAlignStretch : YGAlignAuto,
                    fraction(horizontal(alignment)));
        // Its own height while the cell's is being measured, rather than growing from nothing
        YGNodeStyleSetFlexBasisAuto(child.node);
    }

    /*
        How big `child` would like to be, its margins included: as wide as it likes, and as tall
        as that makes it -- or, given a `width` that isn't NaN, no wider than that and as tall as
        that makes it, which is what text that wraps needs to be asked.
    */
    final void measureCell(Widget child, float width, out float w, out float h) nothrow @nogc
    {
        auto cell = child.cellNode;
        if (!cell || YGNodeStyleGetDisplay(child.node) == YGDisplayNone)
        {
            w = h = 0;
            return;
        }
        /*
            As big as it likes, but with a limit, however far off: Yoga only honours a flex basis
            -- how a text area asks for its rows -- where there's a known size to measure against,
            and with none at all a text area would come out one line tall. So the cell's size is
            left to its content, up to a max that nothing reaches, rather than unlimited.
        */
        enum limit = 1e6f;
        YGNodeStyleSetWidthAuto(cell);
        YGNodeStyleSetHeightAuto(cell);
        YGNodeStyleSetMaxWidth(cell, limit);
        YGNodeStyleSetMaxHeight(cell, limit);
        YGNodeCalculateLayout(cell, float.nan, float.nan, YGDirectionLTR);
        w = YGNodeLayoutGetWidth(cell);
        h = YGNodeLayoutGetHeight(cell);
        if (width == width && width < w)
        {
            YGNodeStyleSetMaxWidth(cell, width < 0 ? 0 : width);
            YGNodeCalculateLayout(cell, float.nan, float.nan, YGDirectionLTR);
            w = width;
            h = YGNodeLayoutGetHeight(cell);
        }
    }

    /// Gives `child`'s cell its place and size: `x`, `y` from the top left inside the padding.
    final void layoutCell(Widget child, float x, float y, float w, float h) nothrow @nogc
    {
        import std.math : round;
        auto cell = child.cellNode;
        if (!cell)
            return;
        // On the pixel grid, as Yoga puts everything else, so what's inside rasterises crisply.
        // Both edges are rounded, and the size is what's between them, so cells side by side
        // meet without a gap or an overlap.
        const scale = scene ? scene.scale : 1.0f;
        float snap(float v) { return round(v * scale) / scale; }
        if (w < 0) w = 0;
        if (h < 0) h = 0;
        const left = snap(_contentLeft + x), top = snap(_contentTop + y);
        child.cellX = left;
        child.cellY = top;
        // Exactly this big: a size of its own, which Yoga takes over the max that measuring left
        YGNodeStyleSetWidth(cell, snap(_contentLeft + x + w) - left);
        YGNodeStyleSetHeight(cell, snap(_contentTop + y + h) - top);
        YGNodeCalculateLayout(cell, float.nan, float.nan, YGDirectionLTR);
    }

    /// Everything's to be measured and placed again: for a subclass whose own settings changed.
    final void relayout() nothrow @nogc
    {
        foreach (child; children)
            placeChild(child);
        childLayoutChanged();
    }

    final override void laidOut(float x, float y, float w, float h) nothrow @nogc
    {
        const l = YGNodeLayoutGetPadding(node, YGEdgeLeft), t = YGNodeLayoutGetPadding(node, YGEdgeTop);
        const cw = w - l - YGNodeLayoutGetPadding(node, YGEdgeRight);
        const ch = h - t - YGNodeLayoutGetPadding(node, YGEdgeBottom);
        if (!arrangeNeeded && cw == _arrangedWidth && ch == _arrangedHeight && l == _contentLeft && t == _contentTop)
            return;
        arrangeNeeded = false;
        _arrangedWidth = cw;
        _arrangedHeight = ch;
        _contentLeft = l;
        _contentTop = t;
        arrange(cw < 0 ? 0 : cw, ch < 0 ? 0 : ch);
    }

private:
    float _arrangedWidth = float.nan, _arrangedHeight = float.nan; // what it last arranged in
    float _contentLeft = 0, _contentTop = 0;                         // its padding, then
}

/*
    Yoga asking how big a CustomLayout is. Measuring lays its children out at sizes other than
    their final ones, so they're arranged again before they're painted.
*/
private extern(C) YGSize measureCustomLayout(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                             float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(CustomLayout) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    self.arrangeNeeded = true;
    float w, h;
    self.measureContent(widthMode == YGMeasureModeUndefined ? float.nan : width,
                        heightMode == YGMeasureModeUndefined ? float.nan : height, w, h);
    return YGSize(w, h);
}

/*
    Its children one on top of another, each filling it as far as its max allows, and the first
    at the back. As big as the biggest.

        new Stack().add(photo).add(new Label("Caption"))   // the caption over the photo

    What doesn't fill it -- a control, which keeps to its preferred size -- sits where `alignment`
    says: in the middle, unless told otherwise. What it's for: a badge over an icon, a spinner over
    a page while it loads, a picture behind what's written on it.
*/
class Stack : CustomLayout
{
public:
    this() nothrow @nogc {}

    /// Where children that don't fill it sit.
    mixin(declareStyleableProperty!(Pos, "alignment", "alignment", "Pos.centre", q{ relayout(); }));

protected:
    override void placeChild(Widget child) nothrow @nogc
    {
        setCell(child, true, true, _alignment);
    }

    override void measureContent(float width, float height, out float w, out float h) nothrow @nogc
    {
        w = h = 0;
        foreach (child; children)
        {
            float cw, ch;
            measureCell(child, width, cw, ch);
            if (cw > w) w = cw;
            if (ch > h) h = ch;
        }
    }

    override void arrange(float width, float height) nothrow @nogc
    {
        foreach (child; children)
            layoutCell(child, 0, 0, width, height);
    }
}

/*
    The shape of most windows: something along the top and the bottom, down the left and the
    right, and the rest in the middle. A toolbar, a status bar, a sidebar and a page:

        new Dock().top(toolbar).left(sidebar).centre(page).bottom(status)

    The top and bottom are as tall as they like, and the full width; the left and right as wide as
    they like, and as tall as what's between the top and bottom; the centre takes what's left. Any
    of them can be left out, and `spacing` goes between those that aren't.

    Each fills its part as far as its max allows. A control, held to its preferred size, sits at
    its part's top left -- the right's at the top right, the bottom's at the bottom left -- and the
    centre's in the middle. They're in the tree in reading order, top, left, centre, right, bottom,
    which is the order Tab moves through them and a screen reader reads them.
*/
class Dock : CustomLayout
{
public:
    this() nothrow @nogc {}

    /// What goes along the top.
    mixin(declareProperty!(Widget, "top", "null", q{ show(Part.top, _top); }));
    /// What goes along the bottom.
    mixin(declareProperty!(Widget, "bottom", "null", q{ show(Part.bottom, _bottom); }));
    /// What goes down the left.
    mixin(declareProperty!(Widget, "left", "null", q{ show(Part.left, _left); }));
    /// What goes down the right.
    mixin(declareProperty!(Widget, "right", "null", q{ show(Part.right, _right); }));
    /// What goes in the middle, taking whatever room is left.
    mixin(declareProperty!(Widget, "centre", "null", q{ show(Part.centre, _centre); }));

    /// Space between one part and the next, in points.
    mixin(declareStyleableProperty!(float, "spacing", "gap", "0", q{ childLayoutChanged(); }));

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // its parts are set by name

    override void placeChild(Widget child) nothrow @nogc
    {
        static immutable Pos[Part.max + 1] alignments = [Pos.topLeft, Pos.topLeft, Pos.centre, Pos.topRight, Pos.bottomLeft];
        foreach (i, shown; _shown)
            if (shown is child)
                setCell(child, true, true, alignments[i]);
    }

    override void childRemoved(Widget child)
    {
        foreach (ref shown; _shown)
            if (shown is child)
                shown = null;
    }

    override void measureContent(float width, float height, out float w, out float h) nothrow @nogc
    {
        float tw = 0, th = 0, bw = 0, bh = 0, lw = 0, lh = 0, rw = 0, rh = 0, cw = 0, ch = 0;
        if (auto t = _shown[Part.top]) measureCell(t, width, tw, th);
        if (auto b = _shown[Part.bottom]) measureCell(b, width, bw, bh);
        if (auto l = _shown[Part.left]) measureCell(l, float.nan, lw, lh);
        if (auto r = _shown[Part.right]) measureCell(r, float.nan, rw, rh);
        const across = acrossGaps;
        if (auto c = _shown[Part.centre])
        {
            const room = width == width ? width - lw - rw - across : float.nan;
            measureCell(c, room == room && room < 0 ? 0 : room, cw, ch);
        }
        float middle = lh > ch ? lh : ch;
        if (rh > middle) middle = rh;
        w = lw + cw + rw + across;
        if (tw > w) w = tw;
        if (bw > w) w = bw;
        h = th + middle + bh + downGaps;
    }

    override void arrange(float width, float height) nothrow @nogc
    {
        float top = 0, bottom = height, left = 0, right = width, w, h;
        const middle = hasMiddle;
        if (auto t = _shown[Part.top])
        {
            measureCell(t, width, w, h);
            layoutCell(t, 0, 0, width, h);
            top = h + (middle || _shown[Part.bottom] ? _spacing : 0);
        }
        if (auto b = _shown[Part.bottom])
        {
            measureCell(b, width, w, h);
            layoutCell(b, 0, height - h, width, h);
            bottom = height - h - (middle ? _spacing : 0);
        }
        const tall = bottom > top ? bottom - top : 0;
        if (auto l = _shown[Part.left])
        {
            measureCell(l, float.nan, w, h);
            if (w > width) w = width;
            layoutCell(l, 0, top, w, tall);
            left = w + (_shown[Part.centre] || _shown[Part.right] ? _spacing : 0);
        }
        if (auto r = _shown[Part.right])
        {
            measureCell(r, float.nan, w, h);
            if (w > width - left) w = width - left > 0 ? width - left : 0;
            layoutCell(r, width - w, top, w, tall);
            right = width - w - (_shown[Part.centre] ? _spacing : 0);
        }
        if (auto c = _shown[Part.centre])
            layoutCell(c, left, top, right > left ? right - left : 0, tall);
    }

private:
    enum Part { top, left, centre, right, bottom } // in reading order, which is the order in the tree
    Widget[Part.max + 1] _shown;

    void show(Part part, Widget w)
    {
        if (_shown[part] is w)
            return;
        if (_shown[part])
            remove(_shown[part]);
        if (!w)
            return;
        if (w.parent)
            w.parent.remove(w); // from another part of this one, if it's moving
        _shown[part] = w;
        size_t index;
        foreach (p; Part.min .. part)
            if (_shown[p])
                index++;
        adopt(w, index);
    }

    bool hasMiddle() const nothrow @nogc
    {
        return _shown[Part.left] || _shown[Part.centre] || _shown[Part.right];
    }

    // The spacing between the parts across the middle, and between the rows down it
    float acrossGaps() const nothrow @nogc
    {
        int n;
        foreach (p; [Part.left, Part.centre, Part.right])
            if (_shown[p]) n++;
        return n > 1 ? (n - 1) * _spacing : 0;
    }

    float downGaps() const nothrow @nogc
    {
        const n = (_shown[Part.top] ? 1 : 0) + (hasMiddle ? 1 : 0) + (_shown[Part.bottom] ? 1 : 0);
        return n > 1 ? (n - 1) * _spacing : 0;
    }
}

package:

// Where along an axis: start, middle or end
enum Place { start, middle, end }

Place horizontal(Pos p) nothrow @nogc
{
    final switch (p)
    {
        case Pos.topLeft, Pos.centreLeft, Pos.bottomLeft: return Place.start;
        case Pos.topCentre, Pos.centre, Pos.bottomCentre: return Place.middle;
        case Pos.topRight, Pos.centreRight, Pos.bottomRight: return Place.end;
    }
}

Place vertical(Pos p) nothrow @nogc
{
    final switch (p)
    {
        case Pos.topLeft, Pos.topCentre, Pos.topRight: return Place.start;
        case Pos.centreLeft, Pos.centre, Pos.centreRight: return Place.middle;
        case Pos.bottomLeft, Pos.bottomCentre, Pos.bottomRight: return Place.end;
    }
}

/// How far along an axis a place is, as a fraction of it
float fraction(Place p) nothrow @nogc
{
    return p == Place.start ? 0 : p == Place.middle ? 0.5f : 1;
}

/// Places a container's children: `along` its own direction, and `across` it those that don't
/// stretch, which each say so for themselves with alignSelf (see placeChild).
void placeChildren(YGNodeRef node, Place along, Place across) nothrow @nogc
{
    YGNodeStyleSetJustifyContent(node, along == Place.start ? YGJustifyFlexStart
                                     : along == Place.middle ? YGJustifyCenter : YGJustifyFlexEnd);
    YGNodeStyleSetAlignItems(node, across == Place.start ? YGAlignFlexStart
                                 : across == Place.middle ? YGAlignCenter : YGAlignFlexEnd);
}
