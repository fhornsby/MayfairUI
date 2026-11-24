import core.stdc.stdlib : exit;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind;
import std.file : tempDir, write;
import std.format : format;
import std.math : abs;
import std.path : buildPath, dirName;
import std.stdio : writefln, writeln;
import harness;
import mayfair;
import mayfair.pdf;
import mayfair.pdf.pdfium;

/*
    End-to-end tests for mayfair-pdf on PDFium: real PDFs, read by PDFium on the PDF thread, shown
    in real windows (see mayfair/tests' harness). The PDFs are made by assets/make-samples.py.

        cd tests && dub run
*/
void main()
{
    PdfDocument.setEngine(new PdfiumEngine);
    opening();
    errorsAndPasswords();
    rendering();
    textLinksAndOutline();
    viewLayoutAndZoom();
    viewSearch();
    viewSelectionAndLinks();
    viewRotation();
    sidebar();
    closing();
    writefln("%s passed, %s failed checks", passedCount, failedChecks);
    exit(failedChecks ? 1 : 0);
}

string sample(string name) { return buildPath(dirName(__FILE_FULL_PATH__), "..", "assets", name); }

bool waitFor(Driver d, bool delegate() ok, Duration timeout = 10.seconds)
{
    const deadline = MonoTime.currTime + timeout;
    while (MonoTime.currTime < deadline)
    {
        bool done;
        d.ui({ done = ok(); });
        if (done)
            return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

bool near(float a, float b, float by = 1.5f) { return abs(a - b) <= by; }

uint pixel(PdfBitmap b, float x, float y) // at `x`, `y` points of the bitmap's region
{
    const px = cast(uint) ((x - b.region.x) * b.scale), py = cast(uint) ((y - b.region.y) * b.scale);
    return b.pixels[py * b.width + px] & 0xFFFFFF;
}
bool reddish(uint c) { return (c >> 16 & 0xFF) > 200 && (c >> 8 & 0xFF) < 90 && (c & 0xFF) < 90; }
bool bluish(uint c) { return (c >> 16 & 0xFF) < 90 && (c & 0xFF) > 200; }

/// Opened: ready, with its pages' sizes, what it says about itself, and its outline.
void opening()
{
    PdfDocument doc;
    bool loadingAtFirst;
    run("pdf: opening", {
        doc = PdfDocument.open(sample("sample.pdf"));
        loadingAtFirst = doc.status == PdfStatus.loading; // open() didn't wait
        return cast(Widget) new Label("PDF");
    }, (Driver d) {
        d.check(loadingAtFirst, "loading at first, open() not waiting for it");
        d.check(waitFor(d, () => doc.status == PdfStatus.ready), "ready");
        d.ui({
            d.expect(doc.pageCount, 5);
            const a4 = doc.pageSize(0);
            d.check(near(a4.width, 595.28) && near(a4.height, 841.89), format!"A4: %s"(a4));
            const wide = doc.pageSize(3);
            d.check(near(wide.width, 841.89) && near(wide.height, 595.28), format!"the fourth, landscape: %s"(wide));
            d.expect(doc.metadata.get("Title", null), "Mayfair PDF sample");
            d.expect(doc.metadata.get("Author", null), "Mayfair");
            d.expect(doc.title, "Mayfair PDF sample");
            auto o = doc.outline;
            d.expect(o.length, 4, "four entries at the top of the outline");
            if (o.length == 4)
            {
                d.expect(o[0].title, "Introduction");
                d.expect(o[0].page, 0);
                d.expect(o[2].title, "Section three");
                d.expect(o[2].page, 2);
                d.expect(o[2].children.length, 1, "with one under it");
                if (o[2].children.length)
                {
                    d.expect(o[2].children[0].title, "Details");
                    d.check(near(o[2].children[0].y, 380, 4), format!"380 points down: %s"(o[2].children[0].y));
                }
                d.expect(o[3].page, 3);
            }
            doc.close();
            d.expect(doc.status, PdfStatus.closed);
        });
    });
}

/// What can't be opened says why; an encrypted one asks for its password, and opens with it.
void errorsAndPasswords()
{
    PdfDocument missing, notPdf, locked, wrong, right;
    run("pdf: errors and passwords", {
        const text = buildPath(tempDir, "mayfair-not-a.pdf");
        write(text, "Plain text, whatever its name says.\n");
        missing = PdfDocument.open("/nowhere/at/all.pdf");
        notPdf = PdfDocument.open(text);
        locked = PdfDocument.open(sample("locked.pdf"));
        wrong = PdfDocument.open(sample("locked.pdf"), "nope");
        right = PdfDocument.open(sample("locked.pdf"), "secret");
        return cast(Widget) new Label("PDF");
    }, (Driver d) {
        d.check(waitFor(d, () => right.status != PdfStatus.loading), "all tried");
        d.ui({
            d.expect(missing.status, PdfStatus.failed);
            d.expect(missing.error.kind, PdfErrorKind.notFound);
            d.expect(notPdf.status, PdfStatus.failed);
            d.expect(notPdf.error.kind, PdfErrorKind.notPdf, format!"not a PDF: %s"(notPdf.error));
            d.expect(locked.status, PdfStatus.needsPassword, "encrypted: it needs a password");
            d.expect(locked.error.message, "This PDF needs a password");
            d.expect(wrong.status, PdfStatus.needsPassword, "the wrong one");
            d.expect(wrong.error.message, "That password isn't right");
            d.expect(right.status, PdfStatus.ready, "the right one opens it");
            d.expect(right.pageCount, 5);
            foreach (doc; [missing, notPdf, locked, wrong, right])
                doc.close();
        });
    });
}

/// Rendered: the page's pixels where its drawing is, whole or a part, turned or not, and a /Rotate honoured.
void rendering()
{
    PdfDocument doc, rotated;
    PdfBitmap whole, part, turned, preview;
    run("pdf: rendering", {
        doc = PdfDocument.open(sample("sample.pdf"));
        rotated = PdfDocument.open(sample("rotated.pdf"));
        return cast(Widget) new Label("PDF");
    }, (Driver d) {
        d.check(waitFor(d, () => doc.status == PdfStatus.ready && rotated.status == PdfStatus.ready), "ready");
        d.ui({
            const s = doc.pageSize(1);
            doc.render(1, PdfRect(0, 0, s.width, s.height), 1, 0, PdfPriority.visible, (b) { whole = b; });
            // Just the circle's part, at four pixels a point
            doc.render(1, PdfRect(380, 120, 80, 80), 4, 0, PdfPriority.visible, (b) { part = b; });
            doc.render(1, PdfRect(0, 0, s.height, s.width), 1, 1, PdfPriority.visible, (b) { turned = b; });
            doc.preview(1, PdfPriority.visible, (b) { preview = b; });
        });
        d.check(waitFor(d, () => whole && part && turned && preview), "rendered");
        d.ui({
            d.check(near(whole.width, 596) && near(whole.height, 842), format!"a point a pixel: %s by %s"(whole.width, whole.height));
            d.check(reddish(pixel(whole, 172, 160)), format!"the red rectangle: %06x"(pixel(whole, 172, 160)));
            d.check(bluish(pixel(whole, 420, 160)), format!"the blue circle: %06x"(pixel(whole, 420, 160)));
            d.expect(pixel(whole, 300, 500), 0xFFFFFF, "white where there's nothing");
            d.check(part.width == 320 && part.height == 320, format!"80 points at 4 pixels: %s"(part.width));
            d.check(bluish(pixel(part, 420, 160)), "the part, rendered where it is");
            // Turned a quarter: the rectangle's centre (172, 160) goes to (841.89 - 160, 172)
            d.check(reddish(pixel(turned, 841.89f - 160, 172)), format!"turned, the rectangle where it's turned to: %06x"
                    (pixel(turned, 841.89f - 160, 172)));
            d.check(preview.width == PdfDocument.previewSize || preview.height == PdfDocument.previewSize,
                    format!"a preview's longer side: %s by %s"(preview.width, preview.height));
            d.check(doc.cachedPreview(1) is preview, "kept");
            // A page with /Rotate 90 is shown turned: its size turned with it
            const r = rotated.pageSize(0);
            d.check(near(r.width, 841.89) && near(r.height, 595.28), format!"/Rotate honoured: %s"(r));
            doc.close();
            rotated.close();
        });
    });
}

/// A page's text, with each character's box, and its links: the document's own and its web addresses.
void textLinksAndOutline()
{
    PdfDocument doc;
    PdfPageText first;
    PdfLinks links;
    run("pdf: text and links", { doc = PdfDocument.open(sample("sample.pdf")); return cast(Widget) new Label("PDF"); }, (Driver d) {
        d.check(waitFor(d, () => doc.status == PdfStatus.ready), "ready");
        d.ui({
            doc.text(0, PdfPriority.visible, (t) { first = t; });
            doc.links(0, PdfPriority.visible, (l) { links = l; });
        });
        d.check(waitFor(d, () => first && links), "read");
        d.ui({
            const all = first.between(0, first.length);
            d.check(all.canFind("The quick brown fox jumps over the lazy dog."), "the text");
            d.check(all.canFind("Mayfair PDF sample\n"), "lines broken with \\n");
            auto fox = first.find("fox"d, false);
            d.expect(fox.length, 2, "\"fox\" twice on the first page");
            if (fox.length)
            {
                PdfRect box;
                foreach (r; first.rects(fox[0][0], fox[0][1]))
                    box = box.union_(r);
                d.check(box.bottom > 128 && box.y < 142 && box.x > 150 && box.x < 200,
                        format!"where it's written: %s"(box));
            }
            d.expect(first.find("MAYFAIR"d, false).length, 3, "\"Mayfair\" three times, whatever the case");
            d.expect(first.find("MAYFAIR"d, true).length, 0, "and not at all, matching case");
            const(PdfLink)* inside, web;
            foreach (ref l; links.links)
            {
                if (l.page == 2)
                    inside = &l;
                if (l.uri == "https://dlang.org")
                    web = &l;
            }
            d.check(inside !is null, format!"a link to page 3: %s"(links.links));
            d.check(web !is null, "and one to a web page");
            if (inside && inside.areas.length)
                d.check(near(inside.areas[0].y, 208, 8), format!"where it is: %s"(inside.areas[0]));
            if (web && web.areas.length)
                d.check(links.at(web.areas[0].x + 2, web.areas[0].y + 2) is web, "found by where it is");
            doc.close();
        });
    });
}

/// A view: pages laid out to fit, drawn in tiles at the screen's pixels, zoomed, paged.
void viewLayoutAndZoom()
{
    PdfView view;
    run("pdf view: layout and zoom", {
        view = new PdfView(PdfDocument.open(sample("sample.pdf"))).prefSize(500, 400);
        return cast(Widget) new Column().padding(10).fillWidth(false).add(view);
    }, (Driver d) {
        d.check(waitFor(d, () => view.stats.tiles > 0 && view.stats.tilesWaiting == 0), "drawn");
        d.ui({
            d.expect(view.fit, PdfFit.width, "fitting the width, to start");
            // 500 wide, less the margins, for the landscape page, the widest
            d.check(near(view.zoom, (500 - 32) / 841.89f, 0.01f), format!"zoom %s"(view.zoom));
            const page = view.pageRectInScene(0, PdfRect(0, 0, 595.28f, 841.89f));
            d.check(page.minY > view.boundsInScene.minY && page.minY < view.boundsInScene.minY + 30, format!"page 1 at the top: %s"(page));
            d.expect(view.currentPage, 0);
            const st = view.stats;
            d.check(st.pagesNear >= 1 && st.pagesNear <= 5, format!"only pages near the view kept: %s"(st));
            view.setZoom(2);
        });
        d.ui({ d.expect(view.fit, PdfFit.none, "setting the zoom stops fitting"); });
        d.check(waitFor(d, () => view.stats.tiles > 0 && view.stats.tilesWaiting == 0), "drawn again, bigger");
        d.ui({
            const st = view.stats;
            d.check(st.tiles >= 1 && st.previews >= 1, format!"tiles over its preview: %s"(st));
            view.zoomIn();
            d.expect(view.zoom, 2.5f, "a step in");
            view.zoomOut();
            view.zoomOut();
            d.expect(view.zoom, 1.75f, "two steps out");
            view.setZoom(100);
            d.expect(view.zoom, PdfView.maxZoom, "no more than the most");
            view.setFit(PdfFit.page);
        });
        d.settle();
        d.ui({
            const page = view.pageRectInScene(0, PdfRect(0, 0, 595.28f, 841.89f));
            d.check(page.height <= 400, format!"a whole page fits: %s"(page));
            view.goToPage(3);
        });
        d.check(waitFor(d, () => view.currentPage == 3, 3.seconds), format!"to page 4: %s"(view.currentPage));
        d.ui({ view.document.close(); });
    });
}

/// Searching: every match, from every page, highlighted, and gone between.
void viewSearch()
{
    PdfView view;
    run("pdf view: search", {
        view = new PdfView(PdfDocument.open(sample("sample.pdf"))).prefSize(500, 400);
        return cast(Widget) view;
    }, (Driver d) {
        d.check(waitFor(d, () => view.document.status == PdfStatus.ready), "ready");
        d.ui({ view.find("fox"); });
        d.check(waitFor(d, () => !view.searching), "searched");
        d.ui({
            d.expect(view.matchCount, 3, "three foxes, on two pages");
            d.expect(view.currentMatch, 0, "the first, current");
            view.findNext();
            d.expect(view.currentMatch, 1);
            view.findNext();
            view.findNext();
            d.expect(view.currentMatch, 0, "round again");
            view.findPrevious();
            d.expect(view.currentMatch, 2, "and back the other way");
        });
        d.check(waitFor(d, () => view.currentPage == 1, 3.seconds), "the third is on page 2, which it went to");
        d.ui({ view.find("Mayfair", true); });
        d.check(waitFor(d, () => !view.searching), "searched again");
        d.ui({
            d.expect(view.matchCount, 3, "\"Mayfair\", matching case, three times");
            view.find("nothing like this");
        });
        d.check(waitFor(d, () => !view.searching), "and again");
        d.ui({
            d.expect(view.matchCount, 0);
            d.expect(view.currentMatch, -1);
            view.clearSearch();
            view.document.close();
        });
    });
}

/// Selecting by dragging, a word by double-clicking, copying; and following links.
void viewSelectionAndLinks()
{
    PdfView view;
    string[] external;
    run("pdf view: selecting and links", {
        view = new PdfView(PdfDocument.open(sample("sample.pdf"))).prefSize(600, 500);
        view.onExternalLink((uri) { external ~= uri; });
        return cast(Widget) view;
    }, (Driver d) {
        d.preserveClipboard();
        d.check(waitFor(d, () => view.document.status == PdfStatus.ready && view.document.cachedText(0)
                                 && view.document.cachedLinks(0)), "ready, its first page's text read");
        d.settle();
        Bounds from, to, word;
        d.ui({
            auto t = view.document.cachedText(0);
            auto r = t.find("quick brown"d, false)[0];
            from = view.pageRectInScene(0, t.boxes[r[0]]);
            to = view.pageRectInScene(0, t.boxes[r[1] - 1]);
            auto j = t.find("jumps"d, false)[0];
            word = view.pageRectInScene(0, t.boxes[j[0] + 2]);
        });
        d.move(from.minX + 1, from.centreY);
        d.press(from.minX + 1, from.centreY);
        d.move(to.centreX, to.centreY);
        d.move(to.maxX - 1, to.centreY);
        d.release(to.maxX - 1, to.centreY);
        d.ui({
            d.check(view.hasSelection, "selected");
            d.expect(view.selectedText, "quick brown", "dragged across");
            view.copySelection();
            d.expect(Clipboard.text, "quick brown", "and copied");
        });
        d.click(word.centreX, word.centreY, 2);
        d.ui({ d.expect(view.selectedText, "jumps", "a double click, a word"); });
        d.key(SDL_Keycode.SDLK_ESCAPE);
        d.ui({ d.check(!view.hasSelection, "Escape, none"); });

        // Links: to a web page, to the app; to a page, there
        Bounds web, inside;
        d.ui({
            foreach (l; view.document.cachedLinks(0).links)
            {
                if (l.uri.length)
                    web = view.pageRectInScene(0, l.areas[0]);
                else
                    inside = view.pageRectInScene(0, l.areas[0]);
            }
        });
        d.click(web.centreX, web.centreY);
        d.ui({ d.expect(external, ["https://dlang.org"], "a web link, to the app"); });
        d.click(inside.centreX, inside.centreY);
        d.check(waitFor(d, () => view.currentPage == 2, 3.seconds), format!"a link to page 3, there: %s"(view.currentPage));
        d.ui({ view.document.close(); });
    });
}

/// Turned: pages a quarter round, drawn and laid out so, and the page being read kept.
void viewRotation()
{
    PdfView view;
    run("pdf view: rotation", {
        view = new PdfView(PdfDocument.open(sample("sample.pdf"))).prefSize(500, 400);
        return cast(Widget) view;
    }, (Driver d) {
        d.check(waitFor(d, () => view.stats.tiles > 0 && view.stats.tilesWaiting == 0), "drawn");
        d.ui({ view.goToPage(1); });
        d.check(waitFor(d, () => view.currentPage == 1, 3.seconds), "on page 2");
        d.ui({ view.rotateClockwise(); });
        d.check(waitFor(d, () => view.stats.tiles > 0 && view.stats.tilesWaiting == 0), "drawn turned");
        d.ui({
            d.expect(view.rotation, 1);
            const r = view.pageRectInScene(1, PdfRect(0, 0, 595.28f, 841.89f));
            d.check(r.width > r.height, format!"a portrait page, turned, is wider than tall: %s"(r));
            d.expect(view.currentPage, 1, "still on page 2");
            view.rotateAnticlockwise();
            view.rotateAnticlockwise();
            d.expect(view.rotation, 3, "round the other way");
            view.document.close();
        });
    });
}

/// Thumbnails: a page each, the current one marked, a click going there; and the outline's entries.
void sidebar()
{
    PdfThumbnails thumbnails;
    PdfOutline outline;
    PdfDocument doc;
    int[] chosen;
    PdfOutlineItem[] items;
    run("pdf sidebar: thumbnails and outline", {
        doc = PdfDocument.open(sample("sample.pdf"));
        thumbnails = new PdfThumbnails(doc).prefSize(180, 400);
        thumbnails.onPageChosen((p) { chosen ~= p; });
        outline = new PdfOutline(doc).prefSize(200, 300);
        outline.onItemChosen((item) { items ~= item; });
        return cast(Widget) new Row().spacing(10).add(thumbnails).add(outline);
    }, (Driver d) {
        d.check(waitFor(d, () => doc.status == PdfStatus.ready), "ready");
        d.check(waitFor(d, () => doc.cachedPreview(0) !is null), "the first pages' previews rendered");
        d.settle();
        Bounds second;
        d.ui({
            d.check(!outline.empty, "an outline");
            auto list = cast(Column) thumbnails.content;
            d.expect(list.children.length, 5, "a thumbnail a page");
            second = (cast(Widget) list.children[1]).boundsInScene; // the third runs off the window's bottom
        });
        d.click(second.centreX, second.centreY);
        d.ui({
            d.expect(chosen, [1], "clicked, chosen");
            d.expect(thumbnails.currentPage, 1, "and marked");
            auto entries = (cast(Column) outline.content).children;
            d.expect(entries.length, 5, "four entries and one under them");
        });
        Bounds details;
        d.ui({ details = (cast(Widget) (cast(Column) outline.content).children[3]).boundsInScene; });
        d.click(details.centreX, details.centreY);
        d.ui({
            d.expect(items.length, 1);
            if (items.length)
            {
                d.expect(items[0].title, "Details");
                d.expect(items[0].page, 2);
            }
            doc.close();
        });
    });
}

/// Closing: at once, while it's opening, and over and over; a view of a closed document shows nothing.
void closing()
{
    PdfView view;
    run("pdf: closing", {
        view = new PdfView(PdfDocument.open(sample("sample.pdf"))).prefSize(400, 300);
        return cast(Widget) view;
    }, (Driver d) {
        d.check(waitFor(d, () => view.stats.tiles > 0 && view.stats.tilesWaiting == 0), "drawn");
        d.ui({
            view.document.close();
            d.expect(view.document.status, PdfStatus.closed);
        });
        d.settle();
        d.ui({ d.expect(view.stats.pagesNear, 0, "nothing shown of a closed document"); });
        // While it's opening, and many times over
        PdfDocument[] docs;
        d.ui({
            foreach (i; 0 .. 50)
            {
                auto doc = PdfDocument.open(sample(i % 2 ? "sample.pdf" : "rotated.pdf"));
                if (i % 3)
                    doc.close();
                docs ~= doc;
            }
        });
        d.check(waitFor(d, () => !docs.canFind!(doc => doc.status == PdfStatus.loading)), "all opened or closed");
        d.ui({
            foreach (i, doc; docs)
                if (i % 3)
                    d.expect(doc.status, PdfStatus.closed, "closed while opening, closed");
                else
                {
                    d.expect(doc.status, PdfStatus.ready);
                    doc.close();
                }
            // A view given a new document starts again with it
            view.setDocument(PdfDocument.open(sample("sample.pdf")));
        });
        d.check(waitFor(d, () => view.stats.tiles > 0 && view.stats.tilesWaiting == 0), "the new one drawn");
        d.ui({ view.document.close(); });
    });
}
