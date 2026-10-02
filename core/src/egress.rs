//! The Category-A egress allowlist — the committed set of hosts Qwave's own
//! code may contact. Ported exactly from the Swift `EgressAllowlist`;
//! `api.mullvad.net` left with the VPN layer.

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
/// subdomain of an allowlisted host (e.g. `codeload.github.com` is allowed,
/// `notgithub.com` is not). An empty or non-ASCII host is never permitted.
pub fn permits(host: &str) -> bool {
    let host = host.trim().to_ascii_lowercase();
    if host.is_empty() || !host.is_ascii() {
        return false;
    }
    HOSTS
        .iter()
        .any(|allowed| host == *allowed || host.ends_with(&format!(".{allowed}")))
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
}
