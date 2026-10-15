// BH-6817: a lane run with rc != 0 answers `failed` (not `done`) on the report
// route and on the by-prefix read, with a reason: `command-missing` for rc
// 126/127, `exit-nonzero` for any other non-zero rc. The D1 row keeps status
// `done` + rc (the CHECK constraint of schema.d/0020 allows no `failed`).
// Driven through the REAL router (worker.fetch) over the schema.d database.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { failReason, runStatus } from '../src/lib/lane-run-status.js';

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
const report = (DB, id, body) => call(DB, 'POST', `/api/lane-runs/${id}/report`, body);
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);

// One row enqueued, claimed by m1 and reported with rc.
async function ranWith(DB, project, rc) {
  const e = await enqueue(DB, 'merge-conductor-pr', project);
  assert.equal(e.status, 201);
  const c = await claim(DB, 'm1');
  assert.equal(c.body.id, e.body.id);
  return { id: e.body.id, res: await report(DB, e.body.id, { machine: 'm1', rc, prof: 'PROF lane-run' }) };
}

test('BH-6817 lane run status: failed for rc != 0', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S0 the composed schema seeds the three BH-6817 settings rows', async () => {
    const { db } = await openDb();
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('lane_run.code_sync'), '1');
    assert.equal(val('lane_run.code_check_s'), '120');
    assert.equal(val('lane_run.command_missing_alert_s'), '3600');
  });

  await t.test('decision table: runStatus and failReason', () => {
    assert.equal(runStatus({ status: 'done', rc: 0 }), 'done');
    assert.equal(runStatus({ status: 'done', rc: 1 }), 'failed');
    assert.equal(runStatus({ status: 'done', rc: 127 }), 'failed');
    assert.equal(runStatus({ status: 'died', rc: 137 }), 'died');
    assert.equal(runStatus({ status: 'claimed', rc: null }), 'claimed');
    assert.equal(failReason(126), 'command-missing');
    assert.equal(failReason(127), 'command-missing');
    assert.equal(failReason(125), 'exit-nonzero');
    assert.equal(failReason(128), 'exit-nonzero');
    assert.equal(failReason(0), null);
    assert.equal(failReason(null), null);
  });

  await t.test('F1 report rc 3 answers failed/exit-nonzero; the D1 row is done rc 3', async () => {
    const { db, DB } = await openDb();
    const { id, res } = await ranWith(DB, 'demo-os.1.aaaaaaaaaaaa', 3);
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'failed');
    assert.equal(res.body.rc, 3);
    assert.equal(res.body.reason, 'exit-nonzero');
    assert.equal(row(db, id).status, 'done');
    assert.equal(row(db, id).rc, 3);
  });

  await t.test('F2 report rc 127 and rc 126 answer failed/command-missing', async () => {
    const { DB } = await openDb();
    for (const [n, rc] of [[1, 127], [2, 126]]) {
      const { res } = await ranWith(DB, `demo-os.${n}.aaaaaaaaaaaa`, rc);
      assert.equal(res.status, 200);
      assert.equal(res.body.status, 'failed', `rc ${rc}`);
      assert.equal(res.body.rc, rc);
      assert.equal(res.body.reason, 'command-missing', `rc ${rc}`);
    }
  });

  await t.test('F3 report rc 0 answers done with reason null', async () => {
    const { db, DB } = await openDb();
    const { id, res } = await ranWith(DB, 'demo-os.3.aaaaaaaaaaaa', 0);
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'done');
    assert.equal(res.body.reason, null);
    assert.equal(row(db, id).status, 'done');
  });

  await t.test('F4 a replay of rc 127 answers failed with replay:true', async () => {
    const { DB } = await openDb();
    const { id } = await ranWith(DB, 'demo-os.4.aaaaaaaaaaaa', 127);
    const again = await report(DB, id, { machine: 'm1', rc: 127 });
    assert.equal(again.status, 200);
    assert.equal(again.body.replay, true);
    assert.equal(again.body.status, 'failed');
    assert.equal(again.body.reason, 'command-missing');
  });

  await t.test('F5 by-prefix lists rc 127 as failed with its reason, rc 0 as done, a died row as died', async () => {
    const { db, DB } = await openDb();
    const a = await ranWith(DB, 'demo-os.5.aaaaaaaaaaaa', 127);
    const b = await ranWith(DB, 'demo-os.5.bbbbbbbbbbbb', 0);
    const d = await enqueue(DB, 'merge-conductor-pr', 'demo-os.5.cccccccccccc');
    // A died row is what sweepDead writes: status died, rc 137.
    db.prepare("UPDATE lane_runs SET status='died', rc=137, finished_at='2026-10-15T00:00:00Z' WHERE id=?").run(d.body.id);
    const r = await call(DB, 'GET', '/api/lane-runs/by-prefix?lane=merge-conductor-pr&project_prefix=demo-os.5.');
    assert.equal(r.status, 200);
    const by = Object.fromEntries(r.body.rows.map((x) => [x.id, x]));
    assert.equal(by[a.id].status, 'failed');
    assert.equal(by[a.id].reason, 'command-missing');
    assert.equal(by[a.id].rc, 127);
    assert.equal(by[b.id].status, 'done');
    assert.equal(by[b.id].reason, null);
    assert.equal(by[d.body.id].status, 'died');
    assert.equal(row(db, a.id).status, 'done', 'the D1 row stays done');
  });
});
