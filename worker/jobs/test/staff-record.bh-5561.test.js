// BH-5561 (BH-5556.4): the staff heartbeat's record step, driven through the
// REAL worker.fetch against the REAL schema.sql (the node:sqlite D1 shim), the
// way staff-findings.test.js does it. Every case first claims a finding through
// the real POST /api/staff/findings/claim. Pinned here: a record moves a row
// only out of 'claimed', a filing writes one staff_decisions row that the
// agent_decisions view shows, a same-body replay answers existing:true and
// writes nothing, a bad body or a wrong agent writes nothing, and fragment 0022
// seeds the one stage.staff-tick route from triage rung 0.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const call = (DB, path, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const record = (DB, body) => call(DB, '/api/staff/findings/record', body);

const TITLE = 'Fixture token in a public gist';
const ISSUE = 'https://github.com/example-org/cromford/issues/7';
// Claim one finding through the real claim route; return its fingerprint.
const claimOne = async (DB, item = { repo: 'fixture/repo', rule: 'fixture-key' }) => {
  const r = await call(DB, '/api/staff/findings/claim', {
    agent: 'watchman', item, title: TITLE,
    source: { kind: 'alert', url: 'https://example.com/alerts/fixture-1', labels: ['ops'] },
    observedAt: '2026-10-10T02:00:00Z',
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.fingerprint;
};
const row = (db, fp) => db.prepare('SELECT * FROM staff_findings WHERE fingerprint=?').get(fp);
const decisions = (db, fp) => db.prepare('SELECT * FROM staff_decisions WHERE escalation_key=?').all(`staff:${fp}`);
const nDecisions = (db) => db.prepare('SELECT count(*) AS n FROM staff_decisions').get().n;
const filed = (fp, extra = {}) => ({ agent: 'watchman', fingerprint: fp, outcome: 'filed', mode: 'ask', ticket_url: ISSUE, ...extra });


test('BH-5561 staff findings record', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 digested: 200; the row is digested and has no ticket_url', async () => {
    const { DB, db } = await openDb();
    const fp = await claimOne(DB);
    const r = await record(DB, { agent: 'watchman', fingerprint: fp, outcome: 'digested' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.ok, true);
    assert.equal(r.body.finding.status, 'digested');
    const after = row(db, fp);
    assert.equal(after.status, 'digested');
    assert.equal(after.ticket_url, null);
    assert.equal(nDecisions(db), 0, 'a digest writes no decision');
  });

  await t.test('R2 filed (ask): the row is filed with the ticket_url; one decision row, seen in agent_decisions', async () => {
    const { DB, db } = await openDb();
    const fp = await claimOne(DB);
    const r = await record(DB, filed(fp));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.ok, true);
    assert.equal(r.body.finding.status, 'filed');
    assert.equal(r.body.finding.ticket_url, ISSUE);
    const after = row(db, fp);
    assert.equal(after.status, 'filed');
    assert.equal(after.ticket_url, ISSUE);
    const d = decisions(db, fp);
    assert.equal(d.length, 1);
    assert.equal(d[0].agent, 'watchman');
    assert.equal(d[0].mode, 'ask');
    assert.equal(d[0].class, 'alert', 'class defaults to the row source_kind');
    assert.equal(d[0].recommendation, TITLE, 'recommendation defaults to the row title');
    assert.equal(nDecisions(db), 1);
    const v = db.prepare('SELECT agent, mode FROM agent_decisions WHERE escalation_key=?').get(`staff:${fp}`);
    assert.ok(v, 'agent_decisions does not show the staff decision');
    assert.equal(v.agent, 'watchman');
    assert.equal(v.mode, 'ask');
  });

  await t.test('R3 the same filed body again: 200 existing:true; still one decision row', async () => {
    const { DB, db } = await openDb();
    const fp = await claimOne(DB);
    assert.equal((await record(DB, filed(fp))).status, 200);
    const r = await record(DB, filed(fp));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.existing, true);
    assert.equal(r.body.finding.status, 'filed');
    assert.equal(decisions(db, fp).length, 1);
    assert.equal(nDecisions(db), 1);
  });

  await t.test('R4 a digested row is never moved to filed: 409 not_claimed with status digested', async () => {
    const { DB, db } = await openDb();
    const fp = await claimOne(DB);
    assert.equal((await record(DB, { agent: 'watchman', fingerprint: fp, outcome: 'digested' })).status, 200);
    const r = await record(DB, filed(fp));
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.error, 'not_claimed');
    assert.equal(r.body.status, 'digested');
    const after = row(db, fp);
    assert.equal(after.status, 'digested');
    assert.equal(after.ticket_url, null);
    assert.equal(nDecisions(db), 0);
  });

  await t.test('R5 filed with no ticket_url, a pull URL or a non-GitHub host: 400 ticket_url; the row is unchanged', async () => {
    const { DB, db } = await openDb();
    const fp = await claimOne(DB);
    const before = row(db, fp);
    const noUrl = filed(fp);
    delete noUrl.ticket_url;
    for (const body of [noUrl, filed(fp, { ticket_url: 'https://github.com/a/b/pull/1' }),
      filed(fp, { ticket_url: 'https://evil.example/x/y/issues/1' })]) {
      const r = await record(DB, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.body.error, 'ticket_url', JSON.stringify(body));
    }
    const bm = await record(DB, filed(fp, { mode: 'later' }));
    assert.equal(bm.status, 400);
    assert.equal(bm.body.error, 'mode');
    assert.deepEqual(row(db, fp), before);
    assert.equal(nDecisions(db), 0);
  });

  await t.test('R6 unknown fingerprint 404; another agent 409 wrong_agent; bad outcome and short fingerprint 400', async () => {
    const { DB, db } = await openDb();
    const fp = await claimOne(DB);
    const before = row(db, fp);
    const nf = await record(DB, { agent: 'watchman', fingerprint: 'b'.repeat(64), outcome: 'digested' });
    assert.equal(nf.status, 404, JSON.stringify(nf.body));
    assert.equal(nf.body.error, 'finding not found');
    const wa = await record(DB, { agent: 'clerk', fingerprint: fp, outcome: 'digested' });
    assert.equal(wa.status, 409, JSON.stringify(wa.body));
    assert.equal(wa.body.error, 'wrong_agent');
    const bo = await record(DB, { agent: 'watchman', fingerprint: fp, outcome: 'done' });
    assert.equal(bo.status, 400);
    assert.equal(bo.body.error, 'outcome');
    const bf = await record(DB, { agent: 'watchman', fingerprint: fp.slice(1), outcome: 'digested' });
    assert.equal(bf.status, 400);
    assert.equal(bf.body.error, 'fingerprint');
    assert.deepEqual(row(db, fp), before);
    assert.equal(nDecisions(db), 0);
  });

  // TEST-CHANGE (lead review lr-5985 of 623ae9adc): R7 checked 7
  // stage.staff.<name> seeds that no code reads. The lane reads ONE route,
  // stage.staff-tick (the operator, 2026-10-12), and nothing checked that seed.
  await t.test('R7 schema: stage.staff-tick copied from triage rung 0; no stage.staff.<name> seed; a re-apply keeps one', async () => {
    const { db } = await openDb();
    const tri = db.prepare(
      "SELECT model, runner FROM model_routes WHERE project IS NULL AND role='triage' AND position=0 AND runner='claude'"
    ).get();
    assert.ok(tri && tri.model, 'triage rung 0 claude is not seeded');
    const tick = () => db.prepare("SELECT role, position, model, runner FROM model_routes WHERE project IS NULL AND role='stage.staff-tick'").all();
    assert.equal(tick().length, 1);
    assert.equal(tick()[0].position, 0);
    assert.equal(tick()[0].model, tri.model);
    assert.equal(tick()[0].runner, 'claude');
    assert.equal(db.prepare("SELECT count(*) AS n FROM model_routes WHERE role LIKE 'stage.staff.%'").get().n, 0);
    db.exec(SCHEMA);
    assert.equal(tick().length, 1);
  });
});
