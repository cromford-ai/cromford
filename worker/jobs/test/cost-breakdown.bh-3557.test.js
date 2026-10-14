import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3557: GET /api/metrics/cost-breakdown, a grouped read over cost_rows so
// the fleet's spend is labelled by project, stage, runner, model, billing mode
// and ticket instead of landing on 91 lanes' $ TODAY cells. Driven through the
// real worker.fetch over a real schema.sql in node:sqlite, clock pinned.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return { prepare: (sql) => make(sql, []), batch: async (s) => s.map((x) => exec(x._sql, x._binds)) };
}

const NOW_MS = Date.parse('2099-09-25T12:00:00Z');
const at = (hhmm) => `2099-09-25T${hhmm}:00.000Z`;

// ts, project, stage, runner, model, billing_mode, ticket, run_id, job_id, cost_usd
const ROWS = [
  [at('10:00'), 'project-4', 'triage', 'codex', 'model-x', 'metered', 'BH-1', 'run-a1', 'job-a1', 3.0],
  [at('11:00'), 'project-4', 'triage', 'codex', 'model-x', 'subscription', 'BH-1', 'run-a2', 'job-a2', 2.0],
  [at('09:00'), 'project-4', 'execute', 'claude', 'opus', 'subscription', 'BH-2', 'run-b1', null, 10.0],
  [at('08:00'), 'cromford', 'review', 'claude', 'opus', 'metered', null, null, null, 4.5],
  [at('07:00'), 'cromford', 'plan', 'claude', 'sonnet', null, 'BH-2', 'run-b0', 'job-b0', 1.25],
  [at('06:00'), null, 'triage', 'codex', 'model-x', 'metered', null, null, null, 0.75],
  [at('05:00'), 'project-5', 'review', 'claude', 'opus', 'subscription', null, null, null, null],
  ['2099-09-24T20:00:00.000Z', 'project-4', 'plan', 'claude', 'opus', 'metered', 'BH-3', 'run-y', null, 100.0],
];
const TODAY_USD = 3 + 2 + 10 + 4.5 + 1.25 + 0.75;
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg}: ${a} != ${b}`);
const sumUsd = (groups) => groups.reduce((a, g) => a + (g.usd ?? 0), 0);

function freshD1(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const ins = db.prepare(
    `INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, model, billing_mode,
       ticket, run_id, job_id, cost_usd, inserted_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  ROWS.forEach((r, i) => ins.run('hub', `h${i}`, i + 1, ...r, at('12:00')));
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function get(env, qs, auth = true) {
  const res = await worker.fetch(new Request('https://jobs.test/api/metrics/cost-breakdown' + qs,
    { headers: auth ? { authorization: 'Bearer ' + SECRET } : {} }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function ok(env, qs) {
  const r = await get(env, qs);
  assert.equal(r.status, 200, `${qs}: ${JSON.stringify(r.body)}`);
  return r.body;
}

test('B1: group=project over the default window sums to the total, yesterday excluded', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '');
  assert.deepEqual(b.group, ['project']);
  assert.equal(b.since, '2099-09-25T00:00:00Z');
  close(b.total.usd, TODAY_USD, 'total');
  close(sumUsd(b.groups), b.total.usd, 'groups vs total');
  assert.equal(b.total.calls, 7);
  assert.equal(b.total.unpriced_calls, 1);
  const cx = b.groups.find((g) => g.project === 'project-4');
  close(cx.usd, 15, 'project-4 today (the 100 from yesterday is not in it)');
  assert.equal(b.groups[0].project, 'project-4', 'groups are ordered by spend, desc');
  assert.equal(b.truncated, false);
  db.close();
});

test('B2: every grouping sums to the same fleet total', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  for (const g of ['project,stage', 'runner,model', 'billing_mode', 'ticket', 'stage', 'model']) {
    const b = await ok(env, '?group=' + g);
    assert.deepEqual(b.group, g.split(','));
    close(b.total.usd, TODAY_USD, `${g} total`);
    close(sumUsd(b.groups), TODAY_USD, `${g} groups`);
  }
  const rm = await ok(env, '?group=runner,model');
  const codex = rm.groups.find((x) => x.runner === 'codex' && x.model === 'model-x');
  close(codex.usd, 5.75, 'codex/model-x');
  db.close();
});

test('B3: since widens the window, until bounds it', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const wk = await ok(env, '?since=2099-09-18T12:00:00Z');
  close(wk.total.usd, TODAY_USD + 100, '7d total includes yesterday');
  close(sumUsd(wk.groups), TODAY_USD + 100, '7d groups');
  const early = await ok(env, '?until=2099-09-25T10:30:00Z');
  close(early.total.usd, TODAY_USD - 2, 'the 11:00 row is past until');
  assert.equal(early.until, '2099-09-25T10:30:00Z');
  db.close();
});

test('B4: cash is metered only, API-equivalent is subscription only, unknown is in neither', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '?group=billing_mode');
  close(b.total.cash_usd, 3 + 4.5 + 0.75, 'cash');
  close(b.total.equiv_usd, 2 + 10, 'equiv');
  const unk = b.groups.find((g) => g.billing_mode === null);
  close(unk.usd, 1.25, 'NULL billing counts in usd');
  close(unk.cash_usd, 0, 'NULL billing is not cash');
  close(unk.equiv_usd, 0, 'NULL billing is not API-equivalent');
  db.close();
});

test('B5: a NULL project is one group, and project= drills into exactly it', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '?group=project');
  const nulls = b.groups.filter((g) => g.project === null);
  assert.equal(nulls.length, 1);
  const st = await ok(env, '?group=stage&project=');
  assert.deepEqual(st.filters, { project: '' });
  assert.deepEqual(st.groups.map((g) => g.stage), ['triage']);
  close(st.total.usd, 0.75, 'the null project\'s total');
  const rows = await ok(env, '?group=rows&project=');
  assert.equal(rows.rows.length, 1);
  assert.equal(rows.rows[0].project, null);
  assert.equal(rows.rows[0].cost_usd, 0.75);
  // and a named filter still binds a value
  const cx = await ok(env, '?group=stage&project=project-4');
  close(cx.total.usd, 15, 'project-4 filter');
  db.close();
});

test('B6: group=ticket carries the newest row\'s run and job ids', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '?group=ticket');
  const t1 = b.groups.find((g) => g.ticket === 'BH-1');
  assert.equal(t1.last_run_id, 'run-a2');
  assert.equal(t1.last_job_id, 'job-a2');
  assert.equal(t1.last_project, 'project-4');
  assert.equal(t1.last_ts, at('11:00'));
  const t2 = b.groups.find((g) => g.ticket === 'BH-2');
  assert.equal(t2.last_run_id, 'run-b1');
  assert.equal(t2.last_job_id, null);
  assert.ok(b.groups.some((g) => g.ticket === null), 'the untagged rows are one (no ticket) group');
  // no ticket fields on other groupings
  assert.equal('last_run_id' in (await ok(env, '?group=project')).groups[0], false);
  db.close();
});

test('B7: group=rows is newest-first, capped by limit, and says so', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '?group=rows&project=project-4&stage=triage&limit=2');
  assert.deepEqual(b.rows.map((r) => r.ts), [at('11:00'), at('10:00')]);
  assert.equal(b.truncated, true);
  assert.equal(b.rows[0].run_id, 'run-a2');
  const all = await ok(env, '?group=rows&project=project-4&stage=triage');
  assert.equal(all.rows.length, 2);
  assert.equal(all.truncated, false);
  db.close();
});

test('B8: an all-unpriced group has usd null, not 0', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const b = await ok(env, '?group=project');
  const ts = b.groups.find((g) => g.project === 'project-5');
  assert.equal(ts.usd, null);
  assert.equal(ts.unpriced_calls, 1);
  assert.equal(ts.calls, 1);
  db.close();
});

test('B9: bad input is a 400 and never reaches SQL', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  for (const qs of ['?group=bogus', '?group=project,project', '?group=project,stage,runner',
    '?since=yesterday', '?until=2099-09-25', '?group=project;DROP%20TABLE%20cost_rows', '?group=rows&limit=0',
    '?group=rows&limit=501', '?group=rows&limit=abc']) {
    const r = await get(env, qs);
    assert.equal(r.status, 400, `${qs} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.ok(r.body && r.body.error, qs);
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM cost_rows').get().n, ROWS.length, 'the table survived');
  db.close();
});

test('B10: the route sits behind the bearer', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  const r = await get(env, '?group=project', false);
  assert.equal(r.status, 401);
  db.close();
});
