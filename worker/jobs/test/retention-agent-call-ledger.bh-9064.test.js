// BH-9064: retention rule agent_call_ledger.age through the REAL
// POST /api/retention/run on node:sqlite.
//   R1 the rule is registered with key retention.agent_call_ledger.days,
//      default 7, and the schema seeds the row at 7
//   R2 under dry run a row 8 days old is counted, not deleted
//   R3 live, that row is deleted and a row 6 days old stays; one audit row per run
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { RULES } from '../src/routes/retention.js';

const SECRET = 'tok-fixture-bh9064-ret';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const run = (DB, body) => worker.fetch(new Request('https://jobs.test/api/retention/run', {
  method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (r) => ({ status: r.status, body: await r.json() }));

async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const ins = o.db.prepare(`INSERT INTO agent_call_ledger (project, stage, fp, status, attempts, first_at, last_at)
                            VALUES ('p', 'review', ?, 'ok', 1, ?, ?)`);
  ins.run('old', ago(8), ago(8));
  ins.run('new', ago(6), ago(6));
  return o;
}
const fps = (db) => db.prepare('SELECT fp FROM agent_call_ledger ORDER BY fp').all().map((r) => r.fp);

test('R1 the rule agent_call_ledger.age is registered, key retention.agent_call_ledger.days, default 7, seeded 7', async (t) => {
  const rule = RULES.find((x) => x.rule === 'agent_call_ledger.age');
  assert.ok(rule, `the rule is registered: ${RULES.map((r) => r.rule).join(',')}`);
  assert.equal(rule.table, 'agent_call_ledger');
  assert.equal(rule.key, 'retention.agent_call_ledger.days');
  assert.equal(rule.def, 7);
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return; }
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key='retention.agent_call_ledger.days'").get().value, '7');
});

test('R2 under dry run the 8-day row is counted, not deleted', async (t) => {
  const o = await seeded(t); if (!o) return;
  const dry = await run(o.DB, { dry_run: true });
  assert.equal(dry.status, 200, JSON.stringify(dry.body));
  const dr = dry.body.rules.find((r) => r.rule === 'agent_call_ledger.age');
  assert.ok(dr, `the rule ran: ${dry.body.rules.map((r) => r.rule).join(',')}`);
  assert.equal(dr.counted, 1);
  assert.equal(dr.removed, 0);
  assert.deepEqual(fps(o.db), ['new', 'old']);
});

test('R3 live: the 8-day row is deleted, the 6-day row stays, one audit row', async (t) => {
  const o = await seeded(t); if (!o) return;
  o.db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','',?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run('test', ago(0));
  const live = await run(o.DB, {});
  assert.equal(live.status, 200, JSON.stringify(live.body));
  const lr = live.body.rules.find((r) => r.rule === 'agent_call_ledger.age');
  assert.equal(lr.removed, 1);
  assert.equal(lr.error, null);
  assert.deepEqual(fps(o.db), ['new']);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule='agent_call_ledger.age'").get().n, 1);
});
