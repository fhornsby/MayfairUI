module mayfair.clipboard;

import std.string : fromStringz, toStringz;
import sdl.clipboard;
import sdl.stdc : SDL_free;

/*
    The system clipboard: JavaFX's Clipboard, for text. It's the desktop's own, shared with every
    other app, so what's put here can be pasted anywhere and the other way round.

    Only from the UI thread, as with anything else that talks to the window system.
*/
struct Clipboard
{
    @disable this(); // namespace only

    /// What's on the clipboard, or null if there's no text on it.
    static string text()
    {
        if (!SDL_HasClipboardText())
            return null;
        auto c = SDL_GetClipboardText();
        scope(exit) SDL_free(c);
        return c ? fromStringz(c).idup : null;
    }

    /// Whether there's text on it, without fetching it: for whether Paste can do anything.
    static bool hasText() nothrow @nogc
    {
        return SDL_HasClipboardText();
    }

    /// Puts `value` on the clipboard, in place of whatever was there.
    static void text(string value)
    {
        SDL_SetClipboardText(value.toStringz);
    }

    /*
        The primary selection: the other clipboard on Linux and the BSDs, which holds whatever
        text was last selected, anywhere, without being copied, and which a middle click pastes.
        Elsewhere there's no such thing, and it's just empty.
    */
    static string primary()
    {
        if (!SDL_HasPrimarySelectionText())
            return null;
        auto c = SDL_GetPrimarySelectionText();
        scope(exit) SDL_free(c);
        return c ? fromStringz(c).idup : null;
    }

    /// Makes `value` the primary selection. A widget does this when the user selects text in it.
    static void primary(string value)
    {
        SDL_SetPrimarySelectionText(value.toStringz);
    }
}
