import std.format : format;
import mayfair;

void main()
{
    // An installed family by name. One that isn't installed falls back to the default font.
    auto sans = font("DejaVu Sans", 18);

    // A 2x2 grid in flexbox terms: a column of two rows, each holding two boxes. grow() makes the
    // boxes in each row share its width equally; the rows are taller together than the window,
    // so there's something to scroll.
    static immutable Colour[4] colours = [Colour(243, 139, 168), Colour(166, 227, 161),
                                          Colour(137, 180, 250), Colour(249, 226, 175)];
    static immutable string[4] captions = ["Affinity fjord VAV", "Waltz, quick jinx!",
                                           "Ligatures: fi fl ffi", "Fallback: 漢字 ∑ ➜"];

    static immutable Colour ink = Colour(24, 24, 37); // dark, to read against the pastel boxes

    auto content = new Column().padding(16).spacing(16);
    foreach (r; 0 .. 2) {
        auto row = new Row().spacing(16).prefHeight(220);
        foreach (c; 0 .. 2) {
            auto i = r * 2 + c;
            row.add(new Box(colours[i]).add(new Label(captions[i]).font(sans).textFill(ink)));
        }
        content.add(row);
    }
    // No font given: the default, at the theme's text size
    content.add(new Label("The default font, at Theme.text_size"));

    // Wrapping: to the window's width, so narrow the window to see it rewrap. Mixed-direction
    // text wraps too, each line in its own order.
    content.add(new Label("Labels wrap when they're told to, breaking where the text allows: after "
        ~ "spaces, around CJK like 漢字漢字漢字, at hyphens. Mixed text wraps in its own order too, "
        ~ "so שלום עולם, זהו טקסט in the middle of a sentence stays where it belongs.").wrapText(true));

    // A text field, and a button that's disabled for as long as the field is empty: one binding,
    // no handlers. Enter in the field greets too, since it has an action of its own.
    auto status = new Label("Not clicked yet");
    auto name = new TextField().promptText("Your name");
    auto greet = new Button("Greet");
    greet.disableProperty.bind(name.textProperty.isEmpty);
    void sayHello() { status.setText("Hello, " ~ name.text); }
    greet.setOnAction(&sayHello);
    name.setOnAction(&sayHello);
    content.add(new Row().spacing(12).alignment(Pos.centerLeft).fillHeight(false)
        .add(new Label("Name")).add(name).add(greet));

    // The count is a property, and the status label follows it through a binding rather than
    // being set by each button. "Click me" is the default button, so Enter presses it wherever
    // focus is (except in the name field, which has its own action); Escape presses the cancel one.
    auto clicks = new Property!int(0);
    auto clickMe = new Button("Click me").defaultButton(true)
        .onAction({ clicks.set(clicks.get + 1); });
    clicks.addListener((int was, int now) {
        status.setText(now ? format!"Clicked %d times"(now) : "Not clicked yet");
    });
    auto toggle = new Button("Disable it");
    toggle.setOnAction({
        clickMe.setDisable(!clickMe.disable);
        toggle.setText(clickMe.disable ? "Enable it" : "Disable it");
    });
    content.add(new Row().spacing(12).alignment(Pos.centerLeft).fillHeight(false)
        .add(clickMe)
        .add(new Button("Reset").cancelButton(true).onAction({ clicks.set(0); }))
        .add(toggle)
        .add(status));

    // Toggles: check boxes, a radio group, and a toggle button. The status says what changed.
    auto wrapBox = new CheckBox("Wrap lines").selected(true);
    auto mixed = new CheckBox("Some of these").allowIndeterminate(true).indeterminate(true);
    auto size = new ToggleGroup;
    auto small = new RadioButton("Small").toggleGroup(size);
    auto medium = new RadioButton("Medium").toggleGroup(size).selected(true);
    auto large = new RadioButton("Large").toggleGroup(size);
    size.selectedToggleProperty.addListener((ToggleButton was, ToggleButton now) {
        status.setText("Size: " ~ (now ? now.text : "none"));
    });
    auto bold = new ToggleButton("Bold").onAction({ status.setText("Bold toggled"); });
    content.add(new Row().spacing(16).alignment(Pos.centerLeft).fillHeight(false)
        .add(wrapBox).add(mixed).add(small).add(medium).add(large).add(bold));

    // A slider driving a progress bar, and one that doesn't know how far it's got
    auto amount = new Slider(0, 100, 40);
    auto progress = new ProgressBar(0.4);
    amount.valueProperty.addListener((double was, double now) { progress.setProgress(now / 100); });
    content.add(new Row().spacing(16).alignment(Pos.centerLeft).fillHeight(false)
        .add(amount).add(progress).add(new ProgressBar()));

    // Icons from the desktop's theme, symbolic ones in the text's colour -- white on the default
    // button -- a full-colour one as it is, and a Lottie animation, playing as soon as it's shown.
    // The spinner's ring is a colour slot, which the stylesheet sets to the accent, light or dark.
    auto spinner = new LottieView(Image.fromData(import("spinner.json"), "spinner.json"))
        .fitWidth(32).preserveRatio(true).style("--lottie-ring: var(--accent);");
    auto pauseSpinner = new ToggleButton("Pause").graphic(new Icon("media-playback-pause-symbolic"));
    pauseSpinner.setOnAction({
        if (pauseSpinner.selected)
            spinner.animation.pause();
        else
            spinner.animation.play();
    });
    content.add(new Row().spacing(12).alignment(Pos.centerLeft).fillHeight(false)
        .add(new Button("Save").graphic(new Icon("document-save-symbolic")))
        .add(new Button("Copy").graphic(new Icon("edit-copy-symbolic")))
        .add(new Button().graphic(new Icon("edit-find-symbolic")).accessibleText("Search"))
        .add(new Icon("folder").iconSize(32))
        .add(spinner)
        .add(pauseSpinner));

    // A text area that wraps, a few lines tall
    content.add(new TextArea("A text area holds several lines. This one wraps them to its width, "
        ~ "and scrolls when there are more than fit.\n\nEnter starts a new paragraph; Tab types a "
        ~ "tab, and Ctrl+Tab moves on.").wrapText(true).prefRowCount(4));

    auto app = new App("Freds new app");
    // All of it scrolls, down only: fitToWidth keeps it the window's width
    app.scene = new Scene(new ScrollPane(content).fitToWidth(true));
    app.run();
}

/// A rounded rectangle of one colour, with whatever it's given centred inside it.
class Box : Column
{
    this(Colour colour)
    {
        this.colour = colour;
        setGrow(1);
        setAlignment(Pos.center);
        setFillWidth(false);
    }

protected:
    override void mounted() nothrow
    {
        tvg_shape_set_fill_color(shape, colour.tupleof);
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        tvg_shape_append_rect(shape, x, y, w, h, 12, 12, true);
    }

private:
    Colour colour;
}
