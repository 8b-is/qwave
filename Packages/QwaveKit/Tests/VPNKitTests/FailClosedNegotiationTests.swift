import XCTest
@testable import VPNKit

/// Regression tests for the v0.3.0 fail-closed guarantee: when the user has
/// `quantumResistant` enabled, a failed (or empty) PSK negotiation must FAIL
/// tunnel start — never silently fall back to classic WireGuard. These tests
/// were written before the provider change, per the kickoff's landmine rule.
final class FailClosedNegotiationTests: XCTestCase {
    private struct ThrowingNegotiator: EphemeralPeerNegotiating {
        func negotiatePresharedKey(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial? {
            throw QuantumTransportError.transportFailed(underlying: URLError(.cannotConnectToHost))
        }
    }

    private struct NilNegotiator: EphemeralPeerNegotiating {
        func negotiatePresharedKey(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial? {
            nil
        }
    }

    private struct SucceedingNegotiator: EphemeralPeerNegotiating {
        func negotiatePresharedKey(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial? {
            PresharedKeyMaterial(presharedKey: Data(repeating: 0xAB, count: 32))
        }
    }

    private func config(quantumResistant: Bool) -> TunnelSessionConfig {
        TunnelSessionConfig(
            interfaceAddresses: ["10.67.1.2/32"],
            dnsServers: ["10.64.0.1"],
            peerPublicKeyBase64: "aFCTFqCJnTqUnkYuxmpPnkzUS67HZbSZffZknJYYYFY=",
            peerEndpoint: "185.213.154.68:51820",
            relayHostname: "se-sto-wg-001",
            quantumResistant: quantumResistant
        )
    }

    func testNegotiationFailureBlocksTunnelStart() async {
        do {
            _ = try await ThrowingNegotiator().negotiateFailClosed(config: config(quantumResistant: true))
            XCTFail("quantumResistant + failed negotiation must throw, not fall back to classic")
        } catch let error as QuantumSessionError {
            guard case .downgradeBlocked = error else {
                return XCTFail("expected downgradeBlocked, got \(error)")
            }
        } catch {
            XCTFail("expected QuantumSessionError, got \(error)")
        }
    }

    func testMissingKeyMaterialBlocksTunnelStart() async {
        do {
            _ = try await NilNegotiator().negotiateFailClosed(config: config(quantumResistant: true))
            XCTFail("quantumResistant + empty negotiation must throw, not fall back to classic")
        } catch let error as QuantumSessionError {
            guard case .downgradeBlocked = error else {
                return XCTFail("expected downgradeBlocked, got \(error)")
            }
        } catch {
            XCTFail("expected QuantumSessionError, got \(error)")
        }
    }

    func testQuantumDisabledStaysClassicWithoutNegotiation() async throws {
        let material = try await ThrowingNegotiator().negotiateFailClosed(config: config(quantumResistant: false))
        XCTAssertNil(material, "quantumResistant off → classic WireGuard, negotiator never consulted")
    }

    func testSuccessfulNegotiationReturnsMaterial() async throws {
        let material = try await SucceedingNegotiator().negotiateFailClosed(config: config(quantumResistant: true))
        XCTAssertEqual(material?.presharedKey, Data(repeating: 0xAB, count: 32))
    }

    // MARK: - Rekey policy

    func testRekeyDueAfterInterval() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(RekeyPolicy.shouldRekey(lastRekey: start, now: start.addingTimeInterval(60)))
        XCTAssertFalse(
            RekeyPolicy.shouldRekey(lastRekey: start, now: start.addingTimeInterval(RekeyPolicy.interval - 1)))
        XCTAssertTrue(RekeyPolicy.shouldRekey(lastRekey: start, now: start.addingTimeInterval(RekeyPolicy.interval)))
        XCTAssertTrue(
            RekeyPolicy.shouldRekey(lastRekey: start, now: start.addingTimeInterval(RekeyPolicy.interval * 3)))
    }

    func testRekeyNotDueWithoutPriorRekey() {
        // No PSK was ever negotiated (classic tunnel) → nothing to rekey.
        XCTAssertFalse(RekeyPolicy.shouldRekey(lastRekey: nil, now: Date()))
    }

    func testClockRollbackDoesNotUnderflow() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(RekeyPolicy.shouldRekey(lastRekey: start, now: start.addingTimeInterval(-3600)))
    }

    func testDailyInterval() {
        XCTAssertEqual(RekeyPolicy.interval, 24 * 60 * 60)
    }
}
