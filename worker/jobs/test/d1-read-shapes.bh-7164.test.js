// BH-7164: the three harness-jobs read shapes still over 5,000 rows a call on
// 2026-10-16 (cost_rows SUM(CASE) 129,155; job_artifacts join 8,293 and
// 12,072), each run through the REAL route on a D1 seeded at the BH-6727 live
// volume, with EXPLAIN QUERY PLAN on the statements the route ran.
//
//   C1 GET /api/progress/stamps: the fold is a rowid range, the raw reads are
//      ts ranges on idx_cost_rows_ts, the buckets a covering index range; no
//      full SCAN, no correlated subquery, every range under 5,000 rows
//   C2 the same spend answer as the old single query, at volume
//   C3 the edge rows on hand-built data, over three calls (no double count)
//   C4 windowParts: the window split decision table
//   C5 a summary read that throws: the legacy read gives the same answer
//   C6 a watermark above MAX(rowid): the buckets are cleared and refolded
//   C7 the retention rule for cost_project_hourly
//   A1 GET /api/artifacts?kind=&project=: walks idx_artifacts_kind_updated, no sort
//   A2 the same with since=: a kind + updated_at range, no sort
//
// The route reads its windows off the server clock, so every route call runs
// under a mocked Date pinned to a fixed offset into the fixture's hour.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { FOLD_SQL, windowParts } from '../src/lib/cost-hourly.js';
import { openVolumeDb, capturingD1, plan, NOW_ISO, isoAgo } from './lib/d1-volume.bh-6727.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const LIMIT = 5000;
const vol = await openVolumeDb();
const QS = '?spend_min=60&long_min=1440,10080&lookback_h=168';
// 37 min 13 s into the fixture's current hour: every window cut is mid-hour.
const VOL_NOW = Date.parse(NOW_ISO) + (37 * 60 + 13) * 1000;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function call(t, DB, path, now) {
  t.mock.timers.enable({ apis: ['Date'], now });
  try {
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
      headers: { authorization: `Bearer ${SECRET}` },
    }), { DB, HARNESS_SECRET: SECRET });
    assert.equal(res.status, 200, `${path} answered ${res.status}`);
    return await res.json();
  } finally { t.mock.timers.reset(); }
}
const planOf = (db, q) => plan(db, q.sql, ...q.binds.map((v) => (v === undefined ? null : v)));
const fullScan = (lines) => lines.filter((l) => /^SCAN (cost_rows|cost_project_hourly|job_artifacts|jobs|a|j)\b/.test(l));
const count = (db, sql, ...b) => Number(db.prepare(sql).get(...b).n);

// The cost read before BH-7164 and its JS, verbatim: the oracle.
const OLD_COST_SQL = (nLong) => `SELECT project, stage,
                  SUM(CASE WHEN ts >= ?2 THEN cost_usd ELSE 0 END) AS short_usd,
                  MAX(CASE WHEN ts >= ?3 THEN ts END) AS last_ts${Array.from({ length: nLong }, (_, i) =>
  `, SUM(CASE WHEN ts >= ?${i + 4} THEN cost_usd ELSE 0 END) AS l${i}`).join('')}
             FROM cost_rows
            WHERE ts >= ?1 AND COALESCE(cost_usd, 0) > 0
            GROUP BY project, stage`;
function oldAnswer(db, body) {
  const nowMs = Date.parse(body.as_of), longMins = body.long_min;
  const lookback = iso(nowMs - body.lookback_h * 3600000), shortCut = iso(nowMs - body.spend_min * 60000);
  const scanCut = iso(nowMs - Math.max(body.spend_min, body.lookback_h * 60, ...longMins) * 60000);
  const rows = db.prepare(OLD_COST_SQL(longMins.length)).all(scanCut, shortCut, lookback, ...longMins.map((w) => iso(nowMs - w * 60000)));
  const round = (n) => Math.round(Number(n || 0) * 100) / 100;
  const newer = (a, b) => (!a ? b || null : !b ? a : (a > b ? a : b));
  const out = {};
  for (const r of rows) {
    if (!r.project) continue;
    const p = out[r.project] ||= { spend: {}, spend_long: Object.fromEntries(longMins.map((w) => [w, 0])), cost: null };
    if (Number(r.short_usd) > 0) p.spend[r.stage || 'unknown'] = round((p.spend[r.stage || 'unknown'] || 0) + Number(r.short_usd));
    longMins.forEach((w, i) => { p.spend_long[w] = round(p.spend_long[w] + Number(r[`l${i}`] || 0)); });
    if (r.last_ts) p.cost = newer(p.cost, r.last_ts);
  }
  return out;
}
// The route's cost fields, keyed like oldAnswer. A project with no cost
// rows in any window has no cost fields to compare.
function newAnswer(body) {
  const out = {};
  for (const [name, p] of Object.entries(body.projects)) {
    if (!p.stamps.cost && !Object.keys(p.spend || {}).length && !Object.values(p.spend_long || {}).some((v) => v)) continue;
    out[name] = { spend: p.spend, spend_long: p.spend_long, cost: p.stamps.cost };
  }
  return out;
}

test('C1: GET /api/progress/stamps reads bounded ranges through indexes, under 5,000 rows each', { skip: !vol }, async (t) => {
  const db = vol.db;
  await call(t, capturingD1(db, []), `/api/progress/stamps${QS}`, VOL_NOW);  // the one-time history fold
  // Ten minutes of live writes (BH-6727 rate) land between the two calls.
  const ins = db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, cost_usd, inserted_at) VALUES (?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < 100; i++) ins.run('box-c1', `c1-${i}`, i, iso(VOL_NOW - i * 1000), 'alpha', 'build', 'claude', 0.01, iso(VOL_NOW));
  const mark = Number(db.prepare(`SELECT last_rowid AS m FROM cost_fold_mark WHERE name='progress.cost'`).get().m);
  assert.equal(count(db, 'SELECT COUNT(*) AS n FROM cost_rows WHERE rowid > ?', mark), 100, 'the fold range is the rows since the last call');

  const log = [];
  await call(t, capturingD1(db, log), `/api/progress/stamps${QS}`, VOL_NOW + 600e3);
  assert.equal(Number(db.prepare(`SELECT last_rowid AS m FROM cost_fold_mark WHERE name='progress.cost'`).get().m),
    count(db, 'SELECT MAX(rowid) AS n FROM cost_rows'), 'the mark advanced to MAX(rowid)');
  const costReads = log.filter((r) => /\b(cost_rows|cost_project_hourly)\b/.test(r.sql));
  assert.ok(!costReads.some((r) => /GROUP BY project, stage/.test(r.sql) && !/MATERIALIZED/.test(r.sql)), 'the old whole-window aggregate is gone');
  for (const q of costReads) {
    const lines = planOf(db, q);
    assert.deepEqual(fullScan(lines), [], `full scan:\n  ${lines.join('\n  ')}`);
    assert.ok(!lines.some((l) => /CORRELATED/.test(l)), lines.join(' | '));
  }
  // The fold: a rowid range of cost_rows.
  const fold = plan(db, FOLD_SQL[3]);
  assert.ok(fold.some((l) => /SEARCH cost_rows USING INTEGER PRIMARY KEY \(rowid>\?\)/.test(l)), fold.join(' | '));
  assert.deepEqual(fullScan(fold), [], fold.join(' | '));
  assert.ok(!fold.some((l) => /CORRELATED/.test(l)), fold.join(' | '));

  const R = costReads.find((r) => /WITH c AS MATERIALIZED/.test(r.sql));
  const E = costReads.find((r) => /ts < \?2/.test(r.sql));
  const B = costReads.find((r) => /FROM cost_project_hourly/.test(r.sql));
  assert.ok(R && E && B, `R, E and B all ran: ${costReads.map((r) => r.sql.slice(0, 60)).join(' || ')}`);
  for (const q of [R, E]) {
    const lines = planOf(db, q);
    assert.ok(lines.some((l) => /SEARCH cost_rows USING INDEX idx_cost_rows_ts \(ts>\?/.test(l)), lines.join(' | '));
  }
  const bl = planOf(db, B);
  assert.ok(bl.some((l) => /SEARCH cost_project_hourly USING COVERING INDEX idx_cost_project_hourly_hour \(hour>\? AND hour<\?\)/.test(l)), bl.join(' | '));

  // Rows each range read touches.
  const ranges = [
    ['R', count(db, 'SELECT COUNT(*) AS n FROM cost_rows WHERE ts >= ?', R.binds[0])],
    ...Array.from({ length: E.binds.length / 2 }, (_, k) =>
      [`E${k}`, count(db, 'SELECT COUNT(*) AS n FROM cost_rows WHERE ts >= ? AND ts < ?', E.binds[2 * k], E.binds[2 * k + 1])]),
    ['B', count(db, 'SELECT COUNT(*) AS n FROM cost_project_hourly WHERE hour >= ? AND hour < ?', B.binds[0], B.binds[1])],
  ];
  const before = count(db, `SELECT COUNT(*) AS n FROM cost_rows WHERE ts >= ?`, isoAgo(168));
  t.diagnostic(`rows per range (after): ${ranges.map(([k, n]) => `${k}=${n}`).join(' ')} fold=100; old single read: ${before}`);
  for (const [k, n] of ranges) assert.ok(n < LIMIT, `${k} reads ${n} rows`);
  assert.ok(before > LIMIT, `the fixture is at volume: the old read covers ${before} rows`);
});

test('C2: the spend answer at volume equals the old single query', { skip: !vol }, async (t) => {
  const body = await call(t, capturingD1(vol.db, []), `/api/progress/stamps${QS}`, VOL_NOW + 900e3);
  assert.deepEqual(body.errors, []);
  const want = oldAnswer(vol.db, body);
  assert.ok(Object.keys(want).length >= 10, 'the fixture spends in most projects');
  assert.ok(Object.values(want).some((p) => p.spend_long[10080] > 1), 'the week window has real spend');
  assert.deepEqual(newAnswer(body), want);
});

// Hand-built rows around a fixed clock: 22:37:13, hour H = 22:00.
const NOW3 = Date.parse('2026-10-16T22:37:13Z');
const ago = (min) => iso(NOW3 - min * 60000);
function seedEdges(db) {
  const c = db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES ('b',?,1,?,?,?,?,'2026-10-16T00:00:00Z')`);
  c.run('a-now', ago(10), 'alpha', 'execute', 1);          // current hour
  c.run('a-prev', '2026-10-16T21:50:00Z', 'alpha', 'plan', 2);  // last hour, inside the short window
  c.run('a-old-short', '2026-10-16T21:30:00Z', 'alpha', 'execute', 0.5);  // last hour, before the short cut
  c.run('a-edge-in', '2026-10-15T22:40:00Z', 'alpha', 'execute', 0.25);   // after the 1440 cut, in its edge hour
  c.run('a-edge-out', '2026-10-15T22:30:00Z', 'alpha', 'execute', 0.5);   // before the 1440 cut, same hour
  c.run('a-zero', ago(5), 'alpha', 'execute', 0);           // unpriced
  c.run('a-null', ago(5), 'alpha', 'execute', null);        // unpriced
  c.run('a-nots', null, 'alpha', 'execute', 9);             // no ts
  c.run('n-null', ago(5), null, 'execute', 9);              // no project
  c.run('n-empty', ago(5), '', 'execute', 9);               // '' project
  c.run('a-8d', ago(8 * 1440), 'alpha', 'execute', 9);      // outside every window
  c.run('b-3d', ago(3 * 1440), 'bravo', 'qa', 1.25);        // week only
  c.run('g-future', '2999-01-01T00:00:00Z', 'gamma', 'build', 4);  // a future ts counts in every window
}
const bucketsMatch = (db) => assert.deepEqual(
  db.prepare('SELECT project, hour, usd, n, max_ts FROM cost_project_hourly ORDER BY 1, 2').all().map((r) => ({ ...r })),
  db.prepare(`SELECT project, substr(ts, 1, 13) AS hour, SUM(cost_usd) AS usd, COUNT(*) AS n, MAX(ts) AS max_ts FROM cost_rows
               WHERE ts IS NOT NULL AND COALESCE(cost_usd, 0) > 0 AND project IS NOT NULL AND project <> ''
               GROUP BY 1, 2 ORDER BY 1, 2`).all().map((r) => ({ ...r })),
  'each bucket is the direct sum of its cost_rows');

test('C3: edge rows count once, in the right windows, over three calls', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  seedEdges(db);
  const b1 = await call(t, DB, `/api/progress/stamps${QS}`, NOW3);
  assert.deepEqual(b1.errors, []);
  assert.deepEqual(newAnswer(b1), oldAnswer(db, b1));
  const a = b1.projects.alpha;
  assert.deepEqual(a.spend, { execute: 1, plan: 2 });
  assert.deepEqual(a.spend_long, { 1440: 3.75, 10080: 4.25 });
  assert.equal(a.stamps.cost, ago(10));
  assert.deepEqual(b1.projects.bravo.spend_long, { 1440: 0, 10080: 1.25 });
  assert.deepEqual(b1.projects.gamma.spend, { build: 4 });
  assert.deepEqual(b1.projects.gamma.spend_long, { 1440: 4, 10080: 4 });
  assert.ok(!('' in b1.projects) && !('null' in b1.projects));
  bucketsMatch(db);

  // A late row with an old ts (an hour already folded) and a new current row.
  const c = db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES ('b',?,1,?,?,?,?,'2026-10-16T00:00:00Z')`);
  c.run('a-late', '2026-10-16T21:10:00Z', 'alpha', 'review', 0.75);
  c.run('a-now2', ago(1), 'alpha', 'execute', 0.25);
  const b2 = await call(t, DB, `/api/progress/stamps${QS}`, NOW3 + 30e3);
  assert.deepEqual(b2.projects.alpha.spend_long, { 1440: 4.75, 10080: 5.25 });
  assert.deepEqual(newAnswer(b2), oldAnswer(db, b2));
  bucketsMatch(db);
  const b3 = await call(t, DB, `/api/progress/stamps${QS}`, NOW3 + 30e3);
  assert.deepEqual(newAnswer(b3), newAnswer(b2), 'a call with no new rows changes nothing');
  bucketsMatch(db);
});

test('C4: windowParts splits a window into a raw edge, whole-hour buckets and the raw current hour', () => {
  const at = (s) => Date.parse(`2026-10-16T${s}Z`);
  const now = at('22:37:13');
  assert.deepEqual(windowParts(at('20:00:00'), now),
    { raw: '2026-10-16T22:00:00Z', edge: null, buckets: ['2026-10-16T20', '2026-10-16T22'] }, 'cut on the hour');
  assert.deepEqual(windowParts(at('20:15:00'), now),
    { raw: '2026-10-16T22:00:00Z', edge: ['2026-10-16T20:15:00Z', '2026-10-16T21:00:00Z'], buckets: ['2026-10-16T21', '2026-10-16T22'] }, 'cut mid-hour');
  assert.deepEqual(windowParts(at('21:15:00'), now),
    { raw: '2026-10-16T22:00:00Z', edge: ['2026-10-16T21:15:00Z', '2026-10-16T22:00:00Z'], buckets: null }, 'cut in the last hour');
  assert.deepEqual(windowParts(at('22:07:00'), now), { raw: '2026-10-16T22:07:00Z', edge: null, buckets: null }, 'cut inside the current hour');
  assert.deepEqual(windowParts(at('22:00:00'), now), { raw: '2026-10-16T22:00:00Z', edge: null, buckets: null }, 'cut = H');
  const w = windowParts(now - 720 * 3600e3, now);
  assert.equal((Date.parse(`${w.buckets[1]}:00:00Z`) - Date.parse(`${w.buckets[0]}:00:00Z`)) / 3600e3, 719, '30 days back, mid-hour');
  assert.equal(windowParts(at('22:00:00') - 720 * 3600e3, now).buckets[0], '2026-09-16T22', '30 days back, on the hour');
});

test('C5: a summary read that throws falls back to the old read, same answer, no error', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  seedEdges(db);
  const inner = d1(db);
  const DB = {
    prepare(sql) { if (/cost_project_hourly|cost_fold_mark/.test(sql)) throw new Error('no such table: cost_project_hourly'); return inner.prepare(sql); },
    batch: (s) => inner.batch(s),
  };
  const body = await call(t, DB, `/api/progress/stamps${QS}`, NOW3);
  assert.deepEqual(body.errors, []);
  assert.deepEqual(newAnswer(body), oldAnswer(db, body));
  assert.deepEqual(body.projects.alpha.spend_long, { 1440: 3.75, 10080: 4.25 });
});

test('C6: a watermark above MAX(rowid) clears the buckets and refolds', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  seedEdges(db);
  await call(t, DB, `/api/progress/stamps${QS}`, NOW3);
  // A renumbered table: the mark is past every rowid, and a bucket is stale.
  db.exec(`UPDATE cost_fold_mark SET last_rowid = last_rowid + 1000; UPDATE cost_project_hourly SET usd = 999`);
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES ('b','c6',1,'2026-10-16T20:10:00Z','alpha','qa',1,'x')`).run();
  const b = await call(t, DB, `/api/progress/stamps${QS}`, NOW3);
  assert.deepEqual(b.projects.alpha.spend_long, { 1440: 4.75, 10080: 5.25 });
  assert.deepEqual(newAnswer(b), oldAnswer(db, b));
  bucketsMatch(db);
  // The table emptied: no buckets are left to count.
  db.exec('DELETE FROM cost_rows');
  const e = await call(t, DB, `/api/progress/stamps${QS}`, NOW3);
  assert.deepEqual(newAnswer(e), {});
  assert.equal(count(db, 'SELECT COUNT(*) AS n FROM cost_project_hourly'), 0);
});

test('C7: retention removes old cost_project_hourly buckets through its hour index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'cost_project_hourly.age');
  assert.ok(r, 'the rule exists');
  assert.equal(r.key, 'retention.cost_project_hourly.days');
  assert.equal(db.prepare(`SELECT value FROM settings WHERE key = 'retention.cost_project_hourly.days'`).get().value, '400');
  const lines = plan(db, r.ids, '2026-01-01T00:00:00Z', 10);
  assert.ok(lines.some((l) => /idx_cost_project_hourly_hour \(hour<\?\)/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScan(lines), []);
  // A live run: a 500-day-old bucket goes, a recent one stays.
  const b = db.prepare(`INSERT INTO cost_project_hourly (project, hour, usd, n, max_ts) VALUES ('alpha', ?, 1, 1, ?)`);
  b.run(iso(NOW3 - 500 * 86400e3).slice(0, 13), iso(NOW3 - 500 * 86400e3));
  b.run(iso(NOW3 - 3600e3).slice(0, 13), iso(NOW3 - 3600e3));
  db.prepare(`UPDATE settings SET value = '0' WHERE key = 'retention.dry_run'`).run();
  t.mock.timers.enable({ apis: ['Date'], now: NOW3 });
  const res = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
  }), { DB, HARNESS_SECRET: SECRET });
  t.mock.timers.reset();
  assert.equal(res.status, 200);
  const out = (await res.json()).rules.find((x) => x.rule === 'cost_project_hourly.age');
  assert.equal(out.removed, 1, JSON.stringify(out));
  assert.deepEqual(db.prepare('SELECT hour FROM cost_project_hourly').all().map((x) => x.hour), [iso(NOW3 - 3600e3).slice(0, 13)]);
});

async function artifacts(t, path) {
  const log = [];
  const body = await call(t, capturingD1(vol.db, log), path, VOL_NOW);
  const q = log.find((r) => /FROM job_artifacts a JOIN jobs j/.test(r.sql));
  assert.ok(q, 'the artifact feed ran');
  return { body, lines: planOf(vol.db, q) };
}

test('A1: GET /api/artifacts?project=&kind= walks idx_artifacts_kind_updated newest first, no sort', { skip: !vol }, async (t) => {
  const { body, lines } = await artifacts(t, '/api/artifacts?project=alpha&kind=pr_url&limit=100');
  assert.ok(lines.some((l) => /SEARCH a USING INDEX idx_artifacts_kind_updated \(artifact_kind=\?\)/.test(l)), lines.join(' | '));
  assert.ok(lines.some((l) => /SEARCH j USING (INDEX sqlite_autoindex_jobs_1|PRIMARY KEY) \(id=\?\)/.test(l)), lines.join(' | '));
  assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScan(lines), []);
  assert.equal(body.artifacts.length, 100);
  const walked = count(vol.db, `SELECT COUNT(*) AS n FROM job_artifacts WHERE artifact_kind='pr_url' AND updated_at >= ?`, body.artifacts[99].updated_at);
  const before = count(vol.db, `SELECT COUNT(*) AS n FROM job_artifacts WHERE artifact_kind='pr_url'`);
  t.diagnostic(`artifact rows walked: ${walked} (old plan read and sorted ${before})`);
  assert.ok(walked < LIMIT, `walked ${walked}`);
});

test('A2: GET /api/artifacts?project=&kind=&since= reads a kind + updated_at range, no sort', { skip: !vol }, async (t) => {
  const since = isoAgo(24);
  const { body, lines } = await artifacts(t, `/api/artifacts?project=alpha&kind=pr_url&since=${since}&limit=100`);
  assert.ok(lines.some((l) => /SEARCH a USING INDEX idx_artifacts_kind_updated \(artifact_kind=\? AND updated_at>\?\)/.test(l)), lines.join(' | '));
  assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScan(lines), []);
  assert.ok(body.artifacts.length > 0 && body.artifacts.every((a) => a.updated_at > since && a.project === 'alpha'));
  const range = count(vol.db, `SELECT COUNT(*) AS n FROM job_artifacts WHERE artifact_kind='pr_url' AND updated_at > ?`, since);
  t.diagnostic(`artifact rows in range: ${range}`);
  assert.ok(range < LIMIT, `range ${range}`);
});
