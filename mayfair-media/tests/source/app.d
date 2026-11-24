import core.stdc.stdlib : exit;
import core.time : Duration, msecs, seconds;
import std.format : format;
import std.math : abs;
import std.stdio : writefln;
import harness;
import mayfair;
import mayfair.media;

/*
    Tests for Media, MediaPlayer and MediaView, against a fake backend whose sessions do nothing
    but record what they're asked, and say what the test tells them to: so every state, and
    every late or stale piece of news, can be made to happen on cue. mayfair-gstreamer's tests
    play real media.

        cd tests && dub run
*/
void main()
{
    statusAndControls();
    loopingAndEnding();
    staleNews();
    disposal();
    noBackend();
    viewShowsFrames();
    viewDetachAndReattach();
    writefln("%s passed, %s failed checks", passedCount, failedChecks);
    exit(failedChecks ? 1 : 0);
}

/// A backend that plays nothing, and tells its players what the test says.
final class FakeBackend : MediaBackend
{
    FakeSession[] sessions;
    string name() { return "fake"; }
    MediaSession open(MediaSessionHost host)
    {
        auto s = new FakeSession(host);
        sessions ~= s;
        return s;
    }
    FakeSession last() { return sessions[$ - 1]; }
}

/// ditto
final class FakeSession : MediaSession
{
    MediaSessionHost host;
    string[] calls;   // what it was asked, in order
    uint generation;  // the last load's
    uint lastSerial;
    double volume = -1;
    bool muted, disposed;

    this(MediaSessionHost host) { this.host = host; }

    void load(string uri, uint generation) { calls ~= "load " ~ uri; this.generation = generation; }
    void play() { calls ~= "play"; }
    void pause() { calls ~= "pause"; }
    void seek(Duration position, uint serial) { calls ~= format!"seek %s"(position.total!"msecs"); lastSerial = serial; }
    void setVolume(double v) { volume = v; }
    void setMute(bool m) { muted = m; }
    void dispose() { calls ~= "dispose"; disposed = true; }

    // As the backend would tell it, for the current media
    void loaded(Duration d = 10.seconds)
    {
        MediaInfo info;
        info.duration = d;
        info.durationKnown = info.seekable = true;
        info.tracks = [Track(TrackKind.video, 0, "Fake"), Track(TrackKind.audio, 0, "Fake")];
        info.metadata = ["title": "Fake"];
        host.loaded(generation, info);
    }
    void state(SessionState s) { host.stateChanged(generation, s); }
    void position(Duration p, uint serial) { host.positionChanged(generation, serial, p); }
    void ended() { host.ended(generation); }
}

/// A frame of one colour, which counts its releases.
final class CountedFrame : VideoFrame
{
    static int released;
    uint[] pixels;
    bool gone;

    this(uint colour, uint w = 4, uint h = 2, float par = 1)
    {
        super(w, h, par, Duration.zero);
        pixels = new uint[w * h];
        pixels[] = colour;
    }
    override const(ubyte)[] map(out size_t stride) nothrow @nogc { stride = width * 4; return gone ? null : cast(const(ubyte)[]) pixels; }
    override void unmap() nothrow @nogc {}
    override void release() nothrow @nogc { assert(!gone, "released twice"); gone = true; released++; }
}

/// Play, pause, stop and seek: what's asked of the session, and the status as the session says it changes.
void statusAndControls()
{
    run("media: status and controls", { return cast(Widget) new Label("Player"); }, (Driver d) {
        d.ui({
            auto backend = new FakeBackend;
            auto media = new Media("/videos/clip.webm");
            auto player = new MediaPlayer(media, backend);
            auto s = backend.last;
            d.expect(s.calls, ["load file:///videos/clip.webm"], "loads the media's URI");
            d.expect(player.status, MediaStatus.unknown, "loading");
            d.expect(s.volume, 1.0, "told the volume to start with");

            int readies;
            player.onReady({ readies++; });
            player.play(); // before it's loaded: asked for at once, but it isn't playing yet
            d.expect(s.calls[$ - 1], "play");
            d.expect(player.status, MediaStatus.unknown, "not playing till it says so");
            s.state(SessionState.playing); // a backend that says so before it's loaded: ignored
            d.expect(player.status, MediaStatus.unknown, "nothing before loaded");

            s.loaded();
            d.expect(player.status, MediaStatus.ready);
            d.expect(readies, 1);
            d.expect(media.duration, 10.seconds, "the media learnt its duration");
            d.expect(media.tracks.length, 2);
            d.expect(media.metadata.get("title", null), "Fake");
            d.expect(s.calls[$ - 1], "play", "asked to play again, as it was before it loaded");
            s.state(SessionState.playing);
            d.expect(player.status, MediaStatus.playing);

            s.position(1500.msecs, 0);
            d.expect(player.currentTime, 1500.msecs, "currentTime from the session");

            player.pause();
            d.expect(player.status, MediaStatus.playing, "paused when it says it is");
            s.state(SessionState.paused);
            d.expect(player.status, MediaStatus.paused);

            player.seek(4.seconds);
            d.expect(player.currentTime, 4.seconds, "at the new time at once");
            d.expect(s.calls[$ - 1], "seek 4000");
            s.position(1600.msecs, s.lastSerial - 1); // from before the seek
            d.expect(player.currentTime, 4.seconds, "a position from before the seek is ignored");
            s.position(4010.msecs, s.lastSerial);
            d.expect(player.currentTime, 4010.msecs);
            player.seek(99.seconds);
            d.expect(player.currentTime, 10.seconds, "a seek past the end goes to the end");
            player.seek(-5.seconds);
            d.expect(player.currentTime, Duration.zero, "and before the start, to the start");

            player.play();
            s.state(SessionState.playing);
            player.stop();
            d.expect(player.status, MediaStatus.stopped, "stopped");
            d.expect(player.currentTime, Duration.zero, "back at the start");
            s.state(SessionState.paused);
            d.expect(player.status, MediaStatus.stopped, "and still stopped as the session pauses");

            s.state(SessionState.playing);
            s.state(SessionState.stalled);
            d.expect(player.status, MediaStatus.stalled, "stalled, waiting for a stream");
            s.state(SessionState.playing);
            d.expect(player.status, MediaStatus.playing);

            player.setVolume(0.25);
            d.expect(s.volume, 0.25);
            player.setVolume(3);
            d.expect(player.volume, 1.0, "the volume's at most 1");
            d.expect(s.volume, 1.0);
            player.setMute(true);
            d.check(s.muted, "muted");
            player.dispose();
        });
    });
}

/// It plays to the end and stops there, or loops round as many times as it's told.
void loopingAndEnding()
{
    run("media: looping and ending", { return cast(Widget) new Label("Player"); }, (Driver d) {
        d.ui({
            auto backend = new FakeBackend;
            auto player = new MediaPlayer(new Media("/clip.ogg"), backend);
            auto s = backend.last;
            int ends, repeats;
            player.onEndOfMedia({ ends++; }).onRepeat({ repeats++; });
            s.loaded(2.seconds);
            player.play();
            s.state(SessionState.playing);
            s.ended();
            d.expect(player.status, MediaStatus.ended, "ended");
            d.expect(player.currentTime, 2.seconds, "at the end");
            d.expect(player.currentCount, 1);
            d.expect(ends, 1);
            d.expect(s.calls[$ - 1], "pause", "paused there");
            s.state(SessionState.paused);
            s.position(1900.msecs, s.lastSerial);
            d.expect(player.status, MediaStatus.ended, "still ended as the session pauses");
            d.expect(player.currentTime, 2.seconds, "and positions after the end don't move it");

            player.play();
            d.expect(s.calls[$ - 2 .. $], ["seek 0", "play"], "play after the end starts again");
            d.expect(player.status, MediaStatus.paused, "from the start");
            s.state(SessionState.playing);
            d.expect(player.status, MediaStatus.playing);

            // Three times through: two repeats, then the end
            player.setMedia(new Media("/loop.ogg"));
            player.setCycleCount(3);
            s.loaded(1.seconds);
            player.play();
            s.state(SessionState.playing);
            ends = repeats = 0;
            s.ended();
            d.expect(player.status, MediaStatus.playing, "looping round, still playing");
            d.expect(s.calls[$ - 1], "seek 0");
            s.ended();
            d.expect(repeats, 2);
            d.expect(player.currentCount, 2);
            s.ended();
            d.expect(player.status, MediaStatus.ended, "then the end");
            d.expect(ends, 3);

            // For ever
            player.setMedia(new Media("/forever.ogg"));
            player.setCycleCount(MediaPlayer.indefinite);
            s.loaded(1.seconds);
            player.play();
            s.state(SessionState.playing);
            foreach (i; 0 .. 50)
                s.ended();
            d.expect(player.status, MediaStatus.playing, "loops for ever");
            d.expect(player.currentCount, 50);
            player.dispose();
        });
    });
}

/// Nothing from media since replaced -- a late frame, an error, its end -- reaches the player.
void staleNews()
{
    run("media: news for replaced media", { return cast(Widget) new Label("Player"); }, (Driver d) {
        d.ui({
            auto backend = new FakeBackend;
            auto first = new Media("/first.ogg"), second = new Media("/second.ogg");
            auto player = new MediaPlayer(first, backend);
            auto s = backend.last;
            s.loaded();
            const old = s.generation;
            auto oldFrame = new CountedFrame(0xFFFF0000);
            s.host.frameArrived(old, oldFrame);
            d.check(player.currentFrame is oldFrame, "the frame's the player's");

            player.setMedia(second);
            d.expect(backend.sessions.length, 1, "the same session, for the next media");
            d.expect(s.calls[$ - 1], "load file:///second.ogg");
            d.check(oldFrame.gone, "the old media's frame is let go of");
            d.check(player.currentFrame is null, "and not shown");
            d.expect(player.status, MediaStatus.unknown, "loading the new one");
            d.check(s.generation != old, "as a new generation");

            // Late news for the first
            auto late = new CountedFrame(0xFFFF0000);
            s.host.frameArrived(old, late);
            d.check(late.gone, "a late frame of the old media is released at once");
            d.check(player.currentFrame is null, "and never shown");
            s.host.failed(old, MediaError(MediaErrorKind.corrupt, "old"));
            s.host.ended(old);
            s.host.stateChanged(old, SessionState.playing);
            MediaInfo info;
            info.duration = 99.seconds;
            info.durationKnown = true;
            s.host.loaded(old, info);
            d.expect(player.status, MediaStatus.unknown, "none of it changes the status");
            d.check(!player.error, "or makes an error");
            d.expect(second.duration, Duration.zero, "or tells the new media anything");

            s.loaded(3.seconds);
            d.expect(player.status, MediaStatus.ready, "the new media's news is heard");
            d.expect(second.duration, 3.seconds);

            // An error for the current media halts it, and play does nothing after
            s.host.failed(s.generation, MediaError(MediaErrorKind.unsupported, "No decoder", "for Fake"));
            d.expect(player.status, MediaStatus.halted);
            d.expect(player.error.kind, MediaErrorKind.unsupported);
            const before = s.calls.length;
            player.play();
            d.expect(s.calls.length, before, "a halted player doesn't play");
            player.setMedia(first);
            d.check(!player.error, "new media clears the error");
            player.dispose();
        });
    });
}

/// Disposed of while it's loading, playing, or again: it stops for good, and lets go of everything.
void disposal()
{
    run("media: disposal", { return cast(Widget) new Label("Player"); }, (Driver d) {
        d.ui({
            auto backend = new FakeBackend;
            auto player = new MediaPlayer(new Media("/clip.ogg"), backend);
            auto s = backend.last;
            player.dispose(); // while loading
            d.check(s.disposed, "the session's disposed of");
            d.expect(player.status, MediaStatus.disposed);
            s.loaded();
            auto frame = new CountedFrame(0xFF00FF00);
            s.host.frameArrived(s.generation, frame);
            d.check(frame.gone, "a frame after is released");
            d.expect(player.status, MediaStatus.disposed, "and nothing after changes anything");
            player.play();
            player.seek(1.seconds);
            player.setMedia(new Media("/other.ogg"));
            d.expect(s.calls, ["load file:///clip.ogg", "dispose"], "nothing's asked of it after");
            player.dispose(); // twice: nothing more

            // While playing, with a frame showing
            auto playing = new MediaPlayer(new Media("/clip.ogg"), backend);
            auto t = backend.last;
            t.loaded();
            playing.play();
            t.state(SessionState.playing);
            auto shown = new CountedFrame(0xFF0000FF);
            t.host.frameArrived(t.generation, shown);
            playing.dispose();
            d.check(shown.gone, "the frame it showed is let go of");
            d.check(t.disposed, "and its session");

            // Made and disposed of over and over
            CountedFrame.released = 0;
            foreach (i; 0 .. 200)
            {
                auto p = new MediaPlayer(new Media(format!"/clip%s.ogg"(i)), backend);
                backend.last.host.frameArrived(backend.last.generation, new CountedFrame(0xFF000000));
                p.dispose();
            }
            d.expect(CountedFrame.released, 200, "every frame let go of");
            foreach (session; backend.sessions)
                d.check(session.disposed, "every session disposed of");
        });
    });
}

/// With no backend, it says so.
void noBackend()
{
    run("media: no backend", { return cast(Widget) new Label("Player"); }, (Driver d) {
        d.ui({
            MediaPlayer.setBackend(null);
            MediaError heard;
            auto player = new MediaPlayer;
            player.onError((e) { heard = e; });
            player.setMedia(new Media("/clip.ogg"));
            d.expect(player.status, MediaStatus.halted);
            d.expect(player.error.kind, MediaErrorKind.noBackend);
            d.expect(heard.kind, MediaErrorKind.noBackend, "onError hears it");
            player.dispose();

            // Given one for all players
            auto backend = new FakeBackend;
            MediaPlayer.setBackend(backend);
            auto other = new MediaPlayer(new Media("/clip.ogg"));
            d.expect(backend.sessions.length, 1, "the chosen backend's used");
            other.dispose();
            MediaPlayer.setBackend(null);
        });
    });
}

/// A view shows each frame, kept to its shape, filling the view as `scaling` says.
void viewShowsFrames()
{
    MediaView view;
    MediaPlayer player;
    FakeSession s;
    run("media view: frames and scaling", {
        auto backend = new FakeBackend;
        player = new MediaPlayer(new Media("/clip.ogg"), backend);
        s = backend.last;
        view = new MediaView(player).prefSize(200, 200);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(view);
    }, (Driver d) {
        Bounds b;
        d.ui({
            b = view.boundsInScene;
            d.expect(view.videoBounds, Bounds.init, "nothing to show before a frame");
            s.loaded();
            s.host.frameArrived(s.generation, new CountedFrame(0xFFFF0000, 4, 2));
            d.expect(player.media.width, 4, "the media learns its size from the frame");
        });
        d.settle();
        d.ui({
            // 4 by 2 in a 200 by 200 view: 200 by 100, in the middle
            const v = view.videoBounds;
            d.check(abs(v.width - 200) < 0.5 && abs(v.height - 100) < 0.5, format!"fit: %s"(v));
            d.check(abs(v.minY - (b.minY + 50)) < 0.5, "centred, with bars above and below");
            view.setScaling(VideoScaling.cover);
        });
        d.settle();
        d.ui({
            const v = view.videoBounds;
            d.check(abs(v.width - 400) < 0.5 && abs(v.height - 200) < 0.5, format!"cover: %s"(v));
            d.check(abs(v.minX - (b.minX - 100)) < 0.5, "cut off at the sides");
            view.setScaling(VideoScaling.stretch);
        });
        d.settle();
        d.ui({
            const v = view.videoBounds;
            d.check(abs(v.width - 200) < 0.5 && abs(v.height - 200) < 0.5, format!"stretch: %s"(v));
            view.setScaling(VideoScaling.fit);
            // Pixels half as wide as they're tall: 4 by 2 of them is square
            s.host.frameArrived(s.generation, new CountedFrame(0xFF00FF00, 4, 2, 0.5));
        });
        d.settle();
        d.ui({
            const v = view.videoBounds;
            d.check(abs(v.width - 200) < 0.5 && abs(v.height - 200) < 0.5, format!"narrow pixels, made square: %s"(v));
            // Its natural size is the video's: a view with no size of its own
            s.host.frameArrived(s.generation, new CountedFrame(0xFF00FF00, 8, 4));
            view.setPrefWidth(float.nan);
            view.setPrefHeight(float.nan);
        });
        d.settle();
        d.ui({
            const v = view.boundsInScene;
            d.check(abs(v.width - 8) < 0.5 && abs(v.height - 4) < 0.5, format!"the video's own size: %s"(v));
            player.dispose();
        });
        d.settle();
        d.ui({ d.expect(view.videoBounds, Bounds.init, "nothing shown once the player's gone"); });
    });
}

/// A view taken out of the window, or moved, leaves its player playing; put back, it shows its frame at once.
void viewDetachAndReattach()
{
    MediaView view;
    MediaPlayer player;
    FakeSession s;
    Column left, right;
    run("media view: detached, moved, put back", {
        auto backend = new FakeBackend;
        player = new MediaPlayer(new Media("/clip.ogg"), backend);
        s = backend.last;
        view = new MediaView(player).prefSize(160, 90);
        left = new Column();
        right = new Column();
        return cast(Widget) new Row().padding(20).spacing(20).add(left.add(view)).add(right);
    }, (Driver d) {
        d.ui({
            s.loaded();
            player.play();
            s.state(SessionState.playing);
            s.host.frameArrived(s.generation, new CountedFrame(0xFFFF0000, 16, 9));
        });
        d.settle();
        d.ui({
            d.check(view.videoBounds.width > 0, "showing");
            left.remove(view);
        });
        d.settle();
        d.ui({
            d.expect(player.status, MediaStatus.playing, "taken out of the window, it plays on");
            d.check(!s.disposed, "its session too");
            // Frames go on arriving, with nothing showing them
            s.host.frameArrived(s.generation, new CountedFrame(0xFF0000FF, 16, 9));
            right.add(view);
        });
        d.settle();
        d.ui({
            d.check(view.videoBounds.width > 0, "put back elsewhere, it shows the current frame at once");
            d.check(view.videoBounds.minX >= right.boundsInScene.minX, "where it is now");
            // Another player: the first plays on, unseen
            auto other = new MediaPlayer(new Media("/other.ogg"), new FakeBackend);
            view.setMediaPlayer(other);
        });
        d.settle();
        d.ui({
            d.expect(view.videoBounds, Bounds.init, "the other player has no frame yet");
            d.expect(player.status, MediaStatus.playing, "the first plays on");
            view.mediaPlayer.dispose();
            player.dispose();
        });
    });
}
