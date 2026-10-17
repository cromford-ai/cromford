// BH-6978 (BH-6547.2): the scheduler shadow routes through the real worker on
// node:sqlite with the composed schema.
//
//   W1 POST diffs writes 1 tick row and N diff rows; the same body again
//      writes 0 and 0; no bearer 401 on every route
//   W2 400 for each bad field; no row written
//   W3 GET holds answers the latest row per ticket (hold then resume: resume)
//   W4 GET agreement: rate, null rate when compared=0, top 5 cut and order,
//      project filter, 400 on a bad day
//   W5 EXPLAIN QUERY PLAN on 5,000 seeded rows per table: every exported
//      statement and both retention id reads use the named index, no SCAN of
//      sched_ticks, sched_diffs or ticket_holds
//   W6 the five settings rows exist with their seeded values
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-6978';
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
const counts = (o = {}) => ({ candidates: 6, ready: 3, not_ready: 2, unknown: 0, in_flight: 1, compared: 4, agreed: 3, idle: 1, ...o });
const diff = (o = {}) => ({ ticket: '401', scheduler_says: 'ready', lanes_did: 'held:triage', reason: 'overlap-guard DEFER', reason_class: 'lanes-held:triage', ...o });
const tick = (o = {}) => ({
  project: 'proj', at: '2026-10-15T10:05:00Z', mode: 'shadow', counts: counts(),
  diffs: [diff(), diff({ ticket: '402', scheduler_says: 'not-ready', lanes_did: 'dispatched', reason: 'parent #90 open', reason_class: 'parent-open' })],
  ...o,
});
const n = (db, sql, ...b) => db.prepare(sql).get(...b).n;
const rows = (db) => n(db, 'SELECT COUNT(*) n FROM sched_ticks') + n(db, 'SELECT COUNT(*) n FROM sched_diffs');

test('W1 POST diffs writes the tick and its diffs once; a retry writes nothing; no bearer 401', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const r = await call(DB, 'POST', '/api/scheduler/diffs', tick());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { ok: true, tick_written: 1, diffs_written: 2 });
  const tk = db.prepare('SELECT * FROM sched_ticks').all();
  assert.equal(tk.length, 1);
  assert.equal(tk[0].project, 'proj'); assert.equal(tk[0].mode, 'shadow'); assert.equal(tk[0].at, '2026-10-15T10:05:00Z');
  assert.equal(tk[0].compared, 4); assert.equal(tk[0].agreed, 3); assert.equal(tk[0].idle, 1); assert.equal(tk[0].in_flight, 1);
  assert.equal(tk[0].partial, null);
  const d = db.prepare('SELECT * FROM sched_diffs ORDER BY ticket').all();
  assert.equal(d.length, 2);
  assert.equal(d[0].ticket, '401'); assert.equal(d[0].scheduler_says, 'ready'); assert.equal(d[0].lanes_did, 'held:triage');
  assert.equal(d[0].reason_class, 'lanes-held:triage'); assert.equal(d[0].at, '2026-10-15T10:05:00Z');
  assert.equal(d[1].reason, 'parent #90 open');

  const again = await call(DB, 'POST', '/api/scheduler/diffs', tick());
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.deepEqual(again.body, { ok: true, tick_written: 0, diffs_written: 0 });
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_ticks'), 1);
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_diffs'), 2);

  // A partial tick: compared=0, no diffs, partial names the failed inputs.
  const p = await call(DB, 'POST', '/api/scheduler/diffs', tick({ at: '2026-10-15T10:10:00Z', partial: 'decisions', counts: counts({ compared: 0, agreed: 0 }), diffs: [] }));
  assert.deepEqual(p.body, { ok: true, tick_written: 1, diffs_written: 0 });
  assert.equal(db.prepare("SELECT partial FROM sched_ticks WHERE at='2026-10-15T10:10:00Z'").get().partial, 'decisions');

  assert.equal((await call(DB, 'POST', '/api/scheduler/diffs', tick(), false)).status, 401);
  assert.equal((await call(DB, 'GET', '/api/scheduler/holds?project=proj', undefined, false)).status, 401);
  assert.equal((await call(DB, 'GET', '/api/scheduler/agreement?day=2026-10-15', undefined, false)).status, 401);
});

test('W2 one bad field is a 400 and writes no row', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const future = new Date(Date.now() + 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z'); // determinism: ok the route refuses an at more than 600 s past the worker clock, so the fixture reads that clock
  const many = Array.from({ length: 201 }, (_, i) => diff({ ticket: String(1000 + i) }));
  for (const [why, b] of [
    ['no project', tick({ project: '' })], ['bad project', tick({ project: 'a b' })],
    ['at not ISO', tick({ at: '2026-10-15 10:05' })], ['at in the future', tick({ at: future })],
    ['mode', tick({ mode: 'enforce' })], ['no counts', tick({ counts: null })],
    ['a count of -1', tick({ counts: counts({ ready: -1 }) })], ['a count not an integer', tick({ counts: counts({ idle: 1.5 }) })],
    ['a count over 100000', tick({ counts: counts({ candidates: 100001 }) })], ['a count missing', tick({ counts: { ...counts(), agreed: undefined } })],
    ['diffs not an array', tick({ diffs: 'x' })], ['201 diffs', tick({ diffs: many })],
    ['ticket 0', tick({ diffs: [diff(), diff({ ticket: '0' })] })], ['ticket BH-1', tick({ diffs: [diff({ ticket: 'BH-1' })] })],
    ['scheduler_says maybe', tick({ diffs: [diff({ scheduler_says: 'maybe' })] })],
    ['lanes_did upper case', tick({ diffs: [diff({ lanes_did: 'Held' })] })],
    ['reason_class with a space', tick({ diffs: [diff({ reason_class: 'parent open' })] })],
    ['reason empty', tick({ diffs: [diff({ reason: '' })] })], ['reason of 201 chars', tick({ diffs: [diff({ reason: 'x'.repeat(201) })] })],
    ['partial not a string', tick({ partial: 7 })],
  ]) {
    const x = await call(DB, 'POST', '/api/scheduler/diffs', b);
    assert.equal(x.status, 400, `${why}: ${JSON.stringify(x.body)}`);
    assert.equal(rows(db), 0, `${why}: no row written`);
  }
  // The edges of the bounds are accepted.
  const ok = await call(DB, 'POST', '/api/scheduler/diffs', tick({ diffs: [diff({ reason: 'x'.repeat(200) })], counts: counts({ candidates: 100000, unknown: 0 }) }));
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
});

test('W3 GET holds answers the latest row per ticket', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const ih = db.prepare('INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES (?,?,?,?,?,?)');
  ih.run('proj', '301', 'hold', 'operator', '2026-10-15T09:00:00Z', '1');
  ih.run('proj', '301', 'resume', 'operator', '2026-10-15T10:00:00Z', '2');
  ih.run('proj', '302', 'hold', 'someone', '2026-10-15T08:00:00Z', '3');
  ih.run('other', '303', 'hold', 'x', '2026-10-15T08:00:00Z', '4');
  const r = await call(DB, 'GET', '/api/scheduler/holds?project=proj');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.holds, [
    { ticket: '301', state: 'resume', by: 'operator', at: '2026-10-15T10:00:00Z' },
    { ticket: '302', state: 'hold', by: 'someone', at: '2026-10-15T08:00:00Z' },
  ]);
  ih.run('proj', '301', 'hold', 'operator', '2026-10-15T11:00:00Z', '5');
  const r2 = await call(DB, 'GET', '/api/scheduler/holds?project=proj');
  assert.equal(r2.body.holds[0].state, 'hold', 'a newer hold after the resume wins');
  assert.deepEqual((await call(DB, 'GET', '/api/scheduler/holds?project=none')).body, { holds: [] });
  assert.equal((await call(DB, 'GET', '/api/scheduler/holds')).status, 400);
  assert.equal((await call(DB, 'GET', '/api/scheduler/holds?project=a%20b')).status, 400);
  db.exec('DROP TABLE ticket_holds');
  const g = await call(DB, 'GET', '/api/scheduler/holds?project=proj');
  assert.equal(g.status, 503);
  assert.match(g.body.error, /ticket_holds schema not applied/);
});

test('W4 GET agreement: rate, null rate, top 5 order, project filter, bad day', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const it = db.prepare(`INSERT INTO sched_ticks (project,at,mode,candidates,ready,not_ready,unknown,in_flight,compared,agreed,idle,partial)
    VALUES (?,?,'shadow',5,2,3,0,0,?,?,?,NULL)`);
  it.run('bh', '2026-10-15T00:00:00Z', 4, 4, 1);
  it.run('bh', '2026-10-15T12:00:00Z', 3, 2, 0);
  it.run('bh', '2026-10-15T23:55:00Z', 3, 3, 2);
  it.run('bh', '2026-10-16T00:00:00Z', 9, 0, 0); // the next day: out of the window
  it.run('bh', '2026-10-14T23:55:00Z', 9, 0, 0); // the day before
  it.run('quiet', '2026-10-15T06:00:00Z', 0, 0, 3);
  const idf = db.prepare(`INSERT INTO sched_diffs (project,ticket,scheduler_says,lanes_did,reason,reason_class,at)
    VALUES (?,?,'ready','held:triage','r',?,?)`);
  let tk = 100;
  const seed = (proj, cls, k, at = '2026-10-15T12:00:00Z') => { for (let i = 0; i < k; i++) idf.run(proj, String(tk++), cls, at); };
  seed('bh', 'parent-open', 4);
  seed('bh', 'lanes-held:triage', 6);
  seed('bh', 'hold', 2);
  seed('bh', 'files-claimed', 2);
  seed('bh', 'wip-cap', 1);
  seed('bh', 'lanes-held:pool', 1);
  seed('bh', 'zzz-old', 50, '2026-10-14T12:00:00Z');
  seed('quiet', 'hold', 1);

  const r = await call(DB, 'GET', '/api/scheduler/agreement?day=2026-10-15');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.day, '2026-10-15');
  assert.equal(r.body.from, '2026-10-15T00:00:00Z');
  assert.equal(r.body.to, '2026-10-16T00:00:00Z');
  assert.deepEqual(r.body.projects.map((p) => p.project), ['bh', 'quiet']);
  const bh = r.body.projects[0];
  assert.equal(bh.ticks, 3); assert.equal(bh.compared, 10); assert.equal(bh.agreed, 9); assert.equal(bh.idle, 3);
  assert.equal(bh.rate, 0.9);
  assert.deepEqual(bh.top, [
    { reason_class: 'lanes-held:triage', n: 6 },
    { reason_class: 'parent-open', n: 4 },
    { reason_class: 'files-claimed', n: 2 },
    { reason_class: 'hold', n: 2 },
    { reason_class: 'lanes-held:pool', n: 1 },
  ], 'top 5: n descending, ties by reason_class; wip-cap is the sixth and is cut');
  const quiet = r.body.projects[1];
  assert.equal(quiet.compared, 0); assert.equal(quiet.rate, null);
  assert.deepEqual(quiet.top, [{ reason_class: 'hold', n: 1 }]);

  // 2 of 3 rounds to 3 places.
  it.run('third', '2026-10-15T01:00:00Z', 3, 2, 0);
  const f = await call(DB, 'GET', '/api/scheduler/agreement?day=2026-10-15&project=third');
  assert.equal(f.status, 200, JSON.stringify(f.body));
  assert.deepEqual(f.body.projects, [{ project: 'third', ticks: 1, compared: 3, agreed: 2, idle: 0, rate: 0.667, top: [] }]);
  const none = await call(DB, 'GET', '/api/scheduler/agreement?day=2026-10-13');
  assert.deepEqual(none.body.projects, []);

  for (const q of ['', '?day=2026-13-01', '?day=2026-02-30', '?day=yesterday', '?day=2999-01-01', '?day=2026-10-15&project=a%20b']) {
    assert.equal((await call(DB, 'GET', `/api/scheduler/agreement${q}`)).status, 400, q);
  }
});

test('W5 EXPLAIN QUERY PLAN on 5,000 rows per table: each statement uses its index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const SQL = await import('../src/routes/scheduler.js');
  const { RULES } = await import('../src/routes/retention.js');
  const it = db.prepare(`INSERT INTO sched_ticks (project,at,mode,candidates,ready,not_ready,unknown,in_flight,compared,agreed,idle)
    VALUES (?,?,'shadow',5,2,3,0,0,4,3,1)`);
  const idf = db.prepare(`INSERT INTO sched_diffs (project,ticket,scheduler_says,lanes_did,reason,reason_class,at)
    VALUES (?,?,'ready','held:triage','r',?,?)`);
  const ih = db.prepare("INSERT INTO ticket_holds (project,ticket,state,by,at,comment_id) VALUES (?,?,'hold','x',?,?)");
  const minutes = (i) => new Date(NOW - i * 300e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    it.run(`p${i % 10}`, minutes(i));
    idf.run(`p${i % 10}`, String(1 + (i % 700)), ['parent-open', 'hold', 'wip-cap', 'lanes-held:triage'][i % 4], minutes(i));
    ih.run(`p${i % 10}`, String(1 + (i % 700)), ago(i % 400), String(50000 + i));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail).join(' | ');
  const rule = (name) => RULES.find((r) => r.rule === name);
  assert.ok(rule('sched_diffs.age') && rule('sched_ticks.age'), 'both retention rules exist');
  assert.equal(rule('sched_diffs.age').key, 'retention.sched_diffs.days');
  assert.equal(rule('sched_ticks.age').key, 'retention.sched_ticks.days');
  const from = '2026-10-15T00:00:00Z', to = '2026-10-16T00:00:00Z';
  const cases = [
    ['holds latest', SQL.HOLDS_LATEST_SQL, ['p1'], /idx_ticket_holds_ticket_at/],
    ['tick insert', SQL.TICK_INSERT_SQL, ['p1', ago(0), 'shadow', 1, 1, 0, 0, 0, 0, 0, 0, null], null],
    ['diff insert', SQL.DIFF_INSERT_SQL, ['p1', '1', 'ready', 'dispatched', 'r', 'hold', ago(0)], null],
    ['agreement ticks', SQL.AGREE_TICKS_SQL, [from, to, null], /idx_sched_ticks_at/],
    ['agreement ticks, one project', SQL.AGREE_TICKS_SQL, [from, to, 'p1'], /idx_sched_ticks_at/],
    ['agreement top', SQL.AGREE_TOP_SQL, [from, to, null], /idx_sched_diffs_at/],
    ['agreement top, one project', SQL.AGREE_TOP_SQL, [from, to, 'p1'], /idx_sched_diffs_at/],
    ['diff retention ids', rule('sched_diffs.age').ids, [ago(30), 10], /idx_sched_diffs_at/],
    ['tick retention ids', rule('sched_ticks.age').ids, [ago(30), 10], /idx_sched_ticks_at/],
  ];
  for (const [name, sql, b, idx] of cases) {
    assert.equal(typeof sql, 'string', `${name}: the statement is exported`);
    const p = plan(sql, ...b);
    if (idx) assert.match(p, idx, `${name}: ${p}`);
    assert.doesNotMatch(p, /SCAN (sched_ticks|sched_diffs|ticket_holds)(?! USING)/, `${name}: ${p}`);
  }
  const idx = (tbl) => db.prepare(`PRAGMA index_list(${tbl})`).all().map((r) => r.name);
  assert.ok(idx('sched_ticks').includes('ux_sched_ticks_pa'), 'the tick conflict target is a unique index');
  assert.ok(idx('sched_diffs').includes('ux_sched_diffs_pta'), 'the diff conflict target is a unique index');
  // The inserts hit seeded rows (i = 0: p0, ticket 1, at NOW) and add none.
  db.prepare(SQL.TICK_INSERT_SQL).run('p0', minutes(0), 'shadow', 1, 1, 0, 0, 0, 0, 0, 0, null);
  db.prepare(SQL.DIFF_INSERT_SQL).run('p0', '1', 'ready', 'dispatched', 'r', 'hold', minutes(0));
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_ticks'), 5000);
  assert.equal(n(db, 'SELECT COUNT(*) n FROM sched_diffs'), 5000);
});

test('W6 the five settings rows exist with their seeded values', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  const s = (k) => db.prepare('SELECT value, actor FROM settings WHERE key=?').get(k);
  for (const [k, v] of [
    ['scheduler.mode', 'shadow'], ['scheduler.projects', 'cromford'], ['scheduler.parent_reads_max', '20'],
    ['retention.sched_diffs.days', '30'], ['retention.sched_ticks.days', '30'],
  ]) {
    const row = s(k);
    assert.ok(row, `${k} is seeded`);
    assert.equal(row.value, v, k);
    assert.equal(row.actor, 'seed', k);
  }
});
