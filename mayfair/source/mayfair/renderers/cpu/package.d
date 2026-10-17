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
    /// SDL_GetWindowSurface works on a plain window
    SDL_WindowFlags windowFlags(){
        return cast(SDL_WindowFlags) 0;
    }

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
        snapshot(pixels, stride, width, height);
        trace("cpu   present  update+draw %.2f  sync %.2f  update window %.2f ms",
              traceMs(start, afterDraw), traceMs(afterDraw, afterSync), traceMs(afterSync, traceNow()));
    }

    /// Its rasteriser is a scanline one with full 8-bit coverage, so there is nothing to buy back.
    float renderScale(){
        return 1.0f;
    }

    /// SDL_UpdateWindowSurface hands the frame over at once: the loop's timer paces it.
    bool pacedByDisplay(){
        return false;
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

/*
    A developer's tool: with MAYFAIR_SNAPSHOT set to a file name, every frame drawn is also written
    there as a PNG, alpha and all -- what the window hands the compositor, shadow included, which a
    screenshot of the desktop can't show on Wayland. Uncompressed, so it needs nothing but stdio.
    The WebGPU renderer writes its frames through this too, read back from the GPU.
*/
package(mayfair) void snapshot(const(uint)* pixels, uint stride, uint w, uint h) nothrow @nogc
{
    import core.stdc.stdio : FILE, fclose, fopen, fwrite;
    import core.stdc.stdlib : getenv;
    const path = getenv("MAYFAIR_SNAPSHOT");
    if (!path || !*path || !pixels || !w || !h)
        return;
    auto f = fopen(path, "wb");
    if (!f)
        return;
    scope (exit) fclose(f);

    static uint[256] table;
    static bool tabled;
    if (!tabled)
    {
        foreach (uint n; 0 .. 256)
        {
            uint c = n;
            foreach (k; 0 .. 8)
                c = c & 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        tabled = true;
    }
    static uint crc(uint c, const(ubyte)[] data) { foreach (b; data) c = table[(c ^ b) & 0xFF] ^ (c >> 8); return c; }
    static void be32(ubyte* p, uint v) { p[0] = cast(ubyte)(v >> 24); p[1] = cast(ubyte)(v >> 16); p[2] = cast(ubyte)(v >> 8); p[3] = cast(ubyte) v; }

    // A chunk is written in pieces, the CRC running over its type and data as they go
    uint running;
    void begin(string type, uint length)
    {
        ubyte[8] head;
        be32(head.ptr, length);
        head[4 .. 8] = cast(const(ubyte)[]) type;
        fwrite(head.ptr, 1, 8, f);
        running = crc(0xFFFFFFFF, head[4 .. 8]);
    }
    void data(const(ubyte)[] bytes)
    {
        fwrite(bytes.ptr, 1, bytes.length, f);
        running = crc(running, bytes);
    }
    void end()
    {
        ubyte[4] tail;
        be32(tail.ptr, running ^ 0xFFFFFFFF);
        fwrite(tail.ptr, 1, 4, f);
    }

    static immutable ubyte[8] signature = [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];
    fwrite(signature.ptr, 1, 8, f);
    ubyte[13] ihdr;
    be32(ihdr.ptr, w);
    be32(ihdr.ptr + 4, h);
    ihdr[8] = 8;  // bits
    ihdr[9] = 6;  // RGBA
    begin("IHDR", 13);
    data(ihdr[]);
    end();

    // Stored (uncompressed) deflate blocks: each row is a filter byte and its pixels, one block a row
    const rowBytes = 1 + w * 4;
    const blocks = h;
    const length = 2 + blocks * (5 + rowBytes) + 4;
    begin("IDAT", cast(uint) length);
    static immutable ubyte[2] zlibHeader = [0x78, 0x01];
    data(zlibHeader[]);
    uint a = 1, b = 0; // adler-32
    ubyte[4096 * 4 + 1] row;
    if (rowBytes > row.length)
        return;
    foreach (y; 0 .. h)
    {
        ubyte[5] block;
        block[0] = y + 1 == h ? 1 : 0;
        block[1] = cast(ubyte) rowBytes;
        block[2] = cast(ubyte)(rowBytes >> 8);
        block[3] = cast(ubyte) ~rowBytes;
        block[4] = cast(ubyte)(~rowBytes >> 8);
        data(block[]);
        row[0] = 0;
        foreach (x; 0 .. w)
        {
            const p = pixels[y * stride + x];
            const al = p >> 24;
            // Premultiplied, as ThorVG draws, to straight, as PNG keeps it
            uint un(uint c) { return al ? (c * 255 + al / 2) / al : 0; }
            row[1 + x * 4] = cast(ubyte) un((p >> 16) & 0xFF);
            row[2 + x * 4] = cast(ubyte) un((p >> 8) & 0xFF);
            row[3 + x * 4] = cast(ubyte) un(p & 0xFF);
            row[4 + x * 4] = cast(ubyte) al;
        }
        data(row[0 .. rowBytes]);
        foreach (v; row[0 .. rowBytes])
        {
            a = (a + v) % 65521;
            b = (b + a) % 65521;
        }
    }
    ubyte[4] adler;
    be32(adler.ptr, (b << 16) | a);
    data(adler[]);
    end();
    begin("IEND", 0);
    end();
}
