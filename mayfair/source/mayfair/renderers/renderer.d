module mayfair.renderers.renderer;

import mayfair.renderers.thorvg;
import sdl;

/// What every renderer provides: somewhere for ThorVG to draw, and a way to get it on screen.
/// Everything here runs every frame and is called from SDL callbacks, hence @nogc nothrow.
interface Renderer
{
@nogc nothrow:
    /// What the window must be created with for this renderer: SDL_WINDOW_OPENGL, say. Asked
    /// before initialise(), as SDL can't add it to a window afterwards.
    SDL_WindowFlags windowFlags();

    /// Sets up for `window`. Prints the reason and returns false on failure.
    bool initialise(SDL_Window* window);

    /// Frees everything. Call before the SDL window is destroyed.
    void release();

    /// ThorVG's scene. Paints added to it are owned by the canvas.
    Tvg_Canvas canvas();

    /// Resizes the drawing surface, in pixels. Does nothing if the size hasn't changed.
    bool resize(uint w, uint h);

    /// Draws the canvas's current scene and shows it in the window.
    void present();

    /*
        The window's about to be hidden: nothing's to reach it until it's shown again and the next
        resize() sets up afresh. A Wayland surface hidden with a frame still on its way to it can't
        be shown again, as SDL gives it its role anew then, and a surface with a buffer can't take one.
    */
    void suspend();

    /// Name for logs, e.g. "cpu" or "webgpu".
    const(char)* name();

    /*
        How many rendered pixels this renderer wants per device pixel. 1 means it draws at the
        window's real resolution; more means it draws bigger and scales down on the way to the
        screen, which is how a renderer whose antialiasing is too coarse buys back edge quality.

        This is not the display scale. Layout still rounds to device pixels and text still lands on
        the device pixel grid; only the ThorVG scene transform is multiplied by this.
    */
    float renderScale();

    /*
        Whether present() waits for the display to be ready for the frame -- vsync -- so the frames
        it shows come once a refresh without the loop timing them. The loop's own timer then only
        keeps a present that stops waiting (a hidden window, say) from running flat out.
    */
    bool pacedByDisplay();
}
