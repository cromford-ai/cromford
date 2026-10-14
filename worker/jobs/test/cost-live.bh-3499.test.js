import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3499 (BH-3481.2): live cost rows. A running session's meter POSTs its
// running total to /api/cost/live, keyed on (box, row_hash); GET answers what
// is still in flight, what went stale without settling, and how many sessions
// already have a final cost_rows row. Driven through the real worker.fetch on
// node:sqlite with the d1 shim from cost-rows-conflict-repair.bh-3220.
//
// One clock: every fixture age derives from NOW.

const SECRET = 'test-secret';
const NOW = Date.now(); // determinism: ok the single anchor; worker.fetch stamps t off the real clock, so every fixture age derives from this one read
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const SCHEMA = jobsSchemaSql();
const ROUTE_SRC = fileURLToPath(new URL('../src/routes/cost-live.js', import.meta.url));
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
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}
async function call(env, method, path, body, { auth = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = 'Bearer ' + SECRET;
  const res = await worker.fetch(new Request('https://jobs.test' + path, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const post = (env, body, o) => call(env, 'POST', '/api/cost/live', body, o);
const get = (env, qs = '', o) => call(env, 'GET', '/api/cost/live' + qs, undefined, o);

const lrow = (o = {}) => ({
  row_hash: 'h-' + (o.session_id || 's1'), session_id: 's1', run_id: 'run-1', ticket: 'BH-1',
  project: 'cromford', stage: 'execute', model: 'model-under-test',
  input_toks: 10, output_toks: 20, cache_read: 30, cache_write: 40, cost_usd: 1.0,
  unpriced: null, started_at: iso(NOW - 60_000), ...o,
});
const stored = (db) => db.prepare('SELECT * FROM cost_rows_live ORDER BY row_hash').all();
const count = (db) => db.prepare('SELECT COUNT(*) AS c FROM cost_rows_live').get().c;
// seed <db> <row> <updated_at-ms> — a live row written straight to the table,
// so an age can be set that the POST's server clock would never stamp.
function seed(db, r, updMs, box = 'hub') {
  const x = lrow(r);
  db.prepare(`INSERT INTO cost_rows_live (box,row_hash,session_id,run_id,ticket,project,stage,model,
    input_toks,output_toks,cache_read,cache_write,cost_usd,unpriced,started_at,updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(box, x.row_hash, x.session_id, x.run_id, x.ticket,
    x.project, x.stage, x.model, x.input_toks, x.output_toks, x.cache_read, x.cache_write,
    x.cost_usd, x.unpriced, x.started_at, iso(updMs));
}
function settle(db, session_id) {
  db.prepare(`INSERT INTO cost_rows (box,row_hash,line_no,ts,project,stage,cost_usd,session_id,inserted_at)
    VALUES ('hub',?,1,?,'cromford','execute',1,?,?)`).run('final-' + session_id, iso(NOW), session_id, iso(NOW));
}

const COLS = ['box', 'row_hash', 'session_id', 'run_id', 'ticket', 'project', 'stage', 'model',
  'input_toks', 'output_toks', 'cache_read', 'cache_write', 'cost_usd', 'unpriced', 'started_at', 'updated_at'];

test('L0 schema: cost_rows_live has the 16 columns, PK (box,row_hash), its indexes, and re-applies', { skip: !DatabaseSync }, () => {
  const { db } = fresh();
  const info = db.prepare('PRAGMA table_info(cost_rows_live)').all();
  assert.deepEqual(info.map((c) => c.name), COLS);
  assert.deepEqual(info.filter((c) => c.pk).sort((a, b) => a.pk - b.pk).map((c) => c.name), ['box', 'row_hash']);
  const live = db.prepare('PRAGMA index_list(cost_rows_live)').all().map((i) => i.name);
  assert.ok(live.includes('cost_rows_live_run'), live.join());
  assert.ok(live.includes('cost_rows_live_upd'), live.join());
  const cr = db.prepare('PRAGMA index_list(cost_rows)').all().map((i) => i.name);
  assert.ok(cr.includes('cost_rows_session'), cr.join());
  assert.doesNotThrow(() => db.exec(SCHEMA), 'a second apply of schema.sql must be a no-op');
});

test('L1 POST one valid row inserts it with a server updated_at', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await post(env, { box: 'hub', rows: [lrow({ updated_at: '1999-01-01T00:00:00Z' })] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.inserted, 1); assert.equal(r.body.updated, 0); assert.equal(r.body.unchanged, 0);
  assert.match(r.body.as_of, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const [s] = stored(db);
  const want = lrow();
  for (const k of ['row_hash', 'session_id', 'run_id', 'ticket', 'project', 'stage', 'model',
    'input_toks', 'output_toks', 'cache_read', 'cache_write', 'cost_usd', 'started_at']) assert.equal(s[k], want[k], k);
  assert.equal(s.box, 'hub');
  assert.match(s.updated_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'ISO, no millis');
  assert.notEqual(s.updated_at, '1999-01-01T00:00:00Z', 'the client updated_at is ignored');
});

test('L2 an identical re-POST is unchanged and a higher cost updates', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await post(env, { box: 'hub', rows: [lrow()] });
  const back = iso(NOW - 3600_000);
  db.prepare('UPDATE cost_rows_live SET updated_at=?').run(back);
  const b = await post(env, { box: 'hub', rows: [lrow()] });
  assert.equal(b.status, 200);
  assert.deepEqual([b.body.inserted, b.body.updated, b.body.unchanged], [0, 0, 1]);
  assert.equal(count(db), 1);
  assert.equal(stored(db)[0].updated_at, back, 'an unchanged row keeps its updated_at');
  const c = await post(env, { box: 'hub', rows: [lrow({ cost_usd: 1.5, output_toks: 99 })] });
  assert.deepEqual([c.body.inserted, c.body.updated, c.body.unchanged], [0, 1, 0]);
  assert.equal(stored(db)[0].cost_usd, 1.5);
  assert.equal(stored(db)[0].output_toks, 99);
  assert.notEqual(stored(db)[0].updated_at, back);
  // same row_hash on another box is its own row
  const d = await post(env, { box: 'other', rows: [lrow()] });
  assert.equal(d.body.inserted, 1);
  assert.equal(count(db), 2);
});

test('L3 testproj is dropped, invalid rows skipped, caps refuse', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const a = await post(env, { box: 'hub', rows: [lrow({ session_id: 'tp', project: 'testproj' }), lrow(), { row_hash: 'x' }] });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.inserted, 1);
  assert.deepEqual(stored(db).map((r) => r.session_id), ['s1']);
  const b = await post(env, { box: 'hub', rows: [lrow({ session_id: 'tp2', project: 'testproj' })] });
  assert.equal(b.status, 200);
  assert.deepEqual([b.body.inserted, b.body.updated, b.body.unchanged], [0, 0, 0]);
  assert.equal(count(db), 1);
  const c = await post(env, { box: 'hub', rows: [{ row_hash: 'nosess', cost_usd: 1 }] });
  assert.equal(c.status, 400);
  const many = Array.from({ length: 51 }, (_, i) => lrow({ session_id: 'm' + i }));
  const d = await post(env, { box: 'hub', rows: many });
  assert.equal(d.status, 400);
  assert.equal(count(db), 1, 'a refused batch writes nothing');
  assert.equal((await post(env, { rows: [lrow()] })).status, 400, 'box required');
  assert.equal((await post(env, { box: 'hub', rows: [] })).status, 400, 'rows required');
  // the 50-row cap is inclusive
  const fifty = Array.from({ length: 50 }, (_, i) => lrow({ session_id: 'f' + i }));
  const e = await post(env, { box: 'hub', rows: fifty });
  assert.equal(e.status, 200); assert.equal(e.body.inserted, 50);
  // duplicate row_hash in one request: last wins, counted once
  const f = await post(env, { box: 'dup', rows: [lrow({ cost_usd: 1 }), lrow({ cost_usd: 3 })] });
  assert.equal(f.body.inserted, 1);
  assert.equal(db.prepare("SELECT cost_usd FROM cost_rows_live WHERE box='dup'").get().cost_usd, 3);
});

async function monotonic(env, db) {
  await post(env, { box: 'hub', rows: [lrow({ cost_usd: 2.0 })] });
  const lower = await post(env, { box: 'hub', rows: [lrow({ cost_usd: 1.0, output_toks: 5 })] });
  const after = stored(db)[0].cost_usd;
  return { lower, after };
}

test('L4 a lower cost_usd never lowers the row; null is not zero', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const { lower, after } = await monotonic(env, db);
  assert.equal(after, 2.0);
  assert.equal(lower.body.unchanged, 1);
  assert.equal(lower.body.updated, 0);
  const n = fresh();
  await post(n.env, { box: 'hub', rows: [lrow({ cost_usd: null, unpriced: 'model' })] });
  const up = await post(n.env, { box: 'hub', rows: [lrow({ cost_usd: 1.5 })] });
  assert.equal(up.body.updated, 1);
  assert.equal(stored(n.db)[0].cost_usd, 1.5, 'unpriced becomes priced');
  const down = await post(n.env, { box: 'hub', rows: [lrow({ cost_usd: null })] });
  assert.equal(down.body.unchanged, 1);
  assert.equal(stored(n.db)[0].cost_usd, 1.5, 'a null push never lowers a priced row');
});

test('L4 mutation: with >= flipped to <= the monotonic guard goes red', { skip: !DatabaseSync }, async () => {
  const src = readFileSync(ROUTE_SRC, 'utf8');
  const needle = 'excluded.cost_usd >= cost_rows_live.cost_usd';
  assert.equal(src.split(needle).length, 2, 'the guard clause must appear exactly once');
  const dir = mkdtempSync(join(tmpdir(), 'cost-live-mut-'));
  try {
    const libUrl = new URL('../src/lib/', import.meta.url).href;
    const patched = src.replace(needle, 'excluded.cost_usd <= cost_rows_live.cost_usd')
      .replaceAll('"../lib/', JSON.stringify(libUrl).slice(0, -1));
    const f = join(dir, 'cost-live.js');
    writeFileSync(f, patched);
    const { routes } = await import(pathToFileURL(f).href);
    const h = routes.find(([m]) => m === 'POST')[2];
    const { db, env } = fresh();
    const p = async (body) => {
      const res = await h({ env, body, t: iso(NOW) });
      return { status: res.status, body: await res.json() };
    };
    await p({ box: 'hub', rows: [lrow({ cost_usd: 2.0 })] });
    await p({ box: 'hub', rows: [lrow({ cost_usd: 1.0, output_toks: 5 })] });
    assert.equal(stored(db)[0].cost_usd, 1.0, 'the mutant must lower the row, or L4 would not catch it');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('L5 a session with a final cost_rows row is settled and out of the in-flight sum', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await post(env, { box: 'hub', rows: [lrow({ session_id: 'A', cost_usd: 1.0 }), lrow({ session_id: 'B', cost_usd: 2.0 })] });
  let g = await get(env);
  assert.equal(g.body.in_flight_usd, 3);
  settle(db, 'B');
  g = await get(env);
  assert.equal(g.status, 200);
  assert.equal(g.body.in_flight_usd, 1);
  assert.equal(g.body.settled_sessions, 1);
  assert.equal(g.body.unsettled_usd, 0);
  const byS = Object.fromEntries(g.body.rows.map((r) => [r.session_id, r.state]));
  assert.deepEqual(byS, { A: 'in_flight', B: 'settled' });
});

test('L6 a stale unsettled row is unsettled_usd; stale_s moves it; unknown is null, nothing is 0', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const empty = await get(env);
  assert.deepEqual({ ...empty.body, as_of: undefined }, {
    rows: [], in_flight_usd: 0, unsettled_usd: 0, settled_sessions: 0, unpriced_rows: 0, truncated: false, as_of: undefined });
  seed(db, { session_id: 'old', cost_usd: 0.75 }, NOW - 3600_000);
  seed(db, { session_id: 'new', cost_usd: 0.25 }, NOW - 10_000);
  let g = await get(env);
  assert.equal(g.body.unsettled_usd, 0.75);
  assert.equal(g.body.in_flight_usd, 0.25);
  assert.equal(g.body.rows.find((r) => r.session_id === 'old').state, 'unsettled');
  g = await get(env, '?stale_s=7200');
  assert.equal(g.body.unsettled_usd, 0);
  assert.equal(g.body.in_flight_usd, 1);
  const n = fresh();
  seed(n.db, { session_id: 'u', cost_usd: null, unpriced: 'model' }, NOW - 10_000);
  g = await get(n.env);
  assert.equal(g.body.in_flight_usd, null, 'all in-flight rows unpriced -> null, never 0');
  assert.equal(g.body.unpriced_rows, 1);
  // junk params fall back, never 500
  g = await get(n.env, '?hours=abc&stale_s=-5');
  assert.equal(g.status, 200);
  assert.equal(g.body.in_flight_usd, null);
});

test('L7 bearer required; 500-row page is truncated but sums cover every row; filters narrow', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  assert.equal((await get(env, '', { auth: false })).status, 401);
  assert.equal((await post(env, { box: 'hub', rows: [lrow()] }, { auth: false })).status, 401);
  assert.equal(count(db), 0);
  db.exec('BEGIN');
  for (let i = 0; i < 501; i++) seed(db, { session_id: 'k' + i, cost_usd: 0.01, run_id: i === 0 ? 'run-x' : 'run-1', project: i < 2 ? 'p2' : 'cromford' }, NOW - 1000 - i);
  db.exec('COMMIT');
  const g = await get(env);
  assert.equal(g.body.rows.length, 500);
  assert.equal(g.body.truncated, true);
  assert.equal(g.body.in_flight_usd, 5.01, 'the sum is over all 501 rows, not the capped page');
  const r = await get(env, '?run_id=run-x');
  assert.equal(r.body.rows.length, 1); assert.equal(r.body.in_flight_usd, 0.01); assert.equal(r.body.truncated, false);
  const p = await get(env, '?project=p2');
  assert.equal(p.body.rows.length, 2); assert.equal(p.body.in_flight_usd, 0.02);
  // hours=abc falls back to 24: a 30h-old row is out, a 1h-old row is in
  const n = fresh();
  seed(n.db, { session_id: 'day2' }, NOW - 30 * 3600_000);
  seed(n.db, { session_id: 'hr1' }, NOW - 3600_000);
  const h = await get(n.env, '?hours=abc');
  assert.deepEqual(h.body.rows.map((x) => x.session_id), ['hr1']);
  const h48 = await get(n.env, '?hours=48');
  assert.equal(h48.body.rows.length, 2);
});

test('L8 a POST prunes rows older than 14 days and keeps fresh ones', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  for (const s of ['o1', 'o2', 'o3']) seed(db, { session_id: s }, NOW - 15 * 86400_000);
  seed(db, { session_id: 'keep' }, NOW - 86400_000);
  const r = await post(env, { box: 'hub', rows: [lrow({ session_id: 'now' })] });
  assert.equal(r.status, 200);
  assert.deepEqual(stored(db).map((x) => x.session_id).sort(), ['keep', 'now']);
});
