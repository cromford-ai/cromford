// BH-4585 (BH-4574.3): the rebase-repair playbook in Archie's action ledger,
// driven through the REAL worker.fetch against the REAL schema.sql (the
// node:sqlite D1 shim), as archie-actions.bh-4583.test.js does it. Pinned: the
// new playbook and its two actions are accepted, an unknown one is still a
// 400, summary=1 counts `repaired` (mode on, action repair, outcome done) and
// nothing else, and the four knobs are seeded one statement each.
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
const get = (DB, qs) => call(DB, `/api/archie/actions?${qs}`);

const BASE = {
  dedupe_key: 'rebase-repair:example-org/cromford#4620:abc123:on',
  project: 'cromford',
  repo: 'example-org/cromford',
  pr: 4620,
  playbook: 'rebase-repair',
  mode: 'on',
  action: 'repair',
  outcome: 'started',
  why: 'parked: conflict-unresolvable: worker/jobs/src/index.js',
  evidence: { park_reason: 'conflict-unresolvable: worker/jobs/src/index.js', old_head: 'abc123' },
  actor: 'archie-fm',
};

test('BH-4585 rebase-repair in the archie action ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('P1 rebase-repair with repair / would_repair / fix_round is accepted; junk is still 400', async () => {
    const { DB } = await openDb();
    const c = await create(DB, BASE);
    assert.equal(c.status, 201, JSON.stringify(c.body));
    assert.equal(c.body.action.playbook, 'rebase-repair');
    const o = await create(DB, { ...BASE, dedupe_key: BASE.dedupe_key.replace(':on', ':observe'), mode: 'observe', action: 'would_repair' });
    assert.equal(o.status, 201, JSON.stringify(o.body));
    const done = await outcome(DB, { id: c.body.action.id, dedupe_key: BASE.dedupe_key,
      expect_updated_at: c.body.action.updated_at, outcome: 'requested', action: 'fix_round',
      evidence: { diagnosis: '--- bin/lib/x.sh ---\nshape: both sides changed the same base lines' } });
    assert.equal(done.status, 200, JSON.stringify(done.body));
    assert.equal(done.body.action.evidence.diagnosis.startsWith('--- bin/lib/x.sh ---'), true);
    const byKey = await get(DB, `dedupe_key=${encodeURIComponent(BASE.dedupe_key)}`);
    assert.equal(byKey.status, 200);
    assert.equal(byKey.body.action.outcome, 'requested');
    assert.equal((await create(DB, { ...BASE, dedupe_key: 'k2', playbook: 'rebase-repairs' })).status, 400);
    assert.deepEqual((await create(DB, { ...BASE, dedupe_key: 'k3', action: 'merge' })).body, { error: 'action' });
    assert.equal((await get(DB, 'day=2026-10-05&playbook=rebase-repair')).status, 200);
  });

  await t.test('P2 summary=1 counts repaired (on/repair/done only), restacked unchanged', async () => {
    const { DB, db } = await openDb();
    const D = '2026-10-05';
    const ins = db.prepare(`INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action, outcome,
      why, evidence, attempts, actor, created_at, updated_at) VALUES (?, ?, 'p', 'o/r', 1, ?, ?, ?, ?, 'w', '{}', 1, 'archie-fm', ?, ?)`);
    const rows = [
      ['a1', 'rebase-repair', 'on', 'repair', 'done'],
      ['a2', 'rebase-repair', 'on', 'repair', 'done'],
      ['a3', 'rebase-repair', 'observe', 'would_repair', 'would'],
      ['a4', 'rebase-repair', 'on', 'fix_round', 'requested'],
      ['a5', 'rebase-repair', 'on', 'repair', 'deferred'],
      ['a6', 'rebase-repair', 'on', 'noop', 'done'],
      ['a7', 'stacked-parent-merged', 'on', 'restack', 'done'],
    ];
    rows.forEach(([k, pb, m, a, o], i) => ins.run(k, D, pb, m, a, o, `${D}T0${i}:00:00Z`, `${D}T0${i}:00:00Z`));
    const s = await get(DB, `day=${D}&summary=1`);
    assert.equal(s.status, 200);
    assert.equal(s.body.repaired, 2);
    assert.equal(s.body.restacked, 1);
    assert.equal(s.body.fix_rounds, 1);
    assert.equal(s.body.would, 1);
    assert.equal(s.body.deferred, 1);
    assert.equal(s.body.total, 7);
    const byPb = await get(DB, `day=${D}&playbook=rebase-repair`);
    assert.deepEqual(byPb.body.counts, { 'rebase-repair': { on: { done: 3, requested: 1, deferred: 1 }, observe: { would: 1 } } });
    assert.equal((await get(DB, 'day=2020-01-01&summary=1')).body.repaired, 0);
  });

  await t.test('P3 the four knobs are seeded, one INSERT OR IGNORE statement each', async () => {
    const { db } = await openDb();
    db.exec(SCHEMA);
    const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    assert.equal(val('archie.cap.rebase-repair'), '10');
    assert.equal(val('archie.fm.first_s'), '1200');
    assert.equal(val('archie.fm.union_globs'), 'worker/*/src/index.js,worker/*/schema.sql,catalog/*.json,*.d/*');
    assert.equal(val('archie.fm.regen'),
      'docs/config-inventory/deployment.md=bin/config-inventory.sh;docs/config-inventory/deployment.json=bin/config-inventory.sh');
    for (const k of ['archie.cap.rebase-repair', 'archie.fm.first_s', 'archie.fm.union_globs', 'archie.fm.regen']) {
      const stmts = SCHEMA.split(';\n').filter((x) => x.includes(`('${k}'`));
      assert.equal(stmts.length, 1, k);
      assert.match(stmts[0], /^\s*(--[^\n]*\n\s*)*INSERT OR IGNORE INTO settings/, k);
    }
    db.prepare("UPDATE settings SET value='3' WHERE key='archie.cap.rebase-repair'").run();
    db.exec(SCHEMA);
    assert.equal(val('archie.cap.rebase-repair'), '3', 're-applying schema.sql reset an operator-set cap');
  });
});
