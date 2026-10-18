import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { LAST_BEAT_SQL } from '../src/routes/boxes.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

// BH-7304 (BH-7191.2): the sync facts a box sends on its liveness post, and
// the per-box heartbeat GET /api/boxes derives from lane_ticks. Driven through
// worker.fetch (the production entry, auth gate included) against the SQL that
// ships: jobsSchemaSql() on node:sqlite, ensureColumns adding the rest.

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
const skip = !DatabaseSync && 'node:sqlite missing';

const SECRET = 'fixture-secret';
const SHA = 'abcdef0123456789abcdef0123456789abcdef01';

// The worker stamps every write with new Date(); a fixed clock per call.
const RealDate = Date;
let clockMs = RealDate.UTC(2026, 9, 18, 3, 0, 0);
class FixtureDate extends RealDate {
  constructor(...a) { if (a.length === 0) super(clockMs); else super(...a); }
  static now() { return clockMs; }
}
const at = (iso) => { clockMs = RealDate.parse(iso); };

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}
async function call(env, path, { method = 'GET', body } = {}) {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  globalThis.Date = FixtureDate;
  try {
    const res = await worker.fetch(req, env);
    return { status: res.status, body: await res.json().catch(() => null) };
  } finally { globalThis.Date = RealDate; }
}
const tick = (env, extra = {}, lane = 'merge-conductor', box = 'box-a') =>
  call(env, '/api/lanes/liveness', { method: 'POST', body: { lane, project: '', box, outcome: 'ran', ...extra } });
const boxOf = async (env, box) => {
  const r = await call(env, '/api/boxes');
  assert.equal(r.status, 200);
  return (r.body.boxes || []).find((b) => b.box === box);
};

test('W1: a liveness post stores harness_synced_at and sync_timer; GET /api/boxes returns them', { skip }, async () => {
  const { env } = fresh();
  at('2026-10-18T03:00:00Z');
  const r = await tick(env, { harness_commit: SHA, harness_synced_at: '2026-10-18T02:00:00Z', sync_timer: 0 });
  assert.equal(r.status, 200);
  const b = await boxOf(env, 'box-a');
  assert.ok(b, 'box-a has no box_status row');
  assert.equal(b.harness_commit, SHA);
  assert.equal(b.harness_synced_at, '2026-10-18T02:00:00Z');
  assert.equal(b.sync_timer, 0);
  // The string forms "1" / "0" are accepted too.
  await tick(env, { sync_timer: '1' });
  assert.equal((await boxOf(env, 'box-a')).sync_timer, 1);
  await tick(env, { sync_timer: 1 });
  assert.equal((await boxOf(env, 'box-a')).sync_timer, 1);
  await tick(env, { sync_timer: '0' });
  assert.equal((await boxOf(env, 'box-a')).sync_timer, 0);
});

test('W2: junk values are ignored, the tick still lands, a synced-only post keeps harness_reported_at', { skip }, async () => {
  const { db, env } = fresh();
  at('2026-10-18T03:00:00Z');
  await tick(env, { harness_commit: SHA, harness_synced_at: '2026-10-18T02:00:00Z', sync_timer: 1 });
  for (const [i, junk] of [
    { sync_timer: 'yes', harness_synced_at: 'x' },
    { sync_timer: 2, harness_synced_at: '2026-10-18' },
    { sync_timer: true, harness_synced_at: 20261018 },
    { sync_timer: { v: 1 }, harness_synced_at: '2026-10-18T02:00:00Z junk' },
  ].entries()) {
    at(`2026-10-18T03:0${i + 1}:00Z`);
    const r = await tick(env, junk);
    assert.equal(r.status, 200, JSON.stringify(junk));
    const t = db.prepare("SELECT last_tick_at FROM lane_ticks WHERE lane='merge-conductor' AND box='box-a'").get();
    assert.equal(t.last_tick_at, `2026-10-18T03:0${i + 1}:00Z`, 'the tick did not land');
    const b = await boxOf(env, 'box-a');
    assert.equal(b.sync_timer, 1, `sync_timer moved on ${JSON.stringify(junk)}`);
    assert.equal(b.harness_synced_at, '2026-10-18T02:00:00Z', `harness_synced_at moved on ${JSON.stringify(junk)}`);
  }
  at('2026-10-18T03:30:00Z');
  await tick(env, { harness_synced_at: '2026-10-18T03:20:00Z', sync_timer: 0 });
  const b = await boxOf(env, 'box-a');
  assert.equal(b.harness_synced_at, '2026-10-18T03:20:00Z');
  assert.equal(b.sync_timer, 0);
  assert.equal(b.harness_commit, SHA);
  assert.equal(b.harness_reported_at, '2026-10-18T03:00:00Z', 'a synced-only post refreshed harness_reported_at');
  // A sha post moves the report time and keeps the sync facts.
  at('2026-10-18T03:40:00Z');
  await tick(env, { harness_commit: SHA });
  const c = await boxOf(env, 'box-a');
  assert.equal(c.harness_reported_at, '2026-10-18T03:40:00Z');
  assert.equal(c.harness_synced_at, '2026-10-18T03:20:00Z');
  assert.equal(c.sync_timer, 0);
  // A post with no sha and no valid fact writes no box_status row.
  await tick(env, { sync_timer: 'yes' }, 'merge-conductor', 'box-new');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM box_status WHERE box='box-new'").get().n, 0);
});

test('W3: last_beat_at is the newest tick of the box over all its lanes; a box with no tick is null', { skip }, async () => {
  const { env } = fresh();
  at('2026-10-18T01:00:00Z'); await tick(env, { harness_commit: SHA }, 'merge-conductor', 'box-a');
  at('2026-10-18T02:00:00Z'); await tick(env, {}, 'alert-digest', 'box-a');
  at('2026-10-18T03:00:00Z'); await tick(env, {}, 'alert-flush', 'box-a');
  at('2026-10-18T02:30:00Z'); await tick(env, {}, 'alert-triage', 'box-b');
  // A box_status row from another writer, with no lane tick at all.
  const r = await call(env, '/api/boxes/backup', { method: 'POST', body: { box: 'box-quiet', ts: '2026-10-18T00:00:00Z', off: '0', unconfigured: '0' } });
  assert.equal(r.status, 200);
  const all = (await call(env, '/api/boxes')).body.boxes;
  const m = Object.fromEntries(all.map((b) => [b.box, b.last_beat_at]));
  assert.equal(m['box-a'], '2026-10-18T03:00:00Z');
  assert.equal(m['box-quiet'], null);
  // box-b ticks but has no box_status row: the roster stays box_status.
  assert.equal('box-b' in m, false);
  assert.deepEqual(all.map((b) => b.box), ['box-a', 'box-quiet']);
});

test('W4: the aggregate uses idx_lane_ticks_box at 8000 rows over 50 boxes', { skip }, async () => {
  const { db, env } = fresh();
  // GET /api/boxes is what creates the index (ensureColumns(lane_ticks)).
  assert.equal((await call(env, '/api/boxes')).status, 200);
  const rows = [];
  for (let b = 0; b < 50; b++) for (let l = 0; l < 160; l++) {
    const ts = new RealDate(RealDate.UTC(2026, 9, 1) + (b * 160 + l) * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    rows.push([`lane-${l}`, '-', `box-${b}`, ts, 'ran', ts]);
  }
  for (let i = 0; i < rows.length; i += 500) {
    const chunk = rows.slice(i, i + 500);
    db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at) VALUES ${chunk.map(() => '(?,?,?,?,?,?)').join(',')}`)
      .run(...chunk.flat());
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_ticks').get().n, 8000);
  db.exec('ANALYZE');
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${LAST_BEAT_SQL}`).all().map((r) => r.detail);
  assert.ok(plan.some((d) => /idx_lane_ticks_box/.test(d)), plan.join(' | '));
  assert.ok(!plan.some((d) => /^SCAN lane_ticks$/.test(d)), plan.join(' | '));
  assert.doesNotMatch(LAST_BEAT_SQL, /FROM box_status/);
  const got = Object.fromEntries((await db.prepare(LAST_BEAT_SQL).all()).map((r) => [r.box, r.last_beat_at]));
  assert.equal(Object.keys(got).length, 50);
  assert.equal(got['box-0'], new RealDate(RealDate.UTC(2026, 9, 1) + 159 * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z'));
});
