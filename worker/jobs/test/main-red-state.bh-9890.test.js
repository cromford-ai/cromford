// BH-9890: PUT /api/main-red-state/pr-errors takes replace:true, which
// overwrites the row of that head. The PR-pair lane sends it only for a named
// head it read again after a newer run of the failed job (a "gate" re-run to
// green on 2026-11-22 never reached the write-once row, and the freeze held).
//   R1  replace:true overwrites job, error, run_at and at; GET returns the new row
//   R2  a PUT without replace (or replace:false) is still write-once
//   R3  replace:"yes" is a 400; a replace never touches another repo's row
// Driven through the REAL router (worker.fetch) on the node:sqlite shim.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh9890';
const REPO = 'example-org/project-6';
const H1 = '386aa88bc41d'.padEnd(40, '0');

const call = (DB, method, path, body) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const q = (s) => encodeURIComponent(s);
const put = (DB, b) => call(DB, 'PUT', '/api/main-red-state/pr-errors', b);
const get = (DB, repo) => call(DB, 'GET', `/api/main-red-state/pr-errors?repo=${q(repo)}&heads=${H1}`);
const GATE = { repo: REPO, head: H1, job: 'gate', error: 'ledger-check: refuse.', run_at: '2026-11-20T09:50:00Z' };
const GREEN = { repo: REPO, head: H1, job: '-', error: '-', run_at: '-' };

test('BH-9890 pr-errors replace', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  let clock = Date.parse('2026-11-20T10:00:00Z');
  const RealDate = Date;
  class FixtureDate extends RealDate {
    constructor(...a) { super(...(a.length ? a : [clock])); }
    static now() { return clock; }
  }
  globalThis.Date = FixtureDate;
  t.after(() => { globalThis.Date = RealDate; });

  await t.test('R1 replace:true overwrites the row of that head', async () => {
    const { DB } = await openDb();
    let r = await put(DB, GATE);
    assert.equal(r.status, 200);
    assert.equal(r.body.inserted, true);
    const first = r.body.row.at;
    clock += 2 * 86400_000;
    r = await put(DB, { ...GREEN, replace: true });
    assert.equal(r.status, 200);
    assert.equal(r.body.inserted, false);
    assert.equal(r.body.replaced, true);
    r = await get(DB, REPO);
    assert.equal(r.body.rows.length, 1);
    assert.equal(r.body.rows[0].job, '-');
    assert.equal(r.body.rows[0].error, '-');
    assert.equal(r.body.rows[0].run_at, '-');
    assert.ok(r.body.rows[0].at > first, `at ${r.body.rows[0].at} must be later than ${first}`);
  });

  await t.test('R2 without replace (or replace:false) the PUT stays write-once', async () => {
    const { DB } = await openDb();
    await put(DB, GATE);
    for (const extra of [{}, { replace: false }]) {
      const r = await put(DB, { ...GREEN, ...extra });
      assert.equal(r.status, 200);
      assert.equal(r.body.inserted, false);
      assert.equal(r.body.replaced, false);
      assert.equal(r.body.row.job, 'gate');
    }
    const r = await get(DB, REPO);
    assert.equal(r.body.rows[0].job, 'gate');
  });

  await t.test('R3 a bad replace is a 400, and a replace never reaches another repo', async () => {
    const { DB } = await openDb();
    await put(DB, GATE);
    await put(DB, { ...GATE, repo: 'o/other' });
    let r = await put(DB, { ...GREEN, replace: 'yes' });
    assert.equal(r.status, 400);
    r = await get(DB, REPO);
    assert.equal(r.body.rows[0].job, 'gate');
    r = await put(DB, { ...GREEN, replace: true });
    assert.equal(r.body.replaced, true);
    r = await get(DB, 'o/other');
    assert.equal(r.body.rows.length, 1);
    assert.equal(r.body.rows[0].job, 'gate');
  });
});
