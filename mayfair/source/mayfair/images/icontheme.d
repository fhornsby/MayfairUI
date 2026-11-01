module mayfair.images.icontheme;

import std.algorithm : canFind, endsWith, splitter, startsWith;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.path : baseName, buildPath, stripExtension;
import std.process : environment;
import std.string : indexOf, strip;

/*
    Icons by name, from the desktop's icon theme: "edit-copy-symbolic", "folder", "dialog-warning".
    The freedesktop Icon Theme Specification, which GNOME, KDE and the rest all follow, so an app
    gets the icons the rest of the desktop has -- Adwaita on GNOME, Yaru on Ubuntu, Breeze on KDE.

    A theme is a folder of folders, one per size and kind of icon, described by its index.theme,
    and it inherits from others: what it hasn't got comes from those, and in the end from hicolor,
    where apps install their own icons. Looking an icon up goes down that chain, in each theme
    taking an icon made for the size wanted, or failing that the nearest size it has. Scalable
    (SVG) icons suit any size, and are what Mayfair would rather have: they're drawn as vectors, so
    they're sharp at any scale. A name that isn't found is tried shorter, as GTK does --
    "edit-copy-symbolic", then "edit-symbolic" -- so a specific name can fall back to a general one.

    This is read at run time, unlike a stylesheet, because it's the desktop's: which theme, and
    what's in it, isn't known until the app is running on it. Each theme's index is read once,
    each folder listed once, and each answer remembered.

    Which theme is the desktop's is mayfair.desktop's to say -- GNOME's setting, today, or failing
    that GTK's settings.ini, or failing that Adwaita. IconTheme.name can say otherwise.
*/
struct IconTheme
{
    /// The theme icons are looked up in: the desktop's, until set.
    static string name()
    {
        if (!chosen.length)
            chosen = desktopIconTheme();
        return chosen;
    }

    /// ditto
    static void name(string theme)
    {
        chosen = theme;
        found = null;
    }

    /*
        The file for icon `iconName` at `size` points, `scale` device pixels to the point -- an SVG
        or a PNG -- or null if no theme has one. Themes list sizes in pixels at scale 1, and
        separately for 2x screens, so the scale picks the folders made for this screen.
    */
    static string lookup(string iconName, int size, int scale = 1)
    {
        const key = iconName ~ "@" ~ size.to!string ~ "x" ~ scale.to!string;
        if (auto hit = key in found)
            return *hit;
        string result;
        for (string n = iconName; n.length && !result.length; n = shorter(n))
            result = lookupExactly(n, size, scale);
        found[key] = result;
        return result;
    }

private:
    static string chosen;
    static string[string] found;       // lookup()'s answers, by name, size and scale
    static Theme[string] themes;       // read so far, by name; null for one that isn't there

    static string lookupExactly(string iconName, int size, int scale)
    {
        bool[string] seen;
        foreach (themeName; [name, "hicolor"])
            if (auto path = lookupIn(themeName, iconName, size, scale, seen))
                return path;
        // Last of all, the old place for apps' icons, unsorted by size
        foreach (base; baseDirs)
            foreach (ext; extensions)
            {
                const path = buildPath(base, "..", "pixmaps", iconName ~ ext);
                if (base.endsWith("/icons") && exists(path))
                    return path;
            }
        return null;
    }

    // The spec's FindIconHelper: this theme, then the ones it inherits from, depth first
    static string lookupIn(string themeName, string iconName, int size, int scale, ref bool[string] seen)
    {
        if (themeName in seen)
            return null;
        seen[themeName] = true;
        auto theme = load(themeName);
        if (!theme)
            return null;
        if (auto path = theme.find(iconName, size, scale))
            return path;
        foreach (parent; theme.inherits)
            if (auto path = lookupIn(parent, iconName, size, scale, seen))
                return path;
        return null;
    }

    static Theme load(string themeName)
    {
        if (auto t = themeName in themes)
            return *t;
        Theme theme;
        foreach (base; baseDirs)
        {
            const root = buildPath(base, themeName);
            const index = buildPath(root, "index.theme");
            if (!theme && exists(index))
            {
                try
                    theme = Theme.parse(readText(index));
                catch (Exception)
                    continue;
            }
            if (theme && exists(root) && isDir(root))
                theme.roots ~= root; // a theme can be spread over several base folders
        }
        themes[themeName] = theme;
        return theme;
    }
}

private:

immutable extensions = [".svg", ".png"]; // xpm, the spec's third, isn't something ThorVG reads

// Where themes are: the user's own, then the system's, in the spec's order
string[] baseDirs()
{
    static string[] dirs;
    if (dirs.length)
        return dirs;
    const home = environment.get("HOME", "");
    if (home.length)
        dirs ~= buildPath(home, ".icons");
    const dataHome = environment.get("XDG_DATA_HOME", home.length ? buildPath(home, ".local/share") : "");
    if (dataHome.length)
        dirs ~= buildPath(dataHome, "icons");
    foreach (d; environment.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").splitter(':'))
        if (d.length)
            dirs ~= buildPath(d, "icons");
    return dirs;
}

/// "edit-copy-symbolic" to "edit-symbolic", "edit-copy" to "edit"; "" when there's nothing shorter.
string shorter(string n) pure nothrow @safe
{
    enum suffix = "-symbolic";
    const symbolic = n.endsWith(suffix);
    const stem = symbolic ? n[0 .. $ - suffix.length] : n;
    size_t dash = stem.length;
    while (dash > 0 && stem[dash - 1] != '-')
        dash--;
    if (dash <= 1)
        return "";
    dash--; // onto the dash itself
    return stem[0 .. dash] ~ (symbolic ? suffix : "");
}

unittest
{
    assert(shorter("edit-copy-symbolic") == "edit-symbolic");
    assert(shorter("edit-symbolic") == "");
    assert(shorter("dialog-warning") == "dialog");
    assert(shorter("folder") == "");
}

enum DirType { threshold, fixed, scalable }

// One of a theme's folders, and the sizes of icon in it, as its index.theme describes it
struct Dir
{
    string path;
    int size, scale = 1, minSize, maxSize, threshold = 2;
    DirType type = DirType.threshold;

    // The spec's DirectoryMatchesSize
    bool matches(int want, int wantScale) const pure nothrow @safe
    {
        if (scale != wantScale)
            return false;
        final switch (type)
        {
            case DirType.fixed:     return size == want;
            case DirType.scalable:  return minSize <= want && want <= maxSize;
            case DirType.threshold: return size - threshold <= want && want <= size + threshold;
        }
    }

    // The spec's DirectorySizeDistance: in device pixels, so a 2x folder compares fairly
    int distance(int want, int wantScale) const pure nothrow @safe
    {
        const w = want * wantScale;
        final switch (type)
        {
            case DirType.fixed:
                return abs(size * scale - w);
            case DirType.scalable:
                return w < minSize * scale ? minSize * scale - w : w > maxSize * scale ? w - maxSize * scale : 0;
            case DirType.threshold:
                return w < (size - threshold) * scale ? (size - threshold) * scale - w
                     : w > (size + threshold) * scale ? w - (size + threshold) * scale : 0;
        }
    }

    static int abs(int v) pure nothrow @safe { return v < 0 ? -v : v; }
}

final class Theme
{
    string[] inherits;
    Dir[] dirs;
    string[] roots;                    // the folders it's in, one per base folder that has it
    bool[string][string] listings;     // the file names in each of its folders, read as needed

    /*
        The spec's LookupIcon: a folder made for this size if there is one, otherwise the nearest.
        Among equally good folders the first listed wins, which is how themes say which they'd
        rather -- and SVG before PNG in the same folder.
    */
    string find(string iconName, int size, int scale)
    {
        foreach (ref d; dirs)
            if (d.matches(size, scale))
                if (auto path = file(d, iconName))
                    return path;
        string best;
        int bestDistance = int.max;
        foreach (ref d; dirs)
        {
            const distance = d.distance(size, scale);
            if (distance >= bestDistance)
                continue;
            if (auto path = file(d, iconName))
            {
                best = path;
                bestDistance = distance;
            }
        }
        return best;
    }

    string file(ref const Dir d, string iconName)
    {
        foreach (root; roots)
        {
            const folder = buildPath(root, d.path);
            auto names = folder in listings;
            if (!names)
            {
                bool[string] listing;
                try
                    if (exists(folder) && isDir(folder))
                        foreach (entry; dirEntries(folder, SpanMode.shallow))
                            listing[baseName(entry.name)] = true;
                catch (Exception) {}
                listings[folder] = listing;
                names = folder in listings;
            }
            foreach (ext; extensions)
                if ((iconName ~ ext) in *names)
                    return buildPath(folder, iconName ~ ext);
        }
        return null;
    }

    /// Reads an index.theme: an ini file with an [Icon Theme] section naming the folders, then one section for each.
    static Theme parse(string text)
    {
        auto theme = new Theme;
        string[string][string] sections;
        string section;
        foreach (rawLine; text.splitter('\n'))
        {
            const line = rawLine.strip;
            if (!line.length || line[0] == '#')
                continue;
            if (line[0] == '[' && line[$ - 1] == ']')
            {
                section = line[1 .. $ - 1];
                continue;
            }
            const eq = line.indexOf('=');
            if (eq > 0)
                sections[section][line[0 .. eq].strip] = line[eq + 1 .. $].strip;
        }
        auto head = "Icon Theme" in sections;
        if (!head)
            throw new Exception("no [Icon Theme] section");
        string list(string key) { auto v = key in *head; return v ? *v : ""; }
        foreach (name; list("Inherits").splitter(','))
            if (name.strip.length)
                theme.inherits ~= name.strip;
        foreach (dirList; [list("Directories"), list("ScaledDirectories")])
            foreach (path; dirList.splitter(','))
            {
                const p = path.strip;
                auto keys = p in sections;
                if (!p.length || !keys || theme.dirs.canFind!(d => d.path == p))
                    continue;
                int number(string key, int otherwise)
                {
                    auto v = key in *keys;
                    try
                        return v ? (*v).to!int : otherwise;
                    catch (Exception)
                        return otherwise;
                }
                Dir d;
                d.path = p;
                d.size = number("Size", 0);
                d.scale = number("Scale", 1);
                d.minSize = number("MinSize", d.size);
                d.maxSize = number("MaxSize", d.size);
                d.threshold = number("Threshold", 2);
                if (auto type = "Type" in *keys)
                    d.type = *type == "Fixed" ? DirType.fixed : *type == "Scalable" ? DirType.scalable : DirType.threshold;
                if (d.size > 0)
                    theme.dirs ~= d;
            }
        return theme;
    }
}

unittest
{
    auto t = Theme.parse(`
[Icon Theme]
Name=Test
Inherits=Parent, hicolor
Directories=16x16/actions,scalable/actions,symbolic/actions
ScaledDirectories=16x16@2/actions

[16x16/actions]
Size=16
Type=Fixed

[16x16@2/actions]
Size=16
Scale=2
Type=Fixed

[scalable/actions]
Size=128
MinSize=8
MaxSize=512
Type=Scalable

[symbolic/actions]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
`);
    assert(t.inherits == ["Parent", "hicolor"]);
    assert(t.dirs.length == 4);
    assert(t.dirs[0].matches(16, 1) && !t.dirs[0].matches(16, 2) && t.dirs[3].matches(16, 2));
    assert(t.dirs[1].matches(24, 1) && t.dirs[1].distance(600, 1) == 88);
    assert(t.dirs[0].distance(24, 1) == 8);
}

// A theme laid out on disk, found through XDG_DATA_DIRS, inheriting and falling back
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    const base = buildPath(tempDir, "mayfair-icontheme-test");
    scope(exit) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "icons/Child/16x16/actions"));
    mkdirRecurse(buildPath(base, "icons/Child/scalable/actions"));
    mkdirRecurse(buildPath(base, "icons/hicolor/48x48/apps"));
    write(buildPath(base, "icons/Child/index.theme"),
          "[Icon Theme]\nDirectories=16x16/actions,scalable/actions\n"
          ~ "[16x16/actions]\nSize=16\nType=Fixed\n[scalable/actions]\nSize=64\nMinSize=8\nMaxSize=256\nType=Scalable\n");
    write(buildPath(base, "icons/hicolor/index.theme"),
          "[Icon Theme]\nDirectories=48x48/apps\n[48x48/apps]\nSize=48\nType=Threshold\n");
    write(buildPath(base, "icons/Child/16x16/actions/edit-copy.png"), "");
    write(buildPath(base, "icons/Child/scalable/actions/edit-copy.svg"), "");
    write(buildPath(base, "icons/Child/scalable/actions/edit-symbolic.svg"), "");
    write(buildPath(base, "icons/hicolor/48x48/apps/my-app.png"), "");

    // Everything else about the environment stays out of it
    const savedHome = environment.get("HOME"), savedData = environment.get("XDG_DATA_DIRS");
    environment["HOME"] = base;
    environment["XDG_DATA_DIRS"] = base;
    environment.remove("XDG_DATA_HOME");
    scope(exit)
    {
        environment["HOME"] = savedHome;
        if (savedData) environment["XDG_DATA_DIRS"] = savedData; else environment.remove("XDG_DATA_DIRS");
        IconTheme.themes = null;
    }
    IconTheme.themes = null;
    IconTheme.name = "Child";

    const copy16 = IconTheme.lookup("edit-copy", 16);
    assert(copy16.endsWith("16x16/actions/edit-copy.png"), copy16);
    assert(IconTheme.lookup("edit-copy", 32).endsWith("scalable/actions/edit-copy.svg"), "no 32: the scalable one");
    assert(IconTheme.lookup("edit-copy-symbolic", 16).endsWith("edit-symbolic.svg"), "shorter, still symbolic");
    assert(IconTheme.lookup("my-app", 16).endsWith("hicolor/48x48/apps/my-app.png"), "from hicolor, nearest size");
    assert(IconTheme.lookup("no-such-icon", 16) is null);
}

/// The desktop's icon theme, as mayfair.desktop finds it: Adwaita if nothing says.
string desktopIconTheme()
{
    import mayfair.desktop : Desktop;
    return Desktop.settings.iconTheme;
}
