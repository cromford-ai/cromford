// worker/jobs/test/pr-records-explain.bh-10455.test.js — BH-10455 (BH-9555.5).
// The triage-gate and triage-state PR-state readers (bin/lib/pr-record-readers.sh)
// read pr_records through GET /api/pr-records?repo=&number= (GET_SQL). This
// pins, at 50,000 seeded rows, that the record's GET, its list read and its two
// retention id reads each use their index and never SCAN pr_records, and that
// a pull_request webhook payload upserts the row those readers serve.
//   W1-W2  recordPrRecord on the real schema: the row GET_SQL returns
//   X1-X4  EXPLAIN QUERY PLAN at 50,000 rows (ANALYZE run)
// The SQL is read from the shipped modules, never copied into this file.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { GET_SQL, LIST_SQL } from '../src/routes/pr-records.js';
import { recordPrRecord } from '../src/lib/pr-record-intake.js';
import { ensureColumns } from '../src/lib/core.js';
import RETENTION from '../src/routes/retention.d/bh-8067-pr-records.js';

const NOW_MS = Date.parse('2026-11-28T00:00:00Z');
const T = '2026-11-28T00:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const A = 'a'.repeat(40), B = 'b'.repeat(40);
const ROWS = 50000;

async function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB } };
}

const prEvent = (repo, action, n, o = {}) => ({
  action, number: n, repository: { full_name: repo, default_branch: 'main' },
  pull_request: { number: n, state: 'open', draft: false, merged_at: null, updated_at: ago(60),
    head: { ref: 'ticket/x', sha: A }, base: { ref: 'main', sha: B }, labels: [], ...o },
});

// 50,000 rows over 200 repos, states open/closed/merged/null, times spread
// over 120 days. Every value comes from the row number.
async function seeded(t) {
  const o = await fresh(t); if (!o) return null;
  const { db } = o;
  // The list columns (pr_updated_at, pr_created_at) and their indexes come from
  // ensureColumns, as on the live worker (BH-8452, BH-8481).
  await ensureColumns(o.env, 'pr_records');
  const STATES = ['open', 'closed', 'merged', null];
  const PER = 100;
  db.exec('BEGIN');
  for (let b = 0; b < ROWS / PER; b++) {
    const vals = [], binds = [];
    for (let j = 0; j < PER; j++) {
      const i = b * PER + j, ts = ago((i % 2880) * 3600);
      vals.push('(?,?,?,?,?,?,?,?)');
      binds.push(`o/repo-${i % 200}`, i + 1, STATES[i % 4], '{}', ts, ts, ts, ts);
    }
    db.prepare(`INSERT INTO pr_records (repo, number, state, fields_at, created_at, refreshed_at, pr_updated_at, pr_created_at)
                VALUES ${vals.join(',')}`).run(...binds);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM pr_records').get().n, ROWS);
  return o;
}

function usesIndex(db, sql, binds, indexes) {
  const p = plan(db, sql, ...binds);
  assert.deepEqual(fullScans(p, ['pr_records']), [], `a full scan: ${p.join(' | ')}`);
  assert.ok(p.some((l) => indexes.some((ix) => l.includes(ix))), `none of ${indexes.join(', ')} in: ${p.join(' | ')}`);
  return p;
}

const rule = (name) => {
  const r = RETENTION.find((x) => x.rule === name);
  assert.ok(r, `retention rule ${name} missing`);
  return r;
};

// ── W: the webhook writer feeds the row the readers serve ─────────────────────
test('W1 a pull_request opened payload upserts the row; GET_SQL returns state open', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await recordPrRecord(o.env, T, 'pull_request', prEvent('o/bh10455-w1', 'opened', 7));
  assert.equal(r.written, 1);
  const row = o.db.prepare(GET_SQL).get('o/bh10455-w1', 7);
  assert.ok(row, 'no row after the webhook');
  assert.equal(row.state, 'open');
});

test('W2 a closed payload with merged_at upserts the same row to state merged', async (t) => {
  const o = await fresh(t); if (!o) return;
  await recordPrRecord(o.env, T, 'pull_request', prEvent('o/bh10455-w2', 'opened', 8));
  await recordPrRecord(o.env, T, 'pull_request', prEvent('o/bh10455-w2', 'closed', 8,
    { state: 'closed', merged_at: ago(30), updated_at: ago(30) }));
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pr_records WHERE repo = ?').get('o/bh10455-w2').n, 1);
  assert.equal(o.db.prepare(GET_SQL).get('o/bh10455-w2', 8).state, 'merged');
});

// ── X: the plans at 50,000 rows ───────────────────────────────────────────────
test('X1-X4 GET, list and both retention id reads use their index at 50,000 rows', async (t) => {
  const o = await seeded(t); if (!o) return;
  // X1 the readers' GET
  usesIndex(o.db, GET_SQL, ['o/repo-7', 40008], ['ux_pr_records_repo_number']);
  // X2 the list read (documented index: idx_pr_records_repo_state_upd)
  usesIndex(o.db, LIST_SQL, ['o/repo-7', 'open', null, 501],
    ['idx_pr_records_repo_state_upd', 'idx_pr_records_repo_state_created']);
  // X3 retention pr_records.closed
  usesIndex(o.db, rule('pr_records.closed').ids, [ago(14 * 86400), 500], ['idx_pr_records_state_refreshed']);
  // X4 retention pr_records.age
  usesIndex(o.db, rule('pr_records.age').ids, [ago(90 * 86400), 500], ['idx_pr_records_refreshed']);
});
