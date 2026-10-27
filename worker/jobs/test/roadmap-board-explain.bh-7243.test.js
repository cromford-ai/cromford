// BH-7265 (BH-7243.2): every roadmap board statement uses an index at seeded
// volume (iron law BH-6730). The schema is the composed jobs schema in
// node:sqlite, seeded with 5,000 ideas over 20 projects, 20,000 links, 200,000
// jobs (2% running) and 2,000 decisions. Each query is the exact SQL text the
// route runs (exported constants), so an edit to the SQL is what this reads.
//
// X1 BOARD_IDEAS_SQL      idx_roadmap_ideas_project_updated or _project_lane_updated
//                         (SQLite walks the project in updated_at order and stops at the LIMIT)
// X2 BOARD_LINKS_SQL      the roadmap_links primary key (idea_id=?), for the ideas X1's
//                         index picks (links of shown ideas only)
// X3 BOARD_RUNNING_SQL    idx_jobs_project_status*
// X4 BOARD_DECISIONS_SQL  idx_roadmap_decisions_project
// X5 LINK_INSERT_SQL      the roadmap_ideas and projects primary keys
// X6 UNLINK_DELETE_SQL    the roadmap_links primary key
// X7 DECIDE_SQL           the roadmap_decisions primary key
// X8 a dropped index turns the check red (the assertion can fail)
// Every plan: no bare `SCAN <table>` of a roadmap table or of jobs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const R = await import('../src/routes/roadmap-board.js').catch(() => null);
const BASE_MS = Date.parse('2026-10-17T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const LANES = ['ideas', 'ideas', 'next', 'discarded'];
const STATES = ['open', 'closed_completed', 'closed_other', null];

let seeded = null;
async function seed() {
  if (seeded) return seeded;
  const o = await openDb();
  if (!o) return null;
  const { db } = o;
  db.exec('BEGIN');
  const pj = db.prepare('INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?,?,0,?,?)');
  for (let p = 0; p < 20; p++) pj.run(`proj-${p}`, `o/proj-${p}`, iso(BASE_MS), iso(BASE_MS));
  const ins = db.prepare(`INSERT INTO roadmap_ideas (id, project, title, source, lane, created_by, created_at, updated_at)
                          VALUES (?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < 5000; i++) {
    const t = iso(BASE_MS - i * 3600e3);
    ins.run(`i-${i}`, `proj-${i % 20}`, `Idea ${i}`, 'operator', LANES[i % LANES.length], 'operator', t, t);
  }
  const ln = db.prepare(`INSERT INTO roadmap_links (idea_id, project, repo, issue, issue_state, created_at) VALUES (?,?,?,?,?,?)`);
  for (let i = 0; i < 20000; i++) {
    const idea = i % 5000;
    ln.run(`i-${idea}`, `proj-${idea % 20}`, `o/proj-${idea % 20}`, 1000 + i, STATES[i % STATES.length], iso(BASE_MS));
  }
  const jb = db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < 200000; i++) {
    const t = iso(BASE_MS - i * 60e3);
    jb.run(`j-${i}`, `proj-${i % 20}`, `BH-${1000 + (i % 20000)}`, 'build', 'hub', 'done', i % 50 === 0 ? 'running' : 'done', t, t);
  }
  const dc = db.prepare(`INSERT INTO roadmap_decisions (id, project, kind, title, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?)`);
  for (let i = 0; i < 2000; i++) {
    const t = iso(BASE_MS - i * 7200e3);
    dc.run(`d-${i}`, `proj-${i % 20}`, i % 3 ? 'log' : 'open', `D ${i}`, i % 3 ? 'decided' : 'open', t, t);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  seeded = db;
  return db;
}

const plan = (db, sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join('\n');
function assertIndexed(db, name, sql, binds, index) {
  const text = plan(db, sql, binds);
  assert.ok(!/SCAN (roadmap_\w+|jobs|projects)\b(?! USING)/.test(text), `${name} scans a table:\n${text}`);
  assert.ok(index.test(text), `${name} does not use ${index}:\n${text}`);
}

test('X0 the seeded volume is real', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  const n = (tb) => db.prepare(`SELECT COUNT(*) AS n FROM ${tb}`).get().n;
  assert.equal(n('roadmap_ideas'), 5000);
  assert.equal(n('roadmap_links'), 20000);
  assert.equal(n('jobs'), 200000);
  assert.equal(n('roadmap_decisions'), 2000);
});

test('X1-X4 the four board reads use their indexes', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  assertIndexed(db, 'X1 BOARD_IDEAS_SQL', R.BOARD_IDEAS_SQL, ['proj-3', 201], /idx_roadmap_ideas_project_(lane_)?updated/);
  assertIndexed(db, 'X2 BOARD_LINKS_SQL', R.BOARD_LINKS_SQL, ['proj-3', 2001, 200], /SEARCH roadmap_links USING INDEX sqlite_autoindex_roadmap_links_1 \(idea_id=\?\)/);
  assertIndexed(db, 'X3 BOARD_RUNNING_SQL', R.BOARD_RUNNING_SQL, ['proj-3', 501], /idx_jobs_project_status/);
  assertIndexed(db, 'X4 BOARD_DECISIONS_SQL', R.BOARD_DECISIONS_SQL, ['proj-3', 201], /idx_roadmap_decisions_project/);
});

test('X5-X7 the write statements look up by primary key', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  const t0 = iso(BASE_MS);
  const ins = plan(db, R.LINK_INSERT_SQL, ['i-3', 'proj-3', 42, 'operator', t0]);
  assert.match(ins, /SEARCH i USING INDEX sqlite_autoindex_roadmap_ideas_1 \(id=\?\)/, ins);
  assert.match(ins, /SEARCH p USING INDEX sqlite_autoindex_projects_1 \(project=\?\)/, ins);
  assert.doesNotMatch(ins, /SCAN (i|p|roadmap_\w+)\b/, ins);
  const del = plan(db, R.UNLINK_DELETE_SQL, ['i-3', 'proj-3', 42]);
  assert.match(del, /SEARCH roadmap_links USING INDEX (sqlite_autoindex_roadmap_links_1|idx_roadmap_links_\w+)/, del);
  assert.doesNotMatch(del, /SCAN roadmap_links/, del);
  const dec = plan(db, R.DECIDE_SQL, ['d-3', 'proj-3', 'decided', 'open', 'operator', t0]);
  assert.match(dec, /SEARCH roadmap_decisions USING INDEX sqlite_autoindex_roadmap_decisions_1 \(id=\?\)/, dec);
});

test('X8 a dropped index turns the check red (the assertion can fail)', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  assert.ok(R, 'src/routes/roadmap-board.js must exist');
  o.db.exec('DROP INDEX idx_roadmap_decisions_project');
  assert.throws(() => assertIndexed(o.db, 'X4 without index', R.BOARD_DECISIONS_SQL, ['p', 2], /idx_roadmap_decisions_project/),
    /X4 without index (scans a table|does not use)/);
});
