module tests.textview;

import core.time : MonoTime, msecs;
import std.array : join, replicate;
import std.conv : to;
import std.format : format;
import harness;
import mayfair;

/// Editing by the keys a code editor has: typing, indenting as it goes, undoing in runs, moving
/// by words and lines, selecting, the clipboard, indenting and moving lines, commenting.
void editing()
{
    TextView view;
    TextBuffer buffer;
    run("text view: editing", {
        buffer = new TextBuffer("int main()\n{\n    return 0;\n}");
        view = new TextView(buffer).showLineNumbers(true).prefSize(600, 400);
        view.setLineComment("//");
        return cast(Widget) view;
    }, (Driver d) {
        d.preserveClipboard();
        d.ui({ view.requestFocus(); view.placeCaret(TextPosition(2, 13)); });
        d.settle();
        // Typing after the last line's text, then Enter: indented as that line
        d.type(" // done");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.type("x");
        d.ui({
            d.expect(buffer.line(2), "    return 0; // done");
            d.expect(buffer.line(3), "    x", "the new line, indented as the last");
            d.expect(view.caretPosition, TextPosition(3, 5));
        });
        // Undo: the typing as a run, then the new line
        d.key(SDL_Keycode.SDLK_Z, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(buffer.line(3), "    ", "the run of typing undone"); });
        d.key(SDL_Keycode.SDLK_Z, SDL_Keymod.KMOD_LCTRL);
        d.key(SDL_Keycode.SDLK_Z, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(buffer.text, "int main()\n{\n    return 0;\n}", "and the rest, back as it was"); });
        d.key(SDL_Keycode.SDLK_Z, cast(SDL_Keymod) (SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        d.ui({ d.expect(buffer.line(2), "    return 0; // done", "redone"); });

        // After an opening brace: a level further, and the closer on a line of its own
        d.ui({ buffer.setText("void f() {}"); view.placeCaret(TextPosition(0, 10)); });
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({
            d.expect(buffer.text, "void f() {\n\t\n}", "the closer below, the caret indented between");
            d.expect(view.caretPosition, TextPosition(1, 1));
        });

        // Home: to the first non-blank, then the start; words with Ctrl, selecting with Shift
        d.ui({ buffer.setText("    alpha beta.gamma"); view.placeCaret(TextPosition(0, 20)); });
        d.key(SDL_Keycode.SDLK_HOME);
        d.ui({ d.expect(view.caretPosition.column, 4, "Home: the first non-blank"); });
        d.key(SDL_Keycode.SDLK_HOME);
        d.ui({ d.expect(view.caretPosition.column, 0, "again: the line's start"); });
        d.key(SDL_Keycode.SDLK_RIGHT, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(view.caretPosition.column, 9, "Ctrl+Right: past the next word"); });
        d.key(SDL_Keycode.SDLK_RIGHT, cast(SDL_Keymod) (SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        d.ui({ d.expect(view.selectedText, " beta", "selecting a word to the right"); });
        d.key(SDL_Keycode.SDLK_C, SDL_Keymod.KMOD_LCTRL);
        d.key(SDL_Keycode.SDLK_END);
        d.key(SDL_Keycode.SDLK_V, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(buffer.line(0), "    alpha beta.gamma beta", "copied, and pasted at the end"); });
        d.key(SDL_Keycode.SDLK_BACKSPACE, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(buffer.line(0), "    alpha beta.gamma ", "Ctrl+Backspace: a word"); });

        // Indenting and outdenting lines, moving them, deleting them, commenting them out
        d.ui({ buffer.setText("a\nb\nc"); view.select(TextPosition(0, 0), TextPosition(1, 1)); });
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.expect(buffer.text, "\ta\n\tb\nc", "Tab: the lines selected indented"); });
        d.key(SDL_Keycode.SDLK_TAB, SDL_Keymod.KMOD_LSHIFT);
        d.ui({ d.expect(buffer.text, "a\nb\nc", "Shift+Tab: back"); view.placeCaret(TextPosition(0, 0)); });
        d.key(SDL_Keycode.SDLK_DOWN, SDL_Keymod.KMOD_LALT);
        d.ui({ d.expect(buffer.text, "b\na\nc", "Alt+Down: the line moved down"); d.expect(view.caretPosition.line, 1, "with the caret"); });
        d.key(SDL_Keycode.SDLK_SLASH, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(buffer.line(1), "// a", "Ctrl+/: commented out"); });
        d.key(SDL_Keycode.SDLK_SLASH, SDL_Keymod.KMOD_LCTRL);
        d.ui({ d.expect(buffer.line(1), "a", "and back in"); });
        d.key(SDL_Keycode.SDLK_K, cast(SDL_Keymod) (SDL_Keymod.KMOD_LCTRL | SDL_Keymod.KMOD_LSHIFT));
        d.ui({ d.expect(buffer.text, "b\nc", "Ctrl+Shift+K: the line deleted"); });

        // Spaces for tabs, to the next stop; Backspace a level
        d.ui({ view.setInsertSpaces(true); buffer.setText("ab"); view.placeCaret(TextPosition(0, 2)); });
        d.key(SDL_Keycode.SDLK_TAB);
        d.ui({ d.expect(buffer.line(0), "ab  ", "spaces to the next stop"); buffer.setText("        x"); view.placeCaret(TextPosition(0, 8)); });
        d.key(SDL_Keycode.SDLK_BACKSPACE);
        d.ui({ d.expect(buffer.line(0), "    x", "Backspace in indentation: a level"); });
    });
}

/// The pointer: a click puts the caret there, a drag selects, a double click a word, a triple a line.
void pointer()
{
    TextView view;
    TextBuffer buffer;
    run("text view: the pointer", {
        buffer = new TextBuffer("first line here\nsecond line\nthird");
        view = new TextView(buffer).prefSize(500, 300);
        return cast(Widget) view;
    }, (Driver d) {
        d.settle();
        Bounds second, here;
        d.ui({
            second = view.rectInScene(TextPosition(1, 0));
            here = view.rectInScene(TextPosition(0, 11));
        });
        d.click(second.minX + 1, second.centreY);
        d.ui({ d.expect(view.caretPosition, TextPosition(1, 0), "a click, the caret there"); });
        d.press(second.minX + 1, second.centreY);
        d.move(here.minX + 30, here.centreY);
        d.release(here.minX + 1, here.centreY);
        d.ui({ d.expect(view.selectedText, "here\n", "dragged back up: selected"); });
        Bounds word;
        d.ui({ word = view.rectInScene(TextPosition(1, 8)); });
        d.click(word.centreX, word.centreY, 2);
        d.ui({ d.expect(view.selectedText, "line", "a double click: the word"); });
        d.click(word.centreX, word.centreY, 3);
        d.ui({ d.expect(view.selectedText, "second line\n", "a triple click: the line"); });
    });
}

/// Finding: every match highlighted and counted, the next selected, replaced one at a time and all at once.
void finding()
{
    TextView view;
    TextBuffer buffer;
    run("text view: finding and replacing", {
        buffer = new TextBuffer("let foo = 1;\nfoo += food;\nprint(foo);");
        view = new TextView(buffer).prefSize(500, 300);
        return cast(Widget) view;
    }, (Driver d) {
        d.ui({
            view.find("foo", false, true);
            d.expect(view.matchCount, 3, "whole words: food isn't one");
            d.expect(view.selectionStart, TextPosition(0, 4), "the first selected");
            view.findNext();
            d.expect(view.selectionStart, TextPosition(1, 0));
            view.replaceNext("bar");
            d.expect(buffer.line(1), "bar += food;", "replaced");
            d.expect(view.selectionStart, TextPosition(2, 6), "and on to the next");
            d.expect(view.replaceAll("baz"), 2, "the rest, all at once");
            d.expect(buffer.text, "let baz = 1;\nbar += food;\nprint(baz);");
            view.undo();
            d.expect(buffer.text, "let foo = 1;\nbar += food;\nprint(foo);", "replacing all, undone as one");
        });
    });
}

/// A big file: a hundred thousand lines, opened, scrolled to the end and typed into, at a speed
/// that doesn't depend on its size, since only what's near the view is drawn.
void bigFile()
{
    TextView view;
    TextBuffer buffer;
    run("text view: a big file", {
        string[] lines;
        foreach (i; 0 .. 100_000)
            lines ~= format!"line %s: the quick brown fox jumps over the lazy dog"(i);
        buffer = new TextBuffer(lines.join("\n"));
        view = new TextView(buffer).showLineNumbers(true).prefSize(700, 500);
        return cast(Widget) view;
    }, (Driver d) {
        d.ui({ view.requestFocus(); });
        d.settle();
        d.key(SDL_Keycode.SDLK_END, SDL_Keymod.KMOD_LCTRL);
        d.settle();
        const start = MonoTime.currTime;
        d.type("typed at the end");
        d.settle();
        const took = MonoTime.currTime - start;
        d.ui({
            d.expect(buffer.line(99_999), "line 99999: the quick brown fox jumps over the lazy dog" ~ "typed at the end");
            d.check(view.caretPosition.line == 99_999, "at the end");
            Bounds caret = view.rectInScene(view.caretPosition);
            Bounds b = view.boundsInScene;
            d.check(caret.minY >= b.minY && caret.maxY <= b.maxY, format!"the caret in view: %s in %s"(caret, b));
        });
        d.check(took < 3000.msecs, format!"typing at the end of 100,000 lines, quickly: %s"(took));
    });
}
