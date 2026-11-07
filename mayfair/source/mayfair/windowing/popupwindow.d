module mayfair.windowing.popupwindow;

import sdl;
import sdl.error;
import mayfair.log;
import mayfair.renderers;
import mayfair.trace;
import mayfair.widgets.scene : PopupWindow;
import mayfair.windowing.window : Window;

/*
    A window of its own for a menu, or a drop-down's list, over the window it's for: SDL's popup
    window, which is an xdg_popup on Wayland and an override-redirect window on X11, with a
    renderer of its own. Its popup is still its Window's scene's (see PopupWindows); this is only
    where it's drawn, and where the pointer's input on it comes from.

    Making one, and starting a renderer in it, takes a good part of a second's tenth, so they're
    kept: a Window makes one the first time a menu's shown, hides it when that menu goes, and
    shows the next menu in it again. A submenu, shown over its menu, takes a second. They go with
    the Window.

    It's hidden once the frame's update is done, not as its menu goes, so a menu shown in its place
    in the same frame -- the next one along a menu bar -- moves it rather than hiding and showing
    it again. On Wayland that's more than saving time: a hidden surface given its role again with a
    frame still on its way to it is an error, and with explicit sync, the compositor holds each
    frame until the GPU's drawn it.

    It's never given keyboard focus: the keys stay with the Window, whose scene sends them to the
    menu, as it does a menu drawn in the window.
*/
final class PopupSurface : PopupWindow
{
    /// Makes one over `owner`, hidden, with the first of `candidates` that starts in it. Null if
    /// none does, or SDL can't make popup windows here.
    static PopupSurface make(Window owner, Renderer[] candidates)
    {
        const start = traceNow();
        enum flags = SDL_WindowFlags.SDL_WINDOW_POPUP_MENU | SDL_WindowFlags.SDL_WINDOW_NOT_FOCUSABLE
                   | SDL_WindowFlags.SDL_WINDOW_TRANSPARENT | SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY
                   | SDL_WindowFlags.SDL_WINDOW_HIDDEN;
        SDL_Window* window;
        SDL_WindowFlags madeFor;
        Renderer renderer;
        foreach (candidate; candidates)
        {
            if (!window || candidate.windowFlags() != madeFor)
            {
                if (window)
                    SDL_DestroyWindow(window);
                madeFor = candidate.windowFlags();
                window = SDL_CreatePopupWindow(owner.sdl, 0, 0, 1, 1, flags | madeFor);
                if (!window)
                {
                    trace("popup window can't be made: %s", SDL_GetError());
                    return null;
                }
            }
            if (candidate.initialise(window))
            {
                renderer = candidate;
                break;
            }
            candidate.release();
        }
        if (!renderer)
        {
            if (window)
                SDL_DestroyWindow(window);
            return null;
        }
        auto made = new PopupSurface;
        made.owner = owner;
        made.sdl = window;
        made.renderer = renderer;
        trace("popup window %u made, renderer %s, in %.2f ms", SDL_GetWindowID(window), renderer.name(),
              traceMs(start, traceNow()));
        return made;
    }

    Tvg_Canvas canvas() nothrow @nogc { return renderer.canvas; }

    void place(float x, float y, float width, float height) nothrow @nogc
    {
        // Rounded down, so it starts on the point it's asked to, or before
        import std.math : floor;
        const wx = cast(int) floor(x * owner.scale / SDL_GetWindowPixelDensity(owner.sdl));
        const wy = cast(int) floor(y * owner.scale / SDL_GetWindowPixelDensity(owner.sdl));
        const ww = owner.toWindow(width) > 0 ? owner.toWindow(width) : 1;
        const wh = owner.toWindow(height) > 0 ? owner.toWindow(height) : 1;
        if (shown && wx == askedX && wy == askedY && ww == askedW && wh == askedH)
            return; // where it was put: anywhere else, the window system had it go
        if (ww != askedW || wh != askedH)
            SDL_SetWindowSize(sdl, ww, wh);
        SDL_SetWindowPosition(sdl, wx, wy);
        if (!shown)
            SDL_ShowWindow(sdl);
        shown = true;
        askedX = atX = wx;
        askedY = atY = wy;
        askedW = ww;
        askedH = wh;
        needsPresent = true;
        trace("popup window %u at %d, %d, %dx%d", SDL_GetWindowID(sdl), wx, wy, ww, wh);
    }

    void origin(out float x, out float y) nothrow @nogc
    {
        const toPoints = SDL_GetWindowPixelDensity(owner.sdl) / owner.scale;
        x = atX * toPoints;
        y = atY * toPoints;
    }

    void giveBack() nothrow @nogc
    {
        inUse = false;
        hidePending = shown; // at the end of the update, unless it's taken again before then
    }

package(mayfair):
    Window owner;
    SDL_Window* sdl;
    Renderer renderer;
    bool inUse;          // taken for a popup
    bool shown;          // and placed, so showing
    bool hidePending;    // given back, and to be hidden at the end of the update: see hideIfUnused
    bool needsPresent;   // its popup was painted, or the window system wants it drawn again
    int askedX = int.min, askedY = int.min, askedW = int.min, askedH = int.min; // where it was last put, in the owner's window coordinates
    int atX, atY;        // where it is, as SDL last said

    SDL_WindowID id() nothrow @nogc { return SDL_GetWindowID(sdl); }

    /// Taken again by another popup: shown where it is until that one's placed.
    void retake() nothrow @nogc
    {
        inUse = true;
        hidePending = false;
    }

    /// Hides it, if it was given back and nothing's taken it since.
    void hideIfUnused() nothrow @nogc
    {
        if (!hidePending || inUse)
            return;
        hidePending = false;
        renderer.suspend();
        SDL_HideWindow(sdl);
        shown = false;
        askedX = askedY = askedW = askedH = int.min;
    }

    /// SDL says it moved: where the window system put it, which may not be where it was asked.
    /// Whether that's somewhere else.
    bool moved() nothrow @nogc
    {
        int x, y;
        SDL_GetWindowPosition(sdl, &x, &y);
        const changed = x != atX || y != atY;
        atX = x;
        atY = y;
        if (changed)
            trace("popup window %u moved to %d, %d", id, x, y);
        return changed;
    }

    /// Draws its popup, as the scene last painted it.
    void present() nothrow @nogc
    {
        needsPresent = false;
        int w, h;
        SDL_GetWindowSizeInPixels(sdl, &w, &h);
        if (w > 0 && h > 0 && renderer.resize(w, h))
            renderer.present();
    }

    /// The pointer's `x` on it, in its owner's scene's points.
    float pointsX(float x) nothrow @nogc
    {
        float ox, oy;
        origin(ox, oy);
        return ox + x * SDL_GetWindowPixelDensity(sdl) / owner.scale;
    }

    /// ditto
    float pointsY(float y) nothrow @nogc
    {
        float ox, oy;
        origin(ox, oy);
        return oy + y * SDL_GetWindowPixelDensity(sdl) / owner.scale;
    }

    /// Lets go of its renderer and window, as its Window closes.
    void destroy() nothrow @nogc
    {
        renderer.release();
        renderer = null;
        SDL_DestroyWindow(sdl);
        sdl = null;
    }
}
