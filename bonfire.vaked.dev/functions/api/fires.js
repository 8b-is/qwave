/**
 * GET  /api/fires  — the ring
 * POST /api/fires  — light a fire. Ash required — no ash, no fire (spec §6).
 */

import { slugify } from '../../shared/wave.js';
import {
  json, fail, noLattice, db, nowSec, id, body, authorHash, withCookie,
} from './_lib/db.js';

export async function onRequestGet({ env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

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

  return json({ fires: results ?? [], source: 'lattice' });
}

export async function onRequestPost({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

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

  const { hash, setCookie } = await authorHash(request, env);

  // Slugs collide; fires do not get to steal each other's addresses.
  const base = slugify(name);
  let slug = base;
  for (let n = 2; n <= 50; n++) {
    const taken = await lattice.prepare('SELECT 1 FROM fires WHERE slug = ?').bind(slug).first();
    if (!taken) break;
    slug = `${base}-${n}`;
  }

  const fire = {
    id: id(),
    slug,
    name,
    question: question || null,
    ash_sentence: ash,
    founder_hash: hash,
    pulse,
    state: 'EMBER',
    created_at: nowSec(),
    ash_at: null,
  };

  await lattice.prepare(`
    INSERT INTO fires (id, slug, name, question, ash_sentence, founder_hash, pulse, state, created_at, ash_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
  `).bind(
    fire.id, fire.slug, fire.name, fire.question, fire.ash_sentence,
    fire.founder_hash, fire.pulse, fire.state, fire.created_at,
  ).run();

  // The founder is sitting down by definition.
  await lattice.prepare(`
    INSERT OR IGNORE INTO chairs (id, fire_id, name_hash, joined_at, last_seen)
    VALUES (?, ?, ?, ?, ?)
  `).bind(id(), fire.id, hash, fire.created_at, fire.created_at).run();

  return withCookie(
    json({ fire: { ...fire, waves: 0, chairs: 1 }, source: 'lattice' }, { status: 201 }),
    setCookie,
  );
}
