module documents;

import std.file : write;
import std.path : baseName;
import mayfair;
import mayfair.code;
import compiler : Problem;

/*
    A file open in the editor: its text (a TextBuffer), the TextView it's edited in, the tab that
    holds it, and what reads it -- a highlighter for its language, a language server's view of
    it if one's installed (texlab, for LaTeX), and the last compile's errors and warnings, marked
    where they are.
*/
final class Document
{
    string path;
    TextBuffer buffer;
    TextView view;
    Tab tab;
    Language language;
    SyntaxHighlighter highlighter;
    LspDocument lsp;
    LspEditor lspEditor;

    this(string path, string content)
    {
        this.path = path;
        buffer = new TextBuffer(content);
        view = new TextView(buffer).showLineNumbers(true).highlightCurrentLine(true);
        view.setGrow(1);
        language = languageFor(path);
        highlighter = new SyntaxHighlighter(buffer, language);
        highlighter.follow(view); // its comments, indentation, and light or dark colours
        tab = new Tab(null, view).graphic(new Icon("text-x-generic-symbolic")).closable(true);
        errorTag = new TextTag("compile-error").underlined(Underline.squiggle, Colour(229, 57, 53));
        warningTag = new TextTag("compile-warning").underlined(Underline.squiggle, Colour(240, 160, 0));
        showName();
        buffer.modifiedProperty.addListener((bool was, bool now) { showName(); });
    }

    /// Writes it to its file. False, with `why` saying why, if it couldn't.
    bool save(out string why)
    {
        try
            write(path, buffer.textToSave);
        catch (Exception e)
        {
            why = e.msg;
            return false;
        }
        buffer.setModified(false);
        if (lsp)
            lsp.saved();
        return true;
    }

    /// The tab says its name, with a dot while it has changes that aren't saved.
    void showName()
    {
        tab.text = (buffer.modified ? "• " : "") ~ baseName(path);
    }

    /// Marks the compile's errors and warnings that are in this file: a squiggle along each
    /// line, and a dot beside it.
    void showProblems(const Problem[] problems)
    {
        buffer.removeTagEverywhere(errorTag);
        buffer.removeTagEverywhere(warningTag);
        foreach (m; marks)
        {
            view.removeGutterMark(m);
            buffer.deleteMark(m);
        }
        marks = null;
        foreach (ref p; problems)
        {
            if (p.file != path || p.line < 1 || p.line > buffer.lineCount)
                continue;
            const l = p.line - 1;
            // From the line's first character that isn't space to its end
            const text = buffer.line(l);
            size_t from;
            while (from < text.length && (text[from] == ' ' || text[from] == '\t'))
                from++;
            buffer.applyTag(p.error ? errorTag : warningTag, TextPosition(l, from), TextPosition(l, text.length));
            auto m = buffer.createMark(TextPosition(l, 0), true);
            marks ~= m;
            view.addGutterMark(m, p.error ? Colour(229, 57, 53) : Colour(240, 160, 0));
        }
    }

    /// Puts the caret at the start of line `line`, from 1, and shows it.
    void goToLine(int line)
    {
        if (line < 1)
            return;
        view.placeCaret(TextPosition(line - 1, 0));
        view.requestFocus();
    }

private:
    TextTag errorTag, warningTag;
    TextMark[] marks;
}
