import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-9625 — on a repo whose lead_authority_mode.<owner>.<name> row is `client`,
// a source=human MERGE stands in for the client decision maker. Whatever
// human_verdict_mode says (shadow here): the POST needs the human token and a
// note with an https approval link, and a lead-token human row never stands.
// Other repos keep the BH-3831 shadow rule. Harness: verdicts-enforce-standing.bh-3849.
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
   VALUES ('example-org/project-3', 9625, ?, ?, ?, '2026-10-01T00:00:00Z', ?)`,
).run(H1, verdict, source, auth).lastInsertRowid);

const H1 = 'c'.repeat(40);
const base = { repo: 'example-org/project-3', pr: 9625, note: 'approved by Stephanie: https://github.com/example-org/project-3/issues/1#c1', head_sha: H1, verdict: 'MERGE', source: 'human' };
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

const setClient = (db, repo = 'example-org.project-3') => db.prepare(
  "INSERT INTO settings (key, value, updated_at) VALUES (?, 'client', '2026-11-12T00:00:00Z')").run(`lead_authority_mode.${repo}`);

test('V1 client repo, shadow mode: a lead-token human MERGE is refused (403), nothing written', async () => {
  const db = openDb(); setClient(db);
  const r = await post(db);
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.match(r.body.error, /lead_authority_mode=client/);
  assert.equal(count(db), 0);
});

test('V2 client repo: a human-token MERGE with no https link is refused (400); with one it is written', async () => {
  const db = openDb(); setClient(db);
  let r = await post(db, { human: HUMAN, body: { ...base, note: 'approved by Stephanie' } });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.equal(count(db), 0);
  r = await post(db, { human: HUMAN });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(rowOf(db, r.body.verdict.id).auth, 'human-token');
});

test('V3 client repo: a human BLOCK is never asked for the token or the link', async () => {
  const db = openDb(); setClient(db);
  const r = await post(db, { body: { ...base, verdict: 'BLOCK', note: undefined } });
  assert.equal(r.status, 201, JSON.stringify(r.body));
});

test('V4 client repo, shadow mode: an older lead-token human MERGE does not stand', async () => {
  const db = openDb();
  insertRow(db, { verdict: 'MERGE', source: 'human', auth: 'lead-token' });
  let g = await get(db, QH);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing?.source, 'human', 'lane repo, shadow: the row stands (BH-3831 unchanged)');
  setClient(db);
  g = await get(db, QH);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing, null, `client repo: ${JSON.stringify(g.body.standing)}`);
});

test('V5 a repo not in client mode keeps the shadow rule: a lead-token human MERGE is written', async () => {
  const db = openDb(); setClient(db, 'example-org.other-os');
  const r = await post(db);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(rowOf(db, r.body.verdict.id).auth, 'lead-token');
});
