module mayfair.widgets.treeview;

import std.conv : to;
import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.listview : Cell;
import mayfair.widgets.scrollpane;
import mayfair.widgets.selection;
import mayfair.widgets.styling;
import mayfair.widgets.virtualflow;
import mayfair.widgets.widget;

/*
    One item in a TreeView: a value, and the items below it. JavaFX's TreeItem.

        auto home = new TreeItem!string("Home").icon("user-home-symbolic").expanded(true)
            .add(new TreeItem!string("Documents").icon("folder-symbolic")
                .add(new TreeItem!string("notes.txt").icon("text-x-generic-symbolic")))
            .add(new TreeItem!string("Music").icon("folder-symbolic"));

    Items below one that isn't expanded don't show. For a hierarchy too big to make all at once --
    a disk's folders -- childrenLoader makes an item's children the first time it's expanded; until
    then it shows as though it has some.

    An item is in one place at a time: adding it somewhere takes it from where it was. Changing an
    item, or what's below it, shows in the tree it's in.
*/
class TreeItem(T)
{
public:
    this(T value, TreeItem[] children...)
    {
        _value = value;
        foreach (c; children)
            adoptChild(c, _children.length);
    }

    /// What it stands for, which its row shows.
    final T value() { return _value; }

    /// ditto
    final TreeItem value(T v)
    {
        _value = v;
        changed();
        return this;
    }

    /// The name of an icon from the desktop's theme shown before it, such as "folder-symbolic"; null for none.
    final string icon() const nothrow @nogc { return _icon; }

    /// ditto
    final TreeItem icon(string name)
    {
        _icon = name;
        changed();
        return this;
    }

    /// The items below it, in order.
    final inout(TreeItem)[] children() inout nothrow @nogc { return _children; }

    /// The item it's below, or null.
    final TreeItem parent() nothrow @nogc { return _parent; }

    /// Adds `items` below it, at the end. Returns this, so calls chain.
    final TreeItem add(TreeItem[] items...)
    {
        foreach (c; items)
            adoptChild(c, _children.length);
        changed();
        return this;
    }

    /// Adds `item` below it, `at` from the first.
    final TreeItem insert(size_t at, TreeItem item)
    {
        adoptChild(item, at < _children.length ? at : _children.length);
        changed();
        return this;
    }

    /// Takes `item` from below it.
    final void remove(TreeItem item)
    {
        if (detach(item))
            changed();
    }

    /// Takes every item from below it.
    final void clear()
    {
        foreach (c; _children)
            c._parent = null;
        _children = null;
        changed();
    }

    /// Whether the items below it are showing.
    final bool expanded() const nothrow @nogc { return _expanded; }

    /// ditto
    final TreeItem expanded(bool on)
    {
        setExpanded(on);
        return this;
    }

    /// ditto
    final void setExpanded(bool on)
    {
        if (on && _loader)
        {
            auto load = _loader;
            _loader = null;
            foreach (c; load())
                adoptChild(c, _children.length);
        }
        if (on == _expanded)
            return changed(); // the loader may have added some
        _expanded = on;
        changed();
    }

    /// Whether it has nothing below it, nor anything still to load.
    final bool isLeaf() const nothrow @nogc { return !_children.length && !_loader; }

    /*
        Makes its children with `load` the first time it's expanded, rather than now: for a
        hierarchy made as it's explored. Until then, it's not a leaf.

            folder.childrenLoader(() => listFolder(path));
    */
    final TreeItem childrenLoader(TreeItem[] delegate() load)
    {
        _loader = load;
        changed();
        return this;
    }

    /// How far down it is: 0 for the top.
    final int depth() nothrow @nogc
    {
        int d;
        for (auto p = _parent; p; p = p._parent)
            d++;
        return d;
    }

    /// Whether it's below `ancestor`, however far.
    final bool isBelow(const TreeItem ancestor) nothrow @nogc
    {
        for (auto p = _parent; p; p = p._parent)
            if (p is ancestor)
                return true;
        return false;
    }

    /// The tree showing it, if one is.
    final TreeView!T treeView() nothrow @nogc
    {
        auto top = this;
        while (top._parent)
            top = top._parent;
        return top._tree;
    }

private:
    T _value;
    string _icon;
    TreeItem _parent;
    TreeItem[] _children;
    bool _expanded;
    TreeItem[] delegate() _loader;
    TreeView!T _tree; // of the top item: the tree it's the root of

    void adoptChild(TreeItem c, size_t at)
    {
        if (auto was = c._parent)
            if (was.detach(c))
                was.changed();
        c._parent = this;
        _children = _children[0 .. at] ~ c ~ _children[at .. $];
    }

    bool detach(TreeItem item)
    {
        foreach (i, c; _children)
            if (c is item)
            {
                _children = _children[0 .. i] ~ _children[i + 1 .. $];
                item._parent = null;
                return true;
            }
        return false;
    }

    void changed()
    {
        if (auto tree = treeView)
            tree.itemsChanged();
    }
}

/*
    Items in a hierarchy, each opening to show those below it: a folder tree, an outline. JavaFX's
    TreeView.

        auto files = new TreeView!string(home);
        files.onActivate((TreeItem!string item) { open(item.value); });  // a double click, or Enter

    The root is the item at the top, which is shown unless showRoot says otherwise, when the items
    below it are the top of the tree. Only the rows in view are made, as a ListView's are, so a
    tree can be as big as it likes. Each row is a TreeCell, showing an arrow to open it, its item's
    icon, and its value as text; for anything else, make cells of a subclass, as a list's cells are.

    A click on the arrow opens or closes an item, and a double click on one opens or closes it too.
    Right opens the item the keys are on, or goes to the first below it if it's open; Left closes
    it, or goes to the item it's below. The rest of the keys, and selecting one item or any number,
    are as a list's (see Selection). Enter, or a double click, activates an item.

    Its style class is "tree-view", and each row is a `.tree-cell` -- :selected, :current for the
    one the keys are on, :expanded, and :leaf for one with nothing below it -- indented by `indent`
    points for each step down, with its arrow in a `.disclosure`. To a screen reader it's a tree of
    tree items, each saying how deep it is and whether it's open.
*/
class TreeView(T) : Widget
{
public:
    this(TreeItem!T root = null)
    {
        styleClass.add("tree-view");
        setAccessibleRole(AccessibleRole.tree);
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
        setRoot(root);
    }

    /// The item at the top, which everything else is below.
    mixin(declarePropertyOf!(TreeItem!T, "TreeItem!T", "root", "null", q{ rootChanged(); }));

    /// Whether the root has a row of its own, or the items below it are the top of the tree.
    mixin(declareProperty!(bool, "showRoot", "true", q{ itemsChanged(); }));

    /// Whether one item can be selected at a time, or any number.
    mixin(declareProperty!(SelectionMode, "selectionMode", "SelectionMode.single", q{
        _selection.setMode(_selectionMode);
        selectionUpdated();
        invalidateAccessible();
    }));

    /// What it says when it has no items.
    mixin(declareProperty!(string, "placeholder", `"No items"`, q{ _empty.setText(_placeholder); }));

    /// How far each step down is indented, in points.
    mixin(declareStyleableProperty!(float, "indent", "indent", "20", q{ _flow.refresh(true); }));

    /// How many rows there are: the items showing, whether they're in view or not.
    final size_t rowCount() { rebuild(); return _rows.length; }

    /// The item showing in row `row`, from the top; null past the end.
    final TreeItem!T itemAt(int row)
    {
        rebuild();
        return row >= 0 && row < _rows.length ? _rows[row] : null;
    }

    /// The row `item` shows in, or -1 if it isn't showing: it's in an item that's closed, or not in the tree.
    final int rowOf(TreeItem!T item)
    {
        rebuild();
        if (auto row = item in _rowOf)
            return *row;
        return -1;
    }

    /// The item selected, or with several, the one selected last; null for none.
    final TreeItem!T selectedItem() { rebuild(); return itemAt(_selection.lead); }

    /// The items selected, from the top.
    final TreeItem!T[] selectedItems()
    {
        rebuild();
        TreeItem!T[] all;
        foreach (row; _selection.indices)
            all ~= _rows[row];
        return all;
    }

    /// Whether `item` is selected.
    final bool isSelected(TreeItem!T item) { return _selection.isSelected(rowOf(item)); }

    /// Adds `item` to what's selected -- or, one at a time, selects it alone -- opening what it's
    /// in so it shows, and scrolling to it.
    final void select(TreeItem!T item)
    {
        reveal(item);
        _selection.select(rowOf(item));
        selectionUpdated();
        scrollTo(item);
    }

    /// Takes `item` out of what's selected.
    final void deselect(TreeItem!T item)
    {
        _selection.deselect(rowOf(item));
        selectionUpdated();
    }

    /// Selects every item showing, if any number can be.
    final void selectAll() { rebuild(); _selection.selectAll(); selectionUpdated(); }

    /// Selects nothing.
    final void clearSelection() { rebuild(); _selection.clear(); selectionUpdated(); }

    /// Opens what `item` is in, so it shows, and scrolls so it's in view.
    final void scrollTo(TreeItem!T item)
    {
        reveal(item);
        const row = rowOf(item);
        if (row >= 0)
            _flow.reveal(row);
    }

    /// How rows are made: a TreeCell of your own that shows an item its own way.
    final TreeView cellFactory(TreeCell!T delegate() factory)
    {
        _factory = factory;
        return this;
    }

    /// What to do when an item's activated: double clicked, or Enter pressed on it. One with items
    /// below it opens or closes as well.
    final TreeView onActivate(void delegate(TreeItem!T item) handler) nothrow @nogc
    {
        _onActivate = handler;
        return this;
    }

    /// What to do when what's selected changes, however it did. An item closing round selected ones
    /// takes them out of it.
    final TreeView onSelectionChanged(void delegate() handler) nothrow @nogc
    {
        _onSelectionChanged = handler;
        return this;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void update()
    {
        rebuild();
    }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed)
            return;
        rebuild();
        if (!_rows.length)
            return;
        auto item = itemAt(_selection.current);
        switch (event.code)
        {
            case KeyCode.enter, KeyCode.numpadEnter:
                if (item)
                    activate(item);
                event.consume();
                return;
            case KeyCode.right:
                if (!item)
                    break;
                if (!item.isLeaf && !item.expanded)
                    toggle(item);
                else if (item.expanded && item.children.length)
                    moveTo(_selection.current + 1);
                event.consume();
                return;
            case KeyCode.left:
                if (!item)
                    break;
                if (!item.isLeaf && item.expanded)
                    toggle(item);
                else if (item.parent && rowOf(item.parent) >= 0)
                    moveTo(rowOf(item.parent));
                event.consume();
                return;
            default:
                break;
        }
        const page = _flow.rowHeight > 0 ? cast(int)(_pane.viewportBounds.height / _flow.rowHeight) - 1 : 10;
        if (!_selection.key(event, page))
            return;
        selectionUpdated();
        _flow.reveal(_selection.current);
        event.consume();
    }

    override void handleMouse(ref MouseEvent event)
    {
        if (event.type != MouseEventType.pressed || event.button != MouseButton.primary)
            return;
        rebuild();
        for (Widget w = event.target; w && w !is this; w = w.parent)
        {
            if (auto cell = cast(TreeCell!T) w)
            {
                const i = _flow.indexOf(cell);
                if (i == size_t.max || i >= _rows.length)
                    break;
                requestFocus();
                auto item = _rows[i];
                if (cell.onDisclosure(event.target))
                    toggle(item); // opening it isn't choosing it
                else
                {
                    _selection.press(cast(int) i, event.shift, event.control);
                    selectionUpdated();
                    if (event.clickCount == 2)
                        activate(item);
                }
                event.consume();
                break;
            }
        }
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        if (_selectionMode == SelectionMode.multiple)
            node.multiselectable();
    }

package:
    /// An item in it changed, or what's below one: the rows are made again before the next layout.
    void itemsChanged() nothrow @nogc
    {
        _dirty = true;
        requestUpdate();
    }

private:
    VirtualFlow _flow;
    ScrollPane _pane;
    Stack _body;
    Label _empty;
    TreeCell!T delegate() _factory;
    void delegate(TreeItem!T) _onActivate;
    void delegate() _onSelectionChanged;
    TreeItem!T _shownRoot;     // the root it told it's the tree of
    TreeItem!T[] _rows;        // the items showing, from the top
    int[] _depths;             // how far each is indented
    int[TreeItem!T] _rowOf;    // and the other way
    bool _anyIcons;            // whether any row has an icon, when those without have a space for one
    bool _dirty = true;        // an item's changed since the rows were made
    Selection _selection;      // by row
    uint _shownChanges;        // the selection's changes, as far as onSelectionChanged has heard

    void rootChanged()
    {
        if (_shownRoot)
            _shownRoot._tree = null;
        _shownRoot = _root;
        if (_root)
        {
            if (_root._parent)
                _root._parent.remove(_root); // a root is below nothing
            _root._tree = this;
        }
        _selection.clear();
        itemsChanged();
    }

    /// Makes the rows again from the items, if they've changed, with the selection going with its items.
    void rebuild()
    {
        if (!_dirty)
            return;
        if (_root && !_showRoot && !_root.expanded)
            _root.setExpanded(true); // what's below a hidden root is the top: load it
        _dirty = false;
        auto was = _rows;
        _rows = null;
        _depths = null;
        void walk(TreeItem!T item, int depth)
        {
            _rows ~= item;
            _depths ~= depth;
            if (item.expanded)
                foreach (c; item._children)
                    walk(c, depth + 1);
        }
        if (_root && _showRoot)
            walk(_root, 0);
        else if (_root)
            foreach (c; _root._children)
                walk(c, 0);

        int[TreeItem!T] rowOf;
        const hadIcons = _anyIcons;
        _anyIcons = false;
        foreach (i, item; _rows)
        {
            rowOf[item] = cast(int) i;
            _anyIcons = _anyIcons || item.icon.length > 0;
        }
        if (_anyIcons != hadIcons)
            _flow.refresh(true);
        auto moved = new int[was.length];
        foreach (row, item; was)
        {
            auto to = item in rowOf;
            moved[row] = to ? *to : -1;
        }
        _rowOf = rowOf;
        _selection.reorder(moved, _rows.length);
        _empty.setVisible(!_rows.length);
        _flow.setCount(_rows.length);
        selectionUpdated();
        invalidateAccessible();
    }

    /// Opens every item `item` is below, so it has a row.
    void reveal(TreeItem!T item)
    {
        for (auto p = item ? item.parent : null; p; p = p.parent)
            if (!p.expanded)
                p.setExpanded(true);
        rebuild();
    }

    /// Opens `item` or closes it, as a click on its arrow does. Closed round the row the keys were
    /// on, it's where they go.
    void toggle(TreeItem!T item)
    {
        if (item.isLeaf)
            return;
        if (item.expanded)
        {
            auto on = itemAt(_selection.current);
            const inside = on && on.isBelow(item);
            item.setExpanded(false);
            rebuild();
            if (inside)
            {
                _selection.selectOnly(rowOf(item));
                selectionUpdated();
            }
        }
        else
        {
            item.setExpanded(true);
            rebuild();
        }
    }

    void activate(TreeItem!T item)
    {
        toggle(item);
        if (_onActivate)
            _onActivate(item);
    }

    /// The keys go to `row`, which is selected alone.
    void moveTo(int row)
    {
        _selection.selectOnly(row);
        selectionUpdated();
        _flow.reveal(row);
    }

    Widget makeCell()
    {
        return _factory ? _factory() : new TreeCell!T;
    }

    void bindCell(Widget w, size_t i)
    {
        (cast(TreeCell!T) w).show(_rows[i], i, _depths[i], _indent, _anyIcons,
                                  _selection.isSelected(cast(int) i), i == _selection.current);
    }

    /// The selection changed: shown on the rows, and told to whoever's listening.
    void selectionUpdated()
    {
        _flow.forEachRow((Widget w, size_t i) {
            (cast(TreeCell!T) w).showSelected(_selection.isSelected(cast(int) i), i == _selection.current);
        });
        if (_selection.changes != _shownChanges)
        {
            _shownChanges = _selection.changes;
            if (_onSelectionChanged)
                _onSelectionChanged();
        }
    }
}

/*
    One of a TreeView's rows, showing an item: indented for how deep it is, an arrow to open it if
    it has anything below it, its icon -- or a space for one, if others in the tree have them -- and
    its value as text. Rows are reused as the tree scrolls
    and opens, so a cell shows whatever item it's given, each time: see updateItem.
*/
class TreeCell(T) : Cell
{
public:
    this()
    {
        styleClass.add("tree-cell");
        setAccessibleRole(AccessibleRole.treeItem);
        _closed = new Icon("pan-end-symbolic");
        _open = new Icon("pan-down-symbolic");
        _disclosure = new Stack();
        _disclosure.styleClass.add("disclosure");
        _disclosure.add(_closed).add(_open);
        _disclosure.setAccessibleHidden(true);
        _icon = new Icon(cast(string) null);
        _icon.styleClass.add("item-icon");
        _icon.setAccessibleHidden(true);
        _label = new Label("").accessibleHidden(true);
        adopt(_disclosure);
        adopt(_icon);
        adopt(_label);
    }

    /// The item it's showing, and its row.
    final TreeItem!T item() nothrow @nogc { return _item; }
    final size_t index() const nothrow @nogc { return _index; } /// ditto

    /// Whether it's selected.
    final bool isSelected() const nothrow @nogc { return _selected; }

    /// Whether it's the row the keys are on.
    final bool isCurrent() const nothrow @nogc { return _current; }

    /// Shows `item`'s value, as text by default. Override to show it otherwise.
    void updateItem(TreeItem!T item)
    {
        static if (is(T : string))
            _label.setText(item.value);
        else
            _label.setText(item.value.to!string);
    }

    /// Adds `w` before the label, after the icon: for a cell of a subclass. Returns this.
    final TreeCell add(Widget w)
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
        node.level(_depth + 1);
        if (!_item)
            return;
        if (!_item.isLeaf)
            node.expanded(_item.expanded);
        if (auto p = _item.parent)
            foreach (i, c; p.children)
                if (c is _item)
                    node.positionInSet(i + 1, p.children.length);
    }

package:
    void show(TreeItem!T item, size_t index, int depth, float indent, bool iconSpace, bool selected, bool current)
    {
        _item = item;
        _index = index;
        _depth = depth;
        // Indented by the arrow's margin, so a row with nothing indenting it has no gap for it
        YGNodeStyleSetMargin(_disclosure.node, YGEdgeLeft, depth * indent);
        _disclosure.setOpacity(item.isLeaf ? 0 : 1); // still there, so leaves line up with their siblings
        _closed.setVisible(!item.expanded);
        _open.setVisible(item.expanded);
        // With no icon, a space the size of one if others have them, so the texts line up as GNOME's do
        if (item.icon.length)
            _icon.setIconName(item.icon);
        _icon.setVisible(item.icon.length > 0 || iconSpace);
        _icon.setOpacity(item.icon.length > 0 ? 1 : 0);
        pseudoClassStateChanged(pseudo!"expanded", item.expanded);
        pseudoClassStateChanged(pseudo!"leaf", item.isLeaf);
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

    /// Whether `target`, which a press went to, is the arrow, of an item it opens.
    bool onDisclosure(Widget target) nothrow @nogc
    {
        if (!_item || _item.isLeaf)
            return false;
        for (auto w = target; w && w !is this; w = w.parent)
            if (w is _disclosure)
                return true;
        return false;
    }

private:
    Stack _disclosure;
    Icon _closed, _open, _icon;
    Label _label;
    TreeItem!T _item;
    size_t _index;
    int _depth;
    bool _selected, _current;
}

unittest
{
    auto a = new TreeItem!string("a"), b = new TreeItem!string("b"), c = new TreeItem!string("c");
    auto root = new TreeItem!string("root", a, b);
    a.add(c);
    assert(c.depth == 2 && c.isBelow(root) && !root.isBelow(c));
    b.add(c); // taken from a
    assert(a.isLeaf && c.parent is b && b.children == [c]);

    // Loaded the first time it's opened, and not before
    int loads;
    auto lazy_ = new TreeItem!string("lazy").childrenLoader({ loads++; return [new TreeItem!string("x")]; });
    assert(!lazy_.isLeaf && !lazy_.children.length && loads == 0);
    lazy_.setExpanded(true);
    lazy_.setExpanded(false);
    lazy_.setExpanded(true);
    assert(loads == 1 && lazy_.children.length == 1);

    // Rows: the root and what's below the open items
    auto tree = new TreeView!string(root);
    assert(tree.rowCount == 1, "the root, closed");
    root.setExpanded(true);
    assert(tree.rowCount == 3 && tree.itemAt(2) is b);
    b.setExpanded(true);
    assert(tree.rowOf(c) == 3);
    tree.setShowRoot(false);
    assert(tree.rowCount == 3 && tree.itemAt(0) is a);
}
