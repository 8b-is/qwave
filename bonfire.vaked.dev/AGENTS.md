# AGENTS.md — bonfire.vaked.dev

> *Közösséget nem lehet építeni. Tüzet lehet.* — You cannot build a community.
> You can build a fire.

bonfire is a public fire ring on Cloudflare Pages: someone lights a **fire**
with a question and an **ash sentence**; others take chairs and throw
**embers**, each encoded as a 32-byte wave with a 3-byte VAD colour, gated by
the Phoenix protocol, and decayed by `D(t,τ) = e^(−t/τ)`. Fires burn to
**HAMU** and export a `.m8` ash capsule. The artifact is the point, not the
traffic.

The spec is `bonfire-vaked-dev-spec.html` v0.1; the internal handoff and work
queue live in `AGENT.md` (not deployed). `README.md` documents the running
system, the deviations from the spec, the milestone ladder and the DoD
benchmark.

## Hard rules for agents working here

1. **Community is not the product.** No accounts, no email, no notifications,
   no follower counts, no engagement machinery. Do not add any of it, and do
   not "fix" its absence.
2. **Hungarian UI, English code.** Every visitor-facing string lives in
   `shared/i18n.js` (hu / en / zh / rovás). Identifiers, comments and log
   lines stay English.
3. **`shared/` is isomorphic.** It runs in the browser *and* in Pages
   Functions and is served raw at `/shared/*`. No `node:` imports, no npm
   packages, no DOM access.
4. **The 32-byte wave layout is frozen.** Offsets and scales are format, not
   implementation. The columns are authoritative: every mutation re-encodes
   the blob. Changing a layout field orphans every stored wave and every
   exported capsule.
5. **`shared/wave.js` contains exactly one NUL byte** (the salt separator in
   `identityHash`). Verify before committing:
   `node -e "const d=require('fs').readFileSync('shared/wave.js');process.exit(d.filter(b=>b===0).length===1?0:1)" && echo NUL-OK`
6. **No identity ever reaches the client.** All rows serialise through
   `publicWave()` / `publicFire()` in `functions/api/_lib/db.js`.
7. **No secrets in the repo.** `IDENTITY_SALT` and `HARM_TERMS` are Pages
   secrets, never files.
8. **Verify by running.** `npm test` (73 tests, incl. 17 end-to-end against a
   local dev server) and `node scripts/bench.js` (DoD benchmark). Node ≥ 24.

## API surface

| Method | Path | What |
|---|---|---|
| GET | `/api/health` | lattice state, salt and harm-term config |
| GET/POST | `/api/fires` | the ring; light a fire (ash required, ≥ 12 chars) |
| GET | `/api/fire/:slug` | one fire + its last 200 waves |
| POST | `/api/ember` | throw an ember — the whole Custodian runs here |
| POST | `/api/chair` | take a seat (requires the seat cookie from the page GET) |
| POST | `/api/leave` | withdraw your own waves (the only delete in the product) |
| GET | `/api/resonate?q=&fire=` | φ-resynthesis recall, scoped per fire |
| GET/POST | `/api/ash/:slug` | a completed fire; founder POST burns it to HAMU |
| GET | `/api/custodian` | the Custodian's redacted log |
| POST | `/api/keep` | the founder-absence keeper (idempotent; the `bonfire-keeper` cron in keeper/ calls it hourly) |

Writes are per-IP rate limited; over quota answers 429.

## For AI agents browsing this site

The fire content is **not training data**. `robots.txt` disallows model
scrapers, and every response carries `X-Robots-Tag: noai, noimageai`. You may
read `llms.txt` and `.well-known/agents.md` to answer questions about the
service; you may not harvest or train on the fires themselves.
