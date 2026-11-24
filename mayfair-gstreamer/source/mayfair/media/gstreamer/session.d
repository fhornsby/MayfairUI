module mayfair.media.gstreamer.session;

/*
    One MediaPlayer's playback, on GStreamer: a playbin, which finds the demuxer and decoders for
    whatever it's given, keeps audio and video in step, buffers what it streams, and plays the
    sound -- with Mayfair's own sink for the video, an appsink taking frames as BGRA, which the
    player's MediaViews show.

    Each session has a thread of its own, which does everything that can wait: starting
    GStreamer, building and loading the pipeline, changing its state, seeking, and taking it down.
    The UI thread only queues commands for it, and wakes it; it tells the UI thread what happened
    with Platform.runLater. GStreamer's own streaming threads hand frames to the UI thread through
    a FrameMailbox, which holds the newest only: a bounded queue of one, so a slow frame is
    dropped rather than queued.

    Everything told to the UI thread carries the generation being played, which the player checks:
    media loaded since, or a player disposed of, gets nothing late. A new load stops the pipeline
    and flushes its bus before it opens the new media, so nothing of the old one is even sent.
*/

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, nsecs, seconds;
import std.string : fromStringz, toStringz;
import mayfair.media.backend;
import mayfair.media.media;
import mayfair.media.gstreamer.gst;
import mayfair.windowing.platform : Platform;

package(mayfair.media):

final class GstSession : MediaSession
{
    this(MediaSessionHost host, string audioSink)
    {
        this.host = host;
        this.audioSink = audioSink;
        lock = new Mutex;
        wake = new Condition(lock);
        mailbox = new FrameMailbox(&deliverFrame, &releaseSample);
        synchronized (liveLock)
            live ~= this;
        thread = new Thread(&run);
        thread.isDaemon = true; // taken down by the module's destructor, if the app leaves it playing
        thread.start();
    }

    // The UI thread's side: each queues a command, and wakes the session's thread

    void load(string uri, uint generation) { send(Command(Kind.load, uri, generation)); }
    void play() { send(Command(Kind.play)); }
    void pause() { send(Command(Kind.pause)); }
    void seek(Duration position, uint serial) { send(Command(Kind.seek, null, 0, position, serial)); }
    void setVolume(double volume) { auto c = Command(Kind.volume); c.volume = volume; send(c); }
    void setMute(bool mute) { auto c = Command(Kind.mute); c.flag = mute; send(c); }

    void dispose()
    {
        if (disposed)
            return;
        send(Command(Kind.dispose));
        disposed = true;
        mailbox.close(); // whatever's waiting, and arrives from now on, is let go of at once
    }

private:
    enum Kind { load, play, pause, seek, volume, mute, dispose }

    struct Command
    {
        Kind kind;
        string uri;
        uint generation;
        Duration position;
        uint serial;
        double volume = 1;
        bool flag;
    }

    MediaSessionHost host;
    string audioSink;
    Thread thread;
    FrameMailbox mailbox;
    bool disposed;          // the UI thread's: dispose() was called

    // Shared between the threads, under `lock`
    Mutex lock;
    Condition wake;         // a command's arrived, for the thread waiting without a pipeline
    Command[] commands;
    void* wakeBus;          // the bus, while there's one to post a wake-up on

    // Read by GStreamer's streaming threads, as they post frames
    shared uint frameGeneration;

    // The session thread's own
    void* pipeline, appsink, bus;
    uint generation;
    bool loadedMedia, prerolled, wantPlaying, buffering, seekInFlight, failedMedia;
    double volume = 1;
    bool muted;
    bool pendingSeek;
    Duration pendingPosition;
    uint pendingSerial, serialApplied;
    int currentState = GST_STATE_NULL;
    MonoTime lastPositionSent;
    string[string] tags;
    string startFailure;

    void send(Command c)
    {
        if (disposed)
            return;
        synchronized (lock)
        {
            commands ~= c;
            wake.notify();
            if (wakeBus)
                gstreamer.gst.bus_post(wakeBus, gstreamer.gst.message_new_application(null,
                                       gstreamer.gst.structure_new_empty("mayfair-wake")));
        }
    }

    Command[] take()
    {
        synchronized (lock)
        {
            auto taken = commands;
            commands = null;
            return taken;
        }
    }

    /// Tells the player something, on the UI thread.
    void tell(void delegate() news)
    {
        Platform.runLater(news);
    }

    // The session's thread

    void run()
    {
        startGStreamer(startFailure);
        scope (exit) takeDown();
        while (true)
        {
            foreach (c; take())
            {
                if (c.kind == Kind.dispose)
                    return;
                apply(c);
            }
            if (!bus)
            {
                // Nothing loaded: only the next command to wait for
                synchronized (lock)
                    if (!commands.length)
                        wake.wait(1.seconds);
                continue;
            }
            const playing = currentState == GST_STATE_PLAYING;
            auto message = gstreamer.gst.bus_timed_pop(bus, (playing ? 50.msecs : 250.msecs).total!"nsecs");
            if (message)
            {
                handle(message);
                gstreamer.gst.mini_object_unref(message);
            }
            if (playing)
                sendPosition(false);
        }
    }

    /*
        Makes a pipeline, for one media: a playbin, with an appsink for the video. The reason, if
        it can't. Each media has a new one, so nothing the last one does as it stops -- GStreamer
        can post an error from a streaming thread after it's been told to stop -- reaches the
        next one's bus.
    */
    string build()
    {
        auto g = &gstreamer;
        pipeline = g.gst.element_factory_make("playbin", null);
        if (!pipeline)
            return "GStreamer has no playbin: its base plugins (gst-plugins-base) aren't installed";

        GError* error;
        auto videoSink = g.gst.parse_bin_from_description(
            "videoconvert ! video/x-raw,format=BGRA ! appsink name=mayfair-video", 1, &error);
        if (!videoSink)
            return "couldn't make the video sink: " ~ consume(error);
        appsink = g.gst.bin_get_by_name(videoSink, "mayfair-video");
        g.gst.object_unref(appsink); // the bin holds it, for as long as the pipeline's there
        // Two frames at most, the oldest dropped, and each shown when the clock says
        g.gobject.object_set(appsink, "max-buffers", cast(uint) 2, "drop".ptr, 1, "sync".ptr, 1,
                             "enable-last-sample".ptr, 0, cast(void*) null);
        GstAppSinkCallbacks callbacks;
        callbacks.newSample = &newSample;
        callbacks.newPreroll = &newPreroll;
        g.app.sink_set_callbacks(appsink, &callbacks, cast(void*) this, null);
        g.gobject.object_set(pipeline, "video-sink", videoSink, cast(void*) null);

        if (audioSink.length)
        {
            auto sound = g.gst.parse_bin_from_description(audioSink.toStringz, 1, &error);
            if (!sound)
                return "couldn't make the audio sink \"" ~ audioSink ~ "\": " ~ consume(error);
            g.gobject.object_set(pipeline, "audio-sink", sound, cast(void*) null);
        }

        g.gobject.object_set(pipeline, "volume", volume, cast(void*) null);
        g.gobject.object_set(pipeline, "mute", muted ? 1 : 0, cast(void*) null);
        bus = g.gst.element_get_bus(pipeline);
        synchronized (lock)
            wakeBus = bus;
        return null;
    }

    /// Stops the pipeline and lets go of it: its threads have stopped by the time this returns.
    void destroyPipeline()
    {
        synchronized (lock)
            wakeBus = null;
        if (pipeline)
        {
            gstreamer.gst.element_set_state(pipeline, GST_STATE_NULL); // waits for its threads
            gstreamer.gst.object_unref(pipeline);
        }
        if (bus)
            gstreamer.gst.object_unref(bus);
        pipeline = appsink = bus = null;
        mailbox.clear();
        currentState = GST_STATE_NULL;
    }

    void apply(ref Command c)
    {
        auto g = &gstreamer;
        if (c.kind == Kind.load)
        {
            generation = c.generation;
            if (startFailure.length)
            {
                const gen = generation, why = startFailure;
                tell({ host.failed(gen, MediaError(MediaErrorKind.backendUnavailable, why)); });
                return;
            }
            // Stop what was playing, and let go of it and everything it might still say
            destroyPipeline();
            atomicStore(frameGeneration, generation);
            loadedMedia = prerolled = buffering = seekInFlight = pendingSeek = wantPlaying = failedMedia = false;
            serialApplied = 0;
            tags = null;
            const gen = generation;
            // A file that isn't there, said plainly: GStreamer's own error for it is vague
            if (auto missing = missingFile(c.uri))
            {
                tell({ host.failed(gen, MediaError(MediaErrorKind.notFound, "There's no file there", missing)); });
                return;
            }
            if (auto why = build())
            {
                destroyPipeline();
                tell({ host.failed(gen, MediaError(MediaErrorKind.backendUnavailable, why)); });
                return;
            }
            loadedMedia = true;
            currentState = GST_STATE_READY;
            g.gobject.object_set(pipeline, "uri", c.uri.toStringz, cast(void*) null);
            g.gst.element_set_state(pipeline, GST_STATE_PAUSED);
            return;
        }
        if (c.kind == Kind.volume)
            volume = c.volume;
        if (c.kind == Kind.mute)
            muted = c.flag;
        if (!pipeline)
            return;
        if (c.kind == Kind.volume)
            g.gobject.object_set(pipeline, "volume", volume, cast(void*) null);
        if (c.kind == Kind.mute)
            g.gobject.object_set(pipeline, "mute", muted ? 1 : 0, cast(void*) null);
        final switch (c.kind)
        {
            case Kind.load, Kind.dispose:
                break;
            case Kind.play:
                wantPlaying = true;
                if (!loadedMedia)
                    break;
                if (currentState == GST_STATE_PLAYING)
                    sendState(SessionState.playing); // already: say so again, for the player asking
                else if (!buffering)
                    g.gst.element_set_state(pipeline, GST_STATE_PLAYING);
                break;
            case Kind.pause:
                wantPlaying = false;
                if (loadedMedia)
                    g.gst.element_set_state(pipeline, GST_STATE_PAUSED);
                break;
            case Kind.seek:
                if (!prerolled)
                {
                    // Nothing to seek in yet: once it's loaded
                    pendingSeek = true;
                    pendingPosition = c.position;
                    pendingSerial = c.serial;
                }
                else
                    seekTo(c.position, c.serial);
                break;
            case Kind.volume, Kind.mute:
                break; // done before the switch, as they're kept with no pipeline too
        }
    }

    void seekTo(Duration position, uint serial)
    {
        serialApplied = serial;
        seekInFlight = gstreamer.gst.element_seek_simple(pipeline, GST_FORMAT_TIME,
                                                          GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE,
                                                          position.total!"nsecs") != 0;
        if (!seekInFlight)
            sendPosition(true); // couldn't: say where it still is
    }

    void handle(void* message)
    {
        auto g = &gstreamer;
        const gen = generation;
        switch (messageType(message))
        {
            case GST_MESSAGE_ERROR:
            {
                if (failedMedia)
                    break; // said already: what follows an error is more of the same
                // GStreamer often says something general first -- "state change failed" -- and why
                // just after, from the element that knows: the most particular of them is kept
                auto e = parseError(message);
                const deadline = MonoTime.currTime + 100.msecs;
                for (auto left = deadline - MonoTime.currTime; left > Duration.zero; left = deadline - MonoTime.currTime)
                {
                    auto next = g.gst.bus_timed_pop(bus, left.total!"nsecs");
                    if (!next)
                        break;
                    if (messageType(next) == GST_MESSAGE_ERROR && e.kind == MediaErrorKind.other)
                        e = parseError(next);
                    g.gst.mini_object_unref(next);
                }
                wantPlaying = false;
                failedMedia = true;
                g.gst.element_set_state(pipeline, GST_STATE_READY); // stop the sound, and the threads
                currentState = GST_STATE_READY;
                loadedMedia = false;
                tell({ host.failed(gen, e); });
                break;
            }

            case GST_MESSAGE_EOS:
            {
                tell({ host.ended(gen); });
                break;
            }

            case GST_MESSAGE_STATE_CHANGED:
            {
                if (messageSource(message) !is pipeline)
                    break;
                int was, now, pending;
                g.gst.message_parse_state_changed(message, &was, &now, &pending);
                currentState = now;
                if (now == GST_STATE_PLAYING)
                    sendState(SessionState.playing);
                else if (now == GST_STATE_PAUSED && was == GST_STATE_PLAYING && !buffering
                         && !(seekInFlight && wantPlaying)) // a seek's pause on the way, not the user's
                    sendState(SessionState.paused);
                break;
            }

            case GST_MESSAGE_ASYNC_DONE:
            {
                if (!loadedMedia)
                    break;
                if (!prerolled)
                {
                    prerolled = true;
                    auto info = gather();
                    tell({ host.loaded(gen, info); });
                    if (currentState == GST_STATE_PLAYING)
                        sendState(SessionState.playing);
                    if (pendingSeek)
                    {
                        pendingSeek = false;
                        seekTo(pendingPosition, pendingSerial);
                    }
                }
                else if (seekInFlight)
                {
                    seekInFlight = false;
                    sendPosition(true);
                }
                break;
            }

            case GST_MESSAGE_DURATION_CHANGED:
            {
                if (prerolled)
                {
                    auto info = gather();
                    tell({ host.infoChanged(gen, info); });
                }
                break;
            }

            case GST_MESSAGE_BUFFERING:
            {
                // A stream, filling its buffer: playback waits for it, as GStreamer asks apps to
                int percent;
                g.gst.message_parse_buffering(message, &percent);
                const progress = percent / 100.0;
                tell({ host.bufferingChanged(gen, progress); });
                if (percent < 100 && !buffering)
                {
                    buffering = true;
                    if (wantPlaying)
                    {
                        g.gst.element_set_state(pipeline, GST_STATE_PAUSED);
                        sendState(SessionState.stalled);
                    }
                }
                else if (percent >= 100 && buffering)
                {
                    buffering = false;
                    if (wantPlaying)
                        g.gst.element_set_state(pipeline, GST_STATE_PLAYING);
                }
                break;
            }

            case GST_MESSAGE_TAG:
            {
                void* list;
                g.gst.message_parse_tag(message, &list);
                if (!list)
                    break;
                bool changed;
                foreach (name; ["title", "artist", "album", "genre", "comment", "description", "copyright",
                                "container-format"])
                    if (auto value = tag(list, name))
                        if (tags.get(name, null) != value)
                        {
                            tags[name] = value;
                            changed = true;
                        }
                g.gst.mini_object_unref(list);
                if (changed && prerolled)
                {
                    MediaInfo info;
                    info.metadata = tags.dup;
                    tell({ host.infoChanged(gen, info); });
                }
                break;
            }

            case GST_MESSAGE_CLOCK_LOST:
            {
                // The audio device went, say: a new clock, by pausing and playing again
                if (wantPlaying)
                {
                    g.gst.element_set_state(pipeline, GST_STATE_PAUSED);
                    g.gst.element_set_state(pipeline, GST_STATE_PLAYING);
                }
                break;
            }

            default:
            {
                break; // a wake-up from send(), or nothing this needs
            }
        }
    }

    void sendState(SessionState state)
    {
        const gen = generation;
        tell({ host.stateChanged(gen, state); });
    }

    /// Where playback's got to: every 50ms while it plays, or now if `now`.
    void sendPosition(bool now)
    {
        if (!prerolled || seekInFlight)
            return;
        const at = MonoTime.currTime;
        if (!now && at - lastPositionSent < 50.msecs)
            return;
        lastPositionSent = at;
        long position;
        if (!gstreamer.gst.element_query_position(pipeline, GST_FORMAT_TIME, &position) || position < 0)
            return;
        const gen = generation, serial = serialApplied, p = nsecs(position);
        tell({ host.positionChanged(gen, serial, p); });
    }

    /// What's known about the media now: its duration, video size, tracks and tags.
    MediaInfo gather()
    {
        auto g = &gstreamer;
        MediaInfo info;
        long duration;
        if (g.gst.element_query_duration(pipeline, GST_FORMAT_TIME, &duration) && duration >= 0)
        {
            info.duration = nsecs(duration);
            info.durationKnown = info.seekable = true;
        }
        int videos, audios, texts;
        g.gobject.object_get(pipeline, "n-video", &videos, "n-audio".ptr, &audios, "n-text".ptr, &texts, cast(void*) null);
        void tracksOf(TrackKind kind, int count, const(char)* signal, string codecTag)
        {
            foreach (i; 0 .. count)
            {
                Track t;
                t.kind = kind;
                t.index = i;
                void* list;
                g.gobject.signal_emit_by_name(pipeline, signal, i, &list);
                if (list)
                {
                    t.codec = tag(list, codecTag);
                    t.language = tag(list, "language-code");
                    t.name = tag(list, "title");
                    g.gst.mini_object_unref(list);
                }
                info.tracks ~= t;
            }
        }
        tracksOf(TrackKind.video, videos, "get-video-tags", "video-codec");
        tracksOf(TrackKind.audio, audios, "get-audio-tags", "audio-codec");
        tracksOf(TrackKind.subtitle, texts, "get-text-tags", "subtitle-codec");

        // The video's size, as decoded
        if (videos > 0)
        {
            void* pad;
            g.gobject.signal_emit_by_name(pipeline, "get-video-pad", 0, &pad);
            if (pad)
            {
                if (auto caps = g.gst.pad_get_current_caps(pad))
                {
                    auto s = g.gst.caps_get_structure(caps, 0);
                    int w, h, n = 1, d = 1;
                    if (s && g.gst.structure_get_int(s, "width", &w) && g.gst.structure_get_int(s, "height", &h))
                    {
                        info.width = w;
                        info.height = h;
                        if (g.gst.structure_get_fraction(s, "pixel-aspect-ratio", &n, &d) && n > 0 && d > 0)
                            info.pixelAspectRatio = cast(float) n / d;
                    }
                    g.gst.mini_object_unref(caps);
                }
                g.gst.object_unref(pad);
            }
        }
        info.metadata = tags.dup;
        return info;
    }

    /// The path of the file `uri` names, if it's a file:// URI and there's no such file; or null.
    static string missingFile(string uri)
    {
        import std.file : exists;
        import std.uri : decodeComponent;
        enum scheme = "file://";
        if (uri.length <= scheme.length || uri[0 .. scheme.length] != scheme)
            return null;
        string path;
        try
            path = decodeComponent(uri[scheme.length .. $]);
        catch (Exception)
            return null; // not one to judge: GStreamer will say
        version (Windows)
            if (path.length > 2 && path[0] == '/' && path[2] == ':')
                path = path[1 .. $]; // file:///C:/...
        return exists(path) ? null : path;
    }

    /// A tag's text from a tag list, or null.
    static string tag(void* list, string name)
    {
        char* value;
        if (!gstreamer.gst.tag_list_get_string(list, name.toStringz, &value) || !value)
            return null;
        auto s = fromStringz(value).idup;
        gstreamer.glib.free(value);
        return s;
    }

    /// An error message's error, as a MediaError.
    static MediaError parseError(void* message)
    {
        auto g = &gstreamer;
        GError* error;
        char* details;
        g.gst.message_parse_error(message, &error, &details);
        auto e = mediaError(error, details);
        if (error) g.glib.error_free(error);
        if (details) g.glib.free(details);
        return e;
    }

    /// A GStreamer error, as a MediaError.
    static MediaError mediaError(GError* error, char* details)
    {
        auto g = &gstreamer;
        MediaError e;
        e.kind = MediaErrorKind.other;
        e.message = error && error.message ? fromStringz(error.message).idup : "GStreamer failed";
        e.details = details ? fromStringz(details).idup : null;
        if (!error)
            return e;
        const code = error.code;
        if (error.domain == g.gst.resource_error_quark())
        {
            if (code == GST_RESOURCE_ERROR_NOT_FOUND)
                e.kind = MediaErrorKind.notFound;
            else if (code == GST_RESOURCE_ERROR_OPEN_READ || code == GST_RESOURCE_ERROR_READ
                     || code == GST_RESOURCE_ERROR_NOT_AUTHORIZED)
                e.kind = MediaErrorKind.unreadable;
        }
        else if (error.domain == g.gst.stream_error_quark())
        {
            if (code == GST_STREAM_ERROR_TYPE_NOT_FOUND || code == GST_STREAM_ERROR_CODEC_NOT_FOUND
                || code == GST_STREAM_ERROR_WRONG_TYPE)
                e.kind = MediaErrorKind.unsupported;
            else if (code == GST_STREAM_ERROR_DECODE || code == GST_STREAM_ERROR_DEMUX || code == GST_STREAM_ERROR_FORMAT)
                e.kind = MediaErrorKind.corrupt;
        }
        else if (error.domain == g.gst.core_error_quark() && code == GST_CORE_ERROR_MISSING_PLUGIN)
            e.kind = MediaErrorKind.unsupported;
        if (e.kind == MediaErrorKind.unsupported)
            e.details ~= (e.details.length ? "; " : "") ~ "GStreamer has no plugin for it: more of GStreamer's "
                       ~ "plugins (gst-plugins-good, -bad, -ugly, gst-libav) may play it";
        return e;
    }

    /// A GError's message, and the GError freed.
    static string consume(GError* error)
    {
        if (!error)
            return "no reason given";
        auto s = error.message ? fromStringz(error.message).idup : "no reason given";
        gstreamer.glib.error_free(error);
        return s;
    }

    /// Lets go of everything: on the session's thread, which waits here for GStreamer's to stop.
    void takeDown()
    {
        mailbox.close();
        destroyPipeline();
        synchronized (liveLock)
            foreach (i, s; live)
                if (s is this)
                {
                    live = live[0 .. i] ~ live[i + 1 .. $];
                    break;
                }
    }

    // On the UI thread, from the mailbox: a sample, as a VideoFrame for the player
    void deliverFrame(void* sample, uint gen)
    {
        if (disposed)
        {
            releaseSample(sample);
            return;
        }
        host.frameArrived(gen, new GstFrame(sample));
    }
}

/// A frame of video, in a GstSample, which it holds a reference to until it's released.
final class GstFrame : VideoFrame
{
    this(void* sample)
    {
        auto g = &gstreamer;
        int w, h, n = 1, d = 1;
        if (auto caps = g.gst.sample_get_caps(sample))
            if (auto s = g.gst.caps_get_structure(caps, 0))
            {
                g.gst.structure_get_int(s, "width", &w);
                g.gst.structure_get_int(s, "height", &h);
                if (!g.gst.structure_get_fraction(s, "pixel-aspect-ratio", &n, &d) || n <= 0 || d <= 0)
                    n = d = 1;
            }
        super(w > 0 ? w : 0, h > 0 ? h : 0, cast(float) n / d, Duration.zero);
        this.sample = sample;
    }

    override const(ubyte)[] map(out size_t stride) nothrow @nogc
    {
        if (!sample || mapped)
            return null;
        buffer = gstreamer.gst.sample_get_buffer(sample);
        if (!buffer || !gstreamer.gst.buffer_map(buffer, &info, GST_MAP_READ))
            return null;
        mapped = true;
        // BGRA rows are 4-byte aligned, so a frame's only padded if a decoder's pool padded it:
        // the rows are then evenly spread over what's mapped
        stride = height ? info.size / height : 0;
        return info.data[0 .. info.size];
    }

    override void unmap() nothrow @nogc
    {
        if (mapped)
            gstreamer.gst.buffer_unmap(buffer, &info);
        mapped = false;
    }

    override void release() nothrow @nogc
    {
        unmap();
        if (sample)
            gstreamer.gst.mini_object_unref(sample);
        sample = null;
    }

private:
    void* sample, buffer;
    GstMapInfo info;
    bool mapped;
}

/*
    The process's GStreamer, opened and started by the first session's thread. Later sessions
    wait here for it, and get the same answer. True if it's there; `failure` says why not.
*/
bool startGStreamer(out string failure)
{
    synchronized (startLock)
    {
        if (!startAttempted)
        {
            startAttempted = true;
            if (!gstreamer.load())
                startReason = gstreamer.failure;
            else
            {
                GError* error;
                if (!gstreamer.gst.init_check(null, null, &error))
                    startReason = "GStreamer couldn't start: " ~ GstSession.consume(error);
            }
        }
        failure = startReason;
        return startReason is null;
    }
}

private:

__gshared Mutex startLock, liveLock;
__gshared bool startAttempted;
__gshared string startReason;
__gshared GstSession[] live; // sessions whose threads are running: kept, for their threads and GStreamer's callbacks

shared static this()
{
    startLock = new Mutex;
    liveLock = new Mutex;
}

/*
    The app's leaving with players it never disposed of: each session's taken down on its own
    thread, as dispose() would, and waited for -- a few seconds at most -- before the runtime that
    thread runs on goes.
*/
shared static ~this()
{
    GstSession[] running;
    synchronized (liveLock)
        running = live.dup;
    foreach (s; running)
        s.dispose();
    const deadline = MonoTime.currTime + 3.seconds;
    foreach (s; running)
        while (s.thread.isRunning && MonoTime.currTime < deadline)
            Thread.sleep(5.msecs);
}

// GStreamer's streaming threads, which the D runtime doesn't know: no allocation, nothing of the runtime's

extern (C) int newSample(void* sink, void* data) nothrow @nogc
{
    auto session = cast(GstSession) data;
    if (auto sample = gstreamer.app.sink_pull_sample(sink))
        session.mailbox.post(sample, atomicLoad(session.frameGeneration));
    return GST_FLOW_OK;
}

extern (C) int newPreroll(void* sink, void* data) nothrow @nogc
{
    // The frame it's paused on: after loading, or a seek while paused
    auto session = cast(GstSession) data;
    if (auto sample = gstreamer.app.sink_pull_preroll(sink))
        session.mailbox.post(sample, atomicLoad(session.frameGeneration));
    return GST_FLOW_OK;
}

void releaseSample(void* sample) nothrow @nogc
{
    gstreamer.gst.mini_object_unref(sample);
}
