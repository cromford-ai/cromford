import test from 'node:test';
import assert from 'node:assert/strict';
import worker, {
  computeAnchored, meterAccounts, anchorSpanCandidates, anchorWindow,
  parseAccountMap, parseBuildDir, parseStageBreakdown,
  ANCHOR_DEFAULT_MAX_FACTOR, ANCHOR_OFF_FLAG,
} from '../src/index.js';

// GET /api/metrics/cost-anchored and the arithmetic behind it.
//
// WHAT IS ACTUALLY UNDER TEST. Not "does it return 200". This endpoint
// MULTIPLIES money, so its failure mode is a confident number 4x too big that
// somebody then budgets against. The properties pinned here are the ones whose
// failure is silent:
//
//   * a factor is only ever computed from a meter that MOVED across a span the
//     account was fully past its weekly credits for - anything else is
//     factor=1, stated as `unmeasured`/`no-login`, never a quiet 0;
//   * the denominator is the rows inside the METER SPAN, not the whole window
//     (the poller is hours old and the window is days, so the two differ by an
//     order of magnitude today);
//   * a box billing two accounts is anchored per account, never with one
//     box-wide multiplier;
//   * the raw dollars survive beside the anchored ones on every row;
//   * a build dir that carries no ticket key yields no ticket, rather than a
//     key parsed out of a project name;
//   * totals are over the whole window, not over the truncated page;
//   * the kill switch answers EMPTY, not raw-dollars-renamed-anchored.

const SECRET = 'test-secret';
const NOW = '2026-09-14T20:00:00Z';
const PR = (repo, n) => `https://github.com/${repo}/pull/${n}`;

// --- the primitives ---------------------------------------------------------

test('the account map drops malformed pairs rather than guessing at them', () => {
  const m = parseAccountMap('project-6-account=claude:a@b.c, hub=claude:d@e.f');
  assert.equal(m.get('project-6-account'), 'claude:a@b.c');
  assert.equal(m.get('hub'), 'claude:d@e.f');
  // An operator typo must not mint an account label out of half a pair.
  assert.equal(parseAccountMap('=nothing,alone,x=').size, 0);
  assert.equal(parseAccountMap(null).size, 0);
});

test('a build dir splits into project and ticket even though both carry hyphens', () => {
  assert.deepEqual(parseBuildDir('project-3-TK-109-202607241459'),
    { dir: 'project-3-TK-109-202607241459', project: 'project-3', key: 'TK-109', at: Date.parse('2026-07-24T14:59:00Z') });
  assert.equal(parseBuildDir('project-5-TK-680-202609141200').project, 'project-5');
  assert.equal(parseBuildDir('project-5-TK-680-202609141200').key, 'TK-680');
  // A hand-run hub build is NOT a ticket. Returning one would file its spend
  // under a key nobody can open.
  assert.equal(parseBuildDir('cost-rows-db-20260902').key, null);
  assert.equal(parseBuildDir('cost-rows-db-20260902').project, null);
  assert.equal(parseBuildDir('cost-rows-db-20260902').at, Date.parse('2026-09-02T00:00:00Z'));
  assert.equal(parseBuildDir('account-routing-20260906').key, null);
  assert.equal(parseBuildDir(''), null);
  // A stamp that is not a real instant is not a build dir either.
  assert.equal(parseBuildDir('project-3-TK-1-209913451299'), null);
});

test('a stage breakdown parses back into dollars per stage', () => {
  assert.deepEqual(parseStageBreakdown('execute:110.77;review:10.72'), { execute: 110.77, review: 10.72 });
  assert.deepEqual(parseStageBreakdown(''), {});
  assert.deepEqual(parseStageBreakdown('garbage;:5;x:notanumber'), {});
});

test('the window is 24h by default, 7d on request, and a named day is exact', () => {
  const now = Date.parse(NOW);
  assert.equal(anchorWindow({ now }).window, '24h');
  assert.equal(anchorWindow({ window: '7d', now }).window, '7d');
  assert.equal(anchorWindow({ window: '7d', now }).from, '2026-09-07T20:00:00Z');
  const day = anchorWindow({ day: '2026-09-13', now });
  assert.equal(day.from, '2026-09-13T00:00:00Z');
  assert.equal(day.to, '2026-09-14T00:00:00Z');
  // A junk day falls back to the rolling window: this is a poll, not a form.
  assert.equal(anchorWindow({ day: 'yesterday', now }).window, '24h');
});

// --- the meter --------------------------------------------------------------

const MAP = parseAccountMap('project-6-account=claude:project-6,hub=claude:hub');
const snap = (box, ts, used, weekly = 100, enabled = 1) =>
  ({ box, ts, extra_used_usd: used, weekly_pct: weekly, extra_enabled: enabled, weekly_resets_at: null, spend_limit_reached: 0 });

const meterOf = (snapshots) => meterAccounts({
  snapshots, accountMap: MAP, from: '2026-09-14T00:00:00Z', to: '2026-09-15T00:00:00Z',
});

test('the meter delta is last poll minus first, and only polls inside the window count', () => {
  const m = meterOf([
    snap('project-6-account', '2026-09-13T23:00:00Z', 1000),   // before the window
    snap('project-6-account', '2026-09-14T10:00:00Z', 1100),
    snap('project-6-account', '2026-09-14T14:00:00Z', 1160),
  ]);
  assert.equal(m.length, 1);
  assert.equal(m[0].label, 'claude:project-6');
  assert.equal(m[0].meter_delta_usd, 60);
  assert.equal(m[0].span_from, '2026-09-14T10:00:00Z');
  assert.equal(m[0].span_to, '2026-09-14T14:00:00Z');
  assert.equal(m[0].fully_overage, true);
});

test('a span that was not fully past its weekly credits is not a cash measurement', () => {
  const m = meterOf([
    snap('project-6-account', '2026-09-14T10:00:00Z', 1000, 87),
    snap('project-6-account', '2026-09-14T14:00:00Z', 1060, 100),
  ]);
  // The delta is still reported - it is a real fact about the meter - but it
  // may not become a factor, because part of that spend rode the credits the
  // cash meter never sees.
  assert.equal(m[0].meter_delta_usd, 60);
  assert.equal(m[0].fully_overage, false);
  assert.equal(anchorSpanCandidates(m).length, 0);
});

test('one poll is not a delta, and a box with no mapping is not an account', () => {
  const one = meterOf([snap('project-6-account', '2026-09-14T10:00:00Z', 1000)]);
  assert.equal(one[0].snapshots, 1);
  assert.equal(one[0].meter_delta_usd, null);
  assert.equal(anchorSpanCandidates(one).length, 0);
  assert.equal(meterOf([snap('orgo-desktop', '2026-09-14T10:00:00Z', 1000)]).length, 0);
});

// --- the anchoring ----------------------------------------------------------

const WIN = {
  window: '24h', from: '2026-09-14T00:00:00Z', to: '2026-09-15T00:00:00Z',
  from_ms: Date.parse('2026-09-14T00:00:00Z'), to_ms: Date.parse('2026-09-15T00:00:00Z'),
};

const METERS = meterOf([
  snap('project-6-account', '2026-09-14T10:00:00Z', 1000),
  snap('project-6-account', '2026-09-14T14:00:00Z', 1400),
]);

test('the factor is the meter delta over the rows inside the METER SPAN', () => {
  const out = computeAnchored({
    ...WIN, meters: METERS,
    // 400 of meter over 100 of rows inside the span = 4x, even though the
    // window holds 250 of rows. Using the window sum would report 1.6x and
    // quietly undercount every figure on the screen by more than half.
    spanSums: { 'claude:project-6': 100 },
    rowSums: [{ box: 'project-6', account: 'claude:project-6', usd: 250, calls: 40 }],
  });
  const a = out.accounts[0];
  assert.equal(a.state, 'metered');
  assert.equal(a.factor, 4);
  assert.equal(a.rows_usd, 250);
  assert.equal(a.rows_usd_span, 100);
  assert.equal(a.meter_delta_usd, 400);
  assert.equal(out.per_box[0].raw_usd, 250);
  assert.equal(out.per_box[0].anchored_usd, 1000);
});

test('every un-anchorable account multiplies by exactly one and says why', () => {
  const out = computeAnchored({
    ...WIN,
    meters: meterOf([
      snap('project-6-account', '2026-09-14T10:00:00Z', 1000),
      snap('project-6-account', '2026-09-14T14:00:00Z', 1000),   // meter did not move
    ]),
    spanSums: {},
    rowSums: [
      { box: 'project-6', account: 'claude:project-6', usd: 250, calls: 40 },
      { box: 'hub', account: 'xai-key:operator', usd: 30, calls: 600 },
      { box: 'hub', account: null, usd: 5, calls: 12 },
    ],
  });
  const by = Object.fromEntries(out.accounts.map((a) => [a.label, a]));
  assert.equal(by['claude:project-6'].state, 'unmeasured');
  assert.match(by['claude:project-6'].reason, /did not move/);
  assert.equal(by['claude:project-6'].factor, 1);
  // An api-key vendor has no such meter at all, and an unlabelled row is its
  // own account rather than being dropped out of the fleet total.
  assert.equal(by['xai-key:operator'].state, 'no-login');
  assert.equal(by.unknown.state, 'no-login');
  assert.equal(by.unknown.rows_usd, 5);
  // factor=1 must mean anchored === raw, never anchored === 0.
  for (const b of out.per_box) assert.equal(b.anchored_usd, b.raw_usd);
  assert.match(out.gaps.join(' '), /No account is metered/);
});

test('a box billing two accounts is anchored per account, not with one multiplier', () => {
  const out = computeAnchored({
    ...WIN, meters: METERS, spanSums: { 'claude:project-6': 100 },
    rowSums: [
      { box: 'hub', account: 'claude:project-6', usd: 100, calls: 10 },
      { box: 'hub', account: 'xai-key:operator', usd: 50, calls: 20 },
    ],
  });
  const hub = out.per_box.find((b) => b.box === 'hub');
  assert.equal(hub.raw_usd, 150);
  // 100 * 4 + 50 * 1. A box-wide factor would have said 600.
  assert.equal(hub.anchored_usd, 450);
  assert.deepEqual(hub.accounts.map((a) => a.factor), [4, 1]);
});

test('an absurd factor is clamped, and the clamp is reported rather than hidden', () => {
  const out = computeAnchored({
    ...WIN, meters: METERS,
    spanSums: { 'claude:project-6': 0.02 },   // 400 / 0.02 = 20000x
    rowSums: [{ box: 'project-6', account: 'claude:project-6', usd: 1, calls: 1 }],
    maxFactor: ANCHOR_DEFAULT_MAX_FACTOR,
  });
  assert.equal(out.accounts[0].factor, ANCHOR_DEFAULT_MAX_FACTOR);
  assert.equal(out.accounts[0].factor_capped, true);
  assert.equal(out.accounts[0].factor_raw, 20000);
  assert.match(out.accounts[0].reason, /capped/);
});

// --- per PR and per ticket --------------------------------------------------

const PR_COSTS = [
  {
    pr_url: PR('example-org/project-3', 12), cost_usd: 50, auth_account: 'claude:project-6',
    stage_breakdown: 'execute:40;review:10', build_dirs: 'project-3-TK-109-202609141200', updated_at: NOW,
  },
  {
    // The SAME ticket, a second build - one ticket, two PRs, one row in $/ticket.
    pr_url: PR('example-org/project-3', 13), cost_usd: 30, auth_account: 'claude:project-6',
    stage_breakdown: 'execute:25;review:5', build_dirs: 'project-3-TK-109-202609141500', updated_at: NOW,
  },
  {
    // A hand-run hub build: real spend, no ticket key.
    pr_url: PR('example-org/cromford', 300), cost_usd: 20, auth_account: 'xai-key:operator',
    stage_breakdown: 'execute:20', build_dirs: 'cost-rows-db-20260914', updated_at: NOW,
  },
  {
    // Outside the window on its build stamp - must not appear anywhere.
    pr_url: PR('example-org/project-3', 1), cost_usd: 9999, auth_account: 'claude:project-6',
    stage_breakdown: 'execute:9999', build_dirs: 'project-3-TK-1-202607241459', updated_at: NOW,
  },
];

const withPrs = (extra = {}) => computeAnchored({
  ...WIN, meters: METERS, spanSums: { 'claude:project-6': 100 },
  rowSums: [{ box: 'project-6', account: 'claude:project-6', usd: 250, calls: 40 }],
  prCosts: PR_COSTS,
  merges: [{ key: PR('example-org/project-3', 12), created_at: '2026-09-14T13:00:00Z' }],
  ...extra,
});

test('a PR is windowed on the build dir that spent the money, not on the rollup clock', () => {
  const out = withPrs();
  const nums = out.per_pr.map((r) => r.number).sort((a, b) => a - b);
  assert.deepEqual(nums, [12, 13, 300], 'the July build is outside a 24h window');
  assert.equal(out.totals.pr_raw_usd, 100);
  const twelve = out.per_pr.find((r) => r.number === 12);
  assert.equal(twelve.repo, 'example-org/project-3');
  assert.equal(twelve.project, 'project-3');
  assert.equal(twelve.key, 'TK-109');
  assert.equal(twelve.raw_usd, 50);
  assert.equal(twelve.anchored_usd, 200);
  assert.equal(twelve.merged_at, '2026-09-14T13:00:00Z');
  // An unmerged PR is not a merged one with a blank date - it is null.
  assert.equal(out.per_pr.find((r) => r.number === 13).merged_at, null);
});

test('a ticket rolls up its PRs, keeps the raw beside the anchored, and sums its stages', () => {
  const out = withPrs();
  assert.equal(out.per_ticket.length, 1, 'two PRs on one ticket are one ticket row');
  const t = out.per_ticket[0];
  assert.equal(t.project, 'project-3');
  assert.equal(t.key, 'TK-109');
  assert.equal(t.prs, 2);
  assert.equal(t.raw_usd, 80);
  assert.equal(t.anchored_usd, 320);
  assert.deepEqual(t.stage_breakdown, { execute: 65, review: 15 });
  // The drill-down target: the LATEST build dir of the ticket.
  assert.equal(t.build_dir, 'project-3-TK-109-202609141500');
});

test('a PR with no ticket key is in $/PR but never invents a ticket row', () => {
  const out = withPrs();
  assert.ok(out.per_pr.some((r) => r.number === 300 && r.key === null));
  assert.ok(!out.per_ticket.some((r) => r.key === null));
  assert.match(out.gaps.join(' '), /no ticket key/);
});

test('an unplaceable PR row is counted in the gaps, never silently dropped', () => {
  const out = withPrs({
    prCosts: [...PR_COSTS, { pr_url: PR('example-org/project-3', 77), cost_usd: 12, build_dirs: '', auth_account: null }],
  });
  assert.ok(!out.per_pr.some((r) => r.number === 77));
  assert.match(out.gaps.join(' '), /neither a parseable build dir/);
});

test('totals are over the whole window and the page says it was truncated', () => {
  const out = withPrs({ limit: 1 });
  assert.equal(out.per_pr.length, 1);
  assert.equal(out.per_pr_truncated, true);
  // The page shrank; the total did not.
  assert.equal(out.totals.pr_raw_usd, 100);
  assert.equal(out.totals.prs, 3);
  // Sorted by the anchored figure, so the biggest real cost is the row shown.
  assert.equal(out.per_pr[0].number, 12);
});

// --- the route --------------------------------------------------------------

function fakeDB(state) {
  const calls = [];
  const result = (rawSql, binds) => {
    // Newlines out FIRST: these statements are template literals with line
    // breaks inside them, and a matcher that misses one answers `no rows` -
    // which a factor of 1 is indistinguishable from.
    const sql = rawSql.replace(/\s+/g, ' ').trim();
    calls.push({ sql, binds });
    if (/FROM pause_flags/.test(sql)) {
      return { rows: (state.flags || []).filter((f) => f.name === binds[0]) };
    }
    // The two cost_rows reads are DIFFERENT questions against one table and the
    // factor's correctness depends on not confusing them: one is the window
    // grouped by box and account, the other is one account inside its meter
    // span. A stub answering both from one list would pass on a worker that
    // divided the window sum by itself and reported 1x forever.
    if (/FROM cost_rows WHERE auth_account/.test(sql)) {
      const [account, from, to] = binds;
      const usd = (state.rows || [])
        .filter((r) => r.auth_account === account && r.ts >= from && r.ts <= to)
        .reduce((n, r) => n + r.cost_usd, 0);
      return { rows: [{ usd }] };
    }
    if (/FROM cost_rows WHERE ts/.test(sql)) {
      const [from, to] = binds;
      const agg = new Map();
      for (const r of (state.rows || [])) {
        if (!(r.ts >= from && r.ts < to)) continue;
        const k = `${r.box}|${r.auth_account}`;
        const e = agg.get(k) || { box: r.box, account: r.auth_account, usd: 0, calls: 0 };
        e.usd += r.cost_usd; e.calls += 1;
        agg.set(k, e);
      }
      return { rows: [...agg.values()] };
    }
    if (/FROM extra_usage_snapshots/.test(sql)) {
      const [from, to] = binds;
      return { rows: (state.snapshots || []).filter((s) => s.ts >= from && s.ts < to) };
    }
    if (/FROM pr_costs/.test(sql)) return { rows: state.prCosts || [] };
    if (/FROM ledgers/.test(sql)) {
      return { rows: (state.merges || []).filter((m) => m.created_at >= binds[0]) };
    }
    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => { result(sql, binds); return { meta: { changes: 1 } }; },
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1 } }; },
  });
  return { prepare: stmt, batch: async (xs) => xs, _calls: calls };
}

const call = (path, { secret = SECRET, state = {}, env = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    headers: secret === null ? {} : { authorization: `Bearer ${secret}` },
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET, ...env })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null), db }));
};

const ROUTE_STATE = {
  snapshots: [
    { box: 'project-6-account', ts: '2026-09-14T10:00:00Z', extra_used_usd: 1000, weekly_pct: 100, extra_enabled: 1, spend_limit_reached: 0, weekly_resets_at: '2026-09-17T04:00:00Z' },
    { box: 'project-6-account', ts: '2026-09-14T14:00:00Z', extra_used_usd: 1400, weekly_pct: 100, extra_enabled: 1, spend_limit_reached: 0, weekly_resets_at: '2026-09-17T04:00:00Z' },
  ],
  rows: [
    // Inside the meter span: the denominator.
    { box: 'project-6', ts: '2026-09-14T11:00:00Z', auth_account: 'claude:operator@second.example', cost_usd: 100 },
    // Inside the window, outside the span: counted as raw, not as denominator.
    { box: 'project-6', ts: '2026-09-14T18:00:00Z', auth_account: 'claude:operator@second.example', cost_usd: 150 },
    { box: 'hub', ts: '2026-09-14T18:00:00Z', auth_account: 'xai-key:operator', cost_usd: 30 },
  ],
  prCosts: [{
    pr_url: PR('example-org/project-3', 12), cost_usd: 50, auth_account: 'claude:operator@second.example',
    stage_breakdown: 'execute:40;review:10', build_dirs: 'project-3-TK-109-202609141200', updated_at: NOW,
  }],
  merges: [],
};

// The route windows off the REAL clock. The fixtures are pinned to 2026-09-14,
// so a relative window (24h/7d) silently empties once the calendar moves on --
// this file went red fleet-wide on 2026-09-15 for exactly that. Pin the day.
test('the route answers the four sections, anchored off the default account map', async () => {
  const r = await call('/api/metrics/cost-anchored?day=2026-09-14', { state: ROUTE_STATE });
  assert.equal(r.status, 200);
  assert.equal(r.body.disabled, false);
  const mk = r.body.accounts.find((a) => a.label === 'claude:operator@second.example');
  assert.equal(mk.state, 'metered');
  assert.equal(mk.factor, 4, '400 of meter over the 100 of rows inside the span');
  assert.equal(mk.rows_usd, 250);
  assert.equal(mk.weekly_pct, 100);
  assert.equal(r.body.per_box.find((b) => b.box === 'project-6').anchored_usd, 1000);
  assert.equal(r.body.per_pr[0].anchored_usd, 200);
  assert.equal(r.body.per_ticket[0].key, 'TK-109');
  assert.equal(r.body.totals.metered_accounts, 1);
});

test('an unauthenticated read gets nothing', async () => {
  const r = await call('/api/metrics/cost-anchored', { secret: null, state: ROUTE_STATE });
  assert.notEqual(r.status, 200);
});

test('the account map is configurable and a wrong map simply stops anchoring', async () => {
  const r = await call('/api/metrics/cost-anchored?day=2026-09-14', {
    state: ROUTE_STATE, env: { COST_ANCHOR_ACCOUNT_MAP: 'project-6-account=claude:someone-else' },
  });
  const mk = r.body.accounts.find((a) => a.label === 'claude:operator@second.example');
  assert.equal(mk.state, 'no-login', 'no meter maps to this label any more');
  assert.equal(mk.factor, 1);
  assert.equal(r.body.per_pr[0].anchored_usd, r.body.per_pr[0].raw_usd);
});

test('the kill switch answers empty, not raw dollars wearing an anchored name', async () => {
  for (const off of [
    { state: { ...ROUTE_STATE, flags: [{ name: ANCHOR_OFF_FLAG, active: 1 }] }, env: {} },
    { state: ROUTE_STATE, env: { COST_ANCHOR_OFF: '1' } },
  ]) {
    const r = await call('/api/metrics/cost-anchored', off);
    assert.equal(r.status, 200);
    assert.equal(r.body.disabled, true);
    assert.deepEqual(r.body.per_pr, []);
    assert.deepEqual(r.body.per_box, []);
    assert.deepEqual(r.body.accounts, []);
    assert.equal(r.body.totals, null);
    assert.match(r.body.reason, /off/);
  }
  // And with the flag row present but INACTIVE, nothing is switched off: a
  // two-state flag that cannot be turned back on is a one-way door.
  const back = await call('/api/metrics/cost-anchored', {
    state: { ...ROUTE_STATE, flags: [{ name: ANCHOR_OFF_FLAG, active: 0 }] },
  });
  assert.equal(back.body.disabled, false);
});

test('the kill switch is read BEFORE the money queries, not after', async () => {
  const r = await call('/api/metrics/cost-anchored', { state: ROUTE_STATE, env: { COST_ANCHOR_OFF: '1' } });
  const tables = r.db._calls.map((c) => c.sql);
  assert.ok(tables.some((s) => /pause_flags/.test(s)), 'the flag is read');
  assert.ok(!tables.some((s) => /cost_rows|pr_costs|extra_usage_snapshots/.test(s)),
    'an off switch that still runs every aggregate is not a kill switch');
});

test('a day window bounds both reads to that UTC day', async () => {
  const r = await call('/api/metrics/cost-anchored?day=2026-09-13', { state: ROUTE_STATE });
  assert.equal(r.body.window, 'day=2026-09-13');
  assert.equal(r.body.from, '2026-09-13T00:00:00Z');
  assert.equal(r.body.to, '2026-09-14T00:00:00Z');
  assert.deepEqual(r.body.per_pr, [], 'nothing was built that day');
  assert.equal(r.body.totals.rows_usd, 0);
});
