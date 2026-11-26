module mayfair.widgets.splitpane;

import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.input;
import mayfair.widgets.layouts;
import mayfair.widgets.slider : Orientation;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    Its children side by side, or one above another, with a divider between each two that's
    dragged to share the room out between them: JavaFX's SplitPane. A file tree, an editor and a
    preview, each as wide as it's dragged to be.

        auto split = new SplitPane();
        split.add(files, keepSize: true).add(editor).add(preview);
        split.setDividerPositions([0.2, 0.6]);

        <SplitPane dividerPositions="0.2 0.6">
            <TreeView of="Entry" SplitPane.keepSize="true"/>
            <TextView/>
            <PdfView/>
        </SplitPane>

    Where each divider is, dividerPositions says, as JavaFX's does: a fraction of the way across,
    from 0 to 1, one for each divider in order. Without them the children share the room evenly.
    Dragging a divider changes them, and they can be listened to, to save them for next time.

    A child doesn't go smaller than its min-width (min-height, one above another), so a divider
    stops where it would squeeze one. A child added with keepSize keeps its size as the split
    pane's is changed, as a sidebar does when the window's made wider; the others share what's
    gained or lost, in proportion. JavaFX's setResizableWithParent(child, false).

    A child that's hidden (setVisible(false)) takes no room, nor does the divider beside it: the
    others share its room in the proportions they had, and get it back when it's shown again.

    Each divider is a widget of its own, a `.divider` in the split pane, `divider-width` thick, so
    a theme draws it as it likes: Mayfair's draws a line down its middle, with room either side to
    take hold of. It's :horizontal or :vertical, as the split pane is, and :dragged while it is.
*/
class SplitPane : CustomLayout
{
public:
    this(Orientation orientation = Orientation.horizontal)
    {
        styleClass.add("split-pane");
        _orientation = orientation;
        orientationChanged();
    }

    /// Side by side (horizontal), or one above another (vertical).
    mixin(declareProperty!(Orientation, "orientation", "Orientation.horizontal", q{ orientationChanged(); }));

    /// Where each divider is, from 0 at the start to 1 at the end: one for each divider, in order.
    /// Dragging a divider sets them; so does a pane that keeps its size, as the room changes,
    /// without telling listeners.
    mixin(declareProperty!(float[], "dividerPositions", "null", q{ fillPositions(); childLayoutChanged(); }));

    /// How thick each divider is, in points: the room taken between two children, and taken hold of.
    mixin(declareStyleableProperty!(float, "dividerWidth", "divider-width", "5", q{ childLayoutChanged(); }));

    alias add = Widget.add;

    /// Adds `child` at the end; with `keepSize`, it keeps its size as the split pane's changes.
    final SplitPane add(Widget child, bool keepSize)
    {
        Widget.add(child);
        setKeepSize(child, keepSize);
        return this;
    }

    /// Whether `child` keeps its size as the split pane's changes: see the top.
    final void setKeepSize(Widget child, bool keep)
    {
        foreach (ref p; _panes)
            if (p.child is child)
                p.keepSize = keep;
    }

    /// The children it shares its room between, in order: its children less its dividers.
    final Widget[] panes()
    {
        Widget[] list;
        foreach (p; _panes)
            list ~= p.child;
        return list;
    }

protected:
    override void placeChild(Widget child) nothrow @nogc
    {
        setCell(child, true, true, Pos.topLeft);
    }

    // A child added: a divider goes before it, if there's one before; a child taken away takes its
    // divider with it. Dividers are children too, in among the others, so they're drawn and hit as
    // any widget is, but they're not panes.
    override void childAdded(Widget child)
    {
        if (cast(Divider) child || adding)
            return;
        adding = true;
        scope (exit) adding = false;
        if (_panes.length)
        {
            auto d = new Divider(this);
            d.horizontal = _orientation == Orientation.horizontal;
            adopt(d, childIndex(child));
            _panes[$ - 1].after = d;
        }
        _panes ~= Pane(child);
        fillPositions();
    }

    override void childRemoved(Widget child)
    {
        if (cast(Divider) child || removing)
            return;
        foreach (i, ref p; _panes)
            if (p.child is child)
            {
                removing = true;
                scope (exit) removing = false;
                // Its divider: the one after it, or for the last, the one before
                Divider gone = p.after;
                if (!gone && i > 0)
                {
                    gone = _panes[i - 1].after;
                    _panes[i - 1].after = null;
                }
                if (gone)
                    remove(gone);
                _panes = _panes[0 .. i] ~ _panes[i + 1 .. $];
                return;
            }
    }

    override void measureContent(float width, float height, out float w, out float h) nothrow @nogc
    {
        const across = _orientation == Orientation.horizontal;
        float along = 0, thick = 0;
        int shown;
        foreach (ref p; _panes)
        {
            if (!showing(p.child))
                continue;
            float cw, ch;
            measureCell(p.child, across ? float.nan : width, cw, ch);
            along += across ? cw : ch;
            const t = across ? ch : cw;
            if (t > thick)
                thick = t;
            shown++;
        }
        if (shown > 1)
            along += (shown - 1) * _dividerWidth;
        w = across ? along : thick;
        h = across ? thick : along;
    }

    override void arrange(float width, float height) nothrow @nogc
    {
        const across = _orientation == Orientation.horizontal;
        const total = across ? width : height, thick = across ? height : width;
        sizes(total < 0 ? 0 : total);

        float at = 0;
        Divider pending; // the divider after the last child shown, placed once there's another
        foreach (ref p; _panes)
        {
            if (!showing(p.child))
            {
                if (p.after)
                    hide(p.after);
                continue;
            }
            if (pending)
            {
                place(pending, at, 0, _dividerWidth, thick, across);
                at += _dividerWidth;
            }
            place(p.child, at, 0, p.size, thick, across);
            at += p.size;
            pending = p.after;
        }
        if (pending)
            hide(pending); // after the last shown: nothing to divide from
    }

private:
    struct Pane
    {
        Widget child;
        Divider after;   // the divider between it and the next
        bool keepSize;
        float whole = 0; // in points along, were every pane shown
        float size = 0;  // in points along, as it's shown
    }
    Pane[] _panes;
    float arrangedWhole = float.nan; // the room every pane would have, as it was last arranged
    bool adding, removing;

    /*
        Each pane's size. The positions are of the panes all shown, so first their sizes as they'd
        be then (`whole`) -- with a pane keeping its size keeping it, if the room's changed since
        -- and then as they are: a hidden pane's room going to the shown panes that don't keep their
        size, and none smaller than its minimum.
    */
    void sizes(float total) nothrow @nogc
    {
        const n = _panes.length;
        if (!n)
            return;
        int shown;
        foreach (ref p; _panes)
            if (showing(p.child))
                shown++;
        float whole = total - (n - 1) * _dividerWidth;
        float room = total - (shown > 1 ? shown - 1 : 0) * _dividerWidth;
        if (whole < 0) whole = 0;
        if (room < 0) room = 0;

        foreach (i, ref p; _panes)
            p.whole = share(i) * whole;

        // The room changed: a pane keeping its size has what it had, the rest share the difference
        if (arrangedWhole == arrangedWhole && arrangedWhole != whole && keepsAny)
        {
            float kept = 0, rest = 0;
            foreach (i, ref p; _panes)
            {
                if (p.keepSize)
                    kept += share(i) * arrangedWhole;
                else
                    rest += p.whole;
            }
            if (kept < whole && rest > 0)
            {
                const scale = (whole - kept) / rest;
                foreach (i, ref p; _panes)
                    p.whole = p.keepSize ? share(i) * arrangedWhole : p.whole * scale;
                positionsFrom(whole);
            }
        }
        arrangedWhole = whole;

        // As shown: a hidden pane's room to the shown ones that don't keep their size, or, if they
        // all do, to them all
        float shownWhole = 0, growing = 0;
        foreach (ref p; _panes)
            if (showing(p.child))
            {
                shownWhole += p.whole;
                if (!p.keepSize)
                    growing += p.whole;
            }
        const spare = room - shownWhole;
        foreach (ref p; _panes)
        {
            if (!showing(p.child))
                p.size = 0;
            else if (growing > 0)
                p.size = p.keepSize ? p.whole : p.whole + spare * p.whole / growing;
            else
                p.size = shownWhole > 0 ? p.whole * room / shownWhole : 0;
        }

        // None smaller than its minimum, the room taken from the others
        foreach (i, ref p; _panes)
        {
            if (!showing(p.child))
                continue;
            const least = minimum(p.child);
            if (p.size >= least)
                continue;
            float need = least - p.size;
            p.size = least;
            foreach (j; 0 .. n)
            {
                if (j == i || !showing(_panes[j].child))
                    continue;
                const left = _panes[j].size - minimum(_panes[j].child);
                if (left <= 0)
                    continue;
                const take = left < need ? left : need;
                _panes[j].size -= take;
                need -= take;
                if (need <= 0)
                    break;
            }
        }
    }

    // The share of the whole between pane i's dividers, from the positions (even, without them)
    float share(size_t i) const nothrow @nogc
    {
        const n = _panes.length;
        float position(size_t d) const nothrow @nogc // divider d: between pane d and d + 1
        {
            if (d < _dividerPositions.length)
            {
                const v = _dividerPositions[d];
                return v < 0 ? 0 : v > 1 ? 1 : v;
            }
            return (d + 1) / cast(float) n;
        }
        const start = i == 0 ? 0 : position(i - 1);
        const end = i + 1 >= n ? 1 : position(i);
        return end > start ? end - start : 0;
    }

    bool keepsAny() const nothrow @nogc
    {
        foreach (ref p; _panes)
            if (p.keepSize)
                return true;
        return false;
    }

    // The positions, from the panes' sizes all shown (`whole`), out of `whole` points, into
    // `positions`: in place as it's arranged, as there's one for every divider (see fillPositions)
    void positionsFrom(float whole) nothrow @nogc
    {
        positionsInto(whole, _dividerPositions);
    }

    void positionsInto(float whole, float[] positions) nothrow @nogc
    {
        const n = _panes.length;
        if (n < 2 || whole <= 0 || positions.length < n - 1)
            return;
        float at = 0;
        foreach (d; 0 .. n - 1)
        {
            at += _panes[d].whole;
            positions[d] = at / whole;
        }
    }

    // A position for every divider: those given kept, and those after shared out evenly from the
    // last given to the end. Never shortened, so positions given before the children are added --
    // as a view's attributes are -- stay for them.
    void fillPositions()
    {
        const n = _panes.length;
        if (n < 2 || _dividerPositions.length >= n - 1)
            return;
        const given = _dividerPositions.length;
        auto filled = _dividerPositions.dup;
        filled.length = n - 1;
        const from = given ? _dividerPositions[given - 1] : 0;
        foreach (d; given .. n - 1)
            filled[d] = from + (1 - from) * (d - given + 1) / cast(float)(n - given);
        _dividerPositions = filled;
    }

    // Divider `d` dragged so that it starts `to` points along
    void drag(Divider d, float to)
    {
        foreach (i, ref p; _panes)
        {
            if (p.after !is d)
                continue;
            // The panes either side that are shown
            const size_t before = i;
            size_t after = i + 1;
            while (after < _panes.length && !showing(_panes[after].child))
                after++;
            if (after >= _panes.length || !showing(_panes[before].child))
                return;
            float start = 0;
            foreach (j; 0 .. before)
                if (showing(_panes[j].child))
                    start += _panes[j].size + _dividerWidth;
            auto a = &_panes[before], b = &_panes[after];
            const both = a.size + b.size;
            float first = to - start;
            const leastFirst = minimum(a.child), leastSecond = minimum(b.child);
            if (first > both - leastSecond)
                first = both - leastSecond;
            if (first < leastFirst)
                first = leastFirst;
            const moved = first - a.size;
            if (moved == 0)
                return;
            // The same points moved between the two all shown, so the positions say where it is
            a.whole += moved;
            b.whole -= moved;
            auto positions = _dividerPositions.dup; // a new array, for listeners to hear a change
            positionsInto(arrangedWhole, positions);
            setDividerPositions(positions);
            return;
        }
    }

    void place(Widget w, float at, float across, float length, float thick, bool horizontal) nothrow @nogc
    {
        if (horizontal)
            layoutCell(w, at, across, length, thick);
        else
            layoutCell(w, across, at, thick, length);
    }

    void hide(Widget w) nothrow @nogc
    {
        layoutCell(w, 0, 0, 0, 0);
    }

    float minimum(Widget child) const nothrow @nogc
    {
        const m = _orientation == Orientation.horizontal ? child.minWidth : child.minHeight;
        return m == m && m > 0 ? m : 0;
    }

    static bool showing(Widget child) nothrow @nogc
    {
        return YGNodeStyleGetDisplay(child.node) != YGDisplayNone;
    }

    size_t childIndex(Widget child) nothrow @nogc
    {
        foreach (i, c; children)
            if (c is child)
                return i;
        return children.length;
    }

    void orientationChanged()
    {
        const horizontal = _orientation == Orientation.horizontal;
        pseudoClassStateChanged(pseudo!"horizontal", horizontal);
        pseudoClassStateChanged(pseudo!"vertical", !horizontal);
        foreach (p; _panes)
            if (p.after)
                p.after.horizontal = horizontal;
        childLayoutChanged();
    }
}

/// One of a SplitPane's dividers: taken hold of and dragged.
private final class Divider : Widget
{
    this(SplitPane pane)
    {
        this.pane = pane;
        styleClass.add("divider");
        setAccessibleHidden(true);
    }

    void horizontal(bool across)
    {
        pseudoClassStateChanged(pseudo!"horizontal", across);
        pseudoClassStateChanged(pseudo!"vertical", !across);
        setCursor(across ? Cursor.resizeHorizontal : Cursor.resizeVertical);
        this.across = across;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void handleMouse(ref MouseEvent event)
    {
        switch (event.type)
        {
            case MouseEventType.pressed:
                if (event.button != MouseButton.primary)
                    break;
                grab = across ? event.x : event.y; // where along it it's held
                dragging = true;
                pseudoClassStateChanged(pseudo!"dragged", true);
                event.consume();
                break;
            case MouseEventType.dragged:
                if (!dragging)
                    break;
                // Where the divider's start is to be, from the split pane's content's start
                const b = pane.boundsInScene;
                const start = across ? b.minX + YGNodeLayoutGetPadding(pane.node, YGEdgeLeft)
                                     : b.minY + YGNodeLayoutGetPadding(pane.node, YGEdgeTop);
                pane.drag(this, (across ? event.sceneX : event.sceneY) - start - grab);
                event.consume();
                break;
            case MouseEventType.released:
                if (!dragging)
                    break;
                dragging = false;
                pseudoClassStateChanged(pseudo!"dragged", false);
                event.consume();
                break;
            default:
                break;
        }
    }

private:
    SplitPane pane;
    bool across = true, dragging;
    float grab = 0;
}
