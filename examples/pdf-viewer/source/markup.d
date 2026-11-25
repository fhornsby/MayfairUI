module markup;

/*
    The markup toolbar, under the title bar while it's shown: what the pointer does -- select text,
    drag out a region, highlight, underline, strike through, draw, shapes, text, notes, sign -- and
    how what it makes looks: its line, its colours, its text's size. A change of style restyles the
    annotation selected, too, as it does in other apps.
*/

import std.conv : to;
import std.format : format;
import mayfair;
import mayfair.pdf;
import icons;
import signature : drawSignature;
import store : removeSignatures, signatures;

/// The colours to choose from.
immutable PdfColour[] palette = [
    PdfColour(220, 38, 38), PdfColour(234, 88, 12), PdfColour(255, 214, 10), PdfColour(22, 163, 74),
    PdfColour(37, 99, 235), PdfColour(147, 51, 234), PdfColour(236, 72, 153), PdfColour(0, 0, 0),
    PdfColour(120, 120, 120), PdfColour(255, 255, 255),
];

immutable string[] paletteNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Black", "Grey", "White"];

final class MarkupBar : Row
{
    this(PdfView view)
    {
        this.view = view;
        setSpacing(2);
        setPadding(Insets(4, 8));
        setAlignment(Pos.centreLeft);
        styleClass.add("markup-bar"); // styled by the viewer's stylesheet: a strip of the page

        tool(PdfTool.select, svgIcon(selectTextIcon), "Select text and annotations");
        tool(PdfTool.region, svgIcon(regionIcon), "Select a region, to crop to");
        add(gap());
        tool(PdfTool.highlight, svgIcon(highlighterIcon), "Highlight text");
        tool(PdfTool.underline, new Icon("format-text-underline-symbolic"), "Underline text");
        tool(PdfTool.strikeOut, new Icon("format-text-strikethrough-symbolic"), "Strike text through");
        add(gap());
        tool(PdfTool.draw, svgIcon(penIcon), "Draw");
        shapes = new MenuButton().graphic(svgIcon(shapesIcon)).accessibleText("Shapes").tooltip("Shapes");
        auto shapeMenu = new ContextMenu();
        static struct Named { PdfTool tool; string name; }
        foreach (n; [Named(PdfTool.rectangle, "Rectangle"), Named(PdfTool.roundedRectangle, "Rounded Rectangle"),
                     Named(PdfTool.oval, "Oval"), Named(PdfTool.line, "Line"), Named(PdfTool.arrow, "Arrow"),
                     Named(PdfTool.star, "Star"), Named(PdfTool.speechBubble, "Speech Bubble")])
            shapeMenu.add(toolItem(n.tool, n.name));
        shapes.setMenu(shapeMenu);
        add(shapes);
        tool(PdfTool.textBox, svgIcon(textBoxIcon), "Text box");
        tool(PdfTool.note, svgIcon(noteIcon), "Note");
        sign = new MenuButton().graphic(svgIcon(signatureIcon)).accessibleText("Sign").tooltip("Sign");
        add(sign);
        rebuildSignatures();
        add(gap());

        // How it looks
        widthButton = new MenuButton().graphic(svgIcon(lineWidthIcon)).accessibleText("Line width").tooltip("Line width");
        auto widths = new ContextMenu();
        foreach (w; [0.5f, 1, 2, 3, 5, 8, 12])
            widths.add(widthItem(w));
        widthButton.setMenu(widths);
        add(widthButton);
        colourButton = new Button().accessibleText("Colour").tooltip("Line and drawing colour");
        colourButton.setOnAction({ chooseColour(colourButton, false, (PdfColour c) { setColour(c); }); });
        add(colourButton);
        fillButton = new Button().accessibleText("Fill").tooltip("Fill colour");
        fillButton.setOnAction({ chooseColour(fillButton, true, (PdfColour c) { setFill(c); }); });
        add(fillButton);
        sizeButton = new MenuButton().graphic(svgIcon(textSizeIcon)).accessibleText("Text size").tooltip("Text size");
        auto sizes = new ContextMenu();
        foreach (size; [9, 10, 12, 14, 16, 18, 24, 32, 48])
            sizes.add(sizeItem(size));
        sizeButton.setMenu(sizes);
        add(sizeButton);
        textColourButton = new Button().accessibleText("Text colour").tooltip("Text colour");
        textColourButton.setOnAction({ chooseColour(textColourButton, false, (PdfColour c) { setTextColour(c); }); });
        add(textColourButton);
        add(gap());

        crop = new Button().graphic(svgIcon(cropIcon)).accessibleText("Crop").tooltip("Crop to the region (Ctrl+K)");
        crop.setOnAction({ view.cropToRegion(); });
        add(crop);
        remove = new Button().graphic(new Icon("edit-delete-symbolic")).accessibleText("Delete").tooltip("Delete the annotation");
        remove.setOnAction({ view.deleteSelectedAnnotation(); });
        add(remove);

        showStyle();
        view.toolProperty.addListener((PdfTool was, PdfTool now) { showTool(); });
        view.regionProperty.addListener((PdfRegion was, PdfRegion now) { showState(); });
        view.selectedAnnotationProperty.addListener((PdfAnnotationRef was, PdfAnnotationRef now) { showState(); });
        showTool();
        showState();
    }

    /// The signature tool, or -- with none drawn -- drawing one first.
    void signWith(int which)
    {
        auto all = signatures();
        if (which < 0 || which >= all.length)
            return;
        view.setSignature(all[which]);
        view.setTool(PdfTool.signature);
    }

private:
    PdfView view;
    ToggleButton[PdfTool] tools;
    MenuButton shapes, sign, widthButton, sizeButton;
    Button colourButton, fillButton, textColourButton, crop, remove;

    static Widget gap() { return new Row().prefWidth(10); }

    void tool(PdfTool t, Icon icon, string tip)
    {
        auto b = new ToggleButton().graphic(icon).accessibleText(tip).tooltip(tip);
        b.setOnAction({ view.setTool(view.tool == t && t != PdfTool.select ? PdfTool.select : t); showTool(); });
        tools[t] = b;
        add(b);
    }

    MenuItem toolItem(PdfTool t, string name) { return new MenuItem(name, { view.setTool(t); }); }
    MenuItem widthItem(float w) { return new MenuItem(format!"%g pt"(w), { setWidth(w); }); }
    MenuItem sizeItem(int size) { return new MenuItem(format!"%s pt"(size), { setSize(size); }); }

    void rebuildSignatures()
    {
        auto menu = new ContextMenu();
        foreach (i, s; signatures())
            menu.add(signatureItem(cast(int) i));
        menu.add(new MenuItem("New Signature…", { drawSignature(this, { rebuildSignatures(); signWith(cast(int) signatures().length - 1); }); }));
        if (signatures().length)
            menu.add(new MenuSeparator()).add(new MenuItem("Forget Signatures", { removeSignatures(); rebuildSignatures(); }));
        sign.setMenu(menu);
    }

    MenuItem signatureItem(int i)
    {
        return new MenuItem(format!"Signature %s"(i + 1), { signWith(i); });
    }

    void showTool()
    {
        foreach (t, b; tools)
            b.setSelected(view.tool == t);
        with (PdfTool)
        {
            const t = view.tool;
            shapes.setStyle(t == rectangle || t == roundedRectangle || t == oval || t == line || t == arrow
                            || t == star || t == speechBubble ? "background-colour: var(--row-selected);" : "");
            sign.setStyle(t == signature ? "background-colour: var(--row-selected);" : "");
        }
    }

    void showState()
    {
        crop.setDisable(view.region.page < 0);
        remove.setDisable(view.selectedAnnotation.page < 0);
    }

    void showStyle()
    {
        const st = view.markupStyle;
        colourButton.setGraphic(svgIcon(swatchSvg(hex(st.colour))).symbolic(false));
        fillButton.setGraphic(svgIcon(swatchSvg(hex(st.fill))).symbolic(false));
        textColourButton.setGraphic(svgIcon(swatchSvg(hex(st.textColour))).symbolic(false));
    }

    static PdfColourHex hex(PdfColour c)
    {
        return PdfColourHex(format!"#%02x%02x%02x"(c.r, c.g, c.b), c.none);
    }

    // A change of style: for what's drawn next, and what's selected

    void restyle(void delegate(ref PdfMarkupStyle) style, void delegate(ref PdfAnnotation) annotation)
    {
        auto st = view.markupStyle;
        style(st);
        view.setMarkupStyle(st);
        showStyle();
        view.restyleSelected(annotation);
    }

    void setColour(PdfColour c)
    {
        restyle((ref PdfMarkupStyle s) {
            if (view.tool == PdfTool.highlight)
                s.highlight = c;
            else
                s.colour = c;
        }, (ref PdfAnnotation a) {
            if (a.kind != PdfAnnotationKind.textBox)
                a.colour = c;
        });
    }

    void setFill(PdfColour c)
    {
        restyle((ref PdfMarkupStyle s) { s.fill = c; }, (ref PdfAnnotation a) { a.fill = c; });
    }

    void setTextColour(PdfColour c)
    {
        restyle((ref PdfMarkupStyle s) { s.textColour = c; }, (ref PdfAnnotation a) {
            if (a.kind == PdfAnnotationKind.textBox)
                a.colour = c;
        });
    }

    void setWidth(float w)
    {
        restyle((ref PdfMarkupStyle s) { s.lineWidth = w; }, (ref PdfAnnotation a) { a.lineWidth = w; });
    }

    void setSize(float size)
    {
        restyle((ref PdfMarkupStyle s) { s.fontSize = size; }, (ref PdfAnnotation a) { a.fontSize = size; });
    }
}

/// Offers the palette, under `owner`; `chosen` hears the colour picked. With `none`, "no colour" too.
void chooseColour(Widget owner, bool none, void delegate(PdfColour) chosen)
{
    auto popup = new Popup();
    auto grid = new Column().spacing(4).padding(Insets(8));
    Row row;
    PdfColour[] choices = palette.dup;
    string[] names = paletteNames.dup;
    if (none)
    {
        choices ~= PdfColour(0, 0, 0, 0);
        names ~= "None";
    }
    foreach (i, c; choices)
    {
        if (i % 6 == 0)
        {
            row = new Row().spacing(4);
            grid.add(row);
        }
        row.add(swatch(popup, c, names[i], chosen));
    }
    popup.setContent(grid);
    popup.show(owner, Side.below);
}

private Button swatch(Popup popup, PdfColour c, string name, void delegate(PdfColour) chosen)
{
    import std.format : format;
    auto b = new Button().graphic(svgIcon(swatchSvg(PdfColourHex(format!"#%02x%02x%02x"(c.r, c.g, c.b), c.none)))
                                  .symbolic(false).iconSize(20))
        .accessibleText(name).tooltip(name);
    b.setOnAction({ popup.hide(); chosen(c); });
    return b;
}
