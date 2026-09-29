module mayfair.html.document;

import core.stdc.math : ceilf, cosf, floorf, sinf;
import std.string : fromStringz;

import litehtml_c;
import mayfair.images;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme : Colour;

/*
    An HTML document, laid out and drawn by litehtml: what LiteWebView shows.

    litehtml parses the HTML and CSS and works out where every box and word goes, and asks the
    program showing it for everything else -- fonts, how wide a word is, pictures -- and to draw,
    one box, border and word at a time. Here that's Mayfair's own: text is shaped by HarfBuzz and
    drawn as outlines, as every Label's is, and boxes, borders and pictures are ThorVG paints. So a
    document is drawn into a ThorVG scene once, and then scrolls, and sits in the window, like any
    other widget's drawing.

    It reads files and data: URLs, and nothing from the network: a stylesheet or a picture a page
    names by http: isn't there.

    litehtml's lengths are CSS pixels, which are Mayfair's points: the Scene's transform takes them
    to the screen's pixels, as it does everything else.
*/
package(mayfair) final class HtmlDocument
{
public:
    /*
        Parses `html`, whose relative links are relative to `location`: a file's path, or a
        directory's with a / on the end, or empty for the working directory. `font` is its default,
        for what doesn't say, and `userCss` goes over litehtml's own defaults and under the page's.
    */
    this(string html, string location, Font font, string userCss)
    {
        _location = location;
        _base = location;
        _defaultFont = font;
        _defaultFamilyZ = font.family ~ '\0';

        lh_callbacks cb;
        cb.user = cast(void*) this;
        cb.create_font = &createFont;
        cb.delete_font = &deleteFont;
        cb.text_width = &textWidth;
        cb.draw_text = &drawText;
        cb.default_font_size = font.size;
        cb.default_font_name = _defaultFamilyZ.ptr;
        cb.draw_list_marker = &drawListMarker;
        cb.load_image = &loadImage;
        cb.get_image_size = &getImageSize;
        cb.draw_image = &drawImage;
        cb.draw_solid_fill = &drawSolidFill;
        cb.draw_linear_gradient = &drawLinearGradient;
        cb.draw_radial_gradient = &drawRadialGradient;
        cb.draw_conic_gradient = &drawConicGradient;
        cb.draw_borders = &drawBorders;
        cb.set_caption = &setCaption;
        cb.set_base_url = &setBaseUrl;
        cb.anchor_click = &anchorClick;
        cb.set_cursor = &setCursor;
        cb.transform_text = &transformText;
        cb.import_css = &importCss;
        cb.set_clip = &setClip;
        cb.del_clip = &delClip;
        cb.get_viewport = &getViewport;
        _callbacks = cb;

        const css = userCss ~ '\0';
        _doc = lh_document_create(html.ptr, html.length, &_callbacks, css.ptr);
    }

    /// Lets go of litehtml's document and the pictures it decoded: before ThorVG's engine stops,
    /// and before anything it drew is shown again. Nothing else works after it.
    void dispose() nothrow
    {
        if (_doc)
            lh_document_destroy(_doc);
        _doc = null;
        foreach (image; _imageList)
            if (image.keeper)
            {
                tvg_paint_rel(image.keeper);
                image.keeper = null;
            }
        _images = null;
        _imageList = null;
        _fonts = null;
    }

    /// Whether litehtml could make anything of it.
    bool ok() const nothrow @nogc { return _doc !is null; }

    /// What its <title> says, if it has one.
    string title() const nothrow @nogc { return _title; }

    /// Where it came from, which its links are relative to.
    string location() const nothrow @nogc { return _location; }

    /*
        Lays it out at most `width` wide, in a viewport `viewportWidth` by `viewportHeight` --
        what its media queries and vh and vw units go by. Its size after is width() and height():
        wider than `width` if something in it wouldn't fit.
    */
    void layout(float width, float viewportWidth, float viewportHeight)
    {
        if (!_doc)
            return;
        _viewportWidth = viewportWidth;
        _viewportHeight = viewportHeight;
        lh_document_media_changed(_doc);
        lh_document_render(_doc, width);
    }

    float width() nothrow { return _doc ? lh_document_width(_doc) : 0; }
    float height() nothrow { return _doc ? lh_document_height(_doc) : 0; }

    /*
        Draws it all into `into`, a ThorVG scene, with its top left at the scene's origin. `scale`
        is device pixels per point, which glyphs are hinted to; `canvasWidth` by `canvasHeight`
        is how much the root element's background covers, as a browser's fills its whole window.
    */
    void draw(Tvg_Paint into, float scale, float canvasWidth, float canvasHeight)
    {
        if (!_doc)
            return;
        _targets = [into];
        _scale = scale;
        _canvasWidth = canvasWidth;
        _canvasHeight = canvasHeight;
        _text = null;
        lh_document_draw(_doc, 0, 0, 0, null);
        _targets = null;
        _text = null;
    }

    /*
        The pointer at `x`, `y` in the document, moving, pressed, let go of, and gone. Each says
        whether how it looks changed -- :hover, :active -- so it's to be laid out and drawn again.
        A click on a link is kept for takeClickedLink(): following it here, while litehtml is still
        working out the click, would pull the document out from under it.
    */
    bool mouseMoved(float x, float y) { return _doc && lh_document_mouse_over(_doc, x, y); }
    bool mousePressed(float x, float y) { return _doc && lh_document_mouse_down(_doc, x, y); } /// ditto
    bool mouseReleased(float x, float y) { return _doc && lh_document_mouse_up(_doc, x, y); } /// ditto
    bool mouseLeft() { return _doc && lh_document_mouse_leave(_doc); } /// ditto
    bool mouseCancelled() { return _doc && lh_document_mouse_cancel(_doc); } /// ditto

    /// The link clicked since this was last asked, as its href says it, or null.
    string takeClickedLink() nothrow @nogc
    {
        auto link = _clicked;
        _clicked = null;
        return link;
    }

    /// What the pointer's over wants it to look like, as CSS's cursor says: "pointer" over a link.
    string cursor() const nothrow @nogc { return _cursor; }

    /// Where the first element `selector` matches is, from the document's top left.
    bool find(string selector, out lh_position where)
    {
        if (!_doc)
            return false;
        const z = selector ~ '\0';
        return lh_document_find(_doc, z.ptr, &where);
    }

    /// `url` as a location, relative to the document: see resolveLocation.
    string resolve(string url) const { return resolveLocation(url, _base.length ? _base : _location); }

private:
    lh_document* _doc;
    lh_callbacks _callbacks;
    string _location, _base, _title, _cursor, _clicked;
    Font _defaultFont;
    string _defaultFamilyZ;
    float _viewportWidth = 0, _viewportHeight = 0;

    WebFont[] _fonts;             // litehtml's font handles are indices into this, plus one
    WebImage[string] _images;     // by location
    WebImage[] _imageList;        // the same, to let go of without walking the AA, which may throw

    // While drawing
    Tvg_Paint[] _targets;         // where paints go: the scene given, then each clip inside it
    float _scale = 1;
    float _canvasWidth = 0, _canvasHeight = 0;
    Tvg_Paint _text;              // the last text drawn, which more text in its colour can join
    Colour _textColour;

    // A paint in the current clip, in drawing order
    void add(Tvg_Paint p) nothrow
    {
        _text = null;
        tvg_scene_add(_targets[$ - 1], p);
    }

    WebFont* fontOf(uintptr_t handle) nothrow @nogc
    {
        return handle >= 1 && handle <= _fonts.length && _fonts[handle - 1].font ? &_fonts[handle - 1] : null;
    }

    WebImage image(const(char)* src, const(char)* base)
    {
        const url = src.fromStringz.idup;
        const b = base && *base ? base.fromStringz.idup : null;
        const where = resolveLocation(url, b.length ? resolveLocation(b, _base) : _base);
        if (auto found = where in _images)
            return *found;
        auto image = new WebImage;
        _images[where] = image;
        _imageList ~= image;
        try
            image.image = readImage(where);
        catch (Exception)
            image.image = null;
        if (!image.image || image.image.error)
            return image;
        // Decoded now, for its size, and kept decoded: each copy drawn shares it
        auto p = tvg_picture_new();
        if (tvg_picture_load_data(p, image.image.dataPointer, image.image.dataLength, image.image.mimeType,
                                  image.image.resourcePath, image.image.copyOnLoad) != TVG_RESULT_SUCCESS)
        {
            tvg_paint_rel(p);
            return image;
        }
        tvg_picture_get_size(p, &image.width, &image.height);
        image.keeper = p;
        return image;
    }

    // One copy of `image` at `x`, `y`, `w` by `h`, into `scene`
    void placeImage(Tvg_Paint scene, WebImage image, float x, float y, float w, float h) nothrow
    {
        auto p = tvg_picture_new();
        if (tvg_picture_load_data(p, image.image.dataPointer, image.image.dataLength, image.image.mimeType,
                                  image.image.resourcePath, image.image.copyOnLoad) != TVG_RESULT_SUCCESS)
        {
            tvg_paint_rel(p);
            return;
        }
        tvg_picture_set_size(p, w, h);
        tvg_paint_translate(p, x, y);
        tvg_scene_add(scene, p);
    }

    // A scene clipped to where a background layer may draw, added to the drawing
    Tvg_Paint layerScene(ref const lh_background_layer layer) nothrow
    {
        auto scene = tvg_scene_new();
        auto clip = tvg_shape_new();
        const c = layer.clip_box;
        appendRounded(clip, c.x, c.y, c.width, c.height, layer.border_radius);
        tvg_paint_set_clip(scene, clip);
        add(scene);
        return scene;
    }

    // Where a background layer fills: its clip box, or the whole canvas for the root's
    lh_position fillBox(ref const lh_background_layer layer) nothrow @nogc
    {
        lh_position box = layer.clip_box;
        if (layer.is_root)
        {
            box.width = max(box.x + box.width, _canvasWidth) - box.x;
            box.height = max(box.y + box.height, _canvasHeight) - box.y;
        }
        return box;
    }
}

private:

/// A font, as litehtml asked for it: the Font, and how its text is decorated.
struct WebFont
{
    Font font;
    float descent = 0;
    int decoration;                // LH_UNDERLINE | ...
    float thickness = 0;           // of a decoration line; 0 for the font's own
    int decorationStyle;
    Colour decorationColour;
    bool decorationIsText;         // the decoration's the text's colour
    GlyphRun[string] runs;         // text shaped already: litehtml measures a word, then draws it

    GlyphRun* run(const(char)[] text)
    {
        if (auto found = cast(string) text in runs)
            return found;
        const key = text.idup;
        runs[key] = shapeText(font, key);
        return key in runs;
    }
}

/// A picture a document shows: read once, decoded once, drawn as often as it's used.
final class WebImage
{
    Image image;         // null, or in error, if it couldn't be read
    float width = 0, height = 0;
    Tvg_Paint keeper;    // holds the decoding, for the copies drawn to share
}

HtmlDocument self(void* user) nothrow @nogc { return cast(HtmlDocument) user; }

Colour colour(lh_colour c) nothrow @nogc { return Colour(c.r, c.g, c.b, c.a); }

float max(float a, float b) nothrow @nogc { return a > b ? a : b; }
float min(float a, float b) nothrow @nogc { return a < b ? a : b; }

void fill(Tvg_Paint shape, Colour c) nothrow @nogc { tvg_shape_set_fill_color(shape, c.r, c.g, c.b, c.a); }

// ---- Fonts and text

// CSS's generic families, as the families likely to be installed for each. sans-serif, system-ui
// and the rest are Mayfair's own default.
static immutable serifFamilies = ["Noto Serif", "DejaVu Serif", "Liberation Serif", "FreeSerif", "Times New Roman"];
static immutable monospaceFamilies = ["Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", "Ubuntu Mono",
                                      "FreeMono", "Courier New"];

// The first family in a CSS font-family list that's installed, or the default
Font pickFont(string families, float size, FontWeight weight, bool italic, Font fallback)
{
    import std.algorithm : splitter;
    import std.string : strip;
    import std.uni : toLower;

    foreach (part; families.splitter(','))
    {
        auto name = part.strip;
        if (name.length >= 2 && (name[0] == '"' || name[0] == '\'') && name[$ - 1] == name[0])
            name = name[1 .. $ - 1];
        if (!name.length)
            continue;
        const lower = name.toLower;
        const(string)[] candidates;
        if (lower == "serif")
            candidates = serifFamilies;
        else if (lower == "monospace" || lower == "ui-monospace")
            candidates = monospaceFamilies;
        else if (lower == "sans-serif" || lower == "system-ui" || lower == "ui-sans-serif"
                 || lower == "-apple-system" || lower == "cursive" || lower == "fantasy")
            return defaultFont(size, weight, italic);
        else
            candidates = [name];
        foreach (family; candidates)
            if (hasFamily(family))
                return font(family, size, weight, italic);
    }
    return fallback.family.length && hasFamily(fallback.family)
        ? font(fallback.family, size, weight, italic)
        : defaultFont(size, weight, italic);
}

extern(C) uintptr_t createFont(void* user, const(lh_font_description)* d, lh_font_metrics* fm) nothrow
{
    try
    {
        auto doc = self(user);
        const weight = cast(FontWeight)(d.weight < 100 ? 100 : d.weight > 900 ? 900 : d.weight);
        const size = d.size > 0 ? d.size : doc._defaultFont.size;
        auto f = pickFont(d.family.fromStringz.idup, size, weight, d.italic, doc._defaultFont);

        WebFont w;
        w.font = f;
        w.decoration = d.decoration_line;
        w.thickness = d.decoration_thickness;
        w.decorationStyle = d.decoration_style;
        w.decorationColour = colour(d.decoration_colour);
        w.decorationIsText = d.decoration_current_colour;

        // The line's height is ascent above the baseline and descent below it, gap and all
        fm.font_size = size;
        fm.height = f.lineHeight;
        fm.ascent = f.ascender;
        fm.descent = f.lineHeight - f.ascender;
        fm.x_height = f.xHeight;
        fm.ch_width = w.run("0").width;
        fm.draw_spaces = d.decoration_line != 0; // a space is underlined too
        fm.sub_shift = size / 5;
        fm.super_shift = size / 3;
        w.descent = fm.descent;

        doc._fonts ~= w;
        return doc._fonts.length;
    }
    catch (Exception)
        return 0;
}

extern(C) void deleteFont(void* user, uintptr_t handle) nothrow
{
    if (auto f = self(user).fontOf(handle))
        *f = WebFont.init;
}

extern(C) float textWidth(void* user, const(char)* text, uintptr_t handle) nothrow
{
    try
    {
        if (auto f = self(user).fontOf(handle))
            return f.run(text.fromStringz).width;
    }
    catch (Exception) {}
    return 0;
}

extern(C) void drawText(void* user, uintptr_t, const(char)* text, uintptr_t handle, lh_colour c, lh_position pos) nothrow
{
    try
    {
        auto doc = self(user);
        auto f = doc.fontOf(handle);
        if (!f)
            return;
        auto run = f.run(text.fromStringz);
        const col = colour(c);
        const baseline = pos.y + pos.height - f.descent;

        // Text in one colour, one word after another, goes in one shape: a page is thousands of words
        if (!doc._text || doc._textColour != col)
        {
            auto shape = tvg_shape_new();
            fill(shape, col);
            doc.add(shape);
            doc._text = shape;
            doc._textColour = col;
        }
        emitRun(doc._text, *run, pos.x, baseline, doc._scale);

        if (f.decoration)
        {
            const lineColour = f.decorationIsText ? col : f.decorationColour;
            const thick = f.thickness > 0 ? f.thickness : f.font.underlineThickness;
            if (f.decoration & LH_UNDERLINE)
                decorate(doc, f.decorationStyle, pos.x, baseline + f.font.underlinePosition, run.width, thick, lineColour);
            if (f.decoration & LH_LINE_THROUGH)
                decorate(doc, f.decorationStyle, pos.x, baseline - f.font.xHeight / 2, run.width, thick, lineColour);
            if (f.decoration & LH_OVERLINE)
                decorate(doc, f.decorationStyle, pos.x, baseline - f.font.ascender, run.width, thick, lineColour);
        }
    }
    catch (Exception) {}
}

// A line through or under text, centred on `y`
void decorate(HtmlDocument doc, int style, float x, float y, float w, float thick, Colour c) nothrow
{
    if (w <= 0)
        return;
    auto shape = tvg_shape_new();
    switch (style)
    {
    case LH_DECORATION_DOUBLE:
        tvg_shape_append_rect(shape, x, y - thick * 1.5f, w, thick, 0, 0, true);
        tvg_shape_append_rect(shape, x, y + thick * 0.5f, w, thick, 0, 0, true);
        fill(shape, c);
        break;
    case LH_DECORATION_DOTTED, LH_DECORATION_DASHED:
        tvg_shape_move_to(shape, x, y);
        tvg_shape_line_to(shape, x + w, y);
        tvg_shape_set_stroke_width(shape, thick);
        tvg_shape_set_stroke_cap(shape, TVG_STROKE_CAP_BUTT); // not ThorVG's square, which fills the gaps
        tvg_shape_set_stroke_color(shape, c.r, c.g, c.b, c.a);
        const float[2] dots = [thick, thick], dashes = [thick * 3, thick * 2];
        tvg_shape_set_stroke_dash(shape, style == LH_DECORATION_DOTTED ? dots.ptr : dashes.ptr, 2, 0);
        break;
    case LH_DECORATION_WAVY:
        // Half a wave every two thicknesses, up and down
        const step = thick * 2;
        tvg_shape_move_to(shape, x, y);
        float at = x;
        bool up = true;
        while (at < x + w)
        {
            const next = min(at + step, x + w);
            const peak = up ? y - thick : y + thick;
            tvg_shape_cubic_to(shape, at + (next - at) / 3, peak, at + 2 * (next - at) / 3, peak, next, y);
            at = next;
            up = !up;
        }
        tvg_shape_set_stroke_width(shape, thick);
        tvg_shape_set_stroke_color(shape, c.r, c.g, c.b, c.a);
        break;
    case LH_DECORATION_SOLID:
    default:
        tvg_shape_append_rect(shape, x, y - thick / 2, w, thick, 0, 0, true);
        fill(shape, c);
        break;
    }
    // Beside the text's shape rather than after it, so the words after can still join that
    tvg_scene_add(doc._targets[$ - 1], shape);
}

extern(C) void transformText(void*, lh_string* s, int transform) nothrow
{
    try
    {
        import std.uni : isAlpha, isWhite, toLower, toUpper;
        import std.utf : byDchar;

        size_t n;
        auto p = lh_string_get(s, &n);
        const text = p[0 .. n];
        string result;
        switch (transform)
        {
        case LH_TRANSFORM_UPPERCASE: result = toUpper(text).idup; break;
        case LH_TRANSFORM_LOWERCASE: result = toLower(text).idup; break;
        case LH_TRANSFORM_CAPITALIZE:
            bool start = true;
            foreach (dchar c; text.byDchar)
            {
                result ~= start && isAlpha(c) ? toUpper(c) : c;
                start = isWhite(c);
            }
            break;
        default:
            return;
        }
        lh_string_set(s, result.ptr, result.length);
    }
    catch (Exception) {}
}

// ---- Boxes

extern(C) void drawSolidFill(void* user, uintptr_t, const(lh_background_layer)* layer, lh_colour c) nothrow
{
    auto doc = self(user);
    if (c.a == 0)
        return;
    auto shape = tvg_shape_new();
    const box = doc.fillBox(*layer);
    appendRounded(shape, box.x, box.y, box.width, box.height, layer.is_root ? lh_radii.init : layer.border_radius);
    fill(shape, colour(c));
    doc.add(shape);
}

Tvg_Color_Stop[] colourStops(const(lh_gradient)* g) nothrow
{
    auto stops = new Tvg_Color_Stop[g.stop_count];
    foreach (i, ref s; g.stops[0 .. g.stop_count])
        stops[i] = Tvg_Color_Stop(s.offset, s.colour.r, s.colour.g, s.colour.b, s.colour.a);
    return stops;
}

// The background box a gradient fills, and the gradient in it
void fillGradient(HtmlDocument doc, const(lh_background_layer)* layer, Tvg_Gradient grad, const(lh_gradient)* g) nothrow
{
    auto stops = colourStops(g);
    tvg_gradient_set_color_stops(grad, stops.ptr, cast(uint) stops.length);
    auto shape = tvg_shape_new();
    const box = doc.fillBox(*layer);
    appendRounded(shape, box.x, box.y, box.width, box.height, layer.border_radius);
    tvg_shape_set_gradient(shape, grad);
    doc.add(shape);
}

extern(C) void drawLinearGradient(void* user, uintptr_t, const(lh_background_layer)* layer, const(lh_gradient)* g) nothrow
{
    auto grad = tvg_linear_gradient_new();
    tvg_linear_gradient_set(grad, g.x1, g.y1, g.x2, g.y2);
    fillGradient(self(user), layer, grad, g);
}

extern(C) void drawRadialGradient(void* user, uintptr_t, const(lh_background_layer)* layer, const(lh_gradient)* g) nothrow
{
    auto grad = tvg_radial_gradient_new();
    const r = g.rx > 0 ? g.rx : 1;
    tvg_radial_gradient_set(grad, g.cx, g.cy, r, g.cx, g.cy, 0);
    // An ellipse is a circle squashed down, about its centre
    if (g.ry > 0 && g.ry != r)
    {
        const sy = g.ry / r;
        auto m = Tvg_Matrix(1, 0, 0, 0, sy, g.cy * (1 - sy), 0, 0, 1);
        tvg_gradient_set_transform(grad, &m);
    }
    fillGradient(self(user), layer, grad, g);
}

/*
    ThorVG has no conic gradient, so it's drawn as one: thin wedges about the centre, each the
    colour the gradient is at its angle, overlapping a little so no seam shows between them.
*/
extern(C) void drawConicGradient(void* user, uintptr_t, const(lh_background_layer)* layer, const(lh_gradient)* g) nothrow
{
    import std.math : PI;

    auto doc = self(user);
    if (!g.stop_count)
        return;
    auto scene = doc.layerScene(*layer);
    enum wedges = 180;
    const r = g.rx > 0 ? g.rx : 1;
    const start = g.angle * PI / 180;
    foreach (i; 0 .. wedges)
    {
        const a0 = start + 2 * PI * i / wedges;
        const a1 = start + 2 * PI * (i + 1.5f) / wedges;
        auto wedge = tvg_shape_new();
        // CSS's angles go clockwise from the top
        tvg_shape_move_to(wedge, g.cx, g.cy);
        tvg_shape_line_to(wedge, g.cx + r * sinf(a0), g.cy - r * cosf(a0));
        tvg_shape_line_to(wedge, g.cx + r * sinf(a1), g.cy - r * cosf(a1));
        tvg_shape_close(wedge);
        fill(wedge, stopColour(g, (i + 0.5f) / wedges));
        tvg_scene_add(scene, wedge);
    }
}

// The colour a gradient's stops give at `t`, from 0 to 1
Colour stopColour(const(lh_gradient)* g, float t) nothrow @nogc
{
    const stops = g.stops[0 .. g.stop_count];
    if (t <= stops[0].offset)
        return colour(stops[0].colour);
    foreach (i; 1 .. stops.length)
        if (t <= stops[i].offset)
        {
            const span = stops[i].offset - stops[i - 1].offset;
            const f = span > 0 ? (t - stops[i - 1].offset) / span : 1;
            return colour(stops[i - 1].colour).interpolate(colour(stops[i].colour), f);
        }
    return colour(stops[$ - 1].colour);
}

/*
    A box's border. The ring between its outside and its inside -- each rounded as its radii say,
    the inside less by the widths -- clips everything drawn for it, so each side can be drawn as
    the plain trapezoid it is, meeting its neighbours on the diagonals, and the ring rounds it off.
    That's how every style is drawn: solid fills its side, double and groove and ridge fill bands
    of it, and dotted and dashed stroke down its middle.
*/
extern(C) void drawBorders(void* user, uintptr_t, const(lh_borders)* b, lh_position pos, bool) nothrow
{
    auto doc = self(user);
    static float widthOf(ref const lh_border s) nothrow @nogc
    {
        return s.style == LH_BORDER_NONE || s.style == LH_BORDER_HIDDEN || s.colour.a == 0 ? 0 : s.width;
    }
    const float[4] w = [widthOf(b.left), widthOf(b.top), widthOf(b.right), widthOf(b.bottom)];
    if (w[0] <= 0 && w[1] <= 0 && w[2] <= 0 && w[3] <= 0)
        return;

    auto ring = tvg_shape_new();
    appendRounded(ring, pos.x, pos.y, pos.width, pos.height, b.radius);
    lh_radii inner = b.radius;
    inner.top_left_x = max(0, inner.top_left_x - w[0]);
    inner.top_left_y = max(0, inner.top_left_y - w[1]);
    inner.top_right_x = max(0, inner.top_right_x - w[2]);
    inner.top_right_y = max(0, inner.top_right_y - w[1]);
    inner.bottom_right_x = max(0, inner.bottom_right_x - w[2]);
    inner.bottom_right_y = max(0, inner.bottom_right_y - w[3]);
    inner.bottom_left_x = max(0, inner.bottom_left_x - w[0]);
    inner.bottom_left_y = max(0, inner.bottom_left_y - w[3]);
    appendRounded(ring, pos.x + w[0], pos.y + w[1], pos.width - w[0] - w[2], pos.height - w[1] - w[3], inner);
    tvg_shape_set_fill_rule(ring, TVG_FILL_RULE_EVEN_ODD);

    auto scene = tvg_scene_new();
    tvg_paint_set_clip(scene, ring);
    const(lh_border)*[4] sides = [&b.left, &b.top, &b.right, &b.bottom];
    foreach (side; 0 .. 4)
        if (w[side] > 0)
            drawSide(scene, pos, w, side, *sides[side]);
    doc.add(scene);
}

// One side of a border: 0 left, 1 top, 2 right, 3 bottom
void drawSide(Tvg_Paint scene, lh_position p, ref const float[4] w, int side, ref const lh_border border) nothrow
{
    const c = colour(border.colour);
    // Darker for the side in shadow, of a border drawn as if lit from the top left
    const dark = Colour(cast(ubyte)(c.r * 0.6f), cast(ubyte)(c.g * 0.6f), cast(ubyte)(c.b * 0.6f), c.a);
    const topLeft = side <= 1;
    switch (border.style)
    {
    case LH_BORDER_DOUBLE:
        band(scene, p, w, side, 0, 1 / 3.0f, c);
        band(scene, p, w, side, 2 / 3.0f, 1, c);
        break;
    case LH_BORDER_GROOVE, LH_BORDER_RIDGE:
        const outerDark = (border.style == LH_BORDER_GROOVE) == topLeft;
        band(scene, p, w, side, 0, 0.5f, outerDark ? dark : c);
        band(scene, p, w, side, 0.5f, 1, outerDark ? c : dark);
        break;
    case LH_BORDER_INSET, LH_BORDER_OUTSET:
        band(scene, p, w, side, 0, 1, (border.style == LH_BORDER_INSET) == topLeft ? dark : c);
        break;
    case LH_BORDER_DOTTED, LH_BORDER_DASHED:
        const t = w[side];
        auto line = tvg_shape_new();
        // Down the middle of the side, corner to corner
        const x0 = p.x + (side == 2 ? p.width - t / 2 : side == 0 ? t / 2 : 0);
        const y0 = p.y + (side == 3 ? p.height - t / 2 : side == 1 ? t / 2 : 0);
        const across = side == 1 || side == 3;
        tvg_shape_move_to(line, x0, y0);
        tvg_shape_line_to(line, across ? x0 + p.width : x0, across ? y0 : y0 + p.height);
        tvg_shape_set_stroke_width(line, t);
        tvg_shape_set_stroke_cap(line, TVG_STROKE_CAP_BUTT); // ThorVG's default, square, lengthens every dash by t
        tvg_shape_set_stroke_color(line, c.r, c.g, c.b, c.a);
        const float[2] dots = [t, t], dashes = [t * 3, t * 2];
        tvg_shape_set_stroke_dash(line, border.style == LH_BORDER_DOTTED ? dots.ptr : dashes.ptr, 2, 0);
        tvg_scene_add(scene, line);
        break;
    default:
        band(scene, p, w, side, 0, 1, c);
        break;
    }
}

// Part of a side, from `from` to `to` of the way in from the outside, as a trapezoid
void band(Tvg_Paint scene, lh_position p, ref const float[4] w, int side, float from, float to, Colour c) nothrow
{
    // The rectangles `from` and `to` of the way in, each side in by its own width
    float[4] outer = [p.x + w[0] * from, p.y + w[1] * from, p.x + p.width - w[2] * from, p.y + p.height - w[3] * from];
    float[4] inner = [p.x + w[0] * to, p.y + w[1] * to, p.x + p.width - w[2] * to, p.y + p.height - w[3] * to];
    auto shape = tvg_shape_new();
    // Corners, clockwise from the top left: [x, y] of outer and inner
    void quad(float ax, float ay, float bx, float by, float cx, float cy, float dx, float dy)
    {
        tvg_shape_move_to(shape, ax, ay);
        tvg_shape_line_to(shape, bx, by);
        tvg_shape_line_to(shape, cx, cy);
        tvg_shape_line_to(shape, dx, dy);
        tvg_shape_close(shape);
    }
    final switch (side)
    {
    case 0: quad(outer[0], outer[1], inner[0], inner[1], inner[0], inner[3], outer[0], outer[3]); break;
    case 1: quad(outer[0], outer[1], outer[2], outer[1], inner[2], inner[1], inner[0], inner[1]); break;
    case 2: quad(outer[2], outer[1], outer[2], outer[3], inner[2], inner[3], inner[2], inner[1]); break;
    case 3: quad(outer[0], outer[3], inner[0], inner[3], inner[2], inner[3], outer[2], outer[3]); break;
    }
    fill(shape, c);
    tvg_scene_add(scene, shape);
}

/// A rectangle into `shape`, each corner rounded by its own radii across and down.
void appendRounded(Tvg_Paint shape, float x, float y, float w, float h, lh_radii r) nothrow @nogc
{
    if (w <= 0 || h <= 0)
        return;
    if (r.top_left_x <= 0 && r.top_left_y <= 0 && r.top_right_x <= 0 && r.top_right_y <= 0
        && r.bottom_right_x <= 0 && r.bottom_right_y <= 0 && r.bottom_left_x <= 0 && r.bottom_left_y <= 0)
    {
        tvg_shape_append_rect(shape, x, y, w, h, 0, 0, true);
        return;
    }
    enum k = 1 - 0.5522848f; // how far from the corner a quarter circle's cubic controls sit, as a fraction of its radius
    const r0x = r.top_left_x, r0y = r.top_left_y, r1x = r.top_right_x, r1y = r.top_right_y;
    const r2x = r.bottom_right_x, r2y = r.bottom_right_y, r3x = r.bottom_left_x, r3y = r.bottom_left_y;
    tvg_shape_move_to(shape, x + r0x, y);
    tvg_shape_line_to(shape, x + w - r1x, y);
    tvg_shape_cubic_to(shape, x + w - r1x * k, y, x + w, y + r1y * k, x + w, y + r1y);
    tvg_shape_line_to(shape, x + w, y + h - r2y);
    tvg_shape_cubic_to(shape, x + w, y + h - r2y * k, x + w - r2x * k, y + h, x + w - r2x, y + h);
    tvg_shape_line_to(shape, x + r3x, y + h);
    tvg_shape_cubic_to(shape, x + r3x * k, y + h, x, y + h - r3y * k, x, y + h - r3y);
    tvg_shape_line_to(shape, x, y + r0y);
    tvg_shape_cubic_to(shape, x, y + r0y * k, x + r0x * k, y, x + r0x, y);
    tvg_shape_close(shape);
}

extern(C) void setClip(void* user, lh_position pos, lh_radii radius) nothrow
{
    auto doc = self(user);
    auto scene = tvg_scene_new();
    auto clip = tvg_shape_new();
    appendRounded(clip, pos.x, pos.y, pos.width, pos.height, radius);
    tvg_paint_set_clip(scene, clip);
    doc.add(scene);
    doc._targets ~= scene;
}

extern(C) void delClip(void* user) nothrow
{
    auto doc = self(user);
    doc._text = null;
    if (doc._targets.length > 1)
        doc._targets = doc._targets[0 .. $ - 1];
}

extern(C) void drawListMarker(void* user, uintptr_t, const(lh_list_marker)* m) nothrow
{
    try
    {
        auto doc = self(user);
        const p = m.pos;
        if (m.image && *m.image)
        {
            auto image = doc.image(m.image, m.base_url);
            if (image.keeper)
            {
                doc._text = null;
                doc.placeImage(doc._targets[$ - 1], image, p.x, p.y, image.width, image.height);
            }
            return;
        }
        auto shape = tvg_shape_new();
        const c = colour(m.colour);
        switch (m.type)
        {
        case LH_MARKER_CIRCLE:
            tvg_shape_append_circle(shape, p.x + p.width / 2, p.y + p.height / 2, p.width / 2 - 0.5f, p.height / 2 - 0.5f, true);
            tvg_shape_set_stroke_width(shape, 1);
            tvg_shape_set_stroke_color(shape, c.r, c.g, c.b, c.a);
            break;
        case LH_MARKER_DISC:
            tvg_shape_append_circle(shape, p.x + p.width / 2, p.y + p.height / 2, p.width / 2, p.height / 2, true);
            fill(shape, c);
            break;
        case LH_MARKER_SQUARE:
            tvg_shape_append_rect(shape, p.x, p.y, p.width, p.height, 0, 0, true);
            fill(shape, c);
            break;
        default:
            break;
        }
        doc.add(shape);
    }
    catch (Exception) {}
}

// ---- Pictures

extern(C) void loadImage(void* user, const(char)* src, const(char)* base, bool) nothrow
{
    try
        self(user).image(src, base);
    catch (Exception) {}
}

extern(C) void getImageSize(void* user, const(char)* src, const(char)* base, float* w, float* h) nothrow
{
    *w = *h = 0;
    try
    {
        auto image = self(user).image(src, base);
        *w = image.width;
        *h = image.height;
    }
    catch (Exception) {}
}

/*
    A picture, as an <img> or a background: one copy at the layer's origin box, as big as it is,
    and more of it tiled out from there across the clip box as far as background-repeat says.
*/
extern(C) void drawImage(void* user, uintptr_t, const(lh_background_layer)* layer, const(char)* url, const(char)* base) nothrow
{
    try
    {
        auto doc = self(user);
        auto image = doc.image(url, base);
        const o = layer.origin_box, c = layer.clip_box;
        if (!image.keeper || o.width <= 0 || o.height <= 0)
            return;
        auto scene = doc.layerScene(*layer);
        const acrossToo = layer.repeat == LH_REPEAT || layer.repeat == LH_REPEAT_X;
        const downToo = layer.repeat == LH_REPEAT || layer.repeat == LH_REPEAT_Y;
        // From the first copy left of and above the clip box, if it repeats that way
        const x0 = acrossToo ? o.x - ceilf((o.x - c.x) / o.width) * o.width : o.x;
        const y0 = downToo ? o.y - ceilf((o.y - c.y) / o.height) * o.height : o.y;
        const x1 = acrossToo ? c.x + c.width : o.x + 1;
        const y1 = downToo ? c.y + c.height : o.y + 1;
        enum maxCopies = 4096; // a tiny picture tiled over a huge page stops somewhere
        int copies;
        for (float y = y0; y < y1 && copies < maxCopies; y += o.height)
            for (float x = x0; x < x1 && copies < maxCopies; x += o.width, copies++)
                doc.placeImage(scene, image, x, y, o.width, o.height);
    }
    catch (Exception) {}
}

// ---- The rest of what litehtml asks

extern(C) void setCaption(void* user, const(char)* caption) nothrow
{
    try
        self(user)._title = caption.fromStringz.idup;
    catch (Exception) {}
}

extern(C) void setBaseUrl(void* user, const(char)* url) nothrow
{
    try
    {
        auto doc = self(user);
        const base = url.fromStringz.idup;
        if (base.length)
            doc._base = resolveLocation(base, doc._location);
    }
    catch (Exception) {}
}

extern(C) void anchorClick(void* user, const(char)* url) nothrow
{
    try
        self(user)._clicked = url.fromStringz.idup;
    catch (Exception) {}
}

extern(C) void setCursor(void* user, const(char)* cursor) nothrow
{
    try
        self(user)._cursor = cursor.fromStringz.idup;
    catch (Exception) {}
}

extern(C) void importCss(void* user, lh_string* text, const(char)* url, lh_string* base) nothrow
{
    try
    {
        auto doc = self(user);
        size_t n;
        auto b = lh_string_get(base, &n);
        const from = n ? resolveLocation(b[0 .. n].idup, doc._base) : doc._base;
        const where = resolveLocation(url.fromStringz.idup, from);
        const css = readText(where);
        lh_string_set(text, css.ptr, css.length);
        lh_string_set(base, where.ptr, where.length);
    }
    catch (Exception) {}
}

extern(C) void getViewport(void* user, lh_position* viewport) nothrow
{
    auto doc = self(user);
    *viewport = lh_position(0, 0, doc._viewportWidth, doc._viewportHeight);
}

// ---- Where things are

public:

/*
    Where `url` points, from a document at `base`: a data: URL as it is; a file as its absolute
    path, from a file: URL or a relative or absolute path, without any ?query or #fragment; or
    anything else -- http:, mailto: -- as it is, for whoever follows it to make sense of. `base` is
    a file's path, or a directory's ending in /, or empty for the working directory.
*/
package(mayfair) string resolveLocation(string url, string base)
{
    import std.path : absolutePath, buildNormalizedPath, dirName, isAbsolute;
    import std.string : indexOf, strip;
    import std.uri : decode;

    url = url.strip;
    if (url.length >= 5 && url[0 .. 5] == "data:")
        return url;
    if (const s = schemeOf(url))
    {
        if (s != "file")
            return url;
        url = url[5 .. $];
        if (url.length >= 2 && url[0 .. 2] == "//")
            url = url[2 .. $];
        // file://host/path: only this machine is a host a file can be on
        const slash = url.indexOf('/');
        url = slash > 0 ? url[slash .. $] : url;
    }
    foreach (stop; ['#', '?'])
    {
        const at = url.indexOf(stop);
        if (at >= 0)
            url = url[0 .. at];
    }
    url = decode(url);
    if (!url.length)
        return base.length ? base : "";
    if (url.isAbsolute)
        return buildNormalizedPath(url);
    if (base.length && schemeOf(base) && schemeOf(base) != "file")
        return url; // relative to a web page, which isn't anywhere to be read
    const b = base.length ? resolveLocation(base, "") : "";
    const dir = !b.length ? "." : base[$ - 1] == '/' ? b : dirName(b);
    return buildNormalizedPath(absolutePath(dir), url);
}

/// The scheme `url` starts with, lower-cased -- "file", "https" -- or null for a path.
package(mayfair) string schemeOf(string url)
{
    import std.ascii : isAlpha, isAlphaNum, toLower;

    foreach (i, c; url)
    {
        if (c == ':')
            return i >= 2 ? url[0 .. i].toLowerAscii : null; // one letter is a Windows drive
        if (!(isAlphaNum(c) || (i && (c == '+' || c == '-' || c == '.'))) || (!i && !isAlpha(c)))
            return null;
    }
    return null;
}

private string toLowerAscii(string s)
{
    import std.ascii : toLower;
    import std.array : array;
    import std.algorithm : map;
    import std.conv : to;

    return s.map!(c => cast(char) toLower(c)).array.to!string;
}

/// What's at `location`, a file or a data: URL, as bytes. Throws if it can't be read.
package(mayfair) ubyte[] readBytes(string location)
{
    import std.base64 : Base64;
    import std.exception : enforce;
    import std.file : read;
    import std.string : indexOf;
    import std.uri : decodeComponent;

    if (location.length >= 5 && location[0 .. 5] == "data:")
    {
        const comma = location.indexOf(',');
        enforce(comma > 0, "a data: URL with no comma");
        const header = location[5 .. comma];
        const payload = location[comma + 1 .. $];
        if (header.length >= 7 && header[$ - 7 .. $] == ";base64")
        {
            char[] clean;
            foreach (c; payload)
                if (c != ' ' && c != '\n' && c != '\r' && c != '\t')
                    clean ~= c;
            return Base64.decode(clean);
        }
        return cast(ubyte[]) decodeComponent(payload).dup;
    }
    enforce(!schemeOf(location), "only files and data: URLs can be read: " ~ location);
    return cast(ubyte[]) read(location);
}

/// The same, as text.
package(mayfair) string readText(string location)
{
    return cast(string) readBytes(location);
}

/// A picture at `location`, read now. Throws if it can't be.
package(mayfair) Image readImage(string location)
{
    if (location.length >= 5 && location[0 .. 5] == "data:")
        return Image.fromData(readBytes(location), "data");
    return new Image(location);
}

unittest
{
    assert(resolveLocation("b.html", "/docs/a.html") == "/docs/b.html");
    assert(resolveLocation("img/x.png", "/docs/") == "/docs/img/x.png");
    assert(resolveLocation("../x.css?v=2#top", "/docs/sub/a.html") == "/docs/x.css");
    assert(resolveLocation("file:///tmp/a%20b.html", "") == "/tmp/a b.html");
    assert(resolveLocation("https://example.org/", "/docs/a.html") == "https://example.org/");
    assert(resolveLocation("x.png", "https://example.org/a.html") == "x.png");
    assert(resolveLocation("data:text/plain,hi", "/docs/") == "data:text/plain,hi");
    assert(schemeOf("C:/x") is null && schemeOf("HTTP://x") == "http" && schemeOf("a/b:c") is null);
    assert(readText("data:text/plain,hello%20there") == "hello there");
    assert(readText("data:text/plain;base64,aGk=") == "hi");
}
