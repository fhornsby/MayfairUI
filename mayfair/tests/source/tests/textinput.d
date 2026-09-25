module tests.textinput;

import std.array : join;
import harness;
import mayfair;

/// A widget that takes text, keeping what it's given.
private class Recorder : Widget
{
    string[] typed, composed;
    this()
    {
        acceptsTextInput(true);
        focusTraversable(true);
        YGNodeStyleSetHeight(node, 30);
    }
protected:
    override void handleKey(ref KeyEvent e)
    {
        if (e.type == KeyEventType.typed)
        {
            typed ~= e.character;
            e.consume();
        }
    }
    override void handleInputMethod(ref InputMethodEvent e)
    {
        composed ~= e.composed;
        e.consume();
    }
}

private __gshared Tvg_Paint[64] order;
private __gshared size_t orderCount;
private extern(C) bool visit(Tvg_Paint p, void* data) nothrow @nogc
{
    if (orderCount < order.length)
        order[orderCount++] = p;
    return true;
}

/// Typed text and input method composition reach the widget with focus; SDL's text input is on
/// only while that widget wants it; a widget added to a live tree is drawn in its place.
void textAndDrawOrder()
{
    Widget root, row, box1, box2, box3;
    Recorder field;
    Button button;

    run("text input, input methods, draw order", {
        root = new Column();
        field = new Recorder;
        row = new Row();
        box1 = new Widget;
        box2 = new Widget;
        box3 = new Widget;
        button = new Button("B");
        row.add(box1);
        root.add(field).add(row).add(box2).add(button);
        return root;
    }, (Driver d) {
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.check(SDL_TextInputActive(d.window), "text input on for a widget that takes text"); });
        d.compose("ni", 2);
        d.compose("");
        d.type("你");
        d.type("a");
        d.ui({
            d.expect(field.typed.join("|"), "你|a", "typed");
            d.check(field.composed.length >= 2 && field.composed[$ - 2 .. $] == ["ni", ""],
                    "composition, then its end: " ~ field.composed.join("|"));
        });
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.check(!SDL_TextInputActive(d.window), "text input off again for a button"); });

        d.ui({ row.add(box3); });
        d.settle();
        d.ui({
            orderCount = 0;
            auto accessor = tvg_accessor_new();
            tvg_accessor_set(accessor, tvg_paint_get_parent(root.shape), &visit, null);
            tvg_accessor_del(accessor);
            string[] names;
            foreach (p; order[0 .. orderCount])
                foreach (w, name; [root: "root", row: "row", box1: "box1", box3: "box3", box2: "box2"])
                    if (p is w.shape)
                        names ~= name;
            d.expect(names.join(" "), "root row box1 box3 box2", "draw order after adding to an earlier row");
        });
    });
}
