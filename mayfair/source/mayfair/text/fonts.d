module mayfair.text.fonts;

import std.algorithm : sort;
import std.process : environment;
import std.string : fromStringz;
import std.uni : toLower;

import mayfair.text.font;
import mayfair.text.freetype;

/*
    Finding fonts: by family name, a default when none is named, and a fallback for any character
    the chosen font has no glyph for.

    There's no fontconfig here. It would bring its own FreeType to disagree with the vendored one
    about, and its matching rules to learn. Instead the directories fonts get installed into are
    scanned once, on first use, reading each face's family and style with the FreeType already
    linked in. That's a header read per file, and only scalable faces are kept: the vector route
    draws outlines, so a bitmap-only face (a .pcf, or a CBDT colour emoji font) has nothing to give.

    Behind every installed font there is one more: DejaVu Sans, compiled into the library, so text
    renders on a machine with no usable fonts at all. It's also the fallback of last resort for a
    missing glyph, and the reason font() and defaultFont() never fail.

    IBM Plex Sans is compiled in too, in regular, italic, semibold and bold, and is the default
    font everywhere for now: Zed's interface is in it, which makes the two easy to compare side by
    side. Both are under licences that let them be (fonts/LICENSE-*.txt).

    Fonts are shared. Asking for the same face at the same size twice gets the same Font, so a
    hundred labels in one style open one file.
*/

/// The installed family `family` (case-insensitive) at `size` points, in the closest style it has
/// to `weight` and `italic`. A family that isn't installed gets the default font instead.
Font font(string family, float size, FontWeight weight = FontWeight.regular, bool italic = false)
{
    auto want = FaceStyle(weight, 5, italic);
    if (auto face = bestFace(family, want))
        return face.at(size);
    return defaultFont(size, weight, italic);
}

/// Whether `family` is installed, or is one of the bundled ones.
bool hasFamily(string family)
{
    return (family.toLower in index.byFamily) !is null;
}

/// The font a widget uses when it isn't given one: IBM Plex Sans, which is bundled, for now; the
/// first of the platform's usual UI families that's installed, or DejaVu Sans, if it weren't.
Font defaultFont(float size, FontWeight weight = FontWeight.regular, bool italic = false)
{
    auto want = FaceStyle(weight, 5, italic);
    foreach (family; defaultFamilies)
        if (auto face = bestFace(family, want))
            return face.at(size);
    return bestFace(bundledFamily, want).at(size);
}

/// Every installed family's name, sorted, for listing in a picker.
string[] installedFamilies()
{
    string[] names;
    foreach (faces; index.byFamily)
        names ~= faces[0].family;
    names.sort();
    return names;
}

package:

/*
    A font at `primary`'s size and in the closest style to it that has a glyph for `c`, or null if
    nothing installed does. Shaping calls this for each character `primary` can't draw.

    Which family covers a character is remembered, so a paragraph of CJK searches once, not once a
    character. The search goes through the families most likely to have it first, then every other
    family in the index, probing one face of each.
*/
Font fallbackFont(Font primary, dchar c)
{
    auto want = FaceStyle(primary.weight, 5, primary.italic);

    auto cached = c in index.coveredBy;
    if (!cached)
    {
        FaceEntry found;
        foreach (family; fallbackFamilies)
            if (auto face = bestFace(family, want))
                if (face.covers(c)) { found = face; break; }
        if (!found)
            foreach (key; index.familyOrder)
            {
                auto face = best(index.byFamily[key], want);
                if (face.covers(c)) { found = face; break; }
            }
        index.coveredBy[c] = found;
        cached = c in index.coveredBy;
    }

    auto face = *cached;
    if (!face)
        return null;
    // The face that was probed matched the style of whoever asked first. This caller may want a
    // different one from the same family, which covers `c` too as long as the family is consistent.
    auto styled = bestFace(face.family, want);
    return (styled && styled.covers(c) ? styled : face).at(primary.size);
}

private:

enum bundledFamily = "DejaVu Sans";
static immutable bundledData = cast(immutable(ubyte)[]) import("DejaVuSans.ttf");

/// The default family's faces, compiled in: see the top of this module.
static immutable plexData = [
    cast(immutable(ubyte)[]) import("IBMPlexSans-Regular.ttf"),
    cast(immutable(ubyte)[]) import("IBMPlexSans-Italic.ttf"),
    cast(immutable(ubyte)[]) import("IBMPlexSans-SemiBold.ttf"),
    cast(immutable(ubyte)[]) import("IBMPlexSans-Bold.ttf"),
];

version (Windows)
    static immutable defaultFamilies = ["IBM Plex Sans", "Segoe UI", "Tahoma", "Arial"];
else version (OSX)
    static immutable defaultFamilies = ["IBM Plex Sans", "Helvetica Neue", "Helvetica", "Arial"];
else
    static immutable defaultFamilies = ["IBM Plex Sans", "Noto Sans", "Cantarell", "Ubuntu", "Roboto",
                                        "Liberation Sans", "DejaVu Sans"];

// Wide coverage first, so a stray symbol lands in a font that looks like the text around it
static immutable fallbackFamilies = [
    "Noto Sans", "DejaVu Sans", "Segoe UI", "Arial Unicode MS",
    "Noto Sans CJK SC", "Noto Sans CJK JP", "Microsoft YaHei", "PingFang SC",
    "Noto Sans Symbols", "Noto Sans Symbols 2", "Noto Sans Math", "Segoe UI Symbol", "Symbola",
];

/// One face in the index: where it is, what it calls itself, and what it looks like.
final class FaceEntry
{
    FaceSource source;
    string family;
    FaceStyle style;

    /// This face at `size`, shared with every other caller asking for the same.
    Font at(float size)
    {
        if (auto f = size in sized)
            return *f;
        return sized[size] = new Font(source, size);
    }

    /// Whether this face maps `c` to a glyph. The first call reads the face's whole character map
    /// into ranges and closes the file again, so asking about the next character is a search, not
    /// another open -- which matters when a fallback search probes every family installed.
    bool covers(dchar c)
    {
        if (!coverageRead)
            readCoverage();
        size_t lo = 0, hi = coverage.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (c < coverage[mid][0]) hi = mid;
            else if (c > coverage[mid][1]) lo = mid + 1;
            else return true;
        }
        return false;
    }

private:
    Font[float] sized;
    dchar[2][] coverage; // inclusive, sorted, non-overlapping
    bool coverageRead;

    void readCoverage()
    {
        coverageRead = true;
        FT_Face face;
        if (source.open(ftLibrary(), &face) != 0)
            return;
        scope(exit) FT_Done_Face(face);

        // FreeType picks a Unicode charmap on open where there is one, and walks it in order
        FT_UInt glyph;
        auto c = cast(dchar) FT_Get_First_Char(face, &glyph);
        while (glyph != 0)
        {
            if (coverage.length && coverage[$ - 1][1] + 1 == c)
                coverage[$ - 1][1] = c;
            else
                coverage ~= [c, c];
            c = cast(dchar) FT_Get_Next_Char(face, c, &glyph);
        }
    }
}

struct FontIndex
{
    FaceEntry[][string] byFamily; // lower-cased family name to its faces, in scan order
    string[] familyOrder;         // keys of byFamily, in the order they were first found
    FaceEntry[dchar] coveredBy;   // fallback search results; null where nothing has the glyph
    bool[string] seen;            // files already scanned

    void add(FaceEntry e)
    {
        const key = e.family.toLower;
        if (auto faces = key in byFamily)
            *faces ~= e;
        else
        {
            byFamily[key] = [e];
            familyOrder ~= key;
        }
    }
}

/// The index, built the first time anything asks for it.
ref FontIndex index()
{
    static FontIndex idx;
    static bool built;
    if (!built)
    {
        built = true;
        foreach (dir; fontDirectories())
            scanDirectory(dir, idx);
        // Last, so an installed copy of a bundled font is preferred to it
        foreach (data; plexData)
            addFaces(FaceSource(null, data, 0), idx);
        addFaces(FaceSource(null, bundledData, 0), idx);
    }
    return idx;
}

FaceEntry bestFace(string family, FaceStyle want)
{
    auto faces = family.toLower in index.byFamily;
    return faces ? best(*faces, want) : null;
}

/*
    The closest face to `want`, in the order CSS's font matching settles it: width first, then
    italic, then weight. Ties go to whichever was found first, so a font in the user's own
    directory beats a system copy of the same.
*/
FaceEntry best(FaceEntry[] faces, FaceStyle want)
{
    FaceEntry result;
    uint bestScore = uint.max;
    foreach (f; faces)
    {
        const widthDiff = f.style.width > want.width ? f.style.width - want.width
                                                     : want.width - f.style.width;
        const weightDiff = f.style.weight > want.weight ? f.style.weight - want.weight
                                                        : want.weight - f.style.weight;
        const score = widthDiff * 100_000 + (f.style.italic != want.italic) * 10_000 + weightDiff;
        if (score < bestScore)
        {
            bestScore = score;
            result = f;
        }
    }
    return result;
}

/// Where fonts are installed, the user's own directories first.
string[] fontDirectories()
{
    string[] dirs;
    version (Windows)
    {
        dirs ~= environment.get("LOCALAPPDATA", "") ~ `\Microsoft\Windows\Fonts`;
        dirs ~= environment.get("WINDIR", `C:\Windows`) ~ `\Fonts`;
    }
    else version (OSX)
    {
        dirs ~= environment.get("HOME", "") ~ "/Library/Fonts";
        dirs ~= ["/Library/Fonts", "/System/Library/Fonts", "/Network/Library/Fonts"];
    }
    else
    {
        // The XDG base directory spec, which is where fontconfig's default config looks too
        import std.algorithm : splitter;
        const home = environment.get("HOME", "");
        dirs ~= environment.get("XDG_DATA_HOME", home ~ "/.local/share") ~ "/fonts";
        dirs ~= home ~ "/.fonts";
        foreach (d; environment.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").splitter(':'))
            if (d.length)
                dirs ~= d ~ "/fonts";
        dirs ~= "/usr/share/fonts"; // in case XDG_DATA_DIRS was set without it
    }
    return dirs;
}

void scanDirectory(string dir, ref FontIndex idx)
{
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : extension;

    try
    {
        if (!dir.exists || !dir.isDir)
            return;
        foreach (entry; dirEntries(dir, SpanMode.breadth, true))
        {
            switch (entry.name.extension.toLower)
            {
                case ".ttf", ".otf", ".ttc", ".otc":
                    // Skip a file already indexed under another directory, e.g. /usr/share/fonts
                    // reached twice through XDG_DATA_DIRS
                    if (entry.name !in idx.seen)
                    {
                        idx.seen[entry.name] = true;
                        addFaces(FaceSource(entry.name, null, 0), idx);
                    }
                    break;
                default:
                    break;
            }
        }
    }
    catch (Exception)
    {
        // An unreadable directory, or one that vanished mid-scan: whatever was found still counts
    }
}

/// Adds every scalable face in the file (a collection holds several) to the index.
void addFaces(FaceSource source, ref FontIndex idx)
{
    auto lib = ftLibrary();
    FT_Long count = 1;
    for (int i = 0; i < count; i++)
    {
        source.index = i;
        FT_Face face;
        if (source.open(lib, &face) != 0)
            return;
        scope(exit) FT_Done_Face(face);

        count = face.num_faces;
        if (!(face.face_flags & FT_FACE_FLAG_SCALABLE_) || !face.family_name)
            continue;

        auto e = new FaceEntry;
        e.source = source;
        e.family = face.family_name.fromStringz.idup;
        e.style = FaceStyle.of(face);
        idx.add(e);
    }
}

unittest
{
    // The bundled IBM Plex Sans, in each of its four faces, under the one family
    foreach (weight, italic; [FontWeight.regular: false, FontWeight.semiBold: false, FontWeight.bold: false])
    {
        auto f = bestFace("IBM Plex Sans", FaceStyle(weight, 5, italic));
        assert(f && f.style.weight == weight, "IBM Plex Sans has its own face for each weight");
    }
    auto italic = bestFace("IBM Plex Sans", FaceStyle(FontWeight.regular, 5, true));
    assert(italic && italic.style.italic && italic.style.weight == FontWeight.regular);
    assert(hasFamily("IBM Plex Sans") && hasFamily("DejaVu Sans"));
}
