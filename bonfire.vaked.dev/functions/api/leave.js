/**
 * POST /api/leave — a chair removes its own waves.
 *
 * Spec §6 and §7 rule 5, and the Council's third answer: burning is consent,
 * and an ember may always take back its own flame. This is the one place in
 * bonfire where deletion is real, because it is the ember's decision and not
 * ours. The seat itself stays: you were there.
 */

import {
  json, fail, noLattice, db, nowSec, body, authorHash, withCookie, logCustodian,
} from './_lib/db.js';

export async function onRequestPost({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const payload = await body(request);
  const fireId = String(payload?.fire_id ?? '').trim();
  if (!fireId) return fail(400, 'Melyik tűzről?');

  const { hash, setCookie } = await authorHash(request, env);

  const { results = [] } = await lattice
    .prepare('SELECT id FROM waves WHERE fire_id = ? AND author_hash = ?')
    .bind(fireId, hash).all();

  if (!results.length) {
    return withCookie(json({ removed: 0, source: 'lattice' }), setCookie);
  }

  await lattice
    .prepare('DELETE FROM waves WHERE fire_id = ? AND author_hash = ?')
    .bind(fireId, hash).run();

  // Logged without the wave ids' content and without the author hash: the
  // record says a flame was taken back, not whose or what it said.
  await logCustodian(lattice, {
    action: 'LEAVE',
    reason: `${results.length} wave(s) withdrawn by their author from fire ${fireId}`,
  });

  await lattice
    .prepare('UPDATE chairs SET last_seen = ? WHERE fire_id = ? AND name_hash = ?')
    .bind(nowSec(), fireId, hash).run();

  return withCookie(json({ removed: results.length, source: 'lattice' }), setCookie);
}
