// BH-7972 (BH-7940.4): the marker lint, the version history routes (list,
// restore, drop head) and the prompt_versions retention rule.
//
// Driven through the REAL router (worker.fetch) on the node:sqlite D1 shim
// with the composed schema. Retention runs through POST /api/retention/run
// with a second in-memory D1 as the archive. Each case opens its own database
// and uses its own project slug (demo-7972-<case>). The clock is pinned (D60).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { missingMarkers } from '../src/lib/prompt-markers.js';
import { PROMPT_KINDS } from '../src/lib/prompt-store.js';
import CATALOG from '../../../catalog/prompt-markers.json' with { type: 'json' };

const SECRET = 'sec-fixture-7972';
const REPO = fileURLToPath(new URL('../../../', import.meta.url));
const NOW_MS = Date.parse('2026-10-27T12:00:00Z');
const DAY = 86400e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (days) => iso(NOW_MS - days * DAY);

const REVIEW_OK = 'TIER: 1\nVERDICT: APPROVE\n';
const PLAN_OK = '## Requirements coverage\n\n## ASSUMPTIONS\n';
const RULES_OK = CATALOG.rules.join('\n\n') + '\n';

const call = (env, path, { method = 'GET', body, auth = SECRET } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(auth === null ? {} : { authorization: `Bearer ${auth}` }), 'content-type': 'application/json' },
  body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
}), { HARNESS_SECRET: SECRET, ...env }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const q = (p) => (p === undefined ? '' : `project=${encodeURIComponent(p)}`);
const save = (env, scope, kind, project, body) => call(env, `/api/prompts/${scope}/${kind}?${q(project)}`, { method: 'POST', body });
const versions = (env, scope, kind, project) => call(env, `/api/prompts/${scope}/${kind}/versions?${q(project)}`);
const restore = (env, scope, kind, project, version, body = { author: 'zz-restorer' }) =>
  call(env, `/api/prompts/${scope}/${kind}/restore?${[q(project), `version=${version}`].filter(Boolean).join('&')}`, { method: 'POST', body });
const drop = (env, scope, kind, project) => call(env, `/api/prompts/${scope}/${kind}/head?${q(project)}`, { method: 'DELETE' });
const count = (db, table) => db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n;
const rowsOf = (db, project, kind) => db.prepare(
  'SELECT * FROM prompt_versions WHERE project = ? AND kind = ? ORDER BY version').all(project, kind).map((r) => ({ ...r }));
const headOf = (db, scope, project, kind) => db.prepare(
  'SELECT h.version_id, v.version FROM prompt_heads h JOIN prompt_versions v ON v.id = h.version_id WHERE h.scope = ? AND h.project = ? AND h.kind = ?')
  .get(scope, project, kind);
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', ago(0));
}

const pinned = new WeakSet();
async function open(t) {
  if (!pinned.has(t)) { t.mock.timers.enable({ apis: ['Date'], now: NOW_MS }); pinned.add(t); }
  const o = await openDb();
  if (o === null) { t.skip('node:sqlite unavailable in this runtime'); return null; }
  return o;
}
async function withArchive(t) {
  const o = await open(t);
  if (!o) return null;
  const { DatabaseSync } = await import('node:sqlite');
  const adb = new DatabaseSync(':memory:');
  return { ...o, adb, ARCHIVE: d1(adb) };
}

// seed(db, scope, project, kind, n, days, head) — versions 1..n, all `days` old,
// and the head on version `head` (default n; 0 = no head).
function seed(db, scope, project, kind, n, days, head = n) {
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO prompt_versions (scope,project,kind,version,body,author,note,created_at)
                          VALUES (?,?,?,?,?,?,?,?)`);
  for (let v = 1; v <= n; v++) ins.run(scope, project, kind, v, `body v${v}`, 'zz-author', '', ago(days));
  if (head > 0) {
    db.prepare(`INSERT INTO prompt_heads (scope,project,kind,version_id,set_by,set_at)
                SELECT scope, project, kind, id, 'zz-author', created_at FROM prompt_versions
                WHERE scope = ? AND project = ? AND kind = ? AND version = ?`).run(scope, project, kind, head);
  }
  db.exec('COMMIT');
}
const versionsLeft = (db, scope, project, kind) => db.prepare(
  'SELECT version FROM prompt_versions WHERE scope = ? AND project = ? AND kind = ? ORDER BY version').all(scope, project, kind).map((r) => r.version);
async function retention(env, body = {}) {
  const r = await call(env, '/api/retention/run', { method: 'POST', body });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const rule = (r.body.rules || []).find((x) => x.rule === 'prompt_versions.archive');
  assert.ok(rule, 'the prompt_versions.archive rule runs');
  return { run: r.body, rule };
}

// ------------------------------------------------------------- the marker lint

test('save-refuses-missing-verdict: a review body with TIER: and no VERDICT: is 422; no row', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await save(o, 'project', 'review', 'demo-7972-verdict', { body: 'TIER: 1', author: 'zz-a' });
  assert.equal(r.status, 422, JSON.stringify(r.body));
  assert.equal(r.body.error, 'missing_marker');
  assert.deepEqual(r.body.missing, ['VERDICT:']);
  assert.equal(count(o.db, 'prompt_versions'), 0);
  assert.equal(count(o.db, 'prompt_heads'), 0);
});

test('lint-negatives: near misses of every marker are refused', async (t) => {
  assert.deepEqual(CATALOG.review, ['TIER:', 'VERDICT:']);
  assert.deepEqual(CATALOG.plan, ['## Requirements coverage', '## ASSUMPTIONS']);
  const refuse = [
    ['review', 'TIER: 1\nverdict: approve', ['VERDICT:']],
    ['review', 'TIER: 1\nVERDICT approve', ['VERDICT:']],
    ['review', 'TIER : 1\nVERDICT: approve', ['TIER:']],
    ['review', 'nothing', ['TIER:', 'VERDICT:']],
    ['plan', '## Requirements\n## ASSUMPTIONS', ['## Requirements coverage']],
    ['plan', '## Requirements coverage\n## assumptions', ['## ASSUMPTIONS']],
    ['plan', '# Requirements coverage\n## ASSUMPTIONS', ['## Requirements coverage']],
  ];
  for (const [kind, body, want] of refuse) assert.deepEqual(missingMarkers(kind, body), want, `${kind}: ${JSON.stringify(body)}`);
  // A rules body that drops any one topic heading names exactly that heading.
  for (const m of CATALOG.rules) {
    const body = CATALOG.rules.filter((x) => x !== m).join('\n');
    assert.deepEqual(missingMarkers('rules', body), [m]);
  }
  // Through the route: a rules body missing one heading is 422 and writes nothing.
  const o = await open(t); if (!o) return;
  const drop1 = CATALOG.rules.slice(1).join('\n');
  const r = await save(o, 'fleet', 'rules', undefined, { body: drop1, author: 'zz-a' });
  assert.equal(r.status, 422, JSON.stringify(r.body));
  assert.deepEqual(r.body.missing, [CATALOG.rules[0]]);
  // An empty body is empty_body before the lint.
  const e = await save(o, 'project', 'review', 'demo-7972-neg', { body: ' ', author: 'zz-a' });
  assert.equal(e.status, 422);
  assert.equal(e.body.error, 'empty_body');
  assert.equal(count(o.db, 'prompt_versions'), 0);
});

test('lint-positives: file end, code fence, CRLF, other order, repeats pass; the four other kinds take any body', async (t) => {
  const pass = [
    ['review', 'x\nTIER: 1\nVERDICT: ok'],
    ['review', '```\nTIER: 1\nVERDICT: ok\n```\n'],
    ['review', 'TIER: 1\r\nVERDICT: ok\r\n'],
    ['review', 'VERDICT: ok\nTIER: 1'],
    ['review', 'TIER: 1\nTIER: 2\nVERDICT: a\nVERDICT: b'],
    ['plan', '## ASSUMPTIONS\r\n## Requirements coverage'],
    ['rules', CATALOG.rules.join('\r\n')],
    ['rules', [...CATALOG.rules].reverse().join('\n')],
    ['rules', '```\n' + CATALOG.rules.join('\n') + '\n```'],
  ];
  for (const [kind, body] of pass) assert.deepEqual(missingMarkers(kind, body), [], `${kind}: ${JSON.stringify(body)}`);
  for (const kind of ['watcher', 'execute', 'fix-round', 'qa']) {
    assert.deepEqual(CATALOG[kind], [], kind);
    assert.deepEqual(missingMarkers(kind, 'any body'), []);
  }
  assert.throws(() => missingMarkers('deploy', 'x'), /unknown prompt kind/);
  const o = await open(t); if (!o) return;
  const r = await save(o, 'project', 'review', 'demo-7972-pos', { body: 'intro\nVERDICT: ok\nTIER: 1', author: 'zz-a' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
});

test('rules-markers-match-topics: the rules list is the first ## line of each topic file, in order', () => {
  const dir = `${REPO}rules/topics/`;
  const want = [];
  for (const f of readdirSync(dir).filter((n) => /^\d{2}-.*\.md$/.test(n)).sort()) {
    const line = readFileSync(dir + f, 'utf8').split('\n').find((l) => l.startsWith('## '));
    if (line !== undefined) want.push(line.replace(/\r$/, ''));
  }
  assert.ok(want.length >= 16, `only ${want.length} topic headings`);
  assert.deepEqual(CATALOG.rules, want, 'a topic heading changed: edit catalog/prompt-markers.json in the same PR');
});

test('rules-markers-in-rules-claude-md: the rendered rules file holds every rules marker', () => {
  const rendered = readFileSync(`${REPO}rules/CLAUDE.md`, 'utf8');
  assert.ok(CATALOG.rules.length > 0);
  assert.deepEqual(missingMarkers('rules', rendered), []);
});

// ------------------------------------------------------------- the routes

test('versions-route-wins-over-version-matcher: GET …/versions is the list, not the contract 400', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await versions(o, 'project', 'plan', 'demo-7972-order');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(Array.isArray(r.body.versions));
  assert.equal(r.body.versions.length, 0);
  assert.equal(r.body.project, 'demo-7972-order');
  assert.equal(r.body.kind, 'plan');
  // The contract's version read still answers its own shapes.
  assert.equal((await call(o, '/api/prompts/project/plan/abc?project=demo-7972-order')).status, 400);
  assert.equal((await call(o, '/api/prompts/project/plan/1?project=demo-7972-order')).status, 404);
});

test('restore-v1-as-v3: v1 body as v3 with the note, head at v3, v1 and v2 unchanged, list 3, 2, 1', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-restore';
  const a = await save(o, 'project', 'review', p, { body: `${REVIEW_OK}first`, author: 'zz-a', note: 'one' });
  const b = await save(o, 'project', 'review', p, { body: `${REVIEW_OK}second`, author: 'zz-b', note: 'two' });
  assert.deepEqual([a.status, b.status], [201, 201]);
  const before = rowsOf(o.db, p, 'review');
  const r = await restore(o, 'project', 'review', p, 1);
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.version, 3);
  assert.equal(r.body.restored_from, 1);
  assert.ok(Number.isInteger(r.body.id));
  const after = rowsOf(o.db, p, 'review');
  assert.deepEqual(after.slice(0, 2), before, 'v1 and v2 are byte-equal');
  assert.equal(after[2].body, `${REVIEW_OK}first`);
  assert.equal(after[2].note, 'restored from v1');
  assert.equal(after[2].author, 'zz-restorer');
  assert.equal(after[2].id, r.body.id);
  assert.equal(headOf(o.db, 'project', p, 'review').version, 3);
  const l = await versions(o, 'project', 'review', p);
  assert.equal(l.status, 200);
  assert.deepEqual(l.body.versions.map((v) => v.version), [3, 2, 1]);
  assert.deepEqual(l.body.versions.map((v) => v.note), ['restored from v1', 'two', 'one']);
  assert.deepEqual(l.body.versions.map((v) => v.author), ['zz-restorer', 'zz-b', 'zz-a']);
  // The list resolves the kind to the new head.
  const heads = await call(o, `/api/prompts?project=${p}`);
  const row = heads.body.prompts.find((x) => x.kind === 'review');
  assert.deepEqual([row.source, row.version], ['project', 3]);
});

test('restore-archived-404: a version below MAX that is gone is archived; one above MAX is not_found', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-archived';
  for (const n of ['a', 'b', 'c']) assert.equal((await save(o, 'project', 'plan', p, { body: PLAN_OK + n, author: 'zz-a' })).status, 201);
  o.db.prepare("DELETE FROM prompt_versions WHERE project = ? AND kind = 'plan' AND version = 1").run(p);
  const n0 = count(o.db, 'prompt_versions');
  const r = await restore(o, 'project', 'plan', p, 1);
  assert.equal(r.status, 404, JSON.stringify(r.body));
  assert.equal(r.body.error, 'archived');
  const hi = await restore(o, 'project', 'plan', p, 4);
  assert.equal(hi.status, 404);
  assert.equal(hi.body.error, 'not_found');
  assert.equal(count(o.db, 'prompt_versions'), n0);
  assert.equal(headOf(o.db, 'project', p, 'plan').version, 3);
});

test('restore-unknown-404: a key with no versions is not_found; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await restore(o, 'project', 'qa', 'demo-7972-unknown', 1);
  assert.equal(r.status, 404, JSON.stringify(r.body));
  assert.equal(r.body.error, 'not_found');
  const f = await restore(o, 'fleet', 'qa', undefined, 2);
  assert.equal(f.status, 404);
  assert.equal(f.body.error, 'not_found');
  assert.equal(count(o.db, 'prompt_versions'), 0);
  assert.equal(count(o.db, 'prompt_heads'), 0);
});

test('restore-refused-by-lint: a v1 saved before its markers existed is 422; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-lint';
  seed(o.db, 'project', p, 'review', 1, 1);
  o.db.prepare("UPDATE prompt_versions SET body = 'TIER: 1 only' WHERE project = ?").run(p);
  const r = await restore(o, 'project', 'review', p, 1);
  assert.equal(r.status, 422, JSON.stringify(r.body));
  assert.equal(r.body.error, 'missing_marker');
  assert.deepEqual(r.body.missing, ['VERDICT:']);
  assert.equal(count(o.db, 'prompt_versions'), 1);
  assert.equal(headOf(o.db, 'project', p, 'review').version, 1);
});

test('restore-bad-version-400: bad version, no author, bad key; nothing written', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-bad';
  assert.equal((await save(o, 'project', 'qa', p, { body: 'q', author: 'zz-a' })).status, 201);
  const n0 = count(o.db, 'prompt_versions');
  const cases = [
    ['/api/prompts/project/qa/restore?project=demo-7972-bad', { author: 'zz-a' }],
    ['/api/prompts/project/qa/restore?project=demo-7972-bad&version=0', { author: 'zz-a' }],
    ['/api/prompts/project/qa/restore?project=demo-7972-bad&version=01', { author: 'zz-a' }],
    ['/api/prompts/project/qa/restore?project=demo-7972-bad&version=abc', { author: 'zz-a' }],
    ['/api/prompts/project/qa/restore?project=demo-7972-bad&version=1', {}],
    ['/api/prompts/project/qa/restore?project=demo-7972-bad&version=1', { author: '  ' }],
    ['/api/prompts/project/qa/restore?project=demo-7972-bad&version=1', 'not json'],
    ['/api/prompts/team/qa/restore?project=demo-7972-bad&version=1', { author: 'zz-a' }],
    ['/api/prompts/project/deploy/restore?project=demo-7972-bad&version=1', { author: 'zz-a' }],
    ['/api/prompts/project/qa/restore?project=..%2Fx&version=1', { author: 'zz-a' }],
    ['/api/prompts/fleet/qa/restore?project=demo-7972-bad&version=1', { author: 'zz-a' }],
  ];
  for (const [path, body] of cases) {
    const r = await call(o, path, { method: 'POST', body });
    assert.equal(r.status, 400, `${path} ${JSON.stringify(body)}: ${JSON.stringify(r.body)}`);
    assert.equal(typeof r.body.error, 'string');
  }
  for (const path of ['/api/prompts/team/qa/versions?project=x', '/api/prompts/project/qa/versions', '/api/prompts/team/qa/head?project=x']) {
    const r = await call(o, path, { method: path.endsWith('versions') || path.includes('versions?') ? 'GET' : 'DELETE' });
    assert.equal(r.status, 400, path);
  }
  assert.equal(count(o.db, 'prompt_versions'), n0);
  assert.equal(count(o.db, 'prompt_heads'), 1);
});

test('drop-head-keeps-versions: the head row goes, versions stay; a second drop is 0; the list falls back', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-drop';
  assert.equal((await save(o, 'fleet', 'watcher', undefined, { body: 'fleet w', author: 'zz-a' })).status, 201);
  for (const b of ['w1', 'w2']) assert.equal((await save(o, 'project', 'watcher', p, { body: b, author: 'zz-a' })).status, 201);
  const before = rowsOf(o.db, p, 'watcher');
  const r = await drop(o, 'project', 'watcher', p);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.dropped, 1);
  assert.equal(headOf(o.db, 'project', p, 'watcher'), undefined);
  assert.deepEqual(rowsOf(o.db, p, 'watcher'), before);
  const again = await drop(o, 'project', 'watcher', p);
  assert.equal(again.status, 200);
  assert.equal(again.body.dropped, 0);
  let row = (await call(o, `/api/prompts?project=${p}`)).body.prompts.find((x) => x.kind === 'watcher');
  assert.equal(row.source, 'fleet');
  // Drop the fleet head too: the repo file is next.
  assert.equal((await drop(o, 'fleet', 'watcher', undefined)).body.dropped, 1);
  row = (await call(o, `/api/prompts?project=${p}`)).body.prompts.find((x) => x.kind === 'watcher');
  assert.equal(row.source, 'repo');
  assert.equal(count(o.db, 'prompt_versions'), 3);
  // The versions list still shows the project's history.
  assert.deepEqual((await versions(o, 'project', 'watcher', p)).body.versions.map((v) => v.version), [2, 1]);
});

test('wrong-project-0-rows: B sees none of A, cannot restore A, and a drop on B leaves A', async (t) => {
  const o = await open(t); if (!o) return;
  const A = 'demo-7972-iso-a', B = 'demo-7972-iso-b';
  for (const b of ['a1', 'a2']) assert.equal((await save(o, 'project', 'qa', A, { body: b, author: 'zz-a' })).status, 201);
  assert.equal((await save(o, 'fleet', 'qa', undefined, { body: 'f1', author: 'zz-a' })).status, 201);
  const lb = await versions(o, 'project', 'qa', B);
  assert.equal(lb.status, 200);
  assert.deepEqual(lb.body.versions, []);
  // The fleet list holds only the fleet key's row.
  assert.deepEqual((await versions(o, 'fleet', 'qa', undefined)).body.versions.map((v) => v.version), [1]);
  const rb = await restore(o, 'project', 'qa', B, 1);
  assert.equal(rb.status, 404);
  assert.equal(rb.body.error, 'not_found');
  const db = await drop(o, 'project', 'qa', B);
  assert.equal(db.body.dropped, 0);
  assert.equal(headOf(o.db, 'project', A, 'qa').version, 2);
  assert.equal(headOf(o.db, 'fleet', '', 'qa').version, 1);
  assert.equal(rowsOf(o.db, B, 'qa').length, 0);
});

test('versions-no-body: the list carries id, version, author, note, created_at and no body', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-nobody';
  assert.equal((await save(o, 'project', 'execute', p, { body: 'secret-ish body text', author: 'zz-a', note: 'n' })).status, 201);
  const r = await versions(o, 'project', 'execute', p);
  assert.equal(r.status, 200);
  assert.equal(r.body.scope, 'project');
  const v = r.body.versions[0];
  assert.deepEqual(Object.keys(v).sort(), ['author', 'created_at', 'id', 'note', 'version']);
  assert.equal(v.created_at, iso(NOW_MS));
  assert.doesNotMatch(JSON.stringify(r.body), /secret-ish/);
});

test('versions-limit-knob: prompts.versions_list_max caps the list; a bad value is the 200 fallback', async (t) => {
  const o = await open(t); if (!o) return;
  const p = 'demo-7972-limit';
  seed(o.db, 'project', p, 'qa', 205, 1);
  let r = await versions(o, 'project', 'qa', p);
  assert.equal(r.body.limit, 200);
  assert.equal(r.body.versions.length, 200);
  assert.equal(r.body.versions[0].version, 205);
  assert.equal(r.body.versions[199].version, 6);
  // The settings snapshot is keyed on env.DB, so each value gets its own database.
  for (const [value, want] of [['3', 3], ['abc', 200], ['0', 200], ['1001', 200], ['1000', 205]]) {
    const o2 = await openDb();
    seed(o2.db, 'project', p, 'qa', 205, 1);
    setting(o2.db, 'prompts.versions_list_max', value);
    r = await versions(o2, 'project', 'qa', p);
    assert.equal(r.body.versions.length, want, `knob ${value}`);
    assert.deepEqual(r.body.versions.slice(0, 3).map((v) => v.version), [205, 204, 203]);
  }
});

test('no-bearer-401 and schema-not-applied-503 on the three routes', async (t) => {
  const o = await open(t); if (!o) return;
  for (const auth of [null, 'wrong-fixture']) {
    const s = [
      (await call(o, '/api/prompts/project/qa/versions?project=demo-7972-auth', { auth })).status,
      (await call(o, '/api/prompts/project/qa/restore?project=demo-7972-auth&version=1', { method: 'POST', auth, body: { author: 'x' } })).status,
      (await call(o, '/api/prompts/project/qa/head?project=demo-7972-auth', { method: 'DELETE', auth })).status,
    ];
    assert.deepEqual(s, [401, 401, 401]);
  }
  o.db.exec('DROP TABLE prompt_heads');
  o.db.exec('DROP TABLE prompt_versions');
  const r = await versions(o, 'project', 'qa', 'demo-7972-auth');
  assert.equal(r.status, 503, JSON.stringify(r.body));
  assert.equal((await drop(o, 'project', 'qa', 'demo-7972-auth')).status, 503);
});

test('statement-count: list 1 + settings, drop 1', async (t) => {
  const o = await open(t); if (!o) return;
  const inner = o.DB;
  let n = 0;
  const DB = { prepare: (s) => { n++; return inner.prepare(s); }, batch: (s) => inner.batch(s) };
  n = 0; await versions({ DB }, 'project', 'qa', 'demo-7972-count');
  assert.ok(n >= 1 && n <= 2, `list prepared ${n}`);
  n = 0; await drop({ DB }, 'project', 'qa', 'demo-7972-count');
  assert.equal(n, 1);
});

// ------------------------------------------------------------- retention

test('knob-defaults: the seeded rows', async (t) => {
  const o = await open(t); if (!o) return;
  const v = (k) => (o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(v('prompts.versions_list_max'), '200');
  assert.equal(v('retention.prompt_versions.days'), '30');
  assert.equal(v('prompts.retention.keep_versions'), '200');
  assert.equal(v('retention.dry_run'), '1');
});

test('retention-keeps-200: 250 old versions -> v1..v50 copied to the archive, then deleted; 200 kept', async (t) => {
  const s = await withArchive(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  const p = 'demo-7972-keep';
  seed(s.db, 'project', p, 'plan', 250, 40);
  const v7 = { ...s.db.prepare("SELECT * FROM prompt_versions WHERE project = ? AND version = 7").get(p) };
  const { rule, run } = await retention(s);
  assert.equal(rule.error, null, JSON.stringify(rule));
  assert.equal(rule.removed, 50);
  assert.equal(rule.backlog, false);
  const left = versionsLeft(s.db, 'project', p, 'plan');
  assert.equal(left.length, 200);
  assert.equal(left[0], 51);
  // archive-copy-then-delete: the archive holds every moved row with its body.
  assert.equal(s.adb.prepare('SELECT count(*) AS n FROM prompt_versions').get().n, 50);
  const a7 = s.adb.prepare('SELECT * FROM prompt_versions WHERE id = ?').get(v7.id);
  for (const k of Object.keys(v7)) assert.equal(a7[k], v7[k], k);
  assert.equal(a7.archived_at, iso(NOW_MS));
  // one-audit-row-per-run
  const audit = s.db.prepare("SELECT * FROM retention_runs WHERE rule = 'prompt_versions.archive'").all();
  assert.equal(audit.length, 1);
  assert.equal(audit[0].run_id, run.run_id);
  assert.equal(audit[0].removed, 50);
  assert.equal(audit[0].cutoff, ago(30));
  // A second run moves nothing more and writes one more audit row.
  const again = await retention(s);
  assert.equal(again.rule.removed, 0);
  assert.equal(s.db.prepare("SELECT count(*) AS n FROM retention_runs WHERE rule = 'prompt_versions.archive'").get().n, 2);
});

test('retention-keeps-head-even-if-old: a head on v1 keeps v1; v2..v50 go', async (t) => {
  const s = await withArchive(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  const p = 'demo-7972-head';
  seed(s.db, 'project', p, 'review', 250, 40, 1);
  const { rule } = await retention(s);
  assert.equal(rule.error, null);
  assert.equal(rule.removed, 49);
  const left = versionsLeft(s.db, 'project', p, 'review');
  assert.deepEqual(left.slice(0, 2), [1, 51]);
  assert.equal(left.length, 201);
  assert.equal(headOf(s.db, 'project', p, 'review').version, 1);
});

test('retention-per-key: rank counts within one (scope, project, kind)', async (t) => {
  const s = await withArchive(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  seed(s.db, 'fleet', '', 'review', 210, 40);
  seed(s.db, 'project', 'demo-7972-perkey-a', 'review', 150, 40);
  seed(s.db, 'project', 'demo-7972-perkey-b', 'review', 203, 40);
  seed(s.db, 'project', 'demo-7972-perkey-a', 'plan', 200, 40);
  const { rule } = await retention(s);
  assert.equal(rule.removed, 13);
  assert.equal(versionsLeft(s.db, 'fleet', '', 'review')[0], 11);
  assert.equal(versionsLeft(s.db, 'project', 'demo-7972-perkey-a', 'review').length, 150);
  assert.equal(versionsLeft(s.db, 'project', 'demo-7972-perkey-b', 'review')[0], 4);
  assert.equal(versionsLeft(s.db, 'project', 'demo-7972-perkey-a', 'plan').length, 200);
});

test('retention-keeps-young: rank 201 younger than retention.prompt_versions.days stays; days=0 is off', async (t) => {
  const s = await withArchive(t); if (!s) return;
  setting(s.db, 'retention.dry_run', '0');
  const p = 'demo-7972-young';
  seed(s.db, 'project', p, 'qa', 201, 1);
  // v1 is 29 days old in a second key: still inside the 30 day window.
  seed(s.db, 'project', `${p}-29`, 'qa', 201, 29);
  let { rule } = await retention(s);
  assert.equal(rule.removed, 0);
  assert.equal(count(s.db, 'prompt_versions'), 402);
  // keep_versions bad values fall back to 200, never to "archive all".
  for (const bad of ['0', '-1', 'abc', '2.5']) {
    const o = await withArchive(t);
    setting(o.db, 'retention.dry_run', '0');
    setting(o.db, 'prompts.retention.keep_versions', bad);
    seed(o.db, 'project', p, 'qa', 202, 40);
    ({ rule } = await retention(o));
    assert.equal(rule.removed, 2, `keep_versions=${bad}`);
  }
  // A good value is used.
  const k = await withArchive(t);
  setting(k.db, 'retention.dry_run', '0');
  setting(k.db, 'prompts.retention.keep_versions', '3');
  seed(k.db, 'project', p, 'qa', 10, 40);
  ({ rule } = await retention(k));
  assert.equal(rule.removed, 7);
  assert.deepEqual(versionsLeft(k.db, 'project', p, 'qa'), [8, 9, 10]);
  // retention.prompt_versions.days = 0 turns the rule off.
  const off = await withArchive(t);
  setting(off.db, 'retention.dry_run', '0');
  setting(off.db, 'retention.prompt_versions.days', '0');
  seed(off.db, 'project', p, 'qa', 250, 40);
  ({ rule } = await retention(off));
  assert.equal(rule.off, true);
  assert.equal(count(off.db, 'prompt_versions'), 250);
});

test('archive-unbound-moves-nothing: no archive -> 0 removed; the error shows only while rows wait', async (t) => {
  const o = await open(t); if (!o) return;
  setting(o.db, 'retention.dry_run', '0');
  let { rule } = await retention(o);
  assert.equal(rule.error, null, 'an empty table raises no error');
  const p = 'demo-7972-unbound';
  seed(o.db, 'project', p, 'plan', 250, 40);
  ({ rule } = await retention(o));
  assert.equal(rule.removed, 0);
  assert.equal(rule.error, 'archive not bound');
  assert.equal(rule.backlog, true);
  assert.equal(count(o.db, 'prompt_versions'), 250);
});

test('dry-run-counts-only: the seeded dry run counts 50 and removes nothing', async (t) => {
  const s = await withArchive(t); if (!s) return;
  const p = 'demo-7972-dry';
  seed(s.db, 'project', p, 'plan', 250, 40);
  const { rule, run } = await retention(s);
  assert.equal(run.dry_run, true);
  assert.equal(rule.counted, 50);
  assert.equal(rule.removed, 0);
  assert.equal(count(s.db, 'prompt_versions'), 250);
  const audit = s.db.prepare("SELECT * FROM retention_runs WHERE rule = 'prompt_versions.archive'").all();
  assert.equal(audit.length, 1);
  assert.equal(audit[0].dry_run, 1);
  assert.equal(audit[0].counted, 50);
});

test('kinds: every PROMPT_KIND is a catalog key', () => {
  assert.deepEqual(Object.keys(CATALOG).sort(), [...PROMPT_KINDS].sort());
});
