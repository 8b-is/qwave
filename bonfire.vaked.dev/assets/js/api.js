/**
 * bonfire — API client
 * ============================================================================
 * Talks to the Pages Functions in /functions/api. If the lattice is not bound
 * (no D1 yet, or a static preview), it falls back to a local ring so the fire
 * still burns and the site is explorable — but it says so, loudly, in the UI.
 * A visitor should never be unable to tell whether the lattice is real.
 * ========================================================================== */

import { composeWave, resynthesise, slugify, vadColor, vadLabel, PHI } from '../../shared/wave.js';

export const state = {
  /** null = not yet probed, true = D1 is answering, false = local ring. */
  live: null,
};

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

/** Probe once: is the lattice bound and answering? */
export async function probe() {
  if (state.live !== null) return state.live;
  try {
    const res = await fetch('/api/health', { method: 'GET' });
    const body = await res.json();
    state.live = res.ok && body?.lattice === 'bound';
  } catch {
    state.live = false;
  }
  return state.live;
}

/** Run `remote`, falling back to `local` when the lattice is not available. */
async function withFallback(remote, local) {
  if (await probe()) {
    try {
      return await remote();
    } catch (err) {
      // A 4xx is a real answer from a real lattice — surface it. Only fall
      // back when the lattice itself is the thing that failed.
      if (err.status && err.status < 500) throw err;
      state.live = false;
    }
  }
  return local();
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

export async function getFire(slug) {
  return withFallback(
    () => request(`/api/fire/${encodeURIComponent(slug)}`),
    async () => {
      const r = await ring();
      const fire = r.fires.find((f) => f.slug === slug);
      if (!fire) { const e = new Error('Nincs ilyen tűz.'); e.status = 404; throw e; }
      const waves = r.waves
        .filter((w) => w.fire_id === fire.id)
        .sort((a, b) => b.ts - a.ts)
        .map(decorate);
      return { fire: { ...fire, waves: waves.length }, waves, source: 'local' };
    },
  );
}

export async function createFire({ name, question, ash_sentence, pulse = 'none' }) {
  return withFallback(
    () => request('/api/fires', { method: 'POST', body: { name, question, ash_sentence, pulse } }),
    async () => {
      const r = await ring();
      const slug = uniqueSlug(slugify(name), r.fires);
      const fire = {
        id: `local-${Date.now()}`, slug, name, question, ash_sentence, pulse,
        state: 'EMBER', created_at: nowSec(), ash_at: null,
        founder_hash: 'local', chairs: 1, waves: 0,
      };
      r.fires.unshift(fire);
      saveLocal(r);
      return { fire, source: 'local' };
    },
  );
}

function uniqueSlug(base, fires) {
  let slug = base;
  let n = 2;
  while (fires.some((f) => f.slug === slug)) slug = `${base}-${n++}`;
  return slug;
}

export async function postEmber({ fire_id, essence }) {
  return withFallback(
    () => request('/api/ember', { method: 'POST', body: { fire_id, essence } }),
    async () => {
      const r = await ring();
      const mine = r.waves.filter((w) => w.fire_id === fire_id);
      const recent = mine.slice(-12).map((w) => w.wave32_hex?.slice(0, 32)).filter(Boolean);

      const built = await composeWave(essence, { recentFingerprints: recent });
      const duplicate = mine.find((w) => w.wave32_hex?.slice(0, 32) === built.fingerprint);

      if (duplicate) {
        // Custodian rule 1 — reinforce ×φ, drop the duplicate.
        duplicate.amplitude = Math.min(duplicate.amplitude * PHI, 1);
        saveLocal(r);
        return {
          decision: 'REINFORCE',
          reason: 'Ez a parázs már ég itt — megerősítettük ×φ.',
          wave: decorate(duplicate),
          source: 'local',
        };
      }

      if (built.decision === 'DROP') {
        return { decision: 'DROP', reason: built.reason, wave: null, source: 'local' };
      }

      const wave = {
        id: `local-${Date.now()}`,
        fire_id, essence, author_hash: 'local',
        vad_v: built.vad.v, vad_a: built.vad.a, vad_d: built.vad.d,
        amplitude: built.amplitude, frequency: built.frequency,
        phase_deg: built.phase_deg, decay_tau: built.tau_hours,
        decision: built.decision, wave32_hex: built.wave32_hex,
        ts: nowSec(),
      };
      r.waves.push(wave);
      saveLocal(r);
      return { decision: built.decision, reason: built.reason, wave: decorate(wave), source: 'local' };
    },
  );
}

export async function takeChair(fire_id) {
  return withFallback(
    () => request('/api/chair', { method: 'POST', body: { fire_id } }),
    async () => {
      const r = await ring();
      const fire = r.fires.find((f) => f.id === fire_id);
      if (fire) { fire.chairs = (fire.chairs ?? 0) + 1; saveLocal(r); }
      return { chair_id: `local-chair-${Date.now()}`, chairs: fire?.chairs ?? 1, source: 'local' };
    },
  );
}

export async function resonate(q) {
  return withFallback(
    () => request(`/api/resonate?q=${encodeURIComponent(q)}`),
    async () => {
      const r = await ring();
      const hits = await resynthesise(q, r.waves, { topK: 8 });
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
  return withFallback(
    () => request('/api/leave', { method: 'POST', body: { fire_id } }),
    async () => {
      const r = await ring();
      const before = r.waves.length;
      r.waves = r.waves.filter((w) => !(w.fire_id === fire_id && w.author_hash === 'local'));
      saveLocal(r);
      return { removed: before - r.waves.length, source: 'local' };
    },
  );
}
