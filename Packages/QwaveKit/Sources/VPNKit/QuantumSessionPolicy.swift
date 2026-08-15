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

/// Corroborates a freshly-negotiated rekey PSK (issue #91).
///
/// ML-KEM decapsulation has implicit rejection: a tampered, corrupted or
/// hostile ciphertext of the right length never throws, it just derives a
/// different, well-formed 32-byte secret (FIPS 203; see
/// `PostQuantum/HybridKEM.swift`). Since #90 dropped the last throwing
/// decapsulation path (the Classic McEliece leg), the daily rekey has no
/// local way to tell a good PSK from a garbage one — there is nothing to
/// check without the peer. The only available corroboration is a completed
/// WireGuard handshake under the newly-installed PSK.
public enum RekeyConfirmation {
    /// Whether a handshake sample taken *after* installing a candidate PSK
    /// corroborates it. `baseline` is the peer's `last_handshake_time`
    /// observed before the PSK was installed; `observed` is a sample taken
    /// afterwards. Confirmed only when `observed` is strictly newer than
    /// `baseline` (or a handshake exists where none did before) — an
    /// unchanged or absent timestamp means no peer has completed a
    /// handshake under the new PSK, which is exactly what a tampered or
    /// hostile rekey ciphertext produces.
    public static func isConfirmed(baseline: Date?, observed: Date?) -> Bool {
        guard let observed else { return false }
        guard let baseline else { return true }
        return observed > baseline
    }
}
