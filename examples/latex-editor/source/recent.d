module recent;

import std.algorithm : filter;
import std.array : array, join, split;
import std.file : exists, isDir, mkdirRecurse, readText, write;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;

/*
    The projects opened lately, most recent first, kept between runs in the user's configuration
    folder, $XDG_CONFIG_HOME/overbrief/recent (~/.config/overbrief/recent), a folder to a line.
    The menu lists them, and the app opens the first when it starts with no project named.
*/

/// How many it keeps.
enum keep = 8;

/// The projects, most recent first: those still there.
string[] recentProjects()
{
    try
    {
        if (!exists(file))
            return null;
        return readText(file).split("\n").filter!(p => p.length && exists(p) && isDir(p)).array;
    }
    catch (Exception)
        return null;
}

/// Puts `folder` first.
void remember(string folder)
{
    auto list = [folder] ~ recentProjects().filter!(p => p != folder).array;
    if (list.length > keep)
        list = list[0 .. keep];
    try
    {
        mkdirRecurse(dirName(file));
        write(file, list.join("\n") ~ "\n");
    }
    catch (Exception) {} // not kept: no harm
}

private string file()
{
    const config = environment.get("XDG_CONFIG_HOME", expandTilde("~/.config"));
    return buildPath(config, "overbrief", "recent");
}
