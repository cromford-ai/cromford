import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { call } from './lib/harness.js';
import { confirmed, auditStmt, knownBox } from '../src/lib/hub-recovery.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1942 (BH-1909.0): the hub-recovery contract. Two additive tables applied
// from the real schema.sql, the three shared helpers the sibling routes build
// on, and the stub routes that answer 501 through the real route table until
// their sibling replaces them. Both siblings have landed: #1943 built recovery
// and promote, #1944 the four restore-lab routes (their suites are under
// test/routes/), so no stub is left.

const SCHEMA = jobsSchemaSql();
const T = '2026-09-24T12:00:00Z';

const CHANGES_COLUMNS = [
  'id', 'action', 'before_holder', 'before_epoch', 'after_holder', 'after_epoch',
  'target', 'actor', 'reason', 'outcome', 'at',
];
const RUNS_COLUMNS = [
  'id', 'box', 'snapshot', 'status', 'requested_by', 'requested_at',
  'claimed_by', 'claimed_at', 'finished_at', 'verdict_detail', 'sha256', 'snapshot_ts',
];

async function open(t) {
  const h = await openDb();
  if (!h) t.skip('node:sqlite unavailable on this runtime');
  return h;
}

function requestRun(db, box, status = 'requested', snapshot) {
  if (snapshot === undefined) {
    return db.prepare('INSERT INTO restore_lab_runs (box, status, requested_at) VALUES (?, ?, ?)').run(box, status, T);
  }
  return db.prepare('INSERT INTO restore_lab_runs (box, snapshot, status, requested_at) VALUES (?, ?, ?, ?)')
    .run(box, snapshot, status, T);
}

// ── Schema ────────────────────────────────────────────────────────────────

test('hub_lease_changes has the contract columns and its (at) index', async (t) => {
  const h = await open(t);
  if (!h) return;
  const cols = h.db.prepare('PRAGMA table_info(hub_lease_changes)').all();
  assert.deepEqual(cols.map((c) => c.name), CHANGES_COLUMNS);
  assert.equal(cols.find((c) => c.name === 'id').pk, 1);
  for (const n of ['action', 'actor', 'outcome', 'at']) {
    assert.equal(cols.find((c) => c.name === n).notnull, 1, `${n} NOT NULL`);
  }
  const idx = h.db.prepare('PRAGMA index_list(hub_lease_changes)').all().map((i) => i.name);
  assert.ok(idx.includes('idx_hub_lease_changes_at'), `indexes: ${idx}`);
  const on = h.db.prepare('PRAGMA index_info(idx_hub_lease_changes_at)').all().map((c) => c.name);
  assert.deepEqual(on, ['at']);
  h.db.prepare(`INSERT INTO hub_lease_changes (action, actor, outcome, at) VALUES ('promote','console','ok',?)`).run(T);
  assert.equal(h.db.prepare('SELECT COUNT(*) AS n FROM hub_lease_changes').get().n, 1);
});

test('restore_lab_runs has the contract columns and snapshot defaults to latest', async (t) => {
  const h = await open(t);
  if (!h) return;
  const cols = h.db.prepare('PRAGMA table_info(restore_lab_runs)').all();
  assert.deepEqual(cols.map((c) => c.name), RUNS_COLUMNS);
  for (const n of ['box', 'snapshot', 'status', 'requested_at']) {
    assert.equal(cols.find((c) => c.name === n).notnull, 1, `${n} NOT NULL`);
  }
  requestRun(h.db, 'hub-1');
  assert.equal(h.db.prepare('SELECT snapshot FROM restore_lab_runs').get().snapshot, 'latest');
});

test('only one open restore-lab run per (box, snapshot)', async (t) => {
  const h = await open(t);
  if (!h) return;
  const first = requestRun(h.db, 'hub-1');
  assert.throws(() => requestRun(h.db, 'hub-1'), /UNIQUE/, 'a second requested run for the same box+snapshot');
  assert.throws(() => requestRun(h.db, 'hub-1', 'claimed'), /UNIQUE/, 'a claimed run beside an open requested run');
  // A different snapshot of the same box is a different run.
  requestRun(h.db, 'hub-1', 'requested', '2026-09-23');
  // Once the first run finishes, the box can be asked again.
  h.db.prepare(`UPDATE restore_lab_runs SET status='ok' WHERE id=?`).run(first.lastInsertRowid);
  requestRun(h.db, 'hub-1');
  const rows = h.db.prepare('SELECT status FROM restore_lab_runs ORDER BY id').all().map((r) => r.status);
  assert.deepEqual(rows, ['ok', 'requested', 'requested']);
});

test('schema.sql applies twice without error', async (t) => {
  const h = await open(t);
  if (!h) return;
  assert.doesNotThrow(() => h.db.exec(SCHEMA));
  assert.doesNotThrow(() => h.db.exec(SCHEMA));
});

// ── Helpers ───────────────────────────────────────────────────────────────

test('confirmed() is true only for a literal confirm:true', () => {
  assert.equal(confirmed({ confirm: true }), true);
  const negatives = ['true', 1, '1', { confirm: 'yes' }, { confirm: 'true' }, { confirm: 1 },
    {}, null, undefined, { confirm: [true] }];
  for (const v of negatives) assert.equal(confirmed(v), false, `confirmed(${JSON.stringify(v)})`);
});

test('auditStmt prepares one audit row and does not run it', async (t) => {
  const h = await open(t);
  if (!h) return;
  const env = { DB: h.DB };
  const count = () => h.db.prepare('SELECT COUNT(*) AS n FROM hub_lease_changes').get().n;
  const stmt = auditStmt(env, {
    action: 'promote', before_holder: 'hub-1', before_epoch: 4, after_holder: 'hub-2', after_epoch: 5,
    target: 'hub-2', actor: 'console', reason: 'hub-1 dead', outcome: 'ok',
  }, T);
  assert.equal(count(), 0, 'auditStmt must not execute the insert');
  await env.DB.batch([stmt]);
  assert.equal(count(), 1);
  const row = h.db.prepare('SELECT * FROM hub_lease_changes').get();
  assert.deepEqual({ ...row }, {
    id: row.id, action: 'promote', before_holder: 'hub-1', before_epoch: 4, after_holder: 'hub-2',
    after_epoch: 5, target: 'hub-2', actor: 'console', reason: 'hub-1 dead', outcome: 'ok', at: T,
  });
});

test('auditStmt stores NULL for omitted optional fields', async (t) => {
  const h = await open(t);
  if (!h) return;
  await h.DB.batch([auditStmt({ DB: h.DB }, {
    action: 'promote_refused', target: 'nope', actor: 'console', outcome: 'refused:unknown_box',
  }, T)]);
  const row = h.db.prepare('SELECT * FROM hub_lease_changes').get();
  for (const n of ['before_holder', 'before_epoch', 'after_holder', 'after_epoch', 'reason']) {
    assert.equal(row[n], null, `${n} should be NULL`);
  }
  assert.equal(row.outcome, 'refused:unknown_box');
});

test('auditStmt does not default a missing actor or outcome', async (t) => {
  const h = await open(t);
  if (!h) return;
  await assert.rejects(
    () => h.DB.batch([auditStmt({ DB: h.DB }, { action: 'promote', outcome: 'ok' }, T)]),
    /NOT NULL/,
  );
  await assert.rejects(
    () => h.DB.batch([auditStmt({ DB: h.DB }, { action: 'promote', actor: 'console' }, T)]),
    /NOT NULL/,
  );
});

test('knownBox is true only for a box in box_status', async (t) => {
  const h = await open(t);
  if (!h) return;
  h.db.prepare(`INSERT INTO box_status (box, updated_at) VALUES ('hub-1', ?)`).run(T);
  const env = { DB: h.DB };
  assert.equal(await knownBox(env, 'hub-1'), true);
  assert.equal(await knownBox(env, 'nope'), false);
  assert.equal(await knownBox(env, ''), false);
  assert.equal(await knownBox(env, undefined), false);
  assert.equal(await knownBox(env, null), false);
});

// ── Stub routes, through the real worker.fetch → ROUTES ───────────────────

// Every route BH-1942 stubbed has been built: /api/hub/recovery and
// /api/hub/promote by BH-1943 (test/routes/hub-recovery.bh-1943.test.js), the
// four restore-lab routes by BH-1944 (test/routes/restore-lab.bh-1944.test.js).
// So the stub list is empty, and what this suite pins instead is that none of
// the six still answers the BH-1909 stub body through the real route table.
const BUILT = [
  ['GET', '/api/hub/recovery'],
  ['POST', '/api/hub/promote'],
  ['POST', '/api/hub/restore-lab'],
  ['GET', '/api/hub/restore-lab'],
  ['POST', '/api/hub/restore-lab/claim'],
  ['POST', '/api/hub/restore-lab/7/result'],
];

test('no hub-recovery route still answers the BH-1909 501 stub', async () => {
  for (const [method, path] of BUILT) {
    const r = await call(path, { method, body: method === 'POST' ? { confirm: true } : undefined });
    assert.notDeepEqual(r.body, { error: 'not_implemented', ticket: 'BH-1909' }, `${method} ${path} is still the stub`);
    assert.notEqual(r.status, 501, `${method} ${path}`);
  }
});

test('a non-numeric restore-lab result id is not a stub route', async () => {
  const r = await call('/api/hub/restore-lab/abc/result', { method: 'POST', body: {} });
  assert.notEqual(r.status, 501);
});

test('the stubs sit behind the bearer', async () => {
  const r = await call('/api/hub/recovery', { secret: null });
  assert.equal(r.status, 401);
});
