//! Sovereign Nomad Mesh, Free-WiFi Captive-Portal Auto-Solver & Bluetooth Mesh (`qwave_core::mesh`).
//!
//! 100% integer-only (`0` floating-point instructions), zero external dependencies:
//! 1. **Free & Open Wi-Fi Discovery (`rank_free_wifi_candidates`)**:
//!    Identifies open networks (`--` / `open`) and known Tokyo/global captive-portal networks
//!    (`tullys_Wi-Fi`, `0000docomo`, `JR-EAST-FREE-WiFi`, `Metro_Free_Wi-Fi`, `Tokyo-Free-Wi-Fi`,
//!    `Starbucks_Wi2`, `7SPOT`, `LAWSON_Free_Wi-Fi`, `FamilyMart_Wi-Fi`, `FreeWiFi`, `Guest`)
//!    and ranks them by integer `score_q10` (signal strength + 5 GHz band bonus + portal score).
//! 2. **Captive Portal Probe & Auto-Acceptor (`parse_captive_portal_response`)**:
//!    Detects HTTP `302`/`307` portal redirects, RFC 8908 Captive Portal JSON, HTML `<meta refresh>`,
//!    and HTML `<form action="..." method="...">` with hidden session tokens, and synthesizes the
//!    exact HTTP `POST`/`GET` acceptance payload (`accept=true&agree=1&connect=1`) to unlock free Wi-Fi.
//! 3. **Bluetooth BLE (31B) & BNEP/RFCOMM (96B) Sovereign Mesh (`BluetoothMeshFrame`)**:
//!    Packs a 79-byte `MEM|8` `WaveInt` frame + 64-bit `WUPZ` XOR-fold + Tokyo JST timestamp +
//!    hop TTL + CRC-16 into a deterministic binary mesh frame for zero-infrastructure peer relay.

use crate::wave::WaveInt;

/// Magic header for 96-byte BNEP / RFCOMM Sovereign Mesh frames (`"8BM8"`).
pub const MESH_MAGIC_96: [u8; 4] = *b"8BM8";

/// Magic header for 31-byte BLE Legacy Advertising mesh beacons (`"8B"`).
pub const BLE_MAGIC_31: [u8; 2] = *b"8B";

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
    "tullys_wi-fi",
    "0000docomo",
    "jr-east-free-wifi",
    "metro_free_wi-fi",
    "tokyo-free-wi-fi",
    "shinjuku-free-wifi",
    "shibuya-wi-fi",
    "starbucks_wi2",
    "at_starbucks_wi2",
    "7spot",
    "lawson_free_wi-fi",
    "familymart_wi-fi",
    "komeda_wi-fi",
    "doutor_free_wi-fi",
    "haneda-free-wifi",
    "narita-free-wifi",
    "freewifi",
    "free_wi-fi",
    "free-wifi",
    "guest",
    "airport",
    "hotel",
    "lobby",
];

/// Parse `nmcli -t -f BSSID,SSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list` output
/// and return ranked free/open or captive-portal Wi-Fi candidates.
pub fn rank_free_wifi_candidates(nmcli_text: &str) -> Vec<FreeWifiCandidate> {
    let mut out = Vec::new();
    for raw_line in nmcli_text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        // In `nmcli -t`, escaped colons in BSSID look like `06\:92\:5E\:E3\:DC\:8B:tullys_Wi-Fi:5:2432 MHz:57:--`
        let normalized = line.replace("\\:", "-");
        let parts: Vec<&str> = normalized.split(':').collect();
        if parts.len() < 6 {
            continue;
        }
        let bssid = parts[0].replace('-', ":");
        let ssid = parts[1].trim().to_string();
        if ssid.is_empty() || ssid == "--" {
            continue;
        }
        let channel: u16 = parts[2].trim().parse().unwrap_or(1);
        let freq_mhz: u16 = parts[3]
            .split_whitespace()
            .next()
            .and_then(|s| s.parse().ok())
            .unwrap_or(2412);
        let signal_pct: u8 = parts[4].trim().parse().unwrap_or(0);
        let security = parts[5..].join(":").trim().to_string();

        let sec_low = security.to_ascii_lowercase();
        let is_open = sec_low.is_empty() || sec_low == "--" || sec_low == "open" || sec_low == "none";
        let ssid_low = ssid.to_ascii_lowercase();
        let is_known_portal_brand = KNOWN_FREE_PORTAL_SSIDS
            .iter()
            .any(|pat| ssid_low.contains(pat));

        if !is_open && !is_known_portal_brand {
            continue;
        }

        // Integer utility score in Q10 (0..1024+):
        // - Signal contribution: signal_pct * 6 (up to 600)
        // - Open network bonus: +240
        // - Known Tokyo/portal brand bonus: +160
        // - 5 GHz band bonus: +80 (less congestion, faster portal traversal)
        let mut score_q10 = (signal_pct as u32) * 6;
        if is_open {
            score_q10 += 240;
        }
        if is_known_portal_brand {
            score_q10 += 160;
        }
        if freq_mhz >= 5000 {
            score_q10 += 80;
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
            score_q10,
        });
    }

    out.sort_by(|a, b| b.score_q10.cmp(&a.score_q10));
    out
}

/// Result of probing an HTTP connection for a captive portal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptivePortalAction {
    /// Internet is already open (`HTTP 204` or expected body); no captive portal blocks us.
    InternetOpen,
    /// Captive portal requires following a redirect URL (`HTTP 302`/`307` or `<meta refresh>`).
    FollowRedirect { url: String },
    /// Captive portal presented an HTML acceptance form that can be auto-submitted.
    SubmitAcceptanceForm {
        method: String,
        action_url: String,
        form_urlencoded_body: String,
    },
}

/// Inspect a raw HTTP response (`HTTP/1.1 ... \r\n\r\n <body>`) from a captive-portal probe
/// and determine the autonomous traversal action (`InternetOpen`, `FollowRedirect`, or `SubmitAcceptanceForm`).
pub fn parse_captive_portal_response(raw_http: &str, base_host: &str) -> CaptivePortalAction {
    let (headers, body) = raw_http.split_once("\r\n\r\n").unwrap_or((raw_http, ""));
    let first_line = headers.lines().next().unwrap_or("");

    // 1. HTTP 204 No Content or Google/Apple success token => Internet is open
    if first_line.contains(" 204 ")
        || body.contains("<TITLE>Success</TITLE>")
        || body.contains("Success") && body.len() < 128
    {
        return CaptivePortalAction::InternetOpen;
    }

    // 2. HTTP 301 / 302 / 303 / 307 / 308 Location header redirect
    for line in headers.lines() {
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("location:") {
            let loc = line["location:".len()..].trim();
            if !loc.is_empty() {
                return CaptivePortalAction::FollowRedirect {
                    url: resolve_portal_url(base_host, loc),
                };
            }
        }
    }

    // 3. HTML <form ...> with hidden inputs / acceptance buttons
    if let Some((method, action, hidden_pairs)) = extract_html_portal_form(body) {
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
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("&");
        return CaptivePortalAction::SubmitAcceptanceForm {
            method,
            action_url: resolve_portal_url(base_host, &action),
            form_urlencoded_body: encoded,
        };
    }

    // 4. HTML <meta http-equiv="refresh" content="0;url=...">
    let body_low = body.to_ascii_lowercase();
    if let Some(idx) = body_low.find("url=") {
        let after = &body[idx + 4..];
        let end = after
            .find(|c: char| matches!(c, '"' | '\'' | '>' | ' '))
            .unwrap_or(after.len());
        let target = after[..end].trim();
        if !target.is_empty() {
            return CaptivePortalAction::FollowRedirect {
                url: resolve_portal_url(base_host, target),
            };
        }
    }

    CaptivePortalAction::InternetOpen
}

fn resolve_portal_url(base_host: &str, target: &str) -> String {
    if target.starts_with("http://") || target.starts_with("https://") {
        target.to_string()
    } else if target.starts_with('/') {
        format!("http://{base_host}{target}")
    } else {
        format!("http://{base_host}/{target}")
    }
}

fn extract_html_portal_form(html: &str) -> Option<(String, String, Vec<(String, String)>)> {
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
            let val = extract_html_attr(inp_tag, "value").unwrap_or_else(|| "1".to_string());
            inputs.push((name, val));
        }
        scan = &after_inp[close_idx + 1..];
    }

    Some((method, action, inputs))
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
    /// `speaker_f0_hz` + `vad_byte` + `wupz_xor_fold` + `timestamp` + 10-byte capsule digest + `CRC-16`).
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
74\\:11\\:B2\\:C9\\:92\\:A1:SWAN2:6:2437 MHz:42:WPA2 802.1X";

        let ranked = rank_free_wifi_candidates(sample);
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[0].ssid, "tullys_Wi-Fi");
        assert_eq!(ranked[0].freq_mhz, 5680);
        assert!(ranked[0].is_open);
        assert!(ranked[0].is_known_portal_brand);
        assert!(ranked[0].score_q10 > ranked[1].score_q10);
    }

    #[test]
    fn captive_portal_parser_handles_redirect_and_html_form() {
        let redirect_http = "HTTP/1.1 302 Found\r\nLocation: http://10.0.0.1/portal/index.html\r\n\r\n";
        assert_eq!(
            parse_captive_portal_response(redirect_http, "10.0.0.1"),
            CaptivePortalAction::FollowRedirect {
                url: "http://10.0.0.1/portal/index.html".to_string()
            }
        );

        let form_http = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n\
            <html><body><form action=\"/auth/accept\" method=\"POST\">\
            <input type=\"hidden\" name=\"session_id\" value=\"tok_432hz\">\
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
                assert!(form_urlencoded_body.contains("accept=true"));
            }
            other => panic!("unexpected action: {other:?}"),
        }
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
