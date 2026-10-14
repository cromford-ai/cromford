import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5750 (C4): the Orgo live-state store. bin/orgo-state.sh on the hub reads
// GET /computers per Orgo account and PUTs the list here; the /machines ORGO
// STATE column reads it back. Driven through the real worker.fetch against real
// SQLite and the real schema.sql, so the upsert and the tombstone are the SQL.
//   U1  a PUT upserts each computer on orgo_id (a second PUT updates, no dupes).
//   U2  a COMPLETE list tombstones (gone_at) an id it does not carry; never deletes.
//   U3  complete:false, or ok:false, tombstones nothing.
//   U4  an id that reappears in a list has gone_at cleared.
//   U5  a bad payload is 400 and writes nothing.
//   U6  GET shape, and 503 on an unapplied table.

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-10T12:00:00Z');
const T0 = '2026-10-10T12:00:00Z';

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return env;
}

async function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

// The shape GET /computers answers (bin/box-launch.sh, bin/lib/box-ops-orgo.sh):
// id, name, cpu, ram (GB), disk (GB), status, plus whatever else Orgo sends.
const pc = (id, over = {}) => ({ id, name: `fixture-box-${id}`, status: 'running', cpu: 4, ram: 16, disk: 100, region: 'fixture-region', ...over });
const put = (over = {}) => ({ account: 'acct-fixture', ok: true, complete: true, computers: [pc('c1'), pc('c2')], ...over });
const rows = (db) => db.prepare('SELECT * FROM orgo_computers ORDER BY orgo_id').all();
const reads = (db) => db.prepare('SELECT * FROM orgo_account_reads ORDER BY account').all();
const advance = (t, s) => t.mock.timers.tick(s * 1000);

test('U1: a PUT upserts each computer on orgo_id, and a second PUT updates in place', async (t) => {
  const env = await open(t); if (!env) return;
  let r = await call(env.DB, 'PUT', '/api/orgo-computers', put());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  let all = rows(env.db);
  assert.equal(all.length, 2);
  assert.deepEqual(
    { orgo_id: all[0].orgo_id, name: all[0].name, account: all[0].account, status: all[0].status, cpu: all[0].cpu, ram_gb: all[0].ram_gb, disk_gb: all[0].disk_gb, seen_at: all[0].seen_at, gone_at: all[0].gone_at },
    { orgo_id: 'c1', name: 'fixture-box-c1', account: 'acct-fixture', status: 'running', cpu: 4, ram_gb: 16, disk_gb: 100, seen_at: T0, gone_at: null },
  );
  assert.equal(JSON.parse(all[0].raw_json).region, 'fixture-region', 'the raw entry is kept');
  advance(t, 300);
  r = await call(env.DB, 'PUT', '/api/orgo-computers', put({ computers: [pc('c1', { status: 'stopped', cpu: 8 }), pc('c2')] }));
  assert.equal(r.status, 200);
  all = rows(env.db);
  assert.equal(all.length, 2, 'no duplicate rows');
  assert.equal(all[0].status, 'stopped');
  assert.equal(all[0].cpu, 8);
  assert.equal(all[0].seen_at, '2026-10-10T12:05:00Z');
  // A numeric id is stored as its string; an absent spec is NULL, never 0.
  r = await call(env.DB, 'PUT', '/api/orgo-computers', put({ account: 'acct-b', computers: [{ id: 42, name: 'n42' }] }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const n = env.db.prepare("SELECT * FROM orgo_computers WHERE orgo_id='42'").get();
  assert.equal(n.cpu, null); assert.equal(n.ram_gb, null); assert.equal(n.disk_gb, null); assert.equal(n.status, null);
  const rd = reads(env.db).find((x) => x.account === 'acct-fixture');
  assert.equal(rd.ok, 1); assert.equal(rd.complete, 1); assert.equal(rd.read_at, '2026-10-10T12:05:00Z');
});

test('U2: a complete list tombstones an id it does not carry, and deletes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  await call(env.DB, 'PUT', '/api/orgo-computers', put());
  await call(env.DB, 'PUT', '/api/orgo-computers', put({ account: 'acct-other', computers: [pc('x9')] }));
  advance(t, 300);
  const r = await call(env.DB, 'PUT', '/api/orgo-computers', put({ computers: [pc('c1')] }));
  assert.equal(r.status, 200);
  assert.equal(r.body.tombstoned, 1);
  const all = rows(env.db);
  assert.equal(all.length, 3, 'the missing row is kept, not deleted');
  const by = Object.fromEntries(all.map((x) => [x.orgo_id, x]));
  assert.equal(by.c2.gone_at, '2026-10-10T12:05:00Z');
  assert.equal(by.c2.seen_at, T0, 'the tombstoned row keeps its last seen_at');
  assert.equal(by.c1.gone_at, null);
  assert.equal(by.x9.gone_at, null, 'another account is never touched');
  // A later complete read does not move the first tombstone stamp.
  advance(t, 300);
  await call(env.DB, 'PUT', '/api/orgo-computers', put({ computers: [pc('c1')] }));
  assert.equal(env.db.prepare("SELECT gone_at FROM orgo_computers WHERE orgo_id='c2'").get().gone_at, '2026-10-10T12:05:00Z');
});

test('U3: complete:false or ok:false tombstones nothing', async (t) => {
  const env = await open(t); if (!env) return;
  await call(env.DB, 'PUT', '/api/orgo-computers', put());
  advance(t, 300);
  let r = await call(env.DB, 'PUT', '/api/orgo-computers', put({ complete: false, computers: [pc('c1')], detail: 'list capped at 1 of 2' }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.tombstoned, 0);
  assert.deepEqual(rows(env.db).map((x) => [x.orgo_id, x.gone_at]), [['c1', null], ['c2', null]]);
  let rd = reads(env.db)[0];
  assert.equal(rd.complete, 0); assert.equal(rd.ok, 1); assert.equal(rd.detail, 'list capped at 1 of 2');
  // A failed read: nothing at all changes on the computers.
  const before = rows(env.db);
  advance(t, 300);
  r = await call(env.DB, 'PUT', '/api/orgo-computers', put({ ok: false, complete: true, computers: [], detail: 'GET /computers HTTP 500' }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.tombstoned, 0);
  assert.deepEqual(rows(env.db), before, 'a failed read changes no computer row');
  rd = reads(env.db)[0];
  assert.equal(rd.ok, 0); assert.equal(rd.complete, 0, 'a failed read is never recorded complete');
  assert.equal(rd.read_at, '2026-10-10T12:10:00Z');
  assert.equal(rd.detail, 'GET /computers HTTP 500');
});

test('U4: an id that reappears in a list has gone_at cleared', async (t) => {
  const env = await open(t); if (!env) return;
  await call(env.DB, 'PUT', '/api/orgo-computers', put());
  advance(t, 300);
  await call(env.DB, 'PUT', '/api/orgo-computers', put({ computers: [pc('c1')] }));
  assert.notEqual(env.db.prepare("SELECT gone_at FROM orgo_computers WHERE orgo_id='c2'").get().gone_at, null);
  advance(t, 300);
  await call(env.DB, 'PUT', '/api/orgo-computers', put());
  const c2 = env.db.prepare("SELECT * FROM orgo_computers WHERE orgo_id='c2'").get();
  assert.equal(c2.gone_at, null);
  assert.equal(c2.seen_at, '2026-10-10T12:10:00Z');
});

test('U5: a bad payload is 400 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  const bad = [
    put({ computers: 'c1' }),
    put({ computers: { id: 'c1' } }),
    put({ computers: undefined }),
    put({ account: 'acct fixture' }),
    put({ account: 'a;b' }),
    put({ account: '' }),
    put({ account: 7 }),
    put({ account: 'a'.repeat(65) }),
    put({ ok: 'true' }),
    put({ ok: undefined }),
    put({ complete: 1 }),
    put({ computers: [pc('c1'), { name: 'no-id' }] }),
    put({ computers: [pc('c1'), pc('')] }),
    put({ computers: [pc('c1'), pc(null)] }),
    put({ computers: [pc('c1'), pc({ x: 1 })] }),
    put({ computers: [pc('c1'), 'c2'] }),
    put({ computers: [pc('c1'), pc('c1')] }),
    put({ computers: [pc('c1', { cpu: -1 })] }),
    put({ computers: [pc('c1', { ram: '16' })] }),
    put({ computers: [pc('c1', { disk: 1.5 })] }),
    put({ detail: 'x'.repeat(501) }),
    put({ computers: Array.from({ length: 501 }, (_, i) => pc(`c${i}`)) }),
  ];
  for (const b of bad) {
    const r = await call(env.DB, 'PUT', '/api/orgo-computers', b);
    assert.equal(r.status, 400, JSON.stringify(b).slice(0, 120));
    assert.equal(typeof r.body.error, 'string');
  }
  for (const raw of ['null', '[]', 'not json']) {
    const r = await call(env.DB, 'PUT', '/api/orgo-computers', raw);
    assert.equal(r.status, 400, raw);
  }
  assert.equal(rows(env.db).length, 0);
  assert.equal(reads(env.db).length, 0);
  // 500 entries is the bound, not over it: one batch, every statement under
  // D1's 100-bind limit (the shim throws above it).
  const r = await call(env.DB, 'PUT', '/api/orgo-computers', put({ computers: Array.from({ length: 500 }, (_, i) => pc(`c${i}`)) }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rows(env.db).length, 500);
});

test('U6: GET answers computers, accounts and as_of; 503 when the table is unapplied', async (t) => {
  const env = await open(t); if (!env) return;
  let r = await call(env.DB, 'GET', '/api/orgo-computers');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { computers: [], accounts: {}, as_of: T0, truncated: false });
  await call(env.DB, 'PUT', '/api/orgo-computers', put());
  advance(t, 60);
  await call(env.DB, 'PUT', '/api/orgo-computers', put({ account: 'acct-down', ok: false, complete: false, computers: [], detail: 'GET /computers HTTP 000' }));
  r = await call(env.DB, 'GET', '/api/orgo-computers');
  assert.equal(r.status, 200);
  assert.equal(r.body.as_of, '2026-10-10T12:01:00Z');
  assert.equal(r.body.computers.length, 2);
  assert.deepEqual(r.body.computers[0], {
    orgo_id: 'c1', name: 'fixture-box-c1', account: 'acct-fixture', status: 'running',
    cpu: 4, ram_gb: 16, disk_gb: 100, seen_at: T0, gone_at: null,
  });
  assert.equal('raw_json' in r.body.computers[0], false, 'raw_json is not served');
  assert.deepEqual(r.body.accounts['acct-fixture'], { read_at: T0, ok: true, complete: true, detail: null });
  assert.deepEqual(r.body.accounts['acct-down'], { read_at: '2026-10-10T12:01:00Z', ok: false, complete: false, detail: 'GET /computers HTTP 000' });
  env.db.exec('DROP TABLE orgo_computers');
  r = await call(env.DB, 'GET', '/api/orgo-computers');
  assert.equal(r.status, 503);
  assert.match(r.body.error, /orgo_computers schema not applied/);
  r = await call(env.DB, 'PUT', '/api/orgo-computers', put());
  assert.equal(r.status, 503);
});
