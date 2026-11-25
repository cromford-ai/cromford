// BH-9924 (slice BH-9956): the flow agent's D1 half, driven through the REAL
// worker.fetch against the composed jobs schema (the node:sqlite D1 shim).
//
//   W1  claim 200 {claimed:true}, then the same key 409 {outcome:'claimed'};
//       a `would` claim stores outcome would
//   W2  record on a claimed row 200 + outcome done; a second record 409
//       not-claimed; record on a would row 409; an unknown key 404
//   W3  count counts only done/failed/escalated rows inside the window; a row
//       at window + 1 s is out; would/claimed/refused rows are out; the
//       flow_agent.count_window_h row changes the window
//   W4  waiting PUT {1,2} then {2,3} leaves {2,3}; `since` kept on the same
//       code and reset on a new code; another project's rows are untouched
//   W5  wrong project: count for (B, A's key) is 0; a PUT for B with [] deletes
//       none of A's rows
//   W6  a bad input is 400 with `field`, and nothing is written
//   W7  a D1 error is 503 with the table name, never an empty 200
//   W9  before/after/detail are cut to the flow_agent.evidence_max_chars row
//   W8  the 4 routes need the bearer; routes-build --print holds the family;
//       flow-agent-panel.js exports []
//   EXPLAIN at 50,000 flow_actions and 5,000 flow_waiting rows: each SQL uses
//       its index, no full SCAN of a flow_ table
//   SEED each seed row of the fragment reads back; no flow-diagnose route row
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const isoAgoS = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok the worker reads the same clock
const req = (DB, method, path, body, { bearer = true } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, text: await res.text() }))
  .then((r) => ({ ...r, body: (() => { try { return JSON.parse(r.text); } catch { return null; } })() }));
const hex = (tag) => (tag.repeat(64)).slice(0, 64);
const claimBody = (over = {}) => ({
  decision_key: hex('a'), project: 'proj-a', ticket_key: 'BH-1', code: 'ready_not_queued',
  action: 'ready_not_queued', episode: '2026-11-24T05:00:00Z', ...over,
});
const insertAction = (db, o) => db.prepare(`INSERT INTO flow_actions (decision_key, project, ticket_key, code, action, episode, outcome, created_at, updated_at)
  VALUES (?,?,?,?,?,?,?,?,?)`).run(o.key, o.project, o.ticket, 'ready_not_queued', 'ready_not_queued', 'ep', o.outcome, o.at, o.at);
const waitingOf = (db, project) => db.prepare('SELECT ticket_key, cause_code, since FROM flow_waiting WHERE project=? ORDER BY ticket_key').all(project).map((r) => ({ ...r }));

test('BH-9924 flow-agent routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 claim 200, then 409 on the same key; a would claim stores would', async () => {
    const { DB, db } = await openDb();
    const r1 = await req(DB, 'POST', '/api/flow-agent/claim', claimBody({ before: 'verdict:ready,queue:none,job:0,pr:none', box: 'box-1' }));
    assert.equal(r1.status, 200, r1.text);
    assert.equal(r1.body.claimed, true);
    assert.equal(typeof r1.body.id, 'number');
    const r2 = await req(DB, 'POST', '/api/flow-agent/claim', claimBody());
    assert.equal(r2.status, 409, r2.text);
    assert.equal(r2.body.error, 'duplicate');
    assert.equal(r2.body.outcome, 'claimed');
    const r3 = await req(DB, 'POST', '/api/flow-agent/claim', claimBody({ decision_key: hex('b'), outcome: 'would' }));
    assert.equal(r3.status, 200, r3.text);
    const rows = db.prepare('SELECT decision_key, outcome, before_state, box FROM flow_actions ORDER BY id').all();
    assert.equal(rows.length, 2);
    assert.equal(rows[0].outcome, 'claimed');
    assert.equal(rows[0].before_state, 'verdict:ready,queue:none,job:0,pr:none');
    assert.equal(rows[0].box, 'box-1');
    assert.equal(rows[1].outcome, 'would');
  });

  await t.test('W2 record is a CAS on outcome=claimed', async () => {
    const { DB, db } = await openDb();
    await req(DB, 'POST', '/api/flow-agent/claim', claimBody({ decision_key: hex('c') }));
    await req(DB, 'POST', '/api/flow-agent/claim', claimBody({ decision_key: hex('d'), outcome: 'would' }));
    const r1 = await req(DB, 'POST', '/api/flow-agent/record', { decision_key: hex('c'), outcome: 'done', after: 'verdict:ready,queue:queued,job:0,pr:none', detail: 'ok' });
    assert.equal(r1.status, 200, r1.text);
    const row = db.prepare('SELECT outcome, after_state, detail FROM flow_actions WHERE decision_key=?').get(hex('c'));
    assert.equal(row.outcome, 'done');
    assert.equal(row.after_state, 'verdict:ready,queue:queued,job:0,pr:none');
    assert.equal(row.detail, 'ok');
    const r2 = await req(DB, 'POST', '/api/flow-agent/record', { decision_key: hex('c'), outcome: 'failed' });
    assert.equal(r2.status, 409, r2.text);
    assert.equal(r2.body.error, 'not-claimed');
    assert.equal(r2.body.outcome, 'done');
    assert.equal(db.prepare('SELECT outcome FROM flow_actions WHERE decision_key=?').get(hex('c')).outcome, 'done');
    const r3 = await req(DB, 'POST', '/api/flow-agent/record', { decision_key: hex('d'), outcome: 'done' });
    assert.equal(r3.status, 409, r3.text);
    assert.equal(r3.body.outcome, 'would');
    const r4 = await req(DB, 'POST', '/api/flow-agent/record', { decision_key: hex('e'), outcome: 'done' });
    assert.equal(r4.status, 404, r4.text);
  });

  await t.test('W9 before/after/detail are cut to flow_agent.evidence_max_chars, never refused', async () => {
    const { DB, db } = await openDb();
    db.exec("UPDATE settings SET value='4' WHERE key='flow_agent.evidence_max_chars'");
    const c = await req(DB, 'POST', '/api/flow-agent/claim', claimBody({ decision_key: hex('9'), before: 'abcdefgh' }));
    assert.equal(c.status, 200, c.text);
    const r = await req(DB, 'POST', '/api/flow-agent/record', { decision_key: hex('9'), outcome: 'refused', after: 'ijklmnop', detail: 'qrstuvwx' });
    assert.equal(r.status, 200, r.text);
    const row = db.prepare('SELECT before_state, after_state, detail FROM flow_actions WHERE decision_key=?').get(hex('9'));
    assert.deepEqual([row.before_state, row.after_state, row.detail], ['abcd', 'ijkl', 'qrst']);
  });

  await t.test('W3 count: done/failed/escalated inside the window only', async () => {
    const { DB, db } = await openDb();
    const H = 3600;
    let i = 0;
    const k = () => (++i).toString(16).padStart(64, '0');
    const put = (d, outcome, agoS, ticket = 'BH-3') => insertAction(d, { key: k(), project: 'proj-a', ticket, outcome, at: isoAgoS(agoS) });
    put(db, 'done', 60); put(db, 'failed', 2 * H); put(db, 'escalated', 23 * H);
    put(db, 'done', 24 * H + 1);                       // 1 s outside 24 h
    put(db, 'would', 60); put(db, 'claimed', 60); put(db, 'refused', 60);
    put(db, 'done', 60, 'BH-4');                       // another ticket
    const r = await req(DB, 'GET', '/api/flow-agent/count?project=proj-a&ticket=BH-3');
    assert.equal(r.status, 200, r.text);
    assert.equal(r.body.count, 3);
    assert.equal(r.body.window_h, 24);
    // The settings snapshot is per binding, so the changed row is read on a fresh one.
    const fresh = await openDb();
    fresh.db.exec("UPDATE settings SET value='1' WHERE key='flow_agent.count_window_h'");
    put(fresh.db, 'done', 60); put(fresh.db, 'done', 2 * H);
    const r2 = await req(fresh.DB, 'GET', '/api/flow-agent/count?project=proj-a&ticket=BH-3');
    assert.equal(r2.status, 200, r2.text);
    assert.equal(r2.body.window_h, 1);
    assert.equal(r2.body.count, 1);
  });

  await t.test('W4 waiting PUT replaces one project\'s set and keeps since on the same code', async () => {
    const { DB, db } = await openDb();
    const row = (key, code, since) => ({ key, code, since, episode: 'ep-1', evidence: 'e' });
    const b1 = await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-b', rows: [row('B-9', 'unknown', '2026-11-01T00:00:00Z')] });
    assert.equal(b1.status, 200, b1.text);
    const a1 = await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [
      row('A-1', 'ready_not_queued', '2026-11-20T00:00:00Z'), row('A-2', 'ready_not_queued', '2026-11-20T00:00:00Z')] });
    assert.equal(a1.status, 200, a1.text);
    const a2 = await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [
      row('A-2', 'ready_not_queued', '2026-11-23T00:00:00Z'), row('A-3', 'unknown', '2026-11-23T00:00:00Z')] });
    assert.equal(a2.status, 200, a2.text);
    assert.deepEqual(waitingOf(db, 'proj-a'), [
      { ticket_key: 'A-2', cause_code: 'ready_not_queued', since: '2026-11-20T00:00:00Z' },
      { ticket_key: 'A-3', cause_code: 'unknown', since: '2026-11-23T00:00:00Z' },
    ]);
    const a3 = await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [
      row('A-2', 'inputs_unreadable', '2026-11-24T00:00:00Z'), row('A-3', 'unknown', '2026-11-24T00:00:00Z')] });
    assert.equal(a3.status, 200, a3.text);
    assert.deepEqual(waitingOf(db, 'proj-a').map((r) => [r.ticket_key, r.cause_code, r.since]), [
      ['A-2', 'inputs_unreadable', '2026-11-24T00:00:00Z'],
      ['A-3', 'unknown', '2026-11-23T00:00:00Z'],
    ]);
    assert.deepEqual(waitingOf(db, 'proj-b').map((r) => r.ticket_key), ['B-9']);
    // evidence is cut to flow_agent.evidence_max_chars
    const fresh = await openDb();
    fresh.db.exec("UPDATE settings SET value='5' WHERE key='flow_agent.evidence_max_chars'");
    const c = await req(fresh.DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [{ ...row('A-7', 'unknown', '2026-11-24T00:00:00Z'), evidence: 'abcdefghij' }] });
    assert.equal(c.status, 200, c.text);
    assert.equal(fresh.db.prepare("SELECT evidence FROM flow_waiting WHERE ticket_key='A-7'").get().evidence, 'abcde');
  });

  await t.test('W5 a wrong-project read gives 0 rows', async () => {
    const { DB, db } = await openDb();
    insertAction(db, { key: hex('f'), project: 'proj-a', ticket: 'BH-5', outcome: 'done', at: isoAgoS(60) });
    const r = await req(DB, 'GET', '/api/flow-agent/count?project=proj-b&ticket=BH-5');
    assert.equal(r.status, 200, r.text);
    assert.equal(r.body.count, 0);
    await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [{ key: 'BH-5', code: 'unknown', since: '2026-11-24T00:00:00Z', episode: 'ep' }] });
    const e = await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-b', rows: [] });
    assert.equal(e.status, 200, e.text);
    assert.equal(e.body.deleted, 0);
    assert.deepEqual(waitingOf(db, 'proj-a').map((x) => x.ticket_key), ['BH-5']);
    // an empty set is a real empty set for its own project
    const e2 = await req(DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [] });
    assert.equal(e2.body.deleted, 1);
    assert.deepEqual(waitingOf(db, 'proj-a'), []);
  });

  await t.test('W6 a bad input is 400 with the field, and nothing is written', async () => {
    const { DB, db } = await openDb();
    const cases = [
      ['POST', '/api/flow-agent/claim', claimBody({ decision_key: 'A'.repeat(64) }), 'decision_key'],
      ['POST', '/api/flow-agent/claim', claimBody({ decision_key: hex('a').slice(1) }), 'decision_key'],
      ['POST', '/api/flow-agent/claim', claimBody({ code: 'merge_it' }), 'code'],
      ['POST', '/api/flow-agent/claim', claimBody({ project: 'Bad Project' }), 'project'],
      ['POST', '/api/flow-agent/claim', claimBody({ ticket_key: 'bad key' }), 'ticket_key'],
      ['POST', '/api/flow-agent/claim', claimBody({ outcome: 'done' }), 'outcome'],
      ['POST', '/api/flow-agent/record', { decision_key: hex('a'), outcome: 'claimed' }, 'outcome'],
      ['GET', '/api/flow-agent/count?project=proj-a', undefined, 'ticket'],
      ['PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [{ key: 'A-1', code: 'nope', since: '2026-11-24T00:00:00Z', episode: 'e' }] }, 'rows[0].code'],
      ['PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [{ key: 'A-1', code: 'unknown', since: 'yesterday', episode: 'e' }] }, 'rows[0].since'],
      ['PUT', '/api/flow-agent/waiting', { project: 'proj-a' }, 'rows'],
    ];
    for (const [m, p, b, field] of cases) {
      const r = await req(DB, m, p, b);
      assert.equal(r.status, 400, `${m} ${p} ${JSON.stringify(b)} -> ${r.status} ${r.text}`);
      assert.equal(r.body.field, field, r.text);
    }
    const fresh = await openDb();
    fresh.db.exec("UPDATE settings SET value='2' WHERE key='flow_agent.waiting_max'");
    const rows = ['A-1', 'A-2', 'A-3'].map((key) => ({ key, code: 'unknown', since: '2026-11-24T00:00:00Z', episode: 'e' }));
    const r = await req(fresh.DB, 'PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows });
    assert.equal(r.status, 400, r.text);
    assert.deepEqual([r.body.error, r.body.field], ['too_many', 'rows']);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM flow_actions').get().n, 0);
    assert.equal(fresh.db.prepare('SELECT COUNT(*) AS n FROM flow_waiting').get().n, 0);
  });

  await t.test('W7 a D1 error is a 503 that names the table', async () => {
    const boom = () => { throw new Error('D1_ERROR: fixture failure'); };
    const DB = { prepare: boom, batch: boom, exec: boom };
    const cases = [
      ['POST', '/api/flow-agent/claim', claimBody(), 'flow_actions'],
      ['POST', '/api/flow-agent/record', { decision_key: hex('a'), outcome: 'done' }, 'flow_actions'],
      ['GET', '/api/flow-agent/count?project=proj-a&ticket=BH-1', undefined, 'flow_actions'],
      ['PUT', '/api/flow-agent/waiting', { project: 'proj-a', rows: [] }, 'flow_waiting'],
    ];
    for (const [m, p, b, table] of cases) {
      const r = await req(DB, m, p, b);
      assert.equal(r.status, 503, `${m} ${p} -> ${r.status} ${r.text}`);
      assert.match(r.body.error, new RegExp(table), r.text);
    }
  });

  await t.test('W8 the bearer gates every route; the family is rendered; the panel seam is empty', async () => {
    const { DB } = await openDb();
    for (const [m, p, b] of [['POST', '/api/flow-agent/claim', claimBody()], ['POST', '/api/flow-agent/record', {}],
      ['GET', '/api/flow-agent/count?project=a&ticket=B-1'], ['PUT', '/api/flow-agent/waiting', { project: 'a', rows: [] }]]) {
      const r = await req(DB, m, p, b, { bearer: false });
      assert.ok(r.status === 401 || r.status === 403, `${m} ${p} without the bearer -> ${r.status}`);
    }
    const out = execFileSync(process.execPath, [fileURLToPath(new URL('../scripts/routes-build.mjs', import.meta.url)), '--print'], { encoding: 'utf8' });
    assert.match(out, /import \{ routes as f_bh_9924_flow_agent \} from "\.\/routes\/flow-agent\.js";/);
    const panel = await import('../src/routes/flow-agent-panel.js');
    assert.deepEqual(panel.routes, []);
  });

  await t.test('EXPLAIN at 50,000 flow_actions and 5,000 flow_waiting rows uses the named index', async () => {
    const { db } = await openDb();
    db.exec('BEGIN');
    const ins = db.prepare(`INSERT INTO flow_actions (decision_key, project, ticket_key, code, action, episode, outcome, created_at, updated_at)
      VALUES (?,?,?,?,?,?,?,?,?)`);
    const outcomes = ['done', 'failed', 'would', 'refused', 'claimed', 'escalated'];
    for (let i = 0; i < 50000; i++) {
      const at = new Date(Date.UTC(2026, 10, 24) - (50000 - i) * 600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      ins.run(i.toString(16).padStart(64, '0'), `proj-${i % 10}`, `BH-${Math.floor(i / 10) % 2000}`, 'ready_not_queued', 'ready_not_queued', 'ep', outcomes[i % 6], at, at);
    }
    const w = db.prepare('INSERT INTO flow_waiting (project, ticket_key, cause_code, since, episode, evidence, seen_at) VALUES (?,?,?,?,?,?,?)');
    for (let i = 0; i < 5000; i++) w.run(`proj-${i % 10}`, `BH-${i}`, 'unknown', '2026-11-20T00:00:00Z', 'ep', null, '2026-11-24T00:00:00Z');
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const F = await import('../src/routes/flow-agent.js');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN flow_/.test(l)), [], lines.join(' | '));
    const uses = (lines, re) => assert.ok(lines.some((l) => re.test(l)), `${re} not used: ${lines.join(' | ')}`);
    const set = JSON.stringify([{ key: 'BH-1', code: 'unknown', since: '2026-11-24T00:00:00Z', episode: 'e', evidence: null }]);
    let l = plan(F.CLAIM_READ_SQL, hex('a')); noScan(l); uses(l, /SEARCH flow_actions USING INDEX sqlite_autoindex_flow_actions_1 \(decision_key=\?\)/);
    l = plan(F.RECORD_SQL, hex('a'), 'done', null, null, '2026-11-24T00:00:00Z'); noScan(l); uses(l, /SEARCH flow_actions USING INDEX sqlite_autoindex_flow_actions_1 \(decision_key=\?\)/);
    l = plan(F.COUNT_SQL, 'proj-1', 'BH-1', '2026-11-23T00:00:00Z'); noScan(l); uses(l, /SEARCH flow_actions USING INDEX idx_flow_actions_ticket_created \(project=\? AND ticket_key=\? AND created_at>\?\)/);
    l = plan(F.CLAIM_SQL, hex('a'), 'p', 'K', 'unknown', 'a', 'e', 'claimed', null, null, '2026-11-24T00:00:00Z'); noScan(l);
    l = plan(F.WAITING_UPSERT_SQL, 'proj-1', set, '2026-11-24T00:00:00Z'); noScan(l);
    l = plan(F.WAITING_DELETE_SQL, 'proj-1', set); noScan(l); uses(l, /SEARCH flow_waiting USING (COVERING )?INDEX sqlite_autoindex_flow_waiting_1 \(project=\?\)/);
  });

  await t.test('SEED every T1 seed row reads back; no flow-diagnose route row', async () => {
    const { db } = await openDb();
    const want = {
      'flow_agent.enabled': '1',
      'flow_agent.project.project-3.mode': 'act',
      'flow_agent.saved_min_default': '60',
      'flow_agent.stall_min': '20',
      'flow_agent.count_window_h': '24',
      'flow_agent.waiting_max': '500',
      'flow_agent.evidence_max_chars': '2000',
      'flow_agent.pr_list_pages': '3',
      'flow_agent.issue_list_pages': '5',
      'flow_agent.board_timeout_s': '30',
    };
    for (const c of ['answered_not_retriaged', 'ready_not_queued', 'row_for_archived_ticket', 'waits_behind_green_pr',
      'waits_behind_dead_blocker', 'parent_slices_not_filed', 'pr_conflict', 'pr_red_same_test_as_main']) want[`flow_agent.action.${c}`] = '1';
    for (const [k, v] of Object.entries(want)) {
      const row = db.prepare('SELECT value, actor FROM settings WHERE key=?').get(k);
      assert.ok(row, `no seed row ${k}`);
      assert.equal(row.value, v, k);
      assert.equal(row.actor, 'seed', k);
    }
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM settings WHERE key LIKE 'flow_agent.action.%'").get().n, 8);
    const frag = readFileSync(new URL('../schema.d/202611242152-bh-9924-flow-agent.sql', import.meta.url), 'utf8');
    assert.doesNotMatch(frag, /flow-diagnose/);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM settings WHERE key LIKE '%flow-diagnose%' OR key LIKE '%flow_diagnose%'").get().n, 0);
  });
});
