// BH-7264 (BH-7243.1): the new roadmap queries use an index at seeded volume
// (iron law BH-6730). The composed jobs schema in node:sqlite holds 20
// projects x 1,000 ideas (20,000) and 100,000 events. Each plan is the exact
// SQL text the route runs (exported constants), so an edit to the SQL is what
// this test reads.
//
// E1 move/edit/detail row   WHERE id AND project       the primary key
// E2 detail events          WHERE idea_id AND project ORDER BY at DESC LIMIT 50
//                           idx_roadmap_idea_events_idea
// E3 summary                GROUP BY project, lane     COVERING INDEX
//                           idx_roadmap_ideas_project_lane_updated, no temp b-tree
// E4 import link join       ux_roadmap_ideas_source_ref
// E5 a dropped index turns the check red (the assertion can fail)
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const R = await import('../src/routes/roadmap-ideas.js').catch(() => null);
const I = await import('../src/routes/roadmap-import.js').catch(() => null);
const BASE_MS = Date.parse('2026-10-17T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const LANES = ['ideas', 'ideas', 'next', 'discarded'];

let seeded = null;
async function seed() {
  if (seeded) return seeded;
  const o = await openDb();
  if (!o) return null;
  const { db } = o;
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO roadmap_ideas (id, project, title, source, lane, source_ref, created_by, created_at, updated_at, discarded_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?)`);
  for (let p = 0; p < 20; p++) {
    for (let i = 0; i < 1000; i++) {
      const lane = LANES[i % LANES.length];
      const at = iso(BASE_MS - (i * 3 + p) * 3600e3);
      ins.run(`i-${p}-${i}`, `proj-${p}`, `Idea ${i}`, 'operator', lane, i % 3 ? null : `ref-${i}`, 'operator', at, at, lane === 'discarded' ? at : null);
    }
  }
  const ev = db.prepare('INSERT INTO roadmap_idea_events (idea_id, project, kind, to_lane, actor, at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 100000; i++) ev.run(`i-${i % 20}-${i % 1000}`, `proj-${i % 20}`, 'moved', 'next', 'operator', iso(BASE_MS - i * 600e3));
  const pr = db.prepare('INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?, ?, 0, ?, ?)');
  for (let p = 0; p < 20; p++) pr.run(`proj-${p}`, `o/proj-${p}`, iso(BASE_MS), iso(BASE_MS));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  seeded = db;
  return db;
}

// The number of binds a statement takes: `?NNN` by its highest number, else
// one per bare `?`.
function bindCount(sql) {
  const numbered = [...sql.matchAll(/\?(\d+)/g)].map((m) => Number(m[1]));
  return numbered.length ? Math.max(...numbered) : (sql.match(/\?/g) || []).length;
}
function plan(db, sql, binds) {
  const b = binds || Array.from({ length: bindCount(sql) }, () => null);
  return db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail).join('\n');
}
function assertIndexed(text, name, index, { scanOk = false } = {}) {
  if (!scanOk) assert.ok(!/SCAN roadmap_/.test(text), `${name} scans a roadmap table:\n${text}`);
  assert.ok(text.includes(index), `${name} does not use ${index}:\n${text}`);
}

test('E0 the seeded volume is real', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM roadmap_ideas').get().n, 20000);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM roadmap_idea_events').get().n, 100000);
});

test('E1 the move, edit and detail row reads use the primary key', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.ok(R && R.IDEA_ROW_SQL, 'roadmap-ideas.js exports IDEA_ROW_SQL');
  const text = plan(db, R.IDEA_ROW_SQL, ['i-3-7', 'proj-3']);
  assert.match(text, /SEARCH roadmap_ideas USING INDEX sqlite_autoindex_roadmap_ideas_1 \(id=\?\)|USING PRIMARY KEY/, text);
  assertIndexed(plan(db, R.MOVE_UPDATE_SQL), 'E1 MOVE_UPDATE_SQL', 'sqlite_autoindex_roadmap_ideas_1');
  assertIndexed(plan(db, R.MOVE_EVENT_SQL), 'E1 MOVE_EVENT_SQL', 'sqlite_autoindex_roadmap_ideas_1');
});

test('E2 the detail events read uses idx_roadmap_idea_events_idea', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assertIndexed(plan(db, R.EVENTS_SQL, ['i-3-7', 'proj-3']), 'E2 EVENTS_SQL', 'idx_roadmap_idea_events_idea');
});

test('E3 the summary groups on the covering index with no temp b-tree', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  const text = plan(db, R.SUMMARY_COUNTS_SQL, []);
  // The summary reads every idea once by design; it must read the index, not the table.
  assert.match(text, /COVERING INDEX idx_roadmap_ideas_project_lane_updated/, text);
  assert.ok(!/TEMP B-TREE/.test(text), `E3 sorts in a temp b-tree:\n${text}`);
});

test('E4 the import link join uses ux_roadmap_ideas_source_ref', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.ok(I && typeof I.linkInsertSql === 'function', 'roadmap-import.js exports linkInsertSql(n)');
  assertIndexed(plan(db, I.linkInsertSql(1)), 'E4 linkInsertSql(1)', 'ux_roadmap_ideas_source_ref');
});

test('E5 a dropped index turns the check red', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  assert.ok(R && R.EVENTS_SQL, 'roadmap-ideas.js exports EVENTS_SQL');
  o.db.exec('DROP INDEX idx_roadmap_idea_events_idea');
  assert.throws(() => assertIndexed(plan(o.db, R.EVENTS_SQL, ['x', 'p']), 'E5', 'idx_roadmap_idea_events_idea'));
  o.db.exec('DROP INDEX idx_roadmap_ideas_project_lane_updated');
  assert.doesNotMatch(plan(o.db, R.SUMMARY_COUNTS_SQL, []), /COVERING INDEX idx_roadmap_ideas_project_lane_updated/);
});
