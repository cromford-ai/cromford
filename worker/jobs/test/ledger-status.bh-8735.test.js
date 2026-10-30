import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-8735: GET /api/ledger takes an optional `status` filter, so the Tackler
// infra collector reads the conductor's BLOCKED_HUMAN parks from the pr_state
// ledger (bin/lib/unblock/collectors/infra.sh, unblock_infra_src parks) instead
// of state/merge-conductor/pr-state.tsv. idx_ledgers_kind_status_updated serves
// it. No `status` (or an empty one) is the list read as it was.

const SECRET = 'test-secret';

async function open(t) {
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function get(DB, path) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

function seed(db, rows) {
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)`);
  for (const r of rows) ins.run(r.kind, r.key, r.status, r.detail ?? null, r.at, r.at);
  db.exec('COMMIT');
}

const at = (i) => new Date(Date.UTC(2026, 9, 20) + i * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const SMALL = [
  { kind: 'pr_state', key: 'example-org/alpha#1', status: 'BLOCKED_HUMAN', at: at(1) },
  { kind: 'pr_state', key: 'example-org/alpha#2', status: 'QUEUED', at: at(2) },
  { kind: 'pr_state', key: 'example-org/alpha#3', status: 'BLOCKED_HUMAN', at: at(3) },
  { kind: 'deploy', key: 'example-org/alpha#1', status: 'BLOCKED_HUMAN', at: at(4) },
  { kind: 'pr_state', key: 'example-org/alpha#4', status: 'MERGED', at: at(5) },
];

test('S1: status=BLOCKED_HUMAN answers only the BLOCKED_HUMAN rows of that kind, newest first', async (t) => {
  const env = await open(t); if (!env) return;
  await get(env.DB, '/api/ledger?kind=pr_state');
  seed(env.db, SMALL);
  const r = await get(env.DB, '/api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=1000');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.ledgers.map((l) => [l.kind, l.key, l.status]), [
    ['pr_state', 'example-org/alpha#3', 'BLOCKED_HUMAN'],
    ['pr_state', 'example-org/alpha#1', 'BLOCKED_HUMAN'],
  ]);
});

test('S2: no status, or an empty one, answers the same rows in the same order as before', async (t) => {
  const env = await open(t); if (!env) return;
  await get(env.DB, '/api/ledger?kind=pr_state');
  seed(env.db, SMALL);
  const want = ['example-org/alpha#4', 'example-org/alpha#3', 'example-org/alpha#2', 'example-org/alpha#1'];
  const a = await get(env.DB, '/api/ledger?kind=pr_state');
  const b = await get(env.DB, '/api/ledger?kind=pr_state&status=');
  assert.deepEqual(a.body.ledgers.map((l) => l.key), want);
  assert.deepEqual(b.body.ledgers.map((l) => l.key), want);
  // The cursor still composes with the filter.
  const c = await get(env.DB, `/api/ledger?kind=pr_state&status=BLOCKED_HUMAN&before=${at(3)}`);
  assert.deepEqual(c.body.ledgers.map((l) => l.key), ['example-org/alpha#1']);
});

test('S3: kind isolation: kind=deploy&status=BLOCKED_HUMAN answers no pr_state row', async (t) => {
  const env = await open(t); if (!env) return;
  await get(env.DB, '/api/ledger?kind=pr_state');
  seed(env.db, SMALL);
  const r = await get(env.DB, '/api/ledger?kind=deploy&status=BLOCKED_HUMAN');
  assert.equal(r.status, 200);
  assert.equal(r.body.ledgers.filter((l) => l.kind === 'pr_state').length, 0);
  assert.deepEqual(r.body.ledgers.map((l) => [l.kind, l.key]), [['deploy', 'example-org/alpha#1']]);
  const none = await get(env.DB, '/api/ledger?kind=pr_state&status=NOPE');
  assert.deepEqual(none.body.ledgers, []);
});

test('S4: EXPLAIN QUERY PLAN at 20,000 pr_state + 50,000 other rows: an index search, no table scan', async (t) => {
  const env = await open(t); if (!env) return;
  await get(env.DB, '/api/ledger?kind=pr_state');
  const states = ['QUEUED', 'MERGED', 'READY', 'WAIT_CI', 'BLOCKED_HUMAN', 'CLOSED', 'NEEDS_REBASE', 'MERGED', 'MERGED', 'MERGED'];
  const rows = [];
  for (let i = 0; i < 20000; i++) rows.push({ kind: 'pr_state', key: `example-org/r${i % 40}#${i}`, status: states[i % 10], at: at(i) });
  for (let i = 0; i < 50000; i++) rows.push({ kind: ['deploy', 'migration', 'lead_part', 'br_attempt'][i % 4], key: `k${i}`, status: 'BLOCKED_HUMAN', at: at(i) });
  seed(env.db, rows);
  env.db.exec('ANALYZE');
  // Capture the statement the route really runs, then EXPLAIN that text.
  const seen = [];
  const orig = env.db.prepare.bind(env.db);
  env.db.prepare = (sql) => { if (/FROM ledgers WHERE/.test(sql)) seen.push(sql); return orig(sql); };
  const r = await get(env.DB, '/api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=1000');
  env.db.prepare = orig;
  assert.equal(r.status, 200);
  assert.equal(r.body.ledgers.length, 1000);
  assert.ok(r.body.ledgers.every((l) => l.kind === 'pr_state' && l.status === 'BLOCKED_HUMAN'));
  assert.equal(seen.length, 1, seen.join(' || '));
  assert.match(seen[0], /status=\?2/);
  const plan = env.db.prepare('EXPLAIN QUERY PLAN ' + seen[0]).all('pr_state', 'BLOCKED_HUMAN')
    .map((x) => x.detail).join(' | ');
  assert.match(plan, /SEARCH ledgers USING INDEX idx_ledgers_kind_status_updated \(kind=\? AND status=\?\)/, plan);
  assert.doesNotMatch(plan, /SCAN ledgers/, plan);
  // The index walks the order too: no temp b-tree sort over the matches.
  assert.doesNotMatch(plan, /USE TEMP B-TREE/, plan);
});
