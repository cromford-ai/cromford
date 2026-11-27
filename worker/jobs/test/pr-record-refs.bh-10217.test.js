// BH-10217: GET /api/pr-record-refs — the closed and merged PR record rows
// for a list of head refs of one repo. Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema (worker/jobs/schema.d/). Each case
// opens its own fresh DB.
//   W1 closed and merged rows of the asked refs come back; open rows, other
//      refs (a shared prefix too) and other repos do not
//   W2 a wrong-repo read returns 0 rows (the tenant check of this data layer)
//   W3 more refs than pr_records.ref_read_max = 400 too_many; the seed row is
//      50, and with no row the fallback is 50
//   W4 bad repo, bad JSON, an empty array, a non-string ref = 400 invalid_field
//   W5 more rows than pr_records.list_limit = truncated:true
//   W6 EXPLAIN QUERY PLAN of the SQL at 20,000 seeded rows uses
//      idx_pr_records_repo_head and no line is a full SCAN of pr_records
//   W7 no bearer = 401; the route is gated, not open
import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { REFS_SQL } from '../src/routes/pr-record-refs.js';

const SECRET = 'tok-fixture-bh10217';
const PATH = '/api/pr-record-refs';
const NOW_MS = Date.parse('2026-11-26T12:00:00Z');
const NOW = new Date(NOW_MS).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  // One read first: guarded runs ensureColumns, which adds merged_at
  // (core.d/bh-8481) and idx_pr_records_repo_head (core.d/bh-8973).
  assert.equal((await get(o.DB, 'o/warm', ['ticket/warm'])).status, 200);
  return o;
}
async function get(DB, repo, refs, { bearer = true, raw } = {}) {
  const headers = {};
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  const q = `repo=${encodeURIComponent(repo)}&refs=${encodeURIComponent(raw !== undefined ? raw : JSON.stringify(refs))}`;
  const res = await worker.fetch(new Request(`https://jobs.test${PATH}?${q}`, { method: 'GET', headers }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
function row(db, repo, number, state, headRef, mergedAt = null) {
  db.prepare(`INSERT INTO pr_records (repo, number, state, head_ref, fields_at, created_at, refreshed_at) VALUES (?,?,?,?,'{}',?,?)`)
    .run(repo, number, state, headRef, NOW, NOW);
  if (mergedAt) db.prepare('UPDATE pr_records SET merged_at = ? WHERE repo = ? AND number = ?').run(mergedAt, repo, number);
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
const brief = (rows) => rows.map((r) => `${r.head_ref}#${r.number}:${r.state}`);

test('W1 closed and merged rows of the asked refs come back; open rows, other refs and other repos do not', async (t) => {
  const o = await fresh(t); if (!o) return;
  row(o.db, 'o/w1', 1, 'closed', 'ticket/bh-1');
  row(o.db, 'o/w1', 2, 'merged', 'ticket/bh-1', '2026-11-25T10:00:00Z');
  row(o.db, 'o/w1', 3, 'open', 'ticket/bh-1');
  row(o.db, 'o/w1', 4, 'merged', 'ticket/bh-10', '2026-11-25T11:00:00Z');
  row(o.db, 'o/w1', 5, 'closed', 'agent/TK-249');
  row(o.db, 'o/other', 6, 'merged', 'ticket/bh-1', '2026-11-25T12:00:00Z');
  const r = await get(o.DB, 'O/W1', ['ticket/bh-1', 'agent/TK-249', 'ticket/none']);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(brief(r.body.rows), ['agent/TK-249#5:closed', 'ticket/bh-1#1:closed', 'ticket/bh-1#2:merged']);
  assert.equal(r.body.rows.find((x) => x.number === 2).merged_at, '2026-11-25T10:00:00Z');
  assert.equal(r.body.rows.find((x) => x.number === 1).merged_at, null);
  assert.equal(r.body.truncated, false);
});

test('W2 a wrong-repo read returns 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  row(o.db, 'o/tenant-a', 1, 'merged', 'ticket/bh-1', '2026-11-25T10:00:00Z');
  const r = await get(o.DB, 'o/tenant-b', ['ticket/bh-1']);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows, []);
  assert.equal(r.body.truncated, false);
});

test('W3 more refs than pr_records.ref_read_max is 400 too_many; the seed and the fallback are both 50', async (t) => {
  const o = await fresh(t); if (!o) return;
  const seed = o.db.prepare("SELECT value FROM settings WHERE key = 'pr_records.ref_read_max'").get();
  assert.equal(seed && seed.value, '50', 'the schema seed row');
  const refs = (n) => Array.from({ length: n }, (_, i) => `ticket/w3-${i}`);
  assert.equal((await get(o.DB, 'o/w3', refs(50))).status, 200);
  const over = await get(o.DB, 'o/w3', refs(51));
  assert.equal(over.status, 400);
  assert.equal(over.body.error, 'too_many');

  const o2 = await openDb();
  o2.db.prepare("DELETE FROM settings WHERE key = 'pr_records.ref_read_max'").run();
  assert.equal((await get(o2.DB, 'o/w3', refs(50))).status, 200, 'no row: fallback 50 takes 50');
  assert.equal((await get(o2.DB, 'o/w3', refs(51))).body.error, 'too_many', 'no row: fallback 50 refuses 51');

  const o3 = await openDb();
  setting(o3.db, 'pr_records.ref_read_max', 3);
  assert.equal((await get(o3.DB, 'o/w3', refs(3))).status, 200);
  assert.equal((await get(o3.DB, 'o/w3', refs(4))).body.error, 'too_many', 'the row value is the cap');
});

test('W4 bad input is 400 invalid_field', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [
    ['bad repo', 'not a repo', ['ticket/x'], undefined, 'repo'],
    ['bad JSON', 'o/w4', null, '[ticket/x', 'refs'],
    ['not an array', 'o/w4', null, '{"a":1}', 'refs'],
    ['empty array', 'o/w4', [], undefined, 'refs'],
    ['a non-string ref', 'o/w4', ['ticket/x', 7], undefined, 'refs'],
    ['an empty ref', 'o/w4', [''], undefined, 'refs'],
    ['a ref over 255 chars', 'o/w4', ['x'.repeat(256)], undefined, 'refs'],
    ['no refs', 'o/w4', null, '', 'refs'],
  ];
  for (const [name, repo, refs, raw, field] of cases) {
    const r = await get(o.DB, repo, refs, { raw });
    assert.equal(r.status, 400, name);
    assert.deepEqual(r.body, { error: 'invalid_field', field }, name);
  }
});

test('W5 more rows than pr_records.list_limit sets truncated:true', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'pr_records.list_limit', 2);
  for (let n = 1; n <= 3; n++) row(o.db, 'o/w5', n, 'closed', 'ticket/w5');
  const r = await get(o.DB, 'o/w5', ['ticket/w5']);
  assert.equal(r.status, 200);
  assert.equal(r.body.rows.length, 2);
  assert.equal(r.body.truncated, true);
  setting(o.db, 'pr_records.list_limit', 3);
  const o2 = await openDb();
  setting(o2.db, 'pr_records.list_limit', 3);
  for (let n = 1; n <= 3; n++) row(o2.db, 'o/w5', n, 'closed', 'ticket/w5');
  const r2 = await get(o2.DB, 'o/w5', ['ticket/w5']);
  assert.equal(r2.body.rows.length, 3);
  assert.equal(r2.body.truncated, false, 'exactly the limit is not truncated');
});

test('W6 the SQL uses idx_pr_records_repo_head and no full scan of pr_records on 20,000 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const STATES = ['open', 'closed', 'merged', 'open'];
  db.exec('BEGIN');
  for (let b = 0; b < 200; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j;
      vals.push("(?,?,?,?,'{}',?,?)");
      binds.push(`o/repo-${i % 40}`, i + 1, STATES[Math.floor(i / 40) % 4], `ticket/bh-${i}`, NOW, NOW);
    }
    db.prepare(`INSERT INTO pr_records (repo, number, state, head_ref, fields_at, created_at, refreshed_at) VALUES ${vals.join(',')}`).run(...binds);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n, 20000);
  const refs = JSON.stringify(Array.from({ length: 20 }, (_, i) => `ticket/bh-${i * 40 + 7}`));
  const p = plan(db, REFS_SQL, 'o/repo-7', refs, 501);
  assert.deepEqual(fullScans(p, ['pr_records']), [], p.join(' | '));
  assert.ok(p.some((l) => l.includes('idx_pr_records_repo_head')), `idx_pr_records_repo_head not in: ${p.join(' | ')}`);
  const r = await get(o.DB, 'o/repo-7', JSON.parse(refs));
  assert.equal(r.status, 200);
  assert.ok(r.body.rows.every((x) => x.state === 'closed' || x.state === 'merged'));
  assert.equal(r.body.rows.length, 10, 'half of the 20 refs are closed or merged');
});

test('W7 no bearer is 401; the route is in the gated table, not the open one', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await get(o.DB, 'o/w7', ['ticket/x'], { bearer: false });
  assert.equal(r.status, 401);
  assert.ok(matchRoute(ROUTES, 'GET', PATH));
  assert.equal(matchRoute(OPEN_ROUTES, 'GET', PATH), null);
});
