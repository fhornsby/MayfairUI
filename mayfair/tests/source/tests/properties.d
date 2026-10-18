module tests.properties;

import core.thread : Thread;
import core.time : msecs;
import std.math : abs;
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
            d.expect(b.minX - box.parent.boundsInScene.minX, 10f, "a margin moves it in");
        });

        d.ui({ row.setAlignment(Pos.centre); row.setPadding(Insets(0, 0, 0, 0)); });
        d.settle();
        d.ui({
            const r = row.boundsInScene, c = child.boundsInScene;
            d.expect(c.centreX, r.centreX, "centred across the row");
            d.expect(c.centreY, r.centreY, "and down it");
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

/// Controls keep their preferred size in a Row or Column, as in JavaFX, and containers fill; a max
/// changes either.
void preferredSizes()
{
    Column root;
    Button button, wide;
    Label label;
    TextField field;
    Widget plain;
    Row row;
    Button inRow, growing, growingWide;
    Widget filler, short_, narrow;
    run("properties: controls keep their preferred size", {
        root = new Column();
        button = new Button("Short");
        wide = new Button("Wide").maxWidth(float.infinity);
        label = new Label("A label");
        field = new TextField();
        plain = new Widget().prefSize(50, 20);
        inRow = new Button("In a row");
        growing = new Button("Grows").grow(1);
        growingWide = new Button("Grows wide").grow(1).maxWidth(float.infinity);
        filler = new Widget().prefWidth(10);
        short_ = new Widget().prefWidth(10).maxHeight(30);
        narrow = new Widget().prefHeight(10).maxWidth(100);
        row = new Row().prefHeight(80).alignment(Pos.centreLeft);
        row.add(inRow).add(growing).add(growingWide).add(filler).add(short_);
        root.add(button).add(wide).add(label).add(field).add(plain).add(row).add(narrow);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            const r = root.boundsInScene;
            d.check(button.boundsInScene.width < r.width, "a button keeps its own width in a column");
            d.expect(button.boundsInScene.minX, r.minX, "at the column's alignment");
            d.check(label.boundsInScene.width < r.width, "so does a label");
            d.expect(wide.boundsInScene.width, r.width, "unless its max is raised");
            d.expect(field.boundsInScene.width, r.width, "a text field stretches along the line");
            d.expect(plain.boundsInScene.width, r.width, "a plain widget fills, whatever its pref");
            d.expect(plain.boundsInScene.height, 20f, "and keeps its pref down the column");
            d.expect(row.boundsInScene.width, r.width, "so does a row");

            const rb = row.boundsInScene, b = inRow.boundsInScene;
            d.check(b.height < rb.height, "a button keeps its own height in a row");
            d.check(abs(b.centreY - rb.centreY) <= 0.5, "at the row's alignment, to the pixel");
            d.expect(filler.boundsInScene.height, rb.height, "while a plain widget fills it");
            d.check(growing.boundsInScene.width < 150, "a growing button stays its width");
            d.check(growingWide.boundsInScene.width > 200, "unless its max is raised");

            const s = short_.boundsInScene;
            d.expect(s.height, 30f, "stretching stops at the max");
            d.check(abs(s.centreY - rb.centreY) <= 0.5, "and it sits at the row's alignment");
            d.expect(narrow.boundsInScene.width, 100f, "the same down a column");
            d.expect(narrow.boundsInScene.minX, r.minX, "at its start");
        });

        d.ui({ root.setAlignment(Pos.topRight); });
        d.settle();
        d.ui({
            d.expect(narrow.boundsInScene.maxX, root.boundsInScene.maxX, "or its end");
            d.expect(button.boundsInScene.maxX, root.boundsInScene.maxX, "with the controls");
        });
        d.ui({ root.setAlignment(Pos.topLeft); });

        // Changing a max, or fill, while it's showing
        d.ui({ button.setMaxWidth(float.infinity); row.setFillHeight(false); });
        d.settle();
        d.ui({
            d.expect(button.boundsInScene.width, root.boundsInScene.width, "a raised max, while showing");
            d.check(filler.boundsInScene.height < row.boundsInScene.height, "fill off: nothing stretches");
        });
        d.ui({ button.setMaxWidth(Widget.useComputedSize); row.setFillHeight(true); });
        d.settle();
        d.ui({
            d.check(button.boundsInScene.width < root.boundsInScene.width, "and back to its own width");
            d.expect(filler.boundsInScene.height, row.boundsInScene.height, "and fill back on");
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
        d.move(bb.centreX, bb.centreY);
        d.move(bb.maxX + 50, bb.maxY + 50);
        d.ui({ d.expect(hovers, [true, false], "hover heard going on and off"); });
        d.move(bb.centreX, bb.centreY);
        d.press(bb.centreX, bb.centreY);
        d.ui({ d.check(b.armed && b.armedProperty.get, "armed while held down"); });
        d.release(bb.centreX, bb.centreY);
        d.ui({ d.check(!b.armed, "not once let go"); });
    });
}

/// The scene's root is the window's size whatever it's set to, and a control won't take children.
void rootAndAdd()
{
    Column root;
    run("properties: the root fills the window; controls keep their children", {
        root = new Column();
        return cast(Widget) root;
    }, (Driver d) {
        float w, h;
        d.ui({ w = root.boundsInScene.width; h = root.boundsInScene.height; });
        d.ui({ root.setPrefWidth(100); root.setMaxHeight(50); root.setGrow(1); });
        d.settle();
        d.ui({
            d.expect(root.boundsInScene.width, w, "the root keeps the window's width");
            d.expect(root.boundsInScene.height, h, "and its height");
        });
        d.ui({
            import std.exception : collectException;
            foreach (control; [cast(Widget) new Label("x"), new Button("x"), new ScrollPane(), new TextField()])
                d.check(collectException(control.add(new Widget)) !is null, typeid(control).name ~ " refuses add()");
            d.check(collectException(new Column().add(new Widget)) is null, "a container takes children");
        });
    });
}

/// A new root for the scene, from a button in the old one, and back again, the old one as it was.
void changingRoot()
{
    Column first, second;
    Button go, back;
    CheckBox kept;
    int backs;
    run("properties: a scene's root changed, and changed back", {
        first = new Column().spacing(8).padding(10);
        kept = new CheckBox("Kept");
        go = new Button("Go");
        first.add(kept).add(go);
        second = new Column().padding(10);
        back = new Button("Back").onAction({ backs++; second.scene.setRoot(first); });
        second.add(back);
        go.setOnAction({ go.scene.setRoot(second); });
        return cast(Widget) first;
    }, (Driver d) {
        float w;
        d.ui({ w = first.boundsInScene.width; });
        d.click(kept);
        d.click(go);
        d.ui({
            d.check(second.scene !is null && second.scene.root is second, "the button's handler made the other its root");
            d.check(first.scene is null, "and the old one's out of the window");
            d.check(!go.pressed && !go.hover, "not pressed or hovered any more");
            d.expect(second.boundsInScene.width, w, "the new one fills the window");
            d.check(second.styleClass.contains("root") && !first.styleClass.contains("root"), "and is .root now");
        });
        d.click(back);
        d.ui({
            d.expect(backs, 1, "its button works");
            d.check(first.scene !is null && first.scene.root is first, "and puts the first back");
            d.check(kept.selected, "as it was left");
            d.expect(first.boundsInScene.width, w, "filling the window again");
        });
        d.click(go);
        d.ui({ d.check(second.scene !is null, "and it goes there again"); });
        d.ui({
            import std.exception : collectException;
            d.check(collectException(second.scene.setRoot(kept)) !is null, "a widget below another can't be a root");
        });
    });
}
