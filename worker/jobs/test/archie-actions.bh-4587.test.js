// BH-4587 (BH-4574.5): Archie's self-improvement loop on his ledger, driven
// through the REAL worker.fetch against the REAL schema.sql (the node:sqlite D1
// shim), as archie-actions.bh-4586.test.js does. What is pinned here: playbook
// `improve` takes file_ticket, comment, reopen, track_merged and verified (and
// their would_* words); pr 0 is allowed on an improve row and still refused on
// stacked-parent-merged; an unknown action is a 400 naming the field;
// count_by=action groups the improve rows; and the six seed rows exist.
import test from 'node:test';
import assert from 'node:assert/strict';
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

const BASE = {
  dedupe_key: 'improve:ticket:0123456789ab:2026-10-11:on',
  project: 'hub',
  repo: 'acme/fixt-harness',
  pr: 0,
  playbook: 'improve',
  mode: 'on',
  action: 'file_ticket',
  outcome: 'started',
  why: 'watch|disk|hub|run_cleanup recurred 3 times in 7 days',
  evidence: { fp: '0123456789ab', cause: 'watch|disk|hub|run_cleanup', count: 3 },
  actor: 'archie-fm-improve',
};
const ACTIONS = ['file_ticket', 'comment', 'reopen', 'track_merged', 'verified'];
const SEEDS = {
  'archie.cap.improve': '10', 'archie.improve.recur_n': '3', 'archie.improve.window_days': '7',
  'archie.improve.tickets_per_day': '3', 'archie.improve.verify_days': '7', 'archie.improve.verify_grace_s': '3600',
};

test('BH-4587 the improve playbook on the archie ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('I1 the six seed rows exist with the seeded values, and read back through /api/settings', async () => {
    const { db, DB } = await openDb();
    db.exec(SCHEMA);
    const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    for (const [k, v] of Object.entries(SEEDS)) assert.equal(val(k), v, k);
    for (const [k, v] of Object.entries(SEEDS)) {
      const r = await call(DB, `/api/settings/${k}`);
      assert.equal(r.status, 200, `${k}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.setting.value, v, k);
    }
  });

  await t.test('I2 every improve action and its would_* form is a 201 with pr 0', async () => {
    const { DB } = await openDb();
    let i = 0;
    for (const action of ACTIONS) {
      for (const mode of ['on', 'observe']) {
        const a = mode === 'on' ? action : `would_${action}`;
        const r = await create(DB, { ...BASE, dedupe_key: `improve:k-${i++}:${mode}`, action: a, mode,
          outcome: mode === 'on' ? 'started' : 'would' });
        assert.equal(r.status, 201, `${a}: ${JSON.stringify(r.body)}`);
        assert.equal(r.body.action.pr, 0);
        assert.equal(r.body.action.playbook, 'improve');
        assert.equal(r.body.action.action, a);
      }
    }
  });

  await t.test('I3 pr 0 stays a 400 on stacked-parent-merged; an unknown action is a 400 naming the field', async () => {
    const { DB } = await openDb();
    const s = await create(DB, { ...BASE, playbook: 'stacked-parent-merged', action: 'restack' });
    assert.equal(s.status, 400);
    assert.equal(s.body.error, 'pr');
    const a = await create(DB, { ...BASE, action: 'write_fix' });
    assert.equal(a.status, 400);
    assert.equal(a.body.error, 'action');
    const w = await create(DB, { ...BASE, action: 'would_merge' });
    assert.equal(w.body.error, 'action');
    // a positive pr is still fine on improve (the merged fix's PR may ride in it later)
    assert.equal((await create(DB, { ...BASE, dedupe_key: 'improve:pr:on', pr: 12 })).status, 201);
  });

  await t.test('I4 count_by=action groups the improve rows of the day', async () => {
    const { DB } = await openDb();
    const first = (await create(DB, BASE)).body.action;
    await create(DB, { ...BASE, dedupe_key: 'improve:comment:0123456789ab:9001:2026-10-11:on', action: 'comment' });
    await create(DB, { ...BASE, dedupe_key: 'improve:comment:0123456789ab:9001:2026-10-12:on', action: 'comment' });
    const r = await call(DB, `/api/archie/actions?day=${first.day}&playbook=improve&count_by=action`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.count_by, 'action');
    assert.equal(r.body.counts.improve.on.file_ticket, 1);
    assert.equal(r.body.counts.improve.on.comment, 2);
    assert.equal(r.body.actions.length, 3);
  });
});
