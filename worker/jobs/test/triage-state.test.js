import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { CREATED_TABLES } from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// TRIAGE-STATE (the operator, 2026-09-28): one row per ticket that says what the
// triage model last decided about it and which INPUT HASH that verdict was made
// against, so a tick can tell, before it spends a token, whether a ticket's
// inputs moved since. Driven through the worker's real fetch handler against
// THE SQL THAT SHIPS (schema.sql into node:sqlite): every claim below is a
// property of the shipped statements, not of a stub that answers `changes:1`.
//
// The routes:
//   GET /api/triage-state/:project/:key   one row, 404 when there is none
//   GET /api/triage-state?project=P[&due=1][&limit=N]
//   PUT /api/triage-state                 one row, or {rows:[...]} (<= 200)
// A PUT names only the columns it carries: the pre-check's observe write
// (input_hash + last_decision) must never erase the verdict a session wrote.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const H64 = 'a'.repeat(64);
const H64B = 'b'.repeat(64);

async function db() {
  const o = await openDb();
  return o;
}

const call = (o, path, { method = 'GET', body, auth = true } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: o.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const COLS = [
  'input_hash', 'last_decision', 'last_decision_at', 'last_mode', 'next_recheck_at', 'project',
  'reason', 'ticket_key', 'ticket_label', 'triaged_at', 'updated_at', 'verdict', 'verdict_hash',
  'waiting_on',
];
const cols = (d, table) => d.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name).sort();

test('(h1) schema: triage_state re-applies cleanly and has exactly the documented columns; CREATED_TABLES builds the same', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  o.db.exec(SCHEMA); // re-applied, as bin/harness-sync.sh does on every deploy
  assert.deepEqual(cols(o.db, 'triage_state'), COLS);
  const { DatabaseSync } = await import('node:sqlite');
  const fresh = new DatabaseSync(':memory:');
  assert.ok(Array.isArray(CREATED_TABLES.triage_state), 'CREATED_TABLES.triage_state must exist (the self-create belt)');
  for (const sql of CREATED_TABLES.triage_state) fresh.exec(sql);
  assert.deepEqual(cols(fresh, 'triage_state'), COLS);
  const pk = o.db.prepare('PRAGMA table_info(triage_state)').all().filter((c) => c.pk > 0).map((c) => c.name).sort();
  assert.deepEqual(pk, ['project', 'ticket_key']);
});

test('(i1) PUT one row, then GET it back by project and key', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await call(o, '/api/triage-state', {
    method: 'PUT',
    body: {
      project: 'cromford', ticket_key: '2657', ticket_label: 'BH-2657', input_hash: H64,
      verdict: 'buildable', waiting_on: 'team', verdict_hash: H64, triaged_at: '2026-09-28T10:00:00Z',
      next_recheck_at: '2026-09-29T10:00:00Z', reason: 'DECISION launch: client answered', last_decision: 'llm new',
      last_mode: 'shadow',
    },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.upserted, 1);
  const g = await call(o, '/api/triage-state/cromford/2657');
  assert.equal(g.status, 200);
  const row = g.body.triage_state;
  assert.equal(row.verdict, 'buildable');
  assert.equal(row.verdict_hash, H64);
  assert.equal(row.input_hash, H64);
  assert.equal(row.ticket_label, 'BH-2657');
  assert.equal(row.next_recheck_at, '2026-09-29T10:00:00Z');
  assert.ok(row.updated_at, 'updated_at is stamped by the worker');
  assert.ok(row.last_decision_at, 'last_decision_at is stamped when last_decision is written');
});

test('(i2) a partial PUT (the observe write) never erases the verdict', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  await call(o, '/api/triage-state', {
    method: 'PUT',
    body: { project: 'p1', ticket_key: '7', input_hash: H64, verdict: 'needs_clarification', waiting_on: 'client',
            verdict_hash: H64, triaged_at: '2026-09-28T10:00:00Z', next_recheck_at: '2026-09-29T10:00:00Z', reason: 'asked' },
  });
  const r = await call(o, '/api/triage-state', {
    method: 'PUT', body: { project: 'p1', ticket_key: '7', input_hash: H64B, last_decision: 'llm changed', last_mode: 'shadow' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const row = (await call(o, '/api/triage-state/p1/7')).body.triage_state;
  assert.equal(row.input_hash, H64B, 'the observed hash is written');
  assert.equal(row.last_decision, 'llm changed');
  assert.equal(row.verdict, 'needs_clarification', 'the verdict is untouched');
  assert.equal(row.verdict_hash, H64, 'verdict_hash is untouched');
  assert.equal(row.waiting_on, 'client');
  assert.equal(row.triaged_at, '2026-09-28T10:00:00Z');
  assert.equal(row.reason, 'asked');
});

test('(i3) a batch PUT upserts every row; more than 200 rows is refused whole', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  const rows = Array.from({ length: 5 }, (_, i) => ({ ticket_key: String(100 + i), input_hash: H64, last_decision: 'skip unchanged' }));
  const r = await call(o, '/api/triage-state', { method: 'PUT', body: { project: 'p2', rows } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.upserted, 5);
  const l = await call(o, '/api/triage-state?project=p2');
  assert.equal(l.body.triage_state.length, 5);
  const big = Array.from({ length: 201 }, (_, i) => ({ ticket_key: String(i), input_hash: H64 }));
  const r2 = await call(o, '/api/triage-state', { method: 'PUT', body: { project: 'p3', rows: big } });
  assert.equal(r2.status, 413);
  const l2 = await call(o, '/api/triage-state?project=p3');
  assert.equal(l2.body.triage_state.length, 0, 'a refused batch writes nothing');
  // one bad row refuses the whole batch, before any write
  const mixed = [{ ticket_key: '1', input_hash: H64 }, { ticket_key: 'bad key!', input_hash: H64 }];
  const r3 = await call(o, '/api/triage-state', { method: 'PUT', body: { project: 'p4', rows: mixed } });
  assert.equal(r3.status, 400);
  assert.equal((await call(o, '/api/triage-state?project=p4')).body.triage_state.length, 0);
});

test('(i4) validation: every malformed field is a 400 and writes nothing', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  const base = { project: 'p5', ticket_key: '9', input_hash: H64 };
  const bad = [
    { ...base, project: 'no spaces allowed' },
    { ...base, project: '' },
    { ...base, ticket_key: '' },
    { ...base, ticket_key: 'x/y' },
    { ...base, ticket_key: 'k'.repeat(65) },
    { ...base, input_hash: 'not-hex' },
    { ...base, verdict_hash: 'zz' },
    { ...base, verdict: 'yolo' },
    { ...base, waiting_on: 'somebody' },
    { ...base, triaged_at: 'yesterday' },
    { ...base, next_recheck_at: '2026-09-28' },
    { ...base, last_mode: 'live' },
    { project: 'p5', ticket_key: '9' }, // nothing to write
  ];
  for (const b of bad) {
    const r = await call(o, '/api/triage-state', { method: 'PUT', body: b });
    assert.equal(r.status, 400, `expected 400 for ${JSON.stringify(b)}, got ${r.status}`);
  }
  assert.equal((await call(o, '/api/triage-state?project=p5')).body.triage_state.length, 0);
  // every documented verdict is accepted
  for (const v of ['buildable', 'needs_clarification', 'waiting_client', 'queued', 'hold', 'closed', 'blocked', 'triaged']) {
    const r = await call(o, '/api/triage-state', { method: 'PUT', body: { ...base, ticket_key: `v-${v}`, verdict: v } });
    assert.equal(r.status, 200, `verdict ${v} must be accepted`);
  }
});

test('(i5) list: project required, due=1 returns only rows whose recheck is due, limit caps with truncated', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  assert.equal((await call(o, '/api/triage-state')).status, 400);
  const past = '2020-01-01T00:00:00Z', future = '2099-01-01T00:00:00Z';
  await call(o, '/api/triage-state', {
    method: 'PUT',
    body: { project: 'p6', rows: [
      { ticket_key: 'a', input_hash: H64, verdict: 'triaged', verdict_hash: H64, next_recheck_at: past },
      { ticket_key: 'b', input_hash: H64, verdict: 'triaged', verdict_hash: H64, next_recheck_at: future },
      { ticket_key: 'c', input_hash: H64 },
    ] },
  });
  await call(o, '/api/triage-state', { method: 'PUT', body: { project: 'other', ticket_key: 'z', input_hash: H64 } });
  const all = await call(o, '/api/triage-state?project=p6');
  assert.deepEqual(all.body.triage_state.map((r) => r.ticket_key).sort(), ['a', 'b', 'c']);
  assert.equal(all.body.truncated, false);
  const due = await call(o, '/api/triage-state?project=p6&due=1');
  assert.deepEqual(due.body.triage_state.map((r) => r.ticket_key), ['a']);
  const lim = await call(o, '/api/triage-state?project=p6&limit=2');
  assert.equal(lim.body.triage_state.length, 2);
  assert.equal(lim.body.truncated, true);
  assert.equal((await call(o, '/api/triage-state?project=p6&limit=0')).status, 400);
});

test('(i6) GET of an unknown key is 404; a malformed key is 400', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  assert.equal((await call(o, '/api/triage-state/p7/404')).status, 404);
  assert.equal((await call(o, '/api/triage-state/p7/bad%20key')).status, 400);
});

test('(i7) the routes sit behind the bearer', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  assert.equal((await call(o, '/api/triage-state?project=p8', { auth: false })).status, 401);
  assert.equal((await call(o, '/api/triage-state', { method: 'PUT', auth: false, body: { project: 'p8', ticket_key: '1', input_hash: H64 } })).status, 401);
});

test('(i8) a table the deploy never created is created by the belt on first use', async (t) => {
  const o = await db();
  if (!o) return t.skip('node:sqlite unavailable');
  o.db.exec('DROP TABLE triage_state');
  const r = await call(o, '/api/triage-state', { method: 'PUT', body: { project: 'p9', ticket_key: '1', input_hash: H64 } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal((await call(o, '/api/triage-state/p9/1')).status, 200);
});
