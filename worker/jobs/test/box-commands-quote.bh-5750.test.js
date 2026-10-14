import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5750 T1.5: per-type args, the price token and the stale-quote refusal,
// through the real worker.fetch on real SQLite. A quote is made the way the
// hub makes one: POST the quote type, the hub's box-ops lane claims it and
// posts its result detail. The detail strings are the ones bin/box-ops.sh
// records from bin/lib/box-ops-orgo.sh and bin/box-launch.sh output.

const SECRET = 'test-secret-fixture';
const OWNER = 'owner@example.com';
const OWNER2 = 'second@example.com';
const NOW_MS = Date.parse('2026-10-10T12:00:00Z');
const RESIZE_PLAN = 'PLAN cost +$12/mo (now $40/mo, after $52/mo); --apply needs --confirm-monthly-usd 12 | box-ops: verb=resize box=project-3 orgo=fixture-oid result=PLAN dry run';
const LAUNCH_PLAN = 'capacity: pool fits 4c/16gb/100gb (used 3 computers, 12 vCPU, 48 GB RAM) | box-launch: box=newbox orgo=- ip=- specs=4c/16gb/100gb usd_mo=40 smoke=PENDING';

async function open(t) {
  if (!t.__mocked) { t.mock.timers.enable({ apis: ['Date'], now: NOW_MS }); t.__mocked = true; }
  const env = await openDb();
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return env;
}
async function call(env, method, path, body) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
  }), { DB: env.DB, HARNESS_SECRET: SECRET, BOX_OPS_OWNERS: `${OWNER},${OWNER2}` });
  return { status: res.status, body: await res.json() };
}
const post = (env, body) => call(env, 'POST', '/api/box-commands', { box: 'hub', reason: 'grow', confirm: true, actor: OWNER, ...body });
const SPECS = { account: 'acct-a', vcpus: 8 };
const resize = (over = {}) => ({ type: 'orgo_resize', target: 'project-3', ...SPECS, ...over });
const launch = (over = {}) => ({ type: 'orgo_launch', target: 'newbox', account: 'acct-a', project: 'proj-x', vcpus: 4, mem_gb: 16, disk_gb: 100, ...over });

// POST the quote, claim it as the hub, post the result. Returns the quote id.
async function quote(env, body, { ok = true, detail = RESIZE_PLAN } = {}) {
  const q = await post(env, body);
  assert.equal(q.status, 201, JSON.stringify(q.body));
  const c = await call(env, 'POST', '/api/box-commands/claim', { claimer: 'hub-box', boxes: ['hub'] });
  assert.equal(c.body.command.id, q.body.id);
  const r = await call(env, 'POST', `/api/box-commands/${q.body.id}/result`, { claimer: 'hub-box', ok, detail });
  assert.equal(r.status, 200);
  return q.body.id;
}
const resizeQuote = (env, over = {}, opts) => quote(env, { type: 'orgo_resize_quote', target: 'project-3', ...SPECS, ...over }, opts);
const cmds = (db, type) => db.prepare('SELECT * FROM box_commands_v2 WHERE type=? ORDER BY id').all(type);
const refusals = (db) => db.prepare("SELECT outcome FROM hub_lease_changes WHERE action='box_command_refused' ORDER BY id").all().map((r) => r.outcome);

test('Q1: a costing type without a full token is 400 confirm_token_required, nothing queued', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  for (const tok of [{}, { quote_id: id }, { confirm_monthly_usd: '12' }, { quote_id: String(id), confirm_monthly_usd: '12' },
    { quote_id: id, confirm_monthly_usd: 12 }, { quote_id: id, confirm_monthly_usd: '12 ' }, { quote_id: id, confirm_monthly_usd: '1.234' },
    { quote_id: 0, confirm_monthly_usd: '12' }]) {
    const r = await post(env, resize(tok));
    assert.equal(r.status, 400, JSON.stringify(tok));
    assert.deepEqual(r.body, { error: 'confirm_token_required' });
  }
  for (const tok of [{}, { quote_id: id }]) assert.equal((await post(env, launch(tok))).status, 400);
  assert.equal(cmds(env.db, 'orgo_resize').length, 0);
});

test('Q2: a fresh ok quote with the same figure is 201; args carry the token; 12.00 matches 12', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  const r = await post(env, resize({ quote_id: id, confirm_monthly_usd: '12' }));
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.deepEqual(r.body.command.args, { account: 'acct-a', vcpus: 8, quote_id: id, confirm_monthly_usd: '12' });
  const env2 = await open(t); if (!env2) return;
  const id2 = await resizeQuote(env2);
  assert.equal((await post(env2, resize({ quote_id: id2, confirm_monthly_usd: '12.00' }))).status, 201);
});

test('Q3: another figure is 409 stale_quote with one refused:quote audit row', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  for (const fig of ['13', '0', '11.99']) {
    const r = await post(env, resize({ quote_id: id, confirm_monthly_usd: fig }));
    assert.equal(r.status, 409, fig);
    assert.deepEqual(r.body, { error: 'stale_quote' });
  }
  assert.deepEqual(refusals(env.db), ['refused:quote', 'refused:quote', 'refused:quote']);
  assert.equal(cmds(env.db, 'orgo_resize').length, 0);
});

test('Q4: a quote older than the TTL is stale (fallback 900 s; the settings row wins)', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  t.mock.timers.tick(900 * 1000);
  assert.equal((await post(env, resize({ quote_id: id, confirm_monthly_usd: '12', target: 'project-3' }))).status, 201, 'at 900 s it is fresh');
  const env2 = await open(t); if (!env2) return;
  const id2 = await resizeQuote(env2);
  t.mock.timers.tick(901 * 1000);
  assert.equal((await post(env2, resize({ quote_id: id2, confirm_monthly_usd: '12' }))).status, 409, 'at 901 s it is stale');
  env2.db.prepare("INSERT INTO settings (key, value, updated_at) VALUES ('box_ops_quote_ttl_s', '3600', '2026-10-10T00:00:00Z')").run();
  assert.equal((await post(env2, resize({ quote_id: id2, confirm_monthly_usd: '12' }))).status, 201, 'the settings row lengthens it');
});

test('Q5: a quote for other specs, account or target is stale', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  for (const over of [{ vcpus: 16 }, { mem_gb: 32 }, { account: 'acct-b' }, { target: 'project-4' }]) {
    const r = await post(env, resize({ quote_id: id, confirm_monthly_usd: '12', ...over }));
    assert.equal(r.status, 409, JSON.stringify(over));
  }
});

test('Q6: a failed quote is stale even when its detail holds a COST line', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env, {}, { ok: false, detail: 'COST: resize project-3 +$12/mo (now $40/mo, after $52/mo) | box-ops: verb=resize result=REFUSED' });
  assert.equal((await post(env, resize({ quote_id: id, confirm_monthly_usd: '12' }))).status, 409);
});

test('Q7: another owner cannot spend a quote someone else asked for', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  const r = await post(env, resize({ quote_id: id, confirm_monthly_usd: '12', actor: OWNER2 }));
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'stale_quote' });
});

test('Q8: an open resize with other args is 409 open_command_differs; the same args dedup', async (t) => {
  const env = await open(t); if (!env) return;
  const id = await resizeQuote(env);
  const id2 = await resizeQuote(env, { vcpus: 16 }, { detail: RESIZE_PLAN.replace(/12/g, '36') });
  const first = await post(env, resize({ quote_id: id, confirm_monthly_usd: '12' }));
  assert.equal(first.status, 201);
  const same = await post(env, resize({ quote_id: id, confirm_monthly_usd: '12' }));
  assert.equal(same.status, 200);
  assert.equal(same.body.deduped, true);
  const other = await post(env, resize({ vcpus: 16, quote_id: id2, confirm_monthly_usd: '36' }));
  assert.equal(other.status, 409);
  assert.deepEqual(other.body, { error: 'open_command_differs', id: first.body.id });
  assert.equal(cmds(env.db, 'orgo_resize').length, 1);
});

test('Q9: restart, stop, retire, the quotes and the Fly pool types need no token', async (t) => {
  const env = await open(t); if (!env) return;
  for (const body of [{ type: 'orgo_restart', target: 'project-3' }, { type: 'orgo_stop', target: 'project-3', account: 'acct-a' },
    { type: 'orgo_retire', target: 'project-3', to: 'project-4', ip: '192.0.2.10', delete: true },
    { type: 'orgo_resize_quote', target: 'project-3', ...SPECS }, { type: 'fly_pool_cap', target: 'proj-x', cap: 5 },
    { type: 'fly_onboard', target: 'proj-x' }]) {
    const r = await post(env, body);
    assert.equal(r.status, 201, `${body.type} ${JSON.stringify(r.body)}`);
  }
  const ret = cmds(env.db, 'orgo_retire')[0];
  const ra = JSON.parse(ret.args);
  assert.equal(ra.to, 'project-4');
  assert.equal(ra.ip, '192.0.2.10');
  assert.equal(ra.delete, true);
});

test('Q10: bad args are 400 and never clamped', async (t) => {
  const env = await open(t); if (!env) return;
  const bad = [
    { type: 'orgo_resize_quote', target: 'project-3', account: 'acct-a', vcpus: 0 },
    { type: 'orgo_resize_quote', target: 'project-3', account: 'acct-a', vcpus: '4' },
    { type: 'orgo_resize_quote', target: 'project-3', account: 'acct-a', vcpus: -1 },
    { type: 'orgo_resize_quote', target: 'project-3', account: 'acct-a', vcpus: 2.5 },
    { type: 'orgo_resize_quote', target: 'project-3', account: 'acct-a' },
    { type: 'orgo_resize_quote', target: 'project-3', vcpus: 4 },
    { type: 'orgo_restart', target: 'hub' },
    { type: 'orgo_restart', target: 'project-3;id' },
    { type: 'orgo_restart', target: 'project-3' },
    { type: 'orgo_restart', target: 'project-3', box: 'project-3-1' },
    { type: 'orgo_retire', target: 'project-3', delete: 'true' },
    { type: 'orgo_retire', target: 'project-3', ip: '192.0.2' },
    { type: 'orgo_retire', target: 'project-3', to: 'hub' },
    { type: 'orgo_retire', target: 'project-3', to: 'project-3' },
    { type: 'orgo_launch_quote', target: 'newbox', account: 'acct-a', project: 'proj-x', vcpus: 4, mem_gb: 16 },
    { type: 'orgo_launch_quote', target: 'newbox', account: 'acct-a', vcpus: 4, mem_gb: 16, disk_gb: 100 },
    { type: 'fly_pool_cap', target: 'proj-x', cap: 0 },
    { type: 'fly_pool_cap', target: 'proj-x', cap: -1 },
    { type: 'fly_pool_cap', target: 'proj-x', cap: '3' },
    { type: 'fly_pool_cap', target: 'proj-x' },
    { type: 'fly_onboard', target: 'proj-x', cap: 0 },
    { type: 'fly_onboard', target: 'a/b' },
  ];
  for (const b of bad) {
    const r = await post(env, b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal(env.db.prepare('SELECT count(*) AS c FROM box_commands_v2').get().c, 0);
});

test('Q11: the FIRST price line counts; a quote with no price line costs 0 (a shrink)', async (t) => {
  const env = await open(t); if (!env) return;
  const two = await resizeQuote(env, {}, { detail: 'COST: resize project-3 +$12/mo (now $40/mo) | COST: resize project-3 +$99/mo | box-ops: verb=resize' });
  assert.equal((await post(env, resize({ quote_id: two, confirm_monthly_usd: '99' }))).status, 409);
  assert.equal((await post(env, resize({ quote_id: two, confirm_monthly_usd: '12' }))).status, 201);
  const env2 = await open(t); if (!env2) return;
  const shrink = await resizeQuote(env2, { vcpus: 2 }, { detail: 'resize: project-3 8c/32gb/-gb -> 2c/32gb/-gb, delta $-18/mo | box-ops: verb=resize box=project-3 orgo=fixture-oid result=PLAN dry run' });
  assert.equal((await post(env2, resize({ vcpus: 2, quote_id: shrink, confirm_monthly_usd: '1' }))).status, 409);
  assert.equal((await post(env2, resize({ vcpus: 2, quote_id: shrink, confirm_monthly_usd: '0' }))).status, 201);
});

test('Q12: a launch is priced by usd_mo of its own launch quote; no usd_mo or a resize quote is stale', async (t) => {
  const env = await open(t); if (!env) return;
  const q = { type: 'orgo_launch_quote', target: 'newbox', account: 'acct-a', project: 'proj-x', vcpus: 4, mem_gb: 16, disk_gb: 100 };
  const id = await quote(env, q, { detail: LAUNCH_PLAN });
  assert.equal((await post(env, launch({ quote_id: id, confirm_monthly_usd: '41' }))).status, 409);
  const ok = await post(env, launch({ quote_id: id, confirm_monthly_usd: '40' }));
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal(ok.body.command.args.confirm_monthly_usd, '40');
  const env2 = await open(t); if (!env2) return;
  const none = await quote(env2, q, { detail: 'capacity: pool fits 4c/16gb/100gb' });
  assert.equal((await post(env2, launch({ quote_id: none, confirm_monthly_usd: '0' }))).status, 409, 'no usd_mo is no figure, never 0');
  const rq = await resizeQuote(env2, {}, { detail: 'usd_mo=40' });
  assert.equal((await post(env2, launch({ quote_id: rq, confirm_monthly_usd: '40' }))).status, 409, 'a quote of the wrong type');
  assert.equal((await post(env2, launch({ quote_id: 999, confirm_monthly_usd: '40' }))).status, 409, 'an unknown quote id');
});
