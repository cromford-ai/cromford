// BH-4584 (BH-4574.2): the queue doctor's playbooks and action words on
// Archie's ledger, driven through the REAL worker.fetch against the REAL
// schema.sql (the node:sqlite D1 shim), as archie-actions.bh-4583.test.js does.
// What is pinned here: the four new playbooks and their action words are
// accepted, junk is still a 400 naming the field, the day counts group by the
// new playbook (the cap read bin/lib/archie-fm.sh afm_cap_ok makes), a replayed
// queue-enqueue key with a different PR is a 409, and the seed rows exist.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

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
const create = (DB, body) => call(DB, '/api/archie/actions', { method: 'POST', body });
const outcome = (DB, body) => call(DB, '/api/archie/actions/outcome', { method: 'POST', body });

const BASE = {
  dedupe_key: 'queue-enqueue:example-org/cromford#4700:0123456789abcdef0123456789abcdef01234567:on',
  project: 'cromford',
  repo: 'example-org/cromford',
  pr: 4700,
  playbook: 'queue-enqueue',
  mode: 'on',
  action: 'enqueue',
  outcome: 'started',
  why: 'approved on its head, green and clean; nobody enqueued it',
  evidence: { head: '0123456789abcdef0123456789abcdef01234567' },
  actor: 'archie-fm-queue',
};
const PAIRS = [
  ['queue-culprit', 'block_verdict'], ['queue-culprit', 'would_block_verdict'],
  ['queue-solo', 'solo_run'], ['queue-solo', 'would_solo_run'],
  ['queue-enqueue', 'enqueue'], ['queue-enqueue', 'would_enqueue'],
  ['queue-reconcile', 'settle_merged'], ['queue-reconcile', 'would_settle_merged'],
  ['queue-reconcile', 'release_dep_hold'], ['queue-reconcile', 'would_release_dep_hold'],
  ['queue-reconcile', 'report_dep_hold'], ['queue-reconcile', 'would_report_dep_hold'],
  ['queue-reconcile', 'kick_ci'], ['queue-reconcile', 'would_kick_ci'],
];

test('BH-4584 queue doctor playbooks on the archie ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('B1 the seed rows: four caps and three thresholds', async () => {
    const { db } = await openDb();
    db.exec(SCHEMA);
    const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    assert.equal(val('archie.cap.queue-culprit'), '10');
    assert.equal(val('archie.cap.queue-enqueue'), '20');
    assert.equal(val('archie.cap.queue-reconcile'), '30');
    assert.equal(val('archie.cap.queue-solo'), '40');
    assert.equal(val('archie.queue.wait_ci_stale_s'), '2700');
    assert.equal(val('archie.queue.dep_hold_stale_s'), '1800');
    assert.equal(val('archie.queue.ready_unqueued_s'), '1800');
  });

  await t.test('B2 every new playbook/action pair is a 201, in both modes', async () => {
    const { DB } = await openDb();
    let i = 0;
    for (const [playbook, action] of PAIRS) {
      const mode = action.startsWith('would_') ? 'observe' : 'on';
      const r = await create(DB, { ...BASE, dedupe_key: `k-${i++}`, playbook, action, mode,
        outcome: mode === 'observe' ? 'would' : 'started' });
      assert.equal(r.status, 201, `${playbook}/${action}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.action.playbook, playbook);
      assert.equal(r.body.action.action, action);
    }
  });

  await t.test('B3 an unknown playbook or action is still a 400 naming the field', async () => {
    const { DB } = await openDb();
    assert.deepEqual((await create(DB, { ...BASE, playbook: 'queue-bogus' })).body, { error: 'playbook' });
    assert.equal((await create(DB, { ...BASE, playbook: 'queue-bogus' })).status, 400);
    assert.deepEqual((await create(DB, { ...BASE, action: 'merge' })).body, { error: 'action' });
    assert.deepEqual((await create(DB, { ...BASE, action: 'would_merge' })).body, { error: 'action' });
    const c = (await create(DB, BASE)).body.action;
    const r = await outcome(DB, { id: c.id, dedupe_key: c.dedupe_key, expect_updated_at: c.updated_at,
      outcome: 'done', action: 'dequeue' });
    assert.equal(r.status, 400);
    assert.deepEqual(r.body, { error: 'action' });
  });

  await t.test('B4 GET counts group by the new playbook, and an unknown playbook filter is a 400', async () => {
    const { DB } = await openDb();
    const a = (await create(DB, BASE)).body.action;
    const moved = await outcome(DB, { id: a.id, dedupe_key: a.dedupe_key, expect_updated_at: a.updated_at, outcome: 'done' });
    assert.equal(moved.status, 200);
    await create(DB, { ...BASE, dedupe_key: 'other', playbook: 'queue-reconcile', action: 'settle_merged' });
    const day = a.day;
    const r = await call(DB, `/api/archie/actions?day=${day}&playbook=queue-enqueue&limit=1`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.counts, { 'queue-enqueue': { on: { done: 1 } } });
    assert.equal(r.body.actions.length, 1);
    const bad = await call(DB, `/api/archie/actions?day=${day}&playbook=queue-bogus`);
    assert.equal(bad.status, 400);
    assert.deepEqual(bad.body, { error: 'playbook' });
  });

  await t.test('B5 a replayed queue-enqueue key with a different PR is a 409', async () => {
    const { DB } = await openDb();
    assert.equal((await create(DB, BASE)).status, 201);
    assert.equal((await create(DB, BASE)).status, 200);
    const r = await create(DB, { ...BASE, pr: 4701 });
    assert.equal(r.status, 409);
    assert.match(r.body.error, /exists with a different payload/);
  });
});
