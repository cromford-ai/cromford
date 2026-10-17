// BH-7156: the documented answer of GET /api/staff/autonomy for archie.
// Archie is not a staff agent, so the route answers 404 "agent not found"
// (worker/jobs/src/routes/staff-autonomy.js header). The console handles it
// by never asking: StaffAgentScreen mounts no AUTONOMY panel for archie
// (console-ui/tests/staff-archie-autonomy.bh-7156.test.js). Driven through the
// REAL worker.fetch over the REAL composed schema (the node:sqlite D1 shim).
//
//   W1 ?agent=archie   -> 404 { error: 'agent not found' }
//   W2 ?agent=Archie   -> 404, the same body (agentOf normalizes the name)
//   W3 ?agent=watchman -> 200 (control)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const autonomy = (DB, agent) => worker.fetch(
  new Request(`https://jobs.test/api/staff/autonomy?agent=${encodeURIComponent(agent)}`, {
    method: 'GET', headers: { authorization: `Bearer ${SECRET}` },
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const probe = await openDb();
const skip = probe ? false : 'node:sqlite is not available';

test('BH-7156 the autonomy read for archie', { skip }, async (t) => {
  const { DB, db } = await openDb();
  assert.ok(db.prepare('SELECT 1 FROM staff_agents WHERE name=?').get('watchman'), 'the schema seeds watchman');
  assert.equal(db.prepare('SELECT count(*) AS n FROM staff_agents WHERE name=?').get('archie').n, 0, 'archie is not a staff_agents row');

  await t.test('W1 archie is 404 agent not found', async () => {
    const r = await autonomy(DB, 'archie');
    assert.equal(r.status, 404);
    assert.deepEqual(r.body, { error: 'agent not found' });
  });

  await t.test('W2 Archie (mixed case) is the same 404', async () => {
    const r = await autonomy(DB, 'Archie');
    assert.equal(r.status, 404);
    assert.deepEqual(r.body, { error: 'agent not found' });
  });

  await t.test('W3 watchman is 200 (control)', async () => {
    const r = await autonomy(DB, 'watchman');
    assert.equal(r.status, 200);
    assert.equal(r.body.agent.name, 'watchman');
  });
});
