module mayfair.animation.timeline;

import core.time : Duration, nsecs;
import std.algorithm : sort;
import std.math : ceil, floor;
import mayfair.animation.animation;

/// A moment in a Timeline, and what happens then. JavaFX's KeyFrame, less its KeyValues, which
/// need a property system to set: `onFinished` does whatever they would have.
struct KeyFrame
{
    Duration time;
    void delegate() onFinished;
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
*/
class Timeline : Animation
{
public:
    this(KeyFrame[] frames...)
    {
        _frames = frames.dup;
        _frames.sort!((a, b) => a.time < b.time);
        cycleDuration(_frames.length ? _frames[$ - 1].time : Duration.zero);
    }

protected:
    override void step(double fraction) {}

    override void moved(double from, double to, bool fresh)
    {
        const cycle = cycleSeconds;
        if (cycle <= 0 || !_frames.length)
            return;
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
}
