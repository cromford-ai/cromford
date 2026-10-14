import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { LANES_REGISTRY } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-6174 (BH-5526 slice C4): GET /api/metrics/lane-spend gives Mission
// Control each lane's spend today against its alert line and its ceiling.
// Driven through the worker's REAL fetch handler over node:sqlite built from
// schema.sql, with the D1 shim that refuses more than 100 binds, because the
// things under test are the SQL (which rows a lane owns, chunked IN lists) and
// the grammar the box gate applies to the ceiling row.
//
//   W1 today is the gate's sum     W2 ceiling grammar     W3 current p99 row
//   W4 over flags (>=)             W5 listing + chunking  W6 no write, bad input
//   W7 the fleet kill switch

const SECRET = 'test-secret';
const DAY = '2026-10-12';
const DAYC = '20261012';

async function fresh() {
  const o = await openDb();
  if (!o) return null;
  // A clean settings table: only the rows a test writes.
  o.db.exec("DELETE FROM settings WHERE key LIKE 'spend.ceiling.%' OR key LIKE 'switch.%'");
  return { db: o.db, env: { DB: o.DB, HARNESS_SECRET: SECRET } };
}
async function call(env, path, auth = true) {
  const headers = auth ? { authorization: 'Bearer ' + SECRET } : {};
  const res = await worker.fetch(new Request('https://jobs.test' + path, { headers }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
let n = 0;
function cost(db, lane, usd, ts = `${DAY}T10:00:00Z`) {
  n += 1;
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, host, project, stage, runner, model, rc, cost_usd, lane_id, inserted_at)
              VALUES ('hub', ?, ?, ?, 'h', 'p1', 'execute', 'claude', 'm', 0, ?, ?, '2026-10-12T00:00:00Z')`)
    .run(`h${n}`, n, ts, usd, lane);
}
function setting(db, key, value, actor = 'operator') {
  db.prepare(`INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 'fixture', ?, '2026-10-12T00:00:00Z')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value, actor=excluded.actor`).run(key, value, actor);
}
function p99(db, lane, status, detail) {
  db.prepare(`INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at)
              VALUES ('spend_p99', ?, ?, 'hub', ?, '2026-10-12T00:00:00Z', '2026-10-12T00:00:00Z')`)
    .run(lane, status, detail);
}
const lane = (body, id) => (body.lanes || []).find((l) => l.lane === id);
const SKIP = { skip: !(await openDb()) && 'node:sqlite missing' };

test('W1 today_usd is the lane_id sum of this UTC day, the same number llm-spend?lane= gives the gate', SKIP, async () => {
  const { db, env } = await fresh();
  cost(db, 'fly-pool', 4); cost(db, 'fly-pool', 6);
  cost(db, 'fly-pool', 50, '2026-10-11T23:59:59Z');
  cost(db, 'fly-pool', 70, '2026-10-13T00:00:00Z');
  cost(db, 'lead-review', 9); cost(db, null, 7);
  const r = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.day, DAY);
  assert.equal(r.body.since, `${DAY}T00:00:00Z`);
  assert.equal(r.body.until, '2026-10-13T00:00:00Z');
  const fp = lane(r.body, 'fly-pool');
  assert.equal(fp.today_usd, 10);
  assert.equal(fp.calls, 2);
  assert.equal(lane(r.body, 'lead-review').today_usd, 9);
  const g = await call(env, `/api/metrics/llm-spend?lane=fly-pool&since=${DAY}T00:00:00Z&until=${DAY}T23:59:59Z`);  // determinism: ok since= and until= pin the window to the fixed DAY
  assert.equal(g.body.usd, fp.today_usd);
  // Sorted today_usd desc.
  assert.deepEqual(r.body.lanes.map((l) => l.lane), ['fly-pool', 'lead-review']);
});

test('W2 the ceiling row follows _llm_ceiling: armed, off, zero, junk; a registry-seed row is none', SKIP, async () => {
  const { db, env } = await fresh();
  setting(db, 'spend.ceiling.fly-pool.day_usd', '10');
  setting(db, 'spend.ceiling.lead-review.day_usd', ' 10.5 ');
  setting(db, 'spend.ceiling.review-prs.day_usd', 'off');
  setting(db, 'spend.ceiling.alert-triage.day_usd', '0');
  setting(db, 'spend.ceiling.pipeline-health.day_usd', 'abc');
  setting(db, 'spend.ceiling.merge-conductor.day_usd', '25', 'registry-seed');
  cost(db, 'merge-conductor', 1);
  const r = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const got = (id) => { const l = lane(r.body, id); return l && [l.ceiling_state, l.ceiling_usd]; };
  assert.deepEqual(got('fly-pool'), ['armed', 10]);
  assert.deepEqual(got('lead-review'), ['armed', 10.5]);
  assert.deepEqual(got('review-prs'), ['off', null]);
  assert.deepEqual(got('alert-triage'), ['zero', null]);
  assert.deepEqual(got('pipeline-health'), ['junk', null]);
  assert.equal(lane(r.body, 'pipeline-health').ceiling_raw, 'abc');
  assert.deepEqual(got('merge-conductor'), ['none', null]);
});

test('W3 only the p99 rows of the newest table day not after the requested day are current', SKIP, async () => {
  const { db, env } = await fresh();
  p99(db, 'fly-pool', DAYC, 'p99=100.00 days=14 mult=1.5 alert=150.00');
  p99(db, 'lead-review', '20261011', 'p99=4.00 days=9 mult=1.5 alert=6.00');
  p99(db, 'review-prs', '20261013', 'p99=8.00 days=9 mult=1.5 alert=12.00');
  p99(db, 'alert-triage', DAYC, 'p99=lots');
  const r = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.p99_day, DAY);
  const fp = lane(r.body, 'fly-pool');
  assert.deepEqual([fp.p99_usd, fp.p99_days, fp.alert_mult, fp.alert_usd], [100, 14, 1.5, 150]);
  // An older or a later table is not today's line: no alert, so not listed.
  assert.equal(lane(r.body, 'lead-review'), undefined);
  assert.equal(lane(r.body, 'review-prs'), undefined);
  assert.equal(r.body.skipped_rows, 1);
  assert.equal(lane(r.body, 'alert-triage'), undefined);
  // With spend today, a lane on an older table is listed with null lines.
  cost(db, 'lead-review', 2);
  const r2 = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  const lr = lane(r2.body, 'lead-review');
  assert.deepEqual([lr.p99_usd, lr.alert_usd, lr.over_alert], [null, null, false]);
  // Asked for yesterday, yesterday's table is the current one.
  const r3 = await call(env, '/api/metrics/lane-spend?day=2026-10-11');
  assert.equal(r3.body.p99_day, '2026-10-11');
  assert.equal(lane(r3.body, 'lead-review').alert_usd, 6);
  assert.equal(lane(r3.body, 'fly-pool'), undefined);
});

test('W4 over_alert and over_ceiling are >=, the gate\'s own comparison', SKIP, async () => {
  const { db, env } = await fresh();
  p99(db, 'fly-pool', DAYC, 'p99=10.00 days=14 mult=1.5 alert=15.00');
  p99(db, 'lead-review', DAYC, 'p99=10.00 days=14 mult=1.5 alert=15.00');
  cost(db, 'fly-pool', 15); cost(db, 'lead-review', 14.99);
  setting(db, 'spend.ceiling.review-prs.day_usd', '10'); cost(db, 'review-prs', 10);
  setting(db, 'spend.ceiling.alert-triage.day_usd', '10'); cost(db, 'alert-triage', 9.99);
  setting(db, 'spend.ceiling.pipeline-health.day_usd', 'off'); cost(db, 'pipeline-health', 500);
  const r = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(lane(r.body, 'fly-pool').over_alert, true);
  assert.equal(lane(r.body, 'lead-review').over_alert, false);
  assert.equal(lane(r.body, 'review-prs').over_ceiling, true);
  assert.equal(lane(r.body, 'review-prs').pct_of_ceiling, 100);
  assert.equal(lane(r.body, 'alert-triage').over_ceiling, false);
  assert.equal(lane(r.body, 'alert-triage').pct_of_ceiling, 99.9);
  const ph = lane(r.body, 'pipeline-health');
  assert.deepEqual([ph.over_ceiling, ph.pct_of_ceiling, ph.over_alert], [false, null, false]);
});

test('W5 listing: a quiet registry lane is not listed; stage ids are listed unregistered; ids past 90 are read', SKIP, async () => {
  const { db, env } = await fresh();
  const ids = (LANES_REGISTRY.lanes || []).map((l) => l.id);
  assert.ok(ids.length > 90, `the registry has ${ids.length} lanes; the chunk test needs more than 90`);
  const late = ids[ids.length - 1];
  cost(db, late, 3.5);
  cost(db, 'fly-pool', 1);
  p99(db, 'stage-review', DAYC, 'p99=3.10 days=9 mult=1.5 alert=4.65');
  cost(db, 'stage-review', 0.5);
  const r = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.lanes.map((l) => l.lane).sort(), [late, 'fly-pool', 'stage-review'].sort());
  assert.equal(lane(r.body, late).today_usd, 3.5);
  assert.equal(lane(r.body, 'fly-pool').registered, true);
  const st = lane(r.body, 'stage-review');
  assert.deepEqual([st.registered, st.today_usd, st.alert_usd], [false, 0.5, 4.65]);
});

test('W6 a GET writes no row; a bad day is 400; no bearer is 401', SKIP, async () => {
  const { db, env } = await fresh();
  cost(db, 'fly-pool', 2); setting(db, 'spend.ceiling.fly-pool.day_usd', '10');
  p99(db, 'fly-pool', DAYC, 'p99=1.00 days=9 mult=1.5 alert=1.50');
  const counts = () => ['ledgers', 'settings', 'cost_rows']
    .map((t) => db.prepare(`SELECT COUNT(*) AS c FROM ${t}`).get().c);
  const before = counts();
  const r = await call(env, `/api/metrics/lane-spend?day=${DAY}`);
  assert.equal(r.status, 200);
  assert.deepEqual(counts(), before);
  for (const bad of ['2026-13-40', '2026-02-30', '20261012', 'x']) {
    const b = await call(env, `/api/metrics/lane-spend?day=${bad}`);
    assert.equal(b.status, 400, bad);
    assert.equal(b.body.error, 'day must be YYYY-MM-DD');
  }
  assert.equal((await call(env, '/api/metrics/lane-spend', false)).status, 401);
  // No ?day= is the worker's UTC day: the day of its own request clock.
  const d = await call(env, '/api/metrics/lane-spend');
  assert.match(d.body.as_of, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(d.body.day, d.body.as_of.slice(0, 10));
});

test('W7 the fleet row switch.spend-ceiling-off: 1|on|true is true, 0|off|false is false, absent or junk is null', SKIP, async () => {
  const { db, env } = await fresh();
  const sw = async () => (await call(env, `/api/metrics/lane-spend?day=${DAY}`)).body.ceiling_switch_fleet;
  assert.equal(await sw(), null);
  setting(db, 'switch.spend-ceiling-off', '1'); assert.equal(await sw(), true);
  setting(db, 'switch.spend-ceiling-off', 'on'); assert.equal(await sw(), true);
  setting(db, 'switch.spend-ceiling-off', '0'); assert.equal(await sw(), false);
  setting(db, 'switch.spend-ceiling-off', 'maybe'); assert.equal(await sw(), null);
});
