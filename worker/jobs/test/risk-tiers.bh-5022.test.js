import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { isProtectedSetting } from '../src/routes/verdicts.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5022 (BH-4973.1) — the worker half of the rule-based risk tier:
//   - source=risk-tier on /api/verdicts: lead token, MERGE only, and it STANDS
//     (plan D1), so every lane that reads vd_standing sees the sign-off;
//   - the risk_tiers classification table behind GET/POST /api/risk-tiers;
//   - lead_review_requests.priority, so a high-tier request is claimed first (D7);
//   - the per-repo mode seed and risk_tier.* as a signed settings family (D2).
// Driven through worker.fetch against THE SQL THAT SHIPS (worker/jobs/schema.sql),
// the verdicts.bh-1525 / lead-reviews.bh-1949 idiom.
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

// Every call carries the bearer; `lead: true` adds the lead verdict token.
const call = (DB, path, { method = 'GET', body, lead = false } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
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

const REPO = 'example-org/cromford';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const H3 = 'c'.repeat(40);
const RT = { repo: REPO, pr: 5022, head_sha: H1, verdict: 'MERGE', source: 'risk-tier', note: 'low risk: docs only' };
const TIER = { repo: REPO, pr: 5022, head_sha: H1, project: 'cromford', tier: 'low', mode: 'enforce',
               action: 'signed', reasons: 'docs/tests/screens only, 10 lines', lines: 10, files: 1 };

test('D1. source=risk-tier MERGE with the lead token → 201 auth=lead-token; without the token → 403 and nothing written', async () => {
  const { db, DB } = fresh();
  const no = await call(DB, '/api/verdicts', { method: 'POST', body: RT });
  assert.equal(no.status, 403, JSON.stringify(no.body));
  assert.match(no.body.error, /lead verdict token/);
  assert.equal(db.prepare('SELECT count(*) AS n FROM verdicts').get().n, 0, 'a refused risk-tier row lands nothing');
  const yes = await call(DB, '/api/verdicts', { method: 'POST', body: RT, lead: true });
  assert.equal(yes.status, 201, JSON.stringify(yes.body));
  assert.equal(yes.body.verdict.source, 'risk-tier');
  assert.equal(yes.body.verdict.verdict, 'MERGE');
  assert.equal(yes.body.verdict.auth, 'lead-token');
});

test('D2. source=risk-tier may only say MERGE: BLOCK and MERGE-WITH-NOTES → 400, with the token, and nothing written', async () => {
  const { db, DB } = fresh();
  for (const verdict of ['BLOCK', 'MERGE-WITH-NOTES']) {
    const res = await call(DB, '/api/verdicts', { method: 'POST', body: { ...RT, verdict }, lead: true });
    assert.equal(res.status, 400, `${verdict}: ${JSON.stringify(res.body)}`);
    assert.match(res.body.error, /risk-tier/);
    assert.match(res.body.error, /MERGE/);
  }
  assert.equal(db.prepare('SELECT count(*) AS n FROM verdicts').get().n, 0);
  // The source is in the accepted vocabulary (the enum error names it).
  const bad = await call(DB, '/api/verdicts', { method: 'POST', body: { ...RT, source: 'robot' }, lead: true });
  assert.equal(bad.status, 400);
  assert.match(bad.body.error, /risk-tier/);
});

test('D3. a risk-tier MERGE STANDS on its head; a newer lead BLOCK on the same head stands instead', async () => {
  const { DB } = fresh();
  assert.equal((await call(DB, '/api/verdicts', { method: 'POST', body: RT, lead: true })).status, 201);
  const q = `/api/verdicts?repo=${REPO}&pr=5022&head=${H1}&standing_only=1`;
  const s1 = await call(DB, q);
  assert.equal(s1.status, 200, JSON.stringify(s1.body));
  assert.ok(s1.body.standing, 'a risk-tier row must stand');
  assert.equal(s1.body.standing.source, 'risk-tier');
  assert.equal(s1.body.standing.verdict, 'MERGE');
  // It is head-bound: another head of the same PR has nothing standing.
  const other = await call(DB, `/api/verdicts?repo=${REPO}&pr=5022&head=${H2}&standing_only=1`);
  assert.equal(other.body.standing, null);
  const blk = await call(DB, '/api/verdicts', { method: 'POST', lead: true,
    body: { repo: REPO, pr: 5022, head_sha: H1, verdict: 'BLOCK', source: 'lead', note: 'no' } });
  assert.equal(blk.status, 201, JSON.stringify(blk.body));
  const s2 = await call(DB, q);
  assert.equal(s2.body.standing.source, 'lead');
  assert.equal(s2.body.standing.verdict, 'BLOCK');
});

test('D4. POST /api/risk-tiers → 201; the same key again → 200 existing:true; bad input → 400', async () => {
  const { db, DB } = fresh();
  const a = await call(DB, '/api/risk-tiers', { method: 'POST', body: TIER });
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.ok, true);
  assert.ok(Number.isInteger(a.body.id) && a.body.id > 0);
  const b = await call(DB, '/api/risk-tiers', { method: 'POST', body: { ...TIER, tier: 'high', reasons: 'other' } });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.existing, true);
  const row = db.prepare('SELECT * FROM risk_tiers').all();
  assert.equal(row.length, 1, 'one row per (repo, pr, head_sha)');
  assert.equal(row[0].tier, 'low', 'the first classification of a head is kept');
  assert.equal(row[0].lines, 10);
  assert.equal(row[0].project, 'cromford');
  for (const [k, v] of [['tier', 'x'], ['mode', 'loud'], ['repo', 'nope'], ['pr', 0], ['head_sha', 'abc'],
                        ['reasons', 'r'.repeat(1001)], ['lines', -1], ['files', 'many'], ['action', 'a'.repeat(65)]]) {
    const res = await call(DB, '/api/risk-tiers', { method: 'POST', body: { ...TIER, head_sha: H2, [k]: v } });
    assert.equal(res.status, 400, `${k}=${JSON.stringify(v)}: ${JSON.stringify(res.body)}`);
  }
  assert.equal(db.prepare('SELECT count(*) AS n FROM risk_tiers').get().n, 1, 'a refused POST lands nothing');
});

test('D5. GET /api/risk-tiers?repo=&tier=low → only low rows, newest first, with truncated', async () => {
  const { DB } = fresh();
  for (const [head, tier, pr] of [[H1, 'low', 1], [H2, 'high', 2], [H3, 'low', 3]]) {
    assert.equal((await call(DB, '/api/risk-tiers', { method: 'POST', body: { ...TIER, head_sha: head, tier, pr } })).status, 201);
  }
  await call(DB, '/api/risk-tiers', { method: 'POST', body: { ...TIER, repo: 'example-org/other', head_sha: H2, tier: 'low', pr: 9 } });
  const all = await call(DB, `/api/risk-tiers?repo=${REPO}&tier=low`);
  assert.equal(all.status, 200, JSON.stringify(all.body));
  assert.deepEqual(all.body.rows.map((r) => r.pr), [3, 1], 'only this repo, only low, newest first');
  assert.equal(all.body.truncated, false);
  const one = await call(DB, `/api/risk-tiers?repo=${REPO}&tier=low&limit=1`);
  assert.deepEqual(one.body.rows.map((r) => r.pr), [3]);
  assert.equal(one.body.truncated, true);
  const byPr = await call(DB, `/api/risk-tiers?repo=${REPO}&pr=2`);
  assert.deepEqual(byPr.body.rows.map((r) => r.tier), ['high']);
  assert.equal((await call(DB, '/api/risk-tiers?tier=x')).status, 400);
  assert.equal((await call(DB, '/api/risk-tiers?limit=201')).status, 400);
});

test('D6. lead-review priority: a high-tier request stores priority 1 (BH-5151 contract, the tick works it first); 0 → 400; a re-confirm with priority 1 raises a queued row, none never lowers it', async () => {
  const { db, DB } = fresh();
  const req = { repo: REPO, pr: 1, head_sha: H1, scope_notes: 'n' };
  const lr = (body) => call(DB, '/api/lead-reviews', { method: 'POST', body, lead: true });
  assert.equal((await lr(req)).status, 201);
  const hi = await lr({ ...req, pr: 2, head_sha: H2, priority: 1 });
  assert.equal(hi.status, 201, JSON.stringify(hi.body));
  assert.equal(hi.body.request.priority, 1);
  // The list is cursor order (BH-5151); bin/lead-review.sh orders by priority.
  const list = await call(DB, '/api/lead-reviews?status=requested');
  assert.equal(list.status, 200, JSON.stringify(list.body));
  assert.deepEqual(list.body.requests.map((r) => [r.pr, r.priority]), [[1, null], [2, 1]]);
  for (const priority of [0, -1, '1', 'high', 0.5]) {
    const res = await lr({ ...req, pr: 3, head_sha: H3, priority });
    assert.equal(res.status, 400, `priority ${JSON.stringify(priority)}: ${JSON.stringify(res.body)}`);
  }
  // priority is not part of the key's identity: the same ask, re-POSTed, is
  // existing. A re-confirm with priority 1 raises the queued row (lead note,
  // 10-07); one with no priority never lowers it.
  const again = await lr({ ...req, priority: 1 });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.existing, true);
  assert.equal(again.body.request.priority, 1, 'the answer carries the raised priority');
  assert.equal(db.prepare('SELECT priority FROM lead_review_requests WHERE pr=1').get().priority, 1, 'raised');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests WHERE pr=1').get().n, 1, 'no second request');
  const res = await lr(req);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.request.priority, 1, 'never lowered by a request with no priority');
});

test('D6b. CREATED_TABLES.risk_tiers builds the same table and indexes as schema.sql', () => {
  const block = SCHEMA.match(/CREATE TABLE IF NOT EXISTS risk_tiers[\s\S]*?\);(\s*CREATE INDEX IF NOT EXISTS idx_risk_tiers[^;]*;)+/);
  assert.ok(block, 'schema.sql has no risk_tiers block');
  assert.ok(Array.isArray(CREATED_TABLES.risk_tiers), 'CREATED_TABLES has no risk_tiers key');
  const a = new DatabaseSync(':memory:');
  a.exec(block[0]);
  const b = new DatabaseSync(':memory:');
  for (const stmt of CREATED_TABLES.risk_tiers) b.exec(stmt);
  const cols = (db) => db.prepare('PRAGMA table_info(risk_tiers)').all()
    .map(({ name, type, notnull, dflt_value, pk }) => ({ name, type, notnull, dflt_value, pk }));
  assert.deepEqual(cols(b), cols(a));
  const idx = (db) => db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='risk_tiers' AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map((r) => r.name);
  assert.deepEqual(idx(b), idx(a));
  assert.ok(idx(b).length >= 1);
});

test('D7. schema.sql seeds risk_tier.mode.example-org.cromford = enforce; risk_tier.* is a protected settings family', () => {
  const { db } = fresh();
  const row = db.prepare("SELECT value FROM settings WHERE key='risk_tier.mode.example-org.cromford'").get();
  assert.ok(row, 'the seed row is missing');
  assert.equal(row.value, 'enforce');
  assert.equal(isProtectedSetting('risk_tier.low_globs'), true);
  assert.equal(isProtectedSetting('risk_tier.mode.example-org.cromford'), true);
  assert.equal(isProtectedSetting('risk_tier'), false);
});
