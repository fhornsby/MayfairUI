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

    Each is drawn from the document's preview of its page, asked for as it scrolls into view. The
    current page is marked, and kept in view.
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
    mixin(declareProperty!(int, "currentPage", "0", q{ markCurrent(); }));

    /// How wide each page is, in points.
    mixin(declareProperty!(float, "thumbnailWidth", "110", q{ rebuild(); }));

    /// Called when a page is clicked.
    PdfThumbnails onPageChosen(void delegate(int page) handler) { _onPageChosen = handler; return this; }

protected:
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
    PdfDocument watching;

    void rebuild()
    {
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
        markCurrent();
        requestUpdate();
    }

    void markCurrent()
    {
        foreach (i, item; items)
            item.setStyle(i == _currentPage ? "background-colour: var(--row-selected); background-radius: 6;" : "");
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
        add(picture).add(new Label((page + 1).to!string).style("font-size: 12px;"));
        setAccessibleRole(AccessibleRole.button);
        setAccessibleText("Page " ~ (page + 1).to!string);
        setCursor(Cursor.hand);
        setOnMouseClicked((ref e) { owner.chose(page); });
    }
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

    /// Asks for the preview, if it hasn't been.
    void want(PdfPriority priority)
    {
        if (bitmap || request)
            return;
        auto doc = owner._document;
        if (auto b = doc.cachedPreview(page))
        {
            show(b);
            return;
        }
        request = doc.preview(page, priority, (PdfBitmap b) { request = null; show(b); });
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
    PdfRequest request;
    Tvg_Paint holder, frame, picture;

    void show(PdfBitmap b)
    {
        bitmap = b;
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
