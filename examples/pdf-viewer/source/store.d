module store;

/*
    What the viewer keeps between runs, in its own folder of the user's settings: the signatures
    drawn, the bookmarks made, and the PDFs opened lately. Plain text, a line each.

        Linux, BSD:  $XDG_CONFIG_HOME/mayfair-pdf-viewer, or ~/.config/mayfair-pdf-viewer
        macOS:       ~/Library/Application Support/mayfair-pdf-viewer
        Windows:     %APPDATA%\mayfair-pdf-viewer
*/

import std.algorithm : canFind, filter, remove;
import std.array : array, join, split;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.format : format;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.string : lineSplitter, strip;
import mayfair.pdf : PdfAnnotation, PdfAnnotationKind, PdfPoint, PdfRect;

/// The folder, made if it isn't there.
string folder()
{
    version (Windows)
        auto base = environment.get("APPDATA", ".");
    else version (OSX)
        auto base = buildPath(environment.get("HOME", "."), "Library", "Application Support");
    else
        auto base = environment.get("XDG_CONFIG_HOME", buildPath(environment.get("HOME", "."), ".config"));
    auto f = buildPath(base, "mayfair-pdf-viewer");
    try
        mkdirRecurse(f);
    catch (Exception) {}
    return f;
}

private string[] lines(string name)
{
    const file = buildPath(folder, name);
    try
        return exists(file) ? readText(file).lineSplitter.filter!(l => l.strip.length).array : null;
    catch (Exception)
        return null;
}

private void keep(string name, string[] list)
{
    try
        write(buildPath(folder, name), list.join("\n") ~ "\n");
    catch (Exception) {}
}

// Signatures: each a line of strokes, "x y x y ...;x y ..." in a box 0..1 across, as tall as it is

/// The signatures drawn, as signature annotations: strokes in their rect.
PdfAnnotation[] signatures()
{
    PdfAnnotation[] found;
    foreach (line; lines("signatures"))
    {
        PdfAnnotation a;
        a.kind = PdfAnnotationKind.signature;
        a.colour.r = a.colour.g = 0;
        a.colour.b = 0;
        a.lineWidth = 1.5;
        float maxY = 0;
        try
            foreach (s; line.split(";"))
            {
                auto numbers = s.split(" ");
                PdfPoint[] stroke;
                for (size_t i = 0; i + 1 < numbers.length; i += 2)
                {
                    const p = PdfPoint(numbers[i].to!float * 160, numbers[i + 1].to!float * 160);
                    if (p.y > maxY)
                        maxY = p.y;
                    stroke ~= p;
                }
                if (stroke.length)
                    a.strokes ~= stroke;
            }
        catch (Exception)
            continue;
        if (!a.strokes.length)
            continue;
        a.rect = PdfRect(0, 0, 160, maxY > 1 ? maxY : 40);
        found ~= a;
    }
    return found;
}

/// Keeps a signature: `strokes`, in a box `width` across.
void addSignature(PdfPoint[][] strokes, float width)
{
    string[] parts;
    foreach (s; strokes)
    {
        string[] numbers;
        foreach (p; s)
            numbers ~= format!"%.4f %.4f"(p.x / width, p.y / width);
        parts ~= numbers.join(" ");
    }
    keep("signatures", lines("signatures") ~ parts.join(";"));
}

void removeSignatures() { keep("signatures", null); }

// Bookmarks: "path<TAB>page<TAB>label"

struct Bookmark
{
    int page;
    string label;
}

Bookmark[] bookmarks(string pdf)
{
    Bookmark[] found;
    const key = absolutePath(pdf);
    foreach (line; lines("bookmarks"))
    {
        auto f = line.split("\t");
        if (f.length >= 3 && f[0] == key)
            try
                found ~= Bookmark(f[1].to!int, f[2]);
            catch (Exception) {}
    }
    return found;
}

void addBookmark(string pdf, Bookmark b)
{
    keep("bookmarks", lines("bookmarks") ~ format!"%s\t%s\t%s"(absolutePath(pdf), b.page, b.label));
}

void removeBookmark(string pdf, Bookmark b)
{
    const line = format!"%s\t%s\t%s"(absolutePath(pdf), b.page, b.label);
    keep("bookmarks", lines("bookmarks").filter!(l => l != line).array);
}

// Recent PDFs: newest first, ten at most

string[] recent() { return lines("recent").filter!(p => exists(p)).array; }

void opened(string pdf)
{
    const path = absolutePath(pdf);
    auto list = [path] ~ lines("recent").filter!(p => p != path).array;
    keep("recent", list.length > 10 ? list[0 .. 10] : list);
}
