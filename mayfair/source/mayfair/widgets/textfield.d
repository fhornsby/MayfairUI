module mayfair.widgets.textfield;

import mayfair.accessibility;
import mayfair.animation;
import mayfair.clipboard;
import mayfair.layout;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.widget;

/*
    A single line of editable text. JavaFX's TextField.

        auto name = new TextField().promptText("Your name");
        name.onAction({ greet(name.text); });

    The caret moves by characters as a reader counts them, and by words with Ctrl; Shift extends
    the selection either way, as does dragging, and a double click selects a word -- dragging on
    from there extends it a word at a time -- and a triple click the lot. Ctrl+A, C, X and V do
    what they do everywhere, and Ctrl+Z undoes, a run of typing or deleting at a time, with
    Ctrl+Shift+Z or Ctrl+Y to redo. On Linux, selecting text also makes it the primary selection,
    and a middle click pastes the primary selection where it's clicked. Enter runs the action if
    there is one, and otherwise goes on to the default button, so a form's OK still works from its
    fields. Text too long for the field scrolls to keep the caret in view.

    Text can read right to left, or mix directions: the arrow keys move the way they point, the
    caret sits at the edge of the character it's before whichever side that is, and a selection
    across a change of direction shows as the pieces it is on screen. See EditableLine.

    Typed text arrives as typed key events rather than key presses, so dead keys, compose
    sequences and input methods all work: while an input method is composing, what it has so far
    is shown underlined where it will go, and it becomes text only when committed.

    The caret blinks while the field has focus, restarting with every keystroke so it's always
    visible while typing, and holds still after a few seconds untouched, as GNOME's does. The
    blinking is a Timeline, which wakes the app only to turn the caret on and off.

    To a screen reader it's a text input whose value is its text. Its characters are laid out for
    it in text runs -- where each is, how wide, which way it reads, where the words start -- which
    is what lets a screen reader read by character or word and follow the caret, and the selection
    is reported as the user moves it. It can also be set, and its selection changed, by assistive
    technology.

    Offsets into the text are bytes of UTF-8, as D strings are, and always fall between
    characters: anything given one inside a character moves it to the start of that character.
*/
class TextField : Widget
{
public:
    this(string text = "")
    {
        _font = defaultFont(Theme.text_size);
        focusTraversable(true);
        acceptsTextInput(true);
        cursor(Cursor.text);
        accessibleRole(AccessibleRole.textField);
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureTextField);
        YGNodeStyleSetPadding(node, YGEdgeHorizontal, Theme.text_field_padding_x);
        YGNodeStyleSetPadding(node, YGEdgeVertical, Theme.text_field_padding_y);

        _hoverFade = new Transition(Theme.button_hover_time, (t) { _hoverAmount = t; invalidate(); })
            .interpolator(Interpolator.easeOut);
        _ringFade = new Transition(Theme.focus_ring_time, (t) { _ringAmount = t; invalidate(); })
            .interpolator(Interpolator.easeOut);
        _blink = new Timeline(KeyFrame(Duration.zero, { showCaret(true); }),
                              KeyFrame(Theme.caret_blink_time / 2, { showCaret(false); }),
                              KeyFrame(Theme.caret_blink_time, null));
        _blink.cycleCount(Theme.caret_blink_count).onFinished({ showCaret(true); });

        setText(text);
    }

    string text() const nothrow @nogc { return _text; }

    /// Replaces all of the text, putting the caret at the end. This is the app setting what the
    /// field holds, not the user editing it, so it starts the undo history afresh. Returns this.
    TextField setText(string text)
    {
        const clean = singleLine(text);
        edit(clean, clean.length);
        _undo = _redo = null;
        _lastEdit = EditKind.none;
        return this;
    }

    string promptText() const nothrow @nogc { return _prompt; }

    /// What the field shows, faintly, while it's empty: a hint at what goes in it. Returns this.
    TextField promptText(string text)
    {
        _prompt = text;
        _promptRun = shapeText(_font, text);
        invalidate();
        invalidateAccessible();
        return this;
    }

    /// What to do when Enter is pressed in the field. Returns this, so calls chain.
    TextField onAction(void delegate() handler) nothrow @nogc
    {
        _onAction = handler;
        return this;
    }

    /// Called with the new text whenever it changes, however it changed. Returns this.
    TextField onTextChanged(void delegate(string text) handler) nothrow @nogc
    {
        _onTextChanged = handler;
        return this;
    }

    bool editable() const nothrow @nogc { return _editable; }

    /// Whether the text can be changed by the user. A field that isn't can still be focused,
    /// selected and copied from. Returns this, so calls chain.
    TextField editable(bool on) nothrow @nogc
    {
        _editable = on;
        acceptsTextInput(on);
        invalidate();
        invalidateAccessible();
        return this;
    }

    Font font() nothrow @nogc { return _font; }

    /// Draws with `f` instead of the theme's default. Returns this, so calls chain.
    TextField font(Font f)
    {
        _font = f;
        YGNodeMarkDirty(node);
        promptText(_prompt);
        relayout();
        return this;
    }

    /// Where the caret is.
    size_t caretPosition() const nothrow @nogc { return _caret; }

    /// The other end of the selection from the caret; the same as the caret if nothing's selected.
    size_t anchor() const nothrow @nogc { return _anchor; }

    /// Puts the caret at `offset`, selecting nothing.
    void positionCaret(size_t offset)
    {
        select(snap(offset), snap(offset));
    }

    /// Selects from `anchor` to `caret`, which can be either way round.
    void selectRange(size_t anchor, size_t caret)
    {
        select(snap(anchor), snap(caret));
    }

    void selectAll() { select(0, _text.length); }
    void deselect() { select(_caret, _caret); }

    string selectedText() const nothrow @nogc { return _text[selectionStart .. selectionEnd]; }

    /// Replaces the selection with `text`, or inserts it at the caret if nothing's selected.
    void replaceSelection(string text)
    {
        change(selectionStart, selectionEnd, text, EditKind.other);
    }

    void copy()
    {
        if (_anchor != _caret)
            Clipboard.text = selectedText;
    }

    void cut()
    {
        if (!_editable || _anchor == _caret)
            return;
        copy();
        replaceSelection("");
    }

    void paste()
    {
        if (!_editable)
            return;
        if (auto pasted = Clipboard.text)
            replaceSelection(pasted);
    }

    /// Whether there's an edit to undo, or one undone to redo.
    bool undoable() const nothrow @nogc { return _undo.length > 0; }
    bool redoable() const nothrow @nogc { return _redo.length > 0; }

    /// Takes back the last edit: a run of typing, a run of deleting, or anything else whole.
    void undo()
    {
        if (!_undo.length)
            return;
        _redo ~= snapshot();
        restore(_undo[$ - 1]);
        _undo = _undo[0 .. $ - 1];
    }

    /// Puts back what undo() took back.
    void redo()
    {
        if (!_redo.length)
            return;
        _undo ~= snapshot();
        restore(_redo[$ - 1]);
        _redo = _redo[0 .. $ - 1];
    }

protected:
    override void handleKey(ref KeyEvent event)
    {
        if (event.type == KeyEventType.typed)
        {
            if (_editable)
            {
                _composed = null; // committed, if it was being composed
                change(selectionStart, selectionEnd, event.character, EditKind.typing);
            }
            event.consume();
            return;
        }
        // While an input method is composing, the keys are its to use
        if (event.type != KeyEventType.pressed || _composed.length)
            return;

        const extend = event.shift, byWord = event.control;
        const hasSelection = _anchor != _caret;
        // In a line that reads right to left, the word before is the one to the right
        const rtl = _line.run.rightToLeft;
        switch (event.code)
        {
            case KeyCode.left:
                moveCaret(byWord ? (rtl ? _line.nextWordEnd(_caret) : _line.previousWordStart(_caret))
                        : hasSelection && !extend ? visualEnd(false) : _line.visualNeighbour(_caret, false), extend);
                break;
            case KeyCode.right:
                moveCaret(byWord ? (rtl ? _line.previousWordStart(_caret) : _line.nextWordEnd(_caret))
                        : hasSelection && !extend ? visualEnd(true) : _line.visualNeighbour(_caret, true), extend);
                break;
            case KeyCode.home:
                moveCaret(0, extend);
                break;
            case KeyCode.end:
                moveCaret(_text.length, extend);
                break;
            case KeyCode.backspace:
                if (_editable)
                    deleteTo(byWord ? _line.previousWordStart(_caret) : _line.previous(_caret));
                break;
            case KeyCode.delete_:
                if (_editable)
                    deleteTo(byWord ? _line.nextWordEnd(_caret) : _line.next(_caret));
                break;
            case KeyCode.enter:
            case KeyCode.numpadEnter:
                // Without an action of its own, Enter goes on to the default button
                if (!_onAction)
                    return;
                _onAction();
                break;
            case KeyCode.a:
                if (!event.control)
                    return;
                selectAll();
                break;
            case KeyCode.c:
                if (!event.control)
                    return;
                copy();
                break;
            case KeyCode.x:
                if (!event.control)
                    return;
                cut();
                break;
            case KeyCode.v:
                if (!event.control)
                    return;
                paste();
                break;
            case KeyCode.z:
                if (!event.control)
                    return;
                event.shift ? redo() : undo();
                break;
            case KeyCode.y:
                if (!event.control)
                    return;
                redo();
                break;
            default:
                return; // not ours: Tab, Escape, and keys whose text comes as a typed event
        }
        event.consume();
    }

    override void handleInputMethod(ref InputMethodEvent event)
    {
        if (!_editable)
            return;
        _composed = event.composed;
        _composedCaret = event.caret;
        relayout();
        event.consume();
    }

    override void handleMouse(ref MouseEvent event)
    {
        switch (event.type)
        {
            case MouseEventType.entered:
                _hoverFade.playForward();
                break;
            case MouseEventType.exited:
                _hoverFade.playReverse();
                break;
            case MouseEventType.pressed:
                const at = hitTest(event.x);
                if (event.button == MouseButton.middle)
                {
                    // The primary selection goes in where the click was, leaving any selection here alone
                    requestFocus();
                    if (_editable)
                        if (auto primary = Clipboard.primary)
                            change(at, at, primary, EditKind.other);
                    event.consume();
                    break;
                }
                if (event.button != MouseButton.primary)
                    break;
                requestFocus();
                _selecting = true; // before selecting, so the primary selection waits for the release
                if (event.clickCount >= 3)
                {
                    _dragUnit = DragUnit.all;
                    selectAll();
                }
                else if (event.clickCount == 2)
                {
                    _dragUnit = DragUnit.word;
                    _line.wordAround(at, _dragWordStart, _dragWordEnd);
                    select(_dragWordStart, _dragWordEnd);
                }
                else
                {
                    _dragUnit = DragUnit.character;
                    select(event.shift ? _anchor : at, at);
                }
                event.consume();
                break;
            case MouseEventType.dragged:
                if (_selecting)
                    dragTo(hitTest(event.x));
                break;
            case MouseEventType.released:
                if (_selecting && _anchor != _caret)
                    Clipboard.primary = selectedText;
                _selecting = false;
                break;
            default:
                break;
        }
    }

    override void focusChanged()
    {
        focused ? _ringFade.playForward() : _ringFade.playReverse();
        if (!focused)
        {
            _composed = null; // an input method's unfinished work goes with the focus
            _selecting = false;
            _blink.stop();
            relayout();
        }
        else
        {
            if (focusVisible && !_ownedFocus)
                selectAll(); // tabbed into, as JavaFX does: typing then replaces what was there
            restartBlink();
        }
        // Still the focus owner with focused() false means the window was switched away from, and
        // coming back to it shouldn't select everything again
        _ownedFocus = isFocusOwner;
        invalidate();
    }

    override void disabledChanged()
    {
        hover && !disabled ? _hoverFade.playForward() : _hoverFade.playReverse();
        applyOpacity();
        invalidate();
    }

    override void mounted() nothrow
    {
        // The selection, the text and the caret each need a colour of their own, and all three are
        // clipped to the inside of the field, so text scrolled out of view doesn't show
        _selectionPaint = addPaint();
        _textPaint = addPaint();
        _caretPaint = addPaint();
        foreach (i, p; [_selectionPaint, _textPaint, _caretPaint])
        {
            _clips[i] = tvg_shape_new();
            tvg_paint_set_clip(p, _clips[i]); // held by the paint, and freed with it
        }
        tvg_shape_set_fill_color(_selectionPaint, Theme.selection_colour.tupleof);
        tvg_shape_set_fill_color(_caretPaint, Theme.text_colour.tupleof);
        applyOpacity();
    }

    override void unmounted() nothrow
    {
        _hoverFade.stop();
        _ringFade.stop();
        _blink.stop();
        _hoverAmount = _ringAmount = 0;
        _selecting = false;
        _composed = null;
        _selectionPaint = _textPaint = _caretPaint = null;
        _clips[] = null;
    }

    override float textInputCaret() nothrow @nogc
    {
        return Theme.text_field_padding_x + _line.xAt(displayCaret) - _scrollX;
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // The field, and its border: brighter under the pointer, the accent when focused, and
        // thicker then too, so where typing goes is plain
        const border = Theme.text_field_border_colour
            .interpolate(Theme.text_field_hover_colour, _hoverAmount)
            .interpolate(Theme.focus_ring_colour, _ringAmount);
        tvg_shape_set_fill_color(shape, Theme.text_field_colour.tupleof);
        tvg_shape_append_rect(shape, x, y, w, h, Theme.text_field_radius, Theme.text_field_radius, true);
        tvg_shape_set_stroke_width(shape, 1 + (Theme.focus_ring_width - 1) * _ringAmount);
        tvg_shape_set_stroke_color(shape, border.tupleof);

        const innerX = x + Theme.text_field_padding_x;
        const innerW = w - 2 * Theme.text_field_padding_x;
        const lineHeight = _font.lineHeight;
        _lineTop = y + (h - lineHeight) / 2;

        // Scrolled just enough to keep the caret in view, and no further than the text goes. Only
        // while focused: a field that isn't shows the start of its text, as browsers' do.
        const caretX = _line.xAt(displayCaret);
        auto scroll = focused ? _scrollX : 0;
        if (focused && caretX - scroll > innerW)
            scroll = caretX - innerW;
        if (caretX - scroll < 0)
            scroll = caretX;
        const most = _line.run.width - innerW;
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

        tvg_shape_reset(_selectionPaint);
        if (focused && _anchor != _caret && !_composed.length)
            appendBoxes(_selectionPaint, selectionStart, selectionEnd, _lineTop, lineHeight);

        tvg_shape_reset(_textPaint);
        const baseline = _lineTop + _font.ascender;
        const scale = scene ? scene.scale : 1.0f;
        if (!_line.text.length && _prompt.length)
        {
            tvg_shape_set_fill_color(_textPaint, Theme.prompt_text_colour.tupleof);
            emitRun(_textPaint, _promptRun, _originX, baseline, scale);
        }
        else
        {
            tvg_shape_set_fill_color(_textPaint, Theme.text_colour.tupleof);
            emitRun(_textPaint, _line.run, _originX, baseline, scale);
        }

        tvg_shape_reset(_caretPaint);
        if (focused && _editable && _caretOn && (_anchor == _caret || _composed.length))
            tvg_shape_append_rect(_caretPaint, _originX + caretX - Theme.caret_width / 2, _lineTop,
                                  Theme.caret_width, lineHeight, 0, 0, true);
        // What an input method is composing, underlined, as every platform shows it
        if (_composed.length)
            appendBoxes(_caretPaint, selectionStart, selectionStart + _composed.length, baseline + 2, 1);
    }

    /*
        What a screen reader needs: the text as the value, and the text laid out in runs, each
        saying where every character is, which way it reads, and where words start. A run reads one
        way and holds at most 255 characters -- AccessKit counts a run's characters in bytes -- so
        mixed text, or long text, is several. The selection is given as places in those runs.
    */
    override void describeAccessible(ref AccessibleNode node)
    {
        node.value(_text);
        if (_prompt.length)
            node.placeholder(_prompt);
        if (_editable)
        {
            node.addAction(AccessibleAction.setValue);
            node.addAction(AccessibleAction.replaceSelectedText);
        }
        else
            node.readOnly();
        node.addAction(AccessibleAction.setTextSelection);

        // The text as it stands, without anything an input method hasn't committed yet
        auto line = modelLine();
        _runFirst = accessibleRuns(line);
        const runs = _runFirst.length - 1;
        while (_runIds.length < runs)
            _runIds ~= newAccessibleId();

        foreach (r; 0 .. runs)
        {
            const first = _runFirst[r], last = _runFirst[r + 1];
            const rtl = line.length && line.rightToLeft[first < line.length ? first : $ - 1];
            node.addChild(_runIds[r], AccessibleRole.textRun, (ref AccessibleNode run) {
                // The run's extent, which its characters are measured from: from its right edge,
                // if it reads right to left
                float x0 = float.infinity, x1 = -float.infinity;
                foreach (i; first .. last)
                {
                    if (line.left[i] < x0) x0 = line.left[i];
                    if (line.right[i] > x1) x1 = line.right[i];
                }
                if (first == last)
                    x0 = x1 = line.xAt(line.stops[first]);

                ubyte[] lengths, wordStarts;
                float[] positions, widths;
                foreach (i; first .. last)
                {
                    const bytes = line.stops[i + 1] - line.stops[i];
                    lengths ~= cast(ubyte)(bytes < 255 ? bytes : 255);
                    positions ~= rtl ? x1 - line.right[i] : line.left[i] - x0;
                    widths ~= line.right[i] - line.left[i];
                    if (line.wordStart[i])
                        wordStarts ~= cast(ubyte)(i - first);
                }
                run.value(line.text[line.stops[first] .. line.stops[last]]);
                run.textDirection(rtl);
                run.characters(lengths, positions, widths, wordStarts);
                run.bounds(_originX + x0, _lineTop, x1 - x0, _font.lineHeight);
            });
        }
        node.textSelection(accessiblePosition(line, _anchor), accessiblePosition(line, _caret));
    }

    override bool ownsAccessibleNode(ulong id)
    {
        foreach (runId; _runIds)
            if (runId == id)
                return true;
        return false;
    }

    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        switch (action)
        {
            case AccessibleAction.setValue:
                if (!_editable)
                    return false;
                change(0, _text.length, data.value, EditKind.other); // the user's doing, so it can be undone
                return true;
            case AccessibleAction.replaceSelectedText:
                if (!_editable)
                    return false;
                replaceSelection(data.value);
                return true;
            case AccessibleAction.setTextSelection:
                select(offsetOf(data.anchor), offsetOf(data.focus));
                return true;
            default:
                return super.executeAccessibleAction(action, data);
        }
    }

private:
    /// What an edit was, for deciding whether it joins the one before in the undo history.
    enum EditKind { none, typing, deleting, other }

    /// How a drag that follows a press extends the selection: by the unit the click selected.
    enum DragUnit { character, word, all }

    struct Snapshot
    {
        string text;
        size_t caret, anchor;
    }

    enum charactersPerRun = 255;

    string _text, _prompt;
    Font _font;
    EditableLine _line; // what's shown: the text, with anything being composed in place of the selection
    GlyphRun _promptRun;
    size_t _caret, _anchor;
    bool _editable = true;
    bool _selecting;    // a drag that started with a press here is selecting
    DragUnit _dragUnit;
    size_t _dragWordStart, _dragWordEnd; // the word a double click selected, which a drag keeps
    bool _ownedFocus;   // was the focus owner at the last focus change
    string _composed;   // what an input method has so far, not yet text
    int _composedCaret = -1;
    float _scrollX = 0, _originX = 0, _lineTop = 0; // where the text was last drawn, in window points
    ulong[] _runIds;
    size_t[] _runFirst; // the first character of each accessibility run, and the count at the end
    void delegate() _onAction;
    void delegate(string) _onTextChanged;

    Snapshot[] _undo, _redo;
    EditKind _lastEdit;
    size_t _editCaret;  // where the caret was left by the last edit

    Transition _hoverFade, _ringFade;
    double _hoverAmount = 0, _ringAmount = 0;
    Timeline _blink;
    bool _caretOn = true;
    Tvg_Paint _selectionPaint, _textPaint, _caretPaint;
    Tvg_Paint[3] _clips;

    size_t selectionStart() const nothrow @nogc { return _anchor < _caret ? _anchor : _caret; }
    size_t selectionEnd() const nothrow @nogc { return _anchor < _caret ? _caret : _anchor; }

    /*
        Replaces text[from .. to] with `replacement`, putting the caret after it, and remembers
        what was there for undo. Typing straight on from typing, or deleting straight on from
        deleting, joins the edit before, so undo takes back a run of either rather than a
        character; anything else, or moving the caret in between, starts a new one.
    */
    void change(size_t from, size_t to, string replacement, EditKind kind)
    {
        const clean = singleLine(replacement);
        const continues = kind != EditKind.other && kind == _lastEdit
            && _caret == _anchor && _caret == _editCaret;
        if (!continues)
        {
            _undo ~= snapshot();
            if (_undo.length > Theme.undo_limit)
                _undo = _undo[1 .. $];
        }
        _redo = null;
        edit(_text[0 .. from] ~ clean ~ _text[to .. $], from + clean.length);
        _lastEdit = kind;
        _editCaret = _caret;
    }

    /// The new text, with the caret at `caret` and nothing selected.
    void edit(string text, size_t caret)
    {
        const changed = text != _text;
        _text = text;
        _caret = _anchor = caret;
        relayout();
        restartBlink();
        if (changed && _onTextChanged)
            _onTextChanged(_text);
    }

    Snapshot snapshot() const nothrow @nogc { return Snapshot(_text, _caret, _anchor); }

    void restore(Snapshot s)
    {
        edit(s.text, s.caret);
        _anchor = s.anchor;
        _lastEdit = EditKind.none; // what's typed next is a new edit, not more of an old one
        invalidate();
    }

    void select(size_t anchor, size_t caret)
    {
        if (anchor == _anchor && caret == _caret)
            return;
        _anchor = anchor;
        _caret = caret;
        _lastEdit = EditKind.none; // moving the caret ends a run of typing, for undo
        // Selected text is the primary selection on Linux; a drag's waits for the button to come up
        if (!_selecting && anchor != caret)
            Clipboard.primary = selectedText;
        restartBlink();
        invalidate();
        invalidateAccessible(); // a screen reader follows the caret
    }

    void moveCaret(size_t to, bool extend)
    {
        select(extend ? _anchor : to, to);
    }

    /// Extends a drag's selection to `at`, a character or a word at a time.
    void dragTo(size_t at)
    {
        final switch (_dragUnit)
        {
            case DragUnit.character:
                select(_anchor, at);
                break;
            case DragUnit.word:
                // The word first double-clicked stays selected, whichever way the drag goes
                size_t start, end;
                _line.wordAround(at, start, end);
                if (start < _dragWordStart)
                    select(_dragWordEnd, start);
                else
                    select(_dragWordStart, end > _dragWordEnd ? end : _dragWordEnd);
                break;
            case DragUnit.all:
                break;
        }
    }

    /// Whichever end of the selection is further right on screen, or left: where Right or Left
    /// collapses a selection to.
    size_t visualEnd(bool rightmost) const nothrow @nogc
    {
        const a = _line.xAt(selectionStart), b = _line.xAt(selectionEnd);
        return (a > b) == rightmost ? selectionStart : selectionEnd;
    }

    /// Deletes the selection if there is one, and otherwise from the caret to `to`.
    void deleteTo(size_t to)
    {
        if (_anchor != _caret)
            change(selectionStart, selectionEnd, "", EditKind.other);
        else if (to != _caret)
            change(to < _caret ? to : _caret, to < _caret ? _caret : to, "", EditKind.deleting);
    }

    void showCaret(bool on)
    {
        _caretOn = on;
        invalidate();
    }

    /// Shows the caret and starts it blinking afresh, so it's never off just as the user looks for it.
    void restartBlink()
    {
        _caretOn = true;
        if (focused && _editable)
            _blink.playFromStart();
    }

    /// Shapes what's shown again, after the text or the composition changed.
    void relayout()
    {
        const shown = _composed.length
            ? _text[0 .. selectionStart] ~ _composed ~ _text[selectionEnd .. $]
            : _text;
        _line = editableLine(_font, shown);
        invalidate();
        invalidateAccessible();
    }

    /// The text as it stands, without what an input method is composing.
    EditableLine modelLine()
    {
        return _composed.length ? editableLine(_font, _text) : _line;
    }

    /// Adds boxes around the characters from `from` to `to` in the line: one box, or several where
    /// the text changes direction partway and the characters aren't side by side on screen.
    void appendBoxes(Tvg_Paint paint, size_t from, size_t to, float top, float height) nothrow @nogc
    {
        const first = _line.indexOf(from), last = _line.indexOf(to);
        float x0 = 0, x1 = 0;
        bool open;
        foreach (i; first .. last)
        {
            const l = _line.left[i], r = _line.right[i];
            if (open && (l - x1 < 0.01f && l - x1 > -0.01f))
                x1 = r; // carries on rightwards from the last
            else if (open && (x0 - r < 0.01f && x0 - r > -0.01f))
                x0 = l; // carries on leftwards
            else
            {
                if (open)
                    tvg_shape_append_rect(paint, _originX + x0, top, x1 - x0, height, 0, 0, true);
                x0 = l;
                x1 = r;
                open = true;
            }
        }
        if (open)
            tvg_shape_append_rect(paint, _originX + x0, top, x1 - x0, height, 0, 0, true);
    }

    /// Where the caret is drawn: inside the composition while there is one.
    size_t displayCaret() const nothrow @nogc
    {
        if (!_composed.length)
            return _caret;
        if (_composedCaret < 0)
            return selectionStart + _composed.length;
        // The input method counts its caret in characters, which here means code points
        size_t at = 0;
        foreach (_; 0 .. _composedCaret)
        {
            if (at >= _composed.length)
                break;
            at += strideAt(_composed, at);
        }
        return selectionStart + at;
    }

    /// The offset in the text under a point `x` across the field from its left edge.
    size_t hitTest(float x) const nothrow @nogc
    {
        return _line.nearest(x - Theme.text_field_padding_x + _scrollX);
    }

    /// `offset`, moved back to the start of the character it's in if it's inside one.
    size_t snap(size_t offset) const nothrow @nogc
    {
        if (offset >= _text.length)
            return _text.length;
        return _line.stops[_line.indexOf(offset)];
    }

    /// Where the accessibility runs start, by character: a new one wherever the direction changes
    /// or the last reaches 255 characters. The character count is added at the end.
    static size_t[] accessibleRuns(ref const EditableLine line)
    {
        size_t[] firsts = [0];
        foreach (i; 1 .. line.length)
            if (line.rightToLeft[i] != line.rightToLeft[i - 1] || i - firsts[$ - 1] >= charactersPerRun)
                firsts ~= i;
        return firsts ~ line.length;
    }

    /// A text offset as AccessKit gives places in text: a run, and a character in it. A place
    /// between two runs is at the start of the second, except at the very end.
    AccessibleTextPosition accessiblePosition(ref const EditableLine line, size_t offset) const nothrow @nogc
    {
        const character = line.indexOf(offset);
        size_t r = 0;
        while (r + 2 < _runFirst.length && _runFirst[r + 1] <= character)
            r++;
        return AccessibleTextPosition(_runIds[r], character - _runFirst[r]);
    }

    /// The other way: AccessKit's place in a run back to an offset in the text.
    size_t offsetOf(AccessibleTextPosition p) const nothrow @nogc
    {
        foreach (r, id; _runIds)
        {
            if (id != p.node || r + 1 >= _runFirst.length)
                continue;
            const character = _runFirst[r] + p.character;
            return character < _line.stops.length ? _line.stops[character] : _text.length;
        }
        return _caret; // not one of ours: leave the caret where it is
    }

    void applyOpacity() nothrow @nogc
    {
        const opacity = disabled ? cast(ubyte)(255 * Theme.disabled_opacity) : 255;
        foreach (p; [shape, _selectionPaint, _textPaint, _caretPaint])
            if (p)
                tvg_paint_set_opacity(p, opacity);
    }
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

/// How many bytes the UTF-8 sequence at `at` takes.
private size_t strideAt(const(char)[] text, size_t at) nothrow @nogc
{
    const c = text[at];
    return c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
}

/// Yoga asking how big the field wants to be: a set width, since a field that grew as it was typed
/// into would move everything around it, and one line high. Growing to fill a row still works.
private extern(C) YGSize measureTextField(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                          float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(TextField) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return YGSize(Theme.text_field_width, self._font.lineHeight);
}
