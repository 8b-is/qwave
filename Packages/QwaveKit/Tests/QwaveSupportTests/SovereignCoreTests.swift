import XCTest
@testable import SovereignCore

/// Pins the contract between the vendored ABI header and the Rust source of
/// truth, plus the safe-fail behavior of the stubs standalone builds link.
final class SovereignCoreTests: XCTestCase {
    /// The header lives in two places: `core/include/qwave_core.h` (the Rust
    /// source of truth) and the QwaveKit `RustCoreABI` target's include dir
    /// (what SPM compiles against). A copy, not a symlink — SwiftPM does not
    /// follow symlinked public headers — so this test guards the drift.
    func testVendoredABIHeaderMatchesTheCoreSource() throws {
        let repo = try repoRoot()
        let source = try String(contentsOf: repo.appendingPathComponent("core/include/qwave_core.h"), encoding: .utf8)
        let vendored = try String(
            contentsOf: repo.appendingPathComponent(
                "Packages/QwaveKit/Sources/RustCoreABI/include/qwave_core.h"),
            encoding: .utf8
        )
        XCTAssertEqual(source, vendored, "the vendored ABI header drifted from core/include/qwave_core.h")
    }

    /// In a standalone package build (swift test, qwave-mcp) the weak stubs
    /// answer; the app links the strong Rust definitions, which win. These
    /// assertions pin the stub contract so it cannot silently become
    /// permissive.
    func testStubsFailClosedInStandaloneBuilds() {
        // The real core would permit these; the stub must never.
        XCTAssertFalse(RustCore.egressPermits("github.com"))
        XCTAssertFalse(RustCore.mem16Verified(4))
        XCTAssertNil(RustCore.mem16StepName(4))
        XCTAssertNil(RustCore.scrubURL("https://example.com/private/path"))
    }

    /// The Phoenix facade over the stubs: no orchestration, no custody —
    /// every verdict is DROP and the amplitude passes through unchanged.
    func testPhoenixStubVerdictIsDrop() {
        let phoenix = RustPhoenix()
        let (verdict, amplitude) = phoenix.decide(
            "essence", precious: false, amplitude: 0.5, frequency: 1.0, phaseDegrees: 0, decayID: 0)
        XCTAssertEqual(verdict, .drop)
        XCTAssertEqual(amplitude, 0.5)
    }

    /// Walk up from this source file to the repository root (the directory
    /// containing both `core/` and `Packages/`).
    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let core = url.appendingPathComponent("core/include/qwave_core.h")
            let packages = url.appendingPathComponent("Packages/QwaveKit")
            if FileManager.default.fileExists(atPath: core.path),
                FileManager.default.fileExists(atPath: packages.path)
            {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        throw XCTSkip("repository root not found from \(#filePath)")
    }
}
