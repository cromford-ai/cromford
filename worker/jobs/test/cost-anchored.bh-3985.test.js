import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-3985: GET /api/metrics/cost-anchored said "No account is metered" while
// operator@second.example's meter was moving. The meter span kept failed polls
// (status error / no-login, extra_used_usd NULL), so a span whose first or last
// poll failed lost its delta and its fully_overage verdict. A failed poll is
// not a reading: it is counted, not measured.

const SECRET = 'test-secret';
const DAY = '2026-09-14';
const MK = 'claude:operator@second.example';

function fakeDB(state) {
  const result = (rawSql, binds) => {
    const sql = rawSql.replace(/\s+/g, ' ').trim();
    if (/FROM pause_flags/.test(sql)) return { rows: [] };
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
    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => ({ meta: { changes: 1 } }),
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => ({ meta: { changes: 1 } }),
  });
  return { prepare: stmt, batch: async (xs) => xs };
}

const anchored = async (state) => {
  const req = new Request(`https://jobs.test/api/metrics/cost-anchored?day=${DAY}`, {
    headers: { authorization: `Bearer ${SECRET}` },
  });
  const res = await worker.fetch(req, { DB: fakeDB(state), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  return res.json();
};

const ok = (ts, used, weekly = 100) => ({
  box: 'project-6-account', ts, status: 'ok', extra_used_usd: used, weekly_pct: weekly,
  extra_enabled: 1, spend_limit_reached: 0, weekly_resets_at: '2026-09-17T04:00:00Z',
});
const failed = (ts, status = 'error') => ({
  box: 'project-6-account', ts, status, extra_used_usd: null, weekly_pct: null,
  extra_enabled: null, spend_limit_reached: null, weekly_resets_at: null,
});
const ROWS = [{ box: 'project-6', ts: `${DAY}T11:00:00Z`, auth_account: MK, cost_usd: 10 }];

test('a moving, fully-overage meter whose newest poll failed is metered', async () => {
  const body = await anchored({
    snapshots: [ok(`${DAY}T10:00:00Z`, 100), ok(`${DAY}T14:00:00Z`, 130), failed(`${DAY}T15:00:00Z`)],
    rows: ROWS,
  });
  const mk = body.accounts.find((a) => a.label === MK);
  assert.equal(mk.state, 'metered', `reason: ${mk.reason}`);
  assert.equal(mk.meter_delta_usd, 30);
  assert.equal(mk.failed_polls, 1);
  assert.equal(mk.snapshots, 2, 'readings only');
  assert.equal(mk.span_to, `${DAY}T14:00:00Z`, 'the span ends at the last reading, not the failed poll');
  assert.equal(mk.factor, 3, '30 of meter over 10 of rows inside the span');
  assert.ok(!body.gaps.some((g) => g.startsWith('No account is metered')), body.gaps.join(' | '));
});

test('a failed FIRST poll does not poison the span either', async () => {
  const body = await anchored({
    snapshots: [failed(`${DAY}T09:00:00Z`, 'no-login'), ok(`${DAY}T10:00:00Z`, 100), ok(`${DAY}T14:00:00Z`, 130)],
    rows: ROWS,
  });
  const mk = body.accounts.find((a) => a.label === MK);
  assert.equal(mk.state, 'metered', `reason: ${mk.reason}`);
  assert.equal(mk.failed_polls, 1);
});

test('an account whose every poll failed is unmeasured and says so, not no-login', async () => {
  const body = await anchored({
    snapshots: [failed(`${DAY}T10:00:00Z`), failed(`${DAY}T14:00:00Z`)],
    rows: ROWS,
  });
  const mk = body.accounts.find((a) => a.label === MK);
  assert.equal(mk.state, 'unmeasured');
  assert.match(mk.reason, /every meter poll in this window failed \(2\)/);
  assert.equal(mk.failed_polls, 2);
  assert.equal(mk.snapshots, 0);
  assert.equal(mk.factor, 1);
});

test('one reading plus failed polls is still not a delta', async () => {
  const body = await anchored({
    snapshots: [ok(`${DAY}T10:00:00Z`, 100), failed(`${DAY}T14:00:00Z`)],
    rows: ROWS,
  });
  const mk = body.accounts.find((a) => a.label === MK);
  assert.equal(mk.state, 'unmeasured');
  assert.match(mk.reason, /one meter poll/);
});

test('a moving meter that was inside its credits for part of the span stays unmeasured', async () => {
  const body = await anchored({
    snapshots: [ok(`${DAY}T10:00:00Z`, 100, 87), ok(`${DAY}T14:00:00Z`, 130), failed(`${DAY}T15:00:00Z`)],
    rows: ROWS,
  });
  const mk = body.accounts.find((a) => a.label === MK);
  assert.equal(mk.state, 'unmeasured');
  assert.match(mk.reason, /inside its weekly credits/);
  assert.equal(mk.failed_polls, 1);
});
