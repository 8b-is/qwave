import Security
import XCTest

@testable import VPNKit

/// Proves the pin computation is correct — the risky part is prepending the
/// right ASN.1 SPKI header to the raw key so the digest matches a standard
/// pin. Fixtures are the real published ISRG root certificates (the pinned
/// anchors) and one foreign root (the negative case). See docs/PINNING.md.
final class MullvadCertificatePinnerTests: XCTestCase {
    private func certificate(_ resource: String) throws -> SecCertificate {
        let url = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "der"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    func testISRGRootX1SPKIMatchesTheRSAPin() throws {
        let cert = try certificate("isrg-root-x1")
        XCTAssertEqual(
            MullvadCertificatePinner.spkiPin(for: cert),
            "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M="
        )
    }

    func testISRGRootX2SPKIMatchesTheECDSAPin() throws {
        let cert = try certificate("isrg-root-x2")
        XCTAssertEqual(
            MullvadCertificatePinner.spkiPin(for: cert),
            "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI="
        )
    }

    func testBothISRGPinsAreInThePinnedSet() {
        XCTAssertTrue(
            MullvadCertificatePinner.pinnedRootSPKISHA256.contains("C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M="))
        XCTAssertTrue(
            MullvadCertificatePinner.pinnedRootSPKISHA256.contains("diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI="))
    }

    func testForeignRootIsNotPinned() throws {
        let cert = try certificate("foreign-root")
        let pin = MullvadCertificatePinner.spkiPin(for: cert)
        XCTAssertNotNil(pin)
        XCTAssertFalse(
            MullvadCertificatePinner.pinnedRootSPKISHA256.contains(pin ?? ""),
            "a non-ISRG root must not satisfy the pin"
        )
    }

    /// The pin applies only to api.mullvad.net; the pinned-host constant must
    /// be exactly that (a typo here would silently disable pinning).
    func testPinnedHostIsMullvadAPI() {
        XCTAssertEqual(MullvadCertificatePinner.pinnedHost, "api.mullvad.net")
    }
}
