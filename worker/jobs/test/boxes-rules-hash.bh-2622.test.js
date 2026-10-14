import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2532.0 (BH-2622) — box_status.rules_hash and rules_reported_at, driven
// against THE SQL THAT SHIPS: schema.sql on a fresh database, and the
// ensureColumns ALTERs on one whose box_status predates them. GET /api/boxes
// is `SELECT *`, so the columns reach the hub with no route change — which is
// only true if both paths actually create them.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// A D1-shaped facade over node:sqlite (same shape as schema-deploy-queue.bh-1026).
function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

const getBoxes = async (db) => {
  const req = new Request('https://jobs.test/api/boxes', {
    method: 'GET', headers: { authorization: `Bearer ${SECRET}` },
  });
  const res = await worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
};

const colNames = (db) => db.prepare('PRAGMA table_info(box_status)').all().map((c) => c.name);

test('N1: schema.sql re-applies clean and its box_status carries rules_hash and rules_reported_at', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const names = colNames(db);
  assert.ok(names.includes('rules_hash'), 'fresh box_status must carry rules_hash');
  assert.ok(names.includes('rules_reported_at'), 'fresh box_status must carry rules_reported_at');
  db.close();
});

test('N2: GET /api/boxes on a fresh database exposes both columns, null until a box reports', async () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.prepare("INSERT INTO box_status (box, updated_at) VALUES ('box-a', '2026-09-26T00:00:00Z')").run();
  const r = await getBoxes(db);
  assert.equal(r.status, 200);
  assert.equal(r.body.boxes.length, 1);
  const [b] = r.body.boxes;
  assert.equal(b.box, 'box-a');
  assert.ok(Object.hasOwn(b, 'rules_hash'), 'boxes[0] must carry rules_hash');
  assert.ok(Object.hasOwn(b, 'rules_reported_at'), 'boxes[0] must carry rules_reported_at');
  assert.equal(b.rules_hash, null);
  assert.equal(b.rules_reported_at, null);
  db.close();
});

test('N3: a legacy box_status gains both columns through ensureColumns on GET /api/boxes', async () => {
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE box_status (box TEXT PRIMARY KEY, updated_at TEXT NOT NULL)');
  db.prepare("INSERT INTO box_status (box, updated_at) VALUES ('box-old', '2026-09-26T00:00:00Z')").run();
  assert.equal(colNames(db).includes('rules_hash'), false);
  const r = await getBoxes(db);
  assert.equal(r.status, 200);
  const names = colNames(db);
  assert.ok(names.includes('rules_hash'), 'ensureColumns must ALTER in rules_hash');
  assert.ok(names.includes('rules_reported_at'), 'ensureColumns must ALTER in rules_reported_at');
  // Additive and never backfilled: the existing row reads null, not a default.
  assert.equal(r.body.boxes[0].box, 'box-old');
  assert.equal(r.body.boxes[0].rules_hash, null);
  assert.equal(r.body.boxes[0].rules_reported_at, null);
  db.close();
});
