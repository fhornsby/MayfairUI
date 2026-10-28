module tests.textfield;

import std.format : format;
import harness;
import mayfair;

/// A field's text, caret, anchor and selection in one line, to compare against.
private string state(TextField f)
{
    return format!"%s|%s %s [%s]"(f.text, f.caretPosition, f.anchor, f.selectedText);
}

private enum ctrl = SDL_Keymod.KMOD_LCTRL, shift = SDL_Keymod.KMOD_LSHIFT;

/// Editing from the keyboard: characters as a reader counts them, words, selection, the
/// clipboard, input methods, and Enter.
void editing()
{
    TextField field;
    int actions;
    run("text field: editing", {
        auto root = new Column().fillWidth(false);
        field = new TextField("old");
        field.onAction({ actions++; });
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(state(field), wanted, step, file, line); });
        }
        d.preserveClipboard();

        d.key(SDL_Keycode.SDLK_TAB);            expect("old|3 0 [old]", "tabbing in selects everything");
        d.type("héllo");                        expect("héllo|6 6 []", "typing replaces it; é is two bytes");
        d.type(" wörld");                       expect("héllo wörld|13 13 []", "more typing");
        d.key(SDL_Keycode.SDLK_LEFT, ctrl);     expect("héllo wörld|7 7 []", "Ctrl+Left to the start of the word");
        d.key(SDL_Keycode.SDLK_BACKSPACE);      expect("héllowörld|6 6 []", "Backspace takes the space");
        d.type(" ");
        d.key(SDL_Keycode.SDLK_END, shift);     expect("héllo wörld|13 7 [wörld]", "Shift+End selects to the end");
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.key(SDL_Keycode.SDLK_END);
        d.key(SDL_Keycode.SDLK_V, ctrl);        expect("héllo wörldwörld|19 19 []", "copied and pasted");
        d.key(SDL_Keycode.SDLK_BACKSPACE, ctrl); expect("héllo |7 7 []", "Ctrl+Backspace takes a word");
        d.compose("ni");                        expect("héllo |7 7 []", "a composition isn't text yet");
        d.compose("");
        d.type("你");                           expect("héllo 你|10 10 []", "committed, it is");
        d.key(SDL_Keycode.SDLK_HOME);
        d.key(SDL_Keycode.SDLK_RIGHT, shift);   expect("héllo 你|1 0 [h]", "Shift+Right selects a character");
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.key(SDL_Keycode.SDLK_DELETE);         expect("hllo 你|1 1 []", "Delete takes é whole");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({ d.expect(actions, 1, "Enter runs the action"); });
    });
}

/// Undo and redo, which take back a run of typing or of deleting at a time.
void undoRedo()
{
    TextField field;
    run("text field: undo and redo", {
        auto root = new Column().fillWidth(false);
        field = new TextField();
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(state(field), wanted, step, file, line); });
        }
        d.key(SDL_Keycode.SDLK_TAB);
        d.type("abc");
        d.type(" def");
        d.key(SDL_Keycode.SDLK_BACKSPACE);
        d.key(SDL_Keycode.SDLK_BACKSPACE);      expect("abc d|5 5 []", "typed, then deleted");
        d.key(SDL_Keycode.SDLK_Z, ctrl);        expect("abc def|7 7 []", "the deleting undone");
        d.key(SDL_Keycode.SDLK_Z, ctrl);        expect("|0 0 []", "the typing undone, all of it");
        d.ui({ d.check(!field.undoable && field.redoable, "nothing left to undo, two to redo"); });
        d.key(SDL_Keycode.SDLK_Z, cast(SDL_Keymod)(ctrl | shift)); expect("abc def|7 7 []", "Ctrl+Shift+Z redoes");
        d.key(SDL_Keycode.SDLK_Y, ctrl);        expect("abc d|5 5 []", "Ctrl+Y redoes too");
        d.ui({ field.setText("new"); d.check(!field.undoable, "setText from code starts the history afresh"); });
    });
}

/// The mouse: dragging a word at a time after a double click, and the middle click's paste.
void mouse()
{
    TextField field;
    run("text field: word drag, middle click", {
        auto root = new Column().fillWidth(false);
        field = new TextField("one two three");
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(state(field), wanted, step, file, line); });
        }
        d.preserveClipboard();
        // Where each word is, from the field's own layout rather than guessed pixels
        Bounds b;
        float two, three, one, left;
        d.ui({
            b = field.boundsInScene;
            left = b.minX + field.padding.left; // the theme's
            auto line = editableLine(field.font, field.text);
            one = left + line.xAt(1);
            two = left + line.xAt(5);
            three = left + line.xAt(10);
        });
        const y = b.centreY;

        d.click(two, y, 1);
        d.move(two, y);
        d.press(two, y, 2);                     expect("one two three|7 4 [two]", "a double click selects the word");
        d.move(three, y);                       expect("one two three|13 4 [two three]", "dragging on takes whole words");
        d.move(one, y);                         expect("one two three|0 7 [one two]", "and backwards keeps the first word");
        d.release(one, y, 2);

        d.ui({ Clipboard.primary = "PRIMARY"; field.setText("ab"); });
        d.click(left, y, 1, 2); // middle button, before the "a"
        expect("PRIMARYab|7 7 []", "a middle click pastes the primary selection where it's clicked");
    });
}

/// Right-to-left text after left-to-right: the arrows move the way they point on screen.
void rightToLeft()
{
    TextField field;
    run("text field: right to left", {
        auto root = new Column().fillWidth(false);
        field = new TextField();
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(state(field), wanted, step, file, line); });
        }
        d.key(SDL_Keycode.SDLK_TAB);
        d.type("abc ");
        d.type("שלום");                         expect("abc שלום|12 12 []", "Hebrew after English");
        d.key(SDL_Keycode.SDLK_LEFT);           expect("abc שלום|3 3 []", "left of the end, on screen, is before the space");
        d.key(SDL_Keycode.SDLK_LEFT);           expect("abc שלום|2 2 []", "and on left");
        d.key(SDL_Keycode.SDLK_RIGHT);
        d.key(SDL_Keycode.SDLK_RIGHT);          expect("abc שלום|12 12 []", "and back to the end");
    });
}

/// A password field: typed into as any field is, but showing dots, and keeping its text off the clipboard.
void password()
{
    PasswordField field;
    run("text field: password", {
        auto root = new Column().fillWidth(false);
        field = new PasswordField();
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(state(field), wanted, step, file, line); });
        }
        d.preserveClipboard();
        d.key(SDL_Keycode.SDLK_TAB);
        // After input, not before: on Wayland a window can only set the clipboard once it's had some
        d.ui({ Clipboard.text = "on the clipboard"; });
        d.type("hunter 2é");                    expect("hunter 2é|10 10 []", "typed as into any field");
        d.key(SDL_Keycode.SDLK_LEFT, ctrl);     expect("hunter 2é|0 0 []", "no words in dots: Ctrl+Left goes to the start");
        d.key(SDL_Keycode.SDLK_RIGHT, ctrl);    expect("hunter 2é|10 10 []", "and Ctrl+Right to the end");
        d.key(SDL_Keycode.SDLK_LEFT, shift);    expect("hunter 2é|8 10 [é]", "é is still one character");
        d.key(SDL_Keycode.SDLK_A, ctrl);
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.key(SDL_Keycode.SDLK_X, ctrl);        expect("hunter 2é|10 0 [hunter 2é]", "cut does nothing");
        d.ui({ d.expect(Clipboard.text, "on the clipboard", "nor does copy"); });
        d.key(SDL_Keycode.SDLK_V, ctrl);        expect("on the clipboard|16 16 []", "but pasting works");
    });
}

/// The context menu a field has of its own: for the selection when the right click's on it, and
/// for the place clicked otherwise; what can't be done disabled; and the app's in its place.
void contextMenu()
{
    TextField field;
    run("text field: context menu", {
        auto root = new Column().fillWidth(false);
        field = new TextField("one two three");
        root.add(field);
        return cast(Widget) root;
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(state(field), wanted, step, file, line); });
        }
        ContextMenu menu() { auto p = field.scene.showingPopups; return p.length ? cast(ContextMenu) p[$ - 1] : null; }
        MenuItem item(string text)
        {
            foreach (w; menu.items)
                if (auto m = cast(MenuItem) w)
                    if (m.text == text)
                        return m;
            assert(false, text);
        }
        string enabled()
        {
            string s;
            foreach (w; menu.items)
                if (auto m = cast(MenuItem) w)
                    if (!m.disabled)
                        s ~= (s.length ? " " : "") ~ m.text;
            return s;
        }
        d.preserveClipboard();
        d.ui({ Clipboard.text = "pasted "; });
        Bounds b;
        float one, two;
        d.ui({
            b = field.boundsInScene;
            const left = b.minX + field.padding.left;
            auto line = editableLine(field.font, field.text);
            one = left + line.xAt(0) + 1;
            two = left + line.xAt(5);
        });
        const y = b.centreY;

        // Tabbed in, so coming back from the menu mustn't be taken for tabbing in again
        d.key(SDL_Keycode.SDLK_TAB);
        d.key(SDL_Keycode.SDLK_END);
        d.click(two, y, 1, 3);
        d.ui({
            d.check(menu !is null, "a right click shows the field's own menu");
            d.expect(enabled, "Paste Select All", "nothing selected: no Cut, Copy or Delete");
        });
        expect("one two three|5 5 []", "the caret goes where it was clicked");
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({ d.check(menu is null && field.focused, "Escape puts it away, focus back on the field"); });
        expect("one two three|5 5 []", "without selecting everything, as tabbing in would");

        d.click(two, y, 1);
        d.move(two, y);
        d.press(two, y, 2);
        d.release(two, y, 2);
        d.click(two + 2, y, 1, 3);
        expect("one two three|7 4 [two]", "a right click on the selection keeps it");
        d.ui({ d.expect(enabled, "Cut Copy Paste Delete Select All"); });
        d.click(item("Copy"));
        d.ui({
            d.expect(Clipboard.text, "two", "Copy copies it");
            d.check(menu is null, "and the menu goes");
        });

        d.click(one, y, 1, 3);
        d.click(item("Paste"));
        expect("twoone two three|3 3 []", "Paste pastes where the right click was");
        d.click(one, y, 1, 3);
        d.click(item("Select All"));
        expect("twoone two three|16 0 [twoone two three]", "Select All");
        d.click(one + 4, y, 1, 3);
        d.click(item("Delete"));
        expect("|0 0 []", "Delete deletes the selection");

        d.ui({ field.setText("read only"); field.setEditable(false); field.selectRange(0, 4); });
        d.click(one + 4, y, 1, 3);
        d.ui({ d.expect(enabled, "Copy Select All", "not editable: only copying and selecting"); });
        d.key(SDL_Keycode.SDLK_ESCAPE);

        string[] done;
        auto own = new ContextMenu().add(new MenuItem("Mine", { done ~= "mine"; }));
        d.ui({ field.setContextMenu(own); });
        d.click(one, y, 1, 3);
        d.ui({ d.check(menu is own, "the app's menu takes the field's place"); });
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({ field.setContextMenu(null); });
        d.key(SDL_Keycode.SDLK_APPLICATION);
        d.ui({ d.check(menu !is null && menu !is own, "the Menu key shows the field's own again"); });
        d.key(SDL_Keycode.SDLK_ESCAPE);
    });
}

/// A selectable label: selected by dragging, by words and lines, copied by the keys and its menu,
/// and only while it's selectable.
void selectableLabel()
{
    Label label;
    Button other;
    run("label: selectable", {
        label = new Label("one two three\nfour five").selectable(true);
        other = new Button("Other");
        return cast(Widget) new Column().fillWidth(false).padding(20).spacing(10).add(other).add(label);
    }, (Driver d) {
        void expect(string wanted, string step, string file = __FILE__, size_t line = __LINE__)
        {
            d.ui({ d.expect(label.selectedText, wanted, step, file, line); });
        }
        ContextMenu menu() { auto p = label.scene.showingPopups; return p.length ? cast(ContextMenu) p[$ - 1] : null; }
        d.preserveClipboard();
        Bounds b;
        float one, two, three, lineHeight;
        d.ui({
            b = label.boundsInScene;
            auto line = editableLine(label.font, "one two three");
            one = b.minX + line.xAt(0) + 1;
            two = b.minX + line.xAt(5);
            three = b.minX + line.xAt(11);
            lineHeight = label.font.lineHeight;
        });
        const y = b.minY + lineHeight / 2, y2 = y + lineHeight;

        d.press(one, y);
        d.move(two, y);
        d.release(two, y);
        expect("one t", "dragging selects");
        d.ui({ d.check(label.focused, "and the click gave it focus"); });
        d.key(SDL_Keycode.SDLK_C, ctrl);
        d.ui({ d.expect(Clipboard.text, "one t", "Ctrl+C copies it"); });

        d.click(two, y, 1);
        d.move(two, y);
        d.press(two, y, 2);
        d.move(three, y);
        d.release(three, y, 2);
        expect("two three", "a double click selects a word, and dragging on whole words");
        d.click(two, y2, 1, 1);
        d.press(two, y2, 2);
        d.press(two, y2, 3);
        d.release(two, y2, 3);
        expect("four five", "a triple click selects the line");
        d.click(one, y, 1);
        d.press(three, y, 1);
        d.release(three, y, 1);
        d.ui({ d.check(!label.selectedText.length, "a click selects nothing"); });

        d.key(SDL_Keycode.SDLK_A, ctrl);
        expect("one two three\nfour five", "Ctrl+A selects everything");
        d.click(two, y, 1, 3);
        d.ui({
            d.check(menu !is null, "a right click shows a menu");
            d.expect(label.selectedText, "one two three\nfour five", "leaving the selection alone");
        });
        Widget copyItem;
        d.ui({ copyItem = menu.items[0]; Clipboard.text = ""; });
        d.click(copyItem);
        d.ui({ d.expect(Clipboard.text, "one two three\nfour five", "its Copy copies"); });

        d.ui({ label.setText("new"); });
        expect("", "new text, nothing selected");
        d.ui({ label.setSelectable(false); });
        d.press(one, y);
        d.move(three, y);
        d.release(three, y);
        expect("", "not selectable: a drag selects nothing");
        d.click(one, y, 1, 3);
        d.ui({ d.check(menu is null, "nor is there a menu"); });
    });
}
