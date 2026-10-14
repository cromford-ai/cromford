import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { ensureTable } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1033 (state→DB slice 8) — the `ready` build_queue status and the
// closeout_aged table, driven through the worker's real fetch handler against
// THE SQL THAT SHIPS, applied into node:sqlite behind a D1 shim.
//
// WHY NOT A PATTERN-MATCHED FAKE DB. Both halves of this slice are SQL
// properties: `ON CONFLICT(build_dir) DO NOTHING` is the entire dedupe, and the
// `ready` upsert has to leave a claimed row alone. A stub that answers by regex
// proves the handler called something, which is the half that was never in
// doubt. The invariants below are the ones a wrong statement would break.
//
// The routes' auth, the status graph and the shapes callers parse are proven
// here too, because bin/jobs-client.sh reads exactly these fields.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// A D1-shaped facade over node:sqlite. D1 reports rows changed on run(), which
// is what the closeout route's "recorded or duplicate" answer is computed from,
// so the shim must report it honestly rather than always 1.
function sqliteDB(db) {
  const prepare = (sql) => {
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

async function openDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    // Visible in TAP as a skip. A silent pass would be the worst outcome: the
    // one check that proves the shipped SQL behaves, quietly absent.
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
}

const call = (db, path, { method = 'POST', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

test('schema.sql seeds both slice-8 flags OFF, and re-applying never undoes an operator', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  for (const key of ['ready_queue_rows', 'closeout_aged_table']) {
    const row = db.prepare('SELECT value, actor FROM settings WHERE key=?').get(key);
    assert.ok(row, `${key} was not seeded — a knob nobody has touched must still answer`);
    assert.equal(row.value, '0', `${key} must seed OFF: this slice lands dark`);
    assert.equal(row.actor, 'seed');
  }
  db.prepare("UPDATE settings SET value='1', actor='hub' WHERE key='ready_queue_rows'").run();
  db.exec(SCHEMA);   // the file re-applies on every deploy
  const after = db.prepare("SELECT value, actor FROM settings WHERE key='ready_queue_rows'").get();
  assert.equal(after.value, '1', 're-applying schema.sql switched a live slice back off');
  assert.equal(after.actor, 'hub');
  db.close();
});

test('a ready enqueue is a ready ROW, and nothing else on this route changed', async (t) => {
  const db = await openDb(t);
  if (!db) return;

  const ready = await call(db, '/api/queue',
    { body: { project: 'project-3', key: 'TK-140', ticket_id: 't-140', status: 'ready',
              meta: JSON.stringify({ ready_line: 'TK-140 t-140 — OWED-STALE project=project-3' }) } });
  assert.equal(ready.status, 201);
  assert.equal(ready.body.queued.status, 'ready');

  // The row a dispatcher would claim is NOT this one: every claim path selects
  // status='queued', so a ready ticket cannot be built before triage launches it.
  const claim = await call(db, '/api/queue/claim', { body: { project: 'project-3', box: 'hub' } });
  assert.equal(claim.status, 404, 'a ready row must not be claimable');

  // An enqueue with no status is `queued`, exactly as every caller has seen.
  const plain = await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-141' } });
  assert.equal(plain.body.queued.status, 'queued');
  // …and so is one with a status this route does not accept. A typo must not
  // land as a permanent unknown state.
  const junk = await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-142', status: 'redy' } });
  assert.equal(junk.body.queued.status, 'queued');

  const claim2 = await call(db, '/api/queue/claim', { body: { project: 'project-3', box: 'hub' } });
  assert.equal(claim2.status, 200);
  assert.equal(claim2.body.queued.ticket_key, 'TK-141', 'the oldest QUEUED row is the one claimed');
});

test('re-offering a ready key keeps the row it already has', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-140', status: 'ready' } });
  const first = db.prepare("SELECT enqueued_at FROM build_queue WHERE ticket_key='TK-140'").get();

  const again = await call(db, '/api/queue',
    { body: { project: 'project-3', key: 'TK-140', status: 'ready' } });
  assert.equal(again.body.duplicate, true, 'the stale-owed sweep re-offers the same key every run');
  const second = db.prepare("SELECT enqueued_at, status FROM build_queue WHERE ticket_key='TK-140'").get();
  assert.equal(second.enqueued_at, first.enqueued_at,
    'a re-offer that rewrote enqueued_at would reset the 24h cooldown it is judged on');
  assert.equal(second.status, 'ready');

  // …AND A READY ROW MUST NOT REFUSE A REAL BUILD. Every launch path and
  // bin/orphan-reconcile.sh enqueue with no status; answering `duplicate` there
  // would make a merely-READY ticket unbuildable for as long as its row sits,
  // which is the starvation this table exists to end.
  const launched = await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-140' } });
  assert.equal(launched.body.duplicate, false, 'a ready row must not refuse a real build enqueue');
  assert.equal(db.prepare("SELECT status FROM build_queue WHERE ticket_key='TK-140'").get().status, 'queued',
    'launching a ready ticket PROMOTES its row — that is what launching means');
  const takeable = await call(db, '/api/queue/claim', { body: { project: 'project-3', box: 'hub' } });
  assert.equal(takeable.status, 200);
  assert.equal(takeable.body.queued.ticket_key, 'TK-140');

  // A key that is BUILDING must not be knocked back to ready by a sweep that
  // has not noticed yet — that is how one ticket gets built twice.
  await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-150' } });
  await call(db, '/api/queue/claim', { body: { project: 'project-3', box: 'fly-7' } });
  await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-150', status: 'ready' } });
  const live = db.prepare("SELECT status, claimed_by FROM build_queue WHERE ticket_key='TK-150'").get();
  assert.equal(live.status, 'claimed');
  assert.equal(live.claimed_by, 'fly-7');
});

test('only a ready row may be dropped, and a dropped row can come back', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-140', status: 'ready' } });

  const dropped = await call(db, '/api/queue',
    { method: 'PATCH', body: { project: 'project-3', key: 'TK-140', status: 'dropped', reason: 'consumed' } });
  assert.equal(dropped.status, 200);
  assert.equal(db.prepare("SELECT status FROM build_queue WHERE ticket_key='TK-140'").get().status, 'dropped');

  // The board can re-offer a dropped ticket; nothing here is a trap.
  const back = await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-140', status: 'ready' } });
  assert.equal(back.body.duplicate, false);
  assert.equal(db.prepare("SELECT status FROM build_queue WHERE ticket_key='TK-140'").get().status, 'ready');
  // …and OFFERING IS NOT ATTEMPTING (round-3 N1). `attempt` is the death count a
  // retry policy judges; a line consumed and re-offered ran no build, so a
  // re-offer that incremented it would park a ticket that never failed.
  assert.equal(db.prepare("SELECT attempt FROM build_queue WHERE ticket_key='TK-140'").get().attempt, 0,
    'a ready re-offer must not count as a build attempt');

  // A CLAIMED row is a live build. bin/queue-line-drop.sh runs while parallel
  // triagers are launching, so the refusal is the guard that keeps that build.
  await call(db, '/api/queue', { body: { project: 'project-3', key: 'TK-160' } });
  await call(db, '/api/queue/claim', { body: { project: 'project-3', box: 'fly-7', key: 'TK-160' } });
  const refused = await call(db, '/api/queue',
    { method: 'PATCH', body: { project: 'project-3', key: 'TK-160', status: 'dropped' } });
  assert.equal(refused.status, 409);
  assert.equal(db.prepare("SELECT status FROM build_queue WHERE ticket_key='TK-160'").get().status, 'claimed');
});

test('a ready re-offer must not rewrite a TERMINAL row', async (t) => {
  const db = await openDb(t);
  if (!db) return;

  // A build that DIED and was parked. bin/blocked-resolver.sh:906-926 intakes
  // parked tickets from `queue_list "" failed` by MATCHING THE REASON — `died N
  // times` / `deferred N times` — so the reason column is not decoration, it is
  // the lane's intake key.
  await call(db, '/api/queue', { body: { project: 'project-1', key: 'TK-88' } });
  await call(db, '/api/queue', { method: 'PATCH',
    body: { project: 'project-1', key: 'TK-88', status: 'failed',
            reason: 'died 2 times on the build lane — parked for the blocked-resolver' } });
  const parked = db.prepare("SELECT * FROM build_queue WHERE ticket_key='TK-88'").get();
  assert.equal(parked.status, 'failed');

  // The hourly stale-owed sweep (bin/stale-owed-tickets.sh:113-116, cron/hub.cron:52)
  // calls rq_put for EVERY queueable key, and a ticket parked for the resolver is
  // exactly the shape its STALE filter selects. The re-offer must bounce off the
  // terminal row: the FILE line still carries the re-offer, as it does today.
  const reoffer = await call(db, '/api/queue',
    { body: { project: 'project-1', key: 'TK-88', status: 'ready',
              meta: JSON.stringify({ ready_line: 'TK-88 OWED-STALE 700h' }) } });
  assert.equal(reoffer.body.duplicate, true,
    'a ready put over a failed row must be refused, not taken');
  assert.equal(reoffer.status, 200);
  const after = db.prepare("SELECT * FROM build_queue WHERE ticket_key='TK-88'").get();
  assert.equal(after.status, 'failed', 'the parked row must still be parked');
  assert.equal(after.reason, parked.reason,
    'the resolver intakes on this string — blanking it removes the ticket from the lane');
  assert.equal(after.finished_at, parked.finished_at, 'a finished build has a finish time');
  assert.equal(after.attempt, parked.attempt, 'the death count is what the retry policy judges');
  assert.equal(after.meta, parked.meta);

  // Same for `done`. bin/blocked-resolver.sh:1169-1179 takes the outcome of a
  // remote rebuild off `queue_list "$p" done`, reading the RESULT line out of
  // column 9 (`reason`); a blanked reason is an outcome nothing ever consumes.
  await call(db, '/api/queue', { body: { project: 'project-1', key: 'TK-90' } });
  await call(db, '/api/queue', { method: 'PATCH',
    body: { project: 'project-1', key: 'TK-90', status: 'done',
            reason: 'RESULT: PR_CREATED | https://github.com/x/y/pull/9' } });
  const finished = db.prepare("SELECT * FROM build_queue WHERE ticket_key='TK-90'").get();
  const again = await call(db, '/api/queue',
    { body: { project: 'project-1', key: 'TK-90', status: 'ready' } });
  assert.equal(again.body.duplicate, true);
  const still = db.prepare("SELECT * FROM build_queue WHERE ticket_key='TK-90'").get();
  assert.equal(still.status, 'done');
  assert.equal(still.reason, finished.reason);
  assert.equal(still.finished_at, finished.finished_at);

  // PATCH cannot walk a terminal row back to ready either — one refusal, two
  // doors, so a future caller cannot reach the same rewrite the other way.
  for (const key of ['TK-88', 'TK-90']) {
    const walked = await call(db, '/api/queue',
      { method: 'PATCH', body: { project: 'project-1', key, status: 'ready' } });
    assert.equal(walked.status, 409, `${key}: a terminal row must not PATCH back to ready`);
  }

  // A terminal row is still RE-QUEUEABLE as a build, exactly as before this
  // slice: `queued` is how a died ticket is retried and nothing here changed it.
  const retried = await call(db, '/api/queue', { body: { project: 'project-1', key: 'TK-88' } });
  assert.equal(retried.body.duplicate, false);
  assert.equal(db.prepare("SELECT status FROM build_queue WHERE ticket_key='TK-88'").get().status, 'queued');
  db.close();
});

test('closeout_aged: the INSERT is the dedupe, and the answer says which happened', async (t) => {
  const db = await openDb(t);
  if (!db) return;

  const first = await call(db, '/api/closeout-aged',
    { body: { project: 'project-1', build_dir: 'project-1-TK-88-202607', result_head: 'PR_CREATED |',
              reason: 'aged-out >168h (652h)', actor: 'hub' } });
  assert.equal(first.status, 201);
  assert.equal(first.body.recorded, true);
  assert.equal(first.body.duplicate, false);

  const again = await call(db, '/api/closeout-aged',
    { body: { project: 'project-1', build_dir: 'project-1-TK-88-202607', reason: 'aged-out >168h (900h)' } });
  assert.equal(again.status, 200, 'deciding twice is not a failure');
  assert.equal(again.body.recorded, false);
  assert.equal(again.body.duplicate, true);

  const rows = db.prepare('SELECT * FROM closeout_aged').all();
  assert.equal(rows.length, 1, 'ON CONFLICT DO NOTHING is the whole dedupe');
  assert.equal(rows[0].reason, 'aged-out >168h (652h)',
    'the FIRST decision stands — a re-record must not overwrite why the fleet decided');
  assert.equal(rows[0].project, 'project-1');
  assert.equal(rows[0].recorded_by, 'hub');

  const miss = await call(db, '/api/closeout-aged', { body: { project: 'project-1' } });
  assert.equal(miss.status, 400, 'a row with no build dir is a decision about nothing');

  const one = await call(db, '/api/closeout-aged?build_dir=project-1-TK-88-202607', { method: 'GET' });
  assert.equal(one.body.aged.length, 1);
  const none = await call(db, '/api/closeout-aged?build_dir=never-seen', { method: 'GET' });
  assert.equal(none.body.aged.length, 0, 'an unknown dir is an EMPTY list, never an error');
  db.close();
});

test('the closeout routes are behind HARNESS_SECRET like every other', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const req = new Request('https://jobs.test/api/closeout-aged', {
    method: 'POST',
    headers: { authorization: 'Bearer wrong', 'content-type': 'application/json' },
    body: JSON.stringify({ build_dir: 'x' }),
  });
  const res = await worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 401);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM closeout_aged').get().n, 0);
  db.close();
});

// ── THE BELT: the table self-creates, it does not wait for a deploy (BH-658) ──
// The repo's rule, spelled out in the CREATED_TABLES comment: two mechanisms,
// one rule — a route never runs ahead of its table in silence. Mechanism one is
// bin/harness-sync.sh applying schema.sql before `wrangler deploy` (BH-1000);
// mechanism two is the worker creating its own table on first use. Without the
// second, a D1 the hand-applied schema never reached answers this family with a
// THROWN `no such table: closeout_aged` — a Cloudflare 1101, not a status a
// caller can read — where `settings` answers 503 and `alerts` self-creates.
//
// The DB below never runs schema.sql. That is the whole point: this is the
// empty-database shape, and every assertion here is about what the route does
// before any operator has touched anything.
async function openBareDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  return new DatabaseSync(':memory:');   // no db.exec(SCHEMA) — deliberately
}

test('closeout-aged answers on a database schema.sql never reached', async (t) => {
  const db = await openBareDb(t);
  if (!db) return;

  const first = await call(db, '/api/closeout-aged',
    { body: { project: 'project-1', build_dir: 'project-1-TK-88-202607',
              reason: 'aged-out >168h (652h)', actor: 'hub' } });
  assert.equal(first.status, 201, 'the POST must create its own table, not throw a 1101');
  assert.equal(first.body.recorded, true);

  // The dedupe is the same dedupe on a table the worker made: the belt must not
  // buy a route that answers but forgets.
  const again = await call(db, '/api/closeout-aged',
    { body: { project: 'project-1', build_dir: 'project-1-TK-88-202607' } });
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);

  const one = await call(db, '/api/closeout-aged?build_dir=project-1-TK-88-202607', { method: 'GET' });
  assert.equal(one.status, 200);
  assert.equal(one.body.aged.length, 1);
  db.close();
});

test('the GET half self-creates too — a read before any write is an empty list', async (t) => {
  const db = await openBareDb(t);
  if (!db) return;
  const none = await call(db, '/api/closeout-aged', { method: 'GET' });
  assert.equal(none.status, 200, 'a read on an untouched D1 is [], never a thrown 1101');
  assert.deepEqual(none.body.aged, []);
  db.close();
});

test('CREATED_TABLES.closeout_aged creates the same columns as schema.sql', async (t) => {
  const db = await openBareDb(t);
  if (!db) return;

  const start = SCHEMA.search(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+closeout_aged\s*\(/is);
  assert.ok(start !== -1, 'schema.sql must contain CREATE TABLE IF NOT EXISTS closeout_aged');
  const paren = start + SCHEMA.slice(start).indexOf('(');
  let depth = 0, end = -1;
  for (let i = paren; i < SCHEMA.length; i++) {
    if (SCHEMA[i] === '(') depth++;
    else if (SCHEMA[i] === ')') { depth--; if (depth === 0) { end = i; break; } }
  }
  assert.ok(end !== -1, 'could not find the matching close paren for closeout_aged');
  const expected = SCHEMA.slice(paren + 1, end).split('\n')
    .map((s) => s.trim())
    .filter((s) => s && !s.startsWith('--'))
    .map((s) => {
      const parts = s.replace(/,\s*$/, '').split(/\s+/);
      return {
        name: parts[0],
        type: parts.slice(1).join(' ').replace(/--.*/, '').replace(/,\s*$/, '').trim(),
      };
    });

  const env = { DB: sqliteDB(db) };
  await ensureTable(env, 'closeout_aged');
  await ensureTable(env, 'closeout_aged');   // idempotent, and cached as done

  const got = db.prepare('PRAGMA table_info(closeout_aged)').all();
  assert.equal(got.length, expected.length,
    `column count: ${got.map((c) => c.name).join(',')} vs schema.sql`);
  for (let i = 0; i < expected.length; i++) {
    assert.equal(got[i].name, expected[i].name, `column ${i}`);
    assert.equal(String(got[i].type).toUpperCase(), expected[i].type.split(/\s+/)[0].toUpperCase(),
      `type for ${got[i].name}`);
  }
  // NOT NULL on `at` is what stops a row with no clock, and the mirror has to
  // carry it or the two shapes diverge the first time a bind is wrong.
  const at = got.find((c) => c.name === 'at');
  assert.ok(at && Number(at.notnull) === 1, '`at` must be NOT NULL in the worker mirror too');

  // The index schema.sql ships is part of the shape: a read-back by project
  // with no index is a table scan on the one table that grows forever.
  const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='closeout_aged'").all();
  assert.ok(idx.map((r) => r.name).includes('idx_closeout_aged_project'),
    'CREATED_TABLES.closeout_aged must create idx_closeout_aged_project as well');
  db.close();
});
