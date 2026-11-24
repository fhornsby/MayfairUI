module mayfair.pdf.types;

/*
    What a PDF is made of, as Mayfair has it: sizes and places in points (1/72 inch) from a page's
    top left, y going down, as the page is shown -- its own /Rotate applied, whatever PDF's own
    upside-down coordinates were -- and the page's text, links and outline, read once by the
    engine and kept.
*/

/// A size, in points.
struct PdfSize
{
    float width = 0, height = 0;
}

/// A rectangle, in points from a page's top left.
struct PdfRect
{
    float x = 0, y = 0, width = 0, height = 0;

    float right() const nothrow @nogc pure { return x + width; }
    float bottom() const nothrow @nogc pure { return y + height; }
    bool empty() const nothrow @nogc pure { return !(width > 0 && height > 0); }

    bool contains(float px, float py) const nothrow @nogc pure
    {
        return px >= x && px < right && py >= y && py < bottom;
    }

    bool intersects(PdfRect o) const nothrow @nogc pure
    {
        return x < o.right && o.x < right && y < o.bottom && o.y < bottom;
    }

    /// The smallest rectangle round both.
    PdfRect union_(PdfRect o) const nothrow @nogc pure
    {
        if (empty)
            return o;
        if (o.empty)
            return this;
        const l = x < o.x ? x : o.x, t = y < o.y ? y : o.y;
        const r = right > o.right ? right : o.right, b = bottom > o.bottom ? bottom : o.bottom;
        return PdfRect(l, t, r - l, b - t);
    }

    /// Where the two overlap; empty if they don't.
    PdfRect intersection(PdfRect o) const nothrow @nogc pure
    {
        const l = x > o.x ? x : o.x, t = y > o.y ? y : o.y;
        const r = right < o.right ? right : o.right, b = bottom < o.bottom ? bottom : o.bottom;
        return r > l && b > t ? PdfRect(l, t, r - l, b - t) : PdfRect.init;
    }
}

/// What a document's doing.
enum PdfStatus
{
    loading,        /// Being opened
    ready,          /// Open: its pages can be read
    needsPassword,  /// Encrypted: open it again, with the password
    failed,         /// It couldn't be opened: see error
    closed,         /// close() was called
}

/// What went wrong.
struct PdfError
{
    PdfErrorKind kind;
    /// What to tell the user.
    string message;
    /// The details, for a log or a bug report.
    string details;

    bool opCast(T : bool)() const nothrow @nogc { return kind != PdfErrorKind.none; }

    string toString() const
    {
        return details.length ? message ~ " (" ~ details ~ ")" : message;
    }
}

/// ditto
enum PdfErrorKind
{
    none,
    noEngine,           /// No engine to read it with: see PdfDocument.setEngine
    engineUnavailable,  /// The engine couldn't start: its library isn't there, say
    notFound,           /// There's no file there
    unreadable,         /// It couldn't be read
    notPdf,             /// It isn't a PDF, or is too damaged to open
    wrongPassword,      /// The password given wasn't right
    unsupported,        /// Its security handler, or something else in it, isn't one the engine reads
    other,
}

/// What a document is, beyond what it says about itself.
struct PdfDocumentInfo
{
    string pdfVersion;      /// "1.7", say; empty if it doesn't say
    bool encrypted;         /// Whether it's protected by a password, or encrypted with none
    bool hasForm;           /// Whether it has fields to fill in
    bool editable;          /// Whether the engine can change it: rotate, delete, annotate, save
}

/// An entry in a document's outline -- its table of contents -- and those under it.
struct PdfOutlineItem
{
    string title;
    int page = -1;          /// The page it goes to, from 0; -1 for none
    float y = float.nan;    /// Where on the page, in points from its top, if it says
    PdfOutlineItem[] children;
}

/// A link on a page: to another page of the document, or to a URI.
struct PdfLink
{
    PdfRect[] areas;        /// Where it can be clicked, in points from the page's top left
    int page = -1;          /// The page it goes to, from 0; -1 for a URI
    float y = float.nan;    /// Where on that page, if it says
    string uri;             /// What it opens, if it's not a page of the document
}

/// A page rendered, or part of one: 0xAARRGGBB pixels, premultiplied, `width` a row.
final class PdfBitmap
{
    uint[] pixels;
    uint width, height;
    /// What it shows: `region` of the page, in points, turned `quarterTurns`, at `scale` pixels a point.
    PdfRect region;
    float scale = 1; /// ditto
    int quarterTurns; /// ditto

    this(uint[] pixels, uint width, uint height, PdfRect region, float scale, int quarterTurns) pure nothrow @nogc
    {
        this.pixels = pixels;
        this.width = width;
        this.height = height;
        this.region = region;
        this.scale = scale;
        this.quarterTurns = quarterTurns;
    }
}

/*
    A page's text, as the engine read it: a character at a time, each with its box on the page, in
    reading order. Characters the engine put in -- a space between words with no space in the PDF,
    a line break -- have empty boxes. What selection, copying and searching all work from, on the
    UI thread, without asking the engine again.
*/
final class PdfPageText
{
    dchar[] chars;
    PdfRect[] boxes;

    this(dchar[] chars, PdfRect[] boxes) pure nothrow @nogc
    {
        assert(chars.length == boxes.length);
        this.chars = chars;
        this.boxes = boxes;
    }

    size_t length() const pure nothrow @nogc { return chars.length; }

    /// The text from `from` up to `to`, as UTF-8, with line breaks as "\n".
    string between(size_t from, size_t to) const pure
    {
        import std.utf : encode;
        if (to > chars.length)
            to = chars.length;
        string s;
        char[4] buffer;
        for (size_t i = from; i < to; i++)
        {
            const c = chars[i];
            if (c == '\r')
            {
                if (i + 1 < to && chars[i + 1] == '\n')
                    i++;
                s ~= '\n';
                continue;
            }
            if (c == 0xFFFE || c == 0)
                continue;
            s ~= buffer[0 .. encode(buffer, c)];
        }
        return s;
    }

    /*
        The character nearest `x`, `y` on the page, for where a selection starts or ends: one whose
        box it's in, or else the nearest on the nearest line, and the side of it it's on -- `after`
        is true when it's past the character's middle, so the selection takes it. -1 if the page
        has no text.
    */
    ptrdiff_t charAt(float x, float y, out bool after) const pure nothrow @nogc
    {
        ptrdiff_t best = -1;
        float bestScore = float.infinity;
        foreach (i, b; boxes)
        {
            if (b.empty)
                continue;
            if (b.contains(x, y))
            {
                after = x > b.x + b.width / 2;
                return i;
            }
            // Lines first: a character on the line the point's level with beats any above or below
            const dy = y < b.y ? b.y - y : y > b.bottom ? y - b.bottom : 0;
            const dx = x < b.x ? b.x - x : x > b.right ? x - b.right : 0;
            const score = dy * 1000 + dx;
            if (score < bestScore)
            {
                bestScore = score;
                best = i;
                after = x > b.x + b.width / 2;
            }
        }
        return best;
    }

    /// The character whose box `x`, `y` is in, or -1: for what's under the pointer.
    ptrdiff_t charUnder(float x, float y) const pure nothrow @nogc
    {
        foreach (i, b; boxes)
            if (b.contains(x, y))
                return i;
        return -1;
    }

    /*
        The rectangles that cover the characters from `from` up to `to`, a line at a time: each
        character's box joined to the one before while they're on the same line, as a selection's
        highlight is drawn.
    */
    PdfRect[] rects(size_t from, size_t to) const pure
    {
        PdfRect[] lines;
        PdfRect line;
        if (to > boxes.length)
            to = boxes.length;
        foreach (i; from .. to)
        {
            const b = boxes[i];
            // A space's box is often a sliver at the baseline: the words either side cover it
            import std.uni : isWhite;
            if (b.empty || (i < chars.length && isWhite(chars[i])))
                continue;
            if (!line.empty && sameLine(line, b))
                line = line.union_(b);
            else
            {
                if (!line.empty)
                    lines ~= line;
                line = b;
            }
        }
        if (!line.empty)
            lines ~= line;
        return lines;
    }

    /// The word around character `i`: from its first character, up to the one after its last.
    void wordAround(size_t i, out size_t from, out size_t to) const pure nothrow @nogc
    {
        import std.uni : isAlphaNum;
        from = to = i;
        if (i >= chars.length)
            return;
        if (!isAlphaNum(chars[i]))
        {
            to = i + 1;
            return;
        }
        while (from > 0 && isAlphaNum(chars[from - 1]))
            from--;
        while (to < chars.length && isAlphaNum(chars[to]))
            to++;
    }

    /// Where `query` is on the page, as [from, to) ranges of characters: ignoring case unless `matchCase`.
    size_t[2][] find(const(dchar)[] query, bool matchCase) const pure
    {
        import std.uni : toLower;
        size_t[2][] found;
        if (!query.length || query.length > chars.length)
            return found;
        dchar fold(dchar c) pure { return matchCase ? c : toLower(c); }
        // What the engine put between lines reads as a space, so a phrase matches across a line break
        dchar normal(dchar c) pure { return c == '\r' || c == '\n' ? ' ' : fold(c); }
        auto q = new dchar[query.length];
        foreach (k, c; query)
            q[k] = normal(c);
        outer: for (size_t i = 0; i + q.length <= chars.length; i++)
        {
            size_t j = i;
            foreach (k, c; q)
            {
                // "\r\n" from the engine counts as the one space
                if (k > 0 && chars[j - 1] == '\r' && j < chars.length && chars[j] == '\n')
                    j++;
                if (j >= chars.length || normal(chars[j]) != c)
                    continue outer;
                j++;
            }
            found ~= [i, j];
            i = j - 1;
        }
        return found;
    }

private:
    static bool sameLine(PdfRect a, PdfRect b) pure nothrow @nogc
    {
        // Overlapping by half the shorter one's height, and not too far apart across
        const top = a.y > b.y ? a.y : b.y, bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
        const shorter = a.height < b.height ? a.height : b.height;
        if (bottom - top < shorter / 2)
            return false;
        const gap = b.x > a.right ? b.x - a.right : a.x > b.right ? a.x - b.right : 0;
        return gap < shorter * 3;
    }
}

/// How a rectangle in a page's points is placed when the page is turned `quarterTurns` clockwise:
/// `width` by `height` is the page's size, unturned.
PdfRect turn(PdfRect r, int quarterTurns, float width, float height) pure nothrow @nogc
{
    final switch (quarterTurns & 3)
    {
        case 0: return r;
        case 1: return PdfRect(height - r.bottom, r.x, r.height, r.width);
        case 2: return PdfRect(width - r.right, height - r.bottom, r.width, r.height);
        case 3: return PdfRect(r.y, width - r.right, r.height, r.width);
    }
}

/// The point on the unturned page that's at `x`, `y` on it turned `quarterTurns`: turn's inverse, for a point.
void unturn(float x, float y, int quarterTurns, float width, float height, out float px, out float py) pure nothrow @nogc
{
    final switch (quarterTurns & 3)
    {
        case 0: px = x; py = y; break;
        case 1: px = y; py = height - x; break;
        case 2: px = width - x; py = height - y; break;
        case 3: px = width - y; py = x; break;
    }
}

unittest
{
    // Selection by lines, hit-testing, words and searching
    dchar[] chars = "Hello world\r\nNext line"d.dup;
    PdfRect[] boxes;
    foreach (i, c; chars)
    {
        const line = i < 13 ? 0 : 1;
        const col = line == 0 ? i : i - 13;
        boxes ~= c == '\r' || c == '\n' ? PdfRect.init : PdfRect(10 + col * 6, 10 + line * 14, 6, 12);
    }
    auto t = new PdfPageText(chars, boxes);
    assert(t.between(0, chars.length) == "Hello world\nNext line");
    assert(t.rects(0, chars.length).length == 2, "two lines");
    assert(t.rects(0, 5) == [PdfRect(10, 10, 30, 12)]);
    bool after;
    assert(t.charAt(13, 15, after) == 0 && !after);
    assert(t.charAt(17, 15, after) == 1 && !after, "in the second character's box, its left half");
    assert(t.charAt(500, 16, after) == 10 && after, "past the end of the line: its last character");
    assert(t.charUnder(500, 16) == -1);
    size_t from, to;
    t.wordAround(7, from, to);
    assert(from == 6 && to == 11, "world");
    assert(t.find("WORLD"d, false) == [[6, 11]]);
    assert(t.find("WORLD"d, true).length == 0);
    assert(t.find("world next"d, false) == [[6, 17]], "across the line break, as a space");
    assert(t.find("l"d, false).length == 4);

    // Turning a page: a corner goes round
    const r = PdfRect(0, 0, 10, 20); // top left of a 100 by 200 page
    assert(turn(r, 1, 100, 200) == PdfRect(180, 0, 20, 10), "a quarter: to the top right");
    assert(turn(r, 2, 100, 200) == PdfRect(90, 180, 10, 20), "a half: to the bottom right");
    assert(turn(r, 3, 100, 200) == PdfRect(0, 90, 20, 10), "three quarters: to the bottom left");
    float px, py;
    foreach (q; 0 .. 4)
    {
        const tr = turn(PdfRect(30, 40, 0.001f, 0.001f), q, 100, 200);
        unturn(tr.x, tr.y, q, 100, 200, px, py);
        import std.math : abs;
        assert(abs(px - 30) < 0.01 && abs(py - 40) < 0.01, "unturn undoes turn");
    }
}
