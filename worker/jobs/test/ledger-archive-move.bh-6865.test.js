// BH-6865 (BH-6780.2): the ledgers.archive retention rule. Old rows of an
// audited, allowlisted ledger kind move from the hot `ledgers` table to the
// archive store, and GET /api/ledger?kind&key still answers them through the
// tracer's fallback. Driven through the REAL worker.fetch: the hot store is
// node:sqlite with the composed jobs schema, the archive is an EMPTY node:sqlite
// database (the worker creates its `ledgers` table). Each test opens its own
// stores and uses its own keys. Every time is an offset from the clock.
//
//   U1-U3 the per-kind class map: never, key, unaudited
//   U4    retention.ledgers.archive_min_days raises the 91-day floor, never lowers it
//   R1    defaults: the rule is off, nothing moves, no archive table
//   R2    a recorded kind moves with the same 8 column values; a failed or short
//         copy deletes nothing; an unbound archive moves nothing
//   R4    never and unaudited kinds are refused with the reason in the audit row
//   R7    the id read and the archive key reads use an index (EXPLAIN QUERY PLAN)
//   R8    a kind dropped from archive_kinds stays sticky: GET still answers it
//   R9    record, then move after retention.ledgers.sticky_wait_s; window 90 off;
//         a window below retention.ledgers.archive_min_days is off
//   R10   newer wins: a re-PUT key moves over the archived row; an archive row
//         older than the hot copy fails the count-back; a PUT between
//         the copy and the delete keeps the hot row
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import {
  LEDGER_KIND_CLASS, LEDGER_ARCHIVE_FLOOR_DAYS, ledgerArchiveMinDays, ledgerKindClass, ledgerKindMovable,
} from '../src/lib/ledger-kind-class.js';
import { ensureArchiveTable } from '../src/lib/archive.js';
import fragment from '../src/routes/retention.d/bh-6865-ledgers-archive.js';

const SECRET = 'test-secret';
const KIND = 'review_block_fp';
const RULE = 'ledgers.archive';
const COLS = 'kind, key, status, job_id, actor, detail, created_at, updated_at';
const isoS = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
// The route cuts against its own clock read, so each fixture time is an offset
// from the clock at the call, not from one module anchor (a 110 s vs 125 s
// sticky-wait case would drift past 120 s on a slow run).
const ago = (days) => isoS(Date.now() - days * 86400e3);  // determinism: ok an offset of whole days from the route's own clock read; every margin is a day or more
// Milliseconds kept: a stickyAt N seconds back stays N seconds back after the
// route truncates its own clock to the second.
const secsAgo = (s) => new Date(Date.now() - s * 1000).toISOString();  // determinism: ok an offset from the route's own clock read; every case keeps 5 s or more from the 120 s wait

async function stores({ archiveHooks = {}, hotHooks = {} } = {}) {
  const o = await openDb(hotHooks);
  if (!o) return null;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  return { db: o.db, DB: o.DB, adb, ARCHIVE: d1(adb, archiveHooks) };
}
async function call(env, method, path, body) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), { ...env, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const run = (env, body = {}) => call(env, 'POST', '/api/retention/run', body);
const getLedger = (env, kind, key) =>
  call(env, 'GET', `/api/ledger?kind=${encodeURIComponent(kind)}&key=${encodeURIComponent(key)}`);
function setting(db, key, value, updatedAt = ago(0)) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`)
    .run(key, String(value), 'test', updatedAt);
}
const settingRow = (db, key) => ({ ...db.prepare('SELECT value, updated_at FROM settings WHERE key=?').get(key) });
// A window of 91 days, real runs, and `kinds` allowlisted.
function on(db, kinds = KIND) {
  setting(db, 'retention.dry_run', '0');
  setting(db, 'retention.ledgers.archive_days', '91');
  setting(db, 'retention.ledgers.archive_kinds', kinds);
}
// `kinds` recorded in archived_kinds `s` seconds ago (past the 120 s wait by default).
const recorded = (db, kinds = KIND, s = 130) => setting(db, 'retention.ledgers.archived_kinds', kinds, secsAgo(s));
function ledger(db, kind, key, daysAgo, status = 'blocked') {
  db.prepare(`INSERT INTO ledgers (${COLS}) VALUES (?,?,?,?,?,?,?,?)`)
    .run(kind, key, status, `job-${key}`, 'hub-a', `detail of ${key}`, ago(daysAgo + 1), ago(daysAgo));
}
const rows = (db, sql, ...b) => db.prepare(sql).all(...b).map((x) => ({ ...x }));
const count = (db, sql, ...b) => db.prepare(sql).get(...b).n;
const hotKeys = (db, kind = KIND) => rows(db, 'SELECT key FROM ledgers WHERE kind=? ORDER BY key', kind).map((x) => x.key);
const hasTable = (adb, t) => !!adb.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(t);
const ruleOut = (body) => (body.rules || []).find((x) => x.rule === RULE);
const audits = (db) => rows(db, 'SELECT counted, removed, error FROM retention_runs WHERE rule=? ORDER BY id', RULE);

// The rule's own kinds(env, o) on a settings Map, for exact second boundaries.
const RULE_DEF = fragment.find((r) => r.rule === RULE);
function byKey(entries) {
  return new Map(entries.map(([key, value, updated_at = '2026-01-01T00:00:00Z']) => [key, { key, value, updated_at }]));
}
function fakeEnv() {
  const writes = [];
  return {
    writes,
    DB: { prepare: (sql) => ({ bind: (...b) => ({ run: async () => { writes.push([sql, b]); return { meta: { changes: 1 } }; } }) }) },
  };
}

test('U1 never kinds are not movable', () => {
  for (const k of ['migration', 'pr_state', 'issue_state', 'build_note', 'repro_gate_claim', 'merge']) {
    assert.equal(ledgerKindClass(k), 'never', k);
    assert.equal(ledgerKindMovable(k), false, k);
  }
});

test('U2 audited key kinds are movable; every class is one of the four', () => {
  assert.equal(ledgerKindMovable('review_block_fp'), true);
  assert.equal(ledgerKindMovable('block_ci_clear'), true);
  const classes = new Set(['key', 'list-only', 'write-only', 'never']);
  for (const [k, c] of Object.entries(LEDGER_KIND_CLASS)) assert.ok(classes.has(c), `${k}: ${c}`);
  assert.ok(Object.isFrozen(LEDGER_KIND_CLASS));
  assert.equal(LEDGER_ARCHIVE_FLOOR_DAYS, 91);
});

test('U3 a kind not in the map is unaudited, inherited names and case near misses too', () => {
  for (const k of ['made_up_kind', 'constructor', '__proto__', 'toString', 'Review_Block_FP', '']) {
    assert.equal(ledgerKindClass(k), 'unaudited', k);
    assert.equal(ledgerKindMovable(k), false, k);
  }
});

test('U4 ledgerArchiveMinDays: the row raises the floor; a row below 91, junk or past 3650 is 91', () => {
  assert.equal(ledgerArchiveMinDays(byKey([])), 91);
  assert.equal(ledgerArchiveMinDays(byKey([['retention.ledgers.archive_min_days', '120']])), 120);
  assert.equal(ledgerArchiveMinDays(byKey([['retention.ledgers.archive_min_days', ' 91 ']])), 91);
  assert.equal(ledgerArchiveMinDays(byKey([['retention.ledgers.archive_min_days', '3650']])), 3650);
  for (const v of ['30', '90', '0', 'abc', '5000', '-120', '120.5', ''])
    assert.equal(ledgerArchiveMinDays(byKey([['retention.ledgers.archive_min_days', v]])), 91, `row ${v}`);
});

test('R1a the seeded defaults: the rule is off, nothing moves, no archive table, no audit row', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0');
  for (const k of ['a', 'b', 'c']) ledger(db, KIND, k, 400);
  const r = await run({ DB, ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const out = ruleOut(r.body);
  assert.ok(out, 'the rule is in the run');
  assert.equal(out.off, true); assert.equal(out.removed, 0);
  assert.deepEqual(hotKeys(db), ['a', 'b', 'c']);
  assert.equal(hasTable(adb, 'ledgers'), false);
  assert.deepEqual(audits(db), []);
  assert.equal(settingRow(db, 'retention.ledgers.archived_kinds').value, '');
});

test('R1b window 91 with an empty archive_kinds is off', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db, '');
  ledger(db, KIND, 'a', 400);
  const r = await run({ DB, ARCHIVE });
  assert.equal(ruleOut(r.body).off, true);
  assert.deepEqual(hotKeys(db), ['a']);
  assert.equal(hasTable(adb, 'ledgers'), false);
  assert.deepEqual(audits(db), []);
});

test('R2a record, then move: same 8 values in the archive, the recent row stays, GET answers archived', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db);
  for (const k of ['old1', 'old2', 'old3']) ledger(db, KIND, k, 100);
  ledger(db, KIND, 'new1', 10);
  const before = rows(db, `SELECT ${COLS} FROM ledgers WHERE key LIKE 'old%' ORDER BY key`);

  const r1 = await run({ DB, ARCHIVE });
  assert.equal(r1.status, 200, JSON.stringify(r1.body));
  assert.equal(ruleOut(r1.body).removed, 0, 'run 1 records the kind and settles');
  assert.equal(settingRow(db, 'retention.ledgers.archived_kinds').value, KIND);
  assert.equal(hotKeys(db).length, 4);

  recorded(db);
  const r2 = await run({ DB, ARCHIVE });
  const out = ruleOut(r2.body);
  assert.equal(out.removed, 3, JSON.stringify(out)); assert.equal(out.error, null);
  assert.deepEqual(hotKeys(db), ['new1']);
  const moved = rows(adb, `SELECT ${COLS}, archived_at FROM ledgers ORDER BY key`);
  assert.deepEqual(moved.map(({ archived_at, ...rest }) => rest), before, 'the archive holds the same 8 values');
  assert.ok(moved.every((x) => /^\d{4}-\d\d-\d\dT/.test(x.archived_at)));
  assert.equal(audits(db).at(-1).removed, 3);

  const g = await getLedger({ DB, ARCHIVE }, KIND, 'old2');
  assert.equal(g.status, 200); assert.equal(g.body.archived, true);
  assert.equal(g.body.ledger.detail, 'detail of old2');
});

test('R2b a padded, repeated allowlist moves the same rows', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db, ` ${KIND} , ${KIND}`); recorded(db);
  ledger(db, KIND, 'old1', 100); ledger(db, KIND, 'new1', 10);
  const out = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(out.removed, 1, JSON.stringify(out));
  assert.deepEqual(hotKeys(db), ['new1']);
  assert.equal(count(adb, 'SELECT COUNT(*) n FROM ledgers'), 1);
});

test('R2c ARCHIVE unbound: "archive not bound", nothing deleted, archived_kinds unchanged', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB } = s;
  on(db);
  ledger(db, KIND, 'old1', 100);
  const seeded = settingRow(db, 'retention.ledgers.archived_kinds');
  const out = ruleOut((await run({ DB })).body);
  assert.equal(out.error, 'archive not bound'); assert.equal(out.removed, 0);
  assert.deepEqual(hotKeys(db), ['old1']);
  assert.deepEqual(settingRow(db, 'retention.ledgers.archived_kinds'), seeded);
  assert.equal(audits(db).length, 1);
});

test('R2d a failed copy or a short count-back deletes nothing', async (t) => {
  const s = await stores({ archiveHooks: { beforeRun: (sql) => { if (/^\s*INSERT/i.test(sql)) throw new Error('archive write refused'); } } });
  if (!s) return t.skip('node:sqlite unavailable');
  on(s.db); recorded(s.db);
  ledger(s.db, KIND, 'old1', 100);
  const out = ruleOut((await run({ DB: s.DB, ARCHIVE: s.ARCHIVE })).body);
  assert.match(String(out.error), /^archive copy failed/); assert.equal(out.removed, 0);
  assert.deepEqual(hotKeys(s.db), ['old1']);

  // The count-back finds no row: the copy is not verified.
  const s2 = await stores(); if (!s2) return t.skip('node:sqlite unavailable');
  const short = {
    prepare(sql) {
      if (/SELECT COUNT\(\*\) AS n FROM json_each/.test(sql)) return { bind: () => ({ first: async () => ({ n: 0 }) }) };
      return s2.ARCHIVE.prepare(sql);
    },
    batch: (x) => s2.ARCHIVE.batch(x),
  };
  on(s2.db); recorded(s2.db);
  ledger(s2.db, KIND, 'old1', 100);
  const out2 = ruleOut((await run({ DB: s2.DB, ARCHIVE: short })).body);
  assert.match(String(out2.error), /^archive copy not verified/); assert.equal(out2.removed, 0);
  assert.deepEqual(hotKeys(s2.db), ['old1']);
});

test('R4 never and unaudited kinds are refused with the reason; a movable kind beside them still moves', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db, `migration,made_up_kind,${KIND}`);
  ledger(db, 'migration', 'm1', 400); ledger(db, 'made_up_kind', 'x1', 400); ledger(db, KIND, 'old1', 100);
  const want = 'refused kinds: migration(never), made_up_kind(unaudited)';

  const r1 = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(r1.error, want); assert.equal(r1.removed, 0);
  assert.equal(settingRow(db, 'retention.ledgers.archived_kinds').value, KIND, 'only the movable kind is recorded');

  recorded(db);
  const r2 = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(r2.error, want); assert.equal(r2.removed, 1);
  assert.deepEqual(hotKeys(db, 'migration'), ['m1']);
  assert.deepEqual(hotKeys(db, 'made_up_kind'), ['x1']);
  assert.deepEqual(hotKeys(db), []);
  assert.deepEqual(rows(adb, 'SELECT kind FROM ledgers').map((x) => x.kind), [KIND]);
  assert.deepEqual(audits(db).map((a) => a.error), [want, want]);
});

test('R4b only refused kinds listed: one audit row with the error, nothing moved, nothing recorded', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db, 'merge,constructor,__proto__,Review_Block_FP');
  ledger(db, 'merge', 'p1', 400);
  const out = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(out.off, false);
  assert.equal(out.error, 'refused kinds: merge(never), constructor(unaudited), __proto__(unaudited), Review_Block_FP(unaudited)');
  assert.deepEqual(audits(db), [{ counted: 0, removed: 0, error: out.error }]);
  assert.deepEqual(hotKeys(db, 'merge'), ['p1']);
  assert.equal(hasTable(adb, 'ledgers'), false);
  assert.equal(settingRow(db, 'retention.ledgers.archived_kinds').value, '');
});

test('R7 the id read and the archive key reads use an index on 5 000 rows', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  const kinds = [KIND, 'merge', 'pr_state', 'deploy', 'hold_comment'];
  const ins = db.prepare(`INSERT INTO ledgers (${COLS}) VALUES (?,?,'s',NULL,NULL,NULL,?,?)`);
  for (let i = 0; i < 5000; i++) { const at = ago(i % 400); ins.run(kinds[i % 5], `k${i}`, at, at); }
  db.exec('ANALYZE');
  const plan = (d, sql, ...b) => rows(d, `EXPLAIN QUERY PLAN ${sql}`, ...b).map((x) => x.detail).join(' | ');
  const ids = plan(db, RULE_DEF.ids, ago(91), 500, JSON.stringify([KIND, 'hold_comment']));
  assert.match(ids, /idx_ledgers_kind_updated/, ids);
  assert.doesNotMatch(ids, /SCAN ledgers/, ids);
  const del = plan(db, RULE_DEF.del, '[1,2,3]', ago(91));
  assert.doesNotMatch(del, /SCAN ledgers/, del);

  await ensureArchiveTable({ DB, ARCHIVE }, 'ledgers');
  const back = plan(adb, `SELECT COUNT(*) AS n FROM json_each(?1) j JOIN "ledgers" a ON a."kind" = json_extract(j.value, '$[0]') AND a."key" = json_extract(j.value, '$[1]') AND a."updated_at" >= json_extract(j.value, '$[2]')`, '[]');
  assert.match(back, /sqlite_autoindex_ledgers_1/, back);
  assert.doesNotMatch(back, /SCAN a\b|SCAN ledgers/, back);
  const point = plan(adb, 'SELECT * FROM ledgers WHERE kind=?1 AND key=?2', KIND, 'k0');
  assert.match(point, /sqlite_autoindex_ledgers_1/, point);
});

test('R8 a kind dropped from archive_kinds stays sticky: GET answers the moved key, no new row moves', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  on(db); recorded(db);
  ledger(db, KIND, 'old1', 100);
  assert.equal(ruleOut((await run({ DB, ARCHIVE })).body).removed, 1);
  setting(db, 'retention.ledgers.archive_kinds', '');
  const g = await getLedger({ DB, ARCHIVE }, KIND, 'old1');
  assert.equal(g.status, 200, JSON.stringify(g.body)); assert.equal(g.body.archived, true);
  ledger(db, KIND, 'old2', 100);
  const out = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(out.off, true);
  assert.deepEqual(hotKeys(db), ['old2']);
  assert.equal(settingRow(db, 'retention.ledgers.archived_kinds').value, KIND, 'never taken back');
});

test('R9a the first real run records the kind at the run time and moves nothing', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db);
  setting(db, 'retention.ledgers.archived_kinds', 'block_ci_clear', secsAgo(500));
  setting(db, 'retention.ledgers.archive_kinds', `block_ci_clear,${KIND}`);
  ledger(db, KIND, 'old1', 100); ledger(db, 'block_ci_clear', 'c1', 100);
  const r = await run({ DB, ARCHIVE });
  const out = ruleOut(r.body);
  assert.equal(out.removed, 0, 'a fresh kind settles the whole run'); assert.equal(out.error, null);
  const row = settingRow(db, 'retention.ledgers.archived_kinds');
  assert.equal(row.value, `block_ci_clear,${KIND}`, 'appended, order kept');
  assert.equal(row.updated_at, r.body.as_of);
  assert.deepEqual(hotKeys(db), ['old1']);
  assert.deepEqual(hotKeys(db, 'block_ci_clear'), ['c1']);
  assert.equal(hasTable(adb, 'ledgers'), false);
});

test('R9b the move waits sticky_wait_s after the record (exact boundary, and through the route)', async (t) => {
  const nowMs = Date.parse('2026-10-29T12:00:00Z');
  const at = (s) => isoS(nowMs - s * 1000);
  for (const [s, settle] of [[119, true], [120, false], [121, false]]) {
    const env = fakeEnv();
    const k = await RULE_DEF.kinds(env, { nowMs, dryRun: false, byKey: byKey([
      ['retention.ledgers.archive_kinds', KIND], ['retention.ledgers.archived_kinds', KIND, at(s)]]) });
    assert.deepEqual(k.list, [KIND]);
    assert.equal(!!k.settle, settle, `${s}s`);
    assert.equal(env.writes.length, 0);
  }
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  on(db); recorded(db, KIND, 110);
  ledger(db, KIND, 'old1', 100);
  assert.equal(ruleOut((await run({ DB, ARCHIVE })).body).removed, 0, '110 s: waits');
  recorded(db, KIND, 125);
  assert.equal(ruleOut((await run({ DB, ARCHIVE })).body).removed, 1, '125 s: moves');
});

test('R9c window: 0, 90 and abc are off; 91 and 365 are on', async (t) => {
  for (const [w, off] of [['0', true], ['90', true], ['abc', true], ['91', false], ['365', false]]) {
    const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
    const { db, DB, ARCHIVE } = s;
    on(db); recorded(db);
    setting(db, 'retention.ledgers.archive_days', w);
    ledger(db, KIND, 'old1', 400);
    const out = ruleOut((await run({ DB, ARCHIVE })).body);
    assert.equal(out.off, off, `window ${w}`);
    assert.deepEqual(hotKeys(db), off ? ['old1'] : [], `window ${w}`);
  }
});

test('R9d an archived_kinds row with an unparsable updated_at settles', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  on(db); setting(db, 'retention.ledgers.archived_kinds', KIND, 'not-a-date');
  ledger(db, KIND, 'old1', 100);
  const out = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(out.removed, 0); assert.equal(out.error, null);
  assert.deepEqual(hotKeys(db), ['old1']);
});

test('R9e a dry run writes no settings: a fresh kind counts 0; a recorded kind counts its old rows', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  on(db);
  ledger(db, KIND, 'old1', 100); ledger(db, KIND, 'old2', 100); ledger(db, KIND, 'new1', 10);
  const seeded = settingRow(db, 'retention.ledgers.archived_kinds');
  const r1 = ruleOut((await run({ DB, ARCHIVE }, { dry_run: true })).body);
  assert.equal(r1.counted, 0); assert.equal(r1.removed, 0);
  assert.deepEqual(settingRow(db, 'retention.ledgers.archived_kinds'), seeded);
  recorded(db);
  const r2 = ruleOut((await run({ DB, ARCHIVE }, { dry_run: true })).body);
  assert.equal(r2.counted, 2); assert.equal(r2.removed, 0);
  assert.equal(hotKeys(db).length, 3);
});

test('R9f retention.ledgers.sticky_wait_s: out of range falls back to 120; 300 waits 300 s', async () => {
  const nowMs = Date.parse('2026-10-29T12:00:00Z');
  const at = (s) => isoS(nowMs - s * 1000);
  for (const [wait, s, settle] of [['60', 100, true], ['60', 121, false], ['abc', 100, true], ['300', 200, true], ['300', 299, true], ['300', 301, false], ['86401', 121, false]]) {
    const k = await RULE_DEF.kinds(fakeEnv(), { nowMs, dryRun: false, byKey: byKey([
      ['retention.ledgers.archive_kinds', KIND], ['retention.ledgers.archived_kinds', KIND, at(s)],
      ['retention.ledgers.sticky_wait_s', wait]]) });
    assert.equal(!!k.settle, settle, `wait ${wait}, recorded ${s}s ago`);
  }
});

test('R9g retention.ledgers.archive_min_days: 120 turns window 100 off and 120 on; 30 is ignored (floor 91)', async (t) => {
  for (const [min, w, off] of [['120', '100', true], ['120', '120', false], ['30', '60', true], ['30', '91', false]]) {
    const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
    const { db, DB, ARCHIVE } = s;
    on(db); recorded(db);
    setting(db, 'retention.ledgers.archive_min_days', min);
    setting(db, 'retention.ledgers.archive_days', w);
    ledger(db, KIND, 'old1', 400);
    const out = ruleOut((await run({ DB, ARCHIVE })).body);
    assert.equal(out.off, off, `min ${min}, window ${w}`);
    assert.deepEqual(hotKeys(db), off ? ['old1'] : [], `min ${min}, window ${w}`);
  }
});

test('R9h the seeded rows: sticky_wait_s is 120, archive_min_days is 91', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  assert.equal(settingRow(s.db, 'retention.ledgers.sticky_wait_s').value, '120');
  assert.equal(settingRow(s.db, 'retention.ledgers.archive_min_days').value, '91');
});

test('R10a a key re-PUT after its move moves again, and the newer values win in the archive', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db); recorded(db);
  ledger(db, KIND, 'k1', 100);
  assert.equal(ruleOut((await run({ DB, ARCHIVE })).body).removed, 1);
  const u1 = adb.prepare('SELECT updated_at FROM ledgers WHERE key=?').get('k1').updated_at;
  const p = await call({ DB, ARCHIVE }, 'PUT', '/api/ledger', { kind: KIND, key: 'k1', status: 'cleared' });
  assert.equal(p.status, 200);
  const u2 = ago(95);
  db.prepare('UPDATE ledgers SET updated_at=? WHERE kind=? AND key=?').run(u2, KIND, 'k1');
  assert.ok(u2 > u1);
  assert.equal(ruleOut((await run({ DB, ARCHIVE })).body).removed, 1);
  assert.deepEqual({ ...adb.prepare('SELECT status, updated_at FROM ledgers WHERE key=?').get('k1') }, { status: 'cleared', updated_at: u2 });
  assert.deepEqual(hotKeys(db), []);
});

test('R10c an archive row newer than the hot copy is kept, and the older hot copy leaves', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db); recorded(db);
  await ensureArchiveTable({ DB, ARCHIVE }, 'ledgers');
  const u92 = ago(92);
  adb.prepare(`INSERT INTO ledgers (${COLS}, archived_at) VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(KIND, 'k1', 'newer', null, null, null, ago(300), u92, ago(1));
  ledger(db, KIND, 'k1', 100, 'older');
  const out = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(out.removed, 1, JSON.stringify(out)); assert.equal(out.error, null);
  assert.deepEqual({ ...adb.prepare('SELECT status, updated_at FROM ledgers WHERE key=?').get('k1') }, { status: 'newer', updated_at: u92 });
  assert.deepEqual(hotKeys(db), []);
});

test('R10b a PUT between the copy and the delete keeps the hot row and is not counted', async (t) => {
  let db = null;
  const hotHooks = {
    beforeRun: (sql) => {
      if (db && /^\s*DELETE FROM ledgers/.test(sql)) {
        // What PUT /api/ledger writes for an existing key: the new status at the request time.
        db.prepare('UPDATE ledgers SET status=?, updated_at=? WHERE kind=? AND key=?').run('fresh', ago(0), KIND, 'k2');
      }
    },
  };
  const s = await stores({ hotHooks }); if (!s) return t.skip('node:sqlite unavailable');
  db = s.db;
  const { DB, ARCHIVE } = s;
  on(db); recorded(db);
  for (const k of ['k1', 'k2', 'k3']) ledger(db, KIND, k, 100);
  const out = ruleOut((await run({ DB, ARCHIVE })).body);
  assert.equal(out.removed, 2, JSON.stringify(out));
  assert.equal(out.error, null);
  assert.deepEqual(rows(db, 'SELECT key, status FROM ledgers WHERE kind=?', KIND), [{ key: 'k2', status: 'fresh' }]);
  assert.equal(audits(db).at(-1).removed, 2);
});

test('R10d an archive that keeps an older row fails the count-back: the newer hot row is not deleted', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  on(db); recorded(db);
  await ensureArchiveTable({ DB, ARCHIVE }, 'ledgers');
  adb.prepare(`INSERT INTO ledgers (${COLS}, archived_at) VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(KIND, 'k1', 'stale', null, null, null, ago(300), ago(200), ago(150));
  ledger(db, KIND, 'k1', 100, 'current');
  // The upsert does not replace the archived row (a write that did not land).
  const keeps = {
    prepare: (sql) => ARCHIVE.prepare(sql.replace(/DO UPDATE SET[\s\S]*$/, 'DO NOTHING')),
    batch: (x) => ARCHIVE.batch(x),
  };
  const out = ruleOut((await run({ DB, ARCHIVE: keeps })).body);
  assert.match(String(out.error), /^archive copy not verified/, JSON.stringify(out));
  assert.equal(out.removed, 0);
  assert.deepEqual(rows(db, 'SELECT key, status FROM ledgers WHERE kind=?', KIND), [{ key: 'k1', status: 'current' }]);
});
