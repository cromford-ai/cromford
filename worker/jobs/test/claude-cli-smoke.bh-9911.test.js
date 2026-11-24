// BH-9911: the claude_cli_smoke table behind POST and GET /api/claude-cli/smoke.
// The canary smoke (bin/claude-cli-smoke.sh) writes one row per step; the
// smoke itself (dedup) and bin/claude-cli-pin.sh promote read them back.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/).
//   R1 POST then GET round-trips box, version, step, ok, newest first
//   R2 a resend of the same rows inserts 0
//   R3 a bad step, version, ok, or more than 50 rows is 400, nothing written
//   R4 GET without box or version is 400
//   R5 limit is capped at 500 (and defaults to 100)
//   R6 no bearer is 401
//   R7 EXPLAIN QUERY PLAN of the GET on 20,000 seeded rows uses
//      idx_claude_cli_smoke_box_version_at, and the retention id read uses
//      idx_claude_cli_smoke_inserted_at; neither scans the table
//   R8 the settings knobs and the model route seed exist in the schema
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { RULES } from '#retention-rules';

const SECRET = 'tok-fixture-bh9911';
const NOW = Date.parse('2026-11-18T00:00:00Z');
const ago = (h) => new Date(NOW - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, { method = 'GET', body, bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const row = (over = {}) => ({
  box: 'small', version: '2.1.331', run_id: 'r1', step: 'stdin', ok: 1, rc: 0, ms: 1200, detail: 'OK', at: ago(2), ...over,
});
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM claude_cli_smoke').get().n;

test('R1 POST then GET round-trips the rows, newest first', async (t) => {
  const o = await fresh(t); if (!o) return;
  const rows = [row(), row({ step: 'late_stdin', ok: 0, rc: 1, detail: 'no stdin in 3 s' }),
    row({ run_id: 'r0', step: 'stdin', at: ago(30) }), row({ box: 'project-4', step: 'haiku' })];
  const p = await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body: { rows } });
  assert.equal(p.status, 200);
  assert.equal(p.body.inserted, 4);
  const g = await call(o.DB, '/api/claude-cli/smoke?box=small&version=2.1.331');
  assert.equal(g.status, 200);
  assert.equal(g.body.rows.length, 3);
  assert.equal(g.body.rows[2].run_id, 'r0');
  const late = g.body.rows.find((r) => r.step === 'late_stdin');
  assert.equal(late.ok, 0);
  assert.equal(late.version, '2.1.331');
  assert.equal(late.rc, 1);
  assert.equal(late.detail, 'no stdin in 3 s');
  assert.ok(g.body.rows.every((r) => r.box === 'small'));
});

test('R2 a resend of the same rows inserts 0', async (t) => {
  const o = await fresh(t); if (!o) return;
  const body = { rows: [row(), row({ step: 'haiku' })] };
  assert.equal((await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body })).body.inserted, 2);
  const again = await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body });
  assert.equal(again.status, 200);
  assert.equal(again.body.inserted, 0);
  assert.equal(count(o.db), 2);
});

test('R3 a bad row is 400 and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const bad of [row({ step: 'tea' }), row({ version: 'latest' }), row({ version: '2.1' }), row({ ok: '1 ' }),
    row({ ok: 2 }), row({ box: '' }), row({ run_id: '' }), row({ at: '' }), row({ detail: 'x'.repeat(501) })]) {
    const r = await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body: { rows: [row({ run_id: 'good' }), bad] } });
    assert.equal(r.status, 400, JSON.stringify(bad));
  }
  assert.equal((await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body: { rows: [] } })).status, 400);
  const many = Array.from({ length: 51 }, (_, i) => row({ run_id: `r${i}` }));
  assert.equal((await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body: { rows: many } })).status, 400);
  assert.equal(count(o.db), 0);
});

test('R4 GET needs box and version', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small')).status, 400);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?version=2.1.331')).status, 400);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small&version=latest')).status, 400);
});

test('R5 limit defaults to 100 and is capped at 500', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare(`INSERT INTO claude_cli_smoke (box, version, run_id, step, ok, at, inserted_at)
                            VALUES ('small','2.1.331',?, 'stdin', 1, ?, ?)`);
  for (let i = 0; i < 600; i++) ins.run(`r${i}`, ago(i / 10), ago(i / 10));
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small&version=2.1.331')).body.rows.length, 100);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small&version=2.1.331&limit=5000')).body.rows.length, 500);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small&version=2.1.331&limit=7')).body.rows.length, 7);
});

test('R6 no bearer is 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small&version=2.1.331', { bearer: false })).status, 401);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body: { rows: [row()] }, bearer: false })).status, 401);
});

test('R7 on 20,000 rows the GET and the retention read use their indexes, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const STEPS = ['stdin', 'late_stdin', 'tool_call', 'haiku', 'lane_tick', 'fail_classes'];
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO claude_cli_smoke (box, version, run_id, step, ok, rc, ms, detail, at, inserted_at)
                          VALUES (?,?,?,?,1,0,10,'',?,?)`);
  for (let i = 0; i < 20000; i++) {
    const at = ago(i % 2160);
    ins.run(`box-${i % 12}`, `2.1.${300 + (i % 40)}`, `run-${Math.floor(i / 6)}`, STEPS[i % 6], at, at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const get = plan(db, `SELECT box, version, run_id, step, ok, rc, ms, detail, at FROM claude_cli_smoke
                        WHERE box = ?1 AND version = ?2 ORDER BY at DESC LIMIT ?3`, 'box-1', '2.1.301', 200);
  assert.ok(get.some((l) => /idx_claude_cli_smoke_box_version_at/.test(l)), get.join('\n'));
  assert.deepEqual(fullScans(get, ['claude_cli_smoke']), []);
  const rule = RULES.find((r) => r.table === 'claude_cli_smoke');
  assert.ok(rule, 'no retention rule names claude_cli_smoke');
  assert.equal(rule.key, 'retention.claude_cli_smoke.days');
  const ids = plan(db, rule.ids, ago(90 * 24), 500);
  assert.ok(ids.some((l) => /idx_claude_cli_smoke_inserted_at/.test(l)), ids.join('\n'));
  assert.deepEqual(fullScans(ids, ['claude_cli_smoke']), []);
});

test('R8 the knob rows and the claude-cli.smoke route are seeded', async (t) => {
  const o = await fresh(t); if (!o) return;
  const v = (k) => (o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(v('claude_cli.pin.enabled'), '0');
  assert.equal(v('claude_cli.pinned_version'), '2.1.330');
  assert.equal(v('claude_cli.canary_box'), 'box-small');
  assert.equal(v('claude_cli.canary_version'), undefined);
  assert.equal(v('retention.claude_cli_smoke.days'), '90');
  assert.equal(v('lane.claude-cli-smoke.llm_usd_cap_day'), '1');
  const smoke = o.db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role = 'bootstrap.smoke' AND position = 0").get();
  const route = o.db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role = 'claude-cli.smoke' AND position = 0").get();
  assert.ok(route, 'no claude-cli.smoke route');
  assert.equal(route.model, smoke.model);
  assert.equal(route.runner, 'claude');
});

// R9 (lead review of a14a874bd8c2): the route bounds are settings rows with the
// old literals as their seeded values and code fallbacks.
test('R9 the route bounds read their settings rows, with the literals as seed and fallback', async (t) => {
  const o = await fresh(t); if (!o) return;
  const v = (k) => (o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(v('claude_cli.smoke_post_rows_max'), '50');
  assert.equal(v('claude_cli.smoke_detail_max'), '500');
  assert.equal(v('claude_cli.smoke_list_limit_max'), '500');
  assert.equal(v('claude_cli.smoke_list_limit_default'), '100');
  assert.equal(v('claude_cli.smoke_step_grace_s'), '30');
  assert.equal(v('claude_cli.smoke_step_kill_after_s'), '10');
  const set = (k, val) => o.db.prepare('UPDATE settings SET value = ? WHERE key = ?').run(val, k);
  const post = (rows) => call(o.DB, '/api/claude-cli/smoke', { method: 'POST', body: { rows } });
  // rows max: 3 -> 4 rows is 400, 3 rows is 200.
  set('claude_cli.smoke_post_rows_max', '3');
  assert.equal((await post(Array.from({ length: 4 }, (_, i) => row({ run_id: `m${i}` })))).status, 400);
  assert.equal((await post(Array.from({ length: 3 }, (_, i) => row({ run_id: `m${i}` })))).status, 200);
  // detail max: 10 -> 11 chars is 400.
  set('claude_cli.smoke_detail_max', '10');
  assert.equal((await post([row({ run_id: 'd1', detail: 'x'.repeat(11) })])).status, 400);
  assert.equal((await post([row({ run_id: 'd2', detail: 'x'.repeat(10) })])).status, 200);
  // list limits.
  const ins = o.db.prepare(`INSERT INTO claude_cli_smoke (box, version, run_id, step, ok, at, inserted_at)
                            VALUES ('lim','2.1.331',?, 'stdin', 1, ?, ?)`);
  for (let i = 0; i < 40; i++) ins.run(`l${i}`, ago(i / 10), ago(i / 10));
  const n = async (q = '') => (await call(o.DB, `/api/claude-cli/smoke?box=lim&version=2.1.331${q}`)).body.rows.length;
  set('claude_cli.smoke_list_limit_default', '12');
  set('claude_cli.smoke_list_limit_max', '20');
  assert.equal(await n(), 12);
  assert.equal(await n('&limit=5000'), 20);
  assert.equal(await n('&limit=7'), 7);
  // An unusable row falls back to the code constant.
  set('claude_cli.smoke_list_limit_default', 'junk');
  set('claude_cli.smoke_list_limit_max', '0');
  assert.equal(await n(), 40);
  set('claude_cli.smoke_post_rows_max', '-1');
  assert.equal((await post(Array.from({ length: 51 }, (_, i) => row({ run_id: `f${i}` })))).status, 400);
  assert.equal((await post(Array.from({ length: 50 }, (_, i) => row({ run_id: `f${i}` })))).status, 200);
  // The three length caps (lead review of f0615e9ae0fa) are rows too: box,
  // run_id and at, on the POST and (box) on the GET.
  assert.equal(v('claude_cli.smoke_box_max_len'), '128');
  assert.equal(v('claude_cli.smoke_run_id_max_len'), '80');
  assert.equal(v('claude_cli.smoke_at_max_len'), '40');
  const at20 = ago(2); // 2026-11-17T22:00:00Z, 20 chars
  set('claude_cli.smoke_box_max_len', '5');
  assert.equal((await post([row({ box: 'small6', run_id: 'b1' })])).status, 400);
  assert.equal((await post([row({ box: 'small', run_id: 'b2' })])).status, 200);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small6&version=2.1.331')).status, 400);
  assert.equal((await call(o.DB, '/api/claude-cli/smoke?box=small&version=2.1.331')).status, 200);
  set('claude_cli.smoke_run_id_max_len', '4');
  assert.equal((await post([row({ run_id: 'abcde' })])).status, 400);
  assert.equal((await post([row({ run_id: 'abcd' })])).status, 200);
  set('claude_cli.smoke_at_max_len', '19');
  assert.equal((await post([row({ run_id: 'a1', at: at20 })])).status, 400);
  set('claude_cli.smoke_at_max_len', '20');
  assert.equal((await post([row({ run_id: 'a2', at: at20 })])).status, 200);
  // An unusable row falls back to 128 / 80 / 40.
  set('claude_cli.smoke_box_max_len', 'junk');
  set('claude_cli.smoke_run_id_max_len', '0');
  set('claude_cli.smoke_at_max_len', '-3');
  assert.equal((await post([row({ box: 'b'.repeat(129), run_id: 'x1' })])).status, 400);
  assert.equal((await post([row({ box: 'b'.repeat(128), run_id: 'x2' })])).status, 200);
  assert.equal((await call(o.DB, `/api/claude-cli/smoke?box=${'b'.repeat(129)}&version=2.1.331`)).status, 400);
  assert.equal((await call(o.DB, `/api/claude-cli/smoke?box=${'b'.repeat(128)}&version=2.1.331`)).status, 200);
  assert.equal((await post([row({ run_id: 'r'.repeat(81) })])).status, 400);
  assert.equal((await post([row({ run_id: 'r'.repeat(80) })])).status, 200);
  assert.equal((await post([row({ run_id: 'x3', at: at20 + 'y'.repeat(21) })])).status, 400);
  assert.equal((await post([row({ run_id: 'x4', at: at20 + 'y'.repeat(20) })])).status, 200);
});
