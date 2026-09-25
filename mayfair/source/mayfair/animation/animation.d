module mayfair.animation.animation;

import core.time : Duration, MonoTime, nsecs;
import std.math : floor;

/// JavaFX's Animation.Status.
enum Status { stopped, paused, running }

/*
    Something that changes over time. JavaFX's Animation: a cycle of some duration, played some
    number of times, forwards or backwards at some rate, and told on every frame how far through
    it is. What changes is up to the subclass -- see Transition.

    The rate is how the same animation plays in reverse: set it to -1 and play() runs it back
    towards the start, from wherever it is. Changing it while the animation is running turns it
    round on the spot, which is what makes a hover highlight that fades out from half way when
    the pointer leaves half way through fading in.

    play() on a stopped animation starts from the beginning -- or the end, if the rate is
    negative -- which is JavaFX's rule too, and is why a finished animation can simply be played
    again. It stops by itself when it runs off either end.

    Running animations are advanced by the app, in its update phase, all from the same clock
    reading. That's the "pulse" in JavaFX. An animation that changes continuously, like a fade,
    wants one every frame; one that only does something at set moments, like a Timeline blinking a
    caret, says how long until the next (untilNextPulse), and the app sleeps until then. Once
    nothing is running it sleeps until an event arrives.
*/
abstract class Animation
{
public:
    enum int indefinite = -1; /// A cycleCount that never runs out

    Duration cycleDuration() const nothrow @nogc { return _cycleDuration; }
    Animation cycleDuration(Duration d) nothrow @nogc
    {
        _cycleDuration = d;
        return this;
    }

    /// How many times the cycle plays: 1 by default, or `indefinite`.
    int cycleCount() const nothrow @nogc { return _cycleCount; }
    Animation cycleCount(int n) nothrow @nogc
    {
        _cycleCount = n;
        return this;
    }

    /// Whether every other cycle plays backwards, so a repeating animation swings to and fro.
    bool autoReverse() const nothrow @nogc { return _autoReverse; }
    Animation autoReverse(bool on) nothrow @nogc
    {
        _autoReverse = on;
        return this;
    }

    /// Speed and direction: 1 is normal speed forwards, 2 twice as fast, -1 normal speed backwards.
    double rate() const nothrow @nogc { return _rate; }
    Animation rate(double r) nothrow @nogc
    {
        _rate = r;
        return this;
    }

    Status status() const nothrow @nogc { return _status; }

    /// Called when the animation runs off the end, but not when it's stopped. Returns this, so calls chain.
    Animation onFinished(void delegate() handler) nothrow @nogc
    {
        _onFinished = handler;
        return this;
    }

    /// Plays from where it is, in the direction the rate says. Does nothing if it's already running.
    void play()
    {
        final switch (_status)
        {
            case Status.running:
                return;
            case Status.stopped:
                _position = _rate < 0 ? startOfLastCycle + cycleSeconds : 0;
                break;
            case Status.paused:
                break;
        }
        if (_status == Status.stopped)
            _fresh = true;
        _status = Status.running;
        _lastPulse = MonoTime.currTime;
        if (!_registered)
        {
            _registered = true;
            running ~= this;
        }
    }

    /// Plays forwards from the beginning, whatever it was doing.
    void playFromStart()
    {
        stop();
        if (_rate < 0)
            _rate = -_rate;
        play();
    }

    /// Stops where it is. play() carries on from here.
    void pause() nothrow @nogc
    {
        if (_status == Status.running)
            _status = Status.paused;
    }

    /// Stops, and goes back to the start. What it last set is left as it was.
    void stop() nothrow @nogc
    {
        _status = Status.stopped;
        _position = 0;
    }

protected:
    /// Brings whatever this animates to `fraction` of the way through a cycle, from 0 to 1.
    /// Reversed cycles are already accounted for; this is called every pulse while running.
    abstract void step(double fraction);

    /*
        Called every pulse with where the animation was and where it is now, in seconds along the
        whole run of cycles; `fresh` is true on the first pulse after starting from stopped. Most
        animations only care where they are, and leave this to call step(). One that has to know
        what it passed on the way, like a Timeline, overrides it.
    */
    void moved(double from, double to, bool fresh)
    {
        step(fractionAt(to));
    }

    /// How long from now until this animation next needs a pulse. Zero, the default, means every
    /// frame, which is what anything that changes continuously wants.
    Duration untilNextPulse() const nothrow @nogc
    {
        return Duration.zero;
    }

    /// Where it's got to, in seconds along the whole run of cycles.
    final double position() const nothrow @nogc { return _position; }

    /// How long a cycle is, in seconds.
    final double cycleSeconds() const nothrow @nogc
    {
        return _cycleDuration.total!"hnsecs" / 1e7;
    }

    /// `position` as a fraction of the way through its cycle, with reversed cycles reversed.
    final double fractionAt(double position) const nothrow @nogc
    {
        const cycle = cycleSeconds;
        if (cycle <= 0)
            return _rate < 0 ? 0 : 1;

        double index = floor(position / cycle);
        double within = position - index * cycle;
        // The very end of the last cycle belongs to it, not to one more after it
        if (_cycleCount != indefinite && index >= _cycleCount)
        {
            index = _cycleCount - 1;
            within = cycle;
        }
        const fraction = within / cycle;
        return _autoReverse && (cast(long) index) % 2 != 0 ? 1 - fraction : fraction;
    }

private:
    Duration _cycleDuration;
    int _cycleCount = 1;
    bool _autoReverse;
    double _rate = 1;
    Status _status;
    void delegate() _onFinished;

    double _position = 0; // seconds along the whole run of cycles, not just the current one
    MonoTime _lastPulse;
    bool _registered;     // whether it's in `running`, which a paused or stopped one may still be
    bool _fresh;          // started from stopped, and not pulsed since

    double startOfLastCycle() const nothrow @nogc
    {
        return _cycleCount == indefinite ? 0 : (_cycleCount - 1) * cycleSeconds;
    }

    void pulse(MonoTime now)
    {
        // Something played during this pulse read the clock after `now` did
        const elapsed = now > _lastPulse ? (now - _lastPulse).total!"hnsecs" / 1e7 : 0.0;
        _lastPulse = now;
        const from = _position;
        _position += elapsed * _rate;

        bool finished;
        if (_cycleCount != indefinite)
        {
            const end = startOfLastCycle + cycleSeconds;
            if (_rate > 0 && _position >= end)
            {
                _position = end;
                finished = true;
            }
            else if (_rate < 0 && _position <= 0)
            {
                _position = 0;
                finished = true;
            }
        }

        const fresh = _fresh;
        _fresh = false;
        moved(from, _position, fresh);
        if (finished && _status == Status.running) // moved() may have stopped it itself
        {
            _status = Status.stopped;
            if (_onFinished)
                _onFinished();
        }
    }

}

/*
    The animations being played, for pulseAnimations() to advance. Thread-local, which is right:
    animations belong to the thread running the UI. One that stops isn't taken out straight
    away, since that could be from inside the loop going through them, but at the end of the pulse.
*/
private Animation[] running;

/// Advances every running animation to `now`. Returns whether any is still running afterwards.
package(mayfair) bool pulseAnimations(MonoTime now)
{
    // By index, because an animation's handler may play another, which lands on the end
    for (size_t i = 0; i < running.length; i++)
        if (running[i]._status == Status.running)
            running[i].pulse(now);

    size_t kept;
    foreach (a; running)
    {
        if (a._status == Status.running)
            running[kept++] = a;
        else
            a._registered = false;
    }
    running = running[0 .. kept];
    running.assumeSafeAppend();
    return kept > 0;
}

/// Whether anything needs another frame.
package(mayfair) bool animationsRunning() nothrow @nogc
{
    foreach (a; running)
        if (a._status == Status.running)
            return true;
    return false;
}

/// How long until any running animation next needs a pulse: zero for the next frame, or
/// Duration.max if nothing is running.
package(mayfair) Duration untilNextPulse() nothrow @nogc
{
    auto soonest = Duration.max;
    foreach (a; running)
    {
        if (a._status != Status.running)
            continue;
        // Measured from its last pulse, which was this frame's clock reading or shortly before
        const due = a.untilNextPulse;
        if (due < soonest)
            soonest = due;
    }
    return soonest;
}

unittest
{
    import core.time : msecs;
    import mayfair.animation.interpolator;
    import mayfair.animation.transition;
    import std.math : isClose;

    double value = -1;
    int finishes;
    Animation t = new Transition(100.msecs, (f) { value = f; }).interpolator(Interpolator.linear);
    t.onFinished({ finishes++; });

    // Played by hand rather than through the pulse, so the clock is the test's
    t.play();
    auto clock = t._lastPulse;
    t.pulse(clock += 50.msecs);
    assert(isClose(value, 0.5));

    // Turned round half way, it comes back from where it is rather than jumping
    t.rate = -1;
    t.play(); // already running, so this changes nothing
    t.pulse(clock += 20.msecs);
    assert(isClose(value, 0.3));
    t.pulse(clock += 100.msecs);
    assert(value == 0 && t.status == Status.stopped && finishes == 1);

    // Stopped at the start and played forwards, then played backwards from the end once finished
    t.rate = 1;
    t.play();
    clock = t._lastPulse;
    t.pulse(clock += 200.msecs);
    assert(value == 1 && t.status == Status.stopped && finishes == 2);
    t.rate = -1;
    t.play();
    clock = t._lastPulse;
    t.pulse(clock += 25.msecs);
    assert(isClose(value, 0.75));

    // Two cycles swinging to and fro
    Animation swing = new Transition(100.msecs, (f) { value = f; }).interpolator(Interpolator.linear);
    swing.cycleCount(2).autoReverse(true);
    swing.play();
    clock = swing._lastPulse;
    swing.pulse(clock += 150.msecs);
    assert(isClose(value, 0.5));
    swing.pulse(clock += 100.msecs);
    assert(value == 0 && swing.status == Status.stopped);
}
