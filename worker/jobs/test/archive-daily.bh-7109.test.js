// BH-7109 (Scope 4 + R5 of BH-6779): the stage_events_daily archive rule.
// Driven through the REAL worker.fetch (POST /api/retention/run) on node:sqlite
// with the composed jobs schema. ARCHIVE is a second, empty node:sqlite behind
// the same D1 shim. Every time is an offset from one clock anchor.
//
//   A1 the rule moves old rows with the same values; newer rows stay
//   A2 a failed copy deletes nothing
//   A3 unbound ARCHIVE (absent, or {} with no prepare) = "archive not bound", no delete
//   A4 an archived key with a different n is not deleted, and not overwritten
//   A5 a re-run after a copy that landed (hot delete lost) moves all, no duplicate
//   A6 off by default: seeded '0', no ARCHIVE call, no audit row
//   A7 the cutoff day stays; the day before it moves
//   A8 EXPLAIN QUERY PLAN: every hot and archive read uses an index
//   A9 multi-batch: retention.batch=2 moves 5 rows in one run
//   A10 a row whose n grows between the copy and the delete stays in hot
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const day = (daysAgo) => new Date(NOW - daysAgo * 86400e3).toISOString().slice(0, 10);
const RULE = 'stage_events_daily.archive';
const COLS = 'day, stage, verdict, actor, n';

async function archiveDb(hooks = {}) {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  let prepares = 0;
  const inner = d1(db, hooks);
  const ARCHIVE = { ...inner, prepare(sql) { prepares++; return inner.prepare(sql); } };
  return { db, ARCHIVE, prepares: () => prepares };
}
async function run(env, body = {}) {
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { HARNESS_SECRET: SECRET, ...env });
  const b = await res.json().catch(() => null);
  return { status: res.status, body: b, rule: b && b.rules ? b.rules.find((x) => x.rule === RULE) : null };
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', day(0));
}
const daily = (db, d, stage, n, verdict = 'OK', actor = 'box-a') =>
  db.prepare(`INSERT INTO stage_events_daily (${COLS}) VALUES (?,?,?,?,?)`).run(d, stage, verdict, actor, n);
const rows = (db) => db.prepare(`SELECT ${COLS} FROM stage_events_daily ORDER BY day, stage, verdict, actor`).all().map((x) => ({ ...x }));
const ARCH_DDL = `CREATE TABLE stage_events_daily (day TEXT NOT NULL, stage TEXT NOT NULL, verdict TEXT NOT NULL,
  actor TEXT NOT NULL, n INTEGER NOT NULL, archived_at TEXT NOT NULL, PRIMARY KEY (day, stage, verdict, actor))`;

// 4 rows older than 30 days, 2 newer.
function seedSix(db) {
  daily(db, day(100), 'plan', 3); daily(db, day(90), 'review', 7, 'APPROVE');
  daily(db, day(60), 'review', 1, ''); daily(db, day(45), 'merge', 2, 'MERGED', 'box-b');
  daily(db, day(10), 'plan', 4); daily(db, day(2), 'review', 9);
}
async function setup({ days = 30, live = true, hooks = {}, archHooks = {} } = {}) {
  const o = await openDb(hooks);
  if (!o) return null;
  if (live) setting(o.db, 'retention.dry_run', '0');
  if (days !== null) setting(o.db, 'retention.stage_events_daily.archive_days', days);
  const a = await archiveDb(archHooks);
  return { ...o, arch: a };
}

test('A1 the rule moves old rows with the same values; newer rows stay', async (t) => {
  const s = await setup(); if (!s) return t.skip('node:sqlite unavailable');
  seedSix(s.db);
  const old = rows(s.db).slice(0, 4);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.rule.error, null);
  assert.equal(r.rule.removed, 4);
  assert.deepEqual(rows(s.db).map((x) => x.day), [day(10), day(2)]);
  assert.deepEqual(rows(s.arch.db), old, 'the archive holds the 4 old rows with the same values');
  assert.ok(s.arch.db.prepare('SELECT archived_at FROM stage_events_daily').all().every((x) => /^\d{4}-\d\d-\d\dT/.test(x.archived_at)));
  const audit = s.db.prepare('SELECT removed, error FROM retention_runs WHERE rule = ?').all(RULE).map((x) => ({ ...x }));
  assert.deepEqual(audit, [{ removed: 4, error: null }]);
});

test('A2 a failed copy deletes nothing', async (t) => {
  const s = await setup({ archHooks: { beforeRun(sql) { if (/^\s*INSERT/i.test(sql)) throw new Error('disk full'); } } });
  if (!s) return t.skip('node:sqlite unavailable');
  seedSix(s.db);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.status, 200);
  assert.match(r.rule.error, /^archive copy failed/);
  assert.equal(r.rule.removed, 0);
  assert.equal(rows(s.db).length, 6, 'hot keeps every row');
  const audit = s.db.prepare('SELECT removed, error FROM retention_runs WHERE rule = ?').get(RULE);
  assert.equal(audit.removed, 0); assert.match(audit.error, /^archive copy failed: disk full/);
});

test('A3 unbound ARCHIVE means "archive not bound" and no delete, real run and dry run', async (t) => {
  for (const [label, env, live] of [['absent', {}, true], ['no prepare', { ARCHIVE: {} }, true], ['absent, dry run', {}, false]]) {
    const s = await setup({ live }); if (!s) return t.skip('node:sqlite unavailable');
    seedSix(s.db);
    const r = await run({ DB: s.DB, ...env });
    assert.equal(r.status, 200, label);
    assert.equal(r.rule.error, 'archive not bound', label);
    assert.equal(r.rule.removed, 0, label);
    assert.equal(r.rule.counted, 0, label);
    assert.equal(rows(s.db).length, 6, `${label}: hot keeps every row`);
    assert.deepEqual(r.body.rules.filter((x) => x.error).map((x) => x.rule), [RULE], `${label}: only this rule errors`);
  }
});

test('A4 an archived key with a different n stays in hot, and the archive keeps its n', async (t) => {
  const s = await setup(); if (!s) return t.skip('node:sqlite unavailable');
  seedSix(s.db);
  s.arch.db.exec(ARCH_DDL);
  s.arch.db.prepare(`INSERT INTO stage_events_daily (${COLS}, archived_at) VALUES (?,?,?,?,?,?)`).run(day(90), 'review', 'APPROVE', 'box-a', 5, 'x');
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.match(r.rule.error || '', /1 of 4/);
  assert.equal(r.rule.removed, 3);
  assert.deepEqual(rows(s.db).map((x) => [x.day, x.n]), [[day(90), 7], [day(10), 4], [day(2), 9]]);
  assert.equal(s.arch.db.prepare('SELECT n FROM stage_events_daily WHERE day = ?').get(day(90)).n, 5, 'nothing overwritten');
  assert.equal(s.arch.db.prepare('SELECT COUNT(*) c FROM stage_events_daily').get().c, 4);
});

test('A5 a re-run after a copy that landed moves all rows, no duplicate', async (t) => {
  const s = await setup(); if (!s) return t.skip('node:sqlite unavailable');
  seedSix(s.db);
  const old = rows(s.db).slice(0, 4);
  s.arch.db.exec(ARCH_DDL);
  const ins = s.arch.db.prepare(`INSERT INTO stage_events_daily (${COLS}, archived_at) VALUES (?,?,?,?,?,'earlier')`);
  for (const x of old.slice(0, 2)) ins.run(x.day, x.stage, x.verdict, x.actor, x.n);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.rule.error, null);
  assert.equal(r.rule.removed, 4);
  assert.deepEqual(rows(s.arch.db), old);
  assert.equal(rows(s.db).length, 2);
});

test('A6 off by default: the seeded row is 0, ARCHIVE is never called, no audit row', async (t) => {
  const s = await setup({ days: null }); if (!s) return t.skip('node:sqlite unavailable');
  assert.equal(s.db.prepare("SELECT value FROM settings WHERE key = 'retention.stage_events_daily.archive_days'").get()?.value, '0');
  seedSix(s.db);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.rule.off, true);
  assert.equal(r.rule.error, null);
  assert.equal(s.arch.prepares(), 0);
  assert.equal(rows(s.db).length, 6);
  assert.equal(s.db.prepare('SELECT COUNT(*) c FROM retention_runs WHERE rule = ?').get(RULE).c, 0);
});

test('A7 the cutoff day stays; the day before it moves', async (t) => {
  const s = await setup(); if (!s) return t.skip('node:sqlite unavailable');
  daily(s.db, day(32), 'a', 1); daily(s.db, day(31), 'b', 1); daily(s.db, day(30), 'c', 1); daily(s.db, day(29), 'd', 1);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.rule.removed, 2, JSON.stringify(r.rule));
  assert.deepEqual(rows(s.db).map((x) => x.stage), ['c', 'd']);
});

test('A8 every hot and archive read of the rule uses an index (5,000 seeded rows)', async (t) => {
  const s = await setup(); if (!s) return t.skip('node:sqlite unavailable');
  const { RULES } = await import('../src/routes/retention.js');
  const { COPY_SQL, VERIFY_SQL, HOT_READ_SQL } = await import('../src/lib/archive-daily.js');
  const r = RULES.find((x) => x.rule === RULE);
  const ins = s.db.prepare(`INSERT INTO stage_events_daily (${COLS}) VALUES (?,?,?,?,?)`);
  for (let i = 0; i < 5000; i++) ins.run(day(40 + (i % 900)), `s${i % 7}`, 'OK', `box-${Math.floor(i / 6300)}${i}`, 1);
  s.db.exec('ANALYZE');
  const plan = (db, sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
  const ids = plan(s.db, r.ids, `${day(30)}T00:00:00Z`, 10);
  assert.ok(ids.some((l) => /USING (COVERING )?INDEX sqlite_autoindex_stage_events_daily_1/.test(l)), ids.join(' | '));
  for (const [sql, b] of [[r.del, '[{"id":1,"n":1}]'], [HOT_READ_SQL, '[1]']]) {
    const lines = plan(s.db, sql, b);
    assert.ok(!lines.some((l) => /^SCAN (stage_events_daily|d)\b/.test(l)), lines.join(' | '));
    assert.ok(lines.some((l) => /^SEARCH stage_events_daily USING INTEGER PRIMARY KEY/.test(l)), lines.join(' | '));
  }
  // The archive after a 5,000-row copy.
  const hot = s.db.prepare(`SELECT ${COLS} FROM stage_events_daily`).all().map((x) => ({ ...x }));
  s.arch.db.exec(ARCH_DDL);
  s.arch.db.prepare(COPY_SQL).run(JSON.stringify(hot), 'now');
  s.arch.db.exec('ANALYZE');
  for (const [sql, b] of [[VERIFY_SQL, ['[]']], ['SELECT MAX(day) AS d FROM stage_events_daily', []]]) {
    const lines = plan(s.arch.db, sql, ...b);
    assert.ok(!lines.some((l) => /^SCAN (stage_events_daily|a)\b(?!.*USING)/.test(l)), lines.join(' | '));
    assert.ok(lines.some((l) => /^SEARCH (stage_events_daily|a) USING (COVERING )?INDEX sqlite_autoindex_stage_events_daily_1/.test(l)), lines.join(' | '));
  }
  assert.equal(s.arch.db.prepare('SELECT COUNT(*) c FROM stage_events_daily').get().c, 5000);
});

test('A9 multi-batch: batch=2 moves all 5 old rows in one run', async (t) => {
  const s = await setup(); if (!s) return t.skip('node:sqlite unavailable');
  setting(s.db, 'retention.batch', 2);
  for (let i = 0; i < 5; i++) daily(s.db, day(50 + i), `s${i}`, i + 1);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.rule.error, null);
  assert.equal(r.rule.removed, 5);
  assert.equal(r.rule.backlog, false);
  assert.equal(rows(s.db).length, 0);
  assert.equal(s.arch.db.prepare('SELECT SUM(n) s FROM stage_events_daily').get().s, 15);
});

test('A10 a row whose n grows between the copy and the hot delete stays in hot', async (t) => {
  let s;
  const hooks = { beforeRun(sql) {
    if (/DELETE FROM stage_events_daily/.test(sql)) s.db.prepare("UPDATE stage_events_daily SET n = n + 1 WHERE stage = 'plan' AND day = ?").run(day(100));
  } };
  s = await setup({ hooks }); if (!s) return t.skip('node:sqlite unavailable');
  seedSix(s.db);
  const r = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r.rule.removed, 3);
  assert.match(r.rule.error || '', /1 of 4/);
  assert.deepEqual(rows(s.db).map((x) => [x.day, x.n]), [[day(100), 4], [day(10), 4], [day(2), 9]], 'the grown row keeps its new n');
});

// The invariant for A11/A12: every event is counted exactly once, in
// stage_events, in the hot rollup, or in the archive.
function total(s) {
  const one = (db, sql) => Number(db.prepare(sql).get().c || 0);
  const arch = s.arch.db.prepare("SELECT name FROM sqlite_master WHERE name = 'stage_events_daily'").get()
    ? one(s.arch.db, 'SELECT SUM(n) c FROM stage_events_daily') : 0;
  return one(s.db, 'SELECT COUNT(*) c FROM stage_events') + one(s.db, 'SELECT SUM(n) c FROM stage_events_daily') + arch;
}
const ev = (db, jobId, daysAgo) => db.prepare(
  `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at) VALUES (?, 'review', 'APPROVE', 'box-a', NULL, ?)`,
).run(jobId, new Date(NOW - daysAgo * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z'));

test('A11 a day whose events drain over runs moves only after its last rollup; an equal n never loses a count', async (t) => {
  const s = await setup({ days: 400 }); if (!s) return t.skip('node:sqlite unavailable');
  setting(s.db, 'retention.max_rows', 1);
  ev(s.db, 'gone-1', 500); ev(s.db, 'gone-2', 500);
  const r1 = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r1.rule.error, null);
  assert.equal(r1.rule.removed, 0, 'the day still has an event in stage_events, so it stays in hot');
  assert.deepEqual(rows(s.db).map((x) => x.n), [1]);
  assert.equal(total(s), 2);
  const r2 = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r2.rule.error, null);
  assert.equal(r2.rule.removed, 1);
  assert.equal(total(s), 2);
  await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(total(s), 2, 'two events, counted once each');
  assert.deepEqual(rows(s.arch.db), [{ day: day(500), stage: 'review', verdict: 'APPROVE', actor: 'box-a', n: 2 }]);
  assert.equal(rows(s.db).length, 0);
});

test('A12 a day with an event of a running job stays in hot until that event rolls up', async (t) => {
  const s = await setup({ days: 400 }); if (!s) return t.skip('node:sqlite unavailable');
  const job = (status) => s.db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
    VALUES ('j-run', 'p', 'T-1', 'build', 'b', 'review', ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET status = excluded.status`).run(status, day(500), day(500));
  job('running');
  ev(s.db, 'j-run', 500); ev(s.db, 'gone-1', 500);
  const r1 = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r1.rule.removed, 0);
  assert.deepEqual(rows(s.db).map((x) => x.n), [1]);
  assert.equal(total(s), 2);
  job('done');
  const r2 = await run({ DB: s.DB, ARCHIVE: s.arch.ARCHIVE });
  assert.equal(r2.rule.error, null);
  assert.equal(r2.rule.removed, 1);
  assert.equal(total(s), 2);
  assert.equal(s.arch.db.prepare('SELECT n FROM stage_events_daily').get().n, 2);
});
