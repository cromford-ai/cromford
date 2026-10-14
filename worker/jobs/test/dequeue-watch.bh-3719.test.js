import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { CREATED_TABLES } from '../src/index.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3727 (BH-3719.1): the dequeue-watch ledger — dequeue_events and
// dequeue_actions, and the seven bearer routes over them. Every request goes
// through worker.fetch, so a case goes red if a route leaves ROUTES, not only
// if its handler changes. Every DB here starts BARE (no schema.sql), so each
// route's self-create is what makes its table.

const SCHEMA = jobsSchemaSql();
const SECRET = 's3cret';
const BASE = 'https://jobs.example/api/dequeue-watch';
const H1 = '0123456789abcdef0123456789abcdef01234567';
const H2 = 'fedcba9876543210fedcba9876543210fedcba98';
const H3 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

async function sqlite(t) {
  try {
    return (await import('node:sqlite')).DatabaseSync;
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

async function bare(t) {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return null;
  const db = new DatabaseSync(':memory:');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

function call(env, method, path = '', body, auth = true) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(BASE + path, init), env);
}
async function jcall(env, method, path, body) {
  const res = await call(env, method, path, body);
  return { status: res.status, body: await res.json() };
}

function tableExists(db, name) {
  return Boolean(db.prepare("SELECT 1 AS x FROM sqlite_master WHERE type='table' AND name=?").get(name));
}
function count(db, name) {
  return tableExists(db, name) ? db.prepare(`SELECT count(*) AS n FROM ${name}`).get().n : 0;
}

function shape(db, table) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((r) => ({ ...r }));
  const idx = db.prepare(`PRAGMA index_list('${table}')`).all()
    .map((r) => ({ name: r.name, unique: r.unique, origin: r.origin }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const idxCols = Object.fromEntries(idx.map((i) => [i.name, db.prepare(`PRAGMA index_info('${i.name}')`).all().map((r) => r.name)]));
  return { cols, idx, idxCols };
}
function pkCols(db, table) {
  return db.prepare(`PRAGMA table_info(${table})`).all().filter((r) => r.pk > 0).sort((a, b) => a.pk - b.pk).map((r) => r.name);
}

const EV = { repo: 'o/r', pr: 12, head: H1, run_id: '99', project: 'cromford' };
const AC = { repo: 'o/r', pr: 12, head: H1, class: 'flake', action: 'requeue', project: 'cromford' };

// Both tables exist on a bare DB once one GET per table has run.
async function ensureBoth(env) {
  assert.equal((await call(env, 'GET', '/events')).status, 200);
  assert.equal((await call(env, 'GET', '/actions')).status, 200);
}
function seedEvent(db, e) {
  db.prepare(`INSERT INTO dequeue_events (repo, pr, head, run_id, project, class, llm_fp, created_at, updated_at)
    VALUES (?, ?, ?, ?, 'p', ?, ?, ?, ?)`).run(e.repo || 'o/r', e.pr, e.head, e.run_id, e.class ?? null, e.llm_fp ?? null, e.at, e.at);
}
function seedAction(db, a) {
  db.prepare(`INSERT INTO dequeue_actions (repo, pr, head, class, action, status, project, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, 'p', ?, ?)`).run(a.repo || 'o/r', a.pr, a.head, a.class, a.action, a.status, a.at, a.upd || a.at);
}

test('SCH: schema.sql builds both tables with their PKs and indexes', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  assert.deepEqual(pkCols(db, 'dequeue_events'), ['repo', 'pr', 'head', 'run_id']);
  assert.deepEqual(pkCols(db, 'dequeue_actions'), ['repo', 'pr', 'head', 'class']);
  const ev = shape(db, 'dequeue_events');
  const ac = shape(db, 'dequeue_actions');
  assert.deepEqual(ev.idxCols.idx_dequeue_events_llm_fp, ['llm_fp']);
  assert.deepEqual(ev.idxCols.idx_dequeue_events_created, ['created_at']);
  assert.deepEqual(ac.idxCols.idx_dequeue_actions_repo_pr_class, ['repo', 'pr', 'class']);
  assert.deepEqual(ac.idxCols.idx_dequeue_actions_status_created, ['status', 'created_at']);
  assert.throws(() => db.prepare(`INSERT INTO dequeue_actions (repo, pr, head, class, action, project, created_at, updated_at)
    VALUES ('o/r', 1, 'h', 'flake', 'merge', 'p', 'x', 'x')`).run(), /CHECK/);
  assert.throws(() => db.prepare(`INSERT INTO dequeue_events (repo, pr, head, run_id, project, class, created_at, updated_at)
    VALUES ('o/r', 1, 'h', 'r', 'p', 'oops', 'x', 'x')`).run(), /CHECK/);
  db.close();
});

test('SCH-PARITY: CREATED_TABLES builds the same two tables as schema.sql', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  for (const table of ['dequeue_events', 'dequeue_actions']) {
    assert.ok(Array.isArray(CREATED_TABLES[table]), `CREATED_TABLES has a ${table} entry`);
    const fresh = new DatabaseSync(':memory:');
    for (const sql of CREATED_TABLES[table]) fresh.exec(sql);
    const want = shape(fromSchema, table);
    assert.ok(want.cols.length > 0, `schema.sql has ${table}`);
    assert.deepEqual(shape(fresh, table), want);
    fresh.close();
  }
  fromSchema.close();
});

test('E1: the first POST records the event, lowercased repo, members as JSON text', async (t) => {
  const h = await bare(t);
  if (!h) return;
  const r = await jcall(h.env, 'POST', '/events', {
    ...EV, repo: 'O/R', extra: { run_url: 'https://x/1', members: [12, 13], draft: 0, batch_size: 2, dequeued_at: '2026-09-30T00:00:00Z', comment_id: 'c1' },
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.recorded, true);
  assert.equal(r.body.first, true);
  assert.equal(r.body.row.repo, 'o/r');
  assert.equal(r.body.row.members, '[12,13]');
  assert.equal(r.body.row.run_url, 'https://x/1');
  assert.equal(r.body.row.batch_size, 2);
  assert.equal(r.body.row.class, null);
  assert.equal(count(h.db, 'dequeue_events'), 1);
});

test('E2: the same key again is first:false and the first extras stand', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal((await jcall(h.env, 'POST', '/events', { ...EV, extra: { run_url: 'https://x/first' } })).body.first, true);
  const r = await jcall(h.env, 'POST', '/events', { ...EV, extra: { run_url: 'https://x/second' } });
  assert.equal(r.status, 200);
  assert.equal(r.body.recorded, true);
  assert.equal(r.body.first, false);
  assert.equal(r.body.row.run_url, 'https://x/first');
  assert.equal(count(h.db, 'dequeue_events'), 1);
});

test('E3: an unknown extra key, a bad member, and a long string are 400 with nothing written', async (t) => {
  const h = await bare(t);
  if (!h) return;
  for (const extra of [{ nope: 1 }, { members: [0] }, { members: 'x' }, { run_url: 'x'.repeat(513) }, { draft: 2 }, { batch_size: 0 }, []]) {
    const r = await jcall(h.env, 'POST', '/events', { ...EV, extra });
    assert.equal(r.status, 400, JSON.stringify(extra));
  }
  assert.equal(count(h.db, 'dequeue_events'), 0);
});

test('ES1: PUT events/state sets the listed fields', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await jcall(h.env, 'POST', '/events', EV);
  const r = await jcall(h.env, 'PUT', '/events/state', { repo: 'o/r', pr: 12, head: H1, run_id: '99', class: 'flake', rule_id: 'x', attribution: 'culprit' });
  assert.equal(r.status, 200);
  assert.equal(r.body.row.class, 'flake');
  assert.equal(r.body.row.rule_id, 'x');
  assert.equal(r.body.row.attribution, 'culprit');
  assert.equal(r.body.fail_lines_truncated, false);
  assert.equal(h.db.prepare('SELECT class FROM dequeue_events').get().class, 'flake');
});

test('ES2: 20 KB of fail_lines is stored at <= 8192 bytes, cut at a line boundary, and flagged', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await jcall(h.env, 'POST', '/events', EV);
  const line = 'FAIL: suite x — case y went red é\n';
  const big = line.repeat(Math.ceil(20480 / Buffer.byteLength(line)));
  const r = await jcall(h.env, 'PUT', '/events/state', { repo: 'o/r', pr: 12, head: H1, run_id: '99', fail_lines: big });
  assert.equal(r.status, 200);
  assert.equal(r.body.fail_lines_truncated, true);
  const stored = h.db.prepare('SELECT fail_lines FROM dequeue_events').get().fail_lines;
  assert.ok(Buffer.byteLength(stored) <= 8192, `stored ${Buffer.byteLength(stored)} bytes`);
  assert.ok(Buffer.byteLength(stored) > 8192 - Buffer.byteLength(line) - 1, 'the cut keeps every whole line that fits');
  assert.ok(big.startsWith(stored + '\n'), 'the cut ends at a line boundary');
  // One line longer than the cap: a byte cut on a UTF-8 boundary.
  const one = 'é'.repeat(5000);
  const r2 = await jcall(h.env, 'PUT', '/events/state', { repo: 'o/r', pr: 12, head: H1, run_id: '99', fail_lines: one });
  assert.equal(r2.body.fail_lines_truncated, true);
  const s2 = h.db.prepare('SELECT fail_lines FROM dequeue_events').get().fail_lines;
  assert.equal(s2, 'é'.repeat(4096));
});

test('ES3: PUT on an unknown key is 404, an unlisted field or no field is 400', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await jcall(h.env, 'POST', '/events', EV);
  const key = { repo: 'o/r', pr: 12, head: H1, run_id: '99' };
  assert.equal((await jcall(h.env, 'PUT', '/events/state', { ...key, run_id: '100', class: 'flake' })).status, 404);
  assert.equal((await jcall(h.env, 'PUT', '/events/state', { ...key, project: 'x' })).status, 400);
  assert.equal((await jcall(h.env, 'PUT', '/events/state', key)).status, 400);
  assert.equal((await jcall(h.env, 'PUT', '/events/state', { ...key, class: 'oops' })).status, 400);
  assert.equal((await jcall(h.env, 'PUT', '/events/state', { ...key, attribution: 'Not Ok' })).status, 400);
  assert.equal(h.db.prepare('SELECT class FROM dequeue_events').get().class, null);
});

test('EL1: 501 events list as 500 + truncated; llm_fp and since filter', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await ensureBoth(h.env);
  for (let i = 1; i <= 501; i++) {
    seedEvent(h.db, { pr: i, head: H1, run_id: 'r', at: `2026-09-${i <= 250 ? '10' : '20'}T00:00:00Z`, llm_fp: i === 7 ? 'fp7' : null });
  }
  let r = await jcall(h.env, 'GET', '/events');
  assert.equal(r.status, 200);
  assert.equal(r.body.rows.length, 500);
  assert.equal(r.body.truncated, true);
  r = await jcall(h.env, 'GET', '/events?limit=501');
  assert.equal(r.status, 400);
  r = await jcall(h.env, 'GET', '/events?llm_fp=fp7');
  assert.deepEqual(r.body.rows.map((x) => x.pr), [7]);
  assert.equal(r.body.truncated, false);
  r = await jcall(h.env, 'GET', '/events?since=2026-09-15T00:00:00Z');
  assert.equal(r.body.rows.length, 251);
  assert.equal(r.body.truncated, false);
  r = await jcall(h.env, 'GET', '/events?repo=o/r&pr=300');
  assert.deepEqual(r.body.rows.map((x) => x.pr), [300]);
  h.db.prepare('DELETE FROM dequeue_events WHERE pr = 501').run();
  r = await jcall(h.env, 'GET', '/events');
  assert.equal(r.body.rows.length, 500);
  assert.equal(r.body.truncated, false, 'exactly 500 rows is complete');
  assert.equal((await jcall(h.env, 'GET', '/events?since=yesterday')).status, 400);  // determinism: ok a malformed since, asserting only the 400; no window is read
});

test('AC1-AC3: one claim per (repo, pr, head, class); the loser gets the winner row', async (t) => {
  const h = await bare(t);
  if (!h) return;
  const a1 = await jcall(h.env, 'POST', '/actions/claim', AC);
  assert.equal(a1.status, 200);
  assert.equal(a1.body.claimed, true);
  assert.equal(a1.body.row.status, 'claimed');
  assert.equal(a1.body.row.action, 'requeue');
  const a2 = await jcall(h.env, 'POST', '/actions/claim', { ...AC, action: 'fix-round' });
  assert.equal(a2.status, 200);
  assert.equal(a2.body.claimed, false);
  assert.equal(a2.body.row.action, 'requeue');
  const a3 = await jcall(h.env, 'POST', '/actions/claim', { ...AC, class: 'rule-break', action: 'fix-round' });
  assert.equal(a3.body.claimed, true);
  assert.equal(count(h.db, 'dequeue_actions'), 2);
});

test('AS1-AS2: PUT actions/state sets status/ref/action; a missing row is 404, a bad status 400', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await jcall(h.env, 'POST', '/actions/claim', { ...AC, action: 'observe' });
  const key = { repo: 'o/r', pr: 12, head: H1, class: 'flake' };
  let r = await jcall(h.env, 'PUT', '/actions/state', { ...key, status: 'done', ref: 'pr#12', action: 'requeue' });
  assert.equal(r.status, 200);
  assert.equal(r.body.row.status, 'done');
  assert.equal(r.body.row.ref, 'pr#12');
  assert.equal(r.body.row.action, 'requeue');
  assert.equal(r.body.row.note, null);
  r = await jcall(h.env, 'PUT', '/actions/state', { ...key, status: 'failed', note: 'why' });
  assert.equal(r.body.row.ref, 'pr#12', 'an absent field is left alone');
  assert.equal(r.body.row.note, 'why');
  assert.equal((await jcall(h.env, 'PUT', '/actions/state', { ...key, class: 'bystander', status: 'done' })).status, 404);
  assert.equal((await jcall(h.env, 'PUT', '/actions/state', { ...key, status: 'ok' })).status, 400);
  assert.equal((await jcall(h.env, 'PUT', '/actions/state', { ...key, status: 'done', note: 'x'.repeat(501) })).status, 400);
  assert.equal((await jcall(h.env, 'PUT', '/actions/state', { ...key, status: 'done', action: 'merge' })).status, 400);
  assert.equal(h.db.prepare('SELECT status FROM dequeue_actions').get().status, 'failed');
});

test('AL1: actions list filters by action+status across repos', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await jcall(h.env, 'POST', '/actions/claim', { ...AC, action: 'main-red-wait' });
  await jcall(h.env, 'POST', '/actions/claim', { ...AC, repo: 'a/b', action: 'main-red-wait' });
  await jcall(h.env, 'POST', '/actions/claim', { ...AC, repo: 'c/d', action: 'hold' });
  await jcall(h.env, 'PUT', '/actions/state', { repo: 'a/b', pr: 12, head: H1, class: 'flake', status: 'waiting' });
  await jcall(h.env, 'PUT', '/actions/state', { repo: 'o/r', pr: 12, head: H1, class: 'flake', status: 'waiting' });
  const r = await jcall(h.env, 'GET', '/actions?action=main-red-wait&status=waiting');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows.map((x) => x.repo).sort(), ['a/b', 'o/r']);
  assert.equal(r.body.truncated, false);
  const r2 = await jcall(h.env, 'GET', `/actions?repo=c/d&head=${H1}&class=flake`);
  assert.deepEqual(r2.body.rows.map((x) => x.action), ['hold']);
  assert.equal((await jcall(h.env, 'GET', '/actions?status=ok')).status, 400);
  assert.equal((await jcall(h.env, 'GET', '/actions?head=xyz')).status, 400);
});

test('V1: a 39-char head and a non-hex head are 400 with no row', async (t) => {
  const h = await bare(t);
  if (!h) return;
  for (const head of [H1.slice(1), H1.slice(1) + 'g']) {
    assert.equal((await jcall(h.env, 'POST', '/events', { ...EV, head })).status, 400);
    assert.equal((await jcall(h.env, 'POST', '/actions/claim', { ...AC, head })).status, 400);
  }
  assert.equal(count(h.db, 'dequeue_events'), 0);
  assert.equal(count(h.db, 'dequeue_actions'), 0);
});

test('V2: a class, action or status outside the enums is 400 with no row', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal((await jcall(h.env, 'POST', '/actions/claim', { ...AC, class: 'oops' })).status, 400);
  assert.equal((await jcall(h.env, 'POST', '/actions/claim', { ...AC, action: 'merge' })).status, 400);
  assert.equal((await jcall(h.env, 'PUT', '/actions/state', { repo: 'o/r', pr: 12, head: H1, class: 'flake', status: 'ok' })).status, 400);
  assert.equal((await jcall(h.env, 'POST', '/actions/claim', { ...AC, pr: 0 })).status, 400);
  assert.equal((await jcall(h.env, 'POST', '/actions/claim', { ...AC, repo: 'no-slash' })).status, 400);
  assert.equal((await jcall(h.env, 'POST', '/events', { ...EV, run_id: 'a b' })).status, 400);
  assert.equal(count(h.db, 'dequeue_actions'), 0);
  assert.equal(count(h.db, 'dequeue_events'), 0);
});

test('R1: repo case folds at write and lookup; R1b: an uppercase head folds too', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal((await jcall(h.env, 'POST', '/events', { ...EV, repo: 'example-org/Cromford' })).body.first, true);
  const again = await jcall(h.env, 'POST', '/events', { ...EV, repo: 'example-org/cromford', head: H1.toUpperCase() });
  assert.equal(again.body.first, false);
  assert.equal(count(h.db, 'dequeue_events'), 1);
  const list = await jcall(h.env, 'GET', '/events?repo=example-org/cromford');
  assert.equal(list.body.rows.length, 1);
  const st = await jcall(h.env, 'PUT', '/events/state', { repo: 'example-org/cromford', pr: 12, head: H1.toUpperCase(), run_id: '99', class: 'flake' });
  assert.equal(st.status, 200);
  const c1 = await jcall(h.env, 'POST', '/actions/claim', { ...AC, repo: 'example-org/Cromford' });
  assert.equal(c1.body.claimed, true);
  const c2 = await jcall(h.env, 'POST', '/actions/claim', { ...AC, repo: 'example-org/cromford', head: H1.toUpperCase() });
  assert.equal(c2.body.claimed, false);
  assert.equal(count(h.db, 'dequeue_actions'), 1);
  const al = await jcall(h.env, 'GET', `/actions?repo=example-org/cromford&head=${H1.toUpperCase()}`);
  assert.equal(al.body.rows.length, 1);
  const set = await jcall(h.env, 'PUT', '/actions/state', { repo: 'example-org/Cromford', pr: 12, head: H1.toUpperCase(), class: 'flake', status: 'done' });
  assert.equal(set.status, 200);
});

test('S1: the summary counts over the window and the mean requeue time is hand-computed', async (t) => {
  const h = await bare(t);
  if (!h) return;
  await ensureBoth(h.env);
  seedEvent(h.db, { pr: 1, head: H1, run_id: 'a', class: 'flake', at: '2026-09-20T10:00:00Z' });
  seedEvent(h.db, { pr: 1, head: H1, run_id: 'b', class: 'flake', at: '2026-09-20T10:05:00Z' });
  seedEvent(h.db, { pr: 2, head: H2, run_id: 'a', at: '2026-09-20T11:00:00Z' });
  seedEvent(h.db, { pr: 9, head: H2, run_id: 'old', class: 'flake', at: '2026-09-10T11:00:00Z' });
  // requeue done, earliest event 10:00:00 -> 600 s
  seedAction(h.db, { pr: 1, head: H1, class: 'flake', action: 'requeue', status: 'done', at: '2026-09-20T10:01:00Z', upd: '2026-09-20T10:10:00Z' });
  // requeue done, no event row -> own created_at: 120 s
  seedAction(h.db, { pr: 3, head: H3, class: 'unclassified', action: 'requeue', status: 'done', at: '2026-09-20T12:00:00Z', upd: '2026-09-20T12:02:00Z' });
  seedAction(h.db, { pr: 4, head: H3, class: 'flake', action: 'requeue', status: 'claimed', at: '2026-09-20T12:00:00Z' });
  seedAction(h.db, { pr: 5, head: H3, class: 'rule-break', action: 'fix-round', status: 'claimed', at: '2026-09-20T12:00:00Z' });
  seedAction(h.db, { pr: 5, head: H3, class: 'semantic-test', action: 'fix-round', status: 'done', at: '2026-09-20T12:00:00Z' });
  seedAction(h.db, { pr: 5, head: H3, class: 'scanner-fp', action: 'fix-round', status: 'failed', at: '2026-09-20T12:00:00Z' });
  seedAction(h.db, { pr: 6, head: H3, class: 'main-red', action: 'hold', status: 'waiting', at: '2026-09-20T12:00:00Z' });
  seedAction(h.db, { pr: 7, head: H3, class: 'main-red', action: 'hold', status: 'waiting', at: '2026-09-10T12:00:00Z' });
  seedAction(h.db, { pr: 8, head: H3, class: 'flake', action: 'requeue', status: 'done', at: '2026-09-10T12:00:00Z', upd: '2026-09-10T15:00:00Z' });
  const r = await jcall(h.env, 'GET', '/summary?since=2026-09-15T00:00:00Z');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.by_class, { flake: 2, unset: 1 });
  assert.equal(r.body.requeues, 2);
  assert.equal(r.body.mean_requeue_s, 360);
  assert.deepEqual(r.body.fix_rounds, { claimed: 1, done: 1, failed: 1 });
  assert.equal(r.body.holds, 1);
  assert.equal(r.body.unowned_now, null);
  assert.ok('unowned_now' in r.body);
  assert.equal(r.body.since, '2026-09-15T00:00:00Z');
  assert.match(r.body.as_of, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
});

test('S2: no requeue rows is a null mean and zero counts; a bad since is 400; no since is a 24 h window', async (t) => {
  const h = await bare(t);
  if (!h) return;
  const r = await jcall(h.env, 'GET', '/summary?since=2026-09-15T00:00:00Z');
  assert.equal(r.status, 200);
  assert.equal(r.body.mean_requeue_s, null);
  assert.equal(r.body.requeues, 0);
  assert.deepEqual(r.body.by_class, {});
  assert.deepEqual(r.body.fix_rounds, { claimed: 0, done: 0, failed: 0 });
  assert.equal((await jcall(h.env, 'GET', '/summary?since=bad')).status, 400);  // determinism: ok a malformed since, asserting only the 400; no window is read
  const d = await jcall(h.env, 'GET', '/summary');
  assert.equal(d.status, 200);
  assert.equal(Date.parse(d.body.as_of) - Date.parse(d.body.since), 86400000);
});

test('U1: a bare DB self-creates both tables; a DB that throws answers 503 naming the table', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal(tableExists(h.db, 'dequeue_events'), false);
  assert.equal(tableExists(h.db, 'dequeue_actions'), false);
  assert.equal((await call(h.env, 'GET', '/summary')).status, 200);
  assert.equal(tableExists(h.db, 'dequeue_events'), true);
  assert.equal(tableExists(h.db, 'dequeue_actions'), true);
  const busy = { DB: { prepare() { throw new Error('SQLITE_BUSY: database is locked'); }, async batch() { return []; } }, HARNESS_SECRET: SECRET };
  const r = await jcall(busy, 'POST', '/events', EV);
  assert.equal(r.status, 503);
  assert.equal(r.body.error, 'dequeue_events unavailable');
  const r2 = await jcall(busy, 'POST', '/actions/claim', AC);
  assert.equal(r2.status, 503);
  assert.equal(r2.body.error, 'dequeue_actions unavailable');
});

test('AUTH: every route refuses a request with no bearer', async (t) => {
  const h = await bare(t);
  if (!h) return;
  for (const [m, p] of [['POST', '/events'], ['PUT', '/events/state'], ['GET', '/events'], ['POST', '/actions/claim'],
    ['PUT', '/actions/state'], ['GET', '/actions'], ['GET', '/summary']]) {
    const res = await call(h.env, m, p, m === 'GET' ? undefined : EV, false);
    assert.equal(res.status, 401, `${m} ${p}`);
  }
  assert.equal(tableExists(h.db, 'dequeue_events'), false);
});
