// BH-8817 (C0): Tackler cards go to Archie first. Driven through the REAL
// worker.fetch over the REAL composed schema (the node:sqlite D1 shim).
//
//   W1  the answerer table: archie answers hold|none|acted only with source
//       archie (answer_source='archie'; acted needs a lever, stored in
//       archie_lever); a person keeps every answer; the 7722 refusals hold;
//       an archie answer on a operator-routed row is 422 routed, on a card
//       Tackler sent to the operator direct 422 not_archie
//   W2  archie-claim: 200 then 409; answered 422; unknown 404; routed 409
//   W3  route: 200 then 409; to archie 400; answered 422; a claim newer than
//       claimed_before 409
//   W4  paged: 200 then 409; a row not routed to operator 409; unknown 404
//   W5  cards/daily counts; a claimed row with a card is not counted; another
//       project reads 0 (wrong tenant); bad project or day 400
//   W6  EXPLAIN QUERY PLAN at 50 000 rows: daily, repeats and list name their index
//   W7  ensureColumns adds the seven columns to a table made without them
//   W8  the four seed rows of schema.d/*-bh-8817-archie-cards.sql
//   W9  cards/repeats: Archie's repeated answers by class, answer and lever,
//       the min threshold, the window, bad input 400
//   W10 cards/daily operator counts every card the operator got: routed back by Archie, a
//       card with no route (BH-8736's ask card, a legacy card) and a card
//       Tackler sent with route operator; another project reads 0 (wrong tenant)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { listSql } from '../src/routes/unblock-decisions.js';
import { DAILY_SQL, REPEATS_SQL } from '../src/routes/unblock-cards.js';

const SECRET = 'test-secret-fixture';
const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const NEW_COLS = ['answer_source', 'routed_to', 'routed_at', 'route_reason', 'paged_at', 'archie_claimed_at', 'archie_lever'];

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

// card <DB> <db> <key> [project] [route] — a claimed + escalated card row; its id.
async function card(DB, db, key, project = 'cromford', route = 'archie', stallClass = 'pr-ejected') {
  const c = await post(DB, '/api/unblock/decisions/claim', {
    decision_key: key, project, subject_kind: 'pr', subject: `o/r#${key}`, stall_class: stallClass,
    rule_cites: ['G14'], evidence: { pr: 1 }, decision: 'escalate', mode: 'act',
  });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const r = await post(DB, '/api/unblock/decisions/record', {
    decision_key: key, outcome: 'escalated',
    card: { id: `u-${key.length.toString(16).padStart(6, '0')}`, options: ['hold: keep it parked', 'run a fix round'], route },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return rowOf(db, key).id;
}
const answer = (DB, id, body) => post(DB, `/api/unblock/decisions/${id}/answer`, body);

test('BH-8817 unblock cards: archie route, claim, page, daily', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 the answerer table', async () => {
    const { DB, db } = await openDb();
    const ok = [
      ['w1-ah', { answer: 'hold', answered_by: 'archie', source: 'archie', note: 'wait for main' }, 'archie'],
      ['w1-an', { answer: 'none', answered_by: 'archie', source: 'archie', note: 'PR already merged' }, 'archie'],
      ['w1-aa', { answer: 'acted', lever: 'requeue', answered_by: 'archie', source: 'archie', note: 'lever requeue done: requeued' }, 'archie'],
      ['w1-ph', { answer: 'hold', answered_by: 'operator@example.com' }, null],
    ];
    for (const [k, body, src] of ok) {
      const id = await card(DB, db, k);
      const r = await answer(DB, id, body);
      assert.equal(r.status, 200, `${k}: ${JSON.stringify(r.body)}`);
      const row = rowOf(db, k);
      assert.equal(row.outcome, 'answered', k);
      assert.equal(row.answer, body.answer, k);
      assert.equal(row.answer_source, src, `${k} answer_source`);
      assert.equal(row.archie_lever, body.lever ?? null, `${k} archie_lever`);
    }
    // The lever rules, on an open archie card: no write on any refusal.
    const lv = await card(DB, db, 'w1-lever');
    for (const [body, err] of [
      [{ answer: 'acted', answered_by: 'archie', source: 'archie' }, 'lever'],
      [{ answer: 'acted', lever: 'merge', answered_by: 'archie', source: 'archie' }, 'lever'],
      [{ answer: 'hold', lever: 'requeue', answered_by: 'archie', source: 'archie' }, 'lever'],
      [{ answer: 'acted', lever: 'requeue', answered_by: 'operator@example.com' }, 'answer'],
      [{ answer: '1', lever: 'requeue', answered_by: 'operator@example.com' }, 'lever'],
    ]) {
      const r = await answer(DB, lv, body);
      assert.equal(r.status, 400, JSON.stringify(body));
      assert.equal(r.body.error, err, JSON.stringify(body));
    }
    assert.equal(rowOf(db, 'w1-lever').outcome, 'escalated', 'no lever refusal wrote');
    // A card Tackler sent to the operator direct (route operator) is not Archie's to answer.
    const direct = await card(DB, db, 'w1-direct', 'cromford', 'operator');
    for (const body of [{ answer: 'none', answered_by: 'archie', source: 'archie', note: 'x' },
      { answer: 'acted', lever: 'requeue', answered_by: 'archie', source: 'archie' }]) {
      const r = await answer(DB, direct, body);
      assert.equal(r.status, 422, JSON.stringify(body));
      assert.equal(r.body.error, 'not_archie');
    }
    assert.equal(rowOf(db, 'w1-direct').outcome, 'escalated', 'a operator card stays open for the operator');
    assert.equal((await answer(DB, direct, { answer: '2', answered_by: 'operator@example.com' })).status, 200, 'the operator answers it');
    // A person answers an option on a card the operator was paged for.
    const routed = await card(DB, db, 'w1-routed');
    assert.equal((await post(DB, `/api/unblock/decisions/${routed}/route`, { to: 'operator', by: 'archie', reason: 'money' })).status, 200);
    const refusals = [
      [{ answer: 'hold', answered_by: 'archie', source: 'archie' }, 422, 'routed'],
      [{ answer: 'hold', answered_by: 'archie' }, 403, 'agent_answerer'],
      [{ answer: 'hold', answered_by: 'Archie' }, 403, 'agent_answerer'],
      [{ answer: 'hold', answered_by: 'tackler', source: 'archie' }, 403, 'agent_answerer'],
      [{ answer: 'hold', answered_by: 'operator@example.com', source: 'archie' }, 400, 'source'],
      [{ answer: 'hold', answered_by: 'operator@example.com', source: 'person' }, 400, 'source'],
      [{ answer: 'none', answered_by: 'operator@example.com' }, 400, 'answer'],
      [{ answer: '2', answered_by: 'archie', source: 'archie' }, 400, 'answer'],
    ];
    for (const [body, st, err] of refusals) {
      const r = await answer(DB, routed, body);
      assert.equal(r.status, st, JSON.stringify(body));
      assert.equal(r.body.error, err, JSON.stringify(body));
    }
    assert.equal(rowOf(db, 'w1-routed').outcome, 'escalated', 'no refusal wrote');
    const p = await answer(DB, routed, { answer: '2', answered_by: 'operator@example.com', command_id: 'tg-w1' });
    assert.equal(p.status, 200, JSON.stringify(p.body));
    assert.equal(rowOf(db, 'w1-routed').answer, '2');
    assert.equal(rowOf(db, 'w1-routed').answer_source, null);
    // A re-run archie answer with the same command id is the 409 duplicate.
    const dup = await card(DB, db, 'w1-dup');
    const body = { answer: 'hold', answered_by: 'archie', source: 'archie', command_id: 'archie-u-000006' };
    assert.equal((await answer(DB, dup, body)).status, 200);
    const again = await answer(DB, dup, body);
    assert.equal(again.status, 409);
    assert.equal(again.body.duplicate, true);
  });

  await t.test('W2 archie-claim', async () => {
    const { DB, db } = await openDb();
    const id = await card(DB, db, 'w2-a');
    const c = await post(DB, `/api/unblock/decisions/${id}/archie-claim`);
    assert.equal(c.status, 200, JSON.stringify(c.body));
    assert.equal(c.body.claimed, true);
    assert.match(c.body.claimed_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.equal(rowOf(db, 'w2-a').archie_claimed_at, c.body.claimed_at);
    const c2 = await post(DB, `/api/unblock/decisions/${id}/archie-claim`);
    assert.equal(c2.status, 409);
    assert.equal(c2.body.error, 'claimed');
    const done = await card(DB, db, 'w2-done');
    assert.equal((await answer(DB, done, { answer: 'hold', answered_by: 'operator@example.com' })).status, 200);
    const c3 = await post(DB, `/api/unblock/decisions/${done}/archie-claim`);
    assert.equal(c3.status, 422);
    assert.equal(c3.body.error, 'not_escalated');
    assert.equal((await post(DB, '/api/unblock/decisions/999999/archie-claim')).status, 404);
    const routed = await card(DB, db, 'w2-routed');
    assert.equal((await post(DB, `/api/unblock/decisions/${routed}/route`, { to: 'operator', by: 'timeout', reason: '' })).status, 200);
    const c4 = await post(DB, `/api/unblock/decisions/${routed}/archie-claim`);
    assert.equal(c4.status, 409);
    assert.equal(c4.body.error, 'routed');
    assert.equal(rowOf(db, 'w2-routed').archie_claimed_at, null);
  });

  await t.test('W3 route', async () => {
    const { DB, db } = await openDb();
    const id = await card(DB, db, 'w3-a');
    const r = await post(DB, `/api/unblock/decisions/${id}/route`, { to: 'operator', by: 'archie', reason: 'money: a price change' });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const row = rowOf(db, 'w3-a');
    assert.equal(row.routed_to, 'operator');
    assert.equal(row.route_reason, 'archie: money: a price change');
    assert.ok(row.routed_at);
    assert.equal(row.outcome, 'escalated', 'needs-operator is not an answer');
    const r2 = await post(DB, `/api/unblock/decisions/${id}/route`, { to: 'operator', by: 'timeout' });
    assert.equal(r2.status, 409);
    assert.equal(r2.body.error, 'routed');
    const b = await card(DB, db, 'w3-b');
    for (const [body, err] of [[{ to: 'archie', by: 'archie' }, 'to'], [{ to: 'operator', by: 'tackler' }, 'by'],
      [{ to: 'operator', by: 'archie', reason: 'x'.repeat(501) }, 'reason'], [{ to: 'operator', by: 'timeout', claimed_before: '2026-11-01' }, 'claimed_before']]) {
      const x = await post(DB, `/api/unblock/decisions/${b}/route`, body);
      assert.equal(x.status, 400, JSON.stringify(body));
      assert.equal(x.body.error, err);
    }
    assert.equal(rowOf(db, 'w3-b').routed_to, null, 'no bad body wrote');
    const done = await card(DB, db, 'w3-done');
    await answer(DB, done, { answer: 'hold', answered_by: 'operator@example.com' });
    assert.equal((await post(DB, `/api/unblock/decisions/${done}/route`, { to: 'operator', by: 'timeout' })).status, 422);
    assert.equal((await post(DB, '/api/unblock/decisions/999999/route', { to: 'operator', by: 'timeout' })).status, 404);
    // Archie claimed it after the sweep's cut-off: the timeout route loses.
    const cl = await card(DB, db, 'w3-claimed');
    db.prepare("UPDATE unblock_decisions SET archie_claimed_at = '2026-11-01T10:20:00Z' WHERE id = ?").run(cl);
    const late = await post(DB, `/api/unblock/decisions/${cl}/route`, { to: 'operator', by: 'timeout', claimed_before: '2026-11-01T10:05:00Z' });
    assert.equal(late.status, 409);
    assert.equal(late.body.error, 'claimed');
    assert.equal(rowOf(db, 'w3-claimed').routed_to, null);
    const stale = await post(DB, `/api/unblock/decisions/${cl}/route`, { to: 'operator', by: 'timeout', claimed_before: '2026-11-01T10:35:00Z' });
    assert.equal(stale.status, 200, JSON.stringify(stale.body));
    assert.equal(rowOf(db, 'w3-claimed').route_reason, 'timeout');
  });

  await t.test('W4 paged', async () => {
    const { DB, db } = await openDb();
    const id = await card(DB, db, 'w4-a');
    const n = await post(DB, `/api/unblock/decisions/${id}/paged`);
    assert.equal(n.status, 409, 'not routed to operator');
    assert.equal(n.body.error, 'not_routed');
    await post(DB, `/api/unblock/decisions/${id}/route`, { to: 'operator', by: 'archie', reason: 'client' });
    const p = await post(DB, `/api/unblock/decisions/${id}/paged`);
    assert.equal(p.status, 200, JSON.stringify(p.body));
    assert.ok(rowOf(db, 'w4-a').paged_at);
    const p2 = await post(DB, `/api/unblock/decisions/${id}/paged`);
    assert.equal(p2.status, 409);
    assert.equal(p2.body.error, 'paged');
    assert.equal((await post(DB, '/api/unblock/decisions/999999/paged')).status, 404);
  });

  await t.test('W5 cards/daily counts and the wrong tenant', async () => {
    const { DB, db } = await openDb();
    // The worker stamps created_at with its own clock; the rows are moved to a
    // fixed day below, so the test reads no wall clock.
    const day = '2026-10-31';
    const a1 = await card(DB, db, 'w5-hold');
    const a2 = await card(DB, db, 'w5-none');
    const a3 = await card(DB, db, 'w5-acted');
    const l1 = await card(DB, db, 'w5-operator');
    await card(DB, db, 'w5-open');
    assert.equal((await answer(DB, a1, { answer: 'hold', answered_by: 'archie', source: 'archie' })).status, 200);
    assert.equal((await answer(DB, a2, { answer: 'none', answered_by: 'archie', source: 'archie', note: 'merged' })).status, 200);
    assert.equal((await answer(DB, a3, { answer: 'acted', lever: 'fix_round', answered_by: 'archie', source: 'archie', note: 'queued' })).status, 200);
    assert.equal((await post(DB, `/api/unblock/decisions/${l1}/route`, { to: 'operator', by: 'archie', reason: 'money' })).status, 200);
    // A claimed row that carries a card (no send yet) is not a received card.
    await post(DB, '/api/unblock/decisions/claim', {
      decision_key: 'w5-claimed', project: 'cromford', subject_kind: 'pr', subject: 'o/r#1', stall_class: 'x',
      rule_cites: ['G14'], evidence: {}, decision: 'escalate', mode: 'act',
    });
    db.prepare(`UPDATE unblock_decisions SET card = '{"id":"u-aaaaaa"}' WHERE decision_key = 'w5-claimed'`).run();
    // An escalated row with no card (a record that carried none) is not a card.
    await post(DB, '/api/unblock/decisions/claim', {
      decision_key: 'w5-nocard', project: 'cromford', subject_kind: 'pr', subject: 'o/r#2', stall_class: 'x',
      rule_cites: ['G14'], evidence: {}, decision: 'escalate', mode: 'act',
    });
    assert.equal((await post(DB, '/api/unblock/decisions/record', { decision_key: 'w5-nocard', outcome: 'escalated' })).status, 200);
    // Another project's cards.
    const o = await card(DB, db, 'w5-project-3', 'project-3');
    await answer(DB, o, { answer: 'none', answered_by: 'archie', source: 'archie', note: 'x' });
    db.prepare('UPDATE unblock_decisions SET created_at = ?').run(`${day}T12:00:00Z`);
    const r = await call(DB, `/api/unblock/cards/daily?project=cromford&day=${day}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body, { project: 'cromford', day, received: 5, archie: 3, operator: 1, false: 1, acted: 1 });
    const none = await call(DB, `/api/unblock/cards/daily?project=project-4&day=${day}`);
    assert.deepEqual(none.body, { project: 'project-4', day, received: 0, archie: 0, operator: 0, false: 0, acted: 0 });
    const other = await call(DB, `/api/unblock/cards/daily?project=cromford&day=2020-01-01`);
    assert.equal(other.body.received, 0, 'another day reads 0');
    for (const q of ['project=BAD&day=2026-11-01', 'project=cromford&day=2026-13-01', 'project=cromford&day=yesterday', 'day=2026-11-01', 'project=cromford']) {
      assert.equal((await call(DB, `/api/unblock/cards/daily?${q}`)).status, 400, q);
    }
  });

  await t.test('W6 EXPLAIN QUERY PLAN at 50 000 rows', async () => {
    const { db, DB } = await openDb();
    await call(DB, '/api/unblock/decisions?outcome=escalated&project=cromford'); // ensureColumns
    const ins = db.prepare(`INSERT INTO unblock_decisions (decision_key, agent, project, subject_kind, subject, stall_class,
      rule_cites, evidence, decision, mode, outcome, card, created_at, answer_source, routed_to)
      VALUES (?, 'tackler', ?, 'pr', 's', 'x', 'G1', '{}', 'escalate', 'act', ?, ?, ?, ?, ?)`);
    const projects = ['cromford', 'project-3', 'project-4', 'project-1', 'project-5'];
    const outcomes = ['would', 'escalated', 'answered', 'expired', 'claimed'];
    const base = Date.parse('2026-04-20T00:00:00Z');
    db.exec('BEGIN');
    for (let i = 0; i < 50000; i++) {
      const at = new Date(base + i * 300000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const out = outcomes[i % 5];
      ins.run(`w6-${i}`, projects[i % 5], out, out === 'would' ? null : '{"id":"u-000001"}', at,
        i % 3 === 0 ? 'archie' : null, i % 7 === 0 ? 'operator' : null);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    for (const [name, sql, binds, idx] of [
      ['daily', DAILY_SQL, ['2026-10-01T00:00:00Z', '2026-10-02T00:00:00Z', 'cromford'], 'idx_unblock_decisions_created'],
      ['repeats', REPEATS_SQL, ['2026-10-01T00:00:00Z', 3, 50], 'idx_unblock_decisions_created'],
      ['list outcome+project', listSql({ outcome: true, project: true }, { cards: true }), ['escalated', 'cromford', null, null, 101], 'idx_unblock_decisions_outcome_project'],
    ]) {
      const lines = planOf(sql, binds);
      assert.ok(lines.some((l) => l.includes(idx)), `${name}: ${idx} not used: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /SCAN unblock_decisions\b/.test(l) && !/USING/.test(l)), `${name}: full scan: ${lines.join(' | ')}`);
    }
  });

  await t.test('W7 ensureColumns adds the seven columns; the list returns them', async () => {
    const { db, DB } = await openDb();
    const have = () => db.prepare('PRAGMA table_info(unblock_decisions)').all().map((c) => c.name);
    for (const c of NEW_COLS) assert.ok(!have().includes(c), `${c} is not in the composed CREATE (added by core.d)`);
    const id = await card(DB, db, 'w7-a');
    const g = await call(DB, '/api/unblock/decisions?outcome=escalated&project=cromford');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    for (const c of NEW_COLS) assert.ok(have().includes(c), `${c} added`);
    const row = g.body.decisions.find((d) => d.id === id);
    for (const c of NEW_COLS) assert.ok(Object.hasOwn(row, c), `list row carries ${c}`);
    assert.equal(row.card.route, 'archie');
  });

  await t.test('W8 the four seed rows', async () => {
    const f = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-8817-archie-cards\.sql$/.test(n));
    assert.ok(f, 'schema.d/<stamp>-bh-8817-archie-cards.sql exists');
    assert.ok(!/CREATE TABLE/i.test(readFileSync(new URL(f, SCHEMA_D), 'utf8')), 'no table');
    const { db } = await openDb();
    const s = (k) => db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value;
    assert.equal(s('unblock.route_to'), 'archie');
    assert.equal(s('unblock.archie_answer_max_min'), '60');
    assert.equal(s('unblock.archie_claim_lease_min'), '15');
    assert.equal(s('budget.stage.archie-card.day_usd'), '10');
  });
  await t.test('W9 cards/repeats', async () => {
    const { DB, db } = await openDb();
    const acted = { answer: 'acted', lever: 'requeue', answered_by: 'archie', source: 'archie', note: 'requeued' };
    for (let i = 0; i < 3; i++) await answer(DB, await card(DB, db, `w9-rq${i}`), acted);
    for (let i = 0; i < 2; i++) {
      await answer(DB, await card(DB, db, `w9-no${i}`, 'cromford', 'archie', 'box-hung'), { answer: 'none', answered_by: 'archie', source: 'archie', note: 'up' });
    }
    // Another project, a person's answer and an open card are their own groups or none.
    await answer(DB, await card(DB, db, 'w9-project-3', 'project-3'), acted);
    await answer(DB, await card(DB, db, 'w9-person'), { answer: 'hold', answered_by: 'operator@example.com' });
    await card(DB, db, 'w9-open');
    db.prepare("UPDATE unblock_decisions SET created_at = '2026-10-20T12:00:00Z'").run();
    db.prepare("UPDATE unblock_decisions SET created_at = '2026-09-01T12:00:00Z' WHERE decision_key = 'w9-rq0'").run();
    const r = await call(DB, '/api/unblock/cards/repeats?since=2026-10-01T00:00:00Z&min=2&limit=50');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.repeats.map((g) => [g.project, g.stall_class, g.answer, g.lever, g.n]), [
      ['cromford', 'box-hung', 'none', '', 2],
      ['cromford', 'pr-ejected', 'acted', 'requeue', 2],
    ], 'a tie on n: the newest group first');
    assert.equal(r.body.repeats[1].last_id, rowOf(db, 'w9-rq2').id);
    const wide = await call(DB, '/api/unblock/cards/repeats?since=2026-08-01T00:00:00Z&min=3&limit=50');
    assert.deepEqual(wide.body.repeats.map((g) => [g.lever, g.n]), [['requeue', 3]], 'the window and min=3');
    const one = await call(DB, '/api/unblock/cards/repeats?since=2026-10-01T00:00:00Z&min=2&limit=1');
    assert.equal(one.body.repeats.length, 1, 'limit');
    for (const q of ['min=2&limit=5', 'since=2026-10-01&min=2&limit=5', 'since=2026-10-01T00:00:00Z&min=1&limit=5',
      'since=2026-10-01T00:00:00Z&min=101&limit=5', 'since=2026-10-01T00:00:00Z&min=2&limit=0', 'since=2026-10-01T00:00:00Z&min=2']) {
      assert.equal((await call(DB, `/api/unblock/cards/repeats?${q}`)).status, 400, q);
    }
  });
  await t.test('W10 cards/daily: operator counts the cards sent to the operator direct', async () => {
    const { DB, db } = await openDb();
    const day = '2026-10-30';
    // direct <key> <card> — a claimed + escalated row with this card JSON.
    const direct = async (key, c, project = 'cromford') => {
      assert.equal((await post(DB, '/api/unblock/decisions/claim', {
        decision_key: key, project, subject_kind: 'build', subject: `${project}:BH-1`, stall_class: 'ticket-plan-blocked',
        rule_cites: ['U14-ASK'], evidence: {}, decision: 'escalate', mode: 'act',
      })).status, 200);
      assert.equal((await post(DB, '/api/unblock/decisions/record', { decision_key: key, outcome: 'escalated', card: c })).status, 200);
    };
    const a1 = await card(DB, db, 'w10-hold');
    const a2 = await card(DB, db, 'w10-none');
    const a3 = await card(DB, db, 'w10-routed');
    assert.equal((await answer(DB, a1, { answer: 'hold', answered_by: 'archie', source: 'archie' })).status, 200);
    assert.equal((await answer(DB, a2, { answer: 'none', answered_by: 'archie', source: 'archie', note: 'merged' })).status, 200);
    assert.equal((await post(DB, `/api/unblock/decisions/${a3}/route`, { to: 'operator', by: 'archie', reason: 'money' })).status, 200);
    // BH-8736's ask card: .lifecycle, no .route (act.sh _ub_ask sends it to the operator).
    await direct('w10-ask', { id: 'u-a5a5a5', options: ['plan again', 'hold'], lifecycle: { project: 'cromford', ticket_key: 'BH-1' } });
    // A card Tackler sent with route operator (unblock.route_to = operator).
    await card(DB, db, 'w10-operator', 'cromford', 'operator');
    // Another project's direct card: the wrong tenant.
    await direct('w10-project-3', { id: 'u-b6b6b6', options: ['a', 'b'] }, 'project-3');
    db.prepare('UPDATE unblock_decisions SET created_at = ?').run(`${day}T08:00:00Z`);
    const r = await call(DB, `/api/unblock/cards/daily?project=cromford&day=${day}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body, { project: 'cromford', day, received: 5, archie: 2, operator: 3, false: 1, acted: 0 });
    const none = await call(DB, `/api/unblock/cards/daily?project=project-4&day=${day}`);
    assert.deepEqual(none.body, { project: 'project-4', day, received: 0, archie: 0, operator: 0, false: 0, acted: 0 });
    const project-3 = await call(DB, `/api/unblock/cards/daily?project=project-3&day=${day}`);
    assert.deepEqual([project-3.body.received, project-3.body.operator], [1, 1], 'the other project counts only its own card');
  });
});
