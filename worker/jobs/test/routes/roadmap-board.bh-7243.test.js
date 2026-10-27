import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-7265 (BH-7243.2): the roadmap board, hand links and decisions. Every
// route case drives the REAL worker.fetch and the fragment-ordered route table
// (D2) over the composed jobs schema in node:sqlite. Deleting
// test/route-table.d/bh-7243-roadmap-board.txt turns every route case here into
// the router's 404. The clock is pinned (D60).
//
// B0      the composed schema seeds roadmap.render_projects, roadmap.board_links_limit
//         and roadmap.board_running_limit
// B1-B10  the ten rows of the column decision table, through GET board and roadmapColumn
// B10b    edge cases: shipped beats running; an unknown state is the hand lane
// B11     one GET board = ONE batch of 4 statements (plus the settings memo read)
// B12     wrong tenant: another project's ideas, links, jobs and decisions are not in the answer
// B13     truncated.ideas / truncated.links / truncated.running at limit+1 rows
// B13b    a dropped open question takes no decision slot; links of hidden ideas are not read
// B14     the ticket_id parse: a trailing integer, compared exactly
// B15     the committed board fixture is the real route answer for its seed
// L1-L6   POST links and links/remove
// D1-D5   POST decisions and decisions/decide (CAS)

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-17T12:00:00Z');
const NOW = '2026-10-17T12:00:00Z';
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const at = (min) => iso(NOW_MS - min * 60e3);
const P = 'cromford';
const REPO = 'example-org/cromford';
const FIXTURE = new URL('../fixtures/roadmap-board.bh-7243.json', import.meta.url);

const R = await import('../../src/routes/roadmap-board.js').catch(() => null);

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const p = o.db.prepare(`INSERT INTO projects (project, repo, board_api_prefix, cron_offset, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)`);
  p.run(P, REPO, null, NOW, NOW);
  p.run('proj-b', 'o/proj-b', null, NOW, NOW);
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
const board = (DB, project = P) => call(DB, 'GET', `/api/roadmap/board?project=${encodeURIComponent(project)}`);
const post = (DB, path, b) => call(DB, 'POST', `/api/roadmap/${path}`, b);

function idea(db, id, lane, min, { project = P, title = `Idea ${id}`, version = 1 } = {}) {
  db.prepare(`INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at, discarded_at)
              VALUES (?,?,?,?,?,?,?,?,?,?)`).run(id, project, title, 'operator', lane, version, 'operator', at(min), at(min), lane === 'discarded' ? at(min) : null);
}
function link(db, ideaId, issue, state, { project = P, repo = REPO, wave_id = null } = {}) {
  db.prepare(`INSERT INTO roadmap_links (idea_id, project, repo, issue, wave_id, issue_state, created_by, created_at)
              VALUES (?,?,?,?,?,?,'test',?)`).run(ideaId, project, repo, issue, wave_id, state, NOW);
}
function job(db, id, ticket, { project = P, status = 'running' } = {}) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,'build','hub','execute',?,?,?)`).run(id, project, ticket, status, NOW, NOW);
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
// The column each idea id landed in, from a GET board answer ('hidden' when in none).
function columnOf(body, id) {
  for (const [col, cards] of Object.entries(body.columns)) if (cards.some((c) => c.id === id)) return col;
  return 'hidden';
}

// The ten rows of the plan's decision table: [lane, link states, running?, column].
const ROWS = [
  ['ideas', [], null, 'ideas'],
  ['next', [], null, 'next'],
  ['discarded', ['open'], null, null],
  ['ideas', ['open'], null, 'now'],
  ['next', [null], null, 'now'],
  ['ideas', ['closed_completed'], null, 'shipped'],
  ['next', ['closed_completed', 'open'], null, 'now'],
  ['next', ['closed_completed', 'closed_other'], null, 'next'],
  ['ideas', ['closed_other'], 'same', 'now'],
  ['ideas', ['closed_other'], 'other', 'ideas'],
];

test('B0 the composed schema seeds the three board settings rows', async (t) => {
  const o = await open(t); if (!o) return;
  const v = (k) => (o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(v('roadmap.render_projects'), '');
  assert.equal(v('roadmap.board_links_limit'), '2000');
  assert.equal(v('roadmap.board_running_limit'), '500');
});

test('B1-B10 the decision table, through roadmapColumn and through GET board', async (t) => {
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  // Direct: the pure function.
  ROWS.forEach(([lane, states, run, want], i) => {
    const base = 1000 + i * 10;
    const links = states.map((s, k) => ({ issue: base + k, issue_state: s }));
    const running = new Set(run === 'same' ? [base] : run === 'other' ? [base + 5] : []);
    assert.equal(R.roadmapColumn({ lane }, links, running), want, `B${i + 1} direct ${lane} ${JSON.stringify(states)} ${run}`);
  });
  // Through the real route.
  const o = await open(t); if (!o) return;
  ROWS.forEach(([lane, states, run], i) => {
    const id = `b${i + 1}`, base = 1000 + i * 10;
    idea(o.db, id, lane, i + 1);
    states.forEach((s, k) => link(o.db, id, base + k, s));
    if (run === 'same') job(o.db, `job-${id}`, `BH-${base}`);
    if (run === 'other') job(o.db, `job-${id}`, `BH-${base + 5}`);
  });
  const r = await board(o.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  ROWS.forEach(([lane, states, run, want], i) => {
    assert.equal(columnOf(r.body, `b${i + 1}`), want === null ? 'hidden' : want, `B${i + 1} route ${lane} ${JSON.stringify(states)} ${run}`);
  });
});

test('B10b shipped beats a running job; an unknown state and a done job are the hand lane', async (t) => {
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  assert.equal(R.roadmapColumn({ lane: 'ideas' }, [{ issue: 7, issue_state: 'closed_completed' }], new Set([7])), 'shipped');
  assert.equal(R.roadmapColumn({ lane: 'next' }, [{ issue: 7, issue_state: 'closed' }], new Set()), 'next');
  assert.equal(R.roadmapColumn({ lane: 'ideas' }, [{ issue: 7, issue_state: 'closed_completed' }, { issue: 8, issue_state: null }], new Set()), 'now');
  const o = await open(t); if (!o) return;
  idea(o.db, 'e1', 'ideas', 1);
  link(o.db, 'e1', 7, 'closed_other');
  job(o.db, 'job-done', 'BH-7', { status: 'done' });
  const r = await board(o.DB);
  assert.equal(columnOf(r.body, 'e1'), 'ideas', 'a done job is not running');
});

test('B11 one GET board is ONE batch of 4 statements; the settings read is the memo', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'c1', 'ideas', 1);
  const seen = { batches: [], single: [] };
  const wrap = (s, sql) => {
    const w = {
      sql, inner: s,
      bind(...v) { s.bind(...v); return w; },
      first(...a) { seen.single.push(sql); return s.first(...a); },
      all() { seen.single.push(sql); return s.all(); },
      run() { seen.single.push(sql); return s.run(); },
    };
    return w;
  };
  const DB = {
    prepare: (sql) => wrap(o.DB.prepare(sql), sql),
    batch: (stmts) => { seen.batches.push(stmts.map((s) => s.sql)); return o.DB.batch(stmts.map((s) => s.inner)); },
  };
  await board(DB); // the first call creates the roadmap tables once per binding
  seen.batches.length = 0; seen.single.length = 0;
  const r = await board(DB);
  assert.equal(r.status, 200);
  assert.equal(seen.batches.length, 1, `one batch, got ${JSON.stringify(seen.batches)}`);
  assert.equal(seen.batches[0].length, 4);
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  assert.deepEqual(seen.batches[0], [R.BOARD_IDEAS_SQL, R.BOARD_LINKS_SQL, R.BOARD_RUNNING_SQL, R.BOARD_DECISIONS_SQL]);
  assert.deepEqual(seen.single.filter((s) => !/FROM settings/.test(s)), [], 'no statement outside the batch but the settings memo');
});

test('B12 wrong tenant: another project is not in the answer (0 rows)', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'x1', 'ideas', 1, { project: 'proj-b' });
  idea(o.db, 'x2', 'next', 2, { project: 'proj-b' });
  link(o.db, 'x1', 55, 'open', { project: 'proj-b', repo: 'o/proj-b' });
  job(o.db, 'job-x', 'BH-55', { project: 'proj-b' });
  o.db.prepare(`INSERT INTO roadmap_decisions (id, project, kind, title, status, created_at, updated_at) VALUES ('dx','proj-b','open','Q','open',?,?)`).run(NOW, NOW);
  idea(o.db, 'mine', 'ideas', 3);
  link(o.db, 'mine', 55, 'closed_other');
  const r = await board(o.DB);
  assert.equal(r.status, 200);
  const ids = Object.values(r.body.columns).flat().map((c) => c.id);
  assert.deepEqual(ids, ['mine']);
  assert.equal(columnOf(r.body, 'mine'), 'ideas', "proj-b's running job for issue 55 does not move this project's card");
  assert.equal(r.body.decisions.length + r.body.open_decisions.length, 0);
  assert.equal((await board(o.DB, 'bad project!')).status, 400);
});

test('B13 truncated.ideas, truncated.links and truncated.running at limit+1 rows', async (t) => {
  const o = await open(t); if (!o) return;
  setting(o.db, 'roadmap.list_limit', 3);
  setting(o.db, 'roadmap.board_links_limit', 2);
  for (let i = 1; i <= 4; i++) idea(o.db, `t${i}`, 'ideas', i);
  link(o.db, 't1', 1, 'open'); link(o.db, 't2', 2, 'open');
  let r = await board(o.DB);
  assert.equal(r.body.truncated.ideas, true);
  assert.equal(r.body.truncated.links, false);
  assert.equal(Object.values(r.body.columns).flat().length, 3, 'only list_limit cards');
  link(o.db, 't3', 3, 'open');
  r = await board(o.DB);
  assert.equal(r.body.truncated.links, true);
  setting(o.db, 'roadmap.list_limit', 4);
  r = await board(o.DB);
  assert.equal(r.body.truncated.ideas, false);
  assert.equal(r.body.truncated.decisions, false);
  assert.equal(r.body.truncated.running, false);
  setting(o.db, 'roadmap.board_running_limit', 1);
  job(o.db, 'j-t1', 'BH-1'); job(o.db, 'j-t2', 'BH-2');
  r = await board(o.DB);
  assert.equal(r.body.truncated.running, true, 'the running read follows roadmap.board_running_limit');
});

test('B13b dropped open questions take no decision slot; links of hidden ideas are not read', async (t) => {
  const o = await open(t); if (!o) return;
  setting(o.db, 'roadmap.list_limit', 1);
  const dq = o.db.prepare(`INSERT INTO roadmap_decisions (id, project, kind, title, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?)`);
  dq.run('dl', P, 'log', 'Kept', 'decided', at(9), at(9));
  dq.run('dd', P, 'open', 'Dropped', 'dropped', at(1), at(1));
  idea(o.db, 'shown', 'ideas', 1);
  idea(o.db, 'hidden', 'ideas', 5);
  setting(o.db, 'roadmap.board_links_limit', 1);
  link(o.db, 'hidden', 7, 'open'); link(o.db, 'shown', 8, 'open');
  const r = await board(o.DB);
  assert.deepEqual(r.body.decisions.map((d) => d.id), ['dl'], 'the dropped question does not push the log entry off');
  assert.equal(r.body.truncated.decisions, false);
  assert.equal(columnOf(r.body, 'shown'), 'now', "the shown idea's link is read");
  assert.equal(r.body.truncated.links, false, "the hidden idea's link takes no links slot");
});

test('B14 the ticket_id parse is the trailing integer, compared exactly', () => {
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  assert.equal(R.ticketIssue('BH-7265'), 7265);
  assert.equal(R.ticketIssue('7265'), 7265);
  assert.equal(R.ticketIssue('example-org/cromford#12'), 12);
  assert.equal(R.ticketIssue('BH-'), null);
  assert.equal(R.ticketIssue(null), null);
  const running = new Set([R.ticketIssue('BH-72650')]);
  assert.equal(R.roadmapColumn({ lane: 'ideas' }, [{ issue: 7265, issue_state: 'closed_other' }], running), 'ideas', '72650 is not 7265');
});

// The seed the committed fixture (test/fixtures/roadmap-board.bh-7243.json)
// was captured from. console-ui/tests/roadmap-board.bh-7243.test.js and
// tests/roadmap-render.bh-7243-test.sh read that file, so both readers of the
// board answer are tested on the shape the route writes (D4).
function fixtureSeed(db) {
  idea(db, 'f1', 'ideas', 50, { title: 'Bravo idea' });
  idea(db, 'f2', 'next', 40, { title: 'Charlie idea', version: 2 });
  idea(db, 'f3', 'ideas', 30, { title: 'Delta idea' });
  idea(db, 'f4', 'next', 20, { title: 'Echo idea' });
  idea(db, 'f5', 'ideas', 10, { title: 'Alpha idea' });
  idea(db, 'f6', 'discarded', 5, { title: 'Gone idea' });
  link(db, 'f3', 101, 'open');
  link(db, 'f3', 103, null);
  link(db, 'f4', 102, 'closed_completed', { wave_id: 'w1' });
  job(db, 'job-101', 'BH-101');
  db.prepare(`INSERT INTO roadmap_decisions (id, project, kind, title, body, status, created_by, decided_by, created_at, updated_at, decided_at)
              VALUES ('d1',?, 'log', 'Ship the board first', 'The wave view waits.', 'decided', 'operator', 'operator', ?, ?, ?)`).run(P, at(60), at(60), at(60));
  db.prepare(`INSERT INTO roadmap_decisions (id, project, kind, title, body, status, created_by, created_at, updated_at)
              VALUES ('d2',?, 'open', 'Render cadence', 'Daily or on change?', 'open', 'operator', ?, ?)`).run(P, at(30), at(30));
}

test('B15 the committed board fixture is the real route answer for its seed', async (t) => {
  const o = await open(t); if (!o) return;
  fixtureSeed(o.db);
  const r = await board(o.DB);
  assert.equal(r.status, 200);
  // An operator refreshes the fixture with ROADMAP_BOARD_FIXTURE_WRITE=1; a test run only reads it.
  if (process.env.ROADMAP_BOARD_FIXTURE_WRITE === '1') writeFileSync(FIXTURE, `${JSON.stringify(r.body, null, 2)}\n`);
  const want = JSON.parse(readFileSync(FIXTURE, 'utf8'));
  // Every value the fixture holds is the route's value (a key a later ticket
  // adds to the answer does not make the fixture stale).
  const stale = [];
  const within = (got, exp, path) => {
    if (exp && typeof exp === 'object') {
      if (!got || typeof got !== 'object' || Array.isArray(exp) !== Array.isArray(got)) { stale.push(path); return; }
      if (Array.isArray(exp) && exp.length !== got.length) { stale.push(`${path}.length`); return; }
      for (const k of Object.keys(exp)) within(got[k], exp[k], `${path}.${k}`);
    } else if (got !== exp) stale.push(path);
  };
  within(r.body, want, 'board');
  assert.deepEqual(stale, [], 'the fixture is stale: rerun with ROADMAP_BOARD_FIXTURE_WRITE=1');
  // The owned fields, by name.
  assert.deepEqual(Object.fromEntries(Object.entries(r.body.columns).map(([k, v]) => [k, v.map((c) => c.id)])),
    { ideas: ['f5', 'f1'], next: ['f2'], now: ['f3'], shipped: ['f4'] });
  const now = r.body.columns.now[0];
  assert.deepEqual(now.links.map((l) => [l.issue, l.issue_state, l.ticket, l.url]), [
    [101, 'open', 'BH-101', `https://github.com/${REPO}/issues/101`],
    [103, null, null, `https://github.com/${REPO}/issues/103`],
  ]);
  assert.equal(r.body.columns.next[0].version, 2);
  assert.deepEqual(r.body.decisions.map((d) => d.id), ['d1']);
  assert.deepEqual(r.body.open_decisions.map((d) => d.id), ['d2']);
});

// ── links ───────────────────────────────────────────────────────────────────
const linkRows = (db) => db.prepare('SELECT idea_id, project, repo, issue, wave_id, issue_state, created_by FROM roadmap_links ORDER BY idea_id, issue').all();
const events = (db, kind) => db.prepare('SELECT idea_id, project, kind, actor, detail FROM roadmap_idea_events WHERE kind = ? ORDER BY id').all(kind);

test('L1 a hand link to an open-state idea puts it in now (the observable outcome)', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'i1', 'ideas', 1);
  let r = await board(o.DB);
  assert.equal(columnOf(r.body, 'i1'), 'ideas');
  const w = await post(o.DB, 'links', { idea_id: 'i1', project: P, issue: 42, actor: 'operator@example.com' });
  assert.equal(w.status, 201, JSON.stringify(w.body));
  assert.equal(w.body.link.repo, REPO, 'the repo comes from projects');
  assert.equal(w.body.link.issue, 42);
  assert.equal(w.body.link.issue_state, null);
  r = await board(o.DB);
  assert.equal(columnOf(r.body, 'i1'), 'now');
  assert.equal(r.body.columns.now[0].links[0].url, `https://github.com/${REPO}/issues/42`);
  const ev = events(o.db, 'linked');
  assert.equal(ev.length, 1);
  assert.equal(ev[0].actor, 'operator@example.com');
  const det = JSON.parse(ev[0].detail);
  assert.equal(det.repo, REPO);
  assert.equal(det.issue, 42);
  o.db.prepare("UPDATE roadmap_links SET issue_state = 'open'").run();
  assert.equal(columnOf((await board(o.DB)).body, 'i1'), 'now');
});

test('L2 the same link twice: 201, then 200 replay; one row, one event', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'i1', 'ideas', 1);
  const b = { idea_id: 'i1', project: P, issue: 42, actor: 'operator' };
  assert.equal((await post(o.DB, 'links', b)).status, 201);
  const r2 = await post(o.DB, 'links', b);
  assert.equal(r2.status, 200);
  assert.equal(r2.body.replay, true);
  assert.equal(r2.body.link.issue, 42);
  assert.equal(linkRows(o.db).length, 1);
  assert.equal(events(o.db, 'linked').length, 1);
});

test("L3 a link to another project's idea id is 404, and nothing is written", async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'theirs', 'ideas', 1, { project: 'proj-b' });
  const r = await post(o.DB, 'links', { idea_id: 'theirs', project: P, issue: 42, actor: 'operator' });
  assert.equal(r.status, 404);
  assert.equal(linkRows(o.db).length, 0);
  assert.equal(events(o.db, 'linked').length, 0);
  assert.equal((await post(o.DB, 'links', { idea_id: 'nope', project: P, issue: 42, actor: 'operator' })).status, 404);
  // A project with no projects row (so no repo): the idea exists, the link cannot.
  idea(o.db, 'orphan', 'ideas', 2, { project: 'no-repo' });
  const nr = await post(o.DB, 'links', { idea_id: 'orphan', project: 'no-repo', issue: 42, actor: 'operator' });
  assert.equal(nr.status, 409);
  assert.equal(linkRows(o.db).length, 0);
  // A projects row with an empty repo: 409, and still no row written.
  o.db.prepare(`INSERT INTO projects (project, repo, board_api_prefix, cron_offset, created_at, updated_at) VALUES ('empty-repo', '', null, 0, ?, ?)`).run(NOW, NOW);
  idea(o.db, 'blank', 'ideas', 3, { project: 'empty-repo' });
  const er = await post(o.DB, 'links', { idea_id: 'blank', project: 'empty-repo', issue: 42, actor: 'operator' });
  assert.equal(er.status, 409);
  assert.equal(linkRows(o.db).length, 0, 'a 409 for an empty repo writes no link');
  assert.equal(events(o.db, 'linked').length, 0);
});

test('L4 a bad issue, idea_id, project or actor is 400', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'i1', 'ideas', 1);
  const base = { idea_id: 'i1', project: P, issue: 42, actor: 'operator' };
  for (const [k, v] of [['issue', '7'], ['issue', 1.5], ['issue', 0], ['issue', 2 ** 31], ['idea_id', ''], ['project', 'a b'], ['actor', '  ']]) {
    const r = await post(o.DB, 'links', { ...base, [k]: v });
    assert.equal(r.status, 400, `${k}=${JSON.stringify(v)}`);
    assert.equal(r.body.field, k);
  }
  assert.equal(linkRows(o.db).length, 0);
});

test('L5 remove a hand link: 200, the row is gone, an unlinked event exists', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'i1', 'ideas', 1);
  await post(o.DB, 'links', { idea_id: 'i1', project: P, issue: 42, actor: 'operator' });
  const r = await post(o.DB, 'links/remove', { idea_id: 'i1', project: P, issue: 42, actor: 'sam' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.removed, 1);
  assert.equal(linkRows(o.db).length, 0);
  const ev = events(o.db, 'unlinked');
  assert.equal(ev.length, 1);
  assert.equal(ev[0].actor, 'sam');
  assert.equal((await post(o.DB, 'links/remove', { idea_id: 'i1', project: P, issue: 42, actor: 'sam' })).status, 404);
  assert.equal(events(o.db, 'unlinked').length, 1, 'a 404 writes no event');
  assert.equal(columnOf((await board(o.DB)).body, 'i1'), 'ideas');
});

test('L6 remove a wave link: 409 and the row is kept; another project: 404', async (t) => {
  const o = await open(t); if (!o) return;
  idea(o.db, 'i1', 'ideas', 1);
  link(o.db, 'i1', 77, 'open', { wave_id: 'w1' });
  const r = await post(o.DB, 'links/remove', { idea_id: 'i1', project: P, issue: 77, actor: 'operator' });
  assert.equal(r.status, 409);
  assert.equal(linkRows(o.db).length, 1);
  assert.equal(events(o.db, 'unlinked').length, 0);
  assert.equal((await post(o.DB, 'links/remove', { idea_id: 'i1', project: 'proj-b', issue: 77, actor: 'operator' })).status, 404);
  assert.equal(linkRows(o.db).length, 1);
});

// ── decisions ───────────────────────────────────────────────────────────────
const decRow = (db, id) => db.prepare('SELECT * FROM roadmap_decisions WHERE id = ?').get(id);

test('D1 add a log entry and an open question: both in the GET', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, 'decisions', { project: P, kind: 'log', title: 'Use REST only', body: 'GraphQL rate limits.', actor: 'operator' });
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.decision.status, 'decided');
  assert.equal(a.body.decision.decided_by, 'operator');
  assert.equal(a.body.decision.decided_at, NOW);
  const b = await post(o.DB, 'decisions', { project: P, kind: 'open', title: 'Which cadence?', actor: 'operator' });
  assert.equal(b.status, 201);
  assert.equal(b.body.decision.status, 'open');
  assert.equal(decRow(o.db, b.body.decision.id).project, P);
  const r = await board(o.DB);
  assert.deepEqual(r.body.decisions.map((d) => d.title), ['Use REST only']);
  assert.deepEqual(r.body.open_decisions.map((d) => d.title), ['Which cadence?']);
  assert.equal((await post(o.DB, 'decisions', { project: 'no-such', kind: 'log', title: 'x', actor: 'operator' })).status, 404);
});

test('D2 decide an open question (expected_status open): 200, it moves to decisions', async (t) => {
  const o = await open(t); if (!o) return;
  const { body: { decision } } = await post(o.DB, 'decisions', { project: P, kind: 'open', title: 'Which cadence?', actor: 'operator' });
  const r = await post(o.DB, 'decisions/decide', { id: decision.id, project: P, status: 'decided', expected_status: 'open', actor: 'sam' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.decision.status, 'decided');
  assert.equal(r.body.decision.decided_by, 'sam');
  const g = await board(o.DB);
  assert.deepEqual(g.body.open_decisions, []);
  assert.deepEqual(g.body.decisions.map((d) => d.id), [decision.id]);
  // Dropped is in neither list.
  const { body: { decision: d2 } } = await post(o.DB, 'decisions', { project: P, kind: 'open', title: 'Second?', actor: 'operator' });
  assert.equal((await post(o.DB, 'decisions/decide', { id: d2.id, project: P, status: 'dropped', expected_status: 'open', actor: 'sam' })).status, 200);
  const g2 = await board(o.DB);
  assert.ok(![...g2.body.decisions, ...g2.body.open_decisions].some((d) => d.id === d2.id));
});

test('D3 a second decide is 409 with the stored row, and the row is unchanged', async (t) => {
  const o = await open(t); if (!o) return;
  const { body: { decision } } = await post(o.DB, 'decisions', { project: P, kind: 'open', title: 'Q', actor: 'operator' });
  const b = { id: decision.id, project: P, status: 'decided', expected_status: 'open', actor: 'sam' };
  assert.equal((await post(o.DB, 'decisions/decide', b)).status, 200);
  const r = await post(o.DB, 'decisions/decide', { ...b, status: 'dropped', actor: 'kim' });
  assert.equal(r.status, 409);
  assert.equal(r.body.decision.status, 'decided');
  assert.equal(decRow(o.db, decision.id).decided_by, 'sam');
});

test('D4 decide with another project is 404, and the row is unchanged', async (t) => {
  const o = await open(t); if (!o) return;
  const { body: { decision } } = await post(o.DB, 'decisions', { project: P, kind: 'open', title: 'Q', actor: 'operator' });
  const r = await post(o.DB, 'decisions/decide', { id: decision.id, project: 'proj-b', status: 'decided', expected_status: 'open', actor: 'sam' });
  assert.equal(r.status, 404);
  assert.equal(decRow(o.db, decision.id).status, 'open');
});

test('D5 a bad kind, status, expected_status, title or body is 400', async (t) => {
  const o = await open(t); if (!o) return;
  for (const [k, v] of [['kind', 'other'], ['title', ''], ['title', 'x'.repeat(201)], ['body', 'x'.repeat(4001)], ['actor', '']]) {
    const r = await post(o.DB, 'decisions', { project: P, kind: 'log', title: 'ok', actor: 'operator', [k]: v });
    assert.equal(r.status, 400, `${k}=${String(v).slice(0, 10)}`);
    assert.equal(r.body.field, k);
  }
  const { body: { decision } } = await post(o.DB, 'decisions', { project: P, kind: 'open', title: 'Q', actor: 'operator' });
  for (const [k, v] of [['status', 'open'], ['status', 'maybe'], ['expected_status', 'decided']]) {
    const r = await post(o.DB, 'decisions/decide', { id: decision.id, project: P, status: 'decided', expected_status: 'open', actor: 'sam', [k]: v });
    assert.equal(r.status, 400, `${k}=${v}`);
    assert.equal(r.body.field, k);
  }
  assert.equal(decRow(o.db, decision.id).status, 'open');
});
