// BH-7305 (BH-7191 child C4): each job start record stores the harness sha the
// job ran. A lane_runs claim, a build_queue claim-machine stamp and a
// lane_machines start record take an optional `harness_commit`; only a 7-40
// char hex value (trimmed, lower-cased) is stored, anything else stores NULL and
// the request answers as it does without the field. GET /api/lane-runs,
// GET /api/lane-runs/:id and GET /api/lane-fleet/machines return it.
// Driven through the REAL router on a fresh node:sqlite database per case. The
// shell writers are pinned by tests/fly-sha-flags.bh-7191-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const SHA40 = '0123456789abcdef0123456789abcdef01234567';
const SHA40B = 'fedcba9876543210fedcba9876543210fedcba98';

const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const enqueue = (DB, lane = 'demo', project = 'p1') =>
  call(DB, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] });
const claim = (DB, machine, extra = {}) => call(DB, 'POST', '/api/lane-runs/claim', { machine, ...extra });
const listRun = async (DB, id) => {
  const r = await call(DB, 'GET', '/api/lane-runs?limit=50');
  assert.equal(r.status, 200);
  return r.body.runs.find((x) => x.id === id);
};
const stamp = (DB, project, key, machine, extra = {}) =>
  call(DB, 'PUT', '/api/pool-state/claim-machine', { project, key, machine, box: 'hub', ...extra });
const record = (DB, body) => call(DB, 'POST', '/api/lane-fleet/machines', body);
const machineOf = async (DB, mid) => {
  const r = await call(DB, 'GET', '/api/lane-fleet/machines');
  assert.equal(r.status, 200);
  return r.body.machines.find((m) => m.machine_id === mid);
};
const col = (db, sql, ...args) => {
  const row = db.prepare(sql).get(...args);
  return row ? row.harness_commit : undefined;
};
const seedQueue = (db, project, key, status = 'claimed', machine = null) =>
  db.prepare("INSERT INTO build_queue (project,ticket_key,status,target,enqueued_at,updated_at,machine) VALUES (?,?,?,?,?,?,?)")
    .run(project, key, status, 'fly', '2026-11-02T00:00:00Z', '2026-11-02T00:00:00Z', machine);

test('BH-7305 job start records carry the harness sha', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 a claim with a 40-hex sha: GET /api/lane-runs returns it', async () => {
    const { DB } = await openDb();
    const e = await enqueue(DB);
    const c = await claim(DB, 'm1', { harness_commit: SHA40 });
    assert.equal(c.status, 200);
    assert.equal(c.body.id, e.body.id);
    assert.equal((await listRun(DB, e.body.id)).harness_commit, SHA40);
  });

  await t.test('R2 GET /api/lane-runs/:id carries the same value', async () => {
    const { DB } = await openDb();
    const e = await enqueue(DB);
    await claim(DB, 'm1', { harness_commit: SHA40 });
    const g = await call(DB, 'GET', `/api/lane-runs/${e.body.id}`);
    assert.equal(g.status, 200);
    assert.equal(g.body.run.harness_commit, SHA40);
  });

  await t.test('R3 harness_commit "main": the same 200 claim answer, the column NULL', async () => {
    const a = await openDb(); const b = await openDb();
    const ea = await enqueue(a.DB); const eb = await enqueue(b.DB);
    const ca = await claim(a.DB, 'm1', { harness_commit: 'main' });
    const cb = await claim(b.DB, 'm1');
    assert.equal(ca.status, 200);
    assert.equal(ca.body.id, ea.body.id);
    assert.deepEqual(Object.keys(ca.body).sort(), Object.keys(cb.body).sort(), 'the answer gains no field');
    assert.equal(ca.body.lane, cb.body.lane);
    assert.equal(ca.body.lease_until, cb.body.lease_until);
    assert.equal(ca.body.attempts, cb.body.attempts);
    assert.equal(eb.body.id, ea.body.id);
    assert.equal((await listRun(a.DB, ea.body.id)).harness_commit, null);
  });

  await t.test('R4 a claim with no field: null in both reads', async () => {
    const { DB } = await openDb();
    const e = await enqueue(DB);
    await claim(DB, 'm1');
    const run = await listRun(DB, e.body.id);
    assert.ok(Object.hasOwn(run, 'harness_commit'), 'the list carries the key');
    assert.equal(run.harness_commit, null);
    assert.equal((await call(DB, 'GET', `/api/lane-runs/${e.body.id}`)).body.run.harness_commit, null);
  });

  await t.test('R5 a released row re-claimed by a machine with no sha: null (per-attempt overwrite)', async () => {
    const { DB } = await openDb();
    const e = await enqueue(DB);
    await claim(DB, 'm1', { harness_commit: SHA40 });
    const r = await call(DB, 'POST', `/api/lane-runs/${e.body.id}/release`, { machine: 'm1' });
    assert.equal(r.status, 200);
    const c2 = await claim(DB, 'm2');
    assert.equal(c2.body.id, e.body.id);
    const run = await listRun(DB, e.body.id);
    assert.equal(run.claimed_by, 'm2');
    assert.equal(run.harness_commit, null);
  });

  await t.test('R6 a 204 claim (nothing queued) answers as before', async () => {
    const { DB } = await openDb();
    const c = await claim(DB, 'm1', { harness_commit: SHA40 });
    assert.equal(c.status, 204);
  });

  const V = [
    ['V1 40-hex', SHA40, SHA40],
    ['V2 7-hex', 'abc1234', 'abc1234'],
    ['V3 upper case', 'ABC1234DEF', 'abc1234def'],
    ['V4 padded', ' abc1234\n', 'abc1234'],
    ['V5 6-hex', 'abc123', null],
    ['V6 41-hex', `${SHA40}a`, null],
    ['V7 non-hex', 'abc123g', null],
    ['V8 a number', 1234567, null],
    ['V9 empty string', '', null],
    ['V10 unknown', 'unknown', null],
  ];
  for (const [name, input, want] of V) {
    await t.test(`${name} through the claim route -> ${want}`, async () => {
      const { db, DB } = await openDb();
      const e = await enqueue(DB);
      const c = await claim(DB, 'm1', { harness_commit: input });
      assert.equal(c.status, 200);
      assert.equal(col(db, 'SELECT harness_commit FROM lane_runs WHERE id=?', e.body.id), want);
    });
  }

  await t.test('Q1 claim-machine with a sha stores it on the build_queue row', async () => {
    const { db, DB } = await openDb();
    seedQueue(db, 'alpha-os', 'BH-1');
    const s = await stamp(DB, 'alpha-os', 'BH-1', '1234567890abcd', { harness_commit: SHA40 });
    assert.equal(s.status, 200);
    assert.equal(s.body.stamped, true);
    assert.equal(col(db, "SELECT harness_commit FROM build_queue WHERE project='alpha-os' AND ticket_key='BH-1'"), SHA40);
  });

  await t.test('Q2 claim-machine with "main": stamped, column NULL', async () => {
    const { db, DB } = await openDb();
    seedQueue(db, 'alpha-os', 'BH-1');
    const s = await stamp(DB, 'alpha-os', 'BH-1', '1234567890abcd', { harness_commit: 'main' });
    assert.equal(s.status, 200);
    assert.equal(s.body.stamped, true);
    assert.equal(col(db, "SELECT harness_commit FROM build_queue WHERE project='alpha-os' AND ticket_key='BH-1'"), null);
  });

  await t.test('Q3 wrong tenant: stamping project A leaves project B (same key) NULL', async () => {
    const { db, DB } = await openDb();
    seedQueue(db, 'alpha-os', 'BH-1'); seedQueue(db, 'beta-os', 'BH-1');
    await stamp(DB, 'alpha-os', 'BH-1', '1234567890abcd', { harness_commit: SHA40 });
    assert.equal(col(db, "SELECT harness_commit FROM build_queue WHERE project='alpha-os' AND ticket_key='BH-1'"), SHA40);
    assert.equal(col(db, "SELECT harness_commit FROM build_queue WHERE project='beta-os' AND ticket_key='BH-1'"), null);
  });

  await t.test('Q4 a 409 (another machine) writes no sha', async () => {
    const { db, DB } = await openDb();
    seedQueue(db, 'alpha-os', 'BH-1', 'claimed', 'aaaaaaaaaaaaaa');
    const s = await stamp(DB, 'alpha-os', 'BH-1', '1234567890abcd', { harness_commit: SHA40 });
    assert.equal(s.status, 409);
    assert.equal(col(db, "SELECT harness_commit FROM build_queue WHERE project='alpha-os' AND ticket_key='BH-1'"), null);
  });

  await t.test('F1 a starting record with a sha: GET /api/lane-fleet/machines returns it', async () => {
    const { DB } = await openDb();
    const r = await record(DB, { machine_id: 'fixturem0001', state: 'starting', harness_commit: SHA40 });
    assert.equal(r.status, 201);
    assert.equal((await machineOf(DB, 'fixturem0001')).harness_commit, SHA40);
  });

  await t.test('F2 a live POST replaces the sha; a stopped POST leaves it', async () => {
    const { db, DB } = await openDb();
    await record(DB, { machine_id: 'fixturem0001', state: 'starting', harness_commit: SHA40 });
    const u = await record(DB, { machine_id: 'fixturem0001', state: 'started', harness_commit: SHA40B });
    assert.equal(u.status, 200);
    assert.equal((await machineOf(DB, 'fixturem0001')).harness_commit, SHA40B);
    const s = await record(DB, { machine_id: 'fixturem0001', state: 'stopped', harness_commit: SHA40 });
    assert.equal(s.status, 200);
    assert.equal(col(db, "SELECT harness_commit FROM lane_machines WHERE machine_id='fixturem0001'"), SHA40B);
    const s2 = await record(DB, { machine_id: 'fixturem0001', state: 'starting' });
    assert.equal(s2.status, 200);
    assert.equal((await machineOf(DB, 'fixturem0001')).harness_commit, null, 'a live POST with no sha writes NULL');
  });

  await t.test('F3 a POST with "unknown": 201, GET shows null', async () => {
    const { DB } = await openDb();
    const r = await record(DB, { machine_id: 'fixturem0001', state: 'starting', harness_commit: 'unknown' });
    assert.equal(r.status, 201);
    const m = await machineOf(DB, 'fixturem0001');
    assert.ok(Object.hasOwn(m, 'harness_commit'), 'the machine carries the key');
    assert.equal(m.harness_commit, null);
  });

  await t.test('F4 wrong row: a POST for machine X leaves machine Y unchanged', async () => {
    const { db, DB } = await openDb();
    await record(DB, { machine_id: 'fixturemyyyy', state: 'starting', harness_commit: SHA40 });
    await record(DB, { machine_id: 'fixturemxxxx', state: 'starting', harness_commit: SHA40B });
    await record(DB, { machine_id: 'fixturemxxxx', state: 'started' });
    assert.equal(col(db, "SELECT harness_commit FROM lane_machines WHERE machine_id='fixturemyyyy'"), SHA40);
    assert.equal(col(db, "SELECT harness_commit FROM lane_machines WHERE machine_id='fixturemxxxx'"), null);
  });
});
