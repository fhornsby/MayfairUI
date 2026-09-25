import core.stdc.stdlib : exit;
import std.stdio : writefln;
import harness;
static import tests.buttons, tests.focus, tests.textinput, tests.textfield, tests.properties;

/*
    Runs every end-to-end test, one window at a time, and exits non-zero if any failed.

        cd tests && dub run
*/
void main(string[] args)
{
    if (args.length > 1 && args[1] == "--accessibility-app")
        return accessibilityApp(); // for accessibility/run.sh, which checks it from outside

    tests.buttons.clicking();
    tests.focus.keyboardDisableRemove();
    tests.textinput.textAndDrawOrder();
    tests.textfield.editing();
    tests.textfield.undoRedo();
    tests.textfield.mouse();
    tests.textfield.rightToLeft();
    tests.properties.bindings();
    tests.properties.textFieldText();
    tests.properties.layout();
    tests.properties.readOnly();

    writefln("%s passed, %s failed checks", passedCount, failedChecks);
    exit(failedChecks ? 1 : 0);
}

/// A window for accessibility/check.py to inspect over AT-SPI: stays up until it's killed.
void accessibilityApp()
{
    import mayfair;
    auto root = new Column().padding(16).spacing(12).fillWidth(false);
    auto status = new Label("Not pressed");
    auto button = new Button("Press me");
    button.onAction({ status.setText("Pressed"); });
    auto disabled = new Button("Disabled").disable(true);
    root.add(status).add(button).add(disabled).add(new TextField("abc שלום def"));
    auto app = new App("accessibility check");
    app.scene = new Scene(root);
    app.run();
}
