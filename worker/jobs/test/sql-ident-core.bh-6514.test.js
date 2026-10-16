// BH-6514 (BH-6523): ensureColumns, appendLines and listLines put a table (and
// for appendLines, column) name into SQL text. Each one now runs the name
// through sqlIdent before it builds any statement, so a bad name throws before
// the first prepare, and ensureColumns caches nothing for it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureColumns, appendLines, listLines, addedColumnsReady } from '../src/lib/core.js';
import { rawDb } from '../src/lib/d1-retry.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

// A DB stub that records every prepare and answers nothing useful: the bad
// names must throw before it is ever asked.
function recorder() {
  const prepared = [];
  const DB = {
    prepare(sql) {
      prepared.push(sql);
      const api = { bind: () => api, all: async () => ({ results: [] }), run: async () => ({}), first: async () => null };
      return api;
    },
    batch: async () => [],
  };
  return { DB, prepared };
}

const T = '2026-10-15T00:00:00Z';

test('J3. ensureColumns refuses a bad table name before PRAGMA and caches nothing', async () => {
  const { DB, prepared } = recorder();
  const env = { DB };
  await assert.rejects(ensureColumns(env, 'x; DROP TABLE y'), TypeError);
  assert.equal(prepared.length, 0);
  const per = addedColumnsReady.get(rawDb(DB));
  assert.ok(!per || !per.has('x; DROP TABLE y'), 'a refused name is never cached');
  await assert.rejects(ensureColumns(env, 'a b'), TypeError);
  assert.equal(prepared.length, 0);
});

test('J3. ensureColumns on a real cost_rows still adds the missing columns', async (t) => {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite unavailable'); return; }
  // A cost_rows from before the added columns: only the base shape.
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE cost_rows (ts TEXT, box TEXT, project TEXT, stage TEXT, cost_usd REAL)');
  await ensureColumns({ DB: d1(db) }, 'cost_rows');
  const cols = new Set(db.prepare('PRAGMA table_info(cost_rows)').all().map((r) => r.name));
  for (const c of ['lane_id', 'guard_fp', 'session_id']) assert.ok(cols.has(c), `missing ${c}`);
});

test('J4. appendLines refuses a bad table or column name before any prepare', async () => {
  const { DB, prepared } = recorder();
  const env = { DB };
  const body = { project: 'p', rows: [{ stamp: T, line: 'a' }] };
  const bind = (project, r, stamp, line) => [stamp, project, line];
  await assert.rejects(appendLines(env, 'bad name', body, T, ['stamp', 'project', 'line'], bind), TypeError);
  await assert.rejects(appendLines(env, 'decisions', body, T, ['stamp', 'a b', 'line'], bind), TypeError);
  assert.equal(prepared.length, 0);
});

test('J4. appendLines with the real decisions columns still inserts', async (t) => {
  const o = await openDb();
  if (o === null) { t.skip('node:sqlite unavailable'); return; }
  const res = await appendLines({ DB: o.DB }, 'decisions', { project: 'p', rows: [{ stamp: T, line: 'x' }] }, T,
    ['stamp', 'project', 'gate', 'scope', 'ticket', 'line', 'created_at'],
    (project, r, stamp, line, t) => [stamp, project, null, null, null, line, t]);
  assert.equal(res.status, 200);
  assert.equal(res.body.inserted, 1);
});

test('J5. listLines refuses a bad table name before any prepare', async () => {
  const { DB, prepared } = recorder();
  const url = new URL(`https://jobs.test/api/decisions?since=${T}`); // determinism: ok since= is the absolute stamp T, compared as stamp>=T; listLines reads no clock
  await assert.rejects(listLines({ DB }, 't;--', url, T), TypeError);
  assert.equal(prepared.length, 0);
});

test('J5. listLines on the real decisions table returns rows', async (t) => {
  const o = await openDb();
  if (o === null) { t.skip('node:sqlite unavailable'); return; }
  o.db.prepare("INSERT INTO decisions (stamp, project, line, created_at) VALUES (?, 'p', 'x', ?)").run(T, T);
  const res = await listLines({ DB: o.DB }, 'decisions', new URL(`https://jobs.test/api/decisions?since=${T}`), T); // determinism: ok since= is the absolute stamp T, compared as stamp>=T; listLines reads no clock
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.rows.length, 1);
});
