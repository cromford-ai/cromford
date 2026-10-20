// BH-7728 (UNB-6): the Tackler ledger's read side and override write, driven
// through the REAL worker.fetch over the REAL composed schema (the node:sqlite
// D1 shim). UNB-0 (#7722) owns unblock_decisions and is not on main yet, so
// every test that needs the table creates it with the DDL copied verbatim from
// the spec section "The decision ledger" (CREATE ... IF NOT EXISTS, so this
// suite stays green after UNB-0's fragment lands).
//
//   R1  a seeded week: decisions/day, escalations/day, override rate, stall
//       median and p95 by nearest rank, the per-day trend; the route output
//       equals tests/fixtures/unblock/bh-7728/metrics-week.json (the bash and
//       console readers' fixture) key for key
//   R2  rows of project B never appear in project A's metrics or list
//   R3  the list: newest first, before_id pages, limit capped, evidence cut
//   R4  400 on bad project, days, to, before_id, limit, since
//   R4b days defaults to the settings row unblock.metrics_days, else 7
//   R5  candidates: done acts with no override inside the window only
//   R6  the override write sets once; the delegation route writes its audit row
//   R7  EXPLAIN QUERY PLAN at 50 000 rows: every read uses an index
//   R8  no table: every route answers 503 "unblock_decisions schema not applied"
//   R9  the four paths resolve through the gated route table
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { ROUTES } from './lib/routes.node.js';
import { matchRoute } from '../src/lib/router.js';
import { METRICS_WINDOW_SQL, DECISIONS_PAGE_SQL, CANDIDATES_SQL } from '../src/routes/unblock-metrics.js';

const SECRET = 'test-secret';
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

// The spec's DDL ("The decision ledger"), verbatim.
const LEDGER_DDL = `
CREATE TABLE IF NOT EXISTS unblock_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  decision_key TEXT NOT NULL UNIQUE,
  agent TEXT NOT NULL DEFAULT 'tackler',
  project TEXT NOT NULL,
  repo TEXT,
  subject_kind TEXT NOT NULL CHECK (subject_kind IN
    ('pr','batch','build','box','lane','setting')),
  subject TEXT NOT NULL,
  head TEXT,
  stall_class TEXT NOT NULL,
  rule_id TEXT,
  rule_cites TEXT NOT NULL,
  evidence TEXT NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('act','escalate','refuse','digest')),
  action TEXT,
  action_args TEXT,
  mode TEXT NOT NULL CHECK (mode IN ('shadow','act')),
  outcome TEXT NOT NULL DEFAULT 'claimed' CHECK (outcome IN
    ('claimed','would','done','failed','refused','no-route',
     'escalated','answered','expired')),
  outcome_detail TEXT,
  card TEXT,
  answer TEXT, answered_by TEXT, answered_at TEXT,
  model_calls INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0,
  override_by TEXT, override_at TEXT, override_detail TEXT,
  created_at TEXT NOT NULL, acted_at TEXT, resolved_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_subject_id ON unblock_decisions(subject, id);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_project_id ON unblock_decisions(project, id);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_outcome_project ON unblock_decisions(outcome, project, id);
CREATE INDEX IF NOT EXISTS idx_unblock_decisions_created ON unblock_decisions(created_at);
`;
const ledgerDb = async () => {
  const o = await openDb();
  o.db.exec(LEDGER_DDL);
  return o;
};

const ms = (iso) => Date.parse(iso);
const isoOf = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
const plusMin = (iso, m) => isoOf(ms(iso) + m * 60000);
let keyN = 0;
// One ledger row in the shape UNB-0's record route writes.
const addRow = (db, r) => {
  const row = {
    project: 'cromford', repo: 'example-org/cromford', subject_kind: 'pr',
    subject: 'example-org/cromford#7617', head: 'a'.repeat(40), stall_class: 'lead-block',
    rule_id: 'U1', rule_cites: 'G1,G12', evidence: '{}', decision: 'act', action: 'post_block',
    action_args: null, mode: 'act', outcome: 'done', outcome_detail: null,
    override_by: null, override_at: null, override_detail: null, acted_at: null, ...r,
  };
  const info = db.prepare(
    `INSERT INTO unblock_decisions (decision_key, project, repo, subject_kind, subject, head, stall_class, rule_id,
       rule_cites, evidence, decision, action, action_args, mode, outcome, outcome_detail,
       override_by, override_at, override_detail, created_at, acted_at)
     VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`
  ).run(`k-${++keyN}`, row.project, row.repo, row.subject_kind, row.subject, row.head, row.stall_class, row.rule_id,
    row.rule_cites, row.evidence, row.decision, row.action, row.action_args, row.mode, row.outcome, row.outcome_detail,
    row.override_by, row.override_at, row.override_detail, row.created_at, row.acted_at);
  return Number(info.lastInsertRowid);
};
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 't', 't', 'x') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);

// The seeded week of R1. Window: to=2026-10-20 days=7 = 2026-10-13..2026-10-19.
const DAYS = ['2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17', '2026-10-18', '2026-10-19'];
const seedWeek = (db, project) => {
  for (let i = 0; i < 21; i++) {
    const created = `${DAYS[Math.floor(i / 3)]}T0${1 + (i % 3)}:00:00Z`;
    const acted = plusMin(created, 5);
    addRow(db, {
      project, created_at: created, acted_at: acted, rule_id: i % 2 === 0 ? 'U1' : 'U6',
      evidence: JSON.stringify({ stall_at: plusMin(acted, -(i + 1) * 10) }),
      ...(i === 4 || i === 10 ? { override_by: 'operator', override_at: plusMin(acted, 60), override_detail: 'verdict: #1' } : {}),
    });
  }
  // 7 shadow rows, one a day, no stall_at: stall unknown.
  for (const d of DAYS) addRow(db, { project, created_at: `${d}T05:00:00Z`, mode: 'shadow', outcome: 'would' });
  // 4 cards: day 0 escalated (stall 300), day 1 answered (stall 400), day 2
  // expired, day 3 the uncovered U12 (no rule id).
  const card = { decision: 'escalate', action: null, mode: 'act' };
  addRow(db, { ...card, project, created_at: `${DAYS[0]}T06:00:00Z`, outcome: 'escalated', evidence: JSON.stringify({ stall_at: plusMin(`${DAYS[0]}T06:00:00Z`, -300) }) });
  addRow(db, { ...card, project, created_at: `${DAYS[1]}T06:00:00Z`, outcome: 'answered', evidence: JSON.stringify({ stall_at: plusMin(`${DAYS[1]}T06:00:00Z`, -400) }) });
  addRow(db, { ...card, project, created_at: `${DAYS[2]}T06:00:00Z`, outcome: 'expired' });
  addRow(db, { ...card, project, created_at: `${DAYS[3]}T06:00:00Z`, outcome: 'escalated', rule_id: null, rule_cites: 'spend' });
  // A refusal counts in nothing; the rows outside the window count in nothing.
  addRow(db, { project, created_at: `${DAYS[4]}T07:00:00Z`, decision: 'refuse', outcome: 'refused' });
  addRow(db, { project, created_at: '2026-10-12T23:59:59Z', acted_at: '2026-10-13T00:05:00Z' });
  addRow(db, { project, created_at: '2026-10-20T00:00:00Z', acted_at: '2026-10-20T00:05:00Z' });
};

const FIXTURE = new URL('../../../tests/fixtures/unblock/bh-7728/metrics-week.json', import.meta.url);

test('BH-7728 unblock metrics routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 a seeded week gives the exact metrics', async () => {
    const { db, DB } = await ledgerDb();
    seedWeek(db, 'p-r1-week');
    const r = await call(DB, '/api/unblock/metrics?project=p-r1-week&days=7&to=2026-10-20');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const b = r.body;
    assert.equal(b.project, 'p-r1-week');
    assert.equal(b.days, 7);
    assert.equal(b.from, '2026-10-13T00:00:00Z');
    assert.equal(b.to, '2026-10-20T00:00:00Z');
    assert.equal(b.totals.decisions_per_day, 3);
    assert.equal(b.totals.escalations_per_day, 0.57);
    assert.equal(b.totals.override_rate, 0.0952);
    // 23 stall values {10..210 step 10, 300, 400}: rank 12 = 120, rank 22 = 300.
    assert.equal(b.totals.stall_median_min, 120);
    assert.equal(b.totals.stall_p95_min, 300);
    assert.equal(b.totals.stall_unknown, 9);
    assert.equal(b.expired_cards, 1);
    assert.equal(b.uncovered, 1);
    assert.equal(b.truncated, false);
    assert.deepEqual(b.daily.map((d) => d.day), DAYS);
    for (const d of b.daily) {
      for (const k of ['day', 'decisions', 'would', 'escalations', 'overrides', 'stall_median_min', 'stall_p95_min']) {
        assert.ok(k in d, `daily[] has ${k}`);
      }
      assert.equal(d.decisions, 3);
      assert.equal(d.would, 1);
    }
    assert.deepEqual(b.daily.map((d) => d.escalations), [1, 1, 1, 1, 0, 0, 0]);
    assert.deepEqual(b.daily.map((d) => d.overrides), [0, 1, 0, 1, 0, 0, 0]);
    assert.deepEqual([b.daily[0].stall_median_min, b.daily[0].stall_p95_min], [20, 300]);
    assert.deepEqual([b.daily[1].stall_median_min, b.daily[1].stall_p95_min], [50, 400]);
    assert.deepEqual([b.daily[2].stall_median_min, b.daily[2].stall_p95_min], [80, 90]);
    const rules = Object.fromEntries(b.rules.map((x) => [x.rule_id, x]));
    assert.deepEqual([rules.U1.acts, rules.U1.overrides], [11, 2]);
    assert.deepEqual([rules.U6.acts, rules.U6.overrides], [10, 0]);
    // The readers' fixture is this output, key for key.
    const fx = JSON.parse(readFileSync(FIXTURE, 'utf8'));
    assert.deepEqual(fx, b, 'tests/fixtures/unblock/bh-7728/metrics-week.json drifted from the route output');
  });

  await t.test('R1b zero decisions: override_rate is null, stall null', async () => {
    const { DB } = await ledgerDb();
    const r = await call(DB, '/api/unblock/metrics?project=p-empty&days=3&to=2026-10-20');
    assert.equal(r.status, 200);
    assert.equal(r.body.totals.override_rate, null);
    assert.equal(r.body.totals.decisions_per_day, 0);
    assert.equal(r.body.totals.stall_median_min, null);
    assert.equal(r.body.daily.length, 3);
  });

  await t.test('R2 project B rows never appear in project A', async () => {
    const { db, DB } = await ledgerDb();
    seedWeek(db, 'p-r2-b');
    addRow(db, { project: 'p-r2-a', created_at: '2026-10-15T01:00:00Z', acted_at: '2026-10-15T01:05:00Z' });
    const m = await call(DB, '/api/unblock/metrics?project=p-r2-a&days=7&to=2026-10-20');
    assert.equal(m.body.daily.reduce((s, d) => s + d.decisions, 0), 1);
    assert.equal(m.body.expired_cards, 0);
    const l = await call(DB, '/api/unblock/metrics/decisions?project=p-r2-a');
    assert.equal(l.body.decisions.length, 1);
    assert.ok(l.body.decisions.every((x) => x.project === 'p-r2-a'));
    const none = await call(DB, '/api/unblock/metrics/decisions?project=p-r2-none');
    assert.equal(none.body.decisions.length, 0);
  });

  await t.test('R3 the list pages newest first and cuts evidence', async () => {
    const { db, DB } = await ledgerDb();
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push(addRow(db, { project: 'p-r3', created_at: `2026-10-15T0${i}:00:00Z` }));
    const big = addRow(db, { project: 'p-r3', created_at: '2026-10-15T09:00:00Z', evidence: JSON.stringify({ x: 'y'.repeat(5000) }) });
    const p1 = await call(DB, '/api/unblock/metrics/decisions?project=p-r3&limit=3');
    assert.equal(p1.status, 200);
    assert.deepEqual(p1.body.decisions.map((x) => x.id), [big, ids[4], ids[3]]);
    assert.equal(p1.body.decisions[0].evidence.length, 2048);
    assert.equal(p1.body.decisions[0].evidence_truncated, true);
    assert.equal(p1.body.decisions[1].evidence_truncated, false);
    assert.equal(p1.body.next_before_id, ids[3]);
    const p2 = await call(DB, `/api/unblock/metrics/decisions?project=p-r3&limit=3&before_id=${ids[3]}`);
    assert.deepEqual(p2.body.decisions.map((x) => x.id), [ids[2], ids[1], ids[0]]);
    const p3 = await call(DB, `/api/unblock/metrics/decisions?project=p-r3&limit=3&before_id=${ids[0]}`);
    assert.deepEqual(p3.body.decisions, []);
    assert.equal(p3.body.next_before_id, null);
    for (const k of ['id', 'created_at', 'acted_at', 'project', 'repo', 'subject_kind', 'subject', 'head', 'rule_id',
      'rule_cites', 'decision', 'action', 'mode', 'outcome', 'outcome_detail', 'override_by', 'override_at',
      'override_detail', 'evidence', 'evidence_truncated']) {
      assert.ok(k in p1.body.decisions[0], `row has ${k}`);
    }
    assert.equal((await call(DB, '/api/unblock/metrics/decisions?project=p-r3')).body.limit, 50);
  });

  await t.test('R4 bad input is 400, never an unfiltered read', async () => {
    const { DB } = await ledgerDb();
    for (const q of [
      '/api/unblock/metrics', '/api/unblock/metrics?project=', '/api/unblock/metrics?project=Bad%20Name',
      '/api/unblock/metrics?project=p&days=0&to=2026-10-20', '/api/unblock/metrics?project=p&days=31&to=2026-10-20',
      '/api/unblock/metrics?project=p&days=x&to=2026-10-20',
      '/api/unblock/metrics?project=p&to=2026-13-01', '/api/unblock/metrics?project=p&to=yesterday',
      '/api/unblock/metrics/decisions', '/api/unblock/metrics/decisions?project=p&before_id=abc',
      '/api/unblock/metrics/decisions?project=p&limit=0', '/api/unblock/metrics/decisions?project=p&limit=101',
      '/api/unblock/overrides/candidates', '/api/unblock/overrides/candidates?since=2026-10-18',
    ]) {
      const r = await call(DB, q);
      assert.equal(r.status, 400, `${q} -> ${r.status} ${JSON.stringify(r.body)}`);
    }
  });

  await t.test('R4b days default comes from the settings row, else 7', async () => {
    const { db, DB } = await ledgerDb();
    assert.equal((await call(DB, '/api/unblock/metrics?project=p&to=2026-10-20')).body.days, 7);
    setting(db, 'unblock.metrics_days', '14');
    assert.equal((await call(DB, '/api/unblock/metrics?project=p&to=2026-10-20')).body.days, 14);
    setting(db, 'unblock.metrics_days', 'junk');
    assert.equal((await call(DB, '/api/unblock/metrics?project=p&to=2026-10-20')).body.days, 7);
    setting(db, 'unblock.metrics_days', '99');
    assert.equal((await call(DB, '/api/unblock/metrics?project=p&to=2026-10-20')).body.days, 7);
  });

  await t.test('R5 candidates: un-overridden done acts in the window only', async () => {
    const { db, DB } = await ledgerDb();
    const want = addRow(db, { project: 'p-r5', created_at: '2026-10-19T10:00:00Z', acted_at: '2026-10-19T10:05:00Z',
      action_args: '{"verdict":"BLOCK"}' });
    addRow(db, { project: 'p-r5', created_at: '2026-10-19T11:00:00Z', outcome: 'would', mode: 'shadow' });
    addRow(db, { project: 'p-r5', created_at: '2026-10-19T12:00:00Z', acted_at: '2026-10-19T12:05:00Z', override_by: 'operator' });
    addRow(db, { project: 'p-r5', created_at: '2026-10-19T13:00:00Z', outcome: 'failed' });
    addRow(db, { project: 'p-r5', created_at: '2026-10-19T14:00:00Z', decision: 'escalate', outcome: 'escalated' });
    addRow(db, { project: 'p-r5', created_at: '2026-10-16T10:00:00Z', acted_at: '2026-10-16T10:05:00Z' });
    const r = await call(DB, '/api/unblock/overrides/candidates?since=2026-10-18T12:00:00Z');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.candidates.map((x) => x.id), [want]);
    const c = r.body.candidates[0];
    assert.equal(c.action, 'post_block');
    assert.equal(c.action_args, '{"verdict":"BLOCK"}');
    assert.equal(c.acted_at, '2026-10-19T10:05:00Z');
    assert.equal(c.head, 'a'.repeat(40));
    assert.equal(c.rule_id, 'U1');
    assert.equal(r.body.truncated, false);
  });

  await t.test('R6 the override write sets once; the demote writes its audit row', async () => {
    const { db, DB } = await ledgerDb();
    const id = addRow(db, { project: 'p-r6', created_at: '2026-10-19T10:00:00Z', acted_at: '2026-10-19T10:05:00Z' });
    const shadow = addRow(db, { project: 'p-r6', created_at: '2026-10-19T10:00:00Z', decision: 'escalate', outcome: 'escalated' });
    const post = (body) => call(DB, '/api/unblock/overrides', { method: 'POST', body });
    const body = { id, override_by: 'operator', override_at: '2026-10-19T13:05:00Z', override_detail: 'verdict: #91; demote: changed' };
    for (const [k, v] of [['id', 'x'], ['override_by', ''], ['override_at', 'soon'], ['override_detail', 'x'.repeat(501)]]) {
      assert.equal((await post({ ...body, [k]: v })).status, 400, `bad ${k}`);
    }
    const first = await post(body);
    assert.equal(first.status, 200, JSON.stringify(first.body));
    assert.equal(first.body.ok, true);
    assert.equal(first.body.existing, undefined);
    const again = await post({ ...body, override_by: 'someone-else' });
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    const row = db.prepare('SELECT override_by, override_at, override_detail FROM unblock_decisions WHERE id=?').get(id);
    assert.deepEqual({ ...row }, { override_by: 'operator', override_at: '2026-10-19T13:05:00Z', override_detail: 'verdict: #91; demote: changed' });
    assert.equal((await post({ ...body, id: 999999 })).status, 404);
    assert.equal((await post({ ...body, id: shadow })).status, 409);
    // The demote half of the pair override.sh drives.
    db.prepare(`INSERT INTO staff_agents (name, role, accountable, autonomy, cap, status, soul_path, updated_at)
      VALUES ('tackler', 'unblock', 'operator@example.com', 'automation', 'autonomy', 'active', 'prompts/staff/tackler-soul.md', '2026-10-20T00:00:00Z')`).run();
    db.prepare(`INSERT INTO staff_classes (agent, class, cap, state, streak, delegated_at, updated_at)
      VALUES ('tackler', 'queue-requeue', 'autonomy', 'delegated', 5, '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z')`).run();
    const d = await call(DB, '/api/staff/classes/delegation', { method: 'POST', body: {
      agent: 'tackler', class: 'queue-requeue', decision: 'ask_first', actor: 'unblock-override', reason: `override of decision #${id} by operator` } });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    assert.ok(Number.isInteger(d.body.change_id));
    const aud = db.prepare("SELECT * FROM staff_autonomy_changes WHERE agent='tackler'").all();
    assert.equal(aud.length, 1);
    assert.equal(aud[0].to_value, 'ask_first');
    assert.equal(aud[0].actor, 'unblock-override');
  });

  await t.test('R7 EXPLAIN at 50 000 rows: every read uses an index', async () => {
    const { db } = await ledgerDb();
    const ins = db.prepare(`INSERT INTO unblock_decisions (decision_key, project, subject_kind, subject, stall_class, rule_cites,
      evidence, decision, mode, outcome, created_at, acted_at) VALUES (?, ?, 'pr', ?, 's', 'G1', '{}', ?, 'act', ?, ?, ?)`);
    db.exec('BEGIN');
    const base = ms('2026-04-20T00:00:00Z');
    for (let i = 0; i < 50000; i++) {
      const at = isoOf(base + i * 300000);
      ins.run(`v-${i}`, ['cromford', 'project-3', 'project-4'][i % 3], `o/r#${i % 900}`, i % 7 ? 'act' : 'escalate',
        ['done', 'would', 'escalated', 'refused'][i % 4], at, at);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const planOf = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((r) => r.detail);
    const checks = [
      [METRICS_WINDOW_SQL, ['2026-10-13T00:00:00Z', '2026-10-20T00:00:00Z', 'cromford', 20001], 'idx_unblock_decisions_created'],
      [DECISIONS_PAGE_SQL, ['cromford', 40000, 51], 'idx_unblock_decisions_project_id'],
      [DECISIONS_PAGE_SQL, ['cromford', null, 51], 'idx_unblock_decisions_project_id'],
      [CANDIDATES_SQL, ['2026-10-18T00:00:00Z', 201], 'idx_unblock_decisions_created'],
    ];
    for (const [sql, binds, idx] of checks) {
      const lines = planOf(sql, ...binds);
      assert.ok(lines.some((l) => l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /^SCAN unblock_decisions\b/.test(l) && !/USING/.test(l)), `full scan: ${lines.join(' | ')}`);
    }
  });

  await t.test('R8 no table: every route answers 503 schema not applied', async () => {
    const { DB } = await openDb();
    for (const [method, path, body] of [
      ['GET', '/api/unblock/metrics?project=cromford&days=7&to=2026-10-20'],
      ['GET', '/api/unblock/metrics/decisions?project=cromford'],
      ['GET', '/api/unblock/overrides/candidates?since=2026-10-18T00:00:00Z'],
      ['POST', '/api/unblock/overrides', { id: 1, override_by: 'operator', override_at: '2026-10-19T13:05:00Z', override_detail: 'x' }],
    ]) {
      const r = await call(DB, path, { method, body });
      assert.equal(r.status, 503, `${method} ${path}`);
      assert.equal(r.body.error, 'unblock_decisions schema not applied');
    }
  });

  await t.test('R9 the four paths resolve through the gated route table', () => {
    for (const [m, p] of [['GET', '/api/unblock/metrics'], ['GET', '/api/unblock/metrics/decisions'],
      ['GET', '/api/unblock/overrides/candidates'], ['POST', '/api/unblock/overrides']]) {
      const hit = matchRoute(ROUTES, m, p);
      assert.ok(hit, `${m} ${p} has no route`);
      assert.equal(hit.entry[1], p);
    }
  });
});
