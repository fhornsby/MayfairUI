module mayfair.widgets.layouts;

import mayfair.layout;
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
*/
class Row : Widget
{
public:
    this() nothrow @nogc
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
    }

    /// Space between one child and the next, in points.
    mixin(declareProperty!(float, "spacing", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));

    /// Where the children sit when there's room to spare.
    mixin(declareProperty!(Pos, "alignment", "Pos.topLeft", q{ arrange(); }));

    /// Whether children stretch to the row's height. On by default, as in JavaFX.
    mixin(declareProperty!(bool, "fillHeight", "true", q{ arrange(); }));

private:
    void arrange() nothrow @nogc
    {
        placeChildren(node, horizontal(_alignment), vertical(_alignment), _fillHeight);
    }
}

/*
    Arranges its children in a column, top to bottom. Draws nothing itself. JavaFX's VBox.

    The same as Row turned on its side: children stretch to the column's width unless fillWidth is
    off, and then `alignment` says where across it they sit.
*/
class Column : Widget
{
public:
    this() nothrow @nogc
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
    }

    /// Space between one child and the next, in points.
    mixin(declareProperty!(float, "spacing", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));

    /// Where the children sit when there's room to spare.
    mixin(declareProperty!(Pos, "alignment", "Pos.topLeft", q{ arrange(); }));

    /// Whether children stretch to the column's width. On by default, as in JavaFX.
    mixin(declareProperty!(bool, "fillWidth", "true", q{ arrange(); }));

private:
    void arrange() nothrow @nogc
    {
        placeChildren(node, vertical(_alignment), horizontal(_alignment), _fillWidth);
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

/// Places a container's children: `along` its own direction, `across` it unless they stretch.
void placeChildren(YGNodeRef node, Place along, Place across, bool fill) nothrow @nogc
{
    YGNodeStyleSetJustifyContent(node, along == Place.start ? YGJustifyFlexStart
                                     : along == Place.middle ? YGJustifyCenter : YGJustifyFlexEnd);
    YGNodeStyleSetAlignItems(node, fill ? YGAlignStretch
                                 : across == Place.start ? YGAlignFlexStart
                                 : across == Place.middle ? YGAlignCenter : YGAlignFlexEnd);
}
