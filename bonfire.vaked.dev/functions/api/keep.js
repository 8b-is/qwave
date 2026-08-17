/**
 * POST|GET /api/keep — the founder-absence keeper (spec §3, M5).
 *
 * "A fire is DONE when it outlives its founder: founder absent 30 days, fire
 * still resonating." This endpoint applies the rule:
 *
 *   - founder's chair untouched for ≥ 30 days and the fire's aggregate live
 *     amplitude is still warm → the fire keeps burning without them;
 *   - founder absent ≥ 30 days and the embers went cold → the fire burns
 *     itself to ash, capsule and all.
 *
 * Cloudflare Pages Functions have no scheduled handler (no [triggers] key in
 * the Pages wrangler config), so this is an HTTP keeper: any external cron —
 * a Worker, an uptime monitor, a deploy hook — POSTs it on a schedule. It is
 * safe to call at any time and from anywhere: every transition it makes is a
 * fact already true in the lattice, so an early call is a no-op, and every
 * call is idempotent.
 */

import { buildCapsule } from '../../shared/capsule.js';
import { effectiveAmplitude } from '../../shared/wave.js';
import { json, noLattice, db, nowSec, id, logCustodian } from './_lib/db.js';

/** Founder absence that makes a fire "outlive its founder" (spec §3). */
const ABSENCE_DAYS = 30;
const ABSENCE_SECONDS = ABSENCE_DAYS * 86400;

/** "Still resonating" needs a number. Not in the spec — chosen so that one
 *  ordinary STORE wave (τ = 30 d) a month old still counts as warm, while a
 *  fire whose only waves have fully decayed falls below it. */
const WARM_FLOOR = 0.05;

export async function onRequestGet(ctx) { return keep(ctx); }
export async function onRequestPost(ctx) { return keep(ctx); }

async function keep({ env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const now = nowSec();

  // The founder's chair is their only activity record: last_seen is the last
  // time they sat at their own fire.
  const { results: candidates = [] } = await lattice.prepare(`
    SELECT f.*, c.last_seen AS founder_seen
    FROM fires f
    JOIN chairs c ON c.fire_id = f.id AND c.name_hash = f.founder_hash
    WHERE f.state IN ('EMBER', 'PARÁZS')
      AND c.last_seen < ?
  `).bind(now - ABSENCE_SECONDS).all();

  const actions = [];

  for (const fire of candidates) {
    const { results: waves = [] } = await lattice
      .prepare('SELECT amplitude, decay_tau, ts FROM waves WHERE fire_id = ?')
      .bind(fire.id).all();

    const absentDays = Math.floor((now - fire.founder_seen) / 86400);
    const alive = waves.reduce((sum, w) => sum + effectiveAmplitude(w, now), 0);

    if (alive >= WARM_FLOOR) {
      // Still resonating: it keeps burning without its founder (spec §3).
      if (fire.state === 'EMBER') {
        await lattice.prepare(`UPDATE fires SET state = 'PARÁZS' WHERE id = ? AND state = 'EMBER'`)
          .bind(fire.id).run();
        await logCustodian(lattice, {
          action: 'FOUNDER-ABSENT-KEEP',
          reason: `founder absent ${absentDays}d; aggregate live amplitude ${alive.toFixed(4)} ≥ ${WARM_FLOOR}`,
        });
        actions.push({ slug: fire.slug, state: 'PARÁZS', decision: 'keep' });
      }
    } else {
      // Embers cold: the fire becomes ash on its own.
      const { results: all = [] } = await lattice
        .prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts ASC')
        .bind(fire.id).all();

      const ashAt = now;
      const bytes = buildCapsule(
        { ...fire, state: 'HAMU', ash_at: ashAt },
        all.map((w) => ({ ...w, wave32: new Uint8Array(w.wave32) })),
      );

      await lattice.batch([
        lattice.prepare(`UPDATE fires SET state = 'HAMU', ash_at = ? WHERE id = ? AND state != 'HAMU'`)
          .bind(ashAt, fire.id),
        lattice.prepare('INSERT OR IGNORE INTO capsules (id, fire_id, m8, exported_at) VALUES (?, ?, ?, ?)')
          .bind(id(), fire.id, bytes, ashAt),
      ]);

      await logCustodian(lattice, {
        action: 'FOUNDER-ABSENT-ASH',
        reason: `founder absent ${absentDays}d; aggregate live amplitude ${alive.toFixed(4)} < ${WARM_FLOOR}`,
      });
      actions.push({ slug: fire.slug, state: 'HAMU', decision: 'ash' });
    }
  }

  return json({ kept: actions, source: 'lattice' });
}
