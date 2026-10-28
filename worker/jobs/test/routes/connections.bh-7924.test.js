import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';
import { matchRoute, matcherSignature } from '../../src/lib/router.js';
import { ROUTES } from '#routes';

// BH-7924 (T3) — the `connections` route family: GET /api/connections,
// PUT /api/connections and the box-side POST /api/connections/<p>/status.
//
// Driven through the real worker.fetch over the real schema in node:sqlite, so
// the route table, the bearer, body parsing and the SQL are what run. Each test
// opens its own in-memory database and seeds its own rows (no shared data, no
// order dependence). No vendor is called: the routes read D1 and env only.

const SECRET = 'test-secret';
const LINEAR_WH = 'whsec-fixture-linear-1';
const NOW_MS = Date.parse('2026-10-27T18:00:00Z');
const T0 = '2026-10-27T17:00:00Z';

async function open(t, extraEnv = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const opened = await openDb();
  if (!opened) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const env = { DB: opened.DB, HARNESS_SECRET: SECRET, LINEAR_WEBHOOK_SECRET: LINEAR_WH, ...extraEnv };
  return { db: opened.db, env };
}

async function call(env, method, path, body, { secret = SECRET } = {}) {
  const init = { method, headers: {} };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), env);
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: res.status, body: json, text };
}

const addProject = (db, project, prefix) => db.prepare(
  `INSERT INTO projects (project, repo, prod_url, board_api_prefix, cron_offset, box, tailnet_ip, note, created_at, updated_at)
   VALUES (?, ?, NULL, ?, 0, NULL, NULL, NULL, ?, ?)`).run(project, `example-org/${project}-os`, prefix, T0, T0);
const setRow = (db, key, value) => db.prepare(
  'INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, NULL, ?, ?)').run(key, value, 'seed-fixture', T0);
const rowOf = (db, key) => db.prepare('SELECT value, actor FROM settings WHERE key=?').get(key) || null;
const ourRows = (db) => Object.fromEntries(db.prepare(
  "SELECT key, value FROM settings WHERE key LIKE 'tracker_%' OR key LIKE 'webhook_route.%' OR key LIKE 'connection.%' ORDER BY key").all()
  .map((r) => [r.key, r.value]));
const audits = (db) => db.prepare("SELECT * FROM config_changes WHERE kind='connection' ORDER BY id").all();

// Four projects, one per adapter, plus the two edge rows of the adapter
// fallback (a junk row, a project only a tracker_adapter row names).
function seedFour(db) {
  addProject(db, 'lin', null);
  addProject(db, 'jir', null);
  addProject(db, 'brd', '/api/x');
  addProject(db, 'ghi', null);
  addProject(db, 'junk', null);
  setRow(db, 'tracker_adapter.lin', 'linear');
  setRow(db, 'tracker_linear.lin.team', 'CRO');
  setRow(db, 'tracker_linear.lin.label', 'ai-build');
  setRow(db, 'tracker_linear.lin.states', '{"review":"In Review"}');
  setRow(db, 'webhook_route.linear.cro', 'example-org/cromford-sandbox-linear');
  setRow(db, 'tracker_adapter.jir', 'jira');
  setRow(db, 'tracker_jira.jir.write_projects', 'SCRUM');
  setRow(db, 'tracker_jira.jir.read_projects', 'SCRUM OPS');
  setRow(db, 'tracker_jira.jir.comment_projects', 'SCRUM');
  setRow(db, 'tracker_jira.jir.label', 'ai-build');
  setRow(db, 'tracker_jira.jir.status_map', 'review=In Review;done=Done');
  setRow(db, 'tracker_adapter.junk', 'trello');
  setRow(db, 'tracker_adapter.onlyrow', 'linear');
  setRow(db, 'connection.lin.status', JSON.stringify({ adapter: 'linear', ok: true, checkedAt: T0, error: null,
    credentialVars: { LINEAR_API_KEY: 'present' }, webhookRoute: 'webhook_route.linear.cro', webhookSecret: 'present' }));
  setRow(db, 'connection.jir.status', 'not json');
}

const put = (env, body, o) => call(env, 'PUT', '/api/connections', body, o);
const get = (env, o) => call(env, 'GET', '/api/connections', undefined, o);
const postStatus = (env, p, body, o) => call(env, 'POST', `/api/connections/${p}/status`, body, o);

test('W1: GET lists every project with its adapter, source, parsed status and route; secrets as booleans only', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  // Count the D1 batches the GET makes: the plan is ONE batch of two reads.
  const batches = [];
  const rawBatch = h.env.DB.batch.bind(h.env.DB);
  h.env.DB.batch = (stmts) => { batches.push(stmts.length); return rawBatch(stmts); };
  const r = await get(h.env);
  assert.equal(r.status, 200);
  assert.deepEqual(batches, [2]);
  const by = Object.fromEntries(r.body.connections.map((c) => [c.project, c]));
  assert.deepEqual(Object.keys(by).sort(), ['brd', 'ghi', 'jir', 'junk', 'lin', 'onlyrow']);

  assert.equal(by.lin.adapter, 'linear');
  assert.equal(by.lin.adapterSource, 'row');
  assert.equal(by.lin.team, 'CRO');
  assert.equal(by.lin.label, 'ai-build');
  assert.equal(by.lin.states, '{"review":"In Review"}');
  assert.deepEqual(by.lin.webhookRoute, { key: 'webhook_route.linear.cro', repo: 'example-org/cromford-sandbox-linear' });
  assert.equal(by.lin.status.ok, true);
  assert.equal(by.lin.status.credentialVars.LINEAR_API_KEY, 'present');

  assert.equal(by.jir.adapter, 'jira');
  assert.equal(by.jir.adapterSource, 'row');
  assert.equal(by.jir.label, 'ai-build');
  assert.deepEqual(by.jir.jira, { write_projects: 'SCRUM', read_projects: 'SCRUM OPS', comment_projects: 'SCRUM',
    status_map: 'review=In Review;done=Done' });
  assert.equal(by.jir.webhookRoute, null);
  // An unparseable status row is null plus a reason, never a throw.
  assert.equal(by.jir.status, null);
  assert.equal(typeof by.jir.statusError, 'string');

  assert.equal(by.brd.adapter, 'board');
  assert.equal(by.brd.adapterSource, 'registry');
  assert.equal(by.ghi.adapter, 'github-issues');
  assert.equal(by.ghi.adapterSource, 'registry');
  assert.equal(by.ghi.status, null);
  assert.equal(by.junk.adapter, null);
  assert.match(by.junk.adapterError, /trello/);
  assert.equal(by.onlyrow.adapter, 'linear');

  assert.deepEqual(r.body.webhookSecrets, { linear: true, jira: false });
  assert.ok(!r.text.includes(LINEAR_WH), 'the webhook secret value never leaves the worker');
  assert.equal(typeof r.body.as_of, 'string');

  const noAuth = await get(h.env, { secret: null });
  assert.equal(noAuth.status, 401);
});

test('W2: PUT with a bad adapter or a bad field is 400 and writes nothing', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  const before = ourRows(h.db);
  const cases = [
    { project: 'lin', adapter: 'trello', reason: 'r' },
    { project: 'lin', team: 'cro', reason: 'r' },
    { project: 'lin', label: 'has space', reason: 'r' },
    { project: 'lin', label: 'ai-build\n', reason: 'r' },
    { project: 'lin', states: '[1,2]', reason: 'r' },
    { project: 'jir', write_projects: 'SCRUM s', reason: 'r' },
    { project: 'jir', status_map: 'Review=In Review', reason: 'r' },
    { project: 'lin', webhook_route: 'not a slug', reason: 'r' },
    { project: 'lin', write_projects: 'SCRUM', reason: 'r' }, // a jira field on a linear project
    { project: 'lin', label: 'ai-build' },                    // no reason
    { project: 'lin', label: 7, reason: 'r' },                // not a string
  ];
  for (const b of cases) {
    const r = await put(h.env, { ...b, actor: 'console:op@example.com' });
    assert.equal(r.status, 400, JSON.stringify(b));
    assert.equal(typeof r.body.error, 'string');
  }
  assert.deepEqual(ourRows(h.db), before);
  assert.equal(audits(h.db).length, 0);
});

test('W3: token-shaped values and secret keys are refused with env_var, never echoed; near misses pass', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  addProject(h.db, 'brd2', '/api/y');
  const before = ourRows(h.db);
  const refused = [
    [{ project: 'lin', label: 'sk-ant-api03-fixture-x' }, 'sk-ant-api03-fixture-x', 'LINEAR_API_KEY'],
    [{ project: 'lin', label: 'lin_api_AbCfixture123' }, 'lin_api_AbCfixture123', 'LINEAR_API_KEY'],
    [{ project: 'lin', team: 'lin_oauth_fixture9' }, 'lin_oauth_fixture9', 'LINEAR_API_KEY'],
    [{ project: 'jir', status_map: 'review=ATATT3xFfixture0' }, 'ATATT3xFfixture0', 'JIRA_API_TOKEN'],
    [{ project: 'jir', label: 'ghp_abcfixture' }, 'ghp_abcfixture', 'JIRA_API_TOKEN'],
    [{ project: 'lin', webhook_route: 'example-org/github_pat_11Afixture' }, 'github_pat_11Afixture', 'LINEAR_API_KEY'],
    [{ project: 'lin', label: 'gho_fixture1' }, 'gho_fixture1', 'LINEAR_API_KEY'],
    [{ project: 'lin', label: 'ghs_fixture1' }, 'ghs_fixture1', 'LINEAR_API_KEY'],
    [{ project: 'lin', api_key: 'tok-fixture-1' }, 'tok-fixture-1', 'LINEAR_API_KEY'],
    [{ project: 'jir', LINEAR_API_KEY: 'tok-fixture-2' }, 'tok-fixture-2', 'LINEAR_API_KEY'],
    [{ project: 'jir', token: 'tok-fixture-3' }, 'tok-fixture-3', 'JIRA_API_TOKEN'],
    [{ project: 'lin', adapter: 'jira', password: 'tok-fixture-4' }, 'tok-fixture-4', 'JIRA_API_TOKEN'],
    [{ project: 'lin', label: 'SK-1' }, 'SK-1', 'LINEAR_API_KEY'],
    [{ project: 'lin', label: 'ai-build', reason: 'pasted sk-fixture-in-reason' }, 'sk-fixture-in-reason', 'LINEAR_API_KEY'],
    [{ project: 'brd2', secret: 'tok-fixture-5' }, 'tok-fixture-5', 'INTERNAL_API_TOKEN'],
  ];
  for (const [b, value, envVar] of refused) {
    const r = await put(h.env, { reason: 'set up', actor: 'console:op@example.com', ...b });
    assert.equal(r.status, 400, JSON.stringify(b));
    assert.equal(r.body.env_var, envVar, JSON.stringify(b));
    assert.match(r.body.error, new RegExp(`^API keys are not stored here\\. Set ${envVar} in env/${b.project}\\.env on the box that runs ${b.project}\\.$`));
    assert.ok(!r.text.includes(value), `the value is echoed for ${JSON.stringify(b)}`);
  }
  assert.deepEqual(ourRows(h.db), before, 'a refused PUT writes no row');
  assert.equal(audits(h.db).length, 0);
  assert.ok(!JSON.stringify(h.db.prepare('SELECT * FROM config_changes').all()).includes('fixture'));

  const pass = [
    { project: 'lin', team: 'SK' },
    { project: 'lin', label: 'ai-build' },
    { project: 'lin', label: 'hotfix' },
    { project: 'lin', webhook_route: 'example-org/cromford-sandbox-linear' },
    { project: 'jir', write_projects: 'SKY' },
    { project: 'jir', status_map: 'review=In Review;done=Done' },
  ];
  for (const b of pass) {
    const r = await put(h.env, { reason: 'near miss', actor: 'console:op@example.com', ...b });
    assert.equal(r.status, 200, `${JSON.stringify(b)} -> ${r.text}`);
  }
  assert.equal(rowOf(h.db, 'tracker_linear.lin.team').value, 'SK');
  assert.equal(rowOf(h.db, 'tracker_jira.jir.write_projects').value, 'SKY');
});

test('W4: PUT on a project in no registry and no tracker row is 404 and writes nothing', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  const before = ourRows(h.db);
  const r = await put(h.env, { project: 'nope', adapter: 'linear', team: 'CRO', reason: 'r' });
  assert.equal(r.status, 404);
  assert.equal(r.body.error, 'unknown project');
  assert.deepEqual(ourRows(h.db), before);
  assert.equal(audits(h.db).length, 0);
  const s = await postStatus(h.env, 'nope', { adapter: 'linear', ok: true, checkedAt: T0, error: null, credentialVars: {} });
  assert.equal(s.status, 404);
  assert.equal(rowOf(h.db, 'connection.nope.status'), null);
});

test('W5: a good PUT writes exactly the tracker rows and one audit row; a repeat writes no audit row', async (t) => {
  const h = await open(t); if (!h) return;
  addProject(h.db, 'fresh', null);
  addProject(h.db, 'fjira', null);
  const actor = 'console:op@example.com';
  const body = { project: 'fresh', adapter: 'linear', team: 'CRO', label: 'ai-build', states: '{"review":"In Review"}',
    webhook_route: 'example-org/cromford-sandbox-linear', reason: 'connect linear', actor };
  const r = await put(h.env, body);
  assert.equal(r.status, 200, r.text);
  // TEST-CHANGE: BH-7924 review fix: the schema seeds the status knob row in
  // the connection.* range; the PUT leaves it at its seed value.
  assert.deepEqual(ourRows(h.db), {
    'connection.status_max_bytes': '2048',
    'tracker_adapter.fresh': 'linear',
    'tracker_linear.fresh.label': 'ai-build',
    'tracker_linear.fresh.states': '{"review":"In Review"}',
    'tracker_linear.fresh.team': 'CRO',
    'webhook_route.linear.cro': 'example-org/cromford-sandbox-linear',
  });
  assert.equal(rowOf(h.db, 'tracker_adapter.fresh').actor, actor);
  let a = audits(h.db);
  assert.equal(a.length, 1);
  assert.equal(a[0].name, 'fresh');
  assert.equal(a[0].actor, actor);
  assert.equal(a[0].reason, 'connect linear');
  assert.equal(JSON.parse(a[0].after_json).team, 'CRO');
  assert.equal(JSON.parse(a[0].before_json).team, null);
  assert.equal(r.body.connection.adapter, 'linear');
  assert.equal(r.body.connection.adapterSource, 'row');

  const again = await put(h.env, body);
  assert.equal(again.status, 200);
  assert.equal(audits(h.db).length, 1, 'an unchanged PUT is not a decision');

  // An omitted field leaves its row; an empty string deletes it.
  const del = await put(h.env, { project: 'fresh', label: '', reason: 'drop label', actor });
  assert.equal(del.status, 200, del.text);
  assert.equal(rowOf(h.db, 'tracker_linear.fresh.label'), null);
  assert.equal(rowOf(h.db, 'tracker_linear.fresh.team').value, 'CRO');
  a = audits(h.db);
  assert.equal(a.length, 2);
  assert.equal(JSON.parse(a[1].before_json).label, 'ai-build');
  assert.equal(JSON.parse(a[1].after_json).label, null);

  // Jira: the key lists normalise to single spaces; the route keys on the first write key.
  const j = await put(h.env, { project: 'fjira', adapter: 'jira', write_projects: ' SCRUM  OPS ', read_projects: 'SCRUM',
    comment_projects: 'SCRUM', label: 'ai-build', status_map: 'review=In Review;done=Done',
    webhook_route: 'example-org/cromford-sandbox-jira', reason: 'connect jira', actor });
  assert.equal(j.status, 200, j.text);
  assert.equal(rowOf(h.db, 'tracker_adapter.fjira').value, 'jira');
  assert.equal(rowOf(h.db, 'tracker_jira.fjira.write_projects').value, 'SCRUM OPS');
  assert.equal(rowOf(h.db, 'tracker_jira.fjira.read_projects').value, 'SCRUM');
  assert.equal(rowOf(h.db, 'tracker_jira.fjira.comment_projects').value, 'SCRUM');
  assert.equal(rowOf(h.db, 'tracker_jira.fjira.label').value, 'ai-build');
  assert.equal(rowOf(h.db, 'tracker_jira.fjira.status_map').value, 'review=In Review;done=Done');
  assert.equal(rowOf(h.db, 'webhook_route.jira.scrum').value, 'example-org/cromford-sandbox-jira');
  assert.equal(audits(h.db).length, 3);

  // adapter "" clears the row, and the GET falls back to the registry.
  const clr = await put(h.env, { project: 'fjira', adapter: '', reason: 'clear', actor });
  assert.equal(clr.status, 200, clr.text);
  assert.equal(rowOf(h.db, 'tracker_adapter.fjira'), null);
  assert.equal(clr.body.connection.adapter, 'github-issues');
  assert.equal(clr.body.connection.adapterSource, 'registry');
});

test('W6: a status POST round-trips through GET; tokens are 400, an oversize body 413, and no audit row is written', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  const sent = { adapter: 'linear', ok: false, checkedAt: '2026-10-27T17:59:00Z', error: 'linear: HTTP 401 from the API',
    credentialVars: { LINEAR_API_KEY: 'missing' }, box: 'small' };
  const r = await postStatus(h.env, 'lin', sent);
  assert.equal(r.status, 200, r.text);
  const stored = JSON.parse(rowOf(h.db, 'connection.lin.status').value);
  assert.equal(stored.ok, false);
  assert.equal(stored.webhookRoute, 'webhook_route.linear.cro');
  assert.equal(stored.webhookSecret, 'present');
  assert.equal(rowOf(h.db, 'connection.lin.status').actor, 'box:small');
  assert.equal(h.db.prepare('SELECT COUNT(*) AS n FROM config_changes').get().n, 0, 'a probe is an observation, not a decision');

  const g = await get(h.env);
  const lin = g.body.connections.find((c) => c.project === 'lin');
  for (const k of ['adapter', 'ok', 'checkedAt', 'error']) assert.equal(lin.status[k], sent[k], k);
  assert.deepEqual(lin.status.credentialVars, sent.credentialVars);
  assert.equal(lin.status.webhookRoute, 'webhook_route.linear.cro');
  assert.equal(lin.status.webhookSecret, 'present');

  // jira: no route row and no JIRA_WEBHOOK_SECRET.
  const jr = await postStatus(h.env, 'jir', { adapter: 'jira', ok: true, checkedAt: '2026-10-27T17:59:00Z', error: null,
    credentialVars: { JIRA_BASE: 'present', JIRA_EMAIL: 'present', JIRA_API_TOKEN: 'present' } });
  assert.equal(jr.status, 200, jr.text);
  const js = JSON.parse(rowOf(h.db, 'connection.jir.status').value);
  assert.equal(js.webhookRoute, null);
  assert.equal(js.webhookSecret, 'missing');

  const prev = rowOf(h.db, 'connection.lin.status').value;
  const tok = await postStatus(h.env, 'lin', { ...sent, error: 'linear: 401 for key lin_api_fixtureLeak9' });
  assert.equal(tok.status, 400);
  assert.equal(tok.body.env_var, 'LINEAR_API_KEY');
  assert.ok(!tok.text.includes('lin_api_fixtureLeak9'));
  const badVar = await postStatus(h.env, 'lin', { ...sent, credentialVars: { LINEAR_API_KEY: 'sk-fixture-val' } });
  assert.equal(badVar.status, 400);
  assert.ok(!badVar.text.includes('sk-fixture-val'));
  const badOk = await postStatus(h.env, 'lin', { ...sent, ok: 'yes' });
  assert.equal(badOk.status, 400);
  const big = await postStatus(h.env, 'lin', { ...sent, error: 'x'.repeat(2100) });
  assert.equal(big.status, 413);
  assert.equal(rowOf(h.db, 'connection.lin.status').value, prev, 'a refused POST leaves the row');

  const noAuth = await postStatus(h.env, 'lin', sent, { secret: null });
  assert.equal(noAuth.status, 401);
});

test('W7: the route-table fragment lists the three routes and each resolves to the connections family', async () => {
  const frag = readFileSync(new URL('../route-table.d/bh-7924-connections.txt', import.meta.url), 'utf8')
    .split('\n').filter((l) => l.trim() && !l.startsWith('#'));
  assert.equal(frag.length, 3);
  assert.deepEqual(frag.slice(0, 2), ['GET /api/connections', 'PUT /api/connections']);
  assert.match(frag[2], /^POST re:/);
  const sig = (hit) => `${hit.entry[0]} ${matcherSignature(hit.entry[1])}`;
  assert.equal(sig(matchRoute(ROUTES, 'GET', '/api/connections')), frag[0]);
  assert.equal(sig(matchRoute(ROUTES, 'PUT', '/api/connections')), frag[1]);
  assert.equal(sig(matchRoute(ROUTES, 'POST', '/api/connections/cromford-sbx-linear/status')), frag[2]);
  assert.equal(matchRoute(ROUTES, 'POST', '/api/connections'), null);
  assert.equal(matchRoute(ROUTES, 'POST', '/api/connections/../status'), null);
});

test('W8: EXPLAIN QUERY PLAN — the settings range read uses the settings key index on 2,000 seeded rows', async (t) => {
  const h = await open(t); if (!h) return;
  const { CONNECTION_SETTINGS_SQL } = await import('../../src/routes/connections.js');
  h.db.exec('BEGIN');
  const ins = h.db.prepare('INSERT OR IGNORE INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, NULL, ?, ?)');
  for (let i = 0; i < 2000; i++) {
    const fam = ['lane.x.knob_', 'tracker_linear.p', 'webhook_route.linear.t', 'connection.p', 'conf.misc.k'][i % 5];
    ins.run(`${fam}${i}`, String(i), 'seed-fixture', T0);
  }
  h.db.exec('COMMIT');
  h.db.exec('ANALYZE');
  const plan = h.db.prepare(`EXPLAIN QUERY PLAN ${CONNECTION_SETTINGS_SQL}`).all().map((r) => r.detail);
  assert.ok(plan.some((d) => /SEARCH settings USING (INDEX sqlite_autoindex_settings_1|PRIMARY KEY)/.test(d)), plan.join(' | '));
  assert.ok(!plan.some((d) => /^SCAN settings\b/.test(d)), `full scan: ${plan.join(' | ')}`);
  const rows = h.db.prepare(CONNECTION_SETTINGS_SQL).all();
  // TEST-CHANGE: BH-7924 review fix: 1200 -> 1201, the schema now seeds the
  // connection.status_max_bytes knob, which is in the connection.* range.
  assert.equal(rows.length, 1201, 'the range read returns exactly the three families plus the status knob row');
  assert.ok(rows.some((r) => r.key === 'connection.status_max_bytes'), 'the status knob row is in the range read');
});

test('W9: the status bound is the connection.status_max_bytes row; out of range falls back to 2048; a key over 64 chars is 400', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  const { CONNECTION_STATUS_MAX_BYTES } = await import('../../src/routes/connections.js');
  assert.equal(CONNECTION_STATUS_MAX_BYTES, 2048, 'the fallback is 2048');
  assert.equal(rowOf(h.db, 'connection.status_max_bytes')?.value, '2048', 'the schema seeds the knob row');
  const setKnob = (v) => h.db.prepare("UPDATE settings SET value=? WHERE key='connection.status_max_bytes'").run(v);
  const sent = { adapter: 'linear', ok: false, checkedAt: '2026-10-27T17:59:00Z', error: null,
    credentialVars: { LINEAR_API_KEY: 'present' } };
  const err3k = 'x'.repeat(3000);

  const seeded = await postStatus(h.env, 'lin', { ...sent, error: err3k });
  assert.equal(seeded.status, 413, seeded.text);
  assert.equal(seeded.body.max, 2048);

  setKnob('4096');
  const raised = await postStatus(h.env, 'lin', { ...sent, error: err3k });
  assert.equal(raised.status, 200, raised.text);
  assert.equal(JSON.parse(rowOf(h.db, 'connection.lin.status').value).error, err3k);
  const over = await postStatus(h.env, 'lin', { ...sent, error: 'x'.repeat(4200) });
  assert.equal(over.status, 413);
  assert.equal(over.body.max, 4096);

  for (const bad of ['junk', '1024', '99999', '-1', '']) {
    setKnob(bad);
    const r = await postStatus(h.env, 'lin', { ...sent, error: err3k });
    assert.equal(r.status, 413, `knob ${JSON.stringify(bad)}: ${r.text}`);
    assert.equal(r.body.max, 2048, `knob ${JSON.stringify(bad)} falls back to 2048`);
  }
  h.db.prepare("DELETE FROM settings WHERE key='connection.status_max_bytes'").run();
  const none = await postStatus(h.env, 'lin', { ...sent, error: err3k });
  assert.equal(none.body.max, 2048, 'no row falls back to 2048');

  // The worst status a probe can send fits the floor: a 1500-byte error, three
  // 64-char var names, the longest Jira route key.
  setKnob('2048');
  const v = (c) => `${c}${'A'.repeat(63)}`;
  const worst = await postStatus(h.env, 'jir', { adapter: 'github-issues', ok: false, checkedAt: '2026-10-27T17:59:00.123Z',
    error: 'x'.repeat(1500), credentialVars: { [v('A')]: 'missing', [v('B')]: 'missing', [v('C')]: 'missing' } });
  assert.equal(worst.status, 200, worst.text);

  const long = 'p'.repeat(50);
  addProject(h.db, long, null);
  const r = await postStatus(h.env, long, sent);
  assert.equal(r.status, 400, r.text);
  assert.match(r.body.error, /longer than 64 characters/);
  assert.equal(rowOf(h.db, `connection.${long}.status`), null);
});

test('W10: a project never reads or writes another project\'s webhook route row (read keys are not route keys)', async (t) => {
  const h = await open(t); if (!h) return;
  seedFour(h.db);
  // `ops` owns OPS (write key) and its route; `jir` only reads OPS.
  addProject(h.db, 'ops', null);
  setRow(h.db, 'tracker_adapter.ops', 'jira');
  setRow(h.db, 'tracker_jira.ops.write_projects', 'OPS');
  setRow(h.db, 'webhook_route.jira.ops', 'example-org/ops-os');
  const actor = 'console:op@example.com';

  // GET and the status POST attribute OPS's route to ops only.
  const g = await get(h.env);
  const by = Object.fromEntries(g.body.connections.map((c) => [c.project, c]));
  assert.equal(by.jir.webhookRoute, null);
  assert.deepEqual(by.ops.webhookRoute, { key: 'webhook_route.jira.ops', repo: 'example-org/ops-os' });
  const s = await postStatus(h.env, 'jir', { adapter: 'jira', ok: true, checkedAt: T0, error: null, credentialVars: {} });
  assert.equal(s.status, 200, s.text);
  assert.equal(s.body.status.webhookRoute, null);

  // A route delete on jir does not touch ops's row and writes no audit row.
  const del = await put(h.env, { project: 'jir', webhook_route: '', reason: 'drop route', actor });
  assert.equal(del.status, 200, del.text);
  assert.deepEqual(del.body.changed, []);
  assert.equal(rowOf(h.db, 'webhook_route.jira.ops').value, 'example-org/ops-os');
  assert.equal(audits(h.db).length, 0);

  // A route set on jir with no write key is 400; ops's row stays.
  const set = await put(h.env, { project: 'jir', write_projects: '', webhook_route: 'example-org/jir-os', reason: 'r', actor });
  assert.equal(set.status, 400, set.text);
  assert.equal(rowOf(h.db, 'webhook_route.jira.ops').value, 'example-org/ops-os');

  // Two projects that both write OPS: jir2 cannot repoint or delete ops's row
  // without route_override; with it, the change is explicit and audited.
  addProject(h.db, 'jir2', null);
  setRow(h.db, 'tracker_adapter.jir2', 'jira');
  setRow(h.db, 'tracker_jira.jir2.write_projects', 'OPS');
  const steal = await put(h.env, { project: 'jir2', webhook_route: 'example-org/jir2-os', reason: 'r', actor });
  assert.equal(steal.status, 409, steal.text);
  assert.equal(steal.body.key, 'webhook_route.jira.ops');
  const drop = await put(h.env, { project: 'jir2', webhook_route: '', reason: 'r', actor });
  assert.equal(drop.status, 409, drop.text);
  assert.equal(rowOf(h.db, 'webhook_route.jira.ops').value, 'example-org/ops-os');
  assert.equal(audits(h.db).length, 0);
  const ok = await put(h.env, { project: 'jir2', webhook_route: 'example-org/jir2-os', route_override: true, reason: 'move OPS', actor });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(rowOf(h.db, 'webhook_route.jira.ops').value, 'example-org/jir2-os');
  assert.equal(audits(h.db).length, 1);

  // ops's own repo route row is its own: no override needed to change it back.
  const back = await put(h.env, { project: 'ops', webhook_route: 'example-org/ops-os', route_override: true, reason: 'r', actor });
  assert.equal(back.status, 200, back.text);
  const own = await put(h.env, { project: 'ops', webhook_route: '', reason: 'drop own route', actor });
  assert.equal(own.status, 200, own.text);
  assert.equal(rowOf(h.db, 'webhook_route.jira.ops'), null);
});
