/**
 * GET /api/ash/:slug — a completed fire and its .m8 capsule (spec §6).
 *
 * `?format=m8` streams the capsule itself as a download. Otherwise you get
 * JSON describing the ash, with the capsule's size and export time.
 *
 * The capsule is built once, on first request after the fire reaches HAMU, and
 * stored — the artifact should not change shape depending on when you ask for it.
 */

import { buildCapsule } from '../../../shared/capsule.js';
import { vadColor, vadLabel } from '../../../shared/wave.js';
import { json, fail, noLattice, db, nowSec, id, wireWave, BASE_HEADERS } from '../_lib/db.js';

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

  const { results: waves = [] } = await lattice
    .prepare('SELECT * FROM waves WHERE fire_id = ? ORDER BY ts ASC')
    .bind(fire.id).all();

  let capsule = await lattice
    .prepare('SELECT * FROM capsules WHERE fire_id = ?').bind(fire.id).first();

  if (!capsule) {
    const bytes = buildCapsule(
      fire,
      waves.map((w) => ({ ...w, wave32: new Uint8Array(w.wave32) })),
    );
    const exported_at = nowSec();
    const capsuleId = id();
    await lattice
      .prepare('INSERT INTO capsules (id, fire_id, m8, exported_at) VALUES (?, ?, ?, ?)')
      .bind(capsuleId, fire.id, bytes, exported_at).run();
    capsule = { id: capsuleId, fire_id: fire.id, m8: bytes, exported_at };
  }

  const m8 = capsule.m8 instanceof Uint8Array ? capsule.m8 : new Uint8Array(capsule.m8);

  if (new URL(request.url).searchParams.get('format') === 'm8') {
    return new Response(m8, {
      headers: {
        ...BASE_HEADERS,
        'content-type': 'application/octet-stream',
        'content-disposition': `attachment; filename="${slug}.m8"`,
      },
    });
  }

  return json({
    fire,
    waves: waves.map((row) => {
      const vad = { v: row.vad_v, a: row.vad_a, d: row.vad_d };
      return { ...wireWave(row), author_hash: undefined, color: vadColor(vad), label: vadLabel(vad) };
    }),
    capsule: {
      bytes: m8.length,
      exported_at: capsule.exported_at,
      download: `/api/ash/${encodeURIComponent(slug)}?format=m8`,
    },
    source: 'lattice',
  });
}
