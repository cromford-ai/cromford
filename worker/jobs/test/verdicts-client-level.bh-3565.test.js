import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3565 — a lead/human verdict from a bin/lead-verdict.sh older than the
// lead_verdict_min_client settings row is refused 426 and nothing is written.
// An old checkout publishes no lead-verdict status, and a script that already
// shipped cannot be taught to refuse itself, so the worker is the only place
// that can. Driven against THE SQL THAT SHIPS (schema.sql), through worker.fetch.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
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
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const setMin = (db, v) => db.prepare("UPDATE settings SET value=? WHERE key='lead_verdict_min_client'").run(v);
const rows = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;

const H1 = 'a'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 3520, head_sha: H1, verdict: 'MERGE', source: 'lead' };

// client: undefined = header omitted. lead: the lead token (null = omitted).
const post = (db, { body = base, client, lead = LEAD } = {}) => {
  const req = new Request('https://jobs.test/api/verdicts', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(lead ? { 'x-lead-verdict-token': lead } : {}),
      ...(client !== undefined ? { 'x-lead-verdict-client': client } : {}),
    },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

test('W1 the knob is seeded 0 (off): a lead post with no client header is recorded', async () => {
  const db = openDb();
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='lead_verdict_min_client'").get().value, '0');
  const res = await post(db);
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(rows(db), 1);
});

test('W2 knob 2, no client header: 426 naming git pull and the level, nothing written', async () => {
  const db = openDb(); setMin(db, '2');
  for (const source of ['lead', 'human']) {
    const res = await post(db, { body: { ...base, source } });
    assert.equal(res.status, 426, `${source}: ${JSON.stringify(res.body)}`);
    assert.match(res.body.error, /git pull/);
    assert.equal(res.body.required, 2);
    assert.equal(res.body.client_level, 0);
  }
  assert.equal(rows(db), 0);
});

test('W3 knob 2: client 1 is refused, 2 and 3 are recorded', async () => {
  const db = openDb(); setMin(db, '2');
  const r1 = await post(db, { client: '1' });
  assert.equal(r1.status, 426);
  assert.equal(r1.body.client_level, 1);
  assert.equal(rows(db), 0);
  assert.equal((await post(db, { client: '2' })).status, 201);
  assert.equal((await post(db, { client: '3' })).status, 201);
  assert.equal(rows(db), 2);
});

test('W4 knob 2: a junk client header counts as level 0', async () => {
  const db = openDb(); setMin(db, '2');
  for (const client of ['abc', '-5', '2.5', '', ' ']) {
    assert.equal((await post(db, { client })).status, 426, `client '${client}'`);
  }
  assert.equal(rows(db), 0);
});

test('W5 box rows are never refused on the client level', async () => {
  const db = openDb(); setMin(db, '2');
  const res = await post(db, { body: { ...base, source: 'box' }, lead: null });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(rows(db), 1);
});

test('W6 the lead token is checked first: a bad token with no client header is 403, not 426', async () => {
  const db = openDb(); setMin(db, '2');
  assert.equal((await post(db, { lead: 'wrong' })).status, 403);
  assert.equal((await post(db, { lead: null })).status, 403);
});

test('W7 a junk or negative knob is off', async () => {
  for (const v of ['x', '-1', '', '1.5']) {
    const db = openDb(); setMin(db, v);
    assert.equal((await post(db)).status, 201, `knob '${v}'`);
  }
});

test('W8 no settings row, or no settings table, is off', async () => {
  const db = openDb();
  db.prepare("DELETE FROM settings WHERE key='lead_verdict_min_client'").run();
  assert.equal((await post(db)).status, 201);
  const db2 = openDb();
  db2.exec('DROP TABLE settings');
  assert.equal((await post(db2)).status, 201);
});
