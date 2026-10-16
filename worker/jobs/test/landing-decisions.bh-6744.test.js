// BH-6744 (wave 1 of #6541): the landing_decisions table behind
// POST/GET /api/landing-decisions, its indexes and its retention rule.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/), the risk-tiers.bh-5022 idiom.
//   W1 POST dedupes on (repo, number, head, mode); a repeat keeps the stored row
//   W2 POST refuses a bad repo, number, head, mode, would or reason
//   W3 GET lists by repo, newest first; number narrows; limit and truncated
//   W4 no bearer -> 401 on both routes
//   W5 EXPLAIN QUERY PLAN on 20,000 rows: every read uses an index
//   W6 retention: the seed row is 90 days; a live run removes an old row,
//      keeps a recent one, writes one retention_runs row; the id read uses an index
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh6744';
const A = 'example-org/landing-a';
const B = 'example-org/landing-b';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const ROW = { repo: A, number: 12, head: H1, mode: 'shadow', would: 'direct', reason: 'ok' };
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, { method = 'GET', body, bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const post = (DB, body) => call(DB, '/api/landing-decisions', { method: 'POST', body });
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM landing_decisions').get().n;

test('W1 POST inserts once per (repo, number, head, mode); a repeat is 200 existing and keeps the stored row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const first = await post(DB, ROW);
  assert.equal(first.status, 201, JSON.stringify(first.body));
  assert.equal(first.body.ok, true);
  assert.ok(Number.isInteger(first.body.id) && first.body.id > 0, JSON.stringify(first.body));
  const again = await post(DB, { ...ROW, would: 'queue', reason: 'tier-high' });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.existing, true);
  assert.equal(count(db), 1);
  const stored = db.prepare('SELECT would, reason, at FROM landing_decisions').get();
  assert.equal(stored.would, 'direct');
  assert.equal(stored.reason, 'ok');
  assert.match(stored.at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const opt = await post(DB, { ...ROW, mode: 'optimistic' });
  assert.equal(opt.status, 201, JSON.stringify(opt.body));
  assert.equal(count(db), 2);
  const other = await post(DB, { ...ROW, head: H2 });
  assert.equal(other.status, 201);
  assert.equal(count(db), 3);
});

test('W2 POST refuses every malformed field with 400 and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const bad = [
    { repo: 'bad' }, { number: 0 }, { number: 'x' }, { head: 'a'.repeat(39) }, { head: 'g'.repeat(40) },
    { mode: 'fast' }, { would: 'merge' }, { reason: 'Bad Token' }, { reason: '' }, { reason: 'x'.repeat(41) },
  ];
  for (const b of bad) {
    const res = await post(DB, { ...ROW, ...b });
    assert.equal(res.status, 400, `${JSON.stringify(b)}: ${JSON.stringify(res.body)}`);
    assert.equal(typeof res.body.error, 'string');
  }
  assert.equal(count(db), 0);
  for (const mode of ['queue', 'shadow', 'optimistic']) {
    assert.equal((await post(DB, { ...ROW, mode })).status, 201, mode);
  }
  assert.equal((await post(DB, { ...ROW, head: H2, reason: 'unreadable-checks', would: 'queue' })).status, 201);
});

test('W3 GET ?repo= lists that repo newest first; number narrows; limit and truncated; repo required', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { DB } = o;
  await post(DB, ROW);
  await post(DB, { ...ROW, number: 13, head: H2, would: 'queue', reason: 'solo' });
  await post(DB, { ...ROW, repo: B });
  const all = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}`);
  assert.equal(all.status, 200, JSON.stringify(all.body));
  assert.deepEqual(all.body.rows.map((r) => r.number), [13, 12]);
  assert.ok(all.body.rows.every((r) => r.repo === A));
  assert.equal(all.body.truncated, false);
  assert.equal(typeof all.body.as_of, 'string');
  const r13 = all.body.rows[0];
  for (const k of ['repo', 'number', 'head', 'mode', 'would', 'reason', 'at']) assert.ok(k in r13, `field ${k}`);
  assert.equal(r13.head, H2); assert.equal(r13.would, 'queue'); assert.equal(r13.reason, 'solo'); assert.equal(r13.mode, 'shadow');
  const one = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}&number=12`);
  assert.deepEqual(one.body.rows.map((r) => [r.number, r.head, r.reason]), [[12, H1, 'ok']]);
  const lim = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}&limit=1`);
  assert.equal(lim.body.rows.length, 1);
  assert.equal(lim.body.truncated, true);
  for (const q of [`repo=${encodeURIComponent(A)}&limit=0`, `repo=${encodeURIComponent(A)}&limit=201`, `repo=${encodeURIComponent(A)}&limit=x`,
    '', 'number=12', 'repo=bad', `repo=${encodeURIComponent(A)}&number=0`]) {
    const res = await call(DB, `/api/landing-decisions?${q}`);
    assert.equal(res.status, 400, `${q}: ${JSON.stringify(res.body)}`);
  }
});

test('W4 no bearer is 401 on POST and GET', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  assert.equal((await call(DB, '/api/landing-decisions', { method: 'POST', body: ROW, bearer: false })).status, 401);
  assert.equal((await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}`, { bearer: false })).status, 401);
  assert.equal(count(db), 0);
});

test('W5 on 20,000 rows every landing_decisions read uses an index', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const REPOS = Array.from({ length: 20 }, (_, i) => `o/r${i}`);
  const sha = (i) => i.toString(16).padStart(40, '0');
  db.exec('BEGIN');
  const ins = db.prepare('INSERT INTO landing_decisions (repo, number, head, mode, would, reason, at) VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < 20000; i++) ins.run(REPOS[i % 20], 1 + (i % 400), sha(i), 'shadow', i % 3 ? 'queue' : 'direct', i % 3 ? 'tier-high' : 'ok', ago(i % 120));
  db.exec('COMMIT');
  const log = [];
  const D = capturingD1(db, log);
  for (const q of ['repo=o%2Fr3', 'repo=o%2Fr3&number=7']) {
    const res = await worker.fetch(new Request(`https://jobs.test/api/landing-decisions?${q}`, {
      headers: { authorization: `Bearer ${SECRET}` },
    }), { DB: D, HARNESS_SECRET: SECRET });
    assert.equal(res.status, 200, q);
  }
  const reads = log.filter((r) => /FROM landing_decisions/.test(r.sql));
  assert.equal(reads.length, 2, `the two GETs read landing_decisions (${log.map((r) => r.sql).join(' | ')})`);
  const byRepo = plan(db, reads[0].sql, ...reads[0].binds);
  assert.deepEqual(fullScans(byRepo, ['landing_decisions']), [], byRepo.join(' | '));
  assert.ok(byRepo.some((l) => /landing_decisions USING (COVERING )?INDEX idx_landing_decisions_repo_id \(repo=\?\)/.test(l)), byRepo.join(' | '));
  assert.ok(!byRepo.some((l) => /TEMP B-TREE/.test(l)), `no sort step: ${byRepo.join(' | ')}`);
  const byNum = plan(db, reads[1].sql, ...reads[1].binds);
  assert.deepEqual(fullScans(byNum, ['landing_decisions']), [], byNum.join(' | '));
  assert.ok(byNum.some((l) => /landing_decisions USING (COVERING )?INDEX \w+ \(repo=\?/.test(l)), byNum.join(' | '));
  // The POST's conflict target is the UNIQUE autoindex.
  const ix = db.prepare("SELECT name FROM pragma_index_list('landing_decisions') WHERE \"unique\" = 1").all().map((r) => r.name);
  assert.ok(ix.some((n) => /^sqlite_autoindex_landing_decisions/.test(n)), ix.join(','));
  const cols = db.prepare(`SELECT name FROM pragma_index_info('${ix.find((n) => /^sqlite_autoindex_landing_decisions/.test(n))}')`).all().map((r) => r.name);
  assert.deepEqual(cols, ['repo', 'number', 'head', 'mode']);
});

test('W6 retention: 90-day seed row; a live run removes a 91-day row, keeps a 10-day row, one audit row; the id read uses an index', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const seed = db.prepare("SELECT value FROM settings WHERE key = 'retention.landing_decisions.days'").get();
  assert.equal(seed && seed.value, '90');
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run('test', ago(0));
  const ins = db.prepare('INSERT INTO landing_decisions (repo, number, head, mode, would, reason, at) VALUES (?,?,?,?,?,?,?)');
  ins.run(A, 1, H1, 'shadow', 'queue', 'solo', ago(91));
  ins.run(A, 2, H2, 'shadow', 'direct', 'ok', ago(10));
  const res = await call(DB, '/api/retention/run', { method: 'POST', body: {} });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const rule = res.body.rules.find((r) => r.rule === 'landing_decisions.age');
  assert.ok(rule, `the rule ran: ${res.body.rules.map((r) => r.rule).join(',')}`);
  assert.equal(rule.removed, 1);
  assert.equal(rule.error, null);
  assert.deepEqual(db.prepare('SELECT number FROM landing_decisions').all().map((r) => r.number), [2]);
  const audit = db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule = 'landing_decisions.age'").get().n;
  assert.equal(audit, 1);
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'landing_decisions.age');
  assert.equal(r.table, 'landing_decisions');
  assert.equal(r.key, 'retention.landing_decisions.days');
  assert.equal(r.def, 90);
  const lines = plan(db, r.ids, ago(90), 10);
  assert.deepEqual(fullScans(lines, ['landing_decisions']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_landing_decisions_at \(at<\?\)/.test(l)), lines.join(' | '));
});
