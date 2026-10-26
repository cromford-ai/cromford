// BH-8395: ADDED_COLUMNS and ADDED_INDEXES (and fragment additions to
// CREATED_TABLE_OVERRIDES) compose from worker/jobs/src/lib/core.d/.
//
// U1  parseCoreFragments: the fragment-name decision table
// U2  two fragments that add verdicts columns concatenate in file-name order
// U3  0000-* sorts before bh-*; the input order of names does not matter
// U4  duplicate column, duplicate statement, bad table, bad item: each throws
// U5  an unknown export and a fragment with no registry export: each throws
// U6  mergeTableLists(base, {}) keeps base's array objects (created-tables T3)
// P1  the 0000-* baselines compose to the pre-split fixture, key order included
// P2  the real core.js exports that composition, and the real ensureColumns
//     ALTERs a column that now lives only in core.d/0000-added-columns.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import {
  parseCoreFragments, composeCoreRegistries, mergeTableLists, renderCoreRegistriesModule,
} from '../src/lib/core-registries.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const FRAG_DIR = join(HERE, '..', 'src', 'lib', 'core.d');
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures', 'core-registries-pre-split.bh-8395.json'), 'utf8'));

const throwsNaming = (fn, file) => assert.throws(fn, (e) => e.message.includes(file), `expected a throw naming ${file}`);

test('U1 fragment names: accept and refuse', () => {
  for (const ok of ['0000-added-columns.js', 'bh-9001-verdicts-break-it.js', 'bh-6005-4-x.js', 'bh-5235.2-x.js']) {
    assert.deepEqual(parseCoreFragments([ok]).map((f) => f.file), [ok]);
  }
  for (const bad of ['added-columns.js', '0000-Added.js', 'bh-9001-.js', 'bh-9001-x.mjs', 'README.md', 'bh-x-y.js', '.DS_Store']) {
    throwsNaming(() => parseCoreFragments(['0000-added-columns.js', bad]), bad);
  }
});

test('U2 two fragments add verdicts columns in file-name order after the baseline', () => {
  const out = composeCoreRegistries([
    ['bh-9002-verdicts-b.js', { ADDED_COLUMNS: { verdicts: [['b_col', 'TEXT']] } }],
    ['0000-added-columns.js', { ADDED_COLUMNS: { verdicts: [['auth', 'TEXT']], alerts: [['x', 'TEXT']] } }],
    ['bh-9001-verdicts-a.js', { ADDED_COLUMNS: { verdicts: [['a_col', 'INTEGER']] } }],
  ]);
  assert.deepEqual(out.ADDED_COLUMNS.verdicts, [['auth', 'TEXT'], ['a_col', 'INTEGER'], ['b_col', 'TEXT']]);
  assert.deepEqual(Object.keys(out.ADDED_COLUMNS), ['verdicts', 'alerts']);
  // A keyed fragment adds a statement to a baseline index table and a new table.
  const idx = composeCoreRegistries([
    ['0000-added-indexes.js', { ADDED_INDEXES: { alerts: ['CREATE INDEX a1 ON alerts(x)'] } }],
    ['bh-9003-idx.js', { ADDED_INDEXES: { alerts: ['CREATE INDEX a2 ON alerts(y)'], wakes: ['CREATE INDEX w1 ON wakes(z)'] } }],
  ]);
  assert.deepEqual(idx.ADDED_INDEXES, { alerts: ['CREATE INDEX a1 ON alerts(x)', 'CREATE INDEX a2 ON alerts(y)'], wakes: ['CREATE INDEX w1 ON wakes(z)'] });
  assert.deepEqual(idx.ADDED_COLUMNS, {});
  assert.deepEqual(idx.CREATED_TABLE_OVERRIDES, {});
});

test('U3 sort order: digits before keys, a before b, any input order', () => {
  const names = ['bh-9001-b.js', 'bh-10000-z.js', '0001-y.js', 'bh-9001-a.js', '0000-x.js'];
  const want = ['0000-x.js', '0001-y.js', 'bh-10000-z.js', 'bh-9001-a.js', 'bh-9001-b.js'];
  assert.deepEqual(parseCoreFragments(names).map((f) => f.file), want);
  assert.deepEqual(parseCoreFragments([...names].reverse()).map((f) => f.file), want);
  assert.equal(renderCoreRegistriesModule(names), renderCoreRegistriesModule([...names].reverse()));
  const mods = Object.fromEntries(want.map((f, i) => [f, { ADDED_INDEXES: { t: [`S${i}`] } }]));
  const a = composeCoreRegistries(names.map((f) => [f, mods[f]]));
  const b = composeCoreRegistries([...names].reverse().map((f) => [f, mods[f]]));
  assert.deepEqual(a.ADDED_INDEXES.t, ['S0', 'S1', 'S2', 'S3', 'S4']);
  assert.deepEqual(b, a);
});

test('U4 refusals name the file', () => {
  const base = ['0000-added-columns.js', { ADDED_COLUMNS: { verdicts: [['auth', 'TEXT']] } }];
  throwsNaming(() => composeCoreRegistries([base, ['bh-1-dup.js', { ADDED_COLUMNS: { verdicts: [['auth', 'TEXT']] } }]]), 'bh-1-dup.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_INDEXES: { t: ['S'] } }], ['bh-2-b.js', { ADDED_INDEXES: { t: ['S'] } }]]), 'bh-2-b.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_INDEXES: { 'bad-name': ['S'] } }]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_COLUMNS: { t: [['x']] } }]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_COLUMNS: { t: ['x TEXT'] } }]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_INDEXES: { t: 'S' } }]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { CREATED_TABLE_OVERRIDES: { t: [''] } }]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bad.js', { ADDED_INDEXES: { t: ['S'] } }]]), 'bad.js');
});

test('U5 unknown export and no registry export throw', () => {
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_COLUMN: { t: [['x', 'TEXT']] } }]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', {}]]), 'bh-1-a.js');
  throwsNaming(() => composeCoreRegistries([['bh-1-a.js', { ADDED_INDEXES: { t: ['S'] }, default: {} }]]), 'bh-1-a.js');
});

test('U6 mergeTableLists keeps base arrays when nothing is added', () => {
  const base = { a: ['A1'], b: ['B1'] };
  const same = mergeTableLists(base, {});
  assert.deepEqual(Object.keys(same), ['a', 'b']);
  assert.equal(same.a, base.a);
  assert.equal(same.b, base.b);
  const more = mergeTableLists(base, { b: ['B2'], c: ['C1'] });
  assert.equal(more.a, base.a);
  assert.deepEqual(more, { a: ['A1'], b: ['B1', 'B2'], c: ['C1'] });
  assert.deepEqual(base.b, ['B1'], 'base is not mutated');
  assert.throws(() => mergeTableLists(base, { a: ['A1'] }), /A1|twice/);
});

async function composeDir(filter) {
  const frags = parseCoreFragments(readdirSync(FRAG_DIR)).filter((f) => filter(f.file));
  const mods = await Promise.all(frags.map((f) => import(new URL(f.file, new URL('../src/lib/core.d/', import.meta.url)))));
  return composeCoreRegistries(frags.map((f, i) => [f.file, mods[i]]));
}

test('P1 the 0000-* baselines equal the pre-split fixture, key order included', async () => {
  const base = await composeDir((f) => f.startsWith('0000-'));
  assert.equal(JSON.stringify(base.ADDED_COLUMNS), JSON.stringify(FIXTURE.ADDED_COLUMNS));
  assert.equal(JSON.stringify(base.ADDED_INDEXES), JSON.stringify(FIXTURE.ADDED_INDEXES));
  const all = await composeDir(() => true);
  for (const reg of ['ADDED_COLUMNS', 'ADDED_INDEXES']) {
    for (const [table, items] of Object.entries(FIXTURE[reg])) {
      assert.deepEqual(all[reg][table].slice(0, items.length), items, `${reg}.${table} keeps the fixture as its prefix`);
    }
  }
});

test('P2 the real core.js exports the composition and ensureColumns uses it', async () => {
  const core = await import('../src/lib/core.js');
  const all = await composeDir(() => true);
  assert.deepEqual(core.ADDED_COLUMNS, all.ADDED_COLUMNS);
  assert.deepEqual(core.ADDED_INDEXES, all.ADDED_INDEXES);
  for (const k of ['merge_trains', 'verdicts', 'setting_sigs', 'suite_reuse_runs']) {
    assert.ok(Array.isArray(core.CREATED_TABLE_OVERRIDES[k]), `CREATED_TABLE_OVERRIDES keeps ${k}`);
    assert.equal(core.CREATED_TABLES[k], core.CREATED_TABLE_OVERRIDES[k]);
  }
  // A verdicts table from before break_it: ensureColumns must ALTER it in.
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE verdicts (repo TEXT, pr INTEGER, sha TEXT, verdict TEXT)');
  await core.ensureColumns({ DB: d1(db) }, 'verdicts');
  const cols = db.prepare('PRAGMA table_info(verdicts)').all().map((r) => r.name);
  for (const c of ['auth', 'human_sig', 'review_tier', 'review_mode', 'break_it']) assert.ok(cols.includes(c), `verdicts gained ${c}: ${cols}`);
  // And an ADDED_INDEXES statement from core.d/0000-added-indexes.js runs.
  const db2 = new DatabaseSync(':memory:');
  db2.exec('CREATE TABLE lane_ticks (box TEXT, last_tick_at TEXT)');
  await core.ensureColumns({ DB: d1(db2) }, 'lane_ticks');
  const idx = db2.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='lane_ticks'").all().map((r) => r.name);
  assert.ok(idx.includes('idx_lane_ticks_box'), `lane_ticks index created: ${idx}`);
});
