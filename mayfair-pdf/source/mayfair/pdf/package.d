module mayfair.pdf;

/*
    PDFs for Mayfair: a PdfDocument to open, a PdfView to read it in -- scrolled, zoomed, turned,
    searched, its text selected and copied, its links followed -- and PdfThumbnails and PdfOutline
    for a sidebar, read with PDFium.

        import mayfair.pdf;

        auto view = new PdfView(PdfDocument.open("report.pdf"));

    PDFium is downloaded prebuilt as this package is built, and put beside the app: nothing else
    to depend on or set up. Its licences, all permissive, come with it: see the README.
*/

public import mayfair.pdf.types;
public import mayfair.pdf.annotation;
public import mayfair.pdf.engine;
public import mayfair.pdf.thread : PdfPriority;
public import mayfair.pdf.document;
public import mayfair.pdf.view;
public import mayfair.pdf.sidebar;
public import mayfair.pdf.pdfium : PdfiumEngine;
