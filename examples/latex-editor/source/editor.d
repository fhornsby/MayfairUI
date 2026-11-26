module editor;

import std.algorithm : filter, sort, startsWith;
import std.array : array;
import std.conv : to;
import std.file : dirEntries, exists, getcwd, isDir, readText, SpanMode, write;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, dirName;
import std.string : strip;
import mayfair;
import mayfair.code;

/// A file or folder in the tree, shown by its name.
struct Entry
{
    string path;
    bool folder;

    string toString() const { return baseName(path); }
}

/// An open file: its buffer, the view it's edited in, its tab, and what reads it.
final class Document
{
    string path;
    TextBuffer buffer;
    TextView view;
    Tab tab;
    Language language;
    SyntaxHighlighter highlighter;
    LspDocument lsp;
    LspEditor lspEditor;

    this(string path, string content)
    {
        this.path = path;
        buffer = new TextBuffer(content);
        view = new TextView(buffer).showLineNumbers(true).highlightCurrentLine(true);
        view.setGrow(1);
        tab = new Tab(null, view).graphic(new Icon("text-x-generic-symbolic")).closable(true);
        setLanguage(path ? languageFor(path) : null);
        showName();
        buffer.modifiedProperty.addListener((bool was, bool now) { showName(); });
    }

    void setLanguage(Language l)
    {
        language = l;
        if (highlighter)
            highlighter.setLanguage(l);
        else
            highlighter = new SyntaxHighlighter(buffer, l);
        highlighter.follow(view);
    }

    void showName()
    {
        tab.text = (buffer.modified ? "• " : "") ~ (path ? baseName(path) : "Untitled");
    }
}

final class Editor
{
    Dock root;
    TitleBar titleBar;
    Column sidebar;
    TreeView!Entry files;
    TabPane tabs;
    Document[] documents;
    LanguageServer[string] servers;   // by language: one each, shared by its files
    string folder;

    // The find bar, and the status line
    Row findBar;
    TextField findField, replaceField;
    ToggleButton matchCase, wholeWord;
    Label findCount, position, languageLabel, indentLabel, serverLabel, problemsLabel;
    bool sidebarShown = true;

    this(string start)
    {
        files = new TreeView!Entry().showRoot(false).placeholder("No folder open");
        files.setGrow(1);
        files.onSelectionChanged({
            if (auto item = files.selectedItem)
                if (!item.value.folder)
                    open(item.value.path);
        });
        sidebar = new Column().prefWidth(240).minWidth(240).maxWidth(240);
        sidebar.styleClass.add("sidebar");
        sidebar.add(new Label("Files").styleClass("sidebar-heading")).add(files);

        tabs = new TabPane();
        tabs.setGrow(1);
        tabs.selectedIndexProperty.addListener((int was, int now) { showStatus(); });

        buildFindBar();
        buildStatus();
        auto page = new Column().grow(1);
        page.styleClass.add("page");
        page.add(tabs).add(findBar).add(statusLine);
        findBar.setVisible(false);

        root = new EditorRoot(this);
        root.setLeft(sidebar);
        root.setCentre(page);
        buildTitleBar();

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
            add(new Document(null, ""));
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

    void openFolder(string f)
    {
        folder = f;
        auto top = new TreeItem!Entry(Entry(f, true));
        top.childrenLoader(() => list(f));
        top.setExpanded(true);
        files.root = top;
        titleBar.setTitle(baseName(f));
    }

    /// A folder's files and folders, folders first, each in name order; hidden ones left out.
    TreeItem!Entry[] list(string f)
    {
        Entry[] entries;
        try
            foreach (e; dirEntries(f, SpanMode.shallow))
                if (!baseName(e.name).startsWith(".") && baseName(e.name) != "node_modules")
                    entries ~= Entry(e.name, e.isDir);
        catch (Exception) {} // unreadable: shown empty
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

    /// Shows `file`'s tab, opening it in one first if it hasn't one; and puts the caret at `at`, if it's given.
    Document open(string file, TextPosition at = TextPosition(-1, 0))
    {
        file = buildNormalizedPath(absolutePath(file));
        foreach (d; documents)
            if (d.path == file)
            {
                tabs.select(d.tab);
                if (at.line >= 0)
                    d.view.placeCaret(at);
                d.view.requestFocus();
                return d;
            }
        string content;
        try
            content = readText(file);
        catch (Exception e)
        {
            say("Couldn't read " ~ baseName(file) ~ ": " ~ e.msg);
            return null;
        }
        auto d = new Document(file, content);
        add(d);
        if (at.line >= 0)
            d.view.placeCaret(at);
        return d;
    }

    void add(Document d)
    {
        documents ~= d;
        d.tab.onCloseRequest(() {
            if (!d.buffer.modified)
                return true;
            askToSave(d, { closeDocument(d); });
            return false;
        });
        d.tab.onClosed({ forget(d); });
        d.view.caretPositionProperty.addListener((TextPosition was, TextPosition now) {
            if (d is current)
                showPosition();
        });
        connect(d);
        tabs.add(d.tab);
        tabs.select(d.tab);
        d.view.requestFocus();
        showStatus();
    }

    /// The document's language server, if one for its language is installed: started once, shared.
    void connect(Document d)
    {
        if (!d.path || !d.language)
            return;
        auto server = servers.get(d.language.name, null);
        if (!server || server.status == LanguageServer.Status.stopped)
        {
            server = LanguageServer.forLanguage(d.language, folder);
            if (!server)
                return;
            servers[d.language.name] = server;
            server.statusProperty.addListener((LanguageServer.Status was, LanguageServer.Status now) { showStatus(); });
        }
        d.lsp = new LspDocument(server, d.buffer, d.path);
        d.lspEditor = new LspEditor(d.lsp, d.view);
        d.lspEditor.onGoToDefinition((Location l) { open(l.path, l.position); });
        d.lsp.addDiagnosticsListener({ if (d is current) showStatus(); });
    }

    void forget(Document d)
    {
        if (d.lsp)
            d.lsp.close();
        documents = documents.filter!(o => o !is d).array;
        showStatus();
    }

    void closeDocument(Document d)
    {
        tabs.remove(d.tab);
        forget(d);
    }

    void closeCurrent()
    {
        auto d = current;
        if (!d)
            return;
        if (d.buffer.modified)
            askToSave(d, { closeDocument(d); });
        else
            closeDocument(d);
    }

    void askToSave(Document d, void delegate() then)
    {
        tabs.select(d.tab);
        new Dialog(format!"Save the changes to “%s”?"(d.path ? baseName(d.path) : "Untitled"))
            .text("If you don't, they're lost.")
            .addStartButton("Don't Save", then)
            .addButton("Cancel", null, ButtonKind.cancel)
            .addButton("Save", { if (save(d)) then(); }, ButtonKind.default_)
            .show(root);
    }

    bool save(Document d)
    {
        if (!d)
            return false;
        if (!d.path)
        {
            saveAs(d);
            return false;
        }
        try
            write(d.path, d.buffer.textToSave);
        catch (Exception e)
        {
            say("Couldn't save: " ~ e.msg);
            return false;
        }
        d.buffer.setModified(false);
        if (d.lsp)
            d.lsp.saved();
        say("Saved " ~ baseName(d.path));
        return true;
    }

    void saveAs(Document d)
    {
        if (!d)
            return;
        new FileChooser().title("Save As").initialFileName(d.path ? baseName(d.path) : "untitled.txt")
            .showSaveDialog(root, (string file) {
                if (!file)
                    return;
                d.path = file;
                d.setLanguage(languageFor(file));
                if (!d.lsp)
                    connect(d);
                save(d);
                d.showName();
                showStatus();
            });
    }

    // Finding

    void showFind(bool replacing)
    {
        findBar.setVisible(true);
        replaceField.setVisible(replacing);
        if (auto d = current)
            if (d.view.hasSelection && d.view.selectionStart.line == d.view.selectionEnd.line)
                findField.setText(d.view.selectedText);
        findField.requestFocus();
        findField.selectAll();
    }

    void hideFind()
    {
        findBar.setVisible(false);
        if (auto d = current)
        {
            d.view.find(null);
            d.view.requestFocus();
        }
    }

    void find(bool backwards = false)
    {
        auto d = current;
        if (!d)
            return;
        d.view.find(findField.text, matchCase.selected, wholeWord.selected, backwards);
        findCount.setText(findField.text.length ? format!"%s found"(d.view.matchCount) : "");
    }

    void goToLine()
    {
        auto d = current;
        if (!d)
            return;
        auto field = new TextField("").prefWidth(120).promptText(format!"1 to %s"(d.buffer.lineCount));
        new Dialog("Go to Line").extra(field)
            .addButton("Cancel", null, ButtonKind.cancel)
            .addButton("Go", {
                try
                {
                    const n = field.text.strip.to!int - 1;
                    d.view.placeCaret(TextPosition(n, 0));
                    d.view.requestFocus();
                }
                catch (Exception) {}
            }, ButtonKind.default_)
            .show(root);
        Platform.runLater({ field.requestFocus(); });
    }

    void toggleSidebar()
    {
        sidebarShown = !sidebarShown;
        root.setLeft(sidebarShown ? sidebar : null);
    }

    void say(string what) { serverLabel.setText(what); }

    // Building it

    void buildTitleBar()
    {
        auto sidebarButton = new Button().graphic(new Icon("sidebar-show-symbolic")).accessibleText("Files").tooltip("Files (F9)");
        sidebarButton.setOnAction({ toggleSidebar(); });
        auto newButton = new Button().graphic(new Icon("document-new-symbolic")).accessibleText("New").tooltip("New file (Ctrl+N)");
        newButton.setOnAction({ add(new Document(null, "")); });
        auto saveButton = new Button().graphic(new Icon("document-save-symbolic")).accessibleText("Save").tooltip("Save (Ctrl+S)");
        saveButton.setOnAction({ save(current); });
        auto findButton = new Button().graphic(new Icon("edit-find-symbolic")).accessibleText("Find").tooltip("Find (Ctrl+F)");
        findButton.setOnAction({ showFind(false); });
        auto menu = new ContextMenu()
            .add(new MenuItem("New File", { add(new Document(null, "")); }).accelerator("Ctrl+N"))
            .add(new MenuItem("Open File…", { chooseFile(); }).accelerator("Ctrl+O"))
            .add(new MenuItem("Open Folder…", { chooseFolder(); }).accelerator("Ctrl+Shift+O"))
            .add(new MenuItem("Save", { save(current); }).accelerator("Ctrl+S"))
            .add(new MenuItem("Save As…", { saveAs(current); }).accelerator("Ctrl+Shift+S"))
            .add(new MenuItem("Close Tab", { closeCurrent(); }).accelerator("Ctrl+W"))
            .add(new MenuSeparator())
            .add(new MenuItem("Find", { showFind(false); }).accelerator("Ctrl+F"))
            .add(new MenuItem("Replace", { showFind(true); }).accelerator("Ctrl+H"))
            .add(new MenuItem("Go to Line…", { goToLine(); }).accelerator("Ctrl+G"))
            .add(new MenuItem("Go to Definition", { if (auto d = current) if (d.lspEditor) d.lspEditor.goToDefinition(d.view.caretPosition); }).accelerator("F12"))
            .add(new MenuItem("Complete", { if (auto d = current) if (d.lspEditor) d.lspEditor.complete(); }).accelerator("Ctrl+Space"))
            .add(new MenuSeparator())
            .add(new MenuItem("Files", { toggleSidebar(); }).accelerator("F9"));
        auto menuButton = new MenuButton().graphic(new Icon("open-menu-symbolic")).accessibleText("Menu").menu(menu);
        titleBar = new TitleBar("Code")
            .sidebar(sidebar)
            .addStart(sidebarButton)
            .addEnd(new Row().spacing(2).alignment(Pos.centreLeft).add(newButton).add(saveButton).add(findButton))
            .addEnd(menuButton);
    }

    void chooseFile()
    {
        new FileChooser().title("Open").showOpenDialog(root, (string file) { if (file) open(file); });
    }

    void chooseFolder()
    {
        new FileChooser().title("Open a Folder").showDirectoryDialog(root, (string f) { if (f) openFolder(f); });
    }

    void buildFindBar()
    {
        findField = new TextField("").promptText("Find").prefWidth(220).accessibleText("Find");
        findField.setOnAction({ find(); });
        findField.textProperty.addListener((string was, string now) { find(); });
        replaceField = new TextField("").promptText("Replace with").prefWidth(220).accessibleText("Replace with");
        matchCase = new ToggleButton("Aa").tooltip("Match case");
        matchCase.setOnAction({ find(); });
        wholeWord = new ToggleButton("W").tooltip("Whole words");
        wholeWord.setOnAction({ find(); });
        auto previous = new Button().graphic(new Icon("go-up-symbolic")).accessibleText("Previous").tooltip("Previous (Shift+Enter)");
        previous.setOnAction({ if (auto d = current) d.view.findNext(true); });
        auto next = new Button().graphic(new Icon("go-down-symbolic")).accessibleText("Next").tooltip("Next (Enter)");
        next.setOnAction({ if (auto d = current) d.view.findNext(); });
        auto replace = new Button("Replace");
        replace.setOnAction({ if (auto d = current) d.view.replaceNext(replaceField.text); find(); });
        auto replaceAll = new Button("All");
        replaceAll.setOnAction({
            if (auto d = current)
                say(format!"Replaced %s"(d.view.replaceAll(replaceField.text)));
            find();
        });
        auto close = new Button().graphic(new Icon("window-close-symbolic")).accessibleText("Close");
        close.setOnAction({ hideFind(); });
        findCount = new Label("").styleClass("secondary");
        findBar = new Row().spacing(6).padding(Insets(6, 10)).alignment(Pos.centreLeft);
        findBar.styleClass.add("find-bar");
        findBar.add(findField).add(matchCase).add(wholeWord).add(previous).add(next).add(findCount)
            .add(replaceField).add(replace).add(replaceAll).add(new Row().grow(1)).add(close);
    }

    Row statusLine;

    void buildStatus()
    {
        position = new Label("");
        languageLabel = new Label("");
        indentLabel = new Label("");
        serverLabel = new Label("");
        problemsLabel = new Label("");
        statusLine = new Row().spacing(18).padding(Insets(4, 12)).alignment(Pos.centreLeft);
        statusLine.styleClass.add("status-line");
        statusLine.add(problemsLabel).add(serverLabel).add(new Row().grow(1))
            .add(position).add(indentLabel).add(languageLabel);
    }

    void showStatus()
    {
        auto d = current;
        if (!d)
        {
            position.setText("");
            languageLabel.setText("");
            indentLabel.setText("");
            problemsLabel.setText("");
            return;
        }
        showPosition();
        languageLabel.setText(d.language ? d.language.name : "Plain Text");
        indentLabel.setText(d.view.insertSpaces ? format!"Spaces: %s"(d.view.tabWidth) : format!"Tabs: %s"(d.view.tabWidth));
        if (d.lsp)
        {
            const s = d.lsp.server;
            final switch (s.status)
            {
                case LanguageServer.Status.starting: serverLabel.setText("Starting " ~ d.language.name ~ " server…"); break;
                case LanguageServer.Status.ready: serverLabel.setText(s.serverName.length ? s.serverName : d.language.name ~ " language server"); break;
                case LanguageServer.Status.stopped: serverLabel.setText("Language server stopped: " ~ s.failure); break;
            }
            int errors, warnings;
            foreach (x; d.lsp.diagnostics)
            {
                if (x.severity == Severity.error) errors++;
                else if (x.severity == Severity.warning) warnings++;
            }
            problemsLabel.setText(format!"%s error%s, %s warning%s"(errors, errors == 1 ? "" : "s", warnings, warnings == 1 ? "" : "s"));
        }
        else
        {
            serverLabel.setText(d.language && LanguageServer.commandsFor(d.language.name).length
                                ? "No " ~ d.language.name ~ " language server installed" : "");
            problemsLabel.setText("");
        }
    }

    void showPosition()
    {
        if (auto d = current)
            position.setText(format!"Ln %s, Col %s"(d.view.caretPosition.line + 1, d.view.caretPosition.column + 1));
    }

    /// Quitting: each unsaved file asked about, then the servers stopped.
    bool quitting()
    {
        foreach (d; documents)
            if (d.buffer.modified)
            {
                askToSave(d, {
                    d.buffer.setModified(false);
                    if (auto w = App.current ? App.current.window : null)
                        w.close();
                });
                return false;
            }
        foreach (s; servers)
            s.stop();
        return true;
    }
}

/// The window's content, which hears the shortcuts nothing in it took.
final class EditorRoot : Dock
{
    this(Editor editor) { this.editor = editor; }

protected:
    override void handleShortcut(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed)
            return;
        const ctrl = event.control || event.meta;
        auto e = editor;
        const c = event.code;
        if (ctrl && event.shift && c == KeyCode.s) e.saveAs(e.current);
        else if (ctrl && event.shift && c == KeyCode.o) e.chooseFolder();
        else if (ctrl && c == KeyCode.s) e.save(e.current);
        else if (ctrl && c == KeyCode.n) e.add(new Document(null, ""));
        else if (ctrl && c == KeyCode.o) e.chooseFile();
        else if (ctrl && c == KeyCode.w) e.closeCurrent();
        else if (ctrl && c == KeyCode.f) e.showFind(false);
        else if (ctrl && c == KeyCode.h) e.showFind(true);
        else if (ctrl && c == KeyCode.g) e.goToLine();
        else if (c == KeyCode.f9) e.toggleSidebar();
        else if (c == KeyCode.escape && e.findBar.visible) e.hideFind();
        else if (c == KeyCode.f3) { if (auto d = e.current) d.view.findNext(event.shift); }
        else
            return;
        event.consume();
    }

private:
    Editor editor;
}

/// The editor's own look, over the Oriel theme: the tree and tabs clear on the glass and the page.
enum editorStyle = `
    .sidebar { padding: 6 6 6 6; }
    .sidebar .tree-view { background-colour: transparent; width: auto; height: auto; }
    .sidebar-heading { font-size: 11px; font-weight: bold; colour: var(--secondary-text); padding: 6 8 4 8; }
    .text-view, .text-view .gutter { background-colour: var(--page); }
    .find-bar, .status-line { background-colour: var(--divider), var(--page); background-insets: 0, 1 0 0 0; }
    .status-line .label { font-size: 12px; colour: var(--secondary-text); }
    .title-bar .button, .title-bar .menu-button { --base: transparent; --hover-base: var(--row-hover); }
`;
