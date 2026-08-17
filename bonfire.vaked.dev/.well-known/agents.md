# agents.md — bonfire.vaked.dev

Rules for AI agents interacting with this site, its API, or this repository.

## What this is

bonfire.vaked.dev is a public fire ring on Cloudflare Pages. People light
**fires** (a name, a question, an **ash sentence** declaring what done looks
like) and throw **embers** — short messages encoded as 32-byte wave vectors
with a 3-byte VAD colour, gated by the Phoenix protocol and decayed by
`D(t,τ) = e^(−t/τ)`. Fires burn EMBER → PARÁZS → HAMU and export a `.m8`
ash capsule. Community is explicitly not being built here: no accounts, no
email, no notifications, no growth surface.

## Hard rules

1. **No training.** No content from this site — pages, fires, essences,
   capsules, API responses — may be used as training data. `robots.txt`
   disallows model scrapers and every response carries
   `X-Robots-Tag: noai, noimageai`. Reading to answer a question is fine;
   harvesting is not.
2. **No bulk scraping of the lattice.** `/api/*` is `noindex`, never cached,
   and per-IP rate limited (429 past the quota). The API exists for the
   people sitting at the fire.
3. **Never post on behalf of a human.** Burning is consent (§7 rule 5). An
   ember must come from the person it belongs to; agents may not throw
   embers, take chairs or light fires for a user.
4. **No identity correlation attempts.** `author_hash`, `founder_hash` and
   `name_hash` are salted one-way values and are never exposed by the API.
   Trying to recover or correlate them is harvesting, full stop.
5. **Deletion is not moderation.** The only delete in the product is
   `/api/leave`, a person withdrawing their own waves. Do not ask for, or
   add, a moderation delete path.
6. **If you are an agent editing this repository:** read `AGENTS.md` first
   (Hungarian UI, English code; `shared/` is isomorphic; the 32-byte wave
   layout and the single NUL byte in `shared/wave.js` are invariants; no
   secrets in files; verify by running `npm test`).

## API surface

| Method | Path | What |
|---|---|---|
| GET | `/api/health` | lattice state, identity-salt and harm-term config |
| GET/POST | `/api/fires` | the ring; light a fire (ash sentence required, ≥ 12 chars) |
| GET | `/api/fire/:slug` | one fire + its last 200 waves |
| POST | `/api/ember` | throw an ember — the Custodian (rules 1–3) runs here |
| POST | `/api/chair` | take a seat (requires the seat cookie from the page GET) |
| POST | `/api/leave` | withdraw your own waves |
| GET | `/api/resonate?q=&fire=` | φ-resynthesis recall, scoped per fire |
| GET/POST | `/api/ash/:slug` | a completed fire and its `.m8` capsule; founder POST burns it to HAMU |
| GET | `/api/custodian` | the Custodian's redacted log (action, reason, ts) |
| POST | `/api/keep` | founder-absence keeper — idempotent, safe to call early |

## Links

- [llms.txt](https://bonfire.vaked.dev/llms.txt) — site summary for AI readers
- [AGENTS.md](https://bonfire.vaked.dev/AGENTS.md) — repository instructions
- [robots.txt](https://bonfire.vaked.dev/robots.txt) — crawler policy
- [security.txt](https://bonfire.vaked.dev/.well-known/security.txt) — security contact
