// BH-7968 (BH-7937.4): POST /api/onboarding/tracker-test takes a secret
// envelope id, not the fields, and POST /api/onboarding/runs takes the
// optional run input ai_envelope. Driven through the REAL worker.fetch on
// node:sqlite with the composed jobs schema. Each case seeds its own DB and
// its own envelope ids.
//   W1-W3  an envelope with scope tracker:<kind>:p -> 202; the hub-probe row's
//          args are [kind, envelope_id]; no field value anywhere in the row
//   W4 no row -> 400   W5 expired row -> 400   W6 an ai-account row -> 400, kept
//   W7 other kind -> 400   W8 other project, and p vs px -> 400
//   W9 a body with fields and no envelope_id -> 400; ONBOARD_KV is never read
//   W10 bad ids (upper case, no dashes, empty, ../x) -> 400
//   W11 ai_envelope: stored when a UUID, 400 invalid_field when not, absent = unchanged
//   W12 the old KV take route is gone (404)
//   W13 the envelope check is one primary-key read
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh7968';
const FUTURE = '2099-01-01T00:00:00Z';
const PAST = '2001-01-01T00:00:00Z';
const CT = 'Q'.repeat(684); // base64-shaped fixture ciphertext; the worker never decrypts

let seq = 0;
const uuid = () => crypto.randomUUID();

async function world(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const kvCalls = [];
  const kv = new Proxy({}, { get: (_, k) => { kvCalls.push(String(k)); return () => { throw new Error('ONBOARD_KV used'); }; } });
  const env = { DB: o.DB, HARNESS_SECRET: SECRET, ONBOARD_KV: kv };
  return { ...o, env, kvCalls };
}
function seed(w, scope, { id = uuid(), expires = FUTURE } = {}) {
  seq += 1;
  w.db.prepare('INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?,?,?,?,?)')
    .run(id, scope, CT, '2026-10-27T00:00:00Z', expires);
  return id;
}
async function call(w, method, path, body, headers = {}) {
  const h = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}`, ...headers };
  const init = { method, headers: h };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), w.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const start = (w, body) => call(w, 'POST', '/api/onboarding/tracker-test', body);
const probes = (w) => w.db.prepare('SELECT * FROM hub_probe_requests').all();
const envelopes = (w, id) => w.db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes WHERE id = ?').get(id).n;

for (const kind of ['linear', 'jira', 'board']) {
  test(`W1-W3 ${kind}: an envelope with scope tracker:${kind}:newproj files one tracker-test row with args [kind, envelope_id]`, async (t) => {
    const w = await world(t); if (!w) return;
    const id = seed(w, `tracker:${kind}:newproj`);
    const r = await start(w, { project: 'newproj', kind, envelope_id: id });
    assert.equal(r.status, 202, JSON.stringify(r.body));
    assert.match(r.body.test_id, /^[0-9a-f]{32}$/);
    const rows = probes(w);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].probe, 'tracker-test');
    assert.equal(rows[0].project, 'newproj');
    assert.equal(rows[0].ticket_key, `onb-${r.body.test_id}`);
    assert.deepEqual(JSON.parse(rows[0].args_json), [kind, id]);
    assert.equal(JSON.stringify(rows[0]).includes(CT.slice(0, 40)), false, 'no ciphertext in the row');
    assert.equal(envelopes(w, id), 1, 'the worker check reads, it never deletes the envelope');
    assert.deepEqual(w.kvCalls, []);
    // The sheet's poll reads the row the POST filed.
    const g = await call(w, 'GET', `/api/onboarding/tracker-test/${r.body.test_id}?project=newproj`);
    assert.equal(g.body.state, 'pending');
  });
}

test('W4-W8 refused envelopes: 400 and no hub-probe row; the envelope is never deleted', async (t) => {
  const cases = [
    ['W4 no row', null, 'linear', 'newproj'],
    ['W5 expired', { scope: 'tracker:linear:newproj', expires: PAST }, 'linear', 'newproj'],
    ['W6 an ai-account envelope', { scope: 'ai-account:claude:a:project:newproj' }, 'linear', 'newproj'],
    ['W6 an ai-account pool envelope', { scope: 'ai-account:claude:a:pool' }, 'board', 'newproj'],
    ['W7 other kind', { scope: 'tracker:jira:newproj' }, 'linear', 'newproj'],
    ['W8 other project', { scope: 'tracker:linear:otherproj' }, 'linear', 'newproj'],
    ['W8 prefix near-miss (px)', { scope: 'tracker:linear:newprojx' }, 'linear', 'newproj'],
    ['W8 prefix near-miss (p)', { scope: 'tracker:linear:new' }, 'linear', 'newproj'],
  ];
  for (const [name, row, kind, project] of cases) {
    const w = await world(t); if (!w) return;
    const id = row ? seed(w, row.scope, { expires: row.expires || FUTURE }) : uuid();
    const r = await start(w, { project, kind, envelope_id: id });
    assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(probes(w).length, 0, `${name}: no hub-probe row`);
    if (row) assert.equal(envelopes(w, id), 1, `${name}: the envelope is kept`);
    assert.deepEqual(w.kvCalls, [], name);
  }
});

test('W9 the old body {fields} with no envelope_id is 400; ONBOARD_KV is never read', async (t) => {
  const w = await world(t); if (!w) return;
  const r = await start(w, { project: 'newproj', kind: 'linear', fields: { api_key: 'lin-api-fixture-1', team: 'CRO', label: 'ai-build' } });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /envelope_id/);
  assert.equal(probes(w).length, 0);
  assert.deepEqual(w.kvCalls, []);
});

test('W10 bad envelope ids, kinds and projects are 400', async (t) => {
  const w = await world(t); if (!w) return;
  const good = seed(w, 'tracker:linear:newproj');
  for (const id of [good.toUpperCase(), good.replace(/-/g, ''), '', '../x', 7, null]) {
    const r = await start(w, { project: 'newproj', kind: 'linear', envelope_id: id });
    assert.equal(r.status, 400, `id ${JSON.stringify(id)}`);
  }
  for (const kind of ['Linear', 'github-issues', '', undefined]) {
    assert.equal((await start(w, { project: 'newproj', kind, envelope_id: good })).status, 400, `kind ${kind}`);
  }
  assert.equal((await start(w, { project: 'bad project', kind: 'linear', envelope_id: good })).status, 400);
  assert.equal(probes(w).length, 0);
  assert.equal((await start(w, { project: 'newproj', kind: 'linear', envelope_id: good })).status, 202, 'the near-miss table did not burn the good id');
});

test('W0 the route sits behind the bearer', async (t) => {
  const w = await world(t); if (!w) return;
  const id = seed(w, 'tracker:linear:newproj');
  const r = await call(w, 'POST', '/api/onboarding/tracker-test', { project: 'newproj', kind: 'linear', envelope_id: id }, { authorization: 'Bearer tok-fixture-wrong' });
  assert.equal(r.status, 401);
  assert.equal(probes(w).length, 0);
});

test('W11 ai_envelope: a UUID is stored in inputs; a bad value is 400 invalid_field; absent leaves inputs unchanged', async (t) => {
  const w = await world(t); if (!w) return;
  const base = { repo: 'example-org/acme-os', project: 'acme-os', tracker: 'github-issues', box: 'shared' };
  const run = (body, key) => call(w, 'POST', '/api/onboarding/runs', body, { 'idempotency-key': key });
  const ai = uuid();
  const a = await run({ ...base, ai_envelope: ai }, `key-fixture-w11-a-${seq}`);
  assert.equal(a.status, 201, JSON.stringify(a.body));
  const g = await call(w, 'GET', `/api/onboarding/runs/${a.body.id}`);
  assert.equal(g.body.run.inputs.ai_envelope, ai);
  for (const bad of [ai.toUpperCase(), ai.replace(/-/g, ''), '../x', 'ob_1234']) {
    const r = await run({ ...base, ai_envelope: bad }, `key-fixture-w11-bad-${bad.length}-${seq++}`);
    assert.equal(r.status, 400, bad);
    assert.deepEqual([r.body.error, r.body.field], ['invalid_field', 'ai_envelope'], bad);
  }
  const b = await run(base, `key-fixture-w11-b-${seq}`);
  assert.equal(b.status, 201);
  const gb = await call(w, 'GET', `/api/onboarding/runs/${b.body.id}`);
  assert.deepEqual(gb.body.run.inputs, base);
  const json = w.db.prepare('SELECT inputs_json FROM onboarding_runs WHERE id = ?').get(b.body.id).inputs_json;
  assert.equal(json, JSON.stringify(Object.fromEntries(Object.keys(base).sort().map((k) => [k, base[k]]))));
});

test('W12 the KV take route is gone: POST /api/onboarding/tracker-secret/take is 404', async (t) => {
  const w = await world(t); if (!w) return;
  const r = await call(w, 'POST', '/api/onboarding/tracker-secret/take', { nonce: 'a'.repeat(32) });
  assert.equal(r.status, 404);
  assert.deepEqual(w.kvCalls, []);
});

test('W13 the envelope check is one primary-key lookup', async (t) => {
  const w = await world(t); if (!w) return;
  const { ENVELOPE_CHECK_SQL } = await import('../src/routes/onboarding-tracker.js');
  assert.equal(typeof ENVELOPE_CHECK_SQL, 'string');
  const plan = w.db.prepare(`EXPLAIN QUERY PLAN ${ENVELOPE_CHECK_SQL}`).all(uuid()).map((r) => r.detail).join(' | ');
  assert.match(plan, /USING INDEX sqlite_autoindex_secret_envelopes|USING PRIMARY KEY/);
  assert.doesNotMatch(plan, /SCAN secret_envelopes/);
});
