// BH-8973 (slice C0): GET /api/ticket-status and GET /api/ticket-status/stuck,
// the live per-ticket status the MCP tools ticket_status and stuck_tickets
// read. Driven through the REAL worker.fetch over the REAL composed schema
// (the node:sqlite D1 shim), with the request clock pinned (mock.timers Date).
//
//   S1  the schema.d fragment applies twice; the 4 knob seeds; a re-apply keeps
//       an operator's value; ensureColumns creates both new indexes
//   S2  the 400s, 404 unknown_repo, 409 ambiguous_repo, a repo resolved through
//       projects (trimmed, any case), fresh_at = request time, a D1 error = 503
//   S3  (T1) a claimed, spawned, running build: state, stage, machine, spawn
//       time, last checkpoint; the answer matches the MCP fixture
//   S4  (T2) a sibling hold names its releasing ticket; released = queued;
//       claimed = spawning
//   S5  (T3) a reaped EXECUTE_EMPTY attempt, then the requeued running one
//   S6  wrong tenant and prefix keys: 0 rows, no cross-match
//   S7  (T4) /stuck: the knob, a row change with no deploy, fresh activity,
//       truncated measured at stuck_scan_limit + 1
//   S8  EXPLAIN QUERY PLAN at volume, and the statement count per warm call
//   S9  the state precedence table of plan.md, one case per row
//   S10 (T6) no cache: a row change shows on the next call
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'test-secret-fixture';
const NOW = '2026-11-02T12:00:00Z';
const NOW_MS = Date.parse(NOW);
const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const FRAGMENT = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-8973-ticket-status\.sql$/.test(n));
const FIXTURE_URL = new URL('../../../mcp/test/fixtures/ticket-status.bh-8973.json', import.meta.url);
const R = () => import('../src/routes/ticket-status.js');

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (min) => iso(NOW_MS - min * 60000);
const epochAgo = (min) => Math.floor((NOW_MS - min * 60000) / 1000);

mock.timers.enable({ apis: ['Date'], now: NOW_MS });

// A D1 that counts prepared statements: the cost of one call.
function counted(DB) {
  let n = 0;
  return {
    DB: { prepare(sql) { n += 1; return DB.prepare(sql); }, batch: (s) => DB.batch(s) },
    count: () => n,
    reset: () => { n = 0; },
  };
}

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const status = (DB, q) => call(DB, `/api/ticket-status?${q}`);
const one = async (DB, q) => {
  const r = await status(DB, q);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.tickets.length, 1, JSON.stringify(r.body));
  return r.body.tickets[0];
};

const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','test','2026-11-02T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));

async function fresh() {
  const o = await openDb();
  await ensureColumns({ DB: d1(o.db) }, 'build_queue');
  await ensureColumns({ DB: d1(o.db) }, 'pr_records');
  return o;
}
function project(db, name, repo) {
  db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at)
    VALUES (?, ?, 0, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')`).run(name, repo);
}
function queue(db, p, key, o = {}) {
  db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, attempt, claimed_by, claimed_at,
      enqueued_at, finished_at, reason, updated_at, machine, phase, phase_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(p, key, o.ticket_id ?? null, o.status ?? 'queued',
    o.attempt ?? 0, o.claimed_by ?? null, o.claimed_at ?? null, o.enqueued_at ?? ago(300), o.finished_at ?? null,
    o.reason ?? null, o.updated_at ?? ago(60), o.machine ?? null, o.phase ?? null, o.phase_at ?? null);
}
function job(db, p, key, id, o = {}) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, p, key, o.kind ?? 'build', o.box ?? 'm-fixture-1',
    o.stage ?? 'execute', o.status ?? 'running', o.created_at ?? ago(30), o.updated_at ?? ago(20),
    o.meta === undefined ? null : JSON.stringify(o.meta));
}
const beat = (db, id, at) => db.prepare(
  'INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?, ?, ?)').run(id, at, 'm-fixture-1');
const spawn = (db, p, key, ts, machine) => db.prepare(
  "INSERT INTO pool_spawns (project, ticket_key, ts, box, machine, created_at) VALUES (?, ?, ?, 'hub-fixture', ?, ?)"
).run(p, key, ts, machine, iso(ts * 1000));
const markerRow = (db, p, key, marker, value, at) => db.prepare(
  "INSERT INTO pool_markers (project, ticket_key, marker, value, box, updated_at) VALUES (?, ?, ?, ?, 'hub-fixture', ?)"
).run(p, key, marker, value, at);
const terminal = (db, p, key, cleared) => db.prepare(
  `INSERT INTO pool_terminals (project, ticket_key, branch, head_sha, reason, created_at, box, cleared_at, updated_at)
   VALUES (?, ?, ?, 'abc1234', 'push rejected', ?, 'hub-fixture', ?, ?)`
).run(p, key, `ticket/${key.toLowerCase()}`, ago(100), cleared ? ago(50) : null, ago(50));
function pr(db, repo, number, o = {}) {
  db.prepare(`INSERT INTO pr_records (repo, number, state, head_ref, review_decision, queue_state, merged_at, url, created_at, refreshed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(repo, number, o.state ?? 'open', o.head_ref, o.review_decision ?? null,
    o.queue_state ?? null, o.merged_at ?? null, `https://github.com/${repo}/pull/${number}`, ago(90), ago(5));
}
// The br_attempt row key comes from the resolver's OWN shell helpers, so the
// fixture writes the shape production writes: bra_key(<p>, br_cap_key(...)).
const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const shellBrKey = (p, key, stamp) => execFileSync('bash', ['-c',
  '. bin/lib/br/record.sh && . bin/blocked-resolver.d/bh-7801-br-attempts.sh && bra_key "$1" "$(br_cap_key "$1" "RB-1-abcdef12" "$2")" "$3" 1',
  'bra', p, key, stamp], { cwd: REPO_ROOT, encoding: 'utf8' });
const brRow = (db, p, key, stamp, statusWord, at) => db.prepare(
  `INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES ('br_attempt', ?, ?, '{}', ?, ?)`
).run(shellBrKey(p, key, stamp), statusWord, at, at);
const edge = (db, p, parent, child) => db.prepare(
  `INSERT INTO ticket_edges (project, parent, child, kind, source, at) VALUES (?, ?, ?, 'hard', 'planner', ?)`
).run(p, parent, child, ago(100));
const event = (db, p, key, from, to, at) => db.prepare(
  `INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at) VALUES (?, ?, ?, ?, 'pool', 'r', NULL, ?)`
).run(p, key, from, to, at);

// The fields of one ticket the MCP fixture carries (plan.md M1).
const OWNED = ['key', 'issue', 'state', 'stage', 'rung', 'machine', 'spawned_at', 'claimed_at', 'branch', 'pr',
  'last_checkpoint_at', 'last_activity_at', 'attempts', 'events', 'waits_on', 'hold', 'truncated'];
const pick = (o, keys) => Object.fromEntries(keys.map((k) => [k, o[k]]));

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('S1 the fragment applies twice; the 4 knob seeds; a re-apply keeps a changed value; both indexes', { skip: SKIP }, async () => {
  assert.ok(FRAGMENT, 'worker/jobs/schema.d/<stamp>-bh-8973-ticket-status.sql exists');
  const sql = readFileSync(new URL(FRAGMENT, SCHEMA_D), 'utf8');
  assert.doesNotMatch(sql, /CREATE TABLE/i, 'settings rows only');
  const { db, DB } = await openDb();
  const want = {
    'ticket_status.stuck_min': '90', 'ticket_status.batch_max': '20',
    'ticket_status.attempts_limit': '20', 'ticket_status.stuck_scan_limit': '200',
  };
  const seeds = () => Object.fromEntries(db.prepare(
    "SELECT key, value FROM settings WHERE key LIKE 'ticket_status.%'").all().map((r) => [r.key, r.value]));
  assert.deepEqual(seeds(), want);
  setting(db, 'ticket_status.stuck_min', '45');
  db.exec(sql);
  db.exec(sql);
  assert.deepEqual(seeds(), { ...want, 'ticket_status.stuck_min': '45' });
  const has = (t, n) => db.prepare(`PRAGMA index_list(${t})`).all().some((r) => r.name === n);
  assert.equal(has('build_queue', 'idx_build_queue_project_ticket_id'), false, 'the index comes from core.d');
  await ensureColumns({ DB }, 'build_queue');
  await ensureColumns({ DB }, 'pr_records');
  assert.deepEqual(db.prepare('PRAGMA index_info(idx_build_queue_project_ticket_id)').all().map((r) => r.name), ['project', 'ticket_id']);
  assert.deepEqual(db.prepare('PRAGMA index_info(idx_pr_records_repo_head)').all().map((r) => r.name), ['repo', 'head_ref']);
});

test('S2 the refusals, repo resolution, fresh_at and a D1 error', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's2', 'example-org/S2-Repo');
  project(db, 's2a', 'example-org/dup');
  project(db, 's2b', 'example-org/dup');
  queue(db, 's2', 'BH-1', { ticket_id: '11' });
  for (const [q, code, err] of [
    ['key=BH-1', 400, 'project'],
    ['project=s2&repo=example-org/S2-Repo&key=BH-1', 400, 'project'],
    ['project=S2!&key=BH-1', 400, 'project'],
    ['project=s2', 400, 'ticket'],
    ['project=s2&key=BH%201', 400, 'key'],
    ['project=s2&issue=0', 400, 'issue'],
    ['project=s2&issue=1.5', 400, 'issue'],
    ['project=s2&issue=abc', 400, 'issue'],
    ['repo=example-org/none&key=BH-1', 404, 'unknown_repo'],
    ['repo=example-org/dup&key=BH-1', 409, 'ambiguous_repo'],
  ]) {
    const r = await status(DB, q);
    assert.equal(r.status, code, `${q}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, err, q);
  }
  const keys = Array.from({ length: 21 }, (_, i) => `key=BH-${i + 1}`).join('&');
  const big = await status(DB, `project=s2&${keys}`);
  assert.equal(big.status, 400);
  assert.deepEqual([big.body.error, big.body.max], ['too_many', 20]);
  // 20 is the knob's value: 20 tickets pass, a smaller knob refuses them.
  const twenty = Array.from({ length: 20 }, (_, i) => `key=BH-${i + 1}`).join('&');
  assert.equal((await status(DB, `project=s2&${twenty}`)).status, 200);
  setting(db, 'ticket_status.batch_max', '3');
  const four = await status(DB, 'project=s2&key=BH-1&key=BH-2&key=BH-3&issue=40');
  assert.deepEqual([four.status, four.body.error, four.body.max], [400, 'too_many', 3]);
  setting(db, 'ticket_status.batch_max', '20');

  const r = await status(DB, 'repo=%20Example-ORG/s2-REPO%20&key=bh-1');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.project, 's2');
  assert.equal(r.body.repo, 'example-org/S2-Repo');
  assert.equal(r.body.format, 'ticket-status v1');
  assert.equal(r.body.fresh_at, NOW);
  assert.equal(r.body.tickets[0].key, 'BH-1', 'a key is trimmed and upper-cased once');
  assert.equal(r.body.tickets[0].state, 'queued');
  // An issue resolves through build_queue.ticket_id; one with no row is unknown.
  const byIssue = await status(DB, 'project=s2&issue=11&issue=12');
  assert.deepEqual(byIssue.body.tickets.map((t) => [t.key, t.issue]), [['BH-1', 11]]);
  assert.deepEqual(byIssue.body.unknown, [{ issue: 12 }]);

  // A failed read is a 503, never a partial not_known.
  const broken = { prepare: (s) => DB.prepare(s), batch: async () => { throw new Error('D1_ERROR: fixture failure'); } };
  const e = await status(broken, 'project=s2&key=BH-1');
  assert.equal(e.status, 503, JSON.stringify(e.body));
  assert.equal(e.body.tickets, undefined);
});

async function seedS3(db) {
  project(db, 's3', 'example-org/s3-fixture');
  queue(db, 's3', 'BH-8973', { ticket_id: '8973', status: 'claimed', claimed_by: 'hub-fixture', claimed_at: ago(30),
    machine: 'm-fixture-1', updated_at: ago(30), enqueued_at: ago(40) });
  spawn(db, 's3', 'BH-8973', epochAgo(29), 'm-fixture-1');
  job(db, 's3', 'BH-8973', 'build-s3-BH-8973-1', { stage: 'execute', status: 'running', created_at: ago(28),
    updated_at: ago(10), meta: { branch: 'ticket/bh-8973', runner: 'fly' } });
  beat(db, 'build-s3-BH-8973-1', ago(2));
  event(db, 's3', 'BH-8973', null, 'building', ago(28));
}

test('S3 (T1) a claimed, spawned, running build reads running/execute with its machine and checkpoint', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  await seedS3(db);
  const r = await status(DB, 'project=s3&key=BH-8973');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const t = r.body.tickets[0];
  assert.equal(t.state, 'running');
  assert.equal(t.stage, 'execute');
  assert.equal(t.machine, 'm-fixture-1');
  assert.equal(t.spawned_at, iso(epochAgo(29) * 1000));
  assert.equal(t.claimed_at, ago(30));
  assert.equal(t.last_checkpoint_at, ago(2), 'the heartbeat is the newest checkpoint');
  assert.equal(t.branch, 'ticket/bh-8973');
  assert.equal(t.issue, 8973);
  assert.deepEqual(t.attempts.map((a) => [a.job_id, a.status, a.ended_at]), [['build-s3-BH-8973-1', 'running', null]]);
  assert.deepEqual(t.events.map((e) => e.to), ['building']);
  assert.ok(Math.abs(Date.parse(r.body.fresh_at) - NOW_MS) <= 60000, 'fresh_at within 60 s');
  // The MCP fixture is this answer: drift on either side is red here.
  const fx = JSON.parse(readFileSync(FIXTURE_URL, 'utf8'));
  assert.deepEqual(pick(fx, ['format', 'project', 'repo', 'fresh_at', 'unknown']), pick(r.body, ['format', 'project', 'repo', 'fresh_at', 'unknown']));
  assert.deepEqual(pick(fx.tickets[0], OWNED), pick(t, OWNED));
});

test('S4 (T2) a sibling hold: held, names the releasing ticket; released = queued; claimed = spawning', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's4', 'example-org/s4-fixture');
  queue(db, 's4', 'BH-9002', { status: 'queued' });
  queue(db, 's4', 'BH-9001', { status: 'claimed', claimed_at: ago(15), machine: 'm-fixture-9' });
  const put = (marker, value) => call(DB, '/api/pool-state/markers', { method: 'PUT', body: { project: 's4', key: 'BH-9002', marker, value } });
  assert.equal((await put('after-since', `BH-9001\t${epochAgo(20)}`)).status, 200);
  let t = await one(DB, 'project=s4&key=BH-9002');
  assert.equal(t.state, 'held');
  assert.equal(t.hold.reason, 'sibling_hold');
  assert.match(t.hold.releases, /BH-9001/);
  const sib = t.waits_on.find((w) => w.kind === 'sibling_hold');
  assert.deepEqual([sib.ticket, sib.since, sib.state], ['BH-9001', ago(20), 'claimed']);
  // The writer's release: clear after-since, put after-released (fly-pool.sh pool_after_gate).
  const clr = await call(DB, '/api/pool-state/markers', { method: 'PATCH', body: { project: 's4', key: 'BH-9002', clear: true, markers: ['after-since'] } });
  assert.equal(clr.status, 200);
  assert.equal((await put('after-released', `BH-9001\t1\t${epochAgo(20)}`)).status, 200);
  t = await one(DB, 'project=s4&key=BH-9002');
  assert.equal(t.state, 'queued');
  assert.equal(t.hold, null);
  assert.equal(t.waits_on.some((w) => w.kind === 'sibling_hold'), false);
  db.prepare("UPDATE build_queue SET status='claimed', claimed_at=?, machine='m-fixture-2', updated_at=? WHERE project='s4' AND ticket_key='BH-9002'").run(ago(1), ago(1));
  t = await one(DB, 'project=s4&key=BH-9002');
  assert.equal(t.state, 'spawning');
  assert.equal(t.machine, 'm-fixture-2');
});

test('S5 (T3) a reaped EXECUTE_EMPTY attempt is stopped with its outcome; the requeued one runs', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's5', 'example-org/s5-fixture');
  queue(db, 's5', 'BH-7001', { status: 'done', finished_at: ago(50), updated_at: ago(50) });
  job(db, 's5', 'BH-7001', 'build-s5-BH-7001-1', { status: 'failed', stage: 'execute', created_at: ago(60), updated_at: ago(50),
    meta: { result: 'EXECUTE_EMPTY reaped: no commits after 40 min' } });
  let t = await one(DB, 'project=s5&key=BH-7001');
  assert.equal(t.state, 'stopped');
  assert.equal(t.attempts[0].outcome, 'EXECUTE_EMPTY');
  assert.equal(t.attempts[0].ended_at, ago(50));
  db.prepare("UPDATE build_queue SET status='claimed', claimed_at=?, machine='m-fixture-5', updated_at=? WHERE project='s5' AND ticket_key='BH-7001'").run(ago(8), ago(8));
  t = await one(DB, 'project=s5&key=BH-7001');
  assert.equal(t.state, 'spawning', 'claimed again, the old job ended before the claim');
  job(db, 's5', 'BH-7001', 'build-s5-BH-7001-2', { status: 'running', stage: 'plan', created_at: ago(5), updated_at: ago(4) });
  t = await one(DB, 'project=s5&key=BH-7001');
  assert.deepEqual([t.state, t.stage], ['running', 'plan']);
  assert.deepEqual(t.attempts.map((a) => [a.job_id, a.outcome]), [['build-s5-BH-7001-2', null], ['build-s5-BH-7001-1', 'EXECUTE_EMPTY']]);
});

test('S6 wrong tenant and prefix keys give 0 rows and no cross-match', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's6a', 'example-org/s6a-fixture');
  project(db, 's6b', 'example-org/s6b-fixture');
  queue(db, 's6b', 'BH-8973', { status: 'claimed', claimed_at: ago(5), machine: 'm-fixture-6' });
  job(db, 's6b', 'BH-8973', 'build-s6b-1', {});
  pr(db, 'example-org/s6b-fixture', 6, { head_ref: 'ticket/bh-8973', state: 'merged', merged_at: ago(1) });
  brRow(db, 's6b', 'BH-8973', '20261102115000', 'fix', ago(1));
  markerRow(db, 's6b', 'BH-8973', 'after-since', `BH-1\t${epochAgo(3)}`, ago(3));
  let t = await one(DB, 'project=s6a&key=BH-8973');
  assert.equal(t.state, 'not_known');
  assert.deepEqual([t.attempts, t.events, t.waits_on, t.pr, t.machine], [[], [], [], null, null]);

  project(db, 's6c', 'example-org/s6c-fixture');
  queue(db, 's6c', 'BH-89731', { status: 'done' });
  job(db, 's6c', 'BH-89731', 'build-s6c-1', { status: 'done', updated_at: ago(40) });
  pr(db, 'example-org/s6c-fixture', 7, { head_ref: 'ticket/bh-89731', state: 'merged', merged_at: ago(30) });
  pr(db, 'example-org/s6c-fixture', 8, { head_ref: 'ticket/bh-8973x', state: 'open' });
  brRow(db, 's6c', 'BH-89731', '20261102115500', 'rebuild', ago(2));
  t = await one(DB, 'project=s6c&key=BH-8973');
  assert.deepEqual([t.state, t.pr, t.rung ?? null, t.attempts.length], ['not_known', null, null, 0]);
  // The positive control: the same rows match their own key.
  t = await one(DB, 'project=s6c&key=BH-89731');
  assert.equal(t.state, 'merged');
  assert.equal(t.pr.number, 7);
});

test('S7 (T4) /stuck reports tickets with no activity past ticket_status.stuck_min', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's7', 'example-org/s7-fixture');
  queue(db, 's7', 'BH-A', { status: 'queued', updated_at: ago(91), enqueued_at: ago(200) });
  queue(db, 's7', 'BH-B', { status: 'claimed', claimed_at: ago(89), updated_at: ago(89), enqueued_at: ago(199) });
  queue(db, 's7', 'BH-C', { status: 'done', updated_at: ago(500), enqueued_at: ago(198) });
  queue(db, 's7', 'BH-E', { status: 'queued', updated_at: ago(95), enqueued_at: ago(197) });
  spawn(db, 's7', 'BH-E', epochAgo(5), 'm-fixture-7');
  queue(db, 's7x', 'BH-A', { status: 'queued', updated_at: ago(500), enqueued_at: ago(500) });
  const stuck = () => call(DB, '/api/ticket-status/stuck?project=s7');
  let r = await stuck();
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.tickets.map((t) => t.key), ['BH-A']);
  assert.deepEqual([r.body.stuck_min, r.body.scanned, r.body.truncated, r.body.fresh_at], [90, 3, false, NOW]);
  assert.equal(r.body.tickets[0].state, 'queued');
  assert.equal(r.body.tickets[0].last_activity_at, ago(91));
  setting(db, 'ticket_status.stuck_min', '100');
  assert.deepEqual((await stuck()).body.tickets, [], 'a row change takes effect with no deploy');
  setting(db, 'ticket_status.stuck_min', '88');
  assert.deepEqual((await stuck()).body.tickets.map((t) => t.key), ['BH-A', 'BH-B'], 'oldest activity first');
  setting(db, 'ticket_status.stuck_min', '90');
  job(db, 's7', 'BH-A', 'build-s7-A', { status: 'done', created_at: ago(300), updated_at: ago(300) });
  beat(db, 'build-s7-A', ago(1));
  assert.deepEqual((await stuck()).body.tickets, [], 'a fresh heartbeat is activity');
  setting(db, 'ticket_status.stuck_scan_limit', '2');
  r = await stuck();
  assert.deepEqual([r.body.scanned, r.body.truncated], [2, true]);
  setting(db, 'ticket_status.stuck_scan_limit', '3');
  r = await stuck();
  assert.deepEqual([r.body.scanned, r.body.truncated], [3, false]);
  const byRepo = await call(DB, '/api/ticket-status/stuck?repo=example-org/s7-fixture');
  assert.deepEqual([byRepo.status, byRepo.body.project], [200, 's7']);
  assert.equal((await call(DB, '/api/ticket-status/stuck')).status, 400);
});

test('S8 EXPLAIN QUERY PLAN at volume uses indexes; statements per warm call are bounded', { skip: SKIP }, async () => {
  const { db } = await fresh();
  const M = await R();
  const projects = ['cromford', 'project-3', 'project-4', 'project-1', 'project-5'];
  projects.forEach((p) => project(db, p, `example-org/${p}`));
  const base = Date.parse('2026-04-01T00:00:00Z');
  db.exec('BEGIN');
  const q = db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, enqueued_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)`);
  for (let i = 0; i < 10000; i++) q.run(projects[i % 5], `T-${i}`, String(i), ['done', 'queued', 'claimed', 'failed'][i % 4], iso(base + i * 60000), iso(base + i * 60000));
  const j = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta)
    VALUES (?, ?, ?, ?, 'b', 'execute', 'done', ?, ?, '{"result":"PR_CREATED x"}')`);
  for (let i = 0; i < 50000; i++) j.run(`j-${i}`, projects[i % 5], `T-${i % 10000}`, i % 7 ? 'build' : 'triage', iso(base + i * 30000), iso(base + i * 30000));
  const p = db.prepare(`INSERT INTO pr_records (repo, number, state, head_ref, created_at, refreshed_at) VALUES (?, ?, 'merged', ?, ?, ?)`);
  for (let i = 0; i < 20000; i++) p.run(`example-org/${projects[i % 5]}`, i + 1, `ticket/t-${i % 10000}`, iso(base), iso(base));
  const e = db.prepare(`INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at) VALUES (?, ?, 'building', 'pr_open', 'pool', 'r', NULL, ?)`);
  for (let i = 0; i < 200000; i++) e.run(projects[i % 5], `T-${i % 10000}`, iso(base + i * 30000));
  const l = db.prepare(`INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?, ?, 'fix', ?, ?)`);
  for (let i = 0; i < 20000; i++) l.run(i % 2 ? 'br_attempt' : 'merge', `${projects[i % 5]}/T-${i % 10000}#2026${String(i).padStart(10, '0')}#000001`, iso(base), iso(base));
  const s = db.prepare(`INSERT INTO pool_spawns (project, ticket_key, ts, box, machine, created_at) VALUES (?, ?, ?, 'h', 'm', ?)`);
  for (let i = 0; i < 20000; i++) s.run(projects[i % 5], `T-${i % 10000}`, 1760000000 + i, iso(base));
  const ed = db.prepare(`INSERT INTO ticket_edges (project, parent, child, kind, source, at) VALUES (?, ?, ?, 'hard', 'planner', ?)`);
  for (let i = 0; i < 10000; i++) ed.run(projects[i % 5], String(i), String((i * 7) % 10000), iso(base));
  const hb = db.prepare('INSERT INTO job_heartbeats (job_id, beat_at) VALUES (?, ?)');
  const se = db.prepare(`INSERT INTO stage_events (job_id, stage, actor, created_at) VALUES (?, 'execute', 'a', ?)`);
  for (let i = 0; i < 50000; i++) { hb.run(`j-${i}`, iso(base)); se.run(`j-${i}`, iso(base)); }
  db.exec('COMMIT');
  db.exec('ANALYZE');

  const keys = JSON.stringify(['T-17', 'T-18', 'T-4242']);
  const issues = JSON.stringify(['17', '99']);
  const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
  const cases = Object.entries(M.SQL).map(([name, sql]) => {
    const binds = {
      repo: ['example-org/project-3'],
      candidates: ['project-3', 201],
      beats: [JSON.stringify(['j-1', 'j-2'])],
      stages: [JSON.stringify(['j-1', 'j-2'])],
      blockers: ['project-3', keys, issues],
    }[name] ?? ['project-3', keys, issues, 21];
    return [name, sql, binds.slice(0, (sql.match(/\?\d/g) || []).reduce((m, x) => Math.max(m, Number(x.slice(1))), 0))];
  });
  assert.ok(cases.length >= 14, `every SQL text is exported: ${cases.map((c) => c[0]).join(',')}`);
  for (const [name, sql, binds] of cases) {
    const lines = planOf(sql, binds);
    assert.ok(!lines.some((x) => /^SCAN (build_queue|jobs|pr_records|ticket_events|ledgers|pool_spawns|pool_markers|pool_holds|pool_terminals|ticket_edges|job_heartbeats|stage_events)\b/.test(x)),
      `${name}: a full SCAN: ${lines.join(' | ')}`);
    // A large table's index used on its project or repo prefix alone reads a
    // whole project (projects is the one-row PK lookup of PR_REPO).
    assert.ok(!lines.some((x) => /^SEARCH (build_queue|jobs|pr_records|ticket_events|ledgers|pool_\w+|ticket_edges) USING (COVERING )?INDEX \S+ \((project|repo)=\?\)$/.test(x)),
      `${name}: a whole-project range: ${lines.join(' | ')}`);
    // SQL.repo reads the projects registry whole: one row per fleet project.
    if (name === 'repo') continue;
    assert.ok(lines.some((x) => /USING (COVERING )?INDEX|USING (INTEGER )?PRIMARY KEY/.test(x)), `${name}: no index: ${lines.join(' | ')}`);
  }
  const named = (name, idx) => assert.ok(planOf(M.SQL[name], cases.find((c) => c[0] === name)[2]).some((x) => x.includes(idx)), `${name} uses ${idx}`);
  named('queue', 'idx_build_queue_project_ticket_id (project=? AND ticket_id=?)');
  named('prs', 'idx_pr_records_repo_head (repo=? AND head_ref');
  named('edges', 'idx_ticket_edges_child (project=? AND child=?)');
  named('br', '(kind=? AND key>? AND key<?)');
  named('jobs', 'idx_jobs_project_ticket');
  named('events', 'idx_ticket_events_project_ticket_id');
  named('candidates', 'idx_build_queue_status');

  // Statements per warm call, counted through the shim. T-1, T-6, ... are
  // project-3 keys with jobs, spawns and br rows, so every round runs.
  const c = counted(d1(db));
  const project-3 = (n) => Array.from({ length: n }, (_, i) => `key=T-${1 + 5 * i}`).join('&');
  await status(c.DB, `project=project-3&${project-3(2)}`);
  c.reset();
  const a = await status(c.DB, `project=project-3&${project-3(2)}&issue=99`);
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.ok(a.body.tickets[0].attempts.length > 0, 'the fixture keys have jobs');
  assert.ok(c.count() <= 15, `ticket_status ran ${c.count()} statements`);
  c.reset();
  const full = await status(c.DB, `project=project-3&${project-3(20)}`);
  assert.equal(full.body.tickets.length, 20);
  assert.ok(c.count() <= 15, `the cost does not grow with N: 20 tickets ran ${c.count()} statements`);
  await call(c.DB, '/api/ticket-status/stuck?project=project-3');
  c.reset();
  const st = await call(c.DB, '/api/ticket-status/stuck?project=project-3');
  assert.equal(st.status, 200, JSON.stringify(st.body));
  assert.ok(c.count() <= 16, `stuck_tickets ran ${c.count()} statements`);
});

test('S9a the br_attempt key is the resolver shell shape <p>/<p>-<KEY>#, never <p>/<KEY>#', { skip: SKIP }, async () => {
  assert.equal(shellBrKey('s9a', 'K-SH', '20261102115000'), 's9a/s9a-K-SH#20261102115000#000001');
  const { db, DB } = await fresh();
  project(db, 's9a', 'example-org/s9a-fixture');
  queue(db, 's9a', 'K-SH', { status: 'done' });
  job(db, 's9a', 'K-SH', 'sh-1', { status: 'done', created_at: ago(90), updated_at: ago(60) });
  // a row in the old wrong shape is not this ticket's resolver row
  db.prepare(`INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES ('br_attempt', ?, 'rebuild', '{}', ?, ?)`)
    .run('s9a/K-SH#20261102115500#000001', ago(5), ago(5));
  let x = await one(DB, 'project=s9a&key=K-SH');
  assert.notEqual(x.state, 'in_resolver');
  brRow(db, 's9a', 'K-SH', '20261102115000', 'fix', ago(10));
  x = await one(DB, 'project=s9a&key=K-SH');
  assert.deepEqual([x.state, x.rung], ['in_resolver', 'fix']);
});

test('S9 the state precedence table, one case per row, through the route', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's9', 'example-org/s9-fixture');
  const REPO = 'example-org/s9-fixture';
  const t = (key) => one(DB, `project=s9&key=${key}`);
  // running fix job -> running/fix-and-recheck, with a fix_round wait
  queue(db, 's9', 'K-FIX', { status: 'done' });
  job(db, 's9', 'K-FIX', 'fix-1', { kind: 'fix', stage: 'review', status: 'running', created_at: ago(5) });
  let x = await t('K-FIX');
  assert.deepEqual([x.state, x.stage], ['running', 'fix-and-recheck']);
  assert.deepEqual(x.waits_on.find((w) => w.kind === 'fix_round'), { kind: 'fix_round', state: 'review' });
  // claimed + machine, no job -> spawning
  queue(db, 's9', 'K-SPAWN', { status: 'claimed', claimed_at: ago(3), machine: 'm-fixture-s' });
  assert.equal((await t('K-SPAWN')).state, 'spawning');
  // claimed, an old done job from before the claim -> spawning (near miss)
  queue(db, 's9', 'K-INH', { status: 'claimed', claimed_at: ago(3) });
  job(db, 's9', 'K-INH', 'inh-1', { status: 'done', created_at: ago(90), updated_at: ago(80) });
  assert.equal((await t('K-INH')).state, 'spawning');
  // queued + a stale after-since and a NEWER after-released -> queued (near miss)
  queue(db, 's9', 'K-REL', { status: 'queued' });
  markerRow(db, 's9', 'K-REL', 'after-since', `K-X\t${epochAgo(40)}`, ago(40));
  markerRow(db, 's9', 'K-REL', 'after-released', `K-X\t1\t${epochAgo(40)}`, ago(30));
  assert.equal((await t('K-REL')).state, 'queued');
  // a NEW hold after an older release -> held (the writer keeps after-released for 24 h)
  queue(db, 's9', 'K-REH', { status: 'queued' });
  markerRow(db, 's9', 'K-REH', 'after-released', `K-X\t1\t${epochAgo(90)}`, ago(90));
  markerRow(db, 's9', 'K-REH', 'after-since', `K-X\t${epochAgo(20)}`, ago(20));
  x = await t('K-REH');
  assert.deepEqual([x.state, x.hold && x.hold.reason], ['held', 'sibling_hold']);
  assert.equal(x.waits_on.find((w) => w.kind === 'sibling_hold').state, 'not_known');
  // a ticket hold -> held
  queue(db, 's9', 'K-THOLD', { status: 'queued' });
  assert.equal((await call(DB, '/api/pool-state/holds', { method: 'PUT', body: { project: 's9', kind: 'ticket', key: 'K-THOLD', why: 'operator hold' } })).status, 200);
  x = await t('K-THOLD');
  assert.deepEqual([x.state, x.hold.reason], ['held', 'ticket_hold']);
  assert.equal(x.waits_on.find((w) => w.kind === 'ticket_hold').why, 'operator hold');
  // terminal cleared + queued -> queued; terminal not cleared -> abandoned
  queue(db, 's9', 'K-TCLR', { status: 'queued' });
  terminal(db, 's9', 'K-TCLR', true);
  assert.equal((await t('K-TCLR')).state, 'queued');
  queue(db, 's9', 'K-TERM', { status: 'queued' });
  terminal(db, 's9', 'K-TERM', false);
  assert.equal((await t('K-TERM')).state, 'abandoned');
  // a merged PR beats a stale running job
  queue(db, 's9', 'K-MERGED', { status: 'done' });
  job(db, 's9', 'K-MERGED', 'm-1', { status: 'running', created_at: ago(200) });
  pr(db, REPO, 91, { head_ref: 'ticket/k-merged', state: 'merged', merged_at: ago(10) });
  x = await t('K-MERGED');
  assert.deepEqual([x.state, x.pr.number, x.branch], ['merged', 91, 'ticket/k-merged']);
  // an open PR + a done row -> pr_open, with the lead verdict and merge queue waits
  queue(db, 's9', 'K-PR', { status: 'done' });
  pr(db, REPO, 92, { head_ref: 'ticket/k-pr', state: 'open', review_decision: 'REVIEW_REQUIRED', queue_state: 'queued' });
  x = await t('K-PR');
  assert.equal(x.state, 'pr_open');
  assert.deepEqual(x.waits_on.filter((w) => ['lead_verdict', 'merge_queue'].includes(w.kind)),
    [{ kind: 'lead_verdict', state: 'REVIEW_REQUIRED' }, { kind: 'merge_queue', state: 'queued' }]);
  // a re-plan branch ticket/<key>-r2 is the same ticket's PR
  queue(db, 's9', 'K-R2', { status: 'done' });
  pr(db, REPO, 93, { head_ref: 'ticket/k-r2-r2', state: 'open' });
  x = await t('K-R2');
  assert.deepEqual([x.state, x.pr.number], ['pr_open', 93]);
  // in_resolver: the newest br_attempt is newer than the last job's end
  queue(db, 's9', 'K-BR', { status: 'done' });
  job(db, 's9', 'K-BR', 'br-1', { status: 'done', created_at: ago(90), updated_at: ago(60) });
  brRow(db, 's9', 'K-BR', '20261102115000', 'fix', ago(10));
  x = await t('K-BR');
  assert.deepEqual([x.state, x.rung], ['in_resolver', 'fix']);
  // an older br_attempt than the job's end -> not in the resolver
  queue(db, 's9', 'K-BROLD', { status: 'done' });
  job(db, 's9', 'K-BROLD', 'bro-1', { status: 'done', created_at: ago(30), updated_at: ago(20), meta: { result: '' } });
  brRow(db, 's9', 'K-BROLD', '20261102100000', 'fix', ago(120));
  x = await t('K-BROLD');
  assert.equal(x.state, 'stopped');
  assert.equal(x.attempts[0].outcome, null, 'an empty result is null, never invented');
  // attempts past the limit -> truncated.attempts
  setting(db, 'ticket_status.attempts_limit', '2');
  queue(db, 's9', 'K-MANY', { status: 'done' });
  for (let i = 0; i < 3; i++) job(db, 's9', 'K-MANY', `many-${i}`, { status: 'done', created_at: ago(100 - i), updated_at: ago(99 - i) });
  x = await t('K-MANY');
  assert.deepEqual(x.attempts.map((a) => a.job_id), ['many-2', 'many-1']);
  assert.deepEqual(x.truncated, { attempts: true, events: false });
  setting(db, 'ticket_status.attempts_limit', '20');
  // a blocker edge: the child's waits_on carries the blocker's own state, by issue
  queue(db, 's9', 'K-CHILD', { status: 'queued', ticket_id: '501' });
  queue(db, 's9', 'K-PARENT', { status: 'claimed', ticket_id: '400', claimed_at: ago(2) });
  edge(db, 's9', '400', '501');
  const byIssue = await status(DB, 'project=s9&issue=501');
  assert.equal(byIssue.body.tickets[0].key, 'K-CHILD');
  assert.deepEqual(byIssue.body.tickets[0].waits_on.find((w) => w.kind === 'blocker'), { kind: 'blocker', ticket: '400', key: 'K-PARENT', state: 'claimed' });
});

test('S9b a spawn hold holds a queued ticket only while until_at is in the future', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  queue(db, 's9d', 'K-1', { status: 'queued' });
  queue(db, 's9e', 'K-1', { status: 'queued' });
  for (const [p, until] of [['s9d', epochAgo(-30)], ['s9e', epochAgo(5)]]) {
    const r = await call(DB, '/api/pool-state/holds', { method: 'PUT', body: { project: p, kind: 'spawn', until_at: until, why: 'lane failure' } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
  }
  const d = await one(DB, 'project=s9d&key=K-1');
  assert.deepEqual([d.state, d.hold.reason], ['held', 'spawn_hold']);
  assert.deepEqual(d.waits_on.find((w) => w.kind === 'spawn_hold'), { kind: 'spawn_hold', why: 'lane failure', until: iso(epochAgo(-30) * 1000) });
  assert.equal((await one(DB, 'project=s9e&key=K-1')).state, 'queued', 'a past until_at is not a hold');
});

test('S10 (T6) no cache: a row change shows on the next call in the same isolate', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 's10', 'example-org/s10-fixture');
  queue(db, 's10', 'BH-10', { status: 'queued' });
  assert.equal((await one(DB, 'project=s10&key=BH-10')).state, 'queued');
  db.prepare("UPDATE build_queue SET status='claimed', claimed_at=?, updated_at=? WHERE project='s10'").run(ago(1), ago(1));
  assert.equal((await one(DB, 'project=s10&key=BH-10')).state, 'spawning');
});
