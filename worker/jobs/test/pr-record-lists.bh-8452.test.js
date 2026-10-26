// BH-8452 (C0): the PR record list. Six added pr_records columns, their
// webhook fill, the list read GET /api/pr-records?repo=&state=, and the full
// list write POST /api/pr-record-lists with its sync stamp. Driven through the
// REAL worker.fetch on node:sqlite with the composed jobs schema. Each case
// opens its own fresh DB and uses its own repo.
//   L0  ensureColumns adds the six columns and idx_pr_records_repo_state_upd; a second call is a no-op
//   L1  a signed pull_request.opened stores the six; edited replaces the title; an older delivery keeps it
//   L1b body null -> ""; no body key leaves body; a 65,537-char body and a 40-char login drop only those
//   L1c PUT with title works; PUT with an unknown field is still 400 unknown_field
//   L2  150 open + 20 merged + 10 other-repo rows: one GET, 150 rows, the 13 keys; 1 batch of 3 statements
//   L2b since filters; need=title names title when one row lacks it
//   L2c limit row 100 -> 100 rows, truncated:true; a bad limit row is the fallback 500
//   L2d no state and no number -> 400 number; state=bogus, since, need -> 400
//   L2e the repo is one list in any case
//   S1  a sync upserts the rows (github), marks the open record not in the list unknown, stamps the list
//   S2  a record whose state is newer than the read stays open
//   S3  a replay gives the same rows and absent:0
//   S4  a bad row is 400 {index, field} and writes nothing; 501 rows at limit 500; state merged; a duplicate
//   S5  a GET after a sync answers sync.age_s on the worker clock; a future `at` is the worker clock
//   S6  the shell writer's body (fixture, pinned by tests/pr-record-list.bh-8452-test.sh R4) posts and lists back
//   S7  an open PR a lagging list read left out: the GET answers unknown:1 (a reader miss) until a
//       sync lists it again; a mark older than the newest stamp is not counted
//   X1  LIST_SQL, SYNC_SQL and UNKNOWN_SQL use their index and no SCAN of pr_records on 5,000 rows
//   X2  ABSENT_SQL and STAMP_SQL use an index and no SCAN on 5,000 rows
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { ensureColumns } from '../src/lib/core.js';
import { LIST_SQL, LIST_KEYS, SYNC_SQL, UNKNOWN_SQL } from '../src/routes/pr-records.js';
import { ABSENT_SQL, STAMP_SQL } from '../src/routes/pr-record-lists.js';

const SECRET = 'tok-fixture-bh8452';
const GH = 'gh-fixture-bh8452';
const NOW_MS = Date.parse('2026-10-26T12:00:00Z');
const T = '2026-10-26T12:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40), C = 'c'.repeat(40);
const SIX = ['title', 'author', 'body', 'pr_created_at', 'url', 'pr_updated_at'];
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
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': `dlv-8452-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const rowOf = (db, repo, n) => db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n;
const list = (env, q) => api(env, 'GET', `/api/pr-records?${q}`);
const sync = (env, body) => api(env, 'POST', '/api/pr-record-lists', body);
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', T);
}
const pr = (repo, n, o = {}) => ({
  number: n, state: 'open', draft: false, merged_at: null, title: `PR ${n}`, user: { login: 'operator' }, body: `body ${n}`,
  created_at: '2026-10-26T09:00:00.123Z', updated_at: ago(60), html_url: `https://github.com/${repo}/pull/${n}`,
  head: { ref: `ticket/x-${n}`, sha: A }, base: { ref: 'main', sha: B }, labels: [{ name: 'ai-build' }], ...o,
});
const prEvent = (repo, action, n, o = {}) => ({ action, number: n, repository: { full_name: repo, default_branch: 'main' }, pull_request: pr(repo, n, o) });
// A row inserted straight into the table (the list read does not care how it got there).
function seedRow(db, repo, n, state, updated, extra = {}) {
  const v = { title: `PR ${n}`, author: 'operator', body: '', url: `https://github.com/${repo}/pull/${n}`, pr_created_at: ago(86400), ...extra };
  db.prepare(`INSERT INTO pr_records (repo, number, state, draft, head_ref, head_sha, base_ref, labels, title, author, body, url,
                pr_created_at, pr_updated_at, fields_at, created_at, refreshed_at)
              VALUES (?,?,?,0,?,?,'main','["ai-build"]',?,?,?,?,?,?,?,?,?)`)
    .run(repo, n, state, `b/${n}`, A, v.title, v.author, v.body, v.url, v.pr_created_at, updated,
      JSON.stringify({ state: updated }), updated, updated);
}
async function withColumns(o) { await ensureColumns(o.env, 'pr_records'); }

// ── L: columns, webhook fill, list read ─────────────────────────────────────────
test('L0 ensureColumns adds the six columns and the list index; a second call is a no-op', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cols = () => o.db.prepare('PRAGMA table_info(pr_records)').all().map((r) => r.name);
  for (const c of SIX) assert.ok(!cols().includes(c), `${c} is not in the BH-8067 CREATE`);
  await withColumns(o);
  for (const c of SIX) assert.ok(cols().includes(c), `${c} after ensureColumns: ${cols()}`);
  const idx = o.db.prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_pr_records_repo_state_upd'").get();
  assert.match(idx.sql, /pr_records\s*\(\s*repo,\s*state,\s*pr_updated_at\s*\)/);
  const before = cols().length;
  await ensureColumns(o.env, 'pr_records');
  // A fresh memo (a new isolate) on the same table: the PRAGMA sees every column, no ALTER runs.
  await ensureColumns({ DB: { prepare: (s) => o.DB.prepare(s), batch: (x) => o.DB.batch(x) } }, 'pr_records');
  assert.equal(cols().length, before);
});

test('L1 a signed pull_request.opened stores the six; edited replaces the title; an older delivery keeps the newer title', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-l1';
  const r = await hook(o.env, 'pull_request', prEvent(repo, 'opened', 5, { updated_at: ago(60) }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const row = rowOf(o.db, repo, 5);
  assert.equal(row.title, 'PR 5');
  assert.equal(row.author, 'operator');
  assert.equal(row.body, 'body 5');
  assert.equal(row.url, `https://github.com/${repo}/pull/5`);
  assert.equal(row.pr_created_at, '2026-10-26T09:00:00Z', 'the fraction is stripped');
  assert.equal(row.pr_updated_at, ago(60));
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 5, { title: 'PR 5 renamed', updated_at: ago(30) }));
  assert.equal(rowOf(o.db, repo, 5).title, 'PR 5 renamed');
  assert.equal(rowOf(o.db, repo, 5).pr_updated_at, ago(30));
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 5, { title: 'PR 5 old', updated_at: ago(45) }));
  assert.equal(rowOf(o.db, repo, 5).title, 'PR 5 renamed', 'an older delivery keeps the newer title');
  assert.equal(rowOf(o.db, repo, 5).pr_updated_at, ago(30));
  // pull_request_review carries the PR object too.
  await hook(o.env, 'pull_request_review', { action: 'submitted', repository: { full_name: repo },
    pull_request: pr(repo, 5, { title: 'PR 5 reviewed', updated_at: ago(10) }), review: { state: 'approved', submitted_at: ago(10) } });
  assert.equal(rowOf(o.db, repo, 5).title, 'PR 5 reviewed');
});

test('L1b body null stores ""; no body key leaves body; an oversize body and a 40-char login drop only those', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-l1b';
  await hook(o.env, 'pull_request', prEvent(repo, 'opened', 6, { body: null, updated_at: ago(100) }));
  assert.equal(rowOf(o.db, repo, 6).body, '', 'null on GitHub is an empty body, not unknown');
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 6, { body: 'Closes #9', updated_at: ago(90) }));
  const noBody = prEvent(repo, 'edited', 6, { title: 'still', updated_at: ago(80) });
  delete noBody.pull_request.body;
  await hook(o.env, 'pull_request', noBody);
  assert.equal(rowOf(o.db, repo, 6).body, 'Closes #9', 'no body key writes no body');
  assert.equal(rowOf(o.db, repo, 6).title, 'still');
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 6, { body: 'x'.repeat(65537), user: { login: 'a'.repeat(40) }, title: 'kept', updated_at: ago(70) }));
  const row = rowOf(o.db, repo, 6);
  assert.equal(row.body, 'Closes #9', 'a 65,537-char body is dropped');
  assert.equal(row.author, 'operator', 'a 40-char login is dropped');
  assert.equal(row.title, 'kept', 'the other fields of that delivery are written');
  // Edge: 65,536 characters and a [bot] login are accepted.
  await hook(o.env, 'pull_request', prEvent(repo, 'edited', 6, { body: 'y'.repeat(65536), user: { login: 'dependabot[bot]' }, updated_at: ago(60) }));
  assert.equal(rowOf(o.db, repo, 6).body.length, 65536);
  assert.equal(rowOf(o.db, repo, 6).author, 'dependabot[bot]');
});

test('L1c PUT with title works; PUT with an unknown field is still 400 unknown_field; a bad url is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ok = await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8452-l1c', number: 1, source: 'fleet', fields: { title: 'T', url: 'https://github.com/o/x/pull/1' } });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.row.title, 'T');
  const bad = await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8452-l1c', number: 1, source: 'fleet', fields: { bogus: 1 } });
  assert.equal(bad.status, 400);
  assert.deepEqual(bad.body, { error: 'unknown_field', field: 'bogus' });
  const u = await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8452-l1c', number: 1, source: 'fleet', fields: { url: 'https://evil.test/x' } });
  assert.deepEqual(u.body, { error: 'invalid_field', field: 'url' });
  const at = await api(o.env, 'PUT', '/api/pr-records', { repo: 'o/bh8452-l1c', number: 1, source: 'fleet', fields: { pr_updated_at: '2026-10-26T12:00:00.5Z' } });
  assert.deepEqual(at.body, { error: 'invalid_field', field: 'pr_updated_at' });
});

async function seeded150(o, repo) {
  await withColumns(o);
  o.db.exec('BEGIN');
  for (let i = 1; i <= 150; i++) seedRow(o.db, repo, i, 'open', ago(i * 60));
  for (let i = 151; i <= 170; i++) seedRow(o.db, repo, i, 'merged', ago(i * 60));
  for (let i = 1; i <= 10; i++) seedRow(o.db, 'o/bh8452-other', i, 'open', ago(i * 60));
  o.db.exec('COMMIT');
}

test('L2 150 open rows answer in one GET with the 13 keys; the read is 1 batch of 3 statements', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-l2';
  await seeded150(o, repo);
  const g = await list(o.env, `repo=${repo}&state=open`);
  assert.equal(g.status, 200, JSON.stringify(g.body).slice(0, 300));
  assert.equal(g.body.rows.length, 150);
  assert.equal(g.body.truncated, false);
  assert.equal(g.body.sync, null);
  assert.equal(g.body.missing, null);
  assert.equal(g.body.unknown, 0);
  assert.deepEqual(LIST_KEYS.length, 13);
  for (const r of g.body.rows) assert.deepEqual(Object.keys(r).sort(), [...LIST_KEYS].sort());
  assert.deepEqual(g.body.rows.slice(0, 3).map((r) => r.number), [1, 2, 3], 'newest pr_updated_at first');
  const r1 = g.body.rows[0];
  assert.deepEqual(r1.labels, ['ai-build']);
  assert.equal(r1.updated_at, ago(60));
  assert.equal(r1.created_at, ago(86400));
  assert.equal(r1.draft, 0);
  // The statement count: a counting DB over the same data, warm memos, settings snapshot cached.
  setting(o.db, 'settings_cache_ttl_s', 60);
  const seen = { prepare: 0, batch: [] };
  const DB = {
    prepare: (s) => { seen.prepare += 1; return o.DB.prepare(s); },
    batch: (x) => { seen.batch.push(x.length); return o.DB.batch(x); },
  };
  const env = { ...o.env, DB };
  await list(env, `repo=${repo}&state=open`);
  seen.prepare = 0; seen.batch = [];
  const w = await list(env, `repo=${repo}&state=open`);
  assert.equal(w.body.rows.length, 150);
  assert.deepEqual(seen.batch, [3], 'one batch of three statements');
  assert.equal(seen.prepare, 3, 'no statement outside the batch');
});

test('L2b since filters on pr_updated_at; need names the first null field', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-l2b';
  await seeded150(o, repo);
  const s = await list(o.env, `repo=${repo}&state=open&since=${ago(600)}`);  // determinism: ok the worker clock is pinned to NOW_MS (t.mock.timers) and the rows are ago() off it
  assert.deepEqual(s.body.rows.map((r) => r.number), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal((await list(o.env, `repo=${repo}&state=open&need=title,body`)).body.missing, null, 'body "" is a value');
  o.db.prepare('UPDATE pr_records SET title = NULL WHERE repo = ? AND number = 77').run(repo);
  assert.equal((await list(o.env, `repo=${repo}&state=open&need=body,title`)).body.missing, 'title');
  assert.equal((await list(o.env, `repo=${repo}&state=open`)).body.missing, null, 'no need, no missing');
  assert.equal((await list(o.env, `repo=${repo}&state=merged&need=title`)).body.missing, null, 'only returned rows count');
});

test('L2c the pr_records.list_limit row caps the page; truncated is exact; a bad row is the fallback', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-l2c';
  await seeded150(o, repo);
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key = 'pr_records.list_limit'").get().value, '500', 'seeded 500');
  setting(o.db, 'pr_records.list_limit', 100);
  const g = await list(o.env, `repo=${repo}&state=open`);
  assert.equal(g.body.rows.length, 100);
  assert.equal(g.body.truncated, true);
  setting(o.db, 'pr_records.list_limit', 150);
  const e = await list(o.env, `repo=${repo}&state=open`);
  assert.equal(e.body.rows.length, 150);
  assert.equal(e.body.truncated, false, 'exactly the limit is not truncated');
  setting(o.db, 'pr_records.list_limit', 149);
  assert.equal((await list(o.env, `repo=${repo}&state=open`)).body.truncated, true);
  for (const v of ['0', 'abc', '9999']) {
    setting(o.db, 'pr_records.list_limit', v);
    const f = await list(o.env, `repo=${repo}&state=open`);
    assert.equal(f.body.rows.length, 150, `limit ${v} -> fallback 500`);
  }
});

test('L2d bad list queries are 400 and name the field', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [
    ['repo=o/x', 'number'],
    ['repo=o/x&state=bogus', 'state'],
    ['repo=o/x&state=open&since=yesterday', 'since'],  // determinism: ok a 400 on the since format, no window is read
    ['repo=o/x&state=open&need=title,checks', 'need'],
    ['repo=bad&state=open', 'repo'],
  ];
  for (const [q, field] of cases) {
    const r = await list(o.env, q);
    assert.equal(r.status, 400, q);
    assert.equal(r.body.field, field, q);
  }
  // With number the old read answers, state or not.
  const one = await list(o.env, 'repo=o/x&number=3&state=open');
  assert.equal(one.status, 200);
  assert.ok(Object.hasOwn(one.body, 'row'));
});

test('L2e example-org/Cromford and example-org/cromford are one list', async (t) => {
  const o = await fresh(t); if (!o) return;
  await withColumns(o);
  seedRow(o.db, 'example-org/cromford', 1, 'open', ago(5));
  const a = await list(o.env, 'repo=example-org/Cromford&state=open');
  const b = await list(o.env, 'repo=example-org/cromford&state=open');
  assert.equal(a.body.rows.length, 1);
  assert.deepEqual(a.body, b.body);
});

// ── S: the full-list write ────────────────────────────────────────────────────
const row = (n, o = {}) => ({ number: n, fields: { state: 'open', title: `PR ${n}`, head_ref: `b/${n}`, head_sha: A, body: '', pr_updated_at: ago(n), ...o } });

test('S1 a sync upserts the rows, marks the open record not in the list unknown, leaves the others, stamps the list', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-s1';
  await withColumns(o);
  seedRow(o.db, repo, 4, 'open', ago(3600));
  seedRow(o.db, repo, 5, 'closed', ago(3600));
  seedRow(o.db, 'o/bh8452-s1-other', 4, 'open', ago(3600));
  const r = await sync(o.env, { repo, state: 'open', at: ago(10), rows: [row(1), row(2), row(3)] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { written: 3, absent: 1, synced_at: ago(10) });
  for (const n of [1, 2, 3]) {
    const x = rowOf(o.db, repo, n);
    assert.equal(x.state, 'open');
    assert.equal(x.last_source, 'github');
    assert.equal(x.gh_read_at, ago(10));
  }
  const gone = rowOf(o.db, repo, 4);
  assert.equal(gone.state, null, 'an open record not in the list is unknown');
  assert.equal(JSON.parse(gone.fields_at).state, ago(10));
  assert.equal(rowOf(o.db, repo, 5).state, 'closed');
  assert.equal(rowOf(o.db, 'o/bh8452-s1-other', 4).state, 'open', 'another repo is not touched');
  assert.deepEqual(o.db.prepare('SELECT repo, state, synced_at, rows FROM pr_record_lists').all().map((x) => ({ ...x })),
    [{ repo, state: 'open', synced_at: ago(10), rows: 3 }]);
  const g = await list(o.env, `repo=${repo}&state=open`);
  assert.deepEqual(g.body.rows.map((x) => x.number), [1, 2, 3]);
});

test('S2 a record whose state time is newer than the read stays open', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-s2';
  await withColumns(o);
  seedRow(o.db, repo, 9, 'open', ago(5));     // a webhook after the read
  seedRow(o.db, repo, 8, 'open', ago(100));   // equal to the read: the read wins
  const r = await sync(o.env, { repo, state: 'open', at: ago(100), rows: [row(1)] });
  assert.equal(r.body.absent, 1);
  assert.equal(rowOf(o.db, repo, 9).state, 'open');
  assert.equal(rowOf(o.db, repo, 8).state, null);
});

test('S3 a replay gives the same rows and absent:0; an older stamp does not move synced_at back', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-s3';
  await withColumns(o);
  seedRow(o.db, repo, 4, 'open', ago(3600));
  const body = { repo, state: 'open', at: ago(10), rows: [row(1), row(2)] };
  await sync(o.env, body);
  const snap = () => o.db.prepare('SELECT * FROM pr_records WHERE repo = ? ORDER BY number').all(repo).map((x) => ({ ...x }));
  const before = snap();
  const r = await sync(o.env, body);
  assert.equal(r.body.absent, 0);
  assert.deepEqual(snap(), before);
  const old = await sync(o.env, { ...body, at: ago(500), rows: [row(1)] });
  assert.equal(old.body.synced_at, ago(10));
  assert.deepEqual({ ...o.db.prepare('SELECT synced_at, rows FROM pr_record_lists').get() }, { synced_at: ago(10), rows: 2 });
  assert.equal(rowOf(o.db, repo, 2).state, 'open', 'an older list does not mark a newer row');
});

test('S4 bad bodies are 400 and write nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-s4';
  const ok = { repo, state: 'open', at: ago(10), rows: [row(1), row(2), row(3)] };
  const cases = [
    [{ ...ok, rows: [row(1), row(2), row(3, { head_sha: 'abc' })] }, { error: 'invalid_field', field: 'head_sha', index: 2 }],
    [{ ...ok, rows: [row(1), row(2), { number: 3, fields: { bogus: 1 } }] }, { error: 'unknown_field', field: 'bogus', index: 2 }],
    [{ ...ok, rows: [row(1), row(1)] }, { error: 'duplicate_number', field: 'number', index: 1 }],
    [{ ...ok, state: 'merged' }, { error: 'invalid_field', field: 'state' }],
    [{ ...ok, rows: 'x' }, { error: 'invalid_field', field: 'rows' }],
    [{ ...ok, at: 'now' }, { error: 'invalid_field', field: 'at' }],
    [{ ...ok, extra: 1 }, { error: 'unknown_key', field: 'extra' }],
    [{ ...ok, rows: Array.from({ length: 501 }, (_, i) => row(i + 1)) }, { error: 'too_many_rows', field: 'rows' }],
  ];
  for (const [body, want] of cases) {
    const r = await sync(o.env, body);
    assert.equal(r.status, 400, JSON.stringify(want));
    assert.deepEqual(r.body, want);
  }
  assert.equal(count(o.db), 0);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_record_lists').get().n, 0);
  // Edge: exactly the limit is accepted.
  const full = await sync(o.env, { ...ok, rows: Array.from({ length: 500 }, (_, i) => row(i + 1)) });
  assert.equal(full.status, 200, JSON.stringify(full.body));
  assert.equal(full.body.written, 500);
});

test('S5 a GET after a sync answers sync.age_s on the worker clock; a future `at` is the worker clock', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-s5';
  await sync(o.env, { repo, state: 'open', at: ago(42), rows: [row(1)] });
  const g = await list(o.env, `repo=${repo}&state=open`);
  assert.deepEqual(g.body.sync, { synced_at: ago(42), age_s: 42, rows: 1 });
  const f = await sync(o.env, { repo, state: 'open', at: '2026-10-26T13:00:00Z', rows: [row(1)] });
  assert.equal(f.body.synced_at, T);
  assert.equal((await list(o.env, `repo=${repo}&state=open`)).body.sync.age_s, 0);
  const empty = await sync(o.env, { repo: 'o/bh8452-s5-empty', state: 'open', rows: [] });
  assert.equal(empty.status, 200);
  const e = await list(o.env, 'repo=o/bh8452-s5-empty&state=open');
  assert.deepEqual(e.body, { rows: [], truncated: false, missing: null, unknown: 0, sync: { synced_at: T, age_s: 0, rows: 0 } });
});

test('S6 the shell writer body posts and lists back with the 13 keys', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = JSON.parse(readFileSync(new URL('bh-8452-list-sync-body.json', FIX), 'utf8'));
  const r = await sync(o.env, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const g = await list(o.env, 'repo=example-org/project-5&state=open&need=title,head_ref,body');
  assert.equal(g.body.missing, null);
  assert.deepEqual(g.body.rows.map((x) => x.number), [101, 102, 103]);
  for (const x of g.body.rows) assert.deepEqual(Object.keys(x).sort(), [...LIST_KEYS].sort());
  const r102 = g.body.rows[1];
  assert.equal(r102.body, 'Closes #12');
  assert.equal(r102.author, 'dependabot[bot]');
  assert.equal(r102.draft, 1);
  assert.deepEqual(r102.labels, []);
  assert.equal(g.body.rows[0].body, '');
  assert.equal(g.body.rows[0].head_ref, 'ticket/TK-11');
});

test('S7 an open PR a lagging list read left out is unknown:1 until a sync lists it; a webhook replay does not hide it', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh8452-s7';
  const h1 = await hook(o.env, 'pull_request', prEvent(repo, 'opened', 7, { updated_at: ago(5) }));
  assert.equal(h1.status, 200, JSON.stringify(h1.body));
  assert.equal(rowOf(o.db, repo, 7).state, 'open');
  // The list read started at T and GitHub's answer did not hold #7 yet.
  const s1 = await sync(o.env, { repo, state: 'open', at: T, rows: [row(8)] });
  assert.equal(s1.body.absent, 1);
  assert.equal(rowOf(o.db, repo, 7).state, null);
  // The same opened delivery again carries the older time: the row stays NULL.
  await hook(o.env, 'pull_request', prEvent(repo, 'opened', 7, { updated_at: ago(5) }));
  assert.equal(rowOf(o.db, repo, 7).state, null);
  const g = await list(o.env, `repo=${repo}&state=open&need=title,head_ref,body`);
  assert.deepEqual(g.body.rows.map((x) => x.number), [8]);
  assert.equal(g.body.truncated, false);
  assert.equal(g.body.missing, null);
  assert.equal(g.body.unknown, 1, 'the record does not hold every open PR: a list reader must miss');
  assert.equal((await list(o.env, `repo=${repo}&state=merged`)).body.unknown, 0, 'no stamp for merged: nothing counted');
  // The reader's GitHub read after the miss lists #7: open again, unknown 0.
  t.mock.timers.setTime(NOW_MS + 60_000);
  const at2 = '2026-10-26T12:01:00Z';
  await sync(o.env, { repo, state: 'open', at: at2, rows: [row(7), row(8)] });
  assert.equal(rowOf(o.db, repo, 7).state, 'open');
  const g2 = await list(o.env, `repo=${repo}&state=open`);
  assert.deepEqual(g2.body.rows.map((x) => x.number).sort(), [7, 8]);
  assert.equal(g2.body.unknown, 0);
  // #8 closes with a lost webhook: the next sync marks it unknown (counted once);
  // the sync after that leaves its mark older than the stamp (not counted).
  t.mock.timers.setTime(NOW_MS + 120_000);
  await sync(o.env, { repo, state: 'open', at: '2026-10-26T12:02:00Z', rows: [row(7)] });
  assert.equal((await list(o.env, `repo=${repo}&state=open`)).body.unknown, 1);
  t.mock.timers.setTime(NOW_MS + 180_000);
  await sync(o.env, { repo, state: 'open', at: '2026-10-26T12:03:00Z', rows: [row(7)] });
  assert.equal(rowOf(o.db, repo, 8).state, null);
  assert.equal((await list(o.env, `repo=${repo}&state=open`)).body.unknown, 0);
});

// ── X: plans at volume ─────────────────────────────────────────────────────────
async function seeded5000(t) {
  const o = await fresh(t); if (!o) return null;
  await withColumns(o);
  const STATES = ['open', 'closed', 'merged', null];
  o.db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, ts = ago(i * 600);
      vals.push('(?,?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 40}`, i + 1, STATES[i % 4], '{}', ts, ts, ts);
    }
    o.db.prepare(`INSERT INTO pr_records (repo, number, state, fields_at, created_at, refreshed_at, pr_updated_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  assert.equal(count(o.db), 5000);
  return o;
}
function check(db, sql, binds, index, tables = ['pr_records']) {
  const p = plan(db, sql, ...binds);
  assert.deepEqual(fullScans(p, tables), [], p.join(' | '));
  assert.ok(p.some((l) => l.includes(index)), `${index} not in: ${p.join(' | ')}`);
}

test('X1 LIST_SQL, SYNC_SQL and UNKNOWN_SQL use their index and no SCAN on 5,000 rows', async (t) => {
  const o = await seeded5000(t); if (!o) return;
  check(o.db, LIST_SQL, ['o/repo-7', 'open', null, 501], 'idx_pr_records_repo_state_upd');
  check(o.db, LIST_SQL, ['o/repo-7', 'open', ago(86400), 501], 'idx_pr_records_repo_state_upd');
  check(o.db, SYNC_SQL, ['o/repo-7', 'open'], 'ux_pr_record_lists_repo_state', ['pr_record_lists']);
  check(o.db, UNKNOWN_SQL, ['o/repo-7', 'open'], 'idx_pr_records_repo_state_upd', ['pr_records', 'pr_record_lists']);
});

test('X2 ABSENT_SQL and STAMP_SQL use an index and no SCAN on 5,000 rows', async (t) => {
  const o = await seeded5000(t); if (!o) return;
  check(o.db, ABSENT_SQL, ['o/repo-7', '[1,2,3]', T], 'idx_pr_records_repo_state_upd');
  const p = plan(o.db, STAMP_SQL, 'o/repo-7', 'open', T, 3);
  assert.deepEqual(fullScans(p, ['pr_record_lists', 'pr_records']), [], p.join(' | '));
  o.db.prepare(STAMP_SQL).run('o/repo-7', 'open', T, 3);
  o.db.prepare(STAMP_SQL).run('o/repo-7', 'open', T, 4);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_record_lists').get().n, 1, 'the conflict target is ux_pr_record_lists_repo_state');
});
