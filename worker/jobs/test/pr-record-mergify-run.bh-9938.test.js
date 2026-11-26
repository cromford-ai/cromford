// BH-9938 (BH-9926.6): the Mergify queue payload on the PR record also holds
// run_id, the /actions/runs/<id> link of the payload comment. bin/dequeue-watch.sh
// keys its event row on (pr, head, run), so the record must carry the run id to
// serve the payload. Driven through the REAL worker.fetch (signed POST
// /webhooks/github, PUT and GET /api/pr-records) on node:sqlite with the
// composed jobs schema. Each case opens its own fresh DB and uses its own repo.
//   R1  a body with an /actions/runs/123 link stores run_id 123
//   R2  a body with no run link stores run_id null (the key is present)
//   R3  two run links: the FIRST one, the link the lane's own parse takes
//       (dqw_parse_payload_md, bin/lib/dequeue-watch/attribute.sh)
//   R4  PUT: an entry without the run_id key (a row written before BH-9938) still passes
//   R5  PUT: run_id "x", -1, 0 and 1.5 are refused (400 mergify_queue); null and 77 pass
//   R6  an older comment does not replace a newer run_id
//   R7  GET returns run_id as stored
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh9938';
const GH = 'gh-fixture-bh9938';
const NOW_MS = Date.parse('2026-11-25T12:00:00Z');
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), C = 'c'.repeat(40);

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
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-9938-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const rowOf = (db, repo, n) => db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const mqOf = (db, repo, n) => { const r = rowOf(db, repo, n); return r && r.mergify_queue !== null ? JSON.parse(r.mergify_queue) : null; };
const put = (env, repo, number, fields, extra = {}) => api(env, 'PUT', '/api/pr-records', { repo, number, source: 'fleet', fields, ...extra });
const openRecord = (env, repo, number) =>
  put(env, repo, number, { state: 'open', head_sha: A, head_ref: `ticket/x-${number}`, base_ref: 'main' }, { at: ago(3600) });

// A Mergify dequeued comment in the shape of tests/fixtures/dequeue-watch/payload-dequeued-batch1.md:
// the run link sits in the "Checks failed" line.
const dequeuedBody = (runLinks) =>
  '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n'
  + JSON.stringify({ version: 1, state: 'dequeued', dequeue_reason: { code: 'CHECKS_FAILED', checks: ['lint'] } })
  + '\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n'
  + `- ❌ **Checks failed** — \`2026-11-25 10:30 UTC\` · on draft #8165${runLinks.map((u) => ` · [run](${u})`).join('')}\n`
  + `- 🚫 **Left the queue** — \`2026-11-25 11:06 UTC\` · at \`${C}\`\n\n## Reason\n\nFailing checks:\n- ❌ [\`lint\`](https://x/runs/1)\n`;
const commentEvent = (repo, n, action, { id, createdAt, updatedAt, body }) => ({
  action, repository: { full_name: repo },
  issue: { number: n, state: 'open', labels: [], updated_at: updatedAt || createdAt, pull_request: { url: 'x' } },
  comment: { id, user: { login: 'mergify[bot]', type: 'Bot' }, created_at: createdAt, updated_at: updatedAt || createdAt, body },
});
const entry = (extra = {}) => ({
  state: 'dequeued', code: 'CHECKS_FAILED', draft_pr: 8165, failing_checks: ['lint'],
  left_sha: C, comment_id: 4242, at: ago(600), ...extra,
});

test('R1 a body with an /actions/runs/123 link stores run_id 123', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r1';
  await openRecord(o.env, repo, 5);
  const r = await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created',
    { id: 7001, createdAt: ago(600), body: dequeuedBody(['https://github.com/o/r/actions/runs/123']) }));
  assert.ok(r.status < 300, `webhook status ${r.status}`);
  assert.equal(mqOf(o.db, repo, 5).run_id, 123);
  assert.equal(mqOf(o.db, repo, 5).comment_id, 7001);
});

test('R2 a body with no run link stores run_id null, and the key is present', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r2';
  await openRecord(o.env, repo, 5);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 7002, createdAt: ago(600), body: dequeuedBody([]) }));
  const mq = mqOf(o.db, repo, 5);
  assert.ok(mq, 'the payload is stored');
  assert.ok(Object.hasOwn(mq, 'run_id'), `run_id key present: ${JSON.stringify(mq)}`);
  assert.equal(mq.run_id, null);
  // A queued payload has no body fields: run_id null too.
  const queued = '-*- Mergify Payload -*-\n{"state":"queued"}\n-*- Mergify Payload End -*-\nQueued';
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 7003, createdAt: ago(300), body: queued }));
  assert.equal(mqOf(o.db, repo, 5).state, 'queued');
  assert.equal(mqOf(o.db, repo, 5).run_id, null);
});

test('R3 two run links: the first one, as the lane parse takes it', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r3';
  await openRecord(o.env, repo, 5);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 7004, createdAt: ago(600),
    body: dequeuedBody(['https://github.com/o/r/actions/runs/555', 'https://github.com/o/r/actions/runs/999']) }));
  assert.equal(mqOf(o.db, repo, 5).run_id, 555);
  // A run id past Number.MAX_SAFE_INTEGER is not a run id: null.
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 7005, createdAt: ago(500),
    body: dequeuedBody(['https://github.com/o/r/actions/runs/99999999999999999999']) }));
  assert.equal(mqOf(o.db, repo, 5).comment_id, 7005);
  assert.equal(mqOf(o.db, repo, 5).run_id, null);
});

test('R4 PUT: an entry without the run_id key (written before BH-9938) still passes', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r4';
  await openRecord(o.env, repo, 5);
  const r = await put(o.env, repo, 5, { mergify_queue: entry() });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const mq = mqOf(o.db, repo, 5);
  assert.equal(mq.comment_id, 4242);
  assert.ok(!Object.hasOwn(mq, 'run_id'), 'a key that was not sent is not invented');
});

test('R5 PUT: a bad run_id is refused; null and a positive integer pass', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r5';
  await openRecord(o.env, repo, 5);
  for (const bad of ['x', -1, 0, 1.5, '77']) {
    const r = await put(o.env, repo, 5, { mergify_queue: entry({ run_id: bad }) });
    assert.equal(r.status, 400, `run_id ${JSON.stringify(bad)}: ${r.status} ${JSON.stringify(r.body)}`);
    assert.match(JSON.stringify(r.body), /mergify_queue/);
  }
  assert.equal(rowOf(o.db, repo, 5).mergify_queue, null, 'no refused entry was stored');
  let r = await put(o.env, repo, 5, { mergify_queue: entry({ run_id: null }) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(mqOf(o.db, repo, 5).run_id, null);
  r = await put(o.env, repo, 5, { mergify_queue: entry({ run_id: 77, at: ago(500) }) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(mqOf(o.db, repo, 5).run_id, 77);
});

test('R6 an older comment does not replace a newer run_id', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r6';
  await openRecord(o.env, repo, 5);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created',
    { id: 7010, createdAt: ago(300), body: dequeuedBody(['https://github.com/o/r/actions/runs/2000']) }));
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created',
    { id: 7009, createdAt: ago(900), body: dequeuedBody(['https://github.com/o/r/actions/runs/1000']) }));
  assert.equal(mqOf(o.db, repo, 5).run_id, 2000);
  // An edit of the older comment (a newer updated_at) is still older by created_at.
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'edited',
    { id: 7009, createdAt: ago(900), updatedAt: ago(10), body: dequeuedBody(['https://github.com/o/r/actions/runs/1001']) }));
  assert.equal(mqOf(o.db, repo, 5).run_id, 2000);
  assert.equal(mqOf(o.db, repo, 5).comment_id, 7010);
});

test('R7 GET /api/pr-records returns run_id as stored', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938-r7';
  await openRecord(o.env, repo, 5);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created',
    { id: 7020, createdAt: ago(600), body: dequeuedBody(['https://github.com/o/r/actions/runs/31337']) }));
  const g = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&number=5`);
  assert.equal(g.status, 200);
  assert.equal(g.body.row.mergify_queue.run_id, 31337);
});
