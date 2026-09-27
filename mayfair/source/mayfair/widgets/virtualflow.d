module mayfair.widgets.virtualflow;

import std.math : ceil, floor;
import mayfair.layout;
import mayfair.widgets.layouts;
import mayfair.widgets.scrollpane;
import mayfair.widgets.styling : styleNow;
import mayfair.widgets.widget;

/*
    Rows of one height, of which only those in view are made: what a ListView and a TableView
    scroll through. A list of a hundred thousand items has as many rows as fit in its window,
    and a couple more either side, whatever its length.

    It's the content of a ScrollPane, as tall as all its rows would be, and each row is a widget
    its owner makes (makeRow) and fills in for the item it's showing (bindRow). As it scrolls, a
    row that's gone out of view is given an item coming into it, rather than a new row made --
    so a row can show many items in its life, and fill in whatever it shows each time. Rows
    already showing an item still in view keep it, so scrolling doesn't fill in what's already
    there.

    The rows are swapped between frames, in the update phase, where widgets can be made and
    changed; layout only puts them where their items go.
*/
final class VirtualFlow : CustomLayout
{
public:
    this(Widget delegate() makeRow, void delegate(Widget row, size_t index) bindRow)
    {
        _makeRow = makeRow;
        _bindRow = bindRow;
        styleClass.add("virtual-flow");
        setAccessibleHidden(true); // its rows are its owner's, to a screen reader
    }

    /// The scroll pane it's in, whose view says which rows are wanted. The owner sets it.
    ScrollPane pane;

    /// Called in the update after the view changes size, before the rows are refreshed: for an
    /// owner whose rows depend on how wide it is, as a table's last column fills it.
    void delegate() onViewportChanged;

    /// Throws every row away, to be made afresh: for when what a row is made of has changed, as a
    /// table's is when its columns do.
    final void clear()
    {
        foreach (row; _rows)
            remove(row);
        _rows = null;
        _shows = null;
        if (_fixedRowHeight <= 0)
            _rowHeight = 0;
        refresh(true);
    }

    /// How many rows there are.
    final size_t count() const nothrow @nogc { return _count; }

    /// There are `n` rows now, and every row showing one is filled in again, as what they show may
    /// have changed.
    final void setCount(size_t n)
    {
        _count = n;
        if (!n)
            _rowHeight = 0; // measured again from the next first row
        refresh(true);
    }

    /// How tall each row is: measured from the first, unless set here. 0 until it's known.
    final float rowHeight() const nothrow @nogc { return _rowHeight; }

    /// Sets how tall each row is, rather than measuring; 0 to measure.
    final void setFixedRowHeight(float h)
    {
        _fixedRowHeight = h;
        _rowHeight = h;
        refresh(true);
    }

    /// How wide the rows are, at least: a table's columns side by side. 0 for as wide as the view.
    final void setContentWidth(float w)
    {
        if (w == _contentWidth)
            return;
        _contentWidth = w;
        childLayoutChanged();
    }

    /// The row showing `index`, if it's made.
    final Widget rowAt(size_t index) nothrow @nogc
    {
        foreach (i, shows; _shows)
            if (shows == index)
                return _rows[i];
        return null;
    }

    /// Which index `row` shows, or size_t.max if it's one of the spare ones.
    final size_t indexOf(const Widget row) const nothrow @nogc
    {
        foreach (i, r; _rows)
            if (r is row)
                return _shows[i];
        return size_t.max;
    }

    /// Scrolls so row `index` is in view.
    final void reveal(size_t index)
    {
        if (_rowHeight > 0 && index < _count)
            scrollIntoView(Bounds(0, index * _rowHeight, 1, _rowHeight));
    }

    /*
        Makes sure the rows in view are made and showing what they should: after scrolling, a
        new count, or the view changing size. With `rebind`, every row in use is filled in again.
    */
    final void refresh(bool rebind = false)
    {
        if (!scene)
        {
            _pendingRebind = _pendingRebind || rebind;
            return; // until it's in a window, there's no view to fill
        }
        rebind = rebind || _pendingRebind;
        _pendingRebind = false;

        if (_count && _rowHeight <= 0)
            measureRowHeight();

        // What's in view, or a guess before there's been a layout to say
        const view = pane ? pane.viewportBounds : Bounds(0, 0, 0, 0);
        const viewHeight = view.height > 0 ? view.height : 600;
        _viewHeight = view.height;
        size_t first, last;
        if (_count && _rowHeight > 0)
        {
            const top = floor(view.minY / _rowHeight) - overscan;
            const bottom = ceil((view.minY + viewHeight) / _rowHeight) + overscan;
            first = top < 0 ? 0 : cast(size_t) top;
            last = bottom > _count ? _count : cast(size_t) bottom;
            if (first > last)
                first = last;
        }

        // Rows already showing an index still wanted keep it; the rest are free to be given one
        bool[] free = new bool[_rows.length];
        foreach (i, shows; _shows)
        {
            free[i] = shows < first || shows >= last || shows >= _count;
            if (!free[i] && rebind)
                _bindRow(_rows[i], shows);
        }
        foreach (index; first .. last)
        {
            if (rowAt(index))
                continue;
            size_t slot = size_t.max;
            foreach (i, f; free)
                if (f)
                {
                    slot = i;
                    break;
                }
            if (slot == size_t.max)
            {
                auto row = _makeRow();
                _rows ~= row;
                _shows ~= size_t.max;
                free ~= true;
                slot = _rows.length - 1;
                adopt(row);
                styleNow(row); // looking as it should in the frame it first shows in
            }
            free[slot] = false;
            _shows[slot] = index;
            _rows[slot].setVisible(true);
            _bindRow(_rows[slot], index);
        }
        foreach (i, f; free)
        {
            if (!f)
                continue;
            _shows[i] = size_t.max;
            _rows[i].setVisible(false); // spare, for the next to come into view
        }
        childLayoutChanged();
    }

protected:
    override void placeChild(Widget child) nothrow @nogc
    {
        setCell(child, true, true, Pos.topLeft);
    }

    override void measureContent(float width, float height, out float w, out float h) nothrow @nogc
    {
        w = _contentWidth;
        h = _count * _rowHeight;
    }

    override void arrange(float width, float height) nothrow @nogc
    {
        // The view's changed size: there may be more or fewer rows to show, next update
        if (pane && (pane.viewportBounds.height != _viewHeight || pane.viewportBounds.width != _viewWidth))
        {
            _viewportMoved = true;
            requestUpdate();
        }
        const w = width > _contentWidth ? width : _contentWidth;
        foreach (i, row; _rows)
            if (_shows[i] != size_t.max)
                layoutCell(row, 0, _shows[i] * _rowHeight, w, _rowHeight);
    }

    override void update()
    {
        if (_viewportMoved)
        {
            _viewportMoved = false;
            _viewWidth = pane ? pane.viewportBounds.width : 0;
            if (onViewportChanged)
                onViewportChanged();
        }
        refresh();
    }

    override void mounted() nothrow
    {
        requestUpdate(); // now there's a window, fill the view
    }

private:
    enum overscan = 2; // rows made beyond each end of the view, so a small scroll has them ready
    Widget delegate() _makeRow;
    void delegate(Widget, size_t) _bindRow;
    Widget[] _rows;
    size_t[] _shows;   // the index each row shows, or size_t.max for a spare one
    size_t _count;
    float _rowHeight = 0, _fixedRowHeight = 0, _contentWidth = 0, _viewHeight = -1, _viewWidth = -1;
    bool _pendingRebind, _viewportMoved;

    // A row's height, from the first item: the one every row has
    void measureRowHeight()
    {
        if (_fixedRowHeight > 0)
        {
            _rowHeight = _fixedRowHeight;
            return;
        }
        if (!_rows.length)
        {
            auto row = _makeRow();
            _rows ~= row;
            _shows ~= size_t.max;
            adopt(row);
        }
        _bindRow(_rows[0], 0);
        float w, h;
        _rows[0].setVisible(true);
        styleNow(_rows[0]); // with its padding and font, as it'll be drawn
        measureCell(_rows[0], float.nan, w, h);
        _rowHeight = h > 1 ? h : 1;
    }
}
