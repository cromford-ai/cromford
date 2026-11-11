import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { onRequest as sweep } from '../functions/api/needs-sweep/[[path]].js';
import { onRequest as cockpit } from '../functions/api/cockpit/[[path]].js';

// BH-9420. The clerk staff agent owns the NEEDS count that Mission Control NOW
// shows. GET /api/needs-sweep/count answers that count to the hub, behind the
// same bearer as the sweep's other two routes. One source: needCounts lives in
// functions/_lib/needs-count.js, and the cockpit and needs-sweep both import it.
// Every case runs the REAL onRequest against a real SQLite database in D1's
// prepare/bind/all/first shape.

const SECRET = 'bh9420-fixture-secret';
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

function world() {
  const s = new DatabaseSync(':memory:');
  s.exec(SCHEMA);
  s.exec(`
    INSERT INTO alerts (id, akey, project, line, resolved) VALUES
      (1,'a1','project-3','x',0),(2,'a2','project-3','y',0),(3,'a3','project-1','z',1);
    INSERT INTO commands (id, ckey, type, project, status) VALUES
      (1,'c1','t','project-3','dead_letter'),(2,'c2','t','project-3','failed'),(3,'c3','t','project-3','done');
    INSERT INTO builds (id, bkey, project, ticket_key, stage, merged, updated_at) VALUES
      (10,'k10','project-3','TK-1','plan_blocked',0,'2026-11-01T00:00:00Z'),
      (11,'k11','project-3','TK-1','plan_deferred',0,'2026-11-02T00:00:00Z'),
      (12,'k12','project-3','TK-2','pr_created',0,'2026-11-02T00:00:00Z'),
      (13,'k13','project-3','TK-3','plan_blocked',0,'2026-11-02T00:00:00Z'),
      (14,'k14','project-3','TK-3','pr_merged',1,'2026-11-03T00:00:00Z'),
      (15,'k15','project-3','','plan_stale',0,'2026-11-03T00:00:00Z'),
      (16,'k16','project-3','TK-4','executing',0,'2026-11-03T00:00:00Z');
    INSERT INTO proposals (pkey, project, status) VALUES ('p1','project-3','gate_pending'),('p2','project-3','done');`);
  const statements = [];
  const db = {
    prepare(sql) {
      statements.push(sql);
      let binds = [];
      const st = {
        bind: (...b) => { binds = b; return st; },
        all: async () => ({ results: s.prepare(sql).all(...binds) }),
        first: async () => s.prepare(sql).get(...binds) || null,
        run: async () => ({ meta: { changes: s.prepare(sql).run(...binds).changes } })
      };
      return st;
    }
  };
  return { s, db, statements };
}

async function count(env, { method = 'GET', auth = `Bearer ${SECRET}` } = {}) {
  const headers = auth === null ? {} : { authorization: auth };
  const res = await sweep({
    request: new Request('https://mc.example/api/needs-sweep/count', { method, headers }),
    env,
    params: { path: ['count'] }
  });
  return { status: res.status, body: JSON.parse(await res.text()) };
}

test('N1: no bearer or a wrong bearer is 401; no CONSOLE_DB is 503', async () => {
  const w = world();
  assert.equal((await count({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }, { auth: null })).status, 401);
  assert.equal((await count({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }, { auth: 'Bearer nope' })).status, 401);
  const r = await count({ HARNESS_SECRET: SECRET });
  assert.equal(r.status, 503);
  assert.match(r.body.error, /CONSOLE_DB/);
  assert.equal(w.statements.length, 0, 'a refused call reads nothing');
});

test('N2: POST to count is 405', async () => {
  const w = world();
  const r = await count({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db }, { method: 'POST' });
  assert.equal(r.status, 405);
  assert.equal(w.statements.length, 0);
});

test('N3: /count needs deep-equals the cockpit /now needs on the same DB', async () => {
  const w = world();
  const r = await count({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  // alerts 2 (unresolved), commands 2 (dead_letter + failed), builds 3 (TK-1
  // newest 11, TK-2 12, the no-key row 15; TK-3's newest row is merged),
  // proposals 1.
  assert.deepEqual(r.body.needs, { alerts: 2, commands: 2, builds: 3, proposals: 1, total: 8 });
  assert.match(r.body.generated_at, /^\d{4}-\d{2}-\d{2}T/);

  const real = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status: 200 });
  try {
    const res = await cockpit({
      request: new Request('https://mc.example/api/cockpit/now', { headers: { cookie: 'dash=bh9420' } }),
      env: { CONSOLE_DB: w.db },
      params: { path: ['now'] }
    });
    assert.equal(res.status, 200);
    const now = JSON.parse(await res.text());
    assert.deepEqual(r.body.needs, now.needs);
  } finally {
    globalThis.fetch = real;
  }
});

test('N4: /count runs exactly one statement', async () => {
  const w = world();
  const r = await count({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db });
  assert.equal(r.status, 200);
  assert.equal(w.statements.length, 1, w.statements.join('\n---\n'));
});

test('N4b: a D1 throw is 502', async () => {
  const db = { prepare() { throw new Error('d1 down'); } };
  const r = await count({ HARNESS_SECRET: SECRET, CONSOLE_DB: db });
  assert.equal(r.status, 502);
  assert.match(r.body.error, /d1 down/);
});

test('N5: one NEEDS_STAGES list, in _lib/needs-count.js', () => {
  const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
  const lib = read('../functions/_lib/needs-count.js');
  assert.equal((lib.match(/const NEEDS_STAGES = \[/g) || []).length, 1, 'the lib holds the one list');
  for (const p of ['../functions/api/cockpit/[[path]].js', '../functions/api/needs-sweep/[[path]].js']) {
    const src = read(p);
    assert.equal(/const NEEDS_STAGES = \[/.test(src), false, `${p} must not re-declare NEEDS_STAGES`);
    assert.equal(/async function needCounts\(/.test(src), false, `${p} must not re-declare needCounts`);
    assert.match(src, /from '\.\.\/\.\.\/_lib\/needs-count\.js'/, `${p} imports the lib`);
  }
});
