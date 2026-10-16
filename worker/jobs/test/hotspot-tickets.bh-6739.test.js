// BH-6739 (BH-6543.2): hotspot_tickets, the "once" memory of
// bin/hotspot-split-ticket.sh. One row per (repo, path) that got a split
// ticket. Driven through the REAL router (worker.fetch) against the composed
// schema on the node:sqlite shim. The shell side is
// tests/hotspot-split-ticket.bh-6739-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { RULES } from '../src/routes/retention.js';

const SECRET = 'fixture-secret';
const REPO = 'example-org/cromford';
const GET_SQL = 'SELECT path, issue, filed_at FROM hotspot_tickets WHERE repo = ?1 ORDER BY path LIMIT 501';
const READ_BACK_SQL = 'SELECT repo, path, issue, filed_at, actor FROM hotspot_tickets WHERE repo = ?1 AND path = ?2';
const RULE = RULES.find((r) => r.rule === 'hotspot_tickets.age');
// The retention route reads the worker's real clock, so the seeded times are offsets from one anchor.
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

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
const put = (DB, body, opts = {}) => call(DB, '/api/hotspot-tickets', { method: 'PUT', body, ...opts });
const get = (DB, repo) => call(DB, `/api/hotspot-tickets?repo=${encodeURIComponent(repo)}`);

test('BH-6739 hotspot-tickets route', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 PUT new 201, same 200 inserted:false, other issue 409, GET returns it', async () => {
    const { DB } = await openDb();
    const a = await put(DB, { repo: REPO, path: 'bin/a.sh', issue: 701, actor: 'hotspot-split-ticket' });
    assert.equal(a.status, 201, JSON.stringify(a.body));
    assert.equal(a.body.inserted, true);
    assert.equal(a.body.row.issue, 701);
    assert.equal(a.body.row.path, 'bin/a.sh');
    assert.ok(a.body.row.filed_at, 'filed_at stamped');
    const b = await put(DB, { repo: REPO, path: 'bin/a.sh', issue: 701 });
    assert.equal(b.status, 200, JSON.stringify(b.body));
    assert.equal(b.body.inserted, false);
    assert.equal(b.body.row.filed_at, a.body.row.filed_at, 'a replay keeps the first filed_at');
    const c = await put(DB, { repo: REPO, path: 'bin/a.sh', issue: 702 });
    assert.equal(c.status, 409, JSON.stringify(c.body));
    assert.equal(c.body.row.issue, 701, 'the stored row wins');
    await put(DB, { repo: 'example-org/other', path: 'bin/a.sh', issue: 5 });
    const g = await get(DB, REPO);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.repo, REPO);
    assert.deepEqual(g.body.tickets.map((r) => [r.path, r.issue]), [['bin/a.sh', 701]]);
    assert.equal(g.body.total, 1);
    assert.equal(g.body.truncated, false);
    const e = await get(DB, 'example-org/none');
    assert.equal(e.status, 200);
    assert.deepEqual(e.body.tickets, []);
  });

  await t.test('R2 bad input answers 400, no bearer 401, and nothing is written', async () => {
    const { DB, db } = await openDb();
    const cases = [
      { repo: 'not-a-slug', path: 'bin/a.sh', issue: 1 },
      { repo: REPO, path: '', issue: 1 },
      { repo: REPO, path: 'bin/a\n.sh', issue: 1 },
      { repo: REPO, path: '/etc/passwd', issue: 1 },
      { repo: REPO, path: 'x'.repeat(1025), issue: 1 },
      { repo: REPO, path: 'bin/a.sh', issue: 0 },
      { repo: REPO, path: 'bin/a.sh', issue: '5' },
      { repo: REPO, path: 'bin/a.sh', issue: 1.5 },
      { repo: REPO, path: 'bin/a.sh' },
      { repo: REPO, path: 'bin/a.sh', issue: 1, actor: 'a'.repeat(65) },
    ];
    for (const body of cases) {
      const r = await put(DB, body);
      assert.equal(r.status, 400, `${JSON.stringify(body).slice(0, 80)} -> ${r.status}`);
    }
    assert.equal((await get(DB, 'bad')).status, 400);
    assert.equal((await call(DB, '/api/hotspot-tickets')).status, 400, 'GET with no repo');
    assert.equal((await put(DB, { repo: REPO, path: 'bin/a.sh', issue: 1 }, { auth: null })).status, 401);
    assert.equal((await call(DB, `/api/hotspot-tickets?repo=${REPO}`, { auth: null })).status, 401);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM hotspot_tickets').get().n, 0);
  });

  await t.test('R3 the composed schema seeds the threshold, the max age and the retention window', async () => {
    assert.match(jobsSchemaSql(), /CREATE TABLE IF NOT EXISTS hotspot_tickets \(/);
    const val = (k) => (probe.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('hotspots.split_threshold'), '10');
    assert.equal(val('hotspots.split_max_age_days'), '14');
    assert.equal(val('retention.hotspot_tickets.days'), '365');
  });

  await t.test('R4 2,000 rows: the GET uses the primary key index; a 600-row repo is truncated at 500', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare('INSERT INTO hotspot_tickets (repo, path, issue, filed_at, actor) VALUES (?, ?, ?, ?, ?)');
    db.exec('BEGIN');
    for (let i = 0; i < 2000; i += 1) ins.run(`example-org/r${i % 20}`, `bin/f${String(i).padStart(5, '0')}.sh`, i + 1, '2026-10-15T00:00:00Z', 'seed');
    for (let i = 0; i < 600; i += 1) ins.run('example-org/big', `src/g${String(i).padStart(4, '0')}.js`, i + 1, '2026-10-15T00:00:00Z', 'seed');
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${GET_SQL}`).all('example-org/r3').map((r) => r.detail).join(' | ');
    assert.match(plan, /sqlite_autoindex_hotspot_tickets_1/, plan);
    assert.doesNotMatch(plan, /SCAN hotspot_tickets/, plan);
    assert.doesNotMatch(plan, /TEMP B-TREE/, `ORDER BY path needs no sort: ${plan}`);
    const g = await get(DB, 'example-org/r3');
    assert.equal(g.body.tickets.length, 100);
    assert.equal(g.body.truncated, false);
    const big = await get(DB, 'example-org/big');
    assert.equal(big.status, 200);
    assert.equal(big.body.tickets.length, 500);
    assert.equal(big.body.total, 500);
    assert.equal(big.body.truncated, true);
    assert.equal(big.body.tickets[0].path, 'src/g0000.js', 'path ascending');
  });

  await t.test('R6 2,000 rows: the PUT read-back uses the primary key, the retention read uses idx_hotspot_tickets_filed', async () => {
    assert.ok(RULE, 'retention.js RULES has hotspot_tickets.age');
    assert.equal(RULE.key, 'retention.hotspot_tickets.days');
    assert.equal(RULE.def, 365);
    const { db } = await openDb();
    const ins = db.prepare('INSERT INTO hotspot_tickets (repo, path, issue, filed_at, actor) VALUES (?, ?, ?, ?, ?)');
    db.exec('BEGIN');
    for (let i = 0; i < 2000; i += 1) ins.run(`example-org/r${i % 20}`, `bin/f${String(i).padStart(5, '0')}.sh`, i + 1, ago(i % 700), 'seed');
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail).join(' | ');
    const rb = plan(READ_BACK_SQL, 'example-org/r3', 'bin/f00003.sh');
    assert.match(rb, /sqlite_autoindex_hotspot_tickets_1/, rb);
    assert.doesNotMatch(rb, /SCAN hotspot_tickets/, rb);
    const ret = plan(RULE.ids, ago(365), 500);
    assert.match(ret, /idx_hotspot_tickets_filed/, ret);
    assert.doesNotMatch(ret, /SCAN hotspot_tickets/, ret);
    assert.doesNotMatch(ret, /TEMP B-TREE/, `ORDER BY filed_at needs no sort: ${ret}`);
  });

  await t.test('R7 POST /api/retention/run deletes a 400-day-old row, keeps a 10-day-old one, audits the rule', async () => {
    const { DB, db } = await openDb();
    db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('retention.dry_run', '0', '', 'test', ?)").run(ago(0));
    const ins = db.prepare('INSERT INTO hotspot_tickets (repo, path, issue, filed_at, actor) VALUES (?, ?, ?, ?, ?)');
    ins.run(REPO, 'bin/old.sh', 11, ago(400), 'seed');
    ins.run(REPO, 'bin/new.sh', 12, ago(10), 'seed');
    const r = await call(DB, '/api/retention/run', { method: 'POST', body: {} });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.dry_run, false);
    const out = r.body.rules.find((x) => x.rule === 'hotspot_tickets.age');
    assert.ok(out, JSON.stringify(r.body.rules.map((x) => x.rule)));
    assert.equal(out.removed, 1, JSON.stringify(out));
    assert.equal(out.error, null);
    const left = db.prepare('SELECT path FROM hotspot_tickets ORDER BY path').all().map((x) => x.path);
    assert.deepEqual(left, ['bin/new.sh']);
    const audit = db.prepare("SELECT rule, tbl, dry_run, removed FROM retention_runs WHERE rule = 'hotspot_tickets.age'").all();
    assert.equal(audit.length, 1);
    assert.equal(audit[0].tbl, 'hotspot_tickets');
    assert.equal(audit[0].removed, 1);
    assert.equal(audit[0].dry_run, 0);
  });

  await t.test('R8 a dry run counts the old row and deletes nothing', async () => {
    const { DB, db } = await openDb();
    db.prepare('INSERT INTO hotspot_tickets (repo, path, issue, filed_at, actor) VALUES (?, ?, ?, ?, ?)').run(REPO, 'bin/old.sh', 11, ago(400), 'seed');
    const r = await call(DB, '/api/retention/run', { method: 'POST', body: { dry_run: true } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const out = r.body.rules.find((x) => x.rule === 'hotspot_tickets.age');
    assert.equal(out.counted, 1, JSON.stringify(out));
    assert.equal(out.removed, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM hotspot_tickets').get().n, 1);
  });

  await t.test('R5 a fresh DB with no hotspot_tickets table self-creates on first use', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE hotspot_tickets');
    const g = await get(DB, REPO);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const p = await put(DB, { repo: REPO, path: 'bin/a.sh', issue: 3 });
    assert.equal(p.status, 201, JSON.stringify(p.body));
  });
});
