// BH-7429 (BH-6896 S2): the build record of a pool machine, off the machine.
// POST /api/pool/records (the runner posts RESULT, the build-dir files and the
// failovers.log tail in ONE batch), GET /api/pool/records (the hub reap reads
// it), POST /api/pool/records/reaped (the hub stamps it), the
// pool_record_files table, its seeds and its two retention rules. Driven
// through the REAL worker.fetch on node:sqlite with the composed jobs schema.
//   K1 seeds and indexes      E1 EXPLAIN QUERY PLAN at 20,000 rows
//   P1-P12 the POST rule      G1-G7 the GET read     R1-R2 the reaped stamp
//   T1-T3 retention
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7429';
const SQL = await import('../src/routes/pool-records.js').catch(() => ({}));
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');
const RLINE = 'PR_CREATED https://github.com/o/r/pull/9';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const post = (DB, b) => call(DB, 'POST', '/api/pool/records', b);
const reaped = (DB, b) => call(DB, 'POST', '/api/pool/records/reaped', b);
const get = (DB, q) => call(DB, 'GET', `/api/pool/records?${new URLSearchParams(q)}`);
const rows = (db) => db.prepare('SELECT * FROM pool_record_files ORDER BY id').all();
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-19T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const record = (extra = {}, files = null) => ({
  project: 'project-6-os', key: 'TK-1', machine: 'm1', build_dir: 'project-6-os-TK-1-202610191500',
  files: files ?? [
    { name: 'RESULT', b64: b64(`${RLINE}\nTIER: 2\nBUILD_DIR: /data/harness/builds/project-6-os-TK-1-202610191500\n`) },
    { name: 'review.md', b64: b64('VERDICT: APPROVE\n') },
    { name: 'pipeline.log', skipped: true, bytes: 1500000 },
  ],
  ...extra,
});
const since = '2000-01-01T00:00:00Z';

test('K1 the schema seeds both retention windows, the project-6-os knob row and the four indexes', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  const v = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
  assert.equal(v('retention.pool_record_files.reaped_days'), '1');
  assert.equal(v('retention.pool_record_files.unread_days'), '3');
  assert.equal(v('lane.fly-pool.project-6-os.pool_record_read'), '1');
  assert.equal(v('lane.fly-pool.pool_record_read'), undefined, 'no lane-wide row: every other project stays on ssh');
  const ix = db.prepare("SELECT name, \"unique\" AS u, partial FROM pragma_index_list('pool_record_files')").all();
  const by = Object.fromEntries(ix.map((r) => [r.name, r]));
  assert.equal(by.uq_pool_record_files_file?.u, 1);
  assert.ok(by.idx_pool_record_files_result);
  assert.equal(by.idx_pool_record_files_reaped?.partial, 1);
  assert.equal(by.idx_pool_record_files_unread?.partial, 1);
});

test('P1 a fresh record: 200, one row per file, bodies and byte counts stored, skipped row has no body', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, record());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.recorded, true); assert.equal(r.body.files, 3); assert.equal(r.body.skipped, 1);
  const x = rows(o.db);
  assert.equal(x.length, 3);
  const by = Object.fromEntries(x.map((y) => [y.name, y]));
  assert.equal(Buffer.from(by.RESULT.body, 'base64').toString().split('\n')[0], RLINE);
  assert.equal(by['review.md'].bytes, 17); assert.equal(by['review.md'].skipped, 0);
  assert.equal(by['pipeline.log'].body, null); assert.equal(by['pipeline.log'].skipped, 1); assert.equal(by['pipeline.log'].bytes, 1500000);
  for (const y of x) {
    assert.equal(y.project, 'project-6-os'); assert.equal(y.ticket_key, 'TK-1'); assert.equal(y.machine, 'm1');
    assert.equal(y.build_dir, 'project-6-os-TK-1-202610191500'); assert.equal(y.reaped_at, null);
    assert.match(y.posted_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  }
});

const BAD = [
  ['P2 bad project', record({ project: 'a b' })],
  ['P2 bad key', record({ key: '' })],
  ['P2 bad machine', record({ machine: 'm/1' })],
  ['P3 build_dir with a slash', record({ build_dir: 'x/y' })],
  ['P3 build_dir ..', record({ build_dir: '..' })],
  ['P4 no RESULT', record({}, [{ name: 'review.md', b64: b64('x') }])],
  ['P4 RESULT skipped', record({}, [{ name: 'RESULT', skipped: true, bytes: 9 }])],
  ['P4 RESULT empty', record({}, [{ name: 'RESULT', b64: '' }])],
  ['P5 name ../x', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: '../x', b64: b64('x') }])],
  ['P5 name a/b', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: 'a/b', b64: b64('x') }])],
  ['P5 name .hidden', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: '.hidden', b64: b64('x') }])],
  ['P6 duplicate name', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: 'RESULT', b64: b64(RLINE) }])],
  ['P7 41 files', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, ...Array.from({ length: 40 }, (_, i) => ({ name: `f${i}`, b64: b64('x') }))])],
  ['P8 not base64', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: 'review.md', b64: 'not*base64!' }])],
  ['P8 bad padding', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: 'review.md', b64: 'abc' }])],
  ['P9 b64 of 1,900,001 chars', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: 'review.md', b64: 'A'.repeat(1900001) }])],
  ['P9 skipped with no byte count', record({}, [{ name: 'RESULT', b64: b64(RLINE) }, { name: 'review.md', skipped: true }])],
  ['P9 files not an array', record({ files: 'RESULT' })],
];
for (const [name, b] of BAD) {
  test(`${name}: 400 and nothing written`, async (t) => {
    const o = await fresh(t); if (!o) return;
    const r = await post(o.DB, b);
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.equal(rows(o.db).length, 0);
  });
}

test('P7b exactly 40 files is accepted', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await post(o.DB, record({}, [{ name: 'RESULT', b64: b64(RLINE) }, ...Array.from({ length: 39 }, (_, i) => ({ name: `f${i}`, b64: b64('x') }))]));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rows(o.db).length, 40);
});

test('P10 a re-post before the reap replaces the record: new bodies, files absent from it are gone', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  const r = await post(o.DB, record({}, [{ name: 'RESULT', b64: b64(`${RLINE}\nTIER: 1\n`) }, { name: 'review.md', b64: b64('VERDICT: BLOCK\n') }]));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const x = rows(o.db);
  assert.deepEqual(x.map((y) => y.name).sort(), ['RESULT', 'review.md']);
  assert.equal(Buffer.from(x.find((y) => y.name === 'review.md').body, 'base64').toString(), 'VERDICT: BLOCK\n');
});

test('P11 a re-post after the reap: 409 already_reaped, nothing changes', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  const rec = record();
  assert.equal((await reaped(o.DB, { project: rec.project, key: rec.key, machine: rec.machine, build_dir: rec.build_dir })).body.reaped, 3);
  const before = rows(o.db);
  const r = await post(o.DB, record({}, [{ name: 'RESULT', b64: b64('BUILD_ERROR x\n') }, { name: 'new.md', b64: b64('x') }]));
  assert.equal(r.status, 409, JSON.stringify(r.body)); assert.equal(r.body.reason, 'already_reaped');
  assert.deepEqual(rows(o.db), before);
});

test('P12 two machines of one key are two records', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  assert.equal((await post(o.DB, record({ machine: 'm2' }))).status, 200);
  assert.equal(rows(o.db).length, 6);
  const g = await get(o.DB, { project: 'project-6-os', key: 'TK-1', machine: 'm2', since });
  assert.equal(g.status, 200); assert.equal(g.body.record.machine, 'm2');
});

test('G1 the GET answers the record at or after since, with every file', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  const at = rows(o.db)[0].posted_at;
  const g = await get(o.DB, { project: 'project-6-os', key: 'TK-1', machine: 'm1', since: at });
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.equal(g.body.record.build_dir, 'project-6-os-TK-1-202610191500');
  assert.equal(g.body.record.machine, 'm1'); assert.equal(g.body.record.posted_at, at);
  const f = Object.fromEntries(g.body.record.files.map((y) => [y.name, y]));
  assert.deepEqual(Object.keys(f).sort(), ['RESULT', 'pipeline.log', 'review.md']);
  assert.equal(Buffer.from(f['review.md'].body, 'base64').toString(), 'VERDICT: APPROVE\n');
  assert.equal(f['review.md'].bytes, 17);
});

test('G2 since after the record: 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  const g = await get(o.DB, { project: 'project-6-os', key: 'TK-1', machine: 'm1', since: '2999-01-01T00:00:00Z' });
  assert.equal(g.status, 404);
});

test('G3 another machine, another key or another project: 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  for (const q of [{ machine: 'm9' }, { key: 'TK-2' }, { project: 'project-5' }]) {
    const g = await get(o.DB, { project: 'project-6-os', key: 'TK-1', machine: 'm1', since, ...q });
    assert.equal(g.status, 404, JSON.stringify(q));
  }
});

test('G4 a skipped file comes back skipped:1 with a null body and its byte count', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  const g = await get(o.DB, { project: 'project-6-os', key: 'TK-1', machine: 'm1', since });
  const s = g.body.record.files.find((y) => y.name === 'pipeline.log');
  assert.equal(s.skipped, 1); assert.equal(s.body, null); assert.equal(s.bytes, 1500000);
});

test('G5 since missing or not YYYY-MM-DDTHH:MM:SSZ, or a bad key: 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const s of [undefined, '', '2026-10-19 15:45:00Z', '2026-10-19T15:45:00+00:00', 'yesterday']) {
    const q = { project: 'project-6-os', key: 'TK-1', machine: 'm1' };
    if (s !== undefined) q.since = s;
    assert.equal((await get(o.DB, q)).status, 400, String(s));
  }
  assert.equal((await get(o.DB, { project: 'project-6-os', key: 'a b', machine: 'm1', since })).status, 400);
});

test('G6 two records of one machine: the newer one', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record({ build_dir: 'old-dir' }))).status, 200);
  o.db.prepare("UPDATE pool_record_files SET posted_at='2026-10-01T00:00:00Z'").run();
  assert.equal((await post(o.DB, record({ build_dir: 'new-dir' }))).status, 200);
  const g = await get(o.DB, { project: 'project-6-os', key: 'TK-1', machine: 'm1', since });
  assert.equal(g.body.record.build_dir, 'new-dir');
  assert.ok(g.body.record.files.length === 3);
});

test('G7 the same key on a reused machine, inside the skew window: a reaped record is never the answer', async (t) => {
  const o = await fresh(t); if (!o) return;
  const q = { project: 'project-6-os', key: 'TK-1', machine: 'm1' };
  // Job 1 posts BUILD_DEFERRED; the hub reaps it and stamps it reaped.
  assert.equal((await post(o.DB, record())).status, 200);
  const at = rows(o.db)[0].posted_at;
  assert.equal((await reaped(o.DB, { ...q, build_dir: 'project-6-os-TK-1-202610191500' })).body.reaped, 3);
  // The handoff gives TK-1 back to m1; the next tick asks with since inside the skew window.
  const g = await get(o.DB, { ...q, since: at });
  assert.equal(g.status, 404, `a reaped record must not read as the live job's RESULT: ${JSON.stringify(g.body)}`);
  // Job 2 posts its own record: that one is the answer.
  assert.equal((await post(o.DB, record({ build_dir: 'project-6-os-TK-1-202610191530' }))).status, 200);
  const g2 = await get(o.DB, { ...q, since: at });
  assert.equal(g2.status, 200, JSON.stringify(g2.body));
  assert.equal(g2.body.record.build_dir, 'project-6-os-TK-1-202610191530');
});

test('R1 the stamp marks only that record; R2 a second stamp is reaped:0', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await post(o.DB, record())).status, 200);
  assert.equal((await post(o.DB, record({ machine: 'm2' }))).status, 200);
  const q = { project: 'project-6-os', key: 'TK-1', machine: 'm1', build_dir: 'project-6-os-TK-1-202610191500' };
  const r = await reaped(o.DB, q);
  assert.equal(r.status, 200); assert.equal(r.body.reaped, 3);
  const x = rows(o.db);
  assert.ok(x.filter((y) => y.machine === 'm1').every((y) => y.reaped_at !== null));
  assert.ok(x.filter((y) => y.machine === 'm2').every((y) => y.reaped_at === null));
  const r2 = await reaped(o.DB, q);
  assert.equal(r2.status, 200); assert.equal(r2.body.reaped, 0);
  assert.equal((await reaped(o.DB, { ...q, build_dir: '' })).status, 400);
});

// Rows written straight into the table for the retention cases.
function seedRow(db, name, postedAt, reapedAt) {
  db.prepare(`INSERT INTO pool_record_files (project, ticket_key, machine, build_dir, name, body, bytes, skipped, posted_at, reaped_at)
              VALUES ('p1','K-1','m1','d1',?, 'eA==', 1, 0, ?, ?)`).run(name, postedAt, reapedAt);
}
// The retention route cuts off at its own server clock, so the seeded ages are
// offsets from one anchor taken here.
const NOW_MS = Date.now(); // determinism: ok the single anchor; the route under test reads the real clock
const isoAgo = (days) => new Date(NOW_MS - days * 86400e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const runRetention = (DB) => call(DB, 'POST', '/api/retention/run', {});

test('T1 the reaped rule deletes a row reaped 2 days ago and keeps one reaped today', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, 'old', isoAgo(2), isoAgo(2));
  seedRow(o.db, 'new', isoAgo(2), isoAgo(0));
  setting(o.db, 'retention.dry_run', 0);
  const r = await runRetention(o.DB);
  assert.equal(r.status, 200);
  const rule = r.body.rules.find((x) => x.rule === 'pool_record_files.reaped');
  assert.ok(rule, 'the reaped rule ran'); assert.equal(rule.removed, 1); assert.equal(rule.error, null);
  assert.deepEqual(rows(o.db).map((y) => y.name), ['new']);
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM retention_runs WHERE rule='pool_record_files.reaped'").get().n, 1);
});

test('T2 the unread rule deletes a row posted 4 days ago and keeps an unread row of 1 day', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, 'stale', isoAgo(4), null);
  seedRow(o.db, 'fresh', isoAgo(1), null);
  setting(o.db, 'retention.dry_run', 0);
  const r = await runRetention(o.DB);
  const rule = r.body.rules.find((x) => x.rule === 'pool_record_files.unread');
  assert.ok(rule, 'the unread rule ran'); assert.equal(rule.removed, 1); assert.equal(rule.error, null);
  assert.deepEqual(rows(o.db).map((y) => y.name), ['fresh']);
});

test('T3 a dry run (the seed) counts and deletes nothing', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, 'old', isoAgo(2), isoAgo(2));
  seedRow(o.db, 'stale', isoAgo(4), null);
  const r = await runRetention(o.DB);
  assert.equal(r.body.dry_run, true);
  assert.equal(r.body.rules.find((x) => x.rule === 'pool_record_files.reaped').counted, 1);
  assert.equal(r.body.rules.find((x) => x.rule === 'pool_record_files.unread').counted, 1);
  assert.equal(rows(o.db).length, 2);
});

test('E1 at 20,000 rows (500 records x 40 files) every record statement uses its named index, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.ok(SQL.RESULT_READ_SQL && SQL.FILES_READ_SQL && SQL.STAMP_SQL && SQL.INSERT_SQL && SQL.CLEAR_SQL, 'the route exports its SQL');
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO pool_record_files (project, ticket_key, machine, build_dir, name, body, bytes, skipped, posted_at, reaped_at)
                          VALUES (?,?,?,?,?,'eA==',1,0,?,?)`);
  for (let r = 0; r < 500; r++) {
    const p = `p${r % 7}`, k = `K-${r}`, m = `m${r % 50}`, d = `d-${r}`;
    const at = `2026-10-${String(1 + (r % 28)).padStart(2, '0')}T00:00:00Z`;
    for (let f = 0; f < 40; f++) ins.run(p, k, m, d, f === 0 ? 'RESULT' : `f${f}`, at, r % 3 === 0 ? null : at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const T = '2026-10-19T10:00:00Z';
  const { RULES } = await import('../src/routes/retention.js');
  const rule = (n) => RULES.find((x) => x.rule === n);
  assert.ok(rule('pool_record_files.reaped') && rule('pool_record_files.unread'), 'both retention rules exist');
  const plans = {
    result_read: plan(db, SQL.RESULT_READ_SQL, 'p1', 'K-1', 'm1', T),
    files_read: plan(db, SQL.FILES_READ_SQL, 'p1', 'K-1', 'm1', 'd-1'),
    clear: plan(db, SQL.CLEAR_SQL, 'p1', 'K-1', 'm1', 'd-1'),
    insert: plan(db, SQL.INSERT_SQL, 'p1', 'K-1', 'm1', 'd-1', 'RESULT', 'eA==', 1, 0, T),
    stamp: plan(db, SQL.STAMP_SQL, 'p1', 'K-1', 'm1', 'd-1', T),
    ret_reaped: plan(db, rule('pool_record_files.reaped').ids, T, 500),
    ret_unread: plan(db, rule('pool_record_files.unread').ids, T, 500),
    ret_del: plan(db, rule('pool_record_files.reaped').del, '[1,2]'),
  };
  for (const [name, lines] of Object.entries(plans)) {
    assert.deepEqual(fullScans(lines, ['pool_record_files']), [], `${name}: ${lines.join(' | ')}`);
  }
  const uses = (name, ix) => assert.ok(plans[name].some((x) => x.includes(ix)), `${name}: ${plans[name].join(' | ')}`);
  uses('result_read', 'idx_pool_record_files_result');
  uses('files_read', 'uq_pool_record_files_file');
  uses('clear', 'uq_pool_record_files_file');
  uses('stamp', 'uq_pool_record_files_file');
  uses('ret_reaped', 'idx_pool_record_files_reaped');
  uses('ret_unread', 'idx_pool_record_files_unread');
});
