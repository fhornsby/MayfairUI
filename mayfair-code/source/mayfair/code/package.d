module mayfair.code;

/*
    Code editing for Mayfair, over its TextView and TextBuffer: syntax highlighting, by language,
    and what a language server knows -- errors and warnings as they're typed, completion, what a
    name is, where it's defined.

        import mayfair;
        import mayfair.code;

        auto buffer = new TextBuffer(readText(path));
        auto view = new TextView(buffer).showLineNumbers(true).highlightCurrentLine(true);
        new SyntaxHighlighter(buffer, languageFor(path)).follow(view);

    No library but Mayfair's own: a language server is a program of its own, run when it's asked for.
*/

public import mayfair.code.language;
public import mayfair.code.highlighter;
