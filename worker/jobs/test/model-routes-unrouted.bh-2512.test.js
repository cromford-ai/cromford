import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2512 — GET /api/model-routes?unrouted_since=<ts> lists every stage the
// cost ledger saw since <ts> that has no stage.<x> route agent-call would use
// (no rung-0 row at the project OR the hub), i.e. every stage that runs on
// RUNNER_<STAGE> from env, else claude. Without the param the response is
// exactly what it was (bin/lib/model-route.sh and the gap-check lane read it).
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

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
// One fixed anchor: the route filters only on the unrouted_since it is handed and
// never reads the clock, so every fixture derives from this instant.
const NOW = Date.parse('2026-09-26T00:00:00Z');
const SINCE = iso(NOW - 7 * 86400000);
const RECENT = iso(NOW - 3600000);
const OLD = iso(NOW - 9 * 86400000);

let seq = 0;
const cost = (db, { stage, project = 'p1', runner = 'claude', ts = RECENT }) => db.prepare(
  `INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, inserted_at)
   VALUES ('b1', ?, ?, ?, ?, ?, ?, '2026-09-26T00:00:00Z')`
).run(`h${++seq}`, seq, ts, project, stage, runner);

const route = (db, role, position, project = null) => db.prepare(
  `INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
   VALUES (?, ?, ?, ?, 'test-model-a', 'claude', 'test', '2026-09-26T00:00:00Z')`
).run(project ? 'project' : 'hub', project, role, position);

const priceModel = (db, model) => db.prepare(
  `INSERT OR IGNORE INTO model_prices (model, slug, prompt, completion, source, updated_at)
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-26T00:00:00Z')`
).run(model, `test/${model}`);

const unrouted = async (DB, project) => {
  const q = new URLSearchParams({ unrouted_since: SINCE });
  if (project) q.set('project', project);
  const r = await call(DB, `/api/model-routes?${q}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
};
const stagesOf = (body) => body.unrouted_stages.map((s) => s.stage);

test('W1: an unrouted stage appears, and adding a route removes it (the ticket\'s test)', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  cost(db, { stage: 'foo', runner: 'codex' });
  let body = await unrouted(DB);
  const foo = body.unrouted_stages.find((s) => s.stage === 'foo');
  assert.ok(foo, `foo listed: ${JSON.stringify(body.unrouted_stages)}`);
  assert.equal(foo.role, 'stage.foo');
  assert.deepEqual(foo.projects, ['p1']);
  assert.equal(foo.calls, 1);
  assert.equal(foo.last_seen, RECENT);
  assert.deepEqual(foo.runners, ['codex']);
  assert.equal(body.unrouted_since, SINCE);
  assert.equal(body.unrouted_truncated, false);

  priceModel(db, 'test-model-a');
  const put = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'stage.foo', ladder: [{ model: 'test-model-a', runner: 'claude' }], actor: 'op' },
  });
  assert.equal(put.status, 200, JSON.stringify(put.body));
  body = await unrouted(DB);
  assert.ok(!stagesOf(body).includes('foo'), 'a routed stage is no longer listed');
  db.close();
});

test('W2: one stage run by two projects is one entry, calls summed, both projects named', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  cost(db, { stage: 'foo', project: 'p1' });
  cost(db, { stage: 'foo', project: 'p1' });
  cost(db, { stage: 'foo', project: 'p2', runner: 'codex' });
  const body = await unrouted(DB);
  const foo = body.unrouted_stages.filter((s) => s.stage === 'foo');
  assert.equal(foo.length, 1);
  assert.deepEqual(foo[0].projects, ['p1', 'p2']);
  assert.equal(foo[0].calls, 3);
  assert.deepEqual(foo[0].runners, ['claude', 'codex']);
  db.close();
});

test('W3: a stage with a hub rung-0 row is not listed', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  route(db, 'stage.bar', 0);
  cost(db, { stage: 'bar' });
  cost(db, { stage: 'foo' });
  const body = await unrouted(DB);
  assert.ok(!stagesOf(body).includes('bar'));
  assert.ok(stagesOf(body).includes('foo'));
  db.close();
});

test('W4: a project override routes only that project; the project tab filters by project', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  route(db, 'stage.baz', 0, 'p1');
  cost(db, { stage: 'baz', project: 'p1' });
  cost(db, { stage: 'baz', project: 'p2' });
  const hub = await unrouted(DB);
  const baz = hub.unrouted_stages.find((s) => s.stage === 'baz');
  assert.ok(baz);
  assert.deepEqual(baz.projects, ['p2']);
  assert.equal(baz.calls, 1);

  const p1 = await unrouted(DB, 'p1');
  assert.ok(!stagesOf(p1).includes('baz'), 'p1 is routed by its own override');
  const p2 = await unrouted(DB, 'p2');
  assert.deepEqual(p2.unrouted_stages.find((s) => s.stage === 'baz').projects, ['p2']);
  db.close();
});

test('W5: a cost row older than unrouted_since is not listed', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  cost(db, { stage: 'oldie', ts: OLD });
  const body = await unrouted(DB);
  assert.ok(!stagesOf(body).includes('oldie'));
  db.close();
});

test('W6: NULL and empty stages are never listed; EXECUTE is hidden by the seeded hub stage.execute', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  cost(db, { stage: null });
  cost(db, { stage: '' });
  cost(db, { stage: 'EXECUTE' });
  cost(db, { stage: 'Foo' });
  const body = await unrouted(DB);
  assert.deepEqual(stagesOf(body), ['foo'], 'only the lowercased unrouted stage');
  assert.equal(body.unrouted_stages[0].role, 'stage.foo');
  db.close();
});

test('W7: without the param the response carries no unrouted key at all', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  cost(db, { stage: 'foo' });
  const r = await call(DB, '/api/model-routes');
  assert.equal(r.status, 200);
  for (const k of ['unrouted_stages', 'unrouted_since', 'unrouted_truncated', 'unrouted_error']) {
    assert.ok(!(k in r.body), `${k} absent without the param`);
  }
  assert.ok(Array.isArray(r.body.roles));
  db.close();
});

test('W8: a malformed unrouted_since is a 400; a gapped-only stage (rungs past 0) is still unrouted', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  for (const bad of ['yesterday', '2026-09-19', '2026-09-19T00:00:00.000Z', '']) {
    const r = await call(DB, `/api/model-routes?unrouted_since=${encodeURIComponent(bad)}`);
    assert.equal(r.status, 400, `${bad}: ${JSON.stringify(r.body)}`);
  }
  route(db, 'stage.gappy', 1);
  cost(db, { stage: 'gappy' });
  const body = await unrouted(DB);
  assert.ok(stagesOf(body).includes('gappy'), 'agent-call ignores a ladder with no rung 0');
  db.close();
});

test('W9: a stage the role table cannot hold is listed with role null; a failed ledger read keeps the routes', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  cost(db, { stage: 'gf-ideate/ops' });
  const body = await unrouted(DB);
  const odd = body.unrouted_stages.find((s) => s.stage === 'gf-ideate/ops');
  assert.ok(odd);
  assert.equal(odd.role, null);

  db.exec('DROP TABLE cost_rows');
  const r = await call(DB, `/api/model-routes?unrouted_since=${SINCE}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.unrouted_stages, null);
  assert.match(r.body.unrouted_error, /cost_rows/);
  assert.ok(r.body.roles.length > 0, 'the routes still render');
  db.close();
});

test('W10: more than 500 stage/project pairs is flagged truncated, never silently cut', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  db.exec('BEGIN');
  for (let i = 0; i < 502; i++) cost(db, { stage: `s${String(i).padStart(3, '0')}` });
  db.exec('COMMIT');
  const body = await unrouted(DB);
  assert.equal(body.unrouted_truncated, true);
  assert.equal(body.unrouted_stages.length, 500);
  db.close();
});
