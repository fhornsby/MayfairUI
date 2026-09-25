module mayfair.animation.interpolator;

import std.math : abs;

/*
    How far through its change an animation is, given how far through its time it is. JavaFX's
    Interpolator.

    Every one is a cubic Bézier from (0, 0) to (1, 1) with two control points in between -- the
    curve JavaFX's Interpolator.SPLINE and CSS's cubic-bezier() both describe -- so the named ones
    are just particular control points, and a curve of your own is `Interpolator(x1, y1, x2, y2)`.
    Being four floats rather than a function pointer or an object is what lets them be enums and
    be copied about freely.
*/
struct Interpolator
{
    float x1 = 0, y1 = 0, x2 = 1, y2 = 1;

    enum Interpolator linear   = Interpolator(0, 0, 1, 1);
    enum Interpolator easeIn   = Interpolator(0.42, 0, 1, 1);    /// Starts slowly
    enum Interpolator easeOut  = Interpolator(0, 0, 0.58, 1);    /// Ends slowly
    enum Interpolator easeBoth = Interpolator(0.42, 0, 0.58, 1); /// Both, and what Transition uses unless told otherwise

    /// The eased fraction for a time fraction `t` in [0, 1].
    double curve(double t) const pure nothrow @nogc @safe
    {
        if (t <= 0)
            return 0;
        if (t >= 1)
            return 1;
        if (x1 == y1 && x2 == y2)
            return t; // a straight line, whatever the control points

        // The curve is given as x(s), y(s), and what's wanted is y at a given x. Newton's method
        // finds the s nearly always in a few steps; bisection catches the flat spots it can't.
        double s = t;
        foreach (_; 0 .. 8)
        {
            const error = bezier(s, x1, x2) - t;
            if (abs(error) < 1e-6)
                return bezier(s, y1, y2);
            const slope = bezierSlope(s, x1, x2);
            if (abs(slope) < 1e-6)
                break;
            s -= error / slope;
            if (s < 0 || s > 1)
                break;
        }

        double lo = 0, hi = 1;
        s = t;
        while (hi - lo > 1e-6)
        {
            if (bezier(s, x1, x2) < t)
                lo = s;
            else
                hi = s;
            s = (lo + hi) / 2;
        }
        return bezier(s, y1, y2);
    }

    /// The value `t` of the way from `start` to `end`, eased.
    double interpolate(double start, double end, double t) const pure nothrow @nogc @safe
    {
        return start + (end - start) * curve(t);
    }
}

// One coordinate of a cubic Bézier whose ends are 0 and 1 and whose control points are p1, p2
private double bezier(double s, double p1, double p2) pure nothrow @nogc @safe
{
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

private double bezierSlope(double s, double p1, double p2) pure nothrow @nogc @safe
{
    const u = 1 - s;
    return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2);
}

unittest
{
    foreach (i; [Interpolator.linear, Interpolator.easeIn, Interpolator.easeOut, Interpolator.easeBoth])
    {
        assert(i.curve(0) == 0 && i.curve(1) == 1);
        double last = 0;
        foreach (step; 1 .. 100)
        {
            const y = i.curve(step / 100.0);
            assert(y >= last);
            last = y;
        }
    }
    assert(abs(Interpolator.easeBoth.curve(0.5) - 0.5) < 1e-4); // symmetric
    assert(Interpolator.easeIn.curve(0.25) < 0.25 && Interpolator.easeOut.curve(0.25) > 0.25);
}
