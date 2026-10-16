module mayfair.widgets.label;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.text;
import mayfair.widgets.widget;

/*
    Text: a line of it, or several, wrapped to the width it's given if wrapText says so.

        new Label("A long explanation...").wrapText(true)

    The text is shaped when it's set, not when it's painted or measured. Shaping allocates, and both
    of the places that would otherwise do it -- Yoga's measure callback and paintTree -- run inside
    the frame loop, which is @nogc on purpose. Doing it at set-text time keeps that promise honest,
    and it's the right place anyway: the glyphs only change when the text or the font does.

    Wrapping keeps it too. The layout decides the width, and asks how tall the label is at it while
    it's working, so everything that doesn't depend on the width is done up front, and the lines at
    a width are worked out from that with arithmetic alone (see Paragraph). The text's own line
    breaks always start a new line, wrapping or not, as JavaFX's do.

    A wrapping label is as wide as its text on one line if it has room, as JavaFX's is, and wraps
    when it hasn't: in a Column, when the column is narrower; in a Row, give it a maxWidth, or
    grow, for the room it can have.

    Without a font of its own it uses the default at the theme's text size, which is what most
    labels want; font() swaps in another. Either way, characters the font can't draw come from a
    fallback (see shapeText), so a label never has to know which fonts cover what.

    Its text, font and colour are properties, as JavaFX's Label's are, so a label can show
    whatever it's bound to:

        status.textProperty.bind(count.map((int n) => format!"Clicked %d times"(n)));
*/
@DefaultProperty("text")
class Label : Widget
{
public:
    this(string text = null)
    {
        _font = defaultFont(Theme.text_size);
        _text = text;
        styleClass.add("label");
        setAccessibleRole(AccessibleRole.label);
        // Yoga asks a leaf how big it wants to be through this callback, which finds its way back
        // here through the node's context pointer
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureLabel);
        reshape();
    }

    /// What it says. Setting it re-shapes and re-measures.
    mixin(declareProperty!(string, "text", "null", q{ reshape(); }));

    /// What it's drawn with, e.g. `font("Noto Serif", 24)` or a Font opened from the app's own file.
    mixin(declareStyleableProperty!(Font, "font", "font, font-family, font-size, font-weight, font-style",
                                    "null", q{ reshape(); }, true));

    /// The colour of the text. JavaFX's textFill.
    mixin(declareStyleableProperty!(Colour, "textFill", "colour", "Theme.text_colour", q{ applyFill(); }));

    /// Whether the text wraps to the label's width, rather than staying on one line. JavaFX's wrapText.
    mixin(declareStyleableProperty!(bool, "wrapText", "wrap-text", "false", q{ remeasure(); }));

    /// How lines line up with each other, and in a label wider than its text. JavaFX's textAlignment.
    mixin(declareStyleableProperty!(TextAlignment, "textAlignment", "text-align", "TextAlignment.left",
                                    q{ invalidate(); }));

    /// Extra room between lines, in points. JavaFX's lineSpacing.
    mixin(declareStyleableProperty!(float, "lineSpacing", "line-spacing", "0", q{ remeasure(); }));

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // Yoga measures it, as a leaf

    // As big as its text and no bigger, as a JavaFX Labeled is: see Widget.maxWidth
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    override void mounted() nothrow
    {
        _image.create();
        addPaint(_image.paint);
    }

    override void unmounted()
    {
        _image.release(); // its paint went with the widget's
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.value(_text);
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // The text goes inside the padding, which Yoga added round what measureLabel said
        const l = YGNodeLayoutGetPadding(node, YGEdgeLeft), t = YGNodeLayoutGetPadding(node, YGEdgeTop);
        x += l;
        y += t;
        w -= l + YGNodeLayoutGetPadding(node, YGEdgeRight);
        h -= t + YGNodeLayoutGetPadding(node, YGEdgeBottom);
        // The width the layout settled on was measured from these lines, but rounded to the pixel
        // grid since, so a line that fitted it before rounding still does
        const lines = _paragraph.lines(_wrapText ? w + 1 : float.infinity);
        _image.begin(scene ? scene.pixelScale : 1.0f);
        float top = y;
        foreach (ref line; lines)
        {
            float left = x;
            if (_textAlignment == TextAlignment.centre)
                left += (w - line.width) / 2;
            else if (_textAlignment == TextAlignment.right)
                left += w - line.width;
            // A line's origin is its baseline, one ascender below its top
            _image.addLine(_paragraph, line, left, top + _paragraph.ascender, _textFill);
            top += _paragraph.lineHeight + _lineSpacing;
        }
        _image.finish();
    }

private:
    /// Shapes the text again, for a new text or font, and has the layout measure it again.
    void reshape()
    {
        if (!_font)
            _font = defaultFont(Theme.text_size); // none given, or a stylesheet's taken back
        _paragraph = Paragraph(_font, _text);
        remeasure();
        invalidateAccessible();
    }

    void remeasure() nothrow @nogc
    {
        YGNodeMarkDirty(node); // the measured size changed, so the layout above it has to be redone
        invalidate();
    }

    void applyFill() nothrow @nogc
    {
        invalidate(); // the colour's in the picture, which is made again
    }

    Paragraph _paragraph;
    TextImage _image; // the text, drawn by FreeType (see mayfair.text.raster)
}

/// How lines of text line up. JavaFX's TextAlignment; justify is left, for now.
enum TextAlignment { left, centre, right, justify }

/*
    Yoga measuring a leaf. It runs inside YGNodeCalculateLayout, so it must not allocate or throw --
    hence the shaping already being done. Wrapping, it wraps to the width Yoga has, whether that's
    all it may have (at most) or what it will have (exactly); with no width to go by, the text's
    as wide as it is on its lines.
*/
private extern(C) YGSize measureLabel(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                      float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(Label) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    const wrap = self._wrapText && widthMode != YGMeasureModeUndefined;
    float w, h;
    self._paragraph.measure(wrap ? width : float.infinity, self._lineSpacing, w, h);
    return YGSize(w, h);
}
