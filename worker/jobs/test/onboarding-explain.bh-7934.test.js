// BH-7934.0 (#7947): EXPLAIN QUERY PLAN for every onboarding_runs /
// onboarding_steps query, on 5,000 runs over 50 projects and 35,000 steps
// (the BH-6730 index law). The run read and the steps read are the SQL the
// route itself runs (exported from src/routes/onboarding.js), so a later edit
// to the route SQL is checked here. The poll, list and retention queries are
// the shapes the schema fragment's INDEXES comment names for the siblings
// (BH-7934.2 runner and retention rule).
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { RUN_READ_SQL, STEPS_READ_SQL } from '../src/routes/onboarding.js';

const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (min) => new Date(NOW - min * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const TABLES = ['onboarding_runs', 'onboarding_steps'];
const STATES = ['queued', 'running', 'failed', 'done', 'cancelled'];
const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];

async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  // Multi-row INSERTs: 100 runs (10 binds each) or 100 steps (4 binds each) per statement.
  for (let b = 0; b < 50; b++) {
    const runs = [], rb = [], steps = [], sb = [];
    for (let j = 0; j < 100; j++) {
      const i = b * 100 + j, id = `ob_${String(i).padStart(20, '0')}`, ts = ago(5000 - i);
      runs.push('(?,?,?,?,?,?,?,?,?,?)');
      rb.push(id, `proj-${i % 50}`, `o/proj-${i % 50}`, '{}', STATES[i % 5], null, null, ts, ts, null);
      STATIONS.forEach((s, k) => { steps.push('(?,?,?,?)'); sb.push(id, s, k + 1, 'queued'); });
    }
    db.prepare(`INSERT INTO onboarding_runs (id, project, repo, inputs_json, state, station, created_by, created_at, updated_at, finished_at) VALUES ${runs.join(',')}`).run(...rb);
    for (let k = 0; k < steps.length; k += 100) {
      db.prepare(`INSERT INTO onboarding_steps (run_id, station, ord, state) VALUES ${steps.slice(k, k + 100).join(',')}`).run(...sb.slice(k * 4, (k + 100) * 4));
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM onboarding_runs').get().n, 5000);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM onboarding_steps').get().n, 35000);
  return o;
}

function check(db, sql, binds, index) {
  const p = plan(db, sql, ...binds);
  assert.deepEqual(fullScans(p, TABLES), [], p.join(' | '));
  assert.ok(p.some((l) => l.includes(index)), `${index} not in: ${p.join(' | ')}`);
}

test('E1 the route reads: the run by its primary key, the steps by idx_onboarding_steps_run_ord', async (t) => {
  const o = await seeded(t); if (!o) return;
  const id = `ob_${String(4321).padStart(20, '0')}`;
  check(o.db, RUN_READ_SQL, [id], 'sqlite_autoindex_onboarding_runs_1');
  check(o.db, STEPS_READ_SQL, [id], 'idx_onboarding_steps_run_ord');
  const p = plan(o.db, STEPS_READ_SQL, id);
  assert.ok(!p.some((l) => /USE TEMP B-TREE FOR ORDER BY/.test(l)), `the steps read sorts in a temp b-tree: ${p.join(' | ')}`);
});

test('E2 the queued poll and the retention id read use idx_onboarding_runs_state_updated', async (t) => {
  const o = await seeded(t); if (!o) return;
  check(o.db, "SELECT id FROM onboarding_runs WHERE state = 'queued' ORDER BY updated_at LIMIT 1", [], 'idx_onboarding_runs_state_updated');
  check(o.db, "SELECT id FROM onboarding_runs WHERE state IN ('done','failed','cancelled') AND updated_at < ?1 ORDER BY updated_at LIMIT ?2",
    [ago(1000), 500], 'idx_onboarding_runs_state_updated');
});

test('E3 the project list uses idx_onboarding_runs_project_created', async (t) => {
  const o = await seeded(t); if (!o) return;
  check(o.db, 'SELECT id, state, created_at FROM onboarding_runs WHERE project = ?1 ORDER BY created_at DESC LIMIT ?2',
    ['proj-7', 50], 'idx_onboarding_runs_project_created');
});

test('E4 the retention child delete uses idx_onboarding_steps_run_ord', async (t) => {
  const o = await seeded(t); if (!o) return;
  const ids = [1, 2, 3].map((i) => `ob_${String(i).padStart(20, '0')}`);
  check(o.db, 'DELETE FROM onboarding_steps WHERE run_id IN (?1, ?2, ?3)', ids, 'idx_onboarding_steps_run_ord');
});
