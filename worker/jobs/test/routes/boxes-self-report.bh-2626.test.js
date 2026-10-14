import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../../src/index.js';
import { jobsSchemaSql } from '../lib/jobs-schema.js';

// BH-2532.4 (BH-2626) — POST /api/boxes/self-report, driven through
// worker.fetch (the production entry, auth gate included) against THE SQL THAT
// SHIPS: schema.sql on a fresh database, the ensureColumns ALTERs on a legacy
// one. The monotonic guard is asserted on real rows, not on SQL text, so a
// guard that is dropped or inverted fails here.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// A D1-shaped facade over node:sqlite (same shape as boxes-rules-hash.bh-2622),
// plus batch() because POST /api/metrics/cli-versions writes through it.
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
  const batch = async (stmts) => { const out = []; for (const s of stmts) out.push(await s.run()); return out; };
  return { prepare, batch };
}

function freshDB() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, d1: sqliteDB(db) };
}

async function call(d1, path, { method = 'POST', body, auth = `Bearer ${SECRET}` } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB: d1, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}

const report = (d1, body) => call(d1, '/api/boxes/self-report', { body });
const row = (db, box) => db.prepare('SELECT * FROM box_status WHERE box=?').get(box);

// md5 hex computed here, not written out: a 32-hex literal trips the share mirror's leakcheck.
const md5 = (s) => createHash('md5').update(s).digest('hex');
const H1 = md5('h1');
const H2 = md5('h2');
const R1 = { box: 'box-project-3-2', cli_version: '2.1.300', codex_version: '0.150.1', rules_hash: H1, at: '2026-09-26T10:00:00Z' };

test('W1: a valid report writes all five columns, actor self-report', async () => {
  const { db, d1 } = freshDB();
  const r = await report(d1, R1);
  assert.equal(r.status, 200);
  assert.equal(r.body.box, 'box-project-3-2');
  assert.equal(r.body.cli_recorded, true);
  assert.equal(r.body.rules_recorded, true);
  const b = row(db, 'box-project-3-2');
  assert.equal(b.cli_version, '2.1.300');
  assert.equal(b.codex_version, '0.150.1');
  assert.equal(b.cli_checked_at, '2026-09-26T10:00:00Z');
  assert.equal(b.rules_hash, H1);
  assert.equal(b.rules_reported_at, '2026-09-26T10:00:00Z');
  assert.equal(b.actor, 'self-report');
  assert.equal(b.rules_commit, null, 'rules_hash is not rules_commit and never writes it');
  // "-" is the no-CLAUDE.md token and is a legal hash.
  const r2 = await report(d1, { ...R1, box: 'nofile', rules_hash: '-' });
  assert.equal(r2.status, 200);
  assert.equal(row(db, 'nofile').rules_hash, '-');
});

test('W2: an older report changes nothing; a newer one wins', async () => {
  const { db, d1 } = freshDB();
  await report(d1, R1);
  // Another writer owns actor/updated_at now; a replayed older report must not take them.
  db.prepare("UPDATE box_status SET actor='backup', updated_at='2026-09-26T10:30:00Z' WHERE box=?").run(R1.box);
  const old = await report(d1, { ...R1, cli_version: '2.1.1', codex_version: '0.1.0', rules_hash: H2, at: '2026-09-26T09:00:00Z' });
  assert.equal(old.status, 200);
  let b = row(db, R1.box);
  assert.equal(b.actor, 'backup', 'a report neither half of which lands must not take actor');
  assert.equal(b.updated_at, '2026-09-26T10:30:00Z', 'a report neither half of which lands must not move updated_at');
  assert.equal(b.cli_version, '2.1.300');
  assert.equal(b.codex_version, '0.150.1');
  assert.equal(b.cli_checked_at, '2026-09-26T10:00:00Z');
  assert.equal(b.rules_hash, H1);
  assert.equal(b.rules_reported_at, '2026-09-26T10:00:00Z');
  await report(d1, { ...R1, cli_version: '2.1.301', rules_hash: H2, at: '2026-09-26T11:00:00Z' });
  b = row(db, R1.box);
  assert.equal(b.actor, 'self-report', 'a report that lands takes actor back');
  assert.notEqual(b.updated_at, '2026-09-26T10:30:00Z');
  assert.equal(b.cli_version, '2.1.301');
  assert.equal(b.rules_hash, H2);
  assert.equal(b.rules_reported_at, '2026-09-26T11:00:00Z');
});

test('W3: the cli-versions route and the self-report share one guard, both directions', async () => {
  const { db, d1 } = freshDB();
  await report(d1, R1);
  // An OLDER cli-versions row loses to the self-report.
  let r = await call(d1, '/api/metrics/cli-versions', { body: { rows: [
    { box: R1.box, cli: 'claude', at: '2026-09-26T09:00:00Z', source: 'update', version_after: '2.0.0' }] } });
  assert.equal(r.status, 200);
  assert.equal(row(db, R1.box).cli_version, '2.1.300');
  // A NEWER cli-versions row wins over the self-report...
  r = await call(d1, '/api/metrics/cli-versions', { body: { rows: [
    { box: R1.box, cli: 'claude', at: '2026-09-26T12:00:00Z', source: 'update', version_after: '2.1.400' }] } });
  assert.equal(r.status, 200);
  let b = row(db, R1.box);
  assert.equal(b.cli_version, '2.1.400');
  assert.equal(b.cli_checked_at, '2026-09-26T12:00:00Z');
  // ...and a self-report older than it cannot roll the CLI half back, while its
  // rules half (guarded on its own clock) still lands.
  r = await report(d1, { ...R1, cli_version: '2.1.302', rules_hash: H2, at: '2026-09-26T11:00:00Z' });
  assert.equal(r.status, 200);
  b = row(db, R1.box);
  assert.equal(b.cli_version, '2.1.400');
  assert.equal(b.cli_checked_at, '2026-09-26T12:00:00Z');
  assert.equal(b.rules_hash, H2);
  assert.equal(b.rules_reported_at, '2026-09-26T11:00:00Z');
});

test('W4: a "missing" CLI drops the whole CLI half; the rules half still lands', async () => {
  const { db, d1 } = freshDB();
  await report(d1, R1);
  const r = await report(d1, { ...R1, codex_version: 'missing', rules_hash: H2, at: '2026-09-26T11:00:00Z' });
  assert.equal(r.status, 200);
  assert.equal(r.body.cli_recorded, false);
  assert.equal(r.body.rules_recorded, true);
  const b = row(db, R1.box);
  assert.equal(b.cli_version, '2.1.300');
  assert.equal(b.codex_version, '0.150.1');
  assert.equal(b.cli_checked_at, '2026-09-26T10:00:00Z', 'a missing CLI must not make the old version look fresh');
  assert.equal(b.rules_hash, H2);
  assert.equal(b.rules_reported_at, '2026-09-26T11:00:00Z');
  // An empty CLI is the same as missing: on a fresh box, no CLI column is written.
  const r2 = await report(d1, { ...R1, box: 'newbox', cli_version: '', at: '2026-09-26T11:00:00Z' });
  assert.equal(r2.status, 200);
  const n = row(db, 'newbox');
  assert.equal(n.cli_version, null);
  assert.equal(n.codex_version, null);
  assert.equal(n.cli_checked_at, null);
  assert.equal(n.rules_hash, H1);
});

test('W5: no or wrong Authorization is 401 and writes nothing', async () => {
  const { db, d1 } = freshDB();
  const a = await call(d1, '/api/boxes/self-report', { body: R1, auth: null });
  assert.equal(a.status, 401);
  const b = await call(d1, '/api/boxes/self-report', { body: R1, auth: 'Bearer nope' });
  assert.equal(b.status, 401);
  assert.equal(row(db, R1.box), undefined);
});

test('W6: GET /api/boxes returns the reported rules_hash and rules_reported_at', async () => {
  const { d1 } = freshDB();
  await report(d1, R1);
  const r = await call(d1, '/api/boxes', { method: 'GET' });
  assert.equal(r.status, 200);
  const b = r.body.boxes.find((x) => x.box === R1.box);
  assert.equal(b.rules_hash, H1);
  assert.equal(b.rules_reported_at, '2026-09-26T10:00:00Z');
  assert.equal(b.cli_checked_at, '2026-09-26T10:00:00Z');
});

test('W7: a legacy box_status gains the columns through ensureColumns on the POST', async () => {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE box_status (box TEXT PRIMARY KEY, host TEXT, cli_version TEXT, cli_checked_at TEXT,
    codex_version TEXT, actor TEXT, updated_at TEXT NOT NULL)`);
  const r = await report(sqliteDB(db), R1);
  assert.equal(r.status, 200);
  const b = row(db, R1.box);
  assert.equal(b.rules_hash, H1);
  assert.equal(b.rules_reported_at, '2026-09-26T10:00:00Z');
});

test('W8: 400 on a bad box, a bad at, a malformed rules_hash, or nothing to record', async () => {
  const { db, d1 } = freshDB();
  for (const [why, body] of [
    ['bad box', { ...R1, box: 'no spaces allowed' }],
    ['no box', { ...R1, box: '' }],
    ['free-form at', { ...R1, at: 'yesterday' }],
    ['at with offset', { ...R1, at: '2026-09-26T10:00:00+02:00' }],
    ['no at', { ...R1, at: undefined }],
    ['uppercase hash', { ...R1, rules_hash: H1.toUpperCase() }],
    ['short hash', { ...R1, rules_hash: 'abc' }],
    ['both halves empty', { box: R1.box, at: R1.at, cli_version: 'missing', codex_version: '0.1.0', rules_hash: '' }],
  ]) {
    const r = await report(d1, body);
    assert.equal(r.status, 400, why);
  }
  assert.equal(row(db, R1.box), undefined, 'a 400 writes nothing');
});
