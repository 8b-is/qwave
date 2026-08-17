/**
 * GET /api/ash/:slug — a completed fire and its .m8 capsule (spec §6).
 * POST /api/ash/:slug — the founder's write: "the ash sentence is fulfilled"
 * (spec §1: fires burn to ash; §5 `fires.state`). This is the only path that
 * moves a fire to HAMU. Founder-authenticated against the salted hash.
 *
 * `?format=m8` streams the capsule itself as a download. Otherwise you get
 * JSON describing the ash, with the capsule's size and export time.
 *
 * The capsule is built on first request after the fire reaches HAMU, and
 * stored — the artifact should not change shape depending on when you ask for
 * it. A leave rebuilds it (§7 rule 5); everything else reuses the stored one.
 */

import { buildCapsule } from '../../../shared/capsule.js';
import { vadColor, vadLabel } from '../../../shared/wave.js';
import {
  json, fail, noLattice, db, nowSec, id, publicWave, publicFire, BASE_HEADERS,
  authorHash, withCookie, logCustodian, guardSalt,
} from '../_lib/db.js';

/** The binary download. Headers built from BASE_HEADERS so the nosniff /
 *  no-store / x-robots guarantees cannot drift off the one response that
 *  streams a binary attachment. */
function m8Response(m8, slug) {
  const bytes = m8 instanceof Uint8Array ? m8 : new Uint8Array(m8);
  return new Response(bytes, {
    headers: {
      ...BASE_HEADERS,
      'content-type': 'application/octet-stream',
      'content-disposition': `attachment; filename="${slug}.m8"`,
    },
  });
}

export async function onRequestGet({ params, request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const slug = String(params.slug ?? '');
  const fire = await lattice.prepare('SELECT * FROM fires WHERE slug = ?').bind(slug).first();
  if (!fire) return fail(404, 'Nincs ilyen tűz.');

  if (fire.state !== 'HAMU') {
    return fail(409, 'Ez a tűz még ég. A hamu csak akkor van, ha a hamu-mondat teljesült.', {
      state: fire.state,
      ash_sentence: fire.ash_sentence,
    });
  }

  const wantM8 = new URL(request.url).searchParams.get('format') === 'm8';

  // The capsule is a cache, not a computation to repeat per request — look it
  // up first, and skip the wave query entirely for a stored m8 download.
  let capsule = await lattice
    .prepare('SELECT * FROM capsules WHERE fire_id = ?').bind(fire.id).first();

  if (capsule && wantM8) return m8Response(capsule.m8, slug);

  if (!capsule) {
    // Two concurrent first-requests both find no capsule. The UNIQUE index on
    // fire_id makes the loser's INSERT a no-op; the re-SELECT picks up the
    // winner's row — asking twice for the same ash gets you the same capsule,
    // twice, without an error.
    const { results: waves = [] } = await lattice
      .prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts ASC')
      .bind(fire.id).all();

    const exported_at = nowSec();
    const capsuleId = id();
    // A HAMU fire claiming no ash_at would write a null into its own header;
    // fall back to the export time rather than let the artifact lie.
    const bytes = buildCapsule(
      { ...fire, ash_at: fire.ash_at ?? exported_at },
      waves.map((w) => ({ ...w, wave32: new Uint8Array(w.wave32) })),
    );
    await lattice
      .prepare('INSERT OR IGNORE INTO capsules (id, fire_id, m8, exported_at) VALUES (?, ?, ?, ?)')
      .bind(capsuleId, fire.id, bytes, exported_at).run();
    capsule = await lattice
      .prepare('SELECT * FROM capsules WHERE fire_id = ?').bind(fire.id).first()
      ?? { id: capsuleId, fire_id: fire.id, m8: bytes, exported_at };
  }

  if (wantM8) return m8Response(capsule.m8, slug);

  const m8 = capsule.m8 instanceof Uint8Array ? capsule.m8 : new Uint8Array(capsule.m8);

  // JSON: the last 200 waves, newest first — the same cap as the fire room.
  const { results: recent = [] } = await lattice
    .prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts DESC LIMIT 200')
    .bind(fire.id).all();

  return json({
    fire: publicFire(fire),
    waves: recent.map((row) => {
      const vad = { v: row.vad_v, a: row.vad_a, d: row.vad_d };
      return { ...publicWave(row), color: vadColor(vad), label: vadLabel(vad) };
    }),
    capsule: {
      bytes: m8.length,
      exported_at: capsule.exported_at,
      download: `/api/ash/${encodeURIComponent(slug)}?format=m8`,
    },
    source: 'lattice',
  });
}

export async function onRequestPost({ params, request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const noSalt = guardSalt(env, request);
  if (noSalt) return noSalt;

  const slug = String(params.slug ?? '');
  const fire = await lattice.prepare('SELECT * FROM fires WHERE slug = ?').bind(slug).first();
  if (!fire) return fail(404, 'Nincs ilyen tűz.');
  if (fire.state === 'HAMU') return fail(409, 'Ez a tűz már hamuvá égett.');

  // Only the founder may declare the ash sentence fulfilled — and the founder
  // is whoever holds the one-way hash this fire was lit with.
  const { hash, setCookie } = await authorHash(request, env);
  if (hash !== fire.founder_hash) {
    return fail(403, 'Ezt a tüzet az alapítója viheti hamuba.');
  }

  const ashAt = nowSec();
  const { results: waves = [] } = await lattice
    .prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts ASC')
    .bind(fire.id).all();

  const capsuleId = id();
  const bytes = buildCapsule(
    { ...fire, state: 'HAMU', ash_at: ashAt },
    waves.map((w) => ({ ...w, wave32: new Uint8Array(w.wave32) })),
  );

  // One transaction: the state flips and the capsule lands together, so no
  // observer can ever see a HAMU fire that has no artifact. The conditional
  // UPDATE keeps a double-click from re-ashing; INSERT OR IGNORE keeps a
  // concurrent GET from racing the capsule (see the GET handler).
  await lattice.batch([
    lattice.prepare(`UPDATE fires SET state = 'HAMU', ash_at = ? WHERE id = ? AND state != 'HAMU'`)
      .bind(ashAt, fire.id),
    lattice.prepare('INSERT OR IGNORE INTO capsules (id, fire_id, m8, exported_at) VALUES (?, ?, ?, ?)')
      .bind(capsuleId, fire.id, bytes, ashAt),
  ]);

  await logCustodian(lattice, {
    action: 'ASH',
    reason: 'founder declared the ash sentence fulfilled; capsule exported',
  });

  return withCookie(json({
    fire: publicFire({ ...fire, state: 'HAMU', ash_at: ashAt }),
    capsule: {
      bytes: bytes.length,
      exported_at: ashAt,
      download: `/api/ash/${encodeURIComponent(slug)}?format=m8`,
    },
    source: 'lattice',
  }), setCookie);
}
