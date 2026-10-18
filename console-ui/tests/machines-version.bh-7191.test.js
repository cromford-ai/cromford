import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, all, fire, rowFor, buttonIn, dialogOf } from './helpers/fake-dom.bh-5750.js';

// BH-7306 (BH-7191.4): the version columns on /machines. ORGO BOXES gets SHA,
// LAG, LAST SYNC and LAST BEAT from GET /api/coord/boxes, a row for each
// registry box the watchdog has no record of, and each FLY table a SHA column.
// LAG says `current` only for a stored 0 checked under 20 min ago; a failed
// feed says `unavailable`, never `current`.

installWindow();
const { render: mount } = await import('preact');
const { MachinesScreen } = await import('../src/screens/Machines.js');
const { shortSha, lagView, timeView, versionBoxRows, readBoxesVersion, LAG_FRESH_MIN, LAG_MAX_FALLBACK } = await import('../src/lib/boxes-version-api.js');

const FIXED_NOW = Date.parse('2026-10-14T06:00:00Z');
Date.now = () => FIXED_NOW;
const ago = (min) => new Date(FIXED_NOW - min * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');

const block = (apps, machines) => ({ machine_count: machines.length, machines, apps, orphan_jobs: [], jobs: [] });
const DASH = () => ({
  boxes: { hub: '1m ago', 'bw-alpha': '1m ago', 'bw-beta': '2m ago' },
  fly: {
    proj: block(['pool-proj'], [
      { id: 'flym1aaa', role: 'pool', state: 'started', region: 'iad', app: 'pool-proj', harness_commit: '0123456789abcdef' },
      { id: 'flym2bbb', role: 'pool', state: 'started', region: 'iad', app: 'pool-proj' },
      { id: 'flym3ccc', role: 'pool', state: 'stopped', region: 'iad', app: 'pool-proj' }
    ])
  },
  fly_errors: [],
  snapshot_age_min: 1
});
const BOXES = () => ({
  boxes: [
    { box: 'bw-alpha', harness_commit: 'aaaa1111bbbb2222', harness_lag_min: 0, lag_checked_at: ago(5), harness_synced_at: ago(30), last_beat_at: ago(2) },
    { box: 'bw-beta', harness_commit: 'bbbb2222', harness_lag_min: 40, lag_checked_at: ago(3) },
    { box: 'bh-hub-2', harness_commit: 'cccc3333dddd', harness_lag_min: 31, lag_checked_at: ago(1) }
  ],
  as_of: ago(0)
});
const REGISTRY = () => ({ boxes: [{ box: 'bw-alpha' }, { box: 'bw-beta' }, { box: 'bh-hub-2' }, { box: 'box-review-2' }] });
const LANE_FLEET = () => ({ machines: [{ machine_id: 'flym2bbb', state: 'started', harness_commit: 'fedcba9876543210' }] });
const SETTINGS = () => ({ settings: [{ key: 'harness_version.max_lag_min', value: '30' }] });

function world(over = {}) {
  return routedFetch((u, method) => {
    if (over[u]) return over[u]();
    if (u === '/api/dash/machines') return [200, DASH()];
    if (u === '/api/coord/boxes') return [200, BOXES()];
    if (u === '/api/coord/registry') return [200, REGISTRY()];
    if (u === '/api/coord/lane-fleet/machines') return [200, LANE_FLEET()];
    if (u === '/api/coord/settings') return [200, SETTINGS()];
    if (u === '/api/coord/orgo-computers') return [404, { error: 'not_found' }];
    if (u.startsWith('/api/coord/box-commands') && method === 'GET') return [200, { commands: [], truncated: false }];
    return [404, { error: 'not_found' }];
  });
}

let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });
async function screen(ready = () => rowFor(root, 'bw-alpha') && /current/.test(boxesTable().textContent)) {
  const doc = installDom();
  root = doc.createElement('div');
  mount(h(MachinesScreen, {}), root);
  await waitFor(ready, 'the ORGO BOXES rows with version cells', () => root.textContent);
  return doc;
}
const tables = () => all(root).filter((n) => n.localName === 'table');
const boxesTable = () => tables()[0];
// A header's label without the sort indicator the active column carries.
const label = (th) => th.textContent.replace(/[^A-Z ]/g, '').trim();
const headersOf = (t) => all(t).filter((n) => n.localName === 'th').map(label);
const tds = (tr) => all(tr).filter((n) => n.localName === 'td');
const cell = (t, rowName, label) => {
  const i = headersOf(t).indexOf(label);
  assert.ok(i >= 0, `no ${label} header in ${headersOf(t)}`);
  const tr = rowFor(t, rowName);
  assert.ok(tr, `no row ${rowName}`);
  return tds(tr)[i];
};
const text = (n) => n.textContent.trim();
// preact writes a style string to style.cssText.
const amber = (n) => all(n).some((x) => /var\(--amber\)/.test(`${(x.attrs && x.attrs.style) || ''} ${(x.style && x.style.cssText) || ''}`));
const bodyRows = (t) => all(t).filter((n) => n.localName === 'tr' && tds(n).length);

test('V1: shortSha and versionBoxRows', () => {
  assert.equal(shortSha('0123456789abcdef'), '01234567');
  assert.equal(shortSha('abc12'), 'abc12', 'a short sha is shown whole');
  assert.equal(shortSha(null), '-');
  assert.equal(shortSha(''), '-');
  const watch = [{ name: 'bw-alpha', ping: '1m ago', min: 1 }, { name: 'bw-beta', ping: '2m ago', min: 2 }];
  const data = { status: { ok: true, byName: { 'bw-alpha': { box: 'bw-alpha', harness_lag_min: 0 } } }, registry: { ok: true, boxes: REGISTRY().boxes }, fly: { ok: true, byMachine: {} }, maxLagMin: 30 };
  const rows = versionBoxRows(watch, data);
  assert.deepEqual(rows.map((r) => r.name), ['bw-alpha', 'bw-beta', 'bh-hub-2', 'box-review-2'], 'registry-only boxes added once, watchdog boxes not doubled');
  assert.equal(rows[0].registryOnly, false);
  assert.equal(rows[0].status.harness_lag_min, 0, 'the box_status row joined by exact name');
  assert.equal(rows[1].status, null);
  const extra = rows.find((r) => r.name === 'bh-hub-2');
  assert.equal(extra.registryOnly, true);
  assert.equal(extra.ping, null);
  assert.equal(extra.min, null);
  assert.deepEqual(versionBoxRows(watch, null).map((r) => r.name), ['bw-alpha', 'bw-beta'], 'while loading: the watchdog rows only');
});

test('V2: the LAG cell table', () => {
  const now = FIXED_NOW;
  const v = (row, o = {}) => lagView(row, { ok: true, now, maxLagMin: 30, ...o });
  assert.equal(LAG_FRESH_MIN, 20);
  assert.equal(LAG_MAX_FALLBACK, 30);
  assert.equal(v({ harness_lag_min: 0, lag_checked_at: ago(5) }).text, 'current');
  assert.equal(v({ harness_lag_min: 0, lag_checked_at: ago(5) }).sort, 0);
  assert.equal(v({ harness_lag_min: 0, lag_checked_at: ago(19) }).text, 'current');
  assert.equal(v({ harness_lag_min: 0, lag_checked_at: ago(20) }).text, 'unchecked', 'the 20-min edge');
  assert.equal(v({ harness_lag_min: 0, lag_checked_at: null }).text, 'unchecked');
  assert.equal(v({ harness_lag_min: 0, lag_checked_at: 'not a time' }).text, 'unchecked');
  assert.equal(v({ harness_lag_min: null, lag_checked_at: ago(1) }).text, 'unchecked');
  assert.equal(v({ harness_lag_min: null, lag_checked_at: ago(1) }).sort, null);
  const edge = v({ harness_lag_min: 30, lag_checked_at: ago(1) });
  assert.equal(edge.text, '30 min');
  assert.notEqual(edge.tone, 'warn', 'at the threshold is not amber');
  const over = v({ harness_lag_min: 31, lag_checked_at: ago(1) });
  assert.equal(over.text, '31 min');
  assert.equal(over.tone, 'warn');
  assert.deepEqual(v({ harness_lag_min: 40, lag_checked_at: ago(1) }), { text: '40 min', tone: 'warn', sort: 40 });
  assert.equal(v(null).text, 'unchecked', 'a box absent from /api/boxes');
  assert.equal(v(undefined).text, 'unchecked');
  const down = v({ harness_lag_min: 0, lag_checked_at: ago(1) }, { ok: false });
  assert.equal(down.text, 'unavailable', 'a failed /api/boxes is never current');
  assert.equal(down.sort, null);
  assert.equal(v({ harness_lag_min: 31, lag_checked_at: ago(1) }, { maxLagMin: undefined }).tone, 'warn', 'no threshold: the fallback 30');
  assert.equal(timeView(ago(30), FIXED_NOW), '30m');
  assert.equal(timeView(null, FIXED_NOW), '-');
});

test('V2b: readBoxesVersion: the settings row moves the threshold, a failed settings read falls back to 30', async () => {
  world({ '/api/coord/settings': () => [200, { settings: [{ key: 'harness_version.max_lag_min', value: '45' }] }] });
  assert.equal((await readBoxesVersion()).maxLagMin, 45);
  world({ '/api/coord/settings': () => [500, { error: 'x' }] });
  const d = await readBoxesVersion();
  assert.equal(d.maxLagMin, 30);
  assert.equal(d.status.ok, true);
  assert.equal(d.status.byName['bw-beta'].harness_lag_min, 40);
  assert.equal(d.fly.byMachine.flym2bbb.harness_commit, 'fedcba9876543210');
  assert.equal(lagView({ harness_lag_min: 31, lag_checked_at: ago(1) }, { ok: true, now: FIXED_NOW, maxLagMin: d.maxLagMin }).tone, 'warn');
  world({ '/api/coord/registry': () => [403, { error: 'forbidden' }] });
  const r = await readBoxesVersion();
  assert.equal(r.registry.ok, false, 'a denied side read marks only that feed');
  assert.equal(r.status.ok, true);
});

test('V3: the ORGO BOXES table shows SHA, LAG, LAST SYNC and LAST BEAT headers', async () => {
  world();
  await screen();
  const hs = headersOf(boxesTable());
  for (const h of ['SHA', 'LAG', 'LAST SYNC', 'LAST BEAT']) assert.ok(hs.includes(h), `header ${h} in ${hs}`);
  assert.ok(hs.indexOf('SHA') > hs.indexOf('SPECS') && hs.indexOf('LAST BEAT') < hs.indexOf('ACTIONS'), `order ${hs}`);
  const wrap = boxesTable().parentNode;
  assert.match(wrap.attrs.class, /tablewrap/, 'the table scrolls inside its own .tablewrap');
  assert.match(wrap.attrs.class, /tablewrap--wide/);
  assert.equal(text(cell(boxesTable(), 'bw-alpha', 'SHA')), 'aaaa1111');
  assert.equal(text(cell(boxesTable(), 'bw-alpha', 'LAST SYNC')), '30m');
  assert.equal(text(cell(boxesTable(), 'bw-alpha', 'LAST BEAT')), '2m');
});

test('V4: LAG clicked twice sorts descending with aria-sort; nulls stay last', async () => {
  world();
  await screen();
  const lagTh = () => all(boxesTable()).find((n) => n.localName === 'th' && label(n) === 'LAG');
  const btn = () => all(lagTh()).find((n) => n.localName === 'button');
  fire(btn(), 'click');
  await flush();
  assert.equal(lagTh().attrs['aria-sort'], 'ascending');
  assert.equal(text(tds(bodyRows(boxesTable())[0])[0]).startsWith('bw-alpha'), true, 'ascending: the current (0) box first');
  fire(btn(), 'click');
  await flush();
  assert.equal(lagTh().attrs['aria-sort'], 'descending');
  const names = bodyRows(boxesTable()).map((tr) => text(tds(tr)[0]));
  assert.deepEqual(names.slice(0, 3), ['bw-beta', 'bh-hub-2', 'bw-alpha'], `descending by lag: ${names}`);
  assert.deepEqual(names.slice(3).sort(), ['box-review-2', 'hub'], 'unchecked rows last');
});

test('V5: registry-only rows, the Orgo id guard, amber lag, the Fly SHA and the unshipped fields', async () => {
  world();
  await screen();
  const t = boxesTable();
  for (const name of ['bh-hub-2', 'box-review-2']) {
    const tr = rowFor(t, name);
    assert.ok(tr, `the registry-only row ${name}`);
    assert.equal(text(cell(t, name, 'LAST PING')), 'never');
    assert.equal(text(cell(t, name, 'STATE')), 'NO RECORD');
    for (const b of ['RESTART', 'RESIZE', 'STOP', 'RETIRE']) assert.equal(buttonIn(tr, b), undefined, `${name} has no ${b}`);
    assert.ok(buttonIn(tr, 'SYNC'), `${name} keeps the box lane SYNC`);
  }
  assert.equal(text(cell(t, 'box-review-2', 'LAG')), 'unchecked');
  assert.equal(text(cell(t, 'bh-hub-2', 'SHA')), 'cccc3333');
  const beta = cell(t, 'bw-beta', 'LAG');
  assert.equal(text(beta), '40 min');
  assert.equal(amber(beta), true, 'over the threshold is amber');
  assert.equal(text(cell(t, 'bw-alpha', 'LAG')), 'current');
  assert.equal(amber(cell(t, 'bw-alpha', 'LAG')), false);
  assert.equal(text(cell(t, 'bw-beta', 'SHA')), 'bbbb2222');
  assert.equal(text(cell(t, 'bw-beta', 'LAST BEAT')), '-', 'a field a sibling has not shipped');
  assert.equal(text(cell(t, 'bw-beta', 'LAST SYNC')), '-');
  assert.equal(text(cell(t, 'hub', 'SHA')), '-', 'a box with no box_status row');
  // The Orgo id of an existing watchdog row is unchanged by the registry rows.
  fire(buttonIn(rowFor(t, 'bw-alpha'), 'RESTART'), 'click');
  await waitFor(() => dialogOf(root), 'the RESTART confirm');
  assert.match(dialogOf(root).textContent, /Restart Orgo box alpha \(bw-alpha\)/);
  const fly = tables()[1];
  assert.ok(headersOf(fly).includes('SHA'), `fly headers ${headersOf(fly)}`);
  assert.ok(headersOf(fly).indexOf('SHA') === headersOf(fly).indexOf('REGION') + 1, 'SHA sits after REGION');
  assert.equal(text(cell(fly, 'flym1aaa', 'SHA')), '01234567', 'from the dash feed');
  assert.equal(text(cell(fly, 'flym2bbb', 'SHA')), 'fedcba98', 'from the lane-fleet feed');
  assert.equal(text(cell(fly, 'flym3ccc', 'SHA')), '-');
});

test('V6: a failed /api/coord/boxes says unavailable, never current, and the table still renders', async () => {
  world({ '/api/coord/boxes': () => [500, { error: 'boom' }], '/api/coord/lane-fleet/machines': () => [500, { error: 'boom' }] });
  await screen(() => rowFor(root, 'bw-alpha') && /unavailable/.test(boxesTable().textContent) && rowFor(root, 'bh-hub-2'));
  const t = boxesTable();
  for (const name of ['hub', 'bw-alpha', 'bw-beta', 'bh-hub-2', 'box-review-2']) {
    assert.equal(text(cell(t, name, 'LAG')), 'unavailable', `${name} LAG`);
    assert.equal(text(cell(t, name, 'SHA')), 'unavailable', `${name} SHA`);
  }
  assert.doesNotMatch(t.textContent, /current/);
  assert.ok(buttonIn(rowFor(t, 'bw-alpha'), 'RESTART'), 'the existing row is intact');
  const fly = tables()[1];
  assert.equal(text(cell(fly, 'flym1aaa', 'SHA')), '01234567', 'the dash feed still answers');
  assert.equal(text(cell(fly, 'flym2bbb', 'SHA')), 'unavailable');
});

test('V7: the four coord reads and /api/dash/machines start before any answer; the cells show … while loading', async () => {
  const calls = [];
  const pending = [];
  const answer = (u) => {
    if (u === '/api/dash/machines') return [200, DASH()];
    if (u === '/api/coord/boxes') return [200, BOXES()];
    if (u === '/api/coord/registry') return [200, REGISTRY()];
    if (u === '/api/coord/lane-fleet/machines') return [200, LANE_FLEET()];
    if (u === '/api/coord/settings') return [200, SETTINGS()];
    if (u.startsWith('/api/coord/box-commands')) return [200, { commands: [], truncated: false }];
    return [404, { error: 'not_found' }];
  };
  globalThis.fetch = (url) => {
    const u = String(url);
    calls.push(u);
    return new Promise((resolve) => pending.push({ u, go: () => { const [status, payload] = answer(u); resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(payload) }); } }));
  };
  const doc = installDom();
  root = doc.createElement('div');
  mount(h(MachinesScreen, {}), root);
  await flush();
  for (const u of ['/api/dash/machines', '/api/coord/boxes', '/api/coord/registry', '/api/coord/lane-fleet/machines', '/api/coord/settings']) {
    assert.ok(calls.includes(u), `${u} requested before any answer: ${calls}`);
  }
  pending.filter((p) => p.u === '/api/dash/machines').forEach((p) => p.go());
  await waitFor(() => rowFor(root, 'bw-alpha'), 'the watchdog rows');
  assert.equal(text(cell(boxesTable(), 'bw-alpha', 'LAG')), '…');
  assert.equal(text(cell(boxesTable(), 'bw-alpha', 'SHA')), '…');
  pending.forEach((p) => p.go());
  await waitFor(() => /current/.test(boxesTable().textContent), 'the version cells');
});
