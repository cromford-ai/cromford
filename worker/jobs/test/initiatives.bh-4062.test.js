// BH-4062 (BH-3966.1): Archie's initiative register, driven through the REAL
// worker.fetch against the REAL schema.sql (the node:sqlite D1 shim), the way
// cooldowns.bh-2353.test.js does it. What is pinned here is SQL behaviour: the
// slug's ON CONFLICT, the check slot's compare-and-swap on next_check_at, the
// upsert's COALESCEs, the reply's dedupe and the due list's order and cap.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const create = (DB, body) => call(DB, '/api/initiatives', { method: 'POST', body });
const check = (DB, body) => call(DB, '/api/initiatives/check', { method: 'POST', body });
const reply = (DB, body) => call(DB, '/api/initiatives/reply', { method: 'POST', body });
const get = (DB, qs) => call(DB, `/api/initiatives${qs ? `?${qs}` : ''}`);

const BASE = {
  goal: 'Ship the thing',
  metric_query: 'csv:logs/x-rollup.csv#rate@project=cromford',
  cadence_hours: 24,
  escalation_rule: '>= 0.5',
  next_check_at: '2099-10-10T07:00:00Z',
  links: ['https://example.test/a'],
  created_by: 'operator',
};
const rowOf = (db, id) => db.prepare('SELECT * FROM initiatives WHERE id=?').get(id);
const countRows = (db, table) => db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n;
// The seed's due slot, read from the table so the slot under test is schema.sql's, not a copy of it.
const seedDue = (db) => rowOf(db, 1).next_check_at;

test('BH-4062 initiative register', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('I1 every route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const [method, path] of [
      ['POST', '/api/initiatives'], ['GET', '/api/initiatives'], ['POST', '/api/initiatives/check'],
      ['GET', '/api/initiatives/events?key=x'], ['POST', '/api/initiatives/reply'],
    ]) {
      const r = await call(DB, path, { method, body: method === 'POST' ? {} : undefined, secret: null });
      assert.equal(r.status, 401, `${method} ${path}`);
      const w = await call(DB, path, { method, body: method === 'POST' ? {} : undefined, secret: 'wrong' });
      assert.equal(w.status, 401, `${method} ${path} wrong bearer`);
    }
  });

  await t.test('I2 the tracer-first-slicing seed is there, active, with its links', async () => {
    const { DB } = await openDb();
    const r = await get(DB, 'id=1');
    assert.equal(r.status, 200);
    const i = r.body.initiative;
    assert.equal(i.slug, 'tracer-first-slicing');
    assert.equal(i.status, 'active');
    assert.equal(i.cadence_hours, 168);
    assert.equal(i.escalation_rule, 'change');
    assert.equal(i.metric_query, 'csv:logs/outcome-rework-rollup.csv#decomposed_rate@project=cromford');
    assert.equal(i.next_check_at, '2026-10-05T07:00:00Z');
    assert.deepEqual(i.links, [3954, 3955, 3956].map((n) => `https://github.com/example-org/cromford/issues/${n}`));
    assert.equal((await get(DB, 'id=999')).status, 404);
    assert.equal((await get(DB, 'id=abc')).status, 400);
  });

  await t.test('I3 create round-trips every field; replay is existing; a different payload is 409', async () => {
    const { DB, db } = await openDb();
    const c = await create(DB, BASE);
    assert.equal(c.status, 201, JSON.stringify(c.body));
    assert.equal(c.body.ok, true);
    assert.equal(c.body.created, true);
    const i = c.body.initiative;
    assert.equal(i.slug, 'ship-the-thing');
    for (const k of ['goal', 'metric_query', 'cadence_hours', 'escalation_rule', 'next_check_at', 'links', 'created_by']) {
      assert.deepEqual(i[k], BASE[k], k);
    }
    assert.equal(i.status, 'active');
    assert.equal(i.last_value, null);
    assert.deepEqual((await get(DB, `id=${i.id}`)).body.initiative, i);

    // next_check_at and created_by are not payload.
    const again = await create(DB, { ...BASE, next_check_at: '2100-01-01T00:00:00Z', created_by: 'archie' });
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    assert.equal(again.body.initiative.next_check_at, BASE.next_check_at);

    for (const diff of [{ cadence_hours: 25 }, { escalation_rule: 'always' }, { links: [] }, { metric_query: 'none' }]) {
      const r = await create(DB, { ...BASE, ...diff });
      assert.equal(r.status, 409, JSON.stringify(diff));
      assert.match(r.body.error, /ship-the-thing exists with a different payload/);
      assert.equal(r.body.initiative.id, i.id);
    }
    // links absent = [] and is its own payload
    const nl = await create(DB, { ...BASE, goal: 'No links', links: undefined });
    assert.equal(nl.status, 201);
    assert.deepEqual(nl.body.initiative.links, []);
    assert.equal(countRows(db, 'initiatives'), 3);
  });

  await t.test('I4 the slug is normalised once: "Foo  Bar!" and " foo bar" are one initiative', async () => {
    const { DB, db } = await openDb();
    const a = await create(DB, { ...BASE, goal: 'Foo  Bar!' });
    assert.equal(a.status, 201);
    assert.equal(a.body.initiative.slug, 'foo-bar');
    const b = await create(DB, { ...BASE, goal: ' foo bar' });
    assert.equal(b.status, 409, 'a differently-cased goal with the same slug is not a new row');
    assert.equal(b.body.initiative.id, a.body.initiative.id);
    const c = await create(DB, { ...BASE, goal: '  Foo  Bar!  ' });
    assert.equal(c.status, 200, 'the trimmed goal is the stored goal');
    assert.equal(c.body.existing, true);
    assert.equal(countRows(db, 'initiatives'), 2);
    const long = await create(DB, { ...BASE, goal: `${'a'.repeat(63)} b` });
    assert.equal(long.body.initiative.slug, 'a'.repeat(63), 'a trailing dash left by the 64-char cut is stripped');
  });

  await t.test('I5 junk is a 400 naming the field, and writes nothing', async () => {
    const { DB, db } = await openDb();
    const cases = [
      [{ goal: '!!!' }, 'goal'], [{ goal: '' }, 'goal'], [{ goal: 'x'.repeat(301) }, 'goal'], [{ goal: 7 }, 'goal'],
      [{ metric_query: 'csv:logs/../x.csv#a' }, 'metric_query'],
      [{ metric_query: 'csv:/etc/passwd#a' }, 'metric_query'],
      [{ metric_query: 'rm -rf /' }, 'metric_query'],
      [{ metric_query: undefined }, 'metric_query'],
      [{ cadence_hours: 0 }, 'cadence_hours'], [{ cadence_hours: 2161 }, 'cadence_hours'],
      [{ cadence_hours: '24' }, 'cadence_hours'], [{ cadence_hours: 1.5 }, 'cadence_hours'],
      [{ escalation_rule: '>= abc' }, 'escalation_rule'], [{ escalation_rule: 'sometimes' }, 'escalation_rule'],
      [{ next_check_at: 'tomorrow' }, 'next_check_at'], [{ next_check_at: '2099-02-30T00:00:00Z' }, 'next_check_at'],
      [{ links: ['javascript:x'] }, 'links'], [{ links: 'https://a.test' }, 'links'],
      [{ links: Array(11).fill('https://a.test') }, 'links'],
      [{ created_by: '' }, 'created_by'], [{ created_by: 'x'.repeat(65) }, 'created_by'],
    ];
    for (const [patch, field] of cases) {
      const r = await create(DB, { ...BASE, ...patch });
      assert.equal(r.status, 400, JSON.stringify(patch));
      assert.deepEqual(r.body, { error: field }, JSON.stringify(patch));
    }
    assert.equal(countRows(db, 'initiatives'), 1, 'only the seed');
    assert.equal((await create(DB, { ...BASE, metric_query: 'none', escalation_rule: '< -1.25', cadence_hours: 2160 })).status, 201);
  });

  await t.test('I6 the due list: not-due and dropped rows excluded, ordered, capped with truncated', async () => {
    const { DB, db } = await openDb();
    const mk = async (goal, at) => (await create(DB, { ...BASE, goal, next_check_at: at })).body.initiative.id;
    const late = await mk('late', '2026-10-04T00:00:00Z');
    const early = await mk('early', '2026-10-01T00:00:00Z');
    const later = await mk('later', '2026-10-09T00:00:00Z');
    const dropped = await mk('dropped one', '2026-09-01T00:00:00Z');
    db.prepare("UPDATE initiatives SET status='dropped' WHERE id=?").run(dropped);
    const bound = encodeURIComponent(seedDue(db));

    const r = await get(DB, `status=active&due_before=${bound}`);
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.initiatives.map((i) => i.id), [early, late, 1], 'by next_check_at; seed at the bound is due');
    assert.equal(r.body.truncated, false);
    assert.equal(typeof r.body.as_of, 'string');
    assert.ok(!r.body.initiatives.some((i) => i.id === later || i.id === dropped));
    assert.ok(Array.isArray(r.body.initiatives[0].links));

    const capped = await get(DB, `status=active&due_before=${bound}&limit=2`);
    assert.deepEqual(capped.body.initiatives.map((i) => i.id), [early, late]);
    assert.equal(capped.body.truncated, true);
    const exact = await get(DB, `status=active&due_before=${bound}&limit=3`);
    assert.equal(exact.body.truncated, false);

    assert.deepEqual((await get(DB, 'status=dropped')).body.initiatives.map((i) => i.id), [dropped]);
    for (const qs of ['status=paused', 'due_before=now', 'limit=0', 'limit=101', 'limit=x', 'limit=2.5']) {
      const bad = await get(DB, qs);
      assert.equal(bad.status, 400, qs);
      assert.deepEqual(bad.body, { error: qs.split('=')[0] }, qs);
    }
  });

  await t.test('I7 check: a non-advancing slot leaves next_check_at and last_value alone; attempts kept', async () => {
    const { DB, db } = await openDb();
    const due = seedDue(db);
    const r = await check(DB, { id: 1, due_at: due, status: 'model_failed', value: '0.4', body: 'draft', attempts: 1 });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.advanced, false);
    assert.equal(r.body.initiative.next_check_at, due);
    assert.equal(r.body.initiative.last_value, null);
    assert.equal(r.body.initiative.last_check_status, 'model_failed');
    assert.equal(typeof r.body.initiative.last_check_at, 'string');
    assert.equal(r.body.event.dedupe_key, `check:1:${due}`);
    assert.equal(r.body.event.kind, 'check');
    assert.equal(r.body.event.actor, 'archie');
    assert.equal(r.body.event.attempts, 1);

    // retry of the same slot: same event row; absent attempts keeps 1; null body keeps the draft
    const r2 = await check(DB, { id: 1, due_at: due, status: 'unreadable', value: null });
    assert.equal(r2.status, 200);
    assert.equal(r2.body.event.id, r.body.event.id);
    assert.equal(r2.body.event.status, 'unreadable');
    assert.equal(r2.body.event.attempts, 1);
    assert.equal(r2.body.event.body, 'draft');
    assert.equal(r2.body.event.value, null);
    assert.equal(countRows(db, 'initiative_events'), 1);
    assert.equal(rowOf(db, 1).last_value, null);
  });

  await t.test('I8 check: advance moves next_check_at + last_value + the event in one call; stale is 409', async () => {
    const { DB, db } = await openDb();
    const due = seedDue(db);
    const next = '2026-10-12T07:00:00Z';
    const r = await check(DB, { id: 1, due_at: due, status: 'sent', value: '0.61', body: 'msg', attempts: 2, advance_to: next, actor: 'archie-test' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.ok, true);
    assert.equal(r.body.advanced, true);
    assert.equal(r.body.initiative.next_check_at, next);
    assert.equal(r.body.initiative.last_value, '0.61');
    assert.equal(r.body.initiative.last_check_status, 'sent');
    assert.equal(r.body.event.status, 'sent');
    assert.equal(r.body.event.value, '0.61');
    assert.equal(r.body.event.actor, 'archie-test');

    // second advance with the old due_at: 409, nothing changed
    const before = rowOf(db, 1);
    const evBefore = db.prepare('SELECT * FROM initiative_events').all();
    const s = await check(DB, { id: 1, due_at: due, status: 'silent', value: '0.99', advance_to: '2026-10-19T07:00:00Z' });
    assert.equal(s.status, 409);
    assert.equal(s.body.error, 'stale');
    assert.equal(s.body.initiative.next_check_at, next);
    assert.deepEqual(rowOf(db, 1), before);
    assert.deepEqual(db.prepare('SELECT * FROM initiative_events').all(), evBefore);

    // an advance with a null value closes the slot but keeps the closed value
    const n = await check(DB, { id: 1, due_at: next, status: 'unreadable', advance_to: '2026-10-19T07:00:00Z' });
    assert.equal(n.body.advanced, true);
    assert.equal(n.body.initiative.last_value, '0.61');
  });

  await t.test('I9 check: the advancing statements are a CAS — a racing tick that moved the slot wins', async () => {
    const moved = '2099-10-12T07:00:00Z';
    let raced = false;
    const box = {};
    const { DB, db } = await openDb({
      beforeRun(sql) {
        if (!raced && /^\s*INSERT INTO initiative_events/.test(sql)) {
          raced = true;
          box.db.prepare('UPDATE initiatives SET next_check_at=? WHERE id=1').run(moved);
        }
      },
    });
    box.db = db;
    const r = await check(DB, { id: 1, due_at: seedDue(db), status: 'sent', value: '1', advance_to: moved });
    assert.ok(raced);
    assert.equal(r.status, 409);
    assert.equal(r.body.error, 'stale');
    assert.equal(rowOf(db, 1).last_value, null, 'the losing tick did not write last_value');
    assert.equal(countRows(db, 'initiative_events'), 0, 'the losing tick wrote no event');
  });

  await t.test('I10 check: dropped row cannot advance; junk 400; unknown 404', async () => {
    const { DB, db } = await openDb();
    const due = seedDue(db);
    db.prepare("UPDATE initiatives SET status='dropped' WHERE id=1").run();
    const r = await check(DB, { id: 1, due_at: due, status: 'sent', advance_to: '2099-10-12T07:00:00Z' });
    assert.equal(r.status, 409);
    assert.equal(r.body.error, 'stale');
    assert.equal(rowOf(db, 1).next_check_at, due);
    assert.equal(countRows(db, 'initiative_events'), 0);

    const ok = { id: 1, due_at: due, status: 'silent' };
    for (const [patch, field] of [
      [{ id: 0 }, 'id'], [{ id: '1' }, 'id'], [{ due_at: 'x' }, 'due_at'], [{ status: 'done' }, 'status'],
      [{ value: 5 }, 'value'], [{ value: 'x'.repeat(65) }, 'value'], [{ body: 'x'.repeat(4001) }, 'body'],
      [{ attempts: -1 }, 'attempts'], [{ attempts: 101 }, 'attempts'], [{ attempts: '1' }, 'attempts'],
      [{ advance_to: 'later' }, 'advance_to'], [{ actor: '' }, 'actor'], [{ actor: 'x'.repeat(65) }, 'actor'],
    ]) {
      const b = await check(DB, { ...ok, ...patch });
      assert.equal(b.status, 400, JSON.stringify(patch));
      assert.deepEqual(b.body, { error: field });
    }
    assert.equal((await check(DB, { ...ok, id: 999 })).status, 404);
  });

  await t.test('I11 events GET by key', async () => {
    const { DB, db } = await openDb();
    const due = seedDue(db);
    await check(DB, { id: 1, due_at: due, status: 'silent', value: '3' });
    const g = await call(DB, `/api/initiatives/events?key=${encodeURIComponent(`check:1:${due}`)}`);
    assert.equal(g.status, 200);
    assert.equal(g.body.event.value, '3');
    assert.equal((await call(DB, '/api/initiatives/events?key=check:1:nope')).status, 404);
    assert.deepEqual((await call(DB, '/api/initiatives/events')).body, { error: 'key' });
    assert.equal((await call(DB, `/api/initiatives/events?key=${'x'.repeat(201)}`)).status, 400);
  });

  await t.test('I12 reply: 201, replay 200, different payload 409, drop leaves the due list', async () => {
    const { DB, db } = await openDb();
    assert.equal((await reply(DB, { id: 999, decision: 'approve', dedupe_key: 'reply:999:m1', actor: 'operator' })).status, 404);

    const a = await reply(DB, { id: 1, decision: 'approve', note: 'go', dedupe_key: 'reply:1:m1', actor: 'operator' });
    assert.equal(a.status, 201, JSON.stringify(a.body));
    assert.equal(a.body.created, true);
    assert.equal(a.body.initiative.last_decision, 'approve');
    assert.equal(a.body.initiative.last_decision_note, 'go');
    assert.equal(a.body.initiative.status, 'active');

    const same = await reply(DB, { id: 1, decision: 'approve', note: 'go', dedupe_key: 'reply:1:m1', actor: 'operator' });
    assert.equal(same.status, 200);
    assert.equal(same.body.existing, true);
    const diff = await reply(DB, { id: 1, decision: 'change', note: 'go', dedupe_key: 'reply:1:m1', actor: 'operator' });
    assert.equal(diff.status, 409);
    const diffNote = await reply(DB, { id: 1, decision: 'approve', dedupe_key: 'reply:1:m1', actor: 'operator' });
    assert.equal(diffNote.status, 409);
    assert.equal(rowOf(db, 1).last_decision, 'approve');
    assert.equal(countRows(db, 'initiative_events'), 1);

    const d = await reply(DB, { id: 1, decision: 'drop', dedupe_key: 'reply:1:m2', actor: 'operator' });
    assert.equal(d.status, 201);
    assert.equal(d.body.initiative.status, 'dropped');
    assert.equal(d.body.initiative.last_decision_note, null);
    // the table pins a check row's status; a reply row's decision is the route's to validate
    assert.throws(() => db.prepare(
      "INSERT INTO initiative_events (initiative_id, dedupe_key, kind, status, actor, created_at, updated_at) VALUES (1,'k','check','approve','x','t','t')").run(), /CHECK/);
    const due = await get(DB, 'status=active&due_before=2099-01-01T00:00:00Z');
    assert.ok(!due.body.initiatives.some((i) => i.id === 1));

    for (const [patch, field] of [
      [{ dedupe_key: 'reply:2:m3' }, 'dedupe_key'], [{ dedupe_key: 'reply:1:' }, 'dedupe_key'],
      [{ dedupe_key: 'check:1:m3' }, 'dedupe_key'], [{ decision: 'maybe' }, 'decision'],
      [{ note: 'x'.repeat(501) }, 'note'], [{ actor: '' }, 'actor'], [{ id: -1 }, 'id'],
    ]) {
      const b = await reply(DB, { id: 1, decision: 'approve', dedupe_key: 'reply:1:m3', actor: 'operator', ...patch });
      assert.equal(b.status, 400, JSON.stringify(patch));
      assert.deepEqual(b.body, { error: field });
    }
  });

  await t.test('I13 an unapplied schema is a 503 naming the table, not a bodiless 500', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE initiatives');
    const r = await get(DB, 'status=active');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'initiatives schema not applied');
  });

  await t.test('I14 stage.archie mirrors stage.execute rung 0 on claude, with no model literal', async () => {
    const { db } = await openDb();
    const exec0 = db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role='stage.execute' AND position=0").get();
    const archie = db.prepare("SELECT scope, position, model, runner, updated_by FROM model_routes WHERE project IS NULL AND role='stage.archie'").all();
    assert.equal(archie.length, 1);
    assert.equal(archie[0].model, exec0.model);
    assert.equal(archie[0].runner, 'claude');
    assert.equal(archie[0].position, 0);
    assert.equal(archie[0].updated_by, 'seed');
    const stmt = (role) => {
      const m = SCHEMA.match(new RegExp(`INSERT OR IGNORE INTO model_routes[^;]*'${role}'[^;]*;`));
      assert.ok(m, `schema.sql seeds ${role}`);
      return m[0];
    };
    const a = stmt('stage.archie');
    assert.doesNotMatch(a, /claude-|opus|sonnet|haiku/i);
    assert.equal(a.replaceAll('stage.archie', 'R').replace(/'\d{4}-\d{2}-\d{2}T[^']*'/, 'D'),
      stmt('stage.daily-digest').replaceAll('stage.daily-digest', 'R').replace(/'\d{4}-\d{2}-\d{2}T[^']*'/, 'D'));
    // re-applying the whole schema is a no-op for the seeds
    db.exec(SCHEMA);
    assert.equal(db.prepare("SELECT count(*) AS n FROM model_routes WHERE role='stage.archie'").get().n, 1);
    assert.equal(countRows(db, 'initiatives'), 1);
  });
});
