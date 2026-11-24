// BH-9075 (BH-9067.3): the parks routes, PUT /api/parks, GET /api/parks/changed,
// GET /api/parks/prune and POST /api/parks/prune, on the `parks` table. Driven
// through the REAL worker.fetch (the route-table fragment is the registration)
// on node:sqlite with the composed jobs schema. Each case opens its own
// database and uses its own project ids.
//   P1 round-trip of the 12 fields; a '-' field on update keeps the old value
//   P2 an older write loses (upserted 0)
//   P3 100 rows = 1 write statement; 101 rows and bad rows are a 400
//   P4 strict since, other project absent, order (updated_at, ck)
//   P5 keyset paging over a shared updated_at at the page boundary
//   P6 GET and POST prune with the seed dry run: 0 deleted, 1 audit row each
//   P7 the 6 seed rows
//   P8 a real prune deletes only old done rows, at most retention_batch
//   P9 hotfix=1 returns the hotfix rows older than since
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh9075';
const NOW_MS = Date.parse('2026-11-17T06:00:00Z');
const NOW_S = NOW_MS / 1000;
const DAY = 86400;

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.headers['content-type'] = 'application/json';
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
  }
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => {
      const text = await res.text();
      let json = null; try { json = JSON.parse(text); } catch { json = null; }
      return { status: res.status, text, body: json };
    });
}
const put = (DB, rows) => call(DB, 'PUT', '/api/parks', { rows });
const changed = (DB, q) => call(DB, 'GET', `/api/parks/changed?${new URLSearchParams(q)}`);
const row = (project, ck, updated_at, extra = {}) => ({
  project, ck, source: 'queue', state: 'parked', head: `h-${ck}`, reason: `r-${ck}`,
  url: `https://github.com/o/r/pull/${updated_at}`, rec: `rec-${ck}`, ticket: `T-${ck}`,
  updated_at, writer: 'fly-pool', parked_at: updated_at - 5, ...extra,
});
const auditRows = (db) => db.prepare("SELECT * FROM retention_runs WHERE rule='parks.done' ORDER BY id").all();
const setSetting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','test','2026-11-17T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);

test('P1 PUT 3 rows, GET changed since=0 returns the 12 fields as sent; a "-" field on update keeps the old value', async (t) => {
  const o = await fresh(t); if (!o) return;
  const sent = [row('p1-a', 'ck-1', 100), row('p1-a', 'ck-2', 101, { state: 'hotfix', source: 'conductor' }), row('p1-a', 'ck-3', 102, { parked_at: null })];
  const r = await put(o.DB, sent);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.upserted, 3);
  assert.equal(typeof r.body.as_of, 'string');
  const g = await changed(o.DB, { project: 'p1-a', since: '0' });
  assert.equal(g.status, 200, g.text);
  assert.deepEqual(g.body.rows, sent);
  assert.equal(g.body.next, '102:ck-3');
  assert.equal(g.body.truncated, false);
  // Update ck-1 with '-' in head/reason/url and no parked_at: those keep the old value.
  const u = await put(o.DB, [{ project: 'p1-a', ck: 'ck-1', source: '-', state: 'done', head: '-', reason: '-', url: '-', rec: 'rec-new', ticket: '-', updated_at: 150, writer: 'blocked-resolver', parked_at: null }]);
  assert.equal(u.body.upserted, 1, u.text);
  const g2 = await changed(o.DB, { project: 'p1-a', since: '102' });
  assert.deepEqual(g2.body.rows, [{ ...sent[0], state: 'done', rec: 'rec-new', updated_at: 150, writer: 'blocked-resolver' }]);
  // Omitted text fields default to '-'.
  await put(o.DB, [{ project: 'p1-b', ck: 'x', state: 'parked', updated_at: 5 }]);
  const g3 = await changed(o.DB, { project: 'p1-b', since: '0' });
  assert.deepEqual(g3.body.rows, [{ project: 'p1-b', ck: 'x', source: '-', state: 'parked', head: '-', reason: '-', url: '-', rec: '-', ticket: '-', updated_at: 5, writer: '-', parked_at: null }]);
});

test('P2 an older write for the same ck loses: the t=200 values stay, upserted 0', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = await put(o.DB, [row('p2-a', 'X', 200, { reason: 'new' })]);
  assert.equal(a.body.upserted, 1, a.text);
  const b = await put(o.DB, [row('p2-a', 'X', 100, { reason: 'old', state: 'done' })]);
  assert.equal(b.status, 200, b.text);
  assert.equal(b.body.upserted, 0);
  const g = await changed(o.DB, { project: 'p2-a', since: '0' });
  assert.equal(g.body.rows.length, 1);
  assert.equal(g.body.rows[0].updated_at, 200);
  assert.equal(g.body.rows[0].reason, 'new');
  assert.equal(g.body.rows[0].state, 'parked');
  // An equal updated_at still wins (>=), so a replay of the same write is idempotent.
  const c = await put(o.DB, [row('p2-a', 'X', 200, { reason: 'same-ts' })]);
  assert.equal(c.body.upserted, 1);
});

test('P3 100 rows = upserted 100 in exactly 1 write statement; 101 rows and bad rows = 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  let writes = 0;
  const DB = {
    prepare(sql) {
      if (/^\s*(INSERT|UPDATE|DELETE)\b/i.test(sql) && /\bparks\b/.test(sql)) writes++;
      return o.DB.prepare(sql);
    },
    batch: (s) => o.DB.batch(s),
  };
  const rows = Array.from({ length: 100 }, (_, i) => row('p3-a', `ck-${i}`, 1000 + i));
  const r = await put(DB, rows);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.upserted, 100);
  assert.equal(writes, 1, 'one json_each statement, not one per row');
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM parks WHERE project='p3-a'").get().n, 100);

  writes = 0;
  const good = row('p3-b', 'ok', 10);
  const bad = [
    Array.from({ length: 101 }, (_, i) => row('p3-b', `c-${i}`, 10 + i)),
    [],
    [{ ...good, state: 'gone' }],
    [{ ...good, ck: 'bad ck' }], [{ ...good, ck: '' }], [{ ...good, ck: 'c'.repeat(201) }],
    [{ ...good, updated_at: 1.5 }], [{ ...good, updated_at: '10' }], [{ ...good, updated_at: 0 }],
    [{ ...good, project: 'P3_B' }], [{ ...good, project: 'p'.repeat(65) }],
    [{ ...good, source: 'Queue' }], [{ ...good, source: 'q'.repeat(25) }],
    [{ ...good, parked_at: 'x' }], [{ ...good, reason: 'r'.repeat(501) }], [{ ...good, head: 7 }],
    [good, 'not-a-row'],
  ];
  for (const b of bad) {
    const x = await put(DB, b);
    assert.equal(x.status, 400, `accepted ${JSON.stringify(b).slice(0, 120)}`);
    assert.equal(typeof x.body.error, 'string');
  }
  for (const raw of ['[1,2]', '"x"', 'null', '{"rows":"x"}']) {
    const x = await call(DB, 'PUT', '/api/parks', raw);
    assert.equal(x.status, 400, `accepted body ${raw}`);
  }
  assert.equal(writes, 0, 'a bad batch runs no write');
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM parks WHERE project='p3-b'").get().n, 0);
  // The legal edges stay legal.
  const e = await put(DB, [{ ...good, ck: 'c'.repeat(200), reason: 'r'.repeat(500), project: 'p'.repeat(64), source: '-' }]);
  assert.equal(e.status, 200, e.text);
});

test('P4 since=<ts> excludes rows at exactly ts; another project is absent; order is (updated_at, ck)', async (t) => {
  const o = await fresh(t); if (!o) return;
  // 60 rows: updated_at 100..119, three cks per ts, inserted in a shuffled order.
  const rows = [];
  for (let i = 0; i < 60; i++) rows.push(row('p4-a', `ck-${String.fromCharCode(99 - (i % 3))}-${i}`, 100 + Math.floor(i / 3)));
  rows.reverse();
  assert.equal((await put(o.DB, rows)).body.upserted, 60);
  await put(o.DB, [row('p4-other', 'ck-zz', 115), row('p4-other', 'ck-yy', 200)]);
  const g = await changed(o.DB, { project: 'p4-a', since: '110' });
  assert.equal(g.status, 200, g.text);
  assert.ok(g.body.rows.every((r) => r.project === 'p4-a'), 'another project leaked in');
  assert.ok(g.body.rows.every((r) => r.updated_at > 110), 'a row at exactly since was returned');
  assert.equal(g.body.rows.length, 27);
  const keys = g.body.rows.map((r) => [r.updated_at, r.ck]);
  const sorted = [...keys].sort((a, b) => a[0] - b[0] || (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
  assert.deepEqual(keys, sorted);
  // No rows: next echoes the since it was sent.
  const e = await changed(o.DB, { project: 'p4-a', since: '119' });
  assert.deepEqual(e.body.rows, []);
  assert.equal(e.body.next, '119');
  assert.equal(e.body.truncated, false);
  // Bad query input is a 400.
  for (const q of [{ since: '0' }, { project: 'P4', since: '0' }, { project: 'p4-a' }, { project: 'p4-a', since: 'x' },
    { project: 'p4-a', since: '1:bad ck' }, { project: 'p4-a', since: '0', limit: '0' }, { project: 'p4-a', since: '0', limit: '1001' },
    { project: 'p4-a', since: '0', limit: '2.5' }]) {
    const b = await changed(o.DB, q);
    assert.equal(b.status, 400, `accepted ${JSON.stringify(q)}`);
  }
});

test('P5 limit 25 over 37 rows: 25 + truncated, then 12 via next; 5 rows sharing one ts across the boundary', async (t) => {
  const o = await fresh(t); if (!o) return;
  // Rows 0..21 at ts 100+i; rows 22..26 share ts 500 (the boundary is inside
  // them: the page ends at row 24); rows 27..36 at ts 600+i.
  const rows = [];
  for (let i = 0; i < 22; i++) rows.push(row('p5-a', `a-${String(i).padStart(2, '0')}`, 100 + i));
  for (let i = 0; i < 5; i++) rows.push(row('p5-a', `b-${i}`, 500));
  for (let i = 0; i < 10; i++) rows.push(row('p5-a', `c-${i}`, 600 + i));
  assert.equal((await put(o.DB, rows)).body.upserted, 37);
  const p1 = await changed(o.DB, { project: 'p5-a', since: '0', limit: '25' });
  assert.equal(p1.status, 200, p1.text);
  assert.equal(p1.body.rows.length, 25);
  assert.equal(p1.body.truncated, true);
  assert.equal(p1.body.next, '500:b-2');
  const p2 = await changed(o.DB, { project: 'p5-a', since: p1.body.next, limit: '25' });
  assert.equal(p2.status, 200, p2.text);
  assert.equal(p2.body.rows.length, 12);
  assert.equal(p2.body.truncated, false);
  const seen = [...p1.body.rows, ...p2.body.rows].map((r) => r.ck);
  assert.equal(new Set(seen).size, 37, 'a row was repeated or missed');
  assert.deepEqual(new Set(seen), new Set(rows.map((r) => r.ck)));
  // Without limit the default is parks.changed_max_limit (1000): one page.
  const all = await changed(o.DB, { project: 'p5-a', since: '0' });
  assert.equal(all.body.rows.length, 37);
  assert.equal(all.body.truncated, false);
});

test('P6 GET and POST prune with the seed prune_dry_run=1 delete 0 rows and each write 1 retention_runs row', async (t) => {
  const o = await fresh(t); if (!o) return;
  const old = NOW_S - 40 * DAY, recent = NOW_S - DAY;
  await put(o.DB, [
    row('p6-a', 'd1', old, { state: 'done' }), row('p6-a', 'd2', old + 1, { state: 'done' }), row('p6-b', 'd3', old, { state: 'done' }),
    row('p6-a', 'd4', recent, { state: 'done' }), row('p6-a', 'k1', old), row('p6-a', 'h1', old, { state: 'hotfix' }),
  ]);
  const g = await call(o.DB, 'GET', '/api/parks/prune');
  assert.equal(g.status, 200, g.text);
  assert.equal(g.body.dry_run, true);
  assert.equal(g.body.counted, 3);
  assert.equal(g.body.removed, 0);
  assert.equal(g.body.backlog, false);
  assert.equal(typeof g.body.run_id, 'string');
  assert.equal(auditRows(o.db).length, 1);
  // A body asking for a real run cannot force one while the setting is 1.
  const p = await call(o.DB, 'POST', '/api/parks/prune', { dry_run: false });
  assert.equal(p.status, 200, p.text);
  assert.equal(p.body.dry_run, true);
  assert.equal(p.body.removed, 0);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM parks').get().n, 6);
  const a = auditRows(o.db);
  assert.equal(a.length, 2);
  for (const r of a) {
    assert.equal(r.tbl, 'parks');
    assert.equal(r.dry_run, 1);
    assert.equal(r.counted, 3);
    assert.equal(r.removed, 0);
    assert.equal(r.backlog, 0);
    assert.equal(r.error, null);
    assert.equal(r.cutoff, new Date((NOW_S - 30 * DAY) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'));
  }
  // retention_days 0: the rule is off, still one audit row, error 'off'.
  setSetting(o.db, 'parks.retention_days', '0');
  const off = await call(o.DB, 'POST', '/api/parks/prune', {});
  assert.equal(off.status, 200, off.text);
  assert.equal(off.body.counted, 0);
  assert.equal(off.body.removed, 0);
  const last = auditRows(o.db).at(-1);
  assert.equal(auditRows(o.db).length, 3);
  assert.equal(last.error, 'off');
});

test('P7 the seed rows exist with the values 30/500/1/100/1000/50', async (t) => {
  const o = await fresh(t); if (!o) return;
  const want = {
    'parks.retention_days': '30', 'parks.retention_batch': '500', 'parks.prune_dry_run': '1',
    'parks.put_max_rows': '100', 'parks.changed_max_limit': '1000', 'parks.hotfix_max': '50',
  };
  const got = Object.fromEntries(o.db.prepare("SELECT key, value, note FROM settings WHERE key LIKE 'parks.%' ORDER BY key").all().map((r) => [r.key, r.value]));
  assert.deepEqual(got, want);
  for (const r of o.db.prepare("SELECT key, note FROM settings WHERE key LIKE 'parks.%'").all()) {
    assert.match(r.note, /routes\/parks\.js/, `${r.key} note names no reader`);
  }
});

test('P8 with prune_dry_run=0 POST deletes only old done rows, at most retention_batch; backlog when the batch is hit', async (t) => {
  const o = await fresh(t); if (!o) return;
  setSetting(o.db, 'parks.prune_dry_run', '0');
  setSetting(o.db, 'parks.retention_batch', '4');
  const old = NOW_S - 40 * DAY, recent = NOW_S - DAY;
  const rows = [];
  for (let i = 0; i < 6; i++) rows.push(row('p8-a', `old-done-${i}`, old + i, { state: 'done' }));
  rows.push(row('p8-a', 'new-done', recent, { state: 'done' }));
  rows.push(row('p8-a', 'old-parked', old), row('p8-a', 'old-hotfix', old, { state: 'hotfix' }));
  await put(o.DB, rows);
  const a = await call(o.DB, 'POST', '/api/parks/prune', {});
  assert.equal(a.status, 200, a.text);
  assert.equal(a.body.dry_run, false);
  assert.equal(a.body.removed, 4);
  assert.equal(a.body.backlog, true);
  // The oldest go first.
  const left = o.db.prepare("SELECT ck FROM parks WHERE project='p8-a' ORDER BY ck").all().map((r) => r.ck);
  assert.deepEqual(left, ['new-done', 'old-done-4', 'old-done-5', 'old-hotfix', 'old-parked']);
  const b = await call(o.DB, 'POST', '/api/parks/prune', {});
  assert.equal(b.body.removed, 2);
  assert.equal(b.body.backlog, false);
  const left2 = o.db.prepare("SELECT ck FROM parks WHERE project='p8-a' ORDER BY ck").all().map((r) => r.ck);
  assert.deepEqual(left2, ['new-done', 'old-hotfix', 'old-parked']);
  const audit = auditRows(o.db);
  assert.equal(audit.length, 2);
  assert.deepEqual(audit.map((r) => [r.dry_run, r.removed, r.backlog]), [[0, 4, 1], [0, 2, 0]]);
  // A body can still ask for a dry run.
  const d = await call(o.DB, 'POST', '/api/parks/prune', { dry_run: true });
  assert.equal(d.body.dry_run, true);
  assert.equal(d.body.removed, 0);
  // GET is always a dry run, even with the setting at 0.
  const g = await call(o.DB, 'GET', '/api/parks/prune');
  assert.equal(g.body.dry_run, true);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM parks WHERE project='p8-a'").get().n, 3);
});

test('P9 hotfix=1 returns the project hotfix rows even when they are older than since', async (t) => {
  const o = await fresh(t); if (!o) return;
  await put(o.DB, [
    row('p9-a', 'h1', 10, { state: 'hotfix' }), row('p9-a', 'h2', 20, { state: 'hotfix' }),
    row('p9-a', 'k1', 30), row('p9-a', 'k2', 300),
    row('p9-b', 'h9', 5, { state: 'hotfix' }),
  ]);
  const g = await changed(o.DB, { project: 'p9-a', since: '100', hotfix: '1' });
  assert.equal(g.status, 200, g.text);
  assert.deepEqual(g.body.rows.map((r) => r.ck), ['k2']);
  assert.deepEqual(g.body.hotfix.map((r) => r.ck), ['h1', 'h2']);
  assert.ok(g.body.hotfix.every((r) => r.state === 'hotfix' && r.project === 'p9-a'));
  // Without hotfix=1 there is no hotfix key.
  const n = await changed(o.DB, { project: 'p9-a', since: '100' });
  assert.equal('hotfix' in n.body, false);
  // parks.hotfix_max caps the list.
  setSetting(o.db, 'parks.hotfix_max', '1');
  const c = await changed(o.DB, { project: 'p9-a', since: '100', hotfix: '1' });
  assert.deepEqual(c.body.hotfix.map((r) => r.ck), ['h1']);
});

test('P0 every parks route is bearer-gated', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [m, p] of [['PUT', '/api/parks'], ['GET', '/api/parks/changed?project=x'], ['GET', '/api/parks/prune'], ['POST', '/api/parks/prune']]) {
    const res = await worker.fetch(new Request(`https://jobs.test${p}`, { method: m, ...(m === 'GET' ? {} : { body: '{}' }) }), { DB: o.DB, HARNESS_SECRET: SECRET });
    assert.equal(res.status, 401, `${m} ${p} answered without the bearer`);
  }
});
