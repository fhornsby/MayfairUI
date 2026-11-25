module viewer;

/*
    A window of the viewer, with a document in it, or none yet: the title bar and its menu, the
    sidebar, the markup toolbar, and the document. Each document gets a window of its own, as a
    desktop's own viewer gives it: opening another while one's open opens another window.
*/

import std.algorithm : canFind, endsWith, sort;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.string : strip, toLower;
import mayfair;
import mayfair.pdf;
import dialogs;
import icons;
import lists;
import markup;
static import store;

/// The tour, beside this source: samples/tour.pdf.
string tour() { return buildPath(dirName(__FILE_FULL_PATH__), "..", "samples", "tour.pdf"); }

/*
    The viewer's own look, over the Oriel theme (mayfair.theme.oriel): the sidebar's tabs small and
    clear on its glass, the markup toolbar a strip of the page under the title bar, and the status line.
*/
enum viewerStyle = `
    .sidebar .toggle-button { font-size: 12px; padding: 3 6; --base: transparent; --hover-base: var(--row-hover); }
    .sidebar .toggle-button:selected { --face: var(--row-selected); }
    .markup-bar { background-colour: var(--divider), var(--page); background-insets: 0, 0 0 1 0; }
    .markup-bar .button, .markup-bar .toggle-button, .markup-bar .menu-button { --base: transparent; }
    .status { font-size: 12px; colour: var(--secondary-text); padding: 4 10; }
    .title-bar .button, .title-bar .toggle-button, .title-bar .menu-button {
        --base: transparent; --hover-base: var(--row-hover); --pressed-base: var(--row-selected);
    }
`;

/// The viewers open, a window each.
Viewer[] viewers;

/// An annotation copied, to paste: into any window's document.
PdfAnnotation copied;
bool haveCopied;

/// Opens `path` in a window of its own; `window` if given, else a new one.
Viewer openWindow(string path, Window window = null)
{
    const fresh = window is null;
    if (fresh)
    {
        window = new Window("PDF Viewer");
        window.setSize(1180, 820);
    }
    auto v = new Viewer(window);
    auto scene = new Scene(v.root).titleBar(v.titleBar);
    // The Oriel look, then the viewer's own: on the scene, so the title bar has them too
    scene.stylesheets.add(orielStylesheet);
    scene.stylesheets.add(stylesheet!viewerStyle);
    window.scene = scene;
    // Frosted glass in the sidebar where the compositor blurs what's behind the window; opaque elsewhere
    window.setTranslucent(true);
    if (fresh)
        window.show();
    if (path.length)
        v.open(path);
    return v;
}

enum SidebarShows { pages, contents, notes, results, bookmarks }

final class Viewer
{
    Window window;
    ViewerRoot root;
    TitleBar titleBar;
    PdfView view;
    PdfDocument document;

    this(Window window)
    {
        this.window = window;
        viewers ~= this;
        view = new PdfView;
        view.setGrow(1);
        view.onExternalLink((uri) { openOutside(uri); });
        view.onEditAnnotation((int page, PdfAnnotation a) { editAnnotationText(page, a); });

        buildSidebar();

        // The middle: the markup toolbar over the document, or what to open when there's none
        message = new Label("").wrapText(true).style("font-size: 14px;");
        welcome = new Column().spacing(16).alignment(Pos.centre).fillWidth(false).padding(40);
        buildWelcome();
        markupBar = new MarkupBar(view);
        documentArea = new Column().grow(1);
        documentArea.add(view);
        middle = new Stack().grow(1);
        middle.add(welcome);
        status = new Label("").styleClass("status");

        root = new ViewerRoot(this);
        auto centre = new Column().grow(1).add(middle).add(status);
        centre.styleClass.add("page"); // opaque, beside the sidebar's glass
        root.setCentre(centre);

        // Dropped on the window, from a file manager: PDFs opened -- here, if nothing is
        root.onDragOver((ref e) {
            e.acceptTransferModes(TransferMode.copy);
            e.consume();
        });
        root.onDragDropped((ref e) {
            foreach (f; e.dragboard.files)
                if (f.toLower.endsWith(".pdf"))
                {
                    if (document && document.status == PdfStatus.ready && pagesDropTarget(e.sceneX))
                        document.insertFile(f, null, view.currentPage + 1, (PdfError err) { if (err) say(err.message); });
                    else
                        open(f);
                    e.setDropCompleted(true);
                }
            e.consume();
        });

        buildTitleBar();
        watchView();
        window.onCloseRequest(() {
            if (document && document.edited)
            {
                askToSave(root, document, &saveThen, { forgetAndClose(); });
                return false;
            }
            forget();
            return true;
        });
    }

    /// Opens `path`: here, if nothing is open; otherwise in another window.
    void open(string path, string password = null)
    {
        if (document && document.status == PdfStatus.ready && document.path != path)
        {
            openWindow(path);
            return;
        }
        load(path, password);
    }

    /// Asks which PDFs to open.
    void choose()
    {
        new FileChooser().title("Open").addFilter("PDF documents", "pdf")
            .showOpenMultipleDialog(root, (string[] paths) {
                foreach (p; paths)
                    open(p);
            });
    }

    void toggleSidebar()
    {
        sidebarShown = !sidebarShown;
        showSidebar();
    }

    void toggleMarkup()
    {
        markupShown = !markupShown;
        markupButton.setSelected(markupShown);
        if (markupShown)
            documentArea.remove(view), documentArea.add(markupBar), documentArea.add(view);
        else
        {
            documentArea.remove(markupBar);
            view.setTool(PdfTool.select);
        }
    }

    void focusSearch() { search.requestFocus(); }

    /// Closes the window: once its changes are saved, or let go, if it has any.
    void requestClose()
    {
        if (document && document.edited)
            askToSave(root, document, &saveThen, { forgetAndClose(); });
        else
            forgetAndClose();
    }

    bool ready() { return document && document.status == PdfStatus.ready; }

    // What the menus and shortcuts do

    void save()
    {
        if (!ready)
            return;
        if (!document.edited)
            return;
        saveThen(null);
    }

    void saveAs()
    {
        if (!ready)
            return;
        new FileChooser().title("Save As").addFilter("PDF documents", "pdf").initialFileName(baseName(document.path))
            .showSaveDialog(root, (string file) {
                if (!file)
                    return;
                if (!file.toLower.endsWith(".pdf"))
                    file ~= ".pdf";
                document.save(file, PdfSaveOptions(false, false), (PdfError e) {
                    if (e)
                        say("It couldn't be saved: " ~ e.message);
                    else
                    {
                        store.opened(file);
                        showTitle();
                        bookmarkList.show(file);
                        say("Saved as " ~ baseName(file));
                    }
                });
            });
    }

    void revert()
    {
        if (!ready || !document.edited)
            return;
        const path = document.path;
        new Dialog("Revert to the saved version?").text("The changes since it was saved are lost.")
            .addButton("Cancel", null, ButtonKind.cancel)
            .addButton("Revert", { load(path, null); }, ButtonKind.default_)
            .show(root);
    }

    void undo()
    {
        if (ready)
            document.undo();
    }

    void redo()
    {
        if (ready)
            document.redo();
    }

    /// The pages acted on: those selected in the sidebar, or the one being read.
    int[] selectedPages()
    {
        auto s = thumbnails.selectedPages;
        return s.length > 1 || (s.length == 1 && s[0] != view.currentPage && sidebarShown) ? s.dup : [view.currentPage];
    }

    void rotate(int turns)
    {
        if (ready)
            document.rotatePages(selectedPages, turns);
    }

    void deletePages(int[] pages)
    {
        if (!ready)
            return;
        if (pages.length >= document.pageCount)
        {
            say("A PDF has a page at least");
            return;
        }
        document.deletePages(pages);
    }

    void insertBlank()
    {
        if (!ready)
            return;
        const at = view.currentPage;
        document.insertBlankPage(at + 1, document.pageSize(at));
        view.goToPage(at + 1);
    }

    void insertFromFile()
    {
        if (!ready)
            return;
        new FileChooser().title("Insert Pages From").addFilter("PDF documents", "pdf")
            .showOpenDialog(root, (string file) {
                if (file)
                    document.insertFile(file, null, view.currentPage + 1, (PdfError e) {
                        say(e ? "Its pages couldn't be put in: " ~ e.message : "Put in the pages of " ~ baseName(file));
                    });
            });
    }

    void copyAnnotation()
    {
        if (auto a = view.selectedAnnotationValue)
        {
            copied = a.copy();
            haveCopied = true;
        }
        else if (document && document.formFocus < 0)
            view.copySelection();
    }

    void pasteAnnotation()
    {
        if (!ready || !haveCopied)
            return;
        auto a = copied.movedBy(12, 12);
        a.ours = true;
        if (a.kind == PdfAnnotationKind.other || a.kind == PdfAnnotationKind.widget)
            return;
        const page = view.currentPage;
        document.addAnnotation(page, a, (int index) {
            if (index >= 0)
                view.selectAnnotation(PdfAnnotationRef(page, index));
        });
        copied = a;
    }

    void bookmark()
    {
        if (!ready)
            return;
        bookmarkList.add();
        sidebarShows(SidebarShows.bookmarks);
        if (!sidebarShown)
            toggleSidebar();
    }

    void slideshow(bool on)
    {
        if (!ready || on == inSlideshow)
            return;
        inSlideshow = on;
        if (on)
        {
            wasFit = view.fit;
            wasZoom = view.zoom;
            wasLayout = view.pageLayout;
            titleBar.setVisible(false);
            root.setLeft(null);
            status.setVisible(false);
            if (markupShown)
                toggleMarkup();
            view.setPageLayout(PdfPageLayout.continuous);
            view.setFit(PdfFit.page);
            view.setStyle("background-colour: black;");
            window.setFullScreen(true);
            view.requestFocus();
        }
        else
        {
            window.setFullScreen(false);
            titleBar.setVisible(true);
            status.setVisible(true);
            view.setStyle("background-colour: rgba(128, 128, 128, 0.18);");
            view.setPageLayout(wasLayout);
            if (wasFit == PdfFit.none)
                view.setZoom(wasZoom);
            else
                view.setFit(wasFit);
            showSidebar();
        }
    }

    bool inSlideshow;

    void print_()
    {
        if (ready)
            print(root, document, view, &say);
    }

    void exportIt()
    {
        if (ready)
            export_(root, document, selectedPages, &say);
    }

    void info()
    {
        if (ready)
            showInfo(root, document, view);
    }

    void cropToRegion()
    {
        if (!ready)
            return;
        if (view.region.page < 0)
        {
            say("Drag out a region with the region tool first, in the markup toolbar");
            if (!markupShown)
                toggleMarkup();
            view.setTool(PdfTool.region);
            return;
        }
        view.cropToRegion();
    }

    void say(string what)
    {
        status.setText(what);
    }

private:
    PdfThumbnails thumbnails;
    PdfOutline contents;
    AnnotationList notes;
    SearchResults results;
    BookmarkList bookmarkList;
    Column sidebar, welcome, documentArea;
    Stack sidebarStack, middle;
    ToggleButton[SidebarShows] sidebarTabs;
    SidebarShows shows;
    MarkupBar markupBar;
    ToggleButton sidebarButton, markupButton;
    Label message, pageCount, matches, status;
    TextField pageField, search;
    MenuButton zoomButton;
    string searched;
    bool sidebarShown = true, markupShown;
    PdfFit wasFit;
    float wasZoom = 1;
    PdfPageLayout wasLayout;

    void load(string path, string password)
    {
        if (document)
            document.close();
        document = PdfDocument.open(path, password);
        auto doc = document;
        doc.statusProperty.addListener((PdfStatus was, PdfStatus now) {
            if (doc is document)
                statusChanged(now);
        });
        doc.editedProperty.addListener((bool was, bool now) {
            if (doc is document)
                showTitle();
        });
        statusChanged(doc.status);
    }

    void saveThen(void delegate() then)
    {
        if (!ready)
            return;
        document.save(document.path, PdfSaveOptions.init, (PdfError e) {
            if (e)
            {
                say("It couldn't be saved: " ~ e.message);
                return;
            }
            say("Saved");
            if (then)
                then();
        });
    }

    void forget()
    {
        import std.algorithm : remove;
        viewers = viewers.remove!(v => v is this);
        if (document)
            document.close();
    }

    void forgetAndClose()
    {
        forget();
        window.close();
    }

    /// Whether a drop at `x` in the window is on the sidebar's pages: put in, rather than opened.
    bool pagesDropTarget(float x)
    {
        return sidebarShown && shows == SidebarShows.pages && x < sidebar.boundsInScene.maxX;
    }

    // Building it

    void buildSidebar()
    {
        thumbnails = new PdfThumbnails;
        thumbnails.setGrow(1);
        thumbnails.onPageChosen((page) { view.goToPage(page); });
        thumbnails.onPagesMoved((int[] pages, int before) { if (ready) document.movePages(pages, before); });
        thumbnails.onDeletePages((int[] pages) { deletePages(pages); });
        thumbnails.onMenu((int page, float x, float y) { pageMenu(x, y); });
        contents = new PdfOutline;
        contents.setGrow(1);
        contents.onItemChosen((item) { view.goToPage(item.page, item.y); });
        notes = new AnnotationList(view);
        notes.setGrow(1);
        results = new SearchResults(view);
        results.setGrow(1);
        bookmarkList = new BookmarkList(view);
        bookmarkList.setGrow(1);

        auto tabs = new Row().spacing(1).padding(Insets(8, 4)).alignment(Pos.centre);
        static struct Tab { SidebarShows which; string name; }
        foreach (t; [Tab(SidebarShows.pages, "Pages"), Tab(SidebarShows.contents, "Contents"), Tab(SidebarShows.notes, "Notes"),
                     Tab(SidebarShows.results, "Search"), Tab(SidebarShows.bookmarks, "Marks")])
        {
            auto which = t.which;
            auto b = new ToggleButton(t.name);
            b.setOnAction(tabAction(which));
            sidebarTabs[which] = b;
            tabs.add(b);
        }
        sidebarStack = new Stack().grow(1);
        sidebar = new Column().prefWidth(240).minWidth(240).maxWidth(240);
        sidebar.styleClass.add("sidebar"); // glass, where the window's translucent
        sidebar.add(tabs).add(sidebarStack);
        sidebarShows(SidebarShows.pages);
    }

    void delegate() tabAction(SidebarShows which) { return { sidebarShows(which); }; }

    void sidebarShows(SidebarShows which)
    {
        shows = which;
        foreach (k, b; sidebarTabs)
            b.setSelected(k == which);
        while (sidebarStack.children.length)
            sidebarStack.remove(cast(Widget) sidebarStack.children[0]);
        final switch (which)
        {
            case SidebarShows.pages: sidebarStack.add(thumbnails); break;
            case SidebarShows.contents: sidebarStack.add(contents); break;
            case SidebarShows.notes: sidebarStack.add(notes); break;
            case SidebarShows.results: results.refresh(); sidebarStack.add(results); break;
            case SidebarShows.bookmarks: sidebarStack.add(bookmarkList); break;
        }
    }

    void showSidebar()
    {
        root.setLeft(sidebarShown && ready && !inSlideshow ? sidebar : null);
        sidebarButton.setSelected(sidebarShown);
    }

    void buildWelcome()
    {
        while (welcome.children.length)
            welcome.remove(cast(Widget) welcome.children[0]);
        auto openButton = new Button("Open a PDF…").defaultButton(true).graphic(new Icon("document-open-symbolic"));
        openButton.setOnAction({ choose(); });
        auto tourButton = new Button("Open the tour").graphic(new Icon("help-browser-symbolic"));
        tourButton.setOnAction({ open(tour); });
        welcome.add(new Icon("x-office-document-symbolic").iconSize(96).style("colour: var(--prompt-text);"))
            .add(new Label("No document open").style("font-size: 22px; font-weight: bold;"))
            .add(message)
            .add(new Row().spacing(12).add(openButton).add(tourButton))
            .add(new Label("or drop a PDF on the window").style("colour: var(--prompt-text);"));
        auto recent = store.recent();
        if (recent.length)
        {
            auto list = new Column().spacing(2).alignment(Pos.topCentre);
            list.add(new Label("Opened lately").style("font-weight: bold; padding: 12 0 4 0;"));
            foreach (p; recent[0 .. recent.length > 6 ? 6 : recent.length])
                list.add(recentButton(p));
            welcome.add(list);
        }
    }

    Button recentButton(string path)
    {
        auto b = new Button(baseName(path)).tooltip(path).style("background-colour: transparent;");
        b.setOnAction({ open(path); });
        return b;
    }

    void buildTitleBar()
    {
        sidebarButton = new ToggleButton().graphic(new Icon("sidebar-show-symbolic")).selected(true)
            .accessibleText("Sidebar").tooltip("Show or hide the sidebar (F9)");
        sidebarButton.setOnAction({ if (sidebarButton.selected != sidebarShown) toggleSidebar(); });

        // Which page, of how many
        pageField = new TextField("").prefWidth(48).accessibleText("Page");
        pageField.setOnAction({
            try
                view.goToPage(pageField.text.strip.to!int - 1);
            catch (Exception) {}
            pageField.setText((view.currentPage + 1).to!string);
            view.requestFocus();
        });
        pageCount = new Label("");

        // Zooming: out, a menu of how much, in
        auto zoomOut = new Button().graphic(new Icon("zoom-out-symbolic")).accessibleText("Zoom out").tooltip("Zoom out (Ctrl+-)");
        zoomOut.setOnAction({ view.zoomOut(); });
        auto zoomIn = new Button().graphic(new Icon("zoom-in-symbolic")).accessibleText("Zoom in").tooltip("Zoom in (Ctrl+=)");
        zoomIn.setOnAction({ view.zoomIn(); });
        auto zooms = new ContextMenu()
            .add(new MenuItem("Fit width", { view.setFit(PdfFit.width); }).accelerator("Ctrl+1"))
            .add(new MenuItem("Fit page", { view.setFit(PdfFit.page); }).accelerator("Ctrl+2"))
            .add(new MenuItem("Actual size", { view.setZoom(1); }).accelerator("Ctrl+0"))
            .add(new MenuSeparator());
        foreach (percent; [50, 75, 100, 125, 150, 200, 300, 400])
            zooms.add(zoomItem(percent));
        zoomButton = new MenuButton("Fit width").menu(zooms).prefWidth(104).accessibleText("Zoom");

        // Turning pages, and marking them up
        auto turnLeft = new Button().graphic(new Icon("object-rotate-left-symbolic")).accessibleText("Rotate left")
            .tooltip("Rotate the page left (Ctrl+L)");
        turnLeft.setOnAction({ rotate(3); });
        auto turnRight = new Button().graphic(new Icon("object-rotate-right-symbolic")).accessibleText("Rotate right")
            .tooltip("Rotate the page right (Ctrl+R)");
        turnRight.setOnAction({ rotate(1); });
        markupButton = new ToggleButton().graphic(svgIcon(markupIcon)).accessibleText("Markup")
            .tooltip("Show or hide the markup toolbar (Ctrl+Shift+A)");
        markupButton.setOnAction({ if (markupButton.selected != markupShown) toggleMarkup(); });

        // Searching
        search = new TextField("").promptText("Search").prefWidth(170).accessibleText("Search");
        search.setOnAction({ find(false); });
        matches = new Label("").style("colour: var(--prompt-text);");
        auto previous = new Button().graphic(new Icon("go-up-symbolic")).accessibleText("Previous match").tooltip("Previous match (Ctrl+Shift+G)");
        previous.setOnAction({ view.findPrevious(); });
        auto next = new Button().graphic(new Icon("go-down-symbolic")).accessibleText("Next match").tooltip("Next match (Ctrl+G)");
        next.setOnAction({ find(false); });

        auto menu = new MenuButton().graphic(new Icon("open-menu-symbolic")).accessibleText("Menu").menu(buildMenu());

        titleBar = new TitleBar("PDF Viewer")
            .sidebar(sidebar) // the sidebar's glass up to the top of the window, following it as it's hidden
            .addStart(sidebarButton)
            .addStart(new Row().spacing(6).alignment(Pos.centreLeft).add(pageField).add(pageCount))
            .addEnd(new Row().spacing(2).alignment(Pos.centreLeft).add(zoomOut).add(zoomButton).add(zoomIn))
            .addEnd(new Row().spacing(2).alignment(Pos.centreLeft).add(turnLeft).add(turnRight))
            .addEnd(markupButton)
            .addEnd(new Row().spacing(4).alignment(Pos.centreLeft).add(matches).add(search).add(previous).add(next))
            .addEnd(menu);
    }

    ContextMenu buildMenu()
    {
        auto file = new Menu("File")
            .add(new MenuItem("Open…", { choose(); }).accelerator("Ctrl+O"))
            .add(new MenuItem("Save", { save(); }).accelerator("Ctrl+S"))
            .add(new MenuItem("Save As…", { saveAs(); }).accelerator("Ctrl+Shift+S"))
            .add(new MenuItem("Export…", { exportIt(); }).accelerator("Ctrl+E"))
            .add(new MenuItem("Revert to Saved", { revert(); }))
            .add(new MenuSeparator())
            .add(new MenuItem("Print…", { print_(); }).accelerator("Ctrl+P"))
            .add(new MenuItem("Document Info", { info(); }).accelerator("Ctrl+I"))
            .add(new MenuSeparator())
            .add(new MenuItem("Close", { requestClose(); }).accelerator("Ctrl+W"));
        auto edit = new Menu("Edit")
            .add(new MenuItem("Undo", { undo(); }).accelerator("Ctrl+Z"))
            .add(new MenuItem("Redo", { redo(); }).accelerator("Ctrl+Shift+Z"))
            .add(new MenuSeparator())
            .add(new MenuItem("Copy", { copyAnnotation(); }).accelerator("Ctrl+C"))
            .add(new MenuItem("Paste", { pasteAnnotation(); }).accelerator("Ctrl+V"))
            .add(new MenuItem("Delete", { view.deleteSelectedAnnotation(); }).accelerator("Delete"))
            .add(new MenuItem("Select All", { view.selectAll(); }).accelerator("Ctrl+A"))
            .add(new MenuSeparator())
            .add(new MenuItem("Insert Blank Page", { insertBlank(); }))
            .add(new MenuItem("Insert Pages From File…", { insertFromFile(); }))
            .add(new MenuItem("Delete Page", { deletePages(selectedPages); }))
            .add(new MenuSeparator())
            .add(new MenuItem("Find", { focusSearch(); }).accelerator("Ctrl+F"));
        auto viewMenu = new Menu("View")
            .add(new MenuItem("Sidebar", { toggleSidebar(); }).accelerator("F9"))
            .add(new MenuItem("Pages", { showTab(SidebarShows.pages); }).accelerator("Ctrl+Alt+1"))
            .add(new MenuItem("Contents", { showTab(SidebarShows.contents); }).accelerator("Ctrl+Alt+2"))
            .add(new MenuItem("Highlights and Notes", { showTab(SidebarShows.notes); }).accelerator("Ctrl+Alt+3"))
            .add(new MenuItem("Bookmarks", { showTab(SidebarShows.bookmarks); }).accelerator("Ctrl+Alt+4"))
            .add(new MenuSeparator())
            .add(new MenuItem("Continuous Scroll", { view.setPageLayout(PdfPageLayout.continuous); }))
            .add(new MenuItem("Two Pages", { view.setPageLayout(PdfPageLayout.twoPages); }))
            .add(new MenuSeparator())
            .add(new MenuItem("Actual Size", { view.setZoom(1); }).accelerator("Ctrl+0"))
            .add(new MenuItem("Fit Width", { view.setFit(PdfFit.width); }).accelerator("Ctrl+1"))
            .add(new MenuItem("Fit Page", { view.setFit(PdfFit.page); }).accelerator("Ctrl+2"))
            .add(new MenuItem("Zoom to Region", { if (view.region.page >= 0) view.zoomToRect(view.region.page, view.region.rect); }))
            .add(new MenuSeparator())
            .add(new MenuItem("Slideshow", { slideshow(true); }).accelerator("Ctrl+Shift+F"));
        auto go = new Menu("Go")
            .add(new MenuItem("Next Page", { view.goToPage(view.currentPage + 1); }).accelerator("Page Down"))
            .add(new MenuItem("Previous Page", { view.goToPage(view.currentPage - 1); }).accelerator("Page Up"))
            .add(new MenuItem("First Page", { view.goToPage(0); }).accelerator("Home"))
            .add(new MenuItem("Last Page", { if (ready) view.goToPage(document.pageCount - 1); }).accelerator("End"))
            .add(new MenuItem("Go to Page…", { pageField.requestFocus(); pageField.selectAll(); }).accelerator("Ctrl+Alt+G"))
            .add(new MenuSeparator())
            .add(new MenuItem("Bookmark This Page", { bookmark(); }).accelerator("Ctrl+D"));
        auto tools = new Menu("Tools")
            .add(new MenuItem("Markup Toolbar", { toggleMarkup(); }).accelerator("Ctrl+Shift+A"))
            .add(new MenuItem("Highlight Selection", { view.markSelectedText(PdfAnnotationKind.highlight); }).accelerator("Ctrl+Shift+H"))
            .add(new MenuItem("Underline Selection", { view.markSelectedText(PdfAnnotationKind.underline); }))
            .add(new MenuItem("Strike Through Selection", { view.markSelectedText(PdfAnnotationKind.strikeOut); }))
            .add(new MenuSeparator())
            .add(new MenuItem("Rotate Left", { rotate(3); }).accelerator("Ctrl+L"))
            .add(new MenuItem("Rotate Right", { rotate(1); }).accelerator("Ctrl+R"))
            .add(new MenuItem("Crop", { cropToRegion(); }).accelerator("Ctrl+K"));
        return new ContextMenu().add(file).add(edit).add(viewMenu).add(go).add(tools);
    }

    void showTab(SidebarShows which)
    {
        if (!sidebarShown)
            toggleSidebar();
        sidebarShows(which);
    }

    /// The sidebar's pages, right-clicked: what can be done to them.
    void pageMenu(float x, float y)
    {
        auto pages = thumbnails.selectedPages.dup;
        auto menu = new ContextMenu()
            .add(new MenuItem("Rotate Left", { if (ready) document.rotatePages(pages, 3); }))
            .add(new MenuItem("Rotate Right", { if (ready) document.rotatePages(pages, 1); }))
            .add(new MenuItem(pages.length > 1 ? "Delete Pages" : "Delete Page", { deletePages(pages); }))
            .add(new MenuSeparator())
            .add(new MenuItem("Insert Blank Page After", {
                if (ready && pages.length)
                    document.insertBlankPage(pages[$ - 1] + 1, document.pageSize(pages[$ - 1]));
            }))
            .add(new MenuItem("Insert Pages From File…", { insertFromFile(); }))
            .add(new MenuItem("Export as Pictures…", { if (ready) export_(root, document, pages, &say); }));
        menu.showAt(thumbnails, x, y);
    }

    MenuItem zoomItem(int percent)
    {
        return new MenuItem(format!"%s%%"(percent), { view.setZoom(percent / 100.0f); });
    }

    /// The view's state, shown in the title bar and sidebar as it changes.
    void watchView()
    {
        view.currentPageProperty.addListener((int was, int now) {
            pageField.setText((now + 1).to!string);
            thumbnails.setCurrentPage(now);
        });
        view.zoomProperty.addListener((float was, float now) { showZoom(); });
        view.fitProperty.addListener((PdfFit was, PdfFit now) { showZoom(); });
        void showMatches()
        {
            if (!searched.length)
                matches.setText("");
            else if (view.matchCount == 0)
                matches.setText(view.searching ? "Searching…" : "Not found");
            else
                matches.setText(format!"%s of %s%s"(view.currentMatch + 1, view.matchCount, view.searching ? "+" : ""));
            if (shows == SidebarShows.results && !view.searching)
                results.refresh();
        }
        view.matchCountProperty.addListener((int was, int now) { showMatches(); });
        view.currentMatchProperty.addListener((int was, int now) { showMatches(); });
        view.searchingProperty.addListener((bool was, bool now) { showMatches(); });
    }

    void showZoom()
    {
        final switch (view.fit)
        {
            case PdfFit.width: zoomButton.setText("Fit width"); break;
            case PdfFit.page: zoomButton.setText("Fit page"); break;
            case PdfFit.none: zoomButton.setText(format!"%s%%"(cast(int) (view.zoom * 100 + 0.5f))); break;
        }
    }

    void showTitle()
    {
        if (!document)
            return;
        const title = document.title ~ (document.edited ? " — Edited" : "");
        titleBar.setTitle(title); // the app's own title bar, which the window's title doesn't reach
        window.setTitle(title);
        pageCount.setText("of " ~ document.pageCount.to!string);
    }

    /// Enter in the search field: a new search if what's typed changed, else the next match.
    void find(bool backwards)
    {
        const text = search.text.strip;
        if (text != searched)
        {
            searched = text;
            if (text.length)
            {
                view.find(text);
                showTab(SidebarShows.results);
            }
            else
                view.clearSearch();
        }
        else if (backwards)
            view.findPrevious();
        else
            view.findNext();
    }

    void statusChanged(PdfStatus st)
    {
        final switch (st)
        {
            case PdfStatus.loading:
                message.setText("Opening " ~ baseName(document.path) ~ "…");
                break;
            case PdfStatus.ready:
                store.opened(document.path);
                view.setDocument(document);
                thumbnails.setDocument(document);
                contents.setDocument(document);
                notes.show(document);
                bookmarkList.show(document.path);
                sidebarTabs[SidebarShows.contents].setDisable(contents.empty);
                sidebarShows(SidebarShows.pages);
                middle.remove(welcome);
                if (!middle.children.length)
                    middle.add(documentArea);
                showSidebar();
                pageField.setText("1");
                searched = null;
                matches.setText("");
                showTitle();
                document.pageCountProperty.addListener((int was, int now) { showTitle(); });
                if (document.info.hasForm)
                    say("This PDF has a form: click a field to fill it in");
                view.requestFocus();
                break;
            case PdfStatus.needsPassword:
                askPassword();
                break;
            case PdfStatus.failed:
                showWelcome(document.error.message ~ ".");
                break;
            case PdfStatus.closed:
                break;
        }
    }

    void showWelcome(string why)
    {
        message.setText(why);
        buildWelcome();
        middle.remove(documentArea);
        if (!middle.children.length)
            middle.add(welcome);
        root.setLeft(null);
        pageCount.setText("");
        pageField.setText("");
        titleBar.setTitle("PDF Viewer");
        window.setTitle("PDF Viewer");
    }

    /// The document's encrypted: its password, asked for, and it's opened again with it.
    void askPassword()
    {
        const path = document.path;
        const wrong = document.error.message == "That password isn't right";
        auto field = new PasswordField().prefWidth(260);
        auto dialog = new Dialog(wrong ? "That password isn't right" : "This PDF is protected")
            .text(format!"Enter the password to open “%s”."(baseName(path)))
            .extra(field)
            .addButton("Cancel", { showWelcome("“" ~ baseName(path) ~ "” is protected by a password."); }, ButtonKind.cancel)
            .addButton("Open", { load(path, field.text); }, ButtonKind.default_);
        dialog.show(root);
        field.requestFocus();
    }

    /// A note's or text box's text, edited; a text box left empty goes.
    void editAnnotationText(int page, PdfAnnotation a)
    {
        editText(view, page, a, (string text) {
            if (text == a.text)
            {
                if (a.kind == PdfAnnotationKind.textBox && !text.strip.length)
                    document.removeAnnotation(page, a.index);
                return;
            }
            if (a.kind == PdfAnnotationKind.textBox && !text.strip.length)
            {
                document.removeAnnotation(page, a.index);
                return;
            }
            auto changed = a.copy();
            changed.text = text;
            view.changeAnnotation(page, a.index, changed);
        });
    }

    /// A web link, opened as the desktop opens them: in the browser.
    static void openOutside(string uri)
    {
        import std.process : Config, spawnProcess;
        version (OSX) auto command = ["open", uri];
        else version (Windows) auto command = ["cmd", "/c", "start", "", uri];
        else auto command = ["xdg-open", uri];
        try
            spawnProcess(command, null, Config.detached);
        catch (Exception) {}
    }
}

/// The window's content, which hears the shortcuts nothing in it took.
final class ViewerRoot : Dock
{
    this(Viewer viewer) { this.viewer = viewer; }

protected:
    override void handleShortcut(ref KeyEvent event)
    {
        if (event.type != KeyEventType.pressed)
            return;
        const ctrl = event.control || event.meta;
        auto v = viewer;
        auto view = v.view;
        const c = event.code;
        if (v.inSlideshow)
        {
            if (c == KeyCode.escape)
                v.slideshow(false);
            else if (c == KeyCode.space || c == KeyCode.right || c == KeyCode.down || c == KeyCode.pageDown)
                view.goToPage(view.currentPage + 1);
            else if (c == KeyCode.left || c == KeyCode.up || c == KeyCode.pageUp || c == KeyCode.backspace)
                view.goToPage(view.currentPage - 1);
            else
                return;
            event.consume();
            return;
        }
        if (ctrl && event.alt)
        {
            if (c == cast(KeyCode) '1') v.showTab(SidebarShows.pages);
            else if (c == cast(KeyCode) '2') v.showTab(SidebarShows.contents);
            else if (c == cast(KeyCode) '3') v.showTab(SidebarShows.notes);
            else if (c == cast(KeyCode) '4') v.showTab(SidebarShows.bookmarks);
            else if (c == KeyCode.g) { v.pageField.requestFocus(); v.pageField.selectAll(); }
            else return;
            event.consume();
            return;
        }
        if (ctrl && event.shift)
        {
            if (c == KeyCode.s) v.saveAs();
            else if (c == KeyCode.z) v.redo();
            else if (c == KeyCode.a) v.toggleMarkup();
            else if (c == KeyCode.f) v.slideshow(true);
            else if (c == KeyCode.g) view.findPrevious();
            else if (c == KeyCode.h) view.markSelectedText(PdfAnnotationKind.highlight);
            else return;
            event.consume();
            return;
        }
        if (ctrl && c == KeyCode.o) v.choose();
        else if (ctrl && c == KeyCode.s) v.save();
        else if (ctrl && c == KeyCode.e) v.exportIt();
        else if (ctrl && c == KeyCode.p) v.print_();
        else if (ctrl && c == KeyCode.i) v.info();
        else if (ctrl && c == KeyCode.w) v.requestClose();
        else if (ctrl && c == KeyCode.z) v.undo();
        else if (ctrl && c == KeyCode.y) v.redo();
        else if (ctrl && c == KeyCode.c) v.copyAnnotation();
        else if (ctrl && c == KeyCode.v) v.pasteAnnotation();
        else if (ctrl && c == KeyCode.f) v.focusSearch();
        else if (ctrl && c == KeyCode.g) view.findNext();
        else if (ctrl && c == KeyCode.d) v.bookmark();
        else if (ctrl && c == KeyCode.k) v.cropToRegion();
        else if (c == KeyCode.f9) v.toggleSidebar();
        else if (ctrl && (c == cast(KeyCode) '=' || c == cast(KeyCode) '+')) view.zoomIn();
        else if (ctrl && c == cast(KeyCode) '-') view.zoomOut();
        else if (ctrl && c == KeyCode.digit0) view.setZoom(1);
        else if (ctrl && c == cast(KeyCode) '1') view.setFit(PdfFit.width);
        else if (ctrl && c == cast(KeyCode) '2') view.setFit(PdfFit.page);
        else if (ctrl && c == KeyCode.r) v.rotate(1);
        else if (ctrl && c == KeyCode.l) v.rotate(3);
        else if (!ctrl && c == KeyCode.pageDown) view.goToPage(view.currentPage + 1);
        else if (!ctrl && c == KeyCode.pageUp) view.goToPage(view.currentPage - 1);
        else
            return;
        event.consume();
    }

private:
    Viewer viewer;
}
