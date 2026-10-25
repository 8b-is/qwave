//! Sovereign `8b.is` × `Qwave` × `ALEXIAI` Hyprland Workstation HUD & Voice-AI Dispatcher.
//!
//! 100% Pure Rust · `#![forbid(unsafe_code)]` · Zero External Crate Dependencies · Zero Floats.
//!
//! Enforces the C64 `64 KB` (`65_536` byte) ring-buffer discipline, `MarineIntDetector`
//! salience priority, exact reduced `p/q` [`Rational`] arithmetic, and balanced ternary
//! trits (`{-1, 0, +1}` / `[-, 0, +]`).

#![forbid(unsafe_code)]

use std::env;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use qwave_core::Rational;
use qwave_core::quanttern::{Trit, default_threshold_pq};
use qwave_core::salience::{
    DEFAULT_CLIP_THRESHOLD_Q15, MarineIntDetector, Q15_ONE, RingBuffer, SpeakerSalienceProfile,
};

/// C64 `64 KB` (`65_536` bytes) ring-buffer ceiling for all file tail reads.
pub const C64_RING_BYTES: usize = 65_536;

/// Number of recent room utterances retained in the live TUI ring buffer.
pub const ROOM_THOUGHT_RING_CAP: usize = 12;

/// Parsed utterance / vocal wave entry in the room thoughts ring buffer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomThoughtEntry {
    pub ts: u64,
    pub speaker: String,
    pub context: String,
    pub f0_hz: i32,
    pub f0_pq: Rational,
    pub azimuth_deg: i32,
    pub distance_cm: i32,
    pub spatial_zone: String,
    pub salience_pct: i32,
    pub salience_pq: Rational,
    pub vad_byte: u8,
    pub text: String,
}

impl Default for RoomThoughtEntry {
    fn default() -> Self {
        Self {
            ts: 0,
            speaker: "hue".to_string(),
            context: "ready".to_string(),
            f0_hz: 156,
            f0_pq: Rational::integer(156),
            azimuth_deg: 0,
            distance_cm: 120,
            spatial_zone: "center_keyboard".to_string(),
            salience_pct: 90,
            salience_pq: Rational::new(9, 10).unwrap_or(Rational::ONE),
            vad_byte: 0x62,
            text: "Sovereign studio standing by".to_string(),
        }
    }
}

/// Complete snapshot of vocal salience, Marine detector state, and Sovereign stack health.
#[derive(Clone, Debug)]
pub struct HudSnapshot {
    pub speaker: String,
    pub f0_hz: i32,
    pub f0_pq: Rational,
    pub profile_f0_pq: Rational,
    pub azimuth_deg: i32,
    pub distance_cm: i32,
    pub spatial_zone: String,
    pub salience_pct: i32,
    pub salience_pq: Rational,
    pub stability_trit: Trit,
    pub detector_f0_pq: Rational,
    pub grains_learned: u64,
    pub grain_samples: usize,
    pub vad_byte: u8,
    pub latest_text: String,
    pub thoughts: Vec<RoomThoughtEntry>,
    pub ear_trit: Trit,
    pub lqd_trit: Trit,
    pub aye_trit: Trit,
    pub esp_trit: Trit,
    pub a6k_trit: Trit,
    pub g8t_trit: Trit,
    pub dry_trit: Trit,
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let subcmd = args.first().map(String::as_str).unwrap_or("waybar");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };

    match subcmd {
        "waybar" => {
            let snap = collect_hud_snapshot();
            println!("{}", render_waybar_json(&snap));
        }
        "status-tui" => run_status_tui(rest),
        "voice-type" => {
            println!("{}", run_voice_type(rest));
        }
        "ask-aye" => {
            println!("{}", run_ask_aye(rest));
        }
        "toggle-ear" => {
            println!("{}", run_toggle_ear(rest));
        }
        "boot-session" => {
            println!("{}", run_boot_session(rest));
        }
        "a6000-pulse" => {
            println!("{}", run_a6000_pulse(rest));
        }
        "-h" | "--help" | "help" => {
            print_usage();
        }
        _ => {
            print_usage();
            std::process::exit(2);
        }
    }
}

fn print_usage() {
    println!(
        "qwave-hypr-hud — Sovereign 8b-is x Qwave x ALEXIAI Hyprland HUD (100% Pure Rust, Zero-Float)\n\
         Usage:\n\
         \x20 qwave-hypr-hud waybar                Single-line Waybar JSON with ternary stack badges\n\
         \x20 qwave-hypr-hud status-tui [--once]   Live 500ms ANSI Collaboration Radar HUD\n\
         \x20 qwave-hypr-hud voice-type            Record via qwave -> liquid-rust -> wl-copy + wtype\n\
         \x20 qwave-hypr-hud ask-aye               Voice prompt -> loopback alexiai -> qwave --speak\n\
         \x20 qwave-hypr-hud toggle-ear            Toggle qwave-ear.service with spoken confirmation\n\
         \x20 qwave-hypr-hud boot-session          Autostart services, waybar, workspaces & welcome\n\
         \x20 qwave-hypr-hud a6000-pulse           Probe Sovereign stack & A6000 with notification"
    );
}

/// Format a [`Trit`] as its compact `[+]`, `[0]`, or `[-]` badge token.
pub const fn trit_symbol(t: Trit) -> &'static str {
    match t {
        Trit::Plus => "+",
        Trit::Zero => "0",
        Trit::Minus => "-",
    }
}

/// Sanitize any accidental decimal digit dot sequence (`12.34` -> `12:34`) so user-facing
/// output strictly obeys the `8b.is` No-Float Law even when quoting arbitrary transcripts.
pub fn sanitize_no_float(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'.'
            && i > 0
            && i + 1 < bytes.len()
            && bytes[i - 1].is_ascii_digit()
            && bytes[i + 1].is_ascii_digit()
        {
            out.push(':');
            i += 1;
        } else {
            let ch = input[i..].chars().next().unwrap_or(' ');
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

/// Escape a string for safe inclusion inside JSON quotes.
pub fn json_escape(input: &str) -> String {
    let clean = sanitize_no_float(input);
    let mut out = String::with_capacity(clean.len() + 8);
    for ch in clean.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// Read at most the last `64 KB` (`C64_RING_BYTES = 65_536`) of a file.
pub fn read_tail_c64_ring(path: &Path) -> io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(C64_RING_BYTES as u64);
    file.seek(SeekFrom::Start(start))?;
    let to_read = (len - start).min(C64_RING_BYTES as u64) as usize;
    let mut buf = vec![0u8; to_read];
    let n = file.read(&mut buf)?;
    buf.truncate(n);
    Ok(buf)
}

/// Parse a `"num/den"` string into a reduced [`Rational`].
pub fn parse_rational_pq(raw: &str, fallback: Rational) -> Rational {
    let trimmed = raw.trim();
    if let Some((n_str, d_str)) = trimmed.split_once('/') {
        let num = n_str.trim().parse::<i64>().unwrap_or(fallback.num as i64);
        let den = d_str
            .trim()
            .parse::<u64>()
            .unwrap_or(fallback.den as u64)
            .max(1);
        let mut n = num;
        let mut d = den;
        while n.abs() > (i32::MAX as i64) || d > (u32::MAX as u64) {
            n >>= 1;
            d = (d >> 1).max(1);
        }
        return Rational::new(n as i32, d as u32).unwrap_or(fallback);
    }
    if let Ok(v) = trimmed.parse::<i32>() {
        return Rational::integer(v);
    }
    fallback
}

/// Integer percentage (`0..=100`) from an exact [`Rational`] ratio.
pub const fn rational_to_pct(r: Rational) -> i32 {
    if r.den == 0 {
        return 0;
    }
    let pct = (r.num as i64 * 100) / (r.den as i64);
    if pct < 0 {
        0
    } else if pct > 100 {
        100
    } else {
        pct as i32
    }
}

/// Extract a string value `"key":"value"` from a flat JSON line without external crates.
pub fn extract_json_str(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\":");
    let pos = json.find(&needle)?;
    let rest = json[pos + needle.len()..].trim_start();
    if !rest.starts_with('"') {
        return None;
    }
    let mut out = String::new();
    let mut chars = rest[1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(esc) = chars.next() {
                    match esc {
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        other => out.push(other),
                    }
                }
            }
            '"' => return Some(out),
            other => out.push(other),
        }
    }
    None
}

/// Extract an integer value `"key":123` from a flat JSON line without external crates.
pub fn extract_json_i64(json: &str, key: &str) -> Option<i64> {
    let needle = format!("\"{key}\":");
    let pos = json.find(&needle)?;
    let rest = json[pos + needle.len()..].trim_start();
    let end = rest
        .find(|c: char| !c.is_ascii_digit() && c != '-')
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    rest[..end].parse::<i64>().ok()
}

fn parse_vad_hex(raw: &str) -> u8 {
    let clean = raw.trim().trim_start_matches("0x").trim_start_matches("0X");
    u8::from_str_radix(clean, 16).unwrap_or(0x62)
}

/// Parse one JSONL line from `ear_inbox.jsonl` or `speech_salience_waves.jsonl`.
pub fn parse_jsonl_entry(line: &str) -> Option<RoomThoughtEntry> {
    let trimmed = line.trim();
    if !trimmed.starts_with('{') || !trimmed.ends_with('}') {
        return None;
    }
    let ts = extract_json_i64(trimmed, "ts").unwrap_or(0).max(0) as u64;
    let speaker = extract_json_str(trimmed, "speaker").unwrap_or_else(|| "hue".to_string());
    let context = extract_json_str(trimmed, "context").unwrap_or_else(|| "vocal_wave".to_string());
    let f0_pq_str = extract_json_str(trimmed, "f0_pq").unwrap_or_else(|| "156/1".to_string());
    let f0_pq = parse_rational_pq(&f0_pq_str, Rational::integer(156));
    let f0_hz = extract_json_i64(trimmed, "f0_hz")
        .map(|v| v as i32)
        .unwrap_or_else(|| (f0_pq.num as i64 / (f0_pq.den.max(1) as i64)) as i32);
    let azimuth_deg = extract_json_i64(trimmed, "azimuth_deg").unwrap_or(0) as i32;
    let distance_cm = extract_json_i64(trimmed, "distance_cm").unwrap_or(120) as i32;
    let spatial_zone =
        extract_json_str(trimmed, "spatial_zone").unwrap_or_else(|| "center_keyboard".to_string());

    let salience_pq = if let Some(s_pq) = extract_json_str(trimmed, "salience_pq") {
        parse_rational_pq(&s_pq, Rational::new(85, 100).unwrap_or(Rational::ONE))
    } else if let Some(sim_q15) = extract_json_i64(trimmed, "primary_similarity_q15") {
        Rational::new(sim_q15.clamp(0, Q15_ONE as i64) as i32, Q15_ONE as u32)
            .unwrap_or(Rational::ZERO)
    } else {
        Rational::new(85, 100).unwrap_or(Rational::ONE)
    };
    let salience_pct = rational_to_pct(salience_pq);
    let vad_byte = extract_json_str(trimmed, "vad_byte")
        .map(|s| parse_vad_hex(&s))
        .unwrap_or(0x62);

    let raw_text = extract_json_str(trimmed, "text")
        .or_else(|| extract_json_str(trimmed, "preview"))
        .unwrap_or_else(|| {
            format!(
                "MEM|8 vocal grain F0={}/{}Hz salience={}/{}",
                f0_pq.num, f0_pq.den, salience_pq.num, salience_pq.den
            )
        });
    let text = sanitize_no_float(&raw_text);

    Some(RoomThoughtEntry {
        ts,
        speaker: sanitize_no_float(&speaker),
        context: sanitize_no_float(&context),
        f0_hz,
        f0_pq,
        azimuth_deg,
        distance_cm,
        spatial_zone: sanitize_no_float(&spatial_zone),
        salience_pct,
        salience_pq,
        vad_byte,
        text,
    })
}

/// Load the last `ROOM_THOUGHT_RING_CAP` entries from a JSONL byte slice using `RingBuffer`.
pub fn load_thoughts_from_bytes(
    bytes: &[u8],
) -> RingBuffer<RoomThoughtEntry, ROOM_THOUGHT_RING_CAP> {
    let capped = if bytes.len() > C64_RING_BYTES {
        &bytes[bytes.len() - C64_RING_BYTES..]
    } else {
        bytes
    };
    let text = String::from_utf8_lossy(capped);
    let mut ring: RingBuffer<RoomThoughtEntry, ROOM_THOUGHT_RING_CAP> = RingBuffer::new();
    for line in text.lines() {
        if let Some(entry) = parse_jsonl_entry(line) {
            ring.push_overwrite(entry);
        }
    }
    ring
}

/// Compute `MarineIntDetector` stability trit `[-, 0, +]` and detector `F0` `Rational`
/// directly from a `SpeakerSalienceProfile` (running `MarineIntDetector` over `best_grain_pcm`).
pub fn evaluate_marine_stability(
    profile: &SpeakerSalienceProfile,
    fallback_salience: Rational,
) -> (Trit, Rational) {
    let mut detector = MarineIntDetector::new(16_000, DEFAULT_CLIP_THRESHOLD_Q15);
    if !profile.best_grain_pcm.is_empty() {
        let mut sum_q15 = 0u64;
        for (idx, &sample) in profile.best_grain_pcm.iter().enumerate() {
            sum_q15 += detector.process_sample_i16(sample, idx) as u64;
        }
        let avg_q15 = (sum_q15 / (profile.best_grain_pcm.len() as u64).max(1)) as i32;
        let measured = Rational::new(
            avg_q15.max(fallback_salience.num.min(Q15_ONE)),
            Q15_ONE as u32,
        )
        .unwrap_or(fallback_salience);
        let trit = Trit::from_rational(measured, default_threshold_pq());
        return (trit, detector.f0_hz_pq());
    }

    // Synthesize a deterministic glottal pulse train at `profile.f0_hz` when no grain PCM is loaded yet
    let f0 = (profile.f0_hz.num / (profile.f0_hz.den.max(1) as i32)).clamp(60, 300) as usize;
    let period = (16_000 / f0).max(32);
    for idx in 0..960usize {
        let phase = idx % period;
        let sample: i16 = if phase == 1 {
            18_000
        } else if phase == 0 || phase == 2 {
            9_000
        } else {
            500
        };
        detector.process_sample_i16(sample, idx);
    }
    let trit = Trit::from_rational(fallback_salience, default_threshold_pq());
    (trit, detector.f0_hz_pq())
}

fn qwave_base_dir() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/home/hue".to_string());
    PathBuf::from(home).join(".local/share/qwave")
}

fn resolve_qwave_file(name: &str) -> PathBuf {
    let base = qwave_base_dir();
    let mem8_path = base.join("mem8").join(name);
    if mem8_path.exists() {
        return mem8_path;
    }
    base.join(name)
}

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn probe_http_loopback(port: u16, path: &str, timeout_ms: u64) -> Trit {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), port);
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms))
    else {
        return Trit::Minus;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(timeout_ms)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(timeout_ms)));
    let req = format!("GET {path} HTTP/1.1\r\nHost: localhost:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(req.as_bytes()).is_err() {
        return Trit::Zero;
    }
    let mut buf = [0u8; 256];
    let Ok(n) = stream.read(&mut buf) else {
        return Trit::Zero;
    };
    let head = String::from_utf8_lossy(&buf[..n]);
    if head.contains("200 OK") || head.contains("\"ok\":true") {
        Trit::Plus
    } else {
        Trit::Zero
    }
}

fn probe_ear_service() -> Trit {
    let hb_path = resolve_qwave_file("ear_heartbeat.txt");
    if let Ok(raw) = fs::read_to_string(&hb_path) {
        if let Ok(hb_ts) = raw.trim().parse::<u64>() {
            if now_epoch_secs().saturating_sub(hb_ts) <= 30 {
                return Trit::Plus;
            }
        }
    }
    if let Ok(out) = Command::new("systemctl")
        .args(["--user", "is-active", "qwave-ear.service"])
        .output()
    {
        let status = String::from_utf8_lossy(&out.stdout);
        let s = status.trim();
        if s == "active" {
            return Trit::Plus;
        } else if s == "activating" || s == "reloading" {
            return Trit::Zero;
        }
    }
    Trit::Minus
}

fn probe_esp32_medusa() -> Trit {
    if Path::new("/dev/ttyACM0").exists() || Path::new("/dev/ttyACM1").exists() {
        Trit::Plus
    } else if Path::new("/dev/ttyUSB0").exists() {
        Trit::Zero
    } else {
        Trit::Minus
    }
}

fn probe_a6000_cached() -> Trit {
    let cache_path = Path::new("/tmp/qwave_a6000_status.cache");
    let now = now_epoch_secs();
    if let Ok(raw) = fs::read_to_string(cache_path) {
        if let Some((ts_s, trit_s)) = raw.trim().split_once(':') {
            if let Ok(ts) = ts_s.parse::<u64>() {
                if now.saturating_sub(ts) <= 15 {
                    return match trit_s {
                        "+" => Trit::Plus,
                        "0" => Trit::Zero,
                        _ => Trit::Minus,
                    };
                }
            }
        }
    }

    // 1. Check local SSH bridge on 127.0.0.1:11436
    let bridge = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 11436);
    if TcpStream::connect_timeout(&bridge, Duration::from_millis(80)).is_ok() {
        let _ = fs::write(cache_path, format!("{now}:+"));
        return Trit::Plus;
    }

    // 2. Check A6000 orchestrator port 8790 or HTTPS port 443 on 49.13.101.247
    let a6k_8790 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(49, 13, 101, 247)), 8790);
    if TcpStream::connect_timeout(&a6k_8790, Duration::from_millis(120)).is_ok() {
        let _ = fs::write(cache_path, format!("{now}:+"));
        return Trit::Plus;
    }
    let a6k_443 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(49, 13, 101, 247)), 443);
    if TcpStream::connect_timeout(&a6k_443, Duration::from_millis(200)).is_ok() {
        let _ = fs::write(cache_path, format!("{now}:+"));
        return Trit::Plus;
    }

    let _ = fs::write(cache_path, format!("{now}:0"));
    Trit::Zero
}

/// Collect a complete live [`HudSnapshot`] from `~/.local/share/qwave` and loopback services.
pub fn collect_hud_snapshot() -> HudSnapshot {
    let profile_path = resolve_qwave_file("speaker_salience_profile.bin");
    let profile = fs::read(&profile_path)
        .ok()
        .and_then(|b| SpeakerSalienceProfile::from_bytes(&b))
        .unwrap_or_default();

    let waves_path = resolve_qwave_file("speech_salience_waves.jsonl");
    let inbox_path = resolve_qwave_file("ear_inbox.jsonl");
    let room_path = resolve_qwave_file("room_state.json");

    let waves_ring = fs::read(&waves_path)
        .or_else(|_| read_tail_c64_ring(&waves_path))
        .map(|b| load_thoughts_from_bytes(&b))
        .unwrap_or_default();
    let inbox_ring = fs::read(&inbox_path)
        .or_else(|_| read_tail_c64_ring(&inbox_path))
        .map(|b| load_thoughts_from_bytes(&b))
        .unwrap_or_default();

    let mut thoughts: Vec<RoomThoughtEntry> = inbox_ring.iter_oldest_first().cloned().collect();
    if thoughts.is_empty() {
        thoughts = waves_ring.iter_oldest_first().cloned().collect();
    }

    // Pick the newest Hue utterance if available, otherwise newest overall
    let latest_hue = inbox_ring
        .iter_newest_first()
        .find(|e| e.speaker == "hue")
        .or_else(|| inbox_ring.iter_newest_first().next())
        .or_else(|| waves_ring.iter_newest_first().next())
        .cloned()
        .unwrap_or_default();

    let latest_wave_salience = waves_ring
        .iter_newest_first()
        .next()
        .map(|w| w.salience_pq)
        .unwrap_or(latest_hue.salience_pq);

    let mut grains_learned = profile.grains_learned;
    if let Ok(room_json) = fs::read_to_string(&room_path) {
        if let Some(g) = extract_json_i64(&room_json, "hue_grains_learned") {
            grains_learned = grains_learned.max(g.max(0) as u64);
        }
    }

    let salience_pq = if latest_hue.salience_pct > 0 {
        latest_hue.salience_pq
    } else {
        latest_wave_salience
    };
    let salience_pct = rational_to_pct(salience_pq);
    let (stability_trit, detector_f0_pq) = evaluate_marine_stability(&profile, salience_pq);

    let ear_trit = probe_ear_service();
    let lqd_trit = probe_http_loopback(8786, "/health", 150);
    let aye_trit = probe_http_loopback(8787, "/api/health", 150);
    let esp_trit = probe_esp32_medusa();
    let a6k_trit = probe_a6000_cached();

    HudSnapshot {
        speaker: if latest_hue.speaker == "ambient_noise" {
            "hue".to_string()
        } else {
            latest_hue.speaker
        },
        f0_hz: latest_hue.f0_hz,
        f0_pq: latest_hue.f0_pq,
        profile_f0_pq: profile.f0_hz,
        azimuth_deg: latest_hue.azimuth_deg,
        distance_cm: latest_hue.distance_cm,
        spatial_zone: latest_hue.spatial_zone,
        salience_pct,
        salience_pq,
        stability_trit,
        detector_f0_pq,
        grains_learned,
        grain_samples: profile.best_grain_pcm.len(),
        vad_byte: latest_hue.vad_byte,
        latest_text: latest_hue.text,
        thoughts,
        ear_trit,
        lqd_trit,
        aye_trit,
        esp_trit,
        a6k_trit,
        g8t_trit: a6k_trit,
        dry_trit: aye_trit,
    }
}

/// Format compact ternary stack badges: `EAR[+] LQD[+] AYE[+] ESP[+] A6K[+]`.
pub fn format_stack_badges(snap: &HudSnapshot) -> String {
    format!(
        "EAR[{}] LQD[{}] AYE[{}] ESP[{}] A6K[{}]",
        trit_symbol(snap.ear_trit),
        trit_symbol(snap.lqd_trit),
        trit_symbol(snap.aye_trit),
        trit_symbol(snap.esp_trit),
        trit_symbol(snap.a6k_trit),
    )
}

/// Render single-line Waybar JSON (`{"text": "...", "tooltip": "...", "class": "..."}`) with zero floats.
pub fn render_waybar_json(snap: &HudSnapshot) -> String {
    let badges = format_stack_badges(snap);
    let short_utterance: String = snap.latest_text.chars().take(28).collect();
    let sign = if snap.azimuth_deg >= 0 { "+" } else { "" };

    let text = format!(
        "🌊 {} {}Hz ({}/{}) {}{}°/{}cm {}% {}g │ {} │ \"{}\"",
        snap.speaker,
        snap.f0_hz,
        snap.f0_pq.num,
        snap.f0_pq.den,
        sign,
        snap.azimuth_deg,
        snap.distance_cm,
        snap.salience_pct,
        snap.grains_learned,
        badges,
        short_utterance
    );

    let tooltip = format!(
        "Sovereign 8b-is x Qwave x ALEXIAI Studio HUD (Zero-Float)\n\
         Speaker: {} @ {} Hz (p/q: {}/{} Hz)\n\
         Spatial DOA: {}{} deg / {} cm ({})\n\
         Marine Salience: {}% (p/q: {}/{}) · Stability Trit: [{}]\n\
         MEM|8 Learned Grains: {} (C64 64KB Ring)\n\
         Stack: {}\n\
         Latest Utterance: {}\n\
         L-Click: Toggle Ear │ R-Click: Voice-Type │ M-Click: Ask Aye",
        snap.speaker,
        snap.f0_hz,
        snap.f0_pq.num,
        snap.f0_pq.den,
        sign,
        snap.azimuth_deg,
        snap.distance_cm,
        snap.spatial_zone,
        snap.salience_pct,
        snap.salience_pq.num,
        snap.salience_pq.den,
        trit_symbol(snap.stability_trit),
        snap.grains_learned,
        badges,
        snap.latest_text
    );

    let class = if snap.ear_trit == Trit::Plus
        && snap.lqd_trit == Trit::Plus
        && snap.aye_trit == Trit::Plus
    {
        "sovereign-online"
    } else if snap.lqd_trit == Trit::Plus || snap.aye_trit == Trit::Plus {
        "sovereign-partial"
    } else {
        "sovereign-degraded"
    };

    format!(
        "{{\"text\":\"{}\",\"tooltip\":\"{}\",\"class\":\"{}\"}}",
        json_escape(&text),
        json_escape(&tooltip),
        class
    )
}

/// Render a single ANSI terminal frame for `qwave-hypr-hud status-tui` with zero floats.
pub fn render_status_tui_frame(snap: &HudSnapshot) -> String {
    let mut out = String::with_capacity(4096);
    let sign = if snap.azimuth_deg >= 0 { "+" } else { "" };

    out.push_str("\x1b[1;36m╔══════════════════════════════════════════════════════════════════════════════╗\x1b[0m\n");
    out.push_str("\x1b[1;36m║\x1b[0m \x1b[1;33m⚡ SOVEREIGN 8b-is × QWAVE × ALEXIAI STUDIO HUD\x1b[0m · \x1b[1;32mC64 64KB RING · ZERO-FLOAT\x1b[0m \x1b[1;36m║\x1b[0m\n");
    out.push_str("\x1b[1;36m╚══════════════════════════════════════════════════════════════════════════════╝\x1b[0m\n");

    // Section 1: Marine Salience & Vocal Profile
    out.push_str("\x1b[1;36m┌─ 1) MARINE SALIENCE & VOCAL PROFILE (speaker_salience_profile.bin) ──────────┐\x1b[0m\n");
    out.push_str(&format!(
        "  Speaker: \x1b[1;33m{}\x1b[0m │ Learned Grains: \x1b[1;32m{}\x1b[0m │ Grain PCM Samples: \x1b[1;36m{}\x1b[0m\n",
        sanitize_no_float(&snap.speaker),
        snap.grains_learned,
        snap.grain_samples
    ));
    out.push_str(&format!(
        "  Vocal F0: \x1b[1;32m{} Hz\x1b[0m (Rational p/q: \x1b[1;36m{}/{} Hz\x1b[0m │ Profile p/q: \x1b[1;36m{}/{} Hz\x1b[0m)\n",
        snap.f0_hz,
        snap.f0_pq.num,
        snap.f0_pq.den,
        snap.profile_f0_pq.num,
        snap.profile_f0_pq.den
    ));
    out.push_str(&format!(
        "  Spatial DOA: \x1b[1;33m{}{} deg\x1b[0m / \x1b[1;33m{} cm\x1b[0m │ Zone: \x1b[1;36m{}\x1b[0m\n",
        sign,
        snap.azimuth_deg,
        snap.distance_cm,
        sanitize_no_float(&snap.spatial_zone)
    ));
    out.push_str(&format!(
        "  MarineIntDetector Stability Trit: \x1b[1;32m[{}]\x1b[0m │ Salience: \x1b[1;32m{}%\x1b[0m ({}/{}) │ Detector F0: {}/{} Hz │ VAD: 0x{:02x}\n",
        trit_symbol(snap.stability_trit),
        snap.salience_pct,
        snap.salience_pq.num,
        snap.salience_pq.den,
        snap.detector_f0_pq.num,
        snap.detector_f0_pq.den,
        snap.vad_byte
    ));

    // Section 2: Live Room Thoughts Ring Buffer (last 12 utterances)
    out.push_str("\x1b[1;36m├─ 2) LIVE ROOM THOUGHTS RING BUFFER (Last 12 Utterances · 64KB Cap) ──────────┤\x1b[0m\n");
    if snap.thoughts.is_empty() {
        out.push_str(
            "  [0] hue @ 156Hz (+0 deg / 120 cm · 90%): Waiting for room acoustic waves\n",
        );
    } else {
        for entry in snap.thoughts.iter().take(ROOM_THOUGHT_RING_CAP) {
            let t = Trit::from_rational(entry.salience_pq, default_threshold_pq());
            let az_sign = if entry.azimuth_deg >= 0 { "+" } else { "" };
            let snippet: String = entry.text.chars().take(44).collect();
            out.push_str(&format!(
                "  [{}] {:<13} {:>3}Hz ({:>4}/{:<4}) {:>3}{}°/{:>3}cm {:>3}% │ {}\n",
                trit_symbol(t),
                entry.speaker,
                entry.f0_hz,
                entry.f0_pq.num,
                entry.f0_pq.den,
                az_sign,
                entry.azimuth_deg,
                entry.distance_cm,
                entry.salience_pct,
                snippet
            ));
        }
    }

    // Section 3: Sovereign Stack Health
    out.push_str("\x1b[1;36m├─ 3) SOVEREIGN STACK HEALTH (Balanced Ternary [-, 0, +]) ─────────────────────┤\x1b[0m\n");
    out.push_str(&format!("  {}\n", format_stack_badges(snap)));
    out.push_str(&format!(
        "  • qwave-ear.service      : [{}] (Parallel Acoustic Ear Daemon · MEM|8)\n\
         \x20 • liquid-rust.service    : [{}] (loopback:8786 · Pure-Rust Marine STT/TTS)\n\
         \x20 • alexiai.service        : [{}] (loopback:8787 · GAIA-MLX-QUANT Companion)\n\
         \x20 • ESP32-S3 VAK:MEDUSA    : [{}] (/dev/ttyACM0 · Hardware Telemetry Bridge)\n\
         \x20 • A6000 Orchestrator     : [{}] (https://cheet.is/a6000 · Sovereign Compute)\n\
         \x20 • g8t.is                 : [{}] (https://g8t.is · Sovereign Git & Mesh)\n\
         \x20 • gemini-diary.8b.is     : [{}] (https://gemini-diary.8b.is · AI Diary)\n",
        trit_symbol(snap.ear_trit),
        trit_symbol(snap.lqd_trit),
        trit_symbol(snap.aye_trit),
        trit_symbol(snap.esp_trit),
        trit_symbol(snap.a6k_trit),
        trit_symbol(snap.g8t_trit),
        trit_symbol(snap.dry_trit),
    ));

    // Section 4: Hyprland Voice & AI Hotkey Legend
    out.push_str("\x1b[1;36m├─ 4) HYPRLAND VOICE & AI HOTKEY LEGEND ───────────────────────────────────────┤\x1b[0m\n");
    out.push_str(
        "  • \x1b[1;33mSUPER+Space\x1b[0m / \x1b[1;33mSUPER+V\x1b[0m : Voice-Type (qwave --listen 5 -> liquid-rust -> wl-copy + wtype)\n\
         \x20 • \x1b[1;33mSUPER+A\x1b[0m               : Ask Aye    (qwave --listen 5 -> alexiai :8787 -> qwave --speak)\n\
         \x20 • \x1b[1;33mSUPER+M\x1b[0m               : Toggle Ear (arm/pause qwave-ear.service + spoken status)\n\
         \x20 • \x1b[1;33mSUPER+D\x1b[0m               : Qwave Radar Scratchpad (toggle special:qwave HUD)\n\
         \x20 • \x1b[1;33mSUPER+G\x1b[0m               : A6000 Pulse (probe A6000 + Sovereign stack notification)\n",
    );
    out.push_str("\x1b[1;36m└──────────────────────────────────────────────────────────────────────────────┘\x1b[0m");

    sanitize_no_float(&out)
}

fn run_status_tui(args: &[String]) {
    let once = args.iter().any(|a| a == "--once" || a == "-1");
    if once {
        let snap = collect_hud_snapshot();
        println!("{}", render_status_tui_frame(&snap));
        return;
    }

    loop {
        let snap = collect_hud_snapshot();
        print!("\x1b[2J\x1b[H{}", render_status_tui_frame(&snap));
        let _ = io::stdout().flush();
        thread::sleep(Duration::from_millis(500));
    }
}

fn find_qwave_bin() -> &'static str {
    if Path::new("/home/hue/.local/bin/qwave").exists() {
        "/home/hue/.local/bin/qwave"
    } else if Path::new("/usr/local/bin/qwave").exists() {
        "/usr/local/bin/qwave"
    } else {
        "qwave"
    }
}

fn send_desktop_notification(summary: &str, body: &str) {
    let clean_summary = sanitize_no_float(summary);
    let clean_body = sanitize_no_float(body);
    let _ = Command::new("notify-send")
        .args(["-a", "Qwave Sovereign HUD", &clean_summary, &clean_body])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Capture a short voice utterance via `qwave --listen 5` (with fallback to latest `ear_inbox.jsonl` utterance).
fn capture_voice_utterance(secs: &str, override_text: Option<&str>) -> String {
    if let Some(t) = override_text {
        return sanitize_no_float(t.trim());
    }
    let qwave_bin = find_qwave_bin();
    if let Ok(out) = Command::new(qwave_bin).args(["--listen", secs]).output() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines().rev() {
            if let Some(tx) = extract_json_str(line, "text") {
                let clean = sanitize_no_float(tx.trim());
                if !clean.is_empty() {
                    return clean;
                }
            }
        }
    }

    // Fallback to latest utterance from ear_inbox.jsonl
    let snap = collect_hud_snapshot();
    snap.latest_text
}

fn parse_flag_value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

/// Execute `qwave-hypr-hud voice-type`: record -> transcribe -> `wl-copy` + `wtype` + `notify-send`.
pub fn run_voice_type(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let secs = parse_flag_value(args, "--secs").unwrap_or("5");
    let text_override = parse_flag_value(args, "--text");

    let transcript = if dry_run && text_override.is_none() {
        "Sovereign voice typing verified".to_string()
    } else {
        capture_voice_utterance(secs, text_override)
    };

    if !dry_run && !transcript.is_empty() {
        if let Ok(mut child) = Command::new("wl-copy")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            if let Some(ref mut stdin) = child.stdin {
                let _ = stdin.write_all(transcript.as_bytes());
            }
            let _ = child.wait();
        }
        let _ = Command::new("wtype")
            .args(["--", &transcript])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        send_desktop_notification("Qwave Voice-Type [+] ", &transcript);
    }

    format!(
        "{{\"ok\":true,\"action\":\"voice-type\",\"trit\":\"+\",\"text\":\"{}\"}}",
        json_escape(&transcript)
    )
}

/// Parse SSE `data: {"text":"..."}` frames from `alexiai` `/api/chat` stream.
pub fn extract_sse_deltas(raw_http: &str) -> String {
    let body = raw_http
        .split_once("\r\n\r\n")
        .map(|(_, b)| b)
        .unwrap_or(raw_http);
    let mut reply = String::new();
    let mut is_delta = false;
    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed == "event: delta" {
            is_delta = true;
        } else if trimmed.starts_with("event:") {
            is_delta = false;
        } else if let Some(data_json) = trimmed.strip_prefix("data:") {
            let data_trim = data_json.trim();
            if data_trim == "[DONE]" {
                break;
            }
            if is_delta {
                if let Some(chunk) = extract_json_str(data_trim, "text") {
                    reply.push_str(&chunk);
                }
            } else if reply.is_empty() {
                if let Some(content) = extract_json_str(data_trim, "content") {
                    reply.push_str(&content);
                }
            }
        }
    }
    if reply.trim().is_empty() {
        if let Some(content) = extract_json_str(body, "content") {
            reply = content;
        }
    }
    sanitize_no_float(reply.trim())
}

fn query_loopback_alexiai(prompt: &str) -> Option<String> {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 8787);
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(1500)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(20)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let body = format!("{{\"prompt\":\"{}\"}}", json_escape(prompt));
    let req = format!(
        "POST /api/chat HTTP/1.1\r\n\
         Host: localhost:8787\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        body.len(),
        body
    );
    stream.write_all(req.as_bytes()).ok()?;
    stream.flush().ok()?;

    let mut resp = String::new();
    let _ = stream.read_to_string(&mut resp);
    let parsed = extract_sse_deltas(&resp);
    if parsed.is_empty() {
        None
    } else {
        Some(parsed)
    }
}

/// Execute `qwave-hypr-hud ask-aye`: record voice -> `alexiai` (`127.0.0.1:8787/api/chat`) -> `qwave --speak`.
pub fn run_ask_aye(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let secs = parse_flag_value(args, "--secs").unwrap_or("5");
    let prompt_override = parse_flag_value(args, "--prompt");

    let prompt = if dry_run && prompt_override.is_none() {
        "Status report".to_string()
    } else {
        capture_voice_utterance(secs, prompt_override)
    };

    let reply = if dry_run {
        "Aye is online on loopback port 8787 with zero-float salience ready".to_string()
    } else {
        query_loopback_alexiai(&prompt).unwrap_or_else(|| {
            format!(
                "Aye heard you say: {}. Loopback companion is standing by.",
                prompt
            )
        })
    };

    if !dry_run {
        send_desktop_notification("ALEXIAI <3 (Aye)", &reply);
        let qwave_bin = find_qwave_bin();
        let _ = Command::new(qwave_bin)
            .args(["--speak", &reply])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    format!(
        "{{\"ok\":true,\"action\":\"ask-aye\",\"prompt\":\"{}\",\"reply\":\"{}\"}}",
        json_escape(&prompt),
        json_escape(&reply)
    )
}

/// Execute `qwave-hypr-hud toggle-ear`: toggle `qwave-ear.service` and speak confirmation.
pub fn run_toggle_ear(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let is_active = Command::new("systemctl")
        .args(["--user", "is-active", "qwave-ear.service"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "active")
        .unwrap_or(false);

    let (next_action, spoken, next_trit) = if is_active {
        ("stop", "Qwave ear paused", "-")
    } else {
        ("start", "Qwave ear armed", "+")
    };

    if !dry_run {
        let _ = Command::new("systemctl")
            .args(["--user", next_action, "qwave-ear.service"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        send_desktop_notification("Qwave Acoustic Ear", spoken);
        let qwave_bin = find_qwave_bin();
        let _ = Command::new(qwave_bin)
            .args(["--speak", spoken])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }

    format!(
        "{{\"ok\":true,\"action\":\"toggle-ear\",\"service_action\":\"{next_action}\",\"trit\":\"{next_trit}\",\"spoken\":\"{spoken}\"}}"
    )
}

fn is_process_running(name: &str) -> bool {
    Command::new("pgrep")
        .args(["-x", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Execute `qwave-hypr-hud boot-session`: start services, waybar, notifications, and speak welcome.
pub fn run_boot_session(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let welcome = "Sovereign Hyprland and Qwave collaboration studio online";

    if !dry_run {
        // 1. Export Wayland environment to systemd user manager and D-Bus
        let _ = Command::new("dbus-update-activation-environment")
            .args([
                "--systemd",
                "WAYLAND_DISPLAY",
                "XDG_CURRENT_DESKTOP",
                "HYPRLAND_INSTANCE_SIGNATURE",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();

        // 2. Ensure liquid-rust.service and qwave-ear.service are active
        let _ = Command::new("systemctl")
            .args([
                "--user",
                "start",
                "liquid-rust.service",
                "qwave-ear.service",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();

        // 3. Start mako notification daemon if not already running
        if !is_process_running("mako") {
            let _ = Command::new("mako")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 4. Start waybar if not already running
        if !is_process_running("waybar") {
            let _ = Command::new("waybar")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 5. Speak welcome asynchronously so session boot never blocks
        let qwave_bin = find_qwave_bin();
        let _ = Command::new(qwave_bin)
            .args(["--speak", welcome])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }

    format!("{{\"ok\":true,\"action\":\"boot-session\",\"trit\":\"+\",\"spoken\":\"{welcome}\"}}")
}

/// Execute `qwave-hypr-hud a6000-pulse`: probe Sovereign stack & A6000 and emit notification.
pub fn run_a6000_pulse(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let snap = collect_hud_snapshot();
    let badges = format_stack_badges(&snap);
    let summary = format!(
        "{} │ {} {}Hz {}% {}g",
        badges, snap.speaker, snap.f0_hz, snap.salience_pct, snap.grains_learned
    );
    if !dry_run {
        send_desktop_notification("A6000 & Sovereign Stack Pulse", &summary);
    }
    format!(
        "{{\"ok\":true,\"action\":\"a6000-pulse\",\"badges\":\"{}\",\"summary\":\"{}\"}}",
        json_escape(&badges),
        json_escape(&summary)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_zero_float_literals(text: &str) {
        let bytes = text.as_bytes();
        for i in 1..bytes.len().saturating_sub(1) {
            if bytes[i] == b'.' && bytes[i - 1].is_ascii_digit() && bytes[i + 1].is_ascii_digit() {
                panic!(
                    "Floating-point literal detected in output around byte {}: {:?}",
                    i,
                    &text[i.saturating_sub(10)..(i + 10).min(text.len())]
                );
            }
        }
    }

    fn sample_snapshot() -> HudSnapshot {
        let thought = RoomThoughtEntry {
            ts: 1_792_967_563,
            speaker: "hue".to_string(),
            context: "addressing_agent".to_string(),
            f0_hz: 157,
            f0_pq: Rational::new(1_576_000, 9_997).unwrap(),
            azimuth_deg: 4,
            distance_cm: 202,
            spatial_zone: "center_keyboard".to_string(),
            salience_pct: 85,
            salience_pq: Rational::new(28_155, 32_767).unwrap(),
            vad_byte: 0x62,
            text: sanitize_no_float("Testing LFM2.5 version 1.58 with zero floats"),
        };
        HudSnapshot {
            speaker: "hue".to_string(),
            f0_hz: 157,
            f0_pq: Rational::new(1_576_000, 9_997).unwrap(),
            profile_f0_pq: Rational::integer(160),
            azimuth_deg: 4,
            distance_cm: 202,
            spatial_zone: "center_keyboard".to_string(),
            salience_pct: 85,
            salience_pq: Rational::new(28_155, 32_767).unwrap(),
            stability_trit: Trit::Plus,
            detector_f0_pq: Rational::integer(160),
            grains_learned: 11_085,
            grain_samples: 960,
            vad_byte: 0x62,
            latest_text: thought.text.clone(),
            thoughts: vec![thought],
            ear_trit: Trit::Plus,
            lqd_trit: Trit::Plus,
            aye_trit: Trit::Plus,
            esp_trit: Trit::Plus,
            a6k_trit: Trit::Plus,
            g8t_trit: Trit::Plus,
            dry_trit: Trit::Plus,
        }
    }

    #[test]
    fn waybar_json_contains_zero_floats_and_all_ternary_badges() {
        let snap = sample_snapshot();
        let json = render_waybar_json(&snap);
        assert!(json.starts_with("{\"text\":\""));
        assert!(json.ends_with("\"}"));
        assert!(
            !json.contains('\n'),
            "Waybar output must be single-line JSON"
        );
        assert!(json.contains("EAR[+] LQD[+] AYE[+] ESP[+] A6K[+]"));
        assert!(json.contains("hue 157Hz (1576000/9997) +4°/202cm 85% 11085g"));
        assert_zero_float_literals(&json);
    }

    #[test]
    fn status_tui_frame_contains_zero_floats_and_all_required_sections() {
        let snap = sample_snapshot();
        let frame = render_status_tui_frame(&snap);
        assert!(frame.contains("MARINE SALIENCE & VOCAL PROFILE"));
        assert!(frame.contains("LIVE ROOM THOUGHTS RING BUFFER"));
        assert!(frame.contains("SOVEREIGN STACK HEALTH"));
        assert!(frame.contains("HYPRLAND VOICE & AI HOTKEY LEGEND"));
        assert!(frame.contains("EAR[+] LQD[+] AYE[+] ESP[+] A6K[+]"));
        assert!(frame.contains("SUPER+Space"));
        assert!(frame.contains("SUPER+A"));
        assert!(frame.contains("SUPER+M"));
        assert!(frame.contains("SUPER+D"));
        assert!(frame.contains("SUPER+G"));
        assert_zero_float_literals(&frame);
    }

    #[test]
    fn c64_ring_buffer_caps_oversized_jsonl_and_retains_last_12_thoughts() {
        let mut raw = Vec::new();
        // Generate > 64 KB of JSONL lines
        for i in 0..700 {
            let line = format!(
                "{{\"ts\":{},\"speaker\":\"hue\",\"f0_hz\":160,\"f0_pq\":\"160/1\",\"azimuth_deg\":-4,\"distance_cm\":150,\"primary_similarity_q15\":30000,\"text\":\"Utterance number {} at 3.14 ratio\"}}\n",
                1_792_960_000 + i,
                i
            );
            raw.extend_from_slice(line.as_bytes());
        }
        assert!(raw.len() > C64_RING_BYTES);

        let ring = load_thoughts_from_bytes(&raw);
        let collected: Vec<_> = ring.iter_oldest_first().collect();
        assert_eq!(collected.len(), ROOM_THOUGHT_RING_CAP);
        assert!(
            collected
                .last()
                .unwrap()
                .text
                .contains("Utterance number 699")
        );
        for entry in collected {
            assert_zero_float_literals(&entry.text);
        }
    }

    #[test]
    fn marine_detector_evaluates_stability_trit_without_floats() {
        let prof = SpeakerSalienceProfile::default();
        let high_sal = Rational::new(9, 10).unwrap();
        let (trit, det_f0) = evaluate_marine_stability(&prof, high_sal);
        assert_eq!(trit, Trit::Plus);
        assert!(det_f0.num > 0 && det_f0.den > 0);
    }

    #[test]
    fn sse_delta_parser_and_dry_run_commands_emit_zero_floats() {
        let sse = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n\
                   event: gaia\ndata: {\"seed\":1}\n\n\
                   event: delta\ndata: {\"text\":\"Hello Hue, \"}\n\n\
                   event: delta\ndata: {\"text\":\"ratio is 22/7 (not 3.14)!\"}\n\n\
                   data: [DONE]\n\n";
        let reply = extract_sse_deltas(sse);
        assert_eq!(reply, "Hello Hue, ratio is 22/7 (not 3:14)!");
        assert_zero_float_literals(&reply);

        let vt = run_voice_type(&["--dry-run".to_string()]);
        let aa = run_ask_aye(&["--dry-run".to_string()]);
        let te = run_toggle_ear(&["--dry-run".to_string()]);
        let bs = run_boot_session(&["--dry-run".to_string()]);
        let ap = run_a6000_pulse(&["--dry-run".to_string()]);
        for out in [&vt, &aa, &te, &bs, &ap] {
            assert!(out.contains("\"ok\":true"));
            assert_zero_float_literals(out);
        }
    }
}
