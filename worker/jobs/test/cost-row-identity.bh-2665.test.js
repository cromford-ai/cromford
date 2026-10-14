import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { shapeLaneDedup } from '../src/lib/lane-dedup.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2665 (BH-2537 slice 1): cost rows carry a 26th column, guard_fp (the
// pre-call guard's input fingerprint), and the cost family gains a shape-only
// GET /api/metrics/lane-dedup (worker/jobs/src/lib/lane-dedup.js) whose lanes[]
// stays empty until the aggregation sibling (#2669) fills it. Driven through
// the worker's REAL fetch handler over node:sqlite built from schema.sql, the
// llm-spend-lane.bh-2303 harness. tests/cost-row-header.bh-2665-test.sh runs
// this file.

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
async function call(env, method, path, body, { auth = true } = {}) {
  const headers = auth ? { authorization: 'Bearer ' + SECRET } : {};
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const ANCHOR = Date.now(); // determinism: ok the single anchor; every row ts below is iso(msAgo) off it
const iso = (msAgo) => new Date(ANCHOR - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
let n = 0;
const row = (o) => ({ row_hash: `h${++n}`, line_no: n, ts: iso(60 * 60 * 1000), host: 'h', project: 'p1',
  stage: 'review', runner: 'claude', model: 'm', rc: 0, cost_usd: 1, ...o });

test('W1/W2: POST cost-rows stores guard_fp; a row without one stores NULL', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'POST', '/api/metrics/cost-rows',
    { box: 'hub', rows: [row({ guard_fp: 'fpA' }), row({})] });
  assert.equal(r.status, 200);
  const got = db.prepare('SELECT guard_fp FROM cost_rows ORDER BY line_no').all().map((x) => x.guard_fp);
  assert.deepEqual(got, ['fpA', null]);
});

test('W3: GET cost-rows filters on guard_fp and lane_id', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ guard_fp: 'fpA', lane_id: 'laneL' }),
    row({ guard_fp: 'fpA', lane_id: 'laneM' }),
    row({ guard_fp: 'fpB', lane_id: 'laneL' }),
  ] });
  const both = await call(env, 'GET', '/api/metrics/cost-rows?guard_fp=fpA&lane_id=laneL');
  assert.equal(both.status, 200);
  assert.deepEqual(both.body.cost_rows.map((x) => [x.guard_fp, x.lane_id]), [['fpA', 'laneL']]);
  const lane = await call(env, 'GET', '/api/metrics/cost-rows?lane_id=laneL');
  assert.equal(lane.body.cost_rows.length, 2);
  assert.ok(lane.body.cost_rows.every((x) => x.lane_id === 'laneL'));
  const fp = await call(env, 'GET', '/api/metrics/cost-rows?guard_fp=fpA');
  assert.equal(fp.body.cost_rows.length, 2);
});

test('W4: GET lane-dedup?days=7 answers the contract shape', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', '/api/metrics/lane-dedup?days=7');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { days: 7, lanes: [], truncated: { fps: false } });
});

test('W5: days outside 1..30 or not an integer is a 400, never clamped', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  for (const d of ['abc', '0', '31', '-1', '7.5', '1e1', '99', ' 7']) {
    const r = await call(env, 'GET', `/api/metrics/lane-dedup?days=${encodeURIComponent(d)}`);
    assert.equal(r.status, 400, `days=${d} answered ${r.status}`);
    assert.equal(r.body.error, 'days must be an integer 1..30');
  }
});

test('W6: no days (or days=) means 7; days=1 and days=30 are accepted as given', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  for (const [q, want] of [['', 7], ['?days=', 7], ['?days=1', 1], ['?days=30', 30]]) {
    const r = await call(env, 'GET', '/api/metrics/lane-dedup' + q);
    assert.equal(r.status, 200, `${q} answered ${r.status}`);
    assert.equal(r.body.days, want);
  }
});

test('W7: shapeLaneDedup returns the same contract shape', () => {
  assert.deepEqual(shapeLaneDedup([], [], 3), { days: 3, lanes: [], truncated: { fps: false } });
});

test('W8: lane-dedup is bearer-gated like every /api/metrics route', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', '/api/metrics/lane-dedup', undefined, { auth: false });
  assert.equal(r.status, 401);
});
