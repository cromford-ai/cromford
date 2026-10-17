// BH-6260: the flip and the two lane_snapshot knobs. Fragment 0025 seeds
// lane_placement.blocked-resolver=fly, lane_snapshot.file_max and
// lane_snapshot.prune_after_s, and the write-back ack prunes on the settings
// row, not on a code constant. Driven through the REAL router (worker.fetch)
// over the composed schema on the node:sqlite shim.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'fixture-harness-secret';
const SCHEMA = jobsSchemaSql();
const LANE = 'demo-lane';
const B = '/api/lane-snapshots';

const call = (DB, method, path, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const isoAgo = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok the ack route stamps and prunes on the worker's own real clock (nowIso), so a fixture age is set relative to it

// One applied write-back stamped <ageS> seconds ago, then an ack that stamps
// nothing new: the answer's `pruned` is the prune window's verdict on that row.
async function pruneOf(db, DB, ageS) {
  db.prepare('DELETE FROM lane_snapshot_writebacks').run();
  db.prepare(
    `INSERT INTO lane_snapshot_writebacks (lane,project,run_id,machine,sha,b64,created_at,applied_at)
     VALUES (?,?,?,?,?,?,?,?)`
  ).run(LANE, 'p1', 'r1', 'fixture-machine-1', 'c'.repeat(64), 'eA==', isoAgo(ageS), isoAgo(ageS));
  const r = await call(DB, 'POST', `${B}/${LANE}/p1/writebacks/ack`, { through: 0 });
  assert.equal(r.status, 200);
  return r.body.pruned;
}

test('BH-6260 the flip and the lane_snapshot knobs', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('K1 the composed schema seeds the flip and the two knobs, and keeps an operator value', async () => {
    const { db } = await openDb();
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('lane_placement.blocked-resolver'), 'fly');
    assert.equal(val('lane_snapshot.file_max'), '262144');
    assert.equal(val('lane_snapshot.prune_after_s'), '604800');
    db.prepare("UPDATE settings SET value = 'hub' WHERE key = 'lane_placement.blocked-resolver'").run();
    db.exec(SCHEMA);
    assert.equal(val('lane_placement.blocked-resolver'), 'hub', 'a re-apply keeps the kill knob');
  });

  await t.test('K2 the ack prunes on lane_snapshot.prune_after_s', async () => {
    const { db, DB } = await openDb();
    assert.equal(await pruneOf(db, DB, 7200), 0, 'the seeded 7 days keeps a 2 h old row');
    db.prepare("UPDATE settings SET value = '3600' WHERE key = 'lane_snapshot.prune_after_s'").run();
    assert.equal(await pruneOf(db, DB, 7200), 1, 'a 1 h window prunes a 2 h old row');
    assert.equal(await pruneOf(db, DB, 1800), 0, 'a 1 h window keeps a 30 min old row');
    db.prepare("UPDATE settings SET value = '7776000' WHERE key = 'lane_snapshot.prune_after_s'").run();
    assert.equal(await pruneOf(db, DB, 86400 * 30), 0, 'the 90-day maximum keeps a 30-day old row');
    db.prepare("DELETE FROM settings WHERE key = 'lane_snapshot.prune_after_s'").run();
    assert.equal(await pruneOf(db, DB, 86400 * 8), 1, 'no row: the 7-day code default prunes an 8-day old row');
    assert.equal(await pruneOf(db, DB, 7200), 0, 'no row: the 7-day code default keeps a 2 h old row');
  });

  await t.test('K3 an out-of-range or unreadable row uses the 7-day default', async () => {
    const { db, DB } = await openDb();
    for (const v of ['0', 'abc', '', '3599', '7776001', '99999999999', '-3600', '3600.5']) {
      db.prepare("UPDATE settings SET value = ? WHERE key = 'lane_snapshot.prune_after_s'").run(v);
      assert.equal(await pruneOf(db, DB, 7200), 0, `row '${v}' keeps a 2 h old row`);
      assert.equal(await pruneOf(db, DB, 86400 * 8), 1, `row '${v}' prunes an 8-day old row`);
    }
  });
});
