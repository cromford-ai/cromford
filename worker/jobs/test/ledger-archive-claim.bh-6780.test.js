// BH-6780.1 (BH-6864): POST /api/ledger/claim never re-claims an archived key.
//
// claimArchiveGuard runs before the claim's INSERT. For a kind listed in
// retention.ledgers.archive_kinds or archived_kinds, a hot miss looks in the
// archive: a hit answers claimed:false, archived:true and writes nothing; an
// archive outage answers 503 and writes nothing; a miss lets the claim run. A
// settings outage answers 503 for every kind. The hot store is a real
// schema.sql database, the archive a second node:sqlite database with a spy on
// prepare(). Every call goes through the real worker.fetch.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const KIND = 'review_block_fp';
const STAMP = '2026-10-01T00:00:00Z';

const ARCHIVE_LEDGERS_SQL = `CREATE TABLE ledgers (
  kind TEXT NOT NULL, key TEXT NOT NULL, status TEXT NOT NULL, job_id TEXT,
  actor TEXT, detail TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY (kind, key))`;

async function openArchive() {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  db.exec(ARCHIVE_LEDGERS_SQL);
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

function setSetting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`)
    .run(key, value, 'test', 'test', STAMP);
}

function call(env, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { HARNESS_SECRET: SECRET, ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const claim = (env, kind, key, status, extra = {}) =>
  call(env, 'POST', '/api/ledger/claim', { kind, key, status, stale_s: 60, actor: 'hub-a', ...extra });
const hotCount = (db, kind, key) =>
  db.prepare('SELECT COUNT(*) AS n FROM ledgers WHERE kind=? AND key=?').get(kind, key).n;

test('BH-6780.1 claim exactly-once on an archived key', async (t) => {
  if (!(await openDb())) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('C1. a hot miss with an archive hit answers claimed:false, archived:true, writes nothing', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    seedLedger(a.db, KIND, 'k1', 'blocked');
    const r = await claim({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1', 'x', { terminal: [] });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.claimed, false);
    assert.equal(r.body.archived, true);
    assert.equal(r.body.ledger.key, 'k1');
    assert.equal(r.body.ledger.status, 'blocked');
    assert.equal(hotCount(db, KIND, 'k1'), 0);
  });

  await t.test('C2. an unlisted kind claims as before: no archive read, no extra hot read', async () => {
    const { db, DB: inner } = await openDb();
    // Statements on the hot `ledgers` table: the route's own INSERT and re-read only.
    const ledgerSql = [];
    const DB = new Proxy(inner, {
      get(target, prop) {
        if (prop !== 'prepare') return Reflect.get(target, prop);
        return (sql) => {
          if (/\bledgers\b/.test(sql)) ledgerSql.push(sql);
          return target.prepare(sql);
        };
      },
    });
    const a = await openArchive();
    const r = await claim({ DB, ARCHIVE: a.ARCHIVE }, 'pr_state', 'p1', 'open');
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, true);
    assert.equal(a.spy.prepares, 0);
    assert.equal(ledgerSql.length, 2, ledgerSql.join('\n'));
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const r2 = await claim({ DB, ARCHIVE: a.ARCHIVE }, 'pr_state', 'p2', 'open');
    assert.equal(r2.body.claimed, true);
    assert.equal(a.spy.prepares, 0);
    assert.equal(ledgerSql.length, 4, ledgerSql.join('\n'));
  });

  await t.test('C3. a listed kind with a hot row runs the normal claim and skips the archive', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    seedLedger(db, KIND, 'k1', 'a');
    const a = await openArchive();
    seedLedger(a.db, KIND, 'k1', 'cold');
    const r = await claim({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1', 'b');
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, true);
    assert.equal(r.body.ledger.status, 'b');
    assert.equal(r.body.archived, undefined);
    assert.equal(db.prepare('SELECT status FROM ledgers WHERE kind=? AND key=?').get(KIND, 'k1').status, 'b');
    assert.equal(a.spy.prepares, 0);
  });

  await t.test('C4. a listed kind with the key in neither store claims after one archive read', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    const r = await claim({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1', 'sending');
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, true);
    assert.equal(hotCount(db, KIND, 'k1'), 1);
    assert.equal(a.spy.prepares, 1);
  });

  await t.test('C5. a sticky-only kind with an archive hit answers claimed:false', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archived_kinds', KIND);
    const a = await openArchive();
    seedLedger(a.db, KIND, 'k1', 'blocked');
    const r = await claim({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1', 'x');
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, false);
    assert.equal(r.body.archived, true);
    assert.equal(hotCount(db, KIND, 'k1'), 0);
  });

  await t.test('C6. an archive outage answers 503 and writes nothing', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const a = await openArchive();
    a.spy.throwWith = 'D1_ERROR: overloaded';
    const r = await claim({ DB, ARCHIVE: a.ARCHIVE }, KIND, 'k1', 'x');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'ledger archive unavailable');
    assert.equal(hotCount(db, KIND, 'k1'), 0);
  });

  await t.test('C7. a sticky kind with ARCHIVE unbound answers 503 archive not bound', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archived_kinds', KIND);
    const r = await claim({ DB }, KIND, 'k1', 'x');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'archive not bound');
    assert.equal(hotCount(db, KIND, 'k1'), 0);
  });

  await t.test('C8. an allowed-only kind with ARCHIVE unbound claims (nothing moved yet)', async () => {
    const { db, DB } = await openDb();
    setSetting(db, 'retention.ledgers.archive_kinds', KIND);
    const r = await claim({ DB }, KIND, 'k1', 'x');
    assert.equal(r.status, 200);
    assert.equal(r.body.claimed, true);
    assert.equal(hotCount(db, KIND, 'k1'), 1);
  });

  await t.test('C9. a settings outage answers 503 for an unlisted kind, never a claim', async () => {
    const { db, DB } = await openDb();
    db.exec('DROP TABLE settings');
    const r = await claim({ DB }, 'pr_state', 'p1', 'open');
    assert.equal(r.status, 503);
    assert.equal(r.body.error, 'settings unavailable');
    assert.equal(hotCount(db, 'pr_state', 'p1'), 0);
  });
});
