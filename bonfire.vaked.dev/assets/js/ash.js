/**
 * bonfire — the ash page
 * ============================================================================
 * A completed fire and its capsule. Nothing here is interactive except the
 * download: the fire is out, and the page should feel like it.
 * ========================================================================== */

import { vadColor, vadLabel } from '../../shared/wave.js';
import * as api from './api.js';

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
  return new Date(ts * 1000).toLocaleDateString('hu-HU', {
    year: 'numeric', month: 'long', day: 'numeric',
  });
}

function fmtBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} kB`;
  return `${(n / (1024 * 1024)).toFixed(2)} MB`;
}

async function boot() {
  const slug = new URLSearchParams(location.search).get('f');
  const error = $('#ash-error');

  if (!slug) {
    error.hidden = false;
    error.textContent = 'Nincs megadva tűz.';
    $('#ash-waves').replaceChildren();
    return;
  }

  try {
    const { fire, waves, capsule } = await api.getAsh(slug);

    document.title = `${fire.name} — hamu — bonfire`;
    $('#ash-head').hidden = false;
    $('#ash-name').textContent = fire.name;
    $('#ash-question').textContent = fire.question ? `„${fire.question}"` : '';
    $('#ash-sentence').textContent = `„${fire.ash_sentence}"`;
    $('#ash-dates').textContent =
      `meggyújtva ${fmtDate(fire.created_at)} · hamuvá lett ${fmtDate(fire.ash_at)}`;

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
      list.append(el('li', { class: 'empty', text: 'Ez a tűz csendben égett ki.' }));
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
            el('span', { text: `${(wave.phase_deg ?? 0).toFixed(0)}° fázis` }),
            el('span', { text: wave.label || vadLabel(vad) }),
            el('span', { class: 'faint', text: fmtDate(wave.ts) }),
          ]),
        ]),
      ]));
    }
  } catch (err) {
    error.hidden = false;
    error.textContent = err.status === 409
      ? 'Ez a tűz még ég. Hamu csak akkor van, ha a hamu-mondat teljesült.'
      : `Nem sikerült betölteni a hamut: ${err.message}`;
    $('#ash-waves').replaceChildren();
  }
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();
