import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2536 — a stage.<x> route for every catalogued agent-call stage, seeded as
// ONE claude rung (what agent-call runs for an unrouted stage today: claude, no
// fallback). Driven against THE SQL THAT SHIPS, and through worker.fetch for the
// PUT the Models page sends, like runner-routes.bh-1766.test.js.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const NEW_ROLES = [
  'qa', 'preplan-files', 'prodqa', 'repro', 'lead-review', 'map', 'signals',
  'ideate', 'synth', 'prd', 'mockup', 'revise', 'remediate', 'mine', 'feature-map-draft', 'readout', 'chat',
].map((s) => `stage.${s}`);
// Their callers pick the runner in code (or only claude can run them), so a
// route would be a switch that changes nothing: not seeded.
const PINNED = ['decompose', 'orchestrator', 'trapeval', 'bench', 'eval'].map((s) => `stage.${s}`);
const BH1766 = ['triage', 'plan', 'preplan', 'execute', 'review', 'fix'].map((s) => `stage.${s}`);

// Copied from model-routes-seed.bh-1908.test.js (test files stay independent).
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
    return { ...bindAndRun([]), bind: (...binds) => { const s = bindAndRun(binds); s._sql = sql; s._binds = binds; return s; } };
  };
  return {
    prepare,
    batch: async (xs) => xs.map((x) => {
      const r = db.prepare(x._sql).run(...(x._binds || []));
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    }),
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const priceModel = (db, model) => db.prepare(
  `INSERT OR IGNORE INTO model_prices (model, slug, prompt, completion, source, updated_at)
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-26T00:00:00Z')`
).run(model, `test/${model}`);

const put = (DB, role, ladder, extra = {}) => call(DB, '/api/model-routes', {
  method: 'PUT', body: { role, ladder, actor: 'op-test', reason: 'bh-2536 test', ...extra },
});

const ladder = (db, role) => db.prepare(
  'SELECT position, model, runner FROM model_routes WHERE role=? AND project IS NULL ORDER BY position'
).all(role).map((r) => `${r.position}:${r.model}:${r.runner}`);
const count = (db, table) => Number(db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n);

test('W1: a fresh DB carries every BH-2536 stage role as one claude rung, seeded at hub scope', () => {
  const db = openDb();
  for (const role of NEW_ROLES) {
    assert.deepEqual(ladder(db, role), ['0:claude-opus-5-5:claude'], role);
    const by = db.prepare('SELECT updated_by FROM model_routes WHERE role=? AND project IS NULL').get(role);
    assert.equal(by.updated_by, 'seed', role);
  }
});

test('W1b: no route is seeded for a stage whose caller pins the runner, nor for stage.verify', () => {
  const db = openDb();
  for (const role of [...PINNED, 'stage.verify']) assert.deepEqual(ladder(db, role), [], role);
});

test('W2: re-applying schema.sql three times adds no row (idempotent)', () => {
  const db = openDb();
  const before = count(db, 'model_routes');
  for (let i = 0; i < 3; i++) db.exec(SCHEMA);
  assert.equal(count(db, 'model_routes'), before);
});

test('W3: the Models page PUT switches a new stage role, and a re-apply keeps the operator ladder', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'claude-opus-5-5');
  priceModel(db, 'anthropic/claude-fable-5.1');
  const r = await put(DB, 'stage.prd', [
    { model: 'anthropic/claude-fable-5.1', runner: 'openrouter' },
    { model: 'claude-opus-5-5', runner: 'claude' },
  ], { confirm: true });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'stage.prd'), [
    '0:anthropic/claude-fable-5.1:openrouter', '1:claude-opus-5-5:claude',
  ]);
  const g = await call(DB, '/api/model-routes/stage.prd');
  assert.equal(g.status, 200);
  assert.equal(g.body.ladder[0].runner, 'openrouter');
});

test('W4: a role the operator emptied (audit row, no route rows) is not re-seeded', () => {
  const db = openDb();
  db.prepare(
    `INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
     VALUES ('hub', NULL, 'stage.mine', 0, 'claude-opus-5-5', 'claude', NULL, NULL, 'op-test', 'cut', '2026-09-26T00:00:00Z')`
  ).run();
  db.prepare("DELETE FROM model_routes WHERE role='stage.mine' AND project IS NULL").run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'stage.mine'), []);
});

test('W5: the six BH-1766 stage ladders are unchanged (claude then codex)', () => {
  const db = openDb();
  for (const role of BH1766) {
    assert.deepEqual(db.prepare('SELECT runner FROM model_routes WHERE role=? AND project IS NULL ORDER BY position')
      .all(role).map((x) => x.runner), ['claude', 'codex'], role);
  }
});

test('W6: a 3-rung PUT on a new stage role is 400 and leaves the seeded rung', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  for (const m of ['claude-opus-5-5', 'claude-fable-5-1', 'gpt-6-astra']) priceModel(db, m);
  const r = await put(DB, 'stage.readout', [
    { model: 'claude-opus-5-5', runner: 'claude' },
    { model: 'gpt-6-astra', runner: 'codex' },
    { model: 'claude-fable-5-1', runner: 'claude' },
  ], { confirm: true });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /at most 2 rungs/);
  assert.deepEqual(ladder(db, 'stage.readout'), ['0:claude-opus-5-5:claude']);
});

test('W7: a role that already has a hub row (no audit trail) is not topped up with the seed rung', () => {
  const db = openDb();
  db.prepare("DELETE FROM model_routes WHERE role='stage.repro' AND project IS NULL").run();
  db.prepare(
    `INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
     VALUES ('hub', NULL, 'stage.repro', 1, 'gpt-6-astra', 'codex', 'op-test', '2026-09-26T00:00:00Z')`
  ).run();
  assert.equal(count(db, 'model_route_changes'), 0);
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'stage.repro'), ['1:gpt-6-astra:codex']);
});
