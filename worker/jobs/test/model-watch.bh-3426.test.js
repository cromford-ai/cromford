import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3426 (BH-3422.1) — the model-watch routes over model_watch and cost_rows,
// every case driven through worker.fetch against a node:sqlite D1 stand-in.
// Fixture ids are neutral (acme / m-1): tests/alert-triage-runners R6 scans
// every added line under worker/ for model literals.

const SECRET = 's3cret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare, exec: async (sql) => db.exec(sql) };
}

async function openDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  return db;
}

// schema.sql's own CREATE TABLE cost_rows, to its matching close paren, so the
// usage route is exercised against the real column names.
function costRowsDdl() {
  const start = SCHEMA.search(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+cost_rows\s*\(/i);
  assert.ok(start !== -1, 'schema.sql must contain CREATE TABLE IF NOT EXISTS cost_rows');
  const paren = start + SCHEMA.slice(start).indexOf('(');
  let depth = 0, end = -1;
  for (let i = paren; i < SCHEMA.length; i++) {
    if (SCHEMA[i] === '(') depth++;
    else if (SCHEMA[i] === ')') { depth--; if (depth === 0) { end = i; break; } }
  }
  assert.ok(end !== -1, 'no matching close paren for cost_rows');
  return SCHEMA.slice(start, end + 1).replace(/--[^\n]*/g, '');
}

function call(db, method, path, body, { bearer = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (body !== undefined) init.body = typeof body === 'string' ? body : JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.example${path}`, init), { DB: db, HARNESS_SECRET: SECRET });
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
// A 400 answers before any DB call, so the table may not exist yet: that is zero rows.
const count = (db) => (db.prepare("SELECT 1 FROM sqlite_master WHERE name='model_watch'").get()
  ? db.prepare('SELECT COUNT(*) AS n FROM model_watch').get().n : 0);

test('W1 POST refuses a missing vendor / model_id / source and a non-numeric price; nothing written', async (t) => {
  const raw = await openDb(t);
  if (!raw) return;
  const DB = sqliteDB(raw);
  const ok = { vendor: 'acme', model_id: 'm-1', source: 's1' };
  const cases = [
    [{ model_id: 'm-1', source: 's1' }, /vendor/],
    [{ vendor: '  ', model_id: 'm-1', source: 's1' }, /vendor/],
    [{ vendor: 'acme', source: 's1' }, /model_id/],
    [{ vendor: 'acme', model_id: ' ', source: 's1' }, /model_id/],
    [{ vendor: 'acme', model_id: 'm-1' }, /source/],
    [{ vendor: 'acme', model_id: 'm-1', source: '   ' }, /source/],
    [{ ...ok, prompt: 'abc' }, /prompt/],
    [{ ...ok, context_window: 'big' }, /context_window/],
    ['{not json', /vendor/],
  ];
  for (const [body, re] of cases) {
    const res = await call(DB, 'POST', '/api/model-watch', body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.match((await res.json()).error, re);
  }
  assert.equal(count(raw), 0);
});

test('W2 double POST: first:true then first:false, one row, first write wins; mixed case dedupes', async (t) => {
  const raw = await openDb(t);
  if (!raw) return;
  const DB = sqliteDB(raw);
  let res = await call(DB, 'POST', '/api/model-watch',
    { vendor: ' ACME ', model_id: 'M-1', source: 's1', prompt: 3, completion: 15, context_window: 200000, slug: 'acme/m-1' });
  assert.equal(res.status, 200);
  let b = await res.json();
  assert.equal(b.recorded, true);
  assert.equal(b.first, true);
  assert.equal(b.row.vendor, 'acme');
  assert.equal(b.row.model_id, 'm-1');
  assert.equal(b.row.status, 'new');
  assert.equal(b.row.source, 's1');
  assert.equal(b.row.prompt, 3);
  assert.equal(b.row.cache_read, null);
  assert.match(b.row.first_seen, ISO);
  assert.equal(b.row.updated_at, b.row.first_seen);

  res = await call(DB, 'POST', '/api/model-watch', { vendor: 'acme', model_id: 'm-1', source: 's2', prompt: 9 });
  assert.equal(res.status, 200);
  b = await res.json();
  assert.equal(b.first, false);
  assert.equal(b.row.source, 's1', 'a second POST never overwrites the first row');
  assert.equal(b.row.prompt, 3);
  assert.equal(count(raw), 1);

  res = await call(DB, 'POST', '/api/model-watch', { vendor: 'Acme', model_id: 'm-10', source: 's1' });
  b = await res.json();
  assert.equal(b.first, true);
  assert.equal(count(raw), 2, 'm-10 is its own row');
});

function seed(raw, vendor, model, status, firstSeen, updatedAt = firstSeen) {
  raw.prepare(`INSERT INTO model_watch (vendor, model_id, source, status, first_seen, updated_at)
    VALUES (?, ?, 's', ?, ?, ?)`).run(vendor, model, status, firstSeen, updatedAt);
}

test('W3 PUT /state: unknown status 400 (even on an absent row), absent row 404, happy path bumps updated_at', async (t) => {
  const raw = await openDb(t);
  if (!raw) return;
  const DB = sqliteDB(raw);
  // Creates the table through the production path first.
  assert.equal((await call(DB, 'GET', '/api/model-watch')).status, 200);
  seed(raw, 'acme', 'm-1', 'new', '2020-01-01T00:00:00Z');

  for (const status of ['done', 'New', 'NEW', 'new ']) {
    for (const model_id of ['m-1', 'absent']) {
      const res = await call(DB, 'PUT', '/api/model-watch/state', { vendor: 'acme', model_id, status });
      assert.equal(res.status, 400, `${status} on ${model_id}`);
    }
  }
  const before = raw.prepare("SELECT * FROM model_watch WHERE model_id='m-1'").get();
  assert.equal(before.status, 'new');
  assert.equal(before.updated_at, '2020-01-01T00:00:00Z');

  let res = await call(DB, 'PUT', '/api/model-watch/state', { vendor: 'acme', model_id: 'absent', status: 'suggested' });
  assert.equal(res.status, 404);

  res = await call(DB, 'PUT', '/api/model-watch/state', { vendor: 'acme', model_id: 'm-1', actor: 'a' });
  assert.equal(res.status, 400, 'nothing to set');
  res = await call(DB, 'PUT', '/api/model-watch/state', { model_id: 'm-1', status: 'suggested' });
  assert.equal(res.status, 400, 'vendor required');

  res = await call(DB, 'PUT', '/api/model-watch/state',
    { vendor: ' ACME ', model_id: 'M-1', status: 'suggested', suggestion: 'x', actor: 'a', reason: 'r', probe: 'ok' });
  assert.equal(res.status, 200);
  const b = await res.json();
  assert.equal(b.updated, true);
  assert.equal(b.row.status, 'suggested');
  assert.equal(b.row.suggestion, 'x');
  assert.equal(b.row.probe, 'ok');
  assert.equal(b.row.actor, 'a');
  assert.equal(b.row.reason, 'r');
  assert.equal(b.row.first_seen, '2020-01-01T00:00:00Z');
  assert.match(b.row.updated_at, ISO);
  assert.notEqual(b.row.updated_at, '2020-01-01T00:00:00Z');
  const after = raw.prepare("SELECT status, suggestion FROM model_watch WHERE model_id='m-1'").get();
  assert.deepEqual({ ...after }, { status: 'suggested', suggestion: 'x' });
});

test('W3b PUT /state: a reason alone records a partial approval, status untouched; object suggestion/probe are stored as JSON text', async (t) => {
  const raw = await openDb(t);
  if (!raw) return;
  const DB = sqliteDB(raw);
  assert.equal((await call(DB, 'GET', '/api/model-watch')).status, 200);
  seed(raw, 'acme', 'm-1', 'suggested', '2020-01-01T00:00:00Z');
  // bin/model-watch-approve.sh's partial path (BH-3428 P3): actor + reason, no
  // status, so a status another writer set meanwhile is never overwritten.
  let res = await call(DB, 'PUT', '/api/model-watch/state',
    { vendor: 'acme', model_id: 'm-1', actor: 'operator', reason: 'approve incomplete: hub stage.review: 409 stale' });
  assert.equal(res.status, 200);
  let b = await res.json();
  assert.equal(b.row.status, 'suggested');
  assert.equal(b.row.reason, 'approve incomplete: hub stage.review: 409 stale');
  assert.equal(b.row.actor, 'operator');
  assert.notEqual(b.row.updated_at, '2020-01-01T00:00:00Z');
  // actor alone still sets nothing
  res = await call(DB, 'PUT', '/api/model-watch/state', { vendor: 'acme', model_id: 'm-1', actor: 'a' });
  assert.equal(res.status, 400);
  // the lane may hand suggestion/probe as JSON values rather than pre-encoded text
  const suggestion = [{ project: null, role: 'stage.plan', position: 0, from: 'm-0' }];
  const probe = { verdict: 'live', served: 'm-1', rc: 0, cost_usd: 0.01 };
  res = await call(DB, 'PUT', '/api/model-watch/state', { vendor: 'acme', model_id: 'm-1', suggestion, probe });
  assert.equal(res.status, 200);
  b = await res.json();
  assert.deepEqual(JSON.parse(b.row.suggestion), suggestion);
  assert.deepEqual(JSON.parse(b.row.probe), probe);
  // a string is stored as given (the approve command reads either shape)
  res = await call(DB, 'PUT', '/api/model-watch/state', { vendor: 'acme', model_id: 'm-1', probe: JSON.stringify(probe) });
  assert.equal((await res.json()).row.probe, JSON.stringify(probe));
});

// The usage fields, each by name (D56): a new response key is not a break.
const sameFields = (got, want) => { for (const [k, v] of Object.entries(want)) assert.deepEqual(got[k], v, k); };

test('W4 /usage sums exactly over 2,500 seeded cost_rows; no match is rows:0; params required', async (t) => {
  const raw = await openDb(t);
  if (!raw) return;
  raw.exec(costRowsDdl());
  const DB = sqliteDB(raw);
  const ins = raw.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, model, input_toks, output_toks, cache_read, cache_write, inserted_at)
    VALUES ('b', ?, ?, ?, ?, ?, ?, ?, ?, '2026-09-29T00:00:00Z')`);
  const since = '2026-09-01T00:00:00Z';
  const want = { input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0 };
  raw.exec('BEGIN');
  for (let i = 0; i < 2500; i++) {
    const r = [i + 1, 2 * i + 3, i % 7, i % 11];
    ins.run(`h${i}`, i, `2026-09-${String(1 + (i % 28)).padStart(2, '0')}T00:00:00Z`, 'm-1', ...r);
    want.input_toks += r[0]; want.output_toks += r[1]; want.cache_read += r[2]; want.cache_write += r[3];
  }
  for (let i = 0; i < 5; i++) ins.run(`o${i}`, i, '2026-09-10T00:00:00Z', 'm-2', 1000, 1000, 1000, 1000);
  for (let i = 0; i < 5; i++) ins.run(`p${i}`, i, '2026-08-31T23:59:59Z', 'm-1', 1000, 1000, 1000, 1000);
  for (let i = 0; i < 3; i++) ins.run(`z${i}`, i, '2026-09-10T00:00:00Z', 'm-zero', 0, 0, 0, 0);
  raw.exec('COMMIT');

  let res = await call(DB, 'GET', `/api/model-watch/usage?model=m-1&since=2026-09-01T00:00:00Z`);
  assert.equal(res.status, 200);
  sameFields(await res.json(), { model: 'm-1', since, rows: 2500, ...want, archive: 'unbound' });

  res = await call(DB, 'GET', `/api/model-watch/usage?model=nope&since=2026-09-01T00:00:00Z`);
  sameFields(await res.json(),
    { model: 'nope', since, rows: 0, input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0, archive: 'unbound' });

  res = await call(DB, 'GET', `/api/model-watch/usage?model=m-zero&since=2026-09-01T00:00:00Z`);
  const z = await res.json();
  assert.equal(z.rows, 3, 'zero spend is not zero rows');
  assert.equal(z.input_toks, 0);

  for (const q of ['?since=2026-09-01T00:00:00Z', '?model=m-1', '?model=%20&since=x', '']) {
    res = await call(DB, 'GET', `/api/model-watch/usage${q}`);
    assert.equal(res.status, 400, q);
  }
});

const CALLS = [
  ['POST', '/api/model-watch', { vendor: 'acme', model_id: 'm-1', source: 's' }],
  ['GET', '/api/model-watch', undefined],
  ['PUT', '/api/model-watch/state', { vendor: 'acme', model_id: 'm-1', status: 'ignored' }],
  ['GET', '/api/model-watch/usage?model=m-1&since=2026-01-01T00:00:00Z', undefined],
];

test('W5 no bearer is 401 on all four with the DB untouched; with the bearer none answers 501', async (t) => {
  const trap = new Proxy({}, { get() { throw new Error('an unauthenticated model-watch call touched the DB'); } });
  for (const [m, p, body] of CALLS) {
    const res = await call(trap, m, p, body, { bearer: false });
    assert.equal(res.status, 401, `${m} ${p}`);
  }
  const raw = await openDb(t);
  if (!raw) return;
  raw.exec(costRowsDdl());
  const DB = sqliteDB(raw);
  for (const [m, p, body] of CALLS) {
    const res = await call(DB, m, p, body);
    assert.notEqual(res.status, 501, `${m} ${p}`);
    assert.equal(res.status, 200, `${m} ${p}`);
  }
});

test('W6 GET lists at most 500 newest-first with truncated; status/vendor filters; empty params mean no filter', async (t) => {
  const raw = await openDb(t);
  if (!raw) return;
  const DB = sqliteDB(raw);
  assert.equal((await call(DB, 'GET', '/api/model-watch')).status, 200);
  raw.exec('BEGIN');
  for (let i = 0; i < 501; i++) {
    const ts = new Date(Date.UTC(2026, 0, 1) + i * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    seed(raw, i % 2 ? 'acme' : 'other', `m-${i}`, i % 5 === 0 ? 'ignored' : 'new', ts);
  }
  raw.exec('COMMIT');

  let res = await call(DB, 'GET', '/api/model-watch');
  assert.equal(res.status, 200);
  let b = await res.json();
  assert.equal(b.rows.length, 500);
  assert.equal(b.truncated, true);
  assert.equal(b.rows[0].model_id, 'm-500', 'newest first_seen first');
  assert.equal(b.rows[499].model_id, 'm-1');

  b = await (await call(DB, 'GET', '/api/model-watch?status=&vendor=')).json();
  assert.equal(b.rows.length, 500);
  assert.equal(b.truncated, true);

  b = await (await call(DB, 'GET', '/api/model-watch?status=ignored')).json();
  assert.equal(b.rows.length, 101);
  assert.equal(b.truncated, false);
  assert.ok(b.rows.every((r) => r.status === 'ignored'));

  b = await (await call(DB, 'GET', '/api/model-watch?vendor=%20ACME%20')).json();
  assert.equal(b.rows.length, 250);
  assert.equal(b.truncated, false);
  assert.ok(b.rows.every((r) => r.vendor === 'acme'));

  b = await (await call(DB, 'GET', '/api/model-watch?status=ignored&vendor=acme')).json();
  assert.ok(b.rows.length > 0 && b.rows.every((r) => r.vendor === 'acme' && r.status === 'ignored'));

  for (const s of ['bogus', 'New']) {
    res = await call(DB, 'GET', `/api/model-watch?status=${s}`);
    assert.equal(res.status, 400, s);
  }
});
