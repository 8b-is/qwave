/**
 * GET /api/resonate?q= — φ-resynthesis: top-k plus golden-ratio harmonics
 * (spec §6). Ranking lives in shared/wave.js so the client's local ring and
 * the lattice answer the same question the same way.
 */

import { resynthesise, vadColor, vadLabel } from '../../shared/wave.js';
import { json, fail, noLattice, db, nowSec, wireWave } from './_lib/db.js';

export async function onRequestGet({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const url = new URL(request.url);
  const q = (url.searchParams.get('q') ?? '').trim();
  const fireId = url.searchParams.get('fire');
  const topK = Math.min(Math.max(parseInt(url.searchParams.get('k') ?? '12', 10) || 12, 1), 50);

  if (!q) return fail(400, 'Mire vagy kíváncsi? Adj meg egy lekérdezést.');

  // Candidate set. Resonance needs the whole neighbourhood, not a text match —
  // the point of φ-resynthesis is to surface what you did not know to ask for.
  const statement = fireId
    ? lattice.prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts DESC LIMIT 1000').bind(fireId)
    : lattice.prepare('SELECT * FROM waves ORDER BY ts DESC LIMIT 1000');

  const { results = [] } = await statement.all();
  const now = nowSec();
  const hits = await resynthesise(q, results, { topK, nowSeconds: now });

  return json({
    query: q,
    waves: hits.map((row) => {
      const vad = { v: row.vad_v, a: row.vad_a, d: row.vad_d };
      return {
        ...wireWave(row),
        author_hash: undefined,
        color: vadColor(vad),
        label: vadLabel(vad),
      };
    }),
    source: 'lattice',
  });
}
