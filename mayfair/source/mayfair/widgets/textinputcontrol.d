module mayfair.widgets.textinputcontrol;

import core.time : Duration;
import mayfair.accessibility;
import mayfair.animation;
import mayfair.clipboard;
import mayfair.layout;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.text;
import mayfair.theme;
import mayfair.widgets.input;
import mayfair.widgets.menu;
import mayfair.widgets.popup : Popup;
import mayfair.widgets.widget;

/*
    Editable text: what TextField and TextArea have in common. JavaFX's TextInputControl.

    It holds the text, the caret and the selection, and does the editing: typing, deleting,
    moving by characters as a reader counts them and by words, selecting by keyboard and by
    mouse, the clipboard and the primary selection, undo in runs of typing or deleting, input
    methods, and what a screen reader reads and asks for. What the subclass decides is how the
    text is laid out -- one line that scrolls sideways, or lines down a page -- by giving it as
    visual lines (see layoutLines), and where on screen they are.

    The keys are TextField's, and GTK's: the arrows move the way they point, with Ctrl a word at
    a time and Shift selecting; Home and End go to the start and end of the line; Backspace and
    Delete, with Ctrl a word; Ctrl+A, C, X, V, and Ctrl+Z undo and Ctrl+Shift+Z or Ctrl+Y redo. A
    double click selects a word, and dragging on from it extends a word at a time; a triple click
    selects the line, or all of a field. Text can read right to left, or mix directions: see
    EditableLine for how the caret and a selection behave then.

    A right click shows a menu of Cut, Copy, Paste, Delete and Select All, with what can't be done
    disabled, as GTK's fields have; one set with contextMenu takes its place. The click moves the
    caret there first, unless it's on the selection, which the menu is then for.

    Typed text arrives as typed key events rather than key presses, so dead keys, compose
    sequences and input methods all work: while an input method is composing, what it has so far
    is shown underlined where it will go, and it becomes text only when committed.

    The caret blinks while it has focus, restarting with every keystroke so it's always visible
    while typing, and holds still after a few seconds untouched, as GNOME's does.

    To a screen reader it's a text input whose value is its text, laid out in text runs --
    a line at a time, each saying where every character is, which way it reads and where words
    start -- which is what lets a screen reader read by character, word or line and follow the
    caret. Its text and selection can be set by assistive technology too.

    Its text is a property, as JavaFX's is: listen to textProperty to hear every change, typed
    or otherwise, or bind it to show something else -- a control whose text is bound shows what
    it's bound to and can't be typed into, since typing would have to set it. Where the caret is,
    the anchor, and the selected text are read-only properties.

    Offsets into the text are bytes of UTF-8, as D strings are, and always fall between
    characters: anything given one inside a character moves it to the start of that character.
*/
abstract class TextInputControl : Widget
{
public:
    this(string text)
    {
        _font = defaultFont(Theme.text_size);
        _promptRun = shapeText(_font, null);
        setFocusTraversable(true);
        setAcceptsTextInput(true);
        setCursor(Cursor.text);
        _blink = new Timeline(KeyFrame(Duration.zero, { showCaret(true); }),
                              KeyFrame(Theme.caret_blink_time / 2, { showCaret(false); }),
                              KeyFrame(Theme.caret_blink_time));
        _blink.cycleCount(Theme.caret_blink_count).onFinished({ showCaret(true); });
        // The subclass's cleaning and layout, called from here: D's constructors call overrides
        _text = clean(text);
        _caretPosition = _anchor = _text.length;
        relayout();
    }

    /*
        What's in it. Set from outside -- by the app, or a binding -- the caret goes to the end and
        the undo history starts afresh, since it's the app saying what it holds rather than the
        user editing it.
    */
    mixin(declareProperty!(string, "text", `""`, q{ textSet(); }));

    /// What it shows, faintly, while it's empty: a hint at what goes in it.
    mixin(declareProperty!(string, "promptText", "null", q{
        _promptRun = shapeText(_font, _promptText);
        invalidateText();
        invalidateAccessible();
    }));

    /// The colour of the text, and the caret. JavaFX's colour.
    mixin(declareStyleableProperty!(Colour, "textFill", "colour", "Theme.text_colour", q{ invalidateText(); }));

    /// The colour of the prompt text. JavaFX's promptTextFill.
    mixin(declareStyleableProperty!(Colour, "promptTextFill", "prompt-text-colour", "Theme.text_colour", q{ invalidateText(); }));

    /// The colour behind selected text. JavaFX's selection-colour.
    mixin(declareStyleableProperty!(Colour, "highlightFill", "selection-colour", "Colour(0, 0, 0, 0)", q{ invalidateText(); }));

    /// Whether the text can be changed by the user. One that isn't can still be focused,
    /// selected and copied from.
    mixin(declareProperty!(bool, "editable", "true", q{
        setAcceptsTextInput(_editable);
        invalidateText();
        invalidateAccessible();
    }));

    /// What it's drawn with, instead of the theme's default.
    mixin(declareStyleableProperty!(Font, "font", "font, font-family, font-size, font-weight, font-style",
                                    "null", q{
        if (!_font)
            _font = defaultFont(Theme.text_size); // none given, or a stylesheet's taken back
        _promptRun = shapeText(_font, _promptText);
        fontChanged();
        relayout();
    }));

    /// Where the caret is.
    mixin(declareReadOnlyProperty!(size_t, "caretPosition", "0"));

    /// The other end of the selection from the caret; the same as the caret if nothing's selected.
    mixin(declareReadOnlyProperty!(size_t, "anchor", "0"));

    /// What's selected, or nothing.
    mixin(declareReadOnlyProperty!(string, "selectedText", "null"));

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
    void deselect() { select(_caretPosition, _caretPosition); }

    /// Replaces the selection with `text`, or inserts it at the caret if nothing's selected.
    void replaceSelection(string text)
    {
        change(selectionStart, selectionEnd, text, EditKind.other);
    }

    /// Copies the selection to the clipboard: not from a field that conceals its text.
    void copy()
    {
        if (_anchor != _caretPosition && !concealsText)
            Clipboard.text = selectedText;
    }

    void cut()
    {
        if (!canEdit() || _anchor == _caretPosition || concealsText)
            return;
        copy();
        replaceSelection("");
    }

    void paste()
    {
        if (!canEdit())
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
    /*
        A line of the text as it's shown: where in the text it starts, the line itself, and where
        it is, from the top left of the text. A line ends where the text has a line break -- which
        isn't in the line -- or where it wraps, in which case the next starts where it ends.
    */
    static struct VisualLine
    {
        size_t start;
        EditableLine line;
        float x = 0, top = 0;
        bool breaks;          /// Whether a line break in the text ends it, rather than wrapping

        size_t end() const nothrow @nogc { return start + line.text.length; }
    }

    /// The lines of `text`, laid out: the subclass's to say. Called whenever the text, what's
    /// being composed, or the font changes.
    abstract VisualLine[] layoutLines(string text);

    /// `text` as this control holds text: a field takes out line breaks, for instance.
    abstract string clean(string text);

    /// Where the text's top left is, in the window, for a screen reader: the subclass knows where it draws it.
    abstract void textOriginInScene(out float x, out float y) nothrow @nogc;

    /// Something about how the text looks changed: the subclass redraws whatever draws it.
    void invalidateText() nothrow @nogc { invalidate(); }

    /// The font changed, before the text's laid out again in it.
    void fontChanged() {}

    /*
        Whether the text is a secret, shown as dots: a PasswordField's. Then it can't be copied or
        cut, isn't made the primary selection, and a screen reader is given the dots, not the text.
        The subclass lays out the dots itself.
    */
    bool concealsText() const nothrow @nogc { return false; }

    /// The caret moved, or the text changed: a subclass that scrolls might bring it into view.
    void caretMoved() {}

    /// Enter, with nothing composing. A field runs its action; an area starts a new line. Consume
    /// the event if it was used.
    void enterPressed(ref KeyEvent event) {}

    /// Up, Down, Page Up and Page Down, for a control with lines to move between. Consume it if used.
    void verticalKey(ref KeyEvent event) {}

    /// Where Home and End go from `offset`: the start or end of its line, or of the text with Ctrl.
    size_t homeOf(size_t offset, bool control) { return control ? 0 : lineOf(offset).start; }
    size_t endOf(size_t offset, bool control) { return control ? _text.length : lineOf(offset).end; }

    /// What a triple click selects: the line, in an area; everything, in a field.
    void selectLineAround(size_t at) { selectAll(); }

    override void handleKey(ref KeyEvent event)
    {
        if (event.type == KeyEventType.typed)
        {
            if (canEdit())
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
        const hasSelection = _anchor != _caretPosition;
        switch (event.code)
        {
            case KeyCode.left, KeyCode.right:
                const rightwards = event.code == KeyCode.right;
                // In a line that reads right to left, the word before is the one to the right
                const rtl = lineOf(_caretPosition).line.run.rightToLeft;
                size_t to;
                if (byWord)
                    to = rightwards != rtl ? nextWordEnd(_caretPosition) : previousWordStart(_caretPosition);
                else if (hasSelection && !extend)
                    to = visualEnd(rightwards);
                else
                    to = visualNeighbour(_caretPosition, rightwards);
                moveCaret(to, extend);
                break;
            case KeyCode.home:
                moveCaret(homeOf(_caretPosition, event.control), extend);
                break;
            case KeyCode.end:
                moveCaret(endOf(_caretPosition, event.control), extend);
                break;
            case KeyCode.up, KeyCode.down, KeyCode.pageUp, KeyCode.pageDown:
                verticalKey(event);
                return;
            case KeyCode.backspace:
                if (canEdit())
                    deleteTo(byWord ? previousWordStart(_caretPosition) : previous(_caretPosition));
                break;
            case KeyCode.delete_:
                if (canEdit())
                    deleteTo(byWord ? nextWordEnd(_caretPosition) : next(_caretPosition));
                break;
            case KeyCode.enter, KeyCode.numpadEnter:
                enterPressed(event);
                return;
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
        _goalX = float.nan; // any move but up and down forgets where they were heading
        event.consume();
    }

    override void handleInputMethod(ref InputMethodEvent event)
    {
        if (!canEdit())
            return;
        _composed = event.composed;
        _composedCaret = event.caret;
        relayout();
        event.consume();
    }

    /*
        The mouse, at `x`, `y` from the top left of the text: what the subclass works out from the
        event, since it knows where the text is. Call from handleMouse.
    */
    final void textMouse(ref MouseEvent event, float x, float y)
    {
        switch (event.type)
        {
            case MouseEventType.pressed:
                const at = hitTest(x, y);
                if (event.button == MouseButton.middle)
                {
                    // The primary selection goes in where the click was, leaving any selection here alone
                    requestFocus();
                    if (canEdit())
                        if (auto primary = Clipboard.primary)
                            change(at, at, primary, EditKind.other);
                    event.consume();
                    break;
                }
                if (event.button == MouseButton.secondary)
                {
                    // The context menu, which the scene shows next, is for the selection if the
                    // click's on it, and otherwise for where the click is
                    requestFocus();
                    if (at < selectionStart || at > selectionEnd || selectionStart == selectionEnd)
                        positionCaret(at);
                    break;
                }
                if (event.button != MouseButton.primary)
                    break;
                requestFocus();
                _goalX = float.nan;
                _selecting = true; // before selecting, so the primary selection waits for the release
                if (event.clickCount >= 3)
                {
                    _dragUnit = DragUnit.all;
                    selectLineAround(at);
                }
                else if (event.clickCount == 2)
                {
                    _dragUnit = DragUnit.word;
                    wordAround(at, _dragWordStart, _dragWordEnd);
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
                    dragTo(hitTest(x, y));
                break;
            case MouseEventType.released:
                if (_selecting && _anchor != _caretPosition && !concealsText)
                    Clipboard.primary = selectedText;
                _selecting = false;
                break;
            default:
                break;
        }
    }

    override void focusChanged()
    {
        if (!focused)
        {
            _composed = null; // an input method's unfinished work goes with the focus
            _selecting = false;
            _blink.stop();
            relayout();
        }
        else
        {
            if (focusVisible && !_ownedFocus && selectsAllOnTab)
                selectAll(); // tabbed into, as JavaFX does: typing then replaces what was there
            restartBlink();
        }
        // Still the focus owner with focused() false means the window was switched away from, and
        // coming back to it shouldn't select everything again. Nor should coming back from a popup
        // shown over it, such as its context menu: focus goes back to it, but it wasn't tabbed into.
        _ownedFocus = isFocusOwner || (!focused && focusInPopup());
        invalidateText();
    }

    override Popup defaultContextMenu()
    {
        const selected = _anchor != _caretPosition, edits = canEdit();
        _menu = new ContextMenu()
            .add(new MenuItem("Cut", { cut(); }).accelerator("Ctrl+X").disable(!edits || !selected || concealsText))
            .add(new MenuItem("Copy", { copy(); }).accelerator("Ctrl+C").disable(!selected || concealsText))
            .add(new MenuItem("Paste", { paste(); }).accelerator("Ctrl+V").disable(!edits || !Clipboard.hasText))
            .add(new MenuItem("Delete", { replaceSelection(""); }).disable(!edits || !selected))
            .add(new MenuSeparator())
            .add(new MenuItem("Select All", { selectAll(); }).accelerator("Ctrl+A")
                 .disable(!_text.length || (selectionStart == 0 && selectionEnd == _text.length)));
        return _menu;
    }

    /// Whether Tab into it selects everything, as a field does and an area doesn't.
    bool selectsAllOnTab() { return true; }

    override void disabledChanged()
    {
        invalidateText(); // no caret, and no selection
    }

    override void unmounted()
    {
        _blink.stop();
        _selecting = false;
        _composed = null;
    }

    /*
        Draws the text into `text`, the selection into `selection` and the caret and anything
        being composed into `caret`, with the text's top left at `ox`, `oy`. For the subclass's
        paint(), or its content's, which says what's behind it with Widget.behind. The text is
        drawn by FreeType, at `pixelScale` pixels to the point (see mayfair.text.raster).
    */
    final void drawText(Tvg_Paint selection, ref TextImage text, Tvg_Paint caret, float ox, float oy,
                        float pixelScale, Behind behind) nothrow @nogc
    {
        tvg_shape_reset(selection);
        tvg_shape_reset(caret);
        text.begin(pixelScale, behind);
        tvg_shape_set_fill_color(selection, _highlightFill.tupleof);
        tvg_shape_set_fill_color(caret, _textFill.tupleof);
        const lh = lineHeight;

        // Kept while its context menu has focus, since that's what the menu's about
        const selecting = (focused || (_menu && _menu.showing)) && _anchor != _caretPosition && !_composed.length;
        if (selecting)
            appendBoxes(selection, selectionStart, selectionEnd, ox, oy, lh);

        if (!_text.length && !_composed.length && _promptText.length)
            text.addRun(_promptRun, ox, oy + _font.ascender, _promptTextFill);
        else if (!selecting)
            foreach (ref l; _lines)
                text.addRun(l.line.run, ox + l.x, oy + l.top + _font.ascender, _textFill);
        else
        {
            // What's selected is over the selection's colour, not the field's
            const over = behind.covered(_highlightFill);
            const from = selectionStart, to = selectionEnd;
            foreach (ref l; _lines)
                foreach (ref g; l.line.run.glyphs)
                {
                    const at = l.start + g.cluster;
                    text.behind = at >= from && at < to ? over : behind;
                    text.addGlyph(g, ox + l.x + g.x, oy + l.top + _font.ascender + g.y, _textFill);
                }
        }
        text.finish();

        if (focused && canEdit() && _caretOn && (_anchor == _caretPosition || _composed.length))
        {
            const shown = displayCaret;
            const l = lineOf(shown);
            tvg_shape_append_rect(caret, ox + l.x + l.line.xAt(shown - l.start) - Theme.caret_width / 2,
                                  oy + l.top, Theme.caret_width, lh, 0, 0, true);
        }
        // What an input method is composing, underlined, as every platform shows it
        if (_composed.length)
            appendBoxes(caret, selectionStart, selectionStart + _composed.length, ox, oy + _font.ascender + 2, 1);
    }

    /// The caret's box, from the top left of the text: for scrolling it into view.
    final Bounds caretBounds() nothrow @nogc
    {
        const l = lineOf(displayCaret);
        return Bounds(l.x + l.line.xAt(displayCaret - l.start) - Theme.caret_width, l.top,
                      2 * Theme.caret_width, lineHeight);
    }

    /// The offset at `x`, `y` from the top left of the text.
    final size_t hitTest(float x, float y) nothrow @nogc
    {
        size_t li = 0;
        foreach (i, ref l; _lines)
            if (y >= l.top)
                li = i;
        const l = &_lines[li];
        return l.start + l.line.nearest(x - l.x);
    }

    /// How far across its line `offset` is, from the text's left.
    final float xAt(size_t offset) nothrow @nogc
    {
        const l = lineOf(offset);
        return l.x + l.line.xAt(offset - l.start);
    }

    /// The line `offset` is in. At a wrap, the one it starts.
    final ref const(VisualLine) lineOf(size_t offset) nothrow @nogc
    {
        return _lines[lineIndexOf(offset)];
    }

    final size_t lineIndexOf(size_t offset) nothrow @nogc
    {
        size_t lo = 0, hi = _lines.length;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (_lines[mid].start <= offset)
                lo = mid;
            else
                hi = mid;
        }
        return lo;
    }

    final inout(VisualLine)[] lines() inout nothrow @nogc { return _lines; }

    float lineHeight() nothrow @nogc { return _font.lineHeight; }

    override void describeAccessible(ref AccessibleNode node)
    {
        if (_promptText.length)
            node.placeholder(_promptText);
        if (canEdit())
        {
            node.addAction(AccessibleAction.setValue);
            node.addAction(AccessibleAction.replaceSelectedText);
        }
        else
            node.readOnly();
        node.addAction(AccessibleAction.setTextSelection);

        // The text as it stands, without anything an input method hasn't committed yet
        auto model = _composed.length ? layoutLines(_text) : _lines;
        if (concealsText)
        {
            size_t characters;
            foreach (ref l; model)
                characters += l.line.length;
            node.value(concealed(characters));
        }
        else
            node.value(_text);
        float ox, oy;
        textOriginInScene(ox, oy);
        _runs = null;
        foreach (li, ref l; model)
        {
            auto line = &l.line;
            // Runs on this line: a new one wherever the direction changes, or at 255 characters,
            // as AccessKit counts a run's characters in bytes
            size_t[] firsts = [0];
            foreach (i; 1 .. line.length)
                if (line.rightToLeft[i] != line.rightToLeft[i - 1] || i - firsts[$ - 1] >= charactersPerRun)
                    firsts ~= i;
            firsts ~= line.length;
            foreach (r; 0 .. firsts.length - 1)
            {
                _runs ~= Run(nextRunId(), l.start, firsts[r], firsts[r + 1], cast(uint) li);
            }
        }
        foreach (k, ref run; _runs)
        {
            const l = &model[run.lineIndex];
            const line = &l.line;
            const lastOfLine = k + 1 == _runs.length || _runs[k + 1].lineIndex != run.lineIndex;
            // A line that a line break ends has it at the end of its last run, with no width
            const withBreak = lastOfLine && l.breaks && run.lineIndex + 1 < model.length;
            const first = run.first, last = run.last;
            const rtl = line.length && line.rightToLeft[first < line.length ? first : $ - 1];
            const prevId = k > 0 && _runs[k - 1].lineIndex == run.lineIndex ? _runs[k - 1].id : 0;
            const nextId = !lastOfLine ? _runs[k + 1].id : 0;
            node.addChild(run.id, AccessibleRole.textRun, (ref AccessibleNode r) {
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
                    const bytes = concealsText ? concealer.length : line.stops[i + 1] - line.stops[i];
                    lengths ~= cast(ubyte)(bytes < 255 ? bytes : 255);
                    positions ~= rtl ? x1 - line.right[i] : line.left[i] - x0;
                    widths ~= line.right[i] - line.left[i];
                    if (line.wordStart[i])
                        wordStarts ~= cast(ubyte)(i - first);
                }
                string value = concealsText ? concealed(last - first) : line.text[line.stops[first] .. line.stops[last]];
                if (withBreak)
                {
                    value ~= "\n";
                    lengths ~= 1;
                    positions ~= rtl ? 0 : x1 - x0;
                    widths ~= 0;
                }
                r.value(value);
                r.textDirection(rtl);
                r.characters(lengths, positions, widths, wordStarts);
                r.boundsInScene(ox + l.x + x0, oy + l.top, x1 - x0, lineHeight);
                if (prevId)
                    r.previousOnLine(prevId);
                if (nextId)
                    r.nextOnLine(nextId);
            });
        }
        node.textSelection(accessiblePosition(model, _anchor), accessiblePosition(model, _caretPosition));
    }

    override bool ownsAccessibleNode(ulong id)
    {
        foreach (ref run; _runs)
            if (run.id == id)
                return true;
        return false;
    }

    override bool executeAccessibleAction(AccessibleAction action, ref const AccessibleActionData data)
    {
        switch (action)
        {
            case AccessibleAction.setValue:
                if (!canEdit())
                    return false;
                change(0, _text.length, data.value, EditKind.other); // the user's doing, so it can be undone
                return true;
            case AccessibleAction.replaceSelectedText:
                if (!canEdit())
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

    /// Lays the text out again, after it, what's composed, the font or the width changed.
    final void relayout()
    {
        const shown = _composed.length
            ? _text[0 .. selectionStart] ~ _composed ~ _text[selectionEnd .. $]
            : _text;
        _lines = layoutLines(shown);
        invalidateText();
        invalidateAccessible();
    }

    // For subclasses moving the caret by keys of their own
    final void moveCaret(size_t to, bool extend)
    {
        select(extend ? _anchor : to, to);
    }

    /// Replaces text[from .. to] with `replacement`, as the user typing or pasting would.
    final void type(string replacement)
    {
        change(selectionStart, selectionEnd, replacement, EditKind.typing);
    }

    final size_t selectionStart() const nothrow @nogc { return _anchor < _caretPosition ? _anchor : _caretPosition; }
    final size_t selectionEnd() const nothrow @nogc { return _anchor < _caretPosition ? _caretPosition : _anchor; }

    /// Whether the user can change the text: it's editable, and not bound to something else.
    final bool canEdit() nothrow @nogc
    {
        return _editable && !(_textProperty && _textProperty.isBound);
    }

    /// Where up and down are heading across, kept while they're pressed in a row. NaN between.
    float _goalX = float.nan;

    final bool composing() const nothrow @nogc { return _composed.length > 0; }

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

    struct Run
    {
        ulong id;
        size_t lineStart;
        size_t first, last; // characters of its line
        uint lineIndex;
    }

    enum charactersPerRun = 255;

    VisualLine[] _lines; // what's shown: the text, with anything being composed in place of the selection
    GlyphRun _promptRun;
    bool _editing;      // it's changing its own text, as opposed to being told to
    bool _selecting;    // a drag that started with a press here is selecting
    DragUnit _dragUnit;
    size_t _dragWordStart, _dragWordEnd; // the word a double click selected, which a drag keeps
    bool _ownedFocus;   // was the focus owner at the last focus change
    string _composed;   // what an input method has so far, not yet text
    int _composedCaret = -1;
    Run[] _runs;        // the accessibility runs, as last described
    ulong[] _runIds;    // ids handed out for them, reused in order so a screen reader keeps its place
    size_t _nextRun;

    Snapshot[] _undo, _redo;
    EditKind _lastEdit;
    size_t _editCaret;  // where the caret was left by the last edit

    Timeline _blink;
    bool _caretOn = true;
    ContextMenu _menu;  // its own context menu, as last shown

    /// Whether the focus owner is in a popup: where focus has gone, as this loses it.
    bool focusInPopup() nothrow @nogc
    {
        for (auto w = scene ? scene.focusedWidget : null; w; w = w.parent)
            if (cast(Popup) w)
                return true;
        return false;
    }

    ulong nextRunId()
    {
        if (!_runs.length)
            _nextRun = 0;
        if (_nextRun == _runIds.length)
            _runIds ~= newAccessibleId();
        return _runIds[_nextRun++];
    }

    /*
        Replaces text[from .. to] with `replacement`, putting the caret after it, and remembers
        what was there for undo. Typing straight on from typing, or deleting straight on from
        deleting, joins the edit before, so undo takes back a run of either rather than a
        character; anything else, or moving the caret in between, starts a new one.
    */
    void change(size_t from, size_t to, string replacement, EditKind kind)
    {
        const cleaned = clean(replacement);
        const continues = kind != EditKind.other && kind == _lastEdit
            && _caretPosition == _anchor && _caretPosition == _editCaret;
        if (!continues)
        {
            _undo ~= snapshot();
            if (_undo.length > Theme.undo_limit)
                _undo = _undo[1 .. $];
        }
        _redo = null;
        edit(_text[0 .. from] ~ cleaned ~ _text[to .. $], from + cleaned.length);
        _lastEdit = kind;
        _editCaret = _caretPosition;
    }

    /// The new text, with the caret at `caret` and nothing selected. The text goes first, since
    /// the caret, and what it selects, are places in it.
    void edit(string text, size_t caret)
    {
        {
            _editing = true;
            scope(exit) _editing = false;
            setText(text);
        }
        place(caret, caret);
        relayout();
        restartBlink();
        caretMoved();
    }

    /// The text was set from outside, by the app or a binding.
    void textSet()
    {
        if (_editing)
            return; // edit() is seeing to the rest
        const cleaned = clean(_text);
        if (cleaned != _text && !(_textProperty && _textProperty.isBound))
            return setText(cleaned); // which comes back here with it
        _composed = null;
        place(_text.length, _text.length);
        _undo = _redo = null;
        _lastEdit = EditKind.none;
        relayout();
        restartBlink();
        caretMoved();
    }

    /// Moves the caret and anchor, and tells anyone watching.
    void place(size_t anchor, size_t caret)
    {
        _setAnchor(anchor);
        _setCaretPosition(caret);
        _setSelectedText(_text[selectionStart .. selectionEnd]);
    }

    Snapshot snapshot() const nothrow @nogc { return Snapshot(_text, _caretPosition, _anchor); }

    void restore(Snapshot s)
    {
        edit(s.text, s.caret);
        place(s.anchor, s.caret);
        _lastEdit = EditKind.none; // what's typed next is a new edit, not more of an old one
        invalidateText();
    }

    void select(size_t anchor, size_t caret)
    {
        if (anchor == _anchor && caret == _caretPosition)
            return;
        place(anchor, caret);
        _lastEdit = EditKind.none; // moving the caret ends a run of typing, for undo
        // Selected text is the primary selection on Linux; a drag's waits for the button to come up
        if (!_selecting && anchor != caret && !concealsText)
            Clipboard.primary = selectedText;
        restartBlink();
        invalidateText();
        invalidateAccessible(); // a screen reader follows the caret
        caretMoved();
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
                wordAround(at, start, end);
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
    /// collapses a selection to. On different lines, the later's the rightmost.
    size_t visualEnd(bool rightmost) nothrow @nogc
    {
        const a = selectionStart, b = selectionEnd;
        if (lineIndexOf(a) != lineIndexOf(b))
            return rightmost ? b : a;
        return (xAt(a) > xAt(b)) == rightmost ? a : b;
    }

    /// Deletes the selection if there is one, and otherwise from the caret to `to`.
    void deleteTo(size_t to)
    {
        if (_anchor != _caretPosition)
            change(selectionStart, selectionEnd, "", EditKind.other);
        else if (to != _caretPosition)
            change(to < _caretPosition ? to : _caretPosition, to < _caretPosition ? _caretPosition : to, "", EditKind.deleting);
    }

    void showCaret(bool on)
    {
        _caretOn = on;
        invalidateText();
    }

    /// Shows the caret and starts it blinking afresh, so it's never off just as the user looks for it.
    void restartBlink()
    {
        _caretOn = true;
        if (focused && canEdit())
            _blink.playFromStart();
    }

    /*
        Moving about the text, across its lines. Each is the line's own (see EditableLine) inside
        a line, and at a line's end goes on to the next: over the line break between them, or, at
        a wrap, from the last character of one line to the first of the next.
    */
    size_t previous(size_t offset) nothrow @nogc
    {
        const li = lineIndexOf(offset);
        const l = &_lines[li];
        if (offset > l.start || li == 0)
            return l.start + l.line.previous(offset - l.start);
        const p = &_lines[li - 1];
        return p.breaks ? p.end : p.start + p.line.previous(p.line.text.length);
    }

    size_t next(size_t offset) nothrow @nogc
    {
        const li = lineIndexOf(offset);
        const l = &_lines[li];
        if (offset < l.end || li + 1 == _lines.length)
            return l.start + l.line.next(offset - l.start);
        return _lines[li + 1].start; // over the line break
    }

    size_t previousWordStart(size_t offset) nothrow @nogc
    {
        auto li = lineIndexOf(offset);
        while (true)
        {
            const l = &_lines[li];
            if (offset > l.start)
            {
                const to = l.start + l.line.previousWordStart(offset - l.start);
                if (to < offset)
                    return to;
            }
            if (li == 0)
                return 0;
            li--;
            offset = _lines[li].end;
            if (_lines[li].breaks)
                return offset; // the end of the line before is a place of its own
        }
    }

    size_t nextWordEnd(size_t offset) nothrow @nogc
    {
        auto li = lineIndexOf(offset);
        while (true)
        {
            const l = &_lines[li];
            if (offset < l.end)
                return l.start + l.line.nextWordEnd(offset - l.start);
            if (li + 1 == _lines.length)
                return l.end;
            li++;
            offset = _lines[li].start;
            if (_lines[li - 1].breaks)
                return offset;
        }
    }

    size_t visualNeighbour(size_t offset, bool rightwards) nothrow @nogc
    {
        const l = &lineOf(offset);
        const to = l.start + l.line.visualNeighbour(offset - l.start, rightwards);
        if (to != offset)
            return to;
        // Off the end of the line: on to the next, or back to the one before, whichever way it reads
        return rightwards != l.line.run.rightToLeft ? next(offset) : previous(offset);
    }

    void wordAround(size_t offset, out size_t start, out size_t end) nothrow @nogc
    {
        const l = &lineOf(offset);
        l.line.wordAround(offset - l.start, start, end);
        start += l.start;
        end += l.start;
    }

    /// `offset`, moved back to the start of the character it's in if it's inside one.
    size_t snap(size_t offset) nothrow @nogc
    {
        if (offset >= _text.length)
            return _text.length;
        const l = &lineOf(offset);
        if (offset >= l.end)
            return offset;
        return l.start + l.line.stops[l.line.indexOf(offset - l.start)];
    }

    /// Adds boxes around the characters from `from` to `to`, a line at a time: one box a line, or
    /// several where the text changes direction partway and the characters aren't side by side.
    void appendBoxes(Tvg_Paint paint, size_t from, size_t to, float ox, float oy, float height) nothrow @nogc
    {
        foreach (ref l; _lines)
        {
            if (l.end < from || l.start > to)
                continue;
            const a = from > l.start ? from - l.start : 0;
            const b = to < l.end ? to - l.start : l.line.text.length;
            const first = l.line.indexOf(a), last = l.line.indexOf(b);
            float x0 = 0, x1 = 0;
            bool open;
            void box()
            {
                tvg_shape_append_rect(paint, ox + l.x + x0, oy + l.top, x1 - x0, height, 0, 0, true);
            }
            foreach (i; first .. last)
            {
                const left = l.line.left[i], right = l.line.right[i];
                if (open && (left - x1 < 0.01f && left - x1 > -0.01f))
                    x1 = right; // carries on rightwards from the last
                else if (open && (x0 - right < 0.01f && x0 - right > -0.01f))
                    x0 = left; // carries on leftwards
                else
                {
                    if (open)
                        box();
                    x0 = left;
                    x1 = right;
                    open = true;
                }
            }
            // A line break that's selected shows as a little space at the end of its line
            if (l.breaks && to > l.end && from <= l.end && &l !is &_lines[$ - 1])
            {
                const edge = l.line.run.width;
                if (!open)
                {
                    x0 = edge;
                    open = true;
                }
                x1 = (x1 > edge ? x1 : edge) + _font.lineHeight / 4;
            }
            if (open)
                box();
        }
    }

    /// Where the caret is drawn: inside the composition while there is one.
    size_t displayCaret() const nothrow @nogc
    {
        if (!_composed.length)
            return _caretPosition;
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

    /// A text offset as AccessKit gives places in text: a run, and a character in it. A place
    /// between two runs is at the start of the second, except at the very end.
    AccessibleTextPosition accessiblePosition(const(VisualLine)[] model, size_t offset) nothrow @nogc
    {
        foreach_reverse (ref run; _runs)
        {
            const l = &model[run.lineIndex];
            if (offset < l.start)
                continue;
            const character = l.line.indexOf(offset - l.start);
            if (character >= run.first)
                return AccessibleTextPosition(run.id, character - run.first);
        }
        return AccessibleTextPosition(_runs.length ? _runs[0].id : 0, 0);
    }

    /// The other way: AccessKit's place in a run back to an offset in the text.
    size_t offsetOf(AccessibleTextPosition p) nothrow @nogc
    {
        foreach (ref run; _runs)
        {
            if (run.id != p.node)
                continue;
            const character = run.first + p.character;
            const l = &_lines[run.lineIndex < _lines.length ? run.lineIndex : $ - 1];
            if (character >= l.line.stops.length)
                return l.end < _text.length ? l.end + (l.breaks ? 1 : 0) : _text.length;
            return l.start + l.line.stops[character];
        }
        return _caretPosition; // not one of ours: leave the caret where it is
    }
}

/// What a field that conceals its text shows for each character.
package enum concealer = "•";

/// `characters` of them.
package string concealed(size_t characters)
{
    import std.array : replicate;

    return concealer.replicate(characters);
}

/// How many bytes the UTF-8 sequence at `at` takes.
private size_t strideAt(const(char)[] text, size_t at) nothrow @nogc
{
    const c = text[at];
    return c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
}
