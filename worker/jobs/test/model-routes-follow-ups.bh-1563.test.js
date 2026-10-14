import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1563 — the two worker halves of the #1560 round-2 review:
//
//   #8 HUB DRIFT. The one-role read's `scope_version` is the version of the
//      scope the read NAMES, which for a project with no override is 0. So a
//      project-tab save that creates an override from the inherited hub ladder
//      carried expected_version: 0 and could not notice the hub ladder moving
//      in another tab between the load and the save. The read now also carries
//      `hub_scope_version`, the PUT accepts `expected_hub_version`, and a
//      tripped guard is a 409 that names WHICH scope moved (`stale`).
//
//   #9 LEGACY GAPPED SCOPES. `resolveModelLadder` ignores any scope whose rows
//      do not start at position 0, so the half-written ladders the pre-#1560
//      write shapes could leave behind are invisible: the project tab shows
//      HUB DEFAULT, the hub tab shows NO ROUTE, and nothing lists them. The
//      list read now carries `gaps` (fleet-wide) and the one-role read carries
//      `gapped` with the orphan rows, so the console can show them and an
//      operator can repair them.
//
// Driven against the SQL that ships (schema.sql) through worker.fetch, the
// #1510.3 suite's idiom.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// Each .bind() returns its OWN statement (see the #1510.3 suite: model-routes.js
// prepares once and binds per rung).
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

const ladderOf = async (DB, role, project) =>
  (await call(DB, `/api/model-routes/${role}${project ? `?project=${project}` : ''}`)).body;

const listOf = async (DB, project) =>
  (await call(DB, `/api/model-routes${project ? `?project=${project}` : ''}`)).body;

// One row straight into the table, bypassing the routes — the only way to make
// the legacy shape the whole-scope replace can no longer write.
const orphan = (db, project, role, position, model) => db.prepare(
  `INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
   VALUES (?, ?, ?, ?, ?, 'grok', 'legacy', '2026-09-20T00:00:00Z')`
).run(project ? 'project' : 'hub', project, role, position, model);

const countRows = (db, sql, ...binds) => Number(db.prepare(sql).get(...binds).n);

// ───────────────────────────────────────────── #8: the hub drift guard

test('the one-role read carries hub_scope_version beside scope_version, and on a project with no override scope_version is 0 while hub_scope_version is the hub\'s', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'drift.role', ['d0']);
  const hubMax = countRows(db, "SELECT coalesce(max(id),0) AS n FROM model_routes WHERE role='drift.role' AND project IS NULL");

  const asProject = await ladderOf(DB, 'drift.role', 'proj');
  assert.equal(asProject.source, 'hub');
  assert.equal(asProject.scope_version, 0, 'the project owns nothing yet');
  assert.equal(asProject.hub_scope_version, hubMax, 'the hub ladder this edit would be based on');

  const asHub = await ladderOf(DB, 'drift.role');
  assert.equal(asHub.scope_version, hubMax);
  assert.equal(asHub.hub_scope_version, hubMax, 'on a hub read the two are the same number');
  db.close();
});

test('a project PUT whose expected_hub_version is stale is a 409 naming the hub, and it writes nothing', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'drift.role', ['d0']);
  for (const m of ['d1', 'd2']) priceModel(db, m);

  // The operator loads the project tab on the inherited hub ladder…
  const seen = await ladderOf(DB, 'drift.role', 'proj');
  // …somebody edits the HUB in another tab…
  await seedHub(DB, db, 'drift.role', ['d1']);
  const changesBefore = countRows(db, "SELECT COUNT(*) AS n FROM model_route_changes WHERE role='drift.role'");

  // …and the project save must refuse, because the ladder it was based on moved.
  const r = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: {
      role: 'drift.role', project: 'proj', ladder: [{ model: 'd2', runner: 'claude' }],
      expected_version: seen.scope_version, expected_hub_version: seen.hub_scope_version,
    },
  });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.stale, 'hub');
  assert.match(r.body.error, /hub/i);
  assert.equal(r.body.hub_scope_version, await (async () => {
    const h = await ladderOf(DB, 'drift.role');
    return h.scope_version;
  })(), 'the 409 hands back the hub version it should have carried');
  assert.equal(countRows(db, "SELECT COUNT(*) AS n FROM model_routes WHERE role='drift.role' AND project='proj'"), 0, 'no override was created');
  assert.equal(countRows(db, "SELECT COUNT(*) AS n FROM model_route_changes WHERE role='drift.role'"), changesBefore, 'no audit row was written');
  db.close();
});

test('a project PUT whose OWN scope moved is a 409 naming the project, not the hub', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'own.role', ['o0']);
  for (const m of ['o1', 'o2']) priceModel(db, m);
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'own.role', project: 'proj', ladder: [{ model: 'o1', runner: 'claude' }] } });
  const seen = await ladderOf(DB, 'own.role', 'proj');
  assert.equal(seen.source, 'project');
  // Someone else rewrites the PROJECT ladder; the hub is untouched.
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'own.role', project: 'proj', ladder: [{ model: 'o2', runner: 'claude' }] } });

  const r = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: {
      role: 'own.role', project: 'proj', ladder: [{ model: 'o0', runner: 'claude' }],
      expected_version: seen.scope_version, expected_hub_version: seen.hub_scope_version,
    },
  });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.stale, 'project');
  db.close();
});

test('the hub guard is INSIDE the batch: a hub write that lands after the read-time check still makes the project PUT a 409', async () => {
  const db = openDb();
  const base = sqliteDB(db);
  await seedHub(base, db, 'atomhub.role', ['a0']);
  for (const m of ['a1', 'a2']) priceModel(db, m);
  const seen = await ladderOf(base, 'atomhub.role', 'proj');

  // The project PUT passes its read-time hub check, then parks at its batch…
  let release;
  const wait = new Promise((r) => { release = r; });
  let armed = true;
  const gatedDB = { ...base, batch: async (xs) => { if (armed) { armed = false; await wait; } return base.batch(xs); } };
  const a = call(gatedDB, '/api/model-routes', {
    method: 'PUT',
    body: {
      role: 'atomhub.role', project: 'proj', ladder: [{ model: 'a1', runner: 'claude' }],
      expected_version: seen.scope_version, expected_hub_version: seen.hub_scope_version,
    },
  });
  await new Promise((r) => setTimeout(r, 10));
  // …the hub moves in the window…
  await seedHub(base, db, 'atomhub.role', ['a2']);
  release();
  // …so the parked batch's own guard must refuse it.
  const ra = await a;
  assert.equal(ra.status, 409, JSON.stringify(ra.body));
  assert.equal(ra.body.stale, 'hub');
  assert.equal(countRows(db, "SELECT COUNT(*) AS n FROM model_routes WHERE role='atomhub.role' AND project='proj'"), 0);
  db.close();
});

test('expected_hub_version on a HUB write is a 400 caller bug, never silently ignored; a malformed one is a 400 too', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'hubw.role', ['h0']);
  priceModel(db, 'h1');
  const v = (await ladderOf(DB, 'hubw.role')).scope_version;

  const onHub = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'hubw.role', ladder: [{ model: 'h1', runner: 'claude' }], expected_hub_version: v },
  });
  assert.equal(onHub.status, 400, JSON.stringify(onHub.body));
  assert.match(onHub.body.error, /expected_hub_version/);
  assert.deepEqual((await ladderOf(DB, 'hubw.role')).ladder.map((x) => x.model), ['h0'], 'the refused hub write changed nothing');

  const bad = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'hubw.role', project: 'proj', ladder: [{ model: 'h1', runner: 'claude' }], expected_hub_version: 'soon' },
  });
  assert.equal(bad.status, 400, JSON.stringify(bad.body));
  assert.equal(countRows(db, "SELECT COUNT(*) AS n FROM model_routes WHERE project='proj'"), 0);
  db.close();
});

test('both versions current: the project override is written, and a project that owns its ladder is NOT blocked by a later hub edit', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'okp.role', ['k0']);
  for (const m of ['k1', 'k2', 'k3']) priceModel(db, m);
  const seen = await ladderOf(DB, 'okp.role', 'proj');

  const r = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: {
      role: 'okp.role', project: 'proj', ladder: [{ model: 'k1', runner: 'claude' }],
      expected_version: seen.scope_version, expected_hub_version: seen.hub_scope_version,
    },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const own0 = await ladderOf(DB, 'okp.role', 'proj');
  assert.equal(own0.source, 'project');
  assert.equal(own0.hub_scope_version, (await ladderOf(DB, 'okp.role')).scope_version, 'the read still names the hub version a later save would guard on');

  // The hub moves; the project now owns its ladder, so its next save sends only
  // expected_version and must still land.
  await seedHub(DB, db, 'okp.role', ['k2']);
  const own = await ladderOf(DB, 'okp.role', 'proj');
  const r2 = await call(DB, '/api/model-routes', {
    method: 'PUT',
    body: { role: 'okp.role', project: 'proj', ladder: [{ model: 'k3', runner: 'claude' }], expected_version: own.scope_version },
  });
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  assert.deepEqual((await ladderOf(DB, 'okp.role', 'proj')).ladder.map((x) => x.model), ['k3']);
  db.close();
});

test('expected_hub_version on a RESET is a 400: a guard field that quietly did nothing would read as protection', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'rst.role', ['s0']);
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'rst.role', project: 'proj', ladder: [{ model: 's0', runner: 'claude' }] } });
  const seen = await ladderOf(DB, 'rst.role', 'proj');

  const r = await call(DB, '/api/model-routes/reset', {
    method: 'POST',
    body: { role: 'rst.role', project: 'proj', expected_version: seen.scope_version, expected_hub_version: seen.hub_scope_version },
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /expected_hub_version/);
  assert.equal((await ladderOf(DB, 'rst.role', 'proj')).source, 'project', 'the refused reset removed nothing');
  db.close();
});

// ──────────────────────────────────────────── #9: legacy gapped scopes

test('gaps lists every scope whose rows do not start at rung 0, with its positions — and a 0,2 ladder or an empty scope is not one', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'g.normal', ['n0', 'n1']);       // 0,1 — fine
  await seedHub(DB, db, 'g.hole', ['x0']);
  orphan(db, null, 'g.hole', 2, 'x2');                    // 0,2 — a hole PAST the primary, resolves fine
  orphan(db, 'proj', 'g.proj', 2, 'p2');                  // project scope, rung 2 only
  orphan(db, null, 'g.hub', 1, 'h1');
  orphan(db, null, 'g.hub', 3, 'h3');                     // hub scope, rungs 1 and 3

  const list = await listOf(DB);
  assert.deepEqual(list.gaps, [
    { project: null, role: 'g.hub', positions: [1, 3] },
    { project: 'proj', role: 'g.proj', positions: [2] },
  ], JSON.stringify(list.gaps));

  const byRole = Object.fromEntries(list.roles.map((r) => [r.role, r]));
  assert.equal(byRole['g.hub'].gapped, true);
  assert.equal(byRole['g.hub'].source, 'none', 'a gapped hub scope is no route');
  assert.equal(byRole['g.normal'].gapped, false);
  assert.equal(byRole['g.hole'].gapped, false, 'a hole past rung 0 is an order, not an index');
  assert.ok(!('g.proj' in byRole), 'a project-only scope is not a hub-tab row — the gaps list is what surfaces it');
  db.close();
});

test('on a project tab the gaps list is still fleet-wide, and only the scope THIS read names is tagged gapped', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  // The project owns a good ladder for a role whose HUB scope is gapped.
  await seedHub(DB, db, 'mix.role', ['m0']);
  await call(DB, '/api/model-routes', { method: 'PUT', body: { role: 'mix.role', project: 'proj', ladder: [{ model: 'm0', runner: 'claude' }] } });
  db.prepare("DELETE FROM model_routes WHERE role='mix.role' AND project IS NULL AND position=0").run();
  orphan(db, null, 'mix.role', 1, 'm1');
  // …and a second role where the PROJECT is the gapped one.
  await seedHub(DB, db, 'fall.role', ['f0']);
  orphan(db, 'proj', 'fall.role', 2, 'f2');

  const list = await listOf(DB, 'proj');
  assert.deepEqual(list.gaps.map((g) => `${g.project || 'hub'}/${g.role}`).sort(), ['hub/mix.role', 'proj/fall.role']);
  const byRole = Object.fromEntries(list.roles.map((r) => [r.role, r]));
  assert.equal(byRole['mix.role'].source, 'project');
  assert.equal(byRole['mix.role'].gapped, false, 'the project owns this role, so the hub\'s gap is not this row\'s');
  assert.equal(byRole['fall.role'].source, 'hub', 'the gapped project scope falls back');
  assert.equal(byRole['fall.role'].gapped, true);
  db.close();
});

test('the one-role read of a gapped project scope hands back the orphan rows and a scope_version that can repair them', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'orph.role', ['r0']);
  orphan(db, 'proj', 'orph.role', 2, 'r2');

  const r = await ladderOf(DB, 'orph.role', 'proj');
  assert.equal(r.source, 'hub', 'the resolver still ignores it');
  assert.deepEqual(r.ladder.map((x) => x.model), ['r0']);
  assert.ok(r.gapped, 'the read says the scope it names is gapped');
  assert.deepEqual(r.gapped.rows, [{ position: 2, model: 'r2', runner: 'grok' }]);
  assert.ok(r.scope_version > 0, 'the orphan rows have a version, so a guarded write can replace them');

  // A hub read of a healthy hub scope is not gapped.
  assert.equal((await ladderOf(DB, 'orph.role')).gapped, null);
  db.close();
});

test('RESET with the gapped scope\'s version clears the gap and audits every orphan rung', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await seedHub(DB, db, 'fix.role', ['r0']);
  orphan(db, 'proj', 'fix.role', 2, 'r2');
  const seen = await ladderOf(DB, 'fix.role', 'proj');

  const r = await call(DB, '/api/model-routes/reset', {
    method: 'POST', body: { role: 'fix.role', project: 'proj', expected_version: seen.scope_version, actor: 'console' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 1);
  assert.deepEqual((await listOf(DB, 'proj')).gaps, []);
  assert.equal((await ladderOf(DB, 'fix.role', 'proj')).gapped, null);
  assert.equal(countRows(db, "SELECT COUNT(*) AS n FROM model_route_changes WHERE role='fix.role' AND project='proj' AND after_model IS NULL"), 1);
  db.close();
});

test('a PUT of a whole ladder on a gapped HUB scope replaces it and clears the gap', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  orphan(db, null, 'hubfix.role', 1, 'q1');
  priceModel(db, 'q0');
  const seen = await ladderOf(DB, 'hubfix.role');
  assert.ok(seen.gapped);

  const r = await call(DB, '/api/model-routes', {
    method: 'PUT', body: { role: 'hubfix.role', ladder: [{ model: 'q0', runner: 'claude' }], expected_version: seen.scope_version },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual((await listOf(DB)).gaps, []);
  const after = await ladderOf(DB, 'hubfix.role');
  assert.equal(after.source, 'hub');
  assert.equal(after.gapped, null);
  assert.deepEqual(after.ladder.map((x) => x.model), ['q0']);
  db.close();
});
