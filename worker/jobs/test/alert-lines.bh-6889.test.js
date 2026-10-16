// BH-6889 (BH-6881.5): alert_lines through the real worker on node:sqlite with
// the composed schema.
//
//   W1 POST makes one row; the same payload again is {dup:true} and one row;
//      bad fields 400 naming the field; no bearer 401
//   W2 GET ?unapplied=1&limit=2 over 3 rows: ids 1 and 2, truncated; POST
//      /applied marks 2, a repeat marks 0, GET then answers id 3 only
//   W3 5,000 seeded rows: the unapplied read, both retention id reads and the
//      dedup lookup use their named index, no plan SCANs alert_lines
//   W4 the seeds 7 / 30 / 200; retention with dry_run=0 removes applied rows
//      past 7 days and unapplied rows past 30 days; dry_run=1 removes nothing
//   W5 the table dropped: every route answers 503
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-6889';
const NOW = Date.parse('2026-10-16T02:00:00Z');
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function call(DB, method, path, body, auth = true) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const STAMP = '2026-10-16 02:00:00Z';
const line = (o = {}) => ({
  lane: 'merge-conductor', project: 'demo', line: `${STAMP} conductor text`, stamp: STAMP,
  severity: 'warn', alertid: 'x-1', run_id: 'r1', ...o,
});
const n = (db, sql, ...b) => db.prepare(sql).get(...b).n;

test('W1 a line is one row; the same payload twice is a dup; bad fields 400; no bearer 401', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const r = await call(DB, 'POST', '/api/alert-lines', line());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(typeof r.body.id, 'number');
  assert.equal(r.body.dup, false);
  const row = db.prepare('SELECT * FROM alert_lines').get();
  assert.equal(row.lane, 'merge-conductor'); assert.equal(row.project, 'demo');
  assert.equal(row.line, `${STAMP} conductor text`); assert.equal(row.stamp, STAMP);
  assert.equal(row.severity, 'warn'); assert.equal(row.alertid, 'x-1'); assert.equal(row.run_id, 'r1');
  assert.equal(row.applied_at, null);
  assert.match(row.dedup_key, /^[0-9a-f]{64}$/);
  const d = await call(DB, 'POST', '/api/alert-lines', line());
  assert.equal(d.status, 200);
  assert.equal(d.body.dup, true);
  assert.equal(d.body.id, r.body.id);
  assert.equal(n(db, 'SELECT COUNT(*) n FROM alert_lines'), 1);
  // Another run's same text is its own row: the key binds lane, project, run and line.
  const other = await call(DB, 'POST', '/api/alert-lines', line({ run_id: 'r2' }));
  assert.equal(other.body.dup, false);
  assert.equal(n(db, 'SELECT COUNT(*) n FROM alert_lines'), 2);
  // The optional fields can be absent.
  const bare = await call(DB, 'POST', '/api/alert-lines', { lane: 'merge-conductor', project: 'demo', line: 'bare text' });
  assert.equal(bare.status, 200, JSON.stringify(bare.body));

  for (const [field, b] of [
    ['lane', line({ lane: '' })], ['lane', line({ lane: 'a b' })], ['project', line({ project: '-x' })],
    ['line', line({ line: '' })], ['line', line({ line: 'a\nb', stamp: undefined })],
    ['line', line({ line: 'x'.repeat(2001), stamp: undefined })],
    ['stamp', line({ stamp: 'x'.repeat(41) })], ['stamp', line({ stamp: '2026-10-15 01:00:00Z' })],
    ['severity', line({ severity: 'loud' })], ['alertid', line({ alertid: 'x'.repeat(121) })],
    ['run_id', line({ run_id: 'x'.repeat(121) })],
  ]) {
    const x = await call(DB, 'POST', '/api/alert-lines', b);
    assert.equal(x.status, 400, `${field}: ${JSON.stringify(x.body)}`);
    assert.match(x.body.error, new RegExp(`^${field}\\b`), `${field}: ${x.body.error}`);
  }
  assert.equal((await call(DB, 'POST', '/api/alert-lines', line(), false)).status, 401);
  assert.equal((await call(DB, 'GET', '/api/alert-lines?unapplied=1', undefined, false)).status, 401);
  assert.equal((await call(DB, 'POST', '/api/alert-lines/applied', { ids: [1] }, false)).status, 401);
});

test('W2 the unapplied read pages and truncates; applied marks once', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { DB } = o;
  const ids = [];
  for (const txt of ['one', 'two', 'three']) {
    ids.push((await call(DB, 'POST', '/api/alert-lines', line({ line: `${STAMP} ${txt}` }))).body.id);
  }
  const g = await call(DB, 'GET', '/api/alert-lines?unapplied=1&limit=2');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.deepEqual(g.body.lines.map((x) => x.id), ids.slice(0, 2));
  assert.equal(g.body.truncated, true);
  assert.ok(g.body.as_of);
  assert.equal(g.body.lines[0].line, `${STAMP} one`);
  assert.equal(g.body.lines[0].alertid, 'x-1');
  assert.match(g.body.lines[0].dedup_key, /^[0-9a-f]{64}$/);
  const a = await call(DB, 'POST', '/api/alert-lines/applied', { ids: ids.slice(0, 2) });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.applied, 2);
  assert.equal((await call(DB, 'POST', '/api/alert-lines/applied', { ids: ids.slice(0, 2) })).body.applied, 0);
  const g2 = await call(DB, 'GET', '/api/alert-lines?unapplied=1');
  assert.deepEqual(g2.body.lines.map((x) => x.id), [ids[2]]);
  assert.equal(g2.body.truncated, false);
  for (const q of ['unapplied=1&limit=0', 'unapplied=1&limit=501', 'unapplied=1&limit=x', 'limit=2']) {
    assert.equal((await call(DB, 'GET', `/api/alert-lines?${q}`)).status, 400, q);
  }
  for (const [why, b] of [['no ids', {}], ['empty', { ids: [] }], ['not ints', { ids: ['a'] }], ['zero', { ids: [0] }],
    ['too many', { ids: Array.from({ length: 501 }, (_, i) => i + 1) }]]) {
    assert.equal((await call(DB, 'POST', '/api/alert-lines/applied', b)).status, 400, why);
  }
});

test('W3 EXPLAIN QUERY PLAN on 5,000 rows: each statement uses its index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const SQL = await import('../src/routes/alert-lines.js');
  const { RULES } = await import('../src/routes/retention.js');
  const ins = db.prepare(`INSERT INTO alert_lines (lane,project,line,dedup_key,created_at,applied_at)
    VALUES ('merge-conductor',?,?,?,?,?)`);
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    const applied = i < 4000;
    ins.run(`p${i % 10}`, `line ${i}`, `k${String(i).padStart(6, '0')}`, ago(i % 10), applied ? ago(i % 10) : null);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail).join(' | ');
  const rule = (name) => RULES.find((r) => r.rule === name);
  assert.ok(rule('alert_lines.applied') && rule('alert_lines.unapplied'), 'both retention rules exist');
  const cases = [
    ['unapplied read', SQL.UNAPPLIED_SQL, [201], /idx_alert_lines_applied/],
    ['dedup lookup', SQL.BY_KEY_SQL, ['k000001'], /ux_alert_lines_dedup/],
    ['mark applied', SQL.APPLIED_SQL, [ago(0), '[1,2]'], /PRIMARY KEY|INTEGER PRIMARY KEY/],
    ['applied retention ids', rule('alert_lines.applied').ids, [ago(7), 10], /idx_alert_lines_applied/],
    ['unapplied retention ids', rule('alert_lines.unapplied').ids, [ago(30), 10], /idx_alert_lines_applied/],
  ];
  for (const [name, sql, b, idx] of cases) {
    const p = plan(sql, ...b);
    assert.match(p, idx, `${name}: ${p}`);
    assert.doesNotMatch(p, /SCAN alert_lines(?! USING)/, `${name}: ${p}`);
  }
  const idx = db.prepare('PRAGMA index_list(alert_lines)').all();
  assert.ok(idx.some((r) => r.name === 'ux_alert_lines_dedup' && r.unique === 1), 'the insert conflict target is a unique index');
  // The insert hits a seeded key and adds nothing.
  db.prepare(SQL.INSERT_SQL).run('merge-conductor', 'p1', 'line 1', null, null, null, null, 'k000001', ago(0));
  assert.equal(n(db, 'SELECT COUNT(*) n FROM alert_lines'), 5000);
});

test('W4 the seeds, and retention removes applied past 7 days and unapplied past 30 days', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const s = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(s('retention.alert_lines.applied_days'), '7');
  assert.equal(s('retention.alert_lines.unapplied_days'), '30');
  assert.equal(s('alert_lines.apply_max'), '200');
  const now = new Date().toISOString(); // determinism: ok retention cuts against the worker clock; the rows are days off it
  const off = (d) => new Date(Date.parse(now) - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ins = db.prepare(`INSERT INTO alert_lines (lane,project,line,dedup_key,created_at,applied_at)
    VALUES ('merge-conductor','demo',?,?,?,?)`);
  ins.run('applied-old', 'a1', off(20), off(8));
  ins.run('applied-new', 'a2', off(20), off(3));
  ins.run('unapplied-old', 'a3', off(31), null);
  ins.run('unapplied-new', 'a4', off(10), null);
  const kept = () => db.prepare('SELECT line FROM alert_lines ORDER BY id').all().map((x) => x.line);
  db.prepare("UPDATE settings SET value='1' WHERE key='retention.dry_run'").run();
  const dry = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.deepEqual(kept(), ['applied-old', 'applied-new', 'unapplied-old', 'unapplied-new'], 'a dry run removes nothing');
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const r = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(kept(), ['applied-new', 'unapplied-new']);
  const rules = r.body.rules.map((x) => x.rule);
  assert.ok(rules.includes('alert_lines.applied') && rules.includes('alert_lines.unapplied'), rules.join(','));
  assert.equal(n(db, "SELECT COUNT(*) n FROM retention_runs WHERE rule IN ('alert_lines.applied','alert_lines.unapplied')"), 4);
});

test('W5 a dropped table answers 503 on every route', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  db.exec('DROP TABLE alert_lines;');
  for (const [m, p, b] of [
    ['POST', '/api/alert-lines', line()], ['GET', '/api/alert-lines?unapplied=1'],
    ['POST', '/api/alert-lines/applied', { ids: [1] }],
  ]) {
    const r = await call(DB, m, p, b);
    assert.equal(r.status, 503, `${m} ${p}`);
    assert.match(r.body.error, /schema not applied/);
  }
});
