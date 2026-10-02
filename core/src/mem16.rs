//! The mem|16-10 wiring — the sovereign library's governing sequence,
//! available on every channel, with the crate itself linked on nightly only.
//!
//! The sequence of six step names is a fact of the sovereign library, not
//! creative expression, so it ships in every build. The AGPL-3.0-only crate
//! (`mem-16-10`) links in only under the `nightly` feature; the nightly gate
//! module below asserts the two stay in agreement.

/// The governing sequence (SpherePOP), as names: the order every admissible
/// transition must pass through.
pub const GOVERNING_SEQUENCE_NAMES: [&str; 6] = [
    "POP", "REFUSE", "BIND", "TRANSFORM", "VERIFY", "COLLAPSE",
];

/// The recovery sequence (Phoenix), as names.
pub const RECOVERY_SEQUENCE_NAMES: [&str; 7] = [
    "DISCOVER", "VERIFY", "REPLAY", "BRANCH", "RANK", "PROPOSE", "BIND/REFUSE",
];

/// The verification gate: only VERIFY (4) and COLLAPSE (5) are admissible
/// terminal steps.
pub fn verified(step_index: u32) -> bool {
    matches!(step_index, 4 | 5)
}

/// C ABI: the governing sequence's `i`-th step name, or null out of range.
///
/// # Safety
/// `i` may be any value; null is returned for out-of-range indices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_mem16_step_name(i: u32) -> *const core::ffi::c_char {
    match GOVERNING_SEQUENCE_NAMES.get(i as usize) {
        Some(name) => name.as_ptr().cast(),
        None => core::ptr::null(),
    }
}

/// The verification gate, over the C ABI.
#[unsafe(no_mangle)]
pub extern "C" fn qw_mem16_verified(i: u32) -> bool {
    verified(i)
}

/// Nightly-only: the real crate integration. `use mem16_10::*` — the
/// sovereign library itself, AGPL-3.0-only, linked only when every feature
/// is ON.
#[cfg(feature = "mem16")]
pub mod sovereign {
    pub use mem16_10::{Step, GOVERNING_SEQUENCE, RECOVERY_SEQUENCE};

    /// The gate over the real crate type: admissible only after `Verify`.
    pub fn verified(step: Step) -> bool {
        matches!(step, Step::Verify | Step::Collapse)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sequence_is_the_sovereign_order() {
        assert_eq!(
            GOVERNING_SEQUENCE_NAMES,
            ["POP", "REFUSE", "BIND", "TRANSFORM", "VERIFY", "COLLAPSE"]
        );
    }

    #[test]
    fn the_gate_admits_only_verified_steps() {
        assert!(verified(4));
        assert!(verified(5));
        assert!(!verified(0));
        assert!(!verified(1));
        assert!(!verified(2));
        assert!(!verified(3));
        assert!(!verified(9));
    }

    #[cfg(feature = "mem16")]
    #[test]
    fn the_real_crate_agrees_with_the_local_sequence() {
        use sovereign::GOVERNING_SEQUENCE;
        let local = GOVERNING_SEQUENCE_NAMES;
        let real = ["POP", "REFUSE", "BIND", "TRANSFORM", "VERIFY", "COLLAPSE"];
        assert_eq!(GOVERNING_SEQUENCE.len(), 6);
        assert_eq!(local, real);
        assert!(sovereign::verified(sovereign::Step::Verify));
        assert!(!sovereign::verified(sovereign::Step::Refuse));
    }
}
