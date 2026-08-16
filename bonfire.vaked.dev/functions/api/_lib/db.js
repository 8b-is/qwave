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

function readCookie(request, name) {
  const header = request.headers.get('cookie') || '';
  for (const part of header.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return rest.join('=');
  }
  return null;
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

/** Normalise a D1 wave row for the wire: blob → hex, plus VAD colour. */
export function wireWave(row) {
  const { wave32, ...rest } = row;
  return {
    ...rest,
    wave32_hex: wave32 ? bytesToHex(new Uint8Array(wave32)) : null,
  };
}

function bytesToHex(bytes) {
  let out = '';
  for (const b of bytes) out += b.toString(16).padStart(2, '0');
  return out;
}
