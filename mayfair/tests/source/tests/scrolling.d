module tests.scrolling;

import std.format : format;
import std.math : abs;
import harness;
import mayfair;

/// A list taller than its pane: the wheel and a touchpad scroll it, what's scrolled out of view
/// can't be clicked, what's scrolled into it can, and the values follow.
void wheel()
{
    ScrollPane pane;
    Column list;
    Button[] items;
    int[] clicked;
    run("scroll pane: wheel, touchpad, clipping", {
        auto root = new Column().fillWidth(false).padding(20);
        list = new Column().spacing(8);
        foreach (i; 0 .. 20)
        {
            auto b = new Button(format!"Item %d"(i));
            // Each its own copy of i: a closure in a loop shares the loop's
            b.setOnAction(((int n) => delegate() { clicked ~= n; })(i));
            items ~= b;
            list.add(b);
        }
        pane = new ScrollPane(list).fitToWidth(true).prefSize(300, 200);
        root.add(pane);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds p, first;
        float yBelow;
        d.ui({
            p = pane.boundsInScene;
            first = items[0].boundsInScene;
            yBelow = items[5].boundsInScene.centerY;
            d.expect(first.minY, p.minY, "the list starts at the top of the pane");
            d.check(yBelow > p.maxY && yBelow < 480, format!"and goes on below it, in the window: %s"(yBelow));
            d.expect(list.boundsInScene.width, p.width, "fitToWidth: the list as wide as the pane");
        });

        // Item 5 is drawn below the pane, clipped: a click there doesn't reach it
        d.click(p.minX + 10, yBelow);
        d.ui({ d.expect(clicked.length, 0, "what's scrolled out of view can't be clicked"); });

        // A notch towards the user scrolls down by JavaFX's 40 points
        d.scroll(p.centerX, p.centerY, -1);
        d.ui({
            d.expect(items[0].boundsInScene.minY, first.minY - 40, "a notch is 40 points");
            d.check(pane.vvalue > 0, "and vvalue follows");
        });

        // A touchpad follows the fingers: SDL's 0.3 of a notch is 3 points
        float before;
        d.ui({ before = items[0].boundsInScene.minY; });
        d.scroll(p.centerX, p.centerY, -0.3f);
        d.ui({ d.check(abs(items[0].boundsInScene.minY - (before - 3)) <= 0.5, "a touchpad scrolls by its movement"); });

        // As far as it goes, and no further
        foreach (i; 0 .. 30)
            d.scroll(p.centerX, p.centerY, -1);
        d.ui({
            d.expect(pane.vvalue, 1f, "all the way down");
            d.expect(items[19].boundsInScene.maxY, p.maxY, "the last item at the bottom");
        });

        // What's in view now can be clicked where it's seen
        d.click(items[19]);
        d.ui({ d.expect(clicked, [19], "the scrolled item clicked where it shows"); });

        d.ui({ pane.setVvalue(0); });
        d.settle();
        d.ui({ d.expect(items[0].boundsInScene.minY, p.minY, "vvalue back to 0 scrolls back to the top"); });
    });
}

/// Tab to something out of view and it's scrolled into view; Page Down pages; and scrollIntoView(),
/// which a screen reader asks for, does the same as Tab.
void keyboard()
{
    ScrollPane pane;
    Button[] items;
    run("scroll pane: focus, page down", {
        auto root = new Column().fillWidth(false).padding(20);
        auto list = new Column().spacing(8);
        foreach (i; 0 .. 20)
        {
            items ~= new Button(format!"Item %d"(i));
            list.add(items[$ - 1]);
        }
        pane = new ScrollPane(list).fitToWidth(true).prefSize(300, 200);
        root.add(pane);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds p;
        d.ui({ p = pane.boundsInScene; });
        foreach (i; 0 .. 8)
            d.key(SDL_Keycode.SDLK_TAB);
        d.ui({
            d.check(items[7].focused, "Tab got to item 7");
            const b = items[7].boundsInScene;
            d.check(b.minY >= p.minY && b.maxY <= p.maxY, format!"and it was scrolled into view: %s in %s"(b, p));
            d.expect(b.maxY, p.maxY, "only as far as it took");
        });
        foreach (i; 0 .. 7)
            d.key(SDL_Keycode.SDLK_TAB, SDL_Keymod.KMOD_LSHIFT);
        d.ui({
            d.check(items[0].focused, "back to item 0");
            d.expect(items[0].boundsInScene.minY, p.minY, "scrolled back up to it");
        });

        float before;
        d.ui({ before = pane.vvalue; });
        d.key(SDL_Keycode.SDLK_PAGEDOWN);
        d.ui({ d.check(pane.vvalue > before, "Page Down, from a button in it, pages down"); });

        d.ui({ items[15].scrollIntoView(); }); // what a screen reader's scroll into view does
        d.settle();
        d.ui({
            const b = items[15].boundsInScene;
            d.check(b.minY >= p.minY && b.maxY <= p.maxY, "scrolled into view on request");
        });
    });
}

/// The overlay bars: a drag on the thumb scrolls, pressing beside it jumps there, and sideways
/// scrolling works on content wider than the pane.
void bars()
{
    ScrollPane pane;
    Widget wide;
    run("scroll pane: bars and sideways", {
        auto root = new Column().fillWidth(false).padding(20);
        wide = new Widget().prefSize(900, 1000);
        pane = new ScrollPane(wide).prefSize(300, 200);
        root.add(pane);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds p;
        d.ui({ p = pane.boundsInScene; });

        // The bars come up when the pointer moves over the pane; then the right edge is the bar's
        d.move(p.centerX, p.centerY);
        d.move(p.centerX + 1, p.centerY);
        const x = p.maxX - 4;
        d.press(x, p.minY + 10);
        d.move(x, p.maxY + 100); // past the end: as far as it goes
        d.release(x, p.maxY + 100);
        d.ui({ d.expect(pane.vvalue, 1f, "dragging the thumb to the bottom"); });

        // Pressing on the bar away from the thumb jumps the thumb's middle to there
        d.move(p.centerX, p.centerY);
        d.press(x, p.centerY);
        d.release(x, p.centerY);
        d.ui({ d.check(abs(pane.vvalue - 0.5) < 0.1, format!"pressing mid-bar jumps to the middle: %s"(pane.vvalue)); });

        // Sideways, and a press on the bar isn't a press on the content
        d.scroll(p.centerX, p.centerY, 0, 1);
        d.ui({
            d.check(pane.hvalue > 0, "scrolling sideways");
            d.expect(wide.boundsInScene.minX, p.minX - 40, "by a notch");
        });
    });
}
