# mayfair-pdf

PDFs for Mayfair: a `PdfDocument` to open, change and save, a `PdfView` to read it in and mark
it up, and `PdfThumbnails` and `PdfOutline` for a sidebar. Reading PDFs is an **engine**'s job, in a package of its own, which the
app chooses: this package has no PDF library in it, and nothing but its own MIT licence.

| Package | What it is |
|---|---|
| `mayfair-pdf` | This one: the API, the widgets, and the engine interface. No PDF library. |
| [`mayfair-pdfium`](../mayfair-pdfium) | An engine on PDFium, Chrome's PDF library: permissively licensed. |

```d
import mayfair;
import mayfair.pdf;
import mayfair.pdf.pdfium;

PdfDocument.setEngine(new PdfiumEngine);          // once: the app's choice, made explicitly

auto view = new PdfView(PdfDocument.open("report.pdf"));
view.find("budget");
view.onExternalLink((uri) { /* open it in the browser */ });
```

[`examples/pdf-viewer`](../examples/pdf-viewer) is a whole reader built this way, in the manner of
the readers desktops come with.

## The API

**`PdfDocument`** opens a PDF on the PDF thread and returns at once. Its `status` goes from
`loading` to `ready`, `needsPassword` or `failed` (with `error` saying why). Once it's `ready`, it
has these:

- `pageCount`, each page's `pageSize`, `metadata` and `outline`.
- `render()`: a part of a page at any scale, turned or not.
- `preview()`: a small picture of a whole page.
- `text()`: a page's characters, each with its box.
- `links()`: the document's own links, and web addresses written in its text.

Each request is handed over on the UI thread, and can be cancelled. Previews, text and links are
kept once read. `close()` lets go of it.

**`PdfView`** shows a document's pages one under another, as a reader does:

| | |
|---|---|
| Zooming | `zoom`, or `fit` to the width or a whole page; Ctrl and the wheel about the pointer; Ctrl with +, - and 0; `zoomIn`, `zoomOut` |
| Turning | `rotation`, a quarter turn a step |
| Where | `currentPage`, `goToPage`, and `pageRectInScene` for laying things over a page |
| Selecting | dragging across text, across pages, a word by a double click, `selectAll`; `copySelection` or Ctrl+C |
| Searching | `find`, with every match highlighted as pages are searched, `findNext`, `findPrevious`, `matchCount`, `currentMatch` |
| Links | to a page, followed; to the web, handed to `onExternalLink` |

**`PdfThumbnails`** lists the pages, small, and marks the current one. Pages are selected with
clicks (Ctrl and Shift for more), moved by dragging (`onPagesMoved`), and deleted with Delete
(`onDeletePages`). **`PdfOutline`** lists the document's contents.

## Editing

A document an engine can change (`info.editable`; PDFium's can) is edited through `PdfDocument`:

| | |
|---|---|
| Pages | `rotatePages`, `deletePages`, `movePages`, `insertBlankPage`, `insertFile` (another PDF's pages), `cropPages` |
| Annotations | `annotations(page)` reads them; `addAnnotation`, `updateAnnotation`, `removeAnnotation` |
| Forms | `formPointer`, `formKey`, `formText` and the rest send input to the form; `formFocus` says which page's field has it |
| History | `undo`, `redo`, `canUndo`, `canRedo`, `undoName`; `edited` until it's saved |
| Saving | `save(file, options)`: Save, Save As, or a copy elsewhere (`asCopy`), encrypted as it was or not (`removeSecurity`) |

Edits are made one after another on the PDF thread. Before each, the document is saved to memory,
to undo to, within a budget of 512 MB; undoing opens that again. After each, change listeners
(`addChangeListener`) hear a `PdfChange`: for each page now, the page it was, and whether it only
looks different. So a view keeps what it has of pages that didn't change, redraws those that only
look different, and lets go of the rest. Saving writes beside the file and renames it into place, so
a failure partway leaves the file as it was.

**Annotations** (`PdfAnnotation`) are highlights, underlines, strike-throughs, notes, text boxes,
rectangles, ovals, lines, arrows, stars, speech bubbles, drawing and signatures, in a page's shown
points. Those Mayfair made (`ours`) keep a description of themselves in the PDF, so they can be
changed again; another app's can be moved and deleted. Form fields are listed too, as `widget`s.

**`PdfView`'s tools** (`tool`) mark a page up with the pointer, in `markupStyle`:

- highlighting, underlining or striking through text as it's selected;
- notes, text boxes, shapes, lines and arrows, dragged out;
- drawing freehand, and placing a signature (`setSignature`).

With the select tool an annotation's selected by clicking it, moved by dragging, stretched by its
handles, and deleted with Delete; double-clicking a note or text box asks the app to edit its text
(`onEditAnnotation`). The region tool drags out a rectangle, to crop to or zoom to. Form fields are
filled in by clicking them and typing.

## How it works

**One PDF thread.** Engines are called on one thread, which the package runs. An engine that isn't
thread-safe (PDFium isn't) needs no locks, and nothing it does keeps the UI thread waiting. Work
is queued by priority:

1. opening and closing documents;
2. what's on screen;
3. what's about to be;
4. what's wanted sometime: a search's text, thumbnails out of view.

A request that's no longer wanted (its page scrolled away) is cancelled, and skipped if it hasn't
started.

**Pages in tiles.** The view draws each page as tiles of 512 pixels, rendered as they come into
view, at the screen's own pixels for the zoom: at 400%, text is as sharp as at 100%. Under the
tiles is the page's preview, shown at once, so a page is never blank while its tiles render, and
a zoom shows the old tiles scaled until the new ones arrive.

Only pages near the view are kept. Tiles are capped at about 160 MB, previews at 200 pages, and
thumbnails far from the sidebar's view let go of their pictures. A 400-page document read
halfway through settles about 115 MB above where it started, and goes no higher.

**Selection and search on the UI thread.** A page's text is read once, with each character's
box, and kept. Hit-testing, selecting by lines, words and searching all work from it, without
asking the engine again.

## Writing an engine

An engine implements `PdfEngine` and `PdfEngineDocument` (see `engine.d`): opening, page sizes,
metadata, outline, rendering a region of a page into a buffer, a page's text with boxes, and its
links. To be edited, its documents implement `PdfEditableDocument` too; to have their forms filled
in, `PdfFormDocument`. Either can be left out: the document is then read-only, or its form is. Everything is synchronous and called on the PDF thread, so the engine is just the library's
calls. Places on a page are in points from its top left, with the page's own `/Rotate` applied.
An engine on MuPDF or Poppler would carry their licences (AGPL and GPL), which is why engines are
packages of their own.

## Licence

MIT, as Mayfair is. The engine an app adds brings its library's licence with it.
