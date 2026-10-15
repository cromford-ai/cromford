// tests/lib/lane-runs-claim-prefer.bh-6885.mjs — BH-6885: the claim `prefer`
// order, the stats `run_p50` field, the settings seeds and the query plans of
// the claim and the run sample. Run by tests/lane-fleet-multistart.bh-6885-test.sh.
//
// Every case goes through the REAL jobs worker (worker/jobs/src/index.js,
// worker.fetch) on node:sqlite with the composed schema (jobsSchemaSql()), the
// worker clock pinned. Prints one `ok <id> ...` or `FAIL <id> ...` line per
// case; exit 1 on any FAIL, exit 3 when node:sqlite is missing.
//
//   S1      the four settings seeds: 60, 5, 60, 8
//   P1-P10  POST /api/lane-runs/claim {machine, prefer}
//   R1-R5   GET /api/lane-runs/stats?run_p50=1
//   E1-E3   EXPLAIN QUERY PLAN of CLAIM_SQL and RUN_SAMPLE_SQL on 20,000 rows
import { fileURLToPath } from 'node:url';

const EPOCH = 1791000000; // 2026-10-03T04:00:00Z
const clockMs = EPOCH * 1000;
const RealDate = Date;
class FixtureDate extends RealDate {
  constructor(...a) { if (a.length === 0) super(clockMs); else super(...a); }
  static now() { return clockMs; }
}
globalThis.Date = FixtureDate;

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
let DatabaseSync;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { process.exit(3); }
const worker = (await import(`${ROOT}worker/jobs/src/index.js`)).default;
const lr = await import(`${ROOT}worker/jobs/src/routes/lane-runs.js`);
const { d1 } = await import(`${ROOT}worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const { jobsSchemaSql } = await import(`${ROOT}worker/jobs/test/lib/jobs-schema.js`);

let fails = 0;
const ok = (id, msg) => console.log(`ok ${id} ${msg}`);
const bad = (id, msg) => { fails += 1; console.log(`FAIL ${id} ${msg}`); };
const check = (id, cond, msg, got) => (cond ? ok(id, msg) : bad(id, `${msg} (got ${JSON.stringify(got)})`));

const iso = (s) => new RealDate(s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (s) => iso(EPOCH - s);

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  return { db, env: { DB: d1(db), HARNESS_SECRET: 'fixture-harness-secret' } };
}
async function call(env, method, path, body) {
  const req = new Request(`http://jobs.fixture.invalid${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: 'Bearer fixture-harness-secret' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, env);
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}
function enqueue(db, lane, project, enqueuedAt, extra = {}) {
  const status = extra.status || 'queued';
  db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, claimed_by, claimed_at, lease_until, finished_at)
              VALUES (?,?,?,?,?,?,?,?,?)`).run(lane, project, '["bin/x.sh"]', enqueuedAt, status,
    extra.claimed_by ?? null, extra.claimed_at ?? null, extra.lease_until ?? null, extra.finished_at ?? null);
}
function setting(db, key, value) {
  db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(key, String(value));
}
const claim = (env, body) => call(env, 'POST', '/api/lane-runs/claim', body);
// The A/B fixture: B older than A, both queued in lane demo.
function ab(aAgo, bAgo) {
  const f = fresh();
  enqueue(f.db, 'demo', 'B', ago(bAgo));
  enqueue(f.db, 'demo', 'A', ago(aAgo));
  return f;
}

// ---- S1 ---------------------------------------------------------------------
{
  const { db } = fresh();
  const want = { 'lane_fleet.target_drain_s': '60', 'lane_fleet.max_starts_per_tick': '5',
    'lane_run.prefer_max_wait_s': '60', 'lane_run.clone_cache_n': '8' };
  const got = {};
  for (const k of Object.keys(want)) {
    const r = db.prepare('SELECT value FROM settings WHERE key=?').get(k);
    got[k] = r ? String(r.value) : null;
  }
  check('S1', JSON.stringify(got) === JSON.stringify(want), 'the four seeds are 60, 5, 60, 8', got);
}

// ---- P: claim order -----------------------------------------------------------
{
  const { env } = ab(10, 30);
  const r = await claim(env, { machine: 'm1', prefer: ['A'] });
  check('P1', r.status === 200 && r.body.project === 'A', 'prefer [A]: the newer preferred row A wins over the older B', r.body);
}
{
  const { db, env } = ab(10, 30);
  enqueue(db, 'demo', 'C', ago(20));
  const r = await claim(env, { machine: 'm1', prefer: ['A', 'C'] });
  check('P2', r.status === 200 && r.body.project === 'C', 'two preferred rows: the older preferred row C', r.body);
}
{
  const { env } = ab(10, 61);
  const r = await claim(env, { machine: 'm1', prefer: ['A'] });
  check('P3', r.status === 200 && r.body.project === 'B', 'B waited 61 s > 60: B wins', r.body);
}
{
  const { env } = ab(10, 30);
  const r = await claim(env, { machine: 'm1', prefer: [] });
  check('P4', r.status === 200 && r.body.project === 'B', 'prefer []: the oldest row B', r.body);
}
{
  const { env } = ab(10, 30);
  const r = await claim(env, { machine: 'm1', prefer: ['Z'] });
  check('P5', r.status === 200 && r.body.project === 'B', 'prefer [Z] (no row): the oldest row B', r.body);
}
{
  const { env } = ab(10, 60);
  const r = await claim(env, { machine: 'm1', prefer: ['A'] });
  check('P6', r.status === 200 && r.body.project === 'A', 'B waited exactly 60 s (equal is not over): A', r.body);
}
{
  const { db, env } = ab(10, 30);
  setting(db, 'lane_run.prefer_max_wait_s', '0');
  const r = await claim(env, { machine: 'm1', prefer: ['A'] });
  check('P7', r.status === 200 && r.body.project === 'B', 'prefer_max_wait_s=0 (affinity off): the oldest row B', r.body);
  const f2 = ab(10, 30);
  setting(f2.db, 'lane_run.prefer_max_wait_s', 'abc');
  const r2 = await claim(f2.env, { machine: 'm1', prefer: ['A'] });
  check('P7b', r2.status === 200 && r2.body.project === 'A', 'prefer_max_wait_s=abc: the default 60, so A', r2.body);
  const f3 = ab(10, 30);
  setting(f3.db, 'lane_run.prefer_max_wait_s', '20');
  const r3 = await claim(f3.env, { machine: 'm1', prefer: ['A'] });
  check('P7c', r3.status === 200 && r3.body.project === 'B', 'prefer_max_wait_s=20: B waited 30 s, so B', r3.body);
}
{
  // A claimed row of A with a live lease is never returned; an expired one is.
  const { db, env } = fresh();
  enqueue(db, 'demo', 'B', ago(30));
  enqueue(db, 'demo', 'A', ago(40), { status: 'claimed', claimed_by: 'm9', claimed_at: ago(5), lease_until: iso(EPOCH + 100) });
  const r = await claim(env, { machine: 'm1', prefer: ['A'] });
  check('P8', r.status === 200 && r.body.project === 'B', 'a live-lease claimed A row is not returned', r.body);
  const f2 = fresh();
  enqueue(f2.db, 'demo', 'B', ago(30));
  enqueue(f2.db, 'demo', 'A', ago(20), { status: 'claimed', claimed_by: 'm9', claimed_at: ago(200), lease_until: ago(1) });
  const r2 = await claim(f2.env, { machine: 'm1', prefer: ['A'] });
  check('P8b', r2.status === 200 && r2.body.project === 'A' && r2.body.attempts === 1,
    'an expired-lease A row is re-claimed through prefer', r2.body);
}
{
  const bads = [['a string', 'A'], ['65 entries', Array.from({ length: 65 }, (_, i) => `p${i}`)],
    ['an entry "a b"', ['A', 'a b']], ['a number', [1]], ['an object', { A: 1 }]];
  for (const [name, prefer] of bads) {
    const { db, env } = ab(10, 30);
    const r = await claim(env, { machine: 'm1', prefer });
    const n = db.prepare("SELECT COUNT(*) AS n FROM lane_runs WHERE status='queued'").get().n;
    check('P9', r.status === 400 && /prefer/.test(r.body.error) && Number(n) === 2, `prefer ${name}: 400, no row changes`, [r.status, r.body, n]);
  }
  const { env } = ab(10, 30);
  const r = await claim(env, { machine: 'm1', prefer: Array.from({ length: 64 }, (_, i) => (i === 63 ? 'A' : `p${i}`)) });
  check('P9b', r.status === 200 && r.body.project === 'A', '64 entries is accepted', r.body);
  const f2 = ab(10, 30);
  const r2 = await claim(f2.env, { machine: 'm1', prefer: null });
  check('P9c', r2.status === 200 && r2.body.project === 'B', 'prefer null: no prefer, the oldest row', r2.body);
}
{
  const { db, env } = fresh();
  enqueue(db, 'other', 'A', ago(10));
  enqueue(db, 'demo', 'B', ago(5));
  const r = await claim(env, { machine: 'm1', lanes: ['demo'], prefer: ['A'] });
  check('P10', r.status === 200 && r.body.lane === 'demo' && r.body.project === 'B', 'the lanes filter wins over prefer', r.body);
}

// ---- R: stats run_p50 -----------------------------------------------------------
{
  const { db, env } = fresh();
  enqueue(db, 'demo', 'q1', ago(10));
  for (const [i, run] of [[1, 10], [2, 50], [3, 30]]) {
    enqueue(db, 'demo', `d${i}`, ago(500), { status: 'done', claimed_at: ago(400), finished_at: iso(EPOCH - 400 + run) });
  }
  // A done row with no stamp is skipped, not a 0.
  enqueue(db, 'demo', 'd4', ago(500), { status: 'done', claimed_at: null, finished_at: ago(1) });
  enqueue(db, 'empty', 'q2', ago(10));
  enqueue(db, 'idle', 'd5', ago(500), { status: 'done', claimed_at: ago(400), finished_at: ago(300) });
  const r1 = await call(env, 'GET', '/api/lane-runs/stats');
  const l1 = (r1.body.lanes || []).find((l) => l.lane === 'demo');
  check('R1', r1.status === 200 && l1 && !('run_p50_s' in l1) && !('run_p50_truncated' in r1.body), 'no run_p50: no run_p50_s field', r1.body);
  const r2 = await call(env, 'GET', '/api/lane-runs/stats?run_p50=1');
  const by = Object.fromEntries((r2.body.lanes || []).map((l) => [l.lane, l]));
  check('R2', r2.status === 200 && by.demo && by.demo.run_p50_s === 30 && by.demo.run_p50_n === 3,
    'run_p50=1: runs 10, 30, 50 s -> run_p50_s 30, run_p50_n 3', by.demo);
  check('R3', by.empty && by.empty.run_p50_s === null && by.empty.run_p50_n === 0,
    'a queued lane with no done rows: run_p50_s null, n 0', by.empty);
  check('R3b', by.idle && !('run_p50_s' in by.idle) && r2.body.run_p50_truncated === false,
    'a lane with nothing queued gets no sample; truncated false', [by.idle, r2.body.run_p50_truncated]);
  const r4 = await call(env, 'GET', '/api/lane-runs/stats?run_p50=2');
  check('R4', r4.status === 400 && /run_p50/.test(r4.body.error), 'run_p50=2: 400', r4.body);
  const r4b = await call(env, 'GET', '/api/lane-runs/stats?lane=demo&run_p50=1');
  const ld = (r4b.body.lanes || [])[0];
  check('R4b', r4b.status === 200 && ld && ld.lane === 'demo' && ld.run_p50_s === 30, 'lane=demo&run_p50=1', r4b.body);
}
{
  // 51 queued lanes: the cap of 50 samples, the 51st lane has run_p50_s null.
  const { db, env } = fresh();
  for (let i = 0; i < 51; i += 1) {
    const lane = `l${String(i).padStart(2, '0')}`;
    enqueue(db, lane, 'q', ago(10));
    enqueue(db, lane, 'd', ago(500), { status: 'done', claimed_at: ago(400), finished_at: ago(380) });
  }
  enqueue(db, 'l50', 'q2', ago(10)); // l50 has 2 queued: it sorts first by queued desc.
  const r = await call(env, 'GET', '/api/lane-runs/stats?run_p50=1');
  const by = Object.fromEntries((r.body.lanes || []).map((l) => [l.lane, l]));
  check('R5', r.status === 200 && r.body.run_p50_truncated === true && by.l50.run_p50_s === 20
    && by.l49.run_p50_s === null && by.l49.run_p50_n === null && by.l00.run_p50_s === 20,
  '51 queued lanes: 50 sampled (queued desc, then lane), truncated true', [r.body.run_p50_truncated, by.l50, by.l49]);
}

// ---- E: query plans ---------------------------------------------------------
{
  const { db } = fresh();
  const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, claimed_at, finished_at)
                          VALUES (?,?,?,?,?,?,?)`);
  db.exec('BEGIN');
  for (let i = 0; i < 20000; i += 1) {
    const lane = `lane${i % 30}`;
    const queued = i % 50 === 0;
    ins.run(lane, `p${i}`, '["bin/x.sh"]', iso(EPOCH - 20000 + i), queued ? 'queued' : 'done',
      queued ? null : iso(EPOCH - 20000 + i), queued ? null : iso(EPOCH - 19990 + i));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, binds) => {
    try { return db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join(' | '); }
    catch (e) { return `ERROR ${e.message}`; }
  };
  const usesIndex = (p, idx) => p.includes(`USING INDEX ${idx}`) && !/SCAN lane_runs\b/.test(p);
  const now = iso(EPOCH);
  const p1 = plan(String(lr.CLAIM_SQL), ['m1', now, iso(EPOCH + 120), null, null, null]);
  check('E1', typeof lr.CLAIM_SQL === 'string' && usesIndex(p1, 'idx_lane_runs_claim'), 'CLAIM_SQL, prefer NULL: idx_lane_runs_claim, no SCAN lane_runs', p1);
  const p2 = plan(String(lr.CLAIM_SQL), ['m1', now, iso(EPOCH + 120), '["lane1"]', '["p100","p150"]', iso(EPOCH - 60)]);
  check('E2', usesIndex(p2, 'idx_lane_runs_claim'), 'CLAIM_SQL, prefer + cutoff + lanes: idx_lane_runs_claim, no SCAN lane_runs', p2);
  const p3 = plan(lr.RUN_SAMPLE_SQL || 'SELECT 1', ['lane1']);
  check('E3', typeof lr.RUN_SAMPLE_SQL === 'string' && usesIndex(p3, 'idx_lane_runs_lane') && !p3.includes('TEMP B-TREE'),
    'RUN_SAMPLE_SQL: idx_lane_runs_lane, no SCAN, no temp sort', p3);
}

process.exit(fails ? 1 : 0);
