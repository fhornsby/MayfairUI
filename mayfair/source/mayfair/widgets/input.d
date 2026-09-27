module mayfair.widgets.input;

import mayfair.widgets.widget;

/// What happened to the mouse. JavaFX's MouseEvent types.
enum MouseEventType
{
    pressed,  /// A button went down
    released, /// A button came up. Goes to the widget it went down on, wherever the pointer is now.
    clicked,  /// A button went down and came up again. Goes to the deepest widget under both.
    entered,  /// The pointer moved onto a widget. Doesn't bubble: each widget it's now over hears it.
    exited,   /// The pointer moved off a widget. Doesn't bubble either.
    moved,    /// The pointer moved with no button down
    dragged,  /// The pointer moved with a button down. Goes to the widget it went down on.
}

/// JavaFX's MouseButton.
enum MouseButton { none, primary, middle, secondary, back, forward }

/*
    One thing the mouse did, on its way through the widgets it concerns.

    Most events bubble: the widget under the pointer hears first, then its parent, and so on up
    to the root, until one of them consumes it. That's JavaFX's order, and it's what lets a click
    on a button's label count as a click on the button.
*/
struct MouseEvent
{
    MouseEventType type;
    MouseButton button;   /// The button that changed, for pressed, released and clicked
    int clickCount;       /// 1 for a single click, 2 for the second press of a double click, ...
    float sceneX = 0, sceneY = 0; /// Where the pointer is, in points from the window's top left
    float x = 0, y = 0;   /// The same, from the top left of the widget hearing the event
    Widget target;        /// The widget the event is about, which it bubbles up from
    bool shift, control, alt, meta; /// The modifier keys held down at the time
    bool consumed;

    /// Stops the event going any further up the tree.
    void consume() nothrow @nogc { consumed = true; }
}

/// What a widget calls when it hears about a mouse event.
alias MouseHandler = void delegate(ref MouseEvent event);

/*
    The wheel turned, or fingers moved on a touchpad: JavaFX's ScrollEvent. It goes to the
    widget under the pointer and bubbles up from there, like a mouse event, so the nearest thing
    that scrolls -- a ScrollPane, say -- takes it, and one inside another scrolls first.

    The deltas are in points, and say which way the content should move: deltaY is positive when
    the wheel turns away from the user, which scrolls up and brings the top into view, as in
    JavaFX. A notch of a wheel is Theme.scroll_step points, JavaFX's 40. A touchpad follows the
    fingers, and the desktop's natural scrolling setting is already applied to both.

    Which of the two it was matters to how it's shown: a wheel's notch is eased into, and a
    touchpad's movement carries on after the fingers lift (see ScrollPane). `time` is when it
    happened, in seconds on a clock of its own, for working out how fast the fingers were going.
*/
struct ScrollEvent
{
    float deltaX = 0, deltaY = 0; /// How far, in points: see above
    float sceneX = 0, sceneY = 0; /// Where the pointer is, in points from the window's top left
    float x = 0, y = 0;           /// The same, from the top left of the widget hearing the event
    Widget target;                /// The widget under the pointer, which it bubbles up from
    ScrollDevice device;          /// What it came from
    double time = 0;              /// When, in seconds: only the differences between events mean anything
    bool shift, control, alt, meta;
    bool consumed;

    void consume() nothrow @nogc { consumed = true; }
}

/// What a scroll came from.
enum ScrollDevice
{
    wheel,    /// A mouse wheel, in notches
    touchpad, /// Fingers on a touchpad, following them
}

/// What a widget calls when it hears about a scroll.
alias ScrollHandler = void delegate(ref ScrollEvent event);

/// What happened on the keyboard. JavaFX's KeyEvent types.
enum KeyEventType
{
    pressed,  /// A key went down, or auto-repeated while held
    released, /// A key came up
    typed,    /// Text was typed. Only arrives while a widget that accepts text input has focus.
}

/*
    Which key, by what it means on the user's layout rather than where it is on the keyboard:
    JavaFX's KeyCode. The values are SDL's keycodes, so a key without a name here still arrives
    with its own value, and a letter key's value is its lower-case character.
*/
enum KeyCode : uint
{
    undefined = 0x0,
    backspace = 0x8,
    tab = 0x9,
    enter = 0xd,
    escape = 0x1b,
    space = 0x20,
    delete_ = 0x7f,   // `delete` is a D keyword
    insert = 0x40000049,
    home = 0x4000004a,
    pageUp = 0x4000004b,
    end = 0x4000004d,
    pageDown = 0x4000004e,
    right = 0x4000004f,
    left = 0x40000050,
    down = 0x40000051,
    up = 0x40000052,
    numpadEnter = 0x40000058,

    digit0 = 0x30,
    digit1 = 0x31,
    digit2 = 0x32,
    digit3 = 0x33,
    digit4 = 0x34,
    digit5 = 0x35,
    digit6 = 0x36,
    digit7 = 0x37,
    digit8 = 0x38,
    digit9 = 0x39,

    a = 0x61,
    b = 0x62,
    c = 0x63,
    d = 0x64,
    e = 0x65,
    f = 0x66,
    g = 0x67,
    h = 0x68,
    i = 0x69,
    j = 0x6a,
    k = 0x6b,
    l = 0x6c,
    m = 0x6d,
    n = 0x6e,
    o = 0x6f,
    p = 0x70,
    q = 0x71,
    r = 0x72,
    s = 0x73,
    t = 0x74,
    u = 0x75,
    v = 0x76,
    w = 0x77,
    x = 0x78,
    y = 0x79,
    z = 0x7a,

    f1 = 0x4000003a,
    f2 = 0x4000003b,
    f3 = 0x4000003c,
    f4 = 0x4000003d,
    f5 = 0x4000003e,
    f6 = 0x4000003f,
    f7 = 0x40000040,
    f8 = 0x40000041,
    f9 = 0x40000042,
    f10 = 0x40000043,
    f11 = 0x40000044,
    f12 = 0x40000045,
    application = 0x40000065, /// The Menu key, between the right Windows key and Ctrl
    menu = 0x40000076,        /// A Menu key, on the keyboards that have one by that name
}

/*
    One key going down or up. It goes to the widget with focus -- or the root, if nothing has it
    -- and bubbles up from there like a mouse event. What nothing consumes, the scene has a use for:
    Tab moves focus on, and then every widget gets a chance at it as a shortcut (see
    Widget.handleShortcut), which is how Enter reaches a default button that doesn't have focus.
*/
struct KeyEvent
{
    KeyEventType type;
    KeyCode code;
    bool shift, control, alt, meta; /// The modifiers held down with it. Meta is the Windows or Command key.
    bool repeat;                    /// A key held down, sending pressed again
    string character;               /// For typed: the text, which an input method may commit a word of at once
    Widget target;
    bool consumed;

    void consume() nothrow @nogc { consumed = true; }
}

/// What a widget calls when it hears about a key event.
alias KeyHandler = void delegate(ref KeyEvent event);

/*
    An input method composing text: pinyin being typed out before it's turned into characters, or
    a dead key waiting for its letter. What's composed isn't text yet, just something to show where
    it will go; when the user commits it, it arrives as a typed KeyEvent, and this is sent again
    with nothing composed. JavaFX's InputMethodEvent.
*/
struct InputMethodEvent
{
    string composed;      /// The text being composed. Empty once it's committed or abandoned.
    int caret = -1;       /// Where in `composed` the input method's cursor is, in characters, or -1
    int selectionLength = -1; /// How many characters from the caret it has selected, or -1
    Widget target;
    bool consumed;

    void consume() nothrow @nogc { consumed = true; }
}

/// What a widget calls when an input method's composition changes.
alias InputMethodHandler = void delegate(ref InputMethodEvent event);

/// The mouse pointer's shape over a widget. JavaFX's Cursor.
enum Cursor
{
    inherit,     /// Whatever the widget it's in shows: the default for every widget
    default_,    /// The ordinary arrow. (`default` is a D keyword.)
    text,        /// The I-beam, for text that can be selected or typed into
    hand,        /// A pointing hand, for a link
    crosshair,
    wait,
    move,
    notAllowed,
    resizeHorizontal,
    resizeVertical,
}
