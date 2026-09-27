import core.stdc.stdlib : exit;
import std.format : format;
import std.stdio : writefln;
import harness;
static import tests.buttons, tests.focus, tests.textinput, tests.textfield, tests.properties, tests.scrolling, tests.styling, tests.wrapping, tests.toggles, tests.controls, tests.images;

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
    tests.properties.preferredSizes();
    tests.properties.rootAndAdd();
    tests.properties.readOnly();
    tests.scrolling.wheel();
    tests.scrolling.keyboard();
    tests.scrolling.bars();
    tests.styling.cascade();
    tests.styling.states();
    tests.styling.lookups();
    tests.styling.theme();
    tests.styling.transitions();
    tests.styling.colourSchemes();
    tests.wrapping.labels();
    tests.toggles.checkBoxes();
    tests.toggles.radioGroup();
    tests.toggles.toggleButtons();
    tests.controls.sliders();
    tests.controls.progressBars();
    tests.controls.textAreas();
    tests.images.imageViews();
    tests.images.icons();
    tests.images.lottie();
    tests.images.lottieSlots();

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
    auto rows = new Column();
    foreach (i; 0 .. 15)
        rows.add(new Button(format!"Row %d"(i)));
    auto pane = new ScrollPane(rows).fitToWidth(true).prefSize(200, 120);
    root.add(status).add(button).add(disabled).add(new TextField("abc שלום def")).add(pane)
        .add(new CheckBox("Tick me").selected(true)).add(new RadioButton("Pick me"))
        .add(new TextArea("one\ntwo\nthree").prefRowCount(3)).add(new Slider(0, 100, 30)).add(new ProgressBar(0.5));
    auto app = new App("accessibility check");
    app.scene = new Scene(root);
    app.run();
}
