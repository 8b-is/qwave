/**
 * GET /api/fire/:slug — the fire, plus its top resonating waves with decay
 * already applied (spec §6).
 */

import { vadColor, vadLabel, effectiveAmplitude } from '../../../shared/wave.js';
import { json, fail, noLattice, db, nowSec, wireWave } from '../_lib/db.js';

export async function onRequestGet({ params, env }) {
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

  const { results = [] } = await lattice
    .prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts DESC LIMIT 200')
    .bind(fire.id).all();

  const now = nowSec();
  const waves = results.map((row) => {
    const vad = { v: row.vad_v, a: row.vad_a, d: row.vad_d };
    return {
      ...wireWave(row),
      // Never ship the author hash to the client. It is one-way, but it is
      // still a correlation handle across a fire, and nothing in the UI needs it.
      author_hash: undefined,
      color: vadColor(vad),
      label: vadLabel(vad),
      alive: Number(effectiveAmplitude(row, now).toFixed(4)),
    };
  });

  return json({ fire, waves, source: 'lattice' });
}
