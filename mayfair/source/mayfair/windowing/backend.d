module mayfair.windowing.backend;

import core.stdc.string : strcmp;
import sdl;
import mayfair.widgets.scene : Scene;

/*
    What a window needs from the desktop that SDL doesn't give it. SDL3 makes windows, reads input,
    sizes, parents and shapes them, and hit tests a title bar Mayfair draws, the same everywhere;
    Window and App do all of that through SDL, and nothing else. What's left differs by desktop,
    and goes through the two interfaces here:

      DesktopBackend  the desktop as a whole: who draws title bars, and what has to be done
                      around SDL starting and making a window for that
      WindowBackend   one window's own: whether it's tiled, moving it by a title bar of ours,
                      and blurring behind it

    Each desktop has its own pair, in a folder of its own -- mayfair.windowing.wayland, for Linux
    and the BSDs, which is the one that matters most -- and the SDL ones below are what a desktop
    gets until it has one: X11, Windows and macOS, for now. There the window manager draws title
    bars, SDL's hit test moves a window by ours, and nothing's tiled or blurred, which is all
    right everywhere and only plainer than it could be.

    Who draws a window's title bar and edges: the desktop should, and Mayfair lets it wherever it
    will. An app can ask for a TitleBar of its own anywhere, to put its own things in it, as macOS
    apps do; then Mayfair draws the bar whatever the desktop would have done. Where the desktop
    won't draw one -- GNOME's Wayland compositor, which leaves every app to draw its own -- Mayfair
    draws a plain one.
*/
interface DesktopBackend
{
    /// A new window's own part, to be opened once SDL has made the window.
    WindowBackend newWindow() nothrow;

nothrow @nogc:
    /// Its name, for traces.
    const(char)* name();

    /// Whether the desktop draws windows' title bars and edges, where they don't ask to draw their
    /// own. Asked before SDL starts, so it's answered without SDL.
    bool decoratesWindows();

    /// Whether a window can be translucent, what's behind it blurred: if so, one asked to be is
    /// made with alpha, which can't be added once it's made.
    bool mayBlur();

    /*
        Called either side of SDL_Init, and of each SDL_CreateWindow: `ownFrame` says whether
        Mayfair's to draw that window's frame, or, for SDL_Init, the main window's. For what has
        to be in place as SDL sets up.
    */
    void beforeSdl(bool ownFrame);
    void afterSdl(bool ownFrame); /// ditto

}

/*
    One window's part of a desktop's backend. Opened once SDL has made the window and a renderer's
    started in it, closed before SDL destroys it. The loop calls it on the UI thread only.
*/
interface WindowBackend
{
nothrow @nogc:
    /// Starts on SDL's `window`; `ownFrame` says whether Mayfair draws its frame.
    void open(SDL_Window* window, bool ownFrame);

    /// Lets go of everything, before SDL destroys the window.
    void close();

    /// SDL's about to hide the window, as it closes.
    void hiding();

    /// Once a turn of the loop, after SDL's handled the window system's events: for whatever
    /// arrives other than through SDL.
    void dispatch();

    /// Whether the window's tiled: snapped to a side, or against another window, where its
    /// frame wants to be flat as a maximised one's is.
    bool tiled();

    /*
        Whether a press on Mayfair's title bar comes to the app, and the move starts only once
        it's a drag, with beginMove(): then a double click can be told from one. If not, SDL's
        hit test hands the press to the window system, which moves the window from it.
    */
    bool movesByDrag();
    bool beginMove(); /// ditto

    /// Whether what's behind the window can be blurred, as of now: a compositor can start or stop.
    bool blurs();

    /// Blurs behind the parts of the window `scene` was last painted with backdrop-blur on, from
    /// the next frame presented. Asked only while blurs() says it can.
    void blurBehind(Scene scene);
}

/*
    The backend for the desktop SDL's about to start on, or, once it has, the one it did. Before,
    it's a guess from the environment, for what has to be decided before SDL starts; SDL can
    always try another driver if the first fails, so it's asked again once it's started.
*/
DesktopBackend chooseDesktop(bool sdlStarted) nothrow
{
    import mayfair.windowing.wayland : WaylandDesktop;
    import mayfair.windowing.wayland.decorations : onWayland;
    bool wayland;
    if (sdlStarted)
    {
        const driver = SDL_GetCurrentVideoDriver();
        wayland = driver && strcmp(driver, "wayland") == 0;
    }
    else
        wayland = onWayland();
    if (wayland)
        return new WaylandDesktop;
    return new SdlDesktop;
}

/// What a desktop with no backend of its own gets: SDL's, and the window manager's title bars.
final class SdlDesktop : DesktopBackend
{
    WindowBackend newWindow() nothrow { return new SdlWindow; }

nothrow @nogc:
    const(char)* name() { return "sdl"; }
    bool decoratesWindows() { return true; }
    bool mayBlur() { return false; }
    void beforeSdl(bool) {}
    void afterSdl(bool) {}
}

/// ditto
final class SdlWindow : WindowBackend
{
nothrow @nogc:
    void open(SDL_Window*, bool) {}
    void close() {}
    void hiding() {}
    void dispatch() {}
    bool tiled() { return false; }
    bool movesByDrag() { return false; }
    bool beginMove() { return false; }
    bool blurs() { return false; }
    void blurBehind(Scene) {}
}
