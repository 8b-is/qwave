/**
 * POST /api/leave — a chair removes its own waves.
 *
 * Spec §6 and §7 rule 5, and the Council's third answer: burning is consent,
 * and an ember may always take back its own flame. This is the one place in
 * bonfire where deletion is real, because it is the ember's decision and not
 * ours. The seat itself stays: you were there.
 *
 * If the fire already burned to ash, its capsule is deleted too, so the next
 * request rebuilds it without the withdrawn waves — "we keep no copy" must
 * hold in the artifact as well as in the lattice (§7 rule 5).
 */

import {
  json, fail, noLattice, db, nowSec, body, authorHash, withCookie, logCustodian,
  PARAZS_THRESHOLD, guardSalt,
} from './_lib/db.js';
import { QUOTAS, checkQuota, clientKey } from './_lib/rate.js';

export async function onRequestPost({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const noSalt = guardSalt(env, request);
  if (noSalt) return noSalt;

  const payload = await body(request);
  const fireId = String(payload?.fire_id ?? '').trim();
  if (!fireId) return fail(400, 'Melyik tűzről?');

  if (!(await checkQuota(lattice, await clientKey(request, env, 'leave'), QUOTAS.leave))) {
    return fail(429, 'Túl gyorsan. A tűz nem siet, te se.');
  }

  const { hash, setCookie } = await authorHash(request, env);

  const { results = [] } = await lattice
    .prepare('SELECT id FROM waves WHERE fire_id = ? AND author_hash = ?')
    .bind(fireId, hash).all();

  if (!results.length) {
    return withCookie(json({ removed: 0, source: 'lattice' }), setCookie);
  }

  // One transaction: withdraw the waves, drop the stale capsule, and recount
  // the fire's state. A PARÁZS fire that falls below the threshold is EMBER
  // again — the ring must show which fires are burning, not which once were.
  await lattice.batch([
    lattice.prepare('DELETE FROM waves WHERE fire_id = ? AND author_hash = ?')
      .bind(fireId, hash),
    lattice.prepare('DELETE FROM capsules WHERE fire_id = ?').bind(fireId),
    lattice.prepare(`
      UPDATE fires SET state = 'EMBER'
      WHERE id = ? AND state = 'PARÁZS'
        AND (SELECT COUNT(*) FROM waves WHERE fire_id = ?) < ?
    `).bind(fireId, fireId, PARAZS_THRESHOLD),
    lattice.prepare('UPDATE chairs SET last_seen = ? WHERE fire_id = ? AND name_hash = ?')
      .bind(nowSec(), fireId, hash),
  ]);

  // Logged without the wave ids' content and without the author hash: the
  // record says a flame was taken back, not whose or what it said.
  await logCustodian(lattice, {
    action: 'LEAVE',
    reason: `${results.length} wave(s) withdrawn by their author from fire ${fireId}`,
  });

  return withCookie(json({ removed: results.length, source: 'lattice' }), setCookie);
}
