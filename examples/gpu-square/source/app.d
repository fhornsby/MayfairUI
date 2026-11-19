/*
    A GpuView: a square drawn with WebGPU, in 3D, which turns as it's dragged. Everything about
    the GPU is the app's own here -- the shader, the pipeline, the buffers, the render pass --
    and Mayfair puts the result in the window, under the label laid over its corner.

        cd examples/gpu-square && dub run
*/
import std.format : format;
import std.math : cos, PI, sin, tan;
import mayfair;

void main()
{
    auto app = new App("GPU square");
    auto square = new Square;

    auto view = new GpuView().accessibleText("A square, turned by dragging it");
    auto turned = new Label("Drag the square to turn it");
    auto how = new Label("").style("background-colour: rgba(0, 0, 0, 0.55); colour: white; padding: 4 8; "
                                    ~ "background-radius: 6;");

    view.onSetup((GpuContext gpu) {
        square.setUp(gpu);
        how.setText(gpu.direct ? "Drawn on the window's GPU, as it is" : "Drawn on a GPU of its own, read back");
    });
    view.onRender((ref GpuFrame frame) { square.render(frame); });
    view.onRelease((GpuContext gpu) { square.release(); });

    // Dragging turns it: across about the vertical axis, up and down about the horizontal
    // with the left button; the right one opens its menu
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
        square.yaw += (e.x - lastX) * 0.01f;
        square.pitch += (e.y - lastY) * 0.01f;
        lastX = e.x;
        lastY = e.y;
        turned.setText(format!"Turned %.0f° across, %.0f° down"(square.yaw * 180 / PI, square.pitch * 180 / PI));
        view.requestRender();
    });
    auto reset = new Button("Reset").onAction({
        square.yaw = square.pitch = 0;
        turned.setText("Drag the square to turn it");
        view.requestRender();
    });
    auto spin = new CheckBox("Spin by itself");
    spin.selectedProperty.addListener((bool was, bool now) {
        square.spinning = now;
        view.setContinuous(now);
    });

    // A menu, which opens over the view like over anything else
    view.contextMenu(new ContextMenu()
        .add(new MenuItem("Reset", { reset.fire(); }))
        .add(new MenuItem("Spin by itself", { spin.setSelected(!spin.selected); })));

    auto stage = new Stack().alignment(Pos.topLeft).grow(1);
    stage.add(view).add(how.margin(Insets(12))); // over the view's corner, which still hears the mouse elsewhere

    auto root = new Column().padding(16).spacing(12);
    root.add(stage).add(new Row().spacing(12).alignment(Pos.centreLeft).add(turned).add(reset).add(spin));
    app.scene = new Scene(root);
    app.run();
}

/// The square: its pipeline and buffers, made on the GPU it's given, and how it's turned.
final class Square
{
    float yaw = 0.5f, pitch = -0.35f;
    bool spinning;

    void setUp(GpuContext gpu)
    {
        device = gpu.device;
        queue = gpu.queue;

        // Two triangles, a colour at each corner. The colours are sRGB, as picked; the shader
        // works in linear colour, as the view encodes what it writes, so they're decoded first.
        static immutable float[3][4] corners = [[0.94f, 0.27f, 0.27f], [0.98f, 0.75f, 0.14f],
                                                [0.13f, 0.77f, 0.37f], [0.23f, 0.51f, 0.96f]];
        static immutable float[2][4] at = [[-0.6f, -0.6f], [0.6f, -0.6f], [0.6f, 0.6f], [-0.6f, 0.6f]];
        float[] vertices;
        foreach (i; [0, 1, 2, 0, 2, 3])
            vertices ~= [at[i][0], at[i][1], 0, linear(corners[i][0]), linear(corners[i][1]), linear(corners[i][2])];
        WGPUBufferDescriptor bd;
        bd.size = vertices.length * float.sizeof;
        bd.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
        vertexBuffer = wgpuDeviceCreateBuffer(device, &bd);
        wgpuQueueWriteBuffer(queue, vertexBuffer, 0, vertices.ptr, bd.size);

        bd.size = 16 * float.sizeof;
        bd.usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst;
        uniformBuffer = wgpuDeviceCreateBuffer(device, &bd);

        static immutable char[] wgsl = q{
            struct Uniforms { mvp: mat4x4f };
            @group(0) @binding(0) var<uniform> u: Uniforms;

            struct VertexOut { @builtin(position) pos: vec4f, @location(0) colour: vec3f };

            @vertex fn vs(@location(0) pos: vec3f, @location(1) colour: vec3f) -> VertexOut {
                var out: VertexOut;
                out.pos = u.mvp * vec4f(pos, 1.0);
                out.colour = colour;
                return out;
            }

            @fragment fn fs(in: VertexOut) -> @location(0) vec4f {
                return vec4f(in.colour, 1.0);
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
        entry.buffer.minBindingSize = 16 * float.sizeof;
        WGPUBindGroupLayoutDescriptor ld;
        ld.entryCount = 1;
        ld.entries = &entry;
        auto bindLayout = wgpuDeviceCreateBindGroupLayout(device, &ld);
        scope (exit) wgpuBindGroupLayoutRelease(bindLayout);

        WGPUBindGroupEntry binding;
        binding.binding = 0;
        binding.buffer = uniformBuffer;
        binding.size = 16 * float.sizeof;
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

        WGPUVertexAttribute[2] attributes;
        attributes[0].format = WGPUVertexFormat_Float32x3;
        attributes[0].offset = 0;
        attributes[0].shaderLocation = 0;
        attributes[1].format = WGPUVertexFormat_Float32x3;
        attributes[1].offset = 3 * float.sizeof;
        attributes[1].shaderLocation = 1;
        WGPUVertexBufferLayout vertexLayout;
        vertexLayout.stepMode = WGPUVertexStepMode_Vertex;
        vertexLayout.arrayStride = 6 * float.sizeof;
        vertexLayout.attributeCount = attributes.length;
        vertexLayout.attributes = attributes.ptr;

        WGPUColorTargetState target;
        target.format = gpu.format; // the view's: sRGB, so the colours above are linear
        target.writeMask = WGPUColorWriteMask_All;
        WGPUFragmentState fragment;
        __traits(getMember, fragment, "module") = shader; // `module` is a D keyword
        fragment.entryPoint = WGPUStringView("fs".ptr, 2);
        fragment.targetCount = 1;
        fragment.targets = &target;

        WGPURenderPipelineDescriptor pd;
        pd.layout = pipelineLayout;
        __traits(getMember, pd.vertex, "module") = shader;
        pd.vertex.entryPoint = WGPUStringView("vs".ptr, 2);
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers = &vertexLayout;
        pd.primitive.topology = WGPUPrimitiveTopology_TriangleList;
        pd.primitive.frontFace = WGPUFrontFace_CCW;
        pd.primitive.cullMode = WGPUCullMode_None; // its back shows too, turned round
        pd.multisample.count = 1;
        pd.multisample.mask = 0xFFFFFFFF;
        pd.fragment = &fragment;
        pipeline = wgpuDeviceCreateRenderPipeline(device, &pd);
    }

    void render(ref GpuFrame frame)
    {
        if (spinning)
            yaw = cast(float) frame.time;
        const aspect = cast(float) frame.width / frame.height;
        auto mvp = mul(perspective(PI / 4, aspect, 0.1f, 10),
                       mul(translation(0, 0, -2.6f), mul(rotationX(pitch), rotationY(yaw))));
        wgpuQueueWriteBuffer(queue, uniformBuffer, 0, mvp.ptr, mvp.sizeof);

        WGPURenderPassColorAttachment colour;
        colour.view = frame.view;
        colour.loadOp = WGPULoadOp_Clear;
        colour.storeOp = WGPUStoreOp_Store;
        colour.clearValue = WGPUColor(0.012, 0.016, 0.03, 1); // linear: a dark slate, once encoded
        colour.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        WGPURenderPassDescriptor pass;
        pass.colorAttachmentCount = 1;
        pass.colorAttachments = &colour;
        auto encoder = wgpuCommandEncoderBeginRenderPass(frame.encoder, &pass);
        wgpuRenderPassEncoderSetPipeline(encoder, pipeline);
        wgpuRenderPassEncoderSetBindGroup(encoder, 0, bindGroup, 0, null);
        // ulong.max is WGPU_WHOLE_SIZE, a C macro ImportC can't expand: all of the buffer
        wgpuRenderPassEncoderSetVertexBuffer(encoder, 0, vertexBuffer, 0, ulong.max);
        wgpuRenderPassEncoderDraw(encoder, 6, 1, 0, 0);
        wgpuRenderPassEncoderEnd(encoder);
        wgpuRenderPassEncoderRelease(encoder);
    }

    void release()
    {
        if (pipeline) wgpuRenderPipelineRelease(pipeline);
        if (bindGroup) wgpuBindGroupRelease(bindGroup);
        if (uniformBuffer) wgpuBufferRelease(uniformBuffer);
        if (vertexBuffer) wgpuBufferRelease(vertexBuffer);
        pipeline = null;
        bindGroup = null;
        uniformBuffer = vertexBuffer = null;
    }

private:
    WGPUDevice device;
    WGPUQueue queue;
    WGPURenderPipeline pipeline;
    WGPUBindGroup bindGroup;
    WGPUBuffer vertexBuffer, uniformBuffer;
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
