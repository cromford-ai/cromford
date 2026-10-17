// BH-6774 C0: the archive store. Cold history moves from the hot harness-jobs
// D1 (env.DB) to a second D1, harness-archive (env.ARCHIVE), through the
// retention run (POST /api/retention/run, BH-6750). Driven through the REAL
// worker.fetch: the hot store is node:sqlite with the composed jobs schema, the
// archive store is an EMPTY node:sqlite database (the worker creates its
// tables). Every time is an offset from one clock anchor.
//
//   A1 cost_rows past retention.cost_rows.archive_days move: the archive has
//      them with the same values (plus archived_at), the hot store no longer
//      has them, recent rows stay, the audit row counts them
//   A2 a failed archive write deletes nothing from the hot store
//   A3 ARCHIVE unbound: nothing is deleted, the audit row says "archive not bound"
//   A4 the default (archive_days 0) leaves cost_rows alone, and no ledger rule exists
//   A5 stage_events with retention.stage_events.archive=1: old events of closed
//      jobs are copied to the archive, then rolled up and removed; unbound =
//      nothing removed; the flag off = the BH-6750 behaviour, no archive write
//   A6 a resend after a cursor reset: rows already in the archive are not
//      inserted into the hot store again; an old row never archived is; a
//      push of only recent rows does not read the archive
//   A7 GET /api/metrics/cost-rows over a range that spans the cutoff returns
//      the same rows before and after the move
//   A8 the cost_rows archive read uses an index (EXPLAIN QUERY PLAN), and the
//      archive tables carry an index on their time column
//   A9 a column added to the hot table later appears in the archive table
//   Fix round of the lead review on 9a53d31e8:
//   A10 a resend chunk made only of archived rows is a 200, not a 400
//   A11 a retry after a failed hot delete carries the newer hot values to the archive
//   A12 retention.cost_rows.archive_days below the 60-day floor runs as 60
//   A13 the archive table check runs once per run, not once per batch
//   A14 a dry run of an archive rule counts while ARCHIVE is unbound
//   A15 an unreadable archive: GET answers the hot rows, POST logs one ALERT line
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function stores(archiveHooks = {}, hotHooks = {}) {
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
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}
const count = (db, sql, ...b) => db.prepare(sql).get(...b).n;
const hasTable = (adb, t) => !!adb.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(t);
function costRow(db, hash, daysAgo, usd = 1.25, box = 'box-a') {
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, model, cost_usd, raw, inserted_at)
              VALUES (?,?,?,?,?,?,?,?,?,?)`)
    .run(box, hash, Number(hash.replace(/\D/g, '') || 1), ago(daysAgo), 'proj', 'execute', 'm-x', usd, `raw,${hash}`, ago(daysAgo));
}
function pushRow(hash, daysAgo, usd = 1.25) {
  return { row_hash: hash, line_no: Number(hash.replace(/\D/g, '') || 1), ts: ago(daysAgo), project: 'proj',
           stage: 'execute', model: 'm-x', cost_usd: usd, raw: `raw,${hash}` };
}
function job(db, id, status) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?, 'p', 'T-1', 'build', 'b', 'done', ?, ?, ?)`).run(id, status, ago(200), ago(200));
}
function event(db, jobId, stage, daysAgo) {
  db.prepare(`INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at) VALUES (?,?,?,?,NULL,?)`)
    .run(jobId, stage, 'OK', 'box-a', ago(daysAgo));
}
const COLS = 'box, row_hash, line_no, ts, project, stage, model, cost_usd, raw, inserted_at';
const costRule = (body) => (body.rules || []).find((x) => x.rule === 'cost_rows.archive');

test('A1 old cost_rows move to the archive with the same values; recent rows stay', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120, 1.5); costRow(db, 'h2', 100, 2.25); costRow(db, 'h3', 10, 3);
  const before = db.prepare(`SELECT ${COLS} FROM cost_rows WHERE row_hash IN ('h1','h2') ORDER BY row_hash`).all().map((x) => ({ ...x }));
  const r = await run({ DB, ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT row_hash FROM cost_rows ORDER BY row_hash').all().map((x) => x.row_hash), ['h3']);
  const moved = adb.prepare(`SELECT ${COLS}, archived_at FROM cost_rows ORDER BY row_hash`).all().map((x) => ({ ...x }));
  assert.deepEqual(moved.map(({ archived_at, ...rest }) => rest), before, 'the archive holds the same values');
  assert.ok(moved.every((x) => /^\d{4}-\d\d-\d\dT/.test(x.archived_at)), 'archived_at is set');
  const rule = costRule(r.body);
  assert.equal(rule.removed, 2); assert.equal(rule.error, null);
  const audit = db.prepare("SELECT removed, error FROM retention_runs WHERE rule='cost_rows.archive'").get();
  assert.equal(audit.removed, 2); assert.equal(audit.error, null);
});

test('A2 a failed archive write deletes nothing', async (t) => {
  const s = await stores({ beforeRun: (sql) => { if (/^\s*INSERT/i.test(sql)) throw new Error('archive write refused'); } });
  if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120); costRow(db, 'h2', 100);
  const r = await run({ DB, ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 2, 'nothing left the hot store');
  const rule = costRule(r.body);
  assert.equal(rule.removed, 0);
  assert.match(String(rule.error), /archive/i);
});

test('A3 ARCHIVE unbound: nothing is deleted, the audit row says "archive not bound"', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120);
  const r = await run({ DB });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 1);
  assert.equal(costRule(r.body).error, 'archive not bound');
  assert.equal(db.prepare("SELECT error FROM retention_runs WHERE rule='cost_rows.archive'").get().error, 'archive not bound');
});

test('A4 the default leaves cost_rows alone, and no ledger rule exists', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0');
  costRow(db, 'h1', 900);
  db.prepare(`INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES ('merge','k','merged',?,?)`).run(ago(900), ago(900));
  const r = await run({ DB, ARCHIVE });
  assert.equal(r.status, 200);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 1);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM ledgers'), 1);
  assert.equal(costRule(r.body).off, true, 'retention.cost_rows.archive_days defaults to 0 (off)');
  assert.ok(!r.body.rules.some((x) => x.table === 'ledgers'), 'no ledger kind moves by default');
  assert.equal(hasTable(adb, 'cost_rows'), false, 'an off rule writes nothing to the archive');
});

test('A5 stage_events: the archive flag copies before the rollup and delete; unbound or off behave', async (t) => {
  for (const mode of ['on', 'unbound', 'off']) {
    const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
    const { db, DB, adb, ARCHIVE } = s;
    setting(db, 'retention.dry_run', '0');
    if (mode !== 'off') setting(db, 'retention.stage_events.archive', '1');
    job(db, 'c1', 'done');
    event(db, 'c1', 'review', 120); event(db, 'c1', 'plan', 130); event(db, 'c1', 'merge', 5);
    const env = mode === 'unbound' ? { DB } : { DB, ARCHIVE };
    const r = await run(env);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const rule = r.body.rules.find((x) => x.rule === 'stage_events.closed');
    if (mode === 'on') {
      assert.equal(count(db, 'SELECT COUNT(*) n FROM stage_events'), 1, 'on: the old events left the hot store');
      assert.equal(count(adb, 'SELECT COUNT(*) n FROM stage_events'), 2, 'on: the archive has both');
      assert.equal(count(db, 'SELECT COALESCE(SUM(n),0) n FROM stage_events_daily'), 2, 'on: the rollup still runs');
    } else if (mode === 'unbound') {
      assert.equal(count(db, 'SELECT COUNT(*) n FROM stage_events'), 3, 'unbound: nothing removed');
      assert.equal(rule.error, 'archive not bound');
    } else {
      assert.equal(count(db, 'SELECT COUNT(*) n FROM stage_events'), 1, 'off: BH-6750 removes them');
      assert.equal(hasTable(adb, 'stage_events'), false, 'off: no archive write');
    }
  }
});

test('A6 a resend after a cursor reset does not put archived rows back in the hot store', async (t) => {
  let archiveReads = 0;
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  const spy = { ...ARCHIVE, prepare(sql) { if (/^\s*SELECT/i.test(sql)) archiveReads++; return ARCHIVE.prepare(sql); } };
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120); costRow(db, 'h2', 100); costRow(db, 'h3', 10);
  assert.equal((await run({ DB, ARCHIVE })).status, 200);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 1);
  // The box's cursor reset: it resends its whole file, h1-h3, plus h4, an old row the hot store never had.
  const resend = await call({ DB, ARCHIVE: spy }, 'POST', '/api/metrics/cost-rows',
    { box: 'box-a', rows: [pushRow('h1', 120), pushRow('h2', 100), pushRow('h3', 10), pushRow('h4', 110)] });
  assert.equal(resend.status, 200, JSON.stringify(resend.body));
  assert.deepEqual(db.prepare('SELECT row_hash FROM cost_rows ORDER BY row_hash').all().map((x) => x.row_hash), ['h3', 'h4'],
    'h1 and h2 are in the archive and stay out of the hot store; h4 was never archived and lands');
  assert.equal(resend.body.skipped_archived, 2);
  archiveReads = 0;
  const fresh = await call({ DB, ARCHIVE: spy }, 'POST', '/api/metrics/cost-rows',
    { box: 'box-a', rows: [pushRow('h5', 0), pushRow('h6', 0)] });
  assert.equal(fresh.status, 200);
  assert.equal(archiveReads, 0, 'a push of recent rows does not read the archive');
});

test('A7 a cost-rows read that spans the cutoff returns the same rows after the move', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  setting(db, 'retention.cost_rows.archive_days', '90');
  for (const [h, d] of [['h1', 150], ['h2', 120], ['h3', 95], ['h4', 60], ['h5', 2]]) costRow(db, h, d);
  const q = `/api/metrics/cost-rows?since=${encodeURIComponent(ago(200))}&until=${encodeURIComponent(ago(1))}&limit=50`;
  const pick = (b) => b.cost_rows.map((x) => `${x.box}/${x.row_hash}/${x.ts}/${x.cost_usd}`);
  const before = await call({ DB, ARCHIVE }, 'GET', q);
  setting(db, 'retention.dry_run', '0');
  assert.equal((await run({ DB, ARCHIVE })).status, 200);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 2, 'three rows moved');
  const after = await call({ DB, ARCHIVE }, 'GET', q);
  assert.equal(after.status, 200, JSON.stringify(after.body));
  assert.deepEqual(pick(after.body), pick(before.body), 'same rows, same order (newest first)');
  const page = await call({ DB, ARCHIVE }, 'GET', `/api/metrics/cost-rows?limit=3`);
  assert.deepEqual(page.body.cost_rows.map((x) => x.row_hash), ['h5', 'h4', 'h3'], 'a page that crosses into the archive is still newest first');
});

test('A8 the archive reads use indexes', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  const plan = (d, sql, ...b) => d.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail).join(' | ');
  const p = plan(db, 'SELECT rowid AS id FROM cost_rows WHERE ts < ?1 ORDER BY ts LIMIT ?2', ago(90), 500);
  assert.match(p, /USING (COVERING )?INDEX idx_cost_rows_ts/, p);
  assert.doesNotMatch(p, /SCAN cost_rows(?! USING)/, p);
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  setting(db, 'retention.stage_events.archive', '1');
  costRow(db, 'h1', 120); job(db, 'c1', 'done'); event(db, 'c1', 'plan', 120);
  assert.equal((await run({ DB, ARCHIVE })).status, 200);
  const a1 = plan(adb, 'SELECT MAX(ts) AS m FROM cost_rows');
  assert.match(a1, /INDEX/, `archive cost_rows MAX(ts): ${a1}`);
  const a2 = plan(adb, "SELECT row_hash FROM cost_rows WHERE box=?1 AND row_hash IN (SELECT value FROM json_each(?2))", 'b', '[]');
  assert.match(a2, /USING (COVERING )?(INDEX|PRIMARY KEY)/, `archive dedupe read: ${a2}`);
  const a3 = plan(adb, 'SELECT * FROM stage_events WHERE created_at < ?1', ago(1));
  assert.match(a3, /INDEX/, `archive stage_events range: ${a3}`);
});

test('A9 a column added to the hot table later appears in the archive table', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120);
  assert.equal((await run({ DB, ARCHIVE })).status, 200);
  db.exec('ALTER TABLE cost_rows ADD COLUMN probe_new TEXT');
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, inserted_at, probe_new) VALUES ('box-a','h2',2,?,?,'v')`).run(ago(100), ago(100));
  assert.equal((await run({ DB, ARCHIVE })).status, 200);
  assert.equal(adb.prepare("SELECT probe_new FROM cost_rows WHERE row_hash='h2'").get().probe_new, 'v');
});

test('A10 a resend chunk made only of archived rows is accepted (200), so the cursor moves', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120); costRow(db, 'h2', 100);
  assert.equal((await run({ DB, ARCHIVE })).status, 200);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 0);
  const r = await call({ DB, ARCHIVE }, 'POST', '/api/metrics/cost-rows',
    { box: 'box-a', rows: [pushRow('h1', 120), pushRow('h2', 100)] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.accepted, 0); assert.equal(r.body.inserted, 0); assert.equal(r.body.skipped_archived, 2);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 0, 'nothing came back to the hot store');
  const bad = await call({ DB, ARCHIVE }, 'POST', '/api/metrics/cost-rows', { box: 'box-a', rows: [{ ts: ago(1) }] });
  assert.equal(bad.status, 400, 'a chunk with no valid row is still a 400');
});

test('A11 a retry after a failed hot delete carries the newer hot values to the archive', async (t) => {
  let failDelete = true;
  const s = await stores({}, { beforeRun: (sql) => {
    if (failDelete && /^\s*DELETE FROM cost_rows/i.test(sql)) throw new Error('D1_ERROR: overloaded');
  } });
  if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120);
  const r1 = await run({ DB, ARCHIVE });
  assert.equal(r1.status, 200);
  assert.match(String(costRule(r1.body).error), /overloaded/);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 1, 'the failed delete left the hot row');
  assert.equal(adb.prepare("SELECT lane_id FROM cost_rows WHERE row_hash='h1'").get().lane_id, null);
  // The lane backfill (or a resend) fills lane_id in the hot row after the copy.
  db.prepare("UPDATE cost_rows SET lane_id='lane-7' WHERE row_hash='h1'").run();
  failDelete = false;
  const r2 = await run({ DB, ARCHIVE });
  assert.equal(r2.status, 200);
  assert.equal(costRule(r2.body).error, null);
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 0, 'the hot row moved');
  assert.equal(adb.prepare("SELECT lane_id FROM cost_rows WHERE row_hash='h1'").get().lane_id, 'lane-7',
    'the archive holds the newer value, not the first copy');
});

test('A12 an archive_days below the 60-day floor runs as 60', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, adb, ARCHIVE } = s;
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '10');
  costRow(db, 'h1', 70); costRow(db, 'h2', 30);
  const r = await run({ DB, ARCHIVE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT row_hash FROM cost_rows').all().map((x) => x.row_hash), ['h2'],
    'a 30-day-old row stays: hot-only readers look back up to 60 days');
  assert.equal(count(adb, 'SELECT COUNT(*) n FROM cost_rows'), 1);
  const cut = Date.parse(costRule(r.body).cutoff);
  assert.ok(Math.abs(cut - (NOW - 60 * 86400e3)) < 3600e3, `cutoff is 60 days back: ${costRule(r.body).cutoff}`);
});

test('A13 the archive table check runs once per run, not once per batch', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB, ARCHIVE } = s;
  let pragmas = 0;
  const spy = { ...ARCHIVE, prepare(sql) { if (/PRAGMA table_info/i.test(sql)) pragmas++; return ARCHIVE.prepare(sql); } };
  setting(db, 'retention.dry_run', '0'); setting(db, 'retention.cost_rows.archive_days', '90');
  setting(db, 'retention.batch', '1');
  costRow(db, 'h1', 120); costRow(db, 'h2', 110); costRow(db, 'h3', 100);
  const r = await run({ DB, ARCHIVE: spy });
  assert.equal(r.status, 200);
  assert.equal(costRule(r.body).removed, 3, 'three batches of one row');
  assert.equal(pragmas, 1, 'one PRAGMA table_info on the archive for the run');
});

test('A14 a dry run of an archive rule counts while ARCHIVE is unbound', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB } = s;
  setting(db, 'retention.cost_rows.archive_days', '90');
  costRow(db, 'h1', 120); costRow(db, 'h2', 100); costRow(db, 'h3', 10);
  const r = await run({ DB });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const rule = costRule(r.body);
  assert.equal(rule.counted, 2, 'the operator sees the estimate before the binding exists');
  assert.equal(rule.error, 'archive not bound');
  assert.equal(count(db, 'SELECT COUNT(*) n FROM cost_rows'), 3);
});

test('A15 an unreadable archive: GET answers the hot rows, POST logs one ALERT line', async (t) => {
  const s = await stores(); if (!s) return t.skip('node:sqlite unavailable');
  const { db, DB } = s;
  costRow(db, 'h1', 120); costRow(db, 'h5', 2);
  const broken = { prepare() { throw new Error('D1_ERROR: archive down'); }, batch() { throw new Error('D1_ERROR: archive down'); } };
  const g = await call({ DB, ARCHIVE: broken }, 'GET', '/api/metrics/cost-rows?limit=50');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.deepEqual(g.body.cost_rows.map((x) => x.row_hash), ['h5', 'h1']);
  assert.equal(g.body.archive, 'unreadable');
  const lines = [];
  const orig = console.log;
  console.log = (...a) => { lines.push(a.join(' ')); };
  let p;
  try {
    p = await call({ DB, ARCHIVE: broken }, 'POST', '/api/metrics/cost-rows', { box: 'box-a', rows: [pushRow('h9', 100)] });
  } finally { console.log = orig; }
  assert.equal(p.status, 503);
  assert.equal(lines.filter((l) => /^ALERT cost-rows: archive unreadable/.test(l)).length, 1, lines.join('\n'));
});
