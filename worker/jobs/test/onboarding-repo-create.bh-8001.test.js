import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '../src/lib/router.js';
import { ROUTES } from '#routes';

// BH-8001 (BH-7935.4): New repo from a template, the worker half
// (src/routes/onboarding-repo-create.js). Driven through the REAL worker
// fetch on node:sqlite with the composed jobs schema. Each test opens its own
// in-memory DB. prepare() is wrapped so every statement is counted.
//   W1  no / blank / short Idempotency-Key -> 400, 0 statements
//   W2  the adversarial owner / name / template table -> 400, 0 statements, 0 rows
//   W3  one key twice, one body -> one probe_id, one row; the repeat runs 1 statement
//   W4  one key, another name -> 409 idempotency_key_reused, still one row
//   W5  two keys -> two rows, two ids
//   W6  GET by id: pending, claimed, pass, fail, rejected, unknown, not hex
//   W7  templates: booleans only, a non-slug value is false, no value leaks
//   W8  statement counts: new POST 3, repeat 1, GET 1
//   W9  EXPLAIN QUERY PLAN of the lookup at 5000 rows uses the unique index
//   W10 the fragment lists the three routes; the table resolves them here
const SECRET = 'tok-fixture-bh8001';
const sha16 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 16);
const KEY = 'key-fixture-0001';

async function world(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.sql = [];
  const inner = o.DB;
  o.DB = { ...inner, prepare: (sql) => { o.sql.push(sql); return inner.prepare(sql); } };
  return o;
}

async function call(o, method, path, { body, key, auth = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  if (key !== null && key !== undefined) headers['idempotency-key'] = key;
  const init = { method, headers };
  if (method !== 'GET') init.body = typeof body === 'string' ? body : JSON.stringify(body ?? {});
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB: o.DB, HARNESS_SECRET: SECRET });
  return { status: res.status, text: await res.clone().text(), body: await res.json().catch(() => null) };
}
const create = (o, body, key = KEY) => call(o, 'POST', '/api/onboarding/repo-create', { body, key });
const state = (o, id) => call(o, 'GET', `/api/onboarding/repo-create/${id}`);
const rows = (o) => o.db.prepare("SELECT * FROM hub_probe_requests WHERE probe='repo-create' ORDER BY id").all();
const GOOD = { owner: 'o', name: 'n', template: 'nextjs' };
const setSetting = (o, key, value) => o.db.prepare(
  "INSERT OR REPLACE INTO settings (key, value, actor, updated_at) VALUES (?, ?, 'test', '2026-11-02T00:00:00Z')").run(key, value);
// The hub's answer for one claimed row (POST /api/hub-probe/claim + result).
async function settle(o, result, output, http = 201) {
  const c = await call(o, 'POST', '/api/hub-probe/claim', { body: { claimed_by: 'hub', n: 5 } });
  const id = c.body.rows[0].id;
  if (result) await call(o, 'POST', '/api/hub-probe/result', { body: { id, result, http_status: http, output } });
  return id;
}

test('W1 the Idempotency-Key is required: 400 and 0 statements', async (t) => {
  const o = await world(t); if (!o) return;
  for (const key of [null, '', '   ', 'abcdefg', 'has space key', 'x'.repeat(129), 'bad/slash-key']) {
    o.sql = [];
    const r = await create(o, GOOD, key);
    assert.equal(r.status, 400, `key ${JSON.stringify(key)}`);
    assert.equal(r.body.error, 'idempotency_key_required');
    assert.equal(o.sql.length, 0, `key ${JSON.stringify(key)} ran a statement`);
  }
  assert.equal(rows(o).length, 0);
  assert.equal((await call(o, 'POST', '/api/onboarding/repo-create', { body: GOOD, key: KEY, auth: false })).status, 401);
});

test('W2 a bad owner, name or template is 400 with 0 statements and 0 rows', async (t) => {
  const o = await world(t); if (!o) return;
  const bad = [
    { owner: 'o', name: 'n x' }, { owner: 'o', name: '..' }, { owner: 'o', name: '.' }, { owner: 'o', name: 'x?y' },
    { owner: 'o', name: 'o/x' }, { owner: 'gitlab.com', name: 'x' }, { owner: 'https://a@github.com', name: 'x' },
    { owner: '', name: 'x' }, { owner: 'o'.repeat(40), name: 'x' }, { owner: 'o', name: 'n'.repeat(101) },
    { owner: 'o', name: 'name.git' }, { owner: 42, name: 'x' }, { owner: 'o', name: ['x'] }, { owner: ' o', name: 'x' },
    { owner: 'o', name: 'x ' }, { owner: 'example-org', name: 'new-app\n' }, { owner: 'o_x', name: 'x' },
    { name: 'x' }, { owner: 'o' },
  ];
  for (const b of bad) {
    o.sql = [];
    const r = await create(o, { template: 'nextjs', ...b });
    assert.equal(r.status, 400, JSON.stringify(b));
    assert.equal(o.sql.length, 0, `${JSON.stringify(b)} ran a statement`);
  }
  for (const template of ['rails', '', undefined, 'NEXTJS', 1, 'nextjs ']) {
    o.sql = [];
    const r = await create(o, { owner: 'o', name: 'n', template });
    assert.equal(r.status, 400, `template ${JSON.stringify(template)}`);
    assert.equal(o.sql.length, 0);
  }
  o.sql = [];
  assert.equal((await create(o, '[1,2]')).status, 400);
  assert.equal(o.sql.length, 0);
  assert.equal(rows(o).length, 0);
  // Near misses that ARE good: the gate is not refusing every dot or dash.
  for (const [owner, name] of [['example-org', 'new-app'], ['a-b', 'x.y_z']]) {
    const r = await create(o, { owner, name, template: 'worker' }, `key-good-${owner}`);
    assert.equal(r.status, 202, `${owner}/${name}: ${r.text}`);
  }
});

test('W3 one key twice with one body: one probe_id, one row; W8 statement counts', async (t) => {
  const o = await world(t); if (!o) return;
  o.sql = [];
  const a = await create(o, GOOD);
  assert.equal(a.status, 202, a.text);
  assert.equal(a.body.probe_id, sha16(KEY));
  assert.match(a.body.probe_id, /^[0-9a-f]{16}$/);
  assert.equal(o.sql.length, 3, `new POST ran ${o.sql.length}: ${o.sql.join(' | ')}`);
  o.sql = [];
  const b = await create(o, GOOD);
  assert.equal(b.status, 202);
  assert.equal(b.body.probe_id, a.body.probe_id);
  assert.equal(o.sql.length, 1, 'the repeat runs only the lookup');
  const r = rows(o);
  assert.equal(r.length, 1);
  assert.equal(r[0].project, 'onboarding');
  assert.equal(r[0].ticket_key, `onb-create-${sha16(KEY)}`);
  assert.equal(r[0].status, 'pending');
  assert.deepEqual(JSON.parse(r[0].args_json), ['o', 'n', 'nextjs']);
  o.sql = [];
  await state(o, a.body.probe_id);
  assert.equal(o.sql.length, 1, 'the GET runs one statement');
  // The key is trimmed before it is hashed.
  const c = await create(o, GOOD, `  ${KEY}  `);
  assert.equal(c.body.probe_id, a.body.probe_id);
  assert.equal(rows(o).length, 1);
});

test('W4 the same key with another body is 409 and files no second row', async (t) => {
  const o = await world(t); if (!o) return;
  await create(o, GOOD);
  for (const other of [{ ...GOOD, name: 'n2' }, { ...GOOD, owner: 'o2' }, { ...GOOD, template: 'empty' }]) {
    const r = await create(o, other);
    assert.equal(r.status, 409, JSON.stringify(other));
    assert.equal(r.body.error, 'idempotency_key_reused');
    assert.equal(r.body.probe_id, sha16(KEY));
  }
  assert.equal(rows(o).length, 1);
});

test('W5 two keys file two rows with two ids', async (t) => {
  const o = await world(t); if (!o) return;
  const a = await create(o, GOOD, 'key-fixture-a');
  const b = await create(o, GOOD, 'key-fixture-b');
  assert.notEqual(a.body.probe_id, b.body.probe_id);
  assert.equal(rows(o).length, 2);
});

test('W6 GET by id maps the row states', async (t) => {
  const o = await world(t); if (!o) return;
  const id = (await create(o, GOOD)).body.probe_id;
  let g = await state(o, id);
  assert.equal(g.status, 200);
  assert.equal(g.body.state, 'pending');
  assert.equal(g.body.slug, null);
  assert.equal(g.body.error, null);
  await settle(o, null);
  g = await state(o, id);
  assert.equal(g.body.state, 'pending', 'claimed is still pending');
  // A deferred row goes back to pending with a note; the note passes through.
  o.db.prepare("UPDATE hub_probe_requests SET status='pending', note='deferred: daily cap' WHERE probe='repo-create'").run();
  g = await state(o, id);
  assert.equal(g.body.state, 'pending');
  assert.equal(g.body.note, 'deferred: daily cap');
  o.db.prepare("UPDATE hub_probe_requests SET status='claimed', note=NULL WHERE probe='repo-create'").run();
  const rid = rows(o)[0].id;
  await call(o, 'POST', '/api/hub-probe/result', { body: { id: rid, result: 'pass', http_status: 201, output: '{"slug":"x/y","created":true}' } });
  g = await state(o, id);
  assert.equal(g.body.state, 'ok');
  assert.equal(g.body.slug, 'o/n', 'the slug is the filed args, never the probe output');
  assert.equal(g.body.error, null);

  const id2 = (await create(o, { ...GOOD, name: 'n2' }, 'key-fixture-fail')).body.probe_id;
  await settle(o, 'fail', 'name already exists: o/n2 was not made from T/tmpl', 422);
  g = await state(o, id2);
  assert.equal(g.body.state, 'error');
  assert.equal(g.body.slug, null);
  assert.equal(g.body.error, 'name already exists: o/n2 was not made from T/tmpl');

  const id3 = (await create(o, { ...GOOD, name: 'n3' }, 'key-fixture-long')).body.probe_id;
  await settle(o, 'fail', 'x'.repeat(500));
  assert.equal((await state(o, id3)).body.error.length, 200, 'the error is cut to 200 chars');

  const id4 = (await create(o, { ...GOOD, name: 'n4' }, 'key-fixture-rej')).body.probe_id;
  o.db.prepare("UPDATE hub_probe_requests SET status='rejected', output=NULL WHERE ticket_key=?").run(`onb-create-${id4}`);
  g = await state(o, id4);
  assert.equal(g.body.state, 'error');
  assert.ok(g.body.error && g.body.error.length > 0, 'a rejected row with no output still names an error');

  assert.equal((await state(o, 'f'.repeat(16))).status, 404);
  assert.equal((await state(o, 'XYZ')).status, 404, 'not 16 hex: no route');
  assert.equal((await state(o, 'a'.repeat(17))).status, 404);
  assert.equal((await call(o, 'GET', `/api/onboarding/repo-create/${id}`, { auth: false })).status, 401);
});

test('W7 templates answers booleans only and never a row value', async (t) => {
  const o = await world(t); if (!o) return;
  let r = await call(o, 'GET', '/api/onboarding/repo-create/templates');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.templates, { nextjs: false, worker: false, empty: false }, 'the empty seed is off');
  setSetting(o, 'onboarding.template.nextjs', 'example-org/tmpl-next');
  setSetting(o, 'onboarding.template.worker', 'x');
  setSetting(o, 'onboarding.template.empty', 'https://github.com/a/b');
  r = await call(o, 'GET', '/api/onboarding/repo-create/templates');
  assert.deepEqual(r.body.templates, { nextjs: true, worker: false, empty: false });
  assert.equal(r.text.includes('example-org'), false, 'no row value leaves the worker');
  for (const v of ['-', 'a/../b', 'a/.', 'a/b/c', 'a b/c', 'a/b ', `${'o'.repeat(40)}/r`, 'a_b/c', 'example-org/tmpl.git']) {
    setSetting(o, 'onboarding.template.worker', v);
    r = await call(o, 'GET', '/api/onboarding/repo-create/templates');
    assert.equal(r.body.templates.worker, false, `value ${JSON.stringify(v)}`);
  }
  setSetting(o, 'onboarding.template.worker', 'a-b/x.y_z');
  r = await call(o, 'GET', '/api/onboarding/repo-create/templates');
  assert.equal(r.body.templates.worker, true);
});

test('W9 the lookup is served by the unique index at 5000 rows', async (t) => {
  const o = await world(t); if (!o) return;
  const ins = o.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES (?,?,?,?,?,?)");
  for (let i = 0; i < 5000; i++) ins.run(i % 3 ? `p${i % 20}` : 'onboarding', `onb-create-${String(i).padStart(16, '0')}`, 'repo-create', '[]', `h${i}`, '2026-11-01T00:00:00Z');
  const { LOOKUP_SQL } = await import('../src/routes/onboarding-repo-create.js');
  const plan = o.db.prepare(`EXPLAIN QUERY PLAN ${LOOKUP_SQL}`).all('onboarding', 'onb-create-x', 'repo-create').map((r) => r.detail).join(' | ');
  assert.match(plan, /USING INDEX sqlite_autoindex_hub_probe_requests/);
  assert.doesNotMatch(plan, /SCAN hub_probe_requests/);
});

test('W10 the fragment lists the three routes and the table resolves them to this family', async () => {
  const frag = readFileSync(new URL('./route-table.d/bh-8001-onboarding-repo-create.txt', import.meta.url), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#'));
  assert.ok(frag.includes('POST /api/onboarding/repo-create'));
  assert.ok(frag.includes('GET /api/onboarding/repo-create/templates'));
  assert.ok(frag.some((l) => l.startsWith('GET re:') && l.includes('repo-create')));
  const mod = await import('../src/routes/onboarding-repo-create.js');
  const mine = new Set(mod.routes.map((r) => r[2]));
  for (const [m, p] of [['POST', '/api/onboarding/repo-create'], ['GET', '/api/onboarding/repo-create/templates'], ['GET', `/api/onboarding/repo-create/${'a'.repeat(16)}`]]) {
    const hit = matchRoute(ROUTES, m, p);
    assert.ok(hit && mine.has(hit.handler), `${m} ${p} resolves to onboarding-repo-create`);
  }
  // The neighbours still resolve to their own family.
  const repo = await import('../src/routes/onboarding-repo.js');
  assert.ok(new Set(repo.routes.map((r) => r[2])).has(matchRoute(ROUTES, 'GET', '/api/onboarding/repo').handler));
});
