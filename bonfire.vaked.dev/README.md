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
npm install

# 1. Create the lattice and put its id in wrangler.toml
npm run db:create

# 2. Apply the schema (spec §5)
npm run db:local      # local dev
npm run db:remote     # production

# 3. Salt the one-way identity hashes — required in production (spec §7 rule 4)
npx wrangler pages secret put IDENTITY_SALT

# 4. Run / deploy
npm run dev
npm run deploy

# Tests — the wave engine's actual promises
npm test
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
shared/wave.js          the wave engine — isomorphic, runs in Workers and the browser
shared/capsule.js       the .m8 ash capsule format (documented at the top of the file)
functions/api/*         Pages Functions — the seven endpoints of spec §6, plus /api/health
assets/js/fire-canvas.js  the fire, the chairs, the ripples
assets/css/bonfire.css  "Ember & Ash" — the design system
schema.sql              the lattice (spec §5)
test/wave.test.js       38 tests over the engine
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

§1–§9 is implemented except where **Not done** below says otherwise. Two
omissions are structural, not cosmetic: pillar 3's pulse mechanism (§2) is
collected, validated, persisted and displayed but never acted on, and no code
path moves a fire to HAMU (§1, §6) — the ash capsule, the spec's central
completion artifact, is unreachable in the running system. Six things are
worth calling out, because they are places where this build made a decision
the spec did not:

1. **The fingerprint is SHA-256, not MD5.** The spec labels the 16-byte field
   `md5`. Web Crypto in Workers has no MD5, and the field is only ever a
   content fingerprint for duplicate detection — never a checksum anyone else
   validates — so it is SHA-256 truncated to 16 bytes. Same width, same role,
   no hand-rolled crypto.

2. **The engine is spec-derived, not transliterated.**
   `.al-biruni/mem8/wave_brain.py` was not reachable from the build
   environment, so `shared/wave.js` was written from the spec's description of
   the contract. Encoding choices the spec left open are documented inline so a
   later reconciliation pass has something concrete to diff against.

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

### Not done

- **The fleet-map row** (§9: "add bonfire row to the constellation-ops
  SKILL.md table"). That file is not in this repository, so the row has not
  been added. The rest of §9 — anti-AI `robots.txt`, `_headers` with CSP and
  `X-Robots-Tag: noai`, the Lovetta Lane footer with bonfire in the sister-site
  nav — ships here.
- **No code path writes HAMU.** `fires.state` supports HAMU and
  `/api/ash/:slug` builds and stores the capsule, but nothing sets the state —
  a fire cannot reach its ash by any route today, so no `.m8` has ever been
  built by the running system. See the `H0` survey item.
- **M5's founder-absence job.** Nothing yet *watches* for "founder absent
  30 days, fire still resonating" and flips the state. That wants a Cron
  Trigger, which is a deploy-time decision.
- **Pillar 3's pulse mechanism.** `fires.pulse` is collected, validated,
  persisted and displayed; nothing ever pulses. What a pulse *does* — the
  spec (§2) calls it a daily or weekly ember-prompt, with notifications an
  explicit non-goal — is an open product decision, tracked as `O1`.

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
