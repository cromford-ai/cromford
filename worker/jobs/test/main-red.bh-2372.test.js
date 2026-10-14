// BH-2372 (BH-2329.1): GET/PUT /api/main-red and the audited
// POST /api/main-red/clear, driven through the REAL router (worker.fetch)
// against a real schema.sql database (the node:sqlite shim). What is pinned
// here is what the rows hold afterwards, not what the handler returned: the
// transition events, the sticky-clear guard, the clear's three writes and the
// refusals that must write nothing.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const TS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const T0 = '2026-09-25T00:00:00Z';

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body) => call(DB, '/api/main-red', { method: 'PUT', body });
const clear = (DB, body) => call(DB, '/api/main-red/clear', { method: 'POST', body });
const flag = (db, name, active) => db.prepare(
  'INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES (?,?,?,?,?)'
).run(name, active, 'detector', 'main is red', T0);
const detail = (db, name, active, sha, extra = {}) => db.prepare(
  `INSERT INTO main_red (name, slug, project, active, sha, workflow, job, run_url, since, reason,
     cleared_sha, cleared_at, cleared_by, clear_reason, updated_at)
   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`
).run(name, 'example-org/x', 'x', active, sha, 'ci', 'test', 'https://gh/run/1', T0, 'red',
  extra.cleared_sha ?? null, extra.cleared_at ?? null, extra.cleared_by ?? null, extra.clear_reason ?? null, T0);
const events = (db, name) => db.prepare(
  'SELECT action, sha, actor, reason, at FROM main_red_events WHERE name=? ORDER BY id').all(name);
const row = (db, table, name) => db.prepare(`SELECT * FROM ${table} WHERE name=?`).get(name);
const snapshot = (db) => JSON.stringify(['pause_flags', 'main_red', 'main_red_events']
  .map((tb) => db.prepare(`SELECT * FROM ${tb} ORDER BY rowid`).all()));

const RED = { name: 'main-red-example-org-cromford', slug: 'example-org/cromford', project: 'cromford',
  workflow: 'harness-ci', job: 'tests', run_url: 'https://github.com/example-org/cromford/actions/runs/1',
  since: '2026-09-25T01:00:00Z', reason: 'tests failed', actor: 'detector' };

test('BH-2372 main-red routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('AT1 PUT writes an event only on a transition: raise, new_sha, green', async () => {
    const { db, DB } = await openDb();
    let res = await put(DB, { ...RED, active: 1, sha: 'aaa' });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.event, 'raise');
    assert.equal(res.body.main_red.active, 1);
    assert.equal(res.body.main_red.sha, 'aaa');
    const r = row(db, 'main_red', RED.name);
    for (const k of ['slug', 'project', 'workflow', 'job', 'run_url', 'since', 'reason']) assert.equal(r[k], RED[k], k);

    res = await put(DB, { ...RED, active: 1, sha: 'aaa' });
    assert.equal(res.status, 200);
    assert.equal(res.body.event, null, 'a still-red republish is not a transition');
    assert.equal(events(db, RED.name).length, 1);

    res = await put(DB, { ...RED, active: 1, sha: 'bbb', job: 'lint' });
    assert.equal(res.body.event, 'new_sha');
    assert.equal(row(db, 'main_red', RED.name).job, 'lint');
    res = await put(DB, { ...RED, active: 0, sha: 'bbb' });
    assert.equal(res.body.event, 'green');
    assert.equal(row(db, 'main_red', RED.name).active, 0);
    assert.deepEqual(events(db, RED.name).map((e) => e.action), ['raise', 'new_sha', 'green']);
    assert.deepEqual(events(db, RED.name).map((e) => e.sha), ['aaa', 'bbb', 'bbb']);
    assert.ok(events(db, RED.name).every((e) => e.actor === 'detector'));

    // 0 -> 0 on a fresh name: the row lands, no event.
    res = await put(DB, { name: 'main-red-quiet', active: 0, sha: 'z' });
    assert.equal(res.status, 200);
    assert.equal(res.body.event, null);
    assert.equal(events(db, 'main-red-quiet').length, 0);
    // PUT never writes pause_flags.
    assert.equal(db.prepare('SELECT count(*) AS n FROM pause_flags').get().n, 0);
  });

  await t.test('AT1b PUT refuses kill switches, bad names and a missing active with no write', async () => {
    const { db, DB } = await openDb();
    for (const body of [
      { name: 'main-red-detector-off', active: 1, sha: 'a' },
      { name: 'main-red-pr-pair-off', active: 1, sha: 'a' },
      { name: 'bad name', active: 1, sha: 'a' },
      { name: 'main-red-a/b', active: 1, sha: 'a' },
      { name: 'other-flag', active: 1, sha: 'a' },
    ]) {
      const res = await put(DB, body);
      assert.equal(res.status, 400, body.name);
      assert.equal(res.body.error, 'valid main-red name required');
    }
    const res = await put(DB, { name: RED.name, sha: 'a' });
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'active required');
    assert.equal(db.prepare('SELECT count(*) AS n FROM main_red').get().n, 0);
    assert.equal(db.prepare('SELECT count(*) AS n FROM main_red_events').get().n, 0);
  });

  await t.test('AT2 GET lists active main-red flags joined to detail; ?all=1 every main_red row', async () => {
    const { db, DB } = await openDb();
    flag(db, 'main-red-a', 1); detail(db, 'main-red-a', 1, 'sha-a');
    flag(db, 'main-red-b', 0);
    detail(db, 'main-red-b', 0, 'sha-b', { cleared_sha: 'sha-b', cleared_at: T0, cleared_by: 'operator', clear_reason: 'flake' });
    flag(db, 'main-red-detector-off', 1);
    flag(db, 'main-red-pr-pair-off', 1);
    flag(db, 'other-flag', 1);
    let res = await call(DB, '/api/main-red');
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.deepEqual(res.body.main_red.map((r) => r.name), ['main-red-a']);
    assert.equal(res.body.main_red[0].sha, 'sha-a');
    assert.equal(res.body.main_red[0].project, 'x');
    assert.equal(res.body.main_red[0].run_url, 'https://gh/run/1');
    assert.equal(res.body.truncated, false);
    assert.match(res.body.as_of, TS);

    res = await call(DB, '/api/main-red?all=1');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.main_red.map((r) => r.name), ['main-red-a', 'main-red-b']);
    const b = res.body.main_red.find((r) => r.name === 'main-red-b');
    assert.equal(b.active, 0);
    assert.equal(b.cleared_sha, 'sha-b');
    assert.equal(b.cleared_by, 'operator');
    assert.equal(b.clear_reason, 'flake');
    assert.equal(b.cleared_at, T0);
    assert.equal(res.body.truncated, false);
  });

  await t.test('AT3 clear refusals write nothing; a valid clear writes all three; a retry is 409', async () => {
    const { db, DB } = await openDb();
    flag(db, RED.name, 1); detail(db, RED.name, 1, 'aaa');
    flag(db, 'main-red-idle', 0);
    const before = snapshot(db);
    const refusals = [
      [{ name: RED.name, reason: '', actor: 'operator' }, 400, 'reason required'],
      [{ name: RED.name, reason: '   ', actor: 'operator' }, 400, 'reason required'],
      [{ name: RED.name, reason: 'flake' }, 400, 'actor required'],
      [{ name: RED.name, reason: 'flake', actor: '  ' }, 400, 'actor required'],
      [{ name: 'main-red-detector-off', reason: 'flake', actor: 'operator' }, 400, 'valid main-red name required'],
      [{ name: 'main-red-pr-pair-off', reason: 'flake', actor: 'operator' }, 400, 'valid main-red name required'],
      [{ name: 'foo', reason: 'flake', actor: 'operator' }, 400, 'valid main-red name required'],
      [{ name: 'main-red-idle', reason: 'flake', actor: 'operator' }, 409, 'not red'],
      [{ name: 'main-red-none', reason: 'flake', actor: 'operator' }, 409, 'not red'],
      [{ name: RED.name, reason: 'flake', actor: 'operator', sha: 'zzz' }, 409, 'moved to a new sha'],
    ];
    for (const [body, status, error] of refusals) {
      const res = await clear(DB, body);
      assert.equal(res.status, status, JSON.stringify(body));
      assert.equal(res.body.error, error, JSON.stringify(body));
    }
    assert.equal(snapshot(db), before, 'a refusal wrote a row');

    const long = 'r'.repeat(600);
    const res = await clear(DB, { name: RED.name, reason: `  ${long}  `, actor: 'operator@example.com', sha: 'aaa' });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.cleared, true);
    assert.equal(res.body.flag.active, 0);
    assert.equal(res.body.main_red.active, 0);
    const pf = row(db, 'pause_flags', RED.name);
    assert.equal(pf.active, 0);
    assert.equal(pf.actor, 'operator@example.com');
    assert.ok(pf.reason.startsWith('cleared: '), pf.reason);
    const mr = row(db, 'main_red', RED.name);
    assert.equal(mr.active, 0);
    assert.equal(mr.cleared_sha, 'aaa');
    assert.equal(mr.cleared_by, 'operator@example.com');
    assert.equal(mr.clear_reason.length, 512);
    assert.equal(mr.clear_reason, long.slice(0, 512));
    assert.match(mr.cleared_at, TS);
    let ev = events(db, RED.name);
    assert.deepEqual(ev.map((e) => e.action), ['clear']);
    assert.equal(ev[0].sha, 'aaa');
    assert.equal(ev[0].actor, 'operator@example.com');
    assert.equal(ev[0].reason.length, 512);

    const again = await clear(DB, { name: RED.name, reason: 'again', actor: 'operator' });
    assert.equal(again.status, 409);
    assert.equal(again.body.error, 'not red');
    ev = events(db, RED.name);
    assert.equal(ev.filter((e) => e.action === 'clear').length, 1);

    // Active flag, no detail row: events + pause_flags written, main_red null.
    flag(db, 'main-red-bare', 1);
    const bare = await clear(DB, { name: 'main-red-bare', reason: 'flake', actor: 'operator' });
    assert.equal(bare.status, 200, JSON.stringify(bare.body));
    assert.equal(bare.body.main_red, null);
    assert.equal(row(db, 'pause_flags', 'main-red-bare').active, 0);
    assert.equal(events(db, 'main-red-bare').length, 1);
  });

  await t.test('AT3b the clear batch is guarded: a raced second clear writes no second event', async () => {
    const { db, DB } = await openDb();
    flag(db, RED.name, 1); detail(db, RED.name, 1, 'aaa');
    // Both requests pass the pre-read before either batch runs.
    const [a, b] = await Promise.all([
      clear(DB, { name: RED.name, reason: 'one', actor: 'operator' }),
      clear(DB, { name: RED.name, reason: 'two', actor: 'operator' }),
    ]);
    assert.deepEqual([a.status, b.status].sort(), [200, 409]);
    assert.equal(events(db, RED.name).filter((e) => e.action === 'clear').length, 1);
    const winner = a.status === 200 ? 'one' : 'two';
    assert.equal(row(db, 'main_red', RED.name).clear_reason, winner);
    assert.equal(row(db, 'pause_flags', RED.name).reason, `cleared: ${winner}`);
  });

  await t.test('AT4 sticky clear holds on the cleared sha and yields to a new sha', async () => {
    const { db, DB } = await openDb();
    flag(db, RED.name, 1);
    await put(DB, { ...RED, active: 1, sha: 'aaa' });
    const c = await clear(DB, { name: RED.name, reason: 'flake', actor: 'operator', sha: 'aaa' });
    assert.equal(c.status, 200);
    const n = events(db, RED.name).length;

    let res = await put(DB, { ...RED, active: 1, sha: 'aaa' });
    assert.equal(res.status, 200);
    assert.equal(res.body.cleared, true);
    assert.equal(res.body.main_red.active, 0);
    assert.equal(row(db, 'main_red', RED.name).active, 0);
    assert.equal(events(db, RED.name).length, n, 'the sticky guard wrote an event');

    res = await put(DB, { ...RED, active: 1, sha: 'bbb' });
    assert.equal(res.status, 200);
    assert.equal(res.body.cleared, undefined);
    assert.equal(res.body.event, 'raise');
    const mr = row(db, 'main_red', RED.name);
    assert.equal(mr.active, 1);
    assert.equal(mr.sha, 'bbb');
    assert.equal(mr.cleared_sha, 'aaa', 'PUT must never touch cleared_*');
    assert.equal(mr.cleared_by, 'operator');
    assert.equal(mr.clear_reason, 'flake');
    assert.deepEqual(events(db, RED.name).map((e) => e.action), ['raise', 'clear', 'raise']);
  });

  await t.test('AT5 every written timestamp is YYYY-MM-DDTHH:MM:SSZ', async () => {
    const { db, DB } = await openDb();
    flag(db, RED.name, 1);
    await put(DB, { ...RED, active: 1, sha: 'aaa' });
    await put(DB, { ...RED, active: 1, sha: 'bbb' });
    await clear(DB, { name: RED.name, reason: 'flake', actor: 'operator' });
    const mr = row(db, 'main_red', RED.name);
    assert.match(mr.updated_at, TS);
    assert.match(mr.cleared_at, TS);
    assert.match(row(db, 'pause_flags', RED.name).updated_at, TS);
    const ev = events(db, RED.name);
    assert.equal(ev.length, 3);
    for (const e of ev) assert.match(e.at, TS);
  });

  await t.test('AT6 GET caps at 200 with truncated, both views', async () => {
    const { db, DB } = await openDb();
    for (let i = 0; i < 201; i++) {
      const name = `main-red-p${String(i).padStart(3, '0')}`;
      flag(db, name, 1); detail(db, name, 1, `s${i}`);
    }
    for (const q of ['', '?all=1']) {
      const res = await call(DB, `/api/main-red${q}`);
      assert.equal(res.status, 200);
      assert.equal(res.body.main_red.length, 200, q);
      assert.equal(res.body.truncated, true, q);
    }
    const small = await openDb();
    for (const n of ['main-red-a', 'main-red-b', 'main-red-c']) flag(small.db, n, 1);
    const res = await call(small.DB, '/api/main-red');
    assert.equal(res.body.main_red.length, 3);
    assert.equal(res.body.truncated, false);
  });

  await t.test('AT7 a DB without main_red answers 503 schema not applied on every route', async () => {
    const { db, DB } = await openDb();
    db.exec('DROP TABLE main_red');
    flag(db, RED.name, 1);
    let res = await call(DB, '/api/main-red');
    assert.equal(res.status, 503);
    assert.equal(res.body.error, 'main_red schema not applied');
    res = await put(DB, { ...RED, active: 1, sha: 'a' });
    assert.equal(res.status, 503);
    assert.equal(res.body.error, 'main_red schema not applied');
    res = await clear(DB, { name: RED.name, reason: 'x', actor: 'y' });
    assert.equal(res.status, 503);
    assert.equal(res.body.error, 'main_red schema not applied');
    assert.equal(row(db, 'pause_flags', RED.name).active, 1, 'a failed clear left the flag up');
  });

  await t.test('the schema the suite runs against carries both tables', () => {
    assert.ok(SCHEMA.includes('CREATE TABLE IF NOT EXISTS main_red ('));
    assert.ok(SCHEMA.includes('CREATE TABLE IF NOT EXISTS main_red_events ('));
  });
});
