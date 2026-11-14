// BH-9697: the suite_quarantine table and its routes, driven through the REAL
// worker.fetch against the composed jobs schema (the node:sqlite D1 shim).
//
//   W1  POST creates an active row (created true)
//   W2  a second POST of the same (repo, suite) is the same row, created false
//   W3  400 on a bad suite, sha or repo; no bearer is 401; no row written
//   W4  /issue sets repair_issue once
//   W5  GET lists the active rows of one repo only, ordered by suite;
//       status=released lists only released rows; a bad status is 400
//   W6  release once; a new POST after it is a NEW active row
//   W7  EXPLAIN QUERY PLAN on 5,000 seeded rows: each read uses its index
//   W8  retention: dry run deletes nothing; live run deletes an old released
//       row and keeps a fresh released row and an old active row
//   W9  the seed rows suite_quarantine.retention_days = '60' and
//       suite_quarantine.list_max = '500'
//   W10 GET returns at most suite_quarantine.list_max rows and sets truncated
//       only when more rows exist
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const DAY = 86400e3;
const SHA_RED = 'a'.repeat(40);
const SHA_GREEN = 'b'.repeat(40);
const isoSec = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const req = (DB, method, path, body, { bearer = true } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const put = (DB, repo, suite, over = {}, o) => req(DB, 'POST', '/api/suite-quarantine',
  { repo, suite, reason: 'red on main', main_sha_red: SHA_RED, ...over }, o);
const list = (DB, repo, status) => req(DB, 'GET',
  `/api/suite-quarantine?repo=${encodeURIComponent(repo)}${status ? `&status=${status}` : ''}`);
const rowsOf = (db, repo) => db.prepare('SELECT * FROM suite_quarantine WHERE repo=? ORDER BY id').all(repo);

test('BH-9697 suite quarantine', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 POST creates an active row', async () => {
    const { DB } = await openDb();
    const r = await put(DB, 'repo-w1', 'tests/w1-test.sh');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.created, true);
    const row = r.body.row;
    assert.equal(typeof row.id, 'number');
    assert.deepEqual([row.repo, row.suite, row.reason, row.main_sha_red, row.status, row.main_sha_green, row.repair_issue, row.released_at],
      ['repo-w1', 'tests/w1-test.sh', 'red on main', SHA_RED, 'active', null, null, null]);
    assert.match(row.created_at, /^\d{4}-\d{2}-\d{2}T/);
  });

  await t.test('W2 a second POST is the same active row', async () => {
    const { DB, db } = await openDb();
    const r1 = await put(DB, 'repo-w2', 'tests/w2-test.sh');
    const r2 = await put(DB, 'repo-w2', 'tests/w2-test.sh', { reason: 'other', main_sha_red: 'c'.repeat(40) });
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    assert.equal(r2.body.created, false);
    assert.equal(r2.body.row.id, r1.body.row.id);
    assert.equal(r2.body.row.reason, 'red on main');
    assert.equal(rowsOf(db, 'repo-w2').filter((x) => x.status === 'active').length, 1);
    assert.equal(rowsOf(db, 'repo-w2').length, 1);
  });

  await t.test('W3 bad fields are 400, no bearer is 401, no row written', async () => {
    const { DB, db } = await openDb();
    for (const [suite, over, field] of [
      ['tests/../x.sh', {}, 'suite'],
      ['x.sh', {}, 'suite'],
      ['tests/x.sh.bak', {}, 'suite'],
      [`tests/${'a'.repeat(200)}.sh`, {}, 'suite'],
      ['tests/w3-test.sh', { main_sha_red: 'abc' }, 'main_sha_red'],
      ['tests/w3-test.sh', { reason: 'r'.repeat(501) }, 'reason'],
    ]) {
      const r = await put(DB, 'repo-w3', suite, over);
      assert.equal(r.status, 400, `${suite}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.error, field);
    }
    const badRepo = await put(DB, 'a b', 'tests/w3-test.sh');
    assert.equal(badRepo.status, 400);
    assert.equal(badRepo.body.error, 'repo');
    assert.equal((await put(DB, 'repo-w3', 'tests/w3-test.sh', {}, { bearer: false })).status, 401);
    assert.equal(rowsOf(db, 'repo-w3').length, 0);
    assert.equal(rowsOf(db, 'a b').length, 0);
    const iss = await req(DB, 'POST', '/api/suite-quarantine/issue', { repo: 'repo-w3', suite: 'tests/w3-test.sh', repair_issue: 0 });
    assert.equal(iss.status, 400);
    assert.equal(iss.body.error, 'repair_issue');
  });

  await t.test('W4 /issue sets repair_issue once', async () => {
    const { DB, db } = await openDb();
    await put(DB, 'repo-w4', 'tests/w4-test.sh');
    const a = await req(DB, 'POST', '/api/suite-quarantine/issue', { repo: 'repo-w4', suite: 'tests/w4-test.sh', repair_issue: 9701 });
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.deepEqual(a.body, { updated: 1 });
    const b = await req(DB, 'POST', '/api/suite-quarantine/issue', { repo: 'repo-w4', suite: 'tests/w4-test.sh', repair_issue: 9702 });
    assert.deepEqual(b.body, { updated: 0 });
    assert.equal(rowsOf(db, 'repo-w4')[0].repair_issue, 9701);
  });

  await t.test('W5 GET lists one repo and one status, ordered by suite', async () => {
    const { DB } = await openDb();
    await put(DB, 'repo-w5', 'tests/w5-b-test.sh');
    await put(DB, 'repo-w5', 'tests/w5-a-test.sh');
    await put(DB, 'repo-w5', 'tests/w5-c-test.sh');
    await put(DB, 'repo-w5-other', 'tests/w5-z-test.sh');
    await req(DB, 'POST', '/api/suite-quarantine/release', { repo: 'repo-w5', suite: 'tests/w5-c-test.sh', main_sha_green: SHA_GREEN });
    const act = await list(DB, 'repo-w5');
    assert.equal(act.status, 200, JSON.stringify(act.body));
    assert.deepEqual(act.body.rows.map((r) => r.suite), ['tests/w5-a-test.sh', 'tests/w5-b-test.sh']);
    assert.ok(act.body.rows.every((r) => r.repo === 'repo-w5' && r.status === 'active'));
    assert.deepEqual(Object.keys(act.body.rows[0]).sort(),
      ['created_at', 'id', 'main_sha_green', 'main_sha_red', 'reason', 'released_at', 'repair_issue', 'repo', 'status', 'suite']);
    const rel = await list(DB, 'repo-w5', 'released');
    assert.deepEqual(rel.body.rows.map((r) => [r.suite, r.status, r.main_sha_green]), [['tests/w5-c-test.sh', 'released', SHA_GREEN]]);
    // Wrong tenant: a repo with no rows of its own sees 0 rows.
    assert.deepEqual((await list(DB, 'repo-w5-none')).body.rows, []);
    const badStatus = await list(DB, 'repo-w5', 'open');
    assert.equal(badStatus.status, 400);
    assert.equal(badStatus.body.error, 'status');
    const noRepo = await req(DB, 'GET', '/api/suite-quarantine');
    assert.equal(noRepo.status, 400);
    assert.equal(noRepo.body.error, 'repo');
  });

  await t.test('W6 release once, then a new POST is a new row', async () => {
    const { DB, db } = await openDb();
    const r1 = await put(DB, 'repo-w6', 'tests/w6-test.sh');
    const rel = (sha = SHA_GREEN) => req(DB, 'POST', '/api/suite-quarantine/release', { repo: 'repo-w6', suite: 'tests/w6-test.sh', main_sha_green: sha });
    assert.deepEqual((await rel()).body, { released: 1 });
    assert.deepEqual((await rel()).body, { released: 0 });
    const badSha = await rel('xyz');
    assert.equal(badSha.status, 400);
    assert.equal(badSha.body.error, 'main_sha_green');
    const r2 = await put(DB, 'repo-w6', 'tests/w6-test.sh');
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    assert.equal(r2.body.created, true);
    assert.notEqual(r2.body.row.id, r1.body.row.id);
    assert.deepEqual(rowsOf(db, 'repo-w6').map((r) => r.status), ['released', 'active']);
    assert.equal(rowsOf(db, 'repo-w6')[0].main_sha_green, SHA_GREEN);
  });

  await t.test('W7 the hot reads use their indexes on 5,000 seeded rows', async () => {
    const { db } = await openDb();
    const now = Date.parse('2026-11-14T00:00:00Z');
    const ins = db.prepare(`INSERT INTO suite_quarantine (repo, suite, reason, main_sha_red, status, created_at, released_at)
      VALUES (?,?,?,?,?,?,?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 5000; i++) {
      const released = i % 10 !== 0;
      ins.run(`repo-${i % 7}`, `tests/s${i}-test.sh`, '', SHA_RED, released ? 'released' : 'active',
        isoSec(now - i * 3600e3), released ? isoSec(now - i * 3600e3 + 60e3) : null);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const uses = (lines, idx) => assert.ok(lines.some((l) => l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN suite_quarantine\b/.test(l) && !/USING/.test(l)), [], lines.join(' | '));
    const { SQL } = await import('../src/routes/suite-quarantine.js');
    // status=active: SQLite plans with the bound value, so the partial
    // uq_suite_quarantine_active (repo, suite) serves both the WHERE and the
    // ORDER BY; status=released uses idx_suite_quarantine_active.
    let l = plan(SQL.list, 'repo-1', 'active', 500); noScan(l);
    assert.ok(l.some((x) => /^SEARCH suite_quarantine USING (COVERING )?INDEX (uq|idx)_suite_quarantine_active \(repo=\?/.test(x)), l.join(' | '));
    l = plan(SQL.list, 'repo-1', 'released', 500); uses(l, 'idx_suite_quarantine_active'); noScan(l);
    l = plan(SQL.active, 'repo-1', 'tests/s1-test.sh'); noScan(l);
    assert.ok(l.some((x) => /^SEARCH suite_quarantine USING/.test(x)), l.join(' | '));
    uses(l, 'uq_suite_quarantine_active');
    for (const s of [SQL.issue, SQL.release]) noScan(plan(s, ...(s === SQL.issue ? [1, 'r', 'tests/x.sh'] : ['t', SHA_GREEN, 'r', 'tests/x.sh'])));
    noScan(plan(SQL.insert, 'r', 'tests/x.sh', '', SHA_RED, 't'));
    const { default: RULES } = await import('../src/routes/retention.d/bh-9697-suite-quarantine.js');
    for (const r of RULES) {
      l = plan(r.ids, isoSec(now - 60 * DAY), 500); uses(l, 'idx_suite_quarantine_released'); noScan(l);
      noScan(plan(r.del, '[1]'));
    }
  });

  await t.test('W8 retention deletes an old released row and keeps the rest', async () => {
    const { DB, db } = await openDb();
    const old = isoSec(Date.now() - 61 * DAY);  // determinism: ok the retention route cuts at its own clock, so the seed is relative to it
    const fresh = isoSec(Date.now() - 1 * DAY);  // determinism: ok same anchor as above
    const older = isoSec(Date.now() - 100 * DAY);  // determinism: ok same anchor as above
    const mk = async (suite) => (await put(DB, 'repo-w8', suite)).body.row.id;
    const gone = await mk('tests/w8-gone-test.sh');
    const recent = await mk('tests/w8-recent-test.sh');
    const active = await mk('tests/w8-active-test.sh');
    db.prepare("UPDATE suite_quarantine SET status='released', released_at=?, main_sha_green=? WHERE id=?").run(old, SHA_GREEN, gone);
    db.prepare("UPDATE suite_quarantine SET status='released', released_at=?, main_sha_green=? WHERE id=?").run(fresh, SHA_GREEN, recent);
    db.prepare('UPDATE suite_quarantine SET created_at=? WHERE id=?').run(older, active);
    const run = () => worker.fetch(new Request('https://jobs.test/api/retention/run', {
      method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
    }), { DB, HARNESS_SECRET: SECRET }).then((r) => r.json());
    const dry = await run();
    assert.equal(dry.dry_run, true);
    assert.equal(dry.rules.find((r) => r.rule === 'suite_quarantine.released').counted, 1);
    assert.equal(rowsOf(db, 'repo-w8').length, 3);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const live = await run();
    const rule = live.rules.find((r) => r.rule === 'suite_quarantine.released');
    assert.equal(rule.error, null);
    assert.equal(rule.removed, 1);
    assert.deepEqual(rowsOf(db, 'repo-w8').map((r) => r.id), [recent, active]);
  });

  await t.test('W9 the seed row', async () => {
    const { db } = await openDb();
    assert.equal(db.prepare("SELECT value FROM settings WHERE key='suite_quarantine.retention_days'").get().value, '60');
    assert.equal(db.prepare("SELECT value FROM settings WHERE key='suite_quarantine.list_max'").get().value, '500');
  });

  await t.test('W10 list_max caps the list and sets truncated', async () => {
    const { DB, db } = await openDb();
    db.prepare("UPDATE settings SET value='2' WHERE key='suite_quarantine.list_max'").run();
    await put(DB, 'repo-w10', 'tests/w10-a-test.sh');
    await put(DB, 'repo-w10', 'tests/w10-b-test.sh');
    const full = await list(DB, 'repo-w10');
    assert.equal(full.status, 200, JSON.stringify(full.body));
    assert.equal(full.body.truncated, false);
    assert.equal(full.body.rows.length, 2);
    await put(DB, 'repo-w10', 'tests/w10-c-test.sh');
    const cut = await list(DB, 'repo-w10');
    assert.equal(cut.body.truncated, true);
    assert.deepEqual(cut.body.rows.map((r) => r.suite), ['tests/w10-a-test.sh', 'tests/w10-b-test.sh']);
  });
});
