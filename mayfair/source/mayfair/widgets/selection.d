module mayfair.widgets.selection;

import mayfair.widgets.input;

/// Whether a list or table lets one row be selected at a time, or any number. JavaFX's SelectionMode.
enum SelectionMode { single, multiple }

/*
    Which rows of a list or table are selected, and which row the keys are on: JavaFX's
    MultipleSelectionModel and FocusModel in one, shared by ListView and TableView. Rows are
    counted as they're shown, from the top.

    With one row at a time, a click or a key selects the row it goes to. With any number, it's as
    a file manager does:

    - a click selects that row alone; Ctrl+click adds it, or takes it away if it was selected
    - Shift+click selects from the anchor -- the last row clicked without Shift -- to this one, in
      place of what was; Ctrl+Shift+click adds that range to it
    - Up and Down, Page Up and Page Down, Home and End select the row they move to alone; with
      Shift, from the anchor to there; with Ctrl, they move the current row without selecting, and
      Ctrl+Space then adds it or takes it away
    - Ctrl+A selects every row

    The current row is the one the keys are on, which the view marks while it has focus, and
    which Enter activates.
*/
package struct Selection
{
    SelectionMode mode;
    int current = -1; // the row the keys are on
    int anchor = -1;  // where Shift's ranges run from
    int lead = -1;    // the row selected last: the view's selectedIndex
    uint changes;     // counts every change to which rows are selected, for the view to notice one

    /// Whether `row` is selected.
    bool isSelected(int row) const nothrow @nogc
    {
        return row >= 0 && row < rows.length && rows[row];
    }

    /// How many rows are selected.
    size_t count() const nothrow @nogc { return selectedCount; }

    /// The selected rows, from the top.
    int[] indices() const
    {
        int[] all;
        all.reserve(selectedCount);
        foreach (i, on; rows)
            if (on)
                all ~= cast(int) i;
        return all;
    }

    /// How many rows there are now. Selected rows past the end go.
    void resize(size_t n)
    {
        if (n < rows.length)
            foreach (on; rows[n .. $])
                if (on)
                {
                    selectedCount--;
                    changes++;
                }
        rows.length = n;
        const last = cast(int) n - 1;
        if (current > last) current = last;
        if (anchor > last) anchor = last;
        fixLead();
    }

    /// Selects nothing.
    void clear()
    {
        if (selectedCount)
            changes++;
        rows[] = false;
        selectedCount = 0;
        lead = -1;
    }

    /// Selects `row` and nothing else, and puts the keys and the anchor there.
    void selectOnly(int row)
    {
        if (row < 0 || row >= rows.length)
            return clear();
        if (!(selectedCount == 1 && rows[row]))
        {
            clear();
            set(row, true);
        }
        current = anchor = lead = row;
    }

    /// Adds `row` to what's selected -- or, one at a time, selects it alone.
    void select(int row)
    {
        if (mode == SelectionMode.single)
            return selectOnly(row);
        if (row < 0 || row >= rows.length)
            return;
        set(row, true);
        current = anchor = lead = row;
    }

    /// Takes `row` out of what's selected.
    void deselect(int row)
    {
        if (row < 0 || row >= rows.length)
            return;
        set(row, false);
        fixLead();
    }

    /// Selects `from` to `to`, either way round, adding them to what's selected if `add`, or in its
    /// place. The keys go to `to`; the anchor stays. One at a time, `to` alone.
    void selectRange(int from, int to, bool add = false)
    {
        if (mode == SelectionMode.single)
            return selectOnly(to);
        if (to < 0 || to >= rows.length)
            return;
        if (from < 0 || from >= rows.length)
            from = to;
        if (!add)
            clear();
        foreach (i; (from < to ? from : to) .. (from < to ? to : from) + 1)
            set(i, true);
        current = lead = to;
    }

    /// Selects every row, if any number can be.
    void selectAll()
    {
        if (mode == SelectionMode.single)
            return;
        foreach (i; 0 .. cast(int) rows.length)
            set(i, true);
        if (lead < 0 && rows.length)
            lead = current >= 0 ? current : 0;
    }

    /*
        The rows put in a new order, and there being `n` of them now: row `r` is row `moved[r]`, or
        gone if that's -1. What was selected stays selected where it's gone to, and so on.
    */
    void reorder(const(int)[] moved, size_t n)
    {
        auto was = rows;
        const before = selectedCount;
        rows = new bool[n];
        selectedCount = 0;
        foreach (r, on; was)
            if (on && r < moved.length && moved[r] >= 0 && moved[r] < n)
            {
                rows[moved[r]] = true;
                selectedCount++;
            }
        int to(int r) { return r >= 0 && r < moved.length && moved[r] < n ? moved[r] : -1; }
        current = to(current);
        anchor = to(anchor);
        lead = to(lead);
        if (selectedCount != before)
            changes++;
        fixLead();
    }

    /// One at a time from now, if `mode` says so: the lead stays selected, and the rest go.
    void setMode(SelectionMode m)
    {
        mode = m;
        if (m == SelectionMode.single && selectedCount > 1)
        {
            const keep = lead;
            clear();
            if (keep >= 0)
                selectOnly(keep);
        }
    }

    /// A primary press on `row`, with those modifiers held.
    void press(int row, bool shift, bool control)
    {
        if (mode == SelectionMode.single || (!shift && !control))
            return selectOnly(row);
        if (shift)
            return selectRange(anchor, row, control);
        // Ctrl alone: this one in or out, and it's where ranges run from next
        if (isSelected(row))
        {
            set(row, false);
            fixLead();
        }
        else
        {
            set(row, true);
            lead = row;
        }
        current = anchor = row;
    }

    /*
        A key pressed, with `n` rows and `page` rows to a page. Whether it was one of the
        selection's keys, having moved the selection, or the keys, as it says.
    */
    bool key(ref const KeyEvent event, int page)
    {
        const n = cast(int) rows.length;
        if (!n)
            return false;
        const multiple = mode == SelectionMode.multiple;
        if (multiple && event.control && !event.shift && !event.alt && event.code == KeyCode.a)
        {
            selectAll();
            return true;
        }
        if (multiple && event.control && event.code == KeyCode.space)
        {
            if (current < 0)
                current = 0;
            press(current, false, true);
            return true;
        }
        const at = current;
        int to;
        switch (event.code)
        {
            case KeyCode.down:     to = at < 0 ? 0 : at + 1; break;
            case KeyCode.up:       to = at < 0 ? 0 : at - 1; break;
            case KeyCode.pageDown: to = at + (page > 1 ? page : 1); break;
            case KeyCode.pageUp:   to = at - (page > 1 ? page : 1); break;
            case KeyCode.home:     to = 0; break;
            case KeyCode.end:      to = n - 1; break;
            default: return false;
        }
        to = to < 0 ? 0 : to >= n ? n - 1 : to;
        if (multiple && event.control && !event.shift)
            current = to; // only the keys move
        else if (multiple && event.shift)
            selectRange(anchor, to, event.control);
        else
            selectOnly(to);
        return true;
    }

private:
    bool[] rows;          // one for each row: whether it's selected
    size_t selectedCount;

    void set(int row, bool on)
    {
        if (rows[row] == on)
            return;
        rows[row] = on;
        if (on)
            selectedCount++;
        else
            selectedCount--;
        changes++;
    }

    /// The lead is a selected row, if there is one: the current row, or else the first.
    void fixLead()
    {
        if (isSelected(lead))
            return;
        lead = -1;
        if (!selectedCount)
            return;
        if (isSelected(current))
            lead = current;
        else
            foreach (i, on; rows)
                if (on)
                {
                    lead = cast(int) i;
                    break;
                }
    }
}

unittest
{
    Selection s;
    s.resize(10);
    s.press(2, false, false);
    assert(s.indices == [2] && s.lead == 2);

    // One at a time, the modifiers change nothing
    s.press(5, true, true);
    assert(s.indices == [5]);

    s.setMode(SelectionMode.multiple);
    s.press(3, false, true);            // Ctrl+click adds
    assert(s.indices == [3, 5] && s.anchor == 3);
    s.press(6, true, false);            // Shift+click: from the anchor, in place of what was
    assert(s.indices == [3, 4, 5, 6] && s.lead == 6 && s.anchor == 3);
    s.press(9, false, true);
    s.press(8, true, true);             // Ctrl+Shift: added
    assert(s.indices == [3, 4, 5, 6, 8, 9]);
    s.press(4, false, true);            // Ctrl+click on a selected row takes it out
    assert(!s.isSelected(4) && s.count == 5);

    // The keys
    KeyEvent e;
    e.type = KeyEventType.pressed;
    s.selectOnly(1);
    e.code = KeyCode.down;
    e.shift = true;
    s.key(e, 5);
    s.key(e, 5);
    assert(s.indices == [1, 2, 3] && s.current == 3);
    e.shift = false;
    e.control = true;
    s.key(e, 5);                         // Ctrl+Down: only the keys move
    assert(s.indices == [1, 2, 3] && s.current == 4);
    e.code = KeyCode.space;
    s.key(e, 5);                         // Ctrl+Space adds the current row
    assert(s.indices == [1, 2, 3, 4]);
    e.code = KeyCode.a;
    s.key(e, 5);
    assert(s.count == 10, "Ctrl+A");

    // Fewer rows: those past the end go
    const before = s.changes;
    s.resize(4);
    assert(s.count == 4 && s.changes > before && s.current == 3);

    // Put in another order: the selection goes with its rows
    s.selectOnly(0);
    s.select(2);
    s.reorder([2, 1, 0, -1], 3);
    assert(s.indices == [0, 2] && s.lead == 0 && s.current == 0);

    s.setMode(SelectionMode.single);
    assert(s.count == 1);
}
