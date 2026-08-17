/**
 * GET  /api/fires  — the ring
 * POST /api/fires  — light a fire. Ash required — no ash, no fire (spec §6).
 */

import { slugify } from '../../shared/wave.js';
import {
  json, fail, noLattice, db, nowSec, id, body, authorHash, withCookie,
  publicFire, guardSalt,
} from './_lib/db.js';
import { QUOTAS, checkQuota, clientKey } from './_lib/rate.js';

export async function onRequestGet({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  // The ring index also establishes the anonymous seat — a visitor can read
  // the ring and then sit down without ever reloading. The founder's own
  // fires get an is_founder badge: the hash itself never ships, only the
  // server-computed boolean.
  const { hash, setCookie } = await authorHash(request, env);

  const { results } = await lattice.prepare(`
    SELECT f.*,
           (SELECT COUNT(*) FROM waves  w WHERE w.fire_id  = f.id) AS waves,
           (SELECT COUNT(*) FROM chairs c WHERE c.fire_id = f.id) AS chairs
    FROM fires f
    ORDER BY
      -- Ash last: a finished fire is an artifact, not an invitation.
      CASE f.state WHEN 'PARÁZS' THEN 0 WHEN 'EMBER' THEN 1 ELSE 2 END,
      f.created_at DESC
    LIMIT 200
  `).all();

  return withCookie(
    json({
      fires: (results ?? []).map((f) => ({ ...publicFire(f), is_founder: f.founder_hash === hash })),
      source: 'lattice',
    }),
    setCookie,
  );
}

export async function onRequestPost({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const noSalt = guardSalt(env, request);
  if (noSalt) return noSalt;

  const payload = await body(request);
  if (!payload) return fail(400, 'Hibás kérés.');

  const name = String(payload.name ?? '').trim();
  const question = String(payload.question ?? '').trim();
  const ash = String(payload.ash_sentence ?? '').trim();
  const pulse = ['daily', 'weekly', 'none'].includes(payload.pulse) ? payload.pulse : 'none';

  if (name.length < 2 || name.length > 80) {
    return fail(400, 'A tűznek nevet kell adni (2–80 karakter).');
  }
  // Pillar 1, enforced at the door.
  if (ash.length < 12) {
    return fail(400, 'Hamu-mondat nélkül nincs tűz. Mondd meg egy mondatban, mikor lesz ennek vége.');
  }
  if (ash.length > 280 || question.length > 240) {
    return fail(400, 'Túl hosszú. A hamu egy mondat, nem egy terv.');
  }

  // A global cap on fires-per-hour: the ring is not a factory.
  if (!(await checkQuota(lattice, await clientKey(request, env, 'fire'), QUOTAS.fire))) {
    return fail(429, 'Túl gyorsan. A tűz nem siet, te se.');
  }

  const { hash, setCookie } = await authorHash(request, env);

  // Slugs collide; fires do not get to steal each other's addresses. One
  // `ON CONFLICT DO NOTHING` replaces the old serial probe loop: the unique
  // index on slug is the arbiter, so two concurrent creates cannot both win —
  // the loser simply retries under a suffixed slug instead of crashing into
  // an unhandled constraint error.
  const base = slugify(name);
  const fireId = id();
  const createdAt = nowSec();
  let slug = base;
  let inserted = false;

  for (let attempt = 0; attempt < 3 && !inserted; attempt++) {
    if (attempt > 0) slug = `${base}-${Math.floor(Math.random() * 900) + 100}`;

    // One transaction: the fire and its founder's seat land together, so a
    // fire can never exist with its founder standing outside it. The chair
    // INSERT is a SELECT-gated no-op when the fire INSERT conflicted, which
    // keeps the foreign key quiet while the batch retries.
    const outcome = await lattice.batch([
      lattice.prepare(`
        INSERT INTO fires (id, slug, name, question, ash_sentence, founder_hash, pulse, state, created_at, ash_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'EMBER', ?, NULL)
        ON CONFLICT(slug) DO NOTHING
      `).bind(fireId, slug, name, question || null, ash, hash, pulse, createdAt),
      lattice.prepare(`
        INSERT INTO chairs (id, fire_id, name_hash, joined_at, last_seen)
        SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM fires WHERE id = ?)
      `).bind(id(), fireId, hash, createdAt, createdAt, fireId),
    ]);

    inserted = (outcome[0]?.meta?.changes ?? 0) > 0;
  }

  if (!inserted) {
    // A constraint is never a 500: the visitor keeps their ash sentence.
    return fail(409, 'Ezt a nevet már elvitte egy másik tűz. Adj neki egy sajátot.');
  }

  return withCookie(
    json({
      fire: { ...publicFire({ id: fireId, slug, name, question: question || null, ash_sentence: ash, pulse, state: 'EMBER', created_at: createdAt, ash_at: null }), waves: 0, chairs: 1 },
      source: 'lattice',
    }, { status: 201 }),
    setCookie,
  );
}
