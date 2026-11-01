module mayfair.widgets.textarea;

import mayfair.accessibility;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.scrollpane;
import mayfair.widgets.textinputcontrol;
import mayfair.widgets.widget;

/*
    Several lines of editable text. JavaFX's TextArea.

        auto notes = new TextArea().wrapText(true).promptText("Notes");

    The editing is TextInputControl's, down lines as well as along them: Up and Down go to the
    line above and below, keeping to where across they started, and Page Up and Page Down a page
    at a time; Home and End go to the ends of the line as it's shown, and with Ctrl, of the text.
    Enter starts a new line and Tab puts in a tab, as JavaFX's do -- Ctrl+Tab moves focus on. A
    triple click selects the paragraph.

    Its text is its paragraphs, one per line, or wrapped to its width if wrapText says so; either
    way it scrolls, in a ScrollPane, as JavaFX's skin does -- the caret kept in view as it moves.
    It's prefColumnCount characters wide and prefRowCount lines tall, as JavaFX's is, and grows
    beyond that if it's given room.

    Its style class is "text-area", and inside it, as in JavaFX, a scroll pane and the text's own
    `.content`, whose padding is round the text as it scrolls.
*/
class TextArea : TextInputControl
{
public:
    this(string text = "")
    {
        _content = new Content(this);
        _pane = new ScrollPane(_content);
        _pane.setAccessibleHidden(true); // the area speaks for its text; see describeAccessible
        super(text);
        _charWidth = shapeText(font, "0").width;
        styleClass.add("text-area");
        setAccessibleRole(AccessibleRole.textArea);
        adopt(_pane);
    }

    /// Whether lines wrap to its width, rather than scroll sideways. JavaFX's wrapText.
    mixin(declareStyleableProperty!(bool, "wrapText", "wrap-text", "false", q{
        _pane.setFitToWidth(_wrapText);
        relayout();
    }));

    /// How many characters wide it asks to be. JavaFX's prefColumnCount.
    mixin(declareStyleableProperty!(float, "prefColumnCount", "pref-column-count", "40", q{ placeChild(_pane); }));

    /// How many lines tall it asks to be. JavaFX's prefRowCount.
    mixin(declareStyleableProperty!(float, "prefRowCount", "pref-row-count", "10", q{ placeChild(_pane); }));

protected:
    override bool takesChildren() const nothrow @nogc { return false; }
    override bool selectsAllOnTab() { return false; }

    // Its scroll pane fills it, and asks for the rows and columns it's meant to show
    override void placeChild(Widget child) nothrow @nogc
    {
        child.place(1, false, false, YGAlignStretch);
        if (child !is _pane)
            return;
        const pad = _content.padding;
        YGNodeStyleSetFlexBasis(child.node, _prefRowCount * lineHeight + pad.top + pad.bottom);
        YGNodeStyleSetMinWidth(child.node, _prefColumnCount * _charWidth + pad.left + pad.right);
    }

    override VisualLine[] layoutLines(string text)
    {
        VisualLine[] result;
        const wrapAt = _wrapText && _wrapWidth > 0 ? _wrapWidth : float.infinity;
        size_t start;
        while (true)
        {
            size_t end = start;
            while (end < text.length && text[end] != '\n')
                end++;
            const paragraph = text[start .. end];
            // Wrapped, a paragraph's lines run end to end, a wrap's spaces at the end of the line
            // before it, so every character is on a line
            size_t from;
            if (wrapAt != float.infinity && paragraph.length)
            {
                auto layout = Paragraph(font, paragraph);
                const wrapped = layout.lines(wrapAt);
                foreach (i; 1 .. wrapped.length)
                {
                    const to = wrapped[i].start;
                    result ~= VisualLine(start + from, editableLine(font, paragraph[from .. to]), 0, 0, false);
                    from = to;
                }
            }
            result ~= VisualLine(start + from, editableLine(font, paragraph[from .. $]), 0, 0, true);
            if (end >= text.length)
                break;
            start = end + 1; // over the line break
        }
        foreach (i, ref l; result)
            l.top = i * lineHeight;
        _linesChanged = true;
        if (_content)
            _content.remeasure();
        return result;
    }

    override string clean(string text)
    {
        // Line breaks are "\n", whatever they came in as; tabs are four spaces, the font having no
        // glyph for one; other control characters go
        bool plain = true;
        foreach (char c; text)
            if ((c < 0x20 && c != '\n') || c == 0x7F)
                plain = false;
        if (plain)
            return text;
        char[] result;
        result.reserve(text.length);
        foreach (i, char c; text)
        {
            if (c == '\r')
            {
                if (i + 1 >= text.length || text[i + 1] != '\n')
                    result ~= '\n';
                continue;
            }
            if (c == '\t')
            {
                result ~= "    ";
                continue;
            }
            if ((c < 0x20 && c != '\n') || c == 0x7F)
                continue;
            result ~= c;
        }
        return cast(string) result;
    }

    override void fontChanged()
    {
        _charWidth = shapeText(font, "0").width;
        placeChild(_pane);
    }

    override void invalidateText() nothrow @nogc
    {
        if (_content)
            _content.invalidate();
    }

    override void caretMoved()
    {
        _revealCaret = true;
        requestUpdate();
    }

    override void update()
    {
        if (_rewrap)
        {
            _rewrap = false;
            relayout();
        }
        if (_padding != _content.padding)
        {
            _padding = _content.padding;
            placeChild(_pane);
        }
        // The caret's line may not be laid out yet -- a new one at the bottom -- and then the scroll
        // pane can't scroll to it: that waits for the layout, which asks again
        if (_revealCaret && !_linesChanged)
        {
            _revealCaret = false;
            const c = caretBounds;
            const pad = _content.padding;
            _content.scrollIntoView(Bounds(c.minX + pad.left, c.minY + pad.top, c.width, c.height));
        }
    }

    override void enterPressed(ref KeyEvent event)
    {
        if (canEdit())
            type("\n");
        event.consume();
    }

    override void handleKey(ref KeyEvent event)
    {
        // Tab types four spaces; Ctrl+Tab is left to move focus
        if (event.type == KeyEventType.pressed && event.code == KeyCode.tab && !event.control
            && !event.alt && !event.meta && !event.shift && !composing)
        {
            if (canEdit())
                type("    ");
            event.consume();
            return;
        }
        if (event.type == KeyEventType.typed)
            _goalX = float.nan;
        super.handleKey(event);
    }

    // Up and Down a line, Page Up and Page Down a page's worth, keeping across to where they began
    override void verticalKey(ref KeyEvent event)
    {
        const here = lineIndexOf(caretPosition);
        const page = cast(ptrdiff_t)(_pane.boundsInScene.height / lineHeight) - 1;
        ptrdiff_t step;
        switch (event.code)
        {
            case KeyCode.up: step = -1; break;
            case KeyCode.down: step = 1; break;
            case KeyCode.pageUp: step = -(page > 1 ? page : 1); break;
            case KeyCode.pageDown: step = page > 1 ? page : 1; break;
            default: return;
        }
        if (_goalX != _goalX)
            _goalX = xAt(caretPosition);
        const target = cast(ptrdiff_t) here + step;
        size_t to;
        if (target < 0)
            to = 0;
        else if (target >= cast(ptrdiff_t) lines.length)
            to = text.length;
        else
        {
            const l = &lines[target];
            to = l.start + l.line.nearest(_goalX - l.x);
            // Not past a wrapped line's end, which is where the next one starts
            if (!l.breaks && to == l.end)
                to = l.start + l.line.previous(l.line.text.length);
        }
        const goal = _goalX;
        moveCaret(to, event.shift);
        _goalX = goal;
        event.consume();
    }

    override size_t endOf(size_t offset, bool control)
    {
        if (control)
            return text.length;
        const l = &lineOf(offset);
        // A wrapped line's end is where the next one starts, so its caret stops before the wrap's space
        return l.breaks ? l.end : l.start + l.line.previous(l.line.text.length);
    }

    override void selectLineAround(size_t at)
    {
        size_t start = at, end = at;
        while (start > 0 && text[start - 1] != '\n')
            start--;
        while (end < text.length && text[end] != '\n')
            end++;
        selectRange(start, end);
    }

    override void handleMouse(ref MouseEvent event)
    {
        const b = _content.boundsInScene, pad = _content.padding;
        textMouse(event, event.sceneX - b.minX - pad.left, event.sceneY - b.minY - pad.top);
    }

    override void textOriginInScene(out float x, out float y) nothrow @nogc
    {
        const b = _content.boundsInScene, pad = _content.padding;
        x = b.minX + pad.left;
        y = b.minY + pad.top;
    }

    override float textInputCaret() nothrow @nogc
    {
        float x, y;
        textOriginInScene(x, y);
        return x + caretBounds.minX + Theme.caret_width - boundsInScene.minX;
    }

private:
    YGSize contentSize(float width, YGMeasureMode widthMode) nothrow @nogc
    {
        float widest = 0;
        foreach (ref l; lines)
            if (l.line.run.width > widest)
                widest = l.line.run.width;
        // Wrapping, it's as wide as it's given, and asks for its column count's width: what it
        // wants isn't its longest paragraph's, which is only how long it could go on for
        const w = !_wrapText ? widest + Theme.caret_width
                : widthMode != YGMeasureModeUndefined ? width : _prefColumnCount * _charWidth;
        return YGSize(w, lines.length * lineHeight);
    }

    ScrollPane _pane;
    Content _content;
    float _wrapWidth = 0;   // the width lines were last wrapped to
    float _charWidth = 8;   // a "0"'s, for prefColumnCount
    bool _rewrap;           // the width's changed: wrap again in the next update
    bool _revealCaret;      // the caret's moved: scroll to it once it's laid out
    bool _linesChanged;     // the lines changed since the content was last laid out
    Insets _padding;        // the content's, as placeChild last saw it

    // The text itself: what the scroll pane scrolls. It draws the area's text, and is as big as it
    final static class Content : Widget
    {
        TextArea area;
        Tvg_Paint selection, caret;
        TextImage text;

        this(TextArea area)
        {
            this.area = area;
            styleClass.add("content");
            setAccessibleHidden(true);
            YGNodeSetContext(node, cast(void*) this);
            YGNodeSetMeasureFunc(node, &measureContent);
        }

        void remeasure() nothrow @nogc
        {
            YGNodeMarkDirty(node);
            invalidate();
        }

    protected:
        override bool takesChildren() const nothrow @nogc { return false; }

        override void mounted() nothrow
        {
            selection = addPaint();
            text.create();
            addPaint(text.paint);
            caret = addPaint();
        }

        override void unmounted()
        {
            selection = caret = null;
            text.release();
        }

        override void laidOut(float x, float y, float w, float h) nothrow @nogc
        {
            area._linesChanged = false;
            if (area._revealCaret)
                area.requestUpdate(); // now the caret's line is laid out
            const inner = w - YGNodeLayoutGetPadding(node, YGEdgeLeft) - YGNodeLayoutGetPadding(node, YGEdgeRight);
            if (area._wrapText && inner != area._wrapWidth)
            {
                area._wrapWidth = inner;
                area._rewrap = true;
                area.requestUpdate();
            }
            if (padding != area._padding)
                area.requestUpdate();
        }

        override void paint(float x, float y, float w, float h) nothrow @nogc
        {
            area.drawText(selection, text, caret, x + YGNodeLayoutGetPadding(node, YGEdgeLeft),
                          y + YGNodeLayoutGetPadding(node, YGEdgeTop), scene ? scene.pixelScale : 1.0f, behind);
        }
    }
}

/// Yoga measuring the text: as tall as its lines, and as wide as the widest -- or, wrapping, as
/// wide as it's given, which the scroll pane makes its own width.
private extern(C) YGSize measureContent(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                        float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(TextArea.Content) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return self.area.contentSize(width, widthMode);
}
