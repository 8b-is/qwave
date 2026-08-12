import Foundation

// Wire models for the Mullvad REST API (api.mullvad.net). Shapes follow the
// open-source mullvadvpn-app client; field names use the API's snake_case via
// each type's CodingKeys so call sites stay Swift-idiomatic.

public struct MullvadAccessToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let expiry: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiry
    }
}

public struct MullvadDevice: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let pubkey: String
    /// In-tunnel addresses assigned to this device, e.g. "10.67.1.2/32".
    public let ipv4Address: String
    public let ipv6Address: String

    enum CodingKeys: String, CodingKey {
        case id, name, pubkey
        case ipv4Address = "ipv4_address"
        case ipv6Address = "ipv6_address"
    }
}

public struct MullvadAccount: Codable, Equatable, Sendable {
    public let id: String
    public let expiry: Date
}

// MARK: - Relay list (GET /app/v1/relays)

public struct RelayList: Codable, Equatable, Sendable {
    public struct Location: Codable, Equatable, Sendable {
        public let country: String
        public let city: String
        public let latitude: Double
        public let longitude: Double
    }

    public struct WireGuard: Codable, Equatable, Sendable {
        public let portRanges: [[UInt16]]
        public let ipv4Gateway: String
        public let ipv6Gateway: String
        public let relays: [WireGuardRelay]

        enum CodingKeys: String, CodingKey {
            case portRanges = "port_ranges"
            case ipv4Gateway = "ipv4_gateway"
            case ipv6Gateway = "ipv6_gateway"
            case relays
        }
    }

    public struct WireGuardRelay: Codable, Equatable, Sendable {
        public let hostname: String
        /// Key into `locations`, e.g. "se-sto".
        public let location: String
        public let active: Bool
        /// Mullvad-owned hardware (vs rented).
        public let owned: Bool
        public let provider: String
        public let ipv4AddrIn: String
        public let ipv6AddrIn: String?
        public let publicKey: String
        /// Supports DAITA (defense against AI traffic analysis).
        public let daita: Bool?

        enum CodingKeys: String, CodingKey {
            case hostname, location, active, owned, provider, daita
            case ipv4AddrIn = "ipv4_addr_in"
            case ipv6AddrIn = "ipv6_addr_in"
            case publicKey = "public_key"
        }
    }

    public let locations: [String: Location]
    public let wireguard: WireGuard

    /// Country code for a relay ("se-sto" → "se").
    public static func countryCode(ofLocation location: String) -> String {
        String(location.split(separator: "-").first ?? "")
    }
}
