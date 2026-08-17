/**
 * bonfire — shared helpers for the Pages Functions
 * ============================================================================
 * Identity, responses, and the one-way chair token.
 * ========================================================================== */

import { identityHash } from '../../../shared/wave.js';

/** The lattice binding name (see wrangler.toml). */
export const LATTICE = 'LATTICE';

/* ---------------------------------------------------------------------------
 * Responses
 * ------------------------------------------------------------------------ */

export const BASE_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  // Spec §9: nothing here is cached, and nothing here is training data.
  'cache-control': 'no-store',
  'x-robots-tag': 'noai, noimageai, noindex',
  'x-content-type-options': 'nosniff',
};

export function json(data, init = {}) {
  return new Response(JSON.stringify(data), {
    status: init.status ?? 200,
    headers: { ...BASE_HEADERS, ...(init.headers ?? {}) },
  });
}

export function fail(status, message, extra = {}) {
  return json({ error: message, ...extra }, { status });
}

/** 503 with the shape the client's `probe()` understands. */
export function noLattice() {
  return fail(503, 'A rács nincs bekötve ehhez a példányhoz.', { lattice: 'unbound' });
}

export function db(env) {
  return env?.[LATTICE] ?? null;
}

/* ---------------------------------------------------------------------------
 * Identity — anonymous, but stable enough to reclaim your own flames
 * ------------------------------------------------------------------------ */

const COOKIE = 'bf_chair';

/**
 * The per-deployment salt. Without it, `author_hash` would be a plain hash of
 * a token and anyone holding a database copy could correlate rows across
 * deployments. Set it as a Pages secret:
 *
 *   npx wrangler pages secret put IDENTITY_SALT
 *
 * The fallback exists so local `wrangler pages dev` works out of the box; it
 * is deliberately obvious, and the API refuses to use it in production.
 */
export function salt(env) {
  return env?.IDENTITY_SALT || 'bonfire-dev-salt-do-not-use-in-production';
}

export function usingDevSalt(env) {
  return !env?.IDENTITY_SALT;
}

/**
 * The promise in the comment above, made true: write endpoints refuse to run
 * on the published fallback salt outside of local development or a
 * `*.pages.dev` preview. Returns a 503 when the salt is the dev fallback and
 * the request host is not exempt; null when the request may proceed. An
 * inaccurate comment about a security control is worse than no comment —
 * here the comment and the behaviour agree.
 */
export function guardSalt(env, request) {
  if (!usingDevSalt(env)) return null;
  const host = new URL(request.url).hostname;
  const exempt = host === 'localhost' || host === '127.0.0.1' || host.endsWith('.pages.dev');
  if (exempt) return null;
  return fail(503, 'A telepítés nem állított be egyedi sót. A székek azonosítása fejlesztői módban futna.');
}

function readCookie(request, name) {
  const header = request.headers.get('cookie') || '';
  for (const part of header.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return rest.join('=');
  }
  return null;
}

/** True when the request already carries a seat cookie. Taking a chair is the
 *  social-proof write: minting a fresh identity on the POST would let a script
 *  manufacture unbounded seats, so the seat must exist before the visitor
 *  arrives at the write — the GET that loads the fire page mints it. */
export function hasSeat(request) {
  return readCookie(request, COOKIE) !== null;
}

/**
 * Resolve the caller's opaque seat token, minting one if this is their first
 * time. Returns the token plus a `Set-Cookie` value when a new one was made.
 *
 * The token is a random opaque string in an httpOnly cookie. It never leaves
 * the browser except to this origin, it is never stored raw — only
 * `identityHash(token, salt)` reaches the database — and it carries no
 * personal information, because none was ever collected.
 */
export function seat(request) {
  const existing = readCookie(request, COOKIE);
  if (existing) return { token: existing, setCookie: null };

  const token = crypto.randomUUID().replace(/-/g, '');
  const setCookie = [
    `${COOKIE}=${token}`,
    'Path=/',
    'HttpOnly',
    'Secure',
    'SameSite=Lax',
    `Max-Age=${60 * 60 * 24 * 365}`,
  ].join('; ');

  return { token, setCookie };
}

/** The one-way author hash written to the lattice. */
export async function authorHash(request, env) {
  const { token, setCookie } = seat(request);
  return { hash: await identityHash(token, salt(env)), setCookie };
}

/** Attach a Set-Cookie to a response built by `json()`. */
export function withCookie(response, setCookie) {
  if (!setCookie) return response;
  const headers = new Headers(response.headers);
  headers.append('set-cookie', setCookie);
  return new Response(response.body, { status: response.status, headers });
}

/* ---------------------------------------------------------------------------
 * Misc
 * ------------------------------------------------------------------------ */

export function nowSec() {
  return Math.floor(Date.now() / 1000);
}

/** Waves needed before a fire is properly burning (EMBER → PARÁZS).
 *  Not in the spec — chosen so that EMBER means "just lit" rather than
 *  "empty forever". Shared by the ember and leave paths, which must agree. */
export const PARAZS_THRESHOLD = 8;

export function id() {
  return crypto.randomUUID();
}

/** Parse a JSON body, tolerating an empty or malformed one. */
export async function body(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

/** Write a line to the Custodian's log. Never throws into the request path —
 *  a failure to log must not become a failure to guard. */
export async function logCustodian(lattice, { wave_id = null, action, reason }) {
  try {
    await lattice
      .prepare('INSERT INTO custodian_log (id, wave_id, action, reason, ts) VALUES (?, ?, ?, ?, ?)')
      .bind(id(), wave_id, action, reason, nowSec())
      .run();
  } catch {
    /* the guard keeps guarding */
  }
}

/** Convert a D1 wave row's blob to hex for the wire. Callers that need VAD
 *  colour/label add them separately. Prefer `publicWave` for client responses. */
export function wireWave(row) {
  const { wave32, ...rest } = row;
  return {
    ...rest,
    wave32_hex: wave32 ? bytesToHex(new Uint8Array(wave32)) : null,
  };
}

/* ---------------------------------------------------------------------------
 * Wire redaction (§7 rule 4) — the client-facing serialisation of rows
 * ------------------------------------------------------------------------ */

/** A wave row as the client is allowed to see it. Strips the blob, its hex
 *  (which embeds the fingerprint), the content fingerprint, and the author's
 *  one-way hash. Every endpoint serialises through this so no future handler
 *  can leak them by forgetting. */
export function publicWave(row) {
  const {
    wave32, wave32_hex, fingerprint, author_hash, founder_hash, ...rest
  } = row;
  return rest;
}

/** A fire row as the client is allowed to see it. Strips the founder's
 *  one-way hash — the same value that identifies that person's embers. */
export function publicFire(row) {
  const { founder_hash, ...rest } = row;
  return rest;
}

function bytesToHex(bytes) {
  let out = '';
  for (const b of bytes) out += b.toString(16).padStart(2, '0');
  return out;
}
