// BH-9262 (C1): the owner-approval inbox. The hub holds no owner proof, so a
// chat caller that meets a proof-required 403 files the request here with the
// fleet bearer; the owner acts on it in the console through the existing proved
// route and then marks the row decided. A row grants nothing.
//
// Everything goes through the REAL worker.fetch on the REAL composed schema
// (node:sqlite D1 shim), a fresh in-memory DB per test.
//
//   A1  the filing table: new 201, dedupe 200 (one row), same key other kind 201,
//       a non-owner type, an unknown key, a bad value, an oversize payload: 400
//   A2  the exact bodies bin/archie.sh and bin/box-request.sh post file and read back
//   A3  GET: pending default, newest first, expired computed on read, limit + truncated
//   A4  decide table (i)-(x)
//   A5  the knobs: code fallbacks with no settings rows, and a row wins
//   A6  box-commands: an enforce refusal carries proof:"required"; shadow does not
//   A7  EXPLAIN on 5,000 seeded rows: each hot read uses its index
//   A8  retention: the rule reads its ids through owner_approvals_created and a
//       real run deletes the old row only
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { boxOpsHeaders } from '../../../console-ui/functions/_lib/box-ops-proof.js';
import { RULES } from '#retention-rules';

const SECRET = 'test-secret-fixture-9262c1';
const LEAD = 'lead-token-fixture-9262c1';
const HUMAN = 'human-token-fixture-9262c1';
const BOX = 'box-ops-token-fixture-9262c1';
const OWNER = 'operator@example.com';
const SIG = 'sig-key-fixture-9262c1';
const ENV = {
  HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN,
  BOX_OPS_TOKEN: BOX, BOX_OPS_OWNERS: OWNER, HUMAN_VERDICT_SIG_KEY: SIG,
};
const HUMAN_H = { 'x-human-verdict-token': HUMAN };
const PAGES_H = boxOpsHeaders({ access: 'on', email: OWNER, actor: OWNER }, { BOX_OPS_TOKEN: BOX });
const NOW = Date.now(); // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (h) => new Date(NOW - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function open(t) {
  const env = await openDb();
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return env;
}

async function send(DB, path, body, { headers = {}, env = {}, method = 'POST' } = {}) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', ...headers },
    body: method === 'GET' ? undefined : JSON.stringify(body),
  }), { ...ENV, DB, ...env });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const get = (DB, q = '') => send(DB, `/api/owner-approvals${q}`, null, { method: 'GET' });
const file = (DB, body) => send(DB, '/api/owner-approvals', body);
const decide = (DB, id, body, headers = {}) => send(DB, `/api/owner-approvals/${id}/decide`, body, { headers });
const rows = (db) => db.prepare('SELECT * FROM owner_approvals ORDER BY id').all();

// The bodies the two chat callers post (tests/owner-approvals-chat.bh-9262-test.sh
// captures the same shapes from the real scripts).
const ARCHIE_BODY = {
  kind: 'archie_delegation', payload: { class: 'lint-fixes', min_streak: 5 }, actor: 'chat',
  via: 'telegram:operator', dedupe_key: 'archie-delegation:lint-fixes:cmd-fixture-1',
};
const QUOTE_BODY = {
  kind: 'box_command',
  payload: {
    box: 'hub', type: 'orgo_launch_quote', target: 'project-3', account: 'main', project: 'project-3',
    vcpus: 4, mem_gb: 8, disk_gb: 64, reason: 'chat: /box launch project-3',
  },
  actor: OWNER, via: 'telegram:operator', dedupe_key: 'box:orgo_launch_quote:project-3:cmd-fixture-2',
};
const FLY_BODY = {
  kind: 'box_command',
  payload: { box: 'hub', type: 'fly_pool_cap', target: 'project-3', cap: 3, reason: 'chat: yes to the project offer for project-3' },
  actor: OWNER, via: 'telegram:operator', dedupe_key: 'box:fly_pool_cap:project-3:cmd-fixture-3',
};

function seedRow(db, { kind = 'box_command', key, status = 'pending', created, payload = QUOTE_BODY.payload }) {
  return db.prepare(
    `INSERT INTO owner_approvals (kind, dedupe_key, payload, actor, via, status, created_at)
     VALUES (?,?,?,?,?,?,?)`,
  ).run(kind, key, JSON.stringify(payload), OWNER, 'telegram:operator', status, created).lastInsertRowid;
}
const dropKnobs = (db) => db.prepare("DELETE FROM settings WHERE key LIKE 'owner_approvals.%'").run();
const setKnob = (db, k, v) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','t') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
).run(k, v);

// --- A1: filing ----------------------------------------------------------------

test('A1 filing: new 201, the same key 200 deduped with one row, the same key under another kind 201', async (t) => {
  const env = await open(t); if (!env) return;
  const a = await file(env.DB, QUOTE_BODY);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.deduped, false);
  assert.ok(Number.isInteger(a.body.id) && a.body.id > 0);
  assert.equal(a.body.approval.kind, 'box_command');
  assert.equal(a.body.approval.status, 'pending');
  assert.equal(a.body.approval.via, 'telegram:operator');
  assert.equal(a.body.approval.actor, OWNER);
  assert.deepEqual(a.body.approval.payload, QUOTE_BODY.payload);
  const b = await file(env.DB, QUOTE_BODY);
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.deduped, true);
  assert.equal(b.body.id, a.body.id);
  assert.equal(rows(env.db).length, 1);
  const c = await file(env.DB, { ...ARCHIE_BODY, dedupe_key: QUOTE_BODY.dedupe_key });
  assert.equal(c.status, 201, JSON.stringify(c.body));
  assert.notEqual(c.body.id, a.body.id);
  assert.equal(rows(env.db).length, 2);
});

test('A1 filing refusals: each is 400 and writes no row', async (t) => {
  const env = await open(t); if (!env) return;
  const cases = [
    ['a type that is not owner-only', { ...QUOTE_BODY, payload: { ...QUOTE_BODY.payload, type: 'backup_now' } }],
    ['an unknown payload key', { ...QUOTE_BODY, payload: { ...QUOTE_BODY.payload, quote_id: 7 } }],
    ['a payload value that is an object', { ...QUOTE_BODY, payload: { ...QUOTE_BODY.payload, account: { a: 1 } } }],
    ['no target', { ...QUOTE_BODY, payload: { box: 'hub', type: 'orgo_launch_quote', reason: 'x' } }],
    ['an unknown kind', { ...QUOTE_BODY, kind: 'staff_raise' }],
    ['no dedupe_key', { ...QUOTE_BODY, dedupe_key: '' }],
    ['a payload that is not an object', { ...QUOTE_BODY, payload: 'orgo_launch_quote' }],
    ['an archie class that does not parse', { ...ARCHIE_BODY, payload: { class: 'Lint Fixes!', min_streak: 5 } }],
    ['an archie min_streak that is a string', { ...ARCHIE_BODY, payload: { class: 'lint-fixes', min_streak: '5' } }],
    ['an archie extra key', { ...ARCHIE_BODY, payload: { class: 'lint-fixes', min_streak: 5, decision: 'delegate' } }],
    ['a payload over 4096 bytes', { ...QUOTE_BODY, payload: { ...QUOTE_BODY.payload, reason: 'r'.repeat(4100) } }],
  ];
  for (const [name, body] of cases) {
    const r = await file(env.DB, body);
    assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(typeof r.body.error, 'string', name);
  }
  assert.equal(rows(env.db).length, 0);
});

test('A1 filing needs the fleet bearer', async (t) => {
  const env = await open(t); if (!env) return;
  const res = await worker.fetch(new Request('https://jobs.test/api/owner-approvals', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(QUOTE_BODY),
  }), { ...ENV, DB: env.DB });
  assert.equal(res.status, 401);
  assert.equal(rows(env.db).length, 0);
});

// --- A2: the chat callers' bodies round-trip ------------------------------------

test('A2 the archie, quote and fly bodies file and read back unchanged through GET', async (t) => {
  const env = await open(t); if (!env) return;
  for (const b of [ARCHIE_BODY, QUOTE_BODY, FLY_BODY]) assert.equal((await file(env.DB, b)).status, 201);
  const g = await get(env.DB);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  const byKey = new Map(g.body.approvals.map((x) => [x.dedupe_key, x]));
  for (const b of [ARCHIE_BODY, QUOTE_BODY, FLY_BODY]) {
    const x = byKey.get(b.dedupe_key);
    assert.ok(x, b.dedupe_key);
    assert.equal(x.kind, b.kind);
    assert.deepEqual(x.payload, b.payload);
    assert.equal(x.via, b.via);
    assert.equal(x.status, 'pending');
  }
});

// --- A3: the list ------------------------------------------------------------------

test('A3 GET: pending by default, newest first; a pending row past the TTL is expired and not in the pending list', async (t) => {
  const env = await open(t); if (!env) return;
  const old = seedRow(env.db, { key: 'k-old', created: ago(100) });       // past 72 h
  const mid = seedRow(env.db, { key: 'k-mid', created: ago(5) });
  const neu = seedRow(env.db, { key: 'k-new', created: ago(1) });
  seedRow(env.db, { key: 'k-done', status: 'approved', created: ago(2) });
  const g = await get(env.DB);
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.approvals.map((x) => x.id), [Number(neu), Number(mid)]);
  assert.equal(g.body.truncated, false);
  const e = await get(env.DB, '?status=expired');
  assert.deepEqual(e.body.approvals.map((x) => [x.id, x.status]), [[Number(old), 'expired']]);
  const all = await get(env.DB, '?status=all');
  assert.deepEqual(all.body.approvals.map((x) => x.dedupe_key), ['k-new', 'k-done', 'k-mid', 'k-old']);
  assert.equal(all.body.approvals.find((x) => x.dedupe_key === 'k-old').status, 'expired', 'computed on read');
  assert.equal(env.db.prepare("SELECT status FROM owner_approvals WHERE dedupe_key='k-old'").get().status, 'pending', 'never written');
  assert.equal((await get(env.DB, '?status=bogus')).status, 400);
});

test('A3 GET: the list stops at the limit and says truncated', async (t) => {
  const env = await open(t); if (!env) return;
  setKnob(env.db, 'owner_approvals.list_limit', '2');
  for (let i = 0; i < 3; i++) seedRow(env.db, { key: `k${i}`, created: ago(3 - i) });
  const g = await get(env.DB);
  assert.equal(g.body.approvals.length, 2);
  assert.equal(g.body.truncated, true);
  assert.deepEqual(g.body.approvals.map((x) => x.dedupe_key), ['k2', 'k1']);
});

// --- A4: decide ------------------------------------------------------------------------

test('A4 decide (i)-(vii): only the two proofs decide; the bearer, a body actor or a half proof is 403 and nothing changes', async (t) => {
  const env = await open(t); if (!env) return;
  const id = Number(seedRow(env.db, { key: 'k1', created: ago(1) }));
  const refusals = [
    ['(i) bearer only', {}, {}],
    ['(ii) bearer + body actor=owner', {}, { actor: OWNER }],
    ['(v) box-ops token, identity not an owner', { 'x-box-ops-token': BOX, 'x-box-ops-identity': 'someone@example.net' }, {}],
    ['(vi) box-ops token, no identity', { 'x-box-ops-token': BOX }, {}],
    ['(vii) a wrong box-ops token', { 'x-box-ops-token': `${BOX}x`, 'x-box-ops-identity': OWNER }, {}],
    ['identity with no token', { 'x-box-ops-identity': OWNER }, {}],
  ];
  for (const [name, headers, extra] of refusals) {
    const r = await decide(env.DB, id, { decision: 'approved', ...extra }, headers);
    assert.equal(r.status, 403, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, 'human_proof_required', name);
  }
  // a BOX_OPS_TOKEN equal to the fleet bearer proves nothing (C0 box_ops_unset)
  const same = await send(env.DB, `/api/owner-approvals/${id}/decide`, { decision: 'approved' },
    { headers: { 'x-box-ops-token': SECRET, 'x-box-ops-identity': OWNER }, env: { BOX_OPS_TOKEN: SECRET } });
  assert.equal(same.status, 403);
  // the mode row does not open the route: shadow is the default and still 403
  assert.equal(env.db.prepare("SELECT count(*) AS n FROM settings WHERE key='owner_proof_mode'").get().n, 0);
  assert.equal(rows(env.db)[0].status, 'pending');
  assert.equal(rows(env.db)[0].decided_at, null);
});

test('A4 decide (iii) the human token approves; decided_by is human-token', async (t) => {
  const env = await open(t); if (!env) return;
  const id = Number(seedRow(env.db, { key: 'k1', created: ago(1) }));
  const r = await decide(env.DB, id, { decision: 'approved', result_ref: '42' }, HUMAN_H);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.approval.status, 'approved');
  const row = rows(env.db)[0];
  assert.equal(row.status, 'approved');
  assert.equal(row.decided_by, 'human-token');
  assert.equal(row.result_ref, '42');
  assert.ok(row.decided_at);
});

test('A4 decide (iv) the Pages proof declines; decided_by is the Access identity', async (t) => {
  const env = await open(t); if (!env) return;
  const id = Number(seedRow(env.db, { key: 'k1', created: ago(1) }));
  const r = await decide(env.DB, id, { decision: 'declined' }, PAGES_H);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const row = rows(env.db)[0];
  assert.equal(row.status, 'declined');
  assert.equal(row.decided_by, OWNER);
  assert.equal(row.result_ref, null);
});

test('A4 decide (viii)-(x): a second decide 409, an expired row 409, an unknown id 404, a bad decision 400', async (t) => {
  const env = await open(t); if (!env) return;
  const id = Number(seedRow(env.db, { key: 'k1', created: ago(1) }));
  assert.equal((await decide(env.DB, id, { decision: 'approved' }, HUMAN_H)).status, 200);
  const again = await decide(env.DB, id, { decision: 'declined' }, HUMAN_H);
  assert.equal(again.status, 409);
  assert.equal(again.body.error, 'already_decided');
  assert.equal(again.body.approval.status, 'approved');
  assert.equal(rows(env.db)[0].status, 'approved', 'the first decision stands');
  const old = Number(seedRow(env.db, { key: 'k-old', created: ago(100) }));
  const exp = await decide(env.DB, old, { decision: 'approved' }, HUMAN_H);
  assert.equal(exp.status, 409);
  assert.equal(exp.body.error, 'expired');
  assert.equal(env.db.prepare('SELECT status FROM owner_approvals WHERE id=?').get(old).status, 'pending');
  const none = await decide(env.DB, 9999, { decision: 'approved' }, HUMAN_H);
  assert.equal(none.status, 404);
  const bad = await decide(env.DB, Number(seedRow(env.db, { key: 'k3', created: ago(1) })), { decision: 'yes' }, HUMAN_H);
  assert.equal(bad.status, 400);
  const badRef = await decide(env.DB, Number(seedRow(env.db, { key: 'k4', created: ago(1) })), { decision: 'approved', result_ref: 12 }, HUMAN_H);
  assert.equal(badRef.status, 400);
});

// --- A5: knobs ------------------------------------------------------------------------

test('A5 the schema seeds each knob row with its code fallback value', async (t) => {
  const env = await open(t); if (!env) return;
  const seeds = Object.fromEntries(env.db.prepare(
    "SELECT key, value FROM settings WHERE key LIKE 'owner_approvals.%' OR key='retention.owner_approvals.days'",
  ).all().map((r) => [r.key, r.value]));
  assert.deepEqual(seeds, {
    'owner_approvals.pending_ttl_h': '72',
    'owner_approvals.list_limit': '50',
    'owner_approvals.payload_max_bytes': '4096',
    'retention.owner_approvals.days': '90',
  });
});

test('A5 with no settings rows the code fallbacks hold: TTL 72 h, limit 50 + truncated, 4096 bytes', async (t) => {
  const env = await open(t); if (!env) return;
  dropKnobs(env.db);
  seedRow(env.db, { key: 'k-71h', created: ago(71) });
  seedRow(env.db, { key: 'k-73h', created: ago(73) });
  const g = await get(env.DB);
  assert.deepEqual(g.body.approvals.map((x) => x.dedupe_key), ['k-71h']);
  env.db.prepare('DELETE FROM owner_approvals').run();
  for (let i = 0; i < 51; i++) seedRow(env.db, { key: `n${i}`, created: ago(1 + i / 100) });
  const l = await get(env.DB);
  assert.equal(l.body.approvals.length, 50);
  assert.equal(l.body.truncated, true);
  const big = { ...QUOTE_BODY, dedupe_key: 'big', payload: { ...QUOTE_BODY.payload, reason: 'r'.repeat(4100) } };
  assert.equal((await file(env.DB, big)).status, 400);
  const fits = { ...QUOTE_BODY, dedupe_key: 'fits', payload: { ...QUOTE_BODY.payload, reason: 'r'.repeat(3000) } };
  assert.equal((await file(env.DB, fits)).status, 201);
});

test('A5 a settings row wins over the fallback: TTL and payload size', async (t) => {
  const env = await open(t); if (!env) return;
  setKnob(env.db, 'owner_approvals.pending_ttl_h', '2');
  seedRow(env.db, { key: 'k-3h', created: ago(3) });
  assert.deepEqual((await get(env.DB)).body.approvals, []);
  setKnob(env.db, 'owner_approvals.payload_max_bytes', '100');
  assert.equal((await file(env.DB, QUOTE_BODY)).status, 400);
});

// --- A6: box-commands refusal body -------------------------------------------------------

const ORGO = { box: 'hub', type: 'orgo_restart', target: 'project-3', reason: 'hung', confirm: true, actor: OWNER };

test('A6 enforce: the box-commands owner refusal carries proof:"required"; error stays owner_only', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('owner_proof_mode','enforce','t','t','t')").run();
  const r = await send(env.DB, '/api/box-commands', ORGO);
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.equal(r.body.error, 'owner_only');
  assert.equal(r.body.proof, 'required');
});

test('A6 shadow: a non-owner refusal has no proof field', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await send(env.DB, '/api/box-commands', { ...ORGO, actor: 'someone@example.net' });
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.equal(r.body.error, 'owner_only');
  assert.equal('proof' in r.body, false);
});

// --- A7: EXPLAIN at volume ---------------------------------------------------------------

test('A7 EXPLAIN on 5,000 rows: the pending list, the dedupe re-read and the retention ids each use their index', async (t) => {
  const env = await open(t); if (!env) return;
  const ins = env.db.prepare(
    "INSERT INTO owner_approvals (kind, dedupe_key, payload, actor, via, status, created_at) VALUES (?,?,'{}','a','v',?,?)",
  );
  env.db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    ins.run(i % 2 ? 'box_command' : 'archie_delegation', `k${i}`, i % 7 ? 'approved' : 'pending', ago(i / 10));
  }
  env.db.exec('COMMIT');
  env.db.exec('ANALYZE');
  const { SQL } = await import('../src/routes/owner-approvals.js');
  const plan = (sql, ...b) => env.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail).join(' | ');
  const pend = plan(SQL.listPending, ago(72), 51);
  assert.match(pend, /USING (COVERING )?INDEX owner_approvals_status_created/, pend);
  assert.doesNotMatch(pend, /SCAN owner_approvals\b(?!.*INDEX)/, pend);
  assert.doesNotMatch(pend, /TEMP B-TREE/, pend);
  const key = plan(SQL.byKey, 'box_command', 'k1');
  assert.match(key, /USING (COVERING )?INDEX owner_approvals_key/, key);
  const rule = RULES.find((r) => r.rule === 'owner_approvals.age');
  assert.ok(rule, 'no owner_approvals.age retention rule');
  const ids = plan(rule.ids, ago(24 * 90), 500);
  assert.match(ids, /USING (COVERING )?INDEX owner_approvals_created/, ids);
  assert.doesNotMatch(ids, /TEMP B-TREE/, ids);
  const del = plan(rule.del, '[1,2]');
  assert.doesNotMatch(del, /SCAN owner_approvals\b/, del);
});

// --- A8: retention --------------------------------------------------------------------------

test('A8 retention: a real run deletes a row older than 90 days and keeps a recent one; dry run deletes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  seedRow(env.db, { key: 'ancient', status: 'approved', created: ago(24 * 100) });
  seedRow(env.db, { key: 'recent', created: ago(1) });
  const run = () => send(env.DB, '/api/retention/run', {});
  const dry = await run();
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(rows(env.db).length, 2, 'the seeded retention.dry_run=1 deletes nothing');
  env.db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const real = await run();
  assert.equal(real.status, 200, JSON.stringify(real.body));
  assert.deepEqual(rows(env.db).map((r) => r.dedupe_key), ['recent']);
  const audit = env.db.prepare("SELECT count(*) AS n FROM retention_runs WHERE rule='owner_approvals.age'").get().n;
  assert.ok(audit >= 1, 'one retention_runs row per run');
});
