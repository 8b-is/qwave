import XCTest
import PostQuantum
@testable import VPNKit

/// Regression tests for issue #91: after #90 dropped the Classic McEliece
/// leg, `HybridKEM.decapsulate` no longer throws on a tampered ciphertext —
/// ML-KEM's implicit rejection (FIPS 203) just derives a different, wrong
/// 32-byte secret. The daily rekey path used to rely, incidentally, on a
/// throwing decapsulation to reject a bad response; `RekeyConfirmation` is
/// the replacement guard, corroborating the installed PSK against a real
/// handshake instead.
final class RekeyConfirmationTests: XCTestCase {

    // MARK: - RekeyConfirmation.isConfirmed — pure decision logic

    func testUnchangedHandshakeIsNotConfirmed() {
        // No new handshake completed under the candidate PSK: exactly what a
        // tampered/wrong-secret rekey produces.
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(RekeyConfirmation.isConfirmed(baseline: baseline, observed: baseline))
    }

    func testNoObservedHandshakeIsNotConfirmed() {
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(RekeyConfirmation.isConfirmed(baseline: baseline, observed: nil))
    }

    func testNewerHandshakeIsConfirmed() {
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let observed = baseline.addingTimeInterval(3)
        XCTAssertTrue(RekeyConfirmation.isConfirmed(baseline: baseline, observed: observed))
    }

    func testOlderHandshakeIsNotConfirmed() {
        // Defensive: a stale/out-of-order sample must not read as proof.
        let baseline = Date(timeIntervalSince1970: 1_000_000)
        let observed = baseline.addingTimeInterval(-3)
        XCTAssertFalse(RekeyConfirmation.isConfirmed(baseline: baseline, observed: observed))
    }

    func testFirstEverHandshakeIsConfirmed() {
        // No prior handshake (fresh tunnel) — any handshake at all confirms.
        XCTAssertTrue(RekeyConfirmation.isConfirmed(baseline: nil, observed: Date()))
    }

    func testNoBaselineNoObservedIsNotConfirmed() {
        XCTAssertFalse(RekeyConfirmation.isConfirmed(baseline: nil, observed: nil))
    }

    // MARK: - End-to-end: a tampered rekey ciphertext must not be corroborated

    /// Simulates the exact scenario from issue #91: a relay's rekey response
    /// ciphertext is tampered in transit. Before #90, the McEliece half's
    /// decapsulation would throw on this. Now `HybridKEM.decapsulate` (via
    /// the negotiator) silently returns a different, wrong PSK — so the
    /// negotiation itself succeeds. `RekeyConfirmation` is what has to catch
    /// it: because no peer ever completes a handshake under the wrong PSK,
    /// the handshake timestamp never advances, and the rekey is rejected.
    func testTamperedRekeyCiphertextProducesUnconfirmedPSK() async throws {
        let clientSeed = Data(repeating: 0x21, count: 32)
        let relaySeed = Data(repeating: 0x42, count: 32)
        let transport = MockQuantumTransport(relaySeed: relaySeed)
        let negotiator = MullvadQuantumPeerNegotiator(transport: transport, seed: clientSeed)

        let config = TunnelSessionConfig(
            interfaceAddresses: ["10.67.1.2/32"],
            dnsServers: ["10.64.0.1"],
            peerPublicKeyBase64: "aFCTFqCJnTqUnkYuxmpPnkzUS67HZbSZffZknJYYYFY=",
            peerEndpoint: "185.213.154.68:51820",
            relayHostname: "se-sto-wg-001",
            quantumResistant: true
        )

        // First, negotiate a legitimate PSK so we know the "correct" answer.
        let legitimateMaterial = try await negotiator.negotiatePresharedKey(config: config)
        let legitimatePSK = try XCTUnwrap(legitimateMaterial?.presharedKey)

        // Now simulate the relay's response being tampered in transit: flip
        // a byte inside the ML-KEM ciphertext (the only leg left post-#90).
        let clientEK = try XCTUnwrap(Data(base64Encoded: transport.receivedRequest!.mlkemPublicKey))
        let (goodCT, _) = try HybridKEM.encapsulate(ek: clientEK, seed: relaySeed)
        var tamperedCT = goodCT
        tamperedCT[100] ^= 0xFF

        // Decapsulating the tampered ciphertext must NOT throw (implicit
        // rejection, FIPS 203) — it must silently produce a different secret.
        let (_, clientDK) = try HybridKEM.keygen(seed: clientSeed)
        let wrongPSK = try HybridKEM.decapsulate(dk: clientDK, ct: tamperedCT)
        XCTAssertEqual(wrongPSK.count, 32, "implicit rejection still returns a well-formed secret")
        XCTAssertNotEqual(wrongPSK, legitimatePSK, "tampering must actually change the derived PSK")

        // This is the bug from #91: nothing at the KEM/negotiator layer
        // rejects `wrongPSK`. The daily rekey path's only remaining guard is
        // handshake corroboration — assert it actually rejects this case.
        let baselineHandshake = Date(timeIntervalSince1970: 1_000_000)
        // No peer ever completes a handshake under `wrongPSK`, so a runtime
        // sample taken after installing it reports the same (or no) time.
        let observedAfterInstallingWrongPSK = baselineHandshake
        XCTAssertFalse(
            RekeyConfirmation.isConfirmed(baseline: baselineHandshake, observed: observedAfterInstallingWrongPSK),
            "a tampered rekey ciphertext must not be corroborated by an unchanged handshake time"
        )

        // Contrast: had the ciphertext NOT been tampered, the relay would
        // complete a handshake under the (correct) new PSK, advancing the
        // timestamp — and that must be accepted.
        let observedAfterInstallingLegitimatePSK = baselineHandshake.addingTimeInterval(2)
        XCTAssertTrue(
            RekeyConfirmation.isConfirmed(
                baseline: baselineHandshake, observed: observedAfterInstallingLegitimatePSK)
        )
    }
}
