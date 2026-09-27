module mayfair.widgets.lottieview;

import core.time : Duration, hnsecs, seconds;
import std.format : format;
import std.string : fromStringz, toStringz;
import mayfair.animation;
import mayfair.css;
import mayfair.images;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.widgets.imageview;
import mayfair.widgets.styling;

/*
    Plays a Lottie animation: vector animation, as JSON, of the kind After Effects exports through
    Bodymovin and LottieFiles publishes by the thousand. An animated icon, a loading spinner, an
    illustration that moves -- drawn by ThorVG as the vectors they are, so sharp at any size, and
    a few kilobytes where a video or a GIF would be megabytes.

        new LottieView(Image.fromData(import("loading.json"), "loading.json")).fitWidth(64).preserveRatio(true)

    It's an ImageView, so it sizes, fits and pads as one does. What it adds is playing: it plays
    from the moment it's shown, over and over, unless autoPlay says not to, and `animation` is its
    playback -- an Animation like any other in the kit, so everything JavaFX's Animation does is
    there to control it:

        spinner.animation.pause();
        spinner.animation.rate(-1).play();          // backwards, from where it is
        tick.animation.cycleCount(1).onFinished({ ... });

    A Lottie file can name parts of its timeline with markers -- "in", "loop", "out", or one per
    state of an animated button -- and `marker` plays just that part: `markers` lists them. The
    animation's cycle is then that part's length.

    Its colours can follow the stylesheet -- the theme's accent, light and dark -- where the file
    allows it. A Lottie file's author can make a colour a slot, giving it an id for a player to set,
    and a colour slot called "ring" takes the colour of the variable --lottie-ring, if one's
    declared for the view or anywhere above it:

        .spinner { --lottie-ring: var(--accent); }
        .root    { --lottie-brand: #7c3aed; }        // every animation with a "brand" slot

    So an animation from LottieFiles, given slots in its editor or by adding "sid" to a fill's or a
    stroke's colour, changes with the colour scheme like everything else, derive() and all. A slot
    nothing declares a colour for keeps the file's own. Lottie colours have no alpha of their own
    -- their opacity is separate -- so a colour's alpha is left out.

    It's paused while it isn't in a scene, and carries on from there when it's back. Its style
    class is "lottie-view".
*/
class LottieView : ImageView
{
public:
    this(Image image = null)
    {
        _playback = new Playback(this);
        _playback.cycleCount(Animation.indefinite);
        super(image);
        styleClass.add("lottie-view");
    }

    /// Its playback: play, pause and stop it, and set its rate, cycle count and so on, as with any Animation.
    final Animation animation() nothrow @nogc { return _playback; }

    /// Whether it starts playing as soon as it's shown. JavaFX's MediaPlayer.autoPlay.
    mixin(declareProperty!(bool, "autoPlay", "true"));

    /// The part of the timeline to play, by the name of a marker in the file; null for all of it.
    mixin(declareProperty!(string, "marker", "null", q{ applyMarker(); }));

    /// The names of the markers in the file, once it's loaded.
    final string[] markers()
    {
        string[] names;
        uint count;
        if (!_anim || tvg_lottie_animation_get_markers_cnt(_anim, &count) != TVG_RESULT_SUCCESS)
            return null;
        foreach (i; 0 .. count)
        {
            const(char)* name;
            if (tvg_lottie_animation_get_marker(_anim, i, &name) == TVG_RESULT_SUCCESS && name)
                names ~= name.fromStringz.idup;
        }
        return names;
    }

    /// How many frames the part being played has, and which it's showing: for tests and scrubbing.
    final float totalFrames() nothrow @nogc
    {
        float n = 0;
        if (_anim)
            tvg_animation_get_total_frame(_anim, &n);
        return n;
    }

    /// ditto
    final float currentFrame() nothrow @nogc
    {
        float n = 0;
        if (_anim)
            tvg_animation_get_frame(_anim, &n);
        return n;
    }

protected:
    override void mounted() nothrow
    {
        super.mounted();
        if (_resume || (_autoPlay && !_played))
            play();
        _resume = false;
    }

    override void unmounted()
    {
        _resume = _playback.status == Status.running;
        _playback.pause();
        super.unmounted();
    }

    /// A picture that's an animation's, so its frames can be set.
    override Tvg_Paint createPicture(Image image) nothrow
    {
        auto anim = tvg_lottie_animation_new();
        auto p = tvg_animation_get_picture(anim);
        if (tvg_picture_load_data(p, image.dataPointer, image.dataLength, image.mimeType, image.resourcePath,
                                  image.copyOnLoad)
            != TVG_RESULT_SUCCESS)
        {
            tvg_animation_del(anim); // and the picture with it, which it owns
            return null;
        }
        _anim = anim;
        _slotJson = null; // a new animation, with none of the old one's colours
        _slotId = 0;
        applyMarker();
        applySlotColours();
        return p;
    }

    override void restyled()
    {
        applySlotColours();
    }

    /// Out of the scene: the animation holds the picture's last reference, and frees it.
    override void released() nothrow
    {
        if (_anim)
            tvg_animation_del(_anim);
        _anim = null;
    }

private:
    Playback _playback;
    Tvg_Animation _anim;
    double _fraction = 0; // how far through the cycle it last showed, for a picture loaded afresh
    bool _played;         // it's been played, so showing it again doesn't start it over
    bool _resume;         // it was running when it was taken out of the scene
    string _slotJson;     // the colours last given to its slots, as ThorVG takes them
    uint _slotId;         // and ThorVG's id for them, 0 for none

    void play() nothrow
    {
        _played = true;
        try
            _playback.play();
        catch (Exception) {}
    }

    /// Plays the marked part, or all of it, and fits the playback's cycle to its length.
    void applyMarker() nothrow
    {
        if (!_anim)
            return;
        const(char)* name;
        try
            name = _marker.length ? _marker.toStringz : null;
        catch (Exception) {}
        if (tvg_lottie_animation_set_marker(_anim, name) != TVG_RESULT_SUCCESS)
            tvg_lottie_animation_set_marker(_anim, null); // no such marker: all of it
        float secs = 0;
        tvg_animation_get_duration(_anim, &secs);
        if (secs > 0)
            _playback.cycleDuration(hnsecs(cast(long)(secs * 1e7)));
        else
            _playback.stop(); // one frame: nothing to play
        show(_fraction);
    }

    /*
        Gives each colour slot the colour the stylesheet looks up for it, all together as one of
        ThorVG's slot overrides. Only if they've changed, since this runs on every restyle -- a
        hover, a focus -- and building the override has ThorVG parse it and rebuild the frame.
    */
    void applySlotColours() nothrow
    {
        if (!_anim || !image)
            return;
        string json;
        try
        {
            auto context = StyleContext(this);
            foreach (sid; image.colourSlots)
            {
                auto value = context.lookup("--lottie-" ~ sid);
                Colour c;
                if (value && convert(*value, context, c))
                    json ~= format!`%s"%s":{"p":{"a":0,"k":[%.4f,%.4f,%.4f,1]}}`(json.length ? "," : "", sid,
                                                                             c.r / 255.0, c.g / 255.0, c.b / 255.0);
            }
            if (json.length)
                json = "{" ~ json ~ "}";
        }
        catch (Exception)
            return;
        if (json == _slotJson)
            return;
        // Out with the old colours, back to the file's, and in with the new
        if (_slotId)
            tvg_lottie_animation_del_slot(_anim, _slotId);
        _slotId = 0;
        _slotJson = json;
        if (json.length)
        {
            try
                _slotId = tvg_lottie_animation_gen_slot(_anim, json.toStringz);
            catch (Exception) {}
        }
        tvg_lottie_animation_apply_slot(_anim, _slotId);
        invalidate();
    }

    /// Shows the frame `fraction` of the way through the part being played.
    void show(double fraction) nothrow @nogc
    {
        _fraction = fraction;
        if (!_anim)
            return;
        float total = 0;
        tvg_animation_get_total_frame(_anim, &total);
        if (total > 0 && tvg_animation_set_frame(_anim, cast(float)(fraction * total)) == TVG_RESULT_SUCCESS)
            invalidate();
    }

    static final class Playback : Animation
    {
        LottieView view;

        this(LottieView view) nothrow @nogc
        {
            this.view = view;
            cycleDuration(1.seconds); // until there's a file to say
        }

    protected:
        override void step(double fraction)
        {
            view.show(fraction);
        }
    }
}
