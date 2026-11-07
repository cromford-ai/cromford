// BH-9072 (BH-9067.0): the lane wake routes, POST /api/lane-wakes/ring and
// POST /api/lane-wakes/take, on the existing `wakes` table. Driven through the
// REAL worker.fetch (the route-table fragment is the registration) on
// node:sqlite with the composed jobs schema. Each case opens its own database.
//   W1 ring once per dedupe        W1b bad input = 400, 0 rows
//   W2 ring then take              W3 a second take is empty; two takes race
//   W4 scope A never takes scope B W5 a lead-review twin and a nudge row stay
//   W6 webhook_max_id              W7 EXPLAIN at volume: both statements indexed
//   W8 the hub's wake claim never hands out a harness/lanes row
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9072';
const NOW_MS = Date.parse('2026-11-09T11:00:00Z');
const REPO = 'example-org/project-3-fixture';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
function call(DB, path, body) {
  const init = {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  };
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => {
      const text = await res.text();
      let json = null; try { json = JSON.parse(text); } catch { json = null; }
      return { status: res.status, text, body: json };
    });
}
const ring = (DB, b) => call(DB, '/api/lane-wakes/ring', b);
const take = (DB, b) => call(DB, '/api/lane-wakes/take', b);
const laneRows = (db) => db.prepare("SELECT * FROM wakes WHERE repo='harness/lanes' ORDER BY id").all();
const webhook = (db, repo, kind, key) => Number(db.prepare(
  "INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?, ?, ?, 'issues', ?, '2026-11-09T10:00:00Z') RETURNING id"
).get(repo, kind, key, `2026-11-09T10:${String(key).padStart(2, '0')}`).id);

test('W1 a ring inserts once per dedupe, with the row shape the take reads', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:2026-11-09t11' });
  assert.equal(a.status, 200, a.text);
  assert.equal(a.body.inserted, 1);
  const b = await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:2026-11-09t11' });
  assert.equal(b.status, 200, b.text);
  assert.equal(b.body.inserted, 0, 'a replayed ring adds no row');
  const rows = laneRows(o.db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].kind, 'lane');
  assert.equal(rows[0].key, 'pm-groom:project-3');
  assert.equal(rows[0].event, 'lane-wake');
  assert.equal(rows[0].minute, 'lw:cal:2026-11-09t11');
  assert.equal(rows[0].acked_at, null);
});

test('W1b a bad lane, scope, dedupe or body is a 400 and writes 0 rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const good = { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:1' };
  const bad = [
    { ...good, lane: 'PM_Groom' }, { ...good, lane: 'a'.repeat(49) }, { ...good, lane: 7 },
    { ...good, scope: 'a b' }, { lane: 'pm-groom', dedupe: 'cal:1' }, { ...good, scope: 'x'.repeat(101) },
    { ...good, dedupe: 'x;drop' }, { ...good, dedupe: 'd'.repeat(65) }, { ...good, dedupe: '' },
  ];
  for (const b of bad) {
    const r = await ring(o.DB, b);
    assert.equal(r.status, 400, `accepted ${JSON.stringify(b)}`);
    assert.equal(typeof r.body.error, 'string');
  }
  for (const raw of ['[1,2]', '"x"', 'null']) {
    const r = await ring(o.DB, raw);
    assert.equal(r.status, 400, `accepted body ${raw}`);
  }
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM wakes').get().n, 0);
  // The edges that are legal stay legal.
  const r = await ring(o.DB, { lane: 'a'.repeat(48), scope: 'fleet', dedupe: 'd'.repeat(64) });
  assert.equal(r.status, 200, r.text);
});

test('W2 W3 a take returns the ring id once; a second take is empty; two takes race to one winner', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:a' });
  const id = laneRows(o.db)[0].id;
  const a = await take(o.DB, { lane: 'pm-groom', scope: 'project-3' });
  assert.equal(a.status, 200, a.text);
  assert.deepEqual(a.body.taken, [id]);
  assert.equal(a.body.webhook_max_id, null, 'no kinds sent: absent, never 0');
  assert.equal(typeof a.body.as_of, 'string');
  assert.equal(laneRows(o.db)[0].acked_at, a.body.as_of);
  const b = await take(o.DB, { lane: 'pm-groom', scope: 'project-3' });
  assert.deepEqual(b.body.taken, []);
  // A replayed ring after the take adds no row, so it is never taken again.
  const re = await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:a' });
  assert.equal(re.body.inserted, 0);
  assert.deepEqual((await take(o.DB, { lane: 'pm-groom', scope: 'project-3' })).body.taken, []);
  // Two rings, two concurrent takes: every id goes to exactly one of them.
  await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:b' });
  await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:c' });
  const [x, y] = await Promise.all([take(o.DB, { lane: 'pm-groom', scope: 'project-3' }), take(o.DB, { lane: 'pm-groom', scope: 'project-3' })]);
  const all = [...x.body.taken, ...y.body.taken].sort((p, q) => p - q);
  assert.equal(all.length, 2);
  assert.equal(new Set(all).size, 2, 'one ring went to both takes');
  assert.deepEqual(x.body.taken, [...x.body.taken].sort((p, q) => p - q), 'ids ascending');
});

test('W4 a take for scope acme never returns the project-3 ring', async (t) => {
  const o = await fresh(t); if (!o) return;
  await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:a' });
  const r = await take(o.DB, { lane: 'pm-groom', scope: 'acme' });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.body.taken, []);
  assert.equal(laneRows(o.db)[0].acked_at, null, 'the project-3 ring stays unacked');
  // And another lane with the same scope does not take it either.
  assert.deepEqual((await take(o.DB, { lane: 'pm-ideas', scope: 'project-3' })).body.taken, []);
});

test('W5 a lead-review row and a nudge row with the same key text are never taken', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.prepare("INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES ('harness/lanes','lead-review','pm-groom:project-3','lane:lead-review','lane:1','2026-11-09T10:00:00Z')").run();
  o.db.prepare("INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES ('harness/lanes','issue','pm-groom:project-3','nudge','nudge:1','2026-11-09T10:00:00Z')").run();
  const r = await take(o.DB, { lane: 'pm-groom', scope: 'project-3' });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.body.taken, []);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM wakes WHERE acked_at IS NULL").get().n, 2);
});

test('W6 webhook_max_id: the newest matching row above after_id; a pr, another repo or a nudge row is not counted', async (t) => {
  const o = await fresh(t); if (!o) return;
  const i1 = webhook(o.db, REPO, 'issue', 1);
  const i2 = webhook(o.db, REPO.toLowerCase(), 'issue', 2);   // the repo compares lowercased
  webhook(o.db, REPO, 'pr', 3);                                // a pr row is not counted
  webhook(o.db, 'example-org/other-fixture', 'issue', 4);        // another repo is not counted
  o.db.prepare("INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?, 'issue', '5', 'nudge:untriaged', 'nudge:5', '2026-11-09T10:00:00Z')").run(REPO);
  const body = { lane: 'pm-groom', scope: 'project-3', kinds: ['issue', 'issue_comment'], repo: REPO };
  const a = await take(o.DB, { ...body, after_id: 0 });
  assert.equal(a.status, 200, a.text);
  assert.equal(a.body.webhook_max_id, i2);
  assert.deepEqual(a.body.taken, []);
  assert.equal((await take(o.DB, { ...body, after_id: i1 })).body.webhook_max_id, i2);
  assert.equal((await take(o.DB, { ...body, after_id: i2 })).body.webhook_max_id, null, 'a row with id = after_id is not counted');
  assert.equal((await take(o.DB, { ...body, kinds: ['issue_comment'], after_id: 0 })).body.webhook_max_id, null, 'the receiver never writes kind issue_comment');
  // The ring half still answers in the same call.
  await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:a' });
  const both = await take(o.DB, { ...body, after_id: i1 });
  assert.equal(both.body.taken.length, 1);
  assert.equal(both.body.webhook_max_id, i2);
  // Bad input: 400 before any statement.
  for (const b of [{ ...body, repo: undefined, after_id: 0 }, { ...body, repo: 'nope', after_id: 0 },
    { ...body, after_id: -1 }, { ...body, after_id: 1.5 }, { ...body, after_id: '3' }, { ...body },
    { ...body, kinds: 'issue', after_id: 0 }, { ...body, kinds: ['Issue'], after_id: 0 },
    { ...body, kinds: Array(9).fill('issue'), after_id: 0 }, { lane: 'pm-groom', scope: 'a b' }]) {
    const r = await take(o.DB, b);
    assert.equal(r.status, 400, `accepted ${JSON.stringify(b)}`);
  }
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM wakes WHERE repo='harness/lanes' AND acked_at IS NULL").get().n, 0);
});

test('W7 EXPLAIN at 50,000 rows: the UPDATE uses idx_wakes_dedupe, the MAX read idx_wakes_repo_lc_id, no SCAN wakes', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)');
  const kinds = ['pr', 'checks', 'push', 'issue', 'deploy', 'merge_group'];
  o.db.exec('BEGIN');
  for (let i = 0; i < 49500; i++) {
    ins.run(`example-org/repo-${i % 20}-fixture`, kinds[i % 6], String(i), 'e', `m${i}`, '2026-11-01T00:00:00Z');
  }
  for (let i = 0; i < 500; i++) {
    ins.run('harness/lanes', 'lane', `lane-${i % 25}:scope-${i % 7}`, 'lane-wake', `lw:${i}`, '2026-11-01T00:00:00Z');
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  // The statements the route runs, read from the module so the plan is of the
  // shipped SQL, not of a copy.
  const { TAKE_SQL, MAX_SQL } = await import('../src/routes/lane-wakes.js');
  const p1 = plan(o.db, TAKE_SQL, '2026-11-09T11:00:00Z', 'lane-3:scope-3');
  assert.ok(p1.some((l) => /idx_wakes_dedupe/.test(l)), p1.join(' | '));
  assert.deepEqual(fullScans(p1, ['wakes']), [], p1.join(' | '));
  const p2 = plan(o.db, MAX_SQL, 'example-org/repo-3-fixture', '["issue","issue_comment"]', 40000);
  assert.ok(p2.some((l) => /idx_wakes_repo_lc_id/.test(l)), p2.join(' | '));
  assert.deepEqual(fullScans(p2, ['wakes']), [], p2.join(' | '));
});

test('W8 the hub claim (fleet repos + hub kinds) never returns a harness/lanes ring', async (t) => {
  const o = await fresh(t); if (!o) return;
  webhook(o.db, REPO, 'pr', 1);
  await ring(o.DB, { lane: 'pm-groom', scope: 'project-3', dedupe: 'cal:a' });
  const r = await call(o.DB, '/api/wakes/claim', {
    box: 'box-fixture', repos: [REPO.toLowerCase()], kinds_all_repos: ['pr', 'checks', 'lead-land', 'queue'], limit: 50,
  });
  assert.equal(r.status, 200, r.text);
  assert.ok(Array.isArray(r.body.wakes) && r.body.wakes.length === 1, r.text);
  assert.ok(!r.body.wakes.some((w) => w.repo === 'harness/lanes'), r.text);
  assert.equal(laneRows(o.db)[0].acked_at, null);
});
