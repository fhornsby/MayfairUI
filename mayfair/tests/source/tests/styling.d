module tests.styling;

import core.thread : Thread;
import core.time : msecs;
import std.format : format;
import harness;
import mayfair;

private enum red = Colour(255, 0, 0), blue = Colour(0, 0, 255), green = Colour(0, 128, 0);

/// The cascade: which declaration wins, by origin, specificity and !important, and what code can
/// and can't override; inline styles; a class going leaving its property as it started.
void cascade()
{
    Label plain, special, coded, inlined, important;
    run("styling: the cascade", {
        auto root = new Column().fillWidth(false);
        plain = new Label("plain").styleClass("item");
        special = new Label("special").styleClass("item", "special");
        coded = new Label("coded").styleClass("item");
        coded.setTextFill(green);
        inlined = new Label("inlined").styleClass("item").style("colour: #0000ff");
        important = new Label("important").styleClass("item", "special").style("colour: #0000ff");
        root.add(plain).add(special).add(coded).add(inlined).add(important);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            // Parsed at runtime; the other tests' are compiled in
            plain.scene.stylesheets.add(Stylesheet.parse(`
                .item { colour: red; }
                .item.special { colour: #008000; }
                Label.special.item { colour: #00ff00 !important; }
            `));
        });
        d.settle();
        d.ui({
            d.expect(plain.textFill, red, "a class's rule");
            d.expect(special.textFill, Colour(0, 255, 0), "the more specific rule, and !important");
            d.expect(coded.textFill, red, "an app's stylesheet beats code, as in JavaFX");
            d.expect(inlined.textFill, blue, "an inline style beats the stylesheet");
            d.expect(important.textFill, Colour(0, 255, 0), "but not its !important");
        });

        d.ui({ plain.styleClass.remove("item"); });
        d.settle();
        d.ui({ d.expect(plain.textFill, Theme.text_colour, "no rule now: back to how it started"); });

        // Code after a stylesheet has set it: code's, until the stylesheet next applies
        d.ui({ plain.setTextFill(green); });
        d.settle();
        d.ui({ d.expect(plain.textFill, green, "set from code, with nothing to override it"); });
    });
}

/// States: :hover, and one on an ancestor reaching the widgets below it.
void states()
{
    Label item, inner;
    Row box;
    run("styling: pseudo-classes", {
        auto root = new Column().fillWidth(false).spacing(20).padding(20);
        item = new Label("hover me").styleClass("item");
        inner = new Label("inside");
        box = new Row().styleClass("box").padding(10);
        box.add(inner);
        root.add(item).add(box);
        root.stylesheets.add(stylesheet!(`
            .item:hover { colour: red; }
            .box:hover .label, .box:hover Label { colour: blue; }
        `));
        return cast(Widget) root;
    }, (Driver d) {
        Bounds b;
        d.ui({ b = item.boundsInScene; });
        d.move(b.centreX, b.centreY);
        d.ui({ d.expect(item.textFill, red, ":hover while the pointer's over it"); });
        d.move(b.maxX + 300, b.centreY);
        d.ui({ d.expect(item.textFill, Theme.text_colour, "and not after"); });

        d.ui({ b = box.boundsInScene; });
        d.move(b.minX + 3, b.minY + 3); // over the box, not the label
        d.ui({ d.expect(inner.textFill, blue, "a state of an ancestor's, in a descendant selector"); });
        d.move(b.maxX + 300, b.centreY);
        d.ui({ d.expect(inner.textFill, Theme.text_colour, "and off again"); });
    });
}

/// Looked-up colours from the widget upwards, derive(), inherited fonts, and layout from CSS.
void lookups()
{
    Label derived, overridden, sized, big;
    Row row;
    Widget a, b;
    run("styling: looked-up colours, inheritance, layout", {
        auto root = new Column().fillWidth(false);
        derived = new Label("derived").styleClass("tinted");
        auto blueArea = new Column().styleClass("blue-area");
        overridden = new Label("overridden").styleClass("tinted");
        blueArea.add(overridden);
        sized = new Label("inherits");
        auto bigArea = new Column().style("font-size: 30");
        big = new Label("big");
        bigArea.add(big);
        a = new Widget().prefSize(10, 10);
        b = new Widget().prefSize(10, 10);
        row = new Row().styleClass("spaced");
        row.add(a).add(b);
        root.add(derived).add(blueArea).add(sized).add(bigArea).add(row);
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            derived.scene.stylesheets.add(stylesheet!(`
                .root { --accent: #ff0000; font-size: 18px; }
                .blue-area { --accent: #0000ff; }
                .tinted { colour: derive(var(--accent), -50%); }
                .spaced { gap: 25; padding: 5 7; }
            `));
        });
        d.settle();
        d.ui({
            d.expect(derived.textFill, Colour(128, 0, 0), "derive() of the root's looked-up colour");
            d.expect(overridden.textFill, Colour(0, 0, 128), "looked up from the widget upwards: its area's own");
            d.expect(sized.font.size, 18f, "a font size inherited from the root");
            d.expect(big.font.size, 30f, "and from the nearest that sets one");
            d.expect(row.spacing, 25f, "gap");
            d.expect(b.boundsInScene.minX - a.boundsInScene.maxX, 25f, "laid out with it");
            d.expect(a.boundsInScene.minX - row.boundsInScene.minX, 7f, "and padding");
        });
    });
}

/// The built-in theme: a button's states, and recolouring the whole kit from one rule.
void theme()
{
    Button plain, preferred, off;
    run("styling: the built-in theme", {
        auto root = new Column().fillWidth(false).spacing(8).padding(10);
        plain = new Button("Plain");
        preferred = new Button("Default").defaultButton(true);
        off = new Button("Off").disable(true);
        root.add(plain).add(preferred).add(off);
        return cast(Widget) root;
    }, (Driver d) {
        Colour fill(Button b) { return b.background.fills[$ - 1].fill; }
        void done() { Thread.sleep(200.msecs); d.settle(); } // the theme's transitions, finished
        d.ui({
            d.expect(fill(plain), Colour(0x33, 0x41, 0x55), "a button, at rest");
            d.expect(fill(preferred), Colour(0x02, 0x84, 0xc7), "a default button, in its own palette");
            d.expect(off.opacity, 0.4f, "a disabled one, faded");
            d.expect(plain.background.fills[0].fill, Colour(0, 0, 0, 0), "no ring without focus");
        });

        Bounds b;
        d.ui({ b = plain.boundsInScene; });
        d.move(b.centreX, b.centreY);
        done();
        d.ui({ d.expect(fill(plain), Colour(0x47, 0x55, 0x69), ":hover"); });
        d.press(b.centreX, b.centreY);
        done();
        d.ui({
            d.expect(fill(plain), Colour(0x1e, 0x29, 0x3b), ":armed");
            d.expect(plain.scaleX, 0.96f, "and pushed in");
        });
        d.release(b.centreX, b.centreY);
        d.move(b.maxX + 300, b.centreY);
        done();
        d.ui({ d.expect(plain.scaleX, 1f, "and back out"); });

        // The click focused it, without a ring; Tab moves on to the next, and it has one
        d.key(SDL_Keycode.SDLK_TAB);
        done();
        d.ui({
            d.expect(plain.background.fills[0].fill, Colour(0, 0, 0, 0), "no ring for focus from a click");
            d.expect(preferred.background.fills[0].fill, Colour(0x38, 0xbd, 0xf8), "a ring when the keyboard gets there");
        });

        d.ui({ plain.scene.stylesheets.add(stylesheet!(`.root { --base: #7f1d1d; }`)); });
        done();
        d.settle();
        d.ui({
            d.expect(fill(plain), Colour(0x7f, 0x1d, 0x1d), "an app's .root recolours the kit");
            d.expect(fill(preferred), Colour(0x02, 0x84, 0xc7), "but not a default button's own palette");
        });
    });
}

/// CSS transitions: a state change moves there over time, code cuts it short, and the first
/// styling doesn't animate at all.
void transitions()
{
    Label item;
    run("styling: transitions", {
        auto root = new Column().fillWidth(false).padding(20);
        item = new Label("fade me").styleClass("fading");
        root.add(item);
        root.stylesheets.add(stylesheet!(`
            .fading { colour: #000000; opacity: 0.5; transition: colour 400ms linear; }
            .fading:hover { colour: #ffffff; opacity: 1; }
        `));
        return cast(Widget) root;
    }, (Driver d) {
        d.ui({
            d.expect(item.textFill, Colour(0, 0, 0), "styled at once the first time: nothing to move from");
            d.expect(item.opacity, 0.5f, "");
        });
        Bounds b;
        d.ui({ b = item.boundsInScene; });
        d.move(b.centreX, b.centreY);
        d.ui({
            d.check(item.textFill.r < 200, "a transition starts on its way, not there");
            d.expect(item.opacity, 1f, "a property with no transition changes at once");
        });
        Thread.sleep(200.msecs);
        d.settle();
        d.ui({
            const r = item.textFill.r;
            d.check(r > 60 && r < 200, format!"half way through, half way there: %s"(r));
        });
        Thread.sleep(300.msecs);
        d.settle();
        d.ui({ d.expect(item.textFill, Colour(255, 255, 255), "and there at the end"); });

        // Back again, and code setting it part way cuts the transition off
        d.move(b.maxX + 300, b.centreY);
        Thread.sleep(100.msecs);
        d.ui({ item.setTextFill(Colour(255, 0, 0)); });
        Thread.sleep(400.msecs);
        d.settle();
        d.ui({ d.expect(item.textFill, Colour(255, 0, 0), "set from code, and left there"); });
    });
}

/// Light and dark: the theme's two palettes, switched by the scene's colour scheme.
void colourSchemes()
{
    Button button;
    Label label;
    run("styling: light and dark", {
        auto root = new Column().fillWidth(false).padding(10);
        button = new Button("Button");
        label = new Label("Label");
        root.add(button).add(label);
        return cast(Widget) root;
    }, (Driver d) {
        Colour fill() { return button.background.fills[$ - 1].fill; }
        d.ui({
            d.expect(fill(), Colour(0x33, 0x41, 0x55), "dark: the harness asks for it");
            d.expect(label.textFill, Colour(0xe2, 0xe8, 0xf0), "");
            d.expect(button.scene.root.background.fills[0].fill, Colour(0x0f, 0x17, 0x2a), "and the root's background");
        });
        d.ui({ button.scene.setColourScheme(ColourScheme.light); });
        Thread.sleep(200.msecs); // the button's colours transition
        d.settle();
        d.ui({
            d.expect(fill(), Colour(0xe2, 0xe8, 0xf0), "light");
            d.expect(label.textFill, Colour(0x0f, 0x17, 0x2a), "");
            d.expect(button.scene.root.background.fills[0].fill, Colour(0xf8, 0xfa, 0xfc), "");
        });
    });
}
