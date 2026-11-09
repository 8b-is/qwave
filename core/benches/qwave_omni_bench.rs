//! `qwave_omni_bench` — Zero-Dependency Hot-Path Benchmark Suite (`hot_paths.md` Protocol).
//!
//! Measures `N = 9` independent windows per benchmark and reports:
//! - `p50` (median) latency per operation (`ns/op`)
//! - `p90` tail latency
//! - `spread` (`p90 - p50`)
//! - Throughput (`ops/sec`)
//!
//! Hot paths covered:
//! 1. `WaveInt` 79-byte binary roundtrip + zero-float `coordinate()` (`qwave_core::wave`)
//! 2. `QuantTern` zero-float rational `VadPq` gate-code packing (`qwave_core::quanttern`)
//! 3. `Phoenix` (`Marine` -> `Custodian` -> `Council`) (`qwave_core::phoenix`)
//! 4. `AgyOmni` K9 Collar Cycle + `SLEB128` LoRa Burst + 79B `WaveInt` + `PackLinkRadar` (`qwave_core::agy_omni`)
//! 5. `Markdown` compiler (`compile_full` with GFM tables, alerts, KaTeX) (`qwave_core::markdown`)
//! 6. `MarineIntDetector` + `extract_salient_grains` zero-float acoustic salience (`qwave_core::salience`)

use std::hint::black_box;
use std::time::Instant;

use qwave_core::Rational;
use qwave_core::agy_omni::{
    AgyOmniCollarNode, GeofenceZone, NODE_BELLA_ID, NODE_BLUE_ID, PackLinkRadar,
    bonobo_resonance_pq, synthesize_k9_sample,
};
use qwave_core::markdown::{MarkdownTrust, compile_full};
use qwave_core::phoenix::Phoenix;
use qwave_core::quanttern::{VadPq, default_threshold_pq, encode_pq, pack_vad_pq_byte};
use qwave_core::salience::{MarineIntDetector, extract_salient_grains};
use qwave_core::wave::{WaveInt, WaveProvenance, consciousness};

const WINDOWS: usize = 9;

struct WindowStats {
    name: &'static str,
    ops_per_window: u64,
    p50_ns_per_op: u64,
    p90_ns_per_op: u64,
    spread_ns_per_op: u64,
    ops_per_sec: u64,
}

fn measure_windows<F: FnMut(usize) -> u64>(
    name: &'static str,
    ops_per_window: u64,
    mut f: F,
) -> (WindowStats, u64) {
    // Warmup window
    let mut checksum = f(0);

    let mut samples_ns_per_op = [0u64; WINDOWS];
    for (w, slot) in samples_ns_per_op.iter_mut().enumerate() {
        let start = Instant::now();
        checksum ^= f(w + 1);
        let elapsed_ns = start.elapsed().as_nanos() as u64;
        *slot = (elapsed_ns / ops_per_window.max(1)).max(1);
    }

    samples_ns_per_op.sort_unstable();
    let p50 = samples_ns_per_op[WINDOWS / 2];
    let p90 = samples_ns_per_op[(WINDOWS * 9) / 10];
    let spread = p90.saturating_sub(p50);
    let ops_per_sec = 1_000_000_000u64 / p50.max(1);

    (
        WindowStats {
            name,
            ops_per_window,
            p50_ns_per_op: p50,
            p90_ns_per_op: p90,
            spread_ns_per_op: spread,
            ops_per_sec,
        },
        checksum,
    )
}

fn main() {
    let mut total_guard = 0u64;
    let mut results = Vec::with_capacity(6);

    // 1. WaveInt 79-byte binary roundtrip + zero-float grid coordinate (50,000 ops/window)
    let (s1, g1) = measure_windows("waveint_79b_roundtrip_and_coord", 50_000, |w| {
        let mut acc = 0u64;
        let amp = Rational::new(3, 2).unwrap();
        let val = Rational::new(1, 2).unwrap();
        let aro = Rational::new(2, 3).unwrap();
        let dec = Rational::new(1, 10).unwrap();
        let freq = consciousness();
        for i in 0..50_000u64 {
            let created = (1_762_646_400 + i) * 1_000_000_000;
            let wave = WaveInt {
                base_amplitude: amp,
                frequency: freq,
                phase: Rational::integer(((i + w as u64) % 360) as i32),
                emotional_valence: val,
                arousal: aro,
                created_at: created,
                last_accessed: created + 5_000_000_000,
                access_count: (i as u32).max(1),
                decay_rate: dec,
                id: Some(0x5157_4156_0000_0000 ^ i ^ (w as u64)),
                provenance: WaveProvenance::Cognitive,
            };
            let bytes = black_box(wave).to_frame();
            let decoded = WaveInt::from_frame(black_box(&bytes)).expect("valid 79B WaveInt");
            let (gx, gy, gz) = decoded.coordinate(Some(created + 5_000_000_000));
            acc ^= decoded.id.unwrap_or(0) ^ ((gx as u64) << 16) ^ ((gy as u64) << 8) ^ (gz as u64);
        }
        acc
    });
    total_guard ^= g1;
    results.push(s1);

    // 2. QuantTern zero-float VadPq gate-code & agreement (100,000 ops/window)
    let (s2, g2) = measure_windows("quanttern_vad_pq_gate_pack", 100_000, |w| {
        let mut acc = 0u64;
        let thresh = default_threshold_pq();
        for i in 0..100_000i32 {
            let vad = VadPq::new(
                Rational::new(((i + w as i32) % 9) - 4, 4).unwrap(),
                Rational::new((i % 5) + 1, 5).unwrap(),
                Rational::new(((i * 3) % 7) - 3, 4).unwrap(),
            );
            let code = encode_pq(black_box(vad), thresh);
            let packed = pack_vad_pq_byte(black_box(vad), thresh);
            acc ^= (packed as u64) ^ (code.magnitude() as u64);
        }
        acc
    });
    total_guard ^= g2;
    results.push(s2);

    // 3. Phoenix Marine -> Custodian -> Council (25,000 ops/window)
    let (s3, g3) = measure_windows("phoenix_orchestration_decide", 25_000, |w| {
        let mut phoenix = Phoenix::new();
        let mut acc = 0u64;
        for i in 0..25_000u64 {
            let (verdict, amp) = phoenix.decide(
                black_box("babilon-ultra-k9 sovereign mem8 wave checkpoint"),
                (i & 3) == 0,
                0.78,
                0.73,
                ((i + w as u64) % 255) as u8,
                (i & 1) as u8,
            );
            acc ^= (verdict as u64) ^ (amp.to_bits() as u64);
        }
        acc
    });
    total_guard ^= g3;
    results.push(s3);

    // 4. AgyOmni K9 Collar Step + SLEB128 LoRa Burst + 79B WaveInt + PackLinkRadar (25,000 dual cycles = 50,000 collar bursts/window)
    let (s4, g4) = measure_windows("agy_omni_k9_collar_waveint_radar", 50_000, |w| {
        let zone = GeofenceZone::default_sanctuary();
        let mut blue = AgyOmniCollarNode::new(
            NODE_BLUE_ID,
            zone.anchor_lat_microdeg,
            zone.anchor_lon_microdeg,
            [0x42 ^ (w as u8); 32],
        );
        let mut bella = AgyOmniCollarNode::new(
            NODE_BELLA_ID,
            zone.anchor_lat_microdeg,
            zone.anchor_lon_microdeg,
            [0xBE ^ (w as u8); 32],
        );
        let mut acc = 0u64;
        for tick in 1..=25_000u64 {
            let now_nanos = (1_762_646_400 + tick) * 1_000_000_000;
            let b_sample = synthesize_k9_sample(
                NODE_BLUE_ID,
                tick,
                zone.anchor_lat_microdeg,
                zone.anchor_lon_microdeg,
            );
            let b_burst = blue.step_cycle(b_sample);
            let b_wave = b_burst.to_wave_int(b_sample.cadence_hz_q8, now_nanos);

            let l_sample = synthesize_k9_sample(
                NODE_BELLA_ID,
                tick,
                zone.anchor_lat_microdeg,
                zone.anchor_lon_microdeg,
            );
            let l_burst = bella.step_cycle(l_sample);
            let l_wave = l_burst.to_wave_int(l_sample.cadence_hz_q8, now_nanos);
            let radar = PackLinkRadar::evaluate(
                blue.last_lat_microdeg,
                blue.last_lon_microdeg,
                bella.last_lat_microdeg,
                bella.last_lon_microdeg,
                &zone,
            );
            acc ^= b_wave.id.unwrap_or(0) ^ l_wave.id.unwrap_or(0) ^ radar.separation_dm;
        }
        acc
    });
    total_guard ^= g4;
    results.push(s4);

    // 5. Markdown Compiler (`compile_full` on technical document with tables, math, and alerts) (1,000 docs/window)
    let sample_md = "# Babilon-Ultra K9 × Qwave Sovereign Architecture\n\n\
                     > [!IMPORTANT]\n\
                     > Zero-float rational `p/q` (`3/2` Bonobo resonance) and 79-byte `MEM|8` `WaveInt` frames.\n\n\
                     | Subsystem | Wire Size | Resonance |\n\
                     | :--- | :---: | ---: |\n\
                     | `WaveInt` | `79 B` | `3/2` |\n\
                     | `EpochSeal` | `64 B` | `PHNX` |\n\
                     | `LoRaBurst` | `<= 24 B` | `Tryte5` |\n\n\
                     Inline math $p/q = 3/2$ and display wave equation:\n\n\
                     $$\\Psi(x, y, z, t) = \\sum_{n=1}^{8} A_n \\cos(\\omega_n t + \\phi_n)$$\n";
    let (s5, g5) = measure_windows("markdown_compile_full_doc", 1_000, |w| {
        let mut acc = w as u64;
        for _ in 0..1_000 {
            let compiled = compile_full(
                black_box(sample_md),
                MarkdownTrust::CompilerOutputOnly,
                None,
            );
            acc ^= (compiled.html.len() as u64) ^ (compiled.toc.len() as u64);
        }
        acc
    });
    total_guard ^= g5;
    results.push(s5);

    // 6. MarineIntDetector + extract_salient_grains on 1s 16kHz PCM audio (200 seconds/window = 3,200,000 samples/window)
    let pcm_1s: Vec<i16> = (0..16_000usize)
        .map(|i| {
            let p = (i % 103) as i32;
            let tri = if p < 51 {
                (p - 25) * 580
            } else {
                (77 - p) * 580
            };
            tri.clamp(-20_000, 20_000) as i16
        })
        .collect();
    let (s6, g6) = measure_windows("salience_marine_1s_16khz_audio", 200, |w| {
        let mut det = MarineIntDetector::new(16_000, 164);
        let mut acc = w as u64;
        for sec in 0..200u64 {
            for (idx, &s) in pcm_1s.iter().enumerate() {
                acc = acc.wrapping_add(det.process_sample_i16(s, idx) as u64);
            }
            if sec % 10 == 0 {
                let rep = extract_salient_grains(&pcm_1s, 16_000, 3, 1_762_646_400 + sec);
                acc ^= rep.top_grains.len() as u64;
            }
        }
        acc
    });
    total_guard ^= g6;
    results.push(s6);

    let bonobo = bonobo_resonance_pq();
    println!(
        "==================================================================================================="
    );
    println!(
        " QWAVE × AGY-OMNI HOT-PATH BENCHMARK SUITE (N = {WINDOWS} windows, Bonobo p/q = {}/{})",
        bonobo.num, bonobo.den
    );
    println!(
        "==================================================================================================="
    );
    println!(
        " {:<34} | {:>10} | {:>10} | {:>10} | {:>10} | {:>14}",
        "Benchmark", "Ops/Win", "p50 (ns)", "p90 (ns)", "Spread", "Throughput"
    );
    println!(
        "---------------------------------------------------------------------------------------------------"
    );
    for r in &results {
        println!(
            " {:<34} | {:>10} | {:>10} | {:>10} | {:>10} | {:>10} ops/s",
            r.name,
            r.ops_per_window,
            r.p50_ns_per_op,
            r.p90_ns_per_op,
            r.spread_ns_per_op,
            r.ops_per_sec
        );
    }
    println!(
        "==================================================================================================="
    );
    println!(" Guard Checksum: 0x{total_guard:016X}");
}
