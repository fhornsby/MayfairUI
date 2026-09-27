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
