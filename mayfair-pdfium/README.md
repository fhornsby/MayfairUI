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

Not tested yet:

- macOS and Windows, and Linux on ARM64, whose PDFium builds are pinned but haven't been run;
- Wayland, a real GPU, and the OpenGL renderer;
- a system's own PDFium;
- PDFs from other producers: scanned, with forms, right-to-left text, or damaged.

## Tests

`tests/` reads real PDFs with PDFium, through real windows (see mayfair/tests' harness):

- **The engine:** opening, errors, passwords, rendering (pixels at known places, whole pages,
  parts and turned), `/Rotate`, text with its boxes, links and the outline.
- **The view:** layout, fitting, zoom, paging, search, selecting by dragging and double-clicking,
  copying, following links, and rotation.
- **The sidebar:** thumbnails and the outline.
- **Closing:** while a document's opening, and over and over.

```sh
cd tests && dub run
```
