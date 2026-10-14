// BH-4583 (BH-4574.1): Archie's factory-manager action ledger, driven through
// the REAL worker.fetch against the REAL schema.sql (the node:sqlite D1 shim),
// the way initiatives.bh-4062.test.js does it. What is pinned here is SQL
// behaviour: the claim's ON CONFLICT and payload comparison, the outcome
// compare-and-swap, the attempts bump, and the day list's order, cap and counts.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const create = (DB, body) => call(DB, '/api/archie/actions', { method: 'POST', body });
const outcome = (DB, body) => call(DB, '/api/archie/actions/outcome', { method: 'POST', body });
const get = (DB, qs) => call(DB, `/api/archie/actions${qs ? `?${qs}` : ''}`);

const BASE = {
  dedupe_key: 'spm:example-org/cromford#4501@abc123',
  project: 'cromford',
  repo: 'example-org/cromford',
  pr: 4501,
  playbook: 'stacked-parent-merged',
  mode: 'on',
  action: 'restack',
  outcome: 'started',
  why: 'parent #4500 merged; base still points at its branch',
  evidence: { parent: 4500, base: 'ticket/bh-4500' },
  actor: 'archie-fm',
};
const COLUMNS = ['id', 'dedupe_key', 'day', 'project', 'repo', 'pr', 'playbook', 'mode', 'action',
  'outcome', 'why', 'evidence', 'attempts', 'actor', 'created_at', 'updated_at'];
const countRows = (db) => db.prepare('SELECT count(*) AS n FROM archie_actions').get().n;

test('BH-4583 archie action ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('A1 schema re-applies cleanly, seeds both knobs, and has exactly the ledger columns', async () => {
    const { db } = await openDb();
    db.exec(SCHEMA);
    const val = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    assert.equal(val('archie.manage'), 'observe', 'seeded observe: the first deploy records, it does not act (review N1)');
    assert.equal(val('archie.cap.stacked-parent-merged'), '20');
    assert.equal(val('archie.manage.cromford'), undefined, 'the per-project override is not seeded');
    const cols = db.prepare('PRAGMA table_info(archie_actions)').all().map((c) => c.name);
    assert.deepEqual(cols, COLUMNS);
  });

  await t.test('A2 every route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const [method, path] of [
      ['POST', '/api/archie/actions'], ['POST', '/api/archie/actions/outcome'],
      ['GET', '/api/archie/actions?day=2026-10-05'],
    ]) {
      const body = method === 'POST' ? {} : undefined;
      assert.equal((await call(DB, path, { method, body, secret: null })).status, 401, `${method} ${path}`);
      assert.equal((await call(DB, path, { method, body, secret: 'wrong' })).status, 401, `${method} ${path} wrong bearer`);
    }
  });

  await t.test('A3 create round-trips; replay is existing; a different payload is 409', async () => {
    const { DB, db } = await openDb();
    const c = await create(DB, { ...BASE, day: '1999-01-01' });
    assert.equal(c.status, 201, JSON.stringify(c.body));
    assert.equal(c.body.ok, true);
    assert.equal(c.body.created, true);
    const a = c.body.action;
    for (const k of ['dedupe_key', 'project', 'repo', 'pr', 'playbook', 'mode', 'action', 'outcome', 'why', 'evidence', 'actor']) {
      assert.deepEqual(a[k], BASE[k], k);
    }
    assert.equal(a.attempts, 1);
    assert.equal(a.day, a.created_at.slice(0, 10), 'day comes from the server clock');
    assert.notEqual(a.day, '1999-01-01', 'a sent day is ignored');
    assert.equal(a.updated_at, a.created_at);

    const again = await create(DB, { ...BASE, action: 'noop', outcome: 'done', why: 'later', evidence: undefined, actor: 'x' });
    assert.equal(again.status, 200, JSON.stringify(again.body));
    assert.equal(again.body.existing, true);
    assert.deepEqual(again.body.action, a);
    assert.equal(countRows(db), 1);

    for (const diff of [{ pr: 4502 }, { mode: 'observe' }, { project: 'other' }, { repo: 'example-org/x' }]) {
      const r = await create(DB, { ...BASE, ...diff });
      assert.equal(r.status, 409, JSON.stringify(diff));
      assert.match(r.body.error, /exists with a different payload/);
      assert.equal(r.body.action.id, a.id);
    }
    assert.equal(countRows(db), 1);

    const noEv = await create(DB, { ...BASE, dedupe_key: 'k2', evidence: undefined });
    assert.equal(noEv.status, 201);
    assert.deepEqual(noEv.body.action.evidence, {});
  });

  await t.test('A4 each junk field is a 400 naming it', async () => {
    const { DB, db } = await openDb();
    const cases = [
      ['dedupe_key', { dedupe_key: 'has space' }], ['dedupe_key', { dedupe_key: 'x'.repeat(301) }],
      ['dedupe_key', { dedupe_key: undefined }],
      ['project', { project: 'Board' }], ['project', { project: '' }],
      ['repo', { repo: 'no-slash' }], ['repo', { repo: 'a/b/c' }],
      ['pr', { pr: 0 }], ['pr', { pr: '4501' }], ['pr', { pr: 1.5 }],
      ['playbook', { playbook: 'other' }], ['mode', { mode: 'off' }],
      ['action', { action: 'merge' }], ['outcome', { outcome: 'ok' }],
      ['why', { why: '   ' }], ['why', { why: 'x'.repeat(501) }],
      ['evidence', { evidence: { blob: 'x'.repeat(16400) } }], ['evidence', { evidence: [1] }],
      ['evidence', { evidence: null }], ['evidence', { evidence: 'str' }],
      ['actor', { actor: '' }], ['actor', { actor: 'x'.repeat(65) }],
    ];
    for (const [field, diff] of cases) {
      const r = await create(DB, { ...BASE, ...diff });
      assert.equal(r.status, 400, `${field} ${JSON.stringify(diff).slice(0, 60)}`);
      assert.deepEqual(r.body, { error: field });
    }
    assert.equal(countRows(db), 0);
  });

  await t.test('A5 two concurrent claims of one key: 201 and 200, never a 500, one row', async () => {
    const { DB, db } = await openDb();
    const rs = await Promise.all([create(DB, BASE), create(DB, BASE)]);
    assert.deepEqual(rs.map((r) => r.status).sort(), [200, 201]);
    assert.equal(countRows(db), 1);
  });

  await t.test('A6 outcome moves are legal-transition CAS writes; only deferred->started grows attempts', async () => {
    const { DB } = await openDb();
    const a = (await create(DB, BASE)).body.action;
    const move = (row, body) => outcome(DB, { id: row.id, dedupe_key: row.dedupe_key, expect_updated_at: row.updated_at, ...body });

    const done = await move(a, { outcome: 'done', action: 'noop', evidence: { sha: 'def' } });
    assert.equal(done.status, 200, JSON.stringify(done.body));
    assert.equal(done.body.ok, true);
    assert.equal(done.body.action.outcome, 'done');
    assert.equal(done.body.action.action, 'noop');
    assert.deepEqual(done.body.action.evidence, { sha: 'def' });
    assert.equal(done.body.action.why, BASE.why, 'why absent keeps the stored why');
    assert.equal(done.body.action.attempts, 1);

    const illegal = await move(done.body.action, { outcome: 'started' });
    assert.equal(illegal.status, 409);
    assert.equal(illegal.body.error, 'illegal transition done -> started');
    assert.equal(illegal.body.action.outcome, 'done');

    const b = (await create(DB, { ...BASE, dedupe_key: 'k-b' })).body.action;
    const stale = await move({ ...b, updated_at: '2000-01-01T00:00:00Z' }, { outcome: 'done' });
    assert.equal(stale.status, 409);
    assert.equal(stale.body.error, 'stale');
    assert.equal(stale.body.action.outcome, 'started', 'a stale report writes nothing');

    const def = await move(b, { outcome: 'deferred', why: 'cap reached' });
    assert.equal(def.status, 200);
    assert.equal(def.body.action.why, 'cap reached');
    assert.equal(def.body.action.attempts, 1);
    const retry = await move(def.body.action, { outcome: 'started' });
    assert.equal(retry.status, 200, JSON.stringify(retry.body));
    assert.equal(retry.body.action.attempts, 2);
    assert.equal((await move(retry.body.action, { outcome: 'deferred' })).status, 200);
    const cur = (await get(DB, `dedupe_key=k-b`)).body.action;
    assert.equal(cur.attempts, 2, 'started->deferred does not grow attempts');
    const failed = await move(cur, { outcome: 'failed' });
    assert.equal(failed.status, 200);
    assert.equal(failed.body.action.outcome, 'failed');
    assert.equal(failed.body.action.attempts, 2);

    assert.equal((await move({ ...b, id: 9999 }, { outcome: 'done' })).status, 404);
    assert.equal((await move({ ...b, dedupe_key: 'nope' }, { outcome: 'done' })).status, 404);

    for (const [field, body] of [
      ['id', { id: 0 }], ['dedupe_key', { dedupe_key: 'a b' }], ['expect_updated_at', { expect_updated_at: '' }],
      ['expect_updated_at', { expect_updated_at: 'x'.repeat(41) }], ['outcome', { outcome: 'nope' }],
      ['action', { action: 'merge' }], ['why', { why: '' }], ['evidence', { evidence: [] }],
    ]) {
      const r = await outcome(DB, { id: b.id, dedupe_key: 'k-b', expect_updated_at: b.updated_at, outcome: 'done', ...body });
      assert.equal(r.status, 400, field);
      assert.deepEqual(r.body, { error: field });
    }
  });

  await t.test('A7 GET by day: newest first, counts uncapped, truncated, summary, and junk params', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare(`INSERT INTO archie_actions (dedupe_key, day, project, repo, pr, playbook, mode, action,
      outcome, why, evidence, attempts, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,'{"n":1}',1,'archie-fm',?,?)`);
    const D = '2026-10-04';
    const seed = [
      // key, project, mode, action, outcome, created_at
      ['r1', 'cromford', 'on', 'restack', 'done', `${D}T01:00:00Z`],
      ['r2', 'cromford', 'on', 'restack', 'done', `${D}T02:00:00Z`],
      ['r3', 'project-3', 'on', 'fix_round', 'requested', `${D}T03:00:00Z`],
      ['r4', 'project-3', 'observe', 'would_restack', 'would', `${D}T04:00:00Z`],
      ['r5', 'cromford', 'on', 'noop', 'done', `${D}T05:00:00Z`],
      ['r6', 'cromford', 'on', 'restack', 'deferred', `${D}T06:00:00Z`],
      ['r7', 'cromford', 'on', 'restack', 'failed', `${D}T07:00:00Z`],
    ];
    for (const [k, p, m, a, o, ts] of seed) ins.run(k, D, p, `example-org/${p}`, 1, 'stacked-parent-merged', m, a, o, 'w', ts, ts);
    ins.run('other-day', '2026-10-03', 'project-3', 'example-org/project-3', 1, 'stacked-parent-merged', 'on', 'restack', 'done', 'w',
      '2026-10-03T09:00:00Z', '2026-10-03T09:00:00Z');

    const all = await get(DB, `day=${D}`);
    assert.equal(all.status, 200);
    assert.equal(all.body.ok, true);
    assert.equal(all.body.day, D);
    assert.deepEqual(all.body.actions.map((r) => r.dedupe_key), ['r7', 'r6', 'r5', 'r4', 'r3', 'r2', 'r1']);
    assert.deepEqual(all.body.actions[0].evidence, { n: 1 });
    assert.equal(all.body.truncated, false);
    const COUNTS = { 'stacked-parent-merged': { on: { done: 3, requested: 1, deferred: 1, failed: 1 }, observe: { would: 1 } } };
    assert.deepEqual(all.body.counts, COUNTS);

    const capped = await get(DB, `day=${D}&limit=2`);
    assert.deepEqual(capped.body.actions.map((r) => r.dedupe_key), ['r7', 'r6']);
    assert.equal(capped.body.truncated, true);
    assert.deepEqual(capped.body.counts, COUNTS, 'the limit never shortens a count');
    assert.equal((await get(DB, `day=${D}&limit=7`)).body.truncated, false);

    const project-3 = await get(DB, `day=${D}&project=project-3&playbook=stacked-parent-merged`);
    assert.deepEqual(project-3.body.actions.map((r) => r.dedupe_key), ['r4', 'r3']);
    assert.deepEqual(project-3.body.counts, { 'stacked-parent-merged': { on: { requested: 1 }, observe: { would: 1 } } });

    const s = await get(DB, `day=${D}&summary=1`);
    assert.equal(s.status, 200);
    assert.deepEqual(s.body, {
      ok: true, day: D, total: 7,
      by_outcome: { done: 3, requested: 1, would: 1, deferred: 1, failed: 1 },
      by_mode: { on: 6, observe: 1 },
      restacked: 2, repaired: 0, fix_rounds: 1, would: 1, deferred: 1, failed: 1, no_local_suites: 0,
      data_lane: { total: 0, applied: 0, escalated: 0, would: 0 },
    });
    const empty = await get(DB, 'day=2020-01-01&summary=1');
    assert.deepEqual(empty.body, {
      ok: true, day: '2020-01-01', total: 0, by_outcome: {}, by_mode: {},
      restacked: 0, repaired: 0, fix_rounds: 0, would: 0, deferred: 0, failed: 0, no_local_suites: 0,
      data_lane: { total: 0, applied: 0, escalated: 0, would: 0 },
    });
    const none = await get(DB, 'day=2020-01-01');
    assert.deepEqual(none.body, { ok: true, day: '2020-01-01', actions: [], counts: {}, truncated: false });

    const one = await get(DB, 'dedupe_key=r3');
    assert.equal(one.status, 200);
    assert.equal(one.body.action.dedupe_key, 'r3');
    assert.equal((await get(DB, 'dedupe_key=missing')).status, 404);

    for (const [qs, field] of [
      ['', 'day'], ['day=2026-1-04', 'day'], ['day=junk', 'day'], [`day=${D}&limit=0`, 'limit'],
      [`day=${D}&limit=501`, 'limit'], [`day=${D}&limit=abc`, 'limit'], [`day=${D}&summary=2`, 'summary'],
      [`day=${D}&project=Bad`, 'project'], [`day=${D}&playbook=x`, 'playbook'], ['dedupe_key=a%20b', 'dedupe_key'],
    ]) {
      const r = await get(DB, qs);
      assert.equal(r.status, 400, qs);
      assert.deepEqual(r.body, { error: field }, qs);
    }
  });
});
