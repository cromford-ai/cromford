// BH-3936 (BH-3929 ask 6): the daily-digest `pr_health` state section.
//
// WHAT IS PINNED
//   W1: latest row per project wins, rows sorted by project, in the row shape
//       {project, day, open, age, ownerless, approved_not_merged,
//       blocked_ci_only, as_of}. Two rows for one project need a fake db: the
//       real ledgers PK (kind, key) allows one.
//   W2: a detail that is not JSON, or misses `age`, is skipped and counted;
//       the section stays ok and the good row is still listed.
//   W3: isEmptyDigest counts pr_health rows as content.
//   W4: the real route over a REAL schema.sql database answers the rows the
//       sweep's job_ledger_put writes (kind pr_health, key <project>).
// Every timestamp is pinned.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { readStateSections } from '../src/lib/daily-digest/state-sections.js';
import { isEmptyDigest, dayWindow } from '../src/lib/daily-digest/shape.js';

const SECRET = 'test-secret';
const DAY = '2026-10-02';
const WIN = dayWindow(DAY, '2026-10-03T12:00:00Z');
const OPTS = { limit: 20, loopMin: 2, trip: 2, humanActors: [] };
const EMPTY = JSON.parse(readFileSync(
  new URL('../../../tests/fixtures/daily-digest/empty-day.json', import.meta.url), 'utf8'));

const detail = (open, day = DAY) => JSON.stringify({
  day, open, age: { lt1d: 1, '1to3d': 0, '3to7d': 0, gt7d: open - 1 },
  ownerless: 1, approved_not_merged: 0, blocked_ci_only: 0,
});

// A db whose pr_health read answers `rows` (already in the reader's ORDER BY
// updated_at DESC) and every other read answers nothing.
const fakeDb = (rows) => ({
  prepare(sql) {
    const results = /kind='pr_health'/.test(sql) ? rows : [];
    const stmt = { bind: () => stmt, all: async () => ({ results }) };
    return stmt;
  },
});

test('W1: the latest row per project wins, sorted by project', async () => {
  const s = await readStateSections(fakeDb([
    { key: 'project-1', detail: detail(3), updated_at: '2026-10-02T23:00:00Z' },
    { key: 'project-4', detail: detail(55), updated_at: '2026-10-02T22:00:00Z' },
    { key: 'project-4', detail: detail(9, '2026-10-01'), updated_at: '2026-10-01T22:00:00Z' },
  ]), WIN, OPTS);
  assert.equal(s.pr_health.ok, true);
  assert.equal(s.pr_health.skipped, 0);
  assert.deepEqual(s.pr_health.rows, [
    { project: 'project-1', day: DAY, open: 3, age: { lt1d: 1, '1to3d': 0, '3to7d': 0, gt7d: 2 },
      ownerless: 1, approved_not_merged: 0, blocked_ci_only: 0, as_of: '2026-10-02T23:00:00Z' },
    { project: 'project-4', day: DAY, open: 55, age: { lt1d: 1, '1to3d': 0, '3to7d': 0, gt7d: 54 },
      ownerless: 1, approved_not_merged: 0, blocked_ci_only: 0, as_of: '2026-10-02T22:00:00Z' },
  ]);
});

test('W2: a malformed detail is skipped and counted, never a throw', async () => {
  const noAge = JSON.parse(detail(4));
  delete noAge.age;
  const s = await readStateSections(fakeDb([
    { key: 'a-os', detail: 'not-json', updated_at: '2026-10-02T23:00:00Z' },
    { key: 'b-os', detail: JSON.stringify(noAge), updated_at: '2026-10-02T22:00:00Z' },
    { key: 'c-os', detail: detail(2), updated_at: '2026-10-02T21:00:00Z' },
  ]), WIN, OPTS);
  assert.equal(s.pr_health.ok, true);
  assert.equal(s.pr_health.skipped, 2);
  assert.deepEqual(s.pr_health.rows.map((r) => r.project), ['c-os']);
});

test('W3: isEmptyDigest counts pr_health rows as content', () => {
  assert.equal(isEmptyDigest(EMPTY), true);
  const withRow = JSON.parse(JSON.stringify(EMPTY));
  withRow.pr_health.rows = [{ project: 'project-4', day: DAY, open: 0 }];
  assert.equal(isEmptyDigest(withRow), false);
  const failed = { ...EMPTY, pr_health: { ok: false, error: 'boom' } };
  assert.equal(isEmptyDigest(failed), false);
});

test('W4: the route answers the rows the sweep writes, on a real schema', async (t) => {
  const o = await openDb();
  if (o === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const { db, DB } = o;
  const put = db.prepare(`INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES (?, ?, 'ok', ?, ?, ?)`);
  put.run('pr_health', 'project-4', detail(55), '2026-10-02T22:00:00Z', '2026-10-02T22:00:00Z');
  put.run('pr_health', 'example-org/extra', 'not-json', '2026-10-02T22:00:00Z', '2026-10-02T22:00:00Z');
  const res = await worker.fetch(
    new Request(`https://jobs.test/api/metrics/daily-digest?day=${DAY}`, { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.pr_health.ok, true, JSON.stringify(body.pr_health));
  assert.equal(body.pr_health.skipped, 1);
  assert.deepEqual(body.pr_health.rows.map((r) => [r.project, r.open, r.as_of]), [['project-4', 55, '2026-10-02T22:00:00Z']]);
});
