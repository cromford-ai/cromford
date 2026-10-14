import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2304: GET /api/lanes/status attributes spend by the lane's REGISTERED
// cost stages, and `stats.cost_stage` may be an array.
//
// run-product calls bin/agent-call.sh as map/signals/ideate/synth, so its
// registry entry is `cost_stage: ["map","signals","ideate","synth"]`; the page
// compared `r.stage === st.cost_stage`, which owns nothing for an array. The
// gate (bin/lib/llm-gate.sh `_llm_lane_ids`) matches a stage inside the array,
// and its header says the two must attribute the same rows. These cases drive
// the real fetch handler over a real schema.sql database with cost_rows
// inserted as the fleet mirror writes them, against the real LANES_REGISTRY.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return { prepare: (sql) => make(sql, []), batch: async (s) => s.map((x) => exec(x._sql, x._binds)) };
}

// The route buckets spend by `ts >= <today's midnight>` off its own request
// clock, so freshD1 freezes that clock at NOW_MS and stamps every row with it:
// a wall-clock stamp would cross midnight between insert and read.
const NOW_MS = Date.parse('2026-09-25T12:00:00Z');

function freshD1(t, rows) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const ins = db.prepare(
    'INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, cost_usd, inserted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
  const now = new Date(NOW_MS).toISOString();
  rows.forEach(([stage, project, usd], i) => ins.run('hub', `h${i}`, i + 1, now, project, stage, usd, now));
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function status(env) {
  const res = await worker.fetch(new Request('https://jobs.test/api/lanes/status',
    { headers: { authorization: 'Bearer ' + SECRET } }), env);
  assert.equal(res.status, 200);
  return res.json();
}
const lane = (body, id) => body.lanes.find((l) => l.id === id);

test('W1: run-product owns every one of its six stages (prd/mockup via bin/draft-proposal.sh, BH-2489), and not the build `plan` stage', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t, [
    ['map', 'project-4', 1.5], ['synth', 'project-4', 2.25], ['plan', 'project-4', 100],
  ]);
  const rp = lane(await status(env), 'run-product');
  assert.ok(rp, 'no run-product lane on the page');
  assert.deepEqual(rp.stats.cost_stage, ['map', 'signals', 'ideate', 'synth', 'prd', 'mockup'],
    'the page does not echo the registered stages');
  assert.equal(rp.cost_attribution, 'lane');
  assert.equal(rp.cost_today, 3.75, 'map + synth spend is not run-product\'s, or a build plan row was counted');
  assert.equal(rp.runs_today, 2);
  assert.deepEqual(rp.cost_rows.map((r) => r.stage).sort(), ['map', 'synth']);
  db.close();
});

test('W2: postmerge-qa owns prodqa rows, and a build fix round is not postmerge-qa\'s', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t, [['prodqa', 'project-4', 0.8], ['fix', 'project-4', 40]]);
  const pq = lane(await status(env), 'postmerge-qa');
  assert.equal(pq.stats.cost_stage, 'prodqa');
  assert.equal(pq.cost_attribution, 'lane');
  assert.equal(pq.cost_today, 0.8);
  db.close();
});

test('W3: a lane sharing ANY one of its stages is shared, and says with whom', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t, [['execute', 'project-4', 5], ['review', 'project-4', 7]]);
  const body = await status(env);
  const br = lane(body, 'blocked-resolver');
  assert.deepEqual(br.stats.cost_stage, ['execute', 'review']);
  assert.equal(br.cost_attribution, 'shared');
  assert.equal(br.cost_today, null, 'a shared lane was handed a sum nobody can attribute');
  assert.ok(br.cost_shared_with.includes('fly-pool'), `shared_with: ${br.cost_shared_with}`);
  assert.ok(br.cost_shared_with.includes('review-prs'), `shared_with: ${br.cost_shared_with}`);
  // ...and the lanes on the other side see blocked-resolver as a sharer too.
  assert.ok(lane(body, 'fly-pool').cost_shared_with.includes('blocked-resolver'));
  assert.ok(lane(body, 'review-prs').cost_shared_with.includes('blocked-resolver'));
  assert.equal(lane(body, 'alert-triage').cost_attribution, 'lane');
  db.close();
});
