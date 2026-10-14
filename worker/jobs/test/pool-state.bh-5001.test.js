// BH-5001 (BH-4951.2): the Fly pool's money-deciding state as rows — the per-key
// spawn ledger, the push-rejected terminal verdict, and the spawn/ticket holds —
// plus the machine stamp on a build_queue claim won before the machine existed.
// Driven through the REAL router against a real schema.sql database (the
// node:sqlite shim), the way fly-images.bh-2523.test.js does it. The shell side
// is bin/lib/pool-state-rows.sh (tests/pool-state-db.bh-5001-test.sh).
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
const NOW = 1790000000; // a fixed epoch: every ts fixture is derived from it
// Text stamps derive from NOW too, so no fixture is pinned to a calendar date.
const iso = (t, sep = ' ') => new Date(t * 1000).toISOString().replace('T', sep).replace(/\.\d+Z$/, 'Z');
const TABLES = ['pool_spawns', 'pool_terminals', 'pool_holds'];

const call = (DB, path, { method = 'GET', body, auth = true } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const get = (DB, project, since = 0) => call(DB, `/api/pool-state?project=${encodeURIComponent(project)}&since=${since}`);
const cols = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all()
  .map((c) => [c.name, c.type, c.notnull, c.pk]);

test('BH-5001 pool state rows', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 schema parity: schema.sql and CREATED_TABLES.pool_* give the same columns; schema applies twice', async () => {
    for (const table of TABLES) {
      const stmts = CREATED_TABLES[table];
      assert.ok(Array.isArray(stmts) && stmts.length >= 1, `CREATED_TABLES.${table}`);
      assert.match(SCHEMA, new RegExp(`CREATE TABLE IF NOT EXISTS ${table} \\(`));
      const want = cols(probe.db, table);
      assert.ok(want.length > 0, `schema.sql creates ${table}`);
      const fresh = await openDb();
      fresh.db.exec(`DROP TABLE IF EXISTS ${table}`);
      for (const s of stmts) fresh.db.exec(s);
      assert.deepEqual(cols(fresh.db, table), want, `${table} columns differ`);
    }
    assert.ok(SCHEMA.includes(`${CREATED_TABLES.pool_spawns[1]};`), 'the spawns index is schema.sql\'s verbatim');
    probe.db.exec(SCHEMA); // a second apply must not error
    const seed = probe.db.prepare("SELECT value, actor FROM settings WHERE key='pool_state_rows'").get();
    assert.deepEqual({ ...seed }, { value: '0', actor: 'seed' });
    // A route self-creates its tables on a DB that never ran schema.sql.
    const fresh = await openDb();
    for (const table of TABLES) fresh.db.exec(`DROP TABLE IF EXISTS ${table}`);
    const g = await get(fresh.DB, 'alpha-os');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const w = await call(fresh.DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows: [{ key: 'BH-1', ts: NOW, box: 'hub' }] } });
    assert.equal(w.status, 200, JSON.stringify(w.body));
  });

  await t.test('W2 spawns: insert is idempotent, since filters, bounds refuse', async () => {
    const { DB } = await openDb();
    const rows = [
      { key: 'BH-1', ts: NOW - 100, box: 'hub' },
      { key: 'BH-1', ts: NOW - 50, box: 'hub', machine: '1234567890abcd' },
      { key: 'BH-2', ts: NOW - 5000, box: 'hub#2' },
    ];
    const a = await call(DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows } });
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.deepEqual(a.body, { inserted: 3, total: 3 });
    const b = await call(DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows } });
    assert.deepEqual(b.body, { inserted: 0, total: 3 });
    const g = await get(DB, 'alpha-os', NOW - 1000);
    assert.equal(g.status, 200);
    assert.equal(g.body.project, 'alpha-os');
    assert.deepEqual(g.body.spawns.map((s) => [s.key, s.ts, s.box, s.machine]).sort(),
      [['BH-1', NOW - 100, 'hub', null], ['BH-1', NOW - 50, 'hub', '1234567890abcd']]);
    assert.equal(g.body.truncated.spawns, false);
    assert.equal((await get(DB, 'alpha-os', 0)).body.spawns.length, 3);
    assert.equal((await get(DB, 'beta-os', 0)).body.spawns.length, 0, 'projects are exact');
    const many = Array.from({ length: 501 }, (_, i) => ({ key: 'BH-9', ts: NOW - i, box: 'hub' }));
    const big = await call(DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows: many } });
    assert.equal(big.status, 400);
    for (const bad of [{ key: 'BH-1', ts: 'soon', box: 'hub' }, { key: 'BH-1', ts: 1.5, box: 'hub' },
      { key: 'bad key', ts: NOW, box: 'hub' }, { key: 'BH-1', ts: NOW }, { key: 'BH-1', ts: NOW, box: 'a b' }]) {
      const r = await call(DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows: [bad] } });
      assert.equal(r.status, 400, JSON.stringify(bad));
    }
    assert.equal((await get(DB, 'alpha-os', 0)).body.spawns.length, 3, 'a refused batch writes nothing');
    assert.equal((await call(DB, '/api/pool-state?since=0')).status, 400, 'project is required');
    assert.equal((await call(DB, '/api/pool-state?project=alpha-os&since=x')).status, 400, 'since is an int');
  });

  await t.test('W2b spawns: the list is bounded and says when it was cut', async () => {
    const { DB } = await openDb();
    for (let c = 0; c < 5; c++) {
      const rows = Array.from({ length: 500 }, (_, i) => ({ key: 'BH-T', ts: NOW - c * 500 - i, box: 'hub' }));
      const r = await call(DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows } });
      assert.equal(r.body.inserted, 500);
    }
    const g = await get(DB, 'alpha-os', 0);
    assert.equal(g.body.spawns.length, 2000);
    assert.equal(g.body.truncated.spawns, true);
  });

  await t.test('W3 remove deletes exactly one row per call', async () => {
    const { DB, db } = await openDb();
    await call(DB, '/api/pool-state/spawns', { method: 'POST', body: { project: 'alpha-os', rows: [
      { key: 'BH-1', ts: NOW, box: 'hub-a' }, { key: 'BH-1', ts: NOW, box: 'hub-b' }, { key: 'BH-1', ts: NOW + 1, box: 'hub-a' }] } });
    const n = () => db.prepare("SELECT count(*) AS n FROM pool_spawns WHERE ticket_key='BH-1' AND ts=?").get(NOW).n;
    const rm = () => call(DB, '/api/pool-state/spawns/remove', { method: 'POST', body: { project: 'alpha-os', key: 'BH-1', ts: NOW } });
    assert.deepEqual((await rm()).body, { removed: 1 }); assert.equal(n(), 1);
    assert.deepEqual((await rm()).body, { removed: 1 }); assert.equal(n(), 0);
    assert.deepEqual((await rm()).body, { removed: 0 });
    assert.equal(db.prepare('SELECT count(*) AS n FROM pool_spawns').get().n, 1, 'the other ts is untouched');
    assert.equal((await call(DB, '/api/pool-state/spawns/remove', { method: 'POST', body: { project: 'alpha-os', key: 'BH-1', ts: 'x' } })).status, 400);
  });

  await t.test('W4 terminal: if_absent keeps the first, clear records why, a new PUT re-arms the verdict', async () => {
    const { DB } = await openDb();
    const put = (b) => call(DB, '/api/pool-state/terminal', { method: 'PUT', body: { project: 'alpha-os', key: 'BH-T1', box: 'hub', ...b } });
    const term = async () => (await get(DB, 'alpha-os')).body.terminals.find((x) => x.key === 'BH-T1');
    assert.equal((await put({ branch: 'ticket/bh-t1', head_sha: 'aaa', reason: 'push rejected', created_at: iso(NOW - 3600) })).status, 200);
    assert.equal((await put({ branch: 'ticket/bh-t1', head_sha: 'zzz', reason: 'file', if_absent: true })).status, 200);
    let r = await term();
    assert.deepEqual([r.branch, r.head_sha, r.reason, r.created_at, r.cleared_at], ['ticket/bh-t1', 'aaa', 'push rejected', iso(NOW - 3600), null]);
    const p = await call(DB, '/api/pool-state/terminal', { method: 'PATCH', body: { project: 'alpha-os', key: 'BH-T1', head_sha: 'bbb', box: 'hub' } });
    assert.equal(p.status, 200);
    assert.equal((await term()).head_sha, 'bbb');
    const c = await call(DB, '/api/pool-state/terminal', { method: 'PATCH', body: { project: 'alpha-os', key: 'BH-T1', clear: true, why: 'head moved', box: 'hub-b' } });
    assert.equal(c.status, 200);
    r = await term();
    assert.equal(typeof r.cleared_at, 'string');
    assert.equal(r.cleared_why, 'head moved');
    assert.equal(r.head_sha, 'bbb', 'a clear keeps the verdict on record');
    assert.equal((await put({ branch: 'ticket/bh-t1', head_sha: 'ccc', reason: 'rejected again' })).status, 200);
    r = await term();
    assert.deepEqual([r.head_sha, r.cleared_at, r.cleared_why], ['ccc', null, null]);
    const miss = await call(DB, '/api/pool-state/terminal', { method: 'PATCH', body: { project: 'alpha-os', key: 'BH-NONE', clear: true, box: 'hub' } });
    assert.equal(miss.status, 404);
    assert.equal((await call(DB, '/api/pool-state/terminal', { method: 'PATCH', body: { project: 'alpha-os', key: 'BH-T1', box: 'hub' } })).status, 400, 'neither head_sha nor clear');
  });

  await t.test('W5 claim-machine stamps a claim that has no machine, and never overwrites another', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare("INSERT INTO build_queue (project,ticket_key,status,target,enqueued_at,updated_at,machine) VALUES (?,?,?,?,?,?,?)");
    ins.run('alpha-os', 'BH-R1', 'queued', 'fly', iso(NOW - 7200, 'T'), iso(NOW - 7200, 'T'), null);
    const stamp = (machine, key = 'BH-R1') => call(DB, '/api/pool-state/claim-machine', { method: 'PUT', body: { project: 'alpha-os', key, machine, box: 'hub' } });
    assert.equal((await stamp('1234567890abcd')).status, 404, 'a queued row is not a claim');
    db.prepare("UPDATE build_queue SET status='claimed' WHERE ticket_key='BH-R1'").run();
    const a = await stamp('1234567890abcd');
    assert.equal(a.status, 200); assert.equal(a.body.stamped, true);
    assert.equal(db.prepare("SELECT machine FROM build_queue WHERE ticket_key='BH-R1'").get().machine, '1234567890abcd');
    assert.equal((await stamp('1234567890abcd')).status, 200, 'the same machine again');
    assert.equal((await stamp('ffffffffffffff')).status, 409);
    assert.equal(db.prepare("SELECT machine FROM build_queue WHERE ticket_key='BH-R1'").get().machine, '1234567890abcd');
    assert.equal((await stamp('bad id!')).status, 400);
    assert.equal((await stamp('1234567890abcd', 'BH-NONE')).status, 404);
  });

  await t.test('W6 holds: first_seen survives, clear deletes, spawn until_at round-trips, bad input refused', async () => {
    const { DB } = await openDb();
    const put = (b) => call(DB, '/api/pool-state/holds', { method: 'PUT', body: { project: 'alpha-os', box: 'hub', ...b } });
    const holds = async () => (await get(DB, 'alpha-os')).body.holds;
    assert.equal((await put({ kind: 'ticket', key: 'BH-H1', ticket_id: '12', why: 'hold:body HOLD', first_seen: iso(NOW - 3600) })).status, 200);
    assert.equal((await put({ kind: 'ticket', key: 'BH-H1', ticket_id: '12', why: 'hold:body HOLD again', first_seen: iso(NOW) })).status, 200);
    let h = (await holds()).find((x) => x.kind === 'ticket' && x.key === 'BH-H1');
    assert.equal(h.first_seen, iso(NOW - 3600));
    assert.equal(h.why, 'hold:body HOLD again');
    assert.equal(typeof h.last_seen, 'string');
    assert.equal((await put({ kind: 'spawn', key: '', until_at: NOW + 1800, why: 'BH-1: RUNNER_EXHAUSTED' })).status, 200);
    h = (await holds()).find((x) => x.kind === 'spawn');
    assert.deepEqual([h.key, h.until_at, h.why], ['', NOW + 1800, 'BH-1: RUNNER_EXHAUSTED']);
    assert.equal((await put({ kind: 'spawn', key: '', until_at: NOW + 9999, why: 'other', if_absent: true })).status, 200);
    assert.equal((await holds()).find((x) => x.kind === 'spawn').until_at, NOW + 1800, 'if_absent never overwrites');
    const c = await call(DB, '/api/pool-state/holds', { method: 'PATCH', body: { project: 'alpha-os', kind: 'ticket', key: 'BH-H1', clear: true } });
    assert.equal(c.status, 200);
    assert.equal((await holds()).filter((x) => x.kind === 'ticket').length, 0);
    assert.equal((await put({ kind: 'nope', key: 'BH-H1', why: 'x' })).status, 400);
    assert.equal((await put({ kind: 'spawn', key: '', until_at: 'later', why: 'x' })).status, 400);
    assert.equal((await put({ kind: 'ticket', key: '', why: 'x' })).status, 400, 'a ticket hold names its key');
    const un = await call(DB, '/api/pool-state?project=alpha-os&since=0', { auth: false });
    assert.equal(un.status, 401);
  });
});
