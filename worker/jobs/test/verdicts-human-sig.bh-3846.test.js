import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { createHmac, randomBytes } from 'node:crypto';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3846 — a source=human verdict row, and the two switches that decide how
// much a human row is trusted, must not be forgeable by a direct D1 write. The
// worker HMAC-signs a human-token row (verdicts.human_sig) and a protected
// setting (`<key>.sig`) with HUMAN_VERDICT_SIG_KEY, a worker-only secret, and
// judges proof at read time. Driven against THE SQL THAT SHIPS (schema.sql),
// through worker.fetch; every expected HMAC is recomputed here with node:crypto.
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
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
const rowOf = (db, id) => db.prepare('SELECT * FROM verdicts WHERE id=?').get(id);
const hmac = (msg, key = KEY) => createHmac('sha256', key).update(msg).digest('hex');
const vMsg = (r) => `bh-verdict-v1\n${r.repo}\n${r.pr}\n${r.head_sha}\n${r.verdict}\n${r.created_at}`;
const sMsg = (k, v) => `bh-setting-v1\n${k}\n${v}`;

const H = 'c'.repeat(40);
const base = { repo: 'example-org/cromford', pr: 3846, head_sha: H, verdict: 'MERGE', source: 'human' };
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };
const NOKEY = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN };

const send = (db, path, method, { body, lead = LEAD, human = null, env = ENV } = {}) => {
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
  return worker.fetch(req, { DB: sqliteDB(db), ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (db, opts = {}) => send(db, '/api/verdicts', 'POST', { body: base, ...opts });
const get = (db, opts = {}) => send(db, `/api/verdicts?repo=${base.repo}&pr=${base.pr}&head=${H}`, 'GET', { lead: null, ...opts });
const putSetting = (db, key, value, opts = {}) => send(db, '/api/settings', 'PUT', { body: { key, value }, lead: null, ...opts });
// The signed way to set a protected switch: the human token, the key in env.
const signedPut = async (db, key, value) => {
  const r = await putSetting(db, key, value, { human: HUMAN });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r;
};

// A row written straight into D1, the way `wrangler d1 execute` would.
function directInsert(db, over = {}) {
  const r = { ...base, auth: 'human-token', human_sig: null, created_at: '2026-10-02T00:00:00.000Z', ...over };
  const res = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth, human_sig)
                          VALUES (?,?,?,?,?,?,?,?)`)
    .run(r.repo, r.pr, r.head_sha, r.verdict, r.source, r.created_at, r.auth, r.human_sig);
  return Number(res.lastInsertRowid);
}

// Capture console.warn lines while fn runs.
async function warns(fn) {
  const seen = [];
  const orig = console.warn;
  console.warn = (...a) => { seen.push(a.join(' ')); };
  try { await fn(); } finally { console.warn = orig; }
  return seen;
}

test('W0 the fresh schema has verdicts.human_sig and human_verdict_sig_mode seeds shadow', () => {
  const db = openDb();
  const cols = db.prepare('PRAGMA table_info(verdicts)').all().map((r) => r.name);
  assert.ok(cols.includes('human_sig'), `verdicts columns: ${cols.join(',')}`);
  assert.equal(setting(db, 'human_verdict_sig_mode'), 'shadow');
});

test('S1 a human-token post is signed with an HMAC over (repo, pr, head_sha, verdict, created_at)', async () => {
  const db = openDb();
  const res = await post(db, { human: HUMAN });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.human_signed, true);
  const row = rowOf(db, res.body.verdict.id);
  assert.match(row.human_sig, /^[0-9a-f]{64}$/);
  assert.equal(row.human_sig, hmac(vMsg(row)));
});

test('S2 a lead-token human post and a lead post are never signed', async () => {
  const db = openDb();
  const h = await post(db);
  assert.equal(h.status, 201, JSON.stringify(h.body));
  assert.equal(h.body.human_signed, false);
  assert.equal(rowOf(db, h.body.verdict.id).human_sig, null);
  for (const human of [null, HUMAN]) {
    const l = await post(db, { body: { ...base, source: 'lead' }, human });
    assert.equal(l.status, 201);
    assert.equal(l.body.human_signed, false);
    assert.equal(rowOf(db, l.body.verdict.id).human_sig, null);
  }
});

test('S3 sig enforce with the key unset: a human-token post is 503 and writes nothing; shadow writes unsigned', async () => {
  const db = openDb();
  const shadow = await post(db, { human: HUMAN, env: NOKEY });
  assert.equal(shadow.status, 201, JSON.stringify(shadow.body));
  assert.equal(shadow.body.human_signed, false);
  assert.equal(rowOf(db, shadow.body.verdict.id).human_sig, null);
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  const n = count(db);
  const res = await post(db, { human: HUMAN, env: NOKEY });
  assert.equal(res.status, 503, JSON.stringify(res.body));
  assert.match(res.body.error, /HUMAN_VERDICT_SIG_KEY unset/);
  assert.equal(count(db), n);
});

test('R1 (AT1) a directly inserted human row with no HMAC reads as unproven', async () => {
  const db = openDb();
  const id = directInsert(db);
  const g = await get(db);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.standing.id, id);
  assert.equal(g.body.standing.human_proven, false);
  assert.equal(g.body.rows[0].human_proven, false);
});

test('R2 (AT1) an API-written human-token MERGE verifies, in shadow and in enforce', async () => {
  for (const m of ['shadow', 'enforce']) {
    const db = openDb();
    if (m === 'enforce') await signedPut(db, 'human_verdict_sig_mode', 'enforce');
    const res = await post(db, { human: HUMAN });
    assert.equal(res.status, 201);
    const g = await get(db);
    assert.equal(g.body.standing.human_proven, true, m);
    assert.equal(g.body.standing.source, 'human', m);
    assert.equal(g.body.standing.source_recorded, undefined, m);
    assert.equal(g.body.rows[0].human_proven, true, m);
  }
});

test('R3 sig enforce: every unproven standing human MERGE stands as lead', async () => {
  // a valid sig from a row with a different verdict, copied onto a MERGE
  const blockRow = { ...base, verdict: 'BLOCK', created_at: '2026-10-02T00:00:00.000Z' };
  const cases = [
    ['no sig', {}, ENV],
    ['random sig', { human_sig: randomBytes(32).toString('hex') }, ENV],
    ['copied sig', { human_sig: hmac(vMsg(blockRow)) }, ENV],
    ['MERGE-WITH-NOTES no sig', { verdict: 'MERGE-WITH-NOTES' }, ENV],
  ];
  for (const [name, over, env] of cases) {
    const db = openDb();
    await signedPut(db, 'human_verdict_sig_mode', 'enforce');
    directInsert(db, over);
    const g = await get(db, { env });
    assert.equal(g.body.standing.human_proven, false, name);
    assert.equal(g.body.standing.source, 'lead', name);
    assert.equal(g.body.standing.source_recorded, 'human', name);
  }
  // a genuinely signed row, read with the key gone from the env
  const db = openDb();
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  const res = await post(db, { human: HUMAN });
  assert.equal(res.body.human_signed, true);
  const g = await get(db, { env: NOKEY });
  assert.equal(g.body.standing.human_proven, false);
  assert.equal(g.body.standing.source, 'lead');
  // and a sig that verifies for a different head does not verify for this one
  const db2 = openDb();
  await signedPut(db2, 'human_verdict_sig_mode', 'enforce');
  directInsert(db2, { human_sig: hmac(vMsg({ ...base, head_sha: 'd'.repeat(40), created_at: '2026-10-02T00:00:00.000Z' })) });
  const g2 = await get(db2);
  assert.equal(g2.body.standing.source, 'lead');
});

test('R4 sig shadow: an unproven standing human MERGE stays human and is logged', async () => {
  const db = openDb();
  directInsert(db);
  let g;
  const seen = await warns(async () => { g = await get(db); });
  assert.equal(g.body.standing.source, 'human');
  assert.equal(g.body.standing.human_proven, false);
  assert.ok(seen.some((l) => /BH-3846 shadow/.test(l)), seen.join('\n'));
});

test('R5 sig enforce: rows[] and the stored row keep source=human', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  const id = directInsert(db);
  const before = rowOf(db, id);
  const g = await get(db);
  assert.equal(g.body.standing.source, 'lead');
  assert.equal(g.body.rows[0].source, 'human');
  assert.equal(g.body.rows[0].source_recorded, undefined);
  assert.deepEqual(rowOf(db, id), before);
});

test('R6 sig enforce: an unproven human BLOCK still stands as human; a lead row is never human_proven', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  directInsert(db, { verdict: 'BLOCK' });
  const g = await get(db);
  assert.equal(g.body.standing.source, 'human');
  assert.equal(g.body.standing.verdict, 'BLOCK');
  assert.equal(g.body.standing.human_proven, false);
  const db2 = openDb();
  const created_at = '2026-10-02T00:00:00.000Z';
  directInsert(db2, { source: 'lead', created_at, human_sig: hmac(vMsg({ ...base, created_at })) });
  const g2 = await get(db2);
  assert.equal(g2.body.standing.source, 'lead');
  assert.equal(g2.body.standing.human_proven, null);
});

test('M1 a human-token PUT of human_verdict_mode writes a matching .sig row', async () => {
  const db = openDb();
  const r = await signedPut(db, 'human_verdict_mode', 'enforce');
  assert.equal(r.body.signed, true);
  assert.equal(setting(db, 'human_verdict_mode'), 'enforce');
  assert.equal(setting(db, 'human_verdict_mode.sig'), hmac(sMsg('human_verdict_mode', 'enforce')));
});

test('M2 (AT2) a directly-written shadow over a signed enforce is still enforced, and logged', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_mode', 'enforce');
  setRaw(db, 'human_verdict_mode', 'shadow');
  let res;
  const seen = await warns(async () => { res = await post(db); });
  assert.equal(res.status, 403, JSON.stringify(res.body));
  assert.equal(count(db), 0);
  assert.ok(seen.some((l) => /BH-3846 human_verdict_mode signature mismatch/.test(l)), seen.join('\n'));
  // junk in the sig row is tamper too
  setRaw(db, 'human_verdict_mode.sig', 'junk');
  assert.equal((await post(db)).status, 403);
  // a signed shadow is honoured
  await signedPut(db, 'human_verdict_mode', 'shadow');
  assert.equal((await post(db)).status, 201);
});

test('M3 tamper that deletes the sig row: enforce (BH-3905 v2 row), and the floor', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_mode', 'enforce');
  setRaw(db, 'human_verdict_mode', 'shadow');
  db.prepare("DELETE FROM settings WHERE key='human_verdict_mode.sig'").run();
  // BH-3905: the setting_sigs row still binds enforce, so the v1 gap is closed
  assert.equal((await post(db)).status, 403);
  const floored = await post(db, { env: { ...ENV, HUMAN_VERDICT_ENFORCE: '1' } });
  assert.equal(floored.status, 403, JSON.stringify(floored.body));
  for (const v of ['0', 'true', ' 1x']) {
    assert.equal((await post(db, { env: { ...ENV, HUMAN_VERDICT_ENFORCE: v } })).status, 403, `floor ${v}`);
  }
  // a v1-only DB (no setting_sigs row): a verifying v1 .sig reads shadow, and
  // deleting it is still the gap only the floor closes
  const v1 = openDb();
  v1.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES ('human_verdict_mode.sig', ?, 'x', 'now')")
    .run(hmac(sMsg('human_verdict_mode', 'shadow')));
  assert.equal((await post(v1)).status, 201);
  v1.prepare("DELETE FROM settings WHERE key='human_verdict_mode.sig'").run();
  assert.equal((await post(v1)).status, 201);
  assert.equal((await post(v1, { env: { ...ENV, HUMAN_VERDICT_ENFORCE: '1' } })).status, 403);
  for (const v of ['0', 'true', ' 1x']) {
    assert.equal((await post(v1, { env: { ...ENV, HUMAN_VERDICT_ENFORCE: v } })).status, 201, `v1 floor ${v}`);
  }
});

test('M4 the same tamper on human_verdict_sig_mode: an unproven human MERGE still stands as lead', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  setRaw(db, 'human_verdict_sig_mode', 'shadow');
  directInsert(db);
  assert.equal((await get(db)).body.standing.source, 'lead');
  db.prepare("DELETE FROM settings WHERE key='human_verdict_sig_mode.sig'").run();
  // BH-3905: the setting_sigs row still binds enforce
  assert.equal((await get(db)).body.standing.source, 'lead');
  assert.equal((await get(db, { env: { ...ENV, HUMAN_VERDICT_ENFORCE: '1' } })).body.standing.source, 'lead');
  // a v1-only DB: a verifying v1 .sig for shadow lets the unproven row stand as human
  const v1 = openDb();
  v1.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES ('human_verdict_sig_mode.sig', ?, 'x', 'now')")
    .run(hmac(sMsg('human_verdict_sig_mode', 'shadow')));
  directInsert(v1);
  assert.equal((await get(v1)).body.standing.source, 'human');
});

test('M5 a PUT of a protected .sig key is refused with any token', async () => {
  const db = openDb();
  for (const k of ['human_verdict_mode.sig', 'human_verdict_sig_mode.sig']) {
    for (const opts of [{}, { lead: LEAD }, { human: HUMAN }]) {
      const r = await putSetting(db, k, 'a'.repeat(64), opts);
      assert.equal(r.status, 400, `${k} ${JSON.stringify(opts)}: ${JSON.stringify(r.body)}`);
      assert.equal(setting(db, k), null);
    }
  }
});

test('M6 human_verdict_sig_mode needs the human token; an unrelated key is unaffected', async () => {
  const db = openDb();
  assert.equal((await putSetting(db, 'human_verdict_sig_mode', 'enforce')).status, 403);
  assert.equal((await putSetting(db, 'human_verdict_sig_mode', 'enforce', { lead: LEAD })).status, 403);
  assert.equal(setting(db, 'human_verdict_sig_mode'), 'shadow');
  const ok = await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  assert.equal(ok.body.signed, true);
  assert.equal(setting(db, 'human_verdict_sig_mode.sig'), hmac(sMsg('human_verdict_sig_mode', 'enforce')));
  const other = await putSetting(db, 'lead_verdict_min_client', '2');
  assert.equal(other.status, 200);
  assert.equal(other.body.signed, undefined);
  assert.equal(setting(db, 'lead_verdict_min_client.sig'), null);
});

test('M7 a protected PUT with the key unset writes the value unsigned and says so', async () => {
  const db = openDb();
  const r = await putSetting(db, 'human_verdict_mode', 'enforce', { human: HUMAN, env: NOKEY });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.signed, false);
  assert.equal(setting(db, 'human_verdict_mode.sig'), null);
});

test('R7 a whole-row replay of a revoked signed human MERGE reads unproven and stands as lead', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  const merge = await post(db, { human: HUMAN });
  assert.equal(merge.status, 201);
  const blocked = await post(db, { human: HUMAN, body: { ...base, verdict: 'BLOCK' } });
  assert.equal(blocked.status, 201);
  assert.equal((await get(db)).body.standing.verdict, 'BLOCK');
  // the hub copies the old MERGE row whole, sig and created_at included
  const res = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer_model, reviewer,
                                                report_url, note, created_at, auth, human_sig)
                          SELECT repo, pr, head_sha, verdict, source, reviewer_model, reviewer,
                                 report_url, note, created_at, auth, human_sig FROM verdicts WHERE id=?`)
    .run(merge.body.verdict.id);
  const copy = Number(res.lastInsertRowid);
  // the copy's signature does verify on its own fields: only the duplicate check catches it
  assert.equal(rowOf(db, copy).human_sig, hmac(vMsg(rowOf(db, copy))));
  const g = await get(db);
  assert.equal(g.body.standing.id, copy);
  assert.equal(g.body.standing.human_proven, false);
  assert.equal(g.body.standing.source, 'lead');
  assert.equal(g.body.standing.source_recorded, 'human');
  const byId = new Map(g.body.rows.map((r) => [r.id, r.human_proven]));
  assert.equal(byId.get(copy), false);
  assert.equal(byId.get(merge.body.verdict.id), true);
  assert.equal(byId.get(blocked.body.verdict.id), true);
  // the standing_only path judges it the same way
  const so = await send(db, `/api/verdicts?repo=${base.repo}&pr=${base.pr}&head=${H}&standing_only=1`, 'GET', { lead: null });
  assert.equal(so.body.standing.human_proven, false);
  assert.equal(so.body.standing.source, 'lead');
  // in shadow the copy is logged rather than downgraded
  await signedPut(db, 'human_verdict_sig_mode', 'shadow');
  let sg;
  const seen = await warns(async () => { sg = await get(db); });
  assert.equal(sg.body.standing.source, 'human');
  assert.ok(seen.some((l) => new RegExp(`BH-3846 shadow: unproven source=human standing row #${copy}`).test(l)), seen.join('\n'));
});

test('M8 GET /api/settings and GET /api/settings/<key>.sig never echo a protected signature', async () => {
  const db = openDb();
  await signedPut(db, 'human_verdict_mode', 'shadow');
  await signedPut(db, 'human_verdict_sig_mode', 'enforce');
  const all = await send(db, '/api/settings', 'GET', { lead: null });
  assert.equal(all.status, 200);
  for (const k of ['human_verdict_mode.sig', 'human_verdict_sig_mode.sig']) {
    const row = all.body.settings.find((s) => s.key === k);
    assert.ok(row, k);
    assert.equal(row.value, null, k);
    assert.equal(row.redacted, true, k);
    const one = await send(db, `/api/settings/${k}`, 'GET', { lead: null });
    assert.equal(one.status, 200);
    assert.equal(one.body.setting.value, null, k);
    assert.ok(!JSON.stringify(one.body).includes(setting(db, k)), k);
  }
  assert.ok(!JSON.stringify(all.body).includes(setting(db, 'human_verdict_mode.sig')));
  // the switches themselves still read normally
  assert.equal(all.body.settings.find((s) => s.key === 'human_verdict_sig_mode').value, 'enforce');
});
