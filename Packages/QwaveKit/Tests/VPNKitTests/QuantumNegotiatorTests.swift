import XCTest
import PostQuantum
@testable import VPNKit

/// A relay simulator: receives the client's encapsulation key and answers
/// with a real ciphertext bundle (as the in-tunnel service would).
final class MockQuantumTransport: QuantumTransporting, @unchecked Sendable {
    private let relaySeed: Data
    private(set) var receivedRequest: EphemeralPeerRequest?
    private(set) var requestCount = 0
    var shouldFail = false

    init(relaySeed: Data) {
        self.relaySeed = relaySeed
    }

    func requestEphemeralPeer(_ request: EphemeralPeerRequest) async throws -> EphemeralPeerResponse {
        requestCount += 1
        receivedRequest = request
        if shouldFail {
            throw QuantumTransportError.transportFailed(underlying: URLError(.cannotConnectToHost))
        }
        guard let clientEK = Data(base64Encoded: request.mlkemPublicKey) else {
            throw QuantumTransportError.invalidResponse
        }
        let (ct, _) = try HybridKEM.encapsulate(ek: clientEK, seed: relaySeed)
        return EphemeralPeerResponse(ciphertextBundle: ct.base64EncodedString())
    }
}

/// Stage B: the negotiator must derive a PSK that both sides agree on, and
/// fall back cleanly when the transport fails.
final class QuantumNegotiatorTests: XCTestCase {
    private func sampleConfig(quantumResistant: Bool = true) -> TunnelSessionConfig {
        TunnelSessionConfig(
            interfaceAddresses: ["10.67.1.2/32"],
            dnsServers: ["10.64.0.1"],
            peerPublicKeyBase64: "aFCTFqCJnTqUnkYuxmpPnkzUS67HZbSZffZknJYYYFY=",
            peerEndpoint: "185.213.154.68:51820",
            relayHostname: "se-sto-wg-001",
            quantumResistant: quantumResistant
        )
    }

    func testNegotiatesPSKAgreedByBothSides() async throws {
        let clientSeed = Data(repeating: 0x21, count: 32)
        let relaySeed = Data(repeating: 0x42, count: 32)
        let transport = MockQuantumTransport(relaySeed: relaySeed)
        let negotiator = MullvadQuantumPeerNegotiator(transport: transport, seed: clientSeed)

        let material = try await negotiator.negotiatePresharedKey(config: sampleConfig())
        let psk = try XCTUnwrap(material?.presharedKey)
        XCTAssertEqual(psk.count, 32)

        // The relay side encapsulates against the client's public half and
        // derives the same key from its own encapsulation.
        let clientEK = Data(base64Encoded: transport.receivedRequest!.mlkemPublicKey)!
        let (_, relaySS) = try HybridKEM.encapsulate(ek: clientEK, seed: relaySeed)
        XCTAssertEqual(psk, relaySS)
    }

    func testDisabledQuantumResistanceSkipsNegotiation() async throws {
        let transport = MockQuantumTransport(relaySeed: Data(repeating: 0x42, count: 32))
        let negotiator = MullvadQuantumPeerNegotiator(transport: transport)
        let material = try await negotiator.negotiatePresharedKey(config: sampleConfig(quantumResistant: false))
        XCTAssertNil(material)
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testTransportFailurePropagates() async {
        let transport = MockQuantumTransport(relaySeed: Data(repeating: 0x42, count: 32))
        transport.shouldFail = true
        let negotiator = MullvadQuantumPeerNegotiator(transport: transport, seed: Data(repeating: 0x21, count: 32))
        do {
            _ = try await negotiator.negotiatePresharedKey(config: sampleConfig())
            XCTFail("expected failure")
        } catch {
            // Fail-closed since v0.3.0: the provider blocks tunnel start on
            // this error (see FailClosedNegotiationTests) — never classic.
        }
    }

    func testRequestCarriesWireGuardKeyAndHostname() async throws {
        let transport = MockQuantumTransport(relaySeed: Data(repeating: 0x42, count: 32))
        let negotiator = MullvadQuantumPeerNegotiator(transport: transport, seed: Data(repeating: 0x21, count: 32))
        _ = try await negotiator.negotiatePresharedKey(config: sampleConfig())
        let request = try XCTUnwrap(transport.receivedRequest)
        XCTAssertEqual(request.relayHostname, "se-sto-wg-001")
        XCTAssertEqual(request.wgPublicKey, "aFCTFqCJnTqUnkYuxmpPnkzUS67HZbSZffZknJYYYFY=")
        XCTAssertEqual(Data(base64Encoded: request.mlkemPublicKey)?.count, MLKEM768.ekSize)
    }
}
