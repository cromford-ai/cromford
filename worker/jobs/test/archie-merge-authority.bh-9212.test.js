import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { PROTECTED_PREFIXES, isProtectedSetting } from '../src/routes/verdicts.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-9212: archie.merge.authority decides if Archie may merge through
// bin/archie-merge.sh. A bearer (any box, Archie's own shell included) may only
// TIGHTEN it to ask_first; any other value needs the human verdict token
// (bin/protected-setting.sh on the operator's Mac). The key is under PROTECTED_PREFIXES,
// so every PUT is signed and an unproven row is a 409 under sig enforce.
// Driven against schema.sql through worker.fetch; a tamper is a raw D1 write.
const SECRET = 'test-secret';
const HUMAN = 'human-test-token-fixture';
const SIGKEY = 'sig-test-key-fixture';
const SCHEMA = jobsSchemaSql();
const A = 'archie.merge.authority';

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
const delRow = (db, k) => db.prepare('DELETE FROM settings WHERE key=?').run(k);
const rawSet = (db, k, v) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?1,?2,'raw','raw','2026-11-08T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=?2",
).run(k, v);
const enforce = (db) => db.prepare("UPDATE settings SET value='enforce' WHERE key='human_verdict_sig_mode'").run();
const ENV = { HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: SIGKEY };

const send = (db, path, method, { body, human = null } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(human ? { 'x-human-verdict-token': human } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: sqliteDB(db), ...ENV })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const put = (db, key, value, opts = {}) =>
  send(db, '/api/settings', 'PUT', { body: { key, value, actor: opts.actor || 'fixture-box' }, human: opts.human || null });
const get = (db, key) => send(db, `/api/settings/${key}`, 'GET');

test('P1 archie.merge. is a protected prefix (BH-9212)', () => {
  assert.ok(PROTECTED_PREFIXES.includes('archie.merge.'));
  assert.equal(isProtectedSetting(A), true);
  assert.equal(isProtectedSetting('archie.merge.other'), true);
  assert.equal(isProtectedSetting('archie.mergeauthority'), false);
  assert.equal(isProtectedSetting('archie.cap.queue-enqueue'), false);
});

test('W-(a)-(c) a bearer may tighten to ask_first: from merge, from no row, from an unproven row', async () => {
  const db = openDb();
  // (a) from merge (written with the human token first)
  let r = await put(db, A, 'merge', { human: HUMAN });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  r = await put(db, A, 'ask_first');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, true);
  assert.equal(setting(db, A), 'ask_first');
  // (b) from no row
  delRow(db, A);
  assert.equal(setting(db, A), null);
  r = await put(db, A, 'ask_first');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(setting(db, A), 'ask_first');
  // (c) from an unproven raw row, under enforce
  enforce(db);
  rawSet(db, A, 'merge');
  assert.equal((await get(db, A)).status, 409);
  r = await put(db, A, 'ask_first', { actor: 'archie' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(setting(db, A), 'ask_first');
  assert.equal((await get(db, A)).body.setting.value, 'ask_first');
});

test('W-(d)-(g) a bearer may not loosen: merge, MERGE, lane, 1, "merge " and the whole prefix are 403', async () => {
  const db = openDb();
  // (e) no row
  delRow(db, A);
  let r = await put(db, A, 'merge');
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.match(r.body.error, /human verdict token/);
  assert.equal(setting(db, A), null);
  // (d) from ask_first
  assert.equal((await put(db, A, 'ask_first')).status, 200);
  for (const v of ['merge', 'MERGE', 'merge ', 'lane', '1', 'merged']) {
    r = await put(db, A, v);
    assert.equal(r.status, 403, `${JSON.stringify(v)}: ${JSON.stringify(r.body)}`);
    assert.equal(setting(db, A), 'ask_first', JSON.stringify(v));
  }
  // actor archie, the same
  r = await put(db, A, 'merge', { actor: 'archie' });
  assert.equal(r.status, 403);
  assert.equal(setting(db, A), 'ask_first');
  // (g) the whole prefix
  r = await put(db, 'archie.merge.other', 'merge');
  assert.equal(r.status, 403);
  assert.equal(setting(db, 'archie.merge.other'), null);
  assert.equal((await put(db, 'archie.merge.other', 'ask_first')).status, 200);
});

test('W-(h) the human token sets merge, signed, and the single-key GET reads merge; a bearer ask_first then wins', async () => {
  const db = openDb();
  enforce(db);
  let r = await put(db, A, 'merge', { human: HUMAN });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, true);
  r = await get(db, A);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.setting.value, 'merge');
  assert.equal((await put(db, A, 'ask_first')).status, 200);
  r = await get(db, A);
  assert.equal(r.status, 200);
  assert.equal(r.body.setting.value, 'ask_first');
});

test('W-(i) near miss: archie.mergeauthority (no dot) is not protected and keeps the plain PUT', async () => {
  const db = openDb();
  const r = await put(db, 'archie.mergeauthority', 'merge');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.notEqual(r.body.signed, true);
  assert.equal(setting(db, 'archie.mergeauthority'), 'merge');
});

test('W-enforce: a raw D1 write of merge over a signed ask_first reads 409 on the single-key GET', async () => {
  const db = openDb();
  enforce(db);
  assert.equal((await put(db, A, 'ask_first')).status, 200);
  assert.equal((await get(db, A)).body.setting.value, 'ask_first');
  rawSet(db, A, 'merge');
  const r = await get(db, A);
  assert.equal(r.status, 409, JSON.stringify(r.body));
});

test('W-(j) control: lead_authority.* and risk_tier.* bearer rules are unchanged', async () => {
  const db = openDb();
  assert.equal((await put(db, 'lead_authority.example-org.cromford', 'human')).status, 200);
  assert.equal((await put(db, 'lead_authority.example-org.cromford', 'lane')).status, 403);
  // cromford#6: the first write and any widening of low_globs need the human token.
  assert.equal((await put(db, 'risk_tier.low_globs', 'docs/**')).status, 403);
  assert.equal((await put(db, 'risk_tier.low_globs', 'docs/** a/**', { human: HUMAN })).status, 200);
  assert.equal((await put(db, 'risk_tier.low_globs', 'docs/** a/** b/**')).status, 403);
  assert.equal((await put(db, 'risk_tier.low_globs', 'a/**')).status, 200);
});
