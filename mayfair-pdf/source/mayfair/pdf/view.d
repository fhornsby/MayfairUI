module mayfair.pdf.view;

import std.math : abs, ceil, floor, pow, round;
import mayfair.clipboard : Clipboard;
import mayfair.accessibility : AccessibleRole;
import mayfair.layout;
import mayfair.pdf.annotation;
import mayfair.pdf.document;
import mayfair.pdf.engine : PdfFormKey, PdfFormModifiers, PdfFormPointer;
import mayfair.pdf.thread : PdfPriority;
import mayfair.pdf.types;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.widgets;

/*
    A PDF to read: its pages one under another, scrolled, zoomed and turned, as a reader shows them.

        auto view = new PdfView(PdfDocument.open("report.pdf"));
        view.setFit(PdfFit.width);
        view.find("budget");
        view.onExternalLink((uri) { ... });

    Pages are drawn as tiles, rendered on the PDF thread as they come into view, at the screen's
    own pixels for the zoom -- so text is as sharp at 400% as at 100% -- with a small picture of the
    page under them, to show at once while they're rendered. Only pages near the screen are kept,
    so a thousand pages cost no more than ten, and tiles the view moves away from are dropped, or
    never rendered at all if they were still waiting.

    Zooming is by `zoom` -- 1 is a point a point, 100% -- or `fit`, to the window's width or a whole
    page; and by Ctrl and the wheel or a touchpad, about the pointer, Ctrl with +, - and 0, or
    zoomIn and zoomOut. `rotation` turns every page, a quarter turn a step. `currentPage` is the
    page in the middle of the view.

    Text is selected by dragging across it, a word by a double click, and copied with Ctrl+C or
    copySelection, from one page or many. find() searches every page, a page at a time on the PDF
    thread, highlighting what it finds; findNext and findPrevious go between them. Links go to
    their page, or -- for a web address -- to onExternalLink, for the app to open as it opens them.

    Pages are marked up with `tool`: highlighting, underlining or striking through text as it's
    selected; notes, text boxes, shapes, lines and arrows dragged out; drawing freehand; placing a
    signature. Each is an annotation, added to the document (so it can be undone, and is saved
    with it), in `markupStyle`. With the select tool, an annotation's selected by clicking it --
    moved by dragging, stretched by its handles, deleted with Delete -- and its text edited by
    double-clicking, which onEditAnnotation hears, for the app to show an editor. The region tool
    drags out a rectangle, to crop to. Form fields are filled in, the keyboard going to the field
    with focus.

    It's a ScrollPane: what's round the pages is its background, which can be styled.
*/
class PdfView : ScrollPane
{
public:
    this(PdfDocument document = null)
    {
        super(null);
        pages = new PdfPages(this);
        setContent(pages);
        styleClass.add("pdf-view");
        setStyle("background-colour: rgba(128, 128, 128, 0.18);");
        setFocusTraversable(true);
        setAccessibleRole(AccessibleRole.document);
        vvalueProperty.addListener((float was, float now) { pages.requestUpdate(); });
        hvalueProperty.addListener((float was, float now) { pages.requestUpdate(); });
        if (document)
            setDocument(document);
    }

    /// What it shows.
    mixin(declareProperty!(PdfDocument, "document", "null", q{ documentChanged(); }));

    /// How big it's shown: 1 is a point on the page a point on the screen. Setting it stops fitting.
    mixin(declareProperty!(float, "zoom", "1", q{ zoomChanged(); }));

    /// Whether the zoom follows the view: to its width, or to a whole page in it; or `none`, as set.
    mixin(declareProperty!(PdfFit, "fit", "PdfFit.width", q{ fitChanged(); }));

    /// How far every page is turned, in quarter turns clockwise: 0 to 3.
    mixin(declareProperty!(int, "rotation", "0", q{ rotationChanged(); }));

    /// The page in the middle of the view, from 0.
    mixin(declareReadOnlyProperty!(int, "currentPage", "0"));

    /// Whether any text is selected.
    mixin(declareReadOnlyProperty!(bool, "hasSelection", "false"));

    /// How many matches find() has found so far, and which is the current one, from 0 (-1 for none).
    mixin(declareReadOnlyProperty!(int, "matchCount", "0"));
    mixin(declareReadOnlyProperty!(int, "currentMatch", "-1")); /// ditto

    /// Whether find() is still reading pages.
    mixin(declareReadOnlyProperty!(bool, "searching", "false"));

    enum float minZoom = 0.1f, maxZoom = 8; /// How small and how big it can be shown

    /// Called when a link to a web address -- not a page of the document -- is clicked.
    PdfView onExternalLink(void delegate(string uri) handler) { _onExternalLink = handler; return this; }

    /*
        Hears a page pressed with the select tool, before the view does anything with it: which
        page, where on it in its points (unturned, from its top left), and which click of a run it
        is, 2 for a double click. Returning true takes the press from the view: a LaTeX editor's
        double click, going to the source it was made from.
    */
    PdfView onPagePressed(bool delegate(int page, float x, float y, int clicks) handler) { _onPagePressed = handler; return this; }

    /// Scrolls to page `index`, from 0: its top, or `y` points down it, if given.
    void goToPage(int index, float y = float.nan)
    {
        if (!pages.ready || index < 0 || index >= pages.count)
            return;
        pages.atStart = false;
        const at = y == y ? turnedY(index, y) * _zoom - 24 : -PdfPages.gap / 2;
        pages.scrollWhenLaidOut(scrollXNow, pages.tops[index] + at);
    }

    /// One step bigger or smaller, about the middle of the view.
    void zoomIn() { zoomTo(step(1)); }
    void zoomOut() { zoomTo(step(-1)); } /// ditto

    /// To `zoom`, keeping what's at `x`, `y` in the view -- the middle, if not given -- where it is.
    void zoomTo(float zoom, float x = float.nan, float y = float.nan)
    {
        pages.atStart = false;
        anchorX = x;
        anchorY = y;
        setZoom(zoom);
        anchorX = anchorY = float.nan;
    }

    /// Turns every page a quarter turn, one way or the other.
    void rotateClockwise() { setRotation((_rotation + 1) & 3); }
    void rotateAnticlockwise() { setRotation((_rotation + 3) & 3); } /// ditto

    /*
        Searches every page for `query` -- ignoring case unless `matchCase` -- from the current page
        on and round, highlighting each match as it's found, and going to the first. Pages whose
        text hasn't been read yet are read on the PDF thread: matchCount grows, and `searching` is
        true, until they all have been.
    */
    void find(string query, bool matchCase = false)
    {
        pages.search(query, matchCase);
    }

    /// Goes to the next match, or the one before, round at either end.
    void findNext() { pages.stepMatch(1); }
    void findPrevious() { pages.stepMatch(-1); } /// ditto

    /// Stops searching, and takes the highlights away.
    void clearSearch() { pages.search(null, false); }

    /// The text selected, from every page it's on whose text has been read.
    string selectedText() { return pages.selectionText(); }

    /// Puts the selected text on the clipboard: once every page it's on has been read, if they haven't.
    void copySelection() { pages.copy(); }

    /// Where `rect` on page `page` -- in its points, unturned, from its top left -- is in the window,
    /// as it's shown now: for what's laid over a page. Empty if the page isn't laid out.
    Bounds pageRectInScene(int page, PdfRect rect)
    {
        if (!pages.ready || page < 0 || page >= pages.count || page >= pages.tops.length)
            return Bounds.init;
        const s = _document.pageSize(page), z = _zoom;
        const t = turn(rect, _rotation, s.width, s.height);
        const b = boundsInScene, vp = viewportBounds;
        return Bounds(b.minX + pages.lefts[page] + t.x * z - vp.minX, b.minY + pages.tops[page] + t.y * z - vp.minY,
                      t.width * z, t.height * z);
    }

    /// What it has drawn and is waiting for: for finding out why it's slow, and for tests.
    PdfViewStats stats()
    {
        PdfViewStats st;
        st.pagesNear = cast(int) pages.slots.length;
        foreach (slot; pages.slots)
        {
            st.tiles += slot.tileList.length;
            st.tilesWaiting += slot.waiting.length;
            if (slot.preview)
                st.previews++;
        }
        return st;
    }

    /// How pages are laid out: one under another, or two side by side.
    mixin(declareProperty!(PdfPageLayout, "pageLayout", "PdfPageLayout.continuous", q{ pages.turned(); }));

    /// The search's matches, in page order.
    PdfMatch[] matchList()
    {
        PdfMatch[] list;
        foreach (m; pages.matches)
            list ~= PdfMatch(m.page, m.from, m.to);
        return list;
    }

    /// Makes match `index` the current one, and scrolls to it.
    void showMatch(int index) { pages.goToMatch(index); }

    /// Zooms so `rect` of page `page` fills the view, and scrolls to it.
    void zoomToRect(int page, PdfRect rect)
    {
        if (!pages.ready || page < 0 || page >= pages.count || rect.empty)
            return;
        const vp = viewportBounds;
        const s = _document.pageSize(page);
        const t = turn(rect, _rotation, s.width, s.height);
        const zx = (vp.width - 32) / t.width, zy = (vp.height - 32) / t.height;
        setZoom(zx < zy ? zx : zy);
        const z = _zoom;
        pages.atStart = false;
        pages.scrollWhenLaidOut(pages.lefts[page] + (t.x + t.width / 2) * z - vp.width / 2,
                                pages.tops[page] + (t.y + t.height / 2) * z - vp.height / 2);
    }

    /// Selects every page's text, or none.
    void selectAll() { pages.selectAll(); }
    void clearSelection() { pages.clearSelection(); } /// ditto

    // Marking up

    /// What the pointer does on a page.
    mixin(declareProperty!(PdfTool, "tool", "PdfTool.select", q{ pages.toolChanged(); }));

    /// How what's drawn next looks.
    mixin(declareProperty!(PdfMarkupStyle, "markupStyle", "PdfMarkupStyle.init"));

    /// The annotation selected, to move, change or delete: page -1 for none.
    mixin(declareReadOnlyProperty!(PdfAnnotationRef, "selectedAnnotation", "PdfAnnotationRef.init"));

    /// The rectangle dragged out with the region tool: page -1 for none.
    mixin(declareReadOnlyProperty!(PdfRegion, "region", "PdfRegion.init"));

    /// What the signature tool places: a signature annotation, its strokes in its rect.
    void setSignature(PdfAnnotation signature) { pages.signature = signature.copy(); }

    /// ditto
    bool hasSignature() const { return pages.signature.strokes.length > 0; }

    /// Hears that an annotation's text wants editing: a note or text box double-clicked, or just
    /// made. The app shows an editor, and changes it with changeAnnotation.
    PdfView onEditAnnotation(void delegate(int page, PdfAnnotation a) handler)
    {
        _onEditAnnotation = handler;
        return this;
    }

    /// The selected annotation, as it was last read: null if none is selected.
    PdfAnnotation* selectedAnnotationValue()
    {
        if (_selectedAnnotation.page < 0 || !_document)
            return null;
        if (auto list = _document.cachedAnnotations(_selectedAnnotation.page))
            foreach (ref a; list.list)
                if (a.index == _selectedAnnotation.index)
                {
                    auto copy = new PdfAnnotation;
                    *copy = a.copy();
                    return copy;
                }
        return null;
    }

    /// Changes annotation `index` of page `page` to `a`, keeping it selected if it was.
    void changeAnnotation(int page, int index, PdfAnnotation a)
    {
        if (!_document)
            return;
        const wasSelected = _selectedAnnotation == PdfAnnotationRef(page, index);
        _document.updateAnnotation(page, index, a, (int now) {
            if (wasSelected && now >= 0)
                _setSelectedAnnotation(PdfAnnotationRef(page, now));
            pages.overlayChanged();
        });
    }

    /// Restyles the selected annotation: `change` is handed it, to change.
    void restyleSelected(void delegate(ref PdfAnnotation) change)
    {
        auto a = selectedAnnotationValue;
        if (!a || !a.ours)
            return;
        auto changed = a.copy();
        change(changed);
        changeAnnotation(_selectedAnnotation.page, _selectedAnnotation.index, changed);
    }

    /// Deletes the selected annotation.
    void deleteSelectedAnnotation()
    {
        if (_selectedAnnotation.page < 0 || !_document)
            return;
        _document.removeAnnotation(_selectedAnnotation.page, _selectedAnnotation.index);
        selectAnnotation(PdfAnnotationRef.init);
    }

    /// Selects annotation `which`, or none for PdfAnnotationRef.init.
    void selectAnnotation(PdfAnnotationRef which)
    {
        _setSelectedAnnotation(which);
        pages.overlayChanged();
    }

    /// Marks the text selected with an annotation of `kind`: a highlight, an underline, a strike through.
    void markSelectedText(PdfAnnotationKind kind) { pages.markSelection(kind); }

    /// Forgets the region dragged out.
    void clearRegion()
    {
        _setRegion(PdfRegion.init);
        pages.overlayChanged();
    }

    /// Crops the page the region's on -- or `pages`, if given -- to it.
    void cropToRegion(const int[] pagesToCrop = null)
    {
        if (_region.page < 0 || !_document)
            return;
        _document.cropPages(pagesToCrop.length ? pagesToCrop : [_region.page], _region.rect);
        clearRegion();
    }

protected:
    override void handleScroll(ref ScrollEvent event)
    {
        pages.atStart = false;
        // Ctrl and the wheel, or a pinch on a touchpad: zoom, about the pointer
        if (event.control && pages.ready)
        {
            const factor = pow(1.0015f, event.deltaY);
            zoomTo(_zoom * factor, event.x, event.y);
            event.consume();
            return;
        }
        super.handleScroll(event);
    }

    override void handleKey(ref KeyEvent event)
    {
        if (pages.ready && _document.formFocus >= 0 && formKey(event))
        {
            event.consume();
            return;
        }
        if (event.type == KeyEventType.pressed && pages.ready && !(event.control || event.meta)
            && _selectedAnnotation.page >= 0)
        {
            if (event.code == KeyCode.delete_ || event.code == KeyCode.backspace)
            {
                deleteSelectedAnnotation();
                event.consume();
                return;
            }
            if (event.code == KeyCode.escape)
            {
                selectAnnotation(PdfAnnotationRef.init);
                event.consume();
                return;
            }
        }
        if (event.type == KeyEventType.pressed && pages.ready && event.code == KeyCode.escape
            && (_tool != PdfTool.select || _region.page >= 0))
        {
            clearRegion();
            setTool(PdfTool.select);
            event.consume();
            return;
        }
        if (event.type == KeyEventType.pressed && pages.ready)
        {
            pages.atStart = false;
            const ctrl = event.control || event.meta;
            const c = event.code;
            if (ctrl && c == KeyCode.c && _hasSelection)
                copySelection();
            else if (ctrl && c == KeyCode.a && !event.shift)
                selectAll();
            else if (ctrl && (c == cast(KeyCode) '=' || c == cast(KeyCode) '+'))
                zoomIn();
            else if (ctrl && c == cast(KeyCode) '-')
                zoomOut();
            else if (ctrl && c == KeyCode.digit0)
                zoomTo(1);
            else if (c == KeyCode.home)
                goToPage(0);
            else if (c == KeyCode.end)
                goToPage(pages.count - 1);
            else if ((c == KeyCode.left || c == KeyCode.up) && hvalueStill && !ctrl && fullPages)
                goToPage(_currentPage - 1);
            else if ((c == KeyCode.right || c == KeyCode.down) && hvalueStill && !ctrl && fullPages)
                goToPage(_currentPage + 1);
            else if (c == KeyCode.escape && _hasSelection)
                clearSelection();
            else
            {
                super.handleKey(event);
                return;
            }
            event.consume();
            return;
        }
        super.handleKey(event);
    }

private:
    PdfPages pages;
    void delegate(string) _onExternalLink;
    bool delegate(int, float, float, int) _onPagePressed;
    void delegate(int, PdfAnnotation) _onEditAnnotation;

    /// A key while a form field has focus: whether it was the field's.
    bool formKey(ref KeyEvent event)
    {
        auto doc = _document;
        const ctrl = event.control || event.meta;
        if (event.type == KeyEventType.typed)
        {
            if (event.character.length)
                doc.formText(event.character);
            return true;
        }
        if (event.type != KeyEventType.pressed)
            return false;
        uint mods;
        if (event.shift) mods |= PdfFormModifiers.shift;
        if (ctrl) mods |= PdfFormModifiers.control;
        if (event.alt) mods |= PdfFormModifiers.alt;
        if (ctrl)
        {
            switch (event.code)
            {
                case KeyCode.a: doc.formSelectAll(); return true;
                case KeyCode.c: doc.formSelectedText((string t) { if (t.length) Clipboard.text(t); }); return true;
                case KeyCode.x:
                    doc.formSelectedText((string t) { if (t.length) { Clipboard.text(t); doc.formText(""); } });
                    return true;
                case KeyCode.v:
                    if (auto t = Clipboard.text)
                        doc.formText(t);
                    return true;
                case KeyCode.z: doc.formUndo(event.shift); return true;
                case KeyCode.y: doc.formUndo(true); return true;
                default: return false; // the app's shortcuts
            }
        }
        PdfFormKey key;
        switch (event.code)
        {
            case KeyCode.backspace: key = PdfFormKey.backspace; break;
            case KeyCode.tab: key = PdfFormKey.tab; break;
            case KeyCode.enter, KeyCode.numpadEnter: key = PdfFormKey.enter; break;
            case KeyCode.escape:
                doc.formBlur();
                return true;
            case KeyCode.left: key = PdfFormKey.left; break;
            case KeyCode.right: key = PdfFormKey.right; break;
            case KeyCode.up: key = PdfFormKey.up; break;
            case KeyCode.down: key = PdfFormKey.down; break;
            case KeyCode.home: key = PdfFormKey.home; break;
            case KeyCode.end: key = PdfFormKey.end; break;
            case KeyCode.pageUp: key = PdfFormKey.pageUp; break;
            case KeyCode.pageDown: key = PdfFormKey.pageDown; break;
            case KeyCode.delete_: key = PdfFormKey.delete_; break;
            default:
                return false; // typed, as text, instead
        }
        doc.formKey(key, true, mods);
        return true;
    }

    void editAnnotation(int page, PdfAnnotation a)
    {
        if (_onEditAnnotation)
            _onEditAnnotation(page, a);
    }
    PdfDocument watching;
    float anchorX = float.nan, anchorY = float.nan; // where zoomTo keeps still
    bool fitting;                                    // the zoom's being set by fit, not by hand

    static immutable float[] steps = [0.1f, 0.25f, 0.33f, 0.5f, 0.67f, 0.75f, 0.9f, 1, 1.1f, 1.25f, 1.5f,
                                      1.75f, 2, 2.5f, 3, 4, 5, 6, 8];

    float step(int by)
    {
        if (by > 0)
        {
            foreach (s; steps)
                if (s > _zoom * 1.01f)
                    return s;
            return maxZoom;
        }
        foreach_reverse (s; steps)
            if (s < _zoom * 0.99f)
                return s;
        return minZoom;
    }

    float scrollXNow() nothrow @nogc { return viewportBounds.minX; }
    bool hvalueStill() nothrow @nogc { return true; }
    bool fullPages() nothrow @nogc { return _fit == PdfFit.page; } // arrows go a page at a time when a page fits

    /// `y` points down page `index`, unturned, as it is once turned: what goToPage scrolls to.
    float turnedY(int index, float y)
    {
        const s = _document.pageSize(index);
        return turn(PdfRect(0, y, 0.001f, 0.001f), _rotation, s.width, s.height).y;
    }

    void documentChanged()
    {
        if (watching)
            watching.removeChangeListener(&pages.documentEdited);
        if (_document)
        {
            _document.addChangeListener(&pages.documentEdited);
            auto doc = _document;
            doc.formFocusProperty.addListener((int was, int now) {
                if (doc is watching)
                    setAcceptsTextInput(now >= 0);
            });
        }
        setAcceptsTextInput(false);
        _setSelectedAnnotation(PdfAnnotationRef.init);
        _setRegion(PdfRegion.init);
        watching = _document;
        if (_document && _document.status == PdfStatus.loading)
        {
            auto doc = _document;
            doc.statusProperty.addListener((PdfStatus was, PdfStatus now) {
                if (doc is watching)
                    pages.reset();
            });
        }
        pages.reset();
    }

    void zoomChanged()
    {
        const clamped = _zoom < minZoom ? minZoom : _zoom > maxZoom ? maxZoom : _zoom;
        if (clamped != _zoom)
        {
            setZoom(clamped);
            return;
        }
        if (!fitting && _fit != PdfFit.none)
        {
            fitting = true; // setFit's reaction would fit it back
            setFit(PdfFit.none);
            fitting = false;
        }
        pages.rezoom(anchorX, anchorY);
    }

    void fitChanged()
    {
        if (!fitting)
            pages.applyFit();
    }

    void rotationChanged()
    {
        if (_rotation < 0 || _rotation > 3)
        {
            setRotation(_rotation & 3);
            return;
        }
        pages.turned();
    }

    /// Zooms to fit, as `fit` says, without stopping it fitting.
    void fitZoom(float zoom)
    {
        fitting = true;
        scope (exit) fitting = false;
        setZoom(zoom);
    }

    void externalLink(string uri)
    {
        if (_onExternalLink)
            _onExternalLink(uri);
    }
}

/// What a PdfView has drawn, and is waiting for.
struct PdfViewStats
{
    int pagesNear;     /// Pages near enough the view to be kept
    size_t tiles;      /// Tiles drawn, of those pages
    size_t tilesWaiting; /// Tiles asked for, not rendered yet
    int previews;      /// Pages with their preview drawn
}

/// How a PdfView lays out its pages.
enum PdfPageLayout
{
    continuous, /// One under another
    twoPages,   /// Two side by side, the first on the left: as a book's opened, but for its cover
}

/// A search's match: characters [from, to) of page `page`'s text.
struct PdfMatch
{
    int page;
    size_t from, to;
}

/// What the pointer does on a PdfView's pages.
enum PdfTool
{
    select,         /// Selects text, and annotations; follows links; fills in forms
    region,         /// Drags out a rectangle: to crop to
    highlight,      /// Highlights text as it's selected
    underline,      /// Underlines text as it's selected
    strikeOut,      /// Strikes text through as it's selected
    note,           /// Puts a note where it's clicked
    textBox,        /// Drags out a text box
    rectangle,      /// Drags out a shape: ...
    roundedRectangle,
    oval,
    line,
    arrow,
    star,
    speechBubble,
    draw,           /// Draws freehand
    signature,      /// Puts the signature (see PdfView.setSignature) where it's clicked
}

/// How annotations a PdfView makes look.
struct PdfMarkupStyle
{
    PdfColour colour = PdfColour(220, 38, 38);       /// Lines, shapes, drawing, underlines
    PdfColour fill = PdfColour(0, 0, 0, 0);          /// Inside shapes and text boxes: none
    float lineWidth = 3;
    PdfColour textColour = PdfColour(0, 0, 0);       /// Text boxes'
    float fontSize = 16;
    PdfColour highlight = PdfColour(255, 214, 10);   /// Highlights'
    PdfColour note = PdfColour(255, 204, 0);         /// Notes'
}

/// An annotation, by its page and its index among that page's.
struct PdfAnnotationRef
{
    int page = -1;
    int index = -1;
}

/// A rectangle on a page.
struct PdfRegion
{
    int page = -1;
    PdfRect rect;
}

/// How a PdfView's zoom follows its size.
enum PdfFit
{
    none,   /// It doesn't: the zoom is as it's set
    width,  /// The widest page fills the view's width
    page,   /// A whole page fits in the view
}

private:

/// Where a selection starts or ends: before character `index` of `page`.
struct Boundary
{
    int page;
    size_t index;

    int opCmp(const Boundary o) const pure nothrow @nogc
    {
        if (page != o.page)
            return page < o.page ? -1 : 1;
        return index < o.index ? -1 : index > o.index ? 1 : 0;
    }
}

/// A match of a search: characters [from, to) of `page`.
struct Match
{
    int page;
    size_t from, to;
}

/// Something drawn over a page: an outline, or handles, in the page's points.
struct OverlayItem
{
    int page = -1;
    PdfPathOp[] ops;
    PdfColour stroke, fill = PdfColour(0, 0, 0, 0);
    float width = 1;
    bool zoomed;        // its width in the page's points, so zoomed with it; else in the screen's
    bool dashed;
    PdfPoint[] handles; // little squares, a fixed size on the screen
}

/// What a tile is of: a part of a page, rendered at a scale, turned.
struct TileKey
{
    float scale;
    int turns;
    int column, row;
    uint version_;   // the page's, as the document has it: an edit renders it again
}

final class Tile
{
    TileKey key;
    PdfRect region;  // of the turned page, in points
    uint width, height;
    Tvg_Paint picture;
    ulong used;      // the frame it was last wanted
}

/// A page near the view: what's drawn of it, and what's been asked for it.
final class Slot
{
    int page;
    Tvg_Paint scene, shadow, frame, previewHolder, preview, tiles, selection, matches, current;
    PdfBitmap previewBitmap;
    uint previewVersion;
    PdfRequest previewRequest, textRequest, linksRequest, annotationsRequest;
    Tile[] tileList;
    PdfRequest[TileKey] waiting;
    PdfRect[] selectionRects, matchRects, currentRects; // on the unturned page, in points
}

/*
    The pages, as a PdfView's content: as big as all of them, at the zoom, one under another with
    a gap between, centred across. It lays them out itself, and draws the ones near the view.
*/
final class PdfPages : Widget
{
    enum float margin = 16, gap = 12;
    enum uint tileSize = 512;   // pixels a side
    enum size_t maxTiles = 160; // about 160MB of them, at most

    this(PdfView view)
    {
        this.view = view;
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measurePages);
        setCursor(Cursor.default_);
    }

    PdfView view;
    float[] tops, lefts, widths, heights; // each page, at the zoom, turned, in points of the content
    float[] rowTops;                      // the top of the row each page's in: one page a row, or two
    int count;
    float contentWidth = 0, contentHeight = 0;

    bool ready() nothrow @nogc
    {
        return view._document && view._document.status == PdfStatus.ready;
    }

    /// The document, or how it's shown, changed: start again.
    void reset()
    {
        dropSlots();
        anchor = focus = Boundary.init;
        view._setHasSelection(false);
        search(null, false);
        count = ready ? view._document.pageCount : 0;
        fitted = false;
        atStart = true;
        relayout();
        scrollWhenLaidOut(0, 0);
        requestUpdate();
    }

    /// The zoom changed: lay out again, keeping what's at `x`, `y` in the view still -- the middle if NaN.
    void rezoom(float x, float y)
    {
        if (!ready || !count)
            return;
        const vp = view.viewportBounds;
        if (x != x) x = vp.width / 2;
        if (y != y) y = vp.height / 2;
        // What's there, on which page, in its unzoomed points -- from where the last zoom's about to
        // scroll it, if it hasn't yet: a wheel's notches can come faster than the frames
        float sx = vp.minX, sy = vp.minY;
        if (scrollPending)
        {
            sx = clampScroll(pendingX, contentWidth - vp.width);
            sy = clampScroll(pendingY, contentHeight - vp.height);
        }
        const cx = sx + x, cy = sy + y;
        const i = pageAt(cy);
        const z = laidZoom > 0 ? laidZoom : view._zoom;
        const px = (cx - lefts[i]) / z, py = (cy - tops[i]) / z;
        relayout();
        if (atStart)
            scrollToStart(); // just opened: its first page's top, whatever the zoom
        else
            scrollWhenLaidOut(lefts[i] + px * view._zoom - x, tops[i] + py * view._zoom - y);
        requestUpdate();
    }

    /// The pages were turned: lay out again, keeping the current page in view.
    void turned()
    {
        if (!ready)
            return;
        const page = view._currentPage;
        dropSlots(); // tiles were rendered turned the old way
        applyFit();
        relayout();
        if (page < count)
            scrollWhenLaidOut(view.scrollXNow, tops[page] - gap / 2);
        requestUpdate();
    }

    /// Zooms as `fit` says, for the view's size.
    void applyFit()
    {
        if (!ready || !count || viewportWidth <= 0)
            return;
        const fit = view._fit;
        if (fit == PdfFit.none)
            return;
        float widest = 0;
        const two = view._pageLayout == PdfPageLayout.twoPages;
        for (int i = 0; i < count; i += two ? 2 : 1)
        {
            float w = turnedSize(i).width;
            if (two && i + 1 < count)
                w += turnedSize(i + 1).width;
            if (w > widest)
                widest = w;
        }
        float zoom = (viewportWidth - 2 * margin - (two ? gap : 0)) / widest;
        if (fit == PdfFit.page)
        {
            const s = turnedSize(view._currentPage < count ? view._currentPage : 0);
            const tall = (viewportHeight - 2 * margin) / s.height;
            if (tall < zoom)
                zoom = tall;
        }
        fitted = true;
        if (abs(zoom - view._zoom) > 0.0005f)
            view.fitZoom(zoom);
    }

    // Scrolling once the layout's caught up with the pages' new size: see update
    void scrollWhenLaidOut(float x, float y)
    {
        scrollPending = true;
        pendingX = x;
        pendingY = y;
        requestUpdate();
    }

    /// The page at `y` in the content, or the nearest.
    int pageAt(float y) const nothrow @nogc
    {
        if (!count)
            return 0;
        size_t lo = 0, hi = count;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (rowTops[mid] - gap / 2 <= y)
                lo = mid;
            else
                hi = mid;
        }
        return cast(int) lo;
    }

    // Searching

    void search(string query, bool matchCase)
    {
        import std.conv : to;
        foreach (r; searchRequests)
            r.cancel();
        searchRequests = null;
        generation++;
        matches = null;
        this.query = query.length ? query.to!dstring : null;
        this.matchCase = matchCase;
        searched = 0;
        view._setMatchCount(0);
        view._setCurrentMatch(-1);
        view._setSearching(false);
        marksChanged();
        if (!this.query.length || !ready)
            return;
        view._setSearching(true);
        const from = view._currentPage;
        foreach (k; 0 .. count)
            searchRequests ~= searchPage((from + k) % count, generation);
    }

    void goToMatch(int index)
    {
        if (index < 0 || index >= matches.length)
            return;
        view._setCurrentMatch(index);
        marksChanged();
        reveal(matches[index]);
    }

    void stepMatch(int by)
    {
        if (!matches.length)
            return;
        auto at = view._currentMatch;
        at = at < 0 ? 0 : cast(int) ((at + by + matches.length) % matches.length);
        view._setCurrentMatch(at);
        marksChanged();
        reveal(matches[at]);
    }

    // Selecting

    string selectionText()
    {
        if (!view._hasSelection || !ready)
            return null;
        auto from = anchor < focus ? anchor : focus, to = anchor < focus ? focus : anchor;
        string text;
        foreach (p; from.page .. to.page + 1)
        {
            auto t = view._document.cachedText(p);
            if (!t)
                continue;
            const a = p == from.page ? from.index : 0, b = p == to.page ? to.index : t.length;
            if (text.length && a < b)
                text ~= "\n";
            text ~= t.between(a, b);
        }
        return text;
    }

    void copy()
    {
        if (!view._hasSelection || !ready)
            return;
        // Every page it's on, read first
        auto from = anchor < focus ? anchor : focus, to = anchor < focus ? focus : anchor;
        int missing;
        const gen = ++copyGeneration;
        foreach (p; from.page .. to.page + 1)
            if (!view._document.cachedText(p))
            {
                missing++;
                view._document.text(p, PdfPriority.visible, (PdfPageText t) {
                    if (gen == copyGeneration && --missing == 0)
                        Clipboard.text(selectionText());
                });
            }
        if (!missing)
            Clipboard.text(selectionText());
    }

    void selectAll()
    {
        if (!ready || !count)
            return;
        anchor = Boundary(0, 0);
        focus = Boundary(count - 1, size_t.max);
        view._setHasSelection(true);
        marksChanged();
    }

    void clearSelection()
    {
        anchor = focus = Boundary.init;
        view._setHasSelection(false);
        marksChanged();
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        holder = addPaint(tvg_scene_new());
        overlay = addPaint(tvg_scene_new()); // over every page
        solidShapes = dashedShapes = null;
        requestUpdate();
    }

    override void unmounted()
    {
        // The holder took every slot's paints with it, and the overlay its shapes
        holder = null;
        overlay = null;
        solidShapes = dashedShapes = null;
        foreach (s; slots)
            forget(s);
        slots = null;
    }

    override void update()
    {
        frame++;
        if (!ready)
        {
            dropSlots();
            return;
        }
        if (count != view._document.pageCount)
        {
            count = view._document.pageCount;
            relayout();
        }
        auto vp = view.viewportBounds;
        if (vp.width != viewportWidth || vp.height != viewportHeight || !fitted)
        {
            viewportWidth = vp.width;
            viewportHeight = vp.height;
            if (viewportWidth > 0)
            {
                applyFit();
                relayout();
            }
        }
        if (laidZoom != view._zoom || laidTurns != view._rotation)
            relayout();
        // The scroll asked for once the content's new size is laid out
        // (Within a couple of points: layout rounds to whole pixels)
        if (scrollPending && abs(YGNodeLayoutGetHeight(node) - contentHeight) < 2
            && abs(YGNodeLayoutGetWidth(node) - contentWidth) < 2)
        {
            scrollPending = false;
            view.scrollTo(pendingX, pendingY);
            vp = view.viewportBounds;
        }
        if (!count || !holder)
            return;

        // The page in the middle of the view
        const middle = pageAt(vp.minY + vp.height / 2);
        if (middle != view._currentPage)
            view._setCurrentPage(middle);

        // The pages near the view -- a screenful either side -- each with a slot
        const rowStart = view._pageLayout == PdfPageLayout.twoPages ? ~1 : ~0;
        const first = pageAt(vp.minY - vp.height) & rowStart, last = pageAt(vp.maxY + vp.height);
        Slot[] kept;
        foreach (s; slots)
        {
            if (s.page >= first && s.page <= last)
                kept ~= s;
            else
            {
                tvg_scene_remove(holder, s.scene);
                forget(s);
            }
        }
        slots = kept;
        foreach (page; first .. last + 1)
        {
            auto s = slotFor(page);
            const visible = PdfRect(lefts[page], tops[page], widths[page], heights[page])
                .intersects(PdfRect(vp.minX, vp.minY, vp.width, vp.height));
            want(s, visible, vp);
        }
        trimTiles();
        if (overlayDirty)
            buildOverlay();
        invalidate();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        originX = x;
        originY = y;
        const vp = view.viewportBounds;
        if (vp.width != viewportWidth || vp.height != viewportHeight || scrollPending)
            requestUpdate();
        foreach (s; slots)
            place(s);
        placeOverlay();
    }

    override void handleMouse(ref MouseEvent event)
    {
        if (!ready || !count)
            return;
        switch (event.type)
        {
            case MouseEventType.pressed:
                if (event.button != MouseButton.primary)
                    return;
                atStart = false;
                view.requestFocus();
                pressed(event.x, event.y, event.clickCount, modifiers(event));
                event.consume();
                break;
            case MouseEventType.dragged:
                if (gesture == Gesture.none)
                    return;
                dragged(event.x, event.y, event.shift);
                event.consume();
                break;
            case MouseEventType.released:
                if (gesture == Gesture.none)
                    return;
                released(event.x, event.y, modifiers(event));
                event.consume();
                break;
            case MouseEventType.moved:
                int page;
                float px, py;
                pointOn(event.x, event.y, page, px, py);
                setCursor(cursorAt(page, px, py));
                break;
            default:
                break;
        }
    }

private:
    Tvg_Paint holder;
    Slot[] slots;
    float originX = 0, originY = 0;
    float viewportWidth = 0, viewportHeight = 0;
    float laidZoom = 0;
    int laidTurns = -1;
    bool fitted;
    bool atStart;        // just opened, and not moved since: kept at the top as it's fitted
    bool scrollPending;
    float pendingX = 0, pendingY = 0;
    ulong frame;

    // Selecting, and links
    Boundary anchor, focus;
    bool pressedOnLink;
    PdfLink pressedLink;
    uint copyGeneration;

    // Marking up: what's being done by dragging, and what's drawn over the pages meanwhile
    enum Gesture { none, selectText, form, move, resize, shape, ink, region }
    Gesture gesture;
    int gesturePage;
    float startX = 0, startY = 0;   // where it started, on gesturePage, in its points
    bool moved;
    PdfAnnotation original, changing; // the annotation as it was, and as it's being dragged to
    int handle = -1;
    PdfPoint[] inkPoints;
    PdfRect regionRect;
    PdfAnnotation signature;
    Tvg_Paint overlay;
    // Dashed and solid shapes apart: a dash is set once, never cleared (see placeOverlay)
    Tvg_Paint[] solidShapes, dashedShapes;
    OverlayItem[] overlayItems;
    bool overlayDirty;

    // Searching
    dstring query;
    bool matchCase;
    Match[] matches;
    int searched;
    uint generation;
    PdfRequest[] searchRequests;

    // Marking up

    static uint modifiers(ref MouseEvent event)
    {
        uint m;
        if (event.shift) m |= PdfFormModifiers.shift;
        if (event.control || event.meta) m |= PdfFormModifiers.control;
        if (event.alt) m |= PdfFormModifiers.alt;
        return m;
    }

    /// Where `x`, `y` in the content is on page `page`, in its points, kept on the page.
    PdfPoint onPage(float x, float y, int page)
    {
        const z = view._zoom, s = view._document.pageSize(page);
        float px, py;
        unturn((x - lefts[page]) / z, (y - tops[page]) / z, view._rotation, s.width, s.height, px, py);
        return PdfPoint(px < 0 ? 0 : px > s.width ? s.width : px, py < 0 ? 0 : py > s.height ? s.height : py);
    }

    /// A new annotation of `kind`, as the markup style has it.
    PdfAnnotation fresh(PdfAnnotationKind kind)
    {
        import std.process : environment;
        const st = view._markupStyle;
        PdfAnnotation a;
        a.kind = kind;
        a.colour = st.colour;
        a.fill = st.fill;
        a.lineWidth = st.lineWidth;
        a.fontSize = st.fontSize;
        a.ours = true;
        with (PdfAnnotationKind)
        {
            if (kind == highlight)
                a.colour = st.highlight;
            else if (kind == note)
                a.colour = st.note;
            else if (kind == textBox)
                a.colour = st.textColour;
        }
        a.author = environment.get("USER", environment.get("USERNAME", null));
        return a;
    }

    static PdfAnnotationKind kindFor(PdfTool tool)
    {
        with (PdfTool) switch (tool)
        {
            case highlight: return PdfAnnotationKind.highlight;
            case underline: return PdfAnnotationKind.underline;
            case strikeOut: return PdfAnnotationKind.strikeOut;
            case note: return PdfAnnotationKind.note;
            case textBox: return PdfAnnotationKind.textBox;
            case rectangle: return PdfAnnotationKind.rectangle;
            case roundedRectangle: return PdfAnnotationKind.roundedRectangle;
            case oval: return PdfAnnotationKind.oval;
            case line: return PdfAnnotationKind.line;
            case arrow: return PdfAnnotationKind.arrow;
            case star: return PdfAnnotationKind.star;
            case speechBubble: return PdfAnnotationKind.speechBubble;
            case draw: return PdfAnnotationKind.ink;
            case signature: return PdfAnnotationKind.signature;
            default: return PdfAnnotationKind.other;
        }
    }

    /// The selected annotation, if it's on `page`.
    PdfAnnotation* selectedOn(int page)
    {
        const sel = view._selectedAnnotation;
        if (sel.page != page)
            return null;
        if (auto list = view._document.cachedAnnotations(page))
            foreach (ref a; list.list)
                if (a.index == sel.index)
                    return &a;
        return null;
    }

    /// Whether `a` can be stretched, and where its handles are: rectangles' corners and edges, a line's ends.
    PdfPoint[] handlesOf(const ref PdfAnnotation a)
    {
        if (a.marksText || a.kind == PdfAnnotationKind.note || a.kind == PdfAnnotationKind.widget)
            return null;
        if ((a.kind == PdfAnnotationKind.line || a.kind == PdfAnnotationKind.arrow) && a.strokes.length
            && a.strokes[0].length >= 2)
            return [a.strokes[0][0], a.strokes[0][$ - 1]];
        const r = a.rect;
        const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
        return [PdfPoint(r.x, r.y), PdfPoint(cx, r.y), PdfPoint(r.right, r.y), PdfPoint(r.right, cy),
                PdfPoint(r.right, r.bottom), PdfPoint(cx, r.bottom), PdfPoint(r.x, r.bottom), PdfPoint(r.x, cy)];
    }

    /// Which of `a`'s handles is at `px`, `py`, or -1.
    int handleAt(const ref PdfAnnotation a, float px, float py)
    {
        const reach = 6 / view._zoom;
        foreach (i, h; handlesOf(a))
            if (px >= h.x - reach && px <= h.x + reach && py >= h.y - reach && py <= h.y + reach)
                return cast(int) i;
        return -1;
    }

    /// `a` with handle `h` dragged to `x`, `y`.
    PdfAnnotation stretched(const ref PdfAnnotation a, int h, float x, float y)
    {
        if (a.kind == PdfAnnotationKind.line || a.kind == PdfAnnotationKind.arrow)
        {
            auto b = a.copy();
            b.strokes[0][h == 0 ? 0 : $ - 1] = PdfPoint(x, y);
            b.rect = b.bounds;
            return b;
        }
        float l = a.rect.x, t = a.rect.y, r = a.rect.right, bt = a.rect.bottom;
        switch (h)
        {
            case 0: l = x; t = y; break;
            case 1: t = y; break;
            case 2: r = x; t = y; break;
            case 3: r = x; break;
            case 4: r = x; bt = y; break;
            case 5: bt = y; break;
            case 6: l = x; bt = y; break;
            default: l = x; break;
        }
        if (r < l) { const k = l; l = r; r = k; }
        if (bt < t) { const k = t; t = bt; bt = k; }
        if (r - l < 4) r = l + 4;
        if (bt - t < 4) bt = t + 4;
        return a.fittedTo(PdfRect(l, t, r - l, bt - t));
    }

    /// The rectangle from where the drag started to `p`: a square, or circle, with Shift.
    PdfRect dragRect(PdfPoint p, bool square)
    {
        float w = p.x - startX, h = p.y - startY;
        if (square)
        {
            import std.math : fabs;
            const side = fabs(w) > fabs(h) ? fabs(w) : fabs(h);
            w = w < 0 ? -side : side;
            h = h < 0 ? -side : side;
        }
        const l = w < 0 ? startX + w : startX, t = h < 0 ? startY + h : startY;
        return PdfRect(l, t, w < 0 ? -w : w, h < 0 ? -h : h);
    }

    void pressed(float x, float y, int clicks, uint mods)
    {
        auto doc = view._document;
        int page;
        float px, py;
        pointOn(x, y, page, px, py);
        gesturePage = page;
        const p = onPage(x, y, page);
        startX = p.x;
        startY = p.y;
        moved = false;
        gesture = Gesture.none;
        const tool = view._tool;
        if (tool == PdfTool.select && view._onPagePressed && view._onPagePressed(page, px, py, clicks))
            return; // the app's
        auto list = doc.cachedAnnotations(page);
        with (PdfTool) switch (tool)
        {
            case select:
            {
                // A handle of what's selected, to stretch it
                if (auto sel = selectedOn(page))
                {
                    const h = handleAt(*sel, px, py);
                    if (h >= 0)
                    {
                        original = changing = sel.copy();
                        handle = h;
                        gesture = Gesture.resize;
                        break;
                    }
                }
                // An annotation, to select and move -- or, a note or text box clicked twice, to edit
                if (list)
                    if (auto a = list.at(px, py, (ref const PdfAnnotation x) => x.movable))
                    {
                        if (doc.formFocus >= 0)
                            doc.formBlur();
                        view._setSelectedAnnotation(PdfAnnotationRef(page, a.index));
                        original = changing = a.copy();
                        if (clicks == 2 && (a.kind == PdfAnnotationKind.note || a.kind == PdfAnnotationKind.textBox))
                            view.editAnnotation(page, a.copy());
                        else if (!a.marksText)
                            gesture = Gesture.move;
                        break;
                    }
                view._setSelectedAnnotation(PdfAnnotationRef.init);
                // A form field, to fill in
                if (list)
                    if (list.at(px, py, (ref const PdfAnnotation x) => x.kind == PdfAnnotationKind.widget))
                    {
                        doc.formPointer(page, clicks == 2 ? PdfFormPointer.doubleClick : PdfFormPointer.press, px, py, mods);
                        gesture = Gesture.form;
                        break;
                    }
                if (doc.formFocus >= 0)
                    doc.formBlur();
                goto case highlight;
            }
            case highlight, underline, strikeOut:
                // Text, to select
                pressedLink = PdfLink.init;
                pressedOnLink = false;
                if (tool == select)
                    if (auto links = doc.cachedLinks(page))
                        if (auto l = links.at(px, py))
                        {
                            pressedLink = PdfLink(l.areas.dup, l.page, l.y, l.uri);
                            pressedOnLink = true;
                        }
                gesture = Gesture.selectText;
                if (clicks == 2)
                    selectWord(page, px, py);
                else
                {
                    anchor = focus = boundaryAt(page, px, py);
                    view._setHasSelection(false);
                    marksChanged();
                }
                break;
            case region:
                gesture = Gesture.region;
                regionRect = PdfRect(p.x, p.y, 0, 0);
                view._setRegion(PdfRegion.init);
                break;
            case draw:
                gesture = Gesture.ink;
                inkPoints = [p];
                break;
            case note:
            {
                auto a = fresh(PdfAnnotationKind.note);
                a.rect = PdfRect(p.x - 10, p.y - 10, 20, 20);
                place(page, a, true);
                break;
            }
            case signature:
            {
                if (!this.signature.strokes.length)
                    break;
                const r = this.signature.rect;
                const w = 160f, h = r.width > 0 ? r.height * w / r.width : 60;
                auto a = this.signature.fittedTo(PdfRect(p.x - w / 2, p.y - h / 2, w, h));
                a.kind = PdfAnnotationKind.signature;
                a.ours = true;
                place(page, a, false);
                break;
            }
            default:
                // A shape, a line, a text box: dragged out
                gesture = Gesture.shape;
                changing = fresh(kindFor(tool));
                changing.rect = PdfRect(p.x, p.y, 0, 0);
                if (changing.kind == PdfAnnotationKind.line || changing.kind == PdfAnnotationKind.arrow)
                    changing.strokes = [[p, p]];
                break;
        }
        overlayChanged();
    }

    void dragged(float x, float y, bool shift)
    {
        moved = true;
        const p = onPage(x, y, gesturePage);
        final switch (gesture)
        {
            case Gesture.none, Gesture.form:
                break;
            case Gesture.selectText:
                int page;
                float px, py;
                pointOn(x, y, page, px, py);
                focus = boundaryAt(page, px, py);
                view._setHasSelection(anchor != focus);
                marksChanged();
                break;
            case Gesture.move:
                changing = original.movedBy(p.x - startX, p.y - startY);
                break;
            case Gesture.resize:
                changing = stretched(original, handle, p.x, p.y);
                break;
            case Gesture.shape:
                if (changing.kind == PdfAnnotationKind.line || changing.kind == PdfAnnotationKind.arrow)
                {
                    changing.strokes[0][1] = p;
                    changing.rect = changing.bounds;
                }
                else
                    changing.rect = dragRect(p, shift);
                break;
            case Gesture.ink:
                if (distance(inkPoints[$ - 1], p) * view._zoom >= 1.5f)
                    inkPoints ~= p;
                break;
            case Gesture.region:
                regionRect = dragRect(p, false);
                break;
        }
        overlayChanged();
    }

    void released(float x, float y, uint mods)
    {
        // Where it's let go of counts, wherever the last move was
        if (gesture == Gesture.move || gesture == Gesture.resize || gesture == Gesture.shape
            || gesture == Gesture.region || gesture == Gesture.ink)
        {
            const p = onPage(x, y, gesturePage);
            if (p.x != startX || p.y != startY || moved)
                dragged(x, y, false);
        }
        auto doc = view._document;
        const page = gesturePage;
        const g = gesture;
        gesture = Gesture.none;
        final switch (g)
        {
            case Gesture.none:
                break;
            case Gesture.form:
            {
                const p = onPage(x, y, page);
                doc.formPointer(page, PdfFormPointer.release, p.x, p.y, mods);
                break;
            }
            case Gesture.selectText:
                const tool = view._tool;
                if (tool == PdfTool.select)
                {
                    if (!moved && pressedOnLink && !view._hasSelection)
                        follow(pressedLink);
                }
                else if (view._hasSelection)
                    markSelection(kindFor(tool));
                break;
            case Gesture.move, Gesture.resize:
                if (moved)
                    view.changeAnnotation(page, original.index, changing);
                break;
            case Gesture.shape:
            {
                auto a = changing.copy();
                const line = a.kind == PdfAnnotationKind.line || a.kind == PdfAnnotationKind.arrow;
                // Clicked rather than dragged: a shape of a size to start with
                if (line && distance(a.strokes[0][0], a.strokes[0][1]) < 4)
                    a.strokes[0][1] = PdfPoint(a.strokes[0][0].x + 100, a.strokes[0][0].y);
                else if (!line && (a.rect.width < 4 || a.rect.height < 4))
                {
                    const w = a.kind == PdfAnnotationKind.textBox ? 200f : 100f;
                    const h = a.kind == PdfAnnotationKind.textBox ? 40f : 70f;
                    a.rect = PdfRect(startX, startY, w, h);
                }
                a.rect = a.bounds;
                place(page, a, a.kind == PdfAnnotationKind.textBox);
                break;
            }
            case Gesture.ink:
            {
                auto a = fresh(PdfAnnotationKind.ink);
                a.strokes = [inkPoints.dup];
                a.rect = a.bounds;
                inkPoints = null;
                doc.addAnnotation(page, a);
                break;
            }
            case Gesture.region:
                if (regionRect.width >= 4 && regionRect.height >= 4)
                    view._setRegion(PdfRegion(page, regionRect));
                break;
        }
        overlayChanged();
    }

    /// Adds `a` to `page`, selects it, and -- if it's text -- asks for its text. The tool's done.
    void place(int page, PdfAnnotation a, bool edit)
    {
        auto doc = view._document;
        doc.addAnnotation(page, a, (int index) {
            if (index < 0)
                return;
            view._setSelectedAnnotation(PdfAnnotationRef(page, index));
            overlayChanged();
            if (edit)
            {
                auto placed = a.copy();
                placed.index = index;
                view.editAnnotation(page, placed);
            }
        });
        view.setTool(PdfTool.select);
    }

    /// The text selected, marked with annotations of `kind`: one a page.
    void markSelection(PdfAnnotationKind kind)
    {
        if (!view._hasSelection || !ready)
            return;
        auto from = anchor < focus ? anchor : focus, to = anchor < focus ? focus : anchor;
        foreach (p; from.page .. to.page + 1)
        {
            auto text = view._document.cachedText(p);
            if (!text)
                continue;
            const a = p == from.page ? from.index : 0, b = p == to.page ? to.index : text.length;
            auto mark = fresh(kind);
            mark.lines = text.rects(a, b);
            if (!mark.lines.length)
                continue;
            import std.conv : to;
            import std.string : strip;
            mark.text = text.between(a, b).to!string.strip;
            mark.rect = mark.bounds;
            view._document.addAnnotation(p, mark);
        }
        clearSelection();
    }

    void toolChanged()
    {
        gesture = Gesture.none;
        inkPoints = null;
        if (view._tool != PdfTool.select)
            view._setSelectedAnnotation(PdfAnnotationRef.init);
        if (view._tool != PdfTool.region)
            view._setRegion(PdfRegion.init);
        setCursor(view._tool == PdfTool.select ? Cursor.default_ : cursorAt(-1, 0, 0));
        overlayChanged();
    }

    Cursor cursorAt(int page, float px, float py)
    {
        with (PdfTool) switch (view._tool)
        {
            case select:
                break;
            case highlight, underline, strikeOut:
                return Cursor.text;
            default:
                return Cursor.crosshair;
        }
        if (page < 0)
            return Cursor.default_;
        auto doc = view._document;
        if (auto sel = selectedOn(page))
            if (handleAt(*sel, px, py) >= 0)
                return Cursor.crosshair;
        if (auto list = doc.cachedAnnotations(page))
            if (auto a = list.at(px, py))
            {
                if (a.kind == PdfAnnotationKind.widget)
                    return a.fieldType == 6 ? Cursor.text : Cursor.hand; // 6: a text field
                if (!a.marksText)
                    return Cursor.move;
            }
        auto links = doc.cachedLinks(page);
        auto text = doc.cachedText(page);
        return links && links.at(px, py) ? Cursor.hand : text && text.charUnder(px, py) >= 0 ? Cursor.text
               : Cursor.default_;
    }

    /// The document changed: pages go where they went, and what's on them is drawn again.
    void documentEdited(PdfChange change)
    {
        if (!ready)
            return;
        int newIndex(int old)
        {
            foreach (i, f; change.from)
                if (f == old)
                    return cast(int) i;
            return -1;
        }
        Slot[] kept;
        foreach (s; slots)
        {
            const j = newIndex(s.page);
            if (j < 0)
            {
                if (holder)
                    tvg_scene_remove(holder, s.scene);
                forget(s);
                continue;
            }
            s.page = j;
            // Asked for again, of the page as it is now
            if (s.annotationsRequest) { s.annotationsRequest.cancel(); s.annotationsRequest = null; }
            if (s.previewRequest) { s.previewRequest.cancel(); s.previewRequest = null; }
            if (s.textRequest) { s.textRequest.cancel(); s.textRequest = null; }
            if (s.linksRequest) { s.linksRequest.cancel(); s.linksRequest = null; }
            dropWaiting(s, null);
            kept ~= s;
        }
        slots = kept;
        const sel = view._selectedAnnotation;
        if (sel.page >= 0)
        {
            const j = newIndex(sel.page);
            view._setSelectedAnnotation(j < 0 ? PdfAnnotationRef.init : PdfAnnotationRef(j, sel.index));
        }
        if (view._region.page >= 0)
            view._setRegion(PdfRegion.init);
        anchor = focus = Boundary.init;
        view._setHasSelection(false);
        if (query.length)
        {
            import std.conv : to;
            search(query.to!string, matchCase);
        }
        count = view._document.pageCount;
        if (view._currentPage >= count)
            view._setCurrentPage(count - 1);
        applyFit();
        relayout();
        overlayChanged();
        requestUpdate();
    }

    // What's drawn over the pages: what's being dragged out, what's selected

    void overlayChanged()
    {
        overlayDirty = true;
        requestUpdate();
        invalidate();
    }

    void buildOverlay()
    {
        overlayDirty = false;
        OverlayItem[] items;
        enum PdfColour accent = PdfColour(53, 132, 228);
        PdfPathOp mv(PdfPoint p) { return PdfPathOp(PdfPathOp.Kind.moveTo, [p, PdfPoint.init, PdfPoint.init]); }
        PdfPathOp ln(PdfPoint p) { return PdfPathOp(PdfPathOp.Kind.lineTo, [p, PdfPoint.init, PdfPoint.init]); }
        PdfPathOp[] box(PdfRect r)
        {
            return [mv(PdfPoint(r.x, r.y)), ln(PdfPoint(r.right, r.y)), ln(PdfPoint(r.right, r.bottom)),
                    ln(PdfPoint(r.x, r.bottom)), PdfPathOp(PdfPathOp.Kind.close)];
        }
        void drawn(int page, const ref PdfAnnotation a)
        {
            // How it'll look: its outline, its strokes
            if (isShape(a.kind))
                foreach (sh; mayfair.pdf.annotation.shapePath(a))
                    items ~= OverlayItem(page, sh.ops, a.colour,
                                         sh.fillWithColour ? a.colour : sh.filled ? a.fill : PdfColour(0, 0, 0, 0),
                                         a.lineWidth, true, false);
            else if (a.stroked)
                foreach (stroke; a.strokes)
                {
                    PdfPathOp[] ops;
                    foreach (i, p; stroke)
                        ops ~= i ? ln(p) : mv(p);
                    items ~= OverlayItem(page, ops, a.colour, PdfColour(0, 0, 0, 0), a.lineWidth, true, false);
                }
        }
        const page = gesturePage;
        final switch (gesture)
        {
            case Gesture.none, Gesture.form, Gesture.selectText:
                break;
            case Gesture.move, Gesture.resize:
                if (moved)
                {
                    drawn(page, changing);
                    items ~= OverlayItem(page, box(changing.bounds), accent, PdfColour(0, 0, 0, 0), 1, false, true);
                }
                break;
            case Gesture.shape:
                if (changing.kind == PdfAnnotationKind.textBox)
                    items ~= OverlayItem(page, box(changing.rect), changing.colour, PdfColour(0, 0, 0, 0), 1, false, true);
                else
                    drawn(page, changing);
                break;
            case Gesture.ink:
            {
                PdfPathOp[] ops;
                foreach (i, p; inkPoints)
                    ops ~= i ? ln(p) : mv(p);
                const st = view._markupStyle;
                items ~= OverlayItem(page, ops, st.colour, PdfColour(0, 0, 0, 0), st.lineWidth, true, false);
                break;
            }
            case Gesture.region:
                items ~= OverlayItem(page, box(regionRect), accent, PdfColour(53, 132, 228, 30), 1, false, true);
                break;
        }
        // The region dragged out, once it is
        const region = view._region;
        if (gesture != Gesture.region && region.page >= 0)
            items ~= OverlayItem(region.page, box(region.rect), accent, PdfColour(53, 132, 228, 30), 1, false, true);
        // What's selected, if it's not being dragged: a frame, and its handles
        const sel = view._selectedAnnotation;
        if (sel.page >= 0 && !((gesture == Gesture.move || gesture == Gesture.resize) && moved))
            if (auto a = selectedOn(sel.page))
            {
                auto r = a.bounds;
                r = PdfRect(r.x - 2, r.y - 2, r.width + 4, r.height + 4);
                items ~= OverlayItem(sel.page, box(r), accent, PdfColour(0, 0, 0, 0), 1, false, true);
                auto handles = handlesOf(*a);
                if (handles.length)
                {
                    OverlayItem h;
                    h.page = sel.page;
                    h.handles = handles;
                    h.stroke = accent;
                    h.fill = PdfColour(255, 255, 255);
                    h.width = 1;
                    items ~= h;
                }
            }
        overlayItems = items;
        size_t dashed;
        foreach (item; items)
            if (item.dashed)
                dashed++;
        if (overlay)
        {
            while (solidShapes.length < items.length - dashed)
            {
                auto shape = tvg_shape_new();
                tvg_scene_add(overlay, shape);
                solidShapes ~= shape;
            }
            while (dashedShapes.length < dashed)
            {
                auto shape = tvg_shape_new();
                static immutable float[2] dash = [4, 3];
                tvg_shape_set_stroke_dash(shape, dash.ptr, 2, 0);
                tvg_scene_add(overlay, shape);
                dashedShapes ~= shape;
            }
        }
        invalidate();
    }

    /// Puts what's drawn over the pages where they are now.
    void placeOverlay() nothrow @nogc
    {
        if (!overlay)
            return;
        const z = view._zoom, turns = view._rotation;
        // Clearing a ThorVG shape's dash leaves it taken as dashed (until Mayfair's patch 0007 of it),
        // so dashed items go on shapes that are always dashed, and solid ones on shapes never dashed
        size_t solid, dashed;
        foreach (ref item; overlayItems)
        {
            if (item.page < 0 || item.page >= count)
                continue;
            auto pool = item.dashed ? dashedShapes : solidShapes;
            auto at = item.dashed ? dashed++ : solid++;
            if (at < pool.length)
                drawItem(pool[at], item, z, turns);
        }
        foreach (shape; solidShapes[solid < solidShapes.length ? solid : $ .. $])
            hideShape(shape);
        foreach (shape; dashedShapes[dashed < dashedShapes.length ? dashed : $ .. $])
            hideShape(shape);
    }

    static void hideShape(Tvg_Paint shape) nothrow @nogc
    {
        tvg_shape_reset(shape);
        tvg_shape_set_stroke_width(shape, 0);
        tvg_shape_set_fill_color(shape, 0, 0, 0, 0);
    }

    void drawItem(Tvg_Paint shape, const ref OverlayItem item, float z, int turns) nothrow @nogc
    {
        tvg_shape_reset(shape);
        const page = item.page;
        const size = view._document.pageSize(page);
        void at(PdfPoint p, out float sx, out float sy)
        {
            const t = turn(PdfRect(p.x, p.y, 0, 0), turns, size.width, size.height);
            sx = originX + lefts[page] + t.x * z;
            sy = originY + tops[page] + t.y * z;
        }
        foreach (ref op; item.ops)
        {
            float x1, y1, x2, y2, x3, y3;
            final switch (op.kind)
            {
                case PdfPathOp.Kind.moveTo:
                    at(op.points[0], x1, y1);
                    tvg_shape_move_to(shape, x1, y1);
                    break;
                case PdfPathOp.Kind.lineTo:
                    at(op.points[0], x1, y1);
                    tvg_shape_line_to(shape, x1, y1);
                    break;
                case PdfPathOp.Kind.cubicTo:
                    at(op.points[0], x1, y1);
                    at(op.points[1], x2, y2);
                    at(op.points[2], x3, y3);
                    tvg_shape_cubic_to(shape, x1, y1, x2, y2, x3, y3);
                    break;
                case PdfPathOp.Kind.close:
                    tvg_shape_close(shape);
                    break;
            }
        }
        foreach (h; item.handles)
        {
            float hx, hy;
            at(h, hx, hy);
            tvg_shape_append_rect(shape, hx - 4, hy - 4, 8, 8, 1, 1, true);
        }
        const f = item.fill, c = item.stroke;
        tvg_shape_set_fill_color(shape, f.r, f.g, f.b, f.a);
        tvg_shape_set_stroke_color(shape, c.r, c.g, c.b, c.a);
        tvg_shape_set_stroke_width(shape, item.zoomed ? item.width * z : item.width);
        tvg_shape_set_stroke_cap(shape, TVG_STROKE_CAP_ROUND);
        tvg_shape_set_stroke_join(shape, TVG_STROKE_JOIN_ROUND);
    }

    /// The document's top, in the middle across.
    void scrollToStart()
    {
        const across = contentWidth - viewportWidth;
        scrollWhenLaidOut(across > 0 ? across / 2 : 0, 0);
    }

    static float clampScroll(float v, float max) pure nothrow @nogc
    {
        return v < 0 || max <= 0 ? 0 : v > max ? max : v;
    }

    /// Page `index`'s size, turned, unzoomed.
    PdfSize turnedSize(int index)
    {
        const s = view._document.pageSize(index);
        return view._rotation & 1 ? PdfSize(s.height, s.width) : s;
    }

    void relayout()
    {
        const zoom = view._zoom;
        laidZoom = zoom;
        laidTurns = view._rotation;
        if (!ready)
        {
            count = 0;
            contentWidth = contentHeight = 0;
            YGNodeMarkDirty(node);
            return;
        }
        count = view._document.pageCount;
        tops.length = lefts.length = widths.length = heights.length = rowTops.length = count;
        const two = view._pageLayout == PdfPageLayout.twoPages;
        const perRow = two ? 2 : 1;
        float y = margin, widest = 0;
        float[] rowWidths;
        for (int first = 0; first < count; first += perRow)
        {
            const last = first + perRow > count ? count : first + perRow;
            float rowWidth = 0, rowHeight = 0;
            foreach (i; first .. last)
            {
                const s = turnedSize(i);
                widths[i] = s.width * zoom;
                heights[i] = s.height * zoom;
                rowWidth += widths[i] + (i > first ? gap : 0);
                if (heights[i] > rowHeight)
                    rowHeight = heights[i];
            }
            foreach (i; first .. last)
            {
                rowTops[i] = y;
                tops[i] = y + (rowHeight - heights[i]) / 2;
            }
            rowWidths ~= rowWidth;
            y += rowHeight + gap;
            if (rowWidth > widest)
                widest = rowWidth;
        }
        contentHeight = count ? y - gap + margin : 0;
        contentWidth = widest + 2 * margin;
        if (contentWidth < viewportWidth)
            contentWidth = viewportWidth;
        foreach (r, rowWidth; rowWidths)
        {
            float x = (contentWidth - rowWidth) / 2;
            foreach (i; cast(int) r * perRow .. (cast(int) r * perRow + perRow > count ? count : cast(int) r * perRow + perRow))
            {
                lefts[i] = x;
                x += widths[i] + gap;
            }
        }
        YGNodeMarkDirty(node);
        invalidate();
    }

    /// Which page `x`, `y` in the content is on -- or nearest -- and where on it, in its unturned points.
    void pointOn(float x, float y, out int page, out float px, out float py)
    {
        page = pageAt(y);
        // Two side by side: the left one, if that's nearer
        if (view._pageLayout == PdfPageLayout.twoPages && page % 2 == 1 && x < lefts[page] - gap / 2)
            page--;
        const z = view._zoom, s = view._document.pageSize(page);
        unturn((x - lefts[page]) / z, (y - tops[page]) / z, view._rotation, s.width, s.height, px, py);
    }

    /// The boundary nearest `px`, `py` on `page`: before or after the nearest character.
    Boundary boundaryAt(int page, float px, float py)
    {
        auto text = view._document.cachedText(page);
        if (!text || !text.length)
            return Boundary(page, 0);
        bool after;
        const i = text.charAt(px, py, after);
        return Boundary(page, i < 0 ? 0 : after ? i + 1 : i);
    }

    void selectWord(int page, float px, float py)
    {
        auto text = view._document.cachedText(page);
        if (!text)
            return;
        bool after;
        const i = text.charAt(px, py, after);
        if (i < 0)
            return;
        size_t from, to;
        text.wordAround(i, from, to);
        anchor = Boundary(page, from);
        focus = Boundary(page, to);
        view._setHasSelection(from < to);
        marksChanged();
    }

    void follow(PdfLink link)
    {
        if (link.page >= 0)
            view.goToPage(link.page, link.y);
        else if (link.uri.length)
            view.externalLink(link.uri);
    }

    // A closure of its own for each page, as for tiles
    PdfRequest searchPage(int page, uint gen)
    {
        return view._document.text(page, PdfPriority.background, (PdfPageText t) {
            if (gen == generation)
                searchedPage(page, t);
        });
    }

    void searchedPage(int page, PdfPageText text)
    {
        searched++;
        // Kept in page order, wherever the page's results arrive
        size_t at = matches.length;
        while (at > 0 && matches[at - 1].page > page)
            at--;
        Match[] found;
        foreach (r; text.find(query, matchCase))
            found ~= Match(page, r[0], r[1]);
        if (found.length)
        {
            matches = matches[0 .. at] ~ found ~ matches[at .. $];
            const current = view._currentMatch;
            if (current >= 0 && current >= at)
                view._setCurrentMatch(cast(int) (current + found.length));
            view._setMatchCount(cast(int) matches.length);
            if (view._currentMatch < 0)
            {
                // The first found: pages are searched from the current one on, so it's the next one there is
                view._setCurrentMatch(cast(int) at);
                reveal(matches[at]);
            }
            marksChanged();
        }
        if (searched >= count)
            view._setSearching(false);
    }

    /// Scrolls `m` into view, if it isn't.
    void reveal(Match m)
    {
        auto text = view._document.cachedText(m.page);
        if (!text)
            return;
        PdfRect r;
        foreach (line; text.rects(m.from, m.to))
            r = r.union_(line);
        const s = view._document.pageSize(m.page), z = view._zoom;
        const t = turn(r, view._rotation, s.width, s.height);
        const x = lefts[m.page] + t.x * z, y = tops[m.page] + t.y * z;
        const vp = view.viewportBounds;
        if (y >= vp.minY && y + t.height * z <= vp.maxY && x >= vp.minX && x + t.width * z <= vp.maxX)
            return;
        float sx = vp.minX;
        if (x < vp.minX || x + t.width * z > vp.maxX)
            sx = x - vp.width / 3;
        scrollWhenLaidOut(sx, y - vp.height / 3);
    }

    // Slots

    Slot slotFor(int page)
    {
        foreach (s; slots)
            if (s.page == page)
                return s;
        auto s = new Slot;
        s.page = page;
        s.scene = tvg_scene_new();
        s.shadow = tvg_shape_new();
        tvg_shape_set_fill_color(s.shadow, 0, 0, 0, 40);
        s.frame = tvg_shape_new();
        tvg_shape_set_fill_color(s.frame, 255, 255, 255, 255);
        s.previewHolder = tvg_scene_new();
        s.tiles = tvg_scene_new();
        s.selection = tvg_shape_new();
        tvg_shape_set_fill_color(s.selection, 53, 132, 228, 90);
        s.matches = tvg_shape_new();
        tvg_shape_set_fill_color(s.matches, 255, 214, 0, 110);
        s.current = tvg_shape_new();
        tvg_shape_set_fill_color(s.current, 255, 140, 0, 150);
        foreach (p; [s.shadow, s.frame, s.previewHolder, s.tiles, s.matches, s.current, s.selection])
            tvg_scene_add(s.scene, p);
        tvg_scene_add(holder, s.scene);
        slots ~= s;
        marksFor(s);
        return s;
    }

    /// Asks for what slot `s` needs: its preview, its text and links, and -- if it's in view -- its tiles.
    void want(Slot s, bool visible, Bounds vp)
    {
        auto doc = view._document;
        const page = s.page;
        const version_ = doc.pageVersion(page);
        if ((!s.previewBitmap || s.previewVersion != version_) && !s.previewRequest)
        {
            // An old one stays until it's replaced
            if (auto b = doc.cachedPreview(page))
                showPreview(s, b, version_);
            else
                s.previewRequest = doc.preview(page, visible ? PdfPriority.visible : PdfPriority.near,
                                               (PdfBitmap b) { showPreview(s, b, version_); });
        }
        if (!doc.cachedAnnotations(page) && !s.annotationsRequest)
            s.annotationsRequest = doc.annotations(page, PdfPriority.near, (PdfAnnotations a) { overlayChanged(); });
        if (!doc.cachedText(page) && !s.textRequest)
            s.textRequest = doc.text(page, PdfPriority.near, (PdfPageText t) { marksFor(s); invalidate(); });
        if (!doc.cachedLinks(page) && !s.linksRequest)
            s.linksRequest = doc.links(page, PdfPriority.near, (PdfLinks l) {});
        if (visible)
            wantTiles(s, vp);
        else
            dropWaiting(s, null);
    }

    void showPreview(Slot s, PdfBitmap b, uint version_)
    {
        s.previewRequest = null;
        if (!slotAlive(s))
            return;
        if (s.preview)
            tvg_scene_remove(s.previewHolder, s.preview);
        s.previewBitmap = b;
        s.previewVersion = version_;
        s.preview = picture(b);
        tvg_scene_add(s.previewHolder, s.preview);
        invalidate();
    }

    /// Asks for the tiles of slot `s`'s page that are in view, at the scale the screen wants, and
    /// drops what's waiting that isn't.
    void wantTiles(Slot s, Bounds vp)
    {
        const page = s.page, z = view._zoom;
        const pixels = z * (view.scene ? view.scene.scale : 1);
        const scale = round(pixels * 64) / 64; // a little coarser, so a nudge to the zoom doesn't render it all again
        const turns = view._rotation;
        const version_ = view._document.pageVersion(page);
        const size = turnedSize(page);
        const span = tileSize / scale; // a tile's side, in points
        // What's in view of the page, in its turned points
        const vx0 = ((vp.minX > lefts[page] ? vp.minX : lefts[page]) - lefts[page]) / z;
        const vy0 = ((vp.minY > tops[page] ? vp.minY : tops[page]) - tops[page]) / z;
        const vx1 = ((vp.maxX < lefts[page] + widths[page] ? vp.maxX : lefts[page] + widths[page]) - lefts[page]) / z;
        const vy1 = ((vp.maxY < tops[page] + heights[page] ? vp.maxY : tops[page] + heights[page]) - tops[page]) / z;
        if (vx1 <= vx0 || vy1 <= vy0)
            return;
        bool[TileKey] wanted;
        bool covered = true;
        foreach (row; cast(int) floor(vy0 / span) .. cast(int) ceil(vy1 / span))
            foreach (column; cast(int) floor(vx0 / span) .. cast(int) ceil(vx1 / span))
            {
                const key = TileKey(scale, turns, column, row, version_);
                wanted[key] = true;
                bool have;
                foreach (t; s.tileList)
                    if (t.key == key)
                    {
                        t.used = frame;
                        have = true;
                    }
                if (have)
                    continue;
                covered = false;
                if (key in s.waiting)
                    continue;
                const x = column * span, y = row * span;
                const region = PdfRect(x, y, x + span > size.width ? size.width - x : span,
                                       y + span > size.height ? size.height - y : span);
                if (region.empty)
                    continue;
                s.waiting[key] = askTile(s, key, region);
            }
        dropWaiting(s, wanted);
        // Once what's in view is all there at this scale, what's left of any other can go
        if (covered)
        {
            Tile[] kept;
            foreach (t; s.tileList)
            {
                if (t.key.scale == scale && t.key.turns == turns && t.key.version_ == version_)
                    kept ~= t;
                else
                    tvg_scene_remove(s.tiles, t.picture);
            }
            s.tileList = kept;
        }
    }

    // A closure of its own for each tile: one made in wantTiles' loop would share the loop's key
    PdfRequest askTile(Slot s, TileKey key, PdfRect region)
    {
        return view._document.render(s.page, region, key.scale, key.turns, PdfPriority.visible,
                                     (PdfBitmap b) { tileArrived(s, key, b); });
    }

    void tileArrived(Slot s, TileKey key, PdfBitmap b)
    {
        s.waiting.remove(key);
        if (!slotAlive(s))
            return;
        auto t = new Tile;
        t.key = key;
        t.region = b.region;
        t.width = b.width;
        t.height = b.height;
        t.used = frame;
        t.picture = picture(b);
        tvg_scene_add(s.tiles, t.picture);
        // ThorVG has its own copy, and nothing else has this one: a megabyte a tile, not left for
        // the collector, which would hold on to the room for it
        import core.memory : GC;
        GC.free(b.pixels.ptr);
        b.pixels = null;
        s.tileList ~= t;
        requestUpdate(); // which drops what this one replaces, once its page is covered
        invalidate();
    }

    /// Cancels what's waiting for slot `s` that isn't `wanted`: everything, if that's null.
    void dropWaiting(Slot s, bool[TileKey] wanted)
    {
        TileKey[] gone;
        foreach (key, request; s.waiting)
            if (!wanted || key !in wanted)
            {
                request.cancel();
                gone ~= key;
            }
        foreach (key; gone)
            s.waiting.remove(key);
    }

    /// Keeps the tiles to maxTiles, dropping those wanted longest ago.
    void trimTiles()
    {
        size_t total;
        foreach (s; slots)
            total += s.tileList.length;
        while (total > maxTiles)
        {
            Slot from;
            size_t oldest;
            ulong when = ulong.max;
            foreach (s; slots)
                foreach (i, t; s.tileList)
                    if (t.used < when)
                    {
                        when = t.used;
                        from = s;
                        oldest = i;
                    }
            if (!from || when == frame)
                break; // everything left is in view
            tvg_scene_remove(from.tiles, from.tileList[oldest].picture);
            from.tileList = from.tileList[0 .. oldest] ~ from.tileList[oldest + 1 .. $];
            total--;
        }
    }

    bool slotAlive(Slot s)
    {
        foreach (o; slots)
            if (o is s)
                return holder !is null;
        return false;
    }

    void forget(Slot s)
    {
        if (s.previewRequest) s.previewRequest.cancel();
        if (s.textRequest) s.textRequest.cancel();
        if (s.linksRequest) s.linksRequest.cancel();
        if (s.annotationsRequest) s.annotationsRequest.cancel();
        dropWaiting(s, null);
    }

    void dropSlots()
    {
        foreach (s; slots)
        {
            if (holder)
                tvg_scene_remove(holder, s.scene);
            forget(s);
        }
        slots = null;
    }

    static Tvg_Paint picture(PdfBitmap b)
    {
        auto p = tvg_picture_new();
        tvg_picture_load_raw(p, b.pixels.ptr, b.width, b.height, TVG_COLORSPACE_ARGB8888, true);
        tvg_picture_set_filter(p, TVG_FILTER_METHOD_BILINEAR);
        return p;
    }

    // Highlights: the selection's, and the search's

    void marksChanged()
    {
        foreach (s; slots)
            marksFor(s);
        invalidate();
    }

    void marksFor(Slot s)
    {
        s.selectionRects = s.matchRects = s.currentRects = null;
        auto text = ready ? view._document.cachedText(s.page) : null;
        if (!text)
            return;
        if (view._hasSelection)
        {
            auto from = anchor < focus ? anchor : focus, to = anchor < focus ? focus : anchor;
            if (s.page >= from.page && s.page <= to.page)
                s.selectionRects = text.rects(s.page == from.page ? from.index : 0,
                                              s.page == to.page ? to.index : text.length);
        }
        foreach (i, m; matches)
            if (m.page == s.page)
            {
                if (i == view._currentMatch)
                    s.currentRects ~= text.rects(m.from, m.to);
                else
                    s.matchRects ~= text.rects(m.from, m.to);
            }
    }

    /// Puts slot `s`'s paints where its page is now.
    void place(Slot s) nothrow @nogc
    {
        const i = s.page;
        if (i >= count)
            return;
        const px = originX + lefts[i], py = originY + tops[i], w = widths[i], h = heights[i], z = view._zoom;
        const turns = view._rotation;
        const size = view._document.pageSize(i);

        tvg_shape_reset(s.shadow);
        tvg_shape_append_rect(s.shadow, px - 1, py - 1, w + 2, h + 3, 2, 2, true);
        tvg_shape_reset(s.frame);
        tvg_shape_append_rect(s.frame, px, py, w, h, 0, 0, true);

        if (s.preview && s.previewBitmap)
        {
            // The preview's upright: turned here, with the page
            const k = z / s.previewBitmap.scale;
            Tvg_Matrix m;
            final switch (turns & 3)
            {
                case 0: m = Tvg_Matrix(k, 0, px, 0, k, py, 0, 0, 1); break;
                case 1: m = Tvg_Matrix(0, -k, px + size.height * z, k, 0, py, 0, 0, 1); break;
                case 2: m = Tvg_Matrix(-k, 0, px + size.width * z, 0, -k, py + size.height * z, 0, 0, 1); break;
                case 3: m = Tvg_Matrix(0, k, px, -k, 0, py + size.width * z, 0, 0, 1); break;
            }
            tvg_paint_set_transform(s.preview, &m);
        }
        foreach (t; s.tileList)
        {
            auto m = Tvg_Matrix(t.region.width * z / t.width, 0, px + t.region.x * z,
                                0, t.region.height * z / t.height, py + t.region.y * z, 0, 0, 1);
            tvg_paint_set_transform(t.picture, &m);
        }
        mark(s.selection, s.selectionRects, px, py, z, turns, size);
        mark(s.matches, s.matchRects, px, py, z, turns, size);
        mark(s.current, s.currentRects, px, py, z, turns, size);
    }

    static void mark(Tvg_Paint shape, const PdfRect[] rects, float px, float py, float z, int turns, PdfSize size) nothrow @nogc
    {
        tvg_shape_reset(shape);
        foreach (r; rects)
        {
            const t = turn(r, turns, size.width, size.height);
            tvg_shape_append_rect(shape, px + t.x * z, py + t.y * z, t.width * z, t.height * z, 1, 1, true);
        }
    }
}

extern (C) YGSize measurePages(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                               float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(PdfPages) YGNodeGetContext(node);
    return self ? YGSize(self.contentWidth, self.contentHeight) : YGSize(0, 0);
}
