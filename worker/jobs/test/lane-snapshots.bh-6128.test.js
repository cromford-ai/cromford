// BH-6128 (5 of 5, split from BH-6047): blocked-resolver inputs off the hub.
// The hub stages a snapshot as parts, commits it in one statement, a machine
// reads it back and posts write-backs, the hub lists, reads and acks them.
// Driven through the REAL router (worker.fetch) over a real schema.sql
// database on the node:sqlite shim. The shell side is bin/lib/lane-run-inputs.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'fixture-harness-secret';
// BH-6005: the schema is composed from schema.d/; schema.sql is not committed.
const SCHEMA = jobsSchemaSql();
const LANE = 'demo-lane';
const SHA_A = 'a'.repeat(64);
const SHA_B = 'b'.repeat(64);
const SHA_W = 'c'.repeat(64);
const B = '/api/lane-snapshots';

const call = (DB, method, path, body, auth = true) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const putPart = (DB, p, n, sha, b64) => call(DB, 'PUT', `${B}/${LANE}/${p}/parts/${n}`, { sha, b64 });
const commit = (DB, p, sha, parts, applied_through = 0) =>
  call(DB, 'POST', `${B}/${LANE}/${p}/commit`, { sha, parts, applied_through });
const snap = (DB, p) => call(DB, 'GET', `${B}/${LANE}/${p}`);
const wbPost = (DB, p, run_id, sha, b64 = 'd2JmaXh0dXJl') =>
  call(DB, 'POST', `${B}/${LANE}/${p}/writebacks`, { run_id, machine: 'fixture-machine-1', sha, b64 });
const ack = (DB, p, body) => call(DB, 'POST', `${B}/${LANE}/${p}/writebacks/ack`, body);
const isoAgo = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok the routes stamp and age rows on the worker's own real clock (nowIso), so a fixture age is set relative to it

test('BH-6128 lane snapshots and write-backs', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const fresh = async () => openDb();

  await t.test('S1 schema.sql has the three tables and the four seeds, the BH-6260 flip, and applies twice', async () => {
    const { db } = await fresh();
    const cols = (tb) => db.prepare(`PRAGMA table_info(${tb})`).all().map((c) => c.name);
    for (const c of ['lane', 'project', 'sha', 'parts', 'bytes', 'applied_through', 'published_at']) {
      assert.ok(cols('lane_snapshots').includes(c), `lane_snapshots has ${c}`);
    }
    for (const c of ['lane', 'project', 'sha', 'n', 'b64']) {
      assert.ok(cols('lane_snapshot_parts').includes(c), `lane_snapshot_parts has ${c}`);
    }
    for (const c of ['id', 'lane', 'project', 'run_id', 'machine', 'sha', 'b64', 'created_at', 'applied_at', 'rejected_at']) {
      assert.ok(cols('lane_snapshot_writebacks').includes(c), `lane_snapshot_writebacks has ${c}`);
    }
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('lane_snapshot.max_age_s'), '1200');
    assert.equal(val('lane_snapshot.max_bytes'), '33554432');
    assert.equal(val('lane_snapshot.builds_days'), '30');
    assert.equal(val('lane_snapshot.max_pending'), '500');
    // BH-6260 seeds the flip (schema.d/0025) now that BH-6125/BH-6126 claim lane_runs rows.
    assert.equal(val('lane_placement.blocked-resolver'), 'fly');
    db.prepare("UPDATE settings SET value = '99' WHERE key = 'lane_snapshot.max_age_s'").run();
    db.exec(SCHEMA);
    assert.equal(val('lane_snapshot.max_age_s'), '99', 'a re-apply keeps an operator value');
    assert.equal(val('lane_placement.blocked-resolver'), 'fly');
  });

  await t.test('V1 no bearer is 401; a bad lane or project is 400; a part over the cap is 413', async () => {
    const { DB } = await fresh();
    assert.equal((await call(DB, 'GET', `${B}/${LANE}/p1`, undefined, false)).status, 401);
    assert.equal((await call(DB, 'GET', `${B}/bad%20lane/p1`)).status, 400);
    assert.equal((await call(DB, 'GET', `${B}/${LANE}/-p1`)).status, 400, 'project must start alphanumeric');
    assert.equal((await putPart(DB, '.p1', 0, SHA_A, 'QUJD')).status, 400);
    assert.equal((await putPart(DB, 'p1', 0, 'XYZ', 'QUJD')).status, 400, 'bad sha');
    assert.equal((await putPart(DB, 'p1', 256, SHA_A, 'QUJD')).status, 400, 'n over 255');
    const big = await putPart(DB, 'p1', 0, SHA_A, 'A'.repeat(1400001));
    assert.equal(big.status, 413);
    assert.equal(big.body.error, 'too_large');
    assert.equal(big.body.max_chars, 1400000);
    assert.equal((await putPart(DB, 'p1', 0, SHA_A, 'A'.repeat(1400000))).status, 200, 'the cap itself is allowed');
    const wbBig = await wbPost(DB, 'p1', 'run-1', SHA_W, 'A'.repeat(1400001));
    assert.equal(wbBig.status, 413);
  });

  await t.test('C1 a commit with a missing part is 409 parts_missing with the missing list', async () => {
    const { db, DB } = await fresh();
    await putPart(DB, 'p1', 0, SHA_A, 'QUJD');
    await putPart(DB, 'p1', 2, SHA_A, 'REVG');
    const r = await commit(DB, 'p1', SHA_A, 4);
    assert.equal(r.status, 409);
    assert.equal(r.body.error, 'parts_missing');
    assert.deepEqual(r.body.missing, [1, 3]);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_snapshots').get().n, 0, 'nothing was published');
    assert.equal((await snap(DB, 'p1')).status, 404);
    assert.equal((await snap(DB, 'p1')).body.error, 'no_snapshot');
  });

  await t.test('R1 put, commit, get and get-part round trip byte for byte', async () => {
    const { DB } = await fresh();
    const p0 = 'SGVsbG8sIGZpeHR1cmUh';
    const p1 = 'cGFydCB0d28+/w==';
    assert.equal((await putPart(DB, 'p1', 0, SHA_A, p0)).status, 200);
    const put1 = await putPart(DB, 'p1', 1, SHA_A, 'b2xk');
    assert.equal(put1.body.ok, true);
    assert.equal(put1.body.n, 1);
    assert.equal((await putPart(DB, 'p1', 1, SHA_A, p1)).status, 200, 'a retry upserts');
    const c = await commit(DB, 'p1', SHA_A, 2, 7);
    assert.equal(c.status, 200);
    assert.equal(c.body.sha, SHA_A);
    assert.equal(c.body.parts, 2);
    assert.equal(c.body.bytes, p0.length + p1.length);
    assert.equal(c.body.applied_through, 7);
    assert.equal(c.body.changed, true);
    assert.match(c.body.published_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    const g = await snap(DB, 'p1');
    assert.equal(g.status, 200);
    assert.equal(g.body.sha, SHA_A);
    assert.equal(g.body.parts, 2);
    assert.equal(g.body.bytes, p0.length + p1.length);
    assert.equal(g.body.applied_through, 7);
    assert.deepEqual(g.body.writebacks, []);
    assert.equal(g.body.pending, 0);
    assert.equal(g.body.truncated, false);
    const a = await call(DB, 'GET', `${B}/${LANE}/p1/parts/0?sha=${SHA_A}`);
    const b = await call(DB, 'GET', `${B}/${LANE}/p1/parts/1?sha=${SHA_A}`);
    assert.equal(a.body.b64, p0);
    assert.equal(b.body.b64, p1);
    assert.equal(b.body.n, 1);
    assert.equal((await call(DB, 'GET', `${B}/${LANE}/p1/parts/0`)).status, 400, 'sha is required');
    const none = await call(DB, 'GET', `${B}/${LANE}/p1/parts/2?sha=${SHA_A}`);
    assert.equal(none.status, 404);
    assert.equal(none.body.error, 'no_part');
  });

  await t.test('C2 a same-sha commit refreshes published_at only; a new sha deletes the old parts', async () => {
    const { db, DB } = await fresh();
    await putPart(DB, 'p1', 0, SHA_A, 'QUJD');
    await commit(DB, 'p1', SHA_A, 1, 1);
    const old = '2026-01-01T00:00:00Z';
    db.prepare('UPDATE lane_snapshots SET published_at=? WHERE project=?').run(old, 'p1');
    // A part of another sha staged for p1, and one for p2, before the refresh.
    await putPart(DB, 'p1', 0, SHA_B, 'WFla');
    await putPart(DB, 'p2', 0, SHA_B, 'WFla');
    const again = await commit(DB, 'p1', SHA_A, 1, 4);
    assert.equal(again.status, 200);
    assert.equal(again.body.changed, false);
    const row = db.prepare('SELECT * FROM lane_snapshots WHERE project=?').get('p1');
    assert.notEqual(row.published_at, old);
    assert.equal(row.applied_through, 4);
    assert.equal(row.sha, SHA_A);
    const parts = (p, sha) => db.prepare('SELECT COUNT(*) AS n FROM lane_snapshot_parts WHERE project=? AND sha=?').get(p, sha).n;
    assert.equal(parts('p1', SHA_A), 1, 'the current sha keeps its parts');
    assert.equal(parts('p1', SHA_B), 0, 'another sha of p1 is deleted');
    assert.equal(parts('p2', SHA_B), 1, 'p2 is untouched');
    // A new sha for p1: SHA_A's parts go, the new ones stay.
    await putPart(DB, 'p1', 0, SHA_B, 'WFla');
    await putPart(DB, 'p1', 1, SHA_B, 'WFla');
    const flip = await commit(DB, 'p1', SHA_B, 2, 4);
    assert.equal(flip.body.changed, true);
    assert.equal(parts('p1', SHA_A), 0);
    assert.equal(parts('p1', SHA_B), 2);
    assert.equal(parts('p2', SHA_B), 1);
  });

  await t.test('A1 age_s is computed on the server clock', async () => {
    const { db, DB } = await fresh();
    await putPart(DB, 'p1', 0, SHA_A, 'QUJD');
    await commit(DB, 'p1', SHA_A, 1);
    db.prepare('UPDATE lane_snapshots SET published_at=? WHERE project=?').run(isoAgo(300), 'p1');
    const g = await snap(DB, 'p1');
    assert.ok(g.body.age_s >= 300 && g.body.age_s <= 310, `age_s=${g.body.age_s}`);
  });

  await t.test('W1 write-back post: 201 id, replay 200 same id, another sha a new id', async () => {
    const { db, DB } = await fresh();
    const a = await wbPost(DB, 'p1', 4242, SHA_W);
    assert.equal(a.status, 201);
    assert.ok(Number.isInteger(a.body.id));
    const r = await wbPost(DB, 'p1', '4242', SHA_W);
    assert.equal(r.status, 200);
    assert.equal(r.body.id, a.body.id);
    assert.equal(r.body.replay, true);
    const b = await wbPost(DB, 'p1', 4242, SHA_B);
    assert.equal(b.status, 201);
    assert.notEqual(b.body.id, a.body.id);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_snapshot_writebacks').get().n, 2);
    assert.equal((await wbPost(DB, 'p1', 'bad run', SHA_W)).status, 400);
  });

  await t.test('W2 GET snapshot lists ids > applied_through, skips rejected, caps at max_pending', async () => {
    const { db, DB } = await fresh();
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push((await wbPost(DB, 'p1', `run-${i}`, SHA_W)).body.id);
    await wbPost(DB, 'p2', 'run-x', SHA_W);
    db.prepare('UPDATE lane_snapshot_writebacks SET rejected_at=? WHERE id=?').run(isoAgo(10), ids[2]);
    await putPart(DB, 'p1', 0, SHA_A, 'QUJD');
    await commit(DB, 'p1', SHA_A, 1, ids[0]);
    const g = await snap(DB, 'p1');
    assert.deepEqual(g.body.writebacks.map((w) => w.id), [ids[1], ids[3], ids[4]]);
    assert.equal(g.body.writebacks[0].sha, SHA_W);
    assert.equal(g.body.pending, 3);
    assert.equal(g.body.truncated, false);
    db.prepare("UPDATE settings SET value='2' WHERE key='lane_snapshot.max_pending'").run();
    const c = await snap(DB, 'p1');
    assert.deepEqual(c.body.writebacks.map((w) => w.id), [ids[1], ids[3]]);
    assert.equal(c.body.pending, 3);
    assert.equal(c.body.truncated, true);
  });

  await t.test('W3 GET writebacks lists the unapplied; GET writebacks/<id> reads one, 404 for another project', async () => {
    const { db, DB } = await fresh();
    const a = (await wbPost(DB, 'p1', 'run-1', SHA_W, 'Zmlyc3Q=')).body.id;
    const b = (await wbPost(DB, 'p1', 'run-2', SHA_B)).body.id;
    const c = (await wbPost(DB, 'p1', 'run-3', SHA_W)).body.id;
    const other = (await wbPost(DB, 'p2', 'run-1', SHA_W)).body.id;
    db.prepare('UPDATE lane_snapshot_writebacks SET applied_at=? WHERE id=?').run(isoAgo(5), b);
    const l = await call(DB, 'GET', `${B}/${LANE}/p1/writebacks`);
    assert.equal(l.status, 200);
    assert.deepEqual(l.body.writebacks.map((w) => w.id), [a, c]);
    assert.equal(l.body.writebacks[0].run_id, 'run-1');
    assert.equal(l.body.writebacks[0].machine, 'fixture-machine-1');
    assert.equal(l.body.truncated, false);
    const one = await call(DB, 'GET', `${B}/${LANE}/p1/writebacks/${a}`);
    assert.equal(one.status, 200);
    assert.equal(one.body.id, a);
    assert.equal(one.body.sha, SHA_W);
    assert.equal(one.body.b64, 'Zmlyc3Q=');
    const cross = await call(DB, 'GET', `${B}/${LANE}/p1/writebacks/${other}`);
    assert.equal(cross.status, 404);
    assert.equal(cross.body.error, 'no_writeback');
  });

  await t.test('K1 ack stamps only this project ids <= through; prunes only this project rows over 7 days old', async () => {
    const { db, DB } = await fresh();
    const p1 = [];
    for (let i = 0; i < 4; i++) p1.push((await wbPost(DB, 'p1', `run-${i}`, SHA_W)).body.id);
    const p2 = [];
    for (let i = 0; i < 2; i++) p2.push((await wbPost(DB, 'p2', `run-${i}`, SHA_W)).body.id);
    // One row of each project was applied 8 days ago.
    db.prepare('UPDATE lane_snapshot_writebacks SET applied_at=? WHERE id IN (?, ?)').run(isoAgo(8 * 86400), p1[0], p2[0]);
    const r = await ack(DB, 'p1', { through: p1[2], rejected: [p1[1], p2[1], p1[3]] });
    assert.equal(r.status, 200);
    assert.equal(r.body.rejected, 1, 'only p1[1]: p2 belongs to another project, p1[3] is over through');
    assert.equal(r.body.applied, 1, 'only p1[2]');
    assert.equal(r.body.pruned, 1, 'only the old p1 row');
    const get = (id) => db.prepare('SELECT * FROM lane_snapshot_writebacks WHERE id=?').get(id);
    assert.equal(get(p1[0]), undefined, 'p1 old row pruned');
    assert.ok(get(p2[0]), 'p2 old row kept');
    assert.ok(get(p1[1]).rejected_at);
    assert.equal(get(p1[1]).applied_at, null);
    assert.ok(get(p1[2]).applied_at);
    assert.equal(get(p1[3]).applied_at, null);
    assert.equal(get(p1[3]).rejected_at, null);
    assert.equal(get(p2[1]).applied_at, null);
    assert.equal(get(p2[1]).rejected_at, null);
    assert.equal((await ack(DB, 'p1', { through: -1 })).status, 400);
    assert.equal((await ack(DB, 'p1', { through: 1, rejected: ['x'] })).status, 400);
  });
});
