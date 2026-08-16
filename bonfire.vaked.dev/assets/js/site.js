/**
 * bonfire — landing page behaviour
 * ============================================================================
 * Three jobs:
 *   1. Ambient polish (reveal-on-scroll, pointer-tracked firelight).
 *   2. The live encoder — type an essence, watch it become a wave. Runs
 *      entirely client-side against shared/wave.js, so it works with no
 *      backend at all.
 *   3. The fire index + "light a fire" form, which do talk to /api.
 * ========================================================================== */

import { mountFire } from './fire-canvas.js';
import {
  composeWave, decayFactor, phaseRelation, phiHarmonics, resynthesise,
  WAVE, TAU_HOURS, PHI,
} from '../../shared/wave.js';
import * as api from './api.js';
import {
  DEFAULT_LANG, RTL_LANGS, lang, relTimeT, setLang, t,
  translateError, translateReason, translateVadLabel,
} from '../../shared/i18n.js';

/* ---------------------------------------------------------------------------
 * Language
 * ------------------------------------------------------------------------ */

const LANG_KEY = 'bonfire.lang';

function applyI18n() {
  const l = lang();
  const html = document.documentElement;
  html.lang = l;
  html.dir = RTL_LANGS.has(l) ? 'rtl' : 'ltr';
  document.title = t('site.title');
  document.querySelector('meta[name="description"]')?.setAttribute('content', t('site.desc'));
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

/* ---------------------------------------------------------------------------
 * Ambient
 * ------------------------------------------------------------------------ */

function initReveal() {
  const items = document.querySelectorAll('.reveal');
  if (!items.length) return;
  if (!('IntersectionObserver' in window)) {
    items.forEach((el) => el.classList.add('in'));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      }
    }
  }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });
  items.forEach((el) => io.observe(el));
}

/**
 * The constellation ambient layer (spec §8: music.vaked.dev at 0.25 opacity).
 *
 * Mounted from JS rather than sitting in the HTML, because a cross-origin
 * iframe that fails to load renders the browser's own error document — a pale
 * full-viewport slab that washes the fire out completely. So: probe first, and
 * only bring the constellation in if it actually answers. If the network is
 * blocked, or the visitor asked for reduced motion, the page simply stays dark.
 */
async function initAmbient() {
  const holder = document.getElementById('constellation-ambient');
  if (!holder) return;
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const SRC = 'https://music.vaked.dev/';
  try {
    // A standard CORS fetch lets us check res.ok (which fails if the network
    // is blocked by an adblocker returning a synthetic 403, or if the server is down).
    const res = await fetch(SRC, { cache: 'no-store', signal: AbortSignal.timeout(4000) });
    if (!res.ok) return;
  } catch {
    return;
  }

  const frame = document.createElement('iframe');
  frame.className = 'constellation-ambient';
  frame.src = SRC;
  frame.title = '';
  frame.tabIndex = -1;
  frame.setAttribute('aria-hidden', 'true');
  frame.setAttribute('loading', 'lazy');
  frame.setAttribute('referrerpolicy', 'no-referrer');
  holder.replaceWith(frame);
}

/** Pointer-tracked firelight on cards (CSS reads --mx/--my). */
function initSpotlight() {
  if (window.matchMedia('(hover: none)').matches) return;
  document.addEventListener('pointermove', (e) => {
    const card = e.target.closest?.('.card');
    if (!card) return;
    const r = card.getBoundingClientRect();
    card.style.setProperty('--mx', `${((e.clientX - r.left) / r.width) * 100}%`);
    card.style.setProperty('--my', `${((e.clientY - r.top) / r.height) * 100}%`);
  }, { passive: true });
}

/* ---------------------------------------------------------------------------
 * Small helpers
 * ------------------------------------------------------------------------ */

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2).toLowerCase(), v);
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

/** Which 32-byte field does this offset belong to? Drives the byte-grid tints. */
function fieldAt(i) {
  if (i < WAVE.AMPLITUDE) return 'fingerprint';
  if (i < WAVE.FREQUENCY) return 'amplitude';
  if (i < WAVE.PHASE) return 'frequency';
  if (i < WAVE.DECAY) return 'phase';
  if (i < WAVE.VERSION) return 'decay';
  return 'reserved';
}

/* ---------------------------------------------------------------------------
 * The live encoder — the showpiece
 * ------------------------------------------------------------------------ */

function initEncoder(fire) {
  const input = $('#encoder-input');
  if (!input) return;

  const grid = $('#encoder-bytes');
  const out = {
    decision: $('#enc-decision'),
    reason: $('#enc-reason'),
    amplitude: $('#enc-amplitude'),
    frequency: $('#enc-frequency'),
    phase: $('#enc-phase'),
    tau: $('#enc-tau'),
    vad: $('#enc-vad'),
    swatch: $('#enc-swatch'),
    hex: $('#enc-hex'),
    harmonics: $('#enc-harmonics'),
    relation: $('#enc-relation'),
  };

  // Build the 32 byte cells once; only their values change.
  const cells = [];
  if (grid) {
    for (let i = 0; i < WAVE.SIZE; i++) {
      const cell = el('div', {
        class: 'wave-byte',
        'data-field': fieldAt(i),
        title: `byte ${i} — ${fieldAt(i)}`,
      });
      cells.push(cell);
      grid.append(cell);
    }
  }

  let token = 0;
  let lastRipple = 0;

  async function render() {
    const mine = ++token;
    const essence = input.value.trim();

    if (!essence) {
      cells.forEach((c) => { c.textContent = ''; c.style.setProperty('--v', 0); });
      if (out.decision) { out.decision.textContent = '—'; out.decision.className = 'decision'; }
      if (out.reason) out.reason.textContent = t('wave.status');
      return;
    }

    const wave = await composeWave(essence, { recentFingerprints: [] });
    if (mine !== token) return;   // a newer keystroke already won

    // Bytes
    wave.wave32.forEach((byte, i) => {
      const cell = cells[i];
      if (!cell) return;
      cell.textContent = byte.toString(16).padStart(2, '0');
      cell.style.setProperty('--v', byte);
    });

    // Readouts
    if (out.decision) {
      out.decision.textContent = wave.decision;
      out.decision.className = `decision decision-${wave.decision}`;
    }
    if (out.reason) out.reason.textContent = translateReason(wave.reason, wave.reason_en, wave.reason_zh);
    if (out.amplitude) out.amplitude.textContent = wave.amplitude.toFixed(3);
    if (out.frequency) out.frequency.textContent = `${wave.frequency.toFixed(2)} Hz`;
    if (out.phase) out.phase.textContent = `${wave.phase_deg.toFixed(1)}°`;
    if (out.tau) {
      out.tau.textContent = wave.tau_hours >= 24
        ? t('time.tau.days', { d: Math.round(wave.tau_hours / 24) })
        : t('time.tau.hours', { h: wave.tau_hours });
    }
    if (out.vad) out.vad.textContent = `${wave.vad.v} · ${wave.vad.a} · ${wave.vad.d} — ${translateVadLabel(wave.label)}`;
    if (out.swatch) out.swatch.style.background = wave.color;
    if (out.hex) out.hex.textContent = wave.wave32_hex.replace(/(.{8})/g, '$1 ').trim();

    if (out.harmonics) {
      const [low, mid, high] = phiHarmonics(wave.frequency);
      out.harmonics.textContent = `${low.toFixed(2)} ← ${mid.toFixed(2)} → ${high.toFixed(2)} Hz`;
    }
    if (out.relation) {
      // Against a neutral reference wave at 90°, so the phase reading has
      // something concrete to mean.
      const rel = phaseRelation(wave.phase_deg, 90);
      out.relation.textContent = `${rel.delta_deg.toFixed(0)}° — ${rel.kind}`;
    }

    // Throttle ripples so holding a key does not flood the canvas.
    const now = performance.now();
    if (fire && wave.decision !== 'DROP' && now - lastRipple > 260) {
      lastRipple = now;
      fire.ripple(wave);
    }
  }

  input.addEventListener('input', render);
  $$('[data-encoder-sample]').forEach((btn) => {
    btn.addEventListener('click', () => {
      input.value = btn.dataset.encoderSample;
      input.focus();
      render();
    });
  });

  render();
}

/* ---------------------------------------------------------------------------
 * The decay curve — D(t,τ) = e^(−t/τ), drawn rather than asserted
 * ------------------------------------------------------------------------ */

function initDecayCurve() {
  const svg = $('#decay-curve');
  if (!svg) return;

  const W = 520, H = 180, PAD = 24;
  const slider = $('#decay-tau');
  const label = $('#decay-tau-label');

  function draw(tauHours) {
    const days = 90;
    const points = [];
    for (let i = 0; i <= 120; i++) {
      const t = (i / 120) * days * 24 * 3600;
      const d = decayFactor(t, tauHours);
      points.push([
        PAD + (i / 120) * (W - PAD * 2),
        H - PAD - d * (H - PAD * 2),
      ]);
    }
    const path = points.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
    $('#decay-path', svg)?.setAttribute('d', path);
    $('#decay-area', svg)?.setAttribute(
      'd',
      `${path} L${(W - PAD).toFixed(1)} ${H - PAD} L${PAD} ${H - PAD} Z`,
    );

    // Mark the half-life: t where D = 0.5 → t = τ·ln2.
    const halfLifeHours = tauHours * Math.LN2;
    const x = PAD + Math.min(halfLifeHours / (days * 24), 1) * (W - PAD * 2);
    const marker = $('#decay-half', svg);
    if (marker) {
      marker.setAttribute('x1', x); marker.setAttribute('x2', x);
      marker.style.opacity = halfLifeHours / 24 <= days ? 1 : 0;
    }
    const halfLabel = $('#decay-half-label', svg);
    if (halfLabel) {
      halfLabel.setAttribute('x', Math.min(x + 6, W - PAD - 90));
      halfLabel.textContent = t('time.half', { h: (halfLifeHours / 24).toFixed(1) });
      halfLabel.style.opacity = halfLifeHours / 24 <= days ? 1 : 0;
    }

    if (label) {
      const days_ = tauHours / 24;
      label.textContent = days_ >= 1 ? t('time.tau.days', { d: days_.toFixed(0) }) : t('time.tau.hours', { h: tauHours });
    }
  }

  slider?.addEventListener('input', () => draw(Number(slider.value)));
  draw(Number(slider?.value ?? TAU_HOURS.STORE));
}

/* ---------------------------------------------------------------------------
 * The fire index
 * ------------------------------------------------------------------------ */

function fireCard(fire) {
  const stateClass = `state-${fire.state === 'PARÁZS' ? 'PARAZS' : fire.state}`;
  return el('a', { class: 'card fire-card', href: `/fire.html?f=${encodeURIComponent(fire.slug)}` }, [
    el('div', { class: 'fire-card-head' }, [
      el('span', { class: `state ${stateClass}`, text: fire.state }),
    ]),
    el('h3', { text: fire.name }),
    fire.question ? el('p', { class: 'fire-question', text: `„${fire.question}”` }) : null,
    el('div', { class: 'fire-ash' }, [
      el('strong', { text: 'Hamu: ' }),
      fire.ash_sentence,
    ]),
    el('footer', {}, [
      el('span', { text: t('firecard.chairs', { n: fire.chairs ?? 0 }) }),
      el('span', { text: t('firecard.waves', { n: fire.waves ?? 0 }) }),
      el('span', { text: fire.pulse === 'daily' ? t('firecard.pulse.daily') : fire.pulse === 'weekly' ? t('firecard.pulse.weekly') : t('firecard.pulse.none') }),
      el('span', { class: 'faint', text: relTime(fire.created_at) }),
    ]),
  ]);
}

async function initFireIndex() {
  const list = $('#fire-list');
  if (!list) return;

  try {
    const { fires } = await api.listFires();
    list.replaceChildren();
    if (!fires.length) {
      list.append(el('div', { class: 'empty', text: t('fires.empty') }));
      return;
    }
    fires.forEach((f) => list.append(fireCard(f)));
    const count = $('#stat-fires');
    if (count) count.textContent = fires.length;
    const waves = fires.reduce((sum, f) => sum + (f.waves ?? 0), 0);
    const waveStat = $('#stat-waves');
    if (waveStat) waveStat.textContent = waves;
    const chairStat = $('#stat-chairs');
    if (chairStat) chairStat.textContent = fires.reduce((sum, f) => sum + (f.chairs ?? 0), 0);
  } catch (err) {
    list.replaceChildren(el('div', { class: 'notice notice-err', text: t('fires.error', { msg: translateError(err.message) }) }));
  }
}

/** Tell the visitor plainly whether the lattice is real right now. */
async function initLatticeBanner() {
  const banner = $('#lattice-status');
  if (!banner) return;
  const live = await api.probe();
  banner.hidden = live;
  if (!live) {
    banner.className = 'notice';
    banner.textContent = t('banner.local.index');
  }
}

/* ---------------------------------------------------------------------------
 * "A hamuból" — φ-resynthesised memories surfacing on golden-ratio beats
 * (spec §8). Not a feed: nothing is ranked by popularity and nothing is
 * chosen for you. Each surfacing wave is the φ-harmonic neighbour of the one
 * before it, so the sequence wanders the lattice by resonance alone.
 * ------------------------------------------------------------------------ */

async function initHamubol(fire) {
  const box = $('#hamubol');
  if (!box) return;

  const sourceEl = $('#hamubol-source');
  const essenceEl = $('#hamubol-essence');
  const metaEl = $('#hamubol-meta');

  // Gather the ring's waves once.
  let pool = [];
  try {
    const { fires } = await api.listFires();
    const loaded = await Promise.all(
      fires.map((f) => api.getFire(f.slug).then(
        (r) => r.waves.map((w) => ({ ...w, fireName: f.name, fireSlug: f.slug })),
        () => [],
      )),
    );
    pool = loaded.flat();
  } catch {
    /* nothing to recall */
  }

  if (pool.length < 2) {
    if (sourceEl) sourceEl.textContent = t('hamubol.empty');
    if (essenceEl) essenceEl.textContent = t('hamubol.nothing');
    return;
  }

  const shown = new Set();
  let current = pool[Math.floor(Math.random() * pool.length)];
  // The beat alternates between t and t·φ — the interval itself is golden.
  const BASE = 7000;
  let beat = 0;

  function surface(wave) {
    if (!wave) return;
    shown.add(wave.id);
    current = wave;

    const color = wave.color || '#ff7a3d';
    if (sourceEl) sourceEl.textContent = `${wave.fireName.toUpperCase()} · ${relTime(wave.ts)}`;
    if (essenceEl) {
      essenceEl.textContent = `„${wave.essence}”`;
      essenceEl.animate(
        [{ opacity: 0, transform: 'translateY(10px)' }, { opacity: 1, transform: 'none' }],
        { duration: 700, easing: 'cubic-bezier(0.22,1,0.36,1)' },
      );
    }
    if (metaEl) {
      // Filter before spreading: replaceChildren() stringifies a null child
      // into a literal "null" rather than skipping it.
      metaEl.replaceChildren(...[
        el('span', {}, [el('b', { text: `${(wave.frequency ?? 0).toFixed(2)} Hz` })]),
        el('span', { text: t('time.phase', { p: (wave.phase_deg ?? 0).toFixed(0) }) }),
        wave.label ? el('span', { text: translateVadLabel(wave.label) }) : null,
        wave.relation ? el('span', { class: 'faint', text: `${wave.relation} · Δ${wave.delta_deg}°` }) : null,
      ].filter(Boolean));
    }
    if (fire) fire.ripple({ ...wave, color });
  }

  async function step() {
    // If everything has surfaced, let the lattice forget and start over.
    if (shown.size >= pool.length) shown.clear();

    const candidates = pool.filter((w) => !shown.has(w.id));
    const [next] = await resynthesiseAgainst(current, candidates);
    surface(next ?? candidates[0]);

    // The beat itself is golden: t, then t·φ, then t again.
    beat++;
    setTimeout(step, beat % 2 ? BASE * PHI : BASE);
  }

  /** Rank `candidates` by resonance against `seed`, using the seed's own
   *  essence as the query, so the chain really is φ-resynthesis and not a
   *  shuffle wearing its name. */
  function resynthesiseAgainst(seed, candidates) {
    if (!candidates.length) return Promise.resolve([]);
    return resynthesise(seed.essence, candidates, { topK: 1 });
  }

  surface(current);
  setTimeout(step, BASE);
}

/* ---------------------------------------------------------------------------
 * Lighting a fire (spec §2 pillar 1: no ash sentence → no fire)
 * ------------------------------------------------------------------------ */

function initLightFire() {
  const form = $('#light-fire');
  if (!form) return;

  const status = $('#light-fire-status');
  const ash = form.elements.ash_sentence;
  const submit = form.querySelector('[type="submit"]');

  // The rule is enforced in the UI as well as the API, because the rule is the
  // product — it should be impossible to even *ask* for a fire without ash.
  function validate() {
    const ok = ash.value.trim().length >= 12 && form.elements.name.value.trim().length >= 2;
    submit.disabled = !ok;
    return ok;
  }
  form.addEventListener('input', validate);
  validate();

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!validate()) return;
    submit.disabled = true;
    status.className = 'notice';
    status.textContent = t('fires.form.lighting');

    try {
      const { fire } = await api.createFire({
        name: form.elements.name.value.trim(),
        question: form.elements.question.value.trim(),
        ash_sentence: ash.value.trim(),
        pulse: form.elements.pulse.value,
      });
      status.textContent = t('fires.form.going');
      window.location.href = `/fire.html?f=${encodeURIComponent(fire.slug)}`;
    } catch (err) {
      status.className = 'notice notice-err';
      status.textContent = translateError(err.message) || t('fires.form.fail');
      submit.disabled = false;
    }
  });
}

/* ---------------------------------------------------------------------------
 * Boot
 * ------------------------------------------------------------------------ */

function boot() {
  try { setLang(localStorage.getItem(LANG_KEY) || DEFAULT_LANG); } catch { setLang(DEFAULT_LANG); }
  applyI18n();
  wireLangSwitch(() => initFireIndex());

  initAmbient();
  initReveal();
  initSpotlight();

  // On wide screens the fire sits to the right of the headline; on narrow ones
  // the copy stacks above it, so the fire centres and drops.
  const wide = window.matchMedia('(min-width: 62rem)');
  const fire = mountFire('#hero-fire', {
    chairs: 14,
    intensity: 1,
    origin: wide.matches ? [0.66, 0.62] : [0.5, 0.78],
  });
  wide.addEventListener('change', (e) => {
    if (!fire) return;
    fire.opts.origin = e.matches ? [0.66, 0.62] : [0.5, 0.78];
    fire._layoutChairs();
  });

  initEncoder(fire);
  initDecayCurve();
  initLatticeBanner();
  initFireIndex().then(() => initHamubol(fire));
  initLightFire();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}
