import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// K2 — THE PROGRESS STAMPS the outside dead-man judges. One read-only route
// that answers, per project, WHEN each lane last produced something (a triage
// row, a build result, a review verdict, a merge, a priced cost row), what it
// spent in the short and long windows, how much work is waiting, and when each
// named detector lane last ticked. bin/progress-push.sh relays it to the
// watchdog worker; nothing here pages and nothing here writes.
//
// Driven through the worker's real fetch handler against THE SQL THAT SHIPS
// (schema.sql into node:sqlite). The route stamps windows off the server clock,
// so every "inside the window" row here is stamped in the far future (2999) and
// every "outside" row in the far past (2000) — the tests never read a clock
// (docs/TEST-DETERMINISM.md).

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const IN = '2999-01-01T00:00:00Z';
const IN2 = '2999-01-01T00:05:00Z';
const OUT = '2000-01-01T00:00:00Z';

function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds.map((v) => (v === undefined ? null : v))) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds.map((v) => (v === undefined ? null : v))) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds.map((v) => (v === undefined ? null : v)));
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

async function openDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
}

const get = (db, qs = '', { secret = SECRET } = {}) => worker.fetch(
  new Request(`https://jobs.test/api/progress/stamps${qs}`, { headers: { authorization: `Bearer ${secret}` } }),
  { DB: sqliteDB(db), HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const job = (db, id, project, kind, status, at) => db.prepare(
  `INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)`,
).run(id, project, kind, 'box-hub', 'done', status, at, at);
const cost = (db, hash, project, stage, usd, ts) => db.prepare(
  `INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES (?,?,?,?,?,?,?,?)`,
).run('box-hub', hash, 1, ts, project, stage, usd, ts);

test('unauthed is refused', async (t) => {
  const db = await openDb(t); if (!db) return;
  assert.equal((await get(db, '', { secret: 'nope' })).status, 401);
});

test('an empty database answers every section empty, with no errors', async (t) => {
  const db = await openDb(t); if (!db) return;
  const r = await get(db, '?detectors=fleet-slo');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.projects, {});
  assert.deepEqual(r.body.detectors, []);
  assert.deepEqual(r.body.errors, []);
  assert.ok(r.body.as_of);
});

test('job stamps: triage = last DONE triage; build_ok = last DONE build/fix; build_result = any finished build; running rows never count', async (t) => {
  const db = await openDb(t); if (!db) return;
  job(db, 'tri-1', 'alpha', 'triage', 'done', IN);
  job(db, 'tri-2', 'alpha', 'triage', 'running', IN2);
  job(db, 'b-1', 'alpha', 'build', 'done', IN);
  job(db, 'b-2', 'alpha', 'fix', 'failed', IN2);
  job(db, 'b-3', 'alpha', 'build', 'running', '2999-06-01T00:00:00Z');
  job(db, 'q-1', 'alpha', 'qa', 'done', IN2);
  job(db, 'b-old', 'beta', 'build', 'done', OUT);
  const r = await get(db);
  const s = r.body.projects.alpha.stamps;
  assert.equal(s.triage, IN, 'a running triage is not a row written');
  assert.equal(s.build_ok, IN);
  assert.equal(s.build_result, IN2, 'a failed fix is a result');
  assert.equal(s.qa, IN2);
  assert.equal(r.body.projects.beta, undefined, 'a row outside the lookback is not read at all');
});

test('review stamp comes from verdict_history joined to its job; merge from the merge ledger, merge_queue and merge_trains', async (t) => {
  const db = await openDb(t); if (!db) return;
  job(db, 'b-1', 'alpha', 'build', 'done', OUT);
  db.prepare(`INSERT INTO verdict_history (job_id, verdict, created_at) VALUES (?,?,?)`).run('b-1', 'APPROVE', IN);
  // The ledger row carries a job for alpha; the one for gamma has no job and is
  // attributed through the repo slug merge_queue records beside its project.
  db.prepare(`INSERT INTO ledgers (kind, key, status, job_id, created_at, updated_at) VALUES ('merge', ?, 'merged', ?, ?, ?)`)
    .run('https://github.com/Org/alpha/pull/7', 'b-1', IN, IN);
  db.prepare(`INSERT INTO ledgers (kind, key, status, job_id, created_at, updated_at) VALUES ('merge', ?, 'merged', NULL, ?, ?)`)
    .run('https://github.com/Org/gamma/pull/9', IN, IN);
  db.prepare(`INSERT INTO merge_queue (project, pr, status, repo, enqueued_at, updated_at) VALUES ('gamma', 1, 'dropped', 'Org/gamma', ?, ?)`).run(OUT, OUT);
  db.prepare(`INSERT INTO merge_queue (project, pr, status, repo, enqueued_at, updated_at) VALUES ('delta', 2, 'landed', 'Org/delta', ?, ?)`).run(IN, IN2);
  db.prepare(`INSERT INTO merge_trains (project, branch, outcome, created_at, updated_at) VALUES ('epsilon', 'batch/x', 'landed', ?, ?)`).run(IN, IN);
  const r = await get(db);
  assert.equal(r.body.projects.alpha.stamps.review, IN);
  assert.equal(r.body.projects.alpha.stamps.merge, IN);
  assert.equal(r.body.projects.gamma.stamps.merge, IN, 'attributed through merge_queue repo map');
  assert.equal(r.body.projects.delta.stamps.merge, IN2);
  assert.equal(r.body.projects.epsilon.stamps.merge, IN);
});

test('spend: priced rows only, per stage over the short window and per project over EACH long window, in one scan', async (t) => {
  const db = await openDb(t); if (!db) return;
  cost(db, 'h1', 'alpha', 'execute', 4.5, IN);
  cost(db, 'h2', 'alpha', 'execute', 3, IN2);
  cost(db, 'h3', 'alpha', 'triage', 0, IN2);
  cost(db, 'h4', 'alpha', 'plan', 2, OUT);
  const r = await get(db, '?spend_min=60&long_min=1440,10080');
  const p = r.body.projects.alpha;
  assert.deepEqual(p.spend, { execute: 7.5 }, 'an unpriced (0) row is not spend; an old row is outside the window');
  assert.deepEqual(p.spend_long, { 1440: 7.5, 10080: 7.5 });
  assert.equal(p.stamps.cost, IN2, 'the last PRICED row');
  assert.equal(r.body.spend_min, 60);
  assert.deepEqual(r.body.long_min, [1440, 10080]);
});

test('the cost section reads cost_rows ONCE (the three windows are one scan)', async (t) => {
  const db = await openDb(t); if (!db) return;
  const seen = [];
  const inner = sqliteDB(db);
  const spy = { prepare: (sql) => { if (/FROM cost_rows/.test(sql)) seen.push(sql); return inner.prepare(sql); } };
  const res = await worker.fetch(
    new Request('https://jobs.test/api/progress/stamps?long_min=1440,10080', { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB: spy, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  assert.equal(seen.length, 1, seen.join('\n---\n'));
});

test('pending: queued build rows and queued merge rows, per project', async (t) => {
  const db = await openDb(t); if (!db) return;
  const bq = db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at) VALUES (?,?,?,?,?)`);
  bq.run('alpha', 'TK-1', 'queued', IN, IN);
  bq.run('alpha', 'TK-2', 'queued', IN, IN);
  bq.run('alpha', 'TK-3', 'claimed', IN, IN);
  const mq = db.prepare(`INSERT INTO merge_queue (project, pr, status, repo, enqueued_at, updated_at) VALUES (?,?,?,?,?,?)`);
  mq.run('alpha', 11, 'queued', 'Org/alpha', IN, IN);
  mq.run('alpha', 12, 'blocked', 'Org/alpha', IN, IN);
  const r = await get(db);
  assert.deepEqual(r.body.projects.alpha.queued, { build: 2, merge: 1 });
});

test('detectors: lane_ticks rows for exactly the named lanes; a bad name is refused, not interpolated', async (t) => {
  const db = await openDb(t); if (!db) return;
  const lt = db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, why, updated_at) VALUES (?,?,?,?,?,?,?)`);
  lt.run('fleet-slo', '-', 'box-hub', IN, 'ran', null, IN);
  lt.run('alert-warn-flush', '-', 'box-small', IN2, 'paused', 'flag', IN2);
  lt.run('merge-conductor', '-', 'box-hub', IN, 'ran', null, IN);
  const r = await get(db, '?detectors=fleet-slo,alert-warn-flush');
  const rows = r.body.detectors.map((d) => `${d.lane}@${d.box}:${d.outcome}:${d.at}`).sort();
  assert.deepEqual(rows, [`alert-warn-flush@box-small:paused:${IN2}`, `fleet-slo@box-hub:ran:${IN}`]);
  assert.equal((await get(db, "?detectors=fleet-slo,x'%20OR%201=1")).status, 400);
});

test('a section whose table is unreadable is NAMED in errors and the other sections still answer', async (t) => {
  const db = await openDb(t); if (!db) return;
  job(db, 'tri-1', 'alpha', 'triage', 'done', IN);
  db.exec('DROP TABLE cost_rows');
  const r = await get(db);
  assert.equal(r.status, 200);
  assert.ok(r.body.errors.includes('cost'), JSON.stringify(r.body.errors));
  assert.equal(r.body.projects.alpha.stamps.triage, IN);
  assert.equal(r.body.projects.alpha.spend, null, 'unknown spend is null, never {}');
  assert.equal(r.body.projects.alpha.spend_long, null);
});

test('nit 4: the stamp lookback widens to the longest no-merge window, so a merge stamp is never older than the window that judges it', async (t) => {
  const db = await openDb(t); if (!db) return;
  const r = await get(db, '?long_min=1440,20160&lookback_h=168');
  assert.equal(r.status, 200);
  assert.equal(r.body.lookback_h, 336, '20160 min = 336 h');
  assert.equal((await get(db, '?long_min=1440&lookback_h=168')).body.lookback_h, 168);
});

test('parameters are clamped: a silly window is bounded, not trusted', async (t) => {
  const db = await openDb(t); if (!db) return;
  const r = await get(db, '?spend_min=0&long_min=999999,x,5,6,7&lookback_h=-5');
  assert.equal(r.status, 200);
  assert.equal(r.body.spend_min, 1);
  assert.deepEqual(r.body.long_min, [20160, 5, 6], 'numbers only, clamped, at most three');
  assert.equal(r.body.lookback_h, 336, 'the clamped 1h lookback is then widened to the 20160-min window (nit 4)');
  const alone = await get(db, '?long_min=5&lookback_h=-5');
  assert.equal(alone.body.lookback_h, 1, 'the lookback clamp itself, with no window to widen it');
});
