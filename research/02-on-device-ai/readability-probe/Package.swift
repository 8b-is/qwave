// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "readability-probe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "readability", path: "Sources/readability")
    ]
)
