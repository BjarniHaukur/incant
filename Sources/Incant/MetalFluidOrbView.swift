import MetalKit
import SwiftUI

/// Per-session randomization for the fluid. The dye sheets, the curl field and
/// the dissipation rates used to be compile-time constants starting from a fluid
/// at rest, so every session bloomed into the same composition. Now a session
/// begins from random vorticity and random dye, and every parameter of its
/// character — orientation, thickness, waviness, drift, chirality, decay — is
/// derived in the shader from `salt`.
struct OrbSeed: Equatable {
    /// The 32-bit roll every derived parameter hangs off.
    var salt: UInt32
    /// Slides the whole field's phase, so even one salt never repeats a moment.
    var phaseOffset: Float
    /// Strength of the initial swirl the fluid starts with.
    var vorticity: Float
    /// Density of the dye the fluid starts with.
    var dyeAmount: Float

    static func random() -> OrbSeed {
        OrbSeed(
            salt: .random(in: UInt32.min...UInt32.max),
            phaseOffset: .random(in: 0..<600),
            vorticity: .random(in: 0.25...1.15),
            dyeAmount: .random(in: 0.3...1.5)
        )
    }
}

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
            motionEnergy: model.orbMotionEnergy,
            seed: model.orbSeed
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
        var seed: OrbSeed

        init(
            phase: AppModel.Phase,
            energy: Float,
            motion: SIMD2<Float>,
            motionEnergy: Float,
            seed: OrbSeed
        ) {
            self.energy = energy
            self.motion = motion
            self.motionEnergy = motionEnergy
            self.seed = seed
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
        var salt: UInt32
        var phaseOffset: Float
        var vorticity: Float
        var dyeSeedAmount: Float
        var impulse: Float
        var impulseWidth: Float
        var impulseCenter: SIMD2<Float>
        var impulseSpin: Float
        var impulsePush: Float
    }

    var state = VisualState(
        phase: .idle,
        energy: 0,
        motion: .zero,
        motionEnergy: 0,
        seed: .random()
    )

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let advectVelocity: MTLComputePipelineState
    private let divergence: MTLComputePipelineState
    private let jacobi: MTLComputePipelineState
    private let project: MTLComputePipelineState
    private let advectDye: MTLComputePipelineState
    private let display: MTLComputePipelineState
    private let clearField: MTLComputePipelineState
    private let seedVelocity: MTLComputePipelineState
    private let seedDye: MTLComputePipelineState
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
    private var activeSeed: OrbSeed?
    /// The voice level the fluid is actually driven by, and the onset spike
    /// taken from it. A fluid integrates its forcing over seconds, which is far
    /// too slow to feel like listening, so speech is followed twice: an envelope
    /// that rises almost instantly and falls smoothly, and an impulse that fires
    /// when the level jumps above that envelope.
    private var envelope: Float = 0
    private var impulse: Float = 0
    /// Where the current syllable landed and what it did there. Rolled fresh on
    /// every onset: a fixed shove in a fixed place made every word feel like the
    /// same button being pressed.
    private var impulseCenter = SIMD2<Float>.zero
    private var impulseWidth: Float = 0.3
    private var impulseSpin: Float = 0
    private var impulsePush: Float = 0

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let advectVelocity = Self.pipeline("advectVelocity", library, device),
              let divergence = Self.pipeline("computeDivergence", library, device),
              let jacobi = Self.pipeline("jacobiPressure", library, device),
              let project = Self.pipeline("projectVelocity", library, device),
              let advectDye = Self.pipeline("advectDye", library, device),
              let display = Self.pipeline("renderOrb", library, device),
              let clearField = Self.pipeline("clearField", library, device),
              let seedVelocity = Self.pipeline("seedVelocity", library, device),
              let seedDye = Self.pipeline("seedDye", library, device) else { return nil }

        self.device = device
        self.queue = queue
        self.advectVelocity = advectVelocity
        self.divergence = divergence
        self.jacobi = jacobi
        self.project = project
        self.advectDye = advectDye
        self.display = display
        self.clearField = clearField
        self.seedVelocity = seedVelocity
        self.seedDye = seedDye

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
        if state.seed != activeSeed {
            activeSeed = state.seed
            startTime = now
            lastFrame = now
            warmupFrames = 24
            encodeInitialConditions(commandBuffer)
        }
        let elapsed = Float(now - startTime)
        let realDT = Float(min(max(now - lastFrame, 1.0 / 120.0), 1.0 / 20.0))
        lastFrame = now
        trackVoice(dt: realDT)
        let steps = warmupFrames > 0 ? 4 : 1
        warmupFrames = max(0, warmupFrames - steps)

        let outputSize = SIMD2(Float(drawable.texture.width), Float(drawable.texture.height))
        for index in 0..<steps {
            var uniforms = makeUniforms(
                dt: warmupFrames > 0 ? 1.0 / 45.0 : realDT,
                time: elapsed - Float(steps - index) * realDT,
                outputSize: outputSize
            )
            encodeSimulation(commandBuffer, uniforms: &uniforms)
        }

        var uniforms = makeUniforms(dt: realDT, time: elapsed, outputSize: outputSize)
        encode(
            commandBuffer, pipeline: display,
            reads: [dyeA, velocityA, pressureA], writes: [drawable.texture],
            uniforms: &uniforms, width: drawable.texture.width, height: drawable.texture.height
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Follows the voice at frame rate rather than at the audio callback's, so
    /// the attack and decay stay the same however the level happens to arrive.
    private func trackVoice(dt: Float) {
        let level = max(state.energy, state.phase == 4 ? 0.78 : 0.015)
        // How far the voice has jumped above where it has been sitting: the
        // start of a syllable, not its loudness.
        let onset: Float = max(0, level - envelope)
        let rate: Float = level > envelope ? 26 : 5.5
        let follow: Float = min(1, dt * rate)
        envelope += (level - envelope) * follow
        let decayed: Float = impulse * pow(0.02, dt)
        let fired: Float = min(1, onset * 3.4)
        if fired > decayed { rollImpulse() }
        impulse = max(decayed, fired)
    }

    /// Somewhere new, at a new size, pushing or pulling, wound either way.
    private func rollImpulse() {
        let angle = Float.random(in: 0..<(2 * .pi))
        let radius = Float.random(in: 0...1).squareRoot() * 0.66
        impulseCenter = SIMD2(cos(angle), sin(angle)) * radius
        impulseWidth = .random(in: 0.15...0.46)
        impulseSpin = .random(in: -1...1)
        let strength = Float.random(in: 0.4...1)
        impulsePush = Bool.random() ? strength : -strength
    }

    private func makeUniforms(dt: Float, time: Float, outputSize: SIMD2<Float>) -> Uniforms {
        Uniforms(
            dt: dt,
            time: time,
            energy: max(envelope, state.phase == 4 ? 0.78 : 0.015),
            phase: state.phase,
            simSize: SIMD2(Float(simulationSize), Float(simulationSize)),
            outputSize: outputSize,
            motion: state.motion,
            motionEnergy: state.motionEnergy,
            salt: state.seed.salt,
            phaseOffset: state.seed.phaseOffset,
            vorticity: state.seed.vorticity,
            dyeSeedAmount: state.seed.dyeAmount,
            impulse: impulse,
            impulseWidth: impulseWidth,
            impulseCenter: impulseCenter,
            impulseSpin: impulseSpin,
            impulsePush: impulsePush
        )
    }

    /// A session starts from a random swirl carrying random dye rather than from
    /// a fluid at rest, which is what made every previous session open the same
    /// way. Pressure and the scratch textures start clean so the first
    /// projection has only the seeded velocity to work with.
    private func encodeInitialConditions(_ buffer: MTLCommandBuffer) {
        var uniforms = makeUniforms(dt: 0, time: 0, outputSize: .zero)
        encode(buffer, pipeline: seedVelocity, reads: [], writes: [velocityA], uniforms: &uniforms)
        encode(buffer, pipeline: seedDye, reads: [], writes: [dyeA], uniforms: &uniforms)
        for texture in [velocityB, pressureA, pressureB, divergenceTexture, dyeB] {
            encode(buffer, pipeline: clearField, reads: [], writes: [texture], uniforms: &uniforms)
        }
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
        uint salt;
        float phaseOffset;
        float vorticity;
        float dyeSeedAmount;
        float impulse;
        float impulseWidth;
        float2 impulseCenter;
        float impulseSpin;
        float impulsePush;
    };

    constexpr sampler fluidSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // Every per-session parameter hangs off one 32-bit salt the app rolls fresh
    // for each dictation. Slots are fixed addresses into that roll, so a salt
    // reproduces a session exactly while neighbouring salts share nothing.
    uint wangHash(uint x) {
        x = (x ^ 61u) ^ (x >> 16);
        x *= 9u;
        x = x ^ (x >> 4);
        x *= 0x27d4eb2du;
        x = x ^ (x >> 15);
        return x;
    }

    float saltedUnit(uint salt, uint slot) {
        return float(wangHash(salt ^ (slot * 0x9e3779b9u))) * (1.0 / 4294967296.0);
    }

    float salted(uint salt, uint slot, float low, float high) {
        return mix(low, high, saltedUnit(salt, slot));
    }

    float latticeNoise(float2 p, uint salt) {
        int2 cell = int2(floor(p));
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float corners[4];
        for (uint i = 0; i < 4; i++) {
            int2 corner = cell + int2(int(i & 1u), int(i >> 1u));
            uint hashed = wangHash(
                uint(corner.x + 8192) * 73856093u
                ^ uint(corner.y + 8192) * 19349663u
                ^ salt
            );
            corners[i] = float(hashed) * (1.0 / 4294967296.0);
        }
        return mix(mix(corners[0], corners[1], f.x), mix(corners[2], corners[3], f.x), f.y);
    }

    float2 curlField(float2 p, float t, float energy, uint salt) {
        float2 v = float2(0.0);
        float wavenumber = salted(salt, 40, .55, 1.95);
        float churn = salted(salt, 41, .5, 2.1);
        float chirality = saltedUnit(salt, 42) < .5 ? -1.0 : 1.0;
        // Alternating orthogonal shears are a classic chaotic mixer. Each
        // component is independent of its own axis, so the field remains
        // divergence-free without creating a privileged vortex center.
        for (uint i = 0; i < 7; i++) {
            float fi = float(i);
            float kx = (2.2 + fi * 1.31) * wavenumber;
            float ky = (2.8 + fi * 1.17) * wavenumber;
            float direction = ((i & 1) == 0 ? 1.0 : -1.0) * chirality;
            float offset = salted(salt, 44 + i, 0.0, 6.2831853);
            float phaseX = ky * p.y + direction * t * (.23 + fi * .071) * churn
                + sin(t * (.11 + fi * .023) * churn + fi * 1.3 + offset) * (0.7 + energy);
            float phaseY = kx * p.x - direction * t * (.29 + fi * .063) * churn
                + cos(t * (.14 + fi * .019) * churn - fi * .9 - offset) * (0.65 + energy);
            // The lowest octave is a single cell the width of the sphere, so at
            // full weight it organises everything around the middle no matter
            // what the rest of the field does. Held back, the finer octaves
            // decide the composition instead.
            float amplitude = .032 / (1.0 + fi * .42) * (i == 0 ? .5 : 1.0);
            float gain = amplitude * (1.25 + energy * (2.6 + fi * .9));
            v.x += gain * sin(phaseX);
            v.y += direction * gain * sin(phaseY);
        }
        return v;
    }

    // The basin the session settles into. Three vortex cores at seeded places,
    // each with its own handedness, strength and slow wander, so the fluid has a
    // different large-scale attractor every time — the shear field alone always
    // organised itself around the centre of the sphere. A swirl whose speed
    // depends only on the distance from its own core adds no divergence, so this
    // costs the projection nothing.
    float2 seededBasin(float2 p, uint salt, float t) {
        float2 v = float2(0.0);
        for (uint i = 0; i < 3; i++) {
            uint slot = 80 + i * 6;
            float angle = salted(salt, slot, 0.0, 6.2831853);
            float2 core = float2(cos(angle), sin(angle)) * salted(salt, slot + 1, .1, .72);
            core += float2(
                sin(t * salted(salt, slot + 2, .3, .72) + float(i) * 2.1),
                cos(t * salted(salt, slot + 3, .3, .72) - float(i) * 1.7)
            ) * .14;
            float spin = salted(salt, slot + 4, .3, 1.0)
                * (saltedUnit(salt, slot + 5) < .5 ? -1.0 : 1.0);
            float2 d = p - core;
            float extent = .5;
            v += float2(-d.y, d.x) * spin * exp(-dot(d, d) / (extent * extent)) * .06;
        }
        return v;
    }

    kernel void clearField(
        texture2d<half, access::write> output [[texture(0)]],
        constant Uniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uint2(u.simSize))) return;
        output.write(half4(0), gid);
    }

    // The curl of a noise potential is divergence-free by construction, so the
    // fluid can open on a random swirl the projection has nothing to undo.
    kernel void seedVelocity(
        texture2d<half, access::write> output [[texture(0)]],
        constant Uniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uint2(u.simSize))) return;
        float2 uv = (float2(gid) + .5) / u.simSize;
        float scale = salted(u.salt, 60, 1.8, 5.5);
        float epsilon = .3 / scale;
        float2 p = uv * scale;
        float dx = latticeNoise(p + float2(epsilon, 0), u.salt) - latticeNoise(p - float2(epsilon, 0), u.salt);
        float dy = latticeNoise(p + float2(0, epsilon), u.salt) - latticeNoise(p - float2(0, epsilon), u.salt);
        float2 velocity = float2(dy, -dx) / (2.0 * epsilon) * u.vorticity * .14;
        float envelope = 1.0 - smoothstep(.58, 1.0, length((uv - .5) * 2.0));
        output.write(half4(half2(clamp(velocity * envelope, -.8, .8)), 0, 1), gid);
    }

    // Three independent noise fields, one per dye channel, so the palette starts
    // unevenly mixed instead of blooming out of an empty sphere.
    kernel void seedDye(
        texture2d<half, access::write> output [[texture(0)]],
        constant Uniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uint2(u.simSize))) return;
        float2 uv = (float2(gid) + .5) / u.simSize;
        float3 density = float3(0.0);
        for (uint i = 0; i < 3; i++) {
            float scale = salted(u.salt, 64 + i, 1.5, 6.5);
            float2 drift = float2(salted(u.salt, 68 + i, 0.0, 16.0), salted(u.salt, 72 + i, 0.0, 16.0));
            float threshold = salted(u.salt, 76 + i, .22, .48);
            float noise = latticeNoise(uv * scale + drift, u.salt ^ ((i + 1u) * 0x85ebca6bu));
            density[i] = pow(max(noise - threshold, 0.0) / (1.0 - threshold), 1.5) * u.dyeSeedAmount;
        }
        float envelope = 1.0 - smoothstep(.5, 1.0, length((uv - .5) * 2.0));
        output.write(half4(half3(clamp(density * envelope * 1.1, 0.0, 3.0)), 1), gid);
    }

    kernel void advectVelocity(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<half, access::write> output [[texture(1)]],
        constant Uniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= uint2(u.simSize))) return;
        float t = u.time + u.phaseOffset;
        float2 uv = (float2(gid) + .5) / u.simSize;
        float2 velocity = source.sample(fluidSampler, uv).xy;
        float2 previous = uv - velocity * u.dt * (1.18 + u.energy * .42);
        float2 advected = source.sample(fluidSampler, previous).xy
            * pow(salted(u.salt, 30, .982, .993), u.dt * 60.0);
        float2 p = (uv - .5) * 2.0;
        float stateGain = u.phase == 1 ? .6 + .4 * sin(u.time * 2.4) : 1.0;
        advected += (curlField(p, t, u.energy, u.salt)
            + seededBasin(p, u.salt, t) * (1.0 + u.energy * 1.0)) * u.dt * stateGain;

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

        // A syllable has to be felt before the fluid could carry it anywhere, so
        // the onset shoves the fluid directly — but at a place, a size, a
        // handedness and a sign rolled for that syllable alone. Pushing spreads
        // dye and compresses the surrounding fluid, which the projection turns
        // into the pressure the render reads as light; pulling drags it back and
        // hollows the same spot out. A fixed ring in the middle did neither, it
        // just repeated.
        float2 fromImpulse = p - u.impulseCenter;
        float impulseDistance2 = dot(fromImpulse, fromImpulse);
        float impulseFalloff = exp(-impulseDistance2 / (u.impulseWidth * u.impulseWidth));
        float2 outward = impulseDistance2 > 1e-6
            ? fromImpulse * rsqrt(impulseDistance2)
            : float2(0.0);
        float2 around = float2(-outward.y, outward.x);
        advected += (outward * u.impulsePush * .85 + around * u.impulseSpin * 1.15)
            * u.impulse * impulseFalloff * u.dt * 6.5;

        // Containment used to be purely inward, which is a permanent pull toward
        // the middle. Most of it is now shear along the limb, wound per session.
        float edge = length(p);
        if (edge > .72) {
            float containment = smoothstep(.72, 1.0, edge);
            float rimSpin = saltedUnit(u.salt, 100) < .5 ? -1.0 : 1.0;
            advected -= p * containment * .009;
            advected += float2(-p.y, p.x) * rimSpin * containment * salted(u.salt, 101, .012, .04);
        }
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
        float t = u.time + u.phaseOffset;
        float2 uv = (float2(g) + .5) / u.simSize;
        float2 v = velocity.sample(fluidSampler, uv).xy;
        float2 previous = uv - v * u.dt * (salted(u.salt, 31, .95, 1.55) + u.energy * .45);
        float3 centerDye = dye.sample(fluidSampler, previous).rgb;
        float2 texel = 1.0 / u.simSize;
        float3 neighboringDye = (
            dye.sample(fluidSampler, previous + float2(texel.x, 0)).rgb
            + dye.sample(fluidSampler, previous - float2(texel.x, 0)).rgb
            + dye.sample(fluidSampler, previous + float2(0, texel.y)).rgb
            + dye.sample(fluidSampler, previous - float2(0, texel.y)).rgb
        ) * .25;
        float diffusion = salted(u.salt, 32, .03, .085) + u.energy * .035;
        float3 density = mix(centerDye, neighboringDye, diffusion)
            * pow(salted(u.salt, 33, .980, .992), u.dt * 60.0);

        // One continuous dye sheet per channel, folded by the projected velocity
        // field. Orientation, offset, thickness, waviness and drift are all
        // rolled per session, so the composition has no fixed skeleton for the
        // eye to recognise from one dictation to the next.
        float3 injection = float3(0.0);
        float2 centered = uv - .5;
        for (uint i = 0; i < 3; i++) {
            uint slot = i * 8u;
            float angle = salted(u.salt, slot + 1, 0.0, 6.2831853);
            float2 normal = float2(cos(angle), sin(angle));
            float2 along = float2(-normal.y, normal.x);
            float wave = salted(u.salt, slot + 2, .02, .2)
                * sin(dot(centered, along) * salted(u.salt, slot + 3, 4.0, 17.0)
                      + t * salted(u.salt, slot + 4, -.42, .42));
            float distance = dot(centered, normal) - salted(u.salt, slot + 5, -.3, .3) - wave;
            float thickness = salted(u.salt, slot + 6, .0007, .0042);
            injection[i] = exp(-(distance * distance) / thickness) * salted(u.salt, slot + 7, .45, 1.5);
        }
        // Volume pumps dye. Silence trickles, speech pours, and an onset dumps a
        // burst in on the frame it arrives.
        density += injection * (.16 + u.energy * .22 + u.impulse * .28) * u.dt;
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
        // Exposure follows the voice directly. Everything else here has to wait
        // for the fluid to move; this lands on the frame the sound does, and is
        // what makes the orb read as listening rather than merely running.
        light = 1.0 - exp(-light * (1.4 + u.energy * 1.15 + u.impulse * .85));

        float3 base = u.phase == 4 ? float3(.028, .001, .002) : float3(.0015, .006, .024);
        float3 color = base + light * (.62 + .82 * z) * (1.0 + pressureSignal * (.2 + u.impulse * .9));
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
