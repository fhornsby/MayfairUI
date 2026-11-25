module mayfair.text.buffer;

/*
    Text to edit, apart from any view of it: GTK's GtkTextBuffer. A TextView shows one, and
    several can show the same one, each with its own caret and scroll.

        auto buffer = new TextBuffer(readText("app.d"));
        auto view = new TextView(buffer);
        buffer.addListener((ref const BufferChange c) { ... });   // every edit, as it's made

    It's lines -- no line endings in them; `lineEnding` says what they're joined with when it's
    saved -- and a place in it is a TextPosition: a line, and a byte offset into it (UTF-8, as D
    strings are), always between characters. Every change is a replace(): what was between two
    places, for new text. Listeners hear each one, with what was there and what's there now, so a
    highlighter or a language server can follow along.

    Marks are places that move with the text, as an edit before them moves them: a caret, a
    bookmark, where a diagnostic is. Tags style what's between two places -- a colour, bold, an
    underline -- and move with the text too: GtkTextTag. A highlighter's styling is kept apart,
    line by line (setHighlights), since it's set afresh for a line whenever the line changes.

    Edits can be undone and redone. Each is a step of its own, unless several are made between
    beginUserAction and endUserAction -- a paste that replaces a selection, an indent of several
    lines -- or are typing or deleting one after another, which merge (see replace's `merge`).
    `modified` says whether it differs from when it was last saved, as setModified(false) says
    it was: undoing back to there isn't modified.
*/

import std.algorithm : max, min;
import std.array : replaceInPlace;
import std.string : indexOf;
import std.utf : stride, UTFException;
import mayfair.properties;
import mayfair.theme : Colour;

/// A place in a TextBuffer: a line, from 0, and a byte offset into it.
struct TextPosition
{
    int line;
    size_t column;

    int opCmp(const TextPosition o) const pure nothrow @nogc
    {
        if (line != o.line)
            return line < o.line ? -1 : 1;
        return column < o.column ? -1 : column > o.column ? 1 : 0;
    }
}

/// What a change did: replaced what was from `start` to `oldEnd` with what's from `start` to `newEnd`.
struct BufferChange
{
    TextPosition start;
    TextPosition oldEnd;   /// Where what was replaced ended, as the text was before
    TextPosition newEnd;   /// Where what replaced it ends, as the text is now
    string removed;        /// What was there
    string inserted;       /// What's there now

    /// How many lines more there are than before: fewer, if it's negative.
    int linesAdded() const pure nothrow @nogc { return newEnd.line - oldEnd.line; }
}

/// How a tag underlines what it's on.
enum Underline { none, single, squiggle }

/*
    A style for part of the text: GtkTextTag. Unset parts leave the text as it is; where tags
    overlap, the higher `priority` wins, and among equals the one applied last.
*/
final class TextTag
{
    this(string name = null) { this.name = name; }

    string name;
    int priority;
    bool hasForeground, hasBackground;
    Colour foreground, background;
    bool bold, italic, strikethrough;
    Underline underline;
    Colour underlineColour;      /// Its colour; the text's, if it's left clear

    TextTag colour(Colour c) { foreground = c; hasForeground = true; return this; }
    TextTag fill(Colour c) { background = c; hasBackground = true; return this; }
    TextTag weight(bool isBold) { bold = isBold; return this; }
    TextTag slanted(bool isItalic) { italic = isItalic; return this; }
    TextTag struck(bool isStruck) { strikethrough = isStruck; return this; }
    TextTag underlined(Underline u, Colour c = Colour(0, 0, 0, 0)) { underline = u; underlineColour = c; return this; }
    TextTag ranked(int p) { priority = p; return this; }
}

/// A tag on part of a line: bytes [start, end).
struct TagSpan
{
    size_t start, end;
    TextTag tag;
}

/// A place that moves with the text: see TextBuffer.createMark.
final class TextMark
{
    /// Where it is now.
    TextPosition position() const nothrow @nogc { return _position; }

    /// Whether text put in where it is goes after it (it stays left), rather than before it.
    bool leftGravity;

    /// Whether it's been deleted from its buffer, and moves no more.
    bool deleted() const nothrow @nogc { return _deleted; }

private:
    TextPosition _position;
    bool _deleted;
}

final class TextBuffer
{
public:
    this(string text = "")
    {
        setText(text);
    }

    // The text

    /// All of it, its lines joined with "\n".
    string text() const
    {
        import std.array : join;
        return lines.join("\n");
    }

    /// All of it, joined with lineEnding: what's saved.
    string textToSave() const
    {
        import std.array : join;
        return lines.join(_lineEnding);
    }

    /*
        Replaces all of it, as a file's loaded: not a change that can be undone, and the history
        starts again, unmodified. "\r\n" and "\r" become line breaks, and lineEnding is whichever
        the text has most of.
    */
    void setText(string text)
    {
        const removed = lines.length ? this.text : null;
        const oldEnd = endPosition;
        size_t crlf, lf;
        for (size_t i = 0; i < text.length; i++)
            if (text[i] == '\n')
            {
                if (i > 0 && text[i - 1] == '\r')
                    crlf++;
                else
                    lf++;
            }
        _lineEnding = crlf > lf ? "\r\n" : "\n";
        lines = splitLines(normalised(text));
        tags = new TagSpan[][lines.length];
        highlights = new TagSpan[][lines.length];
        ids = new ulong[lines.length];
        foreach (ref id; ids)
            id = ++idClock;
        foreach (m; marks)
            m._position = TextPosition(0, 0);
        undoStack = redoStack = null;
        merging = null;
        _version++;
        savedVersion = currentStep = 0;
        _setCanUndo(false);
        _setCanRedo(false);
        _setModified(false);
        auto change = BufferChange(TextPosition(0, 0), oldEnd, endPosition, removed, this.text);
        notify(change);
    }

    /// How many lines it has: one at least.
    int lineCount() const nothrow @nogc { return cast(int) lines.length; }

    /// Line `i`, without its line ending.
    string line(int i) const nothrow @nogc { return i >= 0 && i < lines.length ? lines[i] : null; }

    /// A number line `i` keeps until it changes, and no other line has had: for caching what's drawn of it.
    ulong lineId(int i) const nothrow @nogc { return i >= 0 && i < ids.length ? ids[i] : 0; }

    /// Where it ends: after its last character.
    TextPosition endPosition() const nothrow @nogc
    {
        return lines.length ? TextPosition(cast(int) lines.length - 1, lines[$ - 1].length) : TextPosition(0, 0);
    }

    /// `p`, moved to the nearest place there is: within the text, and between characters.
    TextPosition clamp(TextPosition p) const nothrow @nogc
    {
        if (p.line < 0)
            return TextPosition(0, 0);
        if (p.line >= lines.length)
            return endPosition;
        const l = lines[p.line];
        if (p.column > l.length)
            return TextPosition(p.line, l.length);
        // Back to the start of the character it's in
        size_t c = p.column;
        while (c > 0 && c < l.length && (l[c] & 0xC0) == 0x80)
            c--;
        return TextPosition(p.line, c);
    }

    /// What's from `from` to `to`, its lines joined with "\n".
    string textIn(TextPosition from, TextPosition to) const
    {
        from = clamp(from);
        to = clamp(to);
        if (to < from)
        {
            const t = from;
            from = to;
            to = t;
        }
        if (from.line == to.line)
            return lines[from.line][from.column .. to.column];
        string s = lines[from.line][from.column .. $];
        foreach (i; from.line + 1 .. to.line)
            s ~= "\n" ~ lines[i];
        return s ~ "\n" ~ lines[to.line][0 .. to.column];
    }

    /// What's saved between lines: "\n", or "\r\n" for a file that had them.
    mixin(declareProperty!(string, "lineEnding", `"\n"`));

    /// How many times it's changed: a number that's never the same for two states it's been in.
    ulong version_() const nothrow @nogc { return _version; }

    // Changing it

    /*
        Replaces what's from `from` to `to` with `text`, and says where the new text ends. Undone
        as one step with the edits before it if they're in the same user action, or -- given the
        same `merge`, "typing" say -- if it follows on from the last edit, which had it too.
    */
    TextPosition replace(TextPosition from, TextPosition to, string text, string merge = null)
    {
        from = clamp(from);
        to = clamp(to);
        if (to < from)
        {
            const t = from;
            from = to;
            to = t;
        }
        text = normalised(text);
        if (from == to && !text.length)
            return from;
        const removed = textIn(from, to);
        const end = apply(from, to, text);
        record(Step(from, removed, text, to, end), merge);
        return end;
    }

    /// Puts `text` in at `at`, and says where it ends.
    TextPosition insert(TextPosition at, string text, string merge = null) { return replace(at, at, text, merge); }

    /// Takes out what's from `from` to `to`.
    void remove(TextPosition from, TextPosition to, string merge = null) { replace(from, to, null, merge); }

    /// Edits from here to endUserAction() are undone and redone as one. They nest.
    void beginUserAction()
    {
        if (actionDepth++ == 0)
        {
            actionStart = undoStack.length;
            merging = null;
        }
    }

    /// ditto
    void endUserAction()
    {
        if (actionDepth == 0 || --actionDepth > 0)
            return;
        // The steps since it began, as one
        if (undoStack.length > actionStart + 1)
        {
            Step[] group;
            foreach (ref s; undoStack[actionStart .. $])
                group ~= s.parts.length ? s.parts : [s];
            Step whole;
            whole.parts = group;
            whole.id = undoStack[$ - 1].id;
            undoStack = undoStack[0 .. actionStart] ~ whole;
        }
        merging = null;
    }

    /// The next edit is a step of its own, even if it could merge with the last.
    void breakMerging() nothrow @nogc { merging = null; }

    // Undoing

    mixin(declareReadOnlyProperty!(bool, "canUndo", "false"));
    mixin(declareReadOnlyProperty!(bool, "canRedo", "false"));

    /// Whether it differs from when setModified(false) said it was saved.
    mixin(declareReadOnlyProperty!(bool, "modified", "false"));

    /// Says it's just been saved -- false -- or that it should count as changed whatever, true.
    void setModified(bool modified)
    {
        savedVersion = modified ? ulong.max : currentStep;
        _setModified(modified);
    }

    /// Undoes the last step, and says where it was: for a view to put its caret there.
    TextPosition undo()
    {
        if (!undoStack.length)
            return TextPosition(0, 0);
        auto s = undoStack[$ - 1];
        undoStack = undoStack[0 .. $ - 1];
        merging = null;
        TextPosition at;
        auto parts = s.parts.length ? s.parts : [s];
        foreach_reverse (ref p; parts)
            at = applyAndClamp(p.start, p.newEnd, p.removed);
        redoStack ~= s;
        currentStep = undoStack.length ? undoStack[$ - 1].id : 0;
        historyChanged();
        return at;
    }

    /// Redoes the last step undone, and says where it ends.
    TextPosition redo()
    {
        if (!redoStack.length)
            return TextPosition(0, 0);
        auto s = redoStack[$ - 1];
        redoStack = redoStack[0 .. $ - 1];
        merging = null;
        TextPosition at;
        auto parts = s.parts.length ? s.parts : [s];
        foreach (ref p; parts)
            at = applyAndClamp(p.start, p.oldEnd, p.inserted);
        undoStack ~= s;
        currentStep = s.id;
        historyChanged();
        return at;
    }

    // Marks

    /// A mark at `at`, moving with the text from now on.
    TextMark createMark(TextPosition at, bool leftGravity = false)
    {
        auto m = new TextMark;
        m._position = clamp(at);
        m.leftGravity = leftGravity;
        marks ~= m;
        return m;
    }

    /// Moves `m` to `at`.
    void moveMark(TextMark m, TextPosition at) { m._position = clamp(at); }

    void deleteMark(TextMark m)
    {
        foreach (i, o; marks)
            if (o is m)
            {
                marks = marks[0 .. i] ~ marks[i + 1 .. $];
                break;
            }
        m._deleted = true;
    }

    // Tags

    /// Puts `tag` on what's from `from` to `to`.
    void applyTag(TextTag tag, TextPosition from, TextPosition to)
    {
        from = clamp(from);
        to = clamp(to);
        if (to < from)
        {
            const t = from;
            from = to;
            to = t;
        }
        foreach (l; from.line .. to.line + 1)
        {
            const s = l == from.line ? from.column : 0, e = l == to.line ? to.column : lines[l].length;
            if (e > s || (from == to))
                tags[l] ~= TagSpan(s, e, tag);
        }
        tagsChanged(from.line, to.line);
    }

    /// Takes `tag` off what's from `from` to `to`, leaving it either side.
    void removeTag(TextTag tag, TextPosition from, TextPosition to)
    {
        from = clamp(from);
        to = clamp(to);
        if (to < from)
        {
            const t = from;
            from = to;
            to = t;
        }
        foreach (l; from.line .. to.line + 1)
        {
            const s = l == from.line ? from.column : 0, e = l == to.line ? to.column : size_t.max;
            TagSpan[] kept;
            foreach (sp; tags[l])
            {
                if (sp.tag !is tag || sp.end <= s || sp.start >= e)
                {
                    kept ~= sp;
                    continue;
                }
                if (sp.start < s)
                    kept ~= TagSpan(sp.start, s, tag);
                if (sp.end > e)
                    kept ~= TagSpan(e, sp.end, tag);
            }
            tags[l] = kept;
        }
        tagsChanged(from.line, to.line);
    }

    /// Takes `tag` off everywhere it is.
    void removeTagEverywhere(TextTag tag)
    {
        int first = int.max, last = -1;
        foreach (l, ref spans; tags)
        {
            TagSpan[] kept;
            foreach (sp; spans)
                if (sp.tag !is tag)
                    kept ~= sp;
            if (kept.length != spans.length)
            {
                spans = kept;
                first = min(first, cast(int) l);
                last = max(last, cast(int) l);
            }
        }
        if (last >= 0)
            tagsChanged(first, last);
    }

    /// The tags on line `i`.
    TagSpan[] tagsOn(int i) nothrow @nogc { return i >= 0 && i < tags.length ? tags[i] : null; }

    /// A highlighter's styling of line `i`, in place of what it had: kept apart from tags, and
    /// set afresh as the line changes (see the top).
    void setHighlights(int i, TagSpan[] spans)
    {
        if (i < 0 || i >= highlights.length)
            return;
        highlights[i] = spans;
        tagsChanged(i, i);
    }

    /// ditto
    TagSpan[] highlightsOn(int i) nothrow @nogc { return i >= 0 && i < highlights.length ? highlights[i] : null; }

    // Listeners

    /// Hears each change, once it's made.
    void addListener(void delegate(ref const BufferChange) listener) { listeners ~= listener; }

    /// ditto
    void removeListener(void delegate(ref const BufferChange) listener)
    {
        foreach (i, l; listeners)
            if (l is listener)
            {
                listeners = listeners[0 .. i] ~ listeners[i + 1 .. $];
                return;
            }
    }

    /// Hears that the tags or highlights of lines `from` to `to` changed.
    void addTagListener(void delegate(int from, int to) listener) { tagListeners ~= listener; }

    /// ditto
    void removeTagListener(void delegate(int from, int to) listener)
    {
        foreach (i, l; tagListeners)
            if (l is listener)
            {
                tagListeners = tagListeners[0 .. i] ~ tagListeners[i + 1 .. $];
                return;
            }
    }

    // Searching

    /*
        The next place `query` is, from `from` on, wrapping round to the start if `wrap` says --
        or, `backwards`, the one before it. A query of one line; `matchCase` and `wholeWord` as
        find bars have them. False if it isn't there.
    */
    bool find(string query, TextPosition from, out TextPosition start, out TextPosition end,
              bool matchCase = false, bool wholeWord = false, bool backwards = false, bool wrap = true) const
    {
        if (!query.length || query.indexOf('\n') >= 0)
            return false;
        from = clamp(from);
        const n = cast(int) lines.length;
        foreach (k; 0 .. n + 1)
        {
            int l = backwards ? from.line - k : from.line + k;
            if (!wrap && (l < 0 || l >= n))
                return false;
            l = ((l % n) + n) % n;
            const text = lines[l];
            size_t[] found = matchesIn(text, query, matchCase, wholeWord);
            if (backwards)
            {
                foreach_reverse (c; found)
                    if (k > 0 || c + query.length <= from.column || (k == n && c < from.column))
                    {
                        if (k == 0 && c + query.length > from.column)
                            continue;
                        start = TextPosition(l, c);
                        end = TextPosition(l, c + query.length);
                        return true;
                    }
            }
            else
                foreach (c; found)
                    if (k > 0 || c >= from.column)
                    {
                        if (k == n && c >= from.column)
                            break;
                        start = TextPosition(l, c);
                        end = TextPosition(l, c + query.length);
                        return true;
                    }
        }
        return false;
    }

    /// Every place `query` is: for highlighting them all.
    TextPosition[2][] findAll(string query, bool matchCase = false, bool wholeWord = false, size_t limit = 10_000) const
    {
        TextPosition[2][] all;
        if (!query.length || query.indexOf('\n') >= 0)
            return all;
        foreach (l, text; lines)
            foreach (c; matchesIn(text, query, matchCase, wholeWord))
            {
                all ~= [TextPosition(cast(int) l, c), TextPosition(cast(int) l, c + query.length)];
                if (all.length >= limit)
                    return all;
            }
        return all;
    }

    // UTF-16, as language servers count

    /// Byte `column` of line `l`, in UTF-16 code units.
    size_t utf16Column(int l, size_t column) const
    {
        const text = line(l);
        size_t units, i;
        while (i < column && i < text.length)
        {
            const b = text[i];
            const len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
            units += len == 4 ? 2 : 1;
            i += len;
        }
        return units;
    }

    /// UTF-16 code unit `units` of line `l`, as a byte column.
    size_t byteColumn(int l, size_t units) const
    {
        const text = line(l);
        size_t u, i;
        while (u < units && i < text.length)
        {
            const b = text[i];
            const len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
            u += len == 4 ? 2 : 1;
            i += len;
        }
        return i > text.length ? text.length : i;
    }

private:
    string[] lines;
    ulong[] ids;
    TagSpan[][] tags, highlights;
    TextMark[] marks;
    ulong idClock;
    ulong _version;
    void delegate(ref const BufferChange)[] listeners;
    void delegate(int, int)[] tagListeners;

    struct Step
    {
        TextPosition start;
        string removed, inserted;
        TextPosition oldEnd, newEnd;
        Step[] parts;        // a group's, in order: undone in reverse
        ulong id;
    }
    Step[] undoStack, redoStack;
    string merging;          // what the last step can merge with, if anything
    size_t actionDepth, actionStart;
    ulong stepClock, currentStep, savedVersion;

    /// Where `text` ends, put in at `start`.
    static TextPosition endOf(TextPosition start, string text) pure
    {
        import std.string : lastIndexOf;
        import std.algorithm : count;
        const breaks = cast(int) text.count('\n');
        if (!breaks)
            return TextPosition(start.line, start.column + text.length);
        return TextPosition(start.line + breaks, text.length - text.lastIndexOf('\n') - 1);
    }

    static string normalised(string text)
    {
        import std.array : replace;
        if (text.indexOf('\r') < 0)
            return text;
        return text.replace("\r\n", "\n").replace("\r", "\n");
    }

    static string[] splitLines(string text)
    {
        import std.array : split;
        auto parts = text.split("\n");
        return parts.length ? parts : [""];
    }

    static size_t[] matchesIn(string text, string query, bool matchCase, bool wholeWord)
    {
        import std.uni : isAlphaNum, toLower;
        size_t[] found;
        string hay = text, needle = query;
        if (!matchCase)
        {
            // Lowercased byte for byte where it's ASCII, so offsets stay the same
            char[] h = text.dup, q = query.dup;
            foreach (ref c; h) if (c >= 'A' && c <= 'Z') c += 32;
            foreach (ref c; q) if (c >= 'A' && c <= 'Z') c += 32;
            hay = cast(string) h;
            needle = cast(string) q;
        }
        bool word(size_t at)
        {
            if (!wholeWord)
                return true;
            bool wordChar(char c) { return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80; }
            if (at > 0 && wordChar(hay[at - 1]))
                return false;
            const e = at + needle.length;
            return e >= hay.length || !wordChar(hay[e]);
        }
        for (size_t from = 0; from + needle.length <= hay.length;)
        {
            const i = hay[from .. $].indexOf(needle);
            if (i < 0)
                break;
            const at = from + i;
            if (word(at))
                found ~= at;
            from = at + (needle.length ? needle.length : 1);
        }
        return found;
    }

    /// Makes the change, moving tags and marks with it, and tells the listeners. Where the new text ends.
    TextPosition apply(TextPosition from, TextPosition to, string text)
    {
        const removed = textIn(from, to);
        const prefix = lines[from.line][0 .. from.column], suffix = lines[to.line][to.column .. $];
        auto inserted = splitLines(text);
        string[] fresh;
        foreach (i, l; inserted)
            fresh ~= (i == 0 ? prefix : "") ~ l ~ (i == inserted.length - 1 ? suffix : "");
        const end = TextPosition(from.line + cast(int) inserted.length - 1,
                                 inserted.length == 1 ? from.column + inserted[0].length : inserted[$ - 1].length);

        // Tags: those before the change stay, those after it move with the text after it
        TagSpan[][] freshTags = new TagSpan[][fresh.length];
        TagSpan[][] freshHighlights = new TagSpan[][fresh.length];
        void carry(TagSpan[][] source, TagSpan[][] into)
        {
            foreach (sp; source[from.line])
                if (sp.start < from.column)
                    into[0] ~= TagSpan(sp.start, min(sp.end, from.column), sp.tag);
            const shift = cast(long) end.column - cast(long) to.column;
            foreach (sp; source[to.line])
                if (sp.end > to.column)
                {
                    const s = max(sp.start, to.column), e = sp.end;
                    into[$ - 1] ~= TagSpan(cast(size_t) (s + shift), cast(size_t) (e + shift), sp.tag);
                }
        }
        carry(tags, freshTags);
        carry(highlights, freshHighlights);
        ulong[] freshIds = new ulong[fresh.length];
        foreach (ref id; freshIds)
            id = ++idClock;

        replaceInPlace(lines, from.line, to.line + 1, fresh);
        replaceInPlace(tags, from.line, to.line + 1, freshTags);
        replaceInPlace(highlights, from.line, to.line + 1, freshHighlights);
        replaceInPlace(ids, from.line, to.line + 1, freshIds);

        // Marks: in what was replaced, to its start -- or its new end, for one that's at an
        // insertion point and doesn't stay left -- and after it, along with the text
        foreach (m; marks)
        {
            auto p = m._position;
            if (p < from || (p == from && (m.leftGravity || from != to)))
                continue;
            if (p <= to && !(p == to && from == to))
                p = p == to && !m.leftGravity ? end : from;
            else if (p == to)
                p = m.leftGravity ? from : end;
            else if (p.line == to.line)
                p = TextPosition(end.line, end.column + (p.column - to.column));
            else
                p = TextPosition(p.line + (end.line - to.line), p.column);
            m._position = p;
        }

        _version++;
        auto change = BufferChange(from, to, end, removed, text);
        notify(change);
        return end;
    }

    TextPosition applyAndClamp(TextPosition from, TextPosition to, string text)
    {
        return apply(clamp(from), clamp(to), text);
    }

    void record(Step s, string merge)
    {
        s.id = ++stepClock;
        redoStack = null;
        if (actionDepth == 0 && merge.length && merge == merging && undoStack.length && !undoStack[$ - 1].parts.length)
        {
            auto last = &undoStack[$ - 1];
            // Typing on from where the last typing ended, or deleting back to it, or forward from it
            if (s.removed.length == 0 && s.start == last.newEnd && last.removed.length == 0)
            {
                last.inserted ~= s.inserted;
                last.newEnd = s.newEnd;
                last.id = s.id;
                currentStep = s.id;
                historyChanged();
                return;
            }
            if (s.inserted.length == 0 && last.inserted.length == 0 && s.oldEnd == last.start)
            {
                last.removed = s.removed ~ last.removed;
                last.start = s.start;
                last.newEnd = s.start;
                last.oldEnd = endOf(s.start, last.removed);
                last.id = s.id;
                currentStep = s.id;
                historyChanged();
                return;
            }
            if (s.inserted.length == 0 && last.inserted.length == 0 && s.start == last.start)
            {
                last.removed ~= s.removed;
                last.oldEnd = endOf(last.start, last.removed);
                last.id = s.id;
                currentStep = s.id;
                historyChanged();
                return;
            }
        }
        undoStack ~= s;
        merging = merge;
        currentStep = s.id;
        historyChanged();
    }

    void historyChanged()
    {
        _setCanUndo(undoStack.length > 0);
        _setCanRedo(redoStack.length > 0);
        _setModified(currentStep != savedVersion);
    }

    void notify(ref BufferChange change)
    {
        foreach (l; listeners.dup)
            l(change);
    }

    void tagsChanged(int from, int to)
    {
        foreach (l; tagListeners.dup)
            l(from, to);
    }
}

unittest
{
    auto b = new TextBuffer("hello\nworld");
    assert(b.lineCount == 2 && b.line(1) == "world");
    // Typing merges into one step
    b.insert(TextPosition(0, 5), ",", "typing");
    b.insert(TextPosition(0, 6), " ", "typing");
    b.insert(TextPosition(0, 7), "there", "typing");
    assert(b.line(0) == "hello, there");
    assert(b.modified && b.canUndo);
    b.undo();
    assert(b.line(0) == "hello" && !b.modified, "one undo, all the typing");
    b.redo();
    assert(b.line(0) == "hello, there");

    // Across lines: a newline in, and joining lines out
    auto end = b.insert(TextPosition(0, 5), "\nnew\n");
    assert(b.lineCount == 4 && b.line(1) == "new" && b.line(2) == ", there" && end == TextPosition(2, 0));
    b.remove(TextPosition(0, 5), TextPosition(2, 0));
    assert(b.lineCount == 2 && b.line(0) == "hello, there");

    // Marks move with the text
    auto m = b.createMark(TextPosition(1, 2));
    b.insert(TextPosition(0, 0), "a\nb\n");
    assert(m.position == TextPosition(3, 2));
    b.insert(TextPosition(3, 0), "XX");
    assert(m.position == TextPosition(3, 4));
    b.remove(TextPosition(3, 0), TextPosition(3, 3));
    assert(m.position == TextPosition(3, 1));

    // Tags move, and stay clear of what's put in before them
    auto t = new TextTag("t");
    b.applyTag(t, TextPosition(3, 1), TextPosition(3, 3));
    b.insert(TextPosition(3, 0), "__");
    assert(b.tagsOn(3).length == 1 && b.tagsOn(3)[0].start == 3 && b.tagsOn(3)[0].end == 5);
    b.removeTag(t, TextPosition(3, 4), TextPosition(3, 5));
    assert(b.tagsOn(3).length == 1 && b.tagsOn(3)[0].end == 4);

    // A user action undoes as one
    b.beginUserAction();
    b.insert(TextPosition(0, 0), "1");
    b.insert(TextPosition(1, 0), "2");
    b.endUserAction();
    b.undo();
    assert(b.line(0) == "a" && b.line(1) == "b");

    // Deleting forward, merged, then undone and redone
    auto d = new TextBuffer("abcdef");
    d.remove(TextPosition(0, 1), TextPosition(0, 2), "deleting");
    d.remove(TextPosition(0, 1), TextPosition(0, 2), "deleting");
    assert(d.line(0) == "adef");
    d.undo();
    assert(d.line(0) == "abcdef");
    d.redo();
    assert(d.line(0) == "adef");
    // And backwards, as Backspace does
    d.remove(TextPosition(0, 3), TextPosition(0, 4), "deleting");
    d.remove(TextPosition(0, 2), TextPosition(0, 3), "deleting");
    assert(d.line(0) == "ad");
    d.undo();
    assert(d.line(0) == "adef");
    d.redo();
    assert(d.line(0) == "ad");

    // Line endings: kept to save with
    auto w = new TextBuffer("one\r\ntwo\r\n");
    assert(w.lineEnding == "\r\n" && w.lineCount == 3 && w.line(1) == "two");
    assert(w.textToSave == "one\r\ntwo\r\n");

    // Finding
    auto f = new TextBuffer("foo bar\nFoo food\n");
    TextPosition s, e;
    assert(f.find("foo", TextPosition(0, 1), s, e) && s == TextPosition(1, 0));
    assert(f.find("foo", TextPosition(1, 1), s, e, false, true) && s == TextPosition(0, 0), "whole words, wrapping");
    assert(f.findAll("foo").length == 3);
    assert(f.find("foo", TextPosition(1, 0), s, e, false, false, true) && s == TextPosition(0, 0), "backwards");

    // UTF-16 columns, as a language server has them
    auto u = new TextBuffer("a😀b");
    assert(u.utf16Column(0, 5) == 3 && u.byteColumn(0, 3) == 5);
    assert(u.clamp(TextPosition(0, 2)) == TextPosition(0, 1), "inside a character, to its start");
}
