import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-8349 — a human verdict on a head is final for that head. A source=lead
// post on a head whose standing human row would stand is recorded as advice
// (note token human-final:#<id>, no PR-gate fact, answer human_final), and
// GET &head= answers the human row as `standing` over any newer lead row. A
// new head has no human row, so a push resets the rule. Driven through the
// worker's real fetch entry against the SQL that ships (schema.sql).
const SECRET = 'test-secret-fixture';
const LEAD = 'lead-token-fixture';
const HUMAN = 'human-token-fixture';
const KEY = 'sig-key-fixture';
const SCHEMA = jobsSchemaSql();

// failMode: every human_verdict_mode read throws (an unreadable mode).
function sqliteDB(db, seen, failMode = false) {
  const bindAndRun = (sql, binds) => {
    if (seen) seen.push({ sql, binds });
    if (failMode && /FROM settings WHERE key IN/.test(sql) && binds[0] === 'human_verdict_mode') {
      const boom = async () => { throw new Error('D1_ERROR: overloaded (fixture)'); };
      return { first: boom, all: boom, run: boom };
    }
    return {
      first: async (col) => {
        const row = db.prepare(sql).get(...binds) ?? null;
        return col ? (row ? row[col] : null) : row;
      },
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    };
  };
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
    batch: async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; },
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const setRaw = (db, k, v) => db.prepare('UPDATE settings SET value=? WHERE key=?').run(v, k);
const S = 'a'.repeat(40);
const S2 = 'b'.repeat(40);
const REPO = 'example-org/cromford';
const PR = 8349;
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };

const send = (db, path, method, { body, human = false, seen, failMode } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: {
    authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', 'x-lead-verdict-token': LEAD,
    ...(human ? { 'x-human-verdict-token': HUMAN } : {}),
  },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB: sqliteDB(db, seen, failMode), ...ENV })
  .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const post = (db, { head = S, verdict, source, pr = PR, repo = REPO, human, note, seen, failMode }) =>
  send(db, '/api/verdicts', 'POST', { body: { repo, pr, head_sha: head, verdict, source, ...(note ? { note } : {}) }, human, seen, failMode });
const postHuman = (db, verdict, o = {}) => post(db, { verdict, source: 'human', human: true, ...o });
const postLead = (db, verdict, o = {}) => post(db, { verdict, source: 'lead', ...o });
const standing = async (db, head = S, seen) => {
  const r = await send(db, `/api/verdicts?repo=${REPO}&pr=${PR}&head=${head}&standing_only=1`, 'GET', { seen });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.standing;
};
const gateFacts = (db, id) => db.prepare("SELECT COUNT(*) AS n FROM pr_state_events WHERE state='gate' AND since=?").get(`verdict#${id}`).n;
const created = (r) => { assert.equal(r.status, 201, JSON.stringify(r.body)); return r.body; };

test('W1: human MERGE on S, then lead BLOCK on S: the lead row is advice, the human MERGE stands', async () => {
  const db = openDb();
  const h = created(await postHuman(db, 'MERGE'));
  const l = created(await postLead(db, 'BLOCK', { note: 'lead-review:42 lead-job:j1' }));
  const st = await standing(db);
  assert.equal(st.id, h.verdict.id, 'the human row stands over the newer lead row');
  assert.equal(st.verdict, 'MERGE');
  assert.equal(st.source, 'human');
  assert.equal(h.human_final, null);
  assert.equal(l.human_final?.id, h.verdict.id);
  assert.equal(l.human_final?.verdict, 'MERGE');
  assert.equal(l.verdict.source, 'lead');
  assert.equal(l.verdict.note, `lead-review:42 lead-job:j1 human-final:#${h.verdict.id}`);
  assert.equal(gateFacts(db, l.verdict.id), 0, 'an advice row records no lead-verdict gate fact');
  assert.equal(gateFacts(db, h.verdict.id), 1);
});

test('W2: human BLOCK on S, then lead MERGE on S: the human BLOCK stands', async () => {
  const db = openDb();
  const h = created(await postHuman(db, 'BLOCK'));
  const l = created(await postLead(db, 'MERGE'));
  assert.equal(l.human_final?.id, h.verdict.id);
  assert.equal(l.verdict.note, `human-final:#${h.verdict.id}`);
  const st = await standing(db);
  assert.equal(st.id, h.verdict.id);
  assert.equal(st.verdict, 'BLOCK');
  assert.equal(gateFacts(db, l.verdict.id), 0);
});

test('W3: lead BLOCK, human MERGE, lead BLOCK on S: the second lead is advice, the first is unchanged', async () => {
  const db = openDb();
  const l1 = created(await postLead(db, 'BLOCK'));
  assert.equal(l1.human_final, null);
  assert.equal(gateFacts(db, l1.verdict.id), 1);
  const h = created(await postHuman(db, 'MERGE'));
  assert.equal((await standing(db)).id, h.verdict.id);
  const l2 = created(await postLead(db, 'BLOCK'));
  assert.equal(l2.human_final?.id, h.verdict.id);
  const l3 = created(await postLead(db, 'MERGE'));
  assert.equal(l3.human_final?.id, h.verdict.id, 'still advice on the third lead post');
  const st = await standing(db);
  assert.equal(st.id, h.verdict.id);
  assert.equal(st.verdict, 'MERGE');
  assert.equal(db.prepare('SELECT note FROM verdicts WHERE id=?').get(l1.verdict.id).note, null);
});

test('W4: a new head resets the rule: a lead BLOCK on S2 stands', async () => {
  const db = openDb();
  created(await postHuman(db, 'MERGE'));
  const l = created(await postLead(db, 'BLOCK', { head: S2 }));
  assert.equal(l.human_final, null);
  assert.equal(l.verdict.note, null);
  const st = await standing(db, S2);
  assert.equal(st.id, l.verdict.id);
  assert.equal(st.verdict, 'BLOCK');
  assert.equal(gateFacts(db, l.verdict.id), 1);
});

test('W5: a human row in another PR, or another repo with the same pr number, never makes a lead post advice', async () => {
  const db = openDb();
  created(await postHuman(db, 'MERGE', { pr: PR + 1 }));
  created(await postHuman(db, 'MERGE', { repo: 'example-org/other-fixture' }));
  const l = created(await postLead(db, 'BLOCK'));
  assert.equal(l.human_final, null);
  const st = await standing(db);
  assert.equal(st.id, l.verdict.id);
  assert.equal(st.verdict, 'BLOCK');
});

test('W6: under human_verdict_mode=enforce a lead-token human row is not final', async () => {
  const db = openDb();
  // Shadow: a human post with no human token is recorded with auth=lead-token.
  const h = created(await post(db, { verdict: 'MERGE', source: 'human' }));
  assert.equal(h.verdict.auth, 'lead-token');
  setRaw(db, 'human_verdict_mode', 'enforce');
  const l = created(await postLead(db, 'BLOCK'));
  assert.equal(l.human_final, null);
  const st = await standing(db);
  assert.equal(st.id, l.verdict.id);
  assert.equal(st.verdict, 'BLOCK');
});

test('W7: under human_verdict_sig_mode=enforce an unproven human MERGE is not final', async () => {
  const db = openDb();
  const h = created(await post(db, { verdict: 'MERGE', source: 'human' }));
  assert.equal(h.verdict.auth, 'lead-token');
  setRaw(db, 'human_verdict_sig_mode', 'enforce');
  // Before any lead row, BH-3846 still answers it as source=lead.
  const before = await standing(db);
  assert.equal(before.id, h.verdict.id);
  assert.equal(before.source, 'lead');
  assert.equal(before.source_recorded, 'human');
  const l = created(await postLead(db, 'BLOCK'));
  assert.equal(l.human_final, null);
  const st = await standing(db);
  assert.equal(st.id, l.verdict.id);
  assert.equal(st.verdict, 'BLOCK');
});

test('W7b: under sig enforce an unproven human BLOCK is still final (failure is the safe direction)', async () => {
  const db = openDb();
  const h = created(await post(db, { verdict: 'BLOCK', source: 'human' }));
  setRaw(db, 'human_verdict_sig_mode', 'enforce');
  const l = created(await postLead(db, 'MERGE'));
  assert.equal(l.human_final?.id, h.verdict.id);
  assert.equal((await standing(db)).id, h.verdict.id);
});

test('W8: the POST lookup and the GET standing read use idx_verdicts_pr_head over 2,000 rows', async () => {
  const db = openDb();
  const ins = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth)
                          VALUES (?,?,?,?,?,?,?)`);
  for (let i = 0; i < 2000; i++) {
    const head = (i % 97).toString(16).padStart(2, '0').repeat(20);
    ins.run(REPO, 1000 + (i % 50), head, i % 3 ? 'MERGE' : 'BLOCK', ['lead', 'human', 'box'][i % 3], '2026-10-25T00:00:00.000Z', 'secret');
  }
  db.exec('ANALYZE');
  created(await postHuman(db, 'MERGE'));
  const seen = [];
  created(await postLead(db, 'BLOCK', { seen }));
  await standing(db, S, seen);
  const hot = seen.filter(({ sql }) => /FROM verdicts/.test(sql) && /head_sha=\?3/.test(sql));
  assert.ok(hot.length >= 2, `expected the POST lookup and the GET read, saw ${hot.length}`);
  for (const { sql, binds } of hot) {
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail).join(' | ');
    assert.match(plan, /idx_verdicts_pr_head/, `${sql}\n${plan}`);
    assert.doesNotMatch(plan, /SCAN verdicts/, `${sql}\n${plan}`);
  }
});

test('W9: the mode unreadable and a human row on the head: a lead post is 503 and writes nothing', async () => {
  const db = openDb();
  created(await postHuman(db, 'MERGE'));
  const n = db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n;
  const r = await postLead(db, 'BLOCK', { failMode: true });
  assert.equal(r.status, 503, JSON.stringify(r.body));
  assert.equal(r.body.human_verdict_mode, null);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n, n, 'nothing written');
  // No human row on S2: the mode cannot change the answer, so the post is written.
  const ok2 = created(await postLead(db, 'BLOCK', { head: S2, failMode: true }));
  assert.equal(ok2.human_final, null);
  assert.equal(gateFacts(db, ok2.verdict.id), 1);
});
