// BH-9076 (slice 5 of BH-9067): every table the jobs schema creates has a
// retention answer. A table is covered when a composed retention RULES entry
// (src/routes/retention.d/, `#retention-rules`) names it, or when exactly one
// `-- no-retention: <table> <reason>` comment line in worker/jobs/schema.d/
// names it with a reason.
//
//   C1 every CREATE TABLE in schema.d/ is covered (the failure lists each
//      uncovered table and the fragment that creates it)
//   C2 a CREATE TABLE inside a comment or a string literal is not a table
//      (literal cases, plus the real 0014-bh-5750 comment
//      "an edited CREATE TABLE IF NOT EXISTS is a no-op")
//   C3 no rule names parks or ledgers, and no BH-9076 rule names wakes,
//      a wake_* table, ledgers or parks (they keep their own prune or stay)
//      and every BH-9076 rule name is one bin/d1-retention.sh logs (no digit)
//   C4 no no-retention line names a ruled table or a table no fragment
//      creates, none is repeated, none has an empty reason (literal near
//      misses: an empty reason, `lane` next to `lanes` and `lane_runs`)
//   C5 every BH-9076 rule's settings key is seeded, with the rule's def as
//      its value, in the composed schema
//   C6 every BH-9076 archive rule names its own table, is quietUnbound, has
//      a sel, and has an ARCHIVE_TABLES spec whose key and time columns exist
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { RULES } from '#retention-rules';
import { ARCHIVE_TABLES } from '../src/lib/archive.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SCHEMA_D = fileURLToPath(new URL('../schema.d/', import.meta.url));
const RET_D = new URL('../src/routes/retention.d/', import.meta.url);
const BH9076_FRAGMENTS = ['bh-9076-ops-delete.js', 'bh-9076-history-archive.js', 'bh-9076-d1-stmt-stats.js'];

// stripSql(sql) — the text with every `-- line` comment, `/* block */`
// comment and '...' / "..." literal replaced by one space. A quote inside a
// comment does not open a literal; a `--` inside a literal is not a comment.
export function stripSql(sql) {
  let out = '';
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    const n = sql[i + 1];
    if (c === '-' && n === '-') {
      const e = sql.indexOf('\n', i);
      i = e === -1 ? sql.length : e;
      out += ' ';
    } else if (c === '/' && n === '*') {
      const e = sql.indexOf('*/', i + 2);
      i = e === -1 ? sql.length : e + 2;
      out += ' ';
    } else if (c === "'" || c === '"') {
      let j = i + 1;
      for (;;) {
        if (j >= sql.length) break;
        if (sql[j] === c) {
          if (sql[j + 1] === c) { j += 2; continue; }
          break;
        }
        j++;
      }
      i = j + 1;
      out += ' ';
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

// createdTables(sql) — the table names the statements of `sql` create, in
// order. Only a CREATE TABLE at a statement start counts.
export function createdTables(sql) {
  const re = /(?:^|;)\s*CREATE\s+(?:TEMP\s+|TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`"[]?([A-Za-z_][A-Za-z0-9_]*)/gi;
  return [...stripSql(sql).matchAll(re)].map((m) => m[1]);
}

// noRetentionLines(sql, file) — every `-- no-retention:` line: {file, line,
// table, reason}. table is null when the line does not start with a name.
export function noRetentionLines(sql, file) {
  const out = [];
  sql.split('\n').forEach((text, i) => {
    const m = /^\s*--\s*no-retention:(.*)$/.exec(text);
    if (!m) return;
    const p = /^\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s+(.*))?$/.exec(m[1]);
    out.push({ file, line: i + 1, table: p ? p[1] : null, reason: p && p[2] ? p[2].trim() : '' });
  });
  return out;
}

// noRetentionProblems(lines, created, ruled) — one text per bad line.
export function noRetentionProblems(lines, created, ruled) {
  const probs = [];
  const seen = new Map();
  for (const l of lines) {
    const at = `${l.file}:${l.line}`;
    if (!l.table) { probs.push(`${at}: no table name`); continue; }
    if (!l.reason) probs.push(`${at}: ${l.table} has an empty reason`);
    if (!created.has(l.table)) probs.push(`${at}: ${l.table} is not created by any schema.d fragment (stale line)`);
    if (ruled.has(l.table)) probs.push(`${at}: ${l.table} has a retention rule; the line is stale`);
    if (seen.has(l.table)) probs.push(`${at}: ${l.table} is named again (first at ${seen.get(l.table)})`);
    else seen.set(l.table, at);
  }
  return probs;
}

function readSchemaD() {
  const files = readdirSync(SCHEMA_D).filter((f) => f.endsWith('.sql')).sort();
  const created = new Map();   // table -> [files]
  const lines = [];
  for (const f of files) {
    const sql = readFileSync(SCHEMA_D + f, 'utf8');
    for (const t of createdTables(sql)) {
      if (!created.has(t)) created.set(t, []);
      created.get(t).push(f);
    }
    lines.push(...noRetentionLines(sql, f));
  }
  return { created, lines };
}

async function bh9076Rules() {
  const out = [];
  for (const f of BH9076_FRAGMENTS) {
    const u = new URL(f, RET_D);
    if (!existsSync(u)) continue;
    const mod = await import(u);
    for (const r of mod.default) out.push({ ...r, fragment: f });
  }
  return out;
}

const ruled = new Set(RULES.map((r) => r.table));

test('C1 every CREATE TABLE in schema.d/ has a rule or one no-retention line with a reason', () => {
  const { created, lines } = readSchemaD();
  assert.ok(created.size > 200, `expected the full jobs schema, parsed ${created.size} tables`);
  const byTable = new Map();
  for (const l of lines) if (l.table) byTable.set(l.table, [...(byTable.get(l.table) || []), l]);
  const uncovered = [];
  for (const [t, files] of [...created].sort()) {
    if (ruled.has(t)) continue;
    const ls = byTable.get(t) || [];
    if (ls.length !== 1 || !ls[0].reason) uncovered.push(`${t} (${files.join(',')}; ${ls.length} no-retention line(s))`);
  }
  assert.deepEqual(uncovered, [], `${uncovered.length} table(s) with no retention rule and no single no-retention line:\n  ${uncovered.join('\n  ')}`);
});

test('C2 a CREATE TABLE in a comment or a string literal is not a table', () => {
  const lit = [
    '-- an edited CREATE TABLE IF NOT EXISTS is a no-op (BH-1555)',
    '/* CREATE TABLE in_block (a INT); */',
    "INSERT INTO settings (key,value) VALUES ('k', 'CREATE TABLE in_string (a INT)');",
    'CREATE TABLE IF NOT EXISTS real_one (a INT); -- trailing CREATE TABLE in_tail',
    '  create table real_two (b TEXT);',
    "INSERT INTO t VALUES ('it''s -- not a comment'); CREATE TABLE real_three (c INT);",
  ].join('\n');
  assert.deepEqual(createdTables(lit), ['real_one', 'real_two', 'real_three']);

  // The real fragment: its header comment holds the words, its one statement
  // creates box_commands_v2.
  const raw = readFileSync(SCHEMA_D + '0014-bh-5750-box-commands-v2.sql', 'utf8');
  assert.match(raw, /an edited CREATE TABLE IF NOT EXISTS is a no-op/, 'the comment this case pins is gone from 0014-bh-5750');
  const naive = [...raw.matchAll(/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)/gi)].map((m) => m[1]);
  assert.ok(naive.includes('is'), 'a parser that keeps comments reads the comment as table "is"');
  assert.deepEqual(createdTables(raw), ['box_commands_v2']);
});

test('C3 no rule names parks or ledgers; no BH-9076 rule names wakes or wake_*', async () => {
  for (const r of RULES) {
    assert.notEqual(r.table, 'parks', `rule ${r.rule} names parks`);
    assert.notEqual(r.table, 'ledgers', `rule ${r.rule} names ledgers (claim keys, BH-6774 C2)`);
  }
  const mine = await bh9076Rules();
  assert.ok(mine.some((r) => r.fragment === 'bh-9076-ops-delete.js'), 'retention.d/bh-9076-ops-delete.js has no rule');
  assert.ok(mine.some((r) => r.fragment === 'bh-9076-history-archive.js'), 'retention.d/bh-9076-history-archive.js has no rule');
  for (const r of mine) {
    assert.ok(!/^(wakes|wake_.*|ledgers|parks)$/.test(r.table), `${r.fragment} rule ${r.rule} names ${r.table}`);
    // bin/d1-retention.sh (RULE_RE) logs and alerts only a rule named
    // ^[a-z_]+\.[a-z_]+$; it skips any other name as unsafe.
    assert.match(r.rule, /^[a-z_]+\.[a-z_]+$/, `${r.fragment}: bin/d1-retention.sh skips the rule name ${r.rule}`);
    assert.ok(RULES.some((x) => x.rule === r.rule), `${r.rule} is not in the composed RULES`);
  }
});

test('C4 no stale, repeated or empty no-retention line', () => {
  const { created, lines } = readSchemaD();
  assert.ok(lines.length > 0, 'no -- no-retention: line in schema.d/');
  assert.deepEqual(noRetentionProblems(lines, new Set(created.keys()), ruled), []);

  // Near misses on literal lines, through the same parser.
  const sql = [
    '-- no-retention: lanes',
    '-- no-retention: lane one row per lane',
    '-- no-retention: lane_runs queue rows',
    '-- no-retention: lane_runs again',
    '-- no-retention: wakes the BH-1267 prune',
    '-- no-retention:   ',
    '--no-retention: lanes_x tight prefix',
    '-- not-retention: lanes ignored',
  ].join('\n');
  const ls = noRetentionLines(sql, 'x.sql');
  assert.equal(ls.length, 7);
  const probs = noRetentionProblems(ls, new Set(['lanes', 'lane_runs', 'wakes']), new Set(['wakes']));
  assert.deepEqual(probs, [
    'x.sql:1: lanes has an empty reason',
    'x.sql:2: lane is not created by any schema.d fragment (stale line)',
    'x.sql:4: lane_runs is named again (first at x.sql:3)',
    'x.sql:5: wakes has a retention rule; the line is stale',
    'x.sql:6: no table name',
    'x.sql:7: lanes_x is not created by any schema.d fragment (stale line)',
  ]);
});

test('C5 every BH-9076 rule key is a seeded settings row equal to the rule def', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const mine = await bh9076Rules();
  assert.ok(mine.length > 2);
  const bad = [];
  for (const r of mine) {
    assert.ok(Number.isInteger(r.def) && r.def > 0, `${r.rule}: def ${r.def}`);
    assert.equal(r.key, `retention.${r.table}.days`, `${r.rule}: key`);
    const row = o.db.prepare('SELECT value FROM settings WHERE key = ?').get(r.key);
    if (!row) bad.push(`${r.key}: no seed row`);
    else if (row.value !== String(r.def)) bad.push(`${r.key}: seed ${row.value}, rule def ${r.def}`);
  }
  assert.deepEqual(bad, []);
});

test('C6 every BH-9076 archive rule has an archive spec whose columns exist', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const arch = (await bh9076Rules()).filter((r) => r.archive);
  assert.ok(arch.length > 10, `only ${arch.length} archive rules`);
  for (const r of arch) {
    assert.equal(r.archive, r.table, `${r.rule}: archive must name its own table`);
    assert.equal(r.quietUnbound, true, `${r.rule}: an archive rule here must be quietUnbound`);
    assert.equal(typeof r.sel, 'string', `${r.rule}: sel`);
    const spec = ARCHIVE_TABLES[r.table];
    assert.ok(spec, `${r.rule}: no ARCHIVE_TABLES entry for ${r.table}`);
    const info = o.db.prepare(`PRAGMA table_info(${r.table})`).all();
    const cols = new Set(info.map((c) => c.name));
    for (const k of [...spec.key, spec.time]) assert.ok(cols.has(k), `${r.table}: column ${k} not in the table`);
    // The key is the table's primary key or a unique index: two hot rows can
    // never share one archive row.
    const pk = info.filter((c) => c.pk > 0).sort((a, b) => a.pk - b.pk).map((c) => c.name);
    const uniques = o.db.prepare(`PRAGMA index_list(${r.table})`).all().filter((x) => x.unique)
      .map((x) => o.db.prepare(`PRAGMA index_info(${x.name})`).all().map((c) => c.name));
    const same = (a) => a.length === spec.key.length && a.every((c) => spec.key.includes(c));
    assert.ok(same(pk) || uniques.some(same), `${r.table}: archive key ${spec.key} is not its primary key or a unique index`);
  }
});
