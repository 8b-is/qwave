import Foundation

public struct RelayConstraints: Equatable, Sendable {
    /// Match `location` exactly ("se-sto") or by country prefix ("se").
    public var location: String?
    public var ownedOnly: Bool
    public var requireDaita: Bool

    public init(location: String? = nil, ownedOnly: Bool = false, requireDaita: Bool = false) {
        self.location = location
        self.ownedOnly = ownedOnly
        self.requireDaita = requireDaita
    }
}

public struct SelectedRelay: Equatable, Sendable {
    public let relay: RelayList.WireGuardRelay
    public let port: UInt16

    public var endpoint: String { "\(relay.ipv4AddrIn):\(port)" }
}

/// Deterministic-under-seed relay picking so tests are exact and production
/// gets spread across matching relays.
public enum RelaySelector {
    public static func matchingRelays(
        in list: RelayList,
        constraints: RelayConstraints
    ) -> [RelayList.WireGuardRelay] {
        list.wireguard.relays.filter { relay in
            guard relay.active else { return false }
            if constraints.ownedOnly, !relay.owned { return false }
            if constraints.requireDaita, relay.daita != true { return false }
            if let location = constraints.location, !location.isEmpty {
                let matchesExact = relay.location == location
                let matchesCountry = RelayList.countryCode(ofLocation: relay.location) == location
                guard matchesExact || matchesCountry else { return false }
            }
            return true
        }
    }

    public static func pickRelay(
        from list: RelayList,
        constraints: RelayConstraints,
        seed: UInt64 = UInt64.random(in: .min ... .max)
    ) -> SelectedRelay? {
        let candidates = matchingRelays(in: list, constraints: constraints)
        guard !candidates.isEmpty else { return nil }
        let relay = candidates[Int(seed % UInt64(candidates.count))]
        let port = pickPort(from: list.wireguard.portRanges, seed: seed)
        return SelectedRelay(relay: relay, port: port)
    }

    /// Prefers the canonical WireGuard port when offered; otherwise picks
    /// deterministically across the advertised ranges.
    public static func pickPort(from ranges: [[UInt16]], seed: UInt64) -> UInt16 {
        let normalized: [(UInt16, UInt16)] = ranges.compactMap { range in
            guard let low = range.first, let high = range.last, low <= high else { return nil }
            return (low, high)
        }
        guard !normalized.isEmpty else { return 51820 }

        if normalized.contains(where: { $0.0 <= 51820 && 51820 <= $0.1 }) {
            return 51820
        }

        let total = normalized.reduce(UInt64(0)) { $0 + UInt64($1.1 - $1.0) + 1 }
        var offset = seed % total
        for (low, high) in normalized {
            let span = UInt64(high - low) + 1
            if offset < span {
                return low + UInt16(offset)
            }
            offset -= span
        }
        return normalized[0].0
    }

    /// Countries present in the list, sorted by name — feeds the relay picker UI.
    public static func availableCountries(in list: RelayList) -> [(code: String, name: String)] {
        var byCode: [String: String] = [:]
        for (key, location) in list.locations {
            byCode[RelayList.countryCode(ofLocation: key)] = location.country
        }
        return byCode.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
}
