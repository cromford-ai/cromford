import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-6737 — the hub forwards a far-box `run_script` command to this route
// (bin/lib/jobs/box-console-commands.sh box_ccmd_forward). The route must
// accept the exact type `run_script` and still refuse near spellings.

const SECRET = 'test-secret';
const BASE = '/api/box-console-commands';

async function fixture() {
  const opened = await openDb();
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  db.exec(jobsSchemaSql());
  const create = (over = {}) => worker.fetch(new Request(`https://jobs.test${BASE}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      command_id: 'rs1', box: 'project-3', type: 'run_script', project: 'project-3',
      payload: '{"script":"healthcheck.sh","args":[]}', ...over,
    }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (r) => ({ status: r.status, body: await r.json() }));
  const count = () => db.prepare('SELECT COUNT(*) n FROM box_console_commands').get().n;
  const row = (id) => db.prepare('SELECT * FROM box_console_commands WHERE command_id=?').get(id) ?? null;
  return { create, count, row };
}

test('RS1: type run_script → 201 and one queued row with that type', async () => {
  const f = await fixture();
  const r = await f.create();
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.created, true);
  assert.equal(f.count(), 1);
  const row = f.row('rs1');
  assert.equal(row.type, 'run_script');
  assert.equal(row.status, 'queued');
  assert.equal(row.box, 'project-3');
});

test('RS2: near spellings of run_script → 400 and no row', async () => {
  const f = await fixture();
  for (const [i, type] of ['RUN_SCRIPT', 'run-script', 'run_script ', 'runscript'].entries()) {
    const r = await f.create({ command_id: `bad${i}`, type });
    assert.equal(r.status, 400, `${type}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /^type must be one of /);
  }
  assert.equal(f.count(), 0);
});
