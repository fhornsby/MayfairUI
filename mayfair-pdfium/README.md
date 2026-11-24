# mayfair-pdfium

A [mayfair-pdf](../mayfair-pdf) engine on [PDFium](https://pdfium.googlesource.com/pdfium/): the
PDF library in Chrome, permissively licensed.

```d
import mayfair.pdf;
import mayfair.pdf.pdfium;

PdfDocument.setEngine(new PdfiumEngine);
```

```json
"dependencies": {
    "mayfair-pdf": { "path": "../MayfairUI/mayfair-pdf" },
    "mayfair-pdfium": { "path": "../MayfairUI/mayfair-pdfium" }
}
```

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

## Editing

Its documents can be changed and saved, with PDFium's own editing:

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

This package is MIT. PDFium, and what's built into it, are under their own licences, which all
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
