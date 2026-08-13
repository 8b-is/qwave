import Foundation

/// Errors surfaced to the user when the quantum-resistant session policy
/// refuses to proceed.
public enum QuantumSessionError: Error, Equatable, LocalizedError {
    /// `quantumResistant` was requested but PSK negotiation failed or came
    /// back empty. The tunnel must NOT start classic in that state.
    case downgradeBlocked(reason: String)

    public var errorDescription: String? {
        switch self {
        case .downgradeBlocked(let reason):
            return "Quantum-resistant key exchange failed (\(reason)). "
                + "The tunnel was not started, because falling back to classic "
                + "WireGuard would silently drop the protection you enabled. "
                + "Retry, pick another relay, or disable quantum resistance."
        }
    }
}

extension EphemeralPeerNegotiating {
    /// Fail-closed negotiation wrapper — the only path tunnel providers may
    /// use. `quantumResistant` off → nil (classic WireGuard, by choice).
    /// `quantumResistant` on → key material, or a hard error; never a silent
    /// classic fallback.
    public func negotiateFailClosed(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial? {
        guard config.quantumResistant else { return nil }
        let material: PresharedKeyMaterial?
        do {
            material = try await negotiatePresharedKey(config: config)
        } catch {
            throw QuantumSessionError.downgradeBlocked(reason: String(describing: error))
        }
        guard let material else {
            throw QuantumSessionError.downgradeBlocked(reason: "negotiator returned no key material")
        }
        return material
    }
}

/// When a quantum-resistant tunnel's ephemeral PSK is due for replacement.
/// Pure decision logic; the provider owns the timer and sleep/wake hooks.
public enum RekeyPolicy {
    /// Daily, matching Mullvad's ephemeral-peer rotation cadence.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// `lastRekey == nil` means no PSK was ever negotiated (classic tunnel):
    /// nothing to rotate. Clock rollbacks (negative elapsed) never trigger.
    public static func shouldRekey(lastRekey: Date?, now: Date = Date()) -> Bool {
        guard let lastRekey else { return false }
        return now.timeIntervalSince(lastRekey) >= interval
    }
}
