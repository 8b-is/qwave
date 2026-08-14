// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "foundation-models-probe",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "foundation-models-probe", path: "Sources/foundation-models-probe")
    ]
)
