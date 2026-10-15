import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { parseFragments } from '../src/lib/route-families.js';

// BH-4156 — GET /api/conductor-state: the attempt rows of up to 200 PRs of one
// repo in ONE request, so a merge-conductor tick reads its attempts once per
// repo instead of once per PR per line.
//
// Every case drives `worker.fetch` (D2): the real bearer check and the real
// route table over the real schema in node:sqlite. `t.skip` when node:sqlite is
// absent, the same rule as pr-state.bh-1386.test.js.

const SECRET = 'secret-fixture-4156';
const REPO = 'example-org/x';

async function call(DB, path, { method = 'GET', body } = {}) {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}

// Rows go in through the real PUT, so the batch reads what the writer wrote.
async function put(DB, number, kind, sha, repo = REPO) {
  const r = await call(DB, '/api/pr-attempts', { method: 'PUT', body: { repo, number, kind, sha } });
  assert.ok(r.status === 201 || r.status === 200, `PUT ${number} ${kind} ${sha}: ${r.status}`);
}

const batch = (DB, q) => call(DB, `/api/conductor-state?${q}`);

test('R1: three PRs with 2/0/1 rows answer in one 200, number ASC then newest first', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;
  await put(DB, 7, 'rebase', 'aaa');
  await put(DB, 7, 'rereview', 'bbb');
  await put(DB, 9, 'headlag', 'ccc 1');
  // Same `at` second for both rows of #7: rowid DESC breaks the tie, the
  // same order GET /api/pr-attempts uses.
  db.prepare("UPDATE pr_attempts SET at='2026-10-14T00:00:00Z' WHERE number=7").run();
  const r = await batch(DB, `repo=${encodeURIComponent(REPO)}&numbers=9,8,7`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.numbers, [7, 8, 9]);
  assert.equal(r.body.truncated, false);
  assert.deepEqual(r.body.attempts.map((a) => [a.number, a.kind, a.sha]),
    [[7, 'rereview', 'bbb'], [7, 'rebase', 'aaa'], [9, 'headlag', 'ccc 1']]);
});

test('R1b: zero rows is a 200 with an empty list, not a 404', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const r = await batch(open.DB, `repo=${encodeURIComponent(REPO)}&numbers=4`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.numbers, [4]);
  assert.deepEqual(r.body.attempts, []);
  assert.equal(r.body.truncated, false);
});

test('R2: a bad request is a 400, never a clamp', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const repo = `repo=${encodeURIComponent(REPO)}`;
  const many = Array.from({ length: 201 }, (_, i) => i + 1).join(',');
  for (const q of [repo, `${repo}&numbers=`, `${repo}&numbers=1,x`, `${repo}&numbers=0`,
    `${repo}&numbers=-3`, `${repo}&numbers=1.5`, `${repo}&numbers=1,,2`, `${repo}&numbers=${many}`, 'numbers=1']) {
    const r = await batch(open.DB, q);
    assert.equal(r.status, 400, `expected 400 for ?${q.slice(0, 60)}`);
  }
  // 200 values is the ceiling, and a repeat counts once.
  const ok = await batch(open.DB, `${repo}&numbers=${Array.from({ length: 200 }, (_, i) => i + 1).join(',')},5`);
  assert.equal(ok.status, 200);
  assert.equal(ok.body.numbers.length, 200);
});

test('R3: rows over ROW_CAP leave that PR out and say truncated', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;
  const ins = db.prepare("INSERT INTO pr_attempts (repo, number, kind, sha, at) VALUES (?, 3, 'rebase', ?, '2026-10-14T00:00:00Z')");
  for (let i = 0; i < 5001; i++) ins.run(REPO, `s${i}`);
  await put(DB, 5, 'rebase', 'five');
  const r = await batch(DB, `repo=${encodeURIComponent(REPO)}&numbers=3,4,5`);
  assert.equal(r.status, 200);
  assert.equal(r.body.truncated, true);
  assert.deepEqual(r.body.numbers, [4, 5]);
  assert.deepEqual(r.body.attempts.map((a) => [a.number, a.sha]), [[5, 'five']]);
});

test('R4: a duplicate PUT reads back as one row through the batch', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  await put(open.DB, 11, 'rebase', 'dup');
  await put(open.DB, 11, 'rebase', 'dup');
  const r = await batch(open.DB, `repo=${encodeURIComponent(REPO)}&numbers=11`);
  assert.equal(r.status, 200);
  assert.equal(r.body.attempts.length, 1);
});

test('R5: another repo\'s rows never appear, and the repo match is exact', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  await put(open.DB, 2, 'rebase', 'mine');
  await put(open.DB, 2, 'rebase', 'theirs', 'example-org/y');
  await put(open.DB, 2, 'rebase', 'case', 'example-org/x');
  const r = await batch(open.DB, `repo=${encodeURIComponent(REPO)}&numbers=2`);
  assert.deepEqual(r.body.attempts.map((a) => a.sha), ['mine']);
});

test('R6: the fragment registers GET /api/conductor-state to the conductor-state module', async () => {
  const dir = new URL('./route-table.d/', import.meta.url);
  const frag = parseFragments(['773-conductor-state.txt'])[0];
  assert.equal(frag.family, 'conductor-state');
  const lines = readFileSync(new URL('773-conductor-state.txt', dir), 'utf8')
    .split('\n').filter((l) => l.trim() && !l.startsWith('#'));
  assert.deepEqual(lines, ['GET /api/conductor-state']);
  const { routes } = await import('../src/routes/conductor-state.js');
  assert.deepEqual(routes.map((r) => `${r[0]} ${r[1]}`), ['GET /api/conductor-state']);
});

test('R7: no bearer is a 401 (the route is gated, not open)', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const res = await worker.fetch(new Request(`https://jobs.test/api/conductor-state?repo=a&numbers=1`),
    { DB: open.DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 401);
});
