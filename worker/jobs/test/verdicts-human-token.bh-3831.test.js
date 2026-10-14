import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3831 — a source=human verdict is only provably human when it carries the
// human verdict token (x-human-verdict-token = the worker secret
// HUMAN_VERDICT_TOKEN, held on the operator's Mac only). The lead token alone is shared
// with the hub's lead lane, so a human row posted with only it is recorded and
// marked (verdicts.auth='lead-token') in shadow mode, and refused 403 in enforce
// mode. The mode is the human_verdict_mode settings row, and only the human
// token may change it. Driven against THE SQL THAT SHIPS (schema.sql), through
// worker.fetch.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const HUMAN = 'human-test-token';
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
const mode = (db) => db.prepare("SELECT value FROM settings WHERE key='human_verdict_mode'").get()?.value;
const setMode = (db, v) => db.prepare("UPDATE settings SET value=? WHERE key='human_verdict_mode'").run(v);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
const rowOf = (db, id) => db.prepare('SELECT * FROM verdicts WHERE id=?').get(id);

const H1 = 'b'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 3831, head_sha: H1, verdict: 'MERGE', source: 'human' };
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN };

// lead/human: the header values (null = omitted). env: overrides the worker env.
const send = (db, path, method, { body, lead = LEAD, human = null, env = ENV } = {}) => {
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
  return worker.fetch(req, { DB: sqliteDB(db), ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (db, opts = {}) => send(db, '/api/verdicts', 'POST', { body: base, ...opts });
const get = (db, q) => send(db, `/api/verdicts?${q}`, 'GET', { lead: null });
const putSetting = (db, key, value, opts = {}) => send(db, '/api/settings', 'PUT', { body: { key, value }, lead: null, ...opts });

test('W0 human_verdict_mode seeds shadow and the fresh verdicts table has an auth column', () => {
  const db = openDb();
  assert.equal(mode(db), 'shadow');
  const cols = db.prepare('PRAGMA table_info(verdicts)').all().map((r) => r.name);
  assert.ok(cols.includes('auth'), `verdicts columns: ${cols.join(',')}`);
});

test('W1 shadow: a human post with only the lead token is recorded, marked lead-token, and still stands', async () => {
  const db = openDb();
  const res = await post(db);
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.human_verified, false);
  assert.equal(res.body.human_verdict_mode, 'shadow');
  const row = rowOf(db, res.body.verdict.id);
  assert.equal(row.source, 'human');
  assert.equal(row.auth, 'lead-token');
  assert.equal(res.body.verdict.auth, 'lead-token');
  const g = await get(db, `repo=${base.repo}&pr=${base.pr}&head=${H1}&standing_only=1`);
  assert.equal(g.status, 200);
  assert.equal(g.body.standing.id, res.body.verdict.id);
});

test('W2 shadow and enforce: a human post with the human token is recorded as human-token', async () => {
  for (const m of ['shadow', 'enforce']) {
    const db = openDb();
    setMode(db, m);
    const res = await post(db, { human: HUMAN });
    assert.equal(res.status, 201, `${m}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.human_verified, true, m);
    assert.equal(res.body.human_verdict_mode, m);
    assert.equal(rowOf(db, res.body.verdict.id).auth, 'human-token', m);
  }
});

test('W3 enforce: a human post with only the lead token is 403 and writes nothing', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const res = await post(db);
  assert.equal(res.status, 403);
  assert.match(res.body.error, /x-human-verdict-token/);
  assert.equal(res.body.human_verdict_mode, 'enforce');
  assert.equal(count(db), 0);
});

test('W4 enforce: a WRONG human token is 403 and writes nothing', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const res = await post(db, { human: 'not-the-token' });
  assert.equal(res.status, 403);
  assert.match(res.body.error, /x-human-verdict-token/);
  assert.equal(count(db), 0);
});

test('W5 enforce with HUMAN_VERDICT_TOKEN unset on the worker: every human post is 403', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const env = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD };
  for (const human of [null, '', HUMAN, 'undefined']) {
    const res = await post(db, { human, env });
    assert.equal(res.status, 403, `human header ${human}`);
  }
  assert.equal(count(db), 0);
});

test('W6 enforce: lead and box rows are unaffected, and a human token never upgrades them', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const lead = await post(db, { body: { ...base, source: 'lead' } });
  assert.equal(lead.status, 201, JSON.stringify(lead.body));
  assert.equal(rowOf(db, lead.body.verdict.id).auth, 'lead-token');
  assert.equal(lead.body.human_verified, false);
  const box = await post(db, { body: { ...base, source: 'box' }, lead: null });
  assert.equal(box.status, 201, JSON.stringify(box.body));
  assert.equal(rowOf(db, box.body.verdict.id).auth, 'secret');
  const leadH = await post(db, { body: { ...base, source: 'lead' }, human: HUMAN });
  assert.equal(leadH.status, 201);
  assert.equal(rowOf(db, leadH.body.verdict.id).auth, 'lead-token');
  assert.equal(leadH.body.human_verified, false);
  const boxH = await post(db, { body: { ...base, source: 'box' }, lead: null, human: HUMAN });
  assert.equal(boxH.status, 201);
  assert.equal(rowOf(db, boxH.body.verdict.id).auth, 'secret');
});

test('W7 enforce: a human post with no lead token is still the lead-token 403 (order unchanged)', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const res = await post(db, { lead: null, human: HUMAN });
  assert.equal(res.status, 403);
  assert.match(res.body.error, /x-lead-verdict-token/);
  assert.equal(count(db), 0);
});

test('W8 a junk or missing human_verdict_mode reads as shadow', async () => {
  for (const v of ['ENFORCE', 'on', ' enforce', null]) {
    const db = openDb();
    if (v === null) db.prepare("DELETE FROM settings WHERE key='human_verdict_mode'").run();
    else setMode(db, v);
    const res = await post(db);
    assert.equal(res.status, 201, `mode ${JSON.stringify(v)}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.human_verdict_mode, 'shadow');
    assert.equal(rowOf(db, res.body.verdict.id).auth, 'lead-token');
  }
});

test('W9 PUT human_verdict_mode needs the human token; other keys do not', async () => {
  const db = openDb();
  setMode(db, 'enforce');
  const bare = await putSetting(db, 'human_verdict_mode', 'shadow');
  assert.equal(bare.status, 403);
  assert.match(bare.body.error, /x-human-verdict-token/);
  assert.equal(mode(db), 'enforce');
  const lead = await putSetting(db, 'human_verdict_mode', 'shadow', { lead: LEAD });
  assert.equal(lead.status, 403);
  assert.equal(mode(db), 'enforce');
  const wrong = await putSetting(db, 'human_verdict_mode', 'shadow', { human: 'not-the-token' });
  assert.equal(wrong.status, 403);
  assert.equal(mode(db), 'enforce');
  const ok = await putSetting(db, 'human_verdict_mode', 'shadow', { human: HUMAN });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(mode(db), 'shadow');
  const other = await putSetting(db, 'lead_verdict_min_client', '2');
  assert.equal(other.status, 200, JSON.stringify(other.body));
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='lead_verdict_min_client'").get().value, '2');
});

test('W10 a pre-BH-3831 verdicts table (no auth) is widened on the first post', async () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec('DROP TABLE verdicts');
  db.exec(`CREATE TABLE verdicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, pr INTEGER NOT NULL,
    head_sha TEXT NOT NULL, verdict TEXT NOT NULL, source TEXT NOT NULL,
    reviewer_model TEXT, reviewer TEXT, report_url TEXT, note TEXT, created_at TEXT NOT NULL)`);
  db.exec(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at)
           VALUES ('example-org/cromford', 3831, '${H1}', 'BLOCK', 'human', '2026-09-30T00:00:00Z')`);
  const res = await post(db, { human: HUMAN });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  const cols = db.prepare('PRAGMA table_info(verdicts)').all().map((r) => r.name);
  assert.ok(cols.includes('auth'));
  assert.equal(rowOf(db, res.body.verdict.id).auth, 'human-token');
  // The old row is untouched: auth NULL, and it was simply out-ranked by the newer row.
  assert.equal(rowOf(db, 1).auth, null);
});
