// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TSDKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TSDKit", targets: ["TSDKit"]),
        .executable(name: "tsdconv", targets: ["tsdconv"]),
    ],
    targets: [
        // Reads, writes, renders and exports TechSoft 2D Design V3 (.3vs / .tsd) files.
        .target(
            name: "TSDKit",
            resources: [
                .copy("Resources/template-prefix.bin"),
                .copy("Resources/template-middle.bin"),
            ]
        ),
        // Command-line converter: tsdconv --format svg file.3vs
        .executableTarget(name: "tsdconv", dependencies: ["TSDKit"]),
        .testTarget(
            name: "TSDKitTests",
            dependencies: ["TSDKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
