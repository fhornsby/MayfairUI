module mayfair.pdf.engine;

/*
    What reads PDFs: an engine. PDFium's (mayfair.pdf.pdfium) is the one this package has, and
    what documents are read with unless the app gives another (see PdfDocument.setEngine): a
    test's fake, say. Another implements the same two interfaces, and nothing in PdfDocument,
    PdfView or PdfThumbnails changes.

    An engine is simple on purpose: everything here is synchronous, and called on the one PDF thread
    only (see mayfair.pdf.thread), so an engine that isn't thread-safe -- PDFium isn't -- needs no
    locks, and one that's slow keeps nothing else waiting but that thread. The queue, priorities,
    cancelling and getting results to the UI thread are mayfair-pdf's.

    Places on a page are in points from its top left, as it's shown: its own /Rotate applied.
*/

import mayfair.pdf.annotation;
import mayfair.pdf.types;

/// Something that can read PDFs.
interface PdfEngine
{
    /// A name for it, for logs and errors: "pdfium", say.
    string name();

    /// Starts it -- finds its library, initialises it -- before anything else is asked of it. False,
    /// with `failure` saying why, if it can't.
    bool start(out string failure);

    /// Opens the PDF at `path`, with `password` if it's encrypted. Null, with `error` saying why, if it can't.
    PdfEngineDocument open(string path, string password, out PdfError error);

    /// Opens a PDF from `data`: what an edited document's saved as, to undo to. The engine may
    /// keep `data` for as long as the document's open.
    PdfEngineDocument openMemory(immutable(ubyte)[] data, string password, out PdfError error);
}

/// An open PDF, as an engine has it. Called on the PDF thread only.
interface PdfEngineDocument
{
    int pageCount();

    /// Page `index`'s size, in points, as it's shown.
    PdfSize pageSize(int index);

    /// What the document says about itself: "Title", "Author", "Subject", "Keywords", "Creator",
    /// "Producer", as PDF's document information names them. Only those it has.
    string[string] metadata();

    /// Its outline -- the table of contents -- or none.
    PdfOutlineItem[] outline();

    /*
        Renders `region` of page `index`, turned `quarterTurns` clockwise -- the region's in the
        turned page's points -- at `scale` pixels a point, into `pixels`: `width` by `height` of
        them, a row after another, each 0xAARRGGBB, premultiplied, over white. False if it couldn't.
    */
    bool render(int index, PdfRect region, float scale, int quarterTurns, uint[] pixels, uint width, uint height);

    /// Page `index`'s text, a character at a time, with each one's box.
    PdfPageText text(int index);

    /// Page `index`'s links: those the PDF has, and web addresses written in its text.
    PdfLink[] links(int index);

    /// What it is: its PDF version, whether it's encrypted, whether it has a form.
    PdfDocumentInfo info();

    /// Lets go of it. Nothing's asked of it after.
    void close();
}

/*
    An engine document that can be changed, and saved: what editing needs. Page numbers are as
    they are when each is called; an edit that moves pages changes them for the next.

    Rotations and crops are in the page's shown terms: a quarter turn more clockwise, a crop to
    a rectangle of the page as it's shown now.
*/
interface PdfEditableDocument
{
    /// Writes the whole document, as it is now, a block at a time to `write`. False, with
    /// `failure` saying why, if it couldn't. `removeSecurity` writes it unencrypted.
    bool save(void delegate(const(ubyte)[]) write, bool removeSecurity, out string failure);

    /// Turns page `index` `quarterTurns` more clockwise.
    bool rotatePage(int index, int quarterTurns);

    bool deletePage(int index);

    /// Moves `pages` -- in this order -- to be together from `destination` on, as it's counted
    /// with them taken out.
    bool movePages(const int[] pages, int destination);

    /// Puts a blank page `size` big before page `index` (or at the end, for pageCount).
    bool insertBlankPage(int index, PdfSize size);

    /// Copies `pages` of `from` -- another document of the same engine -- in before page `index`.
    bool importPages(PdfEngineDocument from, const int[] pages, int index);

    /// Crops page `index` to `rect`, in its shown points.
    bool cropPage(int index, PdfRect rect);

    /// Page `index`'s annotations, of every kind but links and popups.
    PdfAnnotation[] annotations(int index);

    /// Adds `a` to page `index`; its index among the page's annotations, or -1 if it couldn't.
    int addAnnotation(int index, const ref PdfAnnotation a);

    /// Changes annotation `which` of page `index` to `a`: wholly, for one of ours; only where it
    /// is, for another app's. Its index after, which may differ, or -1 if it couldn't.
    int updateAnnotation(int index, int which, const ref PdfAnnotation a);

    bool removeAnnotation(int index, int which);
}

/// The keys a form field hears, besides what's typed.
enum PdfFormKey
{
    backspace, tab, enter, escape, left, right, up, down, home, end, pageUp, pageDown, delete_,
}

/// Which modifiers are held, for a form field.
enum PdfFormModifiers : uint
{
    none = 0,
    shift = 1,
    control = 2,
    alt = 4,
}

/// A press, release or move of the pointer, for a form field.
enum PdfFormPointer { move, press, release, doubleClick }

/// What a form tells its document, on the PDF thread.
struct PdfFormEvents
{
    void delegate(int page) nothrow redraw;   /// Something on page `page` looks different
    void delegate() nothrow changed;          /// A field's value changed
}

/*
    An engine document whose form can be filled in: its fields drawn by render(), and pointer
    and keys sent to them. Places are in a page's shown points.
*/
interface PdfFormDocument
{
    /// Whether it has a form to fill in.
    bool hasForm();

    /// Who's told what the form does. Called before anything's sent to it.
    void formEvents(PdfFormEvents events);

    /// The pointer, on page `page`: whether a field took it.
    bool formPointer(int page, PdfFormPointer what, float x, float y, uint modifiers);

    /// A key, pressed or let go of, for the field with focus: whether it took it.
    bool formKey(int page, PdfFormKey key, bool pressed, uint modifiers);

    /// Text typed or pasted, in place of what's selected, in the field with focus.
    bool formText(int page, string text);

    /// What's selected in the field with focus.
    string formSelectedText(int page);

    void formSelectAll(int page);
    bool formUndo(int page);
    bool formRedo(int page);

    /// Takes focus from whichever field has it, keeping what's in it.
    void formBlur();

    /// Whether a field has focus, and which page it's on.
    bool formFocused(out int page);
}
