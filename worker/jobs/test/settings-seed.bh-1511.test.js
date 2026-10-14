import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { call } from './lib/harness.js';
import { clearCapSeeds } from './lib/d1-sqlite.bh-1030.js';
import {
  LANES_REGISTRY, PRUNE_SEED_SQL, REGISTRY_SEED_ACTOR, SEED_REGISTRY_SQL, registrySeedRows, unsettableKnob,
} from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// POST /api/settings/seed-registry — BH-1511.1's seed: every registered knob
// with a static default gets a settings row, so the table is the complete
// record an operator reads and edits in the console.
//
// THE TWO PROMISES, proven on real SQLite (node:sqlite, the same engine D1 is):
//   - IDEMPOTENT: a second seed writes nothing;
//   - NEVER OVERWRITES AN OPERATOR: a row any other actor wrote is left alone,
//     while a row the seed itself owns follows the registry when its default
//     moves (the table mirrors the code; it does not pin last month's default).
// The rows it writes carry actor `registry-seed`, which bin/lib/lane-gate.sh
// ranks BELOW the env and the registry, so seeding changes no running lane
// (tests/settings-contract.bh-1511-test.sh section 5).

const FIX = {
  lanes: [
    { id: 'demo', knobs: [
      { env: 'DEMO_N', type: 'int', default: 5 },
      { env: 'DEMO_S', type: 'string', default: 'a b' },
      { env: 'DEMO_EMPTY', type: 'string', default: '' },
      { env: 'DEMO_NULL', type: 'int', default: null },
      { env: 'DEMO_CMD', type: 'string', default: 'ssh -x', settable: false },
      { resolver: 'demo_resolver', default: 3 },
    ] },
  ],
  libs: [
    { id: 'demo-lib', file: 'bin/lib/demo-lib.sh', knobs: [
      { env: 'DEMO_LIB_S', type: 'int', default: 900 },
      { env: 'DEMO_LIB_CMD', type: 'string', default: 'rm -rf x', settable: false },
    ] },
  ],
};

test('registrySeedRows: settable knobs with a static default, keyed lane./lib., values as text', () => {
  const rows = registrySeedRows(FIX);
  assert.deepEqual(rows.map((r) => [r.key, r.value]), [
    ['lane.demo.demo_n', '5'],
    ['lane.demo.demo_s', 'a b'],
    ['lib.demo-lib.demo_lib_s', '900'],
  ]);
  for (const r of rows) {
    assert.equal(typeof r.value, 'string', 'value is TEXT: the consumer parses it');
    assert.ok(r.note && r.note.length <= 512);
  }
  // The shipped registry seeds, and seeds nothing the PUT route would refuse.
  const real = registrySeedRows(LANES_REGISTRY);
  assert.ok(real.length > 100, `the shipped registry seeded only ${real.length} rows`);
  assert.ok(real.some((r) => r.key === 'lib.wake-lanes.wake_backstop_s' && r.value === '1800'),
    'the libs scope (catalog/lanes.d/_lib.json) was not seeded');
  for (const r of real) {
    assert.match(r.key, /^[a-z0-9_.-]{1,64}$/);
    assert.equal(unsettableKnob(r.key), null, `${r.key} is settable:false and must never be seeded`);
    assert.ok(r.value.length > 0 && r.value.length <= 256);
  }
});

test('unsettableKnob refuses a settable:false knob in the libs scope too', () => {
  // PUT /api/settings is the last of the refusals for a command/host/path a
  // root lane runs; a lib knob must get the same one, keyed lib.<id>.<env>.
  assert.equal(unsettableKnob('lib.demo-lib.demo_lib_cmd', FIX), 'DEMO_LIB_CMD');
  assert.equal(unsettableKnob('lib.demo-lib.demo_lib_cmd.unlimited', FIX), 'DEMO_LIB_CMD');
  assert.equal(unsettableKnob('lib.demo-lib.demo_lib_s', FIX), null);
  assert.equal(unsettableKnob('lane.demo.demo_cmd', FIX), 'DEMO_CMD');
  // A lane key never matches a lib of the same id, and the reverse.
  assert.equal(unsettableKnob('lane.demo-lib.demo_lib_cmd', FIX), null);
  assert.ok((LANES_REGISTRY.libs || []).length > 0, 'the shipped registry carries no libs scope');
});

test('the seed SQL: idempotent, never overwrites an operator, follows the registry on its own rows', async (t) => {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite unavailable on this runtime'); return; }
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  const seed = (rows) => {
    let changed = 0;
    for (const r of rows) {
      changed += Number(db.prepare(SEED_REGISTRY_SQL).run(r.key, r.value, r.note, REGISTRY_SEED_ACTOR, 't1').changes);
    }
    return changed;
  };
  const get = (k) => db.prepare('SELECT value, actor FROM settings WHERE key=?').get(k);

  // An operator already set one of them.
  db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.demo.demo_n','9',NULL,'operator','t0')").run();
  const rows = registrySeedRows(FIX);
  assert.equal(seed(rows), 2, 'first seed must write exactly the two rows nobody had');
  assert.deepEqual({ ...get('lane.demo.demo_n') }, { value: '9', actor: 'operator' }, 'the seed overwrote an operator');
  assert.deepEqual({ ...get('lane.demo.demo_s') }, { value: 'a b', actor: REGISTRY_SEED_ACTOR });
  assert.equal(seed(rows), 0, 'a second seed must change nothing');

  // The registry default moves: the seed's OWN row follows, the operator's does not.
  const moved = registrySeedRows({ ...FIX, lanes: [{ id: 'demo', knobs: [
    { env: 'DEMO_N', type: 'int', default: 6 }, { env: 'DEMO_S', type: 'string', default: 'c' }] }] });
  assert.equal(seed(moved), 1);
  assert.equal(get('lane.demo.demo_s').value, 'c');
  assert.equal(get('lane.demo.demo_n').value, '9');
  db.close();
});

test('POST /api/settings/seed-registry batches one guarded upsert per seed row, bearer required', async () => {
  const want = registrySeedRows(LANES_REGISTRY);
  const r = await call('/api/settings/seed-registry', { method: 'POST', body: {} });
  assert.equal(r.status, 200);
  assert.equal(r.body.rows, want.length);
  const stmts = r.db._batches.flat().filter((s) => /INSERT INTO settings/.test(s.sql));
  assert.equal(stmts.length, want.length, 'one upsert per seed row');
  for (const s of stmts) {
    assert.match(s.sql, /ON CONFLICT\(key\) DO UPDATE .* WHERE settings\.actor = \?4/,
      'the conflict clause must be guarded on the seed actor, or it overwrites operators');
    assert.equal(s.binds[3], REGISTRY_SEED_ACTOR);
  }
  const anon = await call('/api/settings/seed-registry', { method: 'POST', body: {}, secret: null });
  assert.equal(anon.status, 401);
});

// ── Review of #1547 (I1, M2, I2's reporting half) ────────────────────────────

test('the seed PRUNES its own orphans: a registry-seed row whose knob left the registry is deleted, nobody else\'s is', async (t) => {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite unavailable on this runtime'); return; }
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  clearCapSeeds(db); // BH-4155: the orphan count below is over every registry-seed row
  const ins = db.prepare('INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,NULL,?,\'t0\')');
  ins.run('lane.demo.demo_gone', '4', REGISTRY_SEED_ACTOR);     // knob renamed away: an orphan
  ins.run('lane.demo.demo_op', '9', 'operator');                    // an operator's row nobody seeds
  ins.run('lane.demo.demo_n', '5', REGISTRY_SEED_ACTOR);        // still registered
  const keep = new Set(registrySeedRows(FIX).map((r) => r.key));
  const orphans = db.prepare('SELECT key FROM settings WHERE actor=?').all(REGISTRY_SEED_ACTOR)
    .map((r) => r.key).filter((k) => !keep.has(k));
  assert.deepEqual(orphans, ['lane.demo.demo_gone']);
  for (const k of orphans) db.prepare(PRUNE_SEED_SQL).run(k, REGISTRY_SEED_ACTOR);
  // the guard is in the SQL, not only in the caller: a key an operator owns survives even if named
  db.prepare(PRUNE_SEED_SQL).run('lane.demo.demo_op', REGISTRY_SEED_ACTOR);
  const left = db.prepare("SELECT key, actor FROM settings WHERE key LIKE 'lane.demo.%' ORDER BY key").all().map((r) => `${r.key}:${r.actor}`);
  assert.deepEqual(left, ['lane.demo.demo_n:registry-seed', 'lane.demo.demo_op:operator']);
  db.close();
});

test('POST /api/settings/seed-registry deletes orphan seed rows and reports them', async () => {
  const state = { settings: [
    { key: 'lane.nope.gone_knob', value: '4', actor: REGISTRY_SEED_ACTOR },
    { key: 'lane.nope.operator_knob', value: '4', actor: 'operator' },
  ] };
  const r = await call('/api/settings/seed-registry', { method: 'POST', body: {}, state });
  assert.equal(r.status, 200);
  assert.equal(r.body.pruned, 1);
  const dels = r.db._batches.flat().filter((s) => /DELETE FROM settings/.test(s.sql));
  assert.deepEqual(dels.map((d) => d.binds), [['lane.nope.gone_knob', REGISTRY_SEED_ACTOR]]);
  assert.match(dels[0].sql, /WHERE key=\?1 AND actor=\?2/);
});

test('PUT /api/settings refuses the reserved actor registry-seed (M2)', async () => {
  // A write carrying it would rank below the env, vanish from /api/lanes/status
  // and be overwritten by the next seed — an operator value nobody can see.
  const r = await call('/api/settings', { method: 'PUT',
    body: { key: 'gh_budget_min_remaining', value: '5', actor: REGISTRY_SEED_ACTOR } });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /reserved/);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO settings/.test(c.sql)).length, 0);
});

test('POST /api/lanes/liveness records the box\'s harness_commit in box_status (I2), and only a real sha', async () => {
  const lane = LANES_REGISTRY.lanes[0].id;
  const ok = await call('/api/lanes/liveness', { method: 'POST',
    body: { lane, box: 'hub', outcome: 'ran', harness_commit: '4d74f5b4a1b2c3d4e5f60718293a4b5c6d7e8f90' } });
  assert.equal(ok.status, 200);
  const up = ok.db._calls.find((c) => /INSERT INTO box_status/.test(c.sql));
  assert.ok(up, 'no box_status upsert for a tick carrying harness_commit');
  assert.match(up.sql, /harness_commit/);
  assert.match(up.sql, /harness_reported_at/);
  assert.equal(up.binds[0], 'hub');
  assert.equal(up.binds[1], '4d74f5b4a1b2c3d4e5f60718293a4b5c6d7e8f90');
  // No commit, or not a sha: the tick still lands, box_status is not touched.
  for (const harness_commit of [undefined, 'main; DROP', 'zzzzzzz']) {
    const r = await call('/api/lanes/liveness', { method: 'POST', body: { lane, box: 'hub', outcome: 'ran', harness_commit } });
    assert.equal(r.status, 200);
    assert.equal(r.db._calls.filter((c) => /INSERT INTO box_status/.test(c.sql)).length, 0, `wrote box_status for ${harness_commit}`);
  }
});
