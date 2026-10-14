import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1951 — GET /api/lead-reviews?promoted=0: the hub's promotion lane
// (bin/lead-review-land.sh) asks for unpromoted rows only, so a list capped at
// 100 oldest-first can never be filled by requests it already promoted.
// Driven through worker.fetch against THE SQL THAT SHIPS (worker/jobs/schema.sql),
// the lead-reviews.bh-1949 idiom.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}
const fresh = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db) }; };
const call = (DB, path, { method = 'GET', body, lead = false } = {}) => {
  const req = new Request(`https://jobs.test/api/lead-reviews${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      ...(lead ? { 'x-lead-verdict-token': LEAD } : {}),
      'content-type': 'application/json',
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

// Two done rows through the real routes; the first one is promoted.
async function twoDone(DB) {
  const ids = [];
  for (const [pr, h] of [[1, 'a'], [2, 'b']]) {
    const c = await call(DB, '', { method: 'POST', lead: true, body: { repo: 'example-org/demo-os', pr, head_sha: h.repeat(40) } });
    assert.equal(c.status, 201, JSON.stringify(c.body));
    const id = c.body.request.id;
    assert.equal((await call(DB, `/${id}/claim`, { method: 'POST', body: { job_id: `job-${pr}`, box: 'box-1' } })).status, 200);
    const r = await call(DB, `/${id}/result`, { method: 'POST', body: { job_id: `job-${pr}`, head_sha: h.repeat(40), outcome: 'done', verdict: 'BLOCK' } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    ids.push(id);
  }
  assert.equal((await call(DB, `/${ids[0]}/promoted`, { method: 'POST', lead: true })).status, 200);
  return ids;
}

test('1. ?status=done&promoted=0 excludes a stamped row and includes an unstamped one', async () => {
  const { DB } = fresh();
  const [stamped, open] = await twoDone(DB);
  const res = await call(DB, '?status=done&promoted=0');
  assert.equal(res.status, 200);
  const ids = res.body.requests.map((r) => r.id);
  assert.deepEqual(ids, [open]);
  assert.ok(!ids.includes(stamped));
  assert.equal(res.body.truncated, false);
});

test('2. promoted outside {0, absent} is a 400, never ignored', async () => {
  const { DB } = fresh();
  for (const v of ['2', '1', '', 'no']) {
    const res = await call(DB, `?status=done&promoted=${v}`);
    assert.equal(res.status, 400, `promoted=${v}`);
    assert.match(res.body.error, /promoted/);
  }
});

test('3. no promoted param returns both rows (the filter is additive)', async () => {
  const { DB } = fresh();
  const ids = await twoDone(DB);
  const res = await call(DB, '?status=done');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.requests.map((r) => r.id), ids);
});

test('4. the cap counts unpromoted rows only: 101 promoted rows do not hide the next one', async () => {
  const { db, DB } = fresh();
  const [, open] = await twoDone(DB);
  const ins = db.prepare("INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, verdict, created_at, updated_at, promoted_verdict_at) VALUES (?, 'example-org/demo-os', ?, ?, 'done', 'MERGE', '2000-01-01T00:00:00Z', '2000-01-01T00:00:00Z', '2000-01-02T00:00:00Z')");
  for (let i = 0; i < 101; i++) ins.run(`old-${i}`, 1000 + i, i.toString(16).padStart(40, 'c'));
  const all = await call(DB, '?status=done');
  assert.equal(all.body.truncated, true);
  assert.ok(!all.body.requests.some((r) => r.id === open), 'control: without the filter the unpromoted row is past the cap');
  const res = await call(DB, '?status=done&promoted=0');
  assert.deepEqual(res.body.requests.map((r) => r.id), [open]);
  assert.equal(res.body.truncated, false);
});
