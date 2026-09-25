module mayfair.text.caret;

import std.uni : isAlphaNum;
import std.utf : decode, strideBack, UseReplacementDchar;

import mayfair.text.font;
import mayfair.text.linebreak;
import mayfair.text.shaping;

/*
    A line of text as something to edit: where a caret may stand in it, how far along each of those
    places is, and where its words start and end.

    A caret stands between grapheme clusters -- what a reader counts as one character -- which is
    not the same as between code points. "é" can be an e followed by a combining accent, and a flag
    is two regional indicators; a caret between the halves of either would be somewhere a reader
    can't see, and Backspace there would leave half a character. libunibreak says where the
    clusters are (UAX #29), as it already says where lines break.

    Where each character is comes from the shaped glyphs: HarfBuzz tags each glyph with the byte
    its cluster started at, so a cluster's box is its glyphs' extent. A ligature is one glyph for
    several characters -- "fi" in most text fonts -- so a character inside one has no glyph edge to
    go by, and gets an even share of the ligature's width, which is what browsers do too.

    Text can mix directions (see shapeText), and then the order of the text and the order on screen
    part ways: offsets still run through the text, but a stop's x doesn't grow with its offset. So
    each character has a box, and a direction, and a caret before a character stands at its
    leading edge -- its left side in English, its right side in Hebrew. A selection is the boxes of
    the characters in it, which in mixed text can be two stretches of the line rather than one.
    Where a run of one direction meets the other, the same offset could stand at either run's
    edge. It stands against whichever character reads the way the line as a whole does -- after
    "ab " and before a Hebrew word in an English line, that's straight after the space, not away
    at the far end of the Hebrew -- unless another offset already stands there, in which case it
    takes the other edge. At the end of "ab שלום" the end of the text is straight after the space
    too (it's where the next Hebrew letter will appear), so the start of the Hebrew goes to the
    Hebrew's far edge. Either way every edge on screen gets exactly one offset, so the caret can
    reach all of them and a click always has one to land on.
*/
struct EditableLine
{
    string text;
    GlyphRun run;
    size_t[] stops;   /// Byte offsets a caret can stand at, ascending, from 0 to text.length
    float[] x;        /// For each stop, its distance from the start of the line, in points
    bool[] wordStart; /// For each stop, whether a word starts there
    bool[] wordEnd;   /// For each stop, whether a word ends there
    bool[] boundary;  /// For each stop, whether it's between words, or a word and what's around it
    float[] left, right;  /// For each character, where its box starts and ends along the line
    bool[] rightToLeft;   /// For each character, whether it reads right to left

    /// How many characters, in the sense a reader means.
    size_t length() const nothrow @nogc { return stops.length - 1; }

    /// The index of the stop at `offset`, or of the last one before it.
    size_t indexOf(size_t offset) const nothrow @nogc
    {
        size_t lo = 0, hi = stops.length;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (stops[mid] <= offset)
                lo = mid;
            else
                hi = mid;
        }
        return lo;
    }

    /// How far along the line the caret is at `offset`, in points.
    float xAt(size_t offset) const nothrow @nogc { return x[indexOf(offset)]; }

    /// Where a click `px` points along the line puts the caret: the stop drawn nearest to it,
    /// which in mixed text needn't be the nearest in the text.
    size_t nearest(float px) const nothrow @nogc
    {
        size_t best = 0;
        foreach (i; 1 .. stops.length)
            if ((x[i] - px) * (x[i] - px) < (x[best] - px) * (x[best] - px))
                best = i;
        return stops[best];
    }

    /*
        The stop next to `offset` on screen, to its right or its left: what the arrow keys move to.
        In text of one direction that's simply the next or previous character; in mixed text it
        follows the line as it's shown, jumping about in the text as the runs change direction,
        which is what GTK and browsers do. Returns `offset` if there's nothing further that way.
    */
    size_t visualNeighbour(size_t offset, bool rightwards) const nothrow @nogc
    {
        const from = xAt(offset);
        size_t best = offset;
        float bestX = rightwards ? float.infinity : -float.infinity;
        foreach (i, sx; x)
        {
            if (rightwards ? (sx > from + 0.01f && sx < bestX) : (sx < from - 0.01f && sx > bestX))
            {
                bestX = sx;
                best = stops[i];
            }
        }
        return best;
    }

    /// The stop one character before `offset`, or 0.
    size_t previous(size_t offset) const nothrow @nogc
    {
        const i = indexOf(offset);
        return stops[i < stops.length && stops[i] == offset && i > 0 ? i - 1 : i];
    }

    /// The stop one character after `offset`, or the end.
    size_t next(size_t offset) const nothrow @nogc
    {
        const i = indexOf(offset);
        return i + 1 < stops.length ? stops[i + 1] : text.length;
    }

    /// Where the word before `offset` starts: what Ctrl+Left moves to.
    size_t previousWordStart(size_t offset) const nothrow @nogc
    {
        for (auto i = indexOf(offset); i > 0; i--)
            if (wordStart[i - 1] && stops[i - 1] < offset)
                return stops[i - 1];
        return 0;
    }

    /// Where the word after `offset` ends: what Ctrl+Right moves to, as it does on Linux and macOS.
    size_t nextWordEnd(size_t offset) const nothrow @nogc
    {
        foreach (i; indexOf(offset) + 1 .. stops.length)
            if (wordEnd[i])
                return stops[i];
        return text.length;
    }

    /// The word, or run of spaces or punctuation, that `offset` is in: what a double click selects.
    void wordAround(size_t offset, out size_t start, out size_t end) const nothrow @nogc
    {
        auto i = indexOf(offset);
        if (i == length && i > 0)
            i--; // past the end: the last word, not nothing
        while (i > 0 && !boundary[i])
            i--;
        auto j = i + 1;
        while (j < length && !boundary[j])
            j++;
        start = stops[i];
        end = stops[j < stops.length ? j : $ - 1];
    }
}

/// Shapes `text` with `font` and works out its caret stops and words.
EditableLine editableLine(Font font, string text)
{
    EditableLine line;
    line.text = text;
    line.run = shapeText(font, text);

    // brks[i] says whether there's a break after byte i: a character boundary for one, a word
    // boundary for the other. Both init functions build shared tables and are safe to call again.
    auto graphemes = new char[text.length];
    auto words = new char[text.length];
    if (text.length)
    {
        init_graphemebreak();
        init_wordbreak();
        set_graphemebreaks_utf8(cast(const(ubyte)*) text.ptr, text.length, "en", graphemes.ptr);
        set_wordbreaks_utf8(cast(const(ubyte)*) text.ptr, text.length, "en", words.ptr);
    }

    line.stops ~= 0;
    foreach (i; 0 .. text.length)
        if (graphemes[i] == GRAPHEMEBREAK_BREAK)
            line.stops ~= i + 1;
    if (line.stops[$ - 1] != text.length)
        line.stops ~= text.length;

    boxes(line.run, text, line.stops, line.left, line.right, line.rightToLeft);
    line.x = caretPositions(line);

    line.wordStart.length = line.wordEnd.length = line.boundary.length = line.stops.length;
    foreach (i, s; line.stops)
    {
        const isBoundary = s == 0 || s == text.length || words[s - 1] == WORDBREAK_BREAK;
        line.boundary[i] = isBoundary;
        line.wordStart[i] = isBoundary && s < text.length && isWordCharacter(characterAt(text, s));
        line.wordEnd[i] = isBoundary && s > 0 && isWordCharacter(characterBefore(text, s));
    }
    return line;
}

private:

/*
    Each character's box and direction. A cluster's box is its glyphs' extent; a character that's
    the whole of a cluster, or of several, gets theirs, and one of several sharing a cluster (a
    ligature) gets an even share of it, taken from the right in right-to-left text.
*/
void boxes(ref GlyphRun run, const(char)[] text, const(size_t)[] stops,
           out float[] left, out float[] right, out bool[] rightToLeft)
{
    import std.algorithm : sort;

    struct Cluster { size_t start; float x0 = float.infinity, x1 = -float.infinity; bool rtl; }
    Cluster[size_t] byStart;
    foreach (ref g; run.glyphs)
    {
        auto c = g.cluster in byStart;
        if (!c)
        {
            byStart[g.cluster] = Cluster(g.cluster);
            c = g.cluster in byStart;
        }
        if (g.x < c.x0) c.x0 = g.x;
        if (g.x + g.advance > c.x1) c.x1 = g.x + g.advance;
        c.rtl = g.rightToLeft;
    }
    auto clusters = byStart.values;
    clusters.sort!((a, b) => a.start < b.start); // back into the text's order

    const count = stops.length - 1;
    left = new float[count];
    right = new float[count];
    rightToLeft = new bool[count];
    size_t k = 0;
    foreach (i; 0 .. count)
    {
        const s0 = stops[i], s1 = stops[i + 1];
        if (!clusters.length)
        {
            left[i] = right[i] = 0;
            continue;
        }
        while (k + 1 < clusters.length && clusters[k + 1].start <= s0)
            k++;
        const c = clusters[k];
        const clusterEnd = k + 1 < clusters.length ? clusters[k + 1].start : text.length;
        rightToLeft[i] = c.rtl;
        if (s1 <= clusterEnd)
        {
            // All within one cluster, perhaps with others: this one's share of it
            size_t n, j;
            foreach (t; 0 .. count)
            {
                if (stops[t] >= c.start && stops[t + 1] <= clusterEnd)
                {
                    if (stops[t] < s0)
                        j++;
                    n++;
                }
            }
            const w = (c.x1 - c.x0) / (n ? n : 1);
            left[i] = c.rtl ? c.x1 - w * (j + 1) : c.x0 + w * j;
            right[i] = left[i] + w;
        }
        else
        {
            // Across several clusters: all of them
            float x0 = float.infinity, x1 = -float.infinity;
            foreach (ref other; clusters)
            {
                if (other.start >= s0 && other.start < s1)
                {
                    if (other.x0 < x0) x0 = other.x0;
                    if (other.x1 > x1) x1 = other.x1;
                }
            }
            left[i] = x0;
            right[i] = x1;
        }
    }
}

/*
    Where a caret at each stop stands. Between two characters reading the same way, their shared
    edge; at the ends, the outside edge; and where the direction changes, against the character
    that reads the line's way, or the other if that place is taken (see EditableLine). The
    unambiguous ones go first, so the boundaries know what's taken.
*/
float[] caretPositions(ref const EditableLine line)
{
    float leading(size_t i) { return line.rightToLeft[i] ? line.right[i] : line.left[i]; }
    float trailing(size_t i) { return line.rightToLeft[i] ? line.left[i] : line.right[i]; }
    bool boundary(size_t i) { return i > 0 && i < line.length && line.rightToLeft[i - 1] != line.rightToLeft[i]; }

    auto result = new float[line.stops.length];
    foreach (i; 0 .. line.stops.length)
    {
        if (!line.length)
            result[i] = 0;
        else if (i == 0)
            result[i] = leading(0);
        else if (i == line.length)
            result[i] = trailing(i - 1);
        else if (!boundary(i))
            result[i] = leading(i);
    }
    foreach (i; 0 .. line.stops.length)
    {
        if (!boundary(i))
            continue;
        const preferred = line.rightToLeft[i - 1] == line.run.rightToLeft ? trailing(i - 1) : leading(i);
        const other = line.rightToLeft[i - 1] == line.run.rightToLeft ? leading(i) : trailing(i - 1);
        bool taken;
        foreach (j, x; result)
            if (j != i && !boundary(j) && (x - preferred < 0.01f && x - preferred > -0.01f))
                taken = true;
        result[i] = taken ? other : preferred;
    }
    return result;
}

bool isWordCharacter(dchar c) pure nothrow @nogc @safe
{
    return isAlphaNum(c) || c == '_' || c == '\'';
}

dchar characterAt(const(char)[] text, size_t offset)
{
    return decode!(UseReplacementDchar.yes)(text, offset);
}

dchar characterBefore(const(char)[] text, size_t offset)
{
    size_t at = offset - strideBack(text, offset);
    return decode!(UseReplacementDchar.yes)(text, at);
}

unittest
{
    import mayfair.text.fonts : defaultFont;

    auto font = defaultFont(14);

    // One stop per character, and x never goes backwards
    auto plain = editableLine(font, "hello world");
    assert(plain.stops.length == 12 && plain.stops[0] == 0 && plain.stops[$ - 1] == 11);
    foreach (i; 1 .. plain.x.length)
        assert(plain.x[i] >= plain.x[i - 1]);
    assert(plain.x[$ - 1] == plain.run.width);

    // An e with a combining acute is one character, whose bytes the caret doesn't stop inside
    auto combining = editableLine(font, "éx");
    assert(combining.stops == [0, 3, 4]);

    // A ligature is one glyph, but still two stops, the second part way through it
    auto ligature = editableLine(font, "fi");
    assert(ligature.stops == [0, 1, 2]);
    assert(ligature.x[0] < ligature.x[1] && ligature.x[1] < ligature.x[2]);

    // Words, as Ctrl+arrows and a double click see them
    assert(plain.previousWordStart(8) == 6);
    assert(plain.previousWordStart(6) == 0);
    assert(plain.nextWordEnd(0) == 5);
    assert(plain.nextWordEnd(5) == 11);
    size_t start, end;
    plain.wordAround(2, start, end);
    assert(start == 0 && end == 5);
    plain.wordAround(11, start, end);
    assert(start == 6 && end == 11);

    // Moving by character
    assert(combining.next(0) == 3 && combining.previous(4) == 3 && combining.previous(3) == 0);
    assert(plain.nearest(plain.x[4] + 0.1f) == 4);

    // Hebrew reads right to left: its first character is at the right, so is the caret before it,
    // and the arrows still move the way they point
    auto hebrew = editableLine(font, "שלום");
    assert(hebrew.run.rightToLeft && hebrew.rightToLeft[0]);
    assert(hebrew.x[0] > hebrew.x[1] && hebrew.x[$ - 1] < hebrew.x[0]);
    assert(hebrew.visualNeighbour(0, false) == hebrew.next(0)); // left, which is onwards in Hebrew
    assert(hebrew.visualNeighbour(0, true) == 0);               // nothing to the right of the start
    assert(hebrew.nearest(hebrew.right[0] - 0.1f) == 0);        // the right of the first letter is before it

    // English with a Hebrew word in it: the Hebrew is reversed on screen, the English isn't, and
    // moving right goes through the Hebrew backwards through the text
    auto mixed = editableLine(font, "ab שלום cd");
    assert(!mixed.run.rightToLeft);
    const heStart = 3, heEnd = 3 + "שלום".length;
    // The first Hebrew letter is drawn rightmost of them
    assert(mixed.right[mixed.indexOf(heStart)] > mixed.right[mixed.indexOf(heEnd) - 1]);
    // Straight after the space, the caret is against it, not at the far end of the Hebrew
    assert(mixed.xAt(heStart) == mixed.right[mixed.indexOf(heStart) - 1]);
    size_t at = mixed.visualNeighbour(heStart - 1, true);
    assert(at == heStart);
    at = mixed.visualNeighbour(at, true);
    assert(at > heStart && at < heEnd);             // into the Hebrew, backwards through the text
    // Every stop is somewhere different on screen, so the caret can reach every edge
    foreach (i; 0 .. mixed.x.length)
        foreach (j; i + 1 .. mixed.x.length)
            assert(mixed.x[i] != mixed.x[j]);
    // and walking right from the start visits every stop once, ending at the end
    size_t visited = 1;
    for (size_t p = 0, q; (q = mixed.visualNeighbour(p, true)) != p; p = q)
        visited++;
    assert(visited == mixed.stops.length);

    // Ending in Hebrew: the end of the text is straight after the space, where the next Hebrew
    // letter will go, and every edge is still somewhere the caret can be
    auto ending = editableLine(font, "ab שלום");
    assert(ending.xAt(ending.text.length) == ending.right[ending.indexOf(2)]);
    foreach (i; 0 .. ending.x.length)
        foreach (j; i + 1 .. ending.x.length)
            assert(ending.x[i] != ending.x[j]);
    size_t seen = 1;
    size_t p = 0;
    for (size_t q; (q = ending.visualNeighbour(p, true)) != p; p = q)
        seen++;
    assert(seen == ending.stops.length);

    // Nothing at all still has somewhere for the caret
    auto empty = editableLine(font, "");
    assert(empty.stops == [0] && empty.x == [0] && empty.length == 0);
}
