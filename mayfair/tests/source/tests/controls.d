module tests.controls;

import std.algorithm.searching : endsWith;
import core.thread : Thread;
import core.time : msecs;
import std.format : format;
import std.math : abs;
import harness;
import mayfair;

/// Sliders: pressing on the track jumps there, dragging the thumb carries the value, the keys
/// step it, snapping settles on ticks, and a vertical one runs bottom to top.
void sliders()
{
    Slider h, snapping, v;
    bool[] changing;
    run("controls: sliders", {
        auto root = new Column().fillWidth(false).spacing(20).padding(20);
        h = new Slider(0, 100, 40).prefWidth(300);
        h.valueChangingProperty.addListener((bool was, bool now) { changing ~= now; });
        snapping = new Slider(0, 100, 0).prefWidth(300).snapToTicks(true);
        v = new Slider(0, 10, 0).orientation(Orientation.vertical).prefHeight(200);
        root.add(h).add(snapping).add(v);
        return cast(Widget) root;
    }, (Driver d) {
        Bounds b;
        d.ui({ b = h.boundsInScene; });
        // The thumb's middle travels from half a thumb in at each end: 18 points, the theme's
        const thumb = 18f;
        float xOf(float fraction) { return b.minX + thumb / 2 + fraction * (b.width - thumb); }

        d.click(xOf(0.8), b.centreY);
        d.ui({ d.check(abs(h.value - 80) < 1, format!"a press on the track jumps there: %s"(h.value)); });

        d.press(xOf(0.8), b.centreY);
        d.move(b.maxX + 100, b.centreY);
        d.ui({ d.check(h.valueChanging, "changing while it's dragged"); });
        d.release(b.maxX + 100, b.centreY);
        d.ui({
            d.expect(h.value, 100.0, "dragged past the end: as far as it goes");
            d.check(!h.valueChanging, "and settled when it's let go");
        });

        d.key(SDL_Keycode.SDLK_LEFT);
        d.ui({ d.expect(h.value, 90.0, "Left steps it down by blockIncrement"); });
        d.key(SDL_Keycode.SDLK_HOME);
        d.ui({ d.expect(h.value, 0.0, "Home: the minimum"); });
        d.key(SDL_Keycode.SDLK_END);
        d.ui({ d.expect(h.value, 100.0, "End: the maximum"); });

        d.ui({ b = snapping.boundsInScene; });
        d.click(xOf(0.3), b.centreY);
        d.ui({
            // Ticks every 25 / (3 + 1) = 6.25
            const ticks = snapping.value / 6.25;
            d.check(abs(ticks - cast(int)(ticks + 0.5)) < 1e-6, format!"snapped to a tick: %s"(snapping.value));
        });

        d.ui({ b = v.boundsInScene; });
        d.click(b.centreX, b.minY + thumb / 2);
        d.ui({ d.expect(v.value, 10.0, "a vertical slider's top is its maximum"); });
    });
}

/// Progress bars: the bar is its progress of the track, and an indeterminate one slides.
void progressBars()
{
    ProgressBar half, unsure;
    run("controls: progress bars", {
        auto root = new Column().fillWidth(false).spacing(20).padding(20);
        half = new ProgressBar(0.5).prefWidth(200);
        unsure = new ProgressBar().prefWidth(200);
        root.add(half).add(unsure);
        return cast(Widget) root;
    }, (Driver d) {
        Widget bar(ProgressBar p) { return cast(Widget) p.children[1]; }
        d.ui({
            d.expect(bar(half).boundsInScene.width, 100f, "half of 200");
            d.check(unsure.indeterminate, "made with no progress: indeterminate");
            d.expect(bar(unsure).boundsInScene.width, 50f, "a quarter of the track slides");
        });
        float first;
        d.ui({ first = bar(unsure).boundsInScene.minX; });
        Thread.sleep(300.msecs);
        d.settle();
        d.ui({ d.check(bar(unsure).boundsInScene.minX != first, "and it moves"); });

        d.ui({ unsure.setProgress(1); });
        d.settle();
        d.ui({ d.expect(bar(unsure).boundsInScene.width, 200f, "done: the whole track"); });
    });
}

/// Text areas: lines by Enter, Up and Down keeping across, Home and End by line, wrapping, the
/// caret kept in view, Tab typing a tab and Ctrl+Tab moving on, and the mouse by line.
void textAreas()
{
    TextArea area, wrapped;
    Button after;
    run("controls: text areas", {
        auto root = new Column().fillWidth(false).spacing(12).padding(20);
        area = new TextArea().prefRowCount(3).prefColumnCount(30);
        wrapped = new TextArea("one two three four five six seven eight nine ten eleven twelve")
            .wrapText(true).prefColumnCount(12).prefRowCount(6);
        after = new Button("After");
        root.add(area).add(wrapped).add(after);
        return cast(Widget) root;
    }, (Driver d) {
        d.click(area);
        d.type("first line");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.type("second");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.type("third line here");
        d.ui({ d.expect(area.text, "first line\nsecond\nthird line here", "Enter starts a new line"); });

        // Up from the end of the third line: the second's shorter, so its end; up again keeps
        // across to where it started, not where the second line cut it off
        d.key(SDL_Keycode.SDLK_UP);
        d.ui({ d.expect(area.caretPosition, "first line\nsecond".length, "Up: as far across as the line goes"); });
        d.key(SDL_Keycode.SDLK_UP);
        d.ui({ d.expect(area.caretPosition, "first line".length, "and on up, back across to where it began"); });
        d.key(SDL_Keycode.SDLK_HOME);
        d.ui({ d.expect(area.caretPosition, 0, "Home: the line's start"); });
        d.key(SDL_Keycode.SDLK_DOWN);
        d.key(SDL_Keycode.SDLK_END);
        d.ui({ d.expect(area.caretPosition, "first line\nsecond".length, "Down, then End: the second line's end"); });
        d.key(SDL_Keycode.SDLK_END, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(area.caretPosition, area.text.length, "Ctrl+End: the end of it all"); });

        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.check(area.text.endsWith("    ") && area.focused, "Tab types four spaces"); });
        foreach (i; 0 .. 4)
            d.key(SDL_Keycode.SDLK_BACKSPACE);

        // More lines than it shows: the caret's kept in view
        foreach (i; 0 .. 6)
        {
            d.key(SDL_Keycode.SDLK_RETURN);
            d.type(format!"line %d"(i + 4));
        }
        Thread.sleep(50.msecs);
        d.settle();
        Bounds ab;
        d.ui({ ab = area.boundsInScene; });
        d.click(ab.minX + 20, ab.maxY - 12);
        d.ui({
            const lineStart = area.text.length - "line 9".length;
            d.check(area.caretPosition >= lineStart, format!"scrolled to the bottom: a click low down lands on the last line (%s)"(area.caretPosition));
        });

        // A triple click selects the paragraph
        d.click(ab.minX + 20, ab.maxY - 12, 1);
        d.click(ab.minX + 20, ab.maxY - 12, 2);
        d.click(ab.minX + 20, ab.maxY - 12, 3);
        d.ui({ d.expect(area.selectedText, "line 9", "a triple click selects the paragraph"); });

        d.key(SDL_Keycode.SDLK_TAB, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.check(wrapped.focused, "Ctrl+Tab moves on"); });

        // Wrapped: Down from the start stays in the one paragraph, a line on
        d.key(SDL_Keycode.SDLK_HOME, SDL_Keymod.KMOD_LCTRL);
        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({
            const c = wrapped.caretPosition;
            d.check(c > 0 && c < wrapped.text.length, format!"Down in a wrapped paragraph goes a line on within it: %s"(c));
        });
    });
}
