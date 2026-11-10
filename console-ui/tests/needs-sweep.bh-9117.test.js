import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { onRequest } from '../functions/api/needs-sweep/[[path]].js';

// BH-9117. The hub lane bin/needs-sweep.sh reads its candidates and writes its
// guarded closes through this endpoint, so the hub keeps no D1 access. Every
// case runs the REAL onRequest; CONSOLE_DB is a real SQLite database wrapped in
// D1's prepare/bind/all/first/run/batch shape.

const SECRET = 'hs-fixture-bh9117';
const DAY = 86400;
const NOW_S = Date.UTC(2026, 10, 5, 22, 0) / 1000;
const iso = (s) => new Date(s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

function world({ throws = false } = {}) {
  const s = new DatabaseSync(':memory:');
  s.exec(`CREATE TABLE builds (id INTEGER PRIMARY KEY, bkey TEXT, project TEXT, ticket_key TEXT, stage TEXT,
      pr_url TEXT, merged INTEGER DEFAULT 0, updated_at TEXT);
    CREATE TABLE commands (id INTEGER PRIMARY KEY, ckey TEXT, status TEXT, created_at, updated_at);`);
  const b = (id, project, tk, stage, merged = 0, at = '2026-07-22T10:00:00Z', pr = '') => s.prepare(
    'INSERT INTO builds (id, bkey, project, ticket_key, stage, pr_url, merged, updated_at) VALUES (?,?,?,?,?,?,?,?)'
  ).run(id, `k${id}`, project, tk, stage, pr, merged, at);
  b(10, 'project-3', 'TK-1', 'plan_blocked');
  b(11, 'project-3', 'TK-1', 'executing');
  b(12, 'project-3', 'TK-1', 'plan_deferred');
  b(13, 'project-4', 'TK-1', 'plan_stale');
  b(14, 'project-3', '', 'plan_blocked');
  b(15, 'project-3', '', 'plan_malformed');
  b(16, 'project-3', 'TK-2', 'pr_created', 0, '2026-07-22T10:00:00Z', 'https://github.com/o/r/pull/5');
  b(17, 'project-3', 'TK-3', 'pr_merged', 1);
  b(18, 'project-3', 'TK-4', 'executing');
  b(19, 'project-3', 'TK-5', 'plan_blocked', 1);
  const c = (id, status, created, updated) => s.prepare(
    'INSERT INTO commands (id, ckey, status, created_at, updated_at) VALUES (?,?,?,?,?)').run(id, `c${id}`, status, created, updated);
  c(1, 'dead_letter', iso(NOW_S - 20 * DAY), iso(NOW_S - 20 * DAY));
  c(2, 'dead_letter', NOW_S - 20 * DAY, NOW_S - 20 * DAY);
  c(3, 'dead_letter', iso(NOW_S - 2 * DAY), iso(NOW_S - 2 * DAY));
  c(4, 'failed', iso(NOW_S - 20 * DAY), iso(NOW_S - 20 * DAY));
  c(5, 'dead_letter', 'garbage', 'garbage');
  c(6, 'dead_letter', iso(NOW_S - 20 * DAY), null);
  const stmt = (sql, binds) => ({
    bind: (...a) => stmt(sql, a),
    all: async () => ({ results: s.prepare(sql).all(...binds) }),
    first: async () => s.prepare(sql).get(...binds) || null,
    run: async () => ({ success: true, meta: { changes: Number(s.prepare(sql).run(...binds).changes) } }),
    _exec() {
      if (/^\s*SELECT/i.test(sql)) return { success: true, results: s.prepare(sql).all(...binds), meta: {} };
      return { success: true, results: [], meta: { changes: Number(s.prepare(sql).run(...binds).changes) } };
    }
  });
  const db = {
    prepare(sql) {
      if (throws) throw new Error('D1_ERROR: no such table: builds');
      return stmt(sql, []);
    },
    // D1 runs a batch as one transaction.
    async batch(list) {
      s.exec('BEGIN');
      try { const out = list.map((x) => x._exec()); s.exec('COMMIT'); return out; } catch (e) { s.exec('ROLLBACK'); throw e; }
    }
  };
  const row = (id) => ({ ...s.prepare('SELECT stage, merged FROM builds WHERE id = ?').get(id) });
  const cmd = (id) => s.prepare('SELECT status FROM commands WHERE id = ?').get(id).status;
  const count = () => s.prepare('SELECT COUNT(*) AS n FROM builds').get().n;
  return { db, row, cmd, count };
}

async function call(env, path, { method = 'GET', auth = `Bearer ${SECRET}`, body, search = '' } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth != null) headers.authorization = auth;
  const init = { method, headers };
  if (body !== undefined) init.body = typeof body === 'string' ? body : JSON.stringify(body);
  const res = await onRequest({
    request: new Request(`https://pages.example/api/needs-sweep/${path}${search}`, init),
    env,
    params: { path: path.split('/').filter(Boolean) }
  });
  return { status: res.status, body: await res.json() };
}
const envOf = (w, extra = {}) => ({ HARNESS_SECRET: SECRET, CONSOLE_DB: w.db, ...extra });
const applyBody = (builds, extra = {}) => ({ apply: true, builds, commands_before: null, ...extra });
const at = '2026-07-22T10:00:00Z';

test('auth: no secret 503, wrong or missing bearer 401 with nothing changed, newline secret matches', async () => {
  const w = world();
  assert.equal((await call({ CONSOLE_DB: w.db }, 'candidates')).status, 503);
  for (const auth of [null, '', `Bearer ${SECRET}x`, 'Bearer ', SECRET, `Basic ${SECRET}`]) {
    const r = await call(envOf(w), 'apply', { method: 'POST', auth, body: applyBody([{ id: 10, to: 'stale', updated_at: at }]) });
    assert.equal(r.status, 401, String(auth));
  }
  assert.equal(w.row(10).stage, 'plan_blocked');
  const ok = await call(envOf(w, { HARNESS_SECRET: `${SECRET}\n` }), 'candidates');
  assert.equal(ok.status, 200);
  assert.equal((await call({ HARNESS_SECRET: SECRET }, 'candidates')).status, 503, 'no CONSOLE_DB');
});

test('routes: wrong methods are 405, unknown paths 404, a D1 error 502', async () => {
  const w = world();
  assert.equal((await call(envOf(w), 'apply')).status, 405);
  assert.equal((await call(envOf(w), 'candidates', { method: 'POST', body: {} })).status, 405);
  assert.equal((await call(envOf(w), 'nope')).status, 404);
  const broken = world({ throws: true });
  const r = await call(envOf(broken), 'candidates');
  assert.equal(r.status, 502);
  assert.match(r.body.error, /no such table/);
});

test('candidates: only merged=0 NEEDS rows, by id, with newest_id per project + ticket', async () => {
  const w = world();
  const r = await call(envOf(w), 'candidates');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows.map((x) => x.id), [10, 12, 13, 14, 15, 16]);
  const by = Object.fromEntries(r.body.rows.map((x) => [x.id, x]));
  assert.equal(by[10].newest_id, 12);
  assert.equal(by[12].newest_id, 12);
  assert.equal(by[13].newest_id, 13, 'another project with the same key is its own ticket');
  assert.equal(by[14].newest_id, null, 'no ticket key: no pairing');
  assert.equal(by[16].pr_url, 'https://github.com/o/r/pull/5');
  assert.equal(by[10].updated_at, at);
  assert.equal(r.body.done, true);
  assert.equal(r.body.next_after, 16);
});

test('candidates: the after cursor pages, limit clamps, a bad cursor is 400', async () => {
  const w = world();
  const p1 = await call(envOf(w), 'candidates', { search: '?after=0&limit=2' });
  assert.deepEqual(p1.body.rows.map((x) => x.id), [10, 12]);
  assert.equal(p1.body.done, false);
  const p2 = await call(envOf(w), 'candidates', { search: `?after=${p1.body.next_after}&limit=2` });
  assert.deepEqual(p2.body.rows.map((x) => x.id), [13, 14]);
  const p0 = await call(envOf(w), 'candidates', { search: '?limit=0' });
  assert.equal(p0.body.rows.length, 1, 'limit 0 clamps to 1');
  const big = await call(envOf(w), 'candidates', { search: '?limit=99999' });
  assert.equal(big.body.rows.length, 6);
  for (const bad of ['?after=x', '?after=-1', '?after=1.5', '?limit=abc']) {
    assert.equal((await call(envOf(w), 'candidates', { search: bad })).status, 400, bad);
  }
});

test('knobs: NEEDS_SWEEP_PAGE_MAX and NEEDS_SWEEP_APPLY_MAX bound the endpoint, a bad value is the fallback', async () => {
  const w = world();
  const page = await call(envOf(w, { NEEDS_SWEEP_PAGE_MAX: '2' }), 'candidates', { search: '?limit=99999' });
  assert.equal(page.body.rows.length, 2, 'the env page max clamps the limit');
  assert.equal((await call(envOf(w, { NEEDS_SWEEP_PAGE_MAX: '2' }), 'candidates')).body.rows.length, 2, 'and is the default page');
  const junk = await call(envOf(w, { NEEDS_SWEEP_PAGE_MAX: 'x' }), 'candidates', { search: '?limit=99999' });
  assert.equal(junk.body.rows.length, 6, 'a non-numeric env value is the fallback');
  const two = [{ id: 10, to: 'stale', updated_at: at }, { id: 12, to: 'stale', updated_at: at }];
  const over = await call(envOf(w, { NEEDS_SWEEP_APPLY_MAX: '1' }), 'apply', { method: 'POST', body: applyBody(two, { apply: false }) });
  assert.equal(over.status, 400, 'the env apply max refuses a longer list');
  const zero = await call(envOf(w, { NEEDS_SWEEP_APPLY_MAX: '0' }), 'apply', { method: 'POST', body: applyBody(two, { apply: false }) });
  assert.equal(zero.status, 200, 'a zero env value is the fallback');
  assert.equal(w.row(10).stage, 'plan_blocked');
});

test('round trip: the apply body built from candidates moves each row to its target, deletes nothing', async () => {
  const w = world();
  const before = w.count();
  const c = await call(envOf(w), 'candidates');
  const to = { 10: 'superseded', 12: 'stale', 13: 'pr_closed', 16: 'pr_merged' };
  const builds = c.body.rows.filter((x) => to[x.id]).map((x) => ({ id: x.id, to: to[x.id], updated_at: x.updated_at, why: 'test' }));
  const r = await call(envOf(w), 'apply', { method: 'POST', body: applyBody(builds) });
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.apply, true);
  assert.deepEqual(r.body.builds, { asked: 4, changed: 4 });
  assert.deepEqual(w.row(10), { stage: 'superseded', merged: 0 });
  assert.deepEqual(w.row(12), { stage: 'stale', merged: 0 });
  assert.deepEqual(w.row(13), { stage: 'pr_closed', merged: 0 });
  assert.deepEqual(w.row(16), { stage: 'pr_merged', merged: 1 });
  assert.equal(w.count(), before, 'no row is deleted');
  const again = await call(envOf(w), 'apply', { method: 'POST', body: applyBody(builds) });
  assert.equal(again.body.builds.changed, 0, 'a replay changes nothing');
});

test('apply guards: a moved updated_at, a non-NEEDS stage and a merged row are not changed', async () => {
  const w = world();
  const r = await call(envOf(w), 'apply', { method: 'POST', body: applyBody([
    { id: 10, to: 'stale', updated_at: '2026-11-05T10:00:00Z' },
    { id: 11, to: 'stale', updated_at: at },
    { id: 19, to: 'stale', updated_at: at },
    { id: 17, to: 'stale', updated_at: at },
    { id: 14, to: 'stale', updated_at: at }
  ]) });
  assert.deepEqual(r.body.builds, { asked: 5, changed: 1 });
  assert.equal(w.row(10).stage, 'plan_blocked');
  assert.equal(w.row(11).stage, 'executing');
  assert.equal(w.row(19).stage, 'plan_blocked');
  assert.equal(w.row(17).stage, 'pr_merged');
  assert.equal(w.row(14).stage, 'stale');
});

test('apply refuses a bad body and writes nothing', async () => {
  const w = world();
  const bads = [
    applyBody([{ id: 10, to: 'deleted', updated_at: at }]),
    applyBody([{ id: 10, to: 'stale', updated_at: at }, { id: 12, to: 'executing', updated_at: at }]),
    applyBody(Array.from({ length: 101 }, (_, i) => ({ id: i + 1, to: 'stale', updated_at: at }))),
    applyBody([{ id: '10', to: 'stale', updated_at: at }]),
    { builds: [] },
    applyBody([], { commands_before: '20 days ago' }),
    'not json'
  ];
  for (const body of bads) {
    const r = await call(envOf(w), 'apply', { method: 'POST', body });
    assert.equal(r.status, 400, JSON.stringify(body).slice(0, 80));
  }
  assert.equal(w.row(10).stage, 'plan_blocked');
  assert.equal(w.row(12).stage, 'plan_deferred');
  assert.equal(w.cmd(1), 'dead_letter');
});

test('apply:false counts what would change and writes nothing', async () => {
  const w = world();
  const r = await call(envOf(w), 'apply', { method: 'POST', body: {
    apply: false,
    builds: [{ id: 10, to: 'stale', updated_at: at }, { id: 11, to: 'stale', updated_at: at }],
    commands_before: iso(NOW_S - 14 * DAY)
  } });
  assert.equal(r.status, 200);
  assert.equal(r.body.apply, false);
  assert.deepEqual(r.body.builds, { asked: 2, changed: 1 });
  assert.deepEqual(r.body.commands, { changed: 3 });
  assert.equal(w.row(10).stage, 'plan_blocked');
  assert.equal(w.cmd(1), 'dead_letter');
});

test('commands: only dead_letter rows older than commands_before expire', async () => {
  const w = world();
  const r = await call(envOf(w), 'apply', { method: 'POST', body: applyBody([], { commands_before: iso(NOW_S - 14 * DAY) }) });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.commands, { changed: 3 });
  assert.equal(w.cmd(1), 'expired', 'ISO 20 days old');
  assert.equal(w.cmd(2), 'expired', 'epoch 20 days old');
  assert.equal(w.cmd(6), 'expired', 'no updated_at: created_at 20 days old');
  assert.equal(w.cmd(3), 'dead_letter', '2 days old');
  assert.equal(w.cmd(4), 'failed', 'failed is not dead_letter');
  assert.equal(w.cmd(5), 'dead_letter', 'an unparseable time never matches');
});
