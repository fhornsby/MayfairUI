module mayfair.widgets.tableview;

import std.algorithm.mutation : SwapStrategy;
import std.array : join;
import std.algorithm.sorting : sort;
import std.conv : to, ConvException;
import std.uni : icmp;
import mayfair.accessibility;
import mayfair.clipboard;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.buttonbase;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.menu;
import mayfair.widgets.popup : Popup;
import mayfair.widgets.scrollpane;
import mayfair.widgets.selection;
import mayfair.widgets.styling;
import mayfair.widgets.virtualflow;
import mayfair.widgets.widget;

/*
    Items in rows, a column for each thing about them, with a header to sort and size the columns
    by. JavaFX's TableView.

        auto people = new TableView!Person(everyone);
        people.add(new TableColumn!Person("Name", (Person p) => p.name))
              .add(new TableColumn!Person("Age", (Person p) => p.age.to!string).alignment(Alignment.end))
              .add(new TableColumn!Person("City", (Person p) => p.city));

    Clicking a column's header sorts by it, again sorts the other way, and a third time puts the
    items back in their own order. Sorting compares what the cells say -- as numbers, where both
    are -- unless the column has a comparator of its own, and it's stable, so what's equal keeps
    its order. The selection stays with its items. Dragging a header's right edge sizes its
    column; the last column takes any room to spare.

    As with a ListView, only the rows in view are made, however many items there are. Selecting,
    the keys and activating are as a list's, and so is selecting any number of rows at once, when
    selectionMode says it can.

    Ctrl+C copies the selected rows, as tab-separated text a spreadsheet takes, a line a row, and
    so does Copy on a right click, which selects the row it's on first if it isn't already. With
    selectableText -- or a column's selectable -- the cells' text can be selected as a
    selectable Label's can: a drag across a cell selects in it, Ctrl+C and the right click then
    copy that, and a click still selects the row.

    Its style class is "table-view". The header is a `.column-header-background` of
    `.column-header`s, :sorted for the one sorted by; each row is a `.table-row` -- :selected,
    :current for the one the keys are on, and :odd for striping -- of `.table-cell`s. To a screen reader it's a table.
*/
class TableView(S) : Widget
{
public:
    this(S[] items = null)
    {
        styleClass.add("table-view");
        setAccessibleRole(AccessibleRole.table);
        setFocusTraversable(true);
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);

        _header = new HeaderStrip();
        _headerRow = new Row().fillHeight(true);
        _headerRow.setAccessibleRole(AccessibleRole.row);
        _header.add(_headerRow);
        adopt(_header);

        _flow = new VirtualFlow(&makeRow, &bindRow);
        _flow.onViewportChanged = &applyWidths;
        _pane = new ScrollPane(_flow);
        _pane.setAccessibleHidden(true);
        _flow.pane = _pane;
        _pane.vvalueProperty.addListener((float was, float now) { _flow.refresh(); });
        // The header moves sideways with the rows, and stays where it is down
        _pane.hvalueProperty.addListener((float was, float now) { _header.scrollTo(_pane.viewportBounds.minX); });
        _empty = new Label("No items");
        _empty.styleClass.add("placeholder");
        _empty.setAccessibleHidden(true);
        _body = new Stack();
        _body.add(_pane).add(_empty);
        _body.setGrow(1);
        adopt(_body);
        setItems(items);
    }

    /// What it shows, a row each.
    mixin(declarePropertyOf!(S[], "S[]", "items", "null", q{ itemsChanged(); }));

    /// Which row is selected, from the top as it's sorted; -1 for none. With several selected, the
    /// one selected last. Setting it selects that row alone.
    mixin(declareProperty!(int, "selectedIndex", "-1", q{ selectedIndexSet(); }));

    /// Whether one row can be selected at a time, or any number.
    mixin(declareProperty!(SelectionMode, "selectionMode", "SelectionMode.single", q{
        _selection.setMode(_selectionMode);
        selectionUpdated();
        invalidateAccessible();
    }));

    /// Whether every column's cells' text can be selected and copied. A column can be made so on its own.
    mixin(declareProperty!(bool, "selectableText", "false", q{ applySelectable(); }));

    /// What it says when it has no items.
    mixin(declareProperty!(string, "placeholder", `"No items"`, q{ _empty.setText(_placeholder); }));

    /// Adds a column at the right. Returns this, so calls chain.
    final TableView add(TableColumn!S column)
    {
        column._table = this;
        _columns ~= column;
        auto header = new ColumnHeader(this, column);
        column._header = header;
        _headerRow.add(header);
        columnsChanged();
        return this;
    }

    /// The columns, left to right.
    final TableColumn!S[] columns() nothrow @nogc { return _columns; }

    /// The item in the selected row, or S.init.
    final S selectedItem()
    {
        return _selectedIndex >= 0 && _selectedIndex < _order.length ? _items[_order[_selectedIndex]] : S.init;
    }

    /// The item shown in row `row`, as it's sorted.
    final S itemAt(int row) { return _items[_order[row]]; }

    /// Which rows are selected, from the top as it's sorted.
    final int[] selectedIndices() const { return _selection.indices; }

    /// The items in the rows selected, from the top.
    final S[] selectedItems()
    {
        S[] all;
        foreach (row; _selection.indices)
            all ~= _items[_order[row]];
        return all;
    }

    /// Whether row `row` is selected.
    final bool isSelected(int row) const nothrow @nogc { return _selection.isSelected(row); }

    /// Adds row `row` to what's selected -- or, one at a time, selects it alone.
    final void select(int row) { _selection.select(row); selectionUpdated(); }

    /// Takes row `row` out of what's selected.
    final void deselect(int row) { _selection.deselect(row); selectionUpdated(); }

    /// Adds rows `from` to `to` to what's selected, either way round.
    final void selectRange(int from, int to) { _selection.selectRange(from, to, true); selectionUpdated(); }

    /// Selects every row, if any number can be.
    final void selectAll() { _selection.selectAll(); selectionUpdated(); }

    /// Selects nothing.
    final void clearSelection() { _selection.clear(); selectionUpdated(); }

    /// What to do when what's selected changes, however it did. Sorting doesn't change it.
    final TableView onSelectionChanged(void delegate() handler) nothrow @nogc
    {
        _onSelectionChanged = handler;
        return this;
    }

    /// The column it's sorted by, or null for the items' own order.
    final TableColumn!S sortColumn() nothrow @nogc { return _sortColumn; }

    /// Whether it's sorted smallest first.
    final bool sortAscending() const nothrow @nogc { return _ascending; }

    /// Sorts by `column`, smallest first if `ascending`; null for the items' own order.
    final void sortBy(TableColumn!S column, bool ascending = true)
    {
        _sortColumn = column;
        _ascending = ascending;
        foreach (c; _columns)
            c._header.showSort(c is column, ascending);
        resort();
    }

    /// What to do when a row's activated: double clicked, or Enter on it. It's given
    /// the item's index in `items`.
    final TableView onActivate(void delegate(int item) handler) nothrow @nogc
    {
        _onActivate = handler;
        return this;
    }

    /// Scrolls so row `row` is in view.
    final void scrollTo(int row)
    {
        if (row >= 0)
            _flow.reveal(row);
    }

    /// Copies the selected rows to the clipboard: each row's cells, tab-separated, a line a row.
    final void copy()
    {
        string[] lines;
        foreach (row; _selection.indices)
        {
            string[] cells;
            foreach (c; _columns)
                cells ~= c._text(_items[_order[row]]);
            lines ~= cells.join("\t");
        }
        if (lines.length)
            Clipboard.text = lines.join("\n");
    }

    /// Shows every row in view again, for items whose insides changed.
    final void refresh()
    {
        resort();
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || !_order.length)
            return;
        if (event.code == KeyCode.c && event.control)
        {
            copy();
            event.consume();
            return;
        }
        if (event.code == KeyCode.enter || event.code == KeyCode.numpadEnter)
        {
            if (_selection.current >= 0 && _onActivate)
                _onActivate(cast(int) _order[_selection.current]);
            event.consume();
            return;
        }
        const page = _flow.rowHeight > 0 ? cast(int)(_pane.viewportBounds.height / _flow.rowHeight) - 1 : 10;
        if (!_selection.key(event, page))
            return;
        selectionUpdated();
        scrollTo(_selection.current);
        event.consume();
    }

    override void handleMouse(ref MouseEvent event)
    {
        if (event.type != MouseEventType.pressed)
            return;
        if (event.button != MouseButton.primary && event.button != MouseButton.secondary)
            return;
        // A selectable cell pressed took focus, to select in; otherwise the table has it
        auto focus = scene ? scene.focusedWidget : null;
        bool cellFocused;
        for (Widget w = event.target; w && w !is this; w = w.parent)
            cellFocused = cellFocused || (w is focus);
        for (Widget w = event.target; w && w !is this; w = w.parent)
        {
            if (auto row = cast(TableRow) w)
            {
                const i = _flow.indexOf(row);
                if (i == size_t.max)
                    break;
                if (!cellFocused)
                    requestFocus();
                if (event.button == MouseButton.secondary)
                {
                    // The menu's for the selected rows: this one, unless it's one of them
                    if (!_selection.isSelected(cast(int) i))
                    {
                        _selection.selectOnly(cast(int) i);
                        selectionUpdated();
                    }
                    break;
                }
                _selection.press(cast(int) i, event.shift, event.control);
                selectionUpdated();
                if (event.clickCount == 2 && _onActivate)
                    _onActivate(cast(int) _order[i]);
                event.consume();
                break;
            }
        }
    }

    override Popup defaultContextMenu()
    {
        auto menu = new ContextMenu()
            .add(new MenuItem("Copy", { copy(); }).accelerator("Ctrl+C").disable(_selection.count == 0));
        if (_selectionMode == SelectionMode.multiple)
            menu.add(new MenuItem("Select All", { selectAll(); }).accelerator("Ctrl+A")
                     .disable(_selection.count == _order.length));
        return menu;
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.rowCount(_order.length + 1); // the header's a row too
        node.columnCount(_columns.length);
        if (_selectionMode == SelectionMode.multiple)
            node.multiselectable();
    }

private:
    HeaderStrip _header;
    Row _headerRow;
    VirtualFlow _flow;
    ScrollPane _pane;
    Stack _body;
    Label _empty;
    TableColumn!S[] _columns;
    TableColumn!S _sortColumn;
    bool _ascending = true;
    size_t[] _order;          // the index in `items` of each row, as sorted
    void delegate(int) _onActivate;
    void delegate() _onSelectionChanged;
    Selection _selection;     // by row, as sorted
    uint _shownChanges;       // the selection's changes, as far as onSelectionChanged has heard
    bool _syncing;            // setting selectedIndex from the selection, not the other way

    Widget makeRow()
    {
        auto row = new TableRow();
        foreach (c; _columns)
        {
            auto cell = new Label("").accessibleRole(AccessibleRole.cell);
            cell.styleClass.remove("label");
            cell.styleClass.add("table-cell");
            cell.menuOnlyForSelection = true;
            cell.setSelectable(_selectableText || c._selectable);
            if (c._alignment == Alignment.end)
                cell.setTextAlignment(TextAlignment.right);
            else if (c._alignment == Alignment.centre)
                cell.setTextAlignment(TextAlignment.centre);
            row.add(cell);
        }
        sizeRow(row);
        return row;
    }

    void bindRow(Widget w, size_t i)
    {
        auto row = cast(TableRow) w;
        auto item = _items[_order[i]];
        foreach (c, cell; row.children)
            if (c < _columns.length)
                (cast(Label) cell).setText(_columns[c]._text(item));
        row.show(i, _selection.isSelected(cast(int) i), i == _selection.current);
    }

    /// Makes each cell in view selectable or not, as its column now is.
    void applySelectable()
    {
        foreach (w; _flow.children)
            foreach (c, cell; w.children)
                if (c < _columns.length)
                    (cast(Label) cell).setSelectable(_selectableText || _columns[c]._selectable);
    }

    /// Every column's width, as the header and each row lay them out: the last takes what's spare.
    void applyWidths()
    {
        float total = 0;
        foreach (c; _columns)
            total += c.width;
        const view = _pane.viewportBounds.width;
        if (_columns.length && view > total)
            _columns[$ - 1]._shown = _columns[$ - 1].width + (view - total);
        else if (_columns.length)
            _columns[$ - 1]._shown = _columns[$ - 1].width;
        foreach (i, c; _columns)
        {
            if (i + 1 < _columns.length)
                c._shown = c.width;
            fix(c._header, c._shown);
        }
        float shownTotal = 0;
        foreach (c; _columns)
            shownTotal += c._shown;
        _flow.setContentWidth(shownTotal);
        foreach (w; _flow.children)
            sizeRow(cast(TableRow) w);
    }

    void sizeRow(TableRow row)
    {
        foreach (i, cell; row.children)
            if (i < _columns.length)
                fix(cast() cell, _columns[i]._shown);
    }

    static void fix(Widget w, float width)
    {
        w.setMinWidth(width);
        w.setPrefWidth(width);
        w.setMaxWidth(width);
    }

    void columnsChanged()
    {
        foreach (c; _columns)
            if (c._autoWidth)
                c._width = c.naturalWidth;
        applyWidths();
        _flow.clear(); // the rows had the old columns
        invalidateAccessible();
    }

    void itemsChanged()
    {
        _empty.setVisible(_items.length == 0);
        // Columns sized from their text, sized again from the new items'
        bool resized;
        foreach (c; _columns)
            if (c._autoWidth)
            {
                c._width = c.naturalWidth;
                resized = true;
            }
        if (resized)
            applyWidths();
        resort();
        invalidateAccessible();
    }

    /// Works out the rows' order again, keeping the selection on its items.
    void resort()
    {
        const was = _order.dup;
        _order.length = _items.length;
        foreach (i, ref o; _order)
            o = i;
        if (_sortColumn)
        {
            auto column = _sortColumn;
            const up = _ascending;
            bool less(size_t a, size_t b)
            {
                const c = column.compare(_items[a], _items[b]);
                return up ? c < 0 : c > 0;
            }
            sort!(less, SwapStrategy.stable)(_order);
        }
        // Where each row's item has gone
        auto rowOf = new int[_items.length];
        rowOf[] = -1;
        foreach (row, item; _order)
            rowOf[item] = cast(int) row;
        auto moved = new int[was.length];
        foreach (row, item; was)
            moved[row] = item < rowOf.length ? rowOf[item] : -1;
        _selection.reorder(moved, _order.length);
        _flow.setCount(_order.length);
        selectionUpdated();
        if (_selection.lead >= 0)
            scrollTo(_selection.lead);
    }

    /// The app set selectedIndex: that row alone, then.
    void selectedIndexSet()
    {
        if (_syncing)
            return;
        _selection.selectOnly(_selectedIndex);
        selectionUpdated();
    }

    /// The selection changed: shown on the rows, in selectedIndex, and told to whoever's listening.
    void selectionUpdated()
    {
        _flow.forEachRow((Widget w, size_t i) {
            (cast(TableRow) w).showSelected(_selection.isSelected(cast(int) i), i == _selection.current);
        });
        _syncing = true;
        setSelectedIndex(_selection.lead);
        _syncing = false;
        if (_selection.changes != _shownChanges)
        {
            _shownChanges = _selection.changes;
            if (_onSelectionChanged)
                _onSelectionChanged();
        }
    }

    /// A header clicked: sorted by it, then the other way, then not.
    void headerClicked(TableColumn!S column)
    {
        if (!column._sortable)
            return;
        if (_sortColumn !is column)
            sortBy(column, true);
        else if (_ascending)
            sortBy(column, false);
        else
            sortBy(null);
    }

    /// The strip the header's in: clipped, and moved sideways with the rows.
    static final class HeaderStrip : Widget
    {
        this()
        {
            styleClass.add("column-header-background");
            YGNodeStyleSetOverflow(node, YGOverflowHidden);
        }

        void scrollTo(float x) nothrow @nogc { scrollChildren(x, 0); }

    protected:
        override void mounted() nothrow { clipChildren(); }
    }

    /// One of the header's columns: its title and which way it's sorted, clicked to sort and its
    /// right edge dragged to size it.
    final class ColumnHeader : ButtonBase
    {
        this(TableView table, TableColumn!S column)
        {
            super(column._title);
            _column = column;
            styleClass.add("column-header");
            setAccessibleRole(AccessibleRole.columnHeader);
            setFocusTraversable(false); // the table is the stop for Tab
            label.setGrow(1);
            _arrow = new Icon("pan-down-symbolic");
            _arrow.styleClass.add("sort-arrow");
            _arrow.setAccessibleHidden(true);
            _arrow.setVisible(false);
            adopt(_arrow);
        }

        override void fire()
        {
            headerClicked(_column);
            super.fire();
        }

        void showSort(bool sorted, bool ascending)
        {
            pseudoClassStateChanged(pseudo!"sorted", sorted);
            _arrow.setVisible(sorted);
            _arrow.setIconName(ascending ? "pan-up-symbolic" : "pan-down-symbolic");
        }

    protected:
        override void placeChild(Widget child) nothrow @nogc
        {
            super.placeChild(child);
            if (child is label)
            {
                YGNodeStyleSetFlexBasisAuto(child.node);
                YGNodeStyleSetFlexShrink(child.node, 1);
            }
        }

        override void handleMouse(ref MouseEvent event)
        {
            enum edge = 6; // points in from the right edge that take hold of it
            const b = boundsInScene;
            const nearEdge = _column._resizable && event.sceneX >= b.maxX - edge;
            switch (event.type)
            {
                case MouseEventType.moved, MouseEventType.entered:
                    setCursor(nearEdge || _resizing ? Cursor.resizeHorizontal : Cursor.inherit);
                    break;
                case MouseEventType.pressed:
                    if (nearEdge && event.button == MouseButton.primary)
                    {
                        _resizing = true;
                        _grabX = event.sceneX;
                        _grabWidth = _column.width;
                        event.consume();
                        return;
                    }
                    break;
                case MouseEventType.dragged:
                    if (_resizing)
                    {
                        _column.setWidth(_grabWidth + event.sceneX - _grabX);
                        event.consume();
                        return;
                    }
                    break;
                case MouseEventType.released:
                    if (_resizing)
                    {
                        _resizing = false;
                        setCursor(Cursor.inherit);
                        event.consume();
                        return;
                    }
                    break;
                default:
                    break;
            }
            super.handleMouse(event);
        }

        override void describeAccessible(ref AccessibleNode node)
        {
            super.describeAccessible(node);
        }

    private:
        TableColumn!S _column;
        Icon _arrow;
        bool _resizing;
        float _grabX = 0, _grabWidth = 0;
    }

    /// A row of cells, one for each column.
    static final class TableRow : Widget
    {
        this()
        {
            styleClass.add("table-row");
            setAccessibleRole(AccessibleRole.row);
            YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
            YGNodeStyleSetAlignItems(node, YGAlignCenter);
        }

        void show(size_t index, bool selected, bool current)
        {
            _index = index;
            pseudoClassStateChanged(pseudo!"odd", index % 2 == 1);
            showSelected(selected, current);
            invalidateAccessible();
        }

        void showSelected(bool selected, bool current)
        {
            if (selected == _selected && current == _current)
                return;
            _selected = selected;
            _current = current;
            pseudoClassStateChanged(pseudo!"selected", selected);
            pseudoClassStateChanged(pseudo!"current", current);
            invalidateAccessible();
        }

        bool isSelected() const nothrow @nogc { return _selected; }

    protected:
        override void describeAccessible(ref AccessibleNode node)
        {
            node.selected(_selected);
            node.rowIndex(_index + 1); // after the header's
        }

    private:
        size_t _index;
        bool _selected, _current;
    }
}

/*
    One of a TableView's columns: its title, and how to get a cell's text from an item. JavaFX's
    TableColumn, with its cell value factory as a plain function.

        new TableColumn!Person("Age", (Person p) => p.age.to!string).alignment(Alignment.end)

    It's as wide as its title and the first rows' text, unless given a width, and can be sized by
    dragging the header's right edge (resizable), no narrower than minWidth. It sorts by its text,
    as numbers where the texts are, unless it's given a comparator.
*/
final class TableColumn(S)
{
public:
    this(string title, string delegate(S) text)
    {
        _title = title;
        _text = text;
    }

    /// The same, from a plain function.
    this(string title, string function(S) text)
    {
        import std.functional : toDelegate;
        this(title, toDelegate(text));
    }

    /// What its header says.
    string title() const nothrow @nogc { return _title; }

    /// How wide it is, in points. The last column may be shown wider, to fill the table.
    float width() const nothrow @nogc { return _width; }
    /// ditto
    TableColumn width(float w)
    {
        setWidth(w);
        return this;
    }

    /// Sizes it, no narrower than minWidth.
    void setWidth(float w)
    {
        _autoWidth = false;
        _width = w < _minWidth ? _minWidth : w;
        if (_table)
            _table.applyWidths();
    }

    /// The narrowest dragging its edge makes it.
    TableColumn minWidth(float w) { _minWidth = w; return this; }

    /// Whether dragging its header's edge sizes it.
    TableColumn resizable(bool on) { _resizable = on; return this; }

    /// Whether clicking its header sorts by it.
    TableColumn sortable(bool on) { _sortable = on; return this; }

    /// Where its cells' text sits: at the start, in the middle, or at the end, as numbers go.
    TableColumn alignment(Alignment a) { _alignment = a; return this; }

    /// Whether its cells' text can be selected and copied, as a selectable Label's: see TableView.
    TableColumn selectable(bool on)
    {
        _selectable = on;
        if (_table)
            _table.applySelectable();
        return this;
    }

    /// How two items compare, for sorting by it: less than 0 if the first goes first.
    TableColumn comparator(int delegate(S a, S b) compare) { _comparator = compare; return this; }

package:
    TableView!S _table;
    TableView!S.ColumnHeader _header;
    string _title;
    string delegate(S) _text;
    int delegate(S, S) _comparator;
    float _width = float.nan, _minWidth = 40, _shown = 0;
    bool _resizable = true, _sortable = true, _selectable;
    bool _autoWidth = true; // sized from its title and text, until it's given a width
    Alignment _alignment;

    int compare(S a, S b)
    {
        if (_comparator)
            return _comparator(a, b);
        const ta = _text(a), tb = _text(b);
        // As numbers, where they both are
        try
        {
            const na = ta.to!double, nb = tb.to!double;
            return na < nb ? -1 : na > nb ? 1 : 0;
        }
        catch (ConvException) {}
        return icmp(ta, tb);
    }

    // As wide as its title, and the first rows' text, and room besides
    float naturalWidth()
    {
        import mayfair.text : defaultFont, shapeText;
        import mayfair.theme : Theme;
        auto font = defaultFont(Theme.text_size);
        float widest = shapeText(font, _title).width + 40; // the sort arrow and padding
        if (_table)
            foreach (i; 0 .. _table._items.length < 50 ? _table._items.length : 50)
            {
                const w = shapeText(font, _text(_table._items[i])).width + 24;
                if (w > widest)
                    widest = w;
            }
        return widest < _minWidth ? _minWidth : widest;
    }
}

unittest
{
    static struct City { string name; int people; }
    auto cities = new TableView!City([City("Leeds", 812_000), City("Bath", 94_000), City("York", 202_000)]);
    auto people = new TableColumn!City("People", (City c) => c.people.to!string).alignment(Alignment.end);
    cities.add(new TableColumn!City("City", (City c) => c.name)).add(people);
    cities.sortBy(people);
    assert(cities.itemAt(0).name == "Bath", "by people, as numbers");
    cities.sortBy(people, false);
    assert(cities.itemAt(0).name == "Leeds");
    cities.setSelectedIndex(0);
    cities.sortBy(cities.columns[0]);
    assert(cities.selectedItem.name == "Leeds" && cities.selectedIndex == 1, "the selection stays with its item");
    cities.sortBy(null);
    assert(cities.itemAt(0).name == "Leeds" && cities.itemAt(2).name == "York", "back in their own order");
}
