import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { humanTokenOk } from '../src/routes/verdicts.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// Fixes ported from an outside audit (cromford-ai/cromford#5 and #6):
//   F09  PUT /api/settings refuses a service-managed key (hub_envelope_public_key).
//   6a   a bearer may not widen risk_tier.low_globs, nor make the first write.
//   6b   a human token that equals the fleet or lead token is no human token.
const SECRET = 'test-secret';
const HUMAN = 'human-test-token-fixture';
const SCHEMA = jobsSchemaSql();
const LOW = 'risk_tier.low_globs';

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

function put(db, key, value, { human = null, env = {} } = {}) {
  const req = new Request('https://jobs.test/api/settings', {
    method: 'PUT',
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(human ? { 'x-human-verdict-token': human } : {}),
    },
    body: JSON.stringify({ key, value }),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN, ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}

test('F09 PUT /api/settings refuses hub_envelope_public_key and writes nothing', async () => {
  const db = openDb();
  const before = setting(db, 'hub_envelope_public_key');
  const r = await put(db, 'hub_envelope_public_key', '-----BEGIN PUBLIC KEY-----x');
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.match(r.body.error, /service-managed/);
  assert.equal(setting(db, 'hub_envelope_public_key'), before);
});

test('F09 control: an ordinary key still writes', async () => {
  const db = openDb();
  assert.equal((await put(db, 'ui.some_knob', '5')).status, 200);
});

test('6a a bearer cannot make the first write of risk_tier.low_globs', async () => {
  const db = openDb();
  const r = await put(db, LOW, 'docs/**');
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.equal(setting(db, LOW), null);
  assert.equal((await put(db, LOW, 'docs/**', { human: HUMAN })).status, 200);
});

test('6a a bearer cannot add a glob to risk_tier.low_globs, and can remove one', async () => {
  const db = openDb();
  assert.equal((await put(db, LOW, 'docs/** a/**', { human: HUMAN })).status, 200);
  const add = await put(db, LOW, 'docs/** a/** evil/**');
  assert.equal(add.status, 403, JSON.stringify(add.body));
  assert.deepEqual(add.body.added, ['evil/**']);
  assert.equal(setting(db, LOW), 'docs/** a/**');
  assert.equal((await put(db, LOW, 'docs/**')).status, 200);
  assert.equal((await put(db, LOW, 'docs/** evil/**', { human: HUMAN })).status, 200);
});

test('6a high_globs and sensitive_globs: removal is loosening, addition is not', async () => {
  const db = openDb();
  for (const k of ['risk_tier.high_globs', 'risk_tier.sensitive_globs']) {
    assert.equal((await put(db, k, 'a/**', { human: HUMAN })).status, 200);
    assert.equal((await put(db, k, 'a/** b/**')).status, 200, `${k} tighten`);
    assert.equal((await put(db, k, 'a/**')).status, 403, `${k} loosen`);
  }
});

test('6b humanTokenOk refuses a human token equal to the fleet or lead token', () => {
  const req = (t) => new Request('https://x.test', { headers: { 'x-human-verdict-token': t } });
  assert.equal(humanTokenOk(req('same'), { HUMAN_VERDICT_TOKEN: 'same', HARNESS_SECRET: 'same' }), false);
  assert.equal(humanTokenOk(req('same'), { HUMAN_VERDICT_TOKEN: 'same', LEAD_VERDICT_TOKEN: 'same' }), false);
  assert.equal(humanTokenOk(req('h'), { HUMAN_VERDICT_TOKEN: 'h', HARNESS_SECRET: 's', LEAD_VERDICT_TOKEN: 'l' }), true);
  assert.equal(humanTokenOk(req('h'), { HARNESS_SECRET: 's' }), false);
});

test('6b through PUT: a shared human/fleet token no longer opens a protected switch', async () => {
  const db = openDb();
  const r = await put(db, 'human_verdict_mode', 'shadow', { human: SECRET, env: { HUMAN_VERDICT_TOKEN: SECRET } });
  assert.equal(r.status, 403, JSON.stringify(r.body));
});
