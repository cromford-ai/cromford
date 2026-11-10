import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { LANES_REGISTRY } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import {
  mergeStatus, readReuseKnobs, credentialClass, validateItems, REUSE_DEFAULTS,
} from '../src/lib/suite-results.js';

// BH-5354.0 (BH-5366): the suite ledger, driven through worker.fetch (the
// production entry) over a real node:sqlite database, so the sticky merge and
// the class filter are the SQL the worker ships, not a stub's idea of it.

const F = 'a'.repeat(64);
const G = 'b'.repeat(64);
const BEARER = { authorization: 'Bearer SECRET' };
const TOKEN = { 'x-suite-ledger-token': 'tok' };

async function setup(t, envExtra = {}) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  // These cases pin the class trust rule (the C0 seed, BH-5354 I1). The worker
  // flips an untouched seed row to image on its first read (BH-9177), so the
  // row is marked an operator's here and keeps class.
  o.db.prepare("UPDATE settings SET actor = 'fixture' WHERE key = 'lib.suite-reuse.suite_reuse_trust'").run();
  const env = { DB: o.DB, HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok', ...envExtra };
  const call = async (method, path, body, headers = BEARER) => {
    const res = await worker.fetch(new Request('https://jobs.test' + path, {
      method, headers: { 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    }), env);
    return { status: res.status, body: await res.json() };
  };
  return { db: o.db, env, call };
}

const put = (items, extra = {}) => ({ repo: 'example-org/cromford', ctx: 'isolated', run_id: 'r1', items, ...extra });
const look = (items, extra = {}) => ({ repo: 'example-org/cromford', ctx: 'isolated', items, ...extra });
const okItem = (suite = 'tests/a.sh', fingerprint = F, duration_s = 7) => ({ suite, fingerprint, status: 'ok', duration_s });

// ── pure ─────────────────────────────────────────────────────────────────────
test('mergeStatus: fail is sticky, ok beats skipped, null prior takes the incoming', () => {
  const S = ['ok', 'fail', 'skipped'];
  const want = { 'ok,ok': 'ok', 'ok,fail': 'fail', 'ok,skipped': 'ok', 'fail,ok': 'fail', 'fail,fail': 'fail',
    'fail,skipped': 'fail', 'skipped,ok': 'ok', 'skipped,fail': 'fail', 'skipped,skipped': 'skipped' };
  for (const a of S) for (const b of S) assert.equal(mergeStatus(a, b), want[`${a},${b}`], `${a} + ${b}`);
  for (const b of S) assert.equal(mergeStatus(null, b), b);
});

test('readReuseKnobs: defaults, off, and every bad value fails toward off', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const setRow = (k, v) => s.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','2026-10-08T00:00:00Z')").run(k, v);
  const clear = () => s.db.prepare("DELETE FROM settings WHERE key LIKE 'lib.suite-reuse.%'").run();
  clear();
  assert.deepEqual(await readReuseKnobs(s.env.DB), { reuse: 'on', max_age_h: 72 });
  assert.deepEqual(REUSE_DEFAULTS, { reuse: 'on', max_age_h: 72 });
  setRow('lib.suite-reuse.suite_reuse', 'off');
  assert.equal((await readReuseKnobs(s.env.DB)).reuse, 'off');
  setRow('lib.suite-reuse.suite_reuse', 'maybe');
  assert.deepEqual(await readReuseKnobs(s.env.DB), { reuse: 'off', max_age_h: 72, reason: 'bad suite_reuse' });
  clear();
  for (const v of ['0', '721', '7.5', '']) {
    setRow('lib.suite-reuse.suite_reuse_max_age_h', v);
    const k = await readReuseKnobs(s.env.DB);
    assert.equal(k.reuse, 'off', `max_age_h=${JSON.stringify(v)}`);
    assert.equal(k.reason, 'bad suite_reuse_max_age_h');
  }
  setRow('lib.suite-reuse.suite_reuse_max_age_h', '24');
  assert.deepEqual(await readReuseKnobs(s.env.DB), { reuse: 'on', max_age_h: 24 });
  const broken = { prepare() { throw new Error('no such table: settings'); } };
  assert.deepEqual(await readReuseKnobs(broken), { reuse: 'off', max_age_h: 72, reason: 'settings unavailable' });
});

test('credentialClass: bearer is builder, token is ci, anything else is null', () => {
  const req = (h) => new Request('https://jobs.test/x', { headers: h });
  const env = { HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok' };
  assert.equal(credentialClass(req(BEARER), env), 'builder');
  assert.equal(credentialClass(req(TOKEN), env), 'ci');
  assert.equal(credentialClass(req({ 'x-suite-ledger-token': ' tok ' }), { ...env, SUITE_LEDGER_TOKEN: 'tok\n' }), 'ci');
  assert.equal(credentialClass(req({ 'x-suite-ledger-token': 'nope' }), env), null);
  assert.equal(credentialClass(req({ 'x-suite-ledger-token': '' }), { HARNESS_SECRET: 'SECRET' }), null);
  assert.equal(credentialClass(req({ 'x-suite-ledger-token': '' }), { HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: '' }), null);
  assert.equal(credentialClass(req({}), env), null);
});

test('validateItems names the index and field, and never clamps', () => {
  assert.equal(validateItems([okItem()], { withStatus: true }), null);
  assert.match(validateItems([okItem(), { ...okItem(), fingerprint: 'xyz' }], { withStatus: true }), /items\[1\]\.fingerprint/);
  assert.match(validateItems([{ ...okItem(), suite: 'bin/x.sh' }], { withStatus: true }), /items\[0\]\.suite/);
  assert.match(validateItems([{ ...okItem(), status: 'green' }], { withStatus: true }), /items\[0\]\.status/);
  assert.match(validateItems([{ ...okItem(), duration_s: 86401 }], { withStatus: true }), /items\[0\]\.duration_s/);
  assert.match(validateItems([{ ...okItem(), duration_s: 1.5 }], { withStatus: true }), /items\[0\]\.duration_s/);
  assert.equal(validateItems([{ suite: 'tests/a.sh', fingerprint: F }], { withStatus: false }), null);
  assert.match(validateItems('x', {}), /items/);
  assert.match(validateItems(Array.from({ length: 1501 }, () => okItem()), {}), /too many items/);
});

// ── W1 ───────────────────────────────────────────────────────────────────────
test('W1 PUT then lookup returns the hit; another ctx and an aged green do not', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const w = await s.call('PUT', '/api/suite-results', put([okItem()]));
  assert.equal(w.status, 200, JSON.stringify(w.body));
  assert.deepEqual(w.body, { ok: true, written: 1, contradicted: [] });
  const l = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }, { suite: 'tests/b.sh', fingerprint: F }]));
  assert.equal(l.status, 200);
  assert.equal(l.body.reuse, 'on');
  assert.equal(l.body.max_age_h, 72);
  assert.equal(l.body.hits.length, 1);
  const { ok_at, ...hit } = l.body.hits[0];
  assert.deepEqual(hit, { suite: 'tests/a.sh', fingerprint: F, run_id: 'r1', duration_s: 7, class: 'builder' });
  assert.match(ok_at, /^\d{4}-\d\d-\d\dT/);
  const other = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }], { ctx: 'local' }));
  assert.deepEqual(other.body.hits, []);
  const otherFp = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: G }]));
  assert.deepEqual(otherFp.body.hits, []);
  s.db.prepare("UPDATE suite_results SET ok_at='2020-01-01T00:00:00Z'").run();
  const aged = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }]));
  assert.deepEqual(aged.body.hits, []);
});

// ── W2 ───────────────────────────────────────────────────────────────────────
test('W2 ok, fail, ok on one key stores fail and is never reused', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.call('PUT', '/api/suite-results', put([okItem()]));
  await s.call('PUT', '/api/suite-results', put([{ ...okItem(), status: 'fail' }], { run_id: 'r2' }));
  const r3 = await s.call('PUT', '/api/suite-results', put([okItem()], { run_id: 'r3' }));
  assert.equal(r3.status, 200);
  const row = s.db.prepare('SELECT status, runs, fails, run_id FROM suite_results').get();
  assert.equal(row.status, 'fail');
  assert.equal(row.runs, 3);
  assert.equal(row.fails, 1);
  const l = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }]));
  assert.deepEqual(l.body.hits, []);
});

// ── W3 ───────────────────────────────────────────────────────────────────────
test('W3 a fail over a stored ok comes back as contradicted, naming the prior run', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.call('PUT', '/api/suite-results', put([okItem(), okItem('tests/b.sh')]));
  const w = await s.call('PUT', '/api/suite-results', put([{ ...okItem(), status: 'fail' }, okItem('tests/b.sh')], { run_id: 'r2' }));
  assert.equal(w.status, 200);
  assert.deepEqual(w.body.contradicted, [{ suite: 'tests/a.sh', fingerprint: F, prior_run_id: 'r1' }]);
  assert.equal(w.body.written, 2);
});

// ── W4 ───────────────────────────────────────────────────────────────────────
test('W4 settings rows drive the answer: off hides hits, defaults match the registry, a bad age is off', async (t) => {
  const s = await setup(t);
  if (!s) return;
  s.db.prepare("DELETE FROM settings WHERE key LIKE 'lib.suite-reuse.%'").run();
  await s.call('PUT', '/api/suite-results', put([okItem()]));
  const on = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }]));
  const lib = LANES_REGISTRY.libs.find((l) => l.id === 'suite-reuse');
  assert.equal(on.body.reuse, lib.knobs.find((k) => k.env === 'SUITE_REUSE').default);
  assert.equal(on.body.max_age_h, lib.knobs.find((k) => k.env === 'SUITE_REUSE_MAX_AGE_H').default);
  assert.equal(on.body.hits.length, 1);
  s.db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lib.suite-reuse.suite_reuse','off','t','t','2026-10-08T00:00:00Z')").run();
  const off = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }]));
  assert.equal(off.status, 200);
  assert.equal(off.body.reuse, 'off');
  assert.deepEqual(off.body.hits, []);
  s.db.prepare("DELETE FROM settings WHERE key LIKE 'lib.suite-reuse.%'").run();
  s.db.prepare("INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lib.suite-reuse.suite_reuse_max_age_h','0','t','t','2026-10-08T00:00:00Z')").run();
  const bad = await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: F }]));
  assert.equal(bad.body.reuse, 'off');
  assert.equal(bad.body.reason, 'bad suite_reuse_max_age_h');
  assert.deepEqual(bad.body.hits, []);
});

// ── W5 ───────────────────────────────────────────────────────────────────────
test('W5 the class comes from the credential, and a token caller only sees ci rows', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const tw = await s.call('PUT', '/api/suite-results', put([okItem('tests/a.sh')], { run_id: 'c1' }), TOKEN);
  assert.equal(tw.status, 200, JSON.stringify(tw.body));
  const bw = await s.call('PUT', '/api/suite-results', put([okItem('tests/b.sh')], { run_id: 'b1' }));
  assert.equal(bw.status, 200);
  const rows = s.db.prepare('SELECT suite, class FROM suite_results ORDER BY suite').all().map((r) => [r.suite, r.class]);
  assert.deepEqual(rows, [['tests/a.sh', 'ci'], ['tests/b.sh', 'builder']]);
  const lie = await s.call('PUT', '/api/suite-results', put([okItem('tests/c.sh')], { class: 'builder' }), TOKEN);
  assert.equal(lie.status, 403);
  assert.equal(lie.body.error, 'class does not match credential');
  const items = [{ suite: 'tests/a.sh', fingerprint: F }, { suite: 'tests/b.sh', fingerprint: F }];
  const tl = await s.call('POST', '/api/suite-results/lookup', look(items), TOKEN);
  assert.deepEqual(tl.body.hits.map((h) => [h.suite, h.class]), [['tests/a.sh', 'ci']]);
  const bl = await s.call('POST', '/api/suite-results/lookup', look(items));
  assert.deepEqual(bl.body.hits.map((h) => [h.suite, h.class]).sort(), [['tests/a.sh', 'ci'], ['tests/b.sh', 'builder']]);
  const unset = await setup(t, { SUITE_LEDGER_TOKEN: undefined });
  for (const [m, p] of [['POST', '/api/suite-results/lookup'], ['PUT', '/api/suite-results'], ['PUT', '/api/suite-results/runs']]) {
    assert.equal((await unset.call(m, p, look(items), { 'x-suite-ledger-token': '' })).status, 401, `${m} ${p} unset secret`);
    assert.equal((await s.call(m, p, look(items), {})).status, 401, `${m} ${p} no credential`);
  }
});

// ── W5b ──────────────────────────────────────────────────────────────────────
test('W5b fail is sticky across classes: a red in either class hides the other class\'s green from the bearer', async (t) => {
  const key = [{ suite: 'tests/a.sh', fingerprint: F }];
  const failItem = { ...okItem(), status: 'fail' };
  // ci ok, then builder fail at the same key.
  let s = await setup(t);
  if (!s) return;
  assert.equal((await s.call('PUT', '/api/suite-results', put([okItem()], { run_id: 'c1' }), TOKEN)).status, 200);
  const bf = await s.call('PUT', '/api/suite-results', put([failItem], { run_id: 'b1' }));
  assert.equal(bf.status, 200);
  assert.deepEqual(bf.body.contradicted, [{ suite: 'tests/a.sh', fingerprint: F, prior_run_id: 'c1' }]);
  assert.deepEqual((await s.call('POST', '/api/suite-results/lookup', look(key))).body.hits, [], 'bearer after builder fail');
  // A token caller never sees builder rows, so the ci green is still its hit.
  assert.deepEqual((await s.call('POST', '/api/suite-results/lookup', look(key), TOKEN)).body.hits.map((h) => h.run_id), ['c1']);
  // builder ok, then ci fail at the same key.
  s = await setup(t);
  assert.equal((await s.call('PUT', '/api/suite-results', put([okItem()], { run_id: 'b1' }))).status, 200);
  const cf = await s.call('PUT', '/api/suite-results', put([failItem], { run_id: 'c1' }), TOKEN);
  assert.equal(cf.status, 200);
  assert.deepEqual(cf.body.contradicted, [], 'a token caller cannot see the builder green it hid');
  assert.deepEqual((await s.call('POST', '/api/suite-results/lookup', look(key))).body.hits, [], 'bearer after ci fail');
  assert.deepEqual((await s.call('POST', '/api/suite-results/lookup', look(key), TOKEN)).body.hits, [], 'token after ci fail');
  // Another fingerprint of the same suite is untouched.
  await s.call('PUT', '/api/suite-results', put([okItem('tests/a.sh', G)], { run_id: 'b2' }));
  assert.deepEqual((await s.call('POST', '/api/suite-results/lookup', look([{ suite: 'tests/a.sh', fingerprint: G }]))).body.hits.map((h) => h.run_id), ['b2']);
});

test('a JSON null or array body is a 400, never a throw', async (t) => {
  const s = await setup(t);
  if (!s) return;
  for (const [m, p] of [['POST', '/api/suite-results/lookup'], ['PUT', '/api/suite-results'], ['PUT', '/api/suite-results/runs']]) {
    for (const b of [null, []]) {
      const r = await s.call(m, p, b);
      assert.equal(r.status, 400, `${m} ${p} ${JSON.stringify(b)}`);
      assert.equal(r.body.error, 'body must be a JSON object');
    }
  }
});

// ── W6 ───────────────────────────────────────────────────────────────────────
test('W6 a replayed PUT moves no counter; a new run_id does; runs rows are idempotent and class-bound', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.call('PUT', '/api/suite-results', put([okItem()]));
  await s.call('PUT', '/api/suite-results', put([okItem()]));
  let rows = s.db.prepare('SELECT runs, fails FROM suite_results').all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].runs, 1);
  await s.call('PUT', '/api/suite-results', put([okItem()], { run_id: 'r2' }));
  rows = s.db.prepare('SELECT runs, run_id FROM suite_results').all();
  assert.equal(rows[0].runs, 2);
  assert.equal(rows[0].run_id, 'r2');
  const run = { repo: 'example-org/cromford', run_key: 'k1', ctx: 'isolated', ran: 1, reused: 2, total: 3, saved_s: 10 };
  const a = await s.call('PUT', '/api/suite-results/runs', run);
  assert.equal(a.status, 200, JSON.stringify(a.body));
  const b = await s.call('PUT', '/api/suite-results/runs', run);
  assert.equal(b.status, 200);
  const runs = s.db.prepare('SELECT ran, reused, total, saved_s, class FROM suite_reuse_runs').all();
  assert.deepEqual(runs.map((r) => ({ ...r })), [{ ran: 1, reused: 2, total: 3, saved_s: 10, class: 'builder' }]);
  const other = await s.call('PUT', '/api/suite-results/runs', run, TOKEN);
  assert.equal(other.status, 409);
  const over = await s.call('PUT', '/api/suite-results/runs', { ...run, run_key: 'k2', ran: 3 });
  assert.equal(over.status, 400);
});

// ── bounds ───────────────────────────────────────────────────────────────────
test('more than 1500 items is a 400, a bad fingerprint names its index and field', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const many = Array.from({ length: 1501 }, (_, i) => ({ suite: `tests/s${i}.sh`, fingerprint: F }));
  const r = await s.call('POST', '/api/suite-results/lookup', look(many));
  assert.equal(r.status, 400);
  assert.match(r.body.error, /too many items/);
  const bad = await s.call('PUT', '/api/suite-results', put([okItem(), { ...okItem('tests/b.sh'), fingerprint: 'nothex' }]));
  assert.equal(bad.status, 400);
  assert.match(bad.body.error, /items\[1\]\.fingerprint/);
  assert.equal(s.db.prepare('SELECT count(*) AS n FROM suite_results').get().n, 0, 'a bad item rejects the whole batch');
  const lots = Array.from({ length: 1500 }, (_, i) => ({ suite: `tests/s${i}.sh`, fingerprint: F }));
  const ok = await s.call('POST', '/api/suite-results/lookup', look(lots));
  assert.equal(ok.status, 200, 'a full 1500-item lookup is one bind, under the D1 cap');
});

test('the prune deletes at most 500 stale rows per write', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.call('PUT', '/api/suite-results', put([okItem('tests/seed.sh')]));
  const ins = s.db.prepare(`INSERT INTO suite_results (repo,ctx,class,suite,fingerprint,status,run_id,last_run_id,first_at,updated_at)
    VALUES ('r','c','ci',?,?,'ok','old','old','2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')`);
  for (let i = 0; i < 600; i++) ins.run(`tests/old${i}.sh`, F);
  await s.call('PUT', '/api/suite-results', put([okItem()]));
  const stale = s.db.prepare("SELECT count(*) AS n FROM suite_results WHERE updated_at < '2021-01-01'").get().n;
  assert.equal(stale, 100);
  assert.equal(s.db.prepare("SELECT count(*) AS n FROM suite_results WHERE suite IN ('tests/a.sh','tests/seed.sh')").get().n, 2);
});
