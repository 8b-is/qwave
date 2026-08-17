/**
 * bonfire — per-IP write quotas
 * ============================================================================
 * "No accounts" (spec §2 pillar 2) does not mean "no quota": a per-IP fixed
 * window counter is compatible with anonymity and keeps a script from
 * filling the lattice or making a fire look alive. Keys are salted one-way
 * hashes of the visitor's IP — the raw address never reaches D1 (§7 rule 4).
 * ========================================================================== */

import { identityHash } from '../../../shared/wave.js';
import { nowSec, salt } from './db.js';

/** Write quotas, per action, per IP. Not in the spec — the spec bans
 *  accounts, not quotas; these exist so an anonymous script cannot inflate
 *  chairs or fill the lattice, while a human by a fire never notices. */
export const QUOTAS = Object.freeze({
  fire: { windowSec: 3600, max: 3 },
  ember: { windowSec: 3600, max: 30 },
  chair: { windowSec: 3600, max: 10 },
  leave: { windowSec: 3600, max: 10 },
});

/** A stable, salted key for a visitor *and an action*. The IP is hashed
 *  together with the action name before it is stored, so the quotas table
 *  holds no addresses and one action's bucket never leaks into another's. */
export async function clientKey(request, env, action) {
  const ip = (request.headers.get('cf-connecting-ip')
    || request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    || 'unknown').trim();
  return identityHash(`${ip}\u0000${action}`, salt(env));
}

/**
 * Fixed-window counter. Returns true when the caller may proceed. The row is
 * written either way, so an over-quota caller keeps paying for the spam
 * instead of getting a fresh window for free.
 */
export async function checkQuota(lattice, key, { windowSec = 3600, max }) {
  const window = Math.floor(nowSec() / windowSec);
  const row = await lattice.prepare(`
    INSERT INTO quotas (key, window, count) VALUES (?, ?, 1)
    ON CONFLICT(key) DO UPDATE SET
      count  = CASE WHEN window = excluded.window THEN count + 1 ELSE 1 END,
      window = excluded.window
    RETURNING count
  `).bind(key, window).first();
  return (row?.count ?? 1) <= max;
}
