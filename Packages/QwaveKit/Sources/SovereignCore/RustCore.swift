// RustCore.swift — the thin Swift face over the qwave-core C ABI.
//
// The real implementations live in `core/src` (zero-dependency Rust: the
// egress allowlist, the MEM8 wave substrate, the Phoenix protocol, the
// telemetry scrubber, the QuantTern emotional ternary code, and the sphered
// membership badge witness gate). This type is only the trampoline; nothing
// here contains a decision.
//
// Shared by both lanes: the macOS app and the iPhone app link the same
// staticlib and speak the same ABI through this same module (the app targets
// link `libqwave_core.a`; standalone package builds fall back to the weak
// stubs in the RustCoreABI target).
import Foundation
import RustCoreABI

public enum RustCore {

    /// Category-A egress decision, served by the Rust allowlist
    /// (`core/src/egress.rs`). The same hosts the Swift-side guard commits
    /// to, enforced from the native core.
    public static func egressPermits(_ host: String) -> Bool {
        host.withCString { qw_egress_permits($0) }
    }

    /// Validates a 79-byte MEM8 wave frame against the Rust substrate.
    /// Returns 0 when valid; 1 truncated, 2 unsupported version,
    /// 3 invalid provenance, 4 invalid rational, 5 checksum mismatch.
    public static func waveFrameValidate(_ frame: [UInt8]) -> UInt32 {
        frame.withUnsafeBytes { buffer in
            qw_wave_frame_validate(buffer.bindMemory(to: UInt8.self).baseAddress)
        }
    }

    /// Grid coordinate of a validated wave frame at `nowNanos`; an invalid
    /// frame yields the origin.
    public static func waveFrameCoord(_ frame: [UInt8], nowNanos: UInt64) -> (UInt8, UInt8, UInt16) {
        var x: UInt8 = 0
        var y: UInt8 = 0
        var z: UInt16 = 0
        frame.withUnsafeBytes { buffer in
            qw_wave_frame_coord(
                buffer.bindMemory(to: UInt8.self).baseAddress, nowNanos, &x, &y, &z)
        }
        return (x, y, z)
    }

    /// PII-scrubbed URL (scheme + host only, hashed path) for the debug lane.
    public static func scrubURL(_ url: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let written = url.withCString { qw_telemetry_scrub_url($0, &buffer, buffer.count) }
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The mem|16-10 governing sequence's i-th step name, or nil.
    public static func mem16StepName(_ i: UInt32) -> String? {
        guard let cString = qw_mem16_step_name(i) else { return nil }
        return String(cString: cString)
    }

    /// The mem|16-10 verification gate.
    public static func mem16Verified(_ i: UInt32) -> Bool {
        qw_mem16_verified(i)
    }

    // MARK: - QuantTern (qUltraKotoro emotional ternary code)

    /// Quantize `(valence, arousal, dominance)` into one gate-coded byte.
    public static func quantternEncode(
        valence: Float,
        arousal: Float,
        dominance: Float,
        threshold: Float = 0.33
    ) -> UInt8 {
        qw_quanttern_encode(valence, arousal, dominance, threshold)
    }

    /// Count of non-neutral trits (`0...3`) in a gate-coded VAD byte.
    public static func quantternMagnitude(_ packed: UInt8) -> UInt8 {
        qw_quanttern_magnitude(packed)
    }

    /// Agreement fraction (`0.0...1.0`) between two gate-coded VAD bytes.
    public static func quantternAgreement(_ packedA: UInt8, _ packedB: UInt8) -> Float {
        qw_quanttern_agreement(packedA, packedB)
    }

    // MARK: - sphered badge witness & P1 channel gate

    /// Release channels in Qwave (`docs/PRODUCTIZATION.md` §4.1, §5.2).
    public enum Channel: UInt8, Sendable {
        case stable = 0
        case beta = 1
        case nightly = 2
    }

    /// Membership tiers (`docs/PRODUCTIZATION.md` §3).
    public enum Tier: UInt8, Sendable {
        case free = 0
        case supporter = 1
        case patron = 2
        case team = 3
        case oneOff = 4
    }

    /// Compute the deterministic 64-bit witness seal for a badge tuple.
    public static func badgeSeal(
        memberHash: UInt64,
        tier: Tier,
        sinceEpoch: UInt64,
        untilEpoch: UInt64
    ) -> UInt64 {
        qw_badge_seal(memberHash, tier.rawValue, sinceEpoch, untilEpoch)
    }

    /// Verify a badge's 5-stage SpherePOP witness (`#Commit = #ValidWitness`).
    public static func badgeVerify(
        memberHash: UInt64,
        tier: Tier,
        sinceEpoch: UInt64,
        untilEpoch: UInt64,
        witnessSeal: UInt64
    ) -> Bool {
        qw_badge_verify(memberHash, tier.rawValue, sinceEpoch, untilEpoch, witnessSeal)
    }

    /// Check whether `channel` is unlocked at `nowEpoch`.
    /// `.stable` is unconditionally free for everyone (`docs/PRODUCTIZATION.md` §0).
    public static func channelEntitled(
        _ channel: Channel,
        memberHash: UInt64 = 0,
        tier: Tier = .free,
        sinceEpoch: UInt64 = 0,
        untilEpoch: UInt64 = 0,
        witnessSeal: UInt64 = 0,
        nowEpoch: UInt64 = 0
    ) -> Bool {
        qw_channel_entitled(
            channel.rawValue,
            memberHash,
            tier.rawValue,
            sinceEpoch,
            untilEpoch,
            witnessSeal,
            nowEpoch
        )
    }

    /// Non-nagging one-line explanation for `channel`, or nil in stub builds.
    public static func channelNotice(_ channel: Channel) -> String? {
        guard let cString = qw_channel_notice(channel.rawValue) else { return nil }
        return String(cString: cString)
    }
}

/// The Phoenix protocol over the Rust orchestration — MEM|8 first-class.
/// One long-lived orchestration per process; the Swift side only feeds it.
public final class RustPhoenix {
    private var handle: OpaquePointer?

    public init() {
        handle = qw_phoenix_new()
    }

    deinit {
        if let handle {
            qw_phoenix_free(handle)
        }
    }

    public enum Verdict: UInt8 {
        case store = 0
        case reinforce = 1
        case temporary = 2
        case drop = 3
    }

    /// Run one essence through Marine gate → Custodian → Council.
    public func decide(
        _ essence: String,
        precious: Bool,
        amplitude: Float,
        frequency: Float,
        phaseDegrees: UInt8,
        decayID: UInt8
    ) -> (verdict: Verdict, amplitude: Float) {
        var amp: Float = amplitude
        let raw = essence.withCString {
            qw_phoenix_decide(handle, $0, precious, amplitude, frequency, phaseDegrees, decayID, &amp)
        }
        return (Verdict(rawValue: raw) ?? .drop, amp)
    }
}
