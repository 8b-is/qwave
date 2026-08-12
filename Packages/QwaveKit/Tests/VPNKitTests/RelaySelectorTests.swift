import XCTest
@testable import VPNKit

final class RelaySelectorTests: XCTestCase {
    private var list: RelayList!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "relays", withExtension: "json"))
        list = try JSONDecoder().decode(RelayList.self, from: Data(contentsOf: url))
    }

    func testInactiveRelaysExcluded() {
        let matches = RelaySelector.matchingRelays(in: list, constraints: RelayConstraints())
        XCTAssertEqual(matches.count, 2, "us-nyc-wg-301 is inactive")
        XCTAssertFalse(matches.contains { $0.hostname == "us-nyc-wg-301" })
    }

    func testCountryFilter() {
        let matches = RelaySelector.matchingRelays(in: list, constraints: RelayConstraints(location: "se"))
        XCTAssertEqual(matches.map(\.hostname), ["se-sto-wg-001"])
    }

    func testExactLocationFilter() {
        let matches = RelaySelector.matchingRelays(in: list, constraints: RelayConstraints(location: "de-fra"))
        XCTAssertEqual(matches.map(\.hostname), ["de-fra-wg-001"])
    }

    func testOwnedOnlyFilter() {
        let matches = RelaySelector.matchingRelays(in: list, constraints: RelayConstraints(ownedOnly: true))
        XCTAssertEqual(matches.map(\.hostname), ["se-sto-wg-001"])
    }

    func testDaitaFilter() {
        let matches = RelaySelector.matchingRelays(in: list, constraints: RelayConstraints(requireDaita: true))
        XCTAssertEqual(matches.map(\.hostname), ["se-sto-wg-001"], "active + daita")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(RelaySelector.pickRelay(from: list, constraints: RelayConstraints(location: "jp")))
    }

    func testPickIsDeterministicUnderSeed() {
        let a = RelaySelector.pickRelay(from: list, constraints: RelayConstraints(), seed: 7)
        let b = RelaySelector.pickRelay(from: list, constraints: RelayConstraints(), seed: 7)
        XCTAssertEqual(a, b)
    }

    func testPortPrefersCanonicalWireGuardPort() {
        // Fixture ranges include 33565-51820.
        let port = RelaySelector.pickPort(from: list.wireguard.portRanges, seed: 123)
        XCTAssertEqual(port, 51820)
    }

    func testPortFallsBackIntoRanges() {
        let port = RelaySelector.pickPort(from: [[53, 53], [4000, 4002]], seed: 5)
        XCTAssertTrue([53, 4000, 4001, 4002].contains(port))
    }

    func testPortEmptyRangesDefaults() {
        XCTAssertEqual(RelaySelector.pickPort(from: [], seed: 1), 51820)
    }

    func testEndpointFormat() {
        let selected = RelaySelector.pickRelay(from: list, constraints: RelayConstraints(location: "se"), seed: 1)
        XCTAssertEqual(selected?.endpoint, "185.213.154.68:51820")
    }

    func testAvailableCountries() {
        let countries = RelaySelector.availableCountries(in: list)
        XCTAssertEqual(countries.map(\.code).sorted(), ["de", "se", "us"])
    }
}
