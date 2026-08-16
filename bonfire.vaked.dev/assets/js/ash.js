/**
 * bonfire — the ash page
 * ============================================================================
 * A completed fire and its capsule. Nothing here is interactive except the
 * download: the fire is out, and the page should feel like it.
 * ========================================================================== */

import { vadColor, vadLabel } from '../../shared/wave.js';
import * as api from './api.js';
import {
  DEFAULT_LANG, LOCALES, RTL_LANGS, lang, setLang, t,
  translateError, translateVadLabel,
} from '../../shared/i18n.js';

const $ = (sel) => document.querySelector(sel);

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

function fmtDate(ts) {
  if (!ts) return '—';
  return new Date(ts * 1000).toLocaleDateString(LOCALES[lang()], {
    year: 'numeric', month: 'long', day: 'numeric',
  });
}

function fmtBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} kB`;
  return `${(n / (1024 * 1024)).toFixed(2)} MB`;
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
  document.title = t('ash.title');
  document.querySelector('meta[name="description"]')?.setAttribute('content', t('ash.desc'));
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

async function boot() {
  try { setLang(localStorage.getItem(LANG_KEY) || DEFAULT_LANG); } catch { setLang(DEFAULT_LANG); }
  applyI18n();
  wireLangSwitch(() => render());

  await render();
}

async function render() {
  const slug = new URLSearchParams(location.search).get('f');
  const error = $('#ash-error');
  error.hidden = true;
  $('#ash-head').hidden = true;
  $('#ash-capsule').hidden = true;

  if (!slug) {
    error.hidden = false;
    error.textContent = t('ash.noq');
    $('#ash-waves').replaceChildren();
    return;
  }

  try {
    const { fire, waves, capsule } = await api.getAsh(slug);

    document.title = t('ash.title.withName', { n: fire.name });
    $('#ash-head').hidden = false;
    $('#ash-name').textContent = fire.name;
    $('#ash-question').textContent = fire.question ? `„${fire.question}”` : '';
    $('#ash-sentence').textContent = `„${fire.ash_sentence}”`;
    $('#ash-dates').textContent =
      t('ash.dates', { a: fmtDate(fire.created_at), b: fmtDate(fire.ash_at) });

    if (capsule) {
      $('#ash-capsule').hidden = false;
      $('#capsule-size').textContent = fmtBytes(capsule.bytes);
      $('#capsule-waves').textContent = waves.length;
      $('#capsule-date').textContent = fmtDate(capsule.exported_at);
      $('#capsule-download').href = capsule.download;
      $('#capsule-download').setAttribute('download', `${slug}.m8`);
    }

    const list = $('#ash-waves');
    list.replaceChildren();
    if (!waves.length) {
      list.append(el('li', { class: 'empty', text: t('ash.empty') }));
      return;
    }

    for (const wave of waves) {
      const vad = { v: wave.vad_v, a: wave.vad_a, d: wave.vad_d };
      list.append(el('li', {
        class: 'wave-item',
        // Ash does not decay any further: every wave shows at full presence.
        style: { '--wave-color': wave.color || vadColor(vad), '--alive': '1' },
      }, [
        el('div', { class: 'wave-bar' }),
        el('div', {}, [
          el('p', { class: 'wave-essence', text: wave.essence }),
          el('div', { class: 'wave-meta' }, [
            el('span', { text: `${(wave.frequency ?? 0).toFixed(2)} Hz` }),
            el('span', { text: t('time.phase', { p: (wave.phase_deg ?? 0).toFixed(0) }) }),
            el('span', { text: translateVadLabel(wave.label || vadLabel(vad)) }),
            el('span', { class: 'faint', text: fmtDate(wave.ts) }),
          ]),
        ]),
      ]));
    }
  } catch (err) {
    error.hidden = false;
    error.textContent = err.status === 409
      ? t('ash.burning')
      : t('ash.load.fail', { msg: translateError(err.message) });
    $('#ash-waves').replaceChildren();
  }
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();
