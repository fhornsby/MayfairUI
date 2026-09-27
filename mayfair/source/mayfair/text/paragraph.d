module mayfair.text.paragraph;

import mayfair.renderers.thorvg : Tvg_Paint;
import mayfair.text.font;
import mayfair.text.linebreak;
import mayfair.text.outline;
import mayfair.text.shaping;

/*
    Text that wraps: laid out in lines at whatever width it's given. What a wrapping Label draws.

    A width comes from the layout, and the layout asks for a height at a width while it's working
    -- inside Yoga, where nothing may allocate or call into HarfBuzz. So the work that needs either
    is done once, when the text or the font changes, and what depends on the width is arithmetic:

    - Each hard line (the text between line breaks in it) is shaped once, as the single line it
      would be if nothing wrapped it.
    - Where a line may break is libunibreak's (UAX #14): after a space, around CJK, at a hyphen,
      and the rest of what guessing gets wrong. Found once.
    - How wide a stretch of the text is comes from a running total of each character's advance,
      so any line's width is a subtraction.

    Lines are chosen greedily, taking the last break that fits; a word too long for the width on
    its own breaks between characters, as JavaFX's does, rather than running off the end. Spaces at
    the end of a line don't count towards its width, and aren't drawn.

    A line is drawn from its hard line's glyphs, those that belong to it, in the order they're
    in. That's right for mixed-direction text too: the bidi algorithm orders a line by reversing
    runs of it, and a line is a stretch of its hard line, so the stretch's glyphs come out in the
    order shaping it alone would have put them. What isn't the same is kerning between the two
    characters either side of a break -- a fraction of a point, at the end of a line.
*/
struct Paragraph
{
public:
    /// Lays `text` out in `font`. The work that doesn't depend on the width, done now.
    this(Font font, string text)
    {
        this.font = font;
        this.text = text;

        // Where lines may and must break: brks[i] is about the break after byte i
        auto brks = new char[text.length];
        if (text.length)
        {
            init_linebreak();
            set_linebreaks_utf8(cast(const(ubyte)*) text.ptr, text.length, "en", brks.ptr);
        }

        advanceBefore = new float[text.length + 1];
        clusterStart = new bool[text.length + 1];
        // libunibreak says where a line must break, after a newline; and the text's end ends one
        size_t start;
        foreach (i; 0 .. text.length)
        {
            if (brks[i] != LINEBREAK_MUSTBREAK && i + 1 != text.length)
                continue;
            // The hard line runs up to its newline, which isn't drawn
            size_t visible = i + 1;
            while (visible > start && (text[visible - 1] == '\n' || text[visible - 1] == '\r'))
                visible--;
            addBlock(start, visible, brks);
            start = i + 1;
        }
        // Empty text is one empty line, as tall as any other; so is what follows a last newline
        if (!blocks.length || text[$ - 1] == '\n')
            addBlock(text.length, text.length, brks);

        lineBuffer = new Line[text.length + blocks.length + 1]; // no more lines than characters, and blocks
    }

    /// One line, as laid out: bytes `start` to `end` of the text, trailing spaces left out, and how wide it is.
    static struct Line
    {
        size_t start, end;
        float width = 0;
        size_t block;
    }

    Font font;
    string text;

    float lineHeight() const nothrow @nogc { return font ? (cast() font).lineHeight : 0; }
    float ascender() const nothrow @nogc { return font ? (cast() font).ascender : 0; }

    /*
        The lines at `maxWidth` points: as many as fit, broken where the text allows. Infinity
        for none but the text's own line breaks. The slice is the paragraph's own, and holds until
        the next call.
    */
    const(Line)[] lines(float maxWidth) nothrow @nogc
    {
        size_t n;
        foreach (b, ref block; blocks)
        {
            size_t at = block.start;
            do
            {
                const end = lineEnd(block, at, maxWidth);
                const shown = trimmed(at, end);
                lineBuffer[n++] = Line(at, shown, width(at, shown), b);
                at = end;
                // A wrapped line doesn't start with the spaces it wrapped at
                while (at < block.end && (text[at] == ' ' || text[at] == '\t'))
                    at++;
            }
            while (at < block.end);
        }
        return lineBuffer[0 .. n];
    }

    /// How big the lines at `maxWidth` are, `spacing` points apart: the widest's width, and
    /// all their heights.
    void measure(float maxWidth, float spacing, out float w, out float h) nothrow @nogc
    {
        const all = lines(maxWidth);
        w = 0;
        foreach (ref l; all)
            if (l.width > w)
                w = l.width;
        h = all.length * lineHeight + (all.length - 1) * spacing;
    }

    /// Draws `line` into `shape` with its left end at `x` and its baseline at `baseline`, in points.
    void emitLine(Tvg_Paint shape, ref const Line line, float x, float baseline, float scale) nothrow @nogc
    {
        const block = &blocks[line.block];
        float pen = 0, penAll = 0;
        foreach (ref g; block.run.glyphs)
        {
            // Where shaping put it, less where its pen was: its own offset, as a mark's is
            const offset = g.x - penAll;
            penAll += g.advance;
            const at = block.start + g.cluster;
            if (at < line.start || at >= line.end)
                continue;
            emitGlyph(shape, g, x + pen + offset, baseline + g.y, scale);
            pen += g.advance;
        }
    }

private:
    // A stretch of the text between hard line breaks, shaped as one line
    struct Block
    {
        size_t start, end;   // bytes, the line break at its end not included
        GlyphRun run;
        size_t[] breaks;     // where a line may start after a soft break, in order
    }

    Block[] blocks;
    float[] advanceBefore;   // how far the pen has gone before each byte, within its block
    bool[] clusterStart;     // whether a byte starts something drawn: where a word can break if it has to
    Line[] lineBuffer;

    void addBlock(size_t start, size_t visible, const(char)[] brks)
    {
        Block block;
        block.start = start;
        block.end = visible;
        block.run = shapeText(font, text[start .. visible]);

        // Each glyph's advance goes to the byte it came from; a ligature's all to its first
        auto advance = new float[visible - start + 1];
        advance[] = 0;
        foreach (ref g; block.run.glyphs)
        {
            advance[g.cluster] += g.advance;
            clusterStart[start + g.cluster] = true;
        }
        float total = 0;
        foreach (i; start .. visible + 1)
        {
            advanceBefore[i] = total;
            if (i < visible)
                total += advance[i - start];
        }
        foreach (i; start .. visible)
            if (i + 1 < visible && brks[i] == LINEBREAK_ALLOWBREAK)
                block.breaks ~= i + 1;
        blocks ~= block;
    }

    float width(size_t from, size_t to) const nothrow @nogc
    {
        return advanceBefore[to] - advanceBefore[from];
    }

    // `end` less the spaces before it
    size_t trimmed(size_t start, size_t end) const nothrow @nogc
    {
        while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t'))
            end--;
        return end;
    }

    // Where the line starting at `at` ends: the block's end if it all fits, else the last break
    // that does, else as many characters as fit, and at least one
    size_t lineEnd(ref const Block block, size_t at, float maxWidth) const nothrow @nogc
    {
        if (width(at, trimmed(at, block.end)) <= maxWidth)
            return block.end;
        size_t best;
        foreach (b; block.breaks)
        {
            if (b <= at)
                continue;
            if (width(at, trimmed(at, b)) > maxWidth)
                break;
            best = b;
        }
        if (best)
            return best;
        // Not even the first word fits: break it between characters
        size_t fits = at;
        foreach (i; at + 1 .. block.end + 1)
        {
            if (i < block.end && !clusterStart[i])
                continue;
            if (width(at, i) > maxWidth)
                break;
            fits = i;
        }
        if (fits > at)
            return fits;
        foreach (i; at + 1 .. block.end + 1) // one character, too wide as it is
            if (i == block.end || clusterStart[i])
                return i;
        return block.end;
    }
}

unittest
{
    import mayfair.text.fonts : defaultFont;
    auto font = defaultFont(14);
    auto p = Paragraph(font, "one two three");
    const whole = p.lines(float.infinity);
    assert(whole.length == 1 && whole[0].start == 0 && whole[0].end == 13);

    // Narrower than the whole: broken after spaces, which don't count towards a line's width
    const oneTwo = p.width(0, 7);
    const narrow = p.lines(oneTwo + 1);
    assert(narrow.length == 2, "two lines");
    assert(narrow[0].end == 7 && narrow[1].start == 8 && narrow[1].end == 13);
    assert(narrow[0].width == oneTwo);

    // Too narrow for a word: broken inside it, never an empty line
    const tiny = p.lines(1);
    assert(tiny.length == 13 - 2);
    foreach (ref l; tiny)
        assert(l.end > l.start);

    // Its own line breaks, whatever the width; an empty line between two is still a line
    auto q = Paragraph(font, "a\n\nb");
    assert(q.lines(float.infinity).length == 3);
    float w, h;
    q.measure(float.infinity, 2, w, h);
    assert(h == 3 * font.lineHeight + 2 * 2);

    assert(Paragraph(font, "").lines(10).length == 1);
}
