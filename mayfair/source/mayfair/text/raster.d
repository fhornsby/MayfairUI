module mayfair.text.raster;

import core.stdc.math : cbrtf, floorf, powf, roundf;
import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy, memset;

import mayfair.desktop : Desktop, SubpixelOrder, TextAntialiasing;
import mayfair.renderers.thorvg;
import mayfair.text.font;
import mayfair.text.freetype;
import mayfair.text.paragraph;
import mayfair.text.shaping;
import mayfair.theme : Colour, Theme;

/*
    The bitmap route: text rasterised on the CPU by FreeType, and shown as a picture.

    ThorVG's GPU engine antialiases with 4x MSAA, which gives an edge five shades of coverage.
    That's plenty for a button's rounded corners, but a glyph is nearly all edges, and five shades
    make it coarse; the renderer drew the whole window at twice the size to make up for it, which
    a small GPU can't do in a refresh. FreeType gives 256 shades, with hinting, and it's done once
    per glyph: each is rendered the first time it's wanted at a size and kept, and a block of text
    is those bitmaps put together into one, in its colours, which ThorVG draws as a picture.

    It's made at the scene's pixel scale -- the display's times any render scale -- and put on the
    pixel grid, so it's drawn one texel to a pixel, whatever the renderer does. A widget moved by
    a fraction of a pixel, or scaled by an animation, is resampled, a little soft while it lasts.

    Inside it, each glyph goes where HarfBuzz put it to a third of a pixel across, rather than to
    the nearest whole one: each glyph is rendered at up to three offsets, a third of a pixel apart,
    and the nearest is used. Rounded to whole pixels, a gap that should be 1.4 pixels comes out as
    1 in one place and 2 in the next, and a line's letters look unevenly spaced, as if a little
    blurred, though each is sharp. A third is a subpixel light's width, so subpixel text's lights
    line up with the display's. Up and down, the baseline stays on a whole pixel, which the
    hinting has fitted the glyph to. All of it's in the scene's pixels, whatever the scale: at 1,
    a third of a point; at 2, a sixth; at a fractional 1.25 or 1.5, a third of whatever a pixel
    is there.

    Everything here is @nogc: text is laid out at the width layout gives it, so it's put together
    in paint(), which runs inside the frame. What it holds is malloc'd.

    A colour glyph -- an emoji from a bitmap font -- isn't drawn, as the outline route doesn't draw
    it either.

    Subpixel text
    -------------
    On a display of ordinary density a pixel is too coarse for a letter's stems: one a pixel and a
    half wide comes out as a dark column and a grey one. But a pixel is three lights side by side,
    red, green and blue, and lit one at a time they're three times the detail across, as Windows'
    ClearType and older Linux desktops draw text, and Chrome and Zed still do. FreeType's Harmony
    renderer gives a coverage for each, for the layout the desktop says its display has
    (mayfair.desktop's SubpixelOrder).

    A coverage for each light means a different mix of the text's colour and what's behind it in
    each, which a picture with one alpha to a pixel can't hold -- unless it's known what's behind.
    So a widget says (Widget.behind: the solid colour its own background and its ancestors' make,
    if they make one), and each pixel's colour and alpha are worked out so that drawn over that
    colour, it comes out as the three mixes. Where nothing's drawn the picture is clear, as ever,
    so a guess that's wrong -- something behind the text after all -- shows as a tint at the
    letters' edges, never a box. Where nothing solid is behind it -- frosted glass, a translucent
    window, a page of HTML -- text is greyscale.

    It's on where the desktop says, and where it doesn't, on a display of under 2 pixels to the
    point: at 2 and over the pixels are fine enough, and greyscale has no coloured edges, which is
    why macOS stopped drawing it so. Until an App's made -- in a unit test -- text is greyscale.

    Text that's hard to see
    -----------------------
    A stem of an ordinary weight at an ordinary size is a pixel and a half wide, and it falls
    across two pixels as often as not, so neither is ever the text's colour: each is part way to
    it. Dark text on a light ground has contrast to spare and reads as solid anyway, but text with
    less of it -- grey on light grey, white on a mid blue, a link's colour, anything at half its
    alpha -- loses half of what it had, and looks faint and soft.

    So the less contrast text has, the more its coverage is lifted (see inkExponent): a pixel part
    covered comes out nearer the text's colour, and a stem across two pixels reads as solid. Its
    outline isn't touched, so it keeps its weight -- grey text thickened looks bolder than the
    black beside it, and its stems come out unevenly wide, as where each falls on the grid decides
    how many pixels it takes -- and the curve brings a pixel's three lights' coverages closer
    together, so subpixel text's coloured edges are fainter too.

    And it's drawn less in subpixel colours, down to none (see subpixelShare). Subpixel text's
    edges are tinted, a little differently as each glyph falls a third of a pixel further along:
    beside the contrast of dark text on a light ground the tints are too faint to see, but text
    with less contrast has as much tint and less to hide it behind, and comes out smudged, one
    letter clean and the next one not. Greyscale's edges have no tint to show.

    Both are worked out from colours, not
    from what the text is for: the text as it comes out, its alpha mixed in, against what's
    behind it when that's known, and against its opposite when it isn't. So whatever colours an
    app picks get as much as they need, near-black on white none. And less as text is bigger in
    pixels, as big text, or text on a display of high density, has stems wide enough to hold
    their own.

    A block bigger than tileSize either way is shown as tiles, each a picture of its own: a GPU
    won't make a texture past a limit -- WebGPU's is 8192 pixels unless the device offers more --
    and a line with nowhere to wrap, or a long document in a text area, goes well past it.
*/

/// The most a picture of text is, in pixels, across or down: within any GPU's texture limit.
enum tileSize = 4096;

/// How many places across a pixel a glyph can be drawn at: thirds of a pixel (see the top).
enum phases = 3;

/// What text is drawn over, as far as is known: a solid colour, or not known. For subpixel text.
struct Behind
{
    Colour colour;      /// Opaque, when it's known
    bool known;

    /// `colour` if it's opaque; not known if it isn't, as then what's under it shows through.
    static Behind solid(Colour colour) pure nothrow @safe @nogc
    {
        return colour.a == 255 ? Behind(colour, true) : Behind.init;
    }

    /// What's behind with `fill` drawn over this: the fill if it's opaque, the two mixed if it's
    /// translucent over a known colour, and as it was if the fill's clear.
    Behind covered(Colour fill) const pure nothrow @safe @nogc
    {
        if (fill.a == 255)
            return Behind(fill, true);
        if (fill.a == 0)
            return this;
        if (!known)
            return Behind.init;
        static ubyte mix(ubyte over, ubyte under, uint a) { return cast(ubyte)((over * a + under * (255 - a) + 127) / 255); }
        return Behind(Colour(mix(fill.r, colour.r, fill.a), mix(fill.g, colour.g, fill.a), mix(fill.b, colour.b, fill.a)), true);
    }
}

/// Takes how text is antialiased from the desktop's settings: the App does, as it starts.
void useDesktopTextSettings()
{
    const s = Desktop.settings;
    antialiasing = s.textAntialiasing;
    order = s.subpixelOrder == SubpixelOrder.unset ? SubpixelOrder.rgb : s.subpixelOrder;
    useSubpixelOrder(order);
}

/// Whether text at `pixelScale` pixels to the point is drawn with subpixel antialiasing.
bool subpixelAt(float pixelScale) nothrow @nogc
{
    final switch (antialiasing)
    {
        case TextAntialiasing.greyscale: return false;
        case TextAntialiasing.subpixel: return true;
        case TextAntialiasing.unset: return pixelScale < 2;
    }
}

private __gshared TextAntialiasing antialiasing = TextAntialiasing.greyscale; // until an App says
private __gshared SubpixelOrder order = SubpixelOrder.rgb;

/*
    Tells FreeType where each light is in a pixel, for its Harmony renderer: in 64ths of a pixel
    from the middle, red's, green's and blue's, y going up. A third of a pixel apart, in a row or
    a column. Glyphs rendered before keep the order they were rendered in, so this is said before
    any are, and once.
*/
private void useSubpixelOrder(SubpixelOrder o)
{
    FT_Vector[3] at;
    final switch (o)
    {
        case SubpixelOrder.unset:
        case SubpixelOrder.rgb: at = [FT_Vector(-21, 0), FT_Vector(0, 0), FT_Vector(21, 0)]; break;
        case SubpixelOrder.bgr: at = [FT_Vector(21, 0), FT_Vector(0, 0), FT_Vector(-21, 0)]; break;
        case SubpixelOrder.vrgb: at = [FT_Vector(0, 21), FT_Vector(0, 0), FT_Vector(0, -21)]; break;
        case SubpixelOrder.vbgr: at = [FT_Vector(0, -21), FT_Vector(0, 0), FT_Vector(0, 21)]; break;
    }
    if (auto lib = ftLibrary())
        FT_Library_SetLcdGeometry(lib, at.ptr);
}

/*
    A block of text as a picture: what a widget draws its text with. `paint` goes in the widget's
    drawing (addPaint(text.paint) in mounted()), and each paint() starts it again, adds the text,
    and finishes it.

        _text.begin(scene.pixelScale, behind);  // behind: what it's drawn over, Widget.behind
        _text.addRun(run, x, baseline, colour);
        _text.finish();
*/
struct TextImage
{
public:
    /// What to add to the scene: a scene holding the picture, so that the widget's transform
    /// and opacity, which paintTree sets on it, don't disturb the picture's own placing.
    Tvg_Paint paint;

    /// Makes `paint`. Once, in the widget's mounted().
    void create() nothrow @nogc
    {
        paint = tvg_scene_new();
        shown = true;
    }

    /// Lets go of its buffers. `paint` is the scene's, and goes with the widget's other paints.
    void release() nothrow @nogc
    {
        free(glyphs);
        free(pixels);
        free(tile);
        free(tiles);
        glyphs = null;
        pixels = tile = null;
        tiles = null;
        glyphCount = glyphCapacity = pixelCapacity = tileCapacity = tileCount = tilesCapacity = 0;
        paint = null; // the tiles are in it, and go with it
    }

    /// What the glyphs added next are drawn over: begin() sets it, and text over a background
    /// of its own -- a selection's -- changes it while it's added.
    Behind behind;

    /// Starts again, for text at `pixelScale` pixels to the point, over `behind`.
    void begin(float pixelScale, Behind behind = Behind.init) nothrow @nogc
    {
        scale = pixelScale > 0 ? pixelScale : 1;
        subpixel = subpixelAt(scale);
        this.behind = behind;
        glyphCount = 0;
    }

    /// `run`, its baseline starting at `x`, `baseline` in points, in `colour`.
    void addRun(ref const GlyphRun run, float x, float baseline, Colour colour) nothrow @nogc
    {
        foreach (ref g; run.glyphs)
            addGlyph(g, x + g.x, baseline + g.y, colour);
    }

    /// One line of a paragraph, as Paragraph.emitLine draws it.
    void addLine(ref Paragraph paragraph, ref const Paragraph.Line line, float x, float baseline, Colour colour) nothrow @nogc
    {
        paragraph.eachGlyph(line, x, baseline, (ref const PositionedGlyph g, float gx, float gy) nothrow @nogc {
            addGlyph(g, gx, gy, colour);
        });
    }

    /// The same, with the glyphs from bytes `from` to `to` of the text over `selected` -- a
    /// selection's colour -- rather than what the rest is over.
    void addLine(ref Paragraph paragraph, ref const Paragraph.Line line, float x, float baseline, Colour colour,
                 size_t from, size_t to, Behind selected) nothrow @nogc
    {
        const rest = behind;
        paragraph.eachGlyphAt(line, x, baseline, (ref const PositionedGlyph g, size_t at, float gx, float gy) nothrow @nogc {
            behind = at >= from && at < to ? selected : rest;
            addGlyph(g, gx, gy, colour);
        });
        behind = rest;
    }

    /// One glyph, its origin at `x`, `y` in points.
    void addGlyph(ref const PositionedGlyph g, float x, float y, Colour colour) nothrow @nogc
    {
        if (colour.a == 0 || !g.font)
            return;
        if (glyphCount == glyphCapacity)
        {
            const more = glyphCapacity ? glyphCapacity * 2 : 64;
            auto grown = cast(Placed*) realloc(glyphs, more * Placed.sizeof);
            if (!grown)
                return;
            glyphs = grown;
            glyphCapacity = more;
        }
        // Each origin to a third of a pixel across, and on a whole one down (see the top). In
        // subpixel colours if what's behind it is known, as they're mixed with it
        const lcd = subpixel && behind.known;
        const thirds = roundf(x * scale * phases);
        const whole = floorf(thirds / phases);
        const ink = cast(ubyte) roundf(inkExponent(colour, behind, (cast(Font) g.font).size * scale) * 255);
        const tint = lcd ? cast(ubyte) roundf(subpixelShare(colour, behind) * 255) : 0;
        glyphs[glyphCount++] = Placed(cast(void*) g.font, g.glyph, cast(int) whole, cast(int) roundf(y * scale), colour,
                                      lcd, behind.colour, cast(ubyte)(thirds - whole * phases), ink, tint);
    }

    /// Puts it together and shows it. Nothing added shows nothing.
    void finish() nothrow @nogc
    {
        // How far it reaches, from each glyph's bitmap
        int left = int.max, top = int.max, right = int.min, bottom = int.min;
        foreach (ref p; glyphs[0 .. glyphCount])
        {
            auto b = bitmapOf(p);
            if (!b || !b.width || !b.height)
                continue;
            const x = p.x + b.left, y = p.y - b.top;
            if (x < left) left = x;
            if (y < top) top = y;
            if (x + b.width > right) right = x + b.width;
            if (y + b.height > bottom) bottom = y + b.height;
        }
        if (left >= right || top >= bottom)
        {
            show(false);
            return;
        }
        const w = right - left, h = bottom - top;
        if (!reserve(cast(size_t) w * h))
        {
            show(false);
            return;
        }
        memset(pixels, 0, cast(size_t) w * h * uint.sizeof);

        foreach (ref p; glyphs[0 .. glyphCount])
        {
            auto b = bitmapOf(p);
            if (!b || !b.width || !b.height)
                continue;
            const ox = p.x + b.left - left, oy = p.y - b.top - top;
            const c = p.colour;
            if (!tabled || p.ink != tableInk)
            {
                coverageCurve(p.ink / 255.0f, table);
                tableInk = p.ink;
                tabled = true;
            }
            if (b.subpixel)
                foreach (row; 0 .. b.height)
                {
                    auto dst = pixels + (oy + row) * w + ox;
                    auto src = b.coverage + row * b.width * 3;
                    foreach (col; 0 .. b.width)
                    {
                        int r = table[src[3 * col]], g = table[src[3 * col + 1]], bl = table[src[3 * col + 2]];
                        if (p.tint != 255)
                        {
                            // Each light's coverage that much of the way from their mean
                            const mean = (r + g + bl) / 3;
                            r = mean + (r - mean) * p.tint / 255;
                            g = mean + (g - mean) * p.tint / 255;
                            bl = mean + (bl - mean) * p.tint / 255;
                        }
                        if (r | g | bl)
                            dst[col] = overSubpixel(dst[col], c, p.behind, cast(ubyte) r, cast(ubyte) g, cast(ubyte) bl);
                    }
                }
            else
                foreach (row; 0 .. b.height)
                {
                    auto dst = pixels + (oy + row) * w + ox;
                    auto src = b.coverage + row * b.width;
                    foreach (col; 0 .. b.width)
                    {
                        const cov = table[src[col]];
                        if (cov)
                            dst[col] = over(dst[col], c, cov);
                    }
                }
        }

        // As tiles, each a picture where the last one in its place was
        const across = (w + tileSize - 1) / tileSize, down = (h + tileSize - 1) / tileSize;
        const count = cast(size_t) across * down;
        if (!reserveTiles(count))
        {
            show(false);
            return;
        }
        size_t i;
        foreach (ty; 0 .. down)
            foreach (tx; 0 .. across)
            {
                const x = tx * tileSize, y = ty * tileSize;
                const tw = w - x < tileSize ? w - x : tileSize, th = h - y < tileSize ? h - y : tileSize;
                const(uint)* from = pixels;
                if (count > 1)
                {
                    // Its rows, together, as a picture has no stride of its own
                    if (!reserveTile(cast(size_t) tw * th))
                    {
                        show(false);
                        return;
                    }
                    foreach (row; 0 .. th)
                        memcpy(tile + row * tw, pixels + (y + row) * w + x, tw * uint.sizeof);
                    from = tile;
                }
                auto picture = replacePicture(paint, i < tileCount ? tiles[i] : null, from, tw, th);
                tvg_picture_set_size(picture, tw / scale, th / scale);
                tvg_paint_translate(picture, (left + x) / scale, (top + y) / scale);
                tiles[i++] = picture;
            }
        if (count < tileCount)
            foreach (old; tiles[count .. tileCount])
                tvg_scene_remove(paint, old); // and ThorVG frees it
        tileCount = count;
        if (!shown)
            show(true);
    }

private:
    Tvg_Paint* tiles;       // the pictures showing it, a tile each, in `paint`
    size_t tileCount, tilesCapacity;
    uint* tile;             // one tile's pixels, when there's more than one
    size_t tileCapacity;
    float scale = 1;
    bool shown;
    bool subpixel;          // whether glyphs over something known are drawn in subpixel colours

    struct Placed
    {
        void* font;          // a Font, held by the GlyphRun it came from for as long as this is being made
        uint glyph;
        int x, y;            // its origin, in pixels
        Colour colour;
        bool subpixel;       // drawn in subpixel colours, over `behind`
        Colour behind;
        ubyte phase;         // how many thirds of a pixel right of x it is
        ubyte ink;           // inkExponent's, in 255ths: how its coverage is lifted
        ubyte tint;          // subpixelShare's, in 255ths: how much of its subpixel colours it keeps
    }
    Placed* glyphs;
    size_t glyphCount, glyphCapacity;
    uint* pixels;
    size_t pixelCapacity;
    ubyte[256] table;       // coverage as it's blended, for tableInk: see coverageCurve
    ubyte tableInk;
    bool tabled;

    const(GlyphBitmap)* bitmapOf(ref const Placed p) nothrow @nogc
    {
        return (cast(Font) p.font).glyphBitmap(p.glyph, scale, p.subpixel, p.phase);
    }

    bool reserve(size_t count) nothrow @nogc
    {
        if (count <= pixelCapacity)
            return true;
        auto grown = cast(uint*) realloc(pixels, count * uint.sizeof);
        if (!grown)
            return false;
        pixels = grown;
        pixelCapacity = count;
        return true;
    }

    bool reserveTiles(size_t count) nothrow @nogc
    {
        if (count <= tilesCapacity)
            return true;
        auto grown = cast(Tvg_Paint*) realloc(tiles, count * Tvg_Paint.sizeof);
        if (!grown)
            return false;
        tiles = grown;
        tilesCapacity = count;
        return true;
    }

    bool reserveTile(size_t count) nothrow @nogc
    {
        if (count <= tileCapacity)
            return true;
        auto grown = cast(uint*) realloc(tile, count * uint.sizeof);
        if (!grown)
            return false;
        tile = grown;
        tileCapacity = count;
        return true;
    }

    void show(bool on) nothrow @nogc
    {
        if (on != shown)
            foreach (t; tiles[0 .. tileCount])
                tvg_paint_set_opacity(t, on ? 255 : 0);
        shown = on;
    }
}

/*
    A new picture of `pixels`, `w` by `h` premultiplied 0xAARRGGBB, in `holder` where `old` was.
    A new one each time, as ThorVG won't load a picture again once it's been drawn: it keeps the
    bitmap it had, and sizing that to the new one's size squashes it.
*/
package(mayfair) Tvg_Paint replacePicture(Tvg_Paint holder, Tvg_Paint old, const(uint)* pixels, int w, int h) nothrow @nogc
{
    auto picture = tvg_picture_new();
    tvg_picture_load_raw(picture, pixels, w, h, TVG_COLORSPACE_ARGB8888, true); // a copy: pixels are the caller's
    if (old)
    {
        tvg_scene_insert(holder, picture, old);
        tvg_scene_remove(holder, old); // and ThorVG frees it
    }
    else
        tvg_scene_add(holder, picture);
    return picture;
}

/*
    How text's coverage is lifted as it's blended: coverage to the power of this, 1 for as it is.

    FreeType's coverage is a fraction of the light, but it's blended into sRGB values, which aren't
    linear in light: half way between two sRGB values is darker than half the light of each. So a
    glyph's edge comes out darker than it should, which dark text wears as a little more weight,
    and reads well, but light text on a dark ground loses to its background: it looks thin. Light
    text is lifted by a gamma curve as strong as it's light (lightLift).

    And text close to what's behind it is lifted by as much as it's close, down to
    Theme.text_contrast_lift (see the top). Closeness is in lightness, CIE L*, where 0 is black and
    100 white: none at Theme.text_contrast_none apart or more, all at text_contrast_full or less,
    eased between; and all of that up to Theme.text_contrast_ppem pixels to the em, none at twice
    that. What's behind is taken to be the text's opposite in lightness when it isn't known, as
    Skia guesses: mid grey is the worst case either way, and white or black text is left alone.

    The stronger of the two.
*/
package(mayfair) float inkExponent(Colour colour, Behind behind, float ppem) nothrow @nogc
{
    const byContrast = closeness(colour, behind);
    enum float small = Theme.text_contrast_ppem;
    const bySize = ppem <= small ? 1 : ppem >= 2 * small ? 0 : (2 * small - ppem) / small;
    const forContrast = 1 - (1 - Theme.text_contrast_lift) * byContrast * bySize;
    const forLight = lightLift(colour);
    return forContrast < forLight ? forContrast : forLight;
}

/*
    How much of its subpixel colours text in `colour` over `behind` keeps, 1 for all of them and
    0 for greyscale: none of them as it's close to what's behind it (see the top). At any size, as
    the tints show at any size.
*/
package(mayfair) float subpixelShare(Colour colour, Behind behind) nothrow @nogc
{
    return 1 - closeness(colour, behind);
}

/*
    How close text in `colour` is to `behind`, as it comes out, its alpha mixed in: 0 at
    Theme.text_contrast_none or more apart in lightness (CIE L*, where 0 is black and 100 white),
    1 at text_contrast_full or less, eased between. What's behind is taken to be the text's
    opposite in lightness when it isn't known, as Skia guesses.
*/
private float closeness(Colour colour, Behind behind) nothrow @nogc
{
    float text, ground;
    if (behind.known)
    {
        // As the text comes out over it: mixed by its alpha in sRGB, as it's blended
        const b = behind.colour;
        static ubyte mix(ubyte over, ubyte under, uint a) nothrow @nogc { return cast(ubyte)((over * a + under * (255 - a) + 127) / 255); }
        text = lightness(Colour(mix(colour.r, b.r, colour.a), mix(colour.g, b.g, colour.a), mix(colour.b, b.b, colour.a)));
        ground = lightness(b);
    }
    else
    {
        const own = lightness(Colour(colour.r, colour.g, colour.b));
        ground = 100 - own;
        text = ground + (own - ground) * (colour.a / 255.0f);
    }
    const apart = text > ground ? text - ground : ground - text;
    enum float none = Theme.text_contrast_none, full = Theme.text_contrast_full;
    float byContrast = apart >= none ? 0 : apart <= full ? 1 : (none - apart) / (none - full);
    return byContrast * byContrast * (3 - 2 * byContrast); // eased in and out
}

unittest
{
    const light = Behind.solid(Colour(0xf5, 0xf5, 0xf7)), white = Behind.solid(Colour(255, 255, 255));
    const dark = Behind.solid(Colour(0x1c, 0x1c, 0x1e));
    // Near-black on light has contrast to spare
    assert(inkExponent(Colour(0x1d, 0x1d, 0x1f), light, 14) == lightLift(Colour(0x1d, 0x1d, 0x1f)));
    // Grey on light gets lifted, and more on light grey than on white, which it's further from
    const grey = Colour(0x86, 0x86, 0x8b);
    assert(inkExponent(grey, light, 14) < 0.8f);
    assert(inkExponent(grey, light, 14) <= inkExponent(grey, white, 14));
    // Grey on dark, the same the other way round
    assert(inkExponent(Colour(0x6e, 0x6e, 0x73), dark, 14) < 0.8f);
    // Black at a third of its alpha is grey, as it comes out
    assert(inkExponent(Colour(0, 0, 0, 85), white, 14) < 0.8f);
    // White on a mid blue, a button's: coloured grounds count too
    assert(inkExponent(Colour(255, 255, 255), Behind.solid(Colour(0x00, 0x7a, 0xff)), 14) < 0.8f);
    // Less as it's bigger in pixels, and only light text's lift past twice text_contrast_ppem
    assert(inkExponent(grey, light, 26) > inkExponent(grey, light, 14));
    assert(inkExponent(grey, light, 2 * Theme.text_contrast_ppem) == lightLift(grey));
    // Not known what's behind: black is left alone, grey isn't
    assert(inkExponent(Colour(0, 0, 0), Behind.init, 14) == 1);
    assert(inkExponent(grey, Behind.init, 14) < 0.8f);
    // Never past text_contrast_lift, or light text's own lift
    const pale = Colour(0xf0, 0xf0, 0xf3);
    const floor = lightLift(pale) < Theme.text_contrast_lift ? lightLift(pale) : Theme.text_contrast_lift;
    assert(inkExponent(pale, light, 8) >= floor - 1e-4f);
    // Subpixel colours: all of them for near-black on light, few for grey, at any size
    assert(subpixelShare(Colour(0x1d, 0x1d, 0x1f), light) == 1);
    assert(subpixelShare(grey, light) < 0.2f);
    assert(subpixelShare(Colour(255, 255, 255), Behind.solid(Colour(0x00, 0x7a, 0xff))) < 0.5f);
}

/// Light text's lift, for blending in sRGB: 1 for black, 1 / text_gamma for white.
private float lightLift(Colour colour) nothrow @nogc
{
    const luminance = 0.2126f * linear(colour.r) + 0.7152f * linear(colour.g) + 0.0722f * linear(colour.b);
    return 1 / (1 + (Theme.text_gamma - 1) * luminance);
}

/// An sRGB value as a fraction of the light.
private float linear(ubyte c) nothrow @nogc
{
    const v = c / 255.0f;
    return v <= 0.04045f ? v / 12.92f : powf((v + 0.055f) / 1.055f, 2.4f);
}

/// CIE L*, 0 for black and 100 for white, roughly as light as it looks.
private float lightness(Colour c) nothrow @nogc
{
    const y = 0.2126f * linear(c.r) + 0.7152f * linear(c.g) + 0.0722f * linear(c.b);
    return y > 216.0f / 24389 ? 116 * cbrtf(y) - 16 : y * 24389.0f / 27;
}

/// Coverage to the power of `exponent`, as a table: what's blended for what FreeType gives.
private void coverageCurve(float exponent, ref ubyte[256] table) nothrow @nogc
{
    foreach (i; 0 .. 256)
        table[i] = cast(ubyte)(powf(i / 255.0f, exponent) * 255 + 0.5f);
}

/*
    A picture drawn in one colour -- a symbolic icon -- lifted as light text's coverage is (see
    lightLift above): its edges are blended into sRGB too, so light strokes on a dark ground
    look thinner and fainter than the same strokes dark on light. `pixels` are premultiplied
    0xAARRGGBB, all in `colour`; dark colours are left as they are.
*/
package(mayfair) void liftLightInk(uint* pixels, size_t count, Colour colour) nothrow @nogc
{
    ubyte[256] table;
    coverageCurve(lightLift(colour), table);
    foreach (ref p; pixels[0 .. count])
    {
        const a = p >> 24;
        if (a == 0 || a == 255)
            continue;
        const lifted = table[a];
        static uint scaled(uint c, uint by, uint from, uint most) { const v = c * by / from; return v > most ? most : v; }
        p = (lifted << 24) | (scaled((p >> 16) & 0xFF, lifted, a, lifted) << 16)
          | (scaled((p >> 8) & 0xFF, lifted, a, lifted) << 8) | scaled(p & 0xFF, lifted, a, lifted);
    }
}

/// `colour` at `coverage` over `dst`, a premultiplied 0xAARRGGBB, as source-over does.
private uint over(uint dst, Colour colour, ubyte coverage) pure nothrow @nogc
{
    const a = colour.a * coverage / 255; // the source's alpha, and it premultiplied
    const r = colour.r * a / 255, g = colour.g * a / 255, b = colour.b * a / 255;
    const keep = 255 - a;
    const da = dst >> 24, dr = (dst >> 16) & 0xFF, dg = (dst >> 8) & 0xFF, db = dst & 0xFF;
    return ((a + da * keep / 255) << 24) | ((r + dr * keep / 255) << 16)
         | ((g + dg * keep / 255) << 8) | (b + db * keep / 255);
}

/*
    `colour` at `r`, `g` and `b`, a coverage for each light of the pixel, over `dst`, for text over
    `behind`. Each light should come out as the text's colour mixed with `behind` by its own
    coverage, which takes a picture that knows what it's over: the source's alpha is the most any
    light is covered, and each colour is what, drawn over `behind` with that alpha, gives the mix.
    That's a colour the alpha can premultiply (no more than it), so the picture is a picture like
    any other, and where it isn't over `behind` after all it's only the edges that are off.
*/
private uint overSubpixel(uint dst, Colour colour, Colour behind, ubyte r, ubyte g, ubyte b) pure nothrow @nogc
{
    const kr = colour.a * r / 255, kg = colour.a * g / 255, kb = colour.a * b / 255; // each light's share of the text
    const a = kr > kg ? (kr > kb ? kr : kb) : (kg > kb ? kg : kb);
    const pr = (behind.r * (a - kr) + colour.r * kr) / 255;
    const pg = (behind.g * (a - kg) + colour.g * kg) / 255;
    const pb = (behind.b * (a - kb) + colour.b * kb) / 255;
    const keep = 255 - a;
    const da = dst >> 24, dr = (dst >> 16) & 0xFF, dg = (dst >> 8) & 0xFF, db = dst & 0xFF;
    return ((a + da * keep / 255) << 24) | ((pr + dr * keep / 255) << 16)
         | ((pg + dg * keep / 255) << 8) | (pb + db * keep / 255);
}

/// One glyph, rendered: how much of each pixel it covers, and where they go from its origin.
struct GlyphBitmap
{
    int left, top;       // from the origin to the top left pixel: right, and up
    int width, height;   // in pixels
    ubyte* coverage;     // width * height, a row after another; null if it's empty
    bool subpixel;       // three coverages to a pixel, red's, green's and blue's
}

/*
    A font's rendered glyphs, by glyph and pixel scale: FreeType renders each once, and it's kept
    for as long as the font is. Open addressing in a malloc'd table, as it's used from paint(),
    where a D associative array can't be.
*/
package(mayfair) struct GlyphCache
{
    /// `glyph` at `scale` pixels to the point, in subpixel coverage or not, `phase` thirds of a
    /// pixel right of where it'd be, if it's been rendered.
    const(GlyphBitmap)* lookup(uint glyph, float scale, bool subpixel = false, ubyte phase = 0) nothrow @nogc
    {
        if (!capacity)
            return null;
        auto e = find(glyph, scale, subpixel, phase);
        return e.used ? &e.bitmap : null;
    }

    /// Renders `glyph` of `face`, which is sized for `scale`, and keeps it. An empty bitmap if
    /// FreeType couldn't, kept too, so it isn't tried again.
    const(GlyphBitmap)* add(FT_Face face, uint glyph, float scale, bool subpixel = false, ubyte phase = 0) nothrow @nogc
    {
        if (count * 4 >= capacity * 3 && !grow())
            return null;
        auto e = find(glyph, scale, subpixel, phase);
        if (!e.used)
        {
            e.used = true;
            e.glyph = glyph;
            e.scale = scale;
            e.subpixel = subpixel;
            e.phase = phase;
            e.bitmap = render(face, glyph, subpixel, phase);
            count++;
        }
        return &e.bitmap;
    }

    void clear() nothrow @nogc
    {
        foreach (ref e; entries[0 .. capacity])
            if (e.used)
                free(e.bitmap.coverage);
        free(entries);
        entries = null;
        capacity = count = 0;
    }

private:
    struct Entry
    {
        bool used;
        bool subpixel;
        ubyte phase;
        uint glyph;
        float scale;
        GlyphBitmap bitmap;
    }
    Entry* entries;
    size_t capacity, count;

    Entry* find(uint glyph, float scale, bool subpixel, ubyte phase) nothrow @nogc
    {
        auto at = hash(glyph, scale, subpixel, phase) & (capacity - 1);
        while (entries[at].used && (entries[at].glyph != glyph || entries[at].scale != scale
                                    || entries[at].subpixel != subpixel || entries[at].phase != phase))
            at = (at + 1) & (capacity - 1);
        return &entries[at];
    }

    static size_t hash(uint glyph, float scale, bool subpixel, ubyte phase) nothrow @nogc
    {
        const s = *cast(const(uint)*) &scale;
        return (glyph * 2654435761u) ^ (s * 40503u) ^ (subpixel ? 0x9E3779B9u : 0) ^ (phase * 0x85EBCA6Bu);
    }

    bool grow() nothrow @nogc
    {
        auto old = entries;
        const oldCapacity = capacity;
        const more = capacity ? capacity * 2 : 256;
        auto fresh = cast(Entry*) malloc(more * Entry.sizeof);
        if (!fresh)
            return false;
        memset(fresh, 0, more * Entry.sizeof);
        entries = fresh;
        capacity = more;
        foreach (ref e; old[0 .. oldCapacity])
            if (e.used)
                *find(e.glyph, e.scale, e.subpixel, e.phase) = e;
        free(old);
        return true;
    }

    // From freetype.h, where they're macros ImportC doesn't surface
    enum FT_LOAD_NO_BITMAP_ = 1 << 3;
    enum FT_LOAD_TARGET_LIGHT_ = 1 << 16; // grid-fitted up and down only: see mayfair.text.outline

    static GlyphBitmap render(FT_Face face, uint glyph, bool subpixel, ubyte phase) nothrow @nogc
    {
        GlyphBitmap b;
        if (FT_Load_Glyph(face, glyph, FT_LOAD_TARGET_LIGHT_ | FT_LOAD_NO_BITMAP_) != 0)
            return b;
        auto slot = face.glyph;
        if (slot.format != FT_Glyph_Format.FT_GLYPH_FORMAT_OUTLINE)
            return b; // a colour or bitmap glyph
        // Moved right by its phase, in 64ths of a pixel. Light hinting only fits a glyph up and
        // down, so moving it across after doesn't undo any of it
        if (phase)
            FT_Outline_Translate(&slot.outline, (phase * 64 + phases / 2) / phases, 0);
        // In subpixel coverage, three bytes to a pixel, red's, green's and blue's: Harmony aligns
        // them, so they're a pixel's three lights whichever way the display has them
        const mode = subpixel ? FT_Render_Mode.FT_RENDER_MODE_LCD : FT_Render_Mode.FT_RENDER_MODE_LIGHT;
        if (FT_Render_Glyph(slot, mode) != 0)
            return b;
        const bm = &slot.bitmap;
        const want = subpixel ? FT_Pixel_Mode.FT_PIXEL_MODE_LCD : FT_Pixel_Mode.FT_PIXEL_MODE_GRAY;
        // FreeType's renderers write rows downwards; a negative pitch, upwards, isn't theirs
        if (bm.pixel_mode != want || !bm.width || !bm.rows || bm.pitch < 0)
            return b;
        const bytes = bm.width; // a row's, which is three to a pixel in subpixel coverage
        b.left = slot.bitmap_left;
        b.top = slot.bitmap_top;
        b.width = subpixel ? bm.width / 3 : bm.width;
        b.height = bm.rows;
        b.subpixel = subpixel;
        b.coverage = cast(ubyte*) malloc(bytes * b.height);
        if (!b.coverage)
            return GlyphBitmap.init;
        // A row at a time, as FreeType's rows can be padded out beyond the glyph's width
        foreach (row; 0 .. b.height)
            b.coverage[row * bytes .. (row + 1) * bytes] = bm.buffer[row * bm.pitch .. row * bm.pitch + bytes];
        return b;
    }
}

unittest
{
    import mayfair.text.fonts : defaultFont;

    // Drawn by ThorVG's software renderer, as a window would draw it
    tvg_engine_init(1);
    scope (exit) tvg_engine_term();
    enum w = 300, h = 40;
    auto pixels = new uint[w * h];
    auto canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_NONE);
    scope (exit) tvg_canvas_destroy(canvas);
    tvg_swcanvas_set_target(canvas, pixels.ptr, w, w, h, TVG_COLORSPACE_ARGB8888);

    TextImage text;
    text.create();
    tvg_canvas_add(canvas, text.paint);
    scope (exit) text.release();
    auto font = defaultFont(14);

    // Draws `s`, and says how far right it reaches, in pixels
    int show(string s)
    {
        auto run = shapeText(font, s);
        text.begin(1);
        text.addRun(run, 0, 20, Colour(0, 0, 0));
        text.finish();
        pixels[] = 0;
        tvg_canvas_update(canvas);
        tvg_canvas_draw(canvas, false);
        tvg_canvas_sync(canvas);
        int right;
        foreach (i, p; pixels)
            if (p >> 24 && cast(int)(i % w) + 1 > right)
                right = cast(int)(i % w) + 1;
        return right;
    }

    const short_ = show("Short");
    assert(short_ > 0, "drawn");
    // Drawn again with other text: a picture that's been drawn won't load again, and this once
    // showed the first text squashed into the second's size
    const width = shapeText(font, "Something rather longer").width;
    const long_ = show("Something rather longer");
    assert(long_ > short_ * 2, "the new text, not the old one stretched");
    assert(long_ > width - 3 && long_ < width + 3, "as wide as it's laid out");
    assert(show("") == 0, "and nothing for no text");
}

unittest
{
    import std.algorithm : canFind;
    import std.array : replicate;
    import mayfair.text.fonts : defaultFont;

    // A line far wider than a tile is drawn as several, all of it, and shorter text after it as one
    tvg_engine_init(1);
    scope (exit) tvg_engine_term();
    enum w = tileSize * 2 + 1000, h = 40;
    auto pixels = new uint[w * h];
    auto canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_NONE);
    scope (exit) tvg_canvas_destroy(canvas);
    tvg_swcanvas_set_target(canvas, pixels.ptr, w, w, h, TVG_COLORSPACE_ARGB8888);

    TextImage text;
    text.create();
    tvg_canvas_add(canvas, text.paint);
    scope (exit) text.release();
    auto font = defaultFont(14);

    // Draws `s`, and says which columns have ink in them
    bool[] show(string s)
    {
        auto run = shapeText(font, s);
        text.begin(1);
        text.addRun(run, 0, 20, Colour(0, 0, 0));
        text.finish();
        pixels[] = 0;
        tvg_canvas_update(canvas);
        tvg_canvas_draw(canvas, false);
        tvg_canvas_sync(canvas);
        auto inked = new bool[w];
        foreach (i, p; pixels)
            if (p >> 24)
                inked[i % w] = true;
        return inked;
    }

    const line = "m".replicate(cast(size_t)((tileSize * 2 + 500) / shapeText(font, "m").width));
    const width = cast(int) shapeText(font, line).width;
    assert(width > tileSize * 2 && width < w, "the test's line spans three tiles");
    auto inked = show(line);
    assert(text.tileCount == 3, "as three tiles");
    foreach (x; [100, tileSize - 3, tileSize + 3, tileSize * 2 + 3, width - 5])
        assert(inked[x - 3 .. x + 3].canFind(true), "drawn all the way along, across the tiles' edges");
    assert(!inked[width + 3 .. $].canFind(true), "and no further");

    inked = show("Short");
    assert(text.tileCount == 1, "back to one");
    assert(!inked[200 .. $].canFind(true), "the long line's other tiles gone");
}

unittest
{
    // What's behind: a translucent fill mixed over a known colour, an opaque one in its place
    const white = Behind.solid(Colour(255, 255, 255));
    assert(white.known && !Behind.solid(Colour(255, 255, 255, 128)).known);
    assert(white.covered(Colour(0, 0, 0, 255)) == Behind(Colour(0, 0, 0), true));
    assert(white.covered(Colour(0, 0, 0, 0)) == white);
    assert(white.covered(Colour(0, 0, 0, 51)) == Behind(Colour(204, 204, 204), true));
    assert(!Behind.init.covered(Colour(0, 0, 0, 51)).known, "translucent over what isn't known");

    // A pixel of subpixel text, drawn over what it was made for, is each light's own mix
    static uint drawnOver(uint picture, Colour under)
    {
        const a = picture >> 24;
        static uint ch(uint p, uint u, uint a) { return p + u * (255 - a) / 255; }
        return (ch((picture >> 16) & 0xFF, under.r, a) << 16) | (ch((picture >> 8) & 0xFF, under.g, a) << 8)
             | ch(picture & 0xFF, under.b, a);
    }
    const black = Colour(0, 0, 0);
    const p = overSubpixel(0, black, Colour(255, 255, 255), 255, 128, 0);
    assert(p >> 24 == 255, "as opaque as its most covered light");
    assert(drawnOver(p, Colour(255, 255, 255)) == 0x007FFF, "red covered, green half, blue not");
    const q = overSubpixel(0, Colour(255, 255, 255), Colour(0, 0, 64), 0, 255, 51);
    assert(drawnOver(q, Colour(0, 0, 64)) == 0x00FF66, "blue a fifth of the way from 64 to 255");
    assert(overSubpixel(0, black, Colour(255, 255, 255), 0, 0, 0) == 0, "nothing covered: clear");
}

unittest
{
    import mayfair.text.fonts : defaultFont;

    // Subpixel text, drawn by ThorVG's software renderer over a ground, as a window would draw it
    tvg_engine_init(1);
    scope (exit) tvg_engine_term();
    enum w = 120, h = 30;
    auto pixels = new uint[w * h];
    auto canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_NONE);
    scope (exit) tvg_canvas_destroy(canvas);
    tvg_swcanvas_set_target(canvas, pixels.ptr, w, w, h, TVG_COLORSPACE_ARGB8888);

    TextImage text;
    text.create();
    tvg_canvas_add(canvas, text.paint);
    scope (exit) text.release();
    auto font = defaultFont(14);
    const was = antialiasing;
    scope (exit) antialiasing = was;

    // Draws "Hillo" in black over `behind`, on a ground of `ground`, and the pixels as drawn
    uint[] draw(Behind behind, uint ground)
    {
        auto run = shapeText(font, "Hillo");
        text.begin(1, behind);
        text.addRun(run, 2, 20, Colour(0, 0, 0));
        text.finish();
        pixels[] = ground;
        tvg_canvas_update(canvas);
        tvg_canvas_draw(canvas, false);
        tvg_canvas_sync(canvas);
        return pixels.dup;
    }
    static bool coloured(uint p) { return ((p >> 16) & 0xFF) != ((p >> 8) & 0xFF) || ((p >> 8) & 0xFF) != (p & 0xFF); }
    static size_t count(const uint[] ps, bool delegate(uint) nothrow which)
    {
        size_t n;
        foreach (p; ps)
            if (which(p))
                n++;
        return n;
    }

    antialiasing = TextAntialiasing.subpixel;
    useSubpixelOrder(SubpixelOrder.rgb);
    const white = 0xFFFFFFFF;
    auto over = draw(Behind.solid(Colour(255, 255, 255)), white);
    assert(count(over, p => coloured(p)) > 10, "subpixel: the stems' edges in colour");
    assert(count(over, p => (p & 0xFFFFFF) < 0x404040) > 10, "and the stems dark");

    // The same over red: what isn't text stays red, so there's no box round it
    auto red = draw(Behind.solid(Colour(255, 255, 255)), 0xFFFF0000);
    foreach (i; 0 .. w * h)
        if (over[i] == white)
            assert(red[i] == 0xFFFF0000, "nothing drawn where there's no text");

    // Over what isn't known, greyscale, as it is when the desktop says so
    assert(count(draw(Behind.init, white), p => coloured(p)) == 0, "nothing known behind: greyscale");
    antialiasing = TextAntialiasing.greyscale;
    assert(count(draw(Behind.solid(Colour(255, 255, 255)), white), p => coloured(p)) == 0, "greyscale asked for");

    // And left to Mayfair: subpixel at ordinary density, greyscale on a dense display
    antialiasing = TextAntialiasing.unset;
    assert(subpixelAt(1) && subpixelAt(1.5f) && !subpixelAt(2));
}

unittest
{
    import mayfair.text.fonts : defaultFont;

    // A glyph goes where it's put to a third of a pixel: an "l" moved by thirds moves by thirds
    tvg_engine_init(1);
    scope (exit) tvg_engine_term();
    enum w = 40, h = 30;
    auto pixels = new uint[w * h];
    auto canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_NONE);
    scope (exit) tvg_canvas_destroy(canvas);
    tvg_swcanvas_set_target(canvas, pixels.ptr, w, w, h, TVG_COLORSPACE_ARGB8888);

    TextImage text;
    text.create();
    tvg_canvas_add(canvas, text.paint);
    scope (exit) text.release();
    auto run = shapeText(defaultFont(14), "l");
    const was = antialiasing;
    scope (exit) antialiasing = was;
    antialiasing = TextAntialiasing.greyscale;

    // Where the ink's middle is, across, for the "l" drawn at `x` points
    double middle(float x)
    {
        text.begin(1);
        text.addRun(run, x, 20, Colour(0, 0, 0));
        text.finish();
        pixels[] = 0;
        tvg_canvas_update(canvas);
        tvg_canvas_draw(canvas, false);
        tvg_canvas_sync(canvas);
        double sum = 0, weight = 0;
        foreach (i, p; pixels)
        {
            sum += (i % w) * (p >> 24);
            weight += p >> 24;
        }
        return sum / weight;
    }
    const at = [middle(10), middle(10 + 1 / 3.0f), middle(10 + 2 / 3.0f), middle(11)];
    foreach (k; 1 .. 4)
    {
        const step = at[k] - at[k - 1];
        assert(step > 0.2 && step < 0.47, "a third of a pixel further each time");
    }
    assert(at[3] - at[0] > 0.9 && at[3] - at[0] < 1.1, "and a whole one after three");
    assert(middle(10.1f) == at[0] && middle(10.4f) == at[1], "to the nearest third");
}

unittest
{
    // A light icon's edges lifted as light text's are; a dark one's left as they are
    uint[3] light = [0x80808080, 0xFFFFFFFF, 0];
    liftLightInk(light.ptr, light.length, Colour(255, 255, 255));
    assert(light[0] >> 24 > 0x80 && (light[0] & 0xFF) == light[0] >> 24, "more of the edge, still premultiplied");
    assert(light[1] == 0xFFFFFFFF && light[2] == 0, "solid and clear stay so");
    uint[1] dark = [0x80000000];
    liftLightInk(dark.ptr, dark.length, Colour(0, 0, 0));
    assert(dark[0] == 0x80000000);
}

unittest
{
    import mayfair.text.fonts : defaultFont;

    // A line with a selection: its glyphs over the selection's colour, the rest over what's behind it
    tvg_engine_init(1);
    scope (exit) tvg_engine_term();
    enum w = 120, h = 30;
    auto pixels = new uint[w * h];
    auto canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_NONE);
    scope (exit) tvg_canvas_destroy(canvas);
    tvg_swcanvas_set_target(canvas, pixels.ptr, w, w, h, TVG_COLORSPACE_ARGB8888);
    TextImage text;
    text.create();
    tvg_canvas_add(canvas, text.paint);
    scope (exit) text.release();
    const was = antialiasing;
    scope (exit) antialiasing = was;
    antialiasing = TextAntialiasing.subpixel;

    auto paragraph = Paragraph(defaultFont(14), "llll mmmm");
    auto lines = paragraph.lines(float.infinity);
    const white = Colour(255, 255, 255);
    text.begin(1, Behind.solid(white));
    // "mmmm" selected, over a colour that isn't known: greyscale there, subpixel elsewhere
    text.addLine(paragraph, lines[0], 2, 20, Colour(0, 0, 0), 5, 9, Behind.init);
    text.finish();
    assert(text.behind == Behind.solid(white), "what's behind the rest, as it was");
    pixels[] = 0xFFFFFFFF;
    tvg_canvas_update(canvas);
    tvg_canvas_draw(canvas, false);
    tvg_canvas_sync(canvas);
    const split = cast(int)(2 + paragraph.lines(float.infinity)[0].width * 5 / 9); // about where "mmmm" starts
    static bool coloured(uint p) { return ((p >> 16) & 0xFF) != ((p >> 8) & 0xFF) || ((p >> 8) & 0xFF) != (p & 0xFF); }
    size_t left, right;
    foreach (i, p; pixels)
        if (coloured(p))
            (cast(int)(i % w) < split ? left : right)++;
    assert(left > 5, "the unselected glyphs in subpixel colour");
    assert(right == 0, "the selected ones greyscale, over what isn't known");
}
