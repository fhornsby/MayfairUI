module mayfair.pdf.annotation;

/*
    Annotations: what's marked on a page over its content -- highlights, notes, shapes, drawing,
    text boxes, signatures -- as Mayfair has them, in a page's shown points (from its top left, its
    own /Rotate applied), whatever PDF's own coordinates are.

    An engine reads every annotation a page has, of whatever kind, so it can be listed, moved and
    deleted. Those Mayfair made (`ours`) carry a description of themselves in the PDF -- see
    encodeData -- so everything about them can be changed again; another app's are drawn as that
    app made them, and can be moved and deleted, but not restyled. Form fields are annotations
    too (`widget`), listed so a view knows where they are; they're changed by filling them in.

    The shapes' outlines are made here, by shapePath, for an engine to write and a view to draw
    the same while they're being drawn.
*/

import std.math : atan2, cos, PI, sin, sqrt;
import mayfair.pdf.types;

/// A colour, 0 to 255 a channel, straight alpha: 0 alpha is none.
struct PdfColour
{
    ubyte r, g, b, a = 255;

    bool none() const nothrow @nogc pure { return a == 0; }

    /// As "#rrggbbaa".
    string toHex() const pure
    {
        import std.format : format;
        return format!"#%02x%02x%02x%02x"(r, g, b, a);
    }

    /// From "#rrggbb" or "#rrggbbaa"; `fallback` if it isn't one.
    static PdfColour fromHex(const(char)[] s, PdfColour fallback = PdfColour.init) pure
    {
        import std.conv : to;
        if (s.length && s[0] == '#')
            s = s[1 .. $];
        if (s.length != 6 && s.length != 8)
            return fallback;
        try
        {
            PdfColour c;
            c.r = s[0 .. 2].to!ubyte(16);
            c.g = s[2 .. 4].to!ubyte(16);
            c.b = s[4 .. 6].to!ubyte(16);
            c.a = s.length == 8 ? s[6 .. 8].to!ubyte(16) : 255;
            return c;
        }
        catch (Exception)
            return fallback;
    }
}

/// A point, in a page's shown points.
struct PdfPoint
{
    float x = 0, y = 0;
}

/// What an annotation is.
enum PdfAnnotationKind
{
    other,          /// Another app's, of a kind this doesn't make: shown, moved and deleted, not changed
    highlight,      /// Text marked, as with a highlighter: `lines` are where
    underline,      /// ditto, underlined
    strikeOut,      /// ditto, struck through
    squiggly,       /// ditto, a wavy line under it
    note,           /// A sticky note: an icon at `rect`, with `text`
    textBox,        /// `text`, in `rect`, in `fontSize` points of `colour`, on `fill` if it has one
    rectangle,      /// Drawn round `rect`: `colour`, `lineWidth`, `fill`
    roundedRectangle, /// ditto, with rounded corners
    oval,           /// ditto, an ellipse
    line,           /// From strokes[0][0] to strokes[0][1]
    arrow,          /// ditto, with a head at the end
    star,           /// A five-pointed star filling `rect`
    speechBubble,   /// A rounded box with a tail, at its bottom left
    ink,            /// Drawn freehand: `strokes`
    signature,      /// A signature: strokes, as ink, placed
    widget,         /// A form field: filled in, not changed as an annotation
}

/// An annotation on a page.
struct PdfAnnotation
{
    PdfAnnotationKind kind;
    int index = -1;            /// Where it is among the page's annotations, as the engine read it
    PdfRect rect;              /// What it covers
    PdfColour colour = PdfColour(0, 0, 0, 255);  /// Its line, its text, its highlight
    PdfColour fill = PdfColour(0, 0, 0, 0);      /// Inside it, if anything
    float lineWidth = 2;
    PdfRect[] lines;           /// Text marked: a rectangle a line
    PdfPoint[][] strokes;      /// Ink and signatures: each stroke; lines and arrows: [[from, to]]
    string text;               /// A note's or text box's; for marked text, what's marked
    float fontSize = 14;
    string author;             /// Who made it, if it says
    string modified;           /// When, as the PDF has it ("D:20261124093000"), if it says
    bool ours;                 /// Made by Mayfair: everything about it can be changed
    int fieldType = -1;        /// A widget's: the engine's field type

    /// Whether it marks text.
    bool marksText() const nothrow @nogc pure
    {
        with (PdfAnnotationKind)
            return kind == highlight || kind == underline || kind == strikeOut || kind == squiggly;
    }

    /// Whether it's drawn from its strokes.
    bool stroked() const nothrow @nogc pure
    {
        with (PdfAnnotationKind)
            return kind == ink || kind == signature || kind == line || kind == arrow;
    }

    /// Whether it can be moved and deleted as an annotation: everything but form fields.
    bool movable() const nothrow @nogc pure { return kind != PdfAnnotationKind.widget; }

    /// What it covers, worked out from what it's made of, with room for its line.
    PdfRect bounds() const pure
    {
        PdfRect r;
        if (marksText)
            foreach (l; lines)
                r = r.union_(l);
        else if (stroked)
        {
            float l = float.max, t = float.max, rt = -float.max, b = -float.max;
            foreach (s; strokes)
                foreach (p; s)
                {
                    if (p.x < l) l = p.x;
                    if (p.y < t) t = p.y;
                    if (p.x > rt) rt = p.x;
                    if (p.y > b) b = p.y;
                }
            if (l <= rt)
            {
                const pad = kind == PdfAnnotationKind.arrow ? arrowHead(lineWidth) : lineWidth / 2 + 1;
                r = PdfRect(l - pad, t - pad, rt - l + 2 * pad, b - t + 2 * pad);
            }
        }
        return r.empty ? rect : r;
    }

    /// It, moved by `dx`, `dy`.
    PdfAnnotation movedBy(float dx, float dy) const
    {
        auto a = copy();
        a.rect = PdfRect(rect.x + dx, rect.y + dy, rect.width, rect.height);
        foreach (ref l; a.lines)
            l = PdfRect(l.x + dx, l.y + dy, l.width, l.height);
        foreach (ref s; a.strokes)
            foreach (ref p; s)
                p = PdfPoint(p.x + dx, p.y + dy);
        return a;
    }

    /// It, stretched from `rect` to `to`: its strokes with it.
    PdfAnnotation fittedTo(PdfRect to) const
    {
        auto a = copy();
        const from = rect;
        const sx = from.width > 0 ? to.width / from.width : 1, sy = from.height > 0 ? to.height / from.height : 1;
        a.rect = to;
        foreach (ref s; a.strokes)
            foreach (ref p; s)
                p = PdfPoint(to.x + (p.x - from.x) * sx, to.y + (p.y - from.y) * sy);
        foreach (ref l; a.lines)
            l = PdfRect(to.x + (l.x - from.x) * sx, to.y + (l.y - from.y) * sy, l.width * sx, l.height * sy);
        return a;
    }

    /// A copy with its own arrays.
    PdfAnnotation copy() const
    {
        PdfAnnotation a;
        a.kind = kind;
        a.index = index;
        a.rect = rect;
        a.colour = colour;
        a.fill = fill;
        a.lineWidth = lineWidth;
        a.lines = lines.dup;
        foreach (s; strokes)
            a.strokes ~= s.dup;
        a.text = text;
        a.fontSize = fontSize;
        a.author = author;
        a.modified = modified;
        a.ours = ours;
        a.fieldType = fieldType;
        return a;
    }
}

/// A page's annotations, as kept: a class, so "not read yet" (null) and "none" differ.
final class PdfAnnotations
{
    PdfAnnotation[] list;
    this(PdfAnnotation[] list) { this.list = list; }

    /// The topmost annotation at `x`, `y`, that `wanted` accepts, or null. A line's within a few points of it.
    const(PdfAnnotation)* at(float x, float y, bool delegate(ref const PdfAnnotation) wanted = null) const
    {
        foreach_reverse (ref a; list)
        {
            if (wanted && !wanted(a))
                continue;
            if (hits(a, x, y))
                return &a;
        }
        return null;
    }

    private static bool hits(ref const PdfAnnotation a, float x, float y)
    {
        with (PdfAnnotationKind) switch (a.kind)
        {
            case highlight, underline, strikeOut, squiggly:
                foreach (l; a.lines)
                    if (l.contains(x, y))
                        return true;
                return false;
            case line, arrow, ink, signature:
                if (a.kind == signature && a.rect.contains(x, y))
                    return true;
                const reach = a.lineWidth / 2 + 4;
                foreach (s; a.strokes)
                {
                    if (s.length == 1 && distance(s[0], PdfPoint(x, y)) <= reach)
                        return true;
                    foreach (i; 1 .. s.length)
                        if (segmentDistance(s[i - 1], s[i], PdfPoint(x, y)) <= reach)
                            return true;
                }
                return false;
            default:
                return a.rect.contains(x, y);
        }
    }
}

/// How far `p` is from `q`.
float distance(PdfPoint p, PdfPoint q) pure nothrow @nogc
{
    return sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y));
}

/// How far `p` is from the segment from `a` to `b`.
float segmentDistance(PdfPoint a, PdfPoint b, PdfPoint p) pure nothrow @nogc
{
    const dx = b.x - a.x, dy = b.y - a.y;
    const length2 = dx * dx + dy * dy;
    if (length2 <= 0)
        return distance(a, p);
    float t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    return distance(PdfPoint(a.x + t * dx, a.y + t * dy), p);
}

/// How long an arrow's head is, for a line `width` wide.
float arrowHead(float width) pure nothrow @nogc { return 6 + width * 3; }

/// A step of an outline.
struct PdfPathOp
{
    enum Kind { moveTo, lineTo, cubicTo, close }
    Kind kind;
    PdfPoint[3] points; /// lineTo and moveTo: the first; cubicTo: two controls, then the end
}

/// An outline to draw, and how.
struct PdfShape
{
    PdfPathOp[] ops;
    bool filled;     /// Filled with the annotation's fill -- or, for an arrow's head, its colour
    bool stroked;    /// Its outline drawn, in its colour, lineWidth wide
    bool fillWithColour; /// Filled with its colour, not its fill: an arrow's head
}

/*
    The outlines a shape annotation's drawn with, in shown points: a rectangle's, a star's, an
    arrow's line and its head. Empty for kinds that aren't shapes drawn this way (text marks,
    notes, text boxes, ink).
*/
PdfShape[] shapePath(const ref PdfAnnotation a)
{
    PdfShape[] shapes;
    const r = a.rect;
    const hasFill = !a.fill.none;
    PdfPathOp move(float x, float y) { return PdfPathOp(PdfPathOp.Kind.moveTo, [PdfPoint(x, y), PdfPoint.init, PdfPoint.init]); }
    PdfPathOp lineTo(float x, float y) { return PdfPathOp(PdfPathOp.Kind.lineTo, [PdfPoint(x, y), PdfPoint.init, PdfPoint.init]); }
    PdfPathOp curve(float x1, float y1, float x2, float y2, float x, float y)
    {
        return PdfPathOp(PdfPathOp.Kind.cubicTo, [PdfPoint(x1, y1), PdfPoint(x2, y2), PdfPoint(x, y)]);
    }
    PdfPathOp close() { return PdfPathOp(PdfPathOp.Kind.close); }

    // Inset by half the line, so the line's inside `rect`
    const inset = a.lineWidth / 2;
    const x0 = r.x + inset, y0 = r.y + inset, x1 = r.right - inset, y1 = r.bottom - inset;
    enum k = 0.5523f; // a quarter circle, as a cubic

    PdfPathOp[] roundRect(float l, float t, float rt, float b, float radius)
    {
        const rad = radius * 2 > rt - l ? (rt - l) / 2 : radius * 2 > b - t ? (b - t) / 2 : radius;
        const c = rad * (1 - k);
        return [move(l + rad, t), lineTo(rt - rad, t), curve(rt - c, t, rt, t + c, rt, t + rad),
                lineTo(rt, b - rad), curve(rt, b - c, rt - c, b, rt - rad, b),
                lineTo(l + rad, b), curve(l + c, b, l, b - c, l, b - rad),
                lineTo(l, t + rad), curve(l, t + c, l + c, t, l + rad, t), close()];
    }

    with (PdfAnnotationKind) switch (a.kind)
    {
        case rectangle:
            shapes ~= PdfShape([move(x0, y0), lineTo(x1, y0), lineTo(x1, y1), lineTo(x0, y1), close()], hasFill, true);
            break;
        case roundedRectangle:
            shapes ~= PdfShape(roundRect(x0, y0, x1, y1, 10 + a.lineWidth), hasFill, true);
            break;
        case oval:
        {
            const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = (x1 - x0) / 2, ry = (y1 - y0) / 2;
            shapes ~= PdfShape([move(cx + rx, cy),
                                curve(cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry),
                                curve(cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy),
                                curve(cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry),
                                curve(cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy), close()], hasFill, true);
            break;
        }
        case star:
        {
            const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2 + (y1 - y0) * 0.05f;
            const rx = (x1 - x0) / 2, ry = (y1 - y0) / 2;
            PdfPathOp[] ops;
            foreach (i; 0 .. 10)
            {
                const angle = -PI / 2 + i * PI / 5;
                const f = i % 2 ? 0.4f : 1;
                const px = cx + cos(angle) * rx * f, py = cy + sin(angle) * ry * f * 1.05f;
                ops ~= i ? lineTo(px, py) : move(px, py);
            }
            ops ~= close();
            shapes ~= PdfShape(ops, hasFill, true);
            break;
        }
        case speechBubble:
        {
            // A rounded box, its tail out of its bottom edge near the left: one outline
            const bottom = y1 - (y1 - y0) * 0.25f;
            const w = x1 - x0;
            const rad0 = 12f;
            const rad = rad0 * 2 > w ? w / 2 : rad0 * 2 > bottom - y0 ? (bottom - y0) / 2 : rad0;
            const c = rad * (1 - k);
            const tailLeft = x0 + w * 0.2f, tailTip = x0 + w * 0.12f, tailRight = x0 + w * 0.38f;
            shapes ~= PdfShape([move(x0 + rad, y0), lineTo(x1 - rad, y0), curve(x1 - c, y0, x1, y0 + c, x1, y0 + rad),
                                lineTo(x1, bottom - rad), curve(x1, bottom - c, x1 - c, bottom, x1 - rad, bottom),
                                lineTo(tailRight, bottom), lineTo(tailTip, y1), lineTo(tailLeft, bottom),
                                lineTo(x0 + rad, bottom), curve(x0 + c, bottom, x0, bottom - c, x0, bottom - rad),
                                lineTo(x0, y0 + rad), curve(x0, y0 + c, x0 + c, y0, x0 + rad, y0), close()],
                               hasFill, true);
            break;
        }
        case line, arrow:
        {
            if (!a.strokes.length || a.strokes[0].length < 2)
                break;
            auto from = a.strokes[0][0], to = a.strokes[0][$ - 1];
            if (a.kind == arrow)
            {
                const head = arrowHead(a.lineWidth);
                const angle = atan2(to.y - from.y, to.x - from.x);
                const length = distance(from, to);
                // The line stops short of the tip, under the head
                const shaft = length > head * 0.8f ? head * 0.8f : length;
                const ex = to.x - cos(angle) * shaft, ey = to.y - sin(angle) * shaft;
                shapes ~= PdfShape([move(from.x, from.y), lineTo(ex, ey)], false, true);
                const spread = 0.45f;
                shapes ~= PdfShape([move(to.x, to.y),
                                    lineTo(to.x - cos(angle - spread) * head, to.y - sin(angle - spread) * head),
                                    lineTo(to.x - cos(angle + spread) * head, to.y - sin(angle + spread) * head),
                                    close()], true, false, true);
            }
            else
                shapes ~= PdfShape([move(from.x, from.y), lineTo(to.x, to.y)], false, true);
            break;
        }
        default:
            break;
    }
    return shapes;
}

/// Whether annotations of `kind` are drawn by shapePath.
bool isShape(PdfAnnotationKind kind) pure nothrow @nogc
{
    with (PdfAnnotationKind)
        return kind == rectangle || kind == roundedRectangle || kind == oval || kind == star || kind == speechBubble
            || kind == line || kind == arrow;
}

/*
    What an annotation Mayfair made says about itself, kept in it in the PDF (as "MayfairData", a
    key other readers ignore): its kind, colours, line and text size, and -- for those drawn from
    them -- its strokes, in the PDF's own coordinates, so turning the page doesn't change them.
    `toPdf` turns shown points into the PDF's.

        v1|arrow|#ff0000ff|#00000000|2|14|x y x y;x y x y
*/
string encodeData(const ref PdfAnnotation a, PdfPoint delegate(PdfPoint) toPdf)
{
    import std.array : appender;
    import std.conv : to;
    import std.format : format;
    auto o = appender!string;
    o ~= "v1|";
    o ~= a.kind.to!string;
    o ~= "|";
    o ~= a.colour.toHex;
    o ~= "|";
    o ~= a.fill.toHex;
    o ~= format!"|%g|%g|"(a.lineWidth, a.fontSize);
    foreach (i, s; a.strokes)
    {
        if (i)
            o ~= ";";
        foreach (j, p; s)
        {
            const q = toPdf(p);
            o ~= format!"%s%.2f %.2f"(j ? " " : "", q.x, q.y);
        }
    }
    return o[];
}

/// The annotation `data` describes -- kind, colours, sizes, strokes -- or false if it doesn't
/// describe one. `toShown` turns the PDF's points into shown ones.
bool decodeData(string data, ref PdfAnnotation a, PdfPoint delegate(PdfPoint) toShown)
{
    import std.algorithm : splitter;
    import std.array : array, split;
    import std.conv : to;
    auto parts = data.split("|");
    if (parts.length < 6 || parts[0] != "v1")
        return false;
    try
    {
        a.kind = parts[1].to!PdfAnnotationKind;
        a.colour = PdfColour.fromHex(parts[2], a.colour);
        a.fill = PdfColour.fromHex(parts[3], a.fill);
        a.lineWidth = parts[4].to!float;
        a.fontSize = parts[5].to!float;
        a.strokes = null;
        if (parts.length > 6 && parts[6].length)
            foreach (s; parts[6].splitter(";"))
            {
                auto numbers = s.split(" ");
                PdfPoint[] stroke;
                for (size_t i = 0; i + 1 < numbers.length; i += 2)
                    stroke ~= toShown(PdfPoint(numbers[i].to!float, numbers[i + 1].to!float));
                a.strokes ~= stroke;
            }
        a.ours = true;
        return true;
    }
    catch (Exception)
        return false;
}

unittest
{
    PdfAnnotation a;
    a.kind = PdfAnnotationKind.arrow;
    a.colour = PdfColour(255, 0, 0);
    a.lineWidth = 3;
    a.strokes = [[PdfPoint(10, 20), PdfPoint(110, 220)]];
    // A page 800 tall, upside down in the PDF
    const data = encodeData(a, (PdfPoint p) => PdfPoint(p.x, 800 - p.y));
    PdfAnnotation b;
    assert(decodeData(data, b, (PdfPoint p) => PdfPoint(p.x, 800 - p.y)));
    assert(b.kind == PdfAnnotationKind.arrow && b.colour == a.colour && b.lineWidth == 3 && b.ours);
    assert(b.strokes.length == 1 && b.strokes[0][1].x == 110 && b.strokes[0][1].y == 220);
    assert(!decodeData("nonsense", b, null));
    assert(PdfColour.fromHex("#11223344") == PdfColour(0x11, 0x22, 0x33, 0x44));
    assert(PdfColour(1, 2, 3, 4).toHex == "#01020304");

    // Hitting a line, and not beside it
    auto list = new PdfAnnotations([a]);
    assert(list.at(60, 120));
    assert(!list.at(60, 20));

    // Moving and fitting take the strokes along
    auto moved = a.movedBy(5, 5);
    assert(moved.strokes[0][0].x == 15 && a.strokes[0][0].x == 10);
    PdfAnnotation box;
    box.kind = PdfAnnotationKind.ink;
    box.rect = PdfRect(0, 0, 10, 10);
    box.strokes = [[PdfPoint(10, 10)]];
    assert(box.fittedTo(PdfRect(0, 0, 20, 40)).strokes[0][0] == PdfPoint(20, 40));

    // Shapes have outlines; an arrow a line and a head
    assert(shapePath(a).length == 2);
    box.kind = PdfAnnotationKind.star;
    assert(shapePath(box)[0].ops.length == 11);
}
