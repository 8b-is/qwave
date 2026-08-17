/**
 * bonfire — the fire room
 * ============================================================================
 * One fire: its chairs, its embers, and the lattice's memory of them.
 * ========================================================================== */

import { mountFire } from './fire-canvas.js';
import {
  composeWave, effectiveAmplitude, vadColor, vadLabel, pulseIndex,
} from '../../shared/wave.js';
import * as api from './api.js';
import {
  DEFAULT_LANG, RTL_LANGS, lang, relTimeT, setLang, t,
  translateError, translateReason, translateVadLabel,
} from '../../shared/i18n.js';

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
  return relTimeT(ts);
}

/* ---------------------------------------------------------------------------
 * Language
 * ------------------------------------------------------------------------ */

const LANG_KEY = 'bonfire.lang';

function applyI18n() {
  const l = lang();
  const html = document.documentElement;
  html.lang = l;
  html.dir = RTL_LANGS.has(l) ? 'rtl' : 'ltr';
  document.title = t('fire.title');
  document.querySelector('meta[name="description"]')?.setAttribute('content', t('fire.desc'));
  for (const node of document.querySelectorAll('[data-i18n]')) node.textContent = t(node.dataset.i18n);
  for (const node of document.querySelectorAll('[data-i18n-html]')) node.innerHTML = t(node.dataset.i18nHtml);
  for (const node of document.querySelectorAll('[data-i18n-ph]')) node.placeholder = t(node.dataset.i18nPh);
  for (const node of document.querySelectorAll('[data-i18n-attr]')) {
    for (const pair of node.dataset.i18nAttr.split(/\s+/)) {
      const [attr, key] = pair.split(':');
      if (attr && key) node.setAttribute(attr, t(key));
    }
  }
  for (const btn of document.querySelectorAll('.lang-switch button[data-lang]')) {
    btn.setAttribute('aria-pressed', String(btn.dataset.lang === l));
  }
}

function wireLangSwitch(onChange) {
  for (const btn of document.querySelectorAll('.lang-switch button[data-lang]')) {
    btn.addEventListener('click', () => {
      setLang(btn.dataset.lang);
      try { localStorage.setItem(LANG_KEY, btn.dataset.lang); } catch { /* fine */ }
      applyI18n();
      onChange?.();
    });
  }
}

const slug = new URLSearchParams(location.search).get('f');

let fire = null;
let canvas = null;
let allWaves = [];
let nextBefore = null;
let nextBeforeId = null;

/* ---------------------------------------------------------------------------
 * Rendering
 * ------------------------------------------------------------------------ */

function renderHead(f) {
  document.title = `${f.name} — bonfire`;
  $('#fire-head').hidden = false;
  $('#fire-name').textContent = f.name;
  $('#fire-question').textContent = f.question ? `„${f.question}”` : '';
  $('#fire-ash').textContent = ` ${f.ash_sentence}`;

  const stateEl = $('#fire-state');
  stateEl.textContent = f.state;
  stateEl.className = `state state-${f.state === 'PARÁZS' ? 'PARAZS' : f.state}`;

  $('#fire-pulse').textContent =
    f.pulse === 'daily' ? t('firecard.pulse.daily') : f.pulse === 'weekly' ? t('firecard.pulse.weekly') : t('firecard.pulse.none');
  $('#fire-age').textContent = t('fire.lit.ago', { t: relTime(f.created_at) });
  $('#fire-chairs').textContent = f.chairs ?? 0;
  $('#fire-waves').textContent = f.waves ?? 0;

  // Only the founder sees the way to end the fire, and only while it burns.
  const ashBtn = $('#ash-fire');
  if (ashBtn) ashBtn.hidden = !(f.is_founder && f.state !== 'HAMU');

  // The pulse (spec §2 pillar 3): a daily or weekly ember-prompt, derived
  // deterministically from the fire's question — the same prompt for everyone
  // who sits here today. A fire with no pulse shows nothing.
  const prompt = $('#fire-pulse-prompt');
  if (prompt) {
    const idx = pulseIndex(f.question ?? '', f.pulse, Math.floor(Date.now() / 1000));
    prompt.hidden = idx === null;
    if (idx !== null) {
      $('#fire-pulse-eyebrow').textContent =
        f.pulse === 'weekly' ? t('fire.pulse.eyebrow.weekly') : t('fire.pulse.eyebrow.daily');
      const key = `fire.pulse.prompt.${idx}`;
      const text = t(key, { q: f.question || f.name });
      $('#fire-pulse-text').textContent = text === key ? t('fire.pulse.prompt.0', { q: f.question || f.name }) : text;
    }
  }

  // A fire that has burned to ash does not accept new embers.
  if (f.state === 'HAMU') {
    const form = $('#ember-form');
    form.querySelectorAll('textarea, button').forEach((n) => { n.disabled = true; });
    const note = $('#ember-result');
    note.hidden = false;
    note.className = 'notice';
    note.textContent = t('fire.ashed.note');
  }
}

function waveItem(wave, index) {
  const vad = { v: wave.vad_v, a: wave.vad_a, d: wave.vad_d };
  const color = wave.color || vadColor(vad);
  const alive = effectiveAmplitude(
    { amplitude: wave.amplitude, decay_tau: wave.decay_tau, ts: wave.ts },
    Math.floor(Date.now() / 1000),
  );

  const meta = el('div', { class: 'wave-meta' }, [
    el('span', {}, [el('b', { text: `${(wave.frequency ?? 0).toFixed(2)} Hz` })]),
    el('span', { text: t('time.phase', { p: (wave.phase_deg ?? 0).toFixed(0) }) }),
    el('span', { text: `amp ${alive.toFixed(3)}` }),
    el('span', { text: translateVadLabel(wave.label || vadLabel(vad)) }),
    el('span', { class: 'faint', 'data-ts': wave.ts, text: relTime(wave.ts) }),
  ]);

  if (wave.relation) {
    // Recall results carry their own explanation: relation, phase gap, and
    // the resonance score that surfaced them.
    meta.append(el('span', {
      class: 'faint',
      text: `${wave.relation} · Δ${wave.delta_deg}° · rez ${Number(wave.resonance ?? 0).toFixed(3)}`,
    }));
  }

  return el('li', {
    class: 'wave-item',
    style: { '--wave-color': color, '--alive': String(alive.toFixed(3)), '--i': String(Math.min(index, 30)) },
  }, [
    el('div', { class: 'wave-bar' }),
    el('div', {}, [
      el('p', { class: 'wave-essence', text: wave.essence }),
      meta,
    ]),
  ]);
}

function renderWaves(waves, heading = t('fire.waves.title'), emptyText = t('fire.empty')) {
  $('#wave-heading').textContent = heading;
  const list = $('#wave-list');
  list.replaceChildren();

  // A wholesale list replacement is silent to assistive tech; say how many
  // waves arrived so a screen-reader user knows the recall answered.
  const announce = $('#wave-announce');
  if (announce) announce.textContent = t('fire.waves.aria.count', { h: heading, n: waves.length });

  if (!waves.length) {
    list.append(el('li', { class: 'empty', text: emptyText }));
    return;
  }
  waves.forEach((w, i) => list.append(waveItem(w, i)));
}

/** The room walks the lattice backwards: each page appends the 200 before it. */
function renderOlderButton() {
  const holder = $('#older-waves');
  if (!holder) return;
  holder.replaceChildren();
  if (nextBefore == null) return;
  holder.append(el('button', {
    class: 'btn btn-ghost btn-sm',
    type: 'button',
    text: t('fire.waves.older'),
    'data-i18n': 'fire.waves.older',
    onclick: loadOlder,
  }));
}

async function loadOlder() {
  if (!fire || nextBefore == null) return;
  try {
    const { waves, next_before, next_before_id } = await api.getFire(fire.slug, {
      before: nextBefore,
      before_id: nextBeforeId ?? '',
    });
    allWaves = [...allWaves, ...waves];
    nextBefore = next_before ?? null;
    nextBeforeId = next_before_id ?? null;
    renderWaves(allWaves);
    renderOlderButton();
  } catch (err) {
    renderOlderButton();
  }
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
    err.textContent = t('fire.noq');
    $('#wave-list').replaceChildren();
    return;
  }

  try {
    const { fire: f, waves, source, next_before, next_before_id } = await api.getFire(slug);
    fire = f;

    // A HAMU fire is an artifact now, not a room — go to the ash page.
    if (f.state === 'HAMU') {
      window.location.replace(`/ash.html?f=${encodeURIComponent(f.slug)}`);
      return;
    }

    allWaves = waves;
    nextBefore = next_before ?? null;
    nextBeforeId = next_before_id ?? null;
    renderHead(f);
    canvas?.setChairs(Math.min(f.chairs ?? 0, 40));
    renderWaves(waves);
    renderOlderButton();
    rippleAll(waves);

    // A local-ring fire is a read-only demo: no write button may look alive.
    if (source === 'local') {
      $('#ember-form').querySelectorAll('textarea, button').forEach((n) => { n.disabled = true; });
      $('#take-chair').disabled = true;
      $('#leave-fire').disabled = true;
      const note = $('#ember-result');
      note.hidden = false;
      note.className = 'notice';
      note.textContent = t('fire.local.readonly');
    }
  } catch (err) {
    const box = $('#fire-error');
    box.hidden = false;
    box.textContent = err.status === 404
      ? t('fire.gone')
      : t('fire.load.fail', { msg: translateError(err.message) });
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
      `${wave.frequency.toFixed(2)} Hz · ${wave.phase_deg.toFixed(0)}° · ${translateVadLabel(wave.label)}`;
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
        translateReason(res.reason, res.reason_en, res.reason_zh),
      );

      // Rule 2's hold: the wave was not stored — keep the text in the box
      // and show the fire's quieter question instead.
      if (res.cooldown && !res.wave) {
        result.append(el('div', { class: 'faint', style: { marginTop: '0.6rem' } },
          t('fire.cooldown.prompt', { q: fire.question || fire.name })));
      }

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
      result.textContent = translateError(err.message) || t('fire.ember.fail');
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
      status.textContent = t('fire.sitting');
    } catch (err) {
      status.textContent = translateError(err.message) || t('fire.chair.fail');
    }
  });

  // Custodian rule 5: an ember may always take back its own flame.
  $('#leave-fire').addEventListener('click', async () => {
    if (!fire) return;
    const ok = confirm(t('fire.leave.confirm'));
    if (!ok) return;

    try {
      const res = await api.leave(fire.id);
      status.textContent = res.removed
        ? t('fire.leave.done', { n: res.removed })
        : t('fire.leave.none');
      await load();
    } catch (err) {
      status.textContent = translateError(err.message) || t('fire.leave.fail');
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
        // Recall at a fire searches that fire — the scoping happens in the
        // lattice, not by filtering a global top-k down client-side.
        const { waves } = await api.resonate(q, fire?.id);
        renderWaves(waves, t('fire.resonate.heading', { q }), t('fire.resonate.empty'));
      } catch (err) {
        renderWaves([], t('fire.resonate.fail', { msg: translateError(err.message) }));
      }
    }, 260);
  });
}

function initAsh() {
  const btn = $('#ash-fire');
  if (!btn) return;

  btn.addEventListener('click', async () => {
    if (!fire) return;
    const ok = confirm(t('fire.ash.confirm', { ash: fire.ash_sentence }));
    if (!ok) return;

    try {
      await api.burnToAsh(fire.slug);
      window.location.href = `/ash.html?f=${encodeURIComponent(fire.slug)}`;
    } catch (err) {
      const status = $('#chair-status');
      status.textContent = translateError(err.message) || t('fire.ash.fail');
    }
  });
}

async function initLatticeBanner() {
  const banner = $('#lattice-status');
  const render = (live) => {
    banner.hidden = live;
    if (!live) {
      banner.textContent = t('banner.local.room');
    }
  };
  api.onLiveChange(render);
  render(await api.probe());
}

/* ---------------------------------------------------------------------------
 * Boot
 * ------------------------------------------------------------------------ */

function boot() {
  try { setLang(localStorage.getItem(LANG_KEY) || DEFAULT_LANG); } catch { setLang(DEFAULT_LANG); }
  applyI18n();
  wireLangSwitch(() => load());

  canvas = mountFire('#room-fire', { chairs: 0, intensity: 1.15, origin: [0.5, 0.68] });
  initEmberForm();
  initChair();
  initAsh();
  initResonate();
  initLatticeBanner();
  initRelTimeTicker();
  load();

  // Relative times age honestly: refresh them once a minute, quietly.
  function initRelTimeTicker() {
    setInterval(() => {
      document.querySelectorAll('[data-ts]').forEach((node) => {
        node.textContent = relTime(Number(node.dataset.ts));
      });
    }, 60_000);
  }
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();
