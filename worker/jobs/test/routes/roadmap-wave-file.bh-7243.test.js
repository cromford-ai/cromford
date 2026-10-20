import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES } from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '../../src/lib/router.js';

// BH-7267 (BH-7243.4): approve a drafted roadmap wave, file its slices, and
// keep the linked issues' state in sync. Every route case drives the REAL
// worker.fetch and the fragment-ordered route table (D2) over the composed
// jobs schema in node:sqlite. Deleting test/route-table.d/bh-7243-roadmap-wave-file.txt
// turns every route case here into the router's 404. The clock is pinned (D60).
//
// W1  the composed schema seeds the four settings rows with their defaults
// W2  approve: draft -> approved with approved_by/at; requested -> 409; 0 slices -> 409
// W3  the actor gate: each refuse case is 403 and the row is unchanged; each allow case is 200
// W4  reject: draft -> rejected with the reason; an approved wave -> 409; archie -> 403
// W5  file-claim: only approved (fresh or retry-due) and stale filing waves are claimable
// W6  the claim answer, dry_run, two concurrent claims, a project with no projects row
// W7  filed twice -> one link row per idea, wave_id set; not filing -> 409
// W8  filed with another repo -> 400; waves/issues de-duplicates and builds the url
// W9  file-done: filed needs a link per slice; approved needs an error
// W10 tenant: approve / reject / issues with another project -> 404, 0 rows changed
// W11 EXPLAIN QUERY PLAN at seeded volume: every hot read uses its index
// W12 route order: /waves/issues wins over a later GET /api/roadmap/waves/:id row
// W13 links/stale: NULL first, then oldest; fresh rows out; limit capped
// W14 links/state: bad state 400; every row of the issue updated; unknown 404

const SECRET = 'test-secret-fixture';
const NOW_MS = Date.parse('2026-10-19T12:00:00Z');
const NOW = '2026-10-19T12:00:00Z';
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (min) => iso(NOW_MS - min * 60e3);
const REPO = 'example-org/cromford';

const R = await import('../../src/routes/roadmap-wave-file.js').catch(() => null);

const slice = (n, blocked = []) => ({
  title: `Slice ${n}`, body: `Body ${n}`, acceptance_tests: [`t${n}`], spec_refs: [], files: [`f${n}.js`], seam_files: [], blocked_by: blocked,
});
const DRAFT3 = JSON.stringify({ slices: [slice(1), slice(2), slice(3, [1])], notes: '' });

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const p = o.db.prepare(`INSERT INTO projects (project, repo, board_api_prefix, cron_offset, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)`);
  p.run('cromford', REPO, null, NOW, NOW);
  p.run('proj-b', 'o/proj-b', null, NOW, NOW);
  p.run('inapp', 'o/inapp', '/api/boards/b1', NOW, NOW);
  return o;
}

async function call(DB, method, path, body, { secret = SECRET } = {}) {
  const init = { method, headers: {} };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}
const post = (DB, verb, b) => call(DB, 'POST', `/api/roadmap/waves/${verb}`, b);

function wave(db, id, { project = 'cromford', status = 'draft', ideas = ['i1', 'i2'], draft = DRAFT3, error = null,
  updated_at = NOW, claimed_at = null, claimed_by = null } = {}) {
  db.prepare(`INSERT INTO roadmap_waves (id, project, status, input_fp, idea_ids, draft, error, claimed_by, claimed_at, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?)`).run(id, project, status, `fp-${id}`, JSON.stringify(ideas), draft, error, claimed_by, claimed_at, updated_at, updated_at);
}
const row = (db, id) => db.prepare('SELECT * FROM roadmap_waves WHERE id = ?').get(id);
const links = (db, sql = 'SELECT * FROM roadmap_links ORDER BY idea_id, issue') => db.prepare(sql).all();
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', NOW);
}
function link(db, idea, repo, issue, { project = 'cromford', wave_id = null, state = null, seen = null } = {}) {
  db.prepare(`INSERT INTO roadmap_links (idea_id, project, repo, issue, wave_id, issue_state, state_seen_at, created_by, created_at)
              VALUES (?,?,?,?,?,?,?,'test',?)`).run(idea, project, repo, issue, wave_id, state, seen, NOW);
}
const APPROVE = (id, actor = 'operator@example.com', extra = {}) => ({ id, project: 'cromford', expected_status: 'draft', actor, ...extra });

test('W0 the module exports the eight routes and the SQL texts the EXPLAIN test reads', () => {
  assert.ok(R, 'src/routes/roadmap-wave-file.js loads');
  assert.equal(R.routes.length, 8);
  for (const k of ['CLAIM_SQL', 'STALE_SQL', 'ISSUES_LINKS_SQL', 'STATE_SQL', 'TRIED_SQL', 'FILE_DONE_SQL']) assert.equal(typeof R[k], 'string', k);
});

test('W1 the composed schema seeds the four settings rows with their defaults', async (t) => {
  const o = await open(t); if (!o) return;
  const v = (k) => (o.db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
  assert.equal(v('roadmap.issue_sync_batch'), '50');
  assert.equal(v('roadmap.issue_sync_stale_min'), '30');
  assert.equal(v('roadmap.approve_requires_identity'), '0');
  assert.equal(v('roadmap.file_retry_min'), '30');
});

test('W2 approve: draft -> approved and stamped; requested -> 409 unchanged; 0 slices -> 409; bad input -> 400', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1', { updated_at: ago(60) });
  const r = await post(o.DB, 'approve', APPROVE('w1'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.wave.status, 'approved');
  const w = row(o.db, 'w1');
  assert.equal(w.status, 'approved');
  assert.equal(w.approved_by, 'operator@example.com');
  assert.equal(w.approved_at, NOW);
  assert.equal(w.updated_at, NOW);

  const again = await post(o.DB, 'approve', APPROVE('w1'));
  assert.equal(again.status, 409, 'a double click is a 409');
  assert.equal(again.body.wave.status, 'approved');

  wave(o.db, 'w-req', { status: 'requested', draft: null });
  const req = await post(o.DB, 'approve', APPROVE('w-req'));
  assert.equal(req.status, 409);
  assert.equal(row(o.db, 'w-req').status, 'requested');
  assert.equal(row(o.db, 'w-req').approved_by, null);

  wave(o.db, 'w-empty', { draft: JSON.stringify({ slices: [], notes: '' }) });
  const empty = await post(o.DB, 'approve', APPROVE('w-empty'));
  assert.equal(empty.status, 409);
  assert.match(empty.body.error, /no slices/);
  assert.equal(row(o.db, 'w-empty').status, 'draft');
  wave(o.db, 'w-bad', { draft: 'not json' });
  assert.equal((await post(o.DB, 'approve', APPROVE('w-bad'))).status, 409);

  wave(o.db, 'w2');
  assert.equal((await post(o.DB, 'approve', APPROVE('w2', 'operator@example.com', { expected_status: 'approved' }))).status, 400);
  assert.equal((await post(o.DB, 'approve', { project: 'cromford', expected_status: 'draft', actor: 'x@example.com' })).status, 400);
  assert.equal((await post(o.DB, 'approve', APPROVE('missing'))).status, 404);
  assert.equal(row(o.db, 'w2').status, 'draft');
});

test('W3 the actor gate: archie, a roster name, a blank actor and console with the knob on are 403', async (t) => {
  const o = await open(t); if (!o) return;
  const refuse = [['', 0], ['  ', 0], [undefined, 0], ['archie', 0], ['Archie', 0], [' ARCHIE ', 0], ['watchman', 0], ['Watchman', 0], ['console', 1]];
  let i = 0;
  for (const [actor, knob] of refuse) {
    setting(o.db, 'roadmap.approve_requires_identity', knob);
    const id = `wr-${i++}`;
    wave(o.db, id);
    const r = await post(o.DB, 'approve', { id, project: 'cromford', expected_status: 'draft', actor });
    assert.equal(r.status, 403, `actor ${JSON.stringify(actor)} knob=${knob}: ${JSON.stringify(r.body)}`);
    const w = row(o.db, id);
    assert.equal(w.status, 'draft', `actor ${JSON.stringify(actor)} leaves the row draft`);
    assert.equal(w.approved_by, null);
  }
  const allow = [['console', 0], ['operator@example.com', 0], ['archie-fan@example.com', 0], ['watchman2', 0], ['operator@example.com', 1]];
  for (const [actor, knob] of allow) {
    setting(o.db, 'roadmap.approve_requires_identity', knob);
    const id = `wa-${i++}`;
    wave(o.db, id);
    const r = await post(o.DB, 'approve', APPROVE(id, actor));
    assert.equal(r.status, 200, `actor ${actor} knob=${knob}: ${JSON.stringify(r.body)}`);
    assert.equal(row(o.db, id).approved_by, actor);
  }
});

test('W4 reject: draft -> rejected with the reason; approved -> 409; the actor gate holds', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1');
  const r = await post(o.DB, 'reject', { id: 'w1', project: 'cromford', reason: 'too big', actor: 'console' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(row(o.db, 'w1').status, 'rejected');
  assert.equal(row(o.db, 'w1').error, 'rejected: too big');

  wave(o.db, 'w2');
  assert.equal((await post(o.DB, 'reject', { id: 'w2', project: 'cromford', actor: 'console' })).status, 200);
  assert.equal(row(o.db, 'w2').error, 'rejected');

  wave(o.db, 'w3', { status: 'approved' });
  assert.equal((await post(o.DB, 'reject', { id: 'w3', project: 'cromford', actor: 'console' })).status, 409);
  assert.equal(row(o.db, 'w3').status, 'approved');

  wave(o.db, 'w4');
  assert.equal((await post(o.DB, 'reject', { id: 'w4', project: 'cromford', actor: 'archie' })).status, 403);
  assert.equal((await post(o.DB, 'reject', { id: 'w4', project: 'cromford', actor: 'console', reason: 'x'.repeat(501) })).status, 400);
  assert.equal(row(o.db, 'w4').status, 'draft');
});

test('W5 file-claim: draft, rejected, failed, empty and the rest are never claimable', async (t) => {
  const o = await open(t); if (!o) return;
  const claim = () => post(o.DB, 'file-claim', { box: 'hub' });
  let r = await claim();
  assert.equal(r.status, 200);
  assert.equal(r.body.wave, null, 'an empty table has nothing claimable');

  for (const s of ['requested', 'shaping', 'draft', 'empty', 'failed', 'rejected', 'filed']) wave(o.db, `w-${s}`, { status: s, updated_at: ago(600) });
  wave(o.db, 'w-err-fresh', { status: 'approved', error: 'slice 2: http 422', updated_at: ago(1) });
  wave(o.db, 'w-filing-fresh', { status: 'filing', claimed_by: 'bw-1', claimed_at: ago(1), updated_at: ago(1) });
  r = await claim();
  assert.equal(r.body.wave, null, `nothing claimable, got ${JSON.stringify(r.body.wave)}`);
  for (const s of ['requested', 'shaping', 'draft', 'empty', 'failed', 'rejected', 'filed']) assert.equal(row(o.db, `w-${s}`).status, s);
  assert.equal(row(o.db, 'w-filing-fresh').claimed_by, 'bw-1');

  wave(o.db, 'w-ok', { status: 'approved', updated_at: ago(2) });
  r = await claim();
  assert.equal(r.body.wave.id, 'w-ok');
  assert.equal(row(o.db, 'w-ok').status, 'filing');
  assert.equal(row(o.db, 'w-ok').claimed_by, 'hub');
  assert.equal(row(o.db, 'w-ok').claimed_at, NOW);
  assert.equal((await claim()).body.wave, null, 'a fresh claim is not taken again');

  wave(o.db, 'w-stale', { status: 'filing', claimed_by: 'bw-1', claimed_at: ago(31), updated_at: ago(31) });
  r = await claim();
  assert.equal(r.body.wave.id, 'w-stale', 'a filing wave claimed 31 min ago is reclaimed');
  assert.equal(row(o.db, 'w-stale').claimed_by, 'hub');

  wave(o.db, 'w-retry', { status: 'approved', error: 'slice 1: http 500', updated_at: ago(31) });
  r = await claim();
  assert.equal(r.body.wave.id, 'w-retry', 'an approved wave with an error is retried after file_retry_min');
  assert.equal(row(o.db, 'w-retry').error, 'slice 1: http 500', 'the claim keeps the last error until file-done');
  assert.equal((await post(o.DB, 'file-claim', {})).status, 400, 'box is required');
});

test('W6 the claim answer, dry_run, two concurrent claims, a project with no projects row', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1', { status: 'approved', updated_at: ago(5) });
  o.db.prepare("UPDATE roadmap_waves SET approved_by = 'operator@example.com' WHERE id = 'w1'").run();
  const dry = await post(o.DB, 'file-claim', { box: 'hub', dry_run: true });
  assert.equal(dry.body.wave.id, 'w1');
  assert.equal(row(o.db, 'w1').status, 'approved', 'dry_run writes nothing');
  assert.equal(row(o.db, 'w1').claimed_by, null);

  const [a, b] = await Promise.all([post(o.DB, 'file-claim', { box: 'bw-1' }), post(o.DB, 'file-claim', { box: 'bw-2' })]);
  const got = [a.body.wave, b.body.wave].filter(Boolean);
  assert.equal(got.length, 1, 'exactly one claim wins');
  const w = got[0];
  assert.equal(w.id, 'w1');
  assert.equal(w.project, 'cromford');
  assert.deepEqual(w.idea_ids, ['i1', 'i2']);
  assert.equal(w.draft.slices.length, 3);
  assert.deepEqual(w.draft.slices[2].blocked_by, [1]);
  assert.equal(w.approved_by, 'operator@example.com');
  const winner = a.body.wave ? a.body : b.body;
  assert.equal(winner.repo, REPO);
  assert.equal(winner.board_api_prefix, null);
  assert.equal(row(o.db, 'w1').claimed_by, a.body.wave ? 'bw-1' : 'bw-2');

  wave(o.db, 'w-inapp', { project: 'inapp', status: 'approved' });
  const ia = await post(o.DB, 'file-claim', { box: 'hub' });
  assert.equal(ia.body.wave.id, 'w-inapp');
  assert.equal(ia.body.board_api_prefix, '/api/boards/b1');

  wave(o.db, 'w-orphan', { project: 'gone', status: 'approved' });
  const orphan = await post(o.DB, 'file-claim', { box: 'hub' });
  assert.equal(orphan.body.wave, null);
  assert.equal(orphan.body.skipped, 'w-orphan');
  assert.equal(row(o.db, 'w-orphan').status, 'approved');
  assert.equal(row(o.db, 'w-orphan').error, 'project has no projects row');
  assert.equal((await post(o.DB, 'file-claim', { box: 'hub' })).body.wave, null, 'the orphan waits file_retry_min');
});

test('W7 filed twice for one slice -> one row per idea, wave_id set; not filing -> 409; bad slice or issue -> 400', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1', { status: 'filing', claimed_by: 'hub', claimed_at: NOW });
  const f = { id: 'w1', slice: 1, repo: REPO, issue: 101 };
  const a = await post(o.DB, 'filed', f);
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.written, 2);
  const b = await post(o.DB, 'filed', f);
  assert.equal(b.status, 200);
  assert.equal(b.body.written, 0, 'the replay writes nothing');
  const rows = links(o.db);
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((r) => [r.idea_id, r.project, r.repo, r.issue, r.wave_id, r.created_by]),
    [['i1', 'cromford', REPO, 101, 'w1', 'roadmap-file'], ['i2', 'cromford', REPO, 101, 'w1', 'roadmap-file']]);

  for (const bad of [{ slice: 0 }, { slice: 4 }, { slice: '1' }, { issue: 0 }, { issue: -3 }, { issue: 1.5 }]) {
    assert.equal((await post(o.DB, 'filed', { ...f, ...bad })).status, 400, JSON.stringify(bad));
  }
  wave(o.db, 'w2', { status: 'approved' });
  assert.equal((await post(o.DB, 'filed', { ...f, id: 'w2' })).status, 409);
  assert.equal(links(o.db).length, 2);
});

test('W8 filed with another repo -> 400; waves/issues lists the links once each with a url', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1', { status: 'filing', claimed_by: 'hub', claimed_at: NOW });
  assert.equal((await post(o.DB, 'filed', { id: 'w1', slice: 1, repo: 'o/proj-b', issue: 5 })).status, 400);
  assert.equal(links(o.db).length, 0);
  for (const [s, n] of [[1, 101], [2, 102]]) await post(o.DB, 'filed', { id: 'w1', slice: s, repo: REPO, issue: n });
  o.db.prepare("UPDATE roadmap_links SET issue_state = 'open' WHERE issue = 102").run();
  const r = await call(o.DB, 'GET', '/api/roadmap/waves/issues?id=w1&project=cromford');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.wave.id, 'w1');
  assert.equal(r.body.wave.status, 'filing');
  assert.equal(r.body.wave.slice_count, 3);
  assert.equal(r.body.wave.repo, REPO);
  assert.deepEqual(r.body.issues, [
    { repo: REPO, issue: 101, issue_state: null, url: `https://github.com/${REPO}/issues/101` },
    { repo: REPO, issue: 102, issue_state: 'open', url: `https://github.com/${REPO}/issues/102` },
  ]);
  wave(o.db, 'w-req', { status: 'requested', draft: null });
  const req = await call(o.DB, 'GET', '/api/roadmap/waves/issues?id=w-req&project=cromford');
  assert.equal(req.status, 200);
  assert.equal(req.body.wave.slice_count, 0, 'no draft is 0 slices, not an error');
  assert.equal((await call(o.DB, 'GET', '/api/roadmap/waves/issues?id=w1')).status, 400);
});

test('W9 file-done: filed needs a link per slice; approved needs an error', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1', { status: 'filing', claimed_by: 'hub', claimed_at: NOW });
  for (const [s, n] of [[1, 101], [2, 102]]) await post(o.DB, 'filed', { id: 'w1', slice: s, repo: REPO, issue: n });
  const early = await post(o.DB, 'file-done', { id: 'w1', status: 'filed' });
  assert.equal(early.status, 409);
  assert.match(early.body.error, /not every slice has a link/);
  assert.equal(row(o.db, 'w1').status, 'filing');
  await post(o.DB, 'filed', { id: 'w1', slice: 3, repo: REPO, issue: 103 });
  const done = await post(o.DB, 'file-done', { id: 'w1', status: 'filed' });
  assert.equal(done.status, 200, JSON.stringify(done.body));
  assert.equal(row(o.db, 'w1').status, 'filed');
  assert.equal(row(o.db, 'w1').error, null);
  assert.equal((await post(o.DB, 'file-done', { id: 'w1', status: 'filed' })).status, 409, 'only from filing');

  wave(o.db, 'w2', { status: 'filing', claimed_by: 'hub', claimed_at: NOW });
  assert.equal((await post(o.DB, 'file-done', { id: 'w2', status: 'approved' })).status, 400, 'approved needs an error');
  assert.equal((await post(o.DB, 'file-done', { id: 'w2', status: 'failed', error: 'x' })).status, 400);
  const back = await post(o.DB, 'file-done', { id: 'w2', status: 'approved', error: 'slice 2: http 422' });
  assert.equal(back.status, 200);
  const w2 = row(o.db, 'w2');
  assert.equal(w2.status, 'approved');
  assert.equal(w2.error, 'slice 2: http 422');
  assert.equal(w2.claimed_by, null);
  assert.equal((await post(o.DB, 'file-done', { id: 'nope', status: 'approved', error: 'x' })).status, 404);
});

test('W10 tenant: approve, reject and issues with another project read 0 rows and change 0 rows', async (t) => {
  const o = await open(t); if (!o) return;
  wave(o.db, 'w1');
  const before = JSON.stringify(row(o.db, 'w1'));
  assert.equal((await post(o.DB, 'approve', { ...APPROVE('w1'), project: 'proj-b' })).status, 404);
  assert.equal((await post(o.DB, 'reject', { id: 'w1', project: 'proj-b', actor: 'console' })).status, 404);
  assert.equal((await call(o.DB, 'GET', '/api/roadmap/waves/issues?id=w1&project=proj-b')).status, 404);
  assert.equal(JSON.stringify(row(o.db, 'w1')), before);
});

test('W11 EXPLAIN QUERY PLAN over 5,000 links and 500 waves: every hot read uses its index', async (t) => {
  if (!R) { assert.fail('src/routes/roadmap-wave-file.js does not load'); return; }
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db } = o;
  const STATUSES = ['requested', 'shaping', 'draft', 'empty', 'failed', 'rejected', 'approved', 'filing', 'filed'];
  db.exec('BEGIN');
  const wv = db.prepare(`INSERT INTO roadmap_waves (id, project, status, input_fp, idea_ids, created_at, updated_at, claimed_at) VALUES (?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < 500; i++) wv.run(`w-${i}`, `proj-${i % 20}`, STATUSES[i % STATUSES.length], `fp-${i}`, '[]', ago(i * 60), ago(i * 60), ago(i * 60));
  const ln = db.prepare(`INSERT INTO roadmap_links (idea_id, project, repo, issue, wave_id, state_seen_at, created_at) VALUES (?,?,?,?,?,?,?)`);
  for (let i = 0; i < 5000; i++) ln.run(`i-${i}`, `proj-${i % 20}`, `o/r${i % 20}`, 1000 + Math.floor(i / 2), `w-${i % 500}`, i % 10 ? ago(i) : null, NOW);
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
  const cases = [
    ['stale read', R.STALE_SQL, [ago(30), 50], 'idx_roadmap_links_state_seen'],
    ['claim read', R.CLAIM_SQL, [ago(30)], 'idx_roadmap_waves_status'],
    ['waves/issues links', R.ISSUES_LINKS_SQL, ['w-1', 'proj-1'], 'idx_roadmap_links_wave'],
    ['state write', R.STATE_SQL, ['o/r1', 1001, 'open', NOW], 'idx_roadmap_links_repo_issue'],
    ['tried write', R.TRIED_SQL, ['o/r1', 1001, NOW], 'idx_roadmap_links_repo_issue'],
    ['file-done guard', R.FILE_DONE_SQL, ['w-1', 3, NOW], 'idx_roadmap_links_wave'],
  ];
  for (const [name, sql, binds, idx] of cases) {
    const p = plan(sql, binds);
    assert.ok(p.some((d) => d.includes(idx)), `${name} uses ${idx}: ${p.join(' | ')}`);
    assert.ok(!p.some((d) => /^SCAN roadmap_(links|waves)\b(?!.*USING)/.test(d)), `${name} scans no roadmap table: ${p.join(' | ')}`);
  }
});

test('W12 route order: GET /api/roadmap/waves/issues resolves to this family ahead of a later :id row', () => {
  assert.ok(R, 'src/routes/roadmap-wave-file.js loads');
  const later = ['GET', /^\/api\/roadmap\/waves\/([^/]+)$/, () => null];
  const hit = matchRoute([...ROUTES, later], 'GET', '/api/roadmap/waves/issues');
  assert.ok(hit);
  assert.ok(R.routes.includes(hit.entry), 'the issues route of roadmap-wave-file.js answers');
  const other = matchRoute([...ROUTES, later], 'GET', '/api/roadmap/waves/w-123');
  assert.equal(other && other.entry, later, 'any other id still reaches the later row');
});

test('W13 links/stale: never-seen first, then oldest; fresh links out; limit capped by issue_sync_batch', async (t) => {
  const o = await open(t); if (!o) return;
  link(o.db, 'i1', REPO, 1, { seen: ago(120) });
  link(o.db, 'i2', REPO, 2, { seen: null });
  link(o.db, 'i3', REPO, 3, { seen: ago(45) });
  link(o.db, 'i4', REPO, 4, { seen: ago(5) });
  link(o.db, 'i5', REPO, 2, { seen: null });
  const r = await call(o.DB, 'GET', '/api/roadmap/links/stale');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.links.map((l) => l.issue), [2, 1, 3], 'NULL first, then oldest; one entry per issue; 5 min old is fresh');
  assert.equal(r.body.as_of, NOW);
  setting(o.db, 'roadmap.issue_sync_batch', 2);
  const capped = await call(o.DB, 'GET', '/api/roadmap/links/stale?limit=500');
  assert.ok(capped.body.links.length <= 2, `capped at 2: ${JSON.stringify(capped.body.links)}`);
  const one = await call(o.DB, 'GET', '/api/roadmap/links/stale?limit=1');
  assert.equal(one.body.links.length, 1);
  assert.equal((await call(o.DB, 'GET', '/api/roadmap/links/stale?limit=0')).status, 400);
  setting(o.db, 'roadmap.issue_sync_stale_min', 60);
  setting(o.db, 'roadmap.issue_sync_batch', 50);
  const longer = await call(o.DB, 'GET', '/api/roadmap/links/stale');
  assert.deepEqual(longer.body.links.map((l) => l.issue), [2, 1], 'stale_min=60 keeps the 45 min link out');
});

test('W14 links/state: a bad state is 400; every row of the issue is updated; an unknown issue is 404', async (t) => {
  const o = await open(t); if (!o) return;
  link(o.db, 'i1', REPO, 7);
  link(o.db, 'i2', REPO, 7);
  link(o.db, 'i3', REPO, 8);
  const put = (b) => call(o.DB, 'PUT', '/api/roadmap/links/state', b);
  assert.equal((await put({ repo: REPO, issue: 7, issue_state: 'merged' })).status, 400);
  assert.equal((await put({ repo: REPO, issue: '7', issue_state: 'open' })).status, 400);
  const r = await put({ repo: REPO, issue: 7, issue_state: 'closed_completed' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.updated, 2);
  const rows = links(o.db, 'SELECT idea_id, issue_state, state_seen_at FROM roadmap_links ORDER BY idea_id');
  assert.deepEqual(rows.map((x) => [x.idea_id, x.issue_state, x.state_seen_at]),
    [['i1', 'closed_completed', NOW], ['i2', 'closed_completed', NOW], ['i3', null, null]]);
  assert.equal((await put({ repo: REPO, issue: 9, issue_state: 'open' })).status, 404);
  // tried: stamps state_seen_at, keeps issue_state; never with an issue_state.
  assert.equal((await put({ repo: REPO, issue: 8, tried: true, issue_state: 'open' })).status, 400);
  assert.equal((await put({ repo: REPO, issue: 8, tried: 'yes' })).status, 400);
  o.db.prepare("UPDATE roadmap_links SET state_seen_at = ? WHERE idea_id = 'i1'").run(ago(120));
  const tr = await put({ repo: REPO, issue: 7, tried: true });
  assert.equal(tr.status, 200, JSON.stringify(tr.body));
  assert.equal(tr.body.updated, 2);
  const after = links(o.db, 'SELECT idea_id, issue_state, state_seen_at FROM roadmap_links ORDER BY idea_id');
  assert.deepEqual(after.map((x) => [x.idea_id, x.issue_state, x.state_seen_at]),
    [['i1', 'closed_completed', NOW], ['i2', 'closed_completed', NOW], ['i3', null, null]]);
  assert.equal((await put({ repo: REPO, issue: 9, tried: true })).status, 404);
  assert.equal((await call(o.DB, 'GET', '/api/roadmap/links/stale', undefined, { secret: null })).status, 401);
});
