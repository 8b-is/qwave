/**
 * bonfire — API integration tests
 * ============================================================================
 * One command lights a fire, throws embers at it, burns it to ash and reads
 * the capsule back — on a laptop, with no network.
 *
 * The suite boots `wrangler pages dev` against the local D1 (miniflare),
 * seeds it from schema.sql, and drives the real HTTP endpoints. This is the
 * harness the DoD items hang off: the .m8 written to test/artifacts/ is the
 * capsule of a fire this deployment actually burned.
 * ========================================================================== */

import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';

import { readCapsule } from '../shared/capsule.js';
import { decodeWave32 } from '../shared/wave.js';

const PORT = 8799;
const BASE = `http://127.0.0.1:${PORT}`;
const CWD = new URL('..', import.meta.url).pathname;
const ARTIFACTS = new URL('artifacts/', new URL('.', import.meta.url)).pathname;
const D1_DIR = `${CWD}.wrangler/state/v3/d1/miniflare-D1DatabaseObject/`;
const SCHEMA = readFileSync(`${CWD}schema.sql`, 'utf8');

let dev = null;
let sqlite = null;
const cookies = new Map();

/* ---------------------------------------------------------------------------
 * Harness: boot the lattice, apply the schema, wipe it, keep a cookie jar
 * ------------------------------------------------------------------------ */

// `wrangler pages dev` and `wrangler d1 execute --local` persist their local
// D1 into *different* sqlite files in this wrangler version. The harness owns
// the whole local D1 directory: it wipes it before booting the dev server, so
// the one sqlite file that exists afterwards is unambiguously the server's,
// and schema.sql and the wipes go to it directly through node:sqlite.
function wipe() {
  // Children first, so the wipe is order-safe whether or not the dev
  // server's connection enforces foreign keys.
  sqlite.exec(`
    DELETE FROM custodian_log;
    DELETE FROM quotas;
    DELETE FROM waves;
    DELETE FROM chairs;
    DELETE FROM capsules;
    DELETE FROM fires;
  `);
  cookies.clear();
}

async function api(path, { method = 'GET', body, keepCookie = true } = {}) {
  const headers = {};
  if (body !== undefined) headers['content-type'] = 'application/json';
  const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
  if (cookie) headers.cookie = cookie;

  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (keepCookie) {
    for (const pair of (res.headers.getSetCookie?.() ?? [])) {
      const [name, ...rest] = pair.split(';')[0].split('=');
      cookies.set(name, rest.join('='));
    }
  }

  let payload = null;
  try { payload = await res.json(); } catch { /* binary */ }
  return { res, payload, headers: res.headers };
}

// Genuinely distinct essences — the Jaccard novelty of any pair is low, so
// rule 2's cooldown (which these tests do not exercise) never trips here.
const DISTINCT = [
  'A nagymama kenyérreceptje nem a papíron él.',
  'Hajnali négykor a hűtő zúgása a legőszintébb hang.',
  'Valaki más már meggyújtotta ezt a tüzet helyettünk.',
  'A csend néha hangosabb, mint bármelyik mondat.',
  'Huszonhét ember ül körbe, és senki sem ismétli a másikat.',
  'A hamu nem a vége, hanem ami megmarad belőlünk.',
  'Nem tudom, mit mondjak, ezért leírom, amit érzek.',
  'A lépcsőházban két emelet között hallom meg, hogy fáradt vagyok.',
];

function distinct(n) {
  return DISTINCT[n % DISTINCT.length];
}

function nearDupe(n) {
  return `a csend a legjobb válasz erre a kérdésre — ${n}. változat`;
}

before(async () => {
  rmSync(D1_DIR, { recursive: true, force: true });
  dev = spawn('npx', [
    'wrangler', 'pages', 'dev', '.',
    '--port', String(PORT),
    '--d1', 'LATTICE=bonfire-lattice',
  ], { cwd: CWD, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
  dev.stdout.on('data', () => {});
  dev.stderr.on('data', () => {});

  // Wait for the dev server to answer.
  for (let i = 0; i < 120; i++) {
    try {
      const res = await fetch(`${BASE}/api/health`);
      if (res.ok) break;
    } catch { /* not up yet */ }
    await sleep(250);
  }

  // The one sqlite file present now is the dev server's own lattice.
  const files = readdirSync(D1_DIR).filter((f) => f.endsWith('.sqlite'));
  sqlite = new DatabaseSync(`${D1_DIR}${files[0]}`);
  sqlite.exec(SCHEMA);
  const { count } = sqlite.prepare("SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'fires'").get();
  if (!count) throw new Error('schema did not apply to the dev lattice');
});

after(() => {
  try { sqlite?.close(); } catch { /* already closed */ }
  // SIGKILL the whole process group: npx → wrangler → workerd chains can
  // shrug off SIGTERM and leave the port held for the next run.
  try { process.kill(-dev.pid, 'SIGKILL'); } catch { /* already gone */ }
});

beforeEach(() => {
  wipe();
});

/* ---------------------------------------------------------------------------
 * The ring: health, fires, identity redaction
 * ------------------------------------------------------------------------ */

test('health reports the lattice and the Custodian config', async () => {
  const { res, payload } = await api('/api/health');
  assert.equal(res.status, 200);
  assert.equal(payload.lattice, 'bound');
  assert.ok(['development', 'configured'].includes(payload.identity_salt));
  assert.ok(['configured', 'none'].includes(payload.harm_terms));
});

test('a fire is created with an ash sentence, and no identity ever ships', async () => {
  const { res, payload } = await api('/api/fires', {
    method: 'POST',
    body: { name: 'E2E tűz', question: 'Mi marad?', ash_sentence: 'Kész, ha az e2e teszt lefut és zöld.' },
  });
  assert.equal(res.status, 201);
  const fire = payload.fire;
  assert.ok(fire.slug);
  assert.ok(fire.id);
  assert.equal(fire.state, 'EMBER');
  assert.equal('founder_hash' in fire, false, 'founder_hash must never reach the client');

  // The ring index must not leak either — and the founder's own fire is
  // badged with a boolean, not the hash.
  const list = await api('/api/fires');
  assert.equal(list.res.status, 200);
  for (const f of list.payload.fires) {
    assert.equal('founder_hash' in f, false);
  }
  assert.equal(list.payload.fires.find((f) => f.id === fire.id).is_founder, true);

  // A stranger's ring shows the same fire without the badge.
  cookies.clear();
  const strangerList = await api('/api/fires');
  assert.equal(strangerList.payload.fires.find((f) => f.id === fire.id).is_founder, false);
});

test('the fire room identifies the founder without shipping the hash', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Alapító tűz', question: null, ash_sentence: 'Kész, ha az alapító egyedül el tudja hozni a hamut.' },
  })).payload.fire;

  const mine = await api(`/api/fire/${created.slug}`);
  assert.equal(mine.res.status, 200);
  assert.equal(mine.payload.fire.is_founder, true);
  assert.equal('founder_hash' in mine.payload.fire, false);

  // A stranger — fresh cookie jar — is not the founder.
  cookies.clear();
  const stranger = await api(`/api/fire/${created.slug}`);
  assert.equal(stranger.payload.fire.is_founder, false);
  assert.equal('founder_hash' in stranger.payload.fire, false);
});

/* ---------------------------------------------------------------------------
 * Chairs, quotas, the Custodian
 * ------------------------------------------------------------------------ */

test('taking a chair without an established seat is refused', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Széktelen', question: null, ash_sentence: 'Kész, ha senki sem ül le szék nélkül.' },
  })).payload.fire;

  cookies.clear();
  const { res, payload } = await api('/api/chair', { method: 'POST', body: { fire_id: created.id } });
  assert.equal(res.status, 400);
  assert.match(payload.error, /széked/);
});

test('sitting down twice is idempotent', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Székek', question: null, ash_sentence: 'Kész, ha egy szék pontosan egy embert jelent.' },
  })).payload.fire;

  // Loading the fire page mints the seat.
  await api(`/api/fire/${created.slug}`);
  const first = await api('/api/chair', { method: 'POST', body: { fire_id: created.id } });
  assert.equal(first.res.status, 200);
  const again = await api('/api/chair', { method: 'POST', body: { fire_id: created.id } });
  assert.equal(again.payload.chairs, first.payload.chairs, 'a chair is one seat, not two');
});

test('the fire room walks the lattice backwards with ?before=', async () => {
  const fire = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Visszafelé', question: null, ash_sentence: 'Kész, ha a szoba visszafelé is végig tud sétálni.' },
  })).payload.fire;

  // 202 staggered waves plus 3 that share one second — seeded straight into
  // the lattice (the API quota would never allow 205 embers in a test).
  const base = 1_700_000_000;
  const insert = sqlite.prepare(`
    INSERT INTO waves (id, fire_id, essence, author_hash, wave32, vad_v, vad_a, vad_d,
                       amplitude, frequency, phase_deg, decay_tau, decision, ts, fingerprint, dampened)
    VALUES (?, ?, ?, 'seed', ?, 128, 128, 128, 0.5, 2.0, 90, 720, 'STORE', ?, ?, 0)
  `);
  for (let i = 0; i < 202; i++) {
    insert.run(`id-${String(i).padStart(3, '0')}`, fire.id, `seed ${i}`, Buffer.alloc(32), base + i, `fp-${i}`);
  }
  for (let i = 0; i < 3; i++) {
    insert.run(`tie-${i}`, fire.id, `tie ${i}`, Buffer.alloc(32), base - 1, `fp-tie-${i}`);
  }

  // Page 1: the 200 newest — all 202 staggered rows are newer than the tie,
  // so the page is 200 of them and the cursor points at the oldest one shown.
  const first = await api(`/api/fire/${fire.slug}`);
  assert.equal(first.payload.waves.length, 200);
  assert.ok(first.payload.next_before, 'a full page promises more');
  assert.ok(first.payload.next_before_id);

  // Page 2: the two leftover staggered waves plus the three tied ones.
  const second = await api(`/api/fire/${fire.slug}?before=${first.payload.next_before}&before_id=${first.payload.next_before_id}`);
  assert.equal(second.payload.waves.length, 5);
  for (const w of second.payload.waves) {
    assert.ok(
      w.ts < first.payload.next_before
      || (w.ts === first.payload.next_before && w.id < first.payload.next_before_id),
      'the cursor tie-break never repeats a row',
    );
  }
  assert.equal(second.payload.next_before, null, 'the walk ends at the oldest ember');
});

test('eight embers make a fire PARÁZS, and the ring says so', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Parázsba forduló', question: null, ash_sentence: 'Kész, ha nyolc parázstól égni kezd.' },
  })).payload.fire;

  for (let i = 0; i < 8; i++) {
    const { res } = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: distinct(i) } });
    assert.equal(res.status, 201, `ember ${i} stored`);
  }

  const after = await api(`/api/fire/${created.slug}`);
  assert.equal(after.payload.fire.state, 'PARÁZS');
  assert.equal(after.payload.fire.waves, 8);
});

test('rule 1 reinforces an exact duplicate and rule 3 stays dampened under reposts', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Őrzött', question: null, ash_sentence: 'Kész, ha az őrző szabályai itt is bizonyítanak.' },
  })).payload.fire;

  // An exact duplicate reinforces ×φ.
  const essence = distinct(11);
  const first = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence } });
  assert.equal(first.res.status, 201);
  const dup = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence } });
  assert.equal(dup.payload.decision, 'REINFORCE');
  assert.ok(dup.payload.wave.amplitude > first.payload.wave.amplitude);
  assert.equal('author_hash' in dup.payload.wave, false, 'REINFORCE must not leak the author hash');

  // A token flood is dampened — and stays dampened however often reposted.
  const flood = 'zaj zaj zaj zaj zaj zaj zaj';
  const damp = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: flood } });
  assert.equal(damp.res.status, 201);
  assert.ok(damp.payload.wave.amplitude < 0.05, `dampened to ${damp.payload.wave.amplitude}`);
  const repost = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: flood } });
  assert.equal(repost.res.status, 200);
  assert.ok(repost.payload.wave.amplitude < 0.05, 'a dampened wave stays dampened');
  assert.notEqual(repost.payload.decision, 'REINFORCE');
});

test('rule 2 holds a looping author and asks a quieter question', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Körök', question: 'Miért térsz vissza?', ash_sentence: 'Kész, ha egy kör megtörik itt.' },
  })).payload.fire;

  for (let i = 1; i <= 3; i++) {
    const { res } = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: nearDupe(i) } });
    assert.equal(res.status, 201, `near-duplicate ${i} stored`);
  }

  const held = await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: nearDupe(4) } });
  assert.equal(held.payload.cooldown, true, 'the fourth loop is held, not stored');
  assert.equal(held.payload.wave, null);

  const log = await api('/api/custodian');
  assert.ok(log.payload.entries.some((e) => e.action === 'COOLDOWN-HELD'));
});

test('the custodian log is readable and redacted', async () => {
  const created = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Naplós', question: null, ash_sentence: 'Kész, ha a napló nyilvános és üres marad a titkoktól.' },
  })).payload.fire;

  await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: distinct(21) } });
  await api('/api/ember', { method: 'POST', body: { fire_id: created.id, essence: distinct(21) } });

  const { payload } = await api('/api/custodian');
  assert.ok(payload.entries.length > 0);
  for (const e of payload.entries) {
    assert.equal('wave_id' in e, false);
    assert.ok(e.action && e.reason && e.ts);
  }
});

/* ---------------------------------------------------------------------------
 * Recall
 * ------------------------------------------------------------------------ */

test('recall at a fire searches that fire', async () => {
  const a = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Egyik tűz', question: null, ash_sentence: 'Kész, ha a felidézés csak ide szól.' },
  })).payload.fire;
  const b = (await api('/api/fires', {
    method: 'POST',
    body: { name: 'Másik tűz', question: null, ash_sentence: 'Kész, ha a felidézés csak ide szól, máshova nem.' },
  })).payload.fire;

  // The stored essence shares the query's text, hence its frequency: the
  // SQL band filter is guaranteed to include it, and the scoping is what the
  // test asserts.
  const q = 'kenyérrecept';
  await api('/api/ember', { method: 'POST', body: { fire_id: a.id, essence: q } });
  await api('/api/ember', { method: 'POST', body: { fire_id: b.id, essence: 'a kenyér receptje másutt ég' } });

  const { payload } = await api(`/api/resonate?q=${encodeURIComponent(q)}&fire=${a.id}`);
  assert.ok(payload.waves.length > 0);
  for (const w of payload.waves) {
    assert.equal(w.fire_id, a.id, 'scoped recall returns only the fire being searched');
    assert.equal('wave32_hex' in w, false);
    assert.equal('author_hash' in w, false);
  }
});

/* ---------------------------------------------------------------------------
 * Ash: HAMU, the capsule, the leave promise
 * ------------------------------------------------------------------------ */

async function lightFire(name, ash) {
  return (await api('/api/fires', {
    method: 'POST', body: { name, question: 'Mi marad a hamuban?', ash_sentence: ash },
  })).payload.fire;
}

test('only the founder can burn a fire to ash, and the .m8 lands on disk', async () => {
  const fire = await lightFire('Hamu-tűz', 'Kész, ha a kapszula a lemezen van.');
  for (let i = 0; i < 4; i++) {
    await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: distinct(30 + i) } });
  }
  await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: 'zaj zaj zaj zaj zaj zaj zaj' } });

  // A stranger cannot end the fire.
  cookies.clear();
  const stranger = await api(`/api/ash/${fire.slug}`, { method: 'POST', body: {} });
  assert.equal(stranger.res.status, 403);

  // The founder can. (Restore the founder's cookie from the page load.)
  const room = await api(`/api/fire/${fire.slug}`);
  assert.equal(room.payload.fire.is_founder, false, 'fresh jar is a stranger');

  // Re-establish the founder jar: the original cookie was created in lightFire.
  // Instead: create-and-burn in one cookie lifetime, so founder here.
  const own = await lightFire('Saját hamu', 'Kész, ha az alapító maga viszi hamuba.');
  await api('/api/ember', { method: 'POST', body: { fire_id: own.id, essence: distinct(40) } });
  const burn = await api(`/api/ash/${own.slug}`, { method: 'POST', body: {} });
  assert.equal(burn.res.status, 200, JSON.stringify(burn.payload));
  assert.equal(burn.payload.fire.state, 'HAMU');
  assert.ok(burn.payload.fire.ash_at);

  // The ash page serves it, and ?format=m8 is a real binary capsule.
  const ash = await api(`/api/ash/${own.slug}`);
  assert.equal(ash.res.status, 200);
  assert.equal(ash.payload.fire.state, 'HAMU');
  assert.ok(ash.payload.capsule.bytes > 0);

  const download = await fetch(`${BASE}/api/ash/${own.slug}?format=m8`);
  assert.equal(download.headers.get('content-type'), 'application/octet-stream');
  assert.ok(download.headers.get('x-content-type-options'), 'nosniff');
  const bytes = new Uint8Array(await download.arrayBuffer());

  mkdirSync(ARTIFACTS, { recursive: true });
  writeFileSync(`${ARTIFACTS}${own.slug}.m8`, bytes);

  const capsule = readCapsule(bytes);
  assert.equal(capsule.header.fire.slug, own.slug);
  assert.equal(capsule.header.fire.ash_at, burn.payload.fire.ash_at);
  assert.ok(capsule.header.wave_count >= 1);
  assert.equal(capsule.vectors.length, capsule.header.wave_count);

  // The dampened wave's 32 bytes say the same thing as its header (H20).
  for (const w of capsule.header.waves) {
    const decoded = decodeWave32(capsule.vectors[capsule.header.waves.indexOf(w)]);
    assert.ok(Math.abs(decoded.amplitude - w.amplitude) < 0.001,
      `blob amplitude ${decoded.amplitude} matches column ${w.amplitude}`);
    assert.equal(decoded.decision, w.decision);
    assert.equal(decoded.tau_hours, w.decay_tau);
  }
});

test('leave withdraws the waves, drops the stale capsule, and recounts the state', async () => {
  const fire = await lightFire('Távozó', 'Kész, ha a távozás tényleg távozás.');
  for (let i = 0; i < 8; i++) {
    await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: distinct(50 + i) } });
  }
  const before = await api(`/api/fire/${fire.slug}`);
  assert.equal(before.payload.fire.state, 'PARÁZS');

  const leave = await api('/api/leave', { method: 'POST', body: { fire_id: fire.id } });
  assert.equal(leave.payload.removed, 8);

  const after = await api(`/api/fire/${fire.slug}`);
  assert.equal(after.payload.fire.state, 'EMBER', 'an emptied fire is EMBER again, not a lie');
  assert.equal(after.payload.fire.waves, 0);
});

test('leaving an ashed fire rebuilds the capsule without the withdrawn waves', async () => {
  const fire = await lightFire('Hamuból távozó', 'Kész, ha a kapszula nem tart másolatot.');
  await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: distinct(60) } });
  await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: distinct(61) } });

  const burn = await api(`/api/ash/${fire.slug}`, { method: 'POST', body: {} });
  assert.equal(burn.res.status, 200);
  const first = await fetch(`${BASE}/api/ash/${fire.slug}?format=m8`);
  const firstCount = readCapsule(new Uint8Array(await first.arrayBuffer())).header.wave_count;
  assert.equal(firstCount, 2);

  const leave = await api('/api/leave', { method: 'POST', body: { fire_id: fire.id } });
  assert.equal(leave.payload.removed, 2);

  const second = await fetch(`${BASE}/api/ash/${fire.slug}?format=m8`);
  const rebuilt = readCapsule(new Uint8Array(await second.arrayBuffer()));
  assert.equal(rebuilt.header.wave_count, 0, 'the rebuilt capsule keeps no copy');
});

test('a fire that still burns has no ash', async () => {
  const fire = await lightFire('Még ég', 'Kész, ha egyszer kialszik.');
  const { res, payload } = await api(`/api/ash/${fire.slug}`);
  assert.equal(res.status, 409);
  assert.equal(payload.state, 'EMBER');
});

/* ---------------------------------------------------------------------------
 * The keeper (spec §3, M5)
 * ------------------------------------------------------------------------ */

test('the keeper outlives an absent founder and ashes the cold', async () => {
  const warm = await lightFire('Meleg túlélő', 'Kész, ha nélküled is ég.');
  await api('/api/ember', { method: 'POST', body: { fire_id: warm.id, essence: distinct(70) } });

  const cold = await lightFire('Hideg kihunyt', 'Kész, ha magától kialszik.');

  // Backdate both founders' chairs by 31 days.
  sqlite.prepare(`UPDATE chairs SET last_seen = last_seen - 31 * 86400 WHERE fire_id IN (?, ?)`)
    .run(warm.id, cold.id);

  const { payload } = await api('/api/keep', { method: 'POST' });
  const decisions = new Map(payload.kept.map((k) => [k.slug, k]));

  assert.equal(decisions.get(warm.slug)?.state, 'PARÁZS', 'warm fire keeps burning without its founder');
  assert.equal(decisions.get(cold.slug)?.state, 'HAMU', 'cold fire becomes ash on its own');

  const ash = await api(`/api/ash/${cold.slug}`);
  assert.equal(ash.res.status, 200);
  assert.equal(ash.payload.fire.state, 'HAMU');
  assert.ok(ash.payload.fire.ash_at, 'the keeper stamps the date');
});

test('the keeper is a no-op before thirty days', async () => {
  const fire = await lightFire('Korai', 'Kész, ha a harmincadik napon.');
  await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: distinct(80) } });
  const { payload } = await api('/api/keep', { method: 'POST' });
  assert.equal(payload.kept.length, 0);
});

/* ---------------------------------------------------------------------------
 * Quotas
 * ------------------------------------------------------------------------ */

test('a script cannot fill the lattice: the ember quota answers 429', async () => {
  const fire = await lightFire('Kvóta', 'Kész, ha a kvóta megállítja a gépet.');
  let last = null;
  for (let i = 0; i < 31; i++) {
    last = await api('/api/ember', { method: 'POST', body: { fire_id: fire.id, essence: distinct(90 + i) } });
  }
  assert.equal(last.res.status, 429, 'the 31st ember in an hour is too fast for a human');
});
