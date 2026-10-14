// BH-5653 (BH-5637.2): per-suite CI durations, posted by CI after each merge
// queue batch and read back by bin/ci-durations.sh fetch.
// Driven through the REAL router (worker.fetch) against a real schema.sql
// database on the node:sqlite shim, so the shim's 100-bind cap is what the
// chunked multi-row INSERTs run against. The shell side is
// tests/ci-durations-*.bh-5653-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const HARNESS = 'fixture-harness-secret';
const TOKEN = 'fixture-ci-token';
const SCHEMA = jobsSchemaSql();
const TABLES = ['ci_duration_runs', 'ci_suite_duration_samples', 'ci_suite_durations'];
const PATH = '/api/ci/suite-durations';

const envOf = (DB, extra = {}) => ({ DB, HARNESS_SECRET: HARNESS, CI_DURATIONS_TOKEN: TOKEN, ...extra });

// `raw` sends the string as the body unchanged (malformed JSON); `auth: null`
// sends no authorization header at all.
const call = (env, { method = 'GET', body, raw, auth = TOKEN } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = `Bearer ${auth}`;
  const payload = raw !== undefined ? raw : body === undefined ? undefined : JSON.stringify(body);
  const req = new Request(`https://jobs.test${PATH}`, { method, headers, body: payload });
  return worker.fetch(req, env).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const post = (DB, body, opts = {}) => call(envOf(DB, opts.env), { method: 'POST', body, ...opts });
const get = (DB, opts = {}) => call(envOf(DB, opts.env), opts);

const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const R = (suite, seconds) => ({ suite, seconds });
const setWindow = (db, v) => db.prepare("UPDATE settings SET value = ? WHERE key = 'ci_suite_durations.window'").run(v);

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-5653 ci suite durations route', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W0 schema.sql creates the three tables and the window setting, and applies twice', async () => {
    for (const table of TABLES) {
      assert.match(SCHEMA, new RegExp(`CREATE TABLE IF NOT EXISTS ${table} \\(`));
      const cols = probe.db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
      assert.ok(cols.length > 0, `schema.sql creates ${table}`);
    }
    const cols = (tb) => probe.db.prepare(`PRAGMA table_info(${tb})`).all().map((c) => c.name);
    assert.deepEqual(cols('ci_duration_runs'), ['run_id', 'digest', 'suites', 'source', 'posted_at']);
    assert.deepEqual(cols('ci_suite_duration_samples'), ['suite', 'run_id', 'seconds']);
    assert.deepEqual(cols('ci_suite_durations'), ['suite', 'seconds', 'source_run', 'samples', 'updated_at']);
    const s = probe.db.prepare("SELECT value FROM settings WHERE key = 'ci_suite_durations.window'").get();
    assert.equal(s && s.value, '3');
    probe.db.exec(SCHEMA); // a second apply must not error
    assert.throws(() => probe.db.prepare(
      "INSERT INTO ci_duration_runs (run_id, digest, suites, source, posted_at) VALUES (1,'d',1,'other','t')").run(),
    /CHECK/, 'source is ci or seed only');
  });

  await t.test('W1 POST run 101 with 3 rows stores one row per suite, keyed on suite path', async (tt) => {
    const { db, DB } = await fresh(tt);
    const rows = [R('tests/b-test.sh', 12.5), R('tests/a-test.sh', 3), R('tests/mc/c-test.sh', 0)];
    const p = await post(DB, { run_id: 101, rows });
    assert.equal(p.status, 200, JSON.stringify(p.body));
    assert.deepEqual(p.body, { ok: true, duplicate: false, written: 3, run_id: 101, suites: 3 });
    const g = await get(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.count, 3);
    assert.deepEqual(g.body.rows.map((r) => [r.suite, r.seconds, r.source_run, r.samples]), [
      ['tests/a-test.sh', 3, 101, 1],
      ['tests/b-test.sh', 12.5, 101, 1],
      ['tests/mc/c-test.sh', 0, 101, 1],
    ]);
    for (const r of g.body.rows) assert.match(r.updated_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const run = db.prepare('SELECT * FROM ci_duration_runs WHERE run_id = 101').get();
    assert.equal(run.source, 'ci');
    assert.equal(run.suites, 3);
    assert.match(run.digest, /^[0-9a-f]{64}$/);
    const seed = await post(DB, { run_id: 102, source: 'seed', rows: [R('tests/a-test.sh', 10800)] });
    assert.equal(seed.status, 200, JSON.stringify(seed.body));
    assert.equal(db.prepare('SELECT source FROM ci_duration_runs WHERE run_id = 102').get().source, 'seed');
  });

  await t.test('W2 the same run twice is a duplicate; the same run with one changed second is 409', async (tt) => {
    const { db, DB } = await fresh(tt);
    const rows = [R('tests/a-test.sh', 3), R('tests/b-test.sh', 7)];
    assert.equal((await post(DB, { run_id: 201, rows })).status, 200);
    const before = (await get(DB)).body;
    const n = count(db, 'ci_suite_duration_samples');
    // Row order in the body does not change the digest.
    const again = await post(DB, { run_id: 201, rows: [...rows].reverse() });
    assert.equal(again.status, 200, JSON.stringify(again.body));
    assert.deepEqual(again.body, { ok: true, duplicate: true, written: 0, run_id: 201 });
    assert.equal(count(db, 'ci_suite_duration_samples'), n);
    const changed = await post(DB, { run_id: 201, rows: [R('tests/a-test.sh', 3), R('tests/b-test.sh', 8)] });
    assert.equal(changed.status, 409, JSON.stringify(changed.body));
    assert.equal(changed.body.run_id, 201);
    assert.equal(count(db, 'ci_suite_duration_samples'), n);
    assert.equal(count(db, 'ci_duration_runs'), 1);
    assert.deepEqual((await get(DB)).body.rows.map(({ updated_at, ...r }) => r),
      before.rows.map(({ updated_at, ...r }) => r));
  });

  await t.test('W3 rolling median over the window; the window setting changes it', async (tt) => {
    const { db, DB } = await fresh(tt);
    const S = 'tests/w3-test.sh';
    for (const [run, s] of [[101, 10], [102, 30], [103, 20], [104, 99]]) {
      const p = await post(DB, { run_id: run, rows: [R(S, s)] });
      assert.equal(p.status, 200, JSON.stringify(p.body));
    }
    let row = (await get(DB)).body.rows[0];
    assert.deepEqual([row.suite, row.seconds, row.source_run, row.samples], [S, 30, 102, 3]);
    // The prune keeps only the window: run 101's sample is gone.
    assert.equal(count(db, 'ci_suite_duration_samples'), 3);
    // window=1: a re-post of run 104 is a duplicate, and the duplicate path
    // recomputes the median for that run's suites over the newest 1 sample.
    setWindow(db, '1');
    const d = await post(DB, { run_id: 104, rows: [R(S, 99)] });
    assert.equal(d.body.duplicate, true, JSON.stringify(d.body));
    row = (await get(DB)).body.rows[0];
    assert.deepEqual([row.seconds, row.source_run, row.samples], [99, 104, 1]);
    // Garbage in the settings row falls back to 3.
    setWindow(db, 'many');
    await post(DB, { run_id: 104, rows: [R(S, 99)] });
    row = (await get(DB)).body.rows[0];
    assert.deepEqual([row.seconds, row.source_run, row.samples], [30, 102, 3]);
    setWindow(db, '16');
    await post(DB, { run_id: 104, rows: [R(S, 99)] });
    assert.equal((await get(DB)).body.rows[0].samples, 3, 'a window over 15 is garbage, fallback 3');
  });

  await t.test('W4 every bad body is 400 and writes nothing', async (tt) => {
    const { db, DB } = await fresh(tt);
    const good = R('tests/ok-test.sh', 1);
    const badRows = [
      ['suite ../x.sh', R('../x.sh', 1)],
      ['absolute suite', R('/abs/tests/a.sh', 1)],
      ['bin/foo.sh', R('bin/foo.sh', 1)],
      ['tests/a/../b.sh', R('tests/a/../b.sh', 1)],
      ['empty suite', R('', 1)],
      ['non-string suite', R(7, 1)],
      ['seconds -1', R('tests/x-test.sh', -1)],
      ['seconds "NaN"', R('tests/x-test.sh', 'NaN')],
      ['seconds null', R('tests/x-test.sh', null)],
      ['seconds "12s"', R('tests/x-test.sh', '12s')],
      ['seconds 1e9', R('tests/x-test.sh', 1e9)],
      ['seconds 10800.5', R('tests/x-test.sh', 10800.5)],
      ['duplicate suite', R('tests/ok-test.sh', 2)],
      ['row not an object', null],
    ];
    for (const [name, row] of badRows) {
      const p = await post(DB, { run_id: 401, rows: [good, row] });
      assert.equal(p.status, 400, `${name}: ${JSON.stringify(p.body)}`);
      assert.match(p.body.error, /rows\[1\]/, `${name}: the error names the row index`);
      assert.equal(count(db, 'ci_suite_duration_samples'), 0, `${name}: wrote a sample`);
      assert.equal(count(db, 'ci_duration_runs'), 0, `${name}: wrote a run`);
    }
    const badBodies = [
      ['rows []', { run_id: 401, rows: [] }],
      ['rows missing', { run_id: 401 }],
      ['rows not an array', { run_id: 401, rows: { a: 1 } }],
      ['run_id 0', { run_id: 0, rows: [good] }],
      ['run_id "7"', { run_id: '7', rows: [good] }],
      ['run_id 1.5', { run_id: 1.5, rows: [good] }],
      ['run_id -3', { run_id: -3, rows: [good] }],
      ['source "x"', { run_id: 401, source: 'x', rows: [good] }],
      ['over 5000 rows', { run_id: 401, rows: Array.from({ length: 5001 }, (_, i) => R(`tests/s${i}.sh`, 1)) }],
      ['body an array', [good]],
    ];
    for (const [name, body] of badBodies) {
      const p = await post(DB, body);
      assert.equal(p.status, 400, `${name}: ${JSON.stringify(p.body)}`);
      assert.equal(count(db, 'ci_suite_duration_samples'), 0, `${name}: wrote a sample`);
      assert.equal(count(db, 'ci_duration_runs'), 0, `${name}: wrote a run`);
    }
    for (const raw of ['{not json', '', 'null']) {
      const p = await post(DB, undefined, { raw });
      assert.equal(p.status, 400, `malformed ${JSON.stringify(raw)}: ${JSON.stringify(p.body)}`);
      assert.equal(count(db, 'ci_suite_duration_samples'), 0);
    }
    // The same database still takes a good body, so every 400 above was the body.
    const ok = await post(DB, { run_id: 401, rows: [good] });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
  });

  await t.test('W5 a 1,300-row body goes through the chunked multi-row path', async (tt) => {
    const { db, DB } = await fresh(tt);
    const rows = Array.from({ length: 1300 }, (_, i) => R(`tests/s${String(i).padStart(4, '0')}-test.sh`, (i % 97) + 0.25));
    const p = await post(DB, { run_id: 501, rows });
    assert.equal(p.status, 200, JSON.stringify(p.body));
    assert.equal(p.body.written, 1300);
    const g = await get(DB);
    assert.equal(g.body.count, 1300);
    assert.equal(g.body.rows.length, 1300);
    assert.equal(count(db, 'ci_suite_duration_samples'), 1300);
    assert.equal(g.body.rows[1299].suite, 'tests/s1299-test.sh');
    assert.equal(g.body.rows[1299].seconds, (1299 % 97) + 0.25);
    // A second run over the same suites prunes and recomputes in chunks too.
    const p2 = await post(DB, { run_id: 502, rows: rows.map((r) => R(r.suite, r.seconds + 1)) });
    assert.equal(p2.status, 200, JSON.stringify(p2.body));
    assert.equal(count(db, 'ci_suite_duration_samples'), 2600);
    const r0 = (await get(DB)).body.rows[0];
    assert.deepEqual([r0.seconds, r0.source_run, r0.samples], [0.75, 502, 2]);
  });

  await t.test('W6 the route carries its own bearer and fails closed', async (tt) => {
    const { DB } = await fresh(tt);
    assert.equal((await get(DB, { auth: null })).status, 401);
    assert.equal((await get(DB, { auth: 'wrong' })).status, 401);
    const scoped = await get(DB, { auth: TOKEN });
    assert.equal(scoped.status, 200, JSON.stringify(scoped.body));
    assert.equal((await get(DB, { auth: HARNESS })).status, 200);
    const sp = await post(DB, { run_id: 601, rows: [R('tests/a-test.sh', 1)] }, { auth: TOKEN });
    assert.equal(sp.status, 200, JSON.stringify(sp.body));
    // The scoped token is not accepted when the worker has no scoped token set.
    assert.equal((await get(DB, { auth: TOKEN, env: { CI_DURATIONS_TOKEN: undefined } })).status, 401);
    // Neither secret set: every bearer is refused, the empty one included.
    for (const env of [{ HARNESS_SECRET: undefined, CI_DURATIONS_TOKEN: undefined },
      { HARNESS_SECRET: '', CI_DURATIONS_TOKEN: '' }]) {
      for (const auth of ['', 'undefined', null, TOKEN, HARNESS]) {
        const g = await get(DB, { auth, env });
        assert.equal(g.status, 401, `auth ${JSON.stringify(auth)} with ${JSON.stringify(env)}`);
      }
    }
    const unauth = await post(DB, { run_id: 602, rows: [R('tests/a-test.sh', 1)] }, { auth: 'wrong' });
    assert.equal(unauth.status, 401);
    assert.deepEqual(unauth.body, { error: 'unauthorized' });
  });

  await t.test('W7 an unapplied schema answers 503 naming it', async (tt) => {
    const { db, DB } = await fresh(tt);
    for (const table of TABLES) db.exec(`DROP TABLE ${table}`);
    const g = await get(DB);
    assert.equal(g.status, 503, JSON.stringify(g.body));
    assert.equal(g.body.error, 'ci_suite_durations schema not applied');
    const p = await post(DB, { run_id: 701, rows: [R('tests/a-test.sh', 1)] });
    assert.equal(p.status, 503, JSON.stringify(p.body));
    assert.equal(p.body.error, 'ci_suite_durations schema not applied');
  });

  await t.test('W8 an even count is the mean of the two middle values, the newer run named', async (tt) => {
    const { db, DB } = await fresh(tt);
    const A = 'tests/even-two-test.sh';
    assert.equal((await post(DB, { run_id: 1, rows: [R(A, 10)] })).status, 200);
    assert.equal((await post(DB, { run_id: 2, rows: [R(A, 20)] })).status, 200);
    let row = (await get(DB)).body.rows[0];
    assert.deepEqual([row.seconds, row.source_run, row.samples], [15, 2, 2]);
    // Four samples, window 4: sorted 10(r12) 20(r14) 30(r13) 40(r11). The
    // middle two are 20 (run 14) and 30 (run 13): mean 25, newer run 14 —
    // not the upper middle's run.
    setWindow(db, '4');
    const B = 'tests/even-four-test.sh';
    for (const [run, s] of [[11, 40], [12, 10], [13, 30], [14, 20]]) {
      assert.equal((await post(DB, { run_id: run, rows: [R(B, s)] })).status, 200);
    }
    row = (await get(DB)).body.rows.find((r) => r.suite === B);
    assert.deepEqual([row.seconds, row.source_run, row.samples], [25, 14, 4]);
  });
});
