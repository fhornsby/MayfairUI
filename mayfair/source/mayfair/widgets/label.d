module mayfair.widgets.label;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.text;
import mayfair.widgets.widget;

/*
    A line of text.

    The text is shaped when it's set, not when it's painted or measured. Shaping allocates, and both
    of the places that would otherwise do it -- Yoga's measure callback and paintTree -- run inside
    the frame loop, which is @nogc on purpose. Doing it at set-text time keeps that promise honest,
    and it's the right place anyway: the glyphs only change when the text or the font does.

    That's also why there's no wrapping yet. Wrapping needs the available width, which isn't known
    until Yoga is already laying out, so it can't be done up front the way this is. It wants either
    a shaping cache keyed by width or a relaxed @nogc boundary in the layout phase, and that's a
    decision worth making deliberately rather than falling into.

    Without a font of its own it uses the default at the theme's text size, which is what most
    labels want; font() swaps in another. Either way, characters the font can't draw come from a
    fallback (see shapeText), so a label never has to know which fonts cover what.

    Its text, font and colour are properties, as JavaFX's Label's are, so a label can show
    whatever it's bound to:

        status.textProperty.bind(count.map((int n) => format!"Clicked %d times"(n)));
*/
class Label : Widget
{
public:
    this(string text)
    {
        _font = defaultFont(Theme.text_size);
        _text = text;
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
    mixin(declareProperty!(Font, "font", "null", q{ reshape(); }));

    /// The colour of the text. JavaFX's textFill.
    mixin(declareProperty!(Colour, "textFill", "Theme.text_colour", q{ applyFill(); }));

protected:
    override void mounted() nothrow
    {
        applyFill();
        applyOpacity();
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        node.value(_text);
    }

    override void disabledChanged()
    {
        applyOpacity();
        invalidate();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // y is the top of the box; a run's origin is its baseline, one ascender below that
        emitRun(shape, _run, x, y + _ascender, scene ? scene.scale : 1.0f);
    }

private:
    /// Shapes the text again, for a new text or font, and has the layout measure it again.
    void reshape()
    {
        _run = shapeText(_font, _text);
        _ascender = _font.ascender;
        _lineHeight = _font.lineHeight;
        YGNodeMarkDirty(node); // the measured size changed, so the layout above it has to be redone
        invalidate();
        invalidateAccessible();
    }

    void applyFill() nothrow @nogc
    {
        if (shape)
            tvg_shape_set_fill_color(shape, _textFill.tupleof);
        invalidate();
    }

    // A disabled label fades, like any other control: it's a control in JavaFX too
    void applyOpacity() nothrow @nogc
    {
        if (shape)
            tvg_paint_set_opacity(shape, disabled ? cast(ubyte)(255 * Theme.disabled_opacity) : 255);
    }

    GlyphRun _run;
    float _ascender = 0, _lineHeight = 0;
}

/*
    Yoga measuring a leaf. It runs inside YGNodeCalculateLayout, so it must not allocate or throw --
    hence the shaping already being done. The modes are ignored because a single line has one size;
    a wrapping Label would have to respect YGMeasureModeAtMost on the width.
*/
private extern(C) YGSize measureLabel(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                      float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(Label) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return YGSize(self._run.width, self._lineHeight);
}
