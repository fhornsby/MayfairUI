module mayfair.widgets.listview;

import std.array : join;
import std.conv : to;
import mayfair.accessibility;
import mayfair.clipboard;
import mayfair.layout;
import mayfair.properties;
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
    A list of items to choose from, one to a row, however many there are. JavaFX's ListView.

        auto fruit = new ListView!string(["Apple", "Banana", "Cherry"]);
        fruit.selectedIndexProperty.addListener((int was, int now) { show(fruit.selectedItem); });
        fruit.onActivate((int i) { open(fruit.items[i]); });   // a double click, or Enter

    Only the rows in view are made (see VirtualFlow), so a list of a hundred thousand costs no more
    than one of ten. Each is a ListCell, showing its item as text; for anything else -- an icon, two
    lines, a check box -- make cells of a subclass that overrides updateItem, as JavaFX's cell
    factories do:

        class ContactCell : ListCell!Contact
        {
            this() { add(new Icon("avatar-default-symbolic")); }  // before the text
            override void updateItem(Contact c) { label.setText(c.name); }
        }
        contacts.cellFactory({ return cast(ListCell!Contact) new ContactCell; });

    A click selects, and Up and Down, Page Up and Page Down, Home and End move the selection,
    scrolling to keep it in view. It's one stop for Tab. With no items, it says so (placeholder).

    One item is selected at a time, unless selectionMode says any number can be, when Ctrl and
    Shift with a click or the keys select more, as in a file manager (see Selection):

        files.selectionMode(SelectionMode.multiple);
        files.onSelectionChanged({ show(files.selectedItems); });

    Ctrl+C copies the selected items, a line each, and so does Copy on a right click, which
    selects the row it's on first if it isn't already. An item's copied as it's written with
    to!string, unless itemText says otherwise -- as it should for cells that show items their own
    way:

        contacts.itemText((Contact c) => c.name ~ " <" ~ c.email ~ ">");

    Its style class is "list-view", and each row is a `.list-cell`: :selected for those selected,
    :current for the one the keys are on, and :odd for every other, for striping. To a screen
    reader it's a list box of options, each saying where it is in the whole list.
*/
class ListView(T) : Widget
{
public:
    this(T[] items = null)
    {
        styleClass.add("list-view");
        setAccessibleRole(AccessibleRole.listBox);
        setFocusTraversable(true);
        _flow = new VirtualFlow(&makeCell, &bindCell);
        _pane = new ScrollPane(_flow).fitToWidth(true);
        _pane.setAccessibleHidden(true);
        _flow.pane = _pane;
        _pane.vvalueProperty.addListener((float was, float now) { _flow.refresh(); });
        _empty = new Label("No items");
        _empty.styleClass.add("placeholder");
        _empty.setAccessibleHidden(true);
        _body = new Stack();
        _body.add(_pane).add(_empty);
        _body.setGrow(1);
        adopt(_body);
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
        setItems(items);
    }

    /// What it lists.
    mixin(declarePropertyOf!(T[], "T[]", "items", "null", q{ itemsChanged(); }));

    /// Which is selected, from 0; -1 for none. With several selected, the one selected last.
    /// Setting it selects that one alone.
    mixin(declareProperty!(int, "selectedIndex", "-1", q{ selectedIndexSet(); }));

    /// Whether one item can be selected at a time, or any number.
    mixin(declareProperty!(SelectionMode, "selectionMode", "SelectionMode.single", q{
        _selection.setMode(_selectionMode);
        selectionUpdated();
        invalidateAccessible();
    }));

    /// What it says when it has no items.
    mixin(declareProperty!(string, "placeholder", `"No items"`, q{ _empty.setText(_placeholder); }));

    /// The selected item, or T.init when there's none.
    final T selectedItem()
    {
        return _selectedIndex >= 0 && _selectedIndex < _items.length ? _items[_selectedIndex] : T.init;
    }

    /// Which are selected, from the first.
    final int[] selectedIndices() const { return _selection.indices; }

    /// The items selected, in the list's order.
    final T[] selectedItems()
    {
        T[] all;
        foreach (i; _selection.indices)
            all ~= _items[i];
        return all;
    }

    /// Whether item `index` is selected.
    final bool isSelected(int index) const nothrow @nogc { return _selection.isSelected(index); }

    /// Adds item `index` to what's selected -- or, one at a time, selects it alone.
    final void select(int index) { _selection.select(index); selectionUpdated(); }

    /// Takes item `index` out of what's selected.
    final void deselect(int index) { _selection.deselect(index); selectionUpdated(); }

    /// Adds items `from` to `to` to what's selected, either way round.
    final void selectRange(int from, int to) { _selection.selectRange(from, to, true); selectionUpdated(); }

    /// Selects every item, if any number can be.
    final void selectAll() { _selection.selectAll(); selectionUpdated(); }

    /// Selects nothing.
    final void clearSelection() { _selection.clear(); selectionUpdated(); }

    /// What to do when what's selected changes, however it did.
    final ListView onSelectionChanged(void delegate() handler) nothrow @nogc
    {
        _onSelectionChanged = handler;
        return this;
    }

    /// How rows are made: a ListCell of your own that shows an item its own way.
    final ListView cellFactory(ListCell!T delegate() factory)
    {
        _factory = factory;
        return this;
    }

    /// How an item's written when it's copied, in place of to!string.
    final ListView itemText(string delegate(T) text) nothrow @nogc
    {
        _itemText = text;
        return this;
    }

    /// Copies the selected items to the clipboard, a line each.
    final void copy()
    {
        string[] lines;
        foreach (i; _selection.indices)
            lines ~= textOf(_items[i]);
        if (lines.length)
            Clipboard.text = lines.join("\n");
    }

    /// What to do when a row's activated: double clicked, or Enter pressed on it.
    final ListView onActivate(void delegate(int index) handler) nothrow @nogc
    {
        _onActivate = handler;
        return this;
    }

    /// Scrolls so item `index` is in view.
    final void scrollTo(int index)
    {
        if (index >= 0)
            _flow.reveal(index);
    }

    /// Shows every item in view again, for items whose insides changed while the array didn't.
    final void refresh()
    {
        _flow.refresh(true);
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || !_items.length)
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
                _onActivate(_selection.current);
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
        // The row it's in: the cell the press went to, or the one round what it went to
        for (Widget w = event.target; w && w !is this; w = w.parent)
        {
            if (auto cell = cast(ListCell!T) w)
            {
                const i = _flow.indexOf(cell);
                if (i == size_t.max)
                    break;
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
                    _onActivate(cast(int) i);
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
                     .disable(_selection.count == _items.length));
        return menu;
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.rowCount(_items.length);
        if (_selectionMode == SelectionMode.multiple)
            node.multiselectable();
    }

private:
    VirtualFlow _flow;
    ScrollPane _pane;
    Stack _body;
    Label _empty;
    ListCell!T delegate() _factory;
    string delegate(T) _itemText;
    void delegate(int) _onActivate;
    void delegate() _onSelectionChanged;
    Selection _selection;
    uint _shownChanges; // the selection's changes, as far as onSelectionChanged has heard
    bool _syncing;      // setting selectedIndex from the selection, not the other way

    string textOf(T item)
    {
        if (_itemText)
            return _itemText(item);
        static if (is(T : string))
            return item;
        else
            return item.to!string;
    }

    Widget makeCell()
    {
        return _factory ? _factory() : new ListCell!T;
    }

    void bindCell(Widget w, size_t i)
    {
        auto cell = cast(ListCell!T) w;
        cell.show(_items[i], i, _items.length, _selection.isSelected(cast(int) i), i == _selection.current);
    }

    void itemsChanged()
    {
        _selection.resize(_items.length); // what was selected past the end goes
        _empty.setVisible(_items.length == 0);
        _flow.setCount(_items.length);
        selectionUpdated();
        invalidateAccessible();
    }

    /// The app set selectedIndex: that item alone, then.
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
            (cast(ListCell!T) w).showSelected(_selection.isSelected(cast(int) i), i == _selection.current);
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
}

/*
    What every cell of a list or table has, whatever it shows: the space between what's in it. Not
    a template, so the style engine knows it once.
*/
abstract class Cell : Widget
{
public:
    this()
    {
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        YGNodeStyleSetAlignItems(node, YGAlignCenter);
    }

    /// Space between what's in it, in points: an icon and the text after it.
    mixin(declareStyleableProperty!(float, "spacing", "gap", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));
}

/*
    One of a ListView's rows, showing an item. Rows are reused as the list scrolls, so a cell
    shows whatever item it's given, each time: see updateItem. It lays out what's in it in a row,
    with its label -- the item as text, unless updateItem says otherwise -- after anything added.
*/
class ListCell(T) : Cell
{
public:
    this()
    {
        styleClass.add("list-cell");
        setAccessibleRole(AccessibleRole.listBoxOption);
        _label = new Label("").accessibleHidden(true);
        adopt(_label);
    }

    /// The item it's showing, and where it is in the list.
    final T item() nothrow @nogc { return _item; }
    final size_t index() const nothrow @nogc { return _index; } /// ditto

    /// Whether it's selected.
    final bool isSelected() const nothrow @nogc { return _selected; }

    /// Whether it's the row the keys are on.
    final bool isCurrent() const nothrow @nogc { return _current; }

    /// Shows `item`: as text, by default. Override to show it otherwise.
    void updateItem(T item)
    {
        static if (is(T : string))
            _label.setText(item);
        else
            _label.setText(item.to!string);
    }

    /// Adds `w` before the label: an icon, say, for a cell of a subclass. Returns this.
    final ListCell add(Widget w)
    {
        adopt(w, children.length - 1);
        return this;
    }

protected:
    /// The label the item's shown in.
    final Label label() nothrow @nogc { return _label; }

    override bool takesChildren() const nothrow @nogc { return false; }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.label(_label.text);
        node.selected(_selected);
        node.positionInSet(_index + 1, _count);
    }

package:
    void show(T item, size_t index, size_t count, bool selected, bool current)
    {
        _item = item;
        _index = index;
        _count = count;
        pseudoClassStateChanged(pseudo!"odd", index % 2 == 1);
        showSelected(selected, current);
        updateItem(item);
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

private:
    Label _label;
    T _item;
    size_t _index, _count;
    bool _selected, _current;
}

unittest
{
    // Of text, and of a type of an app's own, which it can name only as T
    auto fruit = new ListView!string(["Apple", "Banana"]);
    assert(fruit.items.length == 2 && fruit.selectedIndex == -1);
    fruit.setSelectedIndex(1);
    assert(fruit.selectedItem == "Banana");
    static struct Contact { string name; }
    auto contacts = new ListView!Contact([Contact("Ada")]);
    assert(contacts.items[0].name == "Ada");
}
