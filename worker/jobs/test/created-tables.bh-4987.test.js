// BH-4987: CREATED_TABLES derives from worker/jobs/schema.d/.
//
// T1  every CREATE TABLE in the composed schema has its CREATED_TABLES entry
// T2  the 24 hand entries this slice deleted equal their derived form
// T3  the guard: no new hand key, and no override drifts from the schema
// T4  the parser's decision table
// T5  two branches that each add a fragment merge with no conflict, and both
//     tables derive with no core.js edit
// T6  the two schema writers (jobs-schema.js, bin/schema-build.sh) parse equal
// T7  ensureTable, the production reader, creates a deleted-key table and a
//     table that never had a hand entry exactly as the schema does
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CREATED_TABLES, CREATED_TABLE_OVERRIDES } from '../src/lib/core.js';
import { ensureTable } from '../src/index.js';
import { createdTablesFrom, statementsOf } from '../src/lib/created-tables.js';
import { jobsSchemaSql, composeSchema } from './lib/jobs-schema.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO = join(HERE, '..', '..', '..');
const HAND = JSON.parse(readFileSync(join(HERE, 'fixtures', 'created-tables-hand.bh-4987.json'), 'utf8'));

// Comments stripped, whitespace collapsed, no space around ( ) or ,.
const norm = (s) => statementsOf(s).join(';').replace(/\s+/g, ' ').replace(/\s*([(),])\s*/g, '$1').trim();
const normAll = (a) => a.map(norm);

const derived = createdTablesFrom(jobsSchemaSql());
const schemaTables = () => {
  const out = [];
  for (const s of statementsOf(jobsSchemaSql())) {
    const m = /^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+"?(\w+)"?/i.exec(s);
    if (m && !out.includes(m[1])) out.push(m[1]);
  }
  return out;
};

// The hand entries this slice leaves. A later slice deletes all but the five
// that differ from the schema on purpose.
const KEPT = [
  'merge_trains', 'verdict_history', 'wakes', 'wake_claims', 'pr_state_events',
  'pr_attempts', 'model_routes', 'routing_changes', 'cost_cap_changes',
  'config_changes', 'harness_flags', 'model_route_changes', 'verdicts',
  'lead_protected_paths', 'setting_sigs', 'lead_review_requests', 'risk_tiers',
  'jev_risk_calls', 'queue_risk_scores', 'route_rules', 'route_rule_changes',
  'route_shadow', 'triage_state', 'alert_family_scripts', 'dequeue_events',
  'dequeue_actions', 'projects', 'pool_spawns', 'pool_terminals', 'pool_holds',
  'conflict_hotspots', 'conflict_hotspot_runs', 'participant_machines',
  'suite_results', 'suite_reuse_runs',
];
// The overrides that differ from the derived entry on purpose: derived
// statements first, then the extra statements of the named kind.
const EXTRA = {
  verdicts: /^CREATE\s+TRIGGER\s+IF\s+NOT\s+EXISTS\s/i,
  setting_sigs: /^CREATE\s+TRIGGER\s+IF\s+NOT\s+EXISTS\s/i,
  pr_state_events: /^CREATE\s+VIEW\s+IF\s+NOT\s+EXISTS\s/i,
  harness_flags: /^INSERT\s+OR\s+IGNORE\s+INTO\s+harness_flags\s/i,
};

test('T1: every CREATE TABLE in the composed schema has its CREATED_TABLES entry', () => {
  const tables = schemaTables();
  assert.ok(tables.length >= 100, `the schema parses to ${tables.length} tables`);
  const missing = tables.filter((t) => !Array.isArray(CREATED_TABLES[t]));
  assert.deepEqual(missing, [], `${missing.length} of ${tables.length} schema tables have no entry`);
  for (const t of tables) {
    const first = CREATED_TABLES[t][0];
    assert.match(first, new RegExp(`^CREATE\\s+TABLE\\s+IF\\s+NOT\\s+EXISTS\\s+"?${t}"?\\s*\\(`, 'i'), t);
    if (!(t in CREATED_TABLE_OVERRIDES)) assert.deepEqual(normAll(CREATED_TABLES[t]), normAll(derived[t]), t);
  }
});

test('T2: the 24 deleted hand entries equal their derived form, in order', () => {
  const keys = Object.keys(HAND);
  assert.equal(keys.length, 24);
  for (const k of keys) {
    assert.ok(!(k in CREATED_TABLE_OVERRIDES), `${k} is still a hand entry`);
    assert.deepEqual(normAll(CREATED_TABLES[k]), normAll(HAND[k]), k);
  }
});

test('T3: no new hand key, and every override agrees with the schema', () => {
  const extra = Object.keys(CREATED_TABLE_OVERRIDES).filter((k) => !KEPT.includes(k));
  assert.deepEqual(extra, [],
    `a new table is a worker/jobs/schema.d fragment; CREATED_TABLES derives it (BH-4987): ${extra.join(', ')}`);
  assert.deepEqual(Object.keys(CREATED_TABLE_OVERRIDES).sort(), [...KEPT].sort());
  for (const k of KEPT) assert.equal(CREATED_TABLES[k], CREATED_TABLE_OVERRIDES[k], `${k}: the override wins`);
  // merge_trains creates train_group up front; the schema adds it by ALTER.
  const mt = CREATED_TABLES.merge_trains[0];
  assert.match(mt, /\btrain_group TEXT\b/);
  assert.deepEqual(normAll(CREATED_TABLES.merge_trains.slice(1)), normAll(derived.merge_trains.slice(1)));
  assert.equal(norm(mt).replace('train_group TEXT,', ''), norm(derived.merge_trains[0]));
  for (const k of KEPT) {
    if (k === 'merge_trains') continue;
    const o = normAll(CREATED_TABLE_OVERRIDES[k]);
    const d = normAll(derived[k]);
    if (EXTRA[k]) {
      assert.deepEqual(o.slice(0, d.length), d, `${k}: the derived statements lead the override`);
      const rest = CREATED_TABLE_OVERRIDES[k].slice(d.length);
      assert.ok(rest.length > 0, `${k}: no extra statement`);
      for (const s of rest) assert.match(s.trim(), EXTRA[k], `${k}: ${s.slice(0, 60)}`);
    } else {
      assert.deepEqual(o, d, `${k}: the hand copy drifted from worker/jobs/schema.d`);
    }
  }
});

test('T4: the parser decision table', () => {
  const sql = `
-- CREATE TABLE IF NOT EXISTS in_comment (a);
/* CREATE TABLE IF NOT EXISTS in_block (a); */
CREATE TABLE IF NOT EXISTS gh_budget (k TEXT, v TEXT CHECK (v IN ('a;b','c')));
CREATE TABLE IF NOT EXISTS "q" (a TEXT DEFAULT 'CREATE TABLE IF NOT EXISTS y (a)');
CREATE TABLE IF NOT EXISTS t (a TEXT, b TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS u ON t(a);
CREATE INDEX IF NOT EXISTS i_gh ON gh_budget (k); -- trailing
CREATE INDEX IF NOT EXISTS i ON t (b);
INSERT OR IGNORE INTO settings (key, value) VALUES ('x', 'CREATE TABLE IF NOT EXISTS z (a);');
CREATE VIEW IF NOT EXISTS v AS SELECT * FROM t;
CREATE INDEX IF NOT EXISTS orphan ON never_created(a);
`;
  const m = createdTablesFrom(sql);
  assert.deepEqual(Object.keys(m), ['gh_budget', 'q', 't']);
  assert.deepEqual(m.gh_budget, [
    "CREATE TABLE IF NOT EXISTS gh_budget (k TEXT, v TEXT CHECK (v IN ('a;b','c')))",
    'CREATE INDEX IF NOT EXISTS i_gh ON gh_budget (k)',
  ]);
  assert.deepEqual(m.q, ["CREATE TABLE IF NOT EXISTS \"q\" (a TEXT DEFAULT 'CREATE TABLE IF NOT EXISTS y (a)')"]);
  assert.deepEqual(m.t, [
    'CREATE TABLE IF NOT EXISTS t (a TEXT, b TEXT)',
    'CREATE UNIQUE INDEX IF NOT EXISTS u ON t(a)',
    'CREATE INDEX IF NOT EXISTS i ON t (b)',
  ]);
  assert.deepEqual(createdTablesFrom(''), {});
  assert.deepEqual(createdTablesFrom(undefined), {});
  assert.deepEqual(createdTablesFrom("CREATE TABLE IF NOT EXISTS w (a TEXT DEFAULT 'it''s;')"),
    { w: ["CREATE TABLE IF NOT EXISTS w (a TEXT DEFAULT 'it''s;')"] });
});

test('T5: two branches that each add a fragment merge clean, and both tables derive', () => {
  const r = mkdtempSync(join(tmpdir(), 'created-tables-bh-4987-'));
  try {
    const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (...a) => {
      const p = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.com',
        '-c', 'init.defaultBranch=main', ...a], { cwd: r, env, encoding: 'utf8' });
      return p;
    };
    const ok = (p) => assert.equal(p.status, 0, `${p.stdout}${p.stderr}`);
    ok(git('init', '-q'));
    cpSync(join(HERE, '..', 'schema.d'), join(r, 'schema.d'), { recursive: true });
    ok(git('add', '-A'));
    ok(git('commit', '-qm', 'base'));
    ok(git('checkout', '-qb', 'a'));
    writeFileSync(join(r, 'schema.d', '9998-bh-a-fx.sql'), 'CREATE TABLE IF NOT EXISTS fx_a (id TEXT);\n');
    ok(git('add', '-A'));
    ok(git('commit', '-qm', 'a'));
    ok(git('checkout', '-q', 'main'));
    ok(git('checkout', '-qb', 'b'));
    writeFileSync(join(r, 'schema.d', '9999-bh-b-fx.sql'),
      'CREATE TABLE IF NOT EXISTS fx_b (id TEXT, n INTEGER);\nCREATE INDEX IF NOT EXISTS idx_fx_b_n ON fx_b(n);\n');
    ok(git('add', '-A'));
    ok(git('commit', '-qm', 'b'));
    for (const [br, f] of [['a', 'schema.d/9998-bh-a-fx.sql'], ['b', 'schema.d/9999-bh-b-fx.sql']]) {
      const d = git('diff', '--name-only', `main...${br}`);
      ok(d);
      assert.deepEqual(d.stdout.trim().split('\n'), [f], `branch ${br} touched only its fragment`);
    }
    ok(git('checkout', '-q', 'a'));
    const merge = git('merge', '--no-edit', '-q', 'b');
    ok(merge);
    assert.equal(git('diff', '--name-only', '--diff-filter=U').stdout.trim(), '');
    const m = createdTablesFrom(composeSchema(join(r, 'schema.d')));
    assert.deepEqual(m.fx_a, ['CREATE TABLE IF NOT EXISTS fx_a (id TEXT)']);
    assert.deepEqual(m.fx_b, ['CREATE TABLE IF NOT EXISTS fx_b (id TEXT, n INTEGER)',
      'CREATE INDEX IF NOT EXISTS idx_fx_b_n ON fx_b(n)']);
    assert.equal(Object.keys(m).length, Object.keys(derived).length + 2);
  } finally {
    rmSync(r, { recursive: true, force: true });
  }
});

test('T6: jobs-schema.js and bin/schema-build.sh compose text that parses equal', () => {
  const p = spawnSync('bash', [join(REPO, 'bin', 'schema-build.sh'), '--worker', 'jobs'], { encoding: 'utf8', maxBuffer: 64 << 20 });
  assert.equal(p.status, 0, p.stderr);
  assert.ok(p.stdout.length > 0);
  assert.deepEqual(createdTablesFrom(p.stdout), derived);
});

test('T7: ensureTable creates a deleted-key table and a never-hand table exactly as the schema does', async (t) => {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite is not available'); return; }
  const ref = new DatabaseSync(':memory:');
  ref.exec(jobsSchemaSql());
  const db = new DatabaseSync(':memory:');
  const env = { DB: d1(db) };
  const neverHand = 'stage_events';
  assert.ok(!(neverHand in HAND) && !(neverHand in CREATED_TABLE_OVERRIDES));
  const shape = (h, tb) => ({
    cols: h.prepare(`PRAGMA table_info(${tb})`).all().map((r) => ({ ...r })),
    idx: h.prepare(`SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL ORDER BY name`)
      .all(tb).map((r) => ({ name: r.name, sql: norm(r.sql) })),
  });
  for (const tb of ['gh_budget', neverHand]) {
    assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name=?").get(tb).n, 0);
    await ensureTable(env, tb);
    const got = shape(db, tb);
    assert.ok(got.cols.length > 0, `${tb} was not created`);
    assert.deepEqual(got, shape(ref, tb), tb);
    await ensureTable({ DB: d1(db) }, tb); // a new handle: the statements run again
    assert.deepEqual(shape(db, tb), got, `${tb}: a second call changed nothing`);
  }
  assert.ok(shape(db, neverHand).idx.length >= 2, 'stage_events has its indexes from two fragments');
});
