import XCTest
@testable import VPNKit

final class TunnelSessionConfigTests: XCTestCase {
    private func sampleConfig() -> TunnelSessionConfig {
        TunnelSessionConfig(
            interfaceAddresses: ["10.67.1.2/32", "fc00:bbbb::2/128"],
            dnsServers: ["10.64.0.1"],
            peerPublicKeyBase64: "aFCTFqCJnTqUnkYuxmpPnkzUS67HZbSZffZknJYYYFY=",
            peerEndpoint: "185.213.154.68:51820",
            relayHostname: "se-sto-wg-001",
            quantumResistant: true
        )
    }

    func testProviderConfigurationRoundTrip() throws {
        let original = sampleConfig()
        let dict = try original.providerConfiguration()
        let decoded = TunnelSessionConfig(providerConfiguration: dict)
        XCTAssertEqual(decoded, original)
    }

    func testConfigPreservesValuesAcrossDetachedWork() async {
        let original = sampleConfig()
        let transferred = await Task.detached { original }.value

        XCTAssertEqual(transferred, original)
        XCTAssertEqual(transferred.relayHostname, "se-sto-wg-001")
    }

    func testDecodingGarbageReturnsNil() {
        XCTAssertNil(TunnelSessionConfig(providerConfiguration: nil))
        XCTAssertNil(TunnelSessionConfig(providerConfiguration: [:]))
        XCTAssertNil(TunnelSessionConfig(providerConfiguration: ["qwave.tunnelSessionConfig": Data("junk".utf8)]))
    }

    func testNoPrivateKeyMaterialInProviderConfiguration() throws {
        // The invariant the whole key-handling design hangs on: nothing that
        // looks like key material may enter providerConfiguration.
        let dict = try sampleConfig().providerConfiguration()
        let data = try XCTUnwrap(dict["qwave.tunnelSessionConfig"] as? Data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("privatekey"))
        XCTAssertFalse(json.lowercased().contains("private_key"))
    }

    func testMakeFromRelaySelection() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "relays", withExtension: "json"))
        let list = try JSONDecoder().decode(RelayList.self, from: Data(contentsOf: url))
        let selected = try XCTUnwrap(
            RelaySelector.pickRelay(from: list, constraints: RelayConstraints(location: "se"), seed: 0)
        )
        let device = MullvadDevice(
            id: "dev-1",
            name: "cuddly krill",
            pubkey: "AAA=",
            ipv4Address: "10.67.1.2/32",
            ipv6Address: "fc00:bbbb::2/128"
        )

        let config = TunnelSessionConfig.make(device: device, relayList: list, selected: selected)
        XCTAssertEqual(config.interfaceAddresses, ["10.67.1.2/32", "fc00:bbbb::2/128"])
        XCTAssertEqual(config.dnsServers, ["10.64.0.1", "fc00:bbbb:bbbb:bb01::1"])
        XCTAssertEqual(config.peerPublicKeyBase64, "aFCTFqCJnTqUnkYuxmpPnkzUS67HZbSZffZknJYYYFY=")
        XCTAssertEqual(config.relayHostname, "se-sto-wg-001")
        XCTAssertEqual(config.allowedIPs, ["0.0.0.0/0", "::/0"])
    }
}
