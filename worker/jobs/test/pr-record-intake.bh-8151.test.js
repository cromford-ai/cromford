// BH-8151 (BH-8067 slice C2): the GitHub receiver writes the PR record from
// the payload, and case 2 of the read rule (a named change whose payload does
// not carry the field stores NULL). Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema. Each case opens its own DB and
// uses its own repo o/bh8151-<case>.
//   N1 upsertSql default equals {refresh:true}; refresh:false keeps refreshed_at
//   N2 PUT mergeable_state:null -> 200, column NULL; PUT head_sha:null -> 400
//   M1-M9 the decision table of prRecordWritesOf (pure)
//   W1-W7 recordPrRecord against the real schema
//   X1 the check upsert and the fields upsert use ux_pr_records_repo_number
//   X2 BASE_PUSH_SQL uses an index, no SCAN pr_records, on 5,000 rows
//   R1-R4 signed deliveries through POST /webhooks/github
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { upsertSql } from '../src/routes/pr-records.js';
import { prRecordWritesOf, recordPrRecord, CHECK_MERGE_SQL, BASE_PUSH_SQL } from '../src/lib/pr-record-intake.js';

const SECRET = 'tok-fixture-bh8151';
const GH = 'gh-fixture-secret-bh8151';
const NOW_MS = Date.parse('2026-10-22T12:00:00Z');
const T = '2026-10-22T12:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40), C = 'c'.repeat(40), M = 'd'.repeat(40);

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: GH } };
}
const rowOf = (db, repo, n) => {
  const r = db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n);
  if (!r) return null;
  const o = { ...r };
  for (const k of ['labels', 'checks', 'fields_at']) if (typeof o[k] === 'string') o[k] = JSON.parse(o[k]);
  return o;
};
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n;
async function api(env, method, path, body) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
let dn = 0;
async function hook(env, event, payload, { sig } = {}) {
  const body = JSON.stringify(payload);
  dn += 1;
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-8151-${dn}`,
    'x-hub-signature-256': sig ?? 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

// ── payload builders (the shapes GitHub sends) ─────────────────────────────────
const repository = (repo, extra = {}) => ({ full_name: repo, default_branch: 'main', ...extra });
const pr = (n, o = {}) => ({
  number: n, state: 'open', draft: false, merged_at: null, updated_at: ago(60),
  head: { ref: 'ticket/x', sha: A }, base: { ref: 'main', sha: B },
  labels: [{ name: 'ai-build' }, { name: 'tier-1' }], ...o,
});
const prEvent = (repo, action, n, o = {}) => ({ action, number: n, repository: repository(repo), pull_request: pr(n, o) });
const checkRun = (repo, action, prs, o = {}) => ({
  action, repository: repository(repo),
  check_run: { name: 'test', status: action === 'completed' ? 'completed' : 'in_progress', conclusion: action === 'completed' ? 'success' : null,
    head_sha: C, started_at: ago(300), completed_at: ago(120), pull_requests: prs.map((n) => ({ number: n })), ...o },
});
const checkSuite = (repo, action, prs, o = {}) => ({
  action, repository: repository(repo),
  check_suite: { status: 'completed', conclusion: 'failure', head_sha: C, updated_at: ago(100), app: { slug: 'github-actions' },
    pull_requests: prs.map((n) => ({ number: n })), ...o },
});
const workflowRun = (repo, action, prs, o = {}) => ({
  action, repository: repository(repo),
  workflow_run: { name: 'harness-ci', status: 'completed', conclusion: 'success', head_sha: C, updated_at: ago(90),
    event: 'pull_request', path: '.github/workflows/harness-ci.yml', display_title: 'x', pull_requests: prs.map((n) => ({ number: n })), ...o },
});
const review = (repo, action, n, state, o = {}) => ({
  action, repository: repository(repo), pull_request: pr(n, { mergeable_state: 'clean' }),
  review: { state, submitted_at: ago(30), ...o },
});
const comment = (repo, action, n, { onPr = true, merged = false } = {}) => ({
  action, repository: repository(repo),
  issue: { number: n, state: 'closed', updated_at: ago(20), labels: [{ name: 'hold' }],
    ...(onPr ? { pull_request: { url: 'x', merged_at: merged ? ago(25) : null } } : {}) },
  comment: { id: 99, body: 'hi' },
});
const push = (repo, ref, default_branch = 'main') => ({ ref, before: A, after: B, repository: repository(repo, { default_branch }) });

// ── N: pr-records.js changes ──────────────────────────────────────────────────
test('N1 upsertSql default equals {refresh:true}; refresh:false keeps an existing refreshed_at', async (t) => {
  assert.equal(upsertSql(['state']), upsertSql(['state'], { refresh: true }));
  assert.notEqual(upsertSql(['state']), upsertSql(['state'], { refresh: false }));
  const o = await fresh(t); if (!o) return;
  await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8151-n1', number: 1, source: 'fleet', at: ago(1000), fields: { state: 'open' } });
  await o.DB.prepare(upsertSql(['labels'], { refresh: false })).bind('o/bh8151-n1', 1, ago(10), 'webhook', '["x"]').run();
  const r = rowOf(o.db, 'o/bh8151-n1', 1);
  assert.deepEqual(r.labels, ['x']);
  assert.equal(r.refreshed_at, ago(1000), 'refresh:false keeps refreshed_at');
  assert.equal(r.webhook_at, ago(10));
  await o.DB.prepare(upsertSql(['labels'])).bind('o/bh8151-n1', 1, ago(5), 'webhook', '["y"]').run();
  assert.equal(rowOf(o.db, 'o/bh8151-n1', 1).refreshed_at, ago(5), 'the default moves refreshed_at');
});

test('N2 PUT mergeable_state:null stores NULL with its time; PUT head_sha:null is still a 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8151-n2', number: 2, source: 'github', at: ago(100), fields: { mergeable_state: 'clean' } });
  const r = await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8151-n2', number: 2, source: 'github', fields: { mergeable_state: null } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.applied, ['mergeable_state']);
  const row = rowOf(o.db, 'o/bh8151-n2', 2);
  assert.equal(row.mergeable_state, null);
  assert.equal(row.fields_at.mergeable_state, T);
  const bad = await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8151-n2', number: 3, source: 'fleet', fields: { head_sha: null } });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.field, 'head_sha');
  assert.equal(bad.body.error, 'invalid_field');
});

// ── M: the mapper ─────────────────────────────────────────────────────────────
const R = 'o/bh8151-m';
test('M1 pull_request.synchronize with mergeable_state unknown: every PR field, mergeable_state null, refresh, at = updated_at', () => {
  const w = prRecordWritesOf('pull_request', prEvent('O/BH8151-M', 'synchronize', 7, { mergeable_state: 'unknown' }), T);
  assert.equal(w.length, 1);
  assert.equal(w[0].kind, 'fields');
  assert.equal(w[0].repo, R);
  assert.equal(w[0].number, 7);
  assert.equal(w[0].refresh, true);
  assert.equal(w[0].at, ago(60));
  assert.deepEqual(w[0].fields, { state: 'open', draft: 0, head_ref: 'ticket/x', base_ref: 'main', head_sha: A, base_sha: B,
    labels: '["ai-build","tier-1"]', mergeable_state: null,
    // TEST-CHANGE (BH-8452): prFields also stores GitHub's updated_at as pr_updated_at.
    pr_updated_at: ago(60) });
  const k = prRecordWritesOf('pull_request', prEvent(R, 'synchronize', 7, { mergeable_state: 'clean' }), T);
  assert.equal(k[0].fields.mergeable_state, 'clean');
});
test('M1b pull_request.labeled with no mergeable_state key writes no mergeable_state', () => {
  const p = prEvent(R, 'labeled', 7);
  const w = prRecordWritesOf('pull_request', p, T);
  assert.equal(w.length, 1);
  assert.ok(!Object.hasOwn(w[0].fields, 'mergeable_state'), JSON.stringify(w[0].fields));
  const u = prRecordWritesOf('pull_request', prEvent(R, 'labeled', 7, { mergeable_state: 'unknown' }), T);
  assert.ok(!Object.hasOwn(u[0].fields, 'mergeable_state'), 'unknown on labeled is not written');
});
test('M1c pull_request.closed: merged_at set -> merged, else closed', () => {
  assert.equal(prRecordWritesOf('pull_request', prEvent(R, 'closed', 7, { state: 'closed', merged_at: ago(70) }), T)[0].fields.state, 'merged');
  assert.equal(prRecordWritesOf('pull_request', prEvent(R, 'closed', 7, { state: 'closed', merged: true }), T)[0].fields.state, 'merged');
  assert.equal(prRecordWritesOf('pull_request', prEvent(R, 'closed', 7, { state: 'closed' }), T)[0].fields.state, 'closed');
});
test('M1d near miss: a 39-hex head sha and a 101-char label drop those fields only', () => {
  const w = prRecordWritesOf('pull_request', prEvent(R, 'edited', 7, { head: { ref: 'ticket/x', sha: 'a'.repeat(39) }, labels: [{ name: 'x'.repeat(101) }] }), T);
  assert.equal(w.length, 1);
  assert.ok(!Object.hasOwn(w[0].fields, 'head_sha'));
  assert.ok(!Object.hasOwn(w[0].fields, 'labels'));
  assert.equal(w[0].fields.base_sha, B);
  assert.equal(w[0].fields.state, 'open');
});
test('M2 pull_request_review approved / changes_requested sets review_decision, never mergeable_state', () => {
  for (const s of ['approved', 'changes_requested']) {
    const w = prRecordWritesOf('pull_request_review', review(R, 'submitted', 7, s.toUpperCase()), T);
    assert.equal(w.length, 1);
    assert.equal(w[0].fields.review_decision, s);
    assert.ok(!Object.hasOwn(w[0].fields, 'mergeable_state'));
    assert.equal(w[0].fields.head_sha, A);
    assert.equal(w[0].at, ago(30));
    assert.equal(w[0].refresh, true);
  }
});
test('M2b a commented review writes no review_decision; the PR fields still go', () => {
  const w = prRecordWritesOf('pull_request_review', review(R, 'submitted', 7, 'commented'), T);
  assert.equal(w.length, 1);
  assert.ok(!Object.hasOwn(w[0].fields, 'review_decision'));
  assert.equal(w[0].fields.state, 'open');
});
test('M2c pull_request_review.dismissed -> review_decision null', () => {
  const w = prRecordWritesOf('pull_request_review', review(R, 'dismissed', 7, 'dismissed'), T);
  assert.ok(Object.hasOwn(w[0].fields, 'review_decision'));
  assert.equal(w[0].fields.review_decision, null);
  assert.deepEqual(prRecordWritesOf('pull_request_review', review(R, 'deleted', 7, 'approved'), T), []);
});
test('M3 issue_comment on a PR: labels and state, refresh false, no last_comment_id', () => {
  const w = prRecordWritesOf('issue_comment', comment(R, 'created', 7), T);
  assert.equal(w.length, 1);
  assert.deepEqual(w[0].fields, { labels: '["hold"]', state: 'closed' });
  assert.equal(w[0].refresh, false);
  assert.equal(w[0].at, ago(20));
  assert.equal(prRecordWritesOf('issue_comment', comment(R, 'edited', 7, { merged: true }), T)[0].fields.state, 'merged');
});
test('M3b a comment on a plain issue, and a deleted comment, write nothing', () => {
  assert.deepEqual(prRecordWritesOf('issue_comment', comment(R, 'created', 7, { onPr: false }), T), []);
  assert.deepEqual(prRecordWritesOf('issue_comment', comment(R, 'deleted', 7), T), []);
});
test('M4 check_run.completed with 2 PRs -> 2 check writes', () => {
  const w = prRecordWritesOf('check_run', checkRun(R, 'completed', [7, 8]), T);
  assert.equal(w.length, 2);
  assert.deepEqual(w.map((x) => x.number), [7, 8]);
  for (const x of w) {
    assert.equal(x.kind, 'check');
    assert.equal(x.name, 'test');
    assert.deepEqual(x.value, { status: 'completed', conclusion: 'success', sha: C, at: ago(120) });
    assert.equal(x.at, ago(120));
  }
  const c = prRecordWritesOf('check_run', checkRun(R, 'created', [7]), T);
  assert.deepEqual(c[0].value, { status: 'in_progress', conclusion: null, sha: C, at: ago(300) });
});
test('M4b check_run with no PR, rerequested, a quoted name or a short sha writes nothing', () => {
  assert.deepEqual(prRecordWritesOf('check_run', checkRun(R, 'completed', []), T), []);
  assert.deepEqual(prRecordWritesOf('check_run', checkRun(R, 'rerequested', [7]), T), []);
  assert.deepEqual(prRecordWritesOf('check_run', checkRun(R, 'completed', [7], { name: 'a"b' }), T), []);
  assert.deepEqual(prRecordWritesOf('check_run', checkRun(R, 'completed', [7], { name: 'a\\b' }), T), []);
  assert.deepEqual(prRecordWritesOf('check_run', checkRun(R, 'completed', [7], { name: 'x'.repeat(101) }), T), []);
  assert.deepEqual(prRecordWritesOf('check_run', checkRun(R, 'completed', [7], { head_sha: 'c'.repeat(39) }), T), []);
});
test('M5 check_suite.completed -> suite:<slug>; M5b requested -> nothing', () => {
  const w = prRecordWritesOf('check_suite', checkSuite(R, 'completed', [7]), T);
  assert.equal(w.length, 1);
  assert.equal(w[0].name, 'suite:github-actions');
  assert.deepEqual(w[0].value, { status: 'completed', conclusion: 'failure', sha: C, at: ago(100) });
  assert.deepEqual(prRecordWritesOf('check_suite', checkSuite(R, 'requested', [7]), T), []);
});
test('M6 workflow_run.completed -> workflow:<name>; M6b prequeue title -> pr and head from the title; M6c a look-alike -> nothing', () => {
  const w = prRecordWritesOf('workflow_run', workflowRun(R, 'completed', [7]), T);
  assert.equal(w.length, 1);
  assert.equal(w[0].name, 'workflow:harness-ci');
  assert.equal(w[0].value.sha, C);
  assert.equal(w[0].at, ago(90));
  const pq = prRecordWritesOf('workflow_run', workflowRun(R, 'completed', [], {
    name: 'prequeue-gate', head_sha: M, event: 'workflow_dispatch', path: '.github/workflows/prequeue-gate.yml',
    display_title: `prequeue pr=12 head=${A} main=${M}` }), T);
  assert.equal(pq.length, 1);
  assert.equal(pq[0].number, 12);
  assert.equal(pq[0].name, 'workflow:prequeue-gate');
  assert.equal(pq[0].value.sha, A, 'the title head, not main');
  assert.deepEqual(prRecordWritesOf('workflow_run', workflowRun(R, 'completed', [], {
    event: 'workflow_dispatch', path: '.github/workflows/prequeue-gate.yml', display_title: 'prequeue pr=12 head=short' }), T), []);
  assert.deepEqual(prRecordWritesOf('workflow_run', workflowRun(R, 'requested', [7]), T), []);
});
test('M7 push to the default branch -> base-push; M7b a feature branch or a non-default main -> nothing', () => {
  const w = prRecordWritesOf('push', push(R, 'refs/heads/main'), T);
  assert.deepEqual(w, [{ kind: 'base-push', repo: R, base_ref: 'main', at: T }]);
  assert.deepEqual(prRecordWritesOf('push', push(R, 'refs/heads/ticket/x'), T), []);
  assert.deepEqual(prRecordWritesOf('push', push(R, 'refs/heads/main', 'develop'), T), []);
  assert.equal(prRecordWritesOf('push', push(R, 'refs/heads/develop', 'develop'), T)[0].base_ref, 'develop');
});
test('M8 event time: later than t -> t; a fraction is removed; garbage -> t', () => {
  const at = (u) => prRecordWritesOf('pull_request', prEvent(R, 'edited', 7, { updated_at: u }), T)[0].at;
  assert.equal(at('2026-10-22T13:00:00Z'), T);
  assert.equal(at('2026-10-22T11:00:00.123Z'), '2026-10-22T11:00:00Z');
  assert.equal(at('yesterday'), T);
  assert.equal(at(undefined), T);
});
test('M9 negatives: bad repo, bad numbers, and events the record does not read', () => {
  assert.deepEqual(prRecordWritesOf('pull_request', { ...prEvent(R, 'opened', 7), repository: {} }, T), []);
  assert.deepEqual(prRecordWritesOf('pull_request', { ...prEvent(R, 'opened', 7), repository: { full_name: 'no-slash' } }, T), []);
  for (const n of [0, '12', 1e10]) {
    assert.deepEqual(prRecordWritesOf('pull_request', { ...prEvent(R, 'opened', 7), number: n, pull_request: pr(n) }, T), [], String(n));
    assert.deepEqual(prRecordWritesOf('check_run', { ...checkRun(R, 'completed', []), check_run: { ...checkRun(R, 'completed', []).check_run, pull_requests: [{ number: n }] } }, T), [], String(n));
  }
  for (const ev of ['ping', 'issues', 'status', 'merge_group']) {
    assert.deepEqual(prRecordWritesOf(ev, { action: 'opened', repository: repository(R), state: 'success', sha: A, issue: { number: 1 } }, T), [], ev);
  }
  assert.deepEqual(prRecordWritesOf('pull_request', null, T), []);
});

// ── W: the writer on the real schema ──────────────────────────────────────────
test('W1 a pull_request write stores the fields with last_source webhook, webhook_at and refreshed_at = updated_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await recordPrRecord(o.env, T, 'pull_request', prEvent('o/bh8151-w1', 'opened', 1));
  assert.equal(r.written, 1);
  assert.equal(r.error, undefined);
  const row = rowOf(o.db, 'o/bh8151-w1', 1);
  assert.equal(row.last_source, 'webhook');
  assert.equal(row.webhook_at, ago(60));
  assert.equal(row.refreshed_at, ago(60));
  assert.equal(row.head_sha, A);
  assert.equal(row.state, 'open');
  assert.equal(row.mergeable_state, null);
  assert.equal(row.fields_at.mergeable_state, ago(60), 'case 2: mergeable_state is known to be unknown at that time');
  assert.deepEqual(row.labels, ['ai-build', 'tier-1']);
});

test('W2 two check names merge; an older delivery of a name never replaces a newer one; W2b a check leaves refreshed_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8151-w2';
  await api(o.env, 'PUT', '/api/pr-records', { repo, number: 2, source: 'fleet', at: ago(2000), fields: { state: 'open', head_sha: C } });
  await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [2]));
  await recordPrRecord(o.env, T, 'check_suite', checkSuite(repo, 'completed', [2]));
  let row = rowOf(o.db, repo, 2);
  assert.deepEqual(Object.keys(row.checks).sort(), ['suite:github-actions', 'test']);
  assert.equal(row.checks.test.conclusion, 'success');
  assert.equal(row.fields_at.checks, ago(100), 'fields_at.checks is the newest check time');
  assert.equal(row.refreshed_at, ago(2000), 'W2b: a check write does not move refreshed_at');
  assert.equal(row.webhook_at, ago(100));
  const older = await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [2], { conclusion: 'failure', completed_at: ago(500) }));
  assert.equal(older.written, 0);
  row = rowOf(o.db, repo, 2);
  assert.equal(row.checks.test.conclusion, 'success', 'the newer value stays');
  const newer = await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [2], { conclusion: 'failure', completed_at: ago(10) }));
  assert.equal(newer.written, 1);
  assert.equal(rowOf(o.db, repo, 2).checks.test.conclusion, 'failure');
  // a new row from a check write: refreshed_at = at
  await recordPrRecord(o.env, T, 'workflow_run', workflowRun(repo, 'completed', [3]));
  const r3 = rowOf(o.db, repo, 3);
  assert.equal(r3.refreshed_at, ago(90));
  assert.equal(r3.checks['workflow:harness-ci'].sha, C);
  assert.equal(r3.state, null);
});

test('W2c the checks object is capped at 100 names; an existing name still updates', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8151-w2c';
  const full = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`c${i}`, { status: 'completed', conclusion: 'success', sha: C, at: ago(900) }]));
  await api(o.env, 'PUT', '/api/pr-records', { repo, number: 4, source: 'fleet', at: ago(1000), fields: { checks: full } });
  const extra = await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [4], { name: 'c100' }));
  assert.equal(extra.written, 0);
  assert.equal(Object.keys(rowOf(o.db, repo, 4).checks).length, 100);
  const same = await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [4], { name: 'c5', conclusion: 'failure' }));
  assert.equal(same.written, 1);
  assert.equal(rowOf(o.db, repo, 4).checks.c5.conclusion, 'failure');
});

test('W3 a review sets review_decision; a comment sets labels and state and leaves refreshed_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8151-w3';
  await recordPrRecord(o.env, T, 'pull_request_review', review(repo, 'submitted', 5, 'APPROVED'));
  let row = rowOf(o.db, repo, 5);
  assert.equal(row.review_decision, 'approved');
  assert.equal(row.refreshed_at, ago(30));
  const before = row.refreshed_at;
  await recordPrRecord(o.env, T, 'issue_comment', comment(repo, 'created', 5, { merged: true }));
  row = rowOf(o.db, repo, 5);
  assert.deepEqual(row.labels, ['hold']);
  assert.equal(row.state, 'merged');
  assert.equal(row.refreshed_at, before, 'a comment write does not move refreshed_at');
  assert.equal(row.last_comment_id, null);
  await recordPrRecord(o.env, T, 'pull_request_review', review(repo, 'dismissed', 5, 'DISMISSED', { submitted_at: ago(15) }));
  assert.equal(rowOf(o.db, repo, 5).review_decision, null);
});

test('W4 a push to main nulls mergeable_state on open rows based on main only', async (t) => {
  const o = await fresh(t); if (!o) return;
  const put = (repo, n, state, base_ref) => api(o.env, 'PUT', '/api/pr-records', { repo, number: n, source: 'github', at: ago(100),
    fields: { state, base_ref, mergeable_state: 'clean' } });
  await put('o/bh8151-w4', 1, 'open', 'main');
  await put('o/bh8151-w4', 2, 'closed', 'main');
  await put('o/bh8151-w4', 3, 'open', 'develop');
  await put('o/bh8151-w4b', 4, 'open', 'main');
  const r = await recordPrRecord(o.env, T, 'push', push('o/bh8151-w4', 'refs/heads/main'));
  assert.equal(r.written, 1);
  const one = rowOf(o.db, 'o/bh8151-w4', 1);
  assert.equal(one.mergeable_state, null);
  assert.equal(one.fields_at.mergeable_state, T);
  assert.equal(one.last_source, 'webhook');
  assert.equal(one.refreshed_at, ago(100), 'a push does not move refreshed_at');
  assert.equal(rowOf(o.db, 'o/bh8151-w4', 2).mergeable_state, 'clean');
  assert.equal(rowOf(o.db, 'o/bh8151-w4', 3).mergeable_state, 'clean');
  assert.equal(rowOf(o.db, 'o/bh8151-w4b', 4).mergeable_state, 'clean');
});

test('W5 a fleet write at T+10 then a webhook with updated_at T: the fleet head_sha stays', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8151-w5';
  await api(o.env, 'PUT', '/api/pr-records', { repo, number: 6, source: 'fleet', at: ago(50), fields: { head_sha: B } });
  await recordPrRecord(o.env, T, 'pull_request', prEvent(repo, 'synchronize', 6, { updated_at: ago(60) }));
  const row = rowOf(o.db, repo, 6);
  assert.equal(row.head_sha, B, 'the newer fleet value stays');
  assert.equal(row.fields_at.head_sha, ago(50));
  assert.equal(row.base_sha, B);
  assert.equal(row.fields_at.base_sha, ago(60));
});

test('W6 a batch that throws: {written:0, error}, one warn, and the receiver still answers 200 with its wake row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const warns = [];
  t.mock.method(console, 'warn', (...a) => warns.push(a.join(' ')));
  // Every batch that carries a pr_records statement throws; the gate and wake batches run.
  const DB = {
    prepare: (sql) => Object.assign(o.DB.prepare(sql), { _sql: sql }),
    batch: async (stmts) => {
      if (stmts.some((s) => /pr_records/.test(s._sql || ''))) throw new Error('D1_ERROR: overloaded (fixture)');
      return o.DB.batch(stmts);
    },
  };
  const env = { ...o.env, DB };
  const r = await recordPrRecord(env, T, 'pull_request', prEvent('o/bh8151-w6', 'opened', 1));
  assert.equal(r.written, 0);
  assert.match(r.error, /overloaded/);
  assert.equal(warns.filter((w) => w.includes('[pr-record-intake]')).length, 1);
  const h = await hook(env, 'pull_request', prEvent('o/bh8151-w6', 'opened', 1));
  assert.equal(h.status, 200, JSON.stringify(h.body));
  assert.equal(h.body.ok, true);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM wakes WHERE repo = 'o/bh8151-w6'").get().n, 1);
  assert.equal(count(o.db), 0, 'the record write failed, nothing committed');
});

test('W7 a replay commits the same row; the check merge and the base push change 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8151-w7';
  await recordPrRecord(o.env, T, 'pull_request', prEvent(repo, 'opened', 7, { mergeable_state: 'clean' }));
  await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [7]));
  await recordPrRecord(o.env, T, 'push', push(repo, 'refs/heads/main'));
  const before = rowOf(o.db, repo, 7);
  await recordPrRecord(o.env, T, 'pull_request', prEvent(repo, 'opened', 7, { mergeable_state: 'clean' }));
  const c = await recordPrRecord(o.env, T, 'check_run', checkRun(repo, 'completed', [7]));
  const p = await recordPrRecord(o.env, T, 'push', push(repo, 'refs/heads/main'));
  assert.equal(c.written, 0);
  assert.equal(p.written, 0);
  const after = rowOf(o.db, repo, 7);
  // the replayed opened carries mergeable_state clean at updated_at, older than the push: the push NULL stays
  assert.deepEqual(after, before);
  assert.equal(after.mergeable_state, null);
});

// ── X: EXPLAIN on 5,000 rows ──────────────────────────────────────────────────
async function seeded(t) {
  const o = await fresh(t); if (!o) return null;
  const { db } = o;
  const STATES = ['open', 'closed', 'merged', null];
  db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, ts = ago(i * 3600);
      vals.push('(?,?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 40}`, i + 1, STATES[i % 4], i % 3 ? 'main' : 'develop', '{}', ts, ts);
    }
    db.prepare(`INSERT INTO pr_records (repo, number, state, base_ref, fields_at, created_at, refreshed_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(count(db), 5000);
  return o;
}
function check(db, sql, binds, indexes) {
  const p = plan(db, sql, ...binds);
  assert.deepEqual(fullScans(p, ['pr_records']), [], p.join(' | '));
  assert.ok(p.some((l) => indexes.some((i) => l.includes(i))), `${indexes} not in: ${p.join(' | ')}`);
  return p;
}
test('X1 the check upsert and the fields upsert use ux_pr_records_repo_number on 5,000 rows', async (t) => {
  const o = await seeded(t); if (!o) return;
  const v = JSON.stringify({ status: 'completed', conclusion: 'success', sha: C, at: T });
  // The conflict target is the unique index: the upsert succeeds on an existing row, so SQLite found it there.
  for (const [sql, binds] of [
    [CHECK_MERGE_SQL, ['o/repo-7', 4008, 'test', v, T, '$."test"']],
    [upsertSql(['state', 'labels'], { refresh: false }), ['o/repo-7', 4008, T, 'webhook', 'open', '[]']],
  ]) {
    assert.deepEqual(fullScans(plan(o.db, sql, ...binds), ['pr_records']), [], sql);
    const before = count(o.db);
    o.db.prepare(sql).run(...binds);
    assert.equal(count(o.db), before, 'the upsert hit the existing (repo, number) row');
  }
  const idx = o.db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='pr_records' AND sql LIKE '%UNIQUE%'").all().map((r) => r.name);
  assert.deepEqual(idx, ['ux_pr_records_repo_number'], 'the only unique index, so the only conflict target');
  assert.equal(rowOf(o.db, 'o/repo-7', 4008).checks.test.sha, C);
});
test('X2 BASE_PUSH_SQL uses an index of pr_records and no SCAN on 5,000 rows', async (t) => {
  const o = await seeded(t); if (!o) return;
  check(o.db, BASE_PUSH_SQL, ['o/repo-7', 'main', T], ['idx_pr_records_state_refreshed', 'ux_pr_records_repo_number']);
});

// ── R: the receiver ───────────────────────────────────────────────────────────
test('R1 a signed pull_request.opened writes the row; the response keys are unchanged', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await hook(o.env, 'pull_request', prEvent('o/bh8151-r1', 'opened', 11));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body).sort(), ['as_of', 'duplicate', 'ok', 'vendor', 'wake']);
  const row = rowOf(o.db, 'o/bh8151-r1', 11);
  assert.equal(row.head_sha, A);
  assert.equal(row.last_source, 'webhook');
});
test('R2 a signed check_run.created (wakeOf drops it) writes the check and still answers 202 ignored', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await hook(o.env, 'check_run', checkRun('o/bh8151-r2', 'created', [12]));
  assert.equal(r.status, 202, JSON.stringify(r.body));
  assert.equal(r.body.ignored, 'check_run');
  assert.equal(rowOf(o.db, 'o/bh8151-r2', 12).checks.test.status, 'in_progress');
});
test('R3 ping answers pong and writes no row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await hook(o.env, 'ping', { zen: 'x', repository: repository('o/bh8151-r3') });
  assert.equal(r.status, 200);
  assert.equal(r.body.pong, true);
  assert.equal(count(o.db), 0);
});
test('R4 an unsigned delivery is a 401 and writes no row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await hook(o.env, 'pull_request', prEvent('o/bh8151-r4', 'opened', 14), { sig: 'sha256=' + '0'.repeat(64) });
  assert.equal(r.status, 401);
  assert.equal(count(o.db), 0);
});
