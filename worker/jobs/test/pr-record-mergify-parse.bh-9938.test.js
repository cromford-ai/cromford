// BH-9938 slice C1 (C0 review notes 3 and 5): the Mergify payload on the PR
// record agrees with the GitHub read of dequeue-watch.
//   P1  the shared fixture tests/fixtures/mergify/bh-9938-parse.md (2 drafts, 2
//       run links, 2 "Left the queue" lines, JSON checks that differ from the
//       bullets) stores the 4 values dqw_parse_payload_md prints for the same
//       file: draft 111, run 901, the first left sha, bullet-a and bullet-b.
//       tests/mergify-parse-agree.bh-9938-test.sh asserts the shell side.
//   U1  updated_at is the comment's updated_at, the epoch sdq_payload_last reads
//   U2  an edited delivery of the same comment moves updated_at
//   U3  PUT: an entry with no updated_at key (a row written before C1) passes;
//       a bad updated_at is refused (400)
// Driven through the REAL worker.fetch on node:sqlite with the composed schema.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh9938c1';
const GH = 'gh-fixture-bh9938c1';
const NOW_MS = Date.parse('2026-11-26T12:00:00Z');
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), C = 'c'.repeat(40);
const FIXTURE = readFileSync(fileURLToPath(new URL('../../../tests/fixtures/mergify/bh-9938-parse.md', import.meta.url)), 'utf8');

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
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-9938c1-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const mqOf = (db, repo, n) => {
  const r = db.prepare('SELECT mergify_queue FROM pr_records WHERE repo = ? AND number = ?').get(repo, n);
  return r && r.mergify_queue !== null ? JSON.parse(r.mergify_queue) : null;
};
const put = (env, repo, number, fields, extra = {}) => api(env, 'PUT', '/api/pr-records', { repo, number, source: 'fleet', fields, ...extra });
const openRecord = (env, repo, number) =>
  put(env, repo, number, { state: 'open', head_sha: A, head_ref: `ticket/x-${number}`, base_ref: 'main' }, { at: ago(3600) });
const commentEvent = (repo, n, action, { id, createdAt, updatedAt, body }) => ({
  action, repository: { full_name: repo },
  issue: { number: n, state: 'open', labels: [], updated_at: updatedAt || createdAt, pull_request: { url: 'x' } },
  comment: { id, user: { login: 'mergify[bot]', type: 'Bot' }, created_at: createdAt, updated_at: updatedAt || createdAt, body },
});

test('P1 the shared fixture stores the values dqw_parse_payload_md prints', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938c1-p1';
  await openRecord(o.env, repo, 5);
  const r = await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 8101, createdAt: ago(600), body: FIXTURE }));
  assert.ok(r.status < 300, `webhook status ${r.status}`);
  const mq = mqOf(o.db, repo, 5);
  assert.equal(mq.state, 'dequeued');
  assert.equal(mq.draft_pr, 111, 'the FIRST on draft #');
  assert.equal(mq.run_id, 901, 'the FIRST run link');
  assert.equal(mq.left_sha, '1'.repeat(40), 'the FIRST Left the queue sha');
  assert.deepEqual(mq.failing_checks, ['bullet-a', 'bullet-b'], 'the bullets up to the first blank line, not the JSON names');
});

test('U1 updated_at is the comment updated_at (no fraction)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938c1-u1';
  await openRecord(o.env, repo, 5);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created',
    { id: 8102, createdAt: ago(600), updatedAt: ago(300).replace('Z', '.123Z'), body: FIXTURE }));
  const mq = mqOf(o.db, repo, 5);
  assert.equal(mq.at, ago(600), 'at stays the created time (the order key)');
  assert.equal(mq.updated_at, ago(300));
});

test('U2 an edited delivery of the same comment moves updated_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938c1-u2';
  await openRecord(o.env, repo, 5);
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'created', { id: 8103, createdAt: ago(900), body: FIXTURE }));
  assert.equal(mqOf(o.db, repo, 5).updated_at, ago(900));
  await hook(o.env, 'issue_comment', commentEvent(repo, 5, 'edited', { id: 8103, createdAt: ago(900), updatedAt: ago(100), body: FIXTURE }));
  assert.equal(mqOf(o.db, repo, 5).updated_at, ago(100));
  assert.equal(mqOf(o.db, repo, 5).comment_id, 8103);
});

test('U3 PUT: no updated_at key passes; a bad updated_at is refused', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh9938c1-u3';
  const entry = (extra = {}) => ({
    state: 'dequeued', code: 'CHECKS_FAILED', draft_pr: 8165, failing_checks: ['lint'],
    left_sha: C, comment_id: 4242, at: ago(600), run_id: 1, ...extra,
  });
  const ok = await put(o.env, repo, 6, { state: 'open', mergify_queue: entry() });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.ok(!Object.hasOwn(mqOf(o.db, repo, 6), 'updated_at'));
  const good = await put(o.env, repo, 7, { state: 'open', mergify_queue: entry({ updated_at: ago(60) }) });
  assert.equal(good.status, 200, JSON.stringify(good.body));
  assert.equal(mqOf(o.db, repo, 7).updated_at, ago(60));
  for (const bad of ['x', 7, '2026-11-26']) {
    const r = await put(o.env, repo, 8, { state: 'open', mergify_queue: entry({ updated_at: bad }) });
    assert.equal(r.status, 400, `updated_at ${JSON.stringify(bad)} must be refused`);
  }
});
