import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { shapeLaneDedup } from '../src/lib/lane-dedup.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2669 (BH-2537 slice 3): GET /api/metrics/lane-dedup aggregates cost_rows
// into calls per distinct input (guard_fp), ticket and PR for each lane. Driven
// through the worker's REAL fetch handler over node:sqlite built from
// schema.sql (the cost-row-identity.bh-2665 harness, copied so this file stands
// alone); rows are seeded through POST /api/metrics/cost-rows.

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
async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const ANCHOR = Date.now(); // determinism: ok the single anchor; every row ts below is iso(msAgo) off it
const DAY = 24 * 60 * 60 * 1000;
const iso = (msAgo) => new Date(ANCHOR - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
let n = 0;
const row = (o) => ({ row_hash: `h${++n}`, line_no: n, ts: iso(60 * 60 * 1000), host: 'h', project: 'p1',
  stage: 'triage', runner: 'claude', model: 'm', rc: 0, cost_usd: 1, ticket: 'BH-1', ...o });
const seed = async (env, rows) => {
  for (let i = 0; i < rows.length; i += 2000) {
    const r = await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: rows.slice(i, i + 2000) });
    assert.equal(r.status, 200);
  }
};
const dedup = async (env, q = '?days=7') => {
  const r = await call(env, 'GET', '/api/metrics/lane-dedup' + q);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
};
const laneOf = (body, lane) => body.lanes.find((l) => l.lane === lane);
const times = (k, o) => Array.from({ length: k }, () => row(o));

const LANE_KEYS = ['lane', 'calls', 'distinct_fp', 'distinct_tickets', 'distinct_prs', 'no_fp_calls',
  'unidentified_calls', 'usd', 'calls_per_fp', 'calls_per_ticket', 'calls_per_pr', 'fps'];
const FP_KEYS = ['fp', 'calls', 'ticket', 'pr', 'project', 'usd'];

test('A1: 6 calls of fpA + 2 of fpB in run-triage -> calls 8, distinct_fp 2, calls_per_fp 4', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await seed(env, [
    ...times(6, { lane_id: 'run-triage', guard_fp: 'fpA', ticket: 'BH-7', pr: '70' }),
    ...times(2, { lane_id: 'run-triage', guard_fp: 'fpB', ticket: 'BH-8' }),
  ]);
  const body = await dedup(env);
  assert.equal(body.days, 7);
  assert.deepEqual(body.truncated, { fps: false });
  const l = laneOf(body, 'run-triage');
  assert.ok(l, 'run-triage lane missing');
  assert.deepEqual(Object.keys(l), LANE_KEYS);
  assert.equal(l.calls, 8);
  assert.equal(l.distinct_fp, 2);
  assert.equal(l.calls_per_fp, 4);
  assert.equal(l.distinct_tickets, 2);
  assert.equal(l.calls_per_ticket, 4);
  assert.equal(l.distinct_prs, 1);
  assert.equal(l.calls_per_pr, 8);
  assert.equal(l.no_fp_calls, 0);
  assert.equal(l.unidentified_calls, 0);
  assert.equal(l.usd, 8);
  assert.deepEqual(Object.keys(l.fps[0]), FP_KEYS);
  assert.deepEqual(l.fps[0], { fp: 'fpA', calls: 6, ticket: 'BH-7', pr: '70', project: 'p1', usd: 6 });
  assert.deepEqual(l.fps[1], { fp: 'fpB', calls: 2, ticket: 'BH-8', pr: null, project: 'p1', usd: 2 });
});

test('A2: refused rows are not calls', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await seed(env, [
    ...times(6, { lane_id: 'run-triage', guard_fp: 'fpA' }),
    ...times(2, { lane_id: 'run-triage', guard_fp: 'fpB' }),
    ...times(3, { lane_id: 'run-triage', guard_fp: 'fpC', row_source: 'refused', cost_usd: 0 }),
  ]);
  const l = laneOf(await dedup(env), 'run-triage');
  assert.equal(l.calls, 8);
  assert.equal(l.distinct_fp, 2);
  assert.deepEqual(l.fps.map((f) => f.fp), ['fpA', 'fpB']);
});

test('A3: 501 fp groups -> truncated.fps true; exactly 500 -> false', { skip: !DatabaseSync }, async () => {
  const mk = (k) => Array.from({ length: k }, (_, i) => row({ lane_id: `lane${i % 3}`, guard_fp: `fp${i}` }));
  const a = fresh();
  await seed(a.env, mk(501));
  const over = await dedup(a.env);
  assert.equal(over.truncated.fps, true);
  assert.equal(over.lanes.reduce((s, l) => s + l.calls, 0), 501, 'lane counts come from read 1, uncapped');
  const b = fresh();
  await seed(b.env, mk(500));
  assert.equal((await dedup(b.env)).truncated.fps, false);
});

test('A4: a lane with no fingerprinted rows -> distinct_fp 0, calls_per_fp null, fps []', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await seed(env, [...times(3, { lane_id: 'nofp' }), row({ lane_id: 'nofp', guard_fp: '' })]);
  const l = laneOf(await dedup(env), 'nofp');
  assert.equal(l.calls, 4);
  assert.equal(l.distinct_fp, 0);
  assert.equal(l.calls_per_fp, null);
  assert.deepEqual(l.fps, []);
  assert.equal(l.no_fp_calls, 4);
});

test('A5: days=abc is a 400 with the contract error', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', '/api/metrics/lane-dedup?days=abc');
  assert.equal(r.status, 400);
  assert.equal(r.body.error, 'days must be an integer 1..30');
});

test('A6: an unpriced lane has usd null; a priced lane has the numeric sum', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await seed(env, [
    ...times(2, { lane_id: 'free', guard_fp: 'fpF', cost_usd: null }),
    row({ lane_id: 'paid', guard_fp: 'fpP', cost_usd: 0.25 }),
    row({ lane_id: 'paid', guard_fp: 'fpP', cost_usd: null }),
    row({ lane_id: 'paid', guard_fp: 'fpQ', cost_usd: 0.5 }),
  ]);
  const body = await dedup(env);
  const free = laneOf(body, 'free');
  assert.equal(free.usd, null);
  assert.equal(free.fps[0].usd, null);
  const paid = laneOf(body, 'paid');
  assert.equal(paid.usd, 0.75);
  assert.equal(paid.fps.find((f) => f.fp === 'fpP').usd, 0.25);
});

test('A7: no lane_id -> lane null; no ticket+pr -> unidentified; the window follows days', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await seed(env, [
    row({ guard_fp: 'fpN' }),
    row({ lane_id: '', guard_fp: 'fpN' }),
    row({ lane_id: 'anon', guard_fp: 'fpX', ticket: '', pr: '' }),
    row({ lane_id: 'anon', guard_fp: 'fpX', ticket: null }),
    row({ lane_id: 'anon', guard_fp: 'fpY', ticket: null, pr: '12' }),
    row({ lane_id: 'old', guard_fp: 'fpO', ts: iso(8 * DAY) }),
  ]);
  const week = await dedup(env, '?days=7');
  const nul = week.lanes.filter((l) => l.lane === null);
  assert.equal(nul.length, 1, 'NULL and empty lane_id are one group');
  assert.equal(nul[0].calls, 2);
  assert.equal(nul[0].fps[0].fp, 'fpN');
  const anon = laneOf(week, 'anon');
  assert.equal(anon.unidentified_calls, 2);
  assert.equal(anon.distinct_tickets, 0);
  assert.equal(anon.calls_per_ticket, null);
  assert.equal(laneOf(week, 'old'), undefined, 'an 8-day-old row is outside days=7');
  const month = await dedup(env, '?days=30');
  assert.equal(month.days, 30);
  assert.equal(laneOf(month, 'old').calls, 1);
});

test('A8: a live cost_rows that predates guard_fp is migrated before the read, not a 500', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  db.exec('ALTER TABLE cost_rows DROP COLUMN guard_fp');
  const r = await call(env, 'GET', '/api/metrics/lane-dedup?days=7');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { days: 7, lanes: [], truncated: { fps: false } });
});

test('S1: shapeLaneDedup gives null ratios for a zero distinct count, never Infinity', () => {
  const out = shapeLaneDedup([{ lane: 'x', calls: 5, distinct_fp: 0, distinct_tickets: 0, distinct_prs: 2,
    no_fp_calls: 5, unidentified_calls: 5, usd: null }], [], 7);
  const l = out.lanes[0];
  assert.equal(l.calls_per_ticket, null);
  assert.equal(l.calls_per_fp, null);
  assert.equal(l.calls_per_pr, 2.5);
  assert.equal(l.usd, null);
  const walk = (v) => (v && typeof v === 'object' ? Object.values(v).forEach(walk)
    : assert.ok(v === null || typeof v !== 'number' || Number.isFinite(v), `non-finite ${v}`));
  walk(out);
});

test('S2: shapeLaneDedup keeps the top 10 fps of a lane', () => {
  const fpRows = Array.from({ length: 12 }, (_, i) => ({ lane: 'x', fp: `fp${i}`, calls: 12 - i,
    ticket: null, pr: null, project: 'p', usd: 1 }));
  const out = shapeLaneDedup([{ lane: 'x', calls: 78, distinct_fp: 12, distinct_tickets: 0, distinct_prs: 0,
    no_fp_calls: 0, unidentified_calls: 78, usd: 12 }], fpRows, 7);
  const fps = out.lanes[0].fps;
  assert.equal(fps.length, 10);
  assert.deepEqual(fps.map((f) => f.calls), [12, 11, 10, 9, 8, 7, 6, 5, 4, 3]);
  assert.equal(out.truncated.fps, false);
});
