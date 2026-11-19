module mayfair.widgets.gpuview;

/*
    A widget that the app draws in itself, with WebGPU: a 3D view, a CAD model, a game, a plot of a
    million points. Mayfair gives it a texture on the GPU, the app draws into that with render
    passes of its own, and the window shows it in its place among the other widgets, in order --
    under a popup or a toolbar laid over it, clipped by a scroll pane, faded with the rest.

        auto view = new GpuView().prefSize(640, 480);
        view.onSetup((GpuContext gpu) {
            pipeline = makePipeline(gpu.device, gpu.format);   // once: pipelines, buffers, meshes
        });
        view.onRender((ref GpuFrame f) {
            WGPURenderPassColorAttachment colour;
            colour.view = f.view;
            colour.loadOp = WGPULoadOp_Clear;
            ...
            auto pass = wgpuCommandEncoderBeginRenderPass(f.encoder, &passDescriptor);
            ...
        });
        view.onMouseDragged((ref e) { turn(e.x, e.y); view.requestRender(); });

    onRender is called when the view's drawn first, when its size changes, after requestRender(),
    and every frame while it's `continuous`: on the UI thread, in the update before the frame, so
    what it draws is in that frame. It records into `f.encoder`, which Mayfair submits after it.
    The texture is `f.width` by `f.height` pixels -- the display's, so twice as many each way on a
    2x display, as sharp as the rest of the window -- and `f.view` writes to it as sRGB: a shader
    writes linear colour, and the GPU encodes it, as it would for a window. Its alpha is read as
    not premultiplied; most views are opaque, and clear to an opaque colour.

    How it gets to the window depends on what draws the window. With WebGPU, the default, the view
    draws with the window's own device, and ThorVG draws the texture as a picture: nothing's
    copied (see vendor/patches/thorvg/0006-wg-picture-from-texture.patch). With the OpenGL or CPU
    renderer -- a machine with no Vulkan, a VM on virgl -- there's no WebGPU device to share, so
    the view has one of its own, on whatever wgpu finds (OpenGL included), and what it draws is
    read back to the CPU each time and shown as an image: the same code, slower.
    `GpuContext.direct` says which.

    Mouse, keyboard and focus come as for any widget. It stretches to fill what layout gives it,
    or is prefSize big. Its style class is "gpu-view"; to a screen reader it's an image, named by
    its accessibleText.

    Not in the browser build, which has no WebGPU renderer yet.
*/

version (Emscripten) {} else:

import core.time : MonoTime, seconds;
import std.math : ceil;
import mayfair.accessibility;
import mayfair.animation.animation : Animation;
import mayfair.layout;
import mayfair.animation.animation : Status;
import mayfair.log;
import mayfair.properties;
import mayfair.renderers.thorvg;
import mayfair.renderers.webgpu : sharedDevice;
import mayfair.widgets.widget;

/// WebGPU, as wgpu-native's C API has it, for drawing in a GpuView.
public import webgpu_c;

/// The GPU a GpuView draws with.
struct GpuContext
{
    WGPUInstance instance;
    WGPUAdapter adapter;
    WGPUDevice device;
    WGPUQueue queue;
    /// The format of a frame's `view`, for a pipeline's colour target: RGBA8UnormSrgb.
    WGPUTextureFormat format = WGPUTextureFormat_RGBA8UnormSrgb;
    /// Whether it's the window's own device, drawn from without a copy; false for one of the
    /// view's own, read back through the CPU.
    bool direct;
}

/// What a GpuView's onRender has to draw with, and into.
struct GpuFrame
{
    GpuContext gpu;
    alias gpu this;
    /// Records what's drawn: Mayfair submits it, after onRender.
    WGPUCommandEncoder encoder;
    /// The texture to draw into, and a view of it to render to, in `format`.
    WGPUTexture texture;
    WGPUTextureView view; /// ditto
    /// Its size in pixels, and how many pixels to a point.
    uint width, height;
    float pixelScale = 1; /// ditto
    /// Seconds since the view was first drawn: for what moves by itself.
    double time = 0;
}

class GpuView : Widget
{
public:
    this(float prefWidth = 0, float prefHeight = 0)
    {
        styleClass.add("gpu-view");
        _ticker = new Ticker(this);
        setAccessibleRole(AccessibleRole.image);
        if (prefWidth > 0)
            setPrefWidth(prefWidth);
        if (prefHeight > 0)
            setPrefHeight(prefHeight);
    }

    /// Called once there's a GPU to draw with, before the first onRender: for pipelines, buffers and
    /// meshes. Called again, after onRelease, should the device be another one later.
    final This onSetup(this This)(void delegate(GpuContext gpu) handler) { _onSetup = handler; return cast(This) this; }

    /// Draws a frame: see the top of the module.
    final This onRender(this This)(void delegate(ref GpuFrame frame) handler) { _onRender = handler; requestRender(); return cast(This) this; }

    /// Called as the view lets go of a device it set up with: for what onSetup made on it.
    final This onRelease(this This)(void delegate(GpuContext gpu) handler) { _onRelease = handler; return cast(This) this; }

    /// Draws again, in the next frame: after what's shown has changed.
    final void requestRender() nothrow @nogc
    {
        _renderWanted = true;
        requestUpdate();
    }

    /// Whether it draws every frame, for something that moves by itself, rather than when asked.
    mixin(declareProperty!(bool, "continuous", "false", q{ continuityChanged(); }));

    /// The GPU it draws with, once it has one: for making things on it outside onSetup and onRender.
    final GpuContext context() nothrow @nogc { return _gpu; }

protected:
    override bool takesChildren() const nothrow @nogc { return false; }

    override void mounted() nothrow
    {
        _holder = addPaint(tvg_scene_new());
        _picture = null;
        requestRender();
    }

    override void unmounted()
    {
        // The holder took the picture with it. The texture goes too, until the view's back in a
        // window, which may be another with another renderer; what onSetup made stays, while the
        // device does.
        _holder = null;
        _picture = null;
        releaseTexture();
        _ticker.stop();
    }

    override void update()
    {
        if (_continuous && _ticker.status != Status.running)
            _ticker.play();
        if (_renderWanted)
            render();
    }

    override void paint(float x, float y, float w, float h) nothrow @nogc
    {
        // What it was laid out at, in pixels: a new size wants drawing anew, which happens in the
        // next update. Until then what was drawn last is stretched to fit.
        const s = scene ? scene.scale : 1;
        const pw = clampSize(ceil(w * s)), ph = clampSize(ceil(h * s));
        if (pw != _wantW || ph != _wantH || s != _pixelScale)
        {
            _wantW = pw;
            _wantH = ph;
            _pixelScale = s;
            requestRender();
        }
        if (!_picture || !_shownW || !_shownH)
            return;
        auto m = Tvg_Matrix(w / _shownW, 0, x, 0, h / _shownH, y, 0, 0, 1);
        tvg_paint_set_transform(_picture, &m);
    }

private:
    void delegate(GpuContext) _onSetup, _onRelease;
    void delegate(ref GpuFrame) _onRender;
    bool _renderWanted;

    GpuContext _gpu;       // what onSetup was last given, its device ours to release
    bool _setUp;
    WGPUTexture _texture;
    WGPUTextureView _view;
    uint _textureW, _textureH;
    WGPUBuffer _readback;  // for a device of its own: what the texture's copied to, to be read
    uint[] _pixels;        // and what's read, as ThorVG takes it
    bool _onOwnDevice;     // counted among the own device's users

    uint _wantW, _wantH;   // the size it was laid out at, in pixels
    uint _shownW, _shownH; // the size of what the picture shows
    float _pixelScale = 1;
    Tvg_Paint _holder, _picture;
    MonoTime _started;
    bool _hasStarted;
    Ticker _ticker;

    static uint clampSize(float pixels) nothrow @nogc
    {
        // wgpu's default limit for a 2D texture's side, which every adapter supports
        enum maxSide = 8192;
        return pixels <= 0 ? 0 : pixels > maxSide ? maxSide : cast(uint) pixels;
    }

    void render()
    {
        _renderWanted = false;
        if (!scene || !_holder || !_wantW || !_wantH || !_onRender)
            return;
        if (!ensureDevice() || !ensureTexture(_wantW, _wantH))
            return;
        if (!_hasStarted)
        {
            _started = MonoTime.currTime;
            _hasStarted = true;
        }

        GpuFrame frame;
        frame.gpu = _gpu;
        frame.texture = _texture;
        frame.view = _view;
        frame.width = _textureW;
        frame.height = _textureH;
        frame.pixelScale = _pixelScale;
        frame.time = (MonoTime.currTime - _started).total!"hnsecs" / 1e7;
        frame.encoder = wgpuDeviceCreateCommandEncoder(_gpu.device, null);
        try
            _onRender(frame);
        catch (Exception e)
            logWarning("GpuView: onRender threw %.*s", cast(int) e.msg.length, e.msg.ptr);
        auto commands = wgpuCommandEncoderFinish(frame.encoder, null);
        wgpuQueueSubmit(_gpu.queue, 1, &commands);
        wgpuCommandBufferRelease(commands);
        wgpuCommandEncoderRelease(frame.encoder);

        if (_gpu.direct)
            showTexture();
        else
            showReadBack();
        invalidate();
    }

    /// Finds the device to draw with -- the window's, or one of its own -- setting up on it if it's
    /// another than it set up on before. False if there's none.
    bool ensureDevice()
    {
        GpuContext gpu;
        gpu.direct = sharedDevice(scene.renderer, gpu.instance, gpu.adapter, gpu.device, gpu.queue);
        if (!gpu.direct)
        {
            if (!_onOwnDevice)
            {
                if (!ownGpu.open())
                    return false;
                ownGpu.users++;
                _onOwnDevice = true;
            }
            gpu.instance = ownGpu.instance;
            gpu.adapter = ownGpu.adapter;
            gpu.device = ownGpu.device;
            gpu.queue = ownGpu.queue;
        }
        else
            leaveOwnDevice();
        if (_setUp && gpu.device is _gpu.device && gpu.direct == _gpu.direct)
            return true;

        // Another device, or the first: what was made on the last one goes with it
        releaseTexture();
        releaseSetup();
        wgpuDeviceAddRef(gpu.device);
        wgpuQueueAddRef(gpu.queue);
        _gpu = gpu;
        _setUp = true;
        if (_onSetup)
        {
            try
                _onSetup(_gpu);
            catch (Exception e)
                logWarning("GpuView: onSetup threw %.*s", cast(int) e.msg.length, e.msg.ptr);
        }
        return true;
    }

    /// Makes the texture `w` by `h`, if it isn't already. False if it can't be made.
    bool ensureTexture(uint w, uint h)
    {
        if (_texture && _textureW == w && _textureH == h)
            return true;
        releaseTexture();

        // Shared, it's plain RGBA8Unorm, as ThorVG draws it, with an sRGB view to render to: the
        // same bytes either way, encoded by the GPU on the way in. Read back, it's sRGB itself, as
        // an OpenGL adapter can't always view a texture as another format.
        WGPUTextureFormat[1] srgb = [WGPUTextureFormat_RGBA8UnormSrgb];
        WGPUTextureDescriptor td;
        td.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopySrc;
        td.dimension = WGPUTextureDimension_2D;
        td.size = WGPUExtent3D(w, h, 1);
        td.mipLevelCount = 1;
        td.sampleCount = 1;
        if (_gpu.direct)
        {
            td.format = WGPUTextureFormat_RGBA8Unorm;
            td.viewFormatCount = 1;
            td.viewFormats = srgb.ptr;
        }
        else
            td.format = WGPUTextureFormat_RGBA8UnormSrgb;
        _texture = wgpuDeviceCreateTexture(_gpu.device, &td);
        if (!_texture)
        {
            logWarning("GpuView: couldn't make a %ux%u texture", w, h);
            return false;
        }
        WGPUTextureViewDescriptor vd;
        vd.format = WGPUTextureFormat_RGBA8UnormSrgb;
        vd.dimension = WGPUTextureViewDimension_2D;
        vd.mipLevelCount = 1;
        vd.arrayLayerCount = 1;
        vd.aspect = WGPUTextureAspect_All;
        _view = wgpuTextureCreateView(_texture, &vd);
        _textureW = w;
        _textureH = h;
        return true;
    }

    /// Shows the texture itself, as a picture ThorVG draws from it: made once a texture.
    void showTexture()
    {
        if (_picture && _shownW == _textureW && _shownH == _textureH)
            return; // the same texture, which ThorVG draws as it now is
        dropPicture();
        _picture = tvg_picture_new();
        if (tvg_picture_load_texture(_picture, cast(void*) _texture, _textureW, _textureH,
                                     TVG_COLORSPACE_ABGR8888S) != TVG_RESULT_SUCCESS)
        {
            logWarning("GpuView: ThorVG wouldn't take the texture");
            tvg_paint_rel(_picture);
            _picture = null;
            return;
        }
        tvg_scene_add(_holder, _picture);
        _shownW = _textureW;
        _shownH = _textureH;
    }

    /// Reads the texture back, and shows that as an image: for a device of the view's own.
    void showReadBack()
    {
        const w = _textureW, h = _textureH;
        const rowBytes = (w * 4 + 255) / 256 * 256; // a copy's rows are 256-byte aligned
        const size = cast(ulong) rowBytes * h;
        if (!_readback || wgpuBufferGetSize(_readback) != size)
        {
            if (_readback)
                wgpuBufferRelease(_readback);
            WGPUBufferDescriptor bd;
            bd.size = size;
            bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
            _readback = wgpuDeviceCreateBuffer(_gpu.device, &bd);
            if (!_readback)
                return;
        }

        WGPUTexelCopyTextureInfo from;
        from.texture = _texture;
        from.aspect = WGPUTextureAspect_All;
        WGPUTexelCopyBufferInfo to;
        to.buffer = _readback;
        to.layout.bytesPerRow = rowBytes;
        to.layout.rowsPerImage = h;
        auto extent = WGPUExtent3D(w, h, 1);
        auto encoder = wgpuDeviceCreateCommandEncoder(_gpu.device, null);
        wgpuCommandEncoderCopyTextureToBuffer(encoder, &from, &to, &extent);
        auto commands = wgpuCommandEncoderFinish(encoder, null);
        wgpuQueueSubmit(_gpu.queue, 1, &commands);
        wgpuCommandBufferRelease(commands);
        wgpuCommandEncoderRelease(encoder);

        bool mapped;
        WGPUBufferMapCallbackInfo callback;
        callback.mode = WGPUCallbackMode_AllowSpontaneous;
        callback.callback = &gpuViewMapped;
        callback.userdata1 = &mapped;
        wgpuBufferMapAsync(_readback, WGPUMapMode_Read, 0, cast(size_t) size, callback);
        wgpuDevicePoll(_gpu.device, true, null);
        if (!mapped)
        {
            logWarning("GpuView: couldn't read the texture back");
            return;
        }
        // RGBA bytes, not premultiplied, to 0xAARRGGBB premultiplied, which every renderer takes
        if (_pixels.length != w * h)
            _pixels = new uint[w * h];
        auto bytes = cast(const(ubyte)*) wgpuBufferGetConstMappedRange(_readback, 0, cast(size_t) size);
        foreach (y; 0 .. h)
        {
            auto row = bytes + cast(size_t) y * rowBytes;
            auto into = _pixels[y * w .. (y + 1) * w];
            foreach (x; 0 .. w)
            {
                const r = row[x * 4], g = row[x * 4 + 1], b = row[x * 4 + 2], a = row[x * 4 + 3];
                into[x] = (cast(uint) a << 24) | (cast(uint) (r * a / 255) << 16) | (cast(uint) (g * a / 255) << 8)
                        | (b * a / 255);
            }
        }
        wgpuBufferUnmap(_readback);

        dropPicture();
        _picture = tvg_picture_new();
        tvg_picture_load_raw(_picture, _pixels.ptr, w, h, TVG_COLORSPACE_ARGB8888, true);
        tvg_scene_add(_holder, _picture);
        _shownW = w;
        _shownH = h;
    }

    void dropPicture() nothrow @nogc
    {
        if (_picture && _holder)
            tvg_scene_remove(_holder, _picture);
        _picture = null;
        _shownW = _shownH = 0;
    }

    void releaseTexture() nothrow @nogc
    {
        dropPicture(); // ThorVG lets go of its reference to the texture with the picture
        if (_view)
            wgpuTextureViewRelease(_view);
        if (_texture)
            wgpuTextureRelease(_texture);
        if (_readback)
            wgpuBufferRelease(_readback);
        _view = null;
        _texture = null;
        _readback = null;
        _textureW = _textureH = 0;
    }

    /// Tells the app it's letting go of the device it set up on, and does.
    void releaseSetup()
    {
        if (!_setUp)
            return;
        if (_onRelease)
        {
            try
                _onRelease(_gpu);
            catch (Exception e)
                logWarning("GpuView: onRelease threw %.*s", cast(int) e.msg.length, e.msg.ptr);
        }
        wgpuQueueRelease(_gpu.queue);
        wgpuDeviceRelease(_gpu.device);
        _gpu = GpuContext.init;
        _setUp = false;
    }

    void leaveOwnDevice() nothrow @nogc
    {
        if (!_onOwnDevice)
            return;
        _onOwnDevice = false;
        if (--ownGpu.users == 0)
            ownGpu.close();
    }

    void continuityChanged() nothrow @nogc
    {
        if (_continuous)
            requestUpdate(); // which starts the ticker, where it's allowed to
        else
            _ticker.stop();
    }

    /// Asks for a frame on every pulse, while the view's continuous.
    static final class Ticker : Animation
    {
        GpuView view;

        this(GpuView view) nothrow
        {
            this.view = view;
            cycleDuration(seconds(1));
            cycleCount(Animation.indefinite);
        }

    protected:
        override void step(double fraction)
        {
            view.requestRender();
        }
    }
}

private:

/*
    The device GpuViews draw with when the window's renderer isn't WebGPU: one for all of them,
    made when the first needs it and let go of with the last. Any backend wgpu has will do -- this
    is for a machine whose Vulkan is missing or only in software, where wgpu's OpenGL may be the
    only way in -- and a software adapter is welcome, as it only draws the views.
*/
struct OwnGpu
{
nothrow @nogc:
    WGPUInstance instance;
    WGPUAdapter adapter;
    WGPUDevice device;
    WGPUQueue queue;
    int users;

    bool open()
    {
        if (device)
            return true;
        WGPUInstanceExtras extras;
        extras.chain.sType = cast(WGPUSType) WGPUSType_InstanceExtras;
        extras.backends = WGPUInstanceBackend_Vulkan | WGPUInstanceBackend_GL | WGPUInstanceBackend_Metal;
        WGPUInstanceDescriptor descriptor;
        descriptor.nextInChain = &extras.chain;
        instance = wgpuCreateInstance(&descriptor);
        if (!instance)
        {
            logWarning("GpuView: no WebGPU instance");
            return false;
        }
        WGPURequestAdapterOptions options;
        WGPURequestAdapterCallbackInfo adapterCallback;
        adapterCallback.mode = WGPUCallbackMode_AllowSpontaneous;
        adapterCallback.callback = &gpuViewAdapter;
        adapterCallback.userdata1 = &adapter;
        wgpuInstanceRequestAdapter(instance, &options, adapterCallback);
        if (!adapter)
        {
            logWarning("GpuView: no WebGPU adapter, on any backend");
            close();
            return false;
        }
        WGPUDeviceDescriptor deviceDescriptor;
        deviceDescriptor.uncapturedErrorCallbackInfo.callback = &gpuViewError;
        WGPURequestDeviceCallbackInfo deviceCallback;
        deviceCallback.mode = WGPUCallbackMode_AllowSpontaneous;
        deviceCallback.callback = &gpuViewDevice;
        deviceCallback.userdata1 = &device;
        wgpuAdapterRequestDevice(adapter, &deviceDescriptor, deviceCallback);
        if (!device)
        {
            logWarning("GpuView: no WebGPU device");
            close();
            return false;
        }
        queue = wgpuDeviceGetQueue(device);
        return true;
    }

    void close()
    {
        if (queue) wgpuQueueRelease(queue);
        if (device) wgpuDeviceRelease(device);
        if (adapter) wgpuAdapterRelease(adapter);
        if (instance) wgpuInstanceRelease(instance);
        this = OwnGpu.init;
    }
}

__gshared OwnGpu ownGpu;

extern (C) void gpuViewAdapter(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView message,
                               void* userdata1, void*) nothrow @nogc
{
    if (status == WGPURequestAdapterStatus_Success)
        *cast(WGPUAdapter*) userdata1 = adapter;
}

extern (C) void gpuViewDevice(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message,
                              void* userdata1, void*) nothrow @nogc
{
    if (status == WGPURequestDeviceStatus_Success)
        *cast(WGPUDevice*) userdata1 = device;
}

extern (C) void gpuViewError(const(WGPUDevice)* device, WGPUErrorType type, WGPUStringView message,
                             void*, void*) nothrow @nogc
{
    if (message.length == size_t.max)
        logWarning("GpuView: WebGPU error: %s", message.data);
    else
        logWarning("GpuView: WebGPU error: %.*s", cast(int) message.length, message.data);
}

extern (C) void gpuViewMapped(WGPUMapAsyncStatus status, WGPUStringView, void* mapped, void*) nothrow @nogc
{
    *cast(bool*) mapped = status == WGPUMapAsyncStatus_Success;
}
