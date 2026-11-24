module mayfair.media.media;

import core.time : Duration;
import mayfair.properties;

/*
    Something to play: a file or a URL, and what's been found out about it. JavaFX's Media.

        auto media = new Media("/home/me/Videos/holiday.webm");    // or "https://...", "file:///..."
        auto player = new MediaPlayer(media);

    Making one opens nothing. What's in it -- its duration, the video's size, its tracks and
    metadata -- is found out as a player loads it, and set on it then, on the UI thread: these are
    properties, to listen to, and empty until then. One Media can be given to any number of
    players, and is filled in by whichever loads it first.

    What can be played, and from where -- which containers and codecs, which network protocols --
    is the backend's to say: see MediaBackend.
*/
final class Media
{
public:
    /// `source` is a file's path, absolute or not, or a URI: file://, https://, rtsp:// or
    /// whatever else the backend understands.
    this(string source)
    {
        _source = source;
        _uri = toUri(source);
    }

    /// What it was made with, and the URI that's played: the same, or a path as a file:// URI.
    string source() const nothrow @nogc { return _source; }
    string uri() const nothrow @nogc { return _uri; } /// ditto

    /// How long it is. Duration.zero until it's known; Media.indefinite for a live stream.
    mixin(declareReadOnlyProperty!(Duration, "duration", "Duration.zero", "", "package"));

    /// The video's size, in pixels; 0 by 0 for audio alone, or until it's known.
    mixin(declareReadOnlyProperty!(int, "width", "0", "", "package"));
    mixin(declareReadOnlyProperty!(int, "height", "0", "", "package")); /// ditto

    /// How wide each of the video's pixels is, for its height: 1 nearly always, but not for DV,
    /// say, or anamorphic DVD video, which MediaView stretches back to the right shape.
    mixin(declareReadOnlyProperty!(float, "pixelAspectRatio", "1", "", "package"));

    /// Its video, audio and subtitle tracks.
    mixin(declareReadOnlyProperty!(Track[], "tracks", "null", "", "package"));

    /*
        What it says about itself, by the names GStreamer's tags use, which most formats map onto:
        "title", "artist", "album", "genre", "comment", "description", "copyright",
        "container-format". Only what the media has.
    */
    mixin(declareReadOnlyProperty!(string[string], "metadata", "null", "", "package"));

    /// The duration of what never ends: a live stream.
    enum Duration indefinite = Duration.max;

private:
    string _source, _uri;
}

/// A track in a Media.
struct Track
{
    TrackKind kind;
    int index;          /// Among the tracks of its kind, from 0
    string codec;       /// As the backend names it: "Theora", "H.264 (High Profile)"; or null
    string language;    /// An ISO 639 code, "en" or "fra", if it says; or null
    string name;        /// Its title, if it has one
}

/// ditto
enum TrackKind
{
    video,
    audio,
    subtitle,
}

/// What went wrong.
struct MediaError
{
    MediaErrorKind kind;
    /// What to tell the user, as the backend put it: "Resource not found."
    string message;
    /// The details, for a log or a bug report: which part of the backend, and why.
    string details;

    /// Whether there's an error at all.
    bool opCast(T : bool)() const nothrow @nogc { return kind != MediaErrorKind.none; }

    string toString() const
    {
        return details.length ? message ~ " (" ~ details ~ ")" : message;
    }
}

/// ditto
enum MediaErrorKind
{
    none,
    /// No backend to play it: see MediaPlayer.setBackend.
    noBackend,
    /// The backend couldn't start: its library isn't installed, say.
    backendUnavailable,
    /// There's nothing at the source.
    notFound,
    /// It couldn't be read: permissions, or a network that dropped.
    unreadable,
    /// Its format, or a codec in it, isn't one the backend can play: a plugin missing, say.
    unsupported,
    /// It's damaged, or not what it says it is.
    corrupt,
    /// Anything else.
    other,
}

/// `source` as a URI: a URI as it is, and a path as a file:// one, absolute, its unusual characters escaped.
string toUri(string source)
{
    import std.algorithm : canFind;
    import std.ascii : isAlphaNum, isAlpha;
    import std.format : format;
    import std.path : absolutePath, buildNormalizedPath;

    // A scheme: letters, digits, + . -, then "://" (or "file:" alone)
    foreach (i, c; source)
    {
        if (c == ':')
        {
            if (i > 1 && source[i .. $].length >= 3 && source[i .. i + 3] == "://")
                return source;
            break;
        }
        if (!(isAlphaNum(c) || c == '+' || c == '.' || c == '-'))
            break;
    }

    auto path = buildNormalizedPath(absolutePath(source));
    version (Windows)
    {
        import std.array : replace;
        path = "/" ~ path.replace('\\', '/'); // file:///C:/...
    }
    string uri = "file://";
    foreach (char c; path)
    {
        if (isAlphaNum(c) || "/-._~".canFind(c) || (c == ':' && uri.length == "file:///".length + 1))
            uri ~= c;
        else
            uri ~= format!"%%%02X"(cast(ubyte) c);
    }
    return uri;
}

unittest
{
    assert(toUri("https://example.com/a b.mp4") == "https://example.com/a b.mp4");
    assert(toUri("file:///tmp/x.ogg") == "file:///tmp/x.ogg");
    version (Posix)
    {
        assert(toUri("/tmp/my clip #1.ogg") == "file:///tmp/my%20clip%20%231.ogg");
        assert(toUri("/tmp/ä.ogg") == "file:///tmp/%C3%A4.ogg");
        assert(toUri("/tmp/a/../b.ogg") == "file:///tmp/b.ogg");
        assert(toUri("C:x") != "C:x"); // a relative path that happens to have a colon in it
    }
}
