import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { createHmac } from 'node:crypto';
import worker from '../src/index.js';
import * as verdicts from '../src/routes/verdicts.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const { PROTECTED_PREFIXES, isProtectedSetting, settingProof, settingSigMessageV2 } = verdicts;

// BH-3905 (BH-4087): a protected setting's signature carries a per-key sequence
// number, kept in the append-only setting_sigs table. protectedMode judges the
// NEWEST row, so a signed `shadow` saved earlier and written back later is bound
// to its old seq and no longer verifies. Driven against THE SQL THAT SHIPS
// (schema.sql), through worker.fetch; every expected HMAC is recomputed here.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const HUMAN = 'human-test-token';
const KEY = 'sig-test-key';
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
const setRaw = (db, k, v) => db.prepare('UPDATE settings SET value=? WHERE key=?').run(v, k);
const sigs = (db, k) => db.prepare('SELECT * FROM setting_sigs WHERE key=? ORDER BY seq').all(k);
const sigCount = (db) => db.prepare('SELECT COUNT(*) AS n FROM setting_sigs').get().n;
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
const hmac = (msg, key = KEY) => createHmac('sha256', key).update(msg).digest('hex');
const v1Msg = (k, v) => `bh-setting-v1\n${k}\n${v}`;
const v2Msg = (k, v, seq) => `bh-setting-v2\n${k}\n${v}\n${seq}`;

const H = 'c'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 3905, head_sha: H, verdict: 'MERGE', source: 'human' };
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };
const NOKEY = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN };

const send = (db, path, method, { body, lead = LEAD, human = null, env = ENV, wrap = (d) => d } = {}) => {
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
  return worker.fetch(req, { DB: wrap(sqliteDB(db)), ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (db, opts = {}) => send(db, '/api/verdicts', 'POST', { body: base, ...opts });
const get = (db, opts = {}) => send(db, `/api/verdicts?repo=${base.repo}&pr=${base.pr}&head=${H}`, 'GET', { lead: null, ...opts });
const putSetting = (db, key, value, opts = {}) => send(db, '/api/settings', 'PUT', { body: { key, value }, lead: null, ...opts });
const signedPut = async (db, key, value) => {
  const r = await putSetting(db, key, value, { human: HUMAN });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r;
};

async function warns(fn) {
  const seen = [];
  const orig = console.warn;
  console.warn = (...a) => { seen.push(a.join(' ')); };
  try { await fn(); } finally { console.warn = orig; }
  return seen;
}

test('N1 a signed PUT appends setting_sigs (key, 1, v2 HMAC) and keeps the v1 .sig for the switch', async () => {
  const db = openDb();
  const r = await signedPut(db, 'human_verdict_mode', 'enforce');
  assert.equal(r.body.signed, true);
  assert.equal(r.body.sig_seq, 1);
  const rows = sigs(db, 'human_verdict_mode');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].seq, 1);
  assert.equal(rows[0].sig, hmac(v2Msg('human_verdict_mode', 'enforce', 1)));
  assert.equal(rows[0].actor, 'api');
  assert.ok(rows[0].at);
  assert.equal(setting(db, 'human_verdict_mode.sig'), hmac(v1Msg('human_verdict_mode', 'enforce')));
  // a second PUT is a fresh proof at the next seq, same value or not
  const r2 = await signedPut(db, 'human_verdict_mode', 'enforce');
  assert.equal(r2.body.sig_seq, 2);
  assert.equal(sigs(db, 'human_verdict_mode')[1].sig, hmac(v2Msg('human_verdict_mode', 'enforce', 2)));
});

test('N2 an old signed shadow written back over a signed enforce no longer replays', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_mode', 'shadow');
  const savedV1 = setting(db, 'human_verdict_mode.sig');
  const savedV2 = sigs(db, 'human_verdict_mode')[0].sig;
  await signedPut(db, 'human_verdict_mode', 'enforce');
  // the D1 writer restores every artefact of the old shadow write it can
  setRaw(db, 'human_verdict_mode', 'shadow');
  setRaw(db, 'human_verdict_mode.sig', savedV1);
  db.prepare("INSERT INTO setting_sigs (key, seq, sig, actor, at) VALUES ('human_verdict_mode', 3, ?, 'x', 'now')").run(savedV2);
  let res;
  const seen = await warns(async () => { res = await post(db); });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(count(db), 0);
  assert.ok(seen.some((l) => l.includes('[settings] BH-3846 human_verdict_mode signature mismatch')), seen.join('\n'));
  // the seq it was signed under is already taken
  assert.throws(() => db.prepare("INSERT INTO setting_sigs (key, seq, sig, actor, at) VALUES ('human_verdict_mode', 1, ?, 'x', 'now')").run(savedV2), /UNIQUE/);
  // junk at a new seq, and a right sig for another key, are mismatches too
  for (const sig of ['junk', hmac(v2Msg('human_verdict_sig_mode', 'shadow', 4))]) {
    db.prepare("INSERT INTO setting_sigs (key, seq, sig, actor, at) VALUES ('human_verdict_mode', (SELECT MAX(seq)+1 FROM setting_sigs WHERE key='human_verdict_mode'), ?, 'x', 'now')").run(sig);
    assert.equal((await post(db)).status, 403, sig);
  }
});

test('N3 setting_sigs is append-only and (key, seq) is unique', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_mode', 'enforce');
  assert.throws(() => db.prepare("UPDATE setting_sigs SET sig='x'").run(), /setting_sigs is append-only/);
  assert.throws(() => db.prepare('DELETE FROM setting_sigs').run(), /setting_sigs is append-only/);
  assert.throws(() => db.prepare("INSERT INTO setting_sigs (key, seq, sig, actor, at) VALUES ('human_verdict_mode', 1, 'x', 'x', 'now')").run(), /UNIQUE/);
  assert.equal(sigCount(db), 1);
});

test('N4 deleting the value and .sig rows with a v2 row present reads enforce', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_mode', 'enforce');
  db.prepare("DELETE FROM settings WHERE key IN ('human_verdict_mode', 'human_verdict_mode.sig')").run();
  assert.equal((await post(db)).status, 403);
  assert.equal(count(db), 0);
  // the same on human_verdict_sig_mode: an unproven human MERGE stands as lead
  await signedPut(db, 'human_verdict_mode', 'shadow');
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  db.prepare("DELETE FROM settings WHERE key IN ('human_verdict_sig_mode', 'human_verdict_sig_mode.sig')").run();
  db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth, human_sig)
              VALUES (?,?,?,?,?,?,?,NULL)`).run(base.repo, base.pr, H, 'MERGE', 'human', '2026-10-03T00:00:00.000Z', 'human-token');
  assert.equal((await get(db)).body.standing.source, 'lead');
});

test('N5 a v1-only DB falls back to the .sig rules and logs the missing nonce', async () => {
  const db = openDb();
  setRaw(db, 'human_verdict_mode', 'shadow');
  db.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES ('human_verdict_mode.sig', ?, 'x', 'now')")
    .run(hmac(v1Msg('human_verdict_mode', 'shadow')));
  let res;
  let seen = await warns(async () => { res = await post(db); });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.ok(seen.some((l) => l.includes('[settings] BH-3905 human_verdict_mode carries a v1 signature with no nonce: re-PUT it with the human token')), seen.join('\n'));
  assert.equal(sigCount(db), 0);
  setRaw(db, 'human_verdict_mode.sig', 'junk');
  seen = await warns(async () => { res = await post(db); });
  assert.equal(res.status, 403);
  assert.ok(seen.some((l) => l.includes('BH-3846 human_verdict_mode signature mismatch')), seen.join('\n'));
  assert.ok(!seen.some((l) => l.includes('BH-3905')), seen.join('\n'));
});

test('N6 a seq race answers 409 and writes nothing', async () => {
  const db = openDb();
  // a concurrent PUT lands its sig row between this PUT's seq read and its batch
  const wrap = (d) => ({
    ...d,
    batch: async (stmts) => {
      const n = db.prepare("SELECT COALESCE(MAX(seq),0)+1 AS n FROM setting_sigs WHERE key='human_verdict_mode'").get().n;
      db.prepare("INSERT INTO setting_sigs (key, seq, sig, actor, at) VALUES ('human_verdict_mode', ?, 'other', 'x', 'now')").run(n);
      return d.batch(stmts);
    },
  });
  const r = await putSetting(db, 'human_verdict_mode', 'enforce', { human: HUMAN, wrap });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.deepEqual(r.body, { error: 'concurrent protected write, retry' });
  assert.equal(setting(db, 'human_verdict_mode'), 'shadow');
  assert.equal(setting(db, 'human_verdict_mode.sig'), null);
  assert.equal(sigCount(db), 1);
  // any other batch failure is not a 409
  const boom = (d) => ({ ...d, batch: async () => { throw new Error('D1_ERROR: network lost'); } });
  const r2 = await putSetting(db, 'human_verdict_mode', 'enforce', { human: HUMAN, wrap: boom });
  assert.equal(r2.status, 503, JSON.stringify(r2.body));
});

test('N7 a protected PUT with the key unset writes no sig row and no sig_seq', async () => {
  const db = openDb();
  const r = await putSetting(db, 'human_verdict_mode', 'enforce', { human: HUMAN, env: NOKEY });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, false);
  assert.equal('sig_seq' in r.body, false);
  assert.equal(sigCount(db), 0);
});

test('L1 lead_authority.* and lead_protected_paths_extra.* PUTs are signed; other keys are not', async () => {
  const db = openDb();
  for (const k of ['lead_authority.example-org.cromford', 'lead_protected_paths_extra.example-org.cromford']) {
    const r = await putSetting(db, k, 'human');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.signed, true, k);
    assert.equal(r.body.sig_seq, 1, k);
    const rows = sigs(db, k);
    assert.equal(rows.length, 1, k);
    assert.equal(rows[0].sig, hmac(v2Msg(k, 'human', 1)), k);
    assert.equal(setting(db, `${k}.sig`), null, k);
    // no loosening gate and no effective value here: GET returns what was stored
    const g = await send(db, `/api/settings/${k}`, 'GET', { lead: null });
    assert.equal(g.body.setting.value, 'human', k);
  }
  const other = await putSetting(db, 'lead_verdict_min_client', '2');
  assert.equal(other.status, 200);
  assert.equal(other.body.signed, undefined);
  assert.equal(other.body.sig_seq, undefined);
  assert.equal(sigs(db, 'lead_verdict_min_client').length, 0);
});

test('P1 settingProof answers none, proven, mismatch and null', async () => {
  const db = openDb();
  const env = { DB: sqliteDB(db), ...ENV };
  assert.equal(await settingProof(env, 'human_verdict_mode', 'shadow'), 'none');
  await signedPut(db, 'human_verdict_mode', 'enforce');
  assert.equal(await settingProof(env, 'human_verdict_mode', 'enforce'), 'proven');
  assert.equal(await settingProof(env, 'human_verdict_mode', 'shadow'), 'mismatch');
  assert.equal(await settingProof(env, 'human_verdict_mode', null), 'mismatch');
  assert.equal(await settingProof({ DB: sqliteDB(db), ...NOKEY }, 'human_verdict_mode', 'enforce'), 'mismatch');
  const broken = { prepare: () => { throw new Error('D1 down'); }, batch: async () => { throw new Error('D1 down'); } };
  assert.equal(await settingProof({ DB: broken, ...ENV }, 'human_verdict_mode', 'enforce'), null);
  assert.equal(settingSigMessageV2('k', 'v', 7), 'bh-setting-v2\nk\nv\n7');
});

test('P2 isProtectedSetting covers the two switches, the two lead prefixes and risk_tier. (BH-5022)', () => {
  assert.deepEqual(PROTECTED_PREFIXES, ['lead_authority.', 'lead_protected_paths_extra.', 'risk_tier.']);
  for (const k of ['human_verdict_mode', 'human_verdict_sig_mode', 'lead_authority.x', 'lead_protected_paths_extra.y', 'risk_tier.low_globs']) {
    assert.equal(isProtectedSetting(k), true, k);
  }
  for (const k of ['lead_verdict_min_client', 'human_verdict_mode.sig', 'lead_authority', 'x.lead_authority.y']) {
    assert.equal(isProtectedSetting(k), false, k);
  }
});
