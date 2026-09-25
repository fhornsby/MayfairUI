import std.stdio;
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

    auto content = new Column().padding(16).gap(16);
    foreach (r; 0 .. 2) {
        auto row = new Row().grow(1).gap(16);
        foreach (c; 0 .. 2) {
            auto i = r * 2 + c;
            row.add(new Box(colours[i]).add(new Label(captions[i]).font(sans).colour(ink)));
        }
        content.add(row);
    }
    // No font given: the default, at the theme's text size
    content.add(new Label("The default font, at Theme.text_size").colour(Theme.text_colour));

    // Buttons, and a label they change. Setting the text re-lays out the row, since the label's width changes.
    auto status = new Label("Not clicked yet");
    int clicks;
    auto buttons = new Row().gap(12);
    YGNodeStyleSetAlignItems(buttons.node, YGAlignCenter);
    // Tab moves focus between them and Space presses the focused one. "Click me" is the default
    // button, so Enter presses it wherever focus is, and Escape presses the cancel button.
    auto clickMe = new Button("Click me").defaultButton(true)
        .onAction({ status.setText(format!"Clicked %d times"(++clicks)); });
    auto toggle = new Button("Disable it");
    toggle.onAction({
        clickMe.disable(!clickMe.disable);
        toggle.setText(clickMe.disable ? "Enable it" : "Disable it");
    });
    // A text field. Enter in it runs its own action; a field without one would pass Enter on to
    // "Click me", the default button.
    auto name = new TextField().promptText("Your name");
    name.onAction({ status.setText(name.text.length ? "Hello, " ~ name.text : "Not clicked yet"); });
    auto nameRow = new Row().gap(12);
    YGNodeStyleSetAlignItems(nameRow.node, YGAlignCenter);
    nameRow.add(new Label("Name").colour(Theme.text_colour));
    nameRow.add(name);
    content.add(nameRow);

    buttons.add(clickMe);
    buttons.add(new Button("Reset").cancelButton(true).onAction({ clicks = 0; status.setText("Not clicked yet"); }));
    buttons.add(toggle);
    buttons.add(status);
    content.add(buttons);

    auto app = new App("Freds new app");
    app.scene = new Scene(content);
    app.run();
}

/// A rounded rectangle of one colour, with whatever it's given centred inside it.
class Box : Widget
{
    this(Colour colour)
    {
        this.colour = colour;
        grow(1);
        YGNodeStyleSetJustifyContent(node, YGJustifyCenter);
        YGNodeStyleSetAlignItems(node, YGAlignCenter);
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
