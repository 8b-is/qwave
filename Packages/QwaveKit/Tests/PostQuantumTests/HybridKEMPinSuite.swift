import Testing
import Foundation
@testable import PostQuantum

/// **REGRESSION PIN — NOT CONFORMANCE EVIDENCE.**
///
/// The fixture behind this suite (`Fixtures/hybrid_psk_regression_pin.json`)
/// was generated from Qwave's own `HybridKEM`. It is a self-consistency pin and
/// carries no external authority whatsoever. The only conformance oracle in
/// this repo is `MLKEM768ACVPSuite` against the official NIST ACVP vectors;
/// nothing here may be cited as evidence that anything conforms to FIPS 203.
///
/// What it is for: `HybridKEM`'s derivation constants — `pskLabel`,
/// `mlkemKgLabel`, `mlkemEncLabel` (HybridKEM.swift) and the 64-byte seed
/// expansion split into `d` and `z` — are **wire-visible**. Both tunnel peers
/// must compute them identically, yet no standard defines them and no ACVP
/// vector covers them. Without this pin every one of those constants could be
/// edited with the entire test suite staying green: the behavioural tests in
/// `HybridKEMTests` only assert relationships (round-trips, `rawSS != ss`),
/// which hold for *any* choice of label.
///
/// If a case here fails, ask first whether a wire-visible constant changed on
/// purpose. If it did, regenerate this fixture deliberately and record the
/// break in CHANGELOG.md — old and new peers will not interoperate.
struct HybridKEMPinSuite {
    struct PinVector: Decodable, CustomTestStringConvertible {
        let name: String
        let seed: String
        let ek: String
        let dk: String
        let ct: String
        let ss: String
        var testDescription: String { name }
    }

    struct Fixture: Decodable {
        let vectors: [PinVector]
    }

    static let vectors: [PinVector] = {
        guard let url = Bundle.module.url(forResource: "hybrid_psk_regression_pin", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixture = try? JSONDecoder().decode(Fixture.self, from: data)
        else {
            return []
        }
        return fixture.vectors
    }()

    /// Guards against a silently-empty fixture turning the pin into a no-op.
    @Test func pinIsLoaded() {
        #expect(Self.vectors.count == 2)
    }

    /// Pins `mlkemKgLabel` and the `d`/`z` seed split (via ek and dk),
    /// `mlkemEncLabel` (via ct) and `pskLabel` (via ss) in one shot.
    @Test(arguments: vectors)
    func derivationIsUnchanged(vector: PinVector) throws {
        let seed = Data(hexVector: vector.seed)
        let (ek, dk) = try HybridKEM.keygen(seed: seed)
        #expect(ek == Data(hexVector: vector.ek), "mlkemKgLabel or the d/z seed split changed")
        #expect(dk == Data(hexVector: vector.dk), "mlkemKgLabel or the d/z seed split changed")

        let (ct, ss) = try HybridKEM.encapsulate(ek: ek, seed: seed)
        #expect(ct == Data(hexVector: vector.ct), "mlkemEncLabel changed")
        #expect(ss == Data(hexVector: vector.ss), "pskLabel or mlkemEncLabel changed")

        #expect(try HybridKEM.decapsulate(dk: dk, ct: ct) == Data(hexVector: vector.ss))
    }
}
