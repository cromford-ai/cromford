// BH-9076 (slice 5 of BH-9067): the retention rules this slice adds
// (src/routes/retention.d/bh-9076-*.js), on the composed jobs schema in
// node:sqlite, driven through the REAL worker.fetch where a run is involved.
//
//   R1 each rule's id read is an index range in time order (no SCAN of its
//      table, no temp B-tree for the ORDER BY), and its sel and del find rows
//      by key; dropping the index a rule reads makes the same check fail
//   R2 POST /api/retention/run with the seeded retention.dry_run=1: one
//      retention_runs row per new rule, each seeded old row counted, and no
//      row deleted from any table
//   R3 a real run (retention.dry_run=0) with no archive D1 bound: a delete
//      rule removes its old row and keeps the recent one; every archive rule
//      deletes nothing
//   R4 a real run with an archive D1 bound: every archive rule copies its old
//      row to the archive and then removes it from hot; the recent row stays
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import worker from '../src/index.js';
import { d1, openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const OLD = ago(1000);   // past every window here (the widest is 730 days)
const NEW = ago(1);
const RET_D = new URL('../src/routes/retention.d/', import.meta.url);
const FRAGMENTS = ['bh-9076-ops-delete.js', 'bh-9076-history-archive.js', 'bh-9076-d1-stmt-stats.js'];

async function newRules() {
  const out = [];
  for (const f of FRAGMENTS) {
    const u = new URL(f, RET_D);
    if (existsSync(u)) out.push(...(await import(u)).default);
  }
  return out;
}

// planProblems(db, r) — what is wrong with the plans of rule r's statements.
export function planProblems(db, r) {
  const probs = [];
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
  const ids = plan(r.ids, '2026-01-01T00:00:00Z', 500);
  const scanOf = new RegExp(`^SCAN ${r.table}\\b(?!.*USING (COVERING )?INDEX)`);
  for (const d of ids) {
    if (scanOf.test(d)) probs.push(`${r.rule} ids: ${d}`);
    if (/TEMP B-TREE/.test(d)) probs.push(`${r.rule} ids sorts: ${d}`);
  }
  for (const [name, sql] of [['del', r.del], ['sel', r.sel]]) {
    if (!sql) continue;
    for (const d of plan(sql, '[1,2]')) if (new RegExp(`^SCAN ${r.table}\\b`).test(d)) probs.push(`${r.rule} ${name}: ${d}`);
  }
  return probs;
}

test('R1 every new rule reads ids through an index, in time order; sel and del find rows by key', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const rules = await newRules();
  assert.ok(rules.length > 10, `only ${rules.length} BH-9076 rules found`);
  const probs = rules.flatMap((r) => planProblems(o.db, r));
  assert.deepEqual(probs, []);
  console.log(`retention-explain: ${rules.length} of ${rules.length} BH-9076 rules use an index`);
});

test('R1b the same check fails when the index a rule reads is dropped', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const r = (await newRules()).find((x) => x.table === 'main_red_events');
  assert.ok(r, 'no main_red_events rule');
  const used = o.db.prepare(`EXPLAIN QUERY PLAN ${r.ids}`).all('2026-01-01T00:00:00Z', 500)
    .map((x) => /USING (?:COVERING )?INDEX (\w+)/.exec(x.detail)).filter(Boolean).map((m) => m[1]);
  assert.equal(used.length, 1, 'the main_red_events id read names one index');
  o.db.exec(`DROP INDEX ${used[0]}`);
  assert.notDeepEqual(planProblems(o.db, r), []);
});

// ── seeding: one OLD and one NEW row in every table a new rule reads ──────────

// Column values a CHECK, a NOT NULL with no default, or the rule's own filter
// needs. seed() fills every other key or NOT NULL column (a TEXT primary key
// takes NULL in SQLite, and the real writers always set it), and the rule's
// time column.
const FIX = {
  registry_seed_runs: { status: 'applied' },
  restore_lab_runs: { status: 'done' },
  standby_verify_runs: { status: 'done' },
  box_commands_v2: { type: 'backup_now', reason: 'fixture reason', status: 'ok' },
  box_console_commands: { status: 'done' },
  main_red_events: { action: 'raise' },
  pauses: { what: 'builds', ended_at: OLD },
  main_red_pairs: { opened_at: OLD },
  lane_runs: { status: 'done' },
  queue_batch_minutes: { outcome: 'merged', source: 'jobs' },
  ci_duration_runs: { source: 'ci' },
  d1_stmt_stats: {},
};

function seed(db, r, ts, n) {
  const col = timeColumn(r);
  const info = db.prepare(`PRAGMA table_info(${r.table})`).all();
  const fix = FIX[r.table] || {};
  const row = {};
  for (const c of info) {
    if (c.name in fix) row[c.name] = fix[c.name];
    else if ((c.pk > 0 || (c.notnull && c.dflt_value === null)) && !(c.pk === 1 && /INT/i.test(c.type) && info.filter((x) => x.pk).length === 1)) {
      row[c.name] = /INT/i.test(c.type) ? n : /REAL/i.test(c.type) ? n + 0.5 : `fixture-${n}`;
    }
  }
  row[col] = r.table === 'd1_stmt_stats' ? ts.slice(0, 13) : ts;
  if (r.table === 'pauses') row.ended_at = ts;
  const cols = Object.keys(row);
  db.prepare(`INSERT INTO ${r.table} (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`).run(...cols.map((c) => row[c]));
}

// The column a rule's id read compares to the cutoff: `WHERE <col> < ...`.
function timeColumn(r) {
  const m = /(\w+)\s*<\s*(?:substr\()?\?1/.exec(r.ids);
  assert.ok(m, `${r.rule}: no '<col> < ?1' in ids`);
  return m[1];
}

async function run(env) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: '{}',
  }), { HARNESS_SECRET: SECRET, ...env });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;

async function seeded(t) {
  const o = await openDb(); if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const rules = await newRules();
  assert.ok(rules.length > 10, `only ${rules.length} BH-9076 rules found`);
  const tables = [...new Set(rules.map((r) => r.table))];
  for (const tb of tables) {
    const r = rules.find((x) => x.table === tb);
    seed(o.db, r, OLD, 1);
    seed(o.db, r, NEW, 2);
  }
  return { ...o, rules, tables };
}

test('R2 a dry run writes one retention_runs row per new rule and deletes nothing', async (t) => {
  const s = await seeded(t); if (!s) return;
  const before = Object.fromEntries(s.tables.map((tb) => [tb, count(s.db, tb)]));
  assert.ok(Object.values(before).every((n) => n === 2), JSON.stringify(before));
  const r = await run({ DB: s.DB });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.dry_run, true);
  for (const rule of s.rules) {
    const rows = s.db.prepare('SELECT counted, removed, dry_run FROM retention_runs WHERE run_id = ? AND rule = ?').all(r.body.run_id, rule.rule);
    assert.equal(rows.length, 1, `${rule.rule}: ${rows.length} retention_runs rows`);
    assert.equal(rows[0].dry_run, 1);
    assert.equal(rows[0].removed, 0, rule.rule);
    assert.equal(rows[0].counted, 1, `${rule.rule}: the old row is counted, the recent one is not`);
  }
  const after = Object.fromEntries(s.tables.map((tb) => [tb, count(s.db, tb)]));
  assert.deepEqual(after, before);
});

function live(db) {
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
}

test('R3 a real run with no archive bound: delete rules remove the old row, archive rules delete nothing', async (t) => {
  const s = await seeded(t); if (!s) return;
  live(s.db);
  const r = await run({ DB: s.DB });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.dry_run, false);
  for (const tb of s.tables) {
    const rs = s.rules.filter((x) => x.table === tb);
    const archived = rs.some((x) => x.archive);
    assert.equal(count(s.db, tb), archived ? 2 : 1, `${tb}: ${archived ? 'an archive rule with no archive D1 deletes nothing' : 'the delete rule removes the old row only'}`);
    const res = r.body.rules.find((x) => x.rule === rs[0].rule);
    assert.equal(res.removed, archived ? 0 : 1, `${rs[0].rule}: ${JSON.stringify(res)}`);
    if (archived) assert.match(String(res.error), /archive not bound/i, `${rs[0].rule}: a waiting row reports it`);
  }
});

test('R4 a real run with an archive bound: archive rules copy the old row, then remove it', async (t) => {
  const s = await seeded(t); if (!s) return;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  live(s.db);
  const r = await run({ DB: s.DB, ARCHIVE: d1(adb) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  for (const rule of s.rules.filter((x) => x.archive)) {
    const res = r.body.rules.find((x) => x.rule === rule.rule);
    assert.equal(res.error, null, `${rule.rule}: ${JSON.stringify(res)}`);
    assert.equal(res.removed, 1, `${rule.rule}: ${JSON.stringify(res)}`);
    assert.equal(count(s.db, rule.table), 1, `${rule.table}: the recent row stays in hot`);
    const col = timeColumn(rule);
    const a = adb.prepare(`SELECT ${col} AS ts, archived_at FROM ${rule.table}`).all();
    assert.equal(a.length, 1, `${rule.table}: one archived row`);
    assert.equal(a[0].ts, OLD);
    assert.equal(s.db.prepare(`SELECT ${col} AS ts FROM ${rule.table}`).get().ts, NEW);
  }
});
