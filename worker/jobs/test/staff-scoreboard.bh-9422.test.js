// BH-9422 (C4 of BH-9187): GET /api/staff/levers/scoreboard, every staff
// agent's lever scorecard in one read, driven through the REAL worker.fetch
// against the composed jobs schema (the node:sqlite D1 shim).
//
//   B1  each scoreboard entry deep-equals that agent's GET /scorecard answer
//       minus ok; 3 actions (1 dry run, 2 settled, 1 moved) give precision 0.5
//   B2  the days rule: absent -> row (7, 14, a bad row 7); days=7, 30 accepted;
//       days=0, 31, x, -1 are 400 days
//   B3  an agent with no metric row and no samples: metric null, metric_now
//       null, precision null
//   B4  a staff_agents row named archie is not in agents
//   B5  EXPLAIN QUERY PLAN at 5,000 samples / 2,000 actions over 7 agents: the
//       three per-agent reads use their indexes, no full scan
//   B6  the route is in the table and behind the bearer gate (no token 401)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { ROUTES } from '#routes';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; every seeded time is an offset before it
const isoAgo = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const DAY = 86400;
const get = (DB, path, { token = SECRET } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method: 'GET',
  headers: token ? { authorization: `Bearer ${token}` } : {},
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

// Each case adds its own roster agents with a unique suffix.
const addAgent = (db, name) => db.prepare(
  "INSERT INTO staff_agents (name, role, accountable, soul_path, updated_at) VALUES (?, 'fixture', 'operator', 'prompts/staff/x.md', '2026-11-06T00:00:00Z')"
).run(name);
const setRow = (db, key, value) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 'fixture', 'test', '2026-11-11T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);
const sampleAt = (db, agent, metric, value, ago) => db.prepare(
  'INSERT INTO staff_metric_samples (agent, metric, value, sampled_at) VALUES (?,?,?,?)'
).run(agent, metric, value, isoAgo(ago));
let keyN = 0;
const actionAt = (db, agent, { dry = 0, settled = false, moved = null, ago = DAY }) => db.prepare(
  'INSERT INTO staff_lever_actions (action_key, agent, lever, target, dry_run, metric, metric_before, acted_at, settled_at, metric_after, moved) VALUES (?,?,?,?,?,?,?,?,?,?,?)'
).run(String(++keyN).padStart(64, 'b'), agent, 'l', 't', dry, 'm_b', 5, isoAgo(ago), settled ? isoAgo(ago - 60) : null, settled ? 4 : null, moved);
const entry = (body, agent) => body.agents.find((a) => a.agent === agent);

test('BH-9422 staff scoreboard', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('B1 each entry equals the agent scorecard; precision 0.5', async () => {
    const { DB, db } = await openDb();
    for (const a of ['sb-b1a', 'sb-b1b']) {
      addAgent(db, a);
      setRow(db, `staff.${a}.metric`, 'm_b');
      setRow(db, `staff.${a}.target`, '2');
      sampleAt(db, a, 'm_b', 41, 8 * DAY);
      sampleAt(db, a, 'm_b', 3, 60);
    }
    setRow(db, 'staff.sb-b1a.level', 'act');
    actionAt(db, 'sb-b1a', { dry: 1 });
    actionAt(db, 'sb-b1a', { settled: true, moved: 1 });
    actionAt(db, 'sb-b1a', { settled: true, moved: 0 });
    const sb = await get(DB, '/api/staff/levers/scoreboard');
    assert.equal(sb.status, 200, JSON.stringify(sb.body));
    assert.equal(sb.body.ok, true);
    assert.equal(sb.body.days, 7);
    assert.match(sb.body.as_of, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    for (const a of ['sb-b1a', 'sb-b1b']) {
      const sc = await get(DB, `/api/staff/levers/scorecard?agent=${a}`);
      assert.equal(sc.status, 200);
      const { ok, ...want } = sc.body;
      assert.equal(ok, true);
      assert.deepEqual(entry(sb.body, a), want, a);
    }
    const a = entry(sb.body, 'sb-b1a');
    assert.deepEqual([a.actions, a.dry_runs, a.settled, a.moved, a.precision], [2, 1, 2, 1, 0.5]);
    assert.equal(a.metric_now.value, 3);
    assert.equal(a.metric_then.value, 41);
    assert.equal(a.level, 'act');
    assert.equal(a.target, 2);
    // The seeded roster is on the board too, ordered by name.
    const names = sb.body.agents.map((x) => x.agent);
    assert.deepEqual(names, [...names].sort());
    assert.ok(names.includes('clerk') && names.includes('inspector'), names.join(','));
    assert.equal(entry(sb.body, 'clerk').metric, 'needs_count');
  });

  await t.test('B2 the days rule', async () => {
    const { DB, db } = await openDb();
    const days = async (q) => { const r = await get(DB, `/api/staff/levers/scoreboard${q}`); return r.status === 200 ? r.body.days : `${r.status} ${r.body && r.body.error}`; };
    assert.equal(await days(''), 7);
    assert.equal(await days('?days=7'), 7);
    assert.equal(await days('?days=30'), 30);
    for (const q of ['?days=0', '?days=31', '?days=x', '?days=-1']) assert.equal(await days(q), '400 days', q);
    setRow(db, 'staff.scorecard_days', '14');
    assert.equal(await days(''), 14);
    setRow(db, 'staff.scorecard_days', 'abc');
    assert.equal(await days(''), 7);
    // Every entry carries the window the answer used.
    const r = await get(DB, '/api/staff/levers/scoreboard?days=30');
    assert.ok(r.body.agents.length > 0);
    assert.ok(r.body.agents.every((x) => x.days === 30));
  });

  await t.test('B3 no metric row and no samples: nulls, never zeros', async () => {
    const { DB, db } = await openDb();
    addAgent(db, 'sb-b3');
    const r = await get(DB, '/api/staff/levers/scoreboard');
    const a = entry(r.body, 'sb-b3');
    assert.ok(a, 'agent with no metric row is on the board');
    assert.equal(a.metric, null);
    assert.equal(a.metric_now, null);
    assert.equal(a.metric_then, null);
    assert.equal(a.target, null);
    assert.equal(a.level, 'observe');
    assert.equal(a.precision, null);
    assert.equal(a.actions, 0);
  });

  await t.test('B4 archie is not a staff row on the board', async () => {
    const { DB, db } = await openDb();
    if (!db.prepare("SELECT 1 FROM staff_agents WHERE name='archie'").get()) addAgent(db, 'archie');
    const r = await get(DB, '/api/staff/levers/scoreboard');
    assert.equal(r.status, 200);
    assert.equal(entry(r.body, 'archie'), undefined);
    assert.ok(r.body.agents.length >= 7);
  });

  await t.test('B5 the per-agent reads use their indexes at seeded volume', async () => {
    const { db } = await openDb();
    db.exec('BEGIN');
    for (let i = 0; i < 5000; i++) sampleAt(db, `a${i % 7}`, `m${i % 3}`, i, i * 120);
    for (let i = 0; i < 2000; i++) actionAt(db, `a${i % 7}`, { dry: i % 5 === 0 ? 1 : 0, settled: i % 2 === 0, moved: i % 4 === 0 ? 1 : 0, ago: i * 300 });
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const { SQL } = await import('../src/routes/staff-levers.js');
    const { ROSTER_SQL } = await import('../src/routes/staff-scoreboard.js');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN staff_(metric_samples|lever_actions)\b/.test(l) && !/USING/.test(l)), [], lines.join(' | '));
    for (const [q, idx, b] of [
      [SQL.now, 'idx_staff_metric_samples_agent', ['a1', 'm1']],
      [SQL.then, 'idx_staff_metric_samples_agent', ['a1', 'm1', isoAgo(7 * DAY)]],
      [SQL.counts, 'idx_staff_lever_actions_agent', ['a1', isoAgo(7 * DAY)]],
    ]) {
      const l = plan(q, ...b);
      assert.ok(l.some((x) => x.includes(idx)), `${idx} not used: ${l.join(' | ')}`);
      noScan(l);
    }
    // The roster read is the small staff_agents table (one row per agent).
    assert.match(ROSTER_SQL, /FROM staff_agents/);
  });

  await t.test('B6 the route is in the table and behind the bearer gate', async () => {
    const { DB } = await openDb();
    assert.ok(ROUTES.some(([m, p]) => m === 'GET' && JSON.stringify(p).includes('/api/staff/levers/scoreboard')), 'route registered');
    const r = await get(DB, '/api/staff/levers/scoreboard', { token: null });
    assert.equal(r.status, 401);
    const w = await get(DB, '/api/staff/levers/scoreboard', { token: 'wrong' });
    assert.equal(w.status, 401);
  });
});
