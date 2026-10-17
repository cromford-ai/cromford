// BH-6972 (BH-6546.2): the alert_decisions table behind POST/GET
// /api/alerts/decisions, its indexes, its retention rule and its seeds.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/), the landing-decisions.bh-6744 idiom.
//   D1 the table and its three indexes exist; a POST writes the rows
//   D2 POST 3 rows, then GET ?alert_id= (newest first), ?alert_ids= (newest per
//      id), ?component= (with truncated)
//   D3 every bad body or query is a 400 that writes nothing; no bearer is 401
//   D4 the routes are in the route table (route-table.d fragment)
//   D5 retention rule alert_decisions.age: dry run counts, a live run deletes
//   D6 EXPLAIN QUERY PLAN on 50,000 rows: every read uses its index
//   D7 the schema seeds the settings rows and the component-watch model routes
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh6972';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ROW = { alert_id: 'a-fixture-1', verdict: 'resolve', reason: 'the lane recovered', outcome: 'applied' };
const BODY = { run_id: 'cw-merge-conductor-20261016T120000Z', component: 'merge-conductor', decisions: [ROW] };

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
const post = (DB, body) => call(DB, '/api/alerts/decisions', { method: 'POST', body });
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM alert_decisions').get().n;
const seedRow = (db, r) => db.prepare(
  `INSERT INTO alert_decisions (alert_id, component, run_id, verdict, until, reason, title, outcome, issue, at)
   VALUES (?,?,?,?,?,?,?,?,?,?)`
).run(r.alert_id, r.component || 'merge-conductor', r.run_id || 'cw-seed', r.verdict || 'resolve', r.until || null,
  r.reason || 'seeded', r.title || null, r.outcome || 'applied', r.issue || null, r.at);

test('D1 the table and its three indexes exist; a POST writes one row per decision with the request time', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const ix = db.prepare("SELECT name FROM pragma_index_list('alert_decisions')").all().map((r) => r.name).sort();
  assert.deepEqual(ix, ['idx_alert_decisions_alert', 'idx_alert_decisions_at', 'idx_alert_decisions_component']);
  const cols = (n) => db.prepare(`SELECT name FROM pragma_index_info('${n}')`).all().map((r) => r.name);
  assert.deepEqual(cols('idx_alert_decisions_alert'), ['alert_id', 'at']);
  assert.deepEqual(cols('idx_alert_decisions_component'), ['component', 'at']);
  assert.deepEqual(cols('idx_alert_decisions_at'), ['at']);
  const res = await post(DB, {
    ...BODY,
    decisions: [
      ROW,
      { alert_id: 'a-fixture-2', verdict: 'park', until: '2099-10-17T12:00:00Z', reason: 'a known outage', outcome: 'applied' },
      { alert_id: 'a-fixture-3', verdict: 'ticket', title: 'Fix the probe', reason: 'a real defect', outcome: 'applied', issue: 7001 },
    ],
  });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.written, 3);
  const rows = db.prepare('SELECT * FROM alert_decisions ORDER BY id').all();
  assert.equal(rows.length, 3);
  assert.equal(rows[0].run_id, BODY.run_id);
  assert.equal(rows[0].component, 'merge-conductor');
  assert.equal(rows[1].until, '2099-10-17T12:00:00Z');
  assert.equal(rows[2].issue, 7001);
  assert.equal(rows[2].title, 'Fix the probe');
  assert.match(rows[0].at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(new Set(rows.map((r) => r.at)).size, 1, 'one request, one time');
});

test('D2 GET ?alert_id= newest first, ?alert_ids= the newest row per id, ?component= with truncated', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  seedRow(db, { alert_id: 'a1', verdict: 'park', until: ago(-1), at: ago(3) });
  seedRow(db, { alert_id: 'a1', verdict: 'ticket', title: 'x', outcome: 'deferred', at: ago(2) });
  seedRow(db, { alert_id: 'a1', verdict: 'resolve', outcome: 'failed:resolve-1', at: ago(1) });
  seedRow(db, { alert_id: 'a2', verdict: 'escalate', at: ago(2) });
  seedRow(db, { alert_id: 'a3', component: 'cost', verdict: 'resolve', at: ago(1) });
  // Two rows at one time: the higher id is the newer.
  seedRow(db, { alert_id: 'a2', verdict: 'resolve', outcome: 'noop', at: ago(0.5) });
  seedRow(db, { alert_id: 'a2', verdict: 'park', until: ago(-2), at: ago(0.5) });

  const one = await call(DB, '/api/alerts/decisions?alert_id=a1');
  assert.equal(one.status, 200, JSON.stringify(one.body));
  assert.deepEqual(one.body.decisions.map((r) => r.outcome), ['failed:resolve-1', 'deferred', 'applied']);
  assert.equal(one.body.truncated, false);
  const lim = await call(DB, '/api/alerts/decisions?alert_id=a1&limit=2');
  assert.equal(lim.body.decisions.length, 2);
  assert.equal(lim.body.truncated, true);

  const latest = await call(DB, '/api/alerts/decisions?alert_ids=a1,a2,a9');
  assert.equal(latest.status, 200, JSON.stringify(latest.body));
  const by = Object.fromEntries(latest.body.latest.map((r) => [r.alert_id, r]));
  assert.deepEqual(Object.keys(by).sort(), ['a1', 'a2']);
  assert.equal(by.a1.outcome, 'failed:resolve-1');
  assert.equal(by.a2.verdict, 'park', 'same at: the higher id wins');
  assert.equal(by.a2.until, ago(-2));

  const comp = await call(DB, '/api/alerts/decisions?component=merge-conductor&limit=5');
  assert.equal(comp.status, 200, JSON.stringify(comp.body));
  assert.equal(comp.body.decisions.length, 5);
  assert.equal(comp.body.truncated, true);
  assert.ok(comp.body.decisions.every((r) => r.component === 'merge-conductor'));
  assert.deepEqual(comp.body.decisions.slice(0, 2).map((r) => r.verdict), ['park', 'resolve']);
  const cost = await call(DB, '/api/alerts/decisions?component=cost');
  assert.deepEqual(cost.body.decisions.map((r) => r.alert_id), ['a3']);
  assert.equal(cost.body.truncated, false);

  // The round trip: what a POST writes, the reads give back.
  const res = await post(DB, { ...BODY, decisions: [{ ...ROW, alert_id: 'a9' }] });
  assert.equal(res.status, 200);
  const back = await call(DB, '/api/alerts/decisions?alert_ids=a9');
  assert.equal(back.body.latest.length, 1);
  assert.equal(back.body.latest[0].reason, ROW.reason);
  assert.equal(back.body.latest[0].run_id, BODY.run_id);
});

test('D3 a bad body or query is a 400 that writes nothing; no bearer is 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const many = Array.from({ length: 61 }, (_, i) => ({ ...ROW, alert_id: `a-${i}` }));
  const bad = [
    { decisions: many },
    { decisions: [] },
    { decisions: 'x' },
    { run_id: '' },
    { run_id: 'bad id with spaces' },
    { component: 'Merge Conductor' },
    { decisions: [{ ...ROW, verdict: 'close' }] },
    { decisions: [{ ...ROW, outcome: 'done' }] },
    { decisions: [{ ...ROW, outcome: 'failed:' }] },
    { decisions: [{ ...ROW, outcome: 'failed:Bad Why' }] },
    { decisions: [{ ...ROW, until: '2099-10-17T12:00:00Z' }] },
    { decisions: [{ ...ROW, verdict: 'park', until: 'tomorrow' }] },
    { decisions: [{ ...ROW, reason: '' }] },
    { decisions: [{ ...ROW, reason: 'x'.repeat(501) }] },
    { decisions: [{ ...ROW, title: 'x'.repeat(121) }] },
    { decisions: [{ ...ROW, issue: 0 }] },
    { decisions: [{ ...ROW, issue: '12' }] },
    { decisions: [{ ...ROW, alert_id: 'bad id' }] },
    // One bad row among good ones: nothing is written.
    { decisions: [ROW, { ...ROW, alert_id: 'a-2', verdict: 'nope' }] },
  ];
  for (const b of bad) {
    const res = await post(DB, { ...BODY, ...b });
    assert.equal(res.status, 400, `${JSON.stringify(b).slice(0, 120)}: ${JSON.stringify(res.body)}`);
    assert.equal(typeof res.body.error, 'string');
  }
  assert.equal(count(db), 0);
  // An invalid row keeps the raw verdict token the model gave.
  const inv = await post(DB, { ...BODY, decisions: [{ ...ROW, verdict: 'close', outcome: 'invalid' }] });
  assert.equal(inv.status, 200, JSON.stringify(inv.body));
  assert.equal(count(db), 1);
  const ids51 = Array.from({ length: 51 }, (_, i) => `a${i}`).join(',');
  for (const q of ['', '?alert_id=a1&component=cost', '?alert_id=a1&alert_ids=a1', `?alert_ids=${ids51}`,
    '?alert_ids=', '?alert_id=bad%20id', '?component=Bad', '?alert_id=a1&limit=0', '?alert_id=a1&limit=201', '?component=cost&limit=x']) {
    const res = await call(DB, `/api/alerts/decisions${q}`);
    assert.equal(res.status, 400, `${q}: ${JSON.stringify(res.body)}`);
  }
  assert.equal((await call(DB, '/api/alerts/decisions', { method: 'POST', body: BODY, bearer: false })).status, 401);
  assert.equal((await call(DB, '/api/alerts/decisions?alert_id=a1', { bearer: false })).status, 401);
  assert.equal(count(db), 1);
});

test('D4 the two routes are in the route table fragment', () => {
  const dir = new URL('./route-table.d/', import.meta.url);
  const f = readdirSync(dir).find((n) => n === 'bh-6972-alert-decisions.txt');
  assert.ok(f, 'route-table.d/bh-6972-alert-decisions.txt exists');
  const lines = readFileSync(new URL(f, dir), 'utf8').split('\n').filter((l) => l && !l.startsWith('#'));
  assert.deepEqual(lines, ['POST /api/alerts/decisions', 'GET /api/alerts/decisions']);
});

test('D5 retention alert_decisions.age: a dry run counts the rows past 90 days; a live run deletes them and keeps the rest', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const seed = db.prepare("SELECT value FROM settings WHERE key = 'retention.alert_decisions.days'").get();
  assert.equal(seed && seed.value, '90');
  seedRow(db, { alert_id: 'old1', at: ago(91) });
  seedRow(db, { alert_id: 'old2', at: ago(120) });
  seedRow(db, { alert_id: 'new1', at: ago(10) });
  const dry = await call(DB, '/api/retention/run', { method: 'POST', body: { dry_run: true } });
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  const dr = dry.body.rules.find((r) => r.rule === 'alert_decisions.age');
  assert.ok(dr, `the rule ran: ${dry.body.rules.map((r) => r.rule).join(',')}`);
  assert.equal(dr.counted, 2);
  assert.equal(dr.removed, 0);
  assert.equal(count(db), 3);
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run('test', ago(0));
  const live = await call(DB, '/api/retention/run', { method: 'POST', body: {} });
  const lr = live.body.rules.find((r) => r.rule === 'alert_decisions.age');
  assert.equal(lr.removed, 2);
  assert.equal(lr.error, null);
  assert.deepEqual(db.prepare('SELECT alert_id FROM alert_decisions').all().map((r) => r.alert_id), ['new1']);
  const audit = db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule = 'alert_decisions.age'").get().n;
  assert.equal(audit, 2, 'one retention_runs row per run');
});

test('D6 on 50,000 rows every alert_decisions read uses its index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const COMPS = ['merge-conductor', 'blocked-resolver', 'pool-builders', 'triage', 'deploy-train',
    'main-red-bisect', 'jobs-worker', 'console', 'cost', 'hub-health'];
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO alert_decisions (alert_id, component, run_id, verdict, until, reason, title, outcome, issue, at)
                          VALUES (?,?,?,?,NULL,'r',NULL,'applied',NULL,?)`);
  for (let i = 0; i < 50000; i++) ins.run(`al-${i % 5000}`, COMPS[i % 10], `cw-${i % 700}`, 'resolve', ago((i % 1200) / 10));
  db.exec('COMMIT');
  const log = [];
  const D = capturingD1(db, log);
  const ids = Array.from({ length: 50 }, (_, i) => `al-${i * 7}`).join(',');
  for (const q of [`alert_ids=${ids}`, 'alert_id=al-42', 'component=cost']) {
    const res = await worker.fetch(new Request(`https://jobs.test/api/alerts/decisions?${q}`, {
      headers: { authorization: `Bearer ${SECRET}` },
    }), { DB: D, HARNESS_SECRET: SECRET });
    assert.equal(res.status, 200, q);
  }
  const reads = log.filter((r) => /FROM alert_decisions/.test(r.sql));
  assert.equal(reads.length, 3, `the three GETs read alert_decisions (${log.map((r) => r.sql).join(' | ')})`);
  const want = ['idx_alert_decisions_alert', 'idx_alert_decisions_alert', 'idx_alert_decisions_component'];
  reads.forEach((r, i) => {
    const lines = plan(db, r.sql, ...r.binds);
    assert.deepEqual(fullScans(lines, ['alert_decisions']), [], lines.join(' | '));
    assert.ok(lines.some((l) => new RegExp(`USING (COVERING )?INDEX ${want[i]} \\((alert_id|component)=\\?`).test(l)), `${want[i]}: ${lines.join(' | ')}`);
  });
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'alert_decisions.age');
  assert.ok(r, 'the retention rule exists');
  assert.equal(r.table, 'alert_decisions');
  assert.equal(r.key, 'retention.alert_decisions.days');
  assert.equal(r.def, 90);
  const lines = plan(db, r.ids, ago(90), 500);
  assert.deepEqual(fullScans(lines, ['alert_decisions']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_alert_decisions_at \(at<\?\)/.test(l)), lines.join(' | '));
});

test('D7 the schema seeds the settings rows and the component-watch model routes (copies, no literal)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(val('component_watch.budget_usd'), '0.5');
  assert.equal(val('component_watch.max_tickets'), '2');
  assert.equal(val('component_watch.max_attempts'), '3');
  assert.equal(val('retention.alert_decisions.days'), '90');
  const rung = (role) => db.prepare(
    'SELECT model, runner FROM model_routes WHERE project IS NULL AND role = ? AND position = 0').get(role);
  const src = rung('review.trivial');
  assert.ok(src && src.runner === 'claude', 'review.trivial has a claude rung 0');
  assert.deepEqual({ ...rung('component-watch') }, { ...src });
  const stage = rung('stage.execute');
  assert.ok(stage, 'stage.execute has a rung 0');
  assert.deepEqual({ ...rung('stage.component-watch') }, { ...stage });
  const frag = readdirSync(new URL('../schema.d/', import.meta.url)).find((n) => /-bh-6972-alert-decisions\.sql$/.test(n));
  assert.ok(frag, 'the schema fragment exists');
  const text = readFileSync(new URL(`../schema.d/${frag}`, import.meta.url), 'utf8');
  assert.doesNotMatch(text, /claude-(opus|sonnet|haiku|fable)/);
});
