// BH-2353 (BH-2319.1): the fleet cooldown routes, driven through the REAL
// router against a real schema.sql database (the node:sqlite shim), the way
// conductor-held.bh-1201.test.js does it. The behaviours pinned here are
// statements: the upsert's MAX/CASE, the COALESCE on since_at, the CASTs that
// stop a TEXT until_at comparing as a string, and the bounded sweep. A pattern
// stub would pass a route with none of them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES, COOLDOWN_KINDS, COOLDOWN_MAX_S } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const FUT = 4102444800; // 2100-01-01, far past the 8-day cap: only inserted directly
// The route reads its own request clock, so fixtures are relative to one anchor
// captured at load; every offset below is >= 60 s, far wider than the suite's run.
const ANCHOR = Math.floor(Date.now() / 1000); // determinism: ok the single anchor every until/set_at fixture is derived from
const now = () => ANCHOR;

const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body) => call(DB, '/api/cooldowns', { method: 'POST', body });
const clear = (DB, body) => call(DB, '/api/cooldowns/clear', { method: 'POST', body });
const list = (DB, kind) => call(DB, kind === undefined ? '/api/cooldowns' : `/api/cooldowns?kind=${kind}`);
const norm = (s) => s.replace(/\s+/g, ' ').replace(/\( /g, '(').replace(/ \)/g, ')').trim();
const insertRaw = (db, kind, vendor, subject, until) => db.prepare(
  'INSERT INTO fleet_cooldowns (kind,vendor,subject,until_at,set_at) VALUES (?,?,?,?,?)'
).run(kind, vendor, subject, String(until), String(now()));

test('BH-2353 fleet cooldowns', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 belt DDL == schema.sql, and a POST self-creates the table', async () => {
    const stmts = CREATED_TABLES.fleet_cooldowns;
    assert.ok(Array.isArray(stmts) && stmts.length === 2, 'table + index');
    const m = SCHEMA.match(/CREATE TABLE IF NOT EXISTS fleet_cooldowns \([\s\S]*?\n\);/);
    assert.ok(m, 'schema.sql carries the fleet_cooldowns CREATE');
    assert.equal(norm(stmts[0]), norm(m[0].replace(/;$/, '')));
    assert.ok(SCHEMA.includes(`${stmts[1]};`), 'the index statement is schema.sql\'s verbatim');

    const fresh = await openDb();
    fresh.db.exec('DROP TABLE IF EXISTS fleet_cooldowns');
    const res = await put(fresh.DB, { kind: 'account', vendor: 'claude', subject: 'a', until: now() + 3600 });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(fresh.db.prepare('SELECT count(*) AS n FROM fleet_cooldowns').get().n, 1);
    assert.equal(fresh.db.prepare(
      "SELECT count(*) AS n FROM sqlite_master WHERE name='idx_fleet_cooldowns_kind_until'").get().n, 1);
  });

  await t.test('W2 put then GET returns the row with numeric fields; reason capped at 160', async () => {
    const { DB } = await openDb();
    const until = now() + 7200;
    const res = await put(DB, { kind: 'account', vendor: 'claude', subject: 'a', until, since: 100, reason: 'r', box: 'hub' });
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.row.until, until);
    assert.equal(res.body.row.since, 100);
    assert.equal(res.body.row.box, 'hub');
    assert.equal(typeof res.body.row.set_at, 'number');
    const g = await list(DB, 'account');
    assert.equal(g.status, 200);
    assert.deepEqual(g.body.rows.map((r) => [r.kind, r.vendor, r.subject, r.until, r.since, r.reason, r.box]),
      [['account', 'claude', 'a', until, 100, 'r', 'hub']]);
    assert.equal(g.body.truncated, false);

    const long = await put(DB, { kind: 'account', vendor: 'claude', subject: 'b', until, reason: 'x'.repeat(300) });
    assert.equal(long.status, 200);
    assert.equal(long.body.row.reason.length, 160);
    assert.equal(long.body.row.since, null);
  });

  await t.test('W3 account and model keep the later until', async () => {
    const { DB } = await openDb();
    const x = now() + 3600;
    for (const [kind, subject] of [['account', 'a'], ['model', 'claude-opus/acct']]) {
      await put(DB, { kind, vendor: 'claude', subject, until: x + 100 });
      const r = await put(DB, { kind, vendor: 'claude', subject, until: x });
      assert.equal(r.body.row.until, x + 100, `${kind}: a shorter put shortened the cooldown`);
    }
    // And the numeric compare, not a text one: '99999' > '100000' as strings.
    await put(DB, { kind: 'account', vendor: 'claude', subject: 'n', until: x });
    const r = await put(DB, { kind: 'account', vendor: 'claude', subject: 'n', until: x + 600000 });
    assert.equal(r.body.row.until, x + 600000);
  });

  await t.test('W4 lane refreshes to the new until; since is kept across puts', async () => {
    const { DB } = await openDb();
    const x = now() + 3600;
    await put(DB, { kind: 'lane', vendor: 'openrouter', subject: 'hub', until: x + 100, since: 50 });
    const r = await put(DB, { kind: 'lane', vendor: 'openrouter', subject: 'hub', until: x, since: 60 });
    assert.equal(r.body.row.until, x);
    assert.equal(r.body.row.since, 50);
    const r2 = await put(DB, { kind: 'lane', vendor: 'openrouter', subject: 'hub', until: x });
    assert.equal(r2.body.row.since, 50);
    // A row born without since takes the first since it is given.
    await put(DB, { kind: 'account', vendor: 'claude', subject: 's', until: x });
    const r3 = await put(DB, { kind: 'account', vendor: 'claude', subject: 's', until: x, since: 70 });
    assert.equal(r3.body.row.since, 70);
  });

  await t.test('W5 expired rows are absent; a TEXT-compare trap is not live; sweep boundary', async () => {
    const { DB } = await openDb();
    assert.equal((await put(DB, { kind: 'account', vendor: 'claude', subject: 'e1', until: 1 })).status, 200);
    assert.equal((await put(DB, { kind: 'account', vendor: 'claude', subject: 'e2', until: 2 })).status, 200);
    assert.deepEqual((await list(DB, 'account')).body.rows, []);

    const db2 = await openDb();
    insertRaw(db2.db, 'account', 'claude', 'old', now() - 90000);
    insertRaw(db2.db, 'account', 'claude', 'recent', now() - 3600);
    await put(db2.DB, { kind: 'lane', vendor: 'claude', subject: 'hub', until: now() + 60 });
    const left = db2.db.prepare("SELECT subject FROM fleet_cooldowns WHERE kind='account' ORDER BY subject").all()
      .map((r) => r.subject);
    assert.deepEqual(left, ['recent'], 'rows expired > 24 h are swept, younger expired rows stay');
  });

  await t.test('W6 clear answers the DELETE count', async () => {
    const { DB } = await openDb();
    await put(DB, { kind: 'account', vendor: 'claude', subject: 'a', until: now() + 60 });
    const k = { kind: 'account', vendor: 'claude', subject: 'a' };
    assert.deepEqual((await clear(DB, k)).body.cleared, 1);
    assert.deepEqual((await clear(DB, k)).body.cleared, 0);
    assert.deepEqual((await list(DB, 'account')).body.rows, []);
    assert.equal((await clear(DB, { ...k, kind: 'quota' })).status, 400);
  });

  await t.test('W7 validation: 400 per bad field, model/<acct> accepted', async () => {
    const { db, DB } = await openDb();
    const ok = { kind: 'account', vendor: 'claude', subject: 'a', until: now() + 60 };
    for (const bad of [
      { kind: 'quota' }, { vendor: 'bad vendor' }, { subject: 'a/b' }, { kind: 'lane', subject: 'a/b' },
      { kind: 'model', subject: 'a/b/c' }, { kind: 'model', subject: '/a' }, { until: 'soon' },
      { until: 1.5 }, { until: -1 }, { since: 'x' }, { vendor: undefined },
    ]) {
      const r = await put(DB, { ...ok, ...bad });
      assert.equal(r.status, 400, `accepted ${JSON.stringify(bad)}`);
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM fleet_cooldowns').get().n, 0);
    assert.equal((await put(DB, { ...ok, kind: 'model', subject: 'claude-opus/acct' })).status, 200);
    assert.deepEqual(COOLDOWN_KINDS, ['account', 'model', 'lane']);
  });

  await t.test('W8 an until past 8 days is refused, never clamped', async () => {
    const { DB } = await openDb();
    assert.equal(COOLDOWN_MAX_S, 691200);
    const r = await put(DB, { kind: 'account', vendor: 'claude', subject: 'a', until: now() + COOLDOWN_MAX_S + 60 });
    assert.equal(r.status, 400);
    assert.deepEqual((await list(DB)).body.rows, []);
    const r2 = await put(DB, { kind: 'account', vendor: 'claude', subject: 'a', until: now() + COOLDOWN_MAX_S - 60 });
    assert.equal(r2.status, 200);
  });

  await t.test('W9 truncated at 500 rows', async () => {
    const { db, DB } = await openDb();
    for (let i = 0; i < 499; i++) insertRaw(db, 'account', 'claude', `a${String(i).padStart(3, '0')}`, FUT);
    const g1 = await list(DB, 'account');
    assert.equal(g1.body.rows.length, 499);
    assert.equal(g1.body.truncated, false);
    insertRaw(db, 'account', 'claude', 'zzz', FUT);
    const g2 = await list(DB, 'account');
    assert.equal(g2.body.rows.length, 500);
    assert.equal(g2.body.truncated, true);
  });

  await t.test('W10 codex/default is not a claude account; kind filter; ordering', async () => {
    const { DB } = await openDb();
    const u = now() + 600;
    await put(DB, { kind: 'lane', vendor: 'codex', subject: 'hub', until: u });
    await put(DB, { kind: 'account', vendor: 'codex', subject: 'default', until: u });
    await put(DB, { kind: 'model', vendor: 'claude', subject: 'claude-x/a', until: u });
    const acc = await list(DB, 'account');
    assert.deepEqual(acc.body.rows.map((r) => `${r.vendor}/${r.subject}`), ['codex/default']);
    assert.equal(acc.body.rows.filter((r) => r.vendor === 'claude').length, 0);
    assert.equal((await list(DB, 'unknown')).status, 400);
    const all = await list(DB);
    assert.deepEqual(all.body.rows.map((r) => r.kind), ['account', 'lane', 'model']);
  });

  await t.test('W11 the family sits behind the bearer', async () => {
    const { DB } = await openDb();
    assert.equal((await call(DB, '/api/cooldowns', { secret: null })).status, 401);
    assert.equal((await call(DB, '/api/cooldowns', { method: 'POST', secret: null,
      body: { kind: 'account', vendor: 'claude', subject: 'a', until: now() + 60 } })).status, 401);
  });
});
