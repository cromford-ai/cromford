// BH-2523: the fly_images store — one row per (project, digest), at most one
// active per project. Driven through the REAL router against a real schema.sql
// database (the node:sqlite shim), the way cooldowns.bh-2353.test.js does it.
// The shell side is bin/lib/fly-image-row.sh (tests/fly-images.bh-2523-test.sh).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const ANCHOR = Math.floor(Date.now() / 1000); // determinism: ok the one clock read every baked_at fixture is derived from
const REF_A = 'registry.fly.io/builder-alpha-os:deployment-01AAAAAAAAAAAAAAAAAAAAAAAA';
const REF_B = 'registry.fly.io/builder-alpha-os:deployment-01BBBBBBBBBBBBBBBBBBBBBBBB';

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body) => call(DB, '/api/fly-images', { method: 'PUT', body });
const get = (DB, project) => call(DB, `/api/fly-images?project=${encodeURIComponent(project)}`);
const cols = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all()
  .map((c) => [c.name, c.type, c.notnull, c.pk]);

test('BH-2523 fly_images', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('schema parity: schema.sql and CREATED_TABLES.fly_images give the same columns', async () => {
    const stmts = CREATED_TABLES.fly_images;
    assert.ok(Array.isArray(stmts) && stmts.length === 2, 'table + index');
    assert.match(SCHEMA, /CREATE TABLE IF NOT EXISTS fly_images \(/);
    assert.ok(SCHEMA.includes(`${stmts[1]};`), 'the index statement is schema.sql\'s verbatim');
    const fromSchema = probe.db;
    const fresh = await openDb();
    fresh.db.exec('DROP TABLE IF EXISTS fly_images');
    for (const s of stmts) fresh.db.exec(s);
    const want = cols(fromSchema, 'fly_images');
    assert.ok(want.length > 0, 'schema.sql creates fly_images');
    assert.deepEqual(cols(fresh.db, 'fly_images'), want);
    // A PUT self-creates the table on a DB that never ran schema.sql.
    fresh.db.exec('DROP TABLE IF EXISTS fly_images');
    const res = await put(fresh.DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A });
    assert.equal(res.status, 200, JSON.stringify(res.body));
  });

  await t.test('PUT then GET returns every field', async () => {
    const { DB } = await openDb();
    const res = await put(DB, {
      project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A,
      bake: 'node=22.1\n', cli: 'claude=2.1\ncodex=0.1\n', baked_at: ANCHOR - 300, active: 1, box: 'hub',
    });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    const g = await get(DB, 'alpha-os');
    assert.equal(g.status, 200);
    const r = g.body.row;
    assert.deepEqual(
      [r.project, r.app, r.digest, r.bake, r.cli, r.baked_at, r.active, r.box],
      ['alpha-os', 'builder-alpha-os', REF_A, 'node=22.1\n', 'claude=2.1\ncodex=0.1\n', ANCHOR - 300, 1, 'hub'],
    );
    assert.equal(typeof r.set_at, 'string');
    assert.equal(typeof g.body.as_of, 'string');
  });

  await t.test('two activations leave exactly one active row, the later one', async () => {
    const { DB, db } = await openDb();
    assert.equal((await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, active: 1 })).status, 200);
    assert.equal((await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_B, active: 1 })).status, 200);
    const act = db.prepare("SELECT digest FROM fly_images WHERE project='alpha-os' AND active=1").all();
    assert.deepEqual(act.map((x) => x.digest), [REF_B]);
    assert.equal((await get(DB, 'alpha-os')).body.row.digest, REF_B);
    // The rollback shape: re-activating the older ref moves the pointer back.
    assert.equal((await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, active: 1 })).status, 200);
    const act2 = db.prepare("SELECT digest FROM fly_images WHERE project='alpha-os' AND active=1").all();
    assert.deepEqual(act2.map((x) => x.digest), [REF_A]);
    assert.equal(db.prepare("SELECT count(*) AS n FROM fly_images WHERE project='alpha-os'").get().n, 2);
  });

  await t.test('a PUT without active leaves the active row alone', async () => {
    const { DB } = await openDb();
    await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, active: 1 });
    await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_B });
    assert.equal((await get(DB, 'alpha-os')).body.row.digest, REF_A);
  });

  await t.test('a resend with no bake, cli or baked_at keeps the stored values', async () => {
    const { DB } = await openDb();
    await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, bake: 'node=22.1\n', cli: 'claude=2.1\n', baked_at: ANCHOR - 60, active: 1 });
    const res = await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, active: 1 });
    assert.equal(res.status, 200);
    const r = (await get(DB, 'alpha-os')).body.row;
    assert.equal(r.bake, 'node=22.1\n');
    assert.equal(r.cli, 'claude=2.1\n');
    assert.equal(r.baked_at, ANCHOR - 60);
  });

  await t.test('the PUT refuses bad input with a 400 and writes nothing', async () => {
    const { DB, db } = await openDb();
    const bad = [
      { project: 'alpha-os', app: 'builder-alpha-os', digest: 'docker.io/evil:latest' },
      { project: 'alpha-os', app: 'builder-alpha-os', digest: 'registry.fly.io/builder-alpha-os:tag with space' },
      { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, baked_at: ANCHOR + 3600 },
      { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, baked_at: 'soon' },
      { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, baked_at: -1 },
      { project: 'alpha-os', digest: REF_A },
      { app: 'builder-alpha-os', digest: REF_A },
      { project: 'alpha os', app: 'builder-alpha-os', digest: REF_A },
      // Another app's ref (TK-1175: a foreign ref in the pointer file).
      { project: 'alpha-os', app: 'builder-alpha-os', digest: 'registry.fly.io/builder-beta-os:deployment-01C' },
      { project: 'alpha-os', app: 'builder-alpha-os', digest: 'registry.fly.io/builder-alpha-os-2:deployment-01C' },
    ];
    for (const b of bad) {
      const res = await put(DB, b);
      assert.equal(res.status, 400, `${JSON.stringify(b)} -> ${res.status} ${JSON.stringify(res.body)}`);
      assert.equal(typeof res.body.error, 'string');
    }
    const n = db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='fly_images'").get().n
      ? db.prepare('SELECT count(*) AS n FROM fly_images').get().n : 0;
    assert.equal(n, 0);
  });

  await t.test('GET for an unknown project is 200 row:null; a bad project is 400', async () => {
    const { DB } = await openDb();
    const g = await get(DB, 'nobody');
    assert.equal(g.status, 200);
    assert.equal(g.body.row, null);
    assert.equal((await call(DB, '/api/fly-images')).status, 400);
  });

  await t.test('project keys are exact: alpha-os never answers alpha-os-2', async () => {
    const { DB } = await openDb();
    await put(DB, { project: 'alpha-os-2', app: 'builder-alpha-os-2', digest: 'registry.fly.io/builder-alpha-os-2:deployment-01C', active: 1 });
    assert.equal((await get(DB, 'alpha-os')).body.row, null);
    assert.equal((await get(DB, 'alpha-os-')).body.row, null);
    await put(DB, { project: 'alpha-os', app: 'builder-alpha-os', digest: REF_A, active: 1 });
    assert.equal((await get(DB, 'alpha-os')).body.row.digest, REF_A);
    assert.equal((await get(DB, 'alpha-os-2')).body.row.digest, 'registry.fly.io/builder-alpha-os-2:deployment-01C');
  });
});
