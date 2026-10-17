// BH-6745 (wave 2 of #6541): PUT /api/landing-decisions/outcome, the result of
// a direct landing (bin/lib/mc/landing.sh landing_direct) on its decision row.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/), the landing-decisions.bh-6744 idiom.
//   W1 no bearer -> 401; an outcome outside the enum -> 400; no row -> 404
//   W2 POST a decision, PUT 409 -> 200; GET shows outcome 409 and an ISO
//      outcome_at; a second PUT `merged` overwrites
//   W3 EXPLAIN QUERY PLAN of the UPDATE at 5,000 rows uses the UNIQUE autoindex
//   W4 a PUT for another repo (same number, head, mode) changes nothing -> 404
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh6745';
const A = 'example-org/landing-a';
const B = 'example-org/landing-b';
const H1 = 'a'.repeat(40);
const ROW = { repo: A, number: 12, head: H1, mode: 'optimistic', would: 'direct', reason: 'ok' };
const OUT = { repo: A, number: 12, head: H1, mode: 'optimistic' };

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
const put = (DB, body, opts = {}) => call(DB, '/api/landing-decisions/outcome', { method: 'PUT', body, ...opts });

test('W1 PUT outcome: no bearer 401, a bad outcome or field 400, no decision row 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { DB } = o;
  assert.equal((await put(DB, { ...OUT, outcome: '409' }, { bearer: false })).status, 401);
  for (const b of [{ outcome: 'MERGED' }, { outcome: '500' }, { outcome: '' }, { outcome: undefined },
    { repo: 'bad' }, { number: 0 }, { head: 'g'.repeat(40) }, { mode: 'fast' }]) {
    const res = await put(DB, { ...OUT, outcome: '409', ...b });
    assert.equal(res.status, 400, `${JSON.stringify(b)}: ${JSON.stringify(res.body)}`);
    assert.equal(typeof res.body.error, 'string');
  }
  const none = await put(DB, { ...OUT, outcome: '409' });
  assert.equal(none.status, 404, JSON.stringify(none.body));
  assert.equal(none.body.error, 'no decision row');
});

test('W2 POST a decision, PUT 409, GET reads it back; a second PUT merged overwrites', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { DB } = o;
  assert.equal((await post(DB, ROW)).status, 201);
  const before = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}`);
  assert.equal(before.body.rows[0].outcome, null);
  assert.equal(before.body.rows[0].outcome_at, null);
  const res = await put(DB, { ...OUT, outcome: '409' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.ok, true);
  const got = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}`);
  const r = got.body.rows[0];
  assert.equal(r.outcome, '409');
  assert.match(r.outcome_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(r.would, 'direct'); assert.equal(r.reason, 'ok');
  for (const tok of ['merged', '405', '422', 'error', 'budget', 'lock']) {
    assert.equal((await put(DB, { ...OUT, outcome: tok })).status, 200, tok);
  }
  assert.equal((await put(DB, { ...OUT, outcome: 'merged' })).status, 200);
  const last = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}`);
  assert.equal(last.body.rows[0].outcome, 'merged');
  // The shadow-mode row for the same head is a different row and keeps no outcome.
  assert.equal((await post(DB, { ...ROW, mode: 'shadow' })).status, 201);
  const both = await call(DB, `/api/landing-decisions?repo=${encodeURIComponent(A)}`);
  assert.deepEqual(both.body.rows.map((x) => [x.mode, x.outcome]), [['shadow', null], ['optimistic', 'merged']]);
});

test('W3 on 5,000 rows the outcome UPDATE uses the UNIQUE autoindex', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  await post(DB, ROW);   // the guard has run once: the table and the added columns exist
  const REPOS = Array.from({ length: 20 }, (_, i) => `o/r${i}`);
  const sha = (i) => i.toString(16).padStart(40, '0');
  db.exec('BEGIN');
  const ins = db.prepare('INSERT INTO landing_decisions (repo, number, head, mode, would, reason, at) VALUES (?,?,?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) ins.run(REPOS[i % 20], 1 + (i % 400), sha(i), 'optimistic', 'direct', 'ok', '2026-10-16T00:00:00Z');
  db.exec('COMMIT');
  // capturingD1 logs reads only; the UPDATE is a run(), so log those too.
  const log = [];
  const D0 = capturingD1(db, log);
  const D = { ...D0, prepare(sql) {
    const s = D0.prepare(sql); let b = [];
    const api = { bind(...v) { b = v; s.bind(...v); return api; }, first: (c) => s.first(c), all: () => s.all(),
      run() { log.push({ sql, binds: b }); return s.run(); } };
    return api;
  } };
  const res = await worker.fetch(new Request('https://jobs.test/api/landing-decisions/outcome', {
    method: 'PUT',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ repo: 'o/r3', number: 1 + (3 % 400), head: sha(3), mode: 'optimistic', outcome: '405' }),
  }), { DB: D, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  const upd = log.filter((r) => /^\s*UPDATE landing_decisions/.test(r.sql));
  assert.equal(upd.length, 1, log.map((r) => r.sql).join(' | '));
  const lines = plan(db, upd[0].sql, ...upd[0].binds);
  assert.deepEqual(fullScans(lines, ['landing_decisions']), [], lines.join(' | '));
  assert.ok(lines.some((l) => /landing_decisions USING INDEX sqlite_autoindex_landing_decisions_\d+ \(repo=\? AND number=\? AND head=\? AND mode=\?\)/.test(l)), lines.join(' | '));
});

test('W4 a PUT for another repo with the same number and head changes 0 rows -> 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  assert.equal((await post(DB, ROW)).status, 201);
  const res = await put(DB, { ...OUT, repo: B, outcome: '409' });
  assert.equal(res.status, 404, JSON.stringify(res.body));
  const row = db.prepare('SELECT outcome, outcome_at FROM landing_decisions WHERE repo = ?').get(A);
  assert.equal(row.outcome, null);
  assert.equal(row.outcome_at, null);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM landing_decisions WHERE repo = ?').get(B).n, 0);
});
