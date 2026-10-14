import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4090 (BH-3905 child 4): the lead_authority.* and lead_protected_paths_extra.*
// rows behind the setting signature. A bearer PUT that LOOSENS one needs the
// human token; a single-key GET answers the effective value of an unproven row
// (human / 409 under sig enforce, as stored + a warn in shadow); the bulk list
// marks those rows `proven`. Driven against schema.sql through worker.fetch;
// every tamper is a raw D1 write on rows the real PUT wrote first.
const SECRET = 'test-secret';
const HUMAN = 'human-test-token';
const KEY = 'sig-test-key';
const SCHEMA = jobsSchemaSql();
const K = 'lead_authority.example-org.cromford';
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
const sigs = (db, k) => db.prepare('SELECT * FROM setting_sigs WHERE key=? ORDER BY seq').all(k);
const changes = (db) => db.prepare('SELECT COUNT(*) AS n FROM config_changes').get().n;
const hmac = (msg, key = KEY) => createHmac('sha256', key).update(msg).digest('hex');
const v2Msg = (k, v, seq) => `bh-setting-v2\n${k}\n${v}\n${seq}`;
const enforce = (db) => setRaw(db, 'human_verdict_sig_mode', 'enforce');

const ENV = { HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };
const NOKEY = { HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN };

const send = (db, path, method, { body, human = null, env = ENV, wrap = (d) => d } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      'content-type': 'application/json',
      ...(human ? { 'x-human-verdict-token': human } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: wrap(sqliteDB(db)), ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const put = (db, key, value, opts = {}) => send(db, '/api/settings', 'PUT', { body: { key, value }, ...opts });
const get = (db, key, opts = {}) => send(db, `/api/settings/${key}`, 'GET', opts);
const ok = async (p) => { const r = await p; assert.equal(r.status, 200, JSON.stringify(r.body)); return r; };

async function warns(fn) {
  const seen = [];
  const orig = console.warn;
  console.warn = (...a) => { seen.push(a.join(' ')); };
  try { await fn(); } finally { console.warn = orig; }
  return seen;
}

test('L1 a bearer human -> lane on lead_authority is 403 and writes nothing; other keys are untouched', async () => {
  const db = openDb();
  const r = await ok(put(db, K, 'human'));
  assert.equal(r.body.signed, true);
  assert.equal(r.body.sig_seq, 1);
  const auditBefore = changes(db);
  const no = await put(db, K, 'lane');
  assert.equal(no.status, 403, JSON.stringify(no.body));
  assert.equal(no.body.key, K);
  assert.equal(no.body.from, 'human');
  assert.equal(no.body.to, 'lane');
  assert.match(no.body.error, /x-human-verdict-token/);
  assert.match(no.body.error, /protected-setting\.sh/);
  assert.equal(setting(db, K), 'human');
  assert.equal(sigs(db, K).length, 1);
  assert.equal(changes(db), auditBefore);
  // control: a non-prefix key answers as before
  const c = await ok(put(db, 'lead_verdict_min_client', '1'));
  assert.equal(c.body.signed, undefined);
  assert.equal(c.body.setting.value, '1');
});

test('L2 the bearer transition table on lead_authority', async () => {
  const allowed = [[null, 'lane'], ['lane', 'human:precision'], ['human:precision', 'lane'], ['lane', 'human'],
    ['human:precision', 'human'], ['lane', 'foo'], ['foo', 'human:precision'], ['foo', 'human'], ['human', 'human'],
    // la_decide strips whitespace: `hu man` IS human, both as the new and as the current value
    ['human', 'hu man']];
  const refused = [['human', 'human:precision'], ['human', 'lane'], ['human', 'foo'], ['human', 'la ne'], ['foo', 'lane'],
    ['hu man', 'human:precision']];
  // reach `from` the way production does: bearer PUTs from absent (human last, it locks the rest)
  const reach = async (db, from) => {
    if (from === null) return;
    if (from === 'foo' || from === 'hu man') { await ok(put(db, K, 'lane')); await ok(put(db, K, from)); return; }
    await ok(put(db, K, from));
  };
  for (const [from, to] of allowed) {
    const db = openDb();
    await reach(db, from);
    const r = await put(db, K, to);
    assert.equal(r.status, 200, `${from} -> ${to}: ${JSON.stringify(r.body)}`);
    assert.equal(setting(db, K), to.trim());
  }
  for (const [from, to] of refused) {
    const db = openDb();
    await reach(db, from);
    const r = await put(db, K, to);
    assert.equal(r.status, 403, `${from} -> ${to}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.from, from);
    assert.equal(setting(db, K), from);
  }
});

test('L3 the human token loosens and the write is signed at the next seq', async () => {
  const db = openDb();
  await ok(put(db, K, 'human'));
  const r = await ok(put(db, K, 'lane', { human: HUMAN }));
  assert.equal(r.body.signed, true);
  assert.equal(r.body.sig_seq, 2);
  assert.equal(sigs(db, K)[1].sig, hmac(v2Msg(K, 'lane', 2)));
  assert.equal(setting(db, K), 'lane');
  // a wrong token is the bearer alone
  await ok(put(db, K, 'human'));
  assert.equal((await put(db, K, 'lane', { human: 'nope' })).status, 403);
});

test('L4 extras: the bearer may only add globs', async () => {
  const db = openDb();
  await ok(put(db, X, 'a b'));
  await ok(put(db, X, 'b  a\tc'));
  const before = sigs(db, X).length;
  const auditBefore = changes(db);
  const no = await put(db, X, 'a c');
  assert.equal(no.status, 403, JSON.stringify(no.body));
  assert.equal(no.body.key, X);
  assert.deepEqual(no.body.removed, ['b']);
  assert.equal(no.body.to, 'a c');
  assert.match(no.body.error, /x-human-verdict-token/);
  assert.equal(setting(db, X), 'b  a\tc');
  assert.equal(sigs(db, X).length, before);
  assert.equal(changes(db), auditBefore);
  // reorder and doubled whitespace are not a removal
  await ok(put(db, X, 'c b a'));
  const yes = await ok(put(db, X, 'a c', { human: HUMAN }));
  assert.equal(yes.body.signed, true);
  assert.equal(setting(db, X), 'a c');
});

test('L5 under sig enforce an unproven lead_authority reads human', async () => {
  const db = openDb();
  enforce(db);
  await ok(put(db, K, 'human'));
  setRaw(db, K, 'lane');
  let g = await ok(get(db, K));
  assert.deepEqual(g.body.setting, { key: K, value: 'human', unproven: true, stored_value: 'lane' });
  db.prepare('DELETE FROM settings WHERE key=?').run(K);
  g = await ok(get(db, K));
  assert.deepEqual(g.body.setting, { key: K, value: 'human', unproven: true, stored_value: null });
  // a legacy row written straight into D1 with no signature ever
  const L = 'lead_authority.example-org.legacy';
  db.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES (?, 'lane', 'x', 'now')").run(L);
  g = await ok(get(db, L));
  assert.equal(g.body.setting.value, 'human');
  assert.equal(g.body.setting.unproven, true);
  assert.equal(g.body.setting.stored_value, 'lane');
  // never set, never signed: still no row
  g = await ok(get(db, 'lead_authority.example-org.never'));
  assert.equal(g.body.setting, null);
  assert.equal(g.body.source, 'none');
  // a proven lane is just lane
  const P = 'lead_authority.example-org.proven';
  await ok(put(db, P, 'lane'));
  g = await ok(get(db, P));
  assert.equal(g.body.setting.value, 'lane');
  assert.equal('unproven' in g.body.setting, false);
});

test('L6 in shadow an unproven row reads as stored with a warn; L6b an unreadable mode reads enforce', async () => {
  const db = openDb();
  await ok(put(db, K, 'human'));
  setRaw(db, K, 'lane');
  let g;
  const seen = await warns(async () => { g = await ok(get(db, K)); });
  assert.equal(g.body.setting.value, 'lane');
  assert.equal('unproven' in g.body.setting, false);
  assert.ok(seen.some((l) => /BH-3905 unproven lead_authority\.example-org\.cromford/.test(l)), seen.join('\n'));
  const throwing = (d) => ({ ...d, prepare: (sql) => {
    if (sql.includes('key IN (')) throw new Error('D1 down');
    return d.prepare(sql);
  } });
  g = await ok(get(db, K, { wrap: throwing }));
  assert.equal(g.body.setting.value, 'human');
  assert.equal(g.body.setting.unproven, true);
});

test('L7 an unproven extras row is 409 under enforce, stored in shadow; the PUT judges the effective value', async () => {
  const db = openDb();
  await ok(put(db, X, 'a b'));
  setRaw(db, X, 'a');
  let g;
  const seen = await warns(async () => { g = await ok(get(db, X)); });
  assert.equal(g.body.setting.value, 'a');
  assert.ok(seen.some((l) => l.includes(`BH-3905 unproven ${X}`)), seen.join('\n'));
  enforce(db);
  g = await get(db, X);
  assert.equal(g.status, 409, JSON.stringify(g.body));
  assert.equal(g.body.error, `${X} signature does not verify; re-PUT it with the human token`);
  assert.equal(g.body.key, X);
  // `a c` is a superset of the tampered `a` but drops the signed `b`
  const no = await put(db, X, 'a c');
  assert.equal(no.status, 403, JSON.stringify(no.body));
  assert.equal(no.body.from, 'unproven');
  assert.equal(setting(db, X), 'a');
  // a lead_authority tampered from a signed human to lane
  await ok(put(db, K, 'human'));
  setRaw(db, K, 'lane');
  const no2 = await put(db, K, 'lane');
  assert.equal(no2.status, 403, JSON.stringify(no2.body));
  assert.equal(no2.body.from, 'human');
  await ok(put(db, K, 'human'));
  // the human token repairs the extras row
  await ok(put(db, X, 'a b', { human: HUMAN }));
  assert.equal((await ok(get(db, X))).body.setting.value, 'a b');
});

test('L8 the bulk list marks lead_* rows proven and never rewrites them', async () => {
  const db = openDb();
  enforce(db);
  await ok(put(db, K, 'human'));
  await ok(put(db, X, 'a b'));
  setRaw(db, X, 'a');
  const r = await ok(send(db, '/api/settings', 'GET'));
  const row = (k) => r.body.settings.find((s) => s.key === k);
  assert.equal(row(K).proven, true);
  assert.equal(row(K).value, 'human');
  assert.equal(row(X).proven, false);
  assert.equal(row(X).value, 'a');
  for (const k of ['human_verdict_mode', 'human_verdict_sig_mode', 'lead_verdict_min_client']) {
    assert.ok(row(k), k);
    assert.equal('proven' in row(k), false, k);
  }
});

test('L9 a write with no signing key reads unproven and fails closed under enforce', async () => {
  const db = openDb();
  const r = await ok(put(db, K, 'lane', { env: NOKEY }));
  assert.equal(r.body.signed, false);
  const g = await ok(get(db, K, { env: { ...NOKEY, HUMAN_VERDICT_ENFORCE: '1' } }));
  assert.equal(g.body.setting.value, 'human');
  assert.equal(g.body.setting.unproven, true);
  await ok(put(db, X, 'a', { env: NOKEY }));
  enforce(db);
  assert.equal((await get(db, X)).status, 409);
});
