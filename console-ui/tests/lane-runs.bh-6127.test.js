import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h } from 'preact';

// BH-6127: the LANES screens. /lane-runs (per-lane and per-machine counts over
// 24 h, the hub's load), /lane-runs/lane/:lane and /lane-runs/machine/:machine
// (the runs), /lane-runs/run/:id (one run). preact-render-to-string runs no
// effects, so the views are driven with each load state directly and the real
// screens through ROUTES in their first, loading state.
//
// The data is the fixture: the lead swaps it for real jobs-worker output in
// the same shape, so every case reads it and only overrides fields locally.

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const { ROUTES, NAV } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { AuthError } = await import('../src/api.js');
const { laneRunMetrics, laneRunList, laneRun } = await import('../src/lib/lane-runs-api.js');
const { nextDirection, ariaSort, sortRows } = await import('../src/lib/sort.js');
const {
  LaneRunsScreen, LaneRunListScreen, LaneRunScreen,
  LaneRunsView, LaneRunListView, LaneRunView, LANE_COLUMNS, EMPTY_COPY
} = await import('../src/screens/LaneRuns.js');

const fx = JSON.parse(readFileSync(new URL('./fixtures/lane-runs.bh-6127.json', import.meta.url), 'utf8'));
const loaded = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = (error) => ({ data: null, error, loading: false, reload() {} });
const loading = { data: null, error: null, loading: true, reload() {} };
// Text-node escaping as preact-render-to-string does it: & and < only (a bare
// > in text cannot open a tag, so it is left as is).
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
// One table's markup: from its section title to the end of that table.
const tableAfter = (out, title) => {
  const at = out.indexOf(title);
  assert.ok(at >= 0, `${title} section missing`);
  const end = out.indexOf('</table>', at);
  assert.ok(end > at, `${title} has no table`);
  return out.slice(at, end);
};

const EMPTY = 'No lane runs in the last 24 h. Every lane runs on the hub until a lane_placement row says fly.';

// Two lanes whose wait max differ, built from the fixture's first lane, so
// the sort case does not depend on what the real worker output holds.
const L0 = fx.metrics.lanes[0];
const twoLanes = {
  ...fx.metrics,
  lanes: [{ ...L0, wait_max_s: 600 }, { ...L0, lane: 'zz-other', wait_max_s: 90 }]
};

test('C1 lanes table: aria-sort and arrow on the active column, WAIT MAX flips the order, the lane links', () => {
  const out = render(h(LaneRunsView, { state: loaded(twoLanes) }));
  const lanes = tableAfter(out, 'LANES ·');
  assert.ok(out.includes('class="tablewrap'), 'the table sits in its scroll container');
  // Default: LANE ascending, announced and drawn.
  assert.match(lanes, /<th[^>]*aria-sort="ascending"[^>]*>\s*<button[^>]*>\s*LANE[\s\S]*?<span class="arrow" aria-hidden="true">↑<\/span>/);
  assert.match(lanes, /<th[^>]*aria-sort="none"[^>]*>\s*<button[^>]*>\s*WAIT MAX/);
  assert.ok(lanes.includes(`<a href="/lane-runs/lane/${encodeURIComponent(L0.lane)}"`), 'lane cell links to its runs');
  assert.equal(EMPTY_COPY, EMPTY);

  // The header click sequence SortableTable runs: LANE asc -> WAIT MAX asc -> desc.
  let dir = nextDirection('wait_max', 'lane', 'asc');
  assert.equal(ariaSort('wait_max', 'wait_max', dir), 'ascending');
  const asc = render(h(LaneRunsView, { state: loaded(twoLanes), laneSort: ['wait_max', dir] }));
  dir = nextDirection('wait_max', 'wait_max', dir);
  assert.equal(dir, 'desc');
  const desc = render(h(LaneRunsView, { state: loaded(twoLanes), laneSort: ['wait_max', dir] }));
  const a = tableAfter(asc, 'LANES ·');
  const d = tableAfter(desc, 'LANES ·');
  assert.match(a, /<th[^>]*aria-sort="ascending"[^>]*>\s*<button[^>]*>\s*WAIT MAX/);
  assert.match(d, /<th[^>]*aria-sort="descending"[^>]*>\s*<button[^>]*>\s*WAIT MAX[\s\S]*?↓/);
  assert.ok(a.indexOf('zz-other') < a.indexOf(`>${L0.lane}<`), 'ascending: 90 s before 600 s');
  assert.ok(d.indexOf(`>${L0.lane}<`) < d.indexOf('zz-other'), 'descending: 600 s before 90 s');

  // Minutes are drawn, seconds are sorted.
  const col = LANE_COLUMNS.find((c) => c.key === 'wait_max');
  assert.equal(col.sort({ wait_max_s: 540 }), 540);
  assert.equal(LANE_COLUMNS.find((c) => c.key === 'wait_p50').sort({ wait_p50_s: 61 }), 61);
  assert.equal(LANE_COLUMNS.find((c) => c.key === 'cost').sort({ cost_usd: 0.25 }), 0.25);
  assert.deepEqual(sortRows([{ wait_max_s: null }, { wait_max_s: 5 }], col.sort, 'desc').map((r) => r.wait_max_s), [5, null],
    'a lane with no wait sample sinks');
  assert.ok(a.includes('10'), '600 s is drawn as 10 min');
});

test('C2 machines table links each machine to its runs', () => {
  const out = render(h(LaneRunsView, { state: loaded(fx.metrics) }));
  const machines = tableAfter(out, 'MACHINES ·');
  assert.ok(fx.metrics.machines.length > 0);
  for (const m of fx.metrics.machines) {
    assert.ok(machines.includes(`<a href="/lane-runs/machine/${encodeURIComponent(m.machine)}"`), m.machine);
  }
  assert.match(machines, /aria-sort="ascending"/);
});

test('C3 run list: each run links to its page; the cap note only when truncated', () => {
  const list = { ...fx.list, truncated: true };
  const out = render(h(LaneRunListView, { state: loaded(list), lane: 'demo' }));
  assert.ok(list.runs.length > 0);
  for (const r of list.runs) assert.ok(out.includes(`<a href="/lane-runs/run/${r.id}"`), `run ${r.id}`);
  for (const r of list.runs.filter((x) => x.claimed_by)) {
    assert.ok(out.includes(`<a href="/lane-runs/machine/${encodeURIComponent(r.claimed_by)}"`), `claimer ${r.claimed_by}`);
  }
  assert.ok(out.includes(`showing the newest ${list.limit} runs`));
  assert.ok(out.includes('class="tablewrap'));
  const whole = render(h(LaneRunListView, { state: loaded({ ...list, truncated: false }), lane: 'demo' }));
  assert.ok(!whole.includes('showing the newest'), 'no cap note on an uncapped list');
  const capped = render(h(LaneRunListView, { state: loaded({ ...list, limit: 50 }), machine: 'm1' }));
  assert.ok(capped.includes('showing the newest 50 runs'), 'the copy uses the response limit');
});

test('C4 run view: rc, the prof line as text, the claimer link, wait in minutes', () => {
  const run = { ...fx.run.run, wait_s: 90, rc: 3, claimed_by: 'm1' };
  assert.ok(run.prof_line.includes('<b>'), 'fixture precondition: a prof line with markup in it');
  const out = render(h(LaneRunView, { state: loaded({ ...fx.run, run }), id: String(run.id) }));
  assert.match(out, />RC<\/span>\s*<span[^>]*>3<\/span>/);
  assert.ok(out.includes(esc(run.prof_line)), 'prof line escaped');
  assert.ok(out.includes('&lt;b>'), 'the tag is drawn as text');
  assert.ok(!out.includes('<b>bold'), 'no raw markup from the prof line');
  assert.ok(out.includes('<a href="/lane-runs/machine/m1"'), 'claimer link');
  assert.match(out, /1\.5 min/, '90 s is 1.5 min');
  assert.ok(out.includes(`<a href="/lane-runs/lane/${encodeURIComponent(run.lane)}"`), 'back link to the lane');
  for (const a of run.args || []) assert.ok(out.includes(esc(a)), `arg ${a}`);
});

test('C5 empty, error and loading are three different screens', async () => {
  const empty = render(h(LaneRunsView, { state: loaded({ ...fx.metrics, lanes: [], machines: [] }) }));
  assert.ok(empty.includes(EMPTY));
  assert.ok(!empty.includes('could not load'));
  assert.ok(!empty.includes('class="tablewrap'), 'zero rows draw no table');

  // A rejected fetch through the real api call, as the screen gets it.
  globalThis.fetch = async () => { throw new TypeError('fetch failed'); };
  const err = await laneRunMetrics(24).then(() => null, (e) => e);
  assert.ok(err instanceof Error);
  const broken = render(h(LaneRunsView, { state: failed(err) }));
  assert.ok(broken.includes('could not load'));
  assert.ok(broken.includes('RETRY'));
  assert.ok(!broken.includes(EMPTY));

  const listEmpty = render(h(LaneRunListView, { state: loaded({ ...fx.list, runs: [], truncated: false }), lane: 'demo' }));
  const listBroken = render(h(LaneRunListView, { state: failed(err), lane: 'demo' }));
  assert.ok(listEmpty.includes('No lane runs match this filter.'));
  assert.ok(!listEmpty.includes('could not load'));
  assert.ok(listBroken.includes('could not load') && !listBroken.includes('No lane runs match'));
  const runBroken = render(h(LaneRunView, { state: failed(err), id: '7' }));
  assert.ok(runBroken.includes('could not load') && runBroken.includes('RETRY'));
  const gone = Object.assign(new Error('not_found'), { status: 404 });
  assert.ok(render(h(LaneRunView, { state: failed(gone), id: '7' })).includes('No lane run #7.'));

  // The real screens, mounted through ROUTES: the first state is the skeleton.
  globalThis.fetch = () => new Promise(() => {});
  for (const path of ['/lane-runs', '/lane-runs/lane/demo', '/lane-runs/machine/m1', '/lane-runs/run/7']) {
    const [pat, C] = ROUTES.find(([p]) => matchRoute(p, path));
    const out = render(h(C, { ...matchRoute(pat, path), key: path }));
    assert.ok(out.includes('class="skel"'), `${path} skeleton`);
    assert.ok(out.includes('class="line-headline"'), `${path} headline`);
    assert.ok(!out.includes(EMPTY) && !out.includes('could not load'), `${path} neither empty nor error`);
  }
  for (const [label, s] of [['view', loading]]) {
    const out = render(h(LaneRunsView, { state: s }));
    assert.ok(out.includes('class="skel"') && !out.includes(EMPTY), label);
  }
});

test('C6 no hub report, and no cost', () => {
  const out = render(h(LaneRunsView, { state: loaded({ ...fx.metrics, hub: null, cost_available: false }) }));
  assert.ok(out.includes('hub load: no report yet'));
  assert.ok(out.includes('cost not available'));
  const hub = { box: 'hub', load1: 0.42, reported_at: fx.metrics.as_of, age_s: 12 };
  const ok = render(h(LaneRunsView, { state: loaded({ ...fx.metrics, hub, cost_available: true }) }));
  assert.ok(!ok.includes('hub load: no report yet'));
  assert.ok(!ok.includes('cost not available'));
  assert.ok(ok.includes('0.42') && ok.includes('12s'), 'load1 with its age');
  assert.ok(ok.includes(`alert limit ${fx.metrics.wait_alert_min} min`));
  assert.ok(ok.includes('window 24 h'));
  const capped = render(h(LaneRunsView, { state: loaded({ ...fx.metrics, truncated: true }) }));
  assert.ok(capped.includes('wait sample capped'));
  assert.ok(!ok.includes('wait sample capped'));
});

test('C7 the LANES tab and the four routes', () => {
  const tab = NAV.find((n) => n.to === '/lane-runs');
  assert.ok(tab, '/lane-runs missing from NAV');
  assert.equal(tab.label, 'LANES');
  for (const p of ['/lane-runs', '/lane-runs/run/7', '/lane-runs/lane/demo', '/lane-runs/machine/m1']) assert.ok(tab.match(p), p);
  assert.ok(!tab.match('/lane-runsx') && !tab.match('/settings'));
  const i = NAV.indexOf(tab);
  assert.equal(NAV[i + 1].to, '/hub', 'LANES sits right before HUB');
  assert.equal(NAV[NAV.length - 1].to, '/settings');
  const resolve = (path) => {
    for (const [pat, C] of ROUTES) { const params = matchRoute(pat, path); if (params) return [C, params]; }
    return [null, null];
  };
  assert.deepEqual(resolve('/lane-runs'), [LaneRunsScreen, {}]);
  assert.deepEqual(resolve('/lane-runs/lane/demo'), [LaneRunListScreen, { lane: 'demo' }]);
  assert.deepEqual(resolve('/lane-runs/machine/m%201'), [LaneRunListScreen, { machine: 'm 1' }]);
  assert.deepEqual(resolve('/lane-runs/run/7'), [LaneRunScreen, { id: '7' }]);
});

test('C8 the api calls: coord paths, encoded params, empty params omitted, 403 is AuthError', async () => {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push([init.method || 'GET', String(url)]);
    return { ok: true, status: 200, text: async () => '{"ok":true}' };
  };
  await laneRunMetrics(24);
  await laneRunList({ lane: 'a b', machine: '', status: undefined });
  await laneRunList({ lane: 'demo', machine: 'm/1', status: 'done' });
  await laneRunList({});
  await laneRun(7);
  assert.deepEqual(calls, [
    ['GET', '/api/coord/lane-runs/metrics?hours=24'],
    ['GET', '/api/coord/lane-runs?lane=a%20b'],
    ['GET', '/api/coord/lane-runs?lane=demo&machine=m%2F1&status=done'],
    ['GET', '/api/coord/lane-runs'],
    ['GET', '/api/coord/lane-runs/7'],
  ]);
  globalThis.fetch = async () => ({ ok: false, status: 403, text: async () => '' });
  await assert.rejects(laneRun(7), AuthError);
  globalThis.fetch = async () => ({ ok: false, status: 404, text: async () => '{"error":"unauthorized"}' });
  await assert.rejects(laneRunMetrics(24), AuthError);
  globalThis.fetch = async () => ({ ok: false, status: 404, text: async () => '{"error":"not_found"}' });
  await assert.rejects(laneRun(9), (e) => !(e instanceof AuthError) && e.status === 404 && e.message === 'not_found');
});
