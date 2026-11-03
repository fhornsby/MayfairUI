module mayfair.widgets.label;

import mayfair.accessibility;
import mayfair.clipboard;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.theme;
import mayfair.text;
import mayfair.widgets.accessibletext;
import mayfair.widgets.input;
import mayfair.widgets.menu;
import mayfair.widgets.popup : Popup;
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

    Made selectable, its text can be selected with the mouse and copied: see selectable.

    Given less room than its text needs -- a table's cell, a row that's squeezed -- a line ends in
    an ellipsis where it's cut short, as JavaFX's does, rather than running on past the label's
    edge: see textOverrun.
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
        YGNodeSetBaselineFunc(node, &labelBaseline);    // for Pos.baselineLeft and the like
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

    /// What a line too long for the label's width does: ends in "…" where it's cut, as it does
    /// unless told otherwise, or is cut off at the edge. JavaFX's textOverrun.
    mixin(declareStyleableProperty!(OverrunStyle, "textOverrun", "text-overrun", "OverrunStyle.ellipsis",
                                    q{ invalidate(); }));

    /// Extra room between lines, in points. JavaFX's lineSpacing.
    mixin(declareStyleableProperty!(float, "lineSpacing", "line-spacing", "0", q{ remeasure(); }));

    /*
        Whether its text can be selected and copied, as GTK's selectable labels can: dragged
        across, a word at a time from a double click, all of a line from a triple, and Shift and a
        click to extend. Ctrl+C copies what's selected, Ctrl+A selects everything, and a right click
        shows Copy and Select All. Selecting puts it in the primary selection too, as text fields
        do. A click gives it focus, so the keys reach it, but Tab passes it by, as it's not a
        control. The press still goes on to what it's in, so a selectable label in a list's row
        still selects the row.

        Its style class is "selectable" too while it is, which the theme gives a selection-colour.
    */
    mixin(declareProperty!(bool, "selectable", "false", q{ selectableChanged(); }));

    /// The colour behind selected text. JavaFX's selection-colour, as a text field's.
    mixin(declareStyleableProperty!(Colour, "highlightFill", "selection-colour", "Colour(0, 0, 0, 0)", q{ invalidate(); }));

    /// What's selected, or nothing. Only a selectable label has a selection.
    mixin(declareReadOnlyProperty!(string, "selectedText", "null"));

    /// Selects from `anchor` to `caret`, byte offsets into the text, either way round.
    final void selectRange(size_t anchor, size_t caret)
    {
        select(snap(anchor), snap(caret));
    }

    final void selectAll() { select(0, _text.length); }
    final void deselect() { select(_caret, _caret); }

    /// Copies what's selected to the clipboard, if anything is.
    final void copy()
    {
        if (_anchor != _caret)
            Clipboard.text = _selectedText;
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; } // Yoga measures it, as a leaf

    // As big as its text and no bigger, as a JavaFX Labeled is: see Widget.maxWidth
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }
    override float computeMaxHeight() const nothrow @nogc { return usePrefSize; }

    override void mounted() nothrow
    {
        _selectionPaint = addPaint(); // under the text
        _image.create();
        addPaint(_image.paint);
    }

    override void unmounted()
    {
        _image.release(); // its paint went with the widget's
        _selectionPaint = null;
        _selecting = false;
    }

    override void handleMouse(ref MouseEvent event)
    {
        if (!_selectable)
            return;
        const x = event.x - YGNodeLayoutGetPadding(node, YGEdgeLeft);
        const y = event.y - YGNodeLayoutGetPadding(node, YGEdgeTop);
        // Not consumed: what it's in hears the press too, as a row that selects
        switch (event.type)
        {
            case MouseEventType.pressed:
                if (event.button == MouseButton.secondary)
                    requestFocus(); // for the context menu, which works on what's selected
                if (event.button != MouseButton.primary)
                    break;
                requestFocus();
                layOutLines();
                const at = hitTest(x, y);
                _selecting = true; // the primary selection waits for the release
                _dragUnit = event.clickCount >= 3 ? 2 : event.clickCount == 2 ? 1 : 0;
                if (_dragUnit == 2)
                    lineAround(at, _dragStart, _dragEnd);
                else if (_dragUnit == 1)
                    wordAround(at, _dragStart, _dragEnd);
                else if (event.shift)
                {
                    _dragStart = _dragEnd = _anchor; // extending what's there, from where it started
                    select(_anchor, at);
                    break;
                }
                else
                    _dragStart = _dragEnd = at;
                select(_dragStart, _dragEnd);
                break;
            case MouseEventType.dragged:
                if (_selecting)
                    dragTo(hitTest(x, y));
                break;
            case MouseEventType.released:
                if (_selecting && _anchor != _caret)
                    Clipboard.primary = _selectedText;
                _selecting = false;
                break;
            default:
                break;
        }
    }

    override void handleKey(ref KeyEvent event)
    {
        if (!_selectable || event.type != KeyEventType.pressed || !event.control)
            return;
        if (event.code == KeyCode.c)
        {
            if (_anchor == _caret)
                return; // nothing to copy here: what it's in might have something, as a table its rows
            copy();
        }
        else if (event.code == KeyCode.a)
            selectAll();
        else
            return;
        event.consume();
    }

    override Popup defaultContextMenu()
    {
        if (!_selectable || (menuOnlyForSelection && _anchor == _caret))
            return null;
        _menu = new ContextMenu()
            .add(new MenuItem("Copy", { copy(); }).accelerator("Ctrl+C").disable(_anchor == _caret))
            .add(new MenuSeparator())
            .add(new MenuItem("Select All", { selectAll(); }).accelerator("Ctrl+A")
                 .disable(!_text.length || (selectionStart == 0 && selectionEnd == _text.length)));
        return _menu;
    }

    override void focusChanged()
    {
        if (!focused)
            _selecting = false;
        invalidate(); // the selection shows only while it has focus
    }

    // The lines to select in weren't laid out at the width painted: paint() asked for them
    override void update()
    {
        layOutLines();
        invalidate();
    }

    /*
        Its text, as its value. A selectable label's is laid out in text runs too, as a text field's
        is, so a screen reader can read it by character, word or line, follow what's selected and
        select in it itself.
    */
    override void describeAccessible(ref AccessibleNode node)
    {
        node.value(_text);
        if (!_selectable)
            return;
        layOutLines();
        node.addAction(AccessibleAction.setTextSelection);
        const b = boundsInScene;
        _accessibleText.describe(node, _lines, b.minX + YGNodeLayoutGetPadding(this.node, YGEdgeLeft),
                                 b.minY + YGNodeLayoutGetPadding(this.node, YGEdgeTop), _paragraph.lineHeight,
                                 false, _anchor, _caret);
    }

    override bool ownsAccessibleNode(ulong id)
    {
        return _accessibleText.owns(id);
    }

    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        if (action != AccessibleAction.setTextSelection || !_selectable)
            return super.executeAccessibleAction(action, data);
        layOutLines();
        select(_accessibleText.offsetOf(_lines, data.anchor, _text.length, _anchor),
               _accessibleText.offsetOf(_lines, data.focus, _text.length, _caret));
        return true;
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
        _paintedWidth = w;
        paintSelection(x, y, w);
        _image.begin(scene ? scene.pixelScale : 1.0f, behind);
        // What's selected is over the selection's colour, for subpixel text (see Widget.behind)
        const selecting = _selectable && _anchor != _caret && (focused || (_menu && _menu.showing));
        const selected = behind.covered(_highlightFill);
        float top = y;
        foreach (ref whole; lines)
        {
            // Too long for the width, as rounding can't account for: cut short, with an ellipsis after
            const cut = whole.width > w + 1;
            const line = !cut ? whole
                       : _textOverrun == OverrunStyle.ellipsis ? _paragraph.truncated(whole, w - _ellipsis.width)
                       : _paragraph.truncated(whole, w);
            const ellipsis = cut && _textOverrun == OverrunStyle.ellipsis && _ellipsis.width <= w;
            const shown = line.width + (ellipsis ? _ellipsis.width : 0);
            float left = x;
            if (_textAlignment == TextAlignment.centre)
                left += (w - shown) / 2;
            else if (_textAlignment == TextAlignment.right)
                left += w - shown;
            // A line's origin is its baseline, one ascender below its top
            const baseline = top + _paragraph.ascender;
            if (selecting)
                _image.addLine(_paragraph, line, left, baseline, _textFill, selectionStart, selectionEnd, selected);
            else
                _image.addLine(_paragraph, line, left, baseline, _textFill);
            if (ellipsis)
                _image.addRun(_ellipsis, left + line.width, baseline, _textFill);
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
        _ellipsis = shapeText(_font, "…");    // shaped now, as paint() can't
        if (_anchor || _caret)
            place(0, 0); // what was selected is gone
        remeasure();
        invalidateAccessible();
    }

    void remeasure() nothrow @nogc
    {
        YGNodeMarkDirty(node); // the measured size changed, so the layout above it has to be redone
        _lines = null;         // and the lines to select in, if they're needed
        invalidate();
    }

    void applyFill() nothrow @nogc
    {
        invalidate(); // the colour's in the picture, which is made again
    }

    void selectableChanged()
    {
        setCursor(_selectable ? Cursor.text : Cursor.inherit);
        if (_selectable)
            styleClass.add("selectable");
        else
        {
            styleClass.remove("selectable");
            deselect();
            _selecting = false;
            _lines = null;
        }
    }

    /*
        Selecting. The text's laid out again for it, a line at a time, as text fields lay out
        theirs (see EditableLine), which says where each character is, where words are, and which
        way the text reads. That shapes, which paint() can't, so it's done when there's a click to
        work out, or, if the width's changed since, in the update paint() asks for.
    */
    static struct SelectLine
    {
        size_t start;      // where in the text it starts
        EditableLine line; // to the next line's start, spaces it wrapped at and all, but no line break
        float x = 0, top = 0; // where it is from the text's top left, after alignment
        bool breaks;       // whether a line break ends it, rather than wrapping
    }

    void layOutLines()
    {
        const w = _paintedWidth == _paintedWidth ? _paintedWidth
            : YGNodeLayoutGetWidth(node) - YGNodeLayoutGetPadding(node, YGEdgeLeft) - YGNodeLayoutGetPadding(node, YGEdgeRight);
        if (_lines && _linesWidth == w && _linesAlignment == _textAlignment)
            return;
        _lines = null;
        const laid = _paragraph.lines(_wrapText ? w + 1 : float.infinity);
        const pitch = _paragraph.lineHeight + _lineSpacing;
        foreach (i, ref l; laid)
        {
            float left = 0;
            if (_textAlignment == TextAlignment.centre)
                left = (w - l.width) / 2;
            else if (_textAlignment == TextAlignment.right)
                left = w - l.width;
            // The line takes in what's between it and the next -- the spaces it wrapped at -- so
            // every character is in one, as a screen reader needs; all but a line break
            auto end = i + 1 < laid.length ? laid[i + 1].start : _text.length;
            bool breaks;
            while (end > l.start && (_text[end - 1] == '\n' || _text[end - 1] == '\r'))
            {
                end--;
                breaks = true;
            }
            if (end < l.end)
                end = l.end;
            _lines ~= SelectLine(l.start, editableLine(_font, _text[l.start .. end]), left, i * pitch, breaks);
        }
        invalidateAccessible();
        _linesWidth = w;
        _linesAlignment = _textAlignment;
    }

    /// The offset at `x`, `y` from the text's top left.
    size_t hitTest(float x, float y) nothrow @nogc
    {
        if (!_lines.length)
            return 0;
        const pitch = _paragraph.lineHeight + _lineSpacing;
        const row = y < 0 ? 0 : cast(size_t)(y / pitch);
        const l = &_lines[row < _lines.length ? row : $ - 1];
        return l.start + l.line.nearest(x - l.x);
    }

    void select(size_t anchor, size_t caret)
    {
        if (anchor == _anchor && caret == _caret)
            return;
        place(anchor, caret);
        if (!_selecting && anchor != caret)
            Clipboard.primary = _selectedText;
        invalidate();
        invalidateAccessible(); // a screen reader follows the selection
    }

    void place(size_t anchor, size_t caret)
    {
        _anchor = anchor;
        _caret = caret;
        _setSelectedText(_text[selectionStart .. selectionEnd]);
    }

    size_t selectionStart() const nothrow @nogc { return _anchor < _caret ? _anchor : _caret; }
    size_t selectionEnd() const nothrow @nogc { return _anchor < _caret ? _caret : _anchor; }

    /// Extends a drag to `at`, by the unit its click selected, keeping what that selected.
    void dragTo(size_t at)
    {
        size_t start = at, end = at;
        if (_dragUnit == 1)
            wordAround(at, start, end);
        else if (_dragUnit == 2)
            lineAround(at, start, end);
        if (start < _dragStart)
            select(_dragEnd, start);
        else
            select(_dragStart, end > _dragEnd ? end : _dragEnd);
    }

    void wordAround(size_t at, out size_t start, out size_t end) nothrow @nogc
    {
        foreach_reverse (ref l; _lines)
        {
            if (at < l.start)
                continue;
            l.line.wordAround(at - l.start, start, end);
            start += l.start;
            end += l.start;
            return;
        }
    }

    /// The line `at` is in, between the text's own line breaks: wrapping doesn't end one.
    void lineAround(size_t at, out size_t start, out size_t end) nothrow @nogc
    {
        start = at;
        while (start > 0 && _text[start - 1] != '\n')
            start--;
        end = at;
        while (end < _text.length && _text[end] != '\n')
            end++;
    }

    /// `offset`, at most the text's end, and moved back to the start of the character it's in.
    size_t snap(size_t offset) nothrow @nogc
    {
        if (offset >= _text.length)
            return _text.length;
        while (offset > 0 && (_text[offset] & 0xC0) == 0x80)
            offset--;
        return offset;
    }

    /// Boxes behind the selected characters, with the text's top left at `ox`, `oy`, `w` wide.
    void paintSelection(float ox, float oy, float w) nothrow @nogc
    {
        if (!_selectionPaint)
            return;
        tvg_shape_reset(_selectionPaint);
        const shown = focused || (_menu && _menu.showing); // and while its context menu's about it
        if (!_selectable || _anchor == _caret || !shown)
            return;
        if (!_lines || _linesWidth != w || _linesAlignment != _textAlignment)
        {
            _lines = null;
            requestUpdate(); // which lays them out, and paints again
            return;
        }
        tvg_shape_set_fill_color(_selectionPaint, _highlightFill.tupleof);
        const from = selectionStart, to = selectionEnd;
        foreach (ref l; _lines)
        {
            const end = l.start + l.line.text.length;
            if (end < from || l.start > to)
                continue;
            const first = l.line.indexOf(from > l.start ? from - l.start : 0);
            const last = l.line.indexOf(to < end ? to - l.start : l.line.text.length);
            const top = oy + l.top;
            // One box for each stretch of characters side by side: more than one where the
            // direction changes partway
            float x0 = 0, x1 = 0;
            bool open;
            foreach (i; first .. last)
            {
                const left = l.line.left[i], right = l.line.right[i];
                if (open && left - x1 < 0.01f && left - x1 > -0.01f)
                    x1 = right;
                else if (open && x0 - right < 0.01f && x0 - right > -0.01f)
                    x0 = left;
                else
                {
                    if (open)
                        tvg_shape_append_rect(_selectionPaint, ox + l.x + x0, top, x1 - x0, _paragraph.lineHeight, 0, 0, true);
                    x0 = left;
                    x1 = right;
                    open = true;
                }
            }
            if (open)
                tvg_shape_append_rect(_selectionPaint, ox + l.x + x0, top, x1 - x0, _paragraph.lineHeight, 0, 0, true);
        }
    }

    Paragraph _paragraph;
    GlyphRun _ellipsis;             // "…", for the end of a line cut short
    TextImage _image; // the text, drawn by FreeType (see mayfair.text.raster)
    Tvg_Paint _selectionPaint;
    SelectLine[] _lines;            // laid out to select in, at _linesWidth; null till needed
    float _linesWidth = float.nan, _paintedWidth = float.nan;
    TextAlignment _linesAlignment;
    size_t _anchor, _caret;         // the selection's ends: where it started, and where it's got to
    bool _selecting;                // a press here is being dragged
    int _dragUnit;                  // what the press selected, to drag by: 0 characters, 1 words, 2 lines
    size_t _dragStart, _dragEnd;    // and what it selected, which a drag keeps
    ContextMenu _menu;              // its own context menu, as last shown
    AccessibleText _accessibleText; // its text as a screen reader was last given it, if it's selectable

package:
    // Whether it has a menu of its own only while something's selected, leaving what it's in to
    // show its own otherwise: a table's cell does, so a right click on one copies the rows
    bool menuOnlyForSelection;
}

/// What a line of text too long for its room does. JavaFX's OverrunStyle, less the ones that cut
/// it at the start or in the middle, or by the word.
enum OverrunStyle { clip, ellipsis }

/// How lines of text line up. JavaFX's TextAlignment; justify is left, for now.
enum TextAlignment { left, centre, right, justify }

/*
    Yoga measuring a leaf. It runs inside YGNodeCalculateLayout, so it must not allocate or throw --
    hence the shaping already being done. Wrapping, it wraps to the width Yoga has, whether that's
    all it may have (at most) or what it will have (exactly); with no width to go by, the text's
    as wide as it is on its lines.
*/
/// Where a label's first baseline is, down from its top: Yoga lining labels up by it.
private extern(C) float labelBaseline(YGNodeConstRef node, float width, float height) nothrow @nogc
{
    auto self = cast(Label) YGNodeGetContext(node);
    return self ? YGNodeLayoutGetPadding(node, YGEdgeTop) + self._paragraph.ascender : height;
}

private extern(C) YGSize measureLabel(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                      float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(Label) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    const wrap = self._wrapText && widthMode != YGMeasureModeUndefined;
    float w, h;
    self._paragraph.measure(wrap ? width : float.infinity, self._lineSpacing, w, h);
    // Given at most so much room, no wider than that, as a JavaFX label shrinks: its lines are cut
    // short to fit, with an ellipsis (see textOverrun), rather than running past what it's in
    if (widthMode == YGMeasureModeAtMost && w > width)
        w = width < 0 ? 0 : width;
    return YGSize(w, h);
}
