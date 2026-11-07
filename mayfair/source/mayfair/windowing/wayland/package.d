module mayfair.windowing.wayland;

import core.stdc.string : strcmp;
import sdl;
import mayfair.trace;
import mayfair.widgets.scene : Scene;
import mayfair.windowing.backend;
import mayfair.windowing.wayland.blur : BackgroundBlur;
import mayfair.windowing.wayland.decorations : compositorDecorates;
import mayfair.windowing.wayland.toplevel : TileWatcher, WindowMover;

/*
    The Wayland backend: Linux's desktops, and the BSDs'. What SDL keeps to itself or doesn't do
    -- the press that starts a move, the toplevel's tiled states, the compositor's blur -- is had
    by talking to the compositor on SDL's own connection, in the modules alongside this one.

    The compositor draws title bars if it offers xdg-decoration: KDE's and wlroots-based ones do.
    GNOME's doesn't, and leaves every app to draw its own, which SDL would do through libdecor and
    its GTK plugin: GTK 3 loaded to draw one bar. So there Mayfair draws it, with a TitleBar, and
    libdecor is kept from loading a plugin.
*/
final class WaylandDesktop : DesktopBackend
{
    WindowBackend newWindow() nothrow { return new WaylandWindow; }

nothrow @nogc:
    const(char)* name() { return "wayland"; }

    bool decoratesWindows()
    {
        if (!asked)
        {
            decorates = compositorDecorates();
            asked = true;
        }
        return decorates;
    }

    bool mayBlur() { return true; }

    // libdecor loads its plugins as SDL starts, and looks again as it makes a window: kept from
    // them both times, it draws nothing, and says, twice, that it found none -- what was meant
    void beforeSdl(bool ownFrame)
    {
        if (!ownFrame)
            return;
        keepLibdecorPluginsAway(true);
        quietStderr(true);
    }

    void afterSdl(bool ownFrame)
    {
        if (!ownFrame)
            return;
        quietStderr(false);
        keepLibdecorPluginsAway(false);
    }


private:
    bool asked, decorates;
}

/// A window's part: see WindowBackend.
final class WaylandWindow : WindowBackend
{
nothrow @nogc:
    void open(SDL_Window* window, bool ownFrame)
    {
        this.window = window;
        this.ownFrame = ownFrame;
        auto props = SDL_GetWindowProperties(window);
        auto display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
        if (ownFrame)
            mover.open(display);
        blur.open(display, SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null));
        trace("blur  %s", blur.available ? "the compositor's, behind backdrop-blur".ptr : "none".ptr);
        watchTiling();
    }

    void close()
    {
        blur.close();
        watchTiling(); // so close() doesn't write to a toplevel that's been replaced
        tiles.close(); // before the window, and its xdg_toplevel, go
        mover.close(); // before the window, and SDL's connection, go
        window = null;
    }

    // SDL lets go of the xdg_toplevel as it hides the window, so the tile watcher's to give it
    // its listener back first, while it's there to be given it
    void hiding()
    {
        watchTiling();
        tiles.close();
    }

    void dispatch()
    {
        mover.dispatch();
        blur.dispatch();
        watchTiling(); // still the window's xdg_toplevel?
    }

    bool knowsPosition() { return false; }

    bool tiled()
    {
        watchTiling();
        return tiles.tiled;
    }

    bool movesByDrag() { return mover.available; }

    bool beginMove()
    {
        return mover.move(SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                                 SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER, null));
    }

    bool blurs() { return blur.available; }

    void blurBehind(Scene scene)
    {
        blur.setRegion(scene.backdropBlurRegion(blur.rects[]));
    }

private:
    SDL_Window* window;
    bool ownFrame;
    TileWatcher tiles;   // whether the window's snapped to an edge, for its frame to go flat
    WindowMover mover;   // moves the window by Mayfair's title bar, once a press turns into a drag
    BackgroundBlur blur; // the compositor's blur behind widgets with backdrop-blur

    /*
        Watches whether the window's tiled, while Mayfair draws its frame, once it has an
        xdg_toplevel: it may not when the window's first made, so this is tried again each turn.
        SDL can make the window a new one, too -- it does, through libdecor, as the CPU renderer's
        first frame goes up -- and then the old one's gone, listener and all.
    */
    void watchTiling()
    {
        if (!window || !ownFrame)
            return;
        auto toplevel = SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER, null);
        if (tiles.watching && tiles.watched !is toplevel)
        {
            tiles.forget();
            trace("tiles the window's xdg_toplevel was replaced");
        }
        if (toplevel && !tiles.watching)
            trace("tiles %s", tiles.open(toplevel) ? "watched, for a flat frame when tiled".ptr : "can't be watched".ptr);
    }
}

private:

/*
    Keeps libdecor from loading a plugin -- the GTK one, on GNOME -- while SDL makes the window, by
    pointing it at a folder with none in it, and then puts the setting back as it was. libdecor
    then draws nothing, and Mayfair draws the title bar.
*/
void keepLibdecorPluginsAway(bool away) nothrow @nogc
{
    import core.stdc.stdlib : getenv;
    import core.sys.posix.stdlib : setenv, unsetenv;
    import core.stdc.string : strlen;
    __gshared char[1024] saved;
    __gshared bool hadOne;
    enum none = "/proc/self/fdinfo/nonexistent\0"; // a folder that's never there
    if (away) {
        const was = getenv("LIBDECOR_PLUGIN_DIR");
        hadOne = was !is null && strlen(was) < saved.length;
        if (hadOne)
            saved[0 .. strlen(was) + 1] = was[0 .. strlen(was) + 1];
        setenv("LIBDECOR_PLUGIN_DIR", none.ptr, 1);
    } else if (hadOne) {
        setenv("LIBDECOR_PLUGIN_DIR", saved.ptr, 1);
    } else {
        unsetenv("LIBDECOR_PLUGIN_DIR");
    }
}

/*
    Stops anything reaching stderr, or lets it again: for libdecor, which, kept from its plugins,
    says so as SDL starts and makes the window. Anything SDL itself has to say about that goes
    through SDL_GetError, which is still reported.
*/
void quietStderr(bool quiet) nothrow @nogc
{
    import core.sys.posix.fcntl : open, O_WRONLY;
    import core.sys.posix.unistd : close, dup, dup2;
    __gshared int saved = -1;
    enum stderrFd = 2;
    if (quiet && saved < 0) {
        saved = dup(stderrFd);
        const nul = open("/dev/null", O_WRONLY);
        if (nul >= 0) {
            dup2(nul, stderrFd);
            close(nul);
        }
    } else if (!quiet && saved >= 0) {
        dup2(saved, stderrFd);
        close(saved);
        saved = -1;
    }
}
