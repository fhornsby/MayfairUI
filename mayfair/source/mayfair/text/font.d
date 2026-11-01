module mayfair.text.font;

import std.string : fromStringz, toStringz;
import mayfair.text.freetype;
import mayfair.text.harfbuzz;
import mayfair.text.raster : GlyphBitmap, GlyphCache;

/// How heavy a face is, on the OS/2 table's (and CSS's) 100-900 scale.
enum FontWeight : ushort
{
    thin = 100,
    extraLight = 200,
    light = 300,
    regular = 400,
    medium = 500,
    semiBold = 600,
    bold = 700,
    extraBold = 800,
    black = 900,
}

/*
    A font file at a size, ready to shape and draw with. It owns both halves of what that takes: an
    FT_Face, which turns a glyph id into an outline, and an hb_font_t reading its metrics and tables
    from that same face, so there is one source of truth for both.

    The size is set at 72 dpi, which makes FreeType's 26.6 fixed-point unit exactly 1/64 of a point.
    Everything that comes back out -- advances, offsets, outline coordinates, ascender, line height
    -- is therefore in points once divided by 64, and points are what widgets lay out and paint in.
    Nothing here knows about the device scale: the one transform on the Scene handles that, which is
    the whole reason glyphs stay outlines rather than becoming pixels in an atlas.

    Most code never constructs one: font() in mayfair.text.fonts finds an installed family by name
    and hands back a shared instance. This constructor is for a file the app ships itself.
*/
class Font
{
public:
    /// Opens face `faceIndex` of the file at `path` (a .ttc holds several) at `sizePoints`. Throws
    /// if the file can't be read as a font.
    this(string path, float sizePoints, int faceIndex = 0)
    {
        this(FaceSource(path, null, faceIndex), sizePoints);
    }

    ~this()
    {
        if (_hb) hb_font_destroy(_hb);
        if (_face) FT_Done_Face(_face);
        if (_outline) FT_Done_Face(_outline);
        _bitmaps.clear();
    }

    float size() const nothrow @nogc { return _size; }

    /// The family name the file gives itself, e.g. "DejaVu Sans".
    string family() const nothrow @nogc { return _family; }

    FontWeight weight() const nothrow @nogc { return _style.weight; }

    bool italic() const nothrow @nogc { return _style.italic; }

    /// Distance from the top of a line to its baseline, in points.
    float ascender() const nothrow @nogc { return _face.size.metrics.ascender / 64.0f; }

    /// Baseline to baseline, in points. What a wrapped paragraph steps down by per line.
    float lineHeight() const nothrow @nogc { return _face.size.metrics.height / 64.0f; }

    /// Distance from the baseline to the bottom of a line, in points: positive, below it.
    float descender() const nothrow @nogc { return -_face.size.metrics.descender / 64.0f; }

    /// How tall a lower-case x is, in points, as the font says, or half its size if it doesn't.
    float xHeight() nothrow @nogc
    {
        auto os2 = cast(TT_OS2*) FT_Get_Sfnt_Table(_face, FT_Sfnt_Tag.FT_SFNT_OS2);
        // Only a version 2 table has it: FreeType leaves it 0 in an older one
        if (os2 && os2.sxHeight > 0 && _face.units_per_EM)
            return os2.sxHeight * _size / _face.units_per_EM;
        return _size / 2;
    }

    /// Where an underline goes, in points below the baseline, and how thick it is: the font's
    /// own, or what's usual where it doesn't say.
    float underlinePosition() const nothrow @nogc
    {
        if (!_face.units_per_EM || !_face.underline_position)
            return _size / 10;
        return -_face.underline_position * _size / _face.units_per_EM;
    }

    /// ditto
    float underlineThickness() const nothrow @nogc
    {
        if (!_face.units_per_EM || _face.underline_thickness <= 0)
            return _size / 14;
        return _face.underline_thickness * _size / _face.units_per_EM;
    }

    /// Whether this face has a glyph for `c`. Where it doesn't, shaping falls back to another font.
    bool hasGlyph(dchar c) nothrow @nogc { return FT_Get_Char_Index(_face, c) != 0; }

    /*
        Glyph `glyph` rendered by FreeType at `scale` pixels to the point: rendered the first time
        it's asked for, and kept. It's what TextImage draws text with (see mayfair.text.raster),
        and it's here for a widget that puts its own pixels together, as a terminal's grid does.
        The glyph ids come from shaping: a PositionedGlyph's, with the font it's in.
    */
    const(GlyphBitmap)* glyphBitmap(uint glyph, float scale, bool subpixel = false) nothrow @nogc
    {
        if (auto b = _bitmaps.lookup(glyph, scale, subpixel))
            return b;
        return _bitmaps.add(outlineFace(scale), glyph, scale, subpixel);
    }

package:
    this(FaceSource source, float sizePoints)
    {
        auto lib = ftLibrary();
        if (source.open(lib, &_face) != 0)
            throw new Exception("Could not open font: " ~ source.name);

        _size = sizePoints;
        _family = _face.family_name ? _face.family_name.fromStringz.idup : "";
        _style = FaceStyle.of(_face);
        // 26.6 fixed point, at 72 dpi so that one point is one "pixel" and 26.6 units are points/64
        FT_Set_Char_Size(_face, 0, cast(int)(sizePoints * 64), 72, 72);

        _hb = hb_ft_font_create_referenced(_face);
        if (!_hb)
            throw new Exception("HarfBuzz could not wrap the font: " ~ source.name);

        // A second face, for outlines only. Shaping and measuring happen on _face at a fixed 72 dpi
        // and stay scale-free; hinting has to grid-fit to real device pixels, so it needs a face
        // sized in them. Keeping them apart means resizing this one can't disturb what HarfBuzz
        // reads from the other, and the split falls exactly on the seam: everything above a
        // GlyphRun is scale-free, and only emitting it knows what a device pixel is.
        if (source.open(lib, &_outline) != 0)
            throw new Exception("Could not open font: " ~ source.name);
    }

    hb_font_t* hb() nothrow @nogc { return _hb; }

    /// The face to load outlines from, sized so that one device pixel really is one pixel to
    /// FreeType, which is what hinting needs to grid-fit against. Resized only when the scale
    /// changes, which is a display change, not a frame.
    FT_Face outlineFace(float scale) nothrow @nogc
    {
        if (scale != _outlineScale)
        {
            FT_Set_Char_Size(_outline, 0, cast(int)(_size * scale * 64), 72, 72);
            _outlineScale = scale;
        }
        return _outline;
    }

private:
    FT_Face _face;
    FT_Face _outline;
    float _outlineScale = 0; // 0 so the first call always sizes it
    GlyphCache _bitmaps;
    hb_font_t* _hb;
    float _size;
    string _family;
    FaceStyle _style;
}

package:

/*
    Where a face's bytes come from: a file on disk, or memory compiled into the binary (the bundled
    fallback). Either way FreeType is handed it fresh for each FT_Face, since Font keeps two.
*/
struct FaceSource
{
    string path;               /// empty when the face is in memory
    immutable(ubyte)[] data;   /// empty when the face is a file
    int index;                 /// which face, in a collection

    string name() const nothrow @nogc { return path.length ? path : "<bundled font>"; }

    FT_Error open(FT_Library lib, FT_Face* face) const nothrow
    {
        if (data.length)
            return FT_New_Memory_Face(lib, data.ptr, cast(FT_Long) data.length, index, face);
        return FT_New_Face(lib, path.toStringz(), index, face);
    }
}

/// What a request for a family can be matched on, besides its name.
struct FaceStyle
{
    FontWeight weight = FontWeight.regular;
    ushort width = 5;   /// OS/2 usWidthClass: 1 ultra-condensed .. 5 normal .. 9 ultra-expanded
    bool italic;

    /// Reads the OS/2 table where there is one, and FreeType's style flags where there isn't.
    static FaceStyle of(FT_Face face) nothrow @nogc
    {
        FaceStyle s;
        s.italic = (face.style_flags & FT_STYLE_FLAG_ITALIC_) != 0;
        auto os2 = cast(TT_OS2*) FT_Get_Sfnt_Table(face, FT_Sfnt_Tag.FT_SFNT_OS2);
        // A face without the table gets a stub whose fields are zero, which the range checks reject
        if (os2 && os2.usWeightClass != 0)
        {
            if (os2.usWeightClass >= 1 && os2.usWeightClass <= 1000)
                s.weight = cast(FontWeight) os2.usWeightClass;
            if (os2.usWidthClass >= 1 && os2.usWidthClass <= 9)
                s.width = os2.usWidthClass;
        }
        else if (face.style_flags & FT_STYLE_FLAG_BOLD_)
            s.weight = FontWeight.bold;
        return s;
    }
}

// From freetype.h, where they're macros ImportC doesn't surface.
enum FT_STYLE_FLAG_ITALIC_ = 1 << 0;
enum FT_STYLE_FLAG_BOLD_ = 1 << 1;
enum FT_FACE_FLAG_SCALABLE_ = 1 << 0;

/*
    One FreeType library for the process. FT_Library is not thread-safe, and neither is the rest of
    Mayfair, so this being thread-local costs nothing and avoids sharing a mutable handle.
*/
FT_Library ftLibrary()
{
    static FT_Library library;
    if (!library && FT_Init_FreeType(&library) != 0)
        throw new Exception("FreeType failed to initialise");
    return library;
}
