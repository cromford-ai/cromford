// BH-7325: the migration_reservations table behind POST
// /api/migration-numbers/reserve, its indexes, its retention rule and its seed.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/), the alert-decisions.bh-6972 idiom.
//   W1 the shared fixture body (tests/fixtures/migration-number/) -> 200 {number}
//   W2 a floor above the top reservation -> the floor
//   W3 the same key twice -> the same number, one row, reused true
//   W4 two keys, the same floor -> two numbers (the same-minute case, C2/C3)
//   W5 a key whose row is below a new floor -> moved up past the top
//   W6 a bad project / key / floor -> 400, no row; no bearer -> 401
//   W7 the settings seed row is 30; the route is in the route table
//   W8 EXPLAIN QUERY PLAN on 5,000 rows (50 projects): the top read uses the
//      primary key, the key read idx_migration_reservations_ticket, the
//      retention id read idx_migration_reservations_at (no SCAN)
//   W9 retention migration_reservations.age: dry run counts, a live run deletes
//   W10 GET /api/migration-numbers/holder: the key that holds a number, null
//      for a free one or another project's; bad input 400; no bearer 401
//      (mn_taken asks it so only one of two PRs on one number renumbers)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7325';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FIXTURE = JSON.parse(readFileSync(new URL('../../../tests/fixtures/migration-number/bh-7325-reserve-body.json', import.meta.url), 'utf8'));
const PATH = '/api/migration-numbers/reserve';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function post(DB, body, { bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${PATH}`, {
    method: 'POST',
    headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const rows = (db, project) => db.prepare(
  'SELECT ticket_key, number, floor FROM migration_reservations WHERE project = ? ORDER BY number').all(project).map((r) => ({ ...r }));
const seed = (db, project, key, number, at = ago(0)) => db.prepare(
  'INSERT INTO migration_reservations (project, number, ticket_key, floor, reserved_at) VALUES (?,?,?,?,?)').run(project, number, key, number, at);

test('W1 the shared fixture body reserves its floor', async (t) => {
  const o = await fresh(t); if (!o) return;
  const res = await post(o.DB, FIXTURE);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.number, FIXTURE.floor);
  assert.equal(res.body.reused, false);
  assert.match(res.body.as_of, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.deepEqual(rows(o.db, FIXTURE.project), [{ ticket_key: FIXTURE.ticket_key, number: FIXTURE.floor, floor: FIXTURE.floor }]);
});

test('W2 a floor above the top reservation gives the floor; below it gives top + 1', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, 'p1', 'K-1', 150);
  const hi = await post(o.DB, { project: 'p1', ticket_key: 'K-2', floor: 160 });
  assert.equal(hi.body.number, 160);
  const lo = await post(o.DB, { project: 'p1', ticket_key: 'K-3', floor: 149 });
  assert.equal(lo.body.number, 161);
  // another project's rows do not count
  const other = await post(o.DB, { project: 'p2', ticket_key: 'K-3', floor: 5 });
  assert.equal(other.body.number, 5);
});

test('W3 the same key twice keeps one row and one number', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = await post(o.DB, { project: 'p1', ticket_key: 'K-1', floor: 164 });
  const b = await post(o.DB, { project: 'p1', ticket_key: 'K-1', floor: 164 });
  assert.equal(a.body.number, 164);
  assert.equal(b.body.number, 164);
  assert.equal(b.body.reused, true);
  assert.equal(rows(o.db, 'p1').length, 1);
});

test('W4 two keys with the same floor get two numbers (C2/C3, the same minute)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const [a, b] = await Promise.all([
    post(o.DB, { project: 'project-6-os', ticket_key: 'TK-1149', floor: 164 }),
    post(o.DB, { project: 'project-6-os', ticket_key: 'TK-1150', floor: 164 }),
  ]);
  assert.deepEqual([a.body.number, b.body.number].sort(), [164, 165]);
});

test('W5 a key below a new floor moves up past the top reservation', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, 'p1', 'K-1', 160);
  seed(o.db, 'p1', 'K-2', 170);
  const r = await post(o.DB, { project: 'p1', ticket_key: 'K-1', floor: 165 });
  assert.equal(r.body.number, 171);
  assert.equal(r.body.reused, false);
  assert.deepEqual(rows(o.db, 'p1').map((x) => [x.ticket_key, x.number]), [['K-2', 170], ['K-1', 171]]);
});

test('W6 a bad project, key or floor is a 400 that writes nothing; no bearer is 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  const bad = [
    { ...FIXTURE, project: 'project-6 OS' }, { ...FIXTURE, project: '' }, { ...FIXTURE, project: 7 },
    { ...FIXTURE, ticket_key: 'MK 1' }, { ...FIXTURE, ticket_key: 'x'.repeat(65) }, { ...FIXTURE, ticket_key: undefined },
    { ...FIXTURE, floor: 0 }, { ...FIXTURE, floor: 1000000 }, { ...FIXTURE, floor: '164' }, { ...FIXTURE, floor: 1.5 },
  ];
  for (const b of bad) {
    const r = await post(o.DB, b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal((await post(o.DB, FIXTURE, { bearer: false })).status, 401);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM migration_reservations').get().n, 0);
});

test('W7 the retention settings row is seeded at 30 and the route is pinned', async (t) => {
  const o = await fresh(t); if (!o) return;
  const v = o.db.prepare("SELECT value FROM settings WHERE key = 'retention.migration_reservations.days'").get();
  assert.equal(v && v.value, '30');
  const lines = readFileSync(new URL('./route-table.d/bh-7325-migration-numbers.txt', import.meta.url), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#'));
  assert.deepEqual(lines, [`POST ${PATH}`, 'GET /api/migration-numbers/holder']);
  const k = o.db.prepare("SELECT value FROM settings WHERE key = 'migration_number.reserve'").get();
  assert.equal(k && k.value, '1', 'the kill switch is a settings row, on by default');
});

test('W8 on 5,000 rows every migration_reservations read uses its index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  db.exec('BEGIN');
  const ins = db.prepare('INSERT INTO migration_reservations (project, number, ticket_key, floor, reserved_at) VALUES (?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) ins.run(`proj-${i % 50}`, 100 + Math.floor(i / 50), `K-${i}`, 100, ago((i % 600) / 10));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const top = plan(db, 'SELECT MAX(number) FROM migration_reservations WHERE project = ?1', 'proj-7');
  assert.deepEqual(fullScans(top, ['migration_reservations']), [], top.join(' | '));
  assert.ok(top.some((l) => /USING (COVERING )?INDEX sqlite_autoindex_migration_reservations_1 \(project=\?\)/.test(l)), top.join(' | '));
  const key = plan(db, 'SELECT number, reserved_at FROM migration_reservations WHERE project = ?1 AND ticket_key = ?2', 'proj-7', 'K-7');
  assert.ok(key.some((l) => /USING INDEX idx_migration_reservations_ticket \(project=\? AND ticket_key=\?\)/.test(l)), key.join(' | '));
  const hold = plan(db, 'SELECT ticket_key FROM migration_reservations WHERE project = ?1 AND number = ?2', 'proj-7', 150);
  assert.deepEqual(fullScans(hold, ['migration_reservations']), [], hold.join(' | '));
  assert.ok(hold.some((l) => /USING INDEX sqlite_autoindex_migration_reservations_1 \(project=\? AND number=\?\)/.test(l)), hold.join(' | '));
  const { RULES } = await import('../src/routes/retention.js');
  const r = RULES.find((x) => x.rule === 'migration_reservations.age');
  assert.ok(r, 'the retention rule exists');
  assert.equal(r.table, 'migration_reservations');
  assert.equal(r.key, 'retention.migration_reservations.days');
  assert.equal(r.def, 30);
  const ids = plan(db, r.ids, ago(30), 500);
  assert.deepEqual(fullScans(ids, ['migration_reservations']), [], ids.join(' | '));
  assert.ok(ids.some((l) => /USING (COVERING )?INDEX idx_migration_reservations_at \(reserved_at<\?\)/.test(l)), ids.join(' | '));
  // the reserve itself still answers on the seeded volume
  const res = await post(o.DB, { project: 'proj-7', ticket_key: 'K-new', floor: 1 });
  assert.equal(res.body.number, 200);
});

test('W9 retention migration_reservations.age: a dry run counts rows past 30 days; a live run deletes them', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db, DB } = o;
  seed(db, 'p1', 'old-1', 101, ago(31));
  seed(db, 'p1', 'old-2', 102, ago(90));
  seed(db, 'p1', 'new-1', 103, ago(2));
  const call = (body) => worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET }).then((r) => r.json());
  const dry = await call({ dry_run: true });
  const dr = dry.rules.find((r) => r.rule === 'migration_reservations.age');
  assert.ok(dr, `the rule ran: ${dry.rules.map((r) => r.rule).join(',')}`);
  assert.equal(dr.counted, 2);
  assert.equal(dr.removed, 0);
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run('test', ago(0));
  const live = await call({});
  const lr = live.rules.find((r) => r.rule === 'migration_reservations.age');
  assert.equal(lr.removed, 2);
  assert.equal(lr.error, null);
  assert.deepEqual(rows(db, 'p1').map((r) => r.ticket_key), ['new-1']);
});

test('W10 holder: the key that holds a number, null when none; bad input 400; no bearer 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, 'project-6-os', 'TK-1149', 164);
  seed(o.db, 'other-os', 'OT-1', 165);
  const get = (qs, { bearer = true } = {}) => worker.fetch(new Request(`https://jobs.test/api/migration-numbers/holder?${qs}`, {
    headers: bearer ? { authorization: `Bearer ${SECRET}` } : {},
  }), { DB: o.DB, HARNESS_SECRET: SECRET }).then(async (r) => ({ status: r.status, body: await r.json().catch(() => null) }));
  const held = await get('project=project-6-os&number=164');
  assert.equal(held.status, 200, JSON.stringify(held.body));
  assert.equal(held.body.ticket_key, 'TK-1149');
  assert.equal((await get('project=project-6-os&number=165')).body.ticket_key, null, 'another project holds 165, not this one');
  assert.equal((await get('project=project-6-os&number=999')).body.ticket_key, null);
  for (const qs of ['project=project-6%20OS&number=164', 'number=164', 'project=project-6-os', 'project=project-6-os&number=0',
    'project=project-6-os&number=1000000', 'project=project-6-os&number=1.5', 'project=project-6-os&number=-1']) {
    assert.equal((await get(qs)).status, 400, qs);
  }
  assert.equal((await get('project=project-6-os&number=164', { bearer: false })).status, 401);
});
