module mayfair.widgets.menu;

import mayfair.accessibility;
import mayfair.animation;
import mayfair.layout;
import mayfair.properties;
import mayfair.theme;
import mayfair.widgets.button;
import mayfair.widgets.buttonbase;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.popup;
import mayfair.widgets.scrollpane;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    A list of things to do, shown over the window: on a right click, or from a button. JavaFX's
    ContextMenu, which a MenuButton shows too.

        auto menu = new ContextMenu()
            .add(new MenuItem("Cut", { cut(); }).accelerator("Ctrl+X"))
            .add(new MenuItem("Copy", { copy(); }).accelerator("Ctrl+C").graphic(new Icon("edit-copy-symbolic")))
            .add(new MenuSeparator())
            .add(new CheckMenuItem("Word wrap").selected(true));
        editor.setContextMenu(menu);

    Choosing an item -- a click, or Enter or Space -- does what it does and puts the menu away. The
    pointer over an item picks it out, and Up and Down, Home and End move from one to the next,
    past separators and what's disabled; Escape, or a press anywhere else, puts it away without
    doing anything. It's a Popup, so the rest of the window waits while it's showing.

    A Menu in it is a submenu: resting the pointer on it opens it beside this one, as do Right,
    Enter and a click; Left, or Escape, closes it again. Choosing an item in a submenu puts away
    every menu it was opened from.

    One with more items than fit on the screen -- or than visibleRowCount, if that's set --
    scrolls, with the overlay bar a ScrollPane has; the keys scroll it to the item they move to.

    Its style class is "menu", as well as "popup"; each item is a `.menu-item`, with its shortcut
    in an `.accelerator`, and a separator is a `.separator`. To a screen reader it's a menu of
    menu items.
*/
class ContextMenu : Popup
{
public:
    this()
    {
        _items = new Column();
        _items.styleClass.add("menu-items");
        _scroll = new ScrollPane(_items).fitToWidth(true).hbarPolicy(ScrollBarPolicy.never);
        _scroll.styleClass.add("menu-scroll");
        super(_scroll);
        styleClass.add("menu");
        setAccessibleRole(AccessibleRole.menu);
    }

    /// Adds `item` at the end: a MenuItem, a CheckMenuItem or a MenuSeparator. Returns this, so calls chain.
    final ContextMenu add(Widget item)
    {
        if (auto m = cast(MenuItem) item)
            m._menu = this;
        _items.add(item);
        lineUpTexts();
        return this;
    }

    /// The items, in order.
    final inout(Widget)[] items() inout nothrow @nogc { return _items.children; }

    /// How many items it shows before it scrolls, or 0 for as many as fit on the screen, the
    /// default. JavaFX's ComboBox.visibleRowCount, here for any menu: a drop-down's list is 10.
    mixin(declareProperty!(int, "visibleRowCount", "0"));

    /// Scrolls it so the item at `index` is in the middle of what shows, or as near as it goes: a
    /// drop-down's list opens on its choice. Before it's been laid out, the items are taken to be
    /// the same height, as a drop-down's are.
    final void scrollToItem(size_t index)
    {
        const n = _items.children.length;
        if (index >= n)
            return;
        const shown = _visibleRowCount > 0 && _visibleRowCount < n ? _visibleRowCount : n;
        if (shown >= n)
            return;
        const from = cast(float) index - (shown - 1) / 2.0f;
        const v = from / (n - shown);
        _scroll.setVvalue(v < 0 ? 0 : v > 1 ? 1 : v);
    }

protected:
    // Its content, the items' scroll pane, shrinks to the height it's let have and scrolls
    override void placeChild(Widget child) nothrow @nogc
    {
        super.placeChild(child);
        YGNodeStyleSetFlexShrink(child.node, 1);
        YGNodeStyleSetMinHeight(child.node, 0);
    }

    // As tall as visibleRowCount items, and its padding, if that's fewer than it has
    override float heightLimit() nothrow @nogc
    {
        const n = _items.children.length;
        if (_visibleRowCount <= 0 || _visibleRowCount >= n)
            return float.nan;
        auto last = _items.children[_visibleRowCount - 1];
        // From its top in the items, and theirs in this, unscrolled
        float bottom = YGNodeLayoutGetTop(last.node) + YGNodeLayoutGetHeight(last.node);
        for (Widget w = _items; w && w !is this; w = w.parent)
            bottom += YGNodeLayoutGetTop(w.node);
        return bottom + YGNodeLayoutGetPadding(node, YGEdgeBottom) + YGNodeLayoutGetBorder(node, YGEdgeBottom);
    }

    /// Up and Down, Home and End, from item to item: where focus goes, it's what's picked out.
    override void handleKey(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed)
            return;
        auto order = choosable();
        if (!order.length)
            return;
        ptrdiff_t at = -1;
        foreach (i, item; order)
            if (item.isFocusOwner)
                at = i;
        const n = cast(ptrdiff_t) order.length;
        ptrdiff_t to;
        switch (event.code)
        {
            case KeyCode.down: to = at < 0 ? 0 : (at + 1) % n; break;
            case KeyCode.up:   to = at < 0 ? n - 1 : (at + n - 1) % n; break;
            case KeyCode.home: to = 0; break;
            case KeyCode.end:  to = n - 1; break;
            case KeyCode.right:
                // Into the submenu that has focus -- or, in a menu bar's, on to the next menu along
                if (auto sub = at >= 0 ? cast(Menu) order[at] : null)
                    sub.openMenu(true);
                else if (auto bar = menuBar)
                    bar.openNext(1);
                else
                    return;
                event.consume();
                return;
            case KeyCode.left:
                // Out of a submenu, back to its item -- or, from a menu bar's, to the menu before
                if (_parentItem && !_parentItem._bar)
                {
                    auto item = _parentItem;
                    hide();
                    item.focusFromKeyboard();
                }
                else if (auto bar = menuBar)
                    bar.openNext(-1);
                else
                    return;
                event.consume();
                return;
            default: return;
        }
        cancelPending();
        if (_openChild)
            _openChild.closeMenu(); // the keys have moved on from it
        _pointerPicked = null;
        order[to].focusFromKeyboard();
        event.consume();
    }

    override void hidden()
    {
        cancelPending();
        _openChild = null;
        _pointerPicked = null;
        if (_parentItem)
            _parentItem.menuHidden();
    }

package:
    Menu _parentItem; // the Menu this is the items of: a submenu's item, or a menu bar's title
    Menu _openChild;  // the submenu open from this one
    MenuItem _pointerPicked; // the item the pointer last moved onto, since the keys last moved

    /// The menu this was opened from, and that from, as far back as they go.
    ContextMenu rootMenu() nothrow @nogc
    {
        auto m = this;
        while (m._parentItem && m._parentItem._menu)
            m = m._parentItem._menu;
        return m;
    }

    /// The menu bar the first of those was opened from, if it was.
    MenuBar menuBar() nothrow @nogc
    {
        auto root = rootMenu;
        return root._parentItem ? root._parentItem._bar : null;
    }

    /// The pointer came onto `item`, in this menu: so this is where it is, not the menu this was opened from.
    void pointerOn(MenuItem item)
    {
        if (_parentItem && _parentItem._menu)
            _parentItem._menu.pointerRests(_parentItem);
        pointerRests(item);
    }

    /// Focus on the first item that can be chosen.
    void focusFirst()
    {
        auto order = choosable();
        if (order.length)
            order[0].focusFromKeyboard();
    }

private:
    Column _items;
    ScrollPane _scroll;
    Timeline _pending;              // waiting a moment before opening or closing a submenu,
    void delegate() _pendingAction; // to do this

    /*
        The pointer's on `item`, in this menu. If it stays there a moment, the submenu open from any
        other item closes, and `item`'s own opens if it has one: long enough that crossing an item on
        the way from a submenu's item to the submenu leaves the submenu be.
    */
    void pointerRests(MenuItem item)
    {
        auto sub = cast(Menu) item;
        if (sub && sub.disabled)
            sub = null;
        if (sub is _openChild)
        {
            cancelPending(); // back where it was before it strayed
            return;
        }
        _pendingAction = {
            if (_openChild)
                _openChild.closeMenu();
            if (sub)
                sub.openMenu(false);
        };
        if (!_pending)
            _pending = new Timeline(KeyFrame(Theme.submenu_delay, {
                auto action = _pendingAction;
                _pendingAction = null;
                if (action && showing)
                    action();
            }));
        _pending.playFromStart();
    }

    void cancelPending() nothrow @nogc
    {
        _pendingAction = null;
        if (_pending)
            _pending.stop();
    }

    /*
        Once any item has an icon or a tick, every item's text starts where theirs do, as GNOME's
        menus line up: an item with neither gets an empty space the size of one.
    */
    void lineUpTexts()
    {
        bool anyMarked;
        foreach (w; _items.children)
            if (auto m = cast(MenuItem) w)
                anyMarked = anyMarked || (m.graphic && !m._spacer) || cast(CheckMenuItem) m;
        foreach (w; _items.children)
        {
            auto m = cast(MenuItem) w;
            if (!m || cast(CheckMenuItem) m)
                continue;
            if (anyMarked && !m.graphic)
            {
                m._spacer = new Widget().prefSize(16, 16).accessibleHidden(true);
                m.setGraphic(m._spacer);
            }
        }
    }

    /// The items that can be chosen now: not separators, and not disabled.
    MenuItem[] choosable()
    {
        MenuItem[] order;
        foreach (w; _items.children)
            if (auto item = cast(MenuItem) w)
                if (!item.disabled)
                    order ~= cast() item;
        return order;
    }
}

/*
    One thing a menu does. JavaFX's MenuItem.

        new MenuItem("Save", { save(); }).accelerator("Ctrl+S").graphic(new Icon("document-save-symbolic"))

    `accelerator` is what it says at the right: the shortcut that does the same thing, such as
    "Ctrl+S", "Ctrl+Shift+Z" or "F5". In a menu bar's menus, it's the item's shortcut too, and
    pressing it chooses the item whether its menu is showing or not -- unless what has focus takes
    that key itself, as a text field takes Ctrl+C. Elsewhere it's only there to be read.
*/
class MenuItem : ButtonBase
{
public:
    this(string text, void delegate() action = null)
    {
        super(text);
        styleClass.add("menu-item");
        setAccessibleRole(AccessibleRole.menuItem);
        setMaxWidth(float.infinity); // the menu's width, so all of it is somewhere to click
        label.setGrow(1);            // pushing the accelerator to the right
        if (action)
            setOnAction(action);
    }

    /// The shortcut shown at its right, such as "Ctrl+S".
    mixin(declareProperty!(string, "accelerator", "null", q{ showAccelerator(); }));

    /// Chooses it: does what it does, and puts its menu away first, and any it was opened from.
    override void fire()
    {
        if (_menu)
            _menu.rootMenu.hide();
        super.fire();
    }

protected:
    /// The text grows to push the accelerator to the right, from its own width rather than nothing,
    /// so the menu is measured wide enough for both.
    override void placeChild(Widget child) nothrow @nogc
    {
        super.placeChild(child);
        if (child is label)
        {
            YGNodeStyleSetFlexBasisAuto(child.node);
            YGNodeStyleSetFlexShrink(child.node, 0);
        }
    }

    override void handleMouse(ref MouseEvent event)
    {
        // The pointer moving onto it picks it out, and from there the keys carry on. Moving, not
        // entering: a menu that scrolls, or opens, under a pointer that's still picks nothing
        if (event.type == MouseEventType.moved && !disabled && (!_menu || _menu._pointerPicked !is this))
        {
            if (_menu)
                _menu._pointerPicked = this;
            requestFocus();
            if (_menu)
                _menu.pointerOn(this);
        }
        super.handleMouse(event);
    }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type == KeyEventType.pressed && (event.code == KeyCode.enter || event.code == KeyCode.numpadEnter))
        {
            event.consume();
            flashAndFire();
            return;
        }
        super.handleKey(event);
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        if (_accelerator.length)
            node.description(_accelerator);
    }

package:
    ContextMenu _menu;
    Widget _spacer; // standing in for an icon, so the text lines up with those that have one

    void focusFromKeyboard() { requestFocusFromKeyboard(); }

private:
    Label _acceleratorLabel;

    void showAccelerator()
    {
        if (_accelerator.length && !_acceleratorLabel)
        {
            _acceleratorLabel = new Label(_accelerator).accessibleHidden(true);
            _acceleratorLabel.styleClass.remove("label");
            _acceleratorLabel.styleClass.add("accelerator");
            adopt(_acceleratorLabel);
        }
        else if (_acceleratorLabel && !_accelerator.length)
        {
            remove(_acceleratorLabel);
            _acceleratorLabel = null;
        }
        else if (_acceleratorLabel)
            _acceleratorLabel.setText(_accelerator);
    }
}

/*
    A menu item that's on or off, with a tick when it's on: a setting in a menu. Choosing it
    switches it, then does what it does.
*/
class CheckMenuItem : MenuItem
{
public:
    this(string text, void delegate() action = null)
    {
        super(text, action);
        styleClass.add("check-menu-item");
        _tick = new Icon("object-select-symbolic");
        _tick.styleClass.add("tick");
        _tick.setAccessibleHidden(true);
        setIndicator(_tick);
        showTick();
    }

    /// Whether it's on.
    mixin(declareProperty!(bool, "selected", "false", q{ showTick(); }));

    override void fire()
    {
        setSelected(!_selected);
        super.fire();
    }

protected:
    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.toggled(_selected);
    }

private:
    Icon _tick;

    void showTick()
    {
        pseudoClassStateChanged(pseudo!"selected", _selected);
        if (_tick)
            _tick.setOpacity(_selected ? 1 : 0); // there either way, so the texts line up
        invalidateAccessible();
    }
}

/// A line between groups of items in a menu.
class MenuSeparator : Widget
{
public:
    this()
    {
        styleClass.add("separator");
        setAccessibleHidden(true);
    }
}

/*
    A button that shows a menu below it: GNOME's menu button, as the ☰ at the top of a window.
    JavaFX's MenuButton.

        new MenuButton().graphic(new Icon("open-menu-symbolic")).menu(appMenu).accessibleText("Main menu")

    Pressing it again while the menu's showing puts it away. It's :showing while its menu is.
*/
class MenuButton : Button
{
public:
    this(string text = null)
    {
        super(text);
        styleClass.add("menu-button");
    }

    /// The menu it shows.
    mixin(declareProperty!(ContextMenu, "menu", "null"));

    override void fire()
    {
        if (!_menu)
            return;
        if (_menu.showing)
        {
            _menu.hide();
            return;
        }
        _menu.onHidden({ pseudoClassStateChanged(pseudo!"showing", false); });
        pseudoClassStateChanged(pseudo!"showing", true);
        _menu.show(this, Side.below, 4);
        super.fire();
    }

protected:
    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.expanded(_menu && _menu.showing);
    }
}

/*
    A menu of its own inside another -- a submenu -- or one of a menu bar's menus. JavaFX's Menu.

        new Menu("Open recent")
            .add(new MenuItem("notes.txt", { open("notes.txt"); }))
            .add(new MenuItem("todo.txt", { open("todo.txt"); }))

    In a menu, it's an item with an arrow at its right, whose items open beside it: when the pointer
    rests on it a moment, or with Right, Enter or a click. In a MenuBar, it's a title the menu
    drops down from. It's :showing while its items are.
*/
class Menu : MenuItem
{
public:
    this(string text)
    {
        super(text);
        styleClass.add("submenu-item");
        _items = new ContextMenu();
        _items._parentItem = this;
        _arrow = new Icon("go-next-symbolic");
        _arrow.styleClass.add("arrow");
        _arrow.setAccessibleHidden(true);
        adopt(_arrow);
    }

    /// Adds `item` at the end: a MenuItem, a CheckMenuItem, a MenuSeparator, or a Menu of its own.
    /// Returns this, so calls chain.
    final Menu add(Widget item)
    {
        _items.add(item);
        return this;
    }

    /// Its items, in order.
    final inout(Widget)[] items() inout nothrow @nogc { return _items.items; }

    /// Whether its items are showing.
    final bool showing() const nothrow @nogc { return _items.showing; }

    /// Opens it, with focus on its first item, as Right or Enter do. It has to be showing itself:
    /// in a menu bar, or in a menu that's open.
    final void show() { openMenu(true); }

    /// Closes it, and anything open from it.
    final void hide() { closeMenu(); }

    /// Opens it, rather than doing anything itself.
    override void fire()
    {
        openMenu(true);
    }

protected:
    override void handleMouse(ref MouseEvent event)
    {
        if (!_bar)
            return super.handleMouse(event);
        // A menu bar's title: a press opens its menu, or closes it if it's open. While one of the
        // bar's menus is open, the pointer moving onto another title opens that one instead.
        switch (event.type)
        {
            case MouseEventType.pressed:
                if (event.button == MouseButton.primary && !disabled)
                {
                    if (showing)
                        closeMenu();
                    else
                        _bar.openMenu(this);
                }
                event.consume();
                break;
            case MouseEventType.entered:
                if (_bar._open && _bar._open !is this && !disabled)
                    _bar.openMenu(this);
                break;
            case MouseEventType.released, MouseEventType.clicked:
                event.consume();
                break;
            default:
                break;
        }
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.opensMenu();
        node.expanded(showing);
    }

package:
    MenuBar _bar; // the bar it's a title in, if it is

    /// Shows its items: with focus on the first, or, if the pointer opened it, on this still,
    /// until Right moves it in.
    void openMenu(bool focusIn)
    {
        if (showing)
        {
            if (focusIn)
                _items.focusFirst();
            return;
        }
        if (!scene)
            return;
        if (_bar)
        {
            if (_bar._open && _bar._open !is this)
                _bar._open.closeMenu();
            _bar._open = this;
            _items._reachable = [cast(Widget) _bar];
            _items.show(this, Side.below, 2);
        }
        else
        {
            if (_menu)
            {
                if (_menu._openChild && _menu._openChild !is this)
                    _menu._openChild.closeMenu();
                _menu._openChild = this;
            }
            // Beside the menu this is in, rather than this item, which is inset in it
            const gap = _menu ? _menu.boundsInScene.maxX - boundsInScene.maxX : 0;
            _items.show(this, Side.right, gap);
        }
        pseudoClassStateChanged(pseudo!"showing", true);
        invalidateAccessible();
        if (!focusIn)
            requestFocus();
    }

    void closeMenu()
    {
        _items.hide();
    }

    /// Its items have gone, however that happened.
    void menuHidden()
    {
        pseudoClassStateChanged(pseudo!"showing", false);
        invalidateAccessible();
        if (_menu && _menu._openChild is this)
            _menu._openChild = null;
        if (_bar && _bar._open is this)
            _bar._open = null;
    }

    /// Becomes a title in `bar`.
    void joinBar(MenuBar bar)
    {
        _bar = bar;
        styleClass.remove("menu-item");
        styleClass.remove("submenu-item");
        styleClass.add("menu-bar-item");
        _arrow.setVisible(false);
        setFocusTraversable(false); // reached by F10, as GTK's are, not Tab
    }

    /// Chooses the item among its items, and theirs, whose accelerator `event` is. Whether there was one.
    bool fireAccelerator(ref const KeyEvent event)
    {
        foreach (w; _items.items)
        {
            if (w.disabled)
                continue;
            if (auto sub = cast(Menu) w)
            {
                if (sub.fireAccelerator(event))
                    return true;
            }
            else if (auto item = cast(MenuItem) w)
            {
                if (item.accelerator.length && isAccelerator(item.accelerator, event))
                {
                    item.fire();
                    return true;
                }
            }
        }
        return false;
    }

private:
    ContextMenu _items;
    Icon _arrow;
}

/*
    A row of menus along the top of a window: File, Edit, View... JavaFX's MenuBar.

        auto bar = new MenuBar()
            .add(new Menu("File")
                .add(new MenuItem("Open…", { open(); }).accelerator("Ctrl+O"))
                .add(new Menu("Open recent").add(new MenuItem("notes.txt", { open("notes.txt"); })))
                .add(new MenuSeparator())
                .add(new MenuItem("Quit", { quit(); }).accelerator("Ctrl+Q")))
            .add(new Menu("Edit")
                .add(new MenuItem("Undo", { undo(); }).accelerator("Ctrl+Z")));

    A press on a title opens its menu below it, and a press on it again closes it. While a menu is
    open the bar is still the pointer's, and moving along it opens each title's menu in turn. F10
    opens the first menu; in an open one, Left and Right go to the menus either side. Every item's
    accelerator works while the bar is in the window, menus open or not.

    Its style class is "menu-bar", and each title is a `.menu-bar-item`. To a screen reader it's
    a menu bar of menu items, each of which opens a menu.
*/
class MenuBar : Widget
{
public:
    this()
    {
        styleClass.add("menu-bar");
        setAccessibleRole(AccessibleRole.menuBar);
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        YGNodeStyleSetAlignItems(node, YGAlignStretch);
    }

    /// Space between one title and the next, in points.
    mixin(declareStyleableProperty!(float, "spacing", "gap", "0", q{ YGNodeStyleSetGap(node, YGGutterAll, _spacing); }));

    /// Adds `menu` at the end. Returns this, so calls chain.
    final MenuBar add(Menu menu)
    {
        menu.joinBar(this);
        _menus ~= menu;
        adopt(menu);
        return this;
    }

    /// Its menus, in order.
    final inout(Menu)[] menus() inout nothrow @nogc { return _menus; }

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // its menus, through add()

    /// A press on the bar between titles puts away the menu that's open.
    override void handleMouse(ref MouseEvent event)
    {
        if (event.type == MouseEventType.pressed && _open)
        {
            _open.closeMenu();
            event.consume();
        }
    }

    override void handleShortcut(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || event.repeat)
            return;
        if (event.code == KeyCode.f10 && !event.shift && !event.control && !event.alt && !event.meta)
        {
            openNext(1);
            event.consume();
            return;
        }
        foreach (m; _menus)
        {
            if (!m.disabled && m.fireAccelerator(event))
            {
                event.consume();
                return;
            }
        }
    }

package:
    Menu _open; // the menu showing, if one is

    void openMenu(Menu menu)
    {
        if (_open && _open !is menu)
            _open.closeMenu();
        menu.openMenu(true);
    }

    /// Opens the menu `direction` along from the open one, round from the end to the start, or the
    /// first if none is open.
    void openNext(int direction)
    {
        Menu[] order;
        foreach (m; _menus)
            if (!m.disabled && m.visible)
                order ~= m;
        if (!order.length)
            return;
        ptrdiff_t at = -1;
        foreach (i, m; order)
            if (m is _open)
                at = i;
        const n = cast(ptrdiff_t) order.length;
        openMenu(order[at < 0 ? 0 : (at + direction + n) % n]);
    }

private:
    Menu[] _menus;
}

/*
    Whether `event` is the key `accelerator` names: modifiers and a key joined by "+", such as
    "Ctrl+S", "Ctrl+Shift+Z", "Alt+F4" or "F5". The key is a letter, a digit or other character,
    F1 to F12, or one of Delete, Insert, Home, End, PageUp, PageDown, Escape, Enter, Space, Tab,
    Backspace, Up, Down, Left and Right. The modifiers have to be just those held down.
*/
package bool isAccelerator(string accelerator, ref const KeyEvent event)
{
    import std.conv : to;
    import std.string : indexOf, toLower;
    bool control, shift, alt, meta;
    string key = accelerator;
    for (auto plus = key.indexOf('+'); plus > 0 && plus < key.length - 1; plus = key.indexOf('+'))
    {
        switch (key[0 .. plus].toLower)
        {
            case "ctrl", "control": control = true; break;
            case "shift": shift = true; break;
            case "alt": alt = true; break;
            case "super", "meta", "cmd", "command": meta = true; break;
            default: return false;
        }
        key = key[plus + 1 .. $];
    }
    if (control != event.control || shift != event.shift || alt != event.alt || meta != event.meta)
        return false;

    KeyCode code;
    const name = key.toLower;
    if (name.length == 1)
        code = cast(KeyCode) name[0]; // a key's code is its unshifted character, a letter's lower case
    else if (name.length <= 3 && name[0] == 'f' && name[1] >= '1' && name[1] <= '9')
    {
        uint n;
        try n = name[1 .. $].to!uint;
        catch (Exception) return false;
        if (n < 1 || n > 12)
            return false;
        code = cast(KeyCode) (KeyCode.f1 + n - 1);
    }
    else switch (name)
    {
        case "delete", "del": code = KeyCode.delete_; break;
        case "insert", "ins": code = KeyCode.insert; break;
        case "home": code = KeyCode.home; break;
        case "end": code = KeyCode.end; break;
        case "pageup", "pgup": code = KeyCode.pageUp; break;
        case "pagedown", "pgdn": code = KeyCode.pageDown; break;
        case "escape", "esc": code = KeyCode.escape; break;
        case "enter", "return": code = KeyCode.enter; break;
        case "space": code = KeyCode.space; break;
        case "tab": code = KeyCode.tab; break;
        case "backspace": code = KeyCode.backspace; break;
        case "up": code = KeyCode.up; break;
        case "down": code = KeyCode.down; break;
        case "left": code = KeyCode.left; break;
        case "right": code = KeyCode.right; break;
        default: return false;
    }
    return event.code == code || (code == KeyCode.enter && event.code == KeyCode.numpadEnter);
}

unittest
{
    KeyEvent e;
    e.type = KeyEventType.pressed;
    e.code = KeyCode.s;
    e.control = true;
    assert(isAccelerator("Ctrl+S", e));
    assert(!isAccelerator("Ctrl+Shift+S", e));
    assert(!isAccelerator("S", e));
    e.shift = true;
    e.code = KeyCode.z;
    assert(isAccelerator("Ctrl+Shift+Z", e));
    assert(isAccelerator("shift+control+z", e));
    e = KeyEvent.init;
    e.code = KeyCode.f5;
    assert(isAccelerator("F5", e));
    assert(!isAccelerator("F15", e));
    e.code = KeyCode.delete_;
    assert(isAccelerator("Del", e));
    e.control = true;
    e.code = cast(KeyCode) '+';
    assert(isAccelerator("Ctrl++", e));
    assert(!isAccelerator("Hyper+X", e));
}
