// BH-8067 (C0): the pr_records table, PUT and GET /api/pr-records, and the two
// retention rules. Driven through the REAL worker.fetch on node:sqlite with the
// composed jobs schema (worker/jobs/schema.d/). Each case opens its own fresh
// DB and uses its own repo/number.
//   P0 the table and its 3 indexes exist
//   P1 PUT a new row -> {row, applied}; GET parses labels and fields_at
//   P2 GET of an absent PR -> 200 {row:null}
//   P3 each bad body -> 400 naming the key, nothing written
//   P4 per-field order: an older head_sha is stale, a newer labels is applied
//   P5 an equal `at` is applied; a replay gives the same row
//   P6 the repo is one row in any case
//   P7 source github sets gh_read_at, fleet does not; refreshed_at only moves forward
//   P8 no bearer -> 401 on both routes; the family is gated
//   X1 the GET statement uses ux_pr_records_repo_number on 5,000 rows
//   X2 both retention id reads use their index on 5,000 rows
//   R1 retention removes the old closed and the old open row, keeps the rest; a dry run removes nothing
import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { GET_SQL } from '../src/routes/pr-records.js';
import { RULES } from '../src/routes/retention.js';

const SECRET = 'tok-fixture-bh8067';
const PATH = '/api/pr-records';
const NOW_MS = Date.parse('2026-10-22T12:00:00Z');
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const SHA_A = 'a'.repeat(40);
const SHA_B = 'b'.repeat(40);

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
async function call(DB, method, path, { body, bearer = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const put = (DB, body, opts = {}) => call(DB, 'PUT', PATH, { body, ...opts });
const get = (DB, repo, n, opts = {}) => call(DB, 'GET', `${PATH}?repo=${encodeURIComponent(repo)}&number=${n}`, opts);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n;

test('P0 the table and its 3 indexes exist after the schema', async (t) => {
  const o = await fresh(t); if (!o) return;
  const idx = o.db.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'pr_records' ORDER BY name").all().map((r) => r.name);
  for (const n of ['ux_pr_records_repo_number', 'idx_pr_records_state_refreshed', 'idx_pr_records_refreshed']) assert.ok(idx.includes(n), `${n} in ${idx}`);
  const s = o.db.prepare("SELECT key, value FROM settings WHERE key LIKE 'retention.pr_records.%' ORDER BY key").all().map((r) => `${r.key}=${r.value}`);
  assert.deepEqual(s, ['retention.pr_records.closed_days=14', 'retention.pr_records.days=90']);
});

test('P1 PUT a new row answers row and applied; GET returns labels as an array and fields_at per field', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await put(o.DB, { repo: 'o/p1', number: 11, source: 'fleet', fields: { state: 'open', head_sha: SHA_A, head_ref: 'ticket/x', labels: ['ai-build', 'tier-1'] } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.applied.sort(), ['head_ref', 'head_sha', 'labels', 'state']);
  assert.deepEqual(r.body.stale, []);
  assert.equal(r.body.row.head_sha, SHA_A);
  const g = await get(o.DB, 'o/p1', 11);
  assert.equal(g.status, 200);
  assert.equal(g.body.row.state, 'open');
  assert.equal(g.body.row.head_sha, SHA_A);
  assert.deepEqual(g.body.row.labels, ['ai-build', 'tier-1']);
  assert.equal(g.body.row.fields_at.head_sha, ago(0));
  assert.equal(g.body.row.fields_at.base_sha, undefined);
  assert.equal(g.body.row.base_sha, null);
  assert.equal(g.body.row.last_source, 'fleet');
  assert.equal(g.body.age_s, 0);
});

test('P2 GET of an absent PR is 200 {row:null}', async (t) => {
  const o = await fresh(t); if (!o) return;
  const g = await get(o.DB, 'o/p2', 12);
  assert.equal(g.status, 200);
  assert.equal(g.body.row, null);
  assert.equal(g.body.age_s, null);
});

test('P3 each bad body is a 400 naming the key, and nothing is written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ok = { repo: 'o/p3', number: 13, source: 'fleet', fields: { state: 'open' } };
  const cases = [
    [{ ...ok, fields: { logs: 'x' } }, 'logs'],
    [{ ...ok, fields: { head_sha: 'abc' } }, 'head_sha'],
    [{ ...ok, fields: { state: 'draft' } }, 'state'],
    [{ ...ok, repo: 'no-slash' }, 'repo'],
    [{ ...ok, fields: 'open' }, 'fields'],
    [{ ...ok, fields: {} }, 'fields'],
    [{ ...ok, number: 0 }, 'number'],
    [{ ...ok, source: 'human' }, 'source'],
    [{ ...ok, at: '2026-10-22 12:00' }, 'at'],
    [{ ...ok, extra: 1 }, 'extra'],
    [{ ...ok, fields: { labels: [1] } }, 'labels'],
    [{ ...ok, fields: { last_comment_id: -1 } }, 'last_comment_id'],
    [{ ...ok, fields: { state: 'open', head_sha: null } }, 'head_sha'],
  ];
  for (const [body, field] of cases) {
    const r = await put(o.DB, body);
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.field, field);
  }
  assert.equal(count(o.db), 0);
  assert.equal((await get(o.DB, 'o/p3', 13)).body.row, null);
});

test('P4 per-field order: an older head_sha is stale and kept, a newer labels in the same request is applied', async (t) => {
  const o = await fresh(t); if (!o) return;
  await put(o.DB, { repo: 'o/p4', number: 14, source: 'webhook', at: ago(10), fields: { head_sha: SHA_A } });
  await put(o.DB, { repo: 'o/p4', number: 14, source: 'fleet', at: ago(100), fields: { labels: ['old'] } });
  const r = await put(o.DB, { repo: 'o/p4', number: 14, source: 'fleet', at: ago(20), fields: { head_sha: SHA_B, labels: ['new'] } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.stale, ['head_sha']);
  assert.deepEqual(r.body.applied, ['labels']);
  assert.equal(r.body.row.head_sha, SHA_A);
  assert.equal(r.body.row.fields_at.head_sha, ago(10));
  assert.deepEqual(r.body.row.labels, ['new']);
  // 1 s newer is applied
  const n = await put(o.DB, { repo: 'o/p4', number: 14, source: 'fleet', at: ago(9), fields: { head_sha: SHA_B } });
  assert.deepEqual(n.body.applied, ['head_sha']);
  assert.equal(n.body.row.head_sha, SHA_B);
  // 1 s older is stale
  const s = await put(o.DB, { repo: 'o/p4', number: 14, source: 'fleet', at: ago(10), fields: { head_sha: SHA_A } });
  assert.deepEqual(s.body.stale, ['head_sha']);
  assert.equal(s.body.row.head_sha, SHA_B);
});

test('P5 an equal `at` is applied, and a replay gives the same row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = { repo: 'o/p5', number: 15, source: 'fleet', at: ago(5), fields: { head_sha: SHA_A, state: 'open' } };
  const a = await put(o.DB, body);
  const b = await put(o.DB, { ...body, fields: { head_sha: SHA_B } });
  assert.deepEqual(b.body.applied, ['head_sha'], 'equal time is applied');
  assert.equal(b.body.row.head_sha, SHA_B);
  const c = await put(o.DB, { ...body, fields: { head_sha: SHA_B } });
  assert.deepEqual(c.body.row, b.body.row, 'a replay changes nothing');
  assert.equal(a.body.row.id, c.body.row.id);
  assert.equal(count(o.db), 1);
});

test('P6 example-org/Cromford and example-org/cromford are one row', async (t) => {
  const o = await fresh(t); if (!o) return;
  await put(o.DB, { repo: 'example-org/Cromford', number: 16, source: 'fleet', fields: { head_sha: SHA_A.toUpperCase() } });
  const g = await get(o.DB, 'example-org/cromford', 16);
  assert.equal(g.body.row.repo, 'example-org/cromford');
  assert.equal(g.body.row.head_sha, SHA_A, 'the sha is lowercased');
  await put(o.DB, { repo: 'example-org/cromford', number: 16, source: 'fleet', fields: { state: 'open' } });
  assert.equal(count(o.db), 1);
  assert.equal((await get(o.DB, 'example-org/cromford', 16)).body.row.state, 'open');
});

test('P7 source github sets gh_read_at, fleet does not; refreshed_at moves forward only', async (t) => {
  const o = await fresh(t); if (!o) return;
  const f = await put(o.DB, { repo: 'o/p7', number: 17, source: 'fleet', at: ago(50), fields: { state: 'open' } });
  assert.equal(f.body.row.gh_read_at, null);
  assert.equal(f.body.row.webhook_at, null);
  const g = await put(o.DB, { repo: 'o/p7', number: 17, source: 'github', at: ago(30), fields: { head_sha: SHA_A } });
  assert.equal(g.body.row.gh_read_at, ago(30));
  assert.equal(g.body.row.last_source, 'github');
  assert.equal(g.body.row.refreshed_at, ago(30));
  const w = await put(o.DB, { repo: 'o/p7', number: 17, source: 'webhook', at: ago(40), fields: { state: 'closed' } });
  assert.equal(w.body.row.webhook_at, ago(40));
  assert.equal(w.body.row.refreshed_at, ago(30), 'an older write does not move refreshed_at back');
  assert.equal(w.body.row.gh_read_at, ago(30));
  assert.equal((await get(o.DB, 'o/p7', 17)).body.age_s, 30);
});

test('P8 no bearer is a 401 on both routes; the family is gated, not open', async (t) => {
  const o = await fresh(t); if (!o) return;
  const p = await put(o.DB, { repo: 'o/p8', number: 18, source: 'fleet', fields: { state: 'open' } }, { bearer: false });
  assert.equal(p.status, 401);
  assert.equal((await get(o.DB, 'o/p8', 18, { bearer: false })).status, 401);
  assert.equal(count(o.db), 0);
  assert.ok(matchRoute(ROUTES, 'PUT', PATH));
  assert.ok(matchRoute(ROUTES, 'GET', PATH));
  assert.equal(matchRoute(OPEN_ROUTES, 'PUT', PATH), null);
});

async function seeded(t) {
  const o = await fresh(t); if (!o) return null;
  const { db } = o;
  const STATES = ['open', 'closed', 'merged', null];
  db.exec('BEGIN');
  for (let b = 0; b < 50; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, ts = ago(i * 3600);
      vals.push('(?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 40}`, i + 1, STATES[i % 4], '{}', ts, ts);
    }
    db.prepare(`INSERT INTO pr_records (repo, number, state, fields_at, created_at, refreshed_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(count(db), 5000);
  return o;
}
function check(db, sql, binds, index) {
  const p = plan(db, sql, ...binds);
  assert.deepEqual(fullScans(p, ['pr_records']), [], p.join(' | '));
  assert.ok(p.some((l) => l.includes(index)), `${index} not in: ${p.join(' | ')}`);
}

test('X1 the GET statement uses ux_pr_records_repo_number on 5,000 rows', async (t) => {
  const o = await seeded(t); if (!o) return;
  check(o.db, GET_SQL, ['o/repo-7', 4008], 'ux_pr_records_repo_number');
});

test('X2 both retention id reads use their index on 5,000 rows', async (t) => {
  const o = await seeded(t); if (!o) return;
  const rule = (n) => RULES.find((r) => r.rule === n);
  assert.ok(rule('pr_records.closed') && rule('pr_records.age'), 'both rules are in RULES');
  check(o.db, rule('pr_records.closed').ids, [ago(14 * 86400), 500], 'idx_pr_records_state_refreshed');
  check(o.db, rule('pr_records.age').ids, [ago(90 * 86400), 500], 'idx_pr_records_refreshed');
});

async function retention(env) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
  }), { ...env, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}

test('R1 retention removes a 15-day closed and a 91-day open row, keeps a 13-day closed and an 89-day open row; a dry run removes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const row = (n, state, days) => o.db.prepare(`INSERT INTO pr_records (repo, number, state, fields_at, created_at, refreshed_at) VALUES ('o/r1', ?, ?, '{}', ?, ?)`)
    .run(n, state, ago(days * 86400), ago(days * 86400));
  row(1, 'closed', 15); row(2, 'open', 91); row(3, 'closed', 13); row(4, 'open', 89); row(5, 'merged', 15);
  const left = () => o.db.prepare("SELECT number FROM pr_records WHERE repo = 'o/r1' ORDER BY number").all().map((r) => r.number);
  setting(o.db, 'retention.dry_run', '1');
  const d = await retention({ DB: o.DB });
  assert.equal(d.status, 200, JSON.stringify(d.body));
  assert.equal(d.body.rules.find((r) => r.rule === 'pr_records.closed').counted, 2);
  assert.deepEqual(left(), [1, 2, 3, 4, 5], 'a dry run removes nothing');
  setting(o.db, 'retention.dry_run', '0');
  const r = await retention({ DB: o.DB });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const closed = r.body.rules.find((x) => x.rule === 'pr_records.closed');
  const age = r.body.rules.find((x) => x.rule === 'pr_records.age');
  assert.equal(closed.error, null);
  assert.equal(closed.removed, 2);
  assert.equal(age.removed, 1);
  assert.deepEqual(left(), [3, 4]);
});
