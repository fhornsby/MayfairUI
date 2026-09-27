module mayfair.widgets.grid;

import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.layouts;
import mayfair.widgets.widget;

/*
    Children in rows and columns that line up: a form's labels in one column and its fields in the
    next, a table of settings, a keypad.

        auto form = new Grid().columnGap(12).rowGap(8);
        form.addRow(0, new Label("Name"), name);
        form.addRow(1, new Label("Email"), email);
        form.add(save, 1, 2);                       // column 1, row 2
        form.column(1).grow(1);                     // the fields take any room to spare

    A column is as wide as the widest thing in it, and a row as tall as the tallest -- the height
    worked out at the column's width, so text that wraps wraps to it. Something can span several
    columns or rows, and they grow to fit it if they must. column() and row() say more about one:
    a size to keep between minSize and maxSize, or to be exactly prefSize; how much of any room to
    spare it takes (grow); and where in its cells what doesn't fill them sits (alignment). With
    less room than it would like, the grid squeezes its columns and rows towards their minimums,
    which is never smaller than a control in them: controls keep their preferred size.

    Each child fills its cell as far as its max allows, unless its column or row says not to
    (fill). What doesn't fill -- a control, which keeps to its preferred size -- sits at the start
    of its column and in the middle of its row, so a label lines up with the field beside it.

    Children go in with add(child, column, row), not plain add(). They're in the tree in the order
    they were added, which is the order Tab moves through them and a screen reader reads them, so
    add a form's rows in order.
*/
class Grid : CustomLayout
{
public:
    this() nothrow @nogc {}

    /// Space between one column and the next, in points.
    mixin(declareStyleableProperty!(float, "columnGap", "column-gap", "0", q{ childLayoutChanged(); }));

    /// Space between one row and the next, in points.
    mixin(declareStyleableProperty!(float, "rowGap", "row-gap", "0", q{ childLayoutChanged(); }));

    /// Puts `child` in `column` and `row`, spanning `columnSpan` columns and `rowSpan` rows from
    /// there, or moves it there if it's in the grid already. Returns this, so calls chain.
    final Grid add(Widget child, int column, int row, int columnSpan = 1, int rowSpan = 1)
    {
        if (column < 0 || row < 0 || columnSpan < 1 || rowSpan < 1)
            throw new Exception("a grid cell is at a column and row from 0, spanning at least one of each");
        auto cell = Cell(child, column, row, columnSpan, rowSpan);
        if (child.parent is this)
        {
            foreach (ref c; _cells)
                if (c.child is child)
                    c = cell;
        }
        else
        {
            if (child.parent)
                child.parent.remove(child);
            _cells ~= cell;
            adopt(child);
        }
        resize();
        relayout();
        return this;
    }

    /// Puts `children` in `row`, one to a column from the first. What forms are made of.
    final Grid addRow(int row, Widget[] children...)
    {
        foreach (i, child; children)
            add(child, cast(int) i, row);
        return this;
    }

    /// Puts `children` in `column`, one to a row from the first.
    final Grid addColumn(int column, Widget[] children...)
    {
        foreach (i, child; children)
            add(child, column, cast(int) i);
        return this;
    }

    /// Column `i`'s settings, to read or change: `grid.column(1).grow(1)`.
    final GridTrack column(int i)
    {
        return track(_columnTracks, i, true);
    }

    /// Row `i`'s settings, to read or change.
    final GridTrack row(int i)
    {
        return track(_rowTracks, i, false);
    }

    /// How many columns and rows there are: as many as the tracks set up, or the cells reach.
    final int columnCount() const nothrow @nogc { return cast(int) _cols.length; }
    final int rowCount() const nothrow @nogc { return cast(int) _rows.length; } /// ditto

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // they go in at a column and row

    override void placeChild(Widget child) nothrow @nogc
    {
        foreach (ref c; _cells)
        {
            if (c.child !is child)
                continue;
            auto col = c.column < _columnTracks.length ? _columnTracks[c.column] : null;
            auto row = c.row < _rowTracks.length ? _rowTracks[c.row] : null;
            const across = col ? col._alignment : Alignment.start;
            const down = row ? row._alignment : Alignment.centre;
            setCell(child, col ? col._fill : true, row ? row._fill : true, pos(across, down));
        }
    }

    override void childRemoved(Widget child)
    {
        foreach (i, ref c; _cells)
        {
            if (c.child is child)
            {
                _cells = _cells[0 .. i] ~ _cells[i + 1 .. $];
                break;
            }
        }
        resize();
    }

    override void measureContent(float width, float height, out float w, out float h) nothrow @nogc
    {
        solve(_cols, true, width);
        solve(_rows, false, height);
        w = total(_cols, _columnGap);
        h = total(_rows, _rowGap);
    }

    override void arrange(float width, float height) nothrow @nogc
    {
        solve(_cols, true, width);
        solve(_rows, false, height);
        foreach (ref c; _cells)
        {
            float x, cw, y, ch;
            span(_cols, _columnGap, c.column, c.columnSpan, x, cw);
            span(_rows, _rowGap, c.row, c.rowSpan, y, ch);
            layoutCell(c.child, x, y, cw, ch);
        }
    }

private:
    struct Cell
    {
        Widget child;
        int column, row, columnSpan, rowSpan;
    }

    // What solving works out for a column or row, kept between frames so the frame needn't allocate
    struct Line
    {
        float min = 0, max = float.infinity, grow = 0;
        float size = 0;
    }

    void trackChanged() { resize(); relayout(); }

    Cell[] _cells;
    GridTrack[] _columnTracks, _rowTracks; // null where a column or row has no settings
    Line[] _cols, _rows;

    GridTrack track(ref GridTrack[] tracks, int i, bool isColumn)
    {
        if (i < 0)
            throw new Exception("columns and rows count from 0");
        if (i >= tracks.length)
            tracks.length = i + 1;
        if (!tracks[i])
            tracks[i] = new GridTrack(this, !isColumn);
        resize();
        return tracks[i];
    }

    /// Makes room for every column and row: called whenever the cells or the tracks change.
    void resize()
    {
        size_t cols = _columnTracks.length, rows = _rowTracks.length;
        foreach (ref c; _cells)
        {
            if (c.column + c.columnSpan > cols) cols = c.column + c.columnSpan;
            if (c.row + c.rowSpan > rows) rows = c.row + c.rowSpan;
        }
        _cols.length = cols;
        _rows.length = rows;
        childLayoutChanged();
    }

    /*
        Works out the columns' widths (`across`) or the rows' heights, to fit `room` if it isn't
        NaN. Rows go after columns, as a row's height depends on how wide its cells are.
    */
    void solve(Line[] lines, bool across, float room) nothrow @nogc
    {
        auto tracks = across ? _columnTracks : _rowTracks;
        const gap = across ? _columnGap : _rowGap;
        foreach (i, ref line; lines)
        {
            line = Line.init;
            if (i < tracks.length && tracks[i])
            {
                line.min = tracks[i]._minSize;
                line.max = tracks[i]._maxSize;
                line.grow = tracks[i]._grow;
            }
        }

        // What the children in one column or row want: the biggest of them. A control can't be
        // squeezed smaller than it wants, so neither can its column or row.
        foreach (ref c; _cells)
        {
            if ((across ? c.columnSpan : c.rowSpan) != 1)
                continue;
            float size, held;
            want(c, across, size, held);
            auto line = &lines[across ? c.column : c.row];
            if (size > line.size) line.size = size;
            if (held > line.min) line.min = held;
        }
        foreach (i, ref line; lines)
        {
            if (i < tracks.length && tracks[i] && tracks[i]._prefSize == tracks[i]._prefSize)
                line.size = tracks[i]._prefSize;
            if (line.size < line.min) line.size = line.min;
            if (line.size > line.max) line.size = line.max;
        }

        // What spans several wants, shared among those it spans if they come to less
        foreach (ref c; _cells)
        {
            const first = across ? c.column : c.row, n = across ? c.columnSpan : c.rowSpan;
            if (n == 1)
                continue;
            float size, held;
            want(c, across, size, held);
            float have = (n - 1) * gap;
            foreach (ref line; lines[first .. first + n])
                have += line.size;
            if (size > have)
                share(lines[first .. first + n], size - have, true);
        }

        if (room == room)
            share(lines, room - total(lines, gap), false);
    }

    /// How big `c`'s child wants to be along the axis being solved, and how much of that it must have.
    void want(ref const Cell c, bool across, out float size, out float held) nothrow @nogc
    {
        float w, h;
        if (across)
        {
            measureCell(cast() c.child, float.nan, w, h);
            size = w;
            held = c.child.widthHeldToPref ? w : 0;
        }
        else
        {
            // At the width its cells came to, so text that wraps is as tall as it will be
            float x, width;
            span(_cols, _columnGap, c.column, c.columnSpan, x, width);
            measureCell(cast() c.child, width, w, h);
            size = h;
            held = c.child.heightHeldToPref ? h : 0;
        }
    }

    /*
        Gives `extra` to `lines`, or takes it from them if it's negative. Room to spare goes to
        those that grow, by how much they grow, as far as their max; or, for something spanning
        them (`evenly`), to all of them alike if none grows. Too little is taken from each by how
        far it is above its min.
    */
    static void share(Line[] lines, float extra, bool evenly) nothrow @nogc
    {
        if (extra > 0)
        {
            bool anyGrow;
            foreach (ref line; lines)
                anyGrow = anyGrow || line.grow > 0;
            if (!anyGrow && !evenly)
                return; // nothing wants it: it's left over, after the last
            // A few passes, as lines that reach their max hand what they can't take to the rest
            foreach (pass; 0 .. lines.length)
            {
                float weights = 0;
                foreach (ref line; lines)
                    if (line.size < line.max)
                        weights += anyGrow ? line.grow : 1;
                if (extra <= 0.001f || weights <= 0)
                    break;
                float left = extra;
                foreach (ref line; lines)
                {
                    if (line.size >= line.max)
                        continue;
                    float give = extra * (anyGrow ? line.grow : 1) / weights;
                    if (line.size + give > line.max)
                        give = line.max - line.size;
                    line.size += give;
                    left -= give;
                }
                extra = left;
            }
        }
        else if (extra < 0)
        {
            float slack = 0;
            foreach (ref line; lines)
                slack += line.size > line.min ? line.size - line.min : 0;
            if (slack <= 0)
                return;
            const take = -extra < slack ? -extra : slack;
            foreach (ref line; lines)
                if (line.size > line.min)
                    line.size -= take * (line.size - line.min) / slack;
        }
    }

    static float total(const Line[] lines, float gap) nothrow @nogc
    {
        float sum = lines.length > 1 ? (lines.length - 1) * gap : 0;
        foreach (ref line; lines)
            sum += line.size;
        return sum;
    }

    /// Where `n` lines from `first` start, and how far they reach, gaps between them included.
    static void span(const Line[] lines, float gap, int first, int n, out float start, out float size) nothrow @nogc
    {
        start = 0;
        foreach (ref line; lines[0 .. first])
            start += line.size + gap;
        size = (n - 1) * gap;
        foreach (ref line; lines[first .. first + n])
            size += line.size;
    }

    static Pos pos(Alignment across, Alignment down) nothrow @nogc
    {
        static immutable Pos[3][3] table = [
            [Pos.topLeft, Pos.topCentre, Pos.topRight],
            [Pos.centreLeft, Pos.centre, Pos.centreRight],
            [Pos.bottomLeft, Pos.bottomCentre, Pos.bottomRight],
        ];
        return table[down][across];
    }
}

/// Where in its cell something that doesn't fill it sits, along a column or down a row.
enum Alignment { start, centre, end }

/*
    One column's or row's settings, from Grid.column() or Grid.row(). Each returns the track, so
    they chain: `grid.column(0).minSize(120).alignment(Alignment.end)`.
*/
final class GridTrack
{
public:
    float minSize() const nothrow @nogc { return _minSize; }
    /// The least it's squeezed to: 0 by default, or what a control in it needs.
    GridTrack minSize(float v) { _minSize = v; return changed(); }

    float prefSize() const nothrow @nogc { return _prefSize; }
    /// The size it is, rather than what its children want, if not NaN; within min and max still.
    GridTrack prefSize(float v) { _prefSize = v; return changed(); }

    float maxSize() const nothrow @nogc { return _maxSize; }
    /// The most it grows to.
    GridTrack maxSize(float v) { _maxSize = v; return changed(); }

    float grow() const nothrow @nogc { return _grow; }
    /// Its share of any room to spare, against the others': 0 for none, the default.
    GridTrack grow(float v) { _grow = v; return changed(); }

    Alignment alignment() const nothrow @nogc { return _alignment; }
    /// Where what doesn't fill its cells sits: a column's start and a row's centre by default.
    GridTrack alignment(Alignment v) { _alignment = v; return changed(); }

    bool fill() const nothrow @nogc { return _fill; }
    /// Whether what's in it fills its cells, as far as its max allows. On by default.
    GridTrack fill(bool v) { _fill = v; return changed(); }

private:
    Grid _grid;
    float _minSize = 0, _prefSize = float.nan, _maxSize = float.infinity, _grow = 0;
    Alignment _alignment;
    bool _fill = true;

    this(Grid grid, bool isRow)
    {
        _grid = grid;
        _alignment = isRow ? Alignment.centre : Alignment.start;
    }

    GridTrack changed()
    {
        _grid.trackChanged();
        return this;
    }
}
