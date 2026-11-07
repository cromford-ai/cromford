// BH-9178 (C2 of #9063): the inline prune in PUT /api/suite-results yields to
// the scheduled 14-day rule (suite_results.age) once that rule really deletes:
// retention.dry_run = 0 AND retention.suite_results.days > 0. In every other
// state the PUT prunes rows older than 30 days, as before, so the table always
// has one delete that owns it. Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema; a unique repo per case.
//
//   P1 no settings rows, and retention.dry_run=1 (the seed): the PUT prunes
//   P2 dry_run=0 with days absent / 14 / abc: no prune; days=0 or dry_run=yes:
//      prune. pruneOwnedByRule's table for the same 7 cases
//   P3 a settings read that throws: the PUT answers 200 and prunes
//   P4 dry_run=0: the PUT leaves the row; POST /api/retention/run deletes it and
//      writes one retention_runs row for suite_results.age
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { pruneOwnedByRule } from '../src/routes/suite-results.js';

const SECRET = 'SECRET';
const F = 'c'.repeat(64);
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const D = 86400;
let n = 0;
const uniqueRepo = (tag) => `example-org/prune-${tag}-${process.pid}-${++n}`;

async function call(DB, method, path, body) {
  const res = await worker.fetch(new Request('https://jobs.test' + path, {
    method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
function setRows(db, rows) {
  db.prepare("DELETE FROM settings WHERE key IN ('retention.dry_run', 'retention.suite_results.days')").run();
  for (const [k, v] of Object.entries(rows)) {
    db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test',?)").run(k, String(v), ago(0));
  }
}
function oldRow(db, repo) {
  db.prepare(`INSERT INTO suite_results (repo, ctx, class, suite, fingerprint, status, duration_s, run_id, head_sha, ok_at,
      last_run_id, runs, fails, first_at, updated_at) VALUES (?, 'isolated', 'builder', 'tests/old.sh', ?, 'ok', 1, 'r0', NULL, ?, 'r0', 1, 0, ?, ?)`)
    .run(repo, F, ago(31 * D), ago(31 * D), ago(31 * D));
}
const oldLeft = (db, repo) => db.prepare("SELECT count(*) AS n FROM suite_results WHERE repo=? AND suite='tests/old.sh'").get(repo).n;
// put <repo> — one fresh ok item for the same repo, through the real route.
const put = (DB, repo) => call(DB, 'PUT', '/api/suite-results',
  { repo, ctx: 'isolated', run_id: 'r1', items: [{ suite: 'tests/new.sh', fingerprint: F, status: 'ok', duration_s: 2 }] });

// settings state -> does the PUT prune?
const CASES = [
  ['no rows', {}, true],
  ['dry_run=1 (the seed)', { 'retention.dry_run': '1' }, true],
  ['dry_run=0, days absent (def 14)', { 'retention.dry_run': '0' }, false],
  ['dry_run=0, days=14', { 'retention.dry_run': '0', 'retention.suite_results.days': '14' }, false],
  ['dry_run=0, days=abc (def 14)', { 'retention.dry_run': '0', 'retention.suite_results.days': 'abc' }, false],
  ['dry_run=0, days=0 (rule off)', { 'retention.dry_run': '0', 'retention.suite_results.days': '0' }, true],
  ['dry_run=yes (def 1)', { 'retention.dry_run': 'yes' }, true],
];

test('P1/P2 the PUT prunes only while the 14-day rule does not delete', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  for (const [name, rows, prunes] of CASES) {
    const repo = uniqueRepo('p12');
    setRows(db, rows);
    oldRow(db, repo);
    const r = await put(DB, repo);
    assert.equal(r.status, 200, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.written, 1, name);
    assert.equal(oldLeft(db, repo), prunes ? 0 : 1, `${name}: the 31-day row ${prunes ? 'is pruned' : 'stays'}`);
    assert.equal(db.prepare("SELECT count(*) AS n FROM suite_results WHERE repo=? AND suite='tests/new.sh'").get(repo).n, 1, name);
  }
});

test('P2 pruneOwnedByRule: true only when the scheduled rule deletes', () => {
  for (const [name, rows, prunes] of CASES) {
    const byKey = new Map(Object.entries(rows).map(([key, value]) => [key, { key, value }]));
    assert.equal(pruneOwnedByRule(byKey), !prunes, name);
  }
});

test('P3 a settings read that throws: 200 and the prune runs', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db } = o;
  setRows(db, { 'retention.dry_run': '0', 'retention.suite_results.days': '14' });
  const base = d1(db);
  const DB = {
    ...base,
    prepare(sql) {
      if (/FROM settings WHERE key IN/i.test(sql)) throw new Error('fixture: settings read refused');
      return base.prepare(sql);
    },
  };
  const repo = uniqueRepo('p3');
  oldRow(db, repo);
  const r = await put(DB, repo);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(oldLeft(db, repo), 0, 'a failed settings read never turns the prune off');
});

test('P4 with dry_run=0 the rule owns the table: the PUT leaves the row, the rule deletes it', async (t) => {
  const o = await openDb(); if (!o) return t.skip('node:sqlite unavailable');
  const { db, DB } = o;
  setRows(db, { 'retention.dry_run': '0' });
  const repo = uniqueRepo('p4');
  oldRow(db, repo);
  const r = await put(DB, repo);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(oldLeft(db, repo), 1, 'the PUT did not prune');
  const run = await call(DB, 'POST', '/api/retention/run', {});
  assert.equal(run.status, 200, JSON.stringify(run.body));
  assert.equal(run.body.dry_run, false);
  assert.equal(oldLeft(db, repo), 0, 'the scheduled rule deleted it');
  const audit = db.prepare("SELECT dry_run, removed FROM retention_runs WHERE rule='suite_results.age' AND run_id=?").all(run.body.run_id);
  assert.equal(audit.length, 1);
  assert.equal(audit[0].dry_run, 0);
  assert.ok(audit[0].removed >= 1, JSON.stringify(audit));
});
