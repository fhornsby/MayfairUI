/*
    A C API on alacritty_terminal: a pseudoterminal with a program running in it, the escape
    sequences it writes parsed into a grid of cells, and the keys, mouse and pastes sent back to it
    encoded the way that program expects. What it doesn't do is draw: the caller asks for the
    cells (mt_terminal_screen) and draws them however it likes.

    Each terminal has a thread of its own reading the program's output. Everything here is called
    from one other thread, the caller's, except `wake`, which the reading thread calls: see
    MtOptions. Nothing here throws, panics across the boundary, or keeps a pointer it was given
    past the call it was given in.

    Lines are counted in the view, from 0 at the top of what's shown, whether or not it's scrolled
    back into the history. Colours are 0xRRGGBB.
*/
#ifndef MAYFAIR_TERMINAL_H
#define MAYFAIR_TERMINAL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MtTerminal MtTerminal;

/*
    Called on the terminal's reading thread when there's something new to look at: output drawn
    into the grid, a new title, the bell, the program exiting. Only once until the caller has taken
    the news with mt_terminal_take_events, however much more arrives, so it's cheap however busy
    the program is. It mustn't call back into the terminal: it's for waking the caller's thread.
*/
typedef void (*MtWakeFn)(void *user);

typedef struct MtOptions
{
    const char *program;               /* NULL for the user's login shell */
    const char *const *args;           /* arguments after the program's name */
    size_t arg_count;
    const char *working_directory;     /* NULL for the caller's */
    const char *const *env;            /* "NAME=value" each, on top of the caller's environment */
    size_t env_count;
    uint16_t columns, lines;
    uint16_t cell_width, cell_height;  /* in pixels, for programs that ask how big the window is */
    uint32_t scrollback;               /* lines of history kept */
    MtWakeFn wake;
    void *user;                        /* handed to wake */
} MtOptions;

/* Starts the program in a new terminal. NULL if it couldn't, with why in `error`, NUL-terminated. */
MtTerminal *mt_terminal_new(const MtOptions *options, char *error, size_t error_size);

/* Hangs up on the program, which a shell takes as its cue to exit, and lets the terminal go.
   `wake` isn't called once this has returned. */
void mt_terminal_free(MtTerminal *terminal);

/* Colours, in this order: the 16 of the palette, then the text, the background and the cursor.
   What a program sets with OSC 4, 10, 11 or 12 wins over these until it resets them. */
enum { MT_COLOUR_FOREGROUND = 16, MT_COLOUR_BACKGROUND = 17, MT_COLOUR_CURSOR = 18, MT_COLOUR_COUNT = 19 };
void mt_terminal_set_colours(MtTerminal *terminal, const uint32_t *colours, size_t count);

/* A new size: the program is told, with SIGWINCH. */
void mt_terminal_resize(MtTerminal *terminal, uint16_t columns, uint16_t lines,
                        uint16_t cell_width, uint16_t cell_height);

/*
    What's happened since it was last asked, as MT_EVENT_* bits, and lets `wake` be called again.
    Requests the program made that need the terminal's state -- the colours it asked for, the
    window size -- are answered here too, on the caller's thread.
*/
enum
{
    MT_EVENT_CONTENT   = 1 << 0,  /* something may look different */
    MT_EVENT_TITLE     = 1 << 1,  /* mt_terminal_title has changed */
    MT_EVENT_BELL      = 1 << 2,
    MT_EVENT_EXITED    = 1 << 3,  /* the program's gone: see mt_terminal_exit_status */
    MT_EVENT_CLIPBOARD = 1 << 4,  /* it asked for text to be copied: see mt_terminal_clipboard */
};
uint32_t mt_terminal_take_events(MtTerminal *terminal);

/*
    The title the program set, and the text it asked to have copied (OSC 52), as UTF-8 without a
    NUL. Each returns its whole length and copies as much as fits, so a caller can ask with no
    room to find out how much it needs.
*/
size_t mt_terminal_title(MtTerminal *terminal, char *buffer, size_t size);
size_t mt_terminal_clipboard(MtTerminal *terminal, char *buffer, size_t size);

/* 1 once the program has exited, with its exit code in `status`, or minus the signal that ended it. */
int mt_terminal_exit_status(MtTerminal *terminal, int *status);

/*
    The screen. One cell per column per line, a line after another, with the colours resolved:
    inverse video swapped, dim dimmed, hidden text hidden, the palette applied. A wide character's
    cell is followed by a spacer, which shows nothing of its own.
*/
enum
{
    MT_CELL_BOLD             = 1 << 0,
    MT_CELL_ITALIC           = 1 << 1,
    MT_CELL_UNDERLINE        = 1 << 2,
    MT_CELL_DOUBLE_UNDERLINE = 1 << 3,
    MT_CELL_UNDERCURL        = 1 << 4,
    MT_CELL_DOTTED_UNDERLINE = 1 << 5,
    MT_CELL_DASHED_UNDERLINE = 1 << 6,
    MT_CELL_STRIKEOUT        = 1 << 7,
    MT_CELL_WIDE             = 1 << 8,  /* takes this cell and the next */
    MT_CELL_SPACER           = 1 << 9,  /* the second half of a wide character, or a gap left for one */
    MT_CELL_SELECTED         = 1 << 10,
    MT_CELL_DEFAULT_BG       = 1 << 11, /* bg is the terminal's own background */
};

typedef struct MtCell
{
    uint32_t c;                /* the character, or ' ' */
    uint32_t fg, bg;
    uint16_t flags;            /* MT_CELL_* */
    uint16_t combining_count;  /* characters combined with it, from combining_start in the screen's array */
    uint32_t combining_start;
} MtCell;

enum
{
    MT_CURSOR_HIDDEN,
    MT_CURSOR_BLOCK,
    MT_CURSOR_UNDERLINE,
    MT_CURSOR_BEAM,
    MT_CURSOR_HOLLOW,
};

/* The modes a caller drawing and sending input has to know about, from MtScreen.mode. */
enum
{
    MT_MODE_MOUSE      = 1 << 0,  /* the program wants the mouse: clicks and drags go to it */
    MT_MODE_ALT_SCREEN = 1 << 1,  /* a full-screen program, with no history to scroll */
};

typedef struct MtScreen
{
    uint16_t columns, lines;
    int32_t cursor_column, cursor_line;  /* in the view: off it if it's scrolled away */
    uint8_t cursor_shape;                /* MT_CURSOR_* */
    uint8_t cursor_blinking;
    uint16_t mode;                       /* MT_MODE_* */
    uint32_t foreground, background, cursor; /* the colours, as the program may have changed them */
    uint32_t display_offset;             /* how many lines it's scrolled back */
    uint32_t history_size;               /* how many there are to scroll back through */
    uint32_t combining_count;            /* how many characters are combined with others, in all */
} MtScreen;

/*
    Fills in `screen` and, if there's room for them, the cells (columns * lines) and the combining
    characters. Returns 0 if everything fit, or 1 if not, in which case `screen` still says how much
    room is needed.
*/
int mt_terminal_screen(MtTerminal *terminal, MtScreen *screen, MtCell *cells, size_t cell_capacity,
                       uint32_t *combining, size_t combining_capacity);

/* Input. Each returns 1 if it sent the program anything. */
enum { MT_MOD_SHIFT = 1 << 0, MT_MOD_ALT = 1 << 1, MT_MOD_CONTROL = 1 << 2, MT_MOD_META = 1 << 3 };

enum
{
    MT_KEY_CHARACTER,  /* the codepoint given: for Ctrl and Alt with a letter, digit or symbol */
    MT_KEY_ENTER, MT_KEY_TAB, MT_KEY_BACKSPACE, MT_KEY_ESCAPE,
    MT_KEY_INSERT, MT_KEY_DELETE, MT_KEY_HOME, MT_KEY_END, MT_KEY_PAGE_UP, MT_KEY_PAGE_DOWN,
    MT_KEY_UP, MT_KEY_DOWN, MT_KEY_LEFT, MT_KEY_RIGHT,
    MT_KEY_F1, MT_KEY_F2, MT_KEY_F3, MT_KEY_F4, MT_KEY_F5, MT_KEY_F6,
    MT_KEY_F7, MT_KEY_F8, MT_KEY_F9, MT_KEY_F10, MT_KEY_F11, MT_KEY_F12,
};

/* A key that isn't plain typing: what it sends depends on the modifiers and the program's modes. */
int mt_terminal_key(MtTerminal *terminal, uint32_t key, uint32_t codepoint, uint32_t mods);

/* Typed text, sent as it is. */
int mt_terminal_input(MtTerminal *terminal, const char *utf8, size_t length);

/* Pasted text: bracketed, if the program asked for that, so it knows it wasn't typed. */
int mt_terminal_paste(MtTerminal *terminal, const char *utf8, size_t length);

/* The terminal gained or lost keyboard focus, for programs that asked to know. */
int mt_terminal_focus(MtTerminal *terminal, int focused);

/*
    The mouse, for a program that has asked for it (MT_MODE_MOUSE). `button` is 0, 1 or 2 for the
    primary, middle and secondary, and 3 for none, as when it moves with nothing held. Returns 0,
    sending nothing, if the program isn't listening for this.
*/
enum { MT_MOUSE_PRESS, MT_MOUSE_RELEASE, MT_MOUSE_MOVE };
int mt_terminal_mouse(MtTerminal *terminal, uint32_t kind, uint32_t button, int32_t column, int32_t line,
                      uint32_t mods);

/*
    The wheel, `lines` up (positive) or down. Goes to a program listening to the mouse; to a
    full-screen one that isn't, as arrow keys; and otherwise scrolls the history.
*/
int mt_terminal_wheel(MtTerminal *terminal, int32_t lines, int32_t column, int32_t line, uint32_t mods);

/* Scrolls the history in view: up `lines` (positive) or down, and back to the bottom. */
void mt_terminal_scroll(MtTerminal *terminal, int32_t lines);
void mt_terminal_scroll_to_bottom(MtTerminal *terminal);

/*
    Selecting text. `right_half` says which half of the cell the pointer is over, which decides
    whether the cell is in. A semantic selection grows to the word, a lines one to whole lines.
*/
enum { MT_SELECT_SIMPLE, MT_SELECT_BLOCK, MT_SELECT_SEMANTIC, MT_SELECT_LINES };
void mt_terminal_select_start(MtTerminal *terminal, uint32_t type, int32_t column, int32_t line, int right_half);
void mt_terminal_select_update(MtTerminal *terminal, int32_t column, int32_t line, int right_half);
void mt_terminal_select_all(MtTerminal *terminal);
void mt_terminal_select_clear(MtTerminal *terminal);

/* What's selected, as UTF-8, the same way as mt_terminal_title. 0 for nothing. */
size_t mt_terminal_selection_text(MtTerminal *terminal, char *buffer, size_t size);

#ifdef __cplusplus
}
#endif

#endif
