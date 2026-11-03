import mayfair;
import markdown;
import std.algorithm : filter, sort, startsWith;
import std.array : array;
import std.file : dirEntries, exists, getcwd, isDir, readText, SpanMode, write;
import std.path : absolutePath, baseName, buildNormalizedPath, dirName;

/*
    A Markdown editor: a folder's files on the left, a tab per open document in the middle, and
    what the one being worked on looks like on the right.

        dub run                   the working directory's files
        dub run -- notes          a folder's
        dub run -- notes.md       a file, opened, with its folder's files
*/

enum sample = "# Markdown

Type in the middle and the **preview** follows on the right.

- Lists
- `code`
- [links](https://example.com)

> A quote.
";

/// A file or folder in the tree, shown by its name.
struct Entry
{
    string path;
    bool folder;

    string toString() const { return baseName(path); }
}

/// An open document: its file, if it has one, and the tab it's edited in.
final class Document
{
    string path;
    TextArea text;
    Tab tab;
    bool modified;

    this(string path, string content)
    {
        this.path = path;
        text = new TextArea(content).wrapText(true);
        text.margin(Insets(8));
        tab = new Tab(null, text).graphic(new Icon("text-x-generic-symbolic")).closable(true);
        showName();
    }

    void showName()
    {
        tab.text = (modified ? "• " : "") ~ (path ? baseName(path) : "Untitled");
    }
}

class Editor
{
    Column root;
    TreeView!Entry files;
    TabPane tabs;
    LiteWebView preview;
    CheckMenuItem showPreview;
    Document[] documents;

    this(string start)
    {
        files = new TreeView!Entry().showRoot(false).placeholder("No folder open");
        files.prefWidth(220);
        files.onSelectionChanged({
            if (auto item = files.selectedItem)
                if (!item.value.folder)
                    open(item.value.path);
        });

        tabs = new TabPane();
        tabs.grow(1);
        tabs.selectedIndexProperty.addListener((int was, int now) { render(); });

        preview = new LiteWebView();
        preview.grow(1);

        auto panes = new Row().spacing(8).padding(8)
            .add(files)
            .add(tabs)
            .add(preview);
        panes.grow(1);

        root = new Column();
        root.add(buildMenuBar()).add(panes);

        start = absolutePath(start ? start : getcwd());
        if (start.exists && start.isDir)
            openFolder(start);
        else
        {
            openFolder(dirName(start));
            if (start.exists)
                open(start);
        }
        if (!documents.length)
            add(new Document(null, sample));
    }

    /// The document in the selected tab, or null.
    Document current()
    {
        auto tab = tabs.selectedTab;
        foreach (d; documents)
            if (d.tab is tab)
                return d;
        return null;
    }

    void render()
    {
        auto d = current;
        if (!d)
            preview.loadContent("");
        else
            preview.loadContent(toHtml(d.text.text), d.path ? dirName(d.path) ~ "/" : null);
    }

    void openFolder(string folder)
    {
        auto top = new TreeItem!Entry(Entry(folder, true));
        top.childrenLoader(() => list(folder));
        top.setExpanded(true);
        files.root = top;
    }

    /// A folder's files and folders, folders first, each in name order; hidden ones left out.
    TreeItem!Entry[] list(string folder)
    {
        Entry[] entries;
        try
            foreach (e; dirEntries(folder, SpanMode.shallow))
                if (!baseName(e.name).startsWith("."))
                    entries ~= Entry(e.name, e.isDir);
        catch (Exception)
        {
        } // unreadable: shown empty
        entries.sort!((a, b) => a.folder != b.folder ? a.folder : baseName(a.path) < baseName(b.path));

        TreeItem!Entry[] items;
        foreach (e; entries)
        {
            auto item = new TreeItem!Entry(e).icon(e.folder ? "folder-symbolic" : "text-x-generic-symbolic");
            if (e.folder)
            {
                const path = e.path;
                item.childrenLoader(() => list(path));
            }
            items ~= item;
        }
        return items;
    }

    /// Shows `file`'s tab, opening it in one first if it hasn't one.
    void open(string file)
    {
        file = buildNormalizedPath(absolutePath(file));
        foreach (d; documents)
            if (d.path == file)
                return tabs.select(d.tab);
        string content;
        try
            content = readText(file);
        catch (Exception e)
            content = "Couldn't read " ~ file ~ ": " ~ e.msg;
        add(new Document(file, content));
    }

    void add(Document d)
    {
        documents ~= d;
        d.text.textProperty.addListener((string was, string now) {
            if (!d.modified)
            {
                d.modified = true;
                d.showName();
            }
            if (d is current)
                render();
        });
        d.tab.onClosed({
            documents = documents.filter!(o => o !is d).array;
            render();
        });
        tabs.add(d.tab);
        tabs.select(d.tab);
        render();
    }

    void saveTo(Document d, string file)
    {
        if (!file)
            return;
        d.path = file;
        write(file, d.text.text);
        d.modified = false;
        d.showName();
        render(); // its pictures are now relative to where it is
    }

    void save()
    {
        auto d = current;
        if (!d)
            return;
        if (d.path)
            saveTo(d, d.path);
        else
            saveAs();
    }

    void saveAs()
    {
        auto d = current;
        if (!d)
            return;
        new FileChooser().title("Save as").initialFileName(d.path ? baseName(d.path) : "Untitled.md")
            .addFilter("Markdown", "md")
            .showSaveDialog(root, (string file) { saveTo(d, file); });
    }

    MenuBar buildMenuBar()
    {
        return new MenuBar()
            .add(new Menu("File")
                .add(new MenuItem("New", { add(new Document(null, "")); }).accelerator("Ctrl+N"))
                .add(new MenuItem("Open…", {
                        new FileChooser().title("Open a Markdown file").addFilter("Markdown", "md", "markdown")
                            .showOpenDialog(root, (string file) { if (file) open(file); });
                    }).accelerator("Ctrl+O").graphic(new Icon("document-open-symbolic")))
                .add(new MenuItem("Open folder…", {
                        new FileChooser().title("Open a folder")
                            .showDirectoryDialog(root, (string folder) { if (folder) openFolder(folder); });
                    }).accelerator("Ctrl+Shift+O").graphic(new Icon("folder-open-symbolic")))
                .add(new MenuItem("Save", { save(); }).accelerator("Ctrl+S").graphic(new Icon("document-save-symbolic")))
                .add(new MenuItem("Save as…", { saveAs(); }).accelerator("Ctrl+Shift+S"))
                .add(new MenuSeparator())
                .add(new MenuItem("Quit", { App.quit(); }).accelerator("Ctrl+Q")))
            .add(new Menu("View")
                .add(showPreview = new CheckMenuItem("Show preview", { preview.visible(showPreview.selected); })
                    .selected(true).accelerator("F9")));
    }
}

void main(string[] args)
{
    auto app = new App("Markdown");
    app.setSize(1200, 700);
    auto editor = new Editor(args.length > 1 ? args[1] : null);
    app.scene = new Scene(editor.root);
    app.run();
}
