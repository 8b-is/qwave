import XCTest
import CryptoKit
@testable import VPNKit
import QwaveSupport

final class DeviceKeyAndAccountTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "qwave-vpn-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testKeyGenerationAndStability() throws {
        let manager = DeviceKeyManager(secrets: InMemorySecretStore())
        XCTAssertNil(try manager.currentPrivateKey())

        let first = try manager.obtainPrivateKey()
        let second = try manager.obtainPrivateKey()
        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation, "obtain must be stable")

        let publicKey = try XCTUnwrap(try manager.publicKeyBase64())
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)

        try manager.deleteKey()
        XCTAssertNil(try manager.currentPrivateKey())
    }

    func testAccountStoreLifecycle() {
        let secrets = InMemorySecretStore()
        let defaults = makeDefaults()
        let store = AccountStore(secrets: secrets, defaults: defaults)

        XCTAssertFalse(store.isLoggedIn)
        store.accountNumber = "1234567890123456"
        store.accessToken = "mva_tok"
        store.tokenExpiry = Date().addingTimeInterval(3600)
        store.storeDevice(
            MullvadDevice(
                id: "dev-1",
                name: "cuddly krill",
                pubkey: "AAA=",
                ipv4Address: "10.67.1.2/32",
                ipv6Address: "fc00:bbbb::2/128"
            )
        )

        XCTAssertTrue(store.isLoggedIn)
        XCTAssertTrue(store.hasValidToken)
        XCTAssertEqual(store.deviceIPv4Address, "10.67.1.2/32")

        store.tokenExpiry = Date().addingTimeInterval(-60)
        XCTAssertFalse(store.hasValidToken, "expired token is invalid")

        store.clear()
        XCTAssertFalse(store.isLoggedIn)
        XCTAssertNil(store.accountNumber)
        XCTAssertNil(store.deviceIPv4Address)
    }

    func testNoopNegotiatorReturnsNil() async throws {
        let negotiator = NoopEphemeralPeerNegotiator()
        let config = TunnelSessionConfig(
            interfaceAddresses: [],
            dnsServers: [],
            peerPublicKeyBase64: "",
            peerEndpoint: "",
            relayHostname: "x",
            quantumResistant: true
        )
        let material = try await negotiator.negotiatePresharedKey(config: config)
        XCTAssertNil(material)
    }
}
