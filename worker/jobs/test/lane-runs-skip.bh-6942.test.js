// BH-6942: POST /api/lane-runs/claim takes an optional `skip_prefixes` array.
// A machine that cannot read a repo sends `<project>.` for it, and the claim
// leaves every row whose project starts with one of them `queued` with its
// attempts unchanged, so the hub takes it back (bin/lib/mc/fly-workers.sh,
// no-capacity). Driven through the REAL router (worker.fetch) over the
// composed jobs schema on the node:sqlite shim. The shell side is
// tests/lane-run-head-read.bh-6942-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CLAIM_SQL, REFUSED_SQL } from '../src/routes/lane-runs.js';

const SECRET = 'fixture-harness-secret';

const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const enqueue = (DB, lane, project) => call(DB, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] });
const claim = (DB, extra = {}) => call(DB, 'POST', '/api/lane-runs/claim', { machine: 'm1', ...extra });
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);
const at = (db, id, ts) => db.prepare('UPDATE lane_runs SET enqueued_at=? WHERE id=?').run(ts, id);
// The route stamps rows with the real clock, so two fixed anchors stand for
// "waited far past lane_run.refused_max_wait_s" (OLD, a 2026-01-01 stamp) and
// "has not waited at all" (FRESH, a 2099 stamp, as S8 does); no test reads the clock.
const OLD = '2026-01-01T00:00:00Z';
const FRESH = '2099-01-01T00:00:00Z';
const FRESH1 = '2099-01-01T00:00:01Z';
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','2026-10-16T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
).run(key, value);
const live = (db, prefix) => db.prepare("SELECT COUNT(*) AS n FROM lane_runs WHERE status IN ('queued','claimed') AND substr(project,1,?)=?")
  .get(prefix.length, prefix).n;
const snapshot = (db) => JSON.stringify(db.prepare('SELECT * FROM lane_runs ORDER BY id').all());

test('BH-6942 claim skip_prefixes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S1 a skipped prefix answers 204 and the row stays queued with attempts 0', async () => {
    const { db, DB } = await openDb();
    const a = await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc');
    const c = await claim(DB, { skip_prefixes: ['px.'] });
    assert.equal(c.status, 204);
    const r = row(db, a.body.id);
    assert.equal(r.status, 'queued');
    assert.equal(r.attempts, 0);
    assert.equal(r.claimed_by, null);
  });

  await t.test('S2 the older row is skipped, the newer one is claimed', async () => {
    const { db, DB } = await openDb();
    const old = await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc');
    const nu = await enqueue(DB, 'merge-conductor-pr', 'py.2.aaaabbbbcccc');
    // Not yet waited (FRESH): the refused row only waits (S9 ends an older one).
    at(db, old.body.id, FRESH);
    at(db, nu.body.id, FRESH1);
    const c = await claim(DB, { skip_prefixes: ['px.'] });
    assert.equal(c.status, 200);
    assert.equal(c.body.id, nu.body.id);
    assert.equal(row(db, old.body.id).status, 'queued');
    assert.equal(row(db, old.body.id).attempts, 0);
  });

  await t.test('S3 no field claims the oldest row (today)', async () => {
    const { db, DB } = await openDb();
    const old = await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc');
    const nu = await enqueue(DB, 'merge-conductor-pr', 'py.2.aaaabbbbcccc');
    at(db, old.body.id, '2026-10-15T00:00:00Z');
    at(db, nu.body.id, '2026-10-15T00:00:01Z');
    const c = await claim(DB);
    assert.equal(c.status, 200);
    assert.equal(c.body.id, old.body.id);
    const n = await claim(DB, { skip_prefixes: null });
    assert.equal(n.body.id, nu.body.id, 'null is the same as absent');
  });

  await t.test('S4 an empty array claims the oldest row', async () => {
    const { db, DB } = await openDb();
    const old = await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc');
    const nu = await enqueue(DB, 'merge-conductor-pr', 'py.2.aaaabbbbcccc');
    at(db, old.body.id, '2026-10-15T00:00:00Z');
    at(db, nu.body.id, '2026-10-15T00:00:01Z');
    const c = await claim(DB, { skip_prefixes: [] });
    assert.equal(c.status, 200);
    assert.equal(c.body.id, old.body.id);
  });

  await t.test('S5 a bad skip_prefixes answers 400 and changes no row', async () => {
    const { db, DB } = await openDb();
    await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc');
    const before = snapshot(db);
    const bad = [
      'x',
      Array.from({ length: 65 }, (_, i) => `p${i}.`),
      [''],
      ['a/b'],
      [7],
      ['a'.repeat(66)],
      { p: 'px.' },
    ];
    for (const v of bad) {
      const c = await claim(DB, { skip_prefixes: v });
      assert.equal(c.status, 400, `400 for ${JSON.stringify(v).slice(0, 40)}`);
      assert.match(c.body.error, /skip_prefixes/);
    }
    assert.equal(snapshot(db), before, 'no row changed');
    const ok64 = await claim(DB, { skip_prefixes: Array.from({ length: 64 }, (_, i) => `p${i}.`) });
    assert.equal(ok64.status, 200, '64 entries is the cap, not over it');
  });

  await t.test('S6 a prefix matches by bytes: project-6. skips none of project-6-os, plain or longer names', async () => {
    const { db, DB } = await openDb();
    const ids = {};
    for (const p of ['project-6-os.5.abc', 'project-6', 'project-6x.1.abc', 'px_1.abc']) {
      ids[p] = (await enqueue(DB, 'merge-conductor-pr', p)).body.id;
    }
    const got = [];
    for (;;) {
      const c = await claim(DB, { skip_prefixes: ['project-6.', 'px.'] });
      if (c.status === 204) break;
      got.push(c.body.project);
    }
    assert.deepEqual(got.sort(), ['project-6', 'project-6-os.5.abc', 'project-6x.1.abc', 'px_1.abc'].sort());
    const s = await enqueue(DB, 'merge-conductor-pr', 'project-6.9.abc');
    assert.equal((await claim(DB, { skip_prefixes: ['project-6.'] })).status, 204);
    assert.equal(row(db, s.body.id).status, 'queued');
  });

  await t.test('S7 EXPLAIN QUERY PLAN on 20 000 rows (the exported CLAIM_SQL): the skip keeps the claim index, no SCAN lane_runs', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, rc, finished_at)
                            VALUES (?,?,?,?,?,?,?,?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const queued = i >= 19800;
      ins.run('merge-conductor-pr', `p${i % 13}.${i}.aaaabbbbcccc`, '["bin/x.sh"]', ts,
        queued ? 'queued' : 'done', queued ? 0 : 1, queued ? null : 0, queued ? null : ts);
    }
    db.exec('COMMIT');
    const sql = CLAIM_SQL;
    const plan = (skip) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`)
      .all('m1', '2026-10-15T00:00:00Z', '2026-10-15T00:02:00Z', null, null, null, skip).map((r) => r.detail);
    const withSkip = plan('["p3.","p4."]');
    const without = plan(null);
    const lr = (lines) => lines.filter((l) => /\blane_runs\b/.test(l));
    assert.deepEqual(lr(withSkip), lr(without), 'the same lane_runs access path with and without the skip');
    assert.ok(!withSkip.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l)), `no full SCAN lane_runs: ${withSkip.join(' | ')}`);
    assert.ok(withSkip.some((l) => /lane_runs USING (COVERING )?INDEX/.test(l)), `an index serves lane_runs: ${withSkip.join(' | ')}`);
    // The real statement, once, through the route's own bind order: a skipped p3/p4 row is never the answer.
    const r = db.prepare(sql).get('m1', '2026-10-15T00:00:00Z', '2026-10-15T00:02:00Z', null, null, null, '["p3.","p4."]');
    assert.ok(r && !/^p[34]\./.test(r.project), `claimed ${r && r.project}`);
  });

  await t.test('S8 prefer and skip_prefixes together (BH-6885 merge): a preferred project that is skipped is still not claimed', async () => {
    const { db, DB } = await openDb();
    const a = await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc');
    const b = await enqueue(DB, 'merge-conductor-pr', 'py.2.aaaabbbbcccc');
    // Past any prefer cutoff, so the preference is in force for both rows.
    const now = '2099-01-01T00:00:00Z';
    at(db, a.body.id, now);
    at(db, b.body.id, now);
    const c = await claim(DB, { prefer: ['px.1.aaaabbbbcccc'], skip_prefixes: ['px.'] });
    assert.equal(c.status, 200);
    assert.equal(c.body.id, b.body.id, 'the skip wins over the preference');
    assert.equal(row(db, a.body.id).status, 'queued');
    assert.equal(row(db, a.body.id).attempts, 0);
    assert.equal((await claim(DB, { prefer: ['px.1.aaaabbbbcccc'], skip_prefixes: ['px.'] })).status, 204);
  });
  await t.test('S9 lead review of #6960: 3 heads of a refused PR leave at most 1 live row; each old row ends died, withdrawn', async () => {
    const { db, DB } = await openDb();
    const heads = ['px.8.aaaa1111bbbb', 'px.8.cccc2222dddd', 'px.8.eeee3333ffff'];
    const ids = [];
    for (const [i, h] of heads.entries()) {
      const e = await enqueue(DB, 'merge-conductor-pr', h);
      assert.equal(e.status, 201, `head ${i} enqueued`);
      ids.push(e.body.id);
      // The hub enqueues the next head only past MC_FLY_QUEUE_STALE_S (600 s):
      // the row waited that long, and every machine refuses it.
      at(db, e.body.id, OLD);
      assert.equal((await claim(DB, { skip_prefixes: ['px.'] })).status, 204);
      assert.ok(live(db, 'px.8.') <= 1, `head ${i}: at most 1 live row of the PR, got ${live(db, 'px.8.')}`);
      const r = row(db, e.body.id);
      assert.equal(r.status, 'died', `head ${i} row ended`);
      assert.equal(r.attempts, 0, 'never claimed');
      assert.equal(r.claimed_by, null);
      assert.equal(r.rc, null);
      assert.match(r.prof_line, /^withdrawn refused-at-claim machine=m1 waited>=600s$/);
      assert.ok(r.finished_at, 'finished_at is set');
    }
    assert.equal(live(db, 'px.8.'), 0);
    const st = await call(DB, 'GET', '/api/lane-runs/stats?lane=merge-conductor-pr');
    assert.equal(st.body.lanes[0].queued, 0, 'no queued row is left to hold the fleet up');
    assert.equal(st.body.lanes[0].oldest_queued_wait_s, null);
  });

  await t.test('S10 only rows this claim refuses, past the wait, end; 0 turns it off; no skip ends nothing', async () => {
    const { db, DB } = await openDb();
    const fresh = (await enqueue(DB, 'merge-conductor-pr', 'px.1.aaaabbbbcccc')).body.id;
    const other = (await enqueue(DB, 'merge-conductor-pr', 'pz.2.aaaabbbbcccc')).body.id;
    const otherLane = (await enqueue(DB, 'other-lane', 'px.3.aaaabbbbcccc')).body.id;
    const plain = (await enqueue(DB, 'merge-conductor-pr', 'px')).body.id;
    at(db, fresh, FRESH);
    for (const id of [other, otherLane, plain]) at(db, id, OLD);
    // skip px. with lanes [merge-conductor-pr]: pz. is not refused, the
    // other lane is outside the claim's lanes, plain `px` has no dot, and the
    // px.1 row has not waited (FRESH).
    const c = await claim(DB, { skip_prefixes: ['px.'], lanes: ['merge-conductor-pr'] });
    assert.equal(c.status, 200);
    assert.ok([other, plain].includes(c.body.id), 'a row that is not refused is claimed');
    for (const id of [fresh, otherLane]) assert.equal(row(db, id).status, 'queued', `row ${id} still queued`);
    // 0 = never: an old refused row stays queued.
    setting(db, 'lane_run.refused_max_wait_s', '0');
    at(db, fresh, OLD);
    await claim(DB, { skip_prefixes: ['px.'], lanes: ['merge-conductor-pr'] });
    assert.equal(row(db, fresh).status, 'queued', '0 never ends a row');
    // A bad value falls back to 600: the 5000 s row ends.
    setting(db, 'lane_run.refused_max_wait_s', 'soon');
    await claim(DB, { skip_prefixes: ['px.'], lanes: ['merge-conductor-pr'] });
    assert.equal(row(db, fresh).status, 'died');
    assert.equal(row(db, otherLane).status, 'queued', 'a lane outside the claim filter never ends');
    // A claim with no skip never ends a refused row, however old.
    const { db: db2, DB: DB2 } = await openDb();
    const old = (await enqueue(DB2, 'merge-conductor-pr', 'px.9.aaaabbbbcccc')).body.id;
    at(db2, old, OLD);
    const c2 = await claim(DB2);
    assert.equal(c2.body.id, old, 'no skip: the old row is claimed as today');
  });

  await t.test('S11 EXPLAIN QUERY PLAN on 20 000 rows (the exported REFUSED_SQL): the claim index serves it, no SCAN lane_runs', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, rc, finished_at)
                            VALUES (?,?,?,?,?,?,?,?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const queued = i >= 19800;
      ins.run('merge-conductor-pr', `p${i % 13}.${i}.aaaabbbbcccc`, '["bin/x.sh"]', ts,
        queued ? 'queued' : 'done', queued ? 0 : 1, queued ? null : 0, queued ? null : ts);
    }
    db.exec('COMMIT');
    const args = ['2026-10-15T00:00:00Z', '2026-10-14T23:50:00Z', null, '["p3.","p4."]', 'withdrawn refused-at-claim machine=m1 waited>=600s'];
    const lines = db.prepare(`EXPLAIN QUERY PLAN ${REFUSED_SQL}`).all(...args).map((r) => r.detail);
    assert.ok(!lines.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l)), `no full SCAN lane_runs: ${lines.join(' | ')}`);
    assert.ok(lines.some((l) => /lane_runs USING (COVERING )?INDEX idx_lane_runs_claim/.test(l)), `the claim index serves it: ${lines.join(' | ')}`);
    const r = db.prepare(REFUSED_SQL).run(...args);
    const ended = db.prepare("SELECT project FROM lane_runs WHERE status='died'").all().map((x) => x.project);
    assert.equal(Number(r.changes), ended.length);
    assert.ok(ended.length > 0 && ended.length <= 100, `ended ${ended.length}, at most 100 per claim`);
    assert.ok(ended.every((p) => /^p[34]\./.test(p)), 'only refused prefixes end');
  });
});
