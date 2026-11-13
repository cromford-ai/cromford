// BH-9629 (C1 of #9145): the last screen files put their counts through
// fmtNum, so 12224 reads 12,224 on a real screen. These cases render real
// screen views to a string. Each case builds its own fixture: no shared
// state, no fetch, no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/roadmap/bh9629', search: '?view=board' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};

const { render } = await import('preact-render-to-string');
const { HubView } = await import('../src/screens/Hub.js');
const { WaitingView } = await import('../src/screens/WaitingPanel.js');
const { OutcomesView } = await import('../src/screens/Outcomes.js');
const { RoadmapBoardView } = await import('../src/screens/roadmap/board-view.js');

const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
const noop = () => {};

const hubHtml = (n, tag) => {
  const now = Date.parse('2099-11-12T12:00:00Z');
  const data = {
    lease: { holder: `hub-${tag}`, epoch: 1, expires_at: '2099-11-12T12:01:30Z', updated_at: '2099-11-12T11:59:30Z', live: true },
    role: { active: `hub-${tag}`, standby: [] },
    backups: Array.from({ length: n }, (_, i) => ({
      box: `${tag}-box-${i}`, backup_ts: '2099-11-12T11:48:00Z', backup_off: null,
      backup_unconfigured: null, backup_reported_at: '2099-11-12T11:50:00Z'
    }))
  };
  return text(render(h(HubView, {
    state: { data, error: null, loading: false, fetchedAt: now }, now, onReload: noop, onPromote: noop, promoteMsg: null
  })));
};

test('R1: HubView groups 12,224 backups on record', () => {
  const out = hubHtml(12224, 'r1');
  assert.ok(out.includes('12,224 backups on record.'), out.slice(0, 400));
});

test('R2: a count of 1 keeps the singular word (the plural ternary reads the raw number)', () => {
  const out = hubHtml(1, 'r2');
  assert.ok(out.includes('1 backup on record.'), out.slice(0, 400));
});

test('R3: WaitingView groups 1,234 stale claims', () => {
  const data = {
    ok: true, counts: {}, in_flight: 0, rows: [], total: 0,
    stale_claims: Array.from({ length: 1234 }, (_, i) => ({ key: `R3-${i}`, project: 'bh9629-r3' }))
  };
  const out = text(render(h(WaitingView, { state: { data, loading: false, error: null } })));
  assert.ok(out.includes('stale claims 1,234'), out.slice(0, 400));
});

test('R4: Outcomes API CALLS and PEAK CACHE READ group in en-US whatever the process locale', () => {
  // Node's ICU default stays en-US whatever LANG says, so a German browser
  // is simulated: a no-locale toLocaleString() answers de-DE, as it would there.
  const prev = process.env.LANG;
  const realToLocale = Number.prototype.toLocaleString;
  process.env.LANG = 'de_DE.UTF-8';
  Number.prototype.toLocaleString = function (loc, opts) { return realToLocale.call(this, loc || 'de-DE', opts); };
  try {
    const NOW = Date.UTC(2026, 10, 12, 12, 0);
    const day = new Date(NOW - 86400000).toISOString().slice(0, 10);
    const data = {
      as_of: new Date(NOW).toISOString(), degraded: [], merges: [], outcomes: [], pr_costs: [], gates: [], thresholds: [],
      burn_days: [{ day, usd_equiv: 12, output: 1000, api_calls: 4823, peak_cache_read: 1234567 }]
    };
    const out = text(render(h(OutcomesView, { out: { data }, repo: null, days: 14, nowMs: NOW, setFilter: noop })));
    assert.ok(out.includes('4,823'), 'API CALLS cell reads 4,823');
    assert.ok(out.includes('1,234,567'), 'PEAK CACHE READ cell reads 1,234,567');
    assert.ok(!out.includes('4.823') && !out.includes('1.234.567'), 'no German grouping');
  } finally {
    Number.prototype.toLocaleString = realToLocale;
    if (prev === undefined) delete process.env.LANG; else process.env.LANG = prev;
  }
});

test('R5: the roadmap board column counts keep the loading text "…", not the fmtNum dash', () => {
  const out = render(h(RoadmapBoardView, { project: 'bh9629-r5' }));
  const counts = [...out.matchAll(/<span class="kb__count">([^<]*)<\/span>/g)].map((m) => m[1]);
  assert.ok(counts.length >= 4, `the skeleton renders its column heads: ${out.slice(0, 300)}`);
  assert.ok(counts.every((c) => c === '…'), `every loading count reads …: ${counts.join(',')}`);
});
