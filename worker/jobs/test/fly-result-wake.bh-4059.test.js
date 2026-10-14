import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4059 (slice BH-4171): a finished Fly build rings the queue doorbell.
//
// PUT /api/jobs/:id/artifacts with artifact_kind=fly_result (written by
// fly/builder-runner.sh `fly_result_put`) writes one `queue` wake (repo
// 'harness/build-queue', key '<project>:<job id>', event 'fly_result.put').
// The wake is best effort: a failed wake insert must not change the PUT's
// status or body, and the artifact row must still be committed. Driven
// through `worker.fetch` (D2) over a node:sqlite database with schema.sql
// applied, so the assertions are on rows LEFT, not on statements issued.
//
// The harness is a copy of build-queue-wake.bh-4059's, not an import: that
// file belongs to the tracer slice (BH-4169).

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';

// `failWakes` makes every statement that writes the wakes table throw, the way
// a D1 hiccup would.
function d1(db, calls, opts) {
  const exec = (sql) => {
    const flat = sql.replace(/\s+/g, ' ').trim();
    calls.push(flat);
    if (opts.failWakes && /INTO wakes/i.test(flat)) throw new Error('D1_ERROR: wakes unavailable');
    return db.prepare(sql);
  };
  const shape = (sql, binds) => ({
    all: async () => ({ results: exec(sql).all(...binds) }),
    first: async () => exec(sql).get(...binds) ?? null,
    run: async () => {
      const r = exec(sql).run(...binds);
      return { meta: { changes: r.changes, last_row_id: Number(r.lastInsertRowid) } };
    },
  });
  return {
    prepare(sql) {
      return { bind: (...b) => shape(sql, b), ...shape(sql, []) };
    },
  };
}

async function fixture(t, opts = {}) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const now = '2026-10-04T00:00:00.000Z';
  db.prepare(
    `INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at)
     VALUES ('j-1', 'demo', 'build', 'fly-x', 'execute', 'running', ?1, ?1)`
  ).run(now);
  const calls = [];
  return { db, calls, DB: d1(db, calls, opts) };
}

const call = (fx, method, path, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const wakes = (fx) => fx.db.prepare(
  'SELECT repo, kind, key, event, minute, at, acked_at FROM wakes ORDER BY id ASC').all()
  .map((r) => ({ ...r }));
const artifacts = (fx) => fx.db.prepare(
  'SELECT job_id, artifact_kind, artifact_ref FROM job_artifacts ORDER BY job_id, artifact_kind').all()
  .map((r) => ({ ...r }));

const FLY_RESULT = { artifact_kind: 'fly_result', artifact_ref: 'PR_CREATED https://github.com/o/r/pull/1' };

// The body minus the values that legitimately differ between two runs.
const stable = (body) => {
  const a = { ...body.artifact };
  delete a.id; delete a.created_at; delete a.updated_at;
  return { ...body, artifact: a };
};

test('AT-W5a: a fly_result PUT writes exactly one queue wake for <project>:<job id>', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await call(fx, 'PUT', '/api/jobs/j-1/artifacts', FLY_RESULT);
  assert.equal(r.status, 200);
  assert.equal(r.body.artifact.artifact_kind, 'fly_result');
  assert.deepEqual(artifacts(fx), [{ job_id: 'j-1', artifact_kind: 'fly_result', artifact_ref: FLY_RESULT.artifact_ref }]);
  const w = wakes(fx);
  assert.equal(w.length, 1);
  assert.equal(w[0].repo, 'harness/build-queue');
  assert.equal(w[0].kind, 'queue');
  assert.equal(w[0].key, 'demo:j-1');
  assert.equal(w[0].event, 'fly_result.put');
  assert.equal(w[0].acked_at, null);
  assert.equal(w[0].minute, w[0].at.slice(0, 16) + ':00Z');
});

test('AT-W5b: a wake insert that throws still answers 200 with the same body and commits the artifact', async (t) => {
  const ok = await fixture(t);
  if (!ok) return;
  const good = await call(ok, 'PUT', '/api/jobs/j-1/artifacts', FLY_RESULT);
  const fx = await fixture(t, { failWakes: true });
  const errors = [];
  t.mock.method(console, 'error', (...a) => { errors.push(a.join(' ')); });
  const r = await call(fx, 'PUT', '/api/jobs/j-1/artifacts', FLY_RESULT);
  console.error.mock.restore();
  assert.equal(r.status, 200);
  assert.equal(good.status, 200);
  assert.deepEqual(stable(r.body), stable(good.body));
  assert.deepEqual(artifacts(fx), [{ job_id: 'j-1', artifact_kind: 'fly_result', artifact_ref: FLY_RESULT.artifact_ref }]);
  assert.equal(wakes(fx).length, 0);
  // The wake really was attempted and its failure was said out loud.
  assert.ok(fx.calls.some((s) => /INTO wakes/i.test(s)), 'the PUT must attempt the wake insert');
  assert.ok(errors.some((e) => /queue wake insert failed/.test(e)), 'the failed wake must be logged');
});

test('AT-W5c: two identical fly_result PUTs in the same minute leave one wake row', async (t) => {
  for (let attempt = 0; attempt < 3; attempt++) {
    const fx = await fixture(t);
    if (!fx) return;
    const first = await call(fx, 'PUT', '/api/jobs/j-1/artifacts', FLY_RESULT);
    const again = await call(fx, 'PUT', '/api/jobs/j-1/artifacts', FLY_RESULT);
    // Straddled a minute boundary: two buckets are two legitimate wakes.
    if (first.body.artifact.updated_at.slice(0, 16) !== again.body.artifact.updated_at.slice(0, 16)) continue;
    assert.equal(first.status, 200);
    assert.equal(again.status, 200);
    assert.equal(wakes(fx).length, 1);
    return;
  }
  assert.fail('three attempts straddled a minute boundary');
});

test('AT-W6a: a verdict PUT writes no wake and still appends its history', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await call(fx, 'PUT', '/api/jobs/j-1/artifacts', {
    artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: { reviewed_sha: 'a'.repeat(40) },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.history_appended, true);
  assert.equal(wakes(fx).length, 0);
});

test('AT-W6b: a PUT on an unknown job is 404 and writes no wake and no artifact', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await call(fx, 'PUT', '/api/jobs/j-missing/artifacts', FLY_RESULT);
  assert.equal(r.status, 404);
  assert.deepEqual(r.body, { error: 'no such job' });
  assert.equal(wakes(fx).length, 0);
  assert.equal(artifacts(fx).length, 0);
});
