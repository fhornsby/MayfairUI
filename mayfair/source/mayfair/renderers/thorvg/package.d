module mayfair.renderers.thorvg;

// ThorVG's C API, generated from its header by ImportC (bindings/thorvg_c.c)
public import thorvg_c;

/*
    A GPU texture drawn as a picture: ThorVG's, as Mayfair patches it (vendor/patches/thorvg/
    0006-wg-picture-from-texture.patch), so not in the submodule's header that thorvg_c reads. For
    a WebGPU canvas only: a WGPUTexture on its device, in RGBA8Unorm, read as not premultiplied
    (TVG_COLORSPACE_ABGR8888S), drawn as it is each time the canvas is.
*/
extern (C) Tvg_Result tvg_picture_load_texture(Tvg_Paint picture, void* texture, uint w, uint h, Tvg_Colorspace cs) nothrow @nogc;
