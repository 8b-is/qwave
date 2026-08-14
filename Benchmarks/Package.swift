// swift-tools-version:5.10
import PackageDescription

// In-process benchmarks with CI-checked thresholds (docs/ENERGY.md).
// NOTE: these cover in-process work ONLY. The hibernation memory claim is
// out-of-process (WebKit content processes) and is proven by
// BrowserCoreTests/HibernationReclaimTests, not here.
let package = Package(
    name: "QwaveBenchmarks",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.36.2"),
        .package(path: "../Packages/QwaveKit"),
    ],
    targets: [
        .executableTarget(
            name: "QwaveKitBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "QwaveKit", package: "QwaveKit"),
            ],
            path: "Benchmarks/QwaveKitBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .executableTarget(
            name: "QwaveAllocationBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "QwaveKit", package: "QwaveKit"),
            ],
            path: "Benchmarks/QwaveAllocationBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
    ]
)
