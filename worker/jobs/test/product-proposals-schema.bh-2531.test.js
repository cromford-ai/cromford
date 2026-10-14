import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2531: product_proposals is the row the product lane's proposal ledger
// outlives its box in. This proves schema.sql creates it idempotently, with the
// ticket's columns, a (project, proposal_id) primary key and no other index.

const SCHEMA = jobsSchemaSql();

async function openDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
}

test('S1: schema.sql applies twice; product_proposals has the contract columns and PK, no extra index', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  db.exec(SCHEMA);
  const cols = db.prepare('PRAGMA table_info(product_proposals)').all()
    .map((r) => ({ name: r.name, type: r.type, notnull: r.notnull, pk: r.pk }));
  assert.deepEqual(cols, [
    { name: 'project', type: 'TEXT', notnull: 1, pk: 1 },
    { name: 'proposal_id', type: 'TEXT', notnull: 1, pk: 2 },
    { name: 'status', type: 'TEXT', notnull: 1, pk: 0 },
    { name: 'record', type: 'TEXT', notnull: 1, pk: 0 },
    { name: 'actor', type: 'TEXT', notnull: 0, pk: 0 },
    { name: 'created_at', type: 'TEXT', notnull: 1, pk: 0 },
    { name: 'updated_at', type: 'TEXT', notnull: 1, pk: 0 },
  ]);
  const idx = db.prepare('PRAGMA index_list(product_proposals)').all().map((r) => r.name);
  assert.deepEqual(idx, ['sqlite_autoindex_product_proposals_1']);
});

test('S2: two projects hold the same slug; a repeat (project, slug) is refused', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const ins = db.prepare(`INSERT INTO product_proposals
    (project, proposal_id, status, record, created_at, updated_at) VALUES (?, ?, 'posted', '{}', 't', 't')`);
  ins.run('p1', 's');
  ins.run('p2', 's');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM product_proposals').get().n, 2);
  assert.throws(() => ins.run('p1', 's'), /UNIQUE|PRIMARY KEY/i);
});
