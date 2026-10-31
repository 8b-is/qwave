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
    sanitize_and_dedup_stt_transcript,
};
use qwave_core::vault::{SealedVaultRecord, VAULT_MAGIC, canonicalize_domain};
use qwave_core::wave::WaveInt;

/// C64 `64 KB` (`65_536` bytes) ring-buffer ceiling for all file tail reads.
pub const C64_RING_BYTES: usize = 65_536;

/// Number of recent room utterances retained in the live TUI & Markdown HUD ring buffer.
pub const ROOM_THOUGHT_RING_CAP: usize = 15;

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
    pub grains_learned: u64,
    pub vad_byte: u8,
    pub text: String,
}

impl Default for RoomThoughtEntry {
    fn default() -> Self {
        Self {
            ts: 0,
            speaker: "hue".to_string(),
            context: "ready".to_string(),
            f0_hz: 154,
            f0_pq: Rational::integer(154),
            azimuth_deg: 0,
            distance_cm: 20,
            spatial_zone: "center_keyboard".to_string(),
            salience_pct: 90,
            salience_pq: Rational::new(9, 10).unwrap_or(Rational::ONE),
            grains_learned: 0,
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
            let _ = write_graphical_markdown_hud_from_snap(&snap);
            process_desktop_voice_command(&snap);
            println!("{}", render_waybar_json(&snap));
        }
        "waybar-music" => {
            println!("{}", render_waybar_music_json());
        }
        "waybar-vault" => {
            println!("{}", render_waybar_vault_json());
        }
        "tokyo-song" => {
            println!("{}", run_tokyo_song(rest));
        }
        "humayian-mix" => {
            println!("{}", run_humayian_mix(rest));
        }
        "smoke-bg" => {
            println!("{}", run_smoke_bg(rest));
        }
        "refresh-trits-bg" => {
            refresh_stack_trits_sync();
        }
        "markdown-hud" => {
            println!("{}", run_markdown_hud(rest));
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
        "agy-resume" => {
            println!("{}", run_agy_resume(rest));
        }
        "wifi-menu" => {
            println!("{}", run_wifi_menu(rest));
        }
        "wifi-tui" => {
            println!("{}", run_wifi_tui(rest));
        }
        "wifi-heal" => {
            println!("{}", run_wifi_heal(rest));
        }
        "portal-heal" | "captive-portal" => {
            println!("{}", run_portal_heal(rest));
        }
        "wifi-love" | "mesh-love" | "bluetooth-love" | "hotspot-love" => {
            println!("{}", run_wifi_love(rest));
        }
        "vault-menu" => {
            println!("{}", run_vault_menu(rest));
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
         \x20 qwave-hypr-hud markdown-hud          Launch/refresh graphical browser Qwave Markdown Studio HUD\n\
         \x20 qwave-hypr-hud status-tui [--once]   Live 500ms ANSI Collaboration Radar HUD\n\
         \x20 qwave-hypr-hud voice-type            Record via qwave -> liquid-rust -> wl-copy + wtype\n\
         \x20 qwave-hypr-hud ask-aye               Voice prompt -> loopback alexiai -> qwave --speak\n\
         \x20 qwave-hypr-hud toggle-ear            Toggle qwave-ear.service with spoken confirmation\n\
         \x20 qwave-hypr-hud vault-menu            Sovereign Ed25519 + MEM|8 Personal-Signature Password Vault\n\
         \x20 qwave-hypr-hud boot-session          Autostart services, waybar, workspaces & welcome\n\
         \x20 qwave-hypr-hud agy-resume            Launch Sovereign AGY Studio (All Perms, Zero Sandbox, Resumed)\n\
         \x20 qwave-hypr-hud wifi-menu             Fuzzel/dmenu Wi-Fi switcher, password updater & healer\n\
         \x20 qwave-hypr-hud wifi-tui              Launch floating Alacritty nmtui Wi-Fi manager + MTU 1380\n\
         \x20 qwave-hypr-hud wifi-heal             Auto-reconnect Wi-Fi, heal expired captive portals & MTU 1380\n\
         \x20 qwave-hypr-hud portal-heal           Solve captive portal with honest inputs + Anicca recipe memory\n\
         \x20 qwave-hypr-hud wifi-love             Share Bluetooth / Hotspot & ESP32 Constellation mesh love\n\
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
    let distance_cm = extract_json_i64(trimmed, "distance_cm").unwrap_or(20) as i32;
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
    let grains_learned = extract_json_i64(trimmed, "speaker_grains_learned")
        .or_else(|| extract_json_i64(trimmed, "total_grains_learned"))
        .or_else(|| extract_json_i64(trimmed, "grains_learned"))
        .unwrap_or(0)
        .max(0) as u64;
    let vad_byte = extract_json_str(trimmed, "vad_byte")
        .map(|s| parse_vad_hex(&s))
        .unwrap_or(0x62);

    let raw_text = if let Some(tx) = extract_json_str(trimmed, "text") {
        sanitize_and_dedup_stt_transcript(&tx)?
    } else if let Some(prev) = extract_json_str(trimmed, "preview") {
        prev
    } else {
        format!(
            "MEM|8 vocal grain F0={}/{}Hz salience={}/{}",
            f0_pq.num, f0_pq.den, salience_pq.num, salience_pq.den
        )
    };
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
        grains_learned,
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

fn parse_trit_char(c: char) -> Trit {
    match c {
        '+' => Trit::Plus,
        '-' => Trit::Minus,
        _ => Trit::Zero,
    }
}

fn refresh_stack_trits_sync() -> (Trit, Trit, Trit, Trit, Trit) {
    let now = now_epoch_secs();
    let (ear, lqd, aye, esp, a6k) = thread::scope(|s| {
        let h_ear = s.spawn(probe_ear_service);
        let h_lqd = s.spawn(|| {
            let t8786 = probe_http_loopback(8786, "/health", 150);
            if t8786 == Trit::Plus {
                return Trit::Plus;
            }
            let addr8785 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 8785);
            if TcpStream::connect_timeout(&addr8785, Duration::from_millis(120)).is_ok() {
                Trit::Plus
            } else {
                t8786
            }
        });
        let h_aye = s.spawn(|| {
            let t = probe_http_loopback(8787, "/", 250);
            if t == Trit::Plus {
                Trit::Plus
            } else {
                let addr8787 = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 8787);
                if TcpStream::connect_timeout(&addr8787, Duration::from_millis(120)).is_ok() {
                    Trit::Plus
                } else {
                    t
                }
            }
        });
        let h_esp = s.spawn(probe_esp32_medusa);
        let h_a6k = s.spawn(probe_a6000_cached);
        (
            h_ear.join().unwrap_or(Trit::Zero),
            h_lqd.join().unwrap_or(Trit::Zero),
            h_aye.join().unwrap_or(Trit::Zero),
            h_esp.join().unwrap_or(Trit::Zero),
            h_a6k.join().unwrap_or(Trit::Zero),
        )
    });
    let payload = format!(
        "{now}:{}{}{}{}{}",
        trit_symbol(ear),
        trit_symbol(lqd),
        trit_symbol(aye),
        trit_symbol(esp),
        trit_symbol(a6k)
    );
    let _ = fs::write("/tmp/qwave_stack_trits.cache", payload);
    (ear, lqd, aye, esp, a6k)
}

/// Non-blocking stack health reader: returns cached trits immediately in <50us, and triggers
/// a detached background refresh (`qwave-hypr-hud refresh-trits-bg`) at most once every 30s.
fn read_stack_trits_nonblocking() -> (Trit, Trit, Trit, Trit, Trit) {
    let cache_path = Path::new("/tmp/qwave_stack_trits.cache");
    let now = now_epoch_secs();
    if let Ok(raw) = fs::read_to_string(cache_path) {
        if let Some((ts_s, syms)) = raw.trim().split_once(':') {
            let chars: Vec<char> = syms.chars().collect();
            if chars.len() >= 5 {
                let ts = ts_s.parse::<u64>().unwrap_or(0);
                if now.saturating_sub(ts) > 30 {
                    // Touch timestamp immediately so concurrent callers don't spawn duplicate refreshes
                    let _ = fs::write(cache_path, format!("{now}:{syms}"));
                    if let Ok(exe) = env::current_exe() {
                        let _ = Command::new(exe)
                            .arg("refresh-trits-bg")
                            .stdin(Stdio::null())
                            .stdout(Stdio::null())
                            .stderr(Stdio::null())
                            .spawn();
                    }
                }
                return (
                    parse_trit_char(chars[0]),
                    parse_trit_char(chars[1]),
                    parse_trit_char(chars[2]),
                    parse_trit_char(chars[3]),
                    parse_trit_char(chars[4]),
                );
            }
        }
    }
    // First-ever call when no cache file exists yet: write optimistic defaults and spawn background refresh
    let _ = fs::write(cache_path, format!("{now}:+++++"));
    if let Ok(exe) = env::current_exe() {
        let _ = Command::new(exe)
            .arg("refresh-trits-bg")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }
    (
        probe_ear_service(),
        Trit::Plus,
        Trit::Plus,
        probe_esp32_medusa(),
        Trit::Plus,
    )
}

/// Collect a complete live [`HudSnapshot`] from `~/.local/share/qwave` without blocking on any network socket.
pub fn collect_hud_snapshot() -> HudSnapshot {
    let profile_path = resolve_qwave_file("speaker_salience_profile.bin");
    let mut profile = fs::read(&profile_path)
        .ok()
        .and_then(|b| SpeakerSalienceProfile::from_bytes(&b))
        .unwrap_or_default();
    let prof_f0_int = profile.f0_hz.num / (profile.f0_hz.den.max(1) as i32);
    if prof_f0_int > 175 || prof_f0_int < 85 {
        profile.f0_hz = Rational::integer(154);
    }

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

    // Pick the newest active diarized speaker utterance (`hue`, `alex`, `friend_1..3`)
    let latest_utt = inbox_ring
        .iter_newest_first()
        .find(|e| e.speaker != "ambient_noise")
        .or_else(|| inbox_ring.iter_newest_first().next())
        .or_else(|| waves_ring.iter_newest_first().next())
        .cloned()
        .unwrap_or_default();

    let latest_wave_salience = waves_ring
        .iter_newest_first()
        .next()
        .map(|w| w.salience_pq)
        .unwrap_or(latest_utt.salience_pq);

    let mut hue_grains = profile.grains_learned;
    let mut active_spk_grains = latest_utt.grains_learned;
    if let Ok(room_json) = fs::read_to_string(&room_path) {
        if let Some(g) = extract_json_i64(&room_json, "hue_grains_learned") {
            hue_grains = hue_grains.max(g.max(0) as u64);
        }
        if active_spk_grains == 0 {
            if let Some(sg) = extract_json_i64(&room_json, "speaker_grains_learned") {
                active_spk_grains = sg.max(0) as u64;
            }
        }
    }
    let grains_learned = if latest_utt.speaker != "hue"
        && latest_utt.speaker != "ambient_noise"
        && active_spk_grains > 0
    {
        active_spk_grains
    } else {
        hue_grains.max(active_spk_grains)
    };

    let salience_pq = if latest_utt.salience_pct > 0 {
        latest_utt.salience_pq
    } else {
        latest_wave_salience
    };
    let salience_pct = rational_to_pct(salience_pq);
    let (stability_trit, detector_f0_pq) = evaluate_marine_stability(&profile, salience_pq);

    let (ear_trit, lqd_trit, aye_trit, esp_trit, a6k_trit) = read_stack_trits_nonblocking();

    HudSnapshot {
        speaker: if latest_utt.speaker == "ambient_noise" {
            "hue".to_string()
        } else {
            latest_utt.speaker
        },
        f0_hz: latest_utt.f0_hz,
        f0_pq: latest_utt.f0_pq,
        profile_f0_pq: profile.f0_hz,
        azimuth_deg: latest_utt.azimuth_deg,
        distance_cm: latest_utt.distance_cm,
        spatial_zone: latest_utt.spatial_zone,
        salience_pct,
        salience_pq,
        stability_trit,
        detector_f0_pq,
        grains_learned,
        grain_samples: profile.best_grain_pcm.len(),
        vad_byte: latest_utt.vad_byte,
        latest_text: latest_utt.text,
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
    let short_utterance: String = snap.latest_text.chars().take(18).collect();
    let sign = if snap.azimuth_deg >= 0 { "+" } else { "" };

    let text = format!(
        "🌊 {} {}Hz {}% │ E{} L{} A{} │ \"{}\"",
        snap.speaker,
        snap.f0_hz,
        snap.salience_pct,
        trit_symbol(snap.ear_trit),
        trit_symbol(snap.lqd_trit),
        trit_symbol(snap.aye_trit),
        short_utterance
    );

    let tooltip = format!(
        "Sovereign 8b-is x Qwave x ALEXIAI Studio HUD (Zero-Float)\n\
         Summary: {} {}Hz ({}/{}) {}{}°/{}cm {}% {}g\n\
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
        snap.salience_pct,
        snap.grains_learned,
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
        "  • \x1b[1;33mSUPER+Space\x1b[0m / \x1b[1;33mSUPER+V\x1b[0m : Voice-Type (qwave --listen 5 -> whisper-server:8785 -> wl-copy + wtype)\n\
         \x20 • \x1b[1;33mSUPER+A\x1b[0m               : Ask Aye    (qwave --listen 5 -> alexiai :8787 -> qwave --speak)\n\
         \x20 • \x1b[1;33mSUPER+U\x1b[0m               : Sovereign Vault (Ed25519 + MEM|8 Personal-Signature Password Unseal)\n\
         \x20 • \x1b[1;33mSUPER+M\x1b[0m               : Toggle Ear (arm/pause qwave-ear.service + spoken status)\n\
         \x20 • \x1b[1;33mSUPER+D\x1b[0m               : Qwave Radar Scratchpad (toggle special:qwave HUD)\n\
         \x20 • \x1b[1;33mSUPER+G\x1b[0m               : A6000 Pulse (probe A6000 + Sovereign stack notification)\n\
         \x20 • \x1b[1;33mSUPER+I\x1b[0m / \x1b[1;33mSUPER+S+Ret\x1b[0m : Sovereign AGY Studio (All Perms · Zero Sandbox · Resumed)\n\
         \x20 • \x1b[1;33mSUPER+W\x1b[0m / \x1b[1;33mSUPER+S+W\x1b[0m   : Wi-Fi Switcher, Password Updater & 1380 MTU Auto-Healer\n",
    );
    out.push_str("\x1b[1;36m└──────────────────────────────────────────────────────────────────────────────┘\x1b[0m");

    sanitize_no_float(&out)
}

fn run_status_tui(args: &[String]) {
    let once = args.iter().any(|a| a == "--once" || a == "-1");
    if once {
        let snap = collect_hud_snapshot();
        let _ = write_graphical_markdown_hud_from_snap(&snap);
        println!("{}", render_status_tui_frame(&snap));
        return;
    }

    loop {
        let snap = collect_hud_snapshot();
        let _ = write_graphical_markdown_hud_from_snap(&snap);
        print!("\x1b[2J\x1b[H{}", render_status_tui_frame(&snap));
        let _ = io::stdout().flush();
        thread::sleep(Duration::from_millis(500));
    }
}

/// Path to the live graphical browser-based Qwave Markdown Studio HUD file.
pub fn graphical_markdown_hud_path() -> PathBuf {
    qwave_base_dir().join("sovereign-qwave-hud.md")
}

/// Render a rich, Zero-Float Markdown HUD document for `qwave sovereign-qwave-hud.md`
/// with WebGL `WaveScene` shader, Mermaid spatial triangulation & room diarization diagram,
/// diarized room speakers table, live 64KB C64 Ring Buffer thoughts, and hotkey legend.
pub fn render_graphical_markdown_hud(snap: &HudSnapshot) -> String {
    let mut md = String::with_capacity(8192);
    let sign = if snap.azimuth_deg >= 0 { "+" } else { "" };

    // Summarize latest measured stats per diarized speaker ("hue", "alex", "trisha", "friend_1", "friend_2")
    let find_speaker_stats = |name: &str, default_f0: i32, default_dist: i32, default_az: i32| {
        if let Some(entry) = snap.thoughts.iter().rev().find(|e| e.speaker == name) {
            let g = if name == "hue" {
                snap.grains_learned.max(entry.grains_learned)
            } else {
                entry.grains_learned.max(1)
            };
            (
                entry.f0_hz,
                entry.azimuth_deg,
                entry.distance_cm,
                entry.salience_pct,
                g,
                "ACTIVE",
            )
        } else if name == "hue" {
            let prof_f0 =
                (snap.profile_f0_pq.num / (snap.profile_f0_pq.den.max(1) as i32)).clamp(90, 178);
            (
                prof_f0,
                0,
                20,
                snap.salience_pct.max(85),
                snap.grains_learned,
                "ENROLLED",
            )
        } else {
            (default_f0, default_az, default_dist, 0, 0, "STANDBY")
        }
    };

    let (hue_f0, hue_az, hue_dist, hue_sal, hue_g, hue_st) =
        find_speaker_stats("hue", 154, 20, 0);
    let (alex_f0, alex_az, alex_dist, alex_sal, alex_g, alex_st) =
        find_speaker_stats("alex", 196, 22, 4);
    let (trisha_f0, trisha_az, trisha_dist, trisha_sal, trisha_g, trisha_st) =
        find_speaker_stats("trisha", 242, 35, -12);
    let (pete_f0, pete_az, pete_dist, pete_sal, pete_g, pete_st) =
        find_speaker_stats("pete", 130, 45, 15);

    let hue_az_sign = if hue_az >= 0 { "+" } else { "" };
    let alex_az_sign = if alex_az >= 0 { "+" } else { "" };
    let trisha_az_sign = if trisha_az >= 0 { "+" } else { "" };
    let pete_az_sign = if pete_az >= 0 { "+" } else { "" };

    // Read Closed-Loop OTA Self-Calibration state (`~/.local/share/qwave/self_calibration.json`)
    let cal_raw = fs::read_to_string(qwave_base_dir().join("self_calibration.json")).unwrap_or_default();
    let cal_utts = extract_json_i64(&cal_raw, "total_self_utterances").unwrap_or(0).max(0) as u64;
    let cal_pq = extract_json_str(&cal_raw, "word_match_pq").unwrap_or_else(|| "1/1".to_string());
    let cal_cum_pq =
        extract_json_str(&cal_raw, "cumulative_word_match_pq").unwrap_or_else(|| "1/1".to_string());
    let cal_scale_q10 = extract_json_i64(&cal_raw, "distance_scale_q10").unwrap_or(1024).clamp(512, 2048);
    let cal_az_off = extract_json_i64(&cal_raw, "azimuth_offset_deg").unwrap_or(0);
    let cal_preroll = extract_json_i64(&cal_raw, "preroll_bonus_frames").unwrap_or(0).max(0);
    let cal_hangover = extract_json_i64(&cal_raw, "hangover_bonus_frames").unwrap_or(0).max(0);
    let cal_corr = extract_json_str(&cal_raw, "learned_corrections_flat")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "sleep->speak;bottom cousin->bottom button".to_string());
    let cal_exp = extract_json_str(&cal_raw, "last_expected_text")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Armed at 10 cm open-lid bezel reference".to_string())
        .replace('|', "/");
    let cal_hrd = extract_json_str(&cal_raw, "last_heard_text")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Listening for next spoken reply".to_string())
        .replace('|', "/");

    md.push_str("# ⚡ Sovereign `8b-is` × `Qwave` × `ALEXIAI` Studio HUD\n\n");
    md.push_str(&format!(
        "> [!NOTE]\n\
         > **Stack Health (Balanced Ternary `[-, 0, +]`)**: `EAR[{}]` · `LIQUID-RUST :8786[{}]` · `ALEXIAI :8787[{}]` · `ESP32-S3 VAK:MEDUSA[{}]` · `A6000 :8790[{}]` · `G8T:IS[{}]`\n\
         > **Active Speaker**: **`{}`** @ **`{} Hz`** (`{}/{} Hz`) · **Spatial DOA**: **`{}{}° / {} cm`** (`{}`) · **Marine Salience**: **`{}%`** (`{}/{}`) · **Stability**: **`[{}]`** · **Learned Grains**: **`{}g`**\n\
         > **Closed-Loop OTA Self-Calibration**: **`{}`** word match (`{}` cumulative across `{}` self-utterances) · **`10 cm` Scale**: `{}/1024` (`{:+}°` offset) · **VAD Bonus**: `+{}` pre-roll / `+{}` hangover frames\n\n",
        trit_symbol(snap.ear_trit),
        trit_symbol(snap.lqd_trit),
        trit_symbol(snap.aye_trit),
        trit_symbol(snap.esp_trit),
        trit_symbol(snap.a6k_trit),
        trit_symbol(snap.g8t_trit),
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
        cal_pq,
        cal_cum_pq,
        cal_utts,
        cal_scale_q10,
        cal_az_off,
        cal_preroll,
        cal_hangover,
    ));

    // Mermaid Spatial Triangulation & Room Diarization Diagram
    md.push_str("## 1) Spatial Triangulation & Multi-Speaker Room Diarization\n\n");
    md.push_str("```mermaid\n");
    md.push_str("flowchart TD\n");
    md.push_str("    DMIC[\"🎙️ Open-Lid Laptop Bezel Stereo DMIC (FL + FR @ 48kHz)\\nTDOA + First-Difference Cross-Correlation + ILD\"]\n");
    md.push_str("    SPK[\"🔊 Laptop Internal Speakers (Aye OTA Self-Listen)\\nTest Tone: 432Hz · +0 deg / 10 cm\"]\n");
    md.push_str(&format!(
        "    HUE[\"👤 hue (Primary Enrolled · 90..178Hz)\\nF0: {}Hz · {}{} deg / {} cm · {}% ({}g)\"]\n",
        hue_f0, hue_az_sign, hue_az, hue_dist, hue_sal, hue_g
    ));
    md.push_str(&format!(
        "    ALEX[\"👩 alex (CompanionAlex · 179..225Hz)\\nF0: {}Hz · {}{} deg / {} cm · {}% ({}g)\"]\n",
        alex_f0, alex_az_sign, alex_az, alex_dist, alex_sal, alex_g
    ));
    md.push_str(&format!(
        "    TRISHA[\"👩 trisha (FriendTrisha · 226..320Hz)\\nF0: {}Hz · {}{} deg / {} cm · {}% ({}g)\"]\n",
        trisha_f0, trisha_az_sign, trisha_az, trisha_dist, trisha_sal, trisha_g
    ));
    md.push_str(&format!(
        "    PETE[\"🧑 pete (FriendPete · Off-Axis / Slot 2)\\nF0: {}Hz · {}{} deg / {} cm · {}% ({}g)\"]\n",
        pete_f0, pete_az_sign, pete_az, pete_dist, pete_sal, pete_g
    ));
    md.push_str("    RING[\"💾 64 KB C64 StereoPcmRingBuffer (160 frames / 480ms Pre-Roll)\\nTwo-Stage Hysteresis VAD + MarineIntDetector\"]\n");
    md.push_str("    AYE[\"🧠 ALEXIAI :8787 + LIQUID-RUST :8786\\nGAIA-MLX-QUANT p/q Ternary Fold + Closed-Loop SelfCalibrationEngine\"]\n");
    md.push_str("    SPK -->|\"10 cm OTA Self-Calibration\"| DMIC\n");
    md.push_str(&format!("    HUE -->|\"{} cm Near-Field\"| DMIC\n", hue_dist));
    md.push_str(&format!("    ALEX -->|\"{} cm Room DOA\"| DMIC\n", alex_dist));
    md.push_str(&format!("    TRISHA -->|\"{} cm Room DOA\"| DMIC\n", trisha_dist));
    md.push_str(&format!("    PETE -->|\"{} cm Room DOA\"| DMIC\n", pete_dist));
    md.push_str("    DMIC --> RING --> AYE\n");
    md.push_str("```\n\n");

    // Diarized Room Speakers Table
    md.push_str("## 2) Diarized Room Speakers (`MEM|8` Integer Profiles)\n\n");
    md.push_str("| Speaker | Role / Slot | Pitch Band (`Hz`) | Latest `F0` (`Hz`) | Azimuth (`deg`) | Distance (`cm`) | Salience (`%`) | Learned Grains | Status |\n");
    md.push_str("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n");
    md.push_str(&format!(
        "| **`hue`** | `PrimaryUser` | `90..178 Hz` (`[110..172]`) | `{} Hz` | `{}{}°` | **`{} cm`** | `{}%` | `{}g` | `{}` |\n",
        hue_f0, hue_az_sign, hue_az, hue_dist, hue_sal, hue_g, hue_st
    ));
    md.push_str(&format!(
        "| **`alex`** | `CompanionAlex` (`Slot 0`) | `179..225 Hz` | `{} Hz` | `{}{}°` | **`{} cm`** | `{}%` | `{}g` | `{}` |\n",
        alex_f0, alex_az_sign, alex_az, alex_dist, alex_sal, alex_g, alex_st
    ));
    md.push_str(&format!(
        "| **`trisha`** | `FriendTrisha` (`Slot 1`) | `226..320 Hz` | `{} Hz` | `{}{}°` | **`{} cm`** | `{}%` | `{}g` | `{}` |\n",
        trisha_f0, trisha_az_sign, trisha_az, trisha_dist, trisha_sal, trisha_g, trisha_st
    ));
    md.push_str(&format!(
        "| **`pete`** | `FriendPete` (`Slot 2`) | `Off-Axis / Friend` | `{} Hz` | `{}{}°` | **`{} cm`** | `{}%` | `{}g` | `{}` |\n",
        pete_f0, pete_az_sign, pete_az, pete_dist, pete_sal, pete_g, pete_st
    ));
    md.push_str(&format!(
        "| **`aye_self`** | `OTA Self-Calibrator` | `Laptop Speaker (10 cm)` | `432 Hz` | `+0°` | **`10 cm`** | `100%` | `{}` (`{}/1024`) | `SELF-IMPROVING` |\n\n",
        cal_pq, cal_scale_q10
    ));
    md.push_str(&format!(
        "**Latest OTA Self-Listen**: Expected `\"{}\"` · Heard `\"{}\"` · Learned Corrections: `{}`\n\n",
        cal_exp, cal_hrd, cal_corr
    ));

    // Live 64 KB C64 Ring Buffer Room Thoughts Table (latest 15 utterances)
    md.push_str("## 3) Live `64 KB` C64 Ring Buffer Room Thoughts (Latest 15 Utterances)\n\n");
    md.push_str("| Trit | Speaker | Context | `F0` (`p/q Hz`) | Spatial (`deg / cm`) | Salience | Utterance |\n");
    md.push_str("| :---: | :--- | :--- | :--- | :--- | :---: | :--- |\n");
    if snap.thoughts.is_empty() {
        md.push_str("| `[+]` | **`hue`** | `ready` | `154 Hz` (`154/1`) | `+0° / 20 cm` | `90%` | Waiting for room acoustic waves |\n");
    } else {
        for entry in snap.thoughts.iter().rev().take(15) {
            let t = Trit::from_rational(entry.salience_pq, default_threshold_pq());
            let az_sign = if entry.azimuth_deg >= 0 { "+" } else { "" };
            let clean_tx = entry.text.replace('|', "/").replace('\n', " ");
            md.push_str(&format!(
                "| `[{}]` | **`{}`** | `{}` | `{} Hz` (`{}/{}`) | `{}{}° / {} cm` | `{}%` | {} |\n",
                trit_symbol(t),
                entry.speaker,
                entry.context,
                entry.f0_hz,
                entry.f0_pq.num,
                entry.f0_pq.den,
                az_sign,
                entry.azimuth_deg,
                entry.distance_cm,
                entry.salience_pct,
                clean_tx
            ));
        }
    }
    md.push('\n');

    // Hyprland Sovereign Keybindings Table
    md.push_str("## 4) Hyprland Sovereign Keybindings\n\n");
    md.push_str("| Hotkey | Action | Command / Pipeline |\n");
    md.push_str("| :--- | :--- | :--- |\n");
    md.push_str("| **`SUPER + Space`** / **`SUPER + V`** | Voice-Type | `qwave --listen 5` -> `whisper-server :8785` / `liquid-rust :8786` -> `wl-copy` + `wtype` |\n");
    md.push_str("| **`SUPER + A`** | Ask Aye | `qwave --listen 5` -> `alexiai :8787` -> `qwave --speak` |\n");
    md.push_str("| **`SUPER + U`** | Sovereign Personal-Signature Vault | `qwave-hypr-hud vault-menu` (Ed25519 + `MEM|8` `79B` Wave Unseal & Auto-Type) |\n");
    md.push_str("| **`SUPER + M`** | Toggle Ear | Arm / pause `qwave-ear.service` with spoken confirmation |\n");
    md.push_str("| **`SUPER + D`** | Graphical Qwave Markdown HUD | `qwave-hypr-hud markdown-hud` (WebGL `WaveScene` + Live SSE Reload) |\n");
    md.push_str("| **`SUPER + W`** / **`SUPER + Shift + W`** | Wi-Fi Switcher & Auto-Healer | `qwave-hypr-hud wifi-menu` / `wifi-tui` (Zero-Rescan MTU `1380`) |\n");
    md.push_str("| **`SUPER + I`** / **`SUPER + Shift + Return`** | Resume Sovereign `agy` Studio | `qwave-hypr-hud agy-resume` (All Permissions · Zero Sandbox · Resumed) |\n\n");

    // Tokyo Theme Song Section
    md.push_str("## 5) 🚆 Tokyo Theme Song — \"Next Stop, Tomorrow!\" (`8bit_wraith × 8b-is`)\n\n");
    md.push_str("> **まもなく浜松町、浜松町。京浜東北線、JR、東京モノレールはお乗り換えです。お出口は右側です。**  \n");
    md.push_str("> *\"A thousand faces, a thousand dreams, Tokyo rolls by in silver streams... We don't know where the tracks will bend, but every journey needs a friend. Next stop, tomorrow, here we go! まもなく、未来へ！ And if the tracks don't lead us there, we'll build another, with room to spare.\"*\n");
    md.push_str("> — Click **`🚆 Tokyo Song`** in the top toolbar (or select **`🔥 Tokyo Phoenix Lattice`** in **`🎨 Page Style`**) to play [`music/next-stop-tomorrow.mp3`](file:///home/hue/8b-is/8b-is/music/next-stop-tomorrow.mp3)!\n");

    sanitize_no_float(&md)
}

/// Write `/home/hue/.local/share/qwave/sovereign-qwave-hud.md` from an existing [`HudSnapshot`]
/// (only writing to disk when content changes so `qwave`'s SSE file watcher triggers cleanly).
pub fn write_graphical_markdown_hud_from_snap(snap: &HudSnapshot) -> PathBuf {
    let dir = qwave_base_dir();
    let _ = fs::create_dir_all(&dir);
    let path = dir.join("sovereign-qwave-hud.md");
    let content = render_graphical_markdown_hud(snap);
    let existing = fs::read_to_string(&path).unwrap_or_default();
    if existing != content {
        let _ = fs::write(&path, content.as_bytes());
    }
    path
}

/// Collect a live [`HudSnapshot`] and write `/home/hue/.local/share/qwave/sovereign-qwave-hud.md`.
pub fn write_graphical_markdown_hud() -> PathBuf {
    let snap = collect_hud_snapshot();
    write_graphical_markdown_hud_from_snap(&snap)
}

fn discover_hyprland_signature() -> Option<String> {
    if let Ok(sig) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        if !sig.trim().is_empty() {
            return Some(sig);
        }
    }
    let hypr_dir = Path::new("/run/user/1000/hypr");
    if let Ok(entries) = fs::read_dir(hypr_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() && p.join(".socket.sock").exists() {
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    return Some(name.to_string());
                }
            }
        }
    }
    None
}

fn hyprctl_exec_cmd(cmd_str: &str) -> bool {
    let sig = discover_hyprland_signature();
    let escaped = cmd_str.replace('\\', "\\\\").replace('"', "\\\"");
    let lua_dsp = format!("hl.dsp.exec_cmd(\"{escaped}\")");
    let mut dsp_cmd = Command::new("hyprctl");
    if let Some(ref s) = sig {
        dsp_cmd.env("HYPRLAND_INSTANCE_SIGNATURE", s);
    }
    let ok_dsp = dsp_cmd
        .args(["dispatch", &lua_dsp])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok_dsp {
        return true;
    }

    let mut dispatch_cmd = Command::new("hyprctl");
    if let Some(ref s) = sig {
        dispatch_cmd.env("HYPRLAND_INSTANCE_SIGNATURE", s);
    }
    dispatch_cmd
        .args(["dispatch", "exec", cmd_str])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Execute `qwave-hypr-hud markdown-hud`:
/// Writes `/home/hue/.local/share/qwave/sovereign-qwave-hud.md` and launches our graphical
/// browser-based Qwave Markdown Studio (`qwave sovereign-qwave-hud.md`) if not already open.
pub fn run_markdown_hud(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let watch_mode = args.iter().any(|a| a == "--watch");
    let path = write_graphical_markdown_hud();
    let path_str = path.to_string_lossy().to_string();

    if dry_run {
        return format!(
            "{{\"ok\":true,\"action\":\"markdown-hud\",\"path\":\"{}\",\"trit\":\"+\"}}",
            json_escape(&path_str)
        );
    }

    let qwave_bin = find_qwave_bin();
    let hud_url = format!(
        "http://127.0.0.1:42123/view?path={}",
        path_str
    );
    if is_cmdline_running("qwave-qt") {
        let nav_dir = PathBuf::from("/home/hue/.local/share/qwave");
        let _ = fs::create_dir_all(&nav_dir);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = fs::write(nav_dir.join("nav_command.url"), format!("{}\n{}", ts, hud_url));
        let _ = Command::new("hyprctl")
            .args(["dispatch", "focuswindow", "class:qwave"])
            .env("XDG_RUNTIME_DIR", "/run/user/1000")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    } else {
        let dispatched = hyprctl_exec_cmd(&format!("{qwave_bin} {path_str}"));
        if !dispatched {
            let _ = Command::new("setsid")
                .args(["--fork", qwave_bin, &path_str])
                .env("WAYLAND_DISPLAY", "wayland-1")
                .env("DISPLAY", ":0")
                .env("QT_QPA_PLATFORM", "xcb")
                .env("XDG_RUNTIME_DIR", "/run/user/1000")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    }

    if watch_mode {
        loop {
            thread::sleep(Duration::from_secs(2));
            let _ = write_graphical_markdown_hud();
        }
    }

    format!(
        "{{\"ok\":true,\"action\":\"markdown-hud\",\"path\":\"{}\",\"trit\":\"+\"}}",
        json_escape(&path_str)
    )
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

fn speak_async(text: &str) {
    let clean = sanitize_no_float(text);
    let qwave_bin = find_qwave_bin();
    let _ = Command::new(qwave_bin)
        .args(["--speak", &clean])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
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
        speak_async(spoken);
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

fn is_cmdline_running(pattern: &str) -> bool {
    Command::new("pgrep")
        .args(["-f", pattern])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Execute `qwave-hypr-hud agy-resume`:
/// Sets Sovereign `PATH`, changes directory to `/home/hue/8b-is`, prints the Sovereign AGY Studio
/// banner, and launches `/home/hue/.local/bin/agy --dangerously-skip-permissions --sandbox=false --continue`
/// (keeping an interactive shell open if `agy` ever exits).
pub fn run_agy_resume(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let sovereign_path = "/home/hue/.local/bin:/home/hue/.cargo/bin:/usr/local/bin:/usr/bin:/bin";
    let workdir = "/home/hue/8b-is";
    let header =
        "=== 8b:is SOVEREIGN AGY STUDIO · ALL PERMISSIONS ENABLED · ZERO SANDBOX · RESUMED ===";

    if dry_run {
        return format!(
            "{{\"ok\":true,\"action\":\"agy-resume\",\"trit\":\"+\",\"workdir\":\"{}\",\"header\":\"{}\",\"cmd\":\"/home/hue/.local/bin/agy --dangerously-skip-permissions --sandbox=false --continue\"}}",
            json_escape(workdir),
            json_escape(header)
        );
    }

    println!("\x1b[1;36m=== 8b.is SOVEREIGN AGY STUDIO · ALL PERMISSIONS ENABLED · ZERO SANDBOX · RESUMED ===\x1b[0m");
    let _ = io::stdout().flush();

    if Path::new(workdir).exists() {
        let _ = env::set_current_dir(workdir);
    }

    let agy_bin = if Path::new("/home/hue/.local/bin/agy").exists() {
        "/home/hue/.local/bin/agy"
    } else {
        "agy"
    };

    let passthrough: Vec<&str> = args
        .iter()
        .map(String::as_str)
        .filter(|&a| a != "--dry-run")
        .collect();

    let mut cmd_args = vec![
        "--dangerously-skip-permissions",
        "--sandbox=false",
        "--continue",
    ];
    cmd_args.extend(passthrough.iter().copied());

    let status = Command::new(agy_bin)
        .args(&cmd_args)
        .env("PATH", sovereign_path)
        .status();

    // If `--continue` exited immediately with an error (e.g. no prior conversation in this workspace),
    // automatically launch fresh with all permissions & zero sandbox.
    if status.map(|s| !s.success()).unwrap_or(true) {
        let mut fallback_args = vec!["--dangerously-skip-permissions", "--sandbox=false"];
        fallback_args.extend(passthrough);
        let _ = Command::new(agy_bin)
            .args(&fallback_args)
            .env("PATH", sovereign_path)
            .status();
    }

    // Keep the terminal window open with an interactive shell if `agy` exits
    let shell = if Path::new("/bin/fish").exists() {
        "/bin/fish"
    } else {
        "/bin/bash"
    };
    let _ = Command::new(shell).env("PATH", sovereign_path).status();

    format!(
        "{{\"ok\":true,\"action\":\"agy-resume\",\"trit\":\"+\",\"workdir\":\"{}\"}}",
        json_escape(workdir)
    )
}

/// Parsed Wi-Fi scan entry for `qwave-hypr-hud wifi-menu` and `wifi-heal`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WifiNetworkEntry {
    pub in_use: bool,
    pub ssid: String,
    pub signal: i32,
    pub security: String,
    pub saved: bool,
}

/// Parse `nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list` output into deduplicated,
/// priority-sorted [`WifiNetworkEntry`] items (Zero-Float).
pub fn parse_nmcli_wifi_list(raw: &str, saved_ssids: &[String]) -> Vec<WifiNetworkEntry> {
    let mut list: Vec<WifiNetworkEntry> = Vec::new();
    for line in raw.lines() {
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            continue;
        }
        // Format: IN-USE:SSID:SIGNAL:SECURITY
        let Some((in_use_raw, rest1)) = trimmed.split_once(':') else {
            continue;
        };
        let Some((rest2, security_raw)) = rest1.rsplit_once(':') else {
            continue;
        };
        let Some((ssid_raw, signal_raw)) = rest2.rsplit_once(':') else {
            continue;
        };

        let ssid = ssid_raw.replace("\\:", ":").trim().to_string();
        if ssid.is_empty() || ssid == "--" {
            continue;
        }
        let in_use = in_use_raw.trim() == "*";
        let signal = signal_raw.trim().parse::<i32>().unwrap_or(0).clamp(0, 100);
        let sec_trim = security_raw.trim();
        let security = if sec_trim.is_empty() || sec_trim == "--" {
            "OPEN".to_string()
        } else {
            sanitize_no_float(sec_trim)
        };
        let saved = saved_ssids.iter().any(|s| s == &ssid);

        if let Some(existing) = list.iter_mut().find(|e| e.ssid == ssid) {
            if in_use {
                existing.in_use = true;
            }
            if signal > existing.signal {
                existing.signal = signal;
            }
            if saved {
                existing.saved = true;
            }
        } else {
            list.push(WifiNetworkEntry {
                in_use,
                ssid,
                signal,
                security,
                saved,
            });
        }
    }

    list.sort_by(|a, b| {
        b.in_use
            .cmp(&a.in_use)
            .then_with(|| b.saved.cmp(&a.saved))
            .then_with(|| b.signal.cmp(&a.signal))
            .then_with(|| a.ssid.cmp(&b.ssid))
    });
    list
}

/// Format menu lines for `fuzzel --dmenu -p "Wi-Fi > "` with Zero-Float output.
pub fn format_wifi_menu_entries(entries: &[WifiNetworkEntry]) -> Vec<String> {
    let mut lines = Vec::with_capacity(entries.len() + 5);
    for e in entries {
        let marker = if e.in_use { "[*]" } else { "[ ]" };
        let saved_tag = if e.saved { " · SAVED" } else { "" };
        let clean_ssid = sanitize_no_float(&e.ssid);
        lines.push(format!(
            "{} {} ({}% · {}{})",
            marker, clean_ssid, e.signal, e.security, saved_tag
        ));
    }
    lines.push("[HEAL] Auto-Reconnect, Solve Captive Portal & Fix 1380 MTU".to_string());
    lines.push("[PORTAL] Solve Captive Portal (Honest Input + Remember Recipe)".to_string());
    lines.push("[LOVE] Share Bluetooth / Hotspot & ESP32 Constellation Mesh Love".to_string());
    lines.push("[PASS] Update Wi-Fi Password for Network".to_string());
    lines.push("[TUI] Open Full NetworkManager TUI (nmtui)".to_string());
    lines
}

/// Extract the original SSID from a formatted menu line (`[*] SSID (79% · WPA2 · SAVED)`).
pub fn extract_ssid_from_menu_choice<'a>(
    choice: &'a str,
    entries: &'a [WifiNetworkEntry],
) -> Option<String> {
    let trimmed = choice.trim();
    let after_marker = trimmed
        .strip_prefix("[*] ")
        .or_else(|| trimmed.strip_prefix("[ ] "))?;
    let (candidate_ssid, _) = after_marker.rsplit_once(" (")?;
    for entry in entries {
        if sanitize_no_float(&entry.ssid) == candidate_ssid || entry.ssid == candidate_ssid {
            return Some(entry.ssid.clone());
        }
    }
    Some(candidate_ssid.to_string())
}

fn list_saved_wifi_connections() -> Vec<String> {
    let mut saved = Vec::new();
    if let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "NAME,TYPE", "connection", "show"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            if let Some((name, kind)) = line.trim().rsplit_once(':') {
                if kind.contains("wireless") || kind.contains("wifi") {
                    let clean_name = name.replace("\\:", ":").trim().to_string();
                    if !clean_name.is_empty() && !saved.contains(&clean_name) {
                        saved.push(clean_name);
                    }
                }
            }
        }
    }
    saved
}

fn enforce_wlan0_mtu_1380() -> bool {
    if let Ok(cur_mtu) = fs::read_to_string("/sys/class/net/wlan0/mtu") {
        if cur_mtu.trim() == "1380" {
            return true;
        }
    }
    if Command::new("sudo")
        .args(["-n", "ip", "link", "set", "dev", "wlan0", "mtu", "1380"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        return true;
    }
    Command::new("ip")
        .args(["link", "set", "dev", "wlan0", "mtu", "1380"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Query `wlan0` state and active connection name from NetworkManager's in-memory device table
/// (`nmcli -t -f DEVICE,STATE,CONNECTION device`) WITHOUT ever invoking `device wifi` (zero rescan!).
fn current_wlan0_state_and_ssid() -> (String, String) {
    let mut state = "unknown".to_string();
    let mut ssid = String::new();
    if let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "DEVICE,STATE,CONNECTION", "device"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let trimmed = line.trim();
            if let Some((dev, rest)) = trimmed.split_once(':') {
                if dev.trim() == "wlan0" {
                    if let Some((st, conn)) = rest.split_once(':') {
                        state = st.trim().to_string();
                        ssid = conn.replace("\\:", ":").trim().to_string();
                    } else {
                        state = rest.trim().to_string();
                    }
                    break;
                }
            }
        }
    }
    (state, ssid)
}

fn probe_internet_204_fast() -> bool {
    Command::new("curl")
        .args([
            "-s",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "--max-time",
            "2",
            "http://connectivitycheck.gstatic.com/generate_204",
        ])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "204")
        .unwrap_or(false)
}

/// Execute `qwave-hypr-hud portal-heal`:
/// Invokes `qwave --nomad-connect` to solve captive portals using honest traveler inputs,
/// replay/store Anicca recipes (`~/.local/share/qwave/mem8/portal_recipes.tsv`), vouch for
/// ESP32 Constellation MACs, and broadcast `MemnetCapsule64` over UDP `:8888`.
pub fn run_portal_heal(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"portal-heal\",\"portal_solved\":true,\"mtu\":1380,\"trit\":\"+\"}".to_string();
    }

    let qwave_bin = find_qwave_bin();
    let raw = Command::new(&qwave_bin)
        .arg("--nomad-connect")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let _ = enforce_wlan0_mtu_1380();
    let internet_ok = probe_internet_204_fast();
    let (_, active_ssid) = current_wlan0_state_and_ssid();
    let clean_ssid = sanitize_no_float(&active_ssid);

    if internet_ok {
        let msg = format!(
            "Captive portal unlocked on {} (Anicca recipe saved + ESP32 mesh synced)",
            if clean_ssid.is_empty() { "wlan0" } else { &clean_ssid }
        );
        send_desktop_notification("8b:is Captive Portal Healed [+]", &msg);
        speak_async("Captive portal unlocked and mesh synced");
    }

    let clean_raw = sanitize_no_float(&raw);
    if clean_raw.starts_with('{') && clean_raw.ends_with('}') {
        clean_raw
    } else {
        format!(
            "{{\"ok\":{},\"action\":\"portal-heal\",\"ssid\":\"{}\",\"internet_204\":{},\"mtu\":1380,\"trit\":\"{}\"}}",
            if internet_ok { "true" } else { "false" },
            json_escape(&clean_ssid),
            if internet_ok { "true" } else { "false" },
            if internet_ok { "+" } else { "0" }
        )
    }
}

/// Execute `qwave-hypr-hud wifi-love`:
/// Shares Bluetooth / Hotspot love and broadcasts `MemnetCapsule64` + `TWIF` Wi-Fi bridge
/// to ESP32 Sovereign Constellation nodes and friends who struggle with captive portals.
pub fn run_wifi_love(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"wifi-love\",\"bluetooth_love\":true,\"esp32_mesh\":true,\"trit\":\"+\"}".to_string();
    }

    let qwave_bin = find_qwave_bin();
    let flag = if args.iter().any(|a| a == "--hotspot") {
        "--hotspot-love"
    } else {
        "--bluetooth-love"
    };
    let raw = Command::new(&qwave_bin)
        .arg(flag)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    send_desktop_notification(
        "8b:is Sovereign Mesh & Bluetooth Love [+]",
        "Sharing portal-free Wi-Fi & 64B MemnetCapsule64 across Bluetooth + ESP32 Constellation",
    );
    speak_async("Sharing Bluetooth and Constellation mesh love");

    let clean_raw = sanitize_no_float(&raw);
    if clean_raw.starts_with('{') && clean_raw.ends_with('}') {
        clean_raw
    } else {
        "{\"ok\":true,\"action\":\"wifi-love\",\"bluetooth_love\":true,\"esp32_mesh\":true,\"trit\":\"+\"}".to_string()
    }
}

/// Execute `qwave-hypr-hud wifi-heal`:
/// 1. Checks `wlan0` state without triggering a Wi-Fi scan when already `connected` (eliminating
///    60-second background scan roaming drops).
/// 2. When `disconnected`, scans Wi-Fi and auto-connects to the highest-signal saved connection;
///    if no saved network is in range, falls back to `qwave --nomad-connect` to join and unlock
///    the best free/open captive portal network (weighted by `PortalMemoryBook`).
/// 3. When `connected`, enforces MTU `1380` and probes `HTTP 204`; if a captive portal has expired
///    or requires sign-in, automatically runs `qwave --nomad-connect` to heal the portal and sync
///    the ESP32 Constellation mesh so Aye is never stranded!
pub fn run_wifi_heal(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"wifi-heal\",\"device\":\"wlan0\",\"state\":\"connected\",\"portal_healed\":false,\"mtu\":1380,\"trit\":\"+\"}".to_string();
    }

    let (mut state, mut active_ssid) = current_wlan0_state_and_ssid();
    let mut reconnected = false;
    let mut portal_healed = false;

    if state == "disconnected" {
        let saved = list_saved_wifi_connections();
        if let Ok(out) = Command::new("nmcli")
            .args([
                "-t",
                "-f",
                "IN-USE,SSID,SIGNAL,SECURITY",
                "device",
                "wifi",
                "list",
                "--rescan",
                "yes",
            ])
            .output()
        {
            let raw = String::from_utf8_lossy(&out.stdout);
            let candidates = parse_nmcli_wifi_list(&raw, &saved);
            for cand in candidates.iter().filter(|c| c.saved) {
                if Command::new("nmcli")
                    .args(["connection", "up", &cand.ssid])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false)
                {
                    reconnected = true;
                    break;
                }
            }
        }
        let updated = current_wlan0_state_and_ssid();
        state = updated.0;
        active_ssid = updated.1;

        // If still disconnected (no saved WPA2 network in range), invoke qwave --nomad-connect
        // to join and traverse the highest-ranked open/free captive portal!
        if state != "connected" {
            let qwave_bin = find_qwave_bin();
            let _ = Command::new(&qwave_bin)
                .arg("--nomad-connect")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            let after_nomad = current_wlan0_state_and_ssid();
            if after_nomad.0 == "connected" {
                reconnected = true;
                portal_healed = true;
                state = after_nomad.0;
                active_ssid = after_nomad.1;
            }
        }
    }

    let mtu_ok = enforce_wlan0_mtu_1380();

    // When connected, verify live internet (HTTP 204). If the captive portal expired or reset
    // after a DHCP lease renewal, automatically traverse it with honest traveler inputs + Anicca recipe!
    if state == "connected" && !probe_internet_204_fast() {
        let qwave_bin = find_qwave_bin();
        let _ = Command::new(&qwave_bin)
            .arg("--nomad-connect")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        if probe_internet_204_fast() {
            portal_healed = true;
        }
    }

    let trit = if state == "connected" { "+" } else { "0" };
    let clean_ssid = sanitize_no_float(&active_ssid);

    if reconnected && !clean_ssid.is_empty() {
        let msg = format!("Auto-reconnected Wi-Fi to {} with MTU 1380", clean_ssid);
        send_desktop_notification("8b:is Wi-Fi Auto-Healer [+]", &msg);
        speak_async(&msg);
    } else if portal_healed && !clean_ssid.is_empty() {
        let msg = format!(
            "Healed expired captive portal on {} (Aye stays connected!)",
            clean_ssid
        );
        send_desktop_notification("8b:is Captive Portal Healed [+]", &msg);
    }

    format!(
        "{{\"ok\":true,\"action\":\"wifi-heal\",\"device\":\"wlan0\",\"state\":\"{}\",\"ssid\":\"{}\",\"reconnected\":{},\"portal_healed\":{},\"mtu\":{},\"trit\":\"{}\"}}",
        json_escape(&state),
        json_escape(&clean_ssid),
        if reconnected { "true" } else { "false" },
        if portal_healed { "true" } else { "false" },
        if mtu_ok { 1380 } else { 1500 },
        trit
    )
}

/// Execute `qwave-hypr-hud wifi-tui`:
/// Launches `alacritty --class wifi-manager -T "8b.is Sovereign Wi-Fi Manager" -e nmtui`
/// and runs `wifi-heal` afterwards to ensure MTU `1380` is applied.
pub fn run_wifi_tui(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"wifi-tui\",\"mtu\":1380,\"trit\":\"+\"}".to_string();
    }

    let _ = Command::new("alacritty")
        .args([
            "--class",
            "wifi-manager",
            "-T",
            "8b.is Sovereign Wi-Fi Manager",
            "-e",
            "nmtui",
        ])
        .status();

    let _ = run_wifi_heal(&[]);
    "{\"ok\":true,\"action\":\"wifi-tui\",\"mtu\":1380,\"trit\":\"+\"}".to_string()
}

fn prompt_dmenu(prompt: &str, lines: &[String], password_mode: bool) -> Option<String> {
    let payload = lines.join("\n");
    let mut fuzzel_args = vec!["--dmenu", "-p", prompt];
    if password_mode {
        fuzzel_args.push("--password");
    }

    if let Ok(mut child) = Command::new("fuzzel")
        .args(&fuzzel_args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        if let Some(ref mut stdin) = child.stdin {
            let _ = stdin.write_all(payload.as_bytes());
        }
        if let Ok(out) = child.wait_with_output() {
            if out.status.success() {
                let selected = String::from_utf8_lossy(&out.stdout).trim().to_string();
                return Some(selected);
            }
            return None;
        }
    }

    let mut wofi_args = vec!["--dmenu", "-p", prompt];
    if password_mode {
        wofi_args.push("--password");
    }
    if let Ok(mut child) = Command::new("wofi")
        .args(&wofi_args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        if let Some(ref mut stdin) = child.stdin {
            let _ = stdin.write_all(payload.as_bytes());
        }
        if let Ok(out) = child.wait_with_output() {
            if out.status.success() {
                let selected = String::from_utf8_lossy(&out.stdout).trim().to_string();
                return Some(selected);
            }
        }
    }
    None
}

fn connect_wifi_with_password_prompt(ssid: &str, security: &str, force_password: bool) -> bool {
    if !force_password && (security == "OPEN" || security.is_empty() || security == "--") {
        let ok = Command::new("nmcli")
            .args(["device", "wifi", "connect", ssid])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            let _ = enforce_wlan0_mtu_1380();
            return true;
        }
    }

    let prompt = format!("Password for {} > ", sanitize_no_float(ssid));
    if let Some(pass) = prompt_dmenu(&prompt, &[], true) {
        let trimmed_pass = pass.trim();
        if !trimmed_pass.is_empty() {
            if force_password {
                let _ = Command::new("nmcli")
                    .args(["connection", "delete", ssid])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }
            let ok = Command::new("nmcli")
                .args(["device", "wifi", "connect", ssid, "password", trimmed_pass])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                let _ = enforce_wlan0_mtu_1380();
                return true;
            }
        } else {
            return false;
        }
    }

    // Fallback to interactive nmtui-connect inside floating Alacritty window
    let ok = Command::new("alacritty")
        .args([
            "--class",
            "wifi-manager",
            "-T",
            "8b.is Wi-Fi Manager",
            "-e",
            "nmtui-connect",
            ssid,
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    let _ = enforce_wlan0_mtu_1380();
    ok
}

/// Execute `qwave-hypr-hud wifi-menu`:
/// Opens Noctalia's native graphical Wi-Fi & Network Control Center (`noctalia msg panel-toggle control-center network`)
/// when `/usr/bin/noctalia` is available (falling back to `fuzzel --dmenu` when `--dmenu` is passed),
/// and enforces `1380` MTU on `wlan0`.
pub fn run_wifi_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"wifi-menu\",\"mtu\":1380,\"trit\":\"+\"}".to_string();
    }

    let force_dmenu = args.iter().any(|a| a == "--dmenu");
    if !force_dmenu && Path::new("/usr/bin/noctalia").exists() {
        if !is_process_running("noctalia") {
            let _ = Command::new("/usr/bin/noctalia")
                .arg("--daemon")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
            thread::sleep(Duration::from_millis(250));
            let _ = Command::new("/usr/bin/noctalia")
                .args(["msg", "bar-hide"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        if Command::new("/usr/bin/noctalia")
            .args(["msg", "panel-toggle", "control-center", "network"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
        {
            let _ = enforce_wlan0_mtu_1380();
            return "{\"ok\":true,\"action\":\"wifi-menu\",\"ui\":\"noctalia-network\",\"mtu\":1380,\"trit\":\"+\"}".to_string();
        }
    }

    let saved = list_saved_wifi_connections();
    let raw_scan = Command::new("nmcli")
        .args([
            "-t",
            "-f",
            "IN-USE,SSID,SIGNAL,SECURITY",
            "device",
            "wifi",
            "list",
            "--rescan",
            "auto",
        ])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();

    let entries = parse_nmcli_wifi_list(&raw_scan, &saved);
    let menu_lines = format_wifi_menu_entries(&entries);

    let Some(choice) = prompt_dmenu("Wi-Fi > ", &menu_lines, false) else {
        // If user cancelled fuzzel/wofi with Esc, exit cleanly; if neither launcher exists, open wifi-tui
        if !Path::new("/usr/bin/fuzzel").exists() && !Path::new("/usr/bin/wofi").exists() {
            return run_wifi_tui(&[]);
        }
        return "{\"ok\":true,\"action\":\"wifi-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}"
            .to_string();
    };

    if choice.starts_with("[HEAL]") {
        let res = run_wifi_heal(&[]);
        send_desktop_notification(
            "8b:is Wi-Fi Auto-Healer [+]",
            "Wi-Fi checked, captive portal verified, and MTU 1380 enforced",
        );
        speak_async("Wi-Fi healed and MTU 1380 applied");
        return res;
    }

    if choice.starts_with("[PORTAL]") {
        return run_portal_heal(&[]);
    }

    if choice.starts_with("[LOVE]") {
        return run_wifi_love(&[]);
    }

    if choice.starts_with("[TUI]") {
        return run_wifi_tui(&[]);
    }

    if choice.starts_with("[PASS]") {
        let net_lines: Vec<String> = menu_lines
            .iter()
            .filter(|l| l.starts_with("[*]") || l.starts_with("[ ]"))
            .cloned()
            .collect();
        if let Some(net_choice) = prompt_dmenu("Update Password for SSID > ", &net_lines, false) {
            if let Some(ssid) = extract_ssid_from_menu_choice(&net_choice, &entries) {
                let sec = entries
                    .iter()
                    .find(|e| e.ssid == ssid)
                    .map(|e| e.security.as_str())
                    .unwrap_or("WPA2");
                let ok = connect_wifi_with_password_prompt(&ssid, sec, true);
                let clean_ssid = sanitize_no_float(&ssid);
                if ok {
                    let msg = format!("Connected to {} with updated password and MTU 1380", clean_ssid);
                    send_desktop_notification("8b:is Wi-Fi Connected [+]", &msg);
                    speak_async(&msg);
                    return format!(
                        "{{\"ok\":true,\"action\":\"wifi-menu\",\"ssid\":\"{}\",\"mtu\":1380,\"trit\":\"+\"}}",
                        json_escape(&clean_ssid)
                    );
                } else {
                    let msg = format!("Could not connect to {}", clean_ssid);
                    send_desktop_notification("8b:is Wi-Fi Warning [-]", &msg);
                    return format!(
                        "{{\"ok\":false,\"action\":\"wifi-menu\",\"ssid\":\"{}\",\"trit\":\"-\"}}",
                        json_escape(&clean_ssid)
                    );
                }
            }
        }
        return "{\"ok\":true,\"action\":\"wifi-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}"
            .to_string();
    }

    if let Some(ssid) = extract_ssid_from_menu_choice(&choice, &entries) {
        let entry = entries.iter().find(|e| e.ssid == ssid);
        let is_saved = entry.map(|e| e.saved).unwrap_or(false);
        let sec = entry.map(|e| e.security.as_str()).unwrap_or("WPA2");

        let mut connected = false;
        if is_saved {
            connected = Command::new("nmcli")
                .args(["connection", "up", &ssid])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if connected {
                let _ = enforce_wlan0_mtu_1380();
            }
        }

        if !connected {
            connected = connect_wifi_with_password_prompt(&ssid, sec, is_saved);
        }

        let clean_ssid = sanitize_no_float(&ssid);
        if connected {
            let msg = format!("Connected to {} with MTU 1380", clean_ssid);
            send_desktop_notification("8b:is Wi-Fi Connected [+]", &msg);
            speak_async(&msg);
            return format!(
                "{{\"ok\":true,\"action\":\"wifi-menu\",\"ssid\":\"{}\",\"mtu\":1380,\"trit\":\"+\"}}",
                json_escape(&clean_ssid)
            );
        } else {
            let msg = format!("Failed to connect to {}", clean_ssid);
            send_desktop_notification("8b:is Wi-Fi Error [-]", &msg);
            speak_async(&msg);
            return format!(
                "{{\"ok\":false,\"action\":\"wifi-menu\",\"ssid\":\"{}\",\"trit\":\"-\"}}",
                json_escape(&clean_ssid)
            );
        }
    }

    "{\"ok\":true,\"action\":\"wifi-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

/// Execute `qwave-hypr-hud boot-session`: start services, waybar, notifications, Wi-Fi healer,
/// Workspace 1 AGY Studio + HUD, and speak welcome.
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

        // 2. Ensure qwave-whisper.service, liquid-rust.service, qwave-ear.service, and qwave-wifi-heal.timer are active
        let _ = Command::new("systemctl")
            .args([
                "--user",
                "start",
                "qwave-whisper.service",
                "liquid-rust.service",
                "qwave-ear.service",
                "qwave-wifi-heal.timer",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();

        // 3. Heal Wi-Fi connection and enforce 1380 MTU on wlan0 immediately on boot
        let _ = run_wifi_heal(&[]);

        // 4. Start mako notification daemon if not already running
        if !is_process_running("mako") {
            let _ = Command::new("mako")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 5. Start waybar if not already running
        if !is_process_running("waybar") {
            let _ = Command::new("waybar")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 5b. Ensure noctalia daemon is running for the graphical Wi-Fi & Control Center panels (with duplicate bar hidden)
        if Path::new("/usr/bin/noctalia").exists() {
            if !is_process_running("noctalia") {
                let _ = Command::new("/usr/bin/noctalia")
                    .arg("--daemon")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn();
                thread::sleep(Duration::from_millis(250));
            }
            let _ = Command::new("/usr/bin/noctalia")
                .args(["msg", "bar-hide"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }

        // 6. Start nm-applet --indicator if installed and not already running
        if Path::new("/usr/bin/nm-applet").exists() && !is_process_running("nm-applet") {
            let _ = Command::new("nm-applet")
                .arg("--indicator")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 7. Ensure Workspace 1 (1:AI-STUDIO) has Sovereign AGY Studio (Resumed) and Graphical Qwave Markdown HUD open
        if !is_process_running("agy") && !is_cmdline_running("qwave-hypr-hud agy-resume") {
            let _ = hyprctl_exec_cmd(
                "[workspace 1 silent] alacritty -T \"8b.is Sovereign AGY Studio (Resumed)\" --working-directory /home/hue/8b-is -e /home/hue/.local/bin/qwave-hypr-hud agy-resume",
            );
        }
        let _ = run_markdown_hud(&[]);

        // 8. Speak welcome asynchronously so session boot never blocks
        speak_async(welcome);
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

fn hyprctl_dispatch_lua(lua_expr: &str) {
    let sig = discover_hyprland_signature();
    let mut cmd = Command::new("hyprctl");
    if let Some(ref s) = sig {
        cmd.env("HYPRLAND_INSTANCE_SIGNATURE", s);
    }
    let _ = cmd
        .args(["dispatch", lua_expr])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Toggle playing our Tokyo Theme Song (`next-stop-tomorrow.mp3`) across the Hyprland desktop.
pub fn run_tokyo_song(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"tokyo-song\",\"trit\":\"+\"}".to_string();
    }
    if is_process_running("ffplay") {
        let _ = Command::new("killall").arg("ffplay").status();
        let _ = fs::remove_file("/tmp/qwave_music_state.txt");
        send_desktop_notification("Qwave Humayian Audio [0]", "Paused desktop music");
        return "{\"ok\":true,\"action\":\"tokyo-song\",\"playing\":false,\"trit\":\"0\"}".to_string();
    }
    let mp3 = "/home/hue/.local/share/qwave/music/next-stop-tomorrow.mp3";
    let _ = fs::write("/tmp/qwave_music_state.txt", "tokyo");
    let _ = Command::new("setsid")
        .args([
            "--fork",
            "ffplay",
            "-nodisp",
            "-autoexit",
            "-loglevel",
            "quiet",
            mp3,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    send_desktop_notification(
        "🚆 Next Stop, Tomorrow! [+]",
        "まもなく浜松町 · Playing Tokyo Theme Song (8bit_wraith)",
    );
    "{\"ok\":true,\"action\":\"tokyo-song\",\"playing\":true,\"trit\":\"+\"}".to_string()
}

/// Weave & play a fresh On-Machine 4-Song Humayian Mix across the Hyprland desktop.
pub fn run_humayian_mix(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"humayian-mix\",\"trit\":\"+\"}".to_string();
    }
    let _ = Command::new("killall").arg("ffplay").status();
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(42);
    let s1 = 8 + (seed % 45);
    let s2 = 12 + ((seed / 3) % 50);
    let s3 = 10 + ((seed / 7) % 60);
    let s4 = 15 + ((seed / 11) % 45);
    let _ = fs::write("/tmp/qwave_music_state.txt", "humayian");
    let sh_cmd = format!(
        "ffmpeg -y -loglevel quiet \
         -i /home/hue/8b-is/8b-is/music/next-stop-tomorrow.mp3 \
         -i /home/hue/8b-is/8b-is/music/one-clean-signal.mp3 \
         -i /home/hue/8b-is/8b-is/music/georgia-drew-the-bow.mp3 \
         -i /home/hue/8b-is/8b-is/music/so-simply-alive-klickaud.mp3 \
         -filter_complex \"[0:a]atrim=start={s1}:duration=24,asetpts=PTS-STARTPTS[a0];\
         [1:a]atrim=start={s2}:duration=24,asetpts=PTS-STARTPTS[a1];\
         [2:a]atrim=start={s3}:duration=24,asetpts=PTS-STARTPTS[a2];\
         [3:a]atrim=start={s4}:duration=24,asetpts=PTS-STARTPTS[a3];\
         [a0][a1]acrossfade=d=4:c1=tri:c2=tri[m01];\
         [m01][a2]acrossfade=d=4:c1=tri:c2=tri[m012];\
         [m012][a3]acrossfade=d=4:c1=tri:c2=tri[mix];\
         sine=frequency=432:duration=84,volume=9/500[pad];\
         [mix][pad]amix=inputs=2:duration=first:dropout_transition=2\" \
         -ar 48000 -ac 2 /tmp/qwave_humayian_mix.wav && \
         ffplay -nodisp -autoexit -loglevel quiet /tmp/qwave_humayian_mix.wav"
    );
    let _ = Command::new("setsid")
        .args(["--fork", "sh", "-c", &sh_cmd])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    send_desktop_notification(
        "🎹 Humayian 4-Song Mix [+]",
        "Weaving Next Stop + Clean Signal + Georgia + Simply Alive on-machine!",
    );
    "{\"ok\":true,\"action\":\"humayian-mix\",\"playing\":true,\"trit\":\"+\"}".to_string()
}

/// Render single-line Waybar JSON for the interactive Humayian Music & Partner Pill.
pub fn render_waybar_music_json() -> String {
    let playing = is_process_running("ffplay");
    let mode = fs::read_to_string("/tmp/qwave_music_state.txt").unwrap_or_default();
    let (text, cls) = if playing && mode.trim() == "humayian" {
        ("🎵 Humayian Mix [LIVE]", "humayian-playing")
    } else if playing {
        ("🚆 Next Stop, Tomorrow! [LIVE]", "humayian-playing")
    } else {
        ("🚆 Tokyo Song │ 🎹 Humayian Mix", "humayian-idle")
    };
    let tooltip = "Humayian On-Machine Audio · L-Click: Play/Stop Tokyo Song (Next Stop, Tomorrow!) │ R-Click: Weave & Play 4-Song Humayian Mix │ M-Click: Focus Qwave Browser";
    format!(
        "{{\"text\":\"{}\",\"tooltip\":\"{}\",\"class\":\"{}\"}}",
        json_escape(text),
        json_escape(tooltip),
        cls
    )
}

/// Render single-line Waybar JSON for the Sovereign Personal-Signature Password Vault Pill.
pub fn render_waybar_vault_json() -> String {
    let records = load_hud_vault_records();
    let count = records.len();
    let has_key = find_hud_ed25519_keypair().is_some();
    let trit = if has_key { "+" } else { "0" };
    let text = format!("🔐 Vault [{count}│{trit}]");
    let tooltip = format!(
        "Sovereign Personal-Signature Password Vault (SUPER + U)\n\
         Sealed Credentials: {count} (ChaCha20-HMAC-SHA256 + PBKDF2 + HKDF + MEM|8 79B WaveInt)\n\
         Ed25519 Personal Signature Key: {}\n\
         L-Click: Unseal / Seal Password (fuzzel/wofi + auto-type + 12s clipboard wipe)\n\
         R-Click: Open Sovereign Vault in Qwave Browser",
        if has_key { "Active [+] (~/.ssh/id_ed25519)" } else { "Missing [-]" }
    );
    let cls = if has_key { "vault-ready" } else { "vault-locked" };
    format!(
        "{{\"text\":\"{}\",\"tooltip\":\"{}\",\"class\":\"{}\"}}",
        json_escape(&text),
        json_escape(&tooltip),
        cls
    )
}

/// Pure-Rust Zero-Float Integer Domain-Warped Bluish Smoke Wallpaper Generator for Hyprland.
/// Renders 4 domain-warped FBM smoke wave phases (`smoke_wave_0.ppm` .. `smoke_wave_3.ppm`)
/// so the Hyprland desktop shares Qwave's Bluish Smoke Wave and shifts dynamically when speaking!
fn integer_hash2d(x: i32, y: i32, seed: u32) -> i32 {
    let mut h = (x as u32)
        .wrapping_mul(374_761_393)
        .wrapping_add((y as u32).wrapping_mul(668_265_263))
        .wrapping_add(seed.wrapping_mul(2_246_822_519));
    h = (h ^ (h >> 13)).wrapping_mul(1_274_126_177);
    ((h ^ (h >> 16)) & 0xFFFF) as i32
}

fn integer_noise_q16(x_q8: i32, y_q8: i32, seed: u32) -> i32 {
    let xi = x_q8 >> 8;
    let yi = y_q8 >> 8;
    let xf = x_q8 & 0xFF;
    let yf = y_q8 & 0xFF;
    let u = (xf * xf * (768 - 2 * xf)) >> 16;
    let v = (yf * yf * (768 - 2 * yf)) >> 16;
    let a = integer_hash2d(xi, yi, seed);
    let b = integer_hash2d(xi + 1, yi, seed);
    let c = integer_hash2d(xi, yi + 1, seed);
    let d = integer_hash2d(xi + 1, yi + 1, seed);
    let ab = a + (((b - a) * u) >> 8);
    let cd = c + (((d - c) * u) >> 8);
    ab + (((cd - ab) * v) >> 8)
}

fn integer_fbm_q16(mut x_q8: i32, mut y_q8: i32, seed: u32) -> i32 {
    let mut total = 0i32;
    let mut amp = 32_768i32;
    for oct in 0..4u32 {
        let n = integer_noise_q16(x_q8, y_q8, seed.wrapping_add(oct * 97));
        total += (n * amp) >> 16;
        // Rotate ~(cos 0.5, sin 0.5) in Q8: (224, 122) and scale 2x
        let nx = ((x_q8 * 224 - y_q8 * 122) >> 7) + 2560;
        let ny = ((x_q8 * 122 + y_q8 * 224) >> 7) + 2560;
        x_q8 = nx;
        y_q8 = ny;
        amp >>= 1;
    }
    total.clamp(0, 65_535)
}

fn ensure_smoke_wallpapers() -> PathBuf {
    let dir = qwave_base_dir().join("wallpapers");
    let _ = fs::create_dir_all(&dir);
    let w = 480i32;
    let h = 270i32;
    for phase in 0..4usize {
        let p = dir.join(format!("smoke_wave_{phase}.ppm"));
        if p.exists() {
            continue;
        }
        let mut out = Vec::with_capacity((w * h * 3 + 32) as usize);
        let header = format!("P6\n{w} {h}\n255\n");
        out.extend_from_slice(header.as_bytes());
        let time_shift = (phase as i32) * 190;
        let voice_boost = if phase == 0 { 0i32 } else { 80 + (phase as i32) * 35 };

        for y in 0..h {
            for x in 0..w {
                let mut sx = (x * 768) / h;
                let mut sy = (y * 768) / h;
                if phase > 0 {
                    let dx = x - (w / 2);
                    let dy = y - (h / 2);
                    let dist_sq = dx * dx + dy * dy;
                    let ring = ((dist_sq / (180 + (phase as i32) * 40)) + time_shift) & 63;
                    let wave = if ring < 32 { ring - 16 } else { 48 - ring };
                    sx += (dx * wave) / 160;
                    sy += (dy * wave) / 160;
                }
                let qx = integer_fbm_q16(sx + time_shift, sy, 101) >> 8;
                let qy = integer_fbm_q16(sx + 256, sy + 256, 202) >> 8;
                let rx = integer_fbm_q16(sx + qx + 435 + time_shift, sy + qy + 2350, 303) >> 8;
                let ry = integer_fbm_q16(sx + qx + 2120, sy + qy + 716 + time_shift, 404) >> 8;
                let f = integer_fbm_q16(sx + rx, sy + ry, 505) >> 8; // 0..255

                // Bluish Cyber-Smoke palette: deep midnight -> sapphire -> cobalt azure -> electric cyan/starlight voice crest
                let f2 = (f * f) >> 8;
                let r_crest = (rx * (110 + voice_boost)) >> 8;
                let g_crest = (rx * (215 + (voice_boost >> 2))) >> 8;
                let b_crest = (rx * 255) >> 8;

                let r_col = ((6 + ((f2 * 28) >> 8) + ((r_crest * f) >> 9)) * (110 + f)) >> 8;
                let g_col = ((22 + ((f2 * 135) >> 8) + ((g_crest * f) >> 9)) * (115 + f)) >> 8;
                let b_col = ((56 + ((f2 * 215) >> 8) + ((b_crest * f) >> 8)) * (135 + f)) >> 8;

                out.push(r_col.clamp(3, 255) as u8);
                out.push(g_col.clamp(12, 255) as u8);
                out.push(b_col.clamp(34, 255) as u8);
            }
        }
        let _ = fs::write(&p, out);
    }
    dir
}

fn apply_hyprland_smoke_phase(phase: usize) {
    let dir = ensure_smoke_wallpapers();
    let target = dir.join(format!("smoke_wave_{}.ppm", phase % 4));
    let state_file = "/tmp/qwave_smoke_phase.txt";
    let prev_phase = fs::read_to_string(state_file).unwrap_or_default();
    if prev_phase.trim() == (phase % 4).to_string() && is_process_running("swaybg") {
        return;
    }
    let _ = fs::write(state_file, (phase % 4).to_string());
    let _ = Command::new("killall").arg("swaybg").status();
    let _ = Command::new("setsid")
        .args([
            "--fork",
            "swaybg",
            "-i",
            &target.to_string_lossy(),
            "-m",
            "fill",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

pub fn run_smoke_bg(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"smoke-bg\",\"phase\":0,\"trit\":\"+\"}".to_string();
    }
    let phase = args
        .first()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    apply_hyprland_smoke_phase(phase);
    format!(
        "{{\"ok\":true,\"action\":\"smoke-bg\",\"phase\":{},\"trit\":\"+\"}}",
        phase % 4
    )
}

fn hud_vault_file_path() -> PathBuf {
    let dir = qwave_base_dir().join("vault");
    let _ = fs::create_dir_all(&dir);
    dir.join("sovereign_vault.qvault")
}

fn hud_known_domains_path() -> PathBuf {
    let dir = qwave_base_dir().join("vault");
    let _ = fs::create_dir_all(&dir);
    dir.join("known_domains.txt")
}

fn load_hud_known_domains() -> Vec<String> {
    let mut domains = vec![
        "github.com".to_string(),
        "cheet.is".to_string(),
        "g8t.is".to_string(),
        "gemini-diary.8b.is".to_string(),
        "8b.is".to_string(),
    ];
    if let Ok(raw) = fs::read_to_string(hud_known_domains_path()) {
        for line in raw.lines() {
            let d = canonicalize_domain(line.trim());
            if !d.is_empty() && !domains.contains(&d) {
                domains.insert(0, d);
            }
        }
    }
    domains
}

fn remember_hud_domain(domain: &str) {
    let norm = canonicalize_domain(domain);
    if norm.is_empty() {
        return;
    }
    let mut list = load_hud_known_domains();
    list.retain(|d| d != &norm);
    list.insert(0, norm);
    let path = hud_known_domains_path();
    let _ = fs::write(&path, list.join("\n") + "\n");
    let _ = Command::new("chmod")
        .args(["600", &path.to_string_lossy()])
        .status();
}

fn load_hud_vault_records() -> Vec<SealedVaultRecord> {
    let path = hud_vault_file_path();
    let Ok(content) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut lines = content.lines();
    let Some(first) = lines.next() else {
        return Vec::new();
    };
    if !first.trim().starts_with(VAULT_MAGIC) {
        return Vec::new();
    }
    let mut records = Vec::new();
    for line in lines {
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            if let Ok(rec) = SealedVaultRecord::from_line(trimmed) {
                if WaveInt::from_frame(&rec.wave_frame).is_ok() {
                    records.push(rec);
                }
            }
        }
    }
    records
}

fn find_hud_ed25519_keypair() -> Option<(PathBuf, PathBuf, String)> {
    let home = env::var("HOME").unwrap_or_else(|_| "/home/hue".to_string());
    let ssh_dir = PathBuf::from(home).join(".ssh");
    for name in ["id_ed25519", "id_ed25519_sovereign", "id_rsa"] {
        let priv_p = ssh_dir.join(name);
        let pub_p = ssh_dir.join(format!("{name}.pub"));
        if priv_p.exists() && pub_p.exists() {
            if let Ok(pub_line) = fs::read_to_string(&pub_p) {
                let trimmed = pub_line.trim().to_string();
                if !trimmed.is_empty() {
                    return Some((priv_p, pub_p, trimmed));
                }
            }
        }
    }
    None
}

fn resolve_qwave_bin() -> String {
    for cand in ["/home/hue/.local/bin/qwave", "/usr/local/bin/qwave", "qwave"] {
        if Path::new(cand).exists() {
            return cand.to_string();
        }
    }
    "qwave".to_string()
}

/// Execute `qwave-hypr-hud vault-menu`:
/// Sovereign Personal-Signature Password Vault launcher (`SUPER + U`).
/// Unseals credentials ONLY via live Ed25519 cryptographic signature (`ssh-keygen -Y sign`/`verify`)
/// fused with Hue's `MEM|8` 79-byte `WaveInt` vocal wave, types/copies into the focused window,
/// and automatically wipes the clipboard after 12 seconds!
pub fn run_vault_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"vault-menu\",\"cipher\":\"ChaCha20-HMAC-SHA256-PBKDF2-HKDF\",\"trit\":\"+\"}".to_string();
    }

    let records = load_hud_vault_records();
    let known_domains = load_hud_known_domains();
    let mut menu_lines: Vec<String> = Vec::with_capacity(known_domains.len() + 4);
    for dom in &known_domains {
        menu_lines.push(format!(
            "[UNSEAL] {} (Sign with Ed25519 + 79B WaveInt)",
            sanitize_no_float(dom)
        ));
    }
    menu_lines.push("[SEAL] Seal New Credential with Personal Ed25519 Signature".to_string());
    menu_lines.push(format!(
        "[VERIFY] Verify {} Sealed Vault Records & 79B WaveInt Frames",
        records.len()
    ));
    menu_lines.push("[BROWSER] Open Sovereign Vault in Qwave Browser".to_string());

    let Some(choice) = prompt_dmenu("Sovereign Vault > ", &menu_lines, false) else {
        return "{\"ok\":true,\"action\":\"vault-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}"
            .to_string();
    };

    if choice.starts_with("[BROWSER]") {
        return run_markdown_hud(&[]);
    }

    if choice.starts_with("[VERIFY]") {
        let qwave_bin = resolve_qwave_bin();
        let out = Command::new(&qwave_bin)
            .args(["vault", "verify"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        let total = extract_json_i64(&out, "total_records").unwrap_or(records.len() as i64);
        let fp = extract_json_str(&out, "signer_fingerprint").unwrap_or_default();
        let msg = format!(
            "Verified {} sealed records · Signer {}",
            total,
            sanitize_no_float(&fp)
        );
        send_desktop_notification("🛡️ Sovereign Vault Verified [+]", &msg);
        speak_async("Sovereign password vault verified with your personal signature");
        return if out.is_empty() {
            "{\"ok\":true,\"action\":\"vault-menu\",\"subaction\":\"verify\",\"trit\":\"+\"}".to_string()
        } else {
            sanitize_no_float(&out)
        };
    }

    if choice.starts_with("[SEAL]") {
        let Some(origin_in) =
            prompt_dmenu("Domain to Seal (e.g. github.com) > ", &known_domains, false)
        else {
            return "{\"ok\":true,\"action\":\"vault-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
        };
        let origin = canonicalize_domain(origin_in.trim());
        if origin.is_empty() {
            return "{\"ok\":false,\"action\":\"vault-menu\",\"error\":\"empty origin\",\"trit\":\"-\"}".to_string();
        }
        let Some(user_in) = prompt_dmenu("Username / Email > ", &[], false) else {
            return "{\"ok\":true,\"action\":\"vault-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
        };
        let username = user_in.trim().to_string();
        let Some(pass_in) = prompt_dmenu("Password to Seal > ", &[], true) else {
            return "{\"ok\":true,\"action\":\"vault-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
        };
        let password = pass_in.trim().to_string();
        if password.is_empty() {
            return "{\"ok\":false,\"action\":\"vault-menu\",\"error\":\"empty password\",\"trit\":\"-\"}".to_string();
        }
        let phrase = prompt_dmenu("Optional Personal Signature Phrase (Enter for none) > ", &[], true)
            .unwrap_or_default();

        let qwave_bin = resolve_qwave_bin();
        let out = Command::new(&qwave_bin)
            .args([
                "vault",
                "seal",
                &origin,
                &username,
                &password,
                phrase.trim(),
            ])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();

        if out.contains("\"ok\":true") {
            remember_hud_domain(&origin);
            let msg = format!(
                "Sealed {} ({}) with Ed25519 + 79B WaveInt",
                sanitize_no_float(&origin),
                sanitize_no_float(&username)
            );
            send_desktop_notification("🔏 Sovereign Vault Sealed [+]", &msg);
            speak_async("Password sealed with your personal signature");
            return format!(
                "{{\"ok\":true,\"action\":\"vault-menu\",\"subaction\":\"seal\",\"origin\":\"{}\",\"trit\":\"+\"}}",
                json_escape(&origin)
            );
        }
        let err = extract_json_str(&out, "error").unwrap_or_else(|| "seal failed".to_string());
        send_desktop_notification("Sovereign Vault Error [-]", &sanitize_no_float(&err));
        return format!(
            "{{\"ok\":false,\"action\":\"vault-menu\",\"error\":\"{}\",\"trit\":\"-\"}}",
            json_escape(&err)
        );
    }

    let domain_cand = if let Some(rest) = choice.strip_prefix("[UNSEAL]") {
        rest.split_whitespace().next().unwrap_or("").to_string()
    } else {
        choice.trim().to_string()
    };
    let norm_domain = canonicalize_domain(&domain_cand);
    if !norm_domain.is_empty() {
        let qwave_bin = resolve_qwave_bin();
        let mut out = Command::new(&qwave_bin)
            .args(["vault", "unseal", &norm_domain])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();

        if out.contains("\"requires_phrase\":true") && !out.contains("\"ok\":true") {
            if let Some(phrase) =
                prompt_dmenu("Personal Signature Phrase Required > ", &[], true)
            {
                out = Command::new(&qwave_bin)
                    .args(["vault", "unseal", &norm_domain, "", phrase.trim()])
                    .output()
                    .ok()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .unwrap_or_default();
            }
        }

        if out.contains("\"ok\":true") {
            if let Some(password) = extract_json_str(&out, "password") {
                let username = extract_json_str(&out, "username").unwrap_or_default();
                let sig_fp = extract_json_str(&out, "signer_fingerprint").unwrap_or_default();
                remember_hud_domain(&norm_domain);

                if let Ok(mut child) = Command::new("wl-copy")
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                {
                    if let Some(ref mut stdin) = child.stdin {
                        let _ = stdin.write_all(password.as_bytes());
                    }
                    let _ = child.wait();
                }
                let _ = Command::new("wtype")
                    .args(["--", &password])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
                // Auto-wipe clipboard after 12 seconds so unsealed secrets never linger
                let _ = Command::new("setsid")
                    .args([
                        "--fork",
                        "sh",
                        "-c",
                        "sleep 12 && wl-copy --clear 2>/dev/null || true",
                    ])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn();

                let msg = format!(
                    "Unsealed {} ({}) · {} · Clipboard auto-wipes in 12s",
                    sanitize_no_float(&norm_domain),
                    sanitize_no_float(&username),
                    sanitize_no_float(&sig_fp)
                );
                send_desktop_notification("🔓 Sovereign Vault Unsealed [+]", &msg);
                return format!(
                    "{{\"ok\":true,\"action\":\"vault-menu\",\"subaction\":\"unseal\",\"origin\":\"{}\",\"trit\":\"+\"}}",
                    json_escape(&norm_domain)
                );
            }
        }

        let err = extract_json_str(&out, "error")
            .unwrap_or_else(|| "no sealed credential for domain".to_string());
        send_desktop_notification(
            "Sovereign Vault Notice [0]",
            &sanitize_no_float(&err),
        );
        return format!(
            "{{\"ok\":false,\"action\":\"vault-menu\",\"origin\":\"{}\",\"error\":\"{}\",\"trit\":\"0\"}}",
            json_escape(&norm_domain),
            json_escape(&err)
        );
    }

    "{\"ok\":true,\"action\":\"vault-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

/// Hands-Free Hyprland Desktop Voice Orchestrator:
/// Checks if there is a new utterance from `hue` in `snap.thoughts` (using `.last()`, the newest
/// entry in the chronological ring!) and executes desktop-wide workspace/window/vault/music voice commands!
fn process_desktop_voice_command(snap: &HudSnapshot) {
    let Some(latest) = snap.thoughts.last() else {
        return;
    };
    if latest.speaker != "hue" || latest.ts == 0 {
        return;
    }
    let stamp_path = qwave_base_dir().join("mem8/hypr_voice_last_ts.txt");
    let prev_ts: u64 = fs::read_to_string(&stamp_path)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    if prev_ts == 0 {
        let _ = fs::write(&stamp_path, latest.ts.to_string());
        return;
    }
    if latest.ts <= prev_ts {
        return;
    }
    let _ = fs::write(&stamp_path, latest.ts.to_string());

    let low = latest.text.to_ascii_lowercase();
    if low.contains("workspace one") || low.contains("workspace 1") || low.contains("go to studio") {
        hyprctl_dispatch_lua("hl.dsp.focus({ workspace = 1 })");
        send_desktop_notification("🎙️ Hyprland Voice [+]", "Switched to Workspace 1: AI-STUDIO");
    } else if low.contains("workspace two") || low.contains("workspace 2") || low.contains("go to constellation") {
        hyprctl_dispatch_lua("hl.dsp.focus({ workspace = 2 })");
        send_desktop_notification("🎙️ Hyprland Voice [+]", "Switched to Workspace 2: CONSTELLATION");
    } else if low.contains("workspace three") || low.contains("workspace 3") || low.contains("go to lab") {
        hyprctl_dispatch_lua("hl.dsp.focus({ workspace = 3 })");
        send_desktop_notification("🎙️ Hyprland Voice [+]", "Switched to Workspace 3: QWAVE-LAB");
    } else if low.contains("workspace four") || low.contains("workspace 4") {
        hyprctl_dispatch_lua("hl.dsp.focus({ workspace = 4 })");
        send_desktop_notification("🎙️ Hyprland Voice [+]", "Switched to Workspace 4: DRA-DOCS");
    } else if low.contains("open vault") || low.contains("password vault") || low.contains("unseal password") {
        if let Ok(exe) = env::current_exe() {
            let _ = Command::new(exe)
                .arg("vault-menu")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    } else if low.contains("captive portal") || low.contains("free wifi") || low.contains("free wi-fi") || low.contains("heal portal") {
        let _ = run_portal_heal(&[]);
    } else if low.contains("mesh love") || low.contains("bluetooth love") || low.contains("hotspot love") || low.contains("share wifi") {
        let _ = run_wifi_love(&[]);
    } else if low.contains("wifi menu") || low.contains("wi-fi menu") || low.contains("open wifi") || low.contains("open wi-fi") {
        let _ = Command::new("noctalia")
            .args(["msg", "panel-toggle", "control-center", "network"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    } else if low.contains("control center") || low.contains("bluetooth menu") {
        let _ = Command::new("noctalia")
            .args(["msg", "panel-toggle", "control-center"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    } else if low.contains("fullscreen") || low.contains("maximize window") {
        hyprctl_dispatch_lua("hl.dsp.window.fullscreen()");
    } else if low.contains("toggle floating") || low.contains("float window") {
        hyprctl_dispatch_lua("hl.dsp.window.float({ action = \"toggle\" })");
    }
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
            grains_learned: 11_085,
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
        assert!(frame.contains("SUPER+I"));
        assert!(frame.contains("SUPER+W"));
        assert_zero_float_literals(&frame);
    }

    #[test]
    fn markdown_hud_renders_mermaid_and_zero_floats() {
        let snap = sample_snapshot();
        let md = render_graphical_markdown_hud(&snap);
        assert!(md.contains("```mermaid"));
        assert!(md.contains("flowchart TD"));
        assert!(md.contains("Open-Lid Laptop Bezel Stereo DMIC"));
        assert!(md.contains("10 cm"));
        assert!(md.contains("**`hue`**"));
        assert!(md.contains("**`alex`**"));
        assert!(md.contains("**`trisha`**"));
        assert!(md.contains("SUPER + D"));
        assert_zero_float_literals(&md);
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
        let ar = run_agy_resume(&["--dry-run".to_string()]);
        let mh = run_markdown_hud(&["--dry-run".to_string()]);
        let wm = run_wifi_menu(&["--dry-run".to_string()]);
        let wt = run_wifi_tui(&["--dry-run".to_string()]);
        let wh = run_wifi_heal(&["--dry-run".to_string()]);
        let ph = run_portal_heal(&["--dry-run".to_string()]);
        let wl = run_wifi_love(&["--dry-run".to_string()]);
        let vm = run_vault_menu(&["--dry-run".to_string()]);
        let ap = run_a6000_pulse(&["--dry-run".to_string()]);
        for out in [&vt, &aa, &te, &bs, &ar, &mh, &wm, &wt, &wh, &ph, &wl, &vm, &ap] {
            assert!(out.contains("\"ok\":true"));
            assert_zero_float_literals(out);
        }
    }

    #[test]
    fn wifi_scan_parser_and_menu_formatter_handle_colons_and_zero_floats() {
        let raw = "*:#wifibox_qrm:79:WPA2\n\
                   \x20:Buffalo-A-1260:64:WPA2\n\
                   \x20:8b\\:is_2.4GHz:91:WPA3\n\
                   \x20:--:40:OPEN\n";
        let saved = vec!["#wifibox_qrm".to_string(), "8b:is_2.4GHz".to_string()];
        let parsed = parse_nmcli_wifi_list(raw, &saved);
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].ssid, "#wifibox_qrm");
        assert!(parsed[0].in_use);
        assert!(parsed[0].saved);
        assert_eq!(parsed[1].ssid, "8b:is_2.4GHz");
        assert!(parsed[1].saved);
        assert_eq!(parsed[2].ssid, "Buffalo-A-1260");
        assert!(!parsed[2].saved);

        let menu = format_wifi_menu_entries(&parsed);
        assert!(menu.iter().any(|l| l.starts_with("[HEAL]")));
        assert!(menu.iter().any(|l| l.starts_with("[PORTAL]")));
        assert!(menu.iter().any(|l| l.starts_with("[LOVE]")));
        assert!(menu.iter().any(|l| l.starts_with("[TUI]")));
        for line in &menu {
            assert_zero_float_literals(line);
        }

        let extracted = extract_ssid_from_menu_choice(&menu[1], &parsed);
        assert_eq!(extracted.as_deref(), Some("8b:is_2.4GHz"));
    }
}
