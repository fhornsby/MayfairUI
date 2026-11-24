module mayfair.pdf.engine;

/*
    What reads PDFs: an engine, chosen by the app (see PdfDocument.setEngine). mayfair-pdfium is one;
    another -- on MuPDF or Poppler, under their own licences -- implements the same two interfaces,
    and nothing in PdfDocument, PdfView or PdfThumbnails changes.

    An engine is simple on purpose: everything here is synchronous, and called on the one PDF thread
    only (see mayfair.pdf.thread), so an engine that isn't thread-safe -- PDFium isn't -- needs no
    locks, and one that's slow keeps nothing else waiting but that thread. The queue, priorities,
    cancelling and getting results to the UI thread are mayfair-pdf's.

    Places on a page are in points from its top left, as it's shown: its own /Rotate applied.
*/

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

    /// Lets go of it. Nothing's asked of it after.
    void close();
}
