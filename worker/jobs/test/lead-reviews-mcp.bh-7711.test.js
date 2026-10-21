// BH-7711 — the two worker changes the MCP lead review tools need, driven
// through worker.fetch against the schema that ships (the bh-5400 idiom):
//   G  GET /api/lead-reviews?repo=&pr= lists one PR's requests, served by the
//      UNIQUE(repo, pr, head_sha) autoindex (EXPLAIN on 5000 seeded rows).
//   R  POST /api/lead-reviews/:id/reset reclaims a running request whose
//      COALESCE(heartbeat_at, updated_at) is older than staleWindow (settings
//      lead_review_claim_stale_s, fallback 900); a fresh one stays 409.
import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import * as lr from '../src/routes/lead-reviews.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret-fixture';
const LEAD = 'lead-token-fixture';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db, beforeRun = null) {
  const bindAndRun = (sql, binds) => ({
    first: async (col) => { const r = db.prepare(sql).get(...binds) ?? null; return col && r ? r[col] : r; },
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      if (beforeRun && sql.includes(beforeRun.match)) beforeRun.fn();
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}
const fresh = (beforeRun = null) => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db, beforeRun) }; };

const call = (DB, path, { method = 'GET', body, lead = false } = {}) => {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead) headers['x-lead-verdict-token'] = LEAD;
  const req = new Request(`https://jobs.test${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const head = (c) => c.repeat(40);
const row = (db, id) => db.prepare('SELECT * FROM lead_review_requests WHERE id=?').get(id);
const NOW = Date.now(); // determinism: ok the single anchor; the worker stamps claims and the reset cutoff off the real clock, so every backdated age derives from this one read
const isoAgo = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?1,?2,'test','test','2026-10-20T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);

async function created(DB, repo, pr, sha) {
  const res = await call(DB, '/api/lead-reviews', { method: 'POST', body: { repo, pr, head_sha: sha, scope_notes: 'bh-7711' }, lead: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request;
}
const claim = (DB, id, job_id) => call(DB, `/api/lead-reviews/${id}/claim`, { method: 'POST', body: { job_id, box: 'box-a' } });
const reset = (DB, id, lead = true) => call(DB, `/api/lead-reviews/${id}/reset`, { method: 'POST', body: {}, lead });

// A claimed row whose heartbeat is `beatS` seconds old (null = no heartbeat)
// and whose updated_at is `updS` seconds old.
async function running(db, DB, { beatS, updS = beatS ?? 1000, job = 'job-old', sha = head('a') } = {}) {
  const r = await created(DB, 'acme/app', 7711, sha);
  assert.equal((await claim(DB, r.id, job)).status, 200);
  db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1, updated_at=?2 WHERE id=?3')
    .run(beatS === null ? null : isoAgo(beatS), isoAgo(updS), r.id);
  return r;
}

// ---- G: the pr filter ----

test('G1 ?repo=&pr= lists only that PR of that repo, oldest first', async () => {
  const { db, DB } = fresh();
  const a1 = await created(DB, 'acme/app', 7, head('1'));
  await created(DB, 'acme/app', 8, head('2'));
  await created(DB, 'other/lib', 7, head('3'));
  const a2 = await created(DB, 'acme/app', 7, head('4'));
  // Same created_at second for both pr 7 rows is possible; the rowid breaks it.
  db.prepare('UPDATE lead_review_requests SET created_at=?1 WHERE id=?2').run('2026-10-20T10:00:00Z', a1.id);
  db.prepare('UPDATE lead_review_requests SET created_at=?1 WHERE id=?2').run('2026-10-20T11:00:00Z', a2.id);
  const r = await call(DB, '/api/lead-reviews?repo=acme%2Fapp&pr=7');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.requests.map((q) => q.id), [a1.id, a2.id]);
  assert.ok(r.body.requests.every((q) => q.repo === 'acme/app' && q.pr === 7));
  assert.equal(r.body.truncated, false);
  // limit and truncated still work with the filter.
  const one = await call(DB, '/api/lead-reviews?repo=acme%2Fapp&pr=7&limit=1');
  assert.equal(one.status, 200);
  assert.deepEqual(one.body.requests.map((q) => q.id), [a1.id]);
  assert.equal(one.body.truncated, true);
  assert.ok(one.body.next_after, 'a truncated page names its cursor');
  const next = await call(DB, `/api/lead-reviews?repo=acme%2Fapp&pr=7&limit=1&after=${encodeURIComponent(one.body.next_after)}`);
  assert.deepEqual(next.body.requests.map((q) => q.id), [a2.id]);
  // status filter combines with pr.
  assert.deepEqual((await call(DB, '/api/lead-reviews?repo=acme%2Fapp&pr=7&status=done')).body.requests, []);
});

test('G2 pr without repo, pr=0 and pr=x are 400', async () => {
  const { DB } = fresh();
  const noRepo = await call(DB, '/api/lead-reviews?pr=7');
  assert.equal(noRepo.status, 400);
  assert.match(noRepo.body.error, /pr needs repo/);
  for (const bad of ['0', 'x', '-1', '1.5']) {
    const r = await call(DB, `/api/lead-reviews?repo=acme%2Fapp&pr=${bad}`);
    assert.equal(r.status, 400, bad);
    assert.match(r.body.error, /pr must be a positive integer/, bad);
  }
});

test('G3 without pr the answer is unchanged: every repo and pr, oldest first', async () => {
  const { DB } = fresh();
  const ids = [];
  ids.push((await created(DB, 'acme/app', 7, head('1'))).id);
  ids.push((await created(DB, 'acme/app', 8, head('2'))).id);
  ids.push((await created(DB, 'other/lib', 7, head('3'))).id);
  const all = await call(DB, '/api/lead-reviews');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.requests.map((q) => q.id), ids);
  const repo = await call(DB, '/api/lead-reviews?repo=acme%2Fapp');
  assert.deepEqual(repo.body.requests.map((q) => q.id), ids.slice(0, 2));
});

test('G4 EXPLAIN QUERY PLAN of LR_LIST_PR_SQL on 5000 rows searches the (repo, pr, head_sha) autoindex', () => {
  const { db } = fresh();
  db.exec('BEGIN');
  const ins = db.prepare(
    "INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 'done', ?5, ?5)"
  );
  for (let r = 0; r < 50; r++) {
    for (let p = 1; p <= 100; p++) {
      const n = r * 100 + p;
      ins.run(`id-${n}`, `owner${r}/repo${r}`, p, n.toString(16).padStart(40, '0'), `2026-10-${String(1 + (n % 28)).padStart(2, '0')}T00:00:00Z`);
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(typeof lr.LR_LIST_PR_SQL, 'string', 'LR_LIST_PR_SQL is exported');
  const plan = db.prepare('EXPLAIN QUERY PLAN ' + lr.LR_LIST_PR_SQL)
    .all(null, 'owner3/repo3', 101, null, null, null, 7).map((r) => r.detail);
  const text = plan.join('\n');
  // The UNIQUE(repo, pr, head_sha) autoindex, found by its columns, not by its
  // number (the TEXT primary key takes the first autoindex name).
  const key = db.prepare("PRAGMA index_list('lead_review_requests')").all()
    .map((i) => i.name)
    .find((n) => db.prepare(`PRAGMA index_info('${n}')`).all().map((c) => c.name).join(',') === 'repo,pr,head_sha');
  assert.ok(key, 'no (repo, pr, head_sha) index');
  assert.match(text, new RegExp(`SEARCH lead_review_requests USING INDEX ${key} \\(repo=\\? AND pr=\\?\\)`), text);
  assert.doesNotMatch(text, /SCAN lead_review_requests(?! USING)/, text);
  // And the statement answers the one row it should.
  const rows = db.prepare(lr.LR_LIST_PR_SQL).all(null, 'owner3/repo3', 101, null, null, null, 7);
  assert.deepEqual(rows.map((r) => r.id), ['id-307']);
});

// ---- R: reset reclaims a stale running request ----

test('R1 running, heartbeat 1000 s old, default 900 s: reset reclaims it', async () => {
  const { db, DB } = fresh();
  const r = await running(db, DB, { beatS: 1000 });
  const before = row(db, r.id);
  const res = await reset(DB, r.id);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const now = row(db, r.id);
  assert.equal(now.status, 'requested');
  for (const k of ['job_id', 'box', 'participant', 'heartbeat_at', 'verdict', 'report_ref', 'reviewer_model', 'promoted_verdict_at']) {
    assert.equal(now[k], null, `${k} not cleared`);
  }
  assert.equal(now.reset_count, (before.reset_count ?? 0) + 1);
  assert.ok(now.reset_at);
  assert.match(now.detail, /^stale reset: running with no heartbeat since /);
  assert.match(now.detail, /job job-old/);
  assert.equal(now.stale_reclaims ?? 0, before.stale_reclaims ?? 0, 'the sweep ladder is not touched');
  assert.equal(res.body.request.status, 'requested');
  assert.equal(res.body.reclaimed_from.job_id, 'job-old');
  assert.equal(res.body.reclaimed_from.box, 'box-a');
  assert.equal(res.body.reclaimed_from.last_beat, before.heartbeat_at);
  assert.equal(res.body.stale_s, 900);
});

test('R2 settings 60: a 61 s old beat is reclaimed, a 59 s old beat is 409 and unchanged', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const old = await running(db, DB, { beatS: 61, sha: head('a') });
  const r1 = await reset(DB, old.id);
  assert.equal(r1.status, 200, JSON.stringify(r1.body));
  assert.equal(row(db, old.id).status, 'requested');
  assert.equal(r1.body.stale_s, 60);

  const young = await running(db, DB, { beatS: 59, updS: 59, sha: head('b') });
  const before = row(db, young.id);
  const r2 = await reset(DB, young.id);
  assert.equal(r2.status, 409, JSON.stringify(r2.body));
  assert.match(r2.body.error, /stale after 60 s/);
  assert.deepEqual(row(db, young.id), before);
});

test('R2b a bad setting (abc, 0, -5) falls back to 900 s', async () => {
  for (const v of ['abc', '0', '-5']) {
    const { db, DB } = fresh();
    setting(db, 'lead_review_claim_stale_s', v);
    const young = await running(db, DB, { beatS: 600 });
    assert.equal((await reset(DB, young.id)).status, 409, v);
    const old = await running(db, DB, { beatS: 1000, sha: head('c') });
    const res = await reset(DB, old.id);
    assert.equal(res.status, 200, `${v}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.stale_s, 900, v);
  }
});

test('R3 heartbeat_at NULL, updated_at 1000 s old: reclaimed through COALESCE', async () => {
  const { db, DB } = fresh();
  const r = await running(db, DB, { beatS: null, updS: 1000 });
  const res = await reset(DB, r.id);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(row(db, r.id).status, 'requested');
  assert.equal(res.body.reclaimed_from.last_beat, isoAgo(1000));
});

test('R4 a fresh claim is 409 and keeps its job; a beat that lands between read and write wins', async () => {
  const { db, DB } = fresh();
  const r = await created(DB, 'acme/app', 7711, head('a'));
  assert.equal((await claim(DB, r.id, 'job-live')).status, 200);
  const res = await reset(DB, r.id);
  assert.equal(res.status, 409);
  assert.equal(row(db, r.id).status, 'running');
  assert.equal(row(db, r.id).job_id, 'job-live');

  // The race: the row is stale when the route reads it, and a heartbeat lands
  // just before the reset's UPDATE runs. changes=0 is a 409, row untouched.
  let id = null;
  const race = fresh({ match: 'participant=NULL, heartbeat_at=NULL', fn: () => {
    race.db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1 WHERE id=?2').run(isoAgo(0), id);
  } });
  const s = await running(race.db, race.DB, { beatS: 1000 });
  id = s.id;
  const lost = await reset(race.DB, s.id);
  assert.equal(lost.status, 409, JSON.stringify(lost.body));
  assert.equal(row(race.db, s.id).status, 'running');
  assert.equal(row(race.db, s.id).job_id, 'job-old');
});

test('R5 after a reclaim the old job can neither report nor heartbeat', async () => {
  const { db, DB } = fresh();
  const r = await running(db, DB, { beatS: 1000 });
  assert.equal((await reset(DB, r.id)).status, 200);
  const res = await call(DB, `/api/lead-reviews/${r.id}/result`, {
    method: 'POST', body: { job_id: 'job-old', head_sha: head('a'), outcome: 'done', verdict: 'BLOCK', report_ref: 'r.md' },
  });
  assert.equal(res.status, 409);
  const hb = await call(DB, `/api/lead-reviews/${r.id}/heartbeat`, { method: 'POST', body: { job_id: 'job-old' } });
  assert.equal(hb.status, 409);
  assert.equal(row(db, r.id).status, 'requested');
});

test('R6 without the lead token: 403 and the stale row is unchanged', async () => {
  const { db, DB } = fresh();
  const r = await running(db, DB, { beatS: 1000 });
  const before = row(db, r.id);
  const res = await reset(DB, r.id, false);
  assert.equal(res.status, 403);
  assert.deepEqual(row(db, r.id), before);
});
