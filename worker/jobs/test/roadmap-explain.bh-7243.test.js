// BH-7263 (BH-7243.0): every hot roadmap query uses an index at seeded volume
// (iron law BH-6730). The schema is the composed jobs schema in node:sqlite,
// seeded with 20 projects x 2,000 ideas (mixed lanes), 100,000 events and
// 2,000 waves. Each query is the exact SQL text the route or the retention rule
// runs (exported constants), so an edit to the SQL is what this test reads.
//
// E1 GET list, no lane      idx_roadmap_ideas_project_updated
// E2 GET list, lane=        idx_roadmap_ideas_project_lane_updated
// E3 GET counts             idx_roadmap_ideas_project_lane_updated
// E4 POST idem lookup       ux_roadmap_ideas_idem
// E5 rule roadmap_ideas.discarded   idx_roadmap_ideas_discarded
// E6 rule roadmap_idea_events.age   idx_roadmap_idea_events_at
// E7 rule roadmap_waves.closed      idx_roadmap_waves_status
// Every plan: no `SCAN roadmap_` line.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { RULES } from '../src/routes/retention.js';

const R = await import('../src/routes/roadmap-ideas.js').catch(() => null);
const BASE_MS = Date.parse('2026-10-17T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const LANES = ['ideas', 'ideas', 'next', 'discarded'];
const STATUSES = ['requested', 'shaping', 'draft', 'empty', 'failed', 'rejected', 'approved', 'filing', 'filed'];

let seeded = null;
async function seed() {
  if (seeded) return seeded;
  const o = await openDb();
  if (!o) return null;
  const { db } = o;
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO roadmap_ideas (id, project, title, source, lane, idem_key, source_ref, created_by, created_at, updated_at, discarded_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?)`);
  for (let p = 0; p < 20; p++) {
    for (let i = 0; i < 2000; i++) {
      const lane = LANES[i % LANES.length];
      const at = iso(BASE_MS - (i * 3 + p) * 3600e3);
      ins.run(`i-${p}-${i}`, `proj-${p}`, `Idea ${i}`, 'operator', lane, i % 2 ? `k-${i}` : null, i % 5 ? null : `ref-${i}`,
        'operator', at, at, lane === 'discarded' ? at : null);
    }
  }
  const ev = db.prepare('INSERT INTO roadmap_idea_events (idea_id, project, kind, to_lane, actor, at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 100000; i++) {
    ev.run(`i-${i % 20}-${i % 2000}`, `proj-${i % 20}`, 'created', 'ideas', 'operator', iso(BASE_MS - i * 600e3));
  }
  const wv = db.prepare(`INSERT INTO roadmap_waves (id, project, status, input_fp, idea_ids, created_at, updated_at) VALUES (?,?,?,?,?,?,?)`);
  for (let i = 0; i < 2000; i++) {
    const at = iso(BASE_MS - i * 7200e3);
    wv.run(`w-${i}`, `proj-${i % 20}`, STATUSES[i % STATUSES.length], `fp-${i}`, '[]', at, at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  seeded = db;
  return db;
}

function plan(db, sql, binds) {
  return db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
}
function assertIndexed(db, name, sql, binds, index) {
  const lines = plan(db, sql, binds);
  const text = lines.join('\n');
  assert.ok(!/SCAN roadmap_/.test(text), `${name} scans a roadmap table:\n${text}`);
  assert.ok(text.includes(index), `${name} does not use ${index}:\n${text}`);
}
const rule = (name) => {
  const r = RULES.find((x) => x.rule === name);
  assert.ok(r, `RULES has ${name}`);
  return r;
};

test('E0 the seeded volume is real', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM roadmap_ideas').get().n, 40000);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM roadmap_idea_events').get().n, 100000);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM roadmap_waves').get().n, 2000);
});

test('E1-E4 the route queries use their indexes', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  assert.ok(R, 'src/routes/roadmap-ideas.js must exist');
  assertIndexed(db, 'E1 LIST_ALL_SQL', R.LIST_ALL_SQL, ['proj-3', 201], 'idx_roadmap_ideas_project_updated');
  assertIndexed(db, 'E2 LIST_LANE_SQL', R.LIST_LANE_SQL, ['proj-3', 201, 'next'], 'idx_roadmap_ideas_project_lane_updated');
  assertIndexed(db, 'E3 COUNTS_SQL', R.COUNTS_SQL, ['proj-3'], 'idx_roadmap_ideas_project_lane_updated');
  assertIndexed(db, 'E4 IDEM_SQL', R.IDEM_SQL, ['proj-3', 'k-7'], 'ux_roadmap_ideas_idem');
});

test('E5-E7 the retention id reads use their indexes', async (t) => {
  const db = await seed(); if (!db) return t.skip('node:sqlite unavailable');
  const cut = iso(BASE_MS - 180 * 86400e3);
  assertIndexed(db, 'E5 roadmap_ideas.discarded', rule('roadmap_ideas.discarded').ids, [cut, 500], 'idx_roadmap_ideas_discarded');
  assertIndexed(db, 'E6 roadmap_idea_events.age', rule('roadmap_idea_events.age').ids, [cut, 500], 'idx_roadmap_idea_events_at');
  assertIndexed(db, 'E7 roadmap_waves.closed', rule('roadmap_waves.closed').ids, [cut, 500], 'idx_roadmap_waves_status');
});

test('E8 a dropped index turns the check red (the assertion can fail)', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  assert.ok(R, 'src/routes/roadmap-ideas.js must exist');
  o.db.exec('DROP INDEX idx_roadmap_ideas_project_lane_updated');
  o.db.exec('DROP INDEX idx_roadmap_ideas_project_updated');
  assert.throws(() => assertIndexed(o.db, 'E2 without index', R.LIST_LANE_SQL, ['p', 2, 'next'], 'idx_roadmap_ideas_project_lane_updated'));
});
