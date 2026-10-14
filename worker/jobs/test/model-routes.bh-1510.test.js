import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1510.0 — the model-routes CONTRACT slice, driven against THE SQL THAT
// SHIPS (worker/jobs/schema.sql), the same idiom
// test/schema-deploy-queue.bh-1026.test.js uses and for the same reason: every
// claim here is a property of the shipped statements — the seed lands byte for
// byte what the ticket's derivation table promises, the UNIQUE INDEX on
// coalesce(project,'') actually stops two hub rows from colliding, and a PUT's
// validation, upsert and audit trail are real SQL, not a regex a stub answers
// to. node:sqlite is imported at the top with no skip path: CI runs node 22.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

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
    const bound = (...binds) => bindAndRun(binds);
    // .batch() takes already-bound statement objects, as every route in this
    // worker builds them (catalog.js, model-routes.js): each carries its own
    // sql+binds, and D1's batch just runs them in order inside one transaction.
    bound._sql = sql;
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

const cols = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all();

const priceModel = (db, model) => db.prepare(
  `INSERT INTO model_prices (model, slug, prompt, completion, source, updated_at)
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-22T00:00:00Z')`
).run(model, `test/${model}`);

test('schema.sql re-applies clean (additive-only), and model_routes carries the right shape', () => {
  const db = openDb();
  db.exec(SCHEMA); // re-apply, as bin/harness-sync.sh does on every deploy
  const sql = SCHEMA.split('\n').map((l) => l.replace(/--.*$/, '')).join('\n');
  assert.equal(/\bALTER\b/i.test(sql), false, 'schema.sql must stay additive-only: no ALTER');
  assert.equal(/\bDROP\b/i.test(sql), false, 'schema.sql must stay additive-only: no DROP');

  const names = cols(db, 'model_routes').map((c) => c.name).sort();
  assert.deepEqual(names,
    ['id', 'model', 'position', 'project', 'role', 'runner', 'scope', 'updated_at', 'updated_by'],
    'model_routes must carry exactly these columns');
  for (const need of ['scope', 'role', 'position', 'model', 'runner', 'updated_at']) {
    assert.equal(cols(db, 'model_routes').find((c) => c.name === need).notnull, 1, `${need} must be NOT NULL`);
  }
  assert.equal(cols(db, 'model_routes').find((c) => c.name === 'project').notnull, 0, 'project must be nullable (NULL = hub)');

  const idx = db.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='model_routes'").all();
  const uniq = idx.find((i) => i.name === 'idx_model_routes_key');
  assert.ok(uniq, 'idx_model_routes_key must exist');
  assert.match(uniq.sql, /UNIQUE/i, 'the key index must be UNIQUE — this is what stops two hub rows colliding');
  assert.match(uniq.sql, /coalesce\(project,''\)/i, 'the index must be on coalesce(project, \'\'), not on project alone');

  const chgNames = cols(db, 'model_route_changes').map((c) => c.name).sort();
  assert.deepEqual(chgNames, [
    'actor', 'after_model', 'after_runner', 'at', 'before_model', 'before_runner',
    'id', 'position', 'project', 'reason', 'role', 'scope',
  ], 'model_route_changes must carry exactly these columns');
  db.close();
});

test('the unique index refuses two hub rows at the same (role, position) — coalesce(project, \'\') is doing its job', () => {
  const db = openDb();
  db.prepare(`INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
              VALUES ('hub', NULL, 'zz.test', 0, 'model-a', 'claude', 'op', '2026-09-22T00:00:00Z')`).run();
  assert.throws(() => db.prepare(
    `INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
     VALUES ('hub', NULL, 'zz.test', 0, 'model-b', 'claude', 'op', '2026-09-22T00:01:00Z')`
  ).run(), /UNIQUE constraint failed/, 'a second hub row at the same role+position must collide, not silently coexist');
  // A project row at the SAME role+position is a different key entirely.
  db.prepare(`INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
              VALUES ('project', 'project-3', 'zz.test', 0, 'model-c', 'claude', 'op', '2026-09-22T00:02:00Z')`).run();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM model_routes WHERE role='zz.test'").get().n, 2);
  db.close();
});

test('the seed lands TODAY\'s effective model for every role the ticket\'s derivation table names, and changes nothing on re-apply', () => {
  const db = openDb();
  // A representative sample of the seed — not every row, but enough that a
  // wrong value or a dropped row on any of them fails loudly. Each pair here
  // is exactly what the schema.sql comment cites as its source.
  const expect = {
    // BH-1908 moved these to the live hub ladders: Opus 5.5 first, the old
    // value as rung 1.
    'build.execute': [
      { position: 0, model: 'claude-opus-5-5', runner: 'claude' },
      { position: 1, model: 'claude-opus-5', runner: 'claude' },
    ],
    'build.review': [
      { position: 0, model: 'claude-opus-5-5', runner: 'claude' },
      { position: 1, model: 'claude-fable-5-1', runner: 'claude' },
    ],
    'build.qa': [
      { position: 0, model: 'claude-opus-5-5', runner: 'claude' },
      { position: 1, model: 'claude-opus-5', runner: 'claude' },
    ],
    'triage': [
      { position: 0, model: 'claude-opus-5-5', runner: 'claude' },
      { position: 1, model: 'claude-fable-5-1', runner: 'claude' },
    ],
    'triage.light': [{ position: 0, model: 'claude-sonnet-5', runner: 'claude' }],
    'codex.default': [{ position: 0, model: 'gpt-6-astra', runner: 'codex' }],
    'grok.default': [
      { position: 0, model: 'grok-4.7', runner: 'grok' },
      { position: 1, model: 'grok-4.6', runner: 'grok' },
    ],
    'fireworks.default': [{ position: 0, model: 'accounts/fireworks/models/kimi-k2p7-code', runner: 'fireworks' }],
    // BH-1510.2 added rung 1 (the claude fallback the floor branch passes to
    // agent-call); rung 0 is the row #1510.0 seeded, unchanged.
    'housekeeping.floor': [
      { position: 0, model: 'accounts/fireworks/models/deepseek-v4-flash-0731', runner: 'fireworks' },
      { position: 1, model: 'claude-sonnet-5', runner: 'claude' },
    ],
    // orchestrate is the one #1510.0 role seeded with both rungs in one
    // statement (bin/orchestrate.sh ORC_MODEL / ORC_FALLBACK), at the live ladder.
    'orchestrate': [
      { position: 0, model: 'claude-opus-5-5', runner: 'claude' },
      { position: 1, model: 'claude-fable-5-1', runner: 'claude' },
    ],
  };
  for (const [role, rungs] of Object.entries(expect)) {
    const rows = db.prepare('SELECT position, model, runner, project FROM model_routes WHERE role=? ORDER BY position').all(role);
    assert.deepEqual(rows.map((r) => ({ position: r.position, model: r.model, runner: r.runner })), rungs,
      `seed for role ${role} does not match the derivation table`);
    assert.ok(rows.every((r) => r.project === null), `role ${role} must seed at hub scope (project NULL)`);
  }
  // build.review.t0 IS a role on main (REVIEW_MODEL_T0; the #1515 review's
  // finding 1) and #1510.1 seeds it — see the #1510.1 seed test below.

  // Re-apply must not touch a row an operator has since edited — same
  // INSERT OR IGNORE contract as settings/concurrency_rules.
  // (claude-sonnet-5, not the seed's own claude-opus-5-5, so the assertion can fail.)
  db.prepare("UPDATE model_routes SET model='claude-sonnet-5', updated_by='hub' WHERE role='build.review' AND position=0 AND project IS NULL").run();
  db.exec(SCHEMA);
  const after = db.prepare("SELECT model, updated_by FROM model_routes WHERE role='build.review' AND position=0 AND project IS NULL").get();
  assert.equal(after.model, 'claude-sonnet-5', 're-applying schema.sql must not undo an operator edit');
  assert.equal(after.updated_by, 'hub');
  db.close();
});

// BH-1510.1: the build lanes' roles #1510.0 did not seed. They land at what
// main runs after #1523 (new rows, nothing to move), and ONLY for a role with
// no hub row at all — so a re-apply never puts back a rung an operator cut.
test('the #1510.1 seed lands the build roles at main\'s post-#1523 ladders, and never re-adds a rung an operator removed', () => {
  const db = openDb();
  const ladder = (role) => db.prepare('SELECT position, model, runner FROM model_routes WHERE role=? AND project IS NULL ORDER BY position')
    .all(role).map((r) => `${r.position}:${r.model}:${r.runner}`);
  assert.deepEqual(ladder('build.review.t0'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude']);
  assert.deepEqual(ladder('build.fix'), ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude']);
  assert.deepEqual(ladder('claude.ladder'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude', '2:claude-opus-5:claude']);
  assert.deepEqual(ladder('openrouter.floor'), ['0:deepseek/deepseek-v4-flash:openrouter']);
  assert.deepEqual(ladder('fireworks.floor'), ['0:accounts/fireworks/models/deepseek-v4-flash-0731:fireworks']);
  // An operator cuts claude.ladder to two rungs; the next deploy re-applies the file.
  db.prepare("DELETE FROM model_routes WHERE role='claude.ladder' AND position=2").run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder('claude.ladder'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
    're-applying schema.sql must not put back a rung an operator removed');
  // ...and an operator's model edit on a seeded rung survives it too.
  db.prepare("UPDATE model_routes SET model='claude-sonnet-5', updated_by='op' WHERE role='build.fix' AND position=0 AND project IS NULL").run();
  db.exec(SCHEMA);
  assert.equal(ladder('build.fix')[0], '0:claude-sonnet-5:claude');
  db.close();
});

test('GET /api/model-routes/:role resolves the hub ladder when no project overrides it', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const r = await call(DB, '/api/model-routes/build.execute');
  assert.equal(r.status, 200);
  assert.equal(r.body.source, 'hub');
  assert.equal(r.body.project, null);
  assert.deepEqual(r.body.ladder, [
    { position: 0, model: 'claude-opus-5-5', runner: 'claude' },
    { position: 1, model: 'claude-opus-5', runner: 'claude' },
  ]);
  db.close();
});

test('GET /api/model-routes/:role answers 200 with an empty ladder for an unknown role — not a 404', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const r = await call(DB, '/api/model-routes/nobody.knows.this');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.ladder, []);
  assert.equal(r.body.source, 'none');
  db.close();
});

test('GET /api/model-routes/:role refuses a malformed role before touching the database', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  for (const bad of ['Build.Execute', 'build execute', '-leading-dash', 'x'.repeat(129)]) {
    const r = await call(DB, `/api/model-routes/${encodeURIComponent(bad)}`);
    assert.equal(r.status, 400, `accepted role ${JSON.stringify(bad)}`);
  }
  db.close();
});

test('PUT /api/model-routes validates role, runner and ladder shape before writing anything', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'priced-model');
  const cases = [
    { role: 'Bad Role', ladder: [{ model: 'priced-model', runner: 'claude' }] },
    { role: 'ok.role', ladder: [] },
    { role: 'ok.role', ladder: [{ model: 'priced-model', runner: 'not-a-runner' }] },
    { role: 'ok.role', ladder: [{ model: '', runner: 'claude' }] },
    { role: 'ok.role' }, // ladder missing entirely
    { role: 'ok.role', project: 'has spaces', ladder: [{ model: 'priced-model', runner: 'claude' }] },
  ];
  const before = db.prepare('SELECT COUNT(*) n FROM model_routes').get().n; // the seed's own rows
  for (const body of cases) {
    const r = await call(DB, '/api/model-routes', { method: 'PUT', body });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(body)}`);
  }
  assert.equal(db.prepare('SELECT COUNT(*) n FROM model_routes').get().n, before, 'a refused write must not touch the table');
  db.close();
});

test('PUT /api/model-routes refuses a model that carries no price row — the control-the-pathway premise', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: { role: 'ok.role', ladder: [{ model: 'never-priced-model', runner: 'claude' }] },
  });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /never-priced-model/);
  db.close();
});

test('PUT /api/model-routes writes the hub ladder and one audit row per changed rung', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'model-a');
  priceModel(db, 'model-b');
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: {
      role: 'new.role',
      ladder: [{ model: 'model-a', runner: 'claude' }, { model: 'model-b', runner: 'grok' }],
      actor: 'operator', reason: 'testing',
    },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.route.scope, 'hub');
  assert.equal(r.body.route.project, null);
  assert.deepEqual(r.body.route.ladder, [
    { position: 0, model: 'model-a', runner: 'claude' },
    { position: 1, model: 'model-b', runner: 'grok' },
  ]);
  const changes = db.prepare("SELECT * FROM model_route_changes WHERE role='new.role' ORDER BY position").all();
  assert.equal(changes.length, 2, 'one audit row per rung written');
  assert.equal(changes[0].before_model, null, 'a new rung has no before_model');
  assert.equal(changes[0].after_model, 'model-a');
  assert.equal(changes[0].actor, 'operator');
  assert.equal(changes[0].reason, 'testing');
  db.close();
});

test('re-PUTting the identical ladder writes no new audit rows — an unchanged rung is not a decision', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'model-a');
  const body = { role: 'idem.role', ladder: [{ model: 'model-a', runner: 'claude' }] };
  await call(DB, '/api/model-routes', { method: 'PUT', body });
  const r2 = await call(DB, '/api/model-routes', { method: 'PUT', body });
  assert.equal(r2.status, 200);
  const changes = db.prepare("SELECT COUNT(*) n FROM model_route_changes WHERE role='idem.role'").get().n;
  assert.equal(changes, 1, 'the second, identical PUT must not write a second audit row');
  db.close();
});

test('a shorter ladder DELETEs the trailing rungs, each with its own audit row (after_* NULL)', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'model-a'); priceModel(db, 'model-b');
  await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: { role: 'shrink.role', ladder: [{ model: 'model-a', runner: 'claude' }, { model: 'model-b', runner: 'grok' }] },
  });
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: { role: 'shrink.role', ladder: [{ model: 'model-a', runner: 'claude' }] },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.route.ladder.length, 1);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM model_routes WHERE role='shrink.role'").get().n, 1);
  const dropped = db.prepare("SELECT * FROM model_route_changes WHERE role='shrink.role' AND position=1 ORDER BY id DESC LIMIT 1").get();
  assert.equal(dropped.before_model, 'model-b');
  assert.equal(dropped.after_model, null, 'a dropped rung audits after_model as NULL, not as the last value it had');
  db.close();
});

test('a project PUT overrides the WHOLE ladder for that role, never merges rung-by-rung with the hub', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'model-hub-0'); priceModel(db, 'model-hub-1'); priceModel(db, 'model-proj-0');
  await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: { role: 'ovr.role', ladder: [{ model: 'model-hub-0', runner: 'claude' }, { model: 'model-hub-1', runner: 'grok' }] },
  });
  await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: { role: 'ovr.role', project: 'project-3', ladder: [{ model: 'model-proj-0', runner: 'codex' }] },
  });

  const hub = await call(DB, '/api/model-routes/ovr.role');
  assert.equal(hub.body.source, 'hub');
  assert.equal(hub.body.ladder.length, 2, 'a project write must never touch the hub ladder');

  const proj = await call(DB, '/api/model-routes/ovr.role?project=project-3');
  assert.equal(proj.body.source, 'project');
  assert.deepEqual(proj.body.ladder, [{ position: 0, model: 'model-proj-0', runner: 'codex' }],
    'the project ladder is its OWN one rung, never the hub\'s rung 1 tacked on');

  const other = await call(DB, '/api/model-routes/ovr.role?project=project-5');
  assert.equal(other.body.source, 'hub', 'a project with no override falls back to the hub ladder');
  assert.equal(other.body.ladder.length, 2);
  db.close();
});

test('GET /api/model-routes lists every role with a hub row, resolved', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const r = await call(DB, '/api/model-routes');
  assert.equal(r.status, 200);
  const byRole = Object.fromEntries(r.body.roles.map((x) => [x.role, x]));
  assert.ok(byRole['build.execute'], 'build.execute must be listed');
  assert.equal(byRole['build.execute'].source, 'hub');
  assert.ok(byRole['orchestrate'], 'orchestrate must be listed');
  assert.equal(byRole['orchestrate'].ladder.length, 2);
  db.close();
});

test('model_routes self-creates on a database the deploy reached before schema.sql applied (the pr_state_events belt)', async () => {
  // `wrangler deploy` and harness-sync.sh's own schema apply are two separate
  // steps; a route reached in the gap must not 500 or leave the caller with no
  // body. ensureTable (CREATED_TABLES.model_routes) is the belt — same reason
  // pr_state_events carries one (BH-1025.0).
  const db = new DatabaseSync(':memory:'); // NOTHING created, not even other tables
  const DB = sqliteDB(db);
  const r = await call(DB, '/api/model-routes/build.execute');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.ladder, [], 'a self-created, empty table has no rows yet — that is a real answer, not an outage');
  assert.equal(r.body.source, 'none');
  db.close();
});
