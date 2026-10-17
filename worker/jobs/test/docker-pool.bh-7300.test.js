// BH-7300 (slice C0): the docker-pool claim lease. POST /api/docker-pool/
// {claim, heartbeat, release, sweep}, the docker_pool_leases table, its seeds,
// its retention rule. Driven through the REAL worker.fetch on node:sqlite with
// the composed jobs schema (worker/jobs/schema.d/). The clock is the worker's,
// so a past lease is written as 2000-01-01 and a boundary case binds the
// route's exported SQL with a fixed t.
//   K1 seeds and indexes
//   C1-C13 claim decision rule (kill, max rows, target, race, project, key)
//   H1-H7 heartbeat decision rule      S1-S6 sweep decision rule
//   R1-R3 release and retention        E1 EXPLAIN QUERY PLAN at 5,000 + 5,000 rows
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7300';
const PAST = '2000-01-01T00:00:00Z';
const SQL = await import('../src/routes/docker-pool.js').catch(() => ({}));

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, body, { method = 'POST', bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const dp = (DB, op, body) => call(DB, `/api/docker-pool/${op}`, body);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-17T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const enqueue = (db, { project = 'p1', key, target = 'fly', status = 'queued', claimedBy = null, claimedAt = null, attempt = 0 }) => db.prepare(
  `INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt, requested_by, claimed_by, claimed_at, enqueued_at, updated_at)
   VALUES (?,?,?,?,?,?,'hub-fixture',?,?,'2026-10-17T00:00:00Z','2026-10-17T00:00:00Z')`
).run(project, key, `id-${key}`, status, target, attempt, claimedBy, claimedAt);
const row = (db, key, project = 'p1') => db.prepare('SELECT * FROM build_queue WHERE project=? AND ticket_key=?').get(project, key);
const leases = (db, where = '1=1', ...b) => db.prepare(`SELECT * FROM docker_pool_leases WHERE ${where} ORDER BY id`).all(...b);
const secs = (a, b) => (Date.parse(b) - Date.parse(a)) / 1000;
const claim = (DB, key, box = 'mac-a', project = 'p1') => dp(DB, 'claim', { project, key, box });

test('K1 the schema seeds the four settings rows and the four lease indexes', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(val('docker_pool.max_concurrent'), '0');
  assert.equal(val('docker_pool.kill'), '0');
  assert.equal(val('docker_pool.lease_s'), '300');
  assert.equal(val('retention.docker_pool_leases.days'), '30');
  const ix = db.prepare("SELECT name, \"unique\" AS u, partial FROM pragma_index_list('docker_pool_leases')").all();
  const names = ix.map((r) => r.name).sort();
  assert.deepEqual(names, ['idx_docker_pool_leases_box', 'idx_docker_pool_leases_due', 'idx_docker_pool_leases_ended', 'uq_docker_pool_leases_live']);
  const live = ix.find((r) => r.name === 'uq_docker_pool_leases_live');
  assert.equal(live.u, 1); assert.equal(live.partial, 1);
});

test('C1 kill 1 refuses the claim with reason killed and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-1' });
  setting(db, 'docker_pool.max_concurrent.mac-a', 2);
  setting(db, 'docker_pool.kill', 1);
  const r = await claim(DB, 'K-1');
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'killed'); assert.equal(r.body.refused, true);
  assert.notEqual(r.body.claimed, true);
  assert.equal(row(db, 'K-1').status, 'queued');
  assert.equal(leases(db).length, 0);
});

test('C2 the seeded defaults (fleet max 0, no box row) refuse with reason off (AT4)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-2' });
  const r = await claim(DB, 'K-2');
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'off');
  assert.equal(row(db, 'K-2').status, 'queued');
  assert.equal(row(db, 'K-2').claimed_by, null);
  assert.equal(leases(db).length, 0);
});

test('C3 a box row of 2 claims: the row is claimed by the box and one active lease lives lease_s', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-3', attempt: 2 });
  setting(db, 'docker_pool.max_concurrent.mac-a', 2);
  const r = await claim(DB, 'K-3');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.queued.ticket_key, 'K-3');
  assert.equal(r.body.queued.ticket_id, 'id-K-3');
  assert.equal(r.body.queued.attempt, 2);
  const q = row(db, 'K-3');
  assert.equal(q.status, 'claimed'); assert.equal(q.claimed_by, 'mac-a'); assert.equal(q.attempt, 2);
  const l = leases(db);
  assert.equal(l.length, 1);
  assert.equal(l[0].status, 'active'); assert.equal(l[0].box, 'mac-a');
  assert.equal(l[0].claimed_at, q.claimed_at);
  assert.equal(secs(l[0].claimed_at, l[0].lease_until), 300);
  assert.equal(r.body.lease_until, l[0].lease_until);
  // docker_pool.lease_s moves the lease length; a bad value is the code default.
  setting(db, 'docker_pool.lease_s', 120);
  enqueue(db, { key: 'K-3b' });
  await claim(DB, 'K-3b');
  const l2 = leases(db, 'ticket_key=?', 'K-3b')[0];
  assert.equal(secs(l2.claimed_at, l2.lease_until), 120);
  setting(db, 'docker_pool.lease_s', 'abc');
  enqueue(db, { key: 'K-3c', project: 'p2' });
  await claim(DB, 'K-3c', 'mac-z', 'p2');
  // mac-z has no row and the fleet row is 0: off, so set one and retry
  setting(db, 'docker_pool.max_concurrent', 3);
  const r3 = await claim(DB, 'K-3c', 'mac-z', 'p2');
  assert.equal(r3.status, 200, 'C3 the fleet row applies to a box with no row of its own');
  const l3 = leases(db, 'ticket_key=?', 'K-3c')[0];
  assert.equal(secs(l3.claimed_at, l3.lease_until), 300);
});

test('C4 a box row of 0 wins over a fleet row of 3: off', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-4' });
  setting(db, 'docker_pool.max_concurrent', 3);
  setting(db, 'docker_pool.max_concurrent.mac-a', 0);
  const r = await claim(DB, 'K-4');
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'off');
  assert.equal(leases(db).length, 0);
});

test("C5 a box row of '', abc, -1, 1.5 or 65 is off, never a guess", async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-5' });
  setting(db, 'docker_pool.max_concurrent', 3);
  for (const v of ['', 'abc', '-1', '1.5', '65']) {
    setting(db, 'docker_pool.max_concurrent.mac-a', v);
    const r = await claim(DB, 'K-5');
    assert.equal(r.status, 409, `value ${JSON.stringify(v)}`); assert.equal(r.body.reason, 'off', `value ${JSON.stringify(v)}`);
  }
  assert.equal(row(db, 'K-5').status, 'queued');
  assert.equal(leases(db).length, 0);
  setting(db, 'docker_pool.max_concurrent.mac-a', '64');
  assert.equal((await claim(DB, 'K-5')).status, 200, '64 is the top of the range');
});

test('C6 the cap counts only this box: 2 active on mac-a is full; 1 on mac-a and 2 on mac-b claims', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  setting(db, 'docker_pool.max_concurrent', 2);
  for (const k of ['A1', 'A2', 'A3', 'B1', 'B2']) enqueue(db, { key: k });
  assert.equal((await claim(DB, 'A1')).status, 200);
  assert.equal((await claim(DB, 'A2')).status, 200);
  const full = await claim(DB, 'A3');
  assert.equal(full.status, 409); assert.equal(full.body.reason, 'full');
  assert.equal(row(db, 'A3').status, 'queued');
  assert.equal((await claim(DB, 'B1', 'mac-b')).status, 200);
  assert.equal((await claim(DB, 'B2', 'mac-b')).status, 200);
  // free one mac-a slot: 1 active on mac-a, 2 on mac-b -> mac-a claims
  assert.equal((await dp(DB, 'release', { project: 'p1', key: 'A1', box: 'mac-a', status: 'done' })).status, 200);
  const r = await claim(DB, 'A3');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(leases(db, "box='mac-a' AND status='active'").length, 2);
});

test('C7 a target=local row is not_pool and stays queued', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-7', target: 'local' });
  setting(db, 'docker_pool.max_concurrent', 2);
  const r = await claim(DB, 'K-7');
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'not_pool');
  assert.equal(row(db, 'K-7').status, 'queued');
  assert.equal(leases(db).length, 0);
});

test('C8 two boxes race for one row: exactly one 200, one 409 lost, one lease (AT1)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-8' });
  setting(db, 'docker_pool.max_concurrent', 1);
  const [a, b] = await Promise.all([claim(DB, 'K-8', 'mac-a'), claim(DB, 'K-8', 'mac-b')]);
  const codes = [a.status, b.status].sort();
  assert.deepEqual(codes, [200, 409]);
  const loser = a.status === 409 ? a : b;
  const winner = a.status === 200 ? 'mac-a' : 'mac-b';
  assert.equal(loser.body.reason, 'lost');
  assert.equal(row(db, 'K-8').claimed_by, winner);
  const l = leases(db);
  assert.equal(l.length, 1); assert.equal(l[0].box, winner);
});

test("C9 the same key queued in p2 only: a claim naming p1 is 404 and the p2 row is untouched", async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-9', project: 'p2' });
  setting(db, 'docker_pool.max_concurrent', 2);
  const r = await claim(DB, 'K-9', 'mac-a', 'p1');
  assert.equal(r.status, 404);
  assert.equal(row(db, 'K-9', 'p2').status, 'queued');
  assert.equal(row(db, 'K-9', 'p2').claimed_by, null);
  assert.equal(leases(db).length, 0);
});

test('C10 a second active lease for one key fails on the partial unique index; an ended one does not', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const ins = db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until)
                          VALUES ('p1','K-10',?,?,'2026-10-17T00:00:00Z','2026-10-17T00:00:00Z','2026-10-17T00:05:00Z')`);
  ins.run('mac-a', 'active');
  assert.throws(() => ins.run('mac-b', 'active'), /UNIQUE/);
  ins.run('mac-b', 'expired');
  assert.equal(leases(db).length, 2);
});

test('C11 a claim with no key, no project or no box is 400 and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-11' });
  setting(db, 'docker_pool.max_concurrent', 2);
  for (const body of [{ project: 'p1', box: 'mac-a' }, { key: 'K-11', box: 'mac-a' }, { project: 'p1', key: 'K-11' }, { project: 'p1', key: 'bad key', box: 'mac-a' }]) {
    const r = await dp(DB, 'claim', body);
    assert.equal(r.status, 400, JSON.stringify(body));
  }
  assert.equal(row(db, 'K-11').status, 'queued');
  assert.equal(leases(db).length, 0);
  assert.equal((await call(DB, '/api/docker-pool/claim', { project: 'p1', key: 'K-11', box: 'mac-a' }, { bearer: false })).status, 401);
});

test("C12 after a docker claim the hub pool's keyed claim of the same row is refused (AT1, hub side)", async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-12' });
  setting(db, 'docker_pool.max_concurrent', 1);
  assert.equal((await claim(DB, 'K-12')).status, 200);
  // The keyed claim reads only a `queued` row, so a row the box holds is 404
  // (queue_claim rc 2). bin/fly-pool.sh spawn_one reads rc 2 and rc 9 alike:
  // no machine is spawned.
  const r = await call(DB, '/api/queue/claim', { project: 'p1', box: 'fly-pool', target: 'fly', key: 'K-12' });
  assert.equal(r.status, 404); assert.notEqual(r.body.claimed, true);
  assert.equal(row(db, 'K-12').claimed_by, 'mac-a');
  assert.equal(row(db, 'K-12').status, 'claimed');
});

test('C13 a lease left active on a row the 360-min watchdog requeued is ended by the next claim', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'K-13' });
  setting(db, 'docker_pool.max_concurrent', 2);
  assert.equal((await claim(DB, 'K-13')).status, 200);
  // queue_release: PATCH to queued, the watchdog's release path
  assert.equal((await call(DB, '/api/queue', { project: 'p1', key: 'K-13', status: 'queued' }, { method: 'PATCH' })).status, 200);
  const r = await claim(DB, 'K-13', 'mac-b');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const l = leases(db);
  assert.equal(l.length, 2);
  assert.equal(l[0].status, 'expired'); assert.equal(l[0].box, 'mac-a');
  assert.equal(l[1].status, 'active'); assert.equal(l[1].box, 'mac-b');
});

test('H1 the claimer beats: 200 and lease_until moves to t + lease_s', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'H-1' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'H-1');
  db.prepare("UPDATE docker_pool_leases SET lease_until='2099-01-01T00:00:00Z', heartbeat_at='2026-01-01T00:00:00Z'").run();
  const r = await dp(DB, 'heartbeat', { project: 'p1', key: 'H-1', box: 'mac-a' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const l = leases(db)[0];
  assert.equal(l.status, 'active');
  assert.equal(secs(l.heartbeat_at, l.lease_until), 300);
  assert.equal(r.body.lease_until, l.lease_until);
});

test('H2 the boundary: lease_until exactly t extends; 1 s before t does not', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.ok(SQL.HEARTBEAT_SQL, 'HEARTBEAT_SQL is exported');
  const T = '2026-10-17T10:00:00Z', C = '2026-10-17T09:55:00Z';
  enqueue(db, { key: 'H-2', status: 'claimed', claimedBy: 'mac-a', claimedAt: C });
  db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until)
              VALUES ('p1','H-2','mac-a','active',?,?,?)`).run(C, C, T);
  const run = (t0) => db.prepare(SQL.HEARTBEAT_SQL).run('p1', 'H-2', 'mac-a', t0, '2026-10-17T10:05:00Z').changes;
  assert.equal(run('2026-10-17T10:00:01Z'), 0, '1 s after lease_until: expired');
  assert.equal(run(T), 1, 'lease_until == t: still live');
});

test('H3 an expired lease that was not swept: 409 lost/expired, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'H-3' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'H-3');
  db.prepare('UPDATE docker_pool_leases SET lease_until=?').run(PAST);
  const before = JSON.stringify(leases(db));
  const r = await dp(DB, 'heartbeat', { project: 'p1', key: 'H-3', box: 'mac-a' });
  assert.equal(r.status, 409); assert.equal(r.body.error, 'lost'); assert.equal(r.body.reason, 'expired');
  assert.equal(JSON.stringify(leases(db)), before);
});

test('H4 the row was released and reclaimed by fly: 409 lost/row_moved', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'H-4' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'H-4');
  await call(DB, '/api/queue', { project: 'p1', key: 'H-4', status: 'queued' }, { method: 'PATCH' });
  assert.equal((await call(DB, '/api/queue/claim', { project: 'p1', box: 'fly', target: 'fly', key: 'H-4' })).status, 200);
  const r = await dp(DB, 'heartbeat', { project: 'p1', key: 'H-4', box: 'mac-a' });
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'row_moved');
  assert.equal(row(db, 'H-4').claimed_by, 'fly');
});

test('H5 another box beats a lease it does not hold: 409 not_claimer; H6 no lease: 409 no_lease', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'H-5' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'H-5');
  const before = JSON.stringify(leases(db));
  const r = await dp(DB, 'heartbeat', { project: 'p1', key: 'H-5', box: 'mac-b' });
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'not_claimer');
  assert.equal(JSON.stringify(leases(db)), before);
  const n = await dp(DB, 'heartbeat', { project: 'p1', key: 'H-none', box: 'mac-a' });
  assert.equal(n.status, 409); assert.equal(n.body.reason, 'no_lease');
});

test('H7 kill 1: the heartbeat ends the lease killed and puts the row back on the queue', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'H-7' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'H-7');
  setting(db, 'docker_pool.kill', 1);
  const r = await dp(DB, 'heartbeat', { project: 'p1', key: 'H-7', box: 'mac-a' });
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'killed');
  assert.equal(leases(db)[0].status, 'killed');
  assert.ok(leases(db)[0].ended_at);
  const q = row(db, 'H-7');
  assert.equal(q.status, 'queued'); assert.equal(q.claimed_by, null); assert.equal(q.claimed_at, null);
});

test('S1 an expired lease is swept: the row is requeued with no claimant, the lease ends expired (AT2)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'S-1', attempt: 1 });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'S-1');
  db.prepare('UPDATE docker_pool_leases SET lease_until=?').run(PAST);
  const r = await dp(DB, 'sweep', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.requeued, 1);
  assert.deepEqual(r.body.expired, [{ project: 'p1', key: 'S-1', box: 'mac-a', requeued: true }]);
  const q = row(db, 'S-1');
  assert.equal(q.status, 'queued'); assert.equal(q.claimed_by, null); assert.equal(q.claimed_at, null);
  assert.equal(q.attempt, 1, 'attempt is not changed');
  assert.match(q.reason, /docker-pool lease of mac-a expired/);
  const l = leases(db)[0];
  assert.equal(l.status, 'expired'); assert.ok(l.ended_at);
  // the freed slot claims again
  assert.equal((await claim(DB, 'S-1', 'mac-a')).status, 200);
});

test('S2 the boundary: a lease with lease_until exactly t is kept', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.ok(SQL.SWEEP_SELECT_SQL, 'SWEEP_SELECT_SQL is exported');
  const T = '2026-10-17T10:00:00Z';
  db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until)
              VALUES ('p1','S-2a','mac-a','active',?,?,?), ('p1','S-2b','mac-a','active',?,?,?)`)
    .run(T, T, T, T, T, '2026-10-17T09:59:59Z');
  const due = db.prepare(SQL.SWEEP_SELECT_SQL).all(T, 50).map((r) => r.ticket_key);
  assert.deepEqual(due, ['S-2b']);
});

test('S3 two sweeps: requeued 1, then 0 — the ticket is requeued once (AT2)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'S-3' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'S-3');
  db.prepare('UPDATE docker_pool_leases SET lease_until=?').run(PAST);
  const a = await dp(DB, 'sweep', {});
  const b = await dp(DB, 'sweep', {});
  assert.equal(a.body.requeued, 1);
  assert.equal(b.body.requeued, 0); assert.deepEqual(b.body.expired, []);
  assert.equal(row(db, 'S-3').status, 'queued');
});

test('S4 an old due lease never requeues a newer claim of the same key by the same box', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'S-4', status: 'claimed', claimedBy: 'mac-a', claimedAt: '2026-10-02T00:00:00Z' });
  db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until)
              VALUES ('p1','S-4','mac-a','active','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z',?)`).run(PAST);
  const r = await dp(DB, 'sweep', {});
  assert.equal(r.body.requeued, 0);
  assert.deepEqual(r.body.expired, [{ project: 'p1', key: 'S-4', box: 'mac-a', requeued: false }]);
  assert.equal(row(db, 'S-4').status, 'claimed');
  assert.equal(leases(db)[0].status, 'expired');
});

test('S5 60 due leases: a sweep handles 50 and says backlog; the next handles 10', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const ins = db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until)
                          VALUES ('p1',?,'mac-a','active','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z',?)`);
  for (let i = 0; i < 60; i++) {
    enqueue(db, { key: `S5-${i}`, status: 'claimed', claimedBy: 'mac-a', claimedAt: '2026-10-01T00:00:00Z' });
    ins.run(`S5-${i}`, PAST);
  }
  const a = await dp(DB, 'sweep', {});
  assert.equal(a.body.expired.length, 50); assert.equal(a.body.requeued, 50); assert.equal(a.body.backlog, true);
  assert.equal(leases(db, "status='active'").length, 10);
  const b = await dp(DB, 'sweep', {});
  assert.equal(b.body.expired.length, 10); assert.equal(b.body.requeued, 10); assert.equal(b.body.backlog, false);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM build_queue WHERE status='queued'").get().n, 60);
});

test('S6 a row queue_done already closed: the lease expires and nothing is requeued', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'S-6' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'S-6');
  assert.equal((await call(DB, '/api/queue', { project: 'p1', key: 'S-6', status: 'done' }, { method: 'PATCH' })).status, 200);
  db.prepare('UPDATE docker_pool_leases SET lease_until=?').run(PAST);
  const r = await dp(DB, 'sweep', {});
  assert.equal(r.body.requeued, 0);
  assert.equal(r.body.expired[0].requeued, false);
  assert.equal(row(db, 'S-6').status, 'done');
});

test('R1 release queued: the row goes back on the queue and the lease ends released; a bad status is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'R-1' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'R-1');
  assert.equal((await dp(DB, 'release', { project: 'p1', key: 'R-1', box: 'mac-a', status: 'failed' })).status, 400);
  assert.equal((await dp(DB, 'release', { project: 'p1', key: 'R-1', box: 'mac-b', status: 'queued' })).status, 409);
  assert.equal(row(db, 'R-1').status, 'claimed');
  const r = await dp(DB, 'release', { project: 'p1', key: 'R-1', box: 'mac-a', status: 'queued', reason: 'SIGTERM hand-off' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.requeued, 1);
  const q = row(db, 'R-1');
  assert.equal(q.status, 'queued'); assert.equal(q.claimed_by, null);
  assert.match(q.reason, /SIGTERM hand-off/);
  assert.equal(leases(db)[0].status, 'released');
  // a retried release finds no live lease
  assert.equal((await dp(DB, 'release', { project: 'p1', key: 'R-1', box: 'mac-a', status: 'queued' })).status, 409);
});

test('R2 release done: the lease ends done and the row is left to queue_done', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'R-2' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'R-2');
  const r = await dp(DB, 'release', { project: 'p1', key: 'R-2', box: 'mac-a', status: 'done' });
  assert.equal(r.status, 200);
  assert.equal(leases(db)[0].status, 'done');
  assert.equal(row(db, 'R-2').status, 'claimed');
  assert.equal(row(db, 'R-2').claimed_by, 'mac-a');
});

test('R3 retention rule docker_pool_leases.ended deletes old ended leases and keeps the active one', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  enqueue(db, { key: 'R-3' });
  setting(db, 'docker_pool.max_concurrent', 1);
  await claim(DB, 'R-3');
  db.prepare('UPDATE docker_pool_leases SET lease_until=?').run(PAST);
  await dp(DB, 'sweep', {});
  await claim(DB, 'R-3');
  db.prepare("UPDATE docker_pool_leases SET ended_at=? WHERE status='expired'").run(PAST);
  // an active lease with an old claimed_at is never a candidate
  db.prepare("UPDATE docker_pool_leases SET claimed_at=? WHERE status='active'").run(PAST);
  setting(db, 'retention.dry_run', 0);
  setting(db, 'retention.docker_pool_leases.days', 1);
  const r = await call(DB, '/api/retention/run', {});
  assert.equal(r.status, 200);
  const rule = r.body.rules.find((x) => x.rule === 'docker_pool_leases.ended');
  assert.ok(rule, 'the rule ran');
  assert.equal(rule.removed, 1); assert.equal(rule.error, null);
  const left = leases(db);
  assert.equal(left.length, 1); assert.equal(left[0].status, 'active');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule='docker_pool_leases.ended'").get().n, 1);
});

test('E1 at 5,000 leases and 5,000 queue rows every lease statement uses an index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.ok(SQL.CLAIM_SQL, 'the route exports its SQL');
  db.exec('BEGIN');
  const q = db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt, claimed_by, claimed_at, enqueued_at, updated_at)
                        VALUES (?,?,?,?,'fly',0,?,?,'2026-10-01T00:00:00Z','2026-10-01T00:00:00Z')`);
  const l = db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until, ended_at)
                        VALUES (?,?,?,?,?,?,?,?)`);
  const ST = ['done', 'expired', 'released', 'killed', 'active'];
  for (let i = 0; i < 5000; i++) {
    const p = `p${i % 13}`, k = `E-${i}`, box = `box-${i % 20}`, st = ST[i % ST.length];
    const at = `2026-10-${String(1 + (i % 28)).padStart(2, '0')}T00:00:00Z`;
    q.run(p, k, `id-${i}`, st === 'active' ? 'claimed' : (i % 2 ? 'done' : 'queued'), st === 'active' ? box : null, st === 'active' ? at : null);
    l.run(p, k, box, st, at, at, at, st === 'active' ? null : at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const T = '2026-10-17T10:00:00Z', ids = JSON.stringify([5, 10, 15]);
  const plans = {
    claim: plan(db, SQL.CLAIM_SQL, 'p1', 'E-1', 'box-1', T, 2),
    lease_insert: plan(db, SQL.LEASE_INSERT_SQL, 'p1', 'E-1', 'box-1', T, T),
    orphan_end: plan(db, SQL.ORPHAN_END_SQL, 'p1', 'E-1', T),
    heartbeat: plan(db, SQL.HEARTBEAT_SQL, 'p1', 'E-1', 'box-1', T, T),
    end_lease: plan(db, SQL.END_LEASE_SQL, 'p1', 'E-1', 'box-1', 'done', T, 'r'),
    requeue: plan(db, SQL.REQUEUE_SQL, 'p1', 'E-1', 'box-1', 'r', T),
    sweep_select: plan(db, SQL.SWEEP_SELECT_SQL, T, 50),
    sweep_requeue: plan(db, SQL.SWEEP_REQUEUE_SQL, ids, T),
    sweep_end: plan(db, SQL.SWEEP_END_SQL, ids, T),
    sweep_read: plan(db, SQL.SWEEP_READ_SQL, ids, T),
  };
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((r) => r.rule === 'docker_pool_leases.ended');
  assert.ok(rule, 'retention rule exists');
  plans.retention_ids = plan(db, rule.ids, T, 500);
  for (const [name, lines] of Object.entries(plans)) {
    assert.deepEqual(fullScans(lines, ['docker_pool_leases', 'build_queue']), [], `${name}: ${lines.join(' | ')}`);
  }
  assert.ok(plans.claim.some((x) => /idx_docker_pool_leases_box/.test(x)), `claim count: ${plans.claim.join(' | ')}`);
  assert.ok(plans.sweep_select.some((x) => /idx_docker_pool_leases_due/.test(x)), plans.sweep_select.join(' | '));
  assert.ok(plans.heartbeat.some((x) => /uq_docker_pool_leases_live/.test(x)), plans.heartbeat.join(' | '));
  assert.ok(plans.retention_ids.some((x) => /idx_docker_pool_leases_ended/.test(x)), plans.retention_ids.join(' | '));
});
