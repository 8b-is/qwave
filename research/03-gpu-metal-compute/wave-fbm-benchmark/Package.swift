// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "wavefbm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "wavefbm", path: "Sources/wavefbm")
    ]
)
