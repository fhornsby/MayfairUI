module mayfair.pdf.document;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import mayfair.pdf.annotation;
import std.math : ceil;
import mayfair.pdf.engine;
import mayfair.pdf.thread;
import mayfair.pdf.types;
import mayfair.properties;
import mayfair.windowing.platform : Platform;

/*
    A PDF, opened: its pages, what it says about itself, its outline, and its pages' pictures, text
    and links, read by PDFium on the PDF thread (see mayfair.pdf.thread).

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
        doc.password = password;
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
            auto info = opened.info;
            doc.listenToForm(opened);
            Platform.runLater({ doc.opened(opened, sizes, metadata, outline, info); });
        });
        return doc;
    }

    /// What PDFs are read with: PDFium (mayfair.pdf.pdfium) unless another's given, once, before
    /// the first is opened -- a test's fake, say. False if it's too late to change.
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

    /// What it is: its PDF version, whether it's encrypted, has a form, can be edited.
    mixin(declareReadOnlyProperty!(PdfDocumentInfo, "info", "PdfDocumentInfo.init"));

    /// Whether it's been changed since it was opened or saved.
    mixin(declareReadOnlyProperty!(bool, "edited", "false"));

    /// Whether there's an edit to undo, or one undone to redo.
    mixin(declareReadOnlyProperty!(bool, "canUndo", "false"));
    mixin(declareReadOnlyProperty!(bool, "canRedo", "false")); /// ditto

    /// Whether an edit or a save is being made: what's shown may not be the document as it is.
    mixin(declareReadOnlyProperty!(bool, "busy", "false"));

    /// The page whose form field has focus, being filled in, or -1.
    mixin(declareReadOnlyProperty!(int, "formFocus", "-1"));

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
        const gen = generation;
        request.job = submit(priority, {
            if (atomicLoad(closedOnThread) || atomicLoad(appliedEdits) != gen)
                return;
            auto pixels = new uint[w * h];
            if (!engineDocument.render(index, region, scale, quarterTurns, pixels, w, h))
                return;
            auto bitmap = new PdfBitmap(pixels, w, h, region, scale, quarterTurns);
            Platform.runLater({
                if (!request.cancelled && _status == PdfStatus.ready && gen == generation)
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

    /// Page `index`'s annotations, of every kind but links. Kept once read, until they're changed.
    PdfRequest annotations(int index, PdfPriority priority, void delegate(PdfAnnotations) done)
    {
        return annotationLists.ask(this, index, priority, done, (int i) {
            auto e = cast(PdfEditableDocument) engineDocument;
            return new PdfAnnotations(e ? e.annotations(i) : null);
        });
    }

    /// Page `index`'s annotations, if they've been read: null if not.
    PdfAnnotations cachedAnnotations(int index) { return annotationLists.cached(index); }

    /// How many times page `index` has changed how it looks, as far as this document knows: a
    /// view that rendered it at another version renders it again.
    uint pageVersion(int index) const nothrow @nogc
    {
        return index >= 0 && index < versions.length ? versions[index] : 0;
    }

    /// Hears about each change to the document: which page is which now, and which look different.
    void addChangeListener(void delegate(PdfChange) listener) { changeListeners ~= listener; }

    /// ditto
    void removeChangeListener(void delegate(PdfChange) listener)
    {
        foreach (i, l; changeListeners)
            if (l is listener)
            {
                changeListeners = changeListeners[0 .. i] ~ changeListeners[i + 1 .. $];
                return;
            }
    }

    // Editing. Each edit's made on the PDF thread, one after another, in the order they're asked
    // for; once it's made, the change listeners hear what changed. Each can be undone.

    /// Turns `pages` `quarterTurns` more clockwise.
    void rotatePages(const int[] pages, int quarterTurns)
    {
        auto list = pages.dup;
        edit(list.length == 1 ? "Rotate Page" : "Rotate Pages", (PdfEditableDocument e) {
            auto change = PdfChange.same(pageCountNow);
            foreach (p; list)
                if (e.rotatePage(p, quarterTurns))
                    change.from[p] = -1;
            return change;
        });
    }

    void deletePages(const int[] pages)
    {
        import std.algorithm : sort, uniq;
        import std.array : array;
        auto list = pages.dup.sort.uniq.array;
        edit(list.length == 1 ? "Delete Page" : "Delete Pages", (PdfEditableDocument e) {
            const before = pageCountNow;
            if (list.length >= before)
                return PdfChange.init; // a PDF has a page at least
            foreach_reverse (p; list)
                e.deletePage(p);
            PdfChange change;
            foreach (i; 0 .. before)
            {
                import std.algorithm : canFind;
                if (!list.canFind(i))
                    change.from ~= i;
            }
            change.redrawn = new bool[change.from.length];
            change.ok = true;
            return change;
        });
    }

    /// Moves `pages` to be together, in their order, before page `before` (or at the end, for pageCount).
    void movePages(const int[] pages, int before)
    {
        import std.algorithm : canFind, sort, uniq;
        import std.array : array;
        auto list = pages.dup.sort.uniq.array;
        edit(list.length == 1 ? "Move Page" : "Move Pages", (PdfEditableDocument e) {
            const count = pageCountNow;
            int[] order;
            foreach (i; 0 .. count)
                if (!list.canFind(i))
                    order ~= i;
            int destination;
            foreach (i; 0 .. before)
                if (!list.canFind(i))
                    destination++;
            if (!e.movePages(list, destination))
                return PdfChange.init;
            auto change = PdfChange.same(count);
            change.from = order[0 .. destination] ~ list ~ order[destination .. $];
            return change;
        });
    }

    /// Puts a blank page, `size` big, before page `at`.
    void insertBlankPage(int at, PdfSize size)
    {
        edit("Insert Blank Page", (PdfEditableDocument e) {
            const count = pageCountNow;
            if (!e.insertBlankPage(at, size))
                return PdfChange.init;
            return PdfChange.inserted(count, at, 1);
        });
    }

    /// Puts every page of the PDF at `file` before page `at`: `done` hears whether it could be read.
    void insertFile(string file, string password, int at, void delegate(PdfError) done = null)
    {
        edit("Insert Pages", (PdfEditableDocument e) {
            const count = pageCountNow;
            PdfError error;
            auto engine = PdfThread.engine;
            auto other = engine ? engine.open(file, password, error) : null;
            if (!other)
            {
                if (done)
                    Platform.runLater({ done(error); });
                return PdfChange.init;
            }
            scope (exit) other.close();
            int[] all;
            foreach (i; 0 .. other.pageCount)
                all ~= i;
            if (!e.importPages(other, all, at))
            {
                if (done)
                    Platform.runLater({ done(PdfError(PdfErrorKind.other, "Its pages couldn't be put in")); });
                return PdfChange.init;
            }
            if (done)
                Platform.runLater({ done(PdfError.init); });
            return PdfChange.inserted(count, at, cast(int) all.length);
        });
    }

    /// Crops `pages` to `rect`, in each one's shown points.
    void cropPages(const int[] pages, PdfRect rect)
    {
        auto list = pages.dup;
        edit("Crop", (PdfEditableDocument e) {
            auto change = PdfChange.same(pageCountNow);
            foreach (p; list)
                if (e.cropPage(p, rect))
                    change.from[p] = -1;
            return change;
        });
    }

    /// Adds `a` to page `page`; `done` hears its index among the page's annotations.
    void addAnnotation(int page, PdfAnnotation a, void delegate(int) done = null)
    {
        auto copy = a.copy();
        edit(annotationName(a.kind), (PdfEditableDocument e) {
            const at = e.addAnnotation(page, copy);
            if (done)
                Platform.runLater({ done(at); });
            return at >= 0 ? PdfChange.redrew(pageCountNow, page) : PdfChange.init;
        });
    }

    /// Changes annotation `index` of page `page` to `a`; `done` hears its index after, which may differ.
    void updateAnnotation(int page, int index, PdfAnnotation a, void delegate(int) done = null)
    {
        auto copy = a.copy();
        edit("Change " ~ annotationName(a.kind), (PdfEditableDocument e) {
            const at = e.updateAnnotation(page, index, copy);
            if (done)
                Platform.runLater({ done(at); });
            return at >= 0 ? PdfChange.redrew(pageCountNow, page) : PdfChange.init;
        });
    }

    void removeAnnotation(int page, int index)
    {
        edit("Delete Annotation", (PdfEditableDocument e) {
            return e.removeAnnotation(page, index) ? PdfChange.redrew(pageCountNow, page) : PdfChange.init;
        });
    }

    /// What undo() would undo, and redo() redo: "Highlight", "Delete Page"; empty for nothing.
    string undoName() const { return undoStack.length ? undoStack[$ - 1].name : null; }
    string redoName() const { return redoStack.length ? redoStack[$ - 1].name : null; } /// ditto

    /// Puts the document back as it was before the last edit.
    void undo() { travel(true); }

    /// Makes the last edit undone again.
    void redo() { travel(false); }

    /*
        Writes the document, as it is now, to `file`. Unless `options.asCopy`, it's the document's
        file after: Save, or Save As. `done` hears whether it could be, on the UI thread.
    */
    void save(string file, PdfSaveOptions options, void delegate(PdfError) done = null)
    {
        enqueue({
            _setBusy(true);
            submit(PdfPriority.control, {
                auto e = cast(PdfEditableDocument) engineDocument;
                if (atomicLoad(closedOnThread) || !e)
                {
                    Platform.runLater({ saved(file, options, PdfError(PdfErrorKind.other, "It can't be saved"), done); });
                    return;
                }
                if (auto f = cast(PdfFormDocument) engineDocument)
                    f.formBlur(); // what's being typed into a field, kept
                auto error = writeOut(e, file, options);
                Platform.runLater({ saved(file, options, error, done); });
            });
        });
    }

    // Filling in the form. Places are in a page's shown points; a view sends the pointer when it's
    // over a field, or one has focus, and keys while one has focus (see formFocus).

    /// The pointer, on page `page`, for the form.
    void formPointer(int page, PdfFormPointer what, float x, float y, uint modifiers)
    {
        formJob((PdfFormDocument f, int focused) {
            if (what == PdfFormPointer.press && !formSnapshot.length)
                formSnapshot = snapshotOf(cast(PdfEditableDocument) engineDocument);
            if (what == PdfFormPointer.press)
                f.formPointer(page, PdfFormPointer.move, x, y, modifiers); // onto the field first, as a pointer comes
            f.formPointer(page, what, x, y, modifiers);
            return false;
        });
    }

    /// A key, for the field with focus.
    void formKey(PdfFormKey key, bool pressed, uint modifiers)
    {
        formJob((PdfFormDocument f, int focused) => focused >= 0 && f.formKey(focused, key, pressed, modifiers) && pressed);
    }

    /// Text, typed or pasted, for the field with focus.
    void formText(string text)
    {
        formJob((PdfFormDocument f, int focused) => focused >= 0 && f.formText(focused, text));
    }

    /// What's selected in the field with focus, handed to `done`.
    void formSelectedText(void delegate(string) done)
    {
        formJob((PdfFormDocument f, int focused) {
            auto text = focused >= 0 ? f.formSelectedText(focused) : null;
            Platform.runLater({ done(text); });
            return false;
        });
    }

    void formSelectAll()
    {
        formJob((PdfFormDocument f, int focused) { if (focused >= 0) f.formSelectAll(focused); return false; });
    }

    /// Undoes or redoes typing in the field with focus.
    void formUndo(bool redo = false)
    {
        formJob((PdfFormDocument f, int focused) => focused >= 0 && (redo ? f.formRedo(focused) : f.formUndo(focused)));
    }

    /// Takes focus from the field that has it.
    void formBlur()
    {
        formJob((PdfFormDocument f, int focused) { f.formBlur(); return false; });
    }

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
        annotationLists.clear();
        pendingEdits = null;
        undoStack = redoStack = null;
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
    Kept!PdfAnnotations annotationLists = Kept!PdfAnnotations(0);
    string password;
    uint[] versions;            // each page's: see pageVersion
    uint versionClock;
    uint generation;            // edits whose results the UI thread has: what jobs are asked for against
    shared uint appliedEdits;   // edits made on the PDF thread: jobs asked for against fewer are stale
    void delegate()[] pendingEdits;
    bool editing;
    void delegate(PdfChange)[] changeListeners;
    Snapshot[] undoStack, redoStack;
    enum size_t undoBudget = 512 * 1024 * 1024; // bytes of snapshots kept, at most
    // On the PDF thread: the form, as it was when a field was last pressed, until it's changed
    immutable(ubyte)[] formSnapshot;
    bool formChanged;
    bool[int] formRedrawn;

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
        // Not one of `jobs`: it's to run whatever's cancelled
        PdfThread.submit(new PdfJob(PdfPriority.control, {
            atomicStore(closedOnThread, true);
            if (engineDocument)
                engineDocument.close();
            engineDocument = null;
        }));
    }

    // From the open job, on the UI thread

    void opened(PdfEngineDocument opened, PdfSize[] pageSizes, string[string] metadata, PdfOutlineItem[] outline,
                PdfDocumentInfo info)
    {
        engineDocument = opened;
        if (_status == PdfStatus.closed)
        {
            closeOnThread(); // closed while it was opening
            return;
        }
        sizes = pageSizes;
        versions = new uint[pageSizes.length];
        if (!cast(PdfEditableDocument) opened)
            info.editable = false;
        _setInfo(info);
        _setMetadata(metadata);
        _setOutline(outline);
        _setPageCount(cast(int) pageSizes.length);
        _setStatus(PdfStatus.ready);
    }

    // Editing

    /// The page count, on the PDF thread.
    int pageCountNow() { return engineDocument ? engineDocument.pageCount : 0; }

    /// Runs `step` once every edit and save asked for before it is done: one at a time.
    void enqueue(void delegate() step)
    {
        pendingEdits ~= step;
        pump();
    }

    void pump()
    {
        if (editing || !pendingEdits.length || _status != PdfStatus.ready)
            return;
        auto next = pendingEdits[0];
        pendingEdits = pendingEdits[1 .. $];
        editing = true;
        next();
    }

    /// Done with an edit or a save: on to the next, if there is one.
    void stepDone()
    {
        editing = false;
        if (!pendingEdits.length)
            _setBusy(false);
        pump();
    }

    /*
        An edit called `name`: `make` makes it on the PDF thread, after the document's been kept
        as it was, to undo to, and says what changed -- or nothing (PdfChange.init), if it didn't.
    */
    void edit(string name, PdfChange delegate(PdfEditableDocument) make)
    {
        if (!_info.editable)
            return;
        enqueue({
            _setBusy(true);
            submit(PdfPriority.control, {
                auto e = cast(PdfEditableDocument) engineDocument;
                if (atomicLoad(closedOnThread) || !e)
                {
                    Platform.runLater(&stepDone);
                    return;
                }
                auto before = snapshotOf(e);
                auto change = make(e);
                if (!change.ok)
                {
                    Platform.runLater(&stepDone);
                    return;
                }
                auto sizesNow = readSizes();
                atomicOp!"+="(appliedEdits, 1);
                formSnapshot = null;
                Platform.runLater({
                    if (before.length)
                        pushUndo(Snapshot(before, name, change), true);
                    applied(change, sizesNow);
                    stepDone();
                });
            });
        });
    }

    /// Each page's size, on the PDF thread.
    PdfSize[] readSizes()
    {
        auto list = new PdfSize[pageCountNow];
        foreach (i, ref s; list)
            s = engineDocument.pageSize(cast(int) i);
        return list;
    }

    /// The document as it is now, saved to memory, on the PDF thread: null if it couldn't be.
    immutable(ubyte)[] snapshotOf(PdfEditableDocument e)
    {
        if (!e)
            return null;
        import std.array : appender;
        auto bytes = appender!(ubyte[]);
        string failure;
        if (!e.save((const(ubyte)[] b) { bytes ~= b; }, false, failure))
            return null;
        return cast(immutable) bytes[];
    }

    void pushUndo(Snapshot s, bool clearsRedo)
    {
        undoStack ~= s;
        if (clearsRedo)
            redoStack = null;
        // Within the budget: the oldest let go of first
        size_t total;
        foreach (u; undoStack)
            total += u.bytes.length;
        while (undoStack.length > 1 && total > undoBudget)
        {
            total -= undoStack[0].bytes.length;
            undoStack = undoStack[1 .. $];
        }
        _setCanUndo(undoStack.length > 0);
        _setCanRedo(redoStack.length > 0);
    }

    /// On the UI thread: an edit's been made, and `change` says what changed.
    void applied(PdfChange change, PdfSize[] sizesNow)
    {
        generation++;
        sizes = sizesNow;
        uint[] remapped = new uint[sizesNow.length];
        foreach (i, from; change.from)
        {
            if (i >= remapped.length)
                break;
            const fresh = from < 0 || change.redrawn[i] || from >= versions.length;
            remapped[i] = fresh ? ++versionClock : versions[from];
        }
        versions = remapped;
        previews.remap(change, true);
        texts.remap(change, false);
        linkLists.remap(change, false);
        annotationLists.remap(change, true);
        _setPageCount(cast(int) sizesNow.length);
        _setEdited(true);
        foreach (l; changeListeners.dup)
            l(change);
    }

    /// Undo, or redo: the document as it was before the last edit, or after the last undone.
    void travel(bool back)
    {
        if (!_info.editable)
            return;
        enqueue({
            auto from = back ? &undoStack : &redoStack;
            if (!from.length)
            {
                stepDone();
                return;
            }
            auto target = (*from)[$ - 1];
            *from = (*from)[0 .. $ - 1];
            _setBusy(true);
            submit(PdfPriority.control, {
                auto e = cast(PdfEditableDocument) engineDocument;
                auto engine = PdfThread.engine;
                if (atomicLoad(closedOnThread) || !e || !engine)
                {
                    Platform.runLater(&stepDone);
                    return;
                }
                auto now = snapshotOf(e);
                PdfError error;
                auto reopened = engine.openMemory(target.bytes, password, error);
                if (!reopened || !now.length)
                {
                    if (reopened)
                        reopened.close();
                    Platform.runLater(&stepDone);
                    return;
                }
                engineDocument.close();
                engineDocument = reopened;
                listenToForm(reopened);
                formSnapshot = null;
                auto sizesNow = readSizes();
                atomicOp!"+="(appliedEdits, 1);
                // Undoing an edit changes pages back the other way
                auto change = back ? target.change.inverse(cast(int) sizesNow.length) : target.change;
                Platform.runLater({
                    auto other = Snapshot(now, target.name, target.change);
                    if (back)
                    {
                        redoStack ~= other;
                        _setCanUndo(undoStack.length > 0);
                        _setCanRedo(true);
                    }
                    else
                        pushUndo(other, false);
                    _setFormFocus(-1);
                    applied(change, sizesNow);
                    stepDone();
                });
            });
        });
    }

    /*
        On the PDF thread: writes the document to `file`, by way of a file beside it, so a failure
        halfway leaves what was there. Saved over its own file, it's opened again from there: the
        file it was reading from has been replaced.
    */
    PdfError writeOut(PdfEditableDocument e, string file, PdfSaveOptions options)
    {
        import std.array : appender;
        import std.file : exists, remove, rename, write;
        auto bytes = appender!(ubyte[]);
        string failure;
        if (!e.save((const(ubyte)[] b) { bytes ~= b; }, options.removeSecurity, failure))
            return PdfError(PdfErrorKind.other, "It couldn't be saved", failure);
        const temporary = file ~ ".saving";
        try
            write(temporary, bytes[]);
        catch (Exception x)
            return PdfError(PdfErrorKind.unreadable, "It couldn't be written there", x.msg);
        if (options.asCopy)
        {
            try
                rename(temporary, file);
            catch (Exception x)
            {
                try remove(temporary); catch (Exception) {}
                return PdfError(PdfErrorKind.unreadable, "It couldn't be written there", x.msg);
            }
            return PdfError.init;
        }
        // It's this document's file from now on: let go of the old one, in case it's this one
        auto engine = PdfThread.engine;
        engineDocument.close();
        engineDocument = null;
        PdfError error;
        try
            rename(temporary, file);
        catch (Exception x)
        {
            try remove(temporary); catch (Exception) {}
            error = PdfError(PdfErrorKind.unreadable, "It couldn't be written there", x.msg);
        }
        const pass = options.removeSecurity ? null : password;
        PdfError ignored;
        auto reopened = error ? null : engine.open(file, pass, ignored);
        if (!reopened) // as it was written, from memory: it's what's in the file, if that worked
            reopened = engine.openMemory(cast(immutable) bytes[], pass, ignored);
        engineDocument = reopened;
        if (reopened)
            listenToForm(reopened);
        return error;
    }

    void saved(string file, PdfSaveOptions options, PdfError error, void delegate(PdfError) done)
    {
        if (!error && !options.asCopy)
        {
            _path = file;
            if (options.removeSecurity)
                password = null;
            _setEdited(false);
        }
        if (!engineDocument && !options.asCopy)
        {
            // It couldn't be opened again: there's nothing to show
            _setError(PdfError(PdfErrorKind.unreadable, "It couldn't be opened again after saving"));
            _setStatus(PdfStatus.failed);
        }
        stepDone();
        if (done)
            done(error);
    }

    // The form

    /// On the PDF thread: hears what `document`'s form does.
    void listenToForm(PdfEngineDocument document)
    {
        auto f = cast(PdfFormDocument) document;
        if (!f || !f.hasForm)
            return;
        f.formEvents(PdfFormEvents((int page) nothrow { formRedrawn[page] = true; },
                                   () nothrow { formChanged = true; }));
    }

    /*
        Something for the form, on the PDF thread, once the edits before it are made: `act` says
        whether it changed a field, told which page has the field with focus. After, the pages it redrew are drawn again, which field has
        focus is told, and a change -- the first since a field was pressed -- can be undone.
    */
    void formJob(bool delegate(PdfFormDocument, int focused) act)
    {
        if (!_info.hasForm)
            return;
        enqueue({
            submit(PdfPriority.control, {
                auto f = cast(PdfFormDocument) engineDocument;
                if (atomicLoad(closedOnThread) || !f)
                {
                    Platform.runLater(&stepDone);
                    return;
                }
                formRedrawn = null;
                int before = -1;
                if (!f.formFocused(before))
                    before = -1;
                if (act(f, before))
                    formChanged = true;
                int focused = -1;
                if (!f.formFocused(focused))
                    focused = -1;
                auto redrawn = formRedrawn.keys;
                immutable(ubyte)[] undoTo;
                const changed = formChanged;
                if (formChanged)
                {
                    undoTo = formSnapshot;
                    formSnapshot = null;
                    formChanged = false;
                }
                const count = pageCountNow;
                Platform.runLater({
                    _setFormFocus(focused);
                    if (undoTo.length)
                        pushUndo(Snapshot(undoTo, "Fill In Form", PdfChange.same(count)), true);
                    if (changed)
                        _setEdited(true);
                    if (redrawn.length)
                    {
                        auto change = PdfChange.same(count);
                        foreach (p; redrawn)
                            if (p >= 0 && p < count)
                                change.redrawn[p] = true;
                        foreach (i, r; change.redrawn)
                            if (r && i < versions.length)
                                versions[i] = ++versionClock;
                        previews.remap(change, true);
                        foreach (l; changeListeners.dup)
                            l(change);
                    }
                    stepDone();
                });
            });
        });
    }

    static string annotationName(PdfAnnotationKind kind)
    {
        with (PdfAnnotationKind) switch (kind)
        {
            case highlight: return "Highlight";
            case underline: return "Underline";
            case strikeOut: return "Strikethrough";
            case squiggly: return "Squiggly Underline";
            case note: return "Note";
            case textBox: return "Text";
            case ink: return "Drawing";
            case signature: return "Signature";
            default: return "Shape";
        }
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
            const gen = doc.generation;
            job = doc.submit(priority, {
                if (atomicLoad(doc.closedOnThread) || atomicLoad(doc.appliedEdits) != gen)
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

        /// The pages changed: what's kept goes with its page, as `change` says, unless the page
        /// changed (or, for `looks`, it only looks different). What was waiting is asked for again.
        void remap(const ref PdfChange change, bool looks)
        {
            foreach (ref w; waiting)
                w.job.cancel();
            waiting = null;
            T[int] moved;
            ulong[int] movedUsed;
            foreach (i, from; change.from)
            {
                if (from < 0 || (looks && change.redrawn[i]))
                    continue;
                if (auto t = from in kept)
                {
                    moved[cast(int) i] = *t;
                    movedUsed[cast(int) i] = used[from];
                }
            }
            kept = moved;
            used = movedUsed;
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

/*
    What an edit changed: for each page there is after it, which page it was before (-1 for one
    that's new, or changed so much -- turned, cropped -- that nothing kept of it holds), and
    whether it only looks different (an annotation, a form field), its text and links the same.
*/
struct PdfChange
{
    int[] from;
    bool[] redrawn;
    bool ok;        /// Whether anything changed

    /// No page moved, among `count`.
    static PdfChange same(int count)
    {
        PdfChange c;
        c.from = new int[count];
        foreach (i, ref f; c.from)
            f = cast(int) i;
        c.redrawn = new bool[count];
        c.ok = true;
        return c;
    }

    /// Page `page` looks different, among `count`.
    static PdfChange redrew(int count, int page)
    {
        auto c = same(count);
        if (page >= 0 && page < count)
            c.redrawn[page] = true;
        return c;
    }

    /// `added` new pages put before page `at` of `count`.
    static PdfChange inserted(int count, int at, int added)
    {
        PdfChange c;
        foreach (i; 0 .. at)
            c.from ~= i;
        foreach (i; 0 .. added)
            c.from ~= -1;
        foreach (i; at .. count)
            c.from ~= i;
        c.redrawn = new bool[c.from.length];
        c.ok = true;
        return c;
    }

    /// The change back again, to a document of `count` pages: what undoing it changes.
    PdfChange inverse(int count) const
    {
        PdfChange c;
        c.from = new int[count];
        c.from[] = -1;
        c.redrawn = new bool[count];
        foreach (now, before; from)
            if (before >= 0 && before < count)
            {
                c.from[before] = cast(int) now;
                c.redrawn[before] = redrawn[now];
            }
        c.ok = true;
        return c;
    }
}

unittest
{
    // Page 1 of 3 deleted: then 0 and 2 are what's left, and undoing it brings 1 back new
    PdfChange deleted;
    deleted.from = [0, 2];
    deleted.redrawn = [false, false];
    deleted.ok = true;
    const back = deleted.inverse(3);
    assert(back.from == [0, -1, 1]);
    assert(PdfChange.inserted(3, 1, 2).from == [0, -1, -1, 1, 2]);
    assert(PdfChange.redrew(2, 1).redrawn == [false, true]);
}

/// How a document's saved.
struct PdfSaveOptions
{
    bool asCopy;          /// A copy, elsewhere: the document stays as it is, edited or not, at its own file
    bool removeSecurity;  /// Without its encryption: openable with no password
}

/// The document as it was, to undo to, and the edit that changed it.
private struct Snapshot
{
    immutable(ubyte)[] bytes;
    string name;
    PdfChange change;
}
