import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-6970 — a verdict row carries the result of the break-it verifier that ran
// on its head: break_it = clean | failed:<k> (k 1..999) | could-not-run, or NULL
// when no break-it run happened. A nullable column added through
// ADDED_COLUMNS.verdicts. Driven against THE SQL THAT SHIPS, through worker.fetch.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token-fixture';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async (col) => {
      const row = db.prepare(sql).get(...binds) ?? null;
      return col ? (row ? row[col] : null) : row;
    },
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
    batch: async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; },
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
const cols = (db) => db.prepare('PRAGMA table_info(verdicts)').all().map((r) => r.name);

const H = 'b'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 6970, head_sha: H, verdict: 'BLOCK', source: 'lead' };
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD };

const send = (db, path, method, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', 'x-lead-verdict-token': LEAD },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: sqliteDB(db), ...ENV })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (db, extra = {}) => send(db, '/api/verdicts', 'POST', { ...base, ...extra });
const breakItOf = (db, id) => db.prepare('SELECT break_it FROM verdicts WHERE id=?').get(id).break_it;

test('B8a a POST with break_it failed:2 stores it, and GET answers it', async () => {
  const db = openDb();
  const r = await post(db, { break_it: 'failed:2', review_tier: 'medium', review_mode: 'full' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.verdict.break_it, 'failed:2');
  const g = await send(db, `/api/verdicts?repo=${base.repo}&pr=${base.pr}&head=${H}`, 'GET');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.rows.length, 1);
  assert.equal(g.body.rows[0].break_it, 'failed:2');
  assert.equal(g.body.rows[0].review_tier, 'medium');
});

test('B8b each good value from the decision table is stored verbatim', async () => {
  const db = openDb();
  for (const v of ['clean', 'could-not-run', 'failed:1', 'failed:999']) {
    const r = await post(db, { break_it: v });
    assert.equal(r.status, 201, `${v} -> ${JSON.stringify(r.body)}`);
    assert.equal(breakItOf(db, r.body.verdict.id), v);
  }
});

test('B8c each bad value is refused 400 by name, and no row is written', async () => {
  const db = openDb();
  for (const v of ['bogus', 'CLEAN', 'failed:0', 'failed:', 'failed:1000', 'failed:01', 'skipped:off', 3, '', ' clean', true]) {
    const r = await post(db, { break_it: v });
    assert.equal(r.status, 400, `${JSON.stringify(v)} -> ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /break_it/);
  }
  assert.equal(count(db), 0);
});

test('B8d an absent value and null both store NULL', async () => {
  const db = openDb();
  const a = await post(db);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(breakItOf(db, a.body.verdict.id), null);
  const n = await post(db, { break_it: null });
  assert.equal(n.status, 201, JSON.stringify(n.body));
  assert.equal(breakItOf(db, n.body.verdict.id), null);
});

// The verdicts table as a live D1 holds it after BH-6967 and before BH-6970.
const OLD_VERDICTS = `CREATE TABLE verdicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, pr INTEGER NOT NULL, head_sha TEXT NOT NULL,
  verdict TEXT NOT NULL, source TEXT NOT NULL, reviewer_model TEXT, reviewer TEXT, report_url TEXT,
  note TEXT, created_at TEXT NOT NULL, auth TEXT, human_sig TEXT, review_tier TEXT, review_mode TEXT)`;

test('B8e a fresh database (the shipped schema) has the column', () => {
  assert.ok(cols(openDb()).includes('break_it'));
});

test('B8f a verdicts table created without the column gains it on the first POST', async () => {
  const db = openDb();
  db.exec('DROP TABLE verdicts');
  db.exec(OLD_VERDICTS);
  assert.ok(!cols(db).includes('break_it'));
  const r = await post(db, { break_it: 'could-not-run' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.ok(cols(db).includes('break_it'));
  assert.equal(db.prepare('SELECT break_it FROM verdicts').get().break_it, 'could-not-run');
});
