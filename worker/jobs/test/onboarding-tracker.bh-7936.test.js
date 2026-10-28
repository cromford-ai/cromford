// BH-7936: the onboarding tracker test routes (src/routes/onboarding-tracker.js).
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema.
// TEST-CHANGE (BH-7968): the credential no longer goes to a one-time KV row.
// The sheet stores it as a secret envelope, and the route takes the envelope
// id (test/onboarding-tracker-envelope.bh-7968.test.js pins that contract).
// The KV cases (F4 TTL, F5 put-before-D1, F7 no binding, F8 put throws, F11
// KV delete, W1 the take route) went with the KV path; the field checks of
// F6/F9 moved to the console (console-ui/tests/onboard-envelope.bh-7937.test.js
// T1) and to the hub probe (tests/hub-probe-tracker-envelope.bh-7968-test.sh F1).
//   F1-F3 each kind files one tracker-test hub-probe row and answers 202
//   F0 the route sits behind the bearer
//   F10/W2 GET maps pending/claimed/pass/fail and never returns a field value
//   E1 the GET lookup uses the unique index
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh7936';
const CT = 'Q'.repeat(684);

async function world(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return { ...o, env: { DB: o.DB, HARNESS_SECRET: SECRET } };
}

async function call(w, method, path, body, { auth = `Bearer ${SECRET}` } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), w.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
// One stored envelope with the scope the sheet writes; its id.
function envelope(w, kind, project = 'newproj') {
  const id = crypto.randomUUID();
  w.db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)')
    .run(id, `tracker:${kind}:${project}`, CT, '2026-10-27T00:00:00Z', '2099-01-01T00:00:00Z');
  return id;
}
const start = (w, kind, project = 'newproj') =>
  call(w, 'POST', '/api/onboarding/tracker-test', { project, kind, envelope_id: envelope(w, kind, project) });

for (const kind of ['linear', 'jira', 'board']) {
  test(`F1-F3 ${kind}: 202 with a 32-hex test_id and one tracker-test hub-probe row`, async (t) => {
    const w = await world(t); if (!w) return;
    const r = await start(w, kind);
    assert.equal(r.status, 202, JSON.stringify(r.body));
    assert.match(r.body.test_id, /^[0-9a-f]{32}$/);
    const rows = w.db.prepare('SELECT * FROM hub_probe_requests').all();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].probe, 'tracker-test');
    assert.equal(rows[0].project, 'newproj');
    assert.equal(rows[0].ticket_key, `onb-${r.body.test_id}`);
    assert.equal(rows[0].status, 'pending');
    assert.deepEqual(JSON.parse(rows[0].args_json)[0], kind);
    assert.match(JSON.parse(rows[0].args_json)[1], /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  });
}

test('F0 the route sits behind the bearer', async (t) => {
  const w = await world(t); if (!w) return;
  const id = envelope(w, 'linear');
  assert.equal((await call(w, 'POST', '/api/onboarding/tracker-test', { project: 'newproj', kind: 'linear', envelope_id: id }, { auth: null })).status, 401);
  assert.equal((await call(w, 'POST', '/api/onboarding/tracker-test', { project: 'newproj', kind: 'linear', envelope_id: id }, { auth: 'Bearer tok-fixture-wrong' })).status, 401);
  assert.equal(w.db.prepare('SELECT COUNT(*) AS n FROM hub_probe_requests').get().n, 0);
});

test('F10/W2 the GET answers pending, then ok or the error text, and never a field value', async (t) => {
  const w = await world(t); if (!w) return;
  const r = await start(w, 'jira');
  const id = r.body.test_id;
  const get = (p = 'newproj', i = id) => call(w, 'GET', `/api/onboarding/tracker-test/${i}?project=${p}`);
  let g = await get();
  assert.equal(g.status, 200);
  assert.equal(g.body.state, 'pending');
  const claim = await call(w, 'POST', '/api/hub-probe/claim', { claimed_by: 'hub', n: 5 });
  assert.equal(claim.body.rows.length, 1);
  g = await get();
  assert.equal(g.body.state, 'pending', 'claimed is still pending to the sheet');
  await call(w, 'POST', '/api/hub-probe/result', { id: claim.body.rows[0].id, result: 'fail', http_status: 401, output: 'FAIL list\njira: GET /rest/api/3/search/jql answered 401' });
  g = await get();
  assert.equal(g.body.state, 'error');
  assert.match(g.body.error, /answered 401/);
  assert.equal(JSON.stringify(g.body).includes(CT.slice(0, 40)), false, 'the GET never returns the envelope');

  const r2 = await start(w, 'linear');
  const c2 = await call(w, 'POST', '/api/hub-probe/claim', { claimed_by: 'hub', n: 5 });
  await call(w, 'POST', '/api/hub-probe/result', { id: c2.body.rows[0].id, result: 'pass', http_status: 200, output: 'ok list=2 dry-write=ok' });
  const g2 = await get('newproj', r2.body.test_id);
  assert.equal(g2.body.state, 'ok');
  assert.equal(g2.body.detail, 'ok list=2 dry-write=ok');

  assert.equal((await get('otherproj')).status, 404, 'the wrong project finds nothing');
  assert.equal((await get('newproj', 'b'.repeat(32))).status, 404);
  assert.equal((await get('newproj', 'nothex')).status, 404, 'a non-hex id does not match the route');
  assert.equal((await call(w, 'GET', `/api/onboarding/tracker-test/${id}`)).status, 400, 'project is required');
});

test('E1 the GET lookup is served by the unique (project, ticket_key, probe, args_hash) index', async (t) => {
  const w = await world(t); if (!w) return;
  const ins = w.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES (?,?,?,?,?,?)");
  for (let i = 0; i < 3000; i++) ins.run(`p${i % 20}`, `BH-${i}`, 'd1-count', '[]', `h${i}`, '2026-10-20T00:00:00Z');
  const { TEST_LOOKUP_SQL } = await import('../src/routes/onboarding-tracker.js');
  const plan = w.db.prepare(`EXPLAIN QUERY PLAN ${TEST_LOOKUP_SQL}`).all('p1', 'onb-x', 'tracker-test').map((r) => r.detail).join(' | ');
  assert.match(plan, /USING INDEX sqlite_autoindex_hub_probe_requests/);
  assert.doesNotMatch(plan, /SCAN hub_probe_requests/);
});
