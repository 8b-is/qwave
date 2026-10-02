//! The Category-A egress allowlist — the committed set of hosts Qwave's own
//! code may contact. Ported exactly from the Swift `EgressAllowlist`;
//! `api.mullvad.net` left with the VPN layer.
//!
//! Wild tricks, all real:
//! - **Zero allocation**: the suffix check compares byte slices, no
//!   `format!`, no heap — the hot decision is allocation-free.
//! - **Length-gated short-circuit**: hosts shorter than an allowlist entry
//!   can never suffix-match it, so the loop skips them before touching bytes.
//! - **Case-folded in place**: `to_ascii_lowercase` happens once, on the
//!   caller's bytes, before any comparison.

use core::ffi::{c_char, CStr};

/// Permitted Category-A hosts. Favicon and remote-markdown fetches are
/// deliberately absent: their host is whatever page you navigated to, so
/// they are page-driven and cannot be allowlisted to a fixed set.
pub const HOSTS: [&str; 3] = [
    // Auto-update feed (Sparkle). User-consented.
    "github.com",
    // Memory Wave remote AI provider, default endpoint (off by default).
    "api.x.ai",
    // Omnibox autocomplete suggestions (off by default).
    "duckduckgo.com",
];

/// True when `host` is a permitted Category-A destination — exact match or a
/// subdomain of an allowlisted host. An empty or non-ASCII host is never
/// permitted. Allocation-free: the comparisons are byte-slice equality.
pub fn permits(host: &str) -> bool {
    let bytes = host.trim().as_bytes();
    if bytes.is_empty() || !bytes.is_ascii() {
        return false;
    }

    // Fold to lowercase in place (ASCII only — guarded above).
    let mut folded = [0u8; 253];
    let folded = if bytes.len() <= folded.len() {
        for (i, b) in bytes.iter().enumerate() {
            folded[i] = b.to_ascii_lowercase();
        }
        &folded[..bytes.len()]
    } else {
        return false; // longer than any plausible hostname
    };

    HOSTS.iter().any(|allowed| {
        let a = allowed.as_bytes();
        if folded == a {
            return true;
        }
        // Subdomain rule: ".example.com" suffix, boundary-aware. Length gate
        // first so the slice arithmetic is only done when it can match.
        folded.len() > a.len() && {
            let start = folded.len() - a.len() - 1;
            folded[start] == b'.' && &folded[start + 1..] == a
        }
    })
}

/// C ABI: `qw_egress_permits`. Null, empty, or non-UTF8 hosts are never
/// permitted.
///
/// # Safety
/// `host` must be a valid, NUL-terminated C string, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_egress_permits(host: *const c_char) -> bool {
    if host.is_null() {
        return false;
    }
    // SAFETY: caller contract — NUL-terminated string.
    let Ok(host) = unsafe { CStr::from_ptr(host) }.to_str() else {
        return false;
    };
    permits(host)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_matches_are_permitted() {
        for host in HOSTS {
            assert!(permits(host), "{host} must be permitted");
        }
    }

    #[test]
    fn subdomains_are_permitted_but_not_similar_names() {
        assert!(permits("codeload.github.com"));
        // The Swift doc pins this exact counterexample: it ends in
        // `.githubusercontent.com`, not `.github.com`.
        assert!(!permits("objects.githubusercontent.com"));
    }

    #[test]
    fn lookalikes_are_rejected() {
        assert!(!permits("github.com.evil.com"));
        assert!(!permits("notgithub.com"));
        assert!(!permits("duckduckgo.com.evil.net"));
    }

    #[test]
    fn empty_and_garbage_are_rejected() {
        assert!(!permits(""));
        assert!(!permits("   "));
    }

    #[test]
    fn the_vpn_host_left_with_the_layer() {
        assert!(!permits("api.mullvad.net"));
    }

    #[test]
    fn case_insensitive() {
        assert!(permits("GitHub.COM"));
    }

    #[test]
    fn boundary_aware_no_false_suffix() {
        // "xduckduckgo.com" must not match via a "duckduckgo.com" suffix
        // unless preceded by a dot.
        assert!(!permits("xduckduckgo.com"));
        assert!(permits("ac.duckduckgo.com"));
    }
}
