//! Sovereign membership badges & channel entitlement gate (`docs/productization.md` §4.3, §5.1–5.2).
//!
//! Two laws govern this module:
//!
//! 1. **Privacy is free, forever (`§0`).** The `Stable` channel is unconditionally
//!    permitted for every user — with no badge, an expired badge, or a corrupted
//!    badge. Anything that would degrade the free MIT browser to sell the paid
//!    channel is impossible by construction.
//! 2. **`#Commit = #ValidWitness` (`8b-is/sphered`).** A membership badge for
//!    the `Beta` or `Nightly` channels is accepted if and only if its 5-stage
//!    SpherePOP witness (`<(? admit ~ transform ! verify @ attribute > commit)>`)
//!    holds and its time window `[since_epoch, until_epoch]` covers `now_epoch`.
//!    Per `docs/productization.md` §5.2, this check is an in-app convenience and
//!    support indicator (never a lock on building or running `QWAVE_CHANNEL=nightly`).
//!    When absent or expired, the gate returns the plain, non-nagging notice:
//!    `"nightly is a member channel — stable is yours, free."`

use core::ffi::c_char;

/// Domain separation constant (`"QWAVE|SPHERED|BADGE|v1"`) folded into the
/// 64-bit witness seal so cross-protocol hashes never collide.
const WITNESS_DOMAIN: u64 = 0x5157_4156_455F_4244;

/// FNV-1a 64-bit offset basis and prime, paired with a Sip-style avalanche
/// finalizer for zero-dependency offline seal verification.
const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

/// Release channels in Qwave (`docs/productization.md` §4.1, §5.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Channel {
    /// The signed, notarized MIT release channel — free for everyone, forever.
    Stable = 0,
    /// Early-access beta features (superpowers, early models).
    Beta = 1,
    /// Bleeding-edge rolling build (all experimental WebKit flags ON, mem|16-10).
    Nightly = 2,
}

impl Channel {
    pub fn from_u8(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Stable),
            1 => Some(Self::Beta),
            2 => Some(Self::Nightly),
            _ => None,
        }
    }

    /// Plain, non-nagging one-line explanation for the channel (`§5.2`).
    pub const fn notice(self) -> &'static str {
        match self {
            Self::Stable => "stable is yours, free.",
            Self::Beta => "beta is a member channel — stable is yours, free.",
            Self::Nightly => "nightly is a member channel — stable is yours, free.",
        }
    }

    const fn notice_cstr(self) -> &'static core::ffi::CStr {
        match self {
            Self::Stable => c"stable is yours, free.",
            Self::Beta => c"beta is a member channel — stable is yours, free.",
            Self::Nightly => c"nightly is a member channel — stable is yours, free.",
        }
    }
}

/// Constellation membership tiers (`docs/PRODUCTIZATION.md` §3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Tier {
    /// €0 — the full MIT browser, stable channel, docs, library, hub read-only.
    Free = 0,
    /// €4.20 / mo — nightly + beta builds, academy, badge, weekly hub meeting.
    Supporter = 1,
    /// €12 / mo — everything + `PATRONS.md`, quarterly office hours, roadmap vote.
    Patron = 2,
    /// €42 / mo (5 seats) — institutional onboarding + supporter-of-record badge.
    Team = 3,
    /// Pay-what-you-want — the badge + one month of nightly, no lock-in.
    OneOff = 4,
}

impl Tier {
    pub fn from_u8(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Free),
            1 => Some(Self::Supporter),
            2 => Some(Self::Patron),
            3 => Some(Self::Team),
            4 => Some(Self::OneOff),
            _ => None,
        }
    }

    /// Monthly reference contribution in euro cents (`420` = €4.20 Pro constant).
    pub const fn monthly_euro_cents(self) -> u32 {
        match self {
            Self::Free | Self::OneOff => 0,
            Self::Supporter => 420,
            Self::Patron => 1200,
            Self::Team => 4200,
        }
    }

    /// Whether this tier unlocks member channels (`Beta` / `Nightly`) while active.
    pub const fn unlocks_member_channels(self) -> bool {
        !matches!(self, Self::Free)
    }
}

/// The 5-stage SpherePOP witness (`8b-is/sphered`):
/// `<(? admit ~ transform ! verify @ attribute > commit)>`.
///
/// Enforces the conservation law `#Commit = #ValidWitness`: a commit cannot
/// be forged without all four preceding stages succeeding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SphereWitness {
    /// `?` — admit: member_hash is non-zero and tier is recognized.
    pub admitted: bool,
    /// `~` — transform: time window is well-ordered (`since_epoch <= until_epoch`).
    pub transformed: bool,
    /// `!` — verify: cryptographic/deterministic seal matches payload.
    pub verified: bool,
    /// `@` — attribute: tier carries entitlement for the requested scope.
    pub attributed: bool,
}

impl SphereWitness {
    /// `>` — commit: true iff every stage of `<(? ~ ! @ >)>` succeeded.
    /// Conservation law: `#Commit = #ValidWitness`.
    pub const fn can_commit(&self) -> bool {
        self.admitted && self.transformed && self.verified && self.attributed
    }
}

/// A verifiable 8b-is membership badge (`docs/PRODUCTIZATION.md` §4.3, §5.1).
///
/// Contains no email and no PII — only a pseudonymous `member_hash`, the
/// `tier`, the validity window `[since_epoch, until_epoch]`, and the 64-bit
/// `witness_seal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Badge {
    pub member_hash: u64,
    pub tier: Tier,
    pub since_epoch: u64,
    pub until_epoch: u64,
    pub witness_seal: u64,
}

impl Badge {
    /// Issue and seal a new badge with the sovereign witness function.
    pub const fn issue(member_hash: u64, tier: Tier, since_epoch: u64, until_epoch: u64) -> Self {
        let witness_seal = compute_seal(member_hash, tier as u8, since_epoch, until_epoch);
        Self {
            member_hash,
            tier,
            since_epoch,
            until_epoch,
            witness_seal,
        }
    }

    /// Evaluate the 5-stage SpherePOP witness `<(? ~ ! @ >)>` for this badge.
    pub const fn witness(&self) -> SphereWitness {
        let admitted = self.member_hash != 0;
        let transformed = self.since_epoch > 0 && self.since_epoch <= self.until_epoch;
        let expected = compute_seal(
            self.member_hash,
            self.tier as u8,
            self.since_epoch,
            self.until_epoch,
        );
        let verified = self.witness_seal != 0 && self.witness_seal == expected;
        let attributed = self.tier.unlocks_member_channels();
        SphereWitness {
            admitted,
            transformed,
            verified,
            attributed,
        }
    }

    /// True when `#Commit = #ValidWitness` holds for this badge.
    pub const fn verify_witness(&self) -> bool {
        self.witness().can_commit()
    }

    /// True when `now_epoch` falls within the badge's inclusive validity window.
    pub const fn is_active_at(&self, now_epoch: u64) -> bool {
        self.since_epoch <= now_epoch && now_epoch <= self.until_epoch
    }
}

/// Verdict of the in-app channel gate (`docs/PRODUCTIZATION.md` §5.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GateDecision {
    /// Channel is unlocked.
    Permitted,
    /// Member channel requested without an active, valid badge; carries the
    /// non-nagging one-line reason pointing back to free `Stable`.
    MemberChannelRequired {
        channel: Channel,
        notice: &'static str,
    },
}

impl GateDecision {
    pub const fn is_permitted(&self) -> bool {
        matches!(self, Self::Permitted)
    }
}

/// Decide whether `channel` is unlocked at `now_epoch` given an optional `badge`.
///
/// - `Channel::Stable` is **always** `GateDecision::Permitted` (MIT invariant).
/// - `Channel::Beta` and `Channel::Nightly` require an unexpired badge whose
///   `SphereWitness::can_commit()` is true.
pub const fn decide_channel(
    channel: Channel,
    badge: Option<&Badge>,
    now_epoch: u64,
) -> GateDecision {
    if matches!(channel, Channel::Stable) {
        return GateDecision::Permitted;
    }
    if let Some(b) = badge
        && b.verify_witness()
        && b.is_active_at(now_epoch)
    {
        return GateDecision::Permitted;
    }
    GateDecision::MemberChannelRequired {
        channel,
        notice: channel.notice(),
    }
}

/// Compute the deterministic 64-bit witness seal over the badge fields.
pub const fn compute_seal(
    member_hash: u64,
    tier_raw: u8,
    since_epoch: u64,
    until_epoch: u64,
) -> u64 {
    let mut h = FNV_OFFSET;
    h = fnv_u64(h, WITNESS_DOMAIN);
    h = fnv_u64(h, member_hash);
    h = fnv_byte(h, tier_raw);
    h = fnv_u64(h, since_epoch);
    h = fnv_u64(h, until_epoch);
    avalanche64(h)
}

const fn fnv_byte(mut h: u64, b: u8) -> u64 {
    h ^= b as u64;
    h.wrapping_mul(FNV_PRIME)
}

const fn fnv_u64(mut h: u64, v: u64) -> u64 {
    let bytes = v.to_le_bytes();
    let mut i = 0;
    while i < 8 {
        h = fnv_byte(h, bytes[i]);
        i += 1;
    }
    h
}

/// SplitMix64 / MurmurHash3 finalizer avalanche so every input bit cascades
/// across all 64 bits of the witness seal.
const fn avalanche64(mut x: u64) -> u64 {
    x ^= x >> 30;
    x = x.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^= x >> 31;
    if x == 0 { 1 } else { x }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// C ABI: compute the 64-bit sovereign witness seal for a badge tuple.
#[unsafe(no_mangle)]
pub extern "C" fn qw_badge_seal(
    member_hash: u64,
    tier: u8,
    since_epoch: u64,
    until_epoch: u64,
) -> u64 {
    compute_seal(member_hash, tier, since_epoch, until_epoch)
}

/// C ABI: verify a badge's SpherePOP witness (`#Commit = #ValidWitness`).
#[unsafe(no_mangle)]
pub extern "C" fn qw_badge_verify(
    member_hash: u64,
    tier: u8,
    since_epoch: u64,
    until_epoch: u64,
    witness_seal: u64,
) -> bool {
    let Some(tier) = Tier::from_u8(tier) else {
        return false;
    };
    let badge = Badge {
        member_hash,
        tier,
        since_epoch,
        until_epoch,
        witness_seal,
    };
    badge.verify_witness()
}

/// C ABI: check whether `channel` (`0 = stable`, `1 = beta`, `2 = nightly`) is
/// entitled at `now_epoch`.
///
/// `stable` (`0`) always returns `true`.
#[unsafe(no_mangle)]
pub extern "C" fn qw_channel_entitled(
    channel: u8,
    member_hash: u64,
    tier: u8,
    since_epoch: u64,
    until_epoch: u64,
    witness_seal: u64,
    now_epoch: u64,
) -> bool {
    let Some(channel) = Channel::from_u8(channel) else {
        return false;
    };
    if matches!(channel, Channel::Stable) {
        return true;
    }
    let badge = Tier::from_u8(tier).map(|tier| Badge {
        member_hash,
        tier,
        since_epoch,
        until_epoch,
        witness_seal,
    });
    decide_channel(channel, badge.as_ref(), now_epoch).is_permitted()
}

/// C ABI: return the static NUL-terminated non-nagging notice for `channel`,
/// or null if `channel` is out of range.
#[unsafe(no_mangle)]
pub extern "C" fn qw_channel_notice(channel: u8) -> *const c_char {
    match Channel::from_u8(channel) {
        Some(ch) => ch.notice_cstr().as_ptr(),
        None => core::ptr::null(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_is_always_free_for_everyone() {
        // No badge at all:
        assert_eq!(
            decide_channel(Channel::Stable, None, 1_760_000_000),
            GateDecision::Permitted
        );
        // Expired or forged badge still cannot break Stable:
        let forged = Badge {
            member_hash: 0,
            tier: Tier::Free,
            since_epoch: 100,
            until_epoch: 50,
            witness_seal: 0xdead_beef,
        };
        assert!(!forged.verify_witness());
        assert_eq!(
            decide_channel(Channel::Stable, Some(&forged), 1_760_000_000),
            GateDecision::Permitted
        );
        assert!(qw_channel_entitled(0, 0, 0, 0, 0, 0, 0));
    }

    #[test]
    fn sphered_conservation_law_holds_on_valid_badge() {
        let since = 1_760_000_000;
        let until = 1_762_678_400;
        let badge = Badge::issue(0x8b15_cafe_d00d_0001, Tier::Supporter, since, until);

        let w = badge.witness();
        assert!(w.admitted);
        assert!(w.transformed);
        assert!(w.verified);
        assert!(w.attributed);
        assert!(w.can_commit(), "#Commit = #ValidWitness must hold");
        assert_eq!(badge.tier.monthly_euro_cents(), 420);

        assert_eq!(
            decide_channel(Channel::Nightly, Some(&badge), since + 3600),
            GateDecision::Permitted
        );
        assert_eq!(
            decide_channel(Channel::Beta, Some(&badge), until),
            GateDecision::Permitted
        );
    }

    #[test]
    fn tampered_or_expired_badge_refuses_nightly_without_nagging() {
        let since = 1_760_000_000;
        let until = 1_762_678_400;
        let mut badge = Badge::issue(0x8b15_cafe_d00d_0001, Tier::Supporter, since, until);

        // Expired after `until`:
        assert_eq!(
            decide_channel(Channel::Nightly, Some(&badge), until + 1),
            GateDecision::MemberChannelRequired {
                channel: Channel::Nightly,
                notice: "nightly is a member channel — stable is yours, free.",
            }
        );

        // Tamper with tier (Supporter -> Patron) without re-sealing:
        badge.tier = Tier::Patron;
        assert!(!badge.verify_witness(), "forged tier must fail !verify");
        assert!(!decide_channel(Channel::Nightly, Some(&badge), since + 10).is_permitted());
    }

    #[test]
    fn free_tier_badge_cannot_commit_member_channels() {
        let badge = Badge::issue(0x1234, Tier::Free, 100, 200);
        let w = badge.witness();
        assert!(w.admitted && w.transformed && w.verified);
        assert!(
            !w.attributed,
            "Free tier does not attribute member channel access"
        );
        assert!(!w.can_commit());
    }
}
