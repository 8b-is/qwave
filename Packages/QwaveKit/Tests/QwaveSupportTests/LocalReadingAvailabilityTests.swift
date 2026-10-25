import Foundation
import SovereignCore
import XCTest

final class LocalReadingAvailabilityTests: XCTestCase {
    func testStandalonePackageCannotClaimModelAvailability() async throws {
        XCTAssertFalse(RustLocalReadingSession.isAvailable)
        do {
            _ = try await RustLocalReadingSession.load(
                modelURL: URL(fileURLWithPath: "/missing/model.gguf"),
                tokenizerURL: URL(fileURLWithPath: "/missing/tokenizer.json"))
            XCTFail("Unlinked model must never return a session")
        } catch let error as LocalReadingError {
            XCTAssertEqual(error, .unavailable)
        }
    }
}
