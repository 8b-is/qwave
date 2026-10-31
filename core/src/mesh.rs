//! Sovereign Nomad Mesh, Honest Captive-Portal Auto-Solver, Anicca Recipe Memory,
//! ESP32 Constellation `MemnetCapsule64` (`:8888`) & Bluetooth Mesh (`qwave_core::mesh`).
//!
//! 100% integer-only (`#![forbid(unsafe_code)]`, `0` floating-point instructions), zero external dependencies:
//! 1. **Free & Open Wi-Fi Discovery (`rank_free_wifi_candidates` / `rank_free_wifi_candidates_with_memory`)**:
//!    Identifies open networks (`--` / `open`) and known Tokyo/global captive-portal networks
//!    (`.Wi2_Free_at_[SK.GROUP]`, `tullys_Wi-Fi`, `0000docomo`, `JR-EAST-FREE-WiFi`, `Metro_Free_Wi-Fi`,
//!    `Tokyo-Free-Wi-Fi`, `Starbucks_Wi2`, `7SPOT`, `LAWSON_Free_Wi-Fi`, `FamilyMart_Wi-Fi`, `FreeWiFi`, `Guest`),
//!    penalizes subscription traps (`Wi2premium`, `Wi2_club`), boosts remembered working portals from
//!    [`PortalMemoryBook`], and ranks them by integer `score_q10`.
//! 2. **Reasonable Honesty Captive Portal Solver (`parse_captive_portal_response_with_identity`)**:
//!    Detects HTTP `301`/`302`/`307` portal redirects, USEN/USPOT-02 `/capi/welcome` SPA portals,
//!    HTML `<meta refresh>`, direct `<a href>` accept links, and HTML `<form>` inputs. Fills in honest
//!    traveler inputs (`email`, `name`, `country`, `lang`, `purpose`, `macaddr`, plus ToS checkboxes
//!    and hidden session tokens) to unlock free Wi-Fi for the laptop, the 4-node ESP32 Constellation,
//!    and nearby peers.
//! 3. **Anicca Portal Recipe Memory (`PortalRecipe` & `PortalMemoryBook`)**:
//!    Remembers how to get through each captive portal (`ssid`, `portal_host`, `strategy`, `action_url`,
//!    `honest_inputs`, `ttl_q8`, `success_cnt`, `fail_streak`, `lease_hint_s`) with Anicca decay so
//!    verified recipes replay immediately when a portal expires or Wi-Fi changes.
//! 4. **ESP32 Sovereign Constellation Mesh (`MemnetCapsule64` 64B UDP `:8888` & `S3TriadWifiCapsule` 132B `TWIF`)**:
//!    Byte-exact binary compatibility with `FLUG-OS` (`ADA:MEDUSA`, `VAK:MEDUSA`, `OMN:MEDUSA`) and
//!    `tdeck-omni` (`SUN:TDECK`) across Wi-Fi UDP `:8888`, ESP-NOW, BLE, and Serial.
//! 5. **Bluetooth BLE (31B) & BNEP/RFCOMM (96B) Sovereign Mesh (`BluetoothMeshFrame`)**:
//!    Packs a 79-byte `MEM|8` `WaveInt` frame + 64-bit `WUPZ` XOR-fold + Tokyo JST timestamp +
//!    hop TTL + CRC-16 into a deterministic binary mesh frame for zero-infrastructure peer relay.

#![forbid(unsafe_code)]

use crate::wave::WaveInt;

/// Magic header for 96-byte BNEP / RFCOMM Sovereign Mesh frames (`"8BM8"`).
pub const MESH_MAGIC_96: [u8; 4] = *b"8BM8";

/// Magic header for 31-byte BLE Legacy Advertising mesh beacons (`"8B"`).
pub const BLE_MAGIC_31: [u8; 2] = *b"8B";

/// Magic header (`0x4D4E`, little-endian `'N','M'`) for 64-byte `MemnetCapsule64` packets on UDP `:8888` / ESP-NOW / LoRa.
pub const MEMNET_MAGIC_U16: u16 = 0x4D4E;

/// Magic header (`"TWIF"`) for 132-byte `S3TriadWifiCapsule` ESP-NOW Wi-Fi share frames.
pub const TWIF_MAGIC_4: [u8; 4] = *b"TWIF";

/// Magic header for persistent Anicca Portal Recipe memory files (`QWPORTAL001`).
pub const PORTAL_MEMORY_MAGIC: &str = "QWPORTAL001";

/// FNV-1a 64-bit offset basis (`0xCBF29CE484222325`) matching `FLUG-OS/src/guardian_mesh.h`.
pub const FNV64_BASIS: u64 = 0xCBF2_9CE4_8422_2325;

/// FNV-1a 64-bit prime (`0x00000100000001B3`) matching `FLUG-OS/src/guardian_mesh.h`.
pub const FNV64_PRIME: u64 = 0x0000_0100_0000_01B3;

/// FNV-1a 32-bit offset basis (`0x811C9DC5`) matching `FLUG-OS/src/guardian_mesh.h`.
pub const FNV32_BASIS: u32 = 0x811C_9DC5;

/// FNV-1a 32-bit prime (`0x01000193`) matching `FLUG-OS/src/guardian_mesh.h`.
pub const FNV32_PRIME: u32 = 0x0100_0193;

/// The 4 Sovereign ESP32 Constellation Nodes (`ADA:MEDUSA`, `VAK:MEDUSA`, `OMN:MEDUSA`, `SUN:TDECK`)
/// verified in `FLUG-OS` (`edaaef6`) and `tdeck-omni` (`893e48a`).
pub const CONSTELLATION_FLOCK_MACS: [(&str, &str, &str); 4] = [
    ("ADA:MEDUSA", "80:b5:4e:db:3b:c4", "*"),
    ("VAK:MEDUSA", "80:b5:4e:f2:02:b0", "/\\"),
    ("OMN:MEDUSA", "80:b5:4e:f2:02:b4", "oo"),
    ("SUN:TDECK", "cc:ba:97:00:45:24", "<>"),
];

/// A candidate free/open or captive-portal Wi-Fi network discovered via passive scan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FreeWifiCandidate {
    pub bssid: String,
    pub ssid: String,
    pub channel: u16,
    pub freq_mhz: u16,
    pub signal_pct: u8,
    pub security: String,
    pub is_open: bool,
    pub is_known_portal_brand: bool,
    pub score_q10: u32,
}

/// Known Tokyo & global free Wi-Fi / captive-portal SSID signatures.
const KNOWN_FREE_PORTAL_SSIDS: &[&str] = &[
    ".wi2_free",
    "wi2_free",
    "sk.group",
    "usen",
    "uspot",
    "tullys_wi-fi",
    "0000docomo",
    "jr-east-free-wifi",
    "jr-central",
    "jr-west",
    "shinkansen",
    "metro_free_wi-fi",
    "tokyo-free-wi-fi",
    "tokyo_free",
    "shinjuku-free-wifi",
    "shinjuku_free_wi-fi",
    "shibuya-wi-fi",
    "starbucks_wi2",
    "at_starbucks_wi2",
    "7spot",
    "lawson_free_wi-fi",
    "familymart_wi-fi",
    "komeda_wi-fi",
    "doutor_free_wi-fi",
    "pronto_free",
    "excelsior",
    "haneda-free-wifi",
    "narita-free-wifi",
    "tokyometro",
    "toei_bus",
    "toei_subway",
    "keio",
    "odakyu",
    "tokyu",
    "seibu",
    "tobu",
    "keikyu",
    "apa_hotel",
    "toyoko-inn",
    "route-inn",
    "dormy-inn",
    "freespot",
    "freewifi",
    "free_wi-fi",
    "free-wifi",
    "guest",
    "airport",
    "hotel",
    "lobby",
];

/// Open SSIDs that require paid carrier/ISP subscriptions (`Wi2premium`, `Wi2_club`, `0000SoftBank`)
/// rather than a free captive portal accept button. Penalized so we never strand Aye on a paywall!
const PAID_SUBSCRIPTION_OPEN_SSIDS: &[&str] = &[
    "wi2premium",
    "wi2_club",
    "wi2premium_club",
    "0000softbank",
    "0001docomo",
    "0001softbank",
    "au_wi-fi",
    "docomo_wifi",
];

/// Parse `nmcli -t -f BSSID,SSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list` output
/// and return ranked free/open or captive-portal Wi-Fi candidates.
pub fn rank_free_wifi_candidates(nmcli_text: &str) -> Vec<FreeWifiCandidate> {
    rank_free_wifi_candidates_with_memory(nmcli_text, None)
}

/// Parse `nmcli -t -f BSSID,SSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list` output
/// and rank candidates using optional [`PortalMemoryBook`] Anicca recipe provenance.
pub fn rank_free_wifi_candidates_with_memory(
    nmcli_text: &str,
    memory: Option<&PortalMemoryBook>,
) -> Vec<FreeWifiCandidate> {
    let mut out = Vec::new();
    for raw_line in nmcli_text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        // Handle both `BSSID:SSID:CHAN:FREQ:SIGNAL:SECURITY` and `IN-USE:BSSID:SSID:...`
        let normalized = line.replace("\\:", "-");
        let raw_parts: Vec<&str> = normalized.split(':').collect();
        let parts: &[&str] = if raw_parts.len() >= 7
            && (raw_parts[0].is_empty() || raw_parts[0] == "*" || raw_parts[0].trim().is_empty())
        {
            &raw_parts[1..]
        } else {
            &raw_parts[..]
        };
        if parts.len() < 6 {
            continue;
        }
        let bssid = parts[0].replace('-', ":");
        let ssid = parts[1].replace('-', ":").trim().to_string();
        if ssid.is_empty() || ssid == "--" {
            continue;
        }
        let channel: u16 = parts[2].trim().parse().unwrap_or(1);
        let freq_mhz: u16 = parts[3]
            .split_whitespace()
            .next()
            .and_then(|s| s.parse().ok())
            .unwrap_or(if channel > 14 { 5180 } else { 2412 });
        let signal_pct: u8 = parts[4].trim().parse().unwrap_or(0);
        let security = parts[5..].join(":").trim().to_string();

        let sec_low = security.to_ascii_lowercase();
        let is_open =
            sec_low.is_empty() || sec_low == "--" || sec_low == "open" || sec_low == "none";
        let ssid_low = ssid.to_ascii_lowercase();
        let is_paid_trap = PAID_SUBSCRIPTION_OPEN_SSIDS
            .iter()
            .any(|pat| ssid_low == *pat || ssid_low.starts_with(pat));
        let is_known_portal_brand = !is_paid_trap
            && KNOWN_FREE_PORTAL_SSIDS
                .iter()
                .any(|pat| ssid_low.contains(pat));

        if !is_open && !is_known_portal_brand {
            continue;
        }

        // Integer utility score in Q10 (0..1600+):
        // - Signal contribution: signal_pct * 6 (up to 600)
        // - Open network bonus: +240
        // - Known Tokyo/portal brand bonus: +160
        // - Direct one-click USEN/SK.GROUP/Tully's/Starbucks bonus: +120
        // - 5 GHz band bonus: +80 (less congestion, faster portal traversal)
        // - Paid subscription wall penalty (`Wi2premium`, `Wi2_club`): -380
        // - Remembered & verified Anicca PortalRecipe bonus: +(ttl_q8 + 160)
        let mut score_q10: i32 = (signal_pct as i32) * 6;
        if is_open {
            score_q10 += 240;
        }
        if is_known_portal_brand {
            score_q10 += 160;
        }
        if ssid_low.contains("wi2_free")
            || ssid_low.contains("sk.group")
            || ssid_low.contains("tullys")
            || ssid_low.contains("starbucks")
        {
            score_q10 += 120;
        }
        if freq_mhz >= 5000 {
            score_q10 += 80;
        }
        if is_paid_trap {
            score_q10 -= 380;
        }
        if let Some(book) = memory {
            if let Some(rec) = book.find_by_ssid(&ssid) {
                if rec.ttl_q8 > 0 && rec.success_cnt > 0 && rec.fail_streak == 0 {
                    score_q10 += 160 + (rec.ttl_q8 as i32);
                } else if rec.fail_streak >= 2 {
                    score_q10 -= (rec.fail_streak as i32) * 120;
                }
            }
        }

        out.push(FreeWifiCandidate {
            bssid,
            ssid,
            channel,
            freq_mhz,
            signal_pct,
            security,
            is_open,
            is_known_portal_brand,
            score_q10: score_q10.max(1) as u32,
        });
    }

    out.sort_by(|a, b| b.score_q10.cmp(&a.score_q10));
    out
}

// ============================================================================
// 2. Reasonable Honesty Captive Portal Input Engine & Parser
// ============================================================================

/// Honest traveler identity profile used when a captive portal requests form fields
/// (`email`, `name`, `country`, `lang`, `purpose`, `macaddr`, etc.).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HonestPortalIdentity {
    pub display_name: String,
    pub email: String,
    pub country: String,
    pub lang: String,
    pub purpose: String,
    pub client_mac: String,
    pub extra_vouched_macs: Vec<String>,
}

impl Default for HonestPortalIdentity {
    fn default() -> Self {
        Self {
            display_name: "Hue (8b.is Traveler)".to_string(),
            email: "guest@8b.is".to_string(),
            country: "JP".to_string(),
            lang: "en".to_string(),
            purpose: "research_and_travel".to_string(),
            client_mac: "a0:b3:39:08:f7:46".to_string(),
            extra_vouched_macs: CONSTELLATION_FLOCK_MACS
                .iter()
                .map(|(_, mac, _)| (*mac).to_string())
                .collect(),
        }
    }
}

impl HonestPortalIdentity {
    /// Return deduplicated list of lowercase MAC addresses to vouch for on MAC-based portals
    /// (the laptop's own `client_mac` first, followed by the 4 ESP32 Constellation MACs and any neighbor MACs).
    pub fn all_vouched_macs(&self) -> Vec<String> {
        let mut macs = Vec::new();
        let primary = self.client_mac.trim().to_ascii_lowercase();
        if !primary.is_empty() {
            macs.push(primary);
        }
        for (_, cmac, _) in CONSTELLATION_FLOCK_MACS {
            let m = cmac.to_ascii_lowercase();
            if !macs.contains(&m) {
                macs.push(m);
            }
        }
        for extra in &self.extra_vouched_macs {
            let m = extra.trim().to_ascii_lowercase();
            if m.len() == 17 && m.chars().filter(|&c| c == ':').count() == 5 && !macs.contains(&m)
            {
                macs.push(m);
            }
        }
        macs
    }
}

/// Synthesize a reasonably honest form input value for a captive portal `<input>` or `<select>` field.
/// Preserves existing non-empty hidden/session values while filling empty text/email/checkbox fields.
pub fn synthesize_honest_field_value(
    field_name: &str,
    field_type: &str,
    existing_value: Option<&str>,
    identity: &HonestPortalIdentity,
) -> String {
    let t_low = field_type.trim().to_ascii_lowercase();
    let n_low = field_name.trim().to_ascii_lowercase();

    // 1. Always preserve non-empty hidden / submit / token values verbatim
    if t_low == "hidden" || t_low == "submit" || t_low == "button" {
        if let Some(val) = existing_value {
            if !val.trim().is_empty() {
                return val.trim().to_string();
            }
        }
    }

    // 2. Checkboxes & Radio buttons for Terms of Service / Agreement
    if t_low == "checkbox" || t_low == "radio" {
        if let Some(val) = existing_value {
            if !val.trim().is_empty() {
                return val.trim().to_string();
            }
        }
        return "1".to_string();
    }

    // 3. If an existing non-empty default value is already set by the portal, keep it unless it's a placeholder
    if let Some(val) = existing_value {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    // 4. Match field name semantics with reasonable honesty
    if t_low == "email"
        || n_low.contains("email")
        || n_low.contains("mail")
        || n_low == "u_id"
        || n_low == "login_id"
    {
        return identity.email.clone();
    }
    if n_low.contains("mac") || n_low == "stamac" || n_low == "client_mac" {
        return identity.client_mac.clone();
    }
    if n_low.contains("country") || n_low.contains("nation") || n_low.contains("region") {
        return identity.country.clone();
    }
    if n_low.contains("lang") || n_low.contains("locale") {
        return identity.lang.clone();
    }
    if n_low.contains("purpose") || n_low.contains("reason") || n_low.contains("visit") {
        return identity.purpose.clone();
    }
    if n_low.contains("age") || n_low.contains("over18") || n_low.contains("adult") {
        return "yes".to_string();
    }
    if n_low.contains("gender") || n_low.contains("birth") {
        // Minimal honest disclosure: USEN/USPOT accepts empty optional demographics
        return String::new();
    }
    if n_low.contains("name")
        || n_low.contains("user")
        || n_low.contains("guest")
        || n_low.contains("visitor")
    {
        return "hue".to_string();
    }
    if n_low.contains("accept")
        || n_low.contains("agree")
        || n_low.contains("terms")
        || n_low.contains("policy")
        || n_low.contains("tos")
        || n_low.contains("connect")
    {
        return "true".to_string();
    }

    "1".to_string()
}

/// Result of probing an HTTP connection for a captive portal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptivePortalAction {
    /// Internet is already open (`HTTP 204` or expected body); no captive portal blocks us.
    InternetOpen,
    /// Captive portal requires following a redirect URL (`HTTP 302`/`307`, `<meta refresh>`, JS redirect, or `<a href>` accept link).
    FollowRedirect { url: String },
    /// Captive portal presented an HTML acceptance form that can be auto-submitted with honest inputs.
    SubmitAcceptanceForm {
        method: String,
        action_url: String,
        form_urlencoded_body: String,
    },
    /// USEN / USPOT-02 / `.Wi2_Free_at_[SK.GROUP]` JSON API captive portal (`POST /capi/welcome`)
    /// that unlocks the laptop's MAC plus our 4 ESP32 Constellation MACs and neighbor MACs.
    SubmitUsenWelcomeJson {
        endpoint_url: String,
        vouched_macs: Vec<String>,
        json_payloads: Vec<String>,
    },
}

/// Inspect a raw HTTP response (`HTTP/1.1 ... \r\n\r\n <body>`) from a captive-portal probe
/// and determine the autonomous traversal action (`InternetOpen`, `FollowRedirect`, `SubmitAcceptanceForm`, or `SubmitUsenWelcomeJson`).
pub fn parse_captive_portal_response(raw_http: &str, base_host: &str) -> CaptivePortalAction {
    parse_captive_portal_response_with_identity(
        raw_http,
        base_host,
        &HonestPortalIdentity::default(),
    )
}

/// Inspect a raw HTTP response with an explicit [`HonestPortalIdentity`] (including client MAC and ESP32 flock MACs).
pub fn parse_captive_portal_response_with_identity(
    raw_http: &str,
    base_host: &str,
    identity: &HonestPortalIdentity,
) -> CaptivePortalAction {
    let (headers, body) = raw_http
        .split_once("\r\n\r\n")
        .or_else(|| raw_http.split_once("\n\n"))
        .unwrap_or((raw_http, ""));
    let first_line = headers.lines().next().unwrap_or("");

    // 1. HTTP 204 No Content or Google/Apple success token => Internet is open
    if first_line.contains(" 204 ")
        || body.contains("<TITLE>Success</TITLE>")
        || (body.contains("Success") && body.len() < 128)
    {
        return CaptivePortalAction::InternetOpen;
    }

    // 2. HTTP 301 / 302 / 303 / 307 / 308 Location header redirect
    for line in headers.lines() {
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("location:") {
            let loc = line["location:".len()..].trim();
            if !loc.is_empty() {
                let resolved = resolve_portal_url(base_host, loc);
                // If redirect Location already points to USEN/USPOT `/captive/?stamac=...`, extract stamac if present!
                return CaptivePortalAction::FollowRedirect { url: resolved };
            }
        }
    }

    let body_low = body.to_ascii_lowercase();
    let host_low = base_host.to_ascii_lowercase();

    // 3. USEN / USPOT-02 / `.Wi2_Free_at_[SK.GROUP]` SPA Captive Portal (`POST /capi/welcome`)
    if host_low.contains("usen")
        || host_low.contains("uspot")
        || body_low.contains("/capi/welcome")
        || body_low.contains("uspot")
        || (body_low.contains("stamac=") && body_low.contains("captive"))
    {
        let origin_host = extract_origin_host(base_host);
        let endpoint_url = resolve_portal_url(&origin_host, "/capi/welcome");
        let mut vouched_macs = identity.all_vouched_macs();
        if let Some(url_mac) = extract_stamac_param(base_host).or_else(|| extract_stamac_param(body))
        {
            let m = url_mac.to_ascii_lowercase();
            if !vouched_macs.contains(&m) {
                vouched_macs.insert(0, m);
            }
        }
        let json_payloads = vouched_macs
            .iter()
            .map(|mac| {
                format!(
                    "{{\"gender\":\"\",\"birth\":\"\",\"macaddr\":\"{}\",\"lang\":\"{}\"}}",
                    mac, identity.lang
                )
            })
            .collect();
        return CaptivePortalAction::SubmitUsenWelcomeJson {
            endpoint_url,
            vouched_macs,
            json_payloads,
        };
    }

    // 4. HTML <form ...> with hidden inputs / honest traveler fields / acceptance buttons
    if let Some((method, action, hidden_pairs)) = extract_html_portal_form(body, identity) {
        let mut pairs = hidden_pairs;
        // Append standard captive-portal ToS acceptance keys
        for (k, v) in [
            ("accept", "true"),
            ("agree", "1"),
            ("terms", "on"),
            ("connect", "1"),
            ("buttonClicked", "4"),
        ] {
            if !pairs.iter().any(|(ek, _)| ek.eq_ignore_ascii_case(k)) {
                pairs.push((k.to_string(), v.to_string()));
            }
        }
        let encoded = pairs
            .into_iter()
            .map(|(k, v)| format!("{}={}", url_encode_component(&k), url_encode_component(&v)))
            .collect::<Vec<_>>()
            .join("&");
        let origin_host = extract_origin_host(base_host);
        return CaptivePortalAction::SubmitAcceptanceForm {
            method,
            action_url: resolve_portal_url(&origin_host, &action),
            form_urlencoded_body: encoded,
        };
    }

    // 5. HTML <meta http-equiv="refresh" content="0;url=...">
    if let Some(idx) = body_low.find("url=") {
        let after = &body[idx + 4..];
        let trimmed = after.trim_start_matches(['"', '\'']);
        let end = trimmed
            .find(|c: char| matches!(c, '"' | '\'' | '>' | ' ' | '\r' | '\n'))
            .unwrap_or(trimmed.len());
        let target = trimmed[..end].trim();
        if !target.is_empty() && !target.starts_with("data:") {
            let origin_host = extract_origin_host(base_host);
            return CaptivePortalAction::FollowRedirect {
                url: resolve_portal_url(&origin_host, target),
            };
        }
    }

    // 6. Direct `<a href="...accept/login/agree/auth/connect...">` accept link (matches FLUG-OS `net_time.h`)
    if let Some(href) = extract_accept_anchor_href(body) {
        let origin_host = extract_origin_host(base_host);
        return CaptivePortalAction::FollowRedirect {
            url: resolve_portal_url(&origin_host, &href),
        };
    }

    // 7. JavaScript `location.href = "..."` or `window.location = "..."` redirect
    if let Some(js_url) = extract_js_location_redirect(body) {
        let origin_host = extract_origin_host(base_host);
        return CaptivePortalAction::FollowRedirect {
            url: resolve_portal_url(&origin_host, &js_url),
        };
    }

    CaptivePortalAction::InternetOpen
}

fn extract_origin_host(base_url_or_host: &str) -> String {
    let trimmed = base_url_or_host.trim();
    let without_scheme = if let Some(idx) = trimmed.find("://") {
        &trimmed[idx + 3..]
    } else {
        trimmed
    };
    without_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(without_scheme)
        .to_string()
}

fn extract_stamac_param(text: &str) -> Option<String> {
    let low = text.to_ascii_lowercase();
    for key in ["stamac=", "client_mac=", "mac=", "macaddr="] {
        if let Some(idx) = low.find(key) {
            let after = &text[idx + key.len()..];
            let end = after
                .find(|c: char| matches!(c, '&' | '"' | '\'' | ' ' | '>' | '\r' | '\n'))
                .unwrap_or(after.len());
            let raw = after[..end].trim().replace("%3A", ":").replace("%3a", ":").replace('-', ":");
            if raw.len() == 17 && raw.chars().filter(|&c| c == ':').count() == 5 {
                return Some(raw.to_ascii_lowercase());
            }
        }
    }
    None
}

pub fn resolve_portal_url(base_host: &str, target: &str) -> String {
    let t = target.trim();
    if t.starts_with("http://") || t.starts_with("https://") {
        t.to_string()
    } else {
        let host = extract_origin_host(base_host);
        if t.starts_with('/') {
            format!("http://{host}{t}")
        } else {
            format!("http://{host}/{t}")
        }
    }
}

fn url_encode_component(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'@' | b':' => {
                out.push(b as char);
            }
            b' ' => out.push('+'),
            _ => {
                out.push('%');
                let hi = b >> 4;
                let lo = b & 0x0F;
                out.push(if hi < 10 { (b'0' + hi) as char } else { (b'A' + (hi - 10)) as char });
                out.push(if lo < 10 { (b'0' + lo) as char } else { (b'A' + (lo - 10)) as char });
            }
        }
    }
    out
}

fn extract_html_portal_form(
    html: &str,
    identity: &HonestPortalIdentity,
) -> Option<(String, String, Vec<(String, String)>)> {
    let low = html.to_ascii_lowercase();
    let form_start = low.find("<form")?;
    let form_rest = &html[form_start..];
    let form_end = low[form_start..]
        .find("</form>")
        .map(|i| i + 7)
        .unwrap_or(form_rest.len());
    let form_block = &form_rest[..form_end];

    let tag_end = form_block.find('>')?;
    let form_tag = &form_block[..tag_end];
    let action = extract_html_attr(form_tag, "action").unwrap_or_else(|| "/login".to_string());
    let method = extract_html_attr(form_tag, "method")
        .unwrap_or_else(|| "POST".to_string())
        .to_ascii_uppercase();

    let mut inputs = Vec::new();
    let mut scan = form_block;
    while let Some(inp_idx) = scan.to_ascii_lowercase().find("<input") {
        let after_inp = &scan[inp_idx..];
        let Some(close_idx) = after_inp.find('>') else {
            break;
        };
        let inp_tag = &after_inp[..close_idx];
        if let Some(name) = extract_html_attr(inp_tag, "name") {
            let ftype = extract_html_attr(inp_tag, "type").unwrap_or_else(|| "text".to_string());
            let existing = extract_html_attr(inp_tag, "value");
            let val =
                synthesize_honest_field_value(&name, &ftype, existing.as_deref(), identity);
            inputs.push((name, val));
        }
        scan = &after_inp[close_idx + 1..];
    }

    Some((method, action, inputs))
}

fn extract_accept_anchor_href(html: &str) -> Option<String> {
    let mut scan = html;
    while let Some(a_idx) = scan.to_ascii_lowercase().find("<a ") {
        let after_a = &scan[a_idx..];
        let Some(close_idx) = after_a.find('>') else {
            break;
        };
        let a_tag = &after_a[..close_idx];
        if let Some(href) = extract_html_attr(a_tag, "href") {
            let h_low = href.to_ascii_lowercase();
            if !h_low.starts_with('#')
                && !h_low.starts_with("javascript:void")
                && (h_low.contains("accept")
                    || h_low.contains("login")
                    || h_low.contains("agree")
                    || h_low.contains("auth")
                    || h_low.contains("connect")
                    || h_low.contains("welcome"))
            {
                return Some(href);
            }
        }
        scan = &after_a[close_idx + 1..];
    }
    None
}

fn extract_js_location_redirect(html: &str) -> Option<String> {
    let low = html.to_ascii_lowercase();
    for pat in ["location.href", "window.location.replace", "window.location"] {
        if let Some(idx) = low.find(pat) {
            let after = &html[idx + pat.len()..];
            if let Some(eq_or_paren) = after.find(['=', '(']) {
                let rest = after[eq_or_paren + 1..].trim_start();
                if let Some(quote) = rest.chars().next() {
                    if quote == '"' || quote == '\'' {
                        let inner = &rest[1..];
                        if let Some(end) = inner.find(quote) {
                            let url = inner[..end].trim();
                            if url.starts_with("http://")
                                || url.starts_with("https://")
                                || url.starts_with('/')
                            {
                                return Some(url.to_string());
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

fn extract_html_attr(tag: &str, attr_name: &str) -> Option<String> {
    let low = tag.to_ascii_lowercase();
    let pat = format!("{attr_name}=");
    let idx = low.find(&pat)?;
    let after = tag[idx + pat.len()..].trim_start();
    if let Some(stripped) = after.strip_prefix('"') {
        let end = stripped.find('"')?;
        Some(stripped[..end].to_string())
    } else if let Some(stripped) = after.strip_prefix('\'') {
        let end = stripped.find('\'')?;
        Some(stripped[..end].to_string())
    } else {
        let end = after
            .find(|c: char| c.is_whitespace() || c == '>')
            .unwrap_or(after.len());
        Some(after[..end].to_string())
    }
}

// ============================================================================
// 3. Anicca Portal Recipe Memory (`PortalRecipe` & `PortalMemoryBook`)
// ============================================================================

/// A remembered captive-portal traversal recipe governed by Anicca (`ttl_q8` decay).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PortalRecipe {
    pub ssid: String,
    pub portal_host: String,
    pub strategy: String,
    pub method: String,
    pub action_url: String,
    pub payload_template: String,
    pub honest_summary: String,
    /// `255` = freshly verified (`HTTP 204`); decays via Anicca when failing -> `0` = forgotten.
    pub ttl_q8: u8,
    pub success_cnt: u32,
    pub fail_streak: u8,
    pub last_verified_ts: u64,
    /// Observed lease / re-auth interval in seconds (e.g., `300` for `.Wi2_Free_at_[SK.GROUP]`).
    pub lease_hint_s: u32,
}

impl PortalRecipe {
    pub fn to_tsv_line(&self) -> String {
        let clean = |s: &str| s.replace(['\t', '\r', '\n'], " ");
        format!(
            "RECIPE\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            clean(&self.ssid),
            clean(&self.portal_host),
            clean(&self.strategy),
            clean(&self.method),
            clean(&self.action_url),
            clean(&self.payload_template),
            clean(&self.honest_summary),
            self.ttl_q8,
            self.success_cnt,
            self.fail_streak,
            self.last_verified_ts,
            self.lease_hint_s,
        )
    }

    pub fn from_tsv_line(line: &str) -> Option<Self> {
        let parts: Vec<&str> = line.trim().split('\t').collect();
        if parts.len() < 13 || parts[0] != "RECIPE" {
            return None;
        }
        Some(Self {
            ssid: parts[1].to_string(),
            portal_host: parts[2].to_string(),
            strategy: parts[3].to_string(),
            method: parts[4].to_string(),
            action_url: parts[5].to_string(),
            payload_template: parts[6].to_string(),
            honest_summary: parts[7].to_string(),
            ttl_q8: parts[8].parse().unwrap_or(200),
            success_cnt: parts[9].parse().unwrap_or(1),
            fail_streak: parts[10].parse().unwrap_or(0),
            last_verified_ts: parts[11].parse().unwrap_or(0),
            lease_hint_s: parts[12].parse().unwrap_or(1800),
        })
    }
}

/// Persistent Anicca Learn-Share-Forget Captive Portal Recipe Book.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PortalMemoryBook {
    pub recipes: Vec<PortalRecipe>,
    pub forgotten_count: u32,
}

impl PortalMemoryBook {
    pub fn new() -> Self {
        Self::default()
    }

    /// Find the highest-TTL remembered recipe for `ssid`.
    pub fn find_by_ssid(&self, ssid: &str) -> Option<&PortalRecipe> {
        self.recipes
            .iter()
            .filter(|r| r.ssid == ssid && r.ttl_q8 > 0)
            .max_by_key(|r| (r.ttl_q8, r.success_cnt))
    }

    /// Record a verified captive-portal traversal (`HTTP 204` confirmed), setting `ttl_q8 = 255`.
    #[allow(clippy::too_many_arguments)]
    pub fn learn_verified(
        &mut self,
        ssid: &str,
        portal_host: &str,
        strategy: &str,
        method: &str,
        action_url: &str,
        payload_template: &str,
        honest_summary: &str,
        now_ts: u64,
        lease_hint_s: u32,
    ) {
        if ssid.trim().is_empty() {
            return;
        }
        if let Some(existing) = self.recipes.iter_mut().find(|r| r.ssid == ssid) {
            if !portal_host.is_empty() {
                existing.portal_host = portal_host.to_string();
            }
            if !strategy.is_empty() {
                existing.strategy = strategy.to_string();
            }
            if !method.is_empty() {
                existing.method = method.to_string();
            }
            if !action_url.is_empty() {
                existing.action_url = action_url.to_string();
            }
            if !payload_template.is_empty() {
                existing.payload_template = payload_template.to_string();
            }
            if !honest_summary.is_empty() {
                existing.honest_summary = honest_summary.to_string();
            }
            existing.ttl_q8 = 255;
            existing.fail_streak = 0;
            existing.success_cnt = existing.success_cnt.saturating_add(1);
            existing.last_verified_ts = now_ts;
            if lease_hint_s > 0 {
                existing.lease_hint_s = lease_hint_s;
            }
            return;
        }

        self.recipes.push(PortalRecipe {
            ssid: ssid.to_string(),
            portal_host: portal_host.to_string(),
            strategy: strategy.to_string(),
            method: method.to_string(),
            action_url: action_url.to_string(),
            payload_template: payload_template.to_string(),
            honest_summary: honest_summary.to_string(),
            ttl_q8: 255,
            success_cnt: 1,
            fail_streak: 0,
            last_verified_ts: now_ts,
            lease_hint_s: if lease_hint_s > 0 { lease_hint_s } else { 1800 },
        });
    }

    /// Record a failed portal attempt for `ssid`; if `fail_streak >= 3` or `ttl_q8 <= 80`, forget via Anicca!
    pub fn record_failure(&mut self, ssid: &str) {
        let mut should_forget = false;
        if let Some(rec) = self.recipes.iter_mut().find(|r| r.ssid == ssid) {
            rec.fail_streak = rec.fail_streak.saturating_add(1);
            if rec.fail_streak >= 3 || rec.ttl_q8 <= 80 {
                should_forget = true;
            } else {
                rec.ttl_q8 -= 80;
            }
        }
        if should_forget {
            self.recipes.retain(|r| r.ssid != ssid);
            self.forgotten_count = self.forgotten_count.saturating_add(1);
        }
    }

    /// Serialize the entire recipe book to deterministic TSV format.
    pub fn to_tsv(&self) -> String {
        let mut out = format!("{PORTAL_MEMORY_MAGIC}\tforgotten={}\n", self.forgotten_count);
        for r in &self.recipes {
            out.push_str(&r.to_tsv_line());
            out.push('\n');
        }
        out
    }

    /// Parse a serialized TSV recipe book.
    pub fn from_tsv(raw: &str) -> Self {
        let mut book = Self::new();
        for line in raw.lines() {
            let t = line.trim();
            if t.starts_with(PORTAL_MEMORY_MAGIC) {
                if let Some(idx) = t.find("forgotten=") {
                    book.forgotten_count = t[idx + "forgotten=".len()..]
                        .split_whitespace()
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0);
                }
            } else if let Some(rec) = PortalRecipe::from_tsv_line(t) {
                book.recipes.push(rec);
            }
        }
        book
    }
}

// ============================================================================
// 4. ESP32 Sovereign Constellation `MemnetCapsule64` (64B) & `S3TriadWifiCapsule` (132B)
// ============================================================================

/// Pure-integer 64-bit FNV-1a hash matching `FLUG-OS/src/guardian_mesh.h` (`guardian_fnv64_bytes`).
pub fn fnv64_1a(data: &[u8]) -> u64 {
    let mut h = FNV64_BASIS;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(FNV64_PRIME);
    }
    h
}

/// Pure-integer 32-bit FNV-1a hash matching `FLUG-OS/src/guardian_mesh.h` (`guardian_fnv32_bytes`).
pub fn fnv32_1a(data: &[u8]) -> u32 {
    let mut h = FNV32_BASIS;
    for &b in data {
        h ^= b as u32;
        h = h.wrapping_mul(FNV32_PRIME);
    }
    h
}

/// Exact 64-byte `MemnetCapsule64` frame shared across ESP-NOW, Wi-Fi UDP `:8888`, BLE, and 923.2 MHz SX1262 LoRa.
/// Layout matches `FLUG-OS/src/mem8_consciousness.h` (`struct MemnetCapsule64`) byte-for-byte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemnetCapsule64 {
    pub version: u8,
    /// `0=ADA(*)`, `1=VAK(/\)`, `2=OMN(oo)`, `3=SUN:TDECK(<>)`, `4=LINUX:QWAVE`
    pub node_id: u8,
    /// Balanced ternary pole (`-1`, `0`, `+1`)
    pub node_trit: i8,
    /// `bit0=ESP-NOW`, `bit1=WIFI-UDP(:8888)`, `bit2=BLE`, `bit3=LORA-SX1262`
    pub transport_mask: u8,
    pub seed_class: u8,
    pub dominant_mod: u8,
    pub seq: u32,
    pub audio_f0_hz: u16,
    pub audio_salience_pct: u8,
    pub rf_rssi_dbm: i8,
    pub rf_ap_count: u16,
    pub imu_motion_mg: i16,
    pub peer_rssi_dbm: [i8; 4],
    pub top_bssid_fnv32: u32,
    pub top_bssid_rssi_dbm: i8,
    /// `1` if captive portal / open internet verified (`HTTP 204`)
    pub portal_ok: u8,
    /// 9-trit balanced ternary signature (e.g. `"101T10101"`)
    pub wave_b3: String,
    /// Active open/portal SSID prefix hint (up to 15 ASCII chars + NUL) for flock auto-join!
    pub ssid_hint: String,
}

impl MemnetCapsule64 {
    /// Encode into an exact 64-byte packed binary frame with 64-bit FNV-1a seal over bytes `0..56`.
    pub fn to_bytes_64(&self) -> [u8; 64] {
        let mut buf = [0u8; 64];
        buf[0..2].copy_from_slice(&MEMNET_MAGIC_U16.to_le_bytes()); // 'N', 'M'
        buf[2] = self.version;
        buf[3] = self.node_id;
        buf[4] = self.node_trit as u8;
        buf[5] = self.transport_mask;
        buf[6] = self.seed_class;
        buf[7] = self.dominant_mod;
        buf[8..12].copy_from_slice(&self.seq.to_le_bytes());
        buf[12..14].copy_from_slice(&self.audio_f0_hz.to_le_bytes());
        buf[14] = self.audio_salience_pct;
        buf[15] = self.rf_rssi_dbm as u8;
        buf[16..18].copy_from_slice(&self.rf_ap_count.to_le_bytes());
        buf[18..20].copy_from_slice(&self.imu_motion_mg.to_le_bytes());
        for i in 0..4 {
            buf[20 + i] = self.peer_rssi_dbm[i] as u8;
        }
        buf[24..28].copy_from_slice(&self.top_bssid_fnv32.to_le_bytes());
        buf[28] = self.top_bssid_rssi_dbm as u8;
        buf[29] = self.portal_ok;

        let b3_bytes = self.wave_b3.as_bytes();
        let b3_len = b3_bytes.len().min(9);
        buf[30..30 + b3_len].copy_from_slice(&b3_bytes[..b3_len]);

        let ssid_bytes = self.ssid_hint.as_bytes();
        let ssid_len = ssid_bytes.len().min(15);
        buf[40..40 + ssid_len].copy_from_slice(&ssid_bytes[..ssid_len]);

        let seal = fnv64_1a(&buf[0..56]);
        buf[56..64].copy_from_slice(&seal.to_le_bytes());
        buf
    }

    /// Decode and verify a 64-byte `MemnetCapsule64` packet (`magic == 0x4D4E` and valid 64-bit FNV-1a seal).
    pub fn from_bytes_64(buf: &[u8; 64]) -> Option<Self> {
        let magic = u16::from_le_bytes([buf[0], buf[1]]);
        if magic != MEMNET_MAGIC_U16 {
            return None;
        }
        let expected_seal = fnv64_1a(&buf[0..56]);
        let actual_seal = u64::from_le_bytes([
            buf[56], buf[57], buf[58], buf[59], buf[60], buf[61], buf[62], buf[63],
        ]);
        if expected_seal != actual_seal {
            return None;
        }

        let wave_b3_end = buf[30..40].iter().position(|&b| b == 0).unwrap_or(9).min(9);
        let wave_b3 = String::from_utf8_lossy(&buf[30..30 + wave_b3_end]).to_string();

        let ssid_end = buf[40..56]
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(15)
            .min(15);
        let ssid_hint = String::from_utf8_lossy(&buf[40..40 + ssid_end]).to_string();

        Some(Self {
            version: buf[2],
            node_id: buf[3],
            node_trit: buf[4] as i8,
            transport_mask: buf[5],
            seed_class: buf[6],
            dominant_mod: buf[7],
            seq: u32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]),
            audio_f0_hz: u16::from_le_bytes([buf[12], buf[13]]),
            audio_salience_pct: buf[14],
            rf_rssi_dbm: buf[15] as i8,
            rf_ap_count: u16::from_le_bytes([buf[16], buf[17]]),
            imu_motion_mg: i16::from_le_bytes([buf[18], buf[19]]),
            peer_rssi_dbm: [
                buf[20] as i8,
                buf[21] as i8,
                buf[22] as i8,
                buf[23] as i8,
            ],
            top_bssid_fnv32: u32::from_le_bytes([buf[24], buf[25], buf[26], buf[27]]),
            top_bssid_rssi_dbm: buf[28] as i8,
            portal_ok: buf[29],
            wave_b3,
            ssid_hint,
        })
    }
}

/// Mask byte helper for `S3TriadWifiCapsule` (`"TWIF"`, 132 bytes) matching `FLUG-OS/src/net_time.h` (`net_twif_mask_byte`).
#[inline]
pub fn twif_mask_byte(idx: usize, seq: u32) -> u8 {
    0x8Bu8 ^ (((idx.wrapping_mul(0x5A)) & 0xFF) as u8) ^ ((seq & 0xFF) as u8)
}

/// 132-byte `S3TriadWifiCapsule` (`"TWIF"`) for sharing full 32-char SSIDs + 64-char passwords
/// and host bridge endpoints with the ESP32 Constellation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct S3TriadWifiCapsule {
    pub node_id: u8,
    pub flags: u8,
    pub host_port: u16,
    pub host_ip: String,
    pub ssid: String,
    pub pass: String,
    pub seq: u32,
}

impl S3TriadWifiCapsule {
    pub fn to_bytes_132(&self) -> [u8; 132] {
        let mut buf = [0u8; 132];
        buf[0..4].copy_from_slice(&TWIF_MAGIC_4);
        buf[4] = self.node_id;
        buf[5] = self.flags;
        buf[6..8].copy_from_slice(&self.host_port.to_le_bytes());

        let ip_bytes = self.host_ip.as_bytes();
        let ip_len = ip_bytes.len().min(19);
        buf[8..8 + ip_len].copy_from_slice(&ip_bytes[..ip_len]);

        let mut raw_ssid = [0u8; 33];
        let s_bytes = self.ssid.as_bytes();
        let s_len = s_bytes.len().min(32);
        raw_ssid[..s_len].copy_from_slice(&s_bytes[..s_len]);
        for i in 0..33 {
            buf[28 + i] = raw_ssid[i] ^ twif_mask_byte(i, self.seq);
        }

        let mut raw_pass = [0u8; 65];
        let p_bytes = self.pass.as_bytes();
        let p_len = p_bytes.len().min(64);
        raw_pass[..p_len].copy_from_slice(&p_bytes[..p_len]);
        for i in 0..65 {
            buf[61 + i] = raw_pass[i] ^ twif_mask_byte(i + 33, self.seq);
        }

        buf[126..130].copy_from_slice(&self.seq.to_le_bytes());
        buf
    }

    pub fn from_bytes_132(buf: &[u8; 132]) -> Option<Self> {
        if buf[0..4] != TWIF_MAGIC_4 {
            return None;
        }
        let seq = u32::from_le_bytes([buf[126], buf[127], buf[128], buf[129]]);
        let mut raw_ssid = [0u8; 33];
        for i in 0..33 {
            raw_ssid[i] = buf[28 + i] ^ twif_mask_byte(i, seq);
        }
        let s_end = raw_ssid.iter().position(|&b| b == 0).unwrap_or(32).min(32);
        let ssid = String::from_utf8_lossy(&raw_ssid[..s_end]).to_string();

        let mut raw_pass = [0u8; 65];
        for i in 0..65 {
            raw_pass[i] = buf[61 + i] ^ twif_mask_byte(i + 33, seq);
        }
        let p_end = raw_pass.iter().position(|&b| b == 0).unwrap_or(64).min(64);
        let pass = String::from_utf8_lossy(&raw_pass[..p_end]).to_string();

        let ip_end = buf[8..28].iter().position(|&b| b == 0).unwrap_or(19).min(19);
        let host_ip = String::from_utf8_lossy(&buf[8..8 + ip_end]).to_string();

        Some(Self {
            node_id: buf[4],
            flags: buf[5],
            host_port: u16::from_le_bytes([buf[6], buf[7]]),
            host_ip,
            ssid,
            pass,
            seq,
        })
    }
}

// ============================================================================
// 5. Bluetooth BLE (31B) & BNEP/RFCOMM (96B) Sovereign Mesh (`BluetoothMeshFrame`)
// ============================================================================

/// A 96-byte Sovereign Bluetooth Mesh Frame (`8BM8`) carrying a 79-byte `MEM|8` `WaveInt`,
/// a 64-bit `WUPZ` XOR-fold receipt, speaker `F0` Hz, hop TTL, and CRC-16.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BluetoothMeshFrame {
    pub hop_ttl: u8,
    pub speaker_f0_hz: u16,
    pub wupz_xor_fold: u64,
    pub wave: WaveInt,
}

impl BluetoothMeshFrame {
    /// Encode into an exact 96-byte BNEP / RFCOMM / L2CAP mesh frame (`0` floats).
    pub fn to_bytes_96(&self) -> [u8; 96] {
        let mut buf = [0u8; 96];
        buf[0..4].copy_from_slice(&MESH_MAGIC_96);
        buf[4] = self.hop_ttl;
        buf[5..7].copy_from_slice(&self.speaker_f0_hz.to_le_bytes());
        buf[7..15].copy_from_slice(&self.wupz_xor_fold.to_le_bytes());
        let wave_bytes = self.wave.to_frame();
        buf[15..94].copy_from_slice(&wave_bytes);
        let crc = crc16_ccitt(&buf[0..94]);
        buf[94..96].copy_from_slice(&crc.to_le_bytes());
        buf
    }

    /// Decode and verify a 96-byte BNEP / RFCOMM / L2CAP mesh frame.
    pub fn from_bytes_96(buf: &[u8; 96]) -> Option<Self> {
        if buf[0..4] != MESH_MAGIC_96 {
            return None;
        }
        let expected_crc = crc16_ccitt(&buf[0..94]);
        let actual_crc = u16::from_le_bytes([buf[94], buf[95]]);
        if expected_crc != actual_crc {
            return None;
        }
        let hop_ttl = buf[4];
        let speaker_f0_hz = u16::from_le_bytes([buf[5], buf[6]]);
        let wupz_xor_fold = u64::from_le_bytes([
            buf[7], buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14],
        ]);
        let wave = WaveInt::from_frame(&buf[15..94]).ok()?;
        Some(Self {
            hop_ttl,
            speaker_f0_hz,
            wupz_xor_fold,
            wave,
        })
    }

    /// Encode a compact 31-byte BLE Legacy Advertising payload (`BLE_MAGIC_31` + `hop_ttl` +
    /// `speaker_f0_hz` + `vad_byte` + `wupz_xor_fold` + `timestamp` + 7-byte capsule tag + `CRC-16`).
    pub fn to_ble_adv_31(&self, vad_byte: u8, capsule_tag: &str) -> [u8; 31] {
        let mut adv = [0u8; 31];
        adv[0..2].copy_from_slice(&BLE_MAGIC_31);
        adv[2] = self.hop_ttl;
        adv[3..5].copy_from_slice(&self.speaker_f0_hz.to_le_bytes());
        adv[5] = vad_byte;
        adv[6..14].copy_from_slice(&self.wupz_xor_fold.to_le_bytes());
        adv[14..22].copy_from_slice(&self.wave.created_at.to_le_bytes());
        let tag_bytes = capsule_tag.as_bytes();
        let copy_len = tag_bytes.len().min(7);
        adv[22..22 + copy_len].copy_from_slice(&tag_bytes[..copy_len]);
        let crc = crc16_ccitt(&adv[0..29]);
        adv[29..31].copy_from_slice(&crc.to_le_bytes());
        adv
    }
}

/// Pure-integer CRC-16-CCITT (`0x1021`) for Bluetooth mesh frame integrity.
pub fn crc16_ccitt(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &b in data {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            if (crc & 0x8000) != 0 {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc <<= 1;
            }
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rational::Rational;
    use crate::wave::WaveProvenance;

    #[test]
    fn ranks_open_and_tokyo_portal_wifi_candidates_without_floats() {
        let sample = "\
DA\\:F8\\:50\\:6D\\:54\\:BF:GlobalWiFi_kdq:3:2422 MHz:92:WPA2
0A\\:92\\:5E\\:E3\\:DC\\:8B:tullys_Wi-Fi:136:5680 MHz:57:--
06\\:92\\:5E\\:E3\\:DC\\:8B:tullys_Wi-Fi:5:2432 MHz:57:--
00\\:33\\:58\\:1D\\:3A\\:08:Wi2premium:11:2462 MHz:64:--
00\\:33\\:58\\:5C\\:AF\\:5C:.Wi2_Free_at_[SK.GROUP]:108:5540 MHz:54:--
74\\:11\\:B2\\:C9\\:92\\:A1:SWAN2:6:2437 MHz:42:WPA2 802.1X";

        let ranked = rank_free_wifi_candidates(sample);
        assert_eq!(ranked.len(), 4);
        // Both tullys_Wi-Fi (5GHz) and .Wi2_Free_at_[SK.GROUP] (5GHz) outrank paid trap Wi2premium!
        assert_eq!(ranked.last().unwrap().ssid, "Wi2premium");
        assert!(ranked[0].score_q10 > ranked.last().unwrap().score_q10);
    }

    #[test]
    fn captive_portal_parser_handles_redirect_html_form_and_usen_capi() {
        let redirect_http =
            "HTTP/1.1 302 Found\r\nLocation: http://10.0.0.1/portal/index.html\r\n\r\n";
        assert_eq!(
            parse_captive_portal_response(redirect_http, "10.0.0.1"),
            CaptivePortalAction::FollowRedirect {
                url: "http://10.0.0.1/portal/index.html".to_string()
            }
        );

        let form_http = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n\
            <html><body><form action=\"/auth/accept\" method=\"POST\">\
            <input type=\"hidden\" name=\"session_id\" value=\"tok_432hz\">\
            <input type=\"email\" name=\"user_email\" value=\"\">\
            <input type=\"text\" name=\"country\" value=\"\">\
            <input type=\"submit\" value=\"Connect\">\
            </form></body></html>";
        match parse_captive_portal_response(form_http, "portal.tullys.jp") {
            CaptivePortalAction::SubmitAcceptanceForm {
                method,
                action_url,
                form_urlencoded_body,
            } => {
                assert_eq!(method, "POST");
                assert_eq!(action_url, "http://portal.tullys.jp/auth/accept");
                assert!(form_urlencoded_body.contains("session_id=tok_432hz"));
                assert!(form_urlencoded_body.contains("user_email=guest@8b.is"));
                assert!(form_urlencoded_body.contains("country=JP"));
                assert!(form_urlencoded_body.contains("accept=true"));
            }
            other => panic!("unexpected action: {other:?}"),
        }

        // USEN / USPOT-02 / .Wi2_Free_at_[SK.GROUP] SPA portal
        let usen_http = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n\
            <html><head><title>USPOT Captive</title></head><body>/capi/welcome</body></html>";
        match parse_captive_portal_response(
            usen_http,
            "http://10.59.128.1/captive/?stamac=a0:b3:39:08:f7:46",
        ) {
            CaptivePortalAction::SubmitUsenWelcomeJson {
                endpoint_url,
                vouched_macs,
                json_payloads,
            } => {
                assert_eq!(endpoint_url, "http://10.59.128.1/capi/welcome");
                assert!(vouched_macs.contains(&"a0:b3:39:08:f7:46".to_string()));
                assert!(vouched_macs.contains(&"80:b5:4e:db:3b:c4".to_string()));
                assert!(vouched_macs.contains(&"cc:ba:97:00:45:24".to_string()));
                assert_eq!(vouched_macs.len(), json_payloads.len());
            }
            other => panic!("unexpected USEN action: {other:?}"),
        }
    }

    #[test]
    fn anicca_portal_memory_book_learns_ranks_and_forgets_after_3_failures() {
        let mut book = PortalMemoryBook::new();
        book.learn_verified(
            ".Wi2_Free_at_[SK.GROUP]",
            "10.59.128.1",
            "usen_capi_welcome",
            "POST",
            "http://10.59.128.1/capi/welcome",
            "{\"gender\":\"\",\"birth\":\"\",\"macaddr\":\"a0:b3:39:08:f7:46\",\"lang\":\"en\"}",
            "macaddr+lang=en",
            1_793_411_000,
            300,
        );
        let tsv = book.to_tsv();
        let reloaded = PortalMemoryBook::from_tsv(&tsv);
        let rec = reloaded
            .find_by_ssid(".Wi2_Free_at_[SK.GROUP]")
            .expect("remembered recipe");
        assert_eq!(rec.ttl_q8, 255);
        assert_eq!(rec.lease_hint_s, 300);

        let mut decaying = reloaded;
        decaying.record_failure(".Wi2_Free_at_[SK.GROUP]");
        decaying.record_failure(".Wi2_Free_at_[SK.GROUP]");
        assert!(decaying.find_by_ssid(".Wi2_Free_at_[SK.GROUP]").is_some());
        decaying.record_failure(".Wi2_Free_at_[SK.GROUP]");
        assert!(decaying.find_by_ssid(".Wi2_Free_at_[SK.GROUP]").is_none());
        assert_eq!(decaying.forgotten_count, 1);
    }

    #[test]
    fn esp32_memnet_capsule_64_and_twif_132_round_trip() {
        let cap = MemnetCapsule64 {
            version: 1,
            node_id: 4, // LINUX:QWAVE
            node_trit: 1,
            transport_mask: 0x07, // ESP-NOW + WIFI-UDP(:8888) + BLE
            seed_class: 3,
            dominant_mod: 1,
            seq: 42,
            audio_f0_hz: 154,
            audio_salience_pct: 91,
            rf_rssi_dbm: -54,
            rf_ap_count: 18,
            imu_motion_mg: 0,
            peer_rssi_dbm: [-52, -58, -60, -55],
            top_bssid_fnv32: 0x5CAF_5C00,
            top_bssid_rssi_dbm: -54,
            portal_ok: 1,
            wave_b3: "101T10101".to_string(),
            ssid_hint: ".Wi2_Free_at_[S".to_string(),
        };
        let bytes64 = cap.to_bytes_64();
        assert_eq!(&bytes64[0..2], b"NM");
        let decoded = MemnetCapsule64::from_bytes_64(&bytes64).expect("valid 64B MemnetCapsule64");
        assert_eq!(decoded, cap);

        let twif = S3TriadWifiCapsule {
            node_id: 0,
            flags: 0x01,
            host_port: 8089,
            host_ip: "10.59.166.146".to_string(),
            ssid: ".Wi2_Free_at_[SK.GROUP]".to_string(),
            pass: "".to_string(),
            seq: 7,
        };
        let bytes132 = twif.to_bytes_132();
        let decoded_twif =
            S3TriadWifiCapsule::from_bytes_132(&bytes132).expect("valid 132B TWIF capsule");
        assert_eq!(decoded_twif, twif);
    }

    #[test]
    fn bluetooth_mesh_frame_96_and_ble_31_round_trip_with_crc() {
        let wave = WaveInt {
            base_amplitude: Rational::new(92, 100).unwrap(),
            frequency: Rational::new(175, 1).unwrap(),
            phase: Rational::new(0, 1).unwrap(),
            emotional_valence: Rational::new(80, 100).unwrap(),
            arousal: Rational::new(65, 100).unwrap(),
            created_at: 1_792_728_000,
            last_accessed: 1_792_728_000,
            access_count: 1,
            decay_rate: Rational::new(1, 5).unwrap(),
            id: Some(0x432),
            provenance: WaveProvenance::Cognitive,
        };

        let frame = BluetoothMeshFrame {
            hop_ttl: 3,
            speaker_f0_hz: 175,
            wupz_xor_fold: 0x6c2b_7c57_653b_7a1c,
            wave,
        };

        let bytes96 = frame.to_bytes_96();
        let decoded = BluetoothMeshFrame::from_bytes_96(&bytes96).expect("valid 96B mesh frame");
        assert_eq!(decoded, frame);

        let adv31 = frame.to_ble_adv_31(0x66, "DIRECT!");
        assert_eq!(&adv31[0..2], b"8B");
        assert_eq!(adv31[2], 3);
    }
}
