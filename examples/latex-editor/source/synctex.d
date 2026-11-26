module synctex;

import core.thread : Thread;
import std.conv : to;
import std.format : format;
import std.path : buildNormalizedPath;
import std.process : execute;
import std.string : lineSplitter, startsWith, strip;
import mayfair;

/*
    SyncTeX: the map TeX writes beside the PDF (main.synctex.gz, with -synctex=1) from each place
    in the PDF to the line of source that made it. Asked through the synctex program, which comes
    with TeX Live, on a thread of its own, the answer handed back on the UI thread.

        Source to PDF: where line 12 of intro.tex ended up, to scroll the PDF there
        PDF to source: which line made what's at a place on page 3, to put the caret there
*/

/// A place in the PDF: a page, from 0, and a point on it, in points from its top left.
struct PdfPlace
{
    int page = -1;
    float x = 0, y = 0;
    float width = 0, height = 0; /// The box the line's in, where SyncTeX says
}

/// A place in the source: a file, and a line from 1.
struct SourcePlace
{
    string file;
    int line;
}

/// Where in `pdf` line `line` of `file` is; `done` is told, or given a page of -1 if SyncTeX doesn't know.
void sourceToPdf(string pdf, string file, int line, void delegate(PdfPlace) done)
{
    new Thread({
        PdfPlace place;
        try
        {
            const r = execute(["synctex", "view", "-i", format!"%s:0:%s"(line, file), "-o", pdf]);
            if (r.status == 0)
                place = parseView(r.output);
        }
        catch (Exception) {} // not installed: nothing found
        Platform.runLater(handing(done, place));
    }).start();
}

/// Which source made what's at `x`, `y` on page `page` (from 0) of `pdf`; `done` is told, or given no file.
void pdfToSource(string pdf, int page, float x, float y, void delegate(SourcePlace) done)
{
    new Thread({
        SourcePlace place;
        try
        {
            const r = execute(["synctex", "edit", "-o", format!"%s:%s:%s:%s"(page + 1, x, y, pdf)]);
            if (r.status == 0)
                place = parseEdit(r.output);
        }
        catch (Exception) {}
        Platform.runLater(handing(done, place));
    }).start();
}

private:

// Each answer's closure of its own
void delegate() handing(T)(void delegate(T) done, T place)
{
    return { done(place); };
}

// synctex view's answer: the first of the boxes it lists. Page from 1; h, v the box's left and
// baseline, W, H its size; x, y the point, all in big points (a PDF's points) from the top left
PdfPlace parseView(string output)
{
    PdfPlace p;
    foreach (line; output.lineSplitter)
    {
        const at = indexOfColon(line);
        if (at < 0)
            continue;
        const key = line[0 .. at], value = line[at + 1 .. $].strip;
        try
        {
            switch (key)
            {
                case "Page":
                    if (p.page >= 0)
                        return p; // the next box: the first's enough
                    p.page = value.to!int - 1;
                    break;
                case "x": p.x = value.to!float; break;
                case "y": p.y = value.to!float; break;
                case "W": p.width = value.to!float; break;
                case "H": p.height = value.to!float; break;
                default: break;
            }
        }
        catch (Exception) {}
    }
    return p;
}

// synctex edit's answer: Input, the file, and Line
SourcePlace parseEdit(string output)
{
    SourcePlace s;
    foreach (line; output.lineSplitter)
    {
        if (line.startsWith("Input:") && !s.file.length)
            s.file = buildNormalizedPath(line["Input:".length .. $].strip);
        else if (line.startsWith("Line:") && !s.line)
        {
            try
                s.line = line["Line:".length .. $].strip.to!int;
            catch (Exception) {}
        }
    }
    return s;
}

ptrdiff_t indexOfColon(string s)
{
    foreach (i, c; s)
        if (c == ':')
            return i;
    return -1;
}

unittest
{
    const view = "This is SyncTeX command line utility, version 1.5\nSyncTeX result begin\nOutput:main.pdf\n"
        ~ "Page:2\nx:133.768356\ny:250.071564\nh:133.768356\nv:252.162186\nW:343.711060\nH:9.464540\nbefore:\n"
        ~ "Page:2\nx:140\ny:300\nSyncTeX result end\n";
    auto p = parseView(view);
    assert(p.page == 1 && p.y > 250 && p.y < 251 && p.width > 343);
    auto s = parseEdit("SyncTeX result begin\nOutput:/p/main.pdf\nInput:/p/./intro.tex\nLine:12\nColumn:-1\n");
    assert(s.file == "/p/intro.tex" && s.line == 12);
}
