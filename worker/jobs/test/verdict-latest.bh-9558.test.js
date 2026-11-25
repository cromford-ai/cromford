import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-9558 — LATEST VERDICT WINS. A builder APPROVE followed by a lead BLOCK
// must leave the PR's current verdict at BLOCK, with both rounds in
// verdict_history, and POST /api/verdict/current must answer that. Driven
// through worker.fetch (the production entry point) over the real composed
// schema in node:sqlite. Each case seeds its own repo/PR numbers.

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret-fixture';
const LEAD = 'lead-token-fixture';
const REPO = 'example-org/demo-os';
const SHA_A = 'a'.repeat(40);
const SHA_B = 'b'.repeat(40);
const prUrl = (n, repo = REPO) => `https://github.com/${repo}/pull/${n}`;

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// The D1 surface the worker uses. `failOn` makes prepare() of a matching SQL
// throw at run time, so a case can force one statement to fail.
function d1(db, { failOn = null } = {}) {
  const clean = (b) => b.map((v) => (v === undefined ? null : v));
  const stmt = (sql, binds = []) => ({
    bind: (...b) => stmt(sql, clean(b)),
    first: async (col) => {
      const row = db.prepare(sql).get(...binds) ?? null;
      return col ? (row ? row[col] : null) : row;
    },
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      if (failOn && failOn.test(sql)) throw new Error('forced failure (fixture)');
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return { prepare: (sql) => stmt(sql), batch: async (ss) => { const o = []; for (const s of ss) o.push(await s.run()); return o; } };
}

function openDb(t) {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
}

async function send(db, path, { method = 'GET', body, lead = false, failOn = null } = {}) {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead) headers['x-lead-verdict-token'] = LEAD;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB: d1(db, { failOn }), HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD });
  return { status: res.status, body: await res.json().catch(() => null) };
}

function job(db, id, { kind = 'build', project = 'demo-os' } = {}) {
  db.prepare(`INSERT INTO jobs (id,project,kind,stage,box,ticket_id,status,created_at,updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(id, project, kind, 'review', 'b', 'BH-1', 'running', '2026-11-24T00:00:00Z', '2026-11-24T00:00:00Z');
}

async function ledgerJob(db, id, pr, opts) {
  job(db, id, opts);
  const r = await send(db, `/api/jobs/${id}/artifacts`, { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: pr, actor: 'test-box' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
}

async function builder(db, id, word, sha, source = 'run-build') {
  const r = await send(db, `/api/jobs/${id}/artifacts`, {
    method: 'PUT',
    body: { artifact_kind: 'verdict', artifact_ref: word, detail: JSON.stringify({ reviewed_sha: sha, source, tier: '2', provenance: 'review' }), actor: 'test-box' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r;
}

const lead = (db, pr, verdict, sha, source = 'lead', extra = {}) =>
  send(db, '/api/verdicts', { method: 'POST', lead: true, body: { repo: REPO, pr, head_sha: sha, verdict, source, reviewer: 'lead-fixture', ...extra }, ...(extra.__opts || {}) });

const rounds = (db, id) => db.prepare('SELECT * FROM verdict_history WHERE job_id=? ORDER BY id').all(id);
const current = (db, prs) => send(db, '/api/verdict/current', { method: 'POST', body: { prs } });

test('V1 a lead MERGE on a PR with a build job appends one lead round bound to head_sha', async (t) => {
  const db = openDb(t); if (!db) return;
  await ledgerJob(db, 'j-v1', prUrl(101));
  const r = await lead(db, 101, 'MERGE', SHA_A);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const h = rounds(db, 'j-v1');
  assert.equal(h.length, 1);
  assert.equal(h[0].verdict, 'MERGE');
  assert.equal(h[0].source, 'lead');
  assert.equal(h[0].reviewed_sha, SHA_A);
  assert.equal(h[0].actor, 'lead-fixture');
  assert.equal(JSON.parse(h[0].detail).verdicts_id, r.body.verdict.id);
});

test('V2 builder APPROVE then lead BLOCK: 2 rounds, current BLOCK by lead, lead_blocked', async (t) => {
  const db = openDb(t); if (!db) return;
  const pr = prUrl(102);
  await ledgerJob(db, 'j-v2', pr);
  await builder(db, 'j-v2', 'APPROVE', SHA_A);
  const r = await lead(db, 102, 'BLOCK', SHA_A);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const hist = await send(db, `/api/verdict/history?pr=${encodeURIComponent(pr)}`);
  assert.equal(hist.status, 200);
  assert.deepEqual(hist.body.rounds.map((x) => x.verdict), ['APPROVE', 'BLOCK']);
  const c = await current(db, [pr]);
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const v = c.body.verdicts[pr];
  assert.equal(v.verdict, 'BLOCK');
  assert.equal(v.by, 'lead');
  assert.equal(v.state, 'lead_blocked');
  assert.equal(v.rounds, 2);
  assert.equal(v.reviewed_sha, SHA_A);
  // The standing merge-gate artifact is untouched (assumption 1).
  const art = db.prepare("SELECT artifact_ref FROM job_artifacts WHERE job_id='j-v2' AND artifact_kind='verdict'").get();
  assert.equal(art.artifact_ref, 'APPROVE');
});

test('V3 a box BLOCK and an advice lead row under a final human verdict append nothing; 201 bodies keep their keys', async (t) => {
  const db = openDb(t); if (!db) return;
  await ledgerJob(db, 'j-v3', prUrl(103));
  const box = await send(db, '/api/verdicts', { method: 'POST', body: { repo: REPO, pr: 103, head_sha: SHA_A, verdict: 'BLOCK', source: 'box' } });
  assert.equal(box.status, 201, JSON.stringify(box.body));
  assert.equal(rounds(db, 'j-v3').length, 0, 'a box row is history only');
  for (const k of ['verdict', 'human_verified', 'human_signed', 'human_verdict_mode', 'human_final']) assert.ok(k in box.body, k);
  const human = await lead(db, 103, 'MERGE', SHA_A, 'human');
  assert.equal(human.status, 201, JSON.stringify(human.body));
  assert.equal(rounds(db, 'j-v3').length, 1, 'a human MERGE stands and appends');
  const advice = await lead(db, 103, 'BLOCK', SHA_A);
  assert.equal(advice.status, 201, JSON.stringify(advice.body));
  assert.ok(advice.body.human_final, 'the lead row is advice under the final human verdict');
  const h = rounds(db, 'j-v3');
  assert.equal(h.length, 1, 'an advice row appends nothing');
  assert.equal(h[0].source, 'human');
});

test('V4 an external PR appends nothing and /current omits it; a replayed lead row appends nothing', async (t) => {
  const db = openDb(t); if (!db) return;
  const ext = await lead(db, 104, 'BLOCK', SHA_A);
  assert.equal(ext.status, 201);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM verdict_history').get().n, 0);
  const c = await current(db, [prUrl(104)]);
  assert.equal(c.status, 200);
  assert.ok(!(prUrl(104) in c.body.verdicts));
  // Near miss: a pr_url for PR 1040 in the same repo is not PR 104.
  await ledgerJob(db, 'j-v4', prUrl(1040));
  await lead(db, 104, 'BLOCK', SHA_A);
  assert.equal(rounds(db, 'j-v4').length, 0);
  await lead(db, 1040, 'BLOCK', SHA_A);
  await lead(db, 1040, 'BLOCK', SHA_A);
  assert.equal(rounds(db, 'j-v4').length, 1, 'an exact replay of the newest lead round appends nothing');
  await lead(db, 1040, 'BLOCK', SHA_B);
  assert.equal(rounds(db, 'j-v4').length, 2, 'the same word on a new head is a new round');
});

test('V5 a builder re-put after a lead BLOCK does not make the stale APPROVE current; a new head does', async (t) => {
  const db = openDb(t); if (!db) return;
  const pr = prUrl(105);
  await ledgerJob(db, 'j-v5', pr);
  await builder(db, 'j-v5', 'APPROVE', SHA_A);
  await lead(db, 105, 'BLOCK', SHA_A);
  const again = await builder(db, 'j-v5', 'APPROVE', SHA_A);
  assert.equal(again.body.history_appended, false);
  assert.equal(rounds(db, 'j-v5').length, 2);
  let c = await current(db, [pr]);
  assert.equal(c.body.verdicts[pr].verdict, 'BLOCK');
  const nb = await builder(db, 'j-v5', 'APPROVE', SHA_B);
  assert.equal(nb.body.history_appended, true);
  assert.equal(rounds(db, 'j-v5').length, 3);
  c = await current(db, [pr]);
  assert.equal(c.body.verdicts[pr].verdict, 'APPROVE');
  assert.equal(c.body.verdicts[pr].by, 'builder');
  assert.equal(c.body.verdicts[pr].state, 'approved');
  assert.equal(c.body.verdicts[pr].rounds, 3);
});

test('V6 the bounce share counts the first builder round, never a lead round', async (t) => {
  const db = openDb(t); if (!db) return;
  await ledgerJob(db, 'j-v6', prUrl(106));
  await lead(db, 106, 'BLOCK', SHA_A);
  await builder(db, 'j-v6', 'APPROVE', SHA_A);
  // Back-date the rounds into the window the route computes from the wall clock.
  db.prepare("UPDATE verdict_history SET created_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')").run();
  const r = await send(db, '/api/route-shadow/bounce?project=demo-os');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.reviewed, 1);
  assert.equal(r.body.blocked, 0);
});

test('V7 /current: 3 urls with one unknown answers 2 keys; a bad url is 400 prs; an empty list is 200 {}', async (t) => {
  const db = openDb(t); if (!db) return;
  await ledgerJob(db, 'j-v7a', prUrl(171));
  await ledgerJob(db, 'j-v7b', prUrl(172));
  await builder(db, 'j-v7a', 'APPROVE', SHA_A);
  await builder(db, 'j-v7b', 'BLOCK', SHA_A);
  const c = await current(db, [prUrl(171), prUrl(172), prUrl(173)]);
  assert.equal(c.status, 200);
  assert.deepEqual(Object.keys(c.body.verdicts).sort(), [prUrl(171), prUrl(172)]);
  assert.equal(c.body.truncated, false);
  const bad = await current(db, ['https://evil.example/pull/1']);
  assert.equal(bad.status, 400);
  assert.match(bad.body.error, /prs/);
  const notArr = await current(db, 'x');
  assert.equal(notArr.status, 400);
  const empty = await current(db, []);
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.verdicts, {});
});

test('V8 builder BLOCK is blocked by builder; REQUEST_CHANGES is blocked; MERGE-WITH-NOTES is approved', async (t) => {
  const db = openDb(t); if (!db) return;
  await ledgerJob(db, 'j-v8a', prUrl(181));
  await ledgerJob(db, 'j-v8b', prUrl(182));
  await ledgerJob(db, 'j-v8c', prUrl(183));
  await builder(db, 'j-v8a', 'BLOCK', SHA_A);
  await builder(db, 'j-v8b', 'REQUEST_CHANGES', SHA_A, null);
  await lead(db, 183, 'MERGE-WITH-NOTES', SHA_A);
  const c = await current(db, [prUrl(181), prUrl(182), prUrl(183)]);
  assert.deepEqual([c.body.verdicts[prUrl(181)].state, c.body.verdicts[prUrl(181)].by], ['blocked', 'builder']);
  assert.equal(c.body.verdicts[prUrl(182)].state, 'blocked');
  assert.equal(c.body.verdicts[prUrl(182)].by, 'builder');
  assert.deepEqual([c.body.verdicts[prUrl(183)].state, c.body.verdicts[prUrl(183)].by], ['approved', 'lead']);
});

test('V9 rounds on the build job and a review-verdict job: the newer id wins and rounds counts both', async (t) => {
  const db = openDb(t); if (!db) return;
  const pr = prUrl(109);
  await ledgerJob(db, 'j-v9', pr);
  await builder(db, 'j-v9', 'BLOCK', SHA_A);
  await ledgerJob(db, 'j-v9r', pr, { kind: 'review-verdict' });
  await builder(db, 'j-v9r', 'APPROVE', SHA_B, 'review-prs');
  const c = await current(db, [pr]);
  assert.equal(c.body.verdicts[pr].verdict, 'APPROVE');
  assert.equal(c.body.verdicts[pr].rounds, 2);
  assert.equal(c.body.verdicts[pr].reviewed_sha, SHA_B);
});

test('V10 a human BLOCK is lead_blocked by human', async (t) => {
  const db = openDb(t); if (!db) return;
  const pr = prUrl(110);
  await ledgerJob(db, 'j-v10', pr);
  await builder(db, 'j-v10', 'APPROVE', SHA_A);
  const r = await lead(db, 110, 'BLOCK', SHA_A, 'human');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const c = await current(db, [pr]);
  assert.equal(c.body.verdicts[pr].state, 'lead_blocked');
  assert.equal(c.body.verdicts[pr].by, 'human');
});

test('V11 the cap is the verdict.current.max_prs row: 2 answers 2 of 3 and says truncated; no row is 200', async (t) => {
  const db = openDb(t); if (!db) return;
  const seed = db.prepare("SELECT value FROM settings WHERE key='verdict.current.max_prs'").get();
  assert.equal(seed && seed.value, '200', 'the seed row ships at 200');
  for (const n of [111, 112, 113]) {
    await ledgerJob(db, `j-v11-${n}`, prUrl(n));
    await builder(db, `j-v11-${n}`, 'APPROVE', SHA_A);
  }
  db.prepare("UPDATE settings SET value='2' WHERE key='verdict.current.max_prs'").run();
  let c = await current(db, [prUrl(111), prUrl(112), prUrl(113)]);
  assert.equal(c.status, 200);
  assert.equal(c.body.cap, 2);
  assert.equal(c.body.truncated, true);
  assert.deepEqual(Object.keys(c.body.verdicts).sort(), [prUrl(111), prUrl(112)]);
  db.prepare("DELETE FROM settings WHERE key='verdict.current.max_prs'").run();
  c = await current(db, [prUrl(111), prUrl(112), prUrl(113)]);
  assert.equal(c.body.cap, 200);
  assert.equal(c.body.truncated, false);
  assert.equal(Object.keys(c.body.verdicts).length, 3);
});

test('V12 a forced verdict_history INSERT failure on the lead write still answers 201 with the lead row', async (t) => {
  const db = openDb(t); if (!db) return;
  await ledgerJob(db, 'j-v12', prUrl(120));
  const orig = console.error;
  const seen = [];
  console.error = (...a) => { seen.push(a.join(' ')); };
  let r;
  try {
    r = await lead(db, 120, 'BLOCK', SHA_A, 'lead', { __opts: { failOn: /INSERT INTO verdict_history/ } });
  } finally { console.error = orig; }
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.verdict.verdict, 'BLOCK');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM verdicts').get().n, 1);
  assert.equal(rounds(db, 'j-v12').length, 0);
  assert.ok(seen.some((l) => /BH-9558/.test(l)), 'the failed round is said out loud');
});

test('V13 the /current select uses idx_artifacts_ref and idx_verdict_history_job at 20,000 artifacts and 120,000 rounds', async (t) => {
  const db = openDb(t); if (!db) return;
  const { CURRENT_VERDICTS_SQL } = await import('../src/lib/verdict-rounds.js');
  db.exec('BEGIN');
  const ia = db.prepare("INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, created_at, updated_at) VALUES (?,?,?,'t','t')");
  for (let i = 0; i < 10000; i++) {
    ia.run(`j${i}`, 'pr_url', `https://github.com/o/r/pull/${i}`);
    ia.run(`j${i}`, 'verdict', 'APPROVE');
  }
  const ih = db.prepare("INSERT INTO verdict_history (job_id, verdict, created_at) VALUES (?,?,'t')");
  for (let i = 0; i < 120000; i++) ih.run(`j${i % 10000}`, i % 3 ? 'APPROVE' : 'BLOCK');
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${CURRENT_VERDICTS_SQL}`)
    .all(JSON.stringify(['https://github.com/o/r/pull/1', 'https://github.com/o/r/pull/2']), 200)
    .map((r) => r.detail).join('\n');
  assert.match(plan, /idx_artifacts_ref/, plan);
  assert.match(plan, /idx_verdict_history_job/, plan);
  assert.doesNotMatch(plan, /SCAN (a|job_artifacts)\b/, plan);
  assert.doesNotMatch(plan, /SCAN (h|verdict_history)\b/, plan);
  // And the answer at that volume is right.
  const rows = db.prepare(CURRENT_VERDICTS_SQL).all(JSON.stringify(['https://github.com/o/r/pull/1']), 200);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].rounds, 12);
});
