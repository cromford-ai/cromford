import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// POST /api/wakes/nudge with a Jira/Linear key (BH-8451, slice C3 of #7920).
//
// bin/untriaged-wake.sh nudges a Jira or Linear project's untriaged ticket by
// the tracker's own key (CRO-12), a string. The body N1 posts is the one the
// lane wrote in tests/lane-ports-untriaged-sched.bh-8451-test.sh (W2), read
// from the same fixture, so the writer and this reader agree on one shape.
// Driven through `worker.fetch` on node:sqlite with the composed schema (D2).

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret';
const BODY = JSON.parse(readFileSync(
  new URL('../../../tests/fixtures/lane-ports.bh-8451/nudge-body.json', import.meta.url), 'utf8'));

function d1(db, calls) {
  const exec = (sql) => {
    calls.push(sql.replace(/\s+/g, ' ').trim());
    return db.prepare(sql);
  };
  const shape = (sql, binds) => ({
    all: async () => ({ results: exec(sql).all(...binds) }),
    first: async () => exec(sql).get(...binds) ?? null,
    run: async () => {
      const r = exec(sql).run(...binds);
      return { meta: { changes: r.changes, last_row_id: Number(r.lastInsertRowid) } };
    },
  });
  return {
    prepare(sql) {
      return { bind: (...b) => shape(sql, b), ...shape(sql, []) };
    },
  };
}

async function fixture(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const calls = [];
  return { db, calls, DB: d1(db, calls) };
}

const nudge = (fx, body) => worker.fetch(new Request('https://jobs.test/api/wakes/nudge', {
  method: 'POST',
  headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
  body: JSON.stringify(body),
}), { DB: fx.DB, HARNESS_SECRET: SECRET })
  .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const rows = (fx) => fx.db.prepare(
  'SELECT repo, kind, key, typeof(key) kt, event, minute FROM wakes ORDER BY id ASC').all()
  .map((r) => ({ ...r }));
const inserts = (fx) => fx.calls.filter((s) => /^INSERT/i.test(s));

test('N1 the lane\'s Linear body inserts one row with the TEXT key CRO-12', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal(BODY.key, 'CRO-12');
  const r = await nudge(fx, BODY);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.inserted, 1);
  const got = rows(fx);
  assert.equal(got.length, 1);
  assert.equal(got[0].key, 'CRO-12');
  assert.equal(got[0].kt, 'text');
  assert.equal(got[0].repo, 'o/crolin');
  assert.equal(got[0].kind, 'issue');
  assert.equal(got[0].event, 'nudge:untriaged');
  assert.equal(got[0].minute, 'nudge:untriaged:cro-12');
});

test('N2 the same body again inserts nothing', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal((await nudge(fx, BODY)).body.inserted, 1);
  const again = await nudge(fx, BODY);
  assert.equal(again.status, 200);
  assert.equal(again.body.inserted, 0);
  assert.equal(rows(fx).length, 1);
});

for (const key of ['cro-12', 'CRO-0', 'CRO-12 ', 'CRO-12;x', '12', `${'C'.repeat(21)}-1`, 'CRO-1234567890', '-12', 'CRO12']) {
  test(`N3 key ${JSON.stringify(key)} is a 400 and runs no INSERT`, async (t) => {
    const fx = await fixture(t);
    if (!fx) return;
    const r = await nudge(fx, { ...BODY, key });
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.deepEqual(inserts(fx), []);
  });
}

test('N3 a 20-character Jira project key is accepted (the bound is inclusive)', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await nudge(fx, { ...BODY, key: `A${'B'.repeat(19)}-7`, dedupe: 'untriaged:jira-7' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.inserted, 1);
});

test('N4 an integer key is still accepted and stored as TEXT', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await nudge(fx, { repo: 'example-org/x', key: 12, reason: 'untriaged', dedupe: 'untriaged:12' });
  assert.equal(r.status, 200);
  assert.equal(r.body.inserted, 1);
  assert.equal(rows(fx)[0].key, '12');
  assert.equal(rows(fx)[0].kt, 'text');
});
