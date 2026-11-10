// BH-9127: Archie's turn rows (staff_turns) and the timeline that shows them,
// driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. The clock is pinned (D60) wherever the route reads it.
//
//   T-SCHEMA the composed schema applies twice; staff_turns has its two
//            indexes; the five BH-9127 settings rows are seeded
//   T1  POST /api/staff/turns: 201, the same body is a 200 replay, another
//       body under the same turn_key is 409
//   T2  400 naming each bad field; 404 for an agent not on the roster
//   T3  the stored summary is cut to staff.turns.summary_max_chars (fallback 200)
//   T3b the request bound is staff.turns.summary_in_max (fallback 2000); a
//       stored length over it is the stored fallback, never above the bound
//   T4  a GitHub-token shape in the summary is stored redacted; a near miss is kept
//   T5  archie's timeline holds its tick and its turn; the turn's cost comes
//       from cost rows by run_id; another agent's turn is not in it
//   T6  cursor paging across tick and turn events at the same second is exact
//   T-EXPLAIN every statement the activity route and the roster run reads
//            staff_turns, staff_ticks and cost rows through an index, on seeded volume
//   T-RET retention rule staff_turns.age: dry run counts, live run deletes,
//         one audit row per run
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaFile } from './lib/jobs-schema.js';
import { readFileSync } from 'node:fs';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'secret-fixture';
const call = (DB, path, { method = 'GET', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const KEY = 'archie-turn-1793923200-4242';
// The body bin/lib/archie-hb.sh archie_hb_turn posts (tests/archie-heartbeat.bh-9127-test.sh H4).
const turnBody = (over = {}) => ({
  agent: 'archie', turn_key: KEY,
  started_at: '2026-11-06T00:00:00Z', ended_at: '2026-11-06T00:01:40Z',
  trigger: 'telegram', outcome: 'answered',
  summary: 'Filed BH-1 and BH-2',
  link_url: 'https://github.com/example-org/cromford/pull/12',
  cost_run_id: `staff-turn:${KEY}`, ...over,
});
const postTurn = (DB, over) => call(DB, '/api/staff/turns', { method: 'POST', body: turnBody(over) });
const COUNTS = { collected: 0, new_items: 0, deferred: 0, model_calls: 1, digested: 0, filed: 0, refused: 0, unsupported: 0, failed: 0, held: 0 };
const postTick = (DB, over = {}) => call(DB, '/api/staff/ticks', { method: 'POST', body: {
  tick_key: 'archie-turn-1793923200-4242', agent: 'archie', started_at: '2026-11-06T00:00:00Z', ended_at: '2026-11-06T00:01:40Z',
  phase: 'done', collector_rc: null, collector_s: null, model_rc: null, ...COUNTS, cost_run_id: null, ...over,
} });
const activity = (DB, agent, q = '') => call(DB, `/api/staff/agent/${agent}/activity${q}`);
function costRow(db, n, runId, usd, { ts = '2026-11-06T00:01:00Z', lane = 'orc-monitor' } = {}) {
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, stage, model, rc, duration_s, cost_usd, session_id, run_id, lane_id, inserted_at)
              VALUES ('hub', ?, ?, ?, 'orc-turn', 'stub-model', 0, 12, ?, ?, ?, ?, '2026-11-06T00:02:00Z')`)
    .run(`t9127-${n}`, n, ts, usd, `sess-fixture-${n}`, runId, lane);
}
const setting = (db, key, value) => db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test','2026-11-06T00:00:00Z')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value));

test('T-SCHEMA the schema applies twice; staff_turns has both indexes; the settings rows are seeded', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  db.exec(readFileSync(jobsSchemaFile(), 'utf8'));  // a second apply is a no-op
  const ix = db.prepare('PRAGMA index_list(staff_turns)').all().map((r) => r.name);
  assert.ok(ix.includes('idx_staff_turns_agent_started'), ix.join(','));
  assert.ok(ix.includes('idx_staff_turns_started'), ix.join(','));
  const s = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
  assert.deepEqual(JSON.parse(s('staff.spend.lane_map')), { archie: ['orc-monitor', 'archie', 'archie-research', 'archie-cards', 'archie-learn'] });
  assert.equal(s('staff.spend.window_days'), '7');
  assert.equal(s('staff.turns.summary_in_max'), '2000');
  assert.equal(s('staff.turns.summary_max_chars'), '200');
  assert.equal(s('retention.staff_turns.days'), '90');
});

test('T1 POST /api/staff/turns: 201, replay 200, conflict 409', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const a = await postTurn(DB);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.replay, false);
  assert.equal(a.body.turn.turn_key, KEY);
  const b = await postTurn(DB);
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.replay, true);
  assert.equal(b.body.turn.id, a.body.turn.id);
  const c = await postTurn(DB, { summary: 'Another summary' });
  assert.equal(c.status, 409, JSON.stringify(c.body));
  assert.equal(c.body.error, 'turn_key_conflict');
  const rows = db.prepare('SELECT agent, trigger, outcome, summary, link_url, cost_run_id FROM staff_turns').all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].summary, 'Filed BH-1 and BH-2');
  assert.equal(rows[0].trigger, 'telegram');
  assert.equal(rows[0].cost_run_id, `staff-turn:${KEY}`);
  // A null link and a null cost run are allowed.
  const d = await postTurn(DB, { turn_key: 'archie-sweep-1793923300-1', link_url: null, cost_run_id: null, trigger: 'sweep', outcome: 'acted' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
});

test('T2 400 naming each bad field; 404 for an unknown agent', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const cases = [
    ['agent', { agent: 'Archie!' }],
    ['turn_key', { turn_key: 'Has Spaces' }],
    ['started_at', { started_at: '2026-11-06 00:00:00' }],
    ['ended_at', { ended_at: '2026-11-05T23:59:59Z' }],
    ['trigger', { trigger: 'cron' }],
    ['outcome', { outcome: 'maybe' }],
    ['cost_run_id', { cost_run_id: 'staff-tick:x' }],
    ['link_url', { link_url: 'https://evil.example/issues/1' }],
    ['link_url', { link_url: 'https://github.com/a/b/issues/1?x=1' }],
    ['link_url', { link_url: 'javascript:alert(1)' }],
    ['summary', { summary: 'x'.repeat(2001) }],
    ['summary', { summary: '   ' }],
    ['summary', { summary: 7 }],
  ];
  for (const [field, over] of cases) {
    const r = await postTurn(DB, over);
    assert.equal(r.status, 400, `${field} ${JSON.stringify(over).slice(0, 60)}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, field, JSON.stringify(over).slice(0, 60));
  }
  const n = await postTurn(DB, { agent: 'nobody' });
  assert.equal(n.status, 404, JSON.stringify(n.body));
  assert.equal(db.prepare('SELECT COUNT(*) n FROM staff_turns').get().n, 0, 'nothing was written');
});

test('T3 the stored summary is cut to staff.turns.summary_max_chars; fallback 200', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const long = 'word '.repeat(300).trim();  // 1499 chars
  setting(db, 'staff.turns.summary_max_chars', 50);
  assert.equal((await postTurn(DB, { turn_key: 'k-50', cost_run_id: null, summary: long })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-50'").get().summary.length, 50);
  db.prepare("DELETE FROM settings WHERE key='staff.turns.summary_max_chars'").run();
  assert.equal((await postTurn(DB, { turn_key: 'k-200', cost_run_id: null, summary: long })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-200'").get().summary.length, 200);
  // Control characters go and whitespace runs collapse to one space.
  assert.equal((await postTurn(DB, { turn_key: 'k-ws', cost_run_id: null, summary: '  a\u0007b \n\t c  ' })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-ws'").get().summary, 'ab c');
});

test('T3b the request bound is staff.turns.summary_in_max; fallback 2000', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  setting(db, 'staff.turns.summary_in_max', 100);
  const r = await postTurn(DB, { turn_key: 'k-101', cost_run_id: null, summary: 'x'.repeat(101) });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.equal(r.body.error, 'summary');
  // summary_max_chars 200 is over the bound 100: the stored length is min(200, 100).
  assert.equal((await postTurn(DB, { turn_key: 'k-100', cost_run_id: null, summary: 'x'.repeat(100) })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-100'").get().summary.length, 100);
  for (const v of ['0', 'x']) {
    setting(db, 'staff.turns.summary_in_max', v);
    assert.equal((await postTurn(DB, { turn_key: `k-2001-${v}`, cost_run_id: null, summary: 'x'.repeat(2001) })).status, 400, v);
    assert.equal((await postTurn(DB, { turn_key: `k-2000-${v}`, cost_run_id: null, summary: 'x'.repeat(2000) })).status, 201, v);
  }
  db.prepare("DELETE FROM settings WHERE key='staff.turns.summary_in_max'").run();
  assert.equal((await postTurn(DB, { turn_key: 'k-2001', cost_run_id: null, summary: 'x'.repeat(2001) })).status, 400);
  setting(db, 'staff.turns.summary_in_max', 3000);
  assert.equal((await postTurn(DB, { turn_key: 'k-2500', cost_run_id: null, summary: 'x'.repeat(2500) })).status, 201);
});

test('T4 a GitHub-token shape is stored redacted; a near miss is kept', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const tok = 'ghp_fixtureFIXTUREfixture0123456789abcd';
  assert.equal((await postTurn(DB, { turn_key: 'k-tok', cost_run_id: null, summary: `pushed with ${tok} ok` })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-tok'").get().summary, 'pushed with <redacted:github-token> ok');
  assert.equal((await postTurn(DB, { turn_key: 'k-pat', cost_run_id: null, summary: 'github_pat_fixture_0123456789abcdefghij and https://x-access-token:fixture@github.com/o/r' })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-pat'").get().summary,
    '<redacted:github-token> and https://x-access-token:<redacted:github-token>@github.com/o/r');
  assert.equal((await postTurn(DB, { turn_key: 'k-near', cost_run_id: null, summary: 'ghs_fixture_installation_token stays' })).status, 201);
  assert.equal(db.prepare("SELECT summary FROM staff_turns WHERE turn_key='k-near'").get().summary, 'ghs_fixture_installation_token stays');
});

test('T5 archie timeline: the tick and the turn, the turn cost from cost rows, no other agent', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const tick = await postTick(DB);
  assert.equal(tick.status, 201, JSON.stringify(tick.body));
  assert.equal((await postTurn(DB)).status, 201);
  costRow(db, 1, `staff-turn:${KEY}`, 0.10);
  costRow(db, 2, `staff-turn:${KEY}`, 0.05);
  costRow(db, 3, `staff-turn:${KEY}`, null);
  // A watchman turn never shows in archie's timeline.
  assert.equal((await postTurn(DB, { agent: 'watchman', turn_key: 'watchman-turn-1', cost_run_id: null, summary: 'not archie' })).status, 201);
  const r = await activity(DB, 'archie');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const turns = r.body.events.filter((e) => e.kind === 'turn');
  const ticks = r.body.events.filter((e) => e.kind === 'tick');
  assert.equal(ticks.length, 1);
  assert.equal(turns.length, 1, JSON.stringify(r.body.events));
  const e = turns[0];
  assert.equal(e.summary, 'Filed BH-1 and BH-2');
  assert.equal(e.trigger, 'telegram');
  assert.equal(e.outcome, 'answered');
  assert.equal(e.link_url, 'https://github.com/example-org/cromford/pull/12');
  assert.equal(e.duration_s, 100);
  assert.ok(Math.abs(e.cost.cost_usd - 0.15) < 1e-9, JSON.stringify(e.cost));
  assert.equal(e.cost.unpriced, 1);
  assert.equal(e.cost.rows, 3);
  assert.equal(r.body.last_tick.started_at, '2026-11-06T00:00:00Z');
  const w = await activity(DB, 'watchman');
  assert.deepEqual(w.body.events.filter((x) => x.kind === 'turn').map((x) => x.summary), ['not archie']);
  // A turn with no cost row yet is cost null, never $0.
  assert.equal((await postTurn(DB, { turn_key: 'archie-turn-2', cost_run_id: 'staff-turn:archie-turn-2', started_at: '2026-11-06T01:00:00Z', ended_at: '2026-11-06T01:00:00Z' })).status, 201);
  const r2 = await activity(DB, 'archie');
  assert.equal(r2.body.events.find((x) => x.kind === 'turn' && x.ts === '2026-11-06T01:00:00Z').cost, null);
});

test('T6 cursor paging across tick and turn events at the same second is exact', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const ts = (i) => new Date(Date.UTC(2026, 10, 6) + Math.floor(i / 2) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const tk = db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, created_at) VALUES (?, 'archie', ?, ?, 0, 'done', ?)`);
  const tu = db.prepare(`INSERT INTO staff_turns (turn_key, agent, started_at, ended_at, trigger, summary, outcome, created_at) VALUES (?, 'archie', ?, ?, 'beat', 's', 'answered', ?)`);
  for (let i = 0; i < 60; i++) {
    tk.run(`k-${i}`, ts(i), ts(i), ts(i));
    tu.run(`u-${i}`, ts(i), ts(i), ts(i));
  }
  const seen = []; const sizes = [];
  let q = '?limit=50';
  for (let n = 0; n < 5; n++) {
    const r = await activity(DB, 'archie', q);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    sizes.push(r.body.events.length);
    seen.push(...r.body.events.map((e) => `${e.kind}:${e.id}`));
    if (!r.body.next) break;
    q = `?limit=50&before=${encodeURIComponent(r.body.next)}`;
  }
  assert.deepEqual(sizes, [50, 50, 20]);
  assert.equal(new Set(seen).size, 120, 'no duplicate');
  assert.equal(seen.filter((s) => s.startsWith('turn:')).length, 60);
});

function recorder(DB) {
  const seen = new Map();
  const wrapStmt = (sql, st) => new Proxy(st, {
    get(target, k) {
      if (k === 'bind') return (...a) => { seen.set(sql, a); return wrapStmt(sql, target.bind(...a)); };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  const db = new Proxy(DB, {
    get(target, k) {
      if (k === 'prepare') return (sql) => { if (!seen.has(sql)) seen.set(sql, []); return wrapStmt(sql, target.prepare(sql)); };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  return { db, seen };
}
// Any SCAN of one of the three big tables, a walk of a whole index included:
// every read must SEARCH them through an index.
const bigScans = (lines) => lines.filter((l) => /^SCAN (staff_turns|staff_ticks|cost_rows)\b/.test(l));

test('T-EXPLAIN every activity and roster statement reads the big tables through an index', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db: sql, DB } = o;
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-11-06T12:00:00Z') });
  await ensureColumns({ DB }, 'cost_rows');  // the added indexes, as the live worker has them (core.d)
  const agents = ['archie', 'watchman', 'quartermaster', 'clerk'];
  const ts = (i) => new Date(Date.UTC(2026, 9, 1) + i * 150e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  sql.exec('BEGIN');
  const tk = sql.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, cost_run_id, created_at) VALUES (?, ?, ?, ?, 1, 'done', ?, ?)`);
  for (let i = 0; i < 20000; i++) tk.run(`v-${i}`, agents[i % 4], ts(i), ts(i), `staff-tick:v-${i}`, ts(i));
  const tu = sql.prepare(`INSERT INTO staff_turns (turn_key, agent, started_at, ended_at, trigger, summary, outcome, cost_run_id, created_at) VALUES (?, ?, ?, ?, 'beat', 's', 'answered', ?, ?)`);
  for (let i = 0; i < 20000; i++) tu.run(`u-${i}`, i % 5 ? 'archie' : 'watchman', ts(i), ts(i), `staff-turn:u-${i}`, ts(i));
  const cr = sql.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, cost_usd, run_id, lane_id, inserted_at) VALUES ('hub', ?, ?, ?, 0.01, ?, ?, ?)`);
  const lanes = ['orc-monitor', 'staff', 'cost-reconcile', 'build', 'review'];
  for (let i = 0; i < 40000; i++) {
    const run = i % 3 === 0 ? `staff-tick:v-${i >> 1}` : i % 3 === 1 ? `staff-turn:u-${i >> 1}` : `build-${i}`;
    cr.run(`v${i}`, i, ts(i >> 1), run, lanes[i % 5], ts(i >> 1));
  }
  sql.exec('COMMIT');
  const { db, seen } = recorder(DB);
  const first = await activity(db, 'archie', '?limit=50');
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.ok(first.body.events.some((e) => e.kind === 'turn' && e.cost), 'the page joined a turn cost');
  await activity(db, 'archie', `?limit=50&before=${encodeURIComponent(first.body.next)}`);
  await activity(db, 'watchman', '?limit=50');
  const roster = await call(db, '/api/staff/roster');
  assert.equal(roster.status, 200, JSON.stringify(roster.body));
  assert.equal(roster.body.sources.spend, 'cost_rows');
  const stmts = [...seen.entries()].filter(([q]) => /\b(staff_turns|staff_ticks|cost_rows)\b/.test(q));
  assert.ok(stmts.length >= 6, `only ${stmts.length} statements reached`);
  let turnRead = false; let spendReads = 0;
  for (const [q, binds] of stmts) {
    const lines = sql.prepare(`EXPLAIN QUERY PLAN ${q}`).all(...binds).map((x) => x.detail);
    assert.deepEqual(bigScans(lines), [], `${q.replace(/\s+/g, ' ').slice(0, 200)}: ${lines.join(' | ')}`);
    if (/FROM staff_turns\s+WHERE agent=\?1/.test(q)) {
      turnRead = true;
      assert.ok(lines.some((l) => l.includes('idx_staff_turns_agent_started')), `turn read: ${lines.join(' | ')}`);
    }
    if (/spend_lanes|lane_map/.test(q) || /SUM\(CASE WHEN cost_rows\.ts/.test(q)) spendReads += 1;
  }
  assert.ok(turnRead, 'the turn source ran');
  assert.equal(spendReads, 2, 'the two roster spend statements ran');
});

test('T-RET retention staff_turns.age: dry run counts, live run deletes, one audit row per run', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const NOW = Date.now();  // determinism: ok the retention route cuts at its own clock; every seeded time is an offset from it
  const ago = (d) => new Date(NOW - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ins = db.prepare(`INSERT INTO staff_turns (turn_key, agent, started_at, ended_at, trigger, summary, outcome, created_at) VALUES (?, 'archie', ?, ?, 'beat', 's', 'answered', ?)`);
  ins.run('old-100', ago(100), ago(100), ago(100));
  ins.run('old-95', ago(95), ago(95), ago(95));
  ins.run('new-10', ago(10), ago(10), ago(10));
  const audits = () => db.prepare("SELECT COUNT(*) n FROM retention_runs WHERE rule='staff_turns.age'").get().n;
  const before = audits();
  const run = () => call(DB, '/api/retention/run', { method: 'POST', body: {} });
  const dry = await run();
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  assert.equal(dry.body.dry_run, true);
  const dr = dry.body.rules.find((x) => x.rule === 'staff_turns.age');
  assert.ok(dr, 'the rule ran');
  assert.equal(dr.counted, 2);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM staff_turns').get().n, 3, 'the dry run removed nothing');
  assert.equal(audits(), before + 1, 'one audit row for the dry run');
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const live = await run();
  assert.equal(live.body.rules.find((x) => x.rule === 'staff_turns.age').removed, 2);
  assert.deepEqual(db.prepare('SELECT turn_key FROM staff_turns').all().map((x) => x.turn_key), ['new-10']);
  assert.equal(audits(), before + 2, 'one more audit row for the live run');
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'staff_turns.age');
  assert.equal(r.def, 90);
  assert.equal(r.key, 'retention.staff_turns.days');
  const lines = db.prepare(`EXPLAIN QUERY PLAN ${r.ids}`).all(ago(90), 10).map((x) => x.detail);
  assert.ok(lines.some((l) => l.includes('idx_staff_turns_started')), lines.join(' | '));
});
