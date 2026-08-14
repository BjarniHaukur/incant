import AppKit

let scriptURL = URL(fileURLWithPath: #filePath)
let sourceURL = scriptURL.deletingLastPathComponent().appendingPathComponent("AppIcon-source-v2.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("Could not load \(sourceURL.path)\n", stderr)
    exit(1)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

// The generated source already contains the finished tile and sphere. Apply
// a deterministic macOS-shaped alpha mask so its black source corners never
// appear as a square around the Dock icon.
NSGraphicsContext.current?.imageInterpolation = .high
let tileRect = NSRect(x: 31, y: 31, width: 962, height: 962)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 178, yRadius: 178)
tile.addClip()
source.draw(
    in: NSRect(origin: .zero, size: size),
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1
)

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
