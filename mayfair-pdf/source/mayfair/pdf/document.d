module mayfair.pdf.document;

import core.atomic : atomicLoad, atomicStore;
import std.math : ceil;
import mayfair.pdf.engine;
import mayfair.pdf.thread;
import mayfair.pdf.types;
import mayfair.properties;
import mayfair.windowing.platform : Platform;

/*
    A PDF, opened: its pages, what it says about itself, its outline, and its pages' pictures, text
    and links, read by the app's engine on the PDF thread (see mayfair.pdf.thread).

        PdfDocument.setEngine(new PdfiumEngine);       // once: the app's choice
        auto doc = PdfDocument.open("/home/me/report.pdf");
        doc.statusProperty.addListener((PdfStatus was, PdfStatus now) { ... });

    Nothing waits on the UI thread. open() returns at once, with the document `loading`; it's
    `ready` once the engine's opened it, with pageCount, each page's size, metadata and outline
    known -- or `needsPassword`, or `failed`, with error saying why. What's read from its pages
    after that is asked for, and handed over on the UI thread when it's been read: render() for a
    part of a page, preview() for a small picture of a whole one, text() and links(). Each gives a
    PdfRequest, to cancel if it's not wanted any more: the page it was for scrolled away, say.
    Previews, text and links are kept once read, and asked for again, are handed over at once.

    close() lets go of it, on the PDF thread. A document isn't closed by anything else: a view
    showing it, taken out of the window, leaves it open.
*/
final class PdfDocument
{
public:
    /// Opens the PDF at `path`, with `password` if it's encrypted: on the PDF thread, so this returns at once.
    static PdfDocument open(string path, string password = null)
    {
        auto doc = new PdfDocument(path);
        doc.submit(PdfPriority.control, {
            string failure;
            auto engine = PdfThread.startedEngine(failure);
            if (!engine)
            {
                const kind = PdfThread.engine ? PdfErrorKind.engineUnavailable : PdfErrorKind.noEngine;
                Platform.runLater({ doc.failed(PdfError(kind, "Nothing to read PDFs with", failure)); });
                return;
            }
            PdfError error;
            auto opened = engine.open(path, password, error);
            if (!opened)
            {
                Platform.runLater({ doc.failed(error); });
                return;
            }
            const count = opened.pageCount;
            auto sizes = new PdfSize[count];
            foreach (i; 0 .. count)
                sizes[i] = opened.pageSize(i);
            auto metadata = opened.metadata;
            auto outline = opened.outline;
            Platform.runLater({ doc.opened(opened, sizes, metadata, outline); });
        });
        return doc;
    }

    /// What PDFs are read with: given once, before the first is opened. False if it's too late to change.
    static bool setEngine(PdfEngine engine) { return PdfThread.setEngine(engine); }

    /// ditto
    static PdfEngine engine() { return PdfThread.engine; }

    /// The file it's of.
    string path() const nothrow @nogc { return _path; }

    /// What it's doing.
    mixin(declareReadOnlyProperty!(PdfStatus, "status", "PdfStatus.loading"));

    /// Why it failed, or needs a password, if it does.
    mixin(declareReadOnlyProperty!(PdfError, "error", "PdfError.init"));

    /// How many pages it has, once it's ready.
    mixin(declareReadOnlyProperty!(int, "pageCount", "0"));

    /// What it says about itself, by PDF's names: "Title", "Author", "Subject", "Keywords",
    /// "Creator", "Producer". Only those it has.
    mixin(declareReadOnlyProperty!(string[string], "metadata", "null"));

    /// Its outline: the table of contents, if it has one.
    mixin(declareReadOnlyProperty!(PdfOutlineItem[], "outline", "null"));

    /// Its title: what it says it's called, or else the file's name.
    string title() const
    {
        import std.path : baseName;
        if (auto t = "Title" in _metadata)
            if ((*t).length)
                return *t;
        return baseName(_path);
    }

    /// Page `index`'s size, in points, as it's shown; zero until it's ready, or for no such page.
    PdfSize pageSize(int index) const nothrow @nogc
    {
        return index >= 0 && index < sizes.length ? sizes[index] : PdfSize.init;
    }

    /*
        Renders `region` of page `index` -- in points of the page turned `quarterTurns` clockwise --
        at `scale` pixels a point, and hands it to `done` on the UI thread.
    */
    PdfRequest render(int index, PdfRect region, float scale, int quarterTurns, PdfPriority priority,
                      void delegate(PdfBitmap) done)
    {
        auto request = new PdfRequest;
        if (!usable(index))
            return request;
        const w = cast(uint) ceil(region.width * scale - 0.01f), h = cast(uint) ceil(region.height * scale - 0.01f);
        if (!w || !h)
            return request;
        request.job = submit(priority, {
            if (atomicLoad(closedOnThread))
                return;
            auto pixels = new uint[w * h];
            if (!engineDocument.render(index, region, scale, quarterTurns, pixels, w, h))
                return;
            auto bitmap = new PdfBitmap(pixels, w, h, region, scale, quarterTurns);
            Platform.runLater({
                if (!request.cancelled && _status == PdfStatus.ready)
                {
                    request._finished = true;
                    done(bitmap);
                }
            });
        });
        return request;
    }

    /// How big a preview is: its longer side, in pixels.
    enum previewSize = 320;

    /// A small picture of page `index`, upright, its longer side previewSize pixels: for thumbnails,
    /// and to show while a page is being rendered properly. Kept once rendered.
    PdfRequest preview(int index, PdfPriority priority, void delegate(PdfBitmap) done)
    {
        return previews.ask(this, index, priority, done, (int i) {
            const s = pageSize(i);
            const scale = previewSize / (s.width > s.height ? s.width : s.height);
            const w = cast(uint) ceil(s.width * scale - 0.01f), h = cast(uint) ceil(s.height * scale - 0.01f);
            if (!w || !h)
                return null;
            auto pixels = new uint[w * h];
            if (!engineDocument.render(i, PdfRect(0, 0, s.width, s.height), scale, 0, pixels, w, h))
                return null;
            return new PdfBitmap(pixels, w, h, PdfRect(0, 0, s.width, s.height), scale, 0);
        });
    }

    /// Page `index`'s preview, if it's been rendered: null if not.
    PdfBitmap cachedPreview(int index) { return previews.cached(index); }

    /// Page `index`'s text, a character at a time with each one's box. Kept once read.
    PdfRequest text(int index, PdfPriority priority, void delegate(PdfPageText) done)
    {
        return texts.ask(this, index, priority, done, (int i) => engineDocument.text(i));
    }

    /// Page `index`'s text, if it's been read: null if not.
    PdfPageText cachedText(int index) { return texts.cached(index); }

    /// Page `index`'s links. Kept once read.
    PdfRequest links(int index, PdfPriority priority, void delegate(PdfLinks) done)
    {
        return linkLists.ask(this, index, priority, done, (int i) => new PdfLinks(engineDocument.links(i)));
    }

    /// Page `index`'s links, if they've been read: null if not.
    PdfLinks cachedLinks(int index) { return linkLists.cached(index); }

    /// Lets go of it, on the PDF thread, and of everything it's kept. Nothing asked of it after does anything.
    void close()
    {
        if (_status == PdfStatus.closed)
            return;
        const wasReady = _status == PdfStatus.ready;
        _setStatus(PdfStatus.closed);
        foreach (job; jobs)
            job.cancel();
        jobs = null;
        previews.clear();
        texts.clear();
        linkLists.clear();
        if (wasReady)
            closeOnThread();
    }

private:
    string _path;
    PdfSize[] sizes;
    PdfEngineDocument engineDocument; // set on the UI thread once open; used on the PDF thread after
    shared bool closedOnThread;
    PdfJob[] jobs;                    // queued, and not known to be finished: to cancel on close
    Kept!PdfBitmap previews = Kept!PdfBitmap(200);
    Kept!PdfPageText texts = Kept!PdfPageText(0);
    Kept!PdfLinks linkLists = Kept!PdfLinks(0);

    this(string path)
    {
        _path = path;
    }

    bool usable(int index) const nothrow @nogc
    {
        return _status == PdfStatus.ready && index >= 0 && index < sizes.length;
    }

    PdfJob submit(PdfPriority priority, void delegate() work)
    {
        // Forget the jobs that are done, now and then, so the list stays short
        if (jobs.length > 64)
        {
            PdfJob[] waiting;
            foreach (j; jobs)
                if (!j.finished)
                    waiting ~= j;
            jobs = waiting;
        }
        auto job = new PdfJob(priority, work);
        jobs ~= job;
        PdfThread.submit(job);
        return job;
    }

    void closeOnThread()
    {
        auto document = engineDocument;
        engineDocument = null;
        // Not one of `jobs`: it's to run whatever's cancelled
        PdfThread.submit(new PdfJob(PdfPriority.control, {
            atomicStore(closedOnThread, true);
            if (document)
                document.close();
        }));
    }

    // From the open job, on the UI thread

    void opened(PdfEngineDocument opened, PdfSize[] pageSizes, string[string] metadata, PdfOutlineItem[] outline)
    {
        engineDocument = opened;
        if (_status == PdfStatus.closed)
        {
            closeOnThread(); // closed while it was opening
            return;
        }
        sizes = pageSizes;
        _setMetadata(metadata);
        _setOutline(outline);
        _setPageCount(cast(int) pageSizes.length);
        _setStatus(PdfStatus.ready);
    }

    void failed(PdfError error)
    {
        if (_status == PdfStatus.closed)
            return;
        _setError(error);
        _setStatus(error.kind == PdfErrorKind.wrongPassword ? PdfStatus.needsPassword : PdfStatus.failed);
    }

    /*
        What's read from pages and kept -- previews, text, links -- a page at a time: asked for
        once, however many ask before it's read, and handed to each of them; at most `limit` kept
        (0 for no limit), the least recently asked for let go of first.
    */
    struct Kept(T)
    {
        size_t limit;
        T[int] kept;
        ulong[int] used;
        ulong clock;
        Waiting[int] waiting;

        struct Waiting
        {
            PdfJob job;
            PdfPriority priority;
            PdfRequest[] requests;
            void delegate(T)[] callbacks;
        }

        this(size_t limit) { this.limit = limit; }

        T cached(int index)
        {
            if (auto t = index in kept)
            {
                used[index] = ++clock;
                return *t;
            }
            return null;
        }

        PdfRequest ask(PdfDocument doc, int index, PdfPriority priority, void delegate(T) done, T delegate(int) read)
        {
            auto request = new PdfRequest;
            if (!doc.usable(index))
                return request;
            if (auto t = cached(index))
            {
                request._finished = true;
                done(t);
                return request;
            }
            auto w = index in waiting;
            if (w && w.priority <= priority && !w.job.cancelled)
            {
                // Already asked for, as soon or sooner: wait for that
                w.requests ~= request;
                w.callbacks ~= done;
                return request;
            }
            // Asked for sooner than before, or for the first time: a job of its own, which those
            // waiting on an older one wait on too
            PdfRequest[] requests = w ? w.requests : null;
            void delegate(T)[] callbacks = w ? w.callbacks : null;
            if (w)
                w.job.cancel();
            requests ~= request;
            callbacks ~= done;
            PdfJob job;
            job = doc.submit(priority, {
                if (atomicLoad(doc.closedOnThread))
                    return;
                auto result = read(index);
                Platform.runLater({ arrived(doc, index, job, result); });
            });
            // Not request.job: the job's shared, so cancelling one request only drops its own callback
            waiting[index] = Waiting(job, priority, requests, callbacks);
            return request;
        }

        void arrived(PdfDocument doc, int index, PdfJob job, T result)
        {
            auto w = index in waiting;
            if (!w || w.job !is job || doc._status != PdfStatus.ready)
                return;
            auto requests = w.requests;
            auto callbacks = w.callbacks;
            waiting.remove(index);
            if (!result)
                return;
            keep(index, result);
            foreach (i, r; requests)
                if (!r.cancelled)
                {
                    r._finished = true;
                    callbacks[i](result);
                }
        }

        void keep(int index, T result)
        {
            kept[index] = result;
            used[index] = ++clock;
            if (!limit || kept.length <= limit)
                return;
            int oldest;
            ulong when = ulong.max;
            foreach (k, u; used)
                if (u < when)
                {
                    when = u;
                    oldest = k;
                }
            kept.remove(oldest);
            used.remove(oldest);
        }

        void clear()
        {
            foreach (ref w; waiting)
                w.job.cancel();
            waiting = null;
            kept = null;
            used = null;
        }
    }
}

/// Something asked of a document: cancel it if what it's for isn't wanted any more.
final class PdfRequest
{
    /// Drops it: it's not read if it hasn't been, and what was read isn't handed over.
    void cancel() nothrow @nogc
    {
        _cancelled = true;
        if (job)
            job.cancel(); // its own: a shared one (see Kept) goes on for whoever else is waiting
    }

    bool cancelled() const nothrow @nogc { return _cancelled; }

    /// Whether what it asked for has been handed over.
    bool finished() const nothrow @nogc { return _finished; }

private:
    PdfJob job;        // its own job, cancelled with it; null for one it shares
    bool _cancelled, _finished;
}

/// A page's links, as kept: a class, so "not read yet" (null) and "none" differ.
final class PdfLinks
{
    PdfLink[] links;
    this(PdfLink[] links) { this.links = links; }

    /// The link at `x`, `y` on the page, in points, or null.
    const(PdfLink)* at(float x, float y) const
    {
        foreach (ref l; links)
            foreach (a; l.areas)
                if (a.contains(x, y))
                    return &l;
        return null;
    }
}
