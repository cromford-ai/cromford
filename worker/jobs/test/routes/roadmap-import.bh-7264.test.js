import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-7264 (BH-7243.1): POST /api/roadmap/import, the bulk import of a roadmap
// file into roadmap_ideas, roadmap_links and roadmap_decisions.
//
// Every case drives the REAL worker.fetch and route table (D2) over the
// composed jobs schema in node:sqlite. The d1 shim refuses a statement with
// more than 100 binds, like D1. Deleting
// test/route-table.d/bh-7243-roadmap-import.txt turns each route case into
// the router's 404. The clock is pinned (D60).
//
// L1 a mixed body answers the counts; a re-post inserts 0 and skips all
// L2 501 rows is 400 and writes nothing; 0 rows is 400; 500 rows is 200
//    (the statements are cut under the 100-bind cap)
// L3 issue and pull links make link rows with repo and issue parsed; a blob
//    URL, an http:// URL and no link make none; decisions get deterministic ids
// L4 shipped is closed_completed, never closed_other; the lane map; one
//    imported event per new idea; an unknown project is 400 with 0 rows; a bad
//    row field is 400 that names ideas[i].<field> or decisions[i].<field>
// L5 linkInsertSql(n) is the exact text the route runs; no bearer is 401

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-19T12:00:00Z');
const NOW = '2026-10-19T12:00:00Z';
const PATH = '/api/roadmap/import';

const M = await import('../../src/routes/roadmap-import.js').catch(() => null);

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb(hooks);
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  for (const p of ['cromford', 'proj-b']) {
    o.db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?, ?, 0, ?, ?)`)
      .run(p, `o/${p}`, NOW, NOW);
  }
  return o;
}

async function post(DB, body, { secret = SECRET } = {}) {
  const init = { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  const res = await worker.fetch(new Request(`https://jobs.test${PATH}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const n = (db, sql, ...b) => Number(db.prepare(sql).get(...b).n);
const counts = (db) => ({
  ideas: n(db, 'SELECT COUNT(*) AS n FROM roadmap_ideas'),
  events: n(db, 'SELECT COUNT(*) AS n FROM roadmap_idea_events'),
  links: n(db, 'SELECT COUNT(*) AS n FROM roadmap_links'),
  decisions: n(db, 'SELECT COUNT(*) AS n FROM roadmap_decisions'),
});
const ZERO = { ideas: 0, events: 0, links: 0, decisions: 0 };
const decisionId = (project, kind, ref) =>
  'imp-' + createHash('sha256').update(`${project}\n${kind}\n${ref}`).digest('hex').slice(0, 32);

const GH = 'https://github.com/o/r';
const IDEAS = [
  { section: 'now', title: 'Now item', note: 'Note now', link: `${GH}/issues/12`, source_ref: `${GH}/issues/12` },
  { section: 'next', title: 'Next item', link: `${GH}/pull/13`, source_ref: `${GH}/pull/13` },
  { section: 'next', title: 'Next item with no link', source_ref: 'sha256:aa01' },
  { section: 'later', title: 'Later item', link: `${GH}/issues/14#issuecomment-1`, source_ref: `${GH}/issues/14#issuecomment-1` },
  { section: 'later', title: 'Later blob', link: `${GH}/blob/main/x.md`, source_ref: `${GH}/blob/main/x.md` },
  { section: 'later', title: 'Later http', link: 'http://github.com/o/r/issues/15', source_ref: 'http://github.com/o/r/issues/15' },
  { section: 'shipped', title: 'Shipped PR', link: `${GH}/pull/16`, source_ref: `${GH}/pull/16` },
];
const DECISIONS = [
  { kind: 'log', title: 'Reuse the connectors.', body: 'Source: PR #1001', status: 'decided', decided_at: '2026-10-17', ref: 'ref-log-1' },
  { kind: 'open', title: 'Agent library layout', body: 'Grid or table? Where: #1024', status: 'open', ref: 'ref-open-1' },
];
const BODY = { project: 'cromford', actor: 'operator:fixture', ideas: IDEAS, decisions: DECISIONS };

test('L1 a mixed body answers the counts, and a re-post inserts 0', async (t) => {
  const o = await open(t); if (!o) return;
  const a = await post(o.DB, BODY);
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.deepEqual(a.body, {
    project: 'cromford',
    inserted: { ideas: 7, links: 4, decisions: 2 },
    skipped: { ideas: 0, decisions: 0 },
    as_of: NOW,
  });
  assert.deepEqual(counts(o.db), { ideas: 7, events: 7, links: 4, decisions: 2 });
  const row = o.db.prepare(`SELECT * FROM roadmap_ideas WHERE source_ref = ?`).get(`${GH}/issues/12`);
  assert.equal(row.source, 'import');
  assert.equal(row.title, 'Now item');
  assert.equal(row.note, 'Note now');
  assert.equal(row.link, `${GH}/issues/12`);
  assert.equal(row.version, 1);
  assert.equal(row.created_by, 'operator:fixture');
  assert.equal(row.created_at, NOW);
  assert.equal(row.updated_at, NOW);
  assert.equal(row.project, 'cromford');

  const b = await post(o.DB, BODY);
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.deepEqual(b.body.inserted, { ideas: 0, links: 0, decisions: 0 });
  assert.deepEqual(b.body.skipped, { ideas: 7, decisions: 2 });
  assert.deepEqual(counts(o.db), { ideas: 7, events: 7, links: 4, decisions: 2 });

  // The same rows into another project are new rows there.
  const c = await post(o.DB, { ...BODY, project: 'proj-b' });
  assert.deepEqual(c.body.inserted, { ideas: 7, links: 4, decisions: 2 });
  assert.equal(n(o.db, `SELECT COUNT(*) AS n FROM roadmap_links WHERE project = 'proj-b'`), 4);
});

const many = (k, section = 'later', withLink = false) => Array.from({ length: k }, (_, i) => ({
  section, title: `Row ${i}`, source_ref: withLink ? `${GH}/issues/${1000 + i}` : `sha256:r${i}`,
  ...(withLink ? { link: `${GH}/issues/${1000 + i}` } : {}),
}));

test('L2 501 rows is 400 and writes nothing; 0 rows is 400; 500 rows fits under the bind cap', async (t) => {
  const o = await open(t); if (!o) return;
  const big = await post(o.DB, { ...BODY, ideas: many(500), decisions: [DECISIONS[0]] });
  assert.equal(big.status, 400, JSON.stringify(big.body));
  assert.equal(big.body.field, 'ideas');
  assert.match(big.body.error, /500/);
  assert.deepEqual(counts(o.db), ZERO);

  const none = await post(o.DB, { ...BODY, ideas: [], decisions: [] });
  assert.equal(none.status, 400);
  assert.deepEqual(counts(o.db), ZERO);

  const notArray = await post(o.DB, { ...BODY, ideas: 'x' });
  assert.equal(notArray.status, 400);
  assert.equal(notArray.body.field, 'ideas');

  // 400 ideas with links + 100 decisions: every statement must stay under
  // 100 binds, or the shim throws like D1 does.
  const dec = Array.from({ length: 100 }, (_, i) => ({ kind: 'log', title: `D${i}`, status: 'decided', ref: `d${i}` }));
  const ok = await post(o.DB, { ...BODY, ideas: many(400, 'shipped', true), decisions: dec });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(ok.body.inserted, { ideas: 400, links: 400, decisions: 100 });
  assert.deepEqual(counts(o.db), { ideas: 400, events: 400, links: 400, decisions: 100 });
});

test('L3 links: issue and pull parse to repo and issue; blob, http:// and no link make no row; decision ids are deterministic', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await post(o.DB, BODY);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const links = o.db.prepare(`SELECT i.title, l.repo, l.issue, l.project, l.created_by, l.created_at
    FROM roadmap_links l JOIN roadmap_ideas i ON i.id = l.idea_id ORDER BY l.issue`).all().map((x) => ({ ...x }));
  assert.deepEqual(links, [
    { title: 'Now item', repo: 'o/r', issue: 12, project: 'cromford', created_by: 'operator:fixture', created_at: NOW },
    { title: 'Next item', repo: 'o/r', issue: 13, project: 'cromford', created_by: 'operator:fixture', created_at: NOW },
    { title: 'Later item', repo: 'o/r', issue: 14, project: 'cromford', created_by: 'operator:fixture', created_at: NOW },
    { title: 'Shipped PR', repo: 'o/r', issue: 16, project: 'cromford', created_by: 'operator:fixture', created_at: NOW },
  ]);
  for (const title of ['Later blob', 'Later http', 'Next item with no link']) {
    assert.equal(n(o.db, `SELECT COUNT(*) AS n FROM roadmap_links l JOIN roadmap_ideas i ON i.id = l.idea_id WHERE i.title = ?`, title), 0, title);
  }
  const dec = o.db.prepare(`SELECT * FROM roadmap_decisions ORDER BY kind`).all().map((x) => ({ ...x }));
  assert.deepEqual(dec[0], {
    id: decisionId('cromford', 'log', 'ref-log-1'), project: 'cromford', kind: 'log',
    title: 'Reuse the connectors.', body: 'Source: PR #1001', status: 'decided', created_by: 'operator:fixture',
    decided_by: null, created_at: NOW, updated_at: NOW, decided_at: '2026-10-17',
  });
  assert.deepEqual(dec[1], {
    id: decisionId('cromford', 'open', 'ref-open-1'), project: 'cromford', kind: 'open',
    title: 'Agent library layout', body: 'Grid or table? Where: #1024', status: 'open', created_by: 'operator:fixture',
    decided_by: null, created_at: NOW, updated_at: NOW, decided_at: null,
  });
  assert.match(dec[0].id, /^imp-[0-9a-f]{32}$/);
});

test('L4 shipped is closed_completed (never closed_other), the lane map, one imported event per new idea', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await post(o.DB, BODY);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const state = (issue) => ({ ...o.db.prepare(`SELECT issue_state, state_seen_at FROM roadmap_links WHERE issue = ?`).get(issue) });
  assert.deepEqual(state(16), { issue_state: 'closed_completed', state_seen_at: NOW });
  for (const i of [12, 13, 14]) assert.deepEqual(state(i), { issue_state: null, state_seen_at: null }, `issue ${i}`);
  assert.equal(n(o.db, `SELECT COUNT(*) AS n FROM roadmap_links WHERE issue_state = 'closed_other'`), 0);

  const lane = (title) => o.db.prepare(`SELECT lane FROM roadmap_ideas WHERE title = ?`).get(title).lane;
  assert.equal(lane('Now item'), 'next');
  assert.equal(lane('Next item'), 'next');
  assert.equal(lane('Next item with no link'), 'next');
  assert.equal(lane('Shipped PR'), 'next');
  for (const t2 of ['Later item', 'Later blob', 'Later http']) assert.equal(lane(t2), 'ideas', t2);

  const ev = o.db.prepare(`SELECT i.id, i.lane, i.source_ref, COUNT(e.id) AS k, MIN(e.kind) AS kind, MIN(e.to_lane) AS to_lane,
      MIN(e.actor) AS actor, MIN(e.detail) AS detail, MIN(e.at) AS at, MIN(e.project) AS project
    FROM roadmap_ideas i LEFT JOIN roadmap_idea_events e ON e.idea_id = i.id GROUP BY i.id`).all();
  assert.equal(ev.length, 7);
  for (const e of ev) {
    assert.equal(e.k, 1, e.source_ref);
    assert.equal(e.kind, 'imported');
    assert.equal(e.to_lane, e.lane);
    assert.equal(e.actor, 'operator:fixture');
    assert.equal(e.detail, e.source_ref);
    assert.equal(e.at, NOW);
    assert.equal(e.project, 'cromford');
  }
});

test('L4b an unknown project is 400 field=project and writes nothing', async (t) => {
  const o = await open(t); if (!o) return;
  const r = await post(o.DB, { ...BODY, project: 'no-such-project' });
  assert.equal(r.status, 400);
  assert.equal(r.body.field, 'project');
  assert.match(r.body.error, /not a known project/);
  assert.deepEqual(counts(o.db), ZERO);
  const bad = await post(o.DB, { ...BODY, project: 'bad project!' });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.field, 'project');
});

test('L4c a bad row field is 400 that names it, and nothing is written', async (t) => {
  const o = await open(t); if (!o) return;
  const withIdea = (i, patch) => ({ ...BODY, ideas: IDEAS.map((x, k) => (k === i ? { ...x, ...patch } : x)) });
  const withDec = (i, patch) => ({ ...BODY, decisions: DECISIONS.map((x, k) => (k === i ? { ...x, ...patch } : x)) });
  const cases = [
    ['ideas[1].title', withIdea(1, { title: 'x'.repeat(201) })],
    ['ideas[1].title', withIdea(1, { title: '' })],
    ['ideas[2].section', withIdea(2, { section: 'someday' })],
    ['ideas[3].link', withIdea(3, { link: 'ftp://x' })],
    ['ideas[4].note', withIdea(4, { note: 'x'.repeat(4001) })],
    ['ideas[5].source_ref', withIdea(5, { source_ref: '' })],
    ['ideas[5].source_ref', withIdea(5, { source_ref: 'x'.repeat(501) })],
    ['ideas[6]', { ...BODY, ideas: [...IDEAS.slice(0, 6), 'not an object'] }],
    ['decisions[0].kind', withDec(0, { kind: 'idea' })],
    ['decisions[0].status', withDec(0, { status: 'dropped' })],
    ['decisions[1].title', withDec(1, { title: 'two\nlines' })],
    ['decisions[1].title', withDec(1, { title: 'x'.repeat(201) })],
    ['decisions[1].body', withDec(1, { body: 'x'.repeat(4001) })],
    ['decisions[0].decided_at', withDec(0, { decided_at: '17 Oct' })],
    ['decisions[1].ref', withDec(1, { ref: '' })],
    ['actor', { ...BODY, actor: '' }],
  ];
  for (const [field, body] of cases) {
    const r = await post(o.DB, body);
    assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.field, field, JSON.stringify(r.body));
    assert.ok(r.body.error.startsWith(field), r.body.error);
    assert.deepEqual(counts(o.db), ZERO, field);
  }
});

test('L5 linkInsertSql(n) is the text the route runs; no bearer is 401', async (t) => {
  assert.ok(M, 'src/routes/roadmap-import.js must load');
  const one = M.linkInsertSql(1);
  const three = M.linkInsertSql(3);
  assert.match(one, /^INSERT INTO roadmap_links /);
  assert.match(one, /JOIN roadmap_ideas i ON i\.project = \?1 AND i\.source_ref = /);
  assert.match(one, /WHERE true ON CONFLICT DO NOTHING$/);
  assert.equal((three.match(/\(\?\d+, \?\d+, \?\d+, \?\d+, \?\d+\)/g) || []).length, 3);
  const seen = [];
  const o = await open(t, { beforeRun: (sql) => seen.push(sql) }); if (!o) return;
  await post(o.DB, { ...BODY, ideas: IDEAS.slice(0, 2), decisions: [] });
  assert.ok(seen.includes(M.linkInsertSql(2)), 'the route runs linkInsertSql(2) for 2 link rows');
  assert.ok(seen.every((s) => !/closed_other/.test(s)));

  const r = await post(o.DB, BODY, { secret: null });
  assert.equal(r.status, 401);
});
