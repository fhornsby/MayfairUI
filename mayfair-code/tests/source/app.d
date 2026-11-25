import core.stdc.stdlib : exit;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.path : buildPath, dirName;
import std.stdio : writefln;
import harness;
import mayfair;
import mayfair.code;

/*
    End-to-end tests for mayfair-code: highlighting a TextView's buffer as it's edited, and a
    language server -- tests/fake-server.py, which answers predictably -- seen through a view.

        cd tests && dub run
*/
void main()
{
    highlighting();
    languageServer();
    writefln("%s passed, %s failed checks", passedCount, failedChecks);
    exit(failedChecks ? 1 : 0);
}

bool waitFor(Driver d, bool delegate() ok, Duration timeout = 10.seconds)
{
    const deadline = MonoTime.currTime + timeout;
    while (MonoTime.currTime < deadline)
    {
        bool done;
        d.ui({ done = ok(); });
        if (done)
            return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

/// The tag a line's first highlight is drawn with, from column `column` on.
TextTag tagAt(TextBuffer b, int line, size_t column)
{
    foreach (sp; b.highlightsOn(line))
        if (sp.start <= column && sp.end > column)
            return sp.tag;
    return null;
}

/// Highlighting follows the text: a comment opened colours the lines after it until it's closed,
/// and a long file is highlighted all the way down, a slice at a time.
void highlighting()
{
    TextView view;
    TextBuffer buffer;
    SyntaxHighlighter highlighter;
    run("code: highlighting as it's edited", {
        buffer = new TextBuffer("int a;\nint b;\nint c;\nreturn x;");
        view = new TextView(buffer).prefSize(500, 300);
        highlighter = new SyntaxHighlighter(buffer, languageNamed("D"));
        highlighter.follow(view);
        return cast(Widget) view;
    }, (Driver d) {
        auto comment() { return highlighter.tagFor(Syntax.comment); }
        auto keyword() { return highlighter.tagFor(Syntax.keyword); }
        d.ui({
            d.check(tagAt(buffer, 3, 0) is keyword, "return: a keyword");
            d.expect(view.lineComment, "//", "the view's comment, D's");
            view.requestFocus();
            view.placeCaret(TextPosition(0, 0));
        });
        d.type("/*");
        d.ui({
            d.check(tagAt(buffer, 2, 0) is comment, "a comment opened: the lines after it, comment");
            d.check(tagAt(buffer, 3, 0) is comment, "all the way down");
            view.placeCaret(TextPosition(1, 6));
        });
        d.type("*/");
        d.ui({
            d.check(tagAt(buffer, 1, 0) is comment, "inside it still");
            d.check(tagAt(buffer, 2, 0) !is comment && tagAt(buffer, 3, 0) is keyword, "closed: after it, code again");
        });

        // A long file: highlighted to its end, in slices
        d.ui({
            string[] lines;
            foreach (i; 0 .. 30_000)
                lines ~= format!"int v%s = %s; // number %s"(i, i, i);
            buffer.setText(lines.join("\n"));
        });
        d.check(waitFor(d, () => tagAt(buffer, 29_999, 0) !is null), "the last line of 30,000 highlighted");
        d.ui({ d.check(tagAt(buffer, 29_999, 20) is comment, "its comment, as a comment"); });
    });
}

/// A language server: diagnostics that follow the text as it's typed, completions, a hover, a definition.
void languageServer()
{
    TextView view;
    TextBuffer buffer;
    LanguageServer server;
    LspDocument document;
    LspEditor editor;
    const script = buildPath(dirName(__FILE_FULL_PATH__), "..", "fake-server.py");
    run("code: a language server", {
        buffer = new TextBuffer("x = 1\n😀 bad here\ndef target():\n    pass");
        view = new TextView(buffer).showLineNumbers(true).prefSize(600, 400);
        server = new LanguageServer(["python3", script], dirName(script));
        document = new LspDocument(server, buffer, buildPath(dirName(script), "sample.py"));
        editor = new LspEditor(document, view);
        return cast(Widget) view;
    }, (Driver d) {
        d.check(waitFor(d, () => server.status == LanguageServer.Status.ready), "the server started");
        d.ui({ d.expect(server.serverName, "fake"); d.expect(server.completionTriggers, ["."]); });

        // Its diagnostics, where it says, in the buffer's own columns: after an emoji, 4 bytes but 2 UTF-16 units
        d.check(waitFor(d, () => document.diagnostics.length == 1), "a diagnostic, for the bad that's there");
        d.ui({
            const x = document.diagnostics[0];
            d.expect(x.start, TextPosition(1, 5), "after the emoji and a space, in bytes");
            d.expect(x.message, buffer.line(1), "the server sees the line as it is");
            bool tagged;
            foreach (sp; buffer.tagsOn(1))
                if (sp.tag.name == "error" && sp.start == 5 && sp.end == 8)
                    tagged = true;
            d.check(tagged, "underlined, where it is");
            view.requestFocus();
            view.placeCaret(TextPosition(1, 4)); // before the space after the emoji
        });

        // Typed, as edits the server follows: each sent as the range it changed
        d.type(" not");
        d.check(waitFor(d, () => document.diagnostics.length == 1 && document.diagnostics[0].message == buffer.line(1)),
                "an edit after an emoji, followed");
        d.ui({ d.expect(document.diagnostics[0].start, TextPosition(1, 9), "the diagnostic moved along"); view.placeCaret(TextPosition(0, 5)); });
        d.type(" + bad");
        d.check(waitFor(d, () => document.diagnostics.length == 2), "another, typed");
        d.ui({
            d.expect(document.diagnostics[0].message, buffer.line(0));
            d.expect(document.diagnostics[0].start, TextPosition(0, 8));
        });
        d.key(SDL_Keycode.SDLK_Z, SDL_Keymod.KMOD_LCTRL);
        d.check(waitFor(d, () => document.diagnostics.length == 1), "undone: gone again");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.check(waitFor(d, () => buffer.lineCount == 5 && document.diagnostics.length == 1
                                 && document.diagnostics[0].start.line == 2), "a line put in: the diagnostic a line down");

        // Completions: asked for, narrowed by what's typed, chosen, put in
        d.type("al");
        d.key(SDL_Keycode.SDLK_SPACE, SDL_Keymod.KMOD_LCTRL);
        d.check(waitFor(d, () => editor.completing), "completions shown");
        d.ui({ d.expect(editor.completionLabels, ["alpha", "alphabet"], "narrowed to what's typed"); });
        d.type("phab");
        d.check(waitFor(d, () => editor.completionLabels == ["alphabet"]), "and narrowed further as it's typed");
        d.key(SDL_Keycode.SDLK_RETURN);
        d.ui({
            d.check(!editor.completing, "put away");
            d.expect(buffer.line(1), "alphabet", "put in, in place of what was typed");
        });
        d.type(".");
        d.check(waitFor(d, () => editor.completing), "a trigger character: completions");
        d.key(SDL_Keycode.SDLK_ESCAPE);
        Thread.sleep(300.msecs); // for any answer still coming
        d.ui({ d.check(!editor.completing, "Escape: put away"); d.expect(buffer.line(1), "alphabet.", "nothing put in"); });

        // What's at a place, and where it's defined
        string hovered;
        d.ui({ document.hover(TextPosition(2, 5), (string s) { hovered = s; }); });
        d.check(waitFor(d, () => hovered.length > 0), "a hover");
        d.ui({ d.expect(hovered, "hover at 2:3", "asked where it was, in UTF-16"); view.placeCaret(TextPosition(0, 0)); });
        d.key(SDL_Keycode.SDLK_F12);
        d.check(waitFor(d, () => view.caretPosition == TextPosition(3, 4)), format!"F12: to the definition: %s"(view.caretPosition));

        d.ui({ document.close(); server.stop(); });
        d.check(waitFor(d, () => server.status == LanguageServer.Status.stopped), "stopped");
    });
}
