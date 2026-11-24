module mayfair.media.player;

import core.time : Duration;
import mayfair.media.backend;
import mayfair.media.media;
import mayfair.properties;

/*
    Plays a Media: JavaFX's MediaPlayer. Play, pause, stop and seek it; set how loud it is, and
    whether it loops; and watch what it's doing through its properties. A MediaView shows its
    video.

        MediaPlayer.setBackend(new GStreamerBackend);     // once, as the app starts: see below
        auto player = new MediaPlayer(new Media("/home/me/Videos/holiday.webm"));
        player.statusProperty.addListener((MediaStatus was, MediaStatus now) { ... });
        player.play();
        ...
        player.dispose();

    Everything here is on the UI thread, and nothing waits: loading, seeking, and every change
    of state happen on the backend's own thread, and the properties change when they have, not
    when they were asked for. status goes from `unknown`, while it loads, to `ready`; play() makes
    it `playing` once it is. A control that wants to show what was asked for at once -- a play
    button's icon -- can, but what the properties say is what the player is doing.

    The player outlives anything showing it: a MediaView taken out of the window, or moved to
    another, or into a fullscreen one, leaves it playing as it was, and a view put back shows its
    current frame straight away. Only dispose() stops it for good -- explicitly, as a player
    nothing refers to any more is still playing on the backend's thread, and still heard. A
    disposed player lets go of the backend's session, its thread and everything it held, without
    the UI thread waiting for any of it.

    setMedia() plays something else with the same player, from the start, paused: what a list
    whose cells are reused as it scrolls does, giving each cell's player the media of the item
    it's showing now. Nothing from the media before it -- a late frame, an error -- reaches the
    player after.

    Which backend plays it is the app's choice, made explicitly: one given to the constructor, or
    else the one given to MediaPlayer.setBackend. Mayfair has none of its own, as each plays with
    a library of its own, with a licence of its own (see mayfair-gstreamer's README). With none,
    the player halts with MediaErrorKind.noBackend.
*/
final class MediaPlayer
{
public:
    /// A player for `media`, if given -- or for whatever setMedia gives it later -- played by
    /// `backend`, or by setBackend's.
    this(Media media = null, MediaBackend backend = null)
    {
        _backend = backend;
        host = new Host(this);
        if (media)
            setMedia(media);
    }

    /// What players are played by when they weren't given a backend of their own.
    static void setBackend(MediaBackend backend)
    {
        synchronized (MediaPlayer.classinfo)
            chosen = backend;
    }

    /// ditto
    static MediaBackend backend()
    {
        synchronized (MediaPlayer.classinfo)
            return chosen;
    }

    /// For cycleCount: loops forever.
    enum int indefinite = -1;

    /// What it's playing: see setMedia.
    mixin(declareReadOnlyProperty!(Media, "media", "null"));

    /// What it's doing.
    mixin(declareReadOnlyProperty!(MediaStatus, "status", "MediaStatus.unknown"));

    /// Where it's got to. Changes as it plays, a few times a second, and at once on seek().
    mixin(declareReadOnlyProperty!(Duration, "currentTime", "Duration.zero"));

    /// How much of a stream is buffered, from 0 to 1, of what it needs to play on. A local file's is 0.
    mixin(declareReadOnlyProperty!(double, "bufferProgress", "0"));

    /// Why it halted, if it did.
    mixin(declareReadOnlyProperty!(MediaError, "error", "MediaError.init"));

    /// How loud it is, from 0 (silent) to 1 (as loud as it was recorded).
    mixin(declareProperty!(double, "volume", "1", q{ volumeChanged(); }));

    /// Whether it's silent, whatever the volume.
    mixin(declareProperty!(bool, "mute", "false", q{ if (session) session.setMute(_mute); }));

    /// How many times it plays through before it ends: 1, or indefinite to loop.
    mixin(declareProperty!(int, "cycleCount", "1"));

    /// How many times it's played through to the end, since it was loaded.
    mixin(declareReadOnlyProperty!(int, "currentCount", "0"));

    /// Whether it plays as soon as it's ready, without play().
    mixin(declareProperty!(bool, "autoPlay", "false", q{ if (_autoPlay && _status == MediaStatus.ready) play(); }));

    /// Plays `media` from now on, from the start, paused (unless autoPlay), in place of what it was playing.
    void setMedia(Media media)
    {
        if (_disposed)
            return;
        _generation++;
        dropFrame();
        wantPlaying = false;
        _setMedia(media);
        _setError(MediaError.init);
        _setCurrentTime(Duration.zero);
        _setBufferProgress(0);
        _setCurrentCount(0);
        _setStatus(MediaStatus.unknown);
        if (!media)
            return;
        if (!openSession())
            return;
        session.load(media.uri, _generation);
    }

    /// Plays, from where it is; from the start, if it had ended.
    void play()
    {
        if (!session || !_media || _status == MediaStatus.halted)
            return;
        wantPlaying = true;
        if (_status == MediaStatus.ended)
            seek(Duration.zero);
        session.play();
    }

    /// Pauses where it is.
    void pause()
    {
        if (!session || !_media || _status == MediaStatus.halted)
            return;
        wantPlaying = false;
        session.pause();
        if (_status == MediaStatus.ready)
            _setStatus(MediaStatus.paused); // already still: nothing more will say so
    }

    /// Stops, and goes back to the start.
    void stop()
    {
        if (!session || !_media || _status == MediaStatus.halted)
            return;
        wantPlaying = false;
        session.pause();
        seek(Duration.zero);
        if (_status != MediaStatus.unknown)
            _setStatus(MediaStatus.stopped);
    }

    /// Goes to `position`: from 0 to the media's duration.
    void seek(Duration position)
    {
        if (!session || !_media || _status == MediaStatus.halted)
            return;
        if (position < Duration.zero)
            position = Duration.zero;
        const d = _media.duration;
        if (d > Duration.zero && d != Media.indefinite && position > d)
            position = d;
        seekSerial++;
        _setCurrentTime(position);
        if (_status == MediaStatus.ended || (_status == MediaStatus.stopped && position > Duration.zero))
            _setStatus(MediaStatus.paused);
        session.seek(position, seekSerial);
    }

    /*
        Stops it for good, and lets go of everything it holds: the backend's session, its thread,
        its decoders, and the frame it was showing. Returns at once; what has to wait, waits on
        the backend's thread. It does nothing after this, and its status is `disposed`.
    */
    void dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _generation++;
        wantPlaying = false;
        dropFrame();
        if (session)
            session.dispose();
        session = null;
        _setStatus(MediaStatus.disposed);
    }

    /// Whether dispose() has been called.
    bool disposed() const nothrow @nogc { return _disposed; }

    /// The newest frame of video it's decoded, if any: what a MediaView shows. Its owner's until
    /// the next replaces it, so not to be kept.
    VideoFrame currentFrame() nothrow @nogc { return frame; }

    /// Called once it's ready to play, after it's loaded: once each media.
    MediaPlayer onReady(void delegate() handler) { _onReady = handler; return this; }

    /// Called each time it gets to the end: as it ends, or as it loops round to play again.
    MediaPlayer onEndOfMedia(void delegate() handler) { _onEndOfMedia = handler; return this; }

    /// Called as it loops round to the start, with cycleCount more than 1.
    MediaPlayer onRepeat(void delegate() handler) { _onRepeat = handler; return this; }

    /// Called when it halts, with why: see error.
    MediaPlayer onError(void delegate(MediaError) handler) { _onError = handler; return this; }

    /// Tells `watcher` of each new frame, on the UI thread, until unwatch(): what a MediaView
    /// does while it's in a window, and anything else that reads frames, for a thumbnail, say.
    void watch(FrameWatcher watcher)
    {
        watchers ~= watcher;
    }

    /// ditto
    void unwatch(FrameWatcher watcher)
    {
        foreach (i, w; watchers)
            if (w is watcher)
            {
                watchers = watchers[0 .. i] ~ watchers[i + 1 .. $];
                return;
            }
    }

private:
    MediaBackend _backend;
    MediaSession session;
    Host host;
    uint _generation;    // which media the session's news is for: bumped by setMedia and dispose
    uint seekSerial;     // the last seek's: positions from before it are stale
    bool wantPlaying;    // what play() and pause() last asked for
    bool _disposed;
    VideoFrame frame;
    FrameWatcher[] watchers;
    void delegate() _onReady, _onEndOfMedia, _onRepeat;
    void delegate(MediaError) _onError;

    __gshared MediaBackend chosen;

    bool openSession()
    {
        if (session)
            return true;
        auto backend = _backend ? _backend : MediaPlayer.backend;
        if (!backend)
        {
            fail(MediaError(MediaErrorKind.noBackend, "Nothing to play media with",
                            "no MediaBackend: give MediaPlayer.setBackend one, such as mayfair-gstreamer's GStreamerBackend"));
            return false;
        }
        session = backend.open(host);
        session.setVolume(_volume);
        session.setMute(_mute);
        return true;
    }

    void volumeChanged()
    {
        if (_volume < 0 || _volume > 1 || _volume != _volume)
        {
            setVolume(_volume > 1 ? 1 : _volume >= 0 ? _volume : 0);
            return;
        }
        if (session)
            session.setVolume(_volume);
    }

    void dropFrame()
    {
        if (frame)
            frame.release();
        frame = null;
        foreach (w; watchers.dup)
            w.frameChanged();
    }

    void fail(MediaError error)
    {
        wantPlaying = false;
        _setError(error);
        _setStatus(MediaStatus.halted);
        if (_onError)
            _onError(error);
    }

    void learnt(MediaInfo info)
    {
        if (!_media)
            return;
        if (info.durationKnown)
            _media._setDuration(info.duration);
        if (info.width > 0 && info.height > 0)
        {
            _media._setWidth(info.width);
            _media._setHeight(info.height);
            _media._setPixelAspectRatio(info.pixelAspectRatio > 0 ? info.pixelAspectRatio : 1);
        }
        if (info.tracks.length)
            _media._setTracks(info.tracks);
        if (info.metadata.length)
        {
            string[string] merged;
            foreach (k, v; _media.metadata)
                merged[k] = v;
            foreach (k, v; info.metadata)
                merged[k] = v;
            _media._setMetadata(merged);
        }
    }

    // The session's news, for the current media
    void loaded(MediaInfo info)
    {
        learnt(info);
        if (_status != MediaStatus.unknown)
            return;
        _setStatus(MediaStatus.ready);
        if (_onReady)
            _onReady();
        if (_autoPlay)
            wantPlaying = true;
        if (wantPlaying && session)
            session.play();
    }

    void stateChanged(SessionState state)
    {
        final switch (state)
        {
            case SessionState.playing:
                if (_status != MediaStatus.unknown && _status != MediaStatus.ended)
                    _setStatus(MediaStatus.playing);
                break;
            case SessionState.paused:
                if (_status == MediaStatus.playing || _status == MediaStatus.stalled)
                    _setStatus(MediaStatus.paused);
                break;
            case SessionState.stalled:
                if (_status == MediaStatus.playing || (wantPlaying && _status == MediaStatus.ready))
                    _setStatus(MediaStatus.stalled);
                break;
        }
    }

    void positionChanged(uint serial, Duration position)
    {
        if (serial < seekSerial || _status == MediaStatus.ended)
            return; // from before the last seek, which has set currentTime already
        _setCurrentTime(position);
    }

    void ended()
    {
        if (_status == MediaStatus.ended)
            return;
        _setCurrentCount(_currentCount + 1);
        if (_onEndOfMedia)
            _onEndOfMedia();
        if (_cycleCount == indefinite || _currentCount < _cycleCount)
        {
            // Round again, from the start, still playing
            seekSerial++;
            _setCurrentTime(Duration.zero);
            if (session)
                session.seek(Duration.zero, seekSerial);
            if (_onRepeat)
                _onRepeat();
            return;
        }
        wantPlaying = false;
        if (session)
            session.pause();
        const d = _media ? _media.duration : Duration.zero;
        if (d > Duration.zero && d != Media.indefinite)
            _setCurrentTime(d);
        _setStatus(MediaStatus.ended);
    }

    void frameArrived(VideoFrame arrived)
    {
        if (frame)
            frame.release();
        frame = arrived;
        // The frame's own size is the surest: some formats only say once they're decoding
        if (_media && (_media.width != arrived.width || _media.height != arrived.height))
        {
            _media._setWidth(arrived.width);
            _media._setHeight(arrived.height);
            _media._setPixelAspectRatio(arrived.pixelAspectRatio);
        }
        foreach (w; watchers.dup)
            w.frameChanged();
    }

    /// What the session tells, checked against the generation it's for.
    static final class Host : MediaSessionHost
    {
        MediaPlayer player;

        this(MediaPlayer player) { this.player = player; }

        bool current(uint generation) { return !player._disposed && generation == player._generation; }

        void loaded(uint g, MediaInfo info) { if (current(g)) player.loaded(info); }
        void infoChanged(uint g, MediaInfo info) { if (current(g)) player.learnt(info); }
        void stateChanged(uint g, SessionState state) { if (current(g)) player.stateChanged(state); }
        void positionChanged(uint g, uint serial, Duration position) { if (current(g)) player.positionChanged(serial, position); }
        void bufferingChanged(uint g, double progress) { if (current(g)) player._setBufferProgress(progress); }
        void ended(uint g) { if (current(g)) player.ended(); }
        void failed(uint g, MediaError error) { if (current(g)) player.fail(error); }

        void frameArrived(uint g, VideoFrame frame)
        {
            if (current(g))
                player.frameArrived(frame);
            else
                frame.release(); // for media since replaced, or a player disposed of
        }
    }
}

/// What a player is doing. JavaFX's MediaPlayer.Status, with `ended` added.
enum MediaStatus
{
    unknown,   /// Loading, or with nothing to play
    ready,     /// Loaded, at the start, not played yet
    playing,
    paused,
    stalled,   /// Would be playing, but waiting for more of a stream to arrive
    stopped,   /// Stopped, back at the start
    ended,     /// Played to the end, and stopped there: play() starts again from the start
    halted,    /// It couldn't go on: see error
    disposed,  /// dispose() was called
}

/// What a player tells of each new frame: a MediaView, while it's in a window.
interface FrameWatcher
{
    void frameChanged();
}
