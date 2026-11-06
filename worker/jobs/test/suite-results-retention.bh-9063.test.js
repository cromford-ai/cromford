// BH-9063 (C0): the retention rules of the suite ledger's two tables, driven
// through the REAL worker.fetch (POST /api/retention/run) on node:sqlite with
// the composed jobs schema.
//
//   R1 a real run deletes suite_results rows past 14 days and suite_reuse_runs
//      rows past 60 days, and nothing newer
//   R2 one retention_runs row per rule per run with the right counts; a dry run
//      counts and deletes nothing
//   R3 EXPLAIN QUERY PLAN of both rules' id reads at 20,000 rows: no full scan
//   R4 the schema.d seed carries each rule's window and the trust row, and the
//      code fallbacks equal the seed
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { RULES } from '../src/routes/retention.js';
import { TRUST_DEFAULT } from '../src/lib/suite-trust.js';
import { LANES_REGISTRY } from '../src/lib/core.js';

const SECRET = 'test-secret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const D = 86400;

async function run(DB, body = {}) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}
function result(db, repo, suite, updated) {
  db.prepare(`INSERT INTO suite_results (repo, ctx, class, suite, fingerprint, status, duration_s, run_id, head_sha, ok_at,
      last_run_id, runs, fails, first_at, updated_at) VALUES (?, 'isolated', 'builder', ?, ?, 'ok', 1, 'r', NULL, ?, 'r', 1, 0, ?, ?)`)
    .run(repo, suite, 'a'.repeat(64), updated, updated, updated);
}
function reuseRun(db, repo, k, created) {
  db.prepare(`INSERT INTO suite_reuse_runs (repo, run_key, ctx, class, head_sha, ran, reused, total, saved_s, created_at, updated_at)
              VALUES (?, ?, 'isolated', 'builder', NULL, 1, 1, 2, 5, ?, ?)`).run(repo, k, created, created);
}
function seed(db) {
  const repo = `example-org/ret-${process.pid}`;
  result(db, repo, 'tests/d13.sh', ago(13 * D));
  result(db, repo, 'tests/d14.sh', ago(14 * D + 1));
  result(db, repo, 'tests/d30.sh', ago(30 * D));
  reuseRun(db, repo, 'k59', ago(59 * D));
  reuseRun(db, repo, 'k61', ago(61 * D));
  reuseRun(db, repo, 'k90', ago(90 * D));
  return repo;
}
const auditRows = (db) => db.prepare(`SELECT rule, tbl, dry_run, counted, removed FROM retention_runs
  WHERE rule IN ('suite_results.age', 'suite_reuse_runs.age') ORDER BY rule`).all().map((r) => ({ ...r }));

test('R1 a real run deletes only ledger rows past their window', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  setting(db, 'retention.dry_run', '0');
  const repo = seed(db);
  const r = await run(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT suite FROM suite_results WHERE repo=? ORDER BY suite').all(repo).map((x) => x.suite), ['tests/d13.sh']);
  assert.deepEqual(db.prepare('SELECT run_key FROM suite_reuse_runs WHERE repo=? ORDER BY run_key').all(repo).map((x) => x.run_key), ['k59']);
});

test('R2 one audit row per rule per run; a dry run counts and deletes nothing', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  seed(db);
  // the seed is dry_run=1
  const dry = await run(DB);
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(dry.body.dry_run, true);
  assert.deepEqual(auditRows(db), [
    { rule: 'suite_results.age', tbl: 'suite_results', dry_run: 1, counted: 2, removed: 0 },
    { rule: 'suite_reuse_runs.age', tbl: 'suite_reuse_runs', dry_run: 1, counted: 2, removed: 0 },
  ]);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM suite_results').get().n, 3);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM suite_reuse_runs').get().n, 3);
  db.prepare('DELETE FROM retention_runs').run();
  setting(db, 'retention.dry_run', '0');
  const real = await run(DB);
  assert.equal(real.status, 200);
  assert.deepEqual(auditRows(db), [
    { rule: 'suite_results.age', tbl: 'suite_results', dry_run: 0, counted: 2, removed: 2 },
    { rule: 'suite_reuse_runs.age', tbl: 'suite_reuse_runs', dry_run: 0, counted: 2, removed: 2 },
  ]);
});

test('R3 both rules read their ids through an index at 20,000 rows', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  db.exec('BEGIN');
  for (let i = 0; i < 20000; i++) {
    const ts = ago((i % 40) * D + i);
    result(db, `example-org/r${i % 3}`, `tests/s${i}.sh`, ts);
    reuseRun(db, `example-org/r${i % 3}`, `k${i}`, ts);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const want = { 'suite_results.age': 'idx_suite_results_updated', 'suite_reuse_runs.age': 'idx_suite_reuse_runs_created' };
  for (const [rule, idx] of Object.entries(want)) {
    const r = RULES.find((x) => x.rule === rule);
    assert.ok(r, `rule ${rule} is not composed`);
    for (const sql of [r.ids, `SELECT COUNT(*) AS n FROM (${r.ids})`]) {
      const p = plan(db, sql, ago(14 * D), 500);
      assert.deepEqual(fullScans(p, [r.table]), [], `${rule}: ${JSON.stringify(p)}`);
      assert.ok(p.some((d) => d.includes(`USING INDEX ${idx}`) || d.includes(`USING COVERING INDEX ${idx}`)), `${rule}: ${JSON.stringify(p)}`);
    }
  }
});

test('R4 the seed carries both windows and the trust row; the code fallbacks equal it', () => {
  const dir = new URL('../schema.d/', import.meta.url);
  const file = readdirSync(dir).find((f) => /-bh-9063-suite-ledger\.sql$/.test(f));
  assert.ok(file, 'schema.d/*-bh-9063-suite-ledger.sql is missing');
  const sql = readFileSync(new URL(file, dir), 'utf8');
  const seeded = (k) => (sql.match(new RegExp(`\\('${k.replace(/\./g, '\\.')}','([^']*)'`)) || [])[1];
  assert.equal(seeded('retention.suite_results.days'), '14');
  assert.equal(seeded('retention.suite_reuse_runs.days'), '60');
  assert.equal(seeded('lib.suite-reuse.suite_reuse_trust'), 'class');
  assert.equal(TRUST_DEFAULT, 'class');
  for (const [rule, key] of [['suite_results.age', 'retention.suite_results.days'], ['suite_reuse_runs.age', 'retention.suite_reuse_runs.days']]) {
    const r = RULES.find((x) => x.rule === rule);
    assert.ok(r, rule);
    assert.equal(r.key, key);
    assert.equal(String(r.def), seeded(key));
  }
  const lib = (LANES_REGISTRY.libs || []).find((l) => l.id === 'suite-reuse');
  assert.equal(lib.knobs.find((k) => k.env === 'SUITE_REUSE_TRUST')?.default, TRUST_DEFAULT);
});
