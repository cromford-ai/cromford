import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-7264 (BH-7243.1): move, edit, detail and summary of roadmap ideas.
//
// Every case drives the REAL worker.fetch and route table (D2) over the
// composed jobs schema in node:sqlite. Deleting the 4 new rows from
// test/route-table.d/bh-7243-roadmap-ideas.txt turns each case into the
// router's 404. The clock is pinned (D60).
//
// M1  move ideas -> next at version 1: 200, version 2, one `moved` event
// M2  a second move with the stale version 1: 409 with the stored row, no event
// M3  the same id under another project: 404, the row is unchanged
// M4  discard stamps discarded_at
// M5  restore (-> ideas) and -> next clear discarded_at
// M6  a failed event insert leaves the row unchanged (one atomic batch)
// M7  edit note: 200, version +1, an `edited` event with detail.before.note
// M8  edit with a bad link or with no field: 400, nothing written
// M9  detail: the row and its newest 50 of 60 events; another project: 404
// M10 summary: one row per project, the empty project too, right counts
// M11 a same-lane move at the current version is 200 unchanged with no event;
//     expected_version "2" is accepted, "2a" and 0 are 400
// M12 summary and detail of one project never show another project's rows

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-17T12:00:00Z');
const NOW = '2026-10-17T12:00:00Z';
const LATER_MS = NOW_MS + 60e3;
const LATER = '2026-10-17T12:01:00Z';

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  for (const p of ['cromford', 'proj-b', 'proj-empty']) {
    o.db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?, ?, 0, ?, ?)`)
      .run(p, `o/${p}`, NOW, NOW);
  }
  return o;
}

async function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const add = (DB, b) => call(DB, 'POST', '/api/roadmap/ideas', { project: 'cromford', source: 'operator', actor: 'operator', ...b });
const move = (DB, b) => call(DB, 'POST', '/api/roadmap/ideas/move', { project: 'cromford', actor: 'console', ...b });
const edit = (DB, b) => call(DB, 'POST', '/api/roadmap/ideas/edit', { project: 'cromford', actor: 'console', ...b });
const detail = (DB, id, project = 'cromford') =>
  call(DB, 'GET', `/api/roadmap/ideas/${encodeURIComponent(id)}?project=${encodeURIComponent(project)}`);
const summary = (DB) => call(DB, 'GET', '/api/roadmap/summary');
const row = (db, id) => ({ ...db.prepare('SELECT * FROM roadmap_ideas WHERE id = ?').get(id) });
const eventsOf = (db, id) => db.prepare('SELECT * FROM roadmap_idea_events WHERE idea_id = ? ORDER BY id').all(id).map((e) => ({ ...e }));

async function seedIdea(o, title = 'Ship the roadmap') {
  const r = await add(o.DB, { title });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.idea;
}

test('M1 move ideas -> next: 200, lane next, version 2, one moved event with from and to lanes', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  t.mock.timers.setTime(LATER_MS);
  const r = await move(o.DB, { id: idea.id, to_lane: 'next', expected_version: 1, reason: 'top of the list' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.idea.lane, 'next');
  assert.equal(r.body.idea.version, 2);
  assert.equal(r.body.idea.updated_at, LATER);
  assert.equal(r.body.unchanged, undefined);
  const ev = eventsOf(o.db, idea.id);
  assert.deepEqual(ev.map((e) => e.kind), ['created', 'moved']);
  assert.equal(ev[1].from_lane, 'ideas');
  assert.equal(ev[1].to_lane, 'next');
  assert.equal(ev[1].actor, 'console');
  assert.equal(ev[1].reason, 'top of the list');
  assert.equal(ev[1].project, 'cromford');
  assert.equal(ev[1].at, LATER);
  assert.equal(row(o.db, idea.id).lane, 'next');
});

test('M2 a stale expected_version is 409 with the stored row, and no event is written', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  assert.equal((await move(o.DB, { id: idea.id, to_lane: 'next', expected_version: 1 })).status, 200);
  const r = await move(o.DB, { id: idea.id, to_lane: 'discarded', expected_version: 1 });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.match(r.body.error, /stale version/);
  assert.equal(r.body.idea.id, idea.id);
  assert.equal(r.body.idea.version, 2);
  assert.equal(r.body.idea.lane, 'next');
  assert.equal(eventsOf(o.db, idea.id).length, 2, 'created + moved only');
  assert.equal(row(o.db, idea.id).lane, 'next');
  // A version ahead of the stored one is stale too.
  const ahead = await move(o.DB, { id: idea.id, to_lane: 'ideas', expected_version: 7 });
  assert.equal(ahead.status, 409);
  assert.equal(eventsOf(o.db, idea.id).length, 2);
});

test('M3 the id under another project is 404 and nothing is written', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  const before = row(o.db, idea.id);
  const r = await move(o.DB, { id: idea.id, project: 'proj-b', to_lane: 'next', expected_version: 1 });
  assert.equal(r.status, 404, JSON.stringify(r.body));
  assert.equal(r.body.idea, undefined, 'the other project row is not shown');
  const e = await edit(o.DB, { id: idea.id, project: 'proj-b', note: 'x', expected_version: 1 });
  assert.equal(e.status, 404);
  assert.deepEqual(row(o.db, idea.id), before);
  assert.equal(eventsOf(o.db, idea.id).length, 1);
  const unknown = await move(o.DB, { id: 'no-such-id', to_lane: 'next', expected_version: 1 });
  assert.equal(unknown.status, 404);
});

test('M4 discard stamps discarded_at with the request time', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  t.mock.timers.setTime(LATER_MS);
  const r = await move(o.DB, { id: idea.id, to_lane: 'discarded', expected_version: 1 });
  assert.equal(r.status, 200);
  assert.equal(r.body.idea.discarded_at, LATER);
  assert.equal(row(o.db, idea.id).discarded_at, LATER);
});

test('M5 restore (-> ideas) clears discarded_at, and so does -> next', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await seedIdea(o, 'A');
  const b = await seedIdea(o, 'B');
  for (const x of [a, b]) assert.equal((await move(o.DB, { id: x.id, to_lane: 'discarded', expected_version: 1 })).status, 200);
  const ra = await move(o.DB, { id: a.id, to_lane: 'ideas', expected_version: 2 });
  assert.equal(ra.status, 200);
  assert.equal(ra.body.idea.lane, 'ideas');
  assert.equal(ra.body.idea.discarded_at, null);
  const rb = await move(o.DB, { id: b.id, to_lane: 'next', expected_version: 2 });
  assert.equal(rb.body.idea.discarded_at, null);
  assert.equal(row(o.db, b.id).discarded_at, null);
  assert.deepEqual(eventsOf(o.db, a.id).map((e) => [e.from_lane, e.to_lane]), [[null, 'ideas'], ['ideas', 'discarded'], ['discarded', 'ideas']]);
});

test('M6 a failed event insert leaves the row unchanged: event and update are one batch', async (t) => {
  let fail = false;
  const hooks = { beforeRun(sql) { if (fail && /INSERT INTO roadmap_idea_events/.test(sql)) throw new Error('forced event failure'); } };
  const o = await open(t, hooks); if (!o) return;
  const idea = await seedIdea(o);
  const before = row(o.db, idea.id);
  // D1 runs a batch as one transaction; the node:sqlite shim does not, so
  // this binding adds it (the roadmap-ideas I10 shape).
  const DB = {
    prepare: (sql) => o.DB.prepare(sql),
    async batch(stmts) {
      o.db.exec('BEGIN');
      try { const r = await o.DB.batch(stmts); o.db.exec('COMMIT'); return r; } catch (e) { o.db.exec('ROLLBACK'); throw e; }
    },
  };
  fail = true;
  const r = await move(DB, { id: idea.id, to_lane: 'next', expected_version: 1 });
  assert.notEqual(r.status, 200);
  const e = await edit(DB, { id: idea.id, note: 'n', expected_version: 1 });
  assert.notEqual(e.status, 200);
  assert.deepEqual(row(o.db, idea.id), before);
  assert.equal(eventsOf(o.db, idea.id).length, 1);
});

test('M7 edit note: 200, version +1, an edited event that holds the old value', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  assert.equal((await edit(o.DB, { id: idea.id, note: 'first note', expected_version: 1 })).status, 200);
  t.mock.timers.setTime(LATER_MS);
  const r = await edit(o.DB, { id: idea.id, note: 'second note', title: '  New title ', expected_version: 2, idem_key: 'ignored' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.idea.version, 3);
  assert.equal(r.body.idea.note, 'second note');
  assert.equal(r.body.idea.title, 'New title');
  assert.equal(r.body.idea.updated_at, LATER);
  assert.equal(r.body.idea.idem_key, null, 'idem_key is not editable');
  assert.equal(r.body.idea.lane, 'ideas');
  const ev = eventsOf(o.db, idea.id);
  assert.deepEqual(ev.map((e) => e.kind), ['created', 'edited', 'edited']);
  const d = JSON.parse(ev[2].detail);
  assert.deepEqual(d.before, { title: 'Ship the roadmap', note: 'first note' });
  assert.equal(JSON.parse(ev[1].detail).before.note, null);
  assert.equal(ev[2].actor, 'console');
  // The edit CAS: a stale version is 409 with the stored row.
  const stale = await edit(o.DB, { id: idea.id, note: 'x', expected_version: 2 });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.idea.version, 3);
  assert.equal(eventsOf(o.db, idea.id).length, 3);
  // An empty note is stored as NULL.
  const cleared = await edit(o.DB, { id: idea.id, note: '', expected_version: 3 });
  assert.equal(cleared.status, 200);
  assert.equal(row(o.db, idea.id).note, null);
});

test('M8 edit with a bad field or no field is 400 and writes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  const before = row(o.db, idea.id);
  const cases = [
    ['link', { link: 'ftp://x' }],
    ['title', { title: '' }],
    ['title', { title: 'two\nlines' }],
    ['source', { source: 'boss' }],
    ['title', {}],
    ['actor', { note: 'n', actor: '' }],
    ['expected_version', { note: 'n', expected_version: 0 }],
    ['id', { note: 'n', id: '' }],
  ];
  for (const [field, extra] of cases) {
    const r = await edit(o.DB, { id: idea.id, expected_version: 1, ...extra });
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(extra)} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.equal(r.body.field, field, JSON.stringify(r.body));
  }
  assert.deepEqual(row(o.db, idea.id), before);
  assert.equal(eventsOf(o.db, idea.id).length, 1);
});

test('M9 detail: the row and its newest 50 of 60 events; another project is 404 with no events', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  const ins = o.db.prepare(`INSERT INTO roadmap_idea_events (idea_id, project, kind, from_lane, to_lane, actor, at) VALUES (?, 'cromford', 'moved', 'ideas', 'next', 'operator', ?)`);
  for (let i = 1; i <= 59; i++) ins.run(idea.id, new Date(NOW_MS + i * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'));
  const batches = [];
  const spy = { prepare: (sql) => o.DB.prepare(sql), batch: (s) => { batches.push(s.length); return o.DB.batch(s); } };
  const r = await detail(spy, idea.id);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(batches, [2], 'one batch of 2 statements');
  assert.equal(r.body.idea.id, idea.id);
  assert.equal(r.body.events.length, 50);
  assert.equal(r.body.events[0].at, '2026-10-17T12:00:59Z', 'newest first');
  assert.equal(r.body.events[49].at, '2026-10-17T12:00:10Z');
  assert.ok(!r.body.events.some((e) => e.kind === 'created'), 'the oldest event is past the 50');
  assert.equal(r.body.as_of, NOW);
  const other = await detail(o.DB, idea.id, 'proj-b');
  assert.equal(other.status, 404);
  assert.equal(other.body.events, undefined);
  assert.equal((await detail(o.DB, 'no-such-id')).status, 404);
  assert.equal((await call(o.DB, 'GET', `/api/roadmap/ideas/${idea.id}?project=bad%20project`)).status, 400);
});

test('M10 summary: one row per project with lane counts; an empty project is listed', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await seedIdea(o, 'A');
  await seedIdea(o, 'B');
  const c = await seedIdea(o, 'C');
  await move(o.DB, { id: a.id, to_lane: 'next', expected_version: 1 });
  await move(o.DB, { id: c.id, to_lane: 'discarded', expected_version: 1 });
  assert.equal((await add(o.DB, { project: 'proj-b', title: 'B1' })).status, 201);
  const batches = [];
  const spy = { prepare: (sql) => o.DB.prepare(sql), batch: (s) => { batches.push(s.length); return o.DB.batch(s); } };
  const r = await summary(spy);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(batches, [2], 'one batch of 2 statements');
  assert.deepEqual(r.body.projects.map((p) => p.project), ['cromford', 'proj-b', 'proj-empty']);
  const by = Object.fromEntries(r.body.projects.map((p) => [p.project, p]));
  assert.deepEqual(by['cromford'].counts, { ideas: 1, next: 1, discarded: 1 });
  assert.equal(by['cromford'].total, 3);
  assert.deepEqual(by['proj-b'].counts, { ideas: 1, next: 0, discarded: 0 });
  assert.deepEqual(by['proj-empty'].counts, { ideas: 0, next: 0, discarded: 0 });
  assert.equal(by['proj-empty'].total, 0);
  assert.equal(r.body.as_of, NOW);
});

test('M11 same-lane move is 200 unchanged with no event; "2" is accepted; "2a", 0 and a bad lane are 400', async (t) => {
  const o = await open(t); if (!o) return;
  const idea = await seedIdea(o);
  const same = await move(o.DB, { id: idea.id, to_lane: 'ideas', expected_version: 1 });
  assert.equal(same.status, 200, JSON.stringify(same.body));
  assert.equal(same.body.unchanged, true);
  assert.equal(same.body.idea.version, 1);
  assert.equal(eventsOf(o.db, idea.id).length, 1);
  const str = await move(o.DB, { id: idea.id, to_lane: 'next', expected_version: '1' });
  assert.equal(str.status, 200, JSON.stringify(str.body));
  assert.equal(str.body.idea.version, 2);
  for (const [field, extra] of [
    ['expected_version', { expected_version: '2a' }],
    ['expected_version', { expected_version: 0 }],
    ['expected_version', { expected_version: -1 }],
    ['expected_version', { expected_version: 1.5 }],
    ['expected_version', { expected_version: undefined }],
    ['to_lane', { to_lane: 'now' }],
    ['project', { project: 'bad project!' }],
    ['reason', { reason: 'x'.repeat(501) }],
    ['actor', { actor: '  ' }],
    ['id', { id: 'x'.repeat(81) }],
  ]) {
    const r = await move(o.DB, { id: idea.id, to_lane: 'discarded', expected_version: 2, ...extra });
    assert.equal(r.status, 400, `${field} ${JSON.stringify(extra)} -> ${r.status}`);
    assert.equal(r.body.field, field);
  }
  assert.equal(row(o.db, idea.id).lane, 'next');
  assert.equal(eventsOf(o.db, idea.id).length, 2);
});

test('M12 the wrong tenant reads 0 rows: summary counts and detail stay per project', async (t) => {
  const o = await open(t); if (!o) return;
  const mine = await seedIdea(o, 'Mine');
  const theirs = (await add(o.DB, { project: 'proj-b', title: 'Theirs' })).body.idea;
  const d = await detail(o.DB, mine.id);
  assert.ok(d.body.events.every((e) => e.kind === 'created') && d.body.events.length === 1);
  const cross = await detail(o.DB, theirs.id, 'cromford');
  assert.equal(cross.status, 404);
  const s = await summary(o.DB);
  const by = Object.fromEntries(s.body.projects.map((p) => [p.project, p.total]));
  assert.deepStrictEqual(Object.keys(by).sort(), ['cromford', 'proj-b', 'proj-empty']);
  assert.strictEqual(by['cromford'], 1);
  assert.strictEqual(by['proj-b'], 1);
  assert.strictEqual(by['proj-empty'], 0);
  // A stray event row of another project on the same id is not shown.
  o.db.prepare(`INSERT INTO roadmap_idea_events (idea_id, project, kind, actor, at) VALUES (?, 'proj-b', 'moved', 'x', ?)`).run(mine.id, NOW);
  assert.equal((await detail(o.DB, mine.id)).body.events.length, 1);
});
