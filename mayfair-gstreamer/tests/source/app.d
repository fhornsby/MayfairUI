import core.stdc.stdlib : exit;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind;
import std.file : dirEntries, SpanMode, tempDir, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.stdio : writefln, writeln;
import harness;
import mayfair;
import mayfair.media;
import mayfair.media.gstreamer;

/*
    End-to-end tests for mayfair-gstreamer: real media, played by the system's GStreamer, in real
    windows (see mayfair/tests' harness). The sound goes to a fakesink that keeps time as though
    it played, so they run where there's no sound card; everything else is as an app has it.

        cd tests && dub run

    Skipped, saying why, where GStreamer isn't installed.
*/
void main()
{
    string why;
    if (!GStreamerBackend.available(why))
    {
        writeln("skip  mayfair-gstreamer: ", why);
        return;
    }
    MediaPlayer.setBackend(new GStreamerBackend("fakesink sync=true"));
    loading();
    playingToTheEnd();
    pausingAndSeeking();
    looping();
    volumeAndMute();
    replacingTheMedia();
    errors();
    viewDetachedAndPutBack();
    disposalWhileLoadingAndPlaying();
    writefln("%s passed, %s failed checks", passedCount, failedChecks);
    exit(failedChecks ? 1 : 0);
}

string clip(string name) { return buildPath(dirName(__FILE_FULL_PATH__), "..", "assets", name); }

/// Waits, checking on the UI thread, until `ok`; false if it doesn't happen in time.
bool waitFor(Driver d, bool delegate() ok, Duration timeout = 10.seconds)
{
    const deadline = MonoTime.currTime + timeout;
    while (MonoTime.currTime < deadline)
    {
        bool done;
        d.ui({ done = ok(); });
        if (done)
            return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

/// The colour in the middle of the player's current frame, as 0xRRGGBB, or -1 with none.
long centre(MediaPlayer player)
{
    auto f = player.currentFrame;
    if (!f)
        return -1;
    size_t stride;
    auto px = f.map(stride);
    if (!px)
        return -1;
    scope (exit) f.unmap();
    const at = (f.height / 2) * stride + (f.width / 2) * 4;
    return px[at + 2] << 16 | px[at + 1] << 8 | px[at]; // BGRA bytes
}

bool isRed(long c) { return c >= 0 && (c >> 16 & 0xFF) > 200 && (c >> 8 & 0xFF) < 60 && (c & 0xFF) < 60; }
bool isBlue(long c) { return c >= 0 && (c >> 16 & 0xFF) < 60 && (c >> 8 & 0xFF) < 60 && (c & 0xFF) > 200; }
bool isGreen(long c) { return c >= 0 && (c >> 16 & 0xFF) < 60 && (c >> 8 & 0xFF) > 200 && (c & 0xFF) < 60; }

bool near(Duration a, Duration b, Duration by = 60.msecs) { return a - b < by && b - a < by; }

/// Loaded: ready, at the start, with what it found out, and its first frame shown.
void loading()
{
    MediaPlayer player;
    MediaView view;
    int readies;
    run("gstreamer: loading", {
        player = new MediaPlayer(new Media(clip("red-blue.ogg")));
        player.onReady({ readies++; });
        view = new MediaView(player).prefSize(320, 240);
        return cast(Widget) new Column().padding(20).fillWidth(false).add(view);
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        d.check(waitFor(d, () => view.videoBounds.width > 0), "its first frame shown");
        d.ui({
            auto m = player.media;
            d.expect(readies, 1);
            d.check(near(m.duration, 2.seconds), format!"two seconds long: %s"(m.duration));
            d.expect(m.width, 160);
            d.expect(m.height, 120);
            d.check(m.tracks.canFind!(t => t.kind == TrackKind.video && t.codec.canFind("Theora")),
                    format!"a Theora video track: %s"(m.tracks));
            d.check(m.tracks.canFind!(t => t.kind == TrackKind.audio && t.codec.canFind("Vorbis")),
                    format!"a Vorbis audio track: %s"(m.tracks));
            d.check(isRed(centre(player)), format!"the first frame's red: %06x"(centre(player)));
            d.expect(player.currentTime, Duration.zero, "at the start");
            const v = view.videoBounds, b = view.boundsInScene;
            d.check(v.width == b.width && v.height == b.height, format!"4:3 in a 4:3 view, filling it: %s"(v));
            player.dispose();
        });
    });
}

/// Played: playing, its time going on, to the end, where it stops; and again from the start.
void playingToTheEnd()
{
    MediaPlayer player;
    int ends;
    run("gstreamer: playing to the end", {
        player = new MediaPlayer(new Media(clip("red-blue.ogg")));
        player.onEndOfMedia({ ends++; });
        return cast(Widget) new MediaView(player).prefSize(160, 120);
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        MonoTime started = MonoTime.currTime;
        d.ui({ player.play(); });
        d.check(waitFor(d, () => player.status == MediaStatus.playing, 3.seconds), "playing");
        d.check(waitFor(d, () => player.currentTime > 500.msecs, 3.seconds), "its time goes on");
        d.check(waitFor(d, () => isBlue(centre(player)), 3.seconds), "blue in the second second");
        d.check(waitFor(d, () => player.status == MediaStatus.ended, 4.seconds), "ended");
        const took = MonoTime.currTime - started;
        d.check(took > 1800.msecs && took < 3500.msecs, format!"in about its own two seconds: %s"(took));
        d.ui({
            d.expect(ends, 1, "onEndOfMedia, once");
            d.expect(player.currentTime, player.media.duration, "at the end");
            d.expect(player.currentCount, 1);
        });
        Thread.sleep(300.msecs);
        d.ui({ d.expect(player.status, MediaStatus.ended, "and stays ended"); player.play(); });
        d.check(waitFor(d, () => player.status == MediaStatus.playing, 3.seconds), "play: playing again");
        d.ui({ d.check(player.currentTime < 1.seconds, format!"from the start: %s"(player.currentTime)); });
        d.check(waitFor(d, () => isRed(centre(player)), 2.seconds), "red again");
        d.ui({ player.dispose(); });
    });
}

/// Paused, it stays where it is; seeking shows the frame it's gone to, paused or playing.
void pausingAndSeeking()
{
    MediaPlayer player;
    run("gstreamer: pausing and seeking", {
        player = new MediaPlayer(new Media(clip("red-blue.ogg")));
        return cast(Widget) new MediaView(player).prefSize(160, 120);
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        d.ui({ player.play(); });
        d.check(waitFor(d, () => player.currentTime > 300.msecs, 3.seconds), "playing");
        d.ui({ player.pause(); });
        d.check(waitFor(d, () => player.status == MediaStatus.paused, 3.seconds), "paused");
        Duration at;
        d.ui({ at = player.currentTime; });
        Thread.sleep(400.msecs);
        d.ui({ d.check(near(player.currentTime, at), format!"still: %s, then %s"(at, player.currentTime)); });

        // Paused: the frame it's gone to
        d.ui({ player.seek(1500.msecs); d.expect(player.currentTime, 1500.msecs, "at once"); });
        d.check(waitFor(d, () => isBlue(centre(player)), 3.seconds), "seeking while paused shows the blue second");
        d.ui({ player.seek(250.msecs); });
        d.check(waitFor(d, () => isRed(centre(player)), 3.seconds), "and back, the red one");
        d.ui({
            d.check(near(player.currentTime, 250.msecs), format!"where it was sent: %s"(player.currentTime));
            d.expect(player.status, MediaStatus.paused, "still paused");
        });

        // Playing: on from there
        d.ui({ player.play(); });
        d.check(waitFor(d, () => player.status == MediaStatus.playing, 3.seconds), "playing");
        d.ui({ player.seek(1800.msecs); });
        Thread.sleep(50.msecs);
        d.ui({ d.check(player.status == MediaStatus.playing, format!"playing through the seek: %s"(player.status)); });
        d.check(waitFor(d, () => player.status == MediaStatus.ended, 2.seconds), "ending soon after a seek near the end");

        // Stopped: at the start, still
        d.ui({ player.stop(); });
        d.check(waitFor(d, () => isRed(centre(player)), 3.seconds), "stop shows the start");
        d.ui({
            d.expect(player.status, MediaStatus.stopped);
            d.expect(player.currentTime, Duration.zero);
            player.dispose();
        });
    });
}

/// A short clip looped plays round and round, without stopping.
void looping()
{
    MediaPlayer player;
    int repeats;
    run("gstreamer: looping", {
        player = new MediaPlayer(new Media(clip("green.ogg")));
        player.setCycleCount(MediaPlayer.indefinite);
        player.onRepeat({ repeats++; });
        return cast(Widget) new MediaView(player).prefSize(160, 120);
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        d.ui({ player.play(); });
        d.check(waitFor(d, () => repeats >= 2, 5.seconds), "round twice, in a second's clip");
        d.ui({
            d.expect(player.status, MediaStatus.playing, "still playing");
            d.check(player.currentCount >= 2, format!"counted: %s"(player.currentCount));
            d.check(player.currentTime < 1100.msecs, format!"within the clip: %s"(player.currentTime));
            player.dispose();
        });
    });
}

/// Volume and mute go to GStreamer, which goes on playing.
void volumeAndMute()
{
    MediaPlayer player;
    run("gstreamer: volume and mute", {
        player = new MediaPlayer(new Media(clip("red-blue.ogg")));
        return cast(Widget) new MediaView(player).prefSize(160, 120);
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        d.ui({ player.setVolume(0.3); player.setMute(true); player.play(); });
        d.check(waitFor(d, () => player.currentTime > 300.msecs, 3.seconds), "plays, quietly");
        d.ui({ player.setMute(false); player.setVolume(0); });
        d.check(waitFor(d, () => player.currentTime > 600.msecs, 3.seconds), "and on");
        d.ui({ d.check(!player.error, "no error"); player.dispose(); });
    });
}

/// Other media, given to the same player: nothing of the first shows after, and the second plays.
void replacingTheMedia()
{
    MediaPlayer player;
    MediaView view;
    run("gstreamer: replacing the media", {
        player = new MediaPlayer(new Media(clip("red-blue.ogg")));
        view = new MediaView(player).prefSize(160, 120);
        return cast(Widget) view;
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        d.ui({ player.play(); });
        d.check(waitFor(d, () => player.currentTime > 200.msecs, 3.seconds), "playing the first");

        // Every frame from here on is watched: none may be the first media's
        long[] seen;
        auto watcher = new class FrameWatcher { void frameChanged() { seen ~= centre(player); } };
        d.ui({
            player.setMedia(new Media(clip("green.ogg")));
            d.expect(player.status, MediaStatus.unknown, "loading the second");
            d.check(player.currentFrame is null, "the first's frame gone at once");
            player.watch(watcher);
        });
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "the second ready");
        d.check(waitFor(d, () => isGreen(centre(player)), 3.seconds), "and showing");
        d.ui({
            d.expect(player.media.width, 320, "its size");
            d.check(near(player.media.duration, 1.seconds), "its duration");
            player.play();
        });
        d.check(waitFor(d, () => player.status == MediaStatus.playing, 3.seconds), "playing the second");
        Thread.sleep(300.msecs);
        d.ui({
            player.unwatch(watcher);
            foreach (c; seen)
                if (c != -1 && !isGreen(c))
                    d.fail(format!"a frame of the first media after the second was given: %06x"(c));
            d.check(seen.length > 0, "frames of the second seen");
            player.dispose();
        });

        // Replaced over and over, quickly, while loading: the last one wins
        d.ui({
            player = new MediaPlayer;
            view.setMediaPlayer(player);
            foreach (i; 0 .. 10)
                player.setMedia(new Media(clip(i % 2 ? "red-blue.ogg" : "green.ogg")));
        });
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "the last ready");
        d.check(waitFor(d, () => player.currentFrame !is null, 3.seconds), "with a frame");
        d.ui({
            d.expect(player.media.width, 160, "the last media's");
            d.check(isRed(centre(player)), "and its frame");
            player.dispose();
        });
    });
}

/// What can't be played says why.
void errors()
{
    MediaPlayer missing, notMedia;
    MediaError heard;
    run("gstreamer: errors", {
        missing = new MediaPlayer(new Media("/nowhere/at/all.ogg"));
        missing.onError((e) { heard = e; });
        const text = buildPath(tempDir, "mayfair-not-media.ogg");
        write(text, "This is plain text, not a video, whatever its name says.\n");
        notMedia = new MediaPlayer(new Media(text));
        return cast(Widget) new Label("Errors");
    }, (Driver d) {
        d.check(waitFor(d, () => missing.status == MediaStatus.halted), "a file that isn't there halts");
        d.ui({
            d.expect(missing.error.kind, MediaErrorKind.notFound, format!"not found: %s"(missing.error));
            d.check(missing.error.message.length > 0, "with a message");
            d.expect(heard.kind, MediaErrorKind.notFound, "onError heard it");
            missing.play();
            d.expect(missing.status, MediaStatus.halted, "and play does nothing");
        });
        d.check(waitFor(d, () => notMedia.status == MediaStatus.halted), "a file that isn't media halts");
        d.ui({
            d.check(notMedia.error.kind == MediaErrorKind.unsupported || notMedia.error.kind == MediaErrorKind.corrupt,
                    format!"as unplayable: %s %s"(notMedia.error.kind, notMedia.error));
            // The same player, given something it can play, plays
            notMedia.setMedia(new Media(clip("green.ogg")));
        });
        d.check(waitFor(d, () => notMedia.status == MediaStatus.ready),
                format!"recovers with other media: %s %s %s"(notMedia.status, notMedia.error.kind, notMedia.error));
        d.ui({ missing.dispose(); notMedia.dispose(); });
    });
}

/// A view taken out of the window leaves its player playing; put back, it shows its frame at once.
void viewDetachedAndPutBack()
{
    MediaPlayer player;
    MediaView view;
    Column holder;
    run("gstreamer: view taken out and put back", {
        player = new MediaPlayer(new Media(clip("red-blue.ogg")));
        player.setCycleCount(MediaPlayer.indefinite);
        view = new MediaView(player).prefSize(160, 120);
        holder = new Column().padding(20).fillWidth(false);
        return cast(Widget) holder.add(view);
    }, (Driver d) {
        d.check(waitFor(d, () => player.status == MediaStatus.ready), "ready");
        d.ui({ player.play(); });
        d.check(waitFor(d, () => player.currentTime > 200.msecs, 3.seconds), "playing");
        d.ui({ holder.remove(view); });
        Duration then;
        d.ui({ then = player.currentTime; });
        Thread.sleep(500.msecs);
        d.ui({
            d.expect(player.status, MediaStatus.playing, "out of the window, it plays on");
            d.check(player.currentTime != then, "its time going on");
            holder.add(view);
        });
        d.settle();
        d.ui({ d.check(view.videoBounds.width > 0, "back, it shows a frame straight away"); });
        d.ui({ player.dispose(); });
        d.settle();
        d.ui({ d.check(view.videoBounds.width == 0, "and nothing once the player's disposed of"); });
    });
}

/// Disposed of while loading, while playing, and made and disposed of over and over: the UI never
/// waits for it, and every thread it started ends.
void disposalWhileLoadingAndPlaying()
{
    run("gstreamer: disposal", { return cast(Widget) new Label("Disposal"); }, (Driver d) {
        const threadsBefore = threadCount();
        Duration slowest;
        // While loading: disposed of as soon as it's made
        d.ui({
            foreach (i; 0 .. 30)
            {
                auto p = new MediaPlayer(new Media(clip(i % 2 ? "red-blue.ogg" : "green.ogg")));
                const t = MonoTime.currTime;
                p.dispose();
                const took = MonoTime.currTime - t;
                if (took > slowest)
                    slowest = took;
            }
        });
        // While playing
        MediaPlayer[] playing;
        d.ui({
            foreach (i; 0 .. 8)
            {
                auto p = new MediaPlayer(new Media(clip("red-blue.ogg")));
                p.setAutoPlay(true);
                playing ~= p;
            }
        });
        d.check(waitFor(d, () => playing.canFind!(p => p.status == MediaStatus.playing)), "playing");
        d.ui({
            foreach (p; playing)
            {
                const t = MonoTime.currTime;
                p.dispose();
                const took = MonoTime.currTime - t;
                if (took > slowest)
                    slowest = took;
                d.expect(p.status, MediaStatus.disposed);
            }
        });
        d.check(slowest < 20.msecs, format!"dispose() never keeps the UI thread waiting: the slowest took %s"(slowest));
        d.check(waitFor(() => threadCount() <= threadsBefore + 2, 10.seconds),
                format!"every session's thread, and GStreamer's, ended: %s, from %s"(threadCount(), threadsBefore));
    });
}

bool waitFor(bool delegate() ok, Duration timeout)
{
    const deadline = MonoTime.currTime + timeout;
    while (MonoTime.currTime < deadline)
    {
        if (ok())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

/// How many threads the process has: Linux's count of them.
size_t threadCount()
{
    version (linux)
    {
        size_t n;
        foreach (e; dirEntries("/proc/self/task", SpanMode.shallow))
            n++;
        return n;
    }
    else
        return 0;
}
