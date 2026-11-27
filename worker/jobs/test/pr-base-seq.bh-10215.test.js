// BH-10215: the base sequence per (repo, base branch). A `push` webhook to a
// base branch raises it by 1; the record row stores the sequence its
// mergeable_state was read at; GET /api/pr-base-seqs reads it; the list read
// takes with=head_commit; a retention rule ages the rows out.
// Driven through the REAL worker.fetch (signed POST /webhooks/github, PUT and
// GET /api/pr-records, GET /api/pr-base-seqs, POST /api/retention/run) on
// node:sqlite with the composed jobs schema. Each case opens its own fresh DB
// and uses its own repo slug.
//   W1  push to main (default) on a repo with no row -> seq 1 (the wake batch path)
//   W2  A then B -> 2; a fresh repo B then A -> 2; seq never decreases; a branch delete raises
//   W3  a replay changes 0; the same delivery id twice -> 1 raise (claim guard); recordPrRecord replay -> 0
//   W4  feature/x (no open PR's base, not default) -> no row; ticket/a (an open record's base) -> seq 1
//   W5  near misses: tag ref, bad after, no repository, other events -> nothing
//   W6  prRecordWritesOf('push', ...) is unchanged
//   W7  PUT mergeable_base_seq: stored and stamped with mergeable_state; bad values are 400
//   W8  GET /api/pr-base-seqs: this repo only; bad repo 400; no bearer 401; the read_limit row caps
//   W9  list with=head_commit adds head_commit; without it the keys are LIST_KEYS; with=body 400
//   W10 EXPLAIN on 2,000 pr_base_seqs and 5,000 pr_records rows: no full SCAN
//   W11 retention pr_base_seqs.age: a 40-day row goes, a 1-day row stays, a dry run deletes nothing
//   W12 the route table fragment lists exactly GET /api/pr-base-seqs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { ensureColumns, ensureTable } from '../src/lib/core.js';
import { LIST_KEYS } from '../src/routes/pr-records.js';
import { recordPrRecord, prRecordWritesOf } from '../src/lib/pr-record-intake.js';
import { BASE_SEQ_SQL, baseSeqSql, baseSeqWritesOf, READ_SQL } from '../src/lib/pr-base-seq.js';

const SECRET = 'tok-fixture-bh10215';
const GH = 'gh-fixture-bh10215';
const NOW_MS = Date.parse('2026-11-26T12:00:00Z');
const T = '2026-11-26T12:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const epoch = (iso) => Math.floor(Date.parse(iso) / 1000);
const A = 'a'.repeat(40), B = 'b'.repeat(40), C = 'c'.repeat(40), Z = '0'.repeat(40);

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: GH } };
}
async function api(env, method, path, body, auth = true) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { 'content-type': 'application/json', ...(auth ? { authorization: `Bearer ${SECRET}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), env);
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, body: parsed, text };
}
let dn = 0;
async function hook(env, event, payload, delivery = null) {
  const body = JSON.stringify(payload);
  dn += 1;
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': delivery || `dlv-10215-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const pushEvent = (repo, branch, after, o = {}) => ({
  ref: `refs/heads/${branch}`, before: C, after, deleted: false,
  head_commit: null,
  repository: { full_name: repo, default_branch: 'main', pushed_at: epoch(ago(30)) }, ...o,
});
const hasTable = (db) => Boolean(db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='pr_base_seqs'").get());
const seqRow = (db, repo, base) => (hasTable(db)
  ? db.prepare('SELECT * FROM pr_base_seqs WHERE repo = ? AND base_ref = ?').get(repo, base) || null : null);
const seqCount = (db, repo) => (hasTable(db) ? db.prepare('SELECT COUNT(*) AS n FROM pr_base_seqs WHERE repo = ?').get(repo).n : 0);
const put = (env, repo, number, fields, extra = {}) => api(env, 'PUT', '/api/pr-records', { repo, number, source: 'fleet', fields, ...extra });

// ── W1 ──────────────────────────────────────────────────────────────────────────
test('W1 push to main (the default branch) on a repo with no row -> seq 1, through the wake batch', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w1';
  const r = await hook(o.env, 'push', pushEvent(repo, 'main', A.toUpperCase()));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.wake.kind, 'push', 'a default-branch push wakes, so it took the in-batch path');
  const row = seqRow(o.db, repo, 'main');
  assert.ok(row, 'a row for (repo, main)');
  assert.equal(row.seq, 1);
  assert.equal(row.last_sha, A, 'the sha is stored lowercase');
  assert.equal(row.pushed_at, ago(30), 'pushed_at from repository.pushed_at (epoch), no fraction');
  assert.equal(row.updated_at, T);
});

// ── W2 ──────────────────────────────────────────────────────────────────────────
test('W2 two pushes in either order give seq 2; seq never decreases; a branch delete is a raise', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r1 = 'o/bh10215-w2a', r2 = 'o/bh10215-w2b';
  const seen = [];
  for (const sha of [A, B]) { await hook(o.env, 'push', pushEvent(r1, 'main', sha)); seen.push(seqRow(o.db, r1, 'main').seq); }
  assert.deepEqual(seen, [1, 2]);
  const seen2 = [];
  for (const sha of [B, A]) { await hook(o.env, 'push', pushEvent(r2, 'main', sha)); seen2.push(seqRow(o.db, r2, 'main').seq); }
  assert.deepEqual(seen2, [1, 2]);
  // An ISO pushed_at older than the stored one does not move pushed_at back.
  await hook(o.env, 'push', pushEvent(r2, 'main', C, { repository: { full_name: r2, default_branch: 'main', pushed_at: ago(3600) } }));
  const row = seqRow(o.db, r2, 'main');
  assert.equal(row.seq, 3);
  assert.equal(row.last_sha, C);
  assert.equal(row.pushed_at, ago(30), 'pushed_at only moves forward');
  // A branch delete (after = all zeros) moved the base: it raises.
  await hook(o.env, 'push', pushEvent(r2, 'main', Z, { deleted: true }));
  assert.equal(seqRow(o.db, r2, 'main').seq, 4);
  assert.equal(seqRow(o.db, r2, 'main').last_sha, Z);
});

// ── W3 ──────────────────────────────────────────────────────────────────────────
test('W3 a replay changes nothing; the same delivery id twice is 1 raise; recordPrRecord replay writes 0', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w3';
  await hook(o.env, 'push', pushEvent(repo, 'main', A));
  await hook(o.env, 'push', pushEvent(repo, 'main', B));
  assert.equal(seqRow(o.db, repo, 'main').seq, 2);
  // A redelivery under a new id: same body, same `after` -> 0 changes.
  const before = seqRow(o.db, repo, 'main');
  await hook(o.env, 'push', pushEvent(repo, 'main', B));
  assert.deepEqual(seqRow(o.db, repo, 'main'), before, 'a replay changes no column');

  // The same delivery id twice through the wake batch -> 1 raise. The second
  // body even carries a new sha: only the claim guard stops it.
  const repo2 = 'o/bh10215-w3b';
  const d1 = await hook(o.env, 'push', pushEvent(repo2, 'main', A), 'dlv-10215-w3-same');
  assert.equal(d1.body.duplicate, false);
  const d2 = await hook(o.env, 'push', pushEvent(repo2, 'main', A), 'dlv-10215-w3-same');
  assert.equal(d2.body.duplicate, true);
  const d3 = await hook(o.env, 'push', pushEvent(repo2, 'main', C), 'dlv-10215-w3-same');
  assert.equal(d3.body.duplicate, true);
  assert.equal(seqRow(o.db, repo2, 'main').seq, 1, 'one delivery id, one raise');
  assert.equal(seqRow(o.db, repo2, 'main').last_sha, A);

  // recordPrRecord (the path of a push that does not wake): a replay changes
  // nothing. `written` counts pr_records rows only, so it stays 0 here.
  const repo3 = 'o/bh10215-w3c';
  assert.equal((await put(o.env, repo3, 1, { state: 'open', base_ref: 'ticket/base', head_ref: 'ticket/top' })).status, 200);
  const p = pushEvent(repo3, 'ticket/base', A);
  assert.deepEqual(await recordPrRecord(o.env, T, 'push', p), { written: 0 });
  const first = seqRow(o.db, repo3, 'ticket/base');
  assert.equal(first.seq, 1);
  assert.deepEqual(await recordPrRecord(o.env, T, 'push', p), { written: 0 });
  assert.deepEqual(seqRow(o.db, repo3, 'ticket/base'), first, 'a recordPrRecord replay changes no column');
  await recordPrRecord(o.env, T, 'push', pushEvent(repo3, 'ticket/base', B));
  assert.equal(seqRow(o.db, repo3, 'ticket/base').seq, 2);
});

// ── W4 ──────────────────────────────────────────────────────────────────────────
test('W4 a branch that is no open PR base gets no row; an open record base gets seq 1', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w4';
  assert.equal((await put(o.env, repo, 1, { state: 'open', base_ref: 'ticket/a', head_ref: 'ticket/b' })).status, 200);
  assert.equal((await put(o.env, repo, 2, { state: 'closed', base_ref: 'ticket/c', head_ref: 'ticket/d' })).status, 200);
  const f = await hook(o.env, 'push', pushEvent(repo, 'feature/x', A));
  assert.equal(f.status, 202, 'a feature push wakes nothing');
  assert.equal(seqRow(o.db, repo, 'feature/x'), null);
  await hook(o.env, 'push', pushEvent(repo, 'ticket/c', A));
  assert.equal(seqRow(o.db, repo, 'ticket/c'), null, 'the base of a closed PR only');
  // No head_commit: prRecordWritesOf gives no write, the base sequence still rises.
  const r = await hook(o.env, 'push', pushEvent(repo, 'ticket/a', A));
  assert.equal(r.status, 202);
  assert.equal(seqRow(o.db, repo, 'ticket/a').seq, 1);
  assert.equal(seqCount(o.db, repo), 1);
});

// ── W5 ──────────────────────────────────────────────────────────────────────────
test('W5 near misses: tag ref, bad after, no repository, other events -> nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w5';
  const cases = [
    ['tag ref', 'push', { ...pushEvent(repo, 'main', A), ref: 'refs/tags/v1' }],
    ['after short', 'push', pushEvent(repo, 'main', 'abc123')],
    ['after not hex', 'push', pushEvent(repo, 'main', 'g'.repeat(40))],
    ['after missing', 'push', pushEvent(repo, 'main', undefined)],
    ['no repository', 'push', { ...pushEvent(repo, 'main', A), repository: undefined }],
    ['bad repo', 'push', pushEvent('no-slash', 'main', A)],
    ['pull_request', 'pull_request', { action: 'synchronize', number: 1, after: A, ref: 'refs/heads/main', repository: { full_name: repo, default_branch: 'main' },
      pull_request: { number: 1, state: 'open', head: { ref: 'x', sha: A }, base: { ref: 'main', sha: B } } }],
    ['check_run', 'check_run', { action: 'completed', after: A, ref: 'refs/heads/main', repository: { full_name: repo },
      check_run: { name: 'ci', status: 'completed', conclusion: 'success', head_sha: A, pull_requests: [] } }],
  ];
  for (const [name, event, p] of cases) {
    assert.deepEqual(baseSeqWritesOf(event, p, T), [], name);
    await hook(o.env, event, p);
  }
  assert.deepEqual(baseSeqWritesOf('push', null, T), []);
  assert.equal(seqCount(o.db, repo), 0);
  // The near-hit: the same push with a good ref and sha writes.
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'main', A), T).length, 1);
});

// ── W6 ──────────────────────────────────────────────────────────────────────────
test('W6 prRecordWritesOf for a push is unchanged', () => {
  const repo = 'o/bh10215-w6';
  assert.deepEqual(prRecordWritesOf('push', pushEvent(repo, 'main', A), T), [{ kind: 'base-push', repo, base_ref: 'main', at: T }]);
  assert.deepEqual(prRecordWritesOf('push', pushEvent(repo, 'ticket/a', A), T), []);
  const w = baseSeqWritesOf('push', pushEvent(repo, 'main', A), T);
  assert.deepEqual(w, [{ kind: 'base-seq', repo, base_ref: 'main', sha: A, pushed_at: ago(30), is_default: 1, at: T }]);
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'ticket/a', A), T)[0].is_default, 0);
  // A pushed_at later than the worker clock is clamped to it; none -> t.
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'main', A, { repository: { full_name: repo, pushed_at: epoch('2027-01-01T00:00:00Z') } }), T)[0].pushed_at, T);
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'main', A, { repository: { full_name: repo } }), T)[0].pushed_at, T);
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'main', A, { repository: { full_name: repo, pushed_at: '2026-11-26T11:00:00.250Z' } }), T)[0].pushed_at, '2026-11-26T11:00:00Z');
  // No default_branch: main is the default.
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'main', A, { repository: { full_name: repo } }), T)[0].is_default, 1);
  assert.equal(baseSeqWritesOf('push', pushEvent(repo, 'main', A, { repository: { full_name: repo, default_branch: 'develop' } }), T)[0].is_default, 0);
});

// ── W7 ──────────────────────────────────────────────────────────────────────────
test('W7 PUT mergeable_base_seq is stored and stamped with mergeable_state; bad values are 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w7';
  const r = await put(o.env, repo, 3, { state: 'open', mergeable_state: 'clean', mergeable_base_seq: 3 }, { source: 'github', at: ago(60) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.row.mergeable_base_seq, 3);
  assert.equal(r.body.row.fields_at.mergeable_base_seq, r.body.row.fields_at.mergeable_state);
  assert.equal(r.body.row.fields_at.mergeable_base_seq, ago(60));
  const g = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&number=3`);
  assert.equal(g.body.row.mergeable_base_seq, 3, 'the peek returns it');
  assert.equal((await put(o.env, repo, 3, { mergeable_base_seq: 0 })).status, 200, '0 is a valid sequence');
  for (const bad of [-1, 1.5, '3', null, 2 ** 53]) {
    const b = await put(o.env, repo, 3, { mergeable_base_seq: bad });
    assert.equal(b.status, 400, String(bad));
    assert.equal(b.body.field, 'mergeable_base_seq', String(bad));
  }
});

// ── W8 ──────────────────────────────────────────────────────────────────────────
test('W8 GET /api/pr-base-seqs reads one repo only; bad repo 400; no bearer 401; the read_limit row caps', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r1 = 'o/bh10215-w8a', r2 = 'o/bh10215-w8b', r3 = 'o/bh10215-w8c';
  await hook(o.env, 'push', pushEvent(r1, 'main', A));
  await hook(o.env, 'push', pushEvent(r1, 'main', B));
  await hook(o.env, 'push', pushEvent(r2, 'main', A));
  const g = await api(o.env, 'GET', `/api/pr-base-seqs?repo=${r1.toUpperCase()}`);
  assert.equal(g.status, 200, g.text);
  assert.deepEqual(g.body, { rows: [{ base_ref: 'main', seq: 2, pushed_at: ago(30) }] });
  const none = await api(o.env, 'GET', `/api/pr-base-seqs?repo=${r3}`);
  assert.deepEqual(none.body, { rows: [] }, 'a repo with no push: 0 rows');
  for (const bad of ['', 'no-slash', 'o/a b', 'o/' + 'x'.repeat(101)]) {
    const b = await api(o.env, 'GET', `/api/pr-base-seqs?repo=${encodeURIComponent(bad)}`);
    assert.equal(b.status, 400, bad);
    assert.deepEqual(b.body, { error: 'invalid_field', field: 'repo' });
  }
  assert.equal((await api(o.env, 'GET', `/api/pr-base-seqs?repo=${r1}`, undefined, false)).status, 401);
});

test('W8b the pr_base_seqs.read_limit row caps the read; a bad row value falls back to 500', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w8d';
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key = 'pr_base_seqs.read_limit'").get().value, '500');
  o.db.prepare("UPDATE settings SET value = '2' WHERE key = 'pr_base_seqs.read_limit'").run();
  await ensureTable(o.env, 'pr_base_seqs');
  const ins = o.db.prepare('INSERT INTO pr_base_seqs (repo, base_ref, seq, last_sha, pushed_at, updated_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 5; i++) ins.run(repo, `ticket/b-${i}`, 1, A, T, T);
  const g = await api(o.env, 'GET', `/api/pr-base-seqs?repo=${repo}`);
  assert.equal(g.body.rows.length, 2);
  // A second fresh DB (the settings cache is per DB): a bad row value -> 500.
  const o2 = await openDb();
  o2.db.prepare("UPDATE settings SET value = 'x' WHERE key = 'pr_base_seqs.read_limit'").run();
  await ensureTable({ DB: o2.DB }, 'pr_base_seqs');
  const ins2 = o2.db.prepare('INSERT INTO pr_base_seqs (repo, base_ref, seq, last_sha, pushed_at, updated_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 5; i++) ins2.run(repo, `ticket/b-${i}`, 1, A, T, T);
  const g2 = await api({ ...o.env, DB: o2.DB }, 'GET', `/api/pr-base-seqs?repo=${repo}`);
  assert.equal(g2.body.rows.length, 5);
});

// ── W9 ──────────────────────────────────────────────────────────────────────────
test('W9 the list read: with=head_commit adds head_commit; without it the answer keys are LIST_KEYS; with=body is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w9';
  const hc = { sha: A, at: ago(100) };
  assert.equal((await put(o.env, repo, 1, { state: 'open', head_ref: 'ticket/one', head_commit: hc, pr_updated_at: ago(50) })).status, 200);
  assert.equal((await put(o.env, repo, 2, { state: 'open', head_ref: 'ticket/two', pr_updated_at: ago(40) })).status, 200);
  const plain = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&state=open`);
  assert.equal(plain.status, 200);
  for (const row of plain.body.rows) assert.deepEqual(Object.keys(row).sort(), [...LIST_KEYS].sort());
  const w = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&state=open&with=head_commit`);
  assert.equal(w.status, 200, w.text);
  const byNum = Object.fromEntries(w.body.rows.map((r) => [r.number, r]));
  assert.deepEqual(byNum[1].head_commit, hc, 'parsed, not text');
  assert.equal(byNum[2].head_commit, null);
  for (const row of w.body.rows) assert.deepEqual(Object.keys(row).sort(), [...LIST_KEYS, 'head_commit'].sort());
  // The rest of the answer is the same as without `with`.
  const strip = (b) => ({ ...b, rows: b.rows.map(({ head_commit, ...r }) => r) });
  assert.deepEqual(strip(w.body), plain.body);
  for (const bad of ['body', 'head_commit,body', '']) {
    const b = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&state=open&with=${bad}`);
    assert.equal(b.status, 400, bad);
    assert.deepEqual(b.body, { error: 'invalid_field', field: 'with' });
  }
  // The created-order window takes it too.
  const c = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&state=open&order=created&with=head_commit`);
  assert.equal(c.status, 200);
  assert.ok(c.body.rows.every((r) => 'head_commit' in r));
});

// ── W10 ─────────────────────────────────────────────────────────────────────────
test('W10 2,000 pr_base_seqs and 5,000 pr_records rows: the read, the upsert (EXISTS) and the retention ids use an index', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ensureTable(o.env, 'pr_records');
  await ensureColumns(o.env, 'pr_records');
  await ensureTable(o.env, 'pr_base_seqs');
  await ensureColumns(o.env, 'webhook_deliveries');
  const STATES = ['open', 'closed', 'merged', null];
  o.db.exec('BEGIN');
  const rec = o.db.prepare('INSERT INTO pr_records (repo, number, state, head_sha, head_ref, base_ref, fields_at, created_at, refreshed_at, pr_updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) {
    const ts = ago(i * 600);
    rec.run(`o/repo-${i % 40}`, i + 1, STATES[i % 4], i.toString(16).padStart(40, '0'), `ticket/x-${i}`, i % 5 ? 'main' : `ticket/x-${i - 1}`, '{}', ts, ts, ts);
  }
  const seq = o.db.prepare('INSERT INTO pr_base_seqs (repo, base_ref, seq, last_sha, pushed_at, updated_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 2000; i++) {
    const ts = ago(i * 1200);
    seq.run(`o/repo-${i % 40}`, i < 40 ? 'main' : `ticket/b-${i}`, i + 1, i.toString(16).padStart(40, '0'), ts, ts);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_base_seqs').get().n, 2000);
  const TABLES = ['pr_base_seqs', 'pr_records'];
  const check = (name, sql, binds, index) => {
    const p = plan(o.db, sql, ...binds);
    assert.deepEqual(fullScans(p, TABLES), [], `${name}: ${p.join(' | ')}`);
    if (index) assert.ok(p.some((l) => (index instanceof RegExp ? index.test(l) : l.includes(index))), `${name}: ${index} not in: ${p.join(' | ')}`);
    return p;
  };
  check('read', READ_SQL, ['o/repo-7', 500], 'sqlite_autoindex_pr_base_seqs_1');
  // The EXISTS takes an index on (repo, state): idx_pr_records_repo_state_upd
  // or its sibling idx_pr_records_repo_state_created, whichever ANALYZE picks.
  const EXISTS_IX = /^SEARCH pr_records USING INDEX idx_pr_records_repo_state_\w+ \(repo=\? AND state=\?\)/;
  check('upsert', BASE_SEQ_SQL, ['o/repo-7', 'ticket/x-6', A, T, 0, T], EXISTS_IX);
  check('upsert+claim', baseSeqSql({ guardAt: 7 }), ['o/repo-7', 'ticket/x-6', A, T, 0, T, 'dlv', 'claim'], EXISTS_IX);
  const rule = (await import('../src/routes/retention.d/bh-10215-pr-base-seqs.js')).default[0];
  check('retention ids', rule.ids, [ago(30 * 86400), 500], 'idx_pr_base_seqs_updated');
  check('retention count', `SELECT COUNT(*) AS n FROM (${rule.ids})`, [ago(30 * 86400), 250001], 'idx_pr_base_seqs_updated');
  // The upsert hits the existing (repo, base_ref) row: no new row.
  o.db.prepare(BASE_SEQ_SQL).run('o/repo-0', 'main', B, T, 1, T);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_base_seqs').get().n, 2000);
  assert.equal(o.db.prepare("SELECT seq FROM pr_base_seqs WHERE repo = 'o/repo-0' AND base_ref = 'main'").get().seq, 2);
});

// ── W11 ─────────────────────────────────────────────────────────────────────────
test('W11 retention pr_base_seqs.age deletes a 40-day-old row, keeps a 1-day-old row; a dry run deletes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10215-w11';
  await ensureTable(o.env, 'pr_base_seqs');
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key = 'retention.pr_base_seqs.days'").get().value, '30');
  const rule = (await import('../src/routes/retention.d/bh-10215-pr-base-seqs.js')).default;
  assert.equal(rule.length, 1);
  assert.equal(rule[0].rule, 'pr_base_seqs.age');
  assert.equal(rule[0].key, 'retention.pr_base_seqs.days');
  assert.equal(rule[0].def, 30);
  const ins = o.db.prepare('INSERT INTO pr_base_seqs (repo, base_ref, seq, last_sha, pushed_at, updated_at) VALUES (?,?,?,?,?,?)');
  ins.run(repo, 'old', 4, A, ago(40 * 86400), ago(40 * 86400));
  ins.run(repo, 'new', 2, A, ago(86400), ago(86400));
  const kept = () => o.db.prepare('SELECT base_ref FROM pr_base_seqs WHERE repo = ? ORDER BY base_ref').all(repo).map((r) => r.base_ref);
  o.db.prepare("UPDATE settings SET value = '0' WHERE key = 'retention.dry_run'").run();
  const dry = await api(o.env, 'POST', '/api/retention/run', { dry_run: true });
  assert.equal(dry.status, 200, dry.text);
  const dr = dry.body.rules.find((x) => x.rule === 'pr_base_seqs.age');
  assert.ok(dr, dry.text);
  assert.equal(dr.counted, 1);
  assert.equal(dr.removed, 0);
  assert.deepEqual(kept(), ['new', 'old'], 'a dry run deletes nothing');
  const run = await api(o.env, 'POST', '/api/retention/run', {});
  assert.equal(run.status, 200, run.text);
  const rr = run.body.rules.find((x) => x.rule === 'pr_base_seqs.age');
  assert.equal(rr.removed, 1, JSON.stringify(rr));
  assert.equal(rr.error, null);
  assert.deepEqual(kept(), ['new']);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule = 'pr_base_seqs.age'").get().n, 2, 'one audit row per run');
});

// ── W12 ─────────────────────────────────────────────────────────────────────────
test('W12 the route table fragment lists exactly GET /api/pr-base-seqs', () => {
  const text = readFileSync(new URL('./route-table.d/bh-10215-pr-base-seqs.txt', import.meta.url), 'utf8');
  const lines = text.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
  assert.deepEqual(lines, ['GET /api/pr-base-seqs']);
});
