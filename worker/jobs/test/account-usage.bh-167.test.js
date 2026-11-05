// BH-1914 (BH-167.1): per-account usage computed from cost_rows.
//
// WHAT IS PINNED
//   T1* (pure): shapeAccountUsage over rows shaped exactly like the route's
//     Read 1/2/3 output. usd is over PRICED rows only and null when a group is
//     all-unpriced; the NULL/'' account is its own `account: null` entry; the
//     meter joins through the reversed account map; cross_check is
//     `comparable` only for a fully-overage span with a positive delta, and
//     every other state carries no gap keys; order is usd desc, nulls last.
//   T2* (route): GET /api/metrics/account-usage through the real worker.fetch
//     on a REAL schema.sql database behind the node:sqlite shim, so the SQL
//     itself is under test: the window bounds, the priced-only sum, the poll
//     span sum and the truncated flags.
//
// The worker's clock is the real one: every fixture time is ago(ms) off the ONE
// anchor below, and the offsets (>= 1h) dwarf the suite's run time.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { shapeAccountUsage } from '../src/lib/account-usage.js';
import { parseAccountMap, ANCHOR_DEFAULT_ACCOUNT_MAP } from '../src/lib/core.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture below is ago(ms) off it
const H = 3600e3;
const isoZ = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (ms) => isoZ(ANCHOR - ms);

const MK = 'claude:operator@example.com';
const GM = 'claude:fixture-other@example.com';
const MAP = parseAccountMap(ANCHOR_DEFAULT_ACCOUNT_MAP);

// ── pure fixtures, shaped like the route's reads ──────────────────────────────
const group = (account, over = {}) => ({
  account, calls: 1, priced_calls: 1, usd: 1, unpriced_calls: 0,
  input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0, untokened_calls: 1,
  first_ts: ago(2 * H), last_ts: ago(H), ...over,
});
const snap = (msAgo, used, over = {}) => ({
  box: 'project-6-account', ts: ago(msAgo), session_pct: 40, weekly_pct: 100,
  weekly_resets_at: '2026-10-01T00:00:00Z', extra_enabled: 1, extra_used_usd: used,
  spend_limit_reached: 0, ...over,
});
const WIN = { window: '5h', from: ago(5 * H), to: ago(0) };
const byAccount = (out, a) => out.accounts.find((e) => e.account === a);

test('T1b: usd sums priced rows only, all-unpriced is null, null/empty account is its own entry', () => {
  const out = shapeAccountUsage({
    ...WIN, accountMap: new Map(),
    groups: [
      group('a', { calls: 3, priced_calls: 2, usd: 3.5, unpriced_calls: 1 }),
      group('b', { calls: 2, priced_calls: 0, usd: null, unpriced_calls: 2 }),
      group(null, { calls: 2, usd: 0.1 }),
      group('', { calls: 1, usd: 0.05 }),
    ],
  });
  const a = byAccount(out, 'a');
  assert.equal(a.usd, 3.5);
  assert.equal(a.unpriced_calls, 1);
  assert.equal(a.calls, 3);
  assert.equal(byAccount(out, 'b').usd, null);
  const nulls = out.accounts.filter((e) => e.account === null);
  assert.equal(nulls.length, 1, JSON.stringify(out.accounts));
  assert.equal(nulls[0].calls, 3);
  assert.equal(nulls[0].usd, 0.15);
  assert.equal(nulls[0].meter, null);
  assert.equal(out.accounts.length, 3);
  assert.equal(a.calls + byAccount(out, 'b').calls + nulls[0].calls, out.totals.calls);
});

test('T1c: 3 fully-overage polls $100->$150 against $40 of span rows is comparable, gap_pct 20', () => {
  const snaps = [snap(3 * H, 100), snap(2 * H, 125), snap(H, 150, { session_pct: 55 })];
  const out = shapeAccountUsage({
    ...WIN, accountMap: MAP, groups: [group(MK, { usd: 40, calls: 4, priced_calls: 4 })],
    snapshots: snaps, spanSums: { [MK]: { usd: 40, unpriced: 0 } },
  });
  const e = byAccount(out, MK);
  assert.deepEqual(e.cross_check, {
    state: 'comparable', meter_delta_usd: 50, rows_usd: 40, unpriced_in_span: 0,
    gap_usd: 10, gap_pct: 20, span_from: ago(3 * H), span_to: ago(H),
  });
  assert.equal(e.meter.label, 'project-6-account');
  assert.equal(e.meter.polls, 3);
  assert.equal(e.meter.session_pct, 55);
  assert.equal(e.meter.weekly_pct, 100);
  assert.equal(e.meter.extra_used_usd, 150);
});

test('T1c: gap_pct is absolute when rows exceed the meter', () => {
  const out = shapeAccountUsage({
    ...WIN, accountMap: MAP, groups: [group(MK)],
    snapshots: [snap(3 * H, 100), snap(H, 150)], spanSums: { [MK]: { usd: 60, unpriced: 2 } },
  });
  const cc = byAccount(out, MK).cross_check;
  assert.equal(cc.gap_usd, -10);
  assert.equal(cc.gap_pct, 20);
  assert.equal(cc.unpriced_in_span, 2);
});

test('T1d negatives: partial overage, one poll, unmapped account, reset are never comparable', () => {
  const run = (snapshots, groups = [group(MK)]) => shapeAccountUsage({
    ...WIN, accountMap: MAP, groups, snapshots, spanSums: { [MK]: { usd: 40, unpriced: 0 } },
  });
  const partial = byAccount(run([snap(3 * H, 100, { weekly_pct: 80 }), snap(2 * H, 125), snap(H, 150)]), MK);
  assert.equal(partial.cross_check.state, 'unmeasured');
  assert.equal('gap_pct' in partial.cross_check, false);
  assert.equal('gap_usd' in partial.cross_check, false);
  assert.match(partial.cross_check.reason, /weekly credits/);

  const single = byAccount(run([snap(H, 150)]), MK);
  assert.equal(single.cross_check.state, 'unmeasured');
  assert.equal('gap_pct' in single.cross_check, false);

  const reset = byAccount(run([snap(3 * H, 150), snap(H, 100)]), MK);
  assert.equal(reset.cross_check.state, 'unmeasured');
  assert.equal('gap_pct' in reset.cross_check, false);

  const other = byAccount(run([snap(3 * H, 100), snap(H, 150)], [group(MK), group('claude:someone@else')]),
    'claude:someone@else');
  assert.equal(other.meter, null);
  assert.equal(other.cross_check.state, 'no-login');
  assert.equal('gap_pct' in other.cross_check, false);
});

test('T1e: a mapped meter account with no rows still gets an entry', () => {
  const out = shapeAccountUsage({
    ...WIN, accountMap: MAP, groups: [], snapshots: [snap(3 * H, 100), snap(H, 150)],
  });
  const e = byAccount(out, MK);
  assert.ok(e, JSON.stringify(out.accounts));
  assert.equal(e.calls, 0);
  assert.equal(e.usd, null);
  assert.deepEqual(e.projects, []);
  assert.equal(e.first_ts, null);
  assert.equal(e.meter.polls, 2);
  // The meter moved $50 and no row bills the account: the largest possible gap,
  // so it is comparable at 100% (the #2068 lead review), never "unmeasured".
  assert.equal(e.cross_check.state, 'comparable', JSON.stringify(e.cross_check));
  assert.equal(e.cross_check.rows_usd, 0);
  assert.equal(e.cross_check.gap_pct, 100);
  assert.equal(out.totals.usd, null);
});

test('T1i: the meter moved and the span rows are $0 or all unpriced: comparable, gap_pct 100, unpriced carried', () => {
  const snaps = [snap(3 * H, 100), snap(2 * H, 125), snap(H, 150)];
  const allUnpriced = shapeAccountUsage({
    ...WIN, accountMap: MAP, groups: [group(MK, { usd: null, priced_calls: 0, unpriced_calls: 5, calls: 5 })],
    snapshots: snaps, spanSums: { [MK]: { usd: 0, unpriced: 5 } },
  });
  assert.deepEqual(byAccount(allUnpriced, MK).cross_check, {
    state: 'comparable', meter_delta_usd: 50, rows_usd: 0, unpriced_in_span: 5,
    gap_usd: 50, gap_pct: 100, span_from: ago(3 * H), span_to: ago(H),
  });
  const noRows = shapeAccountUsage({
    ...WIN, accountMap: MAP, groups: [], snapshots: snaps, spanSums: {},
  });
  const cc = byAccount(noRows, MK).cross_check;
  assert.equal(cc.state, 'comparable', JSON.stringify(cc));
  assert.equal(cc.rows_usd, 0);
  assert.equal(cc.unpriced_in_span, 0);
  assert.equal(cc.gap_pct, 100);
  // The meter still decides: a meter that did not move stays unmeasured, rows or not.
  const flat = shapeAccountUsage({
    ...WIN, accountMap: MAP, groups: [], snapshots: [snap(3 * H, 150), snap(H, 150)],
    spanSums: { [MK]: { usd: 0, unpriced: 5 } },
  });
  assert.equal(byAccount(flat, MK).cross_check.state, 'unmeasured');
  assert.equal('gap_pct' in byAccount(flat, MK).cross_check, false);
});

test('T1f: usd desc with nulls last; totals.usd sums the priced, null when none is', () => {
  const out = shapeAccountUsage({
    ...WIN, accountMap: new Map(),
    groups: [
      group('n', { usd: null, priced_calls: 0, unpriced_calls: 1 }),
      group('one', { usd: 1 }),
      group('five', { usd: 5 }),
    ],
  });
  assert.deepEqual(out.accounts.map((e) => e.account), ['five', 'one', 'n']);
  assert.equal(out.totals.usd, 6);
  assert.equal(out.totals.calls, 3);
  assert.equal(out.totals.unpriced_calls, 1);
  const none = shapeAccountUsage({
    ...WIN, accountMap: new Map(), groups: [group('n', { usd: null, priced_calls: 0 })],
  });
  assert.equal(none.totals.usd, null);
});

test('T1g: projects attach to their account, null project kept, usd null rule applies', () => {
  const out = shapeAccountUsage({
    ...WIN, accountMap: new Map(), groups: [group(MK, { calls: 3 })],
    projects: [
      { account: MK, project: 'project-3', calls: 1, priced_calls: 1, usd: 0.75, unpriced_calls: 0,
        input_toks: 400, output_toks: 100, cache_read: 0, cache_write: 0 },
      { account: MK, project: null, calls: 1, priced_calls: 0, usd: null, unpriced_calls: 1,
        input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0 },
      { account: MK, project: 'project-5', calls: 1, priced_calls: 1, usd: 1.25, unpriced_calls: 0,
        input_toks: 1000, output_toks: 200, cache_read: 5000, cache_write: 300 },
      { account: 'x', project: 'elsewhere', calls: 1, priced_calls: 1, usd: 9, unpriced_calls: 0,
        input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0 },
    ],
  });
  const e = byAccount(out, MK);
  assert.deepEqual(e.projects.map((p) => [p.project, p.usd]), [['project-5', 1.25], ['project-3', 0.75], [null, null]]);
  assert.equal(e.projects[0].cache_read, 5000);
});

test('T1h: the truncated input is copied, never aliased, and defaults to all false', () => {
  const t = { groups: true, projects: false, snapshots: false };
  const out = shapeAccountUsage({ ...WIN, truncated: t });
  assert.deepEqual(out.truncated, t);
  assert.notEqual(out.truncated, t);
  assert.deepEqual(shapeAccountUsage(WIN).truncated, { groups: false, projects: false, snapshots: false });
});

// ── route, on a real schema ──────────────────────────────────────────────────
const call = (DB, path, { auth = true } = {}) => {
  const headers = {};
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  return worker.fetch(new Request(`https://jobs.test${path}`, { headers }), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

let seq = 0;
const row = (db, { account, msAgo, usd = null, project = null, inp = null, out = null, cr = null, cw = null }) => {
  seq += 1;
  db.prepare(
    `INSERT INTO cost_rows (box, row_hash, line_no, ts, project, input_toks, output_toks,
                            cache_read, cache_write, cost_usd, auth_account, inserted_at)
     VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`
  ).run('hub', `h${seq}`, seq, ago(msAgo), project, inp, out, cr, cw, usd, account, ago(0));
};
const poll = (db, msAgo, used) => db.prepare(
  `INSERT INTO extra_usage_snapshots (box, ts, session_pct, weekly_pct, weekly_resets_at,
                                      extra_enabled, extra_used_usd, spend_limit_reached)
   VALUES (?,?,?,?,?,?,?,?)`
).run('project-6-account', ago(msAgo), 30, 100, '2026-10-01T00:00:00Z', 1, used, 0);

// The ticket's T2a fixture, verbatim.
const seedTicket = (db) => {
  row(db, { account: MK, msAgo: 2 * H, usd: 1.25, project: 'project-5', inp: 1000, out: 200, cr: 5000, cw: 300 });
  row(db, { account: MK, msAgo: 4 * H, usd: 0.75, project: 'project-3', inp: 400, out: 100 });
  row(db, { account: MK, msAgo: 6 * H, usd: 10 });
  row(db, { account: MK, msAgo: 72 * H, usd: 5 });
  row(db, { account: MK, msAgo: H });
  row(db, { account: GM, msAgo: H, usd: 2 });
  row(db, { account: null, msAgo: H, usd: 0.1 });
};

test('BH-1914 GET /api/metrics/account-usage on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('T2a: window=5h, the ticket fixture', async () => {
    const { db, DB } = await openDb();
    seedTicket(db);
    const r = await call(DB, '/api/metrics/account-usage?window=5h');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.window, '5h');
    assert.deepEqual(r.body.accounts.map((e) => e.account), [MK, GM, null]);
    const mk = r.body.accounts[0];
    assert.equal(mk.usd, 2);
    assert.equal(mk.calls, 3);
    assert.equal(mk.unpriced_calls, 1);
    assert.equal(mk.input_toks, 1400);
    assert.equal(mk.output_toks, 300);
    assert.equal(mk.cache_read, 5000);
    assert.equal(mk.cache_write, 300);
    assert.equal(mk.untokened_calls, 1);
    assert.equal(mk.first_ts, ago(4 * H));
    assert.equal(mk.last_ts, ago(H));
    assert.deepEqual(mk.projects.map((p) => [p.project, p.usd, p.calls]),
      [['project-5', 1.25, 1], ['project-3', 0.75, 1], [null, null, 1]]);
    assert.equal(mk.meter, null);
    assert.equal(mk.cross_check.state, 'no-login');
    assert.equal(r.body.accounts[1].usd, 2);
    assert.equal(r.body.accounts[2].usd, 0.1);
    assert.equal(r.body.accounts[2].calls, 1);
    assert.equal(r.body.totals.usd, 4.1);
    assert.equal(r.body.totals.calls, 5);
    assert.equal(r.body.totals.unpriced_calls, 1);
    assert.deepEqual(r.body.truncated, { groups: false, projects: false, snapshots: false });
  });

  await t.test('T2b: window=7d takes the older rows in', async () => {
    const { db, DB } = await openDb();
    seedTicket(db);
    const r = await call(DB, '/api/metrics/account-usage?window=7d');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const mk = r.body.accounts.find((e) => e.account === MK);
    assert.equal(mk.usd, 17);
    assert.equal(mk.calls, 5);
  });

  await t.test('T2c: overage polls are comparable, and only rows inside the poll span count', async () => {
    const { db, DB } = await openDb();
    poll(db, 3 * H, 100); poll(db, 2 * H, 125); poll(db, H, 150);
    row(db, { account: MK, msAgo: 2.5 * H, usd: 30 });
    row(db, { account: MK, msAgo: 1.5 * H, usd: 10 });
    row(db, { account: MK, msAgo: 1.4 * H });
    row(db, { account: MK, msAgo: 4 * H, usd: 5 });
    const r = await call(DB, '/api/metrics/account-usage?window=5h');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const mk = r.body.accounts.find((e) => e.account === MK);
    assert.equal(mk.usd, 45);
    assert.equal(mk.cross_check.state, 'comparable', JSON.stringify(mk.cross_check));
    assert.equal(mk.cross_check.rows_usd, 40);
    assert.equal(mk.cross_check.meter_delta_usd, 50);
    assert.equal(mk.cross_check.gap_pct, 20);
    assert.equal(mk.cross_check.unpriced_in_span, 1);
    assert.equal(mk.meter.label, 'project-6-account');
    assert.equal(mk.meter.polls, 3);
  });

  await t.test('T2f: meter +$50 against an all-unpriced span is comparable at 100%, unpriced carried', async () => {
    const { db, DB } = await openDb();
    poll(db, 3 * H, 100); poll(db, 2 * H, 125); poll(db, H, 150);
    row(db, { account: MK, msAgo: 2.5 * H });
    row(db, { account: MK, msAgo: 1.5 * H });
    row(db, { account: MK, msAgo: 1.4 * H });
    const r = await call(DB, '/api/metrics/account-usage?window=5h');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const mk = r.body.accounts.find((e) => e.account === MK);
    assert.equal(mk.usd, null);
    assert.equal(mk.cross_check.state, 'comparable', JSON.stringify(mk.cross_check));
    assert.equal(mk.cross_check.rows_usd, 0);
    assert.equal(mk.cross_check.meter_delta_usd, 50);
    assert.equal(mk.cross_check.gap_pct, 100);
    assert.equal(mk.cross_check.unpriced_in_span, 3);
  });

  await t.test('T2d: no bearer is 401; small seeds are not truncated', async () => {
    const { db, DB } = await openDb();
    seedTicket(db);
    assert.equal((await call(DB, '/api/metrics/account-usage?window=5h', { auth: false })).status, 401);
    const r = await call(DB, '/api/metrics/account-usage?window=5h');
    assert.deepEqual(r.body.truncated, { groups: false, projects: false, snapshots: false });
  });

  await t.test('T2e: a read that returns exactly its LIMIT sets its flag', async () => {
    const { db, DB } = await openDb();
    for (let i = 0; i < 200; i += 1) row(db, { account: `acct-${i}`, msAgo: H, usd: 0.01 });
    const r = await call(DB, '/api/metrics/account-usage?window=5h');
    assert.equal(r.status, 200);
    assert.equal(r.body.truncated.groups, true);
    assert.equal(r.body.truncated.projects, false);
    assert.equal(r.body.accounts.length, 200);
  });
});
