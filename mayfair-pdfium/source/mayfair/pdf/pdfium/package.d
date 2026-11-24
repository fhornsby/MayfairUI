module mayfair.pdf.pdfium;

/*
    A PdfEngine on PDFium: Google's PDF library, Chrome's, BSD-3-Clause and Apache-2.0 licensed.

        import mayfair.pdf;
        import mayfair.pdf.pdfium;

        PdfDocument.setEngine(new PdfiumEngine);

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

    Everything here runs on mayfair-pdf's PDF thread, one call at a time, as PDFium needs.
*/

public import mayfair.pdf;
import core.stdc.config : c_ulong;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.stdio : File;
import std.utf : toUTF8;
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
            return doc;

        const code = fn.FPDF_GetLastError();
        switch (code)
        {
            case FPDF_ERR_PASSWORD:
                error = PdfError(PdfErrorKind.wrongPassword,
                                 password.length ? "That password isn't right" : "This PDF needs a password");
                break;
            case FPDF_ERR_FORMAT:
                error = PdfError(PdfErrorKind.notPdf, "This isn't a PDF, or it's too damaged to open");
                break;
            case FPDF_ERR_FILE:
                error = PdfError(PdfErrorKind.unreadable, "The file couldn't be read");
                break;
            case FPDF_ERR_SECURITY:
                error = PdfError(PdfErrorKind.unsupported, "This PDF's security can't be read here");
                break;
            default:
                error = PdfError(PdfErrorKind.other, "The PDF couldn't be opened", "PDFium error " ~ toText(code));
                break;
        }
        doc.file.close();
        return null;
    }

private:
    Functions fn;
    string loadedFrom;

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
final class PdfiumDocument : PdfEngineDocument
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
        foreach (tag; ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"])
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
        const n = fn.FPDFText_CountChars(tp);
        dchar[] chars;
        PdfRect[] boxes;
        chars.reserve(n);
        boxes.reserve(n);
        for (int i = 0; i < n; i++)
        {
            dchar c = fn.FPDFText_GetUnicode(tp, i);
            auto box = charBox(page, tp, index, i);
            // A character beyond the first 65536 comes as two halves
            if (c >= 0xD800 && c < 0xDC00 && i + 1 < n)
            {
                const low = fn.FPDFText_GetUnicode(tp, i + 1);
                if (low >= 0xDC00 && low < 0xE000)
                {
                    c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                    box = box.union_(charBox(page, tp, index, i + 1));
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
        PdfLink[] found;
        // The PDF's own: link annotations
        int position;
        void* annotation;
        while (fn.FPDFLink_Enumerate(page, &position, &annotation))
        {
            PdfLink link;
            FS_RECTF r;
            if (fn.FPDFLink_GetAnnotRect(annotation, &r))
                link.areas ~= toPage(page, index, r.left, r.top, r.right, r.bottom);
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
                            link.areas ~= toPage(page, index, l, t, r, b);
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
        foreach (p; pages)
            fn.FPDF_ClosePage(p.handle);
        pages = null;
        if (handle)
            fn.FPDF_CloseDocument(handle);
        handle = null;
        if (file.isOpen)
            file.close();
    }

private:
    PdfiumEngine engine;
    void* handle;
    File file;
    FPDF_FILEACCESS access;

    // A few pages kept loaded: loading one is most of reading its text, links or a tile of it
    struct Loaded { int index; void* handle; }
    Loaded[] pages;
    enum keepPages = 8;

    this(PdfiumEngine engine) { this.engine = engine; }

    ref Functions fn() { return engine.fn; }

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
        if (pages.length >= keepPages)
        {
            fn.FPDF_ClosePage(pages[0].handle);
            pages = pages[1 .. $];
        }
        pages ~= Loaded(index, h);
        return h;
    }

    /*
        A rectangle in a page's PDF coordinates -- from its bottom left, unturned -- as Mayfair has
        them: from its top left, as it's shown. FPDF_PageToDevice does the turning, in whole
        pixels, so it's asked for a page `fine` times as big, for precision.
    */
    PdfRect toPage(void* page, int index, double left, double top, double right, double bottom)
    {
        enum fine = 16;
        const size = pageSize(index);
        const sw = cast(int) (size.width * fine + 0.5), sh = cast(int) (size.height * fine + 0.5);
        int x1, y1, x2, y2;
        fn.FPDF_PageToDevice(page, 0, 0, sw, sh, 0, left, top, &x1, &y1);
        fn.FPDF_PageToDevice(page, 0, 0, sw, sh, 0, right, bottom, &x2, &y2);
        const l = (x1 < x2 ? x1 : x2) / cast(float) fine, t = (y1 < y2 ? y1 : y2) / cast(float) fine;
        const r = (x1 < x2 ? x2 : x1) / cast(float) fine, b = (y1 < y2 ? y2 : y1) / cast(float) fine;
        return PdfRect(l, t, r - l, b - t);
    }

    PdfRect charBox(void* page, void* tp, int index, int i)
    {
        double l, r, b, t;
        if (!fn.FPDFText_GetCharBox(tp, i, &l, &r, &b, &t) || r <= l || t <= b)
            return PdfRect.init; // a character PDFium put in: a space, a line break
        return toPage(page, index, l, t, r, b);
    }

    /// Where a destination goes: its page, and how far down it, if it says.
    void destination(void* dest, out int page, out float y)
    {
        page = fn.FPDFDest_GetDestPageIndex(handle, dest);
        y = float.nan;
        FPDF_BOOL hasX, hasY, hasZoom;
        float x, py, zoom;
        if (page >= 0 && fn.FPDFDest_GetLocationInPage(dest, &hasX, &hasY, &hasZoom, &x, &py, &zoom) && hasY)
            if (auto target = loadPage(page))
                y = toPage(target, page, 0, py, 0, py).y;
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
}

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
