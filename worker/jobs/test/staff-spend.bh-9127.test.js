// BH-9127: spend per agent on GET /api/staff/roster, driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema. The clock is
// pinned to 2026-11-06T12:00:00Z (D60), so "today" is 2026-11-06 UTC.
//
//   S1  archie: the lanes of settings staff.spend.lane_map, summed; an unpriced
//       row is counted, never read as $0
//   S2  a staff agent: its staff_lanes rows plus its own tick calls on the
//       shared lane staff (by staff_ticks.cost_run_id); another agent's tick
//       calls never reach it
//   S3  a row on the agent's lane AND of its tick counts once
//   S4  the today and 7-day windows, at their edges
//   S5  an agent with no cost rows is 0 (a number), sources.spend cost_rows
//   S6  an invalid lane map: every spend null, sources.spend invalid
//   S7  the lane map row deleted: archie null, the staff agents still read
//   S8  the cost read fails: every spend null, sources.spend unread, the
//       roster still answers with last_tick_at
//   S9  archie's last_tick_at; the roster statement count stays <= 14
//   S10 staff.spend.window_days out of range or absent is 7, flagged default
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'secret-fixture';
const NOW_MS = Date.parse('2026-11-06T12:00:00Z');
const call = (DB, path, { method = 'GET', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const roster = async (DB) => {
  const r = await call(DB, '/api/staff/roster');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { by: Object.fromEntries(r.body.agents.map((a) => [a.name, a])), sources: r.body.sources, agents: r.body.agents };
};
const close = (a, b, msg) => assert.ok(typeof a === 'number' && Math.abs(a - b) < 1e-9, `${msg}: ${a} != ${b}`);

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
let n = 0;
function cost(db, { lane = null, run = null, usd, ts = '2026-11-06T08:00:00Z' }) {
  n += 1;
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, cost_usd, run_id, lane_id, inserted_at) VALUES ('hub', ?, ?, ?, ?, ?, ?, ?)`)
    .run(`s9127-${n}`, n, ts, usd, run, lane, ts);
}
function tick(db, agent, key, started = '2026-11-06T07:59:00Z') {
  db.prepare(`INSERT INTO staff_ticks (tick_key, agent, started_at, ended_at, duration_s, phase, cost_run_id, created_at) VALUES (?, ?, ?, ?, 1, 'done', ?, ?)`)
    .run(key, agent, started, started, `staff-tick:${key}`, started);
}
const setting = (db, key, value) => db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test','2026-11-06T00:00:00Z')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value));

test('S1 archie spend is the sum of its mapped lanes; an unpriced row is counted', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  cost(db, { lane: 'orc-monitor', usd: 1.00 });
  cost(db, { lane: 'archie', usd: 0.50 });
  cost(db, { lane: 'archie-research', usd: null });
  cost(db, { lane: 'build', usd: 9.00 });  // not an archie lane
  const { by, sources } = await roster(DB);
  close(by.archie.spend_usd, 1.50, 'archie today');
  close(by.archie.spend_usd_7d, 1.50, 'archie 7d');
  assert.equal(by.archie.spend_unpriced, 1);
  assert.equal(by.archie.spend_unpriced_7d, 1);
  assert.deepEqual(by.archie.spend_lanes, ['archie', 'archie-cards', 'archie-learn', 'archie-research', 'orc-monitor']);
  assert.equal(by.archie.spend_window_days, 7);
  assert.equal(sources.spend, 'cost_rows');
});

test('S2 a staff agent: its lanes plus its own tick calls; never another agent\'s', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  cost(db, { lane: 'cost-reconcile', usd: 0.20 });
  tick(db, 'quartermaster', 'q-1');
  cost(db, { lane: 'staff', run: 'staff-tick:q-1', usd: 0.30 });
  tick(db, 'watchman', 'w-1');
  cost(db, { lane: 'staff', run: 'staff-tick:w-1', usd: 0.70 });
  // A pre-BH-2303 row (no lane) of a quartermaster tick still counts for it.
  cost(db, { lane: null, run: 'staff-tick:q-1', usd: 0.01 });
  const { by } = await roster(DB);
  close(by.quartermaster.spend_usd, 0.51, 'quartermaster');
  close(by.watchman.spend_usd, 0.70, 'watchman');
  assert.ok(by.quartermaster.spend_lanes.includes('cost-reconcile'), by.quartermaster.spend_lanes.join(','));
  assert.ok(!by.quartermaster.spend_lanes.includes('staff'), 'the shared lane is not listed as its lane');
  assert.equal(by.archie.spend_usd, 0, 'archie has no row today');
});

test('S3 a row on the agent\'s lane and of its tick counts once', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  tick(db, 'quartermaster', 'q-1');
  cost(db, { lane: 'cost-reconcile', run: 'staff-tick:q-1', usd: 0.25 });
  // The same shape with another agent's lane: counted for the lane owner only.
  tick(db, 'watchman', 'w-1');
  cost(db, { lane: 'cost-reconcile', run: 'staff-tick:w-1', usd: 0.40 });
  const { by } = await roster(DB);
  close(by.quartermaster.spend_usd, 0.65, 'quartermaster');
  close(by.watchman.spend_usd, 0, 'watchman');
});

test('S4 windows: today starts at 00:00:00Z; 7d holds yesterday; 8 days ago is out', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  cost(db, { lane: 'orc-monitor', usd: 0.01, ts: '2026-11-06T00:00:00Z' });
  cost(db, { lane: 'orc-monitor', usd: 0.10, ts: '2026-11-05T23:59:59Z' });
  cost(db, { lane: 'orc-monitor', usd: 1.00, ts: '2026-10-29T11:00:00Z' });
  cost(db, { lane: 'orc-monitor', usd: null, ts: '2026-11-05T10:00:00Z' });
  const { by } = await roster(DB);
  close(by.archie.spend_usd, 0.01, 'today');
  close(by.archie.spend_usd_7d, 0.11, '7d');
  assert.equal(by.archie.spend_unpriced, 0);
  assert.equal(by.archie.spend_unpriced_7d, 1);
});

test('S5 no cost rows is 0, a number, with sources.spend cost_rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { DB } = o;
  const { agents, sources } = await roster(DB);
  assert.equal(sources.spend, 'cost_rows');
  for (const a of agents) {
    assert.equal(a.spend_usd, 0, a.name);
    assert.equal(a.spend_usd_7d, 0, a.name);
    assert.equal(a.spend_unpriced, 0, a.name);
  }
});

test('S6 an invalid lane map: every spend null, sources.spend invalid', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  cost(db, { lane: 'cost-reconcile', usd: 0.20 });
  for (const bad of ['not json', '{"archie":"orc-monitor"}', '["orc-monitor"]', '{"archie":[1]}', '{"Bad Agent":["x"]}']) {
    setting(db, 'staff.spend.lane_map', bad);
    const { agents, sources } = await roster(DB);
    assert.match(sources.spend, /^invalid: settings staff\.spend\.lane_map/, bad);
    for (const a of agents) assert.equal(a.spend_usd, null, `${bad}: ${a.name}`);
  }
});

test('S7 the lane map row deleted: archie null, the staff agents still read', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  db.prepare("DELETE FROM settings WHERE key='staff.spend.lane_map'").run();
  cost(db, { lane: 'orc-monitor', usd: 1.00 });
  cost(db, { lane: 'cost-reconcile', usd: 0.20 });
  tick(db, 'quartermaster', 'q-1');
  cost(db, { lane: 'staff', run: 'staff-tick:q-1', usd: 0.30 });
  const { by, sources } = await roster(DB);
  assert.equal(by.archie.spend_usd, null);
  assert.equal(by.archie.spend_usd_7d, null);
  assert.equal(sources.spend_archie, 'no lane map row');
  assert.equal(sources.spend, 'cost_rows');
  close(by.quartermaster.spend_usd, 0.50, 'quartermaster');
});

test('S8 the cost read fails: every spend null, unread, the roster still answers', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  tick(db, 'watchman', 'w-1');
  const failing = new Proxy(DB, {
    get(target, k) {
      if (k === 'prepare') return (sql) => {
        if (/\bcost_rows\b/.test(sql)) throw new Error('D1_ERROR: fixture failure');
        return target.prepare(sql);
      };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  const { agents, sources, by } = await roster(failing);
  assert.equal(sources.spend, 'unread');
  for (const a of agents) assert.equal(a.spend_usd, null, a.name);
  assert.equal(by.watchman.last_tick_at, '2026-11-06T07:59:00Z');
});

test('S9 archie last_tick_at; the roster runs at most 14 statements', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { DB } = o;
  const COUNTS = { collected: 0, new_items: 0, deferred: 0, model_calls: 1, digested: 0, filed: 0, refused: 0, unsupported: 0, failed: 0, held: 0 };
  const p = await call(DB, '/api/staff/ticks', { method: 'POST', body: {
    tick_key: 'archie-turn-1793966400-77', agent: 'archie', started_at: '2026-11-06T11:59:00Z', ended_at: '2026-11-06T11:59:30Z',
    phase: 'done', collector_rc: null, collector_s: null, model_rc: null, ...COUNTS, cost_run_id: null,
  } });
  assert.equal(p.status, 201, JSON.stringify(p.body));
  let stmts = 0;
  const counting = new Proxy(DB, {
    get(target, k) {
      if (k === 'prepare') return (sql) => { stmts += 1; return target.prepare(sql); };
      const v = target[k];
      return typeof v === 'function' ? v.bind(target) : v;
    },
  });
  const { by } = await roster(counting);
  assert.equal(by.archie.last_tick_at, '2026-11-06T11:59:00Z');
  assert.ok(stmts <= 14, `the roster ran ${stmts} statements`);
});

test('S10 window_days out of range or absent is 7, flagged default; 30 is 30', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  cost(db, { lane: 'orc-monitor', usd: 1.00, ts: '2026-10-20T00:00:00Z' });  // 17 days ago
  for (const v of ['0', '61', 'x']) {
    setting(db, 'staff.spend.window_days', v);
    const { by, sources } = await roster(DB);
    assert.equal(by.archie.spend_window_days, 7, v);
    assert.equal(sources.spend_window, 'default', v);
    close(by.archie.spend_usd_7d, 0, v);
  }
  db.prepare("DELETE FROM settings WHERE key='staff.spend.window_days'").run();
  assert.equal((await roster(DB)).sources.spend_window, 'default');
  setting(db, 'staff.spend.window_days', '30');
  const { by, sources } = await roster(DB);
  assert.equal(by.archie.spend_window_days, 30);
  assert.equal(sources.spend_window, undefined);
  close(by.archie.spend_usd_7d, 1.00, '30d');
});
