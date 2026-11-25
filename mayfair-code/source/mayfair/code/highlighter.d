module mayfair.code.highlighter;

/*
    Syntax highlighting: a TextBuffer's lines coloured as their language says, kept up to date as
    it's edited.

        auto highlighter = new SyntaxHighlighter(buffer, languageFor(path));
        highlighter.follow(view);   // light or dark with the view, and its editing set for the language

    Each line's scanned on its own, given how the line before it ended -- inside a block comment,
    or a string that runs on -- and how it ends is kept. So an edit rescans from its line until a
    line ends as it did before, which is usually the line itself; and opening a comment rescans on
    until it's closed. A long file is highlighted a slice at a time, the part in view first, so
    it's never kept waiting for.

    The styling is the buffer's highlights (TextBuffer.setHighlights), under any tags: so search
    matches and a language server's diagnostics show over it.
*/

import std.algorithm : canFind, max, min;
import std.ascii : isAlpha, isAlphaNum, isDigit, isUpper, isLower;
import std.string : startsWith;
import mayfair;
import mayfair.code.language;

/// How a line ended, for the next one: inside a comment, a string, a fence, a tag, or none of them.
struct LineState
{
    enum Kind : ubyte { none, block, nested, string_, fence, tag }
    Kind kind;
    ubyte quote;     // which of the language's quotes the string's in
    ushort depth;    // how deep in nested comments
}

/// A stretch of a line, and what it is.
struct Token
{
    size_t start, end;
    Syntax syntax;
}

/*
    Line `s` of code in `l`, as tokens, given the line before ended in `state`; and how this line
    ends, in `state`, for the next.
*/
Token[] scanLine(const Language l, string s, ref LineState state)
{
    Token[] tokens;
    void add(size_t a, size_t b, Syntax k)
    {
        if (b > a)
            tokens ~= Token(a, b, k);
    }
    bool at(size_t i, string what) { return what.length && i + what.length <= s.length && s[i .. i + what.length] == what; }
    bool identChar(char c) { return c == '_' || isAlphaNum(c) || c >= 0x80; }

    if (l.markdown)
        return markdownLine(s, state);

    size_t i;
    // A comment that runs on: to its close
    size_t blockEnd(size_t from, bool nested, string open, string close)
    {
        size_t j = from;
        while (j < s.length)
        {
            if (nested && at(j, open))
            {
                state.depth++;
                j += open.length;
                continue;
            }
            if (at(j, close))
            {
                j += close.length;
                if (!nested || --state.depth == 0)
                {
                    state.kind = LineState.Kind.none;
                    return j;
                }
                continue;
            }
            j++;
        }
        return s.length;
    }
    // A string that runs on, or starts here: to its close, its escapes marked
    size_t stringEnd(size_t from, ref const Quote q, size_t qi)
    {
        size_t j = from;
        while (j < s.length)
        {
            if (q.escape && s[j] == q.escape && j + 1 < s.length)
            {
                add(j, j + 2, Syntax.escape);
                j += 2;
                continue;
            }
            if (at(j, q.close))
            {
                state.kind = LineState.Kind.none;
                return j + q.close.length;
            }
            j++;
        }
        if (q.multiline)
        {
            state.kind = LineState.Kind.string_;
            state.quote = cast(ubyte) qi;
        }
        else
            state.kind = LineState.Kind.none;
        return s.length;
    }

    // Carried on from the line before
    final switch (state.kind)
    {
        case LineState.Kind.none, LineState.Kind.fence:
            break;
        case LineState.Kind.block:
            i = blockEnd(0, l.nestedBlocks, l.blockOpen, l.blockClose);
            add(0, i, Syntax.comment);
            break;
        case LineState.Kind.nested:
            i = blockEnd(0, true, l.nestedOpen, l.nestedClose);
            add(0, i, Syntax.comment);
            break;
        case LineState.Kind.string_:
        {
            const q = l.quotes[min(state.quote, l.quotes.length - 1)];
            const start = tokens.length;
            i = stringEnd(0, q, state.quote);
            tokens = tokens[0 .. start] ~ Token(0, i, Syntax.string_) ~ tokens[start .. $];
            break;
        }
        case LineState.Kind.tag:
            break;
    }
    if (state.kind != LineState.Kind.none && state.kind != LineState.Kind.tag)
        return tokens;

    if (l.markup)
        return markupLine(l, s, i, state, tokens);

    // A line's start: a section header, a key, a directive
    size_t first = i;
    while (first < s.length && (s[first] == ' ' || s[first] == '\t'))
        first++;
    if (l.sectionHeaders && first < s.length && s[first] == '[')
    {
        add(first, s.length, Syntax.heading);
        return tokens;
    }
    if (l.preprocessor && first < s.length && s[first] == '#')
    {
        // The directive, then the rest of the line as code (a string, a comment)
        size_t e = first + 1;
        while (e < s.length && (s[e] == ' ' || isAlpha(s[e])))
            e++;
        add(first, e, Syntax.preprocessor);
        i = e;
    }
    if (l.keysBeforeEquals && first < s.length)
    {
        size_t e = first;
        while (e < s.length && s[e] != '=' && s[e] != '#' && s[e] != '"')
            e++;
        if (e < s.length && s[e] == '=')
        {
            size_t k = e;
            while (k > first && s[k - 1] == ' ')
                k--;
            add(first, k, Syntax.property);
            i = e;
        }
    }
    if (l.keysBeforeColon && !l.quotes.canFind!(q => q.open == "\"" && q.escape == '\\') && first < s.length)
    {
        // YAML: a key at the line's start, or after a list's "- "
        size_t k = first;
        if (k + 1 < s.length && s[k] == '-' && s[k + 1] == ' ')
            k += 2;
        size_t e = k;
        while (e < s.length && s[e] != ':' && s[e] != '#' && s[e] != '"' && s[e] != '\'')
            e++;
        if (e < s.length && s[e] == ':' && (e + 1 == s.length || s[e + 1] == ' ') && e > k)
        {
            add(k, e, Syntax.property);
            i = e + 1;
        }
    }

    while (i < s.length)
    {
        const c = s[i];
        if (c == ' ' || c == '\t')
        {
            i++;
            continue;
        }
        // Comments
        if (l.lineComment.length && at(i, l.lineComment)
            && (!l.variables || i == 0 || s[i - 1] == ' ' || s[i - 1] == '\t'))
        {
            add(i, s.length, Syntax.comment);
            break;
        }
        if (l.nestedOpen.length && at(i, l.nestedOpen))
        {
            state.kind = LineState.Kind.nested;
            state.depth = 1;
            const e = blockEnd(i + l.nestedOpen.length, true, l.nestedOpen, l.nestedClose);
            add(i, e, Syntax.comment);
            i = e;
            continue;
        }
        if (l.blockOpen.length && at(i, l.blockOpen))
        {
            state.kind = LineState.Kind.block;
            state.depth = 1;
            const e = blockEnd(i + l.blockOpen.length, l.nestedBlocks, l.blockOpen, l.blockClose);
            add(i, e, Syntax.comment);
            i = e;
            continue;
        }
        // Strings: the longest opener that's here, and not the end of a name (r"..." isn't in "for")
        size_t best = size_t.max;
        foreach (qi, ref q; l.quotes)
            if (at(i, q.open) && (best == size_t.max || q.open.length > l.quotes[best].open.length))
                if (!(identChar(q.open[0]) && i > 0 && identChar(s[i - 1])))
                    best = qi;
        if (best != size_t.max)
        {
            const q = l.quotes[best];
            const start = tokens.length;
            const e = stringEnd(i + q.open.length, q, best);
            // A JSON key: a string before a colon
            Syntax kind = Syntax.string_;
            if (l.keysBeforeColon)
            {
                size_t k = e;
                while (k < s.length && s[k] == ' ')
                    k++;
                if (k < s.length && s[k] == ':')
                    kind = Syntax.property;
            }
            tokens = tokens[0 .. start] ~ Token(i, e, kind) ~ tokens[start .. $];
            i = e;
            continue;
        }
        // Numbers
        if (isDigit(c) || (c == '.' && i + 1 < s.length && isDigit(s[i + 1])))
        {
            size_t e = i + 1;
            while (e < s.length && (isAlphaNum(s[e]) || s[e] == '_' || s[e] == '.'
                                    || ((s[e] == '+' || s[e] == '-') && (s[e - 1] == 'e' || s[e - 1] == 'E')
                                        && !(s[i] == '0' && i + 1 < s.length && (s[i + 1] == 'x' || s[i + 1] == 'X')))))
            {
                if (s[e] == '.' && e + 1 < s.length && s[e + 1] == '.')
                    break; // a range: 0..10
                e++;
            }
            add(i, e, Syntax.number);
            i = e;
            continue;
        }
        // A shell's variables
        if (l.variables && c == '$' && i + 1 < s.length)
        {
            size_t e = i + 1;
            if (s[e] == '{' || s[e] == '(')
            {
                const close = s[e] == '{' ? '}' : ')';
                while (e < s.length && s[e] != close)
                    e++;
                e = min(e + 1, s.length);
            }
            else
                while (e < s.length && (identChar(s[e]) || (e == i + 1 && "@*#?$!0123456789".canFind(s[e]))))
                    e++;
            add(i, e, Syntax.variable);
            i = e;
            continue;
        }
        // CSS: a colour, a class or an id in a selector, an at-rule
        if (l.css && c == '#' && i + 1 < s.length && isAlphaNum(s[i + 1]))
        {
            size_t e = i + 1;
            while (e < s.length && (isAlphaNum(s[e]) || s[e] == '-' || s[e] == '_'))
                e++;
            add(i, e, cssValueAhead(s, i) ? Syntax.number : Syntax.type);
            i = e;
            continue;
        }
        if (l.css && c == '.' && i + 1 < s.length && (isAlpha(s[i + 1]) || s[i + 1] == '-'))
        {
            size_t e = i + 1;
            while (e < s.length && (isAlphaNum(s[e]) || s[e] == '-' || s[e] == '_'))
                e++;
            add(i, e, Syntax.type);
            i = e;
            continue;
        }
        // Attributes, decorators, at-rules
        if ((l.decorators || l.css) && c == '@' && i + 1 < s.length && (isAlpha(s[i + 1]) || s[i + 1] == '_'))
        {
            size_t e = i + 1;
            while (e < s.length && (identChar(s[e]) || s[e] == '.' || (l.css && s[e] == '-')))
                e++;
            add(i, e, l.css ? Syntax.keyword : Syntax.attribute);
            i = e;
            continue;
        }
        // Words
        if (isAlpha(c) || c == '_' || c >= 0x80 || (l.css && c == '-' && i + 1 < s.length && isAlpha(s[i + 1])))
        {
            size_t e = i + 1;
            while (e < s.length && (identChar(s[e]) || (l.css && s[e] == '-') || (s[e] == '?' && l.name == "Ruby")))
                e++;
            const word = s[i .. e];
            size_t k = e;
            while (k < s.length && s[k] == ' ')
                k++;
            const next = k < s.length ? s[k] : 0;
            Syntax kind;
            // After a dot it's a member, or part of a module's name: not a keyword or a type
            const member = i > 0 && s[i - 1] == '.' && !l.css && !(i > 1 && s[i - 2] == '.');
            if (member)
                kind = next == '(' ? Syntax.function_ : Syntax.none;
            else if (l.hasKeyword(word))
                kind = Syntax.keyword;
            else if (l.hasType(word))
                kind = Syntax.type;
            else if (l.hasConstant(word))
                kind = Syntax.constant;
            else if (l.hasBuiltin(word))
                kind = Syntax.builtin;
            else if (l.css && next == ':' && !cssSelectorAhead(s, e))
                kind = Syntax.property;
            else if (l.css)
                kind = cssValueAhead(s, i) ? Syntax.none : Syntax.tag;
            else if (next == '(' || (next == '!' && l.name == "Rust"))
                kind = Syntax.function_;
            else if (l.capitalisedTypes && isUpper(word[0]) && word.length > 1 && hasLower(word))
                kind = Syntax.type;
            else if (l.keysBeforeColon && next == ':')
                kind = Syntax.property;
            add(i, e, kind);
            i = e;
            continue;
        }
        i++;
    }
    if (state.kind == LineState.Kind.tag)
        state.kind = LineState.Kind.none;
    return tokens;
}

private bool hasLower(string w)
{
    foreach (c; w)
        if (isLower(c))
            return true;
    return false;
}

/// In CSS, whether what's at `i` is a value -- after a property's colon -- rather than in a selector.
private bool cssValueAhead(string s, size_t i)
{
    foreach_reverse (c; s[0 .. i])
    {
        if (c == ':')
            return true;
        if (c == ';' || c == '{' || c == '}')
            return false;
    }
    return false;
}

/// In CSS, whether the line goes on to a "{": a selector, with a pseudo-class, rather than a property.
private bool cssSelectorAhead(string s, size_t from)
{
    foreach (c; s[from .. $])
    {
        if (c == '{')
            return true;
        if (c == ';' || c == '}')
            return false;
    }
    return false;
}

/// HTML and XML: <tags>, their attributes and values, &entities;, and what's between them as text.
private Token[] markupLine(const Language l, string s, size_t i, ref LineState state, Token[] tokens)
{
    void add(size_t a, size_t b, Syntax k)
    {
        if (b > a)
            tokens ~= Token(a, b, k);
    }
    bool inTag = state.kind == LineState.Kind.tag;
    while (i < s.length)
    {
        if (!inTag)
        {
            if (s[i .. $].startsWith("<!--"))
            {
                size_t e = i + 4;
                while (e + 3 <= s.length && s[e .. e + 3] != "-->")
                    e++;
                if (e + 3 <= s.length)
                {
                    add(i, e + 3, Syntax.comment);
                    i = e + 3;
                    continue;
                }
                add(i, s.length, Syntax.comment);
                state.kind = LineState.Kind.block;
                return tokens;
            }
            if (s[i] == '<' && i + 1 < s.length && (isAlpha(s[i + 1]) || s[i + 1] == '/' || s[i + 1] == '!' || s[i + 1] == '?'))
            {
                size_t e = i + 1;
                if (s[e] == '/' || s[e] == '!' || s[e] == '?')
                    e++;
                while (e < s.length && (isAlphaNum(s[e]) || s[e] == '-' || s[e] == ':' || s[e] == '_' || s[e] == '.'))
                    e++;
                add(i, e, s[i + 1] == '!' || s[i + 1] == '?' ? Syntax.preprocessor : Syntax.tag);
                i = e;
                inTag = true;
                continue;
            }
            if (s[i] == '&')
            {
                size_t e = i + 1;
                while (e < s.length && e - i < 12 && (isAlphaNum(s[e]) || s[e] == '#'))
                    e++;
                if (e < s.length && s[e] == ';')
                {
                    add(i, e + 1, Syntax.constant);
                    i = e + 1;
                    continue;
                }
            }
            i++;
            continue;
        }
        // Inside a tag: attributes, values, and its end
        const c = s[i];
        if (c == '>' || (c == '/' && i + 1 < s.length && s[i + 1] == '>') || (c == '?' && i + 1 < s.length && s[i + 1] == '>'))
        {
            const e = c == '>' ? i + 1 : i + 2;
            add(i, e, Syntax.tag);
            i = e;
            inTag = false;
            continue;
        }
        if (c == '"' || c == '\'')
        {
            size_t e = i + 1;
            while (e < s.length && s[e] != c)
                e++;
            add(i, min(e + 1, s.length), Syntax.string_);
            i = min(e + 1, s.length);
            continue;
        }
        if (isAlpha(c) || c == '_' || c == ':' || c == '@')
        {
            size_t e = i + 1;
            while (e < s.length && (isAlphaNum(s[e]) || s[e] == '-' || s[e] == ':' || s[e] == '_' || s[e] == '.'))
                e++;
            add(i, e, Syntax.property);
            i = e;
            continue;
        }
        i++;
    }
    state.kind = inTag ? LineState.Kind.tag : LineState.Kind.none;
    return tokens;
}

/// Markdown, a line at a time: headings, fences, quotes, lists, `code`, **strong**, *emphasis*, [links](url).
private Token[] markdownLine(string s, ref LineState state)
{
    Token[] tokens;
    void add(size_t a, size_t b, Syntax k)
    {
        if (b > a)
            tokens ~= Token(a, b, k);
    }
    size_t first;
    while (first < s.length && s[first] == ' ')
        first++;
    const rest = s[first .. $];
    if (rest.startsWith("```") || rest.startsWith("~~~"))
    {
        add(0, s.length, Syntax.string_);
        state.kind = state.kind == LineState.Kind.fence ? LineState.Kind.none : LineState.Kind.fence;
        return tokens;
    }
    if (state.kind == LineState.Kind.fence)
    {
        add(0, s.length, Syntax.string_);
        return tokens;
    }
    if (rest.startsWith("#"))
    {
        add(0, s.length, Syntax.heading);
        return tokens;
    }
    if (rest.startsWith(">"))
    {
        add(0, s.length, Syntax.comment);
        return tokens;
    }
    size_t i = first;
    if (rest.startsWith("- ") || rest.startsWith("* ") || rest.startsWith("+ "))
    {
        add(first, first + 1, Syntax.keyword);
        i = first + 2;
    }
    else
    {
        size_t e = first;
        while (e < s.length && isDigit(s[e]))
            e++;
        if (e > first && e + 1 < s.length && s[e] == '.' && s[e + 1] == ' ')
        {
            add(first, e + 1, Syntax.keyword);
            i = e + 2;
        }
    }
    while (i < s.length)
    {
        const c = s[i];
        if (c == '`')
        {
            size_t e = i + 1;
            while (e < s.length && s[e] != '`')
                e++;
            add(i, min(e + 1, s.length), Syntax.string_);
            i = min(e + 1, s.length);
            continue;
        }
        if ((c == '*' || c == '_') && i + 1 < s.length && s[i + 1] == c)
        {
            size_t e = i + 2;
            while (e + 1 < s.length && !(s[e] == c && s[e + 1] == c))
                e++;
            if (e + 1 < s.length)
            {
                add(i, e + 2, Syntax.strong);
                i = e + 2;
                continue;
            }
        }
        if ((c == '*' || c == '_') && i + 1 < s.length && s[i + 1] != ' ' && (i == 0 || !isAlphaNum(s[i - 1])))
        {
            size_t e = i + 1;
            while (e < s.length && s[e] != c)
                e++;
            if (e < s.length && e > i + 1)
            {
                add(i, e + 1, Syntax.emphasis);
                i = e + 1;
                continue;
            }
        }
        if (c == '[')
        {
            size_t e = i + 1;
            while (e < s.length && s[e] != ']')
                e++;
            if (e + 1 < s.length && s[e + 1] == '(')
            {
                size_t u = e + 2;
                while (u < s.length && s[u] != ')')
                    u++;
                add(i, min(u + 1, s.length), Syntax.link);
                i = min(u + 1, s.length);
                continue;
            }
        }
        i++;
    }
    return tokens;
}

/// The colours, and weights, highlighted code is drawn in.
struct SyntaxPalette
{
    Colour[Syntax.max + 1] colours;
    bool[Syntax.max + 1] bold, italic;

    /// Light, on a pale background.
    static SyntaxPalette light()
    {
        SyntaxPalette p;
        with (Syntax)
        {
            p.set(keyword, 0xcf222e);
            p.set(type, 0x953800);
            p.set(constant, 0x0550ae);
            p.set(number, 0x0550ae);
            p.set(string_, 0x0a3069);
            p.set(escape, 0x116329);
            p.set(comment, 0x6e7781, false, true);
            p.set(preprocessor, 0xcf222e);
            p.set(function_, 0x8250df);
            p.set(builtin, 0x0550ae);
            p.set(attribute, 0x8250df);
            p.set(property, 0x0550ae);
            p.set(variable, 0x953800);
            p.set(heading, 0x0550ae, true);
            p.set(emphasis, 0x24292f, false, true);
            p.set(strong, 0x24292f, true);
            p.set(link, 0x0969da);
            p.set(tag, 0x116329);
        }
        return p;
    }

    /// Dark, on a dark background.
    static SyntaxPalette dark()
    {
        SyntaxPalette p;
        with (Syntax)
        {
            p.set(keyword, 0xff7b72);
            p.set(type, 0xffa657);
            p.set(constant, 0x79c0ff);
            p.set(number, 0x79c0ff);
            p.set(string_, 0xa5d6ff);
            p.set(escape, 0x7ee787);
            p.set(comment, 0x8b949e, false, true);
            p.set(preprocessor, 0xff7b72);
            p.set(function_, 0xd2a8ff);
            p.set(builtin, 0x79c0ff);
            p.set(attribute, 0xd2a8ff);
            p.set(property, 0x79c0ff);
            p.set(variable, 0xffa657);
            p.set(heading, 0x79c0ff, true);
            p.set(emphasis, 0xc9d1d9, false, true);
            p.set(strong, 0xc9d1d9, true);
            p.set(link, 0x58a6ff);
            p.set(tag, 0x7ee787);
        }
        return p;
    }

    void set(Syntax s, uint rgb, bool isBold = false, bool isItalic = false)
    {
        colours[s] = Colour(cast(ubyte) (rgb >> 16), cast(ubyte) (rgb >> 8), cast(ubyte) rgb, 255);
        bold[s] = isBold;
        italic[s] = isItalic;
    }
}

/// Highlights a buffer's lines as its language says, as it's edited.
final class SyntaxHighlighter
{
public:
    this(TextBuffer buffer, Language language, SyntaxPalette palette = SyntaxPalette.light)
    {
        this.buffer = buffer;
        foreach (i, ref t; tags)
            t = new TextTag("syntax");
        setPalette(palette);
        buffer.addListener(&edited);
        setLanguage(language);
    }

    /// What it reads the text as: null for none, and nothing's highlighted.
    void setLanguage(Language language)
    {
        this.language = language;
        generation++;
        states = new LineState[buffer.lineCount];
        stale = new bool[buffer.lineCount];
        stale[] = true;
        if (!language)
        {
            foreach (l; 0 .. buffer.lineCount)
                if (buffer.highlightsOn(l).length)
                    buffer.setHighlights(l, null);
            return;
        }
        highlightFrom(0, firstSlice);
    }

    /// The colours it draws in.
    void setPalette(SyntaxPalette p)
    {
        palette = p;
        foreach (i, t; tags)
        {
            t.colour(p.colours[i]);
            t.weight(p.bold[i]).slanted(p.italic[i]);
            t.hasForeground = i != Syntax.none;
        }
        buffer.restyled();
    }

    /*
        Sets `view` up for the language -- its comment, tabs or spaces and their width -- and keeps
        to the light palette or the dark as the view's text is dark or light: as its theme goes.
    */
    void follow(TextView view)
    {
        if (language)
        {
            view.setLineComment(language.lineComment);
            view.setInsertSpaces(language.insertSpaces);
            view.setTabWidth(language.tabWidth);
        }
        void match()
        {
            const t = view.textFill;
            const lightText = (t.r * 299 + t.g * 587 + t.b * 114) / 1000 > 128;
            setPalette(lightText ? SyntaxPalette.dark : SyntaxPalette.light);
        }
        view.textFillProperty.addListener((Colour was, Colour now) { match(); });
        match();
    }

    /// Stops following the buffer, and takes its highlighting off.
    void detach()
    {
        buffer.removeListener(&edited);
        generation++;
        foreach (l; 0 .. buffer.lineCount)
            buffer.setHighlights(l, null);
    }

    /// The tag a kind of syntax is drawn with: for an app's own use, or tests.
    TextTag tagFor(Syntax s) { return tags[s]; }

private:
    TextBuffer buffer;
    Language language;
    SyntaxPalette palette;
    TextTag[Syntax.max + 1] tags;
    LineState[] states;     // how each line ended, as last scanned
    bool[] stale;           // not scanned since it changed
    uint generation;
    enum firstSlice = 3000, slice = 4000;

    void edited(ref const BufferChange c)
    {
        if (!language)
            return;
        // The states go with their lines, those changed scanned again
        import std.array : replaceInPlace;
        const added = c.newEnd.line - c.start.line + 1;
        auto fresh = new LineState[added];
        auto freshStale = new bool[added];
        freshStale[] = true;
        if (c.oldEnd.line < states.length)
        {
            replaceInPlace(states, c.start.line, c.oldEnd.line + 1, fresh);
            replaceInPlace(stale, c.start.line, c.oldEnd.line + 1, freshStale);
        }
        else
        {
            states = new LineState[buffer.lineCount];
            stale = new bool[buffer.lineCount];
            stale[] = true;
        }
        highlightFrom(c.start.line, firstSlice);
    }

    /*
        Scans from line `from` on: until a line ends as it did before and the next isn't stale,
        or `budget` lines, then on in slices, between frames, while anything's left stale.
    */
    void highlightFrom(int from, int budget)
    {
        const gen = ++generation;
        int l = from;
        const count = buffer.lineCount;
        int scanned;
        while (l < count)
        {
            if (scanned >= budget)
            {
                Platform.runLater({
                    if (gen == generation)
                        highlightFrom(l, slice);
                });
                return;
            }
            auto state = l > 0 ? states[l - 1] : LineState.init;
            auto tokens = scanLine(language, buffer.line(l), state);
            TagSpan[] spans;
            spans.reserve(tokens.length);
            foreach (t; tokens)
                if (t.syntax != Syntax.none)
                    spans ~= TagSpan(t.start, t.end, tags[t.syntax]);
            buffer.setHighlights(l, spans);
            const settled = !stale[l] && states[l] == state;
            states[l] = state;
            stale[l] = false;
            scanned++;
            l++;
            if (settled && (l >= count || !stale[l]))
                return;
        }
    }
}

unittest
{
    // What's coloured in a line, in order
    Syntax[] kinds(const Language l, string line, ref LineState st)
    {
        Syntax[] k;
        foreach (t; scanLine(l, line, st))
            if (t.syntax != Syntax.none)
                k ~= t.syntax;
        return k;
    }
    with (Syntax)
    {
        auto d = languageNamed("D");
        LineState st;
        assert(kinds(d, `int x = 42; // the answer`, st) == [type, number, comment]);
        assert(kinds(d, `import std.string;`, st) == [keyword], "a module's name isn't a type");
        // A block comment that runs on, and ends on the next line
        st = LineState.init;
        kinds(d, "x /* open", st);
        assert(st.kind == LineState.Kind.block);
        assert(kinds(d, "still */ return;", st) == [comment, keyword] && st.kind == LineState.Kind.none);
        // Nesting /+ +/
        st = LineState.init;
        kinds(d, "/+ a /+ b +/", st);
        assert(st.kind == LineState.Kind.nested && st.depth == 1);
        // Strings, their escapes, functions, types by their capital
        st = LineState.init;
        assert(kinds(d, `writeln("a\n", Foo.bar);`, st) == [function_, string_, escape, type]);
        // Python: a decorator, and a triple-quoted string over lines
        auto py = languageNamed("Python");
        st = LineState.init;
        assert(kinds(py, `@property`, st) == [attribute]);
        kinds(py, `x = """doc`, st);
        assert(st.kind == LineState.Kind.string_);
        assert(kinds(py, `more""" if True else None`, st) == [string_, keyword, constant, keyword, constant]);
        // JSON: keys, and values
        st = LineState.init;
        assert(kinds(languageNamed("JSON"), `"name": "value", "n": 1, "ok": true`, st)
               == [property, string_, property, number, property, constant]);
        // YAML, TOML, Shell
        st = LineState.init;
        assert(kinds(languageNamed("YAML"), "  - name: web # a comment", st) == [property, comment]);
        st = LineState.init;
        assert(kinds(languageNamed("TOML"), `version = "1.0"`, st) == [property, string_]);
        st = LineState.init;
        assert(kinds(languageNamed("Shell"), `echo "$HOME" # done`, st) == [builtin, string_, comment]);
        // HTML: tags, attributes, values, entities
        st = LineState.init;
        assert(kinds(languageNamed("HTML"), `<a href="x">&amp;</a>`, st) == [tag, property, string_, tag, constant, tag, tag]);
        // Markdown
        st = LineState.init;
        assert(kinds(languageNamed("Markdown"), "Some **strong** and `code`", st) == [strong, string_]);
        // C's preprocessor
        st = LineState.init;
        assert(kinds(languageNamed("C"), `#include <stdio.h>`, st)[0] == preprocessor);
    }
}
