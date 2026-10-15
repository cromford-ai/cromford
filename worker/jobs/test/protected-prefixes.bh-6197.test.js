import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { PROTECTED_PREFIXES, isProtectedSetting } from '../src/routes/verdicts.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-6197: lead_protected_paths_extra.* is an ordinary setting. BH-4148 moved
// the lead protected paths to their own table and nothing reads the extras row,
// so the worker no longer signs it, gates it, or judges it by its signature.
// lead_authority.* and risk_tier.* stay signed (E5). Driven through worker.fetch
// against schema.sql; the tamper in E3 is a raw D1 write on a row the PUT wrote.
const SECRET = 'test-secret';
const HUMAN = 'human-test-token';
const SCHEMA = jobsSchemaSql();
const X = 'lead_protected_paths_extra.example-org.cromford';

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
const setRaw = (db, k, v) => db.prepare('UPDATE settings SET value=? WHERE key=?').run(v, k);
const sigs = (db, k) => db.prepare('SELECT * FROM setting_sigs WHERE key=?').all(k).length;
const ENV = { HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: 'sig-test-key' };

const send = (db, path, method, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: sqliteDB(db), ...ENV })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const put = (db, key, value) => send(db, '/api/settings', 'PUT', { key, value });

test('E1 a bearer PUT of an extras key is not signed', async () => {
  const db = openDb();
  const r = await put(db, X, 'a b');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, undefined);
  assert.equal(sigs(db, X), 0);
  assert.equal(setting(db, X), 'a b');
});

test('E2 a bearer PUT that removes a glob from an extras key is accepted', async () => {
  const db = openDb();
  assert.equal((await put(db, X, 'a b')).status, 200);
  const r = await put(db, X, 'a');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(setting(db, X), 'a');
});

test('E3 a raw-written extras row reads as stored under sig enforce', async () => {
  const db = openDb();
  setRaw(db, 'human_verdict_sig_mode', 'enforce');
  assert.equal((await put(db, X, 'a b')).status, 200);
  setRaw(db, X, 'a');
  const g = await send(db, `/api/settings/${X}`, 'GET');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.setting.value, 'a');
  assert.equal(g.body.setting.unproven, undefined);
  const list = await send(db, '/api/settings', 'GET');
  assert.equal(list.status, 200);
  const row = list.body.settings.find((s) => s.key === X);
  assert.ok(row, 'the extras row is in the list');
  assert.equal(row.value, 'a');
  assert.equal('proven' in row, false);
});

test('E4 the prefix is not protected', () => {
  assert.equal(PROTECTED_PREFIXES.includes('lead_protected_paths_extra.'), false);
  assert.equal(isProtectedSetting('lead_protected_paths_extra.x'), false);
  assert.equal(isProtectedSetting('lead_protected_paths_extra'), false);
});

test('E5 control: lead_authority.* and risk_tier.* PUTs are still signed', async () => {
  const db = openDb();
  for (const [k, v] of [['lead_authority.example-org.cromford', 'human'], ['risk_tier.low_globs', 'docs/**']]) {
    const r = await put(db, k, v);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.signed, true, k);
    assert.equal(sigs(db, k), 1, k);
    assert.equal(isProtectedSetting(k), true, k);
  }
});
