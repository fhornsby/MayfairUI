module mayfair.desktop.gnome;

import mayfair.desktop;

/*
    GNOME's settings, and GTK's: the one place Mayfair reads them. Everything else asks
    mayfair.desktop, so a program for a desktop that isn't GNOME's leaves this out with version
    MayfairNoGnome, and a desktop with a store of its own gives Desktop a source for it.

    GNOME keeps its settings in GSettings, which only its own library or D-Bus can read, so this
    asks the `gsettings` tool: two of them at once, the first time a setting's wanted. What's read:

        org.gnome.desktop.interface icon-theme            the icon theme
        org.gnome.desktop.interface font-antialiasing     'grayscale' or 'rgba'
        org.gnome.desktop.interface font-rgba-order       'rgb', 'bgr', 'vrgb' or 'vbgr'
        org.gnome.desktop.wm.preferences button-layout    which window buttons go where

    and failing GSettings, GTK's settings.ini for the icon theme.

    Oriel keeps its icon theme in GSettings for now, but has no setting of its own for the window
    buttons, whose place on Oriel is always the same, or for antialiasing: GNOME's keys for them
    there are only GNOME's defaults, so on Oriel they're left unset, for Mayfair's own.
*/
package(mayfair) DesktopSettings gnomeSettings()
{
    version (Emscripten)
        return DesktopSettings.init; // a browser has no programs to run, and no desktop to ask
    else
    {
        const oriel = Desktop.isOriel();
        string[] commands = ["gsettings list-recursively org.gnome.desktop.interface"];
        if (!oriel)
            commands ~= "gsettings get org.gnome.desktop.wm.preferences button-layout";
        const outputs = runAll(commands);

        auto s = fromInterface(outputs[0], oriel);
        if (!oriel)
            s.buttonLayout = quoted(outputs[1]);
        if (s.iconTheme is null)
            s.iconTheme = gtkIconTheme();
        return s;
    }
}

/// What `gsettings list-recursively org.gnome.desktop.interface` says, for Mayfair.
package(mayfair) DesktopSettings fromInterface(string listed, bool oriel) pure @safe
{
    string iconTheme, antialiasing, order;
    foreach (line; lines(listed))
    {
        // "org.gnome.desktop.interface icon-theme 'Adwaita'": the schema, the key, the value
        const key = field(line, 1), value = quoted(rest(line, 2));
        if (key == "icon-theme")
            iconTheme = value;
        else if (key == "font-antialiasing" && !oriel)
            antialiasing = value;
        else if (key == "font-rgba-order" && !oriel)
            order = value;
    }
    return settingsFrom(iconTheme, null, antialiasing, order);
}

private:

/// Runs each of `commands` at once, and what each printed, or null for one that couldn't be run.
string[] runAll(string[] commands)
{
    import std.process : pipeShell, ProcessPipes, Redirect, wait;
    auto outputs = new string[commands.length];
    auto running = new ProcessPipes[commands.length];
    auto started = new bool[commands.length];
    foreach (i, c; commands)
    {
        try
        {
            running[i] = pipeShell(c, Redirect.stdout | Redirect.stderrToStdout);
            started[i] = true;
        }
        catch (Exception) {}
    }
    foreach (i; 0 .. commands.length)
    {
        if (!started[i])
            continue;
        try
        {
            string output;
            foreach (chunk; running[i].stdout.byChunk(4096))
                output ~= cast(const(char)[]) chunk;
            if (wait(running[i].pid) == 0)
                outputs[i] = output;
        }
        catch (Exception) {}
    }
    return outputs;
}

/// The icon theme GTK's settings.ini names, for GTK 4 or 3, or null.
string gtkIconTheme()
{
    import std.file : readText;
    import std.path : buildPath;
    import std.process : environment;
    const home = environment.get("HOME", "");
    const config = environment.get("XDG_CONFIG_HOME", home.length ? buildPath(home, ".config") : "");
    if (!config.length)
        return null;
    foreach (gtk; ["gtk-4.0", "gtk-3.0"])
    {
        try
        {
            if (auto name = iniValue(readText(buildPath(config, gtk, "settings.ini")), "gtk-icon-theme-name"))
                return name;
        }
        catch (Exception) {}
    }
    return null;
}

/// The value of `key = value` in an ini file's text, or null.
string iniValue(string text, string key) pure @safe
{
    foreach (line; lines(text))
    {
        const l = trimmed(line);
        if (l.length > key.length && l[0 .. key.length] == key)
        {
            const after = trimmed(l[key.length .. $]);
            if (after.length > 1 && after[0] == '=' && trimmed(after[1 .. $]).length)
                return trimmed(after[1 .. $]);
        }
    }
    return null;
}

/// A GVariant string as gsettings prints it, 'Adwaita', without its quotes; null if it isn't one.
string quoted(string v) pure nothrow @safe @nogc
{
    const t = trimmed(v);
    return t.length >= 2 && t[0] == '\'' && t[$ - 1] == '\'' ? t[1 .. $ - 1] : null;
}

string[] lines(string text) pure @safe
{
    string[] r;
    size_t start;
    foreach (i; 0 .. text.length + 1)
        if (i == text.length || text[i] == '\n')
        {
            r ~= text[start .. i];
            start = i + 1;
        }
    return r;
}

/// The `n`th of the words in `line` separated by spaces, or null.
string field(string line, size_t n) pure nothrow @safe @nogc
{
    size_t i;
    foreach (k; 0 .. n + 1)
    {
        while (i < line.length && line[i] == ' ')
            i++;
        const start = i;
        while (i < line.length && line[i] != ' ')
            i++;
        if (k == n)
            return start < i ? line[start .. i] : null;
    }
    return null;
}

/// All of `line` from its `n`th word on.
string rest(string line, size_t n) pure nothrow @safe @nogc
{
    size_t i;
    foreach (k; 0 .. n)
    {
        while (i < line.length && line[i] == ' ')
            i++;
        while (i < line.length && line[i] != ' ')
            i++;
    }
    return trimmed(line[i .. $]);
}

string trimmed(string s) pure nothrow @safe @nogc
{
    size_t a, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n'))
        a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n'))
        b--;
    return s[a .. b];
}

unittest
{
    enum listed = "org.gnome.desktop.interface clock-format '24h'\n"
                ~ "org.gnome.desktop.interface font-antialiasing 'rgba'\n"
                ~ "org.gnome.desktop.interface font-rgba-order 'bgr'\n"
                ~ "org.gnome.desktop.interface icon-theme 'Papirus Dark'\n"
                ~ "org.gnome.desktop.interface text-scaling-factor 1.0\n";
    const s = fromInterface(listed, false);
    assert(s.iconTheme == "Papirus Dark", s.iconTheme);
    assert(s.textAntialiasing == TextAntialiasing.subpixel && s.subpixelOrder == SubpixelOrder.bgr);

    // On Oriel, only what Oriel keeps there
    const o = fromInterface(listed, true);
    assert(o.iconTheme == "Papirus Dark");
    assert(o.textAntialiasing == TextAntialiasing.unset && o.subpixelOrder == SubpixelOrder.unset);

    assert(fromInterface("", false) == DesktopSettings.init, "gsettings not there");
    assert(quoted("'close,minimize:'\n") == "close,minimize:" && quoted("1.0") is null);
    assert(iniValue("[Settings]\ngtk-theme-name=Adwaita\ngtk-icon-theme-name = Papirus\n", "gtk-icon-theme-name") == "Papirus");
    assert(iniValue("[Settings]\ngtk-icon-theme-name=\n", "gtk-icon-theme-name") is null);
}
