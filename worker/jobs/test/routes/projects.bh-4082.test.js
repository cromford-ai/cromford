// BH-4082 (BH-3979.8, slice C0): the `projects` registry and its audited
// PUT, the store the console's Projects form writes.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch (bearer, router and handler all under test):
//   P0  CREATED_TABLES.projects is schema.sql's CREATE verbatim, and a PUT on a
//       D1 without the table self-creates it;
//   P1  GET on an empty table is 200 {projects: []};
//   P2  a new row lands with exactly one config_changes row (kind project);
//   P3  every refused input is a 400 that writes nothing to either table;
//   P4  an identical re-PUT writes no audit row; a changed box writes one;
//   P5  the project key is lowercased once: project-3 updates project-3;
//   P6  '-' and blank prod_url/board_api_prefix store NULL, box 'local' is fine;
//   P7  a missing reason is a 400 at the worker, nothing written;
//   P8  there is no DELETE.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../../src/index.js';
import { CREATED_TABLES } from '../../src/lib/core.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from '../lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const norm = (s) => s.replace(/\s+/g, ' ').replace(/\( /g, '(').replace(/ \)/g, ')').trim();

const call = (DB, path, { method = 'PUT', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const put = (DB, body) => call(DB, '/api/projects', { body });
const projectRows = (db) => db.prepare('SELECT * FROM projects ORDER BY project').all();
const audits = (db) => db.prepare("SELECT * FROM config_changes WHERE kind='project' ORDER BY id").all();
const counts = (db) => ({
  projects: db.prepare('SELECT count(*) AS n FROM projects').get().n,
  changes: db.prepare('SELECT count(*) AS n FROM config_changes').get().n,
});

// project-3 as fleet.conf carries it today.
const project-3 = {
  project: 'project-3', repo: 'example-org/project-3', prod_url: 'https://os.project-3.example',
  board_api_prefix: '/api/feature-board', cron_offset: 6, box: 'box-project-3-2', tailnet_ip: '10.0.0.3',
  note: 'the project-3 board',
};
const FIELDS = ['repo', 'prod_url', 'board_api_prefix', 'cron_offset', 'box', 'tailnet_ip', 'note'];

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  await fn(opened);
}

test('P0 belt DDL == schema.sql, and a PUT self-creates the table', (t) => withDb(t, async ({ db, DB }) => {
  const stmts = CREATED_TABLES.projects;
  assert.ok(Array.isArray(stmts) && stmts.length === 1, 'one CREATE');
  const m = SCHEMA.match(/CREATE TABLE IF NOT EXISTS projects \([\s\S]*?\n\);/);
  assert.ok(m, 'schema.sql carries the projects CREATE');
  assert.equal(norm(stmts[0]), norm(m[0].replace(/;$/, '')));

  db.exec('DROP TABLE IF EXISTS projects');
  const res = await put(DB, { ...project-3, actor: 'a@x', reason: 'first' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(db.prepare('SELECT count(*) AS n FROM projects').get().n, 1);
}));

test('P1 GET on an empty table is 200 {projects: []}', (t) => withDb(t, async ({ DB }) => {
  const res = await call(DB, '/api/projects', { method: 'GET' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.projects, []);
  assert.equal(typeof res.body.as_of, 'string');
}));

test('P2 a new row lands with exactly one project audit row', (t) => withDb(t, async ({ db, DB }) => {
  const res = await put(DB, { ...project-3, actor: 'operator@example.com', reason: 'adding project-3' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.project.project, 'project-3');
  assert.equal(res.body.project.cron_offset, 6);
  const g = await call(DB, '/api/projects', { method: 'GET' });
  assert.deepEqual(g.body.projects.map((r) => [r.project, r.repo, r.box]),
    [['project-3', 'example-org/project-3', 'box-project-3-2']]);
  const a = audits(db);
  assert.equal(a.length, 1);
  assert.equal(a[0].name, 'project-3');
  assert.equal(a[0].before_json, null);
  const after = JSON.parse(a[0].after_json);
  assert.deepEqual(Object.keys(after), FIELDS);
  assert.deepEqual(after, {
    repo: 'example-org/project-3', prod_url: 'https://os.project-3.example', board_api_prefix: '/api/feature-board',
    cron_offset: 6, box: 'box-project-3-2', tailnet_ip: '10.0.0.3', note: 'the project-3 board',
  });
  assert.equal(a[0].actor, 'operator@example.com');
  assert.equal(a[0].reason, 'adding project-3');
}));

// Invariant (c): every one of these gates a value C1 writes into fleet.conf.
const REFUSED = [
  ['project', 'project-3 os'], ['project', '../etc'], ['project', 'a;b'], ['project', ''], ['project', 'a'.repeat(65)],
  ['project', undefined],
  ['repo', 'example-org'], ['repo', 'example-org/project-3 os'], ['repo', 'https://github.com/x/y'], ['repo', ''],
  ['prod_url', 'http://x'], ['prod_url', 'os.project-3.example'], ['prod_url', 'https://os.project-3.example/a b'],
  ['board_api_prefix', 'api/board'], ['board_api_prefix', '/api/ board'],
  ['cron_offset', ''], ['cron_offset', '3.5'], ['cron_offset', 3.5], ['cron_offset', 10], ['cron_offset', -1],
  ['cron_offset', '2x'], ['cron_offset', null], ['cron_offset', undefined], ['cron_offset', true],
  ['box', 'project-3 Box'], ['box', 'a;b'],
  ['tailnet_ip', '100.1.2'], ['tailnet_ip', '256.1.1.1'], ['tailnet_ip', 'host.ts.net'], ['tailnet_ip', '1.2.3.4.5'],
  ['repo', 'example-org/project-3\n'], ['box', 'project-3\nx'], ['prod_url', 'https://os.project-3.example\nx'],
  ['note', 'n'.repeat(513)],
];

test('P3 every refused input is a 400 that writes nothing', (t) => withDb(t, async ({ db, DB }) => {
  for (const [field, value] of REFUSED) {
    const body = { ...project-3, actor: 'a@x', reason: 'why' };
    if (value === undefined) delete body[field]; else body[field] = value;
    const res = await put(DB, body);
    assert.equal(res.status, 400, `${field}=${JSON.stringify(value)} answered ${res.status} ${JSON.stringify(res.body)}`);
    assert.equal(typeof res.body.error, 'string');
    assert.deepEqual(counts(db), { projects: 0, changes: 0 }, `${field}=${JSON.stringify(value)} wrote something`);
  }
}));

test('P3b a padded numeric cron_offset is trimmed, not refused', (t) => withDb(t, async ({ db, DB }) => {
  const res = await put(DB, { ...project-3, cron_offset: '2 ', reason: 'why' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(projectRows(db)[0].cron_offset, 2);
  for (const ok of [0, 9, '9']) {
    const r = await put(DB, { ...project-3, cron_offset: ok, reason: 'why' });
    assert.equal(r.status, 200, `cron_offset=${JSON.stringify(ok)}`);
  }
}));

test('P4 an identical re-PUT writes no audit row; a changed box writes one', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await put(DB, { ...project-3, actor: 'a@x', reason: 'one' })).status, 200);
  const created = projectRows(db)[0].created_at;
  const again = await put(DB, { ...project-3, actor: 'a@x', reason: 'two' });
  assert.equal(again.status, 200);
  assert.equal(audits(db).length, 1, 'an unchanged write is not a decision');
  assert.equal(projectRows(db).length, 1);
  const moved = await put(DB, { ...project-3, box: 'hub', actor: 'b@x', reason: 'moving it' });
  assert.equal(moved.status, 200);
  assert.equal(moved.body.project.box, 'hub');
  const a = audits(db);
  assert.equal(a.length, 2);
  assert.equal(a[1].before_json, a[0].after_json);
  const before = JSON.parse(a[1].before_json);
  const after = JSON.parse(a[1].after_json);
  assert.deepEqual(FIELDS.filter((f) => String(before[f]) !== String(after[f])), ['box']);
  assert.equal(after.box, 'hub');
  assert.equal(a[1].actor, 'b@x');
  assert.equal(projectRows(db)[0].created_at, created, 'created_at is set on insert only');
}));

test('P5 the project key is lowercased once: project-3 updates project-3', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await put(DB, { ...project-3, reason: 'one' })).status, 200);
  const res = await put(DB, { ...project-3, project: '  project-3 ', box: 'hub', reason: 'two' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.project.project, 'project-3');
  const r = projectRows(db);
  assert.deepEqual(r.map((x) => [x.project, x.box]), [['project-3', 'hub']]);
  assert.deepEqual(audits(db).map((x) => x.name), ['project-3', 'project-3']);
}));

test('P6 "-" and blank store NULL; box local and blank tailnet are fine', (t) => withDb(t, async ({ db, DB }) => {
  const res = await put(DB, {
    project: 'cromford', repo: 'example-org/cromford', prod_url: '-', board_api_prefix: '',
    cron_offset: 1, box: 'local', tailnet_ip: '', note: '', reason: 'the harness itself',
  });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const [row] = projectRows(db);
  assert.equal(row.prod_url, null);
  assert.equal(row.board_api_prefix, null);
  assert.equal(row.box, 'local');
  assert.equal(row.tailnet_ip, null);
  const r2 = await put(DB, { ...project-3, project: 'project-4', prod_url: '', board_api_prefix: '-', box: '', reason: 'x' });
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  const project-4 = projectRows(db).find((x) => x.project === 'project-4');
  assert.equal(project-4.prod_url, null);
  assert.equal(project-4.board_api_prefix, null);
  assert.equal(project-4.box, null);
}));

// Invariant (c)'s accepted half: every live fleet.conf row, read from the file.
test('P6b every current fleet.conf row is accepted as it stands', (t) => withDb(t, async ({ db, DB }) => {
  const conf = readFileSync(fileURLToPath(new URL('../../../../fleet.conf', import.meta.url)), 'utf8');
  const lines = conf.split('\n').filter((l) => l.trim() && !l.trim().startsWith('#'));
  assert.ok(lines.length >= 5, 'fleet.conf has rows');
  for (const l of lines) {
    const [project, repo, prodUrl, prefix, offset, box = '', ip = ''] = l.trim().split(/\s+/);
    const res = await put(DB, {
      project, repo, prod_url: prodUrl, board_api_prefix: prefix, cron_offset: offset, box, tailnet_ip: ip, reason: 'seed check',
    });
    assert.equal(res.status, 200, `${project}: ${JSON.stringify(res.body)}`);
  }
  assert.equal(projectRows(db).length, lines.length);
}));

test('P7 a missing or blank reason is a 400 at the worker, nothing written', (t) => withDb(t, async ({ db, DB }) => {
  for (const extra of [{}, { reason: '' }, { reason: '   ' }]) {
    const res = await put(DB, { ...project-3, ...extra });
    assert.equal(res.status, 400, JSON.stringify(extra));
    assert.match(res.body.error, /reason/);
  }
  assert.deepEqual(counts(db), { projects: 0, changes: 0 });
}));

test('P8 there is no DELETE /api/projects; the row stays', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await put(DB, { ...project-3, reason: 'one' })).status, 200);
  const res = await call(DB, '/api/projects', { method: 'DELETE', body: { project: 'project-3', reason: 'x' } });
  assert.ok([404, 405].includes(res.status), `DELETE answered ${res.status}`);
  assert.equal(projectRows(db).length, 1);
}));
