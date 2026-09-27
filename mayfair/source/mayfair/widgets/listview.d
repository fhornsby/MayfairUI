module mayfair.widgets.listview;

import std.conv : to;
import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.scrollpane;
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

    Its style class is "list-view", and each row is a `.list-cell`, :selected for the selected one
    and :odd for every other, for striping. To a screen reader it's a list box of options, each
    saying where it is in the whole list.
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

    /// Which is selected, from 0; -1 for none.
    mixin(declareProperty!(int, "selectedIndex", "-1", q{ selectionChanged(); }));

    /// What it says when it has no items.
    mixin(declareProperty!(string, "placeholder", `"No items"`, q{ _empty.setText(_placeholder); }));

    /// The selected item, or T.init when there's none.
    final T selectedItem()
    {
        return _selectedIndex >= 0 && _selectedIndex < _items.length ? _items[_selectedIndex] : T.init;
    }

    /// How rows are made: a ListCell of your own that shows an item its own way.
    final ListView cellFactory(ListCell!T delegate() factory)
    {
        _factory = factory;
        return this;
    }

    /// What to do when a row's activated: double clicked, or Enter pressed on the selection.
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
        const n = cast(int) _items.length;
        const page = _flow.rowHeight > 0 ? cast(int)(_pane.viewportBounds.height / _flow.rowHeight) - 1 : 10;
        const at = _selectedIndex;
        int to;
        switch (event.code)
        {
            case KeyCode.down:     to = at < 0 ? 0 : at + 1; break;
            case KeyCode.up:       to = at < 0 ? 0 : at - 1; break;
            case KeyCode.pageDown: to = at + (page > 1 ? page : 1); break;
            case KeyCode.pageUp:   to = at - (page > 1 ? page : 1); break;
            case KeyCode.home:     to = 0; break;
            case KeyCode.end:      to = n - 1; break;
            case KeyCode.enter, KeyCode.numpadEnter:
                if (at >= 0 && _onActivate)
                    _onActivate(at);
                event.consume();
                return;
            default:
                return;
        }
        to = to < 0 ? 0 : to >= n ? n - 1 : to;
        setSelectedIndex(to);
        scrollTo(to);
        event.consume();
    }

    override void handleMouse(ref MouseEvent event)
    {
        if (event.type != MouseEventType.pressed || event.button != MouseButton.primary)
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
                setSelectedIndex(cast(int) i);
                if (event.clickCount == 2 && _onActivate)
                    _onActivate(cast(int) i);
                event.consume();
                break;
            }
        }
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.rowCount(_items.length);
    }

private:
    VirtualFlow _flow;
    ScrollPane _pane;
    Stack _body;
    Label _empty;
    ListCell!T delegate() _factory;
    void delegate(int) _onActivate;

    Widget makeCell()
    {
        return _factory ? _factory() : new ListCell!T;
    }

    void bindCell(Widget w, size_t i)
    {
        auto cell = cast(ListCell!T) w;
        cell.show(_items[i], i, _items.length, i == _selectedIndex);
    }

    void itemsChanged()
    {
        if (_selectedIndex >= cast(int) _items.length)
            setSelectedIndex(cast(int) _items.length - 1);
        _empty.setVisible(_items.length == 0);
        _flow.setCount(_items.length);
        invalidateAccessible();
    }

    int _shownSelection = -1;

    void selectionChanged()
    {
        foreach (i; [_shownSelection, _selectedIndex])
            if (i >= 0)
                if (auto cell = cast(ListCell!T) _flow.rowAt(i))
                    cell.showSelected(i == _selectedIndex);
        _shownSelection = _selectedIndex;
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

    /// Whether it's the list's selected row.
    final bool isSelected() const nothrow @nogc { return _selected; }

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
    void show(T item, size_t index, size_t count, bool selected)
    {
        _item = item;
        _index = index;
        _count = count;
        pseudoClassStateChanged(pseudo!"odd", index % 2 == 1);
        showSelected(selected);
        updateItem(item);
        invalidateAccessible();
    }

    void showSelected(bool on)
    {
        _selected = on;
        pseudoClassStateChanged(pseudo!"selected", on);
        invalidateAccessible();
    }

private:
    Label _label;
    T _item;
    size_t _index, _count;
    bool _selected;
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
