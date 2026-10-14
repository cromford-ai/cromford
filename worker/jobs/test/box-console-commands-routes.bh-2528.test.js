import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2654 (BH-2528.1) — the five `box_console_commands` routes, driven through
// worker.fetch against THE SQL THAT SHIPS (schema.sql in node:sqlite).
//
// Real SQLite because every guarantee here is a property of a statement: the
// create dedup is the PRIMARY KEY plus `ON CONFLICT DO NOTHING`, the claim is
// one conditional UPDATE that names the box, the result is a CAS on
// `status='claimed' AND box=?`, and expire flips queued rows in one statement.

const SECRET = 'test-secret';
const BASE = '/api/box-console-commands';
const SCHEMA = jobsSchemaSql();

const TEST_NOW = Date.now();   // determinism: ok the ONE anchor the aged fixtures are derived from
const ago = (s) => new Date(TEST_NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

const TYPES = ['run_triage', 'fetch_log', 'fetch_artifact', 'chat', 'update_company_map',
  'chat_proposal', 'post_proposal', 'kill_proposal', 'revise_proposal'];

async function fixture() {
  const opened = await openDb();
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  const call = (path, { method = 'POST', body, secret = SECRET } = {}) => {
    const req = new Request(`https://jobs.test${path}`, {
      method,
      headers: {
        ...(secret ? { authorization: `Bearer ${secret}` } : {}),
        'content-type': 'application/json',
      },
      ...(body === undefined || method === 'GET' ? {} : { body: JSON.stringify(body) }),
    });
    return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
      .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  };
  const row = (id) => db.prepare('SELECT * FROM box_console_commands WHERE command_id=?').get(id) ?? null;
  const count = () => db.prepare('SELECT COUNT(*) n FROM box_console_commands').get().n;
  const seed = (over = {}) => {
    const r = {
      command_id: 'seed', box: 'project-3', type: 'run_triage', project: null, payload: '{}',
      status: 'queued', ok: null, result: null, body: null, claimed_at: null, finished_at: null,
      actor: null, created_at: ago(60), updated_at: ago(60), ...over,
    };
    db.prepare(`INSERT INTO box_console_commands (command_id, box, type, project, payload, status, ok,
                  result, body, claimed_at, finished_at, actor, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(r.command_id, r.box, r.type, r.project, r.payload, r.status, r.ok, r.result, r.body,
           r.claimed_at, r.finished_at, r.actor, r.created_at, r.updated_at);
    return r.command_id;
  };
  const create = (over = {}) => call(BASE, {
    body: { command_id: 'c1', box: 'project-3', type: 'run_triage', project: 'project-3', payload: '{"a":1}', ...over },
  });
  return { db, call, row, count, seed, create };
}

// ── S0 / R0 / Neg ────────────────────────────────────────────────────────────

test('S0: schema.sql applies twice on a fresh DB without error', async () => {
  const opened = await openDb();
  assert.ok(opened);
  assert.doesNotThrow(() => { opened.db.exec(SCHEMA); opened.db.exec(SCHEMA); });
});

test('R0: no bearer → 401; #2518 prefix is not answered by this family', async () => {
  const f = await fixture();
  const a = await f.call(`${BASE}/x`, { method: 'GET', secret: null });
  assert.equal(a.status, 401);
  const n = await f.call('/api/box-commands/x', { method: 'GET' });
  assert.equal(n.status, 404);
  assert.equal(n.body.error, 'unknown endpoint');
});

// ── CREATE ───────────────────────────────────────────────────────────────────

test('C1-C3: create → 201 queued; same replay → 200 created:false; different → 409', async () => {
  const f = await fixture();
  const a = await f.create();
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.created, true);
  assert.equal(a.body.command.status, 'queued');
  const r = f.row('c1');
  assert.equal(r.status, 'queued');
  assert.equal(r.payload, '{"a":1}');
  assert.equal(r.project, 'project-3');
  assert.ok(r.created_at);

  const b = await f.create();
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.created, false);
  assert.equal(f.count(), 1);

  for (const over of [{ payload: '{"a":2}' }, { box: 'project-4' }, { type: 'chat' }, { project: 'other' }, { project: null }]) {
    const c = await f.create(over);
    assert.equal(c.status, 409, `${JSON.stringify(over)} → ${JSON.stringify(c.body)}`);
    assert.equal(c.body.refused, true);
    assert.equal(c.body.command.command_id, 'c1');
  }
  assert.equal(f.row('c1').payload, '{"a":1}', 'the stored payload is unchanged');
  assert.equal(f.row('c1').box, 'project-3');
  assert.equal(f.count(), 1);
});

test('C4: payload over 256 KiB → 413 with no row; exactly 256 KiB → 201; counted in UTF-8 bytes', async () => {
  const f = await fixture();
  const big = JSON.stringify('x'.repeat(299998));
  assert.equal(Buffer.byteLength(big), 300000);
  const a = await f.create({ command_id: 'big', payload: big });
  assert.equal(a.status, 413, JSON.stringify(a.body));
  assert.equal(a.body.max, 262144);
  assert.equal(a.body.bytes, 300000);
  assert.equal(f.row('big'), null);

  const exact = JSON.stringify('x'.repeat(262142));
  assert.equal(Buffer.byteLength(exact), 262144);
  const b = await f.create({ command_id: 'exact', payload: exact });
  assert.equal(b.status, 201, JSON.stringify(b.body && b.body.error));
  assert.equal(f.row('exact').payload, exact, 'stored whole, never sliced');

  // 'é' is 2 bytes: .length would say this fits.
  const multi = JSON.stringify('é'.repeat(131071) + 'xx');
  assert.ok(multi.length < 262144);
  assert.ok(Buffer.byteLength(multi) > 262144);
  const c = await f.create({ command_id: 'multi', payload: multi });
  assert.equal(c.status, 413);
  assert.equal(f.row('multi'), null);
});

test('C5: type whitelist is exact and case-sensitive', async () => {
  const f = await fixture();
  for (const type of ['run-lane', 'RUN_TRIAGE', '', undefined]) {
    const r = await f.create({ command_id: `bad-${type}`, type });
    assert.equal(r.status, 400, `type ${type}`);
  }
  for (const type of TYPES) {
    const r = await f.create({ command_id: `t-${type}`, type });
    assert.equal(r.status, 201, `type ${type}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(f.count(), TYPES.length);
});

test('C6: box, id, project and payload validation → 400 with no row', async () => {
  const f = await fixture();
  const cases = [
    { box: 'a/b' }, { box: '' }, { box: 'b'.repeat(65) },
    { payload: '{x' }, { payload: { a: 1 } }, { payload: 5 }, { payload: undefined },
    { project: 'a b' },
    { command_id: '' }, { command_id: 'a/b' }, { command_id: 'x'.repeat(129) }, { command_id: 7 },
  ];
  for (const over of cases) {
    const r = await f.create(over);
    assert.equal(r.status, 400, `${JSON.stringify(over)} → ${r.status} ${JSON.stringify(r.body)}`);
  }
  assert.equal(f.count(), 0);
  const blankProject = await f.create({ command_id: 'np', project: '' });
  assert.equal(blankProject.status, 201);
  assert.equal(f.row('np').project, null);
  const nonObject = await f.call(BASE, { body: [1, 2] });
  assert.equal(nonObject.status, 400);
});

// ── CLAIM ────────────────────────────────────────────────────────────────────

test('K1-K3: claim takes only this box\'s queued rows, oldest first; again → []', async () => {
  const f = await fixture();
  f.seed({ command_id: 'o2', box: 'project-3', created_at: ago(60) });
  f.seed({ command_id: 'o1', box: 'project-3', created_at: ago(120) });
  f.seed({ command_id: 'x1', box: 'project-4', created_at: ago(180) });
  f.seed({ command_id: 'y1', box: 'omy', created_at: ago(180) });

  const a = await f.call(`${BASE}/claim`, { body: { box: 'project-3', limit: 10 } });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.ok(Array.isArray(a.body), 'claim answers a bare array');
  assert.deepEqual(a.body.map((r) => r.command_id), ['o1', 'o2']);
  for (const r of a.body) {
    assert.equal(r.status, 'claimed');
    assert.equal(r.actor, 'project-3');
    assert.ok(r.claimed_at);
    for (const k of ['command_id', 'type', 'project', 'payload', 'created_at']) assert.ok(k in r, k);
  }
  assert.equal(f.row('o1').status, 'claimed');
  assert.equal(f.row('x1').status, 'queued', 'another box\'s row is untouched');
  assert.equal(f.row('y1').status, 'queued', 'a prefix box\'s row is untouched');

  const b = await f.call(`${BASE}/claim`, { body: { box: 'project-3', limit: 10 } });
  assert.equal(b.status, 200);
  assert.deepEqual(b.body, []);

  const c = await f.call(`${BASE}/claim`, { body: { box: 'omy', limit: 10 } });
  assert.deepEqual(c.body.map((r) => r.command_id), ['y1']);
  assert.equal(f.row('o1').actor, 'project-3');
});

test('K2b: box " project-3 " trims to project-3 (laneName)', async () => {
  const f = await fixture();
  f.seed({ command_id: 'o1', box: 'project-3' });
  const a = await f.call(`${BASE}/claim`, { body: { box: ' project-3 ', limit: 1 } });
  assert.deepEqual(a.body.map((r) => r.command_id), ['o1']);
});

test('K4: bad box or limit → 400, never clamped', async () => {
  const f = await fixture();
  f.seed({ command_id: 'o1', box: 'project-3' });
  for (const body of [{ box: '', limit: 1 }, { box: '   ', limit: 1 }, { limit: 1 },
    { box: 'project-3', limit: 0 }, { box: 'project-3', limit: 101 }, { box: 'project-3', limit: '5' },
    { box: 'project-3', limit: 1.5 }, { box: 'project-3' }]) {
    const r = await f.call(`${BASE}/claim`, { body });
    assert.equal(r.status, 400, JSON.stringify(body));
  }
  assert.equal(f.row('o1').status, 'queued');
});

test('K5: limit 1 on two queued rows takes the oldest only', async () => {
  const f = await fixture();
  f.seed({ command_id: 'b', box: 'project-3', created_at: ago(30) });
  f.seed({ command_id: 'a', box: 'project-3', created_at: ago(90) });
  const r = await f.call(`${BASE}/claim`, { body: { box: 'project-3', limit: 1 } });
  assert.deepEqual(r.body.map((x) => x.command_id), ['a']);
  assert.equal(f.row('b').status, 'queued');
});

// ── RESULT ───────────────────────────────────────────────────────────────────

test('R1-R2b: owner result → done / failed; identical repeat → 200 unchanged; different → 409', async () => {
  const f = await fixture();
  await f.create();
  await f.create({ command_id: 'c2' });
  const cl = await f.call(`${BASE}/claim`, { body: { box: 'project-3', limit: 10 } });
  assert.equal(cl.body.length, 2);

  const a = await f.call(`${BASE}/c1/result`, { body: { box: 'project-3', ok: 1, result: 'ok', body: 'tail' } });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.command.status, 'done');
  const r = f.row('c1');
  assert.equal(r.status, 'done');
  assert.equal(r.ok, 1);
  assert.equal(r.result, 'ok');
  assert.equal(r.body, 'tail');
  assert.ok(r.finished_at);

  const b = await f.call(`${BASE}/c2/result`, { body: { box: 'project-3', ok: false, result: 'boom', body: null } });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(f.row('c2').status, 'failed');
  assert.equal(f.row('c2').ok, 0);

  f.db.prepare("UPDATE box_console_commands SET finished_at='2000-01-01T00:00:00Z' WHERE command_id='c1'").run();
  const again = await f.call(`${BASE}/c1/result`, { body: { box: 'project-3', ok: true, result: 'ok', body: 'tail' } });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.unchanged, true);
  assert.equal(f.row('c1').finished_at, '2000-01-01T00:00:00Z', 'the repeat writes nothing');

  for (const over of [{ result: 'other' }, { ok: 0 }, { body: 'different' }, { box: 'project-4' }]) {
    const d = await f.call(`${BASE}/c1/result`, { body: { box: 'project-3', ok: 1, result: 'ok', body: 'tail', ...over } });
    assert.equal(d.status, 409, JSON.stringify(over));
    assert.equal(d.body.refused, true);
  }
  assert.equal(f.row('c1').result, 'ok');
  assert.equal(f.row('c1').ok, 1);
});

test('R3: another box cannot answer a claimed row', async () => {
  const f = await fixture();
  f.seed({ command_id: 'k', box: 'project-3', status: 'claimed', claimed_at: ago(5), actor: 'project-3' });
  const r = await f.call(`${BASE}/k/result`, { body: { box: 'project-4', ok: 1, result: 'x', body: null } });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.command.status, 'claimed');
  assert.equal(f.row('k').status, 'claimed');
  assert.equal(f.row('k').ok, null);
});

test('R4: queued / expired rows → 409; unknown id → 404', async () => {
  const f = await fixture();
  f.seed({ command_id: 'q', box: 'project-3', status: 'queued' });
  f.seed({ command_id: 'e', box: 'project-3', status: 'expired' });
  const body = { box: 'project-3', ok: 1, result: 'x', body: null };
  const q = await f.call(`${BASE}/q/result`, { body });
  assert.equal(q.status, 409);
  assert.equal(f.row('q').status, 'queued');
  const e = await f.call(`${BASE}/e/result`, { body });
  assert.equal(e.status, 409);
  assert.equal(f.row('e').status, 'expired');
  const n = await f.call(`${BASE}/nope/result`, { body });
  assert.equal(n.status, 404);
});

test('R5: result/body caps → 413; ok/body type checks → 400', async () => {
  const f = await fixture();
  f.seed({ command_id: 'k', box: 'project-3', status: 'claimed', claimed_at: ago(5), actor: 'project-3' });
  const base = { box: 'project-3', ok: 1, result: 'x', body: null };
  const a = await f.call(`${BASE}/k/result`, { body: { ...base, result: 'r'.repeat(1025) } });
  assert.equal(a.status, 413);
  const b = await f.call(`${BASE}/k/result`, { body: { ...base, body: 'b'.repeat(262145) } });
  assert.equal(b.status, 413);
  for (const over of [{ ok: '1' }, { ok: 2 }, { ok: undefined }, { body: 5 }, { result: 5 }, { box: 'a/b' }]) {
    const r = await f.call(`${BASE}/k/result`, { body: { ...base, ...over } });
    assert.equal(r.status, 400, JSON.stringify(over));
  }
  assert.equal(f.row('k').status, 'claimed');
  const bad = await f.call(`${BASE}/%E0%A4%A/result`, { body: base });
  assert.equal(bad.status, 400);
  const slash = await f.call(`${BASE}/a%2Fb/result`, { body: base });
  assert.equal(slash.status, 400);
});

// ── EXPIRE ───────────────────────────────────────────────────────────────────

test('E1-E3: expire flips only queued rows past TTL, once; stale claims are listed, never reset', async () => {
  const f = await fixture();
  f.seed({ command_id: 'old-q', status: 'queued', created_at: ago(400) });
  f.seed({ command_id: 'new-q', status: 'queued', created_at: ago(10) });
  f.seed({ command_id: 'mid-c', status: 'claimed', created_at: ago(500), claimed_at: ago(400), actor: 'project-3' });
  f.seed({ command_id: 'old-c', status: 'claimed', created_at: ago(800), claimed_at: ago(700), actor: 'project-3' });
  f.seed({ command_id: 'done', status: 'done', ok: 1, created_at: ago(900), finished_at: ago(850) });
  f.seed({ command_id: 'fail', status: 'failed', ok: 0, created_at: ago(900), finished_at: ago(850) });

  const a = await f.call(`${BASE}/expire`, { body: { ttl_s: 300 } });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.deepEqual(a.body.expired.map((r) => r.command_id), ['old-q']);
  assert.deepEqual(a.body.stale_claimed.map((r) => r.command_id), ['old-c']);
  assert.equal(a.body.stale_truncated, false);
  assert.equal(f.row('old-q').status, 'expired');
  assert.equal(f.row('new-q').status, 'queued');
  assert.equal(f.row('mid-c').status, 'claimed');
  assert.equal(f.row('old-c').status, 'claimed', 'a stale claim is never reset (at-most-once)');
  assert.equal(f.row('done').status, 'done');
  assert.equal(f.row('fail').status, 'failed');

  const b = await f.call(`${BASE}/expire`, { body: { ttl_s: 300 } });
  assert.deepEqual(b.body.expired, []);
  assert.deepEqual(b.body.stale_claimed.map((r) => r.command_id), ['old-c']);

  for (const body of [{ ttl_s: 0 }, { ttl_s: -5 }, {}, { ttl_s: '300' }, { ttl_s: 1.5 }]) {
    const r = await f.call(`${BASE}/expire`, { body });
    assert.equal(r.status, 400, JSON.stringify(body));
  }
});

test('E4: stale_claimed is bounded at 500 with stale_truncated', async () => {
  const f = await fixture();
  const ins = f.db.prepare(`INSERT INTO box_console_commands (command_id, box, type, payload, status,
    claimed_at, actor, created_at, updated_at) VALUES (?, 'project-3', 'chat', '{}', 'claimed', ?, 'project-3', ?, ?)`);
  for (let i = 0; i < 501; i++) ins.run(`s${i}`, ago(1000), ago(1100), ago(1000));
  const r = await f.call(`${BASE}/expire`, { body: { ttl_s: 300 } });
  assert.equal(r.status, 200);
  assert.equal(r.body.stale_claimed.length, 500);
  assert.equal(r.body.stale_truncated, true);
});

// ── GET ──────────────────────────────────────────────────────────────────────

test('G1-G3: GET /:id answers the row or 404; /claim as GET is the row route', async () => {
  const f = await fixture();
  await f.create();
  const a = await f.call(`${BASE}/c1`, { method: 'GET' });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.command.command_id, 'c1');
  assert.equal(a.body.command.status, 'queued');

  const b = await f.call(`${BASE}/probe-none`, { method: 'GET' });
  assert.equal(b.status, 404);
  assert.equal(b.body.error, 'no such console command');

  const c = await f.call(`${BASE}/claim`, { method: 'GET' });
  assert.equal(c.status, 404);
  assert.equal(c.body.error, 'no such console command');

  // A command literally named "claim" is a row like any other.
  const d = await f.create({ command_id: 'claim' });
  assert.equal(d.status, 201);
  const e = await f.call(`${BASE}/claim`, { method: 'GET' });
  assert.equal(e.status, 200);
  assert.equal(e.body.command.command_id, 'claim');

  const bad = await f.call(`${BASE}/%E0%A4%A`, { method: 'GET' });
  assert.equal(bad.status, 400);
});

test('schema not applied → 503, never a 404 or 200', async () => {
  const f = await fixture();
  f.db.exec('DROP TABLE box_console_commands');
  const a = await f.call(`${BASE}/c1`, { method: 'GET' });
  assert.equal(a.status, 503);
  assert.equal(a.body.error, 'box_console_commands schema not applied');
  const b = await f.call(`${BASE}/claim`, { body: { box: 'project-3', limit: 1 } });
  assert.equal(b.status, 503);
  const c = await f.create();
  assert.equal(c.status, 503);
});
