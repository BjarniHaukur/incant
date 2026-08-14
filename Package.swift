// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Incant",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Incant", targets: ["Incant"])],
    targets: [
        .executableTarget(
            name: "Incant",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("Carbon"),
                .linkedFramework("MetalKit"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
