module mayfair.widgets.button;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.widgets.buttonbase;
import mayfair.widgets.layouts : Pos;
import mayfair.widgets.input;
import mayfair.widgets.styling;
import mayfair.widgets.widget;

/*
    A push button: some text on a rounded rectangle, which runs its action when clicked.

        new Button("Save").onAction({ save(); })

    Pressing it is ButtonBase's, and JavaFX's. Enter doesn't press the focused button, as JavaFX's
    doesn't -- it presses the default button, wherever focus is, and Escape presses the cancel
    button. Those are what a dialog's OK and Cancel are.

    How it looks is the stylesheet's: its style class is "button", and besides ButtonBase's states
    it has :default and :cancel for those buttons. The theme darkens and shrinks it slightly while
    it's armed, so it looks pushed in, and puts a ring round it when focus reaches it by keyboard.
    A button pressed by Enter or Escape is armed for a moment, so it looks pressed too.
*/
class Button : ButtonBase
{
public:
    this(string text = null)
    {
        super(text);
        styleClass.add("button");
        setAccessibleRole(AccessibleRole.button);
        setAlignment(Pos.centre); // its text in the middle, as a button's is
    }

    /// Whether this is the button Enter presses, wherever focus is. The theme draws it in the accent colour.
    mixin(declareProperty!(bool, "defaultButton", "false", q{ pseudoClassStateChanged(pseudo!"default", _defaultButton); }));

    /// Whether this is the button Escape presses, wherever focus is.
    mixin(declareProperty!(bool, "cancelButton", "false", q{ pseudoClassStateChanged(pseudo!"cancel", _cancelButton); }));

protected:
    override void handleShortcut(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed || event.repeat)
            return;
        const enter = event.code == KeyCode.enter || event.code == KeyCode.numpadEnter;
        if ((enter && _defaultButton) || (event.code == KeyCode.escape && _cancelButton))
        {
            event.consume();
            flashAndFire();
        }
    }
}
