/**
 * GET /api/fire/:slug — the fire, plus its top resonating waves with decay
 * already applied (spec §6).
 */

import { vadColor, vadLabel, effectiveAmplitude } from '../../../shared/wave.js';
import {
  json, fail, noLattice, db, nowSec, publicWave, publicFire, authorHash, withCookie,
} from '../_lib/db.js';

export async function onRequestGet({ params, request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const slug = String(params.slug ?? '');
  const fire = await lattice.prepare(`
    SELECT f.*,
           (SELECT COUNT(*) FROM waves  w WHERE w.fire_id = f.id) AS waves,
           (SELECT COUNT(*) FROM chairs c WHERE c.fire_id = f.id) AS chairs
    FROM fires f WHERE f.slug = ?
  `).bind(slug).first();

  if (!fire) return fail(404, 'Nincs ilyen tűz.');

  // Loading a fire page establishes the anonymous seat; the chair POST below
  // requires it rather than minting one per request (see api/chair.js). The
  // founder check is a server-computed boolean: the hash itself never ships.
  const { hash, setCookie } = await authorHash(request, env);

  // `?before=<ts>&before_id=<id>` walks back through the lattice: the last
  // 200 waves by default, the 200 before a cursor otherwise. The cursor is
  // (ts, id) because several embers can share a second — ts alone would
  // repeat or skip rows.
  const url = new URL(request.url);
  const before = Number(url.searchParams.get('before'));
  const beforeId = String(url.searchParams.get('before_id') ?? '');
  const statement = Number.isFinite(before) && before > 0 && beforeId
    ? lattice.prepare(`
        SELECT * FROM waves
        WHERE fire_id = ? AND (ts < ? OR (ts = ? AND id < ?))
        ORDER BY ts DESC, id DESC LIMIT 200
      `).bind(fire.id, before, before, beforeId)
    : lattice.prepare(`
        SELECT * FROM waves
        WHERE fire_id = ? ORDER BY ts DESC, id DESC LIMIT 200
      `).bind(fire.id);

  const { results = [] } = await statement.all();

  const now = nowSec();
  const waves = results.map((row) => {
    const vad = { v: row.vad_v, a: row.vad_a, d: row.vad_d };
    return {
      ...publicWave(row),
      color: vadColor(vad),
      label: vadLabel(vad),
      alive: Number(effectiveAmplitude(row, now).toFixed(4)),
    };
  });

  // A full page means the lattice may hold more; the room appends until the
  // oldest ember answers.
  const next_before = results.length === 200 ? results[199].ts : null;
  const next_before_id = results.length === 200 ? results[199].id : null;

  return withCookie(json({
    fire: { ...publicFire(fire), is_founder: hash === fire.founder_hash },
    waves,
    next_before,
    next_before_id,
    source: 'lattice',
  }), setCookie);
}
