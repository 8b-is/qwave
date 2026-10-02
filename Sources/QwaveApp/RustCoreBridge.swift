// RustCoreBridge.swift — the thin Swift face over the qwave-core C ABI.
//
// The real implementations live in `core/src` (zero-dependency Rust: the
// egress allowlist and the MEM8 wave substrate). This type is only the
// trampoline; nothing here contains a decision.
import Foundation

enum RustCore {

    /// Category-A egress decision, served by the Rust allowlist
    /// (`core/src/egress.rs`). The same hosts the Swift-side guard commits
    /// to, enforced from the native core.
    static func egressPermits(_ host: String) -> Bool {
        host.withCString { qw_egress_permits($0) }
    }

    /// Validates a 79-byte MEM8 wave frame against the Rust substrate.
    /// Returns 0 when valid; 1 truncated, 2 unsupported version,
    /// 3 invalid provenance, 4 invalid rational, 5 checksum mismatch.
    static func waveFrameValidate(_ frame: [UInt8]) -> UInt32 {
        frame.withUnsafeBytes { buffer in
            qw_wave_frame_validate(buffer.bindMemory(to: UInt8.self).baseAddress)
        }
    }

    /// Grid coordinate of a validated wave frame at `nowNanos`; an invalid
    /// frame yields the origin.
    static func waveFrameCoord(_ frame: [UInt8], nowNanos: UInt64) -> (UInt8, UInt8, UInt16) {
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
    static func scrubURL(_ url: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let written = url.withCString { qw_telemetry_scrub_url($0, &buffer, buffer.count) }
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The mem|16-10 governing sequence's i-th step name, or nil.
    static func mem16StepName(_ i: UInt32) -> String? {
        guard let cString = qw_mem16_step_name(i) else { return nil }
        return String(cString: cString)
    }

    /// The mem|16-10 verification gate.
    static func mem16Verified(_ i: UInt32) -> Bool {
        qw_mem16_verified(i)
    }
}

/// The Phoenix protocol over the Rust orchestration — MEM|8 first-class.
/// One long-lived orchestration per process; the Swift side only feeds it.
final class RustPhoenix {
    private var handle: OpaquePointer?

    init() {
        handle = qw_phoenix_new()
    }

    deinit {
        if let handle {
            qw_phoenix_free(handle)
        }
    }

    enum Verdict: UInt8 {
        case store = 0
        case reinforce = 1
        case temporary = 2
        case drop = 3
    }

    /// Run one essence through Marine gate → Custodian → Council.
    func decide(
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
