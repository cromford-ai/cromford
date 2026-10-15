import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { sqlIdent } from '../src/lib/sql-ident.js';
import { TABLES, applyRegistry, readAll } from '../src/routes/registry.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-6514 (slice BH-6521): sqlIdent, and the registry routes that put table
// and column names into SQL text through it. J1/J2 pin the check itself. J6
// drives a real registry write through worker.fetch on SQLite, so the wrapped
// names still produce working statements. J7 swaps a TABLES name for an
// injection and shows each wrapped site throws before any statement is made.

const SECRET = 'fixture-secret';
const ADMIN = 'fixture-admin-token';
const NOW_MS = Date.parse('2026-10-13T12:00:00Z');

async function call(env, method, path, body) {
  const headers = { authorization: `Bearer ${SECRET}`, 'x-registry-admin-token': ADMIN };
  const init = { method, headers };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), env);
  return { status: res.status, body: await res.json() };
}

function fixture() {
  return {
    actor: 'registry-seed',
    projects: [
      { project: 'alpha', repo: 'Acme/alpha', prod: '-', board_prefix: '-', cron_offset: 3, box: 'box-a', position: 0, status: 'active' },
      { project: 'beta', repo: 'Acme/beta', prod: '-', board_prefix: '-', cron_offset: 5, box: 'box-a', position: 1, status: 'active' },
    ],
    boxes: [
      { box: 'box-a', box_id: 'a', tailnet_ip: '192.0.2.1', cost_box: 'a', standby_hub_name: null, standby_hub_id: null },
    ],
    lane_boxes: [],
    box_accounts: [],
  };
}

async function seeded(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const opened = await openDb();
  if (!opened) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const env = { DB: opened.DB, HARNESS_SECRET: SECRET, REGISTRY_ADMIN_TOKEN: ADMIN };
  const r = await call(env, 'POST', '/api/registry/import', fixture());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { ...opened, env };
}

const projectRows = (db) => db.prepare('SELECT project FROM registry_projects ORDER BY project').all().map((r) => r.project);

// A D1 stand-in that records every statement and runs none.
function recordingDb() {
  const sql = [];
  let batched = 0;
  const stmt = { bind() { return stmt; }, all: async () => ({ results: [] }), first: async () => null, run: async () => ({}) };
  return {
    sql, batches: () => batched,
    DB: { prepare(s) { sql.push(s); return stmt; }, batch: async () => { batched += 1; return []; } },
  };
}

// Swap TABLES.projects[key] for the length of fn, then restore it.
async function withSpec(key, value, fn) {
  const was = TABLES.projects[key];
  TABLES.projects[key] = value;
  try { return await fn(); } finally { TABLES.projects[key] = was; }
}

const BAD_TABLE = 'registry_projects; DROP TABLE registry_meta';
const empty = () => ({ projects: [], boxes: [], lane_boxes: [], box_accounts: [] });
const ROW = fixture().projects[0];

// ── J1 a plain identifier comes back unchanged ───────────────────────────────
test('J1: sqlIdent returns a plain identifier as it is', () => {
  for (const name of ['registry_projects', '_a1', 'A']) assert.equal(sqlIdent(name), name);
  assert.deepEqual(['a', 'b_c'].map(sqlIdent), ['a', 'b_c']);
});

// ── J2 anything else throws TypeError ────────────────────────────────────────
test('J2: sqlIdent throws TypeError for a name that is not a plain identifier', () => {
  for (const bad of ['', 'a b', 't; DROP TABLE x', '1abc', 'a-b', 'a.b', 'a\n', 'é', undefined, 42]) {
    assert.throws(() => sqlIdent(bad), TypeError, JSON.stringify(String(bad)));
  }
});

// ── J6 a real registry write still applies through worker.fetch ──────────────
test('J6: import then DELETE a project through worker.fetch applies on SQLite', async (t) => {
  const s = await seeded(t); if (!s) return;
  assert.deepEqual(projectRows(s.db), ['alpha', 'beta']);
  const r = await call(s.env, 'DELETE', '/api/registry/projects/beta');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(projectRows(s.db), ['alpha']);
  const au = s.db.prepare("SELECT key, new_value FROM registry_audit WHERE entity='project' AND key='beta' ORDER BY id").all();
  assert.equal(au.length, 2, 'one audit row from the import, one from the delete');
  assert.equal(au[1].new_value, null);
});

// ── J7 a bad name in TABLES stops the write before any SQL ───────────────────
test('J7: a TABLES name that is not an identifier fails the DELETE route, nothing changes', async (t) => {
  const s = await seeded(t); if (!s) return;
  const r = await withSpec('table', BAD_TABLE, () => call(s.env, 'DELETE', '/api/registry/projects/beta'));
  assert.ok(r.status >= 400, `status ${r.status}`);
  assert.match(r.body.detail || '', /not a SQL identifier/);
  assert.equal(s.db.prepare('SELECT COUNT(*) AS n FROM registry_meta').get().n, 1);
  assert.deepEqual(projectRows(s.db), ['alpha', 'beta']);
});

test('J7: readAll checks the table and the column names before it prepares', async () => {
  for (const [key, value] of [['table', BAD_TABLE], ['cols', ['project', 'repo; DROP TABLE x']]]) {
    const rec = recordingDb();
    await withSpec(key, value, () => assert.rejects(readAll({ DB: rec.DB }), TypeError, key));
    assert.equal(rec.sql.length, 0, `${key}: no statement prepared`);
  }
});

test('J7: the DELETE in applyRegistry checks the table and the key columns', async () => {
  const have = { ...empty(), projects: [ROW] };
  for (const [key, value] of [['table', BAD_TABLE], ['pk', ['project) OR (1=1']]]) {
    const rec = recordingDb();
    await withSpec(key, value, () => assert.rejects(
      applyRegistry({ DB: rec.DB }, 't0', 'j7', have, { version: 1 }, empty(), { deletes: true }), TypeError, key));
    assert.equal(rec.sql.filter((q) => q.startsWith('DELETE')).length, 0, `${key}: no DELETE prepared`);
    assert.equal(rec.batches(), 0, `${key}: no batch`);
  }
});

test('J7: the INSERT in applyRegistry checks the table and the columns', async () => {
  const want = { ...empty(), projects: [ROW] };
  for (const [key, value] of [['table', BAD_TABLE], ['cols', [...TABLES.projects.cols, 'x) VALUES (1']]]) {
    const rec = recordingDb();
    await withSpec(key, value, () => assert.rejects(
      applyRegistry({ DB: rec.DB }, 't0', 'j7', empty(), { version: 1 }, want, { deletes: false }), TypeError, key));
    assert.equal(rec.sql.filter((q) => q.startsWith('INSERT')).length, 0, `${key}: no INSERT prepared`);
    assert.equal(rec.batches(), 0, `${key}: no batch`);
  }
});
