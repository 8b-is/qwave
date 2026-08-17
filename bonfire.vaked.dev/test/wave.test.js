/**
 * bonfire — wave engine tests
 * Run with: npm test   (node --test test/)
 *
 * These cover the properties the spec actually promises, not the
 * implementation's incidental shape.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PHI, WAVE, DECISION, TAU_HOURS,
  normaliseEssence, fingerprint, estimateVAD, vadColor,
  structuralJitter, attentionalNovelty, marineGate, phoenix,
  essenceJaccard, attentionalNoveltyJaccard, marineGateJaccard,
  encodeWave32, decodeWave32, composeWave,
  decayFactor, effectiveAmplitude, phaseRelation, phiHarmonics,
  resonanceScore, resynthesise, reinforce, dampen, slugify, identityHash,
} from '../shared/wave.js';

import { buildCapsule, readCapsule } from '../shared/capsule.js';

/* -- normalisation + fingerprint ----------------------------------------- */

test('normalisation folds case, accents and punctuation', () => {
  assert.equal(normaliseEssence('Tűz, TŰZ!!!  tuz…'), 'tuz tuz tuz');
});

test('the same essence always yields the same fingerprint', async () => {
  const a = await fingerprint('A csend helye');
  const b = await fingerprint('a  CSEND, helye!');
  assert.equal(a.length, 16);
  assert.deepEqual([...a], [...b]);
});

test('different essences yield different fingerprints', async () => {
  const a = await fingerprint('tűz');
  const b = await fingerprint('hamu');
  assert.notDeepEqual([...a], [...b]);
});

/* -- VAD ------------------------------------------------------------------ */

test('valence separates warm from dark', () => {
  const warm = estimateVAD('Köszönöm, ez nagyon jólesett. Szeretet és béke.');
  const dark = estimateVAD('Félelem, fájdalom, gyűlölet. Egyedül vagyok.');
  assert.ok(warm.v > 140, `warm valence ${warm.v} should be > 140`);
  assert.ok(dark.v < 115, `dark valence ${dark.v} should be < 115`);
});

test('shouting raises arousal and dominance', () => {
  const calm = estimateVAD('most kell tüzet gyújtani');
  const loud = estimateVAD('MOST AZONNAL KELL TÜZET GYÚJTANI!!!');
  assert.ok(loud.a > calm.a, `${loud.a} should exceed ${calm.a}`);
  assert.ok(loud.d > calm.d);
});

test('questions lower dominance', () => {
  const statement = estimateVAD('Tudom, hogy ez így lesz.');
  const question = estimateVAD('Talán? Nem tudom. Kérlek segíts?');
  assert.ok(question.d < statement.d);
});

test('every VAD byte stays in range', () => {
  const samples = ['', 'a', '!!!!!!!!!!', 'AAAAAAAAAA', 'szeretet '.repeat(60), '???'];
  for (const s of samples) {
    const vad = estimateVAD(s);
    for (const k of ['v', 'a', 'd']) {
      assert.ok(vad[k] >= 0 && vad[k] <= 255, `${k}=${vad[k]} out of range for ${JSON.stringify(s)}`);
      assert.equal(Number.isInteger(vad[k]), true);
    }
  }
});

test('vadColor produces a parseable oklch string', () => {
  const css = vadColor({ v: 200, a: 180, d: 120 });
  assert.match(css, /^oklch\(\d\.\d+ \d\.\d+ \d+\.\d\)$/);
});

/* -- the Marine gate ------------------------------------------------------ */

test('structural jitter separates prose from repetition', () => {
  const prose = structuralJitter('A nagymamám kenyérreceptjét vinném tovább, nem a papírt.');
  const spam = structuralJitter('csend csend csend csend csend csend csend');
  assert.ok(prose > spam, `prose ${prose} should exceed spam ${spam}`);
});

test('novelty is 1 against an empty lattice', async () => {
  const fp = await fingerprint('bármi');
  assert.equal(attentionalNovelty(fp, []), 1);
});

test('novelty is 0 against itself', async () => {
  const fp = await fingerprint('ugyanaz');
  const hex = [...fp].map((b) => b.toString(16).padStart(2, '0')).join('');
  assert.equal(attentionalNovelty(fp, [hex]), 0);
});

test('the gate scores in [0,1]', async () => {
  const fp = await fingerprint('valami');
  const gate = marineGate('valami értelmes mondat a tűz mellől', fp, []);
  assert.ok(gate.score >= 0 && gate.score <= 1);
});

/* -- the Jaccard gate (production novelty path) ---------------------------- */

test('jaccard novelty is 1 against an empty window, like wave_brain.py', () => {
  assert.equal(attentionalNoveltyJaccard('bármi', []), 1);
});

test('jaccard similarity is 1 for the same essence and near 0 for unrelated ones', () => {
  assert.equal(essenceJaccard('A csend helye', 'a CSEND, helye!'), 1);
  assert.ok(essenceJaccard('A csend helye', 'Huszonhét ember ül a tűz körül') < 0.2);
});

test('a near-duplicate scores below 0.5 and a loop scores below 0.28', () => {
  const original = 'A nagymamám kenyérreceptjét viszem tovább, nem a papírt.';
  const reworded = 'A nagymamám kenyérreceptjét viszem tovább, és nem a papírt.';
  const near = marineGateJaccard(reworded, [original, 'Ma reggel hallottam, hogy fáradt vagyok.']);
  assert.ok(near.novelty < 0.5, `near-duplicate novelty ${near.novelty} should be < 0.5`);
  assert.ok(near.score < 0.5, `near-duplicate score ${near.score} should be < 0.5`);

  const loop = marineGateJaccard('blah blah blah blah blah', ['blah blah blah blah blah blah', 'blah blah blah blah']);
  assert.ok(loop.score < 0.28, `loop score ${loop.score} should drop`);
});

/* -- Phoenix -------------------------------------------------------------- */

test('an exact duplicate always reinforces', () => {
  const verdict = phoenix({ gate: { score: 0.02 }, exactDuplicate: true });
  assert.equal(verdict.decision, DECISION.REINFORCE);
  assert.equal(verdict.tau_hours, TAU_HOURS.REINFORCE);
});

test('a third repeat by the same author cools down', () => {
  const verdict = phoenix({ gate: { score: 0.9 }, repeatsByAuthor: 3 });
  assert.equal(verdict.decision, DECISION.TEMPORARY);
  assert.equal(verdict.cooldown, true);
});

test('a dead gate drops', () => {
  assert.equal(phoenix({ gate: { score: 0.05 } }).decision, DECISION.DROP);
});

test('a live gate stores', () => {
  const verdict = phoenix({ gate: { score: 0.85 } });
  assert.equal(verdict.decision, DECISION.STORE);
  assert.equal(verdict.tau_hours, TAU_HOURS.STORE);
});

/* -- the 32-byte vector --------------------------------------------------- */

test('wave32 round-trips through encode/decode', async () => {
  const fp = await fingerprint('kerek egész');
  const bytes = encodeWave32({
    fp, amplitude: 0.625, frequency: 3.75, phase_deg: 137.25,
    tau_hours: 720, decision: 'STORE',
  });

  assert.equal(bytes.length, WAVE.SIZE);
  assert.equal(bytes.length, 32);

  const back = decodeWave32(bytes);
  assert.ok(Math.abs(back.amplitude - 0.625) < 1e-4);
  assert.ok(Math.abs(back.frequency - 3.75) < 1e-3);
  assert.ok(Math.abs(back.phase_deg - 137.25) < 1e-2);
  assert.equal(back.tau_hours, 720);
  assert.equal(back.decision, 'STORE');
  assert.equal(back.version, 1);
  assert.equal(back.fingerprint, [...fp].map((b) => b.toString(16).padStart(2, '0')).join(''));
});

test('phase wraps rather than overflowing', async () => {
  const fp = await fingerprint('körbe');
  const back = decodeWave32(encodeWave32({
    fp, amplitude: 1, frequency: 1, phase_deg: 400, tau_hours: 24, decision: 'STORE',
  }));
  assert.ok(back.phase_deg >= 0 && back.phase_deg < 360, `phase ${back.phase_deg} out of range`);
  assert.ok(Math.abs(back.phase_deg - 40) < 1e-2);
});

test('extreme inputs stay inside their fields', async () => {
  const fp = await fingerprint('szélsőség');
  const bytes = encodeWave32({
    fp, amplitude: 99, frequency: 1e6, phase_deg: -720, tau_hours: 1e9, decision: 'DROP',
  });
  assert.equal(bytes.length, 32);
  const back = decodeWave32(bytes);
  assert.ok(back.amplitude <= 1);
  assert.ok(back.tau_hours <= 65535);
  assert.ok(back.phase_deg >= 0 && back.phase_deg < 360);
});

test('composeWave produces a complete, self-consistent wave', async () => {
  const wave = await composeWave('A csend helye a lépcsőházban van, két emelet között.');
  assert.equal(wave.wave32.length, 32);
  assert.equal(wave.wave32_hex.length, 64);
  assert.ok(wave.amplitude > 0 && wave.amplitude <= 1);
  assert.ok(wave.frequency >= 0.2 && wave.frequency <= 8);
  assert.ok(wave.phase_deg >= 0 && wave.phase_deg <= 180);
  assert.ok(Object.values(DECISION).includes(wave.decision));
  assert.equal(wave.wave32_hex.slice(0, 32), wave.fingerprint);
});

test('warm essences sit at a lower phase than dark ones', async () => {
  const warm = await composeWave('Szeretet, öröm, hála, béke, fény.');
  const dark = await composeWave('Félelem, fájdalom, gyűlölet, halál.');
  assert.ok(warm.phase_deg < dark.phase_deg,
    `warm ${warm.phase_deg}° should be below dark ${dark.phase_deg}°`);
});

/* -- decay ---------------------------------------------------------------- */

test('D(t,τ) = e^(−t/τ) behaves at the boundaries', () => {
  assert.equal(decayFactor(0, 24), 1);
  assert.ok(Math.abs(decayFactor(24 * 3600, 24) - Math.exp(-1)) < 1e-12);
  assert.ok(decayFactor(1e9, 24) < 1e-6);
  assert.equal(decayFactor(100, 0), 0);
});

test('half-life lands at τ·ln2', () => {
  const tau = 720;
  const half = tau * Math.LN2 * 3600;
  assert.ok(Math.abs(decayFactor(half, tau) - 0.5) < 1e-9);
});

test('effective amplitude decays with age', () => {
  const now = 1_000_000;
  const fresh = effectiveAmplitude({ amplitude: 1, decay_tau: 24, ts: now }, now);
  const old = effectiveAmplitude({ amplitude: 1, decay_tau: 24, ts: now - 72 * 3600 }, now);
  assert.equal(fresh, 1);
  assert.ok(old < 0.06 && old > 0);
});

/* -- interference --------------------------------------------------------- */

test('phase relations map onto the spec vocabulary', () => {
  assert.equal(phaseRelation(0, 0).kind, 'bound');
  assert.equal(phaseRelation(0, 180).kind, 'conflicting');
  assert.equal(phaseRelation(0, 90).kind, 'orthogonal');
  assert.ok(Math.abs(phaseRelation(0, 0).coherence - 1) < 1e-12);
  assert.ok(Math.abs(phaseRelation(0, 180).coherence + 1) < 1e-12);
});

test('phase distance is symmetric and wraps the short way', () => {
  assert.equal(phaseRelation(350, 10).delta_deg, 20);
  assert.equal(phaseRelation(10, 350).delta_deg, 20);
});

test('φ harmonics bracket the fundamental', () => {
  const [low, mid, high] = phiHarmonics(4);
  assert.ok(Math.abs(mid - 4) < 1e-12);
  assert.ok(Math.abs(low - 4 / PHI) < 1e-12);
  assert.ok(Math.abs(high - 4 * PHI) < 1e-12);
  assert.ok(low < mid && mid < high);
});

test('resonance prefers matching frequency and agreeing phase', () => {
  const now = 2_000_000;
  const query = { frequency: 3, phase_deg: 30 };
  const base = { amplitude: 1, decay_tau: TAU_HOURS.STORE, ts: now };

  const aligned = resonanceScore({ ...base, frequency: 3, phase_deg: 30 }, query, now);
  const opposed = resonanceScore({ ...base, frequency: 3, phase_deg: 210 }, query, now);
  const distant = resonanceScore({ ...base, frequency: 40, phase_deg: 30 }, query, now);

  assert.ok(aligned.score > opposed.score, 'agreement should outrank conflict');
  assert.ok(aligned.score > distant.score, 'near frequency should outrank far');
  assert.ok(opposed.score > 0, 'conflict is ranked lower, never hidden');
});

test('a φ-sideband still resonates', () => {
  const now = 3_000_000;
  const query = { frequency: 2, phase_deg: 90 };
  const base = { amplitude: 1, decay_tau: TAU_HOURS.STORE, ts: now, phase_deg: 90 };

  const sideband = resonanceScore({ ...base, frequency: 2 * PHI }, query, now);
  const unrelated = resonanceScore({ ...base, frequency: 2 * 7 }, query, now);
  assert.ok(sideband.score > unrelated.score);
});

test('resynthesis returns the top-k, most resonant first', async () => {
  const now = Math.floor(Date.now() / 1000);
  const waves = await Promise.all(
    ['a csend helye', 'a tűz melege', 'hamu és por', 'csend és béke']
      .map(async (essence, i) => {
        const w = await composeWave(essence);
        return {
          id: `w${i}`, essence,
          amplitude: w.amplitude, frequency: w.frequency,
          phase_deg: w.phase_deg, decay_tau: w.tau_hours, ts: now,
        };
      }),
  );

  const hits = await resynthesise('csend', waves, { topK: 2, nowSeconds: now });
  assert.equal(hits.length, 2);
  assert.ok(hits[0].resonance >= hits[1].resonance);
  assert.ok(hits.every((h) => typeof h.relation === 'string'));
});

/* -- Custodian arithmetic ------------------------------------------------- */

test('reinforce multiplies by φ and clamps at 1', () => {
  assert.ok(Math.abs(reinforce(0.5) - 0.5 * PHI) < 1e-12);
  assert.equal(reinforce(0.9), 1);
});

test('dampen approaches zero without reaching it', () => {
  const d = dampen(0.8);
  assert.ok(d > 0 && d < 0.05, `dampened ${d}`);
});

/* -- identity ------------------------------------------------------------- */

test('author hashes are stable, salted, and one-way in shape', async () => {
  const a = await identityHash('token-1', 'salt-A');
  const b = await identityHash('token-1', 'salt-A');
  const c = await identityHash('token-1', 'salt-B');
  const d = await identityHash('token-2', 'salt-A');

  assert.equal(a, b, 'same token + salt must be stable');
  assert.notEqual(a, c, 'a different salt must give a different hash');
  assert.notEqual(a, d, 'a different token must give a different hash');
  assert.match(a, /^[0-9a-f]{32}$/);
});

/* -- slugs ---------------------------------------------------------------- */

test('slugify strips accents and punctuation', () => {
  assert.equal(slugify('Mit viszünk tovább?'), 'mit-viszunk-tovabb');
  assert.equal(slugify('A CSEND helye!!!'), 'a-csend-helye');
});

test('slugify never returns an empty slug', () => {
  assert.equal(slugify('!!!'), 'tuz');
  assert.equal(slugify(''), 'tuz');
});

/* -- the ash capsule ------------------------------------------------------ */

test('a capsule round-trips', async () => {
  const fire = {
    slug: 'az-elso-tuz', name: 'Az első tűz',
    question: 'Miért ülsz le egy tűzhöz, amit nem te gyújtottál?',
    ash_sentence: 'Kész, ha az alapítója harminc napja nincs itt, és a tűz még rezonál.',
    state: 'HAMU', created_at: 1000, ash_at: 2000,
  };

  const waves = await Promise.all(['első', 'második'].map(async (essence, i) => {
    const w = await composeWave(essence);
    return {
      essence, wave32: w.wave32,
      vad_v: w.vad.v, vad_a: w.vad.a, vad_d: w.vad.d,
      amplitude: w.amplitude, frequency: w.frequency, phase_deg: Math.round(w.phase_deg),
      decay_tau: w.tau_hours, decision: w.decision, ts: 1500 + i,
    };
  }));

  const bytes = buildCapsule(fire, waves);
  const back = readCapsule(bytes);

  assert.equal(back.version, 1);
  assert.equal(back.header.fire.slug, 'az-elso-tuz');
  assert.equal(back.header.fire.ash_sentence, fire.ash_sentence);
  assert.equal(back.header.wave_count, 2);
  assert.equal(back.header.waves[0].essence, 'első');
  assert.equal(back.vectors.length, 2);
  assert.deepEqual([...back.vectors[0]], [...waves[0].wave32]);
});

test('a capsule with no waves is still valid', () => {
  const bytes = buildCapsule(
    { slug: 's', name: 'n', ash_sentence: 'a'.repeat(12), state: 'HAMU', created_at: 1 },
    [],
  );
  const back = readCapsule(bytes);
  assert.equal(back.header.wave_count, 0);
  assert.equal(back.vectors.length, 0);
});

test('a non-capsule is rejected', () => {
  assert.throws(() => readCapsule(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])), /magic/);
});
