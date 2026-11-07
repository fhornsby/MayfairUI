module mayfair.renderers.opengl;

import mayfair.renderers.renderer;
import mayfair.log;
import mayfair.renderers.thorvg;
import mayfair.trace;
import sdl;
import sdl.cpuinfo;
import sdl.error;
import sdl.video;
import core.stdc.string : strstr;
import core.stdc.stdlib : getenv;


/*
    Draws with ThorVG's OpenGL engine, in an OpenGL ES 3 context SDL makes on the window.

    The fallback for a GPU that does OpenGL but not Vulkan -- most of all a VM on virtio-gpu with
    virgl, which passes OpenGL through to the host's GPU and nothing else. There the only Vulkan is
    Mesa's lavapipe, which runs the WebGPU renderer on the CPU, emulating a GPU, and that is much
    slower than ThorVG's own CPU engine drawing straight into the window.

    ThorVG's GL engine is built for GLES (see vendor/build.sh) and looks its functions up in
    libGLESv2 itself; it only needs the context to be current. SDL makes the context with EGL on
    Wayland and with GLX on X11, and either does: ThorVG is handed EGL's display and surface where
    there are some, to make it current again itself, and otherwise trusts that it is.

    A software GL driver -- llvmpipe again -- is turned down the same way the WebGPU renderer
    turns down a CPU adapter, unless MAYFAIR_RENDERER=opengl asked for this one.
*/
class OpenGlRenderer : Renderer
{
@nogc nothrow:
private:
    SDL_Window* window;
    SDL_GLContext context;
    Tvg_Canvas _canvas;
    uint width, height;
    bool vsync;
    bool acceptSoftware;
    bool unpaced;

public:
    /// `acceptSoftware`: use a software GL driver rather than fail, when this renderer was asked
    /// for. `unpaced`: swap without waiting for the display, for a menu's window, as WebGPU's does.
    this(bool acceptSoftware = false, bool unpaced = false){
        this.acceptSoftware = acceptSoftware;
        this.unpaced = unpaced;
    }

    SDL_WindowFlags windowFlags(){
        return SDL_WindowFlags.SDL_WINDOW_OPENGL;
    }

    bool initialise(SDL_Window* window){
        this.window = window;
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_CONTEXT_PROFILE_MASK, SDL_GLProfile.SDL_GL_CONTEXT_PROFILE_ES);
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_CONTEXT_MINOR_VERSION, 0);
        // Alpha, for a transparent window -- one drawing its own shadow round it. ThorVG keeps its
        // own multisampled buffers with their stencils, so the window's needs neither.
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_ALPHA_SIZE, 8);
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_DEPTH_SIZE, 0);
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_STENCIL_SIZE, 0);
        SDL_GL_SetAttribute(SDL_GLAttr.SDL_GL_DOUBLEBUFFER, 1);

        context = SDL_GL_CreateContext(window);
        if (!context) {
            logWarning("SDL_GL_CreateContext failed: %s", SDL_GetError());
            return false;
        }
        if (!SDL_GL_MakeCurrent(window, context)) {
            logWarning("SDL_GL_MakeCurrent failed: %s", SDL_GetError());
            return false;
        }

        alias GetString = extern(C) const(char)* function(uint) nothrow @nogc;
        enum GL_RENDERER = 0x1F01;
        auto glGetString = cast(GetString) SDL_GL_GetProcAddress("glGetString");
        const(char)* device = glGetString ? glGetString(GL_RENDERER) : null;
        trace("gl    device %s", device ? device : "unknown".ptr);
        if (device && isSoftware(device) && !acceptSoftware) {
            logInfo("OpenGL is only available in software here (%s)", device);
            return false;
        }

        // Waits for the display, as the WebGPU renderer's Fifo does
        vsync = !unpaced && SDL_GL_SetSwapInterval(1);
        if (unpaced)
            SDL_GL_SetSwapInterval(0);

        if (tvg_engine_init(SDL_GetNumLogicalCPUCores()) != TVG_RESULT_SUCCESS) {
            logWarning("tvg_engine_init failed");
            return false;
        }
        _canvas = tvg_glcanvas_create(TVG_ENGINE_OPTION_DEFAULT);
        if (!_canvas) {
            logWarning("tvg_glcanvas_create failed");
            tvg_engine_term();
            return false;
        }
        return true;
    }

    void release(){
        if (_canvas) {
            tvg_canvas_destroy(_canvas);
            tvg_engine_term();
        }
        if (context)
            SDL_GL_DestroyContext(context);
        _canvas = null;
        context = null;
    }

    Tvg_Canvas canvas(){
        return _canvas;
    }

    bool resize(uint w, uint h){
        if (w == width && h == height)
            return true;
        const start = traceNow();
        // Framebuffer 0 is the window's own. The EGL display and surface let ThorVG make the
        // context current itself if something else changed it.
        enum windowFramebuffer = 0;
        if (tvg_glcanvas_set_target(_canvas, SDL_EGL_GetCurrentDisplay(), SDL_EGL_GetWindowSurface(window), context,
                                    windowFramebuffer, w, h, TVG_COLORSPACE_ABGR8888S) != TVG_RESULT_SUCCESS) {
            logWarning("tvg_glcanvas_set_target failed for %ux%u", w, h);
            return false;
        }
        width = w;
        height = h;
        trace("gl    resize to %ux%u  %.2f ms", w, h, traceMs(start, traceNow()));
        return true;
    }

    void present(){
        const start = traceNow();
        // Each window has a context of its own, and the last one used may be another's
        if (SDL_GL_GetCurrentContext() !is context)
            SDL_GL_MakeCurrent(window, context);
        tvg_canvas_update(_canvas);
        tvg_canvas_draw(_canvas, true);
        const afterDraw = traceNow();
        tvg_canvas_sync(_canvas);
        const afterSync = traceNow();
        if (getenv("MAYFAIR_SNAPSHOT"))
            snapshotFramebuffer();
        SDL_GL_SwapWindow(window);
        trace("gl    present  update+draw %.2f  sync %.2f  swap %.2f ms",
              traceMs(start, afterDraw), traceMs(afterDraw, afterSync), traceMs(afterSync, traceNow()));
    }

    /// ThorVG's GL engine antialiases with MSAA, as its WebGPU one does, which draws at 1x there
    float renderScale(){
        return 1.0f;
    }

    bool pacedByDisplay(){
        return vsync;
    }

    /// Nothing outlasts a swap: the driver's done with it as it returns
    void suspend(){
    }

    const(char)* name(){
        return "opengl";
    }

private:
    /*
        MAYFAIR_SNAPSHOT for this renderer (see mayfair.renderers.cpu.snapshot): the window's
        framebuffer, read back before the swap. GL's rows run bottom to top, and its bytes are
        RGBA, where snapshot() takes 0xAARRGGBB, so both are turned round on the way.
    */
    void snapshotFramebuffer(){
        import mayfair.renderers.cpu : snapshot;
        import core.stdc.stdlib : malloc, free;
        alias ReadPixels = extern(C) void function(int, int, int, int, uint, uint, void*) nothrow @nogc;
        enum GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401;
        auto glReadPixels = cast(ReadPixels) SDL_GL_GetProcAddress("glReadPixels");
        if (!glReadPixels || !width || !height)
            return;
        auto read = cast(uint*) malloc(cast(size_t) width * height * 4);
        auto pixels = cast(uint*) malloc(cast(size_t) width * height * 4);
        scope(exit) { free(read); free(pixels); }
        if (!read || !pixels)
            return;
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, read);
        foreach (y; 0 .. height)
            foreach (x; 0 .. width) {
                const p = read[(height - 1 - y) * width + x]; // 0xAABBGGRR, read as a little-endian uint
                pixels[y * width + x] = (p & 0xFF00FF00) | ((p & 0xFF) << 16) | ((p >> 16) & 0xFF);
            }
        snapshot(pixels, width, width, height);
    }
}

/// Mesa's software drivers, by the names they give GL_RENDERER
private bool isSoftware(const(char)* device) @nogc nothrow
{
    return strstr(device, "llvmpipe") || strstr(device, "softpipe") || strstr(device, "Software Rasterizer");
}

