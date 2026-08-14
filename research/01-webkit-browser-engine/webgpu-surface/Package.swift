// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "webgpu-surface",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "webgpu-probe",
            path: "Sources/webgpu-probe"
        )
    ]
)
