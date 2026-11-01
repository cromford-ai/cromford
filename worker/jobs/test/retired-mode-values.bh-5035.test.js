import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { RETIRED_MODE_KEYS, retiredModeRefusal } from '../src/lib/retired-mode-values.js';

// BH-5035: the `human` value of tier_gate_mode and lead_authority_mode is
// removed. PUT /api/settings refuses it, global or per project/repo, with a 400
// and a message that names BH-5035 and the value to use instead. The refusal
// comes before any DB read, so nothing is stored and nothing is signed. Every
// route case drives worker.fetch, the real route table, over schema.sql applied
// to an in-memory sqlite (the settings-theme.bh-4846 harness).

const SECRET = 'test-secret-fixture';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
const NO_DB = !DatabaseSync;

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function put(env, key, value) {
  const headers = { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json' };
  const res = await worker.fetch(new Request('https://jobs.test/api/settings', {
    method: 'PUT', headers, body: JSON.stringify({ key, value, actor: 'operator@example.com' }),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const row = (db, k) => { const r = db.prepare('SELECT * FROM settings WHERE key=?').get(k); return r ? { ...r } : null; };

const REFUSED = [
  ['tier_gate_mode', 'off'],
  ['tier_gate_mode.demo-os', 'off'],
  ['lead_authority_mode', 'lane'],
  ['lead_authority_mode.example-org.cromford', 'lane'],
];

for (const [i, [key, use]] of REFUSED.entries()) {
  test(`W${i + 1}: PUT ${key}=human is refused with 400 and stores nothing`, { skip: NO_DB }, async () => {
    const { db, env } = fresh();
    const r = await put(env, key, 'human');
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.match(r.body.error, /removed by BH-5035/);
    assert.ok(r.body.error.includes(`set ${key} to ${use}`), r.body.error);
    assert.equal(r.body.key, key);
    assert.equal(row(db, key), null, 'no row is written');
    const audit = db.prepare('SELECT COUNT(*) AS n FROM config_changes WHERE name=?').get(key);
    assert.equal(Number(audit.n), 0, 'no audit row for a refused write');
  });
}

test('W5: the value is trimmed and case-folded before the check', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  for (const v of ['  HUMAN ', 'Human']) {
    const r = await put(env, 'lead_authority_mode.example-org.cromford', v);
    assert.equal(r.status, 400, `${JSON.stringify(v)}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(row(db, 'lead_authority_mode.example-org.cromford'), null);
});

test('W6: the values that stay are accepted and stored', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  for (const [key, value] of [['tier_gate_mode', 'off'], ['lead_authority_mode', 'lane'], ['lead_authority_mode.example-org.cromford', 'lane']]) {
    const r = await put(env, key, value);
    assert.equal(r.status, 200, `${key}=${value}: ${JSON.stringify(r.body)}`);
    assert.equal(row(db, key).value, value);
  }
});

test('W7: near misses are not refused by this rule', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  // A prefix without the dot is another key.
  let r = await put(env, 'tier_gate_mode_x', 'human');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(row(db, 'tier_gate_mode_x').value, 'human');
  // The authority row keeps its own BH-4090 rules: setting it to human tightens it.
  r = await put(env, 'lead_authority.example-org.cromford', 'human');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  // human_verdict_mode is out of scope: still the 403 of BH-3831 without the token.
  r = await put(env, 'human_verdict_mode', 'human');
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.doesNotMatch(r.body.error, /BH-5035/);
  // Another value on a retired key is not this rule's business.
  r = await put(env, 'lead_authority_mode', 'humane');
  assert.equal(r.status, 200, JSON.stringify(r.body));
});

test('W8: retiredModeRefusal decision table', () => {
  assert.deepEqual(RETIRED_MODE_KEYS, ['tier_gate_mode', 'lead_authority_mode']);
  const refused = [
    ['tier_gate_mode', 'human'], ['tier_gate_mode.demo-os', ' Human '],
    ['lead_authority_mode', 'HUMAN'], ['lead_authority_mode.example-org.cromford', 'human'],
  ];
  for (const [k, v] of refused) {
    const msg = retiredModeRefusal(k, v);
    assert.ok(typeof msg === 'string' && msg.startsWith(`${k}=human was removed by BH-5035`), `${k}=${v}: ${msg}`);
  }
  assert.match(retiredModeRefusal('tier_gate_mode', 'human'), /set tier_gate_mode to off\.$/);
  assert.match(retiredModeRefusal('lead_authority_mode.a.b', 'human'), /set lead_authority_mode\.a\.b to lane\.$/);
  const allowed = [
    ['tier_gate_mode', 'off'], ['lead_authority_mode', 'lane'], ['tier_gate_mode_x', 'human'],
    ['lead_authority.example-org.cromford', 'human'], ['lead_authority_mode', 'human:precision'],
    ['human_verdict_mode', 'human'], ['lead_authority_mode', 'humane'], ['xtier_gate_mode', 'human'],
    ['lead_authority_mode', null], ['lead_authority_mode', 42], ['lead_authority_mode', undefined],
  ];
  for (const [k, v] of allowed) assert.equal(retiredModeRefusal(k, v), null, `${k}=${v}`);
});
