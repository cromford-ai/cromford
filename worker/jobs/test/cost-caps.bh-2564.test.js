import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { clearCapSeeds } from './lib/d1-sqlite.bh-1030.js';
import { CAP_KEY_PREFIX_RE, capFleetKey, validateCapValue } from '../src/lib/cost-caps.js';
import { seedRegistryPlan } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2564 (BH-2511 W1-W3): the worker half of the cost-caps editor.
// K/V pin the key shapes and the value grammar the shell readers
// (_cb_row_ok / _lc_row_ok) bind; every other case drives worker.fetch, the
// real route table, over schema.sql applied to an in-memory sqlite.

const SECRET = 'test-secret';
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
    // All or nothing, like D1's batch: a throw mid-batch rolls every statement back.
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
  clearCapSeeds(db); // BH-4155: start from a table with no cap row
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body, { bearer = true } = {}) {
  const headers = {};
  if (bearer) headers.authorization = 'Bearer ' + SECRET;
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const nSettings = (db) => db.prepare('SELECT count(*) AS n FROM settings').get().n;
const nAudit = (db) => db.prepare('SELECT count(*) AS n FROM cost_cap_changes').get().n;
const audit = (db) => db.prepare('SELECT key, before_value, after_value, actor, reason FROM cost_cap_changes ORDER BY id').all()
  .map((r) => ({ ...r }));
const setting = (db, k) => { const r = db.prepare('SELECT * FROM settings WHERE key=?').get(k); return r ? { ...r } : null; };
const put = (db, key, value, actor) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?,?,NULL,?,'2026-01-01T00:00:00Z')").run(key, value, actor);

// ── K: key shapes ───────────────────────────────────────────────────────────
test('K1: the six fleet key shapes', () => {
  assert.deepEqual(capFleetKey('conf.cost-caps.budget.project-5'), { file: 'cost-caps', kind: 'budget', subject: 'project-5' });
  assert.deepEqual(capFleetKey('conf.cost-caps.default'), { file: 'cost-caps', kind: 'default', subject: null });
  assert.deepEqual(capFleetKey('conf.cost-caps.ceiling'), { file: 'cost-caps', kind: 'ceiling', subject: null });
  assert.deepEqual(capFleetKey('conf.lane-caps.lane.medic'), { file: 'lane-caps', kind: 'lane', subject: 'medic' });
  assert.deepEqual(capFleetKey('conf.lane-caps.noise.alert-triage'), { file: 'lane-caps', kind: 'noise', subject: 'alert-triage' });
  assert.deepEqual(capFleetKey('conf.lane-caps.noise.default'), { file: 'lane-caps', kind: 'noise', subject: 'default' });
  assert.deepEqual(capFleetKey('conf.lane-caps.default'), { file: 'lane-caps', kind: 'default', subject: null });
});

test('K2: adversarial keys are not fleet cap keys', () => {
  for (const k of [
    'lane.pipeline-health.cost_autohalt', 'conf.cost-capsx.ceiling', 'conf.cost-caps', 'conf.cost-caps.budget.',
    'conf.cost-caps.budget.acme.hub-1', 'conf.cost-caps.default.hub-1', 'conf.lane-caps.lane.medic.extra.x',
    'conf.cost-caps.Budget.x', 'conf.cost-caps.budget.X', 'conf.lane-caps.ceiling', 'conf.cost-caps.lane.x',
    'conf.lane-caps.budget.x', ' conf.cost-caps.ceiling', '', null, undefined, 5,
  ]) assert.equal(capFleetKey(k), null, String(k));
});

test('K3: a 65-char key is refused; the prefix regex takes box keys but not a lookalike file', () => {
  const k64 = 'conf.cost-caps.budget.' + 'a'.repeat(64 - 'conf.cost-caps.budget.'.length);
  assert.equal(k64.length, 64);
  assert.ok(capFleetKey(k64));
  assert.equal(capFleetKey(k64 + 'a'), null);
  assert.ok(CAP_KEY_PREFIX_RE.test('conf.cost-caps.budget.acme.hub-1'));
  assert.ok(CAP_KEY_PREFIX_RE.test('conf.lane-caps.default'));
  assert.ok(!CAP_KEY_PREFIX_RE.test('conf.cost-capsx.ceiling'));
  assert.ok(!CAP_KEY_PREFIX_RE.test('conf.readiness-levels'));
});

// ── V: value grammar ────────────────────────────────────────────────────────
const cap = (k) => capFleetKey(k);
const ok = (k, v) => assert.equal(validateCapValue(cap(k), v), null, `${k} = ${JSON.stringify(v)} should pass`);
const no = (k, v) => assert.equal(typeof validateCapValue(cap(k), v), 'string', `${k} = ${JSON.stringify(v)} should fail`);

test('V1: cost-caps grammar mirrors _cb_row_ok', () => {
  for (const k of ['conf.cost-caps.budget.project-5', 'conf.cost-caps.default']) {
    for (const v of ['100 5', '3000', '1.2.3', ' 100  5 ', '0.5', '.5']) ok(k, v);
    for (const v of ['abc', '-5', '0', '0 5', '5 0', 'off', '1e3', '85 10 3', '100\t5', '100\n5', '100\r', '', '   ', '.', '5 abc']) no(k, v);
  }
  ok('conf.cost-caps.ceiling', '3000');
  for (const v of ['abc', '-5', '0', '5 5', 'off', '']) no('conf.cost-caps.ceiling', v);
  for (const v of [5, null, undefined, {}]) no('conf.cost-caps.ceiling', v);
});

test('V2: lane-caps grammar mirrors _lc_row_ok', () => {
  for (const k of ['conf.lane-caps.lane.medic', 'conf.lane-caps.default']) {
    for (const v of ['off', '50', '90 40000', '0', '0.5', 'off 100', '1.2.3']) ok(k, v);
    for (const v of ['-3', '1.5 x', '.', '..', '90 0', '90 1.5', '90 -1', 'off 10 3', 'abc', '',
      '90 9223372036854775808']) no(k, v);
  }
  ok('conf.lane-caps.lane.medic', '90 9223372036854775807');
  for (const v of ['4', 'off', '0']) ok('conf.lane-caps.noise.medic', v);
  for (const v of ['1.5', '4 4', '-1', 'abc', '', '.']) no('conf.lane-caps.noise.medic', v);
});

test('V3: `off` is a lane default and never a cost default', () => {
  ok('conf.lane-caps.default', 'off');
  no('conf.cost-caps.default', 'off');
  ok('conf.lane-caps.default', '0');
  no('conf.cost-caps.default', '0');
});

// ── P: PUT /api/cost-caps ───────────────────────────────────────────────────
const K = 'conf.cost-caps.budget.project-5';

test('P1/P2/P8: a change writes the row and one audit row; an unchanged value writes neither', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/cost-caps', { key: K, value: '250 3', reason: 'r', actor: 'console' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.unchanged, false);
  assert.equal(r.body.setting.value, '250 3');
  const row = setting(db, K);
  assert.equal(row.value, '250 3');
  assert.equal(row.actor, 'console');
  assert.equal(row.note, 'r');
  assert.deepEqual(audit(db), [{ key: K, before_value: null, after_value: '250 3', actor: 'console', reason: 'r' }]);

  const again = await call(env, 'PUT', '/api/cost-caps', { key: K, value: ' 250 3 ', reason: 'again', actor: 'console' });
  assert.equal(again.status, 200);
  assert.equal(again.body.unchanged, true);
  assert.equal(again.body.setting.value, '250 3');
  assert.equal(nAudit(db), 1);
  assert.equal(setting(db, K).note, 'r');

  const moved = await call(env, 'PUT', '/api/cost-caps', { key: K, value: '300 3', reason: 'bump', actor: 'operator' });
  assert.equal(moved.status, 200);
  assert.equal(moved.body.unchanged, false);
  assert.deepEqual(audit(db)[1], { key: K, before_value: '250 3', after_value: '300 3', actor: 'operator', reason: 'bump' });
  assert.equal(setting(db, K).actor, 'operator');
});

test('P1b: no actor defaults to api', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/cost-caps', { key: 'conf.lane-caps.noise.medic', value: 'off', reason: 'quiet' });
  assert.equal(r.status, 200);
  assert.equal(audit(db)[0].actor, 'api');
});

test('P3-P7: every refusal is a 400 that writes nothing', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  put(db, K, '100 5', 'console');
  const n0 = nSettings(db);
  const bad = [
    ['P3 blank reason', { key: K, value: '250 3', reason: '   ' }],
    ['P3 missing reason', { key: K, value: '250 3' }],
    ['P3 non-string reason', { key: K, value: '250 3', reason: 5 }],
    ['P4 non-cap key', { key: 'lane.x.y', value: '5', reason: 'r' }],
    ['P5 box key', { key: 'conf.cost-caps.budget.acme.hub-1', value: '1 1', reason: 'r' }],
    ['P6 negative', { key: K, value: '-5', reason: 'r' }],
    ['P6 three fields', { key: K, value: '85 10 3', reason: 'r' }],
    ['P6 number', { key: K, value: 250, reason: 'r' }],
    ['P7 seed actor', { key: K, value: '250 3', reason: 'r', actor: 'registry-seed' }],
  ];
  for (const [name, body] of bad) {
    const r = await call(env, 'PUT', '/api/cost-caps', body);
    assert.equal(r.status, 400, name + ' ' + JSON.stringify(r.body));
    assert.equal(typeof r.body.error, 'string', name);
    assert.equal(nSettings(db), n0, name);
    assert.equal(setting(db, K).value, '100 5', name);
    assert.equal(nAudit(db), 0, name);
  }
});

test('P9: behind the bearer', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const n0 = nSettings(db);
  const r = await call(env, 'PUT', '/api/cost-caps', { key: K, value: '250 3', reason: 'r' }, { bearer: false });
  assert.equal(r.status, 401);
  assert.equal(nSettings(db), n0);
  assert.equal(setting(db, K), null);
});

// ── G: GET /api/cost-cap-changes ────────────────────────────────────────────
async function threeChanges(env) {
  for (const v of ['1 1', '2 2']) {
    const r = await call(env, 'PUT', '/api/cost-caps', { key: K, value: v, reason: 'r' + v });
    assert.equal(r.status, 200);
  }
  const r = await call(env, 'PUT', '/api/cost-caps', { key: 'conf.cost-caps.ceiling', value: '3000', reason: 'c' });
  assert.equal(r.status, 200);
}

test('G1/G2: newest first, and ?key= filters', { skip: NO_DB }, async () => {
  const { env } = fresh();
  await threeChanges(env);
  const all = await call(env, 'GET', '/api/cost-cap-changes');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.changes.map((c) => c.after_value), ['3000', '2 2', '1 1']);
  assert.equal(all.body.truncated, false);
  assert.ok(all.body.as_of);
  const one = await call(env, 'GET', '/api/cost-cap-changes?key=' + K);
  assert.deepEqual(one.body.changes.map((c) => [c.key, c.before_value, c.after_value]), [[K, '1 1', '2 2'], [K, null, '1 1']]);
  const box = await call(env, 'GET', '/api/cost-cap-changes?key=conf.cost-caps.budget.acme.hub-1');
  assert.equal(box.status, 200);
  assert.deepEqual(box.body.changes, []);
  for (const k of ['lane.x.y', 'conf.cost-capsx.ceiling', 'CONF.cost-caps.ceiling']) {
    const r = await call(env, 'GET', '/api/cost-cap-changes?key=' + encodeURIComponent(k));
    assert.equal(r.status, 400, k);
  }
});

test('G3: limit clamps to 1..500, default 100, truncated says when it bit', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  await threeChanges(env);
  const two = await call(env, 'GET', '/api/cost-cap-changes?limit=2');
  assert.equal(two.body.changes.length, 2);
  assert.equal(two.body.truncated, true);
  // The routing-changes formula (Number(q) || 100): 0 reads as absent, a
  // negative clamps to 1.
  const zero = await call(env, 'GET', '/api/cost-cap-changes?limit=0');
  assert.equal(zero.body.changes.length, 3);
  assert.equal(zero.body.truncated, false);
  const neg = await call(env, 'GET', '/api/cost-cap-changes?limit=-5');
  assert.equal(neg.body.changes.length, 1);
  assert.equal(neg.body.truncated, true);
  const ins = db.prepare("INSERT INTO cost_cap_changes (key, before_value, after_value, actor, reason, at) VALUES (?,NULL,'1','t','r','2026-01-01')");
  for (let i = 0; i < 600; i++) ins.run(K);
  const huge = await call(env, 'GET', '/api/cost-cap-changes?limit=9999');
  assert.equal(huge.body.changes.length, 500);
  assert.equal(huge.body.truncated, true);
  const dflt = await call(env, 'GET', '/api/cost-cap-changes');
  assert.equal(dflt.body.changes.length, 100);
  assert.equal(dflt.body.truncated, true);
});

test('G4: an empty table is an honest empty list', { skip: NO_DB }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', '/api/cost-cap-changes');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.changes, []);
  assert.equal(r.body.truncated, false);
});

// ── S: POST /api/cost-caps/seed ─────────────────────────────────────────────
const seed = (env, rows) => call(env, 'POST', '/api/cost-caps/seed', rows === undefined ? {} : { rows });

test('S1/S2: seed inserts under registry-seed, follows a moved value, and is not audited', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const rows = [{ key: 'conf.cost-caps.default', value: '100 5' }, { key: 'conf.lane-caps.lane.medic', value: '90 40000' }];
  const r = await seed(env, rows);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rows, 2);
  assert.deepEqual(r.body.changed_keys, ['conf.cost-caps.default', 'conf.lane-caps.lane.medic']);
  assert.equal(r.body.changed, 2);
  assert.deepEqual(r.body.pruned_keys, []);
  assert.equal(r.body.actor, 'registry-seed');
  assert.equal(setting(db, 'conf.cost-caps.default').actor, 'registry-seed');
  assert.equal(setting(db, 'conf.lane-caps.lane.medic').value, '90 40000');
  assert.equal(nAudit(db), 0);

  const same = await seed(env, rows);
  assert.deepEqual(same.body.changed_keys, []);
  const moved = await seed(env, [rows[0], { key: 'conf.lane-caps.lane.medic', value: '80' }]);
  assert.deepEqual(moved.body.changed_keys, ['conf.lane-caps.lane.medic']);
  assert.equal(setting(db, 'conf.lane-caps.lane.medic').value, '80');
  assert.equal(nAudit(db), 0);
});

test('S3: an operator row is never touched by the seed', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  put(db, 'conf.cost-caps.ceiling', '5000', 'console');
  const r = await seed(env, [{ key: 'conf.cost-caps.ceiling', value: '3000' }]);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.changed_keys, []);
  assert.equal(setting(db, 'conf.cost-caps.ceiling').value, '5000');
  assert.equal(setting(db, 'conf.cost-caps.ceiling').actor, 'console');
});

test('S4: the seed prunes only its own orphans under the two cap prefixes', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  put(db, 'conf.lane-caps.lane.old', '5', 'registry-seed');
  put(db, 'conf.lane-caps.lane.mine', '5', 'console');
  put(db, 'lane.x.y', '5', 'registry-seed');
  put(db, 'conf.readiness-levels', '{}', 'registry-seed');
  const r = await seed(env, [{ key: 'conf.cost-caps.default', value: '100 5' }]);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.pruned_keys, ['conf.lane-caps.lane.old']);
  assert.equal(r.body.pruned, 1);
  assert.equal(setting(db, 'conf.lane-caps.lane.old'), null);
  assert.ok(setting(db, 'conf.lane-caps.lane.mine'));
  assert.ok(setting(db, 'lane.x.y'));
  assert.ok(setting(db, 'conf.readiness-levels'));
});

test('S5-S7: a bad request writes and prunes nothing', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  put(db, 'conf.lane-caps.lane.old', '5', 'registry-seed');
  const n0 = nSettings(db);
  const good = [{ key: 'conf.cost-caps.default', value: '100 5' }, { key: 'conf.lane-caps.lane.medic', value: '90' }];
  const cases = [
    ['S5 empty', []],
    ['S5 string', 'x'],
    ['S5 missing', undefined],
    ['S5 too many', Array.from({ length: 201 }, (_, i) => ({ key: `conf.lane-caps.lane.l${i}`, value: '1' }))],
    ['S6 bad value', [...good, { key: 'conf.cost-caps.ceiling', value: '0' }]],
    ['S6 bad key', [...good, { key: 'lane.x.y', value: '1' }]],
    ['S6 box key', [...good, { key: 'conf.cost-caps.default.hub-1', value: '1' }]],
    ['S6 non-object', [...good, 'conf.cost-caps.ceiling=1']],
    ['S7 duplicate', [...good, { key: 'conf.cost-caps.default', value: '200 5' }]],
    ['S7 duplicate after trim', [...good, { key: ' conf.cost-caps.default ', value: '200 5' }]],
  ];
  for (const [name, rows] of cases) {
    const r = await seed(env, rows);
    assert.equal(r.status, 400, name + ' ' + JSON.stringify(r.body));
    assert.equal(nSettings(db), n0, name);
    assert.equal(setting(db, 'conf.cost-caps.default'), null, name);
    assert.ok(setting(db, 'conf.lane-caps.lane.old'), name + ': the orphan was pruned');
  }
  const r = await seed(env, [...good, { key: 'conf.cost-caps.ceiling', value: '0' }]);
  assert.match(r.body.error, /rows\[2\]/);
});

// ── A: the generic PUT /api/settings audits cap keys ────────────────────────
const sput = (env, body) => call(env, 'PUT', '/api/settings', body);

test('A1: generic PUT on a cap key audits a change, not a repeat', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  let r = await sput(env, { key: 'conf.cost-caps.ceiling', value: '3000', note: 'n', actor: 'console' });
  assert.equal(r.status, 200);
  assert.deepEqual(audit(db), [{ key: 'conf.cost-caps.ceiling', before_value: null, after_value: '3000', actor: 'console', reason: 'n' }]);
  r = await sput(env, { key: 'conf.cost-caps.ceiling', value: 3000 });
  assert.equal(r.status, 200);
  assert.equal(nAudit(db), 1);
  r = await sput(env, { key: 'conf.cost-caps.ceiling', value: '4000', reason: 'rr', note: 'n2' });
  assert.equal(r.status, 200);
  assert.deepEqual(audit(db)[1], { key: 'conf.cost-caps.ceiling', before_value: '3000', after_value: '4000', actor: 'api', reason: 'rr' });
  r = await sput(env, { key: 'conf.cost-caps.ceiling', value: '5000' });
  assert.equal(audit(db)[2].reason, null);
});

test('A2: generic PUT on a non-cap key writes no audit row', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const r = await sput(env, { key: 'lane.x.y', value: '5' });
  assert.equal(r.status, 200);
  assert.equal(setting(db, 'lane.x.y').value, '5');
  assert.equal(nAudit(db), 0);
});

test('A3: a box cap key stays writable on the generic PUT and is audited', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const r = await sput(env, { key: 'conf.cost-caps.budget.acme.hub-1', value: '1 1' });
  assert.equal(r.status, 200);
  assert.equal(setting(db, 'conf.cost-caps.budget.acme.hub-1').value, '1 1');
  assert.equal(nAudit(db), 1);
});

test('A4: the seed actor is still refused on the generic PUT, with no audit row', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  const n0 = nSettings(db);
  const r = await sput(env, { key: 'conf.cost-caps.ceiling', value: '3000', actor: 'registry-seed' });
  assert.equal(r.status, 400);
  assert.equal(nSettings(db), n0);
  assert.equal(setting(db, 'conf.cost-caps.ceiling'), null);
  assert.equal(nAudit(db), 0);
});

// ── R: the registry seed leaves conf.* rows alone ───────────────────────────
test('R1: POST /api/settings/seed-registry keeps a seed-owned conf row and still prunes a stale lane row', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  put(db, 'conf.cost-caps.default', '100 5', 'registry-seed');
  put(db, 'lane.nope.gone', '1', 'registry-seed');
  const r = await call(env, 'POST', '/api/settings/seed-registry');
  assert.equal(r.status, 200);
  assert.ok(r.body.pruned_keys.includes('lane.nope.gone'));
  assert.ok(!r.body.pruned_keys.includes('conf.cost-caps.default'));
  assert.equal(setting(db, 'conf.cost-caps.default').value, '100 5');
  assert.equal(setting(db, 'lane.nope.gone'), null);
});

test('R2: seedRegistryPlan agrees', () => {
  const plan = seedRegistryPlan([], [
    { key: 'conf.cost-caps.default', actor: 'registry-seed', value: '1' },
    { key: 'lane.nope.gone', actor: 'registry-seed', value: '1' },
  ]);
  assert.deepEqual(plan.prune, ['lane.nope.gone']);
});

test('R3: GET /api/settings/seed-registry/plan omits the conf key from prune', { skip: NO_DB }, async () => {
  const { db, env } = fresh();
  put(db, 'conf.cost-caps.default', '100 5', 'registry-seed');
  put(db, 'lane.nope.gone', '1', 'registry-seed');
  const r = await call(env, 'GET', '/api/settings/seed-registry/plan');
  assert.equal(r.status, 200);
  assert.ok(r.body.prune.includes('lane.nope.gone'));
  assert.ok(!r.body.prune.includes('conf.cost-caps.default'));
});
