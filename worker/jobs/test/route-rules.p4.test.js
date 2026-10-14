import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// P4 — PLAN-DRIVEN MODEL ROUTING, SHADOW MODE. Three tables and their routes:
//   route_rules          one row per rule (plan features -> would-be execute
//                        role, review tier floor, test scope), whole-row PUT
//                        under expected_version, exactly as model_routes is
//                        written (docs/MODEL-ROUTES.md)
//   route_rule_changes   append-only audit, one row per decision
//   route_shadow         one row per BUILD: what the rules would have picked
//                        beside what the build actually ran on
// Driven through the worker's real fetch handler against THE SQL THAT SHIPS
// (schema.sql into node:sqlite), the idiom test/model-routes.bh-1510.test.js
// uses: every claim here is a property of the shipped statements.
//
// SHADOW ONLY is a property of the route, not a promise: a PUT that asks for
// mode 'live' is refused, so nothing in this slice can ever be read as a live
// routing decision.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const nul = (xs) => xs.map((v) => (v === undefined ? null : v));
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...nul(binds)) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...nul(binds)) }),
      run: async () => {
        const r = db.prepare(sql).run(...nul(binds));
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return {
      ...bindAndRun([]),
      bind: (...binds) => { const s = bindAndRun(binds); s._sql = sql; s._binds = binds; return s; },
    };
  };
  // D1 runs a batch as ONE transaction and rolls it back when any statement
  // throws; the version guard depends on exactly that, so the stub does too.
  return {
    prepare,
    batch: async (xs) => {
      db.exec('BEGIN');
      try {
        const out = xs.map((x) => {
          const st = db.prepare(x._sql);
          const binds = nul(x._binds || []);
          if (/^\s*SELECT/i.test(x._sql)) { st.all(...binds); return { meta: { changes: 0 } }; }
          const r = st.run(...binds);
          return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
        });
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}

const openDb = () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
};

const call = (db, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const cols = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name).sort();

test('schema: the three tables exist with the shape the routes use, and CREATED_TABLES creates the same columns', () => {
  const db = openDb();
  db.exec(SCHEMA); // re-apply, as bin/harness-sync.sh does on every deploy
  assert.deepEqual(cols(db, 'route_rules'), [
    'effect', 'execute_role', 'match_json', 'mode', 'name', 'note', 'priority',
    'review_tier', 'test_scope', 'tier_bump', 'updated_at', 'updated_by', 'version',
  ]);
  assert.deepEqual(cols(db, 'route_rule_changes'), ['actor', 'after_json', 'at', 'before_json', 'id', 'name', 'reason']);
  assert.ok(cols(db, 'route_shadow').includes('would_execute_model'));
  assert.ok(cols(db, 'route_shadow').includes('actual_execute_model'));
  for (const t of ['route_rules', 'route_rule_changes', 'route_shadow']) {
    assert.ok(Array.isArray(CREATED_TABLES[t]), `CREATED_TABLES.${t} must exist (the self-create belt)`);
    const fresh = new DatabaseSync(':memory:');
    for (const s of CREATED_TABLES[t]) fresh.exec(s);
    assert.deepEqual(cols(fresh, t), cols(db, t), `CREATED_TABLES.${t} and schema.sql must create the same columns`);
    fresh.close();
  }
  db.close();
});

test('seed: four rules, all mode=shadow, none live; the lite execute role is a model_routes row, never a literal in a rule', () => {
  const db = openDb();
  const rules = db.prepare('SELECT * FROM route_rules ORDER BY priority').all();
  assert.deepEqual(rules.map((r) => r.name), ['risk-surface', 'docs-tests-copy', 'specified-small', 'bounce-escalate']);
  for (const r of rules) {
    assert.equal(r.mode, 'shadow', `${r.name} must seed as shadow`);
    assert.equal(r.updated_by, 'seed');
    // A rule names a ROLE, and the role's model lives in model_routes.
    assert.doesNotMatch(String(r.execute_role || ''), /claude-|gpt-|grok-/, `${r.name} names a model id, not a role`);
    JSON.parse(r.match_json);
  }
  const byName = Object.fromEntries(rules.map((r) => [r.name, r]));
  assert.equal(byName['risk-surface'].execute_role, 'build.execute');
  assert.equal(byName['risk-surface'].review_tier, 'T2');
  assert.equal(byName['docs-tests-copy'].execute_role, 'build.execute.lite');
  assert.equal(byName['docs-tests-copy'].review_tier, 'T0');
  assert.equal(byName['specified-small'].execute_role, 'build.execute.lite');
  assert.equal(byName['specified-small'].review_tier, 'T1');
  assert.equal(JSON.parse(byName['specified-small'].match_json).max_lines, 150);
  assert.equal(byName['bounce-escalate'].effect, 'bump');
  assert.equal(byName['bounce-escalate'].tier_bump, 1);
  const lite = db.prepare("SELECT model, runner FROM model_routes WHERE role='build.execute.lite' AND project IS NULL AND position=0").get();
  assert.ok(lite, 'build.execute.lite must be seeded in model_routes');
  // model_prices is filled by bin/model-prices-sync.sh from the catalog, not by
  // schema.sql, so "priced" is checked against the catalog the sync reads.
  const catalog = JSON.parse(readFileSync(fileURLToPath(new URL('../../../catalog/model-prices.json', import.meta.url)), 'utf8'));
  assert.ok(Object.hasOwn(catalog.per_token || {}, lite.model), `the lite model ${lite.model} must be in catalog/model-prices.json`);
  db.close();
});

test('seed: a rule an operator has decided (any audit row) is never re-seeded by a later deploy', () => {
  const db = openDb();
  db.prepare("DELETE FROM route_rules WHERE name='specified-small'").run();
  db.prepare(`INSERT INTO route_rule_changes (name, before_json, after_json, actor, reason, at)
              VALUES ('specified-small', '{}', NULL, 'op', 'removed', '2026-09-25T00:00:00Z')`).run();
  db.exec(SCHEMA);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM route_rules WHERE name='specified-small'").get().n, 0);
  db.close();
});

test('GET /api/route-rules: every rule, match parsed, ordered by priority', async () => {
  const db = openDb();
  const r = await call(db, '/api/route-rules');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rules.map((x) => x.name), ['risk-surface', 'docs-tests-copy', 'specified-small', 'bounce-escalate']);
  assert.equal(typeof r.body.rules[0].match, 'object');
  assert.equal(r.body.rules[0].version, 1);
  db.close();
});

const base = {
  name: 'risk-surface', priority: 10, effect: 'route', mode: 'shadow',
  match: { any: ['u0', 'invariant_bearing', 'risk_surface'] },
  execute_role: 'build.execute', review_tier: 'T2', test_scope: 'full', tier_bump: 0,
};

test('PUT /api/route-rules: a whole-row replace writes ONE audit row with the before and after rows', async () => {
  const db = openDb();
  const r = await call(db, '/api/route-rules', {
    method: 'PUT',
    body: { ...base, test_scope: 'impact', actor: 'console', reason: 'try impact', expected_version: 1 },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rule.version, 2);
  assert.equal(r.body.rule.test_scope, 'impact');
  const audit = db.prepare("SELECT * FROM route_rule_changes WHERE name='risk-surface'").all();
  assert.equal(audit.length, 1);
  assert.equal(audit[0].actor, 'console');
  assert.equal(audit[0].reason, 'try impact');
  assert.equal(JSON.parse(audit[0].before_json).test_scope, 'full');
  assert.equal(JSON.parse(audit[0].after_json).test_scope, 'impact');
  // An identical re-PUT is not a decision: no new audit row, version unchanged.
  const again = await call(db, '/api/route-rules', { method: 'PUT', body: { ...base, test_scope: 'impact', expected_version: 2 } });
  assert.equal(again.status, 200);
  assert.equal(again.body.changed, false);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM route_rule_changes WHERE name='risk-surface'").get().n, 1);
  db.close();
});

test('PUT /api/route-rules: a stale expected_version is a 409 and writes nothing', async () => {
  const db = openDb();
  const r = await call(db, '/api/route-rules', { method: 'PUT', body: { ...base, test_scope: 'impact', expected_version: 7 } });
  assert.equal(r.status, 409);
  assert.equal(r.body.version, 1);
  assert.equal(db.prepare("SELECT test_scope FROM route_rules WHERE name='risk-surface'").get().test_scope, 'full');
  assert.equal(db.prepare('SELECT COUNT(*) n FROM route_rule_changes').get().n, 0);
  db.close();
});

test('PUT /api/route-rules: a new rule is created at version 1 with expected_version 0, audited with before NULL', async () => {
  const db = openDb();
  const r = await call(db, '/api/route-rules', {
    method: 'PUT',
    body: { ...base, name: 'copy-only', priority: 25, match: { all: ['docs_only'] }, execute_role: 'build.execute.lite', review_tier: 'T0', test_scope: 'minimal', expected_version: 0 },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rule.version, 1);
  const a = db.prepare("SELECT * FROM route_rule_changes WHERE name='copy-only'").get();
  assert.equal(a.before_json, null);
  assert.equal(JSON.parse(a.after_json).execute_role, 'build.execute.lite');
  db.close();
});

test('PUT /api/route-rules: SHADOW ONLY — mode live is refused, and so is every malformed field', async () => {
  const db = openDb();
  const bad = [
    [{ mode: 'live' }, /shadow/],
    [{ effect: 'teleport' }, /effect/],
    [{ execute_role: 'claude-opus-5-5' }, /model_routes/],
    [{ execute_role: 'no.such.role' }, /model_routes/],
    [{ review_tier: 'T9' }, /review_tier/],
    [{ test_scope: 'everything' }, /test_scope/],
    [{ match: { any: ['not_a_feature'] } }, /match/],
    [{ match: { max_lines: -1 } }, /match/],
    [{ name: 'Has Spaces' }, /name/],
    [{ priority: 'x' }, /priority/],
  ];
  for (const [patch, re] of bad) {
    const r = await call(db, '/api/route-rules', { method: 'PUT', body: { ...base, ...patch } });
    assert.equal(r.status, 400, `${JSON.stringify(patch)} -> ${r.status}`);
    assert.match(r.body.error, re, JSON.stringify(patch));
  }
  assert.equal(db.prepare('SELECT COUNT(*) n FROM route_rule_changes').get().n, 0, 'a refused PUT writes no audit row');
  db.close();
});

test('GET /api/route-rule-changes: the audit trail, newest first, filterable by name', async () => {
  const db = openDb();
  await call(db, '/api/route-rules', { method: 'PUT', body: { ...base, test_scope: 'impact' } });
  await call(db, '/api/route-rules', { method: 'PUT', body: { ...base, test_scope: 'minimal' } });
  const r = await call(db, '/api/route-rule-changes?name=risk-surface');
  assert.equal(r.status, 200);
  assert.equal(r.body.changes.length, 2);
  assert.equal(r.body.changes[0].after.test_scope, 'minimal');
  db.close();
});

const shadow = {
  build: 'project-3-TK-1-202609250101', job_id: 'build-project-3-TK-1-x', project: 'project-3', ticket_key: 'TK-1',
  rule: 'specified-small', bumped: '', would_execute_role: 'build.execute.lite',
  would_execute_model: 'claude-sonnet-5', actual_execute_model: 'claude-opus-5-5',
  would_review_tier: 'T1', planned_review_tier: 'T1', review_model: 'claude-opus-5-5',
  would_test_scope: 'impact', features: { lines: 90 }, box: 'box1',
};

test('POST /api/route-shadow: one row per build (idempotent), differs derived server-side; GET lists them', async () => {
  const db = openDb();
  const a = await call(db, '/api/route-shadow', { method: 'POST', body: shadow });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.recorded, true);
  const b = await call(db, '/api/route-shadow', { method: 'POST', body: { ...shadow, rule: 'other' } });
  assert.equal(b.status, 200);
  assert.equal(b.body.recorded, false, 'a resumed build dir must not write a second row');
  const row = db.prepare('SELECT * FROM route_shadow').get();
  assert.equal(row.differs, 1);
  assert.equal(row.rule, 'specified-small');
  const l = await call(db, '/api/route-shadow?since=2000-01-01T00:00:00Z&project=project-3');
  assert.equal(l.status, 200);
  assert.equal(l.body.rows.length, 1);
  assert.equal(l.body.rows[0].features.lines, 90);
  const bad = await call(db, '/api/route-shadow', { method: 'POST', body: { ...shadow, build: '' } });
  assert.equal(bad.status, 400);
  db.close();
});

test('GET /api/route-shadow/bounce: first-verdict BLOCK share per project, and per rule class through the shadow rows', async () => {
  const db = openDb();
  const job = (id, project) => db.prepare(
    `INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at)
     VALUES (?, ?, 'build', 'b', 'done', 'done', '2026-09-25T00:00:00Z', '2026-09-25T00:00:00Z')`).run(id, project);
  const verdict = (jobId, v, at) => db.prepare(
    `INSERT INTO verdict_history (job_id, verdict, source, created_at) VALUES (?, ?, 'run-build', ?)`).run(jobId, v, at);
  job('j1', 'project-3'); verdict('j1', 'BLOCK', '2099-01-01T00:00:01Z'); verdict('j1', 'APPROVE', '2099-01-01T00:00:02Z');
  job('j2', 'project-3'); verdict('j2', 'APPROVE', '2099-01-01T00:00:03Z');
  job('j3', 'project-3'); verdict('j3', 'APPROVE', '2099-01-01T00:00:04Z');
  job('j4', 'other'); verdict('j4', 'BLOCK', '2099-01-01T00:00:05Z');
  // Outside ANY trailing window: a BLOCK from the year 2000 must not count.
  job('j5', 'project-3'); verdict('j5', 'BLOCK', '2000-01-01T00:00:00Z');
  await call(db, '/api/route-shadow', { method: 'POST', body: { ...shadow, build: 'b1', job_id: 'j1' } });
  await call(db, '/api/route-shadow', { method: 'POST', body: { ...shadow, build: 'b2', job_id: 'j2', rule: 'risk-surface' } });
  // The fixtures sit in 2099 (inside every trailing window) and 2000 (outside
  // every one), so the rolling window below gives the same answer on any day.
  const p = await call(db, '/api/route-shadow/bounce?project=project-3&days=30'); // determinism: ok fixtures are 2099 (always in) and 2000 (always out)
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal(p.body.reviewed, 3, 'j5 (year 2000) is outside the window');
  assert.equal(p.body.blocked, 1, 'only the FIRST verdict of a job counts — j1 later approved');
  const c = await call(db, '/api/route-shadow/bounce?project=project-3&rule=specified-small&days=30'); // determinism: ok same 2099/2000 fixtures
  assert.equal(c.body.reviewed, 1);
  assert.equal(c.body.blocked, 1);
  const none = await call(db, '/api/route-shadow/bounce?project=nobody&days=30'); // determinism: ok no fixtures for this project at all
  assert.equal(none.body.reviewed, 0);
  assert.equal(none.body.rate, null, 'no reviews is not a 0% bounce rate');
  db.close();
});
