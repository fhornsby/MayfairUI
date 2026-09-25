module mayfair.theme;

struct Colour
{
    ubyte r, g, b, a = 255;

    /// The colour `t` of the way from this one to `end`, channel by channel. JavaFX's Color.interpolate.
    Colour interpolate(Colour end, double t) const pure nothrow @nogc @safe
    {
        static ubyte mix(ubyte from, ubyte to, double t) pure nothrow @nogc @safe
        {
            return cast(ubyte)(from + (to - from) * t + 0.5);
        }
        if (t <= 0)
            return this;
        if (t >= 1)
            return end;
        return Colour(mix(r, end.r, t), mix(g, end.g, t), mix(b, end.b, t), mix(a, end.a, t));
    }
}

public import mayfair.theme.colours;
