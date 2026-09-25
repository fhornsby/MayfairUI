module tests.properties;

import core.thread : Thread;
import core.time : msecs;
import std.format : format;
import harness;
import mayfair;

private enum ctrl = SDL_Keymod.KMOD_LCTRL;

/// Bindings driving what's on screen: a button enabled only while a field has text, and a label
/// following a count through map().
void bindings()
{
    TextField name;
    Button greet;
    Label counter;
    Property!int count;
    int greeted;
    run("properties: bindings in a live window", {
        auto root = new Column().fillWidth(false).spacing(8);
        name = new TextField();
        greet = new Button("Greet").onAction({ greeted++; });
        greet.disableProperty.bind(name.textProperty.isEmpty);
        count = new Property!int(0);
        counter = new Label("");
        counter.textProperty.bind(count.map((int n) => format!"%d so far"(n)));
        root.add(name).add(greet).add(counter);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            d.check(greet.disabled, "disabled while the field is empty");
            d.expect(counter.text, "0 so far", "the label starts from the binding");
        });
        d.click(greet);
        d.ui({ d.expect(greeted, 0, "a disabled button can't be clicked"); });

        d.key(SDL_Keycode.SDLK_TAB);
        d.type("Ada");
        d.ui({ d.check(!greet.disabled, "enabled once there's text"); });
        d.click(greet);
        d.ui({ d.expect(greeted, 1, "and then it can be"); });

        d.click(name);
        d.key(SDL_Keycode.SDLK_A, ctrl);
        d.key(SDL_Keycode.SDLK_BACKSPACE);
        d.ui({ d.check(greet.disabled, "disabled again when the text's deleted"); });

        float before;
        d.ui({ before = counter.boundsInScene.width; count.set(12345); });
        d.settle();
        d.ui({
            d.expect(counter.text, "12345 so far", "the label follows the count");
            d.check(counter.boundsInScene.width > before, "and is laid out again for its longer text");
        });
    });
}

/// A text field's text property: listened to, it hears typing; bound, the field can't be typed into.
void textFieldText()
{
    TextField field;
    Property!string source;
    string[] heard;
    run("properties: a text field's text", {
        auto root = new Column().fillWidth(false);
        field = new TextField("start");
        field.textProperty.addListener((string was, string now) { heard ~= now; });
        source = new Property!string("from a binding");
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        d.key(SDL_Keycode.SDLK_TAB);
        d.type("a");
        d.type("b");
        d.ui({ d.expect(heard, ["a", "ab"], "a listener hears each change as it's typed"); });

        d.ui({ field.textProperty.bind(source); });
        d.settle();
        d.type("typed");
        d.ui({
            d.expect(field.text, "from a binding", "a bound field shows its source and can't be typed into");
            source.set("changed");
        });
        d.ui({ d.expect(field.text, "changed", "and follows it"); });

        d.ui({ field.textProperty.unbind(); });
        d.key(SDL_Keycode.SDLK_END);
        d.type("!");
        d.ui({ d.expect(field.text, "changed!", "unbound, it can be typed into again"); });
    });
}

/// Layout properties set while the window's up, and a Timeline animating one with a KeyValue.
void layout()
{
    Widget box, child;
    Row row;
    Widget tail;
    Timeline slide;
    run("properties: layout, and animating it", {
        auto root = new Column().fillWidth(false);
        box = new Widget().prefSize(100, 40);
        row = new Row().fillHeight(false);
        child = new Widget().prefSize(20, 20);
        tail = new Widget().prefSize(10, 10);
        row.prefSize(200, 60).add(child);
        root.add(box).add(row).add(tail);
        slide = new Timeline(KeyFrame(150.msecs, KeyValue(box.prefWidthProperty, 300f, Interpolator.easeOut)));
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({ d.expect(box.boundsInScene.width, 100f, "the width it asked for"); });

        d.ui({ box.setPrefWidth(150); box.setMargin(Insets(10)); });
        d.settle();
        d.ui({
            const b = box.boundsInScene;
            d.expect(b.width, 150f, "a new width, while it's showing");
            d.expect(b.minX, 10f, "a margin moves it in");
        });

        d.ui({ row.setAlignment(Pos.center); row.setPadding(Insets(0, 0, 0, 0)); });
        d.settle();
        d.ui({
            const r = row.boundsInScene, c = child.boundsInScene;
            d.expect(c.centerX, r.centerX, "centred across the row");
            d.expect(c.centerY, r.centerY, "and down it");
        });

        d.ui({ row.setAlignment(Pos.bottomRight); });
        d.settle();
        d.ui({
            const r = row.boundsInScene, c = child.boundsInScene;
            d.expect(c.maxX, r.maxX, "right");
            d.expect(c.maxY, r.maxY, "bottom");
        });

        d.ui({ slide.play(); });
        Thread.sleep(400.msecs);
        d.settle();
        d.ui({
            d.expect(box.prefWidth, 300f, "the Timeline moved the property to its KeyValue");
            d.expect(box.boundsInScene.width, 300f, "and the layout followed");
        });
    });
}

/// Read-only properties report what's happening, and can't be set from outside.
void readOnly()
{
    Button b;
    bool[] hovers;
    run("properties: read-only state", {
        auto root = new Column().fillWidth(false);
        b = new Button("Hover me");
        b.hoverProperty.addListener((bool was, bool now) { hovers ~= now; });
        root.add(b);
        static assert(!__traits(compiles, b.hoverProperty.set(true)));
        return cast(Widget) root;
    }, (Driver d) {
        Bounds bb;
        d.ui({ bb = b.boundsInScene; });
        d.move(bb.centerX, bb.centerY);
        d.move(bb.maxX + 50, bb.maxY + 50);
        d.ui({ d.expect(hovers, [true, false], "hover heard going on and off"); });
        d.move(bb.centerX, bb.centerY);
        d.press(bb.centerX, bb.centerY);
        d.ui({ d.check(b.armed && b.armedProperty.get, "armed while held down"); });
        d.release(bb.centerX, bb.centerY);
        d.ui({ d.check(!b.armed, "not once let go"); });
    });
}
