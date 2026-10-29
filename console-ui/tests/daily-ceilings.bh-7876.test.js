import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { dailyCeilingRows, dailyWarnPct, withSpend } from '../src/lib/daily-ceilings.js';
import { DailyCeilingsView, loadDaySpend } from '../src/screens/DailyCeilings.js';

// BH-7876: the DAILY CEILINGS table on /costs. One row per
// conf.cost-caps.<project>.daily_usd settings row, beside the project's spend
// for the current UTC day (GET /api/coord/metrics/llm-spend?project=<p>).

const row = (key, value) => ({ key, value, actor: 'console', note: null, updated_at: '2026-10-21T18:47:02Z' });

test('D1: picks every <project>.daily_usd row, keeps the box, ignores the other cost-caps keys', () => {
  const { rows, unreadable } = dailyCeilingRows([
    row('conf.cost-caps.acme-os.daily_usd', '5000'),
    row('conf.cost-caps.budget.x', '100 5'),
    row('conf.cost-caps.ceiling', '10000'),
    row('conf.cost-caps.daily_warn_pct', '90'),
    row('conf.cost-caps.beta.daily_usd.box-3', '20'),
    row('conf.cost-caps.gamma.daily_usd', 'abc'),
    row('conf.lane-caps.acme-os.daily_usd', '7'),
  ]);
  assert.equal(unreadable, false);
  const m = Object.fromEntries(rows.map((r) => [r.key, r]));
  assert.deepEqual(Object.keys(m).sort(), [
    'conf.cost-caps.acme-os.daily_usd', 'conf.cost-caps.beta.daily_usd.box-3', 'conf.cost-caps.gamma.daily_usd',
  ]);
  const a = m['conf.cost-caps.acme-os.daily_usd'];
  assert.deepEqual([a.project, a.box, a.ceiling], ['acme-os', null, 5000]);
  const b = m['conf.cost-caps.beta.daily_usd.box-3'];
  assert.deepEqual([b.project, b.box, b.ceiling], ['beta', 'box-3', 20]);
  const g = m['conf.cost-caps.gamma.daily_usd'];
  assert.deepEqual([g.project, g.ceiling, g.raw], ['gamma', null, 'abc']);
  assert.equal(dailyCeilingRows(null).unreadable, true);
  assert.equal(dailyWarnPct([row('conf.cost-caps.daily_warn_pct', '90')]), 90);
  assert.equal(dailyWarnPct([row('conf.cost-caps.daily_warn_pct', '150')]), 80);
  assert.equal(dailyWarnPct([]), 80);
});

test('D2: withSpend gives pct and state; a failed read is unknown, never 0', () => {
  const { rows } = dailyCeilingRows([
    row('conf.cost-caps.a.daily_usd', '50'),
    row('conf.cost-caps.b.daily_usd', '50'),
    row('conf.cost-caps.c.daily_usd', '50'),
    row('conf.cost-caps.d.daily_usd', '50'),
    row('conf.cost-caps.e.daily_usd', 'off'),
  ]);
  const out = Object.fromEntries(withSpend(rows, {
    a: { usd: 40, as_of: '2026-10-21T19:00:00Z' },
    b: { usd: 50 },
    c: { error: 'boom' },
    d: { usd: 39.5 },
    e: { usd: 1 },
  }).map((r) => [r.project, r]));
  assert.deepEqual([out.a.spent, out.a.pct, out.a.state, out.a.asOf], [40, 80, 'warn', '2026-10-21T19:00:00Z']);
  assert.deepEqual([out.b.pct, out.b.state], [100, 'over']);
  assert.deepEqual([out.c.spent, out.c.pct, out.c.state], [null, null, 'unknown']);
  assert.deepEqual([out.d.pct, out.d.state], [79, 'under']);
  assert.equal(out.e.state, 'unreadable');
  // The warn percent is the settings row's.
  const w = withSpend(rows.slice(0, 1), { a: { usd: 40 } }, 90)[0];
  assert.equal(w.state, 'under');
});

test('D3: the view shows the project link, the ceiling, the spend and sortable headers', () => {
  const settings = { data: { settings: [row('conf.cost-caps.acme-os.daily_usd', '5000')] }, loading: false };
  const spend = { data: { 'acme-os': { usd: 4100.5, as_of: '2026-10-21T19:00:00Z' } }, loading: false };
  const html = render(h(DailyCeilingsView, { settings, spend }));
  assert.match(html, /DAILY CEILINGS/);
  assert.match(html, /href="\/p\/acme-os"/);
  assert.match(html, /\$5000/);
  assert.match(html, /\$4100\.50/);
  assert.match(html, /82%/);
  assert.match(html, /warn/);
  assert.match(html, /aria-sort/);
});

test('D3b: a failed spend read renders unknown, not $0', () => {
  const settings = { data: { settings: [row('conf.cost-caps.acme-os.daily_usd', '5000')] }, loading: false };
  const spend = { data: { 'acme-os': { error: 'http_500' } }, loading: false };
  const html = render(h(DailyCeilingsView, { settings, spend }));
  assert.match(html, /unknown/);
  assert.doesNotMatch(html, /\$0\.00/);
});

test('D4: zero rows renders the empty state', () => {
  const settings = { data: { settings: [row('conf.cost-caps.ceiling', '10000')] }, loading: false };
  const html = render(h(DailyCeilingsView, { settings, spend: { data: {}, loading: false } }));
  assert.match(html, /no daily ceilings set/);
});

test('D5: loadDaySpend reads every project in parallel and keeps a failure per project', async () => {
  const seen = [];
  let open = 0, peak = 0;
  const fetchSpend = async (p) => {
    seen.push(p); open++; peak = Math.max(peak, open);
    await Promise.resolve(); // a parallel caller has started every read before this resolves
    open--;
    if (p === 'bad') throw new Error('http 500');
    return { usd: 12, as_of: 'x' };
  };
  const out = await loadDaySpend(['a', 'bad', 'a', 'c'], fetchSpend);
  assert.deepEqual(seen.sort(), ['a', 'bad', 'c']);
  assert.equal(peak, 3);
  assert.equal(out.a.usd, 12);
  assert.equal(out.bad.error, 'http 500');
});
