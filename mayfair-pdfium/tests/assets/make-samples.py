#!/usr/bin/env python3
"""
Makes the PDFs the tests read, with cairo (python3-cairo) and qpdf:

  sample.pdf    five pages -- A4, then a landscape one -- of text in DejaVu Sans, with an outline,
                a link to page 3, a link to a web page, and shapes. The words the tests search
                for are counted in the comments.
  rotated.pdf   sample.pdf, its first page turned a quarter turn (/Rotate 90)
  locked.pdf    sample.pdf, opened with the password "secret"

    python3 make-samples.py        (a Python whose cairo has PDF tags: 1.18 or later)
"""
import subprocess
import cairo

A4 = (595.276, 841.89)
FONT = "DejaVu Sans"

def text(ctx, x, y, s, size=12, bold=False):
    ctx.select_font_face(FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    ctx.set_font_size(size)
    ctx.move_to(x, y)
    ctx.show_text(s)

surface = cairo.PDFSurface("sample.pdf", *A4)
surface.set_metadata(cairo.PDF_METADATA_TITLE, "Mayfair PDF sample")
surface.set_metadata(cairo.PDF_METADATA_AUTHOR, "Mayfair")
surface.set_metadata(cairo.PDF_METADATA_SUBJECT, "The PDF the tests read")
ctx = cairo.Context(surface)

# Page 1: "fox" twice, "Mayfair" three times (with the title)
ctx.set_source_rgb(0, 0, 0)
text(ctx, 72, 100, "Mayfair PDF sample", 24, True)
text(ctx, 72, 140, "The quick brown fox jumps over the lazy dog.")
text(ctx, 72, 160, "This page is the first of five, made for Mayfair's tests.")
text(ctx, 72, 180, "A second fox appears here, and Mayfair once more.")
ctx.tag_begin(cairo.TAG_LINK, "dest='section-three'")
ctx.set_source_rgb(0, 0, 0.8)
text(ctx, 72, 220, "Go to section three")
ctx.tag_end(cairo.TAG_LINK)
ctx.tag_begin(cairo.TAG_LINK, "uri='https://dlang.org'")
text(ctx, 72, 250, "The D language")
ctx.tag_end(cairo.TAG_LINK)
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Introduction", "page=1 pos=[72 80]", 0)
surface.show_page()

# Page 2: shapes, and one "fox"
ctx.set_source_rgb(0.9, 0.2, 0.2); ctx.rectangle(72, 100, 200, 120); ctx.fill()
ctx.set_source_rgb(0.2, 0.4, 0.9); ctx.arc(420, 160, 60, 0, 6.2832); ctx.fill()
ctx.set_source_rgb(0, 0, 0)
text(ctx, 72, 300, "Shapes: a red rectangle and a blue circle. One fox.")
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Shapes", "page=2 pos=[72 80]", 0)
surface.show_page()

# Page 3: the link's destination, and lines to select across
ctx.tag_begin(cairo.TAG_DEST, "name='section-three'")
text(ctx, 72, 100, "Section three", 20, True)
ctx.tag_end(cairo.TAG_DEST)
lines = ["Alpha beta gamma delta.", "Epsilon zeta eta theta.", "Iota kappa lambda mu."]
for i, line in enumerate(lines):
    text(ctx, 72, 140 + 20 * i, line)
text(ctx, 72, 400, "Details", 16, True)
section = surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Section three", "page=3 pos=[72 80]", 0)
surface.add_outline(section, "Details", "page=3 pos=[72 380]", 0)
surface.show_page()

# Page 4: landscape
surface.set_size(A4[1], A4[0])
text(ctx, 72, 100, "A landscape page", 20, True)
text(ctx, 72, 140, "Wider than it is tall.")
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Landscape", "page=4", 0)
surface.show_page()

# Page 5: A4 again, a long page of numbered lines
surface.set_size(*A4)
for i in range(1, 41):
    text(ctx, 72, 60 + 18 * i, "Line %d of the last page." % i, 10)
surface.show_page()
surface.finish()

subprocess.run(["qpdf", "sample.pdf", "--rotate=+90:1", "rotated.pdf"], check=True)
subprocess.run(["qpdf", "--encrypt", "secret", "secret", "256", "--", "sample.pdf", "locked.pdf"], check=True)
print("made sample.pdf, rotated.pdf, locked.pdf")
