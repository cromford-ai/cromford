// BH-9063 (C0): the suite ledger's trust knob and its red rows, driven through
// worker.fetch (the production entry) over a real node:sqlite database.
//
//   T1 readTrustKnob: absent, class, image, and every bad value
//   T2 a bad trust row answers reuse off, with no hits and no reds
//   T3 image trust: a builder green is a hit for a ci caller in another ctx;
//      another fingerprint is not; class trust keeps the BH-5354 I1 rule
//   T4 image trust: a fail in any class or ctx hides the green; an aged green
//      and a skipped row are not hits
//   T5 wrong tenant: repo A's greens and reds are 0 hits and 0 reds for repo B
//   T6 reds: inside the window, past it, ok -> fail -> ok, class visibility;
//      T6b the helper's jq filter reads the same hit rows with reds present
//   T7 EXPLAIN QUERY PLAN at 20,000 rows: every lookup and reds form seeks
//      an index; a 1,500-item lookup returns every seeded hit
//   T8 a batch-shaped PUT of 40 suites is 40 rows, idempotent on a replay
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { readTrustKnob, TRUST_DEFAULT } from '../src/lib/suite-trust.js';
import { lookupSql, redsSql } from '../src/routes/suite-results.js';

const F = 'a'.repeat(64);
const F2 = 'a'.repeat(63) + 'b';
const BEARER = { authorization: 'Bearer SECRET' };
const TOKEN = { 'x-suite-ledger-token': 'tok' };
const TRUST_KEY = 'lib.suite-reuse.suite_reuse_trust';
const isoAgo = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok offsets from the server clock the route reads

let seq = 0;
const uniq = (p) => `example-org/${p}-${process.pid}-${++seq}`;

async function setup(t, trust) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok' };
  const call = async (method, path, body, headers = BEARER) => {
    const res = await worker.fetch(new Request('https://jobs.test' + path, {
      method, headers: { 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    }), env);
    return { status: res.status, body: await res.json() };
  };
  const setTrust = (v) => {
    if (v === undefined) o.db.prepare('DELETE FROM settings WHERE key=?').run(TRUST_KEY);
    else o.db.prepare("INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','t','2026-11-05T00:00:00Z')").run(TRUST_KEY, v);
  };
  setTrust(trust);
  return { db: o.db, env, call, setTrust };
}

const ok = (suite = 'tests/a.sh', fingerprint = F, duration_s = 7) => ({ suite, fingerprint, status: 'ok', duration_s });
const fail = (suite = 'tests/a.sh', fingerprint = F) => ({ suite, fingerprint, status: 'fail', duration_s: 3 });
const skip = (suite = 'tests/a.sh', fingerprint = F) => ({ suite, fingerprint, status: 'skipped', duration_s: 0 });
const put = (s, repo, ctx, run_id, items, headers = BEARER) => s.call('PUT', '/api/suite-results', { repo, ctx, run_id, items }, headers);
const look = (s, repo, ctx, items, headers = BEARER) => s.call('POST', '/api/suite-results/lookup', { repo, ctx, items }, headers);
const key = (suite = 'tests/a.sh', fingerprint = F) => ({ suite, fingerprint });

// ── T1 ───────────────────────────────────────────────────────────────────────
test('T1 readTrustKnob: absent is class, class and image are themselves, anything else is off', async (t) => {
  const s = await setup(t);
  if (!s) return;
  assert.equal(TRUST_DEFAULT, 'class');
  assert.deepEqual(await readTrustKnob(s.env.DB), { trust: 'class' });
  for (const v of ['class', 'image']) {
    s.setTrust(v);
    assert.deepEqual(await readTrustKnob(s.env.DB), { trust: v }, v);
  }
  for (const v of ['IMAGE', ' image', '', '1', 'image ', 'ci']) {
    s.setTrust(v);
    assert.deepEqual(await readTrustKnob(s.env.DB), { trust: null, reason: 'bad suite_reuse_trust' }, JSON.stringify(v));
  }
  const broken = { prepare() { throw new Error('no such table: settings'); } };
  assert.deepEqual(await readTrustKnob(broken), { trust: null, reason: 'settings unavailable' });
});

// ── T2 ───────────────────────────────────────────────────────────────────────
test('T2 a bad trust row answers 200 reuse off with its reason and no rows', async (t) => {
  const s = await setup(t, 'class');
  if (!s) return;
  const repo = uniq('t2');
  assert.equal((await put(s, repo, 'isolated', 'r1', [ok()])).status, 200);
  assert.equal((await put(s, repo, 'isolated', 'r2', [fail('tests/b.sh')])).status, 200);
  const before = await look(s, repo, 'isolated', [key(), key('tests/b.sh')]);
  assert.equal(before.body.reuse, 'on');
  assert.equal(before.body.hits.length, 1);
  s.setTrust('IMAGE');
  const l = await look(s, repo, 'isolated', [key(), key('tests/b.sh')]);
  assert.equal(l.status, 200);
  assert.equal(l.body.reuse, 'off');
  assert.equal(l.body.reason, 'bad suite_reuse_trust');
  assert.deepEqual(l.body.hits, []);
  assert.deepEqual(l.body.reds, []);
});

// ── T3 ───────────────────────────────────────────────────────────────────────
test('T3 image trust: a builder green is a ci hit in another ctx; another fp is not; class trust holds I1', async (t) => {
  const s = await setup(t, 'image');
  if (!s) return;
  const repo = uniq('t3');
  assert.equal((await put(s, repo, 'isolated', 'b1', [ok()])).status, 200);
  const ci = await look(s, repo, 'ubuntu-latest', [key()], TOKEN);
  assert.equal(ci.status, 200, JSON.stringify(ci.body));
  assert.equal(ci.body.trust, 'image');
  assert.equal(ci.body.hits.length, 1);
  assert.equal(ci.body.hits[0].run_id, 'b1');
  assert.equal(ci.body.hits[0].class, 'builder');
  const otherFp = await look(s, repo, 'ubuntu-latest', [key('tests/a.sh', F2)], TOKEN);
  assert.deepEqual(otherFp.body.hits, []);
  const builderOtherCtx = await look(s, repo, 'local', [key()]);
  assert.equal(builderOtherCtx.body.hits.length, 1);
  s.setTrust(undefined);
  const classCi = await look(s, repo, 'ubuntu-latest', [key()], TOKEN);
  assert.equal(classCi.body.trust, 'class');
  assert.deepEqual(classCi.body.hits, []);
  const classSameCtx = await look(s, repo, 'isolated', [key()], TOKEN);
  assert.deepEqual(classSameCtx.body.hits, [], 'class trust: a ci caller never sees a builder green');
  const classOtherCtx = await look(s, repo, 'local', [key()]);
  assert.deepEqual(classOtherCtx.body.hits, [], 'class trust: another ctx is not a hit');
});

// ── T4 ───────────────────────────────────────────────────────────────────────
test('T4 image trust: a fail anywhere at the key hides every green; aged and skipped are not hits', async (t) => {
  const s = await setup(t, 'image');
  if (!s) return;
  const repo = uniq('t4');
  // a: green in builder/isolated, fail in ci/ubuntu-latest (another class AND ctx)
  await put(s, repo, 'isolated', 'b1', [ok('tests/a.sh'), ok('tests/b.sh'), ok('tests/c.sh'), skip('tests/d.sh')]);
  await put(s, repo, 'ubuntu-latest', 'c1', [fail('tests/a.sh')], TOKEN);
  // b: fail in builder, another ctx
  await put(s, repo, 'local', 'b2', [fail('tests/b.sh')]);
  for (const [who, h] of [['builder', BEARER], ['ci', TOKEN]]) {
    const l = await look(s, repo, 'isolated', [key('tests/a.sh'), key('tests/b.sh'), key('tests/c.sh'), key('tests/d.sh')], h);
    assert.deepEqual(l.body.hits.map((x) => x.suite), ['tests/c.sh'], who);
  }
  // c's green 1 s past max_age_h is not a hit; 60 s inside the window still is
  s.db.prepare('UPDATE suite_results SET ok_at=? WHERE repo=? AND suite=?').run(isoAgo(72 * 3600 - 60), repo, 'tests/c.sh');
  assert.equal((await look(s, repo, 'x', [key('tests/c.sh')], TOKEN)).body.hits.length, 1);
  s.db.prepare('UPDATE suite_results SET ok_at=? WHERE repo=? AND suite=?').run(isoAgo(72 * 3600 + 1), repo, 'tests/c.sh');
  assert.deepEqual((await look(s, repo, 'x', [key('tests/c.sh')], TOKEN)).body.hits, []);
  // class trust: the builder sees the ci fail on a (same ctx only), so a in another ctx is gone already
  s.setTrust('class');
  const cls = await look(s, repo, 'isolated', [key('tests/a.sh'), key('tests/b.sh')]);
  assert.deepEqual(cls.body.hits.map((x) => x.suite), ['tests/a.sh', 'tests/b.sh'],
    'class trust: a fail in another ctx does not hide the green (the pre-BH-9063 rule)');
});

// ── T5 ───────────────────────────────────────────────────────────────────────
test('T5 wrong tenant: repo A greens and reds are 0 hits and 0 reds for repo B, in both modes', async (t) => {
  const s = await setup(t, 'image');
  if (!s) return;
  const A = uniq('t5a'), B = uniq('t5b');
  await put(s, A, 'isolated', 'a1', [ok('tests/a.sh'), fail('tests/b.sh')]);
  await put(s, A, 'ubuntu-latest', 'a2', [ok('tests/a.sh'), fail('tests/b.sh')], TOKEN);
  for (const mode of ['image', 'class']) {
    s.setTrust(mode);
    for (const [who, h, ctx] of [['builder', BEARER, 'isolated'], ['ci', TOKEN, 'ubuntu-latest']]) {
      const inA = await look(s, A, ctx, [key('tests/a.sh'), key('tests/b.sh')], h);
      assert.ok(inA.body.hits.length > 0 && inA.body.reds.length > 0, `${mode}/${who}: repo A must see its own rows`);
      const inB = await look(s, B, ctx, [key('tests/a.sh'), key('tests/b.sh')], h);
      assert.equal(inB.status, 200);
      assert.deepEqual(inB.body.hits, [], `${mode}/${who} hits`);
      assert.deepEqual(inB.body.reds, [], `${mode}/${who} reds`);
    }
  }
});

// ── T6 ───────────────────────────────────────────────────────────────────────
test('T6 reds: a fail in the window is served with its run and class; aged, ok, and class-hidden ones are not', async (t) => {
  const s = await setup(t, 'image');
  if (!s) return;
  const repo = uniq('t6');
  await put(s, repo, 'isolated', 'b1', [fail('tests/a.sh'), ok('tests/b.sh'), fail('tests/old.sh')]);
  // ok -> fail -> ok stays fail (sticky), so it is a red
  await put(s, repo, 'isolated', 'b2', [ok('tests/flip.sh')]);
  await put(s, repo, 'isolated', 'b3', [fail('tests/flip.sh')]);
  await put(s, repo, 'isolated', 'b4', [ok('tests/flip.sh')]);
  s.db.prepare('UPDATE suite_results SET updated_at=? WHERE repo=? AND suite=?').run(isoAgo(72 * 3600 + 1), repo, 'tests/old.sh');
  const items = ['tests/a.sh', 'tests/b.sh', 'tests/old.sh', 'tests/flip.sh'].map((x) => key(x));
  const l = await look(s, repo, 'ubuntu-latest', items, TOKEN);
  assert.equal(l.status, 200);
  assert.equal(l.body.trust, 'image');
  assert.deepEqual(l.body.reds, [
    { suite: 'tests/a.sh', fingerprint: F, run_id: 'b1', class: 'builder' },
    { suite: 'tests/flip.sh', fingerprint: F, run_id: 'b4', class: 'builder' },
  ]);
  assert.deepEqual(l.body.hits.map((x) => x.suite), ['tests/b.sh']);
  // class trust: a ci caller does not see a builder red; the builder does
  s.setTrust('class');
  const ci = await look(s, repo, 'isolated', items, TOKEN);
  assert.deepEqual(ci.body.reds, []);
  const b = await look(s, repo, 'isolated', items);
  assert.deepEqual(b.body.reds.map((x) => x.suite), ['tests/a.sh', 'tests/flip.sh']);
  assert.deepEqual((await look(s, repo, 'local', items)).body.reds, [], 'class trust: another ctx serves no red');
});

test('T6b the helper jq filter reads the same hit rows from an answer that carries reds', async (t) => {
  const s = await setup(t, 'image');
  if (!s) return;
  const repo = uniq('t6b');
  await put(s, repo, 'isolated', 'b1', [ok('tests/a.sh'), fail('tests/b.sh')]);
  const res = await worker.fetch(new Request('https://jobs.test/api/suite-results/lookup', {
    method: 'POST', headers: { 'content-type': 'application/json', ...TOKEN },
    body: JSON.stringify({ repo, ctx: 'ubuntu-latest', items: [key('tests/a.sh'), key('tests/b.sh')] }),
  }), s.env);
  const raw = await res.text();
  const ans = JSON.parse(raw);
  assert.equal(ans.reds.length, 1);
  // bin/suite-reuse.sh's filter, verbatim
  const filter = '.hits | if type == "array" then .[] else error("hits") end | [.suite, .fingerprint, .run_id, (.duration_s | tostring), .class] | @tsv';
  let withReds;
  try { withReds = execFileSync('jq', ['-r', filter], { input: raw, encoding: 'utf8' }); } catch (e) {
    if (e.code === 'ENOENT') return t.skip('jq not installed');
    throw e;
  }
  const { reds, trust, ...bare } = ans;
  const without = execFileSync('jq', ['-r', filter], { input: JSON.stringify(bare), encoding: 'utf8' });
  assert.equal(withReds, without);
  assert.equal(withReds, `tests/a.sh\t${F}\tb1\t7\tbuilder\n`);
});

// ── T7 ───────────────────────────────────────────────────────────────────────
test('T7 at 20,000 rows every lookup and reds form seeks an index; 1,500 items return every hit', async (t) => {
  const s = await setup(t, 'image');
  if (!s) return;
  const REPOS = ['example-org/r0', 'example-org/r1', 'example-org/r2'];
  const COMBOS = [];
  for (const repo of REPOS) for (const ctx of ['isolated', 'ubuntu-latest']) for (const cls of ['builder', 'ci']) COMBOS.push([repo, ctx, cls]);
  const N = 20000;
  const fp = (k) => k.toString(16).padStart(64, '0');
  const now = isoAgo(3600);
  const ins = s.db.prepare(`INSERT INTO suite_results (repo, ctx, class, suite, fingerprint, status, duration_s, run_id, head_sha, ok_at,
      last_run_id, runs, fails, first_at, updated_at) VALUES (?,?,?,?,?,'ok',5,?,NULL,?,?,1,0,?,?)`);
  s.db.exec('BEGIN');
  for (let i = 0; i < N; i++) {
    const [repo, ctx, cls] = COMBOS[i % COMBOS.length];
    const k = Math.floor(i / COMBOS.length);
    ins.run(repo, ctx, cls, `tests/s${k}.sh`, fp(k), `run-${i}`, now, `run-${i}`, now, now);
  }
  s.db.exec('COMMIT');
  const items = Array.from({ length: 1500 }, (_, k) => key(`tests/s${k}.sh`, fp(k)));
  const l = await look(s, 'example-org/r0', 'isolated', items, TOKEN);
  assert.equal(l.status, 200, JSON.stringify(l.body).slice(0, 200));
  assert.equal(new Set(l.body.hits.map((x) => x.suite)).size, 1500);
  assert.equal(l.body.hits.length, 1500 * 4, 'image trust: every ctx and class row at the key');
  assert.deepEqual(l.body.reds, []);
  s.db.exec('ANALYZE');
  const binds = [JSON.stringify(items), 'example-org/r0', 'isolated', isoAgo(72 * 3600)];
  for (const cls of ['builder', 'ci']) {
    for (const [trust, idx] of [['image', 'idx_suite_results_fp'], ['class', null]]) {
      for (const [name, sql] of [['lookup', lookupSql(cls, trust)], ['reds', redsSql(cls, trust)]]) {
        const p = plan(s.db, sql, ...binds);
        const at = `${name}/${cls}/${trust}: ${JSON.stringify(p)}`;
        assert.match(p[0], /^SCAN j VIRTUAL TABLE/, `json_each is not the outer loop: ${at}`);
        assert.deepEqual(fullScans(p, ['suite_results', 'r', 'f']), [], at);
        assert.ok(!p.some((d) => /^SCAN (r|f)\b/.test(d)), at);
        if (idx) assert.ok(p.some((d) => d.includes(`USING INDEX ${idx}`)), at);
        else assert.ok(p.some((d) => /USING INDEX (idx_suite_results_key|sqlite_autoindex_suite_results_1)/.test(d)), at);
      }
    }
  }
});

// ── T8 ───────────────────────────────────────────────────────────────────────
test('T8 a batch-shaped PUT of 40 suites writes 40 rows, and a replay changes nothing', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const repo = uniq('t8');
  const items = Array.from({ length: 40 }, (_, i) => (i % 5 === 0 ? fail(`tests/s${i}.sh`) : ok(`tests/s${i}.sh`)));
  const n = () => s.db.prepare('SELECT COUNT(*) AS n, MAX(runs) AS mr, MIN(runs) AS mn, SUM(fails) AS f FROM suite_results WHERE repo=?').get(repo);
  const w1 = await put(s, repo, 'ubuntu-latest', 'batch-1', items, TOKEN);
  assert.equal(w1.status, 200, JSON.stringify(w1.body));
  assert.equal(w1.body.written, 40);
  assert.deepEqual({ ...n() }, { n: 40, mr: 1, mn: 1, f: 8 });
  const w2 = await put(s, repo, 'ubuntu-latest', 'batch-1', items, TOKEN);
  assert.equal(w2.status, 200);
  assert.deepEqual({ ...n() }, { n: 40, mr: 1, mn: 1, f: 8 });
});
