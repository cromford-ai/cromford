import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-8476 — POST /api/verdicts/<id>/retract marks a lead BLOCK row whose report
// was empty as retracted (verdict_retractions, one row per verdict id). GET
// /api/verdicts then treats that row as absent for `standing` and annotates it
// in history (retracted_at, retract_reason). Driven through the worker's real
// fetch entry against the SQL that ships (schema.d via jobsSchemaSql()). Each
// test opens its own in-memory database, so no test depends on another.
const SECRET = 'test-secret-fixture';
const LEAD = 'lead-token-fixture';
const HUMAN = 'human-token-fixture';
const KEY = 'sig-key-fixture';
const SCHEMA = jobsSchemaSql();
const ENV = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD, HUMAN_VERDICT_TOKEN: HUMAN, HUMAN_VERDICT_SIG_KEY: KEY };

function sqliteDB(db, seen) {
  const bindAndRun = (sql, binds) => {
    if (seen) seen.push({ sql, binds });
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
const H = 'a'.repeat(40);
const REPO = 'example-org/cromford';
const PR = 8476;

// dbObj: pass one sqliteDB wrapper to reuse it across requests (the
// ensureTable memo is keyed on it), so a second request shows the warm path.
const send = (db, path, method, { body, lead = true, human = false, seen, dbObj } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: {
    authorization: `Bearer ${SECRET}`, 'content-type': 'application/json',
    ...(lead ? { 'x-lead-verdict-token': LEAD } : {}),
    ...(human ? { 'x-human-verdict-token': HUMAN } : {}),
  },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB: dbObj || sqliteDB(db, seen), ...ENV })
  .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const post = async (db, verdict, source, { head = H, pr = PR, repo = REPO } = {}) => {
  const r = await send(db, '/api/verdicts', 'POST', {
    body: { repo, pr, head_sha: head, verdict, source }, human: source === 'human',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  return r.body.verdict;
};
const retract = (db, id, body = { reason: 'empty-report' }, o = {}) =>
  send(db, `/api/verdicts/${id}/retract`, 'POST', { body, ...o });
const standing = async (db, { head = H, pr = PR, repo = REPO } = {}) => {
  const r = await send(db, `/api/verdicts?repo=${repo}&pr=${pr}&head=${head}&standing_only=1`, 'GET');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.standing;
};
const nRetractions = (db) => db.prepare('SELECT COUNT(*) AS n FROM verdict_retractions').get().n;

test('W1: a retract without the lead token is 403 and writes no row', async () => {
  const db = openDb();
  const b = await post(db, 'BLOCK', 'lead');
  const r = await retract(db, b.id, { reason: 'empty-report' }, { lead: false });
  assert.equal(r.status, 403, JSON.stringify(r.body));
  assert.equal(nRetractions(db), 0);
});

test('W2: a lead BLOCK is retracted once (201); a repeat is 200 existing:true and stores no second row', async () => {
  const db = openDb();
  const b = await post(db, 'BLOCK', 'lead');
  const r1 = await retract(db, b.id, { reason: 'empty-report', actor: 'operator' });
  assert.equal(r1.status, 201, JSON.stringify(r1.body));
  assert.equal(r1.body.existing, false);
  assert.equal(r1.body.retraction.verdict_id, b.id);
  assert.equal(r1.body.retraction.reason, 'empty-report');
  assert.equal(r1.body.retraction.actor, 'operator');
  assert.ok(r1.body.retraction.created_at);
  assert.equal(r1.body.verdict.id, b.id);
  const row = db.prepare('SELECT * FROM verdict_retractions WHERE verdict_id=?').get(b.id);
  assert.equal(row.reason, 'empty-report');
  const r2 = await retract(db, b.id, { reason: 'empty-report', actor: 'someone-else' });
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  assert.equal(r2.body.existing, true);
  assert.equal(r2.body.retraction.actor, 'operator', 'the stored row is answered, not the retry');
  assert.equal(r2.body.verdict.id, b.id);
  assert.equal(nRetractions(db), 1);
});

test('W3: a retracted lead BLOCK is absent from standing; a human MERGE under it stands, alone it is null', async () => {
  const db = openDb();
  const m = await post(db, 'MERGE', 'human');
  const b = await post(db, 'BLOCK', 'lead');
  assert.equal((await standing(db)).verdict, 'MERGE', 'BH-8349: the human row already stands');
  // A head where the lead BLOCK is the newest standing row and outranks a lead MERGE.
  const H2 = 'c'.repeat(40);
  const lm = await post(db, 'MERGE', 'lead', { head: H2 });
  const lb = await post(db, 'BLOCK', 'lead', { head: H2 });
  assert.equal((await standing(db, { head: H2 })).id, lb.id);
  assert.equal((await retract(db, lb.id)).status, 201);
  assert.equal((await standing(db, { head: H2 })).id, lm.id, 'the retracted BLOCK is absent; the older lead MERGE stands');
  assert.equal((await retract(db, b.id)).status, 201);
  assert.equal((await standing(db)).id, m.id);
  // Only the retracted row on a head: standing is null.
  const H3 = 'd'.repeat(40);
  const only = await post(db, 'BLOCK', 'lead', { head: H3 });
  assert.equal((await standing(db, { head: H3 })).id, only.id);
  assert.equal((await retract(db, only.id)).status, 201);
  assert.equal(await standing(db, { head: H3 }), null);
});

test('W4: GET history rows carry retracted_at and retract_reason; an unretracted row has null', async () => {
  const db = openDb();
  const b = await post(db, 'BLOCK', 'lead');
  const m = await post(db, 'MERGE', 'human');
  const rr = await retract(db, b.id);
  assert.equal(rr.status, 201);
  const r = await send(db, `/api/verdicts?repo=${REPO}&pr=${PR}`, 'GET');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.id), [m.id, b.id], 'newest first, both rows kept in history');
  const rb = r.body.rows.find((x) => x.id === b.id);
  const rm = r.body.rows.find((x) => x.id === m.id);
  assert.equal(rb.retracted_at, rr.body.retraction.created_at);
  assert.equal(rb.retract_reason, 'empty-report');
  assert.equal(rb.verdict, 'BLOCK');
  assert.equal(rb.created_at, b.created_at, 'the verdict created_at is not overwritten by the join');
  assert.equal(rm.retracted_at, null);
  assert.equal(rm.retract_reason, null);
});

test('W5: a retraction on repo A/pr 1 does not change standing for repo B/pr 1 or repo A/pr 2', async () => {
  const db = openDb();
  const A = 'example-org/alpha';
  const B = 'example-org/beta';
  const a1 = await post(db, 'BLOCK', 'lead', { repo: A, pr: 1 });
  const b1 = await post(db, 'BLOCK', 'lead', { repo: B, pr: 1 });
  const a2 = await post(db, 'BLOCK', 'lead', { repo: A, pr: 2 });
  assert.equal((await retract(db, a1.id)).status, 201);
  assert.equal(await standing(db, { repo: A, pr: 1 }), null);
  assert.equal((await standing(db, { repo: B, pr: 1 })).id, b1.id);
  assert.equal((await standing(db, { repo: A, pr: 2 })).id, a2.id);
});

test('W6: human, box and lead MERGE rows are 409; unknown id 404; reason x 400; long actor 400', async () => {
  const db = openDb();
  const hb = await post(db, 'BLOCK', 'human');
  const bx = await post(db, 'BLOCK', 'box');
  const lm = await post(db, 'MERGE', 'lead');
  const rt = await post(db, 'MERGE', 'risk-tier');
  for (const v of [hb, bx, lm, rt]) {
    const r = await retract(db, v.id);
    assert.equal(r.status, 409, `${v.source} ${v.verdict}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, 'only a lead BLOCK row can be retracted');
  }
  const unk = await retract(db, 999999);
  assert.equal(unk.status, 404, JSON.stringify(unk.body));
  assert.notEqual(unk.body.error, 'unknown endpoint');
  const lb = await post(db, 'BLOCK', 'lead');
  const bad = await retract(db, lb.id, { reason: 'x' });
  assert.equal(bad.status, 400, JSON.stringify(bad.body));
  const none = await retract(db, lb.id, {});
  assert.equal(none.status, 400, JSON.stringify(none.body));
  const long = await retract(db, lb.id, { reason: 'empty-report', actor: 'a'.repeat(101) });
  assert.equal(long.status, 400, JSON.stringify(long.body));
  assert.equal(nRetractions(db), 0);
});

test('W7: id 0 and id 01x match no route (404 unknown endpoint)', async () => {
  const db = openDb();
  for (const id of ['0', '01x', '01']) {
    const r = await retract(db, id);
    assert.equal(r.status, 404, `${id}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, 'unknown endpoint', id);
  }
});

test('W8: at 20,000 rows the standing and history reads use idx_verdicts_pr_head; standing_only stays the same statement count', async () => {
  const db = openDb();
  const now = '2026-10-26T00:00:00.000Z';
  const ins = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at, auth)
                          VALUES (?, ?, ?, ?, ?, ?, 'lead-token')`);
  db.exec('BEGIN');
  for (let i = 0; i < 20000; i++) {
    const pr = (i % 2000) + 1;
    ins.run(REPO, pr, (pr % 16).toString(16).repeat(40), i % 3 ? 'BLOCK' : 'MERGE', 'lead', now);
  }
  const insR = db.prepare('INSERT INTO verdict_retractions (verdict_id, reason, actor, created_at) VALUES (?, ?, ?, ?)');
  for (let id = 2; id <= 20000 && id <= 600; id += 3) insR.run(id, 'empty-report', 'seed', now);
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(nRetractions(db), 200);

  const pr = 7;
  const head = (pr % 16).toString(16).repeat(40);
  const seen = [];
  const r = await send(db, `/api/verdicts?repo=${REPO}&pr=${pr}&head=${head}`, 'GET', { seen });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  // sqliteDB records a prepare() and its bind() both; the bound entry is the statement run.
  const reads = seen.filter((s) => s.binds.length && /^\s*SELECT/i.test(s.sql) && /FROM verdicts\b/.test(s.sql));
  assert.equal(reads.length, 2, reads.map((s) => s.sql).join('\n---\n'));
  for (const s of reads) {
    const plan = db.prepare(`EXPLAIN QUERY PLAN ${s.sql}`).all(...s.binds).map((x) => x.detail).join(' | ');
    assert.match(plan, /idx_verdicts_pr_head/, plan);
    assert.doesNotMatch(plan, /SCAN (verdicts|v)\b/, plan);
    assert.doesNotMatch(plan, /SCAN (verdict_retractions|r)\b(?! USING)/, plan);
    if (/verdict_retractions/.test(s.sql) && /LEFT JOIN/i.test(s.sql)) {
      assert.match(plan, /SEARCH (r|verdict_retractions) USING INTEGER PRIMARY KEY/, plan);
    }
    if (/NOT IN \(SELECT verdict_id FROM verdict_retractions\)/.test(s.sql)) {
      // The uncorrelated NOT IN probes the rowid; it never builds a list by scanning.
      assert.match(plan, /USING ROWID SEARCH ON TABLE verdict_retractions|SEARCH verdict_retractions USING INTEGER PRIMARY KEY/, plan);
    }
  }
  assert.ok(reads.some((s) => /verdict_retractions/.test(s.sql) && /LEFT JOIN/i.test(s.sql)), 'the history read joins verdict_retractions');
  assert.ok(reads.some((s) => /NOT IN \(SELECT verdict_id FROM verdict_retractions\)/.test(s.sql)), 'the standing read filters retractions');

  // Statement count of a warm standing_only GET, with and without retractions.
  const count = async (d) => {
    const s = [];
    const obj = sqliteDB(d, s);
    const path = `/api/verdicts?repo=${REPO}&pr=${PR}&head=${H}&standing_only=1`;
    assert.equal((await send(d, path, 'GET', { dbObj: obj })).status, 200);
    s.length = 0;
    assert.equal((await send(d, path, 'GET', { dbObj: obj })).status, 200);
    return s;
  };
  const d1 = openDb();
  await post(d1, 'MERGE', 'lead');
  await post(d1, 'BLOCK', 'lead');
  const without = await count(d1);
  const d2 = openDb();
  await post(d2, 'MERGE', 'lead');
  const b = await post(d2, 'BLOCK', 'lead');
  assert.equal((await retract(d2, b.id)).status, 201);
  const withR = await count(d2);
  assert.equal(withR.length, without.length, withR.map((s) => s.sql).join('\n---\n'));
  assert.equal(withR.filter((s) => s.binds.length && /FROM verdicts\b/.test(s.sql)).length, 1, 'one verdicts read on the warm hot path');
});
