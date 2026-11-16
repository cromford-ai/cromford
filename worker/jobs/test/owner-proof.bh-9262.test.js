// BH-9262 (C0): owner commands and human-only staff decisions accept exactly
// two proofs, never the fleet bearer or a body actor alone:
//   - the Mac human token (x-human-verdict-token = HUMAN_VERDICT_TOKEN), or
//   - the Pages proof: x-box-ops-token = BOX_OPS_TOKEN (timing-safe) AND
//     x-box-ops-identity (the Access-verified email Pages stamps) in BOX_OPS_OWNERS.
// The gate reads the protected settings row owner_proof_mode: no row = shadow
// (the request goes through, one would-refuse warn line), `enforce` = 403, a
// read that throws = 503. OWNER_PROOF_ENFORCE=1 forces enforce.
//
// Everything below the decision table goes through the REAL worker.fetch on the
// REAL composed schema (node:sqlite D1 shim), a fresh in-memory DB per test.
//
//   P1  decision table (a)..(n) on ownerProof
//   P2  enforce: bearer + actor=<owner> is 403 on box-commands and the six staff/archie routes, rows unchanged
//   P3  enforce: the human token is 201/200 on each
//   P4  enforce: the Pages proof (headers from console-ui boxOpsHeaders) is 201/200 on each
//   P5  enforce: the Pages token with no identity is 403 on each
//   P6  not-gated directions with the bearer only answer as before
//   P7  shadow: bearer + owner on box-commands is 201 with one would-refuse line; the archie.sh and box-request.sh bodies work
//   P8  the mode cases
//   P9  PUT /api/settings owner_proof_mode needs the human token
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { ownerProof, ownerProofMode } from '../src/lib/owner-proof.js';
import { boxOpsHeaders } from '../../../console-ui/functions/_lib/box-ops-proof.js';

const SECRET = 'test-secret-fixture-9262';
const LEAD = 'lead-token-fixture-9262';
const HUMAN = 'human-token-fixture-9262';
const BOX = 'box-ops-token-fixture-9262';
const OWNER = 'operator@example.com';
const SIG = 'sig-key-fixture-9262';
const ENV = {
  HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN,
  BOX_OPS_TOKEN: BOX, BOX_OPS_OWNERS: OWNER, HUMAN_VERDICT_SIG_KEY: SIG,
};
const FP = 'ab'.repeat(32);

async function open(t) {
  const env = await openDb();
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return env;
}
const setMode = (db, v) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('owner_proof_mode',?,'t','t','t') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(v);

const BEARER = {};
const HUMAN_H = { 'x-human-verdict-token': HUMAN };
const PAGES_H = boxOpsHeaders({ access: 'on', email: OWNER, actor: OWNER }, { BOX_OPS_TOKEN: BOX });
const PAGES_NO_ID = { 'x-box-ops-token': BOX };

async function send(DB, path, body, { headers = {}, env = {}, method = 'POST' } = {}) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  }), { ...ENV, DB, ...env });
  return { status: res.status, body: await res.json().catch(() => null) };
}

// --- P1: the decision table --------------------------------------------------

const req = (h) => new Request('https://jobs.test/x', { headers: h });

test('P1 decision table (a)-(n): exactly two proofs are accepted', async () => {
  const ok = (h, env = ENV) => ownerProof(req(h), env);
  // accepted
  assert.deepEqual(await ok({ 'x-human-verdict-token': HUMAN }), { ok: true, via: 'human-token' }, '(a)');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX, 'x-box-ops-identity': OWNER }), { ok: true, via: 'box-ops', identity: OWNER }, '(b)');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX, 'x-box-ops-identity': '  the operator@example.com ' }), { ok: true, via: 'box-ops', identity: OWNER }, '(c)');
  // refused
  assert.deepEqual(await ok({}), { ok: false, why: 'none' }, '(d) bearer only');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX }), { ok: false, why: 'identity_missing' }, '(e)');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX, 'x-box-ops-identity': 'someone@example.net' }), { ok: false, why: 'not_owner' }, '(f)');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX.slice(0, -1) + 'X', 'x-box-ops-identity': OWNER }), { ok: false, why: 'box_ops_token' }, '(g) off by one');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX.slice(0, -1), 'x-box-ops-identity': OWNER }), { ok: false, why: 'box_ops_token' }, '(g) prefix');
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX + 'x', 'x-box-ops-identity': OWNER }), { ok: false, why: 'box_ops_token' }, '(g) longer');
  const unset = { ...ENV }; delete unset.BOX_OPS_TOKEN;
  assert.deepEqual(await ok({ 'x-box-ops-token': '', 'x-box-ops-identity': OWNER }, unset), { ok: false, why: 'box_ops_unset' }, '(h) unset, empty header');
  assert.deepEqual(await ok({ 'x-box-ops-token': '  ', 'x-box-ops-identity': OWNER }, { ...ENV, BOX_OPS_TOKEN: '  ' }), { ok: false, why: 'box_ops_unset' }, '(h) blank');
  assert.deepEqual(await ok({ 'x-box-ops-token': SECRET, 'x-box-ops-identity': OWNER }, { ...ENV, BOX_OPS_TOKEN: SECRET }), { ok: false, why: 'box_ops_unset' }, '(i) = HARNESS_SECRET');
  assert.deepEqual(await ok({ 'x-box-ops-token': HUMAN, 'x-box-ops-identity': OWNER }, { ...ENV, BOX_OPS_TOKEN: HUMAN }), { ok: false, why: 'box_ops_unset' }, '(j) = HUMAN_VERDICT_TOKEN');
  assert.deepEqual(await ok({ 'x-box-ops-token': LEAD, 'x-box-ops-identity': OWNER }, { ...ENV, BOX_OPS_TOKEN: LEAD }), { ok: false, why: 'box_ops_unset' }, '(i) = LEAD_VERDICT_TOKEN');
  for (const owners of [undefined, '', '  ', ' , ']) {
    const e = { ...ENV, BOX_OPS_OWNERS: owners };
    assert.deepEqual(await ok({ 'x-box-ops-token': BOX, 'x-box-ops-identity': OWNER }, e), { ok: false, why: 'not_owner' }, `(k) owners ${owners}`);
  }
  assert.deepEqual(await ok({ 'x-box-ops-token': BOX, 'x-box-ops-identity': `${OWNER},x@y` }), { ok: false, why: 'identity_missing' }, '(l) comma');
  assert.deepEqual(await ok({ 'x-human-verdict-token': LEAD }), { ok: false, why: 'none' }, '(m) lead value as human');
  assert.deepEqual(await ok({ 'x-human-verdict-token': BOX }), { ok: false, why: 'none' }, '(n) box token in the human header');
  // the human token is no proof when it equals the bearer (humanTokenOk rule)
  assert.equal((await ok({ 'x-human-verdict-token': SECRET }, { ...ENV, HUMAN_VERDICT_TOKEN: SECRET })).ok, false);
});

// --- the seven gated routes: one seed + one gated call + a read-back each -----

const ROUTES = [
  {
    name: 'box-commands orgo_restart',
    path: '/api/box-commands', created: 201, refusal: 'owner_only',
    seed() {},
    body: () => ({ box: 'hub', type: 'orgo_restart', target: 'project-3', reason: 'hung', confirm: true, actor: OWNER }),
    state: (db) => db.prepare('SELECT count(*) AS n FROM box_commands_v2').get().n,
  },
  {
    name: 'staff autonomy raise',
    path: '/api/staff/agents/autonomy', created: 200, refusal: 'human_proof_required',
    seed() {},
    body: () => ({ agent: 'watchman', autonomy: 'augmentation', actor: OWNER, reason: 'earned' }),
    state: (db) => db.prepare("SELECT autonomy FROM staff_agents WHERE name='watchman'").get().autonomy,
  },
  {
    name: 'staff delegation delegate',
    path: '/api/staff/classes/delegation', created: 200, refusal: 'human_proof_required',
    seed(db) {
      db.prepare("UPDATE staff_agents SET cap='autonomy' WHERE name='watchman'").run();
      db.prepare("INSERT INTO staff_classes (agent, class, cap, streak, never_delegable, updated_at) VALUES ('watchman','lint-fixes','autonomy',9,0,'t')").run();
    },
    body: () => ({ agent: 'watchman', class: 'lint-fixes', decision: 'delegate', actor: OWNER, reason: 'earned' }),
    state: (db) => db.prepare("SELECT state FROM staff_classes WHERE agent='watchman' AND class='lint-fixes'").get().state,
  },
  {
    name: 'staff promotion approve',
    path: '/api/staff/promotions/decide', created: 200, refusal: 'human_proof_required',
    seed(db) {
      db.prepare("INSERT INTO staff_promotions (id, agent, from_level, to_level, agreements, status, created_at) VALUES (77,'watchman','automation','augmentation',5,'pending','2026-11-01T00:00:00Z')").run();
    },
    body: () => ({ id: 77, decision: 'approve', reason: 'earned', actor: OWNER }),
    state: (db) => `${db.prepare('SELECT status FROM staff_promotions WHERE id=77').get().status}/${db.prepare("SELECT autonomy FROM staff_agents WHERE name='watchman'").get().autonomy}`,
  },
  {
    name: 'staff suppression decide approve',
    path: '/api/staff/suppressions/decide', created: 200, refusal: 'human_proof_required',
    seed(db) {
      db.prepare("INSERT INTO staff_suppressions (id, fingerprint, reason, approver, expires_at, status, created_at) VALUES (55,?,'noisy',NULL,'2026-12-01T00:00:00Z','pending','t')").run(FP);
    },
    body: () => ({ id: 55, decision: 'approve', approver: OWNER }),
    state: (db) => db.prepare('SELECT status FROM staff_suppressions WHERE id=55').get().status,
  },
  {
    name: 'staff suppression create',
    path: '/api/staff/suppressions', created: 200, refusal: 'human_proof_required',
    seed() {},
    body: () => ({ fingerprint: FP, reason: 'known noise', approver: OWNER, expiresAt: '2099-01-01T00:00:00Z' }),
    state: (db) => db.prepare('SELECT count(*) AS n FROM staff_suppressions').get().n,
  },
  {
    name: 'archie delegation delegate',
    path: '/api/archie/classes/delegation', created: 200, refusal: 'human_proof_required',
    seed(db) {
      db.prepare("INSERT INTO archie_classes (class, never_delegable, state, streak, updated_at) VALUES ('lint-fixes',0,'ask_first',9,'t')").run();
    },
    body: () => ({ class: 'lint-fixes', decision: 'delegate', min_streak: 5, actor: OWNER }),
    state: (db) => db.prepare("SELECT state FROM archie_classes WHERE class='lint-fixes'").get().state,
  },
];

for (const r of ROUTES) {
  test(`P2 enforce: bearer + actor=<owner> is 403 ${r.refusal} on ${r.name}, nothing written`, async (t) => {
    const env = await open(t); if (!env) return;
    r.seed(env.db); setMode(env.db, 'enforce');
    const before = r.state(env.db);
    const res = await send(env.DB, r.path, r.body(), { headers: BEARER });
    assert.equal(res.status, 403, JSON.stringify(res.body));
    assert.equal(res.body.error, r.refusal);
    assert.equal(r.state(env.db), before, 'the target row is unchanged');
    // a body field that looks like the proof is never read
    const forged = await send(env.DB, r.path, { ...r.body(), 'x-box-ops-identity': OWNER, 'x-box-ops-token': BOX });
    assert.equal(forged.status, 403);
    assert.equal(r.state(env.db), before);
  });

  test(`P3 enforce: the human token is ${r.created} on ${r.name}`, async (t) => {
    const env = await open(t); if (!env) return;
    r.seed(env.db); setMode(env.db, 'enforce');
    const before = r.state(env.db);
    const res = await send(env.DB, r.path, r.body(), { headers: HUMAN_H });
    assert.equal(res.status, r.created, JSON.stringify(res.body));
    assert.notEqual(r.state(env.db), before, 'the write landed');
  });

  test(`P4 enforce: the Pages proof (boxOpsHeaders) is ${r.created} on ${r.name}`, async (t) => {
    const env = await open(t); if (!env) return;
    r.seed(env.db); setMode(env.db, 'enforce');
    const before = r.state(env.db);
    const res = await send(env.DB, r.path, r.body(), { headers: PAGES_H });
    assert.equal(res.status, r.created, JSON.stringify(res.body));
    assert.notEqual(r.state(env.db), before, 'the write landed');
  });

  test(`P5 enforce: the Pages token with no Access identity is 403 on ${r.name}`, async (t) => {
    const env = await open(t); if (!env) return;
    r.seed(env.db); setMode(env.db, 'enforce');
    const before = r.state(env.db);
    const res = await send(env.DB, r.path, r.body(), { headers: PAGES_NO_ID });
    assert.equal(res.status, 403, JSON.stringify(res.body));
    assert.equal(r.state(env.db), before);
  });
}

test('P2b enforce: a box-commands refusal writes one refused:owner_proof audit row and no command row', async (t) => {
  const env = await open(t); if (!env) return;
  setMode(env.db, 'enforce');
  const res = await send(env.DB, '/api/box-commands', ROUTES[0].body());
  assert.equal(res.status, 403);
  assert.deepEqual(res.body, { error: 'owner_only' });
  const audit = env.db.prepare("SELECT * FROM hub_lease_changes WHERE action='box_command_refused'").all();
  assert.equal(audit.length, 1);
  assert.equal(audit[0].outcome, 'refused:owner_proof');
  assert.equal(env.db.prepare('SELECT count(*) AS n FROM box_commands_v2').get().n, 0);
});

test('P4b enforce: a Pages-proven box command records the proven identity as requested_by', async (t) => {
  const env = await open(t); if (!env) return;
  setMode(env.db, 'enforce');
  const res = await send(env.DB, '/api/box-commands', { ...ROUTES[0].body(), actor: 'console' }, { headers: PAGES_H });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.equal(res.body.command.requested_by, OWNER);
});

// --- P6: the directions that lower authority stay open to the bearer ----------

test('P6 enforce: not-gated directions answer as before with the bearer only', async (t) => {
  const env = await open(t); if (!env) return;
  const db = env.db; setMode(db, 'enforce');
  // autonomy lower and the same level
  db.prepare("UPDATE staff_agents SET autonomy='augmentation' WHERE name='watchman'").run();
  const lower = await send(env.DB, '/api/staff/agents/autonomy', { agent: 'watchman', autonomy: 'automation', actor: 'unblock-override', reason: 'noisy' });
  assert.equal(lower.status, 200, JSON.stringify(lower.body));
  const same = await send(env.DB, '/api/staff/agents/autonomy', { agent: 'watchman', autonomy: 'automation', actor: 'x', reason: 'again' });
  assert.equal(same.status, 200);
  // staff ask_first (bin/lib/unblock/override.sh)
  db.prepare("INSERT INTO staff_classes (agent, class, cap, streak, never_delegable, state, updated_at) VALUES ('watchman','lint-fixes','autonomy',9,0,'delegated','t')").run();
  const ask = await send(env.DB, '/api/staff/classes/delegation', { agent: 'watchman', class: 'lint-fixes', decision: 'ask_first', actor: 'unblock-override', reason: 'blocked' });
  assert.equal(ask.status, 200, JSON.stringify(ask.body));
  // archie ask_first
  db.prepare("INSERT INTO archie_classes (class, never_delegable, state, streak, updated_at) VALUES ('lint-fixes',0,'delegated',9,'t')").run();
  const aask = await send(env.DB, '/api/archie/classes/delegation', { class: 'lint-fixes', decision: 'ask_first', actor: 'chat' });
  assert.equal(aask.status, 200, JSON.stringify(aask.body));
  // promotion void
  db.prepare("INSERT INTO staff_promotions (id, agent, from_level, to_level, agreements, status, created_at) VALUES (78,'watchman','automation','augmentation',5,'pending','2026-11-01T00:00:00Z')").run();
  const v = await send(env.DB, '/api/staff/promotions/decide', { id: 78, decision: 'void', reason: 'no', actor: 'x' });
  assert.equal(v.status, 200, JSON.stringify(v.body));
  // suppression decline
  db.prepare("INSERT INTO staff_suppressions (id, fingerprint, reason, approver, expires_at, status, created_at) VALUES (56,?,'noisy',NULL,'2026-12-01T00:00:00Z','pending','t')").run(FP);
  const d = await send(env.DB, '/api/staff/suppressions/decide', { id: 56, decision: 'decline', approver: 'x' });
  assert.equal(d.status, 200, JSON.stringify(d.body));
  // a BH-2518 box type
  const b = await send(env.DB, '/api/box-commands', { box: 'hub', type: 'backup_now', reason: 'nightly', confirm: true, actor: 'console' });
  assert.equal(b.status, 201, JSON.stringify(b.body));
});

// --- P7: shadow keeps today's answers and logs one line ----------------------

test('P7 shadow (no row): bearer + owner on box-commands is 201 with exactly one would-refuse line', async (t) => {
  const env = await open(t); if (!env) return;
  const warn = t.mock.method(console, 'warn', () => {});
  const res = await send(env.DB, '/api/box-commands', ROUTES[0].body());
  assert.equal(res.status, 201, JSON.stringify(res.body));
  const lines = warn.mock.calls.map((c) => String(c.arguments[0])).filter((s) => s.startsWith('[owner-proof]'));
  assert.deepEqual(lines, ['[owner-proof] would-refuse route=/api/box-commands actor=operator@example.com why=none']);
  // shadow still refuses a non-owner actor, as today
  const not = await send(env.DB, '/api/box-commands', { ...ROUTES[0].body(), target: 'project-4', actor: 'someone@example.net' });
  assert.equal(not.status, 403);
  assert.deepEqual(not.body, { error: 'owner_only' });
});

test('P7 shadow: a proven request logs no would-refuse line', async (t) => {
  const env = await open(t); if (!env) return;
  const warn = t.mock.method(console, 'warn', () => {});
  const res = await send(env.DB, '/api/box-commands', ROUTES[0].body(), { headers: PAGES_H });
  assert.equal(res.status, 201);
  assert.equal(warn.mock.calls.filter((c) => String(c.arguments[0]).startsWith('[owner-proof]')).length, 0);
});

test('P7 shadow: the bin/archie.sh delegate body (bearer only, actor chat) is 200 and logs would-refuse', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.prepare("INSERT INTO archie_classes (class, never_delegable, state, streak, updated_at) VALUES ('lint-fixes',0,'ask_first',9,'t')").run();
  const warn = t.mock.method(console, 'warn', () => {});
  const res = await send(env.DB, '/api/archie/classes/delegation', { class: 'lint-fixes', decision: 'delegate', min_streak: 5, actor: 'chat' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(env.db.prepare("SELECT state FROM archie_classes WHERE class='lint-fixes'").get().state, 'delegated');
  const lines = warn.mock.calls.map((c) => String(c.arguments[0])).filter((s) => s.startsWith('[owner-proof]'));
  assert.deepEqual(lines, ['[owner-proof] would-refuse route=/api/archie/classes/delegation actor=chat why=none']);
});

test('P7 shadow: the bin/box-request.sh orgo_launch_quote body (bearer only) is 201', async (t) => {
  const env = await open(t); if (!env) return;
  t.mock.method(console, 'warn', () => {});
  const res = await send(env.DB, '/api/box-commands', {
    box: 'hub', type: 'orgo_launch_quote', target: 'newbox1', account: 'main', project: 'project-3',
    vcpus: 4, mem_gb: 16, disk_gb: 100, reason: 'more builders', actor: OWNER, confirm: true,
  });
  assert.equal(res.status, 201, JSON.stringify(res.body));
});

// --- P8: the mode ---------------------------------------------------------------

test('P8 mode: no row, shadow, enforce, the env floor, the near miss, a read that throws', async (t) => {
  const env = await open(t); if (!env) return;
  t.mock.method(console, 'warn', () => {});
  const E = (over = {}) => ({ ...ENV, DB: env.DB, ...over });
  assert.equal(await ownerProofMode(E()), 'shadow', 'no row');
  setMode(env.db, 'shadow');
  assert.equal(await ownerProofMode(E()), 'shadow');
  setMode(env.db, 'enforce');
  assert.equal(await ownerProofMode(E()), 'enforce');
  env.db.prepare("DELETE FROM settings WHERE key='owner_proof_mode'").run();
  assert.equal(await ownerProofMode(E({ OWNER_PROOF_ENFORCE: '1' })), 'enforce', 'the env floor');
  assert.equal(await ownerProofMode(E({ HUMAN_VERDICT_ENFORCE: '1' })), 'shadow', 'HUMAN_VERDICT_ENFORCE does not force it');
  const broken = { prepare() { throw new Error('D1_ERROR: overloaded'); } };
  assert.equal(await ownerProofMode(E({ DB: broken })), null);
});

test('P8 mode: a signed enforce overwritten by a direct D1 shadow still reads enforce', async (t) => {
  const env = await open(t); if (!env) return;
  t.mock.method(console, 'warn', () => {});
  const put = await send(env.DB, '/api/settings', { key: 'owner_proof_mode', value: 'enforce', note: 'flip' }, { method: 'PUT', headers: HUMAN_H });
  assert.equal(put.status, 200, JSON.stringify(put.body));
  setMode(env.db, 'shadow');
  assert.equal(await ownerProofMode({ ...ENV, DB: env.DB }), 'enforce');
  const res = await send(env.DB, '/api/box-commands', ROUTES[0].body());
  assert.equal(res.status, 403);
});

test('P8 mode: an unreadable mode is 503 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  t.mock.method(console, 'warn', () => {});
  // settings is the table the mode reads; renaming it makes that read throw
  // while every route table stays.
  env.db.exec('ALTER TABLE settings RENAME TO settings_gone');
  const sup = await send(env.DB, '/api/staff/suppressions', ROUTES[5].body());
  assert.equal(sup.status, 503, JSON.stringify(sup.body));
  assert.equal(env.db.prepare('SELECT count(*) AS n FROM staff_suppressions').get().n, 0);
  const box = await send(env.DB, '/api/box-commands', ROUTES[0].body());
  assert.equal(box.status, 503, JSON.stringify(box.body));
  assert.equal(env.db.prepare('SELECT count(*) AS n FROM box_commands_v2').get().n, 0);
});

// --- P9: the switch itself is protected -----------------------------------------

test('P9 PUT /api/settings owner_proof_mode: bearer only is 403, the human token is 200', async (t) => {
  const env = await open(t); if (!env) return;
  const bearer = await send(env.DB, '/api/settings', { key: 'owner_proof_mode', value: 'shadow', note: 'x' }, { method: 'PUT' });
  assert.equal(bearer.status, 403, JSON.stringify(bearer.body));
  const human = await send(env.DB, '/api/settings', { key: 'owner_proof_mode', value: 'shadow', note: 'x' }, { method: 'PUT', headers: HUMAN_H });
  assert.equal(human.status, 200, JSON.stringify(human.body));
});
