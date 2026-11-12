// BH-9447: a safe recommended lever runs when nobody answers a Tackler card.
// Driven through the REAL worker.fetch over the REAL composed schema (the
// node:sqlite D1 shim). The routes are src/routes/unblock-silence.js; the
// columns are src/lib/core.d/bh-9447-unblock-silence.js; the settings rows are
// schema.d/<stamp>-bh-9447-unblock-silence.sql.
//
//   S1  the five seeded settings rows; unblock.silence_auto.* has exactly one
//       row (cromford); ensureColumns adds the four silence columns
//   S2  claim: 200, then 409 claimed; an answered row 422; unknown 404; a bad
//       lever or cap 400
//   S3  result done: outcome answered, answer = the card's recommendation,
//       answered_by and answer_source silence-default; the operator answered first =
//       200 answered:false and the person's answer stays
//   S4  result failed: the row stays escalated, silence_outcome failed;
//       result without a claim 409 not_claimed; unknown 404; bad outcome 400
//   S5  day cap: cap 2, two claims today 200, the third 409 day_cap; another
//       project still 200 (no cross-project count); a claim dated yesterday
//       does not count
//   S6  EXPLAIN QUERY PLAN of the claim at 50 000 rows (500 silence rows): the
//       count uses idx_unblock_decisions_silence, no SCAN unblock_decisions
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { SILENCE_CLAIM_SQL } from '../src/routes/unblock-silence.js';

const SECRET = 'test-secret-fixture';
const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const COLS = ['silence_claimed_at', 'silence_lever', 'silence_outcome', 'silence_detail'];

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const post = (DB, path, body = {}) => call(DB, path, { method: 'POST', body });
const rowOf = (db, key) => db.prepare('SELECT * FROM unblock_decisions WHERE decision_key = ?').get(key);
const claim = (DB, id, body = { lever: 'lead_rerequest', cap: 10 }) => post(DB, `/api/unblock/silence/${id}/claim`, body);
const result = (DB, id, body) => post(DB, `/api/unblock/silence/${id}/result`, body);

// card <DB> <db> <key> [project] — a claimed + escalated card row (route operator,
// recommendation 2); its id.
async function card(DB, db, key, project = 'cromford') {
  const c = await post(DB, '/api/unblock/decisions/claim', {
    decision_key: key, project, subject_kind: 'pr', subject: `o/r#${key.length}`, stall_class: 'pr-verdict-old-head',
    rule_cites: ['G14'], evidence: { pr: 1 }, decision: 'escalate', mode: 'act',
  });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const r = await post(DB, '/api/unblock/decisions/record', {
    decision_key: key, outcome: 'escalated',
    card: { id: 'u-0a0b0c', options: ['hold: keep it parked', 'ask for a new review'], levers: ['none', 'lead_rerequest'],
      recommendation: 2, route: 'operator' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return rowOf(db, key).id;
}

test('BH-9447 unblock silence default: claim, result, day cap', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S1 the seeded rows and the four columns', async () => {
    const f = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-9447-unblock-silence\.sql$/.test(n));
    assert.ok(f, 'schema.d/<stamp>-bh-9447-unblock-silence.sql exists');
    assert.ok(!/CREATE TABLE/i.test(readFileSync(new URL(f, SCHEMA_D), 'utf8')), 'no table');
    const { db, DB } = await openDb();
    const s = (k) => db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value;
    assert.equal(s('unblock.silence_auto.cromford'), 'on');
    assert.equal(s('unblock.silence_safe_levers'), 'lead_rerequest,update_branch,fix_round,rebuild,requeue');
    assert.equal(s('unblock.silence_auto_after_min'), '120');
    assert.equal(s('unblock.silence_auto_day_cap'), '10');
    assert.equal(s('unblock.silence_rereview_priority'), '5');
    const auto = db.prepare("SELECT key FROM settings WHERE key LIKE 'unblock.silence_auto.%'").all().map((r) => r.key);
    assert.deepEqual(auto, ['unblock.silence_auto.cromford'], 'no other project is seeded');
    const have = () => db.prepare('PRAGMA table_info(unblock_decisions)').all().map((c) => c.name);
    for (const c of COLS) assert.ok(!have().includes(c), `${c} is not in the composed CREATE (added by core.d)`);
    const id = await card(DB, db, 's1-a');
    assert.equal((await claim(DB, id)).status, 200);
    for (const c of COLS) assert.ok(have().includes(c), `${c} added`);
  });

  await t.test('S2 claim', async () => {
    const { db, DB } = await openDb();
    const id = await card(DB, db, 's2-a');
    const c1 = await claim(DB, id);
    assert.equal(c1.status, 200, JSON.stringify(c1.body));
    assert.equal(c1.body.claimed, true);
    const row = rowOf(db, 's2-a');
    assert.equal(row.silence_outcome, 'claimed');
    assert.equal(row.silence_lever, 'lead_rerequest');
    assert.match(row.silence_claimed_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.equal(row.outcome, 'escalated', 'a claim does not answer the card');
    const c2 = await claim(DB, id);
    assert.equal(c2.status, 409);
    assert.equal(c2.body.error, 'claimed');
    // An answered row (the operator said hold) is not claimable.
    const held = await card(DB, db, 's2-held');
    assert.equal((await post(DB, `/api/unblock/decisions/${held}/answer`, { answer: 'hold', answered_by: 'operator@example.com' })).status, 200);
    const c3 = await claim(DB, held);
    assert.equal(c3.status, 422);
    assert.equal(c3.body.error, 'not_escalated');
    assert.equal(rowOf(db, 's2-held').silence_claimed_at, null);
    assert.equal((await claim(DB, 999999)).status, 404);
    const open = await card(DB, db, 's2-bad');
    for (const [body, err] of [
      [{ lever: 'Merge!', cap: 10 }, 'lever'], [{ cap: 10 }, 'lever'], [{ lever: 'x'.repeat(41), cap: 10 }, 'lever'],
      [{ lever: 'requeue', cap: 0 }, 'cap'], [{ lever: 'requeue', cap: 1001 }, 'cap'], [{ lever: 'requeue', cap: 2.5 }, 'cap'],
      [{ lever: 'requeue' }, 'cap'],
    ]) {
      const r = await claim(DB, open, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.body.error, err, JSON.stringify(body));
    }
    assert.equal(rowOf(db, 's2-bad').silence_claimed_at, null, 'no refusal wrote');
  });

  await t.test('S3 result done answers the row as silence-default', async () => {
    const { db, DB } = await openDb();
    const id = await card(DB, db, 's3-a');
    assert.equal((await claim(DB, id)).status, 200);
    const r = await result(DB, id, { outcome: 'done', detail: 'requested' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.answered, true);
    const row = rowOf(db, 's3-a');
    assert.equal(row.outcome, 'answered');
    assert.equal(row.answer, '2', 'the card recommendation');
    assert.equal(row.answered_by, 'silence-default');
    assert.equal(row.answer_source, 'silence-default');
    assert.equal(row.silence_outcome, 'done');
    assert.equal(row.silence_detail, 'requested');
    assert.ok(row.answered_at && row.resolved_at);
    // answered_by silence-default only after a done result: a claim alone never answers.
    const id2 = await card(DB, db, 's3-b');
    assert.equal((await claim(DB, id2)).status, 200);
    assert.equal(rowOf(db, 's3-b').answered_by, null);
    // the operator answered between the claim and the result: that answer stays.
    assert.equal((await post(DB, `/api/unblock/decisions/${id2}/answer`, { answer: 'hold', answered_by: 'operator@example.com' })).status, 200);
    const r2 = await result(DB, id2, { outcome: 'done', detail: 'requested' });
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    assert.equal(r2.body.answered, false);
    const row2 = rowOf(db, 's3-b');
    assert.equal(row2.answer, 'hold');
    assert.equal(row2.answered_by, 'operator@example.com');
    assert.equal(row2.silence_outcome, 'done');
    // A second result is not claimed any more.
    assert.equal((await result(DB, id, { outcome: 'done' })).status, 409);
  });

  await t.test('S4 result failed leaves the card open', async () => {
    const { db, DB } = await openDb();
    const id = await card(DB, db, 's4-a');
    assert.equal((await claim(DB, id)).status, 200);
    const r = await result(DB, id, { outcome: 'failed', detail: 'request rc 1 with no reset' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.answered, false);
    const row = rowOf(db, 's4-a');
    assert.equal(row.outcome, 'escalated');
    assert.equal(row.answer, null);
    assert.equal(row.answered_by, null);
    assert.equal(row.silence_outcome, 'failed');
    assert.equal(row.silence_detail, 'request rc 1 with no reset');
    assert.equal((await claim(DB, id)).status, 409, 'a failed card is never claimed again');
    for (const o of ['refused', 'would']) {
      const k = `s4-${o}`;
      const i = await card(DB, db, k);
      assert.equal((await claim(DB, i)).status, 200);
      assert.equal((await result(DB, i, { outcome: o })).status, 200);
      assert.equal(rowOf(db, k).outcome, 'escalated', o);
      assert.equal(rowOf(db, k).silence_outcome, o);
    }
    const nc = await card(DB, db, 's4-noclaim');
    const r3 = await result(DB, nc, { outcome: 'done' });
    assert.equal(r3.status, 409);
    assert.equal(r3.body.error, 'not_claimed');
    assert.equal(rowOf(db, 's4-noclaim').outcome, 'escalated');
    assert.equal((await result(DB, 999999, { outcome: 'done' })).status, 404);
    for (const body of [{ outcome: 'answered' }, {}, { outcome: 'done', detail: 'x'.repeat(501) }, { outcome: 'done', detail: 5 }]) {
      assert.equal((await result(DB, nc, body)).status, 400, JSON.stringify(body));
    }
  });

  await t.test('S5 the day cap is per project and per UTC day', async () => {
    const { db, DB } = await openDb();
    const ids = [];
    for (let i = 0; i < 3; i++) ids.push(await card(DB, db, `s5-${i}`));
    const cap = { lever: 'requeue', cap: 2 };
    assert.equal((await claim(DB, ids[0], cap)).status, 200);
    assert.equal((await claim(DB, ids[1], cap)).status, 200);
    const third = await claim(DB, ids[2], cap);
    assert.equal(third.status, 409);
    assert.equal(third.body.error, 'day_cap');
    assert.equal(third.body.count, 2);
    assert.equal(third.body.cap, 2);
    assert.equal(rowOf(db, 's5-2').silence_claimed_at, null, 'over the cap: no write');
    // Wrong tenant: another project's count is its own.
    const other = await card(DB, db, 's5-project-3', 'project-3');
    assert.equal((await claim(DB, other, cap)).status, 200, 'another project is not counted');
    // Yesterday's claims do not count today.
    const y = new Date(Date.now() - 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z'); // determinism: ok the route takes its day from the worker's real clock (nowIso), so yesterday must be real now - 24 h
    db.prepare('UPDATE unblock_decisions SET silence_claimed_at = ? WHERE decision_key IN (?, ?)').run(y, 's5-0', 's5-1');
    assert.equal((await claim(DB, ids[2], cap)).status, 200, 'yesterday does not count');
  });

  await t.test('S6 EXPLAIN QUERY PLAN of the claim at 50 000 rows', async () => {
    const { db, DB } = await openDb();
    const id = await card(DB, db, 's6-a'); // ensureColumns
    await claim(DB, id);
    const ins = db.prepare(`INSERT INTO unblock_decisions (decision_key, agent, project, subject_kind, subject, stall_class,
      rule_cites, evidence, decision, mode, outcome, card, created_at, silence_claimed_at)
      VALUES (?, 'tackler', ?, 'pr', 's', 'x', 'G1', '{}', 'escalate', 'act', ?, '{"id":"u-000001"}', ?, ?)`);
    const projects = ['cromford', 'project-3', 'project-4', 'project-1', 'project-5'];
    const outcomes = ['would', 'escalated', 'answered', 'expired', 'claimed'];
    const base = Date.parse('2026-04-20T00:00:00Z');
    db.exec('BEGIN');
    for (let i = 0; i < 50000; i++) {
      const at = new Date(base + i * 300000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      ins.run(`s6-${i}`, projects[i % 5], outcomes[i % 5], at, i % 100 === 0 ? at : null);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${SILENCE_CLAIM_SQL}`).all(id, 'requeue', '2026-10-01T00:00:00Z', '2026-10-01', 10)
      .map((r) => r.detail);
    assert.ok(plan.some((d) => d.includes('idx_unblock_decisions_silence')), `the count uses the index: ${plan.join(' | ')}`);
    assert.ok(!plan.some((d) => /^SCAN unblock_decisions\b/.test(d)), `no full scan: ${plan.join(' | ')}`);
  });
});
