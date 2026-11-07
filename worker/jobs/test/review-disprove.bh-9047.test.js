// BH-9047: review_disprove_runs and /api/review-disprove. Driven through the
// REAL worker.fetch over the REAL composed schema (the node:sqlite D1 shim).
//
//   W1  POST then GET by repo+pr+head_sha returns the row; a repeat POST is
//       200 existing:true and leaves 1 row
//   W2  bad inputs each answer 400 and write nothing
//   W3  another repo reads 0 rows
//   W4  EXPLAIN QUERY PLAN at 20 000 rows uses the two indexes, no SCAN
//   W5  retention: the rule is in RULES; dry_run=0 deletes a 91-day row and
//       keeps a 1-day row
//   W6  no bearer = 401
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { RULES } from '../src/routes/retention.js';

const SECRET = 'test-secret-fixture';
const R = () => import('../src/routes/review-disprove.js');

const call = (DB, path, { method = 'GET', body, auth = true, extra = {} } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, ...extra, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const post = (DB, body, o = {}) => call(DB, '/api/review-disprove', { method: 'POST', body, ...o });
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const sha = () => randomUUID().replace(/-/g, '').padEnd(40, '0').slice(0, 40);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','test','2026-11-04T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const count = (db) => db.prepare('SELECT count(*) AS n FROM review_disprove_runs').get().n;

const runBody = (over = {}) => ({
  repo: 'a/b', pr: 12, head_sha: sha(), review_id: `rv-${randomUUID()}`, lane: 'lead', project: 'cromford',
  mode: 'shadow', verdict_before: 'BLOCK', verdict_after: 'BLOCK',
  findings: 3, checked: 2, confirmed: 1, disproved: 1, kept_protected: 0, unchecked: 1,
  cost_usd: 0.12,
  detail: [
    { cls: 'wrong-data', loc: 'bin/a.sh:12', outcome: 'DISPROVED', reason: 'x'.repeat(400) },
    { cls: 'core-flow-broken', loc: 'bin/a.sh:40', outcome: 'CONFIRMED', reason: 'the guard is missing' },
  ],
  actor: 'lead-review',
  ...over,
});

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('W1 POST then GET returns the row; a repeat POST is existing:true and 1 row', { skip: SKIP }, async () => {
  const { db, DB } = await openDb();
  const b = runBody();
  const r1 = await post(DB, b);
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  assert.equal(r1.body.existing, false);
  assert.equal(r1.body.row.disproved, 1);
  assert.equal(r1.body.row.detail[0].reason.length, 300, 'reason cut to 300');
  const g = await call(DB, `/api/review-disprove?repo=a/b&pr=12&head_sha=${b.head_sha}`);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.rows.length, 1);
  const row = g.body.rows[0];
  for (const k of ['findings', 'checked', 'confirmed', 'disproved', 'kept_protected', 'unchecked']) assert.equal(row[k], b[k], k);
  assert.equal(row.cost_usd, 0.12);
  assert.equal(row.mode, 'shadow');
  assert.equal(row.lane, 'lead');
  assert.equal(row.actor, 'lead-review');
  assert.ok(Array.isArray(row.detail) && row.detail.length === 2, 'detail parsed back to an array');
  const r2 = await post(DB, { ...b, verdict_after: 'MERGE-WITH-NOTES' });
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  assert.equal(r2.body.existing, true);
  assert.equal(r2.body.row.verdict_after, 'BLOCK', 'the first row stands');
  assert.equal(count(db), 1);
  // the same head on the other lane is its own row; cost absent is null; actor defaults
  const { cost_usd: _c, actor: _a, ...noCost } = b;
  const r3 = await post(DB, { ...noCost, lane: 'conductor' });
  assert.equal(r3.status, 201, JSON.stringify(r3.body));
  assert.equal(r3.body.row.cost_usd, null);
  assert.equal(r3.body.row.actor, 'box');
  assert.equal(count(db), 2);
  const gl = await call(DB, `/api/review-disprove?repo=a/b&pr=12&head_sha=${b.head_sha}&lane=conductor`);
  assert.equal(gl.body.rows.length, 1);
});

test('W2 bad inputs each answer 400 and write nothing', { skip: SKIP }, async () => {
  const { db, DB } = await openDb();
  const item = { cls: 'wrong-data', loc: 'a:1', outcome: 'CONFIRMED', reason: 'r' };
  for (const [field, over] of [
    ['pr', { pr: 'x' }],
    ['head_sha', { head_sha: 'a'.repeat(39) }],
    ['lane', { lane: 'other' }],
    ['detail', { detail: Array.from({ length: 21 }, () => item) }],
    ['repo', { repo: 'nope' }],
    ['mode', { mode: 'loud' }],
    ['review_id', { review_id: '' }],
    ['project', { project: undefined }],
    ['confirmed', { confirmed: -1 }],
    ['cost_usd', { cost_usd: 'free' }],
  ]) {
    const r = await post(DB, runBody(over));
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.field, field);
    assert.match(r.body.error, new RegExp(`^${field} `));
  }
  assert.equal(count(db), 0);
  for (const q of ['', '?pr=12', '?repo=a/b&limit=0', '?repo=a/b&limit=501', '?repo=a/b&limit=x', '?since=yesterday']) {
    const r = await call(DB, `/api/review-disprove${q}`);
    assert.equal(r.status, 400, `GET ${q}: ${JSON.stringify(r.body)}`);
  }
  setting(db, 'review.disprove.list_max', '600');
  assert.equal((await call(DB, '/api/review-disprove?repo=a/b&limit=501')).status, 200, 'the max is a settings row');
});

test('W3 another repo reads 0 rows', { skip: SKIP }, async () => {
  const { DB } = await openDb();
  const b = runBody();
  assert.equal((await post(DB, b)).status, 201);
  const g = await call(DB, '/api/review-disprove?repo=other/x');
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.rows, []);
  const g2 = await call(DB, `/api/review-disprove?repo=other/x&pr=12&head_sha=${b.head_sha}`);
  assert.deepEqual(g2.body.rows, []);
  const g3 = await call(DB, '/api/review-disprove?since=2000-01-01T00:00:00Z&limit=500');
  assert.equal(g3.body.rows.length, 1, 'since reads it back');
});

test('W4 EXPLAIN QUERY PLAN at 20 000 rows: the key and created indexes, no SCAN', { skip: SKIP }, async () => {
  const { db } = await openDb();
  const M = await R();
  const base = Date.parse('2026-08-01T00:00:00Z');
  const repos = ['example-org/cromford', 'example-org/project-3', 'example-org/project-4', 'example-org/project-1'];
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO review_disprove_runs (repo, pr, head_sha, review_id, lane, project, mode,
    verdict_before, verdict_after, findings, checked, confirmed, disproved, kept_protected, unchecked, cost_usd, detail, actor, created_at)
    VALUES (?, ?, ?, ?, ?, 'p', 'shadow', 'BLOCK', 'BLOCK', 1, 1, 1, 0, 0, 0, NULL, '[]', 'seed', ?)`);
  for (let i = 0; i < 20000; i++) {
    ins.run(repos[i % 4], 1 + (i % 2000), i.toString(16).padStart(40, '0'), `rv-${i}`, i % 3 ? 'lead' : 'conductor', iso(base + i * 60000));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
  const ret = RULES.find((r) => r.rule === 'review_disprove_runs.age');
  assert.ok(ret, 'retention RULES has review_disprove_runs.age');
  const head = (17).toString(16).padStart(40, '0');
  const cases = [
    ['repo+pr+head', M.listSql({ repo: repos[1], pr: 18, head_sha: head, limit: 101 }), 'idx_review_disprove_runs_key'],
    ['repo+pr+head+lane', M.listSql({ repo: repos[1], pr: 18, head_sha: head, lane: 'lead', limit: 101 }), 'idx_review_disprove_runs_key'],
    ['since', M.listSql({ since: '2026-08-10T00:00:00Z', limit: 101 }), 'idx_review_disprove_runs_created'],
    ['since+lane', M.listSql({ since: '2026-08-10T00:00:00Z', lane: 'lead', limit: 101 }), 'idx_review_disprove_runs_created'],
    ['key read', { sql: M.KEY_SQL, binds: [repos[1], 18, head, 'rv-17', 'lead'] }, 'idx_review_disprove_runs_key'],
    ['retention ids', { sql: ret.ids, binds: ['2026-08-05T00:00:00Z', 500] }, 'idx_review_disprove_runs_created'],
  ];
  for (const [name, { sql, binds }, idx] of cases) {
    const lines = planOf(sql, binds);
    assert.ok(lines.some((l) => l.includes(idx)), `${name}: ${idx} not used: ${lines.join(' | ')}`);
    assert.ok(!lines.some((l) => /^SCAN review_disprove_runs\b/.test(l)), `${name}: a SCAN: ${lines.join(' | ')}`);
  }
  // repo alone (no pr) still starts on the key index prefix
  const repoOnly = planOf(...Object.values(M.listSql({ repo: repos[0], limit: 101 })));
  assert.ok(!repoOnly.some((l) => /^SCAN review_disprove_runs\b/.test(l)), `repo: a SCAN: ${repoOnly.join(' | ')}`);
});

test('W5 retention: a 91-day row is deleted, a 1-day row is kept', { skip: SKIP }, async (tt) => {
  const NOW = Date.parse('2026-11-04T12:00:00Z');
  tt.mock.timers.enable({ apis: ['Date'], now: NOW });
  const rule = RULES.find((r) => r.rule === 'review_disprove_runs.age');
  assert.ok(rule, 'RULES has review_disprove_runs.age');
  assert.equal(rule.table, 'review_disprove_runs');
  assert.equal(rule.key, 'retention.review_disprove_runs.days');
  assert.equal(rule.def, 90);
  assert.equal(rule.archive, undefined, 'a plain delete, no archive');
  const { db, DB } = await openDb();
  const ins = db.prepare(`INSERT INTO review_disprove_runs (repo, pr, head_sha, review_id, lane, project, mode,
    verdict_before, verdict_after, findings, checked, confirmed, disproved, kept_protected, unchecked, cost_usd, detail, actor, created_at)
    VALUES ('w5/r', 1, ?, ?, 'lead', 'p', 'shadow', 'BLOCK', 'BLOCK', 1, 1, 1, 0, 0, 0, NULL, '[]', 'seed', ?)`);
  ins.run(sha(), 'old-91', iso(NOW - 91 * 86400e3));
  ins.run(sha(), 'new-1', iso(NOW - 1 * 86400e3));
  const ids = () => db.prepare('SELECT review_id FROM review_disprove_runs ORDER BY review_id').all().map((r) => r.review_id);
  const run = () => call(DB, '/api/retention/run', { method: 'POST', body: {} });
  const ruleOf = (b) => (b.rules || []).find((x) => x.rule === 'review_disprove_runs.age');
  let r = await run();
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(ruleOf(r.body).counted, 1, JSON.stringify(ruleOf(r.body)));
  assert.deepEqual(ids(), ['new-1', 'old-91'], 'a dry run removes nothing');
  setting(db, 'retention.dry_run', '0');
  r = await run();
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(ruleOf(r.body).error, null, JSON.stringify(ruleOf(r.body)));
  assert.equal(ruleOf(r.body).removed, 1);
  assert.deepEqual(ids(), ['new-1']);
});

test('W6 no bearer = 401', { skip: SKIP }, async () => {
  const { db, DB } = await openDb();
  assert.equal((await post(DB, runBody(), { auth: false })).status, 401);
  assert.equal((await call(DB, '/api/review-disprove?repo=a/b', { auth: false })).status, 401);
  assert.equal(count(db), 0);
});
