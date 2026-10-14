import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1525 — lead verdicts become rows. Driven against THE SQL THAT SHIPS
// (worker/jobs/schema.sql), the model-routes idiom: append-only is a property
// of the table (triggers), not of the routes happening to lack an UPDATE, so a
// stub that answered `changes:1` could not prove it.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
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

const openDb = (schema = SCHEMA) => { const db = new DatabaseSync(':memory:'); db.exec(schema); return db; };

// The lead credential (BH-1525 r2): a lead/human row needs LEAD_VERDICT_TOKEN
// on top of the bearer. The helper attaches it for those sources by default so
// every behavioural test below reads as before; the credential tests pass
// `lead` explicitly (null = omitted) and `leadEnv` for the worker's own secret.
const LEAD = 'lead-test-token';
const call = (DB, path, { method = 'GET', body, secret = SECRET, lead, leadEnv = LEAD } = {}) => {
  const tok = lead !== undefined ? lead
    : (body && ['lead', 'human'].includes(body.source) ? LEAD : null);
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      ...(secret ? { authorization: `Bearer ${secret}` } : {}),
      ...(tok ? { 'x-lead-verdict-token': tok } : {}),
      'content-type': 'application/json',
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, ...(leadEnv ? { LEAD_VERDICT_TOKEN: leadEnv } : {}) })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 1400, head_sha: H1, verdict: 'BLOCK', source: 'lead' };

test('an unknown path answers the worker\'s own 404: unknown endpoint AND worker=harness-jobs', async () => {
  // bin/lib/verdicts.sh reads this exact body as "this worker has no
  // /api/verdicts yet"; a foreign 404 (Cloudflare 1042, a proxy, HTML) carries
  // neither field and is read as unverifiable, never as "no verdict".
  const DB = sqliteDB(openDb());
  const res = await call(DB, '/api/no-such-route');
  assert.equal(res.status, 404);
  assert.deepEqual(res.body, { error: 'unknown endpoint', worker: 'harness-jobs' });
});

test('a verdict write needs the bearer every other operator write needs', async () => {
  const DB = sqliteDB(openDb());
  assert.equal((await call(DB, '/api/verdicts', { method: 'POST', body: base, secret: null })).status, 401);
  assert.equal((await call(DB, '/api/verdicts?repo=o/r&pr=1', { secret: 'wrong' })).status, 401);
});

test('HARNESS_SECRET alone may write only source=box: a lead or human row needs the lead token (403)', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const post = (over, opts) => call(DB, '/api/verdicts', { method: 'POST', body: { ...base, ...over }, ...opts });
  for (const source of ['lead', 'human']) {
    const res = await post({ source }, { lead: null });
    assert.equal(res.status, 403, `bearer-only ${source} must be refused`);
    assert.match(res.body.error, /lead verdict token/);
    assert.equal((await post({ source }, { lead: 'wrong-token' })).status, 403, `a wrong token must be refused (${source})`);
  }
  // A worker with no LEAD_VERDICT_TOKEN configured refuses every lead/human
  // write — unset is denied, never allowed (the bearerOk rule).
  assert.equal((await post({ source: 'lead' }, { lead: '', leadEnv: null })).status, 403);
  assert.equal((await post({ source: 'lead' }, { lead: LEAD, leadEnv: null })).status, 403);
  assert.equal(db.prepare('SELECT count(*) AS n FROM verdicts').get().n, 0, 'a refused write lands nothing');
  // The two that ARE allowed.
  assert.equal((await post({ source: 'box', verdict: 'MERGE' }, { lead: null })).status, 201, 'bearer alone writes a box row');
  assert.equal((await post({ source: 'lead' }, { lead: LEAD })).status, 201, 'the lead token writes a lead row');
  // The token is never echoed back.
  const got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400`);
  assert.ok(!JSON.stringify(got.body).includes(LEAD), 'no answer may carry the token');
});

test('a well-formed verdict lands as one row bound to its head', async () => {
  const DB = sqliteDB(openDb());
  const res = await call(DB, '/api/verdicts', {
    method: 'POST',
    body: { ...base, reviewer_model: 'claude-opus-5-5', reviewer: 'mac-lead', report_url: 'https://example.test/r.md', note: 'two blockers' },
  });
  assert.equal(res.status, 201);
  assert.equal(res.body.verdict.head_sha, H1);
  assert.equal(res.body.verdict.verdict, 'BLOCK');
  assert.equal(res.body.verdict.source, 'lead');
  assert.equal(res.body.verdict.reviewer_model, 'claude-opus-5-5');
  assert.ok(res.body.verdict.id > 0);
  assert.match(res.body.verdict.created_at, /^\d{4}-\d\d-\d\dT/);
});

test('route validation refuses every malformed field, naming it', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const bad = async (over, re) => {
    const res = await call(DB, '/api/verdicts', { method: 'POST', body: { ...base, ...over } });
    assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(over)}`);
    assert.match(res.body.error, re);
  };
  await bad({ repo: 'no-slash' }, /repo/);
  await bad({ repo: 'o/r; drop' }, /repo/);
  await bad({ pr: 0 }, /pr/);
  await bad({ pr: 'abc' }, /pr/);
  await bad({ pr: 1.5 }, /pr/);
  await bad({ head_sha: 'abc123' }, /head_sha/);          // a short sha binds to nothing
  await bad({ head_sha: 'z'.repeat(40) }, /head_sha/);
  // The vocabulary drift the ticket names (APPROVE vs MERGE) is refused, not mapped.
  await bad({ verdict: 'APPROVE' }, /verdict/);
  await bad({ verdict: 'merge' }, /verdict/);
  await bad({ source: 'mac' }, /source/);
  await bad({ source: undefined }, /source/);
  await bad({ report_url: 'javascript:alert(1)' }, /report_url/);
  await bad({ reviewer_model: 'x'.repeat(200) }, /reviewer_model/);
  await bad({ note: 'x'.repeat(5000) }, /note/);
  assert.equal(db.prepare('SELECT count(*) AS n FROM verdicts').get().n, 0, 'a refused write lands nothing');
});

test('an upper-case head sha is stored lower-case, so a lookup by the live head finds it', async () => {
  const DB = sqliteDB(openDb());
  const res = await call(DB, '/api/verdicts', { method: 'POST', body: { ...base, head_sha: 'A'.repeat(40) } });
  assert.equal(res.status, 201);
  const got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400&head=${H1}`);
  assert.equal(got.body.standing.verdict, 'BLOCK');
});

test('the table is APPEND-ONLY: UPDATE and DELETE abort in SQL, and no route edits a row', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  await call(DB, '/api/verdicts', { method: 'POST', body: base });
  assert.throws(() => db.prepare("UPDATE verdicts SET verdict='MERGE'").run(), /append-only/);
  assert.throws(() => db.prepare('DELETE FROM verdicts').run(), /append-only/);
  for (const method of ['PUT', 'PATCH', 'DELETE']) {
    const res = await call(DB, '/api/verdicts', { method, body: { ...base, verdict: 'MERGE' } });
    assert.equal(res.status, 404, `${method} must not reach a handler`);
  }
  assert.equal(db.prepare('SELECT verdict FROM verdicts').get().verdict, 'BLOCK');
});

test('standing = the NEWEST lead/human row on THIS head; a box row never stands, another head never counts', async () => {
  const DB = sqliteDB(openDb());
  const post = (over) => call(DB, '/api/verdicts', { method: 'POST', body: { ...base, ...over } });
  await post({ verdict: 'BLOCK', source: 'lead' });
  await post({ verdict: 'MERGE', source: 'box' });           // a box APPROVE does not lift a lead BLOCK
  let got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400&head=${H1}`);
  assert.equal(got.status, 200);
  assert.equal(got.body.standing.verdict, 'BLOCK');
  assert.equal(got.body.standing.source, 'lead');
  assert.equal(got.body.rows.length, 2);

  // A new push invalidates: the next head has nothing standing.
  got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400&head=${H2}`);
  assert.equal(got.body.standing, null);

  // A later human MERGE on the same head supersedes the lead BLOCK.
  await post({ verdict: 'MERGE', source: 'human' });
  got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400&head=${H1}`);
  assert.equal(got.body.standing.verdict, 'MERGE');
  assert.equal(got.body.standing.source, 'human');

  // Another PR in the same repo is a different key.
  got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1401&head=${H1}`);
  assert.equal(got.body.standing, null);
  assert.equal(got.body.rows.length, 0);
});

test('standing_only=1 answers the standing verdict without reading the history (the merge-lane read)', async () => {
  const DB = sqliteDB(openDb());
  for (let i = 0; i < 3; i++) await call(DB, '/api/verdicts', { method: 'POST', body: { ...base, verdict: i === 2 ? 'MERGE' : 'BLOCK' } });
  const got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400&head=${H1}&standing_only=1`);
  assert.equal(got.status, 200);
  assert.equal(got.body.standing.verdict, 'MERGE');
  assert.deepEqual(got.body.rows, [], 'no history rows on the merge-lane read');
  assert.equal((await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400&standing_only=1`)).status, 400, 'standing_only needs a head');
});

test('the read validates its key and answers the history without a head', async () => {
  const DB = sqliteDB(openDb());
  assert.equal((await call(DB, '/api/verdicts?pr=1')).status, 400);
  assert.equal((await call(DB, '/api/verdicts?repo=o/r')).status, 400);
  assert.equal((await call(DB, '/api/verdicts?repo=o/r&pr=1&head=nope')).status, 400);
  await call(DB, '/api/verdicts', { method: 'POST', body: base });
  await call(DB, '/api/verdicts', { method: 'POST', body: { ...base, head_sha: H2, verdict: 'MERGE-WITH-NOTES' } });
  const got = await call(DB, `/api/verdicts?repo=${base.repo}&pr=1400`);
  assert.equal(got.status, 200);
  assert.equal(got.body.standing, null, 'no head asked = no standing claimed');
  assert.deepEqual(got.body.rows.map((r) => r.verdict), ['MERGE-WITH-NOTES', 'BLOCK'], 'newest first');
});

test('a route reached before the schema apply creates its own table (CREATED_TABLES mirrors schema.sql)', async () => {
  const db = new DatabaseSync(':memory:');
  const DB = sqliteDB(db);
  const res = await call(DB, '/api/verdicts', { method: 'POST', body: base });
  assert.equal(res.status, 201);
  assert.throws(() => db.prepare('DELETE FROM verdicts').run(), /append-only/);
  assert.ok(Array.isArray(CREATED_TABLES.verdicts));
  const cols = (d) => d.prepare('PRAGMA table_info(verdicts)').all().map((c) => `${c.name}:${c.type}:${c.notnull}`);
  assert.deepEqual(cols(db), cols(openDb()));
  // Re-running the shipped schema over it is a no-op.
  db.exec(SCHEMA);
});
