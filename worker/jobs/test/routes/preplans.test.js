import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SECRET, call, iso, now, worker } from '../lib/harness.js';
import { jobsSchemaSql } from '../lib/jobs-schema.js';

const PP = (over) => ({
  project: 'project-5', ticket_key: 'TK-1', base_sha: 'abc1234', ticket_fp: 'fp-1',
  planned_files: 'src/lib/pay.ts\n', plan_md: '## Scope\nTouch src/lib/pay.ts.\n',
  bytes: 40, box: 'box-project-4-1', created_at: iso(60e3), updated_at: iso(60e3),
  ...over
});

const ppBody = (over) => ({
  project: 'project-5', ticket_key: 'TK-1', base_sha: 'abc1234', ticket_fp: 'fp-1',
  planned_files: 'src/lib/pay.ts\n', plan_md: '## Scope\nTouch src/lib/pay.ts.\n',
  box: 'box-project-4-1', ...over
});

test('a preplan cannot be written or read without the bearer', async () => {
  const w = await call('/api/preplans', { method: 'POST', secret: null, body: ppBody() });
  assert.equal(w.status, 401);
  const r = await call('/api/preplans?project=project-5&key=TK-1', { secret: null });
  assert.equal(r.status, 401);
});

test('a preplan upserts on (project, ticket_key) and never echoes the plan back', async () => {
  const state = { preplans: [] };
  const r = await call('/api/preplans', { method: 'POST', body: ppBody(), state });
  assert.equal(r.status, 200);
  // A re-plan after the thread moved REPLACES the row: the only pre-plan anyone
  // should adopt is the newest one for that ticket.
  await call('/api/preplans', { method: 'POST', state, body: ppBody({ plan_md: '## Scope\nsecond pass.\n', ticket_fp: 'fp-2' }) });
  assert.equal(state.preplans.length, 1, 'a second publish made a second row');
  assert.equal(state.preplans[0].ticket_fp, 'fp-2');
  const ins = r.db._calls.find((c) => /INSERT INTO preplans/.test(c.sql));
  assert.ok(ins, 'no INSERT INTO preplans was issued');
  assert.match(ins.sql, /ON CONFLICT\(project, ticket_key\) DO UPDATE/);
  assert.ok(ins.binds.includes('## Scope\nTouch src/lib/pay.ts.\n'), 'the plan body never reached the bind list');
  // The publisher already has the plan on disk; echoing 40KB back onto a box
  // that is mid-pre-plan is pure cost.
  assert.equal(r.body.preplan.plan_md, undefined);
  assert.equal(r.body.preplan.ticket_key, 'TK-1');
});

test('an unverifiable or empty preplan is refused, and an over-size one is never truncated', async () => {
  const empty = await call('/api/preplans', { method: 'POST', body: ppBody({ plan_md: '   ' }) });
  assert.equal(empty.status, 400);
  assert.equal(empty.db._calls.filter((c) => /INSERT INTO preplans/.test(c.sql)).length, 0);
  // No base sha means preplan_check can never judge the plan, and an unjudgeable
  // pre-plan is discarded at adopt — so it is refused at the door instead.
  const bad = await call('/api/preplans', { method: 'POST', body: ppBody({ base_sha: 'not a sha' }) });
  assert.equal(bad.status, 400);
  assert.equal(bad.db._calls.filter((c) => /INSERT INTO preplans/.test(c.sql)).length, 0);
  const noKey = await call('/api/preplans', { method: 'POST', body: ppBody({ ticket_key: 'TS 1/../x' }) });
  assert.equal(noKey.status, 400);
  // A TRUNCATED plan is the one failure mode worse than no plan at all: the
  // builder would execute half a design. 413, and the box logs REFUSED.
  const big = await call('/api/preplans', { method: 'POST', body: ppBody({ plan_md: 'x'.repeat(200001) }) });
  assert.equal(big.status, 413);
  assert.equal(big.db._calls.filter((c) => /INSERT INTO preplans/.test(c.sql)).length, 0);
  // And the FILE LIST gets the same answer, for a sharper reason: a prefix of it
  // is worse than none. preplan_check only marks a plan stale for files it can
  // see and the overlap guard only defers for files it can see, so everything
  // past a cut would fail OPEN — the direction that ships a wrong build.
  const files = await call('/api/preplans', {
    method: 'POST', body: ppBody({ planned_files: 'src/a.ts\n'.repeat(12500) })
  });
  assert.equal(files.status, 413);
  assert.equal(files.db._calls.filter((c) => /INSERT INTO preplans/.test(c.sql)).length, 0);
});

test('the preplans table is self-applied: CREATE before the first statement that needs it', async () => {
  const w = await call('/api/preplans', { method: 'POST', body: ppBody() });
  assert.equal(w.status, 200);
  const wsql = w.db._calls.map((c) => c.sql);
  const created = wsql.findIndex((q) => /CREATE TABLE IF NOT EXISTS preplans/.test(q));
  const indexed = wsql.findIndex((q) => /CREATE INDEX IF NOT EXISTS idx_preplans_project/.test(q));
  const inserted = wsql.findIndex((q) => /INSERT INTO preplans/.test(q));
  assert.ok(created >= 0, 'the write never created the table it writes to');
  assert.ok(created < inserted, 'the INSERT ran before the CREATE');
  assert.ok(indexed >= 0 && indexed < inserted, 'the index was not created before the first write');
  // The read too: on a fresh database the hub relays and the guard asks before
  // any box has published, and an honest 404 beats a 500 that reads as an outage.
  const r = await call('/api/preplans?project=project-5&key=TK-9', { state: { preplans: [] } });
  assert.equal(r.status, 404);
  const rsql = r.db._calls.map((c) => c.sql);
  const rci = rsql.findIndex((q) => /CREATE TABLE IF NOT EXISTS preplans/.test(q));
  const rsi = rsql.findIndex((q) => /SELECT \* FROM preplans/.test(q));
  assert.ok(rci >= 0, 'the read never created the table it reads from');
  assert.ok(rsi >= 0, 'the read never issued its SELECT');
  assert.ok(rci < rsi, 'the read ran before the CREATE');
  // Memoised per DB handle: one CREATE per handle, not one per request.
  const db = w.db;
  await worker.fetch(new Request('https://jobs.test/api/preplans', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(ppBody({ ticket_key: 'TK-2' }))
  }), { DB: db, HARNESS_SECRET: SECRET });
  assert.equal(db._calls.filter((c) => /CREATE TABLE IF NOT EXISTS preplans/.test(c.sql)).length, 1,
    'the CREATE ran again on a DB handle that had already been prepared');
});

test('the self-applied CREATE and schema.sql describe the same preplans table', async () => {
  const cols = (sql) => {
    const body = /CREATE TABLE IF NOT EXISTS preplans \(([\s\S]*?)\)\s*;?\s*$/.exec(
      sql.replace(/\s*--[^\n]*/g, '').trim());
    assert.ok(body, `no preplans CREATE found in: ${sql.slice(0, 120)}`);
    return body[1].split(',').map((c) => c.trim().replace(/\s+/g, ' '))
      .filter(Boolean).map((c) => (/^PRIMARY KEY/i.test(c) ? c.replace(/\s*\(\s*/, ' (') : c));
  };
  const w = await call('/api/preplans', { method: 'POST', body: ppBody() });
  const issued = w.db._calls.find((c) => /CREATE TABLE IF NOT EXISTS preplans/.test(c.sql)).sql;
  const schema = jobsSchemaSql();
  const declared = /CREATE TABLE IF NOT EXISTS preplans \([\s\S]*?\n\);/.exec(schema);
  assert.ok(declared, 'schema.sql no longer declares preplans');
  assert.deepEqual(cols(issued), cols(declared[0]));
  assert.ok(/CREATE INDEX IF NOT EXISTS idx_preplans_project ON preplans\(project, updated_at\)/
    .test(schema), 'schema.sql and ensureTable disagree about the index');
});

test('a preplan write prunes the table on its way out, in one bounded statement', async () => {
  const r = await call('/api/preplans', { method: 'POST', body: ppBody() });
  const del = r.db._calls.filter((c) => /DELETE FROM preplans/.test(c.sql));
  assert.equal(del.length, 1, 'the housekeeping DELETE must run exactly once per write');
  assert.match(del[0].sql, /WHERE updated_at < \?1/);
  const cutoff = new Date(del[0].binds[0]);
  const age = (now - cutoff.getTime()) / 86400e3;   // `now` is this file's single clock anchor
  assert.ok(age > 13.5 && age < 14.5, `retention cutoff was ${age} days ago`);
});

test('GET one preplan carries the plan, a missing one is a 404', async () => {
  const r = await call('/api/preplans?project=project-5&key=TK-1', { state: { preplans: [PP()] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.preplan.plan_md, '## Scope\nTouch src/lib/pay.ts.\n');
  assert.equal(r.body.preplan.base_sha, 'abc1234');
  assert.equal(r.body.preplan.ticket_fp, 'fp-1');
  const miss = await call('/api/preplans?project=project-5&key=TK-9', { state: { preplans: [PP()] } });
  assert.equal(miss.status, 404);
});

test('the preplan index never carries plan bodies and is bounded', async () => {
  const r = await call('/api/preplans?project=project-5', {
    state: { preplans: [PP(), PP({ ticket_key: 'TK-2' })] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.preplans.length, 2);
  for (const row of r.body.preplans) {
    assert.equal(row.plan_md, undefined, 'a plan body rode along on the index');
    assert.ok(row.planned_files !== undefined, 'the index owes the overlap guard the file list');
  }
  const sel = r.db._calls.find((c) => /FROM preplans/.test(c.sql) && /ORDER BY/.test(c.sql));
  // The digit guard is the assertion, not decoration: a bare /LIMIT 500/ also
  // matches LIMIT 5000, so widening the bound tenfold would leave this green.
  assert.match(sel.sql, /LIMIT 500(?!\d)/);
});

// BH-5799: the pre-planner's thread stamp rides the row, so a builder that
// adopts the plan from the DB knows which comments are newer than the plan.
test('a preplan carries thread_at through the row, and a malformed stamp is stored NULL', async () => {
  const state = { preplans: [] };
  const r = await call('/api/preplans', { method: 'POST', state, body: ppBody({ thread_at: '2026-10-09T22:00:00Z' }) });
  assert.equal(r.status, 200);
  const ins = r.db._calls.find((c) => /INSERT INTO preplans/.test(c.sql));
  assert.match(ins.sql, /thread_at=\?10/, 'a re-publish must replace the stamp too');
  assert.ok(r.db._calls.some((c) => /ALTER TABLE preplans ADD COLUMN thread_at TEXT/.test(c.sql)),
    'the POST never added the thread_at column to the live table');
  const g = await call('/api/preplans?project=project-5&key=TK-1', { state });
  assert.equal(g.body.preplan.thread_at, '2026-10-09T22:00:00Z');
  await call('/api/preplans', { method: 'POST', state, body: ppBody({ thread_at: 'yesterday' }) });
  assert.equal(state.preplans[0].thread_at, null);
  await call('/api/preplans', { method: 'POST', state, body: ppBody() });
  assert.equal(state.preplans[0].thread_at, null);
});
