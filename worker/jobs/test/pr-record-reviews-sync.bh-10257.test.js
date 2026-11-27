// BH-10257 (slice 2): the pr_records column reviews_sync {head_sha, at, cr},
// the merge conductor's proof that its review set of a head is complete
// (bin/lib/prr-shadow.d/merge-conductor.sh mc_cr_record / mc_cr_github).
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. Each case opens its own fresh DB and uses its own repo.
//   S0  ensureColumns adds reviews_sync; the GET row answers it parsed
//   S1  a PUT with reviews + reviews_sync stores both; fields_at.reviews and
//       fields_at.reviews_sync are the PUT's at; each bad shape is 400 reviews_sync
//   S2  a review delivered after the sync moves fields_at.reviews past
//       reviews_sync.at (the reader's "incomplete" signal), and leaves the
//       sync as it was
//   S3  a review submitted before the sync but delivered after it does not
//       move fields_at.reviews past reviews_sync.at (the sync's read held it)
//   S4  a PUT whose at is older than a delivered review keeps the newer
//       reviews (stale) but stores the sync, so the reader still sees the
//       later review (fields_at.reviews > reviews_sync.at)
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'tok-fixture-bh10257';
const GH = 'gh-fixture-bh10257';
const NOW_MS = Date.parse('2026-10-26T12:00:00Z');
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40);

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
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-10257-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const rowOf = (db, repo, n) => db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const fieldsAt = (db, repo, n) => JSON.parse(rowOf(db, repo, n).fields_at);
const pr = (repo, n, o = {}) => ({
  number: n, state: 'open', draft: false, merged_at: null, title: `PR ${n}`, user: { login: 'operator' }, body: `body ${n}`,
  created_at: '2026-10-26T09:00:00Z', updated_at: ago(600), html_url: `https://github.com/${repo}/pull/${n}`,
  head: { ref: `ticket/x-${n}`, sha: A }, base: { ref: 'main', sha: B }, labels: [], ...o,
});
const reviewEvent = (repo, n, login, state, at) => ({
  action: 'submitted', repository: { full_name: repo }, pull_request: pr(repo, n),
  review: { state, submitted_at: at, commit_id: A, user: { login } },
});
const put = (env, repo, n, fields, at) => api(env, 'PUT', '/api/pr-records', { repo, number: n, source: 'github', fields, at });

test('S0 ensureColumns adds reviews_sync; the GET row answers it parsed', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cols = () => o.db.prepare('PRAGMA table_info(pr_records)').all().map((r) => r.name);
  await ensureColumns(o.env, 'pr_records');
  assert.ok(cols().includes('reviews_sync'), `reviews_sync after ensureColumns: ${cols()}`);
  const repo = 'o/bh10257-s0';
  const sync = { head_sha: A, at: ago(30), cr: 0 };
  assert.equal((await put(o.env, repo, 1, { reviews: {}, reviews_sync: sync }, ago(30))).status, 200);
  const g = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&number=1`);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.deepEqual(g.body.row.reviews_sync, sync);
  assert.deepEqual(g.body.row.reviews, {});
});

test('S1 a PUT stores reviews and reviews_sync at its at; each bad sync shape is 400 reviews_sync', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10257-s1';
  const at = ago(30);
  const reviews = { 'lead-x': { state: 'APPROVED', commit_id: A, at: ago(300) } };
  const ok = await put(o.env, repo, 1, { reviews, reviews_sync: { head_sha: A.toUpperCase(), at, cr: 0 } }, at);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(ok.body.row.reviews_sync, { head_sha: A, at, cr: 0 }, 'the sha is stored lowercase');
  assert.deepEqual(ok.body.applied.sort(), ['reviews', 'reviews_sync']);
  assert.equal(fieldsAt(o.db, repo, 1).reviews, at);
  assert.equal(fieldsAt(o.db, repo, 1).reviews_sync, at);
  const bad = [
    { head_sha: 'abc', at, cr: 0 },
    { head_sha: A, at: 'now', cr: 0 },
    { head_sha: A, at, cr: 2 },
    { head_sha: A, at, cr: '0' },
    { head_sha: A, at },
    { head_sha: A, at, cr: 0, extra: 1 },
    [],
    'x',
  ];
  for (const s of bad) {
    const r = await put(o.env, repo, 2, { reviews_sync: s }, at);
    assert.equal(r.status, 400, JSON.stringify(s));
    assert.deepEqual(r.body, { error: 'invalid_field', field: 'reviews_sync' });
  }
  assert.equal(rowOf(o.db, repo, 2), null);
});

test('S2 a review delivered after the sync moves fields_at.reviews past reviews_sync.at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10257-s2';
  const at = ago(120);
  assert.equal((await put(o.env, repo, 3, { reviews: {}, reviews_sync: { head_sha: A, at, cr: 0 } }, at)).status, 200);
  const r = await hook(o.env, 'pull_request_review', reviewEvent(repo, 3, 'lead-x', 'changes_requested', ago(60)));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const fa = fieldsAt(o.db, repo, 3);
  assert.ok(fa.reviews > JSON.parse(rowOf(o.db, repo, 3).reviews_sync).at, `fields_at.reviews ${fa.reviews} is after the sync ${at}`);
  assert.deepEqual(JSON.parse(rowOf(o.db, repo, 3).reviews_sync), { head_sha: A, at, cr: 0 }, 'a webhook never writes the sync');
  assert.equal(JSON.parse(rowOf(o.db, repo, 3).reviews)['lead-x'].state, 'CHANGES_REQUESTED');
});

test('S3 a review submitted before the sync but delivered after it leaves fields_at.reviews at the sync', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10257-s3';
  const at = ago(60);
  assert.equal((await put(o.env, repo, 4, { reviews: { 'lead-x': { state: 'APPROVED', commit_id: A, at: ago(120) } },
    reviews_sync: { head_sha: A, at, cr: 0 } }, at)).status, 200);
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 4, 'lead-x', 'approved', ago(120)));
  assert.equal(fieldsAt(o.db, repo, 4).reviews, at);
});

test('S4 a PUT older than a delivered review keeps the newer reviews and still stores the sync', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10257-s4';
  assert.equal((await put(o.env, repo, 5, { reviews: {} }, ago(600))).status, 200);
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 5, 'lead-x', 'changes_requested', ago(30)));
  const at = ago(90);
  const r = await put(o.env, repo, 5, { reviews: {}, reviews_sync: { head_sha: A, at, cr: 0 } }, at);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.stale, ['reviews'], 'the older read does not replace the newer review');
  assert.deepEqual(r.body.applied, ['reviews_sync']);
  assert.ok(fieldsAt(o.db, repo, 5).reviews > at, 'the reader sees a review after the sync');
});
