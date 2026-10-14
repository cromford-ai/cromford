import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3220: the immediate emitter posted each cost row without lane_id and
// guard_fp, it landed first, and ON CONFLICT(box, row_hash) DO NOTHING then
// threw away the */10 mirror's full copy of the same line. The route now fills
// a NULL lane_id / guard_fp from a later push of the same (box, row_hash), and
// changes nothing else: no overwrite of a set value, no blanking, no other
// column, and a byte-identical re-push still reports inserted: 0.
//
// Driven through the real POST /api/metrics/cost-rows on node:sqlite with the
// d1 shim from cost-rows-lane-index.bh-2489. D1 is SQLite; the live D1 is not
// probed from this suite.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}
async function post(env, body) {
  const res = await worker.fetch(new Request('https://jobs.test/api/metrics/cost-rows', {
    method: 'POST',
    headers: { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const RAW = '2026-09-28T00:00:00Z,h,p,review,claude,m,0,1,1,1,0,0,0.01,sub,fp,acct,,,,,,,,,merge-conductor,mc:x';
// What the emitter sent before the fix: the same line, no lane_id / guard_fp keys.
const truncated = (o = {}) => ({ row_hash: 'hash-1', line_no: 5, ts: '2026-09-28T00:00:00Z', host: 'h',
  project: 'p', stage: 'review', runner: 'claude', model: 'm', rc: '0', cost_usd: '0.01', raw: RAW, ...o });
const full = (o = {}) => truncated({ lane_id: 'merge-conductor', guard_fp: 'mc:x', ...o });
const stored = (db, box = 'hub') => db.prepare('SELECT * FROM cost_rows WHERE box=? ORDER BY row_hash').all(box);
const count = (db) => db.prepare('SELECT COUNT(*) AS c FROM cost_rows').get().c;

test('a late full row fills the NULL lane_id / guard_fp an early truncated row left', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const a = await post(env, { box: 'hub', rows: [truncated()] });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.inserted, 1);
  assert.equal(stored(db)[0].lane_id, null, 'precondition: the truncated row stored NULL');
  const b = await post(env, { box: 'hub', rows: [full()] });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  const rows = stored(db);
  assert.equal(count(db), 1, 'still one row for (box, row_hash)');
  assert.equal(rows[0].lane_id, 'merge-conductor');
  assert.equal(rows[0].guard_fp, 'mc:x');
  assert.equal(b.body.inserted, 1, 'a repair is a change and is reported as one');
});

test('a byte-identical re-push of a full row changes nothing and reports inserted: 0', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  assert.equal((await post(env, { box: 'hub', rows: [full()] })).body.inserted, 1);
  const before = stored(db);
  const again = await post(env, { box: 'hub', rows: [full()] });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.accepted, 1);
  assert.equal(again.body.inserted, 0, 'the pool-reap dup count reads this');
  assert.deepEqual(stored(db), before);
  // A truncated re-push of an already-repaired row is also a no-op.
  assert.equal((await post(env, { box: 'hub', rows: [truncated()] })).body.inserted, 0);
});

test('a stored lane_id / guard_fp is never overwritten by a different value', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await post(env, { box: 'hub', rows: [full({ lane_id: 'a', guard_fp: 'fp-a' })] });
  const r = await post(env, { box: 'hub', rows: [full({ lane_id: 'b', guard_fp: 'fp-b' })] });
  assert.equal(r.body.inserted, 0);
  const [row] = stored(db);
  assert.equal(row.lane_id, 'a');
  assert.equal(row.guard_fp, 'fp-a');
});

test('an incoming NULL never blanks a stored value, and fills only the column that is NULL', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  // lane_id set, guard_fp NULL (a 25-field line).
  await post(env, { box: 'hub', rows: [truncated({ lane_id: 'merge-conductor' })] });
  await post(env, { box: 'hub', rows: [truncated({ lane_id: null, guard_fp: null })] });
  assert.equal(stored(db)[0].lane_id, 'merge-conductor', 'NULL did not blank lane_id');
  const r = await post(env, { box: 'hub', rows: [full({ lane_id: 'other', guard_fp: 'g' })] });
  assert.equal(r.body.inserted, 1, 'guard_fp was NULL, so this is a repair');
  const [row] = stored(db);
  assert.equal(row.lane_id, 'merge-conductor', 'lane_id kept');
  assert.equal(row.guard_fp, 'g', 'guard_fp filled');

  // The mirror image: guard_fp set, lane_id NULL, and a push that fills
  // lane_id while carrying guard_fp NULL. The update runs (lane_id is a fill)
  // and must still leave guard_fp alone.
  const { db: db2, env: env2 } = fresh();
  await post(env2, { box: 'hub', rows: [truncated({ guard_fp: 'kept' })] });
  const r2 = await post(env2, { box: 'hub', rows: [truncated({ lane_id: 'merge-conductor', guard_fp: null })] });
  assert.equal(r2.body.inserted, 1);
  const [row2] = stored(db2);
  assert.equal(row2.lane_id, 'merge-conductor', 'lane_id filled');
  assert.equal(row2.guard_fp, 'kept', 'NULL did not blank guard_fp while lane_id was filled');
});

test('the conflict path changes no other column, and another box is its own row', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await post(env, { box: 'hub', rows: [truncated()] });
  const before = stored(db)[0];
  await post(env, { box: 'hub', rows: [full({ cost_usd: '9.99', ts: '2030-01-01T00:00:00Z', raw: 'other',
    line_no: 99, model: 'x', note: 'n', project: 'q' })] });
  const after = stored(db)[0];
  for (const k of Object.keys(before)) {
    if (k === 'lane_id' || k === 'guard_fp') continue;
    assert.deepEqual(after[k], before[k], `column ${k} changed on conflict`);
  }
  assert.equal(after.lane_id, 'merge-conductor');
  // Same hash under another box: a separate row, untouched by hub's repair.
  const s = await post(env, { box: 'small', rows: [truncated()] });
  assert.equal(s.body.inserted, 1);
  assert.equal(count(db), 2);
  assert.equal(stored(db, 'small')[0].lane_id, null);
});
