/*
    D bindings for wgpu-native (vendor/wgpu-native/include/webgpu/): the standard webgpu.h plus
    wgpu.h, wgpu-native's own extensions.

    Works the same way as thorvg_c.c: ldc's ImportC compiles it as the D module `webgpu_c`.
    D code should import it through `mayfair.renderers.webgpu`.
*/
#pragma attribute(push, nogc, nothrow)
#include <webgpu/webgpu.h>
#include <webgpu/wgpu.h>
#pragma attribute(pop)
