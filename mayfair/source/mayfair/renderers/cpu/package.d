module mayfair.renderers.cpu;

import mayfair.renderers.renderer;
import mayfair.renderers.thorvg;
import mayfair.trace;
import sdl;
import sdl.cpuinfo;
import sdl.surface;
import sdl.error;
import core.stdc.stdio : fprintf, stderr;


/*
    Draws with ThorVG's CPU engine straight into the window's own buffer (SDL_GetWindowSurface).

    On Wayland this resizes far more smoothly than a GPU surface. Wayland says a window's size is the
    size of the buffer it hands the compositor, so a Vulkan surface has to throw away its swapchain of
    3-4 images and build a new one on every size change, which measured 3-5 ms here. A CPU buffer is
    just reallocated. GTK falls back the same way (GSK_RENDERER=cairo), as does iced (tiny-skia).

    A window can have either a surface or an SDL_Renderer, not both. Mayfair uses no SDL_Renderer.
*/
class CpuRenderer : Renderer
{
@nogc nothrow:
private:
    SDL_Window* window;
    Tvg_Canvas _canvas;
    uint* pixels;
    uint stride; // in pixels, not bytes
    uint width, height;

    /*
        Points ThorVG at the window's current buffer. SDL hands out a new one when the window is
        resized, and may swap buffers between frames, so this runs before every frame as well.
    */
    bool useWindowBuffer(){
        auto surface = cast(SDL_SurfaceFields*) SDL_GetWindowSurface(window);
        if (!surface) {
            fprintf(stderr, "SDL_GetWindowSurface failed: %s\n", SDL_GetError());
            return false;
        }
        if (surface.w != width || surface.h != height) {
            // Also catches the mirrored struct below not matching SDL's, rather than drawing through a
            // wrong pointer
            fprintf(stderr, "Window buffer is %dx%d, expected %ux%u\n", surface.w, surface.h, width, height);
            return false;
        }
        if (surface.flags & SDL_SURFACE_LOCK_NEEDED) {
            fprintf(stderr, "Window buffer needs locking, which isn't supported yet\n");
            return false;
        }

        Tvg_Colorspace colourSpace;
        switch (surface.format) {
            case SDL_PixelFormat.SDL_PIXELFORMAT_XRGB8888:
            case SDL_PixelFormat.SDL_PIXELFORMAT_ARGB8888:
                colourSpace = TVG_COLORSPACE_ARGB8888;
                break;
            case SDL_PixelFormat.SDL_PIXELFORMAT_XBGR8888:
            case SDL_PixelFormat.SDL_PIXELFORMAT_ABGR8888:
                colourSpace = TVG_COLORSPACE_ABGR8888;
                break;
            default:
                fprintf(stderr, "Unsupported window buffer format 0x%08x\n", surface.format);
                return false;
        }

        // Only tell ThorVG when something actually changed; it resets the canvas each time
        if (pixels is cast(uint*) surface.pixels && stride == surface.pitch / 4)
            return true;
        pixels = cast(uint*) surface.pixels;
        stride = surface.pitch / 4;
        if (tvg_swcanvas_set_target(_canvas, pixels, stride, width, height, colourSpace) != TVG_RESULT_SUCCESS) {
            fprintf(stderr, "tvg_swcanvas_set_target failed for %ux%u\n", width, height);
            return false;
        }
        return true;
    }

public:
    bool initialise(SDL_Window* window){
        this.window = window;
        if (tvg_engine_init(SDL_GetNumLogicalCPUCores()) != TVG_RESULT_SUCCESS) {
            fprintf(stderr, "tvg_engine_init failed\n");
            return false;
        }
        _canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_DEFAULT);
        if (!_canvas) {
            fprintf(stderr, "tvg_swcanvas_create failed\n");
            return false;
        }
        return true;
    }

    void release(){
        if (_canvas) {
            tvg_canvas_destroy(_canvas);
            tvg_engine_term();
        }
        _canvas = null;
        pixels = null;
    }

    Tvg_Canvas canvas(){
        return _canvas;
    }

    bool resize(uint w, uint h){
        if (w == width && h == height)
            return true;
        width = w;
        height = h;
        const start = traceNow();
        // SDL throws the old buffer away and makes one of the new size
        const ok = useWindowBuffer();
        trace("cpu   resize to %ux%u  %.2f ms", w, h, traceMs(start, traceNow()));
        return ok;
    }

    void present(){
        if (!useWindowBuffer())
            return;
        const start = traceNow();
        tvg_canvas_update(_canvas);
        tvg_canvas_draw(_canvas, true);
        const afterDraw = traceNow();
        // ThorVG rasterises on its worker threads, so this is where the drawing actually gets waited on
        tvg_canvas_sync(_canvas);
        const afterSync = traceNow();
        SDL_UpdateWindowSurface(window);
        trace("cpu   present  update+draw %.2f  sync %.2f  update window %.2f ms",
              traceMs(start, afterDraw), traceMs(afterDraw, afterSync), traceMs(afterSync, traceNow()));
    }

    /// Its rasteriser is a scanline one with full 8-bit coverage, so there is nothing to buy back.
    float renderScale(){
        return 1.0f;
    }

    const(char)* name(){
        return "cpu";
    }
}

/*
    SDL3's SDL_Surface is a public struct (SDL3/SDL_surface.h), but sdl-d declares it opaque, so its
    layout is mirrored here. useWindowBuffer() checks the size it reads back against the size we asked
    for, so a mismatched layout is caught rather than being drawn through.
*/
private struct SDL_SurfaceFields
{
    SDL_SurfaceFlags flags;
    SDL_PixelFormat format;
    int w, h;
    int pitch;
    void* pixels;
    int refcount;
    void* reserved;
}
