module mayfair.widgets.canvas;

import std.math : abs, ceil, cos, floor, PI, sin, sqrt;
import mayfair.accessibility;
import mayfair.images;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.label : TextAlignment;
import mayfair.widgets.widget;

/*
    A picture to draw on: JavaFX's Canvas. What's drawn stays drawn, as on paper, until it's drawn
    over or cleared, so it's what a painting program, a chart drawn by hand or a game's board wants.

        auto canvas = new Canvas(400, 300);
        auto g = canvas.graphicsContext;
        g.setFill(Colour(37, 99, 235)).fillRoundRect(20, 20, 160, 90, 16, 16);
        g.setStroke(Colour(220, 38, 38)).setLineWidth(4).strokeLine(20, 150, 380, 150);
        g.setFill(Colour(0, 0, 0)).fillText("Hello", 20, 200);

    It holds pixels, not shapes: each call is rasterised into them, once a frame, and then it's
    over. A thousand strokes cost no more to show than one, and what's there can be read back
    (pixels, colourAt) and saved (savePng). The pixels are the screen's, not points -- twice as
    many each way on a 2x display -- so it's as sharp as the rest of the window; move it to a
    display of another scale and what's been drawn is resampled.

    It's as big as `width` by `height` points, which layout doesn't stretch. Making it bigger keeps
    what's drawn, at the top left, with the new space transparent, as JavaFX's does.

    Its style class is "canvas". To a screen reader it's an image, named by its accessibleText.
*/
class Canvas : Widget
{
public:
    this(float width = 0, float height = 0)
    {
        _width = width;
        _height = height;
        _graphics = new GraphicsContext(this);
        styleClass.add("canvas");
        setAccessibleRole(AccessibleRole.image);
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureCanvas);
    }

    /// How wide it is, in points. JavaFX's Canvas.width.
    mixin(declareProperty!(float, "width", "0", q{ resized(); }));

    /// How tall it is, in points. JavaFX's Canvas.height.
    mixin(declareProperty!(float, "height", "0", q{ resized(); }));

    /// What draws on it. There's one, for as long as the canvas lasts.
    final GraphicsContext graphicsContext() nothrow @nogc { return _graphics; }

    /*
        Its pixels, drawing up to now included: pixelWidth by pixelHeight of them, a row after
        another, each 0xAARRGGBB with the colour premultiplied by its alpha. Change them and call
        pixelsChanged() to show it -- for what drawing calls don't do, like a flood fill.

        Null until it's first been in a window, as until then there's no screen to match.
    */
    final uint[] pixels()
    {
        flush();
        return _pixels;
    }

    /// How many pixels across and down it holds, and how many to a point.
    final uint pixelWidth() const nothrow @nogc { return _pw; }
    final uint pixelHeight() const nothrow @nogc { return _ph; } /// ditto
    final float pixelScale() const nothrow @nogc { return _pixelScale; } /// ditto

    /// Shows what was done to pixels() since it was asked for.
    final void pixelsChanged()
    {
        _shown = false;
        requestUpdate();
    }

    /// The colour at (`x`, `y`), in points: transparent outside it, or before it's been in a window.
    final Colour colourAt(float x, float y)
    {
        flush();
        const px = cast(long) floor(x * _pixelScale), py = cast(long) floor(y * _pixelScale);
        if (px < 0 || py < 0 || px >= _pw || py >= _ph)
            return Colour(0, 0, 0, 0);
        return unpremultiply(_pixels[cast(size_t)(py * _pw + px)]);
    }

    /// Its pixels as a PNG file's bytes, or null before it's been in a window.
    final ubyte[] toPng()
    {
        flush();
        return _pixels.length ? encodePng(_pixels, _pw, _ph) : null;
    }

    /// Writes its pixels to `path` as a PNG file. Throws if they can't be written, or aren't there yet.
    final void savePng(string path)
    {
        import std.exception : enforce;
        import std.file : write;

        auto png = toPng();
        enforce(png !is null, "the canvas hasn't been drawn yet: it has to have been in a window");
        write(path, png);
    }

    /// Its pixels as an Image, to show in an ImageView, say. JavaFX's snapshot. Null before it's
    /// been in a window.
    final Image snapshot()
    {
        auto png = toPng();
        return png ? Image.fromData(png, "canvas.png") : null;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    // As big as it says and no bigger, as JavaFX's isn't resizable
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    override void mounted() nothrow
    {
        _holder = addPaint(tvg_scene_new());
        _shown = false; // a new holder, with nothing in it yet
        requestUpdate();
    }

    override void unmounted()
    {
        // The holder took the picture with it. The rasteriser is ThorVG's, and ThorVG's engine
        // may stop before this is back in a window: it's made again then. The pixels are ours.
        _holder = null;
        _picture = null;
        if (_rasteriser)
            tvg_canvas_destroy(_rasteriser);
        _rasteriser = null;
    }

    override void update()
    {
        flush();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        if (!_picture)
            return;
        const s = 1 / _pixelScale;
        auto m = Tvg_Matrix(s, 0, x, 0, s, y, 0, 0, 1);
        tvg_paint_set_transform(_picture, &m);
    }

package(mayfair):
    /// A paint to draw next, from the GraphicsContext: the canvas has it now.
    void draw(Tvg_Paint p)
    {
        if (!_queue.length || _queue[$ - 1].clears)
            _queue ~= Pending(tvg_scene_new());
        tvg_scene_add(_queue[$ - 1].paints, p);
        requestUpdate();
    }

    /// Makes what's under `rect`, in points, transparent.
    void clear(Bounds rect)
    {
        _queue ~= Pending(null, true, rect);
        requestUpdate();
    }

    /// Device pixels per point where it's shown, or 1 until it's in a window.
    float targetScale() nothrow @nogc { return scene ? scene.scale : 1; }

private:
    GraphicsContext _graphics;
    uint[] _pixels;
    uint _pw, _ph;
    float _pixelScale = 1;
    Tvg_Canvas _rasteriser; // ThorVG's software renderer, drawing into _pixels
    Tvg_Paint _holder, _picture;
    bool _shown;            // _picture shows _pixels as they are

    // Drawing not yet rasterised, in order: paints in a scene, or a clearing
    struct Pending
    {
        Tvg_Paint paints;
        bool clears;
        Bounds rect;
    }
    Pending[] _queue;

    void resized() nothrow @nogc
    {
        YGNodeMarkDirty(node);
        requestUpdate();
        invalidate();
    }

    /// Rasterises what's waiting, and shows the result: in the update phase, or before pixels are read.
    void flush()
    {
        if (!scene || !_holder)
            return; // nothing to match the pixels to yet: it waits
        fitPixels(scene.scale);
        foreach (ref p; _queue)
        {
            if (p.clears)
                clearPixels(p.rect);
            else
            {
                tvg_paint_scale(p.paints, _pixelScale);
                rasterise(p.paints);
            }
        }
        if (_queue.length)
            _shown = false;
        _queue = null;
        if (!_shown)
            show();
    }

    /// Draws `paints` over the pixels there are, and lets them go.
    void rasterise(Tvg_Paint paints)
    {
        tvg_canvas_add(_rasteriser, paints);
        tvg_canvas_update(_rasteriser);
        tvg_canvas_draw(_rasteriser, false);
        tvg_canvas_sync(_rasteriser);
        tvg_canvas_remove(_rasteriser, null);
    }

    /// Makes the pixels as many as the size and `scale` need, keeping what's drawn.
    void fitPixels(float scale)
    {
        const pw = cast(uint) ceil(_width * scale - 0.01f), ph = cast(uint) ceil(_height * scale - 0.01f);
        if (_rasteriser && pw == _pw && ph == _ph && scale == _pixelScale)
            return;
        auto old = _pixels;
        const ow = _pw, oh = _ph, oldScale = _pixelScale;

        if (pw != _pw || ph != _ph || !_pixels.length)
            _pixels = new uint[pw * ph];
        _pw = pw;
        _ph = ph;
        _pixelScale = scale;
        if (!_rasteriser)
            _rasteriser = tvg_swcanvas_create(TVG_ENGINE_OPTION_NONE); // no smart render: it'd clear what it thinks is stale
        if (pw && ph)
            tvg_swcanvas_set_target(_rasteriser, _pixels.ptr, pw, pw, ph, TVG_COLORSPACE_ARGB8888);
        _shown = false;

        if (old is _pixels || !old.length || !pw || !ph)
            return;
        if (scale == oldScale)
        {
            // Bigger or smaller: what's drawn stays at the top left
            foreach (y; 0 .. (oh < ph ? oh : ph))
                _pixels[y * pw .. y * pw + (ow < pw ? ow : pw)] = old[y * ow .. y * ow + (ow < pw ? ow : pw)];
        }
        else
        {
            // Another display: what's drawn, resampled to its pixels
            auto picture = tvg_picture_new();
            tvg_picture_load_raw(picture, old.ptr, ow, oh, TVG_COLORSPACE_ARGB8888, true);
            tvg_paint_scale(picture, scale / oldScale);
            rasterise(picture);
        }
    }

    /// Clears `rect`, in points, rounded out to whole pixels.
    void clearPixels(Bounds rect)
    {
        long x0 = cast(long) floor(rect.minX * _pixelScale), y0 = cast(long) floor(rect.minY * _pixelScale);
        long x1 = cast(long) ceil(rect.maxX * _pixelScale), y1 = cast(long) ceil(rect.maxY * _pixelScale);
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > _pw) x1 = _pw;
        if (y1 > _ph) y1 = _ph;
        foreach (y; y0 .. y1)
            if (x0 < x1)
                _pixels[cast(size_t)(y * _pw + x0) .. cast(size_t)(y * _pw + x1)] = 0;
    }

    /// Puts the pixels as they are in the window: ThorVG takes a copy, so drawing can go on in them.
    void show()
    {
        if (_picture)
            tvg_scene_remove(_holder, _picture);
        _picture = null;
        if (_pw && _ph)
        {
            _picture = tvg_picture_new();
            tvg_picture_load_raw(_picture, _pixels.ptr, _pw, _ph, TVG_COLORSPACE_ARGB8888, true);
            tvg_scene_add(_holder, _picture);
        }
        _shown = true;
        invalidate();
    }
}

/// How a stroke's open ends are drawn. JavaFX's StrokeLineCap.
enum StrokeLineCap { butt, round, square }

/// How a stroke turns a corner. JavaFX's StrokeLineJoin.
enum StrokeLineJoin { miter, bevel, round }

/// Which parts of a path that crosses itself are inside it. JavaFX's FillRule.
enum FillRule { nonZero, evenOdd }

/// Where text's `y` is: the top of its first line, its middle, its first baseline, or its bottom. JavaFX's VPos.
enum TextBaseline { top, centre, baseline, bottom }

/// How what's drawn mixes with what's there. JavaFX's BlendMode, less those ThorVG lacks.
enum BlendMode
{
    srcOver, multiply, screen, overlay, darken, lighten, colourDodge, colourBurn, hardLight, softLight,
    difference, exclusion, add,
}

/*
    Draws on a Canvas: JavaFX's GraphicsContext, as HTML's canvas has it too. It keeps a state --
    colours, line width, transform, clip and the rest -- that each call draws with, and save() and
    restore() put it by and bring it back.

    Coordinates are points, from the canvas's top left, through the transform. Setters return the
    context, so they chain; fill() and stroke() fill and stroke the path, so the colours they use
    are fillColour() and strokeColour().

    Only from the UI thread, as with anything else in the window.
*/
final class GraphicsContext
{
public:
    /// The canvas it draws on.
    Canvas canvas() nothrow @nogc { return _canvas; }

    // ---- State

    /// The colour shapes and text are filled with. Black to start with.
    GraphicsContext setFill(Colour c) { s.fill = c; return this; }
    Colour fillColour() const nothrow @nogc { return s.fill; } /// ditto

    /// The colour lines and outlines are drawn in. Black to start with.
    GraphicsContext setStroke(Colour c) { s.stroke = c; return this; }
    Colour strokeColour() const nothrow @nogc { return s.stroke; } /// ditto

    /// How wide lines are, in points. 1 to start with.
    GraphicsContext setLineWidth(float w) { if (w > 0) s.lineWidth = w; return this; }
    float lineWidth() const nothrow @nogc { return s.lineWidth; } /// ditto

    /// How lines end. Square to start with, as JavaFX's.
    GraphicsContext setLineCap(StrokeLineCap c) { s.cap = c; return this; }
    StrokeLineCap lineCap() const nothrow @nogc { return s.cap; } /// ditto

    /// How lines turn corners. Miter to start with.
    GraphicsContext setLineJoin(StrokeLineJoin j) { s.join = j; return this; }
    StrokeLineJoin lineJoin() const nothrow @nogc { return s.join; } /// ditto

    /// How far a miter join may reach, as a multiple of the line width, before it's bevelled. 10 to start with.
    GraphicsContext setMiterLimit(float l) { if (l > 0) s.miterLimit = l; return this; }
    float miterLimit() const nothrow @nogc { return s.miterLimit; } /// ditto

    /// Dashes: lengths of dash and gap in turn, in points; none for a solid line.
    GraphicsContext setLineDashes(float[] dashes...) { s.dashes = dashes.dup; return this; }
    const(float)[] lineDashes() const nothrow @nogc { return s.dashes; } /// ditto

    /// How far into the dash pattern lines start.
    GraphicsContext setLineDashOffset(float o) { s.dashOffset = o; return this; }
    float lineDashOffset() const nothrow @nogc { return s.dashOffset; } /// ditto

    /// How opaque everything drawn is, 0 to 1, on top of its colour's own alpha. 1 to start with.
    GraphicsContext setGlobalAlpha(float a) { s.alpha = a < 0 ? 0 : a > 1 ? 1 : a; return this; }
    float globalAlpha() const nothrow @nogc { return s.alpha; } /// ditto

    /// How what's drawn mixes with what's there. Plain painting over (srcOver) to start with.
    GraphicsContext setGlobalBlendMode(BlendMode m) { s.blend = m; return this; }
    BlendMode globalBlendMode() const nothrow @nogc { return s.blend; } /// ditto

    /// Which parts of a path that crosses itself fill() fills. Non-zero to start with.
    GraphicsContext setFillRule(FillRule r) { s.fillRule = r; return this; }
    FillRule fillRule() const nothrow @nogc { return s.fillRule; } /// ditto

    /// The font text is drawn in: from mayfair.text's font() or defaultFont(). The UI's own to start with.
    GraphicsContext setFont(Font f) { s.font = f; return this; }
    Font font() { if (!s.font) s.font = defaultFont(Theme.text_size); return s.font; } /// ditto

    /// Where text's `x` is: its left end, its middle, or its right end. Left to start with.
    GraphicsContext setTextAlign(TextAlignment a) { s.textAlign = a; return this; }
    TextAlignment textAlign() const nothrow @nogc { return s.textAlign; } /// ditto

    /// Where text's `y` is. Its baseline to start with.
    GraphicsContext setTextBaseline(TextBaseline b) { s.textBaseline = b; return this; }
    TextBaseline textBaseline() const nothrow @nogc { return s.textBaseline; } /// ditto

    /// Whether an image drawn bigger or smaller is smoothed, or its pixels kept square, as pixel art wants. On to start with.
    GraphicsContext setImageSmoothing(bool on) { s.smooth = on; return this; }
    bool imageSmoothing() const nothrow @nogc { return s.smooth; } /// ditto

    /// Puts the state by, to be brought back by restore(): the path isn't part of it.
    GraphicsContext save() { saved ~= s; return this; }

    /// Brings back the state last put by, if there is one.
    GraphicsContext restore()
    {
        if (saved.length)
        {
            s = saved[$ - 1];
            saved = saved[0 .. $ - 1];
        }
        return this;
    }

    // ---- Transform

    /// Moves what's drawn next by (`x`, `y`).
    GraphicsContext translate(float x, float y) { return transform(1, 0, 0, 1, x, y); }

    /// Scales what's drawn next.
    GraphicsContext scale(float x, float y) { return transform(x, 0, 0, y, 0, 0); }

    /// Turns what's drawn next by `degrees`, clockwise, about the origin.
    GraphicsContext rotate(float degrees)
    {
        const r = degrees * PI / 180, c = cos(r), sn = sin(r);
        return transform(c, sn, -sn, c, 0, 0);
    }

    /// Applies an affine transform, in JavaFX's order: x' = mxx x + mxy y + mxt, y' = myx x + myy y + myt.
    GraphicsContext transform(float mxx, float myx, float mxy, float myy, float mxt, float myt)
    {
        s.m = multiply(s.m, Tvg_Matrix(mxx, mxy, mxt, myx, myy, myt, 0, 0, 1));
        return this;
    }

    /// Replaces the transform. setTransform(1, 0, 0, 1, 0, 0) for none.
    GraphicsContext setTransform(float mxx, float myx, float mxy, float myy, float mxt, float myt)
    {
        s.m = Tvg_Matrix(mxx, mxy, mxt, myx, myy, myt, 0, 0, 1);
        return this;
    }

    // ---- Rectangles, ovals, lines

    /// Fills a rectangle.
    GraphicsContext fillRect(float x, float y, float w, float h)
    {
        auto p = tvg_shape_new();
        tvg_shape_append_rect(p, x, y, w, h, 0, 0, true);
        return filled(p);
    }

    /// Outlines a rectangle.
    GraphicsContext strokeRect(float x, float y, float w, float h)
    {
        auto p = tvg_shape_new();
        tvg_shape_append_rect(p, x, y, w, h, 0, 0, true);
        return stroked(p);
    }

    /// Makes a rectangle transparent, whatever the blend mode and clip. Under a rotation, it's the
    /// upright rectangle round it that's cleared.
    GraphicsContext clearRect(float x, float y, float w, float h)
    {
        float x0 = float.infinity, y0 = float.infinity, x1 = -float.infinity, y1 = -float.infinity;
        foreach (c; [[x, y], [x + w, y], [x, y + h], [x + w, y + h]])
        {
            float tx, ty;
            apply(s.m, c[0], c[1], tx, ty);
            if (tx < x0) x0 = tx;
            if (ty < y0) y0 = ty;
            if (tx > x1) x1 = tx;
            if (ty > y1) y1 = ty;
        }
        _canvas.clear(Bounds(x0, y0, x1 - x0, y1 - y0));
        return this;
    }

    /// Fills a rectangle with its corners rounded: `arcWidth` and `arcHeight` across, as JavaFX's.
    GraphicsContext fillRoundRect(float x, float y, float w, float h, float arcWidth, float arcHeight)
    {
        auto p = tvg_shape_new();
        tvg_shape_append_rect(p, x, y, w, h, arcWidth / 2, arcHeight / 2, true);
        return filled(p);
    }

    /// Outlines a rectangle with its corners rounded.
    GraphicsContext strokeRoundRect(float x, float y, float w, float h, float arcWidth, float arcHeight)
    {
        auto p = tvg_shape_new();
        tvg_shape_append_rect(p, x, y, w, h, arcWidth / 2, arcHeight / 2, true);
        return stroked(p);
    }

    /// Fills the oval inside a rectangle.
    GraphicsContext fillOval(float x, float y, float w, float h)
    {
        auto p = tvg_shape_new();
        tvg_shape_append_circle(p, x + w / 2, y + h / 2, w / 2, h / 2, true);
        return filled(p);
    }

    /// Outlines the oval inside a rectangle.
    GraphicsContext strokeOval(float x, float y, float w, float h)
    {
        auto p = tvg_shape_new();
        tvg_shape_append_circle(p, x + w / 2, y + h / 2, w / 2, h / 2, true);
        return stroked(p);
    }

    /// Draws a line.
    GraphicsContext strokeLine(float x1, float y1, float x2, float y2)
    {
        auto p = tvg_shape_new();
        tvg_shape_move_to(p, x1, y1);
        tvg_shape_line_to(p, x2, y2);
        return stroked(p);
    }

    /// Fills the polygon with corners at xs[i], ys[i].
    GraphicsContext fillPolygon(const float[] xs, const float[] ys)
    {
        return filled(polyline(xs, ys, true));
    }

    /// Outlines the polygon with corners at xs[i], ys[i].
    GraphicsContext strokePolygon(const float[] xs, const float[] ys)
    {
        return stroked(polyline(xs, ys, true));
    }

    /// Draws lines from one point to the next, not back to the first.
    GraphicsContext strokePolyline(const float[] xs, const float[] ys)
    {
        return stroked(polyline(xs, ys, false));
    }

    // ---- Paths

    /// Starts a new path, forgetting the last.
    GraphicsContext beginPath() { cmds = null; pts = null; return this; }

    /// Starts a new part of the path at (`x`, `y`).
    GraphicsContext moveTo(float x, float y)
    {
        cmds ~= TVG_PATH_COMMAND_MOVE_TO;
        pts ~= at(x, y);
        return this;
    }

    /// A straight line from where the path is to (`x`, `y`).
    GraphicsContext lineTo(float x, float y)
    {
        startIfEmpty(x, y);
        cmds ~= TVG_PATH_COMMAND_LINE_TO;
        pts ~= at(x, y);
        return this;
    }

    /// A curve to (`x`, `y`), pulled towards (`xc`, `yc`).
    GraphicsContext quadraticCurveTo(float xc, float yc, float x, float y)
    {
        startIfEmpty(xc, yc);
        // The same curve as a cubic: its control points two thirds of the way to the quadratic's
        const from = pts[$ - 1], c = at(xc, yc), to = at(x, y);
        cmds ~= TVG_PATH_COMMAND_CUBIC_TO;
        pts ~= Tvg_Point(from.x + 2 * (c.x - from.x) / 3, from.y + 2 * (c.y - from.y) / 3);
        pts ~= Tvg_Point(to.x + 2 * (c.x - to.x) / 3, to.y + 2 * (c.y - to.y) / 3);
        pts ~= to;
        return this;
    }

    /// A Bézier curve to (`x`, `y`), with control points (`xc1`, `yc1`) and (`xc2`, `yc2`).
    GraphicsContext bezierCurveTo(float xc1, float yc1, float xc2, float yc2, float x, float y)
    {
        startIfEmpty(xc1, yc1);
        cmds ~= TVG_PATH_COMMAND_CUBIC_TO;
        pts ~= at(xc1, yc1);
        pts ~= at(xc2, yc2);
        pts ~= at(x, y);
        return this;
    }

    /*
        Part of an oval centred on (`cx`, `cy`), from `startAngle` round by `length`, in degrees
        counter-clockwise from the right as JavaFX measures them (so on the screen, with y going
        down, a positive length goes anticlockwise). Joined to the path by a line from where it is.
    */
    GraphicsContext arc(float cx, float cy, float rx, float ry, float startAngle, float length)
    {
        // In quarter turns at most, each as one cubic
        const segments = cast(int) ceil(abs(length) / 90 - 1e-4);
        const start = -startAngle * PI / 180, sweep = -length * PI / 180;
        float px = cx + rx * cos(start), py = cy + ry * sin(start);
        if (cmds.length)
            lineTo(px, py);
        else
            moveTo(px, py);
        if (segments < 1)
            return this;
        const step = sweep / segments, k = 4.0 / 3 * (sin(step / 2) / (1 + cos(step / 2)));
        foreach (i; 0 .. segments)
        {
            const a0 = start + step * i, a1 = a0 + step;
            const x1 = cx + rx * cos(a1), y1 = cy + ry * sin(a1);
            bezierCurveTo(px - k * rx * sin(a0), py + k * ry * cos(a0),
                          x1 + k * rx * sin(a1), y1 - k * ry * cos(a1), x1, y1);
            px = x1;
            py = y1;
        }
        return this;
    }

    /// Adds a rectangle to the path, as a part of its own.
    GraphicsContext rect(float x, float y, float w, float h)
    {
        moveTo(x, y);
        lineTo(x + w, y);
        lineTo(x + w, y + h);
        lineTo(x, y + h);
        return closePath();
    }

    /// Joins the path's part back to where it started.
    GraphicsContext closePath()
    {
        if (cmds.length)
            cmds ~= TVG_PATH_COMMAND_CLOSE;
        return this;
    }

    /// Fills the path, by the fill rule.
    GraphicsContext fill()
    {
        if (!cmds.length)
            return this;
        auto p = pathShape();
        tvg_shape_set_fill_color(p, s.fill.r, s.fill.g, s.fill.b, s.fill.a);
        tvg_shape_set_fill_rule(p, s.fillRule == FillRule.evenOdd ? TVG_FILL_RULE_EVEN_ODD : TVG_FILL_RULE_NON_ZERO);
        emit(p);
        return this;
    }

    /// Draws along the path, in the line width as the transform has it now.
    GraphicsContext stroke()
    {
        if (!cmds.length)
            return this;
        auto p = pathShape();
        // The path's points were transformed as they went in, but not its width
        strokeStyle(p, sqrt(abs(s.m.e11 * s.m.e22 - s.m.e12 * s.m.e21)));
        emit(p);
        return this;
    }

    /// Limits what's drawn from now on to inside the path, and whatever clip there was already,
    /// until the state's restored.
    GraphicsContext clip()
    {
        s.clips ~= Clip(cmds.dup, pts.dup, s.fillRule);
        return this;
    }

    // ---- Text

    /// Fills `text` in the font, at (`x`, `y`) as textAlign and textBaseline say. A newline starts another line.
    GraphicsContext fillText(string text, float x, float y)
    {
        auto p = textShape(text, x, y);
        tvg_shape_set_fill_color(p, s.fill.r, s.fill.g, s.fill.b, s.fill.a);
        return transformed(p);
    }

    /// Outlines `text`'s letters.
    GraphicsContext strokeText(string text, float x, float y)
    {
        auto p = textShape(text, x, y);
        strokeStyle(p, 1);
        return transformed(p);
    }

    // ---- Images

    /// Draws `image` at (`x`, `y`), its own size.
    GraphicsContext drawImage(Image image, float x, float y)
    {
        float w, h;
        auto p = picture(image, w, h);
        if (p)
            place(p, 0, 0, w, h, x, y, w, h);
        return this;
    }

    /// Draws `image` stretched to fill a rectangle.
    GraphicsContext drawImage(Image image, float x, float y, float w, float h)
    {
        float iw, ih;
        auto p = picture(image, iw, ih);
        if (p)
            place(p, 0, 0, iw, ih, x, y, w, h);
        return this;
    }

    /// Draws part of `image`, (`sx`, `sy`, `sw`, `sh`) in its own pixels, stretched to fill (`dx`, `dy`, `dw`, `dh`).
    GraphicsContext drawImage(Image image, float sx, float sy, float sw, float sh, float dx, float dy, float dw, float dh)
    {
        float iw, ih;
        auto p = picture(image, iw, ih);
        if (p)
            place(p, sx, sy, sw, sh, dx, dy, dw, dh);
        return this;
    }

package(mayfair):
    this(Canvas canvas)
    {
        _canvas = canvas;
    }

private:
    struct Clip
    {
        Tvg_Path_Command[] cmds;
        Tvg_Point[] pts;
        FillRule rule;
    }

    struct State
    {
        Tvg_Matrix m = Tvg_Matrix(1, 0, 0, 0, 1, 0, 0, 0, 1);
        Colour fill = Colour(0, 0, 0), stroke = Colour(0, 0, 0);
        float lineWidth = 1, miterLimit = 10, dashOffset = 0, alpha = 1;
        StrokeLineCap cap = StrokeLineCap.square;
        StrokeLineJoin join = StrokeLineJoin.miter;
        float[] dashes;
        BlendMode blend;
        FillRule fillRule;
        Font font;
        TextAlignment textAlign;
        TextBaseline textBaseline = TextBaseline.baseline;
        bool smooth = true;
        Clip[] clips; // appended to, never changed, so a saved state can share them
    }

    Canvas _canvas;
    State s;
    State[] saved;
    // The path, its points transformed as they were added, as JavaFX's are
    Tvg_Path_Command[] cmds;
    Tvg_Point[] pts;

    Tvg_Point at(float x, float y)
    {
        float tx, ty;
        apply(s.m, x, y, tx, ty);
        return Tvg_Point(tx, ty);
    }

    void startIfEmpty(float x, float y)
    {
        if (!cmds.length)
            moveTo(x, y);
    }

    Tvg_Paint pathShape()
    {
        auto p = tvg_shape_new();
        tvg_shape_append_path(p, cmds.ptr, cast(uint) cmds.length, pts.ptr, cast(uint) pts.length);
        return p;
    }

    Tvg_Paint polyline(const float[] xs, const float[] ys, bool close)
    {
        auto p = tvg_shape_new();
        const n = xs.length < ys.length ? xs.length : ys.length;
        foreach (i; 0 .. n)
        {
            if (i == 0)
                tvg_shape_move_to(p, xs[i], ys[i]);
            else
                tvg_shape_line_to(p, xs[i], ys[i]);
        }
        if (close && n)
            tvg_shape_close(p);
        return p;
    }

    GraphicsContext filled(Tvg_Paint p)
    {
        tvg_shape_set_fill_color(p, s.fill.r, s.fill.g, s.fill.b, s.fill.a);
        return transformed(p);
    }

    GraphicsContext stroked(Tvg_Paint p)
    {
        strokeStyle(p, 1);
        return transformed(p);
    }

    GraphicsContext transformed(Tvg_Paint p)
    {
        tvg_paint_set_transform(p, &s.m);
        emit(p);
        return this;
    }

    void strokeStyle(Tvg_Paint p, float widthScale)
    {
        tvg_shape_set_stroke_width(p, s.lineWidth * widthScale);
        tvg_shape_set_stroke_color(p, s.stroke.r, s.stroke.g, s.stroke.b, s.stroke.a);
        tvg_shape_set_stroke_cap(p, [TVG_STROKE_CAP_BUTT, TVG_STROKE_CAP_ROUND, TVG_STROKE_CAP_SQUARE][s.cap]);
        tvg_shape_set_stroke_join(p, [TVG_STROKE_JOIN_MITER, TVG_STROKE_JOIN_BEVEL, TVG_STROKE_JOIN_ROUND][s.join]);
        tvg_shape_set_stroke_miterlimit(p, s.miterLimit);
        if (s.dashes.length)
        {
            auto scaled = new float[s.dashes.length];
            foreach (i, d; s.dashes)
                scaled[i] = d * widthScale;
            tvg_shape_set_stroke_dash(p, scaled.ptr, cast(uint) scaled.length, s.dashOffset * widthScale);
        }
    }

    Tvg_Paint textShape(string text, float x, float y)
    {
        auto f = font();
        auto paragraph = Paragraph(f, text);
        const lines = paragraph.lines(float.infinity);
        const lineHeight = paragraph.lineHeight, ascender = paragraph.ascender;
        const total = lines.length * lineHeight;
        float first; // the first line's baseline
        final switch (s.textBaseline)
        {
            case TextBaseline.top: first = y + ascender; break;
            case TextBaseline.centre: first = y - total / 2 + ascender; break;
            case TextBaseline.baseline: first = y; break;
            case TextBaseline.bottom: first = y - total + ascender; break;
        }
        // Glyphs are hinted for the pixels they'll land on
        const hint = _canvas.targetScale * sqrt(abs(s.m.e11 * s.m.e22 - s.m.e12 * s.m.e21));
        auto p = tvg_shape_new();
        foreach (i, ref line; lines)
        {
            float lx = x;
            if (s.textAlign == TextAlignment.centre)
                lx -= line.width / 2;
            else if (s.textAlign == TextAlignment.right)
                lx -= line.width;
            paragraph.emitLine(p, line, lx, first + i * lineHeight, hint > 0 ? hint : 1);
        }
        return p;
    }

    Tvg_Paint picture(Image image, out float w, out float h)
    {
        if (!image || image.error)
            return null;
        auto p = tvg_picture_new();
        if (tvg_picture_load_data(p, image.dataPointer, image.dataLength, image.mimeType, image.resourcePath,
                                  image.copyOnLoad) != TVG_RESULT_SUCCESS)
        {
            tvg_paint_rel(p);
            return null;
        }
        tvg_picture_get_size(p, &w, &h);
        tvg_picture_set_filter(p, s.smooth ? TVG_FILTER_METHOD_BILINEAR : TVG_FILTER_METHOD_NEAREST);
        return p;
    }

    /// Draws the picture's (sx, sy, sw, sh) into (dx, dy, dw, dh), cut to that.
    void place(Tvg_Paint p, float sx, float sy, float sw, float sh, float dx, float dy, float dw, float dh)
    {
        if (sw <= 0 || sh <= 0)
        {
            tvg_paint_rel(p);
            return;
        }
        const kx = dw / sw, ky = dh / sh;
        auto m = multiply(s.m, Tvg_Matrix(kx, 0, dx - sx * kx, 0, ky, dy - sy * ky, 0, 0, 1));
        tvg_paint_set_transform(p, &m);
        // Cut to the destination, in a scene of its own so it's the only clip on it
        auto holder = tvg_scene_new();
        tvg_scene_add(holder, p);
        auto cut = tvg_shape_new();
        tvg_shape_append_rect(cut, dx, dy, dw, dh, 0, 0, true);
        tvg_paint_set_transform(cut, &s.m);
        tvg_paint_set_clip(holder, cut);
        emit(holder);
    }

    /// Hands `p` to the canvas, inside every clip, with the alpha and blend mode.
    void emit(Tvg_Paint p)
    {
        foreach_reverse (ref c; s.clips)
        {
            auto scene = tvg_scene_new();
            tvg_scene_add(scene, p);
            auto clipper = tvg_shape_new();
            tvg_shape_append_path(clipper, c.cmds.ptr, cast(uint) c.cmds.length, c.pts.ptr, cast(uint) c.pts.length);
            tvg_shape_set_fill_color(clipper, 0, 0, 0, 255);
            tvg_shape_set_fill_rule(clipper, c.rule == FillRule.evenOdd ? TVG_FILL_RULE_EVEN_ODD : TVG_FILL_RULE_NON_ZERO);
            tvg_paint_set_clip(scene, clipper);
            p = scene;
        }
        if (s.alpha < 1)
            tvg_paint_set_opacity(p, cast(ubyte)(s.alpha * 255 + 0.5f));
        if (s.blend != BlendMode.srcOver)
            tvg_paint_set_blend_method(p, blendMethods[s.blend]);
        _canvas.draw(p);
    }
}

private:

immutable Tvg_Blend_Method[] blendMethods = [
    TVG_BLEND_METHOD_NORMAL, TVG_BLEND_METHOD_MULTIPLY, TVG_BLEND_METHOD_SCREEN, TVG_BLEND_METHOD_OVERLAY,
    TVG_BLEND_METHOD_DARKEN, TVG_BLEND_METHOD_LIGHTEN, TVG_BLEND_METHOD_COLORDODGE, TVG_BLEND_METHOD_COLORBURN,
    TVG_BLEND_METHOD_HARDLIGHT, TVG_BLEND_METHOD_SOFTLIGHT, TVG_BLEND_METHOD_DIFFERENCE,
    TVG_BLEND_METHOD_EXCLUSION, TVG_BLEND_METHOD_ADD,
];

Tvg_Matrix multiply(const Tvg_Matrix a, const Tvg_Matrix b) pure nothrow @nogc @safe
{
    return Tvg_Matrix(
        a.e11 * b.e11 + a.e12 * b.e21, a.e11 * b.e12 + a.e12 * b.e22, a.e11 * b.e13 + a.e12 * b.e23 + a.e13,
        a.e21 * b.e11 + a.e22 * b.e21, a.e21 * b.e12 + a.e22 * b.e22, a.e21 * b.e13 + a.e22 * b.e23 + a.e23,
        0, 0, 1);
}

void apply(const Tvg_Matrix m, float x, float y, out float tx, out float ty) pure nothrow @nogc @safe
{
    tx = m.e11 * x + m.e12 * y + m.e13;
    ty = m.e21 * x + m.e22 * y + m.e23;
}

Colour unpremultiply(uint argb) pure nothrow @nogc @safe
{
    const a = argb >> 24;
    if (!a)
        return Colour(0, 0, 0, 0);
    ubyte channel(uint shift) { return cast(ubyte)((((argb >> shift) & 0xff) * 255 + a / 2) / a); }
    return Colour(channel(16), channel(8), channel(0), cast(ubyte) a);
}

/// A PNG file of premultiplied ARGB pixels: 8-bit RGBA, unfiltered, zlib-compressed by Phobos.
ubyte[] encodePng(const uint[] pixels, uint w, uint h)
{
    import std.bitmanip : nativeToBigEndian;
    import std.digest.crc : crc32Of;
    import std.zlib : compress;

    auto raw = new ubyte[(w * 4 + 1) * h];
    size_t i;
    foreach (y; 0 .. h)
    {
        raw[i++] = 0; // no filter
        foreach (x; 0 .. w)
        {
            const c = unpremultiply(pixels[y * w + x]);
            raw[i .. i + 4] = [c.r, c.g, c.b, c.a];
            i += 4;
        }
    }

    ubyte[] png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'];
    void chunk(string type, const ubyte[] data)
    {
        png ~= nativeToBigEndian(cast(uint) data.length);
        auto body = cast(const(ubyte)[]) type ~ data;
        png ~= body;
        auto crc = crc32Of(body); // little-endian bytes, as std.digest gives it
        png ~= [crc[3], crc[2], crc[1], crc[0]];
    }
    chunk("IHDR", nativeToBigEndian(w) ~ nativeToBigEndian(h) ~ cast(ubyte[])[8, 6, 0, 0, 0]);
    chunk("IDAT", compress(raw, 6));
    chunk("IEND", null);
    return png;
}

/// Yoga measuring a canvas: its size, whatever room there is.
extern(C) YGSize measureCanvas(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                               float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(Canvas) YGNodeGetContext(node);
    return self ? YGSize(self._width, self._height) : YGSize(0, 0);
}

unittest
{
    // A PNG starts with its signature, and colours come back from premultiplied ARGB
    const png = encodePng([0xff_ff_00_00, 0x80_00_00_80], 2, 1);
    assert(png[0 .. 8] == [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']);
    assert(unpremultiply(0x80_00_00_80) == Colour(0, 0, 255, 128));
    assert(unpremultiply(0) == Colour(0, 0, 0, 0));

    auto m = multiply(Tvg_Matrix(2, 0, 10, 0, 2, 20, 0, 0, 1), Tvg_Matrix(1, 0, 5, 0, 1, 5, 0, 0, 1));
    float x, y;
    apply(m, 1, 1, x, y);
    assert(x == 22 && y == 32, "scale after translate: (1+5)*2+10, (1+5)*2+20");
}
