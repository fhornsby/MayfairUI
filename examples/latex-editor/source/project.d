module project;

import std.algorithm : canFind, sort, startsWith;
import std.file : dirEntries, exists, isDir, isFile, readText, SpanMode;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, extension, relativePath, stripExtension;
import mayfair;

/*
    A project: a folder holding a document's files, as an Overleaf project is. One of its .tex
    files is the main one, the whole document, which the others are \input into; that's the one
    compiled. What compiling makes goes in .build/ inside it, out of the way of the tree.
*/
final class Project
{
    string folder;   /// Where it is
    string mainFile; /// The file that's compiled, or null if there's no .tex file with a \documentclass

    this(string folder)
    {
        this.folder = buildNormalizedPath(absolutePath(folder));
        mainFile = findMain();
    }

    /// Its name, for the title bar: its folder's.
    string name() const { return baseName(folder); }

    /// Where compiling puts what it makes: the PDF, its log, and its SyncTeX.
    string outputFolder() const { return buildPath(folder, ".build"); }

    /// The PDF compiling makes.
    string pdf() const
    {
        return mainFile ? buildPath(outputFolder, stripExtension(baseName(mainFile)) ~ ".pdf") : null;
    }

    /// `path` from the project's folder, for showing.
    string relative(string path) const { return relativePath(path, folder); }

    /*
        The file that's the whole document: main.tex, if there's one with a \documentclass,
        otherwise the first .tex file at the top that has one, otherwise the first anywhere.
    */
    string findMain()
    {
        static bool isDocument(string path)
        {
            try
                return readText(path).canFind("\\documentclass");
            catch (Exception)
                return false;
        }
        const preferred = buildPath(folder, "main.tex");
        if (exists(preferred) && isDocument(preferred))
            return preferred;
        string[] top, deeper;
        try
            foreach (e; dirEntries(folder, "*.tex", SpanMode.breadth))
            {
                if (!e.isFile || hidden(e.name))
                    continue;
                (relativePath(e.name, folder).canFind('/') ? deeper : top) ~= e.name;
            }
        catch (Exception) {}
        top.sort();
        deeper.sort();
        foreach (path; top ~ deeper)
            if (isDocument(path))
                return path;
        return null;
    }

    /// What's in `dir`, for the tree: folders first, then files, each in name order, hidden ones
    /// and the build folder left out. A folder's own are read as it's opened.
    TreeItem!Entry[] list(string dir)
    {
        Entry[] entries;
        try
            foreach (e; dirEntries(dir, SpanMode.shallow))
                if (!hidden(e.name))
                    entries ~= Entry(e.name, e.isDir);
        catch (Exception) {} // unreadable: shown empty
        entries.sort!((a, b) => a.folder != b.folder ? a.folder : baseName(a.path) < baseName(b.path));
        TreeItem!Entry[] items;
        foreach (e; entries)
            items ~= item(e);
        return items;
    }

    /// The tree's top: the project's folder, open.
    TreeItem!Entry root()
    {
        auto top = new TreeItem!Entry(Entry(folder, true));
        top.childrenLoader(() => list(folder));
        top.setExpanded(true);
        return top;
    }

private:
    TreeItem!Entry item(Entry e)
    {
        auto item = new TreeItem!Entry(e).icon(iconFor(e));
        if (e.folder)
        {
            const path = e.path; // each its own: a closure in a loop would share the loop's
            item.childrenLoader(() => list(path));
        }
        return item;
    }

    static bool hidden(string path)
    {
        const name = baseName(path);
        return name.startsWith(".") || name == "node_modules";
    }

    static string iconFor(Entry e)
    {
        if (e.folder)
            return "folder-symbolic";
        switch (extension(e.path))
        {
            case ".tex", ".sty", ".cls", ".bib": return "text-x-generic-symbolic";
            case ".pdf": return "x-office-document-symbolic";
            case ".png", ".jpg", ".jpeg", ".svg", ".eps": return "image-x-generic-symbolic";
            default: return "text-x-generic-symbolic";
        }
    }
}

/// A file or folder in the tree, shown by its name.
struct Entry
{
    string path;
    bool folder;

    string toString() const { return baseName(path); }
}
