module mayfair.text.raster;

import core.stdc.math : roundf;
import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memset;

import mayfair.renderers.thorvg;
import mayfair.text.font;
import mayfair.text.freetype;
import mayfair.text.paragraph;
import mayfair.text.shaping;
import mayfair.theme : Colour;

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

    Everything here is @nogc: text is laid out at the width layout gives it, so it's put together
    in paint(), which runs inside the frame. What it holds is malloc'd.

    A colour glyph -- an emoji from a bitmap font -- isn't drawn, as the outline route doesn't draw
    it either.
*/

/*
    A block of text as a picture: what a widget draws its text with. `paint` goes in the widget's
    drawing (addPaint(text.paint) in mounted()), and each paint() starts it again, adds the text,
    and finishes it.

        _text.begin(scene.pixelScale);
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
        picture = tvg_picture_new();
        tvg_scene_add(paint, picture);
        shown = true;
    }

    /// Lets go of its buffers. `paint` is the scene's, and goes with the widget's other paints.
    void release() nothrow @nogc
    {
        free(glyphs);
        free(pixels);
        glyphs = null;
        pixels = null;
        glyphCount = glyphCapacity = pixelCapacity = 0;
        paint = picture = null;
    }

    /// Starts again, for text at `pixelScale` pixels to the point.
    void begin(float pixelScale) nothrow @nogc
    {
        scale = pixelScale > 0 ? pixelScale : 1;
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
        // Each origin on a whole pixel, so a letter comes out the same wherever it's repeated
        glyphs[glyphCount++] = Placed(cast(void*) g.font, g.glyph, cast(int) roundf(x * scale),
                                      cast(int) roundf(y * scale), colour);
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
            foreach (row; 0 .. b.height)
            {
                auto dst = pixels + (oy + row) * w + ox;
                auto src = b.coverage + row * b.width;
                foreach (col; 0 .. b.width)
                {
                    const cov = src[col];
                    if (cov)
                        dst[col] = over(dst[col], c, cov);
                }
            }
        }

        tvg_picture_load_raw(picture, pixels, w, h, TVG_COLORSPACE_ARGB8888, true);
        tvg_picture_set_size(picture, w / scale, h / scale);
        tvg_paint_translate(picture, left / scale, top / scale);
        show(true);
    }

private:
    Tvg_Paint picture;
    float scale = 1;
    bool shown;

    struct Placed
    {
        void* font;          // a Font, held by the GlyphRun it came from for as long as this is being made
        uint glyph;
        int x, y;            // its origin, in pixels
        Colour colour;
    }
    Placed* glyphs;
    size_t glyphCount, glyphCapacity;
    uint* pixels;
    size_t pixelCapacity;

    const(GlyphBitmap)* bitmapOf(ref const Placed p) nothrow @nogc
    {
        return (cast(Font) p.font).glyphBitmap(p.glyph, scale);
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

    void show(bool on) nothrow @nogc
    {
        if (on != shown && picture)
            tvg_paint_set_opacity(picture, on ? 255 : 0);
        shown = on;
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

/// One glyph, rendered: how much of each pixel it covers, and where they go from its origin.
package(mayfair) struct GlyphBitmap
{
    int left, top;       // from the origin to the top left pixel: right, and up
    int width, height;
    ubyte* coverage;     // width * height, a row after another; null if it's empty
}

/*
    A font's rendered glyphs, by glyph and pixel scale: FreeType renders each once, and it's kept
    for as long as the font is. Open addressing in a malloc'd table, as it's used from paint(),
    where a D associative array can't be.
*/
package(mayfair) struct GlyphCache
{
    /// `glyph` at `scale` pixels to the point, if it's been rendered.
    const(GlyphBitmap)* lookup(uint glyph, float scale) nothrow @nogc
    {
        if (!capacity)
            return null;
        auto e = find(glyph, scale);
        return e.used ? &e.bitmap : null;
    }

    /// Renders `glyph` of `face`, which is sized for `scale`, and keeps it. An empty bitmap if
    /// FreeType couldn't, kept too, so it isn't tried again.
    const(GlyphBitmap)* add(FT_Face face, uint glyph, float scale) nothrow @nogc
    {
        if (count * 4 >= capacity * 3 && !grow())
            return null;
        auto e = find(glyph, scale);
        if (!e.used)
        {
            e.used = true;
            e.glyph = glyph;
            e.scale = scale;
            e.bitmap = render(face, glyph);
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
        uint glyph;
        float scale;
        GlyphBitmap bitmap;
    }
    Entry* entries;
    size_t capacity, count;

    Entry* find(uint glyph, float scale) nothrow @nogc
    {
        auto at = hash(glyph, scale) & (capacity - 1);
        while (entries[at].used && (entries[at].glyph != glyph || entries[at].scale != scale))
            at = (at + 1) & (capacity - 1);
        return &entries[at];
    }

    static size_t hash(uint glyph, float scale) nothrow @nogc
    {
        const s = *cast(const(uint)*) &scale;
        return (glyph * 2654435761u) ^ (s * 40503u);
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
                *find(e.glyph, e.scale) = e;
        free(old);
        return true;
    }

    // From freetype.h, where they're macros ImportC doesn't surface
    enum FT_LOAD_NO_BITMAP_ = 1 << 3;
    enum FT_LOAD_TARGET_LIGHT_ = 1 << 16; // grid-fitted up and down only: see mayfair.text.outline

    static GlyphBitmap render(FT_Face face, uint glyph) nothrow @nogc
    {
        GlyphBitmap b;
        if (FT_Load_Glyph(face, glyph, FT_LOAD_TARGET_LIGHT_ | FT_LOAD_NO_BITMAP_) != 0)
            return b;
        auto slot = face.glyph;
        if (slot.format != FT_Glyph_Format.FT_GLYPH_FORMAT_OUTLINE)
            return b; // a colour or bitmap glyph
        if (FT_Render_Glyph(slot, FT_Render_Mode.FT_RENDER_MODE_LIGHT) != 0)
            return b;
        const bm = &slot.bitmap;
        // FreeType's renderers write rows downwards; a negative pitch, upwards, isn't theirs
        if (bm.pixel_mode != FT_Pixel_Mode.FT_PIXEL_MODE_GRAY || !bm.width || !bm.rows || bm.pitch < 0)
            return b;
        b.left = slot.bitmap_left;
        b.top = slot.bitmap_top;
        b.width = bm.width;
        b.height = bm.rows;
        b.coverage = cast(ubyte*) malloc(b.width * b.height);
        if (!b.coverage)
            return GlyphBitmap.init;
        // A row at a time, as FreeType's rows can be padded out beyond the glyph's width
        foreach (row; 0 .. b.height)
            b.coverage[row * b.width .. (row + 1) * b.width] = bm.buffer[row * bm.pitch .. row * bm.pitch + b.width];
        return b;
    }
}
