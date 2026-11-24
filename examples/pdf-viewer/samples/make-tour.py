#!/usr/bin/env python3
"""
Makes tour.pdf, the PDF viewer's sample: a short tour of what the viewer does, with an outline,
links between its sections and to the web, a landscape page, and a drawing to zoom into.

    python3 make-tour.py        (a Python whose cairo has PDF tags: python3-cairo 1.18 or later)
"""
import math
import cairo

A4 = (595.276, 841.89)
FONT = "DejaVu Sans"
INK = (0.13, 0.15, 0.2)
ACCENT = (0.21, 0.52, 0.89)

surface = cairo.PDFSurface("tour.pdf", *A4)
surface.set_metadata(cairo.PDF_METADATA_TITLE, "A tour of the PDF viewer")
surface.set_metadata(cairo.PDF_METADATA_AUTHOR, "Mayfair")
surface.set_metadata(cairo.PDF_METADATA_SUBJECT, "The sample the Mayfair PDF viewer opens")
ctx = cairo.Context(surface)

def font(size, bold=False):
    ctx.select_font_face(FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    ctx.set_font_size(size)

def text(x, y, s, size=12, bold=False, colour=INK):
    font(size, bold)
    ctx.set_source_rgb(*colour)
    ctx.move_to(x, y)
    ctx.show_text(s)

def paragraph(x, y, lines, size=12, leading=18):
    for i, line in enumerate(lines):
        text(x, y + i * leading, line, size)
    return y + len(lines) * leading

def link(x, y, label, target):
    if "://" in target:
        attrs = "uri='%s'" % target
    elif target.startswith("page="):
        attrs = target
    else:
        attrs = "dest='%s'" % target
    ctx.tag_begin(cairo.TAG_LINK, attrs)
    text(x, y, label, 12, False, ACCENT)
    ctx.tag_end(cairo.TAG_LINK)

def heading(y, s, dest):
    ctx.tag_begin(cairo.TAG_DEST, "name='%s'" % dest)
    text(64, y, s, 22, True)
    ctx.tag_end(cairo.TAG_DEST)

# 1: the title page, and what's in the tour
ctx.set_source_rgb(*ACCENT)
ctx.rectangle(0, 0, A4[0], 230)
ctx.fill()
text(64, 120, "A tour of the", 20, False, (1, 1, 1))
text(64, 160, "PDF viewer", 40, True, (1, 1, 1))
text(64, 196, "Built with Mayfair, reading with PDFium", 13, False, (0.9, 0.95, 1))
y = paragraph(64, 290, [
    "This document is the viewer's sample. Each page shows something it does:",
    "follow the links below, or the contents in the sidebar, to get around.",
])
for i, (label, dest) in enumerate([("Reading: scrolling, zooming and turning pages", "reading"),
                                   ("Searching for words", "searching"),
                                   ("Selecting and copying text", "selecting"),
                                   ("Links, inside and out", "links"),
                                   ("A drawing to zoom into", "drawing")]):
    link(84, y + 20 + i * 24, "%d.  %s" % (i + 1, label), dest)
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Welcome", "page=1", 0)
surface.show_page()

# 2: reading
heading(100, "Reading", "reading")
paragraph(64, 140, [
    "Scroll with the wheel, a touchpad, the scroll bar, or Page Up and Page Down.",
    "Home and End go to the first page and the last.",
    "",
    "Zoom with Ctrl and the wheel, or a pinch on a touchpad, about the pointer;",
    "with Ctrl and + or -, and Ctrl+0 for actual size; or from the zoom menu,",
    "which also fits the pages to the window's width, or a whole page to it.",
    "",
    "However far in you zoom, the text stays sharp: pages are drawn in tiles,",
    "at the screen's own pixels, as they come into view.",
    "",
    "Turn every page a quarter turn with the rotate buttons, or Ctrl+R and Ctrl+L.",
    "The thumbnails down the side show where you are; click one to go there.",
])
reading = surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Reading", "page=2", 0)
surface.add_outline(reading, "Zooming", "page=2 pos=[64 200]", 0)
surface.add_outline(reading, "Turning pages", "page=2 pos=[64 320]", 0)
surface.show_page()

# 3: searching
heading(100, "Searching", "searching")
paragraph(64, 140, [
    "Type in the search field at the top right, or press Ctrl+F to get there.",
    "Every match is highlighted, on every page, as the pages are searched;",
    "Enter goes to the next, and Shift+Enter to the one before.",
    "",
    "Try searching for the word mayfair: it's on this page twice more,",
    "and on the title page too. Searching ignores case: Mayfair, MAYFAIR.",
])
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Searching", "page=3", 0)
surface.show_page()

# 4: selecting
heading(100, "Selecting and copying", "selecting")
paragraph(64, 140, [
    "Drag across text to select it, across lines and across pages,",
    "and copy it with Ctrl+C. Double-click a word to select it alone,",
    "and Ctrl+A selects everything. Escape lets go of the selection.",
    "",
    "The quick brown fox jumps over the lazy dog.",
    "Sphinx of black quartz, judge my vow.",
])
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Selecting and copying", "page=4", 0)
surface.show_page()

# 5: links, on a landscape page
surface.set_size(A4[1], A4[0])
heading(100, "Links, inside and out", "links")
paragraph(64, 140, [
    "A link to a page goes there. This page is landscape: wider than tall,",
    "laid out beside the portrait ones, centred.",
])
link(64, 200, "Back to the start", "page=1")
link(64, 230, "Mayfair's code, on GitHub: https://github.com/fhornsby/MayfairUI", "https://github.com/fhornsby/MayfairUI")
paragraph(64, 280, ["A web address written in the text is a link too: https://dlang.org"])
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "Links", "page=5", 0)
surface.show_page()

# 6: a drawing
surface.set_size(*A4)
heading(100, "A drawing to zoom into", "drawing")
paragraph(64, 140, ["Fine lines and small type: zoom in to 400% and look closely."])
cx, cy = A4[0] / 2, 480
for i in range(72):
    a = i * math.pi / 36
    ctx.set_source_rgb(0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a), 0.8)
    ctx.set_line_width(0.6)
    ctx.move_to(cx, cy)
    ctx.line_to(cx + 200 * math.cos(a), cy + 200 * math.sin(a))
    ctx.stroke()
for r in range(20, 201, 20):
    ctx.set_source_rgba(*INK, 0.4)
    ctx.set_line_width(0.3)
    ctx.arc(cx, cy, r, 0, 2 * math.pi)
    ctx.stroke()
text(cx - 60, cy + 230, "Tiny text, at 3 points, below:", 9)
text(cx - 60, cy + 240, "If you can read this, the tiles are at the screen's pixels.", 3)
surface.add_outline(cairo.PDF_OUTLINE_ROOT, "A drawing", "page=6", 0)
surface.show_page()
surface.finish()
print("made tour.pdf")
