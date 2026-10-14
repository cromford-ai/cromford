import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4846: custom console themes are settings rows ui.theme.custom.<slug>
// holding a theme document (~2.3 KB of JSON). The worker gives that prefix the
// document-sized value cap and a JSON-object check on PUT, and one narrow,
// audited DELETE. Every case drives worker.fetch, the real route table, over
// schema.sql applied to an in-memory sqlite (the cost-caps.bh-2564 harness).

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
const NO_DB = !DatabaseSync;

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const row = (db, k) => { const r = db.prepare('SELECT * FROM settings WHERE key=?').get(k); return r ? { ...r } : null; };
const changes = (db, k) => db.prepare('SELECT name, before_json, after_json, actor, reason FROM config_changes WHERE name=? ORDER BY id').all(k)
  .map((r) => ({ ...r }));

// A theme-shaped document of about the real size: 71 colour tokens plus 13 shape keys.
function themeJson() {
  const tokens = {};
  for (let i = 0; i < 71; i++) tokens[`--token-number-${i}`] = '#1d1c1a';
  const shape = {};
  for (let i = 0; i < 13; i++) shape[`--shape-${i}`] = "'Geist Mono', ui-monospace, monospace";
  return JSON.stringify({ v: 1, name: 'Night Shift', base: 'mill', tokens, shape });
}
const KEY = 'ui.theme.custom.night-shift';

test('ST1: a ~2.3 KB custom theme document is accepted and stored verbatim', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const value = themeJson();
  assert.ok(value.length > 2000 && value.length <= 4096, `fixture is ${value.length} chars`);
  const r = await call(env, 'PUT', '/api/settings', { key: KEY, value, actor: 'operator@example.com' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(row(db, KEY).value, value);
  assert.equal(row(db, KEY).actor, 'operator@example.com');
});

test('ST2: a custom-theme value that is not a JSON object is a 400, and nothing is written', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  for (const value of ['not json', '[1,2]', '"mill"', '42', 'null']) {
    const r = await call(env, 'PUT', '/api/settings', { key: KEY, value });
    assert.equal(r.status, 400, value);
    assert.match(r.body.error, /JSON object/);
  }
  const big = await call(env, 'PUT', '/api/settings', { key: KEY, value: JSON.stringify({ x: 'a'.repeat(4100) }) });
  assert.equal(big.status, 400);
  assert.match(big.body.error, /4096/);
  assert.equal(row(db, KEY), null);
});

test('ST3: an ordinary key keeps its 256-char cap', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/settings', { key: 'ui.theme.default', value: 'x'.repeat(300) });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /<= 256/);
  assert.equal(row(db, 'ui.theme.default'), null);
  // A lookalike outside the prefix gets no document cap either.
  const near = await call(env, 'PUT', '/api/settings', { key: 'ui.theme.customx.a', value: themeJson() });
  assert.equal(near.status, 400);
});

test('ST4: DELETE removes the row and writes its config_changes audit row in the same batch', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const value = themeJson();
  await call(env, 'PUT', '/api/settings', { key: KEY, value, actor: 'operator@example.com' });
  const r = await call(env, 'DELETE', `/api/settings/${KEY}?actor=ops%40example.com&reason=tidy`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { key: KEY, deleted: true });
  assert.equal(row(db, KEY), null);
  const audit = changes(db, KEY);
  assert.equal(audit.length, 2, 'the PUT and the DELETE');
  assert.deepEqual(audit[1], { name: KEY, before_json: JSON.stringify({ value }), after_json: 'null', actor: 'ops@example.com', reason: 'tidy' });
});

test('ST5: DELETE refuses every key outside ui.theme.custom.<slug>', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  db.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES ('ui.theme.default','mill','x','t')").run();
  db.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES ('lane.x.y','3','x','t')").run();
  for (const k of ['ui.theme.default', 'lane.x.y', 'ui.theme.custom.', 'ui.theme.custom.Upper', 'ui.theme.custom.' + 'a'.repeat(41), '%E0%A4%A']) {
    const r = await call(env, 'DELETE', `/api/settings/${k}`);
    assert.equal(r.status, 400, k);
  }
  assert.ok(row(db, 'ui.theme.default'));
  assert.ok(row(db, 'lane.x.y'));
  assert.equal(db.prepare('SELECT count(*) AS n FROM config_changes').get().n, 0);
});

test('ST6: DELETE of a missing row is 200 deleted:false and writes no audit row', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'DELETE', `/api/settings/${KEY}`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { key: KEY, deleted: false });
  assert.equal(db.prepare('SELECT count(*) AS n FROM config_changes').get().n, 0);
});
