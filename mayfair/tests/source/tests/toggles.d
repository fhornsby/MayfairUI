module tests.toggles;

import harness;
import mayfair;

/// Check boxes: a click toggles and runs the action, Space does too, one that allows it goes
/// through indeterminate, and a disabled one doesn't change.
void checkBoxes()
{
    CheckBox plain, triple, off;
    int actions;
    run("toggles: check boxes", {
        auto root = new Column().fillWidth(false).spacing(8).padding(10);
        plain = new CheckBox("Plain").onAction({ actions++; });
        triple = new CheckBox("Three states").allowIndeterminate(true);
        off = new CheckBox("Off").disable(true);
        root.add(plain).add(triple).add(off);
        return cast(Widget) root;
    }, (Driver d) {
        d.click(plain);
        d.ui({ d.check(plain.selected && actions == 1, "a click ticks it, and runs its action"); });
        d.click(plain);
        d.ui({ d.check(!plain.selected && actions == 2, "and another unticks it"); });

        d.key(SDL_Keycode.SDLK_SPACE); // it has focus from the click
        d.ui({ d.check(plain.selected, "Space ticks it"); });

        bool[2][] seen;
        foreach (i; 0 .. 4)
        {
            d.click(triple);
            d.ui({ seen ~= [triple.selected, triple.indeterminate]; });
        }
        d.ui({
            d.expect(seen, [[false, true], [true, false], [false, false], [false, true]],
                     "off, indeterminate, on, off, as JavaFX's goes");
        });

        d.click(off);
        d.ui({ d.check(!off.selected, "a disabled one doesn't change"); });
    });
}

/// A radio group: one chosen at a time, the chosen one stays chosen, the arrows choose as they
/// move, and Tab stops at the group once.
void radioGroup()
{
    ToggleGroup group;
    RadioButton a, b, c;
    Button before, after;
    string[] heard;
    run("toggles: a radio group", {
        auto root = new Column().fillWidth(false).spacing(8).padding(10);
        group = new ToggleGroup;
        before = new Button("Before");
        a = new RadioButton("A").toggleGroup(group);
        b = new RadioButton("B").toggleGroup(group);
        c = new RadioButton("C").toggleGroup(group);
        after = new Button("After");
        group.selectedToggleProperty.addListener((ToggleButton was, ToggleButton now) { heard ~= now ? now.text : "none"; });
        root.add(before).add(a).add(b).add(c).add(after);
        return cast(Widget) root;
    }, (Driver d) {
        d.click(b);
        d.ui({ d.check(b.selected && group.selectedToggle is b, "a click chooses it"); });
        d.click(c);
        d.ui({ d.check(c.selected && !b.selected && group.selectedToggle is c, "and another unchooses the first"); });
        d.click(c);
        d.ui({ d.check(c.selected, "clicking the chosen one leaves it chosen"); });

        // Tab from the button before: into the group at the chosen one, then straight out of it
        d.click(before);
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.check(c.focused, "Tab goes to the chosen radio, not the first"); });
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.check(after.focused, "and on out of the group"); });
        d.key(SDL_Keycode.SDLK_TAB, SDL_Keymod.KMOD_LSHIFT);
        d.ui({ d.check(c.focused, "Shift+Tab comes back to it"); });

        d.key(SDL_Keycode.SDLK_DOWN);
        d.ui({ d.check(a.focused && a.selected && !c.selected, "Down chooses the next, round from the end"); });
        d.key(SDL_Keycode.SDLK_UP);
        d.ui({ d.check(c.focused && c.selected, "Up goes back"); });
        d.ui({ d.expect(heard, ["B", "C", "A", "C"], "the group said so each time"); });
    });
}

/// Toggle buttons: in and out; in a group, one in at a time, and none if the in one is pressed.
void toggleButtons()
{
    ToggleGroup group;
    ToggleButton bold, left, right;
    run("toggles: toggle buttons", {
        auto root = new Row().spacing(8).padding(10).fillHeight(false);
        bold = new ToggleButton("Bold");
        group = new ToggleGroup;
        left = new ToggleButton("Left").toggleGroup(group);
        right = new ToggleButton("Right").toggleGroup(group);
        root.add(bold).add(left).add(right);
        return cast(Widget) root;
    }, (Driver d) {
        d.click(bold);
        d.ui({ d.check(bold.selected, "pressed in"); });
        d.click(bold);
        d.ui({ d.check(!bold.selected, "and out"); });
        d.click(left);
        d.click(right);
        d.ui({ d.check(right.selected && !left.selected, "one in at a time in a group"); });
        d.click(right);
        d.ui({ d.check(!right.selected && group.selectedToggle is null, "and none, unlike radio buttons"); });
    });
}
