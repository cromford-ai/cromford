import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1510.3 — the three things the console Models screen needs from the worker
// that #1510.0's contract did not carry:
//   1. the audit trail as a READ (GET /api/model-route-changes), so a role's
//      history is a table on screen and not a D1 console query;
//   2. "reset this project's override to the hub default" as ONE audited write
//      (POST /api/model-routes/reset) — the PUT cannot express it, because a
//      PUT refuses an empty ladder on purpose;
//   3. provenance on the list read (updated_by / updated_at per rung, and the
//      runner list) so the screen can say which rungs are still the seed's
//      value — the rows #1507 left behind on claude-opus-5 / claude-fable-5-1.
// Driven against the SQL that ships (schema.sql), like the #1510.0 suite.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// Each .bind() returns its OWN statement: model-routes.js prepares a statement
// once and binds it once per rung, and a shim that shared one bind slot would
// batch N copies of the last rung.
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
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-22T00:00:00Z')`
).run(model, `test/${model}`);

const seedHub = async (DB, db, role, models) => {
  for (const m of models) priceModel(db, m);
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role, ladder: models.map((model) => ({ model, runner: 'claude' })), actor: 'op-hub', reason: 'hub set' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
};

// ───────────────────────────────────────────────────────── history read

test('GET /api/model-route-changes returns a role\'s audit trail, newest first, every field the screen shows', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'hist.role', ['m-a']);
  priceModel(db, 'm-b');
  await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'hist.role', ladder: [{ model: 'm-b', runner: 'codex' }], actor: 'op-2', reason: 'swap' },
  });

  const r = await call(DB, '/api/model-route-changes?role=hist.role');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.role, 'hist.role');
  assert.equal(r.body.changes.length, 2);
  const [newest, oldest] = r.body.changes;
  assert.ok(newest.id > oldest.id, 'newest first');
  for (const k of ['id', 'scope', 'project', 'role', 'position', 'before_model', 'before_runner',
                   'after_model', 'after_runner', 'actor', 'reason', 'at']) {
    assert.ok(k in newest, `a change row carries ${k}`);
  }
  assert.equal(newest.before_model, 'm-a');
  assert.equal(newest.after_model, 'm-b');
  assert.equal(newest.after_runner, 'codex');
  assert.equal(newest.actor, 'op-2');
  assert.equal(newest.reason, 'swap');
  assert.equal(oldest.before_model, null, 'the first write ADDED the rung');
  assert.equal(r.body.truncated, false);
  db.close();
});

test('GET /api/model-route-changes?project= returns that project\'s changes AND the hub\'s — both shape what the project runs', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'mix.role', ['m-hub']);
  priceModel(db, 'm-p1');
  priceModel(db, 'm-p2');
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'mix.role', project: 'project-4', ladder: [{ model: 'm-p1', runner: 'claude' }] } });
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'mix.role', project: 'project-3', ladder: [{ model: 'm-p2', runner: 'claude' }] } });

  const scoped = await call(DB, '/api/model-route-changes?role=mix.role&project=project-4');
  assert.equal(scoped.status, 200);
  const projects = scoped.body.changes.map((c) => c.project);
  assert.ok(projects.includes(null), 'the hub change is part of this project\'s story');
  assert.ok(projects.includes('project-4'));
  assert.equal(projects.includes('project-3'), false, 'another project\'s override is not');

  const all = await call(DB, '/api/model-route-changes?role=mix.role');
  assert.equal(all.body.changes.length, 3, 'no project = every scope for the role');
  db.close();
});

test('GET /api/model-route-changes validates role and project, and bounds the page', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  assert.equal((await call(DB, '/api/model-route-changes')).status, 400, 'role is required');
  assert.equal((await call(DB, '/api/model-route-changes?role=Bad%20Role')).status, 400);
  assert.equal((await call(DB, '/api/model-route-changes?role=ok.role&project=a%2Fb')).status, 400);

  priceModel(db, 'm-0');
  priceModel(db, 'm-1');
  for (let i = 0; i < 5; i++) {
    await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'page.role', ladder: [{ model: `m-${i % 2}`, runner: 'claude' }] } });
  }
  const r = await call(DB, '/api/model-route-changes?role=page.role&limit=2');
  assert.equal(r.status, 200);
  assert.equal(r.body.changes.length, 2);
  assert.equal(r.body.truncated, true, 'a page that bit says so');
  db.close();
});

// ─────────────────────────────────────────────────────────────── reset

test('POST /api/model-routes/reset deletes a project\'s WHOLE override, audits every rung, and the role resolves to the hub again', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'rst.role', ['m-hub']);
  priceModel(db, 'm-p0');
  priceModel(db, 'm-p1');
  await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'rst.role', project: 'project-4', ladder: [{ model: 'm-p0', runner: 'claude' }, { model: 'm-p1', runner: 'grok' }] },
  });
  assert.equal((await call(DB, '/api/model-routes/rst.role?project=project-4')).body.source, 'project');

  const r = await call(DB, '/api/model-routes/reset', {
    method: 'POST', body: { role: 'rst.role', project: 'project-4', actor: 'console', reason: 'back to hub' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 2);
  assert.equal(r.body.route.source, 'hub');
  assert.deepEqual(r.body.route.ladder.map((x) => x.model), ['m-hub']);

  const after = await call(DB, '/api/model-routes/rst.role?project=project-4');
  assert.equal(after.body.source, 'hub');

  const audit = db.prepare(
    "SELECT * FROM model_route_changes WHERE role='rst.role' AND project='project-4' AND after_model IS NULL ORDER BY position"
  ).all();
  assert.equal(audit.length, 2, 'one audit row per removed rung');
  assert.deepEqual(audit.map((a) => a.before_model), ['m-p0', 'm-p1']);
  assert.equal(audit[0].actor, 'console');
  assert.equal(audit[0].reason, 'back to hub');
  assert.equal(audit[0].scope, 'project');
  db.close();
});

test('POST /api/model-routes/reset never touches the hub, and a project with no override is a no-op, not an error', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'noop.role', ['m-hub']);
  const before = db.prepare('SELECT COUNT(*) AS n FROM model_route_changes').get().n;

  const refusedHub = await call(DB, '/api/model-routes/reset', { method: 'POST', body: { role: 'noop.role' } });
  assert.equal(refusedHub.status, 400, 'reset is project-only: there is nothing above the hub to reset to');
  const refusedEmpty = await call(DB, '/api/model-routes/reset', { method: 'POST', body: { role: 'noop.role', project: '' } });
  assert.equal(refusedEmpty.status, 400, 'an empty project is not silently the hub');
  assert.equal((await call(DB, '/api/model-routes/reset', { method: 'POST', body: { role: 'Bad Role', project: 'x' } })).status, 400);

  const noop = await call(DB, '/api/model-routes/reset', { method: 'POST', body: { role: 'noop.role', project: 'project-4' } });
  assert.equal(noop.status, 200);
  assert.equal(noop.body.removed, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM model_route_changes').get().n, before, 'nothing removed, nothing audited');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM model_routes WHERE role='noop.role' AND project IS NULL").get().n, 1,
    'the hub ladder is untouched');
  db.close();
});

// ─────────────────────────────────────────────── list read provenance

test('GET /api/model-routes carries per-rung provenance and the runner list, without changing the resolver\'s shape', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const r = await call(DB, '/api/model-routes');
  assert.equal(r.status, 200);
  assert.ok(Array.isArray(r.body.runners) && r.body.runners.includes('claude') && r.body.runners.includes('codex'),
    'the runner list comes from the worker, the one place it is defined');
  const exec = r.body.roles.find((x) => x.role === 'build.execute');
  assert.equal(exec.ladder[0].updated_by, 'seed', 'a seeded rung says so — the screen marks it');
  assert.ok(exec.ladder[0].updated_at);

  // The one-role read is what bin/lib/model-route.sh parses; it keeps its shape.
  const one = await call(DB, '/api/model-routes/build.execute');
  assert.deepEqual(Object.keys(one.body.ladder[0]).sort(), ['model', 'position', 'runner']);
  assert.ok(Array.isArray(one.body.runners), 'the edit form on the role page needs the runner list too');
  // build.execute seeds two rungs since BH-1908 (the live hub ladder).
  assert.deepEqual(one.body.provenance.map((x) => [x.position, x.updated_by]), [[0, 'seed'], [1, 'seed']],
    'provenance rides beside the ladder, for the KEEP SEEDED VALUE button');
  db.close();
});

test('GET /api/model-routes?project= gives the project rung\'s provenance for an override, the hub rung\'s otherwise', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'prov.role', ['m-hub']);
  priceModel(db, 'm-proj');
  await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'prov.role', project: 'project-4', ladder: [{ model: 'm-proj', runner: 'claude' }], actor: 'op-proj' },
  });
  const r = await call(DB, '/api/model-routes?project=project-4');
  const row = r.body.roles.find((x) => x.role === 'prov.role');
  assert.equal(row.source, 'project');
  assert.equal(row.ladder[0].updated_by, 'op-proj');
  const hubOnly = r.body.roles.find((x) => x.role === 'build.execute');
  assert.equal(hubOnly.source, 'hub');
  assert.equal(hubOnly.ladder[0].updated_by, 'seed');
  db.close();
});

// ───────────────────────────────── fix round 1: races, versions, confirm, gaps
//
// The review of #1560 reproduced two interleavings that left a ladder no
// operator wrote: PUT/PUT produced [b0, a2] (a gap at rung 1), and reset/PUT
// left a project override holding only rung 2 — which a first-row reader would
// promote to primary. `gated` holds ONE request's batch until the other request
// has finished, which is exactly the window the old read-then-delete-by-
// position code lost.
function gated(DB) {
  let release, armed = false;
  const wait = new Promise((r) => { release = r; });
  return {
    DB: { ...DB, batch: async (xs) => { if (armed) { armed = false; await wait; } return DB.batch(xs); } },
    arm: () => { armed = true; },
    release: () => release(),
  };
}
const ladderOf = async (DB, role, project) =>
  (await call(DB, `/api/model-routes/${role}${project ? `?project=${project}` : ''}`)).body;

test('race PUT/PUT: the final hub ladder is exactly ONE request\'s ladder — never a mix with a gap', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  for (const m of ['x0', 'x1', 'a0', 'a1', 'a2', 'b0']) priceModel(db, m);
  await call(base, '/api/model-routes', { method: 'PUT', body: { role: 'race.role', ladder: [{ model: 'x0', runner: 'claude' }, { model: 'x1', runner: 'claude' }] } });
  const g = gated(base);
  g.arm();
  const b = call(g.DB, '/api/model-routes', { method: 'PUT', body: { role: 'race.role', ladder: [{ model: 'b0', runner: 'claude' }] } });
  await new Promise((r) => setTimeout(r, 10)); // B has read and is parked at its batch
  const a = await call(g.DB, '/api/model-routes', { method: 'PUT', body: { role: 'race.role', ladder: ['a0', 'a1', 'a2'].map((model) => ({ model, runner: 'claude' })) } });
  assert.equal(a.status, 200);
  g.release();
  await b;
  const final = (await ladderOf(base, 'race.role')).ladder;
  const models = final.map((r) => r.model);
  assert.ok(JSON.stringify(models) === '["b0"]' || JSON.stringify(models) === '["a0","a1","a2"]',
    `the ladder is one request's, whole — got ${JSON.stringify(final)}`);
  assert.deepEqual(final.map((r) => r.position), final.map((_, i) => i), 'no gap');
  db.close();
});

test('race reset/PUT: a reset that commits last leaves NO project rung behind (never a primary-less override)', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  await seedHub(base, db, 'rr.role', ['h0']);
  for (const m of ['p0', 'p1', 'p2']) priceModel(db, m);
  await call(base, '/api/model-routes', { method: 'PUT', body: { role: 'rr.role', project: 'proj', ladder: [{ model: 'p0', runner: 'claude' }, { model: 'p1', runner: 'claude' }] } });
  const g = gated(base);
  g.arm();
  const reset = call(g.DB, '/api/model-routes/reset', { method: 'POST', body: { role: 'rr.role', project: 'proj' } });
  await new Promise((r) => setTimeout(r, 10));
  const put = await call(g.DB, '/api/model-routes', { method: 'PUT', body: { role: 'rr.role', project: 'proj', ladder: ['p0', 'p1', 'p2'].map((model) => ({ model, runner: 'claude' })) } });
  assert.equal(put.status, 200);
  g.release();
  assert.equal((await reset).status, 200);
  const rows = db.prepare("SELECT position FROM model_routes WHERE role='rr.role' AND project='proj'").all();
  assert.deepEqual(rows, [], 'the reset removed the whole scope, including the rung written inside its window');
  const r = await ladderOf(base, 'rr.role', 'proj');
  assert.equal(r.source, 'hub');
  assert.deepEqual(r.ladder.map((x) => x.model), ['h0']);
  db.close();
});

test('optimistic concurrency: a PUT or reset carrying a stale scope_version is refused 409 and writes nothing', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'ver.role', ['v0']);
  priceModel(db, 'v1');
  const seen = await ladderOf(DB, 'ver.role');
  assert.equal(typeof seen.scope_version, 'number', 'the one-role read carries the version of the scope it names');
  // Another tab writes first.
  const other = await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'ver.role', ladder: [{ model: 'v1', runner: 'claude' }], expected_version: seen.scope_version } });
  assert.equal(other.status, 200);
  const stale = await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'ver.role', ladder: [{ model: 'v0', runner: 'grok' }], expected_version: seen.scope_version } });
  assert.equal(stale.status, 409, JSON.stringify(stale.body));
  assert.match(stale.body.error, /changed/);
  assert.deepEqual((await ladderOf(DB, 'ver.role')).ladder.map((x) => x.model), ['v1'], 'the stale write changed nothing');
  const fresh = await ladderOf(DB, 'ver.role');
  assert.notEqual(fresh.scope_version, seen.scope_version, 'every write moves the version');

  priceModel(db, 'pv');
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'ver.role', project: 'proj', ladder: [{ model: 'pv', runner: 'claude' }] } });
  const pSeen = await ladderOf(DB, 'ver.role', 'proj');
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'ver.role', project: 'proj', ladder: [{ model: 'v1', runner: 'claude' }], expected_version: pSeen.scope_version } });
  const staleReset = await call(DB, '/api/model-routes/reset', { method: 'POST', body: { role: 'ver.role', project: 'proj', expected_version: pSeen.scope_version } });
  assert.equal(staleReset.status, 409);
  assert.equal((await ladderOf(DB, 'ver.role', 'proj')).source, 'project', 'the stale reset removed nothing');
  db.close();
});

test('confirm: re-PUTting an unchanged ladder with confirm:true records it as reviewed — updated_by moves off seed, one audit row per rung', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const before = db.prepare("SELECT COUNT(*) AS n FROM model_route_changes WHERE role='build.execute'").get().n;
  const cur = await ladderOf(DB, 'build.execute');
  for (const r of cur.ladder) priceModel(db, r.model);
  const body = { role: 'build.execute', ladder: cur.ladder.map(({ model, runner }) => ({ model, runner })), actor: 'console', reason: 'reviewed' };
  const plain = await call(DB, '/api/model-routes', { method: 'PUT', body });
  assert.equal(plain.status, 200, JSON.stringify(plain.body));
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM model_route_changes WHERE role='build.execute'").get().n, before, 'no confirm, no change: nothing written');
  const confirmed = await call(DB, '/api/model-routes', { method: 'PUT', body: { ...body, confirm: true } });
  assert.equal(confirmed.status, 200);
  const rows = db.prepare("SELECT updated_by FROM model_routes WHERE role='build.execute' AND project IS NULL").all();
  // Both seeded rungs (BH-1908) are confirmed, not only rung 0.
  assert.deepEqual(rows.map((r) => r.updated_by), ['console', 'console']);
  const audit = db.prepare("SELECT * FROM model_route_changes WHERE role='build.execute' ORDER BY id DESC LIMIT 1").get();
  assert.equal(audit.before_model, audit.after_model, 'a confirm audits before = after');
  assert.equal(audit.reason, 'reviewed');
  const list = await call(DB, '/api/model-routes');
  assert.equal(list.body.roles.find((r) => r.role === 'build.execute').ladder[0].updated_by, 'console');
  db.close();
});

test('an unchanged rung keeps its own provenance when a sibling rung changes', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'orc-new');
  const cur = (await ladderOf(DB, 'orchestrate')).ladder;
  for (const r of cur) priceModel(db, r.model);
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'orchestrate', ladder: [{ model: cur[0].model, runner: cur[0].runner }, { model: 'orc-new', runner: 'claude' }], actor: 'op' } });
  const rows = db.prepare("SELECT position, updated_by FROM model_routes WHERE role='orchestrate' AND project IS NULL ORDER BY position").all();
  assert.deepEqual(rows.map((r) => r.updated_by), ['seed', 'op'], 'rung 0 was not decided by this write, so it stays seed');
  db.close();
});

test('the resolver never promotes past a gap: a project scope with no rung 0 falls back to the hub; a hub with none is no route', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'gap.role', ['g0']);
  db.prepare("INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) VALUES ('project','proj','gap.role',2,'stray','grok','x','2026-09-22T00:00:00Z')").run();
  const r = await ladderOf(DB, 'gap.role', 'proj');
  assert.equal(r.source, 'hub');
  assert.deepEqual(r.ladder.map((x) => x.model), ['g0']);
  db.prepare("INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at) VALUES ('hub',NULL,'hubgap.role',1,'stray','grok','x','2026-09-22T00:00:00Z')").run();
  const h = await ladderOf(DB, 'hubgap.role');
  assert.equal(h.source, 'none');
  assert.deepEqual(h.ladder, []);
  db.close();
});

test('an empty-string project on a PUT is refused, never read as the hub', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'e0');
  const r = await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'e.role', project: '', ladder: [{ model: 'e0', runner: 'claude' }] } });
  assert.equal(r.status, 400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM model_routes WHERE role='e.role'").get().n, 0);
  db.close();
});

test('the version guard is INSIDE the batch: a write that lands after the read-time check still makes the stale PUT a 409, and it writes nothing', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  await seedHub(base, db, 'atom.role', ['t0']);
  for (const m of ['t1', 't2']) priceModel(db, m);
  const v = (await ladderOf(base, 'atom.role')).scope_version;
  const g = gated(base);
  g.arm();
  // A passes its read-time check with v, then parks at its batch...
  const a = call(g.DB, '/api/model-routes', { method: 'PUT', body: { role: 'atom.role', ladder: [{ model: 't1', runner: 'claude' }], expected_version: v } });
  await new Promise((r) => setTimeout(r, 10));
  // ...B commits in the window...
  const b = await call(g.DB, '/api/model-routes', { method: 'PUT', body: { role: 'atom.role', ladder: [{ model: 't2', runner: 'claude' }], expected_version: v } });
  assert.equal(b.status, 200);
  g.release();
  // ...so A's own batch must refuse, not overwrite B's decision.
  const ra = await a;
  assert.equal(ra.status, 409, JSON.stringify(ra.body));
  assert.deepEqual((await ladderOf(base, 'atom.role')).ladder.map((x) => x.model), ['t2']);
  db.close();
});
