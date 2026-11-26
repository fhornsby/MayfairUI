/*
    A PDF viewer and editor, in the manner of the one macOS comes with: pages down the side -- or
    the contents, the highlights and notes, a search's results, bookmarks -- and the document in
    the middle, scrolled, zoomed, searched, its text selected and copied, its links followed.

    And changed: pages rotated, deleted, reordered by dragging, inserted, cropped; text
    highlighted, underlined, struck through; notes, text boxes, shapes, arrows, drawing and
    signatures put on it; forms filled in; every change undone and redone; saved, exported -- with
    a password, or as pictures -- and printed. Built with mayfair-pdf, reading and writing PDFs
    with PDFium.

        dub run                       opens nothing: open a PDF, drop one on the window, or open the tour
        dub run -- a.pdf b.pdf        opens a.pdf, and b.pdf in a window of its own

    The menu at the title bar's end has everything, with its shortcuts.
*/
import mayfair;
import mayfair.pdf;
import viewer;

void main(string[] args)
{
    auto app = new App("PDF Viewer");
    app.setSize(1180, 820);
    auto first = openWindow(null, app.window);
    foreach (i, path; args.length > 1 ? args[1 .. $] : null)
    {
        if (i == 0)
            first.open(path);
        else
            openWindow(path);
    }
    app.run();
}
