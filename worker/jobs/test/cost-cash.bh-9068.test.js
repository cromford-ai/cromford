import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { CASH_OVERAGE_SQL, CASH_METERED_SQL, cashSummary } from '../src/routes/cost-breakdown.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-9068 C3: GET /api/metrics/cost-breakdown carries one `cash` object for the
// UTC day of `until`: subscriptions (usd_per_month / days in that month, per
// account), overage (the day's rise of each account's extra-usage meter) and
// metered (the day's vendor_spend usd). cash_usd is their sum, or null with
// `unknown` naming each missing part — never a 0 for money nobody measured.
// Two inputs are out of scope, not missing, and are named in `excluded` without
// making cash null: the overage of an account whose polls are status=no-login,
// and a vendor whose polls are all status=no-spend-endpoint (subscription-
// billed: its price moves under subscriptions).
// The account list is the D1 registry; each price is the settings row
// cost.usd_per_month.<account>. Driven through the real worker.fetch over the
// composed schema in node:sqlite, clock pinned, every fixture row written by
// the route that writes it in prod (registry import, settings PUT, the two
// metric POSTs).

const SECRET = 'test-secret';
const ADMIN = 'registry-admin-fixture';
const SCHEMA = jobsSchemaSql();
const ACCOUNTS = ['acct-fixture-a', 'acct-fixture-b', 'acct-fixture-c'];

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA|WITH)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async (col) => {
      const r = exec(sql, binds);
      if (!r.results.length) return null;
      return col ? r.results[0][col] : r.results[0];
    },
    all: async () => exec(sql, binds),
  });
  return { prepare: (sql) => make(sql, []), batch: async (s) => s.map((x) => exec(x._sql, x._binds)) };
}

// September 2099 has 30 days.
const NOW_MS = Date.parse('2099-09-25T12:00:00Z');
const at = (hhmm) => `2099-09-25T${hhmm}:00.000Z`;
const YESTERDAY = '2099-09-24T22:00:00.000Z';
const close = (a, b, msg) => assert.ok(typeof a === 'number' && Math.abs(a - b) < 1e-6, `${msg}: ${a} != ${b}`);

function freshD1(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET, REGISTRY_ADMIN_TOKEN: ADMIN } };
}

async function call(env, method, path, body) {
  const res = await worker.fetch(new Request('https://jobs.test' + path, {
    method,
    headers: { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json', 'x-registry-admin-token': ADMIN },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function okCall(env, method, path, body) {
  const r = await call(env, method, path, body);
  assert.ok(r.status >= 200 && r.status < 300, `${method} ${path}: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}
const breakdown = (env, qs = '') => okCall(env, 'GET', '/api/metrics/cost-breakdown' + qs);
const putPrice = (env, account, value) => okCall(env, 'PUT', '/api/settings',
  { key: `cost.usd_per_month.${account}`, value: String(value) });
const snap = (env, box, ts, used, status) => okCall(env, 'POST', '/api/metrics/extra-usage', {
  box, ts, session_pct: 10, weekly_pct: 100, extra_enabled: used === null ? null : 1,
  extra_used_usd: used, spend_limit_reached: 0, in_overage: 1, status,
});
const spend = (env, vendor, ts, usd, kind, status) => okCall(env, 'POST', '/api/metrics/vendor-spend', {
  vendor, ts, window_start: null, window_end: ts, usd, kind, status, note: 'fixture',
});

// The registry: each account has a login box and a cost_rows box (two kinds,
// so the account read must DISTINCT them).
const importRegistry = (env, accounts) => okCall(env, 'POST', '/api/registry/import', {
  actor: 'cost-cash-fixture',
  projects: [{ project: 'fixture-project', box: 'box-fixture-0', cron_offset: 0, position: 0, status: 'active', repo: 'fixture-org/fixture-project', board_prefix: '/api/board', prod: 'https://fixture.example.com' }],
  boxes: accounts.map((_, i) => ({ box: `box-fixture-${i}`, box_id: `boxfixture${i}` })),
  lane_boxes: [],
  box_accounts: accounts.flatMap((a, i) => [
    { account: a, kind: 'login', box: `box-fixture-${i}` },
    { account: a, kind: 'cost_rows', box: `box-fixture-${i}` },
  ]),
});

// Prices: account i costs 30*(i+1) a month, so its day share is (i+1).
const PRICE = (i) => 30 * (i + 1);
const SUBS_DAY = ACCOUNTS.reduce((s, _, i) => s + (i + 1), 0);

// The full, all-known day. ACCOUNTS[0]'s meter rises 10 -> 12.5, resets to 0
// at the month line and rises to 1 (overage 3.5); a failed poll in between is
// not a reading. Every other account polls ok twice at the same value (0).
// Yesterday's readings and spend stay out of today.
async function seedKnownDay(env) {
  await importRegistry(env, ACCOUNTS);
  for (let i = 0; i < ACCOUNTS.length; i++) await putPrice(env, ACCOUNTS[i], PRICE(i));
  const a0 = ACCOUNTS[0];
  await snap(env, a0, YESTERDAY, 2, 'ok');
  await snap(env, a0, at('01:00'), 10, 'ok');
  await snap(env, a0, at('02:00'), null, 'no-login');
  await snap(env, a0, at('03:00'), 12.5, 'ok');
  await snap(env, a0, at('04:00'), 0, 'ok');
  await snap(env, a0, at('05:00'), 1, 'ok');
  for (const a of ACCOUNTS.slice(1)) {
    await snap(env, a, at('01:00'), 5, 'ok');
    await snap(env, a, at('09:00'), 5, 'ok');
  }
  await spend(env, 'openrouter', YESTERDAY, 50, 'metered', 'ok');
  await spend(env, 'openrouter', at('01:00'), 1.25, 'metered', 'ok');
  await spend(env, 'openrouter', at('02:00'), 0.75, 'metered', 'ok');
  await spend(env, 'fly', at('01:00'), 2, 'computed', 'ok');
}
const OVERAGE = 3.5;
const METERED = 1.25 + 0.75 + 2;

test('C1: cash = subscriptions + overage + metered for the day, through the real route', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1(t);
  await seedKnownDay(env);
  const b = await breakdown(env);
  const c = b.cash;
  assert.ok(c, 'the unfiltered breakdown carries a cash object');
  assert.equal(SUBS_DAY, 6);
  assert.equal(c.day, '2099-09-25');
  close(c.subscriptions_usd, SUBS_DAY, 'subscriptions = sum of usd_per_month / 30');
  close(c.overage_usd, OVERAGE, 'overage = the meter rise, a reset not counted down');
  close(c.metered_usd, METERED, 'metered = today vendor_spend usd');
  close(c.cash_usd, SUBS_DAY + OVERAGE + METERED, 'cash = the sum of the three');
  assert.deepEqual(c.unknown, []);
  assert.deepEqual(c.excluded, []);
  // The parts are drillable: one entry per account and per vendor.
  assert.deepEqual(c.accounts.map((a) => a.account).sort(), [...ACCOUNTS].sort());
  close(c.accounts.find((a) => a.account === ACCOUNTS[0]).overage_usd, OVERAGE, 'account overage');
  assert.deepEqual(c.vendors.map((v) => v.vendor).sort(), ['fly', 'openrouter']);
  // The existing fields are unchanged by the addition.
  assert.deepEqual(b.group, ['project']);
  assert.ok(b.total && 'usd' in b.total && 'cash_usd' in b.total);
});

test('C2: an account with no price row makes cash null and names that account, never $0', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  await seedKnownDay(env);
  const missing = ACCOUNTS[1];
  db.prepare('DELETE FROM settings WHERE key=?').run(`cost.usd_per_month.${missing}`);
  const c = (await breakdown(env)).cash;
  assert.equal(c.cash_usd, null);
  assert.equal(c.subscriptions_usd, null);
  assert.ok(c.unknown.includes(`subscription:${missing}`), JSON.stringify(c.unknown));
  assert.equal(c.unknown.filter((u) => u.startsWith('subscription:')).length, 1);
  // The known parts still read as numbers.
  close(c.overage_usd, OVERAGE, 'overage still known');
  close(c.metered_usd, METERED, 'metered still known');
});

test('C3: a price row that is not a number >= 0 is unknown, not read as 0', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1(t);
  await seedKnownDay(env);
  // "null" is what bin/cost-prices-push.sh writes for a catalog null.
  for (const v of ['null', 'tbd', '-5']) {
    await putPrice(env, ACCOUNTS[0], v);
    const c = (await breakdown(env)).cash;
    assert.equal(c.cash_usd, null, v);
    assert.equal(c.accounts.find((a) => a.account === ACCOUNTS[0]).usd_per_month, null, v);
    assert.deepEqual(c.unknown, [`subscription:${ACCOUNTS[0]}`], v);
  }
});

test('C4: a meter with under two readings today is unknown overage, not 0', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  await seedKnownDay(env);
  const dead = ACCOUNTS[2];
  // Failed polls (status=error) and no reading: a gap, not a known no-login.
  db.prepare('DELETE FROM extra_usage_snapshots WHERE box=?').run(dead);
  await snap(env, dead, at('01:00'), null, 'error');
  await snap(env, dead, at('02:00'), null, 'error');
  let c = (await breakdown(env)).cash;
  assert.equal(c.overage_usd, null);
  assert.equal(c.cash_usd, null);
  assert.deepEqual(c.unknown, [`overage:${dead}`]);
  assert.deepEqual(c.excluded, []);
  close(c.subscriptions_usd, SUBS_DAY, 'subscriptions still known');
  // One usd reading next to no-login polls is still a gap: the meter was
  // readable today, so its rise is missing, not out of scope.
  db.prepare('DELETE FROM extra_usage_snapshots WHERE box=?').run(dead);
  await snap(env, dead, at('01:00'), 4, 'ok');
  await snap(env, dead, at('02:00'), null, 'no-login');
  c = (await breakdown(env)).cash;
  assert.equal(c.cash_usd, null);
  assert.deepEqual(c.unknown, [`overage:${dead}`]);
  assert.deepEqual(c.excluded, []);
  // No snapshot row at all today: unknown too.
  db.prepare('DELETE FROM extra_usage_snapshots WHERE box=?').run(dead);
  c = (await breakdown(env)).cash;
  assert.equal(c.cash_usd, null);
  assert.deepEqual(c.unknown, [`overage:${dead}`]);
});

test('C5: a vendor with an unmeasured row, or no vendor row at all, is unknown metered', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  await seedKnownDay(env);
  // A failed poll has no usd. That is money nobody measured.
  for (const status of ['error', 'auth-failed']) {
    db.prepare("DELETE FROM vendor_spend WHERE vendor='xai'").run();
    await spend(env, 'xai', at('03:00'), null, 'metered', status);
    const c = (await breakdown(env)).cash;
    assert.equal(c.metered_usd, null, status);
    assert.equal(c.cash_usd, null, status);
    assert.deepEqual(c.unknown, ['metered:xai'], status);
    assert.deepEqual(c.excluded, [], status);
  }

  db.prepare('DELETE FROM vendor_spend').run();
  const c = (await breakdown(env)).cash;
  assert.equal(c.metered_usd, null);
  assert.deepEqual(c.unknown, ['metered:no-vendor-spend-row']);
});

test('C6: a filtered or rows read carries no cash (the line is fleet-wide), and nothing else changes', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1(t);
  await seedKnownDay(env);
  const f = await breakdown(env, '?project=other-project');
  assert.equal(f.cash, undefined);
  assert.equal(f.total.calls, 0);
  assert.deepEqual(f.groups, []);
  const r = await breakdown(env, '?group=rows');
  assert.equal(r.cash, undefined);
  assert.deepEqual(r.rows, []);
});

test('C7: cashSummary divides by the days in the month, and an empty account list is unknown', () => {
  const meter = (box) => ({ box, readings: 2, usd: 0 });
  const fly = [{ vendor: 'fly', polls: 1, usd: 1, unmeasured: 0 }];
  // February 2100 has 28 days (2100 is not a leap year).
  const s = cashSummary({
    day: '2100-02-10', accounts: ['a', 'b', 'a'], prices: new Map([['a', '280'], ['b', '0']]),
    overageRows: [meter('a'), meter('b')], vendorRows: fly,
  });
  assert.equal(s.accounts.length, 2, 'an account listed twice is counted once');
  assert.equal(s.accounts.find((x) => x.account === 'a').day_usd, 10);
  assert.equal(s.accounts.find((x) => x.account === 'b').day_usd, 0, 'a price of 0 is a real 0');
  assert.equal(s.subscriptions_usd, 10);
  assert.equal(s.cash_usd, 11);
  assert.deepEqual(s.unknown, []);
  const none = cashSummary({ day: '2100-02-10', accounts: [], prices: new Map(), overageRows: [], vendorRows: fly });
  assert.equal(none.subscriptions_usd, null);
  assert.equal(none.cash_usd, null);
  assert.deepEqual(none.unknown, ['subscription:no-registry-account']);
});

// The row bin/vendor-spend-pull.sh writes for codex every hour on this fleet:
// no admin key, so no usd, kind=computed, status=no-spend-endpoint.
const codexRow = (env, ts) => spend(env, 'codex', ts, null, 'computed', 'no-spend-endpoint');

test('C9: a subscription-billed vendor (the hourly codex row) is not metered cash; its price sits under subscriptions', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { env } = freshD1(t);
  await seedKnownDay(env);
  await codexRow(env, YESTERDAY);
  for (const hh of ['01:00', '02:00', '03:00']) await codexRow(env, at(hh));
  // No price row for the vendor yet: the subscription is unknown, by name. The
  // metered part is a number again, because the codex row is not cash.
  let c = (await breakdown(env)).cash;
  close(c.metered_usd, METERED, 'metered leaves the subscription-billed vendor out');
  assert.deepEqual(c.excluded, [{ part: 'metered', name: 'codex', why: 'subscription-billed' }]);
  assert.deepEqual(c.unknown, ['subscription:codex']);
  assert.equal(c.cash_usd, null);
  const v = c.vendors.find((x) => x.vendor === 'codex');
  assert.deepEqual({ usd: v.usd, polls: v.polls, unmeasured: v.unmeasured, excluded: v.excluded },
    { usd: null, polls: 3, unmeasured: 0, excluded: 'subscription-billed' });
  // With its price entered the line is a dollar number: the acceptance test
  // "cash = subscriptions + overage + metered for the day" holds with codex polled.
  await putPrice(env, 'codex', 60);
  c = (await breakdown(env)).cash;
  close(c.subscriptions_usd, SUBS_DAY + 2, 'subscriptions carry the vendor subscription (60 / 30 days)');
  close(c.metered_usd, METERED, 'metered');
  close(c.cash_usd, SUBS_DAY + 2 + OVERAGE + METERED, 'cash is a number');
  assert.deepEqual(c.unknown, []);
  assert.deepEqual(c.excluded, [{ part: 'metered', name: 'codex', why: 'subscription-billed' }]);
  const row = c.accounts.find((a) => a.account === 'codex');
  assert.deepEqual({ kind: row.kind, usd_per_month: row.usd_per_month, day_usd: row.day_usd, overage_usd: row.overage_usd },
    { kind: 'vendor', usd_per_month: 60, day_usd: 2, overage_usd: null });
  // The same vendor with an admin key: a measured poll today makes it metered
  // cash, and the no-endpoint polls beside it do not make it unknown.
  await spend(env, 'codex', at('04:00'), 0.5, 'metered', 'ok');
  c = (await breakdown(env)).cash;
  close(c.metered_usd, METERED + 0.5, 'a measured codex poll is metered cash');
  close(c.subscriptions_usd, SUBS_DAY, 'and it is no longer a subscription row');
  assert.deepEqual(c.excluded, []);
  assert.deepEqual(c.unknown, []);
  // A failed poll beside it is still unmeasured money.
  await spend(env, 'codex', at('05:00'), null, 'metered', 'error');
  c = (await breakdown(env)).cash;
  assert.equal(c.cash_usd, null);
  assert.deepEqual(c.unknown, ['metered:codex']);
});

test('C10: a no-login account is a named overage exclusion, and the rest of the line stays a number', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = freshD1(t);
  await seedKnownDay(env);
  const tokenOnly = ACCOUNTS[2];
  db.prepare('DELETE FROM extra_usage_snapshots WHERE box=?').run(tokenOnly);
  await snap(env, tokenOnly, at('01:00'), null, 'no-login');
  await snap(env, tokenOnly, at('02:00'), null, 'no-login');
  const c = (await breakdown(env)).cash;
  assert.deepEqual(c.excluded, [{ part: 'overage', name: tokenOnly, why: 'no-login' }]);
  assert.deepEqual(c.unknown, []);
  close(c.overage_usd, OVERAGE, 'overage is the sum over the accounts with a readable meter');
  close(c.cash_usd, SUBS_DAY + OVERAGE + METERED, 'cash is a number');
  const row = c.accounts.find((a) => a.account === tokenOnly);
  // Its own overage is never a 0: null, with the reason beside it.
  assert.deepEqual({ overage_usd: row.overage_usd, overage_excluded: row.overage_excluded, readings: row.readings },
    { overage_usd: null, overage_excluded: 'no-login', readings: 0 });
  close(row.day_usd, 3, 'its subscription is still counted');
  // Every account no-login: nothing measured the overage, so it is unknown.
  for (const a of ACCOUNTS.slice(0, 2)) {
    db.prepare('DELETE FROM extra_usage_snapshots WHERE box=?').run(a);
    await snap(env, a, at('01:00'), null, 'no-login');
  }
  const all = (await breakdown(env)).cash;
  assert.equal(all.overage_usd, null);
  assert.equal(all.cash_usd, null);
  assert.deepEqual(all.unknown, ['overage:no-readable-account']);
  assert.equal(all.excluded.length, 3);
});

test('C11: the ticket fleet shape: 3 login accounts, 3 setup-token accounts and codex polled give a dollar number', () => {
  const login = ['hub-a', 'hub-b', 'box-c'];
  const token = ['tok-d', 'tok-e', 'tok-f'];
  const s = cashSummary({
    day: '2099-09-25', accounts: [...login, ...token],
    prices: new Map([...login, ...token, 'codex'].map((a) => [a, '30'])),
    overageRows: [...login.map((box) => ({ box, readings: 6, usd: 1, no_login: 0 })),
      ...token.map((box) => ({ box, readings: 0, usd: null, no_login: 6 }))],
    vendorRows: [{ vendor: 'codex', polls: 12, usd: null, unmeasured: 0, no_endpoint: 12, measured: 0 },
      { vendor: 'fly', polls: 12, usd: 4, unmeasured: 0, no_endpoint: 0, measured: 12 }],
  });
  assert.equal(s.subscriptions_usd, 7, '6 accounts + the codex subscription, 30 / 30 days each');
  assert.equal(s.overage_usd, 3);
  assert.equal(s.metered_usd, 4);
  assert.equal(s.cash_usd, 14);
  assert.deepEqual(s.unknown, []);
  assert.deepEqual(s.excluded.map((e) => `${e.part}:${e.name}:${e.why}`), [
    'overage:tok-d:no-login', 'overage:tok-e:no-login', 'overage:tok-f:no-login', 'metered:codex:subscription-billed']);
  // Only subscription-billed vendors polled: no metered vendor measured anything.
  const only = cashSummary({
    day: '2099-09-25', accounts: login, prices: new Map([...login, 'codex'].map((a) => [a, '30'])),
    overageRows: login.map((box) => ({ box, readings: 2, usd: 0, no_login: 0 })),
    vendorRows: [{ vendor: 'codex', polls: 1, usd: null, unmeasured: 0, no_endpoint: 1, measured: 0 }],
  });
  assert.equal(only.metered_usd, null);
  assert.deepEqual(only.unknown, ['metered:no-vendor-spend-row']);
});

test('C8: the two cash statements SEARCH their ts index at seeded volume, never SCAN the table', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db } = freshD1(t);
  const insS = db.prepare(`INSERT INTO extra_usage_snapshots (box, ts, extra_used_usd, status) VALUES (?,?,?,?)`);
  const insV = db.prepare(`INSERT INTO vendor_spend (vendor, ts, usd, kind, status, updated_at) VALUES (?,?,?,?,?,?)`);
  const base = Date.parse('2099-06-01T00:00:00Z');
  db.exec('BEGIN');
  // 6 accounts polled every 10 min for ~90 days; 5 vendors hourly.
  for (let m = 0; m < 90 * 144; m++) {
    const ts = new Date(base + m * 600000).toISOString();
    for (let a = 0; a < 6; a++) insS.run(`acct-${a}`, ts, m / 100, 'ok');
    if (m % 6 === 0) for (let v = 0; v < 5; v++) insV.run(`vendor-${v}`, ts, 0.01, 'metered', 'ok', ts);
  }
  db.exec('COMMIT');
  for (const analyzed of [false, true]) {
    if (analyzed) db.exec('ANALYZE');
    for (const [sql, table, index] of [[CASH_OVERAGE_SQL, 'extra_usage_snapshots', 'idx_extra_usage_ts'],
      [CASH_METERED_SQL, 'vendor_spend', 'idx_vendor_spend_ts']]) {
      const plan = db.prepare('EXPLAIN QUERY PLAN ' + sql).all('2099-08-29T00:00:00Z', '2099-08-29T12:00:00Z')
        .map((r) => r.detail);
      assert.ok(!plan.some((d) => new RegExp(`^SCAN ${table}\\b`).test(d)), `${table} (analyzed=${analyzed}): ${plan.join(' | ')}`);
      // Unanalyzed, SQLite picks the ts index; after ANALYZE it may skip-scan the
      // (key, ts) primary key instead. Both bound the read by ts; a SCAN does not.
      const want = analyzed ? new RegExp(`^SEARCH ${table} USING INDEX \\S+ \\(.*ts>\\?`) : new RegExp(`^SEARCH ${table} USING INDEX ${index} \\(ts>\\?`);
      assert.ok(plan.some((d) => want.test(d)), `${table} (analyzed=${analyzed}) SEARCHes by ts: ${plan.join(' | ')}`);
    }
  }
});
