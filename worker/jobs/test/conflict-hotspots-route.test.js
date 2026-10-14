// BH-5267 (BH-5248.1): every project's conflict hotspots, measured weekly on the
// box that owns it (bin/conflict-hotspots-fleet.sh), stored as rows.
// Driven through the REAL router (worker.fetch) against a real schema.sql
// database on the node:sqlite shim, the way pool-state.bh-5001.test.js does it.
// The shell side is tests/conflict-hotspots-fleet.bh-5267-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const TABLES = ['conflict_hotspots', 'conflict_hotspot_runs'];
const SHA = 'a'.repeat(40);

const call = (DB, path, { method = 'GET', body, auth = SECRET } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${auth}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body, opts = {}) => call(DB, '/api/conflict-hotspots', { method: 'PUT', body, ...opts });
const get = (DB, qs, opts = {}) => call(DB, `/api/conflict-hotspots?${qs}`, opts);
const cols = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all()
  .map((c) => [c.name, c.type, c.notnull, c.pk]);
const dump = (db, project) => db.prepare(
  'SELECT project, file, conflicts, rebases, prs, window_days, since, until, ref_sha, run_at FROM conflict_hotspots '
  + (project ? 'WHERE project = ? ' : '') + 'ORDER BY project, file',
).all(...(project ? [project] : [])).map((r) => ({ ...r }));
const runRow = (db, project) => {
  const r = db.prepare('SELECT * FROM conflict_hotspot_runs WHERE project = ?').get(project);
  return r ? { ...r } : null;
};

const body = (project, rows, extra = {}) => ({
  project, repo: `example-org/${project}`, box: 'small', status: 'ok', detail: null,
  window_days: 30, since: '2024-09-01T00:00:00Z', until: '2024-10-01T00:00:00Z', ref_sha: SHA,
  pr_merges: 12, sync_merges: 7, merge_tree_errors: 0, files_total: rows.length, rows, ...extra,
});
const R = (file, conflicts, rebases, prs = '#1') => ({ file, conflicts, rebases, prs });

test('BH-5267 conflict hotspots route', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R0 schema.sql creates both tables and applies twice', async () => {
    for (const table of TABLES) {
      assert.match(SCHEMA, new RegExp(`CREATE TABLE IF NOT EXISTS ${table} \\(`));
      assert.ok(cols(probe.db, table).length > 0, `schema.sql creates ${table}`);
    }
    const names = cols(probe.db, 'conflict_hotspots').map((c) => c[0]);
    for (const c of ['project', 'file', 'conflicts', 'rebases', 'prs', 'window_days', 'since', 'until', 'ref_sha', 'run_at']) {
      assert.ok(names.includes(c), `conflict_hotspots.${c}`);
    }
    probe.db.exec(SCHEMA); // a second apply must not error
  });

  await t.test('R0b CREATED_TABLES gives the same columns as schema.sql; a fresh DB self-creates', async () => {
    for (const table of TABLES) {
      const stmts = CREATED_TABLES[table];
      assert.ok(Array.isArray(stmts) && stmts.length >= 1, `CREATED_TABLES.${table}`);
      const fresh = await openDb();
      fresh.db.exec(`DROP TABLE IF EXISTS ${table}`);
      for (const s of stmts) fresh.db.exec(s);
      assert.deepEqual(cols(fresh.db, table), cols(probe.db, table), `${table} columns differ`);
    }
    assert.ok(SCHEMA.includes(`${CREATED_TABLES.conflict_hotspots[1]};`), 'the hotspots index is schema.sql\'s verbatim');
    const fresh = await openDb();
    for (const table of TABLES) fresh.db.exec(`DROP TABLE IF EXISTS ${table}`);
    const g = await get(fresh.DB, 'project=alpha');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const w = await put(fresh.DB, body('alpha', [R('a.txt', 1, 1)]));
    assert.equal(w.status, 200, JSON.stringify(w.body));
  });

  await t.test('R1 two projects each store rows keyed by their own project', async () => {
    const { DB, db } = await openDb();
    const a = await put(DB, body('alpha', [R('hot.txt', 3, 4, '#1,#2,#3'), R('cold.txt', 0, 2, '#4')]));
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.run.status, 'ok');
    assert.equal(a.body.stored, 2);
    const b = await put(DB, body('beta', [R('hot.txt', 1, 1, 'ticket/x')]));
    assert.equal(b.status, 200, JSON.stringify(b.body));
    assert.deepEqual(dump(db, 'alpha').map((r) => [r.project, r.file, r.conflicts, r.rebases, r.prs]),
      [['alpha', 'cold.txt', 0, 2, '#4'], ['alpha', 'hot.txt', 3, 4, '#1,#2,#3']]);
    assert.deepEqual(dump(db, 'beta').map((r) => [r.project, r.file, r.prs]), [['beta', 'hot.txt', 'ticket/x']]);
    const row = dump(db, 'alpha')[0];
    assert.equal(row.window_days, 30);
    assert.equal(row.ref_sha, SHA);
    assert.ok(row.run_at, 'run_at stamped');
    const ra = runRow(db, 'alpha');
    assert.equal(ra.status, 'ok');
    assert.equal(ra.files_total, 2);
    assert.equal(ra.rows_stored, 2);
    assert.equal(ra.last_ok_at, ra.run_at);
    assert.equal(ra.repo, 'example-org/alpha');
  });

  await t.test('R2 a re-PUT replaces the project window; the other project is untouched', async () => {
    const { DB, db } = await openDb();
    await put(DB, body('alpha', [R('a.txt', 3, 3), R('b.txt', 2, 2), R('c.txt', 1, 1)]));
    await put(DB, body('beta', [R('a.txt', 9, 9, '#9')]));
    const betaBefore = dump(db, 'beta');
    const r = await put(DB, body('alpha', [R('a.txt', 4, 4), R('b.txt', 2, 3), R('d.txt', 1, 0)], { files_total: 7 }));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const rows = dump(db, 'alpha');
    assert.deepEqual(rows.map((x) => [x.file, x.conflicts, x.rebases]), [['a.txt', 4, 4], ['b.txt', 2, 3], ['d.txt', 1, 0]]);
    assert.ok(!rows.some((x) => x.file === 'c.txt'), 'the dropped file is gone');
    const dups = db.prepare('SELECT project, file, COUNT(*) n FROM conflict_hotspots GROUP BY project, file HAVING COUNT(*) > 1').all();
    assert.equal(dups.length, 0);
    assert.deepEqual(dump(db, 'beta'), betaBefore);
    const ra = runRow(db, 'alpha');
    assert.equal(ra.files_total, 7);
    assert.equal(ra.rows_stored, 3);
    // An ok run with zero rows empties the window (measured, nothing collided).
    const z = await put(DB, body('alpha', []));
    assert.equal(z.status, 200, JSON.stringify(z.body));
    assert.equal(dump(db, 'alpha').length, 0);
    assert.equal(runRow(db, 'alpha').status, 'ok');
    // The multi-statement path: more rows than one INSERT carries.
    const many = Array.from({ length: 23 }, (_, i) => R(`f${String(i).padStart(2, '0')}.txt`, i, i));
    const m = await put(DB, body('alpha', many));
    assert.equal(m.status, 200, JSON.stringify(m.body));
    assert.equal(dump(db, 'alpha').length, 23);
  });

  await t.test('R3 a non-ok run keeps the last good window and last_ok_at', async () => {
    const { DB, db } = await openDb();
    await put(DB, body('alpha', [R('a.txt', 3, 3), R('b.txt', 1, 1)]));
    const before = dump(db, 'alpha');
    const okAt = runRow(db, 'alpha').last_ok_at;
    const s = await put(DB, { project: 'alpha', box: 'small', status: 'shallow', detail: 'the repository is shallow' });
    assert.equal(s.status, 200, JSON.stringify(s.body));
    assert.deepEqual(dump(db, 'alpha'), before);
    const ra = runRow(db, 'alpha');
    assert.equal(ra.status, 'shallow');
    assert.equal(ra.detail, 'the repository is shallow');
    assert.equal(ra.last_ok_at, okAt);
    assert.equal(ra.files_total, 2, 'the last good window\'s counts stay');
    // A failed run for a project never measured is a runs row with no last_ok_at.
    const n = await put(DB, { project: 'gamma', box: 'small', status: 'no-checkout' });
    assert.equal(n.status, 200, JSON.stringify(n.body));
    assert.equal(runRow(db, 'gamma').status, 'no-checkout');
    assert.equal(runRow(db, 'gamma').last_ok_at, null);
    // A non-ok body carrying rows is refused, not half-applied.
    const bad = await put(DB, { project: 'alpha', status: 'error', rows: [R('x.txt', 1, 1)] });
    assert.equal(bad.status, 400);
    assert.equal(runRow(db, 'alpha').status, 'shallow');
    // An unknown status is never stored.
    const u = await put(DB, { project: 'alpha', status: 'fine' });
    assert.equal(u.status, 400);
    assert.equal(runRow(db, 'alpha').status, 'shallow');
  });

  await t.test('R4 one bad row refuses the whole PUT and writes nothing', async () => {
    const { DB, db } = await openDb();
    await put(DB, body('alpha', [R('a.txt', 3, 3)]));
    const snap = () => JSON.stringify([dump(db), runRow(db, 'alpha')]);
    const before = snap();
    for (const rows of [
      [R('b.txt', 2, 2), R('c.txt', -1, 0)],
      [R('b.txt', 2, 2), { conflicts: 1, rebases: 1, prs: '#1' }],
      [R('b.txt', 2, 2), { file: 'c.txt', rebases: 1, prs: '#1' }],
      [R('b.txt', 1.5, 2)],
      [R('b.txt', 2, 2, 'x'.repeat(65537))],
    ]) {
      const r = await put(DB, body('alpha', rows));
      assert.equal(r.status, 400, JSON.stringify(rows).slice(0, 80));
      assert.equal(snap(), before);
    }
    const tooMany = Array.from({ length: 501 }, (_, i) => R(`f${i}`, 1, 1));
    assert.equal((await put(DB, body('alpha', tooMany))).status, 400);
    assert.equal((await put(DB, { ...body('alpha', [R('b.txt', 1, 1)]), project: 'no spaces' })).status, 400);
    assert.equal((await put(DB, body('alpha', [R('b.txt', 1, 1)], { files_total: undefined }))).status, 400);
    assert.equal(snap(), before);
    // A busy repo's hot file: 600 PR ids (~3.6KB) is a real row, stored whole.
    const long = Array.from({ length: 600 }, (_, i) => `#${4000 + i}`).join(',');
    assert.equal((await put(DB, body('alpha', [R('b.txt', 1, 600, long)]))).status, 200);
    assert.equal(dump(db, 'alpha')[0].prs, long);
  });

  await t.test('R5 PUT without the bearer is 401 and writes nothing', async () => {
    const { DB, db } = await openDb();
    assert.equal((await put(DB, body('alpha', [R('a.txt', 1, 1)]), { auth: null })).status, 401);
    assert.equal((await put(DB, body('alpha', [R('a.txt', 1, 1)]), { auth: 'wrong' })).status, 401);
    assert.equal(dump(db).length, 0);
  });

  await t.test('R6 GET answers the top rows by conflicts, then rebases, then file', async () => {
    const { DB } = await openDb();
    await put(DB, body('alpha', [R('b.txt', 2, 1), R('a.txt', 2, 1), R('c.txt', 5, 0), R('d.txt', 2, 9), R('e.txt', 0, 4)]));
    await put(DB, body('beta', [R('zz.txt', 99, 99)]));
    const g = await get(DB, 'project=alpha');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.deepEqual(g.body.hotspots.map((h) => h.file), ['c.txt', 'd.txt', 'a.txt', 'b.txt', 'e.txt']);
    assert.deepEqual(g.body.hotspots[0], {
      file: 'c.txt', conflicts: 5, rebases: 0, prs: '#1', window_days: 30,
      since: '2024-09-01T00:00:00Z', until: '2024-10-01T00:00:00Z', ref_sha: SHA, run_at: g.body.hotspots[0].run_at,
    });
    assert.equal(g.body.project, 'alpha');
    assert.equal(g.body.run.status, 'ok');
    assert.equal(g.body.run.repo, 'example-org/alpha');
    assert.equal(g.body.total, 5);
    assert.equal(g.body.truncated, false);
    assert.ok(g.body.as_of);
  });

  await t.test('R7 limit cuts the list and says so; junk limit is the default', async () => {
    const { DB } = await openDb();
    await put(DB, body('alpha', [R('a', 5, 0), R('b', 4, 0), R('c', 3, 0), R('d', 2, 0), R('e', 1, 0)]));
    const g = await get(DB, 'project=alpha&limit=2');
    assert.deepEqual(g.body.hotspots.map((h) => h.file), ['a', 'b']);
    assert.equal(g.body.total, 5);
    assert.equal(g.body.truncated, true);
    const j = await get(DB, 'project=alpha&limit=junk');
    assert.equal(j.status, 200);
    assert.equal(j.body.hotspots.length, 5);
    assert.equal(j.body.limit, 20);
    const many = Array.from({ length: 25 }, (_, i) => R(`f${String(i).padStart(2, '0')}`, 1, 1));
    await put(DB, body('beta', many));
    const d = await get(DB, 'project=beta&limit=junk');
    assert.equal(d.body.hotspots.length, 20);
    assert.equal(d.body.truncated, true);
    const big = await get(DB, 'project=beta&limit=100000');
    assert.equal(big.body.limit, 200);
    assert.equal(big.body.hotspots.length, 25);
  });

  await t.test('R8 an unknown project answers 200 with run null', async () => {
    const { DB } = await openDb();
    const g = await get(DB, 'project=nobody-here');
    assert.equal(g.status, 200);
    assert.equal(g.body.run, null);
    assert.deepEqual(g.body.hotspots, []);
    assert.equal(g.body.total, 0);
  });

  await t.test('R9 a GET without a project is 400', async () => {
    const { DB } = await openDb();
    assert.equal((await get(DB, '')).status, 400);
    assert.equal((await get(DB, 'project=bad%20name')).status, 400);
  });

  await t.test('R10 a GET without the bearer is 401', async () => {
    const { DB } = await openDb();
    await put(DB, body('alpha', [R('a.txt', 1, 1)]));
    assert.equal((await get(DB, 'project=alpha', { auth: null })).status, 401);
  });

  await t.test('R11 a duplicate file in one body is refused', async () => {
    const { DB, db } = await openDb();
    const r = await put(DB, body('alpha', [R('a.txt', 1, 1), R('a.txt', 2, 2)]));
    assert.equal(r.status, 400);
    assert.equal(dump(db).length, 0);
    assert.equal(runRow(db, 'alpha'), null);
  });
});
