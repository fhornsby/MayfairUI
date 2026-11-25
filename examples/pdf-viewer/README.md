# PDF Viewer

A PDF viewer and editor built with Mayfair, modelled on Preview, the one macOS comes with. It's
built with [mayfair-pdf](../../mayfair-pdf), and reads and writes PDFs with
[mayfair-pdfium](../../mayfair-pdfium). The build downloads PDFium the first time.

```sh
dub run                      # open a PDF, drop one on the window, or open the tour
dub run -- a.pdf b.pdf       # each in a window of its own
```

Everything is in the menu at the end of the title bar, with its shortcuts.

It's in the Oriel desktop's look (`mayfair.theme.oriel`). On Oriel, and on any Wayland desktop
that blurs behind windows over `ext-background-effect-v1`, the sidebar is frosted glass, up
behind the title bar, while the document beside it stays opaque. The title bar follows the
sidebar: hidden with F9, or in a slideshow, the bar's the page's colour all the way across.
Elsewhere (X11, or with translucency off) the window is opaque.

## What it does

**Reading**
- **Sidebar:** pages, contents, highlights and notes, search results, and bookmarks.
- **Zoom:** fit width, fit page, actual size, steps, Ctrl and the wheel, or zoom to a region.
- **Layout:** pages continuous or two side by side, and a slideshow.
- **Text:** search, select and copy. Links are followed.
- **Passwords:** protected PDFs open once their password is given.

**Pages**
- **Rotate:** the selected pages, or the one being read.
- **Delete and reorder:** select pages in the sidebar with Ctrl and Shift, Delete deletes them,
  and dragging them reorders them.
- **Insert:** a blank page, or the pages of another PDF, from a file or dropped on the sidebar.
- **Crop:** to a region dragged out.

**Markup** (the toolbar under the title bar, Ctrl+Shift+A)
- **Text:** highlight, underline, strike through.
- **Shapes:** rectangles, rounded rectangles, ovals, lines, arrows, stars and speech bubbles.
- **Drawing:** freehand, with the pointer or a pen.
- **Text boxes and notes.**
- **Signatures:** drawn once, kept, and placed on any document.
- **Styles:** line width, colour, fill, text size and text colour. Changing a style changes the
  annotation selected too.
- **Annotations:** selected, moved, stretched, copied, pasted and deleted.

**Forms**
- Filled in: text fields, check boxes, radio buttons and lists.

**Files**
- **Undo and redo** for every change.
- **Save, Save As and Revert.** Closing a window with changes asks whether to save them.
- **Export:** as a PDF, with a password if qpdf is installed, or as PNG pictures at 72, 150 or
  300 dpi.
- **Print:** through CUPS, choosing the printer, the copies and the pages.
- **Document info.**

## Compared with Preview

What Preview does that this doesn't, or does differently:

| | |
|---|---|
| Redacting | Not here. PDFium can take out whole text objects, not the parts of them under a box. |
| Text boxes | Edited in a dialog, not on the page; set in Helvetica, so only Latin-1 characters. |
| Notes | Opened by double-clicking, not shown on hover. |
| Shapes | No sketch recognition, loupe, mask or polygon. |
| Signatures | Drawn with the pointer; no camera or phone. |
| Views | Continuous and two pages; no single page or contact sheet. |
| Several documents in one window | A window each. |
| Copying a region as a picture | Mayfair's clipboard has text only. |
| Exporting | PDF and PNG; no JPEG, TIFF or HEIC, and no Quartz filters such as Reduce File Size. |
| Encrypting | Needs qpdf; taking a password off doesn't. |
| Printing | CUPS only (Linux, the BSDs, macOS), with no preview; not on Windows yet. |
| Document info | Shown, not edited: PDFium can't change a PDF's title or author. |
| Saving | Asks, rather than saving automatically with versions to go back to. |
| Signed PDFs | Saving rewrites the file, which invalidates a digital signature. |

## Tested

In a Linux container, on Xvfb, with real pointer and keyboard input, on the CPU and WebGPU
renderers: opening and reading, every markup tool, moving and undoing annotations, filling in a
form, rotating, reordering and deleting pages, signatures, search, the slideshow, saving and
document info. mayfair-pdfium's tests cover the same ground automatically. Printing was tried
only as far as finding no printer. macOS, Windows, Wayland and a real GPU haven't been tried.
