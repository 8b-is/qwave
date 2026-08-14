// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "arcbench",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "arcbench", path: "Sources/arcbench")
    ]
)
