// BH-7431 (BH-6896 S4): the pool's once-markers and wait clocks as rows.
// state/pool/<p>/<key>.terminal-noted, .terminal-alerted, .after-since,
// .after-released, .after-loop and .defer-to-human (marker `cap-wait`) each get
// a pool_markers row next to the file. Driven through the REAL router on the
// node:sqlite D1 shim with the composed schema, the pool-state.bh-5001 way. The
// shell side is bin/lib/pool-state-rows.sh (tests/pool-markers-rows.bh-7431-test.sh).
//
//   W1 PUT then GET lists the row; a tab-holding value round-trips byte for byte
//   W2 if_absent keeps the first value; a plain PUT overwrites
//   W3 PATCH clear removes only the named markers of that key
//   W4 400 on bad input, and a 400 writes nothing
//   W5 EXPLAIN QUERY PLAN on 20,000 rows over 40 projects: the GET read and the
//      retention read each use their index; no SCAN pool_markers
//   W6 a GET over 2000 rows says truncated.markers: true
//   W7 retention: a dry run counts a 31-day-old row and deletes nothing; a live
//      run deletes it and keeps a 1-day-old row
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const NOW = Date.now();  // determinism: ok the single anchor; the retention route cuts its window off the server clock
const ago = (days) => new Date(NOW - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const MARKERS = ['terminal-noted', 'terminal-alerted', 'after-since', 'after-released', 'after-loop', 'cap-wait'];

const call = (DB, path, { method = 'GET', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const get = (DB, project) => call(DB, `/api/pool-state?project=${encodeURIComponent(project)}&since=0`);
const put = (DB, body) => call(DB, '/api/pool-state/markers', { method: 'PUT', body });
const patch = (DB, body) => call(DB, '/api/pool-state/markers', { method: 'PATCH', body });
const rows = (db) => db.prepare('SELECT project, ticket_key, marker, value, box FROM pool_markers ORDER BY project, ticket_key, marker')
  .all().map((r) => ({ ...r }));
const seed = (db, project, key, marker, value, updatedAt) => db.prepare(
  'INSERT INTO pool_markers (project, ticket_key, marker, value, box, updated_at) VALUES (?,?,?,?,?,?)',
).run(project, key, marker, value, 'hub', updatedAt);

test('BH-7431 pool markers', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 PUT then GET lists the row; a tab value round-trips byte for byte', async () => {
    const { DB } = await openDb();
    const a = await put(DB, { project: 'alpha-os', key: 'BH-1', marker: 'after-since', value: 'BH-9\t1790000000', box: 'hub' });
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.ok, true);
    const b = await put(DB, { project: 'alpha-os', key: 'BH-1', marker: 'after-loop', value: 'BH-9\t2\t1790000000' });
    assert.equal(b.status, 200, JSON.stringify(b.body));
    const c = await put(DB, { project: 'alpha-os', key: 'BH-2', marker: 'terminal-noted' });
    assert.equal(c.status, 200, JSON.stringify(c.body));
    await put(DB, { project: 'beta-os', key: 'BH-1', marker: 'cap-wait', value: 'x' });
    const g = await get(DB, 'alpha-os');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const byKey = Object.fromEntries(g.body.markers.map((m) => [`${m.key}/${m.marker}`, m.value]));
    assert.deepEqual(Object.keys(byKey).sort(), ['BH-1/after-loop', 'BH-1/after-since', 'BH-2/terminal-noted']);
    assert.equal(byKey['BH-1/after-since'], 'BH-9\t1790000000');
    assert.equal(byKey['BH-1/after-loop'], 'BH-9\t2\t1790000000');
    assert.equal(byKey['BH-2/terminal-noted'], '', 'no value is an empty string, as an empty file');
    assert.deepEqual(Object.keys(g.body.markers[0]).sort(), ['key', 'marker', 'value']);
    assert.equal(g.body.truncated.markers, false);
    assert.equal(g.body.truncated.spawns, false, 'the existing lists are unchanged');
    // Every allowed marker is accepted.
    for (const m of MARKERS) assert.equal((await put(DB, { project: 'gamma-os', key: 'BH-3', marker: m })).status, 200, m);
    assert.equal((await get(DB, 'gamma-os')).body.markers.length, MARKERS.length);
  });

  await t.test('W2 if_absent keeps the first value; a plain PUT overwrites', async () => {
    const { DB, db } = await openDb();
    await put(DB, { project: 'alpha-os', key: 'BH-1', marker: 'after-since', value: 'first' });
    const k = await put(DB, { project: 'alpha-os', key: 'BH-1', marker: 'after-since', value: 'second', if_absent: true });
    assert.equal(k.status, 200, JSON.stringify(k.body));
    assert.equal(rows(db)[0].value, 'first', 'if_absent never overwrites');
    const n = await put(DB, { project: 'alpha-os', key: 'BH-1', marker: 'after-since', value: 'third', box: 'hub-b' });
    assert.equal(n.status, 200);
    assert.deepEqual(rows(db), [{ project: 'alpha-os', ticket_key: 'BH-1', marker: 'after-since', value: 'third', box: 'hub-b' }]);
    const f = await put(DB, { project: 'alpha-os', key: 'BH-2', marker: 'after-since', value: 'new', if_absent: true });
    assert.equal(f.status, 200);
    assert.equal(rows(db).length, 2, 'if_absent writes a row that does not exist');
  });

  await t.test('W3 PATCH clear removes only the named markers of that key', async () => {
    const { DB, db } = await openDb();
    for (const [key, marker] of [['BH-1', 'after-since'], ['BH-1', 'after-released'], ['BH-1', 'after-loop'],
      ['BH-2', 'after-since']]) await put(DB, { project: 'alpha-os', key, marker, value: 'v' });
    await put(DB, { project: 'beta-os', key: 'BH-1', marker: 'after-since', value: 'v' });
    const r = await patch(DB, { project: 'alpha-os', key: 'BH-1', markers: ['after-since', 'after-released'], clear: true });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(rows(db).map((x) => `${x.project}/${x.ticket_key}/${x.marker}`), [
      'alpha-os/BH-1/after-loop', 'alpha-os/BH-2/after-since', 'beta-os/BH-1/after-since']);
    const again = await patch(DB, { project: 'alpha-os', key: 'BH-1', markers: ['after-since'], clear: true });
    assert.equal(again.status, 200, 'a clear of an absent row is not an error');
    assert.equal(rows(db).length, 3);
  });

  await t.test('W4 400 on bad input, and a 400 writes nothing', async () => {
    const { DB, db } = await openDb();
    const ok = { project: 'alpha-os', key: 'BH-1', marker: 'after-since', value: 'v' };
    for (const bad of [
      { ...ok, marker: 'bogus' }, { ...ok, key: 'a b' }, { ...ok, project: 'a b' }, { ...ok, project: undefined },
      { ...ok, key: undefined }, { ...ok, marker: undefined }, { ...ok, value: 'x'.repeat(501) },
      { ...ok, value: 7 }, { ...ok, box: 'a b' },
    ]) {
      const r = await put(DB, bad);
      assert.equal(r.status, 400, `PUT ${JSON.stringify(bad).slice(0, 120)}`);
    }
    assert.equal(rows(db).length, 0, 'a refused PUT writes nothing');
    assert.equal((await put(DB, { ...ok, value: 'x'.repeat(500) })).status, 200, '500 chars is the limit, not over it');
    for (const bad of [
      { project: 'alpha-os', key: 'BH-1', markers: ['after-since'] },
      { project: 'alpha-os', key: 'BH-1', markers: ['after-since'], clear: false },
      { project: 'alpha-os', key: 'BH-1', markers: [], clear: true },
      { project: 'alpha-os', key: 'BH-1', clear: true },
      { project: 'alpha-os', key: 'BH-1', markers: ['after-since', 'bogus'], clear: true },
      { project: 'alpha-os', key: 'a b', markers: ['after-since'], clear: true },
      { project: 'a b', key: 'BH-1', markers: ['after-since'], clear: true },
    ]) {
      const r = await patch(DB, bad);
      assert.equal(r.status, 400, `PATCH ${JSON.stringify(bad)}`);
    }
    assert.equal(rows(db).length, 1, 'a refused PATCH deletes nothing');
  });

  await t.test('W5 EXPLAIN on 20,000 rows over 40 projects: the GET and the retention read use their index', async () => {
    const { db } = await openDb();
    const ins = db.prepare('INSERT INTO pool_markers (project, ticket_key, marker, value, box, updated_at) VALUES (?,?,?,?,?,?)');
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const j = Math.floor(i / 40); // 500 rows a project: 84 keys x 6 markers, each (project, key, marker) once
      ins.run(`p${i % 40}-os`, `BH-${Math.floor(j / 6)}`, MARKERS[j % 6], `BH-${i}\t${1790000000 + i}`, 'hub', ago((i % 60) + j / 1000));
    }
    db.exec('COMMIT');
    assert.equal(db.prepare('SELECT COUNT(*) n FROM pool_markers').get().n, 20000);
    const log = [];
    const DB = capturingD1(db, log);
    const g = await get(DB, 'p7-os');
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.markers.length, 500);
    const hit = log.filter((r) => /FROM pool_markers/.test(r.sql));
    assert.equal(hit.length, 1, 'the GET reads pool_markers once');
    const gl = plan(db, hit[0].sql, ...hit[0].binds);
    assert.ok(gl.some((l) => /USING INDEX idx_pool_markers_project_updated\b/.test(l)), `GET: ${gl.join(' | ')}`);
    assert.ok(!gl.some((l) => /^SCAN pool_markers/.test(l)), `GET: ${gl.join(' | ')}`);
    const { RULES } = await import('../src/routes/retention.js');
    const rule = RULES.find((r) => r.rule === 'pool_markers.age');
    assert.ok(rule, 'retention rule pool_markers.age exists');
    const rl = plan(db, rule.ids, ago(30), 500);
    assert.ok(rl.some((l) => /USING (COVERING )?INDEX idx_pool_markers_updated\b/.test(l)), `retention: ${rl.join(' | ')}`);
    assert.ok(!rl.some((l) => /^SCAN pool_markers/.test(l)), `retention: ${rl.join(' | ')}`);
    const dl = plan(db, rule.del, '[1,2]');
    assert.ok(!dl.some((l) => /^SCAN pool_markers/.test(l)), `retention delete: ${dl.join(' | ')}`);
  });

  await t.test('W6 a GET over 2000 rows says truncated.markers: true', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare('INSERT INTO pool_markers (project, ticket_key, marker, value, box, updated_at) VALUES (?,?,?,?,?,?)');
    db.exec('BEGIN');
    for (let i = 0; i < 2001; i++) ins.run('alpha-os', `BH-${i}`, 'terminal-noted', '', 'hub', ago(i / 10000));
    db.exec('COMMIT');
    const g = await get(DB, 'alpha-os');
    assert.equal(g.status, 200);
    assert.equal(g.body.markers.length, 2000);
    assert.equal(g.body.truncated.markers, true);
    assert.equal(g.body.markers[0].key, 'BH-0', 'the newest row first');
    db.prepare("DELETE FROM pool_markers WHERE ticket_key = 'BH-2000'").run();
    assert.equal((await get(DB, 'alpha-os')).body.truncated.markers, false, 'exactly 2000 is not cut');
  });

  await t.test('W7 retention: dry run counts and deletes nothing; a live run deletes the old row only', async () => {
    const { DB, db } = await openDb();
    const seeded = db.prepare("SELECT value, actor FROM settings WHERE key = 'retention.pool_markers.days'").get();
    assert.deepEqual({ ...seeded }, { value: '30', actor: 'seed' });
    seed(db, 'alpha-os', 'BH-OLD', 'after-since', 'BH-9\t1', ago(31));
    seed(db, 'alpha-os', 'BH-NEW', 'after-since', 'BH-9\t2', ago(1));
    const run = (body) => call(DB, '/api/retention/run', { method: 'POST', body });
    const d = await run({ dry_run: true });
    assert.equal(d.status, 200, JSON.stringify(d.body));
    const dr = d.body.rules.find((r) => r.rule === 'pool_markers.age');
    assert.ok(dr, 'the run reports pool_markers.age');
    assert.equal(dr.counted, 1);
    assert.equal(dr.removed, 0);
    assert.equal(dr.error, null);
    assert.equal(rows(db).length, 2, 'a dry run deletes nothing');
    const audit = db.prepare("SELECT dry_run, counted FROM retention_runs WHERE rule = 'pool_markers.age'").all().map((x) => ({ ...x }));
    assert.deepEqual(audit, [{ dry_run: 1, counted: 1 }], 'one audit row per run');
    db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('retention.dry_run','0','','test',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(ago(0));
    const l = await run({});
    assert.equal(l.status, 200, JSON.stringify(l.body));
    const lr = l.body.rules.find((r) => r.rule === 'pool_markers.age');
    assert.equal(lr.removed, 1);
    assert.equal(lr.error, null);
    assert.deepEqual(rows(db).map((r) => r.ticket_key), ['BH-NEW']);
  });
});
