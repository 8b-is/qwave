/**
 * bonfire — i18n tests
 * Run with: npm test   (node --test test/)
 *
 * These cover the properties the four-language UI promises: the róvás
 * transliteration is phonemic and longest-match, the dictionary falls back
 * to Hungarian rather than failing, and the server's Hungarian error
 * sentences map to the visitor's language.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  LANGS, DEFAULT_LANG, RTL_LANGS, toRovas, translateLang, translateError,
  translateReason, translateVadLabel, relTimeT,
} from '../shared/i18n.js';

/* -- róvás transliteration ------------------------------------------------- */

test('rovás transliterates digraphs longest-match-first', () => {
  assert.equal(toRovas('csend'), '𐲄𐲈𐲖𐲅');   // cs-e-n-d, not c-s-e-n-d
  assert.equal(toRovas('szék'), '𐲟𐲉𐲑');     // sz-é-k, not s-z-é-k
  assert.equal(toRovas('dzsessz'), '𐲇𐲈𐲞𐲟'); // dzs-e-ssz → dzs-e-sz-sz
  assert.equal(toRovas('gyönyörű'), '𐲌𐲚𐲗𐲚𐲝𐲥');
});

test('rovás is case-insensitive', () => {
  assert.equal(toRovas('TŰZ'), toRovas('tűz'));
});

test('rovás passes digits and punctuation through', () => {
  assert.equal(toRovas('2026 · v0.1'), '2026 · 𐲦0.1');
});

test('rovás transliterates foreign letters by convention', () => {
  assert.equal(toRovas('x'), '𐲑𐲟'); // x → ksz
  assert.equal(toRovas('w'), '𐲦');   // w → v
});

/* -- dictionary ------------------------------------------------------------ */

test('the four languages are the four promised ones', () => {
  assert.deepEqual([...LANGS], ['hu', 'en', 'zh', 'rovas']);
  assert.equal(DEFAULT_LANG, 'hu');
  assert.ok(RTL_LANGS.has('rovas'));
  assert.ok(!RTL_LANGS.has('en'));
});

test('translate falls back to Hungarian for an unknown language', () => {
  assert.equal(translateLang('xx', 'fires.form.submit'), 'Meggyújtom');
});

test('translate interpolates variables', () => {
  assert.equal(translateLang('en', 'fires.error', { msg: 'boom' }), 'The fires could not be reached: boom');
});

test('rovás mode transliterates the Hungarian string', () => {
  assert.equal(translateLang('rovas', 'time.mins', { m: 5 }), toRovas('5 perce'));
});

/* -- server error mapping -------------------------------------------------- */

test('translateError maps a known server sentence to the visitor language', () => {
  assert.equal(translateError('Nincs ilyen tűz.', 'en'), 'No such fire.');
  assert.equal(translateError('Nincs ilyen tűz.', 'zh'), '没有这样的火。');
});

test('translateError passes unknown sentences through', () => {
  assert.equal(translateError('Valami egészen ismeretlen.', 'en'), 'Valami egészen ismeretlen.');
});

test('translateError transliterates in rovás mode', () => {
  assert.equal(translateError('Nincs ilyen tűz.', 'rovas'), toRovas('Nincs ilyen tűz.'));
});

/* -- phoenix reasons ------------------------------------------------------- */

test('translateReason picks the language-specific sentence', () => {
  const reason = 'Új hullám. A rács megtartja.';
  const reason_en = 'A new wave. The lattice keeps it.';
  const reason_zh = '新波。网格将它收下。';
  assert.equal(translateReason(reason, reason_en, reason_zh, 'hu'), reason);
  assert.equal(translateReason(reason, reason_en, reason_zh, 'en'), reason_en);
  assert.equal(translateReason(reason, reason_en, reason_zh, 'zh'), reason_zh);
  assert.equal(translateReason(reason, reason_en, reason_zh, 'rovas'), toRovas(reason));
});

test('translateReason falls back to Hungarian when a translation is missing', () => {
  assert.equal(translateReason('Csak magyar.', undefined, undefined, 'en'), 'Csak magyar.');
});

/* -- VAD labels ------------------------------------------------------------ */

test('translateVadLabel maps the nine VAD words', () => {
  assert.equal(translateVadLabel('meleg · csendes · biztos', 'en'), 'warm · quiet · certain');
  assert.equal(translateVadLabel('meleg · csendes · biztos', 'zh'), '暖 · 静 · 笃定');
  assert.equal(translateVadLabel('meleg · csendes · biztos', 'rovas'), toRovas('meleg · csendes · biztos'));
});

/* -- relative time --------------------------------------------------------- */

test('relTimeT honours the language', () => {
  const nowSec = Math.floor(Date.now() / 1000);
  assert.equal(relTimeT(nowSec, 'en'), 'now');
  // Offsets sit mid-bucket so fractional-second drift cannot cross a boundary.
  assert.equal(relTimeT(nowSec - 330, 'en'), '5 min ago');
  assert.equal(relTimeT(nowSec - 330, 'hu'), '5 perce');
  assert.equal(relTimeT(nowSec - 7260, 'zh'), '2 小时前');
});
