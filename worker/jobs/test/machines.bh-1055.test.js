import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1055 (BH-1035.1): the four /api/machines routes, driven through the
// worker's REAL fetch handler over a node:sqlite database.
//
// WHY A REAL DATABASE HERE AND A STUB IN index.test.js. Every interesting
// decision in this slice is made by SQL, not by JavaScript: which row the
// observe sweep calls `gone`, whether an upsert keeps the first `spawned_at`,
// whether `ended_at` survives a non-terminal correction. A pattern-matching
// stub would answer `changes:1` to all of it and pass a worker that marks live
// machines dead. So the statements run against SQLite and the assertions read
// the rows back.

const SECRET = 'test-secret';
const now = Date.now();  // determinism: ok the single anchor; every fixture below is iso(msAgo) off it
const iso = (msAgo) => new Date(now - msAgo).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const SCHEMA = jobsSchemaSql();

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// ── a D1-shaped adapter over node:sqlite ────────────────────────────────────
// The surface the worker actually uses: prepare().bind().run()/first()/all(),
// and batch() as ONE transaction returning per-statement results in order.
function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) {
      return { results: stmt.all(...binds), meta: { changes: 0 } };
    }
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql,
    _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try {
        const out = stmts.map((s) => exec(s._sql, s._binds));
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}

function fresh() {
  const db = new DatabaseSync(':memory:');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body, opts = {}) {
  const headers = {};
  if (opts.auth !== false) headers.authorization = 'Bearer ' + SECRET;
  const init = { method, headers };
  if (body !== undefined) {
    headers['content-type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  const parsed = await res.json().catch(() => null);
  return { status: res.status, body: parsed };
}

const COLS = [
  'machine_id', 'project', 'app', 'role', 'key', 'ticket', 'auth_account',
  'image', 'state', 'detail', 'spawned_at', 'last_seen', 'ended_at', 'actor', 'updated_at',
];
// Built by concatenation on purpose: a SQL template literal with ${} in it is a
// checks/sql-command-injection finding, in tests as much as in product code.
const SEED_SQL = 'INSERT INTO machines (' + COLS.join(',') + ') VALUES ('
  + COLS.map((_, i) => '?' + (i + 1)).join(',') + ')';

function seed(db, row) {
  db.prepare(SEED_SQL).run(...COLS.map((c) => (row[c] === undefined ? null : row[c])));
}
const rows = (db) => db.prepare('SELECT * FROM machines ORDER BY machine_id ASC').all();
const rowOf = (db, id) => db.prepare('SELECT * FROM machines WHERE machine_id=?1').get(id) ?? null;
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM machines').get().n;
const ids = (list) => list.map((m) => m.machine_id).sort();

// Table must exist before a fixture can be inserted; the routes create it, so
// one read is how a test gets a table without a hand step.
async function withTable(env) {
  const r = await call(env, 'GET', '/api/machines');
  assert.equal(r.status, 200);
}

// ── 1 ───────────────────────────────────────────────────────────────────────
test('GET /api/machines on an empty database answers 200 and creates the table', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  const r = await call(env, 'GET', '/api/machines');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.machines, []);
  assert.match(r.body.as_of, ISO_RE);

  const tbl = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='machines'").get();
  assert.ok(tbl, 'ensureTable did not create machines');
  db.close();
});

// ── 2 ───────────────────────────────────────────────────────────────────────
test('PUT /api/machines refuses an unauthorised or malformed register, and writes nothing', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);

  const ok = { project: 'cromford', app: 'pool-a', machine_id: 'm1', role: 'pool' };

  assert.equal((await call(env, 'PUT', '/api/machines', ok, { auth: false })).status, 401);
  assert.equal((await call(env, 'GET', '/api/machines', undefined, { auth: false })).status, 401);

  assert.equal((await call(env, 'PUT', '/api/machines', { ...ok, role: 'hub' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/machines', { ...ok, state: 'flying' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/machines', { ...ok, machine_id: 'a b' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/machines', { ...ok, project: '' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/machines', { ...ok, app: 'a/b' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/machines', { ...ok, key: 'BH 7' })).status, 400);

  assert.equal(count(db), 0, 'a 400 wrote a row');
  db.close();
});

// ── 3 ───────────────────────────────────────────────────────────────────────
test('PUT /api/machines upserts on machine_id: first spawned_at kept, optional fields COALESCEd', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  const first = await call(env, 'PUT', '/api/machines', {
    project: 'cromford', app: 'pool-a', machine_id: 'm1', role: 'builder',
    key: 'BH-1', image: 'img:1', ticket: 'BH-1', auth_account: 'acct-a', actor: 'tester',
  });
  assert.equal(first.status, 200);
  assert.equal(first.body.machine.machine_id, 'm1');
  assert.equal(first.body.machine.state, 'spawned', 'state defaults to spawned');
  assert.match(first.body.machine.spawned_at, ISO_RE);

  // Age the row so "keeps the FIRST spawned_at" is a claim about a value the
  // second call could not have produced (both calls land in the same second).
  const born = iso(600000);
  db.prepare('UPDATE machines SET spawned_at=?1 WHERE machine_id=?2').run(born, 'm1');

  const second = await call(env, 'PUT', '/api/machines', {
    project: 'cromford', app: 'pool-a', machine_id: 'm1', role: 'builder',
    key: 'BH-2', state: 'started',
  });
  assert.equal(second.status, 200);
  assert.equal(count(db), 1, 'the second PUT inserted a second row');
  const row = rowOf(db, 'm1');
  assert.equal(row.spawned_at, born, 'spawned_at was overwritten by the re-register');
  assert.equal(row.key, 'BH-2', 'the new key did not land');
  assert.equal(row.image, 'img:1', 'the absent image cleared the stored one');
  assert.equal(row.ticket, 'BH-1');
  assert.equal(row.auth_account, 'acct-a');
  assert.equal(row.state, 'started');
  assert.ok(row.updated_at >= first.body.machine.updated_at);
  assert.equal(second.body.machine.age_s >= 600, true, 'age_s is derived from the kept spawned_at');

  // A reused machine is live again: a non-terminal register clears ended_at.
  db.prepare("UPDATE machines SET ended_at=?1, state='destroyed' WHERE machine_id=?2").run(iso(60000), 'm1');
  const revived = await call(env, 'PUT', '/api/machines', {
    project: 'cromford', app: 'pool-a', machine_id: 'm1', role: 'builder', state: 'started',
  });
  assert.equal(revived.status, 200);
  assert.equal(rowOf(db, 'm1').ended_at, null, 'a non-terminal register left ended_at set');

  // ...and a terminal register does not clear it.
  db.prepare('UPDATE machines SET ended_at=?1 WHERE machine_id=?2').run(iso(60000), 'm1');
  await call(env, 'PUT', '/api/machines', {
    project: 'cromford', app: 'pool-a', machine_id: 'm1', role: 'builder', state: 'destroyed',
  });
  assert.equal(rowOf(db, 'm1').ended_at, iso(60000), 'a terminal register cleared ended_at');
  db.close();
});

// ── 4 ───────────────────────────────────────────────────────────────────────
function observeFixture(db) {
  const base = { project: 'cromford', app: 'pool-a', role: 'pool' };
  seed(db, { ...base, machine_id: 'm1', state: 'started', spawned_at: iso(3600000), last_seen: iso(60000), updated_at: iso(60000) });
  seed(db, { ...base, machine_id: 'm2', state: 'started', spawned_at: iso(3600000), last_seen: iso(60000), updated_at: iso(60000) });
  seed(db, { ...base, machine_id: 'm3', state: 'destroyed', spawned_at: iso(7200000), last_seen: iso(120000), ended_at: iso(120000), updated_at: iso(120000) });
  seed(db, { ...base, machine_id: 'm4', state: 'spawned', spawned_at: iso(300000), updated_at: iso(300000) });
  seed(db, { ...base, machine_id: 'm5', state: 'spawned', spawned_at: iso(1860000), updated_at: iso(1860000) });
}

test('PUT /api/machines/observe stamps the listed, sweeps the absent, registers the unknown', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);
  observeFixture(db);
  const before = rows(db);
  const m3Before = before.find((r) => r.machine_id === 'm3');
  const m4Before = before.find((r) => r.machine_id === 'm4');

  const r = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford',
    app: 'pool-a',
    actor: 'fly-pool',
    machines: [
      { machine_id: 'm1', state: 'started', updated_at: iso(900000) },
      { machine_id: 'm9', state: 'stopped' },
    ],
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.seen, 2);
  assert.equal(r.body.registered, 1);
  assert.equal(r.body.gone, 2);
  assert.equal(r.body.capped, false);
  assert.match(r.body.as_of, ISO_RE);
  const t0 = r.body.as_of;

  const m1 = rowOf(db, 'm1');
  assert.equal(m1.last_seen, t0, 'a listed machine is stamped with the SERVER clock');
  assert.equal(m1.state, 'started');
  assert.equal(m1.ended_at, null, 'a listed machine was marked ended');

  const m2 = rowOf(db, 'm2');
  assert.equal(m2.state, 'gone', 'an unlisted machine last seen a minute ago is still live');
  assert.equal(m2.ended_at, t0);

  assert.deepEqual(rowOf(db, 'm3'), m3Before, 'a destroyed row was re-swept');
  assert.deepEqual(rowOf(db, 'm4'), m4Before, 'a machine spawned 5 min ago and never listed went gone');

  const m5 = rowOf(db, 'm5');
  assert.equal(m5.state, 'gone', 'a machine spawned 31 min ago and never seen survived the grace');
  assert.equal(m5.ended_at, t0);

  const m9 = rowOf(db, 'm9');
  assert.ok(m9, 'an untracked machine was ignored instead of registered');
  assert.equal(m9.role, 'pool');
  assert.equal(m9.key, null);
  assert.equal(m9.spawned_at, null);
  assert.equal(m9.state, 'stopped');
  assert.equal(m9.last_seen, t0);
  assert.equal(m9.project, 'cromford');
  assert.equal(m9.app, 'pool-a');
  db.close();
});

test('PUT /api/machines/observe with one bad entry writes nothing at all', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);
  observeFixture(db);
  const before = rows(db);

  const bad = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford',
    app: 'pool-a',
    machines: [{ machine_id: 'm1', state: 'started' }, { machine_id: 'mX', state: 'bogus' }],
  });
  assert.equal(bad.status, 400);
  assert.deepEqual(rows(db), before, 'a rejected listing still wrote rows');

  const badId = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford', app: 'pool-a', machines: [{ machine_id: 'm 1', state: 'started' }],
  });
  assert.equal(badId.status, 400);
  assert.equal((await call(env, 'PUT', '/api/machines/observe', { project: 'cromford', app: 'pool-a' })).status, 400);
  assert.deepEqual(rows(db), before);
  db.close();
});

// ── 5 ───────────────────────────────────────────────────────────────────────
test('an observe for one app never touches another app rows', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);
  seed(db, { machine_id: 'a1', project: 'cromford', app: 'pool-a', role: 'pool', state: 'started', spawned_at: iso(3600000), last_seen: iso(60000), updated_at: iso(60000) });
  seed(db, { machine_id: 'a2', project: 'cromford', app: 'pool-a', role: 'pool', state: 'spawned', spawned_at: iso(3600000), updated_at: iso(3600000) });
  const before = rows(db);

  const r = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford', app: 'pool-b', machines: [],
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.seen, 0);
  assert.equal(r.body.registered, 0);
  assert.equal(r.body.gone, 0);
  assert.deepEqual(rows(db), before, 'app pool-b observe swept app pool-a');
  db.close();
});

// ── 6 ───────────────────────────────────────────────────────────────────────
test('an observe over the cap processes 200, says so, and sweeps nothing', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);
  seed(db, { machine_id: 'u1', project: 'cromford', app: 'pool-a', role: 'pool', state: 'started', spawned_at: iso(3600000), last_seen: iso(60000), updated_at: iso(60000) });

  const listing = [];
  for (let i = 1; i <= 201; i += 1) listing.push({ machine_id: 'g' + i, state: 'started' });
  const r = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford', app: 'pool-a', machines: listing,
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.capped, true);
  assert.equal(r.body.seen, 200);
  assert.equal(r.body.registered, 200);
  assert.equal(r.body.gone, 0, 'a partial listing cannot prove absence');
  assert.equal(count(db), 201, 'expected the fixture plus 200 registered rows');
  assert.equal(rowOf(db, 'g201'), null, 'entry 201 was processed past the cap');
  assert.equal(rowOf(db, 'u1').state, 'started', 'a capped listing called an unlisted machine gone');
  db.close();
});

// ── 6b ────────────────────────────────────────────────────────────
// ONE MACHINE MID-TRANSITION MUST NOT COST THE WHOLE SWEEP. `state` comes
// straight out of `fly machine list --json`, and the validation is all-or-
// nothing: a state Fly reports but the contract does not know answers 400 for
// the ENTIRE listing, so nothing is stamped and nothing is swept that tick.
test('an observe listing carrying a Fly mid-transition state is accepted', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);

  const r = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford', app: 'pool-a', machines: [
      { machine_id: 's1', state: 'suspending' },
      { machine_id: 's2', state: 'replacing' },
      { machine_id: 's3', state: 'destroy_failed' },
    ],
  });
  assert.equal(r.status, 200, 'a machine mid-suspend 400d the whole listing');
  assert.equal(r.body.seen, 3);
  assert.equal(rowOf(db, 's1').state, 'suspending');
  assert.equal(rowOf(db, 's2').state, 'replacing');
  assert.equal(rowOf(db, 's3').state, 'destroy_failed');
  assert.equal(rowOf(db, 's3').ended_at, null, 'destroy_failed is not terminal');
  db.close();
});

// ── 7 ───────────────────────────────────────────────────────────────────────
test('PATCH /api/machines/<id> closes or corrects, and registers an unknown id', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  const closed = await call(env, 'PATCH', '/api/machines/m7', {
    project: 'cromford', app: 'pool-a', state: 'destroyed', actor: 'fly-pool',
  });
  assert.equal(closed.status, 200);
  const m7 = rowOf(db, 'm7');
  assert.ok(m7, 'a close for an unknown machine registered no row');
  assert.equal(m7.state, 'destroyed');
  assert.equal(m7.role, 'pool');
  assert.ok(m7.ended_at, 'a terminal close left ended_at null');
  assert.equal(m7.ended_at, m7.updated_at, 'ended_at is the server clock of this call');
  assert.equal(closed.body.machine.ended_at, m7.ended_at);

  await call(env, 'PUT', '/api/machines', {
    project: 'cromford', app: 'pool-a', machine_id: 'm8', role: 'pool',
  });
  assert.equal(rowOf(db, 'm8').ended_at, null);
  const failed = await call(env, 'PATCH', '/api/machines/m8', {
    project: 'cromford', app: 'pool-a', state: 'failed', detail: 'boot timed out',
  });
  assert.equal(failed.status, 200);
  assert.equal(rowOf(db, 'm8').state, 'failed');
  assert.equal(rowOf(db, 'm8').ended_at, null, 'a non-terminal correction stamped ended_at');
  assert.equal(rowOf(db, 'm8').detail, 'boot timed out');

  // THE SWEEP WRITER'S CLOSE. `destroy_failed` is in the contract's vocabulary
  // (BH-1054) and is NOT terminal: the machine is still there and the pool
  // sweep retries the destroy, so the row records the refusal and keeps
  // `ended_at` NULL. This is byte-for-byte the call bin/fly-pool.sh's sweep
  // writer makes (BH-1056), and it fails open — a 400 here would be silently
  // indistinguishable from a worker outage.
  const df = await call(env, 'PATCH', '/api/machines/m8', {
    project: 'cromford', app: 'pool-a', state: 'destroy_failed',
    detail: 'rate limited by the Fly API',
  });
  assert.equal(df.status, 200, 'the contract refused the sweep writer destroy_failed close');
  assert.equal(rowOf(db, 'm8').state, 'destroy_failed');
  assert.equal(rowOf(db, 'm8').ended_at, null, 'destroy_failed stamped ended_at on a machine that is still there');
  assert.equal(rowOf(db, 'm8').detail, 'rate limited by the Fly API');
  assert.equal(df.body.machine.state, 'destroy_failed');

  const snapshot = rowOf(db, 'm8');
  assert.equal((await call(env, 'PATCH', '/api/machines/m8', { project: 'cromford', app: 'pool-a', state: 'bogus' })).status, 400);
  assert.equal((await call(env, 'PATCH', '/api/machines/m8', { project: 'cromford', app: 'pool-a' })).status, 400);
  assert.equal((await call(env, 'PATCH', '/api/machines/m8', { project: 'a b', app: 'pool-a', state: 'stopped' })).status, 400);
  assert.equal((await call(env, 'PATCH', '/api/machines/m8', {
    project: 'cromford', app: 'pool-a', state: 'stopped', detail: 'x'.repeat(301),
  })).status, 400, 'an over-long detail was truncated instead of refused');
  assert.deepEqual(rowOf(db, 'm8'), snapshot, 'a refused PATCH wrote to the row');

  const long = await call(env, 'PATCH', '/api/machines/m8', {
    project: 'cromford', app: 'pool-a', state: 'stopped', detail: 'y'.repeat(300),
  });
  assert.equal(long.status, 200);
  assert.equal(rowOf(db, 'm8').detail.length, 300);
  db.close();
});

// ── 7b ────────────────────────────────────────────────────────────
// A ROW A PATCH CREATED MUST STILL BE SWEEPABLE. The close that registers an
// unknown machine writes neither `spawned_at` nor `last_seen` — it is a close,
// not a sighting — so a sweep that judges only those two columns can never
// reach it, and a `failed`/`destroy_failed` row Fly has stopped listing stays
// `live=1` forever. The row's own `updated_at` is the fallback clock.
test('a machine registered only by a PATCH is swept once the grace has passed', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  for (const id of ['z1', 'z2']) {
    const p = await call(env, 'PATCH', '/api/machines/' + id, {
      project: 'cromford', app: 'pool-a', state: 'destroy_failed', detail: 'rate limited by the Fly API',
    });
    assert.equal(p.status, 200);
    assert.equal(rowOf(db, id).spawned_at, null, 'a close wrote a spawned_at it does not know');
    assert.equal(rowOf(db, id).last_seen, null, 'a close wrote a last_seen it does not know');
  }
  // z1 is older than the 30-minute grace; z2 was closed a minute ago.
  db.prepare('UPDATE machines SET updated_at=?1 WHERE machine_id=?2').run(iso(1860000), 'z1');
  db.prepare('UPDATE machines SET updated_at=?1 WHERE machine_id=?2').run(iso(60000), 'z2');

  const r = await call(env, 'PUT', '/api/machines/observe', {
    project: 'cromford', app: 'pool-a', machines: [],
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.gone, 1, 'a PATCH-registered row Fly no longer lists was never swept');
  assert.equal(rowOf(db, 'z1').state, 'gone', 'the aged PATCH-registered row survived the sweep');
  assert.equal(rowOf(db, 'z1').ended_at, r.body.as_of);
  assert.equal(rowOf(db, 'z2').state, 'destroy_failed', 'a row closed a minute ago was swept inside the grace');
  assert.equal(rowOf(db, 'z2').ended_at, null);
  db.close();
});

// ── 7c ────────────────────────────────────────────────────────────
test('PATCH /api/machines/observe is not a machine named observe', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);

  const r = await call(env, 'PATCH', '/api/machines/observe', {
    project: 'cromford', app: 'pool-a', state: 'stopped',
  });
  assert.notEqual(r.status, 200, 'a PATCH to the observe path was served as a machine close');
  assert.equal(rowOf(db, 'observe'), null, 'a PATCH to the observe path registered a machine named observe');
  db.close();
});

// ── 8 ───────────────────────────────────────────────────────────────────────
test('GET /api/machines filters on live, key and project, and decorates every row', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);
  const base = { project: 'cromford', app: 'pool-a', role: 'pool' };
  seed(db, { ...base, machine_id: 'a', state: 'started', key: 'BH-7', spawned_at: iso(100000), last_seen: iso(30000), updated_at: iso(30000) });
  seed(db, { ...base, machine_id: 'b', state: 'gone', spawned_at: iso(100000), ended_at: iso(60000), updated_at: iso(60000) });
  seed(db, { ...base, machine_id: 'c', state: 'destroyed', spawned_at: iso(100000), ended_at: iso(90000), updated_at: iso(90000) });
  seed(db, { ...base, machine_id: 'd', state: 'stopped', key: 'BH-8', spawned_at: iso(600000), updated_at: iso(120000) });
  seed(db, { machine_id: 'z', project: 'other', app: 'pool-z', role: 'pool', state: 'started', spawned_at: iso(100000), updated_at: iso(10000) });

  const all = await call(env, 'GET', '/api/machines');
  assert.equal(all.status, 200);
  assert.deepEqual(ids(all.body.machines), ['a', 'b', 'c', 'd', 'z']);

  const live = await call(env, 'GET', '/api/machines?project=cromford&live=1');
  assert.equal(live.status, 200);
  assert.deepEqual(ids(live.body.machines), ['a', 'd'], 'live=1 must exclude gone and destroyed');

  const byKey = await call(env, 'GET', '/api/machines?project=cromford&key=BH-7');
  assert.deepEqual(ids(byKey.body.machines), ['a']);

  const byApp = await call(env, 'GET', '/api/machines?app=pool-z');
  assert.deepEqual(ids(byApp.body.machines), ['z']);

  assert.equal((await call(env, 'GET', '/api/machines?project=a%20b')).status, 400);
  assert.equal((await call(env, 'GET', '/api/machines?app=a%2Fb')).status, 400);
  assert.equal((await call(env, 'GET', '/api/machines?key=BH%207')).status, 400);

  const d = live.body.machines.find((m) => m.machine_id === 'd');
  assert.ok(d.age_s >= 600 && d.age_s <= 605, 'age_s should be ~600, got ' + d.age_s);
  assert.equal(d.seen_age_s, null, 'seen_age_s must be null when a machine was never seen');
  const a = live.body.machines.find((m) => m.machine_id === 'a');
  assert.ok(a.seen_age_s >= 30 && a.seen_age_s <= 35, 'seen_age_s should be ~30, got ' + a.seen_age_s);
  db.close();
});

// ── 9 ───────────────────────────────────────────────────────────────────────
test('schema.sql still applies cleanly after the routes created the table', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await withTable(env);

  db.exec(SCHEMA);
  const cols = db.prepare('PRAGMA table_info(machines)').all();
  assert.equal(cols.length, 15, 'the routes created a machines table schema.sql disagrees with');
  db.close();
});
