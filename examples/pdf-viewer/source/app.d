/*
    A PDF viewer, in the manner of the readers desktops come with: pages down the side, or the
    document's contents; the document in the middle, scrolled, zoomed and turned; a search field;
    text selected and copied; links followed. Built with mayfair-pdf, reading with PDFium.

        dub run                       opens nothing: open a PDF, drop one on the window, or open the tour
        dub run -- file.pdf           opens file.pdf

    Shortcuts: Ctrl+O open, Ctrl+F search, Ctrl+= and Ctrl+- zoom, Ctrl+0 actual size, Ctrl+1 fit
    width, Ctrl+2 fit page, Ctrl+R and Ctrl+L turn, F9 the sidebar, Ctrl+C copy, Ctrl+A select all.
*/
import std.algorithm : endsWith;
import std.conv : to;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.string : strip, toLower;
import mayfair;
import mayfair.pdf;
import mayfair.pdf.pdfium;

void main(string[] args)
{
    PdfDocument.setEngine(new PdfiumEngine);
    auto app = new App("PDF Viewer");
    app.setSize(1180, 820);
    auto viewer = new Viewer;
    app.scene = new Scene(viewer.root).titleBar(viewer.titleBar);
    if (args.length > 1)
        viewer.open(args[1]);
    app.run();
}

/// The tour, beside this source: samples/tour.pdf.
string tour() { return buildPath(dirName(__FILE_FULL_PATH__), "..", "samples", "tour.pdf"); }

final class Viewer
{
    ViewerRoot root;
    TitleBar titleBar;

    this()
    {
        view = new PdfView;
        view.setGrow(1);
        view.onExternalLink((uri) { openOutside(uri); });

        // The sidebar: the pages, or the contents
        thumbnails = new PdfThumbnails;
        thumbnails.setGrow(1);
        thumbnails.onPageChosen((page) { view.goToPage(page); });
        contents = new PdfOutline;
        contents.setGrow(1);
        contents.onItemChosen((item) { view.goToPage(item.page, item.y); });
        showPages = new ToggleButton("Pages").selected(true);
        showContents = new ToggleButton("Contents");
        showPages.setOnAction({ sidebarShows(false); });
        showContents.setOnAction({ sidebarShows(true); });
        sidebarStack = new Stack().grow(1);
        sidebarStack.add(thumbnails);
        sidebar = new Column().prefWidth(190);
        sidebar.style("background-colour: var(--field);");
        sidebar.add(new Row().spacing(4).padding(Insets(8)).alignment(Pos.centre).add(showPages).add(showContents))
            .add(sidebarStack);

        // The middle: the document, or what to open when there's none
        message = new Label("").wrapText(true).style("font-size: 14px;");
        auto openButton = new Button("Open a PDF…").defaultButton(true).graphic(new Icon("document-open-symbolic"));
        openButton.setOnAction({ choose(); });
        auto tourButton = new Button("Open the tour").graphic(new Icon("help-browser-symbolic"));
        tourButton.setOnAction({ open(tour); });
        welcome = new Column().spacing(16).alignment(Pos.centre).fillWidth(false).padding(40);
        welcome.add(new Icon("x-office-document-symbolic").iconSize(96).style("colour: var(--prompt-text);"))
            .add(new Label("No document open").style("font-size: 22px; font-weight: bold;"))
            .add(message)
            .add(new Row().spacing(12).add(openButton).add(tourButton))
            .add(new Label("or drop a PDF on the window").style("colour: var(--prompt-text);"));
        middle = new Stack().grow(1);
        middle.add(welcome);

        root = new ViewerRoot(this);
        root.setCentre(middle);

        // Dropped on the window, from a file manager: the first PDF opened
        root.onDragOver((ref e) {
            e.acceptTransferModes(TransferMode.copy);
            e.consume();
        });
        root.onDragDropped((ref e) {
            foreach (f; e.dragboard.files)
                if (f.toLower.endsWith(".pdf"))
                {
                    open(f);
                    e.setDropCompleted(true);
                    break;
                }
            e.consume();
        });

        buildTitleBar();
        watchView();
    }

    /// Opens the PDF at `path`, with `password` if it's encrypted, in place of what's open.
    void open(string path, string password = null)
    {
        if (document)
            document.close();
        document = PdfDocument.open(path, password);
        auto doc = document;
        doc.statusProperty.addListener((PdfStatus was, PdfStatus now) {
            if (doc is document)
                statusChanged(now);
        });
        statusChanged(doc.status);
    }

    /// Asks which PDF to open.
    void choose()
    {
        new FileChooser().title("Open a PDF").addFilter("PDF documents", "pdf")
            .showOpenDialog(root, (string path) { if (path) open(path); });
    }

    void toggleSidebar()
    {
        sidebarShown = !sidebarShown;
        root.setLeft(sidebarShown && document && document.status == PdfStatus.ready ? sidebar : null);
        sidebarButton.setSelected(sidebarShown);
    }

    void focusSearch() { search.requestFocus(); }

    PdfView view;

private:
    PdfDocument document;
    PdfThumbnails thumbnails;
    PdfOutline contents;
    Column sidebar, welcome;
    Stack sidebarStack, middle;
    ToggleButton showPages, showContents, sidebarButton;
    Label message, pageCount, matches;
    TextField pageField, search;
    MenuButton zoomButton;
    string searched;
    bool sidebarShown = true;

    void buildTitleBar()
    {
        sidebarButton = new ToggleButton().graphic(new Icon("sidebar-show-symbolic")).selected(true)
            .accessibleText("Sidebar").tooltip("Show or hide the sidebar (F9)");
        sidebarButton.setOnAction({ if (sidebarButton.selected != sidebarShown) toggleSidebar(); });
        auto openButton = new Button().graphic(new Icon("document-open-symbolic")).accessibleText("Open")
            .tooltip("Open a PDF (Ctrl+O)");
        openButton.setOnAction({ choose(); });

        // Which page, of how many
        pageField = new TextField("").prefWidth(48).accessibleText("Page");
        pageField.setOnAction({
            try
                view.goToPage(pageField.text.strip.to!int - 1);
            catch (Exception) {}
            pageField.setText((view.currentPage + 1).to!string);
        });
        pageCount = new Label("");

        // Zooming: out, a menu of how much, in; and turning
        auto zoomOut = new Button().graphic(new Icon("zoom-out-symbolic")).accessibleText("Zoom out").tooltip("Zoom out (Ctrl+-)");
        zoomOut.setOnAction({ view.zoomOut(); });
        auto zoomIn = new Button().graphic(new Icon("zoom-in-symbolic")).accessibleText("Zoom in").tooltip("Zoom in (Ctrl+=)");
        zoomIn.setOnAction({ view.zoomIn(); });
        auto zooms = new ContextMenu()
            .add(new MenuItem("Fit width", { view.setFit(PdfFit.width); }).accelerator("Ctrl+1"))
            .add(new MenuItem("Fit page", { view.setFit(PdfFit.page); }).accelerator("Ctrl+2"))
            .add(new MenuSeparator());
        foreach (percent; [50, 75, 100, 125, 150, 200, 300, 400])
            zooms.add(zoomItem(percent));
        zoomButton = new MenuButton("Fit width").menu(zooms).prefWidth(104).accessibleText("Zoom");
        auto turnLeft = new Button().graphic(new Icon("object-rotate-left-symbolic")).accessibleText("Turn left")
            .tooltip("Turn the pages left (Ctrl+L)");
        turnLeft.setOnAction({ view.rotateAnticlockwise(); });
        auto turnRight = new Button().graphic(new Icon("object-rotate-right-symbolic")).accessibleText("Turn right")
            .tooltip("Turn the pages right (Ctrl+R)");
        turnRight.setOnAction({ view.rotateClockwise(); });

        // Searching
        search = new TextField("").promptText("Search").prefWidth(180).accessibleText("Search");
        search.setOnAction({ find(false); });
        matches = new Label("").style("colour: var(--prompt-text);");
        auto previous = new Button().graphic(new Icon("go-up-symbolic")).accessibleText("Previous match");
        previous.setOnAction({ view.findPrevious(); });
        auto next = new Button().graphic(new Icon("go-down-symbolic")).accessibleText("Next match");
        next.setOnAction({ find(false); });

        titleBar = new TitleBar("PDF Viewer")
            .addStart(sidebarButton).addStart(openButton)
            .addStart(new Row().spacing(6).alignment(Pos.centreLeft).add(pageField).add(pageCount))
            .addEnd(new Row().spacing(2).alignment(Pos.centreLeft).add(zoomOut).add(zoomButton).add(zoomIn))
            .addEnd(new Row().spacing(2).add(turnLeft).add(turnRight))
            .addEnd(new Row().spacing(4).alignment(Pos.centreLeft).add(matches).add(search).add(previous).add(next));
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

    /// Enter in the search field: a new search if what's typed changed, else the next match.
    void find(bool backwards)
    {
        const text = search.text.strip;
        if (text != searched)
        {
            searched = text;
            if (text.length)
                view.find(text);
            else
                view.clearSearch();
        }
        else if (backwards)
            view.findPrevious();
        else
            view.findNext();
    }

    void statusChanged(PdfStatus status)
    {
        auto window = Window.of(root);
        final switch (status)
        {
            case PdfStatus.loading:
                message.setText("Opening " ~ baseName(document.path) ~ "…");
                break;
            case PdfStatus.ready:
                view.setDocument(document);
                thumbnails.setDocument(document);
                contents.setDocument(document);
                showContents.setDisable(contents.empty);
                sidebarShows(false);
                middle.remove(welcome);
                if (!middle.children.length)
                    middle.add(view);
                root.setLeft(sidebarShown ? sidebar : null);
                pageCount.setText("of " ~ document.pageCount.to!string);
                pageField.setText("1");
                searched = null;
                matches.setText("");
                titleBar.setTitle(document.title); // the app's own title bar, which the window's title doesn't reach
                if (window)
                    window.setTitle(document.title);
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
        middle.remove(view);
        if (!middle.children.length)
            middle.add(welcome);
        root.setLeft(null);
        pageCount.setText("");
        pageField.setText("");
        titleBar.setTitle("PDF Viewer");
        if (auto window = Window.of(root))
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
            .addButton("Open", { open(path, field.text); }, ButtonKind.default_);
        dialog.show(root);
        field.requestFocus();
    }

    void sidebarShows(bool outline)
    {
        showPages.setSelected(!outline);
        showContents.setSelected(outline);
        while (sidebarStack.children.length)
            sidebarStack.remove(cast(Widget) sidebarStack.children[0]);
        sidebarStack.add(outline ? cast(Widget) contents : thumbnails);
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
        auto view = viewer.view;
        const c = event.code;
        if (ctrl && c == KeyCode.o)
            viewer.choose();
        else if (ctrl && c == KeyCode.f)
            viewer.focusSearch();
        else if (c == KeyCode.f9)
            viewer.toggleSidebar();
        else if (ctrl && (c == cast(KeyCode) '=' || c == cast(KeyCode) '+'))
            view.zoomIn();
        else if (ctrl && c == cast(KeyCode) '-')
            view.zoomOut();
        else if (ctrl && c == KeyCode.digit0)
            view.setZoom(1);
        else if (ctrl && c == cast(KeyCode) '1')
            view.setFit(PdfFit.width);
        else if (ctrl && c == cast(KeyCode) '2')
            view.setFit(PdfFit.page);
        else if (ctrl && c == KeyCode.r)
            view.rotateClockwise();
        else if (ctrl && c == KeyCode.l)
            view.rotateAnticlockwise();
        else
            return;
        event.consume();
    }

private:
    Viewer viewer;
}
