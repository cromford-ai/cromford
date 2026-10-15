// BH-4156: the three main-red tables (schema.d/0026) are read through an index
// (iron law, BH-6730). Each read case runs the REAL route against the composed
// schema, seeded at more than a fleet's volume, records the statement the route
// read with (capturingD1), and runs EXPLAIN QUERY PLAN on it with the route's
// binds. The prune DELETE and the resolve UPDATE are writes the shim does not
// record, so their SQL is EXPLAINed as the route ships it. A plan line
// `SCAN <table>` with no index is a full read and fails the case.
//   main_red_verdicts   one row per repo (-- no-index:), read by its PRIMARY KEY
//   main_red_pr_errors  read by (repo, head) = PRIMARY KEY; pruned by (repo, at)
//   main_red_pairs      open rows read and resolved through main_red_pairs_open
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh4156-idx';
const TABLES = ['main_red_verdicts', 'main_red_pr_errors', 'main_red_pairs'];
const REPOS = Array.from({ length: 20 }, (_, i) => `o/r${i}`);
const sha = (i) => i.toString(16).padStart(40, '0');

async function seeded(t) {
  const h = await openDb();
  if (h === null) { t.skip('node:sqlite unavailable in this runtime'); return null; }
  const { db } = h;
  db.exec('BEGIN');
  const v = db.prepare('INSERT INTO main_red_verdicts (repo, decision, reason, sha, at) VALUES (?,?,?,?,?)');
  REPOS.forEach((r, i) => v.run(r, 'green', '', sha(i), '2026-10-14T00:00:00Z'));
  const e = db.prepare('INSERT INTO main_red_pr_errors (repo, head, job, error, run_at, at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 20000; i++) e.run(REPOS[i % REPOS.length], sha(i), 'job', 'err', '2026-10-01T00:00:00Z', `2026-10-${String(1 + (i % 14)).padStart(2, '0')}T00:00:00Z`);
  const p = db.prepare('INSERT INTO main_red_pairs (repo, hash, job, first_error, prs, opened_at, resolved_at) VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < 10000; i++) p.run(REPOS[i % REPOS.length], `h${i % 500}`, 'job', 'err', '1,2', `2026-10-01T00:00:${String(i % 60).padStart(2, '0')}Z#${i}`, (i < 500 && i % 50 === 0) ? null : '2026-10-02T00:00:00Z');
  db.exec('COMMIT');
  return db;
}

async function reads(db, path) {
  const log = [];
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB: capturingD1(db, log), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200, `${path} answered ${res.status}`);
  return log;
}
function planOf(db, log, re) {
  const hit = log.filter((r) => re.test(r.sql));
  assert.ok(hit.length > 0, `no statement matched ${re}`);
  return plan(db, hit[0].sql, ...hit[0].binds.map((x) => (x === undefined ? null : x)));
}
function noFullScan(lines) {
  assert.deepEqual(fullScans(lines, TABLES), [], `full scan:\n  ${lines.join('\n  ')}`);
}

test('X1: GET verdict reads main_red_verdicts by its PRIMARY KEY', async (t) => {
  const db = await seeded(t); if (!db) return;
  const lines = planOf(db, await reads(db, '/api/main-red-state/verdict?repo=o%2Fr3'), /FROM main_red_verdicts WHERE repo=/);
  noFullScan(lines);
  assert.ok(lines.some((l) => /SEARCH main_red_verdicts USING INDEX sqlite_autoindex_main_red_verdicts_1 \(repo=\?\)/.test(l)), lines.join(' | '));
});

test('X2: GET pr-errors reads by (repo, head), the PRIMARY KEY', async (t) => {
  const db = await seeded(t); if (!db) return;
  const lines = planOf(db, await reads(db, `/api/main-red-state/pr-errors?repo=o%2Fr3&heads=${sha(3)},${sha(23)}`), /FROM main_red_pr_errors/);
  noFullScan(lines);
  assert.ok(lines.some((l) => /SEARCH main_red_pr_errors USING INDEX sqlite_autoindex_main_red_pr_errors_1 \(repo=\? AND head=\?\)/.test(l)), lines.join(' | '));
});

test('X3: the pr-errors prune deletes through main_red_pr_errors_at (repo, at)', async (t) => {
  const db = await seeded(t); if (!db) return;
  const lines = plan(db, 'DELETE FROM main_red_pr_errors WHERE repo=?1 AND at < ?2', 'o/r3', '2026-10-07T00:00:00Z');
  noFullScan(lines);
  assert.ok(lines.some((l) => /SEARCH main_red_pr_errors USING (COVERING )?INDEX main_red_pr_errors_at \(repo=\? AND at<\?\)/.test(l)), lines.join(' | '));
});

test('X4: GET pairs reads the open rows through main_red_pairs_open', async (t) => {
  const db = await seeded(t); if (!db) return;
  const lines = planOf(db, await reads(db, '/api/main-red-state/pairs?repo=o%2Fr3'), /FROM main_red_pairs/);
  noFullScan(lines);
  assert.ok(lines.some((l) => /SEARCH main_red_pairs USING INDEX main_red_pairs_open \(repo=\?\)/.test(l)), lines.join(' | '));
});

test('X5: the pair resolve updates through main_red_pairs_open', async (t) => {
  const db = await seeded(t); if (!db) return;
  const lines = plan(db, 'UPDATE main_red_pairs SET resolved_at=?3 WHERE repo=?1 AND hash=?2 AND resolved_at IS NULL', 'o/r3', 'h3', '2026-10-14T00:00:00Z');
  noFullScan(lines);
  assert.ok(lines.some((l) => /SEARCH main_red_pairs USING INDEX main_red_pairs_open \(repo=\? AND hash=\?\)/.test(l)), lines.join(' | '));
});
