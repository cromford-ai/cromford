// BH-7710: POST /api/box-ssh (the hub lane bin/box-ssh-probe.sh writes one row
// per box) and GET /api/box-health (the MCP box_health and box_restart tools
// read it through /api/coord/box-health). Driven through the REAL worker.fetch
// on node:sqlite with the composed jobs schema.
//   R1-R5  the POST rule        R6 EXPLAIN QUERY PLAN with 200 rows
//   H1-H4  the GET join          X1-X2 the worker answer through the real MCP tools
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7710';
const OWNER = 'owner@fixture.test';
const SQL = await import('../src/routes/box-ssh.js').catch(() => ({}));
const POST_BODY = JSON.parse(readFileSync(new URL('./fixtures/box-ssh-post.bh-7710.json', import.meta.url), 'utf8'));
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, method, path, body, auth = true) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET, BOX_OPS_OWNERS: OWNER })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const post = (DB, b) => call(DB, 'POST', '/api/box-ssh', b);
const health = (DB) => call(DB, 'GET', '/api/box-health');
const rows = (db) => db.prepare('SELECT * FROM box_ssh_state ORDER BY box').all();
const clone = (v) => JSON.parse(JSON.stringify(v));

function seedRegistry(db, boxes) {
  const ins = db.prepare("INSERT INTO registry_boxes (box, box_id, tailnet_ip, updated_at) VALUES (?,?,?,'2026-10-20T00:00:00Z')");
  for (const [box, id, ip] of boxes) ins.run(box, id, ip);
}
const REGISTRY = [['watcher-alpha', 'alpha', '192.0.2.11'], ['watcher-bravo', 'bravo', '192.0.2.12'], ['watcher-hub', 'hub', null]];
function seedVm(db, { complete = 1, extra = [] } = {}) {
  const ins = db.prepare('INSERT INTO orgo_computers (orgo_id, name, account, status, seen_at, gone_at) VALUES (?,?,?,?,?,?)');
  ins.run('vm-a1', 'watcher-alpha', 'acct-fixture', 'running', '2026-10-20T13:00:00Z', null);
  ins.run('vm-b1', 'watcher-bravo', 'acct-fixture', 'running', '2026-10-20T13:00:00Z', null);
  ins.run('vm-b0', 'watcher-bravo', 'acct-fixture', 'stopped', '2026-10-01T00:00:00Z', '2026-10-02T00:00:00Z');
  for (const r of extra) ins.run(...r);
  db.prepare('INSERT INTO orgo_account_reads (account, read_at, ok, complete, detail) VALUES (?,?,?,?,?)')
    .run('acct-fixture', '2026-10-20T13:00:00Z', 1, complete, null);
}

test('R1 two good rows: 200 {written:2, rejected:0}; box-health lists both with the stored fields', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  const r = await post(o.DB, POST_BODY);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.written, 2);
  assert.equal(r.body.rejected, 0);
  const x = rows(o.db);
  assert.deepEqual(x.map((y) => y.box), ['watcher-alpha', 'watcher-bravo']);
  assert.equal(x[0].probe_rc, 0); assert.equal(x[1].probe_rc, 255);
  assert.match(x[0].probed_at, ISO_RE);
  assert.equal(x[0].last_ok_at, x[0].probed_at, 'rc 0 sets last_ok_at');
  assert.equal(x[1].last_ok_at, null, 'rc 255 on a first report leaves last_ok_at null');
  assert.equal(x[1].lane_fails, 4); assert.equal(x[1].lane_window_s, 900);
  assert.equal(x[1].lane_last_fail_at, '2026-10-20T13:20:00Z');
  assert.equal(x[1].tailnet_ip, '192.0.2.12');

  const h = await health(o.DB);
  assert.equal(h.status, 200, JSON.stringify(h.body));
  assert.deepEqual(h.body.boxes.map((b) => b.box), ['watcher-alpha', 'watcher-bravo', 'watcher-hub']);
  const bravo = h.body.boxes[1];
  assert.equal(bravo.box_id, 'bravo');
  assert.deepEqual(bravo.ssh, { rc: 255, probed_at: x[1].probed_at, last_ok_at: null });
  assert.deepEqual(bravo.lane_ssh_failures, { count: 4, window_s: 900, last_at: '2026-10-20T13:20:00Z' });
  assert.equal(h.body.boxes[2].ssh, null, 'a box with no row has ssh null');
  assert.deepEqual(h.body.partial, []);
  assert.match(h.body.as_of, ISO_RE);
});

test('R2 a bad row next to a good one: the bad one is counted in rejected, the good one written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = { rows: [
    { box: '../x', ip: null, rc: 0, lane_fails: 0, lane_window_s: 900, lane_last_fail_at: null },
    { box: 'watcher-alpha', ip: '192.0.2.11', rc: 300, lane_fails: 0, lane_window_s: 900, lane_last_fail_at: null },
    { box: 'watcher-alpha', ip: '192.0.2.11', rc: 0, lane_fails: -1, lane_window_s: 900, lane_last_fail_at: null },
    { box: 'watcher-alpha', ip: '192.0.2.11', rc: 0, lane_fails: 0, lane_window_s: 900, lane_last_fail_at: 'yesterday' },
    { box: 'watcher-bravo', ip: '192.0.2.12', rc: 255, lane_fails: 1, lane_window_s: 900, lane_last_fail_at: null },
    { box: 'watcher-bravo', ip: '192.0.2.12', rc: 0, lane_fails: 1, lane_window_s: 900, lane_last_fail_at: null },
  ] };
  const r = await post(o.DB, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.written, 1);
  assert.equal(r.body.rejected, 5, 'a box named twice: the second row is rejected');
  assert.deepEqual(rows(o.db).map((y) => y.box), ['watcher-bravo']);
  assert.equal(rows(o.db)[0].probe_rc, 255, 'the first row of the box is the one written');
});

test('R3 rc 0 then rc 255: last_ok_at keeps the rc 0 report time, probe_rc is 255', async (t) => {
  const o = await fresh(t); if (!o) return;
  const one = (rc) => ({ rows: [{ box: 'watcher-alpha', ip: '192.0.2.11', rc, lane_fails: 0, lane_window_s: 900, lane_last_fail_at: null }] });
  assert.equal((await post(o.DB, one(0))).status, 200);
  // Move the first report into the past, so a write that overwrites
  // last_ok_at with the new probed_at cannot pass by landing in the same second.
  o.db.prepare("UPDATE box_ssh_state SET probed_at='2026-10-20T01:00:00Z', last_ok_at='2026-10-20T01:00:00Z'").run();
  assert.equal((await post(o.DB, one(255))).status, 200);
  let [x] = rows(o.db);
  assert.equal(x.probe_rc, 255);
  assert.notEqual(x.probed_at, '2026-10-20T01:00:00Z');
  assert.equal(x.last_ok_at, '2026-10-20T01:00:00Z');
  assert.equal((await post(o.DB, one(0))).status, 200);
  [x] = rows(o.db);
  assert.equal(x.last_ok_at, x.probed_at, 'a new rc 0 moves last_ok_at');
});

test('R4 an empty list, 201 rows or no list: 400 and nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const row = (i) => ({ box: `box-${i}`, ip: null, rc: 0, lane_fails: 0, lane_window_s: 900, lane_last_fail_at: null });
  for (const body of [{ rows: [] }, { rows: Array.from({ length: 201 }, (_, i) => row(i)) }, {}, { rows: 'x' }]) {
    const r = await post(o.DB, body);
    assert.equal(r.status, 400, JSON.stringify(r.body));
  }
  assert.equal(rows(o.db).length, 0);
  const ok = await post(o.DB, { rows: Array.from({ length: 200 }, (_, i) => row(i)) });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.written, 200);
});

test('R5 no bearer: 401 on the POST and the GET', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await call(o.DB, 'POST', '/api/box-ssh', POST_BODY, false)).status, 401);
  assert.equal((await call(o.DB, 'GET', '/api/box-health', null, false)).status, 401);
  assert.equal(rows(o.db).length, 0);
});

test('R6 EXPLAIN QUERY PLAN with 200 rows: the upsert uses the PRIMARY KEY, the reads are bounded', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.ok(SQL.UPSERT_SQL && SQL.SSH_READ_SQL && SQL.REGISTRY_READ_SQL, 'box-ssh.js exports its SQL');
  const ins = o.db.prepare(SQL.UPSERT_SQL);
  for (let i = 0; i < 200; i++) ins.run(`box-${i}`, null, 0, '2026-10-20T00:00:00Z', 0, 900, null);
  assert.equal(rows(o.db).length, 200);
  const up = plan(o.db, SQL.UPSERT_SQL, 'box-1', null, 255, '2026-10-20T00:00:00Z', 0, 900, null);
  assert.deepEqual(fullScans(up, ['box_ssh_state']), [], up.join(' | '));
  const read = plan(o.db, SQL.SSH_READ_SQL);
  assert.ok(read.some((l) => /box_ssh_state/.test(l)), read.join(' | '));
  assert.deepEqual(fullScans(read, ['registry_boxes', 'orgo_computers', 'lane_ticks']), [], 'the ssh read touches no other table');
  assert.match(SQL.SSH_READ_SQL, /LIMIT \?1/);
  o.db.exec('ALTER TABLE registry_boxes ADD COLUMN role TEXT');  // ensureColumns adds it on a live read
  const reg = plan(o.db, SQL.REGISTRY_READ_SQL, 201);
  assert.ok(reg.every((l) => !/TEMP B-TREE/.test(l)), `registry read sorts on its key: ${reg.join(' | ')}`);
});

test('H1 box-health: VM matches by registry name, a restart template only for one live match, vm_complete', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  seedVm(o.db);
  const h = await health(o.DB);
  assert.equal(h.status, 200, JSON.stringify(h.body));
  assert.equal(h.body.vm_complete, true);
  const [alpha, bravo, hub] = h.body.boxes;
  assert.deepEqual(bravo.vm.live, [{ id: 'vm-b1', status: 'running', seen_at: '2026-10-20T13:00:00Z', account: 'acct-fixture' }]);
  assert.equal(bravo.vm.gone, 1);
  assert.deepEqual(bravo.restart, { box: 'hub', type: 'orgo_restart', target: 'bravo', account: 'acct-fixture' });
  assert.equal(alpha.restart.target, 'alpha');
  assert.deepEqual(hub.vm, { live: [], gone: 0 });
  assert.equal(hub.restart, null, 'the hub never gets a restart template');
  assert.equal(JSON.stringify(h.body).includes('raw_json'), false);

  // A second live VM with the same name: no template.
  o.db.prepare("INSERT INTO orgo_computers (orgo_id, name, account, status, seen_at) VALUES ('vm-b2','watcher-bravo','acct-fixture','running','2026-10-20T13:00:00Z')").run();
  const two = await health(o.DB);
  assert.equal(two.body.boxes[1].vm.live.length, 2);
  assert.equal(two.body.boxes[1].restart, null);
});

test('H2 an incomplete account read: vm_complete false; no account read at all: false', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  assert.equal((await health(o.DB)).body.vm_complete, false, 'no account read proves nothing');
  seedVm(o.db, { complete: 0 });
  assert.equal((await health(o.DB)).body.vm_complete, false);
});

test('H3 a failed sub-read is named in partial and its fields are null; no registry is a 503', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  seedVm(o.db);
  assert.equal((await post(o.DB, POST_BODY)).status, 200);
  o.db.exec('DROP TABLE box_ssh_state');
  let h = await health(o.DB);
  assert.equal(h.status, 200, JSON.stringify(h.body));
  assert.deepEqual(h.body.partial, ['ssh']);
  assert.ok(h.body.boxes.every((b) => b.ssh === null && b.lane_ssh_failures === null));
  assert.equal(h.body.boxes[1].vm.live.length, 1, 'the other reads still answer');
  o.db.exec('DROP TABLE orgo_computers');
  h = await health(o.DB);
  assert.deepEqual(h.body.partial, ['ssh', 'vm']);
  assert.equal(h.body.vm_complete, null);
  assert.ok(h.body.boxes.every((b) => b.vm === null && b.restart === null));
  o.db.exec('DROP TABLE registry_boxes');
  h = await health(o.DB);
  assert.equal(h.status, 503, JSON.stringify(h.body));
});

test('H4 last_beat_at is the newest lane tick of that box name', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  const tick = o.db.prepare("INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at) VALUES (?, '-', ?, ?, 'ran', ?)");
  tick.run('a', 'watcher-bravo', '2026-10-20T04:21:00Z', '2026-10-20T04:21:00Z');
  tick.run('b', 'watcher-bravo', '2026-10-20T04:00:00Z', '2026-10-20T04:00:00Z');
  const h = await health(o.DB);
  assert.equal(h.body.boxes[1].last_beat_at, '2026-10-20T04:21:00Z');
  assert.equal(h.body.boxes[0].last_beat_at, null);
});

// ---- X: the worker's own answer, through the real MCP tools ----
// consoleFetch stand-in: /api/coord/<rest> -> the worker's /api/<rest>, and a
// POST gets the actor the console proxy stamps. Same {ok,status,data|error}
// shape as mcp/lib/console.mjs.
function viaConsole(DB) {
  return async (cfg, method, path, body) => {
    const rest = path.replace(/^\/api\/coord\//, '/api/');
    const r = await call(DB, method, rest, method === 'GET' ? undefined : { ...body, actor: OWNER });
    if (r.status >= 200 && r.status < 300) return { ok: true, status: r.status, data: r.body };
    return { ok: false, status: r.status, error: `http_${r.status}${r.body?.error ? ': ' + r.body.error : ''}` };
  };
}
const mcp = await import('../../../mcp/lib/tools.mjs');
const registry = await mcp.loadTools(new URL('../../../mcp/tools/', import.meta.url));

test('X1 the worker answer through box_health: bravo (rc 255, VM running) is hung, alpha is ok', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  seedVm(o.db);
  const body = clone(POST_BODY);
  assert.equal((await post(o.DB, body)).status, 200);
  const ctx = { cfg: { url: 'http://console.invalid', token: 'tok-fixture-x1', secret: null }, consoleFetch: viaConsole(o.DB) };
  const r = await mcp.callTool(registry, 'box_health', {}, ctx);
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  const by = Object.fromEntries(r.structuredContent.boxes.map((b) => [b.box, b]));
  assert.equal(by['watcher-bravo'].state, 'hung');
  assert.equal(by['watcher-alpha'].state, 'ok');
  assert.equal(by['watcher-bravo'].vm.status, 'running');
  assert.equal(by['watcher-bravo'].lane_ssh_failures.count, 4);
  assert.deepEqual(r.structuredContent.hung, ['watcher-bravo']);
});

test('X2 box_restart on the worker: one box_commands row and one audit row for bravo; alpha refused, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRegistry(o.db, REGISTRY);
  seedVm(o.db);
  assert.equal((await post(o.DB, clone(POST_BODY))).status, 200);
  const ctx = { cfg: { url: 'http://console.invalid', token: 'tok-fixture-x2', secret: null }, consoleFetch: viaConsole(o.DB) };
  const cmds = () => o.db.prepare('SELECT box, type, target, args, requested_by FROM box_commands_v2 ORDER BY id').all();
  const audits = () => o.db.prepare("SELECT actor, outcome FROM hub_lease_changes WHERE action='box_command_request'").all();

  const no = await mcp.callTool(registry, 'box_restart', { box: 'watcher-alpha', confirm: true }, ctx);
  assert.equal(no.isError, true);
  assert.match(no.content[0].text, /^box_answered_ssh: \d+s ago$/);
  assert.equal(cmds().length, 0);

  const r = await mcp.callTool(registry, 'box_restart', { box: 'watcher-bravo', confirm: true }, ctx);
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  assert.equal(r.structuredContent.queued, true);
  assert.equal(r.structuredContent.deduped, false);
  const c = cmds();
  assert.equal(c.length, 1);
  assert.equal(c[0].box, 'hub'); assert.equal(c[0].type, 'orgo_restart'); assert.equal(c[0].target, 'bravo');
  assert.equal(JSON.parse(c[0].args).account, 'acct-fixture');
  assert.equal(c[0].requested_by, OWNER);
  const au = audits();
  assert.equal(au.length, 1);
  assert.equal(au[0].actor, OWNER);
  assert.equal(au[0].outcome, 'ok');
  assert.equal(r.structuredContent.id, o.db.prepare('SELECT id FROM box_commands_v2').get().id);
});
