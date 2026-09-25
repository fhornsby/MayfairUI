module mayfair.widgets.layouts;

import mayfair.layout;
import mayfair.widgets.widget;

/// Arranges its children in a row, left to right. Draws nothing itself.
class Row : Widget
{
    this() nothrow @nogc
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
    }
}

/// Arranges its children in a column, top to bottom. Draws nothing itself.
class Column : Widget
{
    this() nothrow @nogc
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
    }
}
