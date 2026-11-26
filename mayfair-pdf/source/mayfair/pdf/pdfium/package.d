module mayfair.pdf.pdfium;

/*
    A PdfEngine on PDFium: Google's PDF library, Chrome's, BSD-3-Clause and Apache-2.0 licensed.
    It's what documents are read with, unless an app gives PdfDocument.setEngine another.

    PDFium is found at run time, the first time a document's opened, not linked: so an app builds
    without it, and one run where it's missing has its documents fail with
    PdfErrorKind.engineUnavailable, saying where it looked. It looks, in order:

        1. MAYFAIR_PDFIUM, if it's set: the library's path
        2. beside the app's executable: where dub copies the one this package downloads, and where
           an app shipping PDFium puts it
        3. this package's own pdfium/ folder, where its build downloads PDFium (see fetch.d)
        4. the system's own: libpdfium.so, libpdfium.dylib or pdfium.dll on the library path

    Few systems package PDFium, so the build downloads a prebuilt one, from the pdfium-binaries
    project, at a version and checksum pinned in fetch.d. See this package's README for its licences.

    Its documents can be changed and saved (PdfEditableDocument) -- pages turned, deleted, moved,
    inserted and cropped; annotations added, changed and removed -- and their forms filled in
    (PdfFormDocument), with PDFium's own form filling.

    Everything here runs on mayfair-pdf's PDF thread, one call at a time, as PDFium needs.
*/

public import mayfair.pdf;
import core.stdc.config : c_ulong;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.stdio : File;
import std.utf : toUTF16, toUTF8;
import mayfair.pdf.pdfium.fpdf;

/// PDFium, as a PdfEngine.
final class PdfiumEngine : PdfEngine
{
    string name() { return "pdfium"; }

    /// The library it loaded, once it's started: for an About box, or a bug report.
    string library() const { return loadedFrom; }

    bool start(out string failure)
    {
        string[] tried;
        foreach (candidate; candidates)
        {
            string why;
            if (loadPdfium(candidate, fn, why))
            {
                loadedFrom = candidate;
                FPDF_LIBRARY_CONFIG config;
                fn.FPDF_InitLibraryWithConfig(&config);
                return true;
            }
            tried ~= candidate ~ ": " ~ why;
        }
        import std.array : join;
        failure = "PDFium wasn't found. Looked for " ~ tried.join("; ");
        return false;
    }

    PdfEngineDocument open(string path, string password, out PdfError error)
    {
        if (!exists(path))
        {
            error = PdfError(PdfErrorKind.notFound, "There's no file there", path);
            return null;
        }
        auto doc = new PdfiumDocument(this);
        try
            doc.file = File(path, "rb");
        catch (Exception e)
        {
            error = PdfError(PdfErrorKind.unreadable, "The file couldn't be read", e.msg);
            return null;
        }
        doc.access.fileLength = cast(c_ulong) doc.file.size;
        doc.access.getBlock = &readBlock;
        doc.access.param = cast(void*) doc;
        import std.string : toStringz;
        doc.handle = fn.FPDF_LoadCustomDocument(&doc.access, password.length ? password.toStringz : null);
        if (doc.handle)
        {
            doc.opened();
            return doc;
        }
        error = lastError(password);
        doc.file.close();
        return null;
    }

    PdfEngineDocument openMemory(immutable(ubyte)[] data, string password, out PdfError error)
    {
        auto doc = new PdfiumDocument(this);
        doc.memory = data; // PDFium reads from it for as long as the document's open
        import std.string : toStringz;
        doc.handle = fn.FPDF_LoadMemDocument64(data.ptr, data.length, password.length ? password.toStringz : null);
        if (doc.handle)
        {
            doc.opened();
            return doc;
        }
        error = lastError(password);
        return null;
    }

private:
    Functions fn;
    string loadedFrom;

    PdfError lastError(string password)
    {
        const code = fn.FPDF_GetLastError();
        switch (code)
        {
            case FPDF_ERR_PASSWORD:
                return PdfError(PdfErrorKind.wrongPassword,
                                password.length ? "That password isn't right" : "This PDF needs a password");
            case FPDF_ERR_FORMAT:
                return PdfError(PdfErrorKind.notPdf, "This isn't a PDF, or it's too damaged to open");
            case FPDF_ERR_FILE:
                return PdfError(PdfErrorKind.unreadable, "The file couldn't be read");
            case FPDF_ERR_SECURITY:
                return PdfError(PdfErrorKind.unsupported, "This PDF's security can't be read here");
            default:
                return PdfError(PdfErrorKind.other, "The PDF couldn't be opened", "PDFium error " ~ toText(code));
        }
    }

    /// Where PDFium's looked for, in order.
    static string[] candidates()
    {
        import std.process : environment;
        version (Windows) enum file = "pdfium.dll", folder = "bin";
        else version (OSX) enum file = "libpdfium.dylib", folder = "lib";
        else enum file = "libpdfium.so", folder = "lib";
        string[] found;
        if (auto given = environment.get("MAYFAIR_PDFIUM"))
            found ~= given;
        try
            found ~= buildPath(dirName(thisExePath), file);
        catch (Exception) {}
        // source/mayfair/pdf/pdfium/package.d, four folders down from the package
        found ~= buildPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..", "pdfium", folder, file);
        string[] there;
        foreach (f; found)
            if (exists(f))
                there ~= f;
        return there ~ file; // and the system's, by its name
    }

    static string toText(c_ulong n)
    {
        import std.conv : to;
        return n.to!string;
    }
}

/// A PDF, opened by PDFium.
final class PdfiumDocument : PdfEngineDocument, PdfEditableDocument, PdfFormDocument
{
    int pageCount() { return fn.FPDF_GetPageCount(handle); }

    PdfSize pageSize(int index)
    {
        FS_SIZEF s;
        if (!fn.FPDF_GetPageSizeByIndexF(handle, index, &s))
            return PdfSize.init;
        return PdfSize(s.width, s.height);
    }

    string[string] metadata()
    {
        string[string] found;
        foreach (tag; ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate"])
        {
            import std.string : toStringz;
            const t = tag.toStringz;
            const bytes = fn.FPDF_GetMetaText(handle, t, null, 0);
            if (bytes <= 2)
                continue;
            auto buffer = new ushort[bytes / 2];
            fn.FPDF_GetMetaText(handle, t, buffer.ptr, bytes);
            if (auto value = utf16(buffer))
                found[tag] = value;
        }
        return found;
    }

    PdfDocumentInfo info()
    {
        PdfDocumentInfo i;
        int v;
        if (fn.FPDF_GetFileVersion(handle, &v) && v > 0)
        {
            import std.format : format;
            i.pdfVersion = format!"%s.%s"(v / 10, v % 10);
        }
        i.encrypted = fn.FPDF_GetSecurityHandlerRevision(handle) != -1;
        i.hasForm = form !is null;
        i.editable = true;
        return i;
    }

    PdfOutlineItem[] outline()
    {
        size_t seen;
        PdfOutlineItem[] under(void* parent, int depth)
        {
            PdfOutlineItem[] items;
            if (depth > 32)
                return items;
            for (auto b = fn.FPDFBookmark_GetFirstChild(handle, parent); b && seen < 10_000;
                 b = fn.FPDFBookmark_GetNextSibling(handle, b))
            {
                seen++;
                PdfOutlineItem item;
                const bytes = fn.FPDFBookmark_GetTitle(b, null, 0);
                if (bytes > 2)
                {
                    auto buffer = new ushort[bytes / 2];
                    fn.FPDFBookmark_GetTitle(b, buffer.ptr, bytes);
                    item.title = utf16(buffer);
                }
                auto dest = fn.FPDFBookmark_GetDest(handle, b);
                if (!dest)
                    if (auto action = fn.FPDFBookmark_GetAction(b))
                        if (fn.FPDFAction_GetType(action) == PDFACTION_GOTO)
                            dest = fn.FPDFAction_GetDest(handle, action);
                if (dest)
                    destination(dest, item.page, item.y);
                item.children = under(b, depth + 1);
                items ~= item;
            }
            return items;
        }
        return under(null, 0);
    }

    bool render(int index, PdfRect region, float scale, int quarterTurns, uint[] pixels, uint width, uint height)
    {
        auto page = loadPage(index);
        if (!page || pixels.length < width * height)
            return false;
        auto bitmap = fn.FPDFBitmap_CreateEx(width, height, FPDFBitmap_BGRA, pixels.ptr, width * 4);
        if (!bitmap)
            return false;
        scope (exit) fn.FPDFBitmap_Destroy(bitmap);
        fn.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
        // The page's points, turned, scaled, and moved so `region` is at the bitmap's top left
        const size = pageSize(index), w = size.width, h = size.height, s = scale;
        const ox = region.x, oy = region.y;
        FS_MATRIX m;
        final switch (quarterTurns & 3)
        {
            case 0: m = FS_MATRIX(s, 0, 0, s, -ox * s, -oy * s); break;
            case 1: m = FS_MATRIX(0, s, -s, 0, (h - ox) * s, -oy * s); break;
            case 2: m = FS_MATRIX(-s, 0, 0, -s, (w - ox) * s, (h - oy) * s); break;
            case 3: m = FS_MATRIX(0, -s, s, 0, -ox * s, (w - oy) * s); break;
        }
        auto clip = FS_RECTF(0, 0, width, height);
        fn.FPDF_RenderPageBitmapWithMatrix(bitmap, page, &m, &clip, FPDF_ANNOT);
        if (form)
        {
            // The form's fields, over it: the one being filled in as it's being filled in. PDFium
            // draws them only in whole pixels, at a page's whole size, turned
            import std.math : lround;
            const turned = (quarterTurns & 1) != 0;
            const fw = cast(int) lround((turned ? h : w) * s), fh = cast(int) lround((turned ? w : h) * s);
            fn.FPDF_FFLDraw(form, bitmap, page, cast(int) -lround(ox * s), cast(int) -lround(oy * s), fw, fh,
                            quarterTurns & 3, FPDF_ANNOT);
        }
        return true;
    }

    PdfPageText text(int index)
    {
        auto page = loadPage(index);
        if (!page)
            return new PdfPageText(null, null);
        auto tp = fn.FPDFText_LoadPage(page);
        if (!tp)
            return new PdfPageText(null, null);
        scope (exit) fn.FPDFText_ClosePage(tp);
        const g = geometry(index);
        const n = fn.FPDFText_CountChars(tp);
        dchar[] chars;
        PdfRect[] boxes;
        chars.reserve(n);
        boxes.reserve(n);
        for (int i = 0; i < n; i++)
        {
            dchar c = fn.FPDFText_GetUnicode(tp, i);
            auto box = charBox(g, tp, i);
            // A character beyond the first 65536 comes as two halves
            if (c >= 0xD800 && c < 0xDC00 && i + 1 < n)
            {
                const low = fn.FPDFText_GetUnicode(tp, i + 1);
                if (low >= 0xDC00 && low < 0xE000)
                {
                    c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                    box = box.union_(charBox(g, tp, i + 1));
                    i++;
                }
            }
            chars ~= c;
            boxes ~= box;
        }
        return new PdfPageText(chars, boxes);
    }

    PdfLink[] links(int index)
    {
        auto page = loadPage(index);
        if (!page)
            return null;
        const g = geometry(index);
        PdfLink[] found;
        // The PDF's own: link annotations
        int position;
        void* annotation;
        while (fn.FPDFLink_Enumerate(page, &position, &annotation))
        {
            PdfLink link;
            FS_RECTF r;
            if (fn.FPDFLink_GetAnnotRect(annotation, &r))
                link.areas ~= g.rectToShown(r.left, r.top, r.right, r.bottom);
            auto dest = fn.FPDFLink_GetDest(handle, annotation);
            if (!dest)
                if (auto action = fn.FPDFLink_GetAction(annotation))
                {
                    const type = fn.FPDFAction_GetType(action);
                    if (type == PDFACTION_GOTO)
                        dest = fn.FPDFAction_GetDest(handle, action);
                    else if (type == PDFACTION_URI)
                    {
                        const bytes = fn.FPDFAction_GetURIPath(handle, action, null, 0);
                        if (bytes > 1)
                        {
                            auto buffer = new char[bytes];
                            fn.FPDFAction_GetURIPath(handle, action, buffer.ptr, bytes);
                            link.uri = buffer[0 .. bytes - 1].idup;
                        }
                    }
                }
            if (dest)
                destination(dest, link.page, link.y);
            if (link.areas.length && (link.page >= 0 || link.uri.length))
                found ~= link;
        }
        // Web addresses written in the text, as most readers make links of
        if (auto tp = fn.FPDFText_LoadPage(page))
        {
            scope (exit) fn.FPDFText_ClosePage(tp);
            if (auto web = fn.FPDFLink_LoadWebLinks(tp))
            {
                scope (exit) fn.FPDFLink_CloseWebLinks(web);
                foreach (k; 0 .. fn.FPDFLink_CountWebLinks(web))
                {
                    const chars = fn.FPDFLink_GetURL(web, k, null, 0);
                    if (chars <= 1)
                        continue;
                    auto buffer = new ushort[chars];
                    fn.FPDFLink_GetURL(web, k, buffer.ptr, chars);
                    PdfLink link;
                    link.uri = utf16(buffer);
                    foreach (j; 0 .. fn.FPDFLink_CountRects(web, k))
                    {
                        double l, t, r, b;
                        if (fn.FPDFLink_GetRect(web, k, j, &l, &t, &r, &b))
                            link.areas ~= g.rectToShown(l, t, r, b);
                    }
                    // Not where the PDF has a link already
                    bool covered;
                    foreach (other; found)
                        foreach (a; other.areas)
                            foreach (b; link.areas)
                                if (a.intersects(b))
                                    covered = true;
                    if (link.areas.length && !covered)
                        found ~= link;
                }
            }
        }
        return found;
    }

    void close()
    {
        closePages();
        if (form)
            fn.FPDFDOC_ExitFormFillEnvironment(form);
        form = null;
        if (handle)
            fn.FPDF_CloseDocument(handle);
        handle = null;
        if (file.isOpen)
            file.close();
        memory = null;
    }

    // Editing

    bool save(void delegate(const(ubyte)[]) write, bool removeSecurity, out string failure)
    {
        static struct Writer
        {
            FPDF_FILEWRITE fw;
            void delegate(const(ubyte)[]) sink;
            bool failed;
        }
        extern (C) static int writeBlock(FPDF_FILEWRITE* self, const(void)* data, c_ulong size) nothrow
        {
            auto w = cast(Writer*) self; // fw is its first member
            try
                w.sink((cast(const(ubyte)*) data)[0 .. size]);
            catch (Exception)
            {
                w.failed = true;
                return 0;
            }
            return 1;
        }
        Writer w;
        w.fw.WriteBlock = &writeBlock;
        w.sink = write;
        const flags = FPDF_NO_INCREMENTAL | (removeSecurity ? FPDF_REMOVE_SECURITY : 0);
        if (!fn.FPDF_SaveAsCopy(handle, &w.fw, flags) || w.failed)
        {
            failure = w.failed ? "it couldn't be written" : "PDFium couldn't save it";
            return false;
        }
        return true;
    }

    bool rotatePage(int index, int quarterTurns)
    {
        auto page = loadPage(index);
        if (!page)
            return false;
        fn.FPDFPage_SetRotation(page, (fn.FPDFPage_GetRotation(page) + quarterTurns) & 3);
        closePages(); // their sizes, and the form's idea of them, change
        return true;
    }

    bool deletePage(int index)
    {
        if (index < 0 || index >= pageCount)
            return false;
        closePages();
        fn.FPDFPage_Delete(handle, index);
        return true;
    }

    bool movePages(const int[] pages, int destination)
    {
        closePages();
        return fn.FPDF_MovePages(handle, pages.ptr, cast(c_ulong) pages.length, destination) != 0;
    }

    bool insertBlankPage(int index, PdfSize size)
    {
        closePages();
        auto page = fn.FPDFPage_New(handle, index, size.width, size.height);
        if (!page)
            return false;
        fn.FPDF_ClosePage(page);
        return true;
    }

    bool importPages(PdfEngineDocument from, const int[] pages, int index)
    {
        auto source = cast(PdfiumDocument) from;
        if (!source || !source.handle)
            return false;
        closePages();
        return fn.FPDF_ImportPagesByIndex(handle, source.handle, pages.ptr, cast(c_ulong) pages.length, index) != 0;
    }

    bool cropPage(int index, PdfRect rect)
    {
        auto page = loadPage(index);
        if (!page || rect.empty)
            return false;
        const g = geometry(index);
        float l, b, r, t;
        g.rectToPdf(rect, l, b, r, t);
        fn.FPDFPage_SetCropBox(page, l, b, r, t);
        closePages();
        return true;
    }

    PdfAnnotation[] annotations(int index)
    {
        auto page = loadPage(index);
        if (!page)
            return null;
        const g = geometry(index);
        PdfAnnotation[] list;
        const n = fn.FPDFPage_GetAnnotCount(page);
        foreach (i; 0 .. n)
        {
            auto annot = fn.FPDFPage_GetAnnot(page, i);
            if (!annot)
                continue;
            scope (exit) fn.FPDFPage_CloseAnnot(annot);
            const subtype = fn.FPDFAnnot_GetSubtype(annot);
            if (subtype == FPDF_ANNOT_LINK || subtype == FPDF_ANNOT_POPUP)
                continue;
            PdfAnnotation a;
            a.index = i;
            FS_RECTF r;
            if (fn.FPDFAnnot_GetRect(annot, &r))
                a.rect = g.rectToShown(r.left, r.top, r.right, r.bottom);
            a.text = stringValue(annot, "Contents");
            a.author = stringValue(annot, "T");
            a.modified = stringValue(annot, "M");
            if (!decodeData(stringValue(annot, "MayfairData"), a, (PdfPoint p) => g.toShown(p.x, p.y)))
                a.kind = kindOf(subtype);
            if (a.marksText)
            {
                const quads = fn.FPDFAnnot_CountAttachmentPoints(annot);
                foreach (q; 0 .. quads)
                {
                    FS_QUADPOINTSF qp;
                    if (fn.FPDFAnnot_GetAttachmentPoints(annot, q, &qp))
                    {
                        import std.algorithm : max, min;
                        a.lines ~= g.rectToShown(min(qp.x1, qp.x2, qp.x3, qp.x4), max(qp.y1, qp.y2, qp.y3, qp.y4),
                                                 max(qp.x1, qp.x2, qp.x3, qp.x4), min(qp.y1, qp.y2, qp.y3, qp.y4));
                    }
                }
            }
            if (subtype == FPDF_ANNOT_INK && !a.strokes.length)
                foreach (s; 0 .. fn.FPDFAnnot_GetInkListCount(annot))
                {
                    const count = fn.FPDFAnnot_GetInkListPath(annot, s, null, 0);
                    auto points = new FS_POINTF[count];
                    fn.FPDFAnnot_GetInkListPath(annot, s, points.ptr, count);
                    PdfPoint[] stroke;
                    foreach (p; points)
                        stroke ~= g.toShown(p.x, p.y);
                    a.strokes ~= stroke;
                }
            if (subtype == FPDF_ANNOT_LINE && !a.strokes.length)
            {
                FS_POINTF from, to;
                if (fn.FPDFAnnot_GetLine(annot, &from, &to))
                    a.strokes = [[g.toShown(from.x, from.y), g.toShown(to.x, to.y)]];
            }
            if (subtype == FPDF_ANNOT_WIDGET)
            {
                a.kind = PdfAnnotationKind.widget;
                a.fieldType = form ? fn.FPDFAnnot_GetFormFieldType(form, annot) : -1;
            }
            list ~= a;
        }
        return list;
    }

    int addAnnotation(int index, const ref PdfAnnotation a)
    {
        auto page = loadPage(index);
        if (!page)
            return -1;
        auto g = geometry(index);
        const subtype = subtypeFor(a.kind);
        if (subtype < 0)
            return -1;
        auto annot = fn.FPDFPage_CreateAnnot(page, subtype);
        if (!annot)
            return -1;
        scope (exit) fn.FPDFPage_CloseAnnot(annot);

        float l, b, r, t;
        g.rectToPdf(a.bounds, l, b, r, t);
        auto rect = FS_RECTF(l, t, r, b);
        fn.FPDFAnnot_SetRect(annot, &rect);
        fn.FPDFAnnot_SetFlags(annot, FPDF_ANNOT_FLAG_PRINT);
        bool native = true; // drawn by PDFium from what it is, rather than from objects of ours
        with (PdfAnnotationKind) switch (a.kind)
        {
            case highlight, underline, strikeOut, squiggly:
                colour(annot, FPDFANNOT_COLORTYPE_Color, a.colour);
                foreach (line; a.lines)
                {
                    float ll, lb, lr, lt;
                    g.rectToPdf(line, ll, lb, lr, lt);
                    auto q = FS_QUADPOINTSF(ll, lt, lr, lt, ll, lb, lr, lb);
                    fn.FPDFAnnot_AppendAttachmentPoints(annot, &q);
                }
                break;
            case note:
                colour(annot, FPDFANNOT_COLORTYPE_Color, a.colour);
                break;
            case rectangle, oval:
                colour(annot, FPDFANNOT_COLORTYPE_Color, a.colour);
                if (!a.fill.none)
                    colour(annot, FPDFANNOT_COLORTYPE_InteriorColor, a.fill);
                fn.FPDFAnnot_SetBorder(annot, 0, 0, a.lineWidth);
                break;
            case ink, signature:
                colour(annot, FPDFANNOT_COLORTYPE_Color, a.colour);
                fn.FPDFAnnot_SetBorder(annot, 0, 0, a.lineWidth);
                foreach (s; a.strokes)
                {
                    FS_POINTF[] points;
                    foreach (p; s)
                    {
                        const q = g.toPdf(p.x, p.y);
                        points ~= FS_POINTF(q.x, q.y);
                    }
                    if (points.length == 1)
                        points ~= points[0]; // a dot
                    if (points.length)
                        fn.FPDFAnnot_AddInkStroke(annot, points.ptr, points.length);
                }
                break;
            case textBox:
                native = false;
                if (!appendTextBox(annot, g, a))
                    return removeFailed(page, annot);
                break;
            default:
                native = false;
                if (!appendShapes(annot, g, a))
                    return removeFailed(page, annot);
                break;
        }
        if (a.text.length)
            setString(annot, "Contents", a.text);
        if (a.author.length)
            setString(annot, "T", a.author);
        setString(annot, "M", a.modified.length ? a.modified : pdfDateNow());
        setString(annot, "MayfairData", encodeData(a, (PdfPoint p) => g.toPdf(p.x, p.y)));
        const at = fn.FPDFPage_GetAnnotIndex(page, annot);
        if (native)
            drawOnce(page); // so PDFium makes its appearance now, which it saves with it
        if (form)
            closePages(); // the form keeps its own list of a page's annotations
        return at;
    }

    int updateAnnotation(int index, int which, const ref PdfAnnotation a)
    {
        auto page = loadPage(index);
        if (!page)
            return -1;
        auto annot = fn.FPDFPage_GetAnnot(page, which);
        if (!annot)
            return -1;
        const ours = stringValue(annot, "MayfairData").length > 0;
        if (!ours)
        {
            // Another app's: only moved, or stretched. Its appearance goes where its rectangle does
            scope (exit) fn.FPDFPage_CloseAnnot(annot);
            const g = geometry(index);
            float l, b, r, t;
            g.rectToPdf(a.rect, l, b, r, t);
            auto rect = FS_RECTF(l, t, r, b);
            if (!fn.FPDFAnnot_SetRect(annot, &rect))
                return -1;
            if (form)
                closePages();
            return which;
        }
        fn.FPDFPage_CloseAnnot(annot);
        if (!fn.FPDFPage_RemoveAnnot(page, which))
            return -1;
        return addAnnotation(index, a);
    }

    bool removeAnnotation(int index, int which)
    {
        auto page = loadPage(index);
        if (!page)
            return false;
        const ok = fn.FPDFPage_RemoveAnnot(page, which) != 0;
        if (form)
            closePages();
        return ok;
    }

    // Forms

    bool hasForm() { return form !is null; }

    void formEvents(PdfFormEvents events) { this.events = events; }

    bool formPointer(int page, PdfFormPointer what, float x, float y, uint modifiers)
    {
        auto p = loadPage(page);
        if (!form || !p)
            return false;
        currentPage = page;
        const q = geometry(page).toPdf(x, y);
        const m = flags(modifiers);
        final switch (what)
        {
            case PdfFormPointer.move: return fn.FORM_OnMouseMove(form, p, m, q.x, q.y) != 0;
            case PdfFormPointer.press: return fn.FORM_OnLButtonDown(form, p, m, q.x, q.y) != 0;
            case PdfFormPointer.release: return fn.FORM_OnLButtonUp(form, p, m, q.x, q.y) != 0;
            case PdfFormPointer.doubleClick: return fn.FORM_OnLButtonDoubleClick(form, p, m, q.x, q.y) != 0;
        }
    }

    bool formKey(int page, PdfFormKey key, bool pressed, uint modifiers)
    {
        auto p = loadPage(page);
        if (!form || !p)
            return false;
        int code;
        final switch (key)
        {
            case PdfFormKey.backspace: code = FWL_VKEY_Back; break;
            case PdfFormKey.tab: code = FWL_VKEY_Tab; break;
            case PdfFormKey.enter: code = FWL_VKEY_Return; break;
            case PdfFormKey.escape: code = FWL_VKEY_Escape; break;
            case PdfFormKey.left: code = FWL_VKEY_Left; break;
            case PdfFormKey.right: code = FWL_VKEY_Right; break;
            case PdfFormKey.up: code = FWL_VKEY_Up; break;
            case PdfFormKey.down: code = FWL_VKEY_Down; break;
            case PdfFormKey.home: code = FWL_VKEY_Home; break;
            case PdfFormKey.end: code = FWL_VKEY_End; break;
            case PdfFormKey.pageUp: code = FWL_VKEY_Prior; break;
            case PdfFormKey.pageDown: code = FWL_VKEY_Next; break;
            case PdfFormKey.delete_: code = FWL_VKEY_Delete; break;
        }
        const m = flags(modifiers);
        if (!pressed)
            return fn.FORM_OnKeyUp(form, p, code, m) != 0;
        bool took = fn.FORM_OnKeyDown(form, p, code, m) != 0;
        // As Windows sends them, which PDFium's fields expect: a character for these as well
        if (key == PdfFormKey.backspace)
            took |= fn.FORM_OnChar(form, p, 8, m) != 0;
        else if (key == PdfFormKey.enter)
            took |= fn.FORM_OnChar(form, p, 13, m) != 0;
        return took;
    }

    bool formText(int page, string text)
    {
        auto p = loadPage(page);
        if (!form || !p || !text.length)
            return false;
        wstring units;
        try
            units = toUTF16(text);
        catch (Exception)
            return false;
        if (units.length <= 2)
        {
            bool took;
            foreach (u; units)
                took |= fn.FORM_OnChar(form, p, u, 0) != 0;
            return took;
        }
        auto w = wide(text);
        fn.FORM_ReplaceSelection(form, p, w.ptr);
        return true;
    }

    string formSelectedText(int page)
    {
        auto p = loadPage(page);
        if (!form || !p)
            return null;
        const bytes = fn.FORM_GetSelectedText(form, p, null, 0);
        if (bytes <= 2)
            return null;
        auto buffer = new ushort[bytes / 2];
        fn.FORM_GetSelectedText(form, p, buffer.ptr, bytes);
        return utf16(buffer);
    }

    void formSelectAll(int page)
    {
        if (auto p = loadPage(page))
            if (form)
                fn.FORM_SelectAllText(form, p);
    }

    bool formUndo(int page)
    {
        auto p = loadPage(page);
        return form && p && fn.FORM_Undo(form, p);
    }

    bool formRedo(int page)
    {
        auto p = loadPage(page);
        return form && p && fn.FORM_Redo(form, p);
    }

    void formBlur()
    {
        if (form)
            fn.FORM_ForceToKillFocus(form);
    }

    bool formFocused(out int page)
    {
        if (!form)
            return false;
        void* annot;
        int index = -1;
        if (!fn.FORM_GetFocusedAnnot(form, &index, &annot) || !annot)
            return false;
        fn.FPDFPage_CloseAnnot(annot);
        page = index;
        return index >= 0;
    }

private:
    PdfiumEngine engine;
    void* handle, form;
    File file;
    immutable(ubyte)[] memory;
    FPDF_FILEACCESS access;
    FormCallbacks* callbacks; // kept here, so the collector keeps it while PDFium has it
    PdfFormEvents events;
    int currentPage;

    // A few pages kept loaded: loading one is most of reading its text, links or a tile of it
    struct Loaded { int index; void* handle; Geometry geometry; }
    Loaded[] pages;
    enum keepPages = 8;
    bool keepingAll; // while PDFium's form asks for pages: none closed under it

    this(PdfiumEngine engine) { this.engine = engine; }

    ref Functions fn() { return engine.fn; }

    /// Just opened: its form, if it has one, made ready to fill in.
    void opened()
    {
        if (fn.FPDF_GetFormType(handle) == FORMTYPE_NONE)
            return;
        callbacks = new FormCallbacks;
        callbacks.document = this;
        with (callbacks.info)
        {
            FFI_Invalidate = &formInvalidate;
            FFI_OutputSelectedRect = &formRect;
            FFI_SetCursor = &formCursor;
            FFI_SetTimer = &formSetTimer;
            FFI_KillTimer = &formKillTimer;
            FFI_GetLocalTime = &formLocalTime;
            FFI_OnChange = &formChange;
            FFI_GetPage = &formGetPage;
            FFI_GetCurrentPage = &formCurrentPage;
            FFI_GetRotation = &formRotation;
            FFI_ExecuteNamedAction = &formNamedAction;
            FFI_SetTextFieldFocus = &formTextFocus;
            FFI_DoURIAction = &formUri;
            FFI_DoGoToAction = &formGoTo;
        }
        form = fn.FPDFDOC_InitFormFillEnvironment(handle, &callbacks.info);
        if (form)
        {
            // Fields lightly tinted, so it's clear what can be filled in
            fn.FPDF_SetFormFieldHighlightColor(form, 0, 0xFFE6DD); // light blue: PDFium has it as 0xBBGGRR
            fn.FPDF_SetFormFieldHighlightAlpha(form, 110);
        }
    }

    void* loadPage(int index)
    {
        foreach (i, p; pages)
            if (p.index == index)
            {
                // Most recently used at the end
                pages = pages[0 .. i] ~ pages[i + 1 .. $] ~ p;
                return p.handle;
            }
        auto h = fn.FPDF_LoadPage(handle, index);
        if (!h)
            return null;
        if (pages.length >= keepPages && !keepingAll)
        {
            closePage(pages[0].handle);
            pages = pages[1 .. $];
        }
        pages ~= Loaded(index, h, measure(h, index));
        if (form)
            fn.FORM_OnAfterLoadPage(h, form);
        return h;
    }

    void closePage(void* h)
    {
        if (form)
            fn.FORM_OnBeforeClosePage(h, form);
        fn.FPDF_ClosePage(h);
    }

    /// Lets go of every page loaded: before an edit that changes which page is which, or their sizes.
    void closePages()
    {
        foreach (p; pages)
            closePage(p.handle);
        pages = null;
    }

    int indexOf(void* page) nothrow
    {
        foreach (p; pages)
            if (p.handle is page)
                return p.index;
        return -1;
    }

    /// How page `index`'s shown points and its PDF ones go into each other: loading it if it isn't.
    Geometry geometry(int index)
    {
        loadPage(index);
        foreach (p; pages)
            if (p.index == index)
                return p.geometry;
        return Geometry.init;
    }

    /*
        A page's shown points -- from its top left, as it's shown -- to its PDF ones, from FPDF_DeviceToPage
        at three corners: it's an affine map, a quarter turn and a flip at most, so three say it all.
    */
    Geometry measure(void* page, int index)
    {
        const size = pageSize(index);
        enum fine = 16;
        const sw = cast(int) (size.width * fine + 0.5f), sh = cast(int) (size.height * fine + 0.5f);
        double x0, y0, x1, y1, x2, y2;
        fn.FPDF_DeviceToPage(page, 0, 0, sw, sh, 0, 0, 0, &x0, &y0);
        fn.FPDF_DeviceToPage(page, 0, 0, sw, sh, 0, sw, 0, &x1, &y1);
        fn.FPDF_DeviceToPage(page, 0, 0, sw, sh, 0, 0, sh, &x2, &y2);
        Geometry g;
        if (size.width <= 0 || size.height <= 0)
            return g;
        g.a = (x1 - x0) / size.width;
        g.b = (y1 - y0) / size.width;
        g.c = (x2 - x0) / size.height;
        g.d = (y2 - y0) / size.height;
        g.e = x0;
        g.f = y0;
        return g;
    }

    PdfRect charBox(const ref Geometry g, void* tp, int i)
    {
        double l, r, b, t;
        if (!fn.FPDFText_GetCharBox(tp, i, &l, &r, &b, &t) || r <= l || t <= b)
            return PdfRect.init; // a character PDFium put in: a space, a line break
        return g.rectToShown(l, t, r, b);
    }

    /// Where a destination goes: its page, and how far down it, if it says.
    void destination(void* dest, out int page, out float y)
    {
        page = fn.FPDFDest_GetDestPageIndex(handle, dest);
        y = float.nan;
        FPDF_BOOL hasX, hasY, hasZoom;
        float x, py, zoom;
        if (page >= 0 && fn.FPDFDest_GetLocationInPage(dest, &hasX, &hasY, &hasZoom, &x, &py, &zoom) && hasY)
            y = geometry(page).toShown(0, py).y;
    }

    // Annotations

    static PdfAnnotationKind kindOf(int subtype)
    {
        with (PdfAnnotationKind) switch (subtype)
        {
            case FPDF_ANNOT_HIGHLIGHT: return highlight;
            case FPDF_ANNOT_UNDERLINE: return underline;
            case FPDF_ANNOT_STRIKEOUT: return strikeOut;
            case FPDF_ANNOT_SQUIGGLY: return squiggly;
            case FPDF_ANNOT_TEXT: return note;
            case FPDF_ANNOT_FREETEXT: return textBox;
            case FPDF_ANNOT_SQUARE: return rectangle;
            case FPDF_ANNOT_CIRCLE: return oval;
            case FPDF_ANNOT_LINE: return line;
            case FPDF_ANNOT_INK: return ink;
            case FPDF_ANNOT_WIDGET: return widget;
            default: return other;
        }
    }

    /// The PDF annotation an annotation of Mayfair's is made as: -1 for none.
    static int subtypeFor(PdfAnnotationKind kind)
    {
        with (PdfAnnotationKind) final switch (kind)
        {
            case highlight: return FPDF_ANNOT_HIGHLIGHT;
            case underline: return FPDF_ANNOT_UNDERLINE;
            case strikeOut: return FPDF_ANNOT_STRIKEOUT;
            case squiggly: return FPDF_ANNOT_SQUIGGLY;
            case note: return FPDF_ANNOT_TEXT;
            case rectangle: return FPDF_ANNOT_SQUARE;
            case oval: return FPDF_ANNOT_CIRCLE;
            case ink, signature: return FPDF_ANNOT_INK;
            // Drawn with objects of ours: shapes PDFium doesn't draw itself, and text, as stamps
            case textBox, roundedRectangle, star, speechBubble, line, arrow: return FPDF_ANNOT_STAMP;
            case other, widget: return -1;
        }
    }

    void colour(void* annot, int type, PdfColour c)
    {
        fn.FPDFAnnot_SetColor(annot, type, c.r, c.g, c.b, c.a);
    }

    int removeFailed(void* page, void* annot)
    {
        const at = fn.FPDFPage_GetAnnotIndex(page, annot);
        if (at >= 0)
            fn.FPDFPage_RemoveAnnot(page, at);
        return -1;
    }

    /// A shape's outlines, as path objects in the annotation's appearance.
    bool appendShapes(void* annot, const ref Geometry g, const ref PdfAnnotation a)
    {
        auto shapes = shapePath(a);
        if (!shapes.length)
            return false;
        foreach (s; shapes)
        {
            auto path = pathObject(g, s.ops);
            if (!path)
                return false;
            const fill = s.fillWithColour ? a.colour : a.fill;
            const filled = s.filled && !fill.none;
            if (filled)
                fn.FPDFPageObj_SetFillColor(path, fill.r, fill.g, fill.b, fill.a);
            if (s.stroked)
            {
                fn.FPDFPageObj_SetStrokeColor(path, a.colour.r, a.colour.g, a.colour.b, a.colour.a);
                fn.FPDFPageObj_SetStrokeWidth(path, a.lineWidth);
                fn.FPDFPageObj_SetLineCap(path, FPDF_LINECAP_ROUND);
                fn.FPDFPageObj_SetLineJoin(path, FPDF_LINEJOIN_ROUND);
            }
            fn.FPDFPath_SetDrawMode(path, filled ? FPDF_FILLMODE_WINDING : FPDF_FILLMODE_NONE, s.stroked);
            if (!fn.FPDFAnnot_AppendObject(annot, path))
            {
                fn.FPDFPageObj_Destroy(path);
                return false;
            }
        }
        return true;
    }

    void* pathObject(const ref Geometry g, const PdfPathOp[] ops)
    {
        if (!ops.length)
            return null;
        const start = g.toPdf(ops[0].points[0].x, ops[0].points[0].y);
        auto path = fn.FPDFPageObj_CreateNewPath(start.x, start.y);
        if (!path)
            return null;
        foreach (op; ops[1 .. $])
        {
            final switch (op.kind)
            {
                case PdfPathOp.Kind.moveTo:
                    const p = g.toPdf(op.points[0].x, op.points[0].y);
                    fn.FPDFPath_MoveTo(path, p.x, p.y);
                    break;
                case PdfPathOp.Kind.lineTo:
                    const p = g.toPdf(op.points[0].x, op.points[0].y);
                    fn.FPDFPath_LineTo(path, p.x, p.y);
                    break;
                case PdfPathOp.Kind.cubicTo:
                    const p1 = g.toPdf(op.points[0].x, op.points[0].y);
                    const p2 = g.toPdf(op.points[1].x, op.points[1].y);
                    const p3 = g.toPdf(op.points[2].x, op.points[2].y);
                    fn.FPDFPath_BezierTo(path, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
                    break;
                case PdfPathOp.Kind.close:
                    fn.FPDFPath_Close(path);
                    break;
            }
        }
        return path;
    }

    /*
        A text box: its box, if it's filled, then its text, a line at a time, wrapped
        to the box's width, in Helvetica -- one of the fonts every PDF reader has, so nothing's
        embedded. Upright on the page as it's shown, however the page is turned.
    */
    bool appendTextBox(void* annot, const ref Geometry g, const ref PdfAnnotation a)
    {
        const r = a.rect;
        if (!a.fill.none)
        {
            PdfAnnotation box = a.copy();
            box.kind = PdfAnnotationKind.rectangle;
            box.lineWidth = 0;
            auto shapes = shapePath(box);
            auto path = pathObject(g, shapes[0].ops);
            fn.FPDFPageObj_SetFillColor(path, a.fill.r, a.fill.g, a.fill.b, a.fill.a);
            fn.FPDFPath_SetDrawMode(path, FPDF_FILLMODE_WINDING, false);
            if (!fn.FPDFAnnot_AppendObject(annot, path))
            {
                fn.FPDFPageObj_Destroy(path);
                return false;
            }
        }
        enum padding = 4f, ascent = 0.718f, leading = 1.2f;
        const size = a.fontSize > 0 ? a.fontSize : 12;
        auto lines = wrap(a.text, size, r.width - 2 * padding);
        // The text's x axis, and its up, in the PDF: the page's shown right, and shown up
        const ax = g.a, ay = g.b, ux = -g.c, uy = -g.d;
        foreach (i, line; lines)
        {
            if (!line.length)
                continue;
            const baseline = r.y + padding + size * ascent + i * size * leading;
            if (baseline > r.bottom + size)
                break;
            auto obj = textObject(line, size);
            if (!obj)
                return false;
            fn.FPDFPageObj_SetFillColor(obj, a.colour.r, a.colour.g, a.colour.b, a.colour.a);
            const at = g.toPdf(r.x + padding, baseline);
            fn.FPDFPageObj_Transform(obj, ax, ay, ux, uy, at.x, at.y);
            if (!fn.FPDFAnnot_AppendObject(annot, obj))
            {
                fn.FPDFPageObj_Destroy(obj);
                return false;
            }
        }
        return true;
    }

    void* textObject(string text, float size)
    {
        auto obj = fn.FPDFPageObj_NewTextObj(handle, "Helvetica", size);
        if (!obj)
            return null;
        auto w = wide(text);
        fn.FPDFText_SetText(obj, w.ptr);
        return obj;
    }

    /// How wide `text` is, in Helvetica `size` points.
    float textWidth(string text, float size)
    {
        auto obj = textObject(text, size);
        if (!obj)
            return 0;
        scope (exit) fn.FPDFPageObj_Destroy(obj);
        float l, b, r, t;
        if (!fn.FPDFPageObj_GetBounds(obj, &l, &b, &r, &t))
            return 0;
        return r - l;
    }

    /// `text`'s lines, broken where it breaks them and between words, to fit `width`.
    string[] wrap(string text, float size, float width)
    {
        import std.array : split;
        import std.string : lineSplitter;
        string[] lines;
        foreach (paragraph; text.lineSplitter)
        {
            string line;
            foreach (word; paragraph.split(" "))
            {
                const tried = line.length ? line ~ " " ~ word : word;
                if (line.length && textWidth(tried, size) > width)
                {
                    lines ~= line;
                    line = word;
                }
                else
                    line = tried;
            }
            lines ~= line;
        }
        return lines;
    }

    /// Draws the page once, small, so PDFium makes the appearances of annotations that haven't one.
    void drawOnce(void* page)
    {
        uint[1] pixel;
        auto bitmap = fn.FPDFBitmap_CreateEx(1, 1, FPDFBitmap_BGRA, pixel.ptr, 4);
        if (!bitmap)
            return;
        fn.FPDF_RenderPageBitmap(bitmap, page, 0, 0, 1, 1, 0, FPDF_ANNOT);
        fn.FPDFBitmap_Destroy(bitmap);
    }

    string stringValue(void* annot, string key)
    {
        import std.string : toStringz;
        const k = key.toStringz;
        const bytes = fn.FPDFAnnot_GetStringValue(annot, k, null, 0);
        if (bytes <= 2)
            return null;
        auto buffer = new ushort[bytes / 2];
        fn.FPDFAnnot_GetStringValue(annot, k, buffer.ptr, bytes);
        return utf16(buffer);
    }

    void setString(void* annot, string key, string value)
    {
        import std.string : toStringz;
        auto w = wide(value);
        fn.FPDFAnnot_SetStringValue(annot, key.toStringz, w.ptr);
    }

    static int flags(uint modifiers)
    {
        int m;
        if (modifiers & PdfFormModifiers.shift) m |= FWL_EVENTFLAG_ShiftKey;
        if (modifiers & PdfFormModifiers.control) m |= FWL_EVENTFLAG_ControlKey;
        if (modifiers & PdfFormModifiers.alt) m |= FWL_EVENTFLAG_AltKey;
        return m;
    }

    static ushort[] wide(string s)
    {
        ushort[] units;
        try
            units = cast(ushort[]) toUTF16(s).dup;
        catch (Exception) {}
        return units ~ cast(ushort) 0;
    }

    static string utf16(ushort[] buffer)
    {
        size_t end;
        while (end < buffer.length && buffer[end])
            end++;
        try
            return toUTF8(cast(wchar[]) buffer[0 .. end]);
        catch (Exception)
            return null;
    }

    /// Now, as PDF writes a date: "D:20261124093000".
    static string pdfDateNow()
    {
        import std.datetime.systime : Clock;
        import std.format : format;
        try
        {
            const t = Clock.currTime;
            return format!"D:%04d%02d%02d%02d%02d%02d"(t.year, t.month, t.day, t.hour, t.minute, t.second);
        }
        catch (Exception)
            return null;
    }
}

/*
    A page's shown points -- from its top left, y going down, its /Rotate applied -- and its PDF
    points, into each other: pdf = (a x + c y + e, b x + d y + f).
*/
struct Geometry
{
    double a = 1, b = 0, c = 0, d = -1, e = 0, f = 0;

    PdfPoint toPdf(double x, double y) const pure nothrow @nogc
    {
        return PdfPoint(cast(float) (a * x + c * y + e), cast(float) (b * x + d * y + f));
    }

    PdfPoint toShown(double px, double py) const pure nothrow @nogc
    {
        const det = a * d - b * c;
        if (det == 0)
            return PdfPoint.init;
        const x = px - e, y = py - f;
        return PdfPoint(cast(float) ((d * x - c * y) / det), cast(float) ((-b * x + a * y) / det));
    }

    /// A rectangle given by two of its corners in the PDF's points, as it's shown.
    PdfRect rectToShown(double left, double top, double right, double bottom) const pure nothrow @nogc
    {
        const p = toShown(left, top), q = toShown(right, bottom);
        const l = p.x < q.x ? p.x : q.x, t = p.y < q.y ? p.y : q.y;
        const r = p.x < q.x ? q.x : p.x, bt = p.y < q.y ? q.y : p.y;
        return PdfRect(l, t, r - l, bt - t);
    }

    /// A shown rectangle in the PDF's points: its left, bottom, right and top there.
    void rectToPdf(PdfRect rect, out float left, out float bottom, out float right, out float top) const pure nothrow @nogc
    {
        const p = toPdf(rect.x, rect.y), q = toPdf(rect.right, rect.bottom);
        left = p.x < q.x ? p.x : q.x;
        right = p.x < q.x ? q.x : p.x;
        bottom = p.y < q.y ? p.y : q.y;
        top = p.y < q.y ? q.y : p.y;
    }
}

unittest
{
    // A page 600 by 800, upright: y flips
    auto g = Geometry(1, 0, 0, -1, 0, 800);
    assert(g.toPdf(10, 20) == PdfPoint(10, 780));
    assert(g.toShown(10, 780) == PdfPoint(10, 20));
    float l, b, r, t;
    g.rectToPdf(PdfRect(10, 20, 30, 40), l, b, r, t);
    assert(l == 10 && r == 40 && t == 780 && b == 740);
    assert(g.rectToShown(l, t, r, b) == PdfRect(10, 20, 30, 40));
}

/// What PDFium's form calls back to: its callbacks, then the document they're for.
struct FormCallbacks
{
    FPDF_FORMFILLINFO info;
    PdfiumDocument document;
}

private PdfiumDocument documentOf(FPDF_FORMFILLINFO* info) nothrow
{
    return (cast(FormCallbacks*) info).document;
}

extern (C) nothrow
{
    void formInvalidate(FPDF_FORMFILLINFO* info, void* page, double, double, double, double)
    {
        auto doc = documentOf(info);
        const index = doc.indexOf(page);
        if (index >= 0 && doc.events.redraw)
            doc.events.redraw(index);
    }

    void formRect(FPDF_FORMFILLINFO*, void*, double, double, double, double) {}
    void formCursor(FPDF_FORMFILLINFO*, int) {}

    // A caret that doesn't blink: the timer's never run
    int formSetTimer(FPDF_FORMFILLINFO* info, int, void function(int)) { return ++timers; }
    void formKillTimer(FPDF_FORMFILLINFO*, int) {}

    FPDF_SYSTEMTIME formLocalTime(FPDF_FORMFILLINFO*)
    {
        import core.stdc.time : localtime, time, time_t;
        FPDF_SYSTEMTIME st;
        time_t now = time(null);
        if (auto t = localtime(&now))
        {
            st.wYear = cast(ushort) (t.tm_year + 1900);
            st.wMonth = cast(ushort) (t.tm_mon + 1);
            st.wDayOfWeek = cast(ushort) t.tm_wday;
            st.wDay = cast(ushort) t.tm_mday;
            st.wHour = cast(ushort) t.tm_hour;
            st.wMinute = cast(ushort) t.tm_min;
            st.wSecond = cast(ushort) t.tm_sec;
        }
        return st;
    }

    void formChange(FPDF_FORMFILLINFO* info)
    {
        auto doc = documentOf(info);
        if (doc.events.changed)
            doc.events.changed();
    }

    void* formGetPage(FPDF_FORMFILLINFO* info, void*, int index)
    {
        auto doc = documentOf(info);
        try
        {
            doc.keepingAll = true;
            scope (exit) doc.keepingAll = false;
            return doc.loadPage(index);
        }
        catch (Exception)
            return null;
    }

    void* formCurrentPage(FPDF_FORMFILLINFO* info, void* document)
    {
        return formGetPage(info, document, documentOf(info).currentPage);
    }

    int formRotation(FPDF_FORMFILLINFO*, void*) { return 0; }
    void formNamedAction(FPDF_FORMFILLINFO*, const(char)*) {}
    void formTextFocus(FPDF_FORMFILLINFO*, const(ushort)*, c_ulong, int) {}
    void formUri(FPDF_FORMFILLINFO*, const(char)*) {}
    void formGoTo(FPDF_FORMFILLINFO*, int, int, float*, int) {}
}

private __gshared int timers;

/// PDFium asks for a block of the file: on the PDF thread.
extern (C) int readBlock(void* param, c_ulong position, ubyte* buffer, c_ulong size) nothrow
{
    auto doc = cast(PdfiumDocument) param;
    try
    {
        doc.file.seek(position);
        return doc.file.rawRead(buffer[0 .. size]).length == size;
    }
    catch (Exception)
        return 0;
}
