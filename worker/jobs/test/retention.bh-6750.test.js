// BH-6750 (slice 2 of #6727): POST /api/retention/run, the scheduled D1
// retention. Driven through the REAL worker.fetch on node:sqlite with the
// composed jobs schema. Every time is an offset from one clock anchor, because
// the route cuts its windows off the server clock.
//
//   R1 wakes: acked rows past retention.wakes.acked_days and any row past
//      retention.wakes.days go; an unacked recent wake and a recently acked one stay
//   R2 job_heartbeats: a closed job's old beat goes; a running job's old beat
//      stays; a closed job's recent beat stays
//   R3 stage_events: old events of closed jobs are summed into
//      stage_events_daily, then removed; the sums equal the removed rows;
//      events of a running job stay
//   R4 cost_rows and ledgers are never touched
//   R5 dry run (the seeded default): every count is written to retention_runs,
//      no row is removed
//   R6 budget: a backlog bigger than retention.max_rows drains across runs,
//      each run removes at most max_rows, and its audit row says backlog=1
//   R7 every id read and delete the route runs uses an index (EXPLAIN QUERY PLAN)
//   R8 lane_ticks: rows whose last tick is past the window go
//   R9 a window of 0 turns that rule off; a bad value falls back to the default
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fresh() {
  const o = await openDb();
  if (!o) return null;
  return o;
}
async function run(DB, body = {}) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}
const live = (db) => setting(db, 'retention.dry_run', '0');
const count = (db, sql, ...b) => db.prepare(sql).get(...b).n;
function job(db, id, status, createdDaysAgo = 40) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?, 'p', 'T-1', 'build', 'b', 'done', ?, ?, ?)`).run(id, status, ago(createdDaysAgo), ago(createdDaysAgo));
}
function wake(db, i, atDays, ackedDays = null) {
  const at = ago(atDays);
  db.prepare(`INSERT INTO wakes (repo, kind, key, event, minute, at, acked_at) VALUES ('o/r','pr',?, 'e', ?, ?, ?)`)
    .run(String(i), at.slice(0, 16), at, ackedDays === null ? null : ago(ackedDays));
}
function event(db, jobId, stage, verdict, daysAgo) {
  db.prepare(`INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at) VALUES (?,?,?,?,NULL,?)`)
    .run(jobId, stage, verdict, 'box-a', ago(daysAgo));
}

test('R1 wakes: acked and old rows go, unacked recent and recently acked stay', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  wake(db, 1, 40);          // older than 30 d: goes
  wake(db, 2, 5, 4);        // acked 4 d ago (> 3): goes
  wake(db, 3, 1, 1);        // acked 1 d ago: stays
  wake(db, 4, 1);           // unacked, recent: stays
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT key FROM wakes ORDER BY key').all().map((x) => x.key), ['3', '4']);
});

test('R2 job_heartbeats: a closed job loses its old beat, a running job keeps it', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  job(db, 'closed-old', 'done'); job(db, 'running-old', 'running'); job(db, 'closed-new', 'done');
  const beat = db.prepare('INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?,?,?)');
  beat.run('closed-old', ago(40), 'b'); beat.run('running-old', ago(40), 'b'); beat.run('closed-new', ago(2), 'b');
  beat.run('orphan-old', ago(40), 'b');  // no jobs row at all: goes
  assert.equal((await run(DB)).status, 200);
  assert.deepEqual(db.prepare('SELECT job_id FROM job_heartbeats ORDER BY job_id').all().map((x) => x.job_id),
    ['closed-new', 'running-old']);
});

test('R3 stage_events: old events of closed jobs roll up to stage_events_daily, then go', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  job(db, 'c1', 'done', 200); job(db, 'r1', 'running', 200);
  for (let i = 0; i < 3; i++) event(db, 'c1', 'review', 'APPROVE', 120);
  event(db, 'c1', 'review', null, 120);
  event(db, 'c1', 'plan', 'OK', 150);
  event(db, 'r1', 'plan', 'OK', 150);       // running job: stays
  event(db, 'c1', 'merge', 'MERGED', 10);   // recent: stays
  const before = count(db, 'SELECT COUNT(*) n FROM stage_events');
  assert.equal((await run(DB)).status, 200);
  const after = count(db, 'SELECT COUNT(*) n FROM stage_events');
  const daily = db.prepare('SELECT day, stage, verdict, actor, n FROM stage_events_daily ORDER BY stage, verdict').all()
    .map((x) => ({ ...x }));
  assert.equal(after, 2, 'the running job event and the recent event stay');
  assert.equal(daily.reduce((s, x) => s + x.n, 0), before - after, 'the daily sums equal the removed rows');
  assert.deepEqual(daily.map((x) => [x.stage, x.verdict, x.n]), [['plan', 'OK', 1], ['review', '', 1], ['review', 'APPROVE', 3]]);
  assert.equal(daily[0].day, ago(150).slice(0, 10));
});

test('R4 cost_rows and ledgers are never touched', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, cost_usd, inserted_at) VALUES ('b','h',1,?,1.5,?)`).run(ago(900), ago(900));
  db.prepare(`INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('merge','k','merged',?,?)`).run(ago(900), ago(900));
  const r = await run(DB);
  assert.equal(r.status, 200);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 1);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM ledgers'), 1);
  assert.ok(!r.body.rules.some((x) => /cost_rows|ledgers/.test(x.table)), 'no rule names cost_rows or ledgers');
});

test('R5 dry run (the seeded default) counts and writes the audit rows, and removes nothing', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  for (let i = 0; i < 7; i++) wake(db, i, 40);
  job(db, 'c', 'done'); db.prepare('INSERT INTO job_heartbeats (job_id, beat_at) VALUES (?,?)').run('c', ago(40));
  const r = await run(DB);
  assert.equal(r.status, 200);
  assert.equal(r.body.dry_run, true);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM wakes'), 7);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM job_heartbeats'), 1);
  const audit = db.prepare("SELECT rule, dry_run, counted, removed FROM retention_runs ORDER BY rule").all().map((x) => ({ ...x }));
  const byRule = Object.fromEntries(audit.map((x) => [x.rule, x]));
  assert.equal(byRule['wakes.age'].counted, 7);
  assert.equal(byRule['wakes.age'].removed, 0);
  assert.equal(byRule['wakes.age'].dry_run, 1);
  assert.equal(byRule['job_heartbeats.closed'].counted, 1);
  assert.equal(audit.length, r.body.rules.length, 'one audit row per rule per run');
});

test('R6 budget: a backlog over retention.max_rows drains over runs, each within budget', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  setting(db, 'retention.max_rows', 40); setting(db, 'retention.batch', 15);
  for (let i = 0; i < 100; i++) wake(db, i, 40);
  const r1 = await run(DB);
  const w1 = r1.body.rules.find((x) => x.rule === 'wakes.age');
  assert.equal(w1.removed, 40); assert.equal(w1.backlog, true);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM wakes'), 60);
  await run(DB); const r3 = await run(DB);
  const w3 = r3.body.rules.find((x) => x.rule === 'wakes.age');
  assert.equal(w3.removed, 20); assert.equal(w3.backlog, false);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM wakes'), 0);
  const last = db.prepare("SELECT backlog FROM retention_runs WHERE rule='wakes.age' ORDER BY id DESC LIMIT 1").get();
  assert.equal(last.backlog, 0);
});

test('R7 every id read and delete uses an index', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const { RULES } = await import('../src/routes/retention.js');
  const HOT = ['wakes', 'job_heartbeats', 'stage_events', 'lane_ticks', 'jobs', 'retention_runs'];
  for (const r of RULES) {
    for (const sql of [r.ids, r.del]) {
      const lines = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...(sql === r.ids ? [ago(30), 10] : ['[1]'])).map((x) => x.detail);
      const bad = lines.filter((l) => { const m = /^SCAN (\w+)/.exec(l); return m && HOT.includes(m[1]) && !/USING (INDEX|PRIMARY KEY|INTEGER PRIMARY KEY)/.test(l) && !/^SCAN json_each/.test(l); });
      assert.deepEqual(bad, [], `${r.rule}: ${lines.join(' | ')}`);
    }
  }
});

test('R8 lane_ticks: rows whose last tick is past the window go', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  const tick = db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at) VALUES (?,?,?,?, 'ran', ?)`);
  tick.run('gone-lane', '-', 'old-box', ago(45), ago(45));
  tick.run('live-lane', '-', 'hub', ago(0), ago(0));
  assert.equal((await run(DB)).status, 200);
  assert.deepEqual(db.prepare('SELECT lane FROM lane_ticks').all().map((x) => x.lane), ['live-lane']);
});

test('R9 a window of 0 turns a rule off; a bad value uses the default', async (t) => {
  const o = await fresh(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o; live(db);
  setting(db, 'retention.wakes.days', 0); setting(db, 'retention.wakes.acked_days', 'banana');
  wake(db, 1, 400); wake(db, 2, 10, 10);
  const r = await run(DB);
  assert.equal(r.body.rules.find((x) => x.rule === 'wakes.age').off, true);
  assert.deepEqual(db.prepare('SELECT key FROM wakes').all().map((x) => x.key), ['1'], 'age is off; acked uses the 3 d default');
});
