//! `qwave_core::i1_soul` — Sovereign `i1.is` AI Provenance, Personal Data Field
//! Governance, and Soul Signature Authenticity Engine.
//!
//! Instead of AI companies scraping stripped, uncredited, or private web data,
//! Qwave empowers every user and creator to attach a cryptographic + stylometric
//! **Soul Signature** and explicit **Ingestion & Personal Field Policy** to any
//! page or work:
//!
//! 1. **Page Ingestion & Authorship Modes (`IngestMode`)**:
//!    - `Mine` (`0`): "This is mine" — claims original authorship, binds credit
//!      and the author's `SoulSignature` in `i1.is`, and permits consented AI
//!      indexing with mandatory attribution (revocable at any time by the author).
//!    - `SummarizeFromBrowsing` (`1`): "This is another person's work, but you
//!      can summarize/learn from my browsing" — preserves credit to the original
//!      author and **automatically yields if the original author revokes permission**.
//!    - `LocalAiOnly` (`2`): "Local AI only" — permits local on-device `MEM|8`
//!      (`WaveProvenance::Cognitive`) summarization; strictly blocked from `i1.is`
//!      or any external network egress.
//!    - `NoArchivePrivate` (`3`): "No archive / Private" — zero `i1.is` ingestion,
//!      zero local AI indexing, zero persistence.
//!
//! 2. **Granular Personal Data Field Governance (`PersonalField` × `FieldPolicy`)**:
//!    Per-field rules for `Username`, `Email`, `Phone`, `Website`, `Blog`,
//!    `XHandle`, `RedditHandle`, `GitHubHandle`, `PhysicalAddress`, and `LegalName`:
//!    - `AlwaysAllow` (`0`): Always cool to share and attach to `i1.is` attribution.
//!    - `AskEveryTime` (`1`): Prompt before sharing; redacted in unattended ingestion.
//!    - `RequiredFormsOnly` (`2`): Never ingest into AI/archives; only allow in
//!      interactive `<input required>` DOM forms with user confirmation.
//!    - `NeverStrip` (`3`): Never share anywhere; scrub/redact (`[REDACTED:...]`)
//!      before any local or remote AI processing.
//!
//! 3. **8b-is Soul Signature (`SoulSignature`)**:
//!    Combines:
//!    - A 256-bit cryptographic identity & namespace seal (`SHA-256` / `HMAC-SHA256`
//!      bound to `MEM|8` 79-byte `WaveInt` resonance at `0.73 Hz`),
//!    - A 16-dimensional integer stylometric cadence vector (`cadence_q10: [u16; 16]`)
//!      capturing sentence-length burstiness, punctuation rhythm (including `..`
//!      double-dot ellipses, em-dashes, parentheticals), lexical diversity, and
//!      structural cadence,
//!    - A 256-bit locality-sensitive shingle SimHash (`shingle_simhash: [u64; 4]`)
//!      that identifies an author's work even when scraped, re-wrapped, or stripped
//!      of its byline.
//!
//! **100% Pure Integer Math (Zero Floats)**: All similarity scores, cadence
//! vectors, and authenticity metrics operate in `Q10` (`0..1024`) integer space.

use core::ffi::{CStr, c_char};
use crate::badge::SphereWitness;
use crate::vault::{hmac_sha256, sha256};

/// Domain separation prefix for `i1.is` Soul Signatures and Provenance Deeds.
pub const I1_SOUL_DOMAIN: &[u8] = b"i1.is|qwave|soul-signature|v1";

/// Page ingestion & authorship disposition selected by the user in Qwave.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum IngestMode {
    /// "This is mine" — original author claim, full credit bound to Soul Signature.
    Mine = 0,
    /// "Another person's work — summarize from my browsing (original author can revoke)."
    SummarizeFromBrowsing = 1,
    /// "Local AI only" — on-device `MEM|8` Cognitive wave only; never sent to `i1.is`.
    LocalAiOnly = 2,
    /// "No archive / Private" — no remote ingestion and no local AI indexing.
    NoArchivePrivate = 3,
}

impl IngestMode {
    pub const fn from_u8(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Mine),
            1 => Some(Self::SummarizeFromBrowsing),
            2 => Some(Self::LocalAiOnly),
            3 => Some(Self::NoArchivePrivate),
            _ => None,
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Mine => "mine (original author credit)",
            Self::SummarizeFromBrowsing => "summarize from browsing (author-revocable)",
            Self::LocalAiOnly => "local AI only (on-device MEM|8)",
            Self::NoArchivePrivate => "no archive / private",
        }
    }

    /// True if this mode permits transmitting a provenance/ingestion deed to `i1.is`
    /// (provided the original author has not revoked permission).
    pub const fn allows_i1_egress(self, original_author_revoked: bool) -> bool {
        match self {
            Self::Mine => !original_author_revoked,
            Self::SummarizeFromBrowsing => !original_author_revoked,
            Self::LocalAiOnly | Self::NoArchivePrivate => false,
        }
    }

    /// True if this mode permits local on-device AI summarization (`MEM|8` Cognitive).
    pub const fn allows_local_ai(self) -> bool {
        matches!(self, Self::Mine | Self::SummarizeFromBrowsing | Self::LocalAiOnly)
    }
}

/// Personal data / identity field categories governed by the user's sovereign policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum PersonalField {
    Username = 0,
    Email = 1,
    Phone = 2,
    Website = 3,
    Blog = 4,
    XHandle = 5,
    RedditHandle = 6,
    GitHubHandle = 7,
    PhysicalAddress = 8,
    LegalName = 9,
}

impl PersonalField {
    pub const COUNT: usize = 10;

    pub const ALL: [Self; Self::COUNT] = [
        Self::Username,
        Self::Email,
        Self::Phone,
        Self::Website,
        Self::Blog,
        Self::XHandle,
        Self::RedditHandle,
        Self::GitHubHandle,
        Self::PhysicalAddress,
        Self::LegalName,
    ];

    pub const fn from_u8(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Username),
            1 => Some(Self::Email),
            2 => Some(Self::Phone),
            3 => Some(Self::Website),
            4 => Some(Self::Blog),
            5 => Some(Self::XHandle),
            6 => Some(Self::RedditHandle),
            7 => Some(Self::GitHubHandle),
            8 => Some(Self::PhysicalAddress),
            9 => Some(Self::LegalName),
            _ => None,
        }
    }

    pub const fn key(self) -> &'static str {
        match self {
            Self::Username => "username",
            Self::Email => "email",
            Self::Phone => "phone",
            Self::Website => "website",
            Self::Blog => "blog",
            Self::XHandle => "x_handle",
            Self::RedditHandle => "reddit_handle",
            Self::GitHubHandle => "github_handle",
            Self::PhysicalAddress => "physical_address",
            Self::LegalName => "legal_name",
        }
    }

    pub const fn redact_token(self) -> &'static str {
        match self {
            Self::Username => "[REDACTED:USERNAME]",
            Self::Email => "[REDACTED:EMAIL]",
            Self::Phone => "[REDACTED:PHONE]",
            Self::Website => "[REDACTED:WEBSITE]",
            Self::Blog => "[REDACTED:BLOG]",
            Self::XHandle => "[REDACTED:X]",
            Self::RedditHandle => "[REDACTED:REDDIT]",
            Self::GitHubHandle => "[REDACTED:GITHUB]",
            Self::PhysicalAddress => "[REDACTED:ADDRESS]",
            Self::LegalName => "[REDACTED:NAME]",
        }
    }
}

/// Per-field sharing & form-fill policy chosen by the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FieldPolicy {
    /// Always cool to include in `i1.is` attribution, summaries, and forms.
    AlwaysAllow = 0,
    /// Prompt the user before sharing; redacted in automatic/background ingestion.
    AskEveryTime = 1,
    /// Never include in AI ingestion or archives; only allow in required (`required`) DOM forms.
    RequiredFormsOnly = 2,
    /// Never share or fill; always strip/redact before any AI or network path.
    NeverStrip = 3,
}

impl FieldPolicy {
    pub const fn from_u8(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::AlwaysAllow),
            1 => Some(Self::AskEveryTime),
            2 => Some(Self::RequiredFormsOnly),
            3 => Some(Self::NeverStrip),
            _ => None,
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::AlwaysAllow => "always allow (public attribution)",
            Self::AskEveryTime => "ask every time",
            Self::RequiredFormsOnly => "required forms only (never in AI)",
            Self::NeverStrip => "never (always strip/redact)",
        }
    }

    /// True if this field may be included in an `i1.is` AI ingestion deed without
    /// an interactive per-field override.
    pub const fn allows_ai_ingestion(self, interactive_approved: bool) -> bool {
        match self {
            Self::AlwaysAllow => true,
            Self::AskEveryTime => interactive_approved,
            Self::RequiredFormsOnly | Self::NeverStrip => false,
        }
    }

    /// True if this field may be filled into a web form input.
    pub const fn allows_form_fill(self, is_required_field: bool, user_confirmed: bool) -> bool {
        match self {
            Self::AlwaysAllow => true,
            Self::AskEveryTime => user_confirmed,
            Self::RequiredFormsOnly => is_required_field && user_confirmed,
            Self::NeverStrip => false,
        }
    }
}

/// Complete 10-field sovereign personal data policy table.
///
/// Defaults reflect the creator-friendly sovereign posture:
/// - Public creator handles (`Username`, `Website`, `Blog`, `XHandle`,
///   `RedditHandle`, `GitHubHandle`) default to `AlwaysAllow` so the creator gets
///   instant attribution credit.
/// - `Email` and `LegalName` default to `AskEveryTime`.
/// - `Phone` exists as `RequiredFormsOnly`.
/// - `PhysicalAddress` defaults to `NeverStrip`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldPolicyTable {
    pub policies: [FieldPolicy; PersonalField::COUNT],
    pub values: [String; PersonalField::COUNT],
}

impl Default for FieldPolicyTable {
    fn default() -> Self {
        Self::creator_default()
    }
}

impl FieldPolicyTable {
    pub fn creator_default() -> Self {
        Self {
            policies: [
                FieldPolicy::AlwaysAllow,       // Username
                FieldPolicy::AskEveryTime,      // Email
                FieldPolicy::RequiredFormsOnly, // Phone
                FieldPolicy::AlwaysAllow,       // Website
                FieldPolicy::AlwaysAllow,       // Blog
                FieldPolicy::AlwaysAllow,       // XHandle
                FieldPolicy::AlwaysAllow,       // RedditHandle
                FieldPolicy::AlwaysAllow,       // GitHubHandle
                FieldPolicy::NeverStrip,        // PhysicalAddress
                FieldPolicy::AskEveryTime,      // LegalName
            ],
            values: Default::default(),
        }
    }

    pub fn policy(&self, field: PersonalField) -> FieldPolicy {
        self.policies[field as usize]
    }

    pub fn set_policy(&mut self, field: PersonalField, policy: FieldPolicy) {
        self.policies[field as usize] = policy;
    }

    pub fn value(&self, field: PersonalField) -> &str {
        &self.values[field as usize]
    }

    pub fn set_value(&mut self, field: PersonalField, val: impl Into<String>) {
        self.values[field as usize] = val.into();
    }

    /// Scrub/redact personal data from `text` prior to AI summarization or `i1.is`
    /// ingestion according to each field's policy.
    ///
    /// Both user-configured field values AND pattern-detected emails/phones/handles
    /// are governed by the corresponding `PersonalField` policy.
    pub fn scrub_text_for_ai(&self, text: &str, interactive_approved: bool) -> (String, u32) {
        let mut out = String::from(text);
        let mut redactions = 0u32;

        // 1. Scrub any explicit user-configured field values whose policy forbids AI ingestion
        for field in PersonalField::ALL {
            let pol = self.policy(field);
            if !pol.allows_ai_ingestion(interactive_approved) {
                let val = self.value(field).trim();
                if val.len() >= 3 && out.contains(val) {
                    let count = out.matches(val).count() as u32;
                    redactions = redactions.saturating_add(count);
                    out = out.replace(val, field.redact_token());
                }
            }
        }

        // 2. Pattern-based email scrubbing if Email policy forbids AI ingestion
        if !self
            .policy(PersonalField::Email)
            .allows_ai_ingestion(interactive_approved)
        {
            let (scrubbed, c) = redact_email_tokens(&out);
            out = scrubbed;
            redactions = redactions.saturating_add(c);
        }

        // 3. Pattern-based phone scrubbing if Phone policy forbids AI ingestion
        if !self
            .policy(PersonalField::Phone)
            .allows_ai_ingestion(interactive_approved)
        {
            let (scrubbed, c) = redact_phone_tokens(&out);
            out = scrubbed;
            redactions = redactions.saturating_add(c);
        }

        // 4. Pattern-based Reddit `u/handle` scrubbing if RedditHandle policy forbids AI ingestion
        if !self
            .policy(PersonalField::RedditHandle)
            .allows_ai_ingestion(interactive_approved)
        {
            let (scrubbed, c) = redact_prefixed_handle(&out, "u/", PersonalField::RedditHandle.redact_token());
            out = scrubbed;
            redactions = redactions.saturating_add(c);
        }

        (out, redactions)
    }

    /// Collect the public attribution fields that are permitted for `i1.is` credit.
    pub fn permitted_attribution_pairs(&self, interactive_approved: bool) -> Vec<(&'static str, String)> {
        let mut pairs = Vec::new();
        for field in PersonalField::ALL {
            if self.policy(field).allows_ai_ingestion(interactive_approved) {
                let v = self.value(field).trim();
                if !v.is_empty() {
                    pairs.push((field.key(), String::from(v)));
                }
            }
        }
        pairs
    }
}

fn redact_email_tokens(input: &str) -> (String, u32) {
    let mut out = String::with_capacity(input.len());
    let mut count = 0u32;
    for (idx, line) in input.split('\n').enumerate() {
        if idx > 0 {
            out.push('\n');
        }
        for (w_idx, token) in line.split(' ').enumerate() {
            if w_idx > 0 {
                out.push(' ');
            }
            let trimmed = token.trim_matches(|c: char| ",.;:()<>\"'[]{}".contains(c));
            if looks_like_email(trimmed) {
                let prefix_len = token.find(trimmed).unwrap_or(0);
                let suffix_start = prefix_len + trimmed.len();
                out.push_str(&token[..prefix_len]);
                out.push_str(PersonalField::Email.redact_token());
                out.push_str(&token[suffix_start..]);
                count = count.saturating_add(1);
            } else {
                out.push_str(token);
            }
        }
    }
    (out, count)
}

fn looks_like_email(s: &str) -> bool {
    if s.len() < 5 || s.starts_with('@') || s.ends_with('@') {
        return false;
    }
    let Some(at_pos) = s.find('@') else {
        return false;
    };
    let local = &s[..at_pos];
    let domain = &s[at_pos + 1..];
    !local.is_empty()
        && domain.len() >= 3
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._+-@".contains(&b))
}

fn redact_phone_tokens(input: &str) -> (String, u32) {
    // Scan for contiguous phone-like sequences with 10..15 digits (e.g. +1-555-234-5678 or (555) 234-5678)
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut count = 0u32;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() || (bytes[i] == b'+' && i + 1 < bytes.len() && bytes[i + 1].is_ascii_digit()) {
            let mut j = i;
            let mut digits = 0u32;
            let mut seps = 0u32;
            while j < bytes.len() {
                let b = bytes[j];
                if b.is_ascii_digit() {
                    digits += 1;
                    j += 1;
                } else if b == b'-' || b == b' ' || b == b'.' || b == b'(' || b == b')' || (b == b'+' && j == i) {
                    seps += 1;
                    j += 1;
                } else {
                    break;
                }
            }
            // Trim trailing spaces/dots from the match
            while j > i && (bytes[j - 1] == b' ' || bytes[j - 1] == b'.' || bytes[j - 1] == b'-') {
                j -= 1;
                seps = seps.saturating_sub(1);
            }
            if (10..=15).contains(&digits) && seps >= 1 {
                out.push_str(PersonalField::Phone.redact_token());
                count = count.saturating_add(1);
                i = j;
                continue;
            }
        }
        // Safe UTF-8 char advance
        let ch = input[i..].chars().next().unwrap_or('\0');
        out.push(ch);
        i += ch.len_utf8().max(1);
    }
    (out, count)
}

fn redact_prefixed_handle(input: &str, prefix: &str, replacement: &str) -> (String, u32) {
    let mut out = String::with_capacity(input.len());
    let mut count = 0u32;
    for (idx, word) in input.split(' ').enumerate() {
        if idx > 0 {
            out.push(' ');
        }
        let trimmed = word.trim_matches(|c: char| ",.;:()<>\"'[]{}".contains(c));
        if trimmed.starts_with(prefix) && trimmed.len() > prefix.len() + 1 {
            out.push_str(replacement);
            count = count.saturating_add(1);
        } else {
            out.push_str(word);
        }
    }
    (out, count)
}

// ============================================================================
// 2. The 8b-is Soul Signature (Cryptographic Seal + Stylometric Cadence + SimHash)
// ============================================================================

/// 16-dimensional integer stylometric & harmonic cadence fingerprint (`Q10` = `0..1024`)
/// plus a 256-bit locality-sensitive shingle SimHash and cryptographic identity seal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SoulSignature {
    /// Creator's canonical handle or identifier (e.g. `"hue@8b.is"`).
    pub creator_id: String,
    /// 256-bit cryptographic identity & key-bound seal (`HMAC-SHA256(secret, I1_SOUL_DOMAIN || creator_id)`).
    pub identity_seal: [u8; 32],
    /// 16-dimensional stylometric cadence vector in `Q10` (`0..1024`):
    /// - `[0]`: Mean sentence length (`words * 32`, clamped `0..1024`)
    /// - `[1]`: Sentence length burstiness / dynamic range (`(max - min) * 16`, `0..1024`)
    /// - `[2]`: Double-dot / ellipsis cadence (`".."`, per-100-words scaled `Q10`)
    /// - `[3]`: Dash / em-dash cadence (`"--"` / `"—"`, scaled `Q10`)
    /// - `[4]`: Question density (`'?'`, scaled `Q10`)
    /// - `[5]`: Exclamation / emphasis density (`'!'`, scaled `Q10`)
    /// - `[6]`: Parenthetical / aside density (`'('` / `')'`, scaled `Q10`)
    /// - `[7]`: Comma clause rhythm (`','`, scaled `Q10`)
    /// - `[8]`: Colon / semicolon structural ratio (`':'` / `';'`, scaled `Q10`)
    /// - `[9]`: Lexical diversity / type-token ratio (`unique_words * 1024 / total_words`)
    /// - `[10]`: Long-word ratio (`>= 7` chars, `Q10`)
    /// - `[11]`: Short punchy sentence ratio (`<= 6` words, `Q10`)
    /// - `[12]`: First-person sovereign voice ratio (`"i"`, `"we"`, `"my"`, `"our"`, `Q10`)
    /// - `[13]`: Relational / warmth lexicon resonance (`Q10`)
    /// - `[14]`: Technical / architectural lexicon resonance (`Q10`)
    /// - `[15]`: Paragraph cadence & line-break rhythm (`Q10`)
    pub cadence_q10: [u16; 16],
    /// 256-bit locality-sensitive SimHash over normalized 3-word shingles of the work.
    pub shingle_simhash: [u64; 4],
    /// 64-bit compact Soul Tag (`fnv64` fold of `identity_seal` + `cadence_q10`).
    pub soul_tag: u64,
}

impl SoulSignature {
    /// Mint a new `SoulSignature` from a creator's ID, personal secret/signature phrase,
    /// and a representative writing sample (or the current authored document).
    pub fn mint(creator_id: &str, signature_secret: &[u8], writing_sample: &str) -> Self {
        let mut domain_input = Vec::with_capacity(I1_SOUL_DOMAIN.len() + 1 + creator_id.len());
        domain_input.extend_from_slice(I1_SOUL_DOMAIN);
        domain_input.push(b'|');
        domain_input.extend_from_slice(creator_id.trim().as_bytes());
        let identity_seal = hmac_sha256(signature_secret, &domain_input);

        let cadence_q10 = compute_cadence_vector_q10(writing_sample);
        let shingle_simhash = compute_shingle_simhash_256(writing_sample);
        let soul_tag = compute_soul_tag(&identity_seal, &cadence_q10);

        Self {
            creator_id: String::from(creator_id.trim()),
            identity_seal,
            cadence_q10,
            shingle_simhash,
            soul_tag,
        }
    }

    /// Format the compact `i1-soul://` URI for embedding in headers, `.m8` sidecars,
    /// or `i1.is` database records.
    pub fn to_uri(&self) -> String {
        let seal_prefix = u64::from_be_bytes(self.identity_seal[0..8].try_into().unwrap());
        format!(
            "i1-soul://{}@{:016x}/{:016x}:{:016x}",
            self.creator_id, self.soul_tag, seal_prefix, self.shingle_simhash[0]
        )
    }

    /// Compare a candidate text against this `SoulSignature` and return:
    /// - `stylometric_q10` (`0..1024`): How closely the writing cadence matches this author's Soul Signature.
    /// - `shingle_q10` (`0..1024`): How much phrase/structural shingle overlap exists (even if stripped/edited).
    /// - `combined_q10` (`0..1024`): Weighted authenticity & authorship match score.
    pub fn verify_work_similarity(&self, candidate_text: &str) -> SoulMatchResult {
        let cand_cadence = compute_cadence_vector_q10(candidate_text);
        let cand_simhash = compute_shingle_simhash_256(candidate_text);

        // 1. Stylometric cadence similarity (1024 - mean absolute difference)
        let mut diff_sum = 0u32;
        for i in 0..16 {
            let a = self.cadence_q10[i] as i32;
            let b = cand_cadence[i] as i32;
            diff_sum += (a - b).unsigned_abs();
        }
        let mean_diff = (diff_sum / 16).min(1024);
        let stylometric_q10 = (1024 - mean_diff) as u16;

        // 2. 256-bit SimHash Hamming similarity
        let mut hamming_dist = 0u32;
        for i in 0..4 {
            hamming_dist += (self.shingle_simhash[i] ^ cand_simhash[i]).count_ones();
        }
        // 0 bits different -> 1024; 128 bits (random orthogonal) -> 0
        let shingle_q10 = if hamming_dist >= 128 {
            0u16
        } else {
            (((128 - hamming_dist) * 1024) / 128) as u16
        };

        // 3. Human organic authenticity score (burstiness + signature punctuation + lexical diversity)
        let organic_authenticity_q10 = compute_organic_authenticity_q10(&cand_cadence);

        // Combined authorship match: if shingle_q10 is high (same or derived text), weight shingle 60% + style 40%;
        // if brand-new text by the same author, stylometric cadence carries 75% weight.
        let combined_q10 = if shingle_q10 > 550 {
            ((shingle_q10 as u32 * 6 + stylometric_q10 as u32 * 4) / 10) as u16
        } else {
            ((stylometric_q10 as u32 * 3 + shingle_q10 as u32) / 4) as u16
        };

        SoulMatchResult {
            soul_tag: self.soul_tag,
            stylometric_q10,
            shingle_q10,
            organic_authenticity_q10,
            combined_q10,
            is_authentic_match: combined_q10 >= 700,
        }
    }
}

/// Result of matching a document or passage against an author's `SoulSignature`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SoulMatchResult {
    pub soul_tag: u64,
    pub stylometric_q10: u16,
    pub shingle_q10: u16,
    pub organic_authenticity_q10: u16,
    pub combined_q10: u16,
    pub is_authentic_match: bool,
}

/// Compute the 16-dimensional integer stylometric cadence vector in `Q10` (`0..1024`).
pub fn compute_cadence_vector_q10(text: &str) -> [u16; 16] {
    let bytes = text.as_bytes();
    if bytes.is_empty() {
        return [0u16; 16];
    }

    let mut total_words = 0u32;
    let mut long_words = 0u32;
    let mut first_person = 0u32;
    let mut warmth_words = 0u32;
    let mut tech_words = 0u32;

    // Track up to 256 unique word hashes for deterministic type-token ratio
    let mut unique_hashes = [0u64; 256];
    let mut unique_count = 0usize;

    let mut sentences = 0u32;
    let mut cur_sentence_words = 0u32;
    let mut min_sent_words = u32::MAX;
    let mut max_sent_words = 0u32;
    let mut short_sentences = 0u32;

    for raw_word in text.split_whitespace() {
        let clean = raw_word.trim_matches(|c: char| !c.is_alphanumeric());
        if clean.is_empty() {
            continue;
        }
        total_words += 1;
        cur_sentence_words += 1;
        if clean.len() >= 7 {
            long_words += 1;
        }

        // Lowercase FNV-1a hash of the word
        let mut h = 0xcbf2_9ce4_8422_2325u64;
        for b in clean.bytes() {
            h ^= b.to_ascii_lowercase() as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        if unique_count < unique_hashes.len() && !unique_hashes[..unique_count].contains(&h) {
            unique_hashes[unique_count] = h;
            unique_count += 1;
        }

        let lower = clean.to_ascii_lowercase();
        if matches!(lower.as_str(), "i" | "we" | "my" | "our" | "us" | "me" | "mine") {
            first_person += 1;
        }
        if matches!(
            lower.as_str(),
            "love" | "warmth" | "sanctuary" | "soul" | "heart" | "feel" | "soothing" | "care" | "credit" | "trust"
        ) {
            warmth_words += 1;
        }
        if matches!(
            lower.as_str(),
            "engine" | "server" | "servers" | "database" | "signature" | "ai" | "train" | "data" | "kernel" | "wave"
        ) {
            tech_words += 1;
        }

        if raw_word.ends_with('.') || raw_word.ends_with('!') || raw_word.ends_with('?') {
            sentences += 1;
            if cur_sentence_words < min_sent_words {
                min_sent_words = cur_sentence_words;
            }
            if cur_sentence_words > max_sent_words {
                max_sent_words = cur_sentence_words;
            }
            if cur_sentence_words <= 6 {
                short_sentences += 1;
            }
            cur_sentence_words = 0;
        }
    }

    if cur_sentence_words > 0 {
        sentences += 1;
        if cur_sentence_words < min_sent_words {
            min_sent_words = cur_sentence_words;
        }
        if cur_sentence_words > max_sent_words {
            max_sent_words = cur_sentence_words;
        }
        if cur_sentence_words <= 6 {
            short_sentences += 1;
        }
    }

    let tw = total_words.max(1);
    let sc = sentences.max(1);
    if min_sent_words == u32::MAX {
        min_sent_words = 0;
    }

    // Punctuation & structural cadence counts
    let double_dots = text.matches("..").count() as u32;
    let dashes = text.matches("--").count() as u32 + text.matches('—').count() as u32 + text.matches(" - ").count() as u32;
    let questions = bytes.iter().filter(|&&b| b == b'?').count() as u32;
    let exclamations = bytes.iter().filter(|&&b| b == b'!').count() as u32;
    let parens = bytes.iter().filter(|&&b| b == b'(' || b == b')').count() as u32;
    let commas = bytes.iter().filter(|&&b| b == b',').count() as u32;
    let colons = bytes.iter().filter(|&&b| b == b':' || b == b';').count() as u32;
    let newlines = bytes.iter().filter(|&&b| b == b'\n').count() as u32;

    let mean_words_q10 = ((tw * 32) / sc).min(1024) as u16;
    let burstiness_q10 = ((max_sent_words.saturating_sub(min_sent_words)) * 28).min(1024) as u16;
    let double_dot_q10 = ((double_dots * 4096) / tw).min(1024) as u16;
    let dash_q10 = ((dashes * 4096) / tw).min(1024) as u16;
    let question_q10 = ((questions * 4096) / tw).min(1024) as u16;
    let exclam_q10 = ((exclamations * 4096) / tw).min(1024) as u16;
    let paren_q10 = ((parens * 3072) / tw).min(1024) as u16;
    let comma_q10 = ((commas * 2048) / tw).min(1024) as u16;
    let colon_q10 = ((colons * 4096) / tw).min(1024) as u16;
    let ttr_q10 = ((unique_count as u32 * 1024) / tw.min(256)).min(1024) as u16;
    let long_word_q10 = ((long_words * 1024) / tw).min(1024) as u16;
    let short_sent_q10 = ((short_sentences * 1024) / sc).min(1024) as u16;
    let first_person_q10 = ((first_person * 3072) / tw).min(1024) as u16;
    let warmth_q10 = ((warmth_words * 4096) / tw).min(1024) as u16;
    let tech_q10 = ((tech_words * 4096) / tw).min(1024) as u16;
    let para_q10 = ((newlines * 2048) / sc).min(1024) as u16;

    [
        mean_words_q10,
        burstiness_q10,
        double_dot_q10,
        dash_q10,
        question_q10,
        exclam_q10,
        paren_q10,
        comma_q10,
        colon_q10,
        ttr_q10,
        long_word_q10,
        short_sent_q10,
        first_person_q10,
        warmth_q10,
        tech_q10,
        para_q10,
    ]
}

/// Compute a 256-bit locality-sensitive SimHash over normalized 3-word shingles.
pub fn compute_shingle_simhash_256(text: &str) -> [u64; 4] {
    let mut words: Vec<[u8; 16]> = Vec::new();
    for raw in text.split_whitespace() {
        let mut buf = [0u8; 16];
        let mut len = 0usize;
        for b in raw.bytes() {
            if b.is_ascii_alphanumeric() && len < 16 {
                buf[len] = b.to_ascii_lowercase();
                len += 1;
            }
        }
        if len > 0 {
            words.push(buf);
        }
    }
    if words.is_empty() {
        return [0u64; 4];
    }

    let mut bit_weights = [0i32; 256];
    let window = words.len().min(3);
    let limit = if words.len() >= 3 { words.len() - 2 } else { 1 };

    for i in 0..limit {
        let mut shingle_bytes = [0u8; 48];
        for k in 0..window {
            shingle_bytes[k * 16..(k + 1) * 16].copy_from_slice(&words[i + k]);
        }
        let digest = sha256(&shingle_bytes);
        for bit_idx in 0..256 {
            let byte = digest[bit_idx / 8];
            let bit = (byte >> (bit_idx % 8)) & 1;
            if bit == 1 {
                bit_weights[bit_idx] += 1;
            } else {
                bit_weights[bit_idx] -= 1;
            }
        }
    }

    let mut out = [0u64; 4];
    for bit_idx in 0..256 {
        if bit_weights[bit_idx] >= 0 {
            out[bit_idx / 64] |= 1u64 << (bit_idx % 64);
        }
    }
    out
}

/// Estimate organic human authenticity (`0..1024`) from cadence burstiness,
/// personal voice, punctuation character (`..`, parens, questions), and lexical diversity.
pub fn compute_organic_authenticity_q10(cadence: &[u16; 16]) -> u16 {
    let burstiness = cadence[1] as u32;
    let personal_punct = (cadence[2] as u32 + cadence[3] as u32 + cadence[4] as u32 + cadence[6] as u32).min(1024);
    let lexical_ttr = cadence[9] as u32;
    let voice = (cadence[11] as u32 + cadence[12] as u32).min(1024);
    ((burstiness * 3 + personal_punct * 2 + lexical_ttr * 3 + voice * 2) / 10).min(1024) as u16
}

fn compute_soul_tag(identity_seal: &[u8; 32], cadence: &[u16; 16]) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325u64;
    for &b in identity_seal {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    for &c in cadence {
        h ^= c as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

// ============================================================================
// 3. Smart Tree Quantum `.m8` Context Compressor & `i1.is` Ingestion Deed
// ============================================================================

/// Smart Tree Quantum `.m8` structural digest of a web page or document tree.
///
/// Compresses headings, key assertions, code blocks, and structural nodes into
/// Smart Tree's compact `QUANTUM_I1_M8_V1` wire format while tracking exact
/// byte savings (`compression_ratio_q10`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SmartTreeM8Digest {
    pub quantum_m8: String,
    pub raw_bytes: u32,
    pub compressed_bytes: u32,
    /// Savings ratio in `Q10` (`0..1024`, where `768` = 75% token reduction).
    pub savings_q10: u16,
    pub node_count: u16,
}

/// Compress scrubbed page/document text into Smart Tree's `QUANTUM_I1_M8_V1`
/// structural `.m8` format for `i1.is` and local `MEM|8` waves.
pub fn compress_to_smart_tree_m8(
    canonical_url: &str,
    scrubbed_text: &str,
    soul: &SoulSignature,
    mode: IngestMode,
) -> SmartTreeM8Digest {
    let raw_bytes = scrubbed_text.len() as u32;
    if scrubbed_text.trim().is_empty() || matches!(mode, IngestMode::NoArchivePrivate) {
        return SmartTreeM8Digest {
            quantum_m8: String::new(),
            raw_bytes,
            compressed_bytes: 0,
            savings_q10: 0,
            node_count: 0,
        };
    }

    let mut out = String::with_capacity((scrubbed_text.len() / 2).max(128));
    use core::fmt::Write;
    let _ = writeln!(
        &mut out,
        "ST_M8_V1|url={}|mode={}|soul={:016x}|creator={}",
        canonical_url.trim(),
        mode as u8,
        soul.soul_tag,
        soul.creator_id
    );

    let mut node_count = 0u16;
    for raw_line in scrubbed_text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        node_count = node_count.saturating_add(1);
        if line.starts_with('#') {
            let _ = writeln!(&mut out, "H:{line}");
        } else if line.starts_with("```") || line.starts_with("fn ") || line.starts_with("pub ") {
            let _ = writeln!(&mut out, "C:{line}");
        } else {
            // Keep salient sentences, trim filler whitespace, cap per-node length at 180 chars
            let clipped = if line.len() > 180 {
                let mut end = 180;
                while end > 0 && !line.is_char_boundary(end) {
                    end -= 1;
                }
                &line[..end]
            } else {
                line
            };
            let _ = writeln!(&mut out, "N:{clipped}");
        }
    }

    let compressed_bytes = out.len() as u32;
    let savings_q10 = if raw_bytes > compressed_bytes && raw_bytes > 0 {
        (((raw_bytes - compressed_bytes) as u64 * 1024) / raw_bytes as u64).min(1024) as u16
    } else {
        0
    };

    SmartTreeM8Digest {
        quantum_m8: out,
        raw_bytes,
        compressed_bytes,
        savings_q10,
        node_count,
    }
}

/// A complete, SpherePOP-witnessed `i1.is` Provenance & Ingestion Deed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct I1IngestDeed {
    pub canonical_url: String,
    pub mode: IngestMode,
    pub original_author_id: String,
    pub original_author_revoked: bool,
    pub soul_uri: String,
    pub soul_tag: u64,
    pub organic_authenticity_q10: u16,
    pub scrubbed_content: String,
    pub smart_tree_m8: SmartTreeM8Digest,
    pub content_sha256_hex: String,
    pub redaction_count: u32,
    pub attribution_fields: Vec<(&'static str, String)>,
    pub witness: SphereWitness,
    pub deed_seal: u64,
}

impl I1IngestDeed {
    /// Build and seal a new `I1IngestDeed` for a page or authored document.
    pub fn create(
        canonical_url: &str,
        raw_content: &str,
        mode: IngestMode,
        original_author_id: &str,
        original_author_revoked: bool,
        soul: &SoulSignature,
        field_policies: &FieldPolicyTable,
        interactive_approved: bool,
    ) -> Self {
        let (scrubbed_content, redaction_count) = if matches!(mode, IngestMode::NoArchivePrivate) {
            (String::new(), 0)
        } else {
            field_policies.scrub_text_for_ai(raw_content, interactive_approved)
        };

        let smart_tree_m8 = compress_to_smart_tree_m8(canonical_url, &scrubbed_content, soul, mode);

        let digest = sha256(scrubbed_content.as_bytes());
        let mut content_sha256_hex = String::with_capacity(64);
        for b in digest {
            use core::fmt::Write;
            let _ = write!(&mut content_sha256_hex, "{b:02x}");
        }

        let match_res = soul.verify_work_similarity(raw_content);
        let attribution_fields = if mode.allows_i1_egress(original_author_revoked) {
            field_policies.permitted_attribution_pairs(interactive_approved)
        } else {
            Vec::new()
        };

        // Evaluate the 5-stage SpherePOP witness `<(? admit ~ transform ! verify @ attribute > commit)>`
        let admitted = !canonical_url.trim().is_empty() && mode.allows_i1_egress(original_author_revoked);
        let transformed = !scrubbed_content.is_empty();
        let verified = soul.soul_tag != 0 && !content_sha256_hex.is_empty();
        let attributed = !original_author_id.trim().is_empty() || matches!(mode, IngestMode::Mine);

        let witness = SphereWitness {
            admitted,
            transformed,
            verified,
            attributed,
        };

        let deed_seal = if witness.can_commit() {
            let mut h = soul.soul_tag;
            for b in digest {
                h ^= b as u64;
                h = h.wrapping_mul(0x0000_0100_0000_01b3);
            }
            h ^= (mode as u8) as u64;
            h
        } else {
            0
        };

        Self {
            canonical_url: String::from(canonical_url.trim()),
            mode,
            original_author_id: if original_author_id.trim().is_empty() {
                soul.creator_id.clone()
            } else {
                String::from(original_author_id.trim())
            },
            original_author_revoked,
            soul_uri: soul.to_uri(),
            soul_tag: soul.soul_tag,
            organic_authenticity_q10: match_res.organic_authenticity_q10,
            scrubbed_content,
            smart_tree_m8,
            content_sha256_hex,
            redaction_count,
            attribution_fields,
            witness,
            deed_seal,
        }
    }

    /// True if `#Commit = #ValidWitness` holds and this deed is cleared for `i1.is` ingestion.
    pub const fn can_ingest_to_i1(&self) -> bool {
        self.witness.can_commit() && self.deed_seal != 0
    }
}

// ============================================================================
// 4. C ABI for Swift (`QwaveKit` / `SovereignCore`)
// ============================================================================

/// C ABI summary returned by `qw_i1_evaluate_deed`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QwI1DeedSummary {
    pub soul_tag: u64,
    pub deed_seal: u64,
    pub stylometric_q10: u16,
    pub shingle_q10: u16,
    pub organic_authenticity_q10: u16,
    pub combined_match_q10: u16,
    pub smart_tree_savings_q10: u16,
    pub smart_tree_nodes: u16,
    pub redaction_count: u32,
    pub can_ingest_i1: bool,
    pub can_summarize_local: bool,
}

/// C ABI: evaluate a page's `SoulSignature` match, personal field scrubbing, and
/// `i1.is` ingestion eligibility in one zero-float call.
///
/// # Safety
/// All pointer arguments must be valid NUL-terminated UTF-8 strings or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_i1_evaluate_deed(
    creator_id: *const c_char,
    secret_phrase: *const c_char,
    canonical_url: *const c_char,
    page_text: *const c_char,
    ingest_mode: u8,
    original_author_revoked: bool,
    out_summary: *mut QwI1DeedSummary,
) -> bool {
    if out_summary.is_null() {
        return false;
    }
    let cid = unsafe { cstr_or_empty(creator_id) };
    let sec = unsafe { cstr_or_empty(secret_phrase) };
    let url = unsafe { cstr_or_empty(canonical_url) };
    let txt = unsafe { cstr_or_empty(page_text) };
    let Some(mode) = IngestMode::from_u8(ingest_mode) else {
        return false;
    };

    let soul = SoulSignature::mint(
        if cid.is_empty() { "sovereign@8b.is" } else { cid },
        sec.as_bytes(),
        txt,
    );
    let match_res = soul.verify_work_similarity(txt);
    let policies = FieldPolicyTable::creator_default();
    let deed = I1IngestDeed::create(
        url,
        txt,
        mode,
        cid,
        original_author_revoked,
        &soul,
        &policies,
        false,
    );

    unsafe {
        *out_summary = QwI1DeedSummary {
            soul_tag: soul.soul_tag,
            deed_seal: deed.deed_seal,
            stylometric_q10: match_res.stylometric_q10,
            shingle_q10: match_res.shingle_q10,
            organic_authenticity_q10: match_res.organic_authenticity_q10,
            combined_match_q10: match_res.combined_q10,
            smart_tree_savings_q10: deed.smart_tree_m8.savings_q10,
            smart_tree_nodes: deed.smart_tree_m8.node_count,
            redaction_count: deed.redaction_count,
            can_ingest_i1: deed.can_ingest_to_i1(),
            can_summarize_local: mode.allows_local_ai(),
        };
    }
    true
}

unsafe fn cstr_or_empty<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_AUTHOR_TEXT: &str = "So, strange thought here.. Maybe we should consider something so radically different. \
        That it can change the way AI can train. I think Qwave should have a feature to make a page ingested by i1.is servers! \
        Instead of companies training on stripped or obfuscated data.. this allows people to instantly say: This is mine, \
        or summarize from my browsing, or local AI only, or private.";

    #[test]
    fn soul_signature_identifies_author_even_when_stripped_or_quoted() {
        let soul = SoulSignature::mint("hue@8b.is", b"my-sovereign-soul-key", SAMPLE_AUTHOR_TEXT);
        assert_ne!(soul.soul_tag, 0);
        assert!(soul.to_uri().starts_with("i1-soul://hue@8b.is@"));

        // Strip the opening and test a lightly edited excerpt:
        let stripped_excerpt = "Maybe we should consider something so radically different.. \
            That it can change the way AI can train. I think Qwave should have a feature to make a page ingested by i1.is servers. \
            Instead of companies training on stripped or obfuscated data, this allows people to instantly say: This is mine!";
        let res = soul.verify_work_similarity(stripped_excerpt);
        assert!(
            res.combined_q10 >= 700,
            "expected strong SoulSignature match (>=700), got {}",
            res.combined_q10
        );
        assert!(res.is_authentic_match);
    }

    #[test]
    fn original_author_revocation_overrides_reader_browsing_summary() {
        let soul = SoulSignature::mint("reader@8b.is", b"reader-key", SAMPLE_AUTHOR_TEXT);
        let policies = FieldPolicyTable::creator_default();

        // Permitted when original author has not revoked
        let deed_ok = I1IngestDeed::create(
            "https://8b.is/post/ai-provenance",
            SAMPLE_AUTHOR_TEXT,
            IngestMode::SummarizeFromBrowsing,
            "original_author@8b.is",
            false,
            &soul,
            &policies,
            false,
        );
        assert!(deed_ok.can_ingest_to_i1());

        // Automatically blocked when original author revokes permission
        let deed_revoked = I1IngestDeed::create(
            "https://8b.is/post/ai-provenance",
            SAMPLE_AUTHOR_TEXT,
            IngestMode::SummarizeFromBrowsing,
            "original_author@8b.is",
            true,
            &soul,
            &policies,
            false,
        );
        assert!(!deed_revoked.can_ingest_to_i1());
        assert_eq!(deed_revoked.deed_seal, 0);
    }

    #[test]
    fn local_ai_only_and_private_never_egress_to_i1() {
        let soul = SoulSignature::mint("hue@8b.is", b"key", SAMPLE_AUTHOR_TEXT);
        let policies = FieldPolicyTable::creator_default();

        let local_deed = I1IngestDeed::create(
            "https://8b.is/notes",
            SAMPLE_AUTHOR_TEXT,
            IngestMode::LocalAiOnly,
            "hue@8b.is",
            false,
            &soul,
            &policies,
            false,
        );
        assert!(!local_deed.can_ingest_to_i1());
        assert!(local_deed.mode.allows_local_ai());

        let priv_deed = I1IngestDeed::create(
            "https://8b.is/private",
            SAMPLE_AUTHOR_TEXT,
            IngestMode::NoArchivePrivate,
            "hue@8b.is",
            false,
            &soul,
            &policies,
            false,
        );
        assert!(!priv_deed.can_ingest_to_i1());
        assert!(!priv_deed.mode.allows_local_ai());
        assert!(priv_deed.scrubbed_content.is_empty());
    }

    #[test]
    fn personal_field_policies_scrub_private_fields_while_keeping_public_handles() {
        let mut table = FieldPolicyTable::creator_default();
        table.set_value(PersonalField::Username, "aye_hue");
        table.set_value(PersonalField::Website, "https://8b.is");
        table.set_value(PersonalField::XHandle, "@aye_is");
        table.set_value(PersonalField::RedditHandle, "u/aye_is");
        table.set_value(PersonalField::PhysicalAddress, "742 Evergreen Terrace");

        // By default: Username, Website, XHandle, RedditHandle are AlwaysAllow;
        // Email is AskEveryTime (redacted when unattended);
        // Phone is RequiredFormsOnly (redacted in AI);
        // PhysicalAddress is NeverStrip (always redacted).
        let raw = "Written by aye_hue (@aye_is, u/aye_is) at https://8b.is. \
                   Contact me at hue@8b.is or +1-555-867-5309 or 742 Evergreen Terrace.";
        let (scrubbed, count) = table.scrub_text_for_ai(raw, false);
        assert_eq!(count, 3);
        assert!(scrubbed.contains("aye_hue"));
        assert!(scrubbed.contains("@aye_is"));
        assert!(scrubbed.contains("u/aye_is"));
        assert!(scrubbed.contains("https://8b.is"));
        assert!(scrubbed.contains("[REDACTED:EMAIL]"));
        assert!(scrubbed.contains("[REDACTED:PHONE]"));
        assert!(scrubbed.contains("[REDACTED:ADDRESS]"));
        assert!(!scrubbed.contains("hue@8b.is"));
        assert!(!scrubbed.contains("555-867-5309"));
        assert!(!scrubbed.contains("742 Evergreen Terrace"));
    }
}
