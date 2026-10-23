// BH-6974 (wave 1 of #6545): GET /api/metrics/gh-ledger?group= — the grouped
// reads bin/gh-budget-report.sh prints "who spends the GitHub budget" from.
//
// Driven through the REAL worker.fetch on a node:sqlite D1 with the composed
// schema (bearer, router, table and SQL all under test):
//   G1  no `group`: the answer keeps its old shape (box rows, no totals)
//   G1b two boxes, one (hour, lane): one lane-hour row, summed
//   G2  the REST / GraphQL decision table: graphql rows never reach `rows`,
//       and land in totals.graphql_*
//   G3  the path class -> repo decision table, on GH_LEDGER_REPO_SQL and
//       through group=repo
//   G4  group=bogus is a 400; a grouped read with no `since` is a 400
//   G5  6,000 lane-hour cells: truncated at 5,000 rows, totals still exact
//   G6  150,000 rows over 14 days: every grouped read and the totals read is
//       served by idx_gh_ledger_hour, with no full SCAN of gh_ledger
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';
import {
  GH_LEDGER_GROUPS, GH_LEDGER_REPO_SQL, GH_LEDGER_REPO_REST_SQL,
} from '../src/routes/gh-ledger.js';

const SECRET = 'fixture-secret';
const H = '2026-10-15T10';
const H1 = '2026-10-15T11';

const call = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

// One gh_ledger row the way the POST route stores it.
const INS = `INSERT INTO gh_ledger (box, hour, lane, project, meter, resource, method, path_class,
               status, source, calls, counted, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`;
const put = (db, r) => db.prepare(INS).run(
  r.box || 'hub', r.hour || H, r.lane || 'lane-a', r.project || '-', r.meter || 'app-1',
  r.resource || 'core', r.method || 'GET', r.path_class || 'repos/Org/app/pulls/N',
  r.status || '200', r.source || 'rest', r.calls ?? 1, r.counted ?? 1, '2026-10-15T12:00:00Z');

test('BH-6974 gh_ledger grouped reads', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('G1 no group: the old answer shape, unchanged', async () => {
    const { db, DB } = await openDb();
    put(db, { calls: 3, counted: 2 });
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-15T10`);
    assert.equal(r.status, 200);
    assert.equal('group' in r.body, false, 'no group echo on the ungrouped read');
    assert.equal('totals' in r.body, false, 'no totals on the ungrouped read');
    assert.equal(r.body.truncated, false);
    assert.equal(r.body.rows[0].box, 'hub');
    assert.equal(r.body.rows[0].calls, 3);
  });

  await t.test('G1b two boxes, one (hour, lane): one lane-hour row with the sums', async () => {
    const { db, DB } = await openDb();
    put(db, { box: 'hub', calls: 5, counted: 4 });
    put(db, { box: 'pool-x', calls: 7, counted: 7, path_class: 'repos/Org/app/issues/N' });
    put(db, { box: 'hub', hour: H1, calls: 1, counted: 1 });
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-15T10&group=lane-hour`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.group, 'lane-hour');
    assert.deepEqual(r.body.rows.map((x) => [x.hour, x.lane, x.calls, x.counted]),
      [[H, 'lane-a', 12, 11], [H1, 'lane-a', 1, 1]]);
    assert.equal(r.body.truncated, false);
  });

  await t.test('G2 REST vs GraphQL: graphql rows are only in totals.graphql_*', async () => {
    const { db, DB } = await openDb();
    // REST
    put(db, { lane: 'r1', resource: 'core', path_class: 'repos/Org/app/pulls/N', calls: 10, counted: 9 });
    put(db, { lane: 'r2', resource: '-', path_class: '/repos/Org/app/issues/N/comments', calls: 4, counted: 4 });
    put(db, { lane: 'r3', resource: 'search', path_class: 'search/issues', calls: 2, counted: 2 });
    // GraphQL
    put(db, { lane: 'g1', resource: 'graphql', path_class: 'graphql', calls: 100, counted: 100 });
    put(db, { lane: 'g2', resource: '-', path_class: '/graphql', calls: 20, counted: 20 });
    put(db, { lane: 'g3', resource: 'graphql', path_class: 'repos/Org/app/pulls/N', calls: 7, counted: 6 });
    for (const g of Object.keys(GH_LEDGER_GROUPS)) {
      const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-15T10&group=${g}`);
      assert.equal(r.status, 200, `${g}: ${JSON.stringify(r.body)}`);
      assert.deepEqual(r.body.totals,
        { rest_calls: 16, rest_counted: 15, graphql_calls: 127, graphql_counted: 126 }, g);
      const sum = r.body.rows.reduce((a, x) => a + x.calls, 0);
      assert.equal(sum, 16, `${g}: only REST rows are grouped`);
      if (r.body.rows[0].lane !== undefined) {
        assert.deepEqual(r.body.rows.map((x) => x.lane).filter((l) => l.startsWith('g')), [], g);
      }
    }
    const lc = await call(DB, `/api/metrics/gh-ledger?since=2026-10-15T10&group=lane-class`);
    assert.deepEqual(lc.body.rows.map((x) => [x.lane, x.path_class, x.counted]),
      [['r1', 'repos/Org/app/pulls/N', 9], ['r2', '/repos/Org/app/issues/N/comments', 4], ['r3', 'search/issues', 2]]);
  });

  await t.test('G3 path class -> repo, the decision table', async () => {
    const { db, DB } = await openDb();
    const table = [
      ['repos/Org/app/pulls/N', 'Org/app'],
      ['/repos/Org/app', 'Org/app'],
      ['repos/Org/appN/commits/SHA', 'Org/appN'],
      ['graphql', '(no repo)'],
      ['rate_limit', '(no repo)'],
      ['installation/repositories', '(no repo)'],
      ['repos/Org', '(no repo)'],
      ['repos/Org/', '(no repo)'],
      ['REPOS/Org/app', '(no repo)'],
    ];
    for (const [pc, want] of table) {
      const got = db.prepare(
        `SELECT ${GH_LEDGER_REPO_SQL} AS repo FROM (SELECT ${GH_LEDGER_REPO_REST_SQL} AS rest FROM (SELECT ? AS path_class))`
      ).get(pc).repo;
      assert.equal(got, want, pc);
    }
    // Through the route: REST rows only (graphql is out before the repo rule).
    let n = 1;
    for (const [pc] of table) put(db, { lane: `l${n}`, path_class: pc, resource: 'core', calls: n, counted: n++ });
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-15T10&group=repo`);
    assert.equal(r.status, 200);
    const by = Object.fromEntries(r.body.rows.map((x) => [x.repo, x.calls]));
    // graphql (4) is not REST; Org/app = 1+2, Org/appN = 3, (no repo) = 5+6+7+8+9
    assert.equal(by['Org/app'], 3);
    assert.equal(by['Org/appN'], 3);
    assert.equal(by['(no repo)'], 35);
    assert.deepEqual(r.body.rows.map((x) => x.repo), ['(no repo)', 'Org/app', 'Org/appN'],
      'counted desc, then calls desc, then name');
  });

  await t.test('G4 validation', async () => {
    const { DB } = await openDb();
    const bogus = await call(DB, `/api/metrics/gh-ledger?since=2026-10-15T10&group=bogus`);
    assert.equal(bogus.status, 400);
    // SPEC CHANGE (BH-8066): group=served is a valid group, so the message names it.
    assert.equal(bogus.body.error, 'group must be one of lane-hour, lane-class, repo, served');
    const noSince = await call(DB, '/api/metrics/gh-ledger?group=lane-hour');
    assert.equal(noSince.status, 400);
  });

  await t.test('G5 a capped answer says truncated, and totals stay exact', async () => {
    const { db, DB } = await openDb();
    db.exec('BEGIN');
    let want = 0;
    for (let i = 0; i < 6000; i++) {
      const hour = `2026-10-${String(10 + Math.floor(i / 2400)).padStart(2, '0')}T${String(Math.floor(i / 100) % 24).padStart(2, '0')}`;
      put(db, { hour, lane: `lane-${i % 100}`, calls: 2, counted: 1 });
      want += 2;
    }
    db.exec('COMMIT');
    const r = await call(DB, '/api/metrics/gh-ledger?since=2026-10-01T00&group=lane-hour');
    assert.equal(r.status, 200);
    assert.equal(r.body.truncated, true);
    assert.equal(r.body.rows.length, 5000);
    assert.equal(r.body.totals.rest_calls, want);
  });

  await t.test('G6 150,000 rows: every grouped read uses idx_gh_ledger_hour', async () => {
    const { db } = await openDb();
    const N = 150000;
    const base = Date.parse('2026-10-15T12:00:00Z');
    const stmt = db.prepare(INS);
    db.exec('BEGIN');
    for (let i = 0; i < N; i++) {
      const hour = new Date(base - Math.floor((i / N) * 14 * 24) * 3600e3).toISOString().slice(0, 13);
      stmt.run(`box-${i % 9}`, hour, `lane-${i % 98}`, `p${i % 13}`, 'app-1',
        i % 7 === 0 ? 'graphql' : 'core', 'GET', i % 7 === 0 ? 'graphql' : `repos/Org/app${i % 11}/pulls/N`,
        '200', 'rest', 1 + (i % 3), 1, '2026-10-15T12:00:00Z');
    }
    db.exec('COMMIT');
    const log = [];
    const DB = capturingD1(db, log);
    for (const g of Object.keys(GH_LEDGER_GROUPS)) {
      const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-14T12&group=${g}`);
      assert.equal(r.status, 200, g);
    }
    const reads = log.filter((x) => /FROM gh_ledger/.test(x.sql));
    assert.equal(reads.length, 6, 'three grouped reads and three totals reads');
    for (const { sql, binds } of reads) {
      const lines = plan(db, sql, ...binds);
      assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_gh_ledger_hour/.test(l)),
        `${sql}\n${lines.join('\n')}`);
      assert.deepEqual(fullScans(lines, ['gh_ledger']), [], sql);
    }
  });
});
