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
}
