module mayfair.pdf.view;

import std.math : abs, ceil, floor, pow, round;
import mayfair.clipboard : Clipboard;
import mayfair.accessibility : AccessibleRole;
import mayfair.layout;
import mayfair.pdf.document;
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

    /// Selects every page's text, or none.
    void selectAll() { pages.selectAll(); }
    void clearSelection() { pages.clearSelection(); } /// ditto

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
        if (event.type == KeyEventType.pressed && pages.ready)
        {
            pages.atStart = false;
            const ctrl = event.control || event.meta;
            const c = event.code;
            if (ctrl && c == KeyCode.c)
                copySelection();
            else if (ctrl && c == KeyCode.a)
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

/// What a tile is of: a part of a page, rendered at a scale, turned.
struct TileKey
{
    float scale;
    int turns;
    int column, row;
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
    PdfRequest previewRequest, textRequest, linksRequest;
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
        foreach (i; 0 .. count)
        {
            const s = turnedSize(i);
            if (s.width > widest)
                widest = s.width;
        }
        float zoom = (viewportWidth - 2 * margin) / widest;
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
            if (tops[mid] - gap / 2 <= y)
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
        requestUpdate();
    }

    override void unmounted()
    {
        // The holder took every slot's paints with it
        holder = null;
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
        const first = pageAt(vp.minY - vp.height), last = pageAt(vp.maxY + vp.height);
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
                int page;
                float px, py;
                pointOn(event.x, event.y, page, px, py);
                pressedLink = PdfLink.init;
                pressedOnLink = false;
                if (auto links = view._document.cachedLinks(page))
                    if (auto l = links.at(px, py))
                    {
                        pressedLink = PdfLink(l.areas.dup, l.page, l.y, l.uri);
                        pressedOnLink = true;
                    }
                dragging = true;
                moved = false;
                if (event.clickCount == 2)
                    selectWord(page, px, py);
                else
                {
                    anchor = focus = boundaryAt(page, px, py);
                    view._setHasSelection(false);
                    marksChanged();
                }
                event.consume();
                break;
            case MouseEventType.dragged:
                if (!dragging)
                    return;
                moved = true;
                int page;
                float px, py;
                pointOn(event.x, event.y, page, px, py);
                focus = boundaryAt(page, px, py);
                view._setHasSelection(anchor != focus);
                marksChanged();
                event.consume();
                break;
            case MouseEventType.released:
                if (!dragging)
                    return;
                dragging = false;
                if (!moved && pressedOnLink && !view._hasSelection)
                    follow(pressedLink);
                event.consume();
                break;
            case MouseEventType.moved:
                int page;
                float px, py;
                pointOn(event.x, event.y, page, px, py);
                auto doc = view._document;
                auto links = doc.cachedLinks(page);
                auto text = doc.cachedText(page);
                setCursor(links && links.at(px, py) ? Cursor.hand : text && text.charUnder(px, py) >= 0 ? Cursor.text
                          : Cursor.default_);
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
    bool dragging, moved, pressedOnLink;
    PdfLink pressedLink;
    uint copyGeneration;

    // Searching
    dstring query;
    bool matchCase;
    Match[] matches;
    int searched;
    uint generation;
    PdfRequest[] searchRequests;

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
        tops.length = lefts.length = widths.length = heights.length = count;
        float y = margin, widest = 0;
        foreach (i; 0 .. count)
        {
            const s = turnedSize(i);
            widths[i] = s.width * zoom;
            heights[i] = s.height * zoom;
            tops[i] = y;
            y += heights[i] + gap;
            if (widths[i] > widest)
                widest = widths[i];
        }
        contentHeight = count ? y - gap + margin : 0;
        contentWidth = widest + 2 * margin;
        if (contentWidth < viewportWidth)
            contentWidth = viewportWidth;
        foreach (i; 0 .. count)
            lefts[i] = (contentWidth - widths[i]) / 2;
        YGNodeMarkDirty(node);
        invalidate();
    }

    /// Which page `x`, `y` in the content is on -- or nearest -- and where on it, in its unturned points.
    void pointOn(float x, float y, out int page, out float px, out float py)
    {
        page = pageAt(y);
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
        if (!s.previewBitmap && !s.previewRequest)
        {
            if (auto b = doc.cachedPreview(page))
                showPreview(s, b);
            else
                s.previewRequest = doc.preview(page, visible ? PdfPriority.visible : PdfPriority.near,
                                               (PdfBitmap b) { showPreview(s, b); });
        }
        if (!doc.cachedText(page) && !s.textRequest)
            s.textRequest = doc.text(page, PdfPriority.near, (PdfPageText t) { marksFor(s); invalidate(); });
        if (!doc.cachedLinks(page) && !s.linksRequest)
            s.linksRequest = doc.links(page, PdfPriority.near, (PdfLinks l) {});
        if (visible)
            wantTiles(s, vp);
        else
            dropWaiting(s, null);
    }

    void showPreview(Slot s, PdfBitmap b)
    {
        if (!slotAlive(s))
            return;
        s.previewBitmap = b;
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
                const key = TileKey(scale, turns, column, row);
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
                if (t.key.scale == scale && t.key.turns == turns)
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
