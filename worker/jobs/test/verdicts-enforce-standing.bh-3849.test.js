import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3849 — with human_verdict_mode=enforce, a source=human row recorded with
// only the lead token (auth='lead-token', written while the mode was shadow) no
// longer STANDS on GET /api/verdicts&head=. Pre-BH-3831 rows (auth NULL) and
// human-token rows still stand; shadow is unchanged. An unreadable mode fails
// closed: a source=human POST is 503 and writes nothing, and a GET &head= is 503
// (vd_standing rc 2, a hold). Driven against schema.sql, through worker.fetch.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const HUMAN = 'human-test-token';
const SCHEMA = jobsSchemaSql();
const MODE_SQL = /FROM settings WHERE key='human_verdict_mode'/;
// BH-3846 reads the mode through protectedMode: one SELECT, key bound as ?1.
const PROTECTED_SQL = /FROM settings WHERE key IN \(\?1, \?2\)/;
const isModeRead = (sql, binds) => MODE_SQL.test(sql) || (PROTECTED_SQL.test(sql) && binds[0] === 'human_verdict_mode');

// throwMode: the human_verdict_mode SELECT throws, every other statement runs.
function sqliteDB(db, { throwMode = false } = {}) {
  const bindAndRun = (sql, binds) => {
    const guard = () => { if (throwMode && isModeRead(sql, binds)) throw new Error('D1_ERROR: settings read failed'); };
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

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const setMode = (db, v) => db.prepare("UPDATE settings SET value=? WHERE key='human_verdict_mode'").run(v);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
const rowOf = (db, id) => db.prepare('SELECT * FROM verdicts WHERE id=?').get(id);
// A row written directly, as a pre-BH-3831 worker would have (auth NULL) or with a given auth.
const insertRow = (db, { verdict, source, auth = null }) => Number(db.prepare(
  `INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth)
   VALUES ('example-org/cromford', 3849, ?, ?, ?, '2026-10-01T00:00:00Z', ?)`,
).run(H1, verdict, source, auth).lastInsertRowid);

const H1 = 'c'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 3849, head_sha: H1, verdict: 'MERGE', source: 'human' };
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN };
const Q = `repo=${base.repo}&pr=${base.pr}`;
const QH = `${Q}&head=${H1}&standing_only=1`;

const send = (db, path, method, { body, lead = LEAD, human = null, throwMode = false } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(lead ? { 'x-lead-verdict-token': lead } : {}),
      ...(human ? { 'x-human-verdict-token': human } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: sqliteDB(db, { throwMode }), ...ENV })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (db, opts = {}) => send(db, '/api/verdicts', 'POST', { body: base, ...opts });
const get = (db, q, opts = {}) => send(db, `/api/verdicts?${q}`, 'GET', { lead: null, ...opts });

test('S1 enforce: a lead-token human row stops standing; an older NULL-auth human BLOCK stands instead', async () => {
  const db = openDb();
  const blockId = insertRow(db, { verdict: 'BLOCK', source: 'human', auth: null });
  const m = await post(db); // shadow: recorded as auth='lead-token'
  assert.equal(m.status, 201, JSON.stringify(m.body));
  assert.equal(rowOf(db, m.body.verdict.id).auth, 'lead-token');
  setMode(db, 'enforce');
  const g = await get(db, QH);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing?.id, blockId, `standing ${JSON.stringify(g.body.standing)}`);
  // With only the lead-token row on the head, nothing stands.
  const db2 = openDb();
  assert.equal((await post(db2)).status, 201);
  setMode(db2, 'enforce');
  const g2 = await get(db2, QH);
  assert.equal(g2.status, 200);
  assert.equal(g2.body.standing, null, JSON.stringify(g2.body.standing));
});

test('S2 enforce: a human-token human row stands, and so does a NULL-auth human row', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const res = await post(db, { human: HUMAN });
  assert.equal(res.status, 201);
  const g = await get(db, QH);
  assert.equal(g.body.standing?.id, res.body.verdict.id);
  const db2 = openDb();
  setMode(db2, 'enforce');
  const id = insertRow(db2, { verdict: 'MERGE', source: 'human', auth: null });
  const g2 = await get(db2, QH);
  assert.equal(g2.status, 200, JSON.stringify(g2.body));
  assert.equal(g2.body.standing?.id, id);
});

test('S3 shadow: the same lead-token human row still stands', async () => {
  const db = openDb();
  const res = await post(db);
  assert.equal(res.status, 201);
  const g = await get(db, QH);
  assert.equal(g.status, 200);
  assert.equal(g.body.standing?.id, res.body.verdict.id);
  assert.equal(g.body.standing.auth, 'lead-token');
});

test('S4 an unreadable mode: a human post is 503 and writes nothing; a box post is 201 with mode null', async () => {
  const db = openDb();
  const lead = await post(db, { throwMode: true });
  assert.equal(lead.status, 503, JSON.stringify(lead.body));
  assert.equal(lead.body.human_verdict_mode, null);
  assert.match(lead.body.error, /human_verdict_mode could not be read/);
  assert.equal(count(db), 0);
  const both = await post(db, { human: HUMAN, throwMode: true });
  assert.equal(both.status, 503, JSON.stringify(both.body));
  assert.equal(count(db), 0);
  const box = await post(db, { body: { ...base, source: 'box' }, lead: null, throwMode: true });
  assert.equal(box.status, 201, JSON.stringify(box.body));
  assert.equal(box.body.human_verdict_mode, null);
  assert.equal(count(db), 1);
});

test('S4b an unreadable mode: a lead post is 201', async () => {
  const db = openDb();
  const res = await post(db, { body: { ...base, source: 'lead' }, throwMode: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(rowOf(db, res.body.verdict.id).auth, 'lead-token');
  assert.equal(count(db), 1);
});

test('S5 enforce: an older lead MERGE stands under a newer lead-token human BLOCK (documented edge)', async () => {
  const db = openDb();
  const leadId = insertRow(db, { verdict: 'MERGE', source: 'lead', auth: 'lead-token' });
  insertRow(db, { verdict: 'BLOCK', source: 'human', auth: 'lead-token' });
  setMode(db, 'enforce');
  const g = await get(db, QH);
  assert.equal(g.status, 200);
  assert.equal(g.body.standing?.id, leadId);
  assert.equal(g.body.standing.source, 'lead');
});

test('S6 enforce on a pre-BH-3831 table (no auth column): GET widens it and the NULL-auth human row stands', async () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec('DROP TABLE verdicts');
  db.exec(`CREATE TABLE verdicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, pr INTEGER NOT NULL,
    head_sha TEXT NOT NULL, verdict TEXT NOT NULL, source TEXT NOT NULL,
    reviewer_model TEXT, reviewer TEXT, report_url TEXT, note TEXT, created_at TEXT NOT NULL)`);
  db.exec(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at)
           VALUES ('example-org/cromford', 3849, '${H1}', 'BLOCK', 'human', '2026-09-30T00:00:00Z')`);
  setMode(db, 'enforce');
  const g = await get(db, QH);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing?.id, 1);
});

test('S7 enforce: the history rows (no head) still carry the lead-token human row', async () => {
  const db = openDb();
  const res = await post(db);
  setMode(db, 'enforce');
  const g = await get(db, Q);
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.rows.map((r) => r.id), [res.body.verdict.id]);
  const gh = await get(db, `${Q}&head=${H1}`);
  assert.equal(gh.status, 200);
  assert.equal(gh.body.standing, null);
  assert.deepEqual(gh.body.rows.map((r) => r.id), [res.body.verdict.id]);
});

test('S8 an unreadable mode: GET &head= is 503; GET without head is 200', async () => {
  const db = openDb();
  insertRow(db, { verdict: 'MERGE', source: 'human', auth: 'lead-token' });
  const g = await get(db, QH, { throwMode: true });
  assert.equal(g.status, 503, JSON.stringify(g.body));
  const g2 = await get(db, Q, { throwMode: true });
  assert.equal(g2.status, 200, JSON.stringify(g2.body));
  assert.equal(g2.body.rows.length, 1);
});
