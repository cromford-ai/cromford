// BH-7261 (BH-7244.3): the PM grooming brief routes (src/routes/pm-brief.js).
//
// Every case drives the REAL worker.fetch and route table (D2) over the
// composed jobs schema in node:sqlite (test/lib/d1-sqlite.bh-1030.js). The
// clock is pinned (D60). Each case seeds its own project and ids.
//
// W1  approve ideas -> next: lane next, version +1, updated_at = t, exactly one
//     `moved` event (from ideas, to next, actor pm-brief), move approved
// W1b reject: move rejected; the idea row and its events are unchanged
// W2  approve calls no fetch and writes no roadmap_links, roadmap_waves or jobs row
// W3  another project's name: GET is brief:null with 0 moves; decide is 404
//     and nothing changes
// W4  the idea left from_col before the approve: move stale, applied:false,
//     the idea unchanged, no pm-brief event
// W5  two claims and two creates for one (project, week): 1 row; a second
//     approve is 409 and there is still 1 event
// W6  EXPLAIN QUERY PLAN at seeded volume (500 briefs, 5,000 moves): every hot
//     read uses its index and no plan scans pm_briefs or pm_moves
// W7  the body bin/pm-groom.sh writes (the G1 fixture) round-trips field for
//     field; with no week, GET answers the newest week, not the newest row
// W8  retention: 366 d is archived then deleted, 364 d stays, an unbound
//     archive deletes nothing
// W9  validation: to_col now or shipped is 400 and writes nothing; a create on
//     a row that is not claimed is 409; fail, sent and force
// W11 knobs: pm.moves_max caps a create, pm.weeks_shown caps the weeks GET lists
// W10 the schema fragment creates no roadmap_* or ideas table
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const P = await import('../src/routes/pm-brief.js').catch(() => ({}));
const { RULES } = await import('../src/routes/retention.js');

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-19T11:05:00Z');
const NOW = '2026-10-19T11:05:00Z';
const LATER_MS = NOW_MS + 3600e3;
const LATER = '2026-10-19T12:05:00Z';
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const WEEK = '2026-W43';
const SCHEMA_FRAGMENT = new URL('../schema.d/202610291810-bh-7261-pm-briefs.sql', import.meta.url);

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return o;
}
async function call(env, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { ...env, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const claim = (o, b) => call(o, 'POST', '/api/pm/briefs/claim', { input_fp: 'fp-fixture', model: 'model-fixture', ...b });
const create = (o, b) => call(o, 'POST', '/api/pm/briefs', b);
const getBrief = (o, project, week) =>
  call(o, 'GET', `/api/pm/briefs?${new URLSearchParams({ project, ...(week ? { week } : {}) })}`);
const decide = (o, b) => call(o, 'POST', '/api/pm/moves/decide', { actor: 'console', ...b });

function idea(db, project, id, lane = 'ideas', version = 1) {
  db.prepare(`INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at)
              VALUES (?, ?, ?, 'operator', ?, ?, 'operator', ?, ?)`).run(id, project, `Idea ${id}`, lane, version, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');
}
const ideaRow = (db, id) => ({ ...db.prepare('SELECT * FROM roadmap_ideas WHERE id = ?').get(id) });
const eventsOf = (db, id) => db.prepare('SELECT * FROM roadmap_idea_events WHERE idea_id = ? ORDER BY id').all(id).map((e) => ({ ...e }));
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const BODY = (over = {}) => ({
  summary: 'Two ideas are stale. Move the import idea up.',
  stale: [], stale_partial: false, scores: [], now: [], next_wave: [], snapshot_hash: 'hash-fixture', ...over,
});

// A ready brief for <project> with the given moves, through the real routes.
async function readyBrief(o, project, moves, week = WEEK) {
  const c = await claim(o, { project, week });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.claimed, true);
  const r = await create(o, { project, week, body: BODY(), moves });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body;
}
const MOVE = (idea_id, from_col = 'ideas', to_col = 'next') =>
  ({ idea_id, from_col, to_col, reason: 'cited by the signals', evidence: ['signal.fixture-1'] });

test('W1 approve ideas -> next moves the idea, +1 version, one moved event by pm-brief, move approved', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw1', 'i-w1');
  const b = await readyBrief(o, 'pw1', [MOVE('i-w1')]);
  assert.equal(b.moves.length, 1);
  const before = eventsOf(o.db, 'i-w1').length;
  t.mock.timers.setTime(LATER_MS);
  const r = await decide(o, { project: 'pw1', move_id: b.moves[0].id, decision: 'approve' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.applied, true);
  assert.equal(r.body.move.status, 'approved');
  assert.equal(r.body.move.decided_by, 'console');
  assert.equal(r.body.move.decided_at, LATER);
  const row = ideaRow(o.db, 'i-w1');
  assert.equal(row.lane, 'next');
  assert.equal(row.version, 2);
  assert.equal(row.updated_at, LATER);
  assert.equal(r.body.idea.lane, 'next');
  const ev = eventsOf(o.db, 'i-w1');
  assert.equal(ev.length, before + 1);
  const e = ev[ev.length - 1];
  assert.equal(e.kind, 'moved');
  assert.equal(e.from_lane, 'ideas');
  assert.equal(e.to_lane, 'next');
  assert.equal(e.actor, 'pm-brief');
  assert.equal(e.project, 'pw1');
  assert.equal(e.at, LATER);
  assert.match(e.reason, new RegExp(b.moves[0].id.replace(/[.]/g, '\\.')));
  assert.equal(JSON.parse(e.detail).decided_by, 'console');
  // The only move is decided, so the brief carries decided_at.
  assert.equal(o.db.prepare('SELECT decided_at FROM pm_briefs WHERE project = ?').get('pw1').decided_at, LATER);
});

test('W1b reject: move rejected, the idea and its events unchanged', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw1b', 'i-w1b');
  const b = await readyBrief(o, 'pw1b', [MOVE('i-w1b'), MOVE('i-w1b-other', 'next', 'discarded')]);
  const before = ideaRow(o.db, 'i-w1b');
  const evBefore = count(o.db, 'roadmap_idea_events');
  const r = await decide(o, { project: 'pw1b', move_id: b.moves[0].id, decision: 'reject' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.move.status, 'rejected');
  assert.equal(r.body.applied, false);
  assert.deepEqual(ideaRow(o.db, 'i-w1b'), before);
  assert.equal(count(o.db, 'roadmap_idea_events'), evBefore);
  // One move is still proposed: the brief is not decided yet.
  assert.equal(o.db.prepare('SELECT decided_at FROM pm_briefs WHERE project = ?').get('pw1b').decided_at, null);
});

test('W2 approve calls no fetch and writes no link, wave or job row', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw2', 'i-w2');
  const b = await readyBrief(o, 'pw2', [MOVE('i-w2')]);
  const counts = () => ['roadmap_links', 'roadmap_waves', 'jobs'].map((x) => count(o.db, x));
  const before = counts();
  const real = globalThis.fetch;
  let fetches = 0;
  globalThis.fetch = async () => { fetches += 1; throw new Error('W2: no fetch allowed'); };
  let r;
  try {
    r = await decide(o, { project: 'pw2', move_id: b.moves[0].id, decision: 'approve' });
  } finally { globalThis.fetch = real; }
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.applied, true);
  assert.equal(fetches, 0);
  assert.deepEqual(counts(), before);
});

test('W3 another project reads 0 rows and cannot decide a move it does not own', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw3a', 'i-w3');
  const b = await readyBrief(o, 'pw3a', [MOVE('i-w3')]);
  const g = await getBrief(o, 'pw3b', WEEK);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.brief, null);
  assert.deepEqual(g.body.moves, []);
  assert.deepEqual(g.body.weeks, []);
  const newest = await getBrief(o, 'pw3b');
  assert.equal(newest.body.brief, null);
  assert.deepEqual(newest.body.moves, []);
  const before = ideaRow(o.db, 'i-w3');
  const evBefore = count(o.db, 'roadmap_idea_events');
  const r = await decide(o, { project: 'pw3b', move_id: b.moves[0].id, decision: 'approve' });
  assert.equal(r.status, 404, JSON.stringify(r.body));
  assert.deepEqual(ideaRow(o.db, 'i-w3'), before);
  assert.equal(count(o.db, 'roadmap_idea_events'), evBefore);
  assert.equal(o.db.prepare('SELECT status FROM pm_moves WHERE id = ?').get(b.moves[0].id).status, 'proposed');
  // The owner still reads its brief.
  const own = await getBrief(o, 'pw3a', WEEK);
  assert.equal(own.body.brief.project, 'pw3a');
  assert.equal(own.body.moves.length, 1);
});

test('W4 the idea moved since the brief: the move is stale and the idea is unchanged', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw4', 'i-w4');
  const b = await readyBrief(o, 'pw4', [MOVE('i-w4')]);
  // A person discards the idea through the real move route first.
  const m = await call(o, 'POST', '/api/roadmap/ideas/move', { id: 'i-w4', project: 'pw4', to_lane: 'discarded', expected_version: 1, actor: 'operator' });
  assert.equal(m.status, 200, JSON.stringify(m.body));
  const before = ideaRow(o.db, 'i-w4');
  const evBefore = eventsOf(o.db, 'i-w4');
  t.mock.timers.setTime(LATER_MS);
  const r = await decide(o, { project: 'pw4', move_id: b.moves[0].id, decision: 'approve' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.applied, false);
  assert.equal(r.body.move.status, 'stale');
  assert.deepEqual(ideaRow(o.db, 'i-w4'), before);
  assert.equal(before.lane, 'discarded');
  assert.deepEqual(eventsOf(o.db, 'i-w4'), evBefore);
  assert.equal(eventsOf(o.db, 'i-w4').filter((e) => e.actor === 'pm-brief').length, 0);
});

test('W4b an edit that kept the lane does not stop the approve (the CAS is on the lane)', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw4b', 'i-w4b');
  const b = await readyBrief(o, 'pw4b', [MOVE('i-w4b')]);
  const e = await call(o, 'POST', '/api/roadmap/ideas/edit', { id: 'i-w4b', project: 'pw4b', note: 'edited', expected_version: 1, actor: 'operator' });
  assert.equal(e.status, 200, JSON.stringify(e.body));
  const r = await decide(o, { project: 'pw4b', move_id: b.moves[0].id, decision: 'approve' });
  assert.equal(r.body.applied, true);
  assert.equal(ideaRow(o.db, 'i-w4b').version, 3);
  assert.equal(ideaRow(o.db, 'i-w4b').lane, 'next');
});

test('W5 one (project, week) is one row; a second approve is 409 with one event', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw5', 'i-w5');
  const c1 = await claim(o, { project: 'pw5', week: WEEK });
  const c2 = await claim(o, { project: 'pw5', week: WEEK });
  assert.equal(c1.body.claimed, true);
  assert.equal(c2.status, 200);
  assert.equal(c2.body.claimed, false);
  assert.equal(c2.body.brief.id, c1.body.brief.id);
  const r1 = await create(o, { project: 'pw5', week: WEEK, body: BODY(), moves: [MOVE('i-w5')] });
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  const r2 = await create(o, { project: 'pw5', week: WEEK, body: BODY(), moves: [MOVE('i-w5'), MOVE('i-w5', 'ideas', 'discarded')] });
  assert.equal(r2.status, 409, JSON.stringify(r2.body));
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM pm_briefs WHERE project = 'pw5'").get().n, 1);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM pm_moves WHERE project = 'pw5'").get().n, 1);
  const a1 = await decide(o, { project: 'pw5', move_id: r1.body.moves[0].id, decision: 'approve' });
  assert.equal(a1.status, 200);
  const a2 = await decide(o, { project: 'pw5', move_id: r1.body.moves[0].id, decision: 'approve' });
  assert.equal(a2.status, 409, JSON.stringify(a2.body));
  assert.equal(a2.body.move.status, 'approved');
  assert.equal(eventsOf(o.db, 'i-w5').filter((e) => e.kind === 'moved').length, 1);
});

test('W6 every hot read uses its index at seeded volume', async (t) => {
  const o = await open(t); if (!o) return;
  const { db } = o;
  for (const k of ['BRIEF_WEEK_SQL', 'BRIEF_NEWEST_SQL', 'WEEKS_SQL', 'MOVES_WEEK_SQL', 'MOVES_NEWEST_SQL', 'MOVE_ROW_SQL', 'BRIEF_DECIDED_SQL']) {
    assert.equal(typeof P[k], 'string', `pm-brief.js exports ${k}`);
  }
  db.exec('BEGIN');
  const ib = db.prepare(`INSERT INTO pm_briefs (id, project, week, status, body, created_at, updated_at) VALUES (?,?,?,?,?,?,?)`);
  const im = db.prepare(`INSERT INTO pm_moves (id, brief_id, project, idea_id, from_col, to_col, status, evidence, created_at) VALUES (?,?,?,?,?,?,?,?,?)`);
  for (let p = 0; p < 10; p++) {
    for (let w = 0; w < 50; w++) {
      const id = `b-${p}-${w}`;
      const at = iso(NOW_MS - (w * 7 + p) * DAY);
      ib.run(id, `proj-${p}`, `20${String(25 + Math.floor(w / 52)).padStart(2, '0')}-W${String((w % 52) + 1).padStart(2, '0')}`, 'ready', '{}', at, at);
      for (let m = 0; m < 10; m++) im.run(`${id}.m${m}`, id, `proj-${p}`, `i-${m}`, 'ideas', 'next', m % 3 ? 'proposed' : 'approved', '[]', at);
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(count(db, 'pm_briefs'), 500);
  assert.equal(count(db, 'pm_moves'), 5000);
  const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
  const want = [
    ['brief by week', P.BRIEF_WEEK_SQL, ['proj-3', '2025-W10'], 'ux_pm_briefs_project_week'],
    ['newest brief', P.BRIEF_NEWEST_SQL, ['proj-3'], 'ux_pm_briefs_project_week'],
    ['weeks', P.WEEKS_SQL, ['proj-3'], 'ux_pm_briefs_project_week'],
    ['moves by week', P.MOVES_WEEK_SQL, ['proj-3', '2025-W10'], 'idx_pm_moves_brief'],
    ['moves of the newest', P.MOVES_NEWEST_SQL, ['proj-3'], 'idx_pm_moves_brief'],
    ['move by id', P.MOVE_ROW_SQL, ['b-3-10.m1', 'proj-3'], 'sqlite_autoindex_pm_moves_1'],
    ['brief decided', P.BRIEF_DECIDED_SQL, ['b-3-10', 'proj-3', NOW], 'idx_pm_moves_brief'],
  ];
  for (const name of ['pm_briefs.age', 'pm_moves.age']) {
    const r = RULES.find((x) => x.rule === name);
    assert.ok(r, `RULES has ${name}`);
    want.push([name, r.ids, [NOW, 100], name === 'pm_briefs.age' ? 'idx_pm_briefs_created' : 'idx_pm_moves_created']);
  }
  for (const [name, sql, binds, index] of want) {
    const text = plan(sql, binds);
    assert.ok(!/SCAN (pm_briefs|pm_moves)\b/.test(text), `${name} scans a pm table:\n${text}`);
    assert.ok(text.includes(index), `${name} does not use ${index}:\n${text}`);
    // The index gives the order of a project's briefs: no sort pass. (The
    // moves of one brief, at most 50, may sort in memory.)
    if (!name.startsWith('moves')) assert.ok(!/USE TEMP B-TREE/.test(text), `${name} sorts in a temp b-tree:\n${text}`);
  }
});

test('W7 the body pm-groom.sh writes round-trips through create and GET', async (t) => {
  const o = await open(t); if (!o) return;
  // tests/pm-groom.bh-7261-test.sh G1 saves the exact create payload the lane sent.
  const fx = JSON.parse(readFileSync(new URL('./fixtures/pm-brief-create.bh-7261.json', import.meta.url), 'utf8'));
  const project = 'pw7';
  for (const m of fx.moves) idea(o.db, project, m.idea_id, m.from_col);
  const c = await claim(o, { project, week: fx.week });
  assert.equal(c.body.claimed, true);
  const r = await create(o, { ...fx, project });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const g = await getBrief(o, project, fx.week);
  assert.equal(g.status, 200);
  assert.equal(g.body.brief.status, 'ready');
  assert.equal(g.body.brief.sent_mc, 1);
  assert.equal(g.body.brief.sent_tg, 0);
  for (const k of Object.keys(fx.body)) assert.deepEqual(g.body.brief.body[k], fx.body[k], k);
  assert.equal(g.body.moves.length, fx.moves.length);
  fx.moves.forEach((m, i) => {
    const got = g.body.moves[i];
    for (const k of ['idea_id', 'from_col', 'to_col', 'reason']) assert.equal(got[k], m[k], `${i}.${k}`);
    assert.deepEqual(got.evidence, m.evidence, `${i}.evidence`);
    assert.equal(got.status, 'proposed');
    assert.equal(got.title, `Idea ${m.idea_id}`);
    assert.equal(got.idea_lane, m.from_col);
  });
  assert.deepEqual(g.body.weeks.map((w) => w.week), [fx.week]);
  // With no week, GET answers the newest WEEK, even when an older week's row
  // was written later (a --force re-run of last week).
  o.db.prepare(`INSERT INTO pm_briefs (id, project, week, status, body, created_at, updated_at)
                VALUES ('older-week', ?, '2026-W01', 'ready', '{"summary":"old"}', ?, ?)`).run(project, LATER, LATER);
  const n = await getBrief(o, project);
  assert.equal(n.body.week, fx.week);
  assert.equal(n.body.brief.id, g.body.brief.id);
  assert.equal(n.body.moves.length, fx.moves.length);
  assert.deepEqual(n.body.weeks.map((w) => w.week), [fx.week, '2026-W01']);
});

test('W8 retention: 366 d archived then deleted, 364 d kept, unbound archive deletes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  o.db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','','test',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(NOW);
  const seedAt = (id, days) => {
    const at = iso(NOW_MS - days * DAY);
    o.db.prepare(`INSERT INTO pm_briefs (id, project, week, status, body, created_at, updated_at) VALUES (?, 'pw8', ?, 'ready', '{}', ?, ?)`).run(id, id, at, at);
    o.db.prepare(`INSERT INTO pm_moves (id, brief_id, project, idea_id, from_col, to_col, evidence, created_at) VALUES (?, ?, 'pw8', 'i', 'ideas', 'next', '[]', ?)`).run(`${id}.m00`, id, at);
  };
  seedAt('old', 366);
  seedAt('young', 364);
  const run = (env) => call(env, 'POST', '/api/retention/run', {});
  // Unbound first: nothing leaves.
  const u = await run({ DB: o.DB });
  assert.equal(u.status, 200, JSON.stringify(u.body));
  for (const name of ['pm_briefs.age', 'pm_moves.age']) {
    const rr = u.body.rules.find((x) => x.rule === name);
    assert.ok(rr, name);
    assert.equal(rr.removed, 0, name);
  }
  assert.equal(count(o.db, 'pm_briefs'), 2);
  assert.equal(count(o.db, 'pm_moves'), 2);
  const r = await run({ DB: o.DB, ARCHIVE: d1(adb) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rules.find((x) => x.rule === 'pm_briefs.age').removed, 1);
  assert.equal(r.body.rules.find((x) => x.rule === 'pm_moves.age').removed, 1);
  assert.equal(o.db.prepare("SELECT id FROM pm_briefs").all().map((x) => x.id).join(','), 'young');
  assert.equal(o.db.prepare("SELECT id FROM pm_moves").all().map((x) => x.id).join(','), 'young.m00');
  assert.equal(adb.prepare('SELECT id FROM pm_briefs').get().id, 'old');
  assert.equal(adb.prepare('SELECT id FROM pm_moves').get().id, 'old.m00');
  const audit = o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule IN ('pm_briefs.age','pm_moves.age')").get().n;
  assert.ok(audit >= 2, 'one audit row per rule per run');
});

test('W9 validation and status guards', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'pw9', 'i-w9');
  // A create with no claimed row is 409 and writes nothing.
  const noClaim = await create(o, { project: 'pw9', week: WEEK, body: BODY(), moves: [MOVE('i-w9')] });
  assert.equal(noClaim.status, 409, JSON.stringify(noClaim.body));
  assert.equal(count(o.db, 'pm_briefs'), 0);
  const c = await claim(o, { project: 'pw9', week: WEEK });
  assert.equal(c.body.claimed, true);
  for (const to_col of ['now', 'shipped', 'ideas']) {
    const r = await create(o, { project: 'pw9', week: WEEK, body: BODY(), moves: [MOVE('i-w9', 'ideas', to_col)] });
    assert.equal(r.status, 400, `${to_col}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.field, 'moves');
  }
  for (const evidence of [[], ['ok', 3], 'signal.x']) {
    const r = await create(o, { project: 'pw9', week: WEEK, body: BODY(), moves: [{ ...MOVE('i-w9'), evidence }] });
    assert.equal(r.status, 400, JSON.stringify(evidence));
  }
  const badWeek = await claim(o, { project: 'pw9', week: '2026-43' });
  assert.equal(badWeek.status, 400);
  const tooMany = await create(o, { project: 'pw9', week: WEEK, body: BODY(), moves: Array.from({ length: 51 }, () => MOVE('i-w9')) });
  assert.equal(tooMany.status, 400);
  const big = await create(o, { project: 'pw9', week: WEEK, body: BODY({ summary: 'x'.repeat(70000) }), moves: [] });
  assert.equal(big.status, 400);
  assert.equal(count(o.db, 'pm_moves'), 0);
  assert.equal(o.db.prepare('SELECT status FROM pm_briefs').get().status, 'claimed');
  // sent on a claimed row is 409; fail moves claimed -> failed; a failed row is
  // not re-claimed without force, and is with it.
  assert.equal((await call(o, 'POST', '/api/pm/briefs/sent', { project: 'pw9', week: WEEK, channel: 'tg' })).status, 409);
  const f = await call(o, 'POST', '/api/pm/briefs/fail', { project: 'pw9', week: WEEK, error: 'agent-call rc=1' });
  assert.equal(f.status, 200, JSON.stringify(f.body));
  assert.equal(f.body.brief.status, 'failed');
  assert.equal((await claim(o, { project: 'pw9', week: WEEK })).body.claimed, false);
  const forced = await claim(o, { project: 'pw9', week: WEEK, force: true });
  assert.equal(forced.body.claimed, true);
  assert.equal(forced.body.brief.status, 'claimed');
  assert.equal(forced.body.brief.error, null);
  const ok = await create(o, { project: 'pw9', week: WEEK, body: BODY(), moves: [MOVE('i-w9')] });
  assert.equal(ok.status, 201);
  // force never re-opens a ready row.
  const again = await claim(o, { project: 'pw9', week: WEEK, force: true });
  assert.equal(again.body.claimed, false);
  assert.equal(again.body.brief.status, 'ready');
  const s = await call(o, 'POST', '/api/pm/briefs/sent', { project: 'pw9', week: WEEK, channel: 'tg' });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  assert.equal(s.body.brief.sent_tg, 1);
  // decide refuses a bad decision before any read.
  const bad = await decide(o, { project: 'pw9', move_id: ok.body.moves[0].id, decision: 'maybe' });
  assert.equal(bad.status, 400);
});

test('W10 the schema fragment creates only the pm tables', () => {
  const sql = readFileSync(SCHEMA_FRAGMENT, 'utf8');
  const tables = [...sql.matchAll(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+(\w+)/gi)].map((m) => m[1]);
  assert.deepEqual(tables, ['pm_briefs', 'pm_moves']);
  const names = readdirSync(new URL('../schema.d/', import.meta.url)).filter((f) => /bh-7261/.test(f));
  assert.deepEqual(names, ['202610291810-bh-7261-pm-briefs.sql']);
});

test('W11 pm.moves_max and pm.weeks_shown are settings rows', async (t) => {
  const o = await open(t); if (!o) return;
  const knob = (k, v) => o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test',?)`).run(k, v, NOW);
  idea(o.db, 'pw11', 'i-w11a'); idea(o.db, 'pw11', 'i-w11b');
  knob('pm.moves_max', '1');
  assert.equal((await claim(o, { project: 'pw11', week: WEEK })).body.claimed, true);
  const two = await create(o, { project: 'pw11', week: WEEK, body: BODY(), moves: [MOVE('i-w11a'), MOVE('i-w11b')] });
  assert.equal(two.status, 400, JSON.stringify(two.body));
  assert.match(two.body.error, /at most 1 moves/);
  // An out-of-range row falls back to 50.
  knob('pm.moves_max', '0');
  assert.equal((await create(o, { project: 'pw11', week: WEEK, body: BODY(), moves: [MOVE('i-w11a'), MOVE('i-w11b')] })).status, 201);
  for (const w of ['2026-W41', '2026-W42']) {
    await claim(o, { project: 'pw11', week: w });
    await create(o, { project: 'pw11', week: w, body: BODY(), moves: [] });
  }
  knob('pm.weeks_shown', '2');
  const g = await getBrief(o, 'pw11', WEEK);
  assert.deepEqual(g.body.weeks.map((x) => x.week), ['2026-W43', '2026-W42']);
  knob('pm.weeks_shown', 'abc');
  assert.equal((await getBrief(o, 'pw11', WEEK)).body.weeks.length, 3);
});

test('W12 the write limits are settings rows (pm.reason_max_chars, pm.evidence_max, pm.body_max_chars, pm.error_max_chars)', async (t) => {
  const o = await open(t); if (!o) return;
  const knob = (k, v) => o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test',?)`).run(k, v, NOW);
  idea(o.db, 'pw12', 'i-w12a');
  assert.equal((await claim(o, { project: 'pw12', week: WEEK })).body.claimed, true);
  const mv = { ...MOVE('i-w12a'), reason: 'x'.repeat(30), evidence: ['signal.fixture-1', 'signal.fixture-2'] };
  knob('pm.reason_max_chars', '20');
  const r = await create(o, { project: 'pw12', week: WEEK, body: BODY(), moves: [mv] });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /reason must be a string of at most 20 characters/);
  knob('pm.reason_max_chars', '2001'); // out of range: the fallback 500
  knob('pm.evidence_max', '1');
  const e = await create(o, { project: 'pw12', week: WEEK, body: BODY(), moves: [mv] });
  assert.equal(e.status, 400, JSON.stringify(e.body));
  assert.match(e.body.error, /evidence must be 1\.\.1 evidence id strings/);
  knob('pm.evidence_max', '20');
  knob('pm.body_max_chars', '1024');
  const big = await create(o, { project: 'pw12', week: WEEK, body: { ...BODY(), summary: 'y'.repeat(2000) }, moves: [mv] });
  assert.equal(big.status, 400, JSON.stringify(big.body));
  assert.match(big.body.error, /at most 1024 characters of JSON/);
  knob('pm.error_max_chars', '5');
  const f = await call(o, 'POST', '/api/pm/briefs/fail', { project: 'pw12', week: WEEK, error: 'too long' });
  assert.equal(f.status, 400, JSON.stringify(f.body));
  assert.match(f.body.error, /must be 1\.\.5 characters/);
  knob('pm.body_max_chars', 'abc'); // not an integer: the fallback 65536
  assert.equal((await create(o, { project: 'pw12', week: WEEK, body: BODY(), moves: [mv] })).status, 201);
});
