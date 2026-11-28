// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicRadarCore",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "MusicRadarCore", targets: ["MusicRadarCore"])
    ],
    targets: [
        .target(
            name: "MusicRadarCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MusicRadarCoreTests",
            dependencies: ["MusicRadarCore"]
        )
    ]
)
