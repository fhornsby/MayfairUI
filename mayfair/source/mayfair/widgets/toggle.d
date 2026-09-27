module mayfair.widgets.toggle;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.buttonbase;
import mayfair.widgets.input;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    Toggles that go together, of which at most one is selected: JavaFX's ToggleGroup. Selecting one
    deselects whichever was. A group of radio buttons is the usual one.

        auto size = new ToggleGroup;
        auto small = new RadioButton("Small").toggleGroup(size);
        auto large = new RadioButton("Large").toggleGroup(size);
        size.selectedToggleProperty.addListener((ToggleButton was, ToggleButton now) { ... });

    The keyboard treats a group as one control, as JavaFX and every desktop do: Tab stops once, on
    the selected toggle (or the first, if none is), and the arrow keys move between them -- and in
    a group of radio buttons, select as they go.
*/
final class ToggleGroup
{
public:
    /// The toggles in it, in the order they joined.
    const(ToggleButton)[] toggles() const nothrow @nogc { return _toggles; }

    /// Which is selected, if any.
    mixin(declareReadOnlyProperty!(ToggleButton, "selectedToggle", "null"));

    /// Selects `toggle`, or with null, deselects whichever is selected.
    void selectToggle(ToggleButton toggle)
    {
        if (toggle)
            toggle.setSelected(true);
        else if (selectedToggle)
            selectedToggle.setSelected(false);
    }

package:
    void join(ToggleButton t)
    {
        _toggles ~= t;
        if (t.selected)
            chosen(t, true);
    }

    void leave(ToggleButton t)
    {
        foreach (i, x; _toggles)
        {
            if (x is t)
            {
                _toggles = _toggles[0 .. i] ~ _toggles[i + 1 .. $];
                break;
            }
        }
        if (selectedToggle is t)
            _setSelectedToggle(null);
    }

    // A toggle in the group was selected or deselected
    void chosen(ToggleButton t, bool on)
    {
        if (on)
        {
            auto previous = selectedToggle;
            _setSelectedToggle(t);
            if (previous && previous !is t)
                previous.setSelected(false);
        }
        else if (selectedToggle is t)
            _setSelectedToggle(null);
    }

    /// The toggle `step` on from `from` (-1 for back), past any that are disabled, round from the end.
    ToggleButton next(ToggleButton from, int step)
    {
        ptrdiff_t at = -1;
        foreach (i, t; _toggles)
            if (t is from)
                at = i;
        const n = cast(ptrdiff_t) _toggles.length;
        foreach (k; 1 .. n)
        {
            auto t = _toggles[((at + step * k) % n + n) % n];
            if (!t.disabled && t.scene)
                return t;
        }
        return null;
    }

private:
    ToggleButton[] _toggles;
}

/*
    A button that stays in when it's pressed, until it's pressed again: JavaFX's ToggleButton. In
    a ToggleGroup, pressing one lets the others out.

        auto bold = new ToggleButton("Bold").onAction({ ... });

    It looks like a button; its style class is "toggle-button", and it's :selected while it's in.
*/
class ToggleButton : ButtonBase
{
public:
    this(string text = null)
    {
        super(text);
        styleClass.add("toggle-button");
        setAccessibleRole(AccessibleRole.toggleButton);
        YGNodeStyleSetJustifyContent(node, YGJustifyCenter);
        YGNodeStyleSetAlignItems(node, YGAlignCenter);
    }

    /// Whether it's in.
    mixin(declareProperty!(bool, "selected", "false", q{
        pseudoClassStateChanged(pseudo!"selected", _selected);
        if (_toggleGroup)
            _toggleGroup.chosen(this, _selected);
        invalidateAccessible();
    }));

    /// The group it's one of, if any.
    mixin(declareProperty!(ToggleGroup, "toggleGroup", "null", q{
        if (_joined)
            _joined.leave(this);
        _joined = _toggleGroup;
        if (_toggleGroup)
            _toggleGroup.join(this);
    }));

    /// Toggles, then runs its action: JavaFX's fire().
    override void fire()
    {
        if (disabled)
            return;
        setSelected(!selected);
        super.fire();
    }

protected:
    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        node.toggled(_selected);
    }

    // One stop for the whole group: the selected toggle, or the first if none is. The one with
    // focus is one too, so Tab carries on from wherever focus is.
    override bool isTabStop()
    {
        if (!_toggleGroup || isFocusOwner)
            return true;
        if (auto s = _toggleGroup.selectedToggle)
            return s is this;
        return _toggleGroup.next(null, 1) is this;
    }

    // The arrows move through the group
    override void handleKey(ref KeyEvent event)
    {
        if (_toggleGroup && event.type == KeyEventType.pressed && !event.control && !event.alt && !event.meta)
        {
            int step;
            if (event.code == KeyCode.right || event.code == KeyCode.down)
                step = 1;
            else if (event.code == KeyCode.left || event.code == KeyCode.up)
                step = -1;
            if (step)
            {
                if (auto to = _toggleGroup.next(this, step))
                    arrowedTo(to);
                event.consume();
                return;
            }
        }
        super.handleKey(event);
    }

    /// What arriving on a toggle by the arrows does: a toggle button only takes focus.
    void arrowedTo(ToggleButton to)
    {
        to.requestFocusFromKeyboard();
    }

private:
    ToggleGroup _joined; // the group it's in, for leaving it when it's given another
}

/*
    One of several choices, of which one is chosen: JavaFX's RadioButton. A round mark before its
    text, filled while it's selected. In a ToggleGroup, choosing one unchooses the others, and
    pressing the chosen one again leaves it chosen; the arrow keys choose as they move.

    Its style class is "radio-button", and the mark is two parts, as JavaFX's is: `.radio`, the
    ring, and `.dot` inside it, for a stylesheet to draw.
*/
class RadioButton : ToggleButton
{
public:
    this(string text = null)
    {
        super(text);
        styleClass.remove("toggle-button");
        styleClass.add("radio-button");
        setAccessibleRole(AccessibleRole.radioButton);
        // The mark, then the text, side by side
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        YGNodeStyleSetJustifyContent(node, YGJustifyFlexStart);
        auto radio = new Widget().styleClass("radio").accessibleHidden(true);
        radio.add(new Widget().styleClass("dot").accessibleHidden(true));
        setIndicator(radio);
    }

    /// Chooses it, unless it's in a group and chosen already: then it stays so. JavaFX's fire().
    override void fire()
    {
        if (!toggleGroup || !selected)
            super.fire();
    }

protected:
    override void arrowedTo(ToggleButton to)
    {
        to.requestFocusFromKeyboard();
        if (!to.selected)
            to.fire();
    }
}
