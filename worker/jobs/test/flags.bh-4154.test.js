// BH-4154 slice C0: the pause_flags mirror is retired, and every worker reader
// of a fleet flag reads the store the flag's name picks (lib/harness-flags.js):
// harness_flags for a name FLAG_PORTED_RE matches (its pause_flags row only
// when no harness_flags row exists yet), pause_flags for every other name.
//
// WHAT IS PINNED, on a REAL schema database behind the node:sqlite shim,
// through the real worker.fetch:
//   M1  PUT of a ported fleet name writes the harness_flags row and NO
//       pause_flags row (paused-*, and dispatch-mode-* with its value).
//   M2  DELETE of a ported name sets cleared_at and writes NO pause_flags row;
//       a pre-deploy mirror row keeps its active and its stamp.
//   M3  GET one and GET list keep active, actor and updated_at.
//   M4  a stale pause_flags paused-p active=1 under a cleared harness_flags
//       row does not refuse a claim.
//   M5  a pause_flags paused-q active=1 with no harness_flags row refuses.
//   M6  a box-scoped harness_flags paused-p does not refuse a fleet claim.
//   M7  non-ported names (all-off in the digest, cost-anchor-off, main-red-*
//       list and CLEAR, lane-off-sentry-report) answer from pause_flags, and a
//       stray fleet harness_flags row of the same name changes nothing.
//   M8  /api/lanes/status sees an automerge-disabled harness_flags row with
//       no pause_flags row.
//   M9  the refusal reason names the table and the row that answered.
//   M10 the SQL forms of the decision rule (portedSql, flagActiveSql,
//       clearFleetFlagStmt) agree with isPortedFlag and the JS reader.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import {
  isPortedFlag, portedSql, flagActiveSql, readFleetFlag, clearFleetFlagStmt,
} from '../src/lib/harness-flags.js';
import { ensureTable } from '../src/lib/core.js';
import { withHarnessSentry } from '../src/lib/sentry.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const T0 = '2026-10-01T00:00:00Z';
const T1 = '2026-10-02T00:00:00Z';

const call = (DB, method, path, body) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  // The harness_flags create and its one-time backfill run first, as on a warm
  // worker. A pause_flags row a test plants after this is one the backfill
  // never copied: the "no harness_flags row yet" case.
  await ensureTable({ DB: opened.DB }, 'harness_flags');
  await fn(opened);
}

const hrow = (db, name, scope = 'fleet') =>
  db.prepare('SELECT * FROM harness_flags WHERE scope=? AND name=?').get(scope, name);
const prow = (db, name) => db.prepare('SELECT * FROM pause_flags WHERE name=?').get(name);
const plantPause = (db, name, active, at = T0, actor = 'old-worker') => db.prepare(
  'INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES (?, ?, ?, ?, ?)',
).run(name, active, actor, 'planted', at);
const plantRow = (db, name, { scope = 'fleet', cleared = null, at = T0 } = {}) => db.prepare(
  'INSERT INTO harness_flags (scope, name, set_by, reason, set_at, cleared_at) VALUES (?, ?, ?, ?, ?, ?)',
).run(scope, name, 'stray', 'planted', at, cleared);
const claim = (DB, project, id) => call(DB, 'POST', '/api/jobs', {
  id, project, kind: 'build', box: 'box-fixture', stage: 'plan', ticket_id: id, lane: `plan/${project}/claude`,
});

test('M1 a ported PUT writes the harness_flags row and no pause_flags row', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'console', reason: 'freeze' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(hrow(db, 'paused-p').cleared_at, null);
  assert.equal(prow(db, 'paused-p'), undefined, 'no pause_flags mirror');

  const dm = await call(DB, 'PUT', '/api/flags', { name: 'dispatch-mode-p', active: 1, value: 'paused', actor: 'console' });
  assert.equal(dm.status, 200, JSON.stringify(dm.body));
  assert.equal(hrow(db, 'dispatch-mode-p').value, 'paused');
  assert.equal(prow(db, 'dispatch-mode-p'), undefined, 'no pause_flags mirror for dispatch-mode-*');

  const off = await call(DB, 'PUT', '/api/flags', { name: 'automerge-disabled', active: 0, actor: 'console' });
  assert.equal(off.status, 200);
  assert.equal(prow(db, 'automerge-disabled'), undefined, 'an OFF write does not mirror either');
}));

test('M2 a ported DELETE clears the row and leaves pause_flags alone', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'console' });
  const del = await call(DB, 'DELETE', '/api/flags?name=paused-p&actor=operator&reason=back');
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.equal(typeof hrow(db, 'paused-p').cleared_at, 'string');
  assert.equal(prow(db, 'paused-p'), undefined, 'a clear writes no pause_flags row');

  // A row the old worker mirrored before this deploy: the clear does not touch it.
  await call(DB, 'PUT', '/api/flags', { name: 'paused-m', active: 1, actor: 'console' });
  plantPause(db, 'paused-m', 1, T0);
  const del2 = await call(DB, 'DELETE', '/api/flags?name=paused-m&actor=operator');
  assert.equal(del2.status, 200);
  assert.notEqual(hrow(db, 'paused-m').cleared_at, null);
  assert.equal(prow(db, 'paused-m').active, 1, 'the old mirror row keeps its active');
  assert.equal(prow(db, 'paused-m').updated_at, T0, 'and its stamp');
}));

test('M3 GET one and GET list keep active, actor and updated_at', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'console' });
  const h = hrow(db, 'paused-p');
  const one = await call(DB, 'GET', '/api/flags/paused-p');
  assert.equal(one.status, 200);
  assert.equal(one.body.flag.active, 1);
  assert.equal(one.body.flag.actor, 'console');
  assert.equal(one.body.flag.updated_at, h.set_at);
  const list = await call(DB, 'GET', '/api/flags?prefix=paused-');
  assert.deepEqual(list.body.flags.map((f) => [f.name, f.active, f.actor, f.updated_at]),
    [['paused-p', 1, 'console', h.set_at]]);

  await call(DB, 'DELETE', '/api/flags?name=paused-p&actor=operator');
  const c = hrow(db, 'paused-p');
  const after = await call(DB, 'GET', '/api/flags?prefix=paused-');
  assert.deepEqual(after.body.flags.map((f) => [f.name, f.active, f.actor, f.updated_at]),
    [['paused-p', 0, 'operator', c.cleared_at]]);
}));

test('M4 a stale mirror row under a cleared harness_flags row does not refuse a claim', (t) => withDb(t, async ({ db, DB }) => {
  plantRow(db, 'paused-p', { cleared: T1 });
  plantPause(db, 'paused-p', 1);
  const r = await claim(DB, 'p', 'P-1');
  assert.equal(r.status, 201, JSON.stringify(r.body));
}));

test('M5 a pause_flags row with no harness_flags row still refuses', (t) => withDb(t, async ({ db, DB }) => {
  plantPause(db, 'paused-q', 1);
  assert.equal(hrow(db, 'paused-q'), undefined);
  const r = await claim(DB, 'q', 'Q-1');
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'refused: paused');
  assert.equal(r.body.flag, 'paused-q');
}));

test('M6 a box-scoped harness_flags row does not refuse a fleet claim', (t) => withDb(t, async ({ db, DB }) => {
  plantRow(db, 'paused-p', { scope: 'boxa' });
  const r = await claim(DB, 'p', 'P-2');
  assert.equal(r.status, 201, JSON.stringify(r.body));
}));

test('M7 non-ported names answer from pause_flags; a stray harness_flags row changes nothing', async (t) => {
  // ON in pause_flags under a stray CLEARED harness_flags row stays on; OFF
  // in pause_flags under a stray LIVE harness_flags row stays off.
  const both = async (fn) => {
    for (const on of [1, 0]) {
      const opened = await openDb();
      if (opened === null) { t.skip('node:sqlite unavailable'); return; }
      await ensureTable({ DB: opened.DB }, 'harness_flags');
      await fn(opened, on);
    }
  };
  const plant = (db, name, on) => {
    plantPause(db, name, on);
    plantRow(db, name, { cleared: on ? T1 : null });
  };

  await t.test('all-off in the digest factory section', () => both(async ({ db, DB }, on) => {
    plant(db, 'all-off', on);
    const day = '2026-10-01';
    const r = await call(DB, 'GET', `/api/metrics/daily-digest?day=${day}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.factory.all_off.set, Boolean(on));
  }));

  await t.test('cost-anchor-off on /api/metrics/cost-anchored', () => both(async ({ db, DB }, on) => {
    plant(db, 'cost-anchor-off', on);
    const r = await call(DB, 'GET', '/api/metrics/cost-anchored');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.disabled === true, Boolean(on));
  }));

  await t.test('main-red-o-r on GET /api/main-red and its CLEAR', () => both(async ({ db, DB }, on) => {
    plant(db, 'main-red-o-r', on);
    const list = await call(DB, 'GET', '/api/main-red');
    assert.equal(list.status, 200, JSON.stringify(list.body));
    assert.deepEqual(list.body.main_red.map((r) => r.name), on ? ['main-red-o-r'] : []);
    const clr = await call(DB, 'POST', '/api/main-red/clear', { name: 'main-red-o-r', actor: 'operator', reason: 'fixed' });
    assert.equal(clr.status, on ? 200 : 409, JSON.stringify(clr.body));
    assert.equal(prow(db, 'main-red-o-r').active, 0);
    const stray = hrow(db, 'main-red-o-r');
    assert.equal(stray.cleared_at, on ? T1 : null, 'the stray row is not written');
    assert.equal(stray.set_by, 'stray');
  }));

  await t.test('lane-off-sentry-report in sentry paused()', () => both(async ({ db, DB }, on) => {
    plant(db, 'lane-off-sentry-report', on);
    const real = globalThis.fetch;
    const posts = [];
    globalThis.fetch = async (url) => {
      if (String(url).includes('sentry.test')) posts.push(String(url));
      return new Response('{}', { status: 200 });
    };
    try {
      const waits = [];
      const ctx = { waitUntil: (p) => waits.push(Promise.resolve(p).catch(() => {})), passThroughOnException() {} };
      const h = withHarnessSentry({ fetch() { throw new Error(`m7 sentry ${on}`); } }, { worker: 'm7', pauseFlags: true });
      await assert.rejects(() => h.fetch(new Request('https://x.test/'), { DB, HARNESS_SENTRY_DSN: 'https://fixturekey@sentry.test/1' }, ctx));
      for (let seen = -1; seen !== waits.length;) {
        seen = waits.length;
        await Promise.all(waits);
        await new Promise((r) => setTimeout(r, 5));
      }
      assert.equal(posts.length, on ? 0 : 1, on ? 'the kill switch drops the event' : 'off sends it');
    } finally {
      globalThis.fetch = real;
    }
  }));
});

test('M8 /api/lanes/status sees an automerge-disabled harness_flags row', (t) => withDb(t, async ({ db, DB }) => {
  const put = await call(DB, 'PUT', '/api/flags', { name: 'automerge-disabled', active: 1, actor: 'console', reason: 'hold' });
  assert.equal(put.status, 200);
  assert.equal(prow(db, 'automerge-disabled'), undefined);
  const r = await call(DB, 'GET', '/api/lanes/status');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const l = r.body.lanes.find((x) => x.id === 'merge-conductor');
  assert.equal(l.off, true);
  assert.deepEqual(l.held_by, ['automerge-disabled']);
  assert.equal(l.paused_by, 'console');
  assert.equal(l.paused_reason, 'hold');

  await call(DB, 'DELETE', '/api/flags?name=automerge-disabled&actor=operator');
  plantPause(db, 'automerge-disabled', 1); // a stale mirror row: the cleared row wins
  const after = await call(DB, 'GET', '/api/lanes/status');
  assert.equal(after.body.lanes.find((x) => x.id === 'merge-conductor').off, false);
}));

test('M9 the refusal reason names the table and the row that answered', (t) => withDb(t, async ({ db, DB }) => {
  plantPause(db, 'paused-q', 1, T0);
  const q = await claim(DB, 'q', 'Q-2');
  assert.equal(q.status, 409);
  assert.match(q.body.reason, /^paused: pause_flags row paused-q is active \(updated 2026-10-01T00:00:00Z\)/);

  await call(DB, 'PUT', '/api/flags', { name: 'paused-r', active: 1, actor: 'console', reason: 'hold' });
  const h = hrow(db, 'paused-r');
  const r = await claim(DB, 'r', 'R-1');
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.flag, 'paused-r');
  assert.equal(r.body.reason, `paused: harness_flags row paused-r is active (updated ${h.set_at}) — hold (set by console)`);
}));

test('M10 the SQL forms of the decision rule agree with the JS reader', (t) => withDb(t, async ({ db, DB }) => {
  const names = ['paused-x', 'paused-', 'automerge-disabled', 'automerge-disabledx', 'automerge-disabled-x',
    'automerge-disabled-', 'lanedown-b', 'dispatch-mode-p', 'dispatch-mode-', 'all-off', 'xpaused-x', 'main-red-o-r'];
  for (const n of names) {
    const got = db.prepare(`SELECT ${portedSql('?1')} AS p`).get(n).p;
    assert.equal(Boolean(got), isPortedFlag(n), `portedSql vs isPortedFlag for ${n}`);
  }

  // Each name in four states: no rows, pause only on, harness live over a
  // pause off, harness cleared over a pause on.
  const states = [
    ['none', () => {}],
    ['pause-on', (n) => plantPause(db, n, 1)],
    ['row-live', (n) => { plantPause(db, n, 0); plantRow(db, n); }],
    ['row-cleared', (n) => { plantPause(db, n, 1); plantRow(db, n, { cleared: T1 }); }],
  ];
  for (const base of ['paused-s', 'all-on-x']) {
    for (const [label, plant] of states) {
      const n = `${base}-${label}`;
      plant(n);
      const js = await readFleetFlag({ DB }, n);
      const sql = db.prepare(`SELECT ${flagActiveSql(n)} AS a`).get(n).a;
      assert.equal(Boolean(sql), Boolean(js && js.active === 1), `flagActiveSql vs readFleetFlag for ${n}`);
    }
  }

  // A ported CLEAR soft-clears the row and writes no pause_flags row.
  plantRow(db, 'paused-c');
  await DB.batch([clearFleetFlagStmt({ DB }, 'paused-c', 'operator', 'fixed', T1)]);
  assert.equal(hrow(db, 'paused-c').cleared_at, T1);
  assert.equal(hrow(db, 'paused-c').reason, 'cleared: fixed');
  assert.equal(prow(db, 'paused-c'), undefined);
  // A ported name that only has a pause_flags row gets a cleared row, which
  // then decides; the pause_flags row is left as it was.
  plantPause(db, 'paused-d', 1);
  await DB.batch([clearFleetFlagStmt({ DB }, 'paused-d', 'operator', 'fixed', T1)]);
  assert.equal(hrow(db, 'paused-d').cleared_at, T1);
  assert.equal((await readFleetFlag({ DB }, 'paused-d')).active, 0);
  assert.equal(prow(db, 'paused-d').active, 1);
  // A non-ported name is the pause_flags statement.
  plantPause(db, 'main-red-x', 1);
  await DB.batch([clearFleetFlagStmt({ DB }, 'main-red-x', 'operator', 'fixed', T1)]);
  assert.equal(prow(db, 'main-red-x').active, 0);
  assert.equal(hrow(db, 'main-red-x'), undefined);
}));
