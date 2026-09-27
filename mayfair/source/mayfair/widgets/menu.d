module mayfair.widgets.menu;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.button;
import mayfair.widgets.buttonbase;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.label;
import mayfair.widgets.layouts;
import mayfair.widgets.popup;
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
        super(_items);
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

protected:
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
            default: return;
        }
        order[to].focusFromKeyboard();
        event.consume();
    }

private:
    Column _items;

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

    `accelerator` is what it says at the right -- the shortcut that does the same thing elsewhere
    in the app. It's there to be read: the item doesn't listen for it.
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

    /// Chooses it: does what it does, and puts its menu away first.
    override void fire()
    {
        if (_menu)
            _menu.hide();
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
        // The pointer picks it out, and from there the keys carry on
        if (event.type == MouseEventType.entered && !disabled)
            requestFocus();
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
