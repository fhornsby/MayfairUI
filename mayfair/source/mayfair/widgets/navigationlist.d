module mayfair.widgets.navigationlist;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.buttonbase;
import mayfair.widgets.label;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.layouts;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    A list of places to go, one of them where you are: the sidebar of GNOME's Settings, or its
    file manager.

        auto sidebar = new NavigationList()
            .add("Wi-Fi", "network-wireless-symbolic")
            .add("Bluetooth", "bluetooth-symbolic")
            .add("Displays", "video-display-symbolic");
        sidebar.selectedIndexProperty.addListener((int was, int now) { showPage(now); });

    or in a view, an entry to each NavigationItem:

        <NavigationList>
            <NavigationItem text="Wi-Fi" iconName="network-wireless-symbolic"/>
        </NavigationList>

    A heading can go between them, to group what's after it -- a music player's playlists, say --
    and entries can be taken out again, as a playlist that's deleted is:

        sidebar.addHeading("Playlists").add("Road Trip", "view-list-symbolic");
        sidebar.remove(roadTrip);

    A heading isn't an entry: it can't be selected, the keys pass over it, and selectedIndex
    counts only entries.

    One is always selected once there are any -- the first, to start with -- and clicking it again
    leaves it so, which is what makes it a place rather than a switch. From the keyboard it's one
    stop for Tab, at the selected entry, and Up and Down, Home and End move the selection, which
    follows at once, as GNOME's does.

    Its style class is "navigation-list", and each entry is a `.navigation-item`, :selected for
    the one chosen, and a heading is a `.navigation-heading`. To a screen reader it's a list box
    and its entries options, one selected.
*/
class NavigationList : Widget
{
public:
    this()
    {
        styleClass.add("navigation-list");
        setAccessibleRole(AccessibleRole.listBox);
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionColumn);
        YGNodeStyleSetAlignItems(node, YGAlignStretch);
    }

    /// Adds an entry saying `text`, with the desktop theme's icon `iconName` before it if there's one.
    final NavigationList add(string text, string iconName = null)
    {
        return add(new NavigationItem(text, iconName));
    }

    /// Adds `item` as the last entry.
    final NavigationList add(NavigationItem item)
    {
        if (item._list)
            throw new Exception("a navigation item is in one list at a time");
        item._list = this;
        _items ~= item;
        adopt(item);
        item.setGrow(0);
        if (_selectedIndex < 0)
            setSelectedIndex(0);
        return this;
    }

    /// Adds a heading saying `text` after the entries so far, for those added after it.
    final NavigationList addHeading(string text)
    {
        auto heading = new Label(text);
        heading.styleClass.add("navigation-heading");
        adopt(heading);
        return this;
    }

    /*
        Takes `item` out. If it was the one selected, the entry before it is selected instead --
        or the first, if it was the first -- and selectedIndex's listeners hear of it even where
        the number's the same, as it's another entry now.
    */
    final NavigationList remove(NavigationItem item)
    {
        const i = indexOf(item);
        if (i < 0)
            return this;
        _items = _items[0 .. i] ~ _items[i + 1 .. $];
        item.showSelected(false);
        item._list = null;
        Widget.remove(item);
        if (_selectedIndex == i)
        {
            setSelectedIndex(-1); // which comes back to 0 if there are entries left
            if (i > 0)
                setSelectedIndex(i - 1);
        }
        else if (_selectedIndex > i)
            setSelectedIndex(_selectedIndex - 1); // the same entry, which has moved up
        return this;
    }

    alias add = Widget.add; // refused, as for any control: entries go in with add(text, icon)
    alias remove = Widget.remove; /// ditto

    /// How many entries there are.
    final size_t length() const nothrow @nogc { return _items.length; }

    /// What entry `i` says.
    final string text(size_t i) nothrow @nogc { return _items[i].text; }

    /// Which entry is selected, from 0; -1 when there are none.
    mixin(declareProperty!(int, "selectedIndex", "-1", q{ selectionChanged(); }));

    /// Space between one entry and the next, in points.
    mixin(declareStyleableProperty!(float, "spacing", "gap", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

private:
    NavigationItem[] _items;

    void selectionChanged()
    {
        if (_selectedIndex >= cast(int) _items.length)
        {
            setSelectedIndex(cast(int) _items.length - 1);
            return;
        }
        if (_selectedIndex < 0 && _items.length)
        {
            setSelectedIndex(0);
            return;
        }
        foreach (i, item; _items)
            item.showSelected(i == _selectedIndex);
    }

    void step(NavigationItem from, int to)
    {
        if (to < 0 || to >= cast(int) _items.length)
            return;
        setSelectedIndex(to);
        _items[to].focusFromKeyboard();
        _items[to].scrollIntoView();
    }

    int indexOf(NavigationItem item) nothrow @nogc
    {
        foreach (i, it; _items)
            if (it is item)
                return cast(int) i;
        return -1;
    }
}

/// One entry in a NavigationList.
final class NavigationItem : ButtonBase
{
public:
    /// An entry saying `text`, with the desktop theme's icon `iconName` before it if there's one.
    this(string text = null, string iconName = null)
    {
        super(text);
        if (iconName.length)
            setGraphic(new Icon(iconName));
        styleClass.add("navigation-item");
        setAccessibleRole(AccessibleRole.listBoxOption);
        setMaxWidth(float.infinity); // the width of the list, so it's all somewhere to click
    }

    /// Whether it's the one chosen.
    bool isSelected() const nothrow @nogc { return _selected; }

    override void fire()
    {
        if (_list)
            _list.setSelectedIndex(_list.indexOf(this));
        super.fire();
    }

protected:
    override bool isTabStop() { return _selected; }

    override void handleKey(ref KeyEvent event)
    {
        if (_list && event.type == KeyEventType.pressed && !event.control && !event.alt)
        {
            const i = _list.indexOf(this);
            int to = -1;
            switch (event.code)
            {
                case KeyCode.up:   to = i - 1; break;
                case KeyCode.down: to = i + 1; break;
                case KeyCode.home: to = 0; break;
                case KeyCode.end:  to = cast(int) _list.length - 1; break;
                default: break;
            }
            if (to != -1 || event.code == KeyCode.up || event.code == KeyCode.down)
            {
                _list.step(this, to);
                event.consume();
                return;
            }
        }
        super.handleKey(event);
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.selected(_selected);
    }

private:
    NavigationList _list;
    bool _selected;

    void focusFromKeyboard() { requestFocusFromKeyboard(); }

    void showSelected(bool on)
    {
        if (on == _selected)
            return;
        _selected = on;
        pseudoClassStateChanged(pseudo!"selected", on);
        invalidateAccessible();
    }
}

unittest
{
    auto list = new NavigationList();
    auto a = new NavigationItem("A"), b = new NavigationItem("B"), c = new NavigationItem("C");
    list.add(a).addHeading("Group").add(b).add(c);
    assert(list.length == 3 && list.children.length == 4, "a heading isn't an entry");
    list.setSelectedIndex(2);
    list.remove(b);
    assert(list.selectedIndex == 1 && c.isSelected, "the selected entry stays selected as it moves up");
    list.remove(c);
    assert(list.selectedIndex == 0 && a.isSelected, "the one before, once the selected one's gone");
    list.remove(a);
    assert(list.selectedIndex == -1 && list.length == 0);
}
