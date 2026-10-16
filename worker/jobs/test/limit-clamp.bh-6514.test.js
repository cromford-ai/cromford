// BH-6514 (BH-6523): GET /api/jobs and GET /api/ledger clamp ?limit= to a
// positive integer. Before, `Math.min(Number(x) || d, M)` had no lower bound:
// `limit=-1` built `LIMIT -1`, which SQLite and D1 read as "no limit", and
// `limit=-Infinity` built `LIMIT -Infinity`, which D1 refuses (a 500).
//
// Real schema behind the node:sqlite shim, through the real worker.fetch.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

const get = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

function seedJobs(db) {
  const stmt = db.prepare(
    "INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES (?, 'p', 'build', 'b', 'plan', 'done', ?, ?)",
  );
  for (let i = 1; i <= 3; i++) {
    const at = `2026-10-15T00:00:0${i}Z`;
    stmt.run(`j${i}`, at, at);
  }
}

function seedLedger(db) {
  const stmt = db.prepare(
    "INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('k', ?, 'set', ?, ?)",
  );
  for (let i = 1; i <= 3; i++) {
    const at = `2026-10-15T00:00:0${i}Z`;
    stmt.run(`key${i}`, at, at);
  }
}

test('BH-6514 limit clamp on /api/jobs and /api/ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('K1. /api/jobs?limit=-1 returns 1 job, not the whole table', async () => {
    const { db, DB } = await openDb();
    seedJobs(db);
    const r = await get(DB, '/api/jobs?limit=-1');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.jobs.length, 1);
  });

  await t.test('K2. /api/jobs: -Infinity is 1 (not a 500), 2.7 is 2, abc is the default, 2 is 2', async () => {
    const { db, DB } = await openDb();
    seedJobs(db);
    const inf = await get(DB, '/api/jobs?limit=-Infinity');
    assert.equal(inf.status, 200, JSON.stringify(inf.body));
    assert.equal(inf.body.jobs.length, 1);
    const frac = await get(DB, '/api/jobs?limit=2.7');
    assert.equal(frac.status, 200, JSON.stringify(frac.body));
    assert.equal(frac.body.jobs.length, 2);
    const abc = await get(DB, '/api/jobs?limit=abc');
    assert.equal(abc.status, 200);
    assert.equal(abc.body.jobs.length, 3);
    const two = await get(DB, '/api/jobs?limit=2');
    assert.equal(two.status, 200);
    assert.deepEqual(two.body.jobs.map((j) => j.id), ['j3', 'j2']);
    const big = await get(DB, '/api/jobs?limit=1e9');
    assert.equal(big.status, 200);
    assert.equal(big.body.jobs.length, 3);
  });

  await t.test('K3. /api/ledger?kind=k&limit=-1 returns 1 row, not every row of the kind', async () => {
    const { db, DB } = await openDb();
    seedLedger(db);
    const r = await get(DB, '/api/ledger?kind=k&limit=-1');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.ledgers.length, 1);
  });

  await t.test('K4. /api/ledger: 2.7 is 2, abc is the default, 2 is 2, -Infinity is 1', async () => {
    const { db, DB } = await openDb();
    seedLedger(db);
    const frac = await get(DB, '/api/ledger?kind=k&limit=2.7');
    assert.equal(frac.status, 200, JSON.stringify(frac.body));
    assert.equal(frac.body.ledgers.length, 2);
    const abc = await get(DB, '/api/ledger?kind=k&limit=abc');
    assert.equal(abc.status, 200);
    assert.equal(abc.body.ledgers.length, 3);
    const two = await get(DB, '/api/ledger?kind=k&limit=2');
    assert.equal(two.status, 200);
    assert.deepEqual(two.body.ledgers.map((r) => r.key), ['key3', 'key2']);
    const inf = await get(DB, '/api/ledger?kind=k&limit=-Infinity');
    assert.equal(inf.status, 200, JSON.stringify(inf.body));
    assert.equal(inf.body.ledgers.length, 1);
  });
});
