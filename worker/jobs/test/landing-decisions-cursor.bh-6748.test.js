// BH-6748 (wave 5 of #6541): the `before_id` cursor on GET
// /api/landing-decisions. bin/landing-replay.sh and the digest's landing block
// (bin/lib/landing-sources.sh ls_fetch) page a repo's decisions newest first,
// 200 a page, with before_id = the smallest id of the last page.
// Driven through the REAL worker.fetch on node:sqlite (the BH-6744 idiom).
//   C1 before_id returns only ids below it, newest first, with an honest truncated
//   C2 before_id=0, -1, abc, 1.5 -> 400
//   C3 no before_id -> the same rows and truncated as before (BH-6744 W3)
//   C4 EXPLAIN QUERY PLAN on 20,000 rows with before_id uses
//      idx_landing_decisions_repo_id, no SCAN, no sort step
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh6748';
const A = 'example-org/cursor-a';
const B = 'example-org/cursor-b';
const sha = (i) => i.toString(16).padStart(40, '0');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function get(DB, q) {
  return worker.fetch(new Request(`https://jobs.test/api/landing-decisions?${q}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
// seed <db> <repo> <n> — n rows for one repo, numbers 1..n, ids ascending.
function seed(db, repo, n, from = 1) {
  const ins = db.prepare('INSERT INTO landing_decisions (repo, number, head, mode, would, reason, at) VALUES (?,?,?,?,?,?,?)');
  for (let i = from; i < from + n; i++) ins.run(repo, i, sha(i), 'shadow', 'direct', 'ok', '2026-10-20T00:00:00Z');
}
const ids = (db, repo) => db.prepare('SELECT id FROM landing_decisions WHERE repo = ? ORDER BY id DESC').all(repo).map((r) => r.id);

test('C1 before_id returns only ids below it, newest first; truncated is measured past the limit', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  await get(DB, `repo=${encodeURIComponent(A)}`);   // ensureTable
  seed(db, A, 6); seed(db, B, 3, 100); seed(db, A, 2, 200);
  const all = ids(db, A);                           // 8 ids of A, newest first
  assert.equal(all.length, 8);
  const p1 = await get(DB, `repo=${encodeURIComponent(A)}&limit=3`);
  assert.equal(p1.status, 200, JSON.stringify(p1.body));
  assert.deepEqual(p1.body.rows.map((r) => r.id), all.slice(0, 3));
  assert.equal(p1.body.truncated, true);
  const cur = Math.min(...p1.body.rows.map((r) => r.id));
  const p2 = await get(DB, `repo=${encodeURIComponent(A)}&limit=3&before_id=${cur}`);
  assert.equal(p2.status, 200, JSON.stringify(p2.body));
  assert.deepEqual(p2.body.rows.map((r) => r.id), all.slice(3, 6));
  assert.ok(p2.body.rows.every((r) => r.repo === A && r.id < cur));
  assert.equal(p2.body.truncated, true);
  const p3 = await get(DB, `repo=${encodeURIComponent(A)}&limit=3&before_id=${Math.min(...p2.body.rows.map((r) => r.id))}`);
  assert.deepEqual(p3.body.rows.map((r) => r.id), all.slice(6));
  assert.equal(p3.body.truncated, false);
  const none = await get(DB, `repo=${encodeURIComponent(A)}&before_id=1`);
  assert.deepEqual(none.body.rows, []);
  assert.equal(none.body.truncated, false);
  const num = await get(DB, `repo=${encodeURIComponent(A)}&number=2&before_id=${all[0]}`);
  assert.deepEqual(num.body.rows.map((r) => r.number), [2]);
});

test('C2 before_id that is not a positive integer is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { DB } = o;
  for (const v of ['0', '-1', 'abc', '1.5', '']) {
    const res = await get(DB, `repo=${encodeURIComponent(A)}&before_id=${v}`);
    if (v === '') { assert.equal(res.status, 200, 'an empty before_id is no cursor'); continue; }
    assert.equal(res.status, 400, `${v}: ${JSON.stringify(res.body)}`);
    assert.match(res.body.error, /before_id/);
  }
});

test('C3 no before_id answers the rows and truncated it answered before BH-6748', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  await get(DB, `repo=${encodeURIComponent(A)}`);
  seed(db, A, 4); seed(db, B, 2, 50);
  const all = await get(DB, `repo=${encodeURIComponent(A)}`);
  assert.deepEqual(all.body.rows.map((r) => r.id), ids(db, A));
  assert.equal(all.body.truncated, false);
  const lim = await get(DB, `repo=${encodeURIComponent(A)}&limit=2`);
  assert.deepEqual(lim.body.rows.map((r) => r.id), ids(db, A).slice(0, 2));
  assert.equal(lim.body.truncated, true);
});

test('C4 on 20,000 rows the before_id read uses idx_landing_decisions_repo_id, no scan, no sort', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  await get(DB, `repo=${encodeURIComponent(A)}`);
  const REPOS = Array.from({ length: 20 }, (_, i) => `o/r${i}`);
  db.exec('BEGIN');
  const ins = db.prepare('INSERT INTO landing_decisions (repo, number, head, mode, would, reason, at) VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < 20000; i++) ins.run(REPOS[i % 20], 1 + (i % 400), sha(i), 'shadow', i % 3 ? 'queue' : 'direct', 'ok', '2026-10-20T00:00:00Z');
  db.exec('COMMIT');
  const log = [];
  const D = capturingD1(db, log);
  const res = await get(D, 'repo=o%2Fr3&limit=200&before_id=15000');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.rows.length, 200);
  assert.ok(res.body.rows.every((r) => r.id < 15000));
  const reads = log.filter((r) => /FROM landing_decisions/.test(r.sql));
  assert.equal(reads.length, 1, log.map((r) => r.sql).join(' | '));
  const p = plan(db, reads[0].sql, ...reads[0].binds);
  assert.deepEqual(fullScans(p, ['landing_decisions']), [], p.join(' | '));
  assert.ok(p.some((l) => /landing_decisions USING (COVERING )?INDEX idx_landing_decisions_repo_id \(repo=\? AND id<\?\)/.test(l)), p.join(' | '));
  assert.ok(!p.some((l) => /TEMP B-TREE/.test(l)), `no sort step: ${p.join(' | ')}`);
});
