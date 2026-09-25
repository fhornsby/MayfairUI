module mayfair.animation.transition;

import core.time : Duration;
import mayfair.animation.animation;
import mayfair.animation.interpolator;

/*
    An animation that runs something from 0 to 1 over its duration, eased by an interpolator.
    JavaFX's Transition.

    JavaFX has a subclass per thing to animate (FadeTransition, ScaleTransition...) because each
    has a property to bind to. Mayfair has no property system, so a delegate stands in for all of
    them: it's handed the eased fraction and does whatever that means, usually setting a field
    and calling invalidate().

        auto fade = new Transition(200.msecs, (t) { amount = t; invalidate(); });
        fade.play();

    Subclassing and overriding interpolate() works too, for a transition worth a name of its own.
*/
class Transition : Animation
{
public:
    this(Duration duration, void delegate(double) action = null) nothrow @nogc
    {
        cycleDuration(duration);
        _action = action;
    }

    Interpolator interpolator() const nothrow @nogc { return _interpolator; }

    /// Returns this, so calls chain.
    Transition interpolator(Interpolator i) nothrow @nogc
    {
        _interpolator = i;
        return this;
    }

    /*
        Plays towards the end, or the start, from wherever it has got to, turning round if it's
        running the other way. The pair a widget uses for a state that comes and goes -- hover, a
        press, focus -- where play() on its own isn't quite enough: a stopped animation played
        again starts over from the far end, which for a highlight that's already fully on would
        mean flashing it off first. These do nothing if it's already there.
    */
    void playForward()
    {
        playTowards(1);
    }

    void playReverse()
    {
        playTowards(0);
    }

    /// Stops, and goes back to the start, as Animation.stop() does -- which the forward and
    /// reverse above then count from.
    override void stop() nothrow @nogc
    {
        super.stop();
        _fraction = 0;
    }

protected:
    /// Applies `fraction`, already eased, of the change. Calls the delegate unless overridden.
    void interpolate(double fraction)
    {
        if (_action)
            _action(fraction);
    }

    override final void step(double fraction)
    {
        _fraction = fraction;
        interpolate(_interpolator.curve(fraction));
    }

private:
    double _fraction = 0; // where it last got to, before easing

    void playTowards(double end)
    {
        if (status != Status.running && _fraction == end)
            return;
        rate = end > 0 ? 1 : -1;
        play();
    }

    Interpolator _interpolator = Interpolator.easeBoth;
    void delegate(double) _action;
}

unittest
{
    import core.time : MonoTime, msecs;
    import mayfair.animation.interpolator;

    double value = 0;
    auto t = new Transition(100.msecs, (f) { value = f; }).interpolator(Interpolator.linear);

    // Run to the end by hand, then ask for the end again: it's there, so nothing restarts
    t.playForward();
    pulseAnimations(MonoTime.currTime + 200.msecs);
    assert(value == 1 && t.status == Status.stopped);
    t.playForward();
    assert(t.status == Status.stopped && value == 1);

    // Reverse goes back from the end, not from a restart at the start
    t.playReverse();
    assert(t.status == Status.running && t.rate < 0);

    // After stop() the playhead is at the start, so forward plays again
    t.stop();
    t.playForward();
    assert(t.status == Status.running && t.rate > 0);
}
