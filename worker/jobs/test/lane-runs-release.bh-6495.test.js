// BH-6495 (BH-6047.5): the two lane_runs routes the merge-conductor-pr lane
// needs. POST /api/lane-runs/:id/release hands a claimed row back to the
// queue (a machine that got SIGTERM mid-run); GET /api/lane-runs/by-prefix lists the
// rows of one lane whose project starts with a prefix (the hub's per-PR
// dedupe read). Driven through the REAL router (worker.fetch) over the
// composed jobs schema on the node:sqlite shim. The shell side is
// tests/lane-run-release.bh-6495-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

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
const claim = (DB, machine) => call(DB, 'POST', '/api/lane-runs/claim', { machine });
const release = (DB, id, machine) => call(DB, 'POST', `/api/lane-runs/${id}/release`, { machine });
const list = (DB, qs) => call(DB, 'GET', `/api/lane-runs/by-prefix?${qs}`);
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);

test('BH-6495 lane_runs release and prefix read', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const fresh = async () => openDb();

  await t.test('R1 release by the claimer: 200 queued, claim fields cleared, attempts kept, re-claimable', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'merge-conductor-pr', 'p.1.aaaaaaaaaaaa');
    const c = await claim(DB, 'm1');
    assert.equal(c.body.id, a.body.id);
    const r = await release(DB, a.body.id, 'm1');
    assert.equal(r.status, 200);
    assert.equal(r.body.status, 'queued');
    assert.equal(r.body.attempts, 1);
    const x = row(db, a.body.id);
    assert.equal(x.status, 'queued');
    assert.equal(x.claimed_by, null);
    assert.equal(x.claimed_at, null);
    assert.equal(x.lease_until, null);
    assert.equal(x.attempts, 1, 'attempts stays, so lane_run.max_attempts still ends a crash loop');
    const c2 = await claim(DB, 'm2');
    assert.equal(c2.body.id, a.body.id, 'another machine claims the released row');
    assert.equal(c2.body.attempts, 2);
  });

  await t.test('R2 release by another machine: 409 not_claimer, row untouched', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'merge-conductor-pr', 'p.1.aaaaaaaaaaaa');
    await claim(DB, 'm1');
    const r = await release(DB, a.body.id, 'm2');
    assert.equal(r.status, 409);
    assert.equal(r.body.reason, 'not_claimer');
    assert.equal(row(db, a.body.id).status, 'claimed');
    assert.equal(row(db, a.body.id).claimed_by, 'm1');
  });

  await t.test('R3 release of a done or queued row: 409 not_claimed; no row: 404; bad machine: 400', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'merge-conductor-pr', 'p.1.aaaaaaaaaaaa');
    const q = await release(DB, a.body.id, 'm1');
    assert.equal(q.status, 409);
    assert.equal(q.body.reason, 'not_claimed');
    await claim(DB, 'm1');
    await call(DB, 'POST', `/api/lane-runs/${a.body.id}/report`, { machine: 'm1', rc: 0 });
    const d = await release(DB, a.body.id, 'm1');
    assert.equal(d.status, 409);
    assert.equal(d.body.reason, 'not_claimed');
    assert.equal(row(db, a.body.id).status, 'done', 'a done row never goes back to the queue');
    assert.equal((await release(DB, 999, 'm1')).status, 404);
    assert.equal((await release(DB, a.body.id, 'bad name')).status, 400);
  });

  await t.test('P1 the prefix read: one lane, the prefix only, newest first, live=1 keeps queued and claimed', async () => {
    const { db, DB } = await fresh();
    const done = await enqueue(DB, 'merge-conductor-pr', 'p.12.aaaaaaaaaaaa');
    await claim(DB, 'm1');
    await call(DB, 'POST', `/api/lane-runs/${done.body.id}/report`,
      { machine: 'm1', rc: 0, prof: 'PROF mc-pr state=WAIT_CI reason=ci deferred=rebase' });
    const live = await enqueue(DB, 'merge-conductor-pr', 'p.12.bbbbbbbbbbbb');
    await enqueue(DB, 'merge-conductor-pr', 'p.123.cccccccccccc');
    await enqueue(DB, 'merge-conductor-pr', 'q.12.aaaaaaaaaaaa');
    await enqueue(DB, 'demo', 'p.12.aaaaaaaaaaaa');
    const all = await list(DB, 'lane=merge-conductor-pr&project_prefix=p.12.');
    assert.equal(all.status, 200);
    assert.deepEqual(all.body.rows.map((r) => r.id), [live.body.id, done.body.id], 'newest first, prefix and lane only');
    assert.equal(all.body.truncated, false);
    assert.equal(all.body.rows[1].prof_line, 'PROF mc-pr state=WAIT_CI reason=ci deferred=rebase');
    assert.equal(all.body.rows[1].status, 'done');
    const lv = await list(DB, 'lane=merge-conductor-pr&project_prefix=p.12.&live=1');
    assert.deepEqual(lv.body.rows.map((r) => r.project), ['p.12.bbbbbbbbbbbb']);
    assert.equal(row(db, live.body.id).status, 'queued');
  });

  await t.test('P2 an underscore in the prefix is a character, not a LIKE wildcard', async () => {
    const { DB } = await fresh();
    await enqueue(DB, 'merge-conductor-pr', 'aXb.1.aaaaaaaaaaaa');
    const r = await list(DB, 'lane=merge-conductor-pr&project_prefix=a_b.');
    assert.equal(r.status, 200);
    assert.equal(r.body.rows.length, 0);
  });

  await t.test('P3 more rows than the limit set truncated, never a silent cut', async () => {
    const { db, DB } = await fresh();
    const ins = db.prepare("INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, rc) VALUES ('merge-conductor-pr', ?, '[\"bin/x.sh\"]', '2026-10-14T00:00:00Z', 'done', 0)");
    for (let i = 0; i < 51; i += 1) ins.run('p.7.aaaaaaaaaaaa');
    const r = await list(DB, 'lane=merge-conductor-pr&project_prefix=p.7.');
    assert.equal(r.body.rows.length, 50);
    assert.equal(r.body.truncated, true);
    const s = await list(DB, 'lane=merge-conductor-pr&project_prefix=p.7.&limit=3');
    assert.equal(s.body.rows.length, 3);
    assert.equal(s.body.truncated, true);
    const e = await list(DB, 'lane=merge-conductor-pr&project_prefix=p.8.');
    assert.equal(e.body.rows.length, 0);
    assert.equal(e.body.truncated, false);
  });

  await t.test('P4 bad input is a 400: no lane, no prefix, bad names, live other than 1, limit out of range', async () => {
    const { DB } = await fresh();
    for (const qs of ['project_prefix=p.1.', 'lane=merge-conductor-pr', 'lane=bad%20lane&project_prefix=p.',
      'lane=merge-conductor-pr&project_prefix=p/1', 'lane=merge-conductor-pr&project_prefix=p.&live=yes',
      'lane=merge-conductor-pr&project_prefix=p.&limit=0', 'lane=merge-conductor-pr&project_prefix=p.&limit=51',
      'lane=merge-conductor-pr&project_prefix=p.&limit=x']) {
      assert.equal((await list(DB, qs)).status, 400, qs);
    }
  });
});
