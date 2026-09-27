module mayfair.widgets.region;

import mayfair.renderers.thorvg;
import mayfair.theme : Colour;
import mayfair.widgets.widget : Insets;

/*
    What a widget draws behind what it holds, JavaFX's Region backgrounds and borders: layers of
    fill, and strokes over them, each with its own rounded corners and its own inset from the
    widget's edges. A stylesheet sets them with background-colour and border-colour and the
    rest, a layer for each comma-separated value:

        .button {
            background-colour: var(--focus), var(--base);  // a ring, and the button inside it
            background-insets: -2, 0;
            background-radius: 10, 8;
        }

    An inset can be negative, to draw outside the widget, as a focus ring does. Nothing here takes
    up room in the layout: that's padding's job.
*/
struct Background
{
    BackgroundFill[] fills;

    this(BackgroundFill[] fills...) pure nothrow @safe
    {
        this.fills = fills.dup;
    }
}

struct BackgroundFill
{
    Colour fill;
    CornerRadii radii;
    Insets insets;
}

struct Border
{
    BorderStroke[] strokes;

    this(BorderStroke[] strokes...) pure nothrow @safe
    {
        this.strokes = strokes.dup;
    }
}

/// A stroke all the way round, `width` points wide, inside the widget's edge less its insets.
struct BorderStroke
{
    Colour colour;
    float width = 1;
    CornerRadii radii;
    Insets insets;
}

/// Each corner's radius, from the top left clockwise, as CSS gives them. JavaFX's CornerRadii.
struct CornerRadii
{
    float topLeft = 0, topRight = 0, bottomRight = 0, bottomLeft = 0;

    this(float all) pure nothrow @safe @nogc
    {
        topLeft = topRight = bottomRight = bottomLeft = all;
    }

    this(float topLeft, float topRight, float bottomRight, float bottomLeft) pure nothrow @safe @nogc
    {
        this.topLeft = topLeft;
        this.topRight = topRight;
        this.bottomRight = bottomRight;
        this.bottomLeft = bottomLeft;
    }

    /// Each smaller by `by`, and none below 0: the corners of something drawn inside these.
    CornerRadii less(float by) const pure nothrow @safe @nogc
    {
        static float l(float r, float by) { return r > by ? r - by : 0; }
        return CornerRadii(l(topLeft, by), l(topRight, by), l(bottomRight, by), l(bottomLeft, by));
    }
}

/// Appends a rectangle with corners rounded by `r` to `shape`: one ThorVG call when they're all
/// the same, which they nearly always are, and a path otherwise.
void appendRoundedRect(Tvg_Paint shape, float x, float y, float w, float h, CornerRadii r) nothrow @nogc
{
    if (w <= 0 || h <= 0)
        return;
    // No corner more than half the shorter side, or they'd overlap
    const most = (w < h ? w : h) / 2;
    static float cap(float v, float most) { return v < 0 ? 0 : v > most ? most : v; }
    const tl = cap(r.topLeft, most), tr = cap(r.topRight, most), br = cap(r.bottomRight, most), bl = cap(r.bottomLeft, most);
    if (tl == tr && tr == br && br == bl)
    {
        tvg_shape_append_rect(shape, x, y, w, h, tl, tl, true);
        return;
    }
    // A quarter circle as a cubic: the control points sit this far along the tangents
    enum k = 0.5522848f;
    tvg_shape_move_to(shape, x + tl, y);
    tvg_shape_line_to(shape, x + w - tr, y);
    tvg_shape_cubic_to(shape, x + w - tr + tr * k, y, x + w, y + tr - tr * k, x + w, y + tr);
    tvg_shape_line_to(shape, x + w, y + h - br);
    tvg_shape_cubic_to(shape, x + w, y + h - br + br * k, x + w - br + br * k, y + h, x + w - br, y + h);
    tvg_shape_line_to(shape, x + bl, y + h);
    tvg_shape_cubic_to(shape, x + bl - bl * k, y + h, x, y + h - bl + bl * k, x, y + h - bl);
    tvg_shape_line_to(shape, x, y + tl);
    tvg_shape_cubic_to(shape, x, y + tl - tl * k, x + tl - tl * k, y, x + tl, y);
    tvg_shape_close(shape);
}

/*
    An SVG path, as JavaFX's shape takes one: a region's background drawn as this outline,
    stretched to fill it, instead of a rectangle. How a check box's tick is drawn.

        .check-box:selected > .box > .mark { shape: "M0,5 L4,9 L12,0 L13,1 L4,11 L-1,6Z"; }

    Parsed once, when it's set, into ThorVG's own commands; drawing it at a size is arithmetic.
    Every command but arcs (A): moves, lines, H and V, cubic and quadratic curves and their
    smooth forms, absolute and relative.
*/
struct SvgPath
{
    Tvg_Path_Command[] commands;
    Tvg_Point[] points;
    float minX = 0, minY = 0, maxX = 0, maxY = 0; /// Its bounds, control points included

    bool empty() const nothrow @nogc { return commands.length == 0; }

    /// Parses `d`, an SVG path's data. Throws for what isn't one.
    static SvgPath parse(string d)
    {
        SvgPath path;
        size_t at;
        char command = 0;
        float cx = 0, cy = 0;          // the current point
        float sx = 0, sy = 0;          // where the sub-path started, for Z
        float lastCx = 0, lastCy = 0;  // the last control point, for S and T
        char previous = 0;

        void skip()
        {
            while (at < d.length && (d[at] == ' ' || d[at] == ',' || d[at] == '\n' || d[at] == '\t' || d[at] == '\r'))
                at++;
        }
        bool numberNext()
        {
            skip();
            return at < d.length && (d[at] == '-' || d[at] == '+' || d[at] == '.' || (d[at] >= '0' && d[at] <= '9'));
        }
        float number()
        {
            import std.conv : to;
            skip();
            const start = at;
            if (at < d.length && (d[at] == '-' || d[at] == '+'))
                at++;
            bool dot;
            while (at < d.length && ((d[at] >= '0' && d[at] <= '9') || (d[at] == '.' && !dot)))
            {
                if (d[at] == '.')
                    dot = true;
                at++;
            }
            if (at < d.length && (d[at] == 'e' || d[at] == 'E'))
            {
                at++;
                if (at < d.length && (d[at] == '-' || d[at] == '+'))
                    at++;
                while (at < d.length && d[at] >= '0' && d[at] <= '9')
                    at++;
            }
            if (at == start)
                throw new Exception("SVG path: expected a number at " ~ to!string(start));
            return d[start .. at].to!float;
        }
        void add(Tvg_Path_Command c, float[] xy...)
        {
            path.commands ~= c;
            for (size_t i = 0; i + 1 < xy.length; i += 2)
                path.points ~= Tvg_Point(xy[i], xy[i + 1]);
        }

        while (true)
        {
            skip();
            if (at >= d.length)
                break;
            const c = d[at];
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
            {
                command = c;
                at++;
            }
            else if (!command)
                throw new Exception("SVG path: expected a command");
            const relative = command >= 'a';
            const ox = relative ? cx : 0, oy = relative ? cy : 0;
            switch (command | 0x20)
            {
                case 'm':
                    cx = ox + number(); cy = oy + number();
                    sx = cx; sy = cy;
                    add(TVG_PATH_COMMAND_MOVE_TO, cx, cy);
                    command = relative ? 'l' : 'L'; // numbers after a move are lines
                    break;
                case 'l':
                    cx = ox + number(); cy = oy + number();
                    add(TVG_PATH_COMMAND_LINE_TO, cx, cy);
                    break;
                case 'h':
                    cx = ox + number();
                    add(TVG_PATH_COMMAND_LINE_TO, cx, cy);
                    break;
                case 'v':
                    cy = oy + number();
                    add(TVG_PATH_COMMAND_LINE_TO, cx, cy);
                    break;
                case 'c':
                    const x1 = ox + number(), y1 = oy + number(), x2 = ox + number(), y2 = oy + number();
                    cx = ox + number(); cy = oy + number();
                    add(TVG_PATH_COMMAND_CUBIC_TO, x1, y1, x2, y2, cx, cy);
                    lastCx = x2; lastCy = y2;
                    break;
                case 's':
                    // The first control point mirrors the last curve's second, if there was one
                    const smooth = (previous | 0x20) == 'c' || (previous | 0x20) == 's';
                    const x1 = smooth ? 2 * cx - lastCx : cx, y1 = smooth ? 2 * cy - lastCy : cy;
                    const x2 = ox + number(), y2 = oy + number();
                    cx = ox + number(); cy = oy + number();
                    add(TVG_PATH_COMMAND_CUBIC_TO, x1, y1, x2, y2, cx, cy);
                    lastCx = x2; lastCy = y2;
                    break;
                case 'q', 't':
                    float qx, qy;
                    if ((command | 0x20) == 'q')
                    {
                        qx = ox + number();
                        qy = oy + number();
                    }
                    else
                    {
                        const smooth = (previous | 0x20) == 'q' || (previous | 0x20) == 't';
                        qx = smooth ? 2 * cx - lastCx : cx;
                        qy = smooth ? 2 * cy - lastCy : cy;
                    }
                    const ex = ox + number(), ey = oy + number();
                    // A quadratic as the cubic it is: its control points two thirds of the way to the quadratic's
                    add(TVG_PATH_COMMAND_CUBIC_TO, cx + (qx - cx) * 2 / 3, cy + (qy - cy) * 2 / 3,
                        ex + (qx - ex) * 2 / 3, ey + (qy - ey) * 2 / 3, ex, ey);
                    lastCx = qx; lastCy = qy;
                    cx = ex; cy = ey;
                    break;
                case 'z':
                    add(TVG_PATH_COMMAND_CLOSE);
                    cx = sx; cy = sy;
                    break;
                case 'a':
                    throw new Exception("SVG path: arcs (A) aren't supported; use curves");
                default:
                    throw new Exception("SVG path: unknown command " ~ command);
            }
            previous = command;
            // A command's numbers can repeat without it; Z takes none, so a letter must follow
            if ((command | 0x20) == 'z' && numberNext())
                throw new Exception("SVG path: numbers after Z");
        }

        if (path.points.length)
        {
            path.minX = path.maxX = path.points[0].x;
            path.minY = path.maxY = path.points[0].y;
            foreach (p; path.points)
            {
                if (p.x < path.minX) path.minX = p.x;
                if (p.x > path.maxX) path.maxX = p.x;
                if (p.y < path.minY) path.minY = p.y;
                if (p.y > path.maxY) path.maxY = p.y;
            }
        }
        return path;
    }

    /// Appends it to `shape`, stretched to fill `w` x `h` at `x`, `y`. `scratch` is room for its
    /// points, as many as it has, so drawing it allocates nothing.
    void appendScaled(Tvg_Paint shape, float x, float y, float w, float h, Tvg_Point[] scratch) const nothrow @nogc
    {
        if (empty || w <= 0 || h <= 0 || scratch.length < points.length)
            return;
        const bw = maxX - minX, bh = maxY - minY;
        const kx = bw > 0 ? w / bw : 1, ky = bh > 0 ? h / bh : 1;
        foreach (i, p; points)
            scratch[i] = Tvg_Point(x + (p.x - minX) * kx, y + (p.y - minY) * ky);
        tvg_shape_append_path(shape, commands.ptr, cast(uint) commands.length, scratch.ptr, cast(uint) points.length);
    }
}

unittest
{
    auto tick = SvgPath.parse("M0,5 L4,9 l8-9 1,1 L4,11 z");
    assert(tick.commands == [TVG_PATH_COMMAND_MOVE_TO, TVG_PATH_COMMAND_LINE_TO, TVG_PATH_COMMAND_LINE_TO,
                             TVG_PATH_COMMAND_LINE_TO, TVG_PATH_COMMAND_LINE_TO, TVG_PATH_COMMAND_CLOSE]);
    assert(tick.points[2] == Tvg_Point(12, 0) && tick.points[3] == Tvg_Point(13, 1));
    assert(tick.minX == 0 && tick.maxX == 13 && tick.minY == 0 && tick.maxY == 11);

    auto curves = SvgPath.parse("M0 0C1 0 2 1 2 2S4 4 4 4Q5 5 6 4T8 4H10V-1z");
    assert(curves.commands.length == 8);
    assert(curves.points[4] == Tvg_Point(2, 3)); // S mirrors the last control point, (2, 1), about the current one, (2, 2)

    import std.exception : assertThrown;
    assertThrown(SvgPath.parse("M0 0 A5 5 0 0 1 10 10"));
    assertThrown(SvgPath.parse("5 5"));
}
