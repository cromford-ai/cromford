import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1928 — two follow-ups of #1917 (BH-1572) on the hub remove route, and
// one on reset:
//   R2. `remove` on a role with no hub rows used to write no audit row, so the
//       seeds' "skip a role with hub audit history" guard had nothing to read
//       and the next deploy re-seeded the role. It now writes one TOMBSTONE
//       row (position 0, every before/after NULL) so the removal sticks.
//   R4. remove and reset read the rungs they audit INSIDE the batch that
//       deletes them. Before, the read ran outside the batch, so a write that
//       landed in between was deleted but audited with the stale value.
// Driven through worker.fetch against the schema.sql that ships.
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

const hubLadder = (db, role) => db.prepare(
  'SELECT position, model, runner FROM model_routes WHERE role=? AND project IS NULL ORDER BY position'
).all(role).map((r) => `${r.position}:${r.model}:${r.runner}`);

const hubAudit = (db, role) => db.prepare(
  'SELECT * FROM model_route_changes WHERE role=? AND project IS NULL ORDER BY id'
).all(role);

// The R4 cases own their ladder. They used to read build.qa's LIVE seed, so a
// seed bump on main (build.qa gained a second rung) turned them red: R4a's
// precondition failed and R4a-2/R4c collided with the seeded position 1. This
// lays down a known one-rung hub ladder and clears the role's audit, so what the
// cases assert is the route's behaviour, not today's schema.sql.
const fixtureLadder = (db, role, rungs) => {
  db.prepare('DELETE FROM model_routes WHERE role=? AND project IS NULL').run(role);
  db.prepare('DELETE FROM model_route_changes WHERE role=? AND project IS NULL').run(role);
  rungs.forEach(([model, runner], position) => db.prepare(
    'INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) ' +
    "VALUES ('hub', NULL, ?, ?, ?, ?, 'fixture', '2026-09-24T00:00:00Z')"
  ).run(role, position, model, runner));
};

// A DB whose next batch first runs `sql` — a write landing in the window
// between whatever the handler read before its batch and the batch itself.
function racing(DB, db, sql) {
  let armed = true;
  return {
    ...DB,
    batch: async (xs) => {
      if (armed) { armed = false; db.exec(sql); }
      return DB.batch(xs);
    },
  };
}

// ───────────────────────────────────────────────────── R2: the tombstone

test('R2a: remove on a role with no hub rows writes one tombstone audit row (position 0, before/after NULL)', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  // A raw DELETE, no audit: the state a role is in when its rungs went some
  // other way than the audited route.
  db.prepare("DELETE FROM model_routes WHERE role='fireworks.floor' AND project IS NULL").run();
  assert.equal(hubAudit(db, 'fireworks.floor').length, 0);

  const r = await call(DB, '/api/model-routes/remove', {
    method: 'POST', body: { role: 'fireworks.floor', actor: 'operator', reason: 'floor off' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 0);
  assert.equal(r.body.tombstone, true);

  const audit = hubAudit(db, 'fireworks.floor');
  assert.equal(audit.length, 1, 'exactly one tombstone row');
  const row = audit[0];
  assert.equal(row.scope, 'hub');
  assert.equal(row.position, 0);
  assert.equal(row.before_model, null);
  assert.equal(row.before_runner, null);
  assert.equal(row.after_model, null);
  assert.equal(row.after_runner, null);
  assert.equal(row.actor, 'operator');
  assert.equal(row.reason, 'floor off');
  db.close();
});

test('R2b: after an empty remove, re-applying schema.sql (the next deploy) does not re-seed the role', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  db.prepare("DELETE FROM model_routes WHERE role='fireworks.floor' AND project IS NULL").run();
  const r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'fireworks.floor', actor: 'op' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  assert.deepEqual(hubLadder(db, 'fireworks.floor'), [], 'the removal sticks across a redeploy');
  db.close();
});

test('R2c: remove on a role that has rungs audits each rung and writes NO extra tombstone', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const before = hubLadder(db, 'orchestrate');
  assert.ok(before.length >= 2, `orchestrate is seeded with a multi-rung ladder: ${before}`);
  const r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'orchestrate', actor: 'op' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, before.length);
  assert.equal(r.body.tombstone, false);
  const audit = hubAudit(db, 'orchestrate');
  assert.equal(audit.length, before.length, 'one row per removed rung, nothing more');
  assert.deepEqual(audit.map((a) => `${a.position}:${a.before_model}:${a.before_runner}`), before);
  assert.ok(audit.every((a) => a.after_model === null && a.after_runner === null));
  assert.ok(audit.every((a) => a.before_model !== null), 'no both-null tombstone row among them');
  db.close();
});

// ─────────────────────────────────────── R4: read and delete in one batch

test('R4a: remove audits what its batch deleted, not what it read before the batch', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  fixtureLadder(db, 'build.qa', [['claude-opus-5', 'claude']]);
  assert.deepEqual(hubLadder(db, 'build.qa'), ['0:claude-opus-5:claude']);
  const DB = racing(base, db,
    "UPDATE model_routes SET model='claude-sonnet-5' WHERE role='build.qa' AND project IS NULL");
  const r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.qa', actor: 'op' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 1);
  assert.deepEqual(hubLadder(db, 'build.qa'), []);
  const audit = hubAudit(db, 'build.qa');
  assert.equal(audit.length, 1);
  assert.equal(audit[0].before_model, 'claude-sonnet-5', 'the audit names the rung that was actually deleted');
  db.close();
});

test('R4a-2: a rung added inside the window is deleted AND audited, and `removed` counts it', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  fixtureLadder(db, 'build.qa', [['claude-opus-5', 'claude']]);
  const DB = racing(base, db,
    "INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) " +
    "VALUES ('hub', NULL, 'build.qa', 1, 'claude-sonnet-5', 'claude', 'op', '2026-09-24T00:00:00Z')");
  const r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.qa', actor: 'op' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 2, 'removed is what the DELETE measured');
  assert.equal(r.body.tombstone, false);
  assert.deepEqual(hubAudit(db, 'build.qa').map((a) => `${a.position}:${a.before_model}`),
    ['0:claude-opus-5', '1:claude-sonnet-5']);
  db.close();
});

test('R4b: reset audits what its batch deleted, not what it read before the batch', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  fixtureLadder(db, 'build.qa', [['claude-opus-5', 'claude']]);
  db.prepare(
    "INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) " +
    "VALUES ('project', 'project-4', 'build.qa', 0, 'claude-opus-5', 'claude', 'op', '2026-09-24T00:00:00Z')"
  ).run();
  const DB = racing(base, db,
    "UPDATE model_routes SET model='claude-sonnet-5' WHERE role='build.qa' AND project='project-4'");
  const r = await call(DB, '/api/model-routes/reset', {
    method: 'POST', body: { role: 'build.qa', project: 'project-4', actor: 'op' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 1);
  assert.equal(r.body.route.source, 'hub');
  assert.equal(r.body.tombstone, undefined, 'reset has no seed to hold off, so no tombstone');
  const audit = db.prepare(
    "SELECT * FROM model_route_changes WHERE role='build.qa' AND project='project-4' ORDER BY id"
  ).all();
  assert.equal(audit.length, 1);
  assert.equal(audit[0].scope, 'project');
  assert.equal(audit[0].before_model, 'claude-sonnet-5', 'the audit names the rung that was actually deleted');
  assert.equal(audit[0].after_model, null);
  db.close();
});

test('R4c: a stale expected_version still refuses 409 and writes neither the delete, the audit nor a tombstone', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  fixtureLadder(db, 'build.qa', [['claude-opus-5', 'claude']]);
  const v = (await call(base, '/api/model-routes/build.qa')).body.scope_version;
  // The guard trips INSIDE the batch: a write lands after the up-front check.
  const DB = racing(base, db,
    "INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) " +
    "VALUES ('hub', NULL, 'build.qa', 1, 'claude-sonnet-5', 'claude', 'op', '2026-09-24T00:00:00Z')");
  const r = await call(DB, '/api/model-routes/remove', { method: 'POST', body: { role: 'build.qa', expected_version: v } });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.deepEqual(hubLadder(db, 'build.qa'), ['0:claude-opus-5:claude', '1:claude-sonnet-5:claude']);
  assert.equal(hubAudit(db, 'build.qa').length, 0);
  db.close();
});
