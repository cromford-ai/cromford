import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-8744 (BH-7935.3): GET /api/onboarding/ready/<project>, the Ready
// screen's read, driven through the worker's REAL fetch handler against
// node:sqlite running the composed schema. Each test opens its own in-memory
// DB and seeds its own project names. prepare() and batch() are wrapped so
// every statement and every batch is counted; Date is mocked so the 300 s
// bucket is the test's choice.
//   A1 a seeded project: one batch of 3, 6 statements, the stored values
//   A2 an unknown project: 404, 3 statements, no probe row filed
//   A1d fly comes from the routing row, never from a pause_flags row
//   A3 another project's rows never answer for this one
//   A4 the facts states (pending, pass, stale, fail, unparseable, the knob)
//   A5 the bucket: one probe row per bucket; the knob and its fallback
//   A6 bad paths are 404 with 0 statements; no bearer is 401
//   A7 the tailnet IP never leaves the worker
//   A8 the probe filing fails: the history row still answers
//   E1 EXPLAIN QUERY PLAN at 10k probe rows: every read on an index
const SECRET = 'test-secret';
const T0 = Date.parse('2026-10-30T09:00:10Z');
const S0 = Math.floor(T0 / 1000);
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const pad10 = (n) => String(n).padStart(10, '0');
const keyAt = (s, b = 300) => `onb-ready-${pad10(Math.floor(s / b) * b)}`;
const iso = (s) => new Date(s * 1000).toISOString();
// The probe line bin/lib/hub-probes/ready-facts.sh prints (its suite F1 pins
// the same literal).
const ALL_TRUE = '{"vercel":true,"qa_account":true,"migration_token":true}';
const TAILNET = '192.0.2.44';

async function db(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.sql = [];
  o.batches = [];
  const inner = o.DB;
  o.DB = {
    ...inner,
    prepare: (sql) => {
      o.sql.push(sql);
      if (o.failInsert && /^\s*INSERT INTO hub_probe_requests/i.test(sql)) throw new Error('D1_ERROR: fixture insert failure');
      return inner.prepare(sql);
    },
    batch: (stmts) => { o.batches.push(stmts.length); return inner.batch(stmts); },
  };
  return o;
}

function at(t, ms) {
  mock.timers.reset();
  mock.timers.enable({ apis: ['Date'], now: ms });
  t.after(() => mock.timers.reset());
}

const get = (o, path, auth = true) => {
  const headers = auth ? { authorization: `Bearer ${SECRET}` } : {};
  return worker.fetch(new Request(`https://jobs.test${path}`, { headers }), { DB: o.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, text: await res.clone().text(), body: await res.json().catch(() => null) }));
};
const ready = (o, p) => get(o, `/api/onboarding/ready/${p}`);
const probeRows = (o) => o.db.prepare("SELECT * FROM hub_probe_requests WHERE probe='ready-facts' ORDER BY id").all();
const reset = (o) => { o.sql = []; o.batches = []; };

function seedProject(o, p, { repo = `example-org/${p}`, prod = `https://${p}.example`, box = null, tailnet = null } = {}) {
  o.db.prepare("INSERT INTO registry_projects (project, repo, prod, board_prefix, cron_offset, box, position, updated_at) VALUES (?, ?, ?, 'BH', 0, ?, 1, '2026-10-01T00:00:00Z')")
    .run(p, repo, prod, box);
  if (box) {
    o.db.prepare("INSERT OR REPLACE INTO registry_boxes (box, box_id, tailnet_ip, updated_at) VALUES (?, ?, ?, '2026-10-01T00:00:00Z')")
      .run(box, `id-${box}`, tailnet);
  }
}
const setSetting = (o, key, value) => o.db.prepare(
  "INSERT OR REPLACE INTO settings (key, value, actor, updated_at) VALUES (?, ?, 'test', '2026-10-01T00:00:00Z')").run(key, value);
const setRouting = (o, project, builder) => o.db.prepare(
  "INSERT OR REPLACE INTO routing (project, builder, pool_app, halted, updated_at) VALUES (?, ?, NULL, 0, '2026-10-01T00:00:00Z')").run(project, builder);
const setFlag = (o, name, active = 1) => o.db.prepare(
  "INSERT OR REPLACE INTO pause_flags (name, active, actor, updated_at) VALUES (?, ?, 'test', '2026-10-01T00:00:00Z')").run(name, active);
// A ready-facts row for project p, filed at second s, finished `doneAfter` s later.
function seedProbe(o, p, s, status, output = ALL_TRUE, { doneAfter = 5, bucket = 300 } = {}) {
  const args = JSON.stringify([p]);
  const finished = status === 'pass' || status === 'fail' ? iso(s + doneAfter) : null;
  o.db.prepare(`INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, status, requested_at, finished_at, output)
    VALUES ('onboarding', ?, 'ready-facts', ?, ?, ?, ?, ?, ?)`).run(keyAt(s, bucket), args, sha256(args), status, iso(s), finished, output);
}

test('(A1) a seeded project: one batch of 3 statements, 6 in all, the stored values', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'ra-a1', { repo: 'example-org/project-11', prod: 'https://x.example', box: 'ra-box', tailnet: TAILNET });
  setSetting(o, 'account.ra-a1', 'ra-label');
  setRouting(o, 'ra-a1', 'pool');
  seedProbe(o, 'ra-a1', S0 - 600, 'pass');
  at(t, T0);
  reset(o);
  const r = await ready(o, 'ra-a1');
  assert.equal(r.status, 200);
  assert.deepEqual(o.batches, [3], 'exactly one batch, of 3 statements');
  assert.equal(o.sql.length, 6, `6 statements, got:\n${o.sql.join('\n')}`);
  const b = r.body;
  assert.equal(b.project, 'ra-a1');
  assert.equal(b.repo, 'example-org/project-11');
  assert.equal(b.prod, 'https://x.example');
  assert.equal(b.box, 'ra-box');
  assert.equal(b.tailnet, true);
  assert.equal(b.account, 'ra-label');
  assert.equal(b.fly, true);
  assert.equal(b.facts.state, 'pass');
  assert.equal(b.facts.vercel, true);
  assert.equal(b.facts.qa_account, true);
  assert.equal(b.facts.migration_token, true);
  assert.equal(b.facts.checked_at, iso(S0 - 600 + 5));
  // The current bucket's row was filed for the hub.
  const rows = probeRows(o);
  assert.equal(rows.length, 2);
  assert.equal(rows[1].ticket_key, keyAt(S0));
  assert.equal(rows[1].args_json, '["ra-a1"]');
  assert.equal(rows[1].status, 'pending');
});

test('(A1b) no account row, no routing row, no box: null, false, null', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'ra-a1b', { prod: '-' });
  at(t, T0);
  const { body } = await ready(o, 'ra-a1b');
  assert.equal(body.account, null);
  assert.equal(body.fly, false);
  assert.equal(body.box, null);
  assert.equal(body.tailnet, false);
  assert.equal(body.prod, '-');
  assert.equal(body.facts.state, 'pending');
});

test('(A1c) a box with no tailnet IP is tailnet:false; a repo that is not owner/name is null', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'ra-a1c', { box: 'bare-box', tailnet: null, repo: 'not a repo' });
  at(t, T0);
  const { body } = await ready(o, 'ra-a1c');
  assert.equal(body.box, 'bare-box');
  assert.equal(body.tailnet, false);
  assert.equal(body.repo, null);
});

test('(A1d) fly comes from the routing row, never from a pause_flags row', async (t) => {
  const o = await db(t); if (!o) return;
  // An active pause_flags row named builder-fly-<p> alone is not Fly routing:
  // bin/flag.sh refuses to write that name, and routing.sh never reads it.
  seedProject(o, 'ra-flagonly', { prod: '-' });
  setFlag(o, 'builder-fly-ra-flagonly');
  at(t, T0);
  assert.equal((await ready(o, 'ra-flagonly')).body.fly, false, 'a pause_flags row alone is not connected');
  for (const [builder, fly] of [['fly1', true], ['pool', true], ['local', false], ['other', false]]) {
    const p = `ra-rt-${builder}`;
    seedProject(o, p, { prod: '-' });
    setRouting(o, p, builder);
    assert.equal((await ready(o, p)).body.fly, fly, `routing.builder=${builder}`);
  }
});

test('(A2) an unknown project: 404 unknown_project, 3 statements, 0 probe rows', async (t) => {
  const o = await db(t); if (!o) return;
  at(t, T0);
  reset(o);
  const r = await ready(o, 'nobody-here');
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'unknown_project');
  assert.equal(o.sql.length, 3);
  assert.deepEqual(o.batches, [3]);
  assert.equal(probeRows(o).length, 0);
});

test('(A3) another project\'s rows never answer for this one', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'ra-a3', { prod: 'https://ra.example', box: 'ra-box3', tailnet: TAILNET });
  seedProject(o, 'other-p', { prod: '-' });
  seedProject(o, 'third-p', { prod: '-' });
  setSetting(o, 'account.ra-a3', 'ra-label');
  setRouting(o, 'ra-a3', 'fly1');
  seedProbe(o, 'ra-a3', S0 - 600, 'pass');
  at(t, T0);
  const { body } = await ready(o, 'other-p');
  assert.equal(body.project, 'other-p');
  assert.equal(body.prod, '-');
  assert.equal(body.account, null);
  assert.equal(body.fly, false);
  assert.equal(body.box, null);
  assert.equal(body.tailnet, false);
  assert.equal(body.facts.state, 'pending', 'ra-a3\'s pass row is not other-p\'s');
  assert.equal(body.facts.vercel, undefined);
  const third = await ready(o, 'third-p');
  assert.equal(third.body.facts.state, 'pending');
});

test('(A4) the facts states', async (t) => {
  const cases = [
    ['no finished row', () => {}, { state: 'pending' }],
    ['a pending current row and a 30-min-old pass', (o, p) => { seedProbe(o, p, S0 - 1800, 'pass'); }, { state: 'pass', vercel: true }],
    ['a pass with false keys', (o, p) => { seedProbe(o, p, S0 - 1800, 'pass', '{"vercel":false,"qa_account":true,"migration_token":false}'); },
      { state: 'pass', vercel: false, qa_account: true, migration_token: false }],
    ['a 2-h-old pass only', (o, p) => { seedProbe(o, p, S0 - 6000, 'pass'); }, { state: 'stale' }],
    ['a pass older than twice the stale window', (o, p) => { seedProbe(o, p, S0 - 7500, 'pass'); }, { state: 'pending' }],
    ['a fail newer than a pass', (o, p) => { seedProbe(o, p, S0 - 1800, 'pass'); seedProbe(o, p, S0 - 900, 'fail', 'unreadable'); }, { state: 'fail' }],
    ['a pass newer than a fail', (o, p) => { seedProbe(o, p, S0 - 1800, 'fail', 'unreadable'); seedProbe(o, p, S0 - 900, 'pass'); }, { state: 'pass' }],
    ['a pass whose value is not a boolean', (o, p) => { seedProbe(o, p, S0 - 900, 'pass', '{"vercel":"yes","qa_account":true,"migration_token":true}'); }, { state: 'fail' }],
    ['a pass missing a key', (o, p) => { seedProbe(o, p, S0 - 900, 'pass', '{"vercel":true,"qa_account":true}'); }, { state: 'fail' }],
    ['a pass that is not JSON', (o, p) => { seedProbe(o, p, S0 - 900, 'pass', 'not json'); }, { state: 'fail' }],
    ['the current bucket already passed', (o, p) => { seedProbe(o, p, S0, 'pass', ALL_TRUE, { doneAfter: 0 }); }, { state: 'pass' }],
    ['a rejected row is not an answer', (o, p) => { seedProbe(o, p, S0 - 900, 'rejected', 'x'); }, { state: 'pending' }],
  ];
  for (const [name, seed, want] of cases) {
    const o = await db(t); if (!o) return;
    const p = `a4-${cases.findIndex((c) => c[0] === name)}`;
    seedProject(o, p);
    seed(o, p);
    at(t, T0);
    const { status, body } = await ready(o, p);
    assert.equal(status, 200, name);
    for (const [k, v] of Object.entries(want)) assert.equal(body.facts[k], v, `${name}: facts.${k}`);
    if (want.state !== 'pass') assert.equal(body.facts.vercel, undefined, `${name}: no booleans unless pass`);
  }
});

test('(A4b) onboarding.ready_stale_s = 600 makes a 15-min-old pass stale', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'a4b');
  setSetting(o, 'onboarding.ready_stale_s', '600');
  seedProbe(o, 'a4b', S0 - 900, 'pass');
  at(t, T0);
  assert.equal((await ready(o, 'a4b')).body.facts.state, 'stale');
});

test('(A5) one probe row per bucket; the bucket knob and its fallback', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'a5');
  at(t, T0);
  await ready(o, 'a5');
  await ready(o, 'a5');
  assert.equal(probeRows(o).length, 1, 'two GETs in one 300 s bucket share one row');
  at(t, T0 + 300 * 1000);
  await ready(o, 'a5');
  const rows = probeRows(o);
  assert.equal(rows.length, 2, 'the next bucket files a second row');
  assert.deepEqual(rows.map((r) => r.ticket_key), [keyAt(S0), keyAt(S0 + 300)]);

  setSetting(o, 'onboarding.ready_bucket_s', '60');
  at(t, T0 + 360 * 1000);
  await ready(o, 'a5');
  assert.equal(probeRows(o).at(-1).ticket_key, keyAt(S0 + 360, 60), 'a 60 s bucket');

  for (const bad of ['0', 'abc', '99999', '59', '']) {
    const o2 = await db(t); if (!o2) return;
    seedProject(o2, 'a5b');
    setSetting(o2, 'onboarding.ready_bucket_s', bad);
    at(t, T0);
    await ready(o2, 'a5b');
    assert.equal(probeRows(o2)[0].ticket_key, keyAt(S0, 300), `bucket knob '${bad}' falls back to 300`);
  }
});

test('(A5b) the knob seed rows exist with their defaults', async (t) => {
  const o = await db(t); if (!o) return;
  const v = (k) => o.db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(v('onboarding.ready_bucket_s'), '300');
  assert.equal(v('onboarding.ready_stale_s'), '3600');
});

test('(A6) bad paths are 404 with 0 statements; no bearer is 401', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'a6');
  at(t, T0);
  for (const p of ['/api/onboarding/ready/Realtor', '/api/onboarding/ready/a_b', '/api/onboarding/ready/',
    `/api/onboarding/ready/${'a'.repeat(20)}`, '/api/onboarding/ready/-x', '/api/onboarding/ready/a6/x',
    '/api/onboarding/ready?project=a6']) {
    reset(o);
    const r = await get(o, p);
    assert.equal(r.status, 404, p);
    assert.equal(o.sql.length, 0, `${p}: 0 statements`);
  }
  reset(o);
  const r = await get(o, '/api/onboarding/ready/a6', false);
  assert.equal(r.status, 401);
  assert.equal(o.sql.length, 0);
  assert.equal(probeRows(o).length, 0);
});

test('(A7) the tailnet IP is never in the answer', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'a7', { box: 'a7-box', tailnet: TAILNET });
  at(t, T0);
  const r = await ready(o, 'a7');
  assert.equal(r.body.tailnet, true);
  assert.ok(!r.text.includes(TAILNET), r.text);
});

test('(A8) the probe filing fails: 200 from the history row, or pending', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'a8');
  seedProject(o, 'a8b');
  seedProbe(o, 'a8', S0 - 900, 'pass');
  o.failInsert = true;
  at(t, T0);
  const r = await ready(o, 'a8');
  assert.equal(r.status, 200);
  assert.equal(r.body.facts.state, 'pass');
  const r2 = await ready(o, 'a8b');
  assert.equal(r2.status, 200);
  assert.equal(r2.body.facts.state, 'pending');
  assert.equal(probeRows(o).length, 1, 'nothing filed');
});

test('(A9) a D1 failure in the batch is a 503 and writes nothing', async (t) => {
  const o = await db(t); if (!o) return;
  seedProject(o, 'a9');
  o.DB.batch = async () => { throw new Error('D1_ERROR: fixture batch failure'); };
  at(t, T0);
  const r = await ready(o, 'a9');
  assert.equal(r.status, 503);
  assert.equal(probeRows(o).length, 0);
});

test('(E1) EXPLAIN QUERY PLAN at 10k probe rows: every read uses an index', async (t) => {
  const o = await db(t); if (!o) return;
  const ins = o.db.prepare(`INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, status, requested_at, finished_at, output)
    VALUES (?, ?, ?, ?, ?, 'pass', ?, ?, ?)`);
  o.db.exec('BEGIN');
  for (let i = 0; i < 10000; i++) {
    const p = `p${i % 20}`;
    const s = S0 - (i % 500) * 60;
    const args = JSON.stringify([p]);
    ins.run(i % 4 ? 'onboarding' : 'cromford', `onb-ready-${pad10(s)}-${i}`, i % 3 ? 'ready-facts' : 'repo-detect', args, sha256(args + i), iso(s), iso(s), ALL_TRUE);
  }
  const reg = o.db.prepare("INSERT INTO registry_projects (project, repo, prod, board_prefix, cron_offset, box, position, updated_at) VALUES (?, 'o/r', '-', 'X', 0, ?, 1, 'x')");
  const box = o.db.prepare("INSERT INTO registry_boxes (box, box_id, tailnet_ip, updated_at) VALUES (?, ?, NULL, 'x')");
  const set = o.db.prepare("INSERT OR IGNORE INTO settings (key, value, updated_at) VALUES (?, 'v', 'x')");
  const route = o.db.prepare("INSERT OR IGNORE INTO routing (project, builder, halted, updated_at) VALUES (?, 'pool', 0, 'x')");
  for (let i = 0; i < 2000; i++) {
    reg.run(`e1-${i}`, `box-${i % 50}`);
    if (i < 50) box.run(`box-${i}`, `id-${i}`);
    set.run(`account.e1-${i}`);
    route.run(`e1-${i}`);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  at(t, T0);
  reset(o);
  const r = await ready(o, 'e1-7');
  assert.equal(r.status, 200);
  const reads = o.sql.filter((s) => /^\s*SELECT/i.test(s));
  assert.equal(reads.length, 5, 'registry, settings, routing, the probe row, history');
  const planOf = (sql) => {
    const n = (sql.match(/\?\d+/g) || []).reduce((m, x) => Math.max(m, Number(x.slice(1))), 0);
    return o.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...Array.from({ length: n }, () => 'x')).map((x) => x.detail).join(' | ');
  };
  const plans = reads.map(planOf);
  for (const [i, p] of plans.entries()) {
    // A table read is a SEARCH on an index; a SCAN CONSTANT ROW is no table.
    assert.doesNotMatch(p.replace(/SCAN CONSTANT ROW/g, ''), /\bSCAN\b/, `read ${i} scans a table: ${p}\n${reads[i]}`);
  }
  const history = reads.find((s) => /ORDER BY finished_at/.test(s));
  assert.ok(history, 'the history read ran');
  assert.match(planOf(history), /USING INDEX sqlite_autoindex_hub_probe_requests_1/);
  assert.match(planOf(reads[0]), /SEARCH p USING INDEX sqlite_autoindex_registry_projects_1 \(project=\?\)/);
  assert.match(planOf(reads[0]), /SEARCH b USING INDEX sqlite_autoindex_registry_boxes_1 \(box=\?\)/);
  const routing = reads.find((s) => /FROM routing/.test(s));
  assert.ok(routing, 'the routing read ran');
  assert.match(planOf(routing), /SEARCH routing USING INDEX sqlite_autoindex_routing_1 \(project=\?\)/);
});
