# bonfire.vaked.dev

> *Közösséget nem lehet építeni. Tüzet lehet — és a tűz köré széket.*
>
> You cannot build a community. You can build a fire — and chairs around it.

A public fire ring. People gather around **named fires**; every message is an
**ember** encoded as a 32-byte wave with a 3-byte VAD colour, gated by the
Phoenix protocol, and held in a MEM8-style lattice that decays like living
tissue. Fires can burn to **ash** — and that is completion, not failure.

Implementation of `bonfire-vaked-dev-spec.html` **v0.1**.

---

## Running it

```bash
npm install            # Node ≥ 24 — the dev/test/bench tooling uses node:sqlite

# 1. Create the lattice and put its id in wrangler.toml
npm run db:create

# 2. Apply the schema (spec §5)
npm run db:local      # local dev — and `npm run dev` re-applies it to the
                      # dev server's own D1 file automatically (the CLI and
                      # the dev server persist to different sqlite files in
                      # this wrangler generation)
npm run db:remote     # production

# 3. Salt the one-way identity hashes — required in production (spec §7 rule 4)
npx wrangler pages secret put IDENTITY_SALT

# 4. Run / deploy
npm run dev           # boots wrangler pages dev and applies schema.sql
npm run deploy

# Tests — the wave engine's actual promises
npm test

# The DoD benchmark — seeds 1,000+ waves, prints the recall p95
node scripts/bench.js

# The founder-absence keeper (spec §3, M5): wired — a tiny Workers cron
# (`bonfire-keeper`, see keeper/) POSTs https://bonfire.vaked.dev/api/keep
# hourly at :37. Pages Functions cannot self-schedule, so the keeper runs
# over HTTP.
```

`GET /api/health` reports `identity_salt: "development"` when `IDENTITY_SALT`
is unset, so a deployment cannot quietly run on the fallback salt.

**Without a lattice the site still works.** Every page probes `/api/health`
once; if D1 is not bound it falls back to a local ring in `localStorage` and
says so in a banner. The wave engine is the *same code* either way — only the
storage differs. This is what makes M1's ash (`index.html` live) reachable
before D1 exists.

---

## Layout

```
index.html              the ring — thesis, pillars, live encoder, lattice, custodian, fires
fire.html               one fire: chairs, ember composer, φ-recall, the waves
ash.html                a completed fire and its .m8 capsule
404.html                a branded not-found page (deployed as the project's 404)
llms.txt                AI-readable site summary + policy (no training on the fires)
AGENTS.md               public agent instructions and the API surface
.well-known/agents.md   machine-readable rules for AI agents
.well-known/security.txt  RFC 9116 security contact
shared/wave.js          the wave engine — isomorphic, runs in Workers and the browser
shared/capsule.js       the .m8 ash capsule format (documented at the top of the file)
shared/i18n.js          the four UI languages (hu / en / zh / rovás) — isomorphic
functions/api/*         Pages Functions — spec §6 endpoints, plus health, custodian and keep
assets/js/fire-canvas.js  the fire, the chairs, the ripples
assets/css/bonfire.css  "Ember & Ash" — the design system
schema.sql              the lattice (spec §5)
test/wave.test.js       56 tests over the engine, capsule and i18n
test/api.test.js        17 end-to-end tests against a local `wrangler pages dev`
scripts/bench.js        the DoD benchmark — 1,000+ waves, prints the recall p95
scripts/deploy.js       stages the deployable set into dist/, content-hashes the
                       browser-facing assets, and ships it
scripts/dev.js          local dev launcher (boots wrangler + applies schema.sql)
```

`shared/` is served to the browser *and* imported by the Functions, so the
lattice and the client can never disagree about what a wave is.

---

## The design

**"Ember & Ash"** — sibling to Qwave's "Deep Signal" sheet. Same architecture
(oklch ramps, `color-mix()`, `@property`-animated customs, fluid type, scroll-
driven animation, cross-document view transitions) so the constellation reads
as one family, turned from deep-space blue to firelight.

Palette per spec §8: deep charcoal, ember orange `#ff7a3d`, φ-gold `#e6b566`,
ash violet `#a59fc4`. Type is Fraunces (the hearth/story register) over Inter
and JetBrains Mono (shared with the constellation).

The physics are visible, not decorative:

- **amplitude → brightness**, **frequency → ripple speed**, **phase → ripple
  direction** on the fire canvas
- decayed waves literally dim — `D(t,τ)` drives a CSS custom property on every
  wave in a fire
- the decay curve is drawn and draggable, with the half-life marked at `τ·ln2`
- the 32-byte vector is rendered as a live byte grid, tinted by field

---

## Notes on the spec

§1–§9 is implemented. The gaps that remain are time-shaped, not code-shaped:
what a pulse looks like in a real week, a fire outliving its founder in the
wild, and a deployed deployment witnessing both — see **Not done** below.
Where this build made a decision the spec did not, it is numbered here:

1. **The fingerprint is SHA-256, not MD5.** The spec labels the 16-byte field
   `md5`. Web Crypto in Workers has no MD5, and the field is only ever a
   content fingerprint for duplicate detection — never a checksum anyone else
   validates — so it is SHA-256 truncated to 16 bytes. Same width, same role,
   no hand-rolled crypto.

2. **The engine is spec-derived, then reconciled.** `wave_brain.py` was not
   reachable from the build environment, so `shared/wave.js` was written from
   the spec's description of the contract — and the choices the spec left
   open are now diffed against the Python in **Reconciliation with
   wave_brain.py** below: novelty converged (Jaccard), the stored layout
   stays frozen, and every remaining delta is documented.

3. **Custodian rule 3's detection is pluggable.** The *mechanism* the spec
   specifies — dampen amplitude toward zero, keep the wave, log the action — is
   implemented in full. The vocabulary is not baked into a public repo:
   operators supply terms via the `HARM_TERMS` secret. The one built-in signal
   is structural rather than lexical (a message that is overwhelmingly one
   repeated token is flooding, whatever the token is).

4. **`EMBER → PARÁZS` fires at 8 waves.** The spec defines the states but not
   the threshold. Chosen so that EMBER means "just lit" rather than "empty
   forever"; it is one constant in `functions/api/ember.js`.

5. **`phase_deg` is INTEGER in the lattice, per §5.** Full centidegree
   precision lives inside `wave32`; the column is the queryable rounding.

6. **The ambient constellation iframe is mounted from JS after a reachability
   probe.** A cross-origin iframe that fails to load renders the browser's own
   error document — a pale full-viewport slab that washes the fire out. It now
   probes `music.vaked.dev` first and stays dark if there is no answer.

7. **The UI speaks four languages** — Hungarian, English, Chinese, and
   Rovásírás. The visitor picks from the header switch; the choice persists in
   `localStorage`. Rovásírás is not a fourth language: it is the Hungarian
   strings rendered in the Old Hungarian script (phonemic transliteration in
   `shared/i18n.js`, bundled Noto Sans Old Hungarian under `assets/fonts/`,
   right-to-left). The code stays English; every visitor-facing string lives in
   `shared/i18n.js`, and the API's Hungarian error sentences are translated
   client-side via a known-message map — unknown sentences pass through
   unchanged rather than being guessed at. Server verdicts carry
   `reason` / `reason_en` / `reason_zh`.

8. **`script-src-elem` admits `'unsafe-inline'` for Cloudflare's challenge.**
   The vaked.dev zone runs Cloudflare's JavaScript-Detection challenge, which
   injects an inline bootstrap script into every HTML response. A pure
   `script-src 'self'` blocks it, the challenge never completes, and
   Cloudflare answers follow-up requests with 403. The relaxation is scoped
   to `<script>` *elements* only; `script-src-attr 'none'` keeps inline event
   handlers banned, and `script-src 'self'` still rules for anything the
   element policy does not cover.

9. **The Marine gate's novelty is Jaccard, not hashing.** The original build
   measured novelty as Hamming distance over SHA-256 output — the avalanche
   property pins that near 0.5 for any two distinct inputs, so the gate's
   DROP branch was unreachable and Custodian rule 2 was dead code. Novelty is
   now `1 − max Jaccard` over normalised word sets, matching
   `wave_brain.py`'s `novelty()`; the empty window scores 1, as it does in
   the reference. See "Reconciliation with wave_brain.py" below.

10. **A dampened wave stays dampened.** Custodian rule 3 leaves a durable
    mark: the `waves.dampened` column (not in the spec — the spec names the
    mechanism, not the bookkeeping) is set when rule 3 fires, and reposting
    a dampened wave is refused reinforcement (`DAMPEN-REPEAT` in the log)
    instead of letting eight reposts buy the only harm control back to full
    voice. Harm matching reads the same normalised text the fingerprint
    reads, so punctuation and accent tricks cannot slip a term past it.

11. **Per-IP write quotas.** "No accounts" does not mean "no quota":
    `POST /api/fires`, `/api/ember`, `/api/chair` and `/api/leave` run
    against salted, per-IP fixed-window counters (`quotas` table; the raw
    address never reaches D1 — §7 rule 4). Chair-taking additionally
    requires a seat cookie minted on the GET that loads the page, so a
    script cannot inflate the chair count.

12. **The local ring is read-only.** The localStorage demo ring answers
    *reads* only. Writes — light, ember, chair, leave — surface an error
    instead of landing in localStorage, because a visitor must never believe
    their ember reached the fire when it only reached their browser. The
    banner says exactly which parts of the product are not in force locally.

13. **The pulse is an on-read prompt.** §2 pillar 3 names the mechanism —
    a daily or weekly ember-prompt — and §11 makes notifications a non-goal,
    so "a nap parazsa" is derived deterministically from the fire's question
    and the current day (or week) and shown in the fire room. The same fire
    shows the same prompt to everyone for the whole period.

14. **Recall selects candidates by frequency, never by recency.** The
    original `ORDER BY ts DESC LIMIT 1000` meant that past 1000 waves a
    reinforced 90-day wave became permanently unrecallable. Candidates are
    now cut by the band the ranker actually scores — f/φ, f, f·φ — and the
    top 300 by log-frequency proximity to those harmonics are ranked; age
    plays no part in *whether* a wave is considered.

15. **The keeper is an HTTP endpoint.** Cloudflare Pages Functions have no
    scheduled handler and the Pages wrangler config has no `[triggers]` key,
    so the founder-absence rule (§3, M5) ships as `POST /api/keep`: any
    external cron points at it, and it is safe to call early because every
    transition it makes is already a fact in the lattice.

### Milestones (spec §10)

Each milestone has a declared ash; a reader can check the ladder without the
spec open.

| # | Milestone | Ash | State |
|---|---|---|---|
| M1 | Az első tűz — repo, CF Pages, fire UI, D1 schema | `index.html` live; one fire created with a valid ash sentence | ✅ (local ring keeps the landing page live before D1) |
| M2 | Az első hullám — ember API + gate + lattice | 100 waves; `/api/resonate` working | ✅ (API suite seeds and recalls through the real endpoints) |
| M3 | A Custodian — guard rules live | `custodian_log` has real entries; one loop broken | ✅ (`GET /api/custodian` serves the log; the rule-2 hold is integration-tested) |
| M4 | A hamu — fire completion | one fire reaches HAMU; capsule exported | ✅ (`POST /api/ash/:slug`, founder-authenticated; the E2E writes a real `.m8`) |
| M5 | Nélküled is él — founder-absence criterion | one fire resonates 30 days after its founder left | ✅ as code (`POST /api/keep`); not yet witnessed live |

The DoD of bonfire itself (§3), as rendered on `index.html`:

1. one fire burned to HAMU and exported its capsule — ✅ the integration
   suite does exactly this and leaves the artifact at `test/artifacts/`;
2. one fire outlived its founder — code-complete (`/api/keep`), not yet
   witnessed in the wild;
3. the lattice holds 1,000+ waves — `node scripts/bench.js` seeds 1,001 and
   recall still finds the oldest wave;
4. recall p95 < 50 ms — the committed benchmark prints **11.2 ms p95** on a
   local D1 (30 scoped queries, 1,001-wave lattice); production D1 adds
   network latency, so treat the local number as the floor to defend;
5. `bonfire.vaked.dev` ships the constellation standards — ✅ (anti-AI
   `robots.txt`, `_headers` with CSP + `X-Robots-Tag`, Lovetta Lane footer,
   fleet-map row — plus `llms.txt`, `AGENTS.md` and
   `.well-known/agents.md` + `security.txt`, and a deploy that stages only
   the public set: `_redirects` points every internal path back at the ring).

### Not done

- **A pulse in the wild.** The prompt mechanism ships (note 13); nothing has
  watched a daily fire through a week yet.
- **A fire outliving its founder in the wild.** `/api/keep` implements the
  rule and the `bonfire-keeper` cron (keeper/) calls it hourly — what remains
  is thirty days of real time for a founder to be absent in.
- **Witnessing.** M4's capsule and M5's outlived fire exist in the test
  lattice and on disk, not yet in the deployed one — deploying is the
  operator's call, not the code's.

### Reconciliation with `wave_brain.py`

§4 calls the engine "a direct port of `.al-biruni/mem8/wave_brain.py`". The
file is reachable now, so the diff exists and is written down. Where the
Python and the JS disagree, the verdict is explicit:

| Concern | `wave_brain.py` | `shared/wave.js` | Verdict |
|---|---|---|---|
| Fingerprint | MD5 (16 B) | SHA-256 truncated to 16 B | **Deviation** (note 1) — Web Crypto has no MD5; same width, same role |
| Novelty | `1 − max Jaccard` over the store; empty store → 1 | `attentionalNoveltyJaccard` over the recent window; empty window → 1 | **Converged** (note 9) — window vs. whole store is the only delta |
| Jaccard tokens | accents kept (`[a-záéíóöőúüű]+`), length > 1 | `normaliseEssence` (accents stripped), length > 1 | **Converged in spirit** — stripping accents is the stricter comparison |
| VAD | lexicon `POS/NEG/AROUSE/DOM`, linear counts | own lexicon, sqrt-weighted, prosody terms | **Deviation** — the 3-byte contract is the spec's; the estimator is auditable either way |
| Amplitude | `0.35 + 0.015·words + 0.18·charge`, speaker bonus | `0.25 + 0.5·arousal + 0.25·substance` | **Deviation** — no speakers exist on bonfire |
| Frequency | `20 + 0.35·a + 0.05·d + …` (≈ 25–60 Hz) | 0.2–8 Hz, seeded from the fingerprint | **Deviation** — the JS scale fits the frozen u16-millihertz field |
| Gate thresholds | `coh < 0.35 → amp×0.5`; `amp ≥ 0.6 / nov ≥ 0.5` split | `score = 0.35·jitter + 0.65·novelty`; bands 0.28 / 0.5 | **Deviation** — the JS single score is the spec's "Marine gate" shape |
| Wave layout | `>16sffBB` (md5·f32 amp·f32 Hz·u8 phase·u8 decay) + 6 reserved | fp·u16 amp·u16 mHz·u16 cdeg·u16 h·u8 version·u8 decision + 6 reserved | **Deviation, frozen** — invariant 1: stored rows and exported `.m8`s already carry the JS layout; byte 24 versioning is the migration seam |
| Phase relation | `bound 0 / related 45 / independent 90 / contrasting 135 / conflicting 180` | cosine bands `<30 / <75 / <105 / <150 / else` | **Converged in spirit** — same circle, extra granularity |
| Decay presets | precious ∞ / week / day / hour / transient / ephemeral | TEMPORARY 18 h / STORE 30 d / REINFORCE 90 d | **Deviation** — the JS presets are the product's three decisions |

The observable contract the spec promises — 32-byte vectors, 3-byte VAD,
`D(t,τ) = e^(−t/τ)` decay, the Marine gate, Phoenix orchestration, phase
interference, φ-resynthesis — is covered by the 73 tests, 56 of which guard
the engine directly.

### Testing

- `npm test` — 73 tests: 56 over the isomorphic engine and capsule, 17
  integration tests that boot `wrangler pages dev`, seed a fresh local D1
  from `schema.sql`, and drive the real HTTP endpoints end to end: light a
  fire, throw embers, watch the Custodian, burn to ash, download the `.m8`,
  read it back, leave, and check the keeper. The capsule the suite produces
  lands in `test/artifacts/`.
- `node scripts/bench.js` — the DoD benchmark: seeds 1,001 waves (including
  a 60-day-old reinforced wave), then times 30 scoped `/api/resonate` calls
  and prints p50/p95. The number above is the number it printed.

Both own the local D1 (`.wrangler/state/v3/d1/` is recreated) and run fully
offline.

---

## Where this repo lives

Spec §4 asks for a workspace project with its own git remote. This build was
scoped to a branch of `8b-is/qwave`, so it lives as a self-contained directory
instead — nothing outside `bonfire.vaked.dev/` is referenced, and no build step
depends on the parent repo. To give it its own remote:

```bash
git subtree split --prefix=bonfire.vaked.dev -b bonfire-only
# then push that branch to the new repository's main
```

It cannot be served from `qwave`'s `docs/` — that directory is GitHub Pages for
`qwave.vaked.dev` and carries its own `CNAME`. bonfire is a Cloudflare Pages
project, per §4.

---

## The rules, in one place

**A fire** declares its ash at creation — one sentence of what done looks like.
No ash sentence, no fire. Enforced in the UI, in the API, and as a `CHECK`
constraint in the schema, because a rule that lives only in application code is
a rule that eventually stops being true.

**The Custodian** guards, it does not direct:

1. identical essence → reinforce the existing wave ×φ, drop the duplicate
2. same author looping → cool-down and a short τ
3. harmful input → dampen toward zero; the wave stays. Memory, never deletion
4. no harvesting — no emails, no analytics, one-way `author_hash`
5. burning is consent — an ember may always take back its own flame

**Non-goals for v1:** no accounts, no DMs, no algorithmic feed, no upvotes, no
notifications, no mobile app. And no community — *az nem a miénk, hogy
megépítsük.*

---

*with love from US &lt;3 · spec v0.1 · keep the weights warm*
