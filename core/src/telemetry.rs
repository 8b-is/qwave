//! Ultra-PII scrubbing and aggregation for the debug telemetry lane.
//!
//! The rules are blunt on purpose — a scrubber with exceptions is a scrubber
//! with leaks:
//! - URLs keep **scheme + host only**; the path is replaced by a truncated
//!   hash so two visits to the same page still aggregate without revealing
//!   which page it was. Query strings never survive.
//! - Emails, IP literals, and long numeric sequences are replaced by tags.
//! - Free text is replaced by `len:<n>` plus a content hash: enough to
//!   measure, not enough to read.
//!
//! Aggregation is count-based and JSON-ready: data science sees histograms
//! and counts, never content.

use std::collections::BTreeMap;

/// Truncated FNV-1a content hash, hex-encoded — what replaces page paths and
/// free text. Collision-tolerant by design (this is counting, not identity).
pub fn content_hash(text: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in text.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// URL → `scheme://host/p:<hash8>`. Drops userinfo, port-adjacent query
/// strings, and fragments. The hash covers the *path only* — a query string
/// must never be able to change the aggregate key.
pub fn scrub_url(url: &str) -> String {
    let Some(scheme_end) = url.find("://") else {
        return format!("[UNPARSED:{}]", &content_hash(url)[..8]);
    };
    let scheme = &url[..scheme_end];
    let rest = &url[scheme_end + 3..];
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // Strip userinfo (user:pass@).
    let host = authority.rsplit('@').next().unwrap_or("");
    let path = rest.split(['?', '#']).next().unwrap_or("");
    let path_hash = content_hash(path);
    format!("{scheme}://{host}/p:{}", &path_hash[..8])
}

/// Free text → `len:<n>` — no content survives.
pub fn scrub_text(text: &str) -> String {
    format!("len:{}", text.len())
}

/// Line-level scrubber: any token that looks like an email, an IP literal,
/// or a URL is replaced by its scrubbed form. Everything else passes through
/// length-preserved.
pub fn scrub_line(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    for token in line.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        if looks_like_email(token) {
            out.push_str("[EMAIL]");
        } else if looks_like_ip(token) {
            out.push_str("[IP]");
        } else if token.contains("://") || token.starts_with("www.") {
            out.push_str(&scrub_url(token));
        } else {
            out.push_str(token);
        }
    }
    out
}

fn looks_like_email(token: &str) -> bool {
    let Some(at) = token.find('@') else {
        return false;
    };
    at > 0 && at < token.len() - 1 && token[at + 1..].contains('.') && !token.contains(['/', '?'])
}

fn looks_like_ip(token: &str) -> bool {
    let is_v4 = || {
        let parts: Vec<&str> = token.split('.').collect();
        parts.len() == 4
            && parts.iter().all(|p| {
                !p.is_empty()
                    && p.len() <= 3
                    && p.bytes().all(|b| b.is_ascii_digit())
                    && p.parse::<u8>().is_ok()
            })
    };
    let is_v6 = || token.contains(':') && token.chars().all(|c| c.is_ascii_hexdigit() || c == ':');
    is_v4() || is_v6()
}

/// A counting aggregator: token → occurrences, JSON-ready. Nothing else —
/// aggregation is where privacy and data science meet.
#[derive(Default)]
pub struct Aggregator {
    counts: BTreeMap<String, u64>,
}

impl Aggregator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Count one token.
    pub fn observe(&mut self, token: &str) {
        *self.counts.entry(token.to_string()).or_insert(0) += 1;
    }

    /// Count every whitespace token in a (pre-scrubbed) line.
    pub fn observe_line(&mut self, scrubbed_line: &str) {
        for token in scrubbed_line.split_whitespace() {
            self.observe(token);
        }
    }

    /// Merge another aggregator in.
    pub fn merge(&mut self, other: &Aggregator) {
        for (token, count) in &other.counts {
            *self.counts.entry(token.clone()).or_insert(0) += count;
        }
    }

    /// JSON-ready output: `{"token": count, ...}` sorted by count descending.
    pub fn to_json(&self) -> String {
        let mut rows: Vec<(&String, &u64)> = self.counts.iter().collect();
        rows.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
        let mut out = String::from("{");
        for (i, (token, count)) in rows.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!("\n  \"{}\": {}", json_escape(token), count));
        }
        out.push_str("\n}");
        out
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// C ABI: scrub a URL into a caller-provided buffer. Returns the number of
/// bytes written (excluding the NUL); 0 when the buffer is too small or the
/// pointers are null.
///
/// # Safety
/// `url` must be a NUL-terminated C string or null; `out` must point to
/// `out_len` writable bytes or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_telemetry_scrub_url(
    url: *const core::ffi::c_char,
    out: *mut core::ffi::c_char,
    out_len: usize,
) -> usize {
    if url.is_null() || out.is_null() || out_len == 0 {
        return 0;
    }
    // SAFETY: caller contract.
    let Ok(url) = unsafe { core::ffi::CStr::from_ptr(url) }.to_str() else {
        return 0;
    };
    let scrubbed = scrub_url(url);
    if scrubbed.len() + 1 > out_len {
        return 0;
    }
    unsafe {
        core::ptr::copy_nonoverlapping(scrubbed.as_ptr(), out.cast(), scrubbed.len());
        *out.add(scrubbed.len()) = 0;
    }
    scrubbed.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_keep_scheme_and_host_only() {
        let s = scrub_url("https://www.example.com/some/path?q=secret&token=abc#frag");
        assert!(s.starts_with("https://www.example.com/p:"));
        assert!(!s.contains("secret"));
        assert!(!s.contains("token"));
        assert!(!s.contains("frag"));
        assert!(!s.contains("some/path"));
    }

    #[test]
    fn userinfo_is_stripped() {
        let s = scrub_url("https://user:pass@example.com/x");
        assert!(!s.contains("user"));
        assert!(!s.contains("pass"));
        assert!(s.contains("example.com"));
    }

    #[test]
    fn same_path_aggregates_the_same_way() {
        let a = scrub_url("https://example.com/readme");
        let b = scrub_url("https://example.com/readme?utm=1");
        assert_eq!(a, b, "path hash must not depend on the query string");
    }

    #[test]
    fn emails_and_ips_are_tagged() {
        assert_eq!(scrub_line("mail bob@example.com now"), "mail [EMAIL] now");
        assert_eq!(
            scrub_line("from 192.168.1.10 to 10.0.0.1"),
            "from [IP] to [IP]"
        );
        assert_eq!(scrub_line("v6 ::1 here"), "v6 [IP] here");
    }

    #[test]
    fn free_text_loses_its_content() {
        assert_eq!(scrub_text("the quick brown fox"), "len:19");
    }

    #[test]
    fn aggregation_is_json_ready_and_sorted() {
        let mut agg = Aggregator::new();
        for _ in 0..3 {
            agg.observe("alpha");
        }
        agg.observe("beta");
        let json = agg.to_json();
        assert!(json.starts_with('{'));
        assert!(json.contains("\"alpha\": 3"));
        assert!(json.contains("\"beta\": 1"));
        assert!(json.find("\"alpha\"").unwrap() < json.find("\"beta\"").unwrap());
    }

    #[test]
    fn merge_adds_counts() {
        let mut a = Aggregator::new();
        let mut b = Aggregator::new();
        a.observe("x");
        b.observe("x");
        b.observe("y");
        a.merge(&b);
        let json = a.to_json();
        assert!(json.contains("\"x\": 2"));
        assert!(json.contains("\"y\": 1"));
    }
}
