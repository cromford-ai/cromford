// BH-8481 (C0): the PR record answers bin/pr-owner-sweep.sh's two list reads.
// Two added pr_records columns (merged_at, reviews), their webhook fill, the
// created-time window of GET /api/pr-records, and the merged list write of
// POST /api/pr-record-lists. Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema. Each case opens its own fresh DB
// and uses its own repo.
//   V0  ensureColumns adds merged_at, reviews and idx_pr_records_repo_state_created; a second call is a no-op
//   V1  a PUT with a good reviews object stores it; a bad state, 101 reviewers, a quote in a key, a bad commit are 400 reviews
//   W1  pull_request.opened stores reviews {}; closed with merged_at stores state merged + merged_at
//   W2  pull_request_review merges one entry per reviewer: newer wins, older loses, dismissed wins its tie, bot spellings fold
//   W3  a review on a row whose reviews is NULL leaves it NULL; REVIEW_MERGE_SQL on no row changes nothing
//   W4  a replayed review changes 0 rows; the 101st reviewer is refused; a bad login writes no entry
//   G1  250 merged rows: order=created&limit=200 answers the newest 200 by pr_created_at, truncated:true, 1 batch
//   G2  order and limit are checked (400 names them); limit above the list_limit row is 400
//   G3  rows carry merged_at and the parsed reviews; NULL pr_created_at sorts last and need=created_at names it
//   M1  a merged sync upserts its rows, leaves an open row alone, marks nothing absent, stamps (repo, merged)
//   M2  a merged-sync row that is not state merged is 400 at its index and writes nothing
//   M3  a merged-sync replay is a no-op
//   RT  the shell writer's bodies (pinned by tests/pr-owner-sweep-record-list.bh-8481-test.sh C3/C4) post and list back
//   X1  LIST_CREATED_SQL uses idx_pr_records_repo_state_created, REVIEW_MERGE_SQL the unique index, no SCAN on 5,000 rows
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { ensureColumns } from '../src/lib/core.js';
import { LIST_CREATED_SQL, LIST_KEYS } from '../src/routes/pr-records.js';
import { REVIEW_MERGE_SQL, prRecordWritesOf } from '../src/lib/pr-record-intake.js';

const SECRET = 'tok-fixture-bh8481';
const GH = 'gh-fixture-bh8481';
const NOW_MS = Date.parse('2026-10-26T12:00:00Z');
const T = '2026-10-26T12:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40);
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
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-8481-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const rowOf = (db, repo, n) => db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const reviewsOf = (db, repo, n) => { const r = rowOf(db, repo, n); return r && r.reviews !== null ? JSON.parse(r.reviews) : null; };
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n;
const list = (env, q) => api(env, 'GET', `/api/pr-records?${q}`);
const sync = (env, body) => api(env, 'POST', '/api/pr-record-lists', body);
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', T);
}
const pr = (repo, n, o = {}) => ({
  number: n, state: 'open', draft: false, merged_at: null, title: `PR ${n}`, user: { login: 'operator' }, body: `body ${n}`,
  created_at: '2026-10-26T09:00:00Z', updated_at: ago(600), html_url: `https://github.com/${repo}/pull/${n}`,
  head: { ref: `ticket/x-${n}`, sha: A }, base: { ref: 'main', sha: B }, labels: [], ...o,
});
const prEvent = (repo, action, n, o = {}) => ({ action, number: n, repository: { full_name: repo, default_branch: 'main' }, pull_request: pr(repo, n, o) });
const reviewEvent = (repo, n, action, login, state, at, commit = A) => ({
  action, repository: { full_name: repo }, pull_request: pr(repo, n),
  review: { state, submitted_at: at, commit_id: commit, user: { login } },
});
async function withColumns(o) { await ensureColumns(o.env, 'pr_records'); }

// ── V: columns and the PUT check ────────────────────────────────────────────────
test('V0 ensureColumns adds merged_at, reviews and the window index; a second call is a no-op', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cols = () => o.db.prepare('PRAGMA table_info(pr_records)').all().map((r) => r.name);
  for (const c of ['merged_at', 'reviews']) assert.ok(!cols().includes(c), `${c} is not in the BH-8067 CREATE`);
  await withColumns(o);
  for (const c of ['merged_at', 'reviews']) assert.ok(cols().includes(c), `${c} after ensureColumns: ${cols()}`);
  const idx = o.db.prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_pr_records_repo_state_created'").get();
  assert.match(idx.sql, /pr_records\s*\(\s*repo,\s*state,\s*pr_created_at\s*\)/);
  const before = cols().length;
  await ensureColumns({ DB: { prepare: (s) => o.DB.prepare(s), batch: (x) => o.DB.batch(x) } }, 'pr_records');
  assert.equal(cols().length, before);
});

test('V1 a PUT stores a good reviews object; each bad shape is 400 reviews and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-v1';
  const good = { operator: { state: 'APPROVED', commit_id: A.toUpperCase(), at: ago(60) }, 'cromford': { state: 'COMMENTED', commit_id: null, at: null } };
  const ok = await api(o.env, 'PUT', '/api/pr-records', { repo, number: 1, source: 'fleet', fields: { reviews: good, merged_at: ago(30) } });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(ok.body.row.reviews.operator, { state: 'APPROVED', commit_id: A, at: ago(60) }, 'the sha is stored lowercase');
  assert.deepEqual(ok.body.row.reviews['cromford'], { state: 'COMMENTED', commit_id: null, at: null });
  assert.equal(ok.body.row.merged_at, ago(30));
  const many = Object.fromEntries(Array.from({ length: 101 }, (_, i) => [`r${i}`, { state: 'COMMENTED', commit_id: null, at: null }]));
  const hundred = Object.fromEntries(Object.entries(many).slice(0, 100));
  const bad = [
    { operator: { state: 'BOGUS', commit_id: A, at: ago(60) } },
    many,
    { 'a"b': { state: 'APPROVED', commit_id: A, at: ago(60) } },
    { operator: { state: 'APPROVED', commit_id: A, at: ago(60) } },
    { operator: { state: 'APPROVED', commit_id: 'abc', at: ago(60) } },
    { operator: { state: 'APPROVED', commit_id: A, at: '2026-10-26T11:00:00.5Z' } },
    { operator: { state: 'APPROVED', commit_id: A, at: ago(60), extra: 1 } },
    [],
  ];
  for (const reviews of bad) {
    const r = await api(o.env, 'PUT', '/api/pr-records', { repo, number: 2, source: 'fleet', fields: { reviews } });
    assert.equal(r.status, 400, JSON.stringify(reviews).slice(0, 80));
    assert.deepEqual(r.body, { error: 'invalid_field', field: 'reviews' });
  }
  assert.equal(rowOf(o.db, repo, 2), null);
  const edge = await api(o.env, 'PUT', '/api/pr-records', { repo, number: 3, source: 'fleet', fields: { reviews: hundred } });
  assert.equal(edge.status, 200, '100 reviewers is the bound, accepted');
  const m = await api(o.env, 'PUT', '/api/pr-records', { repo, number: 4, source: 'fleet', fields: { merged_at: 'yesterday' } });
  assert.deepEqual(m.body, { error: 'invalid_field', field: 'merged_at' });
});

// ── W: the webhook fill ─────────────────────────────────────────────────────────
test('W1 opened stores reviews {}; closed with merged_at stores state merged and merged_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-w1';
  const r = await hook(o.env, 'pull_request', prEvent(repo, 'opened', 5, { updated_at: ago(600) }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rowOf(o.db, repo, 5).reviews, '{}', 'a just-opened PR has no review: known empty');
  assert.equal(rowOf(o.db, repo, 5).merged_at, null);
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 6, { updated_at: ago(600) }));
  assert.equal(rowOf(o.db, repo, 6).reviews, null, 'any other action does not know the reviews: unknown');
  await hook(o.env, 'pull_request', prEvent(repo, 'closed', 5, { state: 'closed', merged: true, merged_at: '2026-10-26T11:50:00.000Z', updated_at: ago(500) }));
  const row = rowOf(o.db, repo, 5);
  assert.equal(row.state, 'merged');
  assert.equal(row.merged_at, '2026-10-26T11:50:00Z', 'the fraction is stripped');
  assert.equal(row.reviews, '{}', 'a later delivery does not touch reviews');
});

test('W2 a review merges one entry per reviewer: newer wins, older loses, dismissed wins its tie, bot spellings fold', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-w2';
  await hook(o.env, 'pull_request', prEvent(repo, 'opened', 7));
  const r1 = await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'submitted', 'operator', 'approved', ago(50)));
  assert.equal(r1.status, 200, JSON.stringify(r1.body));
  assert.deepEqual(reviewsOf(o.db, repo, 7), { operator: { state: 'APPROVED', commit_id: A, at: ago(50) } });
  assert.equal(JSON.parse(rowOf(o.db, repo, 7).fields_at).reviews, ago(50), 'fields_at.reviews moves with the merge');
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'submitted', 'operator', 'changes_requested', ago(40), B));
  assert.deepEqual(reviewsOf(o.db, repo, 7).operator, { state: 'CHANGES_REQUESTED', commit_id: B, at: ago(40) });
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'submitted', 'operator', 'approved', ago(45)));
  assert.equal(reviewsOf(o.db, repo, 7).operator.state, 'CHANGES_REQUESTED', 'an older delivery does not replace a newer review');
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'dismissed', 'operator', 'dismissed', ago(40), B));
  assert.equal(reviewsOf(o.db, repo, 7).operator.state, 'DISMISSED', 'a dismissal carries its review time and wins the tie');
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'submitted', 'operator', 'changes_requested', ago(40), B));
  assert.equal(reviewsOf(o.db, repo, 7).operator.state, 'DISMISSED', 'the dismissed review replayed does not come back');
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'submitted', 'cromford[bot]', 'commented', ago(30)));
  assert.deepEqual(reviewsOf(o.db, repo, 7)['cromford'], { state: 'COMMENTED', commit_id: A, at: ago(30) }, 'x[bot] is stored as x');
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 7, 'submitted', 'app/cromford', 'approved', ago(20)));
  const rv = reviewsOf(o.db, repo, 7);
  assert.deepEqual(Object.keys(rv).sort(), ['cromford', 'operator'], 'x[bot] and app/x are one reviewer');
  assert.deepEqual(rv['cromford'], { state: 'APPROVED', commit_id: A, at: ago(20) });
  assert.equal(rowOf(o.db, repo, 7).review_decision, 'approved', 'the BH-8067 field write still runs');
});

test('W3 a review on a row whose reviews is NULL leaves it NULL; the merge on no row changes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-w3';
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 8));
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 8, 'submitted', 'operator', 'approved', ago(50)));
  assert.equal(rowOf(o.db, repo, 8).reviews, null, 'one entry is not the whole set: unknown stays unknown');
  assert.equal(JSON.parse(rowOf(o.db, repo, 8).fields_at).reviews, undefined, 'no reviews time is stamped on an unknown object');
  const n8 = o.db.prepare(REVIEW_MERGE_SQL).run(repo, 8, '$."operator"', JSON.stringify({ state: 'APPROVED', commit_id: A, at: ago(40) }), ago(40));
  assert.equal(n8.changes, 0, 'the merge changes no row whose reviews is NULL');
  await hook(o.env, 'pull_request_review', reviewEvent(repo, 9, 'submitted', 'operator', 'approved', ago(50)));
  assert.equal(rowOf(o.db, repo, 9).reviews, null, 'a PR first seen by its review has reviews unknown');
  await withColumns(o);
  const before = count(o.db);
  const r = o.db.prepare(REVIEW_MERGE_SQL).run(repo, 99, '$."operator"', JSON.stringify({ state: 'APPROVED', commit_id: A, at: ago(50) }), ago(50));
  assert.equal(r.changes, 0);
  assert.equal(count(o.db), before, 'REVIEW_MERGE_SQL never inserts');
});

test('W4 a replayed review changes 0 rows; the 101st reviewer is refused; a bad login writes no entry', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-w4';
  await hook(o.env, 'pull_request', prEvent(repo, 'opened', 10));
  const ev = reviewEvent(repo, 10, 'submitted', 'operator', 'approved', ago(50));
  const w = prRecordWritesOf('pull_request_review', ev, T).find((x) => x.kind === 'review');
  assert.equal(w.login, 'operator');
  assert.equal(w.at, ago(50));
  assert.equal(w.value.state, 'APPROVED');
  assert.equal(w.value.commit_id, A);
  const merge = () => o.db.prepare(REVIEW_MERGE_SQL).run(w.repo, w.number, `$."${w.login}"`, JSON.stringify(w.value), w.at).changes;
  assert.equal(merge(), 1);
  assert.equal(merge(), 0, 'a replay changes 0 rows');
  // 100 reviewers held: a new one is refused, a held one still moves.
  const hundred = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`r${i}`, { state: 'COMMENTED', commit_id: null, at: ago(900) }]));
  o.db.prepare('UPDATE pr_records SET reviews = ? WHERE repo = ? AND number = 10').run(JSON.stringify(hundred), repo);
  assert.equal(merge(), 0, 'the 101st reviewer is refused');
  const held = o.db.prepare(REVIEW_MERGE_SQL).run(repo, 10, '$."r7"', JSON.stringify({ state: 'APPROVED', commit_id: A, at: ago(10) }), ago(10)).changes;
  assert.equal(held, 1, 'a reviewer already held is updated at the bound');
  for (const login of ['a"b', 'x'.repeat(40), '', null]) {
    const e = reviewEvent(repo, 10, 'submitted', login, 'approved', ago(5));
    assert.deepEqual(prRecordWritesOf('pull_request_review', e, T).filter((x) => x.kind === 'review'), [], `login ${login}`);
  }
  const pending = reviewEvent(repo, 10, 'submitted', 'operator', 'pending', ago(5));
  assert.deepEqual(prRecordWritesOf('pull_request_review', pending, T).filter((x) => x.kind === 'review'), [], 'a pending review is not stored');
});

// ── G: the window read ──────────────────────────────────────────────────────────
// One merged row: created i minutes ago (1 = newest), updated in the reverse order.
function seedMerged(db, repo, n, total, extra = {}) {
  const v = { pr_created_at: ago(n * 60), pr_updated_at: ago((total + 1 - n) * 60), merged_at: ago((total + 1 - n) * 60), reviews: '{}', ...extra };
  db.prepare(`INSERT INTO pr_records (repo, number, state, draft, head_ref, head_sha, base_ref, labels, title, author, body, url,
                pr_created_at, pr_updated_at, merged_at, reviews, fields_at, created_at, refreshed_at)
              VALUES (?,?,'merged',0,?,?,'main','[]',?,'operator','',?,?,?,?,?,'{}',?,?)`)
    .run(repo, n, `ticket/bh-${n}`, A, `BH-${n}: x`, `https://github.com/${repo}/pull/${n}`,
      v.pr_created_at, v.pr_updated_at, v.merged_at, v.reviews, T, T);
}
async function seeded250(o, repo) {
  await withColumns(o);
  o.db.exec('BEGIN');
  for (let i = 1; i <= 250; i++) seedMerged(o.db, repo, i, 250);
  o.db.exec('COMMIT');
}

test('G1 order=created&limit=200 answers the newest 200 by pr_created_at, truncated:true, in one batch', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-g1';
  await seeded250(o, repo);
  const g = await list(o.env, `repo=${repo}&state=merged&order=created&limit=200`);
  assert.equal(g.status, 200, JSON.stringify(g.body).slice(0, 300));
  assert.equal(g.body.rows.length, 200);
  assert.deepEqual(g.body.rows.map((r) => r.number), Array.from({ length: 200 }, (_, i) => i + 1), 'newest created first');
  assert.equal(g.body.truncated, true, 'more than 200 exist');
  const d = await list(o.env, `repo=${repo}&state=merged&limit=200`);
  assert.equal(d.body.rows[0].number, 250, 'without order the BH-8452 order stands (newest updated first)');
  assert.equal(d.body.rows.length, 200);
  const all = await list(o.env, `repo=${repo}&state=merged&order=created&limit=250`);
  assert.equal(all.body.truncated, false, 'exactly the window is not truncated');
  setting(o.db, 'settings_cache_ttl_s', 60);
  const seen = { prepare: 0, batch: [] };
  const DB = { prepare: (s) => { seen.prepare += 1; return o.DB.prepare(s); }, batch: (x) => { seen.batch.push(x.length); return o.DB.batch(x); } };
  const env = { ...o.env, DB };
  await list(env, `repo=${repo}&state=merged&order=created&limit=200`);
  seen.prepare = 0; seen.batch = [];
  await list(env, `repo=${repo}&state=merged&order=created&limit=200`);
  assert.deepEqual(seen.batch, [3], 'one batch of three statements');
  assert.equal(seen.prepare, 3);
});

test('G2 order and limit are checked; limit above the list_limit row is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [
    ['repo=o/x&state=merged&order=bogus', 'order'],
    ['repo=o/x&state=merged&order=created&limit=0', 'limit'],
    ['repo=o/x&state=merged&order=created&limit=abc', 'limit'],
    ['repo=o/x&state=merged&order=created&limit=-1', 'limit'],
    ['repo=o/x&state=merged&order=created&limit=', 'limit'],
    ['repo=o/x&state=merged&order=created&limit=501', 'limit'],
  ];
  for (const [q, field] of cases) {
    const r = await list(o.env, q);
    assert.equal(r.status, 400, q);
    assert.deepEqual(r.body, { error: 'invalid_field', field }, q);
  }
  assert.equal((await list(o.env, 'repo=o/x&state=merged&order=created&limit=500')).status, 200, 'the row (500) is accepted');
  setting(o.db, 'pr_records.list_limit', 100);
  assert.equal((await list(o.env, 'repo=o/x&state=merged&order=created&limit=101')).status, 400, 'the bound is the row, not 500');
});

test('G3 rows carry merged_at and parsed reviews; NULL pr_created_at sorts last and need=created_at names it', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-g3';
  await withColumns(o);
  seedMerged(o.db, repo, 1, 3, { reviews: JSON.stringify({ operator: { state: 'APPROVED', commit_id: A, at: ago(5) } }) });
  seedMerged(o.db, repo, 2, 3, { pr_created_at: null });
  seedMerged(o.db, repo, 3, 3);
  const g = await list(o.env, `repo=${repo}&state=merged&order=created&limit=3&need=merged_at,reviews`);
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.rows.map((r) => r.number), [1, 3, 2], 'NULL pr_created_at last');
  for (const r of g.body.rows) assert.deepEqual(Object.keys(r).sort(), [...LIST_KEYS].sort());
  assert.deepEqual(g.body.rows[0].reviews, { operator: { state: 'APPROVED', commit_id: A, at: ago(5) } });
  assert.equal(g.body.rows[0].merged_at, ago(180));
  assert.deepEqual(g.body.rows[1].reviews, {});
  assert.equal(g.body.missing, null);
  assert.equal((await list(o.env, `repo=${repo}&state=merged&order=created&limit=3&need=created_at`)).body.missing, 'created_at');
  o.db.prepare('UPDATE pr_records SET reviews = NULL WHERE repo = ? AND number = 3').run(repo);
  assert.equal((await list(o.env, `repo=${repo}&state=merged&order=created&need=reviews`)).body.missing, 'reviews', 'NULL reviews is unknown');
});

// ── M: the merged list write ────────────────────────────────────────────────────
const mrow = (n, o = {}) => ({ number: n, fields: { state: 'merged', title: `BH-${n}: x`, head_ref: `ticket/bh-${n}`, url: `https://github.com/o/x/pull/${n}`,
  author: 'operator', pr_created_at: ago(n * 100), merged_at: ago(n * 10), ...o } });

test('M1 a merged sync upserts its rows, leaves an open row alone, marks nothing absent, stamps (repo, merged)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-m1';
  await hook(o.env, 'pull_request', prEvent(repo, 'opened', 4));
  const r = await sync(o.env, { repo, state: 'merged', at: ago(10), rows: [mrow(1), mrow(2), mrow(3)] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.written, 3);
  assert.equal(r.body.absent, 0, 'a merged window marks nothing absent');
  assert.equal(r.body.synced_at, ago(10));
  for (const n of [1, 2, 3]) {
    const x = rowOf(o.db, repo, n);
    assert.equal(x.state, 'merged');
    assert.equal(x.merged_at, ago(n * 10));
    assert.equal(x.last_source, 'github');
  }
  assert.equal(rowOf(o.db, repo, 4).state, 'open', 'a merged window never marks an open row');
  assert.deepEqual({ ...o.db.prepare("SELECT synced_at, rows FROM pr_record_lists WHERE repo = ? AND state = 'merged'").get(repo) }, { synced_at: ago(10), rows: 3 });
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM pr_record_lists WHERE repo = ? AND state = 'open'").get(repo).n, 0, 'no open stamp');
  const g = await list(o.env, `repo=${repo}&state=merged&order=created&limit=200`);
  assert.deepEqual(g.body.sync, { synced_at: ago(10), age_s: 10, rows: 3 });
  assert.deepEqual(g.body.rows.map((x) => x.number), [1, 2, 3]);
  assert.equal(g.body.unknown, 0);
});

test('M2 a merged-sync row that is not state merged is 400 at its index and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-m2';
  for (const [rows, index] of [[[mrow(1), mrow(2, { state: 'open' })], 1], [[{ number: 1, fields: { title: 'no state' } }], 0]]) {
    const r = await sync(o.env, { repo, state: 'merged', at: ago(10), rows });
    assert.equal(r.status, 400);
    assert.deepEqual(r.body, { error: 'invalid_field', field: 'state', index });
  }
  assert.equal(count(o.db), 0);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_record_lists').get().n, 0);
  const c = await sync(o.env, { repo, state: 'closed', at: ago(10), rows: [] });
  assert.deepEqual(c.body, { error: 'invalid_field', field: 'state' }, 'closed stays refused');
});

test('M3 a merged-sync replay is a no-op', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8481-m3';
  const body = { repo, state: 'merged', at: ago(10), rows: [mrow(1), mrow(2)] };
  await sync(o.env, body);
  const snap = () => ({ rows: o.db.prepare('SELECT * FROM pr_records WHERE repo = ? ORDER BY number').all(repo).map((x) => ({ ...x })),
    stamp: { ...o.db.prepare('SELECT synced_at, rows FROM pr_record_lists WHERE repo = ?').get(repo) } });
  const before = snap();
  const r = await sync(o.env, body);
  assert.equal(r.body.absent, 0);
  assert.equal(r.body.synced_at, ago(10));
  assert.deepEqual(snap(), before);
});

// ── RT: the shell writer's bodies ───────────────────────────────────────────────
test('RT the shell writer bodies post and list back with the same values', async (t) => {
  const o = await fresh(t); if (!o) return;
  const open = JSON.parse(readFileSync(new URL('bh-8481-sync-open-body.json', FIX), 'utf8'));
  const merged = JSON.parse(readFileSync(new URL('bh-8481-sync-merged-body.json', FIX), 'utf8'));
  for (const b of [open, merged]) {
    const r = await sync(o.env, b);
    assert.equal(r.status, 200, JSON.stringify(r.body));
  }
  const go = await list(o.env, `repo=${open.repo}&state=open&order=created&limit=200&need=title,head_ref,head_sha,base_ref,author,labels,body,url,created_at,updated_at,reviews,draft`);
  assert.equal(go.body.missing, null);
  assert.deepEqual(go.body.rows.map((x) => x.number).sort(), open.rows.map((x) => x.number).sort());
  for (const src of open.rows) {
    const got = go.body.rows.find((x) => x.number === src.number);
    assert.deepEqual(got.reviews, src.fields.reviews, `#${src.number} reviews`);
    assert.equal(got.author, src.fields.author);
    assert.equal(got.head_sha, src.fields.head_sha);
    assert.equal(got.created_at, src.fields.pr_created_at);
    assert.deepEqual(got.labels, src.fields.labels);
    assert.equal(got.mergeable_state, null, 'the GraphQL sync never writes mergeable_state');
  }
  const gm = await list(o.env, `repo=${merged.repo}&state=merged&order=created&limit=200&need=title,head_ref,url,merged_at,author,created_at`);
  assert.equal(gm.body.missing, null);
  for (const src of merged.rows) {
    const got = gm.body.rows.find((x) => x.number === src.number);
    assert.equal(got.merged_at, src.fields.merged_at, `#${src.number} merged_at`);
    assert.equal(got.created_at, src.fields.pr_created_at);
  }
});

// ── X: plans at volume ──────────────────────────────────────────────────────────
test('X1 LIST_CREATED_SQL and REVIEW_MERGE_SQL use their index and no SCAN on 5,000 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  await withColumns(o);
  const STATES = ['open', 'closed', 'merged', null];
  o.db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, ts = ago(i * 600);
      vals.push('(?,?,?,?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 40}`, i + 1, STATES[i % 4], '{}', '{}', ts, ts, ts, ts);
    }
    o.db.prepare(`INSERT INTO pr_records (repo, number, state, fields_at, reviews, created_at, refreshed_at, pr_updated_at, pr_created_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  assert.equal(count(o.db), 5000);
  const check = (sql, binds, index) => {
    const p = plan(o.db, sql, ...binds);
    assert.deepEqual(fullScans(p, ['pr_records']), [], p.join(' | '));
    assert.ok(p.some((l) => l.includes(index)), `${index} not in: ${p.join(' | ')}`);
  };
  check(LIST_CREATED_SQL, ['o/repo-7', 'merged', null, 201], 'idx_pr_records_repo_state_created');
  check(REVIEW_MERGE_SQL, ['o/repo-7', 8, '$."operator"', '{"state":"APPROVED","commit_id":null,"at":null}', T], 'ux_pr_records_repo_number');
});
