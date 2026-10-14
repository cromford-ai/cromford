import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ensureTable } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3425 (BH-3422.0) — the model-watch table. schema.sql is what harness-sync
// applies at deploy, CREATED_TABLES is what the worker creates on a D1 that
// deploy never reached. The two must be the same table. Fixture ids are neutral
// (acme / m-1): tests/alert-triage-runners R6 scans worker/ for model literals.

const SCHEMA = jobsSchemaSql();

const COLUMNS = [
  'vendor', 'model_id', 'slug', 'source', 'source_url', 'released_at', 'prompt', 'completion',
  'cache_read', 'cache_write', 'context_window', 'status', 'suggestion', 'probe', 'probe_attempted_at',
  'announced_at', 'first_seen', 'updated_at', 'actor', 'reason',
];

function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

async function openBareDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  return new DatabaseSync(':memory:');
}

// The schema.sql statements that build model_watch: its CREATE TABLE (to the
// matching close paren) and every CREATE INDEX ... ON model_watch.
function schemaStatements() {
  const start = SCHEMA.search(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+model_watch\s*\(/i);
  assert.ok(start !== -1, 'schema.sql must contain CREATE TABLE IF NOT EXISTS model_watch');
  const paren = start + SCHEMA.slice(start).indexOf('(');
  let depth = 0, end = -1;
  for (let i = paren; i < SCHEMA.length; i++) {
    if (SCHEMA[i] === '(') depth++;
    else if (SCHEMA[i] === ')') { depth--; if (depth === 0) { end = i; break; } }
  }
  assert.ok(end !== -1, 'no matching close paren for model_watch');
  const idx = SCHEMA.match(/CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+\w+\s+ON\s+model_watch\s*\([^)]*\)/gi) || [];
  assert.ok(idx.length > 0, 'schema.sql must index model_watch');
  return [SCHEMA.slice(start, end + 1), ...idx];
}

async function bothDbs(t) {
  const a = await openBareDb(t);
  if (!a) return null;
  const b = await openBareDb(t);
  for (const s of schemaStatements()) a.exec(s);
  await ensureTable({ DB: sqliteDB(b) }, 'model_watch');
  return { a, b };
}

test('W1 schema.sql and ensureTable give identical PRAGMA table_info(model_watch)', async (t) => {
  const dbs = await bothDbs(t);
  if (!dbs) return;
  const shape = (db) => db.prepare('PRAGMA table_info(model_watch)').all()
    .map(({ name, type, notnull, dflt_value, pk }) => ({ name, type, notnull, dflt_value, pk }));
  const a = shape(dbs.a), b = shape(dbs.b);
  assert.deepEqual(b, a);
  assert.deepEqual(a.map((c) => c.name), COLUMNS);
  assert.deepEqual(a.filter((c) => c.pk).map((c) => [c.name, c.pk]), [['vendor', 1], ['model_id', 2]]);
  assert.deepEqual(a.filter((c) => c.notnull).map((c) => c.name),
    ['vendor', 'model_id', 'source', 'status', 'first_seen', 'updated_at']);
  assert.equal(a.find((c) => c.name === 'status').dflt_value, "'new'");
  dbs.a.close(); dbs.b.close();
});

test('W2 both carry idx_model_watch_status on (status, first_seen)', async (t) => {
  const dbs = await bothDbs(t);
  if (!dbs) return;
  for (const db of [dbs.a, dbs.b]) {
    const names = db.prepare('PRAGMA index_list(model_watch)').all().map((r) => r.name);
    assert.ok(names.includes('idx_model_watch_status'), `index list ${names}`);
    const cols = db.prepare('PRAGMA index_info(idx_model_watch_status)').all().map((r) => r.name);
    assert.deepEqual(cols, ['status', 'first_seen']);
  }
  dbs.a.close(); dbs.b.close();
});

test('W3 the status CHECK, the status default and the (vendor, model_id) key hold on both', async (t) => {
  const dbs = await bothDbs(t);
  if (!dbs) return;
  const ins = 'INSERT INTO model_watch (vendor, model_id, source, first_seen, updated_at';
  for (const db of [dbs.a, dbs.b]) {
    assert.throws(() => db.prepare(`${ins}, status) VALUES ('acme','m-0','x','t','t','bogus')`).run(), /CHECK/i);
    db.prepare(`${ins}) VALUES ('acme','m-1','x','t','t')`).run();
    assert.equal(db.prepare("SELECT status FROM model_watch WHERE model_id='m-1'").get().status, 'new');
    assert.throws(() => db.prepare(`${ins}) VALUES ('acme','m-1','y','t','t')`).run(), /UNIQUE|PRIMARY/i);
    db.prepare(`${ins}) VALUES ('other','m-1','x','t','t')`).run();
    for (const s of ['suggested', 'adopted', 'ignored']) {
      db.prepare(`${ins}, status) VALUES ('acme','m-${s}','x','t','t','${s}')`).run();
    }
  }
  dbs.a.close(); dbs.b.close();
});
