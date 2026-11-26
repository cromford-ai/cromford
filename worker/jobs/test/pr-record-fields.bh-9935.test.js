// BH-9935 (BH-9926.3): four more fields on the PR record. Commit statuses,
// the newest Mergify queue payload, the head commit time and the PR file list.
// Driven through the REAL worker.fetch (signed POST /webhooks/github, PUT and
// GET /api/pr-records) on node:sqlite with the composed jobs schema. Each case
// opens its own fresh DB and uses its own repo.
//   V0  ensureColumns adds the 4 columns and the 2 indexes; a second call is a no-op
//   S1  status deliveries for the head store {state, description, sha, at} per context
//   S2  an older status does not replace a newer one; a replay changes 0 rows
//   S3  a status for another sha leaves the record unchanged
//   S4  a context with a quote writes nothing; the 101st context is refused, an existing one still updates
//   S5  a status before any record: 0 rows, no error
//   S6  two open records with the same head both get the entry
//   M1  a Mergify payload comment stores {state, code, draft_pr, failing_checks, left_sha, comment_id, at}
//   M2  an edit of an older comment does not replace a newer one; an edit of the newest does
//   M3  a person quoting the markers: NULL. M4 no markers: NULL. M5 an array / bad JSON: NULL.
//   M6  deleted: no write. M7 `mergify` without [bot]: no write. M8 the row holds no body text
//   H1  a push to the PR branch stores head_commit {sha, at (UTC)}
//   H2  an older pushed_at does not replace; H2b a newer pushed_at with an older commit time replaces
//   H3  pull_request.synchronize writes no head_commit; H4 a push to main keeps the base push, no head_commit
//   H5  a push with no record: 0 rows; H6 deleted:true: no write
//   P1  PUT files: good is stored; a bad sha, non-string paths, 3,001 paths are 400 files
//   P2  PUT head_commit: good / a bad at is 400
//   G1  GET returns the 4 fields parsed
//   D1  the decision table of fieldWritesOf
//   RT  the shell writers' PUT bodies (shared fixture) round-trip through PUT + GET
//   X1  5,000 rows: the 3 write statements use their index, no SCAN
//   E1  recordPrRecord with a malformed status returns {written:0} and does not throw
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { ensureColumns, ensureTable } from '../src/lib/core.js';
import { CHECKS_MAX } from '../src/routes/pr-records.js';
import { recordPrRecord, prRecordWritesOf } from '../src/lib/pr-record-intake.js';
import { STATUS_MERGE_SQL, MERGIFY_SQL, HEAD_PUSH_SQL, fieldWritesOf } from '../src/lib/pr-record-fields.js';

const SECRET = 'tok-fixture-bh9935';
const GH = 'gh-fixture-bh9935';
const NOW_MS = Date.parse('2026-11-24T12:00:00Z');
const T = '2026-11-24T12:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40), C = 'c'.repeat(40);
const FIX = new URL('./fixtures/', import.meta.url);

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: GH } };
}
async function api(env, method, path, body) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
let dn = 0;
async function hook(env, event, payload) {
  const body = JSON.stringify(payload);
  dn += 1;
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-9935-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const rowOf = (db, repo, n) => db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const jsonOf = (db, repo, n, col) => { const r = rowOf(db, repo, n); return r && r[col] !== null ? JSON.parse(r[col]) : null; };
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n;
const put = (env, repo, number, fields, extra = {}) => api(env, 'PUT', '/api/pr-records', { repo, number, source: 'fleet', fields, ...extra });
const openRecord = (env, repo, number, head = A, headRef = `ticket/x-${number}`) =>
  put(env, repo, number, { state: 'open', head_sha: head, head_ref: headRef, base_ref: 'main' }, { at: ago(3600) });

const statusEvent = (repo, sha, context, state, updatedAt, description = `${context} ${state}`) => ({
  id: 1, sha, name: repo, context, state, description, target_url: null,
  created_at: updatedAt, updated_at: updatedAt, repository: { full_name: repo, default_branch: 'main' },
});
// The Mergify comment as the BH-8186 failed-batch suite builds it (tests/mc-failed-batch.bh-8186-test.sh `cmt`).
const mergifyBody = (payloadText, draft, leftSha, check) =>
  `<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n${payloadText}\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n`
  + `- ❌ **Checks failed** — \`2026-11-24 10:30 UTC\` · on draft #${draft}\n`
  + `- 🚫 **Left the queue** — \`2026-11-24 11:06 UTC\` · at \`${leftSha}\`\n\n## Reason\n\nFailing checks:\n- ❌ [\`${check}\`](https://x/runs/1)\n`;
const dequeued = (code, checks) => JSON.stringify({ version: 1, state: 'dequeued', dequeue_reason: { code, checks } });
const commentEvent = (repo, n, action, { id, login = 'mergify[bot]', createdAt, updatedAt, body }) => ({
  action, repository: { full_name: repo },
  issue: { number: n, state: 'open', labels: [], updated_at: updatedAt || createdAt, pull_request: { url: 'x' } },
  comment: { id, user: { login, type: login.endsWith('[bot]') ? 'Bot' : 'User' }, created_at: createdAt, updated_at: updatedAt || createdAt, body },
});
const epoch = (iso) => Math.floor(Date.parse(iso) / 1000);
const pushEvent = (repo, branch, sha, commitTs, pushedAt, o = {}) => ({
  ref: `refs/heads/${branch}`, before: C, after: sha, deleted: false,
  head_commit: sha ? { id: sha, timestamp: commitTs, message: 'x' } : null,
  repository: { full_name: repo, default_branch: 'main', pushed_at: epoch(pushedAt) }, ...o,
});

// ── V ───────────────────────────────────────────────────────────────────────────
test('V0 ensureColumns adds statuses, mergify_queue, head_commit, files and the 2 indexes; a second call is a no-op', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ensureTable(o.env, 'pr_records');
  const cols = () => o.db.prepare('PRAGMA table_info(pr_records)').all().map((r) => r.name);
  const NEW = ['statuses', 'mergify_queue', 'head_commit', 'files'];
  for (const c of NEW) assert.ok(!cols().includes(c), `${c} is not in the BH-8067 CREATE`);
  await ensureColumns(o.env, 'pr_records');
  for (const c of NEW) assert.ok(cols().includes(c), `${c} after ensureColumns: ${cols()}`);
  const idx = (name) => o.db.prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name=?").get(name);
  assert.match(idx('idx_pr_records_repo_head_sha').sql, /pr_records\s*\(\s*repo,\s*head_sha\s*\)/);
  assert.match(idx('idx_pr_records_repo_head').sql, /pr_records\s*\(\s*repo,\s*head_ref\s*\)/);
  const before = cols().length;
  await ensureColumns({ DB: { prepare: (s) => o.DB.prepare(s), batch: (x) => o.DB.batch(x) } }, 'pr_records');
  assert.equal(cols().length, before);
});

// ── S: status ───────────────────────────────────────────────────────────────────
test('S1 status deliveries for the head store state, description, sha and time per context', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-s1';
  assert.equal((await openRecord(o.env, repo, 1)).status, 200);
  for (const [ctx, st, at, desc] of [['lead-verdict', 'success', ago(300), 'APPROVE'],
    ['prequeue-verdict', 'pending', ago(200), 'running'], ['ci/x', 'failure', ago(100), 'red']]) {
    const r = await hook(o.env, 'status', statusEvent(repo, A.toUpperCase(), ctx, st, at, desc));
    assert.ok([200, 202].includes(r.status), JSON.stringify(r.body));
  }
  const g = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&number=1`);
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.row.statuses, {
    'lead-verdict': { state: 'success', description: 'APPROVE', sha: A, at: ago(300) },
    'prequeue-verdict': { state: 'pending', description: 'running', sha: A, at: ago(200) },
    'ci/x': { state: 'failure', description: 'red', sha: A, at: ago(100) },
  });
  assert.equal(g.body.row.fields_at.statuses, ago(100));
});

test('S2 an older status does not replace a newer one; a replay changes 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-s2';
  await openRecord(o.env, repo, 1);
  await hook(o.env, 'status', statusEvent(repo, A, 'lead-verdict', 'success', ago(100), 'APPROVE'));
  await hook(o.env, 'status', statusEvent(repo, A, 'lead-verdict', 'failure', ago(500), 'BLOCK'));
  assert.deepEqual(jsonOf(o.db, repo, 1, 'statuses')['lead-verdict'], { state: 'success', description: 'APPROVE', sha: A, at: ago(100) });
  const ev = statusEvent(repo, A, 'lead-verdict', 'success', ago(100), 'APPROVE');
  const again = await recordPrRecord(o.env, T, 'status', ev);
  assert.deepEqual(again, { written: 0 }, 'a replay changes 0 rows');
  const newer = await recordPrRecord(o.env, T, 'status', statusEvent(repo, A, 'lead-verdict', 'failure', ago(50), 'BLOCK'));
  assert.equal(newer.written, 1);
  assert.equal(jsonOf(o.db, repo, 1, 'statuses')['lead-verdict'].state, 'failure');
});

test('S3 a status for another sha leaves the record unchanged', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-s3';
  await openRecord(o.env, repo, 1);
  const before = rowOf(o.db, repo, 1);
  const r = await recordPrRecord(o.env, T, 'status', statusEvent(repo, B, 'lead-verdict', 'success', ago(100)));
  assert.deepEqual(r, { written: 0 });
  assert.deepEqual(rowOf(o.db, repo, 1), before);
});

test('S4 a context with a quote writes nothing; the 101st context is refused; an existing one still updates', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-s4';
  await openRecord(o.env, repo, 1);
  assert.deepEqual(await recordPrRecord(o.env, T, 'status', statusEvent(repo, A, 'a"b', 'success', ago(100))), { written: 0 });
  assert.equal(rowOf(o.db, repo, 1).statuses, null);
  const full = Object.fromEntries(Array.from({ length: CHECKS_MAX }, (_, i) => [`c${i}`, { state: 'success', description: null, sha: A, at: ago(900) }]));
  assert.equal((await put(o.env, repo, 1, { statuses: full })).status, 200);
  assert.deepEqual(await recordPrRecord(o.env, T, 'status', statusEvent(repo, A, 'c-new', 'success', ago(100))), { written: 0 });
  assert.ok(!('c-new' in jsonOf(o.db, repo, 1, 'statuses')));
  assert.equal((await recordPrRecord(o.env, T, 'status', statusEvent(repo, A, 'c7', 'failure', ago(100)))).written, 1);
  assert.equal(jsonOf(o.db, repo, 1, 'statuses').c7.state, 'failure');
  assert.equal(Object.keys(jsonOf(o.db, repo, 1, 'statuses')).length, CHECKS_MAX);
});

test('S5 a status before any record: 0 rows, no error, no row made', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await recordPrRecord(o.env, T, 'status', statusEvent('o/bh9935-s5', A, 'lead-verdict', 'success', ago(100)));
  assert.deepEqual(r, { written: 0 });
  assert.equal(count(o.db), 0);
});

test('S6 two open records with the same head both get the entry', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-s6';
  await openRecord(o.env, repo, 1); await openRecord(o.env, repo, 2);
  await openRecord(o.env, repo, 3, B);
  const r = await recordPrRecord(o.env, T, 'status', statusEvent(repo, A, 'lead-verdict', 'success', ago(100)));
  assert.equal(r.written, 2);
  for (const n of [1, 2]) assert.equal(jsonOf(o.db, repo, n, 'statuses')['lead-verdict'].sha, A);
  assert.equal(rowOf(o.db, repo, 3).statuses, null);
});

// ── M: Mergify ──────────────────────────────────────────────────────────────────
test('M1 a Mergify payload comment stores code, draft PR, failing checks, left sha, comment id and time', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-m1';
  await openRecord(o.env, repo, 5);
  const body = mergifyBody(dequeued('CHECKS_FAILED', ['lint']), 8165, C.slice(0, 12).toUpperCase(), 'lint');
  const r = await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 6366196632, createdAt: ago(600) }));
  assert.ok(r.status < 300);
  assert.equal(rowOf(o.db, repo, 5).mergify_queue, null, 'no body, no payload: no write');
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 6366196632, createdAt: ago(600), body }));
  // BH-9938 C1: the left sha follows dqw_parse_payload_md (40 hex, lower
  // case), so a 12-character upper-case sha is not read; updated_at is the
  // comment's edit time (created_at here).
  assert.deepEqual(jsonOf(o.db, repo, 5, 'mergify_queue'), {
    state: 'dequeued', code: 'CHECKS_FAILED', draft_pr: 8165, failing_checks: ['lint'],
    left_sha: null, comment_id: 6366196632, at: ago(600), run_id: null, updated_at: ago(600),
  });
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').left_sha, null);
  // P9 of the BH-8186 suite: no checks in the payload, the Failing checks bullets.
  const noChecks = mergifyBody(JSON.stringify({ state: 'dequeued', dequeue_reason: { code: 'CHECKS_FAILED' } }), 900, C, 'Jobs worker — routes');
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 6366196700, createdAt: ago(500), body: noChecks }));
  assert.deepEqual(jsonOf(o.db, repo, 5, 'mergify_queue').failing_checks, ['Jobs worker — routes']);
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').draft_pr, 900);
  // Object checks ({name}) and a queued payload with no reason.
  const objs = mergifyBody(JSON.stringify({ state: 'dequeued', dequeue_reason: { code: 'X', checks: [{ name: 'a' }, 'b', 7] } }), 1, C, 'z');
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 6366196701, createdAt: ago(400), body: objs }));
  // BH-9938 C1: the names come from the bullets, as dqw_parse_payload_md reads them.
  assert.deepEqual(jsonOf(o.db, repo, 5, 'mergify_queue').failing_checks, ['z']);
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').left_sha, C);
  const queued = '-*- Mergify Payload -*-\n{"state":"queued"}\n-*- Mergify Payload End -*-\nQueued';
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 6366196702, createdAt: ago(300), body: queued }));
  assert.deepEqual(jsonOf(o.db, repo, 5, 'mergify_queue'), {
    state: 'queued', code: null, draft_pr: null, failing_checks: [], left_sha: null, comment_id: 6366196702, at: ago(300), run_id: null,
    updated_at: ago(300),
  });
});

test('M2 an edit of an older comment does not replace a newer one; an edit of the newest does', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-m2';
  await openRecord(o.env, repo, 5);
  const c1 = { id: 100, createdAt: ago(900), body: mergifyBody(dequeued('BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS', ['old']), 8165, C, 'old') };
  const c2 = { id: 50, createdAt: ago(300), body: mergifyBody(dequeued('CHECKS_FAILED', ['new']), 8200, C, 'new') };
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', c1));
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', c2));
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').comment_id, 50);
  const edit1 = await recordPrRecord(o.env, T, 'issue_comment', commentEvent(repo, 5, 'edited', { ...c1, updatedAt: ago(10),
    body: mergifyBody(dequeued('CONFLICT_WITH_BASE_BRANCH', ['old2']), 8300, C, 'old2') }));
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').comment_id, 50, 'the newer comment by created_at is kept');
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').code, 'CHECKS_FAILED');
  assert.ok(edit1.written >= 0);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'edited', { ...c2, updatedAt: ago(5),
    body: mergifyBody(dequeued('PR_MANUALLY_DEQUEUED', ['new2']), 8201, C, 'new2') }));
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').code, 'PR_MANUALLY_DEQUEUED', 'an edit of the newest comment replaces it');
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').draft_pr, 8201);
});

test('M3-M8 the Mergify matcher refuses people, no markers, bad payloads, deletes, a bare login, and never stores a body', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-m3';
  const SENTINEL = 'BODY-SENTINEL-9935';
  const good = mergifyBody(dequeued('CHECKS_FAILED', ['lint']), 8165, C, `lint ${SENTINEL}`);
  const cases = [
    ['M3 a person', 1, 'created', { id: 1, login: 'operator', createdAt: ago(100), body: good }],
    ['M4 no markers', 2, 'created', { id: 2, createdAt: ago(100), body: `Queued ${SENTINEL}` }],
    ['M5 an array', 3, 'created', { id: 3, createdAt: ago(100), body: mergifyBody('[1,2]', 1, C, 'x') }],
    ['M5 not JSON', 4, 'created', { id: 4, createdAt: ago(100), body: mergifyBody('{state: dequeued', 1, C, 'x') }],
    ['M6 deleted', 5, 'deleted', { id: 5, createdAt: ago(100), body: good }],
    ['M7 no [bot]', 6, 'created', { id: 6, login: 'mergify', createdAt: ago(100), body: good }],
    ['M7 Mergify[bot]', 7, 'created', { id: 7, login: 'Mergify[bot]', createdAt: ago(100), body: good }],
  ];
  for (const [name, n, action, c] of cases) {
    await openRecord(o.env, repo, n);
    await hook(o.env, 'issue_comment', commentEvent(repo, n, action, c));
    assert.equal(rowOf(o.db, repo, n).mergify_queue, null, name);
  }
  await openRecord(o.env, repo, 8);
  await hook(o.env, 'issue_comment', commentEvent(repo, 8, 'created', { id: 8, createdAt: ago(100), body: good }));
  assert.notEqual(rowOf(o.db, repo, 8).mergify_queue, null, 'the same body from mergify[bot] is stored');
  const all = JSON.stringify(o.db.prepare('SELECT * FROM pr_records').all());
  assert.ok(!all.includes('Merge Queue Status'), 'M8: no column holds the comment body');
  assert.ok(!all.includes('DO NOT EDIT'), 'M8: no column holds the comment body');
});

// ── H: head commit time ─────────────────────────────────────────────────────────
test('H1 a push to the PR branch stores head_commit {sha, at} in UTC', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-h1';
  await openRecord(o.env, repo, 1, A, 'ticket/x');
  const r = await hook(o.env, 'push', pushEvent(repo, 'ticket/x', B.toUpperCase(), '2026-11-24T13:00:00+02:00', ago(60)));
  assert.ok(r.status < 300, JSON.stringify(r.body));
  assert.deepEqual(jsonOf(o.db, repo, 1, 'head_commit'), { sha: B, at: '2026-11-24T11:00:00Z' });
  assert.equal(JSON.parse(rowOf(o.db, repo, 1).fields_at).head_commit, ago(60));
});

test('H2 an older pushed_at does not replace; H2b a newer pushed_at with an older commit time replaces', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-h2';
  await openRecord(o.env, repo, 1, A, 'ticket/x');
  await hook(o.env, 'push', pushEvent(repo, 'ticket/x', B, '2026-11-24T11:00:00Z', ago(60)));
  const older = await recordPrRecord(o.env, T, 'push', pushEvent(repo, 'ticket/x', C, '2026-11-24T11:30:00Z', ago(600)));
  assert.deepEqual(older, { written: 0 });
  assert.equal(jsonOf(o.db, repo, 1, 'head_commit').sha, B);
  const rebase = await recordPrRecord(o.env, T, 'push', pushEvent(repo, 'ticket/x', C, '2026-11-20T09:00:00Z', ago(30)));
  assert.equal(rebase.written, 1);
  assert.deepEqual(jsonOf(o.db, repo, 1, 'head_commit'), { sha: C, at: '2026-11-20T09:00:00Z' });
  assert.deepEqual(await recordPrRecord(o.env, T, 'push', pushEvent(repo, 'ticket/x', C, '2026-11-20T09:00:00Z', ago(30))), { written: 0 }, 'a replay changes 0 rows');
});

test('H3-H6 synchronize, a push to main, no record and a delete write no head_commit', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-h3';
  await openRecord(o.env, repo, 1, A, 'ticket/x');
  await put(o.env, repo, 1, { mergeable_state: 'clean' });
  await hook(o.env, 'pull_request', { action: 'synchronize', number: 1, repository: { full_name: repo, default_branch: 'main' },
    pull_request: { number: 1, state: 'open', updated_at: ago(50), head: { ref: 'ticket/x', sha: B }, base: { ref: 'main', sha: C } } });
  assert.equal(rowOf(o.db, repo, 1).head_sha, B);
  assert.equal(rowOf(o.db, repo, 1).head_commit, null, 'H3: a pull_request delivery carries no commit time');
  await put(o.env, repo, 1, { mergeable_state: 'clean' }, { at: ago(40) });
  await hook(o.env, 'push', pushEvent(repo, 'main', C, '2026-11-24T11:00:00Z', ago(30)));
  assert.equal(rowOf(o.db, repo, 1).mergeable_state, null, 'H4: the base push still nulls mergeable_state');
  assert.equal(rowOf(o.db, repo, 1).head_commit, null, 'H4: a push to main is not a head push');
  assert.deepEqual(await recordPrRecord(o.env, T, 'push', pushEvent(repo, 'ticket/none', C, '2026-11-24T11:00:00Z', ago(30))), { written: 0 }, 'H5');
  await recordPrRecord(o.env, T, 'push', pushEvent(repo, 'ticket/x', null, null, ago(20), { deleted: true, after: '0'.repeat(40) }));
  assert.equal(rowOf(o.db, repo, 1).head_commit, null, 'H6');
});

// ── P / G: PUT and GET ──────────────────────────────────────────────────────────
test('P1 PUT files stores the sorted unique list; a bad sha, non-string paths and 3,001 paths are 400 files', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-p1';
  const ok = await put(o.env, repo, 1, { files: { sha: A.toUpperCase(), paths: ['b.sh', 'a.md', 'b.sh'] } });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(ok.body.row.files, { sha: A, paths: ['a.md', 'b.sh'] });
  for (const files of [{ sha: 'abc1234', paths: [] }, { sha: A, paths: [1] }, { sha: A, paths: [''] },
    { sha: A, paths: Array.from({ length: 3001 }, (_, i) => `f${i}`) }, { sha: A, paths: [], extra: 1 }, { sha: A }, []]) {
    const r = await put(o.env, repo, 2, { files });
    assert.equal(r.status, 400, JSON.stringify(files).slice(0, 60));
    assert.deepEqual(r.body, { error: 'invalid_field', field: 'files' });
  }
  const edge = await put(o.env, repo, 3, { files: { sha: A, paths: Array.from({ length: 3000 }, (_, i) => `f${i}`) } });
  assert.equal(edge.status, 200, '3,000 paths is GitHub\'s cap, accepted');
});

test('P2 PUT head_commit: good is stored; a bad at or sha is 400 head_commit; statuses and mergify_queue are checked', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-p2';
  const ok = await put(o.env, repo, 1, { head_commit: { sha: A, at: ago(60) } });
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.row.head_commit, { sha: A, at: ago(60) });
  for (const hc of [{ sha: A, at: 'yesterday' }, { sha: A, at: '2026-11-24T11:00:00.5Z' }, { sha: 'x', at: ago(1) }, { sha: A }]) {
    const r = await put(o.env, repo, 2, { head_commit: hc });
    assert.deepEqual(r.body, { error: 'invalid_field', field: 'head_commit' }, JSON.stringify(hc));
  }
  const badStatus = await put(o.env, repo, 2, { statuses: { x: { state: 'queued', description: null, sha: A, at: ago(1) } } });
  assert.deepEqual(badStatus.body, { error: 'invalid_field', field: 'statuses' });
  const badMq = await put(o.env, repo, 2, { mergify_queue: { state: 'dequeued' } });
  assert.deepEqual(badMq.body, { error: 'invalid_field', field: 'mergify_queue' });
});

test('G1 GET returns statuses, mergify_queue, head_commit and files parsed', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9935-g1';
  const mq = { state: 'dequeued', code: 'CHECKS_FAILED', draft_pr: 9, failing_checks: ['lint'], left_sha: C, comment_id: 3, at: ago(10) };
  const st = { 'lead-verdict': { state: 'success', description: 'APPROVE', sha: A, at: ago(20) } };
  const r = await put(o.env, repo, 1, { statuses: st, mergify_queue: mq, head_commit: { sha: A, at: ago(30) }, files: { sha: A, paths: ['x'] } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const g = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&number=1`);
  assert.deepEqual(g.body.row.statuses, st);
  assert.deepEqual(g.body.row.mergify_queue, mq);
  assert.deepEqual(g.body.row.head_commit, { sha: A, at: ago(30) });
  assert.deepEqual(g.body.row.files, { sha: A, paths: ['x'] });
});

// ── D: the decision table ───────────────────────────────────────────────────────
test('D1 fieldWritesOf: the decision table', () => {
  const repo = 'o/bh9935-d1';
  const mq = mergifyBody(dequeued('CHECKS_FAILED', ['lint']), 8165, C, 'lint');
  const kinds = (event, p) => fieldWritesOf(event, p, T, CHECKS_MAX).map((w) => w.kind);
  const rows = [
    ['status success lead-verdict', 'status', statusEvent(repo, A, 'lead-verdict', 'success', ago(10)), ['status']],
    ['status pending', 'status', statusEvent(repo, A, 'prequeue-verdict', 'pending', ago(10)), ['status']],
    ['status short sha', 'status', statusEvent(repo, 'abc1234', 'lead-verdict', 'success', ago(10)), []],
    ['status context a"b', 'status', statusEvent(repo, A, 'a"b', 'success', ago(10)), []],
    ['status state queued', 'status', statusEvent(repo, A, 'x', 'queued', ago(10)), []],
    ['mergify created', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, createdAt: ago(10), body: mq }), ['mergify']],
    ['mergify edited', 'issue_comment', commentEvent(repo, 5, 'edited', { id: 1, createdAt: ago(10), body: mq }), ['mergify']],
    ['mergify deleted', 'issue_comment', commentEvent(repo, 5, 'deleted', { id: 1, createdAt: ago(10), body: mq }), []],
    ['mergify no markers', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, createdAt: ago(10), body: 'Queued' }), []],
    ['a person quoting', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, login: 'operator', createdAt: ago(10), body: mq }), []],
    ['Mergify[bot]', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, login: 'Mergify[bot]', createdAt: ago(10), body: mq }), []],
    ['mergify (no [bot])', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, login: 'mergify', createdAt: ago(10), body: mq }), []],
    ['payload array', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, createdAt: ago(10), body: mergifyBody('[1,2]', 1, C, 'x') }), []],
    ['payload not JSON', 'issue_comment', commentEvent(repo, 5, 'created', { id: 1, createdAt: ago(10), body: mergifyBody('{x', 1, C, 'x') }), []],
    ['on an issue', 'issue_comment', { ...commentEvent(repo, 5, 'created', { id: 1, createdAt: ago(10), body: mq }), issue: { number: 5, state: 'open' } }, []],
    ['push ticket branch', 'push', pushEvent(repo, 'ticket/bh-1', A, ago(100), ago(10)), ['head-push']],
    ['push main', 'push', pushEvent(repo, 'main', A, ago(100), ago(10)), []],
    ['push deleted', 'push', pushEvent(repo, 'ticket/bh-1', null, null, ago(10), { deleted: true }), []],
    ['push tag', 'push', { ...pushEvent(repo, 'x', A, ago(100), ago(10)), ref: 'refs/tags/v1' }, []],
    ['pull_request.synchronize', 'pull_request', { action: 'synchronize', number: 1, repository: { full_name: repo },
      pull_request: { number: 1, head: { ref: 'x', sha: A }, base: { ref: 'main', sha: B } } }, []],
  ];
  for (const [name, event, p, want] of rows) assert.deepEqual(kinds(event, p), want, name);
  // The intake returns them after its own writes (the base push stays on main).
  assert.deepEqual(prRecordWritesOf('push', pushEvent(repo, 'main', A, ago(100), ago(10)), T).map((w) => w.kind), ['base-push']);
  assert.deepEqual(prRecordWritesOf('issue_comment', commentEvent(repo, 5, 'created', { id: 1, createdAt: ago(10), body: mq }), T).map((w) => w.kind), ['fields', 'mergify']);
  assert.deepEqual(prRecordWritesOf('status', statusEvent(repo, A, 'lead-verdict', 'success', ago(10)), T).map((w) => w.kind), ['status']);
  // A future time is clamped to the worker's clock.
  const fut = fieldWritesOf('status', statusEvent(repo, A, 'x', 'success', '2027-01-01T00:00:00Z'), T, CHECKS_MAX)[0];
  assert.equal(fut.at, T);
});

// ── RT: the shell writers' bodies ───────────────────────────────────────────────
test('RT the PUT bodies the shell writers build round-trip through PUT and GET', async (t) => {
  const o = await fresh(t); if (!o) return;
  const fx = JSON.parse(readFileSync(new URL('pr-record-files.bh-9935.json', FIX), 'utf8'));
  for (const key of ['files_put', 'head_commit_put']) {
    const body = fx[key];
    const r = await api(o.env, 'PUT', '/api/pr-records', body);
    assert.equal(r.status, 200, `${key}: ${JSON.stringify(r.body)}`);
    const g = await api(o.env, 'GET', `/api/pr-records?repo=${body.repo}&number=${body.number}`);
    const col = Object.keys(body.fields)[0];
    assert.deepEqual(g.body.row[col], body.fields[col], key);
  }
  const up = await api(o.env, 'PUT', '/api/pr-records', { ...fx.files_put, fields: { files: { ...fx.files_put.fields.files, sha: A.toUpperCase() } } });
  assert.equal(up.body.row.files.sha, A, 'the sha is stored lowercase, so the 40-hex compare of the reader holds');
});

// ── X: plans at volume ──────────────────────────────────────────────────────────
test('X1 STATUS_MERGE_SQL, HEAD_PUSH_SQL and MERGIFY_SQL use their index and no SCAN on 5,000 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ensureTable(o.env, 'pr_records');
  await ensureColumns(o.env, 'pr_records');
  const STATES = ['open', 'closed', 'merged', null];
  o.db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, ts = ago(i * 600);
      vals.push('(?,?,?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 40}`, i + 1, STATES[i % 4], i.toString(16).padStart(40, '0'), `ticket/x-${i}`, '{}', ts, ts);
    }
    o.db.prepare(`INSERT INTO pr_records (repo, number, state, head_sha, head_ref, fields_at, created_at, refreshed_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  assert.equal(count(o.db), 5000);
  const check = (sql, binds, index) => {
    const p = plan(o.db, sql, ...binds);
    assert.deepEqual(fullScans(p, ['pr_records']), [], p.join(' | '));
    assert.ok(p.some((l) => l.includes(index)), `${index} not in: ${p.join(' | ')}`);
  };
  const sv = JSON.stringify({ state: 'success', description: null, sha: A, at: T });
  check(STATUS_MERGE_SQL, ['o/repo-7', (7).toString(16).padStart(40, '0'), '$."x"', sv, T, CHECKS_MAX], 'idx_pr_records_repo_head_sha');
  check(HEAD_PUSH_SQL, ['o/repo-7', 'ticket/x-7', JSON.stringify({ sha: A, at: T }), T], 'idx_pr_records_repo_head');
  const mv = JSON.stringify({ state: 'queued', code: null, draft_pr: null, failing_checks: [], left_sha: null, comment_id: 1, at: T });
  assert.deepEqual(fullScans(plan(o.db, MERGIFY_SQL, 'o/repo-7', 8, mv, T, 1), ['pr_records']), []);
  const before = count(o.db);
  o.db.prepare(MERGIFY_SQL).run('o/repo-7', 8, mv, T, 1);
  assert.equal(count(o.db), before, 'the Mergify upsert hit the existing (repo, number) row through ux_pr_records_repo_number');
  assert.equal(JSON.parse(rowOf(o.db, 'o/repo-7', 8).mergify_queue).comment_id, 1);
});

// ── E: never throws ─────────────────────────────────────────────────────────────
test('E1 recordPrRecord with a malformed status returns {written:0} and does not throw', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const p of [{ repository: { full_name: 'o/bh9935-e1' }, sha: 7, context: null, state: {} },
    { repository: { full_name: 'o/bh9935-e1' } }, null, 'x']) {
    const r = await recordPrRecord(o.env, T, 'status', p);
    assert.deepEqual(r, { written: 0 });
  }
});
