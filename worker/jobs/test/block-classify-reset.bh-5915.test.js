// BH-5915: POST /api/block-classify/reset {verdict_id}. The one-shot
// (bin/lesson-classify.sh --requeue-truncated) asks it to re-open a classify run
// that the lane parked because the lead report was cut at the worker's
// 4000-unit artifact cap. Driven through the REAL worker.fetch over the REAL
// jobs schema (the node:sqlite D1 shim), as block-findings.bh-5806.test.js is.
// Pinned here: the bearer gate, the input check, that ONLY a failed run whose
// error names the cap is reset, that a second call is a replay that writes
// nothing, and that the reset run is pending again and claimable.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const CAP_ERR = "the lead report (request r1) is truncated at the worker's 4000-unit artifact cap; the full report is only on box b at p; not classified from a partial report; no full copy on the hub (absent)";
const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const reset = (DB, body) => call(DB, '/api/block-classify/reset', { method: 'POST', body });

const NOW_MS = Date.now(); // determinism: ok one captured anchor; fixtures are one day off it and the pending window is 14 days
const ago = (days) => new Date(NOW_MS - days * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const addVerdict = (db, pr) => Number(db.prepare(
  `INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at)
   VALUES ('example-org/cromford', ?, ?, 'BLOCK', 'lead', 'mac-lead', ?, 'lead-review:r1 lead-job:j1', ?)`
).run(pr, 'a'.repeat(40), `https://github.com/example-org/cromford/pull/${pr}`, ago(1)).lastInsertRowid);
// A run row in the state the lane leaves it in.
const addRun = (db, vid, status, attempts, error) => db.prepare(
  `INSERT INTO block_classify_runs (verdict_id, repo, pr, head_sha, status, attempts, error, created_at, updated_at)
   VALUES (?, 'example-org/cromford', 1, ?, ?, ?, ?, ?, ?)`
).run(vid, 'a'.repeat(40), status, attempts, error, ago(1), ago(1));
const runOf = (db, vid) => db.prepare('SELECT * FROM block_classify_runs WHERE verdict_id = ?').get(vid);

test('BH-5915 block-classify reset', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 no bearer or a wrong bearer is 401', async () => {
    const { DB } = await openDb();
    for (const secret of [null, 'wrong']) {
      const r = await call(DB, '/api/block-classify/reset', { method: 'POST', secret, body: { verdict_id: 1 } });
      assert.equal(r.status, 401, `bearer ${secret}`);
    }
  });

  await t.test('R2 a bad verdict_id is 400; an unknown one is 404', async () => {
    const { DB } = await openDb();
    for (const body of [{ verdict_id: 0 }, { verdict_id: 'x' }, { verdict_id: 1.5 }, {}]) {
      const r = await reset(DB, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.body.error, 'verdict_id');
    }
    const r = await reset(DB, { verdict_id: 999 });
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'no run');
  });

  await t.test('R3 an ok or an empty run is refused (409 not_cap_parked), unchanged', async () => {
    const { db, DB } = await openDb();
    for (const status of ['ok', 'empty']) {
      const v = addVerdict(db, 300);
      addRun(db, v, status, 1, status === 'ok' ? null : 'no findings text');
      const before = runOf(db, v);
      const r = await reset(DB, { verdict_id: v });
      assert.equal(r.status, 409, status);
      assert.equal(r.body.error, 'not_cap_parked');
      assert.equal(r.body.run.status, status);
      assert.deepEqual(runOf(db, v), before);
    }
  });

  await t.test('R4 + R5 a failed run parked at the cap is reset once; the second call is a replay', async () => {
    const { db, DB } = await openDb();
    const v = addVerdict(db, 301);
    addRun(db, v, 'failed', 2, CAP_ERR);
    const r = await reset(DB, { verdict_id: v });
    assert.equal(r.status, 200);
    assert.equal(r.body.reset, true);
    const row = runOf(db, v);
    assert.equal(row.status, 'failed');
    assert.equal(Number(row.attempts), 0);
    assert.equal(row.error, `requeued: ${CAP_ERR}`);
    assert.equal(r.body.run.attempts, 0);
    const again = await reset(DB, { verdict_id: v });
    assert.equal(again.status, 200);
    assert.equal(again.body.replay, true);
    assert.equal(again.body.reset, undefined);
    assert.deepEqual(runOf(db, v), row, 'a replay writes nothing (updated_at the same)');
  });

  await t.test('R6 a run failed for another reason, or claimed, is refused', async () => {
    const { db, DB } = await openDb();
    const a = addVerdict(db, 302);
    addRun(db, a, 'failed', 0, 'job j9 has no lead_review_report artifact; nothing to classify');
    const ra = await reset(DB, { verdict_id: a });
    assert.equal(ra.status, 409);
    assert.equal(ra.body.error, 'not_cap_parked');
    // A claimed row with the phrase in a stale error (a hand edit) is still not
    // failed, so it is not the lane's park.
    const b = addVerdict(db, 303);
    addRun(db, b, 'claimed', 1, CAP_ERR);
    const rb = await reset(DB, { verdict_id: b });
    assert.equal(rb.status, 409);
    assert.equal(runOf(db, b).error, CAP_ERR);
  });

  await t.test('R7 a claim after the reset clears the error and counts attempt 1', async () => {
    const { db, DB } = await openDb();
    const v = addVerdict(db, 304);
    addRun(db, v, 'failed', 0, CAP_ERR);
    assert.equal((await reset(DB, { verdict_id: v })).status, 200);
    const c = await call(DB, '/api/block-classify/claim', { method: 'POST', body: { verdict_id: v } });
    assert.equal(c.status, 200);
    const row = runOf(db, v);
    assert.equal(row.status, 'claimed');
    assert.equal(row.error, null);
    assert.equal(Number(row.attempts), 1);
  });

  await t.test('R8 a cap-parked run at the attempt cap is absent from pending before the reset, present after', async () => {
    const { db, DB } = await openDb();
    const v = addVerdict(db, 305);
    addRun(db, v, 'failed', 3, CAP_ERR);
    const ids = async () => (await call(DB, '/api/block-classify/pending?limit=50')).body.verdicts.map((x) => x.verdict_id);
    assert.ok(!(await ids()).includes(v), 'at the cap: not pending');
    assert.equal((await reset(DB, { verdict_id: v })).status, 200);
    assert.ok((await ids()).includes(v), 'after the reset: pending');
  });
});
