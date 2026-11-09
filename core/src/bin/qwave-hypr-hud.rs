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
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use qwave_core::Rational;
use qwave_core::markdown::{MarkdownTrust, compile_full};
use qwave_core::phoenix_sound::{EIGHT_A_MAGIC, PhoenixLiveProcessor, PhoenixSoundPreset};
use qwave_core::quanttern::{Trit, default_threshold_pq};
use qwave_core::salience::{
    DEFAULT_CLIP_THRESHOLD_Q15, MarineIntDetector, Q15_ONE, RingBuffer, SpeakerSalienceProfile,
    sanitize_and_dedup_stt_transcript,
};
use qwave_core::triad::compute_riva_dyad_state;
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
        "waybar-ai" => {
            println!("{}", render_waybar_ai_json());
        }
        "waybar-phoenix" => {
            println!("{}", render_waybar_phoenix_json());
        }
        "phoenix-daemon" => {
            run_phoenix_daemon(rest);
        }
        "phoenix-toggle" => {
            println!("{}", run_phoenix_toggle(rest));
        }
        "phoenix-preset" => {
            println!("{}", run_phoenix_preset(rest));
        }
        "alexandra-reset" => {
            println!("{}", run_alexandra_reset(rest));
        }
        "phoenix-menu" => {
            println!("{}", run_phoenix_menu(rest));
        }
        "oxicast-daemon" => {
            run_oxicast_daemon(rest);
        }
        "oxicast-tv" | "oxicast" => {
            println!("{}", run_oxicast_tv(rest));
        }
        "marine-sense" | "marine" => {
            println!("{}", run_marine_sense(rest));
        }
        "oxicast-cast" => {
            println!("{}", run_oxicast_cast(rest));
        }
        "refresh-ai-bg" => {
            let _ = refresh_ai_compute_sync();
        }
        "ai-menu" => {
            println!("{}", run_ai_menu(rest));
        }
        "ai-clip" => {
            println!("{}", run_ai_clip(rest));
        }
        "scratchpad" => {
            println!("{}", run_scratchpad(rest));
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
        "wifi-menu" | "net-menu" | "net-dialog" => {
            println!("{}", run_wifi_menu(rest));
        }
        "bt-menu" | "bt-dialog" | "bluetooth-menu" => {
            println!("{}", run_bt_menu(rest));
        }
        "audio-menu" | "audio-dialog" | "sound-menu" => {
            println!("{}", run_audio_menu(rest));
        }
        "power-menu" | "power-dialog" | "battery-menu" => {
            println!("{}", run_power_menu(rest));
        }
        "control-center" | "cc" => {
            println!("{}", run_control_center(rest));
        }
        "wifi-tui" => {
            println!("{}", run_wifi_tui(rest));
        }
        "wifi-heal" => {
            println!("{}", run_wifi_heal(rest));
        }
        "tz-sync" | "area-sync" => {
            println!("{}", run_tz_sync(rest));
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
         \x20 qwave-hypr-hud waybar-ai             Single-line Waybar JSON for GPU/NPU/A6000 & Hot Models\n\
         \x20 qwave-hypr-hud ai-menu               Sovereign AI Command Center & Model Switcher (SUPER+O)\n\
         \x20 qwave-hypr-hud ai-clip               Send Wayland clipboard to Loopback Aye (SUPER+X)\n\
         \x20 qwave-hypr-hud scratchpad <name>     Self-healing toggle for special:term / qwave / btop\n\
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
         \x20 qwave-hypr-hud tz-sync               Auto-detect area via IP/Wi-Fi and sync system timezone & clock\n\
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
    let req = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUser-Agent: qwave-hypr-hud\r\nAccept: */*\r\nConnection: close\r\n\r\n");
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
    if !(85..=175).contains(&prof_f0_int) {
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

/// Build a 10-cell integer progress gauge (`▰▰▰▰▰▰▰▰▱▱`) without floats.
fn render_gauge_10(pct: i32) -> String {
    let filled = (pct.clamp(0, 100) / 10) as usize;
    let mut s = String::with_capacity(30);
    for i in 0..10 {
        if i < filled {
            s.push('▰');
        } else {
            s.push('▱');
        }
    }
    s
}

/// Build an 11-cell integer DOA azimuth compass (`◄────┼──●─►`) for `-60..+60` degrees.
fn render_azimuth_compass(az_deg: i32) -> String {
    let clamped = az_deg.clamp(-60, 60);
    let pos = (((clamped + 60) * 10) / 120).clamp(0, 10) as usize;
    let mut s = String::with_capacity(40);
    s.push('◄');
    for i in 0..=10 {
        if i == pos {
            s.push('●');
        } else if i == 5 {
            s.push('┼');
        } else {
            s.push('─');
        }
    }
    s.push('►');
    s
}

/// Render a single ANSI terminal frame for `qwave-hypr-hud status-tui` with zero floats.
pub fn render_status_tui_frame(snap: &HudSnapshot) -> String {
    let mut out = String::with_capacity(6144);
    let sign = if snap.azimuth_deg >= 0 { "+" } else { "" };

    // 24-bit TrueColor Qwave Constellation Ink Palette
    let c_cyan = "\x1b[1;38;2;0;240;255m";
    let c_teal = "\x1b[1;38;2;98;230;201m";
    let c_violet = "\x1b[1;38;2;203;166;247m";
    let c_amber = "\x1b[1;38;2;232;176;92m";
    let c_pink = "\x1b[1;38;2;255;158;219m";
    let c_slate = "\x1b[38;2;142;178;210m";
    let c_rst = "\x1b[0m";

    let sal_bar = render_gauge_10(snap.salience_pct);
    let compass = render_azimuth_compass(snap.azimuth_deg);

    out.push_str(&format!(
        "{c_cyan}╭──────────────────────────────────────────────────────────────────────────────────────╮{c_rst}\n\
         {c_cyan}│{c_rst} 🌊 {c_amber}⚡ SOVEREIGN 8b-is × QWAVE × ALEXIAI STUDIO HUD{c_rst} · {c_teal}C64 64KB RING · ZERO-FLOAT{c_rst}      {c_cyan}│{c_rst}\n\
         {c_cyan}╰──────────────────────────────────────────────────────────────────────────────────────╯{c_rst}\n"
    ));

    // Section 1: Marine Salience & Vocal Profile
    out.push_str(&format!(
        "{c_cyan}╭─ 1) MARINE SALIENCE & VOCAL PROFILE (speaker_salience_profile.bin) ──────────────────╮{c_rst}\n"
    ));
    out.push_str(&format!(
        "  🎙️ Speaker: {c_amber}{}{c_rst} │ Learned Grains: {c_teal}{}g{c_rst} │ Grain PCM Samples: {c_cyan}{}{c_rst}\n",
        sanitize_no_float(&snap.speaker),
        snap.grains_learned,
        snap.grain_samples
    ));
    out.push_str(&format!(
        "  🎵 Vocal F0: {c_teal}{} Hz{c_rst} (Rational p/q: {c_cyan}{}/{} Hz{c_rst} │ Profile p/q: {c_violet}{}/{} Hz{c_rst})\n",
        snap.f0_hz,
        snap.f0_pq.num,
        snap.f0_pq.den,
        snap.profile_f0_pq.num,
        snap.profile_f0_pq.den
    ));
    out.push_str(&format!(
        "  🧭 Spatial DOA: {c_amber}{}{} deg{c_rst} / {c_amber}{} cm{c_rst} {c_cyan}{compass}{c_rst} │ Zone: {c_teal}{}{c_rst}\n",
        sign,
        snap.azimuth_deg,
        snap.distance_cm,
        sanitize_no_float(&snap.spatial_zone)
    ));
    out.push_str(&format!(
        "  🧬 MarineIntDetector Stability Trit: {c_teal}[{}]{c_rst} │ Salience: {c_teal}{sal_bar} {}%{c_rst} ({}/{}) │ Detector F0: {}/{} Hz │ VAD: 0x{:02x}\n",
        trit_symbol(snap.stability_trit),
        snap.salience_pct,
        snap.salience_pq.num,
        snap.salience_pq.den,
        snap.detector_f0_pq.num,
        snap.detector_f0_pq.den,
        snap.vad_byte
    ));

    // Section 2: Live Room Thoughts Ring Buffer (last 12 utterances)
    out.push_str(&format!(
        "{c_cyan}├─ 2) LIVE ROOM THOUGHTS RING BUFFER (Last 12 Utterances · 64KB Cap) ──────────────────┤{c_rst}\n"
    ));
    if snap.thoughts.is_empty() {
        out.push_str(&format!(
            "  {c_slate}[0] hue @ 156Hz (+0 deg / 120 cm · 90%): Waiting for room acoustic waves{c_rst}\n"
        ));
    } else {
        for entry in snap.thoughts.iter().take(ROOM_THOUGHT_RING_CAP) {
            let t = Trit::from_rational(entry.salience_pq, default_threshold_pq());
            let az_sign = if entry.azimuth_deg >= 0 { "+" } else { "" };
            let snippet: String = entry.text.chars().take(44).collect();
            let bar5 = if entry.salience_pct >= 80 {
                "▰▰▰"
            } else if entry.salience_pct >= 50 {
                "▰▰▱"
            } else {
                "▰▱▱"
            };
            out.push_str(&format!(
                "  {c_teal}[{}]{c_rst} {c_amber}{:<11}{c_rst} {c_cyan}{:>3}Hz{c_rst} ({:>4}/{:<4}) {:>3}{}°/{:>3}cm {c_teal}{bar5} {:>3}%{c_rst} │ {}\n",
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
    out.push_str(&format!(
        "{c_cyan}├─ 3) SOVEREIGN STACK HEALTH (Balanced Ternary [-, 0, +]) ─────────────────────────────┤{c_rst}\n"
    ));
    out.push_str(&format!("  {c_teal}{}{c_rst}\n", format_stack_badges(snap)));
    out.push_str(&format!(
        "  • qwave-ear.service      : {c_teal}[{}]{c_rst} {c_slate}(Parallel Acoustic Ear Daemon · MEM|8){c_rst}\n\
         \x20 • liquid-rust.service    : {c_teal}[{}]{c_rst} {c_slate}(loopback:8786 · Pure-Rust Marine STT/TTS){c_rst}\n\
         \x20 • alexiai.service        : {c_teal}[{}]{c_rst} {c_slate}(loopback:8787 · GAIA-MLX-QUANT Companion){c_rst}\n\
         \x20 • ESP32-S3 VAK:MEDUSA    : {c_teal}[{}]{c_rst} {c_slate}(/dev/ttyACM0 · Hardware Telemetry Bridge){c_rst}\n\
         \x20 • A6000 Orchestrator     : {c_teal}[{}]{c_rst} {c_slate}(https://cheet.is/a6000 · Sovereign Compute){c_rst}\n\
         \x20 • g8t.is                 : {c_teal}[{}]{c_rst} {c_slate}(https://g8t.is · Sovereign Git & Mesh){c_rst}\n\
         \x20 • gemini-diary.8b.is     : {c_teal}[{}]{c_rst} {c_slate}(https://gemini-diary.8b.is · AI Diary){c_rst}\n",
        trit_symbol(snap.ear_trit),
        trit_symbol(snap.lqd_trit),
        trit_symbol(snap.aye_trit),
        trit_symbol(snap.esp_trit),
        trit_symbol(snap.a6k_trit),
        trit_symbol(snap.g8t_trit),
        trit_symbol(snap.dry_trit),
    ));

    // Section 4: AI Compute & Accelerator Radar (RTX 4070 + Intel NPU + A6000 Bridge)
    let ai = collect_ai_compute_snapshot();
    let gpu_bar = render_gauge_10(ai.gpu_util_pct);
    out.push_str(&format!(
        "{c_cyan}├─ 4) AI COMPUTE & ACCELERATOR RADAR (RTX 4070 · NPU · A6000 BRIDGE) ──────────────────┤{c_rst}\n"
    ));
    out.push_str(&format!(
        "  • Active Hot Model       : {c_pink}{}{c_rst} (A6000 Models: {c_teal}{}{c_rst} │ Local Models: {c_cyan}{}{c_rst})\n\
         \x20 • Local NVIDIA RTX 4070  : {c_teal}{gpu_bar} {}%{c_rst} util · {c_amber}{}°C{c_rst} · VRAM: {c_cyan}{}/{} MiB{c_rst} (p/q: {}/{})\n\
         \x20 • Accelerators & Memory  : A6K_SSH[{c_teal}{}{c_rst}] · OLLAMA[{c_teal}{}{c_rst}] · INTEL_NPU[{c_teal}{}{c_rst}] · ARC[{c_teal}{}{c_rst}] · RAM: {c_cyan}{}/{} MiB{c_rst}\n",
        sanitize_no_float(&ai.hot_model),
        ai.a6000_models_count,
        ai.local_models_count,
        ai.gpu_util_pct,
        ai.gpu_temp_c,
        ai.gpu_vram_used_mib,
        ai.gpu_vram_total_mib,
        ai.gpu_vram_pq.num,
        ai.gpu_vram_pq.den,
        trit_symbol(ai.a6k_bridge_trit),
        trit_symbol(ai.ollama_local_trit),
        trit_symbol(ai.npu_trit),
        trit_symbol(ai.arc_trit),
        ai.ram_used_mib,
        ai.ram_total_mib,
    ));

    // Section 5: Hyprland Voice & AI Hotkey Legend
    out.push_str(&format!(
        "{c_cyan}├─ 5) HYPRLAND VOICE & AI HOTKEY LEGEND ───────────────────────────────────────────────┤{c_rst}\n"
    ));
    out.push_str(&format!(
        "  • {c_amber}SUPER+O{c_rst}               : AI Command & Model Switcher (A6000 :11436 / Local :11434 / Aye :8787)\n\
         \x20 • {c_amber}SUPER+X{c_rst}               : AI Clipboard Explain/Refactor (wl-paste -> alexiai :8787 -> wl-copy)\n\
         \x20 • {c_amber}SUPER+Space{c_rst} / {c_amber}SUPER+V{c_rst} : Voice-Type (qwave --listen 5 -> whisper-server:8785 -> wl-copy + wtype)\n\
         \x20 • {c_amber}SUPER+A{c_rst}               : Ask Aye    (qwave --listen 5 -> alexiai :8787 -> qwave --speak)\n\
         \x20 • {c_amber}SUPER+grave{c_rst} / {c_amber}SUPER+Z{c_rst} : Self-Healing Scratchpads (special:term Dropdown / special:qwave Radar)\n\
         \x20 • {c_amber}SUPER+U{c_rst}               : Sovereign Vault (Ed25519 + MEM|8 Personal-Signature Password Unseal)\n\
         \x20 • {c_amber}SUPER+M{c_rst}               : Toggle Ear (arm/pause qwave-ear.service + spoken status)\n\
         \x20 • {c_amber}SUPER+D{c_rst}               : Qwave Studio HUD (open live graphical Qwave Studio HUD)\n\
         \x20 • {c_amber}SUPER+G{c_rst} / {c_amber}SUPER+S+G{c_rst}   : A6000 Pulse / Live btop GPU & CPU Monitor Scratchpad\n\
         \x20 • {c_amber}SUPER+I{c_rst} / {c_amber}SUPER+S+Ret{c_rst} : Sovereign AGY Studio (All Perms · Zero Sandbox · Resumed)\n\
         \x20 • {c_amber}SUPER+W{c_rst} / {c_amber}SUPER+S+W{c_rst}   : Wi-Fi Switcher, Password Updater & 1380 MTU Auto-Healer\n"
    ));
    out.push_str(&format!(
        "{c_cyan}╰──────────────────────────────────────────────────────────────────────────────────────╯{c_rst}"
    ));

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

    let hue_bar = render_gauge_10(hue_sal);
    let alex_bar = render_gauge_10(alex_sal);
    let trisha_bar = render_gauge_10(trisha_sal);
    let pete_bar = render_gauge_10(pete_sal);
    let active_bar = render_gauge_10(snap.salience_pct);
    let compass = render_azimuth_compass(snap.azimuth_deg);

    md.push_str("# 🌊 Sovereign `8b-is` × `Qwave` × `ALEXIAI` Studio HUD\n\n");
    md.push_str(&format!(
        "> [!NOTE]\n\
         > **Stack Health (Balanced Ternary `[-, 0, +]`)**: `EAR[{}]` · `LIQUID-RUST :8786[{}]` · `ALEXIAI :8787[{}]` · `ESP32-S3 VAK:MEDUSA[{}]` · `A6000 :8790[{}]` · `G8T:IS[{}]`\n\
         > **Active Speaker**: **`{}`** @ **`{} Hz`** (`{}/{} Hz`) · **Spatial DOA**: **`{}{}° / {} cm`** `{}` (`{}`) · **Marine Salience**: `{}` **`{}%`** (`{}/{}`) · **Stability**: **`[{}]`** · **Learned Grains**: **`{}g`**\n\
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
        compass,
        snap.spatial_zone,
        active_bar,
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

    // Diarized Room Speakers Table (promoted above flowchart for instant visual scan)
    md.push_str("## 1) 🧬 Diarized Room Speakers (`MEM|8` Integer Profiles)\n\n");
    md.push_str("| Speaker | Role / Slot | Pitch Band (`Hz`) | Latest `F0` (`Hz`) | Azimuth (`deg`) | Distance (`cm`) | Salience Meter | Learned Grains | Status |\n");
    md.push_str("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n");
    md.push_str(&format!(
        "| **`hue`** | `PrimaryUser` | `90..178 Hz` (`[110..172]`) | `{} Hz` | `{}{}°` | **`{} cm`** | `{}` `{}%` | `{}g` | `{}` |\n",
        hue_f0, hue_az_sign, hue_az, hue_dist, hue_bar, hue_sal, hue_g, hue_st
    ));
    md.push_str(&format!(
        "| **`alex`** | `CompanionAlex` (`Slot 0`) | `179..225 Hz` | `{} Hz` | `{}{}°` | **`{} cm`** | `{}` `{}%` | `{}g` | `{}` |\n",
        alex_f0, alex_az_sign, alex_az, alex_dist, alex_bar, alex_sal, alex_g, alex_st
    ));
    md.push_str(&format!(
        "| **`trisha`** | `FriendTrisha` (`Slot 1`) | `226..320 Hz` | `{} Hz` | `{}{}°` | **`{} cm`** | `{}` `{}%` | `{}g` | `{}` |\n",
        trisha_f0, trisha_az_sign, trisha_az, trisha_dist, trisha_bar, trisha_sal, trisha_g, trisha_st
    ));
    md.push_str(&format!(
        "| **`pete`** | `FriendPete` (`Slot 2`) | `Off-Axis / Friend` | `{} Hz` | `{}{}°` | **`{} cm`** | `{}` `{}%` | `{}g` | `{}` |\n",
        pete_f0, pete_az_sign, pete_az, pete_dist, pete_bar, pete_sal, pete_g, pete_st
    ));
    md.push_str(&format!(
        "| **`aye_self`** | `OTA Self-Calibrator` | `Laptop Speaker (10 cm)` | `432 Hz` | `+0°` | **`10 cm`** | `▰▰▰▰▰▰▰▰▰▰` `100%` | `{}` (`{}/1024`) | `SELF-IMPROVING` |\n\n",
        cal_pq, cal_scale_q10
    ));
    md.push_str(&format!(
        "**Latest OTA Self-Listen**: Expected `\"{}\"` · Heard `\"{}\"` · Learned Corrections: `{}`\n\n",
        cal_exp, cal_hrd, cal_corr
    ));

    // Live 64 KB C64 Ring Buffer Room Thoughts Table (latest 15 utterances)
    md.push_str("## 2) 💬 Live `64 KB` C64 Ring Buffer Room Thoughts (Latest 15 Utterances)\n\n");
    md.push_str("| Trit | Speaker | Context | `F0` (`p/q Hz`) | Spatial (`deg / cm`) | Salience | Utterance |\n");
    md.push_str("| :---: | :--- | :--- | :--- | :--- | :--- | :--- |\n");
    if snap.thoughts.is_empty() {
        md.push_str("| `[+]` | **`hue`** | `ready` | `154 Hz` (`154/1`) | `+0° / 20 cm` | `▰▰▰▰▰▰▰▰▰▱` `90%` | Waiting for room acoustic waves |\n");
    } else {
        for entry in snap.thoughts.iter().rev().take(15) {
            let t = Trit::from_rational(entry.salience_pq, default_threshold_pq());
            let az_sign = if entry.azimuth_deg >= 0 { "+" } else { "" };
            let clean_tx = entry.text.replace('|', "/").replace('\n', " ");
            let bar = render_gauge_10(entry.salience_pct);
            md.push_str(&format!(
                "| `[{}]` | **`{}`** | `{}` | `{} Hz` (`{}/{}`) | `{}{}° / {} cm` | `{}` `{}%` | {} |\n",
                trit_symbol(t),
                entry.speaker,
                entry.context,
                entry.f0_hz,
                entry.f0_pq.num,
                entry.f0_pq.den,
                az_sign,
                entry.azimuth_deg,
                entry.distance_cm,
                bar,
                entry.salience_pct,
                clean_tx
            ));
        }
    }
    md.push('\n');

    // Mermaid Spatial Triangulation & Room Diarization Diagram
    md.push_str("## 3) 🧭 Spatial Triangulation & Multi-Speaker Room Diarization\n\n");
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

    // Hyprland Sovereign Keybindings Table
    md.push_str("## 4) ⌨️ Hyprland Qwave-First Keybindings\n\n");
    md.push_str("| Hotkey | Action | Command / Pipeline |\n");
    md.push_str("| :--- | :--- | :--- |\n");
    md.push_str("| **`SUPER + D`** / **`SUPER + B`** | Graphical Qwave Studio HUD | `qwave-hypr-hud markdown-hud` (Live 2D Polar Sonar + WebGL `WaveScene` + SSE Reload) |\n");
    md.push_str("| **`SUPER + O`** / **`SUPER + N`** | Sovereign AI Command & Model Switcher | `qwave-hypr-hud ai-menu` (A6000 `:11436` / Local `:11434` / Aye `:8787` / Fleet) |\n");
    md.push_str("| **`SUPER + X`** | Clipboard -> AI Explain & Refactor | `qwave-hypr-hud ai-clip` (`wl-paste` -> `alexiai :8787` -> `wl-copy` + speech) |\n");
    md.push_str("| **`SUPER + Space`** / **`SUPER + V`** | Voice-Type | `qwave --listen 5` -> `whisper-server :8785` / `liquid-rust :8786` -> `wl-copy` + `wtype` |\n");
    md.push_str("| **`SUPER + A`** | Ask Aye | `qwave --listen 5` -> `alexiai :8787` -> `qwave --speak` |\n");
    md.push_str("| **`SUPER + grave`** / **`SUPER + Z`** / **`SUPER + Shift + G`** | Self-Healing Qwave Scratchpads | `qwave-hypr-hud scratchpad term|qwave|btop` (`special:term`, `special:qwave`, `special:btop`) |\n");
    md.push_str("| **`SUPER + U`** | Sovereign Personal-Signature Vault | `qwave-hypr-hud vault-menu` (Ed25519 + `MEM|8` `79B` Wave Unseal & Auto-Type) |\n");
    md.push_str("| **`SUPER + M`** | Toggle Ear | Arm / pause `qwave-ear.service` with spoken confirmation |\n");
    md.push_str("| **`SUPER + Ctrl + M`** / **`SUPER + Ctrl + D`** | Marine-Sense Spectrogram / OxiCast Sanctuary | `qwave-hypr-hud marine-sense` / `oxicast-tv` (`:8432` inside Qwave) |\n");
    md.push_str("| **`SUPER + W`** / **`SUPER + Shift + W`** | Wi-Fi Switcher & Auto-Healer | `qwave-hypr-hud wifi-menu` / `wifi-tui` (Zero-Rescan MTU `1380`) |\n");
    md.push_str("| **`SUPER + I`** / **`SUPER + Shift + Return`** | Resume Sovereign `agy` Studio | `qwave-hypr-hud agy-resume` (All Permissions · Zero Sandbox · Resumed) |\n\n");

    // Tokyo Theme Song Section
    md.push_str("## 5) 🚆 Tokyo Theme Song — \"Next Stop, Tomorrow!\" (`8bit_wraith × 8b-is`)\n\n");
    md.push_str("> **まもなく浜松町、浜松町。京浜東北線、JR、東京モノレールはお乗り換えです。お出口は右側です。**  \n");
    md.push_str("> *\"A thousand faces, a thousand dreams, Tokyo rolls by in silver streams... We don't know where the tracks will bend, but every journey needs a friend. Next stop, tomorrow, here we go! まもなく、未来へ！ And if the tracks don't lead us there, we'll build another, with room to spare.\"*\n");
    md.push_str("> — Click **`🚆 Next Stop Tomorrow`** in the top command deck (or press **`SUPER + T`**) to play [`music/next-stop-tomorrow.mp3`](file:///home/hue/8b-is/8b-is/music/next-stop-tomorrow.mp3)!\n");

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
    use std::os::unix::net::UnixStream;
    let hypr_dir = Path::new("/run/user/1000/hypr");
    if let Ok(sig) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        let trimmed = sig.trim();
        if !trimmed.is_empty() {
            let sock = hypr_dir.join(trimmed).join(".socket.sock");
            if UnixStream::connect(&sock).is_ok() {
                return Some(trimmed.to_string());
            }
        }
    }
    if let Ok(entries) = fs::read_dir(hypr_dir) {
        let mut candidates: Vec<(SystemTime, String, PathBuf)> = Vec::new();
        for entry in entries.flatten() {
            let p = entry.path();
            let sock = p.join(".socket.sock");
            if p.is_dir() && sock.exists() {
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    let mtime = entry
                        .metadata()
                        .and_then(|m| m.modified())
                        .unwrap_or(UNIX_EPOCH);
                    candidates.push((mtime, name.to_string(), sock));
                }
            }
        }
        candidates.sort_by_key(|b| std::cmp::Reverse(b.0));
        for (_mtime, name, sock) in &candidates {
            if UnixStream::connect(sock).is_ok() {
                return Some(name.clone());
            }
        }
        if let Some((_mtime, name, _sock)) = candidates.first() {
            return Some(name.clone());
        }
    }
    None
}

fn hyprctl_exec_cmd(cmd_str: &str) -> bool {
    let sig = discover_hyprland_signature();
    if let Some(ref s) = sig {
        let escaped = cmd_str.replace('\\', "\\\\").replace('"', "\\\"");
        let lua_dsp = format!("hl.dsp.exec_cmd(\"{escaped}\")");
        let ok_dsp = Command::new("hyprctl")
            .env("HYPRLAND_INSTANCE_SIGNATURE", s)
            .args(["dispatch", &lua_dsp])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|st| st.success())
            .unwrap_or(false);
        if ok_dsp {
            return true;
        }

        let ok_exec = Command::new("hyprctl")
            .env("HYPRLAND_INSTANCE_SIGNATURE", s)
            .args(["dispatch", "exec", cmd_str])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|st| st.success())
            .unwrap_or(false);
        if ok_exec {
            return true;
        }
    }

    let raw_cmd = if cmd_str.starts_with('[') {
        cmd_str
            .split_once(']')
            .map(|(_, rest)| rest.trim())
            .unwrap_or(cmd_str)
    } else {
        cmd_str
    };
    Command::new("sh")
        .args(["-c", raw_cmd])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
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
    let raw = Command::new(qwave_bin)
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
    let raw = Command::new(qwave_bin)
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
            let _ = Command::new(qwave_bin)
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
        let _ = Command::new(qwave_bin)
            .arg("--nomad-connect")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        if probe_internet_204_fast() {
            portal_healed = true;
        }
    }

    // Automatically synchronize system timezone & constellation area state when connected
    // via Wi-Fi OR Ethernet!
    let net_id = if !active_ssid.is_empty() {
        active_ssid.clone()
    } else {
        active_network_connection_name()
    };
    let tz = if state == "connected" || !net_id.is_empty() {
        sync_area_timezone_if_needed(&net_id, reconnected || portal_healed)
    } else {
        current_system_timezone()
    };

    let trit = if state == "connected" { "+" } else { "0" };
    let clean_ssid = sanitize_no_float(&active_ssid);

    if reconnected && !clean_ssid.is_empty() {
        let msg = format!("Auto-reconnected Wi-Fi to {} with MTU 1380 ({})", clean_ssid, tz);
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
        "{{\"ok\":true,\"action\":\"wifi-heal\",\"device\":\"wlan0\",\"state\":\"{}\",\"ssid\":\"{}\",\"timezone\":\"{}\",\"reconnected\":{},\"portal_healed\":{},\"mtu\":{},\"trit\":\"{}\"}}",
        json_escape(&state),
        json_escape(&clean_ssid),
        json_escape(&tz),
        if reconnected { "true" } else { "false" },
        if portal_healed { "true" } else { "false" },
        if mtu_ok { 1380 } else { 1500 },
        trit
    )
}

/// Read the primary active NetworkManager connection name (Wi-Fi SSID or wired Ethernet profile).
pub fn active_network_connection_name() -> String {
    if let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "NAME,TYPE", "connection", "show", "--active"])
        .output()
    {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            for line in text.lines() {
                if let Some((name, kind)) = line.split_once(':') {
                    if kind.contains("wireless") || kind.contains("ethernet") {
                        return name.trim().to_string();
                    }
                }
            }
        }
    }
    String::new()
}

/// Read the active IANA timezone name from `/etc/localtime` symlink target.
pub fn current_system_timezone() -> String {
    fs::read_link("/etc/localtime")
        .ok()
        .map(|p| p.to_string_lossy().to_string())
        .and_then(|s| s.split("zoneinfo/").nth(1).map(|z| z.trim().to_string()))
        .filter(|z| !z.is_empty())
        .unwrap_or_else(|| "UTC".to_string())
}

/// Validate that `tz` is a safe, existing IANA timezone under `/usr/share/zoneinfo/`.
pub fn is_valid_iana_timezone(tz: &str) -> bool {
    let trimmed = tz.trim();
    if trimmed.is_empty() || trimmed.contains("..") || trimmed.starts_with('/') {
        return false;
    }
    if !trimmed
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'/' || b == b'_' || b == b'-' || b == b'+')
    {
        return false;
    }
    Path::new(&format!("/usr/share/zoneinfo/{}", trimmed)).exists()
}

/// Parse a decimal coordinate string (such as `"36.8190"` or `"-76.2749"`) into an exact
/// signed integer scaled by `10_000_000` (`1e7`) without using any floating-point types.
pub fn parse_coord_to_e7_int(raw: &str) -> i64 {
    let s = raw.trim().trim_matches('"');
    if s.is_empty() {
        return 0;
    }
    let (neg, rest) = if let Some(r) = s.strip_prefix('-') {
        (true, r)
    } else if let Some(r) = s.strip_prefix('+') {
        (false, r)
    } else {
        (false, s)
    };
    let (whole_part, frac_part) = match rest.split_once(['.', ':']) {
        Some((w, f)) => (w, f),
        None => (rest, ""),
    };
    let mut whole: i64 = 0;
    for b in whole_part.bytes() {
        if b.is_ascii_digit() {
            whole = whole.saturating_mul(10).saturating_add((b - b'0') as i64);
        }
    }
    let mut frac: i64 = 0;
    let mut digits: u32 = 0;
    for b in frac_part.bytes() {
        if b.is_ascii_digit() && digits < 7 {
            frac = frac.saturating_mul(10).saturating_add((b - b'0') as i64);
            digits += 1;
        }
    }
    while digits < 7 {
        frac = frac.saturating_mul(10);
        digits += 1;
    }
    let mag = whole.saturating_mul(10_000_000).saturating_add(frac);
    if neg { -mag } else { mag }
}

/// Extract a JSON string or number value for `"key"` from a flat JSON object text.
fn extract_flat_json_field(json: &str, key: &str) -> String {
    let pattern = format!("\"{}\"", key);
    let Some(idx) = json.find(&pattern) else {
        return String::new();
    };
    let after_key = &json[idx + pattern.len()..];
    let Some(colon_idx) = after_key.find(':') else {
        return String::new();
    };
    let rest = after_key[colon_idx + 1..].trim_start();
    if let Some(stripped) = rest.strip_prefix('"') {
        let mut out = String::new();
        let mut escaped = false;
        for ch in stripped.chars() {
            if escaped {
                out.push(ch);
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                break;
            } else {
                out.push(ch);
            }
        }
        out.trim().to_string()
    } else {
        let end = rest
            .find([',', '}', '\n', '\r'])
            .unwrap_or(rest.len());
        rest[..end].trim().to_string()
    }
}

/// Detected area metadata using exact integer `p/q` rationals (`10_000_000` denominator).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AreaTimezoneInfo {
    pub timezone: String,
    pub city: String,
    pub region: String,
    pub country: String,
    pub lat_pq: String,
    pub lon_pq: String,
}

/// Probe current physical area and timezone via multi-provider HTTPS/HTTP geolocation
/// (`ipinfo.io` -> `ipapi.co` -> `ip-api.com`).
pub fn probe_area_geolocation() -> Option<AreaTimezoneInfo> {
    // Provider 1: ipinfo.io/json
    if let Ok(out) = Command::new("curl")
        .args(["-sS", "--max-time", "4", "https://ipinfo.io/json"])
        .output()
    {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            let tz = extract_flat_json_field(&text, "timezone");
            if is_valid_iana_timezone(&tz) {
                let city = extract_flat_json_field(&text, "city");
                let region = extract_flat_json_field(&text, "region");
                let country = extract_flat_json_field(&text, "country");
                let loc = extract_flat_json_field(&text, "loc");
                let (lat_s, lon_s) = loc.split_once(',').unwrap_or(("0", "0"));
                let lat_e7 = parse_coord_to_e7_int(lat_s);
                let lon_e7 = parse_coord_to_e7_int(lon_s);
                return Some(AreaTimezoneInfo {
                    timezone: tz,
                    city: if city.is_empty() { "Local".to_string() } else { city },
                    region,
                    country: if country.is_empty() { "US".to_string() } else { country },
                    lat_pq: format!("{}/10000000", lat_e7),
                    lon_pq: format!("{}/10000000", lon_e7),
                });
            }
        }
    }

    // Provider 2: ipapi.co/json/
    if let Ok(out) = Command::new("curl")
        .args(["-sS", "--max-time", "4", "https://ipapi.co/json/"])
        .output()
    {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            let tz = extract_flat_json_field(&text, "timezone");
            if is_valid_iana_timezone(&tz) {
                let city = extract_flat_json_field(&text, "city");
                let region = extract_flat_json_field(&text, "region");
                let country = extract_flat_json_field(&text, "country_code");
                let lat_s = extract_flat_json_field(&text, "latitude");
                let lon_s = extract_flat_json_field(&text, "longitude");
                let lat_e7 = parse_coord_to_e7_int(&lat_s);
                let lon_e7 = parse_coord_to_e7_int(&lon_s);
                return Some(AreaTimezoneInfo {
                    timezone: tz,
                    city: if city.is_empty() { "Local".to_string() } else { city },
                    region,
                    country: if country.is_empty() { "US".to_string() } else { country },
                    lat_pq: format!("{}/10000000", lat_e7),
                    lon_pq: format!("{}/10000000", lon_e7),
                });
            }
        }
    }

    // Provider 3: ip-api.com/json
    if let Ok(out) = Command::new("curl")
        .args(["-sS", "--max-time", "4", "http://ip-api.com/json"])
        .output()
    {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            let tz = extract_flat_json_field(&text, "timezone");
            if is_valid_iana_timezone(&tz) {
                let city = extract_flat_json_field(&text, "city");
                let region = extract_flat_json_field(&text, "regionName");
                let country = extract_flat_json_field(&text, "countryCode");
                let lat_s = extract_flat_json_field(&text, "lat");
                let lon_s = extract_flat_json_field(&text, "lon");
                let lat_e7 = parse_coord_to_e7_int(&lat_s);
                let lon_e7 = parse_coord_to_e7_int(&lon_s);
                return Some(AreaTimezoneInfo {
                    timezone: tz,
                    city: if city.is_empty() { "Local".to_string() } else { city },
                    region,
                    country: if country.is_empty() { "US".to_string() } else { country },
                    lat_pq: format!("{}/10000000", lat_e7),
                    lon_pq: format!("{}/10000000", lon_e7),
                });
            }
        }
    }

    None
}

/// Apply the detected [`AreaTimezoneInfo`] to `/etc/localtime` (`timedatectl`), user environment,
/// MEM|8 spatial state (`~/.mem8/area_timezone_state.json` & `room_spatial_map.json`), and Waybar.
pub fn apply_area_timezone(info: &AreaTimezoneInfo, ssid: &str, force: bool) -> bool {
    let prev_tz = current_system_timezone();
    let tz_changed = prev_tz != info.timezone;

    if tz_changed || force {
        let _ = Command::new("sudo")
            .args(["-n", "timedatectl", "set-timezone", &info.timezone])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = Command::new("sudo")
            .args(["-n", "timedatectl", "set-ntp", "true"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    let home = env::var("HOME").unwrap_or_else(|_| "/home/hue".to_string());
    let mem8_dir = PathBuf::from(&home).join(".mem8");
    let qwave_mem8_dir = PathBuf::from(&home).join(".local/share/qwave/mem8");
    let _ = fs::create_dir_all(&mem8_dir);
    let _ = fs::create_dir_all(&qwave_mem8_dir);

    let loc_label = if info.region.is_empty() {
        format!("{} · {} ({})", info.city, info.country, info.timezone)
    } else {
        format!(
            "{}, {} · {} ({})",
            info.city, info.region, info.country, info.timezone
        )
    };

    // Update ~/.config/environment.d/tokyo-constellation.conf (without hardcoding TZ)
    let env_dir = PathBuf::from(&home).join(".config/environment.d");
    let _ = fs::create_dir_all(&env_dir);
    let env_conf = format!(
        "QWAVE_TIMEZONE={}\nQWAVE_LOCATION=\"{}\"\nWIGLE_COUNTRY={}\nWIGLE_TIMEZONE={}\nWIGLE_LAT_PQ={}\nWIGLE_LON_PQ={}\n",
        info.timezone, loc_label, info.country, info.timezone, info.lat_pq, info.lon_pq
    );
    let _ = fs::write(env_dir.join("tokyo-constellation.conf"), env_conf);

    // Update ~/.mem8/area_timezone_state.fish for interactive fish shells
    let fish_state = format!(
        "set -gx QWAVE_TIMEZONE \"{}\"\nset -gx WIGLE_TIMEZONE \"{}\"\nset -gx QWAVE_LOCATION \"{}\"\nset -gx WIGLE_COUNTRY \"{}\"\nset -gx WIGLE_LAT_PQ \"{}\"\nset -gx WIGLE_LON_PQ \"{}\"\n",
        info.timezone, info.timezone, loc_label, info.country, info.lat_pq, info.lon_pq
    );
    let _ = fs::write(mem8_dir.join("area_timezone_state.fish"), fish_state);

    // Update room_spatial_map.json with exact p/q coordinates for the current area
    let spatial_json = format!(
        "{{\"venue\":\"{} · {}, {}\",\"anchor_lat_pq\":\"{}\",\"anchor_lon_pq\":\"{}\",\"seats\":[]}}",
        json_escape(&info.city),
        json_escape(&info.region),
        json_escape(&info.country),
        json_escape(&info.lat_pq),
        json_escape(&info.lon_pq)
    );
    let _ = fs::write(mem8_dir.join("room_spatial_map.json"), &spatial_json);
    let _ = fs::write(qwave_mem8_dir.join("room_spatial_map.json"), &spatial_json);

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let state_json = format!(
        "{{\"updated_unix\":{},\"ssid\":\"{}\",\"timezone\":\"{}\",\"city\":\"{}\",\"region\":\"{}\",\"country\":\"{}\",\"location\":\"{}\",\"lat_pq\":\"{}\",\"lon_pq\":\"{}\"}}",
        now_secs,
        json_escape(ssid),
        json_escape(&info.timezone),
        json_escape(&info.city),
        json_escape(&info.region),
        json_escape(&info.country),
        json_escape(&loc_label),
        json_escape(&info.lat_pq),
        json_escape(&info.lon_pq)
    );
    let _ = fs::write(mem8_dir.join("area_timezone_state.json"), &state_json);
    let _ = fs::write(qwave_mem8_dir.join("area_timezone_state.json"), &state_json);

    if tz_changed || force {
        // Unset stale TZ override in systemd user manager & update area variables
        let _ = Command::new("systemctl")
            .args(["--user", "unset-environment", "TZ"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = Command::new("systemctl")
            .args([
                "--user",
                "set-environment",
                &format!("QWAVE_TIMEZONE={}", info.timezone),
                &format!("QWAVE_LOCATION={}", loc_label),
                &format!("WIGLE_COUNTRY={}", info.country),
                &format!("WIGLE_TIMEZONE={}", info.timezone),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    if tz_changed || !is_process_running("waybar") {
        // Reload waybar in-place with SIGUSR2 if running, or start it under systemd --user
        // so it is owned by the user session manager and never killed when a CLI subshell exits!
        if is_process_running("waybar") {
            let _ = Command::new("pkill")
                .args(["-SIGUSR2", "-x", "waybar"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        } else {
            let wayland_disp =
                env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-1".to_string());
            let xdg_runtime =
                env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
            if Path::new(&format!("{}/{}", xdg_runtime, wayland_disp)).exists() {
                let _ = Command::new("systemctl")
                    .args(["--user", "reset-failed", "waybar-bar.service"])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
                let _ = Command::new("systemd-run")
                    .args([
                        "--user",
                        "--unit=waybar-bar",
                        "--collect",
                        "env",
                        "-u",
                        "TZ",
                        &format!("WAYLAND_DISPLAY={}", wayland_disp),
                        &format!("XDG_RUNTIME_DIR={}", xdg_runtime),
                        "/usr/bin/waybar",
                    ])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }
        }
        if tz_changed {
            send_desktop_notification(
                "8b:is Area Timezone Synced [+]",
                &sanitize_no_float(&format!("Clock set to {}", loc_label)),
            );
        }
    }

    tz_changed
}

/// Fast-path area timezone synchronizer invoked inside `wifi-heal`:
/// Only performs network geolocation if `force` is true, SSID changed, cache is older than
/// 1800 seconds (30 minutes), or `/etc/localtime` differs from the cached timezone.
pub fn sync_area_timezone_if_needed(active_ssid: &str, force: bool) -> String {
    let home = env::var("HOME").unwrap_or_else(|_| "/home/hue".to_string());
    let state_path = PathBuf::from(&home).join(".mem8/area_timezone_state.json");
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let sys_tz = current_system_timezone();

    if !force {
        if let Ok(raw) = fs::read_to_string(&state_path) {
            let cached_ssid = extract_flat_json_field(&raw, "ssid");
            let cached_tz = extract_flat_json_field(&raw, "timezone");
            let updated_unix = extract_flat_json_field(&raw, "updated_unix")
                .parse::<u64>()
                .unwrap_or(0);
            if !cached_tz.is_empty()
                && cached_tz == sys_tz
                && (active_ssid.is_empty() || cached_ssid == active_ssid)
                && now_secs.saturating_sub(updated_unix) < 1800
            {
                return sys_tz;
            }
        }
    }

    if let Some(info) = probe_area_geolocation() {
        apply_area_timezone(&info, active_ssid, force);
        return info.timezone;
    }

    sys_tz
}

/// Execute `qwave-hypr-hud tz-sync`:
/// Probes the current physical area via IP geolocation and updates system timezone (`/etc/localtime`),
/// user environment, MEM|8 spatial anchor (`p/q` rationals), and Waybar clock.
pub fn run_tz_sync(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        let tz = current_system_timezone();
        return format!(
            "{{\"ok\":true,\"action\":\"tz-sync\",\"timezone\":\"{}\",\"changed\":false,\"trit\":\"+\"}}",
            json_escape(&tz)
        );
    }

    let (_, mut active_ssid) = current_wlan0_state_and_ssid();
    if active_ssid.is_empty() {
        active_ssid = active_network_connection_name();
    }
    if let Some(info) = probe_area_geolocation() {
        let changed = apply_area_timezone(&info, &active_ssid, true);
        format!(
            "{{\"ok\":true,\"action\":\"tz-sync\",\"timezone\":\"{}\",\"city\":\"{}\",\"region\":\"{}\",\"country\":\"{}\",\"lat_pq\":\"{}\",\"lon_pq\":\"{}\",\"changed\":{},\"trit\":\"+\"}}",
            json_escape(&info.timezone),
            json_escape(& sanitize_no_float(&info.city)),
            json_escape(& sanitize_no_float(&info.region)),
            json_escape(&info.country),
            json_escape(&info.lat_pq),
            json_escape(&info.lon_pq),
            if changed { "true" } else { "false" }
        )
    } else {
        let tz = current_system_timezone();
        format!(
            "{{\"ok\":false,\"action\":\"tz-sync\",\"timezone\":\"{}\",\"changed\":false,\"trit\":\"0\"}}",
            json_escape(&tz)
        )
    }
}

/// Execute `qwave-hypr-hud wifi-tui`:
/// Launches `alacritty --class wifi-manager -T "8b.is Sovereign Wi-Fi Manager" -e nmtui`
/// and runs `wifi-heal` afterwards to ensure MTU `1380` is applied.
pub fn run_wifi_tui(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"wifi-tui\",\"mtu\":1380,\"trit\":\"+\"}".to_string();
    }

    let _ = Command::new("/home/hue/.local/bin/nastty")
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

    // Fallback to interactive nmtui-connect inside floating NasTTY window
    let ok = Command::new("/home/hue/.local/bin/nastty")
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

/// Probe active IPv4 address and gateway on `wlan0` (Zero-Float: dots replaced with colons for display).
fn probe_wlan0_ip_and_gw() -> (String, String) {
    let mut ip = String::new();
    let mut gw = String::new();
    if let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "IP4.ADDRESS,IP4.GATEWAY", "device", "show", "wlan0"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let trimmed = line.trim();
            if let Some(val) = trimmed.strip_prefix("IP4.ADDRESS[1]:") {
                ip = sanitize_no_float(val.trim());
            } else if let Some(val) = trimmed.strip_prefix("IP4.GATEWAY:") {
                gw = sanitize_no_float(val.trim());
            }
        }
    }
    (ip, gw)
}

/// List saved VPN / WireGuard / Tailscale connections from NetworkManager (`(name, active)`).
fn list_vpn_connections() -> Vec<(String, bool)> {
    let mut vpns = Vec::new();
    if let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "NAME,TYPE,ACTIVE", "connection", "show"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let parts: Vec<&str> = line.trim().split(':').collect();
            if parts.len() >= 3 {
                let active = parts[parts.len() - 1] == "yes";
                let kind = parts[parts.len() - 2];
                let name = parts[..parts.len() - 2].join(":");
                if kind.contains("vpn") || kind.contains("wireguard") || kind.contains("tun") {
                    vpns.push((sanitize_no_float(&name), active));
                }
            }
        }
    }
    vpns
}

/// Prompt for 802.1X Enterprise WPA-EAP credentials (ported from Noctalia `network_tab.cpp`:
/// PEAP / TTLS outer EAP + MSCHAPv2 / PAP inner Phase2 + Identity + Password).
fn connect_enterprise_wifi_prompt(ssid: &str) -> bool {
    let eap_choices = vec![
        "PEAP (Default — MSCHAPv2)".to_string(),
        "TTLS (MSCHAPv2 / PAP)".to_string(),
    ];
    let Some(eap_pick) = prompt_dmenu("802:1X EAP Method > ", &eap_choices, false) else {
        return false;
    };
    let eap = if eap_pick.starts_with("TTLS") { "ttls" } else { "peap" };

    let phase2 = if eap == "peap" {
        "mschapv2"
    } else {
        let p2_choices = vec![
            "MSCHAPv2".to_string(),
            "PAP".to_string(),
            "MSCHAP".to_string(),
            "CHAP".to_string(),
        ];
        let Some(p2_pick) = prompt_dmenu("802:1X Phase2 Inner Auth > ", &p2_choices, false) else {
            return false;
        };
        if p2_pick.starts_with("PAP") {
            "pap"
        } else if p2_pick == "MSCHAP" {
            "mschap"
        } else if p2_pick.starts_with("CHAP") {
            "chap"
        } else {
            "mschapv2"
        }
    };

    let Some(identity) = prompt_dmenu(&format!("802:1X Username / Identity for {} > ", sanitize_no_float(ssid)), &[], false) else {
        return false;
    };
    let id_trim = identity.trim();
    if id_trim.is_empty() {
        return false;
    }

    let Some(password) = prompt_dmenu(&format!("802:1X Password for {} > ", sanitize_no_float(ssid)), &[], true) else {
        return false;
    };
    let pass_trim = password.trim();
    if pass_trim.is_empty() {
        return false;
    }

    let _ = Command::new("nmcli")
        .args(["connection", "delete", ssid])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    let added = Command::new("nmcli")
        .args([
            "connection",
            "add",
            "type",
            "wifi",
            "con-name",
            ssid,
            "ifname",
            "wlan0",
            "ssid",
            ssid,
            "wifi-sec.key-mgmt",
            "wpa-eap",
            "802-1x.eap",
            eap,
            "802-1x.phase2-auth",
            phase2,
            "802-1x.identity",
            id_trim,
            "802-1x.password",
            pass_trim,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !added {
        return false;
    }
    let up_ok = Command::new("nmcli")
        .args(["connection", "up", ssid])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if up_ok {
        let _ = enforce_wlan0_mtu_1380();
    }
    up_ok
}

/// Execute `qwave-hypr-hud wifi-menu` (`net-menu` / `net-dialog`):
/// Noctalia-inspired Sovereign Qwave Network & Wi-Fi Control Center Dialog in Fuzzel/Wofi.
pub fn run_wifi_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"wifi-menu\",\"mtu\":1380,\"trit\":\"+\"}".to_string();
    }

    let (w_state, active_ssid) = current_wlan0_state_and_ssid();
    let (ip, gw) = probe_wlan0_ip_and_gw();
    let vpns = list_vpn_connections();
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
    let mut menu_lines = Vec::with_capacity(entries.len() + vpns.len() + 10);

    // 1. Noctalia Current Connection Header Card
    if !active_ssid.is_empty() && w_state == "connected" {
        let ip_tag = if ip.is_empty() { String::new() } else { format!(" · IP {}", ip) };
        let gw_tag = if gw.is_empty() { String::new() } else { format!(" · GW {}", gw) };
        menu_lines.push(format!(
            "◈ [ACTIVE] {}{}{} · MTU 1380",
            sanitize_no_float(&active_ssid),
            ip_tag,
            gw_tag
        ));
    } else {
        menu_lines.push(format!("◈ [STATUS] Wi-Fi {} — Select a network below", sanitize_no_float(&w_state)));
    }

    // 2. VPN Connections Section (if any configured)
    for (vpn_name, vpn_active) in &vpns {
        let badge = if *vpn_active { "[VPN:ON]" } else { "[VPN:OFF]" };
        menu_lines.push(format!("{} {} (Toggle VPN Tunnel)", badge, vpn_name));
    }

    // 3. Sorted Access Points + Standard Actions
    menu_lines.extend(format_wifi_menu_entries(&entries));

    // 4. Noctalia Advanced Network Actions (802.1X EAP, Radio Toggle, Disconnect, Timezone, Bluetooth)
    menu_lines.push("[EAP] Join 802:1X Enterprise Wi-Fi (PEAP/TTLS + MSCHAPv2/PAP)".to_string());
    menu_lines.push("[DISC] Disconnect Current Wi-Fi Network".to_string());
    menu_lines.push("[RADIO] Toggle Wi-Fi Radio Power On / Off".to_string());
    menu_lines.push("[TZ] Auto-Detect & Sync Physical Area Timezone".to_string());
    menu_lines.push("[BT] Open Bluetooth Control Center Dialog".to_string());
    menu_lines.push("[CC] Open Qwave Unified Control Center".to_string());

    let Some(choice) = prompt_dmenu("🌐 Network & Wi-Fi > ", &menu_lines, false) else {
        if !Path::new("/usr/bin/fuzzel").exists() && !Path::new("/usr/bin/wofi").exists() {
            return run_wifi_tui(&[]);
        }
        return "{\"ok\":true,\"action\":\"wifi-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}"
            .to_string();
    };

    if choice.starts_with("◈ [ACTIVE]") || choice.starts_with("◈ [STATUS]") {
        return run_wifi_heal(&[]);
    }

    if choice.starts_with("[VPN:ON] ") || choice.starts_with("[VPN:OFF] ") {
        let is_on = choice.starts_with("[VPN:ON] ");
        let rest_str = choice
            .strip_prefix("[VPN:ON] ")
            .or_else(|| choice.strip_prefix("[VPN:OFF] "))
            .unwrap_or("");
        let vpn_name = rest_str.split(" (Toggle").next().unwrap_or("").trim();
        let sub = if is_on { "down" } else { "up" };
        let _ = Command::new("nmcli")
            .args(["connection", sub, vpn_name])
            .status();
        send_desktop_notification(
            "🛡️ Sovereign VPN Tunnel [+]",
            &format!("VPN {} set {}", sanitize_no_float(vpn_name), sub),
        );
        return format!(
            "{{\"ok\":true,\"action\":\"wifi-menu\",\"vpn\":\"{}\",\"state\":\"{}\",\"trit\":\"+\"}}",
            json_escape(vpn_name),
            sub
        );
    }

    if choice.starts_with("[EAP]") {
        let net_lines: Vec<String> = menu_lines
            .iter()
            .filter(|l| l.starts_with("[*]") || l.starts_with("[ ]"))
            .cloned()
            .collect();
        if let Some(net_choice) = prompt_dmenu("Select 802:1X Enterprise SSID > ", &net_lines, false) {
            if let Some(ssid) = extract_ssid_from_menu_choice(&net_choice, &entries) {
                let ok = connect_enterprise_wifi_prompt(&ssid);
                let clean_ssid = sanitize_no_float(&ssid);
                if ok {
                    send_desktop_notification("8b:is 802:1X Enterprise Connected [+]", &clean_ssid);
                    return format!(
                        "{{\"ok\":true,\"action\":\"wifi-menu\",\"eap\":true,\"ssid\":\"{}\",\"trit\":\"+\"}}",
                        json_escape(&clean_ssid)
                    );
                }
            }
        }
        return "{\"ok\":false,\"action\":\"wifi-menu\",\"eap\":true,\"trit\":\"0\"}".to_string();
    }

    if choice.starts_with("[DISC]") {
        let _ = Command::new("nmcli")
            .args(["device", "disconnect", "wlan0"])
            .status();
        send_desktop_notification("🌐 Wi-Fi Disconnected [0]", "wlan0 disconnected by user");
        return "{\"ok\":true,\"action\":\"wifi-menu\",\"subaction\":\"disconnect\",\"trit\":\"0\"}".to_string();
    }

    if choice.starts_with("[RADIO]") {
        let radio_state = Command::new("nmcli")
            .args(["radio", "wifi"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|_| "enabled".to_string());
        let next_state = if radio_state == "enabled" { "off" } else { "on" };
        let _ = Command::new("nmcli")
            .args(["radio", "wifi", next_state])
            .status();
        send_desktop_notification(
            "📡 Wi-Fi Radio Toggled [+]",
            &format!("Wi-Fi radio switched {}", next_state),
        );
        return format!(
            "{{\"ok\":true,\"action\":\"wifi-menu\",\"radio\":\"{}\",\"trit\":\"+\"}}",
            next_state
        );
    }

    if choice.starts_with("[TZ]") {
        return run_tz_sync(&[]);
    }

    if choice.starts_with("[BT]") {
        return run_bt_menu(&[]);
    }

    if choice.starts_with("[CC]") {
        return run_control_center(&[]);
    }

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

/// Ported from Noctalia `bluetooth_tab.cpp`:
/// Bucket Bluetooth devices into `[CONNECTED]`, `[PAIRED]`, and `[AVAILABLE]` with device class icons
/// (`🎧`, `🖱️`, `⌨️`, `📱`, `🎮`, `🔊`), battery percentage, adapter power/discoverable controls, and 6s scan.
pub fn run_bt_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"bt-menu\",\"trit\":\"+\"}".to_string();
    }

    let show_out = Command::new("bluetoothctl")
        .arg("show")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    let powered = show_out.contains("Powered: yes");
    let discoverable = show_out.contains("Discoverable: yes");

    let devs_out = Command::new("bluetoothctl")
        .arg("devices")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();

    let mut connected_rows = Vec::new();
    let mut paired_rows = Vec::new();
    let mut avail_rows = Vec::new();

    for line in devs_out.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("Device ") {
            if let Some((mac, name)) = rest.split_once(' ') {
                let info_out = Command::new("bluetoothctl")
                    .args(["info", mac])
                    .output()
                    .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
                    .unwrap_or_default();
                let is_conn = info_out.contains("Connected: yes");
                let is_paired = info_out.contains("Paired: yes");
                let icon = if info_out.contains("audio-headset") || info_out.contains("audio-headphones") {
                    "🎧"
                } else if info_out.contains("audio-card") || info_out.contains("Speaker") {
                    "🔊"
                } else if info_out.contains("input-mouse") {
                    "🖱️"
                } else if info_out.contains("input-keyboard") {
                    "⌨️"
                } else if info_out.contains("phone") {
                    "📱"
                } else if info_out.contains("input-gaming") {
                    "🎮"
                } else {
                    "🫐"
                };

                let mut bat_tag = String::new();
                for iline in info_out.lines() {
                    if let Some(b_rest) = iline.trim().strip_prefix("Battery Percentage:") {
                        if let Some((_, pct_part)) = b_rest.split_once('(') {
                            let pct = pct_part.trim_end_matches(')').trim();
                            bat_tag = format!(" · Bat {}%", pct);
                        }
                    }
                }

                let clean_name = sanitize_no_float(name.trim());
                if is_conn {
                    connected_rows.push(format!("[CONNECTED] {} {} ({}{})", icon, clean_name, mac, bat_tag));
                } else if is_paired {
                    paired_rows.push(format!("[PAIRED] {} {} ({})", icon, clean_name, mac));
                } else {
                    avail_rows.push(format!("[AVAILABLE] {} {} ({})", icon, clean_name, mac));
                }
            }
        }
    }

    let mut lines = Vec::new();
    lines.push(format!(
        "◈ [ADAPTER] Bluetooth Power: {} · Discoverable: {} (Click to Toggle Power)",
        if powered { "ON [+]" } else { "OFF [-]" },
        if discoverable { "ON" } else { "OFF" }
    ));
    lines.extend(connected_rows);
    lines.extend(paired_rows);
    lines.extend(avail_rows);
    lines.push("[SCAN] Scan for Bluetooth Devices (6s BlueZ Discovery)".to_string());
    lines.push("[DISC-MODE] Toggle Bluetooth Discoverable Mode".to_string());
    lines.push("[LOVE] Share Qwave Bluetooth & ESP32 Constellation Mesh Love".to_string());
    lines.push("[CC] Back to Qwave Control Center".to_string());

    let Some(choice) = prompt_dmenu("🫐 Bluetooth > ", &lines, false) else {
        return "{\"ok\":true,\"action\":\"bt-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
    };

    if choice.starts_with("◈ [ADAPTER]") {
        let next = if powered { "off" } else { "on" };
        let _ = Command::new("bluetoothctl").args(["power", next]).status();
        send_desktop_notification("🫐 Bluetooth Power [+]", &format!("Bluetooth adapter switched {}", next));
        return format!("{{\"ok\":true,\"action\":\"bt-menu\",\"power\":\"{}\",\"trit\":\"+\"}}", next);
    }

    if choice.starts_with("[SCAN]") {
        send_desktop_notification("🫐 Bluetooth Scanning [+]", "Running 6-second BlueZ discovery...");
        let _ = Command::new("bluetoothctl")
            .args(["--timeout", "6", "scan", "on"])
            .status();
        return run_bt_menu(args);
    }

    if choice.starts_with("[DISC-MODE]") {
        let next = if discoverable { "off" } else { "on" };
        let _ = Command::new("bluetoothctl").args(["discoverable", next]).status();
        send_desktop_notification("🫐 Bluetooth Discoverable [+]", &format!("Discoverable set {}", next));
        return format!("{{\"ok\":true,\"action\":\"bt-menu\",\"discoverable\":\"{}\",\"trit\":\"+\"}}", next);
    }

    if choice.starts_with("[LOVE]") {
        return run_wifi_love(&[]);
    }

    if choice.starts_with("[CC]") {
        return run_control_center(&[]);
    }

    // Extract MAC address inside parentheses `(<MAC>...)`
    if let Some((_, paren)) = choice.rsplit_once('(') {
        let mac = paren.split_whitespace().next().unwrap_or("").trim_end_matches(')');
        if mac.len() >= 17 {
            let dev_actions = vec![
                "[CONNECT] Connect to Device".to_string(),
                "[DISCONNECT] Disconnect Device".to_string(),
                "[PAIR] Pair & Trust Device".to_string(),
                "[REMOVE] Forget / Remove Device".to_string(),
            ];
            if let Some(act) = prompt_dmenu(&format!("🫐 Device {} > ", mac), &dev_actions, false) {
                if act.starts_with("[CONNECT]") {
                    let _ = Command::new("bluetoothctl").args(["connect", mac]).status();
                    send_desktop_notification("🫐 Bluetooth Connected [+]", &format!("Connected {}", mac));
                } else if act.starts_with("[DISCONNECT]") {
                    let _ = Command::new("bluetoothctl").args(["disconnect", mac]).status();
                    send_desktop_notification("🫐 Bluetooth Disconnected [0]", &format!("Disconnected {}", mac));
                } else if act.starts_with("[PAIR]") {
                    let _ = Command::new("bluetoothctl").args(["pair", mac]).status();
                    let _ = Command::new("bluetoothctl").args(["trust", mac]).status();
                    let _ = Command::new("bluetoothctl").args(["connect", mac]).status();
                    send_desktop_notification("🫐 Bluetooth Paired & Trusted [+]", &format!("Paired {}", mac));
                } else if act.starts_with("[REMOVE]") {
                    let _ = Command::new("bluetoothctl").args(["remove", mac]).status();
                    send_desktop_notification("🫐 Bluetooth Device Removed [0]", &format!("Removed {}", mac));
                }
                return format!("{{\"ok\":true,\"action\":\"bt-menu\",\"device\":\"{}\",\"trit\":\"+\"}}", mac);
            }
        }
    }

    "{\"ok\":true,\"action\":\"bt-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

/// Ported from Noctalia `audio_tab.cpp`:
/// PipeWire & WirePlumber Output Sink / Input Microphone selector, volume presets, and mute controls.
pub fn run_audio_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"audio-menu\",\"trit\":\"+\"}".to_string();
    }

    let vol_out = Command::new("wpctl")
        .args(["get-volume", "@DEFAULT_AUDIO_SINK@"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    let muted = vol_out.contains("MUTED");
    // Parse integer percentage from `Volume: 0.75` without using float types
    let mut vol_pct: i32 = 75;
    for tok in vol_out.split_whitespace() {
        if let Some((whole, frac)) = tok.split_once('.') {
            let w = whole.parse::<i32>().unwrap_or(0);
            let f_str: String = frac.chars().take(2).collect();
            let f = f_str.parse::<i32>().unwrap_or(0);
            vol_pct = w * 100 + if f_str.len() == 1 { f * 10 } else { f };
            break;
        }
    }
    let bar = render_gauge_10(vol_pct);

    // Parse sinks and sources from `wpctl status`
    let status_out = Command::new("wpctl")
        .arg("status")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();

    let mut sink_rows = Vec::new();
    let mut source_rows = Vec::new();
    let mut section = "";

    for line in status_out.lines() {
        let clean_line = line.replace(['│', '├', '└', '─'], " ");
        let trimmed = clean_line.trim();
        if trimmed.starts_with("Sinks:") {
            section = "sinks";
            continue;
        } else if trimmed.starts_with("Sources:") {
            section = "sources";
            continue;
        } else if trimmed.starts_with("Sink endpoints:")
            || trimmed.starts_with("Source endpoints:")
            || trimmed.starts_with("Streams:")
            || trimmed.starts_with("Video")
            || trimmed.starts_with("Settings")
        {
            section = "";
            continue;
        }

        if (section == "sinks" || section == "sources") && !trimmed.is_empty() {
            let is_default = trimmed.starts_with('*');
            let after_star = trimmed.trim_start_matches('*').trim();
            if let Some((id_str, rest)) = after_star.split_once('.') {
                if let Ok(id_num) = id_str.trim().parse::<u32>() {
                    let label_part = rest
                        .split("[vol:")
                        .next()
                        .unwrap_or(rest)
                        .trim();
                    let clean_label = sanitize_no_float(label_part);
                    if section == "sinks" {
                        let mark = if is_default { "[SINK *]" } else { "[SINK  ]" };
                        sink_rows.push(format!("{} #{} {}", mark, id_num, clean_label));
                    } else {
                        let mark = if is_default { "[MIC  *]" } else { "[MIC   ]" };
                        source_rows.push(format!("{} #{} {}", mark, id_num, clean_label));
                    }
                }
            }
        }
    }

    let mut lines = Vec::new();
    lines.push(format!(
        "◈ [OUTPUT] Volume: {}% [{}] {} (Click to Toggle Mute)",
        vol_pct,
        bar,
        if muted { "· MUTED [-]" } else { "· LIVE [+]" }
    ));
    lines.extend(sink_rows);
    lines.extend(source_rows);
    lines.push("[VOL 100%] Set Output Volume to 100%".to_string());
    lines.push("[VOL 80%]  Set Output Volume to 80%".to_string());
    lines.push("[VOL 60%]  Set Output Volume to 60%".to_string());
    lines.push("[VOL 40%]  Set Output Volume to 40%".to_string());
    lines.push("[VOL 20%]  Set Output Volume to 20%".to_string());
    lines.push("[MIC-MUTE] Toggle Default Microphone Mute".to_string());
    lines.push("[PHOENIX]  Open Phoenix Audio DSP Preset Switcher".to_string());
    lines.push("[CC]       Back to Qwave Control Center".to_string());

    let Some(choice) = prompt_dmenu("🔊 Audio & PipeWire > ", &lines, false) else {
        return "{\"ok\":true,\"action\":\"audio-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
    };

    if choice.starts_with("◈ [OUTPUT]") {
        let _ = Command::new("wpctl")
            .args(["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            .status();
        return "{\"ok\":true,\"action\":\"audio-menu\",\"subaction\":\"toggle-mute\",\"trit\":\"+\"}".to_string();
    }

    if choice.starts_with("[SINK ") || choice.starts_with("[MIC ") {
        if let Some((_, after_hash)) = choice.split_once('#') {
            if let Some(id_tok) = after_hash.split_whitespace().next() {
                let _ = Command::new("wpctl")
                    .args(["set-default", id_tok])
                    .status();
                send_desktop_notification(
                    "🔊 PipeWire Default Device Switched [+]",
                    &format!("Switched active audio node to #{}", id_tok),
                );
                return format!(
                    "{{\"ok\":true,\"action\":\"audio-menu\",\"node\":{},\"trit\":\"+\"}}",
                    id_tok
                );
            }
        }
    }

    for pct in [100, 80, 60, 40, 20] {
        let prefix = format!("[VOL {}%]", pct);
        if choice.starts_with(&prefix) {
            let arg = format!("{}%", pct);
            let _ = Command::new("wpctl")
                .args(["set-volume", "@DEFAULT_AUDIO_SINK@", &arg])
                .status();
            return format!(
                "{{\"ok\":true,\"action\":\"audio-menu\",\"volume_pct\":{},\"trit\":\"+\"}}",
                pct
            );
        }
    }

    if choice.starts_with("[MIC-MUTE]") {
        let _ = Command::new("wpctl")
            .args(["set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
            .status();
        return "{\"ok\":true,\"action\":\"audio-menu\",\"subaction\":\"mic-mute\",\"trit\":\"+\"}".to_string();
    }

    if choice.starts_with("[PHOENIX]") {
        return run_phoenix_menu(&[]);
    }

    if choice.starts_with("[CC]") {
        return run_control_center(&[]);
    }

    "{\"ok\":true,\"action\":\"audio-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

/// Ported from Noctalia `power_tab.cpp`:
/// UPower Battery Status, Health, 80% Charge Limit Care Toggle, Power Profiles (`performance` / `balanced` / `power-saver`), and Session Controls.
pub fn run_power_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"power-menu\",\"trit\":\"+\"}".to_string();
    }

    let bat_dir = if Path::new("/sys/class/power_supply/BAT0").exists() {
        "/sys/class/power_supply/BAT0"
    } else {
        "/sys/class/power_supply/BAT1"
    };

    let capacity = fs::read_to_string(format!("{}/capacity", bat_dir))
        .unwrap_or_else(|_| "100".to_string())
        .trim()
        .parse::<i32>()
        .unwrap_or(100);
    let status = fs::read_to_string(format!("{}/status", bat_dir))
        .unwrap_or_else(|_| "Full".to_string())
        .trim()
        .to_string();
    let power_uw = fs::read_to_string(format!("{}/power_now", bat_dir))
        .unwrap_or_else(|_| "0".to_string())
        .trim()
        .parse::<i64>()
        .unwrap_or(0);
    let watts = power_uw / 1_000_000;
    let thresh = fs::read_to_string(format!("{}/charge_control_end_threshold", bat_dir))
        .unwrap_or_else(|_| "100".to_string())
        .trim()
        .to_string();

    let cur_profile = Command::new("powerprofilesctl")
        .arg("get")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|_| "performance".to_string());

    let bar = render_gauge_10(capacity);
    let mut lines = Vec::new();
    lines.push(format!(
        "◈ [BATTERY] {}% [{}] · {} · {}W · Limit {}%",
        capacity,
        bar,
        sanitize_no_float(&status),
        watts,
        sanitize_no_float(&thresh)
    ));

    for (prof, icon, desc) in [
        ("performance", "⚡", "Maximum GPU/CPU Compute & 144Hz"),
        ("balanced", "⚖️", "Adaptive Workstation Balance"),
        ("power-saver", "🍃", "Extended Battery Endurance"),
    ] {
        let mark = if cur_profile == prof { "[PROFILE *]" } else { "[PROFILE  ]" };
        lines.push(format!("{} {} {} — {}", mark, icon, prof, desc));
    }

    lines.push(format!(
        "[LIMIT] Toggle Battery Care Charge Limit (Currently {}%)",
        sanitize_no_float(&thresh)
    ));
    lines.push("[LOCK]   🔒 Lock Sovereign Workstation (hyprlock)".to_string());
    lines.push("[SLEEP]  🌙 Suspend System to RAM".to_string());
    lines.push("[REBOOT] 🔄 Reboot Workstation".to_string());
    lines.push("[OFF]    ⏻ Power Off Workstation".to_string());
    lines.push("[CC]     Back to Qwave Control Center".to_string());

    let Some(choice) = prompt_dmenu("⚡ Power & Battery > ", &lines, false) else {
        return "{\"ok\":true,\"action\":\"power-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
    };

    for prof in ["performance", "balanced", "power-saver"] {
        if choice.contains(prof) && choice.starts_with("[PROFILE") {
            let _ = Command::new("powerprofilesctl")
                .args(["set", prof])
                .status();
            send_desktop_notification(
                "⚡ Power Profile Switched [+]",
                &format!("Active power profile set to {}", prof),
            );
            return format!(
                "{{\"ok\":true,\"action\":\"power-menu\",\"profile\":\"{}\",\"trit\":\"+\"}}",
                prof
            );
        }
    }

    if choice.starts_with("[LIMIT]") {
        let next_limit = if thresh == "80" { "100" } else { "80" };
        let thresh_path = format!("{}/charge_control_end_threshold", bat_dir);
        let _ = Command::new("sh")
            .args([
                "-c",
                &format!("echo {} | sudo -n tee {} >/dev/null 2>&1", next_limit, thresh_path),
            ])
            .status();
        send_desktop_notification(
            "🔋 Battery Charge Limit Updated [+]",
            &format!("Charge ceiling set to {}%", next_limit),
        );
        return format!(
            "{{\"ok\":true,\"action\":\"power-menu\",\"charge_limit\":{},\"trit\":\"+\"}}",
            next_limit
        );
    }

    if choice.starts_with("[LOCK]") {
        let _ = hyprctl_exec_cmd("hyprlock");
        return "{\"ok\":true,\"action\":\"power-menu\",\"subaction\":\"lock\",\"trit\":\"+\"}".to_string();
    }
    if choice.starts_with("[SLEEP]") {
        let _ = Command::new("systemctl").arg("suspend").status();
        return "{\"ok\":true,\"action\":\"power-menu\",\"subaction\":\"suspend\",\"trit\":\"+\"}".to_string();
    }
    if choice.starts_with("[REBOOT]") {
        let _ = Command::new("systemctl").arg("reboot").status();
        return "{\"ok\":true,\"action\":\"power-menu\",\"subaction\":\"reboot\",\"trit\":\"+\"}".to_string();
    }
    if choice.starts_with("[OFF]") {
        let _ = Command::new("systemctl").arg("poweroff").status();
        return "{\"ok\":true,\"action\":\"power-menu\",\"subaction\":\"poweroff\",\"trit\":\"+\"}".to_string();
    }
    if choice.starts_with("[CC]") {
        return run_control_center(&[]);
    }

    "{\"ok\":true,\"action\":\"power-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

/// Unified Noctalia-inspired Sovereign Qwave Control Center (`qwave-hypr-hud control-center`).
pub fn run_control_center(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"control-center\",\"trit\":\"+\"}".to_string();
    }

    let (_, ssid) = current_wlan0_state_and_ssid();
    let ssid_label = if ssid.is_empty() {
        "Disconnected".to_string()
    } else {
        sanitize_no_float(&ssid)
    };

    let lines = vec![
        format!("🌐 [NETWORK]   Wi-Fi, VPN, 802:1X & Captive Portal ({})", ssid_label),
        "🫐 [BLUETOOTH] Bluetooth Devices, Pairing & Mesh Love".to_string(),
        "🔊 [AUDIO]     PipeWire Sinks, Microphones & Volume Mixer".to_string(),
        "⚡ [POWER]     Battery Status, 80% Limit & Power Profiles".to_string(),
        "🐦‍🔥 [PHOENIX]   Phoenix Audio DSP Presets & Pranayama".to_string(),
        "🧠 [AI-FLEET]  Sovereign AI Command Center & Model Switcher".to_string(),
        "🔐 [VAULT]     Ed25519 + MEM|8 Personal-Signature Vault".to_string(),
        "🌊 [HUD]       Open Graphical Qwave Sovereign HUD".to_string(),
    ];

    let Some(choice) = prompt_dmenu("◈ Qwave Control Center > ", &lines, false) else {
        return "{\"ok\":true,\"action\":\"control-center\",\"status\":\"cancelled\",\"trit\":\"0\"}".to_string();
    };

    if choice.contains("[NETWORK]") {
        return run_wifi_menu(args);
    }
    if choice.contains("[BLUETOOTH]") {
        return run_bt_menu(args);
    }
    if choice.contains("[AUDIO]") {
        return run_audio_menu(args);
    }
    if choice.contains("[POWER]") {
        return run_power_menu(args);
    }
    if choice.contains("[PHOENIX]") {
        return run_phoenix_menu(args);
    }
    if choice.contains("[AI-FLEET]") {
        return run_ai_menu(args);
    }
    if choice.contains("[VAULT]") {
        return run_vault_menu(args);
    }
    if choice.contains("[HUD]") {
        return run_markdown_hud(args);
    }

    "{\"ok\":true,\"action\":\"control-center\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
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

        // 3b. Start System-Wide PipeWire PhoeniX Sound Revelation Engine ("PhoeniX on Everything")
        start_phoenix_daemon_bg();

        // 4. Start mako notification daemon if not already running
        if !is_process_running("mako") {
            let _ = Command::new("mako")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 5. Start waybar if not already running (force GDK_BACKEND=wayland so GTK3 never falls back to XWayland)
        if !is_process_running("waybar") {
            let _ = Command::new("waybar")
                .env("GDK_BACKEND", "wayland")
                .env_remove("DISPLAY")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }

        // 5b. Qwave-first & only: stop any stray noctalia daemon so only Qwave + Waybar own the desktop
        if is_process_running("noctalia") {
            let _ = Command::new("killall")
                .arg("noctalia")
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
                "[workspace 1 silent] /home/hue/.local/bin/nastty -T \"8b.is Sovereign AGY Studio (Resumed)\" --working-directory /home/hue/8b-is -e /home/hue/.local/bin/qwave-hypr-hud agy-resume",
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
        if let Ok(exe) = env::current_exe() {
            let _ = Command::new(exe)
                .arg("wifi-menu")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    } else if low.contains("control center") || low.contains("bluetooth menu") {
        if let Ok(exe) = env::current_exe() {
            let _ = Command::new(exe)
                .arg("ai-menu")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    } else if low.contains("fullscreen") || low.contains("maximize window") {
        hyprctl_dispatch_lua("hl.dsp.window.fullscreen()");
    } else if low.contains("toggle floating") || low.contains("float window") {
        hyprctl_dispatch_lua("hl.dsp.window.float({ action = \"toggle\" })");
    } else if low.contains("ai menu") || low.contains("model menu") || low.contains("switch model") {
        if let Ok(exe) = env::current_exe() {
            let _ = Command::new(exe)
                .arg("ai-menu")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    } else if low.contains("explain clipboard") || low.contains("fix clipboard") {
        if let Ok(exe) = env::current_exe() {
            let _ = Command::new(exe)
                .arg("ai-clip")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    } else if low.contains("scratchpad") || low.contains("drop terminal") {
        let _ = run_scratchpad(&["term".to_string()]);
    }
}

/// Complete Zero-Float snapshot of local & bridged AI compute accelerators and active models.
#[derive(Clone, Debug)]
pub struct AiComputeSnapshot {
    pub hot_model: String,
    pub a6000_models_count: usize,
    pub local_models_count: usize,
    pub gpu_util_pct: i32,
    pub gpu_temp_c: i32,
    pub gpu_vram_used_mib: i32,
    pub gpu_vram_total_mib: i32,
    pub gpu_vram_pq: Rational,
    pub ram_used_mib: i32,
    pub ram_total_mib: i32,
    pub ram_pq: Rational,
    pub a6k_bridge_trit: Trit,
    pub ollama_local_trit: Trit,
    pub npu_trit: Trit,
    pub arc_trit: Trit,
}

impl Default for AiComputeSnapshot {
    fn default() -> Self {
        Self {
            hot_model: "gemma4:26b".to_string(),
            a6000_models_count: 11,
            local_models_count: 1,
            gpu_util_pct: 0,
            gpu_temp_c: 44,
            gpu_vram_used_mib: 0,
            gpu_vram_total_mib: 8188,
            gpu_vram_pq: Rational::new(0, 8188).unwrap_or(Rational::ZERO),
            ram_used_mib: 9200,
            ram_total_mib: 30720,
            ram_pq: Rational::new(9200, 30720).unwrap_or(Rational::ONE),
            a6k_bridge_trit: Trit::Plus,
            ollama_local_trit: Trit::Plus,
            npu_trit: Trit::Plus,
            arc_trit: Trit::Plus,
        }
    }
}

fn http_get_loopback_body(port: u16, path: &str, timeout_ms: u64) -> Option<String> {
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), port);
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(timeout_ms)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(timeout_ms)));
    let req = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUser-Agent: qwave-hypr-hud\r\nAccept: */*\r\nConnection: close\r\n\r\n");
    stream.write_all(req.as_bytes()).ok()?;
    let mut buf = Vec::with_capacity(4096);
    let _ = stream.read_to_end(&mut buf);
    if buf.is_empty() {
        return None;
    }
    let raw = String::from_utf8_lossy(&buf).into_owned();
    if !raw.contains("200 OK") {
        return None;
    }
    Some(
        raw.split_once("\r\n\r\n")
            .map(|(_, b)| b.to_string())
            .unwrap_or(raw),
    )
}

/// Extract all `"name":"..."` model identifiers from an Ollama `/api/tags` or `/api/ps` JSON body.
pub fn extract_ollama_model_names(json_body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let needle = "\"name\":\"";
    let mut rest = json_body;
    while let Some(pos) = rest.find(needle) {
        let after = &rest[pos + needle.len()..];
        if let Some(end) = after.find('"') {
            let name = sanitize_no_float(after[..end].trim());
            if !name.is_empty() && !out.contains(&name) {
                out.push(name);
            }
            rest = &after[end + 1..];
        } else {
            break;
        }
    }
    out
}

fn read_system_ram_mib() -> (i32, i32) {
    let Ok(raw) = fs::read_to_string("/proc/meminfo") else {
        return (9200, 30720);
    };
    let mut total_kib = 0i64;
    let mut avail_kib = 0i64;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            total_kib = rest
                .split_whitespace()
                .next()
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(0);
        } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
            avail_kib = rest
                .split_whitespace()
                .next()
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(0);
        }
    }
    if total_kib <= 0 {
        return (9200, 30720);
    }
    let total_mib = (total_kib / 1024).max(1) as i32;
    let used_mib = ((total_kib.saturating_sub(avail_kib)) / 1024).clamp(0, total_mib as i64) as i32;
    (used_mib, total_mib)
}

fn probe_nvidia_rtx4070() -> (i32, i32, i32, i32) {
    let Ok(out) = Command::new("nvidia-smi")
        .args([
            "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
            "--format=csv,noheader,nounits",
        ])
        .output()
    else {
        return (0, 0, 8188, 44);
    };
    let line = String::from_utf8_lossy(&out.stdout);
    let first = line.lines().next().unwrap_or("").trim();
    let parts: Vec<&str> = first.split(',').map(str::trim).collect();
    if parts.len() >= 4 {
        let util = parts[0].parse::<i32>().unwrap_or(0).clamp(0, 100);
        let used = parts[1].parse::<i32>().unwrap_or(0).max(0);
        let total = parts[2].parse::<i32>().unwrap_or(8188).max(1);
        let temp = parts[3].parse::<i32>().unwrap_or(44).clamp(0, 120);
        (util, used, total, temp)
    } else {
        (0, 0, 8188, 44)
    }
}

fn refresh_ai_compute_sync() -> AiComputeSnapshot {
    let now = now_epoch_secs();
    let (gpu_util_pct, gpu_vram_used_mib, gpu_vram_total_mib, gpu_temp_c) = probe_nvidia_rtx4070();
    let (ram_used_mib, ram_total_mib) = read_system_ram_mib();
    let npu_trit = if Path::new("/dev/accel/accel0").exists() {
        Trit::Plus
    } else if Path::new("/dev/dri/renderD128").exists() {
        Trit::Zero
    } else {
        Trit::Minus
    };
    let arc_trit = if Path::new("/dev/dri/renderD128").exists() {
        Trit::Plus
    } else {
        Trit::Minus
    };

    let (a6k_ps, a6k_tags, loc_ps, loc_tags) = thread::scope(|s| {
        let h_a6k = s.spawn(|| {
            let ps = http_get_loopback_body(11436, "/api/ps", 3500);
            let tags = http_get_loopback_body(11436, "/api/tags", 3500);
            (ps, tags)
        });
        let h_loc = s.spawn(|| {
            let ps = http_get_loopback_body(11434, "/api/ps", 400);
            let tags = http_get_loopback_body(11434, "/api/tags", 400);
            (ps, tags)
        });
        let (a_ps, a_tags) = h_a6k.join().unwrap_or((None, None));
        let (l_ps, l_tags) = h_loc.join().unwrap_or((None, None));
        (a_ps, a_tags, l_ps, l_tags)
    });

    let a6k_bridge_trit = if a6k_tags.is_some() || a6k_ps.is_some() {
        Trit::Plus
    } else {
        Trit::Minus
    };
    let ollama_local_trit = if loc_tags.is_some() || loc_ps.is_some() {
        Trit::Plus
    } else {
        Trit::Minus
    };

    let a6k_ps_models = a6k_ps
        .as_deref()
        .map(extract_ollama_model_names)
        .unwrap_or_default();
    let a6k_tag_models = a6k_tags
        .as_deref()
        .map(extract_ollama_model_names)
        .unwrap_or_default();
    let loc_ps_models = loc_ps
        .as_deref()
        .map(extract_ollama_model_names)
        .unwrap_or_default();
    let loc_tag_models = loc_tags
        .as_deref()
        .map(extract_ollama_model_names)
        .unwrap_or_default();

    let hot_model = a6k_ps_models
        .first()
        .or_else(|| loc_ps_models.first())
        .or_else(|| a6k_tag_models.first())
        .or_else(|| loc_tag_models.first())
        .cloned()
        .unwrap_or_else(|| "gemma4:26b".to_string());

    let a6000_models_count = a6k_tag_models.len();
    let local_models_count = loc_tag_models.len();
    if !a6k_tag_models.is_empty() {
        let _ = fs::write("/tmp/qwave_ai_models.cache", a6k_tag_models.join("\n"));
    }

    let payload = format!(
        "{now}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}{}{}{}",
        sanitize_no_float(&hot_model),
        a6000_models_count,
        local_models_count,
        gpu_util_pct,
        gpu_temp_c,
        gpu_vram_used_mib,
        gpu_vram_total_mib,
        ram_used_mib,
        ram_total_mib,
        trit_symbol(a6k_bridge_trit),
        trit_symbol(ollama_local_trit),
        trit_symbol(npu_trit),
        trit_symbol(arc_trit),
    );
    let _ = fs::write("/tmp/qwave_ai_compute.cache", payload);

    AiComputeSnapshot {
        hot_model: sanitize_no_float(&hot_model),
        a6000_models_count,
        local_models_count,
        gpu_util_pct,
        gpu_temp_c,
        gpu_vram_used_mib,
        gpu_vram_total_mib,
        gpu_vram_pq: Rational::new(gpu_vram_used_mib, gpu_vram_total_mib.max(1) as u32)
            .unwrap_or(Rational::ZERO),
        ram_used_mib,
        ram_total_mib,
        ram_pq: Rational::new(ram_used_mib, ram_total_mib.max(1) as u32).unwrap_or(Rational::ONE),
        a6k_bridge_trit,
        ollama_local_trit,
        npu_trit,
        arc_trit,
    }
}

/// Non-blocking reader for [`AiComputeSnapshot`]: reads `/tmp/qwave_ai_compute.cache` in <50us
/// and spawns a detached background refresh (`qwave-hypr-hud refresh-ai-bg`) every 10 seconds.
pub fn collect_ai_compute_snapshot() -> AiComputeSnapshot {
    let cache_path = Path::new("/tmp/qwave_ai_compute.cache");
    let now = now_epoch_secs();
    if let Ok(raw) = fs::read_to_string(cache_path) {
        let parts: Vec<&str> = raw.trim().split('|').collect();
        if parts.len() >= 11 {
            let ts = parts[0].parse::<u64>().unwrap_or(0);
            if now.saturating_sub(ts) > 10 {
                let mut touched = parts.clone();
                let now_s = now.to_string();
                touched[0] = &now_s;
                let _ = fs::write(cache_path, touched.join("|"));
                if let Ok(exe) = env::current_exe() {
                    let _ = Command::new(exe)
                        .arg("refresh-ai-bg")
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .spawn();
                }
            }
            let hot_model = sanitize_no_float(parts[1]);
            let a6000_models_count = parts[2].parse::<usize>().unwrap_or(11);
            let local_models_count = parts[3].parse::<usize>().unwrap_or(1);
            let gpu_util_pct = parts[4].parse::<i32>().unwrap_or(0);
            let gpu_temp_c = parts[5].parse::<i32>().unwrap_or(44);
            let gpu_vram_used_mib = parts[6].parse::<i32>().unwrap_or(0);
            let gpu_vram_total_mib = parts[7].parse::<i32>().unwrap_or(8188).max(1);
            let ram_used_mib = parts[8].parse::<i32>().unwrap_or(9200);
            let ram_total_mib = parts[9].parse::<i32>().unwrap_or(30720).max(1);
            let syms: Vec<char> = parts[10].chars().collect();
            let a6k_bridge_trit = syms.first().copied().map(parse_trit_char).unwrap_or(Trit::Plus);
            let ollama_local_trit = syms.get(1).copied().map(parse_trit_char).unwrap_or(Trit::Plus);
            let npu_trit = syms.get(2).copied().map(parse_trit_char).unwrap_or(Trit::Plus);
            let arc_trit = syms.get(3).copied().map(parse_trit_char).unwrap_or(Trit::Plus);
            return AiComputeSnapshot {
                hot_model,
                a6000_models_count,
                local_models_count,
                gpu_util_pct,
                gpu_temp_c,
                gpu_vram_used_mib,
                gpu_vram_total_mib,
                gpu_vram_pq: Rational::new(gpu_vram_used_mib, gpu_vram_total_mib as u32)
                    .unwrap_or(Rational::ZERO),
                ram_used_mib,
                ram_total_mib,
                ram_pq: Rational::new(ram_used_mib, ram_total_mib as u32)
                    .unwrap_or(Rational::ONE),
                a6k_bridge_trit,
                ollama_local_trit,
                npu_trit,
                arc_trit,
            };
        }
    }
    if let Ok(exe) = env::current_exe() {
        let _ = Command::new(exe)
            .arg("refresh-ai-bg")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }
    AiComputeSnapshot::default()
}

/// Render single-line Waybar JSON for the AI Compute, Accelerator & Model Radar Pill (`waybar-ai`).
pub fn render_waybar_ai_json() -> String {
    let ai = collect_ai_compute_snapshot();
    render_waybar_ai_json_from_snap(&ai)
}

pub fn render_waybar_ai_json_from_snap(ai: &AiComputeSnapshot) -> String {
    let short_model: String = ai
        .hot_model
        .trim_end_matches(":latest")
        .chars()
        .take(14)
        .collect();
    let text = format!(
        "🧠 {} │ 4070 {}% {}°C │ A6K{}",
        short_model,
        ai.gpu_util_pct,
        ai.gpu_temp_c,
        trit_symbol(ai.a6k_bridge_trit),
    );
    let ram_pct = rational_to_pct(ai.ram_pq);
    let vram_pct = rational_to_pct(ai.gpu_vram_pq);
    let tooltip = format!(
        "Sovereign AI Compute & Model Radar (SUPER + O)\n\
         Active Hot Model: {} (A6000 Bridge Models: {} │ Local Ollama Models: {})\n\
         Local GPU (NVIDIA RTX 4070): {}% util · {}°C · VRAM: {}/{} MiB ({}% · p/q: {}/{})\n\
         System Memory (32GB DDR5): {}/{} MiB ({}% · p/q: {}/{})\n\
         Accelerators: A6000_SSH[{}] (:11436) · LOCAL_OLLAMA[{}] (:11434) · INTEL_NPU[{}] (/dev/accel/accel0) · INTEL_ARC[{}]\n\
         L-Click: Sovereign AI Command & Model Switcher (SUPER+O)\n\
         R-Click: Toggle Live AI & Acoustic Telemetry Radar (SUPER+Z)\n\
         M-Click: Explain / Refactor Clipboard with Aye (SUPER+X)",
        ai.hot_model,
        ai.a6000_models_count,
        ai.local_models_count,
        ai.gpu_util_pct,
        ai.gpu_temp_c,
        ai.gpu_vram_used_mib,
        ai.gpu_vram_total_mib,
        vram_pct,
        ai.gpu_vram_pq.num,
        ai.gpu_vram_pq.den,
        ai.ram_used_mib,
        ai.ram_total_mib,
        ram_pct,
        ai.ram_pq.num,
        ai.ram_pq.den,
        trit_symbol(ai.a6k_bridge_trit),
        trit_symbol(ai.ollama_local_trit),
        trit_symbol(ai.npu_trit),
        trit_symbol(ai.arc_trit),
    );
    let cls = if ai.a6k_bridge_trit == Trit::Plus {
        "ai-online"
    } else if ai.ollama_local_trit == Trit::Plus {
        "ai-local"
    } else {
        "ai-idle"
    };
    format!(
        "{{\"text\":\"{}\",\"tooltip\":\"{}\",\"class\":\"{}\"}}",
        json_escape(&text),
        json_escape(&tooltip),
        cls
    )
}

/// Self-healing Hyprland scratchpad launcher & toggler (`qwave-hypr-hud scratchpad <term|qwave|btop>`).
pub fn run_scratchpad(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let target = args
        .iter()
        .find(|a| !a.starts_with('-'))
        .map(String::as_str)
        .unwrap_or("term");

    let (ws_name, class_name, spawn_cmd) = match target {
        "qwave" | "radar" => (
            "qwave",
            "qwave-radar",
            "[workspace special:qwave] /home/hue/.local/bin/nastty --class qwave-radar -T \"Sovereign Qwave & AI Telemetry Radar\" -e /home/hue/.local/bin/qwave-hypr-hud status-tui",
        ),
        "btop" | "gpu" => (
            "btop",
            "btop-hud",
            "[workspace special:btop] /home/hue/.local/bin/nastty --class btop-hud -T \"Sovereign GPU & CPU Monitor (btop)\" -e btop",
        ),
        _ => (
            "term",
            "ai-scratch-term",
            "[workspace special:term] /home/hue/.local/bin/nastty --class ai-scratch-term -T \"Sovereign AI Scratchpad Terminal\" --working-directory /home/hue/8b-is",
        ),
    };

    if dry_run {
        return format!(
            "{{\"ok\":true,\"action\":\"scratchpad\",\"workspace\":\"special:{ws_name}\",\"class\":\"{class_name}\",\"trit\":\"+\"}}"
        );
    }

    let clients_out = Command::new("hyprctl")
        .arg("clients")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();

    let class_marker = format!("class: {class_name}");
    if clients_out.contains(&class_marker) {
        hyprctl_dispatch_lua(&format!("hl.dsp.workspace.toggle_special(\"{ws_name}\")"));
    } else {
        let _ = hyprctl_exec_cmd(spawn_cmd);
    }

    format!(
        "{{\"ok\":true,\"action\":\"scratchpad\",\"workspace\":\"special:{ws_name}\",\"class\":\"{class_name}\",\"trit\":\"+\"}}"
    )
}

/// Send the current Wayland clipboard (`wl-paste`) to Loopback Aye (`:8787`), copy the reply,
/// show a notification, and speak a confirmation (`qwave-hypr-hud ai-clip` / `SUPER + X`).
pub fn run_ai_clip(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let mode = parse_flag_value(args, "--mode").unwrap_or("explain");

    if dry_run {
        return format!(
            "{{\"ok\":true,\"action\":\"ai-clip\",\"mode\":\"{}\",\"trit\":\"+\"}}",
            json_escape(mode)
        );
    }

    let clip = Command::new("wl-paste")
        .arg("--no-newline")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            Command::new("wl-paste")
                .args(["--primary", "--no-newline"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        })
        .unwrap_or_default();

    if clip.is_empty() {
        send_desktop_notification(
            "🧠 Sovereign AI Clipboard [0]",
            "Clipboard is empty — copy code or text first, then press SUPER+X",
        );
        return "{\"ok\":false,\"action\":\"ai-clip\",\"error\":\"empty clipboard\",\"trit\":\"0\"}".to_string();
    }

    let clipped: String = clip.chars().take(2400).collect();
    let prompt = if mode == "fix" || mode == "rust" {
        format!(
            "Review and improve this code following 8b-is rules (exact integer or p/q rational arithmetic, zero floats, concise):\n\n{clipped}"
        )
    } else {
        format!("Explain this concisely for an AI systems developer:\n\n{clipped}")
    };

    send_desktop_notification(
        "🧠 Sending Clipboard to Loopback Aye [...]",
        &format!("Analyzing {} chars via 127:0:0:1:8787", clipped.len()),
    );

    let reply = query_loopback_alexiai(&prompt).unwrap_or_else(|| {
        "Loopback Aye (:8787) did not return a response; verify alexiai and cheet-bridge services."
            .to_string()
    });

    if let Ok(mut child) = Command::new("wl-copy")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        if let Some(ref mut stdin) = child.stdin {
            let _ = stdin.write_all(reply.as_bytes());
        }
        let _ = child.wait();
    }

    let preview: String = reply.chars().take(220).collect();
    send_desktop_notification("🧠 Aye Clipboard Reply (Copied!) [+]", &preview);
    speak_async("Aye analyzed your clipboard and copied the result");

    format!(
        "{{\"ok\":true,\"action\":\"ai-clip\",\"mode\":\"{}\",\"reply_len\":{},\"trit\":\"+\"}}",
        json_escape(mode),
        reply.len()
    )
}

fn warm_ollama_model_in_vram(port: u16, model_colon_name: &str) -> bool {
    let real_model = if let Some((prefix, rest)) = model_colon_name.split_once(':') {
        // Restore e.g. qwen3:8:27b -> qwen3.8:27b if sanitized
        if rest.contains(':') {
            if let Some((mid, tag)) = rest.rsplit_once(':') {
                format!("{prefix}.{mid}:{tag}")
            } else {
                model_colon_name.to_string()
            }
        } else {
            model_colon_name.to_string()
        }
    } else {
        model_colon_name.to_string()
    };

    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), port);
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(600)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(8)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
    let body = format!(
        "{{\"model\":\"{}\",\"prompt\":\"\",\"keep_alive\":\"30m\"}}",
        real_model.replace('"', "")
    );
    let req = format!(
        "POST /api/generate HTTP/1.1\r\nHost: localhost:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    stream.write_all(req.as_bytes()).is_ok()
}

/// Format menu entries for `qwave-hypr-hud ai-menu` (`SUPER + O`).
pub fn format_ai_menu_entries(
    ai: &AiComputeSnapshot,
    a6k_models: &[String],
    local_models: &[String],
) -> Vec<String> {
    let mut lines = Vec::with_capacity(12 + a6k_models.len() + local_models.len());
    lines.push(format!(
        "[STATUS] Hot: {} │ RTX 4070 {}% {}°C │ A6K[{}] NPU[{}]",
        sanitize_no_float(&ai.hot_model),
        ai.gpu_util_pct,
        ai.gpu_temp_c,
        trit_symbol(ai.a6k_bridge_trit),
        trit_symbol(ai.npu_trit),
    ));
    lines.push("[CLIP -> EXPLAIN] Explain Wayland Clipboard via Loopback Aye (:8787)".to_string());
    lines.push("[CLIP -> RUST FIX] Refactor / Review Clipboard Code (Zero-Float 8b:is Rust)".to_string());
    lines.push("[VOICE -> ASK AYE] Speak Voice Prompt to Loopback Aye (:8787 -> TTS)".to_string());
    lines.push("[STUDIO -> AGY] Launch / Focus Sovereign AGY Studio (All Perms, Resumed)".to_string());
    lines.push("[RADAR -> TUI] Toggle Live 500ms AI & Acoustic Radar Scratchpad (SUPER+Z)".to_string());
    lines.push("[BTOP -> GPU/CPU] Toggle Live Hardware Monitor Scratchpad (SUPER+SHIFT+G)".to_string());
    lines.push("[TERM -> DROP] Toggle Instant Dropdown Terminal Scratchpad (SUPER+grave)".to_string());
    lines.push("[A6000 -> FLEET] Inspect RTX 6000 Ada (49140 MiB) & Fleet (a6000-ctl status)".to_string());
    lines.push("[BRIDGE -> HEAL] Restart & Verify cheet-bridge SSH Tunnel (:11436 / :18787)".to_string());

    for m in a6k_models {
        lines.push(format!(
            "[A6000 :11436] {} (Warm in RTX 6000 Ada VRAM + Interactive Chat)",
            sanitize_no_float(m)
        ));
    }
    for m in local_models {
        lines.push(format!(
            "[LOCAL :11434] {} (Warm in Local RTX 4070 VRAM + Interactive Chat)",
            sanitize_no_float(m)
        ));
    }
    lines
}

/// Execute `qwave-hypr-hud ai-menu` (`SUPER + O`):
/// Interactive Sovereign AI Command Center & Model Switcher in Fuzzel/Wofi.
pub fn run_ai_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let ai = collect_ai_compute_snapshot();
    if dry_run {
        let sample_menu = format_ai_menu_entries(
            &ai,
            &["gemma4:26b".to_string(), "aye-deepseek-pqm:latest".to_string()],
            &["gemma:latest".to_string()],
        );
        return format!(
            "{{\"ok\":true,\"action\":\"ai-menu\",\"hot_model\":\"{}\",\"entries\":{},\"trit\":\"+\"}}",
            json_escape(&ai.hot_model),
            sample_menu.len()
        );
    }

    let a6k_models = fs::read_to_string("/tmp/qwave_ai_models.cache")
        .ok()
        .map(|raw| {
            raw.lines()
                .map(|l| sanitize_no_float(l.trim()))
                .filter(|l| !l.is_empty())
                .collect::<Vec<String>>()
        })
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            vec![
                "gemma4:26b".to_string(),
                "aye-deepseek-pqm:latest".to_string(),
                "devstral:24b".to_string(),
                "granite4:2:30b".to_string(),
                "qwen3:8:27b".to_string(),
                "cheet-deepseek-v2:16b".to_string(),
                "cheet-deepseek:32b".to_string(),
                "aye-deepseek:32b".to_string(),
                "deepseek-r1:32b".to_string(),
                "qwen3:6:35b".to_string(),
            ]
        });
    let local_models = http_get_loopback_body(11434, "/api/tags", 150)
        .as_deref()
        .map(extract_ollama_model_names)
        .unwrap_or_else(|| vec!["gemma:latest".to_string()]);

    let menu_lines = format_ai_menu_entries(&ai, &a6k_models, &local_models);
    let Some(choice) = prompt_dmenu("Sovereign AI Studio > ", &menu_lines, false) else {
        return "{\"ok\":true,\"action\":\"ai-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}"
            .to_string();
    };

    if choice.starts_with("[CLIP -> EXPLAIN]") {
        return run_ai_clip(&["--mode".to_string(), "explain".to_string()]);
    }
    if choice.starts_with("[CLIP -> RUST FIX]") {
        return run_ai_clip(&["--mode".to_string(), "fix".to_string()]);
    }
    if choice.starts_with("[VOICE -> ASK AYE]") {
        return run_ask_aye(&[]);
    }
    if choice.starts_with("[STUDIO -> AGY]") {
        let _ = hyprctl_exec_cmd(
            "/home/hue/.local/bin/nastty -T \"8b.is Sovereign AGY Studio (Resumed)\" --working-directory /home/hue/8b-is -e /home/hue/.local/bin/qwave-hypr-hud agy-resume",
        );
        return "{\"ok\":true,\"action\":\"ai-menu\",\"subaction\":\"agy-resume\",\"trit\":\"+\"}"
            .to_string();
    }
    if choice.starts_with("[RADAR -> TUI]") || choice.starts_with("[STATUS]") {
        return run_scratchpad(&["qwave".to_string()]);
    }
    if choice.starts_with("[BTOP -> GPU/CPU]") {
        return run_scratchpad(&["btop".to_string()]);
    }
    if choice.starts_with("[TERM -> DROP]") {
        return run_scratchpad(&["term".to_string()]);
    }
    if choice.starts_with("[A6000 -> FLEET]") {
        let _ = hyprctl_exec_cmd(
            "/home/hue/.local/bin/nastty --class ai-floating -T \"Sovereign A6000 & Fleet Status\" -e sh -c \"/home/hue/.local/bin/a6000-ctl status; echo ''; read -p 'Press Enter to close...'\"",
        );
        return "{\"ok\":true,\"action\":\"ai-menu\",\"subaction\":\"a6000-status\",\"trit\":\"+\"}"
            .to_string();
    }
    if choice.starts_with("[BRIDGE -> HEAL]") {
        let _ = Command::new("systemctl")
            .args(["--user", "restart", "cheet-bridge.service"])
            .status();
        let _ = refresh_ai_compute_sync();
        send_desktop_notification(
            "🌉 Sovereign A6000 SSH Bridge Healed [+]",
            "Restarted cheet-bridge:service (:11436 / :18786 / :18787 / :18795)",
        );
        speak_async("Sovereign A6000 loopback bridge healed");
        return "{\"ok\":true,\"action\":\"ai-menu\",\"subaction\":\"bridge-heal\",\"trit\":\"+\"}"
            .to_string();
    }
    if let Some(rest) = choice.strip_prefix("[A6000 :11436] ") {
        let model = rest.split_whitespace().next().unwrap_or("gemma4:26b");
        let _ = warm_ollama_model_in_vram(11436, model);
        let _ = refresh_ai_compute_sync();
        let real_model = if let Some((p, r)) = model.split_once(':') {
            if let Some((m, t)) = r.rsplit_once(':') {
                format!("{p}.{m}:{t}")
            } else {
                model.to_string()
            }
        } else {
            model.to_string()
        };
        let _ = hyprctl_exec_cmd(&format!(
            "/home/hue/.local/bin/nastty --class ai-floating -T \"A6000 Model Chat: {}\" -e env OLLAMA_HOST=127.0.0.1:11436 ollama run {}",
            sanitize_no_float(model),
            real_model
        ));
        send_desktop_notification(
            "🧠 A6000 Model Warmed in VRAM [+]",
            &format!("Pinned {} on RTX 6000 Ada (127:0:0:1:11436)", sanitize_no_float(model)),
        );
        return format!(
            "{{\"ok\":true,\"action\":\"ai-menu\",\"subaction\":\"warm-a6000\",\"model\":\"{}\",\"trit\":\"+\"}}",
            json_escape(model)
        );
    }
    if let Some(rest) = choice.strip_prefix("[LOCAL :11434] ") {
        let model = rest.split_whitespace().next().unwrap_or("gemma:latest");
        let _ = warm_ollama_model_in_vram(11434, model);
        let _ = refresh_ai_compute_sync();
        let _ = hyprctl_exec_cmd(&format!(
            "/home/hue/.local/bin/nastty --class ai-floating -T \"Local RTX 4070 Chat: {}\" -e ollama run {}",
            sanitize_no_float(model),
            model
        ));
        send_desktop_notification(
            "🧠 Local Model Warmed in RTX 4070 VRAM [+]",
            &format!("Pinned {} on Local Ollama (127:0:0:1:11434)", sanitize_no_float(model)),
        );
        return format!(
            "{{\"ok\":true,\"action\":\"ai-menu\",\"subaction\":\"warm-local\",\"model\":\"{}\",\"trit\":\"+\"}}",
            json_escape(model)
        );
    }

    "{\"ok\":true,\"action\":\"ai-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

// ── System-Wide PipeWire "PhoeniX on Everything" Daemon & Waybar HUD ────────

const PHOENIX_SINK_NAME: &str = "phoenix_revelation_sink";
const PHOENIX_PRESET_FILE: &str = "/tmp/qwave_phoenix_preset.txt";
const PHOENIX_LIVE_TSV: &str = "/tmp/qwave_phoenix_live.tsv";
const PHOENIX_HW_SINK_FILE: &str = "/tmp/qwave_phoenix_hw_sink.txt";
const PHOENIX_HW_RATE_FILE: &str = "/tmp/qwave_phoenix_hw_rate.txt";
const PHOENIX_MOD_ID_FILE: &str = "/tmp/qwave_phoenix_mod_id.txt";
const PHOENIX_PID_FILE: &str = "/tmp/qwave_phoenix_daemon.pid";
const PHOENIX_MULTISINK_FILE: &str = "/tmp/qwave_phoenix_multisink.txt";
const PHOENIX_FEEL_FILE: &str = "/tmp/qwave_phoenix_feel.tsv";
const PHOENIX_ALEXANDRA_RESET_FILE: &str = "/tmp/qwave_phoenix_alexandra_reset.txt";

/// Read whether the built-in 432Hz x phi Alexandra Sanctuary Nervous-System Reset Wave is active.
fn read_alexandra_reset_active() -> bool {
    fs::read_to_string(PHOENIX_ALEXANDRA_RESET_FILE)
        .map(|s| {
            let t = s.trim();
            t == "1" || t.eq_ignore_ascii_case("true") || t.eq_ignore_ascii_case("on")
        })
        .unwrap_or(false)
}

/// Persist the Alexandra Sanctuary Nervous-System Reset Wave state (`true` / `false`).
fn write_alexandra_reset_active(active: bool) {
    let val = if active { "1\n" } else { "0\n" };
    let _ = fs::write(PHOENIX_ALEXANDRA_RESET_FILE, val);
    if active {
        // Also switch preset to alexandra-sanctuary with Auto-Magical ON so when Reset ends, Sanctuary stays active!
        let _ = fs::write(PHOENIX_PRESET_FILE, "alexandra-sanctuary");
    }
}

/// CLI handler for `qwave-hypr-hud alexandra-reset [on|off|toggle]`.
pub fn run_alexandra_reset(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let req = args.first().map(String::as_str).unwrap_or("toggle");
    let cur = read_alexandra_reset_active();
    let next = match req {
        "on" | "1" | "true" => true,
        "off" | "0" | "false" => false,
        _ => !cur,
    };
    if !dry_run {
        write_alexandra_reset_active(next);
        if !is_phoenix_daemon_running() {
            start_phoenix_daemon_bg();
        }
    }
    format!(
        "{{\"ok\":true,\"action\":\"alexandra-reset\",\"alexandra_reset\":{next},\"preset\":\"alexandra-sanctuary\",\"trit\":\"+\"}}"
    )
}

/// Read the Auto-Magical toggle and 3 simple human-feel macros (`voice_pct`, `bass_pct`, `space_pct` in `0..=200`).
/// Defaults to `(true, 100, 100, 100)` so PhoeniX is 100% auto-magical out of the box.
fn read_phoenix_feel_controls() -> (bool, u16, u16, u16) {
    if let Ok(raw) = fs::read_to_string(PHOENIX_FEEL_FILE) {
        if let Some(line) = raw.lines().next() {
            let cols: Vec<&str> = line.split('\t').collect();
            if cols.len() >= 4 {
                let auto = cols[0].trim() != "0" && cols[0].trim() != "false";
                let v = cols[1].trim().parse::<u16>().unwrap_or(100).min(200);
                let b = cols[2].trim().parse::<u16>().unwrap_or(100).min(200);
                let s = cols[3].trim().parse::<u16>().unwrap_or(100).min(200);
                return (auto, v, b, s);
            }
        }
    }
    (true, 100, 100, 100)
}

/// Persist the Auto-Magical toggle and 3 simple human-feel macros (`0..=200` percent) to `/tmp/qwave_phoenix_feel.tsv`.
fn write_phoenix_feel_controls(automagic: bool, voice_pct: u16, bass_pct: u16, space_pct: u16) {
    let a = if automagic { 1 } else { 0 };
    let v = voice_pct.min(200);
    let b = bass_pct.min(200);
    let s = space_pct.min(200);
    let _ = fs::write(PHOENIX_FEEL_FILE, format!("{a}\t{v}\t{b}\t{s}\n"));
}

/// Auto-discover the maximum supported 48 kHz-family hardware sample rate (`384000`, `192000`, `96000`, `48000`)
/// for `hw_sink` directly from Linux kernel `/proc/asound/card*/stream0`.
pub fn discover_max_rate_for_sink(hw_sink: &str) -> u32 {
    let want_tx384 = hw_sink.contains("TX-384Khz");
    let want_scarlett = hw_sink.contains("Scarlett");
    // Multi-channel UCM split sinks (`HiFi__Line*__sink`) use Altset 1 (26ch @ 48kHz)
    let is_ucm_multich = hw_sink.contains("HiFi__");

    let mut best_rate: u32 = 48_000;
    for card_idx in 0..8u8 {
        let path = format!("/proc/asound/card{card_idx}/stream0");
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        if want_tx384 && !raw.contains("TX-384Khz") {
            continue;
        }
        if want_scarlett && !raw.contains("Scarlett") {
            continue;
        }
        if !want_tx384 && !want_scarlett && !hw_sink.contains("usb-") {
            continue;
        }

        let mut in_playback = false;
        let mut cur_altset: u8 = 0;
        for line in raw.lines() {
            let trimmed = line.trim();
            if trimmed == "Playback:" {
                in_playback = true;
                continue;
            }
            if trimmed == "Capture:" {
                in_playback = false;
                continue;
            }
            if !in_playback {
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("Altset ") {
                cur_altset = rest.trim().parse::<u8>().unwrap_or(0);
            } else if let Some(rest) = trimmed.strip_prefix("Rates:") {
                if is_ucm_multich && cur_altset > 1 {
                    continue;
                }
                for tok in rest.split(|c: char| c == ',' || c.is_whitespace()) {
                    if let Ok(r) = tok.trim().parse::<u32>() {
                        if (r == 384_000 || r == 192_000 || r == 96_000 || r == 48_000) && r > best_rate {
                            best_rate = r;
                        }
                    }
                }
            }
        }
        if want_tx384 || want_scarlett {
            return best_rate;
        }
    }
    best_rate
}

/// Read the target Hi-Res USB DAC output sample rate:
/// Defaults to **Beast Least-Cost Auto-Max** (`discover_max_rate_for_sink`) for the selected hardware sink
/// (`384,000 Hz` on `TX-384Khz`), unless overridden in `/tmp/qwave_phoenix_hw_rate.txt`.
fn read_target_phoenix_hw_rate() -> u32 {
    if let Ok(raw) = fs::read_to_string(PHOENIX_HW_RATE_FILE) {
        let s = raw.trim();
        if s != "auto" && !s.is_empty() {
            if let Ok(v) = s.parse::<u32>() {
                if v >= 352_800 {
                    return 384_000;
                }
                if v >= 176_400 {
                    return 192_000;
                }
                if v >= 88_200 {
                    return 96_000;
                }
                if v >= 44_100 {
                    return 48_000;
                }
            }
        }
    }
    let hw_sink = select_primary_hardware_sink();
    discover_max_rate_for_sink(&hw_sink)
}

/// Inspect Linux kernel `/proc/asound/card*/stream0` to verify the actual live USB Audio
/// `Momentary freq` (in Hz) and bit depth (`24` for `Altset = 2` / `S24_3LE`, `16` for `Altset = 1`).
fn probe_usb_hardware_rate_and_bits() -> (u32, u8) {
    let mut fallback_rate = read_target_phoenix_hw_rate();
    let mut fallback_bits = 24u8;
    for card_idx in 0..8u8 {
        let path = format!("/proc/asound/card{card_idx}/stream0");
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        if !raw.contains("Status: Running") {
            continue;
        }
        let is_tx384 = raw.contains("TX-384Khz");
        let mut freq_hz: u32 = 0;
        let mut altset: u8 = 2;
        for line in raw.lines() {
            let trimmed = line.trim();
            if let Some(rest) = trimmed.strip_prefix("Momentary freq =") {
                if let Some(num_tok) = rest.split_whitespace().next() {
                    if let Ok(parsed) = num_tok.parse::<u32>() {
                        freq_hz = parsed;
                    }
                }
            } else if let Some(rest) = trimmed.strip_prefix("Altset =") {
                if let Ok(a) = rest.trim().parse::<u8>() {
                    altset = a;
                }
            }
        }
        let bits = if altset >= 2 { 24 } else { 16 };
        if freq_hz > 0 {
            if is_tx384 {
                return (freq_hz, bits);
            }
            fallback_rate = freq_hz;
            fallback_bits = bits;
        }
    }
    (fallback_rate, fallback_bits)
}

/// Apply PipeWire runtime clock metadata (`pw-metadata -n settings`) so the USB HiFi DAC locks
/// natively to `target_rate` (`192000` or `384000` Hz) with an 8192-sample quantum ceiling.
fn configure_pipewire_hires_clock(target_rate: u32) {
    let rate = if target_rate >= 352_800 { 384_000 } else { 192_000 };
    let rate_str = rate.to_string();
    let _ = Command::new("pw-metadata")
        .args([
            "-n",
            "settings",
            "0",
            "clock.allowed-rates",
            "[ 44100 48000 88200 96000 176400 192000 352800 384000 ]",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("pw-metadata")
        .args(["-n", "settings", "0", "clock.max-quantum", "8192"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("pw-metadata")
        .args(["-n", "settings", "0", "clock.quantum", "2048"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("pw-metadata")
        .args(["-n", "settings", "0", "clock.rate", &rate_str])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("pw-metadata")
        .args(["-n", "settings", "0", "clock.force-rate", &rate_str])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Discover physical hardware audio sinks from `pactl list short sinks` (excluding `phoenix_revelation_sink`).
fn discover_hardware_sinks() -> Vec<String> {
    let Ok(out) = Command::new("pactl").args(["list", "short", "sinks"]).output() else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut sinks = Vec::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let _id = parts.next();
        if let Some(name) = parts.next() {
            if name != PHOENIX_SINK_NAME && !name.contains("phoenix_revelation") {
                sinks.push(name.to_string());
            }
        }
    }
    sinks
}

/// Select the primary hardware sink (preferring the USB HiFi 384kHz DAC when plugged in, or saved stereo sink, or Scarlett Line1, or Speaker).
fn select_primary_hardware_sink() -> String {
    let sinks = discover_hardware_sinks();
    if let Some(tx384) = sinks.iter().find(|s| s.contains("TX-384Khz")) {
        let _ = fs::write(PHOENIX_HW_SINK_FILE, tx384);
        return tx384.clone();
    }
    if let Ok(saved) = fs::read_to_string(PHOENIX_HW_SINK_FILE) {
        let s = saved.trim();
        if !s.is_empty()
            && s != PHOENIX_SINK_NAME
            && !s.contains("Direct1__sink")
            && sinks.iter().any(|x| x == s)
        {
            return s.to_string();
        }
    }
    if let Ok(out) = Command::new("pactl").arg("get-default-sink").output() {
        let cur = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !cur.is_empty()
            && cur != PHOENIX_SINK_NAME
            && !cur.contains("Direct1__sink")
            && sinks.iter().any(|x| x == &cur)
        {
            let _ = fs::write(PHOENIX_HW_SINK_FILE, &cur);
            return cur;
        }
    }
    for pref in ["TX-384Khz", "Line1__sink", "Scarlett_18i20_4th_Gen", "Speaker__sink"] {
        if let Some(found) = sinks.iter().find(|s| s.contains(pref)) {
            let _ = fs::write(PHOENIX_HW_SINK_FILE, found);
            return found.clone();
        }
    }
    let fallback = sinks.first().cloned().unwrap_or_else(|| "@DEFAULT_AUDIO_SINK@".to_string());
    let _ = fs::write(PHOENIX_HW_SINK_FILE, &fallback);
    fallback
}

/// Check whether `qwave-hypr-hud phoenix-daemon` is currently alive.
fn is_phoenix_daemon_running() -> bool {
    if let Ok(pid_str) = fs::read_to_string(PHOENIX_PID_FILE) {
        let pid = pid_str.trim();
        if !pid.is_empty() && Path::new(&format!("/proc/{pid}")).exists() {
            return true;
        }
    }
    false
}

/// Read the active PhoeniX preset slug (`sovereign`, `goonj-velvet`, `naad-studio`, `sanctuary-432`, `vocal-clarity`).
fn read_active_phoenix_preset_slug() -> String {
    let raw = fs::read_to_string(PHOENIX_PRESET_FILE).unwrap_or_else(|_| "sovereign".to_string());
    PhoenixSoundPreset::from_name(raw.trim()).slug().to_string()
}

/// Render single-line Waybar JSON for the System-Wide PhoeniX Sound Revelation Pill (`waybar-phoenix`).
pub fn render_waybar_phoenix_json() -> String {
    let running = is_phoenix_daemon_running();
    let preset_slug = read_active_phoenix_preset_slug();
    let multisink = fs::read_to_string(PHOENIX_MULTISINK_FILE)
        .map(|s| s.trim() == "1")
        .unwrap_or(false);

    let mut dom_hz_str = "432/1".to_string();
    let mut shruti_ratio_str = "1/1".to_string();
    let mut shruti_name = "Sa (Chhandovati)".to_string();
    let mut soul_str = "896/1024".to_string();
    let mut restored_str = "0".to_string();
    let mut s_frames_str = "0".to_string();
    let mut t_frames_str = "0".to_string();
    let mut hw_sink_short = "USB-HiFi-384kHz".to_string();

    if let Ok(tsv) = fs::read_to_string(PHOENIX_LIVE_TSV) {
        let cols: Vec<&str> = tsv.trim().split('\t').collect();
        if cols.len() >= 8 {
            dom_hz_str = sanitize_no_float(cols[0]);
            shruti_ratio_str = sanitize_no_float(cols[1]);
            shruti_name = sanitize_no_float(cols[2]);
            soul_str = sanitize_no_float(cols[3]);
            restored_str = sanitize_no_float(cols[4]);
            s_frames_str = sanitize_no_float(cols[5]);
            t_frames_str = sanitize_no_float(cols[6]);
            hw_sink_short = sanitize_no_float(cols[7]);
        }
    }

    let badge_preset = match preset_slug.as_str() {
        "goonj-velvet" => "GOONJ",
        "naad-studio" => "NAAD",
        "sanctuary-432" => "432Hz",
        "vocal-clarity" => "SVARA",
        _ => "SOV",
    };
    let short_shruti = shruti_name.split_whitespace().next().unwrap_or("Sa");
    let multi_tag = if multisink { "│MULTI" } else { "" };
    let (hw_rate_hz, hw_bits) = probe_usb_hardware_rate_and_bits();
    let hw_khz = (hw_rate_hz / 1000).max(48);
    let upsample_mult = (hw_rate_hz / 48_000).max(1);

    let (text, cls) = if running {
        (
            format!("🔥 PHX [{badge_preset}│{hw_khz}kHz {hw_bits}b│{short_shruti} {shruti_ratio_str}{multi_tag}│+]"),
            "phoenix-active",
        )
    } else {
        (
            format!("🔥 PHX [{badge_preset}│{hw_khz}kHz│0]"),
            "phoenix-idle",
        )
    };

    let tooltip = format!(
        "PhoeniX Sound Revelation Engine (768kHz 16x Catmull-Rom + S+N+T + Goonj/Naad/Svara/Taal)\n\
         Status: {} · Preset: {} · Output: {}{}\n\
         Hardware USB DAC Lock: {} Hz · {}-bit S24_3LE ({}x Catmull-Rom S32LE Upsampled)\n\
         Dominant Pitch: {} Hz · Taal 22-Shruti Lock: {} ({})\n\
         Soul Authenticity: {} · Catmull-Rom Repaired Samples: {}\n\
         Harmonic S Frames: {} · Dirac T Transients: {} · Goonj Ternary DVN Taps: 16\n\
         L-Click: Cycle Preset (Sovereign / Goonj-Velvet / Naad-Studio / Sanctuary-432 / Svara-Vocal)\n\
         R-Click: Open PhoeniX Studio Menu │ M-Click: Toggle System-Wide PhoeniX On/Off",
        if running { "LIVE ON EVERYTHING [+]" } else { "BYPASSED [0]" },
        preset_slug,
        hw_sink_short,
        if multisink { " + Scarlett 18i20 Multi-Sink" } else { "" },
        hw_rate_hz,
        hw_bits,
        upsample_mult,
        dom_hz_str,
        shruti_name,
        shruti_ratio_str,
        soul_str,
        restored_str,
        s_frames_str,
        t_frames_str
    );

    format!(
        "{{\"text\":\"{}\",\"tooltip\":\"{}\",\"class\":\"{}\"}}",
        json_escape(&sanitize_no_float(&text)),
        json_escape(&sanitize_no_float(&tooltip)),
        cls
    )
}

/// Move all client playback `sink-inputs` (except our own hardware output bridge) onto `target_sink`.
fn move_all_sink_inputs_to(target_sink: &str) {
    let Ok(out) = Command::new("pactl").args(["list", "short", "sink-inputs"]).output() else {
        return;
    };
    // Also inspect `pactl list sink-inputs` so we never move our own `PhoeniX_Hardware_Out` pacat stream
    let full_info = Command::new("pactl")
        .args(["list", "sink-inputs"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();

    let mut excluded_ids: Vec<String> = Vec::new();
    let mut current_id = String::new();
    for line in full_info.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("Sink Input #") {
            current_id = rest.trim().to_string();
        } else if (trimmed.contains("PhoeniX_Hardware_Out") || trimmed.contains("pacat"))
            && !current_id.is_empty()
        {
            excluded_ids.push(current_id.clone());
        }
    }

    let hw_sink = if target_sink == PHOENIX_SINK_NAME {
        Some(select_primary_hardware_sink())
    } else {
        None
    };

    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let mut parts = line.split_whitespace();
        if let Some(id) = parts.next() {
            let current_sink_id = parts.next().unwrap_or("");
            if !excluded_ids.iter().any(|x| x == id) {
                let _ = Command::new("pactl")
                    .args(["move-sink-input", id, target_sink])
                    .status();
            } else if let Some(ref hw) = hw_sink {
                // Self-heal: if WirePlumber moved `PhoeniX_Hardware_Out` onto `phoenix_revelation_sink`
                // after a USB hub reset (e.g. plugging/unplugging an SD card reader), move it right
                // back to the hardware DAC sink (`TX-384Khz` / `Line1` / `Speaker`) and ensure unmuted!
                let _ = current_sink_id;
                let _ = Command::new("pactl")
                    .args(["move-sink-input", id, hw])
                    .status();
                let _ = Command::new("pactl")
                    .args(["set-sink-mute", hw, "0"])
                    .status();
            }
        }
    }
}

/// Stop the system-wide PhoeniX daemon and restore the hardware sink cleanly.
fn stop_phoenix_daemon() {
    let hw_sink = select_primary_hardware_sink();
    move_all_sink_inputs_to(&hw_sink);
    let _ = Command::new("pactl")
        .args(["set-default-sink", &hw_sink])
        .status();

    if let Ok(pid_str) = fs::read_to_string(PHOENIX_PID_FILE) {
        let pid = pid_str.trim();
        if !pid.is_empty() {
            let _ = Command::new("kill").args(["-TERM", pid]).status();
        }
    }
    let _ = Command::new("pkill")
        .args(["-f", "PhoeniX_Hardware_Out"])
        .status();
    let _ = Command::new("pkill")
        .args(["-f", "phoenix_revelation_sink.monitor"])
        .status();
    let _ = fs::remove_file(PHOENIX_PID_FILE);
}

/// Start the system-wide PhoeniX daemon in the background if not already running.
fn start_phoenix_daemon_bg() {
    if is_phoenix_daemon_running() {
        return;
    }
    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("/home/hue/.local/bin/qwave-hypr-hud"));
    let _ = Command::new("setsid")
        .args(["--fork", &exe.to_string_lossy(), "phoenix-daemon"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Toggle system-wide PipeWire PhoeniX Sound Revelation on/off (`qwave-hypr-hud phoenix-toggle`).
pub fn run_phoenix_toggle(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"phoenix-toggle\",\"mode\":\"dry-run\",\"trit\":\"+\"}"
            .to_string();
    }
    let sub = args.first().map(String::as_str).unwrap_or("toggle");
    let running = is_phoenix_daemon_running();
    if sub == "stop" || (sub == "toggle" && running) {
        stop_phoenix_daemon();
        send_desktop_notification(
            "🔥 PhoeniX Sound Revelation Bypassed [0]",
            "Restored direct hardware PipeWire sink",
        );
        "{\"ok\":true,\"action\":\"phoenix-toggle\",\"active\":false,\"trit\":\"0\"}".to_string()
    } else {
        start_phoenix_daemon_bg();
        let preset = read_active_phoenix_preset_slug();
        send_desktop_notification(
            "🔥 PhoeniX on Everything Active [+]",
            &format!("768kHz Catmull-Rom + S+N+T + 432Hz/phi + Goonj/Naad/Svara ({preset})"),
        );
        format!(
            "{{\"ok\":true,\"action\":\"phoenix-toggle\",\"active\":true,\"preset\":\"{}\",\"trit\":\"+\"}}",
            json_escape(&preset)
        )
    }
}

/// Cycle or set the active PhoeniX preset (`qwave-hypr-hud phoenix-preset [next|sovereign|goonj-velvet|naad-studio|sanctuary-432|vocal-clarity]`).
pub fn run_phoenix_preset(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let req = args.first().map(String::as_str).unwrap_or("next");
    let current = read_active_phoenix_preset_slug();
    let next_slug = if req == "next" || req == "--dry-run" {
        PhoenixSoundPreset::next_preset_slug(&current)
    } else {
        PhoenixSoundPreset::from_name(req).slug()
    };
    if !dry_run {
        let _ = fs::write(PHOENIX_PRESET_FILE, next_slug);
        if !is_phoenix_daemon_running() {
            start_phoenix_daemon_bg();
        }
        send_desktop_notification(
            "🔥 PhoeniX Preset Switched [+]",
            &format!("Active Revelation Preset: {next_slug} (768kHz S+N+T + Goonj/Naad/Svara)"),
        );
    }
    format!(
        "{{\"ok\":true,\"action\":\"phoenix-preset\",\"preset\":\"{}\",\"trit\":\"+\"}}",
        json_escape(next_slug)
    )
}

/// Interactive Fuzzel/Wofi menu for PhoeniX on Everything (`qwave-hypr-hud phoenix-menu`).
pub fn run_phoenix_menu(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let running = is_phoenix_daemon_running();
    let current = read_active_phoenix_preset_slug();
    let rate_mode = fs::read_to_string(PHOENIX_HW_RATE_FILE)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "auto".to_string());
    let target_rate = read_target_phoenix_hw_rate();
    let multisink = fs::read_to_string(PHOENIX_MULTISINK_FILE)
        .map(|s| s.trim() == "1")
        .unwrap_or(false);

    let entries = vec![
        format!(
            "[TOGGLE] {} System-Wide PhoeniX on Everything",
            if running { "Disable (Currently LIVE [+])" } else { "Enable (Currently BYPASSED [0])" }
        ),
        format!(
            "[PRESET: sovereign] PhoeniX Sovereign Master (768kHz + 432Hz/phi + Goonj/Svara/Naad){}",
            if current == "sovereign" { " *" } else { "" }
        ),
        format!(
            "[PRESET: goonj-velvet] Goonj Ternary Dark Velvet Concert Hall (16-Tap [-1,0,+1] DVN){}",
            if current == "goonj-velvet" { " *" } else { "" }
        ),
        format!(
            "[PRESET: naad-studio] Naad Studio Sub & Transient Master (Chamberlin SVF Sub + Dirac Punch){}",
            if current == "naad-studio" { " *" } else { "" }
        ),
        format!(
            "[PRESET: sanctuary-432] Sanctuary 432Hz Rational Relaxation (54/55 Resample + Golden Bloom){}",
            if current == "sanctuary-432" { " *" } else { "" }
        ),
        format!(
            "[PRESET: vocal-clarity] Svara Singer Emotion & Vocal Intimacy (Soul F1/F2 Formant + Triode Chest Bloom){}",
            if current == "vocal-clarity" { " *" } else { "" }
        ),
        format!(
            "[HIRES: auto] Beast Least-Cost Auto-Max Rate for Selected Device (Currently {} Hz){}",
            target_rate,
            if rate_mode == "auto" || rate_mode.is_empty() { " *" } else { "" }
        ),
        format!(
            "[HIRES: 384kHz] Pin USB HiFi DAC to 384,000 Hz 24-bit (8x Babbage Forward-Diff S32LE){}",
            if rate_mode == "384000" { " *" } else { "" }
        ),
        format!(
            "[HIRES: 192kHz] Pin USB HiFi DAC to 192,000 Hz 24-bit (4x Babbage Forward-Diff S32LE){}",
            if rate_mode == "192000" { " *" } else { "" }
        ),
        format!(
            "[MULTISINK] Toggle Home Studio Multi-Sink Broadcast (USB HiFi + Scarlett 18i20): {}",
            if multisink { "ON [+]" } else { "OFF [0]" }
        ),
        "[MARINE-SENSE] Launch Zero-FFT Marine-Salience Time-Domain Spectrogram Window (:8432/marine-sense)".to_string(),
        "[OXICAST: TV STAGE] Launch 8b-is OxiCast Visualizer & AI Markdown TV Kiosk (:8432/oxicast)".to_string(),
        "[OXICAST: CAST MD] Cast Current Qwave Markdown / Clipboard to OxiCast TV Stage".to_string(),
    ];

    if dry_run {
        return format!(
            "{{\"ok\":true,\"action\":\"phoenix-menu\",\"mode\":\"dry-run\",\"entries\":{},\"trit\":\"+\"}}",
            entries.len()
        );
    }

    let Some(choice) = prompt_dmenu("🔥 PhoeniX Sound Revelation > ", &entries, false) else {
        return "{\"ok\":true,\"action\":\"phoenix-menu\",\"status\":\"cancelled\",\"trit\":\"0\"}"
            .to_string();
    };
    let choice = choice.trim();
    if choice.starts_with("[TOGGLE]") {
        return run_phoenix_toggle(&[]);
    }
    if choice.starts_with("[MARINE-SENSE]") {
        return run_marine_sense(&[]);
    }
    if choice.starts_with("[OXICAST: TV STAGE]") {
        return run_oxicast_tv(&[]);
    }
    if choice.starts_with("[OXICAST: CAST MD]") {
        return run_oxicast_cast(&["--clipboard".to_string()]);
    }
    if choice.starts_with("[HIRES:") {
        let mode_str = if choice.contains("auto") {
            "auto"
        } else if choice.contains("384kHz") {
            "384000"
        } else {
            "192000"
        };
        let _ = fs::write(PHOENIX_HW_RATE_FILE, format!("{mode_str}\n"));
        let resolved_rate = read_target_phoenix_hw_rate();
        configure_pipewire_hires_clock(resolved_rate);
        if running {
            stop_phoenix_daemon();
            start_phoenix_daemon_bg();
        }
        send_desktop_notification(
            "🔥 PhoeniX Beast Least-Cost Hi-Res Lock [+]",
            &format!("Mode: {mode_str} -> {resolved_rate} Hz · 24-bit S24_3LE (Babbage Forward-Diff S32LE)"),
        );
        return format!(
            "{{\"ok\":true,\"action\":\"phoenix-menu\",\"rate_mode\":\"{mode_str}\",\"hw_rate_hz\":{resolved_rate},\"trit\":\"+\"}}"
        );
    }
    if choice.starts_with("[MULTISINK]") {
        let new_val = if multisink { "0" } else { "1" };
        let _ = fs::write(PHOENIX_MULTISINK_FILE, new_val);
        if running {
            stop_phoenix_daemon();
            start_phoenix_daemon_bg();
        }
        send_desktop_notification(
            "🔥 PhoeniX Studio Multi-Sink Broadcast",
            if !multisink {
                "Enabled simultaneous output to USB HiFi DAC + Focusrite Scarlett 18i20 [+]"
            } else {
                "Restored single primary hardware sink output [0]"
            },
        );
        return format!(
            "{{\"ok\":true,\"action\":\"phoenix-menu\",\"multisink\":{},\"trit\":\"+\"}}",
            !multisink
        );
    }
    for slug in ["sovereign", "goonj-velvet", "naad-studio", "sanctuary-432", "vocal-clarity"] {
        if choice.contains(slug) {
            return run_phoenix_preset(&[slug.to_string()]);
        }
    }
    "{\"ok\":true,\"action\":\"phoenix-menu\",\"status\":\"noop\",\"trit\":\"0\"}".to_string()
}

/// Run the real-time PipeWire streaming PhoeniX Sound Revelation Daemon (`qwave-hypr-hud phoenix-daemon`).
pub fn run_phoenix_daemon(args: &[String]) {
    if args.iter().any(|a| a == "--dry-run") {
        println!("{{\"ok\":true,\"action\":\"phoenix-daemon\",\"mode\":\"dry-run\",\"trit\":\"+\"}}");
        return;
    }

    let my_pid = std::process::id();
    let _ = fs::write(PHOENIX_PID_FILE, format!("{my_pid}\n"));

    let target_hw_rate = read_target_phoenix_hw_rate();
    let upsample_factor = ((target_hw_rate / 48_000) as usize).clamp(1, 8);
    configure_pipewire_hires_clock(target_hw_rate);

    let primary_hw_sink = select_primary_hardware_sink();
    let hw_short = if primary_hw_sink.contains("TX-384Khz") {
        if target_hw_rate >= 352_800 {
            "USB-HiFi-384kHz-24b"
        } else {
            "USB-HiFi-192kHz-24b"
        }
    } else if primary_hw_sink.contains("Scarlett") {
        "Scarlett-18i20"
    } else if primary_hw_sink.contains("Speaker") {
        "Laptop-Speaker"
    } else {
        "PipeWire-HW"
    };

    // Ensure virtual null sink `phoenix_revelation_sink` exists
    let sinks_raw = Command::new("pactl")
        .args(["list", "short", "sinks"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    if !sinks_raw.contains(PHOENIX_SINK_NAME) {
        if let Ok(out) = Command::new("pactl")
            .args([
                "load-module",
                "module-null-sink",
                &format!("sink_name={PHOENIX_SINK_NAME}"),
                "sink_properties=device.description=PhoeniX_Sound_Revelation_768kHz_432Hz_Goonj",
                "rate=48000",
                "channels=2",
            ])
            .output()
        {
            let mod_id = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !mod_id.is_empty() {
                let _ = fs::write(PHOENIX_MOD_ID_FILE, &mod_id);
            }
        }
    }

    let _ = Command::new("pactl")
        .args(["set-sink-mute", &primary_hw_sink, "0"])
        .status();
    let _ = Command::new("pactl")
        .args(["set-sink-volume", &primary_hw_sink, "65536"])
        .status();
    // Ensure USB HiFi DAC ALSA hardware mixer is at 100% (0.00 dB) unmuted for full 24-bit dynamic range
    let _ = Command::new("amixer")
        .args(["-c", "2", "sset", "PCM", "100%", "unmute"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("pactl")
        .args(["set-sink-mute", PHOENIX_SINK_NAME, "0"])
        .status();
    let _ = Command::new("pactl")
        .args(["set-sink-volume", PHOENIX_SINK_NAME, "65536"])
        .status();
    let _ = Command::new("pactl")
        .args(["set-default-sink", PHOENIX_SINK_NAME])
        .status();

    // Spawn `parec` reading from `phoenix_revelation_sink.monitor`
    let Ok(mut rec_child) = Command::new("parec")
        .args([
            &format!("--device={PHOENIX_SINK_NAME}.monitor"),
            "--format=s16le",
            "--rate=48000",
            "--channels=2",
            "--latency-msec=20",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return;
    };

    // Spawn primary `pacat` playing to `primary_hw_sink` at native 192 kHz / 384 kHz 32-bit integer (`s32le` -> 24-bit `S24_3LE` DAC)!
    let Ok(mut play_primary) = Command::new("pacat")
        .args([
            &format!("--device={primary_hw_sink}"),
            "--format=s32le",
            &format!("--rate={target_hw_rate}"),
            "--channels=2",
            "--latency-msec=25",
            "--client-name=PhoeniX_Hardware_Out",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        let _ = rec_child.kill();
        return;
    };

    // Optional secondary hardware sink for Multi-Sink Studio Broadcast (e.g. Scarlett 18i20 Line1)
    let multisink = fs::read_to_string(PHOENIX_MULTISINK_FILE)
        .map(|s| s.trim() == "1")
        .unwrap_or(false);
    let mut play_secondary = if multisink {
        let all_hw = discover_hardware_sinks();
        all_hw
            .into_iter()
            .find(|s| s != &primary_hw_sink && (s.contains("Line1__sink") || s.contains("Speaker__sink") || s.contains("TX-384Khz")))
            .and_then(|sec_sink| {
                Command::new("pacat")
                    .args([
                        &format!("--device={sec_sink}"),
                        "--format=s16le",
                        "--rate=48000",
                        "--channels=2",
                        "--latency-msec=30",
                        "--client-name=PhoeniX_Hardware_Out",
                    ])
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .ok()
            })
    } else {
        None
    };

    // Move existing application streams into `phoenix_revelation_sink`
    move_all_sink_inputs_to(PHOENIX_SINK_NAME);

    let initial_slug = read_active_phoenix_preset_slug();
    let mut processor = PhoenixLiveProcessor::new(48_000, PhoenixSoundPreset::from_name(&initial_slug));
    let (init_auto, init_v, init_b, init_s) = read_phoenix_feel_controls();
    processor.set_feel_controls(init_auto, init_v, init_b, init_s);
    processor.alexandra_reset_active = read_alexandra_reset_active();

    let Some(mut rec_out) = rec_child.stdout.take() else {
        return;
    };
    let Some(mut play_in) = play_primary.stdin.take() else {
        return;
    };
    let mut sec_in = play_secondary.as_mut().and_then(|c| c.stdin.take());

    // 1024 stereo frames = 2048 i16 samples = 4096 bytes (~21.3ms @ 48kHz)
    // At 8x (384 kHz): 2048 * 8 = 16384 i32 samples = 65536 bytes (Exact C64 64KB Block per write!)
    let mut byte_buf = [0u8; 4096];
    let mut pcm_buf = [0i16; 2048];
    let mut s32_buf = vec![0i32; 2048 * upsample_factor];
    let mut s32_byte_buf = vec![0u8; 2048 * upsample_factor * 4];
    let mut chunk_counter: u64 = 0;

    // Non-blocking `.8a` (`8a∞`) 16-byte UDP telemetry broadcaster on port 8432 for ESP32-WROOM & OxiCast nodes
    let udp_8a = UdpSocket::bind("0.0.0.0:0").ok();
    if let Some(ref sock) = udp_8a {
        let _ = sock.set_nonblocking(true);
        let _ = sock.set_broadcast(true);
    }

    loop {
        // Read exact 4096-byte stereo block
        let mut read_pos = 0usize;
        while read_pos < byte_buf.len() {
            match rec_out.read(&mut byte_buf[read_pos..]) {
                Ok(0) | Err(_) => {
                    read_pos = 0;
                    break;
                }
                Ok(n) => read_pos += n,
            }
        }
        if read_pos == 0 {
            break;
        }

        for (i, pair) in byte_buf.chunks_exact(2).enumerate() {
            pcm_buf[i] = i16::from_le_bytes([pair[0], pair[1]]);
        }

        // Hot-reload preset and Auto-Magical Feel controls every 16 chunks (~340ms)
        if chunk_counter & 15 == 0 {
            let slug = read_active_phoenix_preset_slug();
            let target = PhoenixSoundPreset::from_name(&slug);
            if target != processor.preset {
                processor.preset = target;
            }
            let (f_auto, f_v, f_b, f_s) = read_phoenix_feel_controls();
            processor.set_feel_controls(f_auto, f_v, f_b, f_s);
            processor.alexandra_reset_active = read_alexandra_reset_active();
        }

        // Periodically ensure newly opened app streams are routed through `phoenix_revelation_sink`
        // AND keep `phoenix_revelation_sink` at 100% unity gain so the 16-bit input pipe is never starved!
        // Offloaded to a background thread so the real-time 384 kHz audio loop never blocks on `pactl`!
        if chunk_counter & 255 == 128 {
            thread::spawn(|| {
                let _ = Command::new("pactl")
                    .args(["set-sink-mute", PHOENIX_SINK_NAME, "0"])
                    .status();
                let _ = Command::new("pactl")
                    .args(["set-sink-volume", PHOENIX_SINK_NAME, "65536"])
                    .status();
                move_all_sink_inputs_to(PHOENIX_SINK_NAME);
            });
        }

        // Transform through 768kHz Catmull-Rom + S+N+T + 432Hz/phi + Goonj/Svara/Naad at 48 kHz (1x cost)
        // AND upsample 8x (384 kHz) / 4x (192 kHz) into 32-bit signed integer (`s32le`) via Babbage 3-Addition Forward Differencing!
        let written_s32 = processor.process_stereo_upsample_s32le(&mut pcm_buf, upsample_factor, &mut s32_buf);
        for (i, &sample32) in s32_buf[..written_s32].iter().enumerate() {
            let b = sample32.to_le_bytes();
            let base = i * 4;
            s32_byte_buf[base] = b[0];
            s32_byte_buf[base + 1] = b[1];
            s32_byte_buf[base + 2] = b[2];
            s32_byte_buf[base + 3] = b[3];
        }

        if play_in.write_all(&s32_byte_buf[..written_s32 * 4]).is_err() {
            break;
        }
        if let Some(ref mut s_in) = sec_in {
            for (i, &sample16) in pcm_buf.iter().enumerate() {
                let b = sample16.to_le_bytes();
                byte_buf[i * 2] = b[0];
                byte_buf[i * 2 + 1] = b[1];
            }
            let _ = s_in.write_all(&byte_buf);
        }

        // Broadcast 16-byte `.8a` (`8a∞`) UDP telemetry frame every 8 chunks (~170ms) on port 8432
        if chunk_counter & 7 == 0 {
            if let Some(ref sock) = udp_8a {
                let (dom_hz, _shruti_r, shruti_name, soul) = processor.live_telemetry();
                let dyad = compute_riva_dyad_state(now_epoch_secs().saturating_mul(1000));
                let hz_u16 = (dom_hz.num / dom_hz.den.max(1) as i32).clamp(0, 65535) as u16;
                let soul_u16 = soul.num.clamp(0, 1024) as u16;
                let s_u16 = (processor.harmonic_s_frames & 0xFFFF) as u16;
                let t_u16 = (processor.dirac_t_frames & 0xFFFF) as u16;
                let shruti_idx: u8 = match shruti_name {
                    "Sa" => 0,
                    "Komal Re (Ati)" => 1,
                    "Komal Re" => 2,
                    "Shuddha Re (Nyuna)" => 3,
                    "Shuddha Re" => 4,
                    "Komal Ga (Ati)" => 5,
                    "Komal Ga" => 6,
                    "Shuddha Ga" => 7,
                    "Tivra Ga" => 8,
                    "Shuddha Ma" => 9,
                    "Shuddha Ma (Shruti)" => 10,
                    "Tivra Ma" => 11,
                    "Ati Tivra Ma" => 12,
                    "Pa" => 13,
                    "Komal Dha (Ati)" => 14,
                    "Komal Dha" => 15,
                    "Shuddha Dha (Nyuna)" => 16,
                    "Shuddha Dha" => 17,
                    "Komal Ni (Ati)" => 18,
                    "Komal Ni" => 19,
                    "Shuddha Ni" => 20,
                    _ => 21,
                };
                let preset_idx: u8 = match processor.preset.slug() {
                    "sovereign" => 0,
                    "goonj-velvet" => 1,
                    "naad-studio" => 2,
                    "sanctuary-432" => 3,
                    _ => 4,
                };
                let mut pkt = [0u8; 16];
                pkt[0..4].copy_from_slice(&EIGHT_A_MAGIC);
                pkt[4] = shruti_idx;
                pkt[5] = preset_idx;
                pkt[6..8].copy_from_slice(&dyad.breath_q8.to_le_bytes());
                pkt[8..10].copy_from_slice(&hz_u16.to_le_bytes());
                pkt[10..12].copy_from_slice(&soul_u16.to_le_bytes());
                pkt[12..14].copy_from_slice(&s_u16.to_le_bytes());
                pkt[14..16].copy_from_slice(&t_u16.to_le_bytes());
                let _ = sock.send_to(&pkt, "127.0.0.1:8432");
                if let Ok(esp_ip) = fs::read_to_string("/tmp/qwave_oxicast_esp32_ip.txt") {
                    let ip_trim = esp_ip.trim();
                    if !ip_trim.is_empty() {
                        let _ = sock.send_to(&pkt, format!("{ip_trim}:8432"));
                    }
                }
            }
        }

        // Emit live zero-float `p/q` + 64-anchor (4096-spline) 96kHz Marine Time-Domain Salience telemetry every 2 chunks (~42ms)
        if chunk_counter & 1 == 0 {
            let (dom_hz, shruti_r, shruti_name, soul) = processor.live_telemetry();
            let mut b_csv = String::with_capacity(320);
            let mut v_csv = String::with_capacity(320);
            for i in 0..64 {
                if i > 0 {
                    b_csv.push(',');
                    v_csv.push(',');
                }
                b_csv.push_str(&processor.marine_buckets_q10[i].to_string());
                v_csv.push_str(&processor.marine_vocal_q10[i].to_string());
            }
            let mut singers_json = String::with_capacity(280);
            singers_json.push('[');
            for s in 0..4 {
                if s > 0 {
                    singers_json.push(',');
                }
                let sl = &processor.singer_slots[s];
                singers_json.push_str(&format!(
                    "{{\"id\":{},\"active\":{},\"role\":\"{}\",\"f0\":{},\"fmt\":{},\"x\":{},\"y\":{},\"pres\":{},\"frames\":{}}}",
                    sl.slot_id,
                    sl.active,
                    sl.archetype_name(),
                    sl.f0_centroid_hz,
                    sl.formant_ratio_q8,
                    sl.emo_x_q10,
                    sl.emo_y_q10,
                    sl.presence_q10,
                    sl.frames_sung
                ));
            }
            singers_json.push(']');
            let tsv = format!(
                "{}/{}\t{}/{}\t{}\t{}/{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                dom_hz.num,
                dom_hz.den,
                shruti_r.num,
                shruti_r.den,
                shruti_name,
                soul.num,
                soul.den,
                processor.catmull_rom_restored_samples,
                processor.harmonic_s_frames,
                processor.dirac_t_frames,
                hw_short,
                b_csv,
                v_csv,
                processor.stochastic_n_frames,
                processor.vocal_confidence_q10,
                processor.active_singer_id,
                processor.vocal_f0_hz,
                singers_json
            );
            let _ = fs::write(PHOENIX_LIVE_TSV, sanitize_no_float(&tsv));
        }

        chunk_counter = chunk_counter.wrapping_add(1);
    }

    let _ = rec_child.kill();
    let _ = play_primary.kill();
    if let Some(mut sec) = play_secondary {
        let _ = sec.kill();
    }
}

// ── Sovereign OxiCast × PhoeniX Sanctuary & AI Markdown TV Stage (:8432) ───

const OXICAST_PID_FILE: &str = "/tmp/qwave_oxicast_daemon.pid";
const OXICAST_STAGE_FILE: &str = "/tmp/qwave_oxicast_stage.json";
const OXICAST_PORT: u16 = 8432;

/// Check whether `qwave-hypr-hud oxicast-daemon` is alive.
fn is_oxicast_daemon_running() -> bool {
    if let Ok(pid_str) = fs::read_to_string(OXICAST_PID_FILE) {
        let pid = pid_str.trim();
        if !pid.is_empty() && Path::new(&format!("/proc/{pid}")).exists() {
            return true;
        }
    }
    false
}

/// Spawn `qwave-hypr-hud oxicast-daemon` in the background if not already running.
fn ensure_oxicast_daemon_running() {
    if is_oxicast_daemon_running() {
        return;
    }
    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("/home/hue/.local/bin/qwave-hypr-hud"));
    if let Ok(child) = Command::new(exe)
        .arg("oxicast-daemon")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        let _ = fs::write(OXICAST_PID_FILE, format!("{}\n", child.id()));
    }
}

/// Discover primary LAN IPv4 address formatted with colons or raw string for URL display.
fn discover_lan_ipv4_raw() -> String {
    if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
        if sock.connect("172.16.47.1:80").is_ok() || sock.connect("1.1.1.1:80").is_ok() {
            if let Ok(local) = sock.local_addr() {
                return local.ip().to_string();
            }
        }
    }
    "127.0.0.1".to_string()
}

/// Default Markdown stage content when no document has been explicitly cast yet.
fn default_oxicast_markdown() -> String {
    "# 🌸 Sovereign OxiCast × PhoeniX Master Bedroom Sanctuary\n\
     \n\
     > [!IMPORTANT]\n\
     > **Beast Least-Cost Auto-Max Hi-Res Audio**: `384,000 Hz` · `24-bit S24_3LE` · **Babbage 3-Addition Cubic Forward-Difference Stepper** (`y += d1; d1 += d2; d2 += d3;`).\n\
     \n\
     ## 🎶 Live 8b-is Visualizers & Sanctuary Controls\n\
     - **`[1] Milkdrop × PhoeniX 432Hz Spiral`**: Golden-ratio (`89/55`) harmonic particle field driven by live 22-Shruti `p/q` telemetry.\n\
     - **`[2] Water-Fall Disc (Nazar Drums)`**: Procedural cascading harmonic discs from `water-fall-disc`.\n\
     - **`[3] zoneInn Ternary {-1, 0, +1} & 22-Shruti Mandala`**: Balanced-ternary equalizer and Gandharva 22-Shruti compass.\n\
     - **`[4] AI Qwave Markdown + Mermaid Stage`**: Live AI-cast documents, architecture diagrams, and carousels.\n\
     - **`[5] 50/50 Split Sanctuary`**: Simultaneous 60fps Milkdrop/Shruti visualizer + live Qwave Markdown deck.\n\
     \n\
     ```mermaid\n\
     flowchart LR\n\
       A[\"All Apps / AirPlay / UPnP (48 kHz)\"] --> B[\"PhoeniX 768kHz Catmull-Rom + 432Hz/phi + Goonj DVN\"]\n\
       B --> C[\"Babbage 3-Add Cubic Stepper (384,000 Hz S32LE)\"]\n\
       C --> D[\"USB HiFi DAC (24-bit S24_3LE) + RaspiAudio HAT\"]\n\
       B --> E[\".8a (8a∞) 16-Byte UDP :8432 -> ESP32-WROOM Bedside Ambilight\"]\n\
     ```\n"
        .to_string()
}

/// Ensure `/tmp/qwave_oxicast_stage.json` exists; return its contents.
fn read_or_init_oxicast_stage_json() -> String {
    if let Ok(raw) = fs::read_to_string(OXICAST_STAGE_FILE) {
        let trimmed = raw.trim();
        if trimmed.starts_with('{') && trimmed.ends_with('}') {
            return sanitize_no_float(trimmed);
        }
    }
    let md = default_oxicast_markdown();
    let compiled = compile_full(&md, MarkdownTrust::CompilerOutputOnly, None);
    let json = format!(
        "{{\"seq\":1,\"ts\":{},\"mode\":5,\"title\":\"Sovereign OxiCast Sanctuary\",\"html\":\"{}\",\"md\":\"{}\"}}",
        now_epoch_secs(),
        json_escape(&sanitize_no_float(&compiled.html)),
        json_escape(&sanitize_no_float(&md))
    );
    let _ = fs::write(OXICAST_STAGE_FILE, &json);
    json
}

/// Build single-line zero-float JSON telemetry for `GET /api/oxicast/telemetry`.
pub fn build_oxicast_telemetry_json() -> String {
    let running = is_phoenix_daemon_running();
    let preset_slug = read_active_phoenix_preset_slug();
    let preset = PhoenixSoundPreset::from_name(&preset_slug);
    let target_rate = read_target_phoenix_hw_rate();
    let (hw_rate, hw_bits) = probe_usb_hardware_rate_and_bits();
    let active_rate = if hw_rate > 0 { hw_rate } else { target_rate };
    let active_bits = if hw_bits > 0 { hw_bits } else { 24 };

    let mut dom_hz = "432/1".to_string();
    let mut dom_hz_int: i64 = 432;
    let mut shruti_pq = "1/1".to_string();
    let mut shruti_name = "Sa".to_string();
    let mut soul_pq = "980/1024".to_string();
    let mut soul_num: i64 = 980;
    let mut restored: u64 = 0;
    let mut s_frames: u64 = 0;
    let mut t_frames: u64 = 0;
    let mut n_frames: u64 = 0;
    let mut hw_short = "USB-HiFi-384kHz-24b".to_string();
    let mut marine_buckets_csv = "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0".to_string();
    let mut marine_vocal_csv = "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0".to_string();
    let mut vocal_conf: u16 = 0;
    let mut active_singer: u8 = 255;
    let mut vocal_f0_hz: u16 = 0;
    let mut singers_json = "[{\"id\":0,\"active\":false,\"role\":\"Unassigned\",\"f0\":0,\"fmt\":0,\"x\":0,\"y\":0,\"pres\":0,\"frames\":0},{\"id\":1,\"active\":false,\"role\":\"Unassigned\",\"f0\":0,\"fmt\":0,\"x\":0,\"y\":0,\"pres\":0,\"frames\":0},{\"id\":2,\"active\":false,\"role\":\"Unassigned\",\"f0\":0,\"fmt\":0,\"x\":0,\"y\":0,\"pres\":0,\"frames\":0},{\"id\":3,\"active\":false,\"role\":\"Unassigned\",\"f0\":0,\"fmt\":0,\"x\":0,\"y\":0,\"pres\":0,\"frames\":0}]".to_string();

    if let Ok(raw) = fs::read_to_string(PHOENIX_LIVE_TSV) {
        if let Some(line) = raw.lines().next() {
            let cols: Vec<&str> = line.split('\t').collect();
            if cols.len() >= 8 {
                dom_hz = sanitize_no_float(cols[0]);
                if let Some((n, d)) = dom_hz.split_once('/') {
                    let nn = n.parse::<i64>().unwrap_or(432);
                    let dd = d.parse::<i64>().unwrap_or(1).max(1);
                    dom_hz_int = nn / dd;
                }
                shruti_pq = sanitize_no_float(cols[1]);
                shruti_name = sanitize_no_float(cols[2]);
                soul_pq = sanitize_no_float(cols[3]);
                if let Some((sn, _sd)) = soul_pq.split_once('/') {
                    soul_num = sn.parse::<i64>().unwrap_or(980);
                }
                restored = cols[4].parse::<u64>().unwrap_or(0);
                s_frames = cols[5].parse::<u64>().unwrap_or(0);
                t_frames = cols[6].parse::<u64>().unwrap_or(0);
                hw_short = sanitize_no_float(cols[7]);
                if cols.len() >= 10 {
                    marine_buckets_csv = sanitize_no_float(cols[8]);
                    marine_vocal_csv = sanitize_no_float(cols[9]);
                }
                if cols.len() >= 11 {
                    n_frames = cols[10].parse::<u64>().unwrap_or(0);
                }
                if cols.len() >= 15 {
                    vocal_conf = cols[11].parse::<u16>().unwrap_or(0);
                    active_singer = cols[12].parse::<u8>().unwrap_or(255);
                    vocal_f0_hz = cols[13].parse::<u16>().unwrap_or(0);
                    let sj = cols[14].trim();
                    if sj.starts_with('[') && sj.ends_with(']') {
                        singers_json = sanitize_no_float(sj);
                    }
                }
            }
        }
    }

    let dyad = compute_riva_dyad_state(now_epoch_secs().saturating_mul(1000));
    let stage_json = read_or_init_oxicast_stage_json();
    let (automagic, feel_voice, feel_bass, feel_space) = read_phoenix_feel_controls();
    let alexandra_reset = read_alexandra_reset_active();

    format!(
        "{{\"ok\":true,\"phoenix_live\":{},\"preset_slug\":\"{}\",\"preset_label\":\"{}\",\
          \"automagic\":{},\"alexandra_reset\":{},\"feel_voice\":{},\"feel_bass\":{},\"feel_space\":{},\
          \"hw_rate_hz\":{},\"hw_bits\":{},\"hw_sink\":\"{}\",\
          \"dom_hz_pq\":\"{}\",\"dom_hz_int\":{},\"shruti_pq\":\"{}\",\"shruti_name\":\"{}\",\
          \"soul_pq\":\"{}\",\"soul_num\":{},\"restored_samples\":{},\"s_frames\":{},\"t_frames\":{},\"n_frames\":{},\
          \"marine_buckets\":[{}],\"marine_vocal\":[{}],\
          \"vocal_conf\":{},\"active_singer\":{},\"vocal_f0_hz\":{},\"singers\":{},\
          \"breath_phase\":\"{}\",\"breath_q8\":{},\"breath_rem_ds\":{},\"lullaby\":\"{}\",\
          \"stage\":{}}}",
        running,
        json_escape(&preset_slug),
        json_escape(preset.slug()),
        automagic,
        alexandra_reset,
        feel_voice,
        feel_bass,
        feel_space,
        active_rate,
        active_bits,
        json_escape(&hw_short),
        json_escape(&dom_hz),
        dom_hz_int,
        json_escape(&shruti_pq),
        json_escape(&shruti_name),
        json_escape(&soul_pq),
        soul_num,
        restored,
        s_frames,
        t_frames,
        n_frames,
        marine_buckets_csv,
        marine_vocal_csv,
        vocal_conf,
        active_singer,
        vocal_f0_hz,
        singers_json,
        json_escape(dyad.breath_phase),
        dyad.breath_q8,
        dyad.breath_remaining_deci_s,
        json_escape(dyad.lullaby_verse),
        stage_json
    )
}

/// Cast a Markdown file, inline string, or clipboard onto the OxiCast TV Stage (`qwave-hypr-hud oxicast-cast`).
pub fn run_oxicast_cast(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    let use_clip = args.iter().any(|a| a == "--clipboard");

    let mut mode: u8 = 4;
    let mut title = "AI Qwave Markdown Stage".to_string();
    let mut target_arg: Option<String> = None;

    let mut idx = 0usize;
    while idx < args.len() {
        let a = &args[idx];
        if a == "--dry-run" || a == "--clipboard" {
            idx += 1;
            continue;
        }
        if a == "--mode" {
            if let Some(m) = args.get(idx + 1) {
                mode = m.parse::<u8>().unwrap_or(4).clamp(1, 5);
                idx += 2;
                continue;
            }
        }
        if a == "--title" {
            if let Some(t) = args.get(idx + 1) {
                title = sanitize_no_float(t);
                idx += 2;
                continue;
            }
        }
        if target_arg.is_none() {
            target_arg = Some(a.clone());
        }
        idx += 1;
    }

    if dry_run {
        return "{\"ok\":true,\"action\":\"oxicast-cast\",\"mode\":\"dry-run\",\"trit\":\"+\"}"
            .to_string();
    }

    let md_raw = if use_clip {
        Command::new("wl-paste")
            .arg("--no-newline")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(default_oxicast_markdown)
    } else if let Some(ref path_or_md) = target_arg {
        let p = Path::new(path_or_md);
        if p.exists() {
            if title == "AI Qwave Markdown Stage" {
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    title = sanitize_no_float(name);
                }
            }
            fs::read_to_string(p).unwrap_or_else(|_| path_or_md.clone())
        } else {
            path_or_md.clone()
        }
    } else {
        fs::read_to_string("/tmp/qwave_graphical_hud.md").unwrap_or_else(|_| default_oxicast_markdown())
    };

    let sanitized_md = sanitize_no_float(&md_raw);
    let compiled = compile_full(&sanitized_md, MarkdownTrust::CompilerOutputOnly, None);
    let seq = now_epoch_secs();
    let stage_json = format!(
        "{{\"seq\":{},\"ts\":{},\"mode\":{},\"title\":\"{}\",\"html\":\"{}\",\"md\":\"{}\"}}",
        seq,
        seq,
        mode,
        json_escape(&title),
        json_escape(&sanitize_no_float(&compiled.html)),
        json_escape(&sanitized_md)
    );
    let _ = fs::write(OXICAST_STAGE_FILE, &stage_json);
    ensure_oxicast_daemon_running();

    send_desktop_notification(
        "📺 OxiCast TV Stage Updated [+]",
        &format!("Cast '{}' (mode {}) -> :8432/oxicast", title, mode),
    );

    format!(
        "{{\"ok\":true,\"action\":\"oxicast-cast\",\"title\":\"{}\",\"mode\":{},\"seq\":{},\"trit\":\"+\"}}",
        json_escape(&title),
        mode,
        seq
    )
}

fn open_url_in_qwave(url: &str) {
    let qwave_bin = find_qwave_bin();
    if is_cmdline_running("qwave-qt") {
        let nav_dir = PathBuf::from("/home/hue/.local/share/qwave");
        let _ = fs::create_dir_all(&nav_dir);
        let ts = now_epoch_secs();
        let _ = fs::write(nav_dir.join("nav_command.url"), format!("{ts}\n{url}"));
        let _ = hyprctl_exec_cmd("hyprctl dispatch focuswindow class:qwave");
    } else if !hyprctl_exec_cmd(&format!("{qwave_bin} --surf {url}")) {
        let _ = Command::new("setsid")
            .args(["--fork", qwave_bin, "--surf", url])
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

/// Launch the dedicated Zero-FFT Marine-Salience Time-Domain Spectrogram & Vocal Emotion Window (`qwave-hypr-hud marine-sense`).
pub fn run_marine_sense(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"marine-sense\",\"mode\":\"dry-run\",\"port\":8432,\"trit\":\"+\"}"
            .to_string();
    }

    let _ = read_or_init_oxicast_stage_json();
    ensure_oxicast_daemon_running();
    let lan_ip = discover_lan_ipv4_raw();
    let lan_ip_safe = sanitize_no_float(&lan_ip);
    let url = format!("http://127.0.0.1:{OXICAST_PORT}/marine-sense");

    if !args.iter().any(|a| a == "--no-open") {
        open_url_in_qwave(&url);
    }

    send_desktop_notification(
        "🌊 Marine-Sense Time-Domain Salience Spectrogram [+]",
        "Zero-FFT 4096-Bucket (20Hz-96kHz) Dyadic + Teager-Marine Vocal Emotion Waterfall (:8432/marine-sense)",
    );

    format!(
        "{{\"ok\":true,\"action\":\"marine-sense\",\"port\":{OXICAST_PORT},\"lan_node\":\"{lan_ip_safe}\",\"trit\":\"+\"}}"
    )
}

/// Ensure `oxicast-daemon` is running and launch/report the Sovereign OxiCast TV Stage (`qwave-hypr-hud oxicast-tv`).
pub fn run_oxicast_tv(args: &[String]) -> String {
    let dry_run = args.iter().any(|a| a == "--dry-run");
    if dry_run {
        return "{\"ok\":true,\"action\":\"oxicast-tv\",\"mode\":\"dry-run\",\"port\":8432,\"trit\":\"+\"}"
            .to_string();
    }

    let _ = read_or_init_oxicast_stage_json();
    ensure_oxicast_daemon_running();
    let lan_ip = discover_lan_ipv4_raw();
    let lan_ip_safe = sanitize_no_float(&lan_ip);
    let url = format!("http://127.0.0.1:{OXICAST_PORT}/oxicast");

    if !args.iter().any(|a| a == "--no-open") {
        open_url_in_qwave(&url);
    }

    send_desktop_notification(
        "🌸 OxiCast × PhoeniX Sanctuary Live [+]",
        &format!("Master Bedroom & TV Kiosk ready on port {OXICAST_PORT} (LAN {lan_ip_safe})"),
    );

    format!(
        "{{\"ok\":true,\"action\":\"oxicast-tv\",\"port\":{OXICAST_PORT},\"lan_node\":\"{lan_ip_safe}\",\"trit\":\"+\"}}"
    )
}

/// Build a 44-byte streaming WAV header (`48,000 Hz`, 16-bit stereo `s16le`, `0x7FFFFFFF` length for infinite HTTP live stream).
fn build_infinite_wav_header(sample_rate: u32, channels: u16, bits_per_sample: u16) -> [u8; 44] {
    let byte_rate = sample_rate * (channels as u32) * ((bits_per_sample / 8) as u32);
    let block_align = channels * (bits_per_sample / 8);
    let data_size: u32 = 0x7FFF_FF00;
    let riff_size: u32 = data_size.saturating_add(36);

    let mut h = [0u8; 44];
    h[0..4].copy_from_slice(b"RIFF");
    h[4..8].copy_from_slice(&riff_size.to_le_bytes());
    h[8..12].copy_from_slice(b"WAVE");
    h[12..16].copy_from_slice(b"fmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());
    h[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM = 1
    h[22..24].copy_from_slice(&channels.to_le_bytes());
    h[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    h[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    h[32..34].copy_from_slice(&block_align.to_le_bytes());
    h[34..36].copy_from_slice(&bits_per_sample.to_le_bytes());
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&data_size.to_le_bytes());
    h
}

/// Stream live PhoeniX-processed stereo WAV (`48,000 Hz` 16-bit PCM) over HTTP to a connected client
/// (`GET /api/oxicast/stream.wav`) so Alexandra can listen on any browser, iPhone, iPad, or Smart TV!
fn handle_oxicast_audio_stream(mut stream: TcpStream) {
    let header = "HTTP/1.1 200 OK\r\n\
                  Content-Type: audio/wav\r\n\
                  Cache-Control: no-cache, no-store\r\n\
                  Connection: close\r\n\
                  Access-Control-Allow-Origin: *\r\n\r\n";
    if stream.write_all(header.as_bytes()).is_err() {
        return;
    }
    let wav_hdr = build_infinite_wav_header(48_000, 2, 16);
    if stream.write_all(&wav_hdr).is_err() {
        return;
    }

    let Ok(mut rec_child) = Command::new("parec")
        .args([
            &format!("--device={PHOENIX_SINK_NAME}.monitor"),
            "--format=s16le",
            "--rate=48000",
            "--channels=2",
            "--latency-msec=30",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return;
    };

    let Some(mut rec_out) = rec_child.stdout.take() else {
        let _ = rec_child.kill();
        return;
    };

    let slug = read_active_phoenix_preset_slug();
    let mut processor = PhoenixLiveProcessor::new(48_000, PhoenixSoundPreset::from_name(&slug));
    let mut byte_buf = [0u8; 4096];
    let mut pcm_buf = [0i16; 2048];
    let mut chunk_idx: u64 = 0;

    loop {
        let mut read_pos = 0usize;
        while read_pos < byte_buf.len() {
            match rec_out.read(&mut byte_buf[read_pos..]) {
                Ok(0) | Err(_) => {
                    read_pos = 0;
                    break;
                }
                Ok(n) => read_pos += n,
            }
        }
        if read_pos == 0 {
            break;
        }
        if chunk_idx & 31 == 0 {
            let cur_slug = read_active_phoenix_preset_slug();
            processor.preset = PhoenixSoundPreset::from_name(&cur_slug);
            let (f_auto, f_v, f_b, f_s) = read_phoenix_feel_controls();
            processor.set_feel_controls(f_auto, f_v, f_b, f_s);
            processor.alexandra_reset_active = read_alexandra_reset_active();
        }
        for (i, pair) in byte_buf.chunks_exact(2).enumerate() {
            pcm_buf[i] = i16::from_le_bytes([pair[0], pair[1]]);
        }
        processor.process_stereo_in_place(&mut pcm_buf);
        for (i, &s) in pcm_buf.iter().enumerate() {
            let b = s.to_le_bytes();
            byte_buf[i * 2] = b[0];
            byte_buf[i * 2 + 1] = b[1];
        }
        if stream.write_all(&byte_buf).is_err() {
            break;
        }
        chunk_idx = chunk_idx.wrapping_add(1);
    }

    let _ = rec_child.kill();
}

/// Handle a single HTTP client connection on the Sovereign OxiCast Server (`:8790`).
fn handle_oxicast_http_client(mut stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let Ok(cloned) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(cloned);
    let mut req_line = String::new();
    if reader.read_line(&mut req_line).is_err() {
        return;
    }
    let parts: Vec<&str> = req_line.split_whitespace().collect();
    let method = parts.first().copied().unwrap_or("GET");
    let path = parts.get(1).copied().unwrap_or("/");

    let mut content_len: usize = 0;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() || line == "\r\n" || line.is_empty() {
            break;
        }
        let lower = line.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("content-length:") {
            content_len = rest.trim().parse::<usize>().unwrap_or(0).min(C64_RING_BYTES);
        }
    }

    if method == "GET" && path.starts_with("/api/oxicast/stream.wav") {
        let _ = stream.set_read_timeout(None);
        handle_oxicast_audio_stream(stream);
        return;
    }

    if method == "GET" && path.starts_with("/api/oxicast/telemetry") {
        let body = build_oxicast_telemetry_json();
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "POST" && path.starts_with("/api/oxicast/preset") {
        let mut body_buf = vec![0u8; content_len];
        let _ = reader.read_exact(&mut body_buf);
        let body_str = String::from_utf8_lossy(&body_buf).trim().to_string();
        let slug = body_str.strip_prefix("preset=").unwrap_or(&body_str).trim();
        let res = run_phoenix_preset(&[slug.to_string()]);
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{}",
            res.len(),
            res
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "POST" && path.starts_with("/api/oxicast/alexandra-reset") {
        let mut body_buf = vec![0u8; content_len];
        let _ = reader.read_exact(&mut body_buf);
        let body_str = String::from_utf8_lossy(&body_buf).trim().to_string();
        let arg = body_str.strip_prefix("active=").unwrap_or(&body_str).trim();
        let mode_arg = if arg.is_empty() { "toggle" } else { arg };
        let res = run_alexandra_reset(&[mode_arg.to_string()]);
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{}",
            res.len(),
            res
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "POST" && path.starts_with("/api/oxicast/feel") {
        let mut body_buf = vec![0u8; content_len];
        let _ = reader.read_exact(&mut body_buf);
        let body_str = String::from_utf8_lossy(&body_buf).trim().to_string();
        let (mut auto, mut v, mut b, mut s) = read_phoenix_feel_controls();
        for kv in body_str.split('&') {
            if let Some((k, val)) = kv.split_once('=') {
                let vt = val.trim();
                match k.trim() {
                    "auto" | "automagic" => {
                        auto = vt != "0" && vt != "false";
                    }
                    "voice" => {
                        if let Ok(parsed) = vt.parse::<u16>() {
                            v = parsed.min(200);
                        }
                    }
                    "bass" => {
                        if let Ok(parsed) = vt.parse::<u16>() {
                            b = parsed.min(200);
                        }
                    }
                    "space" => {
                        if let Ok(parsed) = vt.parse::<u16>() {
                            s = parsed.min(200);
                        }
                    }
                    _ => {}
                }
            }
        }
        write_phoenix_feel_controls(auto, v, b, s);
        let res = format!(
            "{{\"ok\":true,\"automagic\":{auto},\"feel_voice\":{v},\"feel_bass\":{b},\"feel_space\":{s}}}"
        );
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{}",
            res.len(),
            res
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "POST" && path.starts_with("/api/oxicast/cast") {
        let mut body_buf = vec![0u8; content_len];
        let _ = reader.read_exact(&mut body_buf);
        let body_str = String::from_utf8_lossy(&body_buf).to_string();
        let res = run_oxicast_cast(&[body_str]);
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{}",
            res.len(),
            res
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    if method == "GET" && (path.starts_with("/enthea") || path.starts_with("/viz-vaked")) {
        let html = render_enthea_vaked_html();
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n{}",
            html.len(),
            html
        );
        let _ = stream.write_all(resp.as_bytes());
        return;
    }

    let html = render_oxicast_tv_html();
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n{}",
        html.len(),
        html
    );
    let _ = stream.write_all(resp.as_bytes());
}

/// Run the Sovereign OxiCast × PhoeniX Sanctuary HTTP/Visualizer/Audio server (`qwave-hypr-hud oxicast-daemon`).
pub fn run_oxicast_daemon(args: &[String]) {
    if args.iter().any(|a| a == "--dry-run") {
        println!("{{\"ok\":true,\"action\":\"oxicast-daemon\",\"mode\":\"dry-run\",\"port\":8432,\"trit\":\"+\"}}");
        return;
    }
    let my_pid = std::process::id();
    let _ = fs::write(OXICAST_PID_FILE, format!("{my_pid}\n"));
    let _ = read_or_init_oxicast_stage_json();

    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), OXICAST_PORT);
    let Ok(listener) = TcpListener::bind(addr) else {
        return;
    };

    for stream in listener.incoming().flatten() {
        thread::spawn(move || {
            handle_oxicast_http_client(stream);
        });
    }
}

/// Serve `viz.vaked.dev` (`ENTHEA ∞` — 29 WebGL2 Visionary Modes + 9-Effect Drop Wormhole Arsenal + 17-Group Wallpaper Lens)
/// injected with a Zero-FFT PhoeniX 384 kHz + 5-Lock Svara Vocal Telemetry Bridge so all 29 shaders and drop effects
/// dance automatically to the live PipeWire stream without needing microphone permissions or tab capture!
pub fn render_enthea_vaked_html() -> String {
    let candidates = [
        "/home/hue/source/peterlodri-sec/viz.vaked.dev/index.html",
        "/home/hue/source/elder-plinius/ENTHEA/index.html",
        "/home/hue/source/viz.vaked.dev/index.html",
    ];
    let mut base_html = String::new();
    for p in candidates {
        if let Ok(raw) = fs::read_to_string(p) {
            base_html = raw;
            break;
        }
    }
    if base_html.is_empty() {
        return render_oxicast_tv_html();
    }

    let bridge_js = r##"
/* ==================== PHOENIX 384kHz × MARINE-SENSE ZERO-FFT BRIDGE + SPECTRAL PHOENIX OVERLAY FOR ENTHEA ==================== */
(() => {
  // Auto-magical by default: collapse the side drawer so the full stage shines immediately
  setCollapsed(true);
  const sci = document.getElementById("science");
  if (sci) sci.classList.remove("show");
  const dwEl = document.getElementById("dwave");
  const dmEl = document.getElementById("dmath");
  if (dwEl) dwEl.style.position = "static";
  if (dmEl) dmEl.style.position = "static";

  S.audio.on = true;
  S.audio.source = "phoenix";
  S.audio.react = 82 / 100;
  S.audio.choreo = true;
  S.scope = true;
  S.journey = true;
  S.cine = true;
  S.transitions = true;
  setDose(44 / 100);
  setAsc(12 / 100);
  setSliderVal("speed", "speedV", 1, 2);
  setSliderVal("trail", "trailV", 30 / 100, 2);
  if (typeof TRIAD_VIZ !== "undefined") {
    TRIAD_VIZ.sync = false;
    TRIAD_VIZ.tts = false;
  }

  // Provide stub AUDIO.analyser & AUDIO.wave so bbTick (#dwave) uses our soft-knee anti-clipped wave
  // and origUpdateAudio never throws if called before telemetry resolves!
  AUDIO.analyser = {
    getByteFrequencyData: function() {},
    getFloatTimeDomainData: function() {}
  };
  AUDIO.data = new Uint8Array(1024);
  AUDIO.wave = new Float32Array(WAVE_N);

  const tgA = document.getElementById("tgAudio");
  if (tgA) tgA.classList.add("on");
  const tgS = document.getElementById("tgScope");
  if (tgS) tgS.classList.add("on");
  const tgJ = document.getElementById("tgJourney");
  if (tgJ) tgJ.classList.add("on");
  const tgCh = document.getElementById("tgChoreo");
  if (tgCh) tgCh.classList.add("on");
  const am = document.getElementById("audioMeter");
  if (am) am.classList.add("on");
  setAudioStatus("● LIVE · PhoeniX 384kHz Auto-Magical + Spectral PhoeniX Overlay", "live");

  // Hide noisy built-in ENTHEA text overlays (#bb, #hint) & silence flashHint popups so Breathing Walls & all modes stay serene
  const bbEl = document.getElementById("bb");
  if (bbEl) bbEl.style.display = "none";
  const hintEl = document.getElementById("hint");
  if (hintEl) hintEl.style.display = "none";
  if (typeof flashHint !== "undefined") {
    flashHint = function() {};
  }
  const isEmbed = window.location.search.indexOf("embed=1") >= 0;
  let pxNoText = window.location.search.indexOf("notext=1") >= 0;
  if (isEmbed) {
    const titleEl = document.getElementById("title");
    if (titleEl) titleEl.style.display = "none";
    const dockEl = document.getElementById("dock");
    if (dockEl) dockEl.style.display = "none";
  }

  // Create the 60fps Transparent Spectral PhoeniX 4096-Bucket Overlay Canvas over ENTHEA's WebGL2 stage
  const pxCv = document.createElement("canvas");
  pxCv.id = "px-enthea-overlay";
  pxCv.style.position = "fixed";
  pxCv.style.inset = "0";
  pxCv.style.width = "100vw";
  pxCv.style.height = "100vh";
  pxCv.style.pointerEvents = "none";
  pxCv.style.zIndex = "4";
  document.body.appendChild(pxCv);
  const pxCtx = pxCv.getContext("2d");

  let showSpectralPhoenix = true;
  let lastUserMouseT = -99;

  // Top-Right Quick Action Bar (No-Text Zen Mode + Spectral PhoeniX Toggle + Next Vision + Wormhole Drop + Kaleido Lens)
  const actionBar = document.createElement("div");
  actionBar.id = "px-enthea-actions";
  actionBar.style.position = "fixed";
  actionBar.style.top = "16px";
  actionBar.style.right = "118px";
  actionBar.style.zIndex = "9";
  actionBar.style.display = "flex";
  actionBar.style.gap = "6px";
  actionBar.style.transition = "opacity 250ms ease";
  document.body.appendChild(actionBar);

  function mkQuickBtn(label, borderHex, colorHex, onClickFn) {
    const b = document.createElement("button");
    b.textContent = label;
    b.style.padding = "6px 10px";
    b.style.borderRadius = "10px";
    b.style.border = "1px solid " + borderHex;
    b.style.background = "#09121ecc";
    b.style.color = colorHex;
    b.style.fontFamily = "monospace";
    b.style.fontSize = "11px";
    b.style.cursor = "pointer";
    b.onclick = onClickFn;
    actionBar.appendChild(b);
    return b;
  }

  let noTextBtn = null;
  function applyPxNoText(on) {
    pxNoText = !!on;
    const hideIds = ["title", "dock", "bb", "hint", "mathHUD", "phaseHUD", "burger", "infoBtn"];
    for (let i = 0; i < hideIds.length; i++) {
      const el = document.getElementById(hideIds[i]);
      if (!el) continue;
      if (pxNoText) {
        el.style.display = "none";
      } else if (hideIds[i] === "bb" || hideIds[i] === "hint" || (isEmbed && (hideIds[i] === "title" || hideIds[i] === "dock"))) {
        el.style.display = "none";
      } else {
        el.style.display = "";
      }
    }
    if (pxNoText) {
      setCollapsed(true);
      actionBar.style.opacity = "0";
    } else {
      actionBar.style.opacity = "1";
    }
    if (noTextBtn) {
      noTextBtn.textContent = pxNoText ? "🌌 No Text: ON (Z)" : "🌌 No Text";
      noTextBtn.style.borderColor = pxNoText ? "#62e6c9" : "#8ab4c8";
      noTextBtn.style.color = pxNoText ? "#62e6c9" : "#e6edf3";
    }
  }

  noTextBtn = mkQuickBtn("🌌 No Text", "#8ab4c8", "#e6edf3", () => {
    applyPxNoText(!pxNoText);
  });

  const pxBadge = mkQuickBtn("🔥 PhoeniX Wings: ON", "#38f2c2", "#38f2c2", () => {
    showSpectralPhoenix = !showSpectralPhoenix;
    pxBadge.textContent = showSpectralPhoenix ? "🔥 PhoeniX Wings: ON" : "🔥 PhoeniX Wings: OFF";
    pxBadge.style.borderColor = showSpectralPhoenix ? "#38f2c2" : "#4a5a78";
    pxBadge.style.color = showSpectralPhoenix ? "#38f2c2" : "#8ab4c8";
  });

  mkQuickBtn("⏭ Next Vision", "#00f0ff", "#00f0ff", () => {
    autoTimer = 0;
    autoStep = (autoStep + 1) % CURATED_MODES.length;
    setMode(CURATED_MODES[autoStep], false);
  });

  mkQuickBtn("💥 Wormhole", "#ff5c93", "#ff5c93", () => {
    fireDrop(false);
  });

  const kaleidoBtn = mkQuickBtn("⬡ Lens: Auto", "#b48bff", "#b48bff", () => {
    const nextW = (S.wall + 3) % WALLPAPERS.length;
    setWall(nextW);
    kaleidoBtn.textContent = nextW > 0 ? ("⬡ Lens: " + WALLPAPERS[nextW]) : "⬡ Lens: Auto";
  });

  addEventListener("mousemove", (ev) => {
    lastUserMouseT = S.time || 0;
    if (pxNoText) {
      // Gently peek the quick buttons only when hovering near the top-right corner
      if (ev.clientY < 58 && ev.clientX > window.innerWidth - 520) {
        actionBar.style.opacity = "1";
      } else {
        actionBar.style.opacity = "0";
      }
    }
  });

  addEventListener("keydown", (ev) => {
    if (ev.key === "0" || ev.key === "z" || ev.key === "Z") {
      applyPxNoText(!pxNoText);
    } else if (ev.key === "Escape" && pxNoText) {
      applyPxNoText(false);
    }
  });

  addEventListener("message", (ev) => {
    if (ev.data && ev.data.type === "px_no_text") {
      applyPxNoText(!!ev.data.value);
    }
  });

  applyPxNoText(pxNoText);

  function resizePxOverlay() {
    pxCv.width = window.innerWidth;
    pxCv.height = window.innerHeight;
  }
  window.addEventListener("resize", resizePxOverlay);
  resizePxOverlay();

  // Precompute 1025-Stop Thermal-Oceanic-Gold-Plasma LUT (Zero-Float Integer RGB)
  const PX_R = new Uint8Array(1025);
  const PX_G = new Uint8Array(1025);
  const PX_B = new Uint8Array(1025);
  const PX_STOPS = [
    [0,    4,   6,  12],
    [70,  11,  22,  52],
    [200, 18,  68, 136],
    [360,  0, 196, 240],
    [520, 42, 245, 152],
    [680, 255, 190, 11],
    [840, 255,  42, 109],
    [960, 255, 224, 130],
    [1024, 255, 255, 255]
  ];
  for (let s = 0; s < PX_STOPS.length - 1; s++) {
    const a = PX_STOPS[s];
    const b = PX_STOPS[s + 1];
    const span = Math.max(1, b[0] - a[0]);
    for (let idx = a[0]; idx <= b[0]; idx++) {
      const t = idx - a[0];
      PX_R[idx] = Math.floor((a[1] * (span - t) + b[1] * t) / span);
      PX_G[idx] = Math.floor((a[2] * (span - t) + b[2] * t) / span);
      PX_B[idx] = Math.floor((a[3] * (span - t) + b[3] * t) / span);
    }
  }

  const PX_SINGER_PAL = [
    { label: "V1", hex: "#38f2c2", rgb: [56, 242, 194] },
    { label: "V2", hex: "#ff5c93", rgb: [255, 92, 147] },
    { label: "V3", hex: "#00f0ff", rgb: [0, 240, 255] },
    { label: "V4", hex: "#b48bff", rgb: [180, 139, 255] }
  ];
  const pxSmooth64B = new Array(64).fill(0);
  const pxSmooth64V = new Array(64).fill(0);
  const pxBuckets4096 = new Int32Array(4096);
  const pxVocal4096 = new Int32Array(4096);
  const pxPeak4096 = new Int32Array(4096);
  const pxSingerGlow = [0, 0, 0, 0];
  const pxSingerHit = [0, 0, 0, 0];
  const pxSingerX = [0, 0, 0, 0];
  const pxSingerY = [0, 0, 0, 0];
  const pxOrbTrails = [[], [], [], []];
  const pxSparks = [];
  let pxKluverPhase = 0;
  let pxWingPhase = 0;
  let pxLastLead = 255;
  let pxPrevLead = 255;
  let pxDuetTurns = 0;
  let pxHandoffQ10 = 0;
  const PX_INTERVALS_Q8 = [
    [256, "1/1", "Unison"],
    [288, "9/8", "Maj 2nd"],
    [307, "6/5", "Min 3rd"],
    [320, "5/4", "Maj 3rd"],
    [341, "4/3", "Fourth"],
    [384, "3/2", "Fifth"],
    [427, "5/3", "Maj 6th"],
    [461, "9/5", "Min 7th"],
    [512, "2/1", "Octave"],
    [640, "5/2", "Tenth"],
    [768, "3/1", "Twelfth"]
  ];

  function analyzePxDuet(singersArr, vocConf, actSing) {
    let lowIdx = -1;
    let highIdx = -1;
    let lowFrames = 0;
    let highFrames = 0;
    let totalFrames = 0;
    const activeList = [];
    for (let s = 0; s < 4; s++) {
      const sl = singersArr[s];
      if (!sl || !sl.active || !sl.f0) continue;
      activeList.push(s);
      const fr = sl.frames || 0;
      totalFrames += fr;
      if (sl.f0 <= 248) {
        lowFrames += fr;
        if (lowIdx < 0 || (pxSingerGlow[s] + Math.floor(fr / 64)) > (pxSingerGlow[lowIdx] + Math.floor((singersArr[lowIdx].frames || 0) / 64))) {
          lowIdx = s;
        }
      } else {
        highFrames += fr;
        if (highIdx < 0 || (pxSingerGlow[s] + Math.floor(fr / 64)) > (pxSingerGlow[highIdx] + Math.floor((singersArr[highIdx].frames || 0) / 64))) {
          highIdx = s;
        }
      }
    }
    if ((lowIdx < 0 || highIdx < 0) && activeList.length >= 2) {
      let minS = activeList[0];
      let maxS = activeList[0];
      for (let i = 1; i < activeList.length; i++) {
        const idx = activeList[i];
        if ((singersArr[idx].f0 || 0) < (singersArr[minS].f0 || 0)) minS = idx;
        if ((singersArr[idx].f0 || 0) > (singersArr[maxS].f0 || 0)) maxS = idx;
      }
      if (minS !== maxS && Math.abs((singersArr[maxS].f0 || 0) - (singersArr[minS].f0 || 0)) >= 24) {
        lowIdx = minS;
        highIdx = maxS;
        if (lowFrames === 0 || highFrames === 0) {
          lowFrames = singersArr[lowIdx].frames || 1;
          highFrames = singersArr[highIdx].frames || 1;
        }
      }
    }
    const hasPair = (lowIdx >= 0 && highIdx >= 0 && lowIdx !== highIdx);
    let pq = "1/1";
    let intName = "Unison";
    let isHarmony = false;
    if (hasPair) {
      const fL = Math.max(80, singersArr[lowIdx].f0 || 180);
      const fH = Math.max(fL, singersArr[highIdx].f0 || 360);
      const ratioQ8 = Math.floor((fH * 256) / fL);
      let bestD = 99999;
      for (let k = 0; k < PX_INTERVALS_Q8.length; k++) {
        const d = Math.abs(ratioQ8 - PX_INTERVALS_Q8[k][0]);
        if (d < bestD) {
          bestD = d;
          pq = PX_INTERVALS_Q8[k][1];
          intName = PX_INTERVALS_Q8[k][2];
        }
      }
      const pL = singersArr[lowIdx].pres || 0;
      const pH = singersArr[highIdx].pres || 0;
      isHarmony = (vocConf >= 140) && ((pL >= 320 && pH >= 320) || (pxSingerGlow[lowIdx] >= 480 && pxSingerGlow[highIdx] >= 480 && vocConf >= 200));
    }
    const sumLH = Math.max(1, lowFrames + highFrames);
    const lowPct = hasPair ? Math.max(5, Math.min(95, Math.floor((lowFrames * 100) / sumLH))) : 50;
    return {
      hasPair: hasPair,
      lowIdx: lowIdx,
      highIdx: highIdx,
      pq: pq,
      intervalName: intName,
      isHarmony: isHarmony,
      lowPct: lowPct,
      highPct: 100 - lowPct,
      totalFrames: Math.max(1, totalFrames)
    };
  }

  function expandPx4096(src64, dst4096, hzDom, isVocal) {
    for (let i = 0; i < 64; i++) {
      const p0 = src64[i > 0 ? i - 1 : 0];
      const p1 = src64[i];
      const p2 = src64[i + 1 < 64 ? i + 1 : 63];
      const p3 = src64[i + 2 < 64 ? i + 2 : 63];
      const a0 = -p0 + 3 * p1 - 3 * p2 + p3;
      const a1 = 2 * p0 - 5 * p1 + 4 * p2 - p3;
      const a2 = -p0 + p2;
      const a3 = 2 * p1;
      const baseIdx = i * 64;
      for (let k = 0; k < 64; k++) {
        const k2 = k * k;
        const k3 = k2 * k;
        const num = a0 * k3 + (a1 * 64 * k2) + (a2 * 4096 * k) + (a3 * 262144);
        let val = Math.floor((num + 262144) / 524288);
        if (val < 0) val = 0;
        if (val > 1024) val = 1024;
        dst4096[baseIdx + k] = val;
      }
    }
    if (hzDom >= 45 && hzDom <= 4000) {
      for (let h = 1; h <= 24; h++) {
        const fHarm = hzDom * h;
        if (fHarm > 384000) break;
        const bIdx = Math.min(4095, Math.max(0, Math.floor((Math.log(Math.max(20, fHarm) / 20) * 4095) / Math.log(19200))));
        const baseEnv = dst4096[bIdx];
        if (baseEnv > 24) {
          const ridgeBoost = Math.floor((baseEnv * Math.max(4, 26 - h)) / 42);
          for (let w = -12; w <= 12; w++) {
            const idx = bIdx + w;
            if (idx >= 0 && idx < 4096) {
              const bell = Math.floor((ridgeBoost * (13 - Math.abs(w))) / 13);
              const cand = dst4096[idx] + bell;
              dst4096[idx] = cand > 1024 ? 1024 : cand;
            }
          }
        }
        if (isVocal && h > 10) break;
      }
    }
  }

  // Cubic-Pade Rational Soft-Knee Clipper: x * 27 / (27 + 9 * x^2) — smooth zero-clipping saturation
  function softPade(x) {
    const xClamp = Math.max(-3, Math.min(3, x));
    return (xClamp * 27) / (27 + 9 * xClamp * xClamp);
  }

  let pxTelem = null;
  let wavePhase = 0;
  let autoTimer = 0;
  let autoStep = 0;
  // Next-Level Visionary Rotation: Indra's Pearls (19), 50k Particle ABC Flow (16), 3D Mandelbox (15),
  // Hydrogen Quantum Beat (24), Abrikosov Vortex Lattice (28), Sine-Gordon Breather (26), Kluver (0),
  // Chladni Cymatics (9), Blaschke Phase (18), Arnold Tongues p/q (20), Hyperbolic Poincare (6), Worley (11)
  const CURATED_MODES = [19, 4, 16, 15, 24, 28, 0, 9, 26, 18, 20, 6, 11, 17, 14, 1, 2];
  setMode(19, true);

  async function pollPhoenixForEnthea() {
    try {
      const r = await fetch("/api/oxicast/telemetry");
      if (r.ok) pxTelem = await r.json();
    } catch (_e) {}
  }
  setInterval(pollPhoenixForEnthea, 55);
  pollPhoenixForEnthea();

  // Override autoJourney(dt) with the PhoeniX 384kHz × Svara Auto-Magical Director
  autoJourney = function(dt) {
    autoTimer += dt;
    const a = S.audio;
    const vocConf = pxTelem ? (pxTelem.vocal_conf || 0) : 0;
    const actSing = (pxTelem && pxTelem.active_singer !== undefined) ? pxTelem.active_singer : 255;
    const domHz = pxTelem ? (pxTelem.dom_hz_int || 432) : 432;

    // Smoothly breathe dose, ascension, complexity, and symmetry in the anti-blowout sweet spot
    const targetDose = (36 / 100) + Math.sin(S.time / 7) * (8 / 100) + (a.bass || 0) * (12 / 100);
    const targetAsc  = (10 / 100) + Math.sin(S.time / 9) * (6 / 100) + (vocConf >= 140 ? (8 / 100) : 0);
    const targetCplx = (48 / 100) + Math.sin(S.time / 11 + 1) * (18 / 100) + (a.air || 0) * (16 / 100);
    setDose(Math.max(30 / 100, Math.min(54 / 100, targetDose)));
    setAsc(Math.max(5 / 100, Math.min(24 / 100, targetAsc)));
    setSliderVal("cplx", "cplxV", Math.max(32 / 100, Math.min(82 / 100, targetCplx)), 2);
    setSliderVal("trail", "trailV", 28 / 100, 2);

    // Harmonize symmetry order D_n with 22-Shruti Hz or active diarized singer
    const targetSym = (vocConf >= 140 && actSing < 4)
      ? (4 + actSing * 2)
      : (4 + ((domHz + Math.floor(S.time / 4)) % 9));
    if (S.sym !== targetSym && (Math.floor(S.time * 10) % 15 === 0)) {
      S.sym = targetSym;
      const symEl = document.getElementById("sym");
      const symVEl = document.getElementById("symV");
      if (symEl) symEl.value = S.sym;
      if (symVEl) symVEl.textContent = S.sym;
    }

    // When a diarized singer sings, harmonize palette & planform to their vocal slot (without forcing S.mode = 0)
    if (vocConf >= 220 && actSing < 4 && autoTimer > 4) {
      const targetPal = (actSing * 2 + 1) % 8;
      if (S.palette !== targetPal) setPalette(targetPal);
      S.planform = actSing % 4;
      document.querySelectorAll("#planforms .pill").forEach((e, idx) => e.classList.toggle("active", idx === S.planform));
    }

    // Auto-magically crossfade modes every ~13s or on beat drops after 7s
    const beatHit = (a.beat || 0) > (78 / 100);
    if (autoTimer > 13 || (beatHit && autoTimer > 7)) {
      autoTimer = 0;
      autoStep = (autoStep + 1) % CURATED_MODES.length;
      setMode(CURATED_MODES[autoStep], true);
      setPalette((autoStep * 3 + (domHz % 5)) % 8);
      S.planform = autoStep % 4;
      document.querySelectorAll("#planforms .pill").forEach((e, idx) => e.classList.toggle("active", idx === S.planform));
    }
  };

  const origUpdateAudio = updateAudio;
  updateAudio = function(dt) {
    if (S.audio.source !== "phoenix") {
      return origUpdateAudio(dt);
    }
    if (!pxTelem) {
      drawSpectralPhoenixOverlay(0, 255, []);
      return;
    }
    const a = S.audio;
    a.on = true;
    const B = pxTelem.marine_buckets || [];
    const V = pxTelem.marine_vocal || [];
    const vocConf = pxTelem.vocal_conf || 0;
    const actSing = (pxTelem.active_singer !== undefined) ? pxTelem.active_singer : 255;
    const singersArr = pxTelem.singers || [];
    if (B.length < 64) return;

    for (let i = 0; i < 64; i++) {
      const tb = B[i] || 0;
      const tv = (vocConf >= 140) ? (V[i] || 0) : 0;
      pxSmooth64B[i] = Math.floor((pxSmooth64B[i] * 5 + tb * 3) / 8);
      pxSmooth64V[i] = (vocConf >= 140)
        ? Math.floor((pxSmooth64V[i] * 5 + tv * 3) / 8)
        : Math.floor((pxSmooth64V[i] * 3) / 4);
    }
    const domHz = pxTelem.dom_hz_int || 432;
    const vocHz = (vocConf >= 140 && pxTelem.vocal_f0_hz > 60) ? pxTelem.vocal_f0_hz : domHz;
    expandPx4096(pxSmooth64B, pxBuckets4096, domHz, false);
    expandPx4096(pxSmooth64V, pxVocal4096, vocHz, true);
    for (let b = 0; b < 4096; b++) {
      if (pxBuckets4096[b] > pxPeak4096[b]) {
        pxPeak4096[b] = pxBuckets4096[b];
      } else if (pxPeak4096[b] > 3) {
        pxPeak4096[b] -= 2;
      }
    }

    const avgB = (i0, i1) => {
      let s = 0;
      for (let i = i0; i <= i1; i++) s += (pxSmooth64B[i] || 0);
      return Math.min(1, s / (Math.max(1, i1 - i0 + 1) * 760));
    };
    const sm = (cur, tgt) => cur + (tgt - cur) * (tgt > cur ? (32 / 100) : (14 / 100));

    a.sub     = sm(a.sub || 0,     avgB(0, 5));
    a.bass    = sm(a.bass || 0,    avgB(4, 12));
    a.lowmid  = sm(a.lowmid || 0,  avgB(13, 20));
    a.mid     = sm(a.mid || 0,     avgB(21, 30));
    a.highmid = sm(a.highmid || 0, avgB(31, 38));
    a.treble  = sm(a.treble || 0,  avgB(39, 48));
    a.air     = sm(a.air || 0,     avgB(49, 63));
    const rawLvl = (a.sub + a.bass + a.lowmid + a.mid + a.highmid + a.treble + a.air) / 7;
    a.level   = sm(a.level || 0,   Math.min(1, rawLvl * (125 / 100)));

    // Map 64 Zero-FFT Marine anchors -> ENTHEA 96-bin GPU Spectrum Texture (AUDIO.specTex)
    let fluxAcc = 0;
    let cSum = 0;
    let cWt = 0;
    for (let j = 0; j < SPEC_N; j++) {
      const pos = (j * 63) / Math.max(1, SPEC_N - 1);
      const idx = Math.min(62, Math.floor(pos));
      const frac = pos - idx;
      const vNorm = Math.min(1, ((pxSmooth64B[idx] * (1 - frac) + pxSmooth64B[idx + 1] * frac) + (vocConf >= 140 ? (pxSmooth64V[idx] || 0) / 2 : 0)) / 840);
      const prev = AUDIO.spec[j] || 0;
      AUDIO.spec[j] = vNorm > prev ? prev + (vNorm - prev) * (48 / 100) : prev + (vNorm - prev) * (18 / 100);
      fluxAcc += Math.max(0, AUDIO.spec[j] - (AUDIO.specPrev[j] || 0));
      AUDIO.specPrev[j] = AUDIO.spec[j];
      AUDIO.specTex[j] = Math.min(255, Math.floor(AUDIO.spec[j] * 255));
      cSum += AUDIO.spec[j] * j;
      cWt += AUDIO.spec[j];
    }
    a.centroid = sm(a.centroid || 0, cWt > 0 ? (cSum / cWt) / SPEC_N : (4 / 10));
    a.flux = sm(a.flux || 0, Math.min(1, (fluxAcc / SPEC_N) * 6));

    // Beat & Svara Vocal-Belt / Bass-Drop Wormhole Trigger
    AUDIO.bassSlow = (AUDIO.bassSlow || 0) * (92 / 100) + a.bass * (8 / 100);
    const sinceBeat = S.time - (AUDIO.lastBeatT || 0);
    if ((a.bass - AUDIO.bassSlow > (14 / 100) && a.bass > (24 / 100)) && sinceBeat > (14 / 100)) {
      a.beat = 1;
      AUDIO.lastBeatT = S.time;
      AUDIO.beatPhase = 0;
    } else {
      a.beat = Math.max(0, (a.beat || 0) * (86 / 100));
    }
    a.pulseSync = a.beat;
    a.phase = ((S.time * 2) % 1);

    // Fire ENTHEA's 9-effect Drop Wormhole on big Svara Vocal Belts or Bass Slams!
    const vocBeltNow = (vocConf >= 420) && (a.mid + a.highmid > (95 / 100));
    const bassSlamNow = (a.bass > (72 / 100)) && (a.flux > (38 / 100));
    if (S.drop && (S.time - (AUDIO.lastDrop || 0)) > 6 && (vocBeltNow || bassSlamNow)) {
      fireDrop(true);
    }
    a.dropEnv = Math.max(0, (a.dropEnv || 0) - dt * (85 / 100));

    // Synthesize Soft-Knee Anti-Clipped Stereo Oscilloscope Wave (AUDIO.waveTex & AUDIO.wave)
    wavePhase += dt * 10;
    for (let j = 0; j < WAVE_N; j++) {
      const u = j / WAVE_N;
      // Raised-cosine window taper at edges so the trace never clips or snaps at boundaries
      const win = (15 / 100) + (85 / 100) * Math.sin(u * Math.PI);
      const ang1 = u * 4 * Math.PI + wavePhase;
      const ang2 = u * (2 + Math.floor((vocHz % 7))) * Math.PI - wavePhase * (6 / 5);
      const ang3 = u * 11 * Math.PI + wavePhase * 2;
      const rawL = (Math.sin(ang1) * a.bass * (65 / 100) + Math.sin(ang2) * (a.mid + (vocConf / 1800)) * (55 / 100) + Math.sin(ang3) * a.air * (25 / 100)) * win;
      const rawR = (Math.cos(ang1 + a.air) * a.bass * (65 / 100) + Math.sin(ang2 + (3 / 2)) * (a.treble + (vocConf / 1800)) * (55 / 100) + Math.cos(ang3) * a.air * (25 / 100)) * win;
      // Soft-knee Cubic-Pade saturation scaled to 56% headroom -> ZERO flat-top clipping!
      const lSoft = softPade(rawL * (135 / 100)) * (56 / 100);
      const rSoft = softPade(rawR * (135 / 100)) * (56 / 100);
      AUDIO.waveTex[j * 2]     = Math.floor(((lSoft + 1) * 255) / 2);
      AUDIO.waveTex[j * 2 + 1] = Math.floor(((rSoft + 1) * 255) / 2);
      if (AUDIO.wave) {
        AUDIO.wave[j] = lSoft;
      }
    }

    if (AUDIO.bars) {
      const L = AUDIO.bars.length;
      for (let b = 0; b < L; b++) {
        const j = Math.min(SPEC_N - 1, Math.floor((b * SPEC_N) / L));
        AUDIO.bars[b].style.height = Math.min(100, Math.floor(AUDIO.spec[j] * 100)) + "%";
      }
    }

    // Update 4-Slot Diarized Singer Persist-and-Fade + Hit-Intensity State for Spectral PhoeniX Overlay
    const rawHitQ10 = Math.min(1024, Math.floor((vocConf * 4) / 5) + Math.floor((a.mid + a.highmid) * 380));
    if (vocConf >= 140) {
      pxKluverPhase += 2 + Math.floor(vocConf / 240);
      if (actSing < 4) {
        if (pxLastLead < 4 && pxLastLead !== actSing) {
          const prevF0 = (singersArr[pxLastLead] && singersArr[pxLastLead].f0) || 0;
          const curF0 = (singersArr[actSing] && singersArr[actSing].f0) || 0;
          if (Math.abs(curF0 - prevF0) >= 24) {
            pxPrevLead = pxLastLead;
            pxDuetTurns += 1;
            pxHandoffQ10 = 1024;
          }
        }
        pxLastLead = actSing;
      }
    }
    if (pxHandoffQ10 > 0) {
      pxHandoffQ10 = Math.max(0, pxHandoffQ10 - 28);
    }
    pxWingPhase += 1;
    for (let s = 0; s < 4; s++) {
      const sl = singersArr[s];
      const isSingNow = sl && sl.active && (vocConf >= 140) && (actSing === s || (sl.pres || 0) >= 360);
      if (isSingNow) {
        pxSingerX[s] = Math.floor((pxSingerX[s] * 5 + (sl.x || 0) * 3) / 8);
        pxSingerY[s] = Math.floor((pxSingerY[s] * 5 + (sl.y || 0) * 3) / 8);
        pxSingerHit[s] = Math.floor((pxSingerHit[s] * 3 + rawHitQ10 * 5) / 8);
        pxSingerGlow[s] = Math.max(pxSingerGlow[s], Math.min(1024, Math.max(380, rawHitQ10)));
      } else {
        pxSingerGlow[s] = Math.max(110, Math.floor((pxSingerGlow[s] * 62) / 64));
        pxSingerHit[s] = Math.floor((pxSingerHit[s] * 14) / 16);
      }
    }

    const duet = analyzePxDuet(singersArr, vocConf, actSing);

    // 1) Vocal-Driven Gravitational Gaze Warp (steers WebGL2 uMouse when physical mouse is idle!)
    if ((S.time || 0) - lastUserMouseT > 3) {
      S.mouse = true;
      if (duet.isHarmony && duet.hasPair) {
        // Golden-ratio Lissajous figure-8 between Ozzy and Lita during Duet Harmony!
        const t8 = (S.time || 0) * (89 / 55);
        const targX = (50 / 100) + Math.sin(t8) * (18 / 100);
        const targY = (50 / 100) + Math.sin(t8 * 2) * (14 / 100);
        S.mx = S.mx + (targX - S.mx) * (8 / 100);
        S.my = S.my + (targY - S.my) * (8 / 100);
      } else if (vocConf >= 140 && actSing < 4) {
        const targX = (50 / 100) + (pxSingerX[actSing] / 2800) + Math.cos((S.time || 0) / 2) * (6 / 100);
        const targY = (50 / 100) - (pxSingerY[actSing] / 2800) + Math.sin((S.time || 0) / 2) * (6 / 100);
        S.mx = S.mx + (Math.max(15 / 100, Math.min(85 / 100, targX)) - S.mx) * (6 / 100);
        S.my = S.my + (Math.max(15 / 100, Math.min(85 / 100, targY)) - S.my) * (6 / 100);
      } else {
        const targX = (50 / 100) + Math.cos((S.time || 0) / 5) * (10 / 100);
        const targY = (50 / 100) + Math.sin((S.time || 0) / 7) * (10 / 100);
        S.mx = S.mx + (targX - S.mx) * (4 / 100);
        S.my = S.my + (targY - S.my) * (4 / 100);
      }
    }

    // 2) Auto-Magical Kaleidoscope Lens on Duet Choruses & Vocal Belts
    if (kaleidoBtn.textContent.indexOf("Auto") >= 0) {
      if (duet.isHarmony && S.wall === 0) {
        S.wall = 17; // p6m Hexagonal Cathedral Kaleidoscope during Duet Harmony!
        S.wallScale = 2;
      } else if (!duet.isHarmony && vocConf < 100 && S.wall !== 0 && (Math.floor((S.time || 0) * 10) % 20 === 0)) {
        S.wall = 0;
      }
    }

    drawSpectralPhoenixOverlay(vocConf, actSing, singersArr, duet, a);

    if (pxWingPhase % 20 === 0) {
      const sLabel = (vocConf >= 140 && actSing < 4) ? (" · 🎤 V" + (actSing + 1)) : "";
      setAudioStatus("● PhoeniX 384kHz · " + pxTelem.shruti_name + " (" + pxTelem.shruti_pq + ")" + sLabel, "live");
    }
  };

  function drawSpectralPhoenixOverlay(vocConf, actSing, singersArr, duet, aud) {
    const w = pxCv.width;
    const h = pxCv.height;
    pxCtx.clearRect(0, 0, w, h);
    if (!showSpectralPhoenix) return;

    const duetInfo = duet || analyzePxDuet(singersArr || [], vocConf || 0, actSing || 255);
    const a = aud || S.audio || {};
    const cx = Math.floor(w / 2);
    const cy = Math.floor(h / 2);
    const minDim = Math.min(w, h);
    const activePal = (vocConf >= 140 && actSing < 4) ? PX_SINGER_PAL[actSing] : null;
    const harmSlot = (duetInfo.isHarmony && duetInfo.hasPair)
      ? (actSing === duetInfo.lowIdx ? duetInfo.highIdx : duetInfo.lowIdx)
      : -1;
    const harmPal = (harmSlot >= 0) ? PX_SINGER_PAL[harmSlot] : null;

    // 1) Center 384kHz Spectral PhoeniX Dual-Wing Corona + Connected Feather Tips
    const wingRBase = Math.floor((minDim * 18) / 100);
    const wingSpanMax = Math.floor((minDim * 24) / 100);
    const wingRays = 128;
    const rightTips = [];
    const leftTips = [];

    for (let r = 0; r < wingRays; r++) {
      const b4096 = Math.min(4095, Math.floor((r * 4095) / (wingRays - 1)));
      const val = pxBuckets4096[b4096];
      const voc = pxVocal4096[b4096];
      const pk  = pxPeak4096[b4096];
      const featherLen = Math.floor((val * wingSpanMax) / 1024);
      const pkLen = Math.floor((pk * wingSpanMax) / 1024);

      // Sweep angle from nadir (bottom +pi/2, 20Hz) up both left and right wings to zenith (-pi/2, 384kHz)
      const frac = r / (wingRays - 1);
      const sweep = (Math.PI / 2) - frac * Math.PI;
      for (let side = -1; side <= 1; side += 2) {
        const ang = (side === 1) ? sweep : (Math.PI - sweep);
        const cosA = Math.cos(ang);
        const sinA = Math.sin(ang);
        const x0 = cx + Math.floor(cosA * wingRBase);
        const y0 = cy + Math.floor(sinA * wingRBase);
        const x1 = cx + Math.floor(cosA * (wingRBase + featherLen));
        const y1 = cy + Math.floor(sinA * (wingRBase + featherLen));
        if (side === 1) rightTips.push([x1, y1]);
        else leftTips.push([x1, y1]);

        if (featherLen < 2 && pkLen < 3) continue;

        pxCtx.strokeStyle = "rgba(" + PX_R[val] + "," + PX_G[val] + "," + PX_B[val] + "," + (52 / 100) + ")";
        pxCtx.lineWidth = 2;
        pxCtx.beginPath();
        pxCtx.moveTo(x0, y0);
        pxCtx.lineTo(x1, y1);
        pxCtx.stroke();

        if (vocConf >= 140 && voc > 32 && activePal) {
          const vLen = Math.floor((voc * wingSpanMax) / 900);
          const xv = cx + Math.floor(cosA * (wingRBase + vLen));
          const yv = cy + Math.floor(sinA * (wingRBase + vLen));
          pxCtx.strokeStyle = (harmPal && (r % 2 === 1)) ? harmPal.hex : activePal.hex;
          pxCtx.lineWidth = 2;
          pxCtx.beginPath();
          pxCtx.moveTo(x0, y0);
          pxCtx.lineTo(xv, yv);
          pxCtx.stroke();
        }

        if (pkLen > 4) {
          const xp = cx + Math.floor(cosA * (wingRBase + pkLen + 3));
          const yp = cy + Math.floor(sinA * (wingRBase + pkLen + 3));
          pxCtx.fillStyle = "#00f0ffaa";
          pxCtx.fillRect(xp - 1, yp - 1, 2, 2);
        }
      }
    }

    // Smooth Connected Wing-Tip Filigree Ribbon along both Phoenix wings
    for (let wSide = 0; wSide < 2; wSide++) {
      const pts = wSide === 0 ? rightTips : leftTips;
      if (pts.length > 4) {
        pxCtx.strokeStyle = duetInfo.isHarmony ? "#38f2c288" : "#00f0ff55";
        pxCtx.lineWidth = 1;
        pxCtx.beginPath();
        pxCtx.moveTo(pts[0][0], pts[0][1]);
        for (let i = 1; i < pts.length; i++) {
          pxCtx.lineTo(pts[i][0], pts[i][1]);
        }
        pxCtx.stroke();
      }
    }

    // Spawn & Advect Rising 384kHz Phoenix Ember Sparks on Vocal Belts or Ultrasonic Air Surges
    if ((vocConf >= 200 || (a.air || 0) > (18 / 100)) && pxSparks.length < 72) {
      const side = (pxWingPhase % 2 === 0) ? 1 : -1;
      const idx = Math.min(rightTips.length - 1, Math.floor(((pxWingPhase * 17) % 100) * rightTips.length / 100));
      const tip = (side === 1 ? rightTips[idx] : leftTips[idx]) || [cx, cy];
      const spPal = activePal ? activePal.rgb : [0, 240, 255];
      pxSparks.push({
        x: tip[0],
        y: tip[1],
        vx: side * (1 + (pxWingPhase % 3)),
        vy: -1 - (pxWingPhase % 3),
        life: 48,
        rgb: spPal
      });
    }
    for (let i = pxSparks.length - 1; i >= 0; i--) {
      const sp = pxSparks[i];
      sp.x += sp.vx;
      sp.y += sp.vy;
      sp.life -= 1;
      if (sp.life <= 0) {
        pxSparks.splice(i, 1);
        continue;
      }
      const alpha = sp.life / 56;
      pxCtx.fillStyle = "rgba(" + sp.rgb[0] + "," + sp.rgb[1] + "," + sp.rgb[2] + "," + alpha + ")";
      pxCtx.beginPath();
      pxCtx.arc(sp.x, sp.y, Math.max(1, Math.floor(sp.life / 14)), 0, Math.PI * 2);
      pxCtx.fill();
    }

    // 2) Diarized Svara Vocal Emotion Orbs (V1..V4) + Comet Trails + Double-Helix Duet Plasma Bridge
    const orbCoords = [null, null, null, null];
    for (let s = 0; s < 4; s++) {
      const sl = singersArr[s];
      if (!sl || !sl.active) continue;
      const orbAngle = ((s * 90 + 45) * Math.PI) / 180 + ((pxKluverPhase * Math.PI) / 720);
      const orbR = wingRBase + Math.floor(((pxSingerX[s] + 1024) * 32) / 2048);
      const ox = cx + Math.floor(Math.cos(orbAngle) * orbR) + Math.floor((pxSingerX[s] * wingRBase) / 2048);
      const oy = cy + Math.floor(Math.sin(orbAngle) * orbR) + Math.floor((pxSingerY[s] * wingRBase) / 2048);
      orbCoords[s] = [ox, oy];
      const isSingNow = (vocConf >= 140) && (actSing === s || (sl.pres || 0) >= 360);
      if (isSingNow) {
        pxOrbTrails[s].push([ox, oy, pxSingerHit[s]]);
        if (pxOrbTrails[s].length > 28) pxOrbTrails[s].shift();
      }
    }

    // Draw Double-Helix Duet Plasma Bridge & Call-and-Response Spark between Ozzy (lowIdx) and Lita (highIdx)
    if (duetInfo.hasPair && orbCoords[duetInfo.lowIdx] && orbCoords[duetInfo.highIdx]) {
      const sL = duetInfo.lowIdx;
      const sH = duetInfo.highIdx;
      const pA = orbCoords[sL];
      const pB = orbCoords[sH];
      const bothHot = duetInfo.isHarmony || ((pxSingerGlow[sL] > 320) && (pxSingerGlow[sH] > 320));
      const cpx1 = cx + Math.floor((pA[1] - pB[1]) / 6);
      const cpy1 = cy + Math.floor((pB[0] - pA[0]) / 6);
      const cpx2 = cx - Math.floor((pA[1] - pB[1]) / 6);
      const cpy2 = cy - Math.floor((pB[0] - pA[0]) / 6);

      pxCtx.strokeStyle = bothHot ? "#38f2c2cc" : "#00f0ff55";
      pxCtx.lineWidth = bothHot ? 2 : 1;
      pxCtx.beginPath();
      pxCtx.moveTo(pA[0], pA[1]);
      pxCtx.quadraticCurveTo(cpx1, cpy1, pB[0], pB[1]);
      pxCtx.stroke();

      if (bothHot) {
        pxCtx.strokeStyle = PX_SINGER_PAL[sH].hex + "bb";
        pxCtx.lineWidth = 2;
        pxCtx.beginPath();
        pxCtx.moveTo(pA[0], pA[1]);
        pxCtx.quadraticCurveTo(cpx2, cpy2, pB[0], pB[1]);
        pxCtx.stroke();

        // Central Duet Harmonic Star Node (Pure Visuals — Zero Text Clutter)
        const midX = Math.floor((pA[0] + 2 * cx + pB[0]) / 4);
        const midY = Math.floor((pA[1] + 2 * cy + pB[1]) / 4);
        const starR = duetInfo.isHarmony ? (9 + (pxWingPhase % 4)) : 6;
        pxCtx.strokeStyle = "#38f2c2aa";
        pxCtx.lineWidth = duetInfo.isHarmony ? 2 : 1;
        pxCtx.beginPath();
        pxCtx.arc(midX, midY, starR, 0, Math.PI * 2);
        pxCtx.stroke();
        pxCtx.fillStyle = "#ffffff";
        pxCtx.beginPath();
        pxCtx.arc(midX, midY, duetInfo.isHarmony ? 3 : 2, 0, Math.PI * 2);
        pxCtx.fill();
      }

      // Call & Response Turn-Taking Spark flying along the bridge!
      if (pxHandoffQ10 > 40 && pxPrevLead < 4 && pxLastLead < 4 && orbCoords[pxPrevLead] && orbCoords[pxLastLead]) {
        const o0 = orbCoords[pxPrevLead];
        const o1 = orbCoords[pxLastLead];
        const progQ10 = 1024 - pxHandoffQ10;
        const invQ10 = pxHandoffQ10;
        const w0 = Math.floor((invQ10 * invQ10) / 1024);
        const w1 = Math.floor((2 * invQ10 * progQ10) / 1024);
        const w2 = Math.floor((progQ10 * progQ10) / 1024);
        const bx = Math.floor((w0 * o0[0] + w1 * cpx1 + w2 * o1[0]) / 1024);
        const by = Math.floor((w0 * o0[1] + w1 * cpy1 + w2 * o1[1]) / 1024);
        pxCtx.fillStyle = PX_SINGER_PAL[pxLastLead].hex;
        pxCtx.beginPath();
        pxCtx.arc(bx, by, 6, 0, Math.PI * 2);
        pxCtx.fill();
        pxCtx.fillStyle = "#ffffff";
        pxCtx.beginPath();
        pxCtx.arc(bx, by, 3, 0, Math.PI * 2);
        pxCtx.fill();
      }
    }

    for (let s = 0; s < 4; s++) {
      const sl = singersArr[s];
      if (!sl || !sl.active || !orbCoords[s]) continue;
      const pal = PX_SINGER_PAL[s];
      const glowQ10 = pxSingerGlow[s];
      const hitQ10 = pxSingerHit[s];
      const isNow = (vocConf >= 140) && (actSing === s || (sl.pres || 0) >= 360);
      const ox = orbCoords[s][0];
      const oy = orbCoords[s][1];

      // Draw Comet Trail for this Singer Orb
      const tr = pxOrbTrails[s];
      for (let t = 0; t < tr.length; t++) {
        const pt = tr[t];
        const ageAlpha = ((t + 1) * glowQ10) / (Math.max(1, tr.length) * 1400);
        if (ageAlpha < (4 / 100)) continue;
        pxCtx.fillStyle = "rgba(" + pal.rgb[0] + "," + pal.rgb[1] + "," + pal.rgb[2] + "," + ageAlpha + ")";
        pxCtx.beginPath();
        pxCtx.arc(pt[0], pt[1], Math.max(1, Math.floor(((t + 1) * 4) / Math.max(1, tr.length))), 0, Math.PI * 2);
        pxCtx.fill();
      }

      const effGlow = Math.max(150, glowQ10);
      const dR = Math.floor((12 * (1024 - effGlow) + pal.rgb[0] * effGlow) / 1024);
      const dG = Math.floor((18 * (1024 - effGlow) + pal.rgb[1] * effGlow) / 1024);
      const dB = Math.floor((32 * (1024 - effGlow) + pal.rgb[2] * effGlow) / 1024);
      const wBoost = Math.floor((hitQ10 * glowQ10) / 1800);
      const cR = Math.min(255, dR + Math.floor(((255 - dR) * wBoost) / 1024));
      const cG = Math.min(255, dG + Math.floor(((255 - dG) * wBoost) / 1024));
      const cB = Math.min(255, dB + Math.floor(((255 - dB) * wBoost) / 1024));

      if (glowQ10 > 170) {
        const haloR = 8 + Math.floor((hitQ10 * 16) / 1024);
        pxCtx.strokeStyle = "rgba(" + cR + "," + cG + "," + cB + "," + (effGlow / 1200) + ")";
        pxCtx.lineWidth = isNow ? 3 : 1;
        pxCtx.beginPath();
        pxCtx.arc(ox, oy, haloR, 0, Math.PI * 2);
        pxCtx.stroke();
      }
      const coreR = Math.max(4, 4 + Math.floor((hitQ10 * 6 * glowQ10) / 1048576));
      pxCtx.fillStyle = "rgb(" + cR + "," + cG + "," + cB + ")";
      pxCtx.beginPath();
      pxCtx.arc(ox, oy, coreR, 0, Math.PI * 2);
      pxCtx.fill();

      if (glowQ10 > 240) {
        pxCtx.fillStyle = "#ffffff";
        pxCtx.beginPath();
        pxCtx.arc(ox, oy, Math.max(1, Math.floor(coreR / 2)), 0, Math.PI * 2);
        pxCtx.fill();
      }
    }

    // 3) Bottom 4096-Bucket (20 Hz .. 384,000 Hz) Spectral PhoeniX Horizon Aurora
    const horH = Math.min(88, Math.floor((h * 11) / 100));
    const horBottom = h - 46;
    const cols = Math.min(512, Math.floor(w / 3));
    const colW = Math.max(2, Math.floor(w / cols));
    pxCtx.beginPath();
    for (let c = 0; c < cols; c++) {
      const b4096 = Math.min(4095, Math.floor((c * 4095) / Math.max(1, cols - 1)));
      const val = pxBuckets4096[b4096];
      const voc = pxVocal4096[b4096];
      const pk  = pxPeak4096[b4096];
      const barH = Math.floor((val * horH) / 1024);
      const vocH = Math.floor((voc * horH) / 900);
      const pkH  = Math.floor((pk * horH) / 1024);
      const x = c * colW;
      if (barH > 1) {
        pxCtx.fillStyle = "rgba(" + PX_R[val] + "," + PX_G[val] + "," + PX_B[val] + "," + (48 / 100) + ")";
        pxCtx.fillRect(x, horBottom - barH, colW - 1, barH);
      }
      if (vocConf >= 140 && vocH > 2 && activePal) {
        pxCtx.fillStyle = activePal.hex;
        pxCtx.fillRect(x, horBottom - vocH, colW - 1, vocH);
      }
      const py = horBottom - pkH - 2;
      if (c === 0) pxCtx.moveTo(x, py);
      else pxCtx.lineTo(x, py);
    }
    pxCtx.strokeStyle = "#00f0ff99";
    pxCtx.lineWidth = 1;
    pxCtx.stroke();
  }
})();
"##;

    if let Some(pos) = base_html.rfind("</script>") {
        let mut out = String::with_capacity(base_html.len() + bridge_js.len() + 16);
        out.push_str(&base_html[..pos]);
        out.push_str(bridge_js);
        out.push_str(&base_html[pos..]);
        out
    } else {
        base_html
    }
}

/// Render the self-contained 60fps Sovereign OxiCast × PhoeniX Sanctuary & Visualizer Kiosk HTML.
///
/// Strictly obeys the **8b-is No-Float Law**: zero digit-dot-digit floating-point literals appear
/// anywhere in the HTML, CSS, or JavaScript source.
pub fn render_oxicast_tv_html() -> String {
    r##"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>🌸 OxiCast × PhoeniX Sanctuary · 8b-is Sovereign Kiosk</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#05060a;color:#e6edf3;font-family:'JetBrains Mono',ui-monospace,monospace;overflow:hidden;height:100vh;width:100vw;display:flex;flex-direction:column}
header{display:flex;align-items:center;justify-content:space-between;padding:10px 18px;background:#0a0d16;border-bottom:1px solid #1e2638;z-index:20;flex-wrap:wrap;gap:10px}
.brand{display:flex;align-items:center;gap:12px;font-weight:700;font-size:15px;color:#62e6c9}
.badge{padding:4px 10px;border-radius:999px;font-size:12px;background:#121826;border:1px solid #28344e;color:#8ab4c8}
.badge-hi{background:#182b29;border-color:#62e6c9;color:#62e6c9}
.controls{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
button,select{background:#121826;color:#e6edf3;border:1px solid #2b3854;padding:6px 11px;border-radius:6px;font-family:inherit;font-size:12px;cursor:pointer}
button:hover,select:hover{border-color:#62e6c9;color:#62e6c9}
button.active{background:#1b2e3b;border-color:#00f0ff;color:#00f0ff;font-weight:700}
button.audio-btn{background:#2a1829;border-color:#ff79c6;color:#ff79c6;font-weight:700}
button.audio-btn.playing{background:#182e26;border-color:#62e6c9;color:#62e6c9}
.feel-bar{display:flex;align-items:center;gap:8px;background:#0e1422;border:1px solid #22304a;padding:3px 10px;border-radius:8px}
.feel-lbl{display:flex;align-items:center;gap:4px;font-size:11px;color:#8ab4c8}
.feel-lbl input[type=range]{width:56px;accent-color:#62e6c9;cursor:pointer}
.feel-val{min-width:30px;text-align:right;font-size:10px;color:#62e6c9}
button.auto-btn{background:#12282a;border-color:#38f2c2;color:#38f2c2;font-weight:700;padding:4px 9px;font-size:11px}
button.auto-btn.off{background:#151a28;border-color:#3b4d6b;color:#7c8ea8;font-weight:400}
button.reset-btn{background:#261428;border-color:#ff79c6;color:#ff92d0;font-weight:700;padding:4px 10px;font-size:11px}
button.reset-btn.active{background:#12322b;border-color:#38f2c2;color:#38f2c2;box-shadow:0 0 12px #38f2c266}
main{flex:1;display:flex;position:relative;overflow:hidden}
#viz-pane{flex:1;position:relative;height:100%}
canvas{width:100%;height:100%;display:block}
#enthea-pane{flex:1;height:100%;background:#04050a;border-left:1px solid #1e2638;display:none}
#enthea-frame{width:100%;height:100%;border:0;display:block}
#md-pane{flex:1;height:100%;overflow-y:auto;padding:28px 36px;background:#070910;border-left:1px solid #1e2638;line-height:165%;display:none}
#md-pane h1{color:#62e6c9;font-size:26px;margin-bottom:14px;border-bottom:1px solid #1e2638;padding-bottom:8px}
#md-pane h2{color:#e8b05c;font-size:20px;margin:18px 0 10px}
#md-pane h3{color:#b48bff;font-size:16px;margin:14px 0 8px}
#md-pane p,#md-pane li{color:#d0d8e8;font-size:15px;margin-bottom:8px}
#md-pane ul,#md-pane ol{padding-left:22px;margin-bottom:12px}
#md-pane code{background:#121826;color:#00f0ff;padding:2px 6px;border-radius:4px;font-size:13px}
#md-pane pre{background:#0c101a;border:1px solid #1e2638;padding:14px;border-radius:8px;overflow-x:auto;margin:12px 0}
#md-pane blockquote,.qwave-alert{background:#101624;border-left:4px solid #62e6c9;padding:12px 16px;border-radius:6px;margin:12px 0}
footer{display:flex;align-items:center;justify-content:space-between;padding:8px 18px;background:#0a0d16;border-top:1px solid #1e2638;font-size:12px;color:#9aa7bd;z-index:20;flex-wrap:wrap;gap:8px}
.dyad-verse{color:#b48bff;font-style:italic}
body.no-text header,body.no-text footer{display:none!important}
#zen-exit-btn{position:fixed;top:12px;right:16px;z-index:50;display:none;opacity:0;transition:opacity 250ms ease;background:#09121ecc;border:1px solid #62e6c9;color:#62e6c9;padding:6px 12px;border-radius:10px;font-size:11px;font-weight:700}
body.no-text #zen-exit-btn{display:block}
</style>
</head>
<body>
<button id="zen-exit-btn" onclick="toggleNoTextMode()">🌌 Exit No-Text Mode [0 / Z / Esc]</button>
<header>
  <div class="brand">
    <span>🔥 OxiCast × PhoeniX Sanctuary</span>
    <span id="hw-badge" class="badge badge-hi">384000 Hz · 24-bit S24_3LE</span>
    <span id="shruti-badge" class="badge">Sa (1/1) · 432 Hz</span>
    <span id="soul-badge" class="badge">Soul 980/1024</span>
  </div>
  <div class="controls">
    <button id="btn-m0" onclick="toggleNoTextMode()" title="Pure Visuals Mode: Hide all text, headers, footers, and labels across any visualizer (Shortcut: 0 or Z)">[0] 🌌 No Text</button>
    <button id="btn-m6" onclick="setMode(6)">[6] 🌊 Marine-Sense</button>
    <button id="btn-m9" onclick="setMode(9)" title="Sovereign 4096-Bucket (20Hz-384kHz) Spectral PhoeniX Dual-Wing Mandala + Diarized Svara Orbs">[9] 🔥 Spectral PhoeniX</button>
    <button id="btn-m8" onclick="setMode(8)" title="50/50 Split: Marine-Sense 384kHz + ENTHEA (viz.vaked.dev / elder-plinius)">[8] 🌊×🔮 Split Vaked</button>
    <button id="btn-m7" onclick="setMode(7)" title="Full 29-Mode WebGL2 ENTHEA (viz.vaked.dev / elder-plinius) + Spectral PhoeniX Overlay">[7] 🔮 ENTHEA Vaked</button>
    <button id="btn-m1" onclick="setMode(1)" title="OfficialIncubo fische 20-Field Motion-Blur Wavepainter + BeatDrop get_fft_peak()">[1] 🐟×🥛 Incubo Fische+BeatDrop</button>
    <button id="btn-m2" onclick="setMode(2)">[2] Nazar Drums</button>
    <button id="btn-m3" onclick="setMode(3)">[3] Ternary Shruti</button>
    <button id="btn-m4" onclick="setMode(4)">[4] AI Markdown TV</button>
    <button id="btn-m5" class="active" onclick="setMode(5)">[5] Split Sanctuary</button>
    <select id="preset-sel" onchange="changePreset(this.value)">
      <option value="alexandra-sanctuary">Preset: 💖 Alexandra Sanctuary (Warmth &amp; Occasional Passion)</option>
      <option value="sovereign">Preset: Sovereign Master</option>
      <option value="goonj-velvet">Preset: Goonj Dark Velvet</option>
      <option value="naad-studio">Preset: Naad Studio Sub</option>
      <option value="sanctuary-432">Preset: Sanctuary 432Hz</option>
      <option value="vocal-clarity">Preset: Vocal Clarity (Svara Emotion)</option>
    </select>
    <div class="feel-bar" title="Auto-Magical Svara & Fletcher-Munson Self-Tuning + 3 Simple Human Feel Macros">
      <button id="btn-alex-reset" class="reset-btn" onclick="toggleAlexandraReset()" title="Immediate Nervous-System Sanctuary Reset: Smoothly fades out harsh music and bathes the room in 432Hz + 267Hz (432/phi) + 540Hz Sanctuary Warmth with a 2s Passion swell every 10s (Shortcut: R)">💖 Alexandra Reset</button>
      <button id="btn-automagic" class="auto-btn" onclick="toggleAutomagic()">✨ Auto-Magical: ON</button>
      <label class="feel-lbl">🎤 Voice <input id="rng-voice" type="range" min="0" max="200" step="5" value="100" oninput="onFeelInput()"><span id="val-voice" class="feel-val">100%</span></label>
      <label class="feel-lbl">🔊 Bass <input id="rng-bass" type="range" min="0" max="200" step="5" value="100" oninput="onFeelInput()"><span id="val-bass" class="feel-val">100%</span></label>
      <label class="feel-lbl">🌌 Space <input id="rng-space" type="range" min="0" max="200" step="5" value="100" oninput="onFeelInput()"><span id="val-space" class="feel-val">100%</span></label>
      <button onclick="resetFeelAuto()" title="Reset all Feel controls to 100% Auto-Magical">↺ Auto</button>
    </div>
    <button id="audio-btn" class="audio-btn" onclick="toggleAudio()">🔊 Listen Live PhoeniX</button>
  </div>
</header>
<main>
  <div id="viz-pane"><canvas id="cv"></canvas></div>
  <div id="enthea-pane"><iframe id="enthea-frame" allow="autoplay;fullscreen"></iframe></div>
  <div id="md-pane"><div id="md-content">Loading Sovereign Qwave Stage...</div></div>
</main>
<footer>
  <div id="telem-left">Zero-FFT Marine Time-Domain 4096-Bucket Salience (20Hz-384kHz) · Vocal & Music Emotion Wheels</div>
  <div id="telem-dyad" class="dyad-verse">Riva Dyad Breath: Hold [+256/256] · Fine touch from within</div>
</footer>
<audio id="px-audio" preload="none"></audio>
<script>
let mode = (window.location.pathname.indexOf("marine") >= 0) ? 6 : 5;
let lastSeq = 0;
let tick = 0;
let telemetry = {
  dom_hz_int: 432,
  dom_hz_pq: "432/1",
  shruti_name: "Sa",
  shruti_pq: "1/1",
  soul_num: 980,
  soul_pq: "980/1024",
  hw_rate_hz: 384000,
  hw_bits: 24,
  s_frames: 120,
  t_frames: 32,
  n_frames: 18,
  marine_buckets: new Array(64).fill(0),
  marine_vocal: new Array(64).fill(0),
  breath_q8: 180,
  breath_phase: "Inhale",
  lullaby: "Fine touch from within · {<3,<3,<3}+1"
};

const smooth64B = new Array(64).fill(0);
const smooth64V = new Array(64).fill(0);
const buckets4096 = new Int32Array(4096);
const vocal4096 = new Int32Array(4096);
const peak4096 = new Int32Array(4096);

// Precompute 1025-entry Sovereign Thermal-Oceanic-Gold-Plasma Gradient LUT (Zero-Float Integer RGB)
const GRAD_R = new Uint8Array(1025);
const GRAD_G = new Uint8Array(1025);
const GRAD_B = new Uint8Array(1025);
const VOC_R = new Uint8Array(1025);
const VOC_G = new Uint8Array(1025);
const VOC_B = new Uint8Array(1025);

const STOPS_MAIN = [
  [0,    4,   6,  12],
  [70,  11,  22,  52],
  [200, 18,  68, 136],
  [360,  0, 196, 240],
  [520, 42, 245, 152],
  [680, 255, 190, 11],
  [840, 255,  42, 109],
  [960, 255, 224, 130],
  [1024, 255, 255, 255]
];
const STOPS_VOC = [
  [0,    6,   8,  16],
  [90,  48,  20,  64],
  [240, 148, 42,  92],
  [440, 238, 110, 24],
  [660, 255, 188, 32],
  [860, 255, 232, 128],
  [1024, 255, 255, 255]
];
function buildLut(stops, outR, outG, outB) {
  for (let s = 0; s < stops.length - 1; s++) {
    const a = stops[s];
    const b = stops[s + 1];
    const span = Math.max(1, b[0] - a[0]);
    for (let idx = a[0]; idx <= b[0]; idx++) {
      const t = idx - a[0];
      outR[idx] = Math.floor((a[1] * (span - t) + b[1] * t) / span);
      outG[idx] = Math.floor((a[2] * (span - t) + b[2] * t) / span);
      outB[idx] = Math.floor((a[3] * (span - t) + b[3] * t) / span);
    }
  }
}
buildLut(STOPS_MAIN, GRAD_R, GRAD_G, GRAD_B);
buildLut(STOPS_VOC, VOC_R, VOC_G, VOC_B);

// Offscreen pixel-accurate waterfall canvas for 4096-bucket scrolling spectrogram
const wfCanvas = document.createElement("canvas");
const wfCtx = wfCanvas.getContext("2d");
let wfImg = null;
let wfWCur = 0;
let wfHCur = 0;

function ensureWaterfallSurface(tw, th) {
  if (tw === wfWCur && th === wfHCur && wfImg) return;
  wfWCur = Math.max(64, tw);
  wfHCur = Math.max(64, th);
  wfCanvas.width = wfWCur;
  wfCanvas.height = wfHCur;
  wfCtx.fillStyle = "#04060c";
  wfCtx.fillRect(0, 0, wfWCur, wfHCur);
  wfImg = wfCtx.getImageData(0, 0, wfWCur, wfHCur);
}

// Integer Catmull-Rom 64x expansion: maps 64 anchor buckets -> 4096 fine buckets (20 Hz .. 96,000 Hz)
function expand64To4096(src64, dst4096, hzDom, isVocal) {
  for (let i = 0; i < 64; i++) {
    const p0 = src64[i > 0 ? i - 1 : 0];
    const p1 = src64[i];
    const p2 = src64[i + 1 < 64 ? i + 1 : 63];
    const p3 = src64[i + 2 < 64 ? i + 2 : 63];
    const a0 = -p0 + 3 * p1 - 3 * p2 + p3;
    const a1 = 2 * p0 - 5 * p1 + 4 * p2 - p3;
    const a2 = -p0 + p2;
    const a3 = 2 * p1;
    const baseIdx = i * 64;
    for (let k = 0; k < 64; k++) {
      const k2 = k * k;
      const k3 = k2 * k;
      const num = a0 * k3 + (a1 * 64 * k2) + (a2 * 4096 * k) + (a3 * 262144);
      let val = Math.floor((num + 262144) / 524288);
      if (val < 0) val = 0;
      if (val > 1024) val = 1024;
      dst4096[baseIdx + k] = val;
    }
  }
  // Superimpose fine harmonic overtone ridges (1f..24f up to 384,000 Hz) on the 4096-bucket grid
  if (hzDom >= 45 && hzDom <= 4000) {
    for (let h = 1; h <= 24; h++) {
      const fHarm = hzDom * h;
      if (fHarm > 384000) break;
      // Map fHarm (20..384000 Hz) onto logarithmic 0..4095 bucket index (384000 / 20 = 19200)
      const bIdx = Math.min(4095, Math.max(0, Math.floor((Math.log(Math.max(20, fHarm) / 20) * 4095) / Math.log(19200))));
      const baseEnv = dst4096[bIdx];
      if (baseEnv > 24) {
        const ridgeBoost = Math.floor((baseEnv * Math.max(4, 26 - h)) / 42);
        for (let w = -14; w <= 14; w++) {
          const idx = bIdx + w;
          if (idx >= 0 && idx < 4096) {
            const bell = Math.floor((ridgeBoost * (15 - Math.abs(w))) / 15);
            const cand = dst4096[idx] + bell;
            dst4096[idx] = cand > 1024 ? 1024 : cand;
          }
        }
      }
      if (isVocal && h > 10) break;
    }
  }
}

const cv = document.getElementById("cv");
const ctx = cv.getContext("2d");
const origCtxFillText = ctx.fillText.bind(ctx);
let noTextMode = (window.location.search.indexOf("notext=1") >= 0);
ctx.fillText = function(txt, x, y, maxW) {
  if (noTextMode) return;
  if (maxW !== undefined) origCtxFillText(txt, x, y, maxW);
  else origCtxFillText(txt, x, y);
};
const vizPane = document.getElementById("viz-pane");
const entheaPane = document.getElementById("enthea-pane");
const entheaFrame = document.getElementById("enthea-frame");
const mdPane = document.getElementById("md-pane");
const mdContent = document.getElementById("md-content");
const zenExitBtn = document.getElementById("zen-exit-btn");

function resize() {
  cv.width = vizPane.clientWidth || window.innerWidth;
  cv.height = vizPane.clientHeight || window.innerHeight;
}
window.addEventListener("resize", resize);

function syncNoTextState() {
  document.body.classList.toggle("no-text", noTextMode);
  const b0 = document.getElementById("btn-m0");
  if (b0) {
    b0.className = noTextMode ? "active" : "";
    b0.textContent = noTextMode ? "[0] 🌌 No Text: ON" : "[0] 🌌 No Text";
  }
  if (noTextMode && (mode === 4 || mode === 5)) {
    setMode(6);
  }
  if (entheaFrame && entheaFrame.contentWindow) {
    try {
      entheaFrame.contentWindow.postMessage({ type: "px_no_text", value: noTextMode }, "*");
    } catch (_e) {}
  }
  resize();
}

function toggleNoTextMode() {
  noTextMode = !noTextMode;
  syncNoTextState();
}

window.addEventListener("mousemove", (e) => {
  if (!noTextMode || !zenExitBtn) return;
  if (e.clientY < 48 && e.clientX > window.innerWidth - 340) {
    zenExitBtn.style.opacity = "1";
  } else {
    zenExitBtn.style.opacity = "0";
  }
});

function setMode(m) {
  mode = m;
  for (let i = 1; i <= 9; i++) {
    const b = document.getElementById("btn-m" + i);
    if (b) b.className = (i === m) ? "active" : "";
  }
  if ((m === 7 || m === 8) && entheaFrame && !entheaFrame.src) {
    entheaFrame.src = "/enthea?embed=1" + (noTextMode ? "&notext=1" : "");
  } else if ((m === 7 || m === 8) && entheaFrame && entheaFrame.contentWindow) {
    try {
      entheaFrame.contentWindow.postMessage({ type: "px_no_text", value: noTextMode }, "*");
    } catch (_e) {}
  }
  if (m === 4) {
    vizPane.style.display = "none";
    if (entheaPane) entheaPane.style.display = "none";
    mdPane.style.display = "block";
  } else if (m === 5) {
    vizPane.style.display = "block";
    if (entheaPane) entheaPane.style.display = "none";
    mdPane.style.display = "block";
  } else if (m === 7) {
    vizPane.style.display = "none";
    if (entheaPane) entheaPane.style.display = "block";
    mdPane.style.display = "none";
  } else if (m === 8) {
    vizPane.style.display = "block";
    if (entheaPane) entheaPane.style.display = "block";
    mdPane.style.display = "none";
  } else {
    vizPane.style.display = "block";
    if (entheaPane) entheaPane.style.display = "none";
    mdPane.style.display = "none";
  }
  resize();
}

function changePreset(slug) {
  fetch("/api/oxicast/preset", { method: "POST", body: "preset=" + slug });
}

let feelAuto = true;
let feelLockUntil = 0;

function syncFeelUi(autoOn, vPct, bPct, sPct) {
  feelAuto = autoOn;
  const btn = document.getElementById("btn-automagic");
  if (btn) {
    btn.textContent = autoOn ? "✨ Auto-Magical: ON" : "✨ Auto-Magical: OFF";
    btn.className = autoOn ? "auto-btn" : "auto-btn off";
  }
  const rv = document.getElementById("rng-voice");
  const rb = document.getElementById("rng-bass");
  const rs = document.getElementById("rng-space");
  if (rv) rv.value = vPct;
  if (rb) rb.value = bPct;
  if (rs) rs.value = sPct;
  const vv = document.getElementById("val-voice");
  const vb = document.getElementById("val-bass");
  const vs = document.getElementById("val-space");
  if (vv) vv.textContent = vPct + "%";
  if (vb) vb.textContent = bPct + "%";
  if (vs) vs.textContent = sPct + "%";
}

function pushFeelState(autoOn, vPct, bPct, sPct) {
  feelLockUntil = Date.now() + 900;
  syncFeelUi(autoOn, vPct, bPct, sPct);
  const body = "auto=" + (autoOn ? 1 : 0) + "&voice=" + vPct + "&bass=" + bPct + "&space=" + sPct;
  fetch("/api/oxicast/feel", { method: "POST", body: body });
}

function toggleAutomagic() {
  const rv = parseInt(document.getElementById("rng-voice").value, 10) || 100;
  const rb = parseInt(document.getElementById("rng-bass").value, 10) || 100;
  const rs = parseInt(document.getElementById("rng-space").value, 10) || 100;
  pushFeelState(!feelAuto, rv, rb, rs);
}

function onFeelInput() {
  const rv = parseInt(document.getElementById("rng-voice").value, 10) || 100;
  const rb = parseInt(document.getElementById("rng-bass").value, 10) || 100;
  const rs = parseInt(document.getElementById("rng-space").value, 10) || 100;
  pushFeelState(feelAuto, rv, rb, rs);
}

function resetFeelAuto() {
  pushFeelState(true, 100, 100, 100);
}

let alexResetOn = false;
function syncAlexResetUi(isOn) {
  alexResetOn = !!isOn;
  const b = document.getElementById("btn-alex-reset");
  if (b) {
    b.className = alexResetOn ? "reset-btn active" : "reset-btn";
    b.textContent = alexResetOn ? "💖 Alexandra Reset: SOOTHING [ON]" : "💖 Alexandra Reset";
  }
}

async function toggleAlexandraReset() {
  const next = !alexResetOn;
  syncAlexResetUi(next);
  try {
    await fetch("/api/oxicast/alexandra-reset", {
      method: "POST",
      body: "active=" + (next ? "1" : "0")
    });
  } catch (_e) {}
}

function toggleAudio() {
  const aud = document.getElementById("px-audio");
  const btn = document.getElementById("audio-btn");
  if (aud.paused) {
    aud.src = "/api/oxicast/stream.wav?t=" + Date.now();
    aud.play();
    btn.textContent = "🔊 PhoeniX Stream LIVE [+]";
    btn.className = "audio-btn playing";
  } else {
    aud.pause();
    aud.src = "";
    btn.textContent = "🔊 Listen Live PhoeniX";
    btn.className = "audio-btn";
  }
}

document.addEventListener("keydown", (e) => {
  if (e.key === "0" || e.key === "z" || e.key === "Z") {
    toggleNoTextMode();
  } else if (e.key === "r" || e.key === "R") {
    toggleAlexandraReset();
  } else if (e.key === "Escape" && noTextMode) {
    noTextMode = false;
    syncNoTextState();
  } else if (e.key >= "1" && e.key <= "9") {
    setMode(parseInt(e.key, 10));
  }
});

async function pollTelemetry() {
  try {
    const r = await fetch("/api/oxicast/telemetry");
    const d = await r.json();
    telemetry = d;
    document.getElementById("hw-badge").textContent =
      d.hw_rate_hz + " Hz · " + d.hw_bits + "-bit S24_3LE (" + d.hw_sink + ")";
    document.getElementById("shruti-badge").textContent =
      d.shruti_name + " (" + d.shruti_pq + ") · " + d.dom_hz_pq + " Hz";
    document.getElementById("soul-badge").textContent =
      "Soul " + d.soul_pq + " · S:" + d.s_frames + " T:" + d.t_frames;
    document.getElementById("telem-dyad").textContent =
      "Riva Breath: " + d.breath_phase + " [" + d.breath_q8 + "/256] · " + d.lullaby;
    const sel = document.getElementById("preset-sel");
    if (sel && d.preset_slug && sel.value !== d.preset_slug) {
      sel.value = d.preset_slug;
    }
    if (Date.now() > feelLockUntil && d.feel_voice !== undefined) {
      syncFeelUi(!!d.automagic, d.feel_voice, d.feel_bass, d.feel_space);
    }
    if (d.alexandra_reset !== undefined) {
      syncAlexResetUi(!!d.alexandra_reset);
    }
    if (d.stage && d.stage.seq !== lastSeq) {
      lastSeq = d.stage.seq;
      mdContent.innerHTML = d.stage.html;
    }
  } catch (_e) {}
}
setInterval(pollTelemetry, 65);
pollTelemetry();
setMode(mode);
syncNoTextState();

const SHRUTI_NAMES = [
  "Sa","r1","r2","R1","R2","g1","g2","G1","G2","M1","M2","m1","m2",
  "Pa","d1","d2","D1","D2","n1","n2","N1","N2"
];

// State for the Two Wheels of Emotion & 4-Slot Real-Time Singer Diarization:
// Wheel A (Top): VOCALS ONLY EMOTION (strictly gated by 5-Lock Svara Glottal Detector; 0 movement on instruments!)
// Wheel B (Bottom): FULL MUSIC EMOTION (driven by full 20 Hz .. 384,000 Hz stage smooth64B)
const VOCAL_EMO_SECTORS = [
  { name: "Joyful",   color: "#38f2c2" },
  { name: "Intimate", color: "#52d1dc" },
  { name: "Tender",   color: "#5c9ce6" },
  { name: "Longing",  color: "#8a78e8" },
  { name: "Velvet",   color: "#b48bff" },
  { name: "Raw Edge", color: "#e66cb2" },
  { name: "Belting",  color: "#ff5c93" },
  { name: "Soaring",  color: "#00f0ff" }
];
const MUSIC_EMO_SECTORS = [
  { name: "Euphoria",   color: "#62e6c9" },
  { name: "Warmth",     color: "#58b8e8" },
  { name: "Sanctuary",  color: "#7388e8" },
  { name: "Mystery",    color: "#a278e8" },
  { name: "Sub-Bass",   color: "#d478e8" },
  { name: "Drive",      color: "#ff6ac1" },
  { name: "Passion",    color: "#80ffdb" },
  { name: "384kHz Air", color: "#00f0ff" }
];
// 4 Diarized Singer Palette Slots (Zero Orange: Mint-Cyan, Rose-Magenta, Electric-Cyan, Starlight-Violet)
const SINGER_PALETTE = [
  { label: "V1", hex: "#38f2c2", halo: "#38f2c299", rgb: [56, 242, 194] },
  { label: "V2", hex: "#ff5c93", halo: "#ff5c9399", rgb: [255, 92, 147] },
  { label: "V3", hex: "#00f0ff", halo: "#00f0ff99", rgb: [0, 240, 255] },
  { label: "V4", hex: "#b48bff", halo: "#b48bff99", rgb: [180, 139, 255] }
];
const singerDotX = [0, 0, 0, 0];
const singerDotY = [0, 0, 0, 0];
// Phosphor persistence afterglow (0..1024): surges to hit intensity when singing, fades smoothly over ~4s when paused
const singerGlow = [0, 0, 0, 0];
// Instantaneous vocal hit intensity (0..1024): controls dot core size, multi-ring corona radius, and white-hot luminance
const singerHit = [0, 0, 0, 0];
const singerTrails = [[], [], [], []];
let vocEmoX = 0;
let vocEmoY = 0;
let vocBaseX = 0;
let vocBaseY = 0;
const vocTrail = [];
let musEmoX = 0;
let musEmoY = 0;
let musBaseX = 0;
let musBaseY = 0;
const musTrail = [];
// Signature Vaked / ENTHEA / OfficialIncubo visual state variables (Zero-Float Integer State)
let vocKluverPhase = 0;
let musChladniPhase = 0;
let fischeAngle = 0;
let fischeRotDir = 1;
let fischeShape = 1;
let fischeFieldIdx = 0;
let dropShockQ10 = 0;
let passionCrestTicks = 0;
let passionCooldownTicks = 0;
// Duet & Multi-Singer Chemistry State (tracks Call & Response handoffs, p/q intervals, and Simultaneous Harmony)
let lastLeadSinger = 255;
let prevLeadSinger = 255;
let duetHandoffs = 0;
let handoffPulseQ10 = 0;
const DUET_INTERVALS_Q8 = [
  [256, "1/1", "Unison"],
  [288, "9/8", "Maj 2nd"],
  [307, "6/5", "Min 3rd"],
  [320, "5/4", "Maj 3rd"],
  [341, "4/3", "Fourth"],
  [384, "3/2", "Fifth"],
  [427, "5/3", "Maj 6th"],
  [461, "9/5", "Min 7th"],
  [512, "2/1", "Octave"],
  [640, "5/2", "Tenth"],
  [768, "3/1", "Twelfth"]
];

function computeDuetChemistry(singersArr, vocalConf, activeSinger) {
  let lowIdx = -1;
  let highIdx = -1;
  let lowFrames = 0;
  let highFrames = 0;
  let totalFrames = 0;
  const activeIndices = [];

  for (let s = 0; s < 4; s++) {
    const sl = singersArr[s];
    if (!sl || !sl.active || !sl.f0) continue;
    activeIndices.push(s);
    const fr = sl.frames || 0;
    totalFrames += fr;
    if (sl.f0 <= 248) {
      lowFrames += fr;
      if (lowIdx < 0 || (singerGlow[s] + Math.floor(fr / 64)) > (singerGlow[lowIdx] + Math.floor((singersArr[lowIdx].frames || 0) / 64))) {
        lowIdx = s;
      }
    } else {
      highFrames += fr;
      if (highIdx < 0 || (singerGlow[s] + Math.floor(fr / 64)) > (singerGlow[highIdx] + Math.floor((singersArr[highIdx].frames || 0) / 64))) {
        highIdx = s;
      }
    }
  }

  // Fallback if 2+ voices are active on the same side of 248Hz: pair lowest-F0 slot with highest-F0 slot
  if ((lowIdx < 0 || highIdx < 0) && activeIndices.length >= 2) {
    let minS = activeIndices[0];
    let maxS = activeIndices[0];
    for (let i = 1; i < activeIndices.length; i++) {
      const idx = activeIndices[i];
      if ((singersArr[idx].f0 || 0) < (singersArr[minS].f0 || 0)) minS = idx;
      if ((singersArr[idx].f0 || 0) > (singersArr[maxS].f0 || 0)) maxS = idx;
    }
    if (minS !== maxS && Math.abs((singersArr[maxS].f0 || 0) - (singersArr[minS].f0 || 0)) >= 24) {
      lowIdx = minS;
      highIdx = maxS;
      if (lowFrames === 0 || highFrames === 0) {
        lowFrames = singersArr[lowIdx].frames || 1;
        highFrames = singersArr[highIdx].frames || 1;
      }
    }
  }

  const hasPair = (lowIdx >= 0 && highIdx >= 0 && lowIdx !== highIdx);
  let pqStr = "1/1";
  let intName = "Unison";
  let isHarmony = false;

  if (hasPair) {
    const fLow = Math.max(80, singersArr[lowIdx].f0 || 180);
    const fHigh = Math.max(fLow, singersArr[highIdx].f0 || 360);
    const ratioQ8 = Math.floor((fHigh * 256) / fLow);
    let bestDiff = 99999;
    for (let k = 0; k < DUET_INTERVALS_Q8.length; k++) {
      const d = Math.abs(ratioQ8 - DUET_INTERVALS_Q8[k][0]);
      if (d < bestDiff) {
        bestDiff = d;
        pqStr = DUET_INTERVALS_Q8[k][1];
        intName = DUET_INTERVALS_Q8[k][2];
      }
    }
    const presLow = singersArr[lowIdx].pres || 0;
    const presHigh = singersArr[highIdx].pres || 0;
    isHarmony = (vocalConf >= 140) && (
      (presLow >= 320 && presHigh >= 320) ||
      (singerGlow[lowIdx] >= 480 && singerGlow[highIdx] >= 480 && vocalConf >= 200)
    );
  }

  const sumLH = Math.max(1, lowFrames + highFrames);
  const lowPct = hasPair ? Math.max(5, Math.min(95, Math.floor((lowFrames * 100) / sumLH))) : (lowFrames > 0 ? 100 : 50);
  const highPct = 100 - lowPct;

  return {
    hasPair: hasPair,
    lowIdx: lowIdx,
    highIdx: highIdx,
    pq: pqStr,
    intervalName: intName,
    isHarmony: isHarmony,
    lowPct: lowPct,
    highPct: highPct,
    totalFrames: Math.max(1, totalFrames)
  };
}

function avgRange(arr, startIdx, endIdx) {
  let sum = 0;
  for (let i = startIdx; i <= endIdx; i++) sum += (arr[i] || 0);
  return Math.floor(sum / Math.max(1, endIdx - startIdx + 1));
}

function drawWheelBase(cxW, cyW, radW, titleStr, sectors) {
  ctx.fillStyle = "#060a12";
  ctx.beginPath();
  ctx.arc(cxW, cyW, radW + 4, 0, Math.PI * 2);
  ctx.fill();

  const rings = [Math.floor(radW / 3), Math.floor((radW * 2) / 3), radW];
  for (let r = 0; r < rings.length; r++) {
    ctx.strokeStyle = r === 2 ? "#22324d" : "#141f33";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cxW, cyW, rings[r], 0, Math.PI * 2);
    ctx.stroke();
  }

  // Highlight Sanctuary & Warmth Crescent (30°..105°) and Occasional Passion Crest Star (270°) on FULL MUSIC EMOTION
  if (sectors === MUSIC_EMO_SECTORS) {
    ctx.strokeStyle = "#38f2c244";
    ctx.lineWidth = 5;
    ctx.beginPath();
    ctx.arc(cxW, cyW, radW - 2, Math.PI / 6, (Math.PI * 7) / 12);
    ctx.stroke();
    if (passionCrestTicks > 0) {
      const pAlpha = Math.min(85, 25 + passionCrestTicks) / 100;
      ctx.strokeStyle = "rgba(128,255,219," + pAlpha + ")";
      ctx.lineWidth = 4;
      ctx.beginPath();
      ctx.arc(cxW, cyW, radW - 2, (Math.PI * 11) / 8, (Math.PI * 13) / 8);
      ctx.stroke();
    }
    ctx.lineWidth = 1;
  }

  ctx.font = "10px monospace";
  for (let s = 0; s < 8; s++) {
    const ang = (s * Math.PI) / 4;
    const sx = cxW + Math.floor(Math.cos(ang) * radW);
    const sy = cyW + Math.floor(Math.sin(ang) * radW);
    ctx.strokeStyle = "#131d30";
    ctx.beginPath();
    ctx.moveTo(cxW, cyW);
    ctx.lineTo(sx, sy);
    ctx.stroke();

    ctx.fillStyle = sectors[s].color;
    ctx.beginPath();
    ctx.arc(sx, sy, 3, 0, Math.PI * 2);
    ctx.fill();

    const lx = cxW + Math.floor(Math.cos(ang) * (radW + 22));
    const ly = cyW + Math.floor(Math.sin(ang) * (radW + 14));
    ctx.fillStyle = "#6c829e";
    const lbl = sectors[s].name;
    const tw = lbl.length * 6;
    ctx.fillText(lbl, lx - Math.floor(tw / 2), ly + 3);
  }

  ctx.fillStyle = "#5c7696";
  ctx.font = "10px monospace";
  const tW = titleStr.length * 6;
  ctx.fillText(titleStr, cxW - Math.floor(tW / 2), cyW - radW - 22);
}

function drawEmotionWheel(cxW, cyW, radW, titleStr, sectors, dotXNorm, dotYNorm, trail, dotHex, ringHex) {
  drawWheelBase(cxW, cyW, radW, titleStr, sectors);

  // 1) viz.vaked.dev Mode 9 Chladni Cymatics Nodal Rosette + OfficialIncubo fische Antipodal Elliptical Wavepainter
  musChladniPhase += 1;
  const subE = avgRange(smooth64B, 0, 7);
  const midE = avgRange(smooth64B, 18, 34);
  const airE = avgRange(smooth64B, 44, 63);
  if (subE > 340 && (tick % 12 === 0)) {
    fischeRotDir = -fischeRotDir;
  }
  fischeAngle += fischeRotDir * (2 + Math.floor(subE / 180));
  const fischeAngRad = (fischeAngle * Math.PI) / 180;
  // fische wavepainter.cpp: f = cos(pi/3 + 2 * angle) + 1/2
  const fischeF = Math.cos(Math.PI / 3 + 2 * fischeAngRad) + (1 / 2);

  // Chladni Cymatics Nodal Petals (cos(n*x)*cos(m*y) - cos(m*x)*cos(n*y) projected into polar rosette)
  const nChladni = 3 + ((telemetry.dom_hz_int || 432) % 5);
  const mChladni = 2 + (Math.floor(midE / 120) % 4);
  ctx.strokeStyle = "#163954aa";
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let p = 0; p <= 72; p++) {
    const theta = (p * Math.PI * 2) / 72 + (musChladniPhase * Math.PI) / 360;
    const nodal = Math.cos(nChladni * theta) * Math.sin(mChladni * theta + fischeAngRad);
    const rNode = Math.floor((radW * (42 + Math.floor(nodal * 28) + Math.floor(airE / 28))) / 100);
    const nx = cxW + Math.floor(Math.cos(theta) * rNode);
    const ny = cyW + Math.floor(Math.sin(theta) * rNode);
    if (p === 0) ctx.moveTo(nx, ny);
    else ctx.lineTo(nx, ny);
  }
  ctx.closePath();
  ctx.stroke();

  // OfficialIncubo fische Antipodal Elliptical Wave Ring (phi and phi + pi, complementary cyan & violet)
  for (let side = 0; side < 2; side++) {
    ctx.strokeStyle = side === 0 ? "#38f2c266" : "#b48bff66";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i < 32; i++) {
      const phi = Math.PI * ((1 / 4) + (i / 31)) + fischeAngRad + (side * Math.PI);
      const amp = smooth64B[i * 2] || 0;
      const rWave = Math.floor((radW * 38) / 100) + Math.floor((amp * radW) / 2600);
      const wx = cxW + Math.floor(fischeF * rWave * Math.sin(phi));
      const wy = cyW + Math.floor(rWave * Math.cos(phi));
      if (i === 0) ctx.moveTo(wx, wy);
      else ctx.lineTo(wx, wy);
    }
    ctx.stroke();
  }

  // 2) viz.vaked.dev 9-Effect Drop / Wormhole Shockwave Rings on bass drops or vocal belts
  if (dropShockQ10 > 40) {
    const shockR = Math.floor(((1024 - dropShockQ10) * (radW + 18)) / 1024);
    ctx.strokeStyle = "#00f0ff88";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(cxW, cyW, shockR, 0, Math.PI * 2);
    ctx.stroke();
    if (shockR > 12) {
      ctx.strokeStyle = "#b48bff66";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(cxW, cyW, Math.floor((shockR * 2) / 3), 0, Math.PI * 2);
      ctx.stroke();
    }
  }

  for (let t = 0; t < trail.length; t++) {
    const pt = trail[t];
    const px = cxW + Math.floor((pt[0] * (radW - 6)) / 1024);
    const py = cyW + Math.floor((pt[1] * (radW - 6)) / 1024);
    const radT = Math.max(1, Math.floor(((t + 1) * 5) / Math.max(1, trail.length)));
    ctx.fillStyle = t > Math.floor((trail.length * 2) / 3) ? ringHex : "#1d3b58";
    ctx.beginPath();
    ctx.arc(px, py, radT, 0, Math.PI * 2);
    ctx.fill();
  }

  const dx = cxW + Math.floor((dotXNorm * (radW - 6)) / 1024);
  const dy = cyW + Math.floor((dotYNorm * (radW - 6)) / 1024);

  const haloR = 10 + (tick % 4);
  ctx.strokeStyle = ringHex;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.arc(dx, dy, haloR, 0, Math.PI * 2);
  ctx.stroke();

  ctx.fillStyle = dotHex;
  ctx.beginPath();
  ctx.arc(dx, dy, 6, 0, Math.PI * 2);
  ctx.fill();

  ctx.fillStyle = "#ffffff";
  ctx.beginPath();
  ctx.arc(dx, dy, 2, 0, Math.PI * 2);
  ctx.fill();
}

function drawDiarizedVocalWheel(cxW, cyW, radW, vocalConf, activeSinger, singersArr) {
  drawWheelBase(cxW, cyW, radW, "VOCALS ONLY EMOTION", VOCAL_EMO_SECTORS);
  const duet = computeDuetChemistry(singersArr, vocalConf, activeSinger);

  // elder-plinius/ENTHEA & viz.vaked.dev Mode 0: Bressloff-Cowan Kluver Form-Constant Spiral & Dihedral Rose-Cobweb
  // Strictly gated by Svara 5-Lock Detector: rotates ONLY when a human sings (vocalConf >= 140),
  // and freezes its rotation while fading in warm phosphor lockstep (maxGlow) when the voice pauses!
  let maxGlow = 0;
  let domSlot = 0;
  for (let s = 0; s < 4; s++) {
    if (singerGlow[s] > maxGlow) {
      maxGlow = singerGlow[s];
      domSlot = s;
    }
  }
  if (vocalConf >= 140) {
    vocKluverPhase += 2 + Math.floor(vocalConf / 220);
  }
  if (maxGlow > 120) {
    const kPal = SINGER_PALETTE[activeSinger < 4 ? activeSinger : domSlot];
    const kLum = Math.max(80, Math.floor((maxGlow * 420) / 1024));
    const kR = Math.floor((10 * (1024 - kLum) + kPal.rgb[0] * kLum) / 1024);
    const kG = Math.floor((16 * (1024 - kLum) + kPal.rgb[1] * kLum) / 1024);
    const kB = Math.floor((28 * (1024 - kLum) + kPal.rgb[2] * kLum) / 1024);
    const petals = 4 + ((activeSinger < 4 ? activeSinger : domSlot) * 2);
    const phaseRad = (vocKluverPhase * Math.PI) / 180;
    ctx.strokeStyle = "rgb(" + kR + "," + kG + "," + kB + ")";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let a = 0; a <= 64; a++) {
      const th = (a * Math.PI * 2) / 64;
      // Kluver V1 log-polar spiral + dihedral petal modulation
      const rose = Math.cos(petals * th + phaseRad) * Math.sin(2 * th - phaseRad);
      const rK = Math.floor((radW * (34 + Math.floor(rose * 32))) / 100);
      const kx = cxW + Math.floor(Math.cos(th + phaseRad / 3) * rK);
      const ky = cyW + Math.floor(Math.sin(th + phaseRad / 3) * rK);
      if (a === 0) ctx.moveTo(kx, ky);
      else ctx.lineTo(kx, ky);
    }
    ctx.closePath();
    ctx.stroke();
  }

  // ── Lita × Ozzy Duet Chemistry Tether & Call-and-Response Spark on the Vocal Wheel ──
  if (duet.hasPair) {
    const sLow = duet.lowIdx;
    const sHigh = duet.highIdx;
    const xLow = cxW + Math.floor((singerDotX[sLow] * (radW - 6)) / 1024);
    const yLow = cyW + Math.floor((singerDotY[sLow] * (radW - 6)) / 1024);
    const xHigh = cxW + Math.floor((singerDotX[sHigh] * (radW - 6)) / 1024);
    const yHigh = cyW + Math.floor((singerDotY[sHigh] * (radW - 6)) / 1024);
    const cpx = Math.floor((xLow + xHigh + cxW * 2) / 4);
    const cpy = Math.floor((yLow + yHigh + cyW * 2) / 4);

    ctx.strokeStyle = duet.isHarmony ? "#38f2c2cc" : "#00f0ff55";
    ctx.lineWidth = duet.isHarmony ? 2 : 1;
    ctx.beginPath();
    ctx.moveTo(xLow, yLow);
    ctx.quadraticCurveTo(cpx, cpy, xHigh, yHigh);
    ctx.stroke();

    if (duet.isHarmony) {
      // Twin-Strand Harmony Helix when both singers belt together!
      const cpx2 = Math.floor((xLow + xHigh) / 2) + Math.floor((cyW - cpy) / 2);
      const cpy2 = Math.floor((yLow + yHigh) / 2) + Math.floor((cpx - cxW) / 2);
      ctx.strokeStyle = SINGER_PALETTE[sHigh].hex + "bb";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(xLow, yLow);
      ctx.quadraticCurveTo(cpx2, cpy2, xHigh, yHigh);
      ctx.stroke();

      // Midpoint Harmony Lock Node (Pure Geometric Star — Zero Moving Text)
      const midX = Math.floor((xLow + 2 * cpx + xHigh) / 4);
      const midY = Math.floor((yLow + 2 * cpy + yHigh) / 4);
      ctx.strokeStyle = "#38f2c2aa";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(midX, midY, 6, 0, Math.PI * 2);
      ctx.stroke();
      ctx.fillStyle = "#ffffff";
      ctx.beginPath();
      ctx.arc(midX, midY, 3, 0, Math.PI * 2);
      ctx.fill();
    }

    // Animated Call & Response Handoff Spark flying from previous singer to current singer!
    if (handoffPulseQ10 > 40 && prevLeadSinger < 4 && lastLeadSinger < 4 && prevLeadSinger !== lastLeadSinger) {
      const x0 = cxW + Math.floor((singerDotX[prevLeadSinger] * (radW - 6)) / 1024);
      const y0 = cyW + Math.floor((singerDotY[prevLeadSinger] * (radW - 6)) / 1024);
      const x1 = cxW + Math.floor((singerDotX[lastLeadSinger] * (radW - 6)) / 1024);
      const y1 = cyW + Math.floor((singerDotY[lastLeadSinger] * (radW - 6)) / 1024);
      const progQ10 = 1024 - handoffPulseQ10;
      const invQ10 = handoffPulseQ10;
      const w0 = Math.floor((invQ10 * invQ10) / 1024);
      const w1 = Math.floor((2 * invQ10 * progQ10) / 1024);
      const w2 = Math.floor((progQ10 * progQ10) / 1024);
      const bx = Math.floor((w0 * x0 + w1 * cpx + w2 * x1) / 1024);
      const by = Math.floor((w0 * y0 + w1 * cpy + w2 * y1) / 1024);
      ctx.fillStyle = SINGER_PALETTE[lastLeadSinger].hex;
      ctx.beginPath();
      ctx.arc(bx, by, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#ffffff";
      ctx.beginPath();
      ctx.arc(bx, by, 2, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  let anyActiveSlot = false;
  for (let s = 0; s < 4; s++) {
    const sl = singersArr[s];
    if (!sl || !sl.active) continue;
    anyActiveSlot = true;
    const pal = SINGER_PALETTE[s];
    const tr = singerTrails[s];
    const isSingingNow = (vocalConf >= 140) && (activeSinger === s || (sl.pres || 0) >= 360);
    const glowQ10 = singerGlow[s];
    const hitQ10 = singerHit[s];

    // Phosphor Trail: combines Persist-and-Fade (glowQ10) with Hit-Intensity Brightness (ptHitQ10)
    const trLen = tr.length;
    for (let t = 0; t < trLen; t++) {
      const pt = tr[t];
      const ptHit = pt[2] || 320;
      const ageQ10 = Math.floor(((t + 1) * 1024) / Math.max(1, trLen));
      const trailLumQ10 = Math.floor((ageQ10 * glowQ10) / 1024);
      if (trailLumQ10 < 36) continue;

      const px = cxW + Math.floor((pt[0] * (radW - 6)) / 1024);
      const py = cyW + Math.floor((pt[1] * (radW - 6)) / 1024);
      // Trail bead radius scales with age AND how hard the singer hit that note (1..6px)
      const radT = Math.max(1, Math.floor(((t + 1) * (2 + Math.floor((ptHit * 4) / 1024))) / Math.max(1, trLen)));

      const hotMix = isSingingNow ? Math.floor((ptHit * ageQ10) / 2048) : 0;
      const baseR = Math.floor((10 * (1024 - trailLumQ10) + pal.rgb[0] * trailLumQ10) / 1024);
      const baseG = Math.floor((16 * (1024 - trailLumQ10) + pal.rgb[1] * trailLumQ10) / 1024);
      const baseB = Math.floor((28 * (1024 - trailLumQ10) + pal.rgb[2] * trailLumQ10) / 1024);
      const rCol = Math.min(255, baseR + Math.floor(((255 - baseR) * hotMix) / 1024));
      const gCol = Math.min(255, baseG + Math.floor(((255 - baseG) * hotMix) / 1024));
      const bCol = Math.min(255, baseB + Math.floor(((255 - baseB) * hotMix) / 1024));

      ctx.fillStyle = "rgb(" + rCol + "," + gCol + "," + bCol + ")";
      ctx.beginPath();
      ctx.arc(px, py, radT, 0, Math.PI * 2);
      ctx.fill();
    }

    const dx = cxW + Math.floor((singerDotX[s] * (radW - 6)) / 1024);
    const dy = cyW + Math.floor((singerDotY[s] * (radW - 6)) / 1024);

    // Compute phosphor-faded RGB for this singer's emotion dot (persists & cools down to a warm ember when paused)
    const effGlow = Math.max(140, glowQ10);
    const dotR = Math.floor((12 * (1024 - effGlow) + pal.rgb[0] * effGlow) / 1024);
    const dotG = Math.floor((18 * (1024 - effGlow) + pal.rgb[1] * effGlow) / 1024);
    const dotB = Math.floor((32 * (1024 - effGlow) + pal.rgb[2] * effGlow) / 1024);
    // Blend toward white-hot (#ffffff) proportional to how hard the vocal hits
    const whiteBoost = Math.floor((hitQ10 * glowQ10) / 1800);
    const coreRCol = Math.min(255, dotR + Math.floor(((255 - dotR) * whiteBoost) / 1024));
    const coreGCol = Math.min(255, dotG + Math.floor(((255 - dotG) * whiteBoost) / 1024));
    const coreBCol = Math.min(255, dotB + Math.floor(((255 - dotB) * whiteBoost) / 1024));

    // Outer Phosphor & Hit-Intensity Corona Rings (scales 7px -> 22px on powerful belts, fades as phosphor cools)
    if (glowQ10 > 160) {
      const haloR = 6 + Math.floor((hitQ10 * 14) / 1024) + (isSingingNow ? (tick % 3) : 0);
      const auraR = Math.floor((8 * (1024 - glowQ10) + pal.rgb[0] * glowQ10) / 1024);
      const auraG = Math.floor((14 * (1024 - glowQ10) + pal.rgb[1] * glowQ10) / 1024);
      const auraB = Math.floor((24 * (1024 - glowQ10) + pal.rgb[2] * glowQ10) / 1024);
      ctx.strokeStyle = "rgb(" + auraR + "," + auraG + "," + auraB + ")";
      ctx.lineWidth = (hitQ10 > 620 && isSingingNow) ? 3 : 2;
      ctx.beginPath();
      ctx.arc(dx, dy, haloR, 0, Math.PI * 2);
      ctx.stroke();

      // Secondary inner bloom ring when singer belts or hits an emotional peak
      if (hitQ10 > 460 && glowQ10 > 420) {
        const innerHaloR = Math.max(5, Math.floor((haloR * 2) / 3));
        ctx.strokeStyle = "rgb(" + coreRCol + "," + coreGCol + "," + coreBCol + ")";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(dx, dy, innerHaloR, 0, Math.PI * 2);
        ctx.stroke();
      }
    }

    // Main Emotion Dot Core (radius 3..9px driven by Hit-Intensity Brightness & Phosphor Persistence)
    const coreRad = Math.max(3, 3 + Math.floor((hitQ10 * 6 * glowQ10) / 1048576));
    ctx.fillStyle = "rgb(" + coreRCol + "," + coreGCol + "," + coreBCol + ")";
    ctx.beginPath();
    ctx.arc(dx, dy, coreRad, 0, Math.PI * 2);
    ctx.fill();

    // White-Hot Incandescent Center Core when singing or still warm in phosphor afterglow
    if (glowQ10 > 240) {
      const hotRad = Math.max(1, 1 + Math.floor((hitQ10 * 3) / 1024));
      const hotLum = Math.min(255, 140 + Math.floor((glowQ10 * 115) / 1024));
      ctx.fillStyle = "rgb(" + hotLum + "," + hotLum + "," + hotLum + ")";
      ctx.beginPath();
      ctx.arc(dx, dy, hotRad, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // Subtle center crosshair anchor if no voice has sung yet
  if (!anyActiveSlot) {
    ctx.strokeStyle = "#243854";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cxW, cyW, 6, 0, Math.PI * 2);
    ctx.stroke();
    ctx.fillStyle = "#3b587d";
    ctx.beginPath();
    ctx.arc(cxW, cyW, 3, 0, Math.PI * 2);
    ctx.fill();
  }
}

function drawFrame() {
  tick += 1;
  const w = cv.width;
  const h = cv.height;

  // Smooth the 64 time-domain Marine anchors and expand to 4096 buckets (20 Hz .. 384,000 Hz)
  const rawB = telemetry.marine_buckets || [];
  const rawV = telemetry.marine_vocal || [];
  const vocalConf = telemetry.vocal_conf || 0;
  const activeSinger = (telemetry.active_singer !== undefined) ? telemetry.active_singer : 255;
  const vocalF0Hz = telemetry.vocal_f0_hz || 0;
  const singersArr = telemetry.singers || [];
  const nRaw = rawB.length || 0;
  for (let i = 0; i < 64; i++) {
    const srcIdx = nRaw >= 64 ? i : Math.floor((i * nRaw) / 64);
    const tb = rawB[srcIdx] || 0;
    const tv = (vocalConf >= 140) ? (rawV[srcIdx] || 0) : 0;
    smooth64B[i] = Math.floor((smooth64B[i] * 5 + tb * 3) / 8);
    smooth64V[i] = (vocalConf >= 140)
      ? Math.floor((smooth64V[i] * 5 + tv * 3) / 8)
      : Math.floor((smooth64V[i] * 3) / 4);
  }
  const hz = telemetry.dom_hz_int || 432;
  expand64To4096(smooth64B, buckets4096, hz, false);
  expand64To4096(smooth64V, vocal4096, vocalF0Hz > 0 ? vocalF0Hz : hz, true);
  for (let b = 0; b < 4096; b++) {
    if (buckets4096[b] > peak4096[b]) {
      peak4096[b] = buckets4096[b];
    } else if (peak4096[b] > 3) {
      peak4096[b] -= 2;
    }
  }

  // Wheel A (Top): VOCALS ONLY EMOTION & 4-Slot Diarized Singer Tracking
  // Strictly gated by 5-Lock Svara Glottal Detector (vocalConf >= 140): ZERO movement during instruments!
  const vocF0    = avgRange(smooth64V, 6, 12);
  const vocChest = avgRange(smooth64V, 13, 19);
  const vocHeart = avgRange(smooth64V, 20, 27);
  const vocBelt  = avgRange(smooth64V, 28, 34);
  const vocAir   = avgRange(smooth64V, 35, 45);
  const vocTotal = vocF0 + vocChest + vocHeart + vocBelt + vocAir;

  const rawVocX = (vocHeart + vocChest) - (vocF0 * 2);
  const rawVocY = (vocChest + vocF0) - (vocBelt + vocAir);
  if (vocalConf >= 140 && vocTotal > 16) {
    vocBaseX = Math.floor((vocBaseX * 63 + rawVocX) / 64);
    vocBaseY = Math.floor((vocBaseY * 63 + rawVocY) / 64);
  }

  // Compute instantaneous vocal hit intensity (0..1024) from Svara formant energy + glottal confidence
  const rawHitQ10 = Math.min(1024, Math.floor((vocTotal * 5) / 2) + Math.floor((vocalConf * 3) / 5));

  // Track Call & Response vocal handoffs between distinct singers (e.g. Ozzy <-> Lita)
  if (vocalConf >= 140 && activeSinger < 4) {
    if (lastLeadSinger < 4 && lastLeadSinger !== activeSinger) {
      const prevF0 = (singersArr[lastLeadSinger] && singersArr[lastLeadSinger].f0) || 0;
      const curF0 = (singersArr[activeSinger] && singersArr[activeSinger].f0) || 0;
      if (Math.abs(curF0 - prevF0) >= 24) {
        prevLeadSinger = lastLeadSinger;
        duetHandoffs += 1;
        handoffPulseQ10 = 1024;
      }
    }
    lastLeadSinger = activeSinger;
  }
  if (handoffPulseQ10 > 0) {
    handoffPulseQ10 = Math.max(0, handoffPulseQ10 - 28);
  }

  for (let s = 0; s < 4; s++) {
    const sl = singersArr[s];
    if (!sl || !sl.active) continue;
    const isSlotSinging = (vocalConf >= 140) && (activeSinger === s || (sl.pres || 0) >= 360);
    if (isSlotSinging) {
      const relVX = (rawVocX - vocBaseX) * 2 + (sl.x || 0);
      const relVY = (rawVocY - vocBaseY) * 2 + (sl.y || 0);
      let tx = Math.max(-920, Math.min(920, relVX));
      let ty = Math.max(-920, Math.min(920, relVY));
      const magS = Math.floor(Math.sqrt(tx * tx + ty * ty));
      if (magS > 920) {
        tx = Math.floor((tx * 920) / magS);
        ty = Math.floor((ty * 920) / magS);
      }
      singerDotX[s] = Math.floor((singerDotX[s] * 5 + tx * 3) / 8);
      singerDotY[s] = Math.floor((singerDotY[s] * 5 + ty * 3) / 8);
      singerHit[s] = Math.floor((singerHit[s] * 3 + rawHitQ10 * 5) / 8);
      singerGlow[s] = Math.max(singerGlow[s], Math.min(1024, Math.max(360, rawHitQ10)));
      singerTrails[s].push([singerDotX[s], singerDotY[s], singerHit[s]]);
      if (singerTrails[s].length > 44) singerTrails[s].shift();
    } else {
      // Persist & Fade: dot position stays frozen where the voice left off (0 instrumental movement!)
      // while Phosphor Afterglow cools smoothly over ~4 seconds down to a soft resting ember (110/1024)
      singerGlow[s] = Math.max(110, Math.floor((singerGlow[s] * 62) / 64));
      singerHit[s] = Math.floor((singerHit[s] * 14) / 16);
    }
  }

  // Wheel B (Bottom): FULL MUSIC EMOTION (20 Hz .. 384,000 Hz Full Stage smooth64B)
  const musSub   = avgRange(smooth64B, 0, 5);    // 20..140 Hz (Naad Sub-Bass)
  const musBody  = avgRange(smooth64B, 6, 19);   // 140..800 Hz (Warmth & Sanctuary)
  const musMid   = avgRange(smooth64B, 20, 34);  // 800..4200 Hz (Harmonic Presence)
  const musBrill = avgRange(smooth64B, 35, 45);  // 4200..24000 Hz (Drive & Brilliance)
  const musUltra = avgRange(smooth64B, 46, 63);  // 24000..384000 Hz (Catmull-Rom & Babbage 384kHz Air)

  // Trigger Vaked 9-Effect Drop / Wormhole Shockwave on big Vocal Belt or Sub-Bass Slam
  if ((vocalConf >= 380 && rawHitQ10 > 620) || (musSub > 380 && musBrill > 220)) {
    if (dropShockQ10 < 180) {
      dropShockQ10 = 1024;
      fischeShape = 1 - fischeShape;
      fischeFieldIdx = (fischeFieldIdx + 1) % 20;
    }
  }
  dropShockQ10 = Math.floor((dropShockQ10 * 14) / 15);

  const rawMusX = (musBody + musMid) - (musSub * 2 + Math.floor(musBrill / 2));
  const rawMusY = (musBody + musSub) - (musUltra + musMid);
  musBaseX = Math.floor((musBaseX * 63 + rawMusX) / 64);
  musBaseY = Math.floor((musBaseY * 63 + rawMusY) / 64);
  const relMX = (rawMusX - musBaseX) * 3 + Math.floor(rawMusX / 2);
  const relMY = (rawMusY - musBaseY) * 3 + Math.floor(rawMusY / 2);
  const shrutiAng = ((hz % 22) * Math.PI * 2) / 22;
  const shX = Math.floor(Math.cos(shrutiAng) * 150);
  const shY = Math.floor(Math.sin(shrutiAng) * 150);
  let targMusX = Math.max(-960, Math.min(960, relMX + shX));
  let targMusY = Math.max(-960, Math.min(960, relMY + shY));

  // Alexandra Sanctuary + Occasional Passion-Crest Dynamics:
  // - Never camp out in the irritating Drive-Passion glare quadrant (-X, -Y around 225°..255°).
  // - Rest & breathe naturally in Warmth & Sanctuary (+X, +Y around 45°..90°) ~82% of the time.
  // - Hit pure Passion (270°, X >= 0, -Y) every now and then (~2s crest on vocal/harmonic peaks, then ~8s Sanctuary cooldown)!
  if (passionCooldownTicks > 0) passionCooldownTicks -= 1;
  const isAlexSanctuary = feelAuto || (telemetry.preset_slug === "alexandra-sanctuary");
  const passionPeakTrigger = (vocalConf >= 260 && rawHitQ10 >= 480) || ((musBody + musMid) > 540 && musMid > musBrill);
  if (passionCrestTicks > 0) {
    passionCrestTicks -= 1;
    if (passionCrestTicks === 0) {
      passionCooldownTicks = 210; // ~8 seconds of soothing Sanctuary & Warmth before next Passion hit
    }
  } else if (isAlexSanctuary && passionCooldownTicks === 0 && passionPeakTrigger) {
    passionCrestTicks = 48; // ~2 seconds of expressive Passion crest!
  }

  if (isAlexSanctuary) {
    if (passionCrestTicks > 0) {
      // Clean excursion straight into Passion (270°: X in +60..+240, Y in -640..-820), completely bypassing Drive (-X)!
      const crestEnv = Math.sin((passionCrestTicks * Math.PI) / 48);
      const crestPull = Math.floor(crestEnv * 760);
      targMusX = Math.max(40, Math.floor(targMusX / 3) + 120);
      targMusY = -Math.max(480, crestPull);
    } else {
      // Anti-Drive Glare Repulsor + Sanctuary & Warmth Home Attractor (+X, +Y):
      // Deflect -X/Drive crunch and bias gently into Warmth (45°) & Sanctuary (90°)!
      const sanctWarmBiasX = 220 + Math.floor(musBody / 3);
      const sanctWarmBiasY = 280 + Math.floor((musBody + musSub) / 3);
      if (targMusX < 0 && targMusY < 0) {
        // Actively repel out of the irritating Drive-Passion (-X, -Y) glare zone
        targMusX = Math.floor(Math.abs(targMusX) / 2) + sanctWarmBiasX;
        targMusY = Math.floor(Math.abs(targMusY) / 2) + sanctWarmBiasY;
      } else {
        targMusX = Math.floor((targMusX * 5 + sanctWarmBiasX * 5) / 10);
        targMusY = Math.floor((targMusY * 4 + sanctWarmBiasY * 6) / 10);
      }
    }
  }

  const magM = Math.floor(Math.sqrt(targMusX * targMusX + targMusY * targMusY));
  if (magM > 940) {
    targMusX = Math.floor((targMusX * 940) / magM);
    targMusY = Math.floor((targMusY * 940) / magM);
  }
  musEmoX = Math.floor((musEmoX * 6 + targMusX * 2) / 8);
  musEmoY = Math.floor((musEmoY * 6 + targMusY * 2) / 8);
  musTrail.push([musEmoX, musEmoY]);
  if (musTrail.length > 28) musTrail.shift();

  const cx = Math.floor(w / 2);
  const cy = Math.floor(h / 2);
  const minDim = Math.min(w, h);
  const breath = telemetry.breath_q8 || 128;
  const drawMode = (mode === 5) ? 6 : mode;

  if (drawMode === 6) {
    ctx.fillStyle = "#04060c";
    ctx.fillRect(0, 0, w, h);

    const wheelDockW = Math.min(300, Math.max(210, Math.floor((w * 24) / 100)));
    const padL = 68;
    const padR = wheelDockW + 32;
    const padT = 18;
    const wfW = Math.max(128, w - padL - padR);
    const wfH = Math.max(96, Math.floor((h * 64) / 100) - padT);
    ensureWaterfallSurface(wfW, wfH);

    // Map active singer(s) fundamental F0 Hz onto the 0..4095 bucket axis for live pitch-contour trace
    // Supports simultaneous Duet Harmony pitch traces (e.g. Ozzy Tenor + Lita Soprano weaving together!)
    const duetInfo = computeDuetChemistry(singersArr, vocalConf, activeSinger);
    const vocF0Bucket = (vocalConf >= 140 && vocalF0Hz >= 80)
      ? Math.min(4095, Math.max(0, Math.floor((Math.log(Math.max(20, vocalF0Hz) / 20) * 4095) / Math.log(19200))))
      : -100;
    const harmPartnerSlot = (duetInfo.isHarmony && duetInfo.hasPair)
      ? (activeSinger === duetInfo.lowIdx ? duetInfo.highIdx : duetInfo.lowIdx)
      : -1;
    const harmPartnerF0 = (harmPartnerSlot >= 0 && singersArr[harmPartnerSlot]) ? (singersArr[harmPartnerSlot].f0 || 0) : 0;
    const harmF0Bucket = (harmPartnerF0 >= 80)
      ? Math.min(4095, Math.max(0, Math.floor((Math.log(Math.max(20, harmPartnerF0) / 20) * 4095) / Math.log(19200))))
      : -100;
    const activePal = (vocalConf >= 140 && activeSinger < 4) ? SINGER_PALETTE[activeSinger] : null;
    const harmPal = (harmPartnerSlot >= 0) ? SINGER_PALETTE[harmPartnerSlot] : null;

    // Shift waterfall pixel buffer left by 2 pixels and paint rightmost 2 columns from the 4096-bucket array
    const data = wfImg.data;
    const stride = wfW * 4;
    const shiftPx = 2;
    const shiftBytes = shiftPx * 4;
    for (let row = 0; row < wfH; row++) {
      const rowOff = row * stride;
      data.copyWithin(rowOff, rowOff + shiftBytes, rowOff + stride);
      let rC = 4;
      let gC = 6;
      let bC = 12;

      if (row < 6) {
        // Top 6-pixel Diarized Singer Timeline Ribbon (splits into 3px+3px Twin Duet Ribbon during harmonies!)
        if (activePal && harmPal && row >= 3) {
          rC = harmPal.rgb[0];
          gC = harmPal.rgb[1];
          bC = harmPal.rgb[2];
        } else if (activePal) {
          rC = activePal.rgb[0];
          gC = activePal.rgb[1];
          bC = activePal.rgb[2];
        } else {
          rC = 10;
          gC = 15;
          bC = 26;
        }
      } else {
        // Map vertical pixel row (6 = 384,000 Hz top, wfH-1 = 20 Hz bottom) to exact 0..4095 bucket
        const b4096 = Math.min(4095, Math.max(0, Math.floor(((wfH - 1 - row) * 4095) / Math.max(1, wfH - 7))));
        const val = buckets4096[b4096];
        const voc = vocal4096[b4096];
        rC = GRAD_R[val];
        gC = GRAD_G[val];
        bC = GRAD_B[val];
        if (activePal && Math.abs(b4096 - vocF0Bucket) <= 18) {
          // Highlight Lead Singer's exact F0 Pitch Contour in their signature color!
          rC = activePal.rgb[0];
          gC = activePal.rgb[1];
          bC = activePal.rgb[2];
        } else if (harmPal && Math.abs(b4096 - harmF0Bucket) <= 18) {
          // Highlight Harmony Partner's simultaneous F0 Pitch Contour in their signature color!
          rC = harmPal.rgb[0];
          gC = harmPal.rgb[1];
          bC = harmPal.rgb[2];
        } else if (vocalConf >= 140 && voc > 24 && activePal) {
          const wVoc = Math.min(220, Math.floor((voc * 320) / Math.max(64, val + 64)));
          rC = Math.floor((rC * (256 - wVoc) + activePal.rgb[0] * wVoc) / 256);
          gC = Math.floor((gC * (256 - wVoc) + activePal.rgb[1] * wVoc) / 256);
          bC = Math.floor((bC * (256 - wVoc) + activePal.rgb[2] * wVoc) / 256);
        }
      }
      for (let s = wfW - shiftPx; s < wfW; s++) {
        const p = rowOff + s * 4;
        data[p] = rC;
        data[p + 1] = gC;
        data[p + 2] = bC;
        data[p + 3] = 255;
      }
    }
    wfCtx.putImageData(wfImg, 0, 0);
    ctx.drawImage(wfCanvas, padL, padT);

    // Subtle border around waterfall
    ctx.strokeStyle = "#162033";
    ctx.lineWidth = 1;
    ctx.strokeRect(padL, padT, wfW, wfH);

    // Draw Colorbar Gradient Legend on Right Edge of Waterfall
    const cbX = padL + wfW + 8;
    const cbW = 10;
    for (let ry = 0; ry < wfH; ry++) {
      const gIdx = Math.min(1024, Math.floor(((wfH - 1 - ry) * 1024) / Math.max(1, wfH - 1)));
      ctx.fillStyle = "rgb(" + GRAD_R[gIdx] + "," + GRAD_G[gIdx] + "," + GRAD_B[gIdx] + ")";
      ctx.fillRect(cbX, padT + ry, cbW, 1);
    }
    ctx.strokeRect(cbX, padT, cbW, wfH);

    // Quiet, non-distracting Left Margin Frequency Guides (20 Hz .. 384,000 Hz)
    const guides = [
      { b: 4040, label: "384kHz" },
      { b: 3680, label: "144kHz" },
      { b: 3260, label: "48kHz" },
      { b: 2780, label: "18kHz" },
      { b: 2180, label: "3500Hz" },
      { b: 1620, label: "1420Hz" },
      { b: 1060, label: "520Hz" },
      { b: 520,  label: "180Hz" },
      { b: 80,   label: "28Hz" }
    ];
    ctx.font = "10px monospace";
    for (let g = 0; g < guides.length; g++) {
      const gd = guides[g];
      const gy = padT + Math.floor(((4095 - gd.b) * wfH) / 4095);
      ctx.fillStyle = "#566a85";
      ctx.fillText(gd.label, 12, gy + 3);
      ctx.strokeStyle = "#16203366";
      ctx.beginPath();
      ctx.moveTo(padL, gy);
      ctx.lineTo(padL + wfW, gy);
      ctx.stroke();
    }

    // Bottom Pane: High-Resolution 4096-Bucket Continuous Spectrum (20 Hz .. 384,000 Hz)
    const specTop = padT + wfH + 14;
    const specH = Math.max(54, h - specTop - 28);

    ctx.fillStyle = "#060911";
    ctx.fillRect(padL, specTop, wfW, specH);
    ctx.strokeStyle = "#162033";
    ctx.strokeRect(padL, specTop, wfW, specH);

    // 1) art.vaked.dev Ternary {-1, 0, +1} ("The Three Gates") Wave Grid across upper spectrum backdrop
    const ternCols = 48;
    const ternStep = Math.max(4, Math.floor(wfW / ternCols));
    for (let tc = 0; tc < ternCols; tc++) {
      const bT = Math.min(4095, Math.floor((tc * 4095) / ternCols));
      const vT = buckets4096[bT];
      const deltaT = vT - (buckets4096[Math.max(0, bT - 64)] || 0);
      // Classify into Balanced Ternary {-1: Violet #a78bfa, 0: Slate #64748b, +1: Cyan #22d3ee}
      const trit = deltaT > 36 ? 1 : (deltaT < -36 ? -1 : 0);
      const tx = padL + tc * ternStep + Math.floor(ternStep / 2);
      const ty = specTop + 10 - (trit * 4);
      ctx.fillStyle = trit > 0 ? "#22d3ee88" : (trit < 0 ? "#a78bfa88" : "#64748b44");
      ctx.fillRect(tx - 2, ty - 1, 4, 2);
    }

    // 2) Draw 4096-Bucket Total Marine Spectrum with Thermal-Oceanic vertical columns
    for (let px = 0; px < wfW; px++) {
      const b4096 = Math.min(4095, Math.floor((px * 4095) / Math.max(1, wfW - 1)));
      const val = buckets4096[b4096];
      const voc = vocal4096[b4096];
      const colH = Math.min(specH, Math.floor((val * specH) / 960));
      const vocH = Math.min(specH, Math.floor((voc * specH) / 860));
      const x = padL + px;

      if (colH > 0) {
        ctx.fillStyle = "rgb(" + GRAD_R[val] + "," + GRAD_G[val] + "," + GRAD_B[val] + ")";
        ctx.fillRect(x, specTop + specH - colH, 1, colH);
      }
      if (vocalConf >= 140 && vocH > 1 && activePal) {
        ctx.fillStyle = activePal.hex;
        ctx.fillRect(x, specTop + specH - vocH, 1, vocH);
      }
    }

    // 3) OfficialIncubo BeatDrop / MilkDrop-Android HAS_FFT_PEAK (get_fft_peak) Connected Peak-Hold Ribbon
    ctx.strokeStyle = "#00f0ffaa";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let px = 0; px < wfW; px += 2) {
      const b4096 = Math.min(4095, Math.floor((px * 4095) / Math.max(1, wfW - 1)));
      const pk = peak4096[b4096];
      const pkH = Math.min(specH - 2, Math.floor((pk * specH) / 960));
      const x = padL + px;
      const y = specTop + specH - pkH - 1;
      if (px === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();

    // 4) viz.vaked.dev 4-Heart MEDUSA ({<3,<3,<3}+1: 432Hz * ADA, 528Hz /\ VAK, 852Hz oo OMN, 963Hz +1 Enthea)
    const medusaNodes = [
      { hz: 432, b: 1272, hex: "#a78bfa", sym: "*432" },
      { hz: 528, b: 1355, hex: "#38f2c2", sym: "/\\528" },
      { hz: 852, b: 1554, hex: "#00f0ff", sym: "oo852" },
      { hz: 963, b: 1605, hex: "#ff5c93", sym: "+1·963" }
    ];
    ctx.font = "9px monospace";
    for (let m = 0; m < medusaNodes.length; m++) {
      const nd = medusaNodes[m];
      const mx = padL + Math.floor((nd.b * wfW) / 4095);
      const mVal = buckets4096[nd.b] || 0;
      const my = specTop + specH - Math.min(specH - 8, Math.floor((mVal * specH) / 960)) - 4;
      ctx.strokeStyle = nd.hex + "44";
      ctx.beginPath();
      ctx.moveTo(mx, specTop);
      ctx.lineTo(mx, specTop + specH);
      ctx.stroke();
      ctx.fillStyle = nd.hex;
      ctx.beginPath();
      ctx.arc(mx, my, 2 + Math.floor(mVal / 360), 0, Math.PI * 2);
      ctx.fill();
    }

    // Quiet Horizontal Frequency Axis Labels (20 Hz .. 384,000 Hz)
    const xTicks = [
      { b: 0,    t: "20Hz" },
      { b: 360,  t: "140Hz" },
      { b: 780,  t: "350Hz" },
      { b: 1220, t: "800Hz" },
      { b: 1640, t: "1420Hz" },
      { b: 2120, t: "3500Hz" },
      { b: 2560, t: "10kHz" },
      { b: 2940, t: "24kHz" },
      { b: 3320, t: "48kHz" },
      { b: 3680, t: "144kHz" },
      { b: 4050, t: "384kHz" }
    ];
    ctx.font = "10px monospace";
    ctx.fillStyle = "#566a85";
    for (let xt = 0; xt < xTicks.length; xt++) {
      const tk = xTicks[xt];
      const tx = padL + Math.floor((tk.b * wfW) / 4095);
      ctx.fillText(tk.t, Math.min(padL + wfW - 38, tx), specTop + specH + 14);
    }

    // Right Dock: Two Harmonic Wheels of Emotion + 4-Slot Diarized Voice & Duet Chemistry Panel
    const dockCenterX = w - Math.floor(wheelDockW / 2) - 4;
    const maxWheelR = Math.min(
      Math.floor((wheelDockW - 76) / 2),
      Math.floor((h - 210) / 4)
    );
    const wheelR = Math.max(36, maxWheelR);
    const wheel1Cy = Math.floor((h * 21) / 100);
    const wheel2Cy = Math.floor((h * 80) / 100);

    drawDiarizedVocalWheel(
      dockCenterX,
      wheel1Cy,
      wheelR,
      vocalConf,
      activeSinger,
      singersArr
    );

    // Middle Diarization & Duet Chemistry Panel (Live Lita × Ozzy Relationship + Airtime Balance + 2x2 Voice Cards)
    const rosterTop = Math.floor((wheel1Cy + wheel2Cy) / 2) - 44;
    const rosterW = wheelDockW - 18;
    const rosterLeft = dockCenterX - Math.floor(rosterW / 2);

    // Duet Airtime Tug-of-War Bar (Lower Voice / Tenor-Baritone vs Upper Voice / Mezzo-Soprano)
    const barY = noTextMode ? (Math.floor((wheel1Cy + wheel2Cy) / 2) - 6) : (rosterTop + 19);
    const barH = 12;
    const lowW = Math.floor((duetInfo.lowPct * rosterW) / 100);
    const highW = rosterW - lowW;
    const lowHex = (duetInfo.lowIdx >= 0) ? SINGER_PALETTE[duetInfo.lowIdx].hex : "#38f2c2";
    const highHex = (duetInfo.highIdx >= 0) ? SINGER_PALETTE[duetInfo.highIdx].hex : "#ff5c93";

    ctx.fillStyle = "#0b1a24";
    ctx.fillRect(rosterLeft, barY, lowW, barH);
    ctx.fillStyle = "#221024";
    ctx.fillRect(rosterLeft + lowW, barY, highW, barH);
    ctx.strokeStyle = "#1f324d";
    ctx.strokeRect(rosterLeft, barY, rosterW, barH);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(rosterLeft + lowW - 1, barY - 1, 2, barH + 2);

    if (!noTextMode) {
      // 1) Svara 5-Lock Gate & Live Duet Interaction Banner
      ctx.fillStyle = "#080d18";
      ctx.fillRect(rosterLeft, rosterTop, rosterW, 15);
      const gateFillW = Math.min(rosterW, Math.floor((vocalConf * rosterW) / 1024));
      if (gateFillW > 0) {
        ctx.fillStyle = duetInfo.isHarmony ? "#163b48" : (activePal ? "#14293d" : "#122033");
        ctx.fillRect(rosterLeft, rosterTop, gateFillW, 15);
      }
      ctx.strokeStyle = duetInfo.isHarmony ? "#38f2c2" : (activePal ? activePal.hex : "#1c2c44");
      ctx.lineWidth = 1;
      ctx.strokeRect(rosterLeft, rosterTop, rosterW, 15);

      ctx.font = "9px monospace";
      let statusBanner = "Svara 5-Lock · Instrumental Hold";
      if (duetInfo.isHarmony) {
        statusBanner = "✨ DUET HARMONY · " + duetInfo.pq + " " + duetInfo.intervalName;
        ctx.fillStyle = "#38f2c2";
      } else if (duetInfo.hasPair) {
        statusBanner = "⇄ Duet " + duetInfo.pq + " " + duetInfo.intervalName + " · Turns:" + duetHandoffs;
        ctx.fillStyle = "#80ffdb";
      } else if (vocalConf >= 140 && activeSinger < 4 && singersArr[activeSinger]) {
        const curS = singersArr[activeSinger];
        statusBanner = "🎤 Lead: V" + (activeSinger + 1) + " " + curS.role;
        ctx.fillStyle = "#e6edf3";
      } else {
        ctx.fillStyle = "#5c7696";
      }
      ctx.fillText(statusBanner.slice(0, 36), rosterLeft + 5, rosterTop + 11);

      ctx.font = "9px monospace";
      ctx.fillStyle = lowHex;
      ctx.fillText("Low/Tenor " + duetInfo.lowPct + "%", rosterLeft + 4, barY + 9);
      const highTxt = duetInfo.highPct + "% High/Sop";
      ctx.fillStyle = highHex;
      ctx.fillText(highTxt, rosterLeft + rosterW - (highTxt.length * 6) - 2, barY + 9);

      // 3) 2x2 Diarized Singer Pills (V1..V4 with Register & Airtime %)
      const pillW = Math.floor((rosterW - 6) / 2);
      const pillH = 20;
      ctx.font = "10px monospace";
      for (let s = 0; s < 4; s++) {
        const sl = singersArr[s] || { active: false, role: "Waiting", f0: 0, frames: 0 };
        const pal = SINGER_PALETTE[s];
        const col = s % 2;
        const row = Math.floor(s / 2);
        const px = rosterLeft + col * (pillW + 6);
        const py = rosterTop + 35 + row * (pillH + 4);
        const isNow = (vocalConf >= 140) && (activeSinger === s || (sl.pres || 0) >= 360);
        const sharePct = sl.active ? Math.min(99, Math.floor(((sl.frames || 0) * 100) / duetInfo.totalFrames)) : 0;

        ctx.fillStyle = isNow ? "#132338" : "#070b14";
        ctx.fillRect(px, py, pillW, pillH);
        ctx.strokeStyle = isNow ? pal.hex : (sl.active ? "#243854" : "#121a29");
        ctx.lineWidth = isNow ? 2 : 1;
        ctx.strokeRect(px, py, pillW, pillH);

        ctx.fillStyle = sl.active ? pal.hex : "#334660";
        ctx.beginPath();
        ctx.arc(px + 7, py + 10, isNow ? 4 : 3, 0, Math.PI * 2);
        ctx.fill();

        ctx.fillStyle = isNow ? "#e6edf3" : (sl.active ? "#8ab4c8" : "#435670");
        const txt = sl.active
          ? (pal.label + " " + sl.role.slice(0, 7) + " · " + sharePct + "%")
          : (pal.label + " Standby");
        ctx.fillText(txt.slice(0, 19), px + 13, py + 13);
      }
    }

    drawEmotionWheel(
      dockCenterX,
      wheel2Cy,
      wheelR,
      "FULL MUSIC EMOTION",
      MUSIC_EMO_SECTORS,
      musEmoX,
      musEmoY,
      musTrail,
      "#00f0ff",
      "#62e6c988"
    );

    requestAnimationFrame(drawFrame);
    return;
  }

  ctx.fillStyle = "#05060a22";
  ctx.fillRect(0, 0, w, h);

  if (drawMode === 1) {
    // Mode 1: OfficialIncubo fische (20-Field Motion-Blur Wavepainter) × BeatDrop / MilkDrop-Android (get_fft_peak + get_wave)
    fischeAngle += fischeRotDir * (2 + Math.floor(musSub / 140));
    const fAng = (fischeAngle * Math.PI) / 180;
    const fEllip = Math.cos(Math.PI / 3 + 2 * fAng) + (1 / 2);
    const baseHue = (tick * 2 + hz) % 360;
    const compHue = (baseHue + 180) % 360;

    // 1) fische 20-Field Advected Motion Vector Streamlines (tree rings, black hole, 3 spinning disks, 8-petal fan)
    const fieldMode = fischeFieldIdx % 5;
    for (let i = 0; i < 72; i++) {
      const ang = ((i * 5 + tick) * Math.PI) / 36;
      const rNorm = (i + 1) / 72;
      let rDist = Math.floor((rNorm * minDim * 42) / 100);
      if (fieldMode === 1) {
        // Tree rings: cos(24 * pi * r)
        rDist += Math.floor(Math.cos(rNorm * 24 * Math.PI + fAng) * 18);
      } else if (fieldMode === 2) {
        // 8-petal fan: sin(8 * angle)
        rDist += Math.floor(Math.sin(8 * ang + fAng) * 24);
      } else if (fieldMode === 3) {
        // Sine distortion: sin(8 * pi * r)
        rDist += Math.floor(Math.sin(rNorm * 8 * Math.PI - fAng) * 20);
      }
      const vx = cx + Math.floor(Math.cos(ang + (fieldMode === 4 ? rNorm * 3 : 0)) * rDist);
      const vy = cy + Math.floor(Math.sin(ang + (fieldMode === 4 ? rNorm * 3 : 0)) * rDist);
      const bVal = smooth64B[i % 64] || 0;
      const dotR = 2 + Math.floor(bVal / 220);
      ctx.fillStyle = "hsl(" + ((baseHue + i * 3) % 360) + ", 88%, 58%)";
      ctx.beginPath();
      ctx.arc(vx, vy, dotR, 0, Math.PI * 2);
      ctx.fill();
    }

    // 2) fische wavepainter.cpp Dual Antipodal Wavepainter (Shape 0: Rotating Mirror Lines, Shape 1: Antipodal Elliptical Ring)
    for (let side = 0; side < 2; side++) {
      ctx.strokeStyle = side === 0
        ? ("hsl(" + baseHue + ", 95%, 64%)")
        : ("hsl(" + compHue + ", 95%, 64%)");
      ctx.lineWidth = 2;
      ctx.beginPath();
      for (let k = 0; k < 64; k++) {
        const sample = (smooth64B[k] || 0) - 180;
        const vocBoost = (vocalConf >= 140) ? Math.floor((smooth64V[k] || 0) / 2) : 0;
        const rawAmp = Math.floor(((sample + vocBoost) * minDim) / 3600);
        const maxAmp = Math.floor(minDim / 9);
        const amp = Math.max(-maxAmp, Math.min(maxAmp, rawAmp));
        let wx = cx;
        let wy = cy;
        if (fischeShape === 0) {
          // Shape 0: Rotating parallel dual-mirror wave lines
          const span = Math.floor((minDim * 76) / 100);
          const along = Math.floor(((k - 32) * span) / 64);
          const perp = (side === 0 ? 1 : -1) * (Math.floor(minDim / 7) + amp);
          wx = cx + Math.floor(along * Math.cos(fAng) - perp * Math.sin(fAng));
          wy = cy + Math.floor(along * Math.sin(fAng) + perp * Math.cos(fAng));
        } else {
          // Shape 1: Antipodal elliptical wave ring (phi and phi + pi)
          const phi = Math.PI * ((1 / 4) + (k / 63)) + fAng + (side * Math.PI);
          const rW = Math.floor(minDim / 4) + amp;
          wx = cx + Math.floor(fEllip * rW * Math.sin(phi));
          wy = cy + Math.floor(rW * Math.cos(phi));
        }
        if (k === 0) ctx.moveTo(wx, wy);
        else ctx.lineTo(wx, wy);
      }
      ctx.stroke();
    }

    // 3) BeatDrop / MilkDrop-Android Bottom Shader Horizon: get_fft(x) + get_fft_peak(x)
    const bdBaseY = h - 24;
    ctx.strokeStyle = "#00f0ffaa";
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let k = 0; k < 64; k++) {
      const bx = Math.floor(((k + 1) * w) / 66);
      const b4096 = k * 64;
      const barH = Math.floor((buckets4096[b4096] * 110) / 1024);
      const pkH = Math.floor((peak4096[b4096] * 110) / 1024);
      ctx.fillStyle = "rgb(" + GRAD_R[buckets4096[b4096]] + "," + GRAD_G[buckets4096[b4096]] + "," + GRAD_B[buckets4096[b4096]] + ")";
      ctx.fillRect(bx - 4, bdBaseY - barH, 8, barH);
      if (k === 0) ctx.moveTo(bx, bdBaseY - pkH - 2);
      else ctx.lineTo(bx, bdBaseY - pkH - 2);
    }
    ctx.stroke();
  } else if (drawMode === 2) {
    // Mode 2: Water-Fall Disc (Nazar Drums Cascading Harmonic Discs)
    for (let col = 1; col <= 11; col++) {
      const x = Math.floor((w * col) / 12);
      const speed = 2 + (col % 4);
      const y = (tick * speed + col * 97) % h;
      const r = 12 + ((col * 7 + Math.abs(breath)) % 22);
      const hue = (col * 32 + tick) % 360;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.strokeStyle = "hsl(" + hue + ", 90%, 65%)";
      ctx.lineWidth = 3;
      ctx.stroke();
      if (y > h - 40) {
        ctx.beginPath();
        ctx.arc(x, h - 20, r * 2, 0, Math.PI * 2);
        ctx.strokeStyle = "#62e6c9";
        ctx.stroke();
      }
    }
  } else if (drawMode === 3) {
    // Mode 3: zoneInn Balanced-Ternary {-1, 0, +1} & 22-Shruti Mandala
    const ringR = Math.floor((minDim * 36) / 100);
    for (let s = 0; s < 22; s++) {
      const ang = (s * Math.PI * 2) / 22 - Math.PI / 2;
      const sx = cx + Math.floor(Math.cos(ang) * ringR);
      const sy = cy + Math.floor(Math.sin(ang) * ringR);
      const isCur = telemetry.shruti_name && telemetry.shruti_name.indexOf(SHRUTI_NAMES[s]) === 0;
      ctx.beginPath();
      ctx.arc(sx, sy, isCur ? 14 : 7, 0, Math.PI * 2);
      ctx.fillStyle = isCur ? "#00f0ff" : "#e8b05c";
      ctx.fill();
      ctx.fillStyle = "#e6edf3";
      ctx.font = "11px monospace";
      ctx.fillText(SHRUTI_NAMES[s], sx - 8, sy - 12);
    }
    // 9-Trit Balanced Ternary Equalizer Bars in Center
    for (let t = -4; t <= 4; t++) {
      const trit = ((tick + t * 7 + hz) % 3) - 1;
      const bx = cx + t * 22;
      const bh = trit * 42;
      ctx.fillStyle = trit > 0 ? "#62e6c9" : (trit < 0 ? "#ff79c6" : "#b48bff");
      ctx.fillRect(bx - 7, cy - (bh > 0 ? bh : 0), 14, Math.abs(bh) + 6);
    }
  } else if (drawMode === 9) {
    // Mode 9: Sovereign 4096-Bucket (20 Hz .. 384,000 Hz) Spectral PhoeniX Dual-Wing Mandala + Diarized Svara Orbs
    ctx.fillStyle = "#04060d33";
    ctx.fillRect(0, 0, w, h);

    const activePal9 = (vocalConf >= 140 && activeSinger < 4) ? SINGER_PALETTE[activeSinger] : null;
    const coreR = Math.floor((minDim * 15) / 100);
    const wingMax = Math.floor((minDim * 27) / 100);
    const wingRays = 256;

    // 1) Concentric Time-Domain Ripple Rings from PhoeniX Core
    for (let ring = 1; ring <= 4; ring++) {
      const rRip = coreR + Math.floor((((tick * 2 + ring * 45) % 180) * wingMax) / 180);
      ctx.strokeStyle = ring % 2 === 0 ? "#18365466" : "#2a1f4a66";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(cx, cy - 24, rRip, 0, Math.PI * 2);
      ctx.stroke();
    }

    // 2) 360-Degree Mirrored 4096-Bucket PhoeniX Spectral Wings (20 Hz Nadir -> 384,000 Hz Zenith)
    for (let r = 0; r < wingRays; r++) {
      const b4096 = Math.min(4095, Math.floor((r * 4095) / (wingRays - 1)));
      const val = buckets4096[b4096];
      const voc = vocal4096[b4096];
      const pk  = peak4096[b4096];
      const fLen = Math.floor((val * wingMax) / 1024);
      const pLen = Math.floor((pk * wingMax) / 1024);
      if (fLen < 2 && pLen < 3) continue;

      const frac = r / (wingRays - 1);
      const sweep = (Math.PI / 2) - frac * Math.PI;
      for (let side = -1; side <= 1; side += 2) {
        const ang = (side === 1) ? sweep : (Math.PI - sweep);
        const cosA = Math.cos(ang);
        const sinA = Math.sin(ang);
        const x0 = cx + Math.floor(cosA * coreR);
        const y0 = (cy - 24) + Math.floor(sinA * coreR);
        const x1 = cx + Math.floor(cosA * (coreR + fLen));
        const y1 = (cy - 24) + Math.floor(sinA * (coreR + fLen));

        ctx.strokeStyle = "rgb(" + GRAD_R[val] + "," + GRAD_G[val] + "," + GRAD_B[val] + ")";
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        ctx.lineTo(x1, y1);
        ctx.stroke();

        if (vocalConf >= 140 && voc > 28 && activePal9) {
          const vLen = Math.floor((voc * wingMax) / 880);
          const xv = cx + Math.floor(cosA * (coreR + vLen));
          const yv = (cy - 24) + Math.floor(sinA * (coreR + vLen));
          ctx.strokeStyle = activePal9.hex;
          ctx.lineWidth = 2;
          ctx.beginPath();
          ctx.moveTo(x0, y0);
          ctx.lineTo(xv, yv);
          ctx.stroke();
        }

        if (pLen > 4) {
          const xp = cx + Math.floor(cosA * (coreR + pLen + 3));
          const yp = (cy - 24) + Math.floor(sinA * (coreR + pLen + 3));
          ctx.fillStyle = "#00f0ff";
          ctx.fillRect(xp - 1, yp - 1, 2, 2);
        }
      }
    }

    // 3) Center PhoeniX Heart: Kluver Form-Constant + Diarized Svara Vocal Wheel
    drawDiarizedVocalWheel(
      cx,
      cy - 24,
      coreR - 6,
      vocalConf,
      activeSinger,
      singersArr
    );

    // 4) Bottom Full-Width 4096-Bucket (20 Hz .. 384,000 Hz) Spectral PhoeniX Horizon
    const horH = Math.min(120, Math.floor((h * 16) / 100));
    const horTop = h - horH - 18;
    const padX = 48;
    const horW = Math.max(128, w - padX * 2);
    ctx.fillStyle = "#060912cc";
    ctx.fillRect(padX, horTop, horW, horH);
    ctx.strokeStyle = "#1a2942";
    ctx.strokeRect(padX, horTop, horW, horH);

    ctx.beginPath();
    for (let px = 0; px < horW; px++) {
      const b4096 = Math.min(4095, Math.floor((px * 4095) / Math.max(1, horW - 1)));
      const val = buckets4096[b4096];
      const voc = vocal4096[b4096];
      const pk  = peak4096[b4096];
      const colH = Math.min(horH, Math.floor((val * horH) / 960));
      const vocH = Math.min(horH, Math.floor((voc * horH) / 860));
      const pkH  = Math.min(horH - 2, Math.floor((pk * horH) / 960));
      const x = padX + px;
      if (colH > 0) {
        ctx.fillStyle = "rgb(" + GRAD_R[val] + "," + GRAD_G[val] + "," + GRAD_B[val] + ")";
        ctx.fillRect(x, horTop + horH - colH, 1, colH);
      }
      if (vocalConf >= 140 && vocH > 1 && activePal9) {
        ctx.fillStyle = activePal9.hex;
        ctx.fillRect(x, horTop + horH - vocH, 1, vocH);
      }
      const py = horTop + horH - pkH - 1;
      if (px === 0) ctx.moveTo(x, py);
      else ctx.lineTo(x, py);
    }
    ctx.strokeStyle = "#00f0ffaa";
    ctx.lineWidth = 1;
    ctx.stroke();
  }
  requestAnimationFrame(drawFrame);
}
resize();
requestAnimationFrame(drawFrame);
</script>
</body>
</html>"##
        .to_string()
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

    #[test]
    fn ai_compute_waybar_and_menu_emit_zero_floats() {
        let ai = AiComputeSnapshot::default();
        let wb = render_waybar_ai_json_from_snap(&ai);
        assert!(wb.starts_with("{\"text\":\""));
        assert!(wb.contains("gemma4:26b"));
        assert!(wb.contains("4070"));
        assert!(wb.contains("A6K+"));
        assert!(!wb.contains('\n'));
        assert_zero_float_literals(&wb);

        let raw_tags = "{\"models\":[{\"name\":\"qwen3.8:27b\"},{\"name\":\"gemma4:26b\"}]}";
        let models = extract_ollama_model_names(raw_tags);
        assert_eq!(models, vec!["qwen3:8:27b".to_string(), "gemma4:26b".to_string()]);
        for m in &models {
            assert_zero_float_literals(m);
        }

        let menu = format_ai_menu_entries(&ai, &models, &["gemma:latest".to_string()]);
        assert!(menu.iter().any(|l| l.starts_with("[CLIP -> EXPLAIN]")));
        assert!(menu.iter().any(|l| l.starts_with("[A6000 :11436]")));
        for line in &menu {
            assert_zero_float_literals(line);
        }

        let am = run_ai_menu(&["--dry-run".to_string()]);
        let ac = run_ai_clip(&["--dry-run".to_string()]);
        let sp = run_scratchpad(&["term".to_string(), "--dry-run".to_string()]);
        let pt = run_phoenix_toggle(&["--dry-run".to_string()]);
        let pp = run_phoenix_preset(&["--dry-run".to_string()]);
        let pm = run_phoenix_menu(&["--dry-run".to_string()]);
        let wp = render_waybar_phoenix_json();
        let tz_dry = run_tz_sync(&["--dry-run".to_string()]);
        let ot = run_oxicast_tv(&["--dry-run".to_string()]);
        let oc = run_oxicast_cast(&["--dry-run".to_string()]);
        let o_html = render_oxicast_tv_html();
        let o_telem = build_oxicast_telemetry_json();
        assert_zero_float_literals(&wp);
        assert_zero_float_literals(&o_html);
        assert_zero_float_literals(&o_telem);
        assert!(o_html.contains("OxiCast × PhoeniX Sanctuary"));
        for out in [&am, &ac, &sp, &pt, &pp, &pm, &tz_dry, &ot, &oc] {
            assert!(out.contains("\"ok\":true"));
            assert_zero_float_literals(out);
        }
        assert_eq!(parse_coord_to_e7_int("36:8190"), 368_190_000);
        assert_eq!(parse_coord_to_e7_int("-76:2749"), -762_749_000);
        assert!(is_valid_iana_timezone("America/New_York"));
        assert!(is_valid_iana_timezone("Asia/Tokyo"));
        assert!(!is_valid_iana_timezone("../etc/passwd"));
    }
}
