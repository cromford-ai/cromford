// BH-6124 (1 of 5, split from BH-6047): the lane_runs queue contract. A lane
// placed `fly` is enqueued as a row, a machine claims it in ONE statement,
// runs it and reports its rc. Driven through the REAL router (worker.fetch)
// over a real schema.sql database on the node:sqlite shim. The shell side is
// tests/project-lanes-fly.bh-6124-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'fixture-harness-secret';
// The composition of worker/jobs/schema.d/ (BH-6005): schema.sql is a render.
const SCHEMA = jobsSchemaSql();
const ROUTE_SRC = readFileSync(fileURLToPath(new URL('../src/routes/lane-runs.js', import.meta.url)), 'utf8');

const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const enqueue = (DB, lane, project, args = ['bin/x.sh']) => call(DB, 'POST', '/api/lane-runs', { lane, project, args });
const claim = (DB, machine, lanes) => call(DB, 'POST', '/api/lane-runs/claim', lanes ? { machine, lanes } : { machine });
const report = (DB, id, body) => call(DB, 'POST', `/api/lane-runs/${id}/report`, body);
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);

test('BH-6124 lane_runs queue', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const fresh = async () => openDb();

  await t.test('S1 schema.sql has lane_runs, the live index and the three seeds, and applies twice', async () => {
    const { db } = await fresh();
    const cols = db.prepare('PRAGMA table_info(lane_runs)').all().map((c) => c.name);
    for (const c of ['id', 'lane', 'project', 'args_json', 'enqueued_at', 'claimed_at', 'claimed_by',
      'lease_until', 'heartbeat_at', 'attempts', 'status', 'rc', 'prof_line', 'finished_at']) {
      assert.ok(cols.includes(c), `lane_runs has ${c}`);
    }
    const idx = db.prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name='lane_runs_live'").get();
    assert.ok(idx && /UNIQUE/i.test(idx.sql) && /status IN \('queued','claimed'\)/.test(idx.sql), 'partial unique live index');
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('lane_placement.default'), 'hub');
    assert.equal(val('lane_run.lease_s'), '120');
    assert.equal(val('lane_run.poll_s'), '15');
    db.exec(SCHEMA);
  });

  await t.test('W1 a second live enqueue answers 409 already_live with the first id; after done, 201 again', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    assert.equal(a.status, 201);
    assert.ok(Number.isInteger(a.body.id));
    const b = await enqueue(DB, 'demo', 'p1');
    assert.equal(b.status, 409);
    assert.equal(b.body.error, 'already_live');
    assert.equal(b.body.id, a.body.id);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_runs').get().n, 1);
    const other = await enqueue(DB, 'demo', 'p2');
    assert.equal(other.status, 201, 'another project is not deduped');
    const c = await claim(DB, 'm1', ['demo']);
    assert.equal(c.body.id, a.body.id);
    const b2 = await enqueue(DB, 'demo', 'p1');
    assert.equal(b2.status, 409, 'a claimed row is still live');
    assert.equal((await report(DB, a.body.id, { machine: 'm1', rc: 0 })).status, 200);
    const d = await enqueue(DB, 'demo', 'p1');
    assert.equal(d.status, 201);
    assert.notEqual(d.body.id, a.body.id);
  });

  await t.test('W2 the claim takes the oldest queued row, then the other, then 204', async () => {
    const { db, DB } = await fresh();
    const first = await enqueue(DB, 'demo', 'p1');
    const second = await enqueue(DB, 'demo', 'p2');
    db.prepare("UPDATE lane_runs SET enqueued_at='2026-10-12T00:00:01Z' WHERE id=?").run(first.body.id);
    db.prepare("UPDATE lane_runs SET enqueued_at='2026-10-12T00:00:00Z' WHERE id=?").run(second.body.id);
    const c1 = await claim(DB, 'm1');
    assert.equal(c1.status, 200);
    assert.equal(c1.body.id, second.body.id, 'older enqueued_at first');
    assert.equal(c1.body.lane, 'demo');
    assert.equal(c1.body.project, 'p2');
    assert.equal(c1.body.attempts, 1);
    assert.match(c1.body.lease_until, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    const r = row(db, second.body.id);
    assert.equal(r.status, 'claimed');
    assert.equal(r.claimed_by, 'm1');
    const lease = (Date.parse(r.lease_until) - Date.parse(r.claimed_at)) / 1000;
    assert.equal(lease, 120, 'lease from the lane_run.lease_s seed');
    const c2 = await claim(DB, 'm2');
    assert.equal(c2.body.id, first.body.id);
    const c3 = await claim(DB, 'm3');
    assert.equal(c3.status, 204);
    // A lanes filter that names no queued lane gets nothing.
    await enqueue(DB, 'other', 'p1');
    assert.equal((await claim(DB, 'm3', ['demo'])).status, 204);
    assert.equal((await claim(DB, 'm3', ['other'])).status, 200);
  });

  await t.test('W2b lane_run.lease_s out of range uses the 120 s fallback; in range is used', async () => {
    const { db, DB } = await fresh();
    db.prepare("UPDATE settings SET value='5' WHERE key='lane_run.lease_s'").run();
    const a = await enqueue(DB, 'demo', 'p1');
    await claim(DB, 'm1');
    let r = row(db, a.body.id);
    assert.equal((Date.parse(r.lease_until) - Date.parse(r.claimed_at)) / 1000, 120);
    db.prepare("UPDATE settings SET value='300' WHERE key='lane_run.lease_s'").run();
    const b = await enqueue(DB, 'demo', 'p2');
    await claim(DB, 'm1');
    r = row(db, b.body.id);
    assert.equal((Date.parse(r.lease_until) - Date.parse(r.claimed_at)) / 1000, 300);
  });

  await t.test('W5 report: claimer only, same-rc replay, rc mismatch, missing rc, prof truncation', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    await claim(DB, 'm1');
    const notMine = await report(DB, a.body.id, { machine: 'm2', rc: 0 });
    assert.equal(notMine.status, 409);
    assert.equal(notMine.body.reason, 'not_claimer');
    assert.equal(row(db, a.body.id).status, 'claimed');
    for (const bad of [undefined, null, '', 'x', 1.5, -1, 256, true]) {
      const r = await report(DB, a.body.id, { machine: 'm1', rc: bad });
      assert.equal(r.status, 400, `rc ${JSON.stringify(bad)} is 400`);
    }
    assert.equal(row(db, a.body.id).status, 'claimed', 'a bad rc writes nothing');
    const prof = 'P'.repeat(600);
    const ok = await report(DB, a.body.id, { machine: 'm1', rc: 3, prof });
    assert.equal(ok.status, 200);
    const done = row(db, a.body.id);
    assert.equal(done.status, 'done');
    assert.equal(done.rc, 3);
    assert.equal(Buffer.byteLength(done.prof_line, 'utf8'), 512);
    assert.ok(done.finished_at);
    const replay = await report(DB, a.body.id, { machine: 'm1', rc: 3 });
    assert.equal(replay.status, 200);
    assert.equal(replay.body.replay, true);
    const mismatch = await report(DB, a.body.id, { machine: 'm1', rc: 0 });
    assert.equal(mismatch.status, 409);
    assert.equal(mismatch.body.reason, 'rc_mismatch');
    const otherDone = await report(DB, a.body.id, { machine: 'm2', rc: 3 });
    assert.equal(otherDone.status, 409);
    assert.equal(otherDone.body.reason, 'not_claimer');
    assert.equal((await report(DB, 99999, { machine: 'm1', rc: 0 })).status, 404);
    const q = await enqueue(DB, 'demo', 'p2');
    const notClaimed = await report(DB, q.body.id, { machine: 'm1', rc: 0 });
    assert.equal(notClaimed.status, 409);
    assert.equal(notClaimed.body.reason, 'not_claimed');
    // A multi-byte prof is cut on a character boundary, never inside one.
    await claim(DB, 'm1');
    await report(DB, q.body.id, { machine: 'm1', rc: 0, prof: 'ü'.repeat(300) });
    const cut = row(db, q.body.id).prof_line;
    assert.equal(cut, 'ü'.repeat(256));
  });

  await t.test('W6 args round-trip through enqueue and claim unchanged', async () => {
    const { DB } = await fresh();
    const args = ['bin/x.sh', '--x', 'a b', 'ü\n'];
    await enqueue(DB, 'demo', 'p1', args);
    const c = await claim(DB, 'm1');
    assert.deepEqual(c.body.args, args);
  });

  await t.test('W7 bad args, lane, project or machine answer 400 and write nothing', async () => {
    const { db, DB } = await fresh();
    const bads = [
      ['/bin/sh'], ['bin/../x'], ['../bin/x'], ['sh'], ['bin/a/../../x'], [],
      ['bin/x.sh', 7], Array.from({ length: 65 }, () => 'bin/x.sh'), 'bin/x.sh', ['bin/x.sh', 'y'.repeat(4097)],
    ];
    for (const args of bads) {
      const r = await call(DB, 'POST', '/api/lane-runs', { lane: 'demo', project: 'p1', args });
      assert.equal(r.status, 400, `args ${JSON.stringify(args).slice(0, 60)} is 400`);
    }
    assert.equal((await enqueue(DB, 'de mo', 'p1')).status, 400);
    assert.equal((await enqueue(DB, 'demo', '../p1')).status, 400);
    assert.equal((await enqueue(DB, 'demo', '')).status, 400);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_runs').get().n, 0);
    assert.equal((await claim(DB, 'm 1')).status, 400);
    assert.equal((await claim(DB, 'm1', ['ok', 'b ad'])).status, 400);
    assert.equal((await report(DB, 1, { machine: '', rc: 0 })).status, 400);
    // 64 args is inside the limit.
    assert.equal((await enqueue(DB, 'demo', 'p1', Array.from({ length: 64 }, () => 'bin/x.sh'))).status, 201);
  });

  await t.test('W8 an expired lease is re-claimed with attempts 2; the old claimer is then not the claimer', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    await claim(DB, 'm1');
    assert.equal((await claim(DB, 'm2')).status, 204, 'a live lease is not re-claimed');
    db.prepare("UPDATE lane_runs SET lease_until='2000-01-01T00:00:00Z' WHERE id=?").run(a.body.id);
    const c = await claim(DB, 'm2');
    assert.equal(c.status, 200);
    assert.equal(c.body.id, a.body.id);
    assert.equal(c.body.attempts, 2);
    assert.equal(row(db, a.body.id).claimed_by, 'm2');
    const late = await report(DB, a.body.id, { machine: 'm1', rc: 0 });
    assert.equal(late.status, 409);
    assert.equal(late.body.reason, 'not_claimer');
  });

  await t.test('W9 the claim awaits sweepDead from the lease seam, and a claim succeeds through it', async () => {
    assert.match(ROUTE_SRC, /import\s*\{[^}]*\bsweepDead\b[^}]*\}\s*from\s*["']\.\/lane-runs-lease\.js["']/);
    assert.match(ROUTE_SRC, /await sweepDead\(env, t\)/);
    const { sweepDead } = await import('../src/routes/lane-runs-lease.js');
    const { DB } = await fresh();
    assert.equal(await sweepDead({ DB }, '2026-10-12T00:00:00Z'), 0, 'nothing to sweep in an empty queue');
    await enqueue(DB, 'demo', 'p1');
    assert.equal((await claim(DB, 'm1')).status, 200);
  });

  await t.test('W10 stats per lane: counts by status, oldest queued wait, live claimers', async () => {
    const { db, DB } = await fresh();
    let s = await call(DB, 'GET', '/api/lane-runs/stats?lane=demo');
    assert.equal(s.status, 200);
    assert.deepEqual(s.body.lanes, []);
    const a = await enqueue(DB, 'demo', 'p1');
    await enqueue(DB, 'demo', 'p2');
    await enqueue(DB, 'demo', 'p3');
    await enqueue(DB, 'other', 'p1');
    await claim(DB, 'm1', ['demo']);
    await report(DB, a.body.id, { machine: 'm1', rc: 0 });
    await claim(DB, 'm2', ['demo']);
    db.prepare("UPDATE lane_runs SET enqueued_at='2000-01-01T00:00:00Z' WHERE status='queued' AND lane='demo'").run();
    s = await call(DB, 'GET', '/api/lane-runs/stats?lane=demo');
    assert.equal(s.body.lanes.length, 1);
    const d = s.body.lanes[0];
    assert.equal(d.lane, 'demo');
    assert.equal(d.queued, 1);
    assert.equal(d.claimed, 1);
    assert.equal(d.done, 1);
    assert.equal(d.died, 0);
    assert.equal(d.live_claimers, 1);
    assert.equal(typeof d.oldest_queued_wait_s, 'number');
    assert.ok(d.oldest_queued_wait_s > 800000000, 'wait measured from enqueued_at');
    const all = await call(DB, 'GET', '/api/lane-runs/stats');
    assert.deepEqual(all.body.lanes.map((l) => l.lane), ['demo', 'other']);
    await claim(DB, 'm3', ['demo']);
    s = await call(DB, 'GET', '/api/lane-runs/stats?lane=demo');
    assert.equal(s.body.lanes[0].oldest_queued_wait_s, null, 'no queued row is null, not 0');
    assert.equal((await call(DB, 'GET', '/api/lane-runs/stats?lane=b%20ad')).status, 400);
  });

  await t.test('W11 a database without lane_runs answers 503 schema not applied', async () => {
    const { db, DB } = await fresh();
    db.exec('DROP TABLE lane_runs');
    const r = await enqueue(DB, 'demo', 'p1');
    assert.equal(r.status, 503);
    assert.match(r.body.error, /lane_runs schema not applied/);
  });
});
