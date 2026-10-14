import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5773 — one slow human_verdict_mode read no longer fails a verdict read.
// The read is retried once; a read that still fails answers with the last good
// read of the same env.DB when it is at most 60 s old; with no good read a GET
// &head= with no source=human row on the head is answered without the mode
// (the mode only filters human rows). A source=human POST with no good read is
// still 503 (BH-3849). Driven against schema.sql, through worker.fetch, with
// ONE env.DB wrapper per fixture so the per-isolate cache can hit.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();
const PROTECTED_SQL = /FROM settings WHERE key IN \(\?1, \?2\)/;
const isModeRead = (sql, binds) => PROTECTED_SQL.test(sql) && binds[0] === 'human_verdict_mode';
const OVERLOADED = 'D1_ERROR: D1 DB is overloaded. Requests queued for too long.';
const NOW = Date.parse('2026-10-09T20:00:00Z');

test.beforeEach(() => mock.timers.enable({ apis: ['Date'], now: NOW }));
test.afterEach(() => mock.timers.reset());

// state.throws: how many human_verdict_mode reads throw next (Infinity = all).
// state.reads: how many human_verdict_mode reads ran (thrown ones included).
function sqliteDB(db, state) {
  const bindAndRun = (sql, binds) => {
    const guard = () => {
      if (!isModeRead(sql, binds)) return;
      state.reads += 1;
      if (state.throws > 0) { state.throws -= 1; throw new Error(OVERLOADED); }
    };
    return {
      first: async (col) => {
        guard();
        const row = db.prepare(sql).get(...binds) ?? null;
        return col ? (row ? row[col] : null) : row;
      },
      all: async () => { guard(); return { results: db.prepare(sql).all(...binds) }; },
      run: async () => {
        guard();
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    };
  };
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
    batch: async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; },
  };
}

const H1 = 'd'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 5773, head_sha: H1, verdict: 'MERGE', source: 'human' };
const QH = `repo=${base.repo}&pr=${base.pr}&head=${H1}&standing_only=1`;

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const setMode = (db, v) => db.prepare("UPDATE settings SET value=? WHERE key='human_verdict_mode'").run(v);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
const insertRow = (db, { verdict, source, auth = null }) => Number(db.prepare(
  `INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth)
   VALUES ('example-org/cromford', 5773, ?, ?, ?, '2026-10-09T19:00:00Z', ?)`,
).run(H1, verdict, source, auth).lastInsertRowid);

// One fixture = one sqlite db + one env.DB wrapper reused by every request.
function fixture(db = openDb()) {
  const state = { throws: 0, reads: 0 };
  const env = { DB: sqliteDB(db, state), HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD };
  const send = (path, method, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(method === 'POST' ? { 'x-lead-verdict-token': LEAD } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), env).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  return { db, state, get: () => send(`/api/verdicts?${QH}`, 'GET'), post: (b = base) => send('/api/verdicts', 'POST', b) };
}

test('C1 the mode read throws after one good read: GET standing is 200 and uses the cached enforce', async () => {
  const f = fixture();
  const leadId = insertRow(f.db, { verdict: 'MERGE', source: 'lead', auth: 'lead-token' });
  insertRow(f.db, { verdict: 'BLOCK', source: 'human', auth: 'lead-token' });
  setMode(f.db, 'enforce');
  const g1 = await f.get();
  assert.equal(g1.status, 200, JSON.stringify(g1.body));
  assert.equal(g1.body.standing?.id, leadId);
  f.state.throws = Infinity;
  mock.timers.tick(59_000);
  const g2 = await f.get();
  assert.equal(g2.status, 200, JSON.stringify(g2.body));
  // shadow or no mode would let the newer lead-token human BLOCK stand.
  assert.equal(g2.body.standing?.id, leadId, `standing ${JSON.stringify(g2.body.standing)}`);
});

test('C1b the cache expires: 61 s after the last good read, a head with a human row is 503 again', async () => {
  const f = fixture();
  insertRow(f.db, { verdict: 'MERGE', source: 'human', auth: 'lead-token' });
  assert.equal((await f.get()).status, 200);
  f.state.throws = Infinity;
  mock.timers.tick(61_000);
  const g = await f.get();
  assert.equal(g.status, 503, JSON.stringify(g.body));
});

test('C2 no good read: a source=human POST is 503 and writes nothing (BH-3849 unchanged)', async () => {
  const f = fixture();
  f.state.throws = Infinity;
  const p = await f.post();
  assert.equal(p.status, 503, JSON.stringify(p.body));
  assert.match(p.body.error, /human_verdict_mode could not be read/);
  assert.equal(p.body.human_verdict_mode, null);
  assert.equal(count(f.db), 0);
});

test('C3 no good read and no source=human row on the head: GET standing is 200', async () => {
  const f = fixture();
  const leadId = insertRow(f.db, { verdict: 'MERGE', source: 'lead', auth: 'lead-token' });
  f.state.throws = Infinity;
  const g = await f.get();
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing?.id, leadId);
});

test('C4 a mode read that throws once and then succeeds: one retry, GET is 200', async () => {
  const f = fixture();
  const humanId = insertRow(f.db, { verdict: 'MERGE', source: 'human', auth: 'lead-token' });
  f.state.throws = 1;
  const g = await f.get();
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing?.id, humanId);
  assert.equal(f.state.reads, 2);
});

test('C5 the cache is per env.DB: a good read on wrapper A does not answer wrapper B', async () => {
  const db = openDb();
  insertRow(db, { verdict: 'MERGE', source: 'human', auth: 'lead-token' });
  const a = fixture(db);
  assert.equal((await a.get()).status, 200);
  const b = fixture(db);
  b.state.throws = Infinity;
  const g = await b.get();
  assert.equal(g.status, 503, JSON.stringify(g.body));
});
