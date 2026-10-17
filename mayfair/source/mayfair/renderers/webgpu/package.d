module mayfair.renderers.webgpu;

// wgpu-native's C API, generated from its headers by ImportC (bindings/webgpu_c.c)
public import webgpu_c;
import mayfair.renderers.renderer;
import mayfair.log;
import mayfair.renderers.thorvg;
import mayfair.trace;
import sdl;
import sdl.cpuinfo;
import core.stdc.string : strcmp;
import core.stdc.stdlib : getenv, atof;


/*
    Draws with ThorVG's WebGPU engine, running on wgpu-native, into an SDL window.

    ThorVG needs the WebGPU instance, surface and device from us. Its header says a null device makes
    it create one, but tvgWgRenderer.cpp actually treats a null device as "detach the target".
    ThorVG also never presents the surface itself, so present() does that after each frame.

    ThorVG draws into an offscreen texture rather than straight at the window, and this renderer
    scales that down to the surface afterwards. That is not for effect: ThorVG's GPU engine
    antialiases with 4x MSAA, which WebGPU caps at 4 samples, so an edge pixel can only take one of
    five coverage values. Measured on a line of text, the GPU path produced 5 distinct colours where
    the CPU path and GTK both produced 146, and text looked visibly coarse next to any other app.
    Drawing at supersampleFactor times the window size and letting a linear filter average the
    result multiplies the coverage levels available per device pixel, at the price of drawing that
    many more pixels -- squared.

    That was when text was drawn as outlines. Text and icons are bitmaps now, rendered on the CPU
    by FreeType and ThorVG's software renderer at exactly the pixels they cover (see
    mayfair.text.raster), so what's left to the MSAA is shapes -- corners, check boxes, a slider's
    thumb -- which it draws well enough, and supersampling is off by default. It cost: on a Vega 10
    APU at 2x, 97% of the gallery's Animation page's frames reached the screen on the next vblank;
    at 1x, 99%, as many as vkcube's. MAYFAIR_SUPERSAMPLE still turns it on.

    We still configure the surface ourselves so we can choose the present mode.
*/
class WebGpuRenderer : Renderer
{
@nogc nothrow:
private:
    WGPUInstance instance;
    WGPUSurface surface;
    WGPUAdapter adapter;
    WGPUDevice device;
    // Ours to release: wgpuDeviceGetQueue hands out a new reference each call, and each one keeps
    // the device -- and every texture on it -- alive after release()
    WGPUQueue queue;
    Tvg_Canvas _canvas;
    uint width, height;
    WGPUPresentMode presentMode;
    WGPUTextureFormat surfaceFormat;

    // Supersampling: ThorVG's target, and the pass that scales it down to the window
    float supersampleFactor = 1.0f;
    WGPUTexture offscreen;
    WGPUTextureView offscreenView;
    WGPUSampler sampler;
    WGPUCompositeAlphaMode alphaMode = WGPUCompositeAlphaMode_Auto; // premultiplied, for a transparent window
    WGPURenderPipeline downsamplePipeline;
    WGPUBindGroupLayout downsampleLayout;
    WGPUBindGroup downsampleBind;
    bool acceptSoftware;

public:
    /// `acceptSoftware`: use a software Vulkan device rather than fail, when this renderer was asked for
    this(bool acceptSoftware = false){
        this.acceptSoftware = acceptSoftware;
    }

    /// Vulkan draws to any window: wgpu makes its surface from the native handle
    SDL_WindowFlags windowFlags(){
        return cast(SDL_WindowFlags) 0;
    }

    /// Sets up WebGPU and ThorVG for `window`. Prints the reason and returns false on failure.
    bool initialise(SDL_Window* window){
        // Only the backend Mayfair draws with. By default wgpu looks at every one it has, and
        // looking at OpenGL loads EGL and the GL driver -- tens of megabytes, and a dozen threads,
        // for an adapter that's never used.
        WGPUInstanceExtras extras;
        extras.chain.sType = cast(WGPUSType) WGPUSType_InstanceExtras;
        version (OSX)
            extras.backends = WGPUInstanceBackend_Metal;
        else
            extras.backends = WGPUInstanceBackend_Vulkan;
        WGPUInstanceDescriptor descriptor;
        descriptor.nextInChain = &extras.chain;
        instance = wgpuCreateInstance(&descriptor);
        if (!instance) {
            logWarning("wgpuCreateInstance failed");
            return false;
        }

        surface = createSurface(instance, window);
        if (!surface)
            return false;

        // wgpu-native answers adapter and device requests before returning, so no waiting is needed
        WGPURequestAdapterOptions adapterOptions;
        adapterOptions.compatibleSurface = surface;
        WGPURequestAdapterCallbackInfo adapterCallback;
        adapterCallback.mode = WGPUCallbackMode_AllowSpontaneous;
        adapterCallback.callback = &mayfairWgpuAdapterReady;
        adapterCallback.userdata1 = &adapter;
        wgpuInstanceRequestAdapter(instance, &adapterOptions, adapterCallback);
        if (!adapter)
            return false;

        /*
            A CPU adapter is Mesa's lavapipe: Vulkan emulated in software, which is what a machine
            with no Vulkan driver for its GPU is left with -- a VM on virgl, which passes through
            OpenGL only, above all. ThorVG's WebGPU engine on it is many times slower than its own
            CPU engine, so it's turned down, and the app falls back (see chooseRenderers).
        */
        WGPUAdapterInfo info;
        if (wgpuAdapterGetInfo(adapter, &info) == WGPUStatus_Success) {
            scope(exit) wgpuAdapterInfoFreeMembers(info);
            trace("gpu   adapter %.*s, type %d", cast(int) info.device.length, info.device.data, cast(int) info.adapterType);
            if (info.adapterType == WGPUAdapterType_CPU && !acceptSoftware) {
                logInfo("Vulkan is only available in software here (%.*s)",
                        cast(int) info.device.length, info.device.data);
                return false;
            }
        }

        WGPUDeviceDescriptor deviceDescriptor;
        deviceDescriptor.uncapturedErrorCallbackInfo.callback = &mayfairWgpuError;
        WGPURequestDeviceCallbackInfo deviceCallback;
        deviceCallback.mode = WGPUCallbackMode_AllowSpontaneous;
        deviceCallback.callback = &mayfairWgpuDeviceReady;
        deviceCallback.userdata1 = &device;
        wgpuAdapterRequestDevice(adapter, &deviceDescriptor, deviceCallback);
        if (!device)
            return false;
        queue = wgpuDeviceGetQueue(device);

        // Fifo: each frame waits for the display to be ready for it, which is what locks an
        // animation to the refresh; on a compositor with wp_fifo_v1, Mesa paces it with that.
        // Mailbox doesn't wait. It was used here once, for the frames it didn't spend waiting,
        // and was then paced by whenever the compositor happened to hand buffers back: frames
        // 12-22 ms apart, never on the refresh.
        presentMode = WGPUPresentMode_Fifo;
        // The surface's own preferred format. ThorVG used to need this to be BGRA8Unorm, since it
        // drew to the surface directly; now it draws to our offscreen texture and never touches
        // the surface, so whatever the surface likes best is what the downsample pass writes.
        surfaceFormat = WGPUTextureFormat_BGRA8Unorm;
        WGPUSurfaceCapabilities capabilities;
        if (wgpuSurfaceGetCapabilities(surface, adapter, &capabilities) == WGPUStatus_Success) {
            // Prefer a non-sRGB format. ThorVG's offscreen is plain RGBA8Unorm holding colours
            // that are already sRGB-encoded, and the downsample pass is a straight copy; writing
            // those into an sRGB target would encode them a second time and wash the whole UI out.
            // capabilities.formats[0] here is BGRA8UnormSrgb, so this matters.
            bool found = false;
            foreach (i; 0 .. capabilities.formatCount) {
                const f = capabilities.formats[i];
                if (f == WGPUTextureFormat_BGRA8Unorm || f == WGPUTextureFormat_RGBA8Unorm) {
                    surfaceFormat = f;
                    found = true;
                    break;
                }
            }
            if (!found && capabilities.formatCount > 0)
                surfaceFormat = capabilities.formats[0];
            // A transparent window -- one drawing its own shadow round it -- is composited with the
            // alpha it's drawn with. ThorVG's colours are premultiplied, as compositors expect.
            if (SDL_GetWindowFlags(window) & SDL_WindowFlags.SDL_WINDOW_TRANSPARENT)
                foreach (i; 0 .. capabilities.alphaModeCount)
                    if (capabilities.alphaModes[i] == WGPUCompositeAlphaMode_Premultiplied)
                        alphaMode = WGPUCompositeAlphaMode_Premultiplied;
            wgpuSurfaceCapabilitiesFreeMembers(capabilities);
        }
        trace("gpu   surface format %d", cast(int) surfaceFormat);
        trace("gpu   present mode %s", presentMode == WGPUPresentMode_Mailbox ? "Mailbox".ptr : "Fifo".ptr);

        if (tvg_engine_init(SDL_GetNumLogicalCPUCores()) != TVG_RESULT_SUCCESS) {
            logWarning("tvg_engine_init failed");
            return false;
        }
        _canvas = tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT);
        if (!_canvas) {
            logWarning("tvg_wgcanvas_create failed");
            return false;
        }

        // MAYFAIR_SUPERSAMPLE=2, say, draws at twice the size: see above
        if (const(char)* factor = getenv("MAYFAIR_SUPERSAMPLE")) {
            const parsed = atof(factor);
            if (parsed >= 1.0 && parsed <= 4.0)
                supersampleFactor = cast(float) parsed;
            else
                logWarning("MAYFAIR_SUPERSAMPLE must be between 1 and 4, using %g", supersampleFactor);
        }
        if (!createDownsamplePipeline())
            return false;
        trace("gpu   supersample %gx", supersampleFactor);
        return true;
    }

    /// How much bigger than the window ThorVG draws. See the note at the top of the class.
    float renderScale(){
        return supersampleFactor;
    }

    /// Fifo waits for the display: see initialise().
    bool pacedByDisplay(){
        return presentMode == WGPUPresentMode_Fifo;
    }

    /// Frees everything. Call before the SDL window is destroyed, as the surface belongs to it.
    void release(){
        releaseOffscreen();
        if (downsampleBind) wgpuBindGroupRelease(downsampleBind);
        if (downsamplePipeline) wgpuRenderPipelineRelease(downsamplePipeline);
        if (downsampleLayout) wgpuBindGroupLayoutRelease(downsampleLayout);
        if (sampler) wgpuSamplerRelease(sampler);
        downsampleBind = null;
        downsamplePipeline = null;
        downsampleLayout = null;
        sampler = null;
        if (_canvas) {
            tvg_canvas_destroy(_canvas);
            tvg_engine_term();
        }
        if (queue) wgpuQueueRelease(queue);
        if (device) wgpuDeviceRelease(device);
        if (adapter) wgpuAdapterRelease(adapter);
        if (surface) wgpuSurfaceRelease(surface);
        if (instance) wgpuInstanceRelease(instance);
        _canvas = null;
        queue = null;
        device = null;
        adapter = null;
        surface = null;
        instance = null;
    }

    /// ThorVG's scene. Paints added to it are owned by the canvas.
    Tvg_Canvas canvas(){
        return _canvas;
    }

    /// Resizes the drawing surface, in pixels. Does nothing if the size hasn't changed.
    bool resize(uint w, uint h){
        if (w == width && h == height)
            return true;
        const start = traceNow();

        const rw = cast(uint)(w * supersampleFactor + 0.5f);
        const rh = cast(uint)(h * supersampleFactor + 0.5f);

        WGPUTextureDescriptor offscreenDesc;
        offscreenDesc.dimension = WGPUTextureDimension_2D;
        offscreenDesc.size.width = rw;
        offscreenDesc.size.height = rh;
        offscreenDesc.size.depthOrArrayLayers = 1;
        // Must be BGRA8Unorm: WgContext::format is that, hardcoded, and ThorVG builds its internal
        // pipelines (its blit among them) against it. The C API's note that TVG_COLORSPACE_ABGR8888S
        // means RGBA8Unorm does not hold for a texture target -- handing it one fails validation
        // inside ThorVG's own blit pass.
        offscreenDesc.format = WGPUTextureFormat_BGRA8Unorm;
        offscreenDesc.mipLevelCount = 1;
        offscreenDesc.sampleCount = 1;
        offscreenDesc.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding;
        // Readable back only for MAYFAIR_SNAPSHOT, which is all that copies from it
        if (getenv("MAYFAIR_SNAPSHOT"))
            offscreenDesc.usage |= WGPUTextureUsage_CopySrc;
        WGPUTexture nextOffscreen = wgpuDeviceCreateTexture(device, &offscreenDesc);
        if (!nextOffscreen) {
            logWarning("could not create the %ux%u offscreen target", rw, rh);
            return false;
        }
        WGPUTextureView nextView = wgpuTextureCreateView(nextOffscreen, null);

        /*
            Hand ThorVG the new target before letting go of the old one, and never detach first.

            Passing a null device is how tvgWgRenderer reads "detach", and it answers by calling
            WgRenderer::release(), which tears down the context's queue and bind group layouts. The
            next call then arrives with the same device pointer, so the `mContext.device != device`
            test is false, it takes the "size changed" branch instead and never re-initialises what
            was just destroyed. Rendering afterwards dies inside ThorVG on a released layout, which
            surfaces as a bare "invalid device" panic out of wgpu.
        */
        enum textureTarget = 1; // target type 1 = a texture ThorVG draws to
        if (tvg_wgcanvas_set_target(_canvas, cast(void*) device, cast(void*) instance, cast(void*) nextOffscreen,
                                    rw, rh, TVG_COLORSPACE_ABGR8888S, textureTarget) != TVG_RESULT_SUCCESS) {
            logWarning("tvg_wgcanvas_set_target failed for %ux%u", rw, rh);
            wgpuTextureViewRelease(nextView);
            wgpuTextureRelease(nextOffscreen);
            return false;
        }

        // ThorVG has stopped referring to the old target, so now it can go
        releaseOffscreen();
        offscreen = nextOffscreen;
        offscreenView = nextView;
        const afterTarget = traceNow();

        WGPUSurfaceConfiguration config;
        config.device = device;
        config.format = surfaceFormat;
        config.usage = WGPUTextureUsage_RenderAttachment;
        config.width = w;
        config.height = h;
        config.presentMode = presentMode;
        config.alphaMode = alphaMode;
        wgpuSurfaceConfigure(surface, &config);

        if (!createDownsampleBindGroup())
            return false;
        trace("gpu   resize to %ux%u, drawing %ux%u  set_target %.2f  configure %.2f ms", w, h, rw, rh,
              traceMs(start, afterTarget), traceMs(afterTarget, traceNow()));

        width = w;
        height = h;
        return true;
    }

    const(char)* name(){
        return "webgpu";
    }

    /*
        MAYFAIR_SNAPSHOT for this renderer (see mayfair.renderers.cpu.snapshot): ThorVG's frame,
        copied back from the GPU and written as a PNG. It's what ThorVG drew, before the scaling
        down, so at the render scale. Slow -- it waits for the GPU -- but it's a developer's tool.
    */
    void snapshotOffscreen(){
        import mayfair.renderers.cpu : snapshot;
        if (!offscreen)
            return;
        const w = wgpuTextureGetWidth(offscreen), h = wgpuTextureGetHeight(offscreen);
        const rowBytes = (w * 4 + 255) / 256 * 256; // a copy's rows are 256-byte aligned
        WGPUBufferDescriptor bufferDesc;
        bufferDesc.size = cast(ulong) rowBytes * h;
        bufferDesc.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
        auto buffer = wgpuDeviceCreateBuffer(device, &bufferDesc);
        if (!buffer)
            return;
        scope(exit) wgpuBufferRelease(buffer);

        WGPUTexelCopyTextureInfo from;
        from.texture = offscreen;
        from.aspect = WGPUTextureAspect_All;
        WGPUTexelCopyBufferInfo to;
        to.buffer = buffer;
        to.layout.bytesPerRow = rowBytes;
        to.layout.rowsPerImage = h;
        auto size = WGPUExtent3D(w, h, 1);
        auto encoder = wgpuDeviceCreateCommandEncoder(device, null);
        wgpuCommandEncoderCopyTextureToBuffer(encoder, &from, &to, &size);
        auto commands = wgpuCommandEncoderFinish(encoder, null);
        wgpuQueueSubmit(queue, 1, &commands);
        wgpuCommandBufferRelease(commands);
        wgpuCommandEncoderRelease(encoder);

        bool mapped;
        WGPUBufferMapCallbackInfo callback;
        callback.mode = WGPUCallbackMode_AllowSpontaneous;
        callback.callback = &snapshotMapped;
        callback.userdata1 = &mapped;
        wgpuBufferMapAsync(buffer, WGPUMapMode_Read, 0, cast(size_t) rowBytes * h, callback);
        wgpuDevicePoll(device, true, null);
        if (!mapped)
            return;
        // BGRA8 bytes are a little-endian 0xAARRGGBB, which is what snapshot() takes
        auto pixels = cast(const(uint)*) wgpuBufferGetConstMappedRange(buffer, 0, cast(size_t) rowBytes * h);
        if (pixels)
            snapshot(pixels, rowBytes / 4, w, h);
        wgpuBufferUnmap(buffer);
    }

    /// Draws the canvas's current scene into the offscreen target, scales that down into the
    /// window's next frame, and presents it.
    void present(){
        const start = traceNow();
        tvg_canvas_update(_canvas);
        tvg_canvas_draw(_canvas, true);
        const afterDraw = traceNow();
        tvg_canvas_sync(_canvas); // ThorVG's work is finished in the offscreen texture by here
        const afterSync = traceNow();
        if (getenv("MAYFAIR_SNAPSHOT"))
            snapshotOffscreen();

        // Blocks until the compositor hands a buffer back, which is on its schedule, not ours
        WGPUSurfaceTexture frame;
        wgpuSurfaceGetCurrentTexture(surface, &frame);
        const afterAcquire = traceNow();
        if (frame.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal &&
            frame.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
            if (frame.texture) wgpuTextureRelease(frame.texture);
            return; // the surface needs reconfiguring, which the next resize() will do
        }
        WGPUTextureView frameView = wgpuTextureCreateView(frame.texture, null);

        WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(device, null);
        WGPURenderPassColorAttachment attachment;
        attachment.view = frameView;
        attachment.loadOp = WGPULoadOp_Clear;
        attachment.clearValue = WGPUColor(0.0, 0.0, 0.0, 0.0);
        attachment.storeOp = WGPUStoreOp_Store;
        attachment.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pass;
        pass.colorAttachmentCount = 1;
        pass.colorAttachments = &attachment;
        WGPURenderPassEncoder encoded = wgpuCommandEncoderBeginRenderPass(encoder, &pass);
        wgpuRenderPassEncoderSetPipeline(encoded, downsamplePipeline);
        wgpuRenderPassEncoderSetBindGroup(encoded, 0, downsampleBind, 0, null);
        wgpuRenderPassEncoderDraw(encoded, 3, 1, 0, 0); // one triangle covering the whole frame
        wgpuRenderPassEncoderEnd(encoded);
        wgpuRenderPassEncoderRelease(encoded);

        WGPUCommandBuffer commands = wgpuCommandEncoderFinish(encoder, null);
        wgpuQueueSubmit(queue, 1, &commands);
        wgpuCommandBufferRelease(commands);
        wgpuCommandEncoderRelease(encoder);
        wgpuTextureViewRelease(frameView);
        const afterBlit = traceNow();

        // Present before dropping our reference to the frame: releasing the surface texture first
        // leaves nothing to show and the window stays on whatever it had.
        wgpuSurfacePresent(surface);
        wgpuTextureRelease(frame.texture);
        trace("gpu   present  update+draw %.2f  sync %.2f  buffer wait %.2f  downsample %.2f  surface present %.2f ms",
              traceMs(start, afterDraw), traceMs(afterDraw, afterSync), traceMs(afterSync, afterAcquire),
              traceMs(afterAcquire, afterBlit), traceMs(afterBlit, traceNow()));
    }

private:
    void releaseOffscreen(){
        if (downsampleBind) wgpuBindGroupRelease(downsampleBind);
        if (offscreenView) wgpuTextureViewRelease(offscreenView);
        if (offscreen) wgpuTextureRelease(offscreen);
        downsampleBind = null;
        offscreenView = null;
        offscreen = null;
    }

    /*
        The pass that puts the offscreen texture on the screen. A single triangle big enough to
        cover the frame is cheaper than two, and a linear sampler is what actually averages the
        supersampled pixels: reading one texel per output pixel would throw the extra detail away
        and leave the edges exactly as coarse as before.
    */
    bool createDownsamplePipeline(){
        static immutable char[] wgsl = q{
            @group(0) @binding(0) var src: texture_2d<f32>;
            @group(0) @binding(1) var srcSampler: sampler;

            struct VertexOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };

            @vertex fn vs(@builtin(vertex_index) i: u32) -> VertexOut {
                // (0,0) (2,0) (0,2) in UV, which is a triangle covering the whole clip volume
                let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
                var out: VertexOut;
                out.pos = vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
                out.uv = uv;
                return out;
            }

            @fragment fn fs(in: VertexOut) -> @location(0) vec4f {
                return textureSample(src, srcSampler, in.uv);
            }
        } ~ '\0';

        WGPUShaderSourceWGSL wgslSource;
        wgslSource.chain.sType = WGPUSType_ShaderSourceWGSL;
        wgslSource.code = WGPUStringView(wgsl.ptr, wgsl.length - 1);
        WGPUShaderModuleDescriptor moduleDesc;
        moduleDesc.nextInChain = &wgslSource.chain;
        WGPUShaderModule shaderModule = wgpuDeviceCreateShaderModule(device, &moduleDesc);
        if (!shaderModule) {
            logWarning("could not compile the downsample shader");
            return false;
        }
        scope(exit) wgpuShaderModuleRelease(shaderModule);

        WGPUSamplerDescriptor samplerDesc;
        samplerDesc.addressModeU = WGPUAddressMode_ClampToEdge;
        samplerDesc.addressModeV = WGPUAddressMode_ClampToEdge;
        samplerDesc.addressModeW = WGPUAddressMode_ClampToEdge;
        samplerDesc.magFilter = WGPUFilterMode_Linear;
        samplerDesc.minFilter = WGPUFilterMode_Linear;
        samplerDesc.mipmapFilter = WGPUMipmapFilterMode_Nearest;
        samplerDesc.maxAnisotropy = 1;
        samplerDesc.lodMaxClamp = 32.0f;
        sampler = wgpuDeviceCreateSampler(device, &samplerDesc);

        WGPUBindGroupLayoutEntry[2] entries;
        entries[0].binding = 0;
        entries[0].visibility = WGPUShaderStage_Fragment;
        entries[0].texture.sampleType = WGPUTextureSampleType_Float;
        entries[0].texture.viewDimension = WGPUTextureViewDimension_2D;
        entries[1].binding = 1;
        entries[1].visibility = WGPUShaderStage_Fragment;
        entries[1].sampler.type = WGPUSamplerBindingType_Filtering;
        WGPUBindGroupLayoutDescriptor layoutDesc;
        layoutDesc.entryCount = entries.length;
        layoutDesc.entries = entries.ptr;
        downsampleLayout = wgpuDeviceCreateBindGroupLayout(device, &layoutDesc);

        WGPUPipelineLayoutDescriptor pipelineLayoutDesc;
        pipelineLayoutDesc.bindGroupLayoutCount = 1;
        pipelineLayoutDesc.bindGroupLayouts = &downsampleLayout;
        WGPUPipelineLayout pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &pipelineLayoutDesc);
        scope(exit) wgpuPipelineLayoutRelease(pipelineLayout);

        WGPUColorTargetState colourTarget;
        colourTarget.format = surfaceFormat; // must match what the render pass attaches
        colourTarget.writeMask = WGPUColorWriteMask_All;
        WGPUFragmentState fragment;
        // WGPUFragmentState's field is called `module`, which is a D keyword, so it can't be
        // written as fragment.module. getMember reaches it by name instead.
        __traits(getMember, fragment, "module") = shaderModule;
        fragment.entryPoint = WGPUStringView("fs".ptr, 2);
        fragment.targetCount = 1;
        fragment.targets = &colourTarget;

        WGPURenderPipelineDescriptor pipelineDesc;
        pipelineDesc.layout = pipelineLayout;
        __traits(getMember, pipelineDesc.vertex, "module") = shaderModule;
        pipelineDesc.vertex.entryPoint = WGPUStringView("vs".ptr, 2);
        pipelineDesc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
        // Both spelled out rather than left Undefined: the covering triangle below winds clockwise,
        // so a backface cull would throw it away and leave nothing but the clear colour.
        pipelineDesc.primitive.frontFace = WGPUFrontFace_CCW;
        pipelineDesc.primitive.cullMode = WGPUCullMode_None;
        pipelineDesc.multisample.count = 1;
        pipelineDesc.multisample.mask = 0xFFFFFFFF;
        pipelineDesc.fragment = &fragment;
        downsamplePipeline = wgpuDeviceCreateRenderPipeline(device, &pipelineDesc);
        if (!downsamplePipeline) {
            logWarning("could not create the downsample pipeline");
            return false;
        }
        return true;
    }

    bool createDownsampleBindGroup(){
        WGPUBindGroupEntry[2] entries;
        entries[0].binding = 0;
        entries[0].textureView = offscreenView;
        entries[1].binding = 1;
        entries[1].sampler = sampler;
        WGPUBindGroupDescriptor desc;
        desc.layout = downsampleLayout;
        desc.entryCount = entries.length;
        desc.entries = entries.ptr;
        downsampleBind = wgpuDeviceCreateBindGroup(device, &desc);
        if (!downsampleBind) {
            logWarning("could not create the downsample bind group");
            return false;
        }
        return true;
    }
}

/// Wraps the SDL window's native handle (Wayland or X11) in a WebGPU surface.
private WGPUSurface createSurface(WGPUInstance instance, SDL_Window* window) @nogc nothrow
{
    SDL_PropertiesID props = SDL_GetWindowProperties(window);
    const(char)* driver = SDL_GetCurrentVideoDriver();
    WGPUSurfaceDescriptor descriptor;

    if (strcmp(driver, "wayland") == 0) {
        WGPUSurfaceSourceWaylandSurface source;
        source.chain.sType = WGPUSType_SurfaceSourceWaylandSurface;
        source.display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
        source.surface = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
        descriptor.nextInChain = &source.chain;
        return wgpuInstanceCreateSurface(instance, &descriptor);
    }
    if (strcmp(driver, "x11") == 0) {
        WGPUSurfaceSourceXlibWindow source;
        source.chain.sType = WGPUSType_SurfaceSourceXlibWindow;
        source.display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null);
        source.window = SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        descriptor.nextInChain = &source.chain;
        return wgpuInstanceCreateSurface(instance, &descriptor);
    }

    logWarning("WebGPU: SDL video driver '%s' isn't supported yet", driver);
    return null;
}

/*
    WebGPU callbacks. extern(C) names are global at link time, whatever module they're in,
    hence the mayfair prefix.
*/
private extern(C) void mayfairWgpuAdapterReady(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView message,
                                               void* userdata1, void* userdata2) nothrow @nogc
{
    if (status == WGPURequestAdapterStatus_Success)
        *cast(WGPUAdapter*) userdata1 = adapter;
    else
        printWgpuMessage("WebGPU adapter request failed", message);
}

private extern(C) void mayfairWgpuDeviceReady(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message,
                                              void* userdata1, void* userdata2) nothrow @nogc
{
    if (status == WGPURequestDeviceStatus_Success)
        *cast(WGPUDevice*) userdata1 = device;
    else
        printWgpuMessage("WebGPU device request failed", message);
}

private extern(C) void mayfairWgpuError(const(WGPUDevice)* device, WGPUErrorType type, WGPUStringView message,
                                        void* userdata1, void* userdata2) nothrow @nogc
{
    printWgpuMessage("WebGPU error", message);
}

private void printWgpuMessage(const(char)* context, WGPUStringView message) nothrow @nogc
{
    // A length of WGPU_STRLEN (size_t.max) means the string is null-terminated
    if (message.length == size_t.max)
        logWarning("%s: %s", context, message.data);
    else
        logWarning("%s: %.*s", context, cast(int) message.length, message.data);
}

private extern(C) void snapshotMapped(WGPUMapAsyncStatus status, WGPUStringView, void* mapped, void*) nothrow @nogc
{
    *cast(bool*) mapped = status == WGPUMapAsyncStatus_Success;
}
