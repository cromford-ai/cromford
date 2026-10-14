import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3926 (BH-3921.3): GET /api/metrics/triage-paid-unchanged — the daily,
// per-project count of triage tickets the model was paid to re-read although
// their inputs had not changed. It reads the cost-row notes the triage lane
// writes (bin/lib/triage-state-waste.sh): a single-session row's
// `ts:new=N:…:pu=N` suffix, and +1 per shard row noted `ts=unchanged`. Driven
// through the real worker.fetch over a real schema.sql in node:sqlite, clock
// pinned (the cost-breakdown.bh-3557 pattern).

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA|WITH)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
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
  return { prepare: (sql) => make(sql, []), batch: async (s) => s.map((x) => exec(x._sql, x._binds)) };
}

// Every fixture instant and every expected window edge is an offset from this
// one anchor, which is also what the mocked request clock answers, so the rows
// sit where the rolling ?days= window looks whatever the anchor is.
const NOW_MS = Date.parse('2099-09-25T12:00:00Z');
const DAY_MS = 86400000;
const iso = (ms) => new Date(ms).toISOString();
const dayAgo = (n) => iso(NOW_MS - n * DAY_MS).slice(0, 10);
const at = (n, hhmm) => `${dayAgo(n)}T${hhmm}:00.000Z`;
const D = dayAgo(0);
const Y = dayAgo(1);

// ts, project, stage, rc, note, cost_usd
const ROWS = [
  // W1: day D, p1 — 3 + 0 + 1 (the shard) = 4 paid unchanged over 2 waste calls of 3
  [at(0, '10:00'), 'p1', 'triage', 0, 'ts:new=0:chg=1:due=0:cap=0:unr=0:pu=3', 2.0],
  [at(0, '10:05'), 'p1', 'triage', 0, 'ts:new=1:chg=0:due=0:cap=0:unr=0:pu=0', 1.5],
  [at(0, '10:10'), 'p1', 'triage', 0, 'ts=unchanged', 0.25],
  // W2: rows that must NOT count (day D, p2)
  [at(0, '09:00'), 'p2', 'triage', 1, 'ts:new=0:chg=0:due=0:cap=0:unr=0:pu=9', 1.0],
  [at(0, '09:01'), 'p2', 'execute', 0, 'ts:new=0:chg=0:due=0:cap=0:unr=0:pu=5', 7.0],
  [at(0, '09:02'), 'p2', 'triage', 0, 'context-kill:x:pu=9', 0.5],
  [at(0, '09:03'), 'p2', 'triage', 0, 'ts=unchanged-x', 0.5],
  // and one that does, with agent-call's own tokens appended after ours
  [at(0, '09:04'), 'p2', 'triage', 0, 'ts:new=0:chg=0:due=0:cap=0:unr=0:pu=2;cache_ttl=1h', 0.5],
  // the day before, a null project, a mid-note shard token
  [at(1, '20:00'), null, 'triage', 0, 'cliff:x;ts=unchanged;cache_ttl=1h', null],
  [at(1, '21:00'), 'p1', 'triage', 0, 'ts:new=0:chg=0:due=0:cap=0:unr=3:pu=na', 0.75],
  // outside a 1-day window, inside the default 14
  [at(10, '08:00'), 'p3', 'triage', 0, 'ts=unchanged', 0.1],
];
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg}: ${a} != ${b}`);

function freshD1(t, rows = ROWS) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const ins = db.prepare(
    `INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, rc, note, cost_usd, inserted_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`);
  rows.forEach((r, i) => ins.run('hub', `h${i}`, i + 1, ...r, iso(NOW_MS)));
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function get(env, qs, auth = true) {
  const res = await worker.fetch(new Request('https://jobs.test/api/metrics/triage-paid-unchanged' + qs,
    { headers: auth ? { authorization: 'Bearer ' + SECRET } : {} }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function ok(env, qs) {
  const r = await get(env, qs);
  assert.equal(r.status, 200, `${qs}: ${JSON.stringify(r.body)}`);
  return r.body;
}
const row = (b, day, project) => b.rows.find((r) => r.day === day && r.project === project);

test('W1: the pu suffix sums, a ts=unchanged shard row adds 1, usd is the day\'s triage spend', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '');
  const p1 = row(b, D, 'p1');
  assert.ok(p1, JSON.stringify(b.rows));
  assert.equal(p1.paid_unchanged, 4);
  assert.equal(p1.waste_calls, 2);
  assert.equal(p1.triage_calls, 3);
  close(p1.usd, 3.75, 'p1 usd');
  const none = row(b, Y, null);
  assert.equal(none.paid_unchanged, 1, 'a ts=unchanged token mid-note counts');
  assert.equal(none.usd, null, 'an unpriced day stays null, never 0');
  assert.equal(row(b, Y, 'p1').paid_unchanged, 0, 'pu=na reads as 0 paid, the call still counted');
  assert.equal(row(b, Y, 'p1').triage_calls, 1);
  db.close();
});

test('W2: rc!=0, other stages, a pu= with no ts:new=, and ts=unchanged-x never count; order is day desc', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '');
  const p2 = row(b, D, 'p2');
  assert.equal(p2.paid_unchanged, 2, JSON.stringify(p2));
  assert.equal(p2.waste_calls, 1);
  assert.equal(p2.triage_calls, 3, 'the rc=1 row and the execute row are not triage calls');
  const days = b.rows.map((r) => r.day);
  assert.deepEqual(days, [...days].sort().reverse(), 'day desc');
  assert.equal(b.rows[0].day, D);
  assert.equal(b.rows[0].project, 'p1', 'inside a day, the higher paid_unchanged first');
  db.close();
});

test('W3: days is clamped 1..60, defaults to 14, echoed, and never reaches the SQL', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const cases = [['', 14, dayAgo(13)], ['?days=0', 1, D], ['?days=-3', 1, D], ['?days=999', 60, dayAgo(59)],
    ['?days=abc', 14, dayAgo(13)], ['?days=7.5', 14, dayAgo(13)], ['?days=7', 7, dayAgo(6)]];
  for (const [qs, days, from] of cases) {
    const b = await ok(env, qs);
    assert.equal(b.days, days, qs);
    assert.equal(b.from, `${from}T00:00:00Z`, qs);
  }
  const one = await ok(env, '?days=1');
  assert.ok(one.rows.every((r) => r.day === D), 'a 1-day window is today only');
  const two = await ok(env, '?days=14');
  assert.ok(two.rows.some((r) => r.project === 'p3'), 'the 14-day window reaches 10 days back');
  const inj = await ok(env, '?days=' + encodeURIComponent('1);DROP TABLE cost_rows;--'));
  assert.equal(inj.days, 14);
  assert.deepEqual(inj.rows, two.rows, 'same answer as the default');
  assert.ok(db.prepare("SELECT COUNT(*) AS n FROM cost_rows").get().n === ROWS.length, 'the table still exists');
  db.close();
});

test('W4: the route sits behind the bearer', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const r = await get(env, '', false);
  assert.equal(r.status, 401);
  db.close();
});

test('W5: the answer is exactly {days, from, rows, truncated, as_of}; an empty window is rows: []', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t, []);
  const b = await ok(env, '');
  assert.deepEqual(Object.keys(b).sort(), ['as_of', 'days', 'from', 'rows', 'truncated']);
  assert.deepEqual(b.rows, []);
  assert.equal(b.truncated, false);
  assert.equal(b.as_of, iso(NOW_MS).replace('.000Z', 'Z'), 'the request clock');
  db.close();
});
