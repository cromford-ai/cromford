// BH-10231 (C1 of BH-9889): the box-watch restart rows, driven through the
// REAL worker.fetch against the composed jobs schema (node:sqlite).
//
//   C1  claim → claimed:true with an id; a second claim inside the window →
//       claimed:false naming the first id; after the window → claimed:true
//   C2  the window comes from the settings row box_watch.restart_window_min;
//       a bad row value is the fallback 120
//   R1  record → 200 and the row holds every field; the same body again →
//       replay; another outcome → 409; another box → 409; no such id → 404
//   L1  list: newest first; limit default 50, 1..200, 0 and 201 are 400;
//       ?box= filters
//   B1  bad fields are 400 and write nothing
//   S1  the seeded rows: box_watch.*, retention.box_watch_actions.days and the
//       staff_lanes ownership row ('quartermaster','box-watch')
//   EXPLAIN  20,000 seeded rows over 40 boxes: claim, last, per-box list,
//       newest list, retention ids use an index; no full SCAN, no temp b-tree
//   T1  retention: a row older than 365 days is deleted on a live run
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { SQL, WINDOW_FALLBACK_MIN } from '../src/routes/box-watch.js';
import RULES from '../src/routes/retention.d/bh-10231-box-watch.js';

const SECRET = 'test-secret-10231';
const call = (DB, method, path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (r) => ({ status: r.status, body: await r.json().catch(() => null) }));
let uniq = 0;
const boxName = (tag) => `bw-${tag}-${process.pid}-${++uniq}`;

async function fx(t) {
  const o = await openDb();
  if (o === null) { t.skip('node:sqlite unavailable in this runtime'); return null; }
  return o;
}

test('C1 claim, refused inside the window, claimed after it', async (t) => {
  const o = await fx(t); if (!o) return;
  const { DB, db } = o;
  const box = boxName('c1');
  const a = await call(DB, 'POST', '/api/box-watch/claim', { box, box_id: 'small', probes: 3 });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.claimed, true);
  assert.ok(Number.isInteger(a.body.id) && a.body.id > 0);
  assert.equal(a.body.window_min, WINDOW_FALLBACK_MIN);
  const row = db.prepare('SELECT box, box_id, probes, outcome FROM box_watch_actions WHERE id=?').get(a.body.id);
  assert.deepEqual({ ...row }, { box, box_id: 'small', probes: 3, outcome: 'claimed' });

  const b = await call(DB, 'POST', '/api/box-watch/claim', { box, probes: 4 });
  assert.equal(b.status, 200);
  assert.equal(b.body.claimed, false, 'a second claim inside the window is refused');
  assert.equal(b.body.id, a.body.id);
  assert.equal(b.body.last_acted_at, row && db.prepare('SELECT acted_at FROM box_watch_actions WHERE id=?').get(a.body.id).acted_at);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM box_watch_actions WHERE box=?').get(box).n, 1);

  // Another box is its own window.
  const other = await call(DB, 'POST', '/api/box-watch/claim', { box: boxName('c1o'), probes: 3 });
  assert.equal(other.body.claimed, true);

  // Move the first claim 121 minutes back: the window is over.
  db.prepare('UPDATE box_watch_actions SET acted_at=? WHERE id=?')
    .run(new Date(Date.now() - 121 * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z'), a.body.id); // determinism: ok anchored to the route's clock
  const c = await call(DB, 'POST', '/api/box-watch/claim', { box, probes: 3 });
  assert.equal(c.body.claimed, true, 'a claim after the window is granted');
  assert.notEqual(c.body.id, a.body.id);
  db.close();
});

test('C2 the window is the settings row; a bad value is the fallback', async (t) => {
  const o = await fx(t); if (!o) return;
  const { DB, db } = o;
  const box = boxName('c2');
  const a = await call(DB, 'POST', '/api/box-watch/claim', { box, probes: 3 });
  db.prepare('UPDATE box_watch_actions SET acted_at=? WHERE id=?')
    .run(new Date(Date.now() - 30 * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z'), a.body.id); // determinism: ok anchored to the route's clock
  // 120 (seed): 30 min ago is inside.
  assert.equal((await call(DB, 'POST', '/api/box-watch/claim', { box, probes: 3 })).body.claimed, false);
  // 20: 30 min ago is outside.
  db.prepare("UPDATE settings SET value='20' WHERE key='box_watch.restart_window_min'").run();
  const b = await call(DB, 'POST', '/api/box-watch/claim', { box, probes: 3 });
  assert.equal(b.body.window_min, 20);
  assert.equal(b.body.claimed, true);
  // A bad value (2, below 5) is 120.
  db.prepare("UPDATE settings SET value='2' WHERE key='box_watch.restart_window_min'").run();
  const c = await call(DB, 'POST', '/api/box-watch/claim', { box: boxName('c2b'), probes: 3 });
  assert.equal(c.body.window_min, WINDOW_FALLBACK_MIN);
  db.close();
});

test('R1 record the end state once; replay, 409, 404', async (t) => {
  const o = await fx(t); if (!o) return;
  const { DB, db } = o;
  const box = boxName('r1');
  const { body: { id } } = await call(DB, 'POST', '/api/box-watch/claim', { box, box_id: 'small', probes: 3 });
  const end = { box, probes: 3, restart_rc: 0, recovery_rc: 0, outcome: 'back', back_at: '2026-11-26T15:00:00Z', detail: 'back after restart' };
  const r = await call(DB, 'POST', `/api/box-watch/actions/${id}`, end);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.outcome, 'back');
  const row = db.prepare('SELECT box, probes, outcome, restart_rc, recovery_rc, back_at, detail, ended_at FROM box_watch_actions WHERE id=?').get(id);
  assert.equal(row.outcome, 'back');
  assert.equal(row.restart_rc, 0);
  assert.equal(row.recovery_rc, 0);
  assert.equal(row.back_at, '2026-11-26T15:00:00Z');
  assert.equal(row.detail, 'back after restart');
  assert.match(row.ended_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);

  const again = await call(DB, 'POST', `/api/box-watch/actions/${id}`, end);
  assert.equal(again.status, 200);
  assert.equal(again.body.replay, true);
  const other = await call(DB, 'POST', `/api/box-watch/actions/${id}`, { ...end, outcome: 'still_dark', back_at: null });
  assert.equal(other.status, 409);
  assert.equal(db.prepare('SELECT outcome FROM box_watch_actions WHERE id=?').get(id).outcome, 'back', 'a 409 writes nothing');
  const wrongBox = await call(DB, 'POST', `/api/box-watch/actions/${id}`, { ...end, box: boxName('r1x') });
  assert.equal(wrongBox.status, 409);
  const none = await call(DB, 'POST', '/api/box-watch/actions/999999', end);
  assert.equal(none.status, 404);

  // A refused restart stores a null recovery_rc and no back_at.
  const { body: { id: id2 } } = await call(DB, 'POST', '/api/box-watch/claim', { box: boxName('r1r'), probes: 3 });
  const ref = await call(DB, 'POST', `/api/box-watch/actions/${id2}`, { box: db.prepare('SELECT box FROM box_watch_actions WHERE id=?').get(id2).box, probes: 3, restart_rc: 2, recovery_rc: null, outcome: 'refused', back_at: null, detail: 'not configured: ORGO_API_KEY unset' });
  assert.equal(ref.status, 200, JSON.stringify(ref.body));
  const rr = db.prepare('SELECT outcome, restart_rc, recovery_rc, back_at FROM box_watch_actions WHERE id=?').get(id2);
  assert.deepEqual({ ...rr }, { outcome: 'refused', restart_rc: 2, recovery_rc: null, back_at: null });
  db.close();
});

test('L1 list newest first, limit bounds, box filter', async (t) => {
  const o = await fx(t); if (!o) return;
  const { DB, db } = o;
  const box = boxName('l1');
  const ins = db.prepare("INSERT INTO box_watch_actions (box, probes, acted_at, outcome) VALUES (?, 3, ?, 'back')");
  for (let i = 0; i < 60; i++) ins.run(i % 2 ? box : `${box}-b`, `2026-11-${String(1 + (i % 25)).padStart(2, '0')}T${String(i % 24).padStart(2, '0')}:00:00Z`);
  const a = await call(DB, 'GET', '/api/box-watch/actions');
  assert.equal(a.status, 200);
  assert.equal(a.body.actions.length, 50, 'default limit 50');
  const at = a.body.actions.map((r) => r.acted_at);
  assert.deepEqual(at, [...at].sort().reverse(), 'newest first');
  assert.equal((await call(DB, 'GET', '/api/box-watch/actions?limit=200')).body.actions.length, 60);
  assert.equal((await call(DB, 'GET', '/api/box-watch/actions?limit=1')).body.actions.length, 1);
  for (const bad of ['0', '201', 'x', '-1']) assert.equal((await call(DB, 'GET', `/api/box-watch/actions?limit=${bad}`)).status, 400, bad);
  const f = await call(DB, 'GET', `/api/box-watch/actions?box=${box}&limit=200`);
  assert.equal(f.body.actions.length, 30);
  assert.ok(f.body.actions.every((r) => r.box === box));
  assert.equal((await call(DB, 'GET', '/api/box-watch/actions?box=bad%20box')).status, 400);
  db.close();
});

test('B1 bad fields are 400 and write nothing', async (t) => {
  const o = await fx(t); if (!o) return;
  const { DB, db } = o;
  const n0 = db.prepare('SELECT COUNT(*) n FROM box_watch_actions').get().n;
  for (const body of [{}, { box: 'a b', probes: 3 }, { box: 'ok', probes: -1 }, { box: 'ok', probes: 1.5 }, { box: 'ok', box_id: 'Bad', probes: 3 }, { box: 'x'.repeat(65), probes: 3 }]) {
    assert.equal((await call(DB, 'POST', '/api/box-watch/claim', body)).status, 400, JSON.stringify(body));
  }
  assert.equal(db.prepare('SELECT COUNT(*) n FROM box_watch_actions').get().n, n0);
  const box = boxName('b1');
  const { body: { id } } = await call(DB, 'POST', '/api/box-watch/claim', { box, probes: 3 });
  const good = { box, probes: 3, restart_rc: 0, recovery_rc: 0, outcome: 'still_dark', back_at: null, detail: null };
  for (const over of [{ outcome: 'claimed' }, { outcome: 'nope' }, { restart_rc: 256 }, { recovery_rc: 'x' }, { back_at: '2026-11-26' },
    { outcome: 'back' }, { back_at: '2026-11-26T15:00:00Z' }, { detail: 'x'.repeat(501) }, { probes: null }]) {
    const r = await call(DB, 'POST', `/api/box-watch/actions/${id}`, { ...good, ...over });
    assert.equal(r.status, 400, JSON.stringify(over));
  }
  assert.equal(db.prepare('SELECT outcome FROM box_watch_actions WHERE id=?').get(id).outcome, 'claimed');
  db.close();
});

test('S1 seeded knob rows and the quartermaster ownership row', async (t) => {
  const o = await fx(t); if (!o) return;
  const { db } = o;
  const v = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
  assert.equal(v('box_watch.fail_probes'), '3');
  assert.equal(v('box_watch.restart_window_min'), '120');
  assert.equal(v('box_watch.probe_timeout_s'), '15');
  assert.equal(v('box_watch.mass_dark_boxes'), '3');
  assert.equal(v('box_watch.boot_wait_s'), '600');
  assert.equal(v('box_watch.act_timeout_s'), '2400');
  assert.equal(v('box_watch.orgo_timeout_s'), '30');
  assert.equal(v('retention.box_watch_actions.days'), '365');
  assert.ok(db.prepare("SELECT 1 FROM staff_lanes WHERE agent='quartermaster' AND lane='box-watch'").get());
  db.close();
});

test('EXPLAIN on 20,000 seeded rows over 40 boxes: every hot read uses an index', async (t) => {
  const o = await fx(t); if (!o) return;
  const { db } = o;
  const ins = db.prepare("INSERT INTO box_watch_actions (box, box_id, probes, acted_at, outcome) VALUES (?, 'b', 3, ?, 'back')");
  db.exec('BEGIN');
  const base = Date.UTC(2025, 0, 1);
  for (let i = 0; i < 20000; i++) {
    ins.run(`box-${i % 40}`, new Date(base + i * 1800e3).toISOString().replace(/\.\d{3}Z$/, 'Z'));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  // Each read as the route and the retention rule send it (?N → ?), with its binds.
  const pos = (sql) => sql.replace(/\?\d/g, '?');
  const cases = [
    // The NOT EXISTS of the claim, bound box + cutoff.
    ['claim', 'SELECT 1 FROM box_watch_actions WHERE box = ? AND acted_at > ?', ['box-7', '2026-01-01T00:00:00Z'], 'idx_box_watch_actions_box'],
    ['last', pos(SQL.last), ['box-7'], 'idx_box_watch_actions_box'],
    // listBox binds ?1 limit, ?2 box; in text order that is box, then limit.
    ['perBox', pos(SQL.listBox), ['box-7', 50], 'idx_box_watch_actions_box'],
    ['newest', pos(SQL.list), [50], 'idx_box_watch_actions_at'],
    ['retention', pos(RULES[0].ids), ['2026-01-01T00:00:00Z', 50], 'idx_box_watch_actions_at'],
  ];
  for (const [name, sql, args, idx] of cases) {
    const p = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args).map((r) => r.detail).join(' | ');
    assert.ok(p.includes(idx), `${name}: ${p}`);
    assert.ok(!/SCAN box_watch_actions(?! USING)/.test(p), `${name} full scan: ${p}`);
    assert.ok(!/TEMP B-TREE/.test(p), `${name} temp b-tree: ${p}`);
    console.log(`# EXPLAIN ${name}: ${p}`);
  }
  db.close();
});

test('T1 retention deletes a row older than 365 days on a live run', async (t) => {
  const o = await fx(t); if (!o) return;
  const { DB, db } = o;
  const box = boxName('t1');
  const old = new Date(Date.now() - 400 * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z'); // determinism: ok anchored to the route's clock
  const fresh = new Date(Date.now() - 10 * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z'); // determinism: ok anchored to the route's clock
  db.prepare("INSERT INTO box_watch_actions (box, probes, acted_at, outcome) VALUES (?, 3, ?, 'back'), (?, 3, ?, 'back')").run(box, old, box, fresh);
  db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
  const r = await call(DB, 'POST', '/api/retention/run', {});
  const rule = r.body.rules.find((x) => x.rule === 'box_watch_actions.age');
  assert.ok(rule, JSON.stringify(r.body.rules.map((x) => x.rule)));
  assert.equal(rule.error, null);
  assert.equal(rule.removed, 1);
  assert.deepEqual(db.prepare('SELECT acted_at FROM box_watch_actions WHERE box=?').all(box).map((x) => x.acted_at), [fresh]);
  db.close();
});
