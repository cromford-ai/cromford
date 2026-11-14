// BH-9263: the QA read token. A QA preview session reads harness-jobs with a
// separate QA_READ_TOKEN that opens only the allowlisted GET routes, and every
// answer is projected to the listed fields. Driven through the REAL
// worker.fetch on node:sqlite with the composed jobs schema.
//   J1 GET jobs: 200, projected (no meta, no beat_note)
//   J2 GET otp: 403, no code       J3 GET settings: 403
//   J4 a write and an unknown route: 403
//   J5 GET flags: 200, no value    J6 HARNESS_SECRET: full row (operator path)
//   J7 token unset, or equal to HARNESS_SECRET: 401
//   J8 only the allowed query parameters reach the handler
//   J9 the worker's policy copy is byte-identical to the console-ui one, and
//      qa-read.js imports nothing outside the worker deploy snapshot
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { qaReadDispatch } from '../src/lib/qa-read.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { readFileSync } from 'node:fs';

const SECRET = 'tok-fixture-bh9263-harness';
const QA = 'tok-fixture-bh9263-qa-read';
const T0 = '2026-11-13T10:00:00Z';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, method, path, { auth = `Bearer ${QA}`, env = {} } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = auth;
  const init = { method, headers };
  if (method !== 'GET') init.body = '{}';
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET, QA_READ_TOKEN: QA, ...env })
    .then(async (res) => ({ status: res.status, headers: res.headers, text: await res.text() }))
    .then((r) => ({ ...r, body: (() => { try { return JSON.parse(r.text); } catch { return null; } })() }));
}
function seedJob(db, id) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta)
              VALUES (?, 'proj-bh9263', 'BH-9263', 'build', 'box-fixture', 'execute', 'running', ?, ?, ?)`)
    .run(id, T0, T0, JSON.stringify({ pr: 'https://example.test/pr/1', note: 'opaque-meta-fixture' }));
}

test('J1 GET /api/jobs with the QA token: 200, the row has id and status, no meta, no beat_note', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedJob(o.db, 'job-bh9263-j1');
  const r = await call(o.DB, 'GET', '/api/jobs');
  assert.equal(r.status, 200, r.text);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const row = r.body.jobs.find((j) => j.id === 'job-bh9263-j1');
  assert.ok(row, r.text);
  assert.equal(row.status, 'running');
  assert.equal('meta' in row, false);
  assert.equal('beat_note' in row, false);
  assert.equal('beat_box' in row, false);
  assert.equal(r.text.includes('opaque-meta-fixture'), false);
  assert.equal(typeof r.body.as_of, 'string');
});

test('J2 GET /api/otp with the QA token: 403 and no code', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.prepare(`INSERT INTO otp_messages (recipient, message_id, sender, subject, code, parse_status, received_at)
                VALUES ('a@otp.example.com', 'm-bh9263', 'noreply@vendor.example.test', 'Your code', '918273', 'code', ?)`).run(T0);
  const r = await call(o.DB, 'GET', '/api/otp?to=a@otp.example.com&since=2026-11-13T00:00:00Z');
  assert.equal(r.status, 403, r.text);
  assert.equal(r.text.includes('918273'), false);
  // Not vacuous: the operator bearer does read the code.
  const op = await call(o.DB, 'GET', '/api/otp?to=a@otp.example.com&since=2026-11-13T00:00:00Z', { auth: `Bearer ${SECRET}` });
  assert.equal(op.body.code, '918273');
});

test('J3 GET /api/settings and /api/settings/x with the QA token: 403', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const p of ['/api/settings', '/api/settings/x', '/api/jobs/job-x/events', '/api/flagsx']) {
    const r = await call(o.DB, 'GET', p);
    assert.equal(r.status, 403, `${p} ${r.text}`);
    assert.equal(r.body.error, 'not allowed for the QA read token');
  }
});

test('J4 POST /api/flags and GET /api/unknown-route with the QA token: 403, nothing written', async (t) => {
  const o = await fresh(t); if (!o) return;
  const w = await call(o.DB, 'POST', '/api/flags');
  assert.equal(w.status, 403, w.text);
  const p = await call(o.DB, 'PUT', '/api/flags');
  assert.equal(p.status, 403, p.text);
  const u = await call(o.DB, 'GET', '/api/unknown-route');
  assert.equal(u.status, 403, u.text);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM pause_flags').get().n, 0);
});

test('J5 GET /api/flags with the QA token: 200, rows carry no value and no unknown column', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.prepare(`INSERT INTO pause_flags (name, active, actor, reason, updated_at, value)
                VALUES ('wip-limit-bh9263', 1, 'console', 'fixture', ?, 'secret-value-fixture')`).run(T0);
  const r = await call(o.DB, 'GET', '/api/flags');
  assert.equal(r.status, 200, r.text);
  const row = r.body.flags.find((f) => f.name === 'wip-limit-bh9263');
  assert.ok(row, r.text);
  assert.equal(row.active, 1);
  assert.equal('value' in row, false);
  assert.equal('actor' in row, false);
  assert.equal(r.text.includes('secret-value-fixture'), false);
});

test('J6 the HARNESS_SECRET bearer on GET /api/jobs: the full row, meta included', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedJob(o.db, 'job-bh9263-j6');
  const r = await call(o.DB, 'GET', '/api/jobs', { auth: `Bearer ${SECRET}` });
  assert.equal(r.status, 200, r.text);
  const row = r.body.jobs.find((j) => j.id === 'job-bh9263-j6');
  assert.ok('meta' in row && 'beat_note' in row, r.text);
});

test('J7 QA_READ_TOKEN unset, empty, or equal to HARNESS_SECRET: a non-operator bearer is 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [env, auth] of [
    [{ QA_READ_TOKEN: undefined }, `Bearer ${QA}`],
    [{ QA_READ_TOKEN: undefined }, 'Bearer '],
    [{ QA_READ_TOKEN: '' }, 'Bearer '],
    [{ QA_READ_TOKEN: '' }, null],
    [{ QA_READ_TOKEN: '  ' }, 'Bearer '],
    [{ QA_READ_TOKEN: SECRET }, `Bearer ${QA}`],
  ]) {
    const r = await call(o.DB, 'GET', '/api/jobs', { auth, env });
    assert.equal(r.status, 401, `${JSON.stringify(env)} ${auth}: ${r.text}`);
  }
});

test('J8 only the allowed query parameters reach the handler', async () => {
  let seen = null;
  const routes = [['GET', '/api/jobs', ({ url }) => { seen = url.search; return new Response(JSON.stringify({ jobs: [], as_of: T0, extra: 1 }), { status: 200 }); }]];
  const req = new Request('https://jobs.test/api/jobs?to=x&limit=1&since=2026-11-13T00:00:00Z&project=p', { headers: { authorization: `Bearer ${QA}` } });
  const url = new URL(req.url);
  const res = await qaReadDispatch({ req, env: { HARNESS_SECRET: SECRET, QA_READ_TOKEN: QA }, url, path: url.pathname, t: T0 }, routes);
  assert.equal(res.status, 200);
  const sp = new URLSearchParams(seen);
  assert.deepEqual([...sp.keys()].sort(), ['limit', 'project']);
  assert.equal(sp.get('limit'), '1');
  const body = await res.json();
  assert.equal('extra' in body, false);
  // A non-200 answer passes its status with {error} only.
  const bad = [['GET', '/api/jobs', () => new Response(JSON.stringify({ error: 'nope', detail: 'internal-fixture' }), { status: 503 })]];
  const r2 = await qaReadDispatch({ req, env: { HARNESS_SECRET: SECRET, QA_READ_TOKEN: QA }, url, path: url.pathname, t: T0 }, bad);
  assert.equal(r2.status, 503);
  assert.deepEqual(await r2.json(), { error: 'nope' });
});

test('J9 the policy copies are identical, and qa-read.js stays inside the worker tree', () => {
  const pages = readFileSync(new URL('../../../console-ui/functions/_lib/qa-read-policy.js', import.meta.url), 'utf8');
  const jobs = readFileSync(new URL('../src/lib/qa-read-policy.js', import.meta.url), 'utf8');
  assert.ok(pages.includes('export const QA_READ_ROUTES'), 'console-ui policy is missing');
  assert.equal(jobs, pages, 'worker/jobs/src/lib/qa-read-policy.js differs from console-ui/functions/_lib/qa-read-policy.js: edit both');
  const lib = readFileSync(new URL('../src/lib/qa-read.js', import.meta.url), 'utf8');
  const imports = [...lib.matchAll(/^import .* from "([^"]+)";/gm)].map((m) => m[1]);
  assert.deepEqual(imports.filter((p) => p.startsWith('../')), [], 'the worker deploy snapshot has no console-ui/');
  assert.ok(imports.includes('./qa-read-policy.js'));
});
