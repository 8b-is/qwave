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

/// Real-time PhoeniX Sound Revelation & Marine-Sense 4096-Bucket (20 Hz .. 384 kHz) DSP Engine
/// for macOS and iOS Audio Unit v3 (`AUv3`) plugins and in-app audio pipelines.
public final class RustPhoenixSound: @unchecked Sendable {
    public enum Preset: UInt8, CaseIterable, Sendable {
        case sovereignMaster = 0
        case goonjVelvetHall = 1
        case naadStudioSub = 2
        case sanctuary432 = 3
        case vocalClaritySvara = 4
        case alexandraSanctuary = 5

        public var displayName: String {
            switch self {
            case .sovereignMaster: return "Sovereign Master"
            case .goonjVelvetHall: return "Goonj Dark Velvet"
            case .naadStudioSub: return "Naad Studio Sub (<140Hz)"
            case .sanctuary432: return "Sanctuary 432Hz"
            case .vocalClaritySvara: return "Vocal Clarity (Svara Emotion)"
            case .alexandraSanctuary: return "💖 Alexandra Sanctuary (Warmth & Passion)"
            }
        }
    }

    public struct TelemetrySnapshot: Sendable {
        public let marineBuckets64: [UInt16]
        public let marineVocal64: [UInt16]
        public let dominantHz: UInt32
        public let soulQ10: UInt16

        public init(
            marineBuckets64: [UInt16],
            marineVocal64: [UInt16],
            dominantHz: UInt32,
            soulQ10: UInt16
        ) {
            self.marineBuckets64 = marineBuckets64
            self.marineVocal64 = marineVocal64
            self.dominantHz = dominantHz
            self.soulQ10 = soulQ10
        }
    }

    private var handle: OpaquePointer?

    public init(sampleRateHz: UInt32 = 48_000, preset: Preset = .vocalClaritySvara) {
        handle = qw_phoenix_sound_new(sampleRateHz, preset.rawValue)
    }

    deinit {
        if let handle {
            qw_phoenix_sound_free(handle)
        }
    }

    public func setPreset(_ preset: Preset) {
        qw_phoenix_sound_set_preset(handle, preset.rawValue)
    }

    public func setFeelControls(
        automagic: Bool,
        voicePct: UInt16 = 100,
        bassPct: UInt16 = 100,
        spacePct: UInt16 = 100
    ) {
        qw_phoenix_sound_set_feel(handle, automagic, voicePct, bassPct, spacePct)
    }

    public func setAlexandraReset(_ active: Bool) {
        qw_phoenix_sound_set_alexandra_reset(handle, active)
    }

    public func setParams(
        naadSubQ10: Int32,
        svaraVocalQ10: Int32,
        warmthQ10: Int32,
        goonjVelvetQ10: Int32,
        airQ10: Int32,
        stereoWidthQ10: Int32 = 1380
    ) {
        qw_phoenix_sound_set_params(
            handle,
            naadSubQ10,
            svaraVocalQ10,
            warmthQ10,
            goonjVelvetQ10,
            airQ10,
            stereoWidthQ10
        )
    }

    /// Zero-allocation in-place stereo processing for real-time AUv3 render blocks.
    public func processInterleavedStereo(_ buffer: UnsafeMutablePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        qw_phoenix_sound_process_i16(handle, buffer, frames)
    }

    /// Snapshot live 64-anchor Marine time-domain buckets (20 Hz .. 384 kHz) and isolated Singer Vocal Emotion.
    public func telemetry() -> TelemetrySnapshot {
        var buckets = [UInt16](repeating: 0, count: 64)
        var vocal = [UInt16](repeating: 0, count: 64)
        var domHz: UInt32 = 432
        var soul: UInt16 = 980
        buckets.withUnsafeMutableBufferPointer { bBuf in
            vocal.withUnsafeMutableBufferPointer { vBuf in
                qw_phoenix_sound_telemetry(
                    handle,
                    bBuf.baseAddress,
                    vBuf.baseAddress,
                    &domHz,
                    &soul
                )
            }
        }
        return TelemetrySnapshot(
            marineBuckets64: buckets,
            marineVocal64: vocal,
            dominantHz: domHz,
            soulQ10: soul
        )
    }
}

// MARK: - i1.is Sovereign AI Provenance, Soul Signature & Smart Tree .m8

public enum RustI1Soul {
    public enum IngestMode: UInt8, CaseIterable, Sendable {
        case mine = 0
        case summarizeFromBrowsing = 1
        case localAiOnly = 2
        case noArchivePrivate = 3

        public var label: String {
            switch self {
            case .mine: return "✍️ Mine (Original Credit → i1.is)"
            case .summarizeFromBrowsing: return "🌐 Browsing Summary (Author-Revocable → i1.is)"
            case .localAiOnly: return "🔒 Local AI Only (On-Device MEM|8)"
            case .noArchivePrivate: return "🚫 No Archive / Private"
            }
        }
    }

    public enum PersonalField: UInt8, CaseIterable, Sendable {
        case username = 0
        case email = 1
        case phone = 2
        case website = 3
        case blog = 4
        case xHandle = 5
        case redditHandle = 6
        case githubHandle = 7
        case physicalAddress = 8
        case legalName = 9

        public var label: String {
            switch self {
            case .username: return "Username"
            case .email: return "Email"
            case .phone: return "Phone"
            case .website: return "Website"
            case .blog: return "Blog"
            case .xHandle: return "X / Twitter"
            case .redditHandle: return "Reddit"
            case .githubHandle: return "GitHub / g8t.is"
            case .physicalAddress: return "Address"
            case .legalName: return "Legal Name"
            }
        }
    }

    public enum FieldPolicy: UInt8, CaseIterable, Sendable {
        case alwaysAllow = 0
        case askEveryTime = 1
        case requiredFormsOnly = 2
        case neverStrip = 3

        public var shortLabel: String {
            switch self {
            case .alwaysAllow: return "Always OK"
            case .askEveryTime: return "Ask"
            case .requiredFormsOnly: return "Req. Forms Only"
            case .neverStrip: return "Never (Strip)"
            }
        }
    }

    public struct DeedEvaluation: Equatable, Sendable {
        public let soulTag: UInt64
        public let deedSeal: UInt64
        public let stylometricQ10: UInt16
        public let shingleQ10: UInt16
        public let organicAuthenticityQ10: UInt16
        public let combinedMatchQ10: UInt16
        public let smartTreeSavingsQ10: UInt16
        public let smartTreeNodes: UInt16
        public let redactionCount: UInt32
        public let canIngestI1: Bool
        public let canSummarizeLocal: Bool
    }

    public static func evaluateDeed(
        creatorId: String,
        secretPhrase: String = "sovereign-8b-is-soul",
        canonicalURL: String,
        pageText: String,
        mode: IngestMode,
        originalAuthorRevoked: Bool = false
    ) -> DeedEvaluation {
        var raw = QwI1DeedSummary(
            soul_tag: 0,
            deed_seal: 0,
            stylometric_q10: 0,
            shingle_q10: 0,
            organic_authenticity_q10: 0,
            combined_match_q10: 0,
            smart_tree_savings_q10: 0,
            smart_tree_nodes: 0,
            redaction_count: 0,
            can_ingest_i1: false,
            can_summarize_local: false
        )
        _ = creatorId.withCString { cidPtr in
            secretPhrase.withCString { secPtr in
                canonicalURL.withCString { urlPtr in
                    pageText.withCString { txtPtr in
                        qw_i1_evaluate_deed(
                            cidPtr,
                            secPtr,
                            urlPtr,
                            txtPtr,
                            mode.rawValue,
                            originalAuthorRevoked,
                            &raw
                        )
                    }
                }
            }
        }
        return DeedEvaluation(
            soulTag: raw.soul_tag,
            deedSeal: raw.deed_seal,
            stylometricQ10: raw.stylometric_q10,
            shingleQ10: raw.shingle_q10,
            organicAuthenticityQ10: raw.organic_authenticity_q10,
            combinedMatchQ10: raw.combined_match_q10,
            smartTreeSavingsQ10: raw.smart_tree_savings_q10,
            smartTreeNodes: raw.smart_tree_nodes,
            redactionCount: raw.redaction_count,
            canIngestI1: raw.can_ingest_i1,
            canSummarizeLocal: raw.can_summarize_local
        )
    }
}
