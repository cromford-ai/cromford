// BH-7792 (#7792 comment 6309315490): the lead lane asks the call-guard, BEFORE
// its rules pack and host suite, whether a paid call on one head's key would be
// refused. That read is GET /api/call-guard?project=&stage=&fp= : the roll-up of
// ONE fingerprint, read-only (no claim row is written).
//   F1  fp= answers only that key's row, with its paid count.
//   F2  a key with no rows answers rows: [].
//   F3  the read writes nothing: the table has the same rows after it.
//   F4  the plan for the fp read uses idx_call_guard_key.
import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return { prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }) };
}
const fresh = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const call = (db, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const FP_A = 'lead:example-org/cromford#7663@6ffad02eebd2';
const FP_B = 'lead:example-org/cromford#7556@347bd417aaaa';
const claim = (db, fp, id) => call(db, '/api/call-guard/claim', {
  method: 'POST', body: { project: 'cromford', stage: 'lead-head', fp, call_id: id, max: 1 },
});
const read = (db, fp) => call(db, `/api/call-guard?project=cromford&stage=lead-head&hours=24&fp=${encodeURIComponent(fp)}`);

test('F1. fp= answers only that key, with its paid count', async () => {
  const db = fresh();
  assert.equal((await claim(db, FP_A, 'a1')).body.allowed, true);
  assert.equal((await claim(db, FP_A, 'a2')).body.allowed, false);
  assert.equal((await claim(db, FP_B, 'b1')).body.allowed, true);
  const res = await read(db, FP_A);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.rows.length, 1, JSON.stringify(res.body));
  assert.equal(res.body.rows[0].fp, FP_A);
  assert.equal(res.body.rows[0].paid, 1);
  assert.equal(res.body.rows[0].refused, 1);
});

test('F2. a key with no rows answers rows: []', async () => {
  const db = fresh();
  await claim(db, FP_B, 'b1');
  const res = await read(db, FP_A);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.rows, []);
});

test('F3. the read writes nothing', async () => {
  const db = fresh();
  await claim(db, FP_A, 'a1');
  const before = db.prepare('SELECT COUNT(*) AS n FROM call_guard').get().n;
  await read(db, FP_A); await read(db, FP_B);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM call_guard').get().n, before);
});

test('F4. the fp read is served by idx_call_guard_key', () => {
  const db = fresh();
  const plan = db.prepare(
    "EXPLAIN QUERY PLAN SELECT rowid FROM call_guard WHERE at>=?1 AND project=?2 AND stage=?3 AND fp=?4"
  ).all('2026-10-20T00:00:00Z', 'cromford', 'lead-head', FP_A).map((r) => r.detail).join(' | ');
  assert.match(plan, /idx_call_guard_key/, plan);
});
