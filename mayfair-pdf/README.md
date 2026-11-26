# mayfair-pdf

PDFs for Mayfair: a `PdfDocument` to open, change and save, a `PdfView` to read it in and mark
it up, and `PdfThumbnails` and `PdfOutline` for a sidebar. PDFs are read with
[PDFium](https://pdfium.googlesource.com/pdfium/), the PDF library in Chrome, which is
permissively licensed. The package downloads it prebuilt as it's built and puts it beside the
app, so there's one dependency and nothing to set up:

```json
"dependencies": {
    "mayfair-pdf": { "path": "../MayfairUI/mayfair-pdf" }
}
```

```d
import mayfair;
import mayfair.pdf;

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
| Pressing | `onPagePressed` hears a page pressed, with the place on it, before the view acts on it: a LaTeX editor's double click, to go to the source |

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

## Another engine

PDFium is one implementation of `PdfEngine` and `PdfEngineDocument` (see `engine.d`): opening,
page sizes, metadata, outline, rendering a region of a page into a buffer, a page's text with
boxes, and its links. To be edited, its documents implement `PdfEditableDocument` too; to have
their forms filled in, `PdfFormDocument`. `PdfDocument.setEngine` gives another before the first
document's opened, which the tests can use for a fake. Everything is synchronous and called on
the PDF thread, so an engine is just the library's calls. Places on a page are in points from its
top left, with the page's own `/Rotate` applied.

## Where PDFium comes from

Few systems package PDFium. So when this package is built, `fetch.d` downloads a prebuilt one,
from the [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) project, which builds
PDFium for every platform:

- **Pinned:** it's `chromium/8179` (PDFium 160.0.8179.0), checked against a SHA-256 pinned in
  `fetch.d` for each platform: Linux, macOS and Windows, x86-64 and ARM64.
- **Where it goes:** it's unpacked into `pdfium/`, with its licences and headers, and downloaded
  once.
- **Next to the app:** dub copies the library beside the app's executable as it builds it
  (`copyFiles`).
- **No JavaScript:** it's PDFium without its JavaScript engine (V8) or XFA forms.

It's loaded at run time, not linked, the first time a document's opened, from the first of these
that has it:

1. `MAYFAIR_PDFIUM`, if it's set: the library's path;
2. beside the app's executable;
3. this package's `pdfium/` folder;
4. the system's own `libpdfium.so`, `libpdfium.dylib` or `pdfium.dll`, by the library path.

`MAYFAIR_PDFIUM_FETCH=no` downloads nothing, for a system with PDFium of its own, or a build with
no network. If PDFium can't be found, documents fail with `PdfErrorKind.engineUnavailable`, saying
where it looked. A download that fails doesn't fail the build.

It declares the part of PDFium's C API it uses itself (`source/.../fpdf.d`).
`tools/check-abi.sh` checks those declarations against the downloaded headers.

## How PDFium edits

Documents are changed and saved with PDFium's own editing:

- **Pages:** turned (`/Rotate`), deleted, moved, inserted blank, copied in from another PDF, and
  cropped (`/CropBox`).
- **Annotations, as other readers read them:** highlights, underlines, strike-throughs, notes,
  rectangles and ovals are PDF's own kinds of annotation. Drawing and signatures are ink
  annotations. PDFium draws all of these, and saves their appearance with them.
- **Annotations PDFium doesn't draw itself:** text boxes, lines, arrows, stars, rounded rectangles
  and speech bubbles are stamp annotations, drawn with path and text objects. Text boxes are in
  Helvetica, which every reader has, so nothing's embedded; it has the Latin-1 characters only.
- **Mayfair's own:** every annotation Mayfair makes carries `/MayfairData`, a description of
  itself, which other readers ignore, so it can be changed later.
- **Forms:** filled in with PDFium's form filling (AcroForm fields: text, check boxes, radio
  buttons, lists), drawn as they're typed into. Neither JavaScript nor XFA, which this build of
  PDFium leaves out.
- **Saving:** a whole new file each time, not an incremental update, so a signed PDF's signature
  is invalidated by saving it. It's saved encrypted as it was, or with its encryption taken off.
  PDFium can't encrypt one (the viewer example uses qpdf for that).

## Licences

This package is MIT, as Mayfair is. PDFium, and what's built into it, are under their own licences, which all
come with the download, in `pdfium/LICENSE` and `pdfium/licenses/`. **They're all permissive: none
is copyleft.**

| What | Licence |
|---|---|
| PDFium | BSD-3-Clause |
| The pdfium-binaries build | MIT |
| FreeType | the FreeType License |
| libjpeg-turbo | IJG and BSD-3-Clause |
| libpng | the PNG Reference Library License |
| zlib | zlib |
| OpenJPEG | BSD-2-Clause |
| Little CMS | MIT |
| HarfBuzz | "Old MIT" |
| ICU | the Unicode License v3 |
| Abseil, Highway, Dragonbox | Apache-2.0 (Dragonbox also Boost) |
| LLVM libc | Apache-2.0 with LLVM exceptions |
| fast_float, simdutf | MIT |
| Anti-Grain Geometry 2.3 | its own permissive licence |

An app that ships PDFium (and one built with this package does, beside its executable) has to
include those notices with it: copy `pdfium/LICENSE` and `pdfium/licenses/` into what it
distributes, as its other libraries' notices go. This is a summary to point the way, not legal
advice: the licence files say what applies.

## Tested

Tested in a Linux container, in real windows on Xvfb, with no physical GPU or display. Nothing
else yet.

| | Tested |
|---|---|
| System | Ubuntu 24.04, x86-64 |
| PDFium | chromium/8179, the downloaded build |
| PDFs | made by `tests/assets/make-samples.py` and the viewer's `samples/make-tour.py`, with cairo; an AES-256 encrypted one from qpdf; a 400-page one, for size |
| Display | X11 (Xvfb) |
| Mayfair's renderer | WebGPU on lavapipe (Mesa's software Vulkan), and the CPU renderer |

Editing was tested in the same place: every kind of annotation written, read back, drawn, changed
and removed; pages edited; forms filled in through the view; files saved and read back, by PDFium,
and checked by qpdf.

Not tested yet:

- macOS and Windows, and Linux on ARM64, whose PDFium builds are pinned but haven't been run;
- Wayland, a real GPU, and the OpenGL renderer;
- a system's own PDFium;
- PDFs from other producers: scanned, right-to-left text, damaged, or with forms made by other
  apps (the tests' form is ReportLab's);
- annotations made by other apps, other than being listed, moved and deleted;
- saving very large PDFs (each edit keeps a copy in memory to undo to).

## Tests

`tests/` reads real PDFs with PDFium, through real windows (see mayfair/tests' harness):

- **The engine:** opening, errors, passwords, rendering (pixels at known places, whole pages,
  parts and turned), `/Rotate`, text with its boxes, links and the outline.
- **The view:** layout, fitting, zoom, paging, search, selecting by dragging and double-clicking,
  copying, following links, and rotation.
- **The sidebar:** thumbnails and the outline.
- **Closing:** while a document's opening, and over and over.
- **Editing:** pages turned, deleted, moved, inserted and cropped, undone, redone, saved and read
  back; each kind of annotation added, read back, drawn, changed, removed, undone and saved; a
  form filled in by typing and clicking in a view; marking up with the view's tools; pages moved
  and deleted in the sidebar.

`tests/assets/make-form.py` makes the form, with ReportLab.

```sh
cd tests && dub run
```
