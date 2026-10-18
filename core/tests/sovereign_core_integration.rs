//! End-to-end integration tests for `qwave-core`.
//!
//! Exercises the sovereign pipeline across modules through both the native
//! Rust API and the `extern "C"` ABI exported in `core/include/qwave_core.h`:
//!
//! 1. `quanttern` VAD affect reading → `EmotionCode::wave_fields` + C ABI byte
//! 2. `wave` 79-byte `WaveInt` MEM|8 frame encoding, validation, and 3D grid coord
//! 3. `phoenix` Marine salience gate → Custodian → Council custody verdict
//! 4. `mem16` governing sequence (`POP` → `COLLAPSE`)
//! 5. `badge` `sphered` witness (`#Commit = #ValidWitness`) & channel gate (`Stable` always free)
//! 6. `egress` Category-A host gate & `telemetry` PII URL scrubber

use std::ffi::{CStr, CString};

use qwave_core::Rational;
use qwave_core::badge::{
    Badge, Channel, GateDecision, Tier, decide_channel, qw_badge_seal, qw_badge_verify,
    qw_channel_entitled, qw_channel_notice,
};
use qwave_core::egress::qw_egress_permits;
use qwave_core::mem16::{qw_mem16_step_name, qw_mem16_verified};
use qwave_core::phoenix::{qw_phoenix_decide, qw_phoenix_free, qw_phoenix_new};
use qwave_core::quanttern::{
    DEFAULT_THRESHOLD, Vad, encode, qw_quanttern_agreement, qw_quanttern_encode,
    qw_quanttern_magnitude,
};
use qwave_core::telemetry::qw_telemetry_scrub_url;
use qwave_core::wave::{
    FRAME_SIZE, WaveInt, WaveProvenance, consciousness, qw_wave_frame_coord, qw_wave_frame_validate,
};

#[test]
fn end_to_end_affect_to_mem8_wave_and_phoenix_custody() {
    // 1. Quantize an affective reading via QuantTern (both Rust and C ABI):
    let vad = Vad::new(0.82, -0.64, 0.15);
    let emotion = encode(vad, DEFAULT_THRESHOLD);
    let abi_byte = qw_quanttern_encode(0.82, -0.64, 0.15, 0.0);
    assert_eq!(emotion.bytes, vec![abi_byte]);
    assert_eq!(qw_quanttern_magnitude(abi_byte), 2);
    assert!((qw_quanttern_agreement(abi_byte, abi_byte) - 1.0).abs() < 1e-6);

    // 2. Project affect onto the 79-byte WaveInt MEM|8 frame:
    let (valence, arousal) = emotion.wave_fields();
    assert_eq!(valence, Rational::integer(1));
    assert_eq!(arousal, Rational::integer(-1));

    let wave = WaveInt {
        base_amplitude: Rational::new(9, 10).expect("non-zero denominator"),
        frequency: consciousness(),
        phase: Rational::integer(45),
        emotional_valence: valence,
        arousal,
        created_at: 1_760_000_000_000_000_000,
        last_accessed: 1_760_000_030_000_000_000,
        access_count: 3,
        decay_rate: Rational::new(1, 1000).expect("non-zero denominator"),
        id: Some(0x8b15_cafe_d00d_2026),
        provenance: WaveProvenance::Cognitive,
    };

    let bytes = wave.to_frame();
    assert_eq!(bytes.len(), FRAME_SIZE);
    assert_eq!(WaveInt::from_frame(&bytes), Ok(wave));

    let rc = unsafe { qw_wave_frame_validate(bytes.as_ptr()) };
    assert_eq!(rc, 0, "79-byte WaveInt frame must validate across C ABI");

    let mut x = 0u8;
    let mut y = 0u8;
    let mut z = 0u16;
    unsafe {
        qw_wave_frame_coord(
            bytes.as_ptr(),
            1_760_000_060_000_000_000,
            &mut x,
            &mut y,
            &mut z,
        );
    }
    assert!(x > 0 || y > 0 || z > 0, "valid frame maps onto MEM|8 grid");

    // 3. Run the essence through Phoenix C ABI orchestration:
    let phoenix = qw_phoenix_new();
    assert!(!phoenix.is_null());
    let essence = CString::new("sovereign wave memory").unwrap();
    let mut amp_out = 0.0f32;
    let verdict = unsafe {
        qw_phoenix_decide(
            phoenix,
            essence.as_ptr(),
            true,
            0.9,
            432.0,
            45,
            0,
            &mut amp_out,
        )
    };
    assert_eq!(verdict, 0, "precious high-salience essence must STORE (0)");
    unsafe {
        qw_phoenix_free(phoenix);
    }
}

#[test]
fn end_to_end_sphered_badge_and_channel_entitlement_c_abi() {
    let member_hash = 0x8b15_0000_0000_0420u64;
    let since = 1_760_000_000u64;
    let until = 1_762_678_400u64;

    // Issue via Rust and verify via C ABI:
    let badge = Badge::issue(member_hash, Tier::Supporter, since, until);
    let c_seal = qw_badge_seal(member_hash, Tier::Supporter as u8, since, until);
    assert_eq!(badge.witness_seal, c_seal);
    assert!(qw_badge_verify(
        member_hash,
        Tier::Supporter as u8,
        since,
        until,
        c_seal
    ));

    // Stable (0) is unconditionally free even with zeroes:
    assert!(qw_channel_entitled(0, 0, 0, 0, 0, 0, 0));

    // Beta (1) and Nightly (2) unlock during [since, until] with a valid witness:
    assert!(qw_channel_entitled(
        1,
        member_hash,
        Tier::Supporter as u8,
        since,
        until,
        c_seal,
        since + 60,
    ));
    assert!(qw_channel_entitled(
        2,
        member_hash,
        Tier::Supporter as u8,
        since,
        until,
        c_seal,
        until,
    ));

    // After expiry, Nightly is refused with the non-nagging notice, while Stable remains free:
    assert!(!qw_channel_entitled(
        2,
        member_hash,
        Tier::Supporter as u8,
        since,
        until,
        c_seal,
        until + 1,
    ));
    assert_eq!(
        decide_channel(Channel::Nightly, Some(&badge), until + 1),
        GateDecision::MemberChannelRequired {
            channel: Channel::Nightly,
            notice: "nightly is a member channel — stable is yours, free.",
        }
    );

    let notice_ptr = qw_channel_notice(2);
    assert!(!notice_ptr.is_null());
    let notice = unsafe { CStr::from_ptr(notice_ptr) }.to_str().unwrap();
    assert_eq!(
        notice,
        "nightly is a member channel — stable is yours, free."
    );
}

#[test]
fn end_to_end_egress_mem16_and_telemetry_scrubber_c_abi() {
    let ok_host = CString::new("ac.ecosia.org").unwrap();
    let bad_host = CString::new("telemetry.evil.example").unwrap();
    assert!(unsafe { qw_egress_permits(ok_host.as_ptr()) });
    assert!(!unsafe { qw_egress_permits(bad_host.as_ptr()) });

    // mem|16-10 governing sequence:
    let step0 = unsafe { CStr::from_ptr(qw_mem16_step_name(0)) }
        .to_str()
        .unwrap();
    let step5 = unsafe { CStr::from_ptr(qw_mem16_step_name(5)) }
        .to_str()
        .unwrap();
    assert_eq!(step0, "POP");
    assert_eq!(step5, "COLLAPSE");
    assert!(!qw_mem16_verified(3));
    assert!(qw_mem16_verified(4));
    assert!(qw_mem16_verified(5));

    // Telemetry URL scrubbing strips paths and tokens:
    let raw_url = CString::new("https://github.com/8b-is/qwave/issues/77?token=secret").unwrap();
    let mut out = [0i8; 256];
    let n = unsafe { qw_telemetry_scrub_url(raw_url.as_ptr(), out.as_mut_ptr(), out.len()) };
    assert!(n > 0);
    let scrubbed = unsafe { CStr::from_ptr(out.as_ptr()) }.to_str().unwrap();
    assert!(scrubbed.starts_with("https://github.com/p:"));
    assert!(!scrubbed.contains("secret"));
}
