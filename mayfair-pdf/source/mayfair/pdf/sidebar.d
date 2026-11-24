module mayfair.pdf.sidebar;

import std.conv : to;
import mayfair.accessibility : AccessibleRole;
import mayfair.layout;
import mayfair.pdf.document;
import mayfair.pdf.thread : PdfPriority;
import mayfair.pdf.types;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.widgets;

/*
    A document's pages, small, one under another, each with its number: a reader's sidebar.

        auto thumbnails = new PdfThumbnails(doc);
        thumbnails.onPageChosen((page) { view.goToPage(page); });
        view.currentPageProperty.addListener((int was, int now) { thumbnails.setCurrentPage(now); });

    Each is drawn from the document's preview of its page, asked for as it scrolls into view, and
    again when the page changes. The current page is marked, and kept in view.

    Pages are selected by clicking them -- with Ctrl, one more or less; with Shift, all from the
    last -- for the app to act on (selectedPages): to turn, delete or export. Dragged, they're moved
    (onPagesMoved); Delete asks for them to be deleted (onDeletePages); a right click asks for a
    menu (onMenu).
*/
class PdfThumbnails : ScrollPane
{
public:
    this(PdfDocument document = null)
    {
        super(null);
        list = new Column().padding(12).spacing(10).alignment(Pos.topCentre);
        setContent(list);
        setFitToWidth(true);
        styleClass.add("pdf-thumbnails");
        vvalueProperty.addListener((float was, float now) { requestUpdate(); });
        if (document)
            setDocument(document);
    }

    /// The document whose pages it shows.
    mixin(declareProperty!(PdfDocument, "document", "null", q{ rebuild(); }));

    /// The page marked as the one being read, from 0.
    mixin(declareProperty!(int, "currentPage", "0", q{ currentChanged(); }));

    /// How wide each page is, in points.
    mixin(declareProperty!(float, "thumbnailWidth", "110", q{ rebuild(); }));

    /// Called when a page is clicked.
    PdfThumbnails onPageChosen(void delegate(int page) handler) { _onPageChosen = handler; return this; }

    /// The pages selected, in order: at least the current one.
    mixin(declareReadOnlyProperty!(int[], "selectedPages", "null"));

    /// Selects `pages`.
    void selectPages(int[] pages)
    {
        import std.algorithm : sort, uniq;
        import std.array : array;
        _setSelectedPages(pages.dup.sort.uniq.array);
        markCurrent();
    }

    /// Called when pages are dragged to before page `before` (pageCount for the end).
    PdfThumbnails onPagesMoved(void delegate(int[] pages, int before) handler) { _onPagesMoved = handler; return this; }

    /// Called when Delete is pressed, with the pages selected.
    PdfThumbnails onDeletePages(void delegate(int[] pages) handler) { _onDeletePages = handler; return this; }

    /// Called when a page is right-clicked -- it's selected first -- with where, in the window.
    PdfThumbnails onMenu(void delegate(int page, float sceneX, float sceneY) handler) { _onMenu = handler; return this; }

protected:
    override void handleKey(ref KeyEvent event)
    {
        if (event.type == KeyEventType.pressed && (event.code == KeyCode.delete_ || event.code == KeyCode.backspace)
            && _selectedPages.length && _onDeletePages)
        {
            _onDeletePages(_selectedPages.dup);
            event.consume();
            return;
        }
        super.handleKey(event);
    }

    override void update()
    {
        super.update();
        if (!_document || _document.status != PdfStatus.ready)
            return;
        // Previews for what's in view, and a screenful either side
        const vp = viewportBounds;
        foreach (i, item; items)
        {
            const top = YGNodeLayoutGetTop(item.node), height = YGNodeLayoutGetHeight(item.node);
            if (!(height > 0))
            {
                requestUpdate(); // not laid out yet: once it is, next frame
                return;
            }
            const inView = top + height >= vp.minY && top <= vp.maxY;
            const near = top + height >= vp.minY - vp.height && top <= vp.maxY + vp.height;
            const far = top + height < vp.minY - 3 * vp.height || top > vp.maxY + 3 * vp.height;
            if (near)
                item.picture.want(inView ? PdfPriority.near : PdfPriority.background);
            else if (far)
                item.picture.forget(); // its picture let go of, as a long document's pages go by
        }
    }

private:
    Column list;
    Thumbnail[] items;
    void delegate(int) _onPageChosen;
    void delegate(int[], int) _onPagesMoved;
    void delegate(int[]) _onDeletePages;
    void delegate(int, float, float) _onMenu;
    PdfDocument watching;
    int rangeFrom = -1;     // where Shift selects from
    int dragTarget = -1;    // where pages being dragged would go

    /// The document changed: pages moved, or look different.
    void edited(PdfChange change)
    {
        bool same = change.from.length == items.length;
        foreach (i, f; change.from)
            if (f != i)
                same = false;
        if (!same)
        {
            // Which page is which changed: the list again, what was selected where it went
            int[] selected;
            foreach (i, f; change.from)
                foreach (old; _selectedPages)
                    if (f == old && f >= 0)
                        selected ~= cast(int) i;
            const keep = vvalue;
            rebuild();
            _setSelectedPages(selected);
            if (selected.length)
                markCurrent();
            else
                currentChanged();
            setVvalue(keep);
            return;
        }
        foreach (i, r; change.redrawn)
            if (r && i < items.length)
                items[i].picture.refresh();
        requestUpdate();
    }

    void rebuild()
    {
        if (watching && watching !is _document)
            watching.removeChangeListener(&edited);
        if (_document && watching !is _document)
            _document.addChangeListener(&edited);
        foreach (item; items)
            item.picture.drop();
        while (list.children.length)
            list.remove(cast(Widget) list.children[0]);
        items = null;
        watching = _document;
        if (!_document)
            return;
        if (_document.status != PdfStatus.ready)
        {
            auto doc = _document;
            doc.statusProperty.addListener((PdfStatus was, PdfStatus now) {
                if (doc is watching && now == PdfStatus.ready)
                    rebuild();
            });
            return;
        }
        foreach (i; 0 .. _document.pageCount)
        {
            auto item = new Thumbnail(this, cast(int) i);
            items ~= item;
            list.add(item);
        }
        currentChanged();
        requestUpdate();
    }

    /// The page being read changed: one page selected follows it; more stay as they were chosen.
    void currentChanged()
    {
        if (_selectedPages.length <= 1 && _currentPage >= 0 && _currentPage < items.length)
            _setSelectedPages([_currentPage]);
        markCurrent();
    }

    void markCurrent()
    {
        import std.algorithm : canFind;
        foreach (i, item; items)
            item.setStyle(_selectedPages.canFind(cast(int) i)
                          ? "background-colour: var(--row-selected); background-radius: 6;" : "");
        if (_currentPage >= 0 && _currentPage < items.length)
        {
            // Into view, if it's out of it
            auto item = items[_currentPage];
            const top = YGNodeLayoutGetTop(item.node), height = YGNodeLayoutGetHeight(item.node);
            const vp = viewportBounds;
            if (height > 0 && (top < vp.minY || top + height > vp.maxY))
                scrollTo(0, top - vp.height / 3);
        }
    }

    void chose(int page)
    {
        setCurrentPage(page);
        if (_onPageChosen)
            _onPageChosen(page);
    }

    /// A thumbnail pressed: selected, with Ctrl or Shift as they say.
    void pressedOn(int page, bool ctrl, bool shift, bool secondary)
    {
        import std.algorithm : canFind, remove;
        requestFocus();
        int[] selected = _selectedPages.dup;
        if (secondary)
        {
            if (!selected.canFind(page))
                selected = [page];
        }
        else if (shift && rangeFrom >= 0)
        {
            selected = null;
            foreach (p; (rangeFrom < page ? rangeFrom : page) .. (rangeFrom < page ? page : rangeFrom) + 1)
                selected ~= p;
        }
        else if (ctrl)
        {
            if (selected.canFind(page))
            {
                if (selected.length > 1)
                    selected = selected.remove!(p => p == page);
            }
            else
                selected ~= page;
            rangeFrom = page;
        }
        else
        {
            if (!selected.canFind(page)) // a press on one of several selected keeps them, to drag
                selected = [page];
            rangeFrom = page;
        }
        selectPages(selected);
    }

    /// Released without dragging: just this one, unless Ctrl or Shift chose more.
    void clickedOn(int page, bool ctrl, bool shift)
    {
        if (!ctrl && !shift)
        {
            _setSelectedPages([page]);
            chose(page);
        }
        markCurrent();
    }

    /// Pages dragged, the pointer at `sceneY`: the gap they'd go into, marked.
    void draggedTo(float sceneY)
    {
        int target = cast(int) items.length;
        foreach (i, item; items)
        {
            const b = item.boundsInScene;
            if (sceneY < b.minY + b.height / 2)
            {
                target = cast(int) i;
                break;
            }
        }
        if (target == dragTarget)
            return;
        dragTarget = target;
        foreach (i, item; items)
        {
            item.marker(i == target ? 1 : i + 1 == target && target == items.length ? 2 : 0);
        }
        // Near the top or bottom: scrolled
        const vp = boundsInScene;
        if (sceneY < vp.minY + 24)
            setVvalue(vvalue - 0.02f < 0 ? 0 : vvalue - 0.02f);
        else if (sceneY > vp.maxY - 24)
            setVvalue(vvalue + 0.02f > 1 ? 1 : vvalue + 0.02f);
    }

    void dropped()
    {
        foreach (item; items)
            item.marker(0);
        const target = dragTarget;
        dragTarget = -1;
        if (target < 0 || !_onPagesMoved || !_selectedPages.length)
            return;
        // Nowhere, if they'd go where they are
        bool still = true;
        foreach (k, p; _selectedPages)
            if (p != _selectedPages[0] + k)
                still = false;
        if (still && target >= _selectedPages[0] && target <= _selectedPages[$ - 1] + 1)
            return;
        _onPagesMoved(_selectedPages.dup, target);
    }

    void menuAt(int page, float x, float y)
    {
        if (_onMenu)
            _onMenu(page, x, y);
    }
}

/// A page in the list, and its number.
final class Thumbnail : Column
{
    PdfThumbnails owner;
    int page;
    ThumbnailPicture picture;

    this(PdfThumbnails owner, int page)
    {
        this.owner = owner;
        this.page = page;
        setSpacing(4);
        setPadding(Insets(6));
        setAlignment(Pos.topCentre);
        setFillWidth(false);
        picture = new ThumbnailPicture(owner, page);
        before = new Row().prefHeight(3).prefWidth(owner._thumbnailWidth);
        after = new Row().prefHeight(3).prefWidth(owner._thumbnailWidth);
        add(before).add(picture).add(new Label((page + 1).to!string).style("font-size: 12px;")).add(after);
        setAccessibleRole(AccessibleRole.button);
        setAccessibleText("Page " ~ (page + 1).to!string);
        setCursor(Cursor.hand);
    }

    /// Marks where dragged pages would go: 1 before it, 2 after it, 0 neither.
    void marker(int where)
    {
        enum on = "background-colour: var(--accent); background-radius: 2;";
        before.setStyle(where == 1 ? on : "");
        after.setStyle(where == 2 ? on : "");
    }

protected:
    override void handleMouse(ref MouseEvent event)
    {
        const ctrl = event.control || event.meta;
        switch (event.type)
        {
            case MouseEventType.pressed:
                pressedAt = event.sceneY;
                dragging = false;
                owner.pressedOn(page, ctrl, event.shift, event.button == MouseButton.secondary);
                if (event.button == MouseButton.secondary)
                    owner.menuAt(page, event.sceneX, event.sceneY);
                event.consume();
                break;
            case MouseEventType.dragged:
                if (event.button != MouseButton.primary && !dragging && (event.sceneY - pressedAt) * (event.sceneY - pressedAt) < 36)
                    return;
                dragging = true;
                owner.draggedTo(event.sceneY);
                event.consume();
                break;
            case MouseEventType.released:
                if (event.button == MouseButton.secondary)
                    return;
                if (dragging)
                    owner.dropped();
                else
                    owner.clickedOn(page, ctrl, event.shift);
                dragging = false;
                event.consume();
                break;
            default:
                break;
        }
    }

private:
    Row before, after;
    float pressedAt = 0;
    bool dragging;
}

/// The page itself, small: white until its preview's been rendered.
final class ThumbnailPicture : Widget
{
    this(PdfThumbnails owner, int page)
    {
        this.owner = owner;
        this.page = page;
        const s = owner._document.pageSize(page);
        const w = owner._thumbnailWidth;
        setPrefWidth(w);
        setPrefHeight(s.width > 0 ? w * s.height / s.width : w * 1.41f);
    }

    /// Asks for the preview, if it hasn't been, or the page has changed since.
    void want(PdfPriority priority)
    {
        auto doc = owner._document;
        const now = doc.pageVersion(page);
        if ((bitmap && version_ == now) || request)
            return;
        if (auto b = doc.cachedPreview(page))
        {
            show(b, now);
            return;
        }
        request = doc.preview(page, priority, (PdfBitmap b) { request = null; show(b, now); });
    }

    /// The page changed: its preview's asked for again, the old one shown till it comes.
    void refresh()
    {
        drop();
        owner.requestUpdate();
    }

    /// Lets go of what's waiting.
    void drop()
    {
        if (request)
            request.cancel();
        request = null;
    }

    /// Lets go of its picture, and what's waiting: it's asked for again, if it comes back into view.
    void forget()
    {
        drop();
        if (picture && holder)
            tvg_scene_remove(holder, picture);
        picture = null;
        bitmap = null;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        holder = addPaint(tvg_scene_new());
        frame = tvg_shape_new();
        tvg_shape_set_fill_color(frame, 255, 255, 255, 255);
        tvg_shape_set_stroke_width(frame, 1);
        tvg_shape_set_stroke_color(frame, 0, 0, 0, 50);
        tvg_scene_add(holder, frame);
        picture = null;
        if (bitmap)
            addPicture();
    }

    override void unmounted()
    {
        holder = frame = picture = null;
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        if (!frame)
            return;
        tvg_shape_reset(frame);
        tvg_shape_append_rect(frame, x, y, w, h, 0, 0, true);
        if (picture && bitmap)
        {
            auto m = Tvg_Matrix(w / bitmap.width, 0, x, 0, h / bitmap.height, y, 0, 0, 1);
            tvg_paint_set_transform(picture, &m);
        }
    }

private:
    PdfThumbnails owner;
    int page;
    PdfBitmap bitmap;
    uint version_;
    PdfRequest request;
    Tvg_Paint holder, frame, picture;

    void show(PdfBitmap b, uint v)
    {
        if (picture && holder)
            tvg_scene_remove(holder, picture);
        picture = null;
        bitmap = b;
        version_ = v;
        if (holder)
            addPicture();
    }

    void addPicture() nothrow
    {
        picture = tvg_picture_new();
        tvg_picture_load_raw(picture, bitmap.pixels.ptr, bitmap.width, bitmap.height, TVG_COLORSPACE_ARGB8888, true);
        tvg_scene_add(holder, picture);
        invalidate();
    }
}

/*
    A document's outline -- its table of contents -- as a list of what's in it, those under each
    entry indented under it: a reader's other sidebar. Empty for a document with none.

        auto contents = new PdfOutline(doc);
        contents.onItemChosen((item) { view.goToPage(item.page, item.y); });
*/
class PdfOutline : ScrollPane
{
public:
    this(PdfDocument document = null)
    {
        super(null);
        list = new Column().padding(Insets(8, 6));
        setContent(list);
        setFitToWidth(true);
        styleClass.add("pdf-outline");
        stylesheets.add(stylesheet!(`
            .pdf-outline-entry { padding: 5 8; background-radius: 6; }
            .pdf-outline-entry:hover { background-colour: var(--row-hover); }
        `));
        if (document)
            setDocument(document);
    }

    /// The document whose outline it shows.
    mixin(declareProperty!(PdfDocument, "document", "null", q{ rebuild(); }));

    /// Called when an entry is clicked.
    PdfOutline onItemChosen(void delegate(PdfOutlineItem item) handler) { _onItemChosen = handler; return this; }

    /// Whether there's anything in it.
    bool empty() const nothrow @nogc { return entries == 0; }

private:
    Column list;
    int entries;
    void delegate(PdfOutlineItem) _onItemChosen;
    PdfDocument watching;

    // An entry, with a closure of its own: one made in rebuild's loop would share the loop's item
    Label entry(PdfOutlineItem item, int depth)
    {
        auto label = new Label(item.title).wrapText(true);
        label.styleClass.add("pdf-outline-entry");
        label.setMargin(Insets(0, 0, 0, depth * 14));
        if (depth == 0)
            label.setStyle("font-weight: bold;");
        label.setCursor(Cursor.hand);
        label.setAccessibleRole(AccessibleRole.button);
        label.setOnMouseClicked((ref e) {
            if (_onItemChosen)
                _onItemChosen(item);
        });
        return label;
    }

    void rebuild()
    {
        while (list.children.length)
            list.remove(cast(Widget) list.children[0]);
        entries = 0;
        watching = _document;
        if (!_document)
            return;
        if (_document.status != PdfStatus.ready)
        {
            auto doc = _document;
            doc.statusProperty.addListener((PdfStatus was, PdfStatus now) {
                if (doc is watching && now == PdfStatus.ready)
                    rebuild();
            });
            return;
        }
        void add(PdfOutlineItem[] items, int depth)
        {
            foreach (item; items)
            {
                list.add(entry(item, depth));
                entries++;
                // Not too deep, should an outline go round in a loop
                if (depth < 12)
                    add(item.children, depth + 1);
            }
        }
        add(_document.outline, 0);
    }
}
