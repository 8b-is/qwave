/**
 * bonfire — the fire room
 * ============================================================================
 * One fire: its chairs, its embers, and the lattice's memory of them.
 * ========================================================================== */

import { mountFire } from './fire-canvas.js';
import { composeWave, effectiveAmplitude, vadColor, vadLabel } from '../../shared/wave.js';
import * as api from './api.js';

const $ = (sel, root = document) => root.querySelector(sel);

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(node.style, v);
    else node.setAttribute(k, v);
  }
  for (const child of [].concat(children)) {
    if (child == null) continue;
    node.append(child.nodeType ? child : document.createTextNode(child));
  }
  return node;
}

function relTime(ts) {
  const seconds = Math.max(Math.floor(Date.now() / 1000) - ts, 0);
  if (seconds < 90) return 'most';
  const mins = Math.floor(seconds / 60);
  if (mins < 60) return `${mins} perce`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours} órája`;
  return `${Math.floor(hours / 24)} napja`;
}

const slug = new URLSearchParams(location.search).get('f');

let fire = null;
let canvas = null;

/* ---------------------------------------------------------------------------
 * Rendering
 * ------------------------------------------------------------------------ */

function renderHead(f) {
  document.title = `${f.name} — bonfire`;
  $('#fire-head').hidden = false;
  $('#fire-name').textContent = f.name;
  $('#fire-question').textContent = f.question ? `„${f.question}"` : '';
  $('#fire-ash').textContent = ` ${f.ash_sentence}`;

  const stateEl = $('#fire-state');
  stateEl.textContent = f.state;
  stateEl.className = `state state-${f.state === 'PARÁZS' ? 'PARAZS' : f.state}`;

  $('#fire-pulse').textContent =
    f.pulse === 'daily' ? 'napi pulzus' : f.pulse === 'weekly' ? 'heti pulzus' : 'pulzus nélkül';
  $('#fire-age').textContent = `meggyújtva ${relTime(f.created_at)}`;
  $('#fire-chairs').textContent = f.chairs ?? 0;
  $('#fire-waves').textContent = f.waves ?? 0;

  // A fire that has burned to ash does not accept new embers.
  if (f.state === 'HAMU') {
    const form = $('#ember-form');
    form.querySelectorAll('textarea, button').forEach((n) => { n.disabled = true; });
    const note = $('#ember-result');
    note.hidden = false;
    note.className = 'notice';
    note.textContent = 'Ez a tűz hamuvá égett. A hamu-mondata teljesült — a kör lezárult, '
      + 'de a rács megtartja, ami elhangzott.';
  }
}

function waveItem(wave) {
  const vad = { v: wave.vad_v, a: wave.vad_a, d: wave.vad_d };
  const color = wave.color || vadColor(vad);
  const alive = effectiveAmplitude(
    { amplitude: wave.amplitude, decay_tau: wave.decay_tau, ts: wave.ts },
    Math.floor(Date.now() / 1000),
  );

  const meta = el('div', { class: 'wave-meta' }, [
    el('span', {}, [el('b', { text: `${(wave.frequency ?? 0).toFixed(2)} Hz` })]),
    el('span', { text: `${(wave.phase_deg ?? 0).toFixed(0)}° fázis` }),
    el('span', { text: `amp ${alive.toFixed(3)}` }),
    el('span', { text: wave.label || vadLabel(vad) }),
    el('span', { class: 'faint', text: relTime(wave.ts) }),
  ]);

  if (wave.relation) {
    meta.append(el('span', { class: 'faint', text: `${wave.relation} · Δ${wave.delta_deg}°` }));
  }

  return el('li', {
    class: 'wave-item',
    style: { '--wave-color': color, '--alive': String(alive.toFixed(3)) },
  }, [
    el('div', { class: 'wave-bar' }),
    el('div', {}, [
      el('p', { class: 'wave-essence', text: wave.essence }),
      meta,
    ]),
  ]);
}

function renderWaves(waves, heading = 'A parazsak') {
  $('#wave-heading').textContent = heading;
  const list = $('#wave-list');
  list.replaceChildren();

  if (!waves.length) {
    list.append(el('li', { class: 'empty', text: 'Még csend van. Te lehetsz az első parázs.' }));
    return;
  }
  waves.forEach((w) => list.append(waveItem(w)));
}

/** Send each visible wave out across the canvas, staggered, on first paint. */
function rippleAll(waves) {
  if (!canvas) return;
  waves.slice(0, 10).reverse().forEach((w, i) => {
    setTimeout(() => canvas.ripple({
      amplitude: w.amplitude,
      frequency: w.frequency,
      phase_deg: w.phase_deg,
      color: w.color || vadColor({ v: w.vad_v, a: w.vad_a, d: w.vad_d }),
    }), i * 220);
  });
}

/* ---------------------------------------------------------------------------
 * Actions
 * ------------------------------------------------------------------------ */

async function load() {
  if (!slug) {
    const err = $('#fire-error');
    err.hidden = false;
    err.textContent = 'Nincs megadva tűz. Menj vissza a gyűrűhöz, és válassz egyet.';
    $('#wave-list').replaceChildren();
    return;
  }

  try {
    const { fire: f, waves } = await api.getFire(slug);
    fire = f;
    renderHead(f);
    canvas?.setChairs(Math.min(f.chairs ?? 0, 40));
    renderWaves(waves);
    rippleAll(waves);
  } catch (err) {
    const box = $('#fire-error');
    box.hidden = false;
    box.textContent = err.status === 404
      ? 'Nincs ilyen tűz. Lehet, hogy már hamuvá égett és elvitték a kapszuláját.'
      : `Nem sikerült betölteni a tüzet: ${err.message}`;
    $('#wave-list').replaceChildren();
  }
}

function initEmberForm() {
  const form = $('#ember-form');
  const input = $('#ember-input');
  const preview = $('#ember-preview');
  const result = $('#ember-result');
  const submit = $('#ember-submit');

  // A quiet live read of what the gate is about to see.
  let token = 0;
  input.addEventListener('input', async () => {
    const mine = ++token;
    const text = input.value.trim();
    if (!text) { preview.textContent = ''; return; }
    const wave = await composeWave(text, { recentFingerprints: [] });
    if (mine !== token) return;
    preview.textContent =
      `${wave.frequency.toFixed(2)} Hz · ${wave.phase_deg.toFixed(0)}° · ${wave.label}`;
    preview.style.color = wave.color;
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const essence = input.value.trim();
    if (!essence || !fire) return;

    submit.disabled = true;
    result.hidden = true;

    try {
      const res = await api.postEmber({ fire_id: fire.id, essence });

      result.hidden = false;
      result.className = res.decision === 'DROP' ? 'notice notice-err' : 'notice';
      result.innerHTML = '';
      result.append(
        el('span', { class: `decision decision-${res.decision}`, text: res.decision }),
        ' ',
        res.reason || '',
      );

      if (res.wave) {
        canvas?.ripple({
          amplitude: res.wave.amplitude,
          frequency: res.wave.frequency,
          phase_deg: res.wave.phase_deg,
          color: res.wave.color || vadColor({ v: res.wave.vad_v, a: res.wave.vad_a, d: res.wave.vad_d }),
        });
        input.value = '';
        preview.textContent = '';
        await load();
      }
    } catch (err) {
      result.hidden = false;
      result.className = 'notice notice-err';
      result.textContent = err.message || 'A parázs nem jutott el a tűzig.';
    } finally {
      submit.disabled = false;
    }
  });
}

function initChair() {
  const status = $('#chair-status');

  $('#take-chair').addEventListener('click', async () => {
    if (!fire) return;
    try {
      const res = await api.takeChair(fire.id);
      $('#fire-chairs').textContent = res.chairs ?? '—';
      canvas?.setChairs(Math.min(res.chairs ?? 1, 40));
      status.textContent = 'Leültél. Nem kérünk nevet, és nem is fogunk.';
    } catch (err) {
      status.textContent = err.message || 'A szék nem sikerült.';
    }
  });

  // Custodian rule 5: an ember may always take back its own flame.
  $('#leave-fire').addEventListener('click', async () => {
    if (!fire) return;
    const ok = confirm(
      'Elviszed a lángod?\n\nMinden hullám, amit ehhez a tűzhöz dobtál, eltűnik a rácsból. '
      + 'Ez a te döntésed — nem kérdezünk vissza, és nem tartunk másolatot.',
    );
    if (!ok) return;

    try {
      const res = await api.leave(fire.id);
      status.textContent = res.removed
        ? `${res.removed} hullámod visszavéve. Ott voltál.`
        : 'Nem volt itt hullámod.';
      await load();
    } catch (err) {
      status.textContent = err.message || 'Nem sikerült.';
    }
  });
}

function initResonate() {
  const input = $('#resonate-input');
  let timer = null;

  input.addEventListener('input', () => {
    clearTimeout(timer);
    const q = input.value.trim();

    timer = setTimeout(async () => {
      if (!q) { await load(); return; }
      try {
        const { waves } = await api.resonate(q);
        const scoped = fire ? waves.filter((w) => w.fire_id === fire.id) : waves;
        renderWaves(scoped, `Rezonancia — „${q}"`);
      } catch (err) {
        renderWaves([], `Nem sikerült a felidézés: ${err.message}`);
      }
    }, 260);
  });
}

async function initLatticeBanner() {
  const banner = $('#lattice-status');
  const live = await api.probe();
  banner.hidden = live;
  if (!live) {
    banner.textContent =
      'A rács még nincs bekötve — ez a tűz a böngésződben ég, és csak nálad marad. '
      + 'A kapu és a hullámmotor viszont ugyanaz a kód, ami az éles rácsban fut.';
  }
}

/* ---------------------------------------------------------------------------
 * Boot
 * ------------------------------------------------------------------------ */

function boot() {
  canvas = mountFire('#room-fire', { chairs: 0, intensity: 1.15, origin: [0.5, 0.68] });
  initEmberForm();
  initChair();
  initResonate();
  initLatticeBanner();
  load();
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();
