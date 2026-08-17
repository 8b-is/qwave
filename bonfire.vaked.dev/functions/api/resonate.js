/**
 * GET /api/resonate?q= — φ-resynthesis: top-k plus golden-ratio harmonics
 * (spec §6). Ranking lives in shared/wave.js so the client's local ring and
 * the lattice answer the same question the same way.
 *
 * The candidate set is cut in SQL before ranking: `resonanceScore` only ever
 * scores waves whose frequency sits near the query's f/φ, f or f·φ harmonics,
 * so a band around those frequencies is a complete candidate set — served by
 * idx_waves_frequency, which exists for exactly this query. No full-scan
 * plus-sort, and no text matching either, by design: the point of
 * φ-resynthesis is to surface what you did not know to ask for.
 */

import {
  fingerprint, estimateVAD, deriveWavePhysics, resynthesise, vadColor, vadLabel, PHI,
} from '../../shared/wave.js';
import { json, fail, noLattice, db, nowSec, publicWave } from './_lib/db.js';

export async function onRequestGet({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const url = new URL(request.url);
  const q = (url.searchParams.get('q') ?? '').trim();
  const fireId = (url.searchParams.get('fire') ?? '').trim();
  const topK = Math.min(Math.max(parseInt(url.searchParams.get('k') ?? '12', 10) || 12, 1), 50);

  if (!q) return fail(400, 'Mire vagy kíváncsi? Adj meg egy lekérdezést.');

  // The query's own frequency, derived exactly as the ranker derives it, so
  // the SQL band and the ranking can never disagree about the neighbourhood.
  const fp = await fingerprint(q);
  const vad = estimateVAD(q);
  const query = deriveWavePhysics(q, vad, fp);
  // The harmonics the ranker scores are f/φ, f, f·φ; the band widens that by
  // one octave on each side so no resonant neighbour is cut at the edge.
  const lo = query.frequency / (PHI * 2);
  const hi = query.frequency * (PHI * 2);

  // Project only what the ranker reads plus what the wire needs. The blob is
  // never fetched: scoring runs on frequency, phase, amplitude, τ and ts.
  //
  // Candidate selection is by *frequency proximity*, never by recency: the
  // three harmonics the ranker scores are f/φ, f and f·φ, so the 300
  // candidates closest (in log-distance) to any harmonic are a complete set —
  // and a REINFORCEd 90-day wave cannot be dropped by age, which was the
  // whole failure mode this endpoint was rebuilt against.
  const hLo = query.frequency / PHI;
  const hMid = query.frequency;
  const hHi = query.frequency * PHI;
  const proximity = 'MIN(ABS(LOG(frequency / ?)), ABS(LOG(frequency / ?)), ABS(LOG(frequency / ?)))';

  const statement = fireId
    ? lattice.prepare(`
        SELECT id, fire_id, essence, vad_v, vad_a, vad_d,
               frequency, phase_deg, amplitude, decay_tau, ts
        FROM waves
        WHERE fire_id = ? AND frequency BETWEEN ? AND ?
        ORDER BY ${proximity} LIMIT 300
      `).bind(fireId, lo, hi, hLo, hMid, hHi)
    : lattice.prepare(`
        SELECT id, fire_id, essence, vad_v, vad_a, vad_d,
               frequency, phase_deg, amplitude, decay_tau, ts
        FROM waves
        WHERE frequency BETWEEN ? AND ?
        ORDER BY ${proximity} LIMIT 300
      `).bind(lo, hi, hLo, hMid, hHi);

  const { results = [] } = await statement.all();
  const now = nowSec();
  const hits = await resynthesise(q, results, { topK, nowSeconds: now });

  return json({
    query: q,
    fire: fireId || null,
    waves: hits.map((row) => {
      const vad = { v: row.vad_v, a: row.vad_a, d: row.vad_d };
      return {
        ...publicWave(row),
        color: vadColor(vad),
        label: vadLabel(vad),
      };
    }),
    source: 'lattice',
  });
}
