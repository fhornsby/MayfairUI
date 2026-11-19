/*
    A GpuView: a cube drawn with WebGPU, lit, spinning by itself, and turned as it's dragged.
    Everything about the GPU is the app's own here -- the shader, the pipeline, the buffers, the
    depth buffer, multisampling, the render pass -- and Mayfair puts the result in the window,
    under the label laid over its corner.

        cd examples/gpu-cube && dub run
*/
import std.math : cos, PI, sin, tan;
import mayfair;

void main()
{
    auto app = new App("GPU cube");
    auto cube = new Cube;

    auto view = new GpuView().accessibleText("A cube, spinning, and turned by dragging it");
    auto hint = new Label("Drag the cube to turn it, or right-click it");
    auto how = new Label("").style("background-colour: rgba(0, 0, 0, 0.55); colour: white; padding: 4 8; "
                                    ~ "background-radius: 6;");

    view.onSetup((GpuContext gpu) {
        cube.setUp(gpu);
        how.setText(gpu.direct ? "Drawn on the window's GPU, as it is" : "Drawn on a GPU of its own, read back");
    });
    view.onRender((ref GpuFrame frame) { cube.render(frame); });
    view.onRelease((GpuContext gpu) { cube.release(); });

    // Dragging with the left button turns it: across about the vertical axis, up and down about
    // the horizontal. The right button opens its menu.
    float lastX, lastY;
    bool turning;
    view.onMousePressed((ref e) {
        turning = e.button == MouseButton.primary;
        lastX = e.x;
        lastY = e.y;
    });
    view.onMouseDragged((ref e) {
        if (!turning)
            return;
        cube.yaw += (e.x - lastX) * 0.01f;
        cube.pitch += (e.y - lastY) * 0.01f;
        lastX = e.x;
        lastY = e.y;
        view.requestRender();
    });
    auto reset = new Button("Reset").onAction({
        cube.yaw = 0.6f;
        cube.pitch = 0.45f;
        view.requestRender();
    });
    // Spinning, as Vulkan's demo cube does, from the start
    auto spin = new CheckBox("Spin by itself").selected(true);
    view.setContinuous(true);
    spin.selectedProperty.addListener((bool was, bool now) {
        cube.spinning = now;
        view.setContinuous(now);
    });

    // A menu, which opens over the view like over anything else
    view.contextMenu(new ContextMenu()
        .add(new MenuItem("Reset", { reset.fire(); }))
        .add(new MenuItem("Spin by itself", { spin.setSelected(!spin.selected); })));

    auto stage = new Stack().alignment(Pos.topLeft).grow(1);
    stage.add(view).add(how.margin(Insets(12))); // over the view's corner, which still hears the mouse elsewhere

    auto root = new Column().padding(16).spacing(12);
    root.add(stage).add(new Row().spacing(12).alignment(Pos.centreLeft).add(hint).add(reset).add(spin));
    app.scene = new Scene(root);
    app.run();
}

/// The cube: its pipeline and buffers, made on the GPU it's given, and how it's turned.
final class Cube
{
    float yaw = 0.6f, pitch = 0.45f;
    bool spinning = true;

    void setUp(GpuContext gpu)
    {
        device = gpu.device;
        queue = gpu.queue;
        colourFormat = gpu.format;

        auto vertices = cubeVertices();
        WGPUBufferDescriptor bd;
        bd.size = vertices.length * float.sizeof;
        bd.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
        vertexBuffer = wgpuDeviceCreateBuffer(device, &bd);
        wgpuQueueWriteBuffer(queue, vertexBuffer, 0, vertices.ptr, bd.size);
        vertexCount = cast(uint) (vertices.length / floatsPerVertex);

        bd.size = Uniforms.sizeof;
        bd.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst;
        uniformBuffer = wgpuDeviceCreateBuffer(device, &bd);

        // Lit from above, to the right and in front, with some light everywhere, so each face is
        // a shade of its own and it reads as solid
        static immutable char[] wgsl = q{
            struct Uniforms { mvp: mat4x4f, model: mat4x4f };
            @group(0) @binding(0) var<uniform> u: Uniforms;

            struct VertexOut {
                @builtin(position) pos: vec4f,
                @location(0) colour: vec3f,
                @location(1) normal: vec3f,
            };

            @vertex fn vs(@location(0) pos: vec3f, @location(1) normal: vec3f, @location(2) colour: vec3f) -> VertexOut {
                var out: VertexOut;
                out.pos = u.mvp * vec4f(pos, 1.0);
                out.normal = (u.model * vec4f(normal, 0.0)).xyz;
                out.colour = colour;
                return out;
            }

            @fragment fn fs(in: VertexOut) -> @location(0) vec4f {
                let light = normalize(vec3f(0.4, 0.7, 0.6));
                let lit = 0.3 + 0.7 * max(dot(normalize(in.normal), light), 0.0);
                return vec4f(in.colour * lit, 1.0);
            }
        };
        WGPUShaderSourceWGSL source;
        source.chain.sType = WGPUSType_ShaderSourceWGSL;
        source.code = WGPUStringView(wgsl.ptr, wgsl.length);
        WGPUShaderModuleDescriptor md;
        md.nextInChain = &source.chain;
        auto shader = wgpuDeviceCreateShaderModule(device, &md);
        scope (exit) wgpuShaderModuleRelease(shader);

        WGPUBindGroupLayoutEntry entry;
        entry.binding = 0;
        entry.visibility = WGPUShaderStage_Vertex;
        entry.buffer.type = WGPUBufferBindingType_Uniform;
        entry.buffer.minBindingSize = Uniforms.sizeof;
        WGPUBindGroupLayoutDescriptor ld;
        ld.entryCount = 1;
        ld.entries = &entry;
        auto bindLayout = wgpuDeviceCreateBindGroupLayout(device, &ld);
        scope (exit) wgpuBindGroupLayoutRelease(bindLayout);

        WGPUBindGroupEntry binding;
        binding.binding = 0;
        binding.buffer = uniformBuffer;
        binding.size = Uniforms.sizeof;
        WGPUBindGroupDescriptor bgd;
        bgd.layout = bindLayout;
        bgd.entryCount = 1;
        bgd.entries = &binding;
        bindGroup = wgpuDeviceCreateBindGroup(device, &bgd);

        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 1;
        pld.bindGroupLayouts = &bindLayout;
        auto pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &pld);
        scope (exit) wgpuPipelineLayoutRelease(pipelineLayout);

        // Each vertex: where it is, which way its face points, and its colour
        WGPUVertexAttribute[3] attributes;
        foreach (i, ref a; attributes)
        {
            a.format = WGPUVertexFormat_Float32x3;
            a.offset = i * 3 * float.sizeof;
            a.shaderLocation = cast(uint) i;
        }
        WGPUVertexBufferLayout vertexLayout;
        vertexLayout.stepMode = WGPUVertexStepMode_Vertex;
        vertexLayout.arrayStride = floatsPerVertex * float.sizeof;
        vertexLayout.attributeCount = attributes.length;
        vertexLayout.attributes = attributes.ptr;

        WGPUColorTargetState target;
        target.format = gpu.format; // the view's: sRGB, so the shader's colours are linear
        target.writeMask = WGPUColorWriteMask_All;
        WGPUFragmentState fragment;
        __traits(getMember, fragment, "module") = shader; // `module` is a D keyword
        fragment.entryPoint = WGPUStringView("fs".ptr, 2);
        fragment.targetCount = 1;
        fragment.targets = &target;

        // Nearer faces hide farther ones
        WGPUDepthStencilState depthState;
        depthState.format = depthFormat;
        depthState.depthWriteEnabled = WGPUOptionalBool_True;
        depthState.depthCompare = WGPUCompareFunction_Less;

        WGPURenderPipelineDescriptor pd;
        pd.layout = pipelineLayout;
        __traits(getMember, pd.vertex, "module") = shader;
        pd.vertex.entryPoint = WGPUStringView("vs".ptr, 2);
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers = &vertexLayout;
        pd.primitive.topology = WGPUPrimitiveTopology_TriangleList;
        pd.primitive.frontFace = WGPUFrontFace_CCW;
        pd.primitive.cullMode = WGPUCullMode_Back; // the faces turned away aren't drawn at all
        pd.depthStencil = &depthState;
        pd.multisample.count = samples;
        pd.multisample.mask = 0xFFFFFFFF;
        pd.fragment = &fragment;
        pipeline = wgpuDeviceCreateRenderPipeline(device, &pd);
    }

    void render(ref GpuFrame frame)
    {
        if (spinning && lastTime >= 0)
        {
            yaw += cast(float) (frame.time - lastTime) * 0.9f;
            pitch += cast(float) (frame.time - lastTime) * 0.35f;
        }
        lastTime = frame.time;
        fitTargets(frame.width, frame.height);

        const aspect = cast(float) frame.width / frame.height;
        Uniforms u;
        u.model = mul(rotationX(pitch), rotationY(yaw));
        u.mvp = mul(perspective(PI / 4, aspect, 0.1f, 10), mul(translation(0, 0, -3.4f), u.model));
        wgpuQueueWriteBuffer(queue, uniformBuffer, 0, &u, Uniforms.sizeof);

        WGPURenderPassColorAttachment colour;
        // Drawn with 4 samples a pixel, for smooth edges, then averaged into the view's texture
        colour.view = multisampledView;
        colour.resolveTarget = frame.view;
        colour.loadOp = WGPULoadOp_Clear;
        colour.storeOp = WGPUStoreOp_Discard;
        colour.clearValue = WGPUColor(0.012, 0.016, 0.03, 1); // linear: a dark slate, once encoded
        colour.depthSlice = uint.max; // WGPU_DEPTH_SLICE_UNDEFINED, a C macro ImportC can't expand
        WGPURenderPassDepthStencilAttachment depth;
        depth.view = depthView;
        depth.depthLoadOp = WGPULoadOp_Clear;
        depth.depthStoreOp = WGPUStoreOp_Discard;
        depth.depthClearValue = 1;
        WGPURenderPassDescriptor pass;
        pass.colorAttachmentCount = 1;
        pass.colorAttachments = &colour;
        pass.depthStencilAttachment = &depth;
        auto encoder = wgpuCommandEncoderBeginRenderPass(frame.encoder, &pass);
        wgpuRenderPassEncoderSetPipeline(encoder, pipeline);
        wgpuRenderPassEncoderSetBindGroup(encoder, 0, bindGroup, 0, null);
        // ulong.max is WGPU_WHOLE_SIZE, another C macro: all of the buffer
        wgpuRenderPassEncoderSetVertexBuffer(encoder, 0, vertexBuffer, 0, ulong.max);
        wgpuRenderPassEncoderDraw(encoder, vertexCount, 1, 0, 0);
        wgpuRenderPassEncoderEnd(encoder);
        wgpuRenderPassEncoderRelease(encoder);
    }

    void release()
    {
        releaseTargets();
        if (pipeline) wgpuRenderPipelineRelease(pipeline);
        if (bindGroup) wgpuBindGroupRelease(bindGroup);
        if (uniformBuffer) wgpuBufferRelease(uniformBuffer);
        if (vertexBuffer) wgpuBufferRelease(vertexBuffer);
        pipeline = null;
        bindGroup = null;
        uniformBuffer = vertexBuffer = null;
    }

private:
    enum floatsPerVertex = 9;
    enum depthFormat = WGPUTextureFormat_Depth24Plus;
    enum samples = 4;

    struct Uniforms
    {
        Matrix mvp, model;
    }

    WGPUDevice device;
    WGPUQueue queue;
    WGPURenderPipeline pipeline;
    WGPUBindGroup bindGroup;
    WGPUBuffer vertexBuffer, uniformBuffer;
    uint vertexCount;
    WGPUTextureFormat colourFormat;
    WGPUTexture depthTexture, multisampled;
    WGPUTextureView depthView, multisampledView;
    uint targetW, targetH;
    double lastTime = -1;

    /// The depth buffer and the multisampled colour, as big as the frame: made again when the
    /// view's size changes.
    void fitTargets(uint w, uint h)
    {
        if (depthTexture && targetW == w && targetH == h)
            return;
        releaseTargets();
        WGPUTextureDescriptor td;
        td.usage = WGPUTextureUsage_RenderAttachment;
        td.dimension = WGPUTextureDimension_2D;
        td.size = WGPUExtent3D(w, h, 1);
        td.mipLevelCount = 1;
        td.sampleCount = samples;
        td.format = depthFormat;
        depthTexture = wgpuDeviceCreateTexture(device, &td);
        depthView = wgpuTextureCreateView(depthTexture, null);
        td.format = colourFormat;
        multisampled = wgpuDeviceCreateTexture(device, &td);
        multisampledView = wgpuTextureCreateView(multisampled, null);
        targetW = w;
        targetH = h;
    }

    void releaseTargets()
    {
        if (depthView) wgpuTextureViewRelease(depthView);
        if (depthTexture) wgpuTextureRelease(depthTexture);
        if (multisampledView) wgpuTextureViewRelease(multisampledView);
        if (multisampled) wgpuTextureRelease(multisampled);
        depthView = multisampledView = null;
        depthTexture = multisampled = null;
    }
}

/*
    The cube's 36 vertices: two triangles a face, each wound anticlockwise seen from outside, so
    the back faces can be culled. A face is its normal `n` and two edges `u` and `v` across it,
    with u × v = n, which is what makes its corners go round anticlockwise.
*/
float[] cubeVertices()
{
    alias V = float[3];
    static V cross(V a, V b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }

    // Each face's way out, the way that's "up" across it, and its colour, in sRGB as picked
    static immutable V[6] normals = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
    static immutable V[6] ups = [[0, 1, 0], [0, 1, 0], [0, 0, -1], [0, 0, 1], [0, 1, 0], [0, 1, 0]];
    static immutable V[6] colours = [
        [0.94f, 0.27f, 0.27f], // red
        [0.13f, 0.77f, 0.37f], // green
        [0.98f, 0.75f, 0.14f], // amber
        [0.23f, 0.51f, 0.96f], // blue
        [0.66f, 0.33f, 0.97f], // violet
        [0.08f, 0.72f, 0.65f], // teal
    ];

    float[] vertices;
    foreach (f; 0 .. 6)
    {
        const V n = normals[f], v = ups[f], u = cross(v, n); // (v × n) × v = n
        V[4] corners;
        foreach (i, s; [[-1, -1], [1, -1], [1, 1], [-1, 1]])
            foreach (k; 0 .. 3)
                corners[i][k] = 0.6f * (n[k] + s[0] * u[k] + s[1] * v[k]);
        // The shader works in linear colour, as the view encodes what it writes, so it's decoded
        const V c = [linear(colours[f][0]), linear(colours[f][1]), linear(colours[f][2])];
        foreach (i; [0, 1, 2, 0, 2, 3])
            vertices ~= corners[i] ~ n ~ c;
    }
    return vertices;
}

/// An sRGB colour channel, 0 to 1, as linear light.
float linear(float c)
{
    import std.math : pow;
    return c <= 0.04045f ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
}

// 4x4 matrices, column by column, as WGSL reads them

alias Matrix = float[16];

Matrix mul(const Matrix a, const Matrix b)
{
    Matrix m = 0;
    foreach (c; 0 .. 4)
        foreach (r; 0 .. 4)
            foreach (k; 0 .. 4)
                m[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
    return m;
}

Matrix perspective(float fovY, float aspect, float near, float far)
{
    // WebGPU's clip space: z from 0 to 1
    const f = 1 / tan(fovY / 2);
    Matrix m = 0;
    m[0] = f / aspect;
    m[5] = f;
    m[10] = far / (near - far);
    m[11] = -1;
    m[14] = near * far / (near - far);
    return m;
}

Matrix translation(float x, float y, float z)
{
    Matrix m = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  x, y, z, 1];
    return m;
}

Matrix rotationX(float a)
{
    Matrix m = [1, 0, 0, 0,  0, cos(a), sin(a), 0,  0, -sin(a), cos(a), 0,  0, 0, 0, 1];
    return m;
}

Matrix rotationY(float a)
{
    Matrix m = [cos(a), 0, -sin(a), 0,  0, 1, 0, 0,  sin(a), 0, cos(a), 0,  0, 0, 0, 1];
    return m;
}
