// BH-6890: POST /api/lane-runs/:id/withdraw — the hub ends a stale queued
// merge-conductor row in the same step it takes the project back, so no
// machine claims it during the hub's tick. Driven through the REAL router
// (worker.fetch) over the composed jobs schema on the node:sqlite shim.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { WITHDRAW_SQL } from '../src/routes/lane-runs.js';

const SECRET = 'fixture-harness-secret';
const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const enqueue = (DB) => call(DB, 'POST', '/api/lane-runs', { lane: 'merge-conductor', project: 'p1', args: ['bin/x.sh'] });
const withdraw = (DB, id, body) => call(DB, 'POST', `/api/lane-runs/${id}/withdraw`, body);
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);

test('BH-6890 lane_runs withdraw', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 a queued row: 200, died, prof withdrawn by=<by> <why>, not claimable', async () => {
    const { db, DB } = await openDb();
    const a = await enqueue(DB);
    const r = await withdraw(DB, a.body.id, { by: 'hub-box', why: 'stale 700s' });
    assert.equal(r.status, 200);
    assert.equal(r.body.status, 'died');
    const x = row(db, a.body.id);
    assert.equal(x.status, 'died');
    assert.equal(x.prof_line, 'withdrawn by=hub-box stale700s');
    assert.ok(x.finished_at);
    const c = await call(DB, 'POST', '/api/lane-runs/claim', { machine: 'm1' });
    assert.equal(c.status, 204, 'nothing left to claim');
    const again = await enqueue(DB);
    assert.equal(again.status, 201, 'the live index is free again');
  });

  await t.test('W2 a claimed row: 409 not_queued, row untouched', async () => {
    const { db, DB } = await openDb();
    const a = await enqueue(DB);
    await call(DB, 'POST', '/api/lane-runs/claim', { machine: 'm1' });
    const r = await withdraw(DB, a.body.id, { by: 'hub-box' });
    assert.equal(r.status, 409);
    assert.equal(r.body.reason, 'not_queued');
    assert.equal(row(db, a.body.id).status, 'claimed');
  });

  await t.test('W3 no row is 404; a bad `by` is 400 and runs no statement', async () => {
    const { DB } = await openDb();
    assert.equal((await withdraw(DB, 999, { by: 'hub' })).status, 404);
    const a = await enqueue(DB);
    assert.equal((await withdraw(DB, a.body.id, { by: 'bad name!' })).status, 400);
    assert.equal((await withdraw(DB, a.body.id, {})).status, 400);
  });

  await t.test('W4 the statement uses the primary key', async () => {
    const { db } = await openDb();
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${WITHDRAW_SQL}`).all().map((r) => r.detail).join(' | ');
    assert.match(plan, /INTEGER PRIMARY KEY|USING (INTEGER )?PRIMARY KEY|rowid/i, plan);
    assert.doesNotMatch(plan, /^SCAN lane_runs$/m, plan);
  });
});
