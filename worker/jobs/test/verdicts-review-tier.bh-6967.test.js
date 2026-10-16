import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-6967 — a verdict row carries the risk tier of the head it judges
// (review_tier: low|medium|high) and the kind of review that wrote it
// (review_mode: full|intent|risk-tier). Two nullable columns added through
// ADDED_COLUMNS.verdicts, so an existing table gains them on the first POST.
// Driven against THE SQL THAT SHIPS (schema.sql), through worker.fetch.
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

const H = 'e'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 6967, head_sha: H, verdict: 'MERGE', source: 'lead' };
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
const history = async (db) => {
  const r = await send(db, `/api/verdicts?repo=${base.repo}&pr=${base.pr}&head=${H}`, 'GET');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.rows;
};

test('V1 a POST with review_tier and review_mode stores both, and GET answers them', async () => {
  const db = openDb();
  const r = await post(db, { review_tier: 'medium', review_mode: 'intent' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.verdict.review_tier, 'medium');
  assert.equal(r.body.verdict.review_mode, 'intent');
  const rows = await history(db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].review_tier, 'medium');
  assert.equal(rows[0].review_mode, 'intent');
});

test('V1b the risk-tier sign-off shape: low / risk-tier on a source=risk-tier MERGE', async () => {
  const db = openDb();
  const r = await post(db, { source: 'risk-tier', note: 'low risk: docs', review_tier: 'low', review_mode: 'risk-tier' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const row = db.prepare('SELECT review_tier, review_mode FROM verdicts WHERE id=?').get(r.body.verdict.id);
  assert.equal(row.review_tier, 'low');
  assert.equal(row.review_mode, 'risk-tier');
});

test('V2 a POST with neither field stores NULL in both (today\'s row)', async () => {
  const db = openDb();
  const r = await post(db);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const row = db.prepare('SELECT review_tier, review_mode FROM verdicts WHERE id=?').get(r.body.verdict.id);
  assert.equal(row.review_tier, null);
  assert.equal(row.review_mode, null);
});

test('V3 a value outside the set is refused 400 by name, and no row is written', async () => {
  const db = openDb();
  for (const [extra, name] of [
    [{ review_mode: 'fast' }, 'review_mode'],
    [{ review_tier: 'extreme' }, 'review_tier'],
    [{ review_tier: 'MEDIUM' }, 'review_tier'],
    [{ review_mode: 1 }, 'review_mode'],
  ]) {
    const r = await post(db, extra);
    assert.equal(r.status, 400, `${JSON.stringify(extra)} -> ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, new RegExp(name));
  }
  assert.equal(count(db), 0);
});

// The verdicts table as every live D1 holds it before BH-6967 (CREATE TABLE IF
// NOT EXISTS never widens a table that is already there).
const OLD_VERDICTS = `CREATE TABLE verdicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, pr INTEGER NOT NULL, head_sha TEXT NOT NULL,
  verdict TEXT NOT NULL, source TEXT NOT NULL, reviewer_model TEXT, reviewer TEXT, report_url TEXT,
  note TEXT, created_at TEXT NOT NULL, auth TEXT, human_sig TEXT)`;

test('V0 a fresh database (the shipped schema) has both columns', () => {
  const have = cols(openDb());
  assert.ok(have.includes('review_tier') && have.includes('review_mode'), `fresh verdicts columns: ${have}`);
});

test('V4 a verdicts table created without the columns gains them on the first POST', async () => {
  const db = openDb();
  db.exec('DROP TABLE verdicts');
  db.exec(OLD_VERDICTS);
  const before = cols(db);
  assert.ok(!before.includes('review_tier') && !before.includes('review_mode'), `the old table already has them: ${before}`);
  const r = await post(db, { review_tier: 'high', review_mode: 'full' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const after = cols(db);
  assert.ok(after.includes('review_tier') && after.includes('review_mode'), `columns after the POST: ${after}`);
  assert.equal(db.prepare('SELECT review_tier FROM verdicts').get().review_tier, 'high');
});
