module mayfair.css.value;

import mayfair.theme : Colour;

/*
    What a CSS declaration says, as the parser leaves it.

    Literals are turned into what they mean as they're parsed -- `#38bdf8` into a Colour, `150ms`
    into a number with its unit -- so a stylesheet compiled in has nothing left to work out but
    what can't be known until it's applied: a variable like `var(--base)`, whose value depends
    on where in the tree it's used, and a function of one, like `derive(var(--base), 20%)`.

    It's a small tree of plain data, so a whole stylesheet can be built at compile time and live
    in the program as a constant.
*/
struct Value
{
    ValueKind kind;
    Unit unit;          /// For a number
    float number = 0;   /// For a number: as written, in its unit
    Colour colour;      /// For a colour
    string name;        /// An identifier, a string's text, or a function's name
    Value[] items;      /// A list's items, or a function's arguments

    /// A space-separated list's items, or this alone: so `8`, and `8 16`, both read as a list.
    const(Value)[] spaced() const pure nothrow @trusted return
    {
        return kind == ValueKind.list ? items : (&this)[0 .. 1];
    }

    /// A comma-separated list's items, or this alone: a background's layers, whether one or several.
    const(Value)[] layers() const pure nothrow @trusted return
    {
        return kind == ValueKind.commas ? items : (&this)[0 .. 1];
    }

    bool isIdentifier(string s) const pure nothrow @safe @nogc
    {
        return kind == ValueKind.identifier && name == s;
    }
}

enum ValueKind : ubyte
{
    number,
    colour,
    identifier, /// A keyword -- `center`, `bold` -- or a variable's name inside var(), like `--base`
    text,       /// A quoted string
    function_,  /// A call: `derive(var(--base), 20%)`, with the arguments as items
    list,       /// Values separated by spaces: `8 16`
    commas,     /// Values separated by commas: `red, blue`
}

/// A number's unit. JavaFX's sizes are px, which in Mayfair are points.
enum Unit : ubyte
{
    none,
    px,
    em,      /// Of the font size
    percent,
    pt,      /// 1/72 inch, as in JavaFX: 4/3 of a px
    ms,
    s,
    deg,
}

/// The number `v` in points, `em` being the font size for an em. A plain number counts as points.
float points(const Value v, float em) pure nothrow @safe @nogc
{
    final switch (v.unit)
    {
        case Unit.none, Unit.px, Unit.percent, Unit.ms, Unit.s, Unit.deg: return v.number;
        case Unit.em: return v.number * em;
        case Unit.pt: return v.number * 4 / 3;
    }
}

/// The number `v` in milliseconds, a plain number counting as milliseconds.
float milliseconds(const Value v) pure nothrow @safe @nogc
{
    return v.unit == Unit.s ? v.number * 1000 : v.number;
}

/*
    JavaFX's derive(): `c` made lighter by `brightness` (0 to 1) or darker by a negative one, in
    HSB space, with the adjustments JavaFX makes by how bright it already is -- so a stylesheet's
    derive() gives the same colours here as in JavaFX. This is com.sun.javafx.util.Utils.deriveColor.
*/
Colour derive(Colour c, double brightness) pure nothrow @safe @nogc
{
    import std.math : sqrt;
    const r = c.r / 255.0, g = c.g / 255.0, b = c.b / 255.0;
    const base = sqrt(r * r * 0.299 + g * g * 0.587 + b * b * 0.114);
    double k = brightness;
    if (brightness > 0)
    {
        if (base > 0.85)      k *= 1.6;
        else if (base > 0.6)  {}
        else if (base > 0.5)  k *= 0.9;
        else if (base > 0.4)  k *= 0.8;
        else if (base > 0.3)  k *= 0.7;
        else                  k *= 0.6;
    }
    else if (base < 0.2)
        k *= 0.6;
    if (k < -1) k = -1;
    if (k > 1) k = 1;

    double h, s, v;
    toHsb(r, g, b, h, s, v);
    if (k > 0)
    {
        s *= 1 - k;
        v += (1 - v) * k;
    }
    else
        v *= k + 1;
    if (s < 0) s = 0;
    if (s > 1) s = 1;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    auto result = fromHsb(cast(int) h, s, v); // JavaFX truncates the hue
    result.a = c.a;
    return result;
}

/// JavaFX's ladder(): the colour at `c`'s brightness along a gradient of `stops`.
Colour ladder(Colour c, const(Colour)[] stops, const(float)[] offsets) pure nothrow @safe @nogc
{
    import std.math : sqrt;
    if (!stops.length)
        return c;
    const r = c.r / 255.0, g = c.g / 255.0, b = c.b / 255.0;
    const brightness = sqrt(r * r * 0.299 + g * g * 0.587 + b * b * 0.114);
    if (brightness <= offsets[0])
        return stops[0];
    foreach (i; 1 .. stops.length)
    {
        if (brightness <= offsets[i])
        {
            const span = offsets[i] - offsets[i - 1];
            return stops[i - 1].interpolate(stops[i], span > 0 ? (brightness - offsets[i - 1]) / span : 1);
        }
    }
    return stops[$ - 1];
}

/// Hue in degrees, saturation and brightness from 0 to 1, as java.awt.Color.RGBtoHSB.
void toHsb(double r, double g, double b, out double h, out double s, out double v) pure nothrow @safe @nogc
{
    const max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    const min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    v = max;
    s = max > 0 ? (max - min) / max : 0;
    if (s == 0)
    {
        h = 0;
        return;
    }
    const rc = (max - r) / (max - min), gc = (max - g) / (max - min), bc = (max - b) / (max - min);
    double hue = r == max ? bc - gc : g == max ? 2 + rc - bc : 4 + gc - rc;
    hue /= 6;
    if (hue < 0)
        hue += 1;
    h = hue * 360;
}

/// The colour with hue `h` degrees, saturation `s` and brightness `v`. JavaFX's Color.hsb.
Colour fromHsb(double h, double s, double v, double alpha = 1) pure nothrow @safe @nogc
{
    import std.math : floor;
    h = h - floor(h / 360) * 360;
    const c = v * s;
    const hh = h / 60;
    const x = c * (1 - abs1(hh - 2 * floor(hh / 2) - 1));
    double r = 0, g = 0, b = 0;
    if (hh < 1)      { r = c; g = x; }
    else if (hh < 2) { r = x; g = c; }
    else if (hh < 3) { g = c; b = x; }
    else if (hh < 4) { g = x; b = c; }
    else if (hh < 5) { r = x; b = c; }
    else             { r = c; b = x; }
    const m = v - c;
    return Colour(channel(r + m), channel(g + m), channel(b + m), channel(alpha));
}

ubyte channel(double f) pure nothrow @safe @nogc
{
    if (f <= 0) return 0;
    if (f >= 1) return 255;
    return cast(ubyte)(f * 255 + 0.5);
}

private double abs1(double x) pure nothrow @safe @nogc { return x < 0 ? -x : x; }

unittest
{
    // Worked by hand through JavaFX's algorithm
    assert(derive(Colour(0xec, 0xec, 0xec), -0.3) == Colour(0xa5, 0xa5, 0xa5)); // darker: 0.925 x 0.7
    assert(derive(Colour(0, 0, 0), 0.5) == Colour(0x4d, 0x4d, 0x4d));        // lighter, but by 0.6 of it: very dark
    assert(ladder(Colour(0, 0, 0), [Colour(255, 255, 255), Colour(0, 0, 0)], [0.49, 0.5]) == Colour(255, 255, 255));
    assert(ladder(Colour(255, 255, 255), [Colour(255, 255, 255), Colour(0, 0, 0)], [0.49, 0.5]) == Colour(0, 0, 0));
}
