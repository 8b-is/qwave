import XCTest
@testable import QwaveSupport

final class SecretStoreTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.secret(for: "k"))

        try store.setSecret(Data([1, 2, 3]), for: "k")
        XCTAssertEqual(try store.secret(for: "k"), Data([1, 2, 3]))

        try store.setSecret(Data([9]), for: "k")
        XCTAssertEqual(try store.secret(for: "k"), Data([9]))

        try store.removeSecret(for: "k")
        XCTAssertNil(try store.secret(for: "k"))
    }

    /// `addSecret` is the write for material that cannot be regenerated: it
    /// must refuse rather than clobber, and leave the stored bytes alone.
    func testAddSecretRefusesToOverwrite() throws {
        let store = InMemorySecretStore()
        try store.addSecret(Data([1, 2, 3]), for: "k")
        XCTAssertEqual(try store.secret(for: "k"), Data([1, 2, 3]))

        XCTAssertThrowsError(try store.addSecret(Data([9]), for: "k")) { error in
            XCTAssertEqual(error as? SecretStoreError, .duplicateItem)
        }
        XCTAssertEqual(try store.secret(for: "k"), Data([1, 2, 3]))

        // Removing frees the slot again; setSecret keeps overwriting for the
        // callers that legitimately need update-in-place.
        try store.removeSecret(for: "k")
        XCTAssertNoThrow(try store.addSecret(Data([9]), for: "k"))
        try store.setSecret(Data([7]), for: "k")
        XCTAssertEqual(try store.secret(for: "k"), Data([7]))
    }

    func testRemoveMissingKeyDoesNotThrow() {
        let store = InMemorySecretStore()
        XCTAssertNoThrow(try store.removeSecret(for: "missing"))
    }
}
