import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { laneCandidates } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1948 (BH-1525.0) — the lead review contract: the lead_review_requests
// table, the lead.review model route and the lead-review retry policy. Driven
// against THE SQL THAT SHIPS, the model-routes-seed.bh-1510-2 idiom.
const SCHEMA = jobsSchemaSql();
const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const routes = (db) => db.prepare(
  "SELECT model, runner, position, project, updated_by FROM model_routes WHERE role='lead.review' ORDER BY position").all()
  .map((r) => ({ ...r }));
const SHA_A = 'a'.repeat(40);
const SHA_B = 'b'.repeat(40);
const insertReq = (db, id, sha, extra = {}) => db.prepare(
  'INSERT INTO lead_review_requests (id, repo, pr, head_sha, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
  .run(id, extra.repo ?? 'example-org/demo-os', extra.pr ?? 41, sha, '2026-09-24T00:00:00Z', '2026-09-24T00:00:00Z');

test('lead.review is seeded at hub scope, rank 0, claude-opus-5-5 on the claude runner', () => {
  assert.deepEqual(routes(openDb()),
    [{ model: 'claude-opus-5-5', runner: 'claude', position: 0, project: null, updated_by: 'seed' }]);
});

test('re-applying the schema (every deploy) leaves one lead.review row', () => {
  const db = openDb();
  db.exec(SCHEMA);
  assert.equal(routes(db).length, 1);
});

// Position 1 as well as 0: INSERT OR IGNORE alone already spares a row at the
// seed's own position, so only an operator ladder elsewhere proves the
// WHERE NOT EXISTS role guard.
for (const position of [0, 1]) {
  test(`an operator rung already on lead.review (position ${position}) is never joined or overwritten by the seed`, () => {
    const db = openDb();
    db.exec("DELETE FROM model_routes WHERE role='lead.review'");
    db.prepare("INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) VALUES ('hub', NULL, 'lead.review', ?, 'claude-fable-5-1', 'claude', 'op', '2026-09-24T01:00:00Z')").run(position);
    db.exec(SCHEMA);
    assert.deepEqual(routes(db),
      [{ model: 'claude-fable-5-1', runner: 'claude', position, project: null, updated_by: 'op' }]);
  });
}

test('the retry policy for stage lead-review resolves through laneCandidates: 2 attempts, 300 s, no escalate', () => {
  const db = openDb();
  const q = db.prepare('SELECT max_attempts, backoff_seconds, escalate_allowed FROM retry_policies WHERE lane=?');
  for (const lane of ['lead-review', 'lead-review/cromford', 'lead-review/cromford/claude']) {
    const hit = laneCandidates(lane).candidates.map((k) => q.get(k)).find(Boolean);
    assert.ok(hit, `no retry policy reachable for ${lane}`);
    assert.deepEqual({ ...hit }, { max_attempts: 2, backoff_seconds: 300, escalate_allowed: 0 }, lane);
  }
});

test('lead_review_requests has exactly the contract columns, in order', () => {
  const cols = openDb().prepare('PRAGMA table_info(lead_review_requests)').all().map((c) => c.name);
  assert.deepEqual(cols, ['id', 'repo', 'pr', 'head_sha', 'scope_notes', 'prior_verdict_ref', 'requested_by',
    'status', 'job_id', 'box', 'verdict', 'report_ref', 'reviewer_model', 'detail', 'promoted_verdict_at',
    'created_at', 'updated_at']);
});

test('a minimal request row starts as requested', () => {
  const db = openDb();
  insertReq(db, 'r1', SHA_A);
  assert.equal(db.prepare("SELECT status FROM lead_review_requests WHERE id='r1'").get().status, 'requested');
});

test('one request per (repo, pr, head_sha): a duplicate throws, another head does not', () => {
  const db = openDb();
  insertReq(db, 'r1', SHA_A);
  assert.throws(() => insertReq(db, 'r2', SHA_A), /UNIQUE constraint failed/);
  insertReq(db, 'r3', SHA_B);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n, 2);
});

test('an index serves (status, repo)', () => {
  const db = openDb();
  const idx = db.prepare('PRAGMA index_list(lead_review_requests)').all()
    .map((i) => db.prepare(`PRAGMA index_info('${i.name}')`).all().map((c) => c.name).join(','));
  assert.ok(idx.includes('status,repo'), `indexes: ${JSON.stringify(idx)}`);
});
