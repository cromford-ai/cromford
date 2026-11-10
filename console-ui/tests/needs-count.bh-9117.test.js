import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest } from '../functions/api/cockpit/[[path]].js';

// BH-9117. NOW said "4823 need a person" because NEEDS counted every parked or
// pr_created build row, and a ticket with six old attempts counted six. The
// rule now: one row per (project, ticket), the newest by id, counted only when
// that newest row is itself parked or pr_created. Every case runs the REAL
// onRequest against a real SQLite database in D1's prepare/bind/all/first
// shape; only the console's session probe (fetch) is stubbed.

const SCHEMA = `
  CREATE TABLE boards (project TEXT PRIMARY KEY, paused INTEGER, automerge INTEGER, last_run_at TEXT,
    last_rc INTEGER, last_summary TEXT, disk TEXT, mem TEXT, updated_at TEXT);
  CREATE TABLE builds (id INTEGER PRIMARY KEY, bkey TEXT, project TEXT, ticket_key TEXT, stage TEXT,
    tier INTEGER, verdict TEXT, pr_url TEXT, merged INTEGER DEFAULT 0, updated_at TEXT);
  CREATE TABLE runs (id INTEGER PRIMARY KEY, rkey TEXT, project TEXT, kind TEXT, rc INTEGER, summary TEXT,
    started_at TEXT, finished_at TEXT);
  CREATE TABLE events (id INTEGER PRIMARY KEY, ts TEXT, project TEXT, type TEXT, detail TEXT);
  CREATE TABLE alerts (id INTEGER PRIMARY KEY, akey TEXT, ts TEXT, project TEXT, line TEXT, resolved INTEGER DEFAULT 0);
  CREATE TABLE commands (id INTEGER PRIMARY KEY, ckey TEXT, type TEXT, project TEXT, status TEXT, attempts INTEGER,
    result TEXT, created_at TEXT, updated_at TEXT);
  CREATE TABLE proposals (pkey TEXT PRIMARY KEY, project TEXT, slug TEXT, title TEXT, summary TEXT, score INTEGER,
    status TEXT, updated_at TEXT);`;

function world(builds = []) {
  const s = new DatabaseSync(':memory:');
  s.exec(SCHEMA);
  const ins = s.prepare(`INSERT INTO builds (id, bkey, project, ticket_key, stage, merged, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)`);
  for (const b of builds) {
    ins.run(b.id, `k${b.id}`, b.project || 'project-3', b.ticket_key ?? '', b.stage, b.merged || 0,
      b.updated_at || '2026-07-22T10:00:00Z');
  }
  const statements = [];
  const db = {
    prepare(sql) {
      statements.push(sql);
      let binds = [];
      const st = {
        bind: (...b) => { binds = b; return st; },
        all: async () => ({ results: s.prepare(sql).all(...binds) }),
        first: async () => s.prepare(sql).get(...binds) || null
      };
      return st;
    }
  };
  return { s, db, statements };
}

let seq = 0;
async function call(db, path, search = '') {
  const real = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status: 200 });
  try {
    const res = await onRequest({
      request: new Request(`https://console.example.pages.dev/api/cockpit/${path}${search}`, {
        method: 'GET', headers: { cookie: `dash=bh9117-${++seq}` }
      }),
      env: { CONSOLE_DB: db },
      params: { path: [path] }
    });
    assert.equal(res.status, 200, await res.clone().text());
    return JSON.parse(await res.text());
  } finally {
    globalThis.fetch = real;
  }
}

test('REPRO: an old parked row plus a newer merged row for the same ticket counts 0', async () => {
  const w = world([
    { id: 1, ticket_key: 'BH-1', stage: 'plan_blocked', updated_at: '2026-07-22T10:00:00Z' },
    { id: 2, ticket_key: 'BH-1', stage: 'pr_merged', merged: 1, updated_at: '2026-07-23T10:00:00Z' }
  ]);
  const now = await call(w.db, 'now');
  assert.equal(now.needs.builds, 0);
  const needs = await call(w.db, 'needs');
  assert.equal(needs.counts.builds, 0);
  assert.equal(needs.builds.length, 0);
});

test('six parked attempts of one ticket count 1, and the list shows the newest only', async () => {
  const rows = [3, 4, 7, 9, 11, 12].map((id) => ({ id, ticket_key: 'BH-2', stage: 'plan_deferred' }));
  const w = world(rows);
  assert.equal((await call(w.db, 'now')).needs.builds, 1);
  const needs = await call(w.db, 'needs');
  assert.equal(needs.counts.builds, 1);
  assert.deepEqual(needs.builds.map((b) => b.id), [12]);
});

test('a parked row with a newer unfinished row is left to the stale count', async () => {
  const w = world([
    { id: 5, ticket_key: 'BH-3', stage: 'plan_blocked' },
    { id: 6, ticket_key: 'BH-3', stage: 'executing' }
  ]);
  assert.equal((await call(w.db, 'now')).needs.builds, 0);
});

test('an older pr_created row behind a newer superseded row counts 0; a newest parked row counts 1', async () => {
  const w = world([
    { id: 20, ticket_key: 'BH-4', stage: 'pr_created' },
    { id: 21, ticket_key: 'BH-4', stage: 'superseded' },
    { id: 22, ticket_key: 'BH-5', stage: 'pr_merged', merged: 1 },
    { id: 23, ticket_key: 'BH-5', stage: 'plan_blocked' }
  ]);
  assert.equal((await call(w.db, 'now')).needs.builds, 1);
  assert.deepEqual((await call(w.db, 'needs')).builds.map((b) => b.id), [23]);
});

test('rows with no ticket key never pair: two keyless parked rows count 2', async () => {
  const w = world([
    { id: 30, ticket_key: '', stage: 'plan_blocked' },
    { id: 31, ticket_key: '', stage: 'plan_stale' },
    { id: 32, ticket_key: null, stage: 'plan_malformed' }
  ]);
  assert.equal((await call(w.db, 'now')).needs.builds, 3);
  assert.equal((await call(w.db, 'needs')).builds.length, 3);
});

test('the same ticket key on another project is another ticket', async () => {
  const w = world([
    { id: 40, project: 'project-3', ticket_key: 'TK-1', stage: 'plan_blocked' },
    { id: 41, project: 'project-4', ticket_key: 'TK-1', stage: 'pr_merged', merged: 1 }
  ]);
  assert.equal((await call(w.db, 'now')).needs.builds, 1);
});

test('wrong project: /needs?project=other sees 0 rows of project-3', async () => {
  const w = world([
    { id: 50, ticket_key: 'TK-2', stage: 'plan_blocked' },
    { id: 51, ticket_key: 'TK-3', stage: 'pr_created' }
  ]);
  const other = await call(w.db, 'needs', '?project=other');
  assert.equal(other.counts.builds, 0);
  assert.equal(other.builds.length, 0);
  const own = await call(w.db, 'needs', '?project=project-3');
  assert.equal(own.counts.builds, 2);
  assert.equal(own.builds.length, 2);
});

test('statement count: /now runs 5 statements, /needs runs 6', async () => {
  const w = world([{ id: 60, ticket_key: 'TK-4', stage: 'plan_blocked' }]);
  await call(w.db, 'now');
  assert.equal(w.statements.length, 5);
  w.statements.length = 0;
  await call(w.db, 'needs');
  assert.equal(w.statements.length, 6);
});

test('EXPLAIN QUERY PLAN of the counts statement on 5000 rows has no correlated subquery', async () => {
  const w = world();
  const ins = w.s.prepare(`INSERT INTO builds (id, bkey, project, ticket_key, stage, merged, updated_at)
    VALUES (?, ?, ?, ?, ?, 0, '2026-07-22T10:00:00Z')`);
  const stages = ['plan_blocked', 'plan_deferred', 'pr_created', 'executing', 'pr_merged'];
  const newest = new Map();
  for (let i = 1; i <= 5000; i++) {
    const row = [`p${i % 3}`, `BH-${i % 500}`, stages[Math.floor(i / 7) % 5]];
    ins.run(i, `k${i}`, ...row);
    newest.set(`${row[0]}|${row[1]}`, row[2]);
  }
  const want = [...newest.values()].filter((st) => ['plan_blocked', 'plan_deferred', 'pr_created'].includes(st)).length;
  const now = await call(w.db, 'now');
  assert.ok(want > 0 && want < 1500, `fixture: ${want}`);
  assert.equal(now.needs.builds, want);
  const sql = w.statements.find((q) => q.includes('AS alerts,'));
  assert.ok(sql, 'the counts statement ran');
  const binds = ['plan_blocked', 'plan_deferred', 'plan_stale', 'plan_malformed', 'pr_created'];
  const plan = w.s.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
  assert.ok(plan.length > 0);
  assert.ok(!plan.some((d) => /CORRELATED/.test(d)), plan.join('\n'));
  // The inner MAX(id) GROUP BY is a LIST SUBQUERY run once, not a per-row search.
  assert.ok(plan.some((d) => /LIST SUBQUERY/.test(d)), plan.join('\n'));
});
