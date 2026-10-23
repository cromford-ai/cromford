// BH-7722 (UNB-0): the Tackler decision ledger. Driven through the REAL
// worker.fetch over the REAL composed schema (the node:sqlite D1 shim), with
// the fragment worker/jobs/schema.d/*-bh-7722-unblock-decisions.sql in it.
//
//   W1  the fragment runs twice on a fresh db with no error; seed counts stay
//   W2  EXPLAIN QUERY PLAN at 50 000 rows: every read names an index, no SCAN
//   W3  the seeds: tackler's roster row, lane, 15 classes, the CHECKs, the
//       settings rows, the two model routes; no allowlist or project-6-os row
//   W4  claim: 200 then 409 with the first id; 400 for each bad field
//   W5  wrong tenant: project A never reads or touches project B's rows
//   W6  record: claimed -> terminal once; 409 / 404 / 400; acted_at, resolved_at
//   W7  the #7762 round trip: escalated card, GET card=, then answer
//   W8  answer: 200, 409 duplicate, 422 not_escalated, 400, 403, 404
//   W9  BH-7728's metrics routes answer 200 over rows the claim route wrote
//   W10 retention: dry run counts terminal rows only; unbound archive moves 0;
//       bound archive copies then deletes; claimed and escalated rows stay
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { validate } from '../../../agent-core/src/index.js';
import { RULES } from '../src/routes/retention.js';
import { METRICS_WINDOW_SQL, DECISIONS_PAGE_SQL, CANDIDATES_SQL } from '../src/routes/unblock-metrics.js';

const SECRET = 'test-secret-fixture';
const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const FRAGMENT = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-7722-unblock-decisions\.sql$/.test(n));
const fragmentSql = () => readFileSync(new URL(FRAGMENT, SCHEMA_D), 'utf8');
const CHARTER = JSON.parse(readFileSync(new URL('../../../agent-core/schema/charter.schema.json', import.meta.url), 'utf8'));

const call = (env, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const e = env.DB ? env : { DB: env };
  return worker.fetch(req, { ...e, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const HEAD = 'b'.repeat(40);
const claimBody = (over = {}) => ({
  decision_key: 'k-default', project: 'cromford', repo: 'example-org/cromford', subject_kind: 'pr',
  subject: 'example-org/cromford#7617', head: HEAD, stall_class: 'pr-ejected', rule_id: 'U2-bystander-requeue',
  rule_cites: ['G1', 'G12'], evidence: { pr: 7617, stall_at: '2026-10-20T13:00:00Z' }, decision: 'act',
  action: 'requeue', action_args: { pr: 7617 }, mode: 'shadow', ...over,
});
const claim = (env, over) => call(env, '/api/unblock/decisions/claim', { method: 'POST', body: claimBody(over) });
const record = (env, body) => call(env, '/api/unblock/decisions/record', { method: 'POST', body });
const answer = (env, id, body) => call(env, `/api/unblock/decisions/${id}/answer`, { method: 'POST', body });
const rowOf = (db, key) => db.prepare('SELECT * FROM unblock_decisions WHERE decision_key = ?').get(key);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','test','2026-10-21T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));

test('BH-7722 unblock decisions ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 the fragment applies twice with no error and no new seed row', async () => {
    assert.ok(FRAGMENT, 'worker/jobs/schema.d/<stamp>-bh-7722-unblock-decisions.sql exists');
    const { db } = await openDb();
    const counts = () => ({
      settings: db.prepare("SELECT count(*) AS n FROM settings WHERE key LIKE 'unblock.%' OR key = 'retention.unblock_decisions.days'").get().n,
      agents: db.prepare("SELECT count(*) AS n FROM staff_agents WHERE name = 'tackler'").get().n,
      lanes: db.prepare("SELECT count(*) AS n FROM staff_lanes WHERE agent = 'tackler'").get().n,
      classes: db.prepare("SELECT count(*) AS n FROM staff_classes WHERE agent = 'tackler'").get().n,
      routes: db.prepare("SELECT count(*) AS n FROM model_routes WHERE role IN ('stage.unblock','unblock.judge')").get().n,
      table: db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='unblock_decisions'").get().n,
    });
    const before = counts();
    assert.equal(before.table, 1);
    assert.equal(before.agents, 1);
    assert.equal(before.classes, 15);
    db.exec(fragmentSql());
    db.exec(fragmentSql());
    assert.deepEqual(counts(), before);
  });

  await t.test('W2 EXPLAIN at 50 000 rows: every ledger read uses an index', async () => {
    const { db } = await openDb();
    const R = await import('../src/routes/unblock-decisions.js');
    const ins = db.prepare(`INSERT INTO unblock_decisions (decision_key, project, subject_kind, subject, stall_class, rule_id,
      rule_cites, evidence, decision, mode, outcome, card, created_at) VALUES (?, ?, 'pr', ?, 's', 'U1', 'G1', '{}', ?, 'shadow', ?, ?, ?)`);
    const projects = ['cromford', 'project-3', 'project-4', 'project-1', 'project-5'];
    const outcomes = ['would', 'done', 'escalated', 'refused', 'answered', 'claimed', 'no-route'];
    const base = Date.parse('2026-04-20T00:00:00Z');
    db.exec('BEGIN');
    for (let i = 0; i < 50000; i++) {
      const at = new Date(base + i * 300000).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const out = outcomes[i % 7];
      ins.run(`w2-${i}`, projects[i % 5], `o/r#${i % 2000}`, out === 'escalated' ? 'escalate' : 'act', out,
        out === 'escalated' ? JSON.stringify({ id: `u-${(i % 4096).toString(16).padStart(6, '0')}`, options: ['a', 'b'] }) : null, at);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
    const ret = RULES.find((r) => r.rule === 'unblock_decisions.age');
    assert.ok(ret, 'retention.js RULES has unblock_decisions.age');
    const checks = [
      ['claim conflict lookup', R.CLAIM_READ_SQL, ['w2-77'], 'sqlite_autoindex_unblock_decisions'],
      ['record', R.RECORD_SQL.replace(/^\s*UPDATE/, 'UPDATE'), ['w2-77', 'would', null, 0, 0, null, '2026-10-21T00:00:00Z', 1, 1], 'sqlite_autoindex_unblock_decisions'],
      ['GET subject', R.listSql({ subject: true, project: true }), ['o/r#17', 'cromford', null, 51], 'idx_unblock_decisions_subject_id'],
      ['GET project', R.listSql({ project: true }), ['cromford', null, 51], 'idx_unblock_decisions_project_id'],
      ['GET project page 2', R.listSql({ project: true }), ['cromford', 30000, 51], 'idx_unblock_decisions_project_id'],
      ['GET outcome+project', R.listSql({ outcome: true, project: true }), ['escalated', 'cromford', null, null, 51], 'idx_unblock_decisions_outcome_project'],
      ['GET outcome', R.listSql({ outcome: true }), ['claimed', null, null, 51], 'idx_unblock_decisions_outcome_project'],
      ['GET card', R.listSql({ outcome: true, card: true }), ['escalated', null, 'u-00000a', 51], 'idx_unblock_decisions_outcome_project'],
      ['answer', R.ANSWER_SQL, [77, '1', 'operator@example.com', '2026-10-21T00:00:00Z', null, null], 'INTEGER PRIMARY KEY'],
      ['retention ids', ret.ids, ['2026-05-01T00:00:00Z', 500], 'idx_unblock_decisions_created'],
      ['BH-7728 metrics', METRICS_WINDOW_SQL, ['2026-10-13T00:00:00Z', '2026-10-20T00:00:00Z', 'cromford', 20001], 'idx_unblock_decisions_created'],
      ['BH-7728 list', DECISIONS_PAGE_SQL, ['cromford', null, 51], 'idx_unblock_decisions_project_id'],
      ['BH-7728 candidates', CANDIDATES_SQL, ['2026-10-18T00:00:00Z', 201], 'idx_unblock_decisions_created'],
    ];
    for (const [name, sql, binds, idx] of checks) {
      assert.equal(typeof sql, 'string', `${name}: the SQL text is exported`);
      const lines = planOf(sql, binds);
      assert.ok(lines.some((l) => l.includes(idx)), `${name}: ${idx} not used: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /SCAN unblock_decisions\b/.test(l) && !/USING/.test(l)), `${name}: full scan: ${lines.join(' | ')}`);
    }
  });

  await t.test('W3 the seeds: roster row, lane, classes, CHECKs, settings, routes', async () => {
    const { db, DB } = await openDb();
    const a = db.prepare("SELECT * FROM staff_agents WHERE name = 'tackler'").get();
    assert.ok(a, 'tackler is on the roster');
    assert.equal(a.role, 'unblock');
    assert.equal(a.accountable, 'operator@example.com');
    assert.equal(a.autonomy, 'automation');
    assert.equal(a.cap, 'autonomy');
    assert.equal(a.status, 'active');
    assert.equal(a.soul_path, 'prompts/staff/tackler-soul.md');
    const r = await call(DB, '/api/staff/agents');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const ch = r.body.agents.find((x) => x.name === 'tackler');
    assert.ok(ch, 'GET /api/staff/agents lists tackler');
    assert.deepEqual(validate(CHARTER, ch), { ok: true, errors: [] });
    assert.deepEqual(ch.lanes, ['unblock']);
    assert.equal(ch.autonomy, 'automation');
    const classes = db.prepare("SELECT * FROM staff_classes WHERE agent = 'tackler' ORDER BY class").all();
    const never = ['client-board', 'deploy', 'governance', 'live-probe', 'merge', 'production', 'spend'];
    const ask = ['fix-round', 'infra-knob', 'queue-approve', 'queue-requeue', 'review-block', 'review-rerequest', 'review-route'];
    assert.deepEqual(classes.map((c) => c.class), [...never, ...ask, 'infra-restart'].sort());
    for (const c of classes) assert.equal(c.cap, 'autonomy', c.class);
    for (const n of never) {
      const c = classes.find((x) => x.class === n);
      assert.equal(c.never_delegable, 1, n);
      assert.equal(c.state, 'ask_first', n);
    }
    for (const n of ask) {
      const c = classes.find((x) => x.class === n);
      assert.equal(c.never_delegable, 0, n);
      assert.equal(c.state, 'ask_first', n);
    }
    const ir = classes.find((x) => x.class === 'infra-restart');
    assert.equal(ir.state, 'delegated', 'comment 6294289621 item 2: box restart delegated from day one');
    assert.equal(ir.never_delegable, 0);
    assert.ok(ir.delegated_at, 'delegated_at is set');
    assert.match(ir.note, /6294289621/);
    assert.throws(() => db.prepare("UPDATE staff_classes SET state='delegated' WHERE agent='tackler' AND class='merge'").run(), /CHECK/);
    assert.throws(() => db.prepare(
      "INSERT INTO staff_classes (agent, class, never_delegable, state, updated_at) VALUES ('tackler','governance-x',1,'delegated','t')"
    ).run(), /CHECK/);
    const s = (k) => db.prepare('SELECT value FROM settings WHERE key = ?').get(k)?.value;
    assert.equal(s('unblock.enabled'), '1');
    assert.equal(s('unblock.project.cromford.mode'), 'shadow');
    assert.equal(s('unblock.standing_approval.cromford'), '1');
    assert.equal(s('retention.unblock_decisions.days'), '180');
    const exec0 = db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role = 'stage.execute' AND position = 0 AND runner = 'claude'").get();
    assert.ok(exec0, 'the base seeds stage.execute rung 0 on claude');
    for (const role of ['stage.unblock', 'unblock.judge']) {
      const m = db.prepare('SELECT model, runner, position FROM model_routes WHERE project IS NULL AND role = ?').all(role);
      assert.equal(m.length, 1, role);
      assert.deepEqual({ ...m[0] }, { model: exec0.model, runner: exec0.runner, position: 0 }, role);
    }
    const text = fragmentSql();
    // stage.unblock is BH-7725's row (one writer per row): it is in the
    // composed schema through that fragment, and this fragment never writes it.
    assert.ok(!/'stage\.unblock'/.test(text), 'this fragment does not seed stage.unblock');
    const r7725 = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-7725-unblock-route\.sql$/.test(n));
    assert.ok(r7725, 'BH-7725 route fragment exists');
    assert.match(readFileSync(new URL(r7725, SCHEMA_D), 'utf8'), /'stage\.unblock'/, 'BH-7725 seeds stage.unblock');
    assert.match(text, /'unblock\.judge'/, 'this fragment seeds unblock.judge');
    assert.ok(!text.includes('unblock.knob_allowlist'), 'the allowlist row is #7762\'s');
    assert.ok(!text.includes('project-6-os'), 'project-6-os rows are #7796\'s');
    assert.ok(!/claude-[a-z]/.test(text), 'no model literal');
  });

  await t.test('W4 claim: 200, then 409 with the first id; 400 per bad field', async () => {
    const { DB, db } = await openDb();
    const a = await claim(DB, { decision_key: 'w4-one' });
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.claimed, true);
    assert.ok(Number.isInteger(a.body.id));
    const row = rowOf(db, 'w4-one');
    assert.equal(row.agent, 'tackler');
    assert.equal(row.outcome, 'claimed');
    assert.equal(row.rule_cites, 'G1,G12');
    assert.deepEqual(JSON.parse(row.evidence), claimBody().evidence);
    assert.equal(JSON.parse(row.action_args).pr, 7617);
    assert.match(row.created_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const b = await claim(DB, { decision_key: 'w4-one', agent: 'archie', subject: 'other' });
    assert.equal(b.status, 409);
    assert.equal(b.body.claimed, false);
    assert.equal(b.body.id, a.body.id);
    assert.equal(b.body.outcome, 'claimed');
    assert.equal(b.body.decision, 'act');
    assert.equal(db.prepare('SELECT count(*) AS n FROM unblock_decisions').get().n, 1);
    assert.equal(rowOf(db, 'w4-one').subject, 'example-org/cromford#7617', 'a 409 writes nothing');
    const u12 = await claim(DB, { decision_key: 'w4-u12', decision: 'escalate', rule_id: null, rule_cites: ['spend'], action: null, action_args: null });
    assert.equal(u12.status, 200, 'an escalate needs no rule_id');
    const bads = [
      ['decision_key', { decision_key: 'bad key!' }],
      ['decision_key', { decision_key: 'x'.repeat(129) }],
      ['project', { project: 'Cromford' }],
      ['subject_kind', { subject_kind: 'ticket' }],
      ['subject', { subject: '' }],
      ['stall_class', { stall_class: '' }],
      ['rule_id', { rule_id: null }],
      ['rule_cites', { rule_cites: [] }],
      ['rule_cites', { rule_cites: 'G1' }],
      ['evidence_too_large', { evidence: { blob: 'e'.repeat(8193) } }],
      ['evidence', { evidence: undefined }],
      ['decision', { decision: 'merge' }],
      ['action_args', { action_args: { blob: 'a'.repeat(8193) } }],
      ['mode', { mode: 'live' }],
      ['head', { head: 'not-a-sha' }],
    ];
    for (const [field, over] of bads) {
      const r = await claim(DB, { decision_key: `w4-bad-${field}`, ...over });
      assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
      assert.equal(r.body.error, field);
    }
    assert.equal(db.prepare("SELECT count(*) AS n FROM unblock_decisions WHERE decision_key LIKE 'w4-bad-%'").get().n, 0);
  });

  await t.test('W5 wrong tenant: project A never reads or touches project B', async () => {
    const { DB } = await openDb();
    for (let i = 0; i < 3; i++) assert.equal((await claim(DB, { decision_key: `w5-b-${i}`, project: 'project-3', subject: `o/b#${i}` })).status, 200);
    assert.equal((await claim(DB, { decision_key: 'w5-a-0', project: 'cromford', subject: 'o/a#0' })).status, 200);
    const a = await call(DB, '/api/unblock/decisions?project=cromford');
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.deepEqual(a.body.decisions.map((d) => d.project), ['cromford']);
    const b = await call(DB, '/api/unblock/decisions?project=cromford&subject=o%2Fb%230');
    assert.deepEqual(b.body.decisions, [], 'a B subject under project A reads 0 rows');
    const c = await call(DB, '/api/unblock/decisions?project=nope-os');
    assert.deepEqual(c.body.decisions, []);
  });

  await t.test('W6 record: one transition out of claimed; timestamps', async () => {
    const { DB, db } = await openDb();
    for (const [k, out] of [['w6-would', 'would'], ['w6-done', 'done'], ['w6-failed', 'failed'], ['w6-refused', 'refused'],
      ['w6-noroute', 'no-route'], ['w6-esc', 'escalated']]) {
      assert.equal((await claim(DB, { decision_key: k })).status, 200);
      const r = await record(DB, { decision_key: k, outcome: out, outcome_detail: `d-${out}`, model_calls: 1, cost_usd: 0.25 });
      assert.equal(r.status, 200, `${out}: ${JSON.stringify(r.body)}`);
      const row = rowOf(db, k);
      assert.equal(row.outcome, out);
      assert.equal(row.outcome_detail, `d-${out}`);
      assert.equal(row.model_calls, 1);
      assert.equal(row.cost_usd, 0.25);
      const acted = ['would', 'done', 'failed', 'refused'].includes(out);
      assert.equal(row.acted_at !== null, acted, `${out} acted_at`);
      assert.equal(row.resolved_at !== null, out !== 'escalated', `${out} resolved_at`);
    }
    const again = await record(DB, { decision_key: 'w6-would', outcome: 'done' });
    assert.equal(again.status, 409);
    assert.equal(again.body.error, 'not_claimed');
    assert.equal(again.body.outcome, 'would');
    assert.equal(rowOf(db, 'w6-would').outcome, 'would', 'a second record changes nothing');
    assert.equal((await record(DB, { decision_key: 'w6-nope', outcome: 'done' })).status, 404);
    for (const out of ['claimed', 'answered', 'expired', 'WOULD']) {
      const r = await record(DB, { decision_key: 'w6-done', outcome: out });
      assert.equal(r.status, 400, out);
      assert.equal(r.body.error, 'outcome');
    }
    assert.equal((await record(DB, { decision_key: 'w6-done', outcome: 'done', model_calls: -1 })).body.error, 'model_calls');
    assert.equal((await record(DB, { decision_key: 'w6-done', outcome: 'done', cost_usd: -0.1 })).body.error, 'cost_usd');
    assert.equal((await record(DB, { decision_key: 'w6-done', outcome: 'done', card: { t: 'c'.repeat(8193) } })).body.error, 'card');
  });

  await t.test('W7 the #7762 reply round trip: escalated card, GET card=, answer', async () => {
    const { DB, db } = await openDb();
    assert.equal((await claim(DB, { decision_key: 'w7-card', decision: 'escalate', rule_id: null, rule_cites: ['G14'] })).status, 200);
    assert.equal((await claim(DB, { decision_key: 'w7-other', decision: 'escalate', rule_id: null, rule_cites: ['G14'] })).status, 200);
    const card = { id: 'u-abc123', what: 'a product choice', options: ['nightly', 'on push', 'both'], recommendation: '1', default: 'stay', deadline_at: '2026-10-22T09:00:00Z' };
    assert.equal((await record(DB, { decision_key: 'w7-card', outcome: 'escalated', card })).status, 200);
    assert.equal((await record(DB, { decision_key: 'w7-other', outcome: 'escalated', card: { ...card, id: 'u-ffffff' } })).status, 200);
    const g = await call(DB, '/api/unblock/decisions?outcome=escalated&card=u-abc123');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.decisions.length, 1);
    const d = g.body.decisions[0];
    assert.equal(d.card.id, 'u-abc123');
    assert.equal(d.card.options.length, 3);
    assert.equal(typeof d.evidence, 'object');
    const implied = await call(DB, '/api/unblock/decisions?card=u-abc123');
    assert.equal(implied.status, 200);
    assert.deepEqual(implied.body.decisions.map((x) => x.id), [d.id], 'card= implies outcome=escalated');
    assert.equal((await call(DB, '/api/unblock/decisions?outcome=done&card=u-abc123')).status, 400);
    assert.equal((await call(DB, '/api/unblock/decisions?card=u-ABC')).status, 400);
    const a = await answer(DB, d.id, { answer: '1', answered_by: 'operator@example.com', command_id: 'tg-1001' });
    assert.equal(a.status, 200, JSON.stringify(a.body));
    const row = rowOf(db, 'w7-card');
    assert.equal(row.outcome, 'answered');
    assert.equal(row.answer, '1');
    assert.equal(row.answered_by, 'operator@example.com');
    assert.equal(row.answer_command_id, 'tg-1001');
    assert.ok(row.answered_at);
    assert.deepEqual((await call(DB, '/api/unblock/decisions?outcome=escalated&card=u-abc123')).body.decisions, []);
  });

  await t.test('W8 answer: duplicate, not escalated, bad option, agent answerer, unknown id', async () => {
    const { DB, db } = await openDb();
    await claim(DB, { decision_key: 'w8', decision: 'escalate', rule_id: null, rule_cites: ['G14'] });
    await record(DB, { decision_key: 'w8', outcome: 'escalated', card: { id: 'u-000008', options: ['a', 'b', 'c'] } });
    const id = rowOf(db, 'w8').id;
    assert.equal((await answer(DB, id, { answer: '4', answered_by: 'operator@example.com' })).status, 400, 'option 4 of 3');
    assert.equal((await answer(DB, id, { answer: '0', answered_by: 'operator@example.com' })).status, 400);
    assert.equal((await answer(DB, id, { answer: 'holdx', answered_by: 'operator@example.com' })).status, 400);
    assert.equal((await answer(DB, id, { answer: '1', answered_by: 'not-an-email' })).status, 400);
    for (const who of ['tackler', 'Archie', 'watchman']) {
      const r = await answer(DB, id, { answer: '1', answered_by: who });
      assert.equal(r.status, 403, who);
      assert.equal(r.body.error, 'agent_answerer');
    }
    assert.equal(rowOf(db, 'w8').outcome, 'escalated', 'no refusal wrote');
    const ok = await answer(DB, id, { answer: 'hold', answered_by: 'operator@example.com', command_id: 'tg-8', note: 'wait for the PRD' });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(rowOf(db, 'w8').outcome_detail, 'wait for the PRD');
    const dup = await answer(DB, id, { answer: 'hold', answered_by: 'operator@example.com', command_id: 'tg-8' });
    assert.equal(dup.status, 409);
    assert.equal(dup.body.duplicate, true);
    const other = await answer(DB, id, { answer: '2', answered_by: 'operator@example.com', command_id: 'tg-9' });
    assert.equal(other.status, 422, 'not escalated is never a 409: unblock-reply.sh reads any 409 as recorded');
    assert.equal(other.body.error, 'not_escalated');
    assert.equal(other.body.outcome, 'answered');
    assert.equal(rowOf(db, 'w8').answer, 'hold', 'the first answer stays');
    assert.equal((await answer(DB, 999999, { answer: '1', answered_by: 'operator@example.com' })).status, 404);
  });

  await t.test('W9 BH-7728 metrics routes answer 200 over rows the claim route wrote', async (tt) => {
    // The clock is pinned (D60): the claim route stamps created_at with it.
    tt.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-21T08:00:00Z') });
    const { DB } = await openDb();
    await claim(DB, { decision_key: 'w9-a' });
    await record(DB, { decision_key: 'w9-a', outcome: 'would' });
    const today = '2026-10-21';
    const m = await call(DB, '/api/unblock/metrics?project=cromford&days=1&to=2026-10-22');
    assert.equal(m.status, 200, JSON.stringify(m.body));
    assert.equal(m.body.daily.find((d) => d.day === today).would, 1);
    const l = await call(DB, '/api/unblock/metrics/decisions?project=cromford');
    assert.equal(l.status, 200, JSON.stringify(l.body));
    assert.equal(l.body.decisions.length, 1);
    assert.equal(l.body.decisions[0].outcome, 'would');
  });

  await t.test('W10 retention archives old terminal rows only, never a bare delete', async (tt) => {
    const NOW = Date.parse('2026-10-21T12:00:00Z');
    tt.mock.timers.enable({ apis: ['Date'], now: NOW });
    const ago = (d) => new Date(NOW - d * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
    const { DatabaseSync } = await import('node:sqlite');
    const seed = (db) => {
      const ins = db.prepare(`INSERT INTO unblock_decisions (decision_key, project, subject_kind, subject, stall_class, rule_id,
        rule_cites, evidence, decision, mode, outcome, created_at) VALUES (?, 'cromford', 'pr', 's', 's', 'U1', 'G1', '{}', 'act', 'shadow', ?, ?)`);
      for (const [k, out, d] of [['old-would', 'would', 200], ['old-done', 'done', 181], ['old-answered', 'answered', 300],
        ['old-claimed', 'claimed', 400], ['old-esc', 'escalated', 400], ['new-would', 'would', 179]]) ins.run(k, out, ago(d));
    };
    const keys = (db) => db.prepare('SELECT decision_key FROM unblock_decisions ORDER BY decision_key').all().map((r) => r.decision_key);
    const run = (env, body = {}) => call(env, '/api/retention/run', { method: 'POST', body });
    const ruleOf = (b) => (b.rules || []).find((x) => x.rule === 'unblock_decisions.age');
    // dry run (the seed): counts the 3 old terminal rows, removes nothing
    {
      const { db, DB } = await openDb();
      seed(db);
      const adb = new DatabaseSync(':memory:');
      const r = await run({ DB, ARCHIVE: d1(adb) });
      assert.equal(r.status, 200, JSON.stringify(r.body));
      const rr = ruleOf(r.body);
      assert.ok(rr, 'the rule runs');
      assert.equal(rr.counted, 3, JSON.stringify(rr));
      assert.equal(rr.removed, 0);
      assert.equal(keys(db).length, 6);
    }
    // archive unbound: nothing leaves
    {
      const { db, DB } = await openDb();
      seed(db);
      setting(db, 'retention.dry_run', '0');
      const r = await run({ DB });
      assert.equal(r.status, 200);
      assert.equal(ruleOf(r.body).removed, 0);
      assert.equal(keys(db).length, 6, 'unbound archive moves and deletes nothing');
    }
    // archive bound: the 3 rows are copied, then deleted; a row that turns
    // non-terminal between the id read and the delete stays (the del guard)
    {
      const flip = { done: false };
      const { db, DB } = await openDb({
        beforeRun(sql) {
          if (!flip.done && /DELETE FROM unblock_decisions/.test(sql)) {
            flip.done = true;
            db.prepare("UPDATE unblock_decisions SET outcome='escalated' WHERE decision_key='old-done'").run();
          }
        },
      });
      seed(db);
      setting(db, 'retention.dry_run', '0');
      const adb = new DatabaseSync(':memory:');
      const r = await run({ DB, ARCHIVE: d1(adb) });
      assert.equal(r.status, 200, JSON.stringify(r.body));
      assert.equal(ruleOf(r.body).error, null, JSON.stringify(ruleOf(r.body)));
      assert.ok(flip.done, 'the delete ran');
      assert.deepEqual(keys(db), ['new-would', 'old-claimed', 'old-done', 'old-esc']);
      const arch = adb.prepare('SELECT decision_key FROM unblock_decisions ORDER BY decision_key').all().map((x) => x.decision_key);
      assert.deepEqual(arch, ['old-answered', 'old-done', 'old-would'], 'copied before the delete');
    }
  });
});
