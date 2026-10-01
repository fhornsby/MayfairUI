//! A C API on alacritty_terminal: see include/mayfair_terminal.h, which is the documentation.
//!
//! alacritty_terminal is Alacritty's emulator without its window: a grid of cells, the parser that
//! writes into it, and a thread reading a pseudoterminal into the parser. What's here is what
//! Alacritty's own window adds on top of that, minus the drawing -- encoding keys and the mouse,
//! answering the program's questions, resolving colours -- behind functions D can call.

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::{CStr, c_char, c_int, c_void};
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, EventLoopSender, Msg};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::{Config, Osc52, Term, TermMode};
use alacritty_terminal::tty;
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Rgb};

// The C header's constants, which these must match

const EVENT_CONTENT: u32 = 1 << 0;
const EVENT_TITLE: u32 = 1 << 1;
const EVENT_BELL: u32 = 1 << 2;
const EVENT_EXITED: u32 = 1 << 3;
const EVENT_CLIPBOARD: u32 = 1 << 4;

const COLOUR_FOREGROUND: usize = 16;
const COLOUR_BACKGROUND: usize = 17;
const COLOUR_CURSOR: usize = 18;
const COLOUR_COUNT: usize = 19;

const CELL_BOLD: u16 = 1 << 0;
const CELL_ITALIC: u16 = 1 << 1;
const CELL_UNDERLINE: u16 = 1 << 2;
const CELL_DOUBLE_UNDERLINE: u16 = 1 << 3;
const CELL_UNDERCURL: u16 = 1 << 4;
const CELL_DOTTED_UNDERLINE: u16 = 1 << 5;
const CELL_DASHED_UNDERLINE: u16 = 1 << 6;
const CELL_STRIKEOUT: u16 = 1 << 7;
const CELL_WIDE: u16 = 1 << 8;
const CELL_SPACER: u16 = 1 << 9;
const CELL_SELECTED: u16 = 1 << 10;
const CELL_DEFAULT_BG: u16 = 1 << 11;

const CURSOR_HIDDEN: u8 = 0;
const CURSOR_BLOCK: u8 = 1;
const CURSOR_UNDERLINE: u8 = 2;
const CURSOR_BEAM: u8 = 3;
const CURSOR_HOLLOW: u8 = 4;

const MODE_MOUSE: u16 = 1 << 0;
const MODE_ALT_SCREEN: u16 = 1 << 1;

const MOD_SHIFT: u32 = 1 << 0;
const MOD_ALT: u32 = 1 << 1;
const MOD_CONTROL: u32 = 1 << 2;
const MOD_META: u32 = 1 << 3;

const KEY_CHARACTER: u32 = 0;
const KEY_ENTER: u32 = 1;
const KEY_TAB: u32 = 2;
const KEY_BACKSPACE: u32 = 3;
const KEY_ESCAPE: u32 = 4;
const KEY_INSERT: u32 = 5;
const KEY_DELETE: u32 = 6;
const KEY_HOME: u32 = 7;
const KEY_END: u32 = 8;
const KEY_PAGE_UP: u32 = 9;
const KEY_PAGE_DOWN: u32 = 10;
const KEY_UP: u32 = 11;
const KEY_DOWN: u32 = 12;
const KEY_LEFT: u32 = 13;
const KEY_RIGHT: u32 = 14;
const KEY_F1: u32 = 15;
const KEY_F12: u32 = 26;

const MOUSE_PRESS: u32 = 0;
const MOUSE_RELEASE: u32 = 1;
const MOUSE_MOVE: u32 = 2;

const SELECT_BLOCK: u32 = 1;
const SELECT_SEMANTIC: u32 = 2;
const SELECT_LINES: u32 = 3;

#[repr(C)]
pub struct MtOptions {
    program: *const c_char,
    args: *const *const c_char,
    arg_count: usize,
    working_directory: *const c_char,
    env: *const *const c_char,
    env_count: usize,
    columns: u16,
    lines: u16,
    cell_width: u16,
    cell_height: u16,
    scrollback: u32,
    wake: Option<extern "C" fn(*mut c_void)>,
    user: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MtCell {
    c: u32,
    fg: u32,
    bg: u32,
    flags: u16,
    combining_count: u16,
    combining_start: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct MtScreen {
    columns: u16,
    lines: u16,
    cursor_column: i32,
    cursor_line: i32,
    cursor_shape: u8,
    cursor_blinking: u8,
    mode: u16,
    foreground: u32,
    background: u32,
    cursor: u32,
    display_offset: u32,
    history_size: u32,
    combining_count: u32,
}

/// The size of the grid, as alacritty_terminal wants to be told it.
#[derive(Clone, Copy)]
struct Size {
    columns: usize,
    lines: usize,
    cell_width: u16,
    cell_height: u16,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.lines
    }
    fn screen_lines(&self) -> usize {
        self.lines
    }
    fn columns(&self) -> usize {
        self.columns
    }
}

impl Size {
    fn window(&self) -> WindowSize {
        WindowSize {
            num_lines: self.lines as u16,
            num_cols: self.columns as u16,
            cell_width: self.cell_width,
            cell_height: self.cell_height,
        }
    }
}

type ColourFormatter = Arc<dyn Fn(Rgb) -> String + Sync + Send + 'static>;
type SizeFormatter = Arc<dyn Fn(WindowSize) -> String + Sync + Send + 'static>;

/// What the reading thread has to tell the caller's, kept until it asks.
#[derive(Default)]
struct News {
    title: String,
    clipboard: String,
    exit_status: Option<i32>,
    // Questions that need the terminal's state to answer, which the reading thread can't look at:
    // it's holding the terminal's lock whenever it hears them
    colour_requests: Vec<(usize, ColourFormatter)>,
    size_requests: Vec<SizeFormatter>,
}

/// Shared between the terminal's two threads, through its event listener.
struct Shared {
    events: AtomicU32,
    woken: AtomicBool,
    wake: Mutex<Option<(extern "C" fn(*mut c_void), usize)>>, // None once the terminal's going
    news: Mutex<News>,
    sender: OnceLock<EventLoopSender>, // set once the event loop exists, which is after the listener
}

impl Shared {
    fn post(&self, event: u32) {
        self.events.fetch_or(event, Ordering::AcqRel);
        if !self.woken.swap(true, Ordering::AcqRel) {
            if let Some((wake, user)) = *self.wake.lock().unwrap() {
                wake(user as *mut c_void);
            }
        }
    }

    fn send(&self, bytes: Cow<'static, [u8]>) {
        if let Some(sender) = self.sender.get() {
            let _ = sender.send(Msg::Input(bytes));
        }
    }
}

#[derive(Clone)]
struct Listener(Arc<Shared>);

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        let shared = &self.0;
        match event {
            Event::Wakeup | Event::MouseCursorDirty | Event::CursorBlinkingChange => shared.post(EVENT_CONTENT),
            Event::Title(title) => {
                shared.news.lock().unwrap().title = title;
                shared.post(EVENT_TITLE);
            },
            Event::ResetTitle => {
                shared.news.lock().unwrap().title.clear();
                shared.post(EVENT_TITLE);
            },
            Event::Bell => shared.post(EVENT_BELL),
            Event::ClipboardStore(_, text) => {
                shared.news.lock().unwrap().clipboard = text;
                shared.post(EVENT_CLIPBOARD);
            },
            Event::PtyWrite(text) => shared.send(Cow::Owned(text.into_bytes())),
            Event::ColorRequest(index, format) => {
                shared.news.lock().unwrap().colour_requests.push((index, format));
                shared.post(EVENT_CONTENT);
            },
            Event::TextAreaSizeRequest(format) => {
                shared.news.lock().unwrap().size_requests.push(format);
                shared.post(EVENT_CONTENT);
            },
            Event::ChildExit(status) => {
                let code = status.code().unwrap_or_else(|| -status.signal().unwrap_or(0));
                shared.news.lock().unwrap().exit_status = Some(code);
                shared.post(EVENT_EXITED);
            },
            Event::Exit => shared.post(EVENT_EXITED),
            // Reading the clipboard isn't allowed (see Osc52::OnlyCopy), so this never comes
            Event::ClipboardLoad(..) => {},
        }
    }
}

pub struct MtTerminal {
    term: Arc<FairMutex<Term<Listener>>>,
    shared: Arc<Shared>,
    sender: EventLoopSender,
    thread: Option<JoinHandle<()>>,
    size: Size,
    colours: [Rgb; COLOUR_COUNT],
    exited: bool,
}

/// Tango's palette, which GNOME Terminal starts with, on a dark background.
const DEFAULT_COLOURS: [u32; COLOUR_COUNT] = [
    0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
    0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec,
    0xd3d7cf, 0x1e1e1e, 0xd3d7cf,
];

fn rgb(c: u32) -> Rgb {
    Rgb { r: (c >> 16) as u8, g: (c >> 8) as u8, b: c as u8 }
}

fn packed(c: Rgb) -> u32 {
    (c.r as u32) << 16 | (c.g as u32) << 8 | c.b as u32
}

fn dim(c: Rgb) -> Rgb {
    // As Alacritty dims: to two thirds
    Rgb { r: (c.r as u32 * 2 / 3) as u8, g: (c.g as u32 * 2 / 3) as u8, b: (c.b as u32 * 2 / 3) as u8 }
}

fn mix(fg: Rgb, bg: Rgb) -> Rgb {
    let third = |f: u8, b: u8| ((f as u32 * 2 + b as u32) / 3) as u8;
    Rgb { r: third(fg.r, bg.r), g: third(fg.g, bg.g), b: third(fg.b, bg.b) }
}

unsafe fn string(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    }
}

unsafe fn strings(p: *const *const c_char, count: usize) -> Vec<String> {
    if p.is_null() {
        return Vec::new();
    }
    (0..count).filter_map(|i| unsafe { string(*p.add(i)) }).collect()
}

/// Copies `text` into the caller's buffer, as much as fits, and returns its whole length.
unsafe fn copy_out(text: &str, buffer: *mut c_char, size: usize) -> usize {
    if !buffer.is_null() {
        let n = text.len().min(size);
        unsafe { std::ptr::copy_nonoverlapping(text.as_ptr(), buffer as *mut u8, n) };
    }
    text.len()
}

fn write_error(message: &str, error: *mut c_char, size: usize) {
    if error.is_null() || size == 0 {
        return;
    }
    let n = message.len().min(size - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), error as *mut u8, n);
        *error.add(n) = 0;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_new(
    options: *const MtOptions,
    error: *mut c_char,
    error_size: usize,
) -> *mut MtTerminal {
    let Some(options) = (unsafe { options.as_ref() }) else {
        write_error("no options", error, error_size);
        return std::ptr::null_mut();
    };
    match unsafe { start(options) } {
        Ok(terminal) => Box::into_raw(Box::new(terminal)),
        Err(message) => {
            write_error(&message, error, error_size);
            std::ptr::null_mut()
        },
    }
}

unsafe fn start(options: &MtOptions) -> Result<MtTerminal, String> {
    let size = Size {
        columns: (options.columns as usize).max(2),
        lines: (options.lines as usize).max(1),
        cell_width: options.cell_width.max(1),
        cell_height: options.cell_height.max(1),
    };

    // TERM and COLORTERM go to the program rather than into this process's environment, which is
    // where tty::setup_env() would put them, and which isn't safe to change with other threads running
    let mut env = HashMap::new();
    env.insert("TERM".to_owned(), "xterm-256color".to_owned());
    env.insert("COLORTERM".to_owned(), "truecolor".to_owned());
    for pair in unsafe { strings(options.env, options.env_count) } {
        if let Some((name, value)) = pair.split_once('=') {
            env.insert(name.to_owned(), value.to_owned());
        }
    }
    let shell = unsafe { string(options.program) }
        .map(|program| tty::Shell::new(program, unsafe { strings(options.args, options.arg_count) }));
    let pty_options = tty::Options {
        shell,
        working_directory: unsafe { string(options.working_directory) }.map(PathBuf::from),
        drain_on_exit: true,
        env,
    };

    let config = Config {
        scrolling_history: options.scrollback as usize,
        // Copying is safe to allow, reading isn't: any program could read the clipboard otherwise
        osc52: Osc52::OnlyCopy,
        kitty_keyboard: false,
        ..Config::default()
    };

    let shared = Arc::new(Shared {
        events: AtomicU32::new(0),
        woken: AtomicBool::new(false),
        wake: Mutex::new(options.wake.map(|w| (w, options.user as usize))),
        news: Mutex::new(News::default()),
        sender: OnceLock::new(),
    });
    let listener = Listener(shared.clone());
    let term = Arc::new(FairMutex::new(Term::new(config, &size, listener.clone())));

    let pty = tty::new(&pty_options, size.window(), 0).map_err(|e| e.to_string())?;
    let event_loop = EventLoop::new(term.clone(), listener, pty, true, false).map_err(|e| e.to_string())?;
    let sender = event_loop.channel();
    let _ = shared.sender.set(sender.clone());
    let reader = event_loop.spawn();
    // What the thread hands back is the loop and its state, which only matter to a caller that
    // wants to run it again; joining is only to know it's finished
    let thread = std::thread::Builder::new()
        .name("terminal reaper".into())
        .spawn(move || {
            let _ = reader.join();
        })
        .map_err(|e| e.to_string())?;

    let mut colours = [Rgb::default(); COLOUR_COUNT];
    for (i, c) in DEFAULT_COLOURS.iter().enumerate() {
        colours[i] = rgb(*c);
    }

    Ok(MtTerminal { term, shared, sender, thread: Some(thread), size, colours, exited: false })
}

macro_rules! terminal {
    ($p:expr, $default:expr) => {
        match unsafe { $p.as_mut() } {
            Some(t) => t,
            None => return $default,
        }
    };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_free(terminal: *mut MtTerminal) {
    if terminal.is_null() {
        return;
    }
    let mut terminal = unsafe { Box::from_raw(terminal) };
    *terminal.shared.wake.lock().unwrap() = None;
    let _ = terminal.sender.send(Msg::Shutdown);
    // Not joined: shutting down drops the pseudoterminal, which hangs up on the program and then
    // waits for it to exit, and a program that ignores the hangup would hold up the caller's
    // thread. The reaper thread waits instead.
    terminal.thread.take();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_set_colours(terminal: *mut MtTerminal, colours: *const u32, count: usize) {
    let t = terminal!(terminal, ());
    if colours.is_null() {
        return;
    }
    for i in 0..count.min(COLOUR_COUNT) {
        t.colours[i] = rgb(unsafe { *colours.add(i) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_resize(
    terminal: *mut MtTerminal,
    columns: u16,
    lines: u16,
    cell_width: u16,
    cell_height: u16,
) {
    let t = terminal!(terminal, ());
    let size = Size {
        columns: (columns as usize).max(2),
        lines: (lines as usize).max(1),
        cell_width: cell_width.max(1),
        cell_height: cell_height.max(1),
    };
    let unchanged = size.columns == t.size.columns
        && size.lines == t.size.lines
        && size.cell_width == t.size.cell_width
        && size.cell_height == t.size.cell_height;
    if unchanged {
        return;
    }
    t.size = size;
    t.term.lock().resize(size);
    let _ = t.sender.send(Msg::Resize(size.window()));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_take_events(terminal: *mut MtTerminal) -> u32 {
    let t = terminal!(terminal, 0);
    // Cleared before the events are read, so anything arriving from here on wakes again
    t.shared.woken.store(false, Ordering::Release);
    let events = t.shared.events.swap(0, Ordering::AcqRel);

    let (colour_requests, size_requests) = {
        let mut news = t.shared.news.lock().unwrap();
        if news.exit_status.is_some() {
            t.exited = true;
        }
        (std::mem::take(&mut news.colour_requests), std::mem::take(&mut news.size_requests))
    };
    if !colour_requests.is_empty() {
        let term = t.term.lock();
        for (index, format) in colour_requests {
            let colour = resolve_index(index, term.colors(), &t.colours);
            t.shared.send(Cow::Owned(format(colour).into_bytes()));
        }
    }
    for format in size_requests {
        t.shared.send(Cow::Owned(format(t.size.window()).into_bytes()));
    }
    events
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_title(terminal: *mut MtTerminal, buffer: *mut c_char, size: usize) -> usize {
    let t = terminal!(terminal, 0);
    let news = t.shared.news.lock().unwrap();
    unsafe { copy_out(&news.title, buffer, size) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_clipboard(terminal: *mut MtTerminal, buffer: *mut c_char, size: usize) -> usize {
    let t = terminal!(terminal, 0);
    let news = t.shared.news.lock().unwrap();
    unsafe { copy_out(&news.clipboard, buffer, size) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_exit_status(terminal: *mut MtTerminal, status: *mut c_int) -> c_int {
    let t = terminal!(terminal, 0);
    match t.shared.news.lock().unwrap().exit_status {
        Some(code) => {
            if !status.is_null() {
                unsafe { *status = code };
            }
            1
        },
        None => 0,
    }
}

/// Colour `index` of the terminal's 269, as the program set it or else as the caller did.
fn resolve_index(index: usize, overrides: &Colors, colours: &[Rgb; COLOUR_COUNT]) -> Rgb {
    if index < alacritty_terminal::term::color::COUNT {
        if let Some(c) = overrides[index] {
            return c;
        }
    }
    match index {
        0..16 => colours[index],
        16..232 => {
            // The 6x6x6 cube
            const STEPS: [u8; 6] = [0, 95, 135, 175, 215, 255];
            let i = index - 16;
            Rgb { r: STEPS[i / 36], g: STEPS[i / 6 % 6], b: STEPS[i % 6] }
        },
        232..256 => {
            let v = (8 + 10 * (index - 232)) as u8;
            Rgb { r: v, g: v, b: v }
        },
        256 => colours[COLOUR_FOREGROUND],
        257 => colours[COLOUR_BACKGROUND],
        258 => colours[COLOUR_CURSOR],
        259..267 => dim(resolve_index(index - 259, overrides, colours)),
        267 => resolve_index(256, overrides, colours),
        268 => dim(resolve_index(256, overrides, colours)),
        _ => colours[COLOUR_FOREGROUND],
    }
}

fn resolve(colour: Color, overrides: &Colors, colours: &[Rgb; COLOUR_COUNT]) -> Rgb {
    match colour {
        Color::Spec(c) => c,
        Color::Indexed(i) => resolve_index(i as usize, overrides, colours),
        Color::Named(n) => resolve_index(n as usize, overrides, colours),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_screen(
    terminal: *mut MtTerminal,
    screen: *mut MtScreen,
    cells: *mut MtCell,
    cell_capacity: usize,
    combining: *mut u32,
    combining_capacity: usize,
) -> c_int {
    let t = terminal!(terminal, 1);
    let Some(screen) = (unsafe { screen.as_mut() }) else {
        return 1;
    };
    let term = t.term.lock();
    let content = term.renderable_content();
    let overrides = content.colors;
    let columns = term.columns();
    let lines = term.screen_lines();
    let offset = content.display_offset;

    *screen = MtScreen {
        columns: columns as u16,
        lines: lines as u16,
        mode: if content.mode.intersects(TermMode::MOUSE_MODE) { MODE_MOUSE } else { 0 }
            | if content.mode.contains(TermMode::ALT_SCREEN) { MODE_ALT_SCREEN } else { 0 },
        foreground: packed(resolve_index(256, overrides, &t.colours)),
        background: packed(resolve_index(257, overrides, &t.colours)),
        cursor: packed(resolve_index(258, overrides, &t.colours)),
        display_offset: offset as u32,
        history_size: term.history_size() as u32,
        ..MtScreen::default()
    };
    let cursor = content.cursor;
    screen.cursor_column = cursor.point.column.0 as i32;
    screen.cursor_line = cursor.point.line.0 + offset as i32;
    screen.cursor_shape = match cursor.shape {
        CursorShape::Hidden => CURSOR_HIDDEN,
        CursorShape::Block => CURSOR_BLOCK,
        CursorShape::Underline => CURSOR_UNDERLINE,
        CursorShape::Beam => CURSOR_BEAM,
        CursorShape::HollowBlock => CURSOR_HOLLOW,
    };
    screen.cursor_blinking = term.cursor_style().blinking as u8;

    let fits = !cells.is_null() && cell_capacity >= columns * lines;
    let mut combined = 0usize;
    let selection = content.selection;
    for indexed in content.display_iter {
        let cell = indexed.cell;
        let point = indexed.point;
        let zerowidth = cell.zerowidth().unwrap_or(&[]);
        let start = combined;
        combined += zerowidth.len();
        if !fits {
            continue;
        }
        let Some(line) = usize::try_from(point.line.0 + offset as i32).ok().filter(|l| *l < lines) else {
            continue;
        };

        let flags = cell.flags;
        let mut fg = resolve(cell.fg, overrides, &t.colours);
        let mut bg = resolve(cell.bg, overrides, &t.colours);
        let mut default_bg = cell.bg == Color::Named(NamedColor::Background);
        if flags.contains(Flags::DIM) {
            // A third of the way to the background, which on a dark one is Alacritty's two thirds
            // of the colour, and on a light one fades it rather than darkening it
            fg = mix(fg, bg);
        }
        if flags.contains(Flags::INVERSE) {
            std::mem::swap(&mut fg, &mut bg);
            default_bg = false;
        }
        if flags.contains(Flags::HIDDEN) {
            fg = bg;
        }

        let mut out = 0u16;
        for (from, to) in [
            (Flags::BOLD, CELL_BOLD),
            (Flags::ITALIC, CELL_ITALIC),
            (Flags::UNDERLINE, CELL_UNDERLINE),
            (Flags::DOUBLE_UNDERLINE, CELL_DOUBLE_UNDERLINE),
            (Flags::UNDERCURL, CELL_UNDERCURL),
            (Flags::DOTTED_UNDERLINE, CELL_DOTTED_UNDERLINE),
            (Flags::DASHED_UNDERLINE, CELL_DASHED_UNDERLINE),
            (Flags::STRIKEOUT, CELL_STRIKEOUT),
            (Flags::WIDE_CHAR, CELL_WIDE),
        ] {
            if flags.contains(from) {
                out |= to;
            }
        }
        if flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
            out |= CELL_SPACER;
        }
        if default_bg {
            out |= CELL_DEFAULT_BG;
        }
        if selection.is_some_and(|s| s.contains_cell(&indexed, cursor.point, cursor.shape)) {
            out |= CELL_SELECTED;
        }

        let mut written = 0u16;
        if !combining.is_null() && combined <= combining_capacity {
            for (i, c) in zerowidth.iter().enumerate() {
                unsafe { *combining.add(start + i) = *c as u32 };
            }
            written = zerowidth.len() as u16;
        }
        unsafe {
            *cells.add(line * columns + point.column.0) = MtCell {
                c: cell.c as u32,
                fg: packed(fg),
                bg: packed(bg),
                flags: out,
                combining_count: written,
                combining_start: start as u32,
            };
        }
    }
    screen.combining_count = combined as u32;
    if fits && (combined == 0 || (!combining.is_null() && combined <= combining_capacity)) { 0 } else { 1 }
}

impl MtTerminal {
    fn send(&self, bytes: Vec<u8>) -> c_int {
        if bytes.is_empty() || self.exited {
            return 0;
        }
        let _ = self.sender.send(Msg::Input(Cow::Owned(bytes)));
        1
    }

    fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }

    /// Typing goes to the bottom, where the program's waiting for it, as Alacritty does.
    fn typed(&self) {
        let mut term = self.term.lock();
        if term.grid().display_offset() != 0 {
            term.scroll_display(Scroll::Bottom);
            self.shared.post(EVENT_CONTENT);
        }
    }

    /// A point in the view as a point in the grid, which counts lines from the top of the screen.
    fn point(&self, term: &Term<Listener>, column: i32, line: i32) -> Point {
        let column = column.clamp(0, term.columns() as i32 - 1) as usize;
        let line = line.clamp(0, term.screen_lines() as i32 - 1) - term.grid().display_offset() as i32;
        Point::new(Line(line), Column(column))
    }
}

/// xterm's number for a set of modifiers, in sequences like CSI 1 ; m A.
fn modifier_code(mods: u32) -> u32 {
    1 + if mods & MOD_SHIFT != 0 { 1 } else { 0 }
        + if mods & MOD_ALT != 0 { 2 } else { 0 }
        + if mods & MOD_CONTROL != 0 { 4 } else { 0 }
        + if mods & MOD_META != 0 { 8 } else { 0 }
}

/// What a key sends, as xterm does, and Alacritty by default.
fn encode_key(key: u32, codepoint: u32, mods: u32, mode: TermMode) -> Vec<u8> {
    let alt = mods & MOD_ALT != 0;
    let control = mods & MOD_CONTROL != 0;
    let shift = mods & MOD_SHIFT != 0;
    let modified = mods & (MOD_SHIFT | MOD_ALT | MOD_CONTROL | MOD_META) != 0;
    let app_cursor = mode.contains(TermMode::APP_CURSOR);
    let escaped = |mut bytes: Vec<u8>| {
        if alt {
            bytes.insert(0, 0x1b);
        }
        bytes
    };

    // CSI 1 ; m X for a modified cursor key, SS3 X in application cursor mode, CSI X otherwise
    let cursor = |letter: u8| -> Vec<u8> {
        if modified {
            format!("\x1b[1;{}{}", modifier_code(mods), letter as char).into_bytes()
        } else if app_cursor {
            vec![0x1b, b'O', letter]
        } else {
            vec![0x1b, b'[', letter]
        }
    };
    // CSI n ~, or CSI n ; m ~ modified
    let tilde = |n: u32| -> Vec<u8> {
        if modified { format!("\x1b[{};{}~", n, modifier_code(mods)) } else { format!("\x1b[{}~", n) }.into_bytes()
    };

    match key {
        KEY_ENTER => escaped(vec![b'\r']),
        KEY_TAB if shift => b"\x1b[Z".to_vec(),
        KEY_TAB => escaped(vec![b'\t']),
        KEY_BACKSPACE => escaped(vec![if control { 0x08 } else { 0x7f }]),
        KEY_ESCAPE => escaped(vec![0x1b]),
        KEY_UP => cursor(b'A'),
        KEY_DOWN => cursor(b'B'),
        KEY_RIGHT => cursor(b'C'),
        KEY_LEFT => cursor(b'D'),
        KEY_HOME => cursor(b'H'),
        KEY_END => cursor(b'F'),
        KEY_INSERT => tilde(2),
        KEY_DELETE => tilde(3),
        KEY_PAGE_UP => tilde(5),
        KEY_PAGE_DOWN => tilde(6),
        KEY_F1..=KEY_F12 => {
            let n = key - KEY_F1;
            if n < 4 {
                let letter = b'P' + n as u8;
                if modified {
                    format!("\x1b[1;{}{}", modifier_code(mods), letter as char).into_bytes()
                } else {
                    vec![0x1b, b'O', letter]
                }
            } else {
                const CODES: [u32; 8] = [15, 17, 18, 19, 20, 21, 23, 24];
                tilde(CODES[(n - 4) as usize])
            }
        },
        KEY_CHARACTER => {
            let Some(c) = char::from_u32(codepoint) else {
                return Vec::new();
            };
            if control {
                let code = match c.to_ascii_lowercase() {
                    'a'..='z' => Some(c.to_ascii_lowercase() as u8 - b'a' + 1),
                    '@' | ' ' | '2' => Some(0),
                    '[' | '3' => Some(0x1b),
                    '\\' | '4' => Some(0x1c),
                    ']' | '5' => Some(0x1d),
                    '^' | '6' => Some(0x1e),
                    '_' | '-' | '7' | '/' => Some(0x1f),
                    '8' | '?' => Some(0x7f),
                    _ => None,
                };
                match code {
                    Some(code) => escaped(vec![code]),
                    None => Vec::new(),
                }
            } else if alt {
                let c = if shift { c.to_uppercase().next().unwrap_or(c) } else { c };
                escaped(c.to_string().into_bytes())
            } else {
                c.to_string().into_bytes()
            }
        },
        _ => Vec::new(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_key(terminal: *mut MtTerminal, key: u32, codepoint: u32, mods: u32) -> c_int {
    let t = terminal!(terminal, 0);
    let bytes = encode_key(key, codepoint, mods, t.mode());
    if bytes.is_empty() {
        return 0;
    }
    t.typed();
    t.send(bytes)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_input(terminal: *mut MtTerminal, utf8: *const c_char, length: usize) -> c_int {
    let t = terminal!(terminal, 0);
    if utf8.is_null() || length == 0 {
        return 0;
    }
    let bytes = unsafe { std::slice::from_raw_parts(utf8 as *const u8, length) }.to_vec();
    t.typed();
    t.send(bytes)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_paste(terminal: *mut MtTerminal, utf8: *const c_char, length: usize) -> c_int {
    let t = terminal!(terminal, 0);
    if utf8.is_null() || length == 0 {
        return 0;
    }
    let text = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(utf8 as *const u8, length) });
    let bytes = if t.mode().contains(TermMode::BRACKETED_PASTE) {
        // Without escapes in it, so that the text can't end the bracket early and run as typed
        let mut bytes = b"\x1b[200~".to_vec();
        bytes.extend(text.replace('\x1b', "").bytes());
        bytes.extend(b"\x1b[201~");
        bytes
    } else {
        // Lines end as Enter ends them
        text.replace("\r\n", "\r").replace('\n', "\r").into_bytes()
    };
    t.typed();
    t.send(bytes)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_focus(terminal: *mut MtTerminal, focused: c_int) -> c_int {
    let t = terminal!(terminal, 0);
    let report = {
        let mut term = t.term.lock();
        term.is_focused = focused != 0;
        term.mode().contains(TermMode::FOCUS_IN_OUT)
    };
    if report { t.send(if focused != 0 { b"\x1b[I".to_vec() } else { b"\x1b[O".to_vec() }) } else { 0 }
}

/// A mouse report, in the encoding the program asked for: SGR's, or the original X10 one.
fn mouse_report(mode: TermMode, code: u32, pressed: bool, column: i32, line: i32, mods: u32) -> Vec<u8> {
    let mut code = code;
    if mods & MOD_SHIFT != 0 {
        code += 4;
    }
    if mods & (MOD_ALT | MOD_META) != 0 {
        code += 8;
    }
    if mods & MOD_CONTROL != 0 {
        code += 16;
    }
    let (column, line) = (column.max(0) as u32 + 1, line.max(0) as u32 + 1);
    if mode.contains(TermMode::SGR_MOUSE) {
        format!("\x1b[<{};{};{}{}", code, column, line, if pressed { 'M' } else { 'm' }).into_bytes()
    } else {
        // The original encoding can't say which button came up, or reach past column 223
        let code = if pressed { code } else { 3 + (code & !3) };
        if column > 223 || line > 223 {
            return Vec::new();
        }
        vec![0x1b, b'[', b'M', 32 + code as u8, 32 + column as u8, 32 + line as u8]
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_mouse(
    terminal: *mut MtTerminal,
    kind: u32,
    button: u32,
    column: i32,
    line: i32,
    mods: u32,
) -> c_int {
    let t = terminal!(terminal, 0);
    let mode = t.mode();
    if !mode.intersects(TermMode::MOUSE_MODE) {
        return 0;
    }
    let bytes = match kind {
        MOUSE_PRESS if button < 3 => mouse_report(mode, button, true, column, line, mods),
        MOUSE_RELEASE if button < 3 => mouse_report(mode, button, false, column, line, mods),
        MOUSE_MOVE => {
            let dragging = button < 3;
            if mode.contains(TermMode::MOUSE_MOTION) || (dragging && mode.contains(TermMode::MOUSE_DRAG)) {
                mouse_report(mode, 32 + button.min(3), true, column, line, mods)
            } else {
                return 0;
            }
        },
        _ => return 0,
    };
    t.send(bytes)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_wheel(
    terminal: *mut MtTerminal,
    lines: i32,
    column: i32,
    line: i32,
    mods: u32,
) -> c_int {
    let t = terminal!(terminal, 0);
    if lines == 0 {
        return 0;
    }
    let mode = t.mode();
    if mode.intersects(TermMode::MOUSE_MODE) && mods & MOD_SHIFT == 0 {
        let code = if lines > 0 { 64 } else { 65 };
        let mut bytes = Vec::new();
        for _ in 0..lines.unsigned_abs() {
            bytes.extend(mouse_report(mode, code, true, column, line, mods));
        }
        return t.send(bytes);
    }
    if mode.contains(TermMode::ALT_SCREEN | TermMode::ALTERNATE_SCROLL) && mods & MOD_SHIFT == 0 {
        // A full-screen program has no history: the wheel moves through what it shows instead
        let key = if mode.contains(TermMode::APP_CURSOR) { b'O' } else { b'[' };
        let letter = if lines > 0 { b'A' } else { b'B' };
        let mut bytes = Vec::new();
        for _ in 0..lines.unsigned_abs() {
            bytes.extend([0x1b, key, letter]);
        }
        return t.send(bytes);
    }
    t.term.lock().scroll_display(Scroll::Delta(lines));
    t.shared.post(EVENT_CONTENT);
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_scroll(terminal: *mut MtTerminal, lines: i32) {
    let t = terminal!(terminal, ());
    t.term.lock().scroll_display(Scroll::Delta(lines));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_scroll_to_bottom(terminal: *mut MtTerminal) {
    let t = terminal!(terminal, ());
    t.term.lock().scroll_display(Scroll::Bottom);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_select_start(
    terminal: *mut MtTerminal,
    kind: u32,
    column: i32,
    line: i32,
    right_half: c_int,
) {
    let t = terminal!(terminal, ());
    let mut term = t.term.lock();
    let point = t.point(&term, column, line);
    let ty = match kind {
        SELECT_BLOCK => SelectionType::Block,
        SELECT_SEMANTIC => SelectionType::Semantic,
        SELECT_LINES => SelectionType::Lines,
        _ => SelectionType::Simple,
    };
    let side = if right_half != 0 { Side::Right } else { Side::Left };
    term.selection = Some(Selection::new(ty, point, side));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_select_update(terminal: *mut MtTerminal, column: i32, line: i32, right_half: c_int) {
    let t = terminal!(terminal, ());
    let mut term = t.term.lock();
    let point = t.point(&term, column, line);
    let side = if right_half != 0 { Side::Right } else { Side::Left };
    if let Some(selection) = term.selection.as_mut() {
        selection.update(point, side);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_select_all(terminal: *mut MtTerminal) {
    let t = terminal!(terminal, ());
    let mut term = t.term.lock();
    let start = Point::new(term.topmost_line(), Column(0));
    let end = Point::new(term.bottommost_line(), term.last_column());
    let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
    selection.update(end, Side::Right);
    term.selection = Some(selection);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_select_clear(terminal: *mut MtTerminal) {
    let t = terminal!(terminal, ());
    t.term.lock().selection = None;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mt_terminal_selection_text(terminal: *mut MtTerminal, buffer: *mut c_char, size: usize) -> usize {
    let t = terminal!(terminal, 0);
    let text = t.term.lock().selection_to_string().unwrap_or_default();
    unsafe { copy_out(&text, buffer, size) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::time::{Duration, Instant};

    extern "C" fn wake(user: *mut c_void) {
        unsafe { &*(user as *const AtomicU32) }.fetch_add(1, Ordering::SeqCst);
    }

    struct Running {
        t: *mut MtTerminal,
        wakes: Box<AtomicU32>,
    }

    impl Drop for Running {
        fn drop(&mut self) {
            unsafe { mt_terminal_free(self.t) };
        }
    }

    fn run(program: &str, args: &[&str]) -> Running {
        let program = CString::new(program).unwrap();
        let args: Vec<CString> = args.iter().map(|a| CString::new(*a).unwrap()).collect();
        let arg_ptrs: Vec<*const c_char> = args.iter().map(|a| a.as_ptr()).collect();
        let wakes = Box::new(AtomicU32::new(0));
        let options = MtOptions {
            program: program.as_ptr(),
            args: arg_ptrs.as_ptr(),
            arg_count: arg_ptrs.len(),
            working_directory: std::ptr::null(),
            env: std::ptr::null(),
            env_count: 0,
            columns: 20,
            lines: 5,
            cell_width: 8,
            cell_height: 16,
            scrollback: 100,
            wake: Some(wake),
            user: &*wakes as *const AtomicU32 as *mut c_void,
        };
        let mut error = [0 as c_char; 256];
        let t = unsafe { mt_terminal_new(&options, error.as_mut_ptr(), error.len()) };
        assert!(!t.is_null(), "{:?}", unsafe { CStr::from_ptr(error.as_ptr()) });
        Running { t, wakes }
    }

    /// Waits until the program has exited, taking events as a caller would.
    fn wait_exit(r: &Running) -> u32 {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut all = 0;
        while Instant::now() < deadline {
            all |= unsafe { mt_terminal_take_events(r.t) };
            if all & EVENT_EXITED != 0 {
                return all;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the program didn't exit");
    }

    fn screen(r: &Running) -> (MtScreen, Vec<MtCell>, Vec<u32>) {
        let mut screen = MtScreen::default();
        let mut cells = Vec::new();
        let mut combining = Vec::new();
        loop {
            let ok = unsafe {
                mt_terminal_screen(r.t, &mut screen, cells.as_mut_ptr(), cells.len(), combining.as_mut_ptr(),
                                   combining.len())
            };
            if ok == 0 {
                return (screen, cells, combining);
            }
            cells.resize(screen.columns as usize * screen.lines as usize, MtCell::default());
            combining.resize(screen.combining_count as usize, 0);
        }
    }

    fn line_text(cells: &[MtCell], columns: usize, line: usize) -> String {
        cells[line * columns..(line + 1) * columns]
            .iter()
            .filter(|c| c.flags & CELL_SPACER == 0)
            .map(|c| char::from_u32(c.c).unwrap())
            .collect::<String>()
            .trim_end()
            .to_owned()
    }

    #[test]
    fn output_reaches_the_grid_with_its_colours() {
        let r = run("/bin/sh", &["-c", "printf 'hello\\n\\033[31mred\\033[0m e\\314\\201 \\346\\274\\242'"]);
        let events = wait_exit(&r);
        assert!(events & EVENT_CONTENT != 0);
        assert!(r.wakes.load(Ordering::SeqCst) >= 1, "woken");
        let mut status = -1;
        assert_eq!(unsafe { mt_terminal_exit_status(r.t, &mut status) }, 1);
        assert_eq!(status, 0);

        let (screen, cells, combining) = screen(&r);
        assert_eq!((screen.columns, screen.lines), (20, 5));
        assert_eq!(line_text(&cells, 20, 0), "hello");
        assert_eq!(line_text(&cells, 20, 1), "red e \u{6f22}");
        let red = cells[20];
        assert_eq!(red.fg, 0xcc0000, "the palette's red");
        assert!(red.flags & CELL_DEFAULT_BG != 0);
        assert_eq!(cells[20 + 3].fg, 0xd3d7cf, "and back to the foreground");

        let e = cells[20 + 4];
        assert_eq!(e.combining_count, 1, "the accent combined with the e");
        assert_eq!(combining[e.combining_start as usize], 0x301);
        assert!(cells[20 + 6].flags & CELL_WIDE != 0, "a CJK character is wide");
        assert!(cells[20 + 7].flags & CELL_SPACER != 0, "and followed by a spacer");
    }

    #[test]
    fn palette_and_256_colours_and_inverse() {
        let r = run("/bin/sh", &["-c", "printf '\\033[38;5;196mA\\033[0m\\033[7mB\\033[0m\\033[38;2;1;2;3mC'"]);
        let colours: Vec<u32> = (0..COLOUR_COUNT as u32).map(|i| i * 0x010101).collect();
        unsafe { mt_terminal_set_colours(r.t, colours.as_ptr(), colours.len()) };
        wait_exit(&r);
        let (screen, cells, _) = screen(&r);
        assert_eq!(screen.background, 17 * 0x010101);
        assert_eq!(cells[0].fg, 0xff0000, "cube red");
        assert_eq!(cells[1].fg, 17 * 0x010101, "inverse: the background as text");
        assert_eq!(cells[1].bg, 16 * 0x010101, "and the text as background");
        assert!(cells[1].flags & CELL_DEFAULT_BG == 0);
        assert_eq!(cells[2].fg, 0x010203);
    }

    #[test]
    fn input_reaches_the_program() {
        let r = run("/bin/sh", &["-c", "read line; printf 'got:%s' \"$line\""]);
        let text = b"typed";
        unsafe { mt_terminal_input(r.t, text.as_ptr() as *const c_char, text.len()) };
        unsafe { mt_terminal_key(r.t, KEY_ENTER, 0, 0) };
        wait_exit(&r);
        let (_, cells, _) = screen(&r);
        let all: String = (0..5).map(|l| line_text(&cells, 20, l)).collect::<Vec<_>>().join("\n");
        assert!(all.contains("got:typed"), "{all}");
    }

    #[test]
    fn selection_copies_text() {
        let r = run("/bin/sh", &["-c", "printf 'one two three'"]);
        wait_exit(&r);
        unsafe { mt_terminal_select_start(r.t, SELECT_SEMANTIC, 5, 0, 0) };
        let mut buffer = [0 as c_char; 64];
        let n = unsafe { mt_terminal_selection_text(r.t, buffer.as_mut_ptr(), buffer.len()) };
        let text = unsafe { std::slice::from_raw_parts(buffer.as_ptr() as *const u8, n) };
        assert_eq!(text, b"two");
        let (_, cells, _) = screen(&r);
        assert!(cells[4].flags & CELL_SELECTED != 0 && cells[3].flags & CELL_SELECTED == 0);
    }

    #[test]
    fn keys_encode_as_xterm_does() {
        let normal = TermMode::default();
        assert_eq!(encode_key(KEY_UP, 0, 0, normal), b"\x1b[A");
        assert_eq!(encode_key(KEY_UP, 0, 0, normal | TermMode::APP_CURSOR), b"\x1bOA");
        assert_eq!(encode_key(KEY_RIGHT, 0, MOD_CONTROL, normal), b"\x1b[1;5C");
        assert_eq!(encode_key(KEY_DELETE, 0, 0, normal), b"\x1b[3~");
        assert_eq!(encode_key(KEY_F5, 0, MOD_SHIFT, normal), b"\x1b[15;2~");
        assert_eq!(encode_key(KEY_F1, 0, 0, normal), b"\x1bOP");
        assert_eq!(encode_key(KEY_CHARACTER, 'c' as u32, MOD_CONTROL, normal), b"\x03");
        assert_eq!(encode_key(KEY_CHARACTER, 'b' as u32, MOD_ALT, normal), b"\x1bb");
        assert_eq!(encode_key(KEY_TAB, 0, MOD_SHIFT, normal), b"\x1b[Z");
        assert_eq!(encode_key(KEY_BACKSPACE, 0, 0, normal), b"\x7f");
    }

    const KEY_F5: u32 = KEY_F1 + 4;

    #[test]
    fn mouse_reports_in_both_encodings() {
        let sgr = TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE;
        assert_eq!(mouse_report(sgr, 0, true, 2, 3, 0), b"\x1b[<0;3;4M");
        assert_eq!(mouse_report(sgr, 0, false, 2, 3, MOD_CONTROL), b"\x1b[<16;3;4m");
        let x10 = TermMode::MOUSE_REPORT_CLICK;
        assert_eq!(mouse_report(x10, 0, true, 0, 0, 0), vec![0x1b, b'[', b'M', 32, 33, 33]);
        assert_eq!(mouse_report(x10, 2, false, 0, 0, 0), vec![0x1b, b'[', b'M', 35, 33, 33]);
    }
}
