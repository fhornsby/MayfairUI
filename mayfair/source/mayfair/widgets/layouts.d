module mayfair.widgets.layouts;

import mayfair.layout;
import mayfair.css;
import mayfair.properties;
import mayfair.widgets.widget;

/// Where children sit in a container with room to spare. JavaFX's Pos.
enum Pos
{
    topLeft, topCenter, topRight,
    centerLeft, center, centerRight,
    bottomLeft, bottomCenter, bottomRight,
}

/*
    Arranges its children in a row, left to right. Draws nothing itself. JavaFX's HBox.

        new Row().spacing(8).alignment(Pos.centerLeft)

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

private:

// Where along an axis: start, middle or end
enum Place { start, middle, end }

Place horizontal(Pos p) nothrow @nogc
{
    final switch (p)
    {
        case Pos.topLeft, Pos.centerLeft, Pos.bottomLeft: return Place.start;
        case Pos.topCenter, Pos.center, Pos.bottomCenter: return Place.middle;
        case Pos.topRight, Pos.centerRight, Pos.bottomRight: return Place.end;
    }
}

Place vertical(Pos p) nothrow @nogc
{
    final switch (p)
    {
        case Pos.topLeft, Pos.topCenter, Pos.topRight: return Place.start;
        case Pos.centerLeft, Pos.center, Pos.centerRight: return Place.middle;
        case Pos.bottomLeft, Pos.bottomCenter, Pos.bottomRight: return Place.end;
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
