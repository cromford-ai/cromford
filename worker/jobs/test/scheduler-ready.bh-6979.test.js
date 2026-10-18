// BH-6979 (BH-6547.3): the scheduler's ready set through the real worker on
// node:sqlite with the composed schema.
//
//   W-ready-1 a POST with verdicts writes N sched_ready rows; a retry of the
//             same (project, at) writes 0; mode enforce is accepted
//   W-ready-2 GET /api/scheduler/ready answers the newest tick's set, ordered
//             by ticket number, with complete true/false; no tick -> at:null
//   W-ready-3 a bad verdict or mode -> 400 and no row in any table
//   W-ready-4 EXPLAIN QUERY PLAN on READY_SQL and the retention id read with
//             30k sched_ready rows and 2k ticks: the named indexes, no SCAN
//   W-ready-5 retention rule sched_ready.age: a dry run deletes nothing, a
//             real run deletes rows past the window and keeps newer ones
//   W-ready-6 no bearer -> 401; the settings rows are seeded
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-6979';
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
const counts = (o = {}) => ({ candidates: 4, ready: 1, not_ready: 1, unknown: 1, in_flight: 1, compared: 0, agreed: 0, idle: 0, ...o });
const V = [
  { ticket: '501', ready: 'yes', reason: '' },
  { ticket: '502', ready: 'no', reason: 'parent #500 open' },
  { ticket: '503', ready: 'unknown', reason: 'parent #9 unreadable' },
  { ticket: '1000', ready: 'in-flight', reason: 'in flight' },
];
const tick = (o = {}) => ({ project: 'proj', at: '2026-10-15T10:05:00Z', mode: 'enforce', counts: counts(), diffs: [], verdicts: V, ...o });
const n = (db, sql, ...b) => db.prepare(sql).get(...b).n;
const all = (db) => n(db, 'SELECT COUNT(*) n FROM sched_ticks') + n(db, 'SELECT COUNT(*) n FROM sched_diffs') + n(db, 'SELECT COUNT(*) n FROM sched_ready');

test('W-ready-1 a POST with verdicts writes N rows once; enforce is a mode', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const r = await call(DB, 'POST', '/api/scheduler/diffs', tick());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.tick_written, 1); assert.equal(r.body.verdicts_written, 4);
  assert.equal(db.prepare('SELECT mode FROM sched_ticks').get().mode, 'enforce', 'the mode is the body mode, not a literal');
  assert.deepEqual(db.prepare('SELECT project, at, ticket, ready, reason FROM sched_ready ORDER BY id').all().map((x) => ({ ...x })), V.map((v) => ({ project: 'proj', at: '2026-10-15T10:05:00Z', ...v })));
  const again = await call(DB, 'POST', '/api/scheduler/diffs', tick());
  assert.equal(again.body.tick_written, 0); assert.equal(again.body.verdicts_written, 0);
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_ready'), 4);
  // A shadow tick with no verdicts: no verdicts_written key (the wave-2 answer).
  const s = await call(DB, 'POST', '/api/scheduler/diffs', tick({ at: '2026-10-15T10:10:00Z', mode: 'shadow', verdicts: undefined }));
  assert.equal(s.body.tick_written, 1);
  assert.equal('verdicts_written' in s.body, false);
  assert.equal(db.prepare("SELECT mode FROM sched_ticks WHERE at='2026-10-15T10:10:00Z'").get().mode, 'shadow');
});

test('W-ready-2 GET ready answers the newest tick set with complete', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { DB } = o;
  const none = await call(DB, 'GET', '/api/scheduler/ready?project=proj');
  assert.equal(none.status, 200, JSON.stringify(none.body));
  assert.equal(none.body.ok, true); assert.equal(none.body.at, null); assert.equal(none.body.complete, false);
  assert.deepEqual(none.body.verdicts, []);
  assert.equal((await call(DB, 'POST', '/api/scheduler/diffs', tick({ at: '2026-10-15T10:00:00Z', verdicts: [V[1]], counts: counts({ candidates: 1 }) }))).status, 200);
  assert.equal((await call(DB, 'POST', '/api/scheduler/diffs', tick({ verdicts: [V[3], V[0], V[2], V[1]] }))).status, 200);
  assert.equal((await call(DB, 'POST', '/api/scheduler/diffs', tick({ project: 'other', at: '2026-10-15T11:00:00Z' }))).status, 200);
  const r = await call(DB, 'GET', '/api/scheduler/ready?project=proj');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.at, '2026-10-15T10:05:00Z', 'the newest tick of this project only');
  assert.equal(r.body.mode, 'enforce'); assert.equal(r.body.candidates, 4); assert.equal(r.body.complete, true);
  assert.deepEqual(r.body.verdicts, V, 'ordered by ticket number (1000 after 503), each with its reason');
  // Fewer verdicts than candidates: complete is false.
  assert.equal((await call(DB, 'POST', '/api/scheduler/diffs', tick({ at: '2026-10-15T10:15:00Z', verdicts: [V[0]] }))).status, 200);
  const p = await call(DB, 'GET', '/api/scheduler/ready?project=proj');
  assert.equal(p.body.at, '2026-10-15T10:15:00Z');
  assert.equal(p.body.complete, false);
  assert.deepEqual(p.body.verdicts, [V[0]]);
  // A tick with no candidates is a complete empty set.
  assert.equal((await call(DB, 'POST', '/api/scheduler/diffs', tick({ at: '2026-10-15T10:20:00Z', verdicts: [], counts: counts({ candidates: 0 }) }))).status, 200);
  const e = await call(DB, 'GET', '/api/scheduler/ready?project=proj');
  assert.equal(e.body.at, '2026-10-15T10:20:00Z'); assert.equal(e.body.candidates, 0); assert.equal(e.body.complete, true);
  assert.deepEqual(e.body.verdicts, []);
  for (const q of ['', '?project=a%20b']) assert.equal((await call(DB, 'GET', `/api/scheduler/ready${q}`)).status, 400, q);
});

test('W-ready-3 one bad verdict field or mode is a 400 and writes nothing', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const many = Array.from({ length: 1001 }, (_, i) => ({ ticket: String(1 + i), ready: 'yes', reason: '' }));
  for (const [why, b] of [
    ['mode bogus', tick({ mode: 'bogus' })],
    ['verdicts not an array', tick({ verdicts: 'x' })],
    ['1001 verdicts', tick({ verdicts: many })],
    ['ticket BH-1', tick({ verdicts: [V[0], { ticket: 'BH-1', ready: 'yes', reason: '' }] })],
    ['ready maybe', tick({ verdicts: [{ ticket: '7', ready: 'maybe', reason: 'x' }] })],
    ['reason of 201 chars', tick({ verdicts: [{ ticket: '7', ready: 'no', reason: 'x'.repeat(201) }] })],
    ['a no with an empty reason', tick({ verdicts: [{ ticket: '7', ready: 'no', reason: '' }] })],
    ['reason not a string', tick({ verdicts: [{ ticket: '7', ready: 'yes', reason: null }] })],
    ['a verdict not an object', tick({ verdicts: [7] })],
  ]) {
    const x = await call(DB, 'POST', '/api/scheduler/diffs', b);
    assert.equal(x.status, 400, `${why}: ${JSON.stringify(x.body)}`);
    assert.equal(all(db), 0, `${why}: no row written`);
  }
  const edge = await call(DB, 'POST', '/api/scheduler/diffs', tick({ verdicts: [{ ticket: '7', ready: 'no', reason: 'x'.repeat(200) }] }));
  assert.equal(edge.status, 200, JSON.stringify(edge.body));
});

test('W-ready-4 EXPLAIN QUERY PLAN with 30k verdict rows and 2k ticks', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const SQL = await import('../src/routes/scheduler.js');
  const { RULES } = await import('../src/routes/retention.js');
  const it = db.prepare(`INSERT INTO sched_ticks (project,at,mode,candidates,ready,not_ready,unknown,in_flight,compared,agreed,idle)
    VALUES (?,?,'enforce',15,15,0,0,0,0,0,0)`);
  const ir = db.prepare("INSERT INTO sched_ready (project,at,ticket,ready,reason) VALUES (?,?,?,'yes','')");
  const minutes = (i) => new Date(NOW - i * 300e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  db.exec('BEGIN');
  for (let i = 0; i < 2000; i++) {
    it.run(`p${i % 4}`, minutes(i));
    for (let k = 0; k < 15; k++) ir.run(`p${i % 4}`, minutes(i), String(100 + k));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_ready'), 30000);
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail).join(' | ');
  const rule = RULES.find((r) => r.rule === 'sched_ready.age');
  assert.ok(rule, 'the sched_ready.age rule exists');
  assert.equal(rule.key, 'retention.sched_ready.days');
  assert.equal(rule.def, 3);
  for (const [name, sql, b, idx] of [
    ['ready read', SQL.READY_SQL, ['p1'], [/ux_sched_ticks_pa/, /ux_sched_ready_pat/]],
    ['ready insert', SQL.READY_INSERT_SQL, ['p1', minutes(0), JSON.stringify([['1', 'yes', '']])], []],
    ['ready retention ids', rule.ids, [ago(3), 10], [/idx_sched_ready_at/]],
  ]) {
    assert.equal(typeof sql, 'string', `${name}: the statement is exported`);
    const p = plan(sql, ...b);
    for (const re of idx) assert.match(p, re, `${name}: ${p}`);
    assert.doesNotMatch(p, /SCAN (sched_ticks|sched_ready)(?! USING)/, `${name}: ${p}`);
  }
  // The read returns the newest tick of p1 and its 15 rows.
  const rows = db.prepare(SQL.READY_SQL).all('p1');
  assert.equal(rows.length, 15);
  assert.equal(rows[0].at, minutes(1));
});

test('W-ready-5 retention sched_ready.age: dry run first, then rows past the window go', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const now = new Date().toISOString(); // determinism: ok retention cuts against the worker clock; the rows are 1 and 10 days off it
  const off = (d) => new Date(Date.parse(now) - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ir = db.prepare("INSERT INTO sched_ready (project,at,ticket,ready,reason) VALUES ('proj',?,?,'yes','')");
  ir.run(off(10), '1'); ir.run(off(10), '2'); ir.run(off(1), '3');
  const dry = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_ready'), 3, 'the seeded dry run deletes nothing');
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const r = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(db.prepare('SELECT ticket FROM sched_ready').all().map((x) => x.ticket), ['3']);
  assert.ok(r.body.rules.map((x) => x.rule).includes('sched_ready.age'));
  assert.equal(n(db, "SELECT COUNT(*) n FROM retention_runs WHERE rule='sched_ready.age'"), 2, 'one audit row per run');
});

test('W-ready-6 no bearer is a 401; the settings rows are seeded', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  assert.equal((await call(DB, 'GET', '/api/scheduler/ready?project=proj', undefined, false)).status, 401);
  const s = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(s('scheduler.ready_max_age_s'), '900');
  assert.equal(s('scheduler.sibling_checks_max'), '20');
  assert.equal(s('retention.sched_ready.days'), '3');
  assert.equal(s('scheduler.mode'), 'shadow', 'the seed does not flip the mode');
});
