// BH-9064 (slice C0): the agent_call_ledger table behind
// POST /api/agent-call-ledger/begin, /finish, GET and DELETE. Driven through the
// REAL worker.fetch on node:sqlite with the composed jobs schema
// (worker/jobs/schema.d/).
//   D1-D16 one test per row of the plan's "begin decision" table: each asserts
//          the decision, the status and the attempts, never the whole body
//   D17    EXPLAIN QUERY PLAN on 20,000 rows: begin, finish, GET and DELETE use
//          the primary key, the retention id read uses idx_agent_call_ledger_last,
//          and nothing scans agent_call_ledger
//   D18    finish with an unknown status is 400; a body over the cap is 413
//   D19    unbilled gives the attempt back; a checkpoint-only finish keeps the status
//   D20    DELETE resets the row: the next begin is a fresh run
//   D21    bad begin bodies are 400, no bearer is 401, the routes are in the table
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9064';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (secs) => new Date(NOW - secs * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const BEGIN = { project: 'p1', stage: 'review', max_attempts: 3, window_s: 3600, running_ttl_s: 7200, replay: true, box: 'box-a' };

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, { method = 'GET', body, bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const begin = (DB, fp, extra = {}) => call(DB, '/api/agent-call-ledger/begin', { method: 'POST', body: { ...BEGIN, fp, ...extra } });
const finish = (DB, fp, extra = {}) => call(DB, '/api/agent-call-ledger/finish', { method: 'POST', body: { project: 'p1', stage: 'review', fp, ...extra } });
const rowOf = (db, fp, project = 'p1', stage = 'review') =>
  db.prepare('SELECT * FROM agent_call_ledger WHERE project=? AND stage=? AND fp=?').get(project, stage, fp);
const seed = (db, r) => db.prepare(
  `INSERT INTO agent_call_ledger (project, stage, fp, status, attempts, rc, answer_body, box, first_at, last_at)
   VALUES (?,?,?,?,?,?,?,?,?,?)`
).run(r.project || 'p1', r.stage || 'review', r.fp, r.status, r.attempts, r.rc ?? null, r.answer_body ?? null,
  r.box ?? null, r.at || ago(10), r.at || ago(10));

// expect <begin answer> <decision> <status> <attempts>
function expect(r, decision, status, attempts) {
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.decision, decision, JSON.stringify(r.body));
  assert.equal(r.body.status, status, JSON.stringify(r.body));
  assert.equal(r.body.attempts, attempts, JSON.stringify(r.body));
}

for (const replay of [true, false]) {
  test(`D1 no row (replay ${replay}) -> run, attempts 1, the row is running`, async (t) => {
    const o = await fresh(t); if (!o) return;
    expect(await begin(o.DB, 'fp-d1', { replay }), 'run', 'running', 1);
    const row = rowOf(o.db, 'fp-d1');
    assert.equal(row.status, 'running');
    assert.equal(row.attempts, 1);
    assert.equal(row.box, 'box-a');
  });
}

test('D2 failed attempts=1 -> run, attempts 2', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d2', status: 'failed', attempts: 1, rc: 1 });
  expect(await begin(o.DB, 'fp-d2'), 'run', 'running', 2);
});

test('D3 failed attempts=2 -> run, attempts 3', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d3', status: 'failed', attempts: 2, rc: 1 });
  expect(await begin(o.DB, 'fp-d3'), 'run', 'running', 3);
});

test('D4 failed attempts=3 past the window (3601 s) -> run, attempts restart at 1', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d4', status: 'failed', attempts: 3, rc: 1, at: ago(3601) });
  expect(await begin(o.DB, 'fp-d4'), 'run', 'running', 1);
  assert.equal(rowOf(o.db, 'fp-d4').first_at > ago(60), true, 'first_at restarts with the attempts');
});

test('D5 unbilled attempts=2 -> run, attempts 2 (an unbilled attempt does not count)', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d5', status: 'unbilled', attempts: 1, rc: 75 });
  // seeded at 1: the unbilled settle already gave back the attempt it took.
  expect(await begin(o.DB, 'fp-d5'), 'run', 'running', 2);
  await finish(o.DB, 'fp-d5', { status: 'unbilled', rc: 75 });
  expect(await begin(o.DB, 'fp-d5'), 'run', 'running', 2);
});

test('D6 ok with body "APPROVE", replay true -> replay with the body, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  await begin(o.DB, 'fp-d6');
  const f = await finish(o.DB, 'fp-d6', { status: 'ok', rc: 0, runner: 'claude', model: 'model-fixture', answer_body: 'APPROVE' });
  assert.equal(f.body.settled, true);
  const before = { ...rowOf(o.db, 'fp-d6') };
  assert.equal(before.answer_bytes, 7);
  const r = await begin(o.DB, 'fp-d6');
  expect(r, 'replay', 'ok', 1);
  assert.equal(r.body.answer_body, 'APPROVE');
  assert.equal(r.body.rc, 0);
  assert.equal(r.body.runner, 'claude');
  assert.deepEqual({ ...rowOf(o.db, 'fp-d6') }, before, 'a replay writes nothing');
});

test('D7 ok with body "APPROVE", replay false -> run (a near miss), the attempt counts', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d7', status: 'ok', attempts: 1, rc: 0, answer_body: 'APPROVE' });
  expect(await begin(o.DB, 'fp-d7', { replay: false }), 'run', 'running', 2);
  assert.equal(rowOf(o.db, 'fp-d7').answer_body, null, 'a new attempt clears the old answer');
});

test('D8 ok with body NULL (over the byte cap), replay true -> run (a near miss)', async (t) => {
  const o = await fresh(t); if (!o) return;
  await begin(o.DB, 'fp-d8');
  await finish(o.DB, 'fp-d8', { status: 'ok', rc: 0, answer_bytes: 300000 });
  const row = rowOf(o.db, 'fp-d8');
  assert.equal(row.answer_body, null);
  assert.equal(row.answer_bytes, 300000, 'the size of an answer too big to keep is recorded');
  expect(await begin(o.DB, 'fp-d8'), 'run', 'running', 2);
});

test('D9 ok with a blank body, replay true -> run (a near miss)', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d9', status: 'ok', attempts: 1, rc: 0, answer_body: '   \n' });
  expect(await begin(o.DB, 'fp-d9'), 'run', 'running', 2);
});

test('D10 failed attempts=3 inside the window -> terminal with the stored rc, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (let i = 1; i <= 3; i++) {
    expect(await begin(o.DB, 'fp-d10'), 'run', 'running', i);
    await finish(o.DB, 'fp-d10', { status: 'failed', rc: 124 });
  }
  const r = await begin(o.DB, 'fp-d10');
  expect(r, 'terminal', 'failed', 3);
  assert.equal(r.body.rc, 124);
  assert.equal(r.body.answer_body, undefined, 'a terminal answer carries no body');
  assert.equal(rowOf(o.db, 'fp-d10').attempts, 3, 'a terminal read writes nothing');
  seed(o.db, { fp: 'fp-d10b', status: 'failed', attempts: 3, rc: 1, at: ago(3599) });
  expect(await begin(o.DB, 'fp-d10b'), 'terminal', 'failed', 3);
});

test('D11 empty attempts=1 -> terminal, stored rc 0', async (t) => {
  const o = await fresh(t); if (!o) return;
  await begin(o.DB, 'fp-d11');
  await finish(o.DB, 'fp-d11', { status: 'empty', rc: 0 });
  const r = await begin(o.DB, 'fp-d11');
  expect(r, 'terminal', 'empty', 1);
  assert.equal(r.body.rc, 0);
});

test('D12 running, last_at 10 s ago -> terminal (another box is buying it)', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d12', status: 'running', attempts: 1 });
  const r = await begin(o.DB, 'fp-d12', { box: 'box-b' });
  expect(r, 'terminal', 'running', 1);
  assert.equal(r.body.rc, null);
});

test('D13 running past its TTL at attempts=3 -> terminal; under the cap -> run (counted)', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d13', status: 'running', attempts: 3, at: ago(7201) });
  expect(await begin(o.DB, 'fp-d13', { window_s: 86400 }), 'terminal', 'running', 3);
  seed(o.db, { fp: 'fp-d13b', status: 'running', attempts: 1, at: ago(7201) });
  expect(await begin(o.DB, 'fp-d13b', { window_s: 86400 }), 'run', 'running', 2);
});

test('D14 parked -> terminal', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d14', status: 'parked', attempts: 3, rc: 124 });
  expect(await begin(o.DB, 'fp-d14'), 'terminal', 'parked', 3);
});

test('D15 the same fp on another project is another key -> run', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d15', status: 'failed', attempts: 3, rc: 1, project: 'p2' });
  expect(await begin(o.DB, 'fp-d15'), 'run', 'running', 1);
  assert.equal(rowOf(o.db, 'fp-d15', 'p2').status, 'failed', 'the other project row is untouched');
});

test('D16 the same fp on another stage is another key -> run', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d16', status: 'ok', attempts: 1, rc: 0, answer_body: 'APPROVE', stage: 'lead-review' });
  expect(await begin(o.DB, 'fp-d16'), 'run', 'running', 1);
});

test('D17 on 20,000 rows the key reads use the primary key and retention uses its index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const STAGES = ['review', 'plan', 'execute', 'fix', 'triage-shard', 'lead-review', 'canary', 'orchestrator'];
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO agent_call_ledger (project, stage, fp, status, attempts, rc, first_at, last_at)
                          VALUES (?,?,?,'ok',1,0,?,?)`);
  for (let i = 0; i < 20000; i++) {
    const at = ago((i % 10080) * 60);
    ins.run(`proj-${i % 20}`, STAGES[i % 8], `fp-${i}`, at, at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  // capturingD1 logs reads only; the begin upsert, the finish UPDATE and the
  // DELETE reset are the hot writes, so this wrapper logs run() too.
  const log = [];
  const R = capturingD1(db, log);
  const D = {
    prepare(sql) {
      const s = R.prepare(sql);
      let binds = [];
      const api = {
        bind(...v) { binds = v; s.bind(...v); return api; },
        first: (c) => s.first(c), all: () => s.all(),
        run() { log.push({ sql, binds }); return s.run(); },
      };
      return api;
    },
    batch: (x) => R.batch(x),
  };
  const st = STAGES[777 % 8];
  await begin(D, 'fp-777', { project: 'proj-17', stage: st });
  await finish(D, 'fp-777', { project: 'proj-17', stage: st, status: 'ok', rc: 0, answer_body: 'a' });
  await call(D, `/api/agent-call-ledger?project=proj-17&stage=${st}&fp=fp-777`);
  await call(D, `/api/agent-call-ledger?project=proj-17&stage=${st}&fp=fp-777&actor=op&reason=x`, { method: 'DELETE' });
  const stmts = log.filter((r) => /agent_call_ledger/.test(r.sql) && !/^\s*CREATE/i.test(r.sql));
  assert.equal(stmts.filter((r) => /^\s*INSERT/i.test(r.sql)).length, 1, stmts.map((r) => r.sql).join(' | '));
  assert.equal(stmts.length, 5, stmts.map((r) => r.sql).join(' | '));
  for (const r of stmts) {
    const lines = plan(db, r.sql, ...r.binds);
    assert.deepEqual(fullScans(lines, ['agent_call_ledger']), [], `${r.sql.slice(0, 80)}: ${lines.join(' | ')}`);
    if (/^\s*(SELECT|UPDATE)/i.test(r.sql)) {
      assert.ok(lines.some((l) => /USING (COVERING )?INDEX sqlite_autoindex_agent_call_ledger_1|USING PRIMARY KEY/.test(l)), lines.join(' | '));
    }
  }
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((x) => x.rule === 'agent_call_ledger.age');
  assert.ok(rule, 'the retention rule exists');
  const lines = plan(db, rule.ids, ago(7 * 86400), 500);
  assert.deepEqual(fullScans(lines, ['agent_call_ledger']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_agent_call_ledger_last \(last_at<\?\)/.test(l)), lines.join(' | '));
});

test('D18 finish: an unknown status is 400, a body over the cap is 413, and neither changes the row', async (t) => {
  const o = await fresh(t); if (!o) return;
  await begin(o.DB, 'fp-d18');
  for (const b of [{ status: 'done' }, { status: 'ok', rc: 300 }, {}]) {
    const r = await finish(o.DB, 'fp-d18', b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  const big = await finish(o.DB, 'fp-d18', { status: 'ok', rc: 0, answer_body: 'x'.repeat(1048577) });
  assert.equal(big.status, 413, JSON.stringify(big.body));
  const row = rowOf(o.db, 'fp-d18');
  assert.equal(row.status, 'running');
  assert.equal(row.answer_body, null);
});

test('D19 unbilled gives the attempt back; a checkpoint-only finish keeps the status; GET', async (t) => {
  const o = await fresh(t); if (!o) return;
  await begin(o.DB, 'fp-d19');
  await finish(o.DB, 'fp-d19', { status: 'unbilled', rc: 1 });
  assert.equal(rowOf(o.db, 'fp-d19').attempts, 0);
  const c = await finish(o.DB, 'fp-d19', { checkpoint: 'ticket/bh-1@abc1234' });
  assert.equal(c.body.settled, true);
  assert.equal(rowOf(o.db, 'fp-d19').status, 'unbilled', 'a checkpoint-only finish keeps the status');
  assert.equal(rowOf(o.db, 'fp-d19').checkpoint, 'ticket/bh-1@abc1234');
  const g = await call(o.DB, '/api/agent-call-ledger?project=p1&stage=review&fp=fp-d19');
  assert.equal(g.status, 200);
  assert.equal(g.body.row.status, 'unbilled');
  assert.equal(g.body.row.answer_body, undefined, 'GET without body=1 leaves the body out');
  assert.equal((await call(o.DB, '/api/agent-call-ledger?project=p1&stage=review&fp=nope')).body.row, null);
});

test('D20 DELETE resets the row: the next begin is a fresh run', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { fp: 'fp-d20', status: 'failed', attempts: 3, rc: 1 });
  const d = await call(o.DB, '/api/agent-call-ledger?project=p1&stage=review&fp=fp-d20&actor=op&reason=fixed', { method: 'DELETE' });
  assert.equal(d.body.reset, 1);
  const row = rowOf(o.db, 'fp-d20');
  assert.equal(row.status, 'reset');
  assert.match(row.note, /^reset by op at .*: fixed \(was failed\)$/);
  expect(await begin(o.DB, 'fp-d20'), 'run', 'running', 1);
});

test('D21 bad begin bodies are 400, no bearer is 401, the routes are in the table', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const b of [{ fp: '' }, { fp: 'x', max_attempts: 0 }, { fp: 'x', window_s: 'a' }, { fp: 'x', running_ttl_s: null }]) {
    const r = await call(o.DB, '/api/agent-call-ledger/begin', { method: 'POST', body: { ...BEGIN, ...b } });
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM agent_call_ledger').get().n, 0);
  assert.equal((await call(o.DB, '/api/agent-call-ledger/begin', { method: 'POST', body: { ...BEGIN, fp: 'x' }, bearer: false })).status, 401);
  assert.equal((await call(o.DB, '/api/agent-call-ledger?project=p1&stage=review&fp=x', { bearer: false })).status, 401);
  const frag = readFileSync(new URL('./route-table.d/bh-9064-agent-call-ledger.txt', import.meta.url), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#'));
  assert.deepEqual(frag, ['POST /api/agent-call-ledger/begin', 'POST /api/agent-call-ledger/finish',
    'GET /api/agent-call-ledger', 'DELETE /api/agent-call-ledger']);
});
