/**
 * POST /api/ember — throw an ember on a fire.
 *
 * The whole Custodian lives on this path (spec §7), so the order of checks is
 * the order of the rules:
 *   1. repetition poisoning → reinforce ×φ, drop the duplicate
 *   2. cognitive loops      → cool-down, short τ
 *   3. harmful input        → dampen toward zero, keep the wave, log it
 *   then the Marine gate and Phoenix decide the rest.
 */

import {
  composeWave, attentionalNovelty, fromHex, reinforce, dampen, PHI,
} from '../../shared/wave.js';
import {
  json, fail, noLattice, db, nowSec, id, body, authorHash, withCookie,
  logCustodian, wireWave,
} from './_lib/db.js';

/** Waves needed before a fire is properly burning. Not in the spec — chosen
 *  so that EMBER means "just lit" rather than "empty forever". */
const PARAZS_THRESHOLD = 8;

/** Below this novelty against your *own* recent waves, you are repeating
 *  yourself rather than adding to the fire. */
const NEAR_DUPLICATE = 0.35;

/**
 * Custodian rule 3 detection.
 *
 * The mechanism the spec specifies — dampen amplitude toward zero, keep the
 * wave, log the action — is implemented in full below. The *detection* is
 * deliberately pluggable rather than a wordlist baked into a public repo:
 * operators supply terms via the HARM_TERMS secret (comma-separated). The one
 * built-in signal is structural, not lexical: a message that is overwhelmingly
 * one token repeated is flooding, whatever the token is.
 */
function harmfulSignal(essence, env) {
  const terms = String(env?.HARM_TERMS ?? '')
    .split(',').map((t) => t.trim().toLowerCase()).filter(Boolean);

  const lower = essence.toLowerCase();
  for (const term of terms) {
    if (lower.includes(term)) return { harmful: true, reason: 'operator term list' };
  }

  const words = lower.split(/\s+/).filter(Boolean);
  if (words.length >= 8) {
    const counts = new Map();
    for (const w of words) counts.set(w, (counts.get(w) ?? 0) + 1);
    const top = Math.max(...counts.values());
    if (top / words.length > 0.6) return { harmful: true, reason: 'token flooding' };
  }

  return { harmful: false, reason: null };
}

export async function onRequestPost({ request, env }) {
  const lattice = db(env);
  if (!lattice) return noLattice();

  const payload = await body(request);
  if (!payload) return fail(400, 'Hibás kérés.');

  const fireId = String(payload.fire_id ?? '').trim();
  const essence = String(payload.essence ?? '').trim();

  if (!fireId) return fail(400, 'Melyik tűzhöz?');
  if (essence.length < 2) return fail(400, 'Üres parazsat nem tudunk a tűzbe dobni.');
  if (essence.length > 1200) return fail(400, 'Túl hosszú. A parázs a lényeg, nem az egész fa.');

  const fire = await lattice.prepare('SELECT * FROM fires WHERE id = ?').bind(fireId).first();
  if (!fire) return fail(404, 'Nincs ilyen tűz.');
  if (fire.state === 'HAMU') {
    return fail(409, 'Ez a tűz hamuvá égett. A hamu-mondata teljesült — nem gyújtjuk újra.');
  }

  const { hash, setCookie } = await authorHash(request, env);
  const ts = nowSec();

  // Recent context for the Marine gate: the fire's last waves, and this
  // author's own last waves (rule 2 needs to know if *you* are looping).
  const [{ results: recent = [] }, { results: mine = [] }] = await Promise.all([
    lattice.prepare('SELECT fingerprint FROM waves WHERE fire_id = ? ORDER BY ts DESC LIMIT 24')
      .bind(fireId).all(),
    lattice.prepare('SELECT fingerprint FROM waves WHERE fire_id = ? AND author_hash = ? ORDER BY ts DESC LIMIT 12')
      .bind(fireId, hash).all(),
  ]);

  const recentFingerprints = recent.map((r) => r.fingerprint);
  const wave = await composeWave(essence, { recentFingerprints });

  /* -- Rule 1: repetition poisoning ------------------------------------- */
  const duplicate = await lattice
    .prepare('SELECT * FROM waves WHERE fire_id = ? AND fingerprint = ? ORDER BY ts ASC LIMIT 1')
    .bind(fireId, wave.fingerprint).first();

  if (duplicate) {
    const boosted = reinforce(duplicate.amplitude);
    await lattice
      .prepare('UPDATE waves SET amplitude = ?, decay_tau = ?, decision = ? WHERE id = ?')
      .bind(boosted, Math.max(duplicate.decay_tau, 24 * 90), 'REINFORCE', duplicate.id)
      .run();

    await logCustodian(lattice, {
      wave_id: duplicate.id,
      action: 'REINFORCE',
      reason: `duplicate essence; amplitude ×φ → ${boosted.toFixed(4)}`,
    });

    return withCookie(json({
      decision: 'REINFORCE',
      reason: 'Ez a parázs már ég itt — megerősítettük ×φ.',
      reason_en: 'This ember already burns here — reinforced ×φ.',
      reason_zh: '这颗火种已在这里燃烧——已 ×φ 强化。',
      wave: wireWave({ ...duplicate, amplitude: boosted }),
      source: 'lattice',
    }), setCookie);
  }

  /* -- Rule 2: cognitive loops ------------------------------------------ */
  const fp = fromHex(wave.fingerprint);
  const selfNovelty = attentionalNovelty(fp, mine.map((r) => r.fingerprint));
  const looping = mine.length >= 3 && selfNovelty < NEAR_DUPLICATE;

  /* -- Rule 3: harmful input -------------------------------------------- */
  const harm = harmfulSignal(essence, env);

  let decision = wave.decision;
  let reason = wave.reason;
  let reason_en = wave.reason_en;
  let reason_zh = wave.reason_zh;
  let tau = wave.tau_hours;
  let amplitude = wave.amplitude;

  if (looping) {
    decision = 'TEMPORARY';
    tau = 18;
    reason = 'Kör alakul — rövid τ, és egy csendes újrakezdés. '
      + 'Nem baj, hogy visszatérsz rá; csak ne csak arra térj vissza.';
    reason_en = 'A loop is forming — short τ, and a gentle reintroduction. '
      + 'It is fine to come back to it; just do not come back only to it.';
    reason_zh = '循环正在形成——短 τ，一次温柔的重启。回来没有错；只是别只回到这里。';
  }

  if (harm.harmful) {
    // The wave stays. Its voice does not. Memory, never deletion.
    amplitude = dampen(amplitude);
    decision = decision === 'DROP' ? 'TEMPORARY' : decision;
    tau = Math.min(tau || 18, 18);
    reason = 'A hullám megmarad, de csillapítva. Emlékezés, nem törlés.';
    reason_en = 'The wave stays, but dampened. Memory, not deletion.';
    reason_zh = '波保留下来，但被压低了。是记忆，不是删除。';
  }

  if (decision === 'DROP') {
    await logCustodian(lattice, {
      action: 'DROP',
      reason: `marine gate ${wave.gate.score.toFixed(3)} (jitter ${wave.gate.jitter.toFixed(2)}, novelty ${wave.gate.novelty.toFixed(2)})`,
    });
    return withCookie(json({
      decision: 'DROP', reason, reason_en, reason_zh, wave: null, gate: wave.gate, source: 'lattice',
    }), setCookie);
  }

  /* -- Store ------------------------------------------------------------- */
  const waveId = id();
  const phaseInt = Math.round(wave.phase_deg);

  await lattice.prepare(`
    INSERT INTO waves (id, fire_id, essence, author_hash, wave32, vad_v, vad_a, vad_d,
                       amplitude, frequency, phase_deg, decay_tau, decision, ts, fingerprint)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    waveId, fireId, essence, hash, wave.wave32,
    wave.vad.v, wave.vad.a, wave.vad.d,
    amplitude, wave.frequency, phaseInt, tau, decision, ts, wave.fingerprint,
  ).run();

  if (harm.harmful) {
    await logCustodian(lattice, {
      wave_id: waveId,
      action: 'DAMPEN',
      reason: `harmful signal (${harm.reason}); amplitude → ${amplitude.toFixed(4)}, wave retained`,
    });
  }
  if (looping) {
    await logCustodian(lattice, {
      wave_id: waveId,
      action: 'COOLDOWN',
      reason: `author self-novelty ${selfNovelty.toFixed(3)} over ${mine.length} recent waves`,
    });
  }

  // EMBER → PARÁZS once the fire is actually burning.
  if (fire.state === 'EMBER') {
    const { count } = await lattice
      .prepare('SELECT COUNT(*) AS count FROM waves WHERE fire_id = ?').bind(fireId).first();
    if (count >= PARAZS_THRESHOLD) {
      await lattice.prepare('UPDATE fires SET state = ? WHERE id = ?').bind('PARÁZS', fireId).run();
    }
  }

  return withCookie(json({
    decision,
    reason,
    reason_en,
    reason_zh,
    cooldown: looping || undefined,
    gate: wave.gate,
    wave: {
      id: waveId, fire_id: fireId, essence, ts,
      vad_v: wave.vad.v, vad_a: wave.vad.a, vad_d: wave.vad.d,
      amplitude, frequency: wave.frequency, phase_deg: phaseInt,
      decay_tau: tau, decision,
      color: wave.color, label: wave.label,
      wave32_hex: wave.wave32_hex,
    },
    phi: PHI,
    source: 'lattice',
  }, { status: 201 }), setCookie);
}
