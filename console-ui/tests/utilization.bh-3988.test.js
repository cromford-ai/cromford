import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { ROUTES, NAV } from '../src/app.js';
import { utilizationRows, cellText, pauseAge, verdictRank, VERDICT_RANK, STALE_MS } from '../src/lib/utilization.js';
import { UtilizationScreen, UtilizationView } from '../src/screens/Utilization.js';

// BH-4011 (BH-3988.3): the /utilization screen. One row per fleet.conf project
// from GET /api/coord/utilization (newest snapshot per project); a bucket the
// collector could not read is `—`, never 0.

const NOW = Date.parse('2026-10-03T12:00:00Z');
const iso = (msAgo) => new Date(NOW - msAgo).toISOString();
const MIN = 60000;

// The payload bin/utilization-push.sh writes today: the builds section only,
// verdict unknown (D4).
const tracer = (project, asOfAgo = 10 * MIN, builds = { running: 1, pool_cap: 3, free_slots: 2 }) => ({
  project, hour: '2026-10-03T11:00:00Z', verdict: 'unknown', box: 'hub', as_of: iso(asOfAgo),
  payload: { builds, basis: { builds: 'measured' } },
});
// The full shape the BH-3988 sections agree on (ticket #4011).
const full = (project, verdict, over = {}) => ({
  project, hour: '2026-10-03T11:00:00Z', verdict, box: 'hub', as_of: iso(5 * MIN),
  payload: {
    tickets: { ready: 0, blocked: 2, held: 1, parked: 3, held_complete: true },
    builds: { running: 0, pool_cap: 4, free_slots: 4 },
    pauses: [{ kind: 'flag', name: 'paused-project-3', since: iso(90 * MIN), stops_builds: true }],
    prs: { review: 1, ci: 2, merge_queue: 0 },
    basis: { tickets: 'measured', builds: 'measured', pauses: 'measured', prs: 'measured' },
    ...over,
  },
});

// ------------------------------------------------------------ 1. api key

test('1 api.utilization hits /api/coord/utilization', async () => {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ rows: [], as_of: 't' }) };
  };
  const body = await api.utilization();
  assert.deepEqual(calls, ['/api/coord/utilization']);
  assert.deepEqual(body.rows, []);
});

// ------------------------------------------------------------ 2. one row per fleet project

test('2 utilizationRows: one row per fleet project, in fleet order, no snapshot is its own verdict', () => {
  const resp = { rows: [tracer('project-5'), tracer('cromford')] };
  const out = utilizationRows(resp, ['cromford', 'project-3', 'project-5', 'cromford'], NOW);
  assert.deepEqual(out.rows.map((r) => r.project), ['cromford', 'project-3', 'project-5']);
  const project_3 = out.rows[1];
  assert.equal(project_3.verdict, 'no snapshot');
  assert.equal(project_3.snapshot, null);
  for (const k of ['ready', 'blocked', 'held', 'parked', 'running', 'cap', 'free', 'pauses', 'prReview', 'prCi', 'prMq']) {
    assert.equal(project_3[k], null, `no-snapshot ${k}`);
  }
  assert.equal(out.rows[0].verdict, 'unknown', 'a stored unknown stays unknown, never "no snapshot"');
  assert.equal(out.fleetUnread, false);
  assert.deepEqual(out.extra, []);
});

test('2b utilizationRows: a non-fleet snapshot is named in extra, never silently dropped', () => {
  const out = utilizationRows({ rows: [tracer('a'), tracer('ghost')] }, ['a'], NOW);
  assert.deepEqual(out.rows.map((r) => r.project), ['a']);
  assert.deepEqual(out.extra, ['ghost']);
});

test('2c utilizationRows: an unread fleet list falls back to the snapshot projects, flagged', () => {
  for (const fleet of [null, []]) {
    const out = utilizationRows({ rows: [tracer('a'), tracer('b')] }, fleet, NOW);
    assert.deepEqual(out.rows.map((r) => r.project), ['a', 'b']);
    assert.equal(out.fleetUnread, true);
  }
});

test('2d utilizationRows: rows that are not an array are not an empty answer', () => {
  assert.equal(utilizationRows({}, ['a'], NOW), null);
  assert.equal(utilizationRows({ rows: 'x' }, ['a'], NOW), null);
  assert.equal(utilizationRows(null, ['a'], NOW), null);
});

// ------------------------------------------------------------ 3. stale

test('3 stale: as_of over 2h is stale, under is not, unparseable is stale', () => {
  assert.equal(STALE_MS, 2 * 3600 * 1000);
  const rows = utilizationRows({ rows: [
    tracer('old', 121 * MIN), tracer('fresh', 119 * MIN), { ...tracer('bad'), as_of: 'yesterday' },
  ] }, ['old', 'fresh', 'bad'], NOW).rows;
  const by = Object.fromEntries(rows.map((r) => [r.project, r]));
  assert.equal(by.old.stale, true);
  assert.equal(by.fresh.stale, false);
  assert.equal(by.bad.stale, true);
});

// ------------------------------------------------------------ 4. buckets: absent is —, never 0

test('4 buckets: null / absent / string / negative are null and render —; 0 stays 0', () => {
  const rows = utilizationRows({ rows: [
    tracer('today'),
    full('zero', 'starved'),
    full('junk', 'busy', {
      tickets: { ready: '3', blocked: -1, held: null },
      builds: { running: 1.5, pool_cap: 'unlimited', free_slots: '5' },
      prs: { review: null },
    }),
    full('unl', 'busy', { builds: { running: 2, pool_cap: 'unlimited', free_slots: 'unlimited' } }),
  ] }, ['today', 'zero', 'junk', 'unl'], NOW).rows;
  const by = Object.fromEntries(rows.map((r) => [r.project, r]));
  // Today's tracer: no tickets, pauses or prs section shipped yet.
  for (const k of ['ready', 'blocked', 'held', 'parked', 'pauses', 'prReview', 'prCi', 'prMq']) {
    assert.equal(by.today[k], null, `tracer ${k}`);
    assert.equal(cellText(by.today[k]), '—');
  }
  assert.deepEqual([by.today.running, by.today.cap, by.today.free], [1, 3, 2]);
  assert.equal(by.zero.ready, 0);
  assert.equal(cellText(by.zero.ready), '0');
  assert.equal(by.zero.prMq, 0);
  for (const k of ['ready', 'blocked', 'held', 'parked', 'running', 'free', 'prReview', 'prCi', 'prMq']) {
    assert.equal(by.junk[k], null, `junk ${k}`);
  }
  assert.equal(by.junk.cap, 'unlimited');
  assert.deepEqual([by.unl.cap, by.unl.free], ['unlimited', 'unlimited']);
  assert.equal(cellText('unlimited'), 'unlimited');
  assert.equal(cellText(null), '—');
  assert.equal(cellText(undefined), '—');
  assert.equal(cellText(0), '0');
});

test('4b payload_error survives with its verdict and every bucket —', () => {
  const [r] = utilizationRows({ rows: [
    { project: 'p', hour: 'h', verdict: 'busy', payload: null, payload_error: 'unparseable', box: 'hub', as_of: iso(MIN) },
  ] }, ['p'], NOW).rows;
  assert.equal(r.verdict, 'busy');
  assert.equal(r.payloadError, 'unparseable');
  assert.equal(r.running, null);
  assert.equal(r.free, null);
});

test('4c why: payload.why wins; otherwise the verdict text and the unmeasured buckets', () => {
  const rows = utilizationRows({ rows: [
    full('a', 'starved', { why: 'free slots, nothing ready' }),
    full('b', 'unknown', { basis: { builds: 'measured', tickets: 'unmeasured' } }),
  ] }, ['a', 'b'], NOW).rows;
  assert.equal(rows[0].why, 'free slots, nothing ready');
  assert.match(rows[1].why, /unmeasured: tickets/);
  assert.doesNotMatch(rows[1].why, /builds/);
});

test('4d pauses: kept with their since age; a pause with no since ages —', () => {
  const [r] = utilizationRows({ rows: [full('p', 'paused', { pauses: [
    { kind: 'flag', name: 'paused-p', since: iso(90 * MIN), stops_builds: true },
    { kind: 'conductor', name: 'hold', stops_builds: false },
  ] })] }, ['p'], NOW).rows;
  assert.deepEqual(r.pauses.map((p) => p.name), ['paused-p', 'hold']);
  assert.equal(pauseAge(r.pauses[0].since, NOW), '1h');
  assert.equal(pauseAge(r.pauses[1].since, NOW), '—');
  const [n] = utilizationRows({ rows: [full('q', 'busy', { pauses: 'none' })] }, ['q'], NOW).rows;
  assert.equal(n.pauses, null, 'a non-array pauses is unmeasured, not "no pauses"');
});

test('4e verdictRank puts the problems first, starved at the top', () => {
  const order = ['busy', 'no snapshot', 'starved', 'saturated', 'unknown', 'paused', 'blocked'];
  const sorted = [...order].sort((a, b) => verdictRank(a) - verdictRank(b));
  assert.deepEqual(sorted, ['starved', 'blocked', 'paused', 'unknown', 'no snapshot', 'saturated', 'busy']);
  assert.equal(verdictRank('whatever'), 7);
  assert.equal(VERDICT_RANK.starved, 0);
});

// ------------------------------------------------------------ 5. the view, rendered

const settledOk = (data) => ({ data, error: null, loading: false, reload: () => {} });
const view = (props) => render(h(UtilizationView, { now: NOW, onOpen: () => {}, open: null, ...props }));

test('5 view: verdict text, /p/<project> links, aria-sort on every header, starved first', () => {
  const out = view({
    util: settledOk({ rows: [full('busy-one', 'busy'), full('starved-one', 'starved'), tracer('cromford')] }),
    projects: ['busy-one', 'cromford', 'starved-one', 'project-3 os'],
  });
  for (const v of ['starved', 'busy', 'unknown', 'no snapshot']) assert.ok(out.includes(`>${v}<`), `verdict ${v}`);
  assert.ok(out.includes('href="/p/cromford"'));
  assert.ok(out.includes('href="/p/project-3%20os"'), 'project names are encoded');
  const ths = out.match(/<th\b[^>]*>/g) || [];
  assert.equal(ths.length, 14, 'PROJECT … AS OF');
  for (const th of ths) assert.match(th, /aria-sort="(ascending|descending|none)"/);
  assert.equal(ths.filter((t) => /aria-sort="ascending"/.test(t)).length, 1);
  const verdictTh = out.slice(out.indexOf('<th'), out.indexOf('</thead>')).split('</th>')[1];
  assert.match(verdictTh, /aria-sort="ascending"/, 'VERDICT is the default sort');
  assert.ok(out.indexOf('href="/p/starved-one"') < out.indexOf('href="/p/busy-one"'), 'starved sorts before busy');
  assert.ok(out.includes('tag tag--warn'), 'starved is tagged as a problem');
  assert.ok(out.includes('aria-expanded="false"'));
  assert.ok(out.includes('—'), 'the tracer row renders its unshipped buckets as —');
  assert.ok(out.includes('tablewrap'), 'the table scrolls inside its own wrapper');
});

test('5b view: loading, error and empty are three different screens', () => {
  const loading = view({ util: { data: null, error: null, loading: true }, projects: ['a'] });
  assert.ok(loading.includes('skel'));
  assert.ok(!loading.includes('<table'));

  const error = view({ util: { data: null, error: new Error('http_404'), loading: false, reload: () => {} }, projects: ['a'] });
  assert.ok(error.includes('http_404'));
  assert.ok(error.includes('RETRY'));
  assert.ok(!error.includes('no utilization snapshot yet'), 'an error is not empty');

  const empty = view({ util: settledOk({ rows: [], as_of: 't' }), projects: ['a', 'b'] });
  assert.ok(empty.includes('no utilization snapshot yet'));
  assert.ok(empty.includes(':07'));
  assert.ok(!empty.includes('could not load'), 'empty is not an error');
  assert.ok(!empty.includes('<table'), 'zero snapshots is the empty state, not a table of no-snapshot rows');

  const bad = view({ util: settledOk({ nope: 1 }), projects: ['a'] });
  assert.ok(bad.includes('could not load'), 'a body without rows[] is an error, never empty');
  assert.ok(!bad.includes('no utilization snapshot yet'));
});

test('5c view: footnotes for extra, unread fleet and stale rows', () => {
  const out = view({ util: settledOk({ rows: [tracer('a', 3 * 60 * MIN), tracer('ghost')] }), projects: ['a'] });
  assert.ok(out.includes('ghost'), 'a non-fleet project is named');
  assert.match(out, /1 row.*older than 2h/);
  assert.ok(out.includes('>stale<'));
  const unread = view({ util: settledOk({ rows: [tracer('a')] }), projects: null });
  assert.match(unread, /fleet list unread/);
});

test('5d view: the open drill-down shows pauses, basis and the raw payload', () => {
  const out = view({
    util: settledOk({ rows: [full('p', 'paused', { basis: { tickets: 'unmeasured', builds: 'measured' } }), tracer('q')] }),
    projects: ['p', 'q'], open: 'p',
  });
  assert.ok(out.includes('PAYLOAD · p'));
  assert.ok(out.includes('paused-project-3'));
  assert.ok(out.includes('1h'), 'pause since age');
  assert.ok(out.includes('tickets: unmeasured'));
  assert.ok(out.includes('aria-expanded="true"'));
  assert.ok(out.includes('<pre'));
  assert.match(out, /overflow-x:auto[^>]*>\s*<pre/);
  const none = view({ util: settledOk({ rows: [tracer('q')] }), projects: ['p', 'q'], open: 'p' });
  assert.ok(none.includes('no snapshot for p yet'));
  const noPauses = view({ util: settledOk({ rows: [tracer('q')] }), projects: ['q'], open: 'q' });
  assert.ok(noPauses.includes('pauses unmeasured'), 'the tracer has no pauses section: unmeasured, not "no pauses"');
});

// ------------------------------------------------------------ 6. route and nav

test('6 /utilization is routed and its nav entry sits right after CI', () => {
  const route = ROUTES.find(([p]) => p === '/utilization');
  assert.ok(route, 'routed');
  assert.equal(route[1], UtilizationScreen);
  const i = NAV.findIndex((n) => n.to === '/ci');
  assert.ok(i >= 0);
  assert.equal(NAV[i + 1].to, '/utilization');
  assert.equal(NAV[i + 1].match('/utilization'), true);
  assert.equal(NAV.filter((n) => n.match('/utilization')).length, 1, 'only one tab claims /utilization');
});
