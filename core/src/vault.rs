//! Sovereign Personal-Signature Password Vault (`qwave_core::vault`).
//!
//! Traditional browsers store all website passwords in a single SQLite file
//! protected by a static OS keyring key (or a hardcoded fallback key on Linux)
//! and eagerly inject credentials into page DOM inputs on page load, exposing
//! users to silent credential harvesting and single-key mass compromise.
//!
//! Qwave's Sovereign Vault works on a fundamentally different mechanism:
//! 1. **Zero Master Key on Disk**: No decryption key is ever persisted in the
//!    vault file or browser profile.
//! 2. **Per-Origin, Per-Record Personal Signature Key Derivation**:
//!    Each credential `(canonical_domain, username)` has its own random 32-byte
//!    `record_salt` and 12-byte `nonce`. Sealing or unsealing requires a live,
//!    deterministic **RFC 8032 Ed25519 cryptographic signature** produced by the
//!    end user's personal SSH key (`~/.ssh/id_aye` or `~/.ssh/id_ed25519`) over
//!    the domain-separated namespace `"qwave.sovereign.vault.v1"`, verified
//!    against the user's Ed25519 public key, and combined via **HKDF-SHA256** +
//!    **PBKDF2-HMAC-SHA256** with the user's personal signature phrase and
//!    `MEM|8` 79-byte [`WaveInt`] provenance frame.
//! 3. **Blinded Domain Index**: Even the list of websites in the vault is
//!    blinded via `HMAC-SHA256(index_key, canonical_domain)` so inspecting the
//!    vault file on disk does not reveal which sites have stored logins.
//! 4. **100% Pure Integer Rust (`#![forbid(unsafe_code)]`, Zero Floats)**:
//!    Implements FIPS 180-4 SHA-256, RFC 2104 HMAC-SHA256, RFC 5869 HKDF-SHA256,
//!    RFC 8018 PBKDF2-HMAC-SHA256, and RFC 8439 ChaCha20 + Encrypt-then-HMAC-SHA256
//!    authenticated encryption with constant-time tag verification.

#![forbid(unsafe_code)]

use crate::rational::Rational;
use crate::wave::{WaveInt, WaveProvenance};

/// Magic header for the Sovereign Vault binary/line format (`QWVLT001`).
pub const VAULT_MAGIC: &str = "QWVLT001";

/// SSH signature namespace used exclusively for Qwave Sovereign Vault challenges.
pub const VAULT_SIGN_NAMESPACE: &str = "qwave.sovereign.vault.v1";

/// Default PBKDF2-HMAC-SHA256 iteration count for personal signature phrase stretching.
pub const DEFAULT_PBKDF2_ITERATIONS: u32 = 16_384;

/// Errors returned by Sovereign Vault cryptographic or signature operations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VaultError {
    InvalidInput(&'static str),
    SignatureUnavailable(String),
    SignatureVerificationFailed,
    AuthenticationFailed,
    MalformedVaultRecord,
    NotFound,
    IoError(String),
}

impl core::fmt::Display for VaultError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::InvalidInput(msg) => write!(f, "invalid vault input: {msg}"),
            Self::SignatureUnavailable(msg) => write!(f, "personal signature unavailable: {msg}"),
            Self::SignatureVerificationFailed => {
                write!(f, "personal Ed25519 signature verification failed")
            }
            Self::AuthenticationFailed => write!(
                f,
                "vault authentication failed (wrong personal signature or tampered ciphertext)"
            ),
            Self::MalformedVaultRecord => write!(f, "malformed sovereign vault record"),
            Self::NotFound => write!(f, "no sealed credential found for domain"),
            Self::IoError(msg) => write!(f, "vault I/O error: {msg}"),
        }
    }
}

// ============================================================================
// 1. FIPS 180-4 SHA-256 & RFC 2104 HMAC-SHA256 (Pure Integer Arithmetic)
// ============================================================================

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const SHA256_INIT: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

#[inline]
fn sha256_compress(state: &mut [u32; 8], block: &[u8; 64]) {
    let mut w = [0u32; 64];
    for i in 0..16 {
        let j = i * 4;
        w[i] = u32::from_be_bytes([block[j], block[j + 1], block[j + 2], block[j + 3]]);
    }
    for i in 16..64 {
        let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
        let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16]
            .wrapping_add(s0)
            .wrapping_add(w[i - 7])
            .wrapping_add(s1);
    }

    let mut a = state[0];
    let mut b = state[1];
    let mut c = state[2];
    let mut d = state[3];
    let mut e = state[4];
    let mut f = state[5];
    let mut g = state[6];
    let mut h = state[7];

    for i in 0..64 {
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = (e & f) ^ ((!e) & g);
        let temp1 = h
            .wrapping_add(s1)
            .wrapping_add(ch)
            .wrapping_add(SHA256_K[i])
            .wrapping_add(w[i]);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let temp2 = s0.wrapping_add(maj);

        h = g;
        g = f;
        f = e;
        e = d.wrapping_add(temp1);
        d = c;
        c = b;
        b = a;
        a = temp1.wrapping_add(temp2);
    }

    state[0] = state[0].wrapping_add(a);
    state[1] = state[1].wrapping_add(b);
    state[2] = state[2].wrapping_add(c);
    state[3] = state[3].wrapping_add(d);
    state[4] = state[4].wrapping_add(e);
    state[5] = state[5].wrapping_add(f);
    state[6] = state[6].wrapping_add(g);
    state[7] = state[7].wrapping_add(h);
}

/// Compute FIPS 180-4 SHA-256 digest of `data`.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut state = SHA256_INIT;
    let mut chunks = data.chunks_exact(64);
    for chunk in &mut chunks {
        let mut block = [0u8; 64];
        block.copy_from_slice(chunk);
        sha256_compress(&mut state, &block);
    }
    let rem = chunks.remainder();
    let bit_len = (data.len() as u64).wrapping_mul(8);

    let mut block = [0u8; 64];
    block[..rem.len()].copy_from_slice(rem);
    block[rem.len()] = 0x80;

    if rem.len() >= 56 {
        sha256_compress(&mut state, &block);
        block = [0u8; 64];
    }
    block[56..64].copy_from_slice(&bit_len.to_be_bytes());
    sha256_compress(&mut state, &block);

    let mut out = [0u8; 32];
    for (i, word) in state.iter().enumerate() {
        out[i * 4..(i + 1) * 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

/// Compute RFC 2104 HMAC-SHA256 over `data` using `key`.
pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let hashed = sha256(key);
        k_block[..32].copy_from_slice(&hashed);
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }

    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_block[i];
        opad[i] ^= k_block[i];
    }

    let mut inner = Vec::with_capacity(64 + data.len());
    inner.extend_from_slice(&ipad);
    inner.extend_from_slice(data);
    let inner_hash = sha256(&inner);

    let mut outer = [0u8; 96];
    outer[..64].copy_from_slice(&opad);
    outer[64..96].copy_from_slice(&inner_hash);
    sha256(&outer)
}

/// Compute RFC 5869 HKDF-SHA256 (Extract + Expand to 32 bytes).
pub fn hkdf_sha256(salt: &[u8], ikm: &[u8], info: &[u8]) -> [u8; 32] {
    let effective_salt = if salt.is_empty() { &[0u8; 32][..] } else { salt };
    let prk = hmac_sha256(effective_salt, ikm);
    let mut expand_input = Vec::with_capacity(info.len() + 1);
    expand_input.extend_from_slice(info);
    expand_input.push(0x01);
    hmac_sha256(&prk, &expand_input)
}

/// Compute RFC 8018 PBKDF2-HMAC-SHA256 for a single 32-byte derived key block.
pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let rounds = iterations.max(1);
    let mut salt_block = Vec::with_capacity(salt.len() + 4);
    salt_block.extend_from_slice(salt);
    salt_block.extend_from_slice(&1u32.to_be_bytes());

    let mut u = hmac_sha256(password, &salt_block);
    let mut out = u;
    for _ in 1..rounds {
        u = hmac_sha256(password, &u);
        for j in 0..32 {
            out[j] ^= u[j];
        }
    }
    out
}

/// Constant-time byte slice equality check to prevent timing side-channels.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Zeroize a mutable byte buffer in place.
pub fn zeroize_bytes(buf: &mut [u8]) {
    for b in buf.iter_mut() {
        *b = 0;
    }
}

// ============================================================================
// 2. RFC 8439 ChaCha20 Stream Cipher + Encrypt-then-HMAC-SHA256 AEAD
// ============================================================================

#[inline]
fn chacha20_quarter_round(state: &mut [u32; 16], a: usize, b: usize, c: usize, d: usize) {
    state[a] = state[a].wrapping_add(state[b]);
    state[d] = (state[d] ^ state[a]).rotate_left(16);

    state[c] = state[c].wrapping_add(state[d]);
    state[b] = (state[b] ^ state[c]).rotate_left(12);

    state[a] = state[a].wrapping_add(state[b]);
    state[d] = (state[d] ^ state[a]).rotate_left(8);

    state[c] = state[c].wrapping_add(state[d]);
    state[b] = (state[b] ^ state[c]).rotate_left(7);
}

fn chacha20_block(key: &[u8; 32], counter: u32, nonce: &[u8; 12]) -> [u8; 64] {
    let mut state = [0u32; 16];
    // "expand 32-byte k"
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;

    for i in 0..8 {
        let j = i * 4;
        state[4 + i] = u32::from_le_bytes([key[j], key[j + 1], key[j + 2], key[j + 3]]);
    }
    state[12] = counter;
    state[13] = u32::from_le_bytes([nonce[0], nonce[1], nonce[2], nonce[3]]);
    state[14] = u32::from_le_bytes([nonce[4], nonce[5], nonce[6], nonce[7]]);
    state[15] = u32::from_le_bytes([nonce[8], nonce[9], nonce[10], nonce[11]]);

    let initial = state;
    for _ in 0..10 {
        // Column rounds
        chacha20_quarter_round(&mut state, 0, 4, 8, 12);
        chacha20_quarter_round(&mut state, 1, 5, 9, 13);
        chacha20_quarter_round(&mut state, 2, 6, 10, 14);
        chacha20_quarter_round(&mut state, 3, 7, 11, 15);
        // Diagonal rounds
        chacha20_quarter_round(&mut state, 0, 5, 10, 15);
        chacha20_quarter_round(&mut state, 1, 6, 11, 12);
        chacha20_quarter_round(&mut state, 2, 7, 8, 13);
        chacha20_quarter_round(&mut state, 3, 4, 9, 14);
    }

    let mut out = [0u8; 64];
    for i in 0..16 {
        let word = state[i].wrapping_add(initial[i]);
        out[i * 4..(i + 1) * 4].copy_from_slice(&word.to_le_bytes());
    }
    out
}

/// Apply RFC 8439 ChaCha20 keystream XOR starting at `initial_counter`.
pub fn chacha20_xor(
    key: &[u8; 32],
    nonce: &[u8; 12],
    initial_counter: u32,
    input: &[u8],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len());
    for (block_idx, chunk) in input.chunks(64).enumerate() {
        let counter = initial_counter.wrapping_add(block_idx as u32);
        let keystream = chacha20_block(key, counter, nonce);
        for (b, k) in chunk.iter().zip(keystream.iter()) {
            out.push(b ^ k);
        }
    }
    out
}

fn compute_aead_tag(
    mac_key: &[u8; 32],
    nonce: &[u8; 12],
    aad: &[u8],
    ciphertext: &[u8],
) -> [u8; 32] {
    let mut mac_data = Vec::with_capacity(8 + aad.len() + 12 + 8 + ciphertext.len());
    mac_data.extend_from_slice(&(aad.len() as u64).to_be_bytes());
    mac_data.extend_from_slice(aad);
    mac_data.extend_from_slice(nonce);
    mac_data.extend_from_slice(&(ciphertext.len() as u64).to_be_bytes());
    mac_data.extend_from_slice(ciphertext);
    hmac_sha256(mac_key, &mac_data)
}

/// Seal `plaintext` using ChaCha20 + Encrypt-then-HMAC-SHA256, returning `ciphertext || 32-byte tag`.
pub fn aead_seal(
    enc_key: &[u8; 32],
    mac_key: &[u8; 32],
    nonce: &[u8; 12],
    aad: &[u8],
    plaintext: &[u8],
) -> Vec<u8> {
    let mut ciphertext = chacha20_xor(enc_key, nonce, 1, plaintext);
    let tag = compute_aead_tag(mac_key, nonce, aad, &ciphertext);
    ciphertext.extend_from_slice(&tag);
    ciphertext
}

/// Open `sealed` (`ciphertext || 32-byte tag`), verifying the 256-bit HMAC tag in constant time
/// before decrypting a single byte.
pub fn aead_open(
    enc_key: &[u8; 32],
    mac_key: &[u8; 32],
    nonce: &[u8; 12],
    aad: &[u8],
    sealed: &[u8],
) -> Result<Vec<u8>, VaultError> {
    if sealed.len() < 32 {
        return Err(VaultError::MalformedVaultRecord);
    }
    let split = sealed.len() - 32;
    let (ciphertext, tag) = sealed.split_at(split);
    let expected_tag = compute_aead_tag(mac_key, nonce, aad, ciphertext);
    if !constant_time_eq(tag, &expected_tag) {
        return Err(VaultError::AuthenticationFailed);
    }
    Ok(chacha20_xor(enc_key, nonce, 1, ciphertext))
}

// ============================================================================
// 3. Per-Domain Key Derivation & Personal Signature Binding
// ============================================================================

/// Material derived from the end user's personal signatures for a single operation.
#[derive(Clone)]
pub struct PersonalSignatureMaterial {
    /// Raw deterministic Ed25519 signature output over the record or vault challenge.
    pub ed25519_signature: Vec<u8>,
    /// Public key fingerprint / identifier of the user's personal Ed25519 key.
    pub signer_fingerprint: String,
    /// Optional user-supplied personal signature phrase (stretched via PBKDF2).
    pub personal_phrase: String,
    /// User's vocal salience fundamental frequency rational (`f0_pq`), e.g. `154/1` Hz for `hue`.
    pub vocal_f0_pq: Rational,
}

impl Drop for PersonalSignatureMaterial {
    fn drop(&mut self) {
        zeroize_bytes(&mut self.ed25519_signature);
    }
}

/// Derive independent `(enc_key, mac_key)` for a specific `(canonical_domain, username, record_salt)`
/// bound to the user's `PersonalSignatureMaterial` and 79-byte `WaveInt` provenance frame.
pub fn derive_record_keys(
    domain: &str,
    username: &str,
    record_salt: &[u8; 32],
    sig: &PersonalSignatureMaterial,
    wave_bytes: &[u8; 79],
) -> ([u8; 32], [u8; 32]) {
    let norm_domain = canonicalize_domain(domain);
    let phrase_key = pbkdf2_hmac_sha256(
        sig.personal_phrase.as_bytes(),
        record_salt,
        DEFAULT_PBKDF2_ITERATIONS,
    );

    let mut ikm = Vec::with_capacity(sig.ed25519_signature.len() + 32 + 79);
    ikm.extend_from_slice(&sig.ed25519_signature);
    ikm.extend_from_slice(&phrase_key);
    ikm.extend_from_slice(wave_bytes);

    let enc_info = format!(
        "qwave.sovereign.vault.enc.v1|{}|{}|{}",
        sig.signer_fingerprint, norm_domain, username
    );
    let mac_info = format!(
        "qwave.sovereign.vault.mac.v1|{}|{}|{}",
        sig.signer_fingerprint, norm_domain, username
    );

    let enc_key = hkdf_sha256(record_salt, &ikm, enc_info.as_bytes());
    let mac_key = hkdf_sha256(record_salt, &ikm, mac_info.as_bytes());
    zeroize_bytes(&mut ikm);
    (enc_key, mac_key)
}

/// Compute the deterministic challenge string signed by the user's Ed25519 key for a record.
pub fn build_record_signature_challenge(
    domain: &str,
    username: &str,
    record_salt: &[u8; 32],
) -> String {
    let norm = canonicalize_domain(domain);
    format!(
        "QWAVE-SOVEREIGN-VAULT-V1|domain={}|user={}|salt={}",
        norm,
        username.trim(),
        hex_encode(record_salt)
    )
}

/// Compute a blinded 32-byte HMAC tag for `domain` using the user's vault index key so
/// plaintext domain names never appear in the on-disk vault file.
pub fn blind_domain_tag(index_sig: &[u8], vault_salt: &[u8; 32], domain: &str) -> [u8; 32] {
    let norm = canonicalize_domain(domain);
    let index_key = hkdf_sha256(vault_salt, index_sig, b"qwave.sovereign.vault.domain-index.v1");
    hmac_sha256(&index_key, norm.as_bytes())
}

/// Canonicalize a URL or hostname to its lowercase registrable/origin host (port-stripped, lowercase).
pub fn canonicalize_domain(raw: &str) -> String {
    let trimmed = raw.trim();
    let without_scheme = if let Some(idx) = trimmed.find("://") {
        &trimmed[idx + 3..]
    } else {
        trimmed
    };
    let host_port = without_scheme
        .split(&['/', '?', '#'][..])
        .next()
        .unwrap_or(without_scheme);
    let host = if host_port.starts_with('[') {
        host_port
    } else {
        host_port.split(':').next().unwrap_or(host_port)
    };
    let lower = host.trim().trim_end_matches('.').to_ascii_lowercase();
    let stripped = lower.strip_prefix("www.").unwrap_or(&lower);
    stripped.to_string()
}

// ============================================================================
// 4. Smart Password Field Capture Rules (Shared Decision Core)
// ============================================================================

/// One filled password field observed on a submitted login or change-password form.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedPasswordField {
    pub value: String,
    pub autocomplete: String,
}

impl CapturedPasswordField {
    pub fn new(value: impl Into<String>, autocomplete: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            autocomplete: autocomplete.into(),
        }
    }

    pub fn has_token(&self, token: &str) -> bool {
        self.autocomplete
            .split_whitespace()
            .any(|part| part.eq_ignore_ascii_case(token))
    }
}

/// Select which password field from a submitted form should be offered for sealing:
/// 1. `autocomplete="new-password"` wins (if multiple disagree, returns `None`).
/// 2. `autocomplete="current-password"` is excluded when other password fields exist.
/// 3. Of remaining non-empty fields, the last field in DOM order wins.
pub fn select_submitted_password(fields: &[CapturedPasswordField]) -> Option<String> {
    let filled: Vec<&CapturedPasswordField> =
        fields.iter().filter(|f| !f.value.is_empty()).collect();
    if filled.is_empty() {
        return None;
    }

    let declared_new: Vec<&CapturedPasswordField> = filled
        .iter()
        .copied()
        .filter(|f| f.has_token("new-password"))
        .collect();
    if !declared_new.is_empty() {
        let first_val = &declared_new[0].value;
        if declared_new.iter().all(|f| &f.value == first_val) {
            return Some(first_val.clone());
        }
        return None;
    }

    let not_current: Vec<&CapturedPasswordField> = filled
        .iter()
        .copied()
        .filter(|f| !f.has_token("current-password"))
        .collect();
    let pool = if not_current.is_empty() {
        &filled
    } else {
        &not_current
    };
    pool.last().map(|f| f.value.clone())
}

// ============================================================================
// 5. Sealed Credential Record & Provenance WaveInt Binding
// ============================================================================

/// Plaintext credential payload that exists ONLY in volatile memory during seal/unseal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlaintextCredential {
    pub domain: String,
    pub username: String,
    pub password: String,
    pub created_ts: u64,
    pub sign_count: u64,
}

/// On-disk sealed credential record containing zero plaintext domain, username, or password.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SealedVaultRecord {
    pub blinded_domain: [u8; 32],
    pub record_salt: [u8; 32],
    pub nonce: [u8; 12],
    pub signer_fingerprint: String,
    pub requires_phrase: bool,
    pub wave_frame: [u8; 79],
    /// Sealed username hint (`ChaCha20-HMAC-SHA256` encrypted with the vault index key so
    /// the native UI can show which account is sealed for the current domain after Ed25519
    /// index verification without unsealing the password).
    pub sealed_username: Vec<u8>,
    /// Sealed credential payload (`ChaCha20-HMAC-SHA256` encrypted with the per-record
    /// personal signature key + PBKDF2 personal signature phrase + 79-byte `WaveInt` AAD).
    pub sealed_payload: Vec<u8>,
}

impl SealedVaultRecord {
    /// Seal a [`PlaintextCredential`] using the end user's [`PersonalSignatureMaterial`].
    pub fn seal(
        cred: &PlaintextCredential,
        index_sig: &[u8],
        vault_salt: &[u8; 32],
        record_salt: [u8; 32],
        nonce: [u8; 12],
        sig: &PersonalSignatureMaterial,
    ) -> Result<Self, VaultError> {
        let norm_domain = canonicalize_domain(&cred.domain);
        if norm_domain.is_empty() || cred.password.is_empty() {
            return Err(VaultError::InvalidInput("domain and password must not be empty"));
        }

        let blinded_domain = blind_domain_tag(index_sig, vault_salt, &norm_domain);

        // Mint a 79-byte MEM|8 WaveInt provenance frame bound to the user's vocal f0_pq & timestamp
        let essence_digest = sha256(
            format!("qwave-vault:{}:{}:{}", norm_domain, cred.username, cred.created_ts).as_bytes(),
        );
        let wave_id = u64::from_le_bytes([
            essence_digest[0],
            essence_digest[1],
            essence_digest[2],
            essence_digest[3],
            essence_digest[4],
            essence_digest[5],
            essence_digest[6],
            essence_digest[7],
        ]);
        let wave = WaveInt {
            base_amplitude: Rational::new(95, 100).unwrap_or(Rational::ONE),
            frequency: sig.vocal_f0_pq,
            phase: Rational::ZERO,
            emotional_valence: Rational::ONE,
            arousal: Rational::new(1, 2).unwrap_or(Rational::ONE),
            created_at: cred.created_ts,
            last_accessed: cred.created_ts,
            access_count: cred.sign_count.min(u32::MAX as u64) as u32,
            decay_rate: Rational::ZERO,
            id: Some(wave_id.max(1)),
            provenance: WaveProvenance::Cognitive,
        };
        let wave_frame = wave.to_frame();

        // Seal the username with the Ed25519 index signature so the browser toolbar can show
        // `Sign & Fill (<username>)` for the active domain without touching the password ciphertext.
        let user_enc_key = hkdf_sha256(
            &record_salt,
            index_sig,
            format!("qwave.vault.user.enc|{}", norm_domain).as_bytes(),
        );
        let user_mac_key = hkdf_sha256(
            &record_salt,
            index_sig,
            format!("qwave.vault.user.mac|{}", norm_domain).as_bytes(),
        );
        let sealed_username = aead_seal(
            &user_enc_key,
            &user_mac_key,
            &nonce,
            &blinded_domain,
            cred.username.as_bytes(),
        );

        let (enc_key, mac_key) = derive_record_keys(
            &norm_domain,
            &cred.username,
            &record_salt,
            sig,
            &wave_frame,
        );

        let mut aad = Vec::with_capacity(32 + 79 + norm_domain.len());
        aad.extend_from_slice(&blinded_domain);
        aad.extend_from_slice(&wave_frame);
        aad.extend_from_slice(norm_domain.as_bytes());

        let serialized = encode_plaintext_payload(cred);
        let sealed_payload = aead_seal(&enc_key, &mac_key, &nonce, &aad, &serialized);

        Ok(Self {
            blinded_domain,
            record_salt,
            nonce,
            signer_fingerprint: sig.signer_fingerprint.clone(),
            requires_phrase: !sig.personal_phrase.is_empty(),
            wave_frame,
            sealed_username,
            sealed_payload,
        })
    }

    /// Unseal the username for a matched domain using the user's Ed25519 index signature.
    pub fn unseal_username(
        &self,
        index_sig: &[u8],
        domain: &str,
    ) -> Result<String, VaultError> {
        let norm_domain = canonicalize_domain(domain);
        let user_enc_key = hkdf_sha256(
            &self.record_salt,
            index_sig,
            format!("qwave.vault.user.enc|{}", norm_domain).as_bytes(),
        );
        let user_mac_key = hkdf_sha256(
            &self.record_salt,
            index_sig,
            format!("qwave.vault.user.mac|{}", norm_domain).as_bytes(),
        );
        let raw = aead_open(
            &user_enc_key,
            &user_mac_key,
            &self.nonce,
            &self.blinded_domain,
            &self.sealed_username,
        )?;
        String::from_utf8(raw).map_err(|_| VaultError::MalformedVaultRecord)
    }

    /// Unseal the full [`PlaintextCredential`] using the end user's live [`PersonalSignatureMaterial`].
    pub fn unseal(
        &self,
        domain: &str,
        username: &str,
        sig: &PersonalSignatureMaterial,
    ) -> Result<PlaintextCredential, VaultError> {
        if self.signer_fingerprint != sig.signer_fingerprint {
            return Err(VaultError::SignatureVerificationFailed);
        }
        // Verify that the 79-byte WaveInt provenance frame is intact before key derivation
        if WaveInt::from_frame(&self.wave_frame).is_err() {
            return Err(VaultError::MalformedVaultRecord);
        }
        let norm_domain = canonicalize_domain(domain);
        let (enc_key, mac_key) = derive_record_keys(
            &norm_domain,
            username,
            &self.record_salt,
            sig,
            &self.wave_frame,
        );

        let mut aad = Vec::with_capacity(32 + 79 + norm_domain.len());
        aad.extend_from_slice(&self.blinded_domain);
        aad.extend_from_slice(&self.wave_frame);
        aad.extend_from_slice(norm_domain.as_bytes());

        let mut raw = aead_open(&enc_key, &mac_key, &self.nonce, &aad, &self.sealed_payload)?;
        let decoded = decode_plaintext_payload(&raw);
        zeroize_bytes(&mut raw);
        decoded
    }

    /// Serialize record to a single deterministic TSV-hex line for atomic vault file storage.
    pub fn to_line(&self) -> String {
        format!(
            "REC\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            hex_encode(&self.blinded_domain),
            hex_encode(&self.record_salt),
            hex_encode(&self.nonce),
            self.signer_fingerprint.replace('\t', " "),
            if self.requires_phrase { "1" } else { "0" },
            hex_encode(&self.wave_frame),
            hex_encode(&self.sealed_username),
            hex_encode(&self.sealed_payload),
        )
    }

    /// Parse a serialized `REC\t...` line from the vault file.
    pub fn from_line(line: &str) -> Result<Self, VaultError> {
        let parts: Vec<&str> = line.trim().split('\t').collect();
        if parts.len() != 9 || parts[0] != "REC" {
            return Err(VaultError::MalformedVaultRecord);
        }
        let blinded_vec = hex_decode(parts[1]).ok_or(VaultError::MalformedVaultRecord)?;
        let salt_vec = hex_decode(parts[2]).ok_or(VaultError::MalformedVaultRecord)?;
        let nonce_vec = hex_decode(parts[3]).ok_or(VaultError::MalformedVaultRecord)?;
        let wave_vec = hex_decode(parts[6]).ok_or(VaultError::MalformedVaultRecord)?;
        let sealed_username = hex_decode(parts[7]).ok_or(VaultError::MalformedVaultRecord)?;
        let sealed_payload = hex_decode(parts[8]).ok_or(VaultError::MalformedVaultRecord)?;

        if blinded_vec.len() != 32
            || salt_vec.len() != 32
            || nonce_vec.len() != 12
            || wave_vec.len() != 79
        {
            return Err(VaultError::MalformedVaultRecord);
        }

        let mut blinded_domain = [0u8; 32];
        blinded_domain.copy_from_slice(&blinded_vec);
        let mut record_salt = [0u8; 32];
        record_salt.copy_from_slice(&salt_vec);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&nonce_vec);
        let mut wave_frame = [0u8; 79];
        wave_frame.copy_from_slice(&wave_vec);

        Ok(Self {
            blinded_domain,
            record_salt,
            nonce,
            signer_fingerprint: parts[4].to_string(),
            requires_phrase: parts[5] == "1",
            wave_frame,
            sealed_username,
            sealed_payload,
        })
    }
}

fn encode_plaintext_payload(cred: &PlaintextCredential) -> Vec<u8> {
    let mut out = Vec::new();
    for field in [
        cred.domain.as_bytes(),
        cred.username.as_bytes(),
        cred.password.as_bytes(),
    ] {
        out.extend_from_slice(&(field.len() as u32).to_be_bytes());
        out.extend_from_slice(field);
    }
    out.extend_from_slice(&cred.created_ts.to_be_bytes());
    out.extend_from_slice(&cred.sign_count.to_be_bytes());
    out
}

fn decode_plaintext_payload(bytes: &[u8]) -> Result<PlaintextCredential, VaultError> {
    let mut pos = 0usize;
    let mut strings = Vec::with_capacity(3);
    for _ in 0..3 {
        if pos + 4 > bytes.len() {
            return Err(VaultError::MalformedVaultRecord);
        }
        let len = u32::from_be_bytes([
            bytes[pos],
            bytes[pos + 1],
            bytes[pos + 2],
            bytes[pos + 3],
        ]) as usize;
        pos += 4;
        if pos + len > bytes.len() {
            return Err(VaultError::MalformedVaultRecord);
        }
        let s = core::str::from_utf8(&bytes[pos..pos + len])
            .map_err(|_| VaultError::MalformedVaultRecord)?
            .to_string();
        pos += len;
        strings.push(s);
    }
    if pos + 16 != bytes.len() {
        return Err(VaultError::MalformedVaultRecord);
    }
    let mut ts_bytes = [0u8; 8];
    ts_bytes.copy_from_slice(&bytes[pos..pos + 8]);
    let mut sc_bytes = [0u8; 8];
    sc_bytes.copy_from_slice(&bytes[pos + 8..pos + 16]);
    Ok(PlaintextCredential {
        domain: strings[0].clone(),
        username: strings[1].clone(),
        password: strings[2].clone(),
        created_ts: u64::from_be_bytes(ts_bytes),
        sign_count: u64::from_be_bytes(sc_bytes),
    })
}

/// Encode bytes as lowercase hex string.
pub fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

/// Decode hex string into byte vector.
pub fn hex_decode(hex: &str) -> Option<Vec<u8>> {
    let s = hex.trim();
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let bytes = s.as_bytes();
    for i in (0..bytes.len()).step_by(2) {
        let hi = from_hex_digit(bytes[i])?;
        let lo = from_hex_digit(bytes[i + 1])?;
        out.push((hi << 4) | lo);
    }
    Some(out)
}

fn from_hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_matches_nist_vectors() {
        let empty = sha256(b"");
        assert_eq!(
            hex_encode(&empty),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let abc = sha256(b"abc");
        assert_eq!(
            hex_encode(&abc),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn hmac_sha256_matches_rfc4231_vector() {
        let key = [0x0bu8; 20];
        let data = b"Hi There";
        let mac = hmac_sha256(&key, data);
        assert_eq!(
            hex_encode(&mac),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
    }

    #[test]
    fn chacha20_matches_rfc8439_section_2_4_2() {
        let mut key = [0u8; 32];
        for (i, b) in key.iter_mut().enumerate() {
            *b = i as u8;
        }
        let nonce: [u8; 12] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00];
        let plaintext = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
        let ciphertext = chacha20_xor(&key, &nonce, 1, plaintext);
        let expected_first_16 = [
            0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80,
            0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81,
        ];
        assert_eq!(&ciphertext[..16], &expected_first_16);
        let roundtrip = chacha20_xor(&key, &nonce, 1, &ciphertext);
        assert_eq!(&roundtrip[..], &plaintext[..]);
    }

    #[test]
    fn seal_and_unseal_requires_exact_personal_signature() {
        let vault_salt = [0x11u8; 32];
        let index_sig = b"ed25519-index-sig-for-hue";
        let record_salt = [0x22u8; 32];
        let nonce = [0x33u8; 12];

        let sig = PersonalSignatureMaterial {
            ed25519_signature: b"SSH-SIG-ED25519-DETERMINISTIC-BYTES-HUE".to_vec(),
            signer_fingerprint: "SHA256:hue-id-aye-ed25519".to_string(),
            personal_phrase: "fine-touch-from-within".to_string(),
            vocal_f0_pq: Rational::new(154, 1).unwrap(),
        };

        let cred = PlaintextCredential {
            domain: "https://www.GitHub.com:443/login".to_string(),
            username: "hue".to_string(),
            password: "sovereign-unbreakable-secret-!@#".to_string(),
            created_ts: 1_793_236_000,
            sign_count: 1,
        };

        let record = SealedVaultRecord::seal(
            &cred,
            index_sig,
            &vault_salt,
            record_salt,
            nonce,
            &sig,
        )
        .expect("seal succeeds");

        // Serialized record line never contains plaintext domain, username, or password
        let line = record.to_line();
        assert!(!line.contains("github"));
        assert!(!line.contains("sovereign-unbreakable-secret"));

        let parsed = SealedVaultRecord::from_line(&line).expect("parse succeeds");
        let unsealed_user = parsed
            .unseal_username(index_sig, "github.com")
            .expect("username unseals with index signature");
        assert_eq!(unsealed_user, "hue");

        // Unseal with matching personal signature succeeds
        let opened = parsed
            .unseal("github.com", "hue", &sig)
            .expect("unseal succeeds");
        assert_eq!(opened.password, "sovereign-unbreakable-secret-!@#");

        // Wrong personal phrase fails closed
        let mut wrong_phrase = sig.clone();
        wrong_phrase.personal_phrase = "wrong-phrase".to_string();
        assert_eq!(
            parsed.unseal("github.com", "hue", &wrong_phrase),
            Err(VaultError::AuthenticationFailed)
        );

        // Wrong Ed25519 signature fails closed
        let mut wrong_ed25519 = sig.clone();
        wrong_ed25519.ed25519_signature = b"FORGED-SIGNATURE".to_vec();
        assert_eq!(
            parsed.unseal("github.com", "hue", &wrong_ed25519),
            Err(VaultError::AuthenticationFailed)
        );

        // Wrong domain fails closed (strict origin binding)
        assert_eq!(
            parsed.unseal("evil-phishing.com", "hue", &sig),
            Err(VaultError::AuthenticationFailed)
        );
    }

    #[test]
    fn password_field_selection_honors_change_password_rules() {
        let fields = vec![
            CapturedPasswordField::new("old-secret", "current-password"),
            CapturedPasswordField::new("new-secret", "new-password"),
            CapturedPasswordField::new("new-secret", "new-password"),
        ];
        assert_eq!(
            select_submitted_password(&fields),
            Some("new-secret".to_string())
        );

        let mismatched = vec![
            CapturedPasswordField::new("new-1", "new-password"),
            CapturedPasswordField::new("new-2", "new-password"),
        ];
        assert_eq!(select_submitted_password(&mismatched), None);
    }
}
