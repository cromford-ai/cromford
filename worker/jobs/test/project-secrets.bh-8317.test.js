// BH-8317 (MKF-2): the project secret NAME manifest (project_secret_names) and
// its three routes, driven through the REAL worker.fetch on node:sqlite with the
// composed jobs schema. Each case opens its own database and seeds its own rows,
// so no case depends on another or on order. No route here ever sees a value.
//   W-G1 list one project only (wrong tenant answers 0 rows), sorted, pending
//   W-P1 PUT validation: 400 names the field, never echoes the bad value
//   W-RT PUT then GET round-trip; stamp sets set_at, no stamp keeps it
//   W-A1 a changed PUT writes one config_changes row; an identical PUT none
//   W-D1 DELETE removes the row + one audit row (after_json 'null'); again 404
//   W-K1 the list limit knob (no row 500; row 3 cuts and says truncated)
//   W-R1 checkSecretName, the same R1 table as tests/project-secrets.bh-8317-test.sh
//   W-U1 no bearer is 401 on all three routes
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import * as MOD from '../src/routes/project-secrets.js';

const SECRET = 'tok-fixture-bh8317-main';
const NOW_MS = Date.parse('2026-10-25T23:00:00Z');
const NOW = '2026-10-25T23:00:00Z';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
function call(DB, method, path, { body, bearer = SECRET } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const init = { method, headers };
  if (method === 'PUT') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => {
      const text = await res.text();
      let json = null; try { json = JSON.parse(text); } catch { json = null; }
      return { status: res.status, headers: res.headers, text, body: json };
    });
}
const put = (DB, body) => call(DB, 'PUT', '/api/project-secrets/names', { body });
const list = (DB, p) => call(DB, 'GET', `/api/project-secrets/names?project=${encodeURIComponent(p)}`);
const del = (DB, p, n) => call(DB, 'DELETE', `/api/project-secrets/names?project=${encodeURIComponent(p)}&name=${encodeURIComponent(n)}&actor=fixture-op`);
const audits = (db) => db.prepare("SELECT kind, name, before_json, after_json, actor FROM config_changes WHERE kind='project_secret' ORDER BY id").all();
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-25T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
).run(key, String(value));
const row = (name, extra = {}) => ({ project: 'project-6-os', name, apps: ['pool-project-6-os'], set_by: 'fixture-op', ...extra });

// R1. The shell suite carries the same two lists (S-R1).
export const R1_ACCEPT = ['QA_CLERK_SECRET_KEY', '_X', 'FLYWHEEL_KEY', 'GH_TOKENS', 'GH_TOKEN_X', 'A'.repeat(128)];
export const R1_REFUSE = ['qa_clerk', '1ABC', 'HBUNDLE_P_X', 'SEED_A', 'FLY_API_TOKEN', 'GH_TOKEN', 'GH_TOKEN_INSTALLATION_ID', '', 'A-B', 'A'.repeat(129)];

test('W-R1 checkSecretName accepts and refuses the R1 table, and a refusal never echoes the name', () => {
  for (const n of R1_ACCEPT) assert.deepEqual(MOD.checkSecretName(n), { ok: true, value: n }, n);
  for (const n of R1_REFUSE) {
    const r = MOD.checkSecretName(n);
    assert.equal(r.ok, false, `refuse ${JSON.stringify(n)}`);
    if (n) assert.ok(!r.message.includes(n), `message echoes ${n}: ${r.message}`);
  }
  assert.equal(MOD.checkSecretName(42).ok, false);
});

test('W-G1 GET lists one project only, sorted by name, and counts pending rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [p, n, stamp] of [['p-one', 'ZED', true], ['p-one', 'ALPHA', false], ['p-one', 'MID', true], ['q-two', 'ALPHA', true], ['q-two', 'OTHER', true]]) {
    const r = await put(o.DB, { project: p, name: n, apps: ['pool-' + p], set_by: 'fixture-op', stamp });
    assert.equal(r.status, 200, r.text);
  }
  const g = await list(o.DB, 'p-one');
  assert.equal(g.status, 200, g.text);
  assert.equal(g.headers.get('cache-control'), 'no-store');
  assert.deepEqual(g.body.names.map((x) => x.name), ['ALPHA', 'MID', 'ZED']);
  assert.equal(g.body.project, 'p-one');
  assert.equal(g.body.pending, 1, 'ALPHA has no set_at');
  assert.equal(g.body.truncated, false);
  const wrong = await list(o.DB, 'r-three');
  assert.equal(wrong.status, 200);
  assert.deepEqual(wrong.body.names, [], 'a project with no rows answers 0 rows, never another project');
  assert.equal(wrong.body.pending, 0);
  assert.equal((await list(o.DB, 'Bad Project')).status, 400);
  assert.equal((await call(o.DB, 'GET', '/api/project-secrets/names')).status, 400);
});

test('W-P1 PUT refuses each bad field with 400 naming the field, never the value', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [
    [{ ...row('X'), project: 'BAD/PROJ' }, 'project', 'BAD/PROJ'],
    [{ ...row('X'), name: 'lower_case_x' }, 'name', 'lower_case_x'],
    [{ ...row('X'), name: 'HBUNDLE_P_SNEAKY' }, 'name', 'HBUNDLE_P_SNEAKY'],
    [{ ...row('X'), apps: [] }, 'apps', null],
    [{ ...row('X'), apps: 'pool-project-6-os' }, 'apps', null],
    [{ ...row('X'), apps: ['Bad_App!'] }, 'apps', 'Bad_App!'],
    [{ ...row('X'), need: 'sometimes' }, 'need', 'sometimes'],
    [{ ...row('X'), set_by: '' }, 'set_by', null],
    [{ ...row('X'), digest: 'not-an-object' }, 'digest', 'not-an-object'],
    [{ ...row('X'), value: 'fixture-leak-1' }, 'names only', 'fixture-leak-1'],
    [{ ...row('X'), secret: 'fixture-leak-2' }, 'names only', 'fixture-leak-2'],
  ];
  for (const [body, field, bad] of cases) {
    const r = await put(o.DB, body);
    assert.equal(r.status, 400, `${field}: ${r.text}`);
    assert.match(r.body.error, new RegExp(field), r.text);
    if (bad) assert.ok(!r.text.includes(bad), `the 400 echoes ${bad}: ${r.text}`);
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM project_secret_names').get().n, 0, 'no refused PUT writes a row');
  assert.equal(audits(o.db).length, 0, 'no refused PUT writes an audit row');
});

test('W-RT PUT then GET returns the same apps, need and digest; stamp sets set_at, a PUT without stamp keeps it', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r1 = await put(o.DB, row('QA_CLERK_SECRET_KEY', { apps: ['pool-project-6-os', 'lane-run-mk', 'pool-project-6-os'], need: 'optional' }));
  assert.equal(r1.status, 200, r1.text);
  assert.equal(r1.body.set_at, null, 'a new row without stamp is pending');
  let g = (await list(o.DB, 'project-6-os')).body.names[0];
  assert.deepEqual(g.apps, ['pool-project-6-os', 'lane-run-mk'], 'deduped, order kept');
  assert.equal(g.need, 'optional');
  assert.equal(g.set_at, null);
  const digest = { 'pool-project-6-os': 'dg-fixture-a', 'lane-run-mk': 'dg-fixture-b' };
  const r2 = await put(o.DB, row('QA_CLERK_SECRET_KEY', { apps: ['pool-project-6-os', 'lane-run-mk'], need: 'optional', digest, stamp: true }));
  assert.equal(r2.status, 200, r2.text);
  assert.equal(r2.body.set_at, NOW);
  g = (await list(o.DB, 'project-6-os')).body.names[0];
  assert.deepEqual(g.digest, digest);
  assert.equal(g.set_at, NOW);
  assert.equal(g.set_by, 'fixture-op');
  t.mock.timers.setTime(NOW_MS + 60_000);
  const r3 = await put(o.DB, row('QA_CLERK_SECRET_KEY', { apps: ['pool-project-6-os'], need: 'required' }));
  assert.equal(r3.status, 200, r3.text);
  g = (await list(o.DB, 'project-6-os')).body.names[0];
  assert.equal(g.set_at, NOW, 'a PUT without stamp keeps the old set_at');
  assert.deepEqual(g.apps, ['pool-project-6-os']);
  assert.equal(g.need, 'required');
  assert.deepEqual(g.digest, digest, 'a PUT without a digest keeps the old one');
});

test('W-A1 a PUT that changes the row writes one project_secret audit row; an identical PUT writes none', async (t) => {
  const o = await fresh(t); if (!o) return;
  await put(o.DB, row('BOARD_TOKEN'));
  let a = audits(o.db);
  assert.equal(a.length, 1, 'the create is audited');
  assert.equal(a[0].name, 'project-6-os/BOARD_TOKEN');
  assert.equal(a[0].before_json, null);
  assert.equal(a[0].actor, 'fixture-op');
  await put(o.DB, row('BOARD_TOKEN'));
  assert.equal(audits(o.db).length, 1, 'an identical PUT is not a change');
  await put(o.DB, row('BOARD_TOKEN', { apps: ['pool-project-6-os', 'lane-run-mk'] }));
  a = audits(o.db);
  assert.equal(a.length, 2);
  assert.deepEqual(JSON.parse(a[1].after_json).apps, '["pool-project-6-os","lane-run-mk"]');
  for (const x of a) assert.doesNotMatch(`${x.before_json}${x.after_json}`, /fixture-val/);
});

test('W-D1 DELETE removes the row and writes one audit row with after_json null; a second DELETE is 404 and writes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  await put(o.DB, row('BOARD_TOKEN', { stamp: true }));
  await put(o.DB, row('KEEP_ME'));
  const before = audits(o.db).length;
  const d = await del(o.DB, 'project-6-os', 'BOARD_TOKEN');
  assert.equal(d.status, 200, d.text);
  assert.equal(d.body.deleted, true);
  assert.deepEqual((await list(o.DB, 'project-6-os')).body.names.map((x) => x.name), ['KEEP_ME']);
  const a = audits(o.db);
  assert.equal(a.length, before + 1);
  assert.equal(a.at(-1).after_json, 'null');
  assert.equal(a.at(-1).name, 'project-6-os/BOARD_TOKEN');
  assert.equal(a.at(-1).actor, 'fixture-op');
  const again = await del(o.DB, 'project-6-os', 'BOARD_TOKEN');
  assert.equal(again.status, 404);
  assert.equal(audits(o.db).length, before + 1, 'a 404 writes nothing');
  assert.equal((await del(o.DB, 'project-6-os', 'bad-name')).status, 400);
});

test('W-K1 the list limit knob: no row answers 500; row 3 with 4 rows answers 3 and truncated', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const n of ['A1', 'A2', 'A3', 'A4']) await put(o.DB, row(n));
  let g = await list(o.DB, 'project-6-os');
  assert.equal(g.body.limit, 500);
  assert.equal(g.body.names.length, 4);
  assert.equal(g.body.truncated, false);
  setting(o.db, 'project_secrets.list_limit', 3);
  g = await list(o.DB, 'project-6-os');
  assert.equal(g.body.limit, 3);
  assert.deepEqual(g.body.names.map((x) => x.name), ['A1', 'A2', 'A3']);
  assert.equal(g.body.truncated, true);
  setting(o.db, 'project_secrets.list_limit', 'lots');
  assert.equal((await list(o.DB, 'project-6-os')).body.limit, 500, 'a bad row answers the fallback');
});

test('W-U1 no bearer is 401 on all three routes', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [m, p] of [['GET', '/api/project-secrets/names?project=x'], ['PUT', '/api/project-secrets/names'], ['DELETE', '/api/project-secrets/names?project=x&name=X']]) {
    const r = await call(o.DB, m, p, { bearer: null, body: row('X') });
    assert.equal(r.status, 401, `${m} ${p}`);
  }
});
