module mayfair.media.gstreamer;

/*
    A MediaBackend on GStreamer: Mayfair's media played by the GStreamer installed on the system,
    which does the reading, demuxing, decoding, buffering, timing, keeping sound and picture in
    step, and playing the sound. Mayfair shows the video, in a MediaView, and draws the controls.

        import mayfair.media;
        import mayfair.media.gstreamer;

        MediaPlayer.setBackend(new GStreamerBackend);

    GStreamer is found when the first player loads something, not when the app's built or
    started: an app with this backend builds and runs without it, and its players halt with
    MediaErrorKind.backendUnavailable, saying what's missing. What it can play is whatever the
    system's GStreamer plugins can: see this package's README.

    GStreamer is LGPL-2.1-or-later, and its plugins each have their own licence (see the README).
    Using it through this package, which is MIT, doesn't change that: an app that ships GStreamer
    ships it under its terms.
*/

public import mayfair.media;
import mayfair.media.gstreamer.session;

/// GStreamer, as a MediaBackend.
final class GStreamerBackend : MediaBackend
{
    /*
        `audioSink` says what plays the sound, in gst-launch's terms: null for GStreamer's choice
        (autoaudiosink: PipeWire, PulseAudio, ALSA, CoreAudio or WASAPI, as the system has),
        or "fakesink sync=true" for none at all, keeping time as though it played -- for tests,
        a machine with no sound, or a player that's always silent.
    */
    this(string audioSink = null)
    {
        this.audioSink = audioSink;
    }

    string name() { return "gstreamer"; }

    MediaSession open(MediaSessionHost host)
    {
        return new GstSession(host, audioSink);
    }

    /*
        Whether GStreamer can be found and started here, and if not, why. It starts GStreamer, if
        nothing has yet, which can take a second or two the first time it's run on a machine: call
        it from a thread of the app's own, not the UI thread.
    */
    static bool available(out string why)
    {
        return startGStreamer(why);
    }

private:
    string audioSink;
}
