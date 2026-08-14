import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// Renders the README's orb animation headlessly, on a transparent background.
// The Metal source is read out of MetalFluidOrbView.swift rather than copied, so
// the animation can never drift away from what the app actually draws, and the
// voice envelope is the same one AppModel.startVisualPreview feeds the orb.
//
//   swift Resources/make-orb-gif.swift docs/orb.webp  # soft alpha, smallest (needs img2webp)
//   swift Resources/make-orb-gif.swift docs/orb.png   # soft alpha, APNG, no dependencies
//   swift Resources/make-orb-gif.swift docs/orb.gif   # 1-bit alpha: hard edge, no glow

let canvas = 320            // final animation edge, in pixels
let supersample = 2         // render larger, then box-filter down
let orbFraction = 0.70      // orb diameter as a fraction of the canvas
let fps = 30                // the app's own preferredFramesPerSecond
let loopFrames = 120        // 4s loop
let crossfadeFrames = 18    // tail blended back over the head to close the loop
let prerollFrames = 210     // let the dye develop before the first kept frame

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputURL = URL(
    filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/orb.png",
    relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
)
let format = outputURL.pathExtension.lowercased()

func fail(_ message: String) -> Never {
    fputs("make-orb-gif: \(message)\n", stderr)
    exit(1)
}

// MARK: - Shader source, lifted from the app

let viewSource = try String(
    contentsOf: root.appending(path: "Sources/Incant/MetalFluidOrbView.swift"),
    encoding: .utf8
)
guard let open = viewSource.range(of: "#\"\"\""),
      let close = viewSource.range(of: "\"\"\"#", range: open.upperBound..<viewSource.endIndex) else {
    fail("could not find the raw shader literal in MetalFluidOrbView.swift")
}
let shaderSource = String(viewSource[open.upperBound..<close.lowerBound])

// MARK: - Metal setup, mirroring MetalFluidRenderer

struct Uniforms {
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
}

// The app rolls a fresh seed for every session. The README keeps one fixed roll
// so the committed animation stays reproducible; pass another salt to shop for a
// composition: `swift Resources/make-orb-gif.swift docs/orb.png 12345`.
let salt = CommandLine.arguments.count > 2 ? (UInt32(CommandLine.arguments[2]) ?? 0) : 704_133_209
let vorticity: Float = 0.85
let dyeSeedAmount: Float = 0.95

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fail("no Metal device")
}
let library = try device.makeLibrary(source: shaderSource, options: nil)
func pipeline(_ name: String) throws -> MTLComputePipelineState {
    guard let function = library.makeFunction(name: name) else { fail("missing kernel \(name)") }
    return try device.makeComputePipelineState(function: function)
}
let advectVelocity = try pipeline("advectVelocity")
let computeDivergence = try pipeline("computeDivergence")
let jacobiPressure = try pipeline("jacobiPressure")
let projectVelocity = try pipeline("projectVelocity")
let advectDye = try pipeline("advectDye")
let renderOrb = try pipeline("renderOrb")
let clearField = try pipeline("clearField")
let seedVelocity = try pipeline("seedVelocity")
let seedDye = try pipeline("seedDye")

let simulationSize = 128
func simTexture() -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: simulationSize,
        height: simulationSize,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else { fail("out of texture memory") }
    return texture
}
var velocityA = simTexture()
var velocityB = simTexture()
var pressureA = simTexture()
var pressureB = simTexture()
let divergenceTexture = simTexture()
var dyeA = simTexture()
var dyeB = simTexture()

let orbPixels = Int((Double(canvas) * orbFraction).rounded()) * supersample
let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm,
    width: orbPixels,
    height: orbPixels,
    mipmapped: false
)
outputDescriptor.usage = [.shaderWrite, .shaderRead]
outputDescriptor.storageMode = .shared
guard let orbTexture = device.makeTexture(descriptor: outputDescriptor) else { fail("out of texture memory") }

func encode(
    _ buffer: MTLCommandBuffer,
    _ pipeline: MTLComputePipelineState,
    reads: [MTLTexture],
    writes: [MTLTexture],
    uniforms: inout Uniforms,
    size: Int
) {
    guard let encoder = buffer.makeComputeCommandEncoder() else { return }
    encoder.setComputePipelineState(pipeline)
    for (index, texture) in reads.enumerated() { encoder.setTexture(texture, index: index) }
    for (index, texture) in writes.enumerated() { encoder.setTexture(texture, index: reads.count + index) }
    encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    let groupWidth = min(pipeline.threadExecutionWidth, size)
    let groupHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / groupWidth, size, 8))
    encoder.dispatchThreads(
        MTLSize(width: size, height: size, depth: 1),
        threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1)
    )
    encoder.endEncoding()
}

// MARK: - Frame rendering

let dt = Float(1.0) / Float(fps)
/// AppModel.startVisualPreview's synthetic voice level.
func voiceLevel(at time: Float) -> Float {
    min(0.2 + abs(sin(time * 2.1)) * 0.48 + abs(sin(time * 5.7)) * 0.18, 1)
}

let orbBytesPerRow = orbPixels * 4
var orbBytes = [UInt8](repeating: 0, count: orbBytesPerRow * orbPixels)
/// Straight-alpha RGBA of the orb for one frame, at supersampled resolution.
var renderedFrames: [[Float]] = []
let totalFrames = loopFrames + crossfadeFrames

func makeUniforms(dt: Float, time: Float) -> Uniforms {
    Uniforms(
        dt: dt,
        time: time,
        energy: max(voiceLevel(at: time), 0.015),
        phase: 0,
        simSize: SIMD2(Float(simulationSize), Float(simulationSize)),
        outputSize: SIMD2(Float(orbPixels), Float(orbPixels)),
        motion: .zero,
        motionEnergy: 0,
        salt: salt,
        phaseOffset: 0,
        vorticity: vorticity,
        dyeSeedAmount: dyeSeedAmount
    )
}

// The same random initial conditions the app starts a session from, held fixed
// by the salt above.
do {
    guard let buffer = queue.makeCommandBuffer() else { fail("no command buffer") }
    var uniforms = makeUniforms(dt: 0, time: 0)
    encode(buffer, seedVelocity, reads: [], writes: [velocityA], uniforms: &uniforms, size: simulationSize)
    encode(buffer, seedDye, reads: [], writes: [dyeA], uniforms: &uniforms, size: simulationSize)
    for texture in [velocityB, pressureA, pressureB, divergenceTexture, dyeB] {
        encode(buffer, clearField, reads: [], writes: [texture], uniforms: &uniforms, size: simulationSize)
    }
    buffer.commit()
    buffer.waitUntilCompleted()
}

for step in 0..<(prerollFrames + totalFrames) {
    let time = Float(step) * dt
    var uniforms = makeUniforms(dt: dt, time: time)
    guard let buffer = queue.makeCommandBuffer() else { fail("no command buffer") }
    encode(buffer, advectVelocity, reads: [velocityA], writes: [velocityB], uniforms: &uniforms, size: simulationSize)
    encode(buffer, computeDivergence, reads: [velocityB], writes: [divergenceTexture], uniforms: &uniforms, size: simulationSize)
    for _ in 0..<12 {
        encode(buffer, jacobiPressure, reads: [pressureA, divergenceTexture], writes: [pressureB], uniforms: &uniforms, size: simulationSize)
        swap(&pressureA, &pressureB)
    }
    encode(buffer, projectVelocity, reads: [velocityB, pressureA], writes: [velocityA], uniforms: &uniforms, size: simulationSize)
    encode(buffer, advectDye, reads: [dyeA, velocityA], writes: [dyeB], uniforms: &uniforms, size: simulationSize)
    swap(&dyeA, &dyeB)

    let keep = step >= prerollFrames
    if keep {
        encode(
            buffer, renderOrb,
            reads: [dyeA, velocityA, pressureA], writes: [orbTexture],
            uniforms: &uniforms, size: orbPixels
        )
    }
    buffer.commit()
    buffer.waitUntilCompleted()
    guard keep else { continue }

    orbBytes.withUnsafeMutableBytes { raw in
        orbTexture.getBytes(
            raw.baseAddress!,
            bytesPerRow: orbBytesPerRow,
            from: MTLRegionMake2D(0, 0, orbPixels, orbPixels),
            mipmapLevel: 0
        )
    }
    renderedFrames.append(orbBytes.map { Float($0) / 255 })
    if renderedFrames.count % 20 == 0 {
        print("rendered \(renderedFrames.count)/\(totalFrames)")
    }
}

// Blend the tail back over the head so the animation closes on itself. The
// fluid never repeats, so a short dissolve is the only seamless option.
var frames = Array(renderedFrames[0..<loopFrames])
for index in 0..<crossfadeFrames {
    let head = renderedFrames[index]
    let tail = renderedFrames[loopFrames + index]
    var weight = Float(index + 1) / Float(crossfadeFrames + 1)
    weight = weight * weight * (3 - 2 * weight)
    frames[index] = zip(tail, head).map { $0 + ($1 - $0) * weight }
}

// MARK: - Composite the ambient glow behind the orb, over nothing

let glowColor = SIMD3<Float>(0.02, 0.38, 1)      // RecorderOrbView's listening glow
let center = Float(canvas - 1) / 2
let orbRadius = Float(canvas) * Float(orbFraction) / 2
let glowRadius = orbRadius * 1.06
let glowSoftness = Float(canvas) / 320 * 32      // the SwiftUI blur, scaled to this canvas

func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

var images: [CGImage] = []
var composite = [UInt8](repeating: 0, count: canvas * canvas * 4)
for (index, frame) in frames.enumerated() {
    let voice = voiceLevel(at: Float(prerollFrames + index) * dt)
    let glowStrength = 0.1 + voice * 0.035
    let orbOrigin = (Float(canvas) - Float(canvas) * Float(orbFraction)) / 2

    for y in 0..<canvas {
        for x in 0..<canvas {
            let dx = Float(x) - center
            let dy = Float(y) - center
            let distance = (dx * dx + dy * dy).squareRoot()
            let glowAlpha = glowStrength * (1 - smoothstep(glowRadius - glowSoftness, glowRadius + glowSoftness, distance))
            // Premultiplied throughout: it is what the containers store, and it
            // is the only space in which filtering an edge is correct.
            var pixel = SIMD4(glowColor * glowAlpha, glowAlpha)

            // Box-filter the supersampled orb into this destination pixel.
            let sx0 = Int((Float(x) - orbOrigin)) * supersample
            let sy0 = Int((Float(y) - orbOrigin)) * supersample
            if Float(x) >= orbOrigin, Float(y) >= orbOrigin,
               sx0 >= 0, sy0 >= 0, sx0 + supersample <= orbPixels, sy0 + supersample <= orbPixels {
                var sum = SIMD4<Float>.zero
                for sy in sy0..<(sy0 + supersample) {
                    let row = sy * orbBytesPerRow
                    for sx in sx0..<(sx0 + supersample) {
                        let offset = row + sx * 4
                        let alpha = frame[offset + 3]
                        sum += SIMD4(
                            frame[offset] * alpha,
                            frame[offset + 1] * alpha,
                            frame[offset + 2] * alpha,
                            alpha
                        )
                    }
                }
                let orb = sum / Float(supersample * supersample)
                pixel = orb + pixel * (1 - orb.w)
            }

            let offset = (y * canvas + x) * 4
            for channel in 0..<4 {
                composite[offset + channel] = UInt8(min(max(pixel[channel], 0), 1) * 255)
            }
        }
    }

    guard let provider = CGDataProvider(data: Data(composite) as CFData),
          let image = CGImage(
            width: canvas,
            height: canvas,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: canvas * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else { fail("could not build frame \(index)") }
    images.append(image)
}

// MARK: - Write

func writePNGFrames(to directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (index, image) in images.enumerated() {
        let url = directory.appending(path: String(format: "frame-%04d.png", index))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { continue }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let delay = 1.0 / Double(fps)

switch format {
case "webp":
    // WebP compresses the alpha channel losslessly even in lossy mode, so the
    // glow and the antialiased limb survive at roughly a GIF's file size.
    let staging = URL.temporaryDirectory.appending(path: "incant-orb-frames-\(getpid())")
    writePNGFrames(to: staging)
    defer { try? FileManager.default.removeItem(at: staging) }
    let frameFiles = (try? FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()) ?? []
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["img2webp", "-loop", "0", "-d", String(Int((delay * 1000).rounded())),
                         "-lossy", "-q", "82", "-m", "6"]
        + frameFiles.map { staging.appending(path: $0).path }
        + ["-o", outputURL.path]
    do {
        try process.run()
    } catch {
        fail("img2webp not found — brew install webp, or render docs/orb.png instead")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("img2webp failed") }

case "gif", "png":
    // GIF carries a single transparent palette index, so its edge and glow can
    // only be all-or-nothing; APNG keeps the alpha ramp the shader produced.
    let isGIF = format == "gif"
    let containerType = isGIF ? UTType.gif : UTType.png
    let containerProperties: CFDictionary = isGIF
        ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary
    let frameProperties: CFDictionary = isGIF
        ? [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay
          ]] as CFDictionary
        : [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyAPNGDelayTime: delay,
            kCGImagePropertyAPNGUnclampedDelayTime: delay
          ]] as CFDictionary
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, containerType.identifier as CFString, images.count, nil
    ) else { fail("could not open \(outputURL.path)") }
    CGImageDestinationSetProperties(destination, containerProperties)
    for image in images {
        CGImageDestinationAddImage(destination, image, frameProperties)
    }
    guard CGImageDestinationFinalize(destination) else { fail("could not encode \(outputURL.path)") }

default:
    fail("unsupported output \(outputURL.lastPathComponent) — use .webp, .png or .gif")
}

if ProcessInfo.processInfo.arguments.contains("--frames") {
    let framesDirectory = outputURL.deletingLastPathComponent().appending(path: "orb-frames")
    writePNGFrames(to: framesDirectory)
    print("wrote PNG frames to \(framesDirectory.path)")
}
print("wrote \(outputURL.path) — \(images.count) frames, \(canvas)x\(canvas) @ \(fps)fps")
