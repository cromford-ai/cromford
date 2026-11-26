import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

// BH-9905 — GET /api/verdict-blocks: the batch reader the blocked-resolver's
// verdict-block candidate source calls once per project per tick (through
// bin/lib/verdicts.sh vd_repo_blocks), instead of one /api/verdicts read per
// open PR. Driven through worker.fetch against the SQL that ships (schema.d
// composed into node:sqlite).
//
//   W1  20,000 rows over 20 repos: only BLOCK rows of the repo, created_at >=
//       since, retracted ids absent, newest first, the five fields only
//   W2  limit over the settings row verdict_blocks.max_rows is clamped and
//       truncated is true at the cap; with no row the cap is 1000; one
//       settings read per request
//   W3  400 bad repo / missing or bad since / bad limit; 401 without bearer
//   W4  EXPLAIN QUERY PLAN of the statement the route ran, at 20,000 rows,
//       uses idx_verdicts_repo_verdict_created and does not SCAN verdicts
//   W5  the answer at 500 rows is under 100 KB

const SECRET = 'tok-fixture-bh9905';
const BASE_MS = Date.parse('2026-11-01T00:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const VERDICTS = ['MERGE', 'MERGE-WITH-NOTES', 'BLOCK'];
const SOURCES = ['lead', 'human', 'box', 'risk-tier'];
const N = 20000;
const REPOS = 20;
const repoOf = (k) => `example-org-test/bh9905-r${k}`;

// A fixed generator: row i (id i+1) is one of 20 repos, one of three verdict
// words, one of four sources, and a created_at that is a permutation of
// minutes (7919 is prime to 20000), so the id order is not the time order.
function gen(i) {
  return {
    id: i + 1,
    repo: repoOf(i % REPOS),
    pr: 100 + (i % 50),
    head_sha: (i + 1).toString(16).padStart(40, 'a'),
    verdict: VERDICTS[Math.floor(i / REPOS) % 3],
    source: SOURCES[Math.floor(i / 60) % 4],
    created_at: iso(BASE_MS + ((i * 7919) % N) * 60000),
  };
}

async function fresh(t, rows = N) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO verdicts (id, repo, pr, head_sha, verdict, source, reviewer, note, created_at, auth)
                          VALUES (?,?,?,?,?,?,'box-a','a finding line for the refusal comment',?,'secret')`);
  for (let i = 0; i < rows; i++) {
    const r = gen(i);
    ins.run(r.id, r.repo, r.pr, r.head_sha, r.verdict, r.source, r.created_at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  return o;
}

function call(DB, path, { bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method: 'GET',
    headers: bearer ? { authorization: `Bearer ${SECRET}` } : {},
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => {
    const text = await res.text();
    let body = null;
    try { body = JSON.parse(text); } catch { /* not json */ }
    return { status: res.status, body, bytes: Buffer.byteLength(text) };
  });
}

const q = (repo, since, limit) =>
  `/api/verdict-blocks?repo=${encodeURIComponent(repo)}&since=${encodeURIComponent(since)}${limit === undefined ? '' : `&limit=${limit}`}`;

// The oracle: what the answer must be, computed from the generator alone.
function expected(repo, since, retracted, rows = N) {
  const out = [];
  for (let i = 0; i < rows; i++) {
    const r = gen(i);
    if (r.repo === repo && r.verdict === 'BLOCK' && r.created_at >= since && !retracted.has(r.id)) out.push(r);
  }
  out.sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0));
  return out.map(({ id, pr, head_sha, source, created_at }) => ({ id, pr, head_sha, source, created_at }));
}

const SINCE = iso(BASE_MS + 10000 * 60000);
const REPO = repoOf(7);

test('W1 20,000 rows: only the BLOCK rows of the repo since the cutoff, retracted ids absent, newest first', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  const before = expected(REPO, SINCE, new Set());
  assert.ok(before.length > 50, `fixture holds enough candidate rows (${before.length})`);
  // Retract three of the repo's own BLOCK rows: they must drop out.
  const retracted = new Set([before[0].id, before[10].id, before[before.length - 1].id]);
  const rins = db.prepare("INSERT INTO verdict_retractions (verdict_id, reason, actor, created_at) VALUES (?, 'empty-report', 'test', ?)");
  for (const id of retracted) rins.run(id, SINCE);
  const want = expected(REPO, SINCE, retracted);

  const r = await call(DB, q(REPO, SINCE));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.repo, REPO);
  assert.equal(r.body.since, SINCE);
  assert.equal(r.body.limit, 1000);
  assert.equal(r.body.truncated, false);
  assert.ok(typeof r.body.as_of === 'string' && r.body.as_of.length > 0);
  assert.deepEqual(r.body.rows, want);
  for (const row of r.body.rows) {
    assert.deepEqual(Object.keys(row).sort(), ['created_at', 'head_sha', 'id', 'pr', 'source']);
    assert.ok(!retracted.has(row.id));
  }
  // A since with milliseconds or an offset compares as the same instant.
  const r2 = await call(DB, q(REPO, SINCE.replace('Z', '.000Z')));
  assert.equal(r2.status, 200);
  assert.deepEqual(r2.body.rows, want);
  const offset = '2026-11-08T00:40:00+02:00';
  assert.equal(Date.parse(offset), Date.parse(SINCE));
  const r3 = await call(DB, q(REPO, offset));
  assert.equal(r3.status, 200);
  assert.deepEqual(r3.body.rows, want);
  // Another repo's answer holds none of REPO's rows.
  const other = await call(DB, q(repoOf(3), SINCE));
  assert.equal(other.status, 200);
  assert.deepEqual(other.body.rows, expected(repoOf(3), SINCE, new Set()));
  assert.ok(other.body.rows.every((row) => !want.some((w) => w.id === row.id)));
});

test('W2 limit is clamped to verdict_blocks.max_rows; truncated at the cap; 1000 with no row; one settings read', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const log = [];
  const DB = capturingD1(db, log);
  const want = expected(REPO, SINCE, new Set());
  db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('verdict_blocks.max_rows', '5', 'test', 'test', ?)").run(SINCE);

  const r = await call(DB, q(REPO, SINCE, 50));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.limit, 5);
  assert.equal(r.body.rows.length, 5);
  assert.equal(r.body.truncated, true);
  assert.deepEqual(r.body.rows, want.slice(0, 5));
  const settingsReads = log.filter((e) => /FROM settings/i.test(e.sql) && e.sql.includes('verdict_blocks.max_rows'));
  assert.equal(settingsReads.length, 1, 'one settings read per request');

  const small = await call(DB, q(REPO, SINCE, 3));
  assert.equal(small.body.limit, 3);
  assert.equal(small.body.rows.length, 3);
  assert.equal(small.body.truncated, true);

  db.prepare("DELETE FROM settings WHERE key='verdict_blocks.max_rows'").run();
  const fb = await call(DB, q(REPO, SINCE, 5000));
  assert.equal(fb.status, 200);
  assert.equal(fb.body.limit, 1000);
  assert.equal(fb.body.truncated, false);
  assert.deepEqual(fb.body.rows, want);

  // A row that is not a positive whole number reads as the code fallback.
  db.prepare("INSERT INTO settings (key, value, note, actor, updated_at) VALUES ('verdict_blocks.max_rows', 'lots', 'test', 'test', ?)").run(SINCE);
  const bad = await call(DB, q(REPO, SINCE));
  assert.equal(bad.body.limit, 1000);
});

test('W3 400 on a bad repo, a missing or bad since, a bad limit; 401 without the bearer', async (t) => {
  const o = await fresh(t, 100); if (!o) return;
  const { DB } = o;
  for (const path of [
    q('not-a-repo', SINCE),
    q('', SINCE),
    `/api/verdict-blocks?repo=${encodeURIComponent(REPO)}`,
    q(REPO, ''),
    q(REPO, 'yesterday'),
    q(REPO, '1'),
    q(REPO, SINCE, 0),
    q(REPO, SINCE, -3),
    q(REPO, SINCE, 'abc'),
    q(REPO, SINCE, '2.5'),
  ]) {
    const r = await call(DB, path);
    assert.equal(r.status, 400, `${path} -> ${r.status} ${JSON.stringify(r.body)}`);
    assert.ok(r.body && typeof r.body.error === 'string');
  }
  const u = await call(DB, q(REPO, SINCE), { bearer: false });
  assert.equal(u.status, 401);
});

test('W4 EXPLAIN QUERY PLAN at 20,000 rows uses idx_verdicts_repo_verdict_created, no SCAN verdicts', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const log = [];
  const r = await call(capturingD1(db, log), q(REPO, SINCE));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const reads = log.filter((e) => /FROM verdicts\b/.test(e.sql) && e.sql.includes("'BLOCK'"));
  assert.equal(reads.length, 1, 'one verdicts read per request');
  const lines = plan(db, reads[0].sql, ...reads[0].binds);
  t.diagnostic(`EXPLAIN QUERY PLAN: ${lines.join(' | ')}`);
  assert.ok(lines.some((l) => l.includes('idx_verdicts_repo_verdict_created')), lines.join('\n'));
  assert.deepEqual(fullScans(lines, ['verdicts', 'verdict_retractions']), [], lines.join('\n'));
  assert.ok(!lines.some((l) => /^SCAN verdicts\b/.test(l)), lines.join('\n'));
  assert.ok(!lines.some((l) => /USE TEMP B-TREE FOR ORDER BY/.test(l)), lines.join('\n'));
});

test('W5 the answer at 500 rows is under 100 KB', async (t) => {
  const o = await fresh(t, 0); if (!o) return;
  const { db, DB } = o;
  db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('verdict_blocks.max_rows', '500', 'test', 'test', ?)").run(SINCE);
  // 600 BLOCK rows on one repo with long names and full shas: the cap answers 500.
  const big = 'example-org-test-with-a-long-owner/bh9905-repository-name-that-is-long';
  const ins = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, note, created_at)
                          VALUES (?, ?, ?, 'BLOCK', 'risk-tier', ?, ?)`);
  db.exec('BEGIN');
  for (let i = 0; i < 600; i++) ins.run(big, 100000 + i, (i + 1).toString(16).padStart(40, 'f'), 'n'.repeat(2000), iso(BASE_MS + i * 1000));
  db.exec('COMMIT');
  const r = await call(DB, q(big, '2000-01-01T00:00:00Z'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rows.length, 500);
  assert.equal(r.body.truncated, true);
  assert.ok(r.bytes < 100 * 1024, `${r.bytes} bytes at 500 rows`);
});
