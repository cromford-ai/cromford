// BH-6780.0 (BH-6863): GET /api/ledger falls back to the archive store.
//
// A hot miss on GET /api/ledger?kind&key for a kind listed in
// retention.ledgers.archive_kinds (allow) or retention.ledgers.archived_kinds
// (sticky) does ONE point read on env.ARCHIVE. Every other path answers what it
// answered before. The hot store is a real schema.sql database; the archive is
// a second node:sqlite database behind the same D1 shim, and a spy counts its
// prepare() calls. Everything goes through the real worker.fetch.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ledgerArchiveKinds } from '../src/lib/ledger-archive.js';
import { claimArchiveGuard } from '../src/lib/ledger-archive-claim.js';

const SECRET = 'test-secret';
const KIND = 'review_block_fp';
const STAMP = '2026-10-01T00:00:00Z';

const ARCHIVE_LEDGERS_SQL = `CREATE TABLE ledgers (
  kind TEXT NOT NULL, key TEXT NOT NULL, status TEXT NOT NULL, job_id TEXT,
  actor TEXT, detail TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY (kind, key))`;

async function openArchive({ table = true } = {}) {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  if (table) db.exec(ARCHIVE_LEDGERS_SQL);
  const inner = d1(db);
  const spy = { prepares: 0, throwWith: null };
  const ARCHIVE = {
    prepare(sql) {
      spy.prepares += 1;
      if (spy.throwWith) throw new Error(spy.throwWith);
      return inner.prepare(sql);
    },
    batch: (s) => inner.batch(s),
  };
  return { db, ARCHIVE, spy };
}

function seedLedger(db, kind, key, status) {
  db.prepare(`INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?)`).run(kind, key, status, 'hub-a', null, STAMP, STAMP);
}

function setSetting(db, key, value, updatedAt = STAMP) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`)
    .run(key, value, 'test', 'test', updatedAt);
}

function call(env, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { HARNESS_SECRET: SECRET, ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const getLedger = (env, kind, key) =>
  call(env, 'GET', `/api/ledger?kind=${encodeURIComponent(kind)}&key=${encodeURIComponent(key)}`);
const hotCount = (db) => db.prepare('SELECT COUNT(*) AS n FROM ledgers').get().n;

test('BH-6780 ledger archive read fallback', async (t) => {
  if (!(await openDb())) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('T1. a hot miss on an allowlisted kind answers the archive row, archived: true', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    seedLedger(a.db, KIND, 'k1', 'blocked');
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 200);
    assert.equal(r.body.archived, true);
    assert.equal(r.body.ledger.status, 'blocked');
    assert.equal(r.body.ledger.key, 'k1');
    assert.equal(a.spy.prepares, 1);
  });

  await t.test('T2. an unlisted kind 404s and never touches ARCHIVE', async () => {
    const { DB } = await openDb();
    const a = await openArchive();
    seedLedger(a.db, 'pr_state', 'missing', 'open');
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, 'pr_state', 'missing');
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'not found');
    assert.equal(a.spy.prepares, 0);
  });

  await t.test('T3a. an archive throw is 503 ledger archive unavailable; hot table unchanged', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    a.spy.throwWith = 'D1_ERROR: overloaded';
    const before = hotCount(db);
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'ledger archive unavailable');
    assert.equal(hotCount(db), before);
  });

  await t.test('T3b. a sticky kind with no ARCHIVE binding is 503 archive not bound', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archived_kinds', KIND);
    const before = hotCount(db);
    const r = await getLedger({ DB }, KIND, 'k1');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'archive not bound');
    assert.equal(hotCount(db), before);
  });

  await t.test('T3c. an allow-only kind with no ARCHIVE binding is 404', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const r = await getLedger({ DB }, KIND, 'k1');
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'not found');
  });

  await t.test('T4. an archive with no ledgers table is 404, not 503', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive({ table: false });
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'not found');
    assert.equal(a.spy.prepares, 1);
  });

  await t.test('T4b. the D1 wire text for a missing table is also 404', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    a.spy.throwWith = 'D1_ERROR: no such table: ledgers: SQLITE_ERROR';
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 404);
  });

  await t.test('T6. a listed kind whose key is absent from the archive is 404', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    seedLedger(a.db, KIND, 'other', 'blocked');
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'not found');
    assert.equal(a.spy.prepares, 1);
  });

  await t.test('T7. a claim on a listed kind is unchanged; the seam returns null', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    const r = await call({ DB, ARCHIVE: a.ARCHIVE }, 'POST', '/api/ledger/claim',
      { kind: KIND, key: 'k9', status: 'sending', stale_s: 900, actor: 'hub-a' });
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.ledger.status, 'sending');
    assert.equal(await claimArchiveGuard({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k9', STAMP), null);
  });

  await t.test('T8. a list written through PUT /api/settings is trimmed, deduped and length-capped', async () => {
    const { db, DB } = await openDb();
    const a = await openArchive();
    seedLedger(a.db, KIND, 'k1', 'blocked');
    const env = { DB, ARCHIVE: a.ARCHIVE };
    const put = await call(env, 'PUT', '/api/settings',
      { key: 'retention.ledgers.archive_kinds', value: ` ${KIND} , ${KIND},,${'x'.repeat(33)}` });
    assert.equal(put.status, 200, JSON.stringify(put.body));
    const r = await getLedger(env, KIND, 'k1');
    assert.equal(r.status, 200);
    assert.equal(r.body.archived, true);
    const rows = db.prepare('SELECT * FROM settings').all();
    const { allow } = ledgerArchiveKinds(new Map(rows.map((x) => [x.key, x])));
    assert.deepEqual([...allow], [KIND]);
  });

  await t.test('T9. a hot hit wins: hot row, no archived field, no archive read', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    seedLedger(db, KIND, 'k1', 'hot');
    const a = await openArchive();
    seedLedger(a.db, KIND, 'k1', 'cold');
    const r = await getLedger({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 200);
    assert.equal(r.body.ledger.status, 'hot');
    assert.equal('archived' in r.body, false);
    assert.equal(a.spy.prepares, 0);
  });

  await t.test('T10. ledgerArchiveKinds caps at 64 entries and reads stickyAt', () => {
    const list = Array.from({ length: 70 }, (_, i) => `kind_${i}`).join(',');
    const byKey = new Map([
      ['retention.ledgers.archive_kinds', { key: 'retention.ledgers.archive_kinds', value: list, updated_at: STAMP }],
      ['retention.ledgers.archived_kinds', { key: 'retention.ledgers.archived_kinds', value: 'a,b', updated_at: '2026-10-02T03:04:05Z' }],
    ]);
    const k = ledgerArchiveKinds(byKey);
    assert.equal(k.allow.size, 64);
    assert.equal(k.allow.has('kind_63'), true);
    assert.equal(k.allow.has('kind_64'), false);
    assert.deepEqual([...k.sticky], ['a', 'b']);
    assert.equal(k.stickyAt, '2026-10-02T03:04:05Z');
    const empty = ledgerArchiveKinds(new Map());
    assert.equal(empty.allow.size, 0);
    assert.equal(empty.sticky.size, 0);
    assert.equal(empty.stickyAt, null);
  });

  await t.test('T11. a settings read throw on a hot miss is 503 settings unavailable', async () => {
    const { db, DB } = await openDb();
    const failing = {
      ...DB,
      prepare(sql) {
        if (/^SELECT \* FROM settings/.test(sql)) throw new Error('D1_ERROR: overloaded');
        return DB.prepare(sql);
      },
    };
    const a = await openArchive();
    const before = hotCount(db);
    const r = await getLedger({ DB: failing, ARCHIVE: a.ARCHIVE }, KIND, 'k1');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'settings unavailable');
    assert.equal(a.spy.prepares, 0);
    assert.equal(hotCount(db), before);
  });

  await t.test('T12. a fresh schema seeds the three settings rows', async () => {
    const { db } = await openDb();
    const v = (k) => db.prepare('SELECT value FROM settings WHERE key=?').get(k)?.value;
    assert.equal(v('retention.ledgers.archive_days'), '0');
    assert.equal(v('retention.ledgers.archive_kinds'), '');
    assert.equal(v('retention.ledgers.archived_kinds'), '');
  });

  await t.test('EXPLAIN. the archive point read uses the primary key on 5000 rows', async () => {
    const a = await openArchive();
    const ins = a.db.prepare(`INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?,?,?,?,?)`);
    for (let i = 0; i < 5000; i++) ins.run(`kind_${i % 20}`, `key_${i}`, 'x', STAMP, STAMP);
    a.db.exec('ANALYZE');
    const plan = a.db.prepare('EXPLAIN QUERY PLAN SELECT * FROM ledgers WHERE kind=? AND key=?')
      .all('kind_3', 'key_3').map((r) => r.detail).join(' | ');
    assert.doesNotMatch(plan, /SCAN ledgers/);
    assert.match(plan, /USING (PRIMARY KEY|INDEX)/);
  });
});
