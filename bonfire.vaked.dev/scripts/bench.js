/**
 * bonfire — the DoD benchmark (spec §3: 1000+ waves in the lattice, recall
 * p95 < 50 ms)
 * ============================================================================
 * Run with: node scripts/bench.js
 *
 * Boots `wrangler pages dev` against a fresh local D1, seeds the lattice past
 * 1000 waves (including one 60-day-old REINFORCE-style wave the old
 * `ORDER BY ts LIMIT 1000` path could never see), then times real
 * /api/resonate calls and prints the p95. The number the README cites must be
 * the number this script printed.
 *
 * The harness owns the local D1 (`.wrangler/state/v3/d1/` is wiped) — same
 * contract as `npm test`.
 * ========================================================================== */

import { spawn } from 'node:child_process';
import { readFileSync, readdirSync, rmSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';

import { fingerprint, estimateVAD } from '../shared/wave.js';

const nowSec = () => Math.floor(Date.now() / 1000);

const CWD = new URL('..', import.meta.url).pathname;
const D1_DIR = `${CWD}.wrangler/state/v3/d1/miniflare-D1DatabaseObject/`;
const PORT = 8798;
const BASE = `http://127.0.0.1:${PORT}`;

const WAVES = 1000;            // DoD item 3: the lattice holds 1,000+ waves
const QUERIES = 30;            // samples for the p95
const OLD_AGE_SECONDS = 60 * 86400;
const OLD_TAU_HOURS = 90 * 24;
const QUERY_TEXT = 'mire emlékszik a tűz';

/* ---------------------------------------------------------------------------
 * Harness
 * ------------------------------------------------------------------------ */

const cookies = new Map();

async function api(path, { method = 'GET', body } = {}) {
  const headers = {};
  if (body !== undefined) headers['content-type'] = 'application/json';
  const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
  if (cookie) headers.cookie = cookie;
  const res = await fetch(`${BASE}${path}`, { method, headers, body: body !== undefined ? JSON.stringify(body) : undefined });
  for (const pair of (res.headers.getSetCookie?.() ?? [])) {
    const [name, ...rest] = pair.split(';')[0].split('=');
    cookies.set(name, rest.join('='));
  }
  const payload = await res.json();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${JSON.stringify(payload).slice(0, 200)}`);
  return payload;
}

// Deterministic pseudo-random in [0,1) so the seed is reproducible.
function prand(seed) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

/* ---------------------------------------------------------------------------
 * Seed: 1000 waves + one old, strong, resonant wave
 * ------------------------------------------------------------------------ */

async function seed(lattice, fireId, queryFreq, queryText) {
  const rand = prand(0xbeef);
  const stmt = lattice.prepare(`
    INSERT INTO waves (id, fire_id, essence, author_hash, wave32, vad_v, vad_a, vad_d,
                       amplitude, frequency, phase_deg, decay_tau, decision, ts, fingerprint, dampened)
    VALUES (?, ?, ?, ?, ?, 128, 128, 128, ?, ?, ?, ?, ?, ?, ?, 0)
  `);
  const blob = Buffer.alloc(32);

  for (let i = 0; i < WAVES; i++) {
    // Frequencies spread over the full band, with ~12% near the query's
    // harmonic neighbourhood — a realistic lattice, not a stacked deck.
    const inBand = rand() < 0.12;
    const frequency = inBand
      ? queryFreq * (0.5 + rand())
      : 0.2 + rand() * 7.8;
    const ts = nowSec() - Math.floor(rand() * 90 * 86400);
    const essence = `a rács ${i}. hulláma — senki sem idézi fel, amíg nem kérdezik`;
    const fp = Buffer.from(await fingerprint(essence)).toString('hex');
    stmt.run(
      crypto.randomUUID(), fireId, essence, 'bench-author', blob,
      Number((0.2 + rand() * 0.8).toFixed(4)), Number(frequency.toFixed(4)),
      Math.floor(rand() * 360),
      Math.floor(rand() * 3) === 0 ? 18 : 24 * 30,
      ['STORE', 'REINFORCE', 'TEMPORARY'][Math.floor(rand() * 3)], ts, fp,
    );
  }

  // The wave the DoD cares about: old, reinforced, phase-bound to the query
  // (a wave that genuinely resonates), and exactly on the query's frequency —
  // the first row any ts-LIMIT would drop, and the first the band filter keeps.
  const oldEssence = 'régi parázs — aki kérdez, az megtalálja';
  const oldFp = Buffer.from(await fingerprint(oldEssence)).toString('hex');
  const queryVad = estimateVAD(queryText);
  const queryPhase = Math.round((1 - queryVad.v / 255) * 180);
  stmt.run(
    crypto.randomUUID(), fireId, oldEssence, 'bench-author', blob,
    1.0, queryFreq, queryPhase, OLD_TAU_HOURS, 'REINFORCE', nowSec() - OLD_AGE_SECONDS, oldFp,
  );
  return oldEssence;
}

/* ---------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------ */

async function main() {
  rmSync(D1_DIR, { recursive: true, force: true });
  const dev = spawn('npx', [
    'wrangler', 'pages', 'dev', '.', '--port', String(PORT), '--d1', 'LATTICE=bonfire-lattice',
  ], { cwd: CWD, stdio: 'ignore', detached: true });

  try {
    for (let i = 0; i < 120; i++) {
      try { const r = await fetch(`${BASE}/api/health`); if (r.ok) break; } catch { /* not up yet */ }
      await sleep(250);
    }

    const files = readdirSync(D1_DIR).filter((f) => f.endsWith('.sqlite'));
    const lattice = new DatabaseSync(`${D1_DIR}${files[0]}`);
    lattice.exec(readFileSync(`${CWD}schema.sql`, 'utf8'));

    const fire = (await api('/api/fires', {
      method: 'POST',
      body: { name: 'Benchmark tűz', question: QUERY_TEXT, ash_sentence: 'Kész, ha a szám a README-ben van.' },
    })).fire;

    // The query's own frequency, so the old wave sits exactly in-band.
    const qFp = await fingerprint(QUERY_TEXT);
    const qFpSeed = ((qFp[0] << 16) | (qFp[1] << 8) | qFp[2]) / 0xffffff;
    const queryFreq = 0.2 + qFpSeed * 7.8;

    const oldEssence = await seed(lattice, fire.id, queryFreq, QUERY_TEXT);
    const { count } = lattice.prepare('SELECT COUNT(*) AS count FROM waves').get();
    console.log(`seeded ${count} waves into ${fire.slug}`);

    // Warm-up, then the timed samples (default k=12, what the fire room uses)
    // and the found-old check at k=50, which is the honest "findable" claim:
    // the old wave is a strong resonator, not necessarily the strongest.
    if (process.env.BENCH_DEBUG) {
      const probe = await api(`/api/resonate?q=${encodeURIComponent(QUERY_TEXT)}&fire=${fire.id}`);
      for (const w of probe.waves) {
        console.log(`  hit ${w.frequency.toFixed(3)} Hz · ${w.phase_deg}° · amp ${w.amplitude} · res ${w.resonance} · ${w.essence.slice(0, 40)}`);
      }
    }
    await api(`/api/resonate?q=${encodeURIComponent(QUERY_TEXT)}&fire=${fire.id}`);
    const times = [];
    let foundOld = false;

    for (let i = 0; i < QUERIES; i++) {
      const t0 = performance.now();
      const { waves } = await api(`/api/resonate?q=${encodeURIComponent(QUERY_TEXT)}&fire=${fire.id}`);
      times.push(performance.now() - t0);
      if (waves.some((w) => w.essence === oldEssence)) foundOld = true;
    }

    // The findable claim, checked at k=50 so it does not demand that a
    // 60-day-old wave outrank every fresh one — only that it is found.
    if (!foundOld) {
      const wide = await api(`/api/resonate?q=${encodeURIComponent(QUERY_TEXT)}&fire=${fire.id}&k=50`);
      foundOld = wide.waves.some((w) => w.essence === oldEssence);
    }

    times.sort((a, b) => a - b);
    const p50 = times[Math.floor(times.length * 0.5)];
    const p95 = times[Math.floor(times.length * 0.95)];

    console.log(`queries       ${QUERIES} × GET /api/resonate (scoped, ${count} waves in lattice)`);
    console.log(`p50           ${p50.toFixed(1)} ms`);
    console.log(`p95           ${p95.toFixed(1)} ms`);
    console.log(`max           ${times[times.length - 1].toFixed(1)} ms`);
    console.log(`old wave      ${foundOld ? 'FOUND — recall sees the whole lattice' : 'MISSING — the 1000-row cliff is still there'}`);

    if (!foundOld) process.exitCode = 2;
    if (p95 >= 50) process.exitCode = process.exitCode || 3;
  } finally {
    try { process.kill(-dev.pid, 'SIGKILL'); } catch { /* already gone */ }
  }
}

await main();
