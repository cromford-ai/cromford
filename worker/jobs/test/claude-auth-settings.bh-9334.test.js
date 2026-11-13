import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { BILLING_PREFIXES, PROTECTED_PREFIXES, isProtectedSetting } from '../src/routes/verdicts.js';
import { redactTokens } from '../src/routes/staff-turns.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-9334 C0: claude_auth.<project> (oauth | api-key) and runner_lock.<project>
// (claude) change billing and which vendors see client code. The PUT refuses
// any other value (400, never echoing it), refuses a write without the human
// verdict token (403), and signs every accepted write into setting_sigs.
// Driven through worker.fetch against schema.sql; each case its own DB and project.
const SECRET = 'test-secret';
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
const setting = (db, k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value ?? null;
const count = (db, table, k) => db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE key=?`).get(k).n;
const auditRows = (db, k) => db.prepare('SELECT COUNT(*) AS n FROM config_changes WHERE name=?').get(k).n;
const ENV = { HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: 'sig-test-key' };

const send = (db, path, method, body, extra = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', ...extra },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: sqliteDB(db), ...ENV })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const putH = (db, key, value) => send(db, '/api/settings', 'PUT', { key, value }, { 'x-human-verdict-token': HUMAN });
const putB = (db, key, value) => send(db, '/api/settings', 'PUT', { key, value });

const nothingWritten = (db, key) => {
  assert.equal(setting(db, key), null, `settings row for ${key}`);
  assert.equal(count(db, 'setting_sigs', key), 0, `setting_sigs for ${key}`);
  assert.equal(auditRows(db, key), 0, `config_changes for ${key}`);
};

test('W1 claude_auth.<p>=api-key with the human token: stored, signed, proven in the list', async () => {
  const db = openDb();
  const r = await putH(db, 'claude_auth.p1', 'api-key');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, true);
  assert.equal(setting(db, 'claude_auth.p1'), 'api-key');
  assert.equal(count(db, 'setting_sigs', 'claude_auth.p1'), 1);
  const g = await send(db, '/api/settings', 'GET');
  const row = g.body.settings.find((s) => s.key === 'claude_auth.p1');
  assert.equal(row.proven, true);
});

test('W2 claude_auth.x=foo is 400 and writes nothing', async () => {
  const db = openDb();
  const r = await putH(db, 'claude_auth.x', 'foo');
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /must be oauth or api-key/);
  nothingWritten(db, 'claude_auth.x');
});

test('W3 a pasted key as the value is 400 and the error does not echo it', async () => {
  const db = openDb();
  const pasted = 'sk-' + 'ant-api03-FIXTURE' + 'Q'.repeat(40);
  const r = await putH(db, 'claude_auth.p3', pasted);
  assert.equal(r.status, 400);
  assert.ok(!JSON.stringify(r.body).includes(pasted), JSON.stringify(r.body));
  assert.ok(!JSON.stringify(r.body).includes('FIXTURE'), JSON.stringify(r.body));
  nothingWritten(db, 'claude_auth.p3');
});

test('W4 claude_auth.<p>=API-KEY (case) is 400', async () => {
  const db = openDb();
  assert.equal((await putH(db, 'claude_auth.p4', 'API-KEY')).status, 400);
  assert.equal((await putH(db, 'claude_auth.p4', 'api_key')).status, 400);
  nothingWritten(db, 'claude_auth.p4');
});

test('W5 claude_auth. with no project is 400', async () => {
  const db = openDb();
  const r = await putH(db, 'claude_auth.', 'oauth');
  assert.equal(r.status, 400, JSON.stringify(r.body));
  nothingWritten(db, 'claude_auth.');
});

test('W6 claude_auth.a.b (a dotted project) is 400', async () => {
  const db = openDb();
  const r = await putH(db, 'claude_auth.a.b', 'oauth');
  assert.equal(r.status, 400, JSON.stringify(r.body));
  nothingWritten(db, 'claude_auth.a.b');
  assert.equal((await putH(db, 'runner_lock.a.b', 'claude')).status, 400);
  nothingWritten(db, 'runner_lock.a.b');
});

test('W7 claude_auth.<p>=oauth with the token is 200 and signed', async () => {
  const db = openDb();
  const r = await putH(db, 'claude_auth.my-proj_1', 'oauth');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(setting(db, 'claude_auth.my-proj_1'), 'oauth');
  assert.equal(count(db, 'setting_sigs', 'claude_auth.my-proj_1'), 1);
});

test('W8 runner_lock.<p>=claude with the token is 200 and signed', async () => {
  const db = openDb();
  const r = await putH(db, 'runner_lock.p8', 'claude');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, true);
  assert.equal(setting(db, 'runner_lock.p8'), 'claude');
  assert.equal(count(db, 'setting_sigs', 'runner_lock.p8'), 1);
});

test('W9 runner_lock.<p>=codex or none is 400 and writes nothing', async () => {
  const db = openDb();
  for (const v of ['codex', 'none', 'Claude']) {
    const r = await putH(db, 'runner_lock.p9', v);
    assert.equal(r.status, 400, `${v}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /must be claude/);
  }
  nothingWritten(db, 'runner_lock.p9');
});

test('W10 claude_auth.<p> with the bearer only is 403 for either value, nothing written', async () => {
  const db = openDb();
  for (const v of ['api-key', 'oauth']) {
    const r = await putB(db, 'claude_auth.p10', v);
    assert.equal(r.status, 403, `${v}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /changes billing and vendor routing/);
    assert.match(r.body.error, /human verdict token/);
    assert.match(r.body.error, /bin\/protected-setting\.sh/);
  }
  nothingWritten(db, 'claude_auth.p10');
});

test('W10b a bearer re-write of a signed row is 403, even with the same value', async () => {
  const db = openDb();
  assert.equal((await putH(db, 'claude_auth.p10b', 'api-key')).status, 200);
  assert.equal((await putH(db, 'runner_lock.p10b', 'claude')).status, 200);
  for (const [k, v] of [['claude_auth.p10b', 'api-key'], ['claude_auth.p10b', 'oauth'], ['runner_lock.p10b', 'claude']]) {
    const r = await putB(db, k, v);
    assert.equal(r.status, 403, `${k}=${v}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(setting(db, 'claude_auth.p10b'), 'api-key');
  assert.equal(count(db, 'setting_sigs', 'claude_auth.p10b'), 1);
  assert.equal(count(db, 'setting_sigs', 'runner_lock.p10b'), 1);
});

test('W11 runner_lock.<p>=claude with the bearer only is 403', async () => {
  const db = openDb();
  const r = await putB(db, 'runner_lock.p11', 'claude');
  assert.equal(r.status, 403, JSON.stringify(r.body));
  nothingWritten(db, 'runner_lock.p11');
});

test('W12 a wrong human token is 403', async () => {
  const db = openDb();
  const r = await send(db, '/api/settings', 'PUT', { key: 'claude_auth.p12', value: 'api-key' },
    { 'x-human-verdict-token': 'not-the-token' });
  assert.equal(r.status, 403, JSON.stringify(r.body));
  nothingWritten(db, 'claude_auth.p12');
});

test('W13 near-miss keys are unaffected', async () => {
  const db = openDb();
  const r = await putB(db, 'claude_authx.y', 'z');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, undefined);
  assert.equal(count(db, 'setting_sigs', 'claude_authx.y'), 0);
  const a = await putB(db, 'account.p13', 'own:p13');
  assert.equal(a.status, 200, JSON.stringify(a.body));
});

test('W14 both prefixes are protected and exported', () => {
  assert.deepEqual(BILLING_PREFIXES, ['claude_auth.', 'runner_lock.']);
  for (const p of BILLING_PREFIXES) assert.ok(PROTECTED_PREFIXES.includes(p), p);
  assert.equal(isProtectedSetting('claude_auth.p'), true);
  assert.equal(isProtectedSetting('runner_lock.p'), true);
  assert.equal(isProtectedSetting('claude_authx.p'), false);
});

// ── S. the JS mirror of bin/lib/token-redact.sh ──
const SK = 'sk-' + 'ant-';
test('S1 redactTokens redacts an Anthropic API key', () => {
  const k = `${SK}api03-FIXTURE_${'Q'.repeat(30)}`;
  assert.equal(redactTokens(`key=${k} end`), 'key=<redacted:anthropic-key> end');
});
test('S2 redactTokens leaves an OAuth token unchanged', () => {
  const k = `${SK}oat01-FIXTURE${'Q'.repeat(40)}`;
  assert.equal(redactTokens(`oauth ${k}`), `oauth ${k}`);
});
test('S3 redactTokens still redacts a GitHub token', () => {
  const g = `ghs_FIXTURE${'Q'.repeat(29)}`;
  assert.equal(redactTokens(`gh ${g}`), 'gh <redacted:github-token>');
});
