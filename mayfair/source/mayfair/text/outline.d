module mayfair.text.outline;

import core.stdc.math : roundf;

import mayfair.renderers.thorvg;
import mayfair.text.font;
import mayfair.text.freetype;
import mayfair.text.shaping;

/*
    The vector route: a glyph's outline goes into a ThorVG shape as path segments, so text is
    geometry like every other widget's. It scales with the one transform on the Scene, which means
    no glyph atlas, no rasterising per device scale, and nothing here that knows what the scale is.

    The cost is the other side of that coin: these segments are rebuilt whenever the shape is reset,
    which is why Widget.paintTree only repaints what actually moved.
*/

// From freetype.h. These are function-like macro constants there, which ImportC doesn't surface.
private enum FT_LOAD_NO_BITMAP_ = 1 << 3;
// FT_LOAD_TARGET_( FT_RENDER_MODE_LIGHT ), i.e. "slight" hinting: it grid-fits horizontal edges
// and leaves horizontal metrics alone. Full hinting distorts glyph widths, which would fight the
// advances above, since those come from the unhinted face that HarfBuzz shaped with.
private enum FT_LOAD_TARGET_LIGHT_ = 1 << 16;

/*
    Emits every glyph in `run` into `shape`, with the run's origin -- the start of its baseline --
    at (originX, baselineY) in points.

    `scale` is device pixels per point, and every glyph's origin is rounded to a whole device pixel
    before its outline is emitted. Without that, shaping puts each glyph at whatever fractional
    position its advances add up to, and the same letter rasterises differently every time it
    appears -- a stem landing on a pixel edge is crisp, the same stem half a pixel over becomes two
    grey columns. Repeated letters then look like they're stepping up and down the line.

    This is the same trick an atlas has to play, for a different reason: it can't cache infinitely
    many subpixel phases, so it quantises glyph origins and gets consistency as a side effect. Here
    the quantising is the whole point, and costs one rounding per glyph.

    Outlines are loaded hinted, from a face Font keeps sized in device pixels for exactly this. A
    stem is some fraction of a pixel wide, and unhinted it renders as one dark column and one pale
    one wherever it falls; hinting pulls its edges onto the grid so it comes out a whole pixel.
    That's what the remaining softness was after the snapping above fixed the positions.
*/
void emitRun(Tvg_Paint shape, ref GlyphRun run, float originX, float baselineY,
             float scale = 1.0f) nothrow @nogc
{
    foreach (ref g; run.glyphs)
        emitGlyph(shape, g, originX + g.x, baselineY + g.y, scale);
}

/// One glyph, its origin at `x`, `y` in points. For drawing a run's glyphs somewhere other than
/// where the run put them: a line of a wrapped paragraph (see mayfair.text.paragraph).
void emitGlyph(Tvg_Paint shape, ref const PositionedGlyph g, float x, float y, float scale = 1.0f) nothrow @nogc
{
    FT_Outline_Funcs funcs;
    funcs.move_to = &emitMoveTo;
    funcs.line_to = &emitLineTo;
    funcs.conic_to = &emitConicTo;
    funcs.cubic_to = &emitCubicTo;
    funcs.shift = 0;
    funcs.delta = 0;

    const snap = scale > 0 ? scale : 1.0f;

    // Each glyph's own font, since a run can mix in fallbacks for characters the first lacked
    auto face = (cast() g.font).outlineFace(snap);
    if (FT_Load_Glyph(face, g.glyph, FT_LOAD_TARGET_LIGHT_ | FT_LOAD_NO_BITMAP_) != 0)
        return;
    auto slot = face.glyph;
    if (slot.format != FT_Glyph_Format.FT_GLYPH_FORMAT_OUTLINE)
        return; // a colour or bitmap glyph, which the vector route has nothing to say about

    // Round in device space, then back to points: the Scene's transform will scale these
    // coordinates by `snap`, so landing on whole pixels there is what matters, not here.
    auto emitter = Emitter(shape, roundf(x * snap) / snap, roundf(y * snap) / snap, snap);
    FT_Outline_Decompose(&slot.outline, &funcs, &emitter);
    if (emitter.open)
        tvg_shape_close(shape); // FreeType closes each contour implicitly; ThorVG wants it said
}

private:

/*
    Carried through FT_Outline_Decompose as its user pointer. FreeType's coordinates are 26.6 fixed
    point with y pointing up; ours are points with y pointing down, so every point is divided by 64
    and its y negated against the glyph's origin.
*/
struct Emitter
{
    Tvg_Paint shape;
    float originX, originY;
    float scale = 1.0f;       // coordinates arrive in device pixels; points are what we emit
    float curX = 0, curY = 0; // the current point, which a conic segment needs to convert itself
    bool open;                // whether a contour has been started and not yet closed

    float x(FT_Pos v) const nothrow @nogc { return originX + v / (64.0f * scale); }
    float y(FT_Pos v) const nothrow @nogc { return originY - v / (64.0f * scale); }
}

extern(C) int emitMoveTo(const(FT_Vector)* to, void* user) nothrow @nogc
{
    auto e = cast(Emitter*) user;
    if (e.open)
        tvg_shape_close(e.shape); // a new contour starts, so the previous one is finished
    e.curX = e.x(to.x);
    e.curY = e.y(to.y);
    tvg_shape_move_to(e.shape, e.curX, e.curY);
    e.open = true;
    return 0;
}

extern(C) int emitLineTo(const(FT_Vector)* to, void* user) nothrow @nogc
{
    auto e = cast(Emitter*) user;
    e.curX = e.x(to.x);
    e.curY = e.y(to.y);
    tvg_shape_line_to(e.shape, e.curX, e.curY);
    return 0;
}

/*
    TrueType outlines are quadratic, and ThorVG's path has no quadratic segment, so each one is
    raised to the cubic that draws the identical curve: both controls sit two thirds of the way from
    an endpoint towards the quadratic's single control point.
*/
extern(C) int emitConicTo(const(FT_Vector)* control, const(FT_Vector)* to, void* user) nothrow @nogc
{
    auto e = cast(Emitter*) user;
    const qx = e.x(control.x), qy = e.y(control.y);
    const ex = e.x(to.x), ey = e.y(to.y);

    const c1x = e.curX + 2.0f / 3.0f * (qx - e.curX);
    const c1y = e.curY + 2.0f / 3.0f * (qy - e.curY);
    const c2x = ex + 2.0f / 3.0f * (qx - ex);
    const c2y = ey + 2.0f / 3.0f * (qy - ey);

    tvg_shape_cubic_to(e.shape, c1x, c1y, c2x, c2y, ex, ey);
    e.curX = ex;
    e.curY = ey;
    return 0;
}

extern(C) int emitCubicTo(const(FT_Vector)* c1, const(FT_Vector)* c2, const(FT_Vector)* to, void* user) nothrow @nogc
{
    auto e = cast(Emitter*) user;
    e.curX = e.x(to.x);
    e.curY = e.y(to.y);
    tvg_shape_cubic_to(e.shape, e.x(c1.x), e.y(c1.y), e.x(c2.x), e.y(c2.y), e.curX, e.curY);
    return 0;
}
