module lists;

/*
    The sidebar's other lists: the document's highlights and notes, a search's results, and the
    bookmarks made in it. Each row's clicked to go there.
*/

import std.algorithm : min;
import std.conv : to;
import std.format : format;
import std.string : replace, strip;
import mayfair;
import mayfair.pdf;
import store;

/// A row of a list: a little colour, a title, a line of text under it, and what clicking it does.
private Widget row(PdfColour colour, string title, string detail, void delegate() chosen, Widget end = null)
{
    auto swatch = new Row().prefWidth(4).prefHeight(30);
    swatch.setStyle(format!"background-colour: rgb(%s, %s, %s); background-radius: 2;"(colour.r, colour.g, colour.b));
    auto text = new Column().spacing(2).grow(1);
    text.add(new Label(title).style("font-size: 12px; colour: var(--prompt-text);"));
    if (detail.length)
        text.add(new Label(detail).wrapText(true).style("font-size: 13px;"));
    auto r = new Row().spacing(8).padding(Insets(6, 8)).alignment(Pos.centreLeft);
    r.add(swatch).add(text);
    if (end)
        r.add(end);
    r.styleClass.add("sidebar-row");
    r.setCursor(Cursor.hand);
    r.setOnMouseClicked((ref e) { chosen(); });
    return r;
}

private enum rowStyle = `
    .sidebar-row { background-radius: 6; }
    .sidebar-row:hover { background-colour: var(--row-hover); }
`;

/// What's marked on the document: every annotation but form fields, page by page.
final class AnnotationList : ScrollPane
{
    this(PdfView view)
    {
        super(null);
        this.view = view;
        list = new Column().padding(Insets(6));
        setContent(list);
        setFitToWidth(true);
        stylesheets.add(stylesheet!rowStyle);
    }

    /// Reads them again, from `document`.
    void show(PdfDocument document)
    {
        if (this.document && this.document !is document)
            this.document.removeChangeListener(&changed);
        if (document && this.document !is document)
            document.addChangeListener(&changed);
        this.document = document;
        refresh();
    }

private:
    PdfView view;
    PdfDocument document;
    Column list;
    PdfAnnotations[] pages;
    uint generation;

    void changed(PdfChange change) { refresh(); }

    void refresh()
    {
        generation++;
        pages = null;
        if (!document || document.status != PdfStatus.ready)
        {
            draw();
            return;
        }
        pages = new PdfAnnotations[document.pageCount];
        foreach (i; 0 .. document.pageCount)
            ask(i, generation);
    }

    void ask(int page, uint gen)
    {
        document.annotations(page, PdfPriority.background, (PdfAnnotations a) {
            if (gen != generation || page >= pages.length)
                return;
            pages[page] = a;
            draw();
        });
    }

    void draw()
    {
        while (list.children.length)
            list.remove(cast(Widget) list.children[0]);
        size_t shown;
        foreach (page, annotations; pages)
            if (annotations)
                foreach (a; annotations.list)
                {
                    if (a.kind == PdfAnnotationKind.widget)
                        continue;
                    list.add(entry(cast(int) page, a));
                    if (++shown >= 500)
                        return;
                }
        if (!shown)
            list.add(new Label(pages.length ? "No highlights or notes" : "").style("colour: var(--prompt-text); padding: 12;"));
    }

    Widget entry(int page, PdfAnnotation a)
    {
        string text = a.text.replace("\n", " ").strip;
        if (text.length > 120)
            text = text[0 .. 120] ~ "…";
        return row(a.colour, format!"%s · Page %s"(kindName(a.kind), page + 1), text, {
            view.goToPage(page, a.rect.y - 20);
            if (a.movable)
                view.selectAnnotation(PdfAnnotationRef(page, a.index));
        });
    }
}

/// What an annotation's called, in a list.
string kindName(PdfAnnotationKind kind)
{
    with (PdfAnnotationKind) final switch (kind)
    {
        case highlight: return "Highlight";
        case underline: return "Underline";
        case strikeOut: return "Strikethrough";
        case squiggly: return "Squiggly underline";
        case note: return "Note";
        case textBox: return "Text";
        case rectangle: return "Rectangle";
        case roundedRectangle: return "Rounded rectangle";
        case oval: return "Oval";
        case line: return "Line";
        case arrow: return "Arrow";
        case star: return "Star";
        case speechBubble: return "Speech bubble";
        case ink: return "Drawing";
        case signature: return "Signature";
        case widget: return "Form field";
        case other: return "Annotation";
    }
}

/// A search's results: each match, with the words round it.
final class SearchResults : ScrollPane
{
    this(PdfView view)
    {
        super(null);
        this.view = view;
        list = new Column().padding(Insets(6));
        setContent(list);
        setFitToWidth(true);
        stylesheets.add(stylesheet!rowStyle);
    }

    /// Shows the view's matches, as they are now.
    void refresh()
    {
        while (list.children.length)
            list.remove(cast(Widget) list.children[0]);
        auto doc = view.document;
        auto matches = view.matchList;
        list.add(new Label(view.searching ? "Searching…" : matches.length == 1 ? "1 match" : format!"%s matches"(matches.length))
                 .style("colour: var(--prompt-text); padding: 6 8;"));
        foreach (i, m; matches[0 .. min(matches.length, 300)])
            list.add(entry(cast(int) i, m, doc ? doc.cachedText(m.page) : null));
    }

private:
    PdfView view;
    Column list;

    Widget entry(int i, PdfMatch m, PdfPageText text)
    {
        string context;
        if (text)
        {
            const from = m.from > 40 ? m.from - 40 : 0, to = m.to + 40 < text.length ? m.to + 40 : text.length;
            context = (from > 0 ? "…" : "") ~ text.between(from, to).to!string.replace("\n", " ").replace("\r", "").strip
                      ~ (to < text.length ? "…" : "");
        }
        return row(PdfColour(255, 214, 10), format!"Page %s"(m.page + 1), context, { view.showMatch(i); });
    }
}

/// The pages bookmarked in this document: kept on this computer, not in the PDF.
final class BookmarkList : ScrollPane
{
    this(PdfView view)
    {
        super(null);
        this.view = view;
        list = new Column().padding(Insets(6));
        setContent(list);
        setFitToWidth(true);
        stylesheets.add(stylesheet!rowStyle);
    }

    /// Shows the bookmarks of the PDF at `path`.
    void show(string path)
    {
        this.path = path;
        while (list.children.length)
            list.remove(cast(Widget) list.children[0]);
        auto marks = path.length ? bookmarks(path) : null;
        foreach (b; marks)
            list.add(entry(b));
        if (!marks.length)
            list.add(new Label("No bookmarks. Ctrl+D bookmarks the page you're on.").wrapText(true)
                     .style("colour: var(--prompt-text); padding: 12;"));
    }

    /// Bookmarks the page being read.
    void add()
    {
        if (!path.length)
            return;
        const page = view.currentPage;
        foreach (b; bookmarks(path))
            if (b.page == page)
                return;
        addBookmark(path, Bookmark(page, format!"Page %s"(page + 1)));
        show(path);
    }

private:
    PdfView view;
    Column list;
    string path;

    Widget entry(Bookmark b)
    {
        auto forget = new Button().graphic(new Icon("window-close-symbolic")).accessibleText("Remove bookmark");
        forget.setOnAction({ removeBookmark(path, b); show(path); });
        return row(PdfColour(37, 99, 235), b.label, null, { view.goToPage(b.page); }, forget);
    }
}
