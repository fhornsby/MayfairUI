import core.stdc.stdlib : exit;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind;
import std.file : copy, exists, read, remove, tempDir, write;
import std.format : format;
import std.math : abs;
import std.path : buildPath, dirName;
import std.stdio : writefln, writeln;
import harness;
import mayfair;
import mayfair.pdf;

/*
    End-to-end tests for mayfair-pdf on PDFium: real PDFs, read by PDFium on the PDF thread, shown
    in real windows (see mayfair/tests' harness). The PDFs are made by assets/make-samples.py.

        cd tests && dub run
*/
void main()
{
    // No engine set: documents are read with PDFium, as an app's are
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
    editingPages();
    annotating();
    fillingForms();
    viewMarkup();
    thumbnailEditing();
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

/// A copy of sample `name` to change, in the temporary folder.
string scratch(string name)
{
    const to = buildPath(tempDir, "mayfair-pdf-test-" ~ name);
    copy(sample(name), to);
    return to;
}

/// Pages turned, deleted, moved, inserted, cropped: each undone and redone, the listeners told
/// which page is which, and saved.
void editingPages()
{
    PdfDocument doc;
    PdfChange[] heard;
    const file = scratch("sample.pdf");
    run("pdf editing: pages", {
        doc = PdfDocument.open(file);
        doc.addChangeListener((PdfChange c) { heard ~= c; });
        return cast(Widget) new Label("PDF");
    }, (Driver d) {
        d.check(waitFor(d, () => doc.status == PdfStatus.ready), "ready");
        d.ui({ d.check(doc.info.editable, "PDFium's can be edited"); d.check(!doc.edited && !doc.canUndo, "not edited yet"); });

        d.ui({ doc.rotatePages([1], 1); });
        d.check(waitFor(d, () => doc.canUndo), "turned");
        d.ui({
            const s = doc.pageSize(1);
            d.check(near(s.width, 841.89) && near(s.height, 595.28), format!"page 2 on its side: %s"(s));
            d.check(doc.edited, "edited");
            d.expect(heard.length, 1);
            d.expect(heard[0].from[1], -1, "a turned page is a new one, to what's kept");
            d.expect(heard[0].from[0], 0, "and the others the same");
        });

        d.ui({ doc.deletePages([4]); });
        d.check(waitFor(d, () => doc.pageCount == 4), "the last deleted");
        d.ui({ d.expect(heard[$ - 1].from, [0, 1, 2, 3]); });

        d.ui({ doc.movePages([3], 0); });
        d.check(waitFor(d, () => heard.length == 3), "moved");
        d.ui({
            d.expect(heard[$ - 1].from, [3, 0, 1, 2], "the fourth first");
            d.check(doc.pageSize(0).width > doc.pageSize(0).height, "the landscape page, first");
        });

        d.ui({ doc.insertBlankPage(1, PdfSize(200, 300)); });
        d.check(waitFor(d, () => doc.pageCount == 5), "a blank page put in");
        d.ui({ d.check(near(doc.pageSize(1).width, 200) && near(doc.pageSize(1).height, 300), "200 by 300"); });

        d.ui({ doc.undo(); });
        d.check(waitFor(d, () => doc.pageCount == 4), "undone");
        d.ui({ d.check(doc.canRedo, "redoable"); d.expect(heard[$ - 1].from, [0, 2, 3, 4], "undoing an insert: each page from where it went"); });
        d.ui({ doc.redo(); });
        d.check(waitFor(d, () => doc.pageCount == 5), "redone");

        d.ui({ doc.cropPages([0], PdfRect(100, 100, 300, 200)); });
        d.check(waitFor(d, () => near(doc.pageSize(0).width, 300)), "cropped");
        d.ui({ d.check(near(doc.pageSize(0).height, 200), format!"to 300 by 200: %s"(doc.pageSize(0))); });

        bool saved;
        PdfError error;
        d.ui({ doc.save(file, PdfSaveOptions.init, (PdfError e) { error = e; saved = true; }); });
        d.check(waitFor(d, () => saved), "saved");
        d.ui({ d.check(!error, error.toString); d.check(!doc.edited, "not edited, once saved"); });
        // And read back, by another document
        PdfDocument again;
        d.ui({ again = PdfDocument.open(file); });
        d.check(waitFor(d, () => again.status == PdfStatus.ready), "opened again");
        d.ui({
            d.expect(again.pageCount, 5, "as it was saved");
            d.check(near(again.pageSize(0).width, 300) && near(again.pageSize(1).width, 200), "crop and blank page kept");
            again.close();
            doc.close();
        });
    });
}

/// Annotations of every kind added, read back, changed, removed, undone, and saved.
void annotating()
{
    PdfDocument doc;
    const file = scratch("sample.pdf");
    run("pdf editing: annotations", {
        doc = PdfDocument.open(file);
        return cast(Widget) new Label("PDF");
    }, (Driver d) {
        d.check(waitFor(d, () => doc.status == PdfStatus.ready), "ready");
        PdfPageText text;
        d.ui({ doc.text(0, PdfPriority.visible, (PdfPageText t) { text = t; }); });
        d.check(waitFor(d, () => text !is null), "text read");
        int added;
        d.ui({
            auto r = text.find("quick brown"d, false)[0];
            PdfAnnotation h;
            h.kind = PdfAnnotationKind.highlight;
            h.colour = PdfColour(255, 214, 10);
            h.lines = text.rects(r[0], r[1]);
            h.text = "quick brown";
            h.rect = h.bounds;
            doc.addAnnotation(0, h, (int i) { added++; });
            foreach (kind; [PdfAnnotationKind.rectangle, PdfAnnotationKind.oval, PdfAnnotationKind.arrow,
                            PdfAnnotationKind.star, PdfAnnotationKind.textBox, PdfAnnotationKind.note,
                            PdfAnnotationKind.ink])
            {
                PdfAnnotation a;
                a.kind = kind;
                a.colour = PdfColour(0, 0, 255);
                a.lineWidth = 4;
                a.rect = PdfRect(100, 500, 120, 80);
                a.strokes = [[PdfPoint(100, 500), PdfPoint(220, 580)]];
                if (kind == PdfAnnotationKind.textBox)
                    a.text = "Some words";
                if (kind == PdfAnnotationKind.arrow || kind == PdfAnnotationKind.ink)
                    a.rect = a.bounds;
                doc.addAnnotation(0, a, (int i) { if (i >= 0) added++; });
            }
        });
        d.check(waitFor(d, () => added == 8), format!"eight added: %s"(added));
        PdfAnnotations list;
        d.ui({ doc.annotations(0, PdfPriority.visible, (PdfAnnotations a) { list = a; }); });
        d.check(waitFor(d, () => list !is null), "read back");
        PdfAnnotation arrow;
        d.ui({
            PdfAnnotationKind[] kinds;
            foreach (a; list.list)
                if (a.ours)
                    kinds ~= a.kind;
            with (PdfAnnotationKind)
                d.expect(kinds, [highlight, rectangle, oval, arrow, star, textBox, note, ink], "each, ours, in order");
            foreach (a; list.list)
            {
                if (a.kind == PdfAnnotationKind.highlight)
                {
                    d.expect(a.text, "quick brown", "the highlight's text");
                    d.expect(a.lines.length, 1, "on a line");
                }
                if (a.kind == PdfAnnotationKind.arrow)
                {
                    arrow = a;
                    d.check(a.strokes.length == 1 && near(a.strokes[0][1].x, 220) && near(a.strokes[0][1].y, 580),
                            format!"the arrow where it was put: %s"(a.strokes));
                    d.expect(a.colour, PdfColour(0, 0, 255), "blue");
                }
                if (a.kind == PdfAnnotationKind.textBox)
                    d.expect(a.text, "Some words");
            }
        });
        // Drawn: the rectangle's left edge is blue
        PdfBitmap b;
        d.ui({ doc.render(0, PdfRect(90, 490, 40, 40), 2, 0, PdfPriority.visible, (PdfBitmap x) { b = x; }); });
        d.check(waitFor(d, () => b !is null), "rendered");
        d.ui({ d.check(bluish(pixel(b, 101.5f, 520)), format!"the rectangle drawn: %06x"(pixel(b, 101.5f, 520))); });

        // Changed: the arrow, red and moved; removed: the star
        int changedTo = -1;
        d.ui({
            auto red = arrow.movedBy(0, 100);
            red.colour = PdfColour(255, 0, 0);
            doc.updateAnnotation(0, arrow.index, red, (int i) { changedTo = i; });
        });
        d.check(waitFor(d, () => changedTo >= 0), "the arrow changed");
        list = null;
        d.ui({ doc.annotations(0, PdfPriority.visible, (PdfAnnotations a) { list = a; }); });
        d.check(waitFor(d, () => list !is null), "read again");
        int star = -1;
        d.ui({
            foreach (a; list.list)
            {
                if (a.kind == PdfAnnotationKind.arrow)
                {
                    d.expect(a.colour, PdfColour(255, 0, 0), "red now");
                    d.check(near(a.strokes[0][1].y, 680), "and lower");
                }
                if (a.kind == PdfAnnotationKind.star)
                    star = a.index;
            }
            doc.removeAnnotation(0, star);
        });
        d.check(waitFor(d, () => doc.cachedAnnotations(0) is null || doc.cachedAnnotations(0).list.length == 7), "the star gone");
        d.ui({ doc.undo(); });
        list = null;
        d.check(waitFor(d, () => !doc.busy), "undone");
        d.ui({ doc.annotations(0, PdfPriority.visible, (PdfAnnotations a) { list = a; }); });
        d.check(waitFor(d, () => list !is null), "read after undoing");
        d.ui({ d.expect(list.list.length, 8, "the star back"); });

        bool saved;
        d.ui({ doc.save(file, PdfSaveOptions.init, (PdfError e) { saved = !e; }); });
        d.check(waitFor(d, () => saved), "saved");
        PdfDocument again;
        list = null;
        d.ui({ again = PdfDocument.open(file); });
        d.check(waitFor(d, () => again.status == PdfStatus.ready), "opened again");
        d.ui({ again.annotations(0, PdfPriority.visible, (PdfAnnotations a) { list = a; }); });
        d.check(waitFor(d, () => list !is null), "its annotations read");
        d.ui({
            size_t ours;
            foreach (a; list.list)
                if (a.ours)
                    ours++;
            d.expect(ours, 8, "all eight saved, and still ours");
            again.close();
            doc.close();
        });
    });
}

/// A form filled in: a text field typed into, a box ticked, a choice made; undone; saved.
void fillingForms()
{
    PdfView view;
    const file = scratch("form.pdf");
    run("pdf editing: forms", {
        view = new PdfView(PdfDocument.open(file)).prefSize(700, 600);
        return cast(Widget) view;
    }, (Driver d) {
        auto doc() { return view.document; }
        d.check(waitFor(d, () => doc.status == PdfStatus.ready && doc.cachedAnnotations(0)), "ready, its fields read");
        d.settle();
        d.ui({ d.check(doc.info.hasForm, "it has a form"); });
        Bounds name, box;
        d.ui({
            foreach (a; doc.cachedAnnotations(0).list)
            {
                d.expect(a.kind, PdfAnnotationKind.widget, "fields, as widgets");
                if (a.fieldType == 6 && !name.width)
                    name = view.pageRectInScene(0, a.rect);
                if (a.fieldType == 2)
                    box = view.pageRectInScene(0, a.rect);
            }
        });
        d.click(name.centreX, name.centreY);
        d.check(waitFor(d, () => doc.formFocus == 0), "the name field has focus");
        d.type("Ada");
        d.check(waitFor(d, () => doc.edited && !doc.busy), "typed into");
        d.key(SDL_Keycode.SDLK_BACKSPACE);
        d.type("a Lovelace");
        d.check(waitFor(d, () => !doc.busy), "typed");
        uint before;
        d.ui({ before = doc.pageVersion(0); });
        d.click(box.centreX, box.centreY);
        d.check(waitFor(d, () => doc.pageVersion(0) != before && !doc.busy), "ticked: the page drawn again");
        d.ui({ d.check(doc.canUndo, "undoably"); });
        d.ui({ d.check(doc.formFocus == 0, "the box has focus now"); });
        bool saved;
        d.ui({ doc.save(file, PdfSaveOptions.init, (PdfError e) { saved = !e; }); });
        d.check(waitFor(d, () => saved), "saved");
        d.ui({
            auto bytes = cast(const(char)[]) read(file);
            d.check(bytes.canFind("(Ada Lovelace)"), "the name, in the file");
            d.check(bytes.canFind("/V /Yes") || bytes.canFind("/V/Yes"), "the box, ticked in the file");
            doc.close();
        });
    });
}

/// Marked up with the view's tools, by the pointer: a highlight, a rectangle selected, moved and
/// deleted, undone; a region cropped to.
void viewMarkup()
{
    PdfView view;
    const file = scratch("sample.pdf");
    run("pdf view: marking up", {
        view = new PdfView(PdfDocument.open(file)).prefSize(700, 600);
        return cast(Widget) view;
    }, (Driver d) {
        auto doc() { return view.document; }
        d.check(waitFor(d, () => doc.status == PdfStatus.ready && doc.cachedText(0) && doc.cachedAnnotations(0)), "ready");
        d.settle();
        Bounds from, to;
        d.ui({
            auto t = doc.cachedText(0);
            auto r = t.find("quick brown"d, false)[0];
            from = view.pageRectInScene(0, t.boxes[r[0]]);
            to = view.pageRectInScene(0, t.boxes[r[1] - 1]);
            view.setTool(PdfTool.highlight);
        });
        d.press(from.minX + 1, from.centreY);
        d.move(to.centreX, to.centreY);
        d.move(to.maxX - 1, to.centreY);
        d.release(to.maxX - 1, to.centreY);
        d.check(waitFor(d, () => doc.cachedAnnotations(0) && doc.cachedAnnotations(0).list.length == 1), "highlighted");
        d.ui({
            auto a = doc.cachedAnnotations(0).list[0];
            d.expect(a.kind, PdfAnnotationKind.highlight);
            d.expect(a.text, "quick brown", "what was dragged across");
            d.expect(view.tool, PdfTool.highlight, "the highlighter kept, for more");
        });

        // A rectangle, dragged out
        Bounds page;
        d.ui({ view.setTool(PdfTool.rectangle); page = view.pageRectInScene(0, PdfRect(100, 300, 200, 100)); });
        d.press(page.minX, page.minY);
        d.move(page.centreX, page.centreY);
        d.move(page.maxX, page.maxY);
        d.release(page.maxX, page.maxY);
        d.check(waitFor(d, () => view.selectedAnnotation.page == 0 && doc.cachedAnnotations(0)
                                 && doc.cachedAnnotations(0).list.length == 2), "drawn, and selected");
        d.ui({
            d.expect(view.tool, PdfTool.select, "the tool back to selecting");
            auto r = view.selectedAnnotationValue;
            d.check(r && r.kind == PdfAnnotationKind.rectangle, "a rectangle");
            d.check(r && near(r.rect.x, 100, 3) && near(r.rect.y, 300, 3) && near(r.rect.width, 200, 3),
                    format!"where it was dragged: %s"(r ? r.rect : PdfRect.init));
        });

        // Moved by dragging it
        d.press(page.centreX, page.centreY);
        d.move(page.centreX + 20, page.centreY + 20);
        d.release(page.centreX + 40, page.centreY + 40);
        d.check(waitFor(d, () => !doc.busy && view.selectedAnnotationValue && view.selectedAnnotationValue.rect.x > 110),
                format!"moved: selected %s, %s, busy %s, undo '%s'"(view.selectedAnnotation,
                       view.selectedAnnotationValue ? view.selectedAnnotationValue.rect : PdfRect.init, doc.busy, doc.undoName));
        // Deleted, and back
        d.key(SDL_Keycode.SDLK_DELETE);
        d.check(waitFor(d, () => doc.cachedAnnotations(0) && doc.cachedAnnotations(0).list.length == 1), "deleted");
        d.ui({ doc.undo(); });
        d.check(waitFor(d, () => !doc.busy && doc.cachedAnnotations(0) && doc.cachedAnnotations(0).list.length == 2), "undone");

        // A region, cropped to: once nothing's changing, as a change of the document forgets it
        d.check(waitFor(d, () => !doc.busy), "settled");
        d.settle();
        Bounds region;
        d.ui({ view.setTool(PdfTool.region); region = view.pageRectInScene(0, PdfRect(50, 50, 300, 250)); });
        d.press(region.minX, region.minY);
        d.move(region.centreX, region.centreY);
        d.release(region.maxX, region.maxY);
        d.check(waitFor(d, () => view.region.page == 0, 3.seconds), "a region");
        d.ui({ view.cropToRegion(); });
        d.check(waitFor(d, () => near(doc.pageSize(0).width, 300, 3)), format!"cropped: %s"(doc.pageSize(0)));
        d.ui({ doc.close(); });
    });
}

/// The sidebar's pages: selected, dragged to move them, and deleted with Delete.
void thumbnailEditing()
{
    PdfThumbnails thumbnails;
    PdfDocument doc;
    int[][] moved;
    int[] movedTo;
    int[][] deleted;
    run("pdf sidebar: moving and deleting pages", {
        doc = PdfDocument.open(scratch("sample.pdf"));
        thumbnails = new PdfThumbnails(doc).prefSize(180, 760).thumbnailWidth(60);
        thumbnails.onPagesMoved((int[] pages, int before) { moved ~= pages; movedTo ~= before; doc.movePages(pages, before); });
        thumbnails.onDeletePages((int[] pages) { deleted ~= pages; doc.deletePages(pages); });
        return cast(Widget) thumbnails;
    }, (Driver d) {
        d.check(waitFor(d, () => doc.status == PdfStatus.ready), "ready");
        d.settle();
        Bounds first, third;
        d.ui({
            auto items = (cast(Column) thumbnails.content).children;
            first = (cast(Widget) items[0]).boundsInScene;
            third = (cast(Widget) items[2]).boundsInScene;
        });
        // The first dragged below the third: before the fourth
        d.press(first.centreX, first.centreY);
        foreach (k; 1 .. 8)
            d.move(first.centreX, first.centreY + (third.maxY - 5 - first.centreY) * k / 7);
        d.release(first.centreX, third.maxY - 5);
        d.check(waitFor(d, () => movedTo.length == 1), "moved");
        d.ui({ d.expect(moved[0], [0]); d.expect(movedTo[0], 3, "to before the fourth"); });
        d.check(waitFor(d, () => !doc.busy), "and the document with it");
        d.ui({ d.check(doc.pageSize(3).width > doc.pageSize(3).height, "the landscape page third now, as it was fourth"); });
        // Ctrl clicks select two; Delete deletes them
        Bounds a, b;
        d.ui({
            auto items = (cast(Column) thumbnails.content).children;
            a = (cast(Widget) items[0]).boundsInScene;
            b = (cast(Widget) items[1]).boundsInScene;
        });
        d.click(a.centreX, a.centreY);
        d.hold(SDL_Keymod.KMOD_LCTRL);
        d.click(b.centreX, b.centreY);
        d.hold(SDL_Keymod.KMOD_NONE);
        d.ui({ d.expect(thumbnails.selectedPages, [0, 1], "two selected"); });
        d.key(SDL_Keycode.SDLK_DELETE);
        d.check(waitFor(d, () => doc.pageCount == 3), "both deleted");
        d.ui({ d.expect(deleted, [[0, 1]]); doc.close(); });
    });
}
