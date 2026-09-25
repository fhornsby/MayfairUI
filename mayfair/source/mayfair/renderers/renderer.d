module mayfair.renderers.renderer;

import mayfair.renderers.thorvg;
import sdl;

/// What every renderer provides: somewhere for ThorVG to draw, and a way to get it on screen.
/// Everything here runs every frame and is called from SDL callbacks, hence @nogc nothrow.
interface Renderer
{
@nogc nothrow:
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
}
