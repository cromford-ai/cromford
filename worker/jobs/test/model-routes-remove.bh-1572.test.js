import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1572 (F5 of #1569's round-2 review) — removing a whole hub role is
// DURABLE. Before this, the PUT refused an empty ladder and reset was
// project-only, so a hub role could only be taken away by a raw DELETE, and the
// next deploy re-applied schema.sql and put the seeded rungs straight back:
// there was no way to switch a floor off that survived a deploy.
//   1. POST /api/model-routes/remove deletes every hub rung of a role in one
//      batch and audits each one (after_* NULL). Those audit rows are the
//      tombstone.
//   2. Every model_routes seed in schema.sql skips a role with any hub audit
//      history — the #1510.1 and BH-1766 per-role guards, and the #1510.0 and
//      #1510.2 per-rung VALUES seeds, which until now re-added any rung an
//      operator had cut, on every deploy.
// Driven against the SQL that ships (schema.sql), like the #1510.x suites.
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
    return { ...bindAndRun([]), bind: (...binds) => { const s = bindAndRun(binds); s._sql = sql; s._binds = binds; return s; } };
  };
  return {
    prepare,
    batch: async (xs) => {
      // One transaction, rolled back on any error — D1's batch contract, which
      // the version guard inside the batch depends on.
      db.exec('BEGIN');
      try {
        const out = xs.map((x) => {
          const r = db.prepare(x._sql).run(...(x._binds || []));
          return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
        });
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
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

// A PUT needs a price row for every model it names (the control-the-pathway
// premise); schema.sql seeds no prices, so each suite adds the ones it writes.
const priceModel = (db, model) => db.prepare(
  `INSERT OR IGNORE INTO model_prices (model, slug, prompt, completion, source, updated_at)
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-22T00:00:00Z')`
).run(model, `test/${model}`);

const hubLadder = (db, role) => db.prepare(
  'SELECT position, model, runner FROM model_routes WHERE role=? AND project IS NULL ORDER BY position'
).all(role).map((r) => `${r.position}:${r.model}:${r.runner}`);

test('POST /api/model-routes/remove takes every hub rung away, audits each one, and the role resolves to no route', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  assert.deepEqual(hubLadder(db, 'openrouter.floor'), ['0:deepseek/deepseek-v4-flash:openrouter']);

  const r = await call(DB, '/api/model-routes/remove', {
    method: 'POST', body: { role: 'openrouter.floor', actor: 'operator', reason: 'floor off' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 1);
  assert.deepEqual(hubLadder(db, 'openrouter.floor'), []);

  const got = await call(DB, '/api/model-routes/openrouter.floor');
  assert.equal(got.body.source, 'none');
  assert.deepEqual(got.body.ladder, []);

  const audit = db.prepare(
    "SELECT * FROM model_route_changes WHERE role='openrouter.floor' AND project IS NULL"
  ).all();
  assert.equal(audit.length, 1, 'one audit row per removed rung');
  assert.equal(audit[0].scope, 'hub');
  assert.equal(audit[0].before_model, 'deepseek/deepseek-v4-flash');
  assert.equal(audit[0].after_model, null);
  assert.equal(audit[0].actor, 'operator');
  assert.equal(audit[0].reason, 'floor off');
  db.close();
});

test('a removed role stays removed: re-applying schema.sql never re-seeds it, for every seed shape', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  // One role from each seed block: #1510.0 VALUES, #1510.1 guarded, #1510.2
  // VALUES, BH-1766 guarded (stage.*).
  const roles = ['fireworks.default', 'fireworks.floor', 'openrouter.default', 'stage.triage'];
  for (const role of roles) {
    assert.ok(hubLadder(db, role).length > 0, `${role} is seeded`);
    const r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role, actor: 'op' } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
  }
  db.exec(SCHEMA); // the next deploy
  for (const role of roles) {
    assert.deepEqual(hubLadder(db, role), [], `${role} must stay removed across a re-apply`);
  }
  // ...and nothing else moved: a role nobody touched is still exactly as seeded.
  assert.deepEqual(hubLadder(db, 'grok.default'), ['0:grok-4.7:grok', '1:grok-4.6:grok']);
  db.close();
});

test('a PUT that shortened a #1510.0 ladder is not undone by the next deploy (the per-rung VALUES seed used to re-add the rung)', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  assert.deepEqual(hubLadder(db, 'orchestrate'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude']);
  priceModel(db, 'claude-opus-5-5');
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'orchestrate', ladder: [{ model: 'claude-opus-5-5', runner: 'claude' }], actor: 'op' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  assert.deepEqual(hubLadder(db, 'orchestrate'), ['0:claude-opus-5-5:claude'],
    're-applying schema.sql must not put back a rung an operator cut');
  db.close();
});

test('a role nobody has decided is still seeded on a fresh database, and a raw DELETE (no audit) is still healed by the seed', () => {
  const db = openDb();
  db.prepare("DELETE FROM model_routes WHERE role='codex.default' AND project IS NULL").run();
  db.exec(SCHEMA);
  assert.deepEqual(hubLadder(db, 'codex.default'), ['0:gpt-6-astra:codex'],
    'with no audit row there is no tombstone: the seed restores the role, as before');
  db.close();
});

test('a removed role comes back with a PUT', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'fireworks.floor' } });
  priceModel(db, 'accounts/fireworks/models/kimi-k2p7-code');
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'fireworks.floor', ladder: [{ model: 'accounts/fireworks/models/kimi-k2p7-code', runner: 'fireworks' }] },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  assert.deepEqual(hubLadder(db, 'fireworks.floor'), ['0:accounts/fireworks/models/kimi-k2p7-code:fireworks']);
  db.close();
});

test('POST /api/model-routes/remove is hub-only, validates the role, and a role with no hub rows writes a tombstone (BH-1928)', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  let r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.plan', project: 'project-4' } });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /reset/);
  r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'Bad Role' } });
  assert.equal(r.status, 400);
  r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.plan', expected_hub_version: 3 } });
  assert.equal(r.status, 400);
  assert.deepEqual(hubLadder(db, 'build.plan'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'], 'a refused remove writes nothing');
  r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'nobody.has.this' } });
  assert.equal(r.status, 200);
  assert.equal(r.body.removed, 0);
  // BH-1928: was "no audit row". An empty remove now writes ONE tombstone row,
  // so a seed for the role (should one ever exist) skips it on the next deploy.
  assert.equal(r.body.tombstone, true);
  assert.equal(db.prepare(
    "SELECT count(*) AS n FROM model_route_changes WHERE role='nobody.has.this' AND project IS NULL AND position=0 AND before_model IS NULL AND after_model IS NULL"
  ).get().n, 1);
  assert.equal(db.prepare("SELECT count(*) AS n FROM model_route_changes WHERE role='nobody.has.this'").get().n, 1);
  db.close();
});

test('POST /api/model-routes/remove with a stale expected_version is refused 409 and removes nothing', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const v = (await call(DB, '/api/model-routes/build.qa')).body.scope_version;
  assert.ok(v > 0);
  let r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.qa', expected_version: v + 1 } });
  assert.equal(r.status, 409);
  assert.deepEqual(hubLadder(db, 'build.qa'), ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude']);
  r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.qa', expected_version: v } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(hubLadder(db, 'build.qa'), []);
  db.close();
});

test('a project override survives a hub remove, and still resolves', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'claude-sonnet-5');
  const put = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'build.plan', project: 'project-4', ladder: [{ model: 'claude-sonnet-5', runner: 'claude' }] },
  });
  assert.equal(put.status, 200, JSON.stringify(put.body));
  await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.plan' } });
  const got = await call(DB, '/api/model-routes/build.plan?project=project-4');
  assert.equal(got.body.source, 'project');
  assert.deepEqual(got.body.ladder.map((x) => x.model), ['claude-sonnet-5']);
  assert.equal((await call(DB, '/api/model-routes/build.plan')).body.source, 'none');
  db.close();
});
