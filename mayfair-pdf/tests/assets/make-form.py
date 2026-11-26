#!/usr/bin/env python3
"""
Makes form.pdf, for mayfair-pdf's form tests: one page with a text field, a multi-line one,
a checkbox, two radio buttons and a drop-down list, at known places. Needs ReportLab.

    python3 make-form.py
"""
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

c = canvas.Canvas("form.pdf", pagesize=A4)
c.setTitle("Mayfair form sample")
width, height = A4
c.setFont("Helvetica-Bold", 20)
c.drawString(72, height - 80, "A form to fill in")
c.setFont("Helvetica", 12)
form = c.acroForm

# Places from the page's top left, as Mayfair has them: the PDF's are from its bottom left
c.drawString(72, height - 128, "Name")
form.textfield(name="name", x=160, y=height - 140, width=250, height=22, borderWidth=1,
               fillColor=None, forceBorder=True, fontSize=12)
c.drawString(72, height - 188, "Comments")
form.textfield(name="comments", x=160, y=height - 260, width=250, height=80, borderWidth=1,
               fillColor=None, forceBorder=True, fieldFlags="multiline", fontSize=11)
c.drawString(72, height - 308, "Subscribe")
form.checkbox(name="subscribe", x=160, y=height - 314, size=18, buttonStyle="check", checked=False)
c.drawString(72, height - 358, "Size")
form.radio(name="size", value="small", x=160, y=height - 364, size=18, selected=True)
c.drawString(184, height - 358, "Small")
form.radio(name="size", value="large", x=250, y=height - 364, size=18, selected=False)
c.drawString(274, height - 358, "Large")
c.drawString(72, height - 408, "Colour")
form.choice(name="colour", x=160, y=height - 414, width=150, height=22, value="Red",
            options=["Red", "Green", "Blue"], fieldFlags="combo", fontSize=12)
c.showPage()
c.save()
