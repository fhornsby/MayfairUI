module mayfair.widgets.textview;

/*
    A view of a TextBuffer, to read and edit: GTK's GtkTextView, with the parts of GtkSourceView a
    code editor wants -- line numbers, the current line highlighted, matching brackets, indenting
    as it's typed, tabs as spaces, finding and replacing.

        auto view = new TextView(new TextBuffer(readText("app.d")));
        view.showLineNumbers(true).highlightCurrentLine(true);
        view.styleClass.add("code");     // monospaced, in the theme

    It's made for big files: only the lines near what's in view are shaped and drawn, in blocks of
    lines that stay drawn as it scrolls, so a file of a hundred thousand lines scrolls as one of a
    hundred does. Lines don't wrap: long ones scroll sideways.

    The keys are a code editor's: the arrows, Home (to the line's first non-blank, then its start)
    and End, Page Up and Down, with Ctrl a word or the whole text, with Shift selecting; Backspace
    and Delete, with Ctrl a word; Enter, indenting the new line as the last; Tab and Shift+Tab,
    indenting or outdenting what's selected; Alt+Up and Down moving lines; Ctrl+Shift+K deleting
    them; Ctrl+/ commenting them out (given lineComment); Ctrl+A, C, X, V, Z, Shift+Z and Y. A
    double click selects a word, a triple click a line, and dragging on from either extends by
    the same; the middle button pastes the primary selection, as Linux does. Input methods
    compose in place, underlined.

    Its tags style the text (see TextBuffer.applyTag), and a highlighter's styling is drawn under
    them (TextBuffer.setHighlights): mayfair-code highlights code by language, and shows what a
    language server says. Its style class is "text-view", and its parts `.gutter` and `.content`;
    the theme's "code" class makes it monospaced.
*/

import core.time : Duration;
import std.algorithm : max, min;
import std.math : ceil, floor, round;
import std.uni : isAlphaNum, isWhite;
import std.utf : decode, stride, strideBack;
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
import mayfair.widgets.scrollpane;
import mayfair.widgets.widget;

class TextView : Widget
{
public:
    this(TextBuffer buffer = null)
    {
        styleClass.add("text-view");
        setAccessibleRole(AccessibleRole.textArea);
        setFocusTraversable(true);
        setAcceptsTextInput(true);
        setCursor(Cursor.text);
        YGNodeStyleSetFlexDirection(node, YGFlexDirectionRow);
        _font = monospaceFont(Theme.text_size);
        gutter = new Gutter(this);
        content = new Content(this);
        pane = new ScrollPane(content);
        pane.setAccessibleHidden(true);
        pane.setGrow(1);
        adopt(gutter);
        adopt(pane);
        pane.vvalueProperty.addListener((float was, float now) { scrolled(); });
        pane.hvalueProperty.addListener((float was, float now) { scrolled(); });
        blink = new Timeline(KeyFrame(Duration.zero, { showCaret(true); }),
                             KeyFrame(Theme.caret_blink_time / 2, { showCaret(false); }),
                             KeyFrame(Theme.caret_blink_time));
        blink.cycleCount(Theme.caret_blink_count).onFinished({ showCaret(true); });
        setBuffer(buffer ? buffer : new TextBuffer);
    }

    /// What it shows and edits.
    mixin(declareProperty!(TextBuffer, "buffer", "null", q{ bufferChanged(); }));

    /// Whether it can be typed into.
    mixin(declareProperty!(bool, "editable", "true", q{ setAcceptsTextInput(_editable); refresh(); }));

    /// Whether the line numbers show, down the left.
    mixin(declareProperty!(bool, "showLineNumbers", "false", q{ gutterChanged(); }));

    /// Whether the caret's line is highlighted.
    mixin(declareProperty!(bool, "highlightCurrentLine", "false", q{ refresh(); }));

    /// Whether the bracket matching the one at the caret is highlighted.
    mixin(declareProperty!(bool, "matchBrackets", "true", q{ refresh(); }));

    /// How many spaces wide a tab is.
    mixin(declareProperty!(int, "tabWidth", "4", q{ relayoutText(); }));

    /// Whether Tab puts in spaces rather than a tab.
    mixin(declareProperty!(bool, "insertSpaces", "false"));

    /// Whether a new line starts indented as the one before, and further after an opening bracket.
    mixin(declareProperty!(bool, "autoIndent", "true"));

    /// What starts a comment to the end of the line, for Ctrl+/: "//", "#". None by default.
    mixin(declareProperty!(string, "lineComment", "null"));

    /// Where the caret is.
    mixin(declareReadOnlyProperty!(TextPosition, "caretPosition", "TextPosition.init"));

    /// Where the selection starts: the caret's other end. The same as the caret for none.
    mixin(declareReadOnlyProperty!(TextPosition, "anchor", "TextPosition.init"));

    /// How many matches the last find() found.
    mixin(declareReadOnlyProperty!(int, "matchCount", "0"));

    // Its look, from the stylesheet

    mixin(declareStyleableProperty!(Font, "font", "font, font-family, font-size, font-weight, font-style", "null", q{
        if (!_font)
            _font = monospaceFont(Theme.text_size); // none given, or a stylesheet's taken back
        relayoutText();
    }));
    mixin(declareStyleableProperty!(Colour, "textFill", "colour", "Theme.text_colour", q{ refreshText(); }, true));
    mixin(declareStyleableProperty!(Colour, "highlightFill", "selection-colour", "Colour(0, 120, 215, 90)", q{ refresh(); }));
    mixin(declareStyleableProperty!(Colour, "currentLineFill", "current-line-colour", "Colour(128, 128, 128, 26)", q{ refresh(); }));
    mixin(declareStyleableProperty!(Colour, "lineNumberFill", "line-number-colour", "Colour(128, 128, 128, 255)", q{ gutter.invalidate(); }));
    mixin(declareStyleableProperty!(Colour, "caretFill", "caret-colour", "Theme.text_colour", q{ refresh(); }));
    mixin(declareStyleableProperty!(Colour, "bracketFill", "bracket-colour", "Colour(128, 128, 128, 70)", q{ refresh(); }));
    mixin(declareStyleableProperty!(Colour, "matchFill", "match-colour", "Colour(255, 200, 0, 110)", q{ refresh(); }));
    /// Line spacing, as a multiple of the font's.
    mixin(declareStyleableProperty!(float, "lineSpacing", "line-spacing", "1.25", q{ relayoutText(); }));

    // The caret and the selection

    bool hasSelection() const nothrow @nogc { return _anchor != _caretPosition; }

    /// The selection's start and end, in order.
    TextPosition selectionStart() const nothrow @nogc { return _anchor < _caretPosition ? _anchor : _caretPosition; }
    TextPosition selectionEnd() const nothrow @nogc { return _anchor < _caretPosition ? _caretPosition : _anchor; } /// ditto

    string selectedText() { return _buffer.textIn(selectionStart, selectionEnd); }

    /// Selects from `anchor` to `caret`, the caret at `caret`, and scrolls it into view.
    void select(TextPosition anchor, TextPosition caret)
    {
        _buffer.moveMark(anchorMark, anchor);
        _buffer.moveMark(caretMark, caret);
        caretMoved(true);
    }

    /// Puts the caret at `at`, selecting nothing.
    void placeCaret(TextPosition at) { select(at, at); }

    void selectAll() { select(TextPosition(0, 0), _buffer.endPosition); }

    /// Replaces the selection with `text` -- or puts it in at the caret -- as typing does.
    void replaceSelection(string text, string merge = null)
    {
        if (!_editable)
            return;
        const end = _buffer.replace(selectionStart, selectionEnd, text, merge);
        placeCaret(end);
    }

    void copy()
    {
        if (hasSelection)
            Clipboard.text = selectedText;
    }

    void cut()
    {
        if (!hasSelection || !_editable)
            return;
        copy();
        _buffer.breakMerging();
        replaceSelection("");
    }

    void paste()
    {
        if (!_editable)
            return;
        if (auto text = Clipboard.text)
        {
            _buffer.breakMerging();
            replaceSelection(text);
            _buffer.breakMerging();
        }
    }

    void undo()
    {
        if (_editable && _buffer.canUndo)
            placeCaret(_buffer.undo());
    }

    void redo()
    {
        if (_editable && _buffer.canRedo)
            placeCaret(_buffer.redo());
    }

    // Finding

    /*
        Finds `query`, highlighting every match, and selects the next from the caret on -- or,
        `backwards`, the one before it. matchCount says how many there are. Empty stops finding.
    */
    void find(string query, bool matchCase = false, bool wholeWord = false, bool backwards = false)
    {
        _query = query;
        _matchCase = matchCase;
        _wholeWord = wholeWord;
        markMatches();
        if (query.length)
            findNext(backwards);
    }

    /// The next match, or the one before: wrapping round. False if there's none.
    bool findNext(bool backwards = false)
    {
        TextPosition s, e;
        const from = backwards ? selectionStart : selectionEnd;
        if (!_buffer.find(_query, from, s, e, _matchCase, _wholeWord, backwards))
            return false;
        select(s, e);
        return true;
    }

    /// Replaces the selection with `replacement` if it's a match, and finds the next.
    void replaceNext(string replacement)
    {
        if (!_editable || !_query.length)
            return;
        TextPosition s, e;
        if (hasSelection && _buffer.find(_query, selectionStart, s, e, _matchCase, _wholeWord, false, false)
            && s == selectionStart && e == selectionEnd)
        {
            _buffer.breakMerging();
            replaceSelection(replacement);
        }
        findNext();
    }

    /// Replaces every match with `replacement`, as one edit. How many it replaced.
    int replaceAll(string replacement)
    {
        if (!_editable || !_query.length)
            return 0;
        auto all = _buffer.findAll(_query, _matchCase, _wholeWord);
        _buffer.beginUserAction();
        foreach_reverse (m; all)
            _buffer.replace(m[0], m[1], replacement);
        _buffer.endUserAction();
        markMatches();
        return cast(int) all.length;
    }

    // Where things are

    /// Scrolls so `at` is in view, with a little room round it.
    void scrollTo(TextPosition at)
    {
        at = _buffer.clamp(at);
        const vp = pane.viewportBounds;
        const lh = lineHeight;
        const y = padTop + at.line * lh, x = padLeft + xAt(at);
        float sx = vp.minX, sy = vp.minY;
        if (y < vp.minY)
            sy = y - lh;
        else if (y + lh > vp.maxY)
            sy = y + 2 * lh - vp.height;
        if (x < vp.minX + 20)
            sx = x - vp.width / 3;
        else if (x > vp.maxX - 20)
            sx = x - vp.width * 2 / 3;
        if (sx != vp.minX || sy != vp.minY)
        {
            pendingX = sx;
            pendingY = sy;
            scrollPending = true;
            content.requestUpdate();
        }
    }

    /// Where `at` is in the window: its character's box, a line tall. For a popup by the caret.
    Bounds rectInScene(TextPosition at)
    {
        at = _buffer.clamp(at);
        const b = content.boundsInScene, vp = pane.viewportBounds;
        const x = b.minX + padLeft + xAt(at), y = b.minY + padTop + at.line * lineHeight;
        // boundsInScene is the content's as it's drawn: scrolled already
        return Bounds(x, y, max(1f, charWidth), lineHeight);
    }

    /// The place nearest `sceneX`, `sceneY` in the window.
    TextPosition positionAtScene(float sceneX, float sceneY)
    {
        const b = content.boundsInScene;
        return positionAt(sceneX - b.minX, sceneY - b.minY);
    }

    /// How tall a line is, in points.
    float lineHeight() const nothrow @nogc { return lineH; }

    /// Hears every key before the view does: true from it means it took the key. For a completion
    /// list over the view, which takes Up, Down and Enter while it's showing.
    void addKeyFilter(bool delegate(ref KeyEvent) filter) { keyFilters ~= filter; }

    /// Hears the pointer resting on a place in the text for a moment: for a tooltip of what's there.
    TextView onHover(void delegate(TextPosition at, float sceneX, float sceneY) handler) { _onHover = handler; return this; }

    /// Hears a Ctrl+click on a place in the text: for going to where what's there is defined.
    TextView onControlClick(void delegate(TextPosition at) handler) { _onControlClick = handler; return this; }

    /// A coloured mark beside a line, in the gutter, that moves with the text: a diagnostic's, a
    /// breakpoint. Removed with removeGutterMark.
    void addGutterMark(TextMark mark, Colour colour)
    {
        gutterMarks ~= GutterMark(mark, colour);
        gutter.invalidate();
    }

    /// ditto
    void removeGutterMark(TextMark mark)
    {
        foreach (i, g; gutterMarks)
            if (g.mark is mark)
            {
                gutterMarks = gutterMarks[0 .. i] ~ gutterMarks[i + 1 .. $];
                break;
            }
        gutter.invalidate();
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void handleKey(ref KeyEvent event)
    {
        foreach (f; keyFilters)
            if (f(event))
            {
                event.consume();
                return;
            }
        if (event.type == KeyEventType.typed)
        {
            if (!_editable || !event.character.length)
                return;
            composed = null;
            typed(event.character);
            event.consume();
            return;
        }
        if (event.type != KeyEventType.pressed || composed.length)
            return;
        if (key(event))
        {
            event.consume();
            restartBlink();
        }
    }

    override void handleInputMethod(ref InputMethodEvent event)
    {
        if (!_editable)
            return;
        composed = event.composed;
        refresh();
        event.consume();
    }

    override void focusChanged()
    {
        if (focused)
            restartBlink();
        else
        {
            blink.stop();
            composed = null;
        }
        refresh();
    }

    override Popup defaultContextMenu()
    {
        const selected = hasSelection, edits = _editable;
        return new ContextMenu()
            .add(new MenuItem("Undo", { undo(); }).accelerator("Ctrl+Z").disable(!edits || !_buffer.canUndo))
            .add(new MenuItem("Redo", { redo(); }).accelerator("Ctrl+Shift+Z").disable(!edits || !_buffer.canRedo))
            .add(new MenuSeparator())
            .add(new MenuItem("Cut", { cut(); }).accelerator("Ctrl+X").disable(!edits || !selected))
            .add(new MenuItem("Copy", { copy(); }).accelerator("Ctrl+C").disable(!selected))
            .add(new MenuItem("Paste", { paste(); }).accelerator("Ctrl+V").disable(!edits || !Clipboard.hasText))
            .add(new MenuItem("Delete", { replaceSelection(""); }).disable(!edits || !selected))
            .add(new MenuSeparator())
            .add(new MenuItem("Select All", { selectAll(); }).accelerator("Ctrl+A"));
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        // Its text, as far as it's reasonable to read out: a long file's start
        auto t = _buffer.text;
        node.value(t.length > 100_000 ? t[0 .. 100_000] : t);
        if (!_editable)
            node.readOnly();
    }

private:
    Gutter gutter;
    Content content;
    ScrollPane pane;
    TextBuffer watching;
    TextMark caretMark, anchorMark;
    Timeline blink;
    bool caretOn = true;
    string composed;            // what an input method has so far
    float goalX = float.nan;    // where Up and Down keep to, across
    bool delegate(ref KeyEvent)[] keyFilters;
    void delegate(TextPosition, float, float) _onHover;
    void delegate(TextPosition) _onControlClick;
    string _query;
    bool _matchCase, _wholeWord;
    TextTag matchTag;
    GutterMark[] gutterMarks;
    bool scrollPending;
    float pendingX = 0, pendingY = 0;

    // Metrics: refreshed when the font changes
    float lineH = 18, ascent = 14, charWidth = 8, spaceWidth = 8;
    enum float padLeft = 8, padTop = 4;

    // What's been shaped, by line id: kept for the lines near the view
    ShapedLine[ulong] shaped;
    size_t widestChars;         // the longest line's length, for the content's width
    bool widestStale = true;

    struct GutterMark
    {
        TextMark mark;
        Colour colour;
    }

    void bufferChanged()
    {
        if (watching)
        {
            watching.removeListener(&edited);
            watching.removeTagListener(&tagsChanged);
            if (caretMark)
            {
                watching.deleteMark(caretMark);
                watching.deleteMark(anchorMark);
            }
            if (matchTag)
                watching.removeTagEverywhere(matchTag);
        }
        watching = _buffer;
        if (!_buffer)
            return;
        _buffer.addListener(&edited);
        _buffer.addTagListener(&tagsChanged);
        caretMark = _buffer.createMark(TextPosition(0, 0));
        anchorMark = _buffer.createMark(TextPosition(0, 0));
        matchTag = new TextTag("match").ranked(-10);
        shaped = null;
        widestStale = true;
        content.blocks = null;
        content.dropBlocks();
        _setCaretPosition(TextPosition(0, 0));
        _setAnchor(TextPosition(0, 0));
        relayoutText();
    }

    // The buffer changed: what's drawn of the lines it changed goes, and the caret follows its mark
    void edited(ref const BufferChange c)
    {
        widestStale = true;
        content.linesChanged(c.start.line);
        if (_query.length)
            markMatches();
        caretMoved(false);
        gutterChanged();
    }

    void tagsChanged(int from, int to)
    {
        content.tagsChanged(from, to);
    }

    void caretMoved(bool reveal)
    {
        const was = _caretPosition;
        _setCaretPosition(caretMark.position);
        _setAnchor(anchorMark.position);
        if (was.line != _caretPosition.line)
            gutter.invalidate();
        if (reveal)
        {
            goalX = float.nan;
            scrollTo(_caretPosition);
            restartBlink();
            if (hasSelection)
                Clipboard.primary = selectedText;
        }
        refresh();
    }

    void showCaret(bool on)
    {
        caretOn = on;
        content.showCaret();
    }

    void restartBlink()
    {
        caretOn = true;
        content.showCaret();
        if (focused && _editable)
            blink.playFromStart();
    }

    void refresh()
    {
        content.decorationsStale = true;
        content.requestUpdate();
    }

    void refreshText()
    {
        content.dropBlocks();
        refresh();
    }

    void relayoutText()
    {
        if (!_buffer)
            return;
        auto f = _font;
        lineH = round(f.lineHeight * (_lineSpacing > 0 ? _lineSpacing : 1));
        ascent = round(f.ascender + (lineH - f.lineHeight) / 2);
        charWidth = shapeText(f, "0").width;
        spaceWidth = shapeText(f, " ").width;
        shaped = null;
        widestStale = true;
        content.dropBlocks();
        content.remeasure();
        gutterChanged();
        refresh();
    }

    void gutterChanged()
    {
        gutter.resize();
        gutter.invalidate();
    }

    void scrolled()
    {
        gutter.invalidate();
        content.requestUpdate();
    }

    void markMatches()
    {
        _buffer.removeTagEverywhere(matchTag);
        if (!_query.length)
        {
            _setMatchCount(0);
            return;
        }
        matchTag.fill(_matchFill);
        auto all = _buffer.findAll(_query, _matchCase, _wholeWord);
        foreach (m; all)
            _buffer.applyTag(matchTag, m[0], m[1]);
        _setMatchCount(cast(int) all.length);
    }

    // Shaping

    /// Line `i`, shaped: kept by its id, and its styling's bold and italic.
    ref ShapedLine shapedLine(int i)
    {
        const id = _buffer.lineId(i);
        auto spans = styleSpans(i);
        const key = id ^ (fontKey(spans) * 0x9E3779B97F4A7C15UL);
        if (auto s = key in shaped)
            return *s;
        shaped[key] = shapeLine(_buffer.line(i), spans);
        return shaped[key];
    }

    /// The tags and highlights on line `i`, highlights first, then tags by priority: the order they're drawn in.
    TagSpan[] styleSpans(int i)
    {
        TagSpan[] all = _buffer.highlightsOn(i).dup;
        auto tagged = _buffer.tagsOn(i).dup;
        import std.algorithm : sort;
        tagged.sort!((a, b) => a.tag.priority < b.tag.priority);
        return all ~ tagged;
    }

    static ulong fontKey(const TagSpan[] spans)
    {
        ulong k;
        foreach (s; spans)
            if (s.tag.bold || s.tag.italic)
                k = k * 31 + (s.start * 7 + s.end * 13 + (s.tag.bold ? 1 : 0) + (s.tag.italic ? 2 : 0));
        return k;
    }

    /*
        A line, shaped: split where tabs are, and where bold or italic start and stop, each piece
        shaped on its own in its font and laid end to end, tabs to the next tab stop. And where
        across it each place in it is, for the caret, the selection and the pointer.
    */
    ShapedLine shapeLine(string text, const TagSpan[] spans)
    {
        ShapedLine s;
        s.xs = new float[text.length + 1];
        s.xs[] = float.nan;
        size_t[] cuts = [0, text.length];
        foreach (i, char c; text)
            if (c == '\t')
                cuts ~= [i, i + 1];
        foreach (sp; spans)
            if (sp.tag.bold || sp.tag.italic)
                cuts ~= [min(sp.start, text.length), min(sp.end, text.length)];
        import std.algorithm : sort, uniq;
        import std.array : array;
        cuts = cuts.sort.uniq.array;
        float pen = 0;
        const tabStop = spaceWidth * (_tabWidth > 0 ? _tabWidth : 4);
        foreach (k; 0 .. cuts.length - 1)
        {
            const a = cuts[k], b = cuts[k + 1];
            if (a >= b)
                continue;
            s.xs[a] = pen;
            if (text[a] == '\t' && b == a + 1)
            {
                pen = (floor(pen / tabStop + 0.001f) + 1) * tabStop;
                continue;
            }
            bool bold, italic;
            foreach (sp; spans)
                if (sp.start <= a && sp.end >= b && (sp.tag.bold || sp.tag.italic))
                {
                    bold |= sp.tag.bold;
                    italic |= sp.tag.italic;
                }
            auto f = bold || italic ? mayfair.text.fonts.font(_font.family, _font.size,
                                                               bold ? FontWeight.bold : FontWeight.regular, italic) : _font;
            auto run = shapeText(f, text[a .. b]);
            foreach (g; run.glyphs)
            {
                auto placed = g;
                placed.cluster += cast(uint) a;
                placed.x += pen;
                s.glyphs ~= placed;
                const at = placed.cluster;
                if (at < s.xs.length && (s.xs[at] != s.xs[at] || (!g.rightToLeft && placed.x < s.xs[at])))
                    s.xs[at] = placed.x;
            }
            pen += run.width;
        }
        s.xs[text.length] = pen;
        s.width = pen;
        // Places inside a cluster -- a ligature's, a combining sequence's -- spread evenly across it
        size_t last = 0;
        for (size_t i = 1; i <= text.length; i++)
        {
            if (s.xs[i] != s.xs[i])
                continue;
            if (i - last > 1)
            {
                size_t chars, j = last;
                while (j < i) { j += strideAt(text, j); chars++; }
                size_t n;
                j = last;
                while (j < i)
                {
                    s.xs[j] = s.xs[last] + (s.xs[i] - s.xs[last]) * n / chars;
                    j += strideAt(text, j);
                    n++;
                }
            }
            last = i;
        }
        return s;
    }

    static size_t strideAt(string text, size_t i) nothrow @nogc
    {
        const b = text[i];
        const n = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
        return i + n > text.length ? text.length - i : n;
    }

    /// How far across its line `at` is, from the text's left.
    float xAt(TextPosition at)
    {
        auto s = &shapedLine(at.line);
        const c = min(at.column, s.xs.length - 1);
        const x = s.xs[c];
        return x == x ? x : 0;
    }

    /// The place nearest `x`, `y` in the content.
    TextPosition positionAt(float x, float y)
    {
        int line = cast(int) floor((y - padTop) / lineH);
        if (line < 0)
            return TextPosition(0, 0);
        if (line >= _buffer.lineCount)
            return _buffer.endPosition;
        const text = _buffer.line(line);
        auto s = &shapedLine(line);
        const px = x - padLeft;
        size_t best = 0;
        float bestD = float.max;
        for (size_t i = 0; i <= text.length; i = i < text.length ? i + strideAt(text, i) : text.length + 1)
        {
            const d = s.xs[i] == s.xs[i] ? (s.xs[i] - px) * (s.xs[i] - px) : float.max;
            if (d < bestD)
            {
                bestD = d;
                best = i;
            }
            if (i == text.length)
                break;
        }
        return TextPosition(line, best);
    }

    // Editing

    void typed(string text)
    {
        // Closing a bracket that's already there: over it, as editors do
        if (!hasSelection && text.length == 1 && (text[0] == ')' || text[0] == ']' || text[0] == '}'))
        {
            const l = _buffer.line(_caretPosition.line);
            if (_caretPosition.column < l.length && l[_caretPosition.column] == text[0] && autoClosed)
            {
                autoClosed = false;
                placeCaret(TextPosition(_caretPosition.line, _caretPosition.column + 1));
                return;
            }
        }
        autoClosed = false;
        replaceSelection(text, "typing");
        // A closing brace on a line of its own: back out to its opener's indent
        if (_autoIndent && text == "}" )
        {
            const l = _buffer.line(_caretPosition.line);
            const indent = leadingWhitespace(l);
            if (indent.length + 1 == l.length && indent.length)
            {
                const open = matchingBracket(TextPosition(_caretPosition.line, l.length - 1));
                if (open.line >= 0)
                {
                    const want = leadingWhitespace(_buffer.line(open.line));
                    if (want != indent)
                    {
                        _buffer.replace(TextPosition(_caretPosition.line, 0), TextPosition(_caretPosition.line, indent.length), want, "typing");
                        placeCaret(TextPosition(_caretPosition.line, want.length + 1));
                    }
                }
            }
        }
    }

    bool autoClosed;

    /// A key pressed: whether it was one of the view's.
    bool key(ref KeyEvent event)
    {
        const ctrl = event.control || event.meta, shift = event.shift, alt = event.alt;
        const c = event.code;
        auto b = _buffer;
        const at = _caretPosition;

        void moveTo(TextPosition to, bool keepGoal = false)
        {
            const g = goalX;
            select(shift ? _anchor : to, to);
            if (keepGoal)
                goalX = g;
            b.breakMerging();
        }

        if (ctrl && !alt)
        {
            switch (c)
            {
                case KeyCode.a: selectAll(); return true;
                case KeyCode.c: copy(); return true;
                case KeyCode.x: cut(); return true;
                case KeyCode.v: paste(); return true;
                case KeyCode.z: if (shift) redo(); else undo(); return true;
                case KeyCode.y: redo(); return true;
                case KeyCode.k:
                    if (shift) { deleteLines(); return true; }
                    return false;
                case cast(KeyCode) '/':
                    if (_lineComment.length) { toggleComment(); return true; }
                    return false;
                case cast(KeyCode) ']': indentLines(true); return true;
                case cast(KeyCode) '[': indentLines(false); return true;
                case KeyCode.home: moveTo(TextPosition(0, 0)); return true;
                case KeyCode.end: moveTo(b.endPosition); return true;
                case KeyCode.left: moveTo(wordLeft(at)); return true;
                case KeyCode.right: moveTo(wordRight(at)); return true;
                case KeyCode.backspace:
                    if (!_editable) return true;
                    if (hasSelection) replaceSelection("");
                    else b.remove(wordLeft(at), at, "deleting");
                    placeCaret(caretMark.position);
                    return true;
                case KeyCode.delete_:
                    if (!_editable) return true;
                    if (hasSelection) replaceSelection("");
                    else b.remove(at, wordRight(at), "deleting");
                    return true;
                default:
                    return false;
            }
        }
        if (alt && !ctrl && (c == KeyCode.up || c == KeyCode.down))
        {
            moveLines(c == KeyCode.up ? -1 : 1);
            return true;
        }
        switch (c)
        {
            case KeyCode.left:
                if (hasSelection && !shift) moveTo(selectionStart);
                else moveTo(previous(at));
                return true;
            case KeyCode.right:
                if (hasSelection && !shift) moveTo(selectionEnd);
                else moveTo(next(at));
                return true;
            case KeyCode.up, KeyCode.down, KeyCode.pageUp, KeyCode.pageDown:
            {
                if (goalX != goalX)
                    goalX = xAt(at);
                const page = max(1, cast(int) (pane.viewportBounds.height / lineH) - 1);
                const by = c == KeyCode.up ? -1 : c == KeyCode.down ? 1 : c == KeyCode.pageUp ? -page : page;
                const line = at.line + by;
                TextPosition to;
                if (line < 0)
                    to = TextPosition(0, 0);
                else if (line >= b.lineCount)
                    to = b.endPosition;
                else
                    to = positionAt(padLeft + goalX, padTop + line * lineH + lineH / 2);
                moveTo(to, true);
                return true;
            }
            case KeyCode.home:
            {
                // To the first non-blank, then the line's start
                const first = leadingWhitespace(b.line(at.line)).length;
                moveTo(TextPosition(at.line, at.column == first ? 0 : first));
                return true;
            }
            case KeyCode.end:
                moveTo(TextPosition(at.line, b.line(at.line).length));
                return true;
            case KeyCode.backspace:
                if (!_editable) return true;
                if (hasSelection)
                    replaceSelection("");
                else if (at != TextPosition(0, 0))
                {
                    // Indentation in spaces goes a level at a time
                    const l = b.line(at.line);
                    const before = l[0 .. at.column];
                    if (_insertSpaces && before.length && leadingWhitespace(before).length == before.length && before[$ - 1] == ' ')
                    {
                        const n = (before.length - 1) % _tabWidth + 1;
                        b.remove(TextPosition(at.line, at.column - n), at, "deleting");
                    }
                    else
                        b.remove(previous(at), at, "deleting");
                }
                placeCaret(caretMark.position);
                return true;
            case KeyCode.delete_:
                if (!_editable) return true;
                if (hasSelection)
                    replaceSelection("");
                else
                    b.remove(at, next(at), "deleting");
                placeCaret(caretMark.position);
                return true;
            case KeyCode.enter, KeyCode.numpadEnter:
                if (!_editable) return true;
                newLine();
                return true;
            case KeyCode.tab:
                if (!_editable) return false;
                if (shift)
                    indentLines(false);
                else if (hasSelection && selectionStart.line != selectionEnd.line)
                    indentLines(true);
                else
                {
                    b.breakMerging();
                    // To the next tab stop
                    const col = cast(int) round(xAt(at) / spaceWidth);
                    replaceSelection(_insertSpaces ? spaces(_tabWidth - col % _tabWidth) : "\t", "typing");
                }
                return true;
            case KeyCode.escape:
                if (hasSelection)
                {
                    placeCaret(at);
                    return true;
                }
                return false;
            default:
                return false;
        }
    }

    string spaces(float n)
    {
        import std.array : replicate;
        int k = cast(int) round(n);
        if (k <= 0)
            k = _tabWidth;
        return " ".replicate(k);
    }

    /// One indentation level: a tab, or tabWidth spaces.
    string indentUnit()
    {
        import std.array : replicate;
        return _insertSpaces ? " ".replicate(_tabWidth) : "\t";
    }

    static string leadingWhitespace(string line) nothrow @nogc
    {
        size_t i;
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            i++;
        return line[0 .. i];
    }

    /// Enter: a new line, indented as the last -- and a level further after an opening bracket,
    /// with its closer, if it's right there, on a line of its own after.
    void newLine()
    {
        auto b = _buffer;
        b.breakMerging();
        const at = selectionStart;
        const l = b.line(at.line);
        string indent = _autoIndent ? leadingWhitespace(l) : null;
        if (indent.length > at.column)
            indent = indent[0 .. at.column];
        const before = l[0 .. at.column];
        size_t e = before.length;
        while (e > 0 && (before[e - 1] == ' ' || before[e - 1] == '\t'))
            e--;
        const opener = _autoIndent && e > 0 && (before[e - 1] == '{' || before[e - 1] == '(' || before[e - 1] == '[')
                       ? before[e - 1] : 0;
        const after = hasSelection ? b.line(selectionEnd.line)[selectionEnd.column .. $] : l[at.column .. $];
        const closes = opener && after.length && after[0] == (opener == '{' ? '}' : opener == '(' ? ')' : ']');
        b.beginUserAction();
        if (opener)
        {
            const inner = indent ~ indentUnit;
            replaceSelection("\n" ~ inner ~ (closes ? "\n" ~ indent : ""));
            if (closes)
                placeCaret(TextPosition(at.line + 1, inner.length));
        }
        else
            replaceSelection("\n" ~ indent);
        b.endUserAction();
        b.breakMerging();
    }

    /// The lines the selection's on, or the caret's.
    void selectedLines(out int first, out int last)
    {
        first = selectionStart.line;
        last = selectionEnd.line;
        if (last > first && selectionEnd.column == 0)
            last--;
    }

    /// Indents or outdents the selected lines a level.
    void indentLines(bool more)
    {
        if (!_editable)
            return;
        int first, last;
        selectedLines(first, last);
        auto b = _buffer;
        const a = _anchor, cpos = _caretPosition;
        b.beginUserAction();
        foreach (l; first .. last + 1)
        {
            const text = b.line(l);
            if (more)
            {
                if (text.length)
                    b.insert(TextPosition(l, 0), indentUnit);
            }
            else
            {
                size_t n;
                if (text.length && text[0] == '\t')
                    n = 1;
                else
                    while (n < _tabWidth && n < text.length && text[n] == ' ')
                        n++;
                if (n)
                    b.remove(TextPosition(l, 0), TextPosition(l, n));
            }
        }
        b.endUserAction();
        // The whole lines selected, as editors leave them
        if (first != last || a != cpos)
            select(TextPosition(first, 0), last + 1 < b.lineCount ? TextPosition(last + 1, 0) : TextPosition(last, b.line(last).length));
    }

    void deleteLines()
    {
        if (!_editable)
            return;
        int first, last;
        selectedLines(first, last);
        auto b = _buffer;
        if (last + 1 < b.lineCount)
            b.remove(TextPosition(first, 0), TextPosition(last + 1, 0));
        else if (first > 0)
            b.remove(TextPosition(first - 1, b.line(first - 1).length), TextPosition(last, b.line(last).length));
        else
            b.remove(TextPosition(0, 0), b.endPosition);
        placeCaret(TextPosition(min(first, b.lineCount - 1), 0));
    }

    /// Moves the selected lines up or down one.
    void moveLines(int by)
    {
        if (!_editable)
            return;
        int first, last;
        selectedLines(first, last);
        auto b = _buffer;
        if ((by < 0 && first == 0) || (by > 0 && last + 1 >= b.lineCount))
            return;
        const a = _anchor, cpos = _caretPosition;
        b.beginUserAction();
        if (by < 0)
        {
            const above = b.line(first - 1);
            b.remove(TextPosition(first - 1, 0), TextPosition(first, 0));
            b.insert(TextPosition(last, b.line(last - 1).length), "\n" ~ above);
        }
        else
        {
            const below = b.line(last + 1);
            b.remove(TextPosition(last, b.line(last).length), TextPosition(last + 1, below.length));
            b.insert(TextPosition(first, 0), below ~ "\n");
        }
        b.endUserAction();
        select(TextPosition(a.line + by, a.column), TextPosition(cpos.line + by, cpos.column));
    }

    /// Comments the selected lines out with lineComment, or back in if they all are.
    void toggleComment()
    {
        if (!_editable)
            return;
        int first, last;
        selectedLines(first, last);
        auto b = _buffer;
        const mark = _lineComment;
        bool all = true;
        size_t indent = size_t.max;
        foreach (l; first .. last + 1)
        {
            const text = b.line(l);
            const ws = leadingWhitespace(text).length;
            if (ws == text.length)
                continue;
            indent = min(indent, ws);
            if (text[ws .. $].length < mark.length || text[ws .. ws + mark.length] != mark)
                all = false;
        }
        if (indent == size_t.max)
            return;
        b.beginUserAction();
        foreach (l; first .. last + 1)
        {
            const text = b.line(l);
            const ws = leadingWhitespace(text).length;
            if (ws == text.length)
                continue;
            if (all)
            {
                const n = mark.length + (ws + mark.length < text.length && text[ws + mark.length] == ' ' ? 1 : 0);
                b.remove(TextPosition(l, ws), TextPosition(l, ws + n));
            }
            else
                b.insert(TextPosition(l, indent), mark ~ " ");
        }
        b.endUserAction();
    }

    // Moving by characters and words

    TextPosition previous(TextPosition at)
    {
        if (at.column > 0)
        {
            const l = _buffer.line(at.line);
            size_t c = at.column - 1;
            while (c > 0 && (l[c] & 0xC0) == 0x80)
                c--;
            return TextPosition(at.line, c);
        }
        return at.line > 0 ? TextPosition(at.line - 1, _buffer.line(at.line - 1).length) : at;
    }

    TextPosition next(TextPosition at)
    {
        const l = _buffer.line(at.line);
        if (at.column < l.length)
            return TextPosition(at.line, at.column + strideAt(l, at.column));
        return at.line + 1 < _buffer.lineCount ? TextPosition(at.line + 1, 0) : at;
    }

    static bool wordChar(dchar c) { return c == '_' || isAlphaNum(c); }

    dchar charAt(TextPosition at)
    {
        const l = _buffer.line(at.line);
        if (at.column >= l.length)
            return '\n';
        size_t i = at.column;
        try
            return decode(l, i);
        catch (Exception)
            return ' ';
    }

    TextPosition wordLeft(TextPosition at)
    {
        auto p = at;
        // Past spaces, then past a word -- or a run of punctuation
        while (p != TextPosition(0, 0) && isWhite(charAt(previous(p))) && p.column > 0)
            p = previous(p);
        if (p.column == 0)
            return p == at ? previous(p) : p;
        const word = wordChar(charAt(previous(p)));
        while (p.column > 0)
        {
            const c = charAt(previous(p));
            if (isWhite(c) || wordChar(c) != word)
                break;
            p = previous(p);
        }
        return p;
    }

    TextPosition wordRight(TextPosition at)
    {
        auto p = at;
        const len = _buffer.line(at.line).length;
        if (p.column >= len)
            return next(p);
        while (p.column < len && isWhite(charAt(p)))
            p = next(p);
        if (p.column >= len)
            return p;
        const word = wordChar(charAt(p));
        while (p.column < len)
        {
            const c = charAt(p);
            if (isWhite(c) || wordChar(c) != word)
                break;
            p = next(p);
        }
        return p;
    }

    void wordAround(TextPosition at, out TextPosition from, out TextPosition to)
    {
        const len = _buffer.line(at.line).length;
        from = to = at;
        if (!len)
            return;
        auto probe = at.column < len ? at : previous(at);
        const word = wordChar(charAt(probe));
        from = probe;
        while (from.column > 0 && wordChar(charAt(previous(from))) == word && !isWhite(charAt(previous(from))))
            from = previous(from);
        to = next(probe);
        while (to.column < len && to.line == at.line && wordChar(charAt(to)) == word && !isWhite(charAt(to)))
            to = next(to);
        if (to.line != at.line)
            to = TextPosition(at.line, len);
    }

    /// The bracket matching the one at `at`, or line -1: searching a few thousand lines at most.
    TextPosition matchingBracket(TextPosition at)
    {
        const c = charAt(at);
        dchar open, close;
        bool forward;
        switch (c)
        {
            case '(': open = '('; close = ')'; forward = true; break;
            case '[': open = '['; close = ']'; forward = true; break;
            case '{': open = '{'; close = '}'; forward = true; break;
            case ')': open = '('; close = ')'; break;
            case ']': open = '['; close = ']'; break;
            case '}': open = '{'; close = '}'; break;
            default: return TextPosition(-1, 0);
        }
        int depth = 0;
        auto b = _buffer;
        const lastLine = forward ? min(b.lineCount - 1, at.line + 3000) : max(0, at.line - 3000);
        for (int l = at.line; forward ? l <= lastLine : l >= lastLine; l += forward ? 1 : -1)
        {
            const text = b.line(l);
            if (forward)
            {
                for (size_t i = l == at.line ? at.column : 0; i < text.length; i++)
                {
                    if (text[i] == open) depth++;
                    else if (text[i] == close && --depth == 0) return TextPosition(l, i);
                }
            }
            else
            {
                for (long i = l == at.line ? cast(long) at.column : cast(long) text.length - 1; i >= 0; i--)
                {
                    if (text[i] == close) depth++;
                    else if (text[i] == open && --depth == 0) return TextPosition(l, cast(size_t) i);
                }
            }
        }
        return TextPosition(-1, 0);
    }

    /// The bracket by the caret, and its match: after it first, then before it.
    bool bracketPair(out TextPosition a, out TextPosition b)
    {
        if (!_matchBrackets || hasSelection)
            return false;
        const at = _caretPosition;
        foreach (probe; [at, at.column > 0 ? previous(at) : TextPosition(-1, 0)])
        {
            if (probe.line < 0)
                continue;
            const m = matchingBracket(probe);
            if (m.line >= 0)
            {
                a = probe;
                b = m;
                return true;
            }
        }
        return false;
    }

    void widest()
    {
        if (!widestStale)
            return;
        widestStale = false;
        size_t w;
        foreach (i; 0 .. _buffer.lineCount)
        {
            const l = _buffer.line(i);
            size_t n = l.length;
            foreach (char c; l)
                if (c == '\t')
                    n += _tabWidth - 1;
            if (n > w)
                w = n;
        }
        widestChars = w;
    }
}

/// A line, shaped: its glyphs, placed across it, how wide it is, and where each place in it is.
struct ShapedLine
{
    PositionedGlyph[] glyphs;
    float width = 0;
    float[] xs;   // by byte offset: NaN inside a character
}

/*
    The line numbers, down the left, beside the text: drawn for the lines in view, the caret's
    brighter, and the gutter's marks beside them.
*/
private final class Gutter : Widget
{
    this(TextView view)
    {
        this.view = view;
        styleClass.add("gutter");
        setAccessibleHidden(true);
    }

    void resize()
    {
        float w = 0;
        if (view._showLineNumbers && view._buffer)
        {
            int digits = 1;
            for (int n = view._buffer.lineCount; n >= 10; n /= 10)
                digits++;
            if (digits < 3)
                digits = 3;
            w = digits * view.charWidth + 24;
            if (!digitRuns.length || digitFont !is view._font)
            {
                digitFont = view._font;
                digitRuns = null;
                foreach (d; 0 .. 10)
                    digitRuns ~= shapeText(digitFont, [cast(char) ('0' + d)]);
            }
        }
        if (w != width)
        {
            width = w;
            YGNodeStyleSetWidth(node, w);
            YGNodeStyleSetMinWidth(node, w);
            setVisible(w > 0);
        }
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        marks = addPaint();
        text.create();
        addPaint(text.paint);
    }

    override void unmounted()
    {
        marks = null;
        text.release();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        if (!marks || !view._buffer || !digitRuns.length)
            return;
        tvg_shape_reset(marks);
        text.begin(scene ? scene.pixelScale : 1, behind);
        const vp = view.pane.viewportBounds;
        const lh = view.lineH;
        const first = cast(int) floor((vp.minY - view.padTop) / lh), last = cast(int) ceil((vp.maxY - view.padTop) / lh);
        const count = view._buffer.lineCount;
        const caretLine = view._caretPosition.line;
        auto c = view._lineNumberFill;
        auto bright = view._textFill;
        const digitW = digitRuns[0].width;
        foreach (l; max(0, first) .. min(count, last + 1))
        {
            const top = y + view.padTop + l * lh - vp.minY;
            if (top + lh < y || top > y + h)
                continue;
            // Right-aligned, a digit at a time from the right
            int n = l + 1;
            float right = x + w - 12;
            do
            {
                right -= digitW;
                text.addRun(digitRuns[n % 10], right, top + view.ascent, l == caretLine ? bright : c);
                n /= 10;
            }
            while (n > 0);
        }
        foreach (ref m; view.gutterMarks)
        {
            const l = m.mark.position.line;
            if (l < first || l > last)
                continue;
            const top = y + view.padTop + l * lh - vp.minY;
            tvg_shape_append_circle(marks, x + 7, top + lh / 2, 3, 3, true);
            tvg_shape_set_fill_color(marks, m.colour.tupleof); // the last one's colour, for them all
        }
        text.finish();
    }

private:
    TextView view;
    Tvg_Paint marks;
    TextImage text;
    GlyphRun[] digitRuns;
    Font digitFont;
    float width = -1;
}

/*
    The text itself, as the scroll pane scrolls it: as big as all the lines, drawing only those
    near the view. Text in blocks of `blockLines` lines, each a picture of its own, drawn when it
    comes near the view and again when its lines or their styling change; and over and under it,
    the selection, the current line, matches, brackets, underlines and the caret, for the lines
    near the view.
*/
private final class Content : Widget
{
    enum int blockLines = 64;

    this(TextView view)
    {
        this.view = view;
        styleClass.add("content");
        setAccessibleHidden(true);
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureTextContent);
    }

    TextView view;
    Block[] blocks;
    bool decorationsStale = true;

    final static class Block
    {
        int first;
        ulong[] ids;          // its lines', as they were drawn
        bool stale;           // their styling changed
        float clipFrom = 0, clipTo = 0; // across, what's drawn of them
        float scale = 0;
        TextImage image;
    }

    void remeasure() nothrow @nogc
    {
        YGNodeMarkDirty(node);
        requestUpdate();
    }

    /// Lines from `from` on changed: the blocks from there are drawn again.
    void linesChanged(int from)
    {
        foreach (b; blocks)
            if (b.first + blockLines > from)
                b.stale = true;
        decorationsStale = true;
        remeasure();
    }

    void tagsChanged(int from, int to)
    {
        foreach (b; blocks)
            if (b.first <= to && b.first + blockLines > from)
                b.stale = true;
        decorationsStale = true;
        requestUpdate();
    }

    void dropBlocks()
    {
        foreach (b; blocks)
        {
            if (holder && b.image.paint)
                tvg_scene_remove(holder, b.image.paint);
            b.image.release();
        }
        blocks = null;
        requestUpdate();
    }

    void showCaret()
    {
        if (caret)
        {
            tvg_paint_set_opacity(caret, view.caretOn && view.focused && view._editable ? 255 : 0);
            invalidate();
        }
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        under = addPaint(tvg_scene_new());
        holder = addPaint(tvg_scene_new());
        over = addPaint();
        caret = addPaint();
        composedText.create();
        addPaint(composedText.paint);
        blocks = null;
        decorationsStale = true;
        requestUpdate();
    }

    override void unmounted()
    {
        foreach (b; blocks)
            b.image.release();
        blocks = null;
        extra = null;
        composedText.release();
        under = holder = over = caret = null;
    }

    override void update()
    {
        if (!holder || !view._buffer)
            return;
        auto vp = view.pane.viewportBounds;
        if (view.scrollPending && abs(YGNodeLayoutGetHeight(node) - contentHeight) < 2)
        {
            view.scrollPending = false;
            view.pane.scrollTo(view.pendingX, view.pendingY);
            vp = view.pane.viewportBounds;
        }
        const lh = view.lineH;
        const count = view._buffer.lineCount;
        const first = max(0, cast(int) floor((vp.minY - view.padTop) / lh) - 4);
        const last = min(count - 1, cast(int) ceil((vp.maxY - view.padTop) / lh) + 4);
        const scale = scene ? scene.pixelScale : 1;

        // The blocks the view's in, drawn if they're not -- or not as they are now
        const firstBlock = first / blockLines, lastBlock = last / blockLines;
        Block[] kept;
        foreach (b; blocks)
        {
            const bi = b.first / blockLines;
            if (bi >= firstBlock - 1 && bi <= lastBlock + 1)
                kept ~= b;
            else
            {
                tvg_scene_remove(holder, b.image.paint);
                b.image.release();
            }
        }
        blocks = kept;
        foreach (bi; firstBlock .. lastBlock + 1)
        {
            Block block;
            foreach (b; blocks)
                if (b.first == bi * blockLines)
                    block = b;
            if (!block)
            {
                block = new Block;
                block.first = bi * blockLines;
                block.image.create();
                tvg_scene_add(holder, block.image.paint);
                blocks ~= block;
                block.stale = true;
            }
            // Drawn again if its lines changed, the scale did, or the view's gone past what it drew across
            bool fresh = !block.stale && block.scale == scale && vp.minX >= block.clipFrom && vp.maxX <= block.clipTo;
            if (fresh)
                foreach (k, id; block.ids)
                    if (view._buffer.lineId(block.first + cast(int) k) != id)
                    {
                        fresh = false;
                        break;
                    }
            if (!fresh || block.ids.length != min(blockLines, max(0, count - block.first)))
                drawBlock(block, vp, scale);
        }

        // Its size: as tall as the lines, as wide as the widest, or the view
        view.widest();
        const h = view.padTop * 2 + count * lh;
        const w = view.padLeft + (view.widestChars + 4) * view.charWidth;
        if (h != contentHeight || w != contentWidth)
        {
            contentHeight = h;
            contentWidth = w;
            YGNodeMarkDirty(node);
        }
        drawDecorations(first, last);
        lastFirst = first;
        lastLast = last;
        view.gutter.invalidate(); // its numbers, for the lines now in view
        invalidate();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // Everything's in the content's own points: moved to where it is
        Tvg_Paint[4] all = [under, holder, over, caret];
        foreach (p; all)
            if (p)
            {
                Tvg_Matrix m = Tvg_Matrix(1, 0, x, 0, 1, y, 0, 0, 1);
                tvg_paint_set_transform(p, &m);
            }
        if (composedText.paint)
        {
            Tvg_Matrix m = Tvg_Matrix(1, 0, x, 0, 1, y, 0, 0, 1);
            tvg_paint_set_transform(composedText.paint, &m);
        }
        // Scrolled to lines it hasn't drawn: draw them
        const vp = view.pane.viewportBounds;
        const lh = view.lineH;
        const first = cast(int) floor((vp.minY - view.padTop) / lh), last = cast(int) ceil((vp.maxY - view.padTop) / lh);
        if (first < lastFirst || last > lastLast)
            requestUpdate();
        foreach (b; blocks)
            if (vp.minX < b.clipFrom || vp.maxX > b.clipTo)
            {
                requestUpdate();
                break;
            }
    }

    override void handleMouse(ref MouseEvent event)
    {
        auto v = view;
        const at = v.positionAt(event.x, event.y);
        switch (event.type)
        {
            case MouseEventType.pressed:
                v.requestFocus();
                if (event.button == MouseButton.middle)
                {
                    if (v._editable)
                        if (auto primary = Clipboard.primary)
                        {
                            v._buffer.breakMerging();
                            v.placeCaret(at);
                            v.replaceSelection(primary);
                        }
                    event.consume();
                    return;
                }
                if (event.button == MouseButton.secondary)
                {
                    if (at < v.selectionStart || at > v.selectionEnd || !v.hasSelection)
                        v.placeCaret(at);
                    return; // the scene shows the context menu next
                }
                if (event.button != MouseButton.primary)
                    return;
                if ((event.control || event.meta) && v._onControlClick)
                {
                    v.placeCaret(at);
                    v._onControlClick(at);
                    event.consume();
                    return;
                }
                selecting = true;
                v._buffer.breakMerging();
                if (event.clickCount >= 3)
                {
                    unit = 2;
                    dragFrom = TextPosition(at.line, 0);
                    dragTo = at.line + 1 < v._buffer.lineCount ? TextPosition(at.line + 1, 0) : TextPosition(at.line, v._buffer.line(at.line).length);
                    v.select(dragFrom, dragTo);
                }
                else if (event.clickCount == 2)
                {
                    unit = 1;
                    v.wordAround(at, dragFrom, dragTo);
                    v.select(dragFrom, dragTo);
                }
                else
                {
                    unit = 0;
                    v.select(event.shift ? v._anchor : at, at);
                }
                event.consume();
                break;
            case MouseEventType.dragged:
                if (!selecting)
                    return;
                if (unit == 0)
                    v.select(v._anchor, at);
                else
                {
                    TextPosition a, b;
                    if (unit == 1)
                        v.wordAround(at, a, b);
                    else
                    {
                        a = TextPosition(at.line, 0);
                        b = at.line + 1 < v._buffer.lineCount ? TextPosition(at.line + 1, 0) : TextPosition(at.line, v._buffer.line(at.line).length);
                    }
                    if (a < dragFrom)
                        v.select(dragTo, a);
                    else
                        v.select(dragFrom, b);
                }
                event.consume();
                break;
            case MouseEventType.released:
                // Where it's let go of counts, wherever it last moved to
                if (selecting && unit == 0 && event.button == MouseButton.primary && at != v._caretPosition)
                    v.select(v._anchor, at);
                selecting = false;
                break;
            case MouseEventType.moved:
                hoverAt = at;
                hoverX = event.sceneX;
                hoverY = event.sceneY;
                if (v._onHover)
                    scheduleHover();
                break;
            default:
                break;
        }
    }

private:
    Tvg_Paint under, holder, over, caret;
    TextImage composedText;
    float contentWidth = 0, contentHeight = 0;
    int lastFirst = int.max, lastLast = -1;
    bool selecting;
    int unit;
    TextPosition dragFrom, dragTo;
    TextPosition hoverAt;
    float hoverX = 0, hoverY = 0;
    Timeline hoverTimer;

    static float abs(float v) pure nothrow @nogc { return v < 0 ? -v : v; }

    void scheduleHover()
    {
        if (!hoverTimer)
            hoverTimer = new Timeline(KeyFrame(Duration.zero), KeyFrame(Theme.tooltip_delay, {
                if (view._onHover && hover)
                    view._onHover(hoverAt, hoverX, hoverY);
            }));
        hoverTimer.playFromStart();
    }

    /// Block `b`'s text, drawn: across what's in view and as much again either side.
    void drawBlock(Block b, Bounds vp, float scale)
    {
        auto v = view;
        const count = v._buffer.lineCount;
        const lines = min(blockLines, max(0, count - b.first));
        b.ids.length = lines;
        b.clipFrom = vp.minX - vp.width;
        b.clipTo = vp.maxX + vp.width;
        b.scale = scale;
        b.stale = false;
        b.image.begin(scale, behind);
        foreach (k; 0 .. lines)
        {
            const l = b.first + k;
            b.ids[k] = v._buffer.lineId(l);
            auto s = &v.shapedLine(l);
            auto spans = v.styleSpans(l);
            const baseline = v.padTop + l * v.lineH + v.ascent;
            foreach (ref g; s.glyphs)
            {
                const x = v.padLeft + g.x;
                if (x < b.clipFrom || x > b.clipTo)
                    continue;
                Colour colour = v._textFill;
                foreach (ref sp; spans)
                    if (sp.tag.hasForeground && g.cluster >= sp.start && g.cluster < sp.end)
                        colour = sp.tag.foreground;
                b.image.addGlyph(g, x, baseline + g.y, colour);
            }
        }
        b.image.finish();
        // Lines shaped that aren't near the view any more go, now and then
        if (v.shaped.length > 4000)
            v.shaped = null;
    }

    /// The selection, current line, matches, brackets, underlines and caret, for lines `first` to `last`.
    void drawDecorations(int first, int last)
    {
        auto v = view;
        tvg_shape_reset(over);
        tvg_shape_reset(caret);
        composedText.begin(scene ? scene.pixelScale : 1, behind);
        const lh = v.lineH, px = v.padLeft, py = v.padTop;
        const wide = max(contentWidth, v.pane.viewportBounds.maxX + 100);

        // Under the text: tag backgrounds, the current line, the brackets, the selection -- each
        // its own shape, as a shape has one colour
        foreach (p; extra)
            tvg_scene_remove(under, p);
        extra = null;
        void box(Colour c, float x, float y, float w, float h, float r = 2)
        {
            auto s = tvg_shape_new();
            tvg_shape_append_rect(s, x, y, w, h, r, r, true);
            tvg_shape_set_fill_color(s, c.tupleof);
            tvg_scene_add(under, s);
            extra ~= s;
        }
        if (v._highlightCurrentLine && !v.hasSelection)
            box(v._currentLineFill, 0, py + v._caretPosition.line * lh, wide, lh, 0);
        foreach (l; first .. last + 1)
        {
            foreach (ref sp; v.styleSpans(l))
                if (sp.tag.hasBackground)
                {
                    const a = v.xAt(TextPosition(l, sp.start)), b = v.xAt(TextPosition(l, sp.end));
                    box(sp.tag.background, px + a, py + l * lh, max(b - a, 2f), lh);
                }
        }
        TextPosition ba, bb;
        if (v.focused && v.bracketPair(ba, bb))
            foreach (p; [ba, bb])
                if (p.line >= first && p.line <= last)
                {
                    const a = v.xAt(p), b = v.xAt(v.next(p));
                    box(v._bracketFill, px + a, py + p.line * lh, max(b - a, 2f), lh);
                }
        if (v.hasSelection)
        {
            const s = v.selectionStart, e = v.selectionEnd;
            foreach (l; max(first, s.line) .. min(last, e.line) + 1)
            {
                const a = l == s.line ? v.xAt(s) : 0;
                const b = l == e.line ? v.xAt(e) : v.shapedLine(l).width + v.spaceWidth / 2;
                box(v._highlightFill, px + a, py + l * lh, max(b - a, 2f), lh, 0);
            }
        }

        // Over it: underlines and strike-throughs
        tvg_shape_set_stroke_width(over, 1.2f);
        Colour underlineColour = v._textFill;
        bool anyOver;
        foreach (l; first .. last + 1)
            foreach (ref sp; v.styleSpans(l))
            {
                if (sp.tag.underline == Underline.none && !sp.tag.strikethrough)
                    continue;
                const a = px + v.xAt(TextPosition(l, sp.start));
                float b = px + v.xAt(TextPosition(l, sp.end));
                if (b - a < 4)
                    b = a + 4;
                const top = py + l * lh;
                const c = sp.tag.underlineColour.a ? sp.tag.underlineColour
                        : sp.tag.hasForeground ? sp.tag.foreground : v._textFill;
                underlineColour = c;
                anyOver = true;
                if (sp.tag.underline == Underline.squiggle)
                {
                    const base = top + lh - 2.5f;
                    tvg_shape_move_to(over, a, base);
                    bool up = true;
                    for (float x = a; x < b; x += 2)
                    {
                        tvg_shape_line_to(over, min(x + 2, b), up ? base - 2 : base);
                        up = !up;
                    }
                }
                else if (sp.tag.underline == Underline.single)
                {
                    tvg_shape_move_to(over, a, top + v.ascent + 2);
                    tvg_shape_line_to(over, b, top + v.ascent + 2);
                }
                if (sp.tag.strikethrough)
                {
                    tvg_shape_move_to(over, a, top + v.ascent * 0.65f);
                    tvg_shape_line_to(over, b, top + v.ascent * 0.65f);
                }
            }
        tvg_shape_set_stroke_color(over, underlineColour.r, underlineColour.g, underlineColour.b, anyOver ? underlineColour.a : 0);

        // The caret, or what an input method's composing there
        const at = v._caretPosition;
        const cx = px + v.xAt(at), cy = py + at.line * lh;
        if (v.composed.length)
        {
            auto run = shapeText(v._font, v.composed);
            composedText.addRun(run, cx, cy + v.ascent, v._textFill);
            tvg_shape_append_rect(caret, cx, cy + lh - 2, run.width, 1, 0, 0, true);
        }
        tvg_shape_append_rect(caret, cx - Theme.caret_width / 2, cy + 1, Theme.caret_width, lh - 2, 0, 0, true);
        tvg_shape_set_fill_color(caret, v._caretFill.tupleof);
        composedText.finish();
        showCaret();
        decorationsStale = false;
    }

    Tvg_Paint[] extra;   // the shapes under the text, in `under`: a colour each
}

/// Yoga measuring the text: as tall as its lines, and as wide as the widest.
private extern (C) YGSize measureTextContent(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                             float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(Content) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return YGSize(self.contentWidth, self.contentHeight);
}
