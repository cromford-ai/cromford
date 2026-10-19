import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb, d1 } from '../lib/d1-sqlite.bh-1030.js';

// BH-7263 (BH-7243.0): the roadmap ideas contract and tracer.
//
// GET and POST /api/roadmap/ideas, driven through the REAL worker.fetch and
// route table (D2) over the composed jobs schema in node:sqlite. Deleting
// test/route-table.d/bh-7243-roadmap-ideas.txt turns every route case here
// into the router's 404. The clock is pinned (D60).
//
// I1 the tracer: POST 201, then GET returns the row with counts.ideas = 1,
//    and exactly one `created` event exists for it
// I2 an unknown project is 400 field=project, 0 rows
// I3 a replay (same key, same payload) is 200 with the same id, still 1 event
// I4 the same key with a different title is 409 with the stored idea
// I5 the same key and payload from another actor is a 200 replay
// I6 the same key in another project is a new idea
// I7 each bad field is a 400 that names it, and writes nothing
// I8 roadmap.list_limit caps the list and sets truncated; limit= is checked
// I9 GET runs ONE batch of 2 statements; lane= filters
// I10 a failed event insert leaves no idea (one atomic batch)
// I11 ensureRoadmapTables creates all 5 tables on a db without them
// I12 a wrong project reads 0 rows
// I13 no bearer is 401

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-17T12:00:00Z');
const NOW = '2026-10-17T12:00:00Z';

const R = await import('../../src/routes/roadmap-ideas.js').catch(() => null);

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  for (const p of ['cromford', 'proj-b']) {
    o.db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?, ?, 0, ?, ?)`)
      .run(p, `o/${p}`, NOW, NOW);
  }
  return o;
}

async function call(DB, method, path, body, { secret = SECRET } = {}) {
  const init = { method, headers: {} };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const post = (DB, b, o) => call(DB, 'POST', '/api/roadmap/ideas', b, o);
const list = (DB, qs, o) => call(DB, 'GET', `/api/roadmap/ideas?${qs}`, undefined, o);
const n = (db, sql, ...b) => db.prepare(sql).get(...b).n;
const ideas = (db) => n(db, 'SELECT COUNT(*) AS n FROM roadmap_ideas');
const events = (db) => n(db, 'SELECT COUNT(*) AS n FROM roadmap_idea_events');
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}

const TRACER = { project: 'cromford', title: 'Roadmap tracer', source: 'operator', idem_key: 't1', actor: 'operator' };

test('I1 the tracer: POST 201, GET returns it with counts.ideas = 1, and one created event', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await post(o.DB, TRACER);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const idea = r.body.idea;
  assert.match(idea.id, /^[0-9a-f-]{36}$/);
  assert.equal(idea.title, 'Roadmap tracer');
  assert.equal(idea.lane, 'ideas');
  assert.equal(idea.source, 'operator');
  assert.equal(idea.created_by, 'operator');
  assert.equal(idea.version, 1);
  assert.equal(idea.created_at, NOW);
  assert.equal(idea.updated_at, NOW);

  const g = await list(o.DB, 'project=cromford');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.project, 'cromford');
  assert.equal(g.body.ideas.length, 1);
  assert.equal(g.body.ideas[0].id, idea.id);
  assert.equal(g.body.ideas[0].title, 'Roadmap tracer');
  assert.deepEqual(g.body.counts, { ideas: 1, next: 0, discarded: 0 });
  assert.equal(g.body.truncated, false);
  assert.equal(g.body.as_of, NOW);

  const ev = o.db.prepare('SELECT kind, to_lane, actor, project, at FROM roadmap_idea_events WHERE idea_id = ?').all(idea.id);
  assert.equal(ev.length, 1);
  assert.deepEqual({ ...ev[0] }, { kind: 'created', to_lane: 'ideas', actor: 'operator', project: 'cromford', at: NOW });
});

test('I2 an unknown project is 400 field=project and writes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await post(o.DB, { ...TRACER, project: 'no-such-project' });
  assert.equal(r.status, 400);
  assert.equal(r.body.field, 'project');
  assert.match(r.body.error, /not a known project/);
  assert.equal(ideas(o.db), 0);
  assert.equal(events(o.db), 0);
});

test('I3 a replay of the same key and payload is 200 with the same id, still 1 event', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, { ...TRACER, note: '' });
  assert.equal(a.status, 201);
  const b = await post(o.DB, TRACER);  // note absent = note "" (both NULL)
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.replay, true);
  assert.equal(b.body.idea.id, a.body.idea.id);
  assert.equal(ideas(o.db), 1);
  assert.equal(events(o.db), 1);
});

test('I4 the same key with a different payload is 409 with the stored idea', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, TRACER);
  const b = await post(o.DB, { ...TRACER, title: 'Another title' });
  assert.equal(b.status, 409, JSON.stringify(b.body));
  assert.match(b.body.error, /idem_key reused with a different payload/);
  assert.equal(b.body.idea.id, a.body.idea.id);
  assert.equal(b.body.idea.title, 'Roadmap tracer');
  const c = await post(o.DB, { ...TRACER, link: 'https://example.com/x' });
  assert.equal(c.status, 409);
  assert.equal(ideas(o.db), 1);
  assert.equal(events(o.db), 1);
});

test('I5 the same key and payload from another actor is a 200 replay', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, TRACER);
  const b = await post(o.DB, { ...TRACER, actor: 'console' });
  assert.equal(b.status, 200);
  assert.equal(b.body.idea.id, a.body.idea.id);
  assert.equal(ideas(o.db), 1);
});

test('I6 the same key in another project is a new idea; no key twice is two ideas', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, TRACER);
  const b = await post(o.DB, { ...TRACER, project: 'proj-b' });
  assert.equal(b.status, 201);
  assert.notEqual(b.body.idea.id, a.body.idea.id);
  const { idem_key: _k, ...noKey } = TRACER;
  assert.equal((await post(o.DB, noKey)).status, 201);
  assert.equal((await post(o.DB, noKey)).status, 201);
  assert.equal(ideas(o.db), 4);
  assert.equal(events(o.db), 4);
});

test('I7 each bad field is a 400 that names it and writes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const { title: _t, ...noTitle } = TRACER;
  const { actor: _a, ...noActor } = TRACER;
  const cases = [
    ['title', noTitle],
    ['title', { ...TRACER, title: '   ' }],
    ['title', { ...TRACER, title: 'x'.repeat(201) }],
    ['title', { ...TRACER, title: 'two\nlines' }],
    ['title', { ...TRACER, title: 7 }],
    ['source', { ...TRACER, source: 'boss' }],
    ['note', { ...TRACER, note: 'x'.repeat(4001) }],
    ['link', { ...TRACER, link: 'ftp://x' }],
    ['link', { ...TRACER, link: 'https://a b' }],
    ['idem_key', { ...TRACER, idem_key: 'a b' }],
    ['actor', { ...TRACER, actor: '' }],
    ['actor', noActor],
    ['project', { ...TRACER, project: 'bad project!' }],
  ];
  for (const [field, body] of cases) {
    const r = await post(o.DB, body);
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(body).slice(0, 80)} -> ${r.status}`);
    assert.equal(r.body.field, field, JSON.stringify(r.body));
    assert.ok(r.body.error.startsWith(field), r.body.error);
  }
  // At the limits it is accepted, never clamped.
  const edge = await post(o.DB, { ...TRACER, idem_key: 'edge', title: '  ' + 'y'.repeat(200) + ' ', note: 'z'.repeat(4000) });
  assert.equal(edge.status, 201, JSON.stringify(edge.body));
  assert.equal(edge.body.idea.title, 'y'.repeat(200));
  assert.equal(edge.body.idea.note.length, 4000);
  assert.equal(ideas(o.db), 1);
});

test('I8 roadmap.list_limit caps the list and sets truncated; limit= is checked', async (t) => {
  const o = await open(t); if (!o) return;
  setting(o.db, 'roadmap.list_limit', '3');
  for (let i = 1; i <= 5; i++) {
    t.mock.timers.setTime(NOW_MS + i * 1000);
    assert.equal((await post(o.DB, { ...TRACER, idem_key: `k${i}`, title: `Idea ${i}` })).status, 201);
  }
  const all = await list(o.DB, 'project=cromford');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.ideas.map((x) => x.title), ['Idea 5', 'Idea 4', 'Idea 3'], 'newest updated_at first');
  assert.equal(all.body.truncated, true);
  assert.equal(all.body.counts.ideas, 5, 'counts are not capped');
  const two = await list(o.DB, 'project=cromford&limit=2');
  assert.equal(two.body.ideas.length, 2);
  assert.equal(two.body.truncated, true);
  const fifty = await list(o.DB, 'project=cromford&limit=50');
  assert.equal(fifty.body.ideas.length, 3, 'a limit above the setting is capped to it');
  for (const bad of ['0', '-1', 'abc', '1.5']) {
    const r = await list(o.DB, `project=cromford&limit=${bad}`);
    assert.equal(r.status, 400, `limit=${bad}`);
    assert.equal(r.body.field, 'limit');
  }
  setting(o.db, 'roadmap.list_limit', 'lots');
  const dflt = await list(o.DB, 'project=cromford');
  assert.equal(dflt.body.ideas.length, 5, 'an unparseable setting falls back to the code default 200');
  assert.equal(dflt.body.truncated, false);
});

test('I9 GET runs one batch of 2 statements; lane= filters; a bad lane or no project is 400', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, TRACER);
  await post(o.DB, { ...TRACER, idem_key: 'k2', title: 'Second' });
  o.db.prepare("UPDATE roadmap_ideas SET lane = 'next' WHERE id = ?").run(a.body.idea.id);
  const batches = [];
  const spy = { prepare: (sql) => o.DB.prepare(sql), batch: (s) => { batches.push(s.length); return o.DB.batch(s); } };
  const g = await list(spy, 'project=cromford&lane=next');
  assert.equal(g.status, 200);
  assert.deepEqual(batches, [2]);
  assert.deepEqual(g.body.ideas.map((x) => x.id), [a.body.idea.id]);
  assert.deepEqual(g.body.counts, { ideas: 1, next: 1, discarded: 0 });
  const bad = await list(o.DB, 'project=cromford&lane=now');
  assert.equal(bad.status, 400);
  assert.equal(bad.body.field, 'lane');
  const none = await list(o.DB, '');
  assert.equal(none.status, 400);
  assert.equal(none.body.field, 'project');
});

test('I10 a failed event insert leaves no idea: insert and event are one atomic batch', async (t) => {
  const hooks = {
    beforeRun(sql) { if (/INSERT INTO roadmap_idea_events/.test(sql)) throw new Error('forced event failure'); },
  };
  const o = await open(t, hooks); if (!o) return;
  // D1 runs a batch as one transaction; the node:sqlite shim does not, so the
  // binding here adds it. Two separate run() calls would still leave a row.
  const DB = {
    prepare: (sql) => o.DB.prepare(sql),
    async batch(stmts) {
      o.db.exec('BEGIN');
      try { const r = await o.DB.batch(stmts); o.db.exec('COMMIT'); return r; } catch (e) { o.db.exec('ROLLBACK'); throw e; }
    },
  };
  const r = await post(DB, TRACER);
  assert.notEqual(r.status, 201);
  assert.equal(r.status, 503, JSON.stringify(r.body));
  assert.equal(ideas(o.db), 0);
  assert.equal(events(o.db), 0);
});

test('I11 ensureRoadmapTables creates all 5 tables on a db without them; validateIdea is exported', async () => {
  assert.ok(R, 'src/routes/roadmap-ideas.js must exist');
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  await R.ensureRoadmapTables({ DB: d1(db) });
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'roadmap_%' ORDER BY name").all().map((x) => x.name);
  assert.deepEqual(names, ['roadmap_decisions', 'roadmap_idea_events', 'roadmap_ideas', 'roadmap_links', 'roadmap_waves']);
  assert.deepEqual([...R.ROADMAP_TABLES].sort(), names);
  const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name = 'idx_roadmap_ideas_project_lane_updated'").all();
  assert.equal(idx.length, 1, 'the indexes come with the tables');
  assert.deepEqual(R.validateIdea({ title: 'x' }, { partial: true }), { idea: { title: 'x' } });
  assert.equal(R.validateIdea({ title: 'x' }).field, 'project');
  assert.equal(R.validateIdea({ source: 'boss' }, { partial: true }).field, 'source');
});

test('I12 a wrong project reads 0 rows and zero counts', async (t) => {
  const o = await open(t); if (!o) return;
  await post(o.DB, TRACER);
  const g = await list(o.DB, 'project=proj-b');
  assert.equal(g.status, 200);
  assert.deepEqual(g.body.ideas, []);
  assert.deepEqual(g.body.counts, { ideas: 0, next: 0, discarded: 0 });
});

test('I13 no bearer is 401 on both routes', async (t) => {
  const o = await open(t); if (!o) return;
  assert.equal((await post(o.DB, TRACER, { secret: null })).status, 401);
  assert.equal((await list(o.DB, 'project=cromford', { secret: null })).status, 401);
  assert.equal(ideas(o.db), 0);
});
