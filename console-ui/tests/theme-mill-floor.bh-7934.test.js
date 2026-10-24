// BH-7951 (BH-7934.4): the Mill Floor console theme is a settings row,
// ui.theme.custom.mill-floor, seeded by a jobs-worker schema fragment. Never a
// code constant (BH-7934 Decision 5).
//
// These tests read the VALUE out of the fragment, apply the fragment to a
// settings table built from the real CREATE TABLE, and load the row through
// customThemesFromSettings, the reader the console uses. --accent is #cd6642,
// not the prototype's #c8572f: that one is 4.23:1 on --surface-1, under the
// 4.5:1 gate, so the row would be skipped on every read (plan A1).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

import {
  customId, contrastFailures, exportTheme, customThemesFromSettings, validateThemeDoc, MAX_DOC_CHARS
} from '../src/theme/custom.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const schemaDir = path.join(repo, 'worker', 'jobs', 'schema.d');
const FRAGMENT = path.join(schemaDir, '202610231903-bh-7934-mill-floor-theme.sql');
const KEY = 'ui.theme.custom.mill-floor';

const TOKENS = {
  '--surface-0': '#0d0d0c',
  '--surface-1': '#151513',
  '--rule': '#2b2a26',
  '--text-dim': '#8d8a82',
  '--text-strong': '#f2f0eb',
  '--text': '#e7e5df',
  '--accent': '#cd6642',
  '--ok': '#6fae7b',
  '--warn': '#d9a441'
};

const sql = () => fs.readFileSync(FRAGMENT, 'utf8');

function seededValue() {
  const re = /'ui\.theme\.custom\.mill-floor','([^']*)'/g;
  const hits = [...sql().matchAll(re)];
  assert.equal(hits.length, 1, 'the fragment holds exactly one ui.theme.custom.mill-floor value');
  return hits[0][1];
}

// The settings table exactly as 0000-base.sql creates it.
function settingsDb() {
  const base = fs.readFileSync(path.join(schemaDir, '0000-base.sql'), 'utf8');
  const m = /CREATE TABLE IF NOT EXISTS settings \([\s\S]*?\n\);/.exec(base);
  assert.ok(m, '0000-base.sql creates the settings table');
  const db = new DatabaseSync(':memory:');
  db.exec(m[0]);
  return db;
}

test('the fragment holds one canonical value under the size cap', () => {
  const value = seededValue();
  assert.equal(exportTheme(JSON.parse(value)), value, 'the stored bytes are exportTheme canonical');
  assert.ok(value.length <= MAX_DOC_CHARS, `${value.length} <= ${MAX_DOC_CHARS}`);
});

test('the applied fragment seeds a row customThemesFromSettings loads as Mill Floor', () => {
  const db = settingsDb();
  db.exec(sql());
  const rows = db.prepare('SELECT key, value, actor, updated_at FROM settings').all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].key, KEY);
  assert.equal(rows[0].value, seededValue());

  const { themes, skipped } = customThemesFromSettings(rows);
  assert.deepEqual(skipped, []);
  assert.equal(themes.length, 1);
  const [t] = themes;
  assert.equal(t.id, customId('mill-floor'));
  assert.equal(t.doc.name, 'Mill Floor');
  assert.equal(t.doc.base, 'mill');
  assert.deepEqual(t.doc.shape, {});
  for (const [k, v] of Object.entries(TOKENS)) assert.equal(t.theme.tokens[k], v, k);
  assert.deepEqual(t.doc.tokens, TOKENS, 'the doc sets exactly the 9 Mill Floor tokens');
  assert.deepEqual(contrastFailures(t.theme.tokens), []);
});

test('a re-apply is a no-op and keeps an operator-edited row', () => {
  const db = settingsDb();
  const edited = exportTheme({ v: 1, name: 'Mill Floor', base: 'mill', tokens: {}, shape: {} });
  db.prepare('INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)')
    .run(KEY, edited, 'operator', 'operator', '2026-10-22T02:00:00Z');
  db.exec(sql());
  db.exec(sql());
  const rows = db.prepare('SELECT key, value, actor FROM settings').all();
  assert.deepEqual(rows.map((r) => ({ ...r })), [{ key: KEY, value: edited, actor: 'operator' }]);
});

test('the prototype accent #c8572f is refused by the 4.5:1 gate', () => {
  const doc = { ...JSON.parse(seededValue()) };
  doc.tokens = { ...doc.tokens, '--accent': '#c8572f' };
  const res = validateThemeDoc(doc);
  assert.equal(res.ok, false);
  assert.ok(res.errors.some((e) => e.startsWith('contrast: --accent on --surface-1 is 4.23:1')), res.errors.join('; '));
  const { skipped } = customThemesFromSettings([{ key: KEY, value: exportTheme(doc) }]);
  assert.equal(skipped.length, 1);
});

test('the 3 Mill Floor fonts ship in console-ui/public/fonts', () => {
  for (const f of ['archivo-latin-wdth.woff2', 'geist-latin.woff2', 'geist-mono-latin.woff2']) {
    const p = path.join(repo, 'console-ui', 'public', 'fonts', f);
    assert.ok(fs.existsSync(p), `${f} exists`);
    assert.ok(fs.statSync(p).size > 0, `${f} is not empty`);
  }
});
