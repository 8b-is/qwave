/**
 * POST /api/ember — throw an ember on a fire.
 *
 * The whole Custodian lives on this path (spec §7), so the order of checks is
 * the order of the rules:
 *   1. repetition poisoning → reinforce ×φ, drop the duplicate
 *   2. cognitive loops      → cool-down, short τ
 *   3. harmful input        → dampen toward zero, keep the wave, log it
 *   then the Marine gate and Phoenix decide the rest.
 *
 * Rule 3 is evaluated *before* rule 1's reinforce: a dampened wave stays
 * dampened however many times it is thrown back into the fire.
 */

import {
  composeWave, attentionalNoveltyJaccard, encodeWave32, fromHex, normaliseEssence,
  reinforce, dampen, PHI,
} from '../../shared/wave.js';
import {
  json, fail, noLattice, db, nowSec, id, body, authorHash, withCookie,
  logCustodian, publicWave, PARAZS_THRESHOLD, guardSalt,
} from './_lib/db.js';
import { QUOTAS, checkQuota, clientKey } from './_lib/rate.js';

/** Below this novelty against your *own* recent waves, you are repeating
 *  yourself rather than adding to the fire. */
const NEAR_DUPLICATE = 0.35;

/** The cooling window for rule 2. Not in the spec — the spec names the
 *  mechanism (cool-down, then a quiet reintroduction) but not the length;
 *  chosen to match the 18 h τ a looping wave is stored with. */
const COOLDOWN_HOURS = 18;

/**
 * Custodian rule 3 detection.
 *
 * The mechanism the spec specifies — dampen amplitude toward zero, keep the
 * wave, log the action — is implemented in full below. The *detection* is
 * deliberately pluggable rather than a wordlist baked into a public repo:
 * operators supply terms via the HARM_TERMS secret (comma-separated). The one
 * built-in signal is structural, not lexical: a message that is overwhelmingly
 * one token repeated is flooding, whatever the token is.
 *
 * Matching happens against the same text the fingerprint reads
 * (normaliseEssence: lowercase, accents stripped, punctuation folded), so
 * punctuation and accent tricks cannot slip a term past the Custodian.
 * Zero-width characters are deleted outright *before* normalisation — they
 * exist only to defeat matching, and the normaliser would fold them into
 * spaces and split the word they were hiding in.
 */
function harmfulSignal(essence, env) {
  const normal = normaliseEssence(
    String(essence).replace(/[\u200B-\u200D\u2060\uFEFF]/g, ''),
  );
  const terms = String(env?.HARM_TERMS ?? '')
    .split(',').map((t) => normaliseEssence(t)).filter(Boolean);

  for (const term of terms) {
    if (normal.includes(term)) return { harmful: true, reason: 'operator term list' };
  }

  const words = normal.split(' ').filter(Boolean);
  if (words.length >= 5) {
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

  const noSalt = guardSalt(env, request);
  if (noSalt) return noSalt;

  const payload = await body(request);
  if (!payload) return fail(400, 'Hibás kérés.');

  const fireId = String(payload.fire_id ?? '').trim();
  const essence = String(payload.essence ?? '').trim();

  if (!fireId) return fail(400, 'Melyik tűzhöz?');
  if (essence.length < 2) return fail(400, 'Üres parazsat nem tudunk a tűzbe dobni.');
  if (essence.length > 1200) return fail(400, 'Túl hosszú. A parázs a lényeg, nem az egész fa.');

  // A per-IP token bucket: a script cannot fill the lattice.
  if (!(await checkQuota(lattice, await clientKey(request, env, 'ember'), QUOTAS.ember))) {
    return fail(429, 'Túl gyorsan. A tűz nem siet, te se.');
  }

  const fire = await lattice.prepare('SELECT * FROM fires WHERE id = ?').bind(fireId).first();
  if (!fire) return fail(404, 'Nincs ilyen tűz.');
  if (fire.state === 'HAMU') {
    return fail(409, 'Ez a tűz hamuvá égett. A hamu-mondata teljesült — nem gyújtjuk újra.');
  }

  const { hash, setCookie } = await authorHash(request, env);
  const ts = nowSec();

  // Recent context for the Marine gate: the fire's last waves, and this
  // author's own last waves (rule 2 needs to know if *you* are looping).
  // Essences ride alongside the fingerprints because novelty is measured by
  // Jaccard near-duplicate detection, not by hashing.
  const [{ results: recent = [] }, { results: mine = [] }] = await Promise.all([
    lattice.prepare('SELECT fingerprint, essence FROM waves WHERE fire_id = ? ORDER BY ts DESC LIMIT 24')
      .bind(fireId).all(),
    lattice.prepare('SELECT fingerprint, essence FROM waves WHERE fire_id = ? AND author_hash = ? ORDER BY ts DESC LIMIT 12')
      .bind(fireId, hash).all(),
  ]);

  const recentFingerprints = recent.map((r) => r.fingerprint);
  const recentEssences = recent.map((r) => r.essence);
  const wave = await composeWave(essence, { recentFingerprints, recentEssences });

  /* -- Rule 3: harmful input -------------------------------------------- */
  /* -- evaluated before rule 1's reinforce: a dampened wave stays dampened */
  /* -- however many times it is thrown back into the fire. -------------- */
  const harm = harmfulSignal(essence, env);

  /* -- Rule 1: repetition poisoning ------------------------------------- */
  const duplicate = await lattice
    .prepare('SELECT * FROM waves WHERE fire_id = ? AND fingerprint = ? ORDER BY ts ASC LIMIT 1')
    .bind(fireId, wave.fingerprint).first();

  if (duplicate) {
    if (duplicate.dampened) {
      // Already quieted once: reinforcement is withheld, not re-applied.
      await logCustodian(lattice, {
        wave_id: duplicate.id,
        action: 'DAMPEN-REPEAT',
        reason: 'previously dampened wave reposted; reinforcement withheld',
      });
      return withCookie(json({
        decision: duplicate.decision,
        reason: 'A hullám megmarad, de csillapítva. Emlékezés, nem törlés.',
        reason_en: 'The wave stays, but dampened. Memory, not deletion.',
        reason_zh: '波保留下来，但被压低了。是记忆，不是删除。',
        wave: publicWave(duplicate),
        source: 'lattice',
      }), setCookie);
    }

    if (harm.harmful) {
      // Rule 3 outranks rule 1: dampen the existing wave, do not reinforce it.
      const quiet = dampen(duplicate.amplitude);
      const tau = Math.min(duplicate.decay_tau, 18);
      const wave32 = encodeWave32({
        fp: fromHex(duplicate.fingerprint),
        amplitude: quiet,
        frequency: duplicate.frequency,
        phase_deg: duplicate.phase_deg,
        tau_hours: tau,
        decision: duplicate.decision,
      });
      await lattice
        .prepare('UPDATE waves SET amplitude = ?, decay_tau = ?, dampened = 1, wave32 = ? WHERE id = ?')
        .bind(quiet, tau, wave32, duplicate.id)
        .run();

      await logCustodian(lattice, {
        wave_id: duplicate.id,
        action: 'DAMPEN',
        reason: `harmful signal (${harm.reason}); amplitude → ${quiet.toFixed(4)}, wave retained`,
      });

      return withCookie(json({
        decision: duplicate.decision,
        reason: 'A hullám megmarad, de csillapítva. Emlékezés, nem törlés.',
        reason_en: 'The wave stays, but dampened. Memory, not deletion.',
        reason_zh: '波保留下来，但被压低了。是记忆，不是删除。',
        wave: publicWave({ ...duplicate, amplitude: quiet, decay_tau: tau, dampened: 1 }),
        source: 'lattice',
      }), setCookie);
    }

    const boosted = reinforce(duplicate.amplitude);
    const boostedTau = Math.max(duplicate.decay_tau, 24 * 90);
    // Keep the blob honest with the columns: the reinforcement must land in
    // the 32 bytes too, or the capsule would tell two stories (H20).
    const wave32 = encodeWave32({
      fp: fromHex(duplicate.fingerprint),
      amplitude: boosted,
      frequency: duplicate.frequency,
      phase_deg: duplicate.phase_deg,
      tau_hours: boostedTau,
      decision: 'REINFORCE',
    });
    await lattice
      .prepare('UPDATE waves SET amplitude = ?, decay_tau = ?, decision = ?, wave32 = ? WHERE id = ?')
      .bind(boosted, boostedTau, 'REINFORCE', wave32, duplicate.id)
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
      wave: publicWave({ ...duplicate, amplitude: boosted, decay_tau: boostedTau, decision: 'REINFORCE' }),
      source: 'lattice',
    }), setCookie);
  }

  /* -- Rule 2: cognitive loops ------------------------------------------ */
  const selfNovelty = attentionalNoveltyJaccard(essence, mine.map((r) => r.essence));
  const looping = mine.length >= 3 && selfNovelty < NEAR_DUPLICATE;

  // A loop that already tripped cools for a real window: the author's next
  // near-duplicate is held — not stored, not dropped — and the fire asks
  // them a quieter question instead. A genuinely new ember still passes.
  const lastCooldown = await lattice.prepare(`
    SELECT ts FROM waves
    WHERE fire_id = ? AND author_hash = ? AND decision = 'TEMPORARY'
    ORDER BY ts DESC LIMIT 1
  `).bind(fireId, hash).first();
  const cooling = lastCooldown && (ts - lastCooldown.ts) < COOLDOWN_HOURS * 3600;

  if (cooling && looping) {
    await logCustodian(lattice, {
      action: 'COOLDOWN-HELD',
      reason: `author loop held within ${COOLDOWN_HOURS}h window; self-novelty ${selfNovelty.toFixed(3)}`,
    });
    return withCookie(json({
      decision: 'TEMPORARY',
      cooldown: true,
      reason: 'Kör alakul — rövid τ, és egy csendes újrakezdés. '
        + 'Nem baj, hogy visszatérsz rá; csak ne csak arra térj vissza.',
      reason_en: 'A loop is forming — short τ, and a gentle reintroduction. '
        + 'It is fine to come back to it; just do not come back only to it.',
      reason_zh: '循环正在形成——短 τ，一次温柔的重启。回来没有错；只是别只回到这里。',
      wave: null,
      source: 'lattice',
    }), setCookie);
  }

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

  // The blob must encode the wave as the Custodian actually let it in —
  // amplitude, τ and decision after every rule has run (H20).
  const wave32 = encodeWave32({
    fp: fromHex(wave.fingerprint),
    amplitude,
    frequency: wave.frequency,
    phase_deg: wave.phase_deg,
    tau_hours: tau,
    decision,
  });

  const insertWave = lattice.prepare(`
    INSERT INTO waves (id, fire_id, essence, author_hash, wave32, vad_v, vad_a, vad_d,
                       amplitude, frequency, phase_deg, decay_tau, decision, ts, fingerprint, dampened)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    waveId, fireId, essence, hash, wave32,
    wave.vad.v, wave.vad.a, wave.vad.d,
    amplitude, wave.frequency, phaseInt, tau, decision, ts, wave.fingerprint,
    harm.harmful ? 1 : 0,
  );

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

  // EMBER → PARÁZS once the fire is actually burning. Batched with the wave
  // INSERT so the two are one transaction: a fire that reaches eight embers
  // is PARÁZS even if the isolate dies between the writes.
  await lattice.batch([
    insertWave,
    lattice.prepare(`
      UPDATE fires SET state = 'PARÁZS'
      WHERE id = ? AND state = 'EMBER'
        AND (SELECT COUNT(*) FROM waves WHERE fire_id = ?) >= ?
    `).bind(fireId, fireId, PARAZS_THRESHOLD),
  ]);

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
