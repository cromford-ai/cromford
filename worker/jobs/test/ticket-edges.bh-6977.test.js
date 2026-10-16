// BH-6977 (BH-6547.1): ticket_edges and ticket_holds through the real worker
// on node:sqlite with the composed schema.
//
//   W1 POST an edge, GET it by child and by parent; bad fields 400; no bearer 401
//   W2 the same edge twice is one row; a planner write after a dep-verify
//      write keeps kind and verified_at; a later verdict changes the kind
//   W3 POST a hold, GET it; the same comment_id as resume is one row, resume
//   W4 the tables dropped: every route answers 503
//   W5 settings seed 365 / 365 / 20; retention removes 400-day-old rows of
//      both tables and keeps 30-day-old ones
//   W6 5,000 seeded rows per table: every exported statement and both
//      retention id reads use the named index, no plan SCANs either table
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-6977';
const NOW = Date.parse('2026-10-15T12:00:00Z');
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function call(DB, method, path, body, auth = true) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const edge = (o = {}) => ({ project: 'proj', parent: '11', child: '20', kind: 'hard', source: 'planner', ...o });
const hold = (o = {}) => ({ project: 'proj', ticket: '30', state: 'hold', by: 'operator-fixture', at: '2026-10-15T10:00:00Z', comment_id: '9001', ...o });
const n = (db, sql, ...b) => db.prepare(sql).get(...b).n;

test('W1 an edge round-trips by child and by parent; bad fields 400; no bearer 401', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { DB } = o;
  const r = await call(DB, 'POST', '/api/ticket-edges', edge({ planned_files: ['bin/a.sh', 'docs/b.md'] }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.kind, 'hard');
  assert.equal(r.body.verified_at, null);
  const byChild = await call(DB, 'GET', '/api/ticket-edges?project=proj&child=20');
  assert.equal(byChild.status, 200);
  assert.equal(byChild.body.edges.length, 1);
  const e = byChild.body.edges[0];
  assert.equal(e.parent, '11'); assert.equal(e.child, '20'); assert.equal(e.source, 'planner');
  assert.deepEqual(e.planned_files, ['bin/a.sh', 'docs/b.md']);
  const byParent = await call(DB, 'GET', '/api/ticket-edges?project=proj&parent=11');
  assert.equal(byParent.body.edges.length, 1);
  assert.equal(byParent.body.edges[0].id, r.body.id);
  const all = await call(DB, 'GET', '/api/ticket-edges?project=proj');
  assert.equal(all.body.edges.length, 1);
  assert.equal((await call(DB, 'GET', '/api/ticket-edges?project=other&child=20')).body.edges.length, 0);

  for (const [why, b] of [
    ['no project', edge({ project: '' })], ['bad project', edge({ project: 'a b' })],
    ['parent 0', edge({ parent: '0' })], ['child not a number', edge({ child: 'TK-12' })],
    ['self edge', edge({ parent: '20' })], ['kind', edge({ kind: 'maybe' })],
    ['source', edge({ source: 'robot' })], ['files not an array', edge({ planned_files: 'bin/a.sh' })],
    ['a file not a string', edge({ planned_files: [1] })], ['a file too long', edge({ planned_files: ['x'.repeat(301)] })],
    ['too many files', edge({ planned_files: Array.from({ length: 501 }, (_, i) => `f${i}`) })],
  ]) {
    const x = await call(DB, 'POST', '/api/ticket-edges', b);
    assert.equal(x.status, 400, `${why}: ${JSON.stringify(x.body)}`);
  }
  assert.equal((await call(DB, 'GET', '/api/ticket-edges?child=20')).status, 400, 'GET with no project');
  assert.equal((await call(DB, 'GET', '/api/ticket-edges?project=proj&child=x')).status, 400, 'GET with a bad child');
  assert.equal((await call(DB, 'GET', '/api/ticket-edges?project=proj&child=20&parent=11')).status, 400, 'GET with both');
  assert.equal((await call(DB, 'POST', '/api/ticket-edges', edge(), false)).status, 401);
  assert.equal((await call(DB, 'GET', '/api/ticket-edges?project=proj', undefined, false)).status, 401);
  assert.equal((await call(DB, 'POST', '/api/ticket-holds', hold(), false)).status, 401);
  assert.equal((await call(DB, 'GET', '/api/ticket-holds?project=proj&ticket=30', undefined, false)).status, 401);
});

test('W2 the same edge twice is one row; a planner write keeps a verdict; a later verdict moves it', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  await call(DB, 'POST', '/api/ticket-edges', edge());
  await call(DB, 'POST', '/api/ticket-edges', edge());
  assert.equal(n(db, "SELECT COUNT(*) n FROM ticket_edges WHERE project='proj' AND parent='11' AND child='20'"), 1);
  const v = await call(DB, 'POST', '/api/ticket-edges', edge({ kind: 'soft', source: 'dep-verify' }));
  assert.equal(v.status, 200);
  assert.equal(v.body.kind, 'soft');
  assert.ok(v.body.verified_at, 'a dep-verify write sets verified_at');
  const p = await call(DB, 'POST', '/api/ticket-edges', edge({ kind: 'hard', source: 'planner', planned_files: ['x.sh'] }));
  assert.equal(p.body.kind, 'soft', 'a planner write does not undo the verdict');
  const row = db.prepare("SELECT * FROM ticket_edges WHERE parent='11' AND child='20'").get();
  assert.equal(row.kind, 'soft'); assert.equal(row.source, 'dep-verify'); assert.ok(row.verified_at);
  assert.equal(row.planned_files, '["x.sh"]', 'planned_files still moves on a planner write');
  // A planner write with no planned_files keeps the stored list.
  await call(DB, 'POST', '/api/ticket-edges', edge());
  assert.equal(db.prepare("SELECT planned_files FROM ticket_edges WHERE parent='11'").get().planned_files, '["x.sh"]');
  const h = await call(DB, 'POST', '/api/ticket-edges', edge({ kind: 'hard', source: 'dep-verify' }));
  assert.equal(h.body.kind, 'hard', 'a later verdict changes the kind');
  assert.equal(n(db, 'SELECT COUNT(*) n FROM ticket_edges'), 1);
});

test('W3 a hold round-trips; the same comment as resume is one row', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const r = await call(DB, 'POST', '/api/ticket-holds', hold());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.state, 'hold');
  const g = await call(DB, 'GET', '/api/ticket-holds?project=proj&ticket=30');
  assert.equal(g.status, 200);
  assert.equal(g.body.holds.length, 1);
  assert.equal(g.body.holds[0].by, 'operator-fixture'); assert.equal(g.body.holds[0].comment_id, '9001');
  const e = await call(DB, 'POST', '/api/ticket-holds', hold({ state: 'resume' }));
  assert.equal(e.body.state, 'resume');
  assert.equal(n(db, 'SELECT COUNT(*) n FROM ticket_holds'), 1);
  assert.equal(db.prepare('SELECT state FROM ticket_holds').get().state, 'resume');
  await call(DB, 'POST', '/api/ticket-holds', hold({ comment_id: '9002', at: '2026-10-15T11:00:00Z' }));
  const g2 = await call(DB, 'GET', '/api/ticket-holds?project=proj&ticket=30');
  assert.deepEqual(g2.body.holds.map((x) => x.comment_id), ['9002', '9001'], 'newest first');
  for (const [why, b] of [
    ['project', hold({ project: '' })], ['ticket', hold({ ticket: 'TK-1' })], ['state', hold({ state: 'abandon' })],
    ['by', hold({ by: 'a b' })], ['at', hold({ at: 'yesterday' })], ['comment_id', hold({ comment_id: 'x' })],
  ]) {
    assert.equal((await call(DB, 'POST', '/api/ticket-holds', b)).status, 400, why);
  }
  assert.equal((await call(DB, 'GET', '/api/ticket-holds?project=proj')).status, 400, 'GET with no ticket');
});

test('W4 a dropped table answers 503 on every route', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  db.exec('DROP TABLE ticket_edges; DROP TABLE ticket_holds;');
  for (const [m, p, b] of [
    ['POST', '/api/ticket-edges', edge()], ['GET', '/api/ticket-edges?project=proj&child=20'],
    ['POST', '/api/ticket-holds', hold()], ['GET', '/api/ticket-holds?project=proj&ticket=30'],
  ]) {
    const r = await call(DB, m, p, b);
    assert.equal(r.status, 503, `${m} ${p}`);
    assert.match(r.body.error, /schema not applied/);
  }
});

test('W5 the seeds, and retention removes year-old rows of both tables', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const s = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(s('retention.ticket_edges.days'), '365');
  assert.equal(s('retention.ticket_holds.days'), '365');
  assert.equal(s('ticket_holds.wake_reads_max'), '20');
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const now = new Date().toISOString(); // determinism: ok retention cuts against the worker clock; the rows are 30 and 400 days off it
  const off = (d) => new Date(Date.parse(now) - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ie = db.prepare("INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES ('proj',?,?,'hard','planner',?)");
  ie.run('1', '2', off(400)); ie.run('3', '4', off(30));
  const ih = db.prepare("INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES ('proj','5','hold','x',?,?)");
  ih.run(off(400), '1'); ih.run(off(30), '2');
  const r = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT parent FROM ticket_edges').all().map((x) => x.parent), ['3']);
  assert.deepEqual(db.prepare('SELECT comment_id FROM ticket_holds').all().map((x) => x.comment_id), ['2']);
  const rules = r.body.rules.map((x) => x.rule);
  assert.ok(rules.includes('ticket_edges.age') && rules.includes('ticket_holds.age'), rules.join(','));
  assert.equal(n(db, "SELECT COUNT(*) n FROM retention_runs WHERE rule IN ('ticket_edges.age','ticket_holds.age')"), 2);
});

test('W6 EXPLAIN QUERY PLAN on 5,000 rows per table: each statement uses its index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const SQL = await import('../src/routes/ticket-edges.js');
  const { RULES } = await import('../src/routes/retention.js');
  const ie = db.prepare("INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES (?,?,?,'hard','planner',?)");
  const ih = db.prepare("INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES (?,?,'hold','x',?,?)");
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    ie.run(`p${i % 10}`, String(1 + (i % 700)), String(1000 + i), ago(i % 400));
    ih.run(`p${i % 10}`, String(1 + (i % 700)), ago(i % 400), String(50000 + i));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail).join(' | ');
  const rule = (name) => RULES.find((r) => r.rule === name);
  assert.ok(rule('ticket_edges.age') && rule('ticket_holds.age'), 'both retention rules exist');
  const cases = [
    ['edge put', SQL.EDGE_PUT_SQL, ['p1', '1', '1000', 'hard', null, 'planner', ago(0)], /ux_ticket_edges_pc|PRIMARY KEY/],
    ['edges by parent', SQL.EDGES_BY_PARENT_SQL, ['p1', '1'], /ux_ticket_edges_pc/],
    ['edges by child', SQL.EDGES_BY_CHILD_SQL, ['p1', '1000'], /idx_ticket_edges_child/],
    ['edges by project', SQL.EDGES_BY_PROJECT_SQL, ['p1'], /ux_ticket_edges_pc/],
    ['edge retention ids', rule('ticket_edges.age').ids, [ago(365), 10], /idx_ticket_edges_at/],
    ['holds by ticket', SQL.HOLDS_SQL, ['p1', '1'], /idx_ticket_holds_ticket_at/],
    ['hold retention ids', rule('ticket_holds.age').ids, [ago(365), 10], /idx_ticket_holds_at/],
  ];
  for (const [name, sql, b, idx] of cases) {
    const p = plan(sql, ...b);
    if (!/^INSERT/.test(sql)) assert.match(p, idx, `${name}: ${p}`);
    assert.doesNotMatch(p, /SCAN ticket_(edges|holds)(?! USING)/, `${name}: ${p}`);
  }
  const idx = (tbl) => db.prepare(`PRAGMA index_list(${tbl})`).all().map((r) => r.name);
  assert.ok(idx('ticket_edges').includes('ux_ticket_edges_pc'), 'the upsert conflict target is a unique index');
  assert.ok(idx('ticket_holds').includes('ux_ticket_holds_comment'), 'the hold conflict target is a unique index');
  // The upserts hit seeded rows (i = 1: p1, parent 2, child 1001, comment 50001) and add none.
  db.prepare(SQL.EDGE_VERDICT_SQL).get('p1', '2', '1001', 'soft', null, ago(0));
  db.prepare(SQL.HOLD_PUT_SQL).get('p1', '2', 'resume', 'x', ago(0), '50001');
  assert.equal(n(db, 'SELECT COUNT(*) n FROM ticket_edges'), 5000);
  assert.equal(n(db, 'SELECT COUNT(*) n FROM ticket_holds'), 5000);
});
