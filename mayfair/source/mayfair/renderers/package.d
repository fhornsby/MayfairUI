module mayfair.renderers;

public import mayfair.renderers.renderer;
public import mayfair.renderers.cpu;
public import mayfair.renderers.thorvg;
// Not in the browser yet, which has a WebGPU of its own rather than wgpu-native's
version (Emscripten) {} else
{
    public import mayfair.renderers.webgpu;
    public import mayfair.renderers.opengl;
}
