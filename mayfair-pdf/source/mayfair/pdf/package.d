module mayfair.pdf;

/*
    PDFs for Mayfair: a PdfDocument to open, a PdfView to read it in -- scrolled, zoomed, turned,
    searched, its text selected and copied, its links followed -- and PdfThumbnails and PdfOutline
    for a sidebar, read by an engine the app chooses, in a package of its own.

        import mayfair.pdf;
        import mayfair.pdf.pdfium;   // mayfair-pdfium

        PdfDocument.setEngine(new PdfiumEngine);
        auto view = new PdfView(PdfDocument.open("report.pdf"));

    This package has no PDF library in it, and carries no licence but its own: see its README.
*/

public import mayfair.pdf.types;
public import mayfair.pdf.engine;
public import mayfair.pdf.thread : PdfPriority;
public import mayfair.pdf.document;
public import mayfair.pdf.view;
public import mayfair.pdf.sidebar;
