module mayfair.desktop;

import std.process : environment;

/*
    What the desktop wants of an app's look: its icon theme, where it puts the window buttons, and
    how it draws text. Everything in Mayfair that follows the desktop asks here, and nothing asks a
    desktop's own settings store itself, so no desktop's is built into the rest: GNOME's is read by
    mayfair.desktop.gnome alone, and a desktop of its own -- Oriel's, say -- adds a source here and
    needs nothing else changed.

    Each setting is the first of these to say what it is:

    1. The environment, for trying a setting out, or for an app that knows better:

           MAYFAIR_ICON_THEME=Papirus
           MAYFAIR_BUTTON_LAYOUT=close:            (see TitleBar)
           MAYFAIR_TEXT_ANTIALIASING=subpixel      or greyscale
           MAYFAIR_SUBPIXEL_ORDER=rgb              or bgr, vrgb, vbgr

    2. Sources the app's added with Desktop.addSource, the last added first: a desktop's own
       integration, which asks it however it's asked.

           Desktop.addSource(() {
               DesktopSettings s;
               s.iconTheme = orielSettings.iconTheme;   // what it knows; the rest left unset
               return s;
           });

    3. The desktop's own store, as read by what's built in for it: GNOME's GSettings, which is
       where Oriel keeps its settings for now too (mayfair.desktop.gnome). A program compiled with
       version MayfairNoGnome has none.

    4. Mayfair's own defaults.

    They're read once, the first time a setting's asked for, and kept: Desktop.refresh() reads
    them again, for a setting that's changed while the app runs.
*/

/// How text is antialiased: greyscale, or a subpixel's worth of detail across, in colour.
enum TextAntialiasing : ubyte
{
    unset,      /// Mayfair's choice: subpixel on a display of ordinary density, greyscale on a dense one
    greyscale,  /// Shades of the text's colour: what's right for a dense display, and over anything
    subpixel,   /// Each pixel's red, green and blue lit on their own, as ClearType does: sharper on an ordinary display
}

/// Which way the red, green and blue of a display's pixels are laid out, for subpixel text.
enum SubpixelOrder : ubyte
{
    unset,
    rgb,        /// Red on the left, as nearly every display has them
    bgr,        /// Blue on the left
    vrgb,       /// In rows, red at the top
    vbgr,       /// In rows, blue at the top
}

/// What a desktop wants. Anything a source doesn't know, it leaves unset: null, or `unset`.
struct DesktopSettings
{
    string iconTheme;                   /// The freedesktop.org icon theme icons are looked up in, by name
    string buttonLayout;                /// Which window buttons go where, as TitleBar reads it
    TextAntialiasing textAntialiasing;
    SubpixelOrder subpixelOrder;

    /// Takes whatever this hasn't been told from `other`.
    void fillFrom(const DesktopSettings other) pure nothrow @safe @nogc
    {
        if (iconTheme is null)
            iconTheme = other.iconTheme;
        if (buttonLayout is null)
            buttonLayout = other.buttonLayout;
        if (textAntialiasing == TextAntialiasing.unset)
            textAntialiasing = other.textAntialiasing;
        if (subpixelOrder == SubpixelOrder.unset)
            subpixelOrder = other.subpixelOrder;
    }
}

/// Something that knows what the desktop wants, and says, leaving unset what it doesn't know.
alias DesktopSource = DesktopSettings delegate();

/// The desktop's settings, from wherever they're kept: see the top of this module.
struct Desktop
{
static:
    /// What the desktop wants, each setting from the first that says.
    DesktopSettings settings() @trusted
    {
        synchronized
        {
            if (!read)
            {
                current = gather(fromEnvironment(), sources, &builtIn);
                read = true;
            }
            return current;
        }
    }

    /// Asks `source` before the built-in readers, and before any added earlier. Read from the
    /// next time a setting's asked for.
    void addSource(DesktopSource source) @trusted
    {
        synchronized
        {
            sources = source ~ sources;
            read = false;
        }
    }

    /// Reads the settings again the next time one's asked for.
    void refresh() @trusted
    {
        synchronized
            read = false;
    }

    /// Whether this is the Oriel desktop: $XDG_CURRENT_DESKTOP, a list separated by colons, names it.
    bool isOriel() @trusted
    {
        return names(environment.get("XDG_CURRENT_DESKTOP", ""), "Oriel");
    }

private:
    __gshared DesktopSettings current;
    __gshared bool read;
    __gshared DesktopSource[] sources;
}

/// The settings `environment` says, from what's in it, then each of `sources`, then `builtIn`'s, then the defaults.
package(mayfair) DesktopSettings gather(DesktopSettings environment, DesktopSource[] sources, DesktopSettings function() builtIn)
{
    auto s = environment;
    foreach (source; sources)
    {
        try
            s.fillFrom(source());
        catch (Exception) {} // a source that can't say, says nothing
    }
    try
        s.fillFrom(builtIn());
    catch (Exception) {}
    s.fillFrom(defaults);
    return s;
}

/// What Mayfair does when nothing says: Adwaita's icons, as GNOME's default is, and the window
/// buttons at the end. Text's antialiasing is left for Mayfair to choose by the display's density.
package(mayfair) enum DesktopSettings defaults = () {
    DesktopSettings s;
    s.iconTheme = "Adwaita";
    s.buttonLayout = ":minimize,maximize,close";
    s.subpixelOrder = SubpixelOrder.rgb;
    return s;
}();

/// What the MAYFAIR_ environment variables say.
package(mayfair) DesktopSettings fromEnvironment() @trusted
{
    return settingsFrom(environment.get("MAYFAIR_ICON_THEME"), environment.get("MAYFAIR_BUTTON_LAYOUT"),
                        environment.get("MAYFAIR_TEXT_ANTIALIASING"), environment.get("MAYFAIR_SUBPIXEL_ORDER"));
}

/// Settings from their text, as the environment, or a desktop's store, has them. Anything that
/// isn't one of the values a setting can be is left unset.
package(mayfair) DesktopSettings settingsFrom(string iconTheme, string buttonLayout, string antialiasing, string order) pure @safe
{
    DesktopSettings s;
    if (iconTheme.length)
        s.iconTheme = iconTheme;
    if (buttonLayout.length)
        s.buttonLayout = buttonLayout;
    s.textAntialiasing = antialiasingFrom(antialiasing);
    s.subpixelOrder = orderFrom(order);
    return s;
}

/// greyscale or grayscale, subpixel or rgba (as GNOME and fontconfig call it); anything else unset.
package(mayfair) TextAntialiasing antialiasingFrom(string text) pure nothrow @safe @nogc
{
    switch (text)
    {
        case "greyscale", "grayscale": return TextAntialiasing.greyscale;
        case "subpixel", "rgba": return TextAntialiasing.subpixel;
        default: return TextAntialiasing.unset;
    }
}

/// rgb, bgr, vrgb or vbgr; anything else unset.
package(mayfair) SubpixelOrder orderFrom(string text) pure nothrow @safe @nogc
{
    switch (text)
    {
        case "rgb": return SubpixelOrder.rgb;
        case "bgr": return SubpixelOrder.bgr;
        case "vrgb": return SubpixelOrder.vrgb;
        case "vbgr": return SubpixelOrder.vbgr;
        default: return SubpixelOrder.unset;
    }
}

/// Whether `list`, separated by colons, has `name` in it.
package(mayfair) bool names(string list, string name) pure nothrow @safe @nogc
{
    size_t start;
    foreach (i; 0 .. list.length + 1)
        if (i == list.length || list[i] == ':')
        {
            if (list[start .. i] == name)
                return true;
            start = i + 1;
        }
    return false;
}

private:

/// What's built in: the desktop's own store, where there's a reader for it.
DesktopSettings builtIn()
{
    version (MayfairNoGnome)
        return DesktopSettings.init;
    else
    {
        import mayfair.desktop.gnome : gnomeSettings;
        return gnomeSettings();
    }
}

unittest
{
    // Each setting from the first that says it, then the defaults
    DesktopSettings env;
    env.iconTheme = "FromEnvironment";
    DesktopSettings added;
    added.iconTheme = "FromSource";
    added.textAntialiasing = TextAntialiasing.greyscale;
    static DesktopSettings store()
    {
        DesktopSettings s;
        s.iconTheme = "FromStore";
        s.buttonLayout = "close:";
        s.textAntialiasing = TextAntialiasing.subpixel;
        return s;
    }
    DesktopSource[] sources = [() => added, () { throw new Exception("can't say"); return DesktopSettings.init; }];
    const s = gather(env, sources, &store);
    assert(s.iconTheme == "FromEnvironment");
    assert(s.textAntialiasing == TextAntialiasing.greyscale, "a source before the store");
    assert(s.buttonLayout == "close:", "the store, as nothing before it says");
    assert(s.subpixelOrder == SubpixelOrder.rgb, "the default, as nothing says");

    static DesktopSettings nothing() { return DesktopSettings.init; }
    const d = gather(DesktopSettings.init, null, &nothing);
    assert(d.iconTheme == "Adwaita" && d.buttonLayout == ":minimize,maximize,close");
    assert(d.textAntialiasing == TextAntialiasing.unset, "left for Mayfair to choose by the display");

    // From text
    const t = settingsFrom("Papirus", "", "rgba", "bgr");
    assert(t.iconTheme == "Papirus" && t.buttonLayout is null);
    assert(t.textAntialiasing == TextAntialiasing.subpixel && t.subpixelOrder == SubpixelOrder.bgr);
    assert(antialiasingFrom("grayscale") == TextAntialiasing.greyscale);
    assert(antialiasingFrom("none") == TextAntialiasing.unset && orderFrom("") == SubpixelOrder.unset);

    assert(names("Oriel", "Oriel") && names("ubuntu:GNOME", "GNOME") && !names("GNOME-Classic", "GNOME"));
}
