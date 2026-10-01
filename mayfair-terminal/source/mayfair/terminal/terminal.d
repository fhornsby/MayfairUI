module mayfair.terminal.terminal;

import core.memory : GC;
import core.stdc.math : ceilf, floorf, powf, roundf, sinf;
import core.stdc.stdio : fprintf, stderr;
import std.string : fromStringz, toStringz;
import std.utf : encode;

import mayfair.accessibility;
import mayfair.clipboard;
import mayfair.properties;
import mayfair.theme;
import mayfair.widgets;
import mayfair.widgets.styling : StyleContext, convert;
import mayfair.windowing.platform : Notifier;
import mayfair_terminal_c;

/*
    A terminal emulator: a program running in a pseudoterminal, its screen drawn here, and the
    keyboard and mouse sent to it. GNOME's VteTerminal, on alacritty_terminal -- Alacritty's
    emulator without its window -- which parses what the program writes, keeps the screen and its
    history, and encodes what's typed as the program expects (see native/, its C API).

        auto shell = new Terminal();                       // the user's login shell
        auto top = new Terminal(["htop"]).grow(1);
        shell.windowTitleProperty.addListener(...);        // what the shell says it's doing
        shell.onExited((int status) { App.quit(); });

    The program starts once the terminal is first laid out, at the size it's been given, and is
    told whenever that size changes. It keeps running while the terminal's out of the window --
    moved to another tab, say -- and the terminal isn't collected while it does: close() hangs up
    on it, which ends a shell. After it exits, what it last showed stays.

    Keys go to the program, Tab and Escape included, as in any terminal. What a terminal keeps for
    itself are GNOME Terminal's: Ctrl+Shift+C and Ctrl+Shift+V to copy and paste, Shift+Insert to
    paste, Ctrl+Shift+A to select everything, and Shift with Page Up, Page Down, Home and End to
    scroll the history. Dragging selects -- double-clicking a word, triple-clicking a line -- and
    what's selected is the primary selection, which a middle click pastes. A program that asks for
    the mouse gets it, unless Shift is held.

    Its colours follow the theme: the text and background are --text and --field, as a text
    area's are, and the 16 of the palette are Tango's, which GNOME Terminal starts with. A
    stylesheet changes any of them with variables:

        .terminal {
            --terminal-foreground: #eeeeec;   --terminal-background: #1e1e1e;
            --terminal-cursor: #eeeeec;       --terminal-selection: #3465a480;
            --terminal-colour-1: #ff5555;     // ... through --terminal-colour-15
        }

    A program can change them as it runs (OSC 4, 10, 11), and that wins until it resets them.

    Its font is the first of the usual monospace families that's installed, at the theme's text
    size; set `font` for another. Bold and italic text use the family's bold and italic faces, and
    a character it can't draw comes from a fallback font, centred in its cell.

    Its style class is "terminal". To a screen reader it's a terminal, whose value is the text on
    the screen.

    Not yet: a scroll bar, blinking, box-drawing characters drawn by hand (a font's can leave
    gaps between lines), and colour emoji.
*/
class Terminal : Widget
{
public:
    /// Runs `command` -- a program, then its arguments -- or, if it's empty, the user's login shell.
    this(string[] command = null)
    {
        _command = command.dup;
        styleClass.add("terminal");
        setAccessibleRole(AccessibleRole.terminal);
        setFocusTraversable(true);
        setAcceptsTextInput(true);
        setCursor(Cursor.text);
        setPadding(Insets(2, 4));
        YGNodeSetContext(node, cast(void*) this);
        YGNodeSetMeasureFunc(node, &measureTerminal);
        _notifier = new Notifier(&readNews);
        _palette = tango;
        loadFonts();
    }

    ~this()
    {
        // Only once nothing's running in it: until then the Notifier is a root, and it holds this
        if (_session)
            mt_terminal_free(_session);
    }

    /*
        What it's drawn with: a monospace font, as any other would be drawn a character to a cell.
        Set in code rather than by a stylesheet, whose fonts are for proportional text: a font-size
        on .root would otherwise swap the monospace default for the theme's sans.
    */
    mixin(declareProperty!(Font, "font", "null", q{ loadFonts(); }));

    /// How many lines of history it keeps. Read when the program starts.
    mixin(declareProperty!(int, "scrollback", "10000"));

    /// Where the program starts, or null for this process's working directory. Read when it starts.
    mixin(declareProperty!(string, "workingDirectory", "null"));

    /// Environment variables for the program, "NAME=value" each, on top of this process's. Read
    /// when it starts. TERM is xterm-256color and COLORTERM truecolor unless this says otherwise.
    mixin(declareProperty!(string[], "environment", "null"));

    /// The title the program gave itself: a shell usually shows where it is, or what it's running.
    mixin(declareReadOnlyProperty!(string, "windowTitle", "null"));

    /// Whether the program has exited. Its code is exitStatus.
    mixin(declareReadOnlyProperty!(bool, "exited", "false"));

    /// The program's exit code once it's exited, or minus the signal that ended it.
    final int exitStatus() const nothrow @nogc { return _exitStatus; }

    /// What to do when the program exits, with its exitStatus.
    final void setOnExited(void delegate(int status) handler) nothrow @nogc { _onExited = handler; }

    /// ditto
    final This onExited(this This)(void delegate(int status) handler)
    {
        _onExited = handler;
        return cast(This) this;
    }

    /// What to do when the program rings the bell. Nothing, by default.
    final void setOnBell(void delegate() handler) nothrow @nogc { _onBell = handler; }

    /// ditto
    final This onBell(this This)(void delegate() handler)
    {
        _onBell = handler;
        return cast(This) this;
    }

    /// Sends `text` to the program as if it had been typed.
    final void sendText(string text)
    {
        if (_session && text.length)
            mt_terminal_input(_session, text.ptr, text.length);
    }

    /// What's selected, or null.
    final string selectedText()
    {
        if (!_session)
            return null;
        const n = mt_terminal_selection_text(_session, null, 0);
        if (!n)
            return null;
        auto buffer = new char[n];
        mt_terminal_selection_text(_session, buffer.ptr, n);
        return cast(string) buffer;
    }

    /// Copies what's selected to the clipboard.
    final void copy()
    {
        if (auto text = selectedText())
            Clipboard.text(text);
    }

    /// Pastes the clipboard's text to the program.
    final void paste()
    {
        pasteText(Clipboard.text());
    }

    /// Selects everything, the history included.
    final void selectAll()
    {
        if (!_session)
            return;
        mt_terminal_select_all(_session);
        contentChanged();
    }

    /// The text on the screen, as it's shown -- scrolled back, if it is -- a line to a line, without
    /// the spaces that pad each one out. Updated when the terminal is next drawn.
    final string screenText()
    {
        char[] text;
        foreach (l; 0 .. _screen.lines)
        {
            if (cast(size_t)(l + 1) * _screen.columns > _cells.length)
                break;
            const start = text.length;
            foreach (ref cell; _cells[l * _screen.columns .. (l + 1) * _screen.columns])
            {
                if (cell.flags & MT_CELL_SPACER)
                    continue;
                encode(text, cast(dchar) cell.c);
                foreach (k; 0 .. cell.combining_count)
                    if (cell.combining_start + k < _combining.length)
                        encode(text, cast(dchar) _combining[cell.combining_start + k]);
            }
            while (text.length > start && text[$ - 1] == ' ')
                text.length--;
            text ~= '\n';
        }
        while (text.length && text[$ - 1] == '\n')
            text.length--;
        return cast(string) text;
    }

    /// How many columns and lines it shows: what the program's been told its size is.
    final int columns() const nothrow @nogc { return _columns; }

    /// ditto
    final int lines() const nothrow @nogc { return _lines; }

    /// Where the cell at `column`, `line` is drawn, in points from the terminal's top left.
    final Bounds cellBounds(int column, int line) nothrow @nogc
    {
        const s = _scale > 0 ? _scale : 1;
        const left = YGNodeLayoutGetPadding(node, YGEdgeLeft), top = YGNodeLayoutGetPadding(node, YGEdgeTop);
        return Bounds(left + column * _cellWidth / s, top + line * _cellHeight / s, _cellWidth / s, _cellHeight / s);
    }

    /// Hangs up on the program, as closing a terminal window does: a shell exits. What it showed stays.
    final void close()
    {
        if (!_session || _exited)
            return;
        mt_terminal_free(_session);
        _session = null;
        unroot();
        finish(-1);
    }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        _grid = tvg_scene_new();
        _rows = tvg_scene_new();
        tvg_scene_add(_grid, _rows);
        addPaint(_grid);
        _pictures = null;
        _drawnScale = 0; // new paints, which need everything drawn on them
    }

    override void unmounted()
    {
        _grid = _rows = null; // gone with the widget's other paints, and the pictures in them
        _pictures = null;
    }

    override void laidOut(float x, float y, float w, float h) nothrow @nogc
    {
        const scale = scene ? scene.pixelScale : 1.0f;
        const iw = w - YGNodeLayoutGetPadding(node, YGEdgeLeft) - YGNodeLayoutGetPadding(node, YGEdgeRight);
        const ih = h - YGNodeLayoutGetPadding(node, YGEdgeTop) - YGNodeLayoutGetPadding(node, YGEdgeBottom);
        if (iw != _innerWidth || ih != _innerHeight || scale != _scale)
        {
            _innerWidth = iw;
            _innerHeight = ih;
            _scale = scale;
            requestUpdate(); // a new size, or new pixels, for update() to work out
        }
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // The background reaches the edges, padding and all, where the cells stop short of them
        // The program's, once there's a screen from it, and until then the theme's
        const bg = _screen.columns ? _screen.background : _palette[MT_COLOUR_BACKGROUND];
        tvg_shape_append_rect(shape, x, y, w, h, 0, 0, true);
        tvg_shape_set_fill_color(shape, (bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF, 255);
        if (_rows)
        {
            // The cells on the pixel grid, so each texel of theirs is one pixel
            const s = _scale > 0 ? _scale : 1;
            const left = roundf((x + YGNodeLayoutGetPadding(node, YGEdgeLeft)) * s) / s;
            const top = roundf((y + YGNodeLayoutGetPadding(node, YGEdgeTop)) * s) / s;
            tvg_paint_translate(_rows, left, top);
        }
    }

    override void update()
    {
        if (_scale <= 0 || _innerWidth != _innerWidth)
            return; // not laid out yet
        if (_scale != _metricsScale)
            measureCells();
        const columns = cast(int) floorf(_innerWidth * _scale / _cellWidth);
        const lines = cast(int) floorf(_innerHeight * _scale / _cellHeight);
        const cols = cast(ushort)(columns < 2 ? 2 : columns > ushort.max ? ushort.max : columns);
        const rows = cast(ushort)(lines < 1 ? 1 : lines > ushort.max ? ushort.max : lines);
        if (!_started)
            start(cols, rows);
        else if (_session && (cols != _columns || rows != _lines || _cellsResized))
            mt_terminal_resize(_session, cols, rows, cast(ushort) _cellWidth, cast(ushort) _cellHeight);
        _columns = cols;
        _lines = rows;
        _cellsResized = false;
        refresh();
    }

    override void restyled()
    {
        uint[mtColourCount] colours;
        Colour selection;
        try
        {
            auto context = StyleContext(this);
            // The variable `name`, or else `fallback`'s, or else what's already there
            Colour pick(string name, string fallback, Colour otherwise)
            {
                foreach (n; [name, fallback])
                {
                    if (!n.length)
                        continue;
                    Colour c;
                    auto value = context.lookup(n);
                    if (value && convert(*value, context, c))
                        return c;
                }
                return otherwise;
            }
            foreach (i; 0 .. 16)
                colours[i] = packed(pick(paletteVariables[i], null, unpacked(tango[i])));
            colours[MT_COLOUR_FOREGROUND] = packed(pick("--terminal-foreground", "--text", Theme.text_colour));
            colours[MT_COLOUR_BACKGROUND] = packed(pick("--terminal-background", "--field", Theme.background_colour));
            colours[MT_COLOUR_CURSOR] = packed(pick("--terminal-cursor", null, unpacked(colours[MT_COLOUR_FOREGROUND])));
            selection = pick("--terminal-selection", "--selection", Colour(52, 101, 164, 128));
        }
        catch (Exception)
            return;
        if (colours == _palette && selection == _selection)
            return;
        _palette = colours;
        _selection = selection;
        if (_session)
            mt_terminal_set_colours(_session, _palette.ptr, _palette.length);
        _redrawAll = true;
        contentChanged();
    }

    override void focusChanged()
    {
        if (_session)
            mt_terminal_focus(_session, focused);
        contentChanged(); // the cursor: solid with focus, hollow without
    }

    override void handleKey(ref KeyEvent event)
    {
        if (!_session || _exited)
            return;
        if (event.type == KeyEventType.typed)
        {
            // Typed as well as pressed, but sent when it was pressed: see below
            if (_swallowTyped)
                _swallowTyped = false;
            else if (event.character.length)
                mt_terminal_input(_session, event.character.ptr, event.character.length);
            event.consume();
            return;
        }
        if (event.type != KeyEventType.pressed)
            return;
        _swallowTyped = false;
        const mods = modifiers(event.shift, event.alt, event.control, event.meta);

        // The terminal's own keys, which GNOME Terminal's are
        if (event.control && event.shift && !event.alt)
        {
            switch (event.code)
            {
                case KeyCode.c: copy(); event.consume(); return;
                case KeyCode.v: paste(); event.consume(); return;
                case KeyCode.a: selectAll(); event.consume(); return;
                default: break;
            }
        }
        if (event.shift && !event.control && !event.alt)
        {
            const alt = (_screen.mode & MT_MODE_ALT_SCREEN) != 0; // nothing to scroll back to
            switch (event.code)
            {
                case KeyCode.insert: pasteText(Clipboard.primary()); event.consume(); return;
                case KeyCode.pageUp: if (!alt) { scrollBy(_lines - 1); event.consume(); return; } break;
                case KeyCode.pageDown: if (!alt) { scrollBy(-(_lines - 1)); event.consume(); return; } break;
                case KeyCode.home: if (!alt) { scrollBy(int.max / 2); event.consume(); return; } break;
                case KeyCode.end: if (!alt) { scrollToBottom(); event.consume(); return; } break;
                default: break;
            }
        }

        const key = keyFor(event.code);
        if (key >= 0)
        {
            mt_terminal_key(_session, key, 0, mods);
            event.consume();
            return;
        }
        // A character with Ctrl or Alt is a control code or an escape, not the character: sent
        // from here, and the typed event that may follow it ignored. Shift alone types.
        const code = cast(uint) event.code;
        if ((event.control || event.alt) && code >= 0x20 && code < 0x7f)
        {
            if (mt_terminal_key(_session, MT_KEY_CHARACTER, code, mods))
                _swallowTyped = true;
            event.consume();
        }
    }

    override void handleMouse(ref MouseEvent event)
    {
        if (!_session)
            return;
        int column, line;
        bool right;
        cellAt(event.x, event.y, column, line, right);
        const mods = modifiers(event.shift, event.alt, event.control, event.meta);
        // A program that wants the mouse has it, except while Shift is held, which selects instead
        const reporting = (_screen.mode & MT_MODE_MOUSE) && !event.shift && !_exited;
        const button = event.button == MouseButton.primary ? 0 : event.button == MouseButton.middle ? 1
                     : event.button == MouseButton.secondary ? 2 : 3;

        final switch (event.type)
        {
            case MouseEventType.pressed:
                requestFocus();
                if (reporting)
                {
                    mt_terminal_mouse(_session, MT_MOUSE_PRESS, button, column, line, mods);
                    _held = button;
                    event.consume();
                }
                else if (event.button == MouseButton.primary)
                {
                    const type = event.clickCount >= 3 ? MT_SELECT_LINES
                               : event.clickCount == 2 ? MT_SELECT_SEMANTIC
                               : event.control ? MT_SELECT_BLOCK : MT_SELECT_SIMPLE;
                    if (type == MT_SELECT_SIMPLE)
                        mt_terminal_select_clear(_session); // a click with no drag selects nothing
                    else
                        mt_terminal_select_start(_session, type, column, line, right);
                    _selectFrom = [column, line, right];
                    _selectType = type;
                    _selecting = true;
                    contentChanged();
                    event.consume();
                }
                else if (event.button == MouseButton.middle)
                {
                    pasteText(Clipboard.primary());
                    event.consume();
                }
                break;
            case MouseEventType.dragged:
                if (_held < 3)
                {
                    if (column != _lastColumn || line != _lastLine)
                        mt_terminal_mouse(_session, MT_MOUSE_MOVE, _held, column, line, mods);
                    event.consume();
                }
                else if (_selecting)
                {
                    if (_selectType == MT_SELECT_SIMPLE && !_dragged)
                        mt_terminal_select_start(_session, MT_SELECT_SIMPLE, _selectFrom[0], _selectFrom[1],
                                                 _selectFrom[2]);
                    _dragged = true;
                    mt_terminal_select_update(_session, column, line, right);
                    contentChanged();
                    event.consume();
                }
                break;
            case MouseEventType.released:
                if (_held < 3)
                {
                    mt_terminal_mouse(_session, MT_MOUSE_RELEASE, _held, column, line, mods);
                    _held = 3;
                    event.consume();
                }
                else if (_selecting)
                {
                    _selecting = _dragged = false;
                    if (auto text = selectedText())
                        Clipboard.primary(text);
                    event.consume();
                }
                break;
            case MouseEventType.moved:
                if (reporting && (column != _lastColumn || line != _lastLine))
                    mt_terminal_mouse(_session, MT_MOUSE_MOVE, 3, column, line, mods);
                break;
            case MouseEventType.clicked:
            case MouseEventType.entered:
            case MouseEventType.exited:
                break;
        }
        _lastColumn = column;
        _lastLine = line;
    }

    override void handleScroll(ref ScrollEvent event)
    {
        if (!_session)
            return;
        // A wheel's notch is three lines, as in GNOME Terminal and Alacritty; a touchpad follows
        // the fingers, a line for every line's height they move
        const linePoints = _cellHeight / (_scale > 0 ? _scale : 1);
        _scrollRemainder += event.device == ScrollDevice.wheel ? event.deltaY / Theme.scroll_step * 3
                                                               : event.deltaY / linePoints;
        const lines = cast(int) _scrollRemainder;
        if (!lines)
        {
            event.consume();
            return;
        }
        _scrollRemainder -= lines;
        int column, line;
        bool right;
        cellAt(event.x, event.y, column, line, right);
        mt_terminal_wheel(_session, lines, column, line, modifiers(event.shift, event.alt, event.control, event.meta));
        contentChanged();
        event.consume();
    }

    override void describeAccessible(ref AccessibleNode node)
    {
        if (_windowTitle.length)
            node.label(_windowTitle);
        node.value(screenText());
    }

private:
    string[] _command;
    MtTerminal* _session;
    bool _started, _rooted;
    Notifier _notifier;
    int _exitStatus;
    void delegate(int) _onExited;
    void delegate() _onBell;

    // The fonts, regular, bold, italic and both, and a cell's size from them
    Font[4] _fonts;
    float _advance = 8, _lineHeight = 16, _ascender = 12; // points
    int _cellWidth = 8, _cellHeight = 16, _baseline = 12; // pixels, at _metricsScale
    float _metricsScale = 0;
    bool _cellsResized;
    GlyphRun _deepest;        // characters that reach furthest down, for the cells' height: see measureCells
    GlyphRun[string] _shaped; // a cell's text in a style, shaped once: see glyphsOf
    char[] _key;

    // Where it's been laid out
    float _innerWidth = float.nan, _innerHeight = float.nan, _scale = 0;
    ushort _columns, _lines;

    // The screen as the terminal last gave it, and as it's drawn
    MtScreen _screen;
    MtCell[] _cells, _shown;
    uint[] _combining, _shownCombining;
    int _shownCursorLine = -1, _shownCursorColumn = -1, _shownCursorShape = -1;
    bool _redrawAll = true;
    float _drawnScale = 0;
    bool _contentChanged = true;

    // How it's drawn: a picture a line, in _rows, which is in _grid, which is the widget's paint
    Tvg_Paint _grid, _rows;
    Tvg_Paint[] _pictures;
    uint[] _pixels;
    ubyte[256] _table;
    uint _tableColour = uint.max;

    // Colours: what the terminal's given, and the selection drawn over the cells
    uint[mtColourCount] _palette;
    Colour _selection = Colour(52, 101, 164, 128);

    // Input in progress
    bool _swallowTyped;
    uint _held = 3;                 // the button a program listening to the mouse saw go down, or 3
    bool _selecting, _dragged;
    int[3] _selectFrom;
    uint _selectType;
    int _lastColumn = -1, _lastLine = -1;
    float _scrollRemainder = 0;

    enum mtColourCount = MT_COLOUR_COUNT;

    /// Something will look different: has update() look at the screen again.
    void contentChanged() nothrow @nogc
    {
        _contentChanged = true;
        requestUpdate();
    }

    void loadFonts()
    {
        auto regular = _font ? _font : monospaceFont(Theme.text_size);
        _fonts[0] = regular;
        _fonts[1] = .font(regular.family, regular.size, FontWeight.bold, regular.italic);
        _fonts[2] = .font(regular.family, regular.size, regular.weight, true);
        _fonts[3] = .font(regular.family, regular.size, FontWeight.bold, true);
        _shaped = null;
        _advance = shapeText(regular, "M").width;
        _deepest = shapeText(regular, "_gjy|");
        _lineHeight = regular.lineHeight;
        _ascender = regular.ascender;
        _metricsScale = 0; // the cells' size, worked out again
        _redrawAll = true;
        YGNodeMarkDirty(node);
        requestUpdate();
    }

    void measureCells() nothrow @nogc
    {
        const s = _scale;
        const w = cast(int) roundf(_advance * s), h = cast(int) ceilf(_lineHeight * s);
        _cellWidth = w < 1 ? 1 : w;
        _cellHeight = h < 1 ? 1 : h;
        _baseline = cast(int) roundf(_ascender * s);
        // FreeType rounds a font's metrics to whole pixels, and an underscore can reach below the
        // descender they leave room for -- out of the cell, where it isn't drawn -- so the cell's
        // as tall as the deepest of them, rendered
        foreach (ref g; _deepest.glyphs)
            if (auto b = g.font.glyphBitmap(g.glyph, s))
                if (b.height && _baseline - b.top + b.height > _cellHeight)
                    _cellHeight = _baseline - b.top + b.height;
        _metricsScale = s;
        _cellsResized = true;
        _redrawAll = true;
    }

    void start(ushort columns, ushort lines)
    {
        _started = true;
        auto program = _command.length ? _command[0].toStringz : null;
        const(char)*[] args, env;
        foreach (a; _command.length ? _command[1 .. $] : null)
            args ~= a.toStringz;
        foreach (e; _environment)
            env ~= e.toStringz;
        MtOptions options;
        options.program = program;
        options.args = args.ptr;
        options.arg_count = args.length;
        options.working_directory = _workingDirectory.length ? _workingDirectory.toStringz : null;
        options.env = env.ptr;
        options.env_count = env.length;
        options.columns = columns;
        options.lines = lines;
        options.cell_width = cast(ushort) _cellWidth;
        options.cell_height = cast(ushort) _cellHeight;
        options.scrollback = _scrollback < 0 ? 0 : _scrollback;
        options.wake = &wakeTerminal;
        options.user = cast(void*) _notifier;

        // The reading thread holds the Notifier by a pointer the collector can't see, and the
        // Notifier holds this: rooted, both stay while the program runs
        GC.addRoot(cast(void*) _notifier);
        _rooted = true;
        char[256] error = 0;
        _session = mt_terminal_new(&options, error.ptr, error.length);
        if (!_session)
        {
            unroot();
            const message = fromStringz(error.ptr);
            fprintf(stderr, "Terminal: %.*s\n", cast(int) message.length, message.ptr);
            finish(127); // as a shell says of a command it couldn't run
            return;
        }
        mt_terminal_set_colours(_session, _palette.ptr, _palette.length);
        mt_terminal_focus(_session, focused);
    }

    void unroot() nothrow
    {
        if (_rooted)
            GC.removeRoot(cast(void*) _notifier);
        _rooted = false;
    }

    void finish(int status)
    {
        _exitStatus = status;
        _setExited(true);
        if (_onExited)
            _onExited(status);
    }

    /// What the reading thread said: run on the UI thread, by the Notifier.
    void readNews()
    {
        if (!_session)
            return;
        const events = mt_terminal_take_events(_session);
        if (events & MT_EVENT_TITLE)
            _setWindowTitle(take(&mt_terminal_title));
        if (events & MT_EVENT_CLIPBOARD)
            Clipboard.text(take(&mt_terminal_clipboard));
        if ((events & MT_EVENT_BELL) && _onBell)
            _onBell();
        if (events & (MT_EVENT_CONTENT | MT_EVENT_EXITED))
            contentChanged();
        int status;
        if ((events & MT_EVENT_EXITED) && !_exited && mt_terminal_exit_status(_session, &status))
        {
            unroot(); // nothing more will come
            finish(status);
        }
    }

    /// One of the terminal's strings.
    string take(StringGetter get)
    {
        const n = get(_session, null, 0);
        auto buffer = new char[n];
        get(_session, buffer.ptr, n);
        return cast(string) buffer;
    }

    void pasteText(string text)
    {
        if (_session && !_exited && text.length)
            mt_terminal_paste(_session, text.ptr, text.length);
    }

    void scrollBy(int lines)
    {
        mt_terminal_scroll(_session, lines);
        contentChanged();
    }

    void scrollToBottom()
    {
        mt_terminal_scroll_to_bottom(_session);
        contentChanged();
    }

    /// The cell at `x`, `y`, in points from the widget's top left, and whether it's in its right half.
    void cellAt(float x, float y, out int column, out int line, out bool right) nothrow @nogc
    {
        const s = _scale > 0 ? _scale : 1;
        const cx = (x - YGNodeLayoutGetPadding(node, YGEdgeLeft)) * s / _cellWidth;
        const cy = (y - YGNodeLayoutGetPadding(node, YGEdgeTop)) * s / _cellHeight;
        column = cast(int) floorf(cx);
        line = cast(int) floorf(cy);
        right = cx - column >= 0.5f;
        if (column < 0) { column = 0; right = false; }
        if (column >= _columns) { column = _columns - 1; right = true; }
        if (line < 0) line = 0;
        if (line >= _lines) line = _lines - 1;
    }

    /// Takes the screen from the terminal, and draws again the lines of it that changed.
    void refresh()
    {
        if (!_session || !_rows || !_contentChanged && !_redrawAll && _drawnScale == _scale)
            return;
        _contentChanged = false;
        while (mt_terminal_screen(_session, &_screen, _cells.ptr, _cells.length, _combining.ptr, _combining.length))
        {
            _cells.length = cast(size_t) _screen.columns * _screen.lines;
            _combining.length = _screen.combining_count;
        }
        const columns = _screen.columns, lines = _screen.lines;
        _cells.length = cast(size_t) columns * lines;
        if (_shown.length != _cells.length || _drawnScale != _scale)
        {
            _shown.length = _cells.length;
            _redrawAll = true;
        }

        // The cursor, as it's drawn: hollow without focus, nowhere if it's scrolled out of view
        int shape = _screen.cursor_shape;
        if (shape == MT_CURSOR_BLOCK && !focused)
            shape = MT_CURSOR_HOLLOW;
        int cursorLine = _screen.cursor_line, cursorColumn = _screen.cursor_column;
        if (cursorLine < 0 || cursorLine >= lines || shape == MT_CURSOR_HIDDEN)
            cursorLine = cursorColumn = -1;

        // A picture a line, made or let go to match
        while (_pictures.length > lines)
        {
            tvg_scene_remove(_rows, _pictures[$ - 1]); // and ThorVG frees it
            _pictures.length--;
        }
        while (_pictures.length < lines)
            _pictures ~= null;

        bool drew;
        foreach (l; 0 .. lines)
        {
            const cursorHere = l == cursorLine, cursorWas = l == _shownCursorLine;
            const cursorMoved = (cursorHere || cursorWas)
                && (cursorLine != _shownCursorLine || cursorColumn != _shownCursorColumn || shape != _shownCursorShape);
            if (!_redrawAll && _pictures[l] && !cursorMoved && !lineChanged(l))
                continue;
            drawLine(l, cursorHere ? cursorColumn : -1, shape);
            drew = true;
        }
        _shown[] = _cells[];
        _shownCombining = _combining.dup;
        _shownCursorLine = cursorLine;
        _shownCursorColumn = cursorColumn;
        _shownCursorShape = shape;
        _redrawAll = false;
        _drawnScale = _scale;
        invalidate(); // the background, if a program changed it, and the new pictures
        if (drew)
            invalidateAccessible();
    }

    /// Whether line `l` is different from how it's drawn.
    bool lineChanged(size_t l) nothrow @nogc
    {
        const from = l * _columns, to = from + _columns;
        foreach (i; from .. to)
        {
            const a = _cells[i], b = _shown[i];
            if (a.c != b.c || a.fg != b.fg || a.bg != b.bg || a.flags != b.flags
                || a.combining_count != b.combining_count)
                return true;
            foreach (k; 0 .. a.combining_count)
            {
                const ai = a.combining_start + k, bi = b.combining_start + k;
                if (ai >= _combining.length || bi >= _shownCombining.length
                    || _combining[ai] != _shownCombining[bi])
                    return true;
            }
        }
        return false;
    }

    /// Draws line `l` into its picture, with the cursor in `cursorColumn` if it's on it.
    void drawLine(int l, int cursorColumn, int cursorShape)
    {
        const cw = _cellWidth, ch = _cellHeight;
        const width = _columns * cw;
        _pixels.length = cast(size_t) width * ch;
        _pixels[] = 0;
        auto cells = _cells[l * _columns .. (l + 1) * _columns];
        const selection = premultiplied(_selection);

        // Backgrounds first, every cell's, so that a glyph reaching past its own isn't covered by the next
        foreach (c, ref cell; cells)
        {
            uint px = cell.flags & MT_CELL_DEFAULT_BG ? 0 : 0xFF000000 | cell.bg;
            if (cell.flags & MT_CELL_SELECTED)
                px = blend(px, selection);
            if (px)
                fill(cast(int) c * cw, 0, cw, ch, px, width);
        }
        const solid = cursorColumn >= 0 && cursorShape == MT_CURSOR_BLOCK;
        const cursorSpan = cursorColumn >= 0 && cursorColumn < _columns
            && (cells[cursorColumn].flags & MT_CELL_WIDE) ? 2 : 1;
        if (solid)
            fill(cursorColumn * cw, 0, cw * cursorSpan, ch, 0xFF000000 | _screen.cursor, width);

        foreach (c, ref cell; cells)
        {
            if (cell.flags & MT_CELL_SPACER)
                continue;
            const span = cell.flags & MT_CELL_WIDE ? 2 : 1;
            // Under a solid cursor, text is the colour of what the cursor covers
            const fg = solid && c == cursorColumn ? (cell.flags & MT_CELL_DEFAULT_BG ? _screen.background : cell.bg)
                                                   : cell.fg;
            const x = cast(int) c * cw;
            if (cell.c != ' ' && cell.c != 0 || cell.combining_count)
                drawGlyphs(cell, x, span * cw, fg, width);
            drawDecorations(cell.flags, x, span * cw, fg, width);
        }

        // The other cursors, over the text
        if (cursorColumn >= 0 && !solid)
        {
            const colour = 0xFF000000 | _screen.cursor;
            const thick = cast(int) roundf(_scale * 1.5f) < 1 ? 1 : cast(int) roundf(_scale * 1.5f);
            const x = cursorColumn * cw, w = cw * cursorSpan;
            switch (cursorShape)
            {
                case MT_CURSOR_BEAM: fill(x, 0, thick, ch, colour, width); break;
                case MT_CURSOR_UNDERLINE: fill(x, ch - thick, w, thick, colour, width); break;
                case MT_CURSOR_HOLLOW:
                    const t = thick > 1 ? thick - 1 : 1;
                    fill(x, 0, w, t, colour, width);
                    fill(x, ch - t, w, t, colour, width);
                    fill(x, 0, t, ch, colour, width);
                    fill(x + w - t, 0, t, ch, colour, width);
                    break;
                default: break;
            }
        }

        // A new picture each time, as ThorVG won't load one again once it's been drawn
        auto picture = tvg_picture_new();
        tvg_picture_load_raw(picture, _pixels.ptr, width, ch, TVG_COLORSPACE_ARGB8888, true);
        tvg_picture_set_size(picture, width / _scale, ch / _scale);
        tvg_paint_translate(picture, 0, l * ch / _scale);
        if (auto old = _pictures[l])
        {
            tvg_scene_insert(_rows, picture, old);
            tvg_scene_remove(_rows, old);
        }
        else
            tvg_scene_add(_rows, picture);
        _pictures[l] = picture;
    }

    /// The glyphs of `cell`, in `fg`, in the `span` pixels from `x`.
    void drawGlyphs(ref const MtCell cell, int x, int span, uint fg, int width)
    {
        const style = (cell.flags & MT_CELL_BOLD ? 1 : 0) | (cell.flags & MT_CELL_ITALIC ? 2 : 0);
        auto run = glyphsOf(cell, style);
        if (!run.glyphs.length)
            return;
        // A glyph from a fallback font may be narrower or wider than a cell: centred in it
        const offset = cast(int) roundf((span - run.width * _scale) / 2);
        if (fg != _tableColour)
        {
            coverageCurve(fg, _table);
            _tableColour = fg;
        }
        foreach (ref g; run.glyphs)
        {
            auto b = g.font.glyphBitmap(g.glyph, _scale);
            if (!b || !b.coverage)
                continue;
            const ox = x + offset + cast(int) roundf(g.x * _scale) + b.left;
            const oy = _baseline + cast(int) roundf(g.y * _scale) - b.top;
            foreach (row; 0 .. b.height)
            {
                const py = oy + row;
                if (py < 0 || py >= _cellHeight)
                    continue;
                auto dst = _pixels.ptr + py * width;
                auto src = b.coverage + row * b.width;
                foreach (col; 0 .. b.width)
                {
                    const px = ox + col;
                    if (px < 0 || px >= width)
                        continue;
                    const cov = _table[src[col]];
                    if (cov)
                        dst[px] = over(dst[px], fg, cov);
                }
            }
        }
    }

    /// The cell's text in `style`, shaped, from the regular, bold, italic or bold italic font.
    GlyphRun glyphsOf(ref const MtCell cell, int style)
    {
        // Looked up by the style and the text, put together in a buffer kept for it, so drawing a
        // screen of what's been seen before allocates nothing
        _key.length = 0;
        _key.assumeSafeAppend();
        _key ~= cast(char)('0' + style);
        encode(_key, cast(dchar) cell.c);
        foreach (k; 0 .. cell.combining_count)
            if (cell.combining_start + k < _combining.length)
                encode(_key, cast(dchar) _combining[cell.combining_start + k]);
        if (auto run = cast(string) _key in _shaped)
            return *run;
        auto run = shapeText(_fonts[style], _key[1 .. $]);
        _shaped[_key.idup] = run;
        return run;
    }

    /// Underlines and strikeouts, in `fg`, along the `span` pixels from `x`.
    void drawDecorations(uint flags, int x, int span, uint fg, int width) nothrow
    {
        const colour = 0xFF000000 | fg;
        auto regular = _fonts[0];
        int thick = cast(int) roundf(regular.underlineThickness * _scale);
        if (thick < 1)
            thick = 1;
        int under = _baseline + cast(int) roundf(regular.underlinePosition * _scale);
        if (under + thick > _cellHeight)
            under = _cellHeight - thick;
        if (flags & MT_CELL_UNDERLINE)
            fill(x, under, span, thick, colour, width);
        if (flags & MT_CELL_DOUBLE_UNDERLINE)
        {
            // Below the first if there's room in the cell, else above it
            const gap = thick < 2 ? 2 : thick * 2;
            const second = under + gap + thick <= _cellHeight ? under + gap : under - gap;
            fill(x, under, span, thick, colour, width);
            fill(x, second, span, thick, colour, width);
        }
        if (flags & MT_CELL_DOTTED_UNDERLINE)
            for (int dx = 0; dx < span; dx += thick * 2)
                fill(x + dx, under, thick, thick, colour, width);
        if (flags & MT_CELL_DASHED_UNDERLINE)
            for (int dx = 0; dx < span; dx += thick * 6)
                fill(x + dx, under, thick * 4 < span - dx ? thick * 4 : span - dx, thick, colour, width);
        if (flags & MT_CELL_UNDERCURL)
        {
            // A wave a cell wide, as tall as two lines are thick
            foreach (dx; 0 .. span)
            {
                const wave = sinf(dx * 2 * 3.14159265f / _cellWidth);
                fill(x + dx, under - thick + cast(int) roundf(wave * thick), 1, thick, colour, width);
            }
        }
        if (flags & MT_CELL_STRIKEOUT)
            fill(x, _baseline - cast(int) roundf(regular.xHeight * _scale / 2), span, thick, colour, width);
    }

    /// Fills a rectangle of the line's pixels with `px`, premultiplied, cut to the line.
    void fill(int x, int y, int w, int h, uint px, int width) nothrow @nogc
    {
        int x1 = x + w, y1 = y + h;
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x1 > width) x1 = width;
        if (y1 > _cellHeight) y1 = _cellHeight;
        foreach (row; y .. y1)
            _pixels[row * width + x .. row * width + x1] = px;
    }
}

private:

/// One of the C API's functions that hand out a string: see Terminal.take.
alias StringGetter = extern (C) size_t function(MtTerminal*, char*, size_t) nothrow @nogc;

/// Has a terminal's Notifier run its task: called on the terminal's reading thread.
extern (C) void wakeTerminal(void* user) nothrow @nogc
{
    (cast(Notifier) user).signal();
}

/// Its preferred size: 80 columns by 24 lines, as a terminal has always been.
extern (C) YGSize measureTerminal(YGNodeConstRef node, float width, YGMeasureMode widthMode,
                                  float height, YGMeasureMode heightMode) nothrow @nogc
{
    auto self = cast(Terminal) YGNodeGetContext(node);
    if (!self)
        return YGSize(0, 0);
    return YGSize(self._advance * 80, self._lineHeight * 24);
}

/// The first of the usual monospace families that's installed, at `size`.
Font monospaceFont(float size)
{
    static immutable families = ["Adwaita Mono", "Source Code Pro", "DejaVu Sans Mono", "Noto Sans Mono",
                                 "Ubuntu Mono", "Liberation Mono", "Cascadia Mono", "JetBrains Mono",
                                 "Fira Mono", "Menlo", "Consolas", "Courier New"];
    foreach (family; families)
        if (hasFamily(family))
            return font(family, size);
    return defaultFont(size); // not monospace, but every character still has its cell
}

/// Tango's palette, which GNOME Terminal starts with, and the text, background and cursor after it.
immutable uint[MT_COLOUR_COUNT] tango = [
    0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
    0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec,
    0xd3d7cf, 0x1e1e1e, 0xd3d7cf,
];

immutable string[16] paletteVariables = () {
    import std.conv : to;
    string[16] names;
    foreach (i; 0 .. 16)
        names[i] = "--terminal-colour-" ~ i.to!string;
    return names;
}();

uint modifiers(bool shift, bool alt, bool control, bool meta) nothrow @nogc
{
    return (shift ? MT_MOD_SHIFT : 0) | (alt ? MT_MOD_ALT : 0) | (control ? MT_MOD_CONTROL : 0)
         | (meta ? MT_MOD_META : 0);
}

/// The terminal's name for a key that isn't typing, or -1 for one that is.
int keyFor(KeyCode code) nothrow @nogc
{
    switch (code)
    {
        case KeyCode.enter, KeyCode.numpadEnter: return MT_KEY_ENTER;
        case KeyCode.tab: return MT_KEY_TAB;
        case KeyCode.backspace: return MT_KEY_BACKSPACE;
        case KeyCode.escape: return MT_KEY_ESCAPE;
        case KeyCode.insert: return MT_KEY_INSERT;
        case KeyCode.delete_: return MT_KEY_DELETE;
        case KeyCode.home: return MT_KEY_HOME;
        case KeyCode.end: return MT_KEY_END;
        case KeyCode.pageUp: return MT_KEY_PAGE_UP;
        case KeyCode.pageDown: return MT_KEY_PAGE_DOWN;
        case KeyCode.up: return MT_KEY_UP;
        case KeyCode.down: return MT_KEY_DOWN;
        case KeyCode.left: return MT_KEY_LEFT;
        case KeyCode.right: return MT_KEY_RIGHT;
        case KeyCode.f1: .. case KeyCode.f12: return MT_KEY_F1 + (code - KeyCode.f1);
        default: return -1;
    }
}

uint packed(Colour c) nothrow @nogc { return c.r << 16 | c.g << 8 | c.b; }

Colour unpacked(uint c) nothrow @nogc { return Colour((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF); }

/// `c` as a premultiplied 0xAARRGGBB.
uint premultiplied(Colour c) nothrow @nogc
{
    return c.a << 24 | (c.r * c.a / 255) << 16 | (c.g * c.a / 255) << 8 | (c.b * c.a / 255);
}

/// Premultiplied `src` over premultiplied `dst`.
uint blend(uint dst, uint src) nothrow @nogc
{
    const keep = 255 - (src >> 24);
    uint channel(int shift) { return ((src >> shift) & 0xFF) + ((dst >> shift) & 0xFF) * keep / 255; }
    return channel(24) << 24 | channel(16) << 16 | channel(8) << 8 | channel(0);
}

/// Opaque colour `rgb` at `coverage` over `dst`, a premultiplied 0xAARRGGBB, as source-over does.
uint over(uint dst, uint rgb, ubyte coverage) nothrow @nogc
{
    const a = coverage;
    const r = ((rgb >> 16) & 0xFF) * a / 255, g = ((rgb >> 8) & 0xFF) * a / 255, b = (rgb & 0xFF) * a / 255;
    return blend(dst, a << 24 | r << 16 | g << 8 | b);
}

/*
    Coverage as it's blended, for text in `rgb`: light text's lifted, as mayfair.text.raster lifts
    it, so that light text on a dark ground isn't thin. See coverageCurve there.
*/
void coverageCurve(uint rgb, ref ubyte[256] table) nothrow @nogc
{
    static float linear(uint c) nothrow @nogc
    {
        const v = c / 255.0f;
        return v <= 0.04045f ? v / 12.92f : powf((v + 0.055f) / 1.055f, 2.4f);
    }
    const luminance = 0.2126f * linear((rgb >> 16) & 0xFF) + 0.7152f * linear((rgb >> 8) & 0xFF)
                    + 0.0722f * linear(rgb & 0xFF);
    const exponent = 1 / (1 + (Theme.text_gamma - 1) * luminance);
    foreach (i; 0 .. 256)
        table[i] = cast(ubyte)(powf(i / 255.0f, exponent) * 255 + 0.5f);
}
