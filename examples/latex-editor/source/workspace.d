module workspace;

import core.time : msecs;
import std.algorithm : filter;
import std.array : array;
import std.file : exists, isDir, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath;
import mayfair;
import mayfair.code;
import compiler;
import documents;
import files;
import header;
import preview;
import project;
import synctex;

/*
    The window's content and what it does: the controller of main.xml. It holds the project, the
    files open in it, and the compiler, and connects the three panes -- FilesPane, the editor's
    tabs, PreviewPane -- to them and to each other:

        a file chosen in the tree           opens in a tab
        Ctrl+S, Ctrl+Enter or Recompile     saves what's changed and compiles
        typing, with Auto on                compiles once typing's paused
        a compile finishing                 shows its PDF, and marks its problems in the files
        a problem chosen in the logs        opens its file at its line
        a double click on the PDF           opens the source that made it, at its line
        Show in PDF (Ctrl+.)                scrolls the PDF to the caret's line
*/
@View("main.xml")
final class Workspace
{
public:
    @xml SplitPane split;
    @xml FilesPane files;
    @xml PreviewPane preview;
    @xml Column editorPane;
    @xml TabPane tabs;
    @xml Label problemsLabel, serverLabel, mainLabel, positionLabel;
    Header header;     /// The title bar: made by main(), as it's the window's, not the content's

    /// Called once main.xml's built: the panes connected.
    void initialise()
    {
        files.onOpen = (string path) { open(path); };
        preview.onCompile = { compile(); };
        preview.onAutoChanged = (bool on) { autoCompile = on; };
        preview.onEngineChanged = (Engine e) { compiler.engine = e; compile(); };
        preview.onProblemChosen = (Problem p) { if (p.file.length) open(p.file, p.line); };
        preview.onSourceWanted = (int page, float x, float y) { goToSource(page, x, y); };
        tabs.selectedIndexProperty.addListener((int was, int now) { showStatus(); });
        split.setOnKeyPressed((ref KeyEvent e) { shortcut(e); });
        // Compiling as you type: once typing's paused this long
        pause = new Timeline(KeyFrame(1500.msecs, { if (autoCompile) compile(); }));
    }

    /// Opens the project in `folder`, or the one a file's in, with its main file open.
    void openProject(string path)
    {
        path = buildNormalizedPath(absolutePath(path));
        const folder = exists(path) && isDir(path) ? path : std.path.dirName(path);
        project = new Project(folder);
        files.show(project);
        if (header)
            header.setTitle(project.name);
        mainLabel.setText(project.mainFile ? tr!"main_file"(project.relative(project.mainFile)) : "");
        if (exists(path) && !isDir(path))
            open(path);
        else if (project.mainFile)
            open(project.mainFile);
        if (project.mainFile)
            compile();
    }

    /// Asks for a project's folder, and opens it.
    void chooseProject()
    {
        new FileChooser().title(tr!"open_project").showDirectoryDialog(split, (string f) { if (f) openProject(f); });
    }

    /// Shows `file`'s tab, opening it first if it isn't open, at line `line` (from 1) if it's given.
    Document open(string file, int line = 0)
    {
        file = buildNormalizedPath(absolutePath(file));
        foreach (d; documents)
            if (d.path == file)
            {
                tabs.select(d.tab);
                d.goToLine(line);
                return d;
            }
        string content;
        try
            content = readText(file);
        catch (Exception e)
        {
            serverLabel.setText(baseName(file) ~ ": " ~ e.msg);
            return null;
        }
        auto d = new Document(file, content);
        add(d);
        d.showProblems(problems);
        d.goToLine(line);
        return d;
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

    /// Saves the file in the selected tab, then compiles, as Overleaf's Ctrl+S does.
    void save()
    {
        if (auto d = current)
            write(d);
        compile();
    }

    /// Saves every file with changes.
    bool saveAll()
    {
        bool ok = true;
        foreach (d; documents)
            if (d.buffer.modified)
                ok &= write(d);
        return ok;
    }

    /// Saves what's changed, and compiles the project.
    void compile()
    {
        if (!project)
            return;
        saveAll();
        pause.stop();
        preview.compiling();
        compiler.compile(project, (CompileResult r) {
            problems = r.problems;
            foreach (d; documents)
                d.showProblems(problems);
            preview.show(r);
            showStatus();
            if (!r.ran && !installed("pdflatex") && !installed("latexmk"))
                serverLabel.setText(tr!"no_tex");
        });
    }

    /// Scrolls the PDF to the place the caret's line made, by SyncTeX.
    void goToPdf()
    {
        auto d = current;
        if (!d || !preview.compiledPdf.length)
            return;
        sourceToPdf(preview.compiledPdf, d.path, d.view.caretPosition.line + 1, (PdfPlace place) {
            preview.scrollTo(place);
        });
    }

    /// Opens the source that made what's at `x`, `y` on page `page` of the PDF, at its line.
    void goToSource(int page, float x, float y)
    {
        if (!preview.compiledPdf.length)
            return;
        pdfToSource(preview.compiledPdf, page, x, y, (SourcePlace place) {
            if (place.file.length && exists(place.file))
                open(place.file, place.line);
        });
    }

    /// Shows or hides the files, or the PDF, the others taking their room.
    void toggleFiles() { files.setVisible(!files.visible); }
    void togglePdf() { preview.setVisible(!preview.visible); } /// ditto

    /// Closes the file in the selected tab, asking first if it has changes.
    void closeCurrent()
    {
        if (auto d = current)
            close(d);
    }

    /// Quitting: each file with changes asked about, then the language servers stopped.
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

private:
    Project project;
    Compiler compiler = new Compiler;
    Document[] documents;
    Problem[] problems;                 // the last compile's
    LanguageServer server;              // texlab, shared by every file, if it's installed
    LanguageServer[] servers;
    Timeline pause;
    bool autoCompile;

    void add(Document d)
    {
        documents ~= d;
        d.tab.onCloseRequest(() {
            if (!d.buffer.modified)
                return true;
            askToSave(d, { forget(d); tabs.remove(d.tab); });
            return false;
        });
        d.tab.onClosed({ forget(d); });
        d.view.caretPositionProperty.addListener((TextPosition was, TextPosition now) {
            if (d is current)
                showPosition();
        });
        // Typing: compiled once it pauses, with Auto on
        d.buffer.addListener((ref const BufferChange c) { if (autoCompile) pause.playFromStart(); });
        // The workspace's shortcuts, before the view takes them: Ctrl+Enter isn't a new line
        d.view.addKeyFilter((ref KeyEvent e) { shortcut(e); return e.consumed; });
        connect(d);
        tabs.add(d.tab);
        tabs.select(d.tab);
        d.view.requestFocus();
        showStatus();
    }

    // texlab, where it's installed: started once, for the project, and shared
    void connect(Document d)
    {
        if (!d.language || d.language.name != "LaTeX")
            return;
        if (!server || server.status == LanguageServer.Status.stopped)
        {
            server = LanguageServer.forLanguage(d.language, project ? project.folder : null);
            if (!server)
                return;
            servers ~= server;
            server.statusProperty.addListener((LanguageServer.Status was, LanguageServer.Status now) { showStatus(); });
        }
        d.lsp = new LspDocument(server, d.buffer, d.path);
        d.lspEditor = new LspEditor(d.lsp, d.view);
        d.lspEditor.onGoToDefinition((Location l) { open(l.path, l.position.line + 1); });
    }

    void forget(Document d)
    {
        if (d.lsp)
            d.lsp.close();
        documents = documents.filter!(o => o !is d).array;
        showStatus();
    }

    void close(Document d)
    {
        if (d.buffer.modified)
            askToSave(d, { forget(d); tabs.remove(d.tab); });
        else
        {
            tabs.remove(d.tab);
            forget(d);
        }
    }

    bool write(Document d)
    {
        string why;
        if (d.save(why))
            return true;
        serverLabel.setText(baseName(d.path) ~ ": " ~ why);
        return false;
    }

    void askToSave(Document d, void delegate() then)
    {
        tabs.select(d.tab);
        new Dialog(tr!"save_changes"(baseName(d.path)))
            .text(tr!"lost")
            .addStartButton(tr!"dont_save", then)
            .addButton(tr!"cancel", null, ButtonKind.cancel)
            .addButton(tr!"save", { if (write(d)) then(); }, ButtonKind.default_)
            .show(split);
    }

    void shortcut(ref KeyEvent e)
    {
        if (e.type != KeyEventType.pressed)
            return;
        const ctrl = e.control || e.meta;
        const c = e.code;
        if (ctrl && c == KeyCode.s && e.shift) saveAll();
        else if (ctrl && c == KeyCode.s) save();
        else if (ctrl && (c == KeyCode.enter || c == KeyCode.numpadEnter)) compile();
        else if (ctrl && c == cast(KeyCode) '.') goToPdf();
        else if (ctrl && c == KeyCode.o) chooseProject();
        else if (ctrl && c == KeyCode.n) files.newFile();
        else if (ctrl && c == KeyCode.w) closeCurrent();
        else if (c == KeyCode.f9) toggleFiles();
        else if (c == KeyCode.f10) togglePdf();
        else
            return;
        e.consume();
    }

    void showStatus()
    {
        showPosition();
        int errors, warnings;
        foreach (ref p; problems)
            (p.error ? errors : warnings)++;
        problemsLabel.setText(project ? tr!"problems"(errors, warnings) : "");
        if (server)
            serverLabel.setText(server.status == LanguageServer.Status.ready
                                ? (server.serverName.length ? server.serverName : "texlab") : "");
        else if (current && current.language && current.language.name == "LaTeX")
            serverLabel.setText(tr!"no_server");
    }

    void showPosition()
    {
        auto d = current;
        positionLabel.setText(d ? tr!"position"(d.view.caretPosition.line + 1, d.view.caretPosition.column + 1) : "");
    }
}

private import std.path : dirName;
static import std.path;
