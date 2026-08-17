/**
 * bonfire — API client
 * ============================================================================
 * Talks to the Pages Functions in /functions/api. If the lattice is not bound
 * (no D1 yet, or a static preview), *reads* fall back to a local ring so the
 * site stays explorable — and the banner says so, loudly. *Writes* never fall
 * back: the local ring is a read-only demo, because a visitor must never
 * believe their ember reached the fire when it only reached localStorage.
 * ========================================================================== */

import { composeWave, resynthesise, vadColor, vadLabel } from '../../shared/wave.js';

export const state = {
  /** null = not yet probed, true = D1 is answering, false = local ring. */
  live: null,
  /** ms timestamp of the last probe; demotions get re-checked. */
  probedAt: 0,
};

const PROBE_TTL_MS = 30_000;

const liveListeners = new Set();

/** Subscribe to live/local changes so banners re-render the moment the
 *  lattice comes up or goes away mid-session. */
export function onLiveChange(fn) {
  liveListeners.add(fn);
  return () => liveListeners.delete(fn);
}

function setLive(value) {
  if (state.live === value) return;
  state.live = value;
  for (const fn of liveListeners) { try { fn(value); } catch { /* observer broke */ } }
}

const LOCAL_KEY = 'bonfire.local-ring.v1';
const HOUR = 3600;

/** Seed fires for the local ring. Each one carries a real ash sentence,
 *  because a fire without declared ash is not a fire (spec §2, pillar 1). */
const SEED = {
  fires: [
    {
      id: 'seed-1', slug: 'mit-viszunk-tovabb',
      name: 'Mit viszünk tovább',
      question: 'Mi az az egy dolog, amit a régi életedből átviszel a következőbe?',
      ash_sentence: 'Kész, ha huszonhét ember leírta a magáét, és egyik sem ismételte a másikat.',
      pulse: 'daily', state: 'PARÁZS',
      created_at: nowSec() - 26 * 24 * HOUR, ash_at: null,
      founder_hash: 'seed', chairs: 27, waves: 34,
    },
    {
      id: 'seed-2', slug: 'a-csend-helye',
      name: 'A csend helye',
      question: 'Hol vagy csendben, és mit hallasz meg ott?',
      ash_sentence: 'Kész, ha a tűz egy hónapig ég anélkül, hogy bárki megkérdezné, mi a célja.',
      pulse: 'weekly', state: 'EMBER',
      created_at: nowSec() - 9 * 24 * HOUR, ash_at: null,
      founder_hash: 'seed', chairs: 11, waves: 12,
    },
    {
      id: 'seed-3', slug: 'az-elso-tuz',
      name: 'Az első tűz',
      question: 'Miért ülsz le egy tűzhöz, amit nem te gyújtottál?',
      ash_sentence: 'Kész, ha az alapítója harminc napja nincs itt, és a tűz még mindig rezonál.',
      pulse: 'none', state: 'HAMU',
      created_at: nowSec() - 94 * 24 * HOUR, ash_at: nowSec() - 5 * 24 * HOUR,
      founder_hash: 'seed', chairs: 42, waves: 61,
    },
  ],
  essences: [
    ['seed-1', 'A nagymamám kenyérreceptjét. Nem a papírt — a kezét a tésztában.', 30 * HOUR],
    ['seed-1', 'Azt a szokást, hogy megvárom, amíg a másik befejezi a mondatát.', 22 * HOUR],
    ['seed-1', 'Semmit. Azt hiszem ez a lényeg, és ez fáj.', 14 * HOUR],
    ['seed-1', 'Egy nevet, amit már senki más nem mond ki hangosan.', 6 * HOUR],
    ['seed-2', 'A lépcsőházban, két emelet között. Ott hallom meg, hogy fáradt vagyok.', 40 * HOUR],
    ['seed-2', 'Silence is where I stop performing. What I hear is how loud the performance was.', 18 * HOUR],
    ['seed-2', 'A konyhában hajnali négykor. A hűtő zúgása. Ennyi. Elég.', 3 * HOUR],
    ['seed-3', 'Mert valaki más már megcsinálta a nehezét, és ez tiszteletre méltó.', 80 * 24 * HOUR],
    ['seed-3', 'Mert egyedül nem tudok tüzet gyújtani, csak melegedni tudok.', 60 * 24 * HOUR],
  ],
};

function nowSec() { return Math.floor(Date.now() / 1000); }

/* ---------------------------------------------------------------------------
 * Transport
 * ------------------------------------------------------------------------ */

async function request(path, { method = 'GET', body } = {}) {
  const res = await fetch(path, {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });

  let payload = null;
  try { payload = await res.json(); } catch { /* non-JSON — handled below */ }

  if (!res.ok) {
    const err = new Error(payload?.error || `HTTP ${res.status}`);
    err.status = res.status;
    err.payload = payload;
    throw err;
  }
  return payload;
}

/** Probe: is the lattice bound and answering? Cached with a short TTL so a
 *  demotion mid-session is noticed instead of trusted forever. */
export async function probe() {
  if (state.live !== null && Date.now() - state.probedAt < PROBE_TTL_MS) return state.live;
  state.probedAt = Date.now();
  try {
    const res = await fetch('/api/health', { method: 'GET' });
    const body = await res.json();
    setLive(res.ok && body?.lattice === 'bound');
  } catch {
    setLive(false);
  }
  return state.live;
}

/** Run `remote`, falling back to `local` when the lattice is not available.
 *  Reads only: a visitor may always browse the demo ring. Writes never come
 *  through here — see `write()`. */
async function withFallback(remote, local) {
  if (await probe()) {
    try {
      return await remote();
    } catch (err) {
      // A 4xx is a real answer from a real lattice — surface it. Only fall
      // back when the lattice itself is the thing that failed.
      if (err.status && err.status < 500) throw err;
      setLive(false);
    }
  }
  return local();
}

/**
 * A write must never land in localStorage while the visitor believes it
 * reached the fire. No lattice → an error that says so, and the text stays
 * in the box. The local ring is a read-only demo.
 */
async function write(path, body) {
  if (!(await probe())) {
    const err = new Error('A rács nincs bekötve ehhez a példányhoz.');
    err.status = 503;
    throw err;
  }
  return request(path, { method: 'POST', body });
}

/* ---------------------------------------------------------------------------
 * The local ring — a faithful, clearly-labelled stand-in
 * ------------------------------------------------------------------------ */

function loadLocal() {
  try {
    const raw = localStorage.getItem(LOCAL_KEY);
    if (raw) return JSON.parse(raw);
  } catch { /* storage blocked — fall through to a fresh ring */ }
  return null;
}

function saveLocal(ring) {
  try { localStorage.setItem(LOCAL_KEY, JSON.stringify(ring)); } catch { /* fine */ }
}

let ringPromise = null;

async function ring() {
  if (ringPromise) return ringPromise;
  ringPromise = (async () => {
    const stored = loadLocal();
    if (stored) return stored;

    const fresh = { fires: SEED.fires.map((f) => ({ ...f })), waves: [], chairs: [] };
    for (const [fireId, essence, age] of SEED.essences) {
      const wave = await composeWave(essence, { recentFingerprints: [] });
      fresh.waves.push({
        id: `seed-${fresh.waves.length}`,
        fire_id: fireId,
        essence,
        author_hash: 'seed',
        vad_v: wave.vad.v, vad_a: wave.vad.a, vad_d: wave.vad.d,
        amplitude: wave.amplitude,
        frequency: wave.frequency,
        phase_deg: wave.phase_deg,
        decay_tau: wave.tau_hours,
        decision: wave.decision,
        wave32_hex: wave.wave32_hex,
        ts: nowSec() - age,
      });
    }
    saveLocal(fresh);
    return fresh;
  })();
  return ringPromise;
}

function decorate(wave) {
  const vad = { v: wave.vad_v, a: wave.vad_a, d: wave.vad_d };
  return { ...wave, color: vadColor(vad), label: vadLabel(vad) };
}

/* ---------------------------------------------------------------------------
 * Public surface — mirrors the API table in spec §6
 * ------------------------------------------------------------------------ */

export async function listFires() {
  return withFallback(
    () => request('/api/fires'),
    async () => {
      const r = await ring();
      const fires = r.fires.map((f) => ({
        ...f,
        waves: r.waves.filter((w) => w.fire_id === f.id).length || f.waves || 0,
        chairs: f.chairs ?? 0,
      }));
      return { fires, source: 'local' };
    },
  );
}

export async function getFire(slug, { before, before_id } = {}) {
  const params = new URLSearchParams();
  if (before) { params.set('before', before); params.set('before_id', before_id ?? ''); }
  const qs = params.toString();
  return withFallback(
    () => request(`/api/fire/${encodeURIComponent(slug)}${qs ? `?${qs}` : ''}`),
    async () => {
      const r = await ring();
      const fire = r.fires.find((f) => f.slug === slug);
      if (!fire) { const e = new Error('Nincs ilyen tűz.'); e.status = 404; throw e; }
      const waves = r.waves
        .filter((w) => w.fire_id === fire.id && (!before || w.ts < before))
        .sort((a, b) => b.ts - a.ts)
        .slice(0, 200)
        .map(decorate);
      return { fire: { ...fire, waves: waves.length }, waves, next_before: null, next_before_id: null, source: 'local' };
    },
  );
}

export async function createFire({ name, question, ash_sentence, pulse = 'none' }) {
  // Writes are lattice-only: a transient 500 must not turn into a local-only
  // fire that vanishes the moment the next page re-probes.
  return write('/api/fires', { name, question, ash_sentence, pulse });
}

export async function postEmber({ fire_id, essence }) {
  return write('/api/ember', { fire_id, essence });
}

export async function takeChair(fire_id) {
  return write('/api/chair', { fire_id });
}

export async function resonate(q, fireId) {
  const fireParam = fireId ? `&fire=${encodeURIComponent(fireId)}` : '';
  return withFallback(
    () => request(`/api/resonate?q=${encodeURIComponent(q)}${fireParam}`),
    async () => {
      const r = await ring();
      // Recall at a fire searches that fire — mirrored in the local branch.
      const scoped = fireId ? r.waves.filter((w) => w.fire_id === fireId) : r.waves;
      const hits = await resynthesise(q, scoped, { topK: 8 });
      return { query: q, waves: hits.map(decorate), source: 'local' };
    },
  );
}

export async function getAsh(slug) {
  return withFallback(
    () => request(`/api/ash/${encodeURIComponent(slug)}`),
    async () => {
      const { fire, waves } = await getFire(slug);
      return { fire, waves, capsule: null, source: 'local' };
    },
  );
}

export async function leave(fire_id) {
  return write('/api/leave', { fire_id });
}

/** The founder's own write: "the ash sentence is fulfilled" (spec §1). */
export async function burnToAsh(slug) {
  return write(`/api/ash/${encodeURIComponent(slug)}`, {});
}

/** The lattice's own answer to "is it up" plus the DoD's live counters. */
export async function health() {
  return withFallback(
    () => request('/api/health'),
    async () => ({ lattice: 'unbound', stats: null, source: 'local' }),
  );
}

/** The Custodian's own trace (spec §7), paginated. A read, so the local ring
 *  answers honestly: no lattice, no log. */
export async function custodianLog(cursor = 0) {
  const param = cursor > 0 ? `?cursor=${cursor}` : '';
  return withFallback(
    () => request(`/api/custodian${param}`),
    async () => ({ entries: [], cursor: 0, done: true, source: 'local' }),
  );
}
