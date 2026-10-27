import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { parseRepoSlug, fileScreenProbe } from '../src/routes/onboarding-repo.js';

// BH-7997 (BH-7935 wave 2, order 1): GET /api/onboarding/repo and
// GET /api/onboarding/repos, driven through the worker's REAL fetch handler
// against node:sqlite running the composed schema. Each test opens its own
// in-memory DB. The D1 binding is wrapped so every prepared statement is
// counted, and Date is mocked so the minute bucket is the test's choice.
//   P1     parseRepoSlug accept / refuse table (plan Decision rule 1)
//   B1     a bad slug is 400 with 0 D1 statements
//   D1-D3  the 60 s bucket: one row per minute, a new row next minute, never
//          another project's row
//   M1-M8  row state -> answer (plan Decision rule 3); W1 the golden probe line
//   L1-L3  /repos lines, pending, fail; R2 the 600 s bucket
//   X1     fileScreenProbe is exported and returns the stored row
//   E1     EXPLAIN QUERY PLAN of the row lookup at 10k rows uses the index
const SECRET = 'test-secret';
const GOLDEN = readFileSync(new URL('./fixtures/onboard-repo/visible-probe.json', import.meta.url), 'utf8');
const T0 = Date.parse('2026-10-22T09:00:10Z');
const sha256 = (s) => createHash('sha256').update(s).digest('hex');

async function db(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.sql = [];
  const inner = o.DB;
  o.DB = { ...inner, prepare: (sql) => { o.sql.push(sql); return inner.prepare(sql); } };
  return o;
}

function at(t, ms) {
  mock.timers.reset();
  mock.timers.enable({ apis: ['Date'], now: ms });
  t.after(() => mock.timers.reset());
}

const get = (o, path) => {
  const req = new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } });
  return worker.fetch(req, { DB: o.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const repo = (o, slug) => get(o, `/api/onboarding/repo?slug=${encodeURIComponent(slug)}`);
const rows = (o) => o.db.prepare('SELECT * FROM hub_probe_requests ORDER BY id').all();
const finish = (o, id, status, output, note = null) =>
  o.db.prepare('UPDATE hub_probe_requests SET status=?, output=?, note=? WHERE id=?').run(status, output, note, id);

const ACCEPT = [
  ['example-org/project-11', 'example-org/project-11'],
  ['  example-org/project-11  ', 'example-org/project-11'],
  ['https://github.com/example-org/project-11', 'example-org/project-11'],
  ['https://github.com/example-org/project-11.git', 'example-org/project-11'],
  ['https://github.com/example-org/project-11/', 'example-org/project-11'],
  ['https://github.com/example-org/project-11/tree/main/src', 'example-org/project-11'],
  ['a/b', 'a/b'],
  ['example-org/project-11.git', 'example-org/project-11'],
  [`o/${'r'.repeat(100)}`, `o/${'r'.repeat(100)}`],
  ['myorg-x/re_po.js', 'myorg-x/re_po.js'],
  [`${'o'.repeat(39)}/r`, `${'o'.repeat(39)}/r`],
];
const REFUSE = [
  '', 'example-org', 'example-org/real tor', 'example-org/../x', 'example-org/.', 'example-org/..', '../x',
  'example-org/x?y', 'example-org/x#y', '/project-11', 'example-org/', `o/${'r'.repeat(101)}`,
  `${'o'.repeat(40)}/r`, 'owner_x/repo', 'my.org/repo', 'a/b/c', 'https://gitlab.com/o/r',
  'https://a@github.com/x/y', 'https://github.com.evil.com/o/r', 'http://github.com/o/r',
  'https://www.github.com/o/r', 'https://github.com/o/r?tab=1', 'https://github.com/o/r#readme',
  'https://github.com/o', 'https://github.com/o/', 'git@github.com:o/r.git', 'o/.git',
  'https://github.com/o/r/tree/ma in', 'example-org/project-11\n', 'example-org\t/r',
  123, { owner: 'o', repo: 'r' }, null, undefined, `o/${'r'.repeat(2047)}`,
];

test('(P1) parseRepoSlug: every ACCEPT row gives its slug, every REFUSE row gives null', () => {
  for (const [raw, slug] of ACCEPT) {
    const p = parseRepoSlug(raw);
    assert.ok(p, `accept ${JSON.stringify(raw)}`);
    assert.equal(p.slug, slug, `slug of ${JSON.stringify(raw)}`);
    assert.equal(`${p.owner}/${p.repo}`, slug);
  }
  // `example-org/project-11\n` trims to a good slug; that is the trim rule, not a refuse.
  for (const raw of REFUSE.filter((r) => r !== 'example-org/project-11\n')) {
    assert.equal(parseRepoSlug(raw), null, `refuse ${JSON.stringify(raw)}`);
  }
  const padded = `example-org/project-11${' '.repeat(2029)}`;
  assert.equal(padded.length, 2049);
  assert.equal(parseRepoSlug(padded), null, 'over 2048 characters before the trim');
  assert.equal(parseRepoSlug(padded.slice(0, 2048)).slug, 'example-org/project-11', '2048 characters is in');
});

test('(B1) a bad slug is 400 with 0 D1 statements; so is no slug', async (t) => {
  const o = await db(t); if (!o) return;
  for (const raw of ['example-org', 'https://gitlab.com/o/r', 'a/b/c', 'o/..']) {
    const r = await repo(o, raw);
    assert.equal(r.status, 400);
    assert.equal(r.body.error, 'slug must be owner/repo or https://github.com/owner/repo');
  }
  const none = await get(o, '/api/onboarding/repo');
  assert.equal(none.status, 400);
  assert.deepEqual(o.sql, []);
  assert.equal(rows(o).length, 0);
});

test('(D1) two GETs in one minute file ONE row and both answer pending', async (t) => {
  const o = await db(t); if (!o) return;
  at(t, T0);
  const a = await repo(o, 'example-org/project-11');
  mock.timers.setTime(T0 + 40_000);
  const b = await repo(o, 'https://github.com/example-org/project-11.git');
  assert.deepEqual([a.status, a.body], [200, { state: 'pending' }]);
  assert.deepEqual([b.status, b.body], [200, { state: 'pending' }]);
  const all = rows(o);
  assert.equal(all.length, 1);
  assert.equal(all[0].project, 'onboarding');
  assert.equal(all[0].probe, 'repo-detect');
  assert.equal(all[0].ticket_key, `onb-repo-${Math.floor(T0 / 60000)}`);
  assert.equal(all[0].args_json, '["example-org/project-11"]');
  assert.equal(all[0].args_hash, sha256('["example-org/project-11"]'));
  assert.equal(all[0].requested_by, 'console');
  assert.equal(o.sql.length, 4, 'two statements per GET: the INSERT and the SELECT');
});

test('(D2) a GET in the next minute files a second row', async (t) => {
  const o = await db(t); if (!o) return;
  at(t, T0);
  await repo(o, 'example-org/project-11');
  mock.timers.setTime(T0 + 60_000);
  const b = await repo(o, 'example-org/project-11');
  assert.equal(b.body.state, 'pending');
  const keys = rows(o).map((r) => r.ticket_key);
  assert.deepEqual(keys, [`onb-repo-${Math.floor(T0 / 60000)}`, `onb-repo-${Math.floor(T0 / 60000) + 1}`]);
});

test('(D3) a row of another project with the same key is never read', async (t) => {
  const o = await db(t); if (!o) return;
  at(t, T0);
  const key = `onb-repo-${Math.floor(T0 / 60000)}`;
  const args = '["example-org/project-11"]';
  o.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, status, requested_at, output) VALUES ('other', ?, 'repo-detect', ?, ?, 'pass', '2026-10-22T09:00:00Z', ?)")
    .run(key, args, sha256(args), GOLDEN);
  const r = await repo(o, 'example-org/project-11');
  assert.deepEqual(r.body, { state: 'pending' });
  const mine = rows(o).filter((x) => x.project === 'onboarding');
  assert.equal(mine.length, 1);
  assert.equal(mine[0].status, 'pending');
});

// One filed row per case, moved to the state under test, then read back.
async function stateOf(t, status, output, note) {
  const o = await db(t); if (!o) return null;
  at(t, T0);
  await repo(o, 'example-org/project-11');
  finish(o, rows(o)[0].id, status, output, note);
  return (await repo(o, 'example-org/project-11')).body;
}

test('(M1-M8) row state -> answer', async (t) => {
  await t.test('M1 claimed is pending', async (t) => {
    assert.deepEqual(await stateOf(t, 'claimed', null), { state: 'pending' });
  });
  await t.test('M2 pending deferred by the daily cap is pending with the note', async (t) => {
    assert.deepEqual(await stateOf(t, 'pending', null, 'deferred: daily cap'), { state: 'pending', note: 'deferred: daily cap' });
  });
  await t.test('M3 pass visible:false', async (t) => {
    const out = '{"visible":false,"install_url":"https://github.com/apps/cromford/installations/new"}\n';
    assert.deepEqual(await stateOf(t, 'pass', out),
      { state: 'ok', visible: false, install_url: 'https://github.com/apps/cromford/installations/new' });
  });
  await t.test('M4 pass with an array is an error', async (t) => {
    assert.equal((await stateOf(t, 'pass', '[1,2]')).state, 'error');
  });
  await t.test('M5 pass with text is an error, never a half-parsed ok', async (t) => {
    const b = await stateOf(t, 'pass', 'oops\n{"visible":true}');
    assert.equal(b.state, 'error');
    assert.equal(b.visible, undefined);
  });
  await t.test('M6 pass with an empty output is an error', async (t) => {
    assert.equal((await stateOf(t, 'pass', '')).state, 'error');
  });
  await t.test('M7 fail not-configured', async (t) => {
    assert.deepEqual(await stateOf(t, 'fail', 'not-configured\n'), { state: 'error', error: 'not-configured' });
  });
  await t.test('M8 rejected is an error; a long output is cut to 200 characters', async (t) => {
    const b = await stateOf(t, 'rejected', `${'x'.repeat(300)}\n`);
    assert.equal(b.state, 'error');
    assert.equal(b.error, 'x'.repeat(200));
  });
  await t.test('M9 pass with visible not a boolean is an error', async (t) => {
    assert.equal((await stateOf(t, 'pass', '{"visible":"yes"}')).state, 'error');
  });
});

test('(W1) a pass row holding the golden probe line answers the facts', async (t) => {
  const b = await stateOf(t, 'pass', GOLDEN);
  if (!b) return;
  assert.deepEqual(b, {
    state: 'ok', visible: true,
    facts: { default_branch: 'main', has_issues: true, open_issues: 3 },
    install_url: 'https://github.com/apps/cromford/installations/new',
  });
});

const REPOS_OUT = 'example-org/cromford\nexample-org/project-11\ntotal_count=140\nincomplete: 2 of 140\n';
async function reposOf(t, status, output) {
  const o = await db(t); if (!o) return null;
  at(t, T0);
  const first = await get(o, '/api/onboarding/repos');
  assert.deepEqual(first.body, { state: 'pending' });
  const r = rows(o)[0];
  assert.equal(r.probe, 'app-installation-repos');
  assert.equal(r.args_json, '[]');
  assert.equal(r.ticket_key, `onb-repos-${Math.floor(T0 / 600000)}`);
  finish(o, r.id, status, output);
  return (await get(o, '/api/onboarding/repos')).body;
}

test('(L1) /repos: pass lines -> repos, total_count, incomplete', async (t) => {
  const b = await reposOf(t, 'pass', REPOS_OUT);
  if (!b) return;
  assert.deepEqual(b, { state: 'ok', repos: ['example-org/cromford', 'example-org/project-11'], total_count: 140, incomplete: true });
  const c = await reposOf(t, 'pass', 'example-org/project-11\ntotal_count=1\n');
  assert.deepEqual(c, { state: 'ok', repos: ['example-org/project-11'], total_count: 1, incomplete: false });
});

test('(L2) /repos: claimed is pending; (L3) fail and a pass without total_count are errors', async (t) => {
  assert.deepEqual(await reposOf(t, 'claimed', null), { state: 'pending' });
  assert.deepEqual(await reposOf(t, 'fail', 'FAIL app-token-unavailable\n'), { state: 'error', error: 'FAIL app-token-unavailable' });
  assert.equal((await reposOf(t, 'pass', 'example-org/project-11\n')).state, 'error');
});

test('(R2) two /repos GETs 9 minutes apart in one 600 s bucket file one row', async (t) => {
  const o = await db(t); if (!o) return;
  const start = Math.floor(T0 / 600000) * 600000;
  at(t, start);
  await get(o, '/api/onboarding/repos');
  mock.timers.setTime(start + 9 * 60_000);
  await get(o, '/api/onboarding/repos');
  assert.equal(rows(o).length, 1);
  mock.timers.setTime(start + 10 * 60_000);
  await get(o, '/api/onboarding/repos');
  assert.equal(rows(o).length, 2);
});

test('(X1) fileScreenProbe files once and returns the stored row', async (t) => {
  const o = await db(t); if (!o) return;
  const a = await fileScreenProbe({ DB: o.DB }, { t: '2026-10-22T09:00:00Z', ticket_key: 'onb-x-1', probe: 'ready-facts', args: ['project-11'] });
  const b = await fileScreenProbe({ DB: o.DB }, { ticket_key: 'onb-x-1', probe: 'ready-facts', args: ['project-11'] });
  assert.equal(a.project, 'onboarding');
  assert.equal(a.status, 'pending');
  assert.equal(a.requested_at, '2026-10-22T09:00:00Z');
  assert.equal(b.id, a.id);
  assert.equal(rows(o).length, 1);
  assert.equal(await fileScreenProbe({ DB: o.DB }, { ticket_key: 'bad key!', probe: 'ready-facts', args: [] }), null);
  const broken = { DB: { prepare() { throw new Error('D1 overloaded'); } } };
  assert.equal(await fileScreenProbe(broken, { ticket_key: 'onb-x-1', probe: 'ready-facts', args: [] }), null);
});

test('(X2) a D1 that cannot file the row answers 503', async (t) => {
  const r = await worker.fetch(new Request('https://jobs.test/api/onboarding/repo?slug=a/b', { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB: { prepare() { throw new Error('no such table: hub_probe_requests'); } }, HARNESS_SECRET: SECRET });
  assert.equal(r.status, 503);
  assert.deepEqual(await r.json(), { error: 'the hub-probe request could not be filed' });
});

test('(E1) EXPLAIN QUERY PLAN of the row lookup at 10k rows uses the unique index', async (t) => {
  const o = await db(t); if (!o) return;
  const ins = o.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES (?, ?, 'repo-detect', '[]', ?, '2026-10-22T00:00:00Z')");
  o.db.exec('BEGIN');
  for (let i = 0; i < 10000; i++) ins.run(i % 2 ? 'onboarding' : 'cromford', `onb-repo-${29000000 + (i % 500)}`, sha256(String(i)));
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  o.sql = [];
  at(t, T0);
  await repo(o, 'example-org/project-11');
  const select = o.sql.find((s) => /^\s*SELECT/i.test(s));
  assert.ok(select, 'the handler ran a SELECT');
  const plan = o.db.prepare(`EXPLAIN QUERY PLAN ${select}`).all('onboarding', 'onb-repo-1', 'repo-detect', 'h').map((r) => r.detail).join(' | ');
  assert.match(plan, /USING (COVERING )?INDEX/);
  assert.doesNotMatch(plan, /SCAN hub_probe_requests/);
});
