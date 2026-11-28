// BH-9594 (BH-9555, order 1 of 2): the could-not-read record, driven through
// the REAL worker.fetch against the composed jobs schema (node:sqlite D1 shim).
//
//   W1  POST 401 then GET: 1 recent row, consecutive 1; POST 503: 2; POST ok:
//       0, and still 2 recent rows (ok writes no failure row)
//   W2  two failure POSTs in one Promise.all: consecutive 2 (one-statement
//       increment)
//   W3  the three settings rows are seeded with their values
//   W4  400 on cred_class gh, box 192.0.2.5 / box.local, status abc, a GET with
//       no box; the GET of another box sees none of this box's rows
//   E1  EXPLAIN QUERY PLAN on 50,000 failure rows over 20 boxes x 4 classes:
//       the recent read uses idx_box_read_failures_box_cred_at, the health
//       read the primary key, the retention ids read idx_box_read_failures_at;
//       no SCAN of box_read_failures
//   R1  retention dry run counts a 15-day-old row and not a 1-day-old row
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; every seeded time is an offset before it
const isoAgo = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const DAY = 86400;
const call = (DB, path, { method = 'POST', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const post = (DB, box, status, over = {}) => call(DB, '/api/box-read-failures', {
  body: { box, project: 'project-5', cred_class: 'gh-app', status, reason: status === 'ok' ? '' : 'auth', ...over },
});
const get = (DB, box, q = '') => call(DB, `/api/box-read-failures?box=${encodeURIComponent(box)}${q}`, { method: 'GET' });
const health = (r, c = 'gh-app') => (r.body.health || []).find((h) => h.cred_class === c);

test('BH-9594 box read failures', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 a failure adds 1, ok resets to 0 and writes no failure row', async () => {
    const { DB } = await openDb();
    const a = await post(DB, 'w1-box', '401');
    assert.equal(a.status, 200);
    assert.deepEqual([a.body.ok, a.body.box, a.body.cred_class, a.body.consecutive], [true, 'w1-box', 'gh-app', 1]);
    let g = await get(DB, 'w1-box');
    assert.equal(g.status, 200);
    assert.equal(g.body.recent.length, 1);
    assert.equal(g.body.recent[0].status, '401');
    assert.equal(health(g).consecutive, 1);
    assert.equal((await post(DB, 'w1-box', '503')).body.consecutive, 2);
    const o = await post(DB, 'w1-box', 'ok');
    assert.equal(o.status, 200);
    assert.equal(o.body.consecutive, 0);
    g = await get(DB, 'w1-box');
    assert.equal(health(g).consecutive, 0);
    assert.equal(health(g).last_status, 'ok');
    assert.ok(health(g).last_ok_at);
    assert.equal(health(g).last_failure_at !== null, true);
    assert.equal(g.body.recent.length, 2);
    // The cred_class filter narrows the recent rows.
    assert.equal((await get(DB, 'w1-box', '&cred_class=gh-pat')).body.recent.length, 0);
  });

  await t.test('W2 two concurrent failures count 2', async () => {
    const { DB } = await openDb();
    await Promise.all([post(DB, 'w2-box', '429'), post(DB, 'w2-box', '502')]);
    assert.equal(health(await get(DB, 'w2-box')).consecutive, 2);
  });

  await t.test('W3 the settings rows are seeded', async () => {
    const { db } = await openDb();
    const v = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
    assert.equal(String(v('retention.box_read_failures.days')), '14');
    assert.equal(String(v('lib.could-not-read.cnr_enforce')), '1');
    assert.equal(String(v('box_read_failures.recent_max')), '20');
  });

  await t.test('W4 bad input is a 400; another box sees nothing', async () => {
    const { DB } = await openDb();
    assert.deepEqual(await post(DB, 'w4-box', '401', { cred_class: 'gh' }), { status: 400, body: { error: 'cred_class' } });
    assert.deepEqual(await post(DB, '192.0.2.5', '401'), { status: 400, body: { error: 'box' } });
    assert.deepEqual(await post(DB, 'box.local', '401'), { status: 400, body: { error: 'box' } });
    assert.deepEqual(await post(DB, 'w4-box', 'abc'), { status: 400, body: { error: 'status' } });
    assert.deepEqual(await post(DB, 'w4-box', '401', { project: 'a b' }), { status: 400, body: { error: 'project' } });
    assert.equal((await call(DB, '/api/box-read-failures', { method: 'GET' })).status, 400);
    assert.equal((await get(DB, 'w4-box', '&cred_class=gh')).status, 400);
    await post(DB, 'w4-box', '401');
    const other = await get(DB, 'w4-other');
    assert.deepEqual([other.body.health, other.body.recent], [[], []]);
    // A long reason is cut to 200 characters.
    await post(DB, 'w4-long', '500', { reason: 'x'.repeat(500) });
    assert.equal((await get(DB, 'w4-long')).body.recent[0].reason.length, 200);
    // No bearer, no answer.
    const anon = await worker.fetch(new Request('https://jobs.test/api/box-read-failures?box=w4-box'), { DB, HARNESS_SECRET: SECRET });
    assert.equal(anon.status, 401);
  });

  await t.test('W5 recent is capped by box_read_failures.recent_max', async () => {
    const { DB, db } = await openDb();
    db.prepare("UPDATE settings SET value='3' WHERE key='box_read_failures.recent_max'").run();
    for (let i = 0; i < 5; i++) await post(DB, 'w5-box', '401');
    assert.equal((await get(DB, 'w5-box')).body.recent.length, 3);
  });

  await t.test('E1 the hot reads use their indexes at seeded volume', async () => {
    const { db } = await openDb();
    const classes = ['gh-app', 'gh-pat', 'board-api', 'jobs'];
    db.exec('BEGIN');
    const s = db.prepare('INSERT INTO box_read_failures (box, project, cred_class, status, reason, at) VALUES (?,?,?,?,?,?)');
    for (let i = 0; i < 50000; i++) s.run(`box-${i % 20}`, 'p', classes[i % 4], '401', 'auth', isoAgo(i * 30));
    const h = db.prepare('INSERT INTO box_cred_health (box, cred_class, consecutive, updated_at) VALUES (?,?,1,?)');
    for (let b = 0; b < 20; b++) for (const c of classes) h.run(`box-${b}`, c, isoAgo(0));
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const uses = (lines, idx) => assert.ok(lines.some((l) => l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN box_\w+/.test(l) && !/USING/.test(l)), [], lines.join(' | '));
    const { SQL } = await import('../src/routes/box-read-failures.js');
    const { default: RULES } = await import('../src/routes/retention.d/bh-9594-box-read-failures.js');
    for (const [q, idx, b] of [
      [SQL.recent, 'idx_box_read_failures_box_cred_at', ['box-1', 20]],
      [SQL.recentClass, 'idx_box_read_failures_box_cred_at', ['box-1', 'gh-app', 20]],
      [SQL.health, 'sqlite_autoindex_box_cred_health_1', ['box-1']],
      [RULES[0].ids, 'idx_box_read_failures_at', [isoAgo(14 * DAY), 500]],
    ]) { const l = plan(q, ...b); uses(l, idx); noScan(l); }
    noScan(plan(RULES[0].del, '[1]'));
  });

  await t.test('R1 retention dry run counts the 15-day-old row only', async () => {
    const { DB, db } = await openDb();
    const s = db.prepare('INSERT INTO box_read_failures (box, project, cred_class, status, reason, at) VALUES (?,?,?,?,?,?)');
    s.run('r1-box', 'p', 'gh-app', '401', 'auth', isoAgo(15 * DAY));
    s.run('r1-box', 'p', 'gh-app', '401', 'auth', isoAgo(1 * DAY));
    const r = await call(DB, '/api/retention/run', { body: { dry_run: true } });
    assert.equal(r.status, 200);
    const rule = r.body.rules.find((x) => x.rule === 'box_read_failures.age');
    assert.ok(rule, `rule missing: ${JSON.stringify(r.body.rules.map((x) => x.rule))}`);
    assert.equal(rule.counted, 1);
    assert.equal(db.prepare('SELECT count(*) AS n FROM box_read_failures').get().n, 2);
  });
});
