import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1766 (BH-1749.4) — the runner per build stage as model_routes rows.
//   S*: the stage.* seed rows schema.sql ships (claude first, codex fallback,
//       no new model literal, and a re-apply never re-adds a rung an operator
//       cut);
//   W*: the PUT's two refusals for a stage.* ladder — an unknown runner (the
//       check predates this ticket; pinned here) and a third rung (new: agent-call
//       reads a primary and one fallback, nothing past it) — and that a valid
//       write is audited.
// Driven through worker.fetch against the SQL that ships, like the #1510 suites.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const STAGES = ['triage', 'plan', 'preplan', 'execute', 'review', 'fix'];

// Copied from model-routes-ui.bh-1510-3.test.js (not imported: test files stay
// independent). Each .bind() returns its OWN statement.
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

const openDb = () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
};

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
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-24T00:00:00Z')`
).run(model, `test/${model}`);

const priceAll = (db, models) => { for (const m of models) priceModel(db, m); };
const count = (db, table) => Number(db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n);
const put = (DB, role, ladder, extra = {}) => call(DB, '/api/model-routes', {
  method: 'PUT', body: { role, ladder, actor: 'op-test', reason: 'bh-1766 test', ...extra },
});

// ─────────────────────────────────────────────────────────────── seed

test('S1: GET /api/model-routes/stage.triage answers the seeded claude/codex rungs', async () => {
  const DB = sqliteDB(openDb());
  const r = await call(DB, '/api/model-routes/stage.triage');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.source, 'hub');
  assert.deepEqual(r.body.ladder.map(({ position, model, runner }) => ({ position, model, runner })), [
    { position: 0, model: 'claude-fable-5-1', runner: 'claude' },
    { position: 1, model: 'gpt-6-astra', runner: 'codex' },
  ]);
});

test('S2: all six stage.* roles are seeded at hub scope, two rungs each, claude then codex, updated_by seed', () => {
  const db = openDb();
  for (const s of STAGES) {
    const rows = db.prepare(
      "SELECT position, runner, updated_by, project FROM model_routes WHERE role=? ORDER BY position"
    ).all(`stage.${s}`);
    assert.equal(rows.length, 2, `stage.${s} rungs`);
    assert.deepEqual(rows.map((r) => r.runner), ['claude', 'codex'], `stage.${s} runners`);
    for (const r of rows) {
      assert.equal(r.updated_by, 'seed');
      assert.equal(r.project, null);
    }
  }
  // No live-box value like grok is seeded under the stage. prefix: the six roles
  // above are among the seeded stage.* roles, and every other one (BH-2536: one
  // per catalogued stage) is a single claude rung — what agent-call runs unrouted.
  const seeded = db.prepare("SELECT DISTINCT role FROM model_routes WHERE role LIKE 'stage.%'").all().map((r) => r.role);
  for (const s of STAGES) assert.ok(seeded.includes(`stage.${s}`), `stage.${s} not seeded`);
  for (const role of seeded.filter((r) => !STAGES.includes(r.slice('stage.'.length)))) {
    const rows = db.prepare("SELECT position, runner FROM model_routes WHERE role=?").all(role);
    assert.deepEqual(rows.map((r) => `${r.position}:${r.runner}`), ['0:claude'], role);
  }
});

test('S3: a re-apply of schema.sql does not put back a rung an operator cut', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'claude-fable-5-1');
  const r = await put(DB, 'stage.triage', [{ model: 'claude-fable-5-1', runner: 'claude' }]);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  const rows = db.prepare("SELECT position FROM model_routes WHERE role='stage.triage' AND project IS NULL").all();
  assert.equal(rows.length, 1, 'still the one rung the operator left');
});

test('S4: every stage.* seed model is reused from a non-stage seed row of the same runner, and the PUT accepts it', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const allStageRows = db.prepare("SELECT role, position, model, runner FROM model_routes WHERE role LIKE 'stage.%'").all();
  // BH-2536 seeds more stage.* roles; the PUT round-trip below is about these six.
  const stageRows = allStageRows.filter((r) => STAGES.includes(r.role.slice('stage.'.length)));
  assert.equal(stageRows.length, 12);
  // The twin check covers EVERY stage.* seed row, so no stage seed brings a new literal.
  for (const r of allStageRows) {
    const twin = db.prepare(
      "SELECT 1 FROM model_routes WHERE role NOT LIKE 'stage.%' AND updated_by='seed' AND model=? AND runner=?"
    ).get(r.model, r.runner);
    assert.ok(twin, `${r.role}#${r.position} ${r.runner}/${r.model} has no non-stage seed twin`);
  }
  priceAll(db, stageRows.map((r) => r.model));
  for (const s of STAGES) {
    const ladder = stageRows.filter((r) => r.role === `stage.${s}`)
      .sort((a, b) => a.position - b.position).map(({ model, runner }) => ({ model, runner }));
    const w = await put(DB, `stage.${s}`, ladder, { confirm: true });
    assert.equal(w.status, 200, `stage.${s}: ${JSON.stringify(w.body)}`);
  }
});

// ─────────────────────────────────────────────────────────────── writes

test('W1: a stage.* PUT with an unknown runner is 400, names the allowed runners, and writes nothing', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceAll(db, ['claude-fable-5-1', 'gpt-6-astra']);
  const before = [count(db, 'model_routes'), count(db, 'model_route_changes')];
  const r = await put(DB, 'stage.triage', [
    { model: 'claude-fable-5-1', runner: 'claude' }, { model: 'gpt-6-astra', runner: 'bogus' },
  ]);
  assert.equal(r.status, 400);
  assert.match(r.body.error, /claude, codex, openrouter, grok, fireworks/);
  assert.deepEqual([count(db, 'model_routes'), count(db, 'model_route_changes')], before);
});

test('W2: a 3-rung stage.* PUT is 400 (agent-call reads no third rung) and writes nothing', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceAll(db, ['claude-fable-5-1', 'gpt-6-astra', 'grok-4.6']);
  const before = [count(db, 'model_routes'), count(db, 'model_route_changes')];
  const r = await put(DB, 'stage.triage', [
    { model: 'grok-4.6', runner: 'grok' },
    { model: 'gpt-6-astra', runner: 'codex' },
    { model: 'claude-fable-5-1', runner: 'claude' },
  ]);
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /at most 2 rungs/);
  assert.deepEqual([count(db, 'model_routes'), count(db, 'model_route_changes')], before);
  const still = db.prepare("SELECT runner FROM model_routes WHERE role='stage.triage' ORDER BY position").all();
  assert.deepEqual(still.map((x) => x.runner), ['claude', 'codex']);
});

test('W3: a valid 2-rung stage.* PUT is 200 and audited in model_route_changes', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceAll(db, ['grok-4.6', 'gpt-6-astra']);
  const r = await put(DB, 'stage.triage', [
    { model: 'grok-4.6', runner: 'grok' }, { model: 'gpt-6-astra', runner: 'codex' },
  ], { actor: 'hub' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const ch = db.prepare(
    "SELECT after_runner, after_model, before_runner, actor FROM model_route_changes WHERE role='stage.triage' AND position=0"
  ).all();
  assert.equal(ch.length, 1);
  assert.deepEqual({ ...ch[0] }, { after_runner: 'grok', after_model: 'grok-4.6', before_runner: 'claude', actor: 'hub' });
  const row = db.prepare("SELECT runner, updated_by FROM model_routes WHERE role='stage.triage' AND project IS NULL AND position=0").get();
  assert.deepEqual({ ...row }, { runner: 'grok', updated_by: 'hub' });
});

test('W4: the list read carries the stage.* roles', async () => {
  const DB = sqliteDB(openDb());
  const r = await call(DB, '/api/model-routes');
  assert.equal(r.status, 200);
  const roles = r.body.roles.map((x) => x.role);
  for (const s of STAGES) assert.ok(roles.includes(`stage.${s}`), `stage.${s} missing from the list`);
});

test('W5: the 2-rung cap fires on the stage. prefix only — not stagex.*, not claude.ladder, not a 2-rung stage.*', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceAll(db, ['claude-fable-5-1', 'claude-opus-5-5', 'claude-opus-5']);
  const three = [
    { model: 'claude-fable-5-1', runner: 'claude' },
    { model: 'claude-opus-5-5', runner: 'claude' },
    { model: 'claude-opus-5', runner: 'claude' },
  ];
  for (const role of ['stagex.triage', 'claude.ladder', 'build.stage.triage']) {
    const r = await put(DB, role, three, { confirm: true });
    assert.equal(r.status, 200, `${role}: ${JSON.stringify(r.body)}`);
  }
  const two = await put(DB, 'stage.preplan-files', three.slice(0, 2));
  assert.equal(two.status, 200, JSON.stringify(two.body));
  const one = await put(DB, 'stage.fix', three.slice(0, 1));
  assert.equal(one.status, 200, JSON.stringify(one.body));
});
