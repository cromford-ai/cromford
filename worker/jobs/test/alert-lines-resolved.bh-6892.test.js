// BH-6892 (BH-6881.10): a lane-run machine retracts a pipeline-health alert by
// posting its RESOLVED line with severity "resolved"; the hub replays it as
// `bin/alert-line.sh --severity resolved`, which beats resolved:true.
//
//   W1 POST /api/alert-lines with severity "resolved" stores the row with that
//      severity, and the unapplied read hands it back; "loud" is still a 400
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-6892';
const STAMP = '2026-10-16 12:00:00Z';

async function call(DB, method, path, body) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const line = (o = {}) => ({
  lane: 'pipeline-health', project: 'fx', run_id: 'run-fixture-1', stamp: STAMP, alertid: 'ph-staleparent_fx_9',
  line: `${STAMP} [pipeline-health] RESOLVED staleparent:fx:9 — condition no longer holds`, ...o,
});

test('W1 severity resolved is stored and read back; an unknown severity is a 400', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  const r = await call(DB, 'POST', '/api/alert-lines', line({ severity: 'resolved' }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(db.prepare('SELECT severity FROM alert_lines WHERE id = ?').get(r.body.id).severity, 'resolved');
  const g = await call(DB, 'GET', '/api/alert-lines?unapplied=1');
  assert.equal(g.status, 200);
  const got = g.body.lines.find((x) => x.id === r.body.id);
  assert.equal(got.severity, 'resolved');
  assert.equal(got.alertid, 'ph-staleparent_fx_9');
  const bad = await call(DB, 'POST', '/api/alert-lines', line({ severity: 'loud', run_id: 'run-fixture-2' }));
  assert.equal(bad.status, 400);
  assert.match(bad.body.error, /^severity must be one of info, warn, critical, resolved$/);
});
