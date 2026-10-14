import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { ensureTable, CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1032: `model_prices` is a NEW table, and `bin/harness-sync.sh` runs
// `npx wrangler deploy` and nothing else — there is no `wrangler d1 execute`
// anywhere in bin/, cron/, fly/ or .github/. So the table only exists on the
// live database if the worker creates it itself (the BH-658 rule in
// src/lib/core.js). Without that, the hub's 04:30 push answers 500 and eight
// boxes burn their 05:05 daily ALERT on a false cause, while the code reviews
// as correct because index.test.js's fakeDB accepts any SQL.
//
// So the route runs against a database that has NEVER seen schema.sql — the
// shape a `wrangler deploy` leaves behind — and the assertion is that it
// answers 200 and the rows read back.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// A D1-shaped adapter over node:sqlite: the surface these two routes use is
// prepare().bind().run()/first()/all() and batch(). D1 takes undefined for a
// NULL bind; node:sqlite refuses it, so binds are normalised here and the
// worker's own binds stay unchanged.
function d1(db) {
  const norm = (v) => (v === undefined || v === null ? null : (typeof v === 'boolean' ? (v ? 1 : 0) : v));
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql,
    _binds: binds,
    bind: (...b) => make(sql, b.map(norm)),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => stmts.map((s) => exec(s._sql, s._binds)),
  };
}

const req = (method, path, body) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
});

// Parses the column list of a `CREATE TABLE IF NOT EXISTS <name> (...)` out of
// schema.sql, the way alerts-schema.bh-1068.test.js does.
function parseTable(sql, name) {
  const start = sql.search(new RegExp(`CREATE\\s+TABLE\\s+IF\\s+NOT\\s+EXISTS\\s+${name}\\s*\\(`, 'is'));
  assert.ok(start !== -1, `schema.sql must contain CREATE TABLE IF NOT EXISTS ${name}`);
  const paren = start + sql.slice(start).indexOf('(');
  let depth = 0, end = -1;
  for (let i = paren; i < sql.length; i++) {
    if (sql[i] === '(') depth++;
    else if (sql[i] === ')') { depth--; if (depth === 0) { end = i; break; } }
  }
  assert.ok(end !== -1, `could not find matching close paren in ${name}`);
  return sql.slice(paren + 1, end).split('\n')
    .map((s) => s.trim())
    .filter((s) => s && !s.startsWith('--'))
    .map((s) => {
      const parts = s.replace(/,\s*$/, '').split(/\s+/);
      return { name: parts[0], type: parts.slice(1).join(' ').replace(/--.*/, '').replace(/,\s*$/, '').trim() };
    });
}

test('POST+GET /api/model-prices work on a database that never ran schema.sql', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const db = new DatabaseSync(':memory:');   // deliberately EMPTY — a fresh `wrangler deploy`
  const env = { DB: d1(db), HARNESS_SECRET: SECRET };

  const post = await worker.fetch(req('POST', '/api/model-prices', {
    source: 'openrouter',
    rows: [
      { model: 'claude-opus-5', slug: 'anthropic/claude-opus-5', prompt: 0.000015, completion: 0.000075,
        cache_read: 0.0000015, cache_write: 0.00001875, cliff_tokens: 200000 },
      { model: 'claude-haiku-4-5-20251001', slug: 'anthropic/claude-haiku-4.5', prompt: 0.000001, completion: 0.000005 },
    ],
  }), env);
  assert.equal(post.status, 200, `POST must self-create the table, not 500: ${await post.clone().text()}`);
  assert.equal((await post.json()).accepted, 2);

  const get = await worker.fetch(req('GET', '/api/model-prices'), env);
  assert.equal(get.status, 200, `GET must self-create the table, not 500: ${await get.clone().text()}`);
  const body = await get.json();
  assert.equal(body.models, 2);
  assert.equal(body.per_token['claude-opus-5'].prompt, 0.000015);
  assert.equal(body.per_token['claude-opus-5'].cliff_tokens, 200000);
  // A model with no cliff carries no key at all: cost_model_cliff reads
  // `.cliff_tokens | numbers` and a null would not be the same answer.
  assert.equal('cliff_tokens' in body.per_token['claude-haiku-4-5-20251001'], false);
  assert.equal(body.source, 'openrouter');

  db.close();
});

test('GET /api/model-prices answers an empty table, not a 500, before the first push', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const db = new DatabaseSync(':memory:');
  const env = { DB: d1(db), HARNESS_SECRET: SECRET };

  const get = await worker.fetch(req('GET', '/api/model-prices'), env);
  assert.equal(get.status, 200, `a never-pushed table is empty, not missing: ${await get.clone().text()}`);
  const body = await get.json();
  assert.equal(body.models, 0);
  assert.deepEqual(body.per_token, {});

  db.close();
});

test('CREATED_TABLES.model_prices creates the same columns as schema.sql', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  assert.ok(Array.isArray(CREATED_TABLES.model_prices), 'CREATED_TABLES.model_prices is an array');

  const expected = parseTable(SCHEMA, 'model_prices');
  const db = new DatabaseSync(':memory:');
  const env = { DB: db };
  await ensureTable(env, 'model_prices');
  await ensureTable(env, 'model_prices'); // idempotent

  const got = db.prepare('PRAGMA table_info(model_prices)').all()
    .map((r) => ({ name: r.name, type: r.type, notnull: Boolean(r.notnull), pk: Boolean(r.pk) }));
  assert.equal(got.length, expected.length, `column count: ${got.map((c) => c.name).join(',')}`);
  for (let i = 0; i < expected.length; i++) {
    assert.equal(got[i].name, expected[i].name, `column ${i}`);
    assert.equal(got[i].type.toUpperCase(), expected[i].type.split(/\s+/)[0].toUpperCase(), `type for ${got[i].name}`);
  }
  const model = got.find((c) => c.name === 'model');
  assert.ok(model && model.pk, 'model is the primary key — the ON CONFLICT(model) upsert depends on it');
  const updated = got.find((c) => c.name === 'updated_at');
  assert.ok(updated && updated.notnull, 'updated_at is NOT NULL, as in schema.sql');

  db.close();
});
