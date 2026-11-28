// BH-10199 (slice 1): the issue record. issue_records, issue_comments and
// issue_record_syncs, driven through the REAL worker.fetch (POST
// /webhooks/github, GET and PUT /api/issue-records, the two sync routes) on
// node:sqlite with the composed jobs schema. A fixture clock (mock Date) and
// fixture GitHub payloads; no network. Each case opens its own DB and repo.
//   W1  issue_comment created, edited, deleted -> 1 row with the last state;
//       an older edit after a newer one changes nothing; a late `created`
//       after `deleted` does not bring it back
//   W2  each applied webhook change adds 1 to rev; a replay of the same
//       delivery body (a new delivery id) adds 0; two comments in one minute
//       add 2 (the wake row is one)
//   W3  issues labeled then an older edited: newer only; issues.deleted drops
//       the record and its comments
//   W4  PUT with base_rev = rev: backfill, a stored comment not in the list is
//       marked deleted, stale_at cleared, rev + 1; a stale base_rev: applied
//       false and 0 rows changed; a comments-only PUT (issue null) keeps the
//       issue fields and needs a stored row
//   W5  GET why: no-record, no-backfill, no-sync, null, stale, backfill-old,
//       sync-old, truncated, too-many
//   W6  sync claim: due on no row; not due right after a complete sync; a
//       second claim inside the lease is not due; since = the mark
//   W7  sync write: a newer item sets stale_at and rev + 1; an equal item
//       changes nothing; an unknown issue writes no row; complete stamps
//       synced_at = started; incomplete moves the mark only
//   W8  a duplicate delivery id changes no record row (the claim guard)
//   W9  EXPLAIN QUERY PLAN at volume: no SCAN of the three tables
//   W10 bad bodies -> 400 naming the field; no bearer -> 401
//   W11 (review of #10343) a lost comment, then a later comment whose
//       issue.comments is above the stored count: stale; the full read
//       repairs it. W11b: equal counts, a deleted comment, a late older
//       delivery and a payload with no count stay ready
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import {
  GET_SQL, COMMENTS_SQL, SYNC_GET_SQL, PUT_COMMENTS_SQL, PUT_THREAD_SQL, PUT_ABSENT_SQL, PUT_ISSUE_SQL, CLAIM_SQL,
  SYNC_ITEM_SQL, SYNC_STAMP_SQL, issueUpsertSql, commentUpsertSql, COMMENT_REV_SQL, COUNT_STALE_SQL,
} from '../src/routes/issue-records.js';
import { RULES } from '#retention-rules';

const SECRET = 'tok-fixture-bh10199';
const GH = 'gh-fixture-bh10199';
const NOW_MS = Date.parse('2026-11-27T06:00:00Z');
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fresh(t, settings = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  for (const [k, v] of Object.entries(settings)) o.db.prepare('UPDATE settings SET value = ? WHERE key = ?').run(String(v), k);
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: GH } };
}
async function api(env, method, path, body, auth = true) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { 'content-type': 'application/json', ...(auth ? { authorization: `Bearer ${SECRET}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
let dn = 0;
async function hook(env, event, payload, delivery) {
  const body = JSON.stringify(payload);
  dn += 1;
  const headers = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': delivery || `dlv-10199-${dn}`,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', GH).update(body).digest('hex') };
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const issue = (n, o = {}) => ({ number: n, state: 'open', title: `T${n}`, body: 'b', labels: [{ name: 'ai-build' }], updated_at: ago(600), ...o });
const comment = (id, o = {}) => ({ id, body: `c${id}`, created_at: ago(500), updated_at: ago(500), user: { login: 'operator', type: 'User' }, ...o });
const cEvent = (repo, action, n, c, io = {}) => ({ action, repository: { full_name: repo }, issue: issue(n, io), comment: c });
const iEvent = (repo, action, n, io = {}) => ({ action, repository: { full_name: repo }, issue: issue(n, io) });
const rec = (db, repo, n) => db.prepare('SELECT * FROM issue_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const cmt = (db, repo, id) => db.prepare('SELECT * FROM issue_comments WHERE repo = ? AND comment_id = ?').get(repo, id) || null;
const get = (env, repo, n) => api(env, 'GET', `/api/issue-records?repo=${repo}&number=${n}`);
const put = (env, body) => api(env, 'PUT', '/api/issue-records', body);
const claim = (env, repo) => api(env, 'POST', '/api/issue-record-syncs/claim', { repo });
const sync = (env, body) => api(env, 'POST', '/api/issue-record-syncs', body);

test('W1 created, edited, deleted gives 1 row with the last state; older and late events change nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w1';
  assert.equal((await hook(o.env, 'issue_comment', cEvent(repo, 'created', 5, comment(11)))).status, 200);
  await hook(o.env, 'issue_comment', cEvent(repo, 'edited', 5, comment(11, { body: 'v2', updated_at: ago(300) }), { updated_at: ago(300) }));
  await hook(o.env, 'issue_comment', cEvent(repo, 'edited', 5, comment(11, { body: 'old', updated_at: ago(400) }), { updated_at: ago(400) }));
  let c = cmt(o.db, repo, 11);
  assert.deepEqual([c.body, c.deleted, c.gh_updated_at], ['v2', 0, ago(300)]);
  await hook(o.env, 'issue_comment', cEvent(repo, 'deleted', 5, comment(11, { body: 'v2', updated_at: ago(300) }), { updated_at: ago(200) }));
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 5, comment(11), { updated_at: ago(500) }));
  c = cmt(o.db, repo, 11);
  assert.equal(c.deleted, 1, 'a late created must not bring a deleted comment back');
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM issue_comments WHERE repo = ?').get(repo).n, 1);
  assert.equal(rec(o.db, repo, 5).gh_updated_at, ago(200));
});

test('W2 rev counts applied changes; a replay adds 0; two comments in one minute add 2', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w2';
  const ev = cEvent(repo, 'created', 7, comment(21));
  await hook(o.env, 'issue_comment', ev);
  const r1 = rec(o.db, repo, 7).rev;
  await hook(o.env, 'issue_comment', ev);
  assert.equal(rec(o.db, repo, 7).rev, r1, 'a replay of the same body must add 0');
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 7, comment(22), { updated_at: ago(590) }));
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 7, comment(23), { updated_at: ago(580) }));
  assert.equal(rec(o.db, repo, 7).rev, r1 + 2);
  const w = o.db.prepare("SELECT COUNT(*) AS n FROM wakes WHERE repo = ? AND kind = 'issue' AND key = '7'").get(repo).n;
  assert.equal(w, 1, 'the fixture must put both comments in one wake minute');
});

test('W3 issues events are newer only; issues.deleted drops the record', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w3';
  await hook(o.env, 'issues', iEvent(repo, 'labeled', 9, { labels: [{ name: 'ai-build' }, { name: 'hold' }], updated_at: ago(100) }));
  await hook(o.env, 'issues', iEvent(repo, 'edited', 9, { title: 'older', updated_at: ago(200) }));
  const r = rec(o.db, repo, 9);
  assert.deepEqual([JSON.parse(r.labels), r.title, r.is_pr], [['ai-build', 'hold'], 'T9', 0]);
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 9, comment(31), { updated_at: ago(50) }));
  await hook(o.env, 'issues', iEvent(repo, 'deleted', 9));
  assert.equal(rec(o.db, repo, 9), null);
  assert.equal(cmt(o.db, repo, 31), null);
});

test('W4 PUT applies only on the base rev', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w4';
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 3, comment(41)));
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 3, comment(42), { updated_at: ago(590) }));
  o.db.prepare("UPDATE issue_records SET stale_at = ? WHERE repo = ?").run(ago(100), repo);
  const base = rec(o.db, repo, 3).rev;
  const body = { repo, number: 3, base_rev: base, issue: issue(3, { updated_at: ago(60) }), comments: [comment(41), comment(43)] };
  const stale = await put(o.env, { ...body, base_rev: base - 1 });
  assert.deepEqual(stale.body, { applied: false, rev: null });
  assert.equal(cmt(o.db, repo, 43), null, 'a refused PUT writes no comment');
  assert.equal(rec(o.db, repo, 3).backfill_at, null);
  const r = await put(o.env, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { applied: true, rev: base + 1 });
  const row = rec(o.db, repo, 3);
  assert.deepEqual([row.backfill_at, row.stale_at], [ago(0), null]);
  assert.deepEqual([cmt(o.db, repo, 42).deleted, cmt(o.db, repo, 43).deleted, cmt(o.db, repo, 41).seen_at], [1, 0, ago(0)]);
  // first seen: base 0 creates the row
  const n = await put(o.env, { repo, number: 4, base_rev: 0, issue: issue(4), comments: [] });
  assert.deepEqual(n.body, { applied: true, rev: 1 });
  // a comments-only read (issue null) of a stored row; none for no row
  o.db.prepare("UPDATE issue_records SET stale_at = ? WHERE repo = ? AND number = 4").run(ago(5), repo);
  const c = await put(o.env, { repo, number: 4, base_rev: 1, issue: null, comments: [comment(44)] });
  assert.deepEqual(c.body, { applied: true, rev: 2 });
  assert.deepEqual([rec(o.db, repo, 4).stale_at, rec(o.db, repo, 4).title, cmt(o.db, repo, 44).deleted], [null, 'T4', 0]);
  assert.equal((await put(o.env, { repo, number: 5, base_rev: 0, issue: null, comments: [] })).body.field, 'base_rev');
});

test('W5 GET answers the miss word, or null when ready', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w5';
  assert.equal((await get(o.env, repo, 1)).body.why, 'no-record');
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 1, comment(51)));
  assert.equal((await get(o.env, repo, 1)).body.why, 'no-backfill');
  await put(o.env, { repo, number: 1, base_rev: rec(o.db, repo, 1).rev, issue: issue(1), comments: [comment(51)] });
  assert.equal((await get(o.env, repo, 1)).body.why, 'no-sync');
  o.db.prepare('INSERT INTO issue_record_syncs (repo, mark, synced_at) VALUES (?, ?, ?)').run(repo, ago(600), ago(60));
  const ok = (await get(o.env, repo, 1)).body;
  assert.equal(ok.why, null);
  assert.deepEqual(ok.comments.map((c) => [c.comment_id, c.author, c.author_type]), [[51, 'operator', 'User']]);
  assert.deepEqual(ok.row.labels, ['ai-build']);
  o.db.prepare('UPDATE issue_records SET stale_at = ? WHERE repo = ?').run(ago(10), repo);
  assert.equal((await get(o.env, repo, 1)).body.why, 'stale');
  o.db.prepare('UPDATE issue_records SET stale_at = NULL, backfill_at = ? WHERE repo = ?').run(ago(604801), repo);
  assert.equal((await get(o.env, repo, 1)).body.why, 'backfill-old');
  o.db.prepare('UPDATE issue_records SET backfill_at = ? WHERE repo = ?').run(ago(10), repo);
  o.db.prepare('UPDATE issue_record_syncs SET synced_at = ? WHERE repo = ?').run(ago(1801), repo);
  assert.equal((await get(o.env, repo, 1)).body.why, 'sync-old');
  o.db.prepare('UPDATE issue_record_syncs SET synced_at = ? WHERE repo = ?').run(ago(60), repo);
  o.db.prepare('UPDATE issue_comments SET truncated = 1 WHERE repo = ?').run(repo);
  assert.equal((await get(o.env, repo, 1)).body.why, 'truncated');
});

test('W5b too-many: more comments than issue_records.comments_max', async (t) => {
  const o = await fresh(t, { 'issue_records.comments_max': 2 }); if (!o) return;
  const repo = 'o/bh10199-w5b';
  const r = await put(o.env, { repo, number: 1, base_rev: 0, issue: issue(1), comments: [comment(1), comment(2)] });
  assert.equal(r.body.applied, true);
  o.db.prepare('INSERT INTO issue_record_syncs (repo, synced_at) VALUES (?, ?)').run(repo, ago(5));
  assert.equal((await get(o.env, repo, 1)).body.why, null);
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 1, comment(3), { updated_at: ago(10) }));
  assert.equal((await get(o.env, repo, 1)).body.why, 'too-many');
  assert.equal((await put(o.env, { repo, number: 1, base_rev: 9, issue: issue(1), comments: [comment(1), comment(2), comment(3)] })).status, 400);
});

test('W6 the sync claim is due once per sync_every_s', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w6';
  const c1 = (await claim(o.env, repo)).body;
  assert.deepEqual(c1, { due: true, since: ago(604800), started: ago(0), pages_max: 5, every_s: 600 });
  assert.deepEqual((await claim(o.env, repo)).body, { due: false, every_s: 600 }, 'a second claim inside the lease');
  const w = await sync(o.env, { repo, started: c1.started, mark: ago(30), complete: true, items: [] });
  assert.deepEqual(w.body, { written: 0, synced_at: ago(0), mark: ago(30) });
  assert.deepEqual((await claim(o.env, repo)).body, { due: false, every_s: 600 });
  o.db.prepare('UPDATE issue_record_syncs SET synced_at = ? WHERE repo = ?').run(ago(601), repo);
  assert.deepEqual((await claim(o.env, repo)).body, { due: true, since: ago(30), started: ago(0), pages_max: 5, every_s: 600 });
});

test('W7 the sync write marks a missed change stale and stamps only a complete read', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w7';
  await put(o.env, { repo, number: 1, base_rev: 0, issue: issue(1, { updated_at: ago(600) }), comments: [] });
  await put(o.env, { repo, number: 2, base_rev: 0, issue: issue(2, { updated_at: ago(600) }), comments: [] });
  const items = [issue(1, { updated_at: ago(100), labels: [{ name: 'hold' }] }), issue(2, { updated_at: ago(600) }), issue(3, { updated_at: ago(50) })];
  const w = await sync(o.env, { repo, started: ago(5), mark: ago(50), complete: false, items });
  assert.equal(w.status, 200, JSON.stringify(w.body));
  assert.deepEqual(w.body, { written: 1, synced_at: null, mark: ago(50) });
  const r1 = rec(o.db, repo, 1);
  assert.deepEqual([r1.stale_at, r1.rev, JSON.parse(r1.labels)], [ago(100), 2, ['hold']]);
  assert.equal(rec(o.db, repo, 2).rev, 1, 'an equal updated_at changes nothing');
  assert.equal(rec(o.db, repo, 3), null, 'an unknown issue writes no row');
  const w2 = await sync(o.env, { repo, started: ago(5), mark: ago(80), complete: true, items: [] });
  assert.deepEqual(w2.body, { written: 0, synced_at: ago(5), mark: ago(50) }, 'the mark never moves back');
  assert.equal((await get(o.env, repo, 1)).body.why, 'stale');
  // a full read clears it
  await put(o.env, { repo, number: 1, base_rev: 2, issue: issue(1, { updated_at: ago(100) }), comments: [] });
  assert.equal((await get(o.env, repo, 1)).body.why, null);
});

test('W8 a duplicate delivery id changes no record row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w8';
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 2, comment(81)), 'dlv-w8-a');
  const r = rec(o.db, repo, 2).rev;
  const ev = cEvent(repo, 'edited', 2, comment(81, { body: 'x', updated_at: ago(100) }), { updated_at: ago(100) });
  await hook(o.env, 'issue_comment', ev, 'dlv-w8-a');
  assert.deepEqual([rec(o.db, repo, 2).rev, cmt(o.db, repo, 81).body], [r, 'c81'], 'a duplicate id must write nothing');
  await hook(o.env, 'issue_comment', ev, 'dlv-w8-b');
  assert.deepEqual([rec(o.db, repo, 2).rev, cmt(o.db, repo, 81).body], [r + 1, 'x']);
});

test('W9 every statement uses an index at volume', async (t) => {
  const o = await fresh(t); if (!o) return;
  const db = o.db;
  db.exec('BEGIN');
  const ir = db.prepare('INSERT INTO issue_records (repo, number, state, gh_updated_at, created_at, refreshed_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) ir.run(`o/r${i % 10}`, i, 'open', ago(i), ago(i), ago(i));
  const ic = db.prepare('INSERT INTO issue_comments (repo, number, comment_id, gh_created_at, body, seen_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 50000; i++) ic.run(`o/r${i % 10}`, i % 5000, i + 1, ago(i), 'x', ago(i));
  const is = db.prepare('INSERT INTO issue_record_syncs (repo, mark, synced_at) VALUES (?,?,?)');
  for (let i = 0; i < 10; i++) is.run(`o/r${i}`, ago(i), ago(i));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
  const T = ago(0), r = 'o/r1';
  const checks = [
    ['get row', plan(GET_SQL, r, 11), /ux_issue_records_repo_number/],
    ['get comments', plan(COMMENTS_SQL, r, 11, 1001), /idx_issue_comments_thread/],
    ['get sync', plan(SYNC_GET_SQL, r), /ux_issue_record_syncs_repo/],
    ['hook issue', plan(issueUpsertSql(), r, 11, 0, 'open', 't', 'b', '[]', T, 0, T), null],
    ['hook comment', plan(commentUpsertSql(), r, 11, 9, 'a', 'User', T, T, 'b', 0, 0, T), null],
    ['hook rev', plan(COMMENT_REV_SQL, r, 11, T), /ux_issue_records_repo_number/],
    ['hook count', plan(COUNT_STALE_SQL(), r, 11, 3, T, T), /idx_issue_comments_thread/],
    ['put comments', plan(PUT_COMMENTS_SQL, r, 11, '[]', T, 1), null],
    ['put absent', plan(PUT_ABSENT_SQL, r, 11, '[1,2]', T, 1), /idx_issue_comments_thread/],
    ['put thread', plan(PUT_THREAD_SQL, r, 11, T, 1), /ux_issue_records_repo_number/],
    ['put issue', plan(PUT_ISSUE_SQL, r, 11, 0, 'open', 't', 'b', '[]', T, 0, T, 1), null],
    ['claim', plan(CLAIM_SQL, r, T, T), null],
    ['sync item', plan(SYNC_ITEM_SQL, r, 11, 0, 'open', 't', 'b', '[]', T, 0, T), /ux_issue_records_repo_number/],
    ['sync stamp', plan(SYNC_STAMP_SQL, r, T, T, 0), null],
  ];
  for (const name of ['issue_records.age', 'issue_comments.age']) {
    const rule = RULES.find((x) => x.rule === name);
    assert.ok(rule, `no ${name} rule in #retention-rules`);
    checks.push([`${name} ids`, plan(rule.ids, ago(86400), 500), name.startsWith('issue_records') ? /idx_issue_records_refreshed/ : /idx_issue_comments_seen/]);
    checks.push([`${name} del`, plan(rule.del, '[1,2]'), null]);
  }
  for (const [name, details, want] of checks) {
    for (const d of details) assert.doesNotMatch(d, /^SCAN (issue_records|issue_comments|issue_record_syncs)\b(?!.*USING (COVERING )?INDEX)/, `${name}: ${d}`);
    if (want) assert.ok(details.some((d) => want.test(d)), `${name} does not use ${want}: ${details.join(' | ')}`);
  }
});

test('W10 bad bodies are a 400 that names the field; no bearer is a 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w10';
  const ok = { repo, number: 1, base_rev: 0, issue: issue(1), comments: [] };
  for (const [over, field] of [[{ repo: 'x' }, 'repo'], [{ number: 0 }, 'number'], [{ base_rev: -1 }, 'base_rev'],
    [{ issue: { state: 'open' } }, 'issue'], [{ comments: [{ id: 1 }] }, 'comments'], [{ extra: 1 }, 'extra']]) {
    const r = await put(o.env, { ...ok, ...over });
    assert.equal(r.status, 400, JSON.stringify(over));
    assert.equal(r.body.field, field);
  }
  assert.equal((await api(o.env, 'GET', `/api/issue-records?repo=${repo}&number=x`)).body.field, 'number');
  assert.equal((await sync(o.env, { repo, started: ago(-60), mark: null, complete: true, items: [] })).body.field, 'started');
  assert.equal((await sync(o.env, { repo, started: ago(5), mark: null, complete: 'yes', items: [] })).body.field, 'complete');
  assert.equal((await api(o.env, 'GET', `/api/issue-records?repo=${repo}&number=1`, undefined, false)).status, 401);
});

// W11 (review of #10343): a later delivery must not hide a lost comment
// webhook. Each issues / issue_comment delivery compares the payload's
// issue.comments with the stored count of comments that are not deleted.
async function readyThread(o, repo, n, comments) {
  const r = await put(o.env, { repo, number: n, base_rev: 0, issue: issue(n, { comments: comments.length }), comments });
  assert.equal(r.body.applied, true);
  o.db.prepare('INSERT OR IGNORE INTO issue_record_syncs (repo, synced_at) VALUES (?, ?)').run(repo, ago(5));
  assert.equal((await get(o.env, repo, n)).body.why, null);
}
test('W11 a lost comment followed by a later comment marks the thread stale', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w11';
  await readyThread(o, repo, 1, [comment(1)]);
  // comment 2 is lost; comment 3 arrives and the issue now has 3 comments
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 1, comment(3, { created_at: ago(100), updated_at: ago(100) }), { comments: 3, updated_at: ago(100) }));
  const g = (await get(o.env, repo, 1)).body;
  assert.equal(g.why, 'stale', 'a count above the stored count must make the thread stale');
  assert.equal(rec(o.db, repo, 1).stale_at, ago(100));
  // a later issues event with the same short count keeps it stale
  await hook(o.env, 'issues', iEvent(repo, 'labeled', 1, { comments: 3, updated_at: ago(50) }));
  assert.equal((await get(o.env, repo, 1)).body.why, 'stale');
  // the full read repairs it
  await put(o.env, { repo, number: 1, base_rev: rec(o.db, repo, 1).rev, issue: issue(1, { comments: 3, updated_at: ago(50) }), comments: [comment(1), comment(2), comment(3)] });
  assert.equal((await get(o.env, repo, 1)).body.why, null);
});
test('W11b equal counts stay ready; a deleted comment is no false stale', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10199-w11b';
  await readyThread(o, repo, 1, [comment(1)]);
  await hook(o.env, 'issue_comment', cEvent(repo, 'created', 1, comment(2, { created_at: ago(100), updated_at: ago(100) }), { comments: 2, updated_at: ago(100) }));
  assert.equal((await get(o.env, repo, 1)).body.why, null, 'equal counts must stay ready');
  await hook(o.env, 'issue_comment', cEvent(repo, 'deleted', 1, comment(1), { comments: 1, updated_at: ago(90) }));
  assert.equal((await get(o.env, repo, 1)).body.why, null, 'a deleted comment must not mark the thread stale');
  await hook(o.env, 'issues', iEvent(repo, 'labeled', 1, { comments: 1, updated_at: ago(80) }));
  assert.equal((await get(o.env, repo, 1)).body.why, null);
  // an older delivery that arrives late carries an old count: no false stale
  await hook(o.env, 'issue_comment', cEvent(repo, 'edited', 1, comment(2, { body: 'v2', updated_at: ago(95) }), { comments: 2, updated_at: ago(95) }));
  assert.equal((await get(o.env, repo, 1)).body.why, null, 'an out-of-order delivery must not mark the thread stale');
  // a payload with no count checks nothing
  await hook(o.env, 'issues', iEvent(repo, 'edited', 1, { updated_at: ago(70) }));
  assert.equal((await get(o.env, repo, 1)).body.why, null);
});
