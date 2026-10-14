// BH-4586 (BH-4574.4): the whole-factory watch's playbooks and action words on
// Archie's ledger, driven through the REAL worker.fetch against the REAL
// schema.sql (the node:sqlite D1 shim), as archie-actions.bh-4584.test.js does.
// What is pinned here: the eleven watch playbooks and five levers (and their
// would_* words) are accepted; pr 0 is allowed on a watch-* row ONLY; an
// unknown watch playbook is still a 400 naming the field; a replayed key is 200
// existing; the day counts group by the new playbook (the cap read
// bin/lib/archie-fm.sh afm_cap_ok makes); and the 17 seed rows exist.
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
  dedupe_key: 'watch:disk:disk-high-boxa@1791180000:ack_alert:on',
  project: 'hub',
  repo: 'example-org/cromford',
  pr: 0,
  playbook: 'watch-disk',
  mode: 'on',
  action: 'ack_alert',
  outcome: 'started',
  why: 'disk, tmpfs or inodes over threshold on boxa',
  evidence: { source: 'alert', alert_id: 'disk-high-boxa' },
  actor: 'archie-fm-watch',
};
const WATCH = ['watch-build-stuck', 'watch-review-unrescued', 'watch-pool-idle', 'watch-disk', 'watch-cron-install',
  'watch-deploy-drift', 'watch-main-red', 'watch-pause-waiting', 'watch-triage-skip', 'watch-cost-anomaly', 'watch-ticket', 'watch-session',
  'watch-owed-overdue', 'watch-metric-unreadable'];
const LEVERS = ['kick_lane', 'run_cleanup', 'rerun_deploy', 'ack_alert', 'file_ticket', 'session', 'note'];
const SEEDS = {
  'archie.cap.watch-build-stuck': '20', 'archie.cap.watch-review-unrescued': '10', 'archie.cap.watch-pool-idle': '5',
  'archie.cap.watch-disk': '10', 'archie.cap.watch-cron-install': '6', 'archie.cap.watch-deploy-drift': '6',
  'archie.cap.watch-main-red': '10', 'archie.cap.watch-pause-waiting': '5', 'archie.cap.watch-triage-skip': '10',
  'archie.cap.watch-cost-anomaly': '10', 'archie.cap.watch-ticket': '5', 'archie.cap.watch-session': '12',
  'archie.cap.watch-owed-overdue': '20', 'archie.cap.watch-metric-unreadable': '20',
  'archie.watch.escalate_s': '7200', 'archie.watch.rescue_grace_s': '3600', 'archie.watch.cron_install_s': '1800',
  'archie.watch.pause_waiting_s': '7200', 'archie.watch.inode_pct': '90', 'archie.watch.alert_min_age_s': '3000',
  'archie.watch.interval_min': '20',
};

test('BH-4586 whole-factory watch playbooks on the archie ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 the 21 seed rows: fourteen caps, six thresholds and the interval', async () => {
    const { db } = await openDb();
    db.exec(SCHEMA);
    const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    assert.equal(Object.keys(SEEDS).length, 21);
    for (const [k, v] of Object.entries(SEEDS)) assert.equal(val(k), v, k);
  });

  await t.test('W2 every watch playbook with pr 0 is a 201, and every lever word in both modes', async () => {
    const { DB } = await openDb();
    let i = 0;
    for (const playbook of WATCH) {
      for (const lever of LEVERS) {
        for (const mode of ['on', 'observe']) {
          const action = mode === 'on' ? lever : `would_${lever}`;
          const r = await create(DB, { ...BASE, dedupe_key: `k-${i++}`, playbook, action, mode,
            outcome: mode === 'on' ? 'started' : 'would' });
          assert.equal(r.status, 201, `${playbook}/${action}: ${JSON.stringify(r.body)}`);
          assert.equal(r.body.action.pr, 0);
          assert.equal(r.body.action.playbook, playbook);
          assert.equal(r.body.action.action, action);
        }
      }
    }
  });

  await t.test('W3 pr 0 stays a 400 on every non-watch playbook, and a negative pr on a watch one', async () => {
    const { DB } = await openDb();
    for (const [playbook, action] of [['queue-enqueue', 'enqueue'], ['stacked-parent-merged', 'restack'], ['queue-culprit', 'block_verdict']]) {
      const r = await create(DB, { ...BASE, playbook, action });
      assert.equal(r.status, 400, playbook);
      assert.deepEqual(r.body, { error: 'pr' });
    }
    assert.deepEqual((await create(DB, { ...BASE, pr: -1 })).body, { error: 'pr' });
    assert.deepEqual((await create(DB, { ...BASE, pr: '0' })).body, { error: 'pr' });
  });

  await t.test('W4 an unknown watch playbook or lever is a 400 naming the field', async () => {
    const { DB } = await openDb();
    const r = await create(DB, { ...BASE, playbook: 'watch-bogus' });
    assert.equal(r.status, 400);
    assert.deepEqual(r.body, { error: 'playbook' });
    assert.deepEqual((await create(DB, { ...BASE, action: 'harness_ctl_off' })).body, { error: 'action' });
    assert.deepEqual((await create(DB, { ...BASE, action: 'would_unpause' })).body, { error: 'action' });
    const bad = await call(DB, '/api/archie/actions?day=2026-10-05&playbook=watch-bogus');
    assert.deepEqual(bad.body, { error: 'playbook' });
  });

  await t.test('W5 a replay with the same key is 200 existing; a different project is a 409', async () => {
    const { DB } = await openDb();
    assert.equal((await create(DB, BASE)).status, 201);
    const again = await create(DB, BASE);
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    const other = await create(DB, { ...BASE, project: 'fixt' });
    assert.equal(other.status, 409);
  });

  await t.test('W6 the day count groups by a watch playbook, and the row reads back by key', async () => {
    const { DB } = await openDb();
    const a = (await create(DB, BASE)).body.action;
    const moved = await outcome(DB, { id: a.id, dedupe_key: a.dedupe_key, expect_updated_at: a.updated_at, outcome: 'done' });
    assert.equal(moved.status, 200);
    await create(DB, { ...BASE, dedupe_key: 'other', playbook: 'watch-ticket', action: 'file_ticket' });
    const r = await call(DB, `/api/archie/actions?day=${a.day}&playbook=watch-disk&limit=1`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.counts, { 'watch-disk': { on: { done: 1 } } });
    const byKey = await call(DB, `/api/archie/actions?dedupe_key=${encodeURIComponent(BASE.dedupe_key)}`);
    assert.equal(byKey.status, 200);
    assert.equal(byKey.body.action.outcome, 'done');
    const none = await call(DB, `/api/archie/actions?dedupe_key=${encodeURIComponent('watch:disk:nope:ack_alert:on')}`);
    assert.equal(none.status, 404);
    assert.deepEqual(none.body, { error: 'archie action not found' });
  });
});
