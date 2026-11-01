module mayfair.widgets.textfield;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.textinputcontrol;
import mayfair.widgets.widget;

/*
    A single line of editable text. JavaFX's TextField.

        auto name = new TextField().promptText("Your name");
        name.onAction({ greet(name.text); });

    The editing is TextInputControl's. What's a field's own: its text is one line, and one too
    long for it scrolls to keep the caret in view; Enter runs its action if it has one, and
    otherwise goes on to the default button, so a form's OK still works from its fields; and
    Tab into it selects everything, as JavaFX's does, so typing replaces what was there.
*/
class TextField : TextInputControl
{
public:
    this(string text = "")
    {
        super(text);
        setAccessibleRole(AccessibleRole.textField);
        styleClass.add("text-field");
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureTextField);
    }

    /// What to do when Enter is pressed in the field. JavaFX's setOnAction.
    final void setOnAction(void delegate() handler) nothrow @nogc
    {
        _onAction = handler;
    }

    /// The same, returning this so calls chain.
    final TextField onAction(void delegate() handler) nothrow @nogc
    {
        _onAction = handler;
        return this;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // Yoga measures it, as a leaf

    // It stretches along a line, as JavaFX's does, but keeps to one line's height
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    override VisualLine[] layoutLines(string text)
    {
        return [VisualLine(0, editableLine(font, text), 0, 0, true)];
    }

    override string clean(string text)
    {
        return singleLine(text);
    }

    override void fontChanged()
    {
        YGNodeMarkDirty(node);
    }

    override void enterPressed(ref KeyEvent event)
    {
        // Without an action of its own, Enter goes on to the default button
        if (!_onAction)
            return;
        _onAction();
        event.consume();
    }

    override void handleMouse(ref MouseEvent event)
    {
        textMouse(event, event.x - YGNodeLayoutGetPadding(node, YGEdgeLeft) + _scrollX, 0);
    }

    override void mounted() nothrow
    {
        // The selection, the text and the caret each need a colour of their own, and all three are
        // clipped to the inside of the field, so text scrolled out of view doesn't show
        _selectionPaint = addPaint();
        _text.create();
        addPaint(_text.paint);
        _caretPaint = addPaint();
        foreach (i, p; [_selectionPaint, _text.paint, _caretPaint])
        {
            _clips[i] = tvg_shape_new();
            tvg_paint_set_clip(p, _clips[i]); // held by the paint, and freed with it
        }
    }

    override void unmounted()
    {
        super.unmounted();
        _selectionPaint = _caretPaint = null;
        _text.release();
        _clips[] = null;
    }

    override float textInputCaret() nothrow @nogc
    {
        return YGNodeLayoutGetPadding(node, YGEdgeLeft) + caretBounds.minX + Theme.caret_width - _scrollX;
    }

    override void textOriginInScene(out float x, out float y) nothrow @nogc
    {
        // Where it drew the text, moved as the field's been moved since by scrolling around it
        const b = boundsInScene;
        x = _originX + b.minX - _paintedAt[0];
        y = _lineTop + b.minY - _paintedAt[1];
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        _paintedAt = [x, y];
        // The field and its border are its background and border, from the stylesheet. The text
        // goes inside its padding.
        const padLeft = YGNodeLayoutGetPadding(node, YGEdgeLeft);
        const innerX = x + padLeft;
        const innerW = w - padLeft - YGNodeLayoutGetPadding(node, YGEdgeRight);
        _lineTop = y + (h - lineHeight) / 2;

        // Scrolled just enough to keep the caret in view, and no further than the text goes. Only
        // while focused: a field that isn't shows the start of its text, as browsers' do.
        const caretX = caretBounds.minX + Theme.caret_width;
        auto scroll = focused ? _scrollX : 0;
        if (focused && caretX - scroll > innerW)
            scroll = caretX - innerW;
        if (caretX - scroll < 0)
            scroll = caretX;
        const most = lines[0].line.run.width - innerW;
        if (scroll > most)
            scroll = most > 0 ? most : 0;
        if (scroll != _scrollX)
        {
            _scrollX = scroll;
            invalidateAccessible(); // the characters moved on screen
        }
        _originX = innerX - _scrollX;

        // A caret at either end is half outside the text, so the clip leaves room for it
        foreach (clip; _clips)
        {
            tvg_shape_reset(clip);
            tvg_shape_append_rect(clip, innerX - Theme.caret_width, y, innerW + 2 * Theme.caret_width, h, 0, 0, true);
        }
        drawText(_selectionPaint, _text, _caretPaint, _originX, _lineTop, scene ? scene.pixelScale : 1.0f, behind);
    }

private:
    void delegate() _onAction;
    float _scrollX = 0, _originX = 0, _lineTop = 0; // where the text was last drawn
    float[2] _paintedAt = [0, 0];
    Tvg_Paint _selectionPaint, _caretPaint;
    TextImage _text;
    Tvg_Paint[3] _clips;
}

/// `text` as one line: a field has nowhere to put a line break, and no use for control characters.
private string singleLine(string text)
{
    foreach (char c; text)
    {
        if (c < 0x20 || c == 0x7F)
        {
            char[] clean;
            clean.reserve(text.length);
            foreach (char d; text)
                if (d >= 0x20 && d != 0x7F)
                    clean ~= d;
            return cast(string) clean;
        }
    }
    return text;
}

/// Yoga asking how big the field wants to be: a set width, since a field that grew as it was typed
/// into would move everything around it, and one line high. Growing to fill a row still works.
private extern(C) YGSize measureTextField(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                          float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(TextField) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return YGSize(Theme.text_field_width, self.font.lineHeight);
}
