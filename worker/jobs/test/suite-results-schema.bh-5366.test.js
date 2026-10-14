import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureTable, CREATED_TABLES } from '../src/index.js';
import { LANES_REGISTRY } from '../src/lib/core.js';
import { REUSE_DEFAULTS } from '../src/lib/suite-results.js';
import { lookupSql, priorSql } from '../src/routes/suite-results.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5354.0 (BH-5366): the suite ledger's two tables, their worker self-create
// mirror, and the knob defaults the worker falls back to, pinned to the registry.

const SCHEMA = jobsSchemaSql();
const TABLES = ['suite_results', 'suite_reuse_runs'];

async function sqlite(t) {
  try {
    return (await import('node:sqlite')).DatabaseSync;
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

function shape(db, table) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((r) => ({
    name: r.name, type: r.type.toUpperCase(), notnull: Boolean(r.notnull), pk: r.pk, dflt: r.dflt_value,
  }));
  const idx = db.prepare(`SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=? AND name NOT LIKE 'sqlite_%' ORDER BY name`)
    .all(table).map((r) => r.name);
  return { cols, idx };
}

const pkOf = (s) => s.cols.filter((c) => c.pk > 0).sort((a, b) => a.pk - b.pk).map((c) => c.name);

test('schema.sql creates both ledger tables with their keys, re-runnably', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const r = shape(db, 'suite_results');
  assert.deepEqual(r.cols.map((c) => c.name), [
    'repo', 'ctx', 'class', 'suite', 'fingerprint', 'status', 'duration_s', 'run_id', 'head_sha', 'ok_at',
    'last_run_id', 'runs', 'fails', 'first_at', 'updated_at',
  ]);
  assert.deepEqual(pkOf(r), ['repo', 'ctx', 'class', 'suite', 'fingerprint']);
  assert.deepEqual(r.idx, ['idx_suite_results_key', 'idx_suite_results_updated']);
  const u = shape(db, 'suite_reuse_runs');
  assert.deepEqual(u.cols.map((c) => c.name), [
    'repo', 'run_key', 'ctx', 'class', 'head_sha', 'ran', 'reused', 'total', 'saved_s', 'created_at', 'updated_at',
  ]);
  assert.deepEqual(pkOf(u), ['repo', 'run_key']);
  assert.deepEqual(u.idx, ['idx_suite_reuse_runs_created']);
  db.close();
});

test('CREATED_TABLES mirrors schema.sql for both tables, statement for statement', async (t) => {
  const norm = (s) => s.replace(/\s+/g, ' ').replace(/\( /g, '(').replace(/ \)/g, ')').trim();
  for (const table of TABLES) {
    assert.ok(Array.isArray(CREATED_TABLES[table]), `CREATED_TABLES.${table} is missing`);
    for (const stmt of CREATED_TABLES[table]) {
      assert.ok(norm(SCHEMA).includes(norm(stmt)), `schema.sql does not carry: ${norm(stmt).slice(0, 80)}`);
    }
  }
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  const fresh = new DatabaseSync(':memory:');
  for (const table of TABLES) {
    await ensureTable({ DB: fresh }, table);
    await ensureTable({ DB: fresh }, table);
    assert.deepEqual(shape(fresh, table), shape(fromSchema, table));
  }
  fromSchema.close();
  fresh.close();
});

// Lead review of #5420: a plain JOIN scanned every (repo, ctx) row and rescanned
// json_each per row (74s for 1,500 items over 20k rows). The plan must loop
// json_each outside and SEEK the ledger on suite and fingerprint, never scan it.
test('lookup and prior-status reads seek the ledger per item, never scan it', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const plan = (sql) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all().map((r) => r.detail);
  const KEY = 'SEARCH r USING INDEX idx_suite_results_key (repo=? AND ctx=? AND suite=? AND fingerprint=?)';
  const PK = 'SEARCH r USING INDEX sqlite_autoindex_suite_results_1 (repo=? AND ctx=? AND class=? AND suite=? AND fingerprint=?)';
  for (const [cls, seek] of [['builder', KEY], ['ci', PK]]) {
    for (const [name, sql, alsoF] of [['lookup', lookupSql(cls), true], ['prior', priorSql(cls), false]]) {
      const p = plan(sql);
      const at = `${name}/${cls}: ${JSON.stringify(p)}`;
      assert.match(p[0], /^SCAN j VIRTUAL TABLE/, `json_each is not the outer loop: ${at}`);
      assert.equal(p[1], seek, `r is not seeked on all key columns: ${at}`);
      if (alsoF) assert.ok(p.includes(seek.replace('SEARCH r', 'SEARCH f')), `NOT EXISTS probe does not seek: ${at}`);
      assert.ok(!p.some((d) => /^SCAN (r|f)\b/.test(d)), `a ledger scan: ${at}`);
    }
  }
  db.close();
});

test('the ledger block in schema.sql is additive only', () => {
  const at = SCHEMA.indexOf('CREATE TABLE IF NOT EXISTS suite_results');
  assert.notEqual(at, -1);
  const block = SCHEMA.slice(SCHEMA.lastIndexOf('\n\n', at));
  const end = block.indexOf('idx_suite_reuse_runs_created');
  assert.notEqual(end, -1);
  assert.doesNotMatch(block.slice(0, end), /^\s*(DROP|DELETE|ALTER)\b/m);
  assert.match(block.slice(0, end), /D1 has no RLS/);
});

test('REUSE_DEFAULTS equal the registry defaults of the suite-reuse lib', () => {
  const lib = (LANES_REGISTRY.libs || []).find((l) => l.id === 'suite-reuse');
  assert.ok(lib, 'catalog/lanes.d/_lib.suite-reuse.json is not in the registry');
  const def = (env) => lib.knobs.find((k) => k.env === env)?.default;
  assert.equal(REUSE_DEFAULTS.reuse, def('SUITE_REUSE'));
  assert.equal(REUSE_DEFAULTS.max_age_h, def('SUITE_REUSE_MAX_AGE_H'));
  const age = lib.knobs.find((k) => k.env === 'SUITE_REUSE_MAX_AGE_H');
  assert.equal(age.min, 1);
  assert.equal(age.max, 720);
});
