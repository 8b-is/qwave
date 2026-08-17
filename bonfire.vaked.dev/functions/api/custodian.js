/**
 * GET /api/custodian — the Custodian's own trace (spec §7).
 *
 * "Guard, don't direct" is only checkable if the guarding leaves a trace.
 * The write paths leave one; this is its reader. Read-only, paginated, and
 * redacted: wave ids never leave the lattice, and an action's reason carries
 * no essence text — the log says what was guarded, never whose or what.
 */

import { json, noLattice, db } from './_lib/db.js';

const PAGE_SIZE = 50;

export async function onRequestGet({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const url = new URL(request.url);
  const raw = parseInt(url.searchParams.get('cursor') ?? '0', 10);
  const offset = Number.isFinite(raw) && raw > 0 ? raw : 0;

  const { results = [] } = await lattice.prepare(`
    SELECT action, reason, ts FROM custodian_log
    ORDER BY ts DESC LIMIT ${PAGE_SIZE} OFFSET ${offset}
  `).all();

  return json({
    entries: results,
    cursor: offset + results.length,
    done: results.length < PAGE_SIZE,
    source: 'lattice',
  });
}
