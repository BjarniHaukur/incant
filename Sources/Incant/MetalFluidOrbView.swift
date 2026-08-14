import MetalKit
import SwiftUI

struct MetalFluidOrbView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        if let renderer = MetalFluidRenderer(view: view) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.state = .init(
            phase: model.phase,
            energy: Float(model.level),
            motion: model.orbMotion,
            motionEnergy: model.orbMotionEnergy
        )
    }

    final class Coordinator {
        fileprivate var renderer: MetalFluidRenderer?
    }
}

private final class MetalFluidRenderer: NSObject, MTKViewDelegate {
    struct VisualState {
        var phase: UInt32
        var energy: Float
        var motion: SIMD2<Float>
        var motionEnergy: Float

        init(phase: AppModel.Phase, energy: Float, motion: SIMD2<Float>, motionEnergy: Float) {
            self.energy = energy
            self.motion = motion
            self.motionEnergy = motionEnergy
            switch phase {
            case .idle, .listening: self.phase = 0
            case .connecting: self.phase = 1
            case .finishing: self.phase = 2
            case .success: self.phase = 3
            case .error: self.phase = 4
            }
        }
    }

    private struct Uniforms {
        var dt: Float
        var time: Float
        var energy: Float
        var phase: UInt32
        var simSize: SIMD2<Float>
        var outputSize: SIMD2<Float>
        var motion: SIMD2<Float>
        var motionEnergy: Float
        var padding: Float = 0
    }

    var state = VisualState(phase: .idle, energy: 0, motion: .zero, motionEnergy: 0)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let advectVelocity: MTLComputePipelineState
    private let divergence: MTLComputePipelineState
    private let jacobi: MTLComputePipelineState
    private let project: MTLComputePipelineState
    private let advectDye: MTLComputePipelineState
    private let display: MTLComputePipelineState
    private var velocityA: MTLTexture
    private var velocityB: MTLTexture
    private var pressureA: MTLTexture
    private var pressureB: MTLTexture
    private var divergenceTexture: MTLTexture
    private var dyeA: MTLTexture
    private var dyeB: MTLTexture
    private let simulationSize = 128
    private var startTime = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private var warmupFrames = 24

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let advectVelocity = Self.pipeline("advectVelocity", library, device),
              let divergence = Self.pipeline("computeDivergence", library, device),
              let jacobi = Self.pipeline("jacobiPressure", library, device),
              let project = Self.pipeline("projectVelocity", library, device),
              let advectDye = Self.pipeline("advectDye", library, device),
              let display = Self.pipeline("renderOrb", library, device) else { return nil }

        self.device = device
        self.queue = queue
        self.advectVelocity = advectVelocity
        self.divergence = divergence
        self.jacobi = jacobi
        self.project = project
        self.advectDye = advectDye
        self.display = display

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: simulationSize,
            height: simulationSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let velocityA = device.makeTexture(descriptor: descriptor),
              let velocityB = device.makeTexture(descriptor: descriptor),
              let pressureA = device.makeTexture(descriptor: descriptor),
              let pressureB = device.makeTexture(descriptor: descriptor),
              let divergenceTexture = device.makeTexture(descriptor: descriptor),
              let dyeA = device.makeTexture(descriptor: descriptor),
              let dyeB = device.makeTexture(descriptor: descriptor) else { return nil }
        self.velocityA = velocityA
        self.velocityB = velocityB
        self.pressureA = pressureA
        self.pressureB = pressureB
        self.divergenceTexture = divergenceTexture
        self.dyeA = dyeA
        self.dyeB = dyeB
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let elapsed = Float(now - startTime)
        let realDT = Float(min(max(now - lastFrame, 1.0 / 120.0), 1.0 / 20.0))
        lastFrame = now
        let steps = warmupFrames > 0 ? 4 : 1
        warmupFrames = max(0, warmupFrames - steps)

        for index in 0..<steps {
            var uniforms = Uniforms(
                dt: warmupFrames > 0 ? 1.0 / 45.0 : realDT,
                time: elapsed - Float(steps - index) * realDT,
                energy: max(state.energy, state.phase == 4 ? 0.78 : 0.015),
                phase: state.phase,
                simSize: SIMD2(Float(simulationSize), Float(simulationSize)),
                outputSize: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                motion: state.motion,
                motionEnergy: state.motionEnergy
            )
            encodeSimulation(commandBuffer, uniforms: &uniforms)
        }

        var uniforms = Uniforms(
            dt: realDT,
            time: elapsed,
            energy: max(state.energy, state.phase == 4 ? 0.78 : 0.015),
            phase: state.phase,
            simSize: SIMD2(Float(simulationSize), Float(simulationSize)),
            outputSize: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
            motion: state.motion,
            motionEnergy: state.motionEnergy
        )
        encode(
            commandBuffer, pipeline: display,
            reads: [dyeA, velocityA, pressureA], writes: [drawable.texture],
            uniforms: &uniforms, width: drawable.texture.width, height: drawable.texture.height
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encodeSimulation(_ buffer: MTLCommandBuffer, uniforms: inout Uniforms) {
        encode(buffer, pipeline: advectVelocity, reads: [velocityA], writes: [velocityB], uniforms: &uniforms)
        encode(buffer, pipeline: divergence, reads: [velocityB], writes: [divergenceTexture], uniforms: &uniforms)
        for _ in 0..<12 {
            encode(buffer, pipeline: jacobi, reads: [pressureA, divergenceTexture], writes: [pressureB], uniforms: &uniforms)
            swap(&pressureA, &pressureB)
        }
        encode(buffer, pipeline: project, reads: [velocityB, pressureA], writes: [velocityA], uniforms: &uniforms)
        encode(buffer, pipeline: advectDye, reads: [dyeA, velocityA], writes: [dyeB], uniforms: &uniforms)
        swap(&dyeA, &dyeB)
    }

    private func encode(
        _ buffer: MTLCommandBuffer,
        pipeline: MTLComputePipelineState,
        reads: [MTLTexture],
        writes: [MTLTexture],
        uniforms: inout Uniforms,
        width: Int? = nil,
        height: Int? = nil
    ) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in reads.enumerated() { encoder.setTexture(texture, index: index) }
        for (index, texture) in writes.enumerated() { encoder.setTexture(texture, index: reads.count + index) }
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let w = width ?? simulationSize
        let h = height ?? simulationSize
        let groupWidth = min(pipeline.threadExecutionWidth, w)
        let groupHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / groupWidth, h, 8))
        encoder.dispatchThreads(
            MTLSize(width: w, height: h, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1)
        )
        encoder.endEncoding()
    }

    private static func pipeline(_ name: String, _ library: MTLLibrary, _ device: MTLDevice) -> MTLComputePipelineState? {
        guard let function = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float dt;
        float time;
        float energy;
        uint phase;
        float2 simSize;
        float2 outputSize;
        float2 motion;
        float motionEnergy;
        float padding;
    };

    constexpr sampler fluidSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 curlField(float2 p, float t, float energy) {
        float2 v = float2(0.0);
        // Alternating orthogonal shears are a classic chaotic mixer. Each
        // component is independent of its own axis, so the field remains
        // divergence-free without creating a privileged vortex center.
        for (uint i = 0; i < 7; i++) {
            float fi = float(i);
            float kx = 2.2 + fi * 1.31;
            float ky = 2.8 + fi * 1.17;
            float direction = (i & 1) == 0 ? 1.0 : -1.0;
            float phaseX = ky * p.y + direction * t * (.23 + fi * .071)
                + sin(t * (.11 + fi * .023) + fi * 1.3) * (0.7 + energy);
            float phaseY = kx * p.x - direction * t * (.29 + fi * .063)
                + cos(t * (.14 + fi * .019) - fi * .9) * (0.65 + energy);
            float amplitude = .032 / (1.0 + fi * .42);
            float gain = amplitude * (.28 + energy * (1.6 + fi * .72));
            v.x += gain * sin(phaseX);
            v.y += direction * gain * sin(phaseY);
        }
        return v;
    }

    kernel void advectVelocity(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<half, access::write> output [[texture(1)]],
        constant Uniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uint2(u.simSize))) return;
        float2 uv = (float2(gid) + .5) / u.simSize;
        float2 velocity = source.sample(fluidSampler, uv).xy;
        float2 previous = uv - velocity * u.dt * (1.18 + u.energy * .42);
        float2 advected = source.sample(fluidSampler, previous).xy * pow(.988, u.dt * 60.0);
        float2 p = (uv - .5) * 2.0;
        float stateGain = u.phase == 1 ? .6 + .4 * sin(u.time * 2.4) : 1.0;
        advected += curlField(p, u.time, u.energy) * u.dt * stateGain;

        // Moving the window accelerates its glass shell while the fluid lags
        // behind. A soft spatial envelope turns that inertia into pressure;
        // paired, noisy transverse wakes keep the response turbulent rather
        // than sliding the texture rigidly across the sphere.
        float2 drag = float2(u.motion.x, -u.motion.y);
        float motionEnvelope = 1.0 - smoothstep(.62, 1.08, length(p));
        float wake = sin(dot(p, float2(7.3, -5.1)) + u.time * 5.7)
            * cos(dot(p, float2(3.9, 8.2)) - u.time * 3.8);
        float2 transverse = float2(-drag.y, drag.x);
        float2 inertialForce = -drag * (.9 + .42 * wake);
        float2 turbulentWake = transverse * wake * .7;
        advected += (inertialForce + turbulentWake) * u.motionEnergy * motionEnvelope * u.dt * 1.35;

        float edge = length(p);
        if (edge > .72) advected -= p * smoothstep(.72, 1.0, edge) * .025;
        output.write(half4(half2(clamp(advected, -.8, .8)), 0, 1), gid);
    }

    kernel void computeDivergence(
        texture2d<float, access::read> velocity [[texture(0)]],
        texture2d<half, access::write> output [[texture(1)]],
        constant Uniforms &u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (any(g >= uint2(u.simSize))) return;
        uint2 hi = uint2(u.simSize) - 1;
        float l = velocity.read(uint2(max(int(g.x) - 1, 0), g.y)).x;
        float r = velocity.read(uint2(min(g.x + 1, hi.x), g.y)).x;
        float b = velocity.read(uint2(g.x, max(int(g.y) - 1, 0))).y;
        float t = velocity.read(uint2(g.x, min(g.y + 1, hi.y))).y;
        output.write(half4(half(.5 * (r - l + t - b)), 0, 0, 1), g);
    }

    kernel void jacobiPressure(
        texture2d<float, access::read> pressure [[texture(0)]],
        texture2d<float, access::read> divergence [[texture(1)]],
        texture2d<half, access::write> output [[texture(2)]],
        constant Uniforms &u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (any(g >= uint2(u.simSize))) return;
        uint2 hi = uint2(u.simSize) - 1;
        float l = pressure.read(uint2(max(int(g.x) - 1, 0), g.y)).x;
        float r = pressure.read(uint2(min(g.x + 1, hi.x), g.y)).x;
        float b = pressure.read(uint2(g.x, max(int(g.y) - 1, 0))).x;
        float t = pressure.read(uint2(g.x, min(g.y + 1, hi.y))).x;
        float p = (l + r + b + t - divergence.read(g).x) * .25;
        output.write(half4(half(p), 0, 0, 1), g);
    }

    kernel void projectVelocity(
        texture2d<float, access::read> velocity [[texture(0)]],
        texture2d<float, access::read> pressure [[texture(1)]],
        texture2d<half, access::write> output [[texture(2)]],
        constant Uniforms &u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (any(g >= uint2(u.simSize))) return;
        uint2 hi = uint2(u.simSize) - 1;
        float l = pressure.read(uint2(max(int(g.x) - 1, 0), g.y)).x;
        float r = pressure.read(uint2(min(g.x + 1, hi.x), g.y)).x;
        float b = pressure.read(uint2(g.x, max(int(g.y) - 1, 0))).x;
        float t = pressure.read(uint2(g.x, min(g.y + 1, hi.y))).x;
        float2 v = velocity.read(g).xy - .5 * float2(r - l, t - b);
        output.write(half4(half2(v), 0, 1), g);
    }

    kernel void advectDye(
        texture2d<float, access::sample> dye [[texture(0)]],
        texture2d<float, access::sample> velocity [[texture(1)]],
        texture2d<half, access::write> output [[texture(2)]],
        constant Uniforms &u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (any(g >= uint2(u.simSize))) return;
        float2 uv = (float2(g) + .5) / u.simSize;
        float2 v = velocity.sample(fluidSampler, uv).xy;
        float2 previous = uv - v * u.dt * (1.2 + u.energy * .45);
        float3 centerDye = dye.sample(fluidSampler, previous).rgb;
        float2 texel = 1.0 / u.simSize;
        float3 neighboringDye = (
            dye.sample(fluidSampler, previous + float2(texel.x, 0)).rgb
            + dye.sample(fluidSampler, previous - float2(texel.x, 0)).rgb
            + dye.sample(fluidSampler, previous + float2(0, texel.y)).rgb
            + dye.sample(fluidSampler, previous - float2(0, texel.y)).rgb
        ) * .25;
        float diffusion = .055 + u.energy * .035;
        float3 density = mix(centerDye, neighboringDye, diffusion) * pow(.988, u.dt * 60.0);
        // Continuous dye sheets are folded by the projected velocity field.
        // Their different slopes and drift rates prevent a single spiral from
        // becoming the composition's dominant gesture.
        float sheet0 = exp(-pow((uv.y - .34) - .1 * sin(uv.x * 11.0 + u.time * .19), 2.0) / .0011);
        float sheet1 = exp(-pow((uv.x - .68) - .12 * sin(uv.y * 9.0 - u.time * .13 + 1.7), 2.0) / .0014);
        float diagonal = (uv.x + uv.y - 1.18) - .08 * sin((uv.x - uv.y) * 12.0 + u.time * .09);
        float sheet2 = exp(-(diagonal * diagonal) / .0019);
        density += float3(sheet0, sheet1, sheet2) * (.22 + u.energy * .12) * u.dt;
        output.write(half4(half3(clamp(density, 0.0, 3.0)), 1), g);
    }

    float3 palette(float3 dye, uint phase) {
        float3 a = float3(.02, .22, .72);
        float3 b = float3(.02, .72, 1.0);
        float3 c = float3(.26, .08, .58);
        if (phase == 1) { a = float3(.18, .12, .7); b = float3(.48, .3, 1.0); c = float3(.04, .32, .88); }
        if (phase == 2) { a *= .72; b *= .68; c *= .78; }
        if (phase == 3) { a = float3(.02, .42, .62); b = float3(.06, 1.0, .72); c = float3(.08, .48, .9); }
        if (phase == 4) { a = float3(.72, .015, .005); b = float3(1.0, .14, .015); c = float3(.48, .0, .08); }
        return dye.r * a + dye.g * b + dye.b * c;
    }

    kernel void renderOrb(
        texture2d<float, access::sample> dye [[texture(0)]],
        texture2d<float, access::sample> velocity [[texture(1)]],
        texture2d<float, access::sample> pressure [[texture(2)]],
        texture2d<half, access::write> output [[texture(3)]],
        constant Uniforms &u [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
        if (any(g >= uint2(u.outputSize))) return;
        float2 uv = (float2(g) + .5) / u.outputSize;
        float aspect = u.outputSize.x / u.outputSize.y;
        float2 q = (uv - .5) * 2.0;
        q.x *= aspect;
        float r2 = dot(q, q);
        float aa = 2.5 / min(u.outputSize.x, u.outputSize.y);
        float alpha = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, sqrt(r2));
        if (alpha <= 0) { output.write(half4(0), g); return; }

        float z = sqrt(max(0.0, 1.0 - r2));
        float2 sphereUV = .5 + q * (.37 + .09 * z);
        float2 flow = velocity.sample(fluidSampler, sphereUV).xy;
        float2 refracted = sphereUV + flow * (.028 + .025 * (1.0 - z));

        // Projection pressure is the bridge from dynamics to light. Voice
        // drives the flow; compressed regions then illuminate the gas rather
        // than audio amplitude directly turning up the palette.
        float pressureTexel = 1.0 / u.simSize.x;
        float pressureCenter = pressure.sample(fluidSampler, sphereUV).x;
        float pressureX = pressure.sample(fluidSampler, sphereUV + float2(pressureTexel, 0)).x
            - pressure.sample(fluidSampler, sphereUV - float2(pressureTexel, 0)).x;
        float pressureY = pressure.sample(fluidSampler, sphereUV + float2(0, pressureTexel)).x
            - pressure.sample(fluidSampler, sphereUV - float2(0, pressureTexel)).x;
        float pressureSignal = clamp(abs(pressureCenter) * 16.0 + length(float2(pressureX, pressureY)) * 42.0, 0.0, 1.0);

        // Front-to-back integration through seven moving depth planes. Each
        // layer has parallax, absorption and a slightly different fluid
        // coordinate, creating a real volume inside the spherical shell.
        float3 light = float3(0.0);
        float transmittance = 1.0;
        float density = 0.0;
        for (uint i = 0; i < 7; i++) {
            float depth = (float(i) / 6.0) * 2.0 - 1.0;
            float2 parallax = flow * depth * .075;
            float2 layerUV = refracted + parallax;
            layerUV += float2(sin(u.time * .037 + depth * 2.7), cos(u.time * .029 - depth * 1.9)) * .022 * depth;
            float3 layerDye = dye.sample(fluidSampler, layerUV).rgb;
            float layerDensity = dot(layerDye, float3(.22, .31, .25));
            float absorption = 1.0 - exp(-layerDensity * .38);
            light += transmittance * palette(layerDye, u.phase) * (.13 + absorption * .34);
            transmittance *= 1.0 - absorption * .48;
            density += layerDensity;
        }
        // Dye-interface gradients are the naturally illuminated streaks in a
        // mixing fluid. Emphasizing them reveals folds without inventing
        // sparkles, stars, or unrelated decoration.
        float texel = 1.0 / u.simSize.x;
        float3 dyeLeft = dye.sample(fluidSampler, refracted - float2(texel, 0)).rgb;
        float3 dyeRight = dye.sample(fluidSampler, refracted + float2(texel, 0)).rgb;
        float3 dyeDown = dye.sample(fluidSampler, refracted - float2(0, texel)).rgb;
        float3 dyeUp = dye.sample(fluidSampler, refracted + float2(0, texel)).rgb;
        float3 interfaces = abs(dyeRight - dyeLeft) + abs(dyeUp - dyeDown);
        light += palette(interfaces, u.phase) * (.72 + pressureSignal * .62);
        light = 1.0 - exp(-light * (2.0 + u.energy * .12));

        float3 base = u.phase == 4 ? float3(.028, .001, .002) : float3(.0015, .006, .024);
        float3 color = base + light * (.62 + .82 * z) * (1.0 + pressureSignal * .2);
        color *= .22 + .78 * pow(z, .62); // heavy glass absorption at the limb
        color *= .78 + .22 * exp(-density * .35); // dark density occlusion

        float3 normal = normalize(float3(q, z));
        float3 halfVector = normalize(float3(-.45, -.55, 1.5));
        float specular = pow(max(dot(normal, halfVector), 0.0), 85.0) * .12;
        float fresnel = pow(1.0 - z, 4.0) * .16;
        color += specular + fresnel * (u.phase == 4 ? float3(.22, .01, .005) : float3(.025, .09, .18));
        color = pow(max(color, 0.0), float3(.82));
        output.write(half4(half3(color), half(alpha)), g);
    }
    """#
}
