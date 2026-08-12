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

    func testRemoveMissingKeyDoesNotThrow() {
        let store = InMemorySecretStore()
        XCTAssertNoThrow(try store.removeSecret(for: "missing"))
    }
}
