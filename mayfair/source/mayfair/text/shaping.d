module mayfair.text.shaping;

import mayfair.text.bidi;
import mayfair.text.font;
import mayfair.text.harfbuzz;
import mayfair.text.linebreak;

/*
    The seam. Everything above here -- fonts, shaping, where lines break -- is what text means; every
    route for getting it on screen is below. A GlyphRun says which glyphs, and where, and nothing
    about how they are drawn, so the outline emitter in mayfair.text.outline can be swapped for an
    atlas that rasterises the same run into a texture without any of this changing.
*/

/// One glyph, placed. `x` and `y` are offsets in points from the run's origin, which is the start
/// of its baseline. `cluster` is the byte offset in the source text this glyph came from -- several
/// glyphs can share one (a ligature), and one glyph can span several (a combining sequence).
/// `font` is the one it was shaped with, which is the fallback for a character the requested font
/// has no glyph for; a glyph id means nothing without it. `advance` is how far it moves the pen,
/// and `rightToLeft` whether it's from text that reads that way.
struct PositionedGlyph
{
    uint glyph;
    float x, y;
    uint cluster;
    Font font;
    float advance = 0;
    bool rightToLeft;
}

/// A single line's worth of shaped text. The glyphs are in the order they're drawn, left to right,
/// which for right-to-left text is not the order of the text: see shapeText.
struct GlyphRun
{
    PositionedGlyph[] glyphs;
    float width;       /// total advance, in points
    bool rightToLeft;  /// whether the line as a whole reads right to left: its first strong character does
}

/// A whole wrapped paragraph, one GlyphRun per line.
struct TextLayout
{
    GlyphRun[] lines;
    float width, height;  /// in points
}

/*
    Shapes one line. Named shapeText rather than shape because every Widget has a `shape` field --
    its ThorVG paint -- which would shadow a free function called that inside any text widget.

    HarfBuzz reads the font's GSUB and GPOS tables, so this is where ligatures,
    contextual forms, mark positioning and real (GPOS) kerning happen -- the things a loop that only
    accumulates advances can't do, whatever font it is given.

    First, though, the line is put in the order it's shown. Text can mix left-to-right and
    right-to-left scripts -- an English word in Arabic, a number in Hebrew -- and the Unicode
    Bidirectional Algorithm (SheenBidi, here) splits it into runs that each read one way, and says
    which order the runs go in on screen. HarfBuzz is given one run at a time with its direction,
    and lays a right-to-left run's glyphs out right to left, mirroring brackets as it goes. So the
    glyphs come out in the order they're drawn, and a glyph's cluster is how to get back from one
    to the text. Which way the line as a whole reads is decided by its first strong character, as
    UAX #9 says, and left to right if it has none.

    Then each run is split into spans by which font can draw them. Each character
    goes to `font` if it has a glyph for it and to a fallback from mayfair.text.fonts if not; marks,
    joiners and variation selectors stay with the character they modify, so a combining accent or
    an emoji sequence is never split across two fonts. Each span is shaped on its own, with the
    rest of the line as context, and the spans' glyphs are laid end to end.
*/
GlyphRun shapeText(Font font, const(char)[] text)
{
    GlyphRun run;
    float penX = 0, penY = 0;

    foreach (ref r; visualRuns(text, run.rightToLeft))
    {
        auto spans = fontSpans(font, text, r.start, r.end);
        // A right-to-left run's spans are shown in the opposite order to the text's
        if (r.rightToLeft)
            foreach_reverse (ref span; spans)
                shapeSpan(run, span.font, text, span.start, span.end, true, penX, penY);
        else
            foreach (ref span; spans)
                shapeSpan(run, span.font, text, span.start, span.end, false, penX, penY);
    }

    run.width = penX;
    return run;
}

/*
    Shapes `text` wrapped to `maxWidth` points. Pass maxWidth <= 0 for a single line.

    Where a line may break is libunibreak's job (UAX #14), not HarfBuzz's and not a search for
    spaces: the rules cover hyphens, CJK, which punctuation may start or end a line, and a good deal
    more that guessing gets wrong. Given the opportunities, the choice of which to take here is
    plain greedy -- take the last one that fits.
*/
TextLayout layoutText(Font font, string text, float maxWidth)
{
    TextLayout result;
    if (text.length == 0)
        return result;

    // brks[i] describes the break after byte i. init_linebreak() builds shared tables and is safe
    // to call more than once.
    init_linebreak();
    auto brks = new char[text.length];
    set_linebreaks_utf8(cast(const(ubyte)*) text.ptr, text.length, "en", brks.ptr);

    size_t start = 0;
    while (start < text.length)
    {
        size_t cut = text.length; // byte offset where the next line starts

        // A mandatory break (a newline in the text) wins over any fitting decision
        foreach (i; start .. text.length)
            if (brks[i] == LINEBREAK_MUSTBREAK)
            {
                cut = i + 1;
                break;
            }

        auto run = shapeText(font, text[start .. cut]);

        if (maxWidth > 0 && run.width > maxWidth)
        {
            // The last opportunity whose line still fits. How wide the line up to a break would be
            // is the advance of every glyph from text before it -- summed rather than read off
            // positions, since in mixed-direction text the glyphs aren't in the text's order. The
            // line is then shaped again on its own, which reorders it for what it now holds.
            size_t fitting = 0;
            foreach (b; 1 .. cut - start)
            {
                if (brks[start + b - 1] != LINEBREAK_ALLOWBREAK)
                    continue;
                float width = 0;
                foreach (ref g; run.glyphs)
                    if (g.cluster < b)
                        width += g.advance;
                if (width > maxWidth)
                    break;
                fitting = b;
            }
            // fitting == 0 means not even the first word fits, so let this line overflow rather
            // than emit an empty one and loop forever
            if (fitting > 0)
            {
                cut = start + fitting;
                run = shapeText(font, text[start .. cut]);
            }
        }

        result.lines ~= run;
        if (run.width > result.width)
            result.width = run.width;
        start = cut;
    }

    result.height = font.lineHeight * result.lines.length;
    return result;
}

private:

/// A stretch of text that reads one way, as a byte range.
struct VisualRun
{
    size_t start, end;
    bool rightToLeft;
}

/*
    The line's runs, in the order they're shown, and whether the line reads right to left. Text
    with nothing outside ASCII can't have anything right to left in it, and that's most text, so
    it skips the algorithm altogether.
*/
VisualRun[] visualRuns(const(char)[] text, out bool rightToLeft)
{
    bool ascii = true;
    foreach (char c; text)
        if (c >= 0x80)
        {
            ascii = false;
            break;
        }
    if (ascii || !text.length)
        return [VisualRun(0, text.length, false)];

    auto sequence = SBCodepointSequence(SBStringEncodingUTF8, cast(void*) text.ptr, text.length);
    auto algorithm = SBAlgorithmCreate(&sequence);
    scope(exit) SBAlgorithmRelease(algorithm);
    // One paragraph: a line has no paragraph breaks in it to find
    auto paragraph = SBAlgorithmCreateParagraph(algorithm, 0, text.length, SBLevelDefaultLTR);
    scope(exit) SBParagraphRelease(paragraph);
    rightToLeft = (SBParagraphGetBaseLevel(paragraph) & 1) != 0;
    auto line = SBParagraphCreateLine(paragraph, 0, text.length);
    scope(exit) SBLineRelease(line);

    auto runs = SBLineGetRunsPtr(line)[0 .. SBLineGetRunCount(line)];
    auto result = new VisualRun[runs.length];
    foreach (i, ref r; runs)
        result[i] = VisualRun(r.offset, r.offset + r.length, (r.level & 1) != 0);
    return result;
}

/// Part of a run that one font draws.
struct FontSpan
{
    Font font;
    size_t start, end;
}

/// text[start .. end] split by which font can draw each character, in the text's order.
FontSpan[] fontSpans(Font font, const(char)[] text, size_t start, size_t end)
{
    import std.utf : decode, UseReplacementDchar;

    FontSpan[] spans;
    for (size_t i = start; i < end;)
    {
        const at = i;
        const c = decode!(UseReplacementDchar.yes)(text, i);
        auto f = spans.length && staysWithPrevious(c) ? spans[$ - 1].font : fontFor(font, c);
        if (spans.length && f is spans[$ - 1].font)
            spans[$ - 1].end = i;
        else
            spans ~= FontSpan(f, at, i);
    }
    return spans;
}

/// `primary` if it can draw `c`, otherwise a fallback that can. Characters nothing can draw stay
/// with `primary`, whose missing-glyph box at least shows something was there.
Font fontFor(Font primary, dchar c)
{
    import mayfair.text.fonts : fallbackFont;

    if (c < 0x20 || primary.hasGlyph(c))
        return primary; // a control character is never drawn, so it's no reason to switch fonts
    auto f = fallbackFont(primary, c);
    return f ? f : primary;
}

/// Whether `c` modifies the character before it, and so has to be shaped in the same font.
bool staysWithPrevious(dchar c)
{
    import std.uni : isMark;

    return isMark(c)
        || c == 0x200C || c == 0x200D             // zero-width non-joiner and joiner
        || (c >= 0xFE00 && c <= 0xFE0F)           // variation selectors
        || (c >= 0xE0100 && c <= 0xE01EF)         // variation selectors supplement
        || (c >= 0x1F3FB && c <= 0x1F3FF)         // emoji skin-tone modifiers
        || (c >= 0xE0020 && c <= 0xE007F);        // tag characters, as in flag sequences
}

/*
    Shapes text[start .. end] with `font` and appends its glyphs to `run`, advancing the pen.

    The whole line goes into the buffer, with only the span marked as the item to shape: HarfBuzz
    then sees the characters either side, which contextual shaping (Arabic joining, for one) needs
    across a font change, and every cluster comes back as a byte offset into the whole line rather
    than into the span.
*/
void shapeSpan(ref GlyphRun run, Font font, const(char)[] text, size_t start, size_t end,
               bool rightToLeft, ref float penX, ref float penY)
{
    auto buffer = hb_buffer_create();
    scope(exit) hb_buffer_destroy(buffer);

    hb_buffer_add_utf8(buffer, text.ptr, cast(int) text.length, cast(uint) start, cast(int)(end - start));
    // The direction is the bidi algorithm's to say, not a guess from the script: a run of digits
    // inside Arabic is left to right, though nothing about digits says so. Script and language
    // are still guessed from the text, and only fill in what's unset.
    hb_buffer_set_direction(buffer, rightToLeft ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font.hb, buffer, null, 0);

    uint count;
    const infos = hb_buffer_get_glyph_infos(buffer, &count);
    const positions = hb_buffer_get_glyph_positions(buffer, &count);

    run.glyphs.reserve(run.glyphs.length + count);
    foreach (i; 0 .. count)
    {
        // 26.6 fixed point at 72 dpi, so dividing by 64 gives points (see Font's comment)
        run.glyphs ~= PositionedGlyph(
            infos[i].codepoint, // after shaping this is a glyph id, not a character
            penX + positions[i].x_offset / 64.0f,
            penY - positions[i].y_offset / 64.0f, // FreeType's y goes up, ours goes down
            infos[i].cluster,
            font,
            positions[i].x_advance / 64.0f,
            rightToLeft);
        penX += positions[i].x_advance / 64.0f;
        penY -= positions[i].y_advance / 64.0f;
    }
}
