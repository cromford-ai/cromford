import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaFile } from './lib/jobs-schema.js';

// BH-3448 (BH-3434.1): the hub_probe_requests ledger and its routes, driven
// through the worker's real fetch handler against node:sqlite running the
// shipped schema.sql.
//   POST /api/hub-probe            request once: {created, row}
//   POST /api/hub-probe/claim      at most n pending -> claimed, atomically
//   POST /api/hub-probe/result     claimed -> pass|fail|rejected, or back to pending with a note
//   POST /api/hub-probe/commented  stamp commented_at where it is NULL
//   GET  /api/hub-probe            one ticket's rows
//   GET  /api/hub-probe/count-today  today's claims of one probe
// The shapes asserted are the ones bin/lib/jobs/hub-probe.sh parses.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaFile();
const SPLITTER = fileURLToPath(new URL('../../../bin/lib/d1-schema.sh', import.meta.url));

const call = (o, path, { method = 'GET', body, auth = true } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: o.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const BASE = { project: 'cromford', ticket_key: 'BH-3434', probe: 'd1-count', args: { table: 'jobs', template: 'all' }, requested_by: 'operator' };
const request = (o, over = {}) => call(o, '/api/hub-probe', { method: 'POST', body: { ...BASE, ...over } });
const claim = (o, body) => call(o, '/api/hub-probe/claim', { method: 'POST', body });
const result = (o, body) => call(o, '/api/hub-probe/result', { method: 'POST', body });
const commented = (o, body) => call(o, '/api/hub-probe/commented', { method: 'POST', body });
const count = (o) => o.db.prepare('SELECT COUNT(*) AS n FROM hub_probe_requests').get().n;
const rowOf = (o, id) => o.db.prepare('SELECT * FROM hub_probe_requests WHERE id=?').get(id);
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const isoNoMs = (d) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

async function db(t) {
  const o = await openDb();
  if (!o) t.skip('node:sqlite unavailable');
  return o;
}

// Three pending rows with distinct, ordered requested_at.
async function threePending(o) {
  const ids = [];
  for (const [i, table] of ['jobs', 'ledgers', 'split_watchdog_actions'].entries()) {
    const r = await request(o, { args: { table, template: 'all' } });
    ids.push(r.body.row.id);
    o.db.prepare('UPDATE hub_probe_requests SET requested_at=? WHERE id=?').run(`2026-09-2${i}T00:00:00Z`, r.body.row.id);
  }
  return ids;
}

async function claimedRow(o) {
  const r = await request(o);
  const c = await claim(o, { claimed_by: 'hub', n: 1 });
  assert.equal(c.body.rows[0].id, r.body.row.id);
  return r.body.row.id;
}

test('(S1) fresh schema: 16 columns, the status index, and the unique key rejects a raw duplicate', async (t) => {
  const o = await db(t); if (!o) return;
  const cols = o.db.prepare('PRAGMA table_info(hub_probe_requests)').all().map((c) => c.name);
  assert.deepEqual(cols, ['id', 'project', 'ticket_key', 'probe', 'args_json', 'args_hash', 'status',
    'requested_by', 'requested_at', 'claimed_by', 'claimed_at', 'finished_at', 'http_status', 'output',
    'commented_at', 'note']);
  const idx = o.db.prepare("PRAGMA index_info('idx_hub_probe_status')").all().map((c) => c.name);
  assert.deepEqual(idx, ['status', 'requested_at']);
  const ins = "INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES ('p','K','d1-count','{}','h','2026-09-29T00:00:00Z')";
  o.db.exec(ins);
  assert.throws(() => o.db.exec(ins), /UNIQUE constraint failed/);
  assert.throws(() => o.db.exec("UPDATE hub_probe_requests SET status='done'"), /CHECK constraint failed/);
});

test('(S2) the BH-3434 block splits into two statements through d1_schema_statements and applies twice', async (t) => {
  const o = await db(t); if (!o) return;
  const text = readFileSync(SCHEMA, 'utf8');
  const at = text.indexOf('-- ── BH-3434');
  assert.ok(at >= 0, 'schema.sql carries a BH-3434 block');
  const dir = mkdtempSync(join(tmpdir(), 'hp-s2-'));
  try {
    const f = join(dir, 'block.sql');
    // TEST-CHANGE (BH-3726): the slice ends at the next `-- ── ` block header, not
    // at EOF, so a block appended after this one (BH-3719.0's route seeds) is not
    // counted as a hub-probe statement. The block itself is still pinned at 2.
    const next = text.indexOf('\n-- ── ', at + 1);
    writeFileSync(f, next < 0 ? text.slice(at) : text.slice(at, next + 1));
    const r = spawnSync('bash', ['-c', '. "$1" || exit 9; d1_schema_statements "$2"', 'x', SPLITTER, f], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const stmts = r.stdout.split('\0').filter((s) => s.trim() !== '');
    assert.equal(stmts.length, 2, JSON.stringify(stmts));
    const { DatabaseSync } = await import('node:sqlite');
    const fresh = new DatabaseSync(':memory:');
    for (let pass = 0; pass < 2; pass++) for (const s of stmts) fresh.exec(s);
    assert.equal(fresh.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name IN ('hub_probe_requests','idx_hub_probe_status')").get().n, 2);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('(A1) no bearer: 401 on every hub-probe route', async (t) => {
  const o = await db(t); if (!o) return;
  for (const [method, path] of [['POST', '/api/hub-probe'], ['POST', '/api/hub-probe/claim'],
    ['POST', '/api/hub-probe/result'], ['POST', '/api/hub-probe/commented'],
    ['GET', '/api/hub-probe?project=cromford&ticket=BH-3434'],
    ['GET', '/api/hub-probe/count-today?probe=d1-count']]) {
    const r = await call(o, path, { method, auth: false, ...(method === 'POST' ? { body: BASE } : {}) });
    assert.equal(r.status, 401, `${method} ${path}`);
  }
  assert.equal(count(o), 0);
});

test('(R1) first request: created true, the row is pending with requested_at set', async (t) => {
  const o = await db(t); if (!o) return;
  const before = isoNoMs(new Date(Date.now()));  // determinism: ok brackets the request's own clock read from below
  const r = await request(o);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.created, true);
  assert.equal(typeof r.body.row, 'object');
  assert.equal(r.body.row.status, 'pending');
  assert.equal(r.body.row.project, 'cromford');
  assert.equal(r.body.row.ticket_key, 'BH-3434');
  assert.equal(r.body.row.probe, 'd1-count');
  assert.equal(r.body.row.requested_by, 'operator');
  assert.match(r.body.row.requested_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.ok(r.body.row.requested_at >= before);
  assert.equal(r.body.row.claimed_at, null);
  assert.equal(count(o), 1);
});

test('(R2) the same request again: created false, same id, one row', async (t) => {
  const o = await db(t); if (!o) return;
  const a = await request(o);
  const b = await request(o);
  assert.equal(b.status, 200);
  assert.equal(b.body.created, false);
  assert.equal(b.body.row.id, a.body.row.id);
  assert.equal(count(o), 1);
});

test('(R3) args_hash is the worker\'s: key order ignored, types kept, client hash ignored', async (t) => {
  const o = await db(t); if (!o) return;
  const a = await request(o, { args: { a: 1, b: { d: [2, 1], c: null } } });
  const b = await request(o, { args: { b: { c: null, d: [2, 1] }, a: 1 }, args_hash: 'f'.repeat(64) });
  assert.equal(b.body.created, false, 'key order does not make a new row');
  assert.equal(b.body.row.id, a.body.row.id);
  const canonical = '{"a":1,"b":{"c":null,"d":[2,1]}}';
  assert.equal(a.body.row.args_json, canonical);
  assert.equal(a.body.row.args_hash, sha256(canonical));
  assert.match(a.body.row.args_hash, /^[0-9a-f]{64}$/);
  const c = await request(o, { args: { a: '1', b: { c: null, d: [2, 1] } } });
  assert.equal(c.body.created, true, 'a string "1" is not the number 1');
  const d = await request(o, { args: { a: 1, b: { c: null, d: [1, 2] } } });
  assert.equal(d.body.created, true, 'array order is kept');
  const e = await request(o, { args: {} });
  const f = await request(o, { args: [] });
  assert.equal(e.body.created, true);
  assert.equal(f.body.created, true, '{} and [] are two rows');
  assert.equal(count(o), 5);
});

test('(R4) once ever: a finished row re-requested comes back untouched', async (t) => {
  const o = await db(t); if (!o) return;
  const a = await request(o);
  o.db.prepare("UPDATE hub_probe_requests SET status='pass', output='ok', finished_at='2026-09-01T00:00:00Z' WHERE id=?").run(a.body.row.id);
  const b = await request(o);
  assert.equal(b.status, 200);
  assert.equal(b.body.created, false);
  assert.equal(b.body.row.id, a.body.row.id);
  assert.equal(b.body.row.status, 'pass');
  assert.equal(b.body.row.output, 'ok');
  assert.equal(b.body.row.finished_at, '2026-09-01T00:00:00Z');
});

test('(R5) 400 on a bad project, ticket_key, probe, missing args, or args over 2048; nothing written', async (t) => {
  const o = await db(t); if (!o) return;
  const bad = [
    { project: '' }, { project: 'a b' }, { project: 'x'.repeat(65) },
    { ticket_key: '' }, { ticket_key: 'BH 1' }, { ticket_key: 'K'.repeat(65) }, { ticket_key: 'a;b' },
    { probe: '' }, { probe: 'D1-count' }, { probe: '1abc' }, { probe: 'a'.repeat(33) }, { probe: 'x;y' },
    { args: undefined }, { args: { s: 'x'.repeat(2048) } },
  ];
  for (const over of bad) {
    const body = { ...BASE, ...over };
    if ('args' in over && over.args === undefined) delete body.args;
    const r = await call(o, '/api/hub-probe', { method: 'POST', body });
    assert.equal(r.status, 400, JSON.stringify(over).slice(0, 80));
    assert.match(r.body.error, /\w/);
  }
  assert.equal(count(o), 0);
  const ok = await request(o, { ticket_key: 'K'.repeat(64), probe: 'a'.repeat(32) });
  assert.equal(ok.status, 200, 'the bounds themselves are accepted');
});

test('(C1) claim n=2 over three pending: the two oldest, claimed, stamped', async (t) => {
  const o = await db(t); if (!o) return;
  const ids = await threePending(o);
  const r = await claim(o, { claimed_by: 'hub-box', n: 2 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.id), ids.slice(0, 2));
  for (const row of r.body.rows) {
    assert.equal(row.status, 'claimed');
    assert.equal(row.claimed_by, 'hub-box');
    assert.match(row.claimed_at, /Z$/);
    assert.equal(rowOf(o, row.id).status, 'claimed');
  }
  assert.equal(rowOf(o, ids[2]).status, 'pending');
  const again = await claim(o, { claimed_by: 'hub-box', n: 5 });
  assert.deepEqual(again.body.rows.map((x) => x.id), [ids[2]]);
  const none = await claim(o, { claimed_by: 'hub-box', n: 5 });
  assert.equal(none.status, 200);
  assert.deepEqual(none.body.rows, []);
});

test('(C2) two concurrent claims never return the same row', async (t) => {
  const o = await db(t); if (!o) return;
  const ids = await threePending(o);
  const [a, b] = await Promise.all([claim(o, { claimed_by: 'a', n: 2 }), claim(o, { claimed_by: 'b', n: 2 })]);
  const ai = a.body.rows.map((x) => x.id);
  const bi = b.body.rows.map((x) => x.id);
  assert.deepEqual(ai.filter((x) => bi.includes(x)), [], 'disjoint');
  assert.deepEqual([...ai, ...bi].sort(), [...ids].sort());
});

test('(C3) claim rejects a bad n or a missing claimed_by with 400; no row moves', async (t) => {
  const o = await db(t); if (!o) return;
  await threePending(o);
  for (const body of [{ claimed_by: 'x', n: 0 }, { claimed_by: 'x', n: -1 }, { claimed_by: 'x', n: 1.5 },
    { claimed_by: 'x', n: '2' }, { claimed_by: 'x', n: 101 }, { claimed_by: 'x' }, { n: 2 }, { claimed_by: '', n: 2 }]) {
    const r = await claim(o, body);
    assert.equal(r.status, 400, JSON.stringify(body));
  }
  assert.equal(o.db.prepare("SELECT COUNT(*) AS n FROM hub_probe_requests WHERE status='pending'").get().n, 3);
  const top = await claim(o, { claimed_by: 'x', n: 100 });
  assert.equal(top.status, 200, 'n=100 is the bound, accepted');
});

test('(X1) result only from claimed: pending/pass -> 409 unchanged, unknown -> 404', async (t) => {
  const o = await db(t); if (!o) return;
  const pending = (await request(o)).body.row.id;
  const before = rowOf(o, pending);
  const r1 = await result(o, { id: pending, result: 'pass', http_status: 200, output: 'x' });
  assert.equal(r1.status, 409, JSON.stringify(r1.body));
  assert.equal(r1.body.status, 'pending');
  assert.deepEqual(rowOf(o, pending), before);
  const done = (await request(o, { ticket_key: 'BH-2' })).body.row.id;
  o.db.prepare("UPDATE hub_probe_requests SET status='pass' WHERE id=?").run(done);
  const beforeDone = rowOf(o, done);
  const r2 = await result(o, { id: done, result: 'fail', http_status: 500, output: 'y' });
  assert.equal(r2.status, 409);
  assert.equal(r2.body.status, 'pass');
  assert.deepEqual(rowOf(o, done), beforeDone);
  const r3 = await result(o, { id: 99999, result: 'pass', http_status: 200, output: '' });
  assert.equal(r3.status, 404);
});

test('(X2) claimed -> pass: ok, finished; the status alias works too', async (t) => {
  const o = await db(t); if (!o) return;
  const id = await claimedRow(o);
  const r = await result(o, { id, result: 'pass', http_status: 200, output: 'rows: 3' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { ok: true });
  const row = rowOf(o, id);
  assert.equal(row.status, 'pass');
  assert.equal(row.http_status, 200);
  assert.equal(row.output, 'rows: 3');
  assert.match(row.finished_at, /Z$/);
  const again = await result(o, { id, result: 'pass', http_status: 200, output: 'rows: 3' });
  assert.equal(again.status, 409, 'a second result is a lost CAS');
  await request(o, { ticket_key: 'BH-9' });
  const c = await claim(o, { claimed_by: 'hub', n: 1 });
  const id2 = c.body.rows[0].id;
  const s = await result(o, { id: id2, status: 'fail', http_status: null, output: 'boom' });
  assert.equal(s.status, 200, JSON.stringify(s.body));
  assert.equal(rowOf(o, id2).status, 'fail');
  assert.equal(rowOf(o, id2).http_status, null);
  const c3 = await claim(o, { claimed_by: 'hub', n: 1 });
  assert.equal(c3.body.rows.length, 0);
  // bad outcome words / id / http_status
  await request(o, { ticket_key: 'BH-10' });
  const id3 = (await claim(o, { claimed_by: 'hub', n: 1 })).body.rows[0].id;
  for (const body of [{ id: id3, result: 'done' }, { id: id3, result: 'claimed' }, { id: 'x', result: 'pass' },
    { id: 0, result: 'pass' }, { id: id3, result: 'pass', http_status: '2xx' }, { id: id3, result: 'pass', http_status: 1.5 }]) {
    const b = await result(o, body);
    assert.equal(b.status, 400, JSON.stringify(body));
  }
  assert.equal(rowOf(o, id3).status, 'claimed');
});

test('(X3) output is cut to 4096 UTF-8 bytes worker-side, on a character boundary', async (t) => {
  const o = await db(t); if (!o) return;
  const id = await claimedRow(o);
  await result(o, { id, result: 'pass', http_status: 200, output: 'a'.repeat(5000) });
  assert.equal(Buffer.byteLength(rowOf(o, id).output, 'utf8'), 4096);
  await request(o, { ticket_key: 'BH-11' });
  const id2 = (await claim(o, { claimed_by: 'hub', n: 1 })).body.rows[0].id;
  // 4095 ASCII then a 3-byte char straddling the cut, then a 4-byte one
  const out = 'b'.repeat(4095) + '€' + '😀'.repeat(10);
  await result(o, { id: id2, result: 'fail', http_status: 500, output: out });
  const stored = rowOf(o, id2).output;
  const bytes = Buffer.from(stored, 'utf8');
  assert.ok(bytes.length <= 4096, String(bytes.length));
  assert.equal(stored, 'b'.repeat(4095));
  assert.ok(!stored.includes('\uFFFD'));
  assert.equal(new TextDecoder('utf-8', { fatal: true }).decode(bytes), stored);
  // a 4-byte char cut at 2 bytes in
  await request(o, { ticket_key: 'BH-12' });
  const id3 = (await claim(o, { claimed_by: 'hub', n: 1 })).body.rows[0].id;
  await result(o, { id: id3, result: 'fail', http_status: 500, output: 'c'.repeat(4094) + '😀' });
  assert.equal(rowOf(o, id3).output, 'c'.repeat(4094));
  // a short multibyte output is kept whole
  await request(o, { ticket_key: 'BH-13' });
  const id4 = (await claim(o, { claimed_by: 'hub', n: 1 })).body.rows[0].id;
  await result(o, { id: id4, result: 'pass', http_status: 200, output: 'ok ✓ 😀' });
  assert.equal(rowOf(o, id4).output, 'ok ✓ 😀');
});

test('(X4) pending with a note from claimed: back to pending, claim cleared, re-claimable', async (t) => {
  const o = await db(t); if (!o) return;
  const id = await claimedRow(o);
  const r = await result(o, { id, result: 'pending', note: 'daily cap', http_status: null, output: '' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const row = rowOf(o, id);
  assert.equal(row.status, 'pending');
  assert.equal(row.claimed_at, null);
  assert.equal(row.claimed_by, null);
  assert.equal(row.note, 'daily cap');
  assert.equal(row.finished_at, null);
  const again = await claim(o, { claimed_by: 'hub', n: 1 });
  assert.deepEqual(again.body.rows.map((x) => x.id), [id]);
});

test('(X5) pending without a note is a 400 and the row stays claimed', async (t) => {
  const o = await db(t); if (!o) return;
  const id = await claimedRow(o);
  for (const body of [{ id, result: 'pending' }, { id, result: 'pending', note: '' }]) {
    const r = await result(o, body);
    assert.equal(r.status, 400, JSON.stringify(body));
  }
  assert.equal(rowOf(o, id).status, 'claimed');
});

test('(M1) commented twice keeps the first timestamp; both answer ok', async (t) => {
  const o = await db(t); if (!o) return;
  const id = (await request(o)).body.row.id;
  const a = await commented(o, { id });
  assert.equal(a.status, 200);
  assert.deepEqual(a.body, { ok: true });
  const first = rowOf(o, id).commented_at;
  assert.match(first, /Z$/);
  o.db.prepare('UPDATE hub_probe_requests SET commented_at=? WHERE id=?').run('2026-01-01T00:00:00Z', id);
  const b = await commented(o, { id });
  assert.equal(b.status, 200);
  assert.deepEqual(b.body, { ok: true });
  assert.equal(rowOf(o, id).commented_at, '2026-01-01T00:00:00Z');
});

test('(M2) commented on an unknown or malformed id', async (t) => {
  const o = await db(t); if (!o) return;
  assert.equal((await commented(o, { id: 4242 })).status, 404);
  assert.equal((await commented(o, { id: 'x' })).status, 400);
});

test('(L1) list: only this project+ticket, oldest first, with a truncated flag', async (t) => {
  const o = await db(t); if (!o) return;
  const ids = await threePending(o);
  await request(o, { ticket_key: 'BH-OTHER' });
  await request(o, { project: 'project-3' });
  const r = await call(o, '/api/hub-probe?project=cromford&ticket=BH-3434');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.id), ids);
  assert.equal(r.body.truncated, false);
  const none = await call(o, '/api/hub-probe?project=cromford&ticket=BH-NONE');
  assert.deepEqual(none.body.rows, []);
  // over the cap: 200 rows and truncated:true
  const ins = o.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES ('p','BIG','d1-count',?,?, '2026-09-29T00:00:00Z')");
  for (let i = 0; i < 201; i++) ins.run(String(i), String(i));
  const big = await call(o, '/api/hub-probe?project=p&ticket=BIG');
  assert.equal(big.body.rows.length, 200);
  assert.equal(big.body.truncated, true);
});

test('(L2) list without project or ticket, or with a bad one, is a 400', async (t) => {
  const o = await db(t); if (!o) return;
  for (const q of ['', '?project=cromford', '?ticket=BH-1', '?project=a%20b&ticket=BH-1', '?project=p&ticket=a%3Bb']) {
    const r = await call(o, `/api/hub-probe${q}`);
    assert.equal(r.status, 400, q);
  }
});

test('(T1) count-today counts only today\'s claims of that probe', async (t) => {
  const o = await db(t); if (!o) return;
  const today = await claimedRow(o); // claimed now, still claimed: counts
  const finished = (await request(o, { ticket_key: 'BH-F' })).body.row.id;
  await claim(o, { claimed_by: 'hub', n: 1 });
  await result(o, { id: finished, result: 'pass', http_status: 200, output: '' }); // claimed today, finished: counts
  const other = (await request(o, { ticket_key: 'BH-O', probe: 'app-status-write' })).body.row.id;
  await claim(o, { claimed_by: 'hub', n: 1 }); // another probe: not in d1-count's count
  const deferred = (await request(o, { ticket_key: 'BH-D' })).body.row.id;
  await claim(o, { claimed_by: 'hub', n: 1 });
  await result(o, { id: deferred, result: 'pending', note: 'cap' }); // deferred: does not count
  const yest = (await request(o, { ticket_key: 'BH-Y' })).body.row.id;
  const y = new Date(Date.now() - 86400000)  // determinism: ok "yesterday" relative to the route's real UTC day; the row lands at its last second
    .toISOString().slice(0, 10) + 'T23:59:59Z';
  o.db.prepare("UPDATE hub_probe_requests SET status='pass', claimed_at=? WHERE id=?").run(y, yest); // yesterday: does not count
  await request(o, { ticket_key: 'BH-P' }); // pending, never claimed: does not count
  assert.equal(rowOf(o, today).status, 'claimed');
  assert.equal(rowOf(o, other).status, 'claimed');
  assert.equal(rowOf(o, deferred).status, 'pending');
  const r = await call(o, '/api/hub-probe/count-today?probe=d1-count');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { count: 2 });
  assert.deepEqual((await call(o, '/api/hub-probe/count-today?probe=app-status-write')).body, { count: 1 });
  // the deferred row is the oldest pending: re-claimed it counts, deferred again it drops out
  const again = await claim(o, { claimed_by: 'hub', n: 1 });
  assert.deepEqual(again.body.rows.map((x) => x.id), [deferred]);
  assert.deepEqual((await call(o, '/api/hub-probe/count-today?probe=d1-count')).body, { count: 3 });
  await result(o, { id: deferred, result: 'pending', note: 'cap' });
  assert.deepEqual((await call(o, '/api/hub-probe/count-today?probe=d1-count')).body, { count: 2 });
  for (const q of ['', '?probe=', '?probe=D1', '?probe=a%20b']) {
    assert.equal((await call(o, `/api/hub-probe/count-today${q}`)).status, 400, q);
  }
});

test('(T2) a D1 without the table answers 503 schema not applied, never a count of 0', async (t) => {
  const o = await db(t); if (!o) return;
  o.db.exec('DROP TABLE hub_probe_requests');
  const r = await call(o, '/api/hub-probe/count-today?probe=d1-count');
  assert.equal(r.status, 503);
  assert.match(r.body.error, /hub_probe_requests schema not applied/);
  const w = await request(o);
  assert.equal(w.status, 503);
  const c = await claim(o, { claimed_by: 'hub', n: 1 });
  assert.equal(c.status, 503);
});
