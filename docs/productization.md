# Qwave — productization: brainstorm · plan · spec

> **Status:** draft for review. Nothing here is committed policy. Pricing and
> go-to-market are proposals, not promises.
> **Premise:** Qwave is MIT and stays MIT. You cannot paywall privacy — so we
> don't. The subscription buys the *constellation around the browser*:
> bleeding-edge builds, the academy, the badges, the weekly hub.

---

## 0. The one rule

**Privacy is free, forever.** The MIT browser, the Rust core, the egress
allowlist, the source — all of it. The subscription sells *what a solo
maintainer cannot give away for free*: early access to unstable work, a place
to learn, a place to meet, and the badge that says you stood with it.
*(`sharing is caring` is not a slogan; it is the license.)*

Anything that would degrade the free browser to sell the paid one is out of
scope by construction.

---

## 1. Brainstorm (raw signal → shape)

**What people already ask for** (patterns worth selling):
- "Give me the *nightly* — every experimental WebKit flag ON, ZIG lane, the
  superpowers." → **bleeding-edge access**.
- "Show me how you built the blocklist / the crypto review / the MEM8 core."
  → **the academy**.
- "Where is everyone?" → **the hub**.
- "How do I prove *my* build is the one you shipped?" → **verifiable badges**.

**The honest tension.** A privacy browser has a trust surface you can lose by
monetizing badly. Three temptations to refuse:
1. *Paywall the privacy.* No. (MIT core.)
2. *Telemetry for "improvement".* No. (The whole point is `prove what it
   sends`.)
3. *Venture-shaped growth at any cost.* No. (The constellation is a cottage,
   not a unicorn — see `lovetta` patron lane.)

**The shape that survives all three:** open core + a *membership* that funds the
near-field work (mostly the M1 and one human) and returns value as community,
curriculum, and early access — never as withheld safety.

---

## 2. Positioning

| | |
|---|---|
| **Category** | WebKit-native, privacy-auditable browser + a sovereign-tools community |
| **Wedge** | *prove what it sends* — the egress allowlist is readable, testable, and small |
| **Who pays** | people who already care (tinkerers, OSS maintainers, privacy folk, the 8b-is constellation itself) |
| **Why they pay** | early builds, the academy, the meeting, the badge — and because they want the project to exist |
| **Non-customer** | anyone expecting a free Chrome clone with a paid skin |

The line that goes on the pricing page: **"The browser is free because privacy
must be. The membership is for everything around it — and for keeping the
lights on."**

---

## 3. Tiers

Small, honest numbers. Currency EUR; annual = 10× monthly (two months free).

| Tier | Price | Gets |
|---|---|---|
| **Free** | €0 | the full browser (MIT), stable channel, docs, the library, the hub read-only |
| **Supporter** | **€4.20 / mo** | nightly + beta builds (early + supported — see 5.2), the academy, badge, weekly hub meeting, hub-write |
| **Patron** | **€12 / mo** | everything + name in `PATRONS.md`, quarterly office hours with the maintainer, vote on the roadmap |
| **Team / Institutional** | €42 / mo (5 seats) | everything + private onboarding, priority in the meeting, "supporter of record" badge |
| **One-off** | pay-what-you-want | the badge, one month of nightly — no lock-in, no shame |

**Why €4.20?** it already means "Pro" in the constellation (`qUltraKotoro`). One
number, one meaning, everywhere.

**Distribution/rails already in the house:** GitHub Sponsors, `store.vaked.dev`
(prints/vinyl), `lovetta.vaked.dev` (patron lane), Revolut/Wise links in the
footer. The subscription is a *membership object*, not a checkout page — it can
live behind any of them.

---

## 4. What the paid side actually is

### 4.1 Bleeding-edge lane (features)
The subscription unlocks the *unstable* channel. Concretely, from the repo's own
backlog (`ROADMAP_AUDIT.md`, `docs/superpowers`, `ZIG_INTEGRATION.md`):

| Feature | State | Gate |
|---|---|---|
| **Nightly channel** (all experimental WebKit flags ON) | exists (two lanes) | Supporter — early + supported, not exclusive (5.2) |
| **superpowers** (the `docs/superpowers` specs) | planned | Supporter (beta) |
| **ZIG lane** (`ZIG_INTEGRATION.md`) | scoped | Supporter (alpha) |
| **Beta model / features you can try first** | ongoing | Supporter |
| **Stable channel** | ships | **everyone, free** |

**Out of scope — no VPN.** The WireGuard/VPN stack (PacketTunnel, WireGuardKit +
Go bridge, Zig packet filter, VPNKit, PostQuantum) is not in-tree and does not
belong on this roadmap. Per `AGENTS.md` rule 4 it returns, if it ever returns, as
its own package/repo — and that separate product owns its own distribution and
membership. Nothing in the membership spine depends on it.

Rule: **beta never replaces stable, and never removes a free feature.** Paid
users get *earlier*, not *more privacy*.

### 4.2 Academy
A curriculum from the constellation's own receipts, free to read, guided for
members:
- *Build your own blocklist* (from `BLOCKLIST.md`).
- *Reading a binary: the crypto review* (`CRYPTO_REVIEW.md`).
- *The MEM8 core in one sitting* (`ARCHITECTURE.md`, `constellation.md`).
- *The egress allowlist — prove what it sends* (`NETWORK.md`).
- *One man, end to end* (the studio/pipeline as a worked example).
Format: `docs/` (free) + monthly live walkthrough + graded exercises (members).

### 4.3 Badges (8b-is)
Verifiable, not decorative. A badge is a signed artifact the member can show:
```
badge = { id, member_hash, tier, since, sig }   # Ed25519, pinned pubkey
```
- Shown in the hub, optionally in the member's GitHub README.
- **Verifiable**: anyone can check the signature against the constellation's
  pinned public key — *prove it, don't assert it*, extended to belonging.
- Reuses `sphered`'s spine: `#Commit = #ValidWitness` — a badge without a
  witness is refused.

### 4.4 Weekly Community Hub Meeting
- **Cadence:** weekly, 40 min, one fixed slot (published).
- **Shape:** 5′ standup (what changed) · 10′ demo (one bleeding-edge feature,
  live) · 15′ open floor · 5′ academy Q&A · 5′ the ledger (who shipped what).
- **Artifact:** every meeting produces a note (`docs/hub/YYYY-MM-DD.md`) with
  the decisions; the note is the witness.

### 4.5 The hub — Discord *now*, sovereign *later*
**Decision: Discord is the venue, not the identity.** Members authenticate via
the membership (not via Discord), so the community survives a venue change.
- **Phase 1 — Discord:** fastest to run; the studio already speaks it
  (`wa_stream.py` bridges the `UltraCrushLove<3` surface).
- **Phase 2 — sovereign hub:** `etherhive.vaked.dev` (swarm memory) or a Matrix
  bridge; Discord becomes a *door*, not the room.
- **Bridge:** one bot that mirrors the weekly note, the badges, and the
  nightly-channel status; announced from `koan.vaked.dev` (the doors).
- **Non-negotiable:** no member data leaves the browser/constellation; the bot
  holds minimal state (member_hash → tier → badge).

---

## 5. Product spec (concrete)

### 5.1 Entitlement model
```jsonc
// membership.json — the single source of truth, signed
{
  "member_hash": "sha256:…",        // never an email
  "tier": "supporter|patron|team",
  "since": "2026-10-10",
  "until": "2026-11-10",
  "channels": ["nightly", "beta"],  // what the key unlocks
  "badge_sig": "ed25519:…",
  "verified_at": "2026-10-10T…Z"
}
```
- The app holds only the **signed badge**; verification is offline (pinned key).
- **No account, no email, no telemetry** — checkout hands back a signed token.

### 5.2 Channel gating (in-app) — and what it can honestly enforce
- `stable` → everyone.
- `nightly` / `beta` → badge present **and** unexpired; otherwise a plain,
  non-nagging link to membership.
- Never a countdown, never a blur. A one-line reason: *"nightly is a member
  channel — stable is yours, free."*

**The limit, stated up front.** That check is a *convenience, not a lock*.
`scripts/release-nightly.sh` publishes the same unsigned nightly to the public
`nightly` prerelease, and the channel is selected from `QWAVE_CHANNEL` (env or
bundle) — so anyone can download or build nightly and turn it on without a
token. This tier therefore must not be sold as exclusive access.

What is actually enforced is **distribution and support**, not runtime:

| Enforceable | Not enforceable |
|---|---|
| the signed artifacts and release notes we publish and stand behind | the code itself — the repo is open and builds |
| the supported build for your machine, with a fix path | hiding the nightly binary |
| early notification, and the hub lane where changes are discussed | blocking `QWAVE_CHANNEL=nightly` |

If exclusivity is ever required, it needs a restricted distribution and
authorization design first (private artifacts + entitlement to fetch). That is a
deliberate product decision, not a badge check.

### 5.3 Hub bot (minimal surface)
Commands: `!badge` (show/verify), `!nightly` (channel status), `!meet` (next
meeting), `!ledger` (this week's shipped). Everything else is human.

### 5.4 Academy plumbing
`docs/academy/<slug>.md` (free) + a members-only live session note + exercises.
Reuses the sovereign-library build (`pocoo.vaked.dev/docs`) — content lives once.

### 5.5 Metrics that respect the rule
Measure **value returned**, not people surveilled: nightly downloads (opt-in
count), meeting attendance, badge verifications, academy completions, churn
reason (asked, never tracked). **No per-user analytics. Ever.**

---

## 6. Plan (phases)

| Phase | Window | Ships | Done when |
|---|---|---|---|
| **P0 — decide** | 1 week | this doc reviewed; tier prices frozen; rails picked | one page published, linked from `koan.vaked.dev` |
| **P1 — membership spine** | 2–3 weeks | signed badge + offline verify + channel gating; PATRONS.md | a paying member gets a supported nightly with notes; a non-member can still build nightly — the gate is support, not secrecy (5.2) |
| **P2 — the room** | 3–4 weeks | hub bot + weekly cadence + first meeting note | two consecutive weekly notes exist |
| **P3 — the academy** | 4–6 weeks | 5 lessons from existing docs + first live walkthrough | one member completes the track |
| **P4 — sovereign hub** | 6–12 weeks | Matrix/etherhive bridge; Discord demoted to a door | members can move venues without losing identity |
| **P5 — institutional** | ongoing | team tier, onboarding, "supporter of record" | first team seat |

**Sequencing rule:** never ship P1's nag before P2's welcome. The gate and the
room arrive together.

---

## 7. Risks & refusals

| Risk | The refusal |
|---|---|
| Fork of the MIT core, paid features stripped | the paid thing is *the community + early builds*, not code you can copy — and the free browser is whole |
| "paying for privacy" optics | privacy is free; the page says so in the first line |
| Discord lock-in | members authenticate off-platform; Phase 4 moves the room |
| Maintainer burnout is the real bottleneck | the money buys *time*, and the meeting is capped at 40 minutes |
| Badge = fake scarcity | badges are verifiable and cheap; one-off tier exists |

**Refusals, in one breath:** no telemetry, no dark patterns, no paywalled
safety, no venture pressure, no selling the room's data.

---

## 8. The one-line pitch

> **Qwave is free because privacy must be. The membership is the constellation
> around it — nightlies, the academy, the badge, and the weekly hub — for the
> price of a coffee that keeps the lights on.**
> `sharing is caring` · `0 + 1` · `fine touch from within`

*Open questions for the maintainer: (a) Discord-first or Matrix-first?
(b) is €4.20 too cute for a browser — or exactly right? (c) does the badge
need a public registry, or is pinning the pubkey enough?*
