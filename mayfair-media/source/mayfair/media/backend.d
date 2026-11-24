module mayfair.media.backend;

/*
    What plays a MediaPlayer's media: a backend, chosen by the app, and a session of it for each
    player. mayfair-gstreamer is one; another -- on FFmpeg, say -- implements the same interfaces,
    and nothing in Media, MediaPlayer or MediaView changes.

    The rules every backend keeps:

    - A session's methods are called on the UI thread, and return at once: anything slow --
      starting the library, opening a file, changing a pipeline's state, waiting for it to stop --
      happens on a thread of the backend's own.
    - It tells its host what happened through MediaSessionHost, on the UI thread: Platform.runLater
      from a thread the D runtime knows, or a FrameMailbox (which signals a Notifier) from one it
      doesn't, like a library's streaming thread.
    - Everything it says carries the generation it was loading when it happened. A host ignores
      news from an older one -- media since replaced, or a player disposed of -- so a late frame or
      event can't land on the wrong media; but a backend should still stop sending it.
    - dispose() is asynchronous: it returns at once, and the backend lets go of everything on its
      own thread. Nothing it sends after that reaches anyone.
*/

import core.sync.mutex : Mutex;
import core.time : Duration;
import mayfair.media.media;
import mayfair.windowing.platform : Notifier;

/// Something that can play media: given to MediaPlayer.setBackend, or to a player of its own.
interface MediaBackend
{
    /// A name for it, for logs and errors: "gstreamer", say.
    string name();

    /// A session for one player, which tells `host` what happens. On the UI thread; mustn't block.
    MediaSession open(MediaSessionHost host);
}

/*
    One player's playback, as a backend runs it. Called on the UI thread only, and nothing here
    may wait for the backend: each is a request, carried out when it can be, and what came of it
    is told to the host.
*/
interface MediaSession
{
    /// Opens `uri`, as `generation`, in place of whatever was open: paused, at the start, until
    /// play(). The host is told `loaded` once it's ready, or `failed`.
    void load(string uri, uint generation);

    /// Plays, or pauses: as soon as it can, if it's still loading.
    void play();
    void pause(); /// ditto

    /// Goes to `position`: where it was told to, or as near as the media allows. Positions it
    /// tells the host afterwards carry `serial`, so the host can tell them from ones before.
    void seek(Duration position, uint serial);

    /// How loud, from 0 to 1, and whether it's silent.
    void setVolume(double volume);
    void setMute(bool mute); /// ditto

    /// Stops, and lets go of everything, on the backend's own thread. Returns at once.
    void dispose();
}

/// What a session's playback is doing, as it tells its host.
enum SessionState
{
    paused,
    playing,
    stalled,  /// would be playing, but waiting for more of a stream to arrive
}

/// What a session learnt about its media.
struct MediaInfo
{
    Duration duration;           /// How long it is, if durationKnown
    bool durationKnown;          /// False for a live stream, or until it's known
    bool seekable;
    int width, height;           /// The video's size in pixels, or 0 if there's none, or it isn't known yet
    float pixelAspectRatio = 1;  /// How wide each pixel is, for its height
    Track[] tracks;
    string[string] metadata;     /// Its title, artist and so on: see Media.metadata
}

/*
    How a session tells its player what happened. Called on the UI thread only, with the
    generation the news is about: a host drops what's for another.
*/
interface MediaSessionHost
{
    /// Ready to play, paused at the start: what it found out about the media.
    void loaded(uint generation, MediaInfo info);
    /// It learnt more since: the duration, once a stream's known it, or tags.
    void infoChanged(uint generation, MediaInfo info);
    /// Playing, paused, or stalled.
    void stateChanged(uint generation, SessionState state);
    /// Where playback has got to, after the seek with `seekSerial` (0 before any).
    void positionChanged(uint generation, uint seekSerial, Duration position);
    /// How much of a stream is buffered, from 0 to 1, of what it needs to play on.
    void bufferingChanged(uint generation, double progress);
    /// It reached the end.
    void ended(uint generation);
    /// It couldn't go on: it stops there.
    void failed(uint generation, MediaError error);
    /// A frame of video to show. The host owns it, and releases it.
    void frameArrived(uint generation, VideoFrame frame);
}

/*
    A frame of video, as a backend decoded it: pixels in memory, each a 32-bit 0xAARRGGBB --
    BGRA bytes, little-endian -- premultiplied by its alpha (which video's being opaque, it's
    always 255). A backend whose frames are on the GPU can map them here, or a future kind of
    frame can carry a texture.

    Mapped and unmapped on the UI thread; released once, by its owner, from any thread.
*/
abstract class VideoFrame
{
    /// Its size in pixels, and how wide each pixel is for its height (1, mostly).
    final uint width() const nothrow @nogc { return _width; }
    final uint height() const nothrow @nogc { return _height; } /// ditto
    final float pixelAspectRatio() const nothrow @nogc { return _pixelAspectRatio; } /// ditto

    /// Where in the media it's from.
    final Duration timestamp() const nothrow @nogc { return _timestamp; }

    /// Its pixels, `stride` bytes a row, until unmap(); null if they can't be had.
    abstract const(ubyte)[] map(out size_t stride) nothrow @nogc;
    abstract void unmap() nothrow @nogc; /// ditto

    /// Lets go of what it holds. Once only; it can't be mapped after.
    abstract void release() nothrow @nogc;

protected:
    this(uint width, uint height, float pixelAspectRatio, Duration timestamp) nothrow @nogc
    {
        _width = width;
        _height = height;
        _pixelAspectRatio = pixelAspectRatio > 0 ? pixelAspectRatio : 1;
        _timestamp = timestamp;
    }

private:
    uint _width, _height;
    float _pixelAspectRatio;
    Duration _timestamp;
}

/// A frame in plain memory: for a backend that copies what it decodes, and for tests.
final class PixelFrame : VideoFrame
{
    /// `pixels` is `width` 0xAARRGGBB words a row, `height` rows.
    this(uint[] pixels, uint width, uint height, float pixelAspectRatio = 1, Duration timestamp = Duration.zero) nothrow @nogc
    {
        super(width, height, pixelAspectRatio, timestamp);
        this.pixels = pixels;
    }

    override const(ubyte)[] map(out size_t stride) nothrow @nogc
    {
        stride = width * 4;
        return pixels is null ? null : cast(const(ubyte)[]) pixels;
    }

    override void unmap() nothrow @nogc {}

    override void release() nothrow @nogc { pixels = null; }

private:
    uint[] pixels;
}

/*
    The newest frame a session's decoded, waiting for the UI thread: for a backend whose frames
    arrive on a thread the D runtime doesn't know -- a library's streaming thread -- which can't
    allocate, or call Platform.runLater. post() from that thread neither allocates nor asks the
    runtime anything.

    It holds one frame. A newer one posted before the UI thread took it replaces it, and the
    older is released there and then: a frame the UI thread was too busy to show is one it'd
    never show, and video can't queue up behind a slow frame. The frames are the backend's own
    handles -- a GstSample, an AVFrame -- as `void*`, which `deliver` turns into a VideoFrame on
    the UI thread, and `release` lets go of from whichever thread drops one.

    Made on the UI thread, and kept by whatever gives it to the other thread, for as long as that
    thread may post: it holds it by a pointer the garbage collector can't see.
*/
final class FrameMailbox
{
public:
    this(void delegate(void* frame, uint generation) deliver, void function(void* frame) nothrow @nogc release) nothrow
    {
        this.deliver = deliver;
        this.release = release;
        lock = new Mutex;
        notifier = new Notifier(&take);
    }

    /// The newest frame, of `generation`: from any thread.
    void post(void* frame, uint generation) nothrow @nogc
    {
        void* replaced;
        bool open;
        lock.lock_nothrow();
        open = !closed;
        if (open)
        {
            replaced = pending;
            pending = frame;
            pendingGeneration = generation;
        }
        lock.unlock_nothrow();
        if (!open)
            replaced = frame;
        if (replaced)
            release(replaced);
        if (open)
            notifier.signal();
    }

    /// Drops the frame waiting, if there is one: as the media changes, say.
    void clear() nothrow @nogc
    {
        lock.lock_nothrow();
        auto dropped = pending;
        pending = null;
        lock.unlock_nothrow();
        if (dropped)
            release(dropped);
    }

    /// Drops it, and anything posted from now on: for a session that's done.
    void close() nothrow @nogc
    {
        lock.lock_nothrow();
        closed = true;
        lock.unlock_nothrow();
        clear();
    }

private:
    void delegate(void*, uint) deliver;
    void function(void*) nothrow @nogc release;
    Mutex lock;
    Notifier notifier;
    void* pending;
    uint pendingGeneration;
    bool closed;

    // On the UI thread, from the notifier
    void take()
    {
        lock.lock_nothrow();
        auto frame = pending;
        const generation = pendingGeneration;
        pending = null;
        const isClosed = closed;
        lock.unlock_nothrow();
        if (!frame)
            return;
        if (isClosed)
            release(frame);
        else
            deliver(frame, generation);
    }
}

unittest
{
    import mayfair.windowing.platform : Platform;
    __gshared int released;
    static void releaseOne(void* f) nothrow @nogc { released++; }
    void*[] delivered;
    uint[] generations;
    auto box = new FrameMailbox((void* f, uint g) { delivered ~= f; generations ~= g; }, &releaseOne);
    int a, b, c;
    box.post(&a, 1);
    box.post(&b, 1); // replaces a, which is released
    assert(released == 1);
    foreach (task; Platform.take())
        task();
    assert(delivered == [cast(void*) &b] && generations == [1]);
    box.post(&c, 2);
    box.close(); // c dropped, and nothing more delivered
    assert(released == 2);
    box.post(&a, 2);
    assert(released == 3, "posted after closing: released at once");
    foreach (task; Platform.take())
        task();
    assert(delivered.length == 1);
}
