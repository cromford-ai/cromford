import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1908 — the model_routes seed matches the live hub ladders, so a fresh D1
// (a new box, a test fixture) runs the models the hub runs. One carve-out:
// alert.triage keeps Fable 5.1 at rung 0, the never-seen-family investigator
// (tests/triage-split-test.sh pins it; the operator on the ticket, 2026-09-24).
// Driven against THE SQL THAT SHIPS, through worker.fetch for the writes, the
// same idiom as model-routes.bh-1510.test.js and runner-routes.bh-1766.test.js.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// Copied from runner-routes.bh-1766.test.js (test files stay independent).
function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => { const s = bindAndRun(binds); s._sql = sql; s._binds = binds; return s; } };
  };
  return {
    prepare,
    batch: async (xs) => xs.map((x) => {
      const r = db.prepare(x._sql).run(...(x._binds || []));
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    }),
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const priceModel = (db, model) => db.prepare(
  `INSERT OR IGNORE INTO model_prices (model, slug, prompt, completion, source, updated_at)
   VALUES (?, ?, 1, 1, 'catalog', '2026-09-24T00:00:00Z')`
).run(model, `test/${model}`);

const put = (DB, role, ladder) => call(DB, '/api/model-routes', {
  method: 'PUT', body: { role, ladder, actor: 'op-test', reason: 'bh-1908 test' },
});

const ladder = (db, role) => db.prepare(
  'SELECT position, model, runner FROM model_routes WHERE role=? AND project IS NULL ORDER BY position'
).all(role).map((r) => `${r.position}:${r.model}:${r.runner}`);

// The live hub ladders: GET https://harness-jobs.operator.workers.dev/api/model-routes,
// as_of 2026-09-24T14:40:55Z, gaps [] (the build's re-probe of the plan's
// 14:37:37Z read; identical). stage.* are left out: box-written, not seeded
// from live (see the BH-1766 comment in schema.sql).
const LIVE = {
  'alert.triage': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'auth.fallback': ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude'],
  'bench': ['0:claude-opus-5-5:claude'],
  'build.execute': ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude'],
  'build.execute.fallback': ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude'],
  'build.fix': ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude'],
  'build.plan': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'build.qa': ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude'],
  'build.review': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'build.review.t0': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'claude.ladder': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude', '2:claude-opus-5:claude'],
  'codex.default': ['0:gpt-6-astra:codex'],
  'decompose': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'fireworks.default': ['0:accounts/fireworks/models/kimi-k2p7-code:fireworks'],
  'fireworks.floor': ['0:accounts/fireworks/models/deepseek-v4-flash-0731:fireworks'],
  'greenfield': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'greenfield.deck': ['0:claude-opus-5-5:claude'],
  'greenfield.ideate': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'greenfield.mockup': ['0:claude-opus-5-5:claude'],
  'greenfield.signals': ['0:claude-opus-5-5:claude'],
  'greenfield.synth': ['0:claude-sonnet-5:claude'],
  'grok.default': ['0:grok-4.7:grok', '1:grok-4.6:grok'],
  'housekeeping.floor': ['0:accounts/fireworks/models/deepseek-v4-flash-0731:fireworks', '1:claude-sonnet-5:claude'],
  'lander': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'openrouter.default': ['0:anthropic/claude-opus-5.5:openrouter', '1:anthropic/claude-fable-5.1:openrouter'],
  'openrouter.floor': ['0:deepseek/deepseek-v4-flash:openrouter'],
  'orchestrate': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'plan': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'postmerge.qa': ['0:claude-opus-5-5:claude', '1:claude-opus-5:claude'],
  'product': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'product.ideate': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'product.map': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'product.mockup': ['0:claude-opus-5-5:claude'],
  'product.prd': ['0:claude-opus-5-5:claude'],
  'product.revise': ['0:claude-opus-5-5:claude'],
  'product.signals': ['0:claude-opus-5-5:claude'],
  'product.synth': ['0:claude-sonnet-5:claude'],
  'remediate': ['0:claude-sonnet-5:claude'],
  'rescue.review': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'responder': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'rule.miner': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'triage': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
  'triage.light': ['0:claude-sonnet-5:claude'],
  'triage.shard': ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude'],
};
const CARVE_OUT = new Set(['alert.triage']);
// Roles main seeded after the live read above, so not in LIVE: #1510.4's
// bootstrap.smoke (the bootstrap-machine.sh smoke literal it replaced) and
// BH-1948's lead.review (the lead review job's rank-0 model). Pinned here at
// those seeds so test 1's "no seeded role escapes" check still covers them.
// BH-2005.3's feature-map.draft (bin/feature-map-draft.sh) is pinned the same way,
// and so is BH-2545's review.trivial (bin/lib/review-saving.sh).
const SEEDED_SINCE = {
  'bootstrap.smoke': ['0:claude-haiku-4-5-20251001:claude'],
  'lead.review': ['0:claude-opus-5-5:claude'],
  'feature-map.draft': ['0:claude-opus-5-5:claude'],
  'review.trivial': ['0:claude-haiku-4-5-20251001:claude'],
  // P4's build.execute.lite: the would-be execute role of the cheap shadow
  // rules (route_rules). Read by nothing live; pinned the same way.
  'build.execute.lite': ['0:claude-sonnet-5:claude'],
};
// TEST-CHANGE (BH-3327): roles whose seed COPIES another role's rung 0 instead
// of carrying a model literal (tests/alert-triage-runners R6 forbids a new model
// id under worker/, this file included). Each is pinned to exactly that copy.
// stage.lookback is a stage.* role, outside test 1.
// TEST-CHANGE (BH-3726): dequeue.classify copies lookback.cluster's rung 0 the
// same way (stage.dequeue-classify, like stage.lookback, is outside test 1).
const SEEDED_AS_COPY = {
  'lookback.cluster': 'rule.miner',
  'dequeue.classify': 'lookback.cluster',
  // TEST-CHANGE (BH-3955): replan copies triage.light's rung 0 the same way
  // (stage.replan is a stage.* role, outside test 1).
  replan: 'triage.light',
  // TEST-CHANGE (BH-5024): jev-pilot.baseline, the replay pilot's Haiku
  // baseline, copies review.trivial's rung 0 the same way.
  'jev-pilot.baseline': 'review.trivial',
  // TEST-CHANGE (BH-5806): lesson.classify, the BLOCK classifier's cheap route,
  // copies review.trivial's rung 0 the same way.
  'lesson.classify': 'review.trivial',
  // TEST-CHANGE (BH-5807): lesson.propose, the lesson-propose drafting route,
  // copies rule.miner's claude rung 0 the same way lookback.cluster does.
  'lesson.propose': 'rule.miner',
  // TEST-CHANGE (BH-7258): product.pm, the PM agent's route (BH-7244), copies
  // product.prd's rung 0 the same way.
  'product.pm': 'product.prd',
  // TEST-CHANGE (BH-6972): component-watch, the per-component alert watcher's
  // route, copies review.trivial's rung 0 (Haiku class) the same way.
  'component-watch': 'review.trivial',
  // TEST-CHANGE (BH-7722): unblock.judge, Tackler's bounded judge route, copies
  // stage.execute's claude rung 0 the same way stage.archie does.
  'unblock.judge': 'stage.execute',
};
// TEST-CHANGE (BH-4065): archie-research.xsearch copies grok.default's GROK
// rung 0 (Archie's direct xAI X search runs on the grok runner), so it is
// pinned to exactly that copy here, the same way the claude copies are above.
const SEEDED_AS_GROK_COPY = {
  'archie-research.xsearch': 'grok.default',
};
// TEST-CHANGE (BH-6967): review-intent, the intent review's route, is a two-rung
// copy: rung 0 is triage.light's claude rung 0, rung 1 is lead.review's rung 0.
const SEEDED_AS_LADDER_COPY = {
  'review-intent': ['triage.light', 'lead.review'],
  // TEST-CHANGE (BH-6970): review-break-it, the break-it verifier's route, is the
  // same two-rung copy.
  'review-break-it': ['triage.light', 'lead.review'],
};

test('1: a fresh DB seeds every hub role at its live ladder (bar the alert.triage carve-out)', () => {
  const db = openDb();
  for (const [role, want] of Object.entries(LIVE)) {
    if (CARVE_OUT.has(role)) continue;
    assert.deepEqual(ladder(db, role), want, `seed ladder for ${role}`);
  }
  for (const [role, want] of Object.entries(SEEDED_SINCE)) {
    assert.deepEqual(ladder(db, role), want, `seed ladder for ${role}`);
  }
  for (const [role, from] of Object.entries(SEEDED_AS_COPY)) {
    const rung0 = ladder(db, from).find((r) => r.startsWith('0:') && r.endsWith(':claude'));
    assert.ok(rung0, `${from} has a claude rung 0 to copy`);
    assert.deepEqual(ladder(db, role), [rung0], `seed ladder for ${role} (copy of ${from} rung 0)`);
  }
  for (const [role, from] of Object.entries(SEEDED_AS_GROK_COPY)) {
    const rung0 = ladder(db, from).find((r) => r.startsWith('0:') && r.endsWith(':grok'));
    assert.ok(rung0, `${from} has a grok rung 0 to copy`);
    assert.deepEqual(ladder(db, role), [rung0], `seed ladder for ${role} (copy of ${from} rung 0)`);
  }
  for (const [role, from] of Object.entries(SEEDED_AS_LADDER_COPY)) {
    const want = from.map((src, i) => {
      const rung0 = ladder(db, src).find((r) => r.startsWith('0:'));
      assert.ok(rung0, `${src} has a rung 0 to copy`);
      return `${i}:${rung0.slice(2)}`;
    });
    assert.deepEqual(ladder(db, role), want, `seed ladder for ${role} (copy of ${from.join(', ')} rung 0)`);
  }
  // Every non-stage hub role the seed writes is in the live snapshot, so no
  // seeded role escapes the comparison above.
  const seeded = db.prepare("SELECT DISTINCT role FROM model_routes WHERE project IS NULL AND role NOT LIKE 'stage.%'")
    .all().map((r) => r.role).sort();
  assert.deepEqual(seeded, [...Object.keys(LIVE), ...Object.keys(SEEDED_SINCE), ...Object.keys(SEEDED_AS_COPY), ...Object.keys(SEEDED_AS_GROK_COPY),
    ...Object.keys(SEEDED_AS_LADDER_COPY)].sort());
  db.close();
});

test('2: alert.triage stays on the strong never-seen-family investigator, Fable 5.1, one rung', () => {
  const db = openDb();
  assert.deepEqual(ladder(db, 'alert.triage'), ['0:claude-fable-5-1:claude']);
  db.close();
});

test('3: no claude-opus-4-8 survives anywhere in the seed', () => {
  const db = openDb();
  assert.equal(Number(db.prepare("SELECT count(*) n FROM model_routes WHERE model='claude-opus-4-8'").get().n), 0);
  db.close();
});

test('4: the stage.* seed is untouched (claude then codex, as BH-1766 seeded it)', () => {
  const db = openDb();
  const want = {
    'stage.triage': ['0:claude-fable-5-1:claude', '1:gpt-6-astra:codex'],
    'stage.plan': ['0:claude-fable-5-1:claude', '1:gpt-6-astra:codex'],
    'stage.preplan': ['0:claude-fable-5-1:claude', '1:gpt-6-astra:codex'],
    'stage.execute': ['0:claude-opus-5-5:claude', '1:gpt-6-astra:codex'],
    'stage.review': ['0:claude-opus-5-5:claude', '1:gpt-6-astra:codex'],
    'stage.fix': ['0:claude-opus-5-5:claude', '1:gpt-6-astra:codex'],
  };
  for (const [role, rungs] of Object.entries(want)) assert.deepEqual(ladder(db, role), rungs, role);
  db.close();
});

test('5: an operator who PUT a one-rung ladder keeps it: re-applying schema.sql never re-adds rung 1', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'claude-opus-5-5');
  assert.deepEqual(ladder(db, 'build.review'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude']);
  const r = await put(DB, 'build.review', [{ model: 'claude-opus-5-5', runner: 'claude' }]);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'build.review'), ['0:claude-opus-5-5:claude'],
    're-applying schema.sql must not put back a rung an operator cut');
  db.close();
});

test('6: an operator\'s model edit survives a re-apply', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  priceModel(db, 'claude-sonnet-5');
  const r = await put(DB, 'triage', [{ model: 'claude-sonnet-5', runner: 'claude' }]);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'triage'), ['0:claude-sonnet-5:claude']);
  db.close();
});

test('7: re-applying schema.sql is idempotent: the row count does not move', () => {
  const db = openDb();
  const n = () => Number(db.prepare('SELECT count(*) n FROM model_routes').get().n);
  const first = n();
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  assert.equal(n(), first);
  db.close();
});

test('8: a project-scoped audit row does not suppress the hub rung-1 seed', () => {
  const db = openDb();
  // A DB whose only history for triage is a project override: no hub rows, no hub audit.
  db.prepare("DELETE FROM model_routes WHERE role='triage'").run();
  db.prepare("DELETE FROM model_route_changes WHERE role='triage'").run();
  db.prepare(`INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
              VALUES ('project', 'x', 'triage', 0, NULL, NULL, 'claude-sonnet-5', 'claude', 'op', 'project override', '2026-09-24T00:00:00Z')`).run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'triage'), ['0:claude-opus-5-5:claude', '1:claude-fable-5-1:claude']);
  db.close();
});
