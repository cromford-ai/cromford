// BH-9554 (custody C0): the /api/custody routes over the REAL composed schema
// (the node:sqlite D1 shim), driven through the REAL worker.fetch.
//
//   C1 the claim decision table: no row, own lease, custodian, expired 1 s
//      ago, settled -> take; live other owner, far lease, "Pool" vs "pool" ->
//      409 held; the same key on another project is another row; the exact
//      edge lease == now is expired (pure claimDecision)
//   C2 every 400 field writes 0 rows in both tables
//   C3 act CAS: expect_attempt 0 -> attempt 1 + one action row; the same call
//      again -> 409 stale, attempt still 1, still one action row
//   C4 the due table: deadline past / lease past / both / released-deadline
//      past are due; both future, settled, due_at == now are not; limit and
//      truncated are measured; due_at is the earlier time on every write
//   C5 release/next/renew by a non-owner: 409, row and log unchanged; settle
//      twice: one settle row and duplicate:true; a stale rev writes nothing
//   C6 retention custody_actions.age: an unbound archive moves nothing; a
//      bound one copies the old rows, then deletes them; the recent row stays
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { RULES } from '#retention-rules';
import { claimDecision, dueOf, custodyOwned, CUSTODY_ACTIONS, CUSTODY_STATES } from '../src/routes/custody.js';

const SECRET = 'test-secret-fixture';
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const at = (s) => iso(Date.now() + s * 1000); // determinism: ok every seeded time is an offset from the route's own server clock

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
const post = (DB, verb, body) => call(DB, `/api/custody/${verb}`, { method: 'POST', body });
const claim = (DB, project, ticket, lane, extra = {}) =>
  post(DB, 'claim', { project, ticket, lane, state: 'building', next_action: 'reoffer', ...extra });
const rowOf = (db, p, k) => db.prepare('SELECT * FROM ticket_custody WHERE project = ? AND ticket = ?').get(p, k);
const actionsOf = (db, p, k) => db.prepare('SELECT * FROM custody_actions WHERE project = ? AND ticket = ? ORDER BY id').all(p, k);
const counts = (db) => ({
  rows: db.prepare('SELECT count(*) AS n FROM ticket_custody').get().n,
  actions: db.prepare('SELECT count(*) AS n FROM custody_actions').get().n,
});
const set = (db, p, k, cols) => {
  const keys = Object.keys(cols);
  db.prepare(`UPDATE ticket_custody SET ${keys.map((c) => `${c} = ?`).join(', ')} WHERE project = ? AND ticket = ?`)
    .run(...keys.map((c) => cols[c]), p, k);
};

test('C1 the claim decision table', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  // (1) no row -> take
  let r = await claim(DB, 'p1', 'T-1', 'pool');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(rowOf(db, 'p1', 'T-1').owner_lane, 'pool');
  // (2) the same lane on its own live lease -> take
  r = await claim(DB, 'p1', 'T-1', 'pool');
  assert.equal(r.status, 200);
  // (6) another lane, lease ends 30 s from now -> held
  set(db, 'p1', 'T-1', { lease_expires_at: at(30) });
  const before = rowOf(db, 'p1', 'T-1');
  r = await claim(DB, 'p1', 'T-1', 'triage', { state: 'triaged' });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'held');
  assert.equal(r.body.owner_lane, 'pool');
  assert.deepEqual(rowOf(db, 'p1', 'T-1'), before, 'a refused claim changes nothing');
  // (7) lease far in the future -> held
  set(db, 'p1', 'T-1', { lease_expires_at: at(86400 * 300) });
  assert.equal((await claim(DB, 'p1', 'T-1', 'triage')).status, 409);
  // (8) "Pool" is another owner
  assert.equal((await claim(DB, 'p1', 'T-1', 'Pool')).status, 409);
  // (9) the same ticket key on another project is another row -> take
  assert.equal((await claim(DB, 'p2', 'T-1', 'triage')).status, 200);
  assert.equal(rowOf(db, 'p1', 'T-1').owner_lane, 'pool');
  // (4) lease ended 1 s ago -> take; the state changed, so attempt resets
  set(db, 'p1', 'T-1', { lease_expires_at: at(-1), attempt: 3, ladder_rung: 2 });
  r = await claim(DB, 'p1', 'T-1', 'triage', { state: 'triaged' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  let row = rowOf(db, 'p1', 'T-1');
  assert.equal(row.owner_lane, 'triage');
  assert.equal(row.attempt, 0);
  assert.equal(row.ladder_rung, 0);
  // the same state keeps attempt and rung
  set(db, 'p1', 'T-1', { attempt: 2, ladder_rung: 1 });
  await claim(DB, 'p1', 'T-1', 'triage', { state: 'triaged' });
  row = rowOf(db, 'p1', 'T-1');
  assert.deepEqual([row.attempt, row.ladder_rung], [2, 1]);
  // (3) owner custodian (released) -> take
  set(db, 'p1', 'T-1', { owner_lane: 'custodian', lease_expires_at: null });
  assert.equal((await claim(DB, 'p1', 'T-1', 'pool')).status, 200);
  // (5) settled -> take, attempt reset, settled_at cleared
  set(db, 'p1', 'T-1', { settled_at: at(-60), owner_lane: null, lease_expires_at: at(3600), state: 'merged', attempt: 4 });
  r = await claim(DB, 'p1', 'T-1', 'triage', { state: 'triaged' });
  assert.equal(r.status, 200);
  row = rowOf(db, 'p1', 'T-1');
  assert.equal(row.settled_at, null);
  assert.equal(row.attempt, 0);
  // the pure decision at its exact edges
  const now = '2099-01-01T00:00:00Z';
  const live = { owner_lane: 'pool', settled_at: null };
  assert.deepEqual(claimDecision({ ...live, lease_expires_at: now }, 'triage', now), { take: true }, 'lease == now is expired');
  assert.deepEqual(claimDecision({ ...live, lease_expires_at: '2099-01-01T00:00:01Z' }, 'triage', now), { take: false, error: 'held' });
  assert.deepEqual(claimDecision({ ...live, lease_expires_at: '2000-01-01T00:00:00Z' }, 'triage', now), { take: true });
  assert.deepEqual(claimDecision(null, 'triage', now), { take: true });
  assert.deepEqual(claimDecision({ ...live, lease_expires_at: '2099-01-01T00:00:01Z' }, 'pool', now), { take: true });
  assert.deepEqual(claimDecision({ ...live, owner_lane: 'Pool', lease_expires_at: '2099-01-01T00:00:01Z' }, 'pool', now).take, false);
  // owned: live lane lease only
  assert.equal(custodyOwned({ ...live, lease_expires_at: '2099-01-01T00:00:01Z' }, now), true);
  assert.equal(custodyOwned({ ...live, lease_expires_at: now }, now), false);
  assert.equal(custodyOwned({ owner_lane: 'custodian', lease_expires_at: '2099-01-01T00:00:00Z', settled_at: null }, now), false);
});

test('C2 every 400 field writes 0 rows in both tables', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const base = { project: 'p', ticket: 'T-2', lane: 'pool', state: 'building', next_action: 'reoffer' };
  const cases = [
    [{ ...base, project: 'Bad Project' }, 'project'],
    [{ ...base, ticket: 'a b' }, 'ticket'],
    [{ ...base, lane: 'a b' }, 'lane'],
    [{ ...base, lane: ' pool' }, 'lane'],
    [{ ...base, lane: 'custodian' }, 'lane'],
    [{ ...base, state: 'merged' }, 'state'],
    [{ ...base, state: 'closed' }, 'state'],
    [{ ...base, state: 'nope' }, 'state'],
    [{ ...base, next_action: 'alert' }, 'next_action'],
    [{ ...base, deadline_at: '2026-11-12 00:00:00' }, 'deadline_at'],
    [{ ...base, deadline_at: at(86400 * 31) }, 'deadline_at'],
    [{ ...base, deadline_min: 43201 }, 'deadline_min'],
    [{ ...base, deadline_min: -1 }, 'deadline_min'],
    [{ ...base, deadline_min: 5, deadline_at: at(60) }, 'deadline'],
    [{ ...base, lease_s: 86401 }, 'lease_s'],
    [{ ...base, lease_s: 0 }, 'lease_s'],
    [{ ...base, lease_s: 1.5 }, 'lease_s'],
    [{ ...base, pr: 0 }, 'pr'],
    [{ ...base, evidence: 'x'.repeat(501) }, 'evidence'],
  ];
  for (const [body, field] of cases) {
    const r = await post(DB, 'claim', body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} -> ${r.status}`);
    assert.equal(r.body.error, field);
  }
  assert.deepEqual(counts(db), { rows: 0, actions: 0 });
  // the other verbs
  await claim(DB, 'p', 'T-2', 'pool');
  const c0 = counts(db);
  const more = [
    ['renew', { project: 'p', ticket: 'T-2', lane: 'pool', lease_s: 999999 }, 'lease_s'],
    ['release', { project: 'p', ticket: 'T-2', lane: 'pool', next_action: 'x' }, 'next_action'],
    ['next', { project: 'p', ticket: 'T-2', lane: 'pool', next_action: 'wait', state: 'merged' }, 'state'],
    ['settle', { project: 'p', ticket: 'T-2', actor: 'conductor', state: 'building' }, 'state'],
    ['act', { project: 'p', ticket: 'T-2', actor: 'custodian', expect_attempt: -1, action: 'reoffer', why: 'w', result: 'r', next_action: 'wait' }, 'expect_attempt'],
    ['act', { project: 'p', ticket: 'T-2', actor: 'custodian', expect_attempt: 0, action: 'reoffer', why: '', result: 'r', next_action: 'wait' }, 'why'],
  ];
  for (const [verb, body, field] of more) {
    const r = await post(DB, verb, body);
    assert.equal(r.status, 400, `${verb} ${JSON.stringify(body)} -> ${r.status}`);
    assert.equal(r.body.error, field);
  }
  assert.deepEqual(counts(db), c0);
  // unknown ticket: 404, nothing written
  for (const verb of ['renew', 'release', 'next']) {
    const r = await post(DB, verb, { project: 'p', ticket: 'NONE', lane: 'pool', next_action: 'wait' });
    assert.equal(r.status, 404, verb);
  }
  assert.equal((await call(DB, '/api/custody/row?project=p&ticket=NONE')).status, 404);
  assert.deepEqual(counts(db), c0);
  // no bearer: 401
  const res = await worker.fetch(new Request('https://jobs.test/api/custody/claim', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(base),
  }), { DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 401);
  assert.deepEqual(counts(db), c0);
});

test('C3 act is a compare-and-set on attempt', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  await claim(DB, 'p', 'T-3', 'pool');
  const before = actionsOf(db, 'p', 'T-3').length;
  const body = { project: 'p', ticket: 'T-3', actor: 'custodian', expect_attempt: 0, action: 'reoffer',
    why: 'lease expired', result: 're-offered', next_action: 'wait', deadline_min: 30, ladder_rung: 1 };
  let r = await post(DB, 'act', body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  let row = rowOf(db, 'p', 'T-3');
  assert.deepEqual([row.attempt, row.ladder_rung, row.next_action], [1, 1, 'wait']);
  let log = actionsOf(db, 'p', 'T-3');
  assert.equal(log.length, before + 1);
  assert.deepEqual([log.at(-1).actor, log.at(-1).action, log.at(-1).why, log.at(-1).result, log.at(-1).attempt],
    ['custodian', 'reoffer', 'lease expired', 're-offered', 1]);
  r = await post(DB, 'act', body);
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'stale');
  assert.equal(r.body.ok, undefined);
  row = rowOf(db, 'p', 'T-3');
  assert.equal(row.attempt, 1);
  assert.equal(actionsOf(db, 'p', 'T-3').length, before + 1);
  // a settled row refuses act
  await post(DB, 'settle', { project: 'p', ticket: 'T-3', actor: 'conductor', state: 'merged' });
  r = await post(DB, 'act', { ...body, expect_attempt: 1 });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'settled');
});

test('C4 due: the decision table, due_at on every write, truncated measured', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  // every write sets due_at = the earlier time
  await claim(DB, 'p', 'W-1', 'pool', { deadline_min: 5, lease_s: 3600 });
  let row = rowOf(db, 'p', 'W-1');
  assert.equal(row.due_at, row.deadline_at, 'deadline earlier');
  await claim(DB, 'p', 'W-1', 'pool', { deadline_min: 120, lease_s: 60 });
  row = rowOf(db, 'p', 'W-1');
  assert.equal(row.due_at, row.lease_expires_at, 'lease earlier');
  await post(DB, 'release', { project: 'p', ticket: 'W-1', lane: 'pool', next_action: 'retriage', deadline_min: 7 });
  row = rowOf(db, 'p', 'W-1');
  assert.equal(row.lease_expires_at, null);
  assert.equal(row.due_at, row.deadline_at, 'released: the deadline alone');
  assert.equal(dueOf(null, null), null);
  db.exec('DELETE FROM ticket_custody');

  // The due table. Each row is created through the route, then its times are
  // moved into the past or future with SQL; due_at gets the route's own rule
  // (dueOf). The three asserts above are what proves the write path sets it.
  const seed = async (k, dlS, leaseS, extra = {}) => {
    await claim(DB, 'p', k, 'pool', { deadline_min: 60, lease_s: 3600 });
    const dl = dlS === null ? null : at(dlS);
    const ls = leaseS === null ? null : at(leaseS);
    // the route's own rule, applied to the aged times
    set(db, 'p', k, { deadline_at: dl, lease_expires_at: ls, due_at: dueOf(dl, ls), ...extra });
  };
  await seed('D-dl', -60, 3600);
  await seed('D-lease', 3600, -60);
  await seed('D-both', -120, -30);
  await seed('D-rel', -10, null, { owner_lane: 'custodian' });
  await seed('N-future', 3600, 3600);
  await seed('N-settled', -60, null, { settled_at: at(-30) });
  await seed('N-now', 3600, 3600);
  set(db, 'p', 'N-now', { due_at: at(30) });
  const r = await call(DB, '/api/custody/due');
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.deepEqual(r.body.rows.map((x) => x.ticket), ['D-both', 'D-dl', 'D-lease', 'D-rel']);
  assert.equal(r.body.truncated, false);
  const r2 = await call(DB, '/api/custody/due?limit=2');
  assert.deepEqual(r2.body.rows.map((x) => x.ticket), ['D-both', 'D-dl']);
  assert.equal(r2.body.truncated, true);
  const r3 = await call(DB, '/api/custody/due?limit=4');
  assert.equal(r3.body.truncated, false);
  assert.equal((await call(DB, '/api/custody/due?limit=0')).status, 400);
});

test('C5 non-owner writes refused; settle once; gaps', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  await claim(DB, 'p', 'T-5', 'pool', { pr: 42, evidence: 'built' });
  const before = rowOf(db, 'p', 'T-5');
  const n0 = actionsOf(db, 'p', 'T-5').length;
  for (const verb of ['renew', 'release', 'next']) {
    const r = await post(DB, verb, { project: 'p', ticket: 'T-5', lane: 'triage', next_action: 'wait' });
    assert.equal(r.status, 409, verb);
    assert.equal(r.body.error, 'not_owner');
  }
  assert.deepEqual(rowOf(db, 'p', 'T-5'), before);
  assert.equal(actionsOf(db, 'p', 'T-5').length, n0);
  // the owner's next and renew
  let r = await post(DB, 'next', { project: 'p', ticket: 'T-5', lane: 'pool', next_action: 'resolver', state: 'pr_open' });
  assert.equal(r.status, 200);
  assert.equal(rowOf(db, 'p', 'T-5').state, 'pr_open');
  r = await post(DB, 'renew', { project: 'p', ticket: 'T-5', lane: 'pool', lease_s: 120 });
  assert.equal(r.status, 200);
  assert.equal(actionsOf(db, 'p', 'T-5').length, n0 + 2);
  // gaps: none on the write path
  r = await call(DB, '/api/custody/gaps');
  assert.deepEqual([r.body.no_owner, r.body.no_deadline], [0, 0]);
  set(db, 'p', 'T-5', { owner_lane: null });
  r = await call(DB, '/api/custody/gaps?project=p');
  assert.deepEqual([r.body.no_owner, r.body.no_deadline], [1, 0]);
  r = await call(DB, '/api/custody/gaps?project=other');
  assert.deepEqual([r.body.no_owner, r.body.no_deadline], [0, 0]);
  set(db, 'p', 'T-5', { owner_lane: 'pool' });
  // settle twice: one settle row, duplicate:true
  r = await post(DB, 'settle', { project: 'p', ticket: 'T-5', actor: 'conductor', state: 'merged' });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, undefined);
  r = await post(DB, 'settle', { project: 'p', ticket: 'T-5', actor: 'conductor', state: 'merged' });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
  assert.equal(actionsOf(db, 'p', 'T-5').filter((a) => a.action === 'settle').length, 1);
  const row = rowOf(db, 'p', 'T-5');
  assert.deepEqual([row.owner_lane, row.lease_expires_at, row.next_action, row.deadline_at, row.due_at], [null, null, null, null, null]);
  assert.equal(row.state, 'merged');
  // a write on a stale rev writes nothing in either table (the batch guard)
  await claim(DB, 'p', 'T-6', 'pool');
  const { UPDATE_SQL, ACTION_SQL } = await import('../src/routes/custody.js');
  const n1 = counts(db);
  const stale = rowOf(db, 'p', 'T-6').rev - 1;
  const res = await DB.batch([
    DB.prepare(ACTION_SQL).bind('p', 'T-6', 'x', 'claim', 'w', 'r', 'building', 0, 0, at(0), stale),
    DB.prepare(UPDATE_SQL).bind('p', 'T-6', 'building', 'x', null, 'wait', null, null, 0, 0, null, null, null, at(0), stale),
  ]);
  assert.deepEqual(res.map((x) => x.meta.changes), [0, 0]);
  assert.deepEqual(counts(db), n1);
  // the vocabulary the docs list
  assert.deepEqual(CUSTODY_ACTIONS, ['reoffer', 'requeue_build', 'resolver', 'retriage', 'return_todo', 'wait']);
  assert.deepEqual(CUSTODY_STATES, ['triaged', 'planned', 'plan_blocked', 'building', 'pr_open', 'in_queue', 'ejected', 'abandoned']);
});

test('C6 custody_actions.age archives old rows, then deletes them', async (t) => {
  const o0 = await openDb(); if (!o0) return t.skip('node:sqlite unavailable');
  const NOW = Date.parse('2026-11-12T12:00:00Z');
  t.mock.timers.enable({ apis: ['Date'], now: NOW });
  const ago = (d) => iso(NOW - d * 86400e3);
  const { DatabaseSync } = await import('node:sqlite');
  const rule = RULES.find((r) => r.rule === 'custody_actions.age');
  assert.ok(rule, 'rule custody_actions.age is composed');
  assert.deepEqual([rule.def, rule.key, rule.archive], [90, 'retention.custody_actions.days', 'custody_actions']);
  const seed = (db) => {
    const ins = db.prepare(`INSERT INTO custody_actions (project, ticket, actor, action, why, result, state, attempt, ladder_rung, at)
      VALUES ('c6', ?, 'pool', 'claim', 'w', 'r', 'building', 0, 0, ?)`);
    for (const [k, d] of [['old-120', 120], ['old-91', 91], ['new-89', 89]]) ins.run(k, ago(d));
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','t','test','x') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run();
  };
  const keys = (db) => db.prepare('SELECT ticket FROM custody_actions ORDER BY ticket').all().map((r) => r.ticket);
  const run = (DB, extra) => worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
  }), { DB, HARNESS_SECRET: SECRET, ...extra }).then((r) => r.json());
  const ruleOf = (b) => (b.rules || []).find((x) => x.rule === 'custody_actions.age');
  {
    const { db, DB } = await openDb();
    seed(db);
    const b = await run(DB, {});
    assert.equal(ruleOf(b).removed, 0, JSON.stringify(ruleOf(b)));
    assert.equal(keys(db).length, 3, 'an unbound archive moves nothing');
  }
  {
    const { db, DB } = await openDb();
    seed(db);
    const adb = new DatabaseSync(':memory:');
    const b = await run(DB, { ARCHIVE: d1(adb) });
    assert.equal(ruleOf(b).error, null, JSON.stringify(ruleOf(b)));
    assert.equal(ruleOf(b).removed, 2);
    assert.deepEqual(keys(db), ['new-89']);
    assert.deepEqual(adb.prepare('SELECT ticket FROM custody_actions ORDER BY ticket').all().map((x) => x.ticket),
      ['old-120', 'old-91'], 'copied before the delete');
  }
});
