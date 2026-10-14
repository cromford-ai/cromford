import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5024 (BH-4973.3) — the spend ledger in front of every Jev (TypeSafe
// jev-latest) call: POST /api/jev-risk/claim, POST /api/jev-risk/settle,
// GET /api/jev-risk, over the jev_risk_calls table. bin/jev-risk.sh claims a
// (repo, pr, head_sha, question_version) BEFORE it calls the vendor and settles
// it after: ok, empty or failed. ok and empty are terminal, so a head already
// answered is never bought again. Driven through worker.fetch against THE SQL
// THAT SHIPS (worker/jobs/schema.sql), the risk-tiers.bh-5022 idiom.
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

const fresh = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db) }; };
const bare = () => { const db = new DatabaseSync(':memory:'); return { db, DB: sqliteDB(db) }; };

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const REPO = 'example-org/cromford';
const H1 = 'a'.repeat(40);
const KEY = { repo: REPO, pr: 5024, head_sha: H1, question_version: 'v1' };
const CLAIM = { ...KEY, rule_tier: 'medium', model: 'jev-latest', caller: 'shadow:hub' };
const claim = (DB, extra = {}) => call(DB, '/api/jev-risk/claim', { method: 'POST', body: { ...CLAIM, ...extra } });
// A settle names the claim it settles: by default the row's current attempt.
const attemptsOf = async (DB, k = KEY) =>
  (await DB.prepare('SELECT attempts FROM jev_risk_calls WHERE repo=?1 AND pr=?2 AND head_sha=?3 AND question_version=?4')
    .bind(k.repo, k.pr, k.head_sha, k.question_version).first())?.attempts ?? 1;
const settle = async (DB, extra) =>
  call(DB, '/api/jev-risk/settle', { method: 'POST', body: { ...KEY, attempts: await attemptsOf(DB), ...extra } });
const rowOf = (db) => db.prepare('SELECT * FROM jev_risk_calls').all();

test('W1. an absent key claims 201 attempts 1; the same key while freshly claimed is 409 in_flight; an upper-case sha is the same row', async () => {
  const { db, DB } = fresh();
  const a = await claim(DB);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.row.status, 'claimed');
  assert.equal(a.body.row.attempts, 1);
  assert.equal(a.body.row.rule_tier, 'medium');
  assert.equal(a.body.row.caller, 'shadow:hub');
  const b = await claim(DB, { head_sha: H1.toUpperCase() });
  assert.equal(b.status, 409, JSON.stringify(b.body));
  assert.equal(b.body.error, 'in_flight');
  assert.equal(rowOf(db).length, 1, 'the upper-case sha made a second row');
  assert.equal(rowOf(db)[0].head_sha, H1);
  assert.equal(rowOf(db)[0].attempts, 1, 'a refused claim wrote the attempts');
});

test('W1b. junk keys are 400 naming the field, and write nothing', async () => {
  const { db, DB } = fresh();
  for (const [extra, field] of [
    [{ repo: 'nope' }, /repo/], [{ pr: 0 }, /pr/], [{ head_sha: 'abc' }, /head_sha/],
    [{ question_version: '1' }, /question_version/], [{ rule_tier: 'LOW' }, /rule_tier/],
    [{ caller: 'x y' }, /caller/],
  ]) {
    const r = await claim(DB, extra);
    assert.equal(r.status, 400, `${JSON.stringify(extra)}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, field);
  }
  assert.equal(rowOf(db).length, 0);
});

test('W1c. a claimed row older than 2 x jev_risk.timeout_s (a crashed caller) is reclaimed, attempts 2', async () => {
  const { db, DB } = fresh();
  await claim(DB);
  db.prepare("UPDATE jev_risk_calls SET claimed_at = '2026-01-01T00:00:00.000Z'").run();
  const r = await claim(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.row.attempts, 2);
  assert.equal(r.body.row.status, 'claimed');
});

test('W2. empty and ok are terminal: a claim after either is 409 terminal; a settle replay is 200 and writes nothing; another terminal is 409', async () => {
  const { db, DB } = fresh();
  await claim(DB);
  const e = await settle(DB, { status: 'empty', raw: '{}' });
  assert.equal(e.status, 200, JSON.stringify(e.body));
  assert.equal(e.body.row.status, 'empty');
  const c = await claim(DB);
  assert.equal(c.status, 409, JSON.stringify(c.body));
  assert.equal(c.body.error, 'terminal');
  assert.equal(c.body.status, 'empty');
  assert.equal(rowOf(db)[0].attempts, 1, 'a terminal claim bumped attempts');

  const { db: db2, DB: DB2 } = fresh();
  await claim(DB2);
  const o = await settle(DB2, { status: 'ok', jev_tier: 'low', jev_prob: 0.9, raw: '{"choice":"low"}' });
  assert.equal(o.status, 200, JSON.stringify(o.body));
  assert.equal(o.body.row.jev_tier, 'low');
  assert.equal(o.body.row.jev_prob, 0.9);
  const c2 = await claim(DB2);
  assert.equal(c2.status, 409);
  assert.equal(c2.body.error, 'terminal');
  const before = JSON.stringify(rowOf(db2));
  const replay = await settle(DB2, { status: 'ok', jev_tier: 'high', jev_prob: 0.1 });
  assert.equal(replay.status, 200, JSON.stringify(replay.body));
  assert.equal(replay.body.replay, true);
  assert.equal(JSON.stringify(rowOf(db2)), before, 'a settle replay changed the row');
  const other = await settle(DB2, { status: 'empty' });
  assert.equal(other.status, 409, JSON.stringify(other.body));
  assert.equal(rowOf(db2)[0].status, 'ok');
});

test('W3. ok needs a tier and a probability in [0,1]; failed is retried to max_attempts, then attempt_cap', async () => {
  const { db, DB } = fresh();
  await claim(DB);
  for (const bad of [{ status: 'ok', jev_prob: 0.5 }, { status: 'ok', jev_tier: 'low', jev_prob: 1.5 },
    { status: 'ok', jev_tier: 'LOW', jev_prob: 0.5 }, { status: 'ok', jev_tier: 'low' },
    { status: 'empty', jev_tier: 'low' }, { status: 'failed', jev_prob: 0.2 }, { status: 'claimed' }]) {
    const r = await settle(DB, bad);
    assert.equal(r.status, 400, `${JSON.stringify(bad)}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(rowOf(db)[0].status, 'claimed', 'a refused settle moved the row');
  const f = await settle(DB, { status: 'failed', error: 'http 500' });
  assert.equal(f.status, 200, JSON.stringify(f.body));
  const again = await claim(DB);
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.row.attempts, 2);
  await settle(DB, { status: 'failed', error: 'http 500' });
  const cap = await claim(DB);
  assert.equal(cap.status, 409, JSON.stringify(cap.body));
  assert.equal(cap.body.error, 'attempt_cap');
  assert.equal(rowOf(db)[0].attempts, 2);
  // the cap is the jev_risk.max_attempts row
  db.prepare("INSERT OR REPLACE INTO settings (key,value,actor,updated_at) VALUES ('jev_risk.max_attempts','3','t','t')").run();
  const third = await claim(DB);
  assert.equal(third.status, 200, JSON.stringify(third.body));
  assert.equal(third.body.row.attempts, 3);
});

test('W3b. settle on an unknown key is 404; raw is cut at 8000 chars', async () => {
  const { db, DB } = fresh();
  const none = await settle(DB, { status: 'failed' });
  assert.equal(none.status, 404, JSON.stringify(none.body));
  await claim(DB);
  const r = await settle(DB, { status: 'empty', raw: 'x'.repeat(9000) });
  assert.equal(r.status, 200);
  assert.equal(rowOf(db)[0].raw.length, 8000);
});

test('W4. the schema seeds jev_risk.mode = off and no jev_risk.api_url; self-create answers a claim on a bare DB', async () => {
  const { db } = fresh();
  const mode = db.prepare("SELECT value FROM settings WHERE key = 'jev_risk.mode'").get();
  assert.equal(mode && mode.value, 'off');
  assert.equal(db.prepare("SELECT count(*) AS n FROM settings WHERE key = 'jev_risk.api_url'").get().n, 0,
    'an api_url was seeded (D26: never a fabricated vendor URL)');
  for (const [k, v] of [['jev_risk.model', 'jev-latest'], ['jev_risk.max_per_tick', '3'], ['jev_risk.timeout_s', '30'],
    ['jev_risk.max_attempts', '2'], ['jev_risk.max_diff_chars', '60000']]) {
    assert.equal(db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value, v, k);
  }
  const route = db.prepare("SELECT model FROM model_routes WHERE role = 'jev-pilot.baseline' AND project IS NULL").get();
  assert.ok(route && route.model, 'no jev-pilot.baseline model_routes seed');
  assert.ok(Array.isArray(CREATED_TABLES.jev_risk_calls), 'no CREATED_TABLES.jev_risk_calls copy');
  const { db: b, DB: bareDB } = bare();
  b.exec('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT, note TEXT, actor TEXT, updated_at TEXT)');
  const r = await claim(bareDB);
  assert.equal(r.status, 201, `self-create: ${JSON.stringify(r.body)}`);
});

test('W4b. self-create copy matches the schema column for column', () => {
  const { db } = fresh();
  const shipped = db.prepare('PRAGMA table_info(jev_risk_calls)').all().map((c) => `${c.name}:${c.type}:${c.notnull}`);
  const b = new DatabaseSync(':memory:');
  for (const sql of CREATED_TABLES.jev_risk_calls) b.exec(sql);
  const copy = b.prepare('PRAGMA table_info(jev_risk_calls)').all().map((c) => `${c.name}:${c.type}:${c.notnull}`);
  assert.deepEqual(copy, shipped);
});

test('W5. GET /api/jev-risk lists newest first, filtered by repo and pr; limit refused outside 1..200', async () => {
  const { DB } = fresh();
  await claim(DB);
  await claim(DB, { head_sha: 'b'.repeat(40) });
  await claim(DB, { pr: 7 });
  const r = await call(DB, `/api/jev-risk?repo=${REPO}&pr=5024`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.head_sha), ['b'.repeat(40), H1]);
  assert.equal(r.body.truncated, false);
  const one = await call(DB, `/api/jev-risk?repo=${REPO}&limit=1`);
  assert.equal(one.body.rows.length, 1);
  assert.equal(one.body.truncated, true);
  assert.equal((await call(DB, '/api/jev-risk?limit=0')).status, 400);
  assert.equal((await call(DB, '/api/jev-risk?limit=201')).status, 400);
});

test('W6. settle is fenced on the claim attempt: a stale caller cannot overwrite the claim that replaced it', async () => {
  const { db, DB } = fresh();
  const a = await claim(DB);
  assert.equal(a.body.row.attempts, 1);
  db.prepare("UPDATE jev_risk_calls SET claimed_at = '2026-01-01T00:00:00.000Z'").run();
  const b = await claim(DB, { caller: 'pilot' });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.row.attempts, 2);
  // A's late settle lands while B is still in flight: refused, and writes nothing.
  const late = await settle(DB, { attempts: 1, status: 'failed', error: 'curl rc 28' });
  assert.equal(late.status, 409, JSON.stringify(late.body));
  assert.equal(late.body.error, 'superseded');
  assert.equal(rowOf(db)[0].status, 'claimed', 'a superseded settle moved the row');
  // B's paid answer still settles.
  const ok = await settle(DB, { attempts: 2, status: 'ok', jev_tier: 'low', jev_prob: 0.8 });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(rowOf(db)[0].status, 'ok');
  assert.equal(rowOf(db)[0].jev_tier, 'low');
  for (const bad of [undefined, 0, '2', 1.5]) {
    const r = await settle(DB, { attempts: bad, status: 'ok', jev_tier: 'low', jev_prob: 0.8 });
    assert.equal(r.status, 400, `attempts ${JSON.stringify(bad)}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /attempts/);
  }
});
