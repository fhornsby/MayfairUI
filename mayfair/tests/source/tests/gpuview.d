module tests.gpuview;

import core.thread : Thread;
import core.time : msecs;
import std.math : ceil;
import harness;
import mayfair;

/// GpuViews: set up once on a GPU, drawn at the screen's pixels, again when asked or resized and
/// every frame while continuous; what's drawn lands in the texture sRGB-encoded; and taken out of
/// the window and put back, it draws again on the same device, without setting up again.
void drawing()
{
    GpuView view;
    Column root;
    int setups, renders, releases;
    uint width, height;
    bool direct;
    WGPUTexture texture;
    ContextMenu menu;
    run("gpu view: drawing", {
        view = new GpuView(200, 120);
        view.onSetup((GpuContext gpu) { setups++; direct = gpu.direct; });
        view.onRender((ref GpuFrame f) {
            renders++;
            width = f.width;
            height = f.height;
            texture = f.texture;
            // Clears to a linear half grey: sRGB-encoded in the texture, as 188
            WGPURenderPassColorAttachment colour;
            colour.view = f.view;
            colour.loadOp = WGPULoadOp_Clear;
            colour.storeOp = WGPUStoreOp_Store;
            colour.clearValue = WGPUColor(0.5, 0.5, 0.5, 1);
            colour.depthSlice = uint.max; // WGPU_DEPTH_SLICE_UNDEFINED
            WGPURenderPassDescriptor pass;
            pass.colorAttachmentCount = 1;
            pass.colorAttachments = &colour;
            auto encoder = wgpuCommandEncoderBeginRenderPass(f.encoder, &pass);
            wgpuRenderPassEncoderEnd(encoder);
            wgpuRenderPassEncoderRelease(encoder);
        });
        view.onRelease((GpuContext gpu) { releases++; });
        menu = new ContextMenu().add(new MenuItem("Reset"));
        view.contextMenu(menu);
        root = new Column().padding(20).fillWidth(false);
        return cast(Widget) root.add(view);
    }, (Driver d) {
        d.ui({
            const s = view.scene.scale;
            d.expect(setups, 1, "set up once");
            d.check(renders >= 1, "drawn");
            d.expect(width, cast(uint) ceil(200 * s), "the screen's pixels across");
            d.expect(height, cast(uint) ceil(120 * s), "and down");
            // Straight from the texture on the WebGPU renderer, read back on the others
            import std.process : environment;
            const renderer = environment.get("MAYFAIR_RENDERER", "");
            if (renderer == "webgpu")
                d.check(direct, "drawn from the texture, on the WebGPU renderer");
            else if (renderer.length)
                d.check(!direct, "read back, on the " ~ renderer ~ " renderer");
            const rgba = centrePixel(view.context, texture, width, height);
            d.expect(rgba, [188, 188, 188, 255], "a linear half grey, sRGB-encoded");
        });

        // Asked to draw again: once
        int before;
        d.ui({ before = renders; view.requestRender(); });
        d.settle();
        d.ui({ d.expect(renders, before + 1, "drawn again when asked"); });

        // Resized: drawn at the new size
        d.ui({ view.setPrefWidth(300); });
        d.settle();
        d.ui({ d.expect(width, cast(uint) ceil(300 * view.scene.scale), "drawn again at its new width"); });

        // Continuous: a frame after another, until it isn't
        d.ui({ before = renders; view.setContinuous(true); });
        Thread.sleep(300.msecs);
        d.settle();
        int during;
        d.ui({ during = renders; view.setContinuous(false); });
        d.check(during - before >= 5, "drawn every frame while continuous");
        d.settle();
        d.ui({ before = renders; });
        Thread.sleep(200.msecs);
        d.settle();
        d.ui({ d.expect(renders, before, "and not after"); });

        // A right click: its menu, over it, as over any widget
        Bounds b;
        d.ui({ b = view.boundsInScene; });
        d.click(b.minX + 30, b.minY + 30, 1, 3);
        d.ui({
            d.check(menu.showing, "a right click shows its menu");
            d.check(b.contains(menu.boundsInScene.minX, menu.boundsInScene.minY), "over it");
        });
        d.key(SDL_Keycode.SDLK_ESCAPE);

        // Out of the window and back: drawn again, on the device it set up on
        d.ui({ root.remove(view); });
        d.settle();
        d.ui({ before = renders; root.add(view); });
        d.settle();
        d.ui({
            d.expect(renders, before + 1, "drawn again, back in the window");
            d.expect(setups, 1, "without setting up again");
            d.expect(releases, 0, "or letting go of what it set up");
        });
    });
}

/// The texture's middle pixel, as RGBA bytes, read back.
ubyte[] centrePixel(GpuContext gpu, WGPUTexture texture, uint w, uint h)
{
    WGPUBufferDescriptor bd;
    bd.size = 256;
    bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
    auto buffer = wgpuDeviceCreateBuffer(gpu.device, &bd);
    scope (exit) wgpuBufferRelease(buffer);
    WGPUTexelCopyTextureInfo from;
    from.texture = texture;
    from.origin = WGPUOrigin3D(w / 2, h / 2, 0);
    from.aspect = WGPUTextureAspect_All;
    WGPUTexelCopyBufferInfo to;
    to.buffer = buffer;
    to.layout.bytesPerRow = 256;
    to.layout.rowsPerImage = 1;
    auto size = WGPUExtent3D(1, 1, 1);
    auto encoder = wgpuDeviceCreateCommandEncoder(gpu.device, null);
    wgpuCommandEncoderCopyTextureToBuffer(encoder, &from, &to, &size);
    auto commands = wgpuCommandEncoderFinish(encoder, null);
    wgpuQueueSubmit(gpu.queue, 1, &commands);
    wgpuCommandBufferRelease(commands);
    wgpuCommandEncoderRelease(encoder);

    bool mapped;
    WGPUBufferMapCallbackInfo callback;
    callback.mode = WGPUCallbackMode_AllowSpontaneous;
    callback.callback = &whenMapped;
    callback.userdata1 = &mapped;
    wgpuBufferMapAsync(buffer, WGPUMapMode_Read, 0, 256, callback);
    wgpuDevicePoll(gpu.device, true, null);
    if (!mapped)
        return null;
    auto bytes = cast(const(ubyte)*) wgpuBufferGetConstMappedRange(buffer, 0, 256);
    auto rgba = bytes[0 .. 4].dup;
    wgpuBufferUnmap(buffer);
    return rgba;
}

extern (C) void whenMapped(WGPUMapAsyncStatus status, WGPUStringView, void* mapped, void*) nothrow @nogc
{
    *cast(bool*) mapped = status == WGPUMapAsyncStatus_Success;
}
