// BH-9503 (C1 of #8973): ONE status comment per ticket, edited in place at
// each state change. GET /api/ticket-status-comments/due says which tickets
// need a write (their rendered body changed since the last recorded write);
// POST /api/ticket-status-comments records a write the lane made. Driven
// through the REAL worker.fetch over the REAL composed schema (the node:sqlite
// D1 shim), with the request clock pinned (mock.timers Date).
//
//   C1  renderBody: the marker is line 1; the fingerprint ignores the Updated line
//   C2  queued -> claimed (spawning) -> running(plan, m1): due once per step
//   C3  held (sibling hold) -> queued after the release: due, no Held: line
//   C4  running -> reaped EXECUTE_EMPTY -> resumed running: due at each step
//   C5  PR opened, then merged: due twice; merged is final and leaves the watch set
//   C6  no secret: free text (why, reason, a secret-shaped result) is never rendered
//   C7  a heartbeat or a stage event alone is not a state change: not due
//   C8  POST then GET: not due; the 400s name the field; the upsert keeps created_at
//   C9  EXPLAIN QUERY PLAN at volume; statements per due call are constant
//       (the recent read: a ticket reaped with no comment row is still seen)
//   C10 deploy guard: a running attempt older than comment_not_before is not due
//   C11 ticket_status_comment.batch_max cuts the due list, truncated, rest next call
//   C12 the watch and recent sets read newest first; a scan cut sets window_cut
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'test-secret-fixture';
const NOW = '2026-11-11T12:00:00Z';
const NOW_MS = Date.parse(NOW);
const MARKER = '<!-- harness-status: ticket-status -->';
const M = () => import('../src/routes/ticket-status-comment.js');

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (min) => iso(NOW_MS - min * 60000);
const epochAgo = (min) => Math.floor((NOW_MS - min * 60000) / 1000);

mock.timers.enable({ apis: ['Date'], now: NOW_MS });

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
const dueOf = async (DB, p) => {
  const r = await call(DB, `/api/ticket-status-comments/due?project=${p}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
};
let nextComment = 7000001;
// record <due entry>: the lane's POST after a GitHub write succeeded.
const record = async (DB, p, d, commentId) => {
  const r = await call(DB, '/api/ticket-status-comments', { method: 'POST', body: {
    project: p, ticket_key: d.key, issue: d.issue, comment_id: commentId ?? d.comment_id ?? nextComment++,
    fingerprint: d.fingerprint, state: d.state, final: d.final,
  } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
};
// settle: one lane tick that writes every due ticket. -> the due list.
const settle = async (DB, p) => {
  const b = await dueOf(DB, p);
  for (const d of b.due) await record(DB, p, d);
  return b.due;
};

const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','test','2026-11-02T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
// The deploy guard is C10's subject; every other case starts after "deploy".
const EARLY = '2026-01-01T00:00:00Z';

async function fresh({ notBefore = EARLY } = {}) {
  const o = await openDb();
  await ensureColumns({ DB: d1(o.db) }, 'build_queue');
  await ensureColumns({ DB: d1(o.db) }, 'pr_records');
  if (notBefore) setting(o.db, 'ticket_status_comment.not_before', notBefore);
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
const setQueue = (db, p, key, cols) => {
  const names = Object.keys(cols);
  db.prepare(`UPDATE build_queue SET ${names.map((n) => `${n} = ?`).join(', ')} WHERE project = ? AND ticket_key = ?`)
    .run(...names.map((n) => cols[n]), p, key);
};
function job(db, p, key, id, o = {}) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, p, key, o.kind ?? 'build', o.box ?? 'm1',
    o.stage ?? 'execute', o.status ?? 'running', o.created_at ?? ago(30), o.updated_at ?? ago(20),
    o.meta === undefined ? null : JSON.stringify(o.meta));
}
const setJob = (db, id, cols) => {
  const names = Object.keys(cols);
  db.prepare(`UPDATE jobs SET ${names.map((n) => `${n} = ?`).join(', ')} WHERE id = ?`).run(...names.map((n) => cols[n]), id);
};
function pr(db, repo, number, o = {}) {
  db.prepare(`INSERT INTO pr_records (repo, number, state, head_ref, review_decision, queue_state, merged_at, url, created_at, refreshed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(repo, number, o.state ?? 'open', o.head_ref, o.review_decision ?? null,
    o.queue_state ?? null, o.merged_at ?? null, `https://github.com/${repo}/pull/${number}`, ago(90), ago(5));
}
const row = (db, p, key) => db.prepare('SELECT * FROM ticket_status_comments WHERE project = ? AND ticket_key = ?').get(p, key);

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('C1 renderBody: the marker is line 1; the fingerprint ignores the Updated line only', { skip: SKIP }, async () => {
  const { renderBody, fingerprint } = await M();
  const t = { key: 'BH-1', issue: 1, state: 'running', stage: 'execute', rung: null, machine: 'm1', spawned_at: ago(30),
    pr: null, attempts: [{ status: 'running', started_at: ago(30), ended_at: null, outcome: null }], waits_on: [], hold: null };
  const a = renderBody(t, NOW);
  const b = renderBody(t, ago(-7));
  assert.equal(a.split('\n')[0], MARKER);
  assert.match(a, /\*\*Build status: running\*\* \(stage: execute\)/);
  assert.match(a, /^Updated 2026-11-11 12:00Z\./m);
  assert.notEqual(a, b, 'the Updated line moves with the clock');
  assert.equal(await fingerprint(a), await fingerprint(b), 'and the fingerprint does not');
  assert.match(await fingerprint(a), /^[0-9a-f]{16}$/);
  const c = renderBody({ ...t, stage: 'review' }, NOW);
  assert.notEqual(await fingerprint(a), await fingerprint(c), 'a stage change is a new fingerprint');
});

test('C2 queued -> claimed -> running(plan, m1): each step is due once with a new fingerprint', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c2', 'example-org/c2-fixture');
  queue(db, 'c2', 'BH-201', { ticket_id: '201' });
  queue(db, 'c2', 'TK-12', { ticket_id: 'TK-12' });            // an in-app board key: no issue, never due
  queue(db, 'c2-other', 'BH-202', { ticket_id: '202' });       // another tenant: never in c2's answer
  let b = await dueOf(DB, 'c2');
  assert.equal(b.format, 'ticket-status-comment v1');
  assert.equal(b.repo, 'example-org/c2-fixture');
  assert.deepEqual(b.due.map((d) => [d.key, d.issue, d.state, d.comment_id]), [['BH-201', 201, 'queued', null]]);
  assert.match(b.due[0].body, /Build status: queued/);
  const fps = [b.due[0].fingerprint];
  await record(DB, 'c2', b.due[0]);
  assert.deepEqual((await dueOf(DB, 'c2')).due, [], 'nothing changed: not due');

  setQueue(db, 'c2', 'BH-201', { status: 'claimed', claimed_at: ago(2), machine: 'm1', updated_at: ago(2) });
  b = await dueOf(DB, 'c2');
  assert.deepEqual(b.due.map((d) => [d.key, d.state]), [['BH-201', 'spawning']]);
  assert.equal(b.due[0].comment_id, 7000001, 'the recorded comment is named, so the lane edits it');
  assert.match(b.due[0].body, /Build status: spawning/);
  fps.push(b.due[0].fingerprint);
  await record(DB, 'c2', b.due[0]);

  job(db, 'c2', 'BH-201', 'build-c2-1', { stage: 'plan', status: 'running', created_at: ago(1), updated_at: ago(1), box: 'm1' });
  b = await dueOf(DB, 'c2');
  assert.deepEqual(b.due.map((d) => [d.key, d.state]), [['BH-201', 'running']]);
  assert.match(b.due[0].body, /Build status: running\*\* \(stage: plan\)/);
  assert.match(b.due[0].body, /Machine: m1/);
  fps.push(b.due[0].fingerprint);
  await record(DB, 'c2', b.due[0]);
  assert.equal(new Set(fps).size, 3, 'three states, three fingerprints');
  assert.deepEqual((await dueOf(DB, 'c2')).due, []);
  assert.equal(row(db, 'c2', 'BH-201').comment_id, 7000001, 'one comment row, the same comment id');
});

test('C3 held (sibling hold) -> queued after the release: due, and the body drops Held:', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c3', 'example-org/c3-fixture');
  queue(db, 'c3', 'BH-302', { ticket_id: '302' });
  queue(db, 'c3', 'BH-301', { ticket_id: '301', status: 'claimed', claimed_at: ago(15), machine: 'm9' });
  const put = (marker, value) => call(DB, '/api/pool-state/markers', { method: 'PUT', body: { project: 'c3', key: 'BH-302', marker, value } });
  assert.equal((await put('after-since', `BH-301\t${epochAgo(20)}`)).status, 200);
  const first = await settle(DB, 'c3');
  const held = first.find((d) => d.key === 'BH-302');
  assert.equal(held.state, 'held');
  assert.match(held.body, /Held: sibling hold on BH-301/);
  const clr = await call(DB, '/api/pool-state/markers', { method: 'PATCH', body: { project: 'c3', key: 'BH-302', clear: true, markers: ['after-since'] } });
  assert.equal(clr.status, 200);
  assert.equal((await put('after-released', `BH-301\t1\t${epochAgo(20)}`)).status, 200);
  const b = await dueOf(DB, 'c3');
  assert.deepEqual(b.due.map((d) => [d.key, d.state]), [['BH-302', 'queued']]);
  assert.doesNotMatch(b.due[0].body, /Held:/);
  assert.equal(b.due[0].comment_id, held.comment_id ?? row(db, 'c3', 'BH-302').comment_id);
});

test('C4 running -> reaped EXECUTE_EMPTY -> resumed running: due at each change', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c4', 'example-org/c4-fixture');
  queue(db, 'c4', 'BH-401', { ticket_id: '401', status: 'claimed', claimed_at: ago(40), machine: 'm4' });
  job(db, 'c4', 'BH-401', 'build-c4-1', { status: 'running', stage: 'execute', created_at: ago(39), updated_at: ago(30) });
  assert.deepEqual((await settle(DB, 'c4')).map((d) => d.state), ['running']);
  // The reaper: the job fails with its outcome, the queue row is done.
  setJob(db, 'build-c4-1', { status: 'failed', updated_at: ago(10), meta: JSON.stringify({ result: 'EXECUTE_EMPTY reaped: no commits' }) });
  setQueue(db, 'c4', 'BH-401', { status: 'done', finished_at: ago(10), updated_at: ago(10) });
  let b = await dueOf(DB, 'c4');
  assert.deepEqual(b.due.map((d) => d.state), ['stopped'], 'reaped: no queue row is open, the watch set still sees it');
  assert.match(b.due[0].body, /Last attempt: EXECUTE_EMPTY, ended 2026-11-11 11:50Z/);
  await record(DB, 'c4', b.due[0]);
  // Resumed: claimed again, a new attempt runs.
  setQueue(db, 'c4', 'BH-401', { status: 'claimed', claimed_at: ago(5), updated_at: ago(5) });
  job(db, 'c4', 'BH-401', 'build-c4-2', { status: 'running', stage: 'plan', created_at: ago(4), updated_at: ago(4) });
  b = await dueOf(DB, 'c4');
  assert.deepEqual(b.due.map((d) => d.state), ['running']);
  assert.match(b.due[0].body, /Build status: running\*\* \(stage: plan\)/);
  assert.match(b.due[0].body, /Last attempt: EXECUTE_EMPTY/);
});

test('C5 PR opened, then merged: due twice; merged is final and leaves the watch set', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c5', 'example-org/c5-fixture');
  queue(db, 'c5', 'BH-501', { ticket_id: '501', status: 'claimed', claimed_at: ago(40), machine: 'm5' });
  job(db, 'c5', 'BH-501', 'build-c5-1', { status: 'running', created_at: ago(39) });
  await settle(DB, 'c5');
  setJob(db, 'build-c5-1', { status: 'done', updated_at: ago(3), meta: JSON.stringify({ result: 'PR_CREATED #77', branch: 'ticket/bh-501' }) });
  setQueue(db, 'c5', 'BH-501', { status: 'done', finished_at: ago(3), updated_at: ago(3) });
  pr(db, 'example-org/c5-fixture', 77, { head_ref: 'ticket/bh-501', state: 'open' });
  let b = await dueOf(DB, 'c5');
  assert.deepEqual(b.due.map((d) => [d.state, d.final]), [['pr_open', false]]);
  assert.match(b.due[0].body, /PR: #77 \(open\)/);
  await record(DB, 'c5', b.due[0]);
  db.prepare("UPDATE pr_records SET state = 'merged', merged_at = ? WHERE number = 77").run(ago(1));
  b = await dueOf(DB, 'c5');
  assert.deepEqual(b.due.map((d) => [d.state, d.final]), [['merged', true]]);
  assert.match(b.due[0].body, /PR: #77 \(merged\)/);
  assert.equal(b.scanned, 1);
  await record(DB, 'c5', b.due[0]);
  assert.equal(row(db, 'c5', 'BH-501').final, 1);
  b = await dueOf(DB, 'c5');
  assert.deepEqual(b.due, [], 'merged and recorded: not due');
  const { SQL } = await M();
  assert.deepEqual(db.prepare(SQL.watch).all('c5', ago(14 * 1440), 201), [], 'a final row leaves the watch set');
});

test('C6 no secret: hold why, queue reason, event reason and a secret-shaped result are never rendered', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c6', 'example-org/c6-fixture');
  const SECRETS = ['ghp_fixtureAAAAAAAAAAAAAAAAAAAA', 'sk-ant-fixture-0000', 'Bearer fixture-token'];
  queue(db, 'c6', 'BH-601', { ticket_id: '601', reason: SECRETS[1] });
  db.prepare(`INSERT INTO pool_holds (project, kind, ticket_key, until_at, why, first_seen, updated_at)
    VALUES ('c6', 'ticket', 'BH-601', NULL, ?, ?, ?)`).run(`held: ${SECRETS[0]}`, ago(9), ago(9));
  db.prepare(`INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at)
    VALUES ('c6', 'BH-601', NULL, 'queued', 'pool', ?, NULL, ?)`).run(SECRETS[2], ago(8));
  queue(db, 'c6', 'BH-602', { ticket_id: '602', status: 'done', reason: SECRETS[1] });
  job(db, 'c6', 'BH-602', 'build-c6-2', { status: 'failed', updated_at: ago(2), meta: { result: `${SECRETS[0]} leaked into a result` } });
  const b = await dueOf(DB, 'c6');
  assert.deepEqual(b.due.map((d) => [d.key, d.state]), [['BH-601', 'held'], ['BH-602', 'stopped']]);
  assert.match(b.due[0].body, /Held: ticket hold/, 'the hold KIND is rendered');
  for (const d of b.due) {
    assert.doesNotMatch(d.body, /ghp_|ghs_|sk-|Bearer /, `${d.key}: ${d.body}`);
    for (const s of SECRETS) assert.ok(!d.body.includes(s), `${d.key} carries ${s}`);
  }
  assert.match(b.due[1].body, /Last attempt: failed/, 'an outcome that is not a code falls back to the status');
});

test('C7 a heartbeat or a stage event alone is not a state change: not due', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c7', 'example-org/c7-fixture');
  queue(db, 'c7', 'BH-701', { ticket_id: '701', status: 'claimed', claimed_at: ago(30), machine: 'm7' });
  job(db, 'c7', 'BH-701', 'build-c7-1', { status: 'running', stage: 'execute', created_at: ago(29), updated_at: ago(20) });
  await settle(DB, 'c7');
  db.prepare('INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?, ?, ?)').run('build-c7-1', ago(1), 'm7');
  db.prepare("INSERT INTO stage_events (job_id, stage, actor, created_at) VALUES ('build-c7-1', 'execute', 'a', ?)").run(ago(1));
  setJob(db, 'build-c7-1', { updated_at: ago(1) });
  assert.deepEqual((await dueOf(DB, 'c7')).due, [], 'activity moved, the state did not');
  // The positive control: a stage change is due.
  setJob(db, 'build-c7-1', { stage: 'review' });
  assert.deepEqual((await dueOf(DB, 'c7')).due.map((d) => d.state), ['running']);
});

test('C8 POST then GET is not due; the 400s name the field; the upsert keeps created_at', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  project(db, 'c8', 'example-org/c8-fixture');
  queue(db, 'c8', 'BH-801', { ticket_id: '801' });
  const b = await dueOf(DB, 'c8');
  const good = { project: 'c8', ticket_key: 'BH-801', issue: 801, comment_id: 6800001, fingerprint: b.due[0].fingerprint, state: 'queued', final: false };
  for (const [field, value] of [['project', 'C8!'], ['ticket_key', 'bh 801'], ['issue', 0], ['issue', '801'], ['comment_id', -1],
    ['comment_id', 1.5], ['fingerprint', 'XYZ'], ['state', 'exploded'], ['final', 'yes']]) {
    const r = await call(DB, '/api/ticket-status-comments', { method: 'POST', body: { ...good, [field]: value } });
    assert.deepEqual([r.status, r.body && r.body.error], [400, field], `${field}=${JSON.stringify(value)}`);
  }
  assert.equal(row(db, 'c8', 'BH-801'), undefined, 'a refused POST writes nothing');
  let r = await call(DB, '/api/ticket-status-comments', { method: 'POST', body: good });
  assert.deepEqual([r.status, r.body.ok], [200, true]);
  assert.deepEqual((await dueOf(DB, 'c8')).due, []);
  const first = row(db, 'c8', 'BH-801');
  assert.deepEqual([first.created_at, first.updated_at, first.comment_id], [NOW, NOW, 6800001]);
  mock.timers.setTime(NOW_MS + 5 * 60000);
  try {
    r = await call(DB, '/api/ticket-status-comments', { method: 'POST', body: { ...good, comment_id: 6800002, fingerprint: '0123456789abcdef' } });
    assert.equal(r.status, 200);
  } finally { mock.timers.setTime(NOW_MS); }
  const second = row(db, 'c8', 'BH-801');
  assert.deepEqual([second.created_at, second.updated_at, second.comment_id, second.fingerprint],
    [NOW, iso(NOW_MS + 5 * 60000), 6800002, '0123456789abcdef']);
  assert.equal(db.prepare("SELECT count(*) AS n FROM ticket_status_comments WHERE project = 'c8'").get().n, 1);
  assert.equal((await call(DB, '/api/ticket-status-comments/due?project=Bad!')).status, 400);
});

test('C9 EXPLAIN QUERY PLAN at volume uses the indexes; statements per due call are constant', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  const mod = await M();
  const retention = (await import('../src/routes/retention.d/bh-9503-ticket-status-comments.js')).default;
  const rule = retention.find((x) => x.table === 'ticket_status_comments');
  assert.ok(rule, 'a retention rule names ticket_status_comments');
  assert.equal(rule.key, 'retention.ticket_status_comments.days');
  assert.equal(db.prepare("SELECT value FROM settings WHERE key = 'retention.ticket_status_comments.days'").get().value, String(rule.def));
  const projects = ['cromford', 'project-3', 'project-4', 'project-1', 'project-5'];
  projects.forEach((p) => project(db, p, `example-org/${p}`));
  const base = Date.parse('2026-08-01T00:00:00Z');
  db.exec('BEGIN');
  const q = db.prepare('INSERT INTO build_queue (project, ticket_key, ticket_id, status, enqueued_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)');
  for (let i = 0; i < 10000; i++) q.run(projects[i % 5], `T-${i}`, String(i + 1), ['done', 'queued', 'claimed', 'failed'][i % 4], iso(base + i * 60000), iso(base + i * 60000));
  const c = db.prepare(`INSERT INTO ticket_status_comments (project, ticket_key, issue, comment_id, fingerprint, state, final, created_at, updated_at)
    VALUES (?, ?, ?, ?, '0123456789abcdef', 'queued', ?, ?, ?)`);
  for (let i = 0; i < 20000; i++) c.run(projects[i % 5], `T-${i}`, i + 1, 900000 + i, i % 3 ? 0 : 1, iso(base + i * 30000), iso(base + i * 30000));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
  const cases = [
    ['watch', mod.SQL.watch, ['project-3', iso(base), 201], 'idx_ticket_status_comments_watch'],
    ['candidates', mod.SQL.candidates, ['project-3', 201], 'sqlite_autoindex_ticket_status_comments_1'],
    ['recent', mod.SQL.recent, ['project-3', iso(base + 9000 * 60000), 201], 'idx_build_queue_project_updated (project=? AND updated_at>?)'],
    ['retention', rule.ids, [iso(base + 86400e3), 500], 'idx_ticket_status_comments_updated'],
    ['retention-del', rule.del, [JSON.stringify([1, 2, 3])], 'INTEGER PRIMARY KEY'],
  ];
  for (const [name, sql, binds, idx] of cases) {
    const lines = planOf(sql, binds);
    assert.ok(!lines.some((x) => /^SCAN (ticket_status_comments|build_queue)\b/.test(x)), `${name}: a full SCAN: ${lines.join(' | ')}`);
    assert.ok(lines.some((x) => x.includes(idx)), `${name} uses ${idx}: ${lines.join(' | ')}`);
    assert.ok(!lines.some((x) => /USE TEMP B-TREE FOR ORDER BY/.test(x)) || name === 'candidates', `${name}: a sort: ${lines.join(' | ')}`);
  }
  // Statements per warm call: the same for 1 open ticket and for 40.
  project(db, 'c9', 'example-org/c9-fixture');
  queue(db, 'c9', 'BH-901', { ticket_id: '901' });
  const k = counted(DB);
  await dueOf(k.DB, 'c9');                 // warm the isolate caches
  k.reset();
  await dueOf(k.DB, 'c9');
  const one = k.count();
  for (let i = 2; i <= 40; i++) queue(db, 'c9', `BH-9${String(i).padStart(2, '0')}`, { ticket_id: `9${String(i).padStart(2, '0')}` });
  k.reset();
  const b = await dueOf(k.DB, 'c9');
  assert.equal(b.due.length, 20, 'the batch cut is the seeded 20');
  assert.equal(k.count(), one, `the statement count does not grow with the tickets (${one})`);
  assert.ok(one <= 19, `at most 19 statements per warm call, got ${one}`);
});

test('C10 deploy guard: a running attempt older than comment_not_before gets no comment until it ends', { skip: SKIP }, async () => {
  const { db, DB } = await fresh({ notBefore: null });
  project(db, 'c10', 'example-org/c10-fixture');
  queue(db, 'c10', 'BH-1001', { ticket_id: '1001', status: 'claimed', claimed_at: ago(30), machine: 'm10' });
  job(db, 'c10', 'BH-1001', 'build-c10-1', { status: 'running', created_at: ago(29) });
  queue(db, 'c10', 'BH-1002', { ticket_id: '1002', status: 'claimed', claimed_at: ago(20), machine: 'm11' });   // spawning, claimed before deploy
  queue(db, 'c10', 'BH-1003', { ticket_id: '1003' });                                                            // queued: no attempt to disturb
  let b = await dueOf(DB, 'c10');
  assert.equal(db.prepare("SELECT value FROM settings WHERE key = 'ticket_status_comment.not_before'").get().value, NOW,
    'the first call stamps comment_not_before once');
  assert.deepEqual(b.due.map((d) => d.key), ['BH-1003'], 'the attempts that started before the stamp are not due');
  assert.equal(b.deferred, 2);
  // The stamp is written once: a later call does not move it.
  mock.timers.setTime(NOW_MS + 10 * 60000);
  try {
    await settle(DB, 'c10');
    assert.equal(db.prepare("SELECT value FROM settings WHERE key = 'ticket_status_comment.not_before'").get().value, NOW);
    // A new attempt after the stamp is due.
    setQueue(db, 'c10', 'BH-1002', { claimed_at: iso(NOW_MS + 5 * 60000), updated_at: iso(NOW_MS + 5 * 60000) });
    // The old attempt ends: its ticket is due now.
    setJob(db, 'build-c10-1', { status: 'done', updated_at: iso(NOW_MS + 9 * 60000), meta: JSON.stringify({ result: 'EXECUTE_EMPTY' }) });
    setQueue(db, 'c10', 'BH-1001', { status: 'done', updated_at: iso(NOW_MS + 9 * 60000) });
    b = await dueOf(DB, 'c10');
    assert.deepEqual(b.due.map((d) => [d.key, d.state]), [['BH-1001', 'stopped'], ['BH-1002', 'spawning']]);
  } finally { mock.timers.setTime(NOW_MS); }
});

test('C11 ticket_status_comment.batch_max cuts the due list; the rest comes on the next call', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  assert.equal(db.prepare("SELECT value FROM settings WHERE key = 'ticket_status_comment.batch_max'").get().value, '20');
  assert.equal(db.prepare("SELECT value FROM settings WHERE key = 'ticket_status_comment.watch_days'").get().value, '14');
  setting(db, 'ticket_status_comment.batch_max', 2);
  project(db, 'c11', 'example-org/c11-fixture');
  for (const n of [1103, 1101, 1102]) queue(db, 'c11', `BH-${n}`, { ticket_id: String(n) });
  let b = await dueOf(DB, 'c11');
  assert.deepEqual([b.due.map((d) => d.key), b.truncated], [['BH-1101', 'BH-1102'], true]);
  for (const d of b.due) await record(DB, 'c11', d);
  b = await dueOf(DB, 'c11');
  assert.deepEqual([b.due.map((d) => d.key), b.truncated], [['BH-1103'], false]);
  // The watch window is the settings row: a row older than it is not watched.
  await record(DB, 'c11', b.due[0]);
  setQueue(db, 'c11', 'BH-1103', { status: 'done', updated_at: ago(15 * 1440) });
  db.prepare("UPDATE ticket_status_comments SET updated_at = ? WHERE ticket_key = 'BH-1103'").run(ago(15 * 1440));
  b = await dueOf(DB, 'c11');
  assert.deepEqual(b.due.map((d) => d.key), [], 'past ticket_status_comment.watch_days (14): not watched');
  setting(db, 'ticket_status_comment.watch_days', 30);
  b = await dueOf(DB, 'c11');
  assert.deepEqual(b.due.map((d) => [d.key, d.state]), [['BH-1103', 'stopped']], 'a wider window watches it again');
});

test('C12 the watch and recent sets read newest first: a scan cut drops the oldest, never today\'s change', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  setting(db, 'ticket_status.stuck_scan_limit', 2);
  project(db, 'c12', 'example-org/c12-fixture');
  // (c): five finished tickets with no comment row, finished 50..10 minutes ago.
  for (let i = 1; i <= 5; i++) {
    queue(db, 'c12', `BH-120${i}`, { ticket_id: `120${i}`, status: 'done', finished_at: ago(60 - i * 10), updated_at: ago(60 - i * 10) });
    job(db, 'c12', `BH-120${i}`, `build-c12-${i}`, { status: 'failed', created_at: ago(70), updated_at: ago(60 - i * 10), meta: { result: 'EXECUTE_EMPTY' } });
  }
  let b = await dueOf(DB, 'c12');
  assert.deepEqual(b.due.map((d) => d.key), ['BH-1204', 'BH-1205'], 'the two newest changes are read');
  assert.deepEqual([b.truncated, b.window_cut], [false, true], 'a window cut is not a batch cut');
  // (b): five watched comment rows written 50..10 minutes ago, each with a stale fingerprint.
  db.prepare("DELETE FROM build_queue WHERE project = 'c12'").run();
  for (let i = 1; i <= 5; i++) {
    db.prepare(`INSERT INTO ticket_status_comments (project, ticket_key, issue, comment_id, fingerprint, state, final, created_at, updated_at)
      VALUES ('c12', ?, ?, ?, '0000000000000000', 'stopped', 0, ?, ?)`).run(`BH-121${i}`, 1210 + i, 7120000 + i, ago(60 - i * 10), ago(60 - i * 10));
    queue(db, 'c12', `BH-121${i}`, { ticket_id: String(1210 + i), status: 'done', updated_at: ago(20 * 1440) });   // outside (c)'s window
  }
  b = await dueOf(DB, 'c12');
  assert.deepEqual(b.due.map((d) => [d.key, d.comment_id]), [['BH-1214', 7120004], ['BH-1215', 7120005]],
    'the two newest watched rows are read');
  assert.equal(b.window_cut, true);
});
