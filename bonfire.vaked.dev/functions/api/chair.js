/**
 * POST /api/chair — take a seat (spec §6).
 *
 * Pillar 2: anonymous seats, no account wall. One click = you sit. The seat is
 * keyed by a one-way hash of an opaque cookie token, so sitting down twice is
 * idempotent without anyone learning who you are.
 *
 * The cookie must already exist — the GET that loads the fire page mints it.
 * Minting on the POST instead would hand every cookie-less request a fresh
 * identity and a new chair row, and chairs are the number the ring shows.
 */

import {
  json, fail, noLattice, db, nowSec, id, body, authorHash, withCookie, guardSalt,
  hasSeat,
} from './_lib/db.js';
import { QUOTAS, checkQuota, clientKey } from './_lib/rate.js';

export async function onRequestPost({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const noSalt = guardSalt(env, request);
  if (noSalt) return noSalt;

  const payload = await body(request);
  const fireId = String(payload?.fire_id ?? '').trim();
  if (!fireId) return fail(400, 'Melyik tűzhöz ülsz le?');

  // Seats are established on a GET, never on the write that uses them.
  if (!hasSeat(request)) {
    return fail(400, 'Még nincs széked. Töltsd újra az oldalt, aztán ülj le.');
  }

  if (!(await checkQuota(lattice, await clientKey(request, env, 'chair'), QUOTAS.chair))) {
    return fail(429, 'Túl gyorsan. A tűz nem siet, te se.');
  }

  const fire = await lattice.prepare('SELECT id, state FROM fires WHERE id = ?').bind(fireId).first();
  if (!fire) return fail(404, 'Nincs ilyen tűz.');

  const { hash, setCookie } = await authorHash(request, env);
  const ts = nowSec();

  const existing = await lattice
    .prepare('SELECT id FROM chairs WHERE fire_id = ? AND name_hash = ?')
    .bind(fireId, hash).first();

  if (existing) {
    await lattice.prepare('UPDATE chairs SET last_seen = ? WHERE id = ?').bind(ts, existing.id).run();
  } else {
    await lattice.prepare(`
      INSERT INTO chairs (id, fire_id, name_hash, joined_at, last_seen) VALUES (?, ?, ?, ?, ?)
    `).bind(id(), fireId, hash, ts, ts).run();
  }

  const { chairs } = await lattice
    .prepare('SELECT COUNT(*) AS chairs FROM chairs WHERE fire_id = ?').bind(fireId).first();

  return withCookie(json({
    chair_id: existing?.id ?? null,
    chairs,
    seated: true,
    source: 'lattice',
  }), setCookie);
}
