// BH-10213: POST /api/pr-record-notes — a lane's GitHub read after a PR-record
// miss, written back into pr_records through the webhook SQL (newer only), and
// the "checked, empty" marker pr_records.gh_empty. Driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema. Each case opens
// its own fresh DB and uses its own repo.
//   W1  non-empty statuses -> merged per context for the head (STATUS_MERGE_SQL)
//   W2  a status older than the stored entry is not replaced; a replay changes 0 rows
//   W3  a Mergify comment on a pre-#10195 row (same at and id, no updated_at)
//       -> the row gets updated_at and run_id; a replay changes 0 rows
//   W3b a comment that does not parse (or not mergify[bot]): 200 parsed:false, 0 rows
//   W4  a Mergify comment older than the stored payload is not replaced
//   W5  statuses: [] -> gh_empty.statuses = {sha: head, at}; another head -> 0
//       rows; an older at -> not replaced; a replay -> 0 rows; a future at is
//       clamped to the worker clock; comment null -> gh_empty.mergify_queue =
//       {sha: row head, at}, next to the statuses marker
//   W6  round trip: POST empty, then GET returns gh_empty with the marker
//   W7  a `status` webhook after the marker: the entry exists next to the marker
//   W8  EXPLAIN QUERY PLAN of both marker statements on 5,000 rows: the unique
//       index, no SCAN pr_records
//   W9  bad bodies -> 400 that names the field; no bearer -> 401
//   W10 no write moves refreshed_at
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { ensureColumns, ensureTable } from '../src/lib/core.js';
import { recordPrRecord } from '../src/lib/pr-record-intake.js';
import { CHECKS_MAX } from '../src/routes/pr-records.js';
import { EMPTY_STATUSES_SQL, EMPTY_MERGIFY_SQL } from '../src/routes/pr-record-notes.js';

const SECRET = 'tok-fixture-bh10213';
const NOW_MS = Date.parse('2026-11-26T12:00:00Z');
const T = '2026-11-26T12:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40);

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET } };
}
async function api(env, method, path, body, auth = true) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { 'content-type': 'application/json', ...(auth ? { authorization: `Bearer ${SECRET}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const note = (env, body, auth) => api(env, 'POST', '/api/pr-record-notes', body, auth);
const rowOf = (db, repo, n) => db.prepare('SELECT * FROM pr_records WHERE repo = ? AND number = ?').get(repo, n) || null;
const jsonOf = (db, repo, n, col) => { const r = rowOf(db, repo, n); return r && r[col] !== null ? JSON.parse(r[col]) : null; };
const openRecord = (env, repo, number, head = A, extra = {}) =>
  api(env, 'PUT', '/api/pr-records', { repo, number, source: 'fleet', at: ago(3600),
    fields: { state: 'open', head_sha: head, head_ref: `ticket/x-${number}`, base_ref: 'main', ...extra } });
const st = (context, state, updatedAt, description = `${context} ${state}`) => ({ context, state, description, updated_at: updatedAt });
const QUEUED = '-*- Mergify Payload -*-\n{"state":"queued"}\n-*- Mergify Payload End -*-\nQueued';
const DEQ = '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": "dequeued", "dequeue_reason": {"code": "CHECKS_FAILED"}}\n-*- Mergify Payload End -*-\n-->\n'
  + '- ❌ **Checks failed** — on draft #8165\nSee https://github.com/o/r/actions/runs/777\n\nFailing checks:\n- ❌ [`lint`](https://x)\n';
const cmt = (id, createdAt, updatedAt, body, login = 'mergify[bot]') => ({ id, created_at: createdAt, updated_at: updatedAt, body, login });

test('W1 non-empty statuses are merged per context for the head', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w1';
  assert.equal((await openRecord(o.env, repo, 1)).status, 200);
  const r = await note(o.env, { repo, number: 1, kind: 'statuses', head: A.toUpperCase(), at: ago(10),
    statuses: [st('lead-verdict', 'success', ago(300), 'MERGE'), st('ci/x', 'failure', ago(200), null)] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { written: 2, parsed: true });
  assert.deepEqual(jsonOf(o.db, repo, 1, 'statuses'), {
    'lead-verdict': { state: 'success', description: 'MERGE', sha: A, at: ago(300) },
    'ci/x': { state: 'failure', description: null, sha: A, at: ago(200) },
  });
  assert.equal(rowOf(o.db, repo, 1).gh_empty, null, 'a non-empty answer writes no marker');
});

test('W2 an older status does not replace a newer one; a replay changes 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w2';
  await openRecord(o.env, repo, 1);
  await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(10), statuses: [st('lead-verdict', 'success', ago(100), 'MERGE')] });
  const old = await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(5), statuses: [st('lead-verdict', 'failure', ago(500), 'BLOCK')] });
  assert.equal(old.body.written, 0);
  assert.equal(jsonOf(o.db, repo, 1, 'statuses')['lead-verdict'].state, 'success');
  const again = await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(5), statuses: [st('lead-verdict', 'success', ago(100), 'MERGE')] });
  assert.equal(again.body.written, 0, 'a replay changes 0 rows');
});

test('W3 a Mergify comment on a pre-#10195 row adds updated_at and run_id; a replay changes 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w3';
  // The row as the pre-#10195 webhook wrote it: same at and comment id, no updated_at, no run_id.
  await openRecord(o.env, repo, 5, A, { mergify_queue: { state: 'dequeued', code: 'CHECKS_FAILED', draft_pr: 8165,
    failing_checks: ['lint'], left_sha: null, comment_id: 6366196632, at: ago(600) } });
  const r = await note(o.env, { repo, number: 5, kind: 'mergify', at: ago(5), comment: cmt(6366196632, ago(600), ago(400), DEQ) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { written: 1, parsed: true });
  const mq = jsonOf(o.db, repo, 5, 'mergify_queue');
  assert.equal(mq.updated_at, ago(400));
  assert.equal(mq.run_id, 777);
  assert.equal(mq.comment_id, 6366196632);
  assert.equal(mq.at, ago(600));
  const again = await note(o.env, { repo, number: 5, kind: 'mergify', at: ago(4), comment: cmt(6366196632, ago(600), ago(400), DEQ) });
  assert.equal(again.body.written, 0, 'a replay changes 0 rows');
});

test('W3b a comment that does not parse writes nothing: 200 parsed false', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w3b';
  await openRecord(o.env, repo, 5);
  for (const c of [cmt(11, ago(600), ago(600), 'no markers here'), cmt(12, ago(600), ago(600), QUEUED, 'mergify')]) {
    const r = await note(o.env, { repo, number: 5, kind: 'mergify', at: ago(5), comment: c });
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, { written: 0, parsed: false });
  }
  assert.equal(rowOf(o.db, repo, 5).mergify_queue, null);
});

test('W4 a Mergify comment older than the stored payload is not replaced', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w4';
  await openRecord(o.env, repo, 5);
  await note(o.env, { repo, number: 5, kind: 'mergify', at: ago(5), comment: cmt(900, ago(100), ago(100), DEQ) });
  const r = await note(o.env, { repo, number: 5, kind: 'mergify', at: ago(4), comment: cmt(800, ago(700), ago(50), QUEUED) });
  assert.equal(r.body.written, 0);
  assert.equal(jsonOf(o.db, repo, 5, 'mergify_queue').comment_id, 900);
});

test('W5 the empty marker: head-bound, newer only, replay 0 rows, future at clamped; comment null marks the row head', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w5';
  await openRecord(o.env, repo, 1);
  let r = await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(60), statuses: [] });
  assert.deepEqual(r.body, { written: 1, parsed: true });
  assert.deepEqual(jsonOf(o.db, repo, 1, 'gh_empty'), { statuses: { sha: A, at: ago(60) } });
  r = await note(o.env, { repo, number: 1, kind: 'statuses', head: B, at: ago(30), statuses: [] });
  assert.equal(r.body.written, 0, 'another head: 0 rows');
  r = await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(120), statuses: [] });
  assert.equal(r.body.written, 0, 'an older at: not replaced');
  r = await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(60), statuses: [] });
  assert.equal(r.body.written, 0, 'a replay: 0 rows');
  r = await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: '2026-11-26T13:00:00Z', statuses: [] });
  assert.equal(r.body.written, 1);
  assert.deepEqual(jsonOf(o.db, repo, 1, 'gh_empty').statuses, { sha: A, at: T }, 'a future at is the worker clock');
  r = await note(o.env, { repo, number: 1, kind: 'mergify', at: ago(10), comment: null });
  assert.deepEqual(r.body, { written: 1, parsed: true });
  assert.deepEqual(jsonOf(o.db, repo, 1, 'gh_empty'), { statuses: { sha: A, at: T }, mergify_queue: { sha: A, at: ago(10) } });
  r = await note(o.env, { repo, number: 1, kind: 'mergify', at: ago(20), comment: null });
  assert.equal(r.body.written, 0, 'an older Mergify marker: not replaced');
  r = await note(o.env, { repo, number: 99, kind: 'mergify', at: ago(10), comment: null });
  assert.equal(r.body.written, 0, 'no record: 0 rows, no insert');
  assert.equal(rowOf(o.db, repo, 99), null);
});

test('W6 round trip: POST the marker, GET returns gh_empty with it', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w6';
  await openRecord(o.env, repo, 3);
  await note(o.env, { repo, number: 3, kind: 'statuses', head: A, at: ago(30), statuses: [] });
  const g = await api(o.env, 'GET', `/api/pr-records?repo=${repo}&number=3`);
  assert.equal(g.status, 200);
  const ge = typeof g.body.row.gh_empty === 'string' ? JSON.parse(g.body.row.gh_empty) : g.body.row.gh_empty;
  assert.deepEqual(ge, { statuses: { sha: A, at: ago(30) } });
});

test('W7 a status webhook after the marker: the entry exists next to the marker', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w7';
  await openRecord(o.env, repo, 1);
  await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(60), statuses: [] });
  const w = await recordPrRecord(o.env, T, 'status', { sha: A, context: 'lead-verdict', state: 'success', description: 'MERGE',
    updated_at: ago(30), repository: { full_name: repo } });
  assert.equal(w.written, 1);
  assert.equal(jsonOf(o.db, repo, 1, 'statuses')['lead-verdict'].state, 'success');
  assert.deepEqual(jsonOf(o.db, repo, 1, 'gh_empty'), { statuses: { sha: A, at: ago(60) } });
});

test('W8 both marker statements use ux_pr_records_repo_number and no SCAN on 5,000 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ensureTable(o.env, 'pr_records');
  await ensureColumns(o.env, 'pr_records');
  o.db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, ts = ago(i * 600);
      vals.push('(?,?,?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 40}`, i + 1, 'open', i.toString(16).padStart(40, '0'), `ticket/x-${i}`, '{}', ts, ts);
    }
    o.db.prepare(`INSERT INTO pr_records (repo, number, state, head_sha, head_ref, fields_at, created_at, refreshed_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  for (const [sql, binds] of [[EMPTY_STATUSES_SQL, ['o/repo-7', 8, (7).toString(16).padStart(40, '0'), T]],
    [EMPTY_MERGIFY_SQL, ['o/repo-7', 8, T]]]) {
    const p = plan(o.db, sql, ...binds);
    assert.deepEqual(fullScans(p, ['pr_records']), [], p.join(' | '));
    assert.ok(p.some((l) => l.includes('ux_pr_records_repo_number')), p.join(' | '));
  }
});

test('W9 bad bodies are a 400 that names the field; no bearer is a 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w9';
  const good = { repo, number: 1, kind: 'statuses', head: A, at: ago(5), statuses: [] };
  const cases = [
    [{ ...good, repo: 'nope' }, 'repo'],
    [{ ...good, number: 0 }, 'number'],
    [{ ...good, kind: 'checks' }, 'kind'],
    [{ ...good, head: 'abc' }, 'head'],
    [{ ...good, at: 'yesterday' }, 'at'],
    [{ ...good, statuses: 'x' }, 'statuses'],
    [{ ...good, statuses: [st('lead-verdict', 'green', ago(5))] }, 'statuses'],
    [{ ...good, statuses: [{ context: 'x', state: 'success', description: null }] }, 'statuses'],
    [{ ...good, statuses: Array.from({ length: CHECKS_MAX + 1 }, (_, i) => st(`c${i}`, 'success', ago(5))) }, 'statuses'],
    [{ ...good, extra: 1 }, 'extra'],
    [{ repo, number: 1, kind: 'mergify', at: ago(5) }, 'comment'],
    [{ repo, number: 1, kind: 'mergify', at: ago(5), comment: { ...cmt(1, ago(5), ago(5), QUEUED), body: 7 } }, 'comment'],
    [{ repo, number: 1, kind: 'mergify', at: ago(5), comment: { ...cmt(1, ago(5), ago(5), QUEUED), id: -1 } }, 'comment'],
  ];
  for (const [body, field] of cases) {
    const r = await note(o.env, body);
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.field, field, JSON.stringify(r.body));
  }
  const nb = await note(o.env, good, false);
  assert.equal(nb.status, 401);
});

test('W10 no write moves refreshed_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const repo = 'o/bh10213-w10';
  await openRecord(o.env, repo, 1);
  const before = rowOf(o.db, repo, 1).refreshed_at;
  await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(5), statuses: [] });
  await note(o.env, { repo, number: 1, kind: 'statuses', head: A, at: ago(4), statuses: [st('lead-verdict', 'success', ago(4))] });
  await note(o.env, { repo, number: 1, kind: 'mergify', at: ago(3), comment: null });
  await note(o.env, { repo, number: 1, kind: 'mergify', at: ago(2), comment: cmt(5, ago(3), ago(3), QUEUED) });
  assert.equal(rowOf(o.db, repo, 1).refreshed_at, before);
});
