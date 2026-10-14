import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { ensureColumns, ADDED_COLUMNS } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1026.0 (BH-1364) — the queues-are-rows CONTRACT slice, driven against THE
// SQL THAT SHIPS: the `deploy_queue` table, `build_queue.machine`, the three
// settings rows that seed the split dark, and the claim route's one optional
// field.
//
// WHY NOT A PATTERN-MATCHED FAKE DB. Every claim in this slice is a property of
// the shipped statements: that schema.sql re-applies clean (the additive-only
// iron law), that an operator's `'1'` survives a re-apply, that the column is
// nullable, and that ADDED_COLUMNS is what reaches a database whose build_queue
// predates the column. A stub answering by regex proves the handler called
// something, which was never in doubt.
//
// node:sqlite is imported at the TOP on purpose, with no skip path: CI runs
// node 22, where it exists, and a `t.skip` here would let the one check that
// proves the shipped SQL behaves vanish quietly on a runtime change.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// A D1-shaped facade over node:sqlite, with every statement it is asked to
// prepare recorded: the claim route's QUERY ORDER is part of what "an absent
// machine is exactly today's behaviour" means, and the only way to see it is to
// watch what the handler prepares.
function sqliteDB(db, seen) {
  const prepare = (sql) => {
    if (seen) seen.push(sql);
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

const openDb = () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
};

const call = (DB, path, { method = 'POST', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const cols = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all();

test('schema.sql re-applies clean, and carries no ALTER or DROP', () => {
  const db = openDb();
  db.exec(SCHEMA);   // the file re-applies on every deploy (bin/harness-sync.sh)
  db.exec(SCHEMA);
  // A bare ALTER cannot live in a re-runnable file — SQLite has no
  // `ADD COLUMN IF NOT EXISTS`, so the second apply would throw above. The
  // regex is the second half: it catches a statement that would be refused by
  // the apply mechanism's own classifier (D20) before it ever runs.
  const sql = SCHEMA.split('\n').map((l) => l.replace(/--.*$/, '')).join('\n');
  assert.equal(/\bALTER\b/i.test(sql), false, 'schema.sql must stay additive-only: no ALTER');
  assert.equal(/\bDROP\b/i.test(sql), false, 'schema.sql must stay additive-only: no DROP');
  db.close();
});

test('deploy_queue ships with its nine columns, its key and its index', () => {
  const db = openDb();
  const info = cols(db, 'deploy_queue');
  const names = info.map((c) => c.name).sort();
  assert.deepEqual(names,
    ['build_dir', 'claimed_by', 'departed_at', 'enqueued_at', 'project', 'reason', 'sha', 'status', 'updated_at'],
    'deploy_queue must carry exactly the columns the file store keys on');
  // (project, sha) — NOT the file store's identity, and the difference is the
  // point. state/deploy-queue/<p>/<epoch>-<sha8> is one file per REQUEST: the
  // same sha asked for twice is two files and bin/deploy-train.sh departs on
  // both. The table collapses that to one row on purpose, because deploying one
  // sha twice is a double-move.
  const pk = info.filter((c) => c.pk > 0).sort((a, b) => a.pk - b.pk).map((c) => c.name);
  assert.deepEqual(pk, ['project', 'sha'], 'the primary key is (project, sha)');
  // NOT NULL where the file store could not be empty.
  for (const need of ['project', 'sha', 'status', 'enqueued_at', 'updated_at']) {
    assert.equal(info.find((c) => c.name === need).notnull, 1, `${need} must be NOT NULL`);
  }

  const idx = db.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='deploy_queue'").all();
  const mine = idx.find((i) => i.name === 'idx_deploy_queue_status');
  assert.ok(mine, 'idx_deploy_queue_status must exist — every read this slice adds rides it');
  assert.match(mine.sql, /\(\s*status\s*,\s*project\s*,\s*enqueued_at\s*\)/,
    'the index is (status, project, enqueued_at), in that order');

  // SHIPS EMPTY. No row is today's behaviour.
  assert.equal(db.prepare('SELECT COUNT(*) n FROM deploy_queue').get().n, 0);
  db.close();
});

test('the (project, sha) collapse: a repeat request RE-OPENS the row, it is never dropped', () => {
  // The writer is a sibling slice, so what this pins is the CONTRACT the key
  // forces on it. The case is real and it is the worst one: bin/deploy-train.sh
  // self-sources a departure precisely when a sha has already departed `done`
  // and production is STILL not serving it. Under this key that request lands on
  // the existing row, so an `INSERT OR IGNORE` writer would no-op, the train
  // would read an empty queue, and production would stay stale with no departure
  // and no alert — the exact outage the self-source path exists to end.
  const db = openDb();
  const ins = (sha, at, status) => db.prepare(
    `INSERT INTO deploy_queue (project, sha, build_dir, status, enqueued_at, updated_at)
     VALUES ('project-3', ?, '/b', ?, ?, ?)
     ON CONFLICT(project, sha) DO UPDATE SET
       status=excluded.status, enqueued_at=excluded.enqueued_at,
       departed_at=NULL, reason=NULL, updated_at=excluded.updated_at`
  ).run(sha, status, at, at);

  ins('abc123', '2026-09-22T10:00:00Z', 'queued');
  db.prepare("UPDATE deploy_queue SET status='done', departed_at='2026-09-22T10:05:00Z', reason='VERIFIED' WHERE sha='abc123'").run();

  ins('abc123', '2026-09-22T10:40:00Z', 'queued');   // the self-sourced retry
  const rows = db.prepare("SELECT * FROM deploy_queue WHERE sha='abc123'").all();
  assert.equal(rows.length, 1, 'two requests for one sha are ONE row — that is the collapse');
  assert.equal(rows[0].status, 'queued', 'the retry must RE-OPEN the row, not be swallowed by it');
  assert.equal(rows[0].departed_at, null, 'a re-opened row has not departed yet');
  assert.equal(rows[0].reason, null, 'and carries no verdict from the departure before it');
  assert.equal(rows[0].enqueued_at, '2026-09-22T10:40:00Z', 'the wait starts again from the new request');

  // An `INSERT OR IGNORE` writer is what the contract forbids, and this is why.
  db.prepare("UPDATE deploy_queue SET status='done', departed_at='x' WHERE sha='abc123'").run();
  db.prepare(`INSERT OR IGNORE INTO deploy_queue (project, sha, status, enqueued_at, updated_at)
              VALUES ('project-3','abc123','queued','2026-09-22T11:00:00Z','2026-09-22T11:00:00Z')`).run();
  assert.equal(db.prepare("SELECT status FROM deploy_queue WHERE sha='abc123'").get().status, 'done',
    'INSERT OR IGNORE silently drops the retry — the drain would see nothing queued');
  db.close();
});

test('build_queue.machine is nullable, defaultless and never backfilled', () => {
  const db = openDb();
  const m = cols(db, 'build_queue').find((c) => c.name === 'machine');
  assert.ok(m, 'build_queue must carry `machine` for a FRESH database');
  assert.equal(m.type, 'TEXT');
  assert.equal(m.notnull, 0, 'machine is nullable: every row that predates it stays legal');
  assert.equal(m.dflt_value, null, 'machine has no default — absent is absent, never a placeholder');
  // The CREATE reaches only a fresh database; ADDED_COLUMNS is what reaches the
  // live one, and the two must name the same column.
  assert.deepEqual(ADDED_COLUMNS.build_queue, [['machine', 'TEXT']],
    'ADDED_COLUMNS.build_queue must stay in sync with the CREATE');
  db.close();
});

test('the three flag rows seed 0, and a re-apply never undoes an operator', () => {
  const db = openDb();
  const keys = ['build_queue_rows_only', 'merge_queue_rows_only', 'deploy_queue_rows'];
  for (const key of keys) {
    const row = db.prepare('SELECT value, actor, note FROM settings WHERE key=?').get(key);
    assert.ok(row, `${key} was not seeded — a knob nobody has touched must still answer`);
    assert.equal(row.value, '0', `${key} must seed OFF: this slice lands dark`);
    assert.equal(row.actor, 'seed');
    assert.ok(row.note && row.note.length > 0, `${key} must carry a note saying what it moves`);
  }
  db.prepare("UPDATE settings SET value='1', actor='hub' WHERE key='build_queue_rows_only'").run();
  db.exec(SCHEMA);
  const after = db.prepare("SELECT value, actor FROM settings WHERE key='build_queue_rows_only'").get();
  assert.equal(after.value, '1', 're-applying schema.sql switched a live slice back off');
  assert.equal(after.actor, 'hub');
  db.close();
});

test('ensureColumns reaches a build_queue that predates machine, once', async () => {
  // A LIVE database: build_queue exists without the column, so the CREATE in
  // schema.sql can never widen it. This is the only path that can.
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE build_queue (
    project TEXT NOT NULL, ticket_key TEXT NOT NULL, status TEXT NOT NULL,
    target TEXT NOT NULL DEFAULT 'local', attempt INTEGER NOT NULL DEFAULT 0,
    enqueued_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY (project, ticket_key))`);
  const seen = [];
  const env = { DB: sqliteDB(db, seen) };
  await ensureColumns(env, 'build_queue');
  assert.ok(cols(db, 'build_queue').some((c) => c.name === 'machine'),
    'ensureColumns must ALTER the column into an existing table');
  const alters = seen.filter((s) => /ALTER TABLE/i.test(s));
  assert.equal(alters.length, 1, `exactly one ALTER, got ${alters.length}: ${alters.join(' | ')}`);

  await ensureColumns(env, 'build_queue');
  assert.equal(seen.filter((s) => /ALTER TABLE/i.test(s)).length, 1,
    'memoised per DB handle: a second call must not re-ALTER');
  assert.equal(seen.filter((s) => /PRAGMA table_info/i.test(s)).length, 1,
    'memoised per DB handle: a second call must not re-PRAGMA');
  db.close();
});

test('ensureColumns swallows a duplicate-column race and never caches a failure', async () => {
  // Two isolates widening the same table in the same second: the loser gets
  // `duplicate column`, which is the outcome it wanted.
  const raced = {
    prepare: (sql) => ({
      all: async () => ({ results: [{ name: 'project' }, { name: 'ticket_key' }] }),
      bind: () => ({ run: async () => { throw new Error('D1_ERROR: duplicate column name: machine'); } }),
      run: async () => { throw new Error('D1_ERROR: duplicate column name: machine'); },
      first: async () => null,
    }),
  };
  await ensureColumns({ DB: raced }, 'build_queue');   // must not throw

  // A REAL failure is not swallowed, and is not cached as done either.
  const broken = {
    prepare: (sql) => ({
      all: async () => ({ results: [{ name: 'project' }] }),
      bind: () => ({ run: async () => { throw new Error('D1_ERROR: no such table: build_queue'); } }),
      run: async () => { throw new Error('D1_ERROR: no such table: build_queue'); },
      first: async () => null,
    }),
  };
  await assert.rejects(() => ensureColumns({ DB: broken }, 'build_queue'), /no such table/);
});

test('a claim that names a machine stores it, returns it, and GET /api/queue shows it', async () => {
  const db = openDb();
  const DB = sqliteDB(db);
  const put = await call(DB, '/api/queue', { body: { project: 'project-3', key: 'TK-140', ticket_id: 't-140', target: 'fly' } });
  assert.equal(put.status, 201);

  const MACHINE = '1857abc9f3d128';
  const claim = await call(DB, '/api/queue/claim',
    { body: { project: 'project-3', box: 'hub', key: 'TK-140', machine: MACHINE } });
  assert.equal(claim.status, 200);
  assert.equal(claim.body.queued.machine, MACHINE, 'the claim response must carry the machine it recorded');
  assert.equal(claim.body.queued.status, 'claimed');

  const stored = db.prepare("SELECT machine, status, claimed_by FROM build_queue WHERE ticket_key='TK-140'").get();
  assert.equal(stored.machine, MACHINE, 'the row the UPDATE changed must carry the machine');
  assert.equal(stored.status, 'claimed');
  assert.equal(stored.claimed_by, 'hub');

  const list = await call(DB, '/api/queue?project=project-3&status=claimed', { method: 'GET' });
  assert.equal(list.status, 200);
  assert.equal(list.body.queue[0].ticket_key, 'TK-140');
  assert.equal(list.body.queue[0].machine, MACHINE,
    'GET /api/queue is SELECT * — the column must appear the moment it exists');
  db.close();
});

// The claim response's keys as they SHIPPED, written out rather than read back
// off the table: an expectation derived from the schema this diff widened would
// carry the added column on both sides of the assertion and could not fail on
// the one thing it is cited for. `machine` is listed LAST and deliberately —
// the response is `{...row}` over a `SELECT *`, so once the column exists a
// claim that sent none answers `machine: null`. That is an added key, it is
// additive (every caller reads named fields), and this list is where it is
// admitted instead of being hidden behind a self-referential deepEqual.
const CLAIM_KEYS_ON_MAIN = [
  'attempt', 'claimed_at', 'claimed_by', 'enqueued_at', 'finished_at', 'meta',
  'project', 'reason', 'requested_by', 'status', 'target', 'ticket_id',
  'ticket_key', 'updated_at',
];

test('a claim with NO machine is byte for byte today: no PRAGMA, no ALTER, same SQL', async () => {
  const db = openDb();
  const seen = [];
  await call(sqliteDB(db), '/api/queue', { body: { project: 'project-3', key: 'TK-141' } });
  // A FRESH HANDLE for the claim. ensureColumns memoises per DB handle, so a
  // claim sharing the enqueue's handle would answer "no PRAGMA" because the
  // enqueue already paid for one — which would make the assertion below true of
  // a route that probed on every claim.
  const DB = sqliteDB(db, seen);

  const claim = await call(DB, '/api/queue/claim', { body: { project: 'project-3', box: 'hub' } });
  assert.equal(claim.status, 200);
  assert.equal(claim.body.claimed, true);

  // NOT CONFIGURED IS NOT A FAILURE, and it is not a migration either: no
  // machine in the body means the claim's query sequence is the one every
  // existing caller and every existing test sees.
  assert.equal(seen.filter((s) => /PRAGMA table_info/i.test(s)).length, 0,
    `an absent machine must not trigger the column check: ${seen.join(' | ')}`);
  assert.equal(seen.filter((s) => /ALTER TABLE/i.test(s)).length, 0,
    'an absent machine must not ALTER anything');
  assert.equal(seen.filter((s) => /\bmachine\b/.test(s)).length, 0,
    `no statement may name the column when the body did not: ${seen.join(' | ')}`);

  assert.equal(db.prepare("SELECT machine FROM build_queue WHERE ticket_key='TK-141'").get().machine, null,
    'a claim with no machine leaves the column null — absent, never a placeholder');

  // The response shape: the keys it had before, PLUS the one this column adds.
  assert.deepEqual(Object.keys(claim.body.queued).sort(),
    [...CLAIM_KEYS_ON_MAIN, 'machine'].sort(),
    'the claim response is the row: every key it had, and machine — nothing else');
  assert.deepEqual(Object.keys(claim.body).sort(), ['as_of', 'claimed', 'queued'],
    'the claim body keys are unchanged');
  assert.equal(claim.body.queued.machine, null);
  db.close();
});

test('a machine that is not an id-shaped string records NOTHING, and never a coerced one', async () => {
  // `String(v)` is the trap: every one of these lands UNDER any length bound and
  // would be written to the row as this build's location. "[object Object]"
  // names no machine; "1,2" and "42" could name somebody else's. A wrong id is
  // worse than none — the reaper and the dispatcher this column feeds act on it.
  const db = openDb();
  const junk = [
    ['an object', { a: 1 }], ['an array', [1, 2]], ['a boolean', true], ['a number', 42],
    ['an over-long id', 'f'.repeat(300)], ['an id with a space', 'not an id'],
    ['an empty string', ''], ['a path', '../../etc/passwd'],
  ];
  let n = 0;
  for (const [label, value] of junk) {
    const key = `TK-2${n++}`;
    const DB = sqliteDB(db);
    await call(DB, '/api/queue', { body: { project: 'project-3', key } });
    const claim = await call(DB, '/api/queue/claim',
      { body: { project: 'project-3', box: 'hub', key, machine: value } });
    assert.equal(claim.status, 200, `${label} is a shape, never a 500`);
    const stored = db.prepare('SELECT machine FROM build_queue WHERE ticket_key=?').get(key).machine;
    assert.equal(stored, null, `${label} must not be coerced onto the row`);
    // AND THE CLAIM STILL LANDS, with no machine. The column's guarantee is
    // "never the wrong machine", not "always a machine" — the route comment says
    // exactly that, because a row with none reads as every local claim does.
    assert.equal(claim.body.queued.status, 'claimed', `${label} must not refuse the claim`);
    assert.equal(claim.body.queued.machine, null,
      `${label} must be reported back as what was RECORDED, not what was sent`);
  }
  // …and the id-shaped string it exists for still goes through.
  const DB = sqliteDB(db);
  await call(DB, '/api/queue', { body: { project: 'project-3', key: 'TK-99' } });
  const good = await call(DB, '/api/queue/claim',
    { body: { project: 'project-3', box: 'hub', key: 'TK-99', machine: '1857abc9f3d128' } });
  assert.equal(good.body.queued.machine, '1857abc9f3d128',
    'the validator must not be so tight it refuses a real Fly machine id');
  db.close();
});

test('machine belongs to the CLAIM: a release and a re-queue both clear it', async () => {
  // THE DEFECT THIS PINS. A machine dies; bin/jobs-watchdog.sh releases the row
  // 6h later; the ticket is re-claimed by a LOCAL build, which sends no machine.
  // Without the clear, the row reads status=claimed, claimed_by=box-a and
  // machine=<the dead id> — "claimed, and here is where", pointing at a machine
  // that is gone or has been recycled to another build.
  const db = openDb();
  const DB = sqliteDB(db);
  const MACHINE = '1857abc9f3d128';
  await call(DB, '/api/queue', { body: { project: 'project-3', key: 'TK-150', target: 'fly' } });
  await call(DB, '/api/queue/claim', { body: { project: 'project-3', box: 'fly-1', key: 'TK-150', machine: MACHINE } });
  const mOf = (key) => db.prepare('SELECT machine, status FROM build_queue WHERE ticket_key=?').get(key);
  assert.equal(mOf('TK-150').machine, MACHINE);

  const rel = await call(DB, '/api/queue',
    { method: 'PATCH', body: { project: 'project-3', key: 'TK-150', status: 'queued', reason: 'machine died' } });
  assert.equal(rel.status, 200);
  assert.equal(mOf('TK-150').machine, null, 'a released row is running nowhere and must name no machine');
  assert.equal(rel.body.queued.machine, null, 'and the response must say so');

  const re = await call(DB, '/api/queue/claim', { body: { project: 'project-3', box: 'box-a', key: 'TK-150' } });
  assert.equal(re.status, 200);
  assert.equal(mOf('TK-150').machine, null,
    'a re-claim that sends no machine must not inherit the dead one');
  assert.equal(mOf('TK-150').status, 'claimed');

  // A TERMINAL row keeps it — "which machine ran this build" is ledger — and the
  // RE-QUEUE is what clears it, so the next claim starts clean either way.
  await call(DB, '/api/queue', { body: { project: 'project-3', key: 'TK-151', target: 'fly' } });
  await call(DB, '/api/queue/claim', { body: { project: 'project-3', box: 'fly-1', key: 'TK-151', machine: MACHINE } });
  await call(DB, '/api/queue',
    { method: 'PATCH', body: { project: 'project-3', key: 'TK-151', status: 'done', reason: 'PR_CREATED' } });
  assert.equal(mOf('TK-151').machine, MACHINE, 'a finished row records where it ran');
  await call(DB, '/api/queue', { body: { project: 'project-3', key: 'TK-151', target: 'fly' } });
  assert.equal(mOf('TK-151').machine, null, 're-queueing a finished row must clear the last attempt\'s machine');
  assert.equal(mOf('TK-151').status, 'queued');
  db.close();
});
