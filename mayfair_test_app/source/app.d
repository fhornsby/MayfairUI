import std.format : format;
import mayfair;

void main()
{
    // An installed family by name. One that isn't installed falls back to the default font.
    auto sans = font("DejaVu Sans", 18);

    // A 2x2 grid in flexbox terms: a column of two rows, each holding two boxes. grow() makes the
    // rows, and the boxes in each row, share the space equally.
    static immutable Colour[4] colours = [Colour(243, 139, 168), Colour(166, 227, 161),
                                          Colour(137, 180, 250), Colour(249, 226, 175)];
    static immutable string[4] captions = ["Affinity fjord VAV", "Waltz, quick jinx!",
                                           "Ligatures: fi fl ffi", "Fallback: 漢字 ∑ ➜"];

    static immutable Colour ink = Colour(24, 24, 37); // dark, to read against the pastel boxes

    auto content = new Column().padding(16).spacing(16);
    foreach (r; 0 .. 2) {
        auto row = new Row().spacing(16).grow(1);
        foreach (c; 0 .. 2) {
            auto i = r * 2 + c;
            row.add(new Box(colours[i]).add(new Label(captions[i]).font(sans).textFill(ink)));
        }
        content.add(row);
    }
    // No font given: the default, at the theme's text size
    content.add(new Label("The default font, at Theme.text_size"));

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

    auto app = new App("Freds new app");
    app.scene = new Scene(content);
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
