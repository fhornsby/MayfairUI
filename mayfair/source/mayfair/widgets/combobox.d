module mayfair.widgets.combobox;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.buttonbase;
import mayfair.widgets.icon;
import mayfair.widgets.input;
import mayfair.widgets.menu;
import mayfair.widgets.popup;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    One of a list, chosen from a drop-down: GNOME's drop-down, JavaFX's ComboBox of strings.

        auto size = new ComboBox(["Small", "Medium", "Large"]).selectedIndex(1);
        size.selectedIndexProperty.addListener((int was, int now) { resize(now); });

    It shows the choice, or promptText while there isn't one, with an arrow at its right. A click,
    or Enter, Space or Alt+Down, drops the list down below it, as wide as it is at least, with the
    choice ticked and picked out; choosing from the list chooses. Up and Down change the choice
    without opening the list, as a desktop's drop-downs do.

    Its style class is "combo-box", :showing while the list is. To a screen reader it's a combo
    box, its value the choice, expanded while the list is showing.
*/
class ComboBox : ButtonBase
{
public:
    this(string[] items = null)
    {
        super(null);
        _items = items;
        styleClass.add("combo-box");
        setAccessibleRole(AccessibleRole.comboBox);
        label.setGrow(1); // the text at the left, the arrow at the right
        _arrow = new Icon("pan-down-symbolic");
        _arrow.styleClass.add("arrow");
        _arrow.setAccessibleHidden(true);
        adopt(_arrow);
        showChoice();
    }

    /// What there is to choose from.
    mixin(declareProperty!(string[], "items", "null", q{
        if (_selectedIndex >= cast(int) _items.length)
            setSelectedIndex(-1);
        showChoice();
    }));

    /// Which is chosen, from 0; -1 for none.
    mixin(declareProperty!(int, "selectedIndex", "-1", q{ showChoice(); }));

    /// What it says while nothing's chosen.
    mixin(declareProperty!(string, "promptText", "null", q{ showChoice(); }));

    /// The choice, or null.
    final string value() nothrow @nogc
    {
        return _selectedIndex >= 0 && _selectedIndex < _items.length ? _items[_selectedIndex] : null;
    }

    /// Whether the list is showing.
    final bool showing() nothrow @nogc { return _list && _list.showing; }

    /// Drops the list down.
    final void show()
    {
        if (!_items.length || !scene)
            return;
        _list = new ContextMenu();
        _list.styleClass.add("combo-box-popup");
        foreach (i, item; _items)
        {
            auto choice = new CheckMenuItem(item, chooser(cast(int) i));
            choice.setSelected(i == _selectedIndex);
            _list.add(choice);
        }
        // At least as wide as this, so the list reads as this opened
        _list.setMinWidth(YGNodeLayoutGetWidth(node));
        _list.onHidden({
            pseudoClassStateChanged(pseudo!"showing", false);
            invalidateAccessible();
        });
        pseudoClassStateChanged(pseudo!"showing", true);
        _list.show(this, Side.below, 4);
        // The choice picked out, for the keys to go on from
        if (_selectedIndex >= 0)
            (cast(MenuItem) _list.items[_selectedIndex]).focusFromKeyboard();
        invalidateAccessible();
    }

    /// Opens the list: what a click does.
    override void fire()
    {
        show();
        super.fire();
    }

protected:
    /// The text grows to push the arrow to the right, from its own width rather than nothing.
    override void placeChild(Widget child) nothrow @nogc
    {
        super.placeChild(child);
        if (child is label)
        {
            YGNodeStyleSetFlexBasisAuto(child.node);
            YGNodeStyleSetFlexShrink(child.node, 0);
        }
    }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type == KeyEventType.pressed)
        {
            const n = cast(int) _items.length;
            if ((event.code == KeyCode.down && event.alt) || event.code == KeyCode.enter
                || event.code == KeyCode.numpadEnter)
            {
                show();
                event.consume();
                return;
            }
            if (n && (event.code == KeyCode.down || event.code == KeyCode.up) && !event.control)
            {
                const to = event.code == KeyCode.down ? (_selectedIndex < 0 ? 0 : _selectedIndex + 1)
                                                      : (_selectedIndex < 0 ? n - 1 : _selectedIndex - 1);
                if (to >= 0 && to < n)
                    setSelectedIndex(to);
                event.consume();
                return;
            }
        }
        super.handleKey(event);
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.value(value.length ? value : _promptText);
        node.expanded(showing);
    }

private:
    Icon _arrow;
    ContextMenu _list;

    // A choice's action, made here rather than in the loop, so each has its own index
    void delegate() chooser(int i)
    {
        return { setSelectedIndex(i); };
    }

    void showChoice()
    {
        const v = value;
        setText(v.length ? v : _promptText);
        pseudoClassStateChanged(pseudo!"prompt", !v.length);
        invalidateAccessible();
    }
}
