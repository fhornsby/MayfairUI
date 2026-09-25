module mayfair.animation.timeline;

import core.time : Duration, nsecs;
import std.algorithm : sort;
import std.math : ceil, floor;
import mayfair.animation.animation;
import mayfair.animation.interpolator;
import mayfair.properties.property;

/*
    A value a property should have at some moment: JavaFX's KeyValue. In a KeyFrame, it says what
    the property is at that frame's time; in between frames the Timeline moves it there from what
    it was, eased by `interpolator`, which belongs to the end it's moving towards.

        auto slide = new Timeline(KeyFrame(300.msecs, KeyValue(box.prefWidthProperty, 400f, Interpolator.easeOut)));
        slide.play();

    Numbers and colours move smoothly. Anything else -- a string, a bool -- has nothing in between,
    and changes at the end, as JavaFX's do.
*/
struct KeyValue
{
    this(T)(Property!T target, T end, Interpolator interpolator = Interpolator.linear)
    {
        this.target = target;
        this.interpolator = interpolator;
        this.end = new Box!T(end);
        read = &readValue!T;
        write = &writeBetween!T;
    }

    Object target;
    Interpolator interpolator;

private:
    Object end;                                                 // a Box!T
    Object function(Object target) read;                        // the target's value now, boxed
    void function(Object target, Object from, Object to, double t) write;
}

private final class Box(T)
{
    T value;
    this(T value) { this.value = value; }
}

private Object readValue(T)(Object target)
{
    return new Box!T((cast(Property!T) target).get());
}

private void writeBetween(T)(Object target, Object from, Object to, double t)
{
    import mayfair.theme : Colour;
    const a = (cast(Box!T) from).value, b = (cast(Box!T) to).value;
    static if (is(T : double))
        const value = cast(T)(a + (b - a) * t);
    else static if (is(T == Colour))
        const value = a.interpolate(b, t);
    else
        const value = t < 1 ? a : b; // nothing in between: it changes at the end
    auto property = cast(Property!T) target;
    if (!property.isBound)
        property.set(value);
}

/// A moment in a Timeline, and what happens then: properties reach the values given, and
/// `onFinished` runs. JavaFX's KeyFrame.
struct KeyFrame
{
    Duration time;
    void delegate() onFinished;
    KeyValue[] values;

    this(Duration time, KeyValue[] values...)
    {
        this.time = time;
        this.values = values.dup;
    }

    this(Duration time, void delegate() onFinished, KeyValue[] values...)
    {
        this.time = time;
        this.onFinished = onFinished;
        this.values = values.dup;
    }
}

/*
    Things that happen at set moments: JavaFX's Timeline. Where a Transition changes something
    smoothly and needs every frame, a Timeline only does something as its playhead passes a
    KeyFrame, and tells the app how long until the next one -- so a caret blinking for as long as
    a field has focus costs two wake-ups a second, not a frame every refresh.

        auto blink = new Timeline(KeyFrame(Duration.zero, { show(); }),
                                  KeyFrame(500.msecs, { hide(); }),
                                  KeyFrame(1000.msecs, null));
        blink.cycleCount(Animation.indefinite).play();

    A cycle lasts until the last KeyFrame. Every KeyFrame the playhead passes fires, in the order
    passed, however long a pulse was, so none is skipped when the app was busy; and it runs
    backwards and swings to and fro the same as any Animation. A KeyFrame at zero fires as it
    starts from the beginning.

    KeyFrames with KeyValues move properties smoothly between them, which takes every frame; a
    property with no KeyValue at zero starts from whatever it was when the Timeline started.
*/
class Timeline : Animation
{
public:
    this(KeyFrame[] frames...)
    {
        _frames = frames.dup;
        _frames.sort!((a, b) => a.time < b.time);
        cycleDuration(_frames.length ? _frames[$ - 1].time : Duration.zero);
        foreach (ref f; _frames)
            foreach (ref v; f.values)
            {
                _animatesValues = true;
                bool known;
                foreach (t; _targets)
                    known |= t is v.target;
                if (!known)
                    _targets ~= v.target;
            }
    }

protected:
    override void step(double fraction) {}

    override void moved(double from, double to, bool fresh)
    {
        const cycle = cycleSeconds;
        if (cycle <= 0 || !_frames.length)
            return;
        if (fresh)
            captureStarts();
        interpolateValues(fractionAt(to) * cycle);
        const forwards = to >= from;
        const lo = forwards ? from : to, hi = forwards ? to : from;

        // Every KeyFrame, in every cycle between the two, whose moment is between them. Where the
        // playhead started only counts on the first pulse: otherwise the last pulse had it.
        struct Passed { double at; void delegate() action; }
        Passed[] passed;
        auto first = cast(long) floor(lo / cycle), last = cast(long) floor(hi / cycle);
        if (cycleCount != indefinite && last > cycleCount - 1)
            last = cycleCount - 1;
        if (first < 0)
            first = 0;
        foreach (k; first .. last + 1)
        {
            const reversed = autoReverse && k % 2 != 0;
            foreach (ref f; _frames)
            {
                const local = f.time.total!"hnsecs" / 1e7;
                const at = k * cycle + (reversed ? cycle - local : local);
                if ((at > lo && at < hi) || at == (forwards ? hi : lo) || (fresh && at == from))
                    passed ~= Passed(at, f.onFinished);
            }
        }
        if (forwards)
            passed.sort!((a, b) => a.at < b.at);
        else
            passed.sort!((a, b) => a.at > b.at);

        foreach (ref p; passed)
        {
            if (status != Status.running)
                return; // a handler stopped it
            if (p.action)
                p.action();
        }
    }

    override Duration untilNextPulse() const nothrow @nogc
    {
        if (_animatesValues)
            return Duration.zero; // moving properties smoothly takes every frame
        const cycle = cycleSeconds;
        if (cycle <= 0 || rate == 0)
            return rate == 0 ? Duration.max : Duration.zero;
        const at = position;
        const forwards = rate > 0;

        // The nearest KeyFrame ahead of the playhead, looking into the next cycle too
        double soonest = double.infinity;
        const k0 = cast(long) floor(at / cycle);
        foreach (k; k0 - 1 .. k0 + 2)
        {
            if (k < 0 || (cycleCount != indefinite && k > cycleCount - 1))
                continue;
            const reversed = autoReverse && k % 2 != 0;
            foreach (ref f; _frames)
            {
                const local = f.time.total!"hnsecs" / 1e7;
                const t = k * cycle + (reversed ? cycle - local : local);
                const ahead = forwards ? t - at : at - t;
                if (ahead > 0 && ahead < soonest)
                    soonest = ahead;
            }
        }
        if (soonest == double.infinity)
            return Duration.zero; // nothing left ahead: let it run to its end and finish
        const seconds = soonest / (rate < 0 ? -rate : rate);
        return nsecs(cast(long) ceil(seconds * 1e9));
    }

private:
    KeyFrame[] _frames;
    bool _animatesValues;
    Object[] _targets;   // every property a KeyValue moves
    Object[] _starts;    // what each was when the Timeline started, boxed, for those with no KeyValue at zero

    void captureStarts()
    {
        _starts.length = _targets.length;
        foreach (i, target; _targets)
            _starts[i] = keyValueFor(target).read(target);
    }

    /// Any KeyValue for `target`, for the functions that know its type.
    ref const(KeyValue) keyValueFor(Object target)
    {
        foreach (ref f; _frames)
            foreach (ref v; f.values)
                if (v.target is target)
                    return v;
        assert(0, "every target has a KeyValue");
    }

    /// Puts every animated property where it should be `at` seconds into the cycle: between the
    /// KeyFrames either side that say anything about it, or at the last one's value past them all.
    void interpolateValues(double at)
    {
        if (!_animatesValues || _starts.length != _targets.length)
            return;
        foreach (i, target; _targets)
        {
            Object from = _starts[i];
            double fromTime = 0;
            const(KeyValue)* next;
            double nextTime = 0;
            foreach (ref f; _frames)
            {
                const time = f.time.total!"hnsecs" / 1e7;
                foreach (ref v; f.values)
                {
                    if (v.target !is target)
                        continue;
                    if (time <= at)
                    {
                        from = cast(Object) v.end;
                        fromTime = time;
                    }
                    else if (!next)
                    {
                        next = &v;
                        nextTime = time;
                    }
                }
            }
            if (!next)
            {
                // Past the last value for it: that's where it stays
                keyValueFor(target).write(target, from, from, 1);
                continue;
            }
            const span = nextTime - fromTime;
            const t = span > 0 ? next.interpolator.curve((at - fromTime) / span) : 1;
            next.write(target, from, cast(Object) next.end, t);
        }
    }

}

unittest
{
    import core.time : MonoTime, msecs, seconds;

    string fired;
    auto t = new Timeline(KeyFrame(Duration.zero, { fired ~= "0"; }),
                          KeyFrame(500.msecs, { fired ~= "h"; }),
                          KeyFrame(1.seconds, { fired ~= "e"; }));
    t.cycleCount(3);

    // Starting from the beginning fires the KeyFrame at zero, and then nothing is due for half a second
    t.play();
    const start = MonoTime.currTime;
    pulseAnimations(start);
    assert(fired == "0");
    const due = t.untilNextPulse;
    assert(due > 400.msecs && due <= 501.msecs);

    // A long gap fires everything it passed, in order, across the cycle boundary, and the last
    // cycle's end finishes it
    pulseAnimations(start + 1600.msecs);
    assert(fired == "0he0h", fired);
    pulseAnimations(start + 10.seconds);
    assert(fired == "0he0he0he", fired);
    assert(t.status == Status.stopped);

    // KeyValues: a property moved from where it started to 100, half way at half time, eased
    import mayfair.properties.property : Property;
    import mayfair.animation.interpolator : Interpolator;
    auto width = new Property!float(0);
    auto grow = new Timeline(KeyFrame(1.seconds, KeyValue(width, 100f)));
    grow.play();
    const begun = MonoTime.currTime;
    pulseAnimations(begun);
    pulseAnimations(begun + 500.msecs);
    assert(width.get > 49 && width.get < 51, "half way");
    pulseAnimations(begun + 2.seconds);
    assert(width.get == 100 && grow.status == Status.stopped);
    assert(grow.untilNextPulse == Duration.zero); // values move every frame

    // Two KeyFrames, and a string, which changes at its frame rather than in between
    auto label = new Property!string("start");
    auto steps = new Timeline(KeyFrame(Duration.zero, KeyValue(width, 0f)),
                              KeyFrame(1.seconds, KeyValue(width, 10f), KeyValue(label, "done")),
                              KeyFrame(2.seconds, KeyValue(width, 30f, Interpolator.linear)));
    steps.play();
    const s0 = MonoTime.currTime;
    pulseAnimations(s0);
    assert(width.get < 0.1f && label.get == "start"); // a few microseconds in
    pulseAnimations(s0 + 1500.msecs);
    assert(width.get > 19 && width.get < 21 && label.get == "done");
}
