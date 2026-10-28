// BH-3155 (BH-2325.0 contract): two new config_changes kinds for the merge
// queue and held pages. No new route: GET /api/config-changes already reads
// config_changes, and its kind filter is the CONFIG_KINDS set.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim:
//   A0  CONFIG_KINDS carries MERGE_QUEUE='merge_queue' and HELD_PAGE='held_page',
//       stays frozen (a new key does not land), all eleven values distinct;
//   R   the same through the real worker.fetch: ?kind=merge_queue and
//       ?kind=held_page answer 200 with only their rows; a near miss
//       (?kind=merge_queues, ?kind=MERGE_QUEUE) is still a 400.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { CONFIG_KINDS } from '../src/lib/config-changes.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const T = '2026-09-28T14:00:00Z';

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

const insert = (db, kind, name) => db.prepare(
  "INSERT INTO config_changes (kind, name, before_json, after_json, actor, reason, at) VALUES (?,?,NULL,'{}','api',NULL,?)",
).run(kind, name, T);

const get = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

test('A0 CONFIG_KINDS gains MERGE_QUEUE and HELD_PAGE, stays frozen, every value distinct', () => {
  assert.equal(CONFIG_KINDS.MERGE_QUEUE, 'merge_queue');
  assert.equal(CONFIG_KINDS.HELD_PAGE, 'held_page');
  assert.ok(Object.isFrozen(CONFIG_KINDS));
  try { CONFIG_KINDS.EXTRA = 'extra'; } catch { /* strict mode throws; either way it must not land */ }
  assert.equal(CONFIG_KINDS.EXTRA, undefined);
  const values = Object.values(CONFIG_KINDS);
  // BH-4082 added PROJECT: eleven became twelve. BH-8317 added PROJECT_SECRET: thirteen.
  // TEST-CHANGE (BH-7924): CONNECTION added: fourteen.
  assert.equal(values.length, 14);
  assert.equal(new Set(values).size, values.length);
});

test('R GET /api/config-changes?kind=merge_queue|held_page answers 200 with only that kind', (t) => withDb(t, async ({ db, DB }) => {
  insert(db, 'merge_queue', 'project-3#12');
  insert(db, 'held_page', 'page-7');
  insert(db, 'flag', 'x');
  const mq = await get(DB, '/api/config-changes?kind=merge_queue');
  assert.equal(mq.status, 200);
  assert.deepEqual(mq.body.changes.map((c) => [c.kind, c.name]), [['merge_queue', 'project-3#12']]);
  assert.equal(mq.body.truncated, false);
  const held = await get(DB, '/api/config-changes?kind=held_page');
  assert.equal(held.status, 200);
  assert.deepEqual(held.body.changes.map((c) => [c.kind, c.name]), [['held_page', 'page-7']]);
}));

test('R a near-miss kind is still a 400, never an unfiltered read', (t) => withDb(t, async ({ db, DB }) => {
  insert(db, 'merge_queue', 'project-3#12');
  for (const kind of ['merge_queues', 'MERGE_QUEUE', 'held_pages']) {
    const r = await get(DB, `/api/config-changes?kind=${kind}`);
    assert.equal(r.status, 400, kind);
    assert.match(r.body.error, /kind/);
    assert.equal(r.body.changes, undefined);
  }
}));
