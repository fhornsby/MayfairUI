module mayfair.widgets.checkbox;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.buttonbase;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    A box to tick: JavaFX's CheckBox. On or off -- and, if it's allowed to be, neither, for a box
    that stands for several things of which some are on.

        auto wrap = new CheckBox("Wrap lines").selected(true);
        wrap.selectedProperty.addListener((bool was, bool now) { ... });

    Clicking it goes from off to on and back. One that allows indeterminate goes, as JavaFX's does,
    from off to indeterminate to on and round again. Either way its action runs after.

    Its style class is "check-box", and its box is two parts, as JavaFX's is: `.box`, and `.mark`
    inside it, which the theme draws as a tick with shape. Its states are :selected,
    :indeterminate and :determinate, on top of ButtonBase's.
*/
class CheckBox : ButtonBase
{
public:
    this(string text = null)
    {
        super(text);
        styleClass.add("check-box");
        setAccessibleRole(AccessibleRole.checkBox);
        // The box, then the text, side by side from the left
        auto box = new Widget().styleClass("box").accessibleHidden(true);
        box.add(new Widget().styleClass("mark").accessibleHidden(true));
        setIndicator(box);
        pseudoClassStateChanged(pseudo!"determinate", true);
    }

    /// Whether it's ticked. JavaFX's selected.
    mixin(declareProperty!(bool, "selected", "false", q{
        pseudoClassStateChanged(pseudo!"selected", _selected);
        invalidateAccessible();
    }));

    /// Whether it's neither ticked nor not: some of what it stands for is, and some isn't.
    /// `selected` says nothing while it is. JavaFX's indeterminate.
    mixin(declareProperty!(bool, "indeterminate", "false", q{
        pseudoClassStateChanged(pseudo!"indeterminate", _indeterminate);
        pseudoClassStateChanged(pseudo!"determinate", !_indeterminate);
        invalidateAccessible();
    }));

    /// Whether clicking it goes through indeterminate as well. JavaFX's allowIndeterminate.
    mixin(declareProperty!(bool, "allowIndeterminate", "false"));

    /// Moves it on a step, as a click does, then runs its action. JavaFX's fire().
    override void fire()
    {
        if (disabled)
            return;
        if (_allowIndeterminate)
        {
            if (!_selected && !_indeterminate)
                setIndeterminate(true);
            else if (_selected && !_indeterminate)
                setSelected(false);
            else
            {
                setSelected(true);
                setIndeterminate(false);
            }
        }
        else
        {
            setSelected(!_selected);
            setIndeterminate(false);
        }
        super.fire();
    }

protected:
    override void describeAccessible(ref AccessibleNode node)
    {
        super.describeAccessible(node);
        if (_indeterminate)
            node.mixed();
        else
            node.toggled(_selected);
    }
}
