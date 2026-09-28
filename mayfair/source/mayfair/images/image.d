module mayfair.images.image;

/*
    A picture, as data: the bytes of a PNG, JPEG, WebP, SVG or Lottie file. JavaFX's Image. It
    isn't drawn itself -- an ImageView draws one -- and one Image can be shown by any number of
    views at once, which share what decoding it makes.

        auto logo = new Image("/usr/share/pixmaps/debian-logo.png");  // a file, read now
        auto tick = Image.fromData(import("tick.svg"), "tick.svg");     // compiled into the app

    The second is the one to reach for with an app's own images: `import` puts the file in the
    executable, so there's nothing to install alongside it or to go missing, and nothing is read
    at run time. `name` is only a hint -- what the file was called, for its extension -- as what
    the data is gets worked out from its first few bytes.

    Decoding it waits until a view shows it, because ThorVG only decodes once its engine is running,
    which needs a window. So `width` and `height` are 0 until then, as JavaFX's are for an image
    still loading in the background. A file that can't be read, or data that isn't an image,
    leaves `error` set and draws nothing, rather than throwing -- as JavaFX's does, and so a
    missing icon doesn't take the app down with it.
*/
final class Image
{
public:
    /// Reads the image file at `path`. Relative paths inside it, such as an SVG's linked images,
    /// are found from the file's own folder.
    this(string path)
    {
        import std.file : read;
        import std.path : dirName;
        _name = path;
        _resourcePath = dirName(path);
        try
            setData(cast(const(ubyte)[]) read(path), path);
        catch (Exception e)
        {
            _error = true;
            _errorMessage = e.msg;
        }
    }

    /*
        The image file at `path`, read once for the life of the app and shared by everything that
        asks for it after: what an Icon shows, so a hundred rows with a folder icon read the file
        once and decode it once, and a row scrolled onto another icon and back doesn't read or
        decode it again. For files that don't change while the app runs, as a theme's icons don't.
    */
    static Image cached(string path)
    {
        if (auto hit = path in cache)
            return *hit;
        auto image = new Image(path);
        image._shared = true;
        cache[path] = image;
        return image;
    }

    /// An image from the bytes of its file, such as `import("logo.svg")`. `name` is what the file
    /// was called, if there's a name: a hint at what it holds, and for messages.
    static Image fromData(const(void)[] data, string name = null)
    {
        auto image = new Image;
        image._name = name;
        image.setData(cast(const(ubyte)[]) data, name);
        return image;
    }

    /// What the data turned out to be.
    ImageFormat format() const nothrow @nogc { return _format; }

    /// Whether it moves: a Lottie animation, which a LottieView plays. An ImageView shows its first frame.
    bool animated() const nothrow @nogc { return _format == ImageFormat.lottie; }

    /// Its own size, in points (a pixel of a PNG, a px of an SVG), once a view has decoded it; 0 before.
    float width() const nothrow @nogc { return _width; }
    float height() const nothrow @nogc { return _height; } /// ditto

    /// Whether it couldn't be read or decoded. JavaFX's isError; `errorMessage` says why.
    bool error() const nothrow @nogc { return _error; }
    string errorMessage() const nothrow @nogc { return _errorMessage; }

    /// The path or name it was made with, if any.
    string name() const nothrow @nogc { return _name; }

    /// The ids of a Lottie file's colour slots, which a LottieView takes from the stylesheet as
    /// the variable --lottie-<id>; none for any other image. See mayfair.images.lottie.
    const(string)[] colourSlots()
    {
        import mayfair.images.lottie : lottieColourSlots;
        if (!_slotsScanned)
        {
            _slotsScanned = true;
            if (_format == ImageFormat.lottie)
                _colourSlots = lottieColourSlots(cast(const(char)[]) _data[0 .. $ - 1]);
        }
        return _colourSlots;
    }

    override string toString() const
    {
        return _name.length ? "Image(" ~ _name ~ ")" : "Image";
    }

package(mayfair):
    /*
        The data as ThorVG takes it. It's handed over without being copied, and ThorVG keys what it
        decodes on the pointer, which is how views showing the same Image share one decoding: so
        the bytes must stay put for as long as any picture made from them lives. They do: they're
        this object's, and every view showing it holds on to it. ThorVG reads SVG and Lottie as a
        C string, so there's a 0 after the data, which isn't counted in its length.

        Lottie is the exception. ThorVG parses its JSON in place, writing into the buffer as it
        goes, and doesn't share what it parses anyway (each animation is at a frame of its own),
        so it's handed a copy of its own every time: see copyOnLoad. Data of no known format is
        too, in case it's Lottie.
    */
    bool copyOnLoad() const nothrow @nogc { return _format == ImageFormat.lottie || _format == ImageFormat.unknown; }
    const(char)* dataPointer() const nothrow @nogc { return cast(const(char)*) _data.ptr; }
    uint dataLength() const nothrow @nogc { return cast(uint)(_data.length - 1); }
    const(char)* mimeType() const nothrow @nogc { return mimeTypes[_format].ptr; }
    const(char)* resourcePath() const nothrow @nogc { return _resourcePath.length ? _resourcePathZ.ptr : null; }

    /// Whether it's one of cached()'s, whose decoding is worth keeping once it's made.
    bool keepsDecoding() const nothrow @nogc { return _shared; }

    /// A view decoded it: its size is known now, or it turned out not to be an image after all.
    void decoded(bool ok, float width, float height) nothrow @nogc
    {
        if (!ok)
        {
            _error = true;
            if (!_errorMessage.length)
                _errorMessage = "not an image ThorVG can decode";
            return;
        }
        _width = width;
        _height = height;
    }

private:
    const(ubyte)[] _data;
    ImageFormat _format;
    string _name, _resourcePath, _resourcePathZ, _errorMessage;
    float _width = 0, _height = 0;
    bool _error;
    string[] _colourSlots;
    bool _slotsScanned;
    bool _shared; // one of cached()'s

    static Image[string] cache; // cached()'s, by path

    this() {}

    void setData(const(ubyte)[] data, string name)
    {
        // A copy with a 0 on the end. Even a file just read is copied, as that's the only way to
        // get the 0 after it; an image is read once, so it isn't worth avoiding.
        auto copy = new ubyte[data.length + 1];
        copy[0 .. data.length] = data[];
        copy[$ - 1] = 0;
        _data = copy;
        _format = sniff(data, name);
        if (_resourcePath.length)
            _resourcePathZ = _resourcePath ~ '\0';
        if (!data.length)
        {
            _error = true;
            _errorMessage = "no data";
        }
    }
}

/// What an Image holds.
enum ImageFormat { unknown, png, jpeg, webp, svg, lottie }

// ThorVG's names for them. Unknown is "", which has it try each loader in turn.
private immutable string[] mimeTypes = ["\0", "png\0", "jpg\0", "webp\0", "svg\0", "lottie+json\0"];

/*
    What `data` is, from how it starts: a PNG, JPEG or WebP by its signature, an SVG by being XML,
    and a Lottie file by being JSON. Failing those, the name's extension; failing that, unknown.
*/
ImageFormat sniff(const(ubyte)[] data, string name) pure nothrow @safe
{
    static bool startsWith(const(ubyte)[] d, string s) pure nothrow @safe
    {
        return d.length >= s.length && d[0 .. s.length] == cast(const(ubyte)[]) s;
    }

    if (startsWith(data, "\x89PNG"))
        return ImageFormat.png;
    if (startsWith(data, "\xFF\xD8\xFF"))
        return ImageFormat.jpeg;
    if (startsWith(data, "RIFF") && data.length >= 12 && data[8 .. 12] == cast(const(ubyte)[]) "WEBP")
        return ImageFormat.webp;

    // Text: past a byte order mark and any white space, XML starts with <, JSON with {
    auto text = data;
    if (startsWith(text, "\xEF\xBB\xBF"))
        text = text[3 .. $];
    while (text.length && (text[0] == ' ' || text[0] == '\t' || text[0] == '\n' || text[0] == '\r'))
        text = text[1 .. $];
    if (text.length && text[0] == '<')
        return ImageFormat.svg;
    if (text.length && text[0] == '{')
        return ImageFormat.lottie;

    import std.ascii : toLower;
    import std.path : extension;
    char[8] buffer;
    const ext = extension(name);
    if (ext.length > buffer.length)
        return ImageFormat.unknown;
    foreach (i, c; ext)
        buffer[i] = toLower(c);
    switch (buffer[0 .. ext.length])
    {
        case ".png":                  return ImageFormat.png;
        case ".jpg": case ".jpeg":    return ImageFormat.jpeg;
        case ".webp":                 return ImageFormat.webp;
        case ".svg":                  return ImageFormat.svg;
        case ".json": case ".lottie": return ImageFormat.lottie;
        default:                      return ImageFormat.unknown;
    }
}

unittest
{
    assert(sniff(cast(const(ubyte)[]) "\x89PNG\r\n\x1a\n", null) == ImageFormat.png);
    assert(sniff(cast(const(ubyte)[]) "\xFF\xD8\xFF\xE0", null) == ImageFormat.jpeg);
    assert(sniff(cast(const(ubyte)[]) "RIFF\0\0\0\0WEBPVP8 ", null) == ImageFormat.webp);
    assert(sniff(cast(const(ubyte)[]) "\xEF\xBB\xBF\n  <svg/>", null) == ImageFormat.svg);
    assert(sniff(cast(const(ubyte)[]) " {\"v\":\"5.7\"}", null) == ImageFormat.lottie);
    assert(sniff(cast(const(ubyte)[]) "????", "photo.JPG") == ImageFormat.jpeg);
    assert(sniff(cast(const(ubyte)[]) "????", null) == ImageFormat.unknown);
}

unittest
{
    auto i = Image.fromData("<svg/>", "x.svg");
    assert(i.format == ImageFormat.svg && !i.error);
    assert(i.dataLength == 6 && i.dataPointer[6] == 0, "a 0 after the data, not counted");
    assert(new Image("/nonexistent/image.png").error, "a missing file: an error, not an exception");
    assert(Image.fromData("").error);
    assert(Image.cached("/nonexistent/icon.svg") is Image.cached("/nonexistent/icon.svg"), "one per path");
    assert(Image.cached("/nonexistent/icon.svg").keepsDecoding && !i.keepsDecoding);
}
