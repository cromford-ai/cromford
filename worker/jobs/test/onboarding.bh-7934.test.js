// BH-7934.0 (#7947): POST /api/onboarding/runs and GET /api/onboarding/runs/:id,
// the onboarding_runs / onboarding_steps tables and their settings seed.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/), the migration-numbers.bh-7325 idiom. Each
// case opens its own fresh DB and uses its own Idempotency-Key.
//   O1 create -> 201, id = ob_ + sha256(key)[:20]; GET -> queued run, 7 queued steps
//   O2 tracker=board -> step 3 is `tracker`, no `label`
//   O3 replay (same body, reordered keys, padded prod) -> 200 same id, no new rows
//   O4 same key, different project -> 409, the first run is intact
//   O5 same key, different tracker -> 409, still 7 steps with `label`
//   O6 no key / a short key -> 400, no row
//   O7 no bearer -> 401, no row
//   O8 unknown fields (token, password) are not stored
//   O9 each bad field -> 400 with its name, no row
//   O10 near-miss accepts
//   O11 GET unknown id / malformed id -> 404
//   O12 the route is gated (in ROUTES, not in OPEN_ROUTES)
//   O13 the retention window seed row is 30
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh7947';
const PATH = '/api/onboarding/runs';
const BODY = { repo: 'example-org/acme-os', project: 'acme-os', tracker: 'github-issues', box: 'shared', prefix: 'ACME', base: 'main', prod: 'https://acme.x.example' };
const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
async function call(DB, method, path, { body, key, bearer = true, actor } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  if (key !== undefined) headers['idempotency-key'] = key;
  if (actor !== undefined) headers['x-harness-actor'] = actor;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const post = (DB, body, key, opts = {}) => call(DB, 'POST', PATH, { body, key, ...opts });
const get = (DB, id) => call(DB, 'GET', `${PATH}/${id}`);
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
const expectedId = (key) => 'ob_' + createHash('sha256').update(key).digest('hex').slice(0, 20);

test('O1 create -> 201 with ob_+sha256(key)[:20]; GET -> queued run with 7 queued steps in order', async (t) => {
  const o = await fresh(t); if (!o) return;
  const key = 'key-fixture-o1';
  const r = await post(o.DB, BODY, key, { actor: 'operator@example.com' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.match(r.body.id, /^ob_[0-9a-f]{20}$/);
  assert.equal(r.body.id, expectedId(key));
  assert.equal(r.body.state, 'queued');
  assert.equal(r.body.created, true);
  const g = await get(o.DB, r.body.id);
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.run.id, r.body.id);
  assert.equal(g.body.run.state, 'queued');
  assert.equal(g.body.run.project, 'acme-os');
  assert.equal(g.body.run.repo, 'example-org/acme-os');
  assert.equal(g.body.run.created_by, 'operator@example.com');
  assert.equal(g.body.run.station, null);
  assert.deepEqual(g.body.run.inputs, BODY);
  assert.deepEqual(g.body.steps.map((s) => s.station), STATIONS);
  assert.deepEqual(g.body.steps.map((s) => s.ord), [1, 2, 3, 4, 5, 6, 7]);
  for (const s of g.body.steps) {
    assert.equal(s.state, 'queued');
    assert.equal(s.retries, 0);
    for (const f of ['started_at', 'finished_at', 'error_code', 'log_excerpt']) assert.ok(f in s && s[f] === null, f);
  }
  assert.equal(count(o.db, 'onboarding_runs'), 1);
  assert.equal(count(o.db, 'onboarding_steps'), 7);
});

test('O2 tracker=board -> step 3 is tracker and there is no label step', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, { ...BODY, tracker: 'board' }, 'key-fixture-o2');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const g = await get(o.DB, r.body.id);
  assert.deepEqual(g.body.steps.map((s) => s.station), ['register', 'prompt', 'tracker', 'box', 'clone', 'smoke', 'ready']);
  assert.equal(g.body.steps[2].ord, 3);
  // no x-harness-actor header, or a malformed one -> created_by is NULL
  assert.equal(g.body.run.created_by, null);
  const bad = await post(o.DB, BODY, 'key-fixture-o2-actor', { actor: 'has space; drop' });
  assert.equal(bad.status, 201);
  assert.equal((await get(o.DB, bad.body.id)).body.run.created_by, null);
});

test('O3 a replay with the same canonical inputs -> 200, same id, no new rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const key = 'key-fixture-o3';
  const a = await post(o.DB, BODY, key);
  assert.equal(a.status, 201);
  const b = await post(o.DB, BODY, key);
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.id, a.body.id);
  assert.equal(b.body.created, false);
  assert.equal(b.body.state, 'queued');
  const reordered = { prod: '  https://acme.x.example  ', box: 'shared', base: 'main', prefix: 'ACME', tracker: 'github-issues', project: 'acme-os', repo: 'example-org/acme-os' };
  const c = await post(o.DB, reordered, `  ${key}  `);
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.id, a.body.id);
  assert.equal(count(o.db, 'onboarding_runs'), 1);
  assert.equal(count(o.db, 'onboarding_steps'), 7);
});

test('O4 the same key with a different project -> 409, the first run keeps its project', async (t) => {
  const o = await fresh(t); if (!o) return;
  const key = 'key-fixture-o4';
  const a = await post(o.DB, BODY, key);
  assert.equal(a.status, 201);
  const b = await post(o.DB, { ...BODY, project: 'other-os' }, key);
  assert.equal(b.status, 409, JSON.stringify(b.body));
  assert.equal(b.body.error, 'idempotency_key_reused');
  assert.equal(b.body.id, a.body.id);
  const row = o.db.prepare('SELECT project FROM onboarding_runs WHERE id = ?').get(a.body.id);
  assert.equal(row.project, 'acme-os');
  assert.equal(count(o.db, 'onboarding_runs'), 1);
});

test('O5 the same key with a different tracker -> 409 and no 8th step', async (t) => {
  const o = await fresh(t); if (!o) return;
  const key = 'key-fixture-o5';
  const a = await post(o.DB, BODY, key);
  assert.equal(a.status, 201);
  const b = await post(o.DB, { ...BODY, tracker: 'board' }, key);
  assert.equal(b.status, 409, JSON.stringify(b.body));
  assert.equal(b.body.error, 'idempotency_key_reused');
  const g = await get(o.DB, a.body.id);
  assert.deepEqual(g.body.steps.map((s) => s.station), STATIONS);
  assert.equal(count(o.db, 'onboarding_steps'), 7);
});

test('O6 no Idempotency-Key or a malformed one -> 400, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const key of [undefined, '', 'abc', 'has space here', 'x'.repeat(129)]) {
    const r = await post(o.DB, BODY, key);
    assert.equal(r.status, 400, String(key));
    assert.equal(r.body.error, 'idempotency_key_required');
  }
  assert.equal(count(o.db, 'onboarding_runs'), 0);
  assert.equal(count(o.db, 'onboarding_steps'), 0);
});

test('O7 no bearer -> 401, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, BODY, 'key-fixture-o7', { bearer: false });
  assert.equal(r.status, 401);
  const g = await call(o.DB, 'GET', `${PATH}/${expectedId('key-fixture-o7')}`, { bearer: false });
  assert.equal(g.status, 401);
  assert.equal(count(o.db, 'onboarding_runs'), 0);
});

test('O8 unknown fields such as token and password are dropped before the row is written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, { ...BODY, token: 'tok-fixture-secret', password: 'pw-fixture', Repo: 'x/y' }, 'key-fixture-o8');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const raw = o.db.prepare('SELECT inputs_json FROM onboarding_runs WHERE id = ?').get(r.body.id).inputs_json;
  const stored = JSON.parse(raw);
  assert.ok(!('token' in stored) && !('password' in stored) && !('Repo' in stored), raw);
  assert.ok(!raw.includes('tok-fixture-secret'), raw);
  assert.deepEqual(Object.keys(stored), Object.keys(BODY).sort());
  const g = await get(o.DB, r.body.id);
  assert.deepEqual(Object.keys(g.body.run.inputs), Object.keys(stored));
});

test('O9 each bad field -> 400 naming the field, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const bad = [
    ['repo', { repo: 'no-slash' }], ['repo', { repo: undefined }],
    ['project', { project: 'Bad Name' }], ['project', { project: 7 }],
    ['tracker', { tracker: 'linear' }], ['tracker', { tracker: 'GitHub-Issues' }], ['tracker', { tracker: 'github_issues' }],
    ['box', { box: 'dedicated' }],
    ['prefix', { prefix: 'ab' }],
    ['base', { base: 'a/../b' }],
    ['prod', { prod: 'http://x.example' }], ['prod', { prod: 'ftp://x.example' }], ['prod', { prod: 'https://' }],
  ];
  let i = 0;
  for (const [field, patch] of bad) {
    const r = await post(o.DB, { ...BODY, ...patch }, `key-fixture-o9-${i++}`);
    assert.equal(r.status, 400, `${field} ${JSON.stringify(patch)}`);
    assert.equal(r.body.error, 'invalid_field');
    assert.equal(r.body.field, field, JSON.stringify(patch));
  }
  const arr = await post(o.DB, [BODY], 'key-fixture-o9-arr');
  assert.equal(arr.status, 400);
  assert.equal(arr.body.error, 'invalid_body');
  assert.equal(count(o.db, 'onboarding_runs'), 0);
  assert.equal(count(o.db, 'onboarding_steps'), 0);
});

test('O10 near-miss accepts: prod "-", no prefix, a nested base, a trimmed board tracker', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { prefix, ...noPrefix } = BODY;
  const r = await post(o.DB, { ...noPrefix, prod: '-', base: 'release/v2', tracker: 'board ' }, 'key-fixture-o10');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const g = await get(o.DB, r.body.id);
  assert.equal(g.body.run.inputs.prod, '-');
  assert.equal(g.body.run.inputs.base, 'release/v2');
  assert.equal(g.body.run.inputs.tracker, 'board');
  assert.ok(!('prefix' in g.body.run.inputs));
  const empty = await post(o.DB, { ...BODY, prefix: '  ' }, 'key-fixture-o10b');
  assert.equal(empty.status, 201, JSON.stringify(empty.body));
  const g2 = await get(o.DB, empty.body.id);
  assert.ok(!('prefix' in g2.body.run.inputs));
});

test('O11 GET of an unknown id -> 404 not_found; a malformed id -> 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  const g = await get(o.DB, expectedId('key-fixture-never'));
  assert.equal(g.status, 404);
  assert.equal(g.body.error, 'not_found');
  const bad = await get(o.DB, 'ob_XYZ');
  assert.equal(bad.status, 404);
});

test('O12 the routes are gated: in ROUTES, not in OPEN_ROUTES', () => {
  assert.ok(matchRoute(ROUTES, 'POST', PATH));
  assert.ok(matchRoute(ROUTES, 'GET', `${PATH}/${expectedId('k')}`));
  assert.equal(matchRoute(OPEN_ROUTES, 'POST', PATH), null);
  assert.equal(matchRoute(OPEN_ROUTES, 'GET', `${PATH}/${expectedId('k')}`), null);
});

test('O13 the retention window settings row is seeded at 30', async (t) => {
  const o = await fresh(t); if (!o) return;
  const v = o.db.prepare("SELECT value FROM settings WHERE key = 'onboarding_runs_retention_days'").get();
  assert.equal(v && v.value, '30');
});
