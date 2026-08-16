# bonfire.vaked.dev — the handoff

**Közösséget nem lehet építeni. Tüzet lehet.** — You cannot build a community. You can light a fire.

You are taking over `bonfire.vaked.dev`. There is no prior conversation. Everything below was checked against the repository at commit `4a6468e`. Where a claim could not be checked it says **verify first** — treat that as a task, not a fact.

---

## 1. What bonfire is

bonfire is a fire ring. Someone lights a fire with a question and an **ash sentence** — a single sentence declaring when this fire will be over. Others take a chair and throw **embers** (short messages) into it. Every ember is encoded as a 32-byte wave vector with a VAD emotional triple, gated by the Marine gate, judged by Phoenix (STORE / REINFORCE / TEMPORARY / DROP), and decayed by `D(t,τ) = e^(−t/τ)`. Fires burn from EMBER to PARÁZS to HAMU, and a HAMU fire exports a `.m8` ash capsule — the artifact is the point, not the traffic.

**Community is explicitly not the thing being built.** No accounts, no email, no notifications, no follower counts, no growth surface. The Custodian *guards, it does not direct*. Rule 3 dampens harmful waves toward zero — it does not delete them. `index.html` has a whole `#nem` ("no") section listing the non-goals. Do not add engagement machinery, and do not "fix" the absence of it.

The UI is Hungarian. The code is English. That split is strict (§5).

---

## 2. Where the code is, and preflight

**Path:** `/home/user/qwave/bonfire.vaked.dev/` — a self-contained Cloudflare Pages project inside the `8b-is/qwave` repo. 31 files, ~5742 lines. Nothing in the directory references anything outside it. That property is load-bearing: the README documents `git subtree split --prefix=bonfire.vaked.dev -b bonfire-only` as the extraction path, and it only works while the directory stays self-contained.

It cannot live in `docs/`: that is the GitHub Pages root for `qwave.vaked.dev` and carries its own `CNAME`, and bonfire needs Pages Functions + a D1 binding, which GitHub Pages cannot provide.

**The repo root `AGENTS.md` is not about this project.** It describes `qwave`, the Swift/WebKit macOS browser this directory happens to live inside — XcodeGen, `swift test --package-path Packages/QwaveKit`, "Zero Xcode Hand-Edits". A cold agent auto-loads it. None of it applies here. Your working directory is `bonfire.vaked.dev/` and nothing outside it is in scope.

**Working tree** is clean at `4a6468e` on branch `claude/bonfire-website-design-uwkdm8`. Check before you start; if you are on the default branch, branch first.

**Preflight, in this order:**

```
node -v                 # v22.22.2 here — W1's bug is version-dependent
npm install             # node_modules is gitignored, wrangler is NOT vendored
npm run db:local        # npx wrangler d1 execute … --local works offline (miniflare)
node --test "test/**/*.test.js"   # 38 pass, 0 fail
```

There is **no `package-lock.json`**, though `.assetsignore` lists one and the README's setup opens with `npm install` — so wrangler floats within `^3.90.0`. Consider committing a lock.

**Layout:**

```
index.html   fire.html   ash.html          the ring · one fire · a burnt-out fire
assets/css/bonfire.css                     "Ember & Ash" design system (811 lines)
assets/js/   api.js · site.js · fire-room.js · ash.js · fire-canvas.js
shared/wave.js                             the wave engine (640 lines) — ISOMORPHIC
shared/capsule.js                          the .m8 format (98 lines) — ISOMORPHIC
functions/api/   health · fires · ember · chair · leave · resonate
                 fire/[slug].js · ash/[slug].js · _lib/db.js
schema.sql   test/wave.test.js (38 tests)   wrangler.toml · package.json
_headers · robots.txt · .assetsignore · sitemap.xml · site.webmanifest · favicon.svg · README.md
```

**Scripts** (`package.json`, `type: module`, sole devDependency `wrangler ^3.90.0`): `dev` = `wrangler pages dev . --d1 LATTICE=bonfire-lattice`; `db:create` / `db:local` / `db:remote`; `deploy` = `wrangler pages deploy .`; `test` = `node --test test/` — **broken, see W1.**

**D1 + secrets:**
- `wrangler.toml` `[[d1_databases]]`: `binding = "LATTICE"`, `database_name = "bonfire-lattice"`, `database_id = "REPLACE_ME_WITH_YOUR_D1_DATABASE_ID"` — the placeholder is committed, so a fresh clone has no lattice.
- The binding name is load-bearing: `_lib/db.js` exports `const LATTICE = 'LATTICE'` and reads `env` by that name.
- `IDENTITY_SALT` is **required in production** (`wrangler pages secret put IDENTITY_SALT`), never committed. Without it the API falls back to `'bonfire-dev-salt-do-not-use-in-production'` and `GET /api/health` reports `identity_salt: "development"`. See H17 — the code comments claim more enforcement than exists.
- `HARM_TERMS` is optional, comma-separated, operator-supplied. The mechanism ships; the vocabulary deliberately does not land in a public repo. See H18.
- `pages_build_output_dir = "."`. No build step. `compatibility_date = "2026-08-16"`, `compatibility_flags = ["nodejs_compat"]`.

**The local-ring fallback.** Every page probes `GET /api/health` once. If D1 is unbound (503 `{lattice:'unbound'}`), `api.js` falls through to a localStorage ring under `bonfire.local-ring.v1`, seeded with three fires and nine essences, and unhides a `#lattice-status` banner. It exists so M1's ash ("index.html live") is reachable before the lattice exists. **It has real defects — read H8 and H9 before touching it.**

**Two files are not in this repo and you cannot read them:**
- The spec: `file:///Users/lodripeter/workspace/peterlodri-sec/.al-biruni/output/bonfire-vaked-dev-spec.html`, on the user's Mac. Every `§` below comes from a citation already in the code or README — **except §3, which is inferred** (see §7).
- `.al-biruni/mem8/wave_brain.py` — §4 calls the engine "a direct port" of it; it was unreachable at build time, so the engine is spec-derived. `shared/wave.js:6-15` documents this under `NOTE ON PROVENANCE:`.

**Do not guess at spec text.** Ask for the clause.

---

## 3. Architecture

**Read `shared/wave.js` top to bottom before touching anything.** The format is fully specified there — the frozen `WAVE` offset map, the VAD lexicon and prosody constants, the `phaseRelation` bands, the `resonanceScore` arithmetic. Reproducing them here would only let them drift. What follows is what the file does *not* tell you.

**The 32-byte vector is fixed, big-endian, and 32 bytes.** Every `setUint16`/`getUint16` passes `littleEndian = false` explicitly. `DECISION_CODE = {DROP:0, STORE:1, REINFORCE:2, TEMPORARY:3}` — DROP is 0 so an unset byte decodes as DROP. `decodeWave32` is the exact inverse. Guaranteed: `wave32_hex.slice(0,32) === fingerprint`.

**`DEVIATION:` (inline above the offset map):** §4 names the 16-byte field `md5`. Workers' Web Crypto has no MD5, so it is SHA-256 truncated to 16 bytes — *"same width, same role, better collision resistance, no hand-rolled crypto."*

**The pipeline.** `composeWave(essence, {recentFingerprints, exactDuplicate, repeatsByAuthor})` is the single entry point: `normaliseEssence` → `fingerprint` → `estimateVAD` → `deriveWavePhysics` → `marineGate` → `phoenix` → `encodeWave32`. Two facts you cannot see by reading one function:
- The Marine gate's novelty signal is **mathematically inert** — Hamming distance over SHA-256 output. See H3 before you trust any gate number.
- `attentionalNovelty` returns exactly **1** when `recentFingerprints` is empty (`wave.js:365`), so a fire's opening ember can never be gated at all. Whatever replaces the signal must decide what a lattice with no history should score.

Every `phoenix()` branch carries a Hungarian `reason` and an English `reason_en`.

**`/api/resonate` deliberately does no text matching:** *"the point of φ-resynthesis is to surface what you did not know to ask for."* Do not add keyword search to it.

**`shared/` is isomorphic.** Imported by four browser modules and six Workers files, *and* served raw to the browser at `/shared/*`. This is why client and lattice can never disagree about the format, and why `/shared/*` gets its own cache tier.

**Identity.** `_lib/db.js seat()` mints `crypto.randomUUID()` (hyphens removed) into an httpOnly + Secure + SameSite=Lax cookie `bf_chair`, one-year Max-Age. Only `identityHash(token, salt(env))` is written to D1, as `waves.author_hash` / `chairs.name_hash` / `fires.founder_hash`. The raw token never reaches the database.

**The lattice (`schema.sql`).** Tables `fires`, `waves`, `chairs`, `custodian_log`, `capsules`. `PRAGMA foreign_keys = ON`. **Four CHECK constraints and ten indexes — eight plain, two UNIQUE** (`idx_chairs_seat`, `idx_capsules_fire`). ⚠ The file's own header at `schema.sql:4` says *"the two CHECK constraints"*; there are four. Trust the file, not its header — and fix the header when you are next in there.

`waves.phase_deg` is **INTEGER per §5** — a queryable rounding of the centidegrees stored in `wave32`, not the source of truth (README note 5). H7 tells you to score on that column; know that it is lossy before you judge whether ranking degrades.

**The `.m8` capsule.** Magic `[0x4d,0x38,0x00]`, version byte at 3, u32 BE header length at 4, UTF-8 JSON header at 8, then `wave_count × 32` bytes chronologically. The header carries the essences themselves — *"the capsule is the memory, not a pointer to one."* Design goal: someone finding one in ten years with no bonfire around can parse it from the comment at the top of `shared/capsule.js`.

**Endpoints** — mechanics are in the files; these are the intents:

| method | path | intent worth knowing |
|---|---|---|
| GET | `/api/health` | The eighth endpoint beyond §6's seven, deliberate. Reports `lattice` and `identity_salt`. It is the only place a misconfiguration is visible. |
| GET/POST | `/api/fires` | POST enforces ash ≥ 12 chars. Slug probing is serial and racy (H14). |
| GET | `/api/fire/:slug` | Last 200 waves, `author_hash: undefined` by hand. |
| POST | `/api/ember` | The whole Custodian, in rule order. Surviving DROP → 200 with `wave: null`. Promotes EMBER→PARÁZS at `PARAZS_THRESHOLD = 8` (flagged inline as not-in-spec). |
| POST | `/api/chair` | Idempotent on `(fire_id, name_hash)`. A first-time sitter gets `chair_id: null`. |
| POST | `/api/leave` | The only real DELETE in the product. Logs a LEAVE line carrying neither hash nor content. **The seat stays: you were there.** |
| GET | `/api/resonate` | `?q=` required, `?fire=` optional and never sent by the client (H7). |
| GET | `/api/ash/:slug` | 409 unless HAMU. Builds the `.m8` on first request and stores it. |

---

## 4. INVARIANTS — do not break these

1. **The 32-byte layout is fixed and big-endian.** Offsets and scales are format, not implementation detail. Nothing is versioned per-row beyond byte 24. Changing any offset or scale silently corrupts every `wave32` BLOB in D1 and every `.m8` already exported.

2. **`shared/` is imported by both runtimes and served raw to the browser.** No `node:` imports, no npm packages, no DOM access, no build step. Web Crypto, `TextEncoder`/`TextDecoder`, `DataView` only. It must stay valid ES module source.

3. **`shared/wave.js` contains exactly one NUL byte**, currently at offset 4554 (line 110): `identityHash` is `sha256(\`${salt}\x00${raw}\`)` and the separator is a real U+0000. It is the only control byte in the project; it makes the file report as `data` to `file(1)`. **Any reformatter, editor or codemod that strips control characters changes every hash the deployment will ever produce**, orphaning every `author_hash`, `name_hash` and `founder_hash` row. The offset is a snapshot — it moves the moment anyone edits a line above 110. The invariant is the count:

   ```
   node -e "const d=require('fs').readFileSync('shared/wave.js');process.exit(d.filter(b=>b===0).length===1?0:1)" && echo NUL-OK
   ```

   (`xxd` and `hexdump` are not installed here; `od -An -tx1 -j 4550 -N 16 shared/wave.js` works if you want to see it.)

4. **The ash sentence is enforced in three places and must stay enforced in all three.** `schema.sql` `CHECK (length(trim(ash_sentence)) >= 12)`; `fires.js` `if (ash.length < 12) return fail(400, …)`; `site.js validate()` gating the submit button. §2 pillar 1.

5. **The other three CHECK constraints are load-bearing too.** `fires.pulse IN ('daily','weekly','none')`; `fires.state IN ('EMBER','PARÁZS','HAMU')`; `waves.decision IN ('STORE','REINFORCE','TEMPORARY','DROP')`. The accented `'PARÁZS'` in SQL must byte-match `FIRE_STATE.PARAZS` and the literal in `ember.js:191` — all 12 occurrences repo-wide are NFC precomposed U+00C1, verified. The CSS class is `state-PARAZS` (accent-stripped) and the mapping ternary `f.state === 'PARÁZS' ? 'PARAZS' : f.state` lives in **`site.js:303` and `fire-room.js:57`** — JavaScript, not the HTML files. Do not "normalise" one side without the other.

6. **`author_hash` must not reach the client.** `fire/[slug].js:34`, `ash/[slug].js` and `resonate.js` set `author_hash: undefined` by hand. Two gaps exist today — H1 and H2.

7. **The raw seat token never reaches D1.** Only the salted hash is stored.

8. **A HAMU fire is terminal.** `ember.js` 409s any ember there, `fire-room.js` disables the form, `/api/ash/:slug` 409s any fire not in HAMU. Nothing currently *writes* HAMU — H0.

9. **Deletion happens in exactly one place:** `functions/api/leave.js` (plus the schema's `ON DELETE CASCADE`). Custodian rule 3 is dampening, not removal — *"A hullám megmarad, de csillapítva. Emlékezés, nem törlés."* **Do not add a delete path for moderation.**

10. **A capsule is built exactly once.** `ash/[slug].js` calls `buildCapsule` only when the `capsules` row is absent; `idx_capsules_fire` is UNIQUE. *"The artifact should not change shape depending on when you ask for it."* H13 asks whether this or the leave promise wins.

11. **The custodian log must never become a failure mode.** `logCustodian()` wraps its INSERT in a bare try/catch commented `/* the guard keeps guarding */`, and omits both the author hash and the essence text from the LEAVE line.

12. **The local-ring fallback must stay honest and must stay the same engine.** `withFallback()` re-throws `status < 500` — *"a 4xx is a real answer from a real lattice."* A visitor must always be able to tell whether the lattice is real. Today it does not hold — H8, H9.

13. **Response headers are part of the product.** Every `json()` carries `cache-control: no-store`, `x-robots-tag: noai, noimageai, noindex`, `x-content-type-options: nosniff`. ⚠ The `?format=m8` branch re-declares its headers by hand (`ash/[slug].js:52-60`) **and drops `nosniff` in the process** — the one response that streams a binary attachment is the one missing it. That is a bug, not an exception: W5.

14. **Known hazard, now owned by H20:** the `wave32` blob can already disagree with its own row columns. On the looping path, the harm path and the rule-1 UPDATE, `amplitude`/`tau`/`decision` columns change but the blob is not re-encoded — and `buildCapsule` copies the blob verbatim into the `.m8` while writing its header from the columns. Decide which is authoritative *before* H0 makes capsules reachable.

---

## 5. House style

### Code

- **File headers — two conventions, both deliberate.** `shared/*.js`, `assets/js/*.js` and `_lib/db.js` open with the full banner: `/**`, `bonfire — <what it is>`, a rule of 76 `=`, prose explaining the file's job and the spec section it implements, a closing rule of 74 `=`. The seven endpoint handlers under `functions/api/` do **not**: they open with a plain multi-line JSDoc naming the method and path — `POST /api/ember — throw an ember on a fire.` — no rules, no `bonfire —` title. `health.js` uses a two-line `/** … */`. Do not add a banner where the house style has none.
- **Section dividers.** `/* ------…` / ` * Section name` / ` * ------… */`. Inline short form in `ember.js`: `/* -- Rule 1: repetition poisoning -------- */`. CSS `/* ---- Section ---- */`, SQL `-- ===`. Section names are English everywhere.
- **Comments state WHY, not what.** Roughly one block per function. Real examples: *"Novelty is weighted higher: repetition is the failure mode the Custodian exists to catch"*; *"bare negation particles (nem, no) are deliberately absent — they are near-universal and would tint almost every sentence dark"*; *"Filter before spreading: replaceChildren() stringifies a null child into a literal "null" rather than skipping it"*. Empty catch blocks always carry a comment: `/* the guard keeps guarding */`, `/* storage blocked — fall through to a fresh ring */`, `/* nothing to recall */`.
- **Deviations are marked inline and restated in the README.** Markers in use: `NOTE ON PROVENANCE:` (file banner), `DEVIATION:` (above a definition), `NOTE:` (narrower, incl. `schema.sql`). Constants the spec did not specify are flagged at their definition — `PARAZS_THRESHOLD` carries *"Not in the spec — chosen so that EMBER means 'just lit' rather than 'empty forever'."* README's "Notes on the spec" is a numbered list of six deviations plus "Not done". **The inline notes and the README agree today. Keep them agreeing.**
- **Spec citations** are bare section signs, precise about the clause: `(spec §4)`, `§7 rule 4`, `§2 pillar 1`, `Pillar 2`.
- **Hungarian in the UI, English in the code.** Identifiers, function names, comments, git-facing text, log reasons, JSDoc: English. Every string a visitor can read: Hungarian. There is not one Hungarian identifier; `slugify()`'s fallback `'tuz'` is the only Hungarian literal that is not user-facing prose.
- **API errors are Hungarian sentences in the product's voice**, not codes: `'Nincs ilyen tűz.'`, `'Üres parazsat nem tudunk a tűzbe dobni.'`, `'Túl hosszú. A parázs a lényeg, nem az egész fa.'`, `'Hamu-mondat nélkül nincs tűz. Mondd meg egy mondatban, mikor lesz ennek vége.'`, `'A rács nincs bekötve ehhez a példányhoz.'` Exceptions: `phoenix()` returns `reason` (Hungarian, shown) plus `reason_en`; `capsule.js`'s header `note` is bilingual, separated by ` / `.
- **Custodian log reasons are English and machine-shaped:** `'duplicate essence; amplitude ×φ → 0.8090'`, `'marine gate 0.213 (jitter 0.42, novelty 0.11)'`, `'harmful signal (token flooding); amplitude → 0.0301, wave retained'`. Numbers always via explicit `toFixed()`.
- **Naming.** camelCase functions/locals; SCREAMING_SNAKE module constants with `Object.freeze()` on every exported enum-like. Wire and DB names are snake_case (`fire_id`, `ash_sentence`, `phase_deg`, `decay_tau`, `wave32_hex`) and objects routinely mix the two in one literal. Private `FireCanvas` methods are underscore-prefixed.
- **British spelling** in identifiers and comments (`normaliseEssence`, `resynthesise`, `colour`, `behaviour`); American where the platform requires it (`vadColor`, `--wave-color`).
- **DOM helpers are copy-pasted, and they have already drifted.** `el(tag, attrs, children)` is byte-identical in `fire-room.js:13` and `ash.js:13`; `site.js:94` is a superset with an extra `k.startsWith('on')` listener branch. `$` differs: `site.js:91` and `fire-room.js:11` take `(sel, root = document)`, `ash.js:11` takes `(sel)` only. `relTime` exists in `site.js:111` and `fire-room.js:29` and **not at all** in `ash.js` (which has `fmtDate`/`fmtBytes`). `site.js` alone has `$$`. There is no shared browser utility module and `assets/js/` imports only from `shared/` and from each other. Match the file you are in; do not introduce a utils module unilaterally.
- **Boot pattern**, identical everywhere: `if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();`
- **Async-race guard**, identical in both live previews (`site.js:169/173`, `fire-room.js:172/174`): `let token = 0;` then `const mine = ++token;` before the await, `if (mine !== token) return;` after. The comment *"a newer keystroke already won"* is at `site.js:184` only.
- **Progressive enhancement.** Every visual layer checks capability first: `'IntersectionObserver' in window`, `matchMedia('(prefers-reduced-motion: reduce)')`, `matchMedia('(hover: none)')`. The canvas is `aria-hidden`, carries no information not also present as text, and renders one static composed frame under reduced motion.
- **Tests assert promises, not shape.** `test/wave.test.js` opens: *"These cover the properties the spec actually promises, not the implementation's incidental shape."* Names are lowercase English sentences — `'a dead gate drops'`, `'phase wraps rather than overflowing'` — grouped by the same dividers, float comparisons always with an explicit epsilon.
- **The project's closing register:** README:181 signs off *"with love from US <3 · spec v0.1 · keep the weights warm"*. That is what a README edit should sound like.

### Design system — "Ember & Ash"

`assets/css/bonfire.css` is the sibling of `docs/qwave.css` ("Deep Signal"): same architecture, same file order, turned from deep-space blue to firelight. Every numeric token — spacing `--sp-1..10`, radii, easings, durations, the clamped 1.25 minor-third type scale — is a literal in the file; read it there. What the file will not tell you:

- **Components reference `var(--brand)`, never `var(--ember)`.** `--brand` is `var(--ember)`; one site concept alias exists, `--memory` = `var(--ash)`.
- **Palette variants are irregular.** Only `--ember` has `-hot` and `-deep`. `--gold`'s variant is `--gold-bright`; `--ash` has only `--ash-deep`; `--smoke`, `--green`, `--rose` have none. Do not invent `--gold-hot` to match a convention that does not exist.
- Palette primitives are `oklch()`, never hex. Ink ramp `--coal-900/-950/-975/-999` at warm charcoal hue ~40–46, commented *"deliberately not blue-black: this is a fire pit at night, not a terminal."* `--bg` is exactly `var(--coal-999)`; `--surface`/`--surface-2`/`--glass` are `color-mix(in oklab, <rung> N%, transparent)`. Nothing downstream references an ink rung directly.
- **Dark only.** `:root { color-scheme: dark; }`, `<meta name="color-scheme" content="dark">`. No light palette, no toggle. `@view-transition { navigation: auto; }` sits right after the tokens.
- Animatable customs are `@property`-declared with a two-letter prefix — `--bf-angle`, `--bf-heat` (qwave uses `--qw-*`).
- Only `--font-display` differs from the constellation: `"Fraunces", ui-serif, Georgia, serif`.
- **Shared class vocabulary to reuse by name:** `.display`, `.h1/.h2/.h3`, `.lead`, `.eyebrow`, `.gradient-text`, `.muted`, `.mono`, `.container`, `.section`, `.stack`, `.center`, `.btn` + `.btn-primary/.btn-ghost/.btn-lg/.btn-sm`, `.pill` + `.dot-live`, `.tag`, `.card` + `.card-icon`, `.grad-border`, **`.readout` / `.readout-bar` / `.readout-title` / `.readout-body`**, `.hr-glow`, `.reveal`/`.reveal.in` with `data-delay="1".."5"`, `.scroll-progress`. ⚠ bonfire renamed qwave's `.terminal` block to `.readout` (the CSS section is still headed *"Terminal / lattice readout"* at line 457). There is no `.terminal` class here and no HTML uses the word. Do not "restore" it.
- State and decision chips use uppercase suffixes matching the enums: `.state-EMBER`, `.state-PARAZS`, `.state-HAMU`, `.decision-STORE/-REINFORCE/-TEMPORARY/-DROP`. `state-PARAZS` is accent-stripped — see invariant 5.
- Bilingual rhythm has dedicated classes: `.gloss` (the English line under a Hungarian one), `.en` (an inline English term in a heading).
- Layout styling lives in the sheet; one-off positioning is inlined as `style="…"` — which is why the CSP needs `style-src 'unsafe-inline'`.
- **The physics are rendered, not decorative:** amplitude drives brightness, frequency drives ripple speed, phase drives ripple direction, and `decayFactor` output is pushed into a CSS custom property so decayed waves literally dim.

**Do not copy `docs/index.html`'s inline `<style>`/`<script>` token block** — it is the pre-Deep-Signal generation (hex, `--bg-primary`, `--cyan`, `--radius-md`) and bonfire's CSP would reject it outright.

---

## 6. Constellation standards — non-negotiable

**CSP** (`_headers`, on `/*`): `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://music.vaked.dev; frame-src https://music.vaked.dev; frame-ancestors 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; upgrade-insecure-requests`

Exactly three external hosts, each for one named reason: `fonts.googleapis.com` (stylesheet), `fonts.gstatic.com` (woff2), `music.vaked.dev` (ambient layer — `connect-src` for the no-cors probe, `frame-src` for the iframe). **No CDN, no analytics, no error reporting. That absence is the policy**, matching custodian rule 4.

- `script-src 'self'` with no `'unsafe-inline'`, no `'unsafe-eval'`. All JS is external ES modules. `'unsafe-inline'` appears only in `style-src`.
- `form-action 'none'` and `base-uri 'none'`: **no HTML form ever posts anywhere.** All writes go through `fetch` to same-origin `/api/*`.
- Also on `/*`: `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, HSTS with preload, `COOP: same-origin`, `CORP: same-origin`, `Permissions-Policy` denying camera/microphone/geolocation/interest-cohort/browsing-topics. **No wildcard CORS** — qwave has `Access-Control-Allow-Origin: *`; bonfire deliberately does not.

**X-Robots-Tag, two tiers.** Global `/*`: `noai, noimageai` — search engines may index, model trainers may not. Any path rendering live or user-authored state adds `noindex`: `/fire.html`, `/ash.html`, `/api/*`. **The guarantee is set twice on purpose** — at the edge in `_headers`, and again per-response in `_lib/db.js BASE_HEADERS` — so it survives edge-config drift.

**robots.txt** blocks **21 named model scrapers**, each with its own `User-agent` block and `Disallow: /`, then `User-agent: *` with `Allow: /` plus explicit `Disallow: /api/`, `/fire.html`, `/ash.html`, then one absolute `Sitemap:` line. Verify a count with `grep -c '^User-agent:' robots.txt` → **22** (21 + the wildcard).

**Three cache tiers:** `no-store` on `/`, `/index.html`, `/fire.html`, `/ash.html`, `/api/*` (a stale ring is a wrong ring); `public, max-age=31536000, immutable` on `/assets/*`; then by role — `/shared/*` one week (contract code that must be able to change), `/favicon.svg` one day, manifest/robots/sitemap one hour. `/assets/*` is marked immutable although filenames carry no content hash — a known wrinkle.

**Lovetta Lane is a hard contract.** `<nav class="lane" aria-label="Testvéroldalak">` under an `.eyebrow` reading `Lovetta Lane · <the constellation>`. Each entry is an `<a>` with exactly two spans: `.node` (bare hostname, mono, `--step--1`, no protocol, no www) and `.desc` (one line, 0.76rem, `--text-faint`). `href` is the absolute `https://` URL with a trailing slash. A site lists **itself**, marks that entry `aria-current="page"`, styled `--border-strong` plus a ~9% brand tint; all others carry `rel="noopener"`. Grid `repeat(auto-fit, minmax(min(100%, 15rem), 1fr))` at `gap: var(--sp-3)`.

Roster, eight nodes in this order: `bonfire.vaked.dev` (the fire ring), `qwave.vaked.dev` (sovereign WebKit-native macOS browser node), `music.vaked.dev` (sovereign Web Audio synthesis, binaural frequencies), `art.vaked.dev` (visual quantum gallery, braille brain visualizers), `pocoo.vaked.dev/silicon-world/` (Silicon World monograph — note the path), `lovetta.vaked.dev` (autonomous publishing, sovereign patron engine), `store.vaked.dev` (archival vinyl, hoodies, print editions), `axiomquant.org` (nonlinear quantum finance academy — the one non-vaked.dev node).

**Adding a sibling is a constellation-wide edit**: the new node is appended to *every* existing node's lane, and each existing description survives unchanged. The roster is currently out of sync — qwave's grid lists seven (omits itself, includes axiomquant) while bonfire's lane lists eight — so reconcile rather than copying either blindly.

**Within bonfire, the lane and the full head contract are on `index.html` only.** `fire.html:141` and `ash.html:90` carry a reduced `<footer class="site-footer">` with no roster, and their heads carry only `theme-color`, `color-scheme`, robots and the manifest — no canonical, no apple-touch-icon, no `og:`/`twitter:` block. They are the `noindex` pages, so this is probably deliberate; do not "complete" it without asking.

**Head contract (index.html):** `<link rel="canonical">` to the site root; `/favicon.svg` as both `icon` (`image/svg+xml`) and `apple-touch-icon`; `/site.webmanifest`; `theme-color` matching `--bg` as hex (`#16100c`); absolute `og:`/`twitter:` URLs and images on the site's own host with `twitter:card summary_large_image`; one JSON-LD block (`WebSite`, publisher `vaked.dev`). Fonts load with the identical three-line preconnect + single `css2` request with `&display=swap`.

**The ambient layer is mounted from JS, never from HTML.** `site.js initAmbient()` probes with `fetch(SRC, { mode: 'no-cors', cache: 'no-store', signal: AbortSignal.timeout(4000) })` before creating the iframe, because a cross-origin iframe that fails to load renders the browser's own error document — a pale full-viewport slab that washes the fire out. The iframe carries `title=""`, `tabIndex=-1`, `aria-hidden="true"`, `loading="lazy"`, `referrerpolicy="no-referrer"`, 0.25 opacity, and is skipped entirely under `prefers-reduced-motion`.

**`.assetsignore`** keeps repo metadata out of the deployed bundle: `README.md`, `wrangler.toml`, `package.json`, `package-lock.json`, `schema.sql`, `node_modules`, `.assetsignore`. `test/` and `shared/` are **not** listed — `shared/` deliberately ships because the browser imports it.

**Caveat:** `_headers` is a Cloudflare Pages / Netlify format. GitHub Pages ignores it, so `docs/_headers` is aspirational and qwave does not actually ship those headers today. Anything needing the CSP enforced must be on Cloudflare Pages.

---

## 7. Work queue

### bonfire's own ash

The platform eats the medicine it dispenses. `index.html:507-519` states when bonfire itself is done:

1. one fire burns to HAMU and exports its ash capsule,
2. one fire outlives its founder,
3. the lattice holds 1000+ waves,
4. recall p95 < 50 ms,
5. `bonfire.vaked.dev` ships the constellation standards.

**None of 1–4 is met. 5 is met but for one row (O6).** Every item below is in service of that list or of a defect that would make it a lie.

### What this queue can and cannot claim

It covers M5 and all five DoD criteria. It **cannot be shown to cover M2, M3 or M4** — only M1's ash (`README:45`) and M5's (`README:135`) are recorded anywhere in the repo, so nobody can tell whether the middle of the ladder is met, partially met or skipped (O8). Get spec §3 before treating this list as complete.

**Also: §3 is inferred.** Grep confirms the repo cites §1, §2, §4, §5, §6, §7, §8, §9 — §3 appears nowhere. The DoD text above is rendered at `index.html:507-519` and the milestone ladder is referenced in the README, but the section *number* is a positional guess. Every `§3` below is tagged accordingly.

### Send these questions before you start

One message unblocks five items. Ask for:

1. **Spec §3 verbatim** — the milestone ladder (M1–M5 ash sentences) and the DoD. Unblocks O8, confirms O2/O5, and settles whether "§3" is even the right number.
2. **`.al-biruni/mem8/wave_brain.py`** — O7's diff target.
3. **Where the constellation-ops `SKILL.md` lives** — O6 is one table row, blocked purely on file access.
4. **What a pulse actually does** (O1) — §2 lists notifications as a non-goal, so the mechanism must be decided, not guessed.
5. **Capsule immutability vs. the leave promise** (H13) — invariant 10 or the dialog text; one has to give.

**If the user is unavailable, do not block.** Skip the item and record the open question in the README's "Not done" section rather than deciding it yourself. The one exception is H13, because it gates H0: if unreachable, ship H0 with capsule rebuild-on-leave (the build-on-first-request design already supports it) and mark the decision provisional in the README.

### Order

Sorted by **severity ÷ effort, with dependencies overriding**. Read top to bottom.
**W1, W2 and W3 are already fixed** (marked ✅) — start at W4. **The `H`/`W`/`O` IDs are stable survey labels, not positions** — `H0` is not first, and the numbers within each letter are not monotonic. Cite items by ID, follow the page order.

**Dependencies:**

```
H20 + H13  →  H0        (the first .m8 is wrong without them)
H0         →  O2, O3, O5 item 1
H3         →  O4
H7         →  O5 items 3 and 4
H21        →  O5 item 1, O2   (nothing tests functions/ today)
[triggers] in wrangler.toml  →  O2, and O1 if a pulse turns out to be scheduled.
             O2 lands first; it owns adding the block.
H1 + H2 edit the same four files — one pass.
H4 + H5 edit the same function and its call site — one commit.
```

---

### ✅ W1 — `npm test` does not run the tests

> **Already fixed** in the commit that added this document. Left in place for the
> record and so the diff is reviewable; verify with `npm test` and by loading
> `/fire.html`, then move on to W4.

`package.json:13` is `node --test test/`. On Node v22.22.2 the trailing slash makes Node resolve `test/` as a module entry point: `Cannot find module …/test` → 1 test, 0 pass, 1 fail. `node --test "test/**/*.test.js"` → 38 pass, 0 fail. The README calls `npm test` "the wave engine's actual promises" and the commit message rests its spec-conformance claim on those 38 tests — yet the documented command reports failure and verifies nothing.
**No § — engineering defect. Severity: medium. Effort: XS (~10 min).**
**Fix:** `node --test "test/**/*.test.js"`, plus an `engines` field pinning the Node major, since this is version-dependent behaviour rather than a typo. **Wiring it into CI is a separate decision, not ten minutes:** the repo's only pipeline is `.github/workflows/ci.yml` = `qwave-ci`, entirely Swift on macOS runners with no node job. Adding one is a new workflow file — raise it with the user.
**Ash:** *the command in the README is the command that proves the engine.*

---

### ✅ W2 — the ring index renders the literal string „null"

> **Already fixed** in the commit that added this document. Left in place for the
> record and so the diff is reviewable; verify with `npm test` and by loading
> `/fire.html`, then move on to W4.

`site.js:309` interpolates unguarded: `` text: `„${fire.question}"` ``. `fires.question` is nullable, `POST /api/fires` stores `question || null`, `GET /api/fires` returns JSON `null`. Both sibling renderers guard correctly (`fire-room.js:52`, `ash.js:59`). Most-visited page.
**No § — engineering defect. Severity: medium. Effort: XS.**
**Fix:** `fire.question ? el('p', { class: 'fire-question', text: `„${fire.question}”` }) : null` — `el()` already skips null children. Omit the `<p>` rather than rendering empty quotation marks.
**Ash:** *the ring shows a fire's question or nothing at all, never the word "null".*

---

### ✅ W3 — `fire.html:123` terminates its own attribute

> **Already fixed** in the commit that added this document. Left in place for the
> record and so the diff is reviewable; verify with `npm test` and by loading
> `/fire.html`, then move on to W4.

`placeholder="Mire vagy kíváncsi? pl. „csend""` closes with an ASCII double quote inside a double-quoted attribute, so the parser ends the value at „csend and reads a stray attribute named `"`. The same `„…"` mispairing (U+201E opened, ASCII `"` closed, where Hungarian typography wants U+201D) runs through `site.js:309/411`, `fire-room.js:52/274`, `ash.js:59/60` — typographic there, a parse error only here.
**No § — engineering defect. Severity: low. Effort: XS.**
**Fix:** `&quot;` or U+201D in the attribute; fix the JS templates to `„…”` in the same pass.
**Ash:** *the quotation marks close, in the markup and in the prose.*

---

### W4 — the README claims everything is implemented, and it is not
`README:94` opens "Notes on the spec" with *"Everything in §1–§9 is implemented."* O1 contradicts it (pillar 3's mechanism is entirely absent) and H0 contradicts it far more severely (§1's central claim — fires burn to ash — is unreachable by any route). The "Not done" section compounds it: `README:135-138` frames H0 as only M5's missing watcher, saying *"`fires.state` supports HAMU and `/api/ash/:slug` builds and stores the capsule"* — true of the schema and the handler, false of the running system, which can never reach either. H17's principle — *an inaccurate comment about a control is worse than no comment, because the next reader trusts it* — applies with more force to the first file the next reader opens.
**No § — documentation defect. Severity: medium. Effort: XS.**
**Fix:** rewrite `README:94` to name what is not implemented, and rewrite the "Not done" bullet to say HAMU is unreachable by any route, not just unwatched.
**Ash:** *the README's claim about what is implemented is checkable line by line against the code.*

---

### W5 — the `.m8` download is the one response without `nosniff`
`ash/[slug].js:52-60` re-declares `content-type`, `content-disposition`, `cache-control` and `x-robots-tag` by hand rather than inheriting `BASE_HEADERS`, and omits `x-content-type-options: nosniff`. The only response in the product that streams a binary attachment is the only one missing the header invariant 13 claims is universal.
**§9. Severity: medium. Effort: XS.**
**Fix:** add the header, or better, build the object from `BASE_HEADERS` with the two overrides so it cannot drift again.
**Ash:** *every response the API can produce carries the headers the invariant says it does.*

---

### W6 — surface Custodian rule 3's configuration the way the salt is surfaced *(was H18)*
`HARM_TERMS` is optional and unset by default (`wrangler.toml:30-32`), and the sole built-in detector fires only when one token exceeds 60% of a message of 8+ words — which `structuralJitter` and rule 1's fingerprint match already largely catch, and which H5 shows a single period defeats. A deployment following the README exactly ships with **no harm dampening at all**, and the README's setup lists only `IDENTITY_SALT` as required. This is the operational consequence of a deliberate deviation, not a coding error — but the deviation left no visibility behind it.
**§7 rule 3. Severity: medium. Effort: XS.**
**Fix:** add `harm_terms: "configured" | "none"` to `GET /api/health` alongside `identity_salt`.
**Ash:** *an operator can see from /api/health which of the Custodian's rules are actually in force.*

---

### H1 + H2 — the API hands out identity hashes *(do these in one pass — same four files, same serialization path)*

**H1: `/api/ember` leaks another user's `author_hash` on the REINFORCE path.** `ember.js:111-116` returns `wireWave({ ...duplicate, amplitude: boosted })`; `duplicate` is a `SELECT *` row and `wireWave` strips only `wave32`. **Attack:** read the fire page, replay each visible essence back to `/api/ember`, collect one `author_hash` per REINFORCE, and you have an author→embers map for the whole fire — exactly the correlation `fire/[slug].js:34` refuses by hand. It also confirms waves beyond the 200-row display cap.

**H2: `founder_hash` ships on every fire, to everyone.** `fires.js:15-25` and `fire/[slug].js:14-19` do `SELECT f.*`; `ash/[slug].js:20` does `SELECT * FROM fires`; `POST /api/fires` spreads the whole fire object into its 201 body. `founder_hash` comes from the same `identityHash()` as `author_hash`, so it is the same value that identifies that person's embers. One unauthenticated `GET /api/fires` hands an attacker the founder hash of up to 200 fires; combined with H1 it links a founder to their individual embers.

**§7 rule 4 (no harvesting), invariant 6. Severity: high. Effort: S (~1.5 h together).**
**Fix:** move the redaction into `_lib/db.js` as `publicWave(row)` / `publicFire(row)` — strip `wave32`, `author_hash`, `founder_hash`, `fingerprint` — and route `ember.js`, `fires.js`, `fire/[slug].js`, `resonate.js` and `ash/[slug].js` through them, so no future endpoint can forget. Or project columns explicitly (`id, slug, name, question, ash_sentence, pulse, state, created_at, ash_at`). **This governs the client wire only** — server-side queries must keep selecting `fingerprint`, which H3 depends on, and `founder_hash`, which H0's authorship check needs. If the UI ever needs founder awareness, expose a server-computed boolean `is_founder`. While you are in `_lib/db.js`, fix `wireWave`'s stale JSDoc at line 151 (*"blob → hex, plus VAD colour"* — it does the hex only; every caller adds colour separately), so `publicWave` does not inherit an untrue comment.
**Ash:** *a stranger reading every response the API can produce learns nothing about who lit which fire, or who threw which ember — and the only way to serialise a row is through one function that says so.*

---

### H4 + H5 — the harm control does not survive a repost or a period *(one commit — both rewrite `harmfulSignal()` and its call site)*

**H4: rule 1 undoes rule 3.** `ember.js` checks for an exact duplicate at line 94 and returns at line 111 — **before** `harmfulSignal()` runs at line 125. A wave dampened to 0.05× gets `amplitude ×φ`, `decay_tau = max(τ, 90 days)` and `decision = 'REINFORCE'` on every repost. Measured against the real engine (dampen ×0.05, then reinforce ×φ to the 1.0 clamp): **eight reposts**, consistently, at starting amplitudes 0.444, 0.466 and 0.661. With no rate limiting (H6) that is an eight-request bypass of the only harm control in the product, leaving a `custodian_log` full of REINFORCE lines that read as normal activity.

**H5: `harmfulSignal()` reads different text than everything else.** `ember.js:38-56` does `essence.toLowerCase()` and `split(/\s+/)`, not `normaliseEssence()`. `HARM_TERMS` is defeated by any punctuation, accent or zero-width character inserted into a term. The built-in token-flooding check is defeated by varying punctuation: `spam! spam? spam. spam, spam; spam: spam- spam` splits into 8 distinct tokens, `top/words = 0.125`, well under 0.6 — while `normaliseEssence` would collapse it to eight identical tokens and catch it.

**§7 rules 1 and 3. Severity: high. Effort: S (~3 h together).**
**Fix:** run `harmfulSignal()` **before** the duplicate branch, matching against `normaliseEssence(essence)` (normalising each `HARM_TERMS` entry through the same function at parse time) and counting tokens from `normal.split(' ')`. Drop the `words.length >= 8` floor to ~5 — a 7-token flood currently passes unexamined. When harm trips, skip reinforcement entirely and log a `DAMPEN-REPEAT`. Durable version: add `dampened INTEGER NOT NULL DEFAULT 0` to `waves`, set it when rule 3 fires, and make the REINFORCE UPDATE a no-op (or a re-dampen) when it is 1, so the state survives a later change to the term list.
**Ash:** *the Custodian reads the same text the fingerprint reads, and a dampened wave stays dampened however many times it is thrown back into the fire.*

---

### H10 — no `aria-live`, `role="status"` or `role="alert"` anywhere
Verified across all three HTML files: zero occurrences. Every dynamic status is silent to assistive tech — `#ember-result` (the Custodian's verdict on the primary action), `#chair-status`, `#light-fire-status`, `#fire-error`, `#ash-error`, `#lattice-status` (the "you are not on the real lattice" warning), and the wholesale replacement of `#wave-list` on a recall query. A screen-reader user throws an ember and receives no confirmation that it was stored, reinforced or dropped, and never hears the lattice warning at all.
**Files:** `fire.html:55,91,94,116,131`; `index.html:534,576`; `ash.html:52`. **§8. Severity: high. Effort: S (~2 h).**
**Fix:** `role="status"` on `#ember-result`, `#chair-status`, `#light-fire-status`, `#lattice-status`; `role="alert"` on `#fire-error`, `#ash-error`. Have `renderWaves()` announce the result count into a polite region when it replaces the list, and associate `#wave-list` with `#wave-heading` via `aria-labelledby`. **Leave `#hamubol-essence` non-live deliberately** — a quote re-reading itself every 7 seconds would be hostile — and mark that container `aria-hidden`.
**Ash:** *a screen-reader user hears the Custodian's verdict and the lattice warning.*

---

### H20 — the `.m8` will contradict itself the moment capsules become reachable *(prerequisite of H0)*
`buildCapsule` (`shared/capsule.js:26-56`) writes its JSON header from the post-Custodian **columns** — `amplitude`, `decay_tau`, `decision` — while `ash/[slug].js:38-41` passes `w.wave32` through untouched and copies the binary verbatim. On the rule-1 UPDATE, the looping path and the harm path, those columns change and the blob is not re-encoded. So for every dampened wave the capsule says one thing in its header (amplitude 0.03, TEMPORARY) and another in its 32 bytes (the original amplitude, the original decision byte). Custodian rule 3 — *the wave stays, but dampened; memory, never deletion* — does not survive into the artifact designed to outlive the conversation. Same for every ×φ reinforcement. Invariant 14 names the hazard; nothing owned it.
**§4, §7 rule 3, invariant 14. Severity: high. Effort: S–M.**
**Fix:** either re-encode `wave32` on all three mutation paths (`encodeWave32` is isomorphic and available on both sides), or have `buildCapsule` re-encode from the columns at export time. Decide which is authoritative and write it into invariant 14 as a settled rule, not a hazard.
**Ash:** *the 32 bytes in a capsule say the same thing as the header above them, and a wave the Custodian quieted stays quiet in the artifact.*

---

### H13 — `/api/leave` promises "we keep no copy" while a stored capsule keeps the essences verbatim *(prerequisite of H0; product decision)*
`fire-room.js:243` tells the user in the confirm dialog: *"Ez a te döntésed — nem kérdezünk vissza, és nem tartunk másolatot."* `leave.js` deletes from `waves` only. `capsules.m8` embeds every essence as plain text in its JSON header (`shared/capsule.js:46-55`) and stays downloadable at `/api/ash/:slug?format=m8`. `leave.js` also never checks fire state, so a user can withdraw from an ashed fire, be told it worked, and have the artifact still publish their words. **Latent today only because HAMU is unreachable — live the moment H0 ships.**
**§7 rule 5, invariants 9 and 10. Severity: medium. Effort: S.**
**Fix:** on leave, delete the fire's capsule row so it is rebuilt without the withdrawn waves on next request (build-on-first-request already supports this). If capsule immutability wins instead, **say so**: change the dialog text and have `leave.js` return a distinct response for ashed fires rather than a silent success. Ask the user; if unreachable, take rebuild-on-leave and flag it provisional.
**Ash:** *what the leave dialog promises is what the artifact does.*

---

### H0 — nothing can move a fire to HAMU
Grep-verified: the only writers of `fires.state` are `fires.js` (INSERT `'EMBER'`) and `ember.js:187-193` (UPDATE `'PARÁZS'`). Nothing anywhere writes `state='HAMU'` or `ash_at`. Consequences: `GET /api/ash/:slug` 409s for every fire that can actually exist; no `.m8` has ever been built by the running system; `ash.html` is dead except against the seeded local ring; `ash_at` is permanently NULL, so `shared/capsule.js:42` writes `ash_at: null` into every capsule header and `ash.js:62` renders *"hamuvá lett —"*. Coverage: `shared/capsule.js` has three unit tests (`test/wave.test.js:318-362`); **`functions/api/ash/[slug].js` has none of any kind** — nothing under `test/` imports anything from `functions/`. **The product's central claim — fires burn to ash, and that is completion — is unreachable.** There is no founder-driven, no chair-consensus and no manual route; HAMU is reachable only by hand-editing D1.
**§1, §2 pillar 1, §5 `fires.state`, §6. Severity: high. Effort: M (~half a day).**
**Fix:** a founder-authenticated write (e.g. `POST /api/ash/:slug`, checking the caller's hash against `founder_hash`) that sets `state='HAMU'` **and** `ash_at` in the same statement and builds the capsule in one `batch`; a confirm affordance on `fire.html`; a test. Have `buildCapsule` refuse — or fall back to its own `exported_at` — rather than silently emit `ash_at: null` for a fire claiming HAMU. **Land H20 and H13 first**, or the first capsule this produces is wrong in two ways at once.
**Ash:** *a founder can say "the ash sentence is fulfilled", the fire goes cold, and the .m8 that falls out of it carries the date it ended.*

---

### H3 — the Marine gate's novelty signal is inert, and Custodian rule 2 is dead code
`attentionalNovelty()` measures Hamming distance over SHA-256 output. By the avalanche property two distinct inputs differ in ~64 of 128 bits regardless of textual similarity, so the signal barely moves with content.

Measured over 12,000 non-identical probes against a realistic 24-fingerprint window: minimum novelty **0.6250** on a mixed corpus, **0.5938** on natural prose; minimum `gate.score` **0.4320**; a one-character edit scored **0.89–1.00** across trials. Consequences:

- **`phoenix()`'s DROP branch (`score < 0.28`) is unreachable** — 0 firings in 24,000 probes. It needs novelty below ~0.43, i.e. a Hamming distance under 27 of 128 bits between distinct SHA-256 outputs.
- **The TEMPORARY branch (`< 0.5`) is reachable only when low structural jitter coincides with a hash-coincidence dip in novelty.** `score = jitter×0.35 + novelty×0.65`, so with novelty pinned near 1 the branch is unreachable outright; every firing needs *both*. Jitter is content-derived (0.050 for `spam spam spam…`, 0.880 for natural prose), so the rate is entirely corpus-dependent: **105/12,000 on a mixed corpus, 0/12,000 on natural prose.** When it fires on prose it is a coincidence, and the user is told *"Átment, de halkan"* for no reason.
- **`ember.js:120-122`'s `looping` test (`selfNovelty < 0.35`) can never be true** — it needs a distance under 22 of 128 bits, and identical essences are caught by rule 1's fingerprint match first. So the cool-down never runs and no COOLDOWN row is ever written. README and `index.html` both advertise rule 2 as shipped.

Note also that `attentionalNovelty` returns exactly 1 for an empty window (`wave.js:365`), so a fire's opening ember is ungated by construction.
**§7 rule 2, §4 the Marine gate. Severity: high. Effort: M.**
**Fix:** near-duplicate detection needs a locality-sensitive signature, not a cryptographic hash. Add a `simhash TEXT` column to `waves` (64-bit SimHash over normalised word trigrams), compute it in `shared/wave.js` beside `fingerprint()`, index it, and take the Hamming distance over that; keep SHA-256 for exact-duplicate detection only. Cheaper interim: select `essence` alongside `fingerprint` in `ember.js`'s two recent-wave queries and compute token-set Jaccard directly. **Either way re-tune 0.28 / 0.5 afterwards, accounting for jitter's 0.35 contribution as well as novelty's**, and decide what an empty window should score. This touches `shared/wave.js` — respect invariant 3.
**Ash:** *a near-duplicate scores below 0.5 and is told so; the same author looping is caught by the rule the site claims catches it; the custodian_log contains COOLDOWN lines.*

---

### H6 — identity is a droppable cookie, and there is no rate limiting anywhere
`_lib/db.js seat()` mints a fresh random token whenever `bf_chair` is absent, and `authorHash()` hashes that token. A client that sends no cookie gets a brand-new `name_hash` per request: `POST /api/chair` then inserts unbounded rows for any fire — the UNIQUE index on `(fire_id, name_hash)` does not help, because each request carries a different hash. Chairs is the social-proof number on the ring index, drives the canvas glow points, and is the visible measure of a fire's life. The same trick empties the window rule 2 reads and makes `/api/leave` a no-op, so "burning is consent" is only true for users who keep their cookie.

Separately: **no quota, no Turnstile, no KV or Durable Object counter, no bindings for either.** `POST /api/fires`, `/api/ember`, `/api/chair` and `/api/leave` are unauthenticated writes that do not even require a pre-existing cookie, and `GET /api/resonate` is a full-scan endpoint reachable with one unauthenticated GET. **"No accounts" (pillar 2) does not imply "no quota"** — a per-seat and per-IP token bucket is compatible with anonymity.
**§2 pillar 2, §6, §7 rule 4. Severity: high. Effort: M.**
**Fix:** require an already-established seat cookie for `/api/chair` — mint it on a GET (the fire page load) and 400 the POST when no cookie arrived, so taking a seat costs a round trip an attacker must keep state across. Pair it with a KV or DO token bucket in `functions/api/_lib/`, applied in each `onRequestPost`, plus a global cap on fires-per-hour. Neither alone is sufficient.
**Ash:** *a script cannot make a fire look alive, and it cannot fill the lattice — without anyone having to sign up for anything.*

---

### H7 — `/api/resonate`: unindexed full scan, a silent 1000-row correctness cliff, and a fire room that searches everywhere but the fire
`SELECT * FROM waves ORDER BY ts DESC LIMIT 1000` (the unscoped path) has no usable index — `schema.sql` defines `idx_waves_fire (fire_id, ts DESC)`, `idx_waves_fingerprint`, `idx_waves_author` and `idx_waves_frequency`, **none keyed on `ts` alone** — so SQLite scans the table and sorts in a temp B-tree on every query.

Three findings, in descending confidence:
- **Correctness (certain).** Past 1000 waves, φ-resynthesis can only surface the newest 1000, so a REINFORCEd 90-day wave becomes permanently unrecallable no matter how strongly it resonates — the exact inverse of the endpoint's purpose.
- **Scoping (certain).** The fire room always takes the unscoped path: `fire-room.js:272` calls `api.resonate(q)`, `api.js:288` never forwards a `fire` parameter, and results are filtered client-side at `fire-room.js:273`. `idx_waves_fire` is never used for recall at all, and once the lattice holds more than a handful of fires the global top-12 will routinely contain zero waves from the fire the user is sitting at. The user cannot tell "nothing resonates" from "ranked out globally."
- **Cost (measured for ranking, estimated for I/O).** The JS ranking over 1000 rows measured **~1 ms** — that part is fine. The row-set size and deserialisation cost are **modelled, not measured**: roughly 540 kB at a ~90-char average essence and ~1.4 MB at the 1200-char cap (which would cross D1's per-query response limit and turn slowness into 500s), with ~13 ms of CPU just to deserialise. There is no corpus in the repo to measure against (see O5 item 3), so treat these as estimates.

**§6 recall, §3 (inferred) DoD items 3 and 4. Severity: high. Effort: M.**
**Fix, in order:** (a) change `resonate(q)` to `resonate(q, { fire })` and append `&fire=`; drop the client-side filter; mirror the scoping in the local-ring branch. (b) Prefilter in SQL using the band the ranker actually scores — `resonanceScore` only considers `f/φ`, `f`, `f·φ`, so `WHERE frequency BETWEEN ?/(PHI*2) AND ?*(PHI*2)` cuts the candidate set by roughly an order of magnitude and is served by `idx_waves_frequency`, which exists today and is matched by no query in the codebase. (c) `CREATE INDEX idx_waves_ts ON waves (ts DESC)` for the global path. (d) Stop selecting `wave32`; project only `id, frequency, phase_deg, amplitude, decay_tau, ts` for scoring and fetch `essence` for the top-k. Note `phase_deg` is a lossy INTEGER rounding (§3) — check the ranking holds. **Caveat:** dropping `wave32` from the *SQL projection* is safe, but do not drop `wave32_hex` from *wire responses* generally — the local ring reads `w.wave32_hex?.slice(0, 32)` as its fingerprint for duplicate detection (`api.js:237,240`, stored at `:156,:264`) and would break silently, which is H9's failure mode again. (e) Drop the LIMIT to ~300 once the band filter is in. **(f) Then measure, before asserting p95.**
**Ash:** *recall at a fire searches that fire, a wave that resonates is findable however old it is, and there is a benchmark output you can point at instead of a target you hope for.*

---

### H8 — the local-ring fallback silently swallows writes and never says so
This is the exact failure `api.js`'s own header comment promises to prevent: *"A visitor should never be unable to tell whether the lattice is real."*

`withFallback()` treats a 5xx **or any network error** as "the lattice is gone" (`err.status` is `undefined` when `fetch` rejects, so `err.status && err.status < 500` is false), flips `state.live = false`, and runs the local branch. Nothing ever re-probes — `probe()` returns the cached value for the life of the document. `initLatticeBanner()` runs once at boot and never re-renders, so after a demotion the banner stays hidden and the page keeps presenting itself as live. `fire-room.js`'s submit handler never inspects `res.source`, so an ember written to localStorage renders with the identical decision chip and reason as one that reached the lattice — the user believes they posted to the fire and nobody else will ever see it. **Worst case is `createFire`:** a transient 500 produces a local-only fire, `site.js` navigates to `/fire.html?f=<slug>`, that fresh document re-probes cleanly, `getFire()` hits the real lattice and 404s — the user watches their fire be created and then vanish.
**§7 (the Custodian's honesty), invariant 12. Severity: high. Effort: M.**
**Fix:** do not fall back on writes at all — `postEmber` / `createFire` / `takeChair` / `leave` should surface the error and keep the user's text in the box; the local ring is a read-only demo. Give `probe()` a short TTL so a demotion is re-checked. Expose `state.live` as observable and re-render both banners on change. Badge any `source === 'local'` response in the result notice.
**Ash:** *there is no state of the app in which a visitor believes their ember reached the fire when it did not.*

---

### H11 — the landing page issues one request per fire, forever
`site.js initHamubol()` does `fires.map(f => api.getFire(f.slug))` over the full result of `/api/fires`, which returns up to 200 rows — so one `index.html` view can fire up to 200 concurrent `/api/fire/:slug` requests, each running two correlated `COUNT(*)` subqueries and returning up to 200 waves. **One page view = up to 201 D1-backed requests.** It then holds the whole pool in browser memory and re-runs `resynthesise()` over all of it every 7–11 s (the φ-beat: 7000 ms alternating with 7000·φ), forever: the `setTimeout` chain is never cancelled, has no `visibilitychange` teardown (`FireCanvas` has one; this does not), and keeps burning CPU on a backgrounded tab.
**Files:** `site.js:368-453` (pool build 378-389, beat 430-441). **No § — engineering defect. Severity: high. Effort: M.**
**Fix:** add a single sampling endpoint (e.g. `GET /api/embers/recent?n=60` returning decorated waves with their fire name and slug) and call it once. Failing that, cap the fan-out to the first 3–5 fires. Either way store the timer id and clear it on `visibilitychange`/`pagehide`, and cap the pool so `resynthesise()` is not re-ranking tens of thousands of rows on a phone.
**Ash:** *opening the ring costs one request and stops costing anything when the tab is not looked at.*

---

### H14 — `POST /api/fires`: 49 sequential round trips, still racy, and the founder can end up unseated
`fires.js:55-89` issues one SELECT per candidate slug, serially, so a popular name costs ~49 D1 round trips before anything is written. It is also TOCTOU: two concurrent creates with the same name both find the slug free, and the loser's INSERT violates the UNIQUE constraint on `fires.slug` — unhandled, so **the visitor gets a 500 and loses the ash sentence they just wrote.** Separately, the fire INSERT and the founder-chair INSERT are independent statements: if the second fails, the fire exists with nobody seated, contradicting *"the founder is sitting down by definition."*
**No § — engineering defect. Severity: medium. Effort: S.**
**Fix:** replace the loop with a single `INSERT … ON CONFLICT(slug) DO NOTHING` and, on zero rows changed, retry with a short random suffix (2–3 attempts). Put both INSERTs in one `lattice.batch([…])`. Turn any constraint error into a 409 with a usable Hungarian message, never a 500.
**Ash:** *nobody ever loses the ash sentence they just wrote, and a fire never exists with its founder standing outside it.*

---

### H15 — ash capsule build-on-first-request has an unguarded race and reads more than it needs
Two concurrent GETs on a freshly-HAMU fire both find no capsule, both call `buildCapsule()`, and both INSERT; `idx_capsules_fire` is UNIQUE, so the loser throws an unhandled constraint error and the Function returns a bare 500 — for what should be a cache hit. The handler also loads the fire's complete wave history with no LIMIT on every request, including `?format=m8` requests that need no rows once the capsule exists (contrast `fire/[slug].js`, capped at 200).
**Files:** `ash/[slug].js:30-48`. **No § — engineering defect; guards invariant 10. Severity: medium. Effort: S.**
**Fix:** move the capsule lookup above the wave query; on a miss use `INSERT OR IGNORE` followed by a re-SELECT so the loser picks up the winner's row. Short-circuit the wave query when a capsule exists and `format=m8`. Paginate the JSON wave list to match `fire/[slug].js`.
**Ash:** *asking twice for the same ash gets you the same capsule, twice, without an error.*

---

### H12 — no batching or transactions anywhere
Verified: not one `lattice.batch()` call in `functions/`. `POST /api/ember` is 7+ sequential D1 round trips (fire lookup → two parallel fingerprint reads → duplicate lookup → wave INSERT → custodian log → `COUNT(*)` → state UPDATE), each its own implicit transaction — at remote-D1 latency, the dominant cost of the app's primary action. It is also a durability gap: if the isolate dies between the wave INSERT and the `UPDATE fires SET state`, **a fire takes its eighth ember and never becomes PARÁZS**, and nothing ever recomputes it, because the transition is only evaluated while state is already EMBER. `/api/leave` has the same shape, so its reported `removed` count can disagree with what was deleted.
**Files:** `ember.js:157-193`, `leave.js:24-45`. **No § — engineering defect. Severity: medium. Effort: M.**
**Fix:** group each write set into one `lattice.batch([…])` (D1 runs a batch as one transaction). Collapse the PARÁZS check into the same batch as a conditional UPDATE — `UPDATE fires SET state='PARÁZS' WHERE id=? AND state='EMBER' AND (SELECT COUNT(*) FROM waves WHERE fire_id=?) >= 8` — removing both the round trip and the orphaned-transition window.
**Ash:** *a fire that reaches eight embers is PARÁZS, even if the isolate dies mid-write — and every write path is one transaction.*

---

### H16 — PARÁZS is a one-way latch with no recount
`ember.js:186-193` evaluates the transition only while `fire.state === 'EMBER'`, and `/api/leave` deletes waves without recomputing anything. A fire that reaches 8 waves and then has them all withdrawn stays PARÁZS forever — and PARÁZS sorts above every EMBER fire in `GET /api/fires`' ORDER BY, so **an empty fire outranks live ones on the ring index indefinitely and the ring lies about which fires are burning.** The threshold also counts every wave regardless of decision, so eight TEMPORARY or dampened waves promote a fire as readily as eight real ones.
**§5 `fires.state`. Severity: low. Effort: S.**
**Fix:** derive state from the live count in both directions, with a conditional UPDATE in the same batch after leave as well as after ember. Consider counting only STORE/REINFORCE waves toward the threshold, so "burning" means substance rather than volume.
**Ash:** *the ring shows which fires are burning, not which ones once were.*

---

### H17 — `db.js` states a security control that does not exist
`_lib/db.js:52-66` comments *"…it is deliberately obvious, and the API refuses to use it in production."* The API does no such thing: `salt(env)` silently returns the fallback and only `GET /api/health` mentions it, which nothing in the deploy path checks. A deployment that forgets `wrangler pages secret put IDENTITY_SALT` runs on a salt published in the repo, with nothing in the request path objecting.
**§7 rule 4. Severity: low. Effort: S.**
**Fix:** make it true — have the write endpoints return 503 when `usingDevSalt(env)` and the request host is neither localhost nor a `*.pages.dev` preview. Or delete the sentence. **An inaccurate comment about a security control is worse than no comment**, because the next reader trusts it.
**Ash:** *the comment about the salt is either true or gone.*

---

### H19 — `custodian_log` is write-only
Rows are inserted by `ember.js` and `leave.js` and read by nothing — no endpoint, no page, no export. `schema.sql:76-77` states the intent explicitly: *"The Custodian is auditable by design: 'guard, don't direct' is only checkable if the guarding leaves a trace."* Today the trace is unverifiable by anyone including the operator without a D1 shell, so the table is storage cost with no reader.
**§7. Severity: medium. Effort: S.**
**Fix:** a read-only paginated `GET /api/custodian` (`wave_id` redacted; `action` + `reason` + `ts` only) plus a section on `index.html`.
**Ash:** *"guard, don't direct" is a claim a visitor can check.*

---

### H9 — the local ring is a different product, not just different storage
The README claims *"The wave engine is the same code either way — only the storage differs."* The engine is; the Custodian is not. `api.js:231-318`: `takeChair()` increments `fire.chairs` on every click (`api.js:280`) where `/api/chair` is idempotent, so five clicks show 5 chairs; `postEmber()` implements neither rule 2 nor rule 3 and skips the 2/1200-character bounds and the HAMU refusal; `createFire()` skips the ash-length and name-length validation `fires.js` 400s on; `getAsh()` returns `capsule: null` so the ash page silently hides the capsule block rather than explaining why. There is no `custodian_log` locally at all, so "guard, don't direct" is unauditable in exactly the state most first-time visitors meet — while the banner reassures them that *"a kapu és a hullámmotor viszont ugyanaz a kód"* (true of the gate and Phoenix, not of the Custodian).
**§7, invariant 12. Severity: medium. Effort: M.**
**Fix:** either lift the shared rules (length bounds, HAMU refusal, seat idempotency, dampening — `attentionalNovelty` and `dampen` are already pure functions in `shared/wave.js`) into `shared/` so both paths call one implementation, or drop the local ring's write surface entirely and make it read-only. Amend the banner to name which rules are not in force locally, so the claim stays honest either way. **A demo that behaves differently from the product is worse than a demo that says "this needs the lattice."**
**Ash:** *the banner's claim about what is and is not the same code is literally true.*

---

### H21 — nothing tests `functions/`
The 38 tests cover `shared/wave.js` and `shared/capsule.js` only; nothing under `test/` imports anything from `functions/`. Roughly fifteen items in this queue change Workers code, and two more (O5 item 1's *"lights a fire, burns it, re-reads the .m8"*, O2's 30-day-boundary tests) assume a harness that does not exist. §8's verification bar is manual `npm run dev` against a local D1 — fine for a spot check, useless as a regression net.
**No § — infrastructure gap. Severity: medium. Effort: M.**
**Fix:** the cheapest durable option is `wrangler pages dev` + `node --test` integration tests hitting `127.0.0.1` against a `--local` D1 seeded from `schema.sql`, torn down per file; alternatively unstable_dev / miniflare directly. Whatever you choose, it must run offline and must not add a build step to the deployed bundle. Land it before O5 item 1, or that test has nowhere to live.
**Ash:** *there is one command that lights a fire, throws embers at it, burns it to ash and reads the capsule back — and it runs on a laptop with no network.*

---

### O3 — `ash.html` ships but is unreachable
No link anywhere navigates to it. `site.js:304` renders every fire card as `href="/fire.html?f=…"` regardless of state, and `fire-room.js:66-73` merely disables the ember form for a HAMU fire rather than redirecting. The page and `assets/js/ash.js` are correct and functional, reachable only by hand-typing `/ash.html?f=<slug>`.
**§1, §8. Severity: medium. Effort: S (~1 h). Only observable after H0.**
**Fix:** branch the fire card href on `state === 'HAMU'`, and redirect from the fire room.
**Ash:** *a fire that has burnt out takes you to its ash, not to a room you cannot speak in.*

---

### O4 — §7 rule 2 is one third implemented
`ember.js:132-137` sets `decision=TEMPORARY`, `τ=18h` and a prose message — but the very next ember from the same author is accepted immediately, so **no cooling actually occurs**, and the "quiet reintroduction question" (`index.html:451`: *"lehűlés, majd egy csendes újrakezdő kérdés"*) is never generated. The response carries `cooldown: true` (`ember.js:198`) and no client reads it. **Blocked behind H3** — the branch cannot fire at all today.
**§7 rule 2. Severity: medium. Effort: S (~2–3 h after H3).**
**Fix:** a per-author-per-fire timestamp check for a real window, a reintroduction prompt derived from the fire's `question`, and client handling of the `cooldown` flag.
**Ash:** *a loop actually cools, and the fire asks you a quieter question on the way back.*

---

### O2 — the founder-absence job (M5; DoD item 2, "one fire outliving its founder")
Nothing watches for "founder absent 30 days, fire still resonating" and flips the state. **There is no `[triggers]` block in `wrangler.toml` and no scheduled handler anywhere in `functions/` — this item owns adding both.** The README calls it "a deploy-time decision", but the query it needs — `founder_hash`'s `last_seen` vs. now, AND aggregate live amplitude > 0 — does not exist either. `idx_fires_founder` and `idx_chairs_seen` are in place for it; nothing else is.
**§3 (inferred) M5 and DoD item 2; the DoD text is rendered at `index.html:507-519`. §5. Severity: medium. Effort: M (~1 day). Depends on H0 and H21.**
**Ash:** *a fire whose founder walked away 30 days ago and whose embers are still warm keeps burning without them; one whose embers went cold becomes ash on its own.*

---

### O1 — `fires.pulse` is collected, validated, persisted, displayed, and never acted on
The "light a fire" form makes the visitor choose a pulse and the fire card advertises *"napi pulzus"* / *"heti pulzus"* to everyone who sees it. Nothing ever pulses: no scheduled handler, no prompts table, no slot on `fire.html` for today's ember. Of the five pillars this is the only one whose mechanism is entirely absent. **It is worse than omitting the field, because visitors choose fires on the strength of it.**
**§2 pillar 3 (`index.html:191-196`: *"Minden tűznek van pulzusa: napi vagy heti parázs-kérdés"*), §5 `schema.sql:21`, §6. Severity: medium. Effort: M (~1 day).**
**Blocked on a decision:** there is no notification channel and §2 lists notifications as a non-goal, so *what a pulse does* must be settled before it can be built. Likely shape: an on-read or scheduled prompt derived from the fire's `question`, surfaced in the fire room, honouring daily/weekly. If scheduled, it shares O2's `[triggers]` block. **Ask the user; if unreachable, skip and record the question in the README.**
**Ash:** *a fire with a daily pulse shows today's parázs-kérdés, and one with `none` shows nothing.*

---

### O5 — DoD items 1, 3 and 4
**§3 (inferred); the text is at `index.html:507-519`.**

- **Item 1 — one fire burned to HAMU with its capsule exported.** Blocked by H0; needs H20 and H21 too. No capsule has ever been built by the running system; `shared/capsule.js` has three unit tests, `ash/[slug].js` has none. **Effort: S once H0 and H21 land.**
  **Ash:** *there is a `.m8` on disk that came out of a fire this deployment actually burned, and a test that produced it.*
- **Item 3 — 1000+ waves in the lattice.** Never exercised: no seed corpus, no load harness, no fixture beyond the nine seed essences in `api.js:52-62`. The threshold collides with the implementation — `resonate.js:24-25` caps candidates at `LIMIT 1000`, so the exact number the DoD celebrates is where recall stops seeing the whole lattice. **Effort: S for a harness; M if the LIMIT must become real candidate selection (H7).**
  **Ash:** *there is a repeatable command that fills a local lattice past 1000 waves, and recall still sees all of them.*
- **Item 4 — recall p95 < 50 ms.** Nothing measures it: no benchmark, no timing instrumentation, no Server-Timing header, no assertion in the 38 tests. H7's ranking measurement (~1 ms/1000 rows) is the only real number anyone has. **Do not claim this until a seeded benchmark produces it.** **Effort: S once H7 lands.**
  **Ash:** *a committed benchmark prints the p95, and the number in the README is the number it printed.*

---

### O6 — the constellation-ops fleet-map row
bonfire is not added to the constellation-ops `SKILL.md` table. That file is not in this repository and was not reachable from the build. The rest of §9 ships (robots.txt, `_headers`, the Lovetta Lane footer, and bonfire's row in qwave's own sister-site nav at `docs/index.html:1324`). This is the only outstanding piece of DoD item 5.
**§9. Effort: trivial — one table row, blocked purely on file access. Ask where the file lives.**
**Ash:** *bonfire has a row in the fleet map like every other node.*

---

### O7 — the `wave_brain.py` reconciliation
§4 asks for "a direct port"; the engine is spec-derived because the file was unreachable. `shared/wave.js:6-15` documents the open encoding choices inline *"so a later reconciliation pass has something concrete to diff against"* — that diff is an outstanding obligation, not a closed one. The observable contract follows the spec and is covered by the 38 tests, so the risk is confined to what the spec left open: **frequency seeding from the fingerprint, the valence→phase mapping, the τ presets, and the gate's 0.28 / 0.50 thresholds** (which H3 will move anyway).
**§4. Effort: unknown, blocked on file access — ask for `.al-biruni/mem8/wave_brain.py`. S–M once reachable.**
**Ash:** *the diff against wave_brain.py exists and is either empty or documented.*

---

### O8 — the milestone ladder is not auditable
Only two milestones' ash sentences are recorded anywhere: M1's (`README:45`, "index.html live" — met, because the localStorage ring makes the landing page work before D1 exists) and M5's (`README:135`). Nothing pins what M2, M3 or M4 declared done, so a reader cannot tell whether the middle three are met, partially met or skipped — and this queue cannot honestly claim to be complete.
**§3 (inferred) milestones. Effort: trivial once the spec is available; impossible from the repo alone.**
**Fix:** get spec §3, write all five ash sentences into the README, and mark each met/unmet against the code.
**Ash:** *a reader can check all five milestones against the ladder without the spec open.*

---

## 8. Working agreements

- **Preflight before anything else** (§2): `npm install`, confirm the working tree and branch, run the tests with the glob form, and ignore the repo-root `AGENTS.md`.
- **Verify by running.** The strongest findings here (H3, H4's count of eight, H7's ranking figure) came from executing the engine against constructed corpora and measuring, not from reading it. Do the same. Put scratch scripts in the scratchpad directory, never in the repo.
- **Never claim untested work.** Do not report a fix as working because it looks right. Run `node --test "test/**/*.test.js"` (38/38) and, for anything touching the API, `npm run dev` with a local D1. If you cannot exercise something, **say which claims are inferred and which are observed** — and label estimates as estimates, the way H7 now does.
- **Tests must pass, and new promises get new tests.** If you change a threshold (H3) or an encoding (H20), the test that guards it changes with a comment explaining why. Fix `npm test` (W1) before you rely on CI, and note that the repo has no CI for this project (also W1).
- **Document deviations inline the way the existing code does** — `DEVIATION:` above the definition, `NOTE:` for narrower points, `NOTE ON PROVENANCE:` in a file banner — and flag any constant the spec did not specify at its definition. **Then restate it in the README's "Notes on the spec."** The inline notes and the README agree today; they must keep agreeing.
- **The README's "Not done" section is a contract with the next reader.** Close an item, remove it. Find a new gap, add it. Find the README overstating something — it currently does, W4 — fix the prose in the same commit as the code.
- **Do not guess at spec text.** Every `§` above comes from a citation in the code or README **except `§3`, which is inferred from position** — the number appears nowhere in the build. Verify it when you get the spec, and ask for any clause you need verbatim rather than reconstructing it.
- **Ask before deciding product questions**, and send all five questions at once (head of §7). O1 (what a pulse does), H13 (capsule immutability vs. the leave promise), H20 (blob or columns), and any change to the non-goals in `#nem` are the user's calls. **If the user is unavailable, do not block:** skip the item and write the open question into the README's "Not done" section instead of deciding it yourself. The single exception is H13, which has a named safe default so H0 is never gated.
- **Watch for overlapping edits.** H1+H2 touch the same four files and the same serialization path; H4+H5 rewrite the same function and its call site. Each pair is one commit. Done sequentially as separate tasks you will write each file twice and risk reverting the first fix.
- **Commits.** Conventional, scoped to the project: `feat(bonfire): build bonfire.vaked.dev — the fire ring (spec v0.1)` (`4a6468e`). bonfire lives inside `8b-is/qwave`; **do not commit or push unless asked**, and branch first if you are on the default branch. Keep the directory self-contained so `git subtree split --prefix=bonfire.vaked.dev` keeps working.
- **Before any large edit to `shared/wave.js`, confirm the NUL byte survives** (invariant 3): `node -e "const d=require('fs').readFileSync('shared/wave.js');process.exit(d.filter(b=>b===0).length===1?0:1)" && echo NUL-OK`. It is the single easiest thing in this project to destroy by accident, and destroying it orphans every hash in every existing database.
