// BH-7348 (BH-7300 slice C2): the docker-pool result rows. POST
// /api/docker-pool/result (the docker host's reap posts one summary row per
// finished claim) and POST /api/docker-pool/results/reap (the hub reads and
// stamps them), the docker_pool_results table, its seed and its retention
// rule. Driven through the REAL worker.fetch on node:sqlite with the composed
// jobs schema. Leases come from C0's real POST /api/docker-pool/claim.
//   P1-P16 result decision rule and retention    Q1-Q5 reap read
//   K1 seed and indexes                          E1 EXPLAIN QUERY PLAN at 5,000 + 5,000 rows
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7348';
const PAST = '2000-01-01T00:00:00Z';
const SQL = await import('../src/routes/docker-pool-results.js').catch(() => ({}));
const PR = 'https://github.com/o/r/pull/7';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, body) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const dp = (DB, op, body) => call(DB, `/api/docker-pool/${op}`, body);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-17T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const enqueue = (db, key, project = 'p1') => db.prepare(
  `INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt, requested_by, enqueued_at, updated_at)
   VALUES (?,?,?,'queued','fly',0,'hub-fixture','2026-10-17T00:00:00Z','2026-10-17T00:00:00Z')`
).run(project, key, `id-${key}`);
const results = (db) => db.prepare('SELECT * FROM docker_pool_results ORDER BY id').all();
const leaseOf = (db, key) => db.prepare('SELECT * FROM docker_pool_leases WHERE ticket_key=? ORDER BY id DESC').get(key);
// A queued row claimed by box through C0's real route; the lease is active.
async function leased(o, key, box = 'mac-a') {
  setting(o.db, 'docker_pool.max_concurrent', 4);
  enqueue(o.db, key);
  const r = await dp(o.DB, 'claim', { project: 'p1', key, box });
  assert.equal(r.status, 200, `claim ${key}: ${JSON.stringify(r.body)}`);
  return leaseOf(o.db, key);
}
const body = (key, extra = {}) => ({
  project: 'p1', key, box: 'mac-a', result: `PR_CREATED ${PR} | TIER: 2`, cost_box: 'pool-p1-dk-mac1',
  cost_rows: 3, unpriced_rows: 0, cost_verified: 1, job_id: `build-p1-${key}-1`, pr_url: PR, tier: 2,
  auth_account: 'claude:acct-fixture@example.com', ...extra,
});
const post = (DB, b) => dp(DB, 'result', b);
const reap = (DB, b = {}) => dp(DB, 'results/reap', b);

test('K1 the schema seeds retention.docker_pool_results.days 30 and the four indexes', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.equal(db.prepare('SELECT value FROM settings WHERE key=?').get('retention.docker_pool_results.days')?.value, '30');
  const ix = db.prepare("SELECT name, \"unique\" AS u, partial FROM pragma_index_list('docker_pool_results')").all();
  const by = Object.fromEntries(ix.map((r) => [r.name, r]));
  assert.equal(by.uq_docker_pool_results_claim?.u, 1);
  assert.equal(by.idx_docker_pool_results_unread?.partial, 1);
  assert.ok(by.idx_docker_pool_results_posted);
  const lx = db.prepare("SELECT name FROM pragma_index_list('docker_pool_leases')").all().map((r) => r.name);
  assert.ok(lx.includes('idx_docker_pool_leases_key'), lx.join(','));
});

test('P1 an active lease and valid fields: 200 recorded, one row bound to the claim, line 1 stored', async (t) => {
  const o = await fresh(t); if (!o) return;
  const l = await leased(o, 'P-1');
  const r = await post(o.DB, body('P-1'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.recorded, true); assert.equal(r.body.claimed_at, l.claimed_at);
  const rows = results(o.db);
  assert.equal(rows.length, 1);
  const x = rows[0];
  assert.equal(x.project, 'p1'); assert.equal(x.ticket_key, 'P-1'); assert.equal(x.box, 'mac-a');
  assert.equal(x.claimed_at, l.claimed_at); assert.equal(x.cost_box, 'pool-p1-dk-mac1');
  assert.equal(x.cost_rows, 3); assert.equal(x.unpriced_rows, 0); assert.equal(x.cost_verified, 1);
  assert.equal(x.pr_url, PR); assert.equal(x.tier, 2); assert.equal(x.job_id, 'build-p1-P-1-1');
  assert.equal(x.auth_account, 'claude:acct-fixture@example.com');
  assert.equal(x.result, `PR_CREATED ${PR} | TIER: 2`);
  assert.equal(x.reaped_at, null);
});

test('P2 a lease released done before the post: 200 recorded', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-2');
  assert.equal((await dp(o.DB, 'release', { project: 'p1', key: 'P-2', box: 'mac-a', status: 'done' })).status, 200);
  const r = await post(o.DB, body('P-2'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(results(o.db).length, 1);
});

test('P3 a lease the sweep expired: 409 superseded, no row', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-3');
  o.db.prepare('UPDATE docker_pool_leases SET lease_until=?').run(PAST);
  await dp(o.DB, 'sweep', {});
  assert.equal(leaseOf(o.db, 'P-3').status, 'expired');
  const r = await post(o.DB, body('P-3'));
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'superseded');
  assert.equal(results(o.db).length, 0);
});

test('P4 a lease ended killed or released: 409 superseded', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-4a');
  setting(o.db, 'docker_pool.kill', 1);
  await dp(o.DB, 'heartbeat', { project: 'p1', key: 'P-4a', box: 'mac-a' });
  setting(o.db, 'docker_pool.kill', 0);
  assert.equal(leaseOf(o.db, 'P-4a').status, 'killed');
  await leased(o, 'P-4b');
  await dp(o.DB, 'release', { project: 'p1', key: 'P-4b', box: 'mac-a', status: 'queued' });
  assert.equal(leaseOf(o.db, 'P-4b').status, 'released');
  for (const k of ['P-4a', 'P-4b']) {
    const r = await post(o.DB, body(k));
    assert.equal(r.status, 409, k); assert.equal(r.body.reason, 'superseded', k);
  }
  assert.equal(results(o.db).length, 0);
});

test('P5 an older expired lease and a newer active one of the same box: 200, bound to the newer claim', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-5');
  o.db.prepare("UPDATE docker_pool_leases SET lease_until=?, claimed_at=?").run(PAST, PAST);
  o.db.prepare("UPDATE build_queue SET claimed_at=? WHERE ticket_key='P-5'").run(PAST);
  await dp(o.DB, 'sweep', {});
  const r2 = await dp(o.DB, 'claim', { project: 'p1', key: 'P-5', box: 'mac-a' });
  assert.equal(r2.status, 200);
  const newer = leaseOf(o.db, 'P-5');
  assert.notEqual(newer.claimed_at, PAST);
  const r = await post(o.DB, body('P-5'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.claimed_at, newer.claimed_at);
  assert.equal(results(o.db)[0].claimed_at, newer.claimed_at);
});

test('P6 the lease is held by another box: 409 no_lease', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-6', 'mac-b');
  const r = await post(o.DB, body('P-6'));
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'no_lease');
  assert.equal(results(o.db).length, 0);
});

test('P7 no lease at all: 409 no_lease', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, body('P-7'));
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'no_lease');
});

test('P8 cost_rows absent, a string, negative or fractional, and every other bad field: 400, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-8');
  const noCost = body('P-8'); delete noCost.cost_rows;
  const noUnpriced = body('P-8'); delete noUnpriced.unpriced_rows;
  const noVerified = body('P-8'); delete noVerified.cost_verified;
  const noBox = body('P-8'); delete noBox.box;
  const noResult = body('P-8'); delete noResult.result;
  const cases = [
    ['cost_rows absent', noCost], ['cost_rows "3"', body('P-8', { cost_rows: '3' })],
    ['cost_rows -1', body('P-8', { cost_rows: -1 })], ['cost_rows 1.5', body('P-8', { cost_rows: 1.5 })],
    ['unpriced_rows absent', noUnpriced], ['cost_verified absent', noVerified],
    ['cost_verified 2', body('P-8', { cost_verified: 2 })], ['box absent', noBox], ['result absent', noResult],
    ['pr_url not a PR', body('P-8', { pr_url: 'https://example.com/x' })], ['tier 3', body('P-8', { tier: 3 })],
    ['cost_box with a space', body('P-8', { cost_box: 'a b' })], ['job_id with a slash', body('P-8', { job_id: 'a/b' })],
  ];
  for (const [name, b] of cases) {
    const r = await post(o.DB, b);
    assert.equal(r.status, 400, `${name}: ${r.status} ${JSON.stringify(r.body)}`);
  }
  assert.equal(results(o.db).length, 0);
});

test('P9 unpriced_rows greater than cost_rows: 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-9');
  const r = await post(o.DB, body('P-9', { cost_rows: 2, unpriced_rows: 3 }));
  assert.equal(r.status, 400);
  assert.equal(results(o.db).length, 0);
});

test('P10 an account label with a colon and an @ is stored; an empty one is stored unknown', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-10a'); await leased(o, 'P-10b');
  assert.equal((await post(o.DB, body('P-10a'))).status, 200);
  assert.equal((await post(o.DB, body('P-10b', { auth_account: '' }))).status, 200);
  const by = Object.fromEntries(results(o.db).map((r) => [r.ticket_key, r.auth_account]));
  assert.equal(by['P-10a'], 'claude:acct-fixture@example.com');
  assert.equal(by['P-10b'], 'unknown');
});

test('P11 an account that looks like a credential, has a space, a comma, a quote or 129 chars: 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-11');
  for (const a of ['sk-ant-fixture-token', 'ghs_fixture0token', 'github_pat_fixture', 'a b', 'a,b', 'a"b', 'x'.repeat(129)]) {
    const r = await post(o.DB, body('P-11', { auth_account: a }));
    assert.equal(r.status, 400, `${a}: ${r.status}`);
    if (/^(sk-|ghs_|github_pat_)/.test(a)) assert.equal(r.body.reason, 'auth_account_not_a_label', a);
  }
  assert.equal(results(o.db).length, 0);
  const rows = o.db.prepare("SELECT COUNT(*) AS n FROM docker_pool_results WHERE auth_account LIKE '%fixture%token%'").get();
  assert.equal(rows.n, 0);
});

test('P12 a multi-line RESULT: only line 1 is stored', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-12');
  const r = await post(o.DB, body('P-12', { result: `PR_CREATED ${PR} | TIER: 2\nTIER: 2\nPR: ${PR}` }));
  assert.equal(r.status, 200);
  assert.equal(results(o.db)[0].result, `PR_CREATED ${PR} | TIER: 2`);
});

test('P13 a lower-case or empty result word: 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-13');
  for (const res of ['pr created', '', '   ']) {
    const r = await post(o.DB, body('P-13', { result: res }));
    assert.equal(r.status, 400, JSON.stringify(res));
  }
  assert.equal(results(o.db).length, 0);
});

test('P14 a re-post before the hub read replaces the row', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-14');
  assert.equal((await post(o.DB, body('P-14', { cost_rows: 2, cost_verified: 0 }))).status, 200);
  const r = await post(o.DB, body('P-14', { cost_rows: 3, cost_verified: 1 }));
  assert.equal(r.status, 200);
  const rows = results(o.db);
  assert.equal(rows.length, 1); assert.equal(rows[0].cost_rows, 3); assert.equal(rows[0].cost_verified, 1);
});

test('P15 a re-post after the hub read: 409 already_reaped, the row is unchanged', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-15');
  assert.equal((await post(o.DB, body('P-15', { cost_rows: 3 }))).status, 200);
  assert.equal((await reap(o.DB)).body.reaped.length, 1);
  const r = await post(o.DB, body('P-15', { cost_rows: 9 }));
  assert.equal(r.status, 409); assert.equal(r.body.reason, 'already_reaped');
  const rows = results(o.db);
  assert.equal(rows.length, 1); assert.equal(rows[0].cost_rows, 3); assert.notEqual(rows[0].reaped_at, null);
});

test('P16 post, reap, retention run: an old read row is deleted, an old unread row is kept, one audit row', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'P-16a'); await leased(o, 'P-16b');
  assert.equal((await post(o.DB, body('P-16a'))).status, 200);
  assert.equal((await reap(o.DB)).body.reaped.length, 1);
  assert.equal((await post(o.DB, body('P-16b'))).status, 200);
  // A 0-day window turns a rule off (retention.js), so the rows are aged past 30 days.
  o.db.prepare('UPDATE docker_pool_results SET posted_at=?').run(PAST);
  setting(o.db, 'retention.dry_run', 0);
  const r = await call(o.DB, '/api/retention/run', {});
  assert.equal(r.status, 200);
  const rule = r.body.rules.find((x) => x.rule === 'docker_pool_results.age');
  assert.ok(rule, 'the rule ran');
  assert.equal(rule.removed, 1); assert.equal(rule.error, null);
  const left = results(o.db);
  assert.equal(left.length, 1); assert.equal(left[0].ticket_key, 'P-16b'); assert.equal(left[0].reaped_at, null);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule='docker_pool_results.age'").get().n, 1);
});

// Rows written straight into the table, for the reap read cases.
function seedResults(db, n, prefix) {
  const ins = db.prepare(`INSERT INTO docker_pool_results (project, ticket_key, claimed_at, box, cost_box, auth_account, result, cost_rows, unpriced_rows, cost_verified, posted_at)
                          VALUES ('p1',?,'2026-10-17T00:00:00Z','mac-a','pool-p1-dk-mac1','unknown','PR_CREATED',1,0,1,?)`);
  for (let i = 0; i < n; i++) ins.run(`${prefix}-${i}`, `2026-10-17T01:${String(Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}Z`);
}

test('Q1 three unread rows: the reap returns 3 with their fields and stamps all; Q2 a second call returns 0', async (t) => {
  const o = await fresh(t); if (!o) return;
  await leased(o, 'Q-1');
  assert.equal((await post(o.DB, body('Q-1', { unpriced_rows: 1 }))).status, 200);
  seedResults(o.db, 2, 'Q-1s');
  const r = await reap(o.DB);
  assert.equal(r.status, 200);
  assert.equal(r.body.reaped.length, 3); assert.equal(r.body.backlog, 0);
  const q = r.body.reaped.find((x) => x.key === 'Q-1');
  assert.equal(q.project, 'p1'); assert.equal(q.box, 'mac-a'); assert.equal(q.cost_box, 'pool-p1-dk-mac1');
  assert.equal(q.cost_rows, 3); assert.equal(q.unpriced_rows, 1); assert.equal(q.cost_verified, 1);
  assert.equal(q.auth_account, 'claude:acct-fixture@example.com'); assert.equal(q.pr_url, PR);
  assert.equal(q.result, `PR_CREATED ${PR} | TIER: 2`);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM docker_pool_results WHERE reaped_at IS NULL').get().n, 0);
  const r2 = await reap(o.DB);
  assert.equal(r2.status, 200); assert.equal(r2.body.reaped.length, 0); assert.equal(r2.body.backlog, 0);
});

test('Q3 60 unread rows: 50 and backlog 1, then 10 and backlog 0', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedResults(o.db, 60, 'Q-3');
  const a = await reap(o.DB);
  assert.equal(a.body.reaped.length, 50); assert.equal(a.body.backlog, 1);
  const b = await reap(o.DB);
  assert.equal(b.body.reaped.length, 10); assert.equal(b.body.backlog, 0);
  const keys = new Set([...a.body.reaped, ...b.body.reaped].map((x) => x.key));
  assert.equal(keys.size, 60);
});

test('Q4 two concurrent reaps over 10 rows: 10 distinct rows in total, none twice', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedResults(o.db, 10, 'Q-4');
  const [a, b] = await Promise.all([reap(o.DB, { limit: 10 }), reap(o.DB, { limit: 10 })]);
  const all = [...a.body.reaped, ...b.body.reaped].map((x) => x.key);
  assert.equal(all.length, 10);
  assert.equal(new Set(all).size, 10);
});

test('Q5 limit 0, 51, abc or 1.5: 400 and nothing stamped', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedResults(o.db, 2, 'Q-5');
  for (const limit of [0, 51, 'abc', 1.5]) {
    const r = await reap(o.DB, { limit });
    assert.equal(r.status, 400, String(limit));
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM docker_pool_results WHERE reaped_at IS NULL').get().n, 2);
  const r = await reap(o.DB, { limit: 1 });
  assert.equal(r.body.reaped.length, 1); assert.equal(r.body.backlog, 1);
});

test('E1 at 5,000 results and 5,000 leases every result statement uses an index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.ok(SQL.LEASE_READ_SQL && SQL.UPSERT_SQL && SQL.REAP_IDS_SQL && SQL.REAP_STAMP_SQL, 'the route exports its SQL');
  db.exec('BEGIN');
  const l = db.prepare(`INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until, ended_at)
                        VALUES (?,?,?,?,?,?,?,?)`);
  const r = db.prepare(`INSERT INTO docker_pool_results (project, ticket_key, claimed_at, box, cost_box, auth_account, result, cost_rows, unpriced_rows, cost_verified, posted_at, reaped_at)
                        VALUES (?,?,?,?,?,'unknown','PR_CREATED',1,0,1,?,?)`);
  const ST = ['done', 'expired', 'released', 'killed', 'active'];
  for (let i = 0; i < 5000; i++) {
    const p = `p${i % 13}`, k = `E-${i}`, box = `box-${i % 20}`, st = ST[i % ST.length];
    const at = `2026-10-${String(1 + (i % 28)).padStart(2, '0')}T00:00:00Z`;
    l.run(p, k, box, st, at, at, at, st === 'active' ? null : at);
    r.run(p, k, at, box, `pool-${p}-${box}`, at, i % 3 === 0 ? null : at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const T = '2026-10-17T10:00:00Z', ids = JSON.stringify([5, 10, 15]);
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((x) => x.rule === 'docker_pool_results.age');
  assert.ok(rule, 'retention rule exists');
  const plans = {
    lease_read: plan(db, SQL.LEASE_READ_SQL, 'p1', 'E-1', 'box-1'),
    upsert: plan(db, SQL.UPSERT_SQL, 'p1', 'E-1', T, 'box-1', 'c', 'unknown', null, 'PR_CREATED', null, null, 1, 0, 1, T),
    reap_ids: plan(db, SQL.REAP_IDS_SQL, 50),
    reap_stamp: plan(db, SQL.REAP_STAMP_SQL, ids, T),
    retention_ids: plan(db, rule.ids, T, 500),
  };
  for (const [name, lines] of Object.entries(plans)) {
    assert.deepEqual(fullScans(lines, ['docker_pool_results', 'docker_pool_leases']), [], `${name}: ${lines.join(' | ')}`);
  }
  assert.ok(plans.lease_read.some((x) => /idx_docker_pool_leases_key/.test(x)), plans.lease_read.join(' | '));
  assert.ok(plans.reap_ids.some((x) => /idx_docker_pool_results_unread/.test(x)), plans.reap_ids.join(' | '));
  assert.ok(plans.retention_ids.some((x) => /idx_docker_pool_results_posted/.test(x)), plans.retention_ids.join(' | '));
});
