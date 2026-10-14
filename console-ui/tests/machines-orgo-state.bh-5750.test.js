import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, all, fire, rowsOf, rowFor } from './helpers/fake-dom.bh-5750.js';

// BH-5750 C4 (T4.4): the ORGO STATE and SPECS columns on /machines. A box row
// is matched to an Orgo computer by name. No record is `unknown`; a read older
// than 15 minutes is stale, not current; a gone_at row is gone; a route that
// is not deployed (404/503) is "not available", which is not "no data".

installWindow();
const { render: mount } = await import('preact');
const { MachinesScreen, BoxesTable } = await import('../src/screens/Machines.js');
const { orgoBoxIds, shapeOrgoComputers, orgoStateFor, specsText } = await import('../src/lib/orgo-state.js');

// One fixed clock for the whole file: the fixtures and the screen read the same now.
const FIXED_NOW = Date.parse('2026-10-10T12:00:00Z');
Date.now = () => FIXED_NOW;
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const NAMES = ['hub', 'bw-1', 'bw-alpha-2', 'bw-beta', 'bw-gamma', 'bw-delta'];
const ORGO = () => ({
  computers: [
    { orgo_id: 'oc-fixture-1', name: 'bw-alpha-2', account: 'acct-a', status: 'running', cpu: 4, ram_gb: 16, disk_gb: 100, seen_at: ago(2), gone_at: null },
    { orgo_id: 'oc-fixture-2', name: 'bw-beta', account: 'acct-b', status: 'stopped', cpu: 2, ram_gb: 8, disk_gb: 50, seen_at: ago(40), gone_at: null },
    { orgo_id: 'oc-fixture-3', name: 'bw-gamma', account: 'acct-a', status: 'running', cpu: 8, ram_gb: 32, disk_gb: 200, seen_at: ago(90), gone_at: ago(60) }
  ],
  accounts: { 'acct-a': { read_at: ago(2), ok: true, complete: true }, 'acct-b': { read_at: ago(40), ok: true, complete: true } },
  as_of: ago(0)
});
const rows = NAMES.map((name) => ({ name, ping: '1m ago', min: 1 }));
const cellText = (tr, i) => all(tr).filter((n) => n.localName === 'td')[i].textContent.trim();
const headers = (root) => all(root).filter((n) => n.localName === 'th').map((th) => th.textContent.trim());

let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });

test('S1: the Orgo box id comes from the row name; the hub and an all-number name have none', () => {
  assert.deepEqual(orgoBoxIds(NAMES), { hub: 'hub', 'bw-1': null, 'bw-alpha-2': 'alpha', 'bw-beta': 'beta', 'bw-gamma': 'gamma', 'bw-delta': 'delta' });
  assert.deepEqual(orgoBoxIds(['solo']), { solo: 'solo' });
  assert.deepEqual(orgoBoxIds(['Bad_Name', 'x-y']), { Bad_Name: null, 'x-y': null }, 'no shared prefix: no guessed id');
  assert.deepEqual(orgoBoxIds(['bw-alpha-2']), { 'bw-alpha-2': null }, 'one row has no prefix to strip');
});

test('S2: state and specs per row: running, stopped (stale), gone, unknown', () => {
  const o = shapeOrgoComputers(ORGO());
  const now = Date.now();
  const a = orgoStateFor('bw-alpha-2', o, now);
  assert.equal(a.state, 'running');
  assert.equal(a.stale, false);
  assert.equal(specsText(a.computer), '4c/16gb/100gb');
  const b = orgoStateFor('bw-beta', o, now);
  assert.equal(b.state, 'stopped');
  assert.equal(b.stale, true, 'a 40 min old read is stale');
  assert.match(b.text, /stale/);
  assert.equal(orgoStateFor('bw-gamma', o, now).state, 'gone', 'a gone_at row is not current');
  assert.equal(orgoStateFor('bw-delta', o, now).state, 'unknown');
  assert.equal(orgoStateFor('bw-delta', o, now).computer, null);
  assert.equal(orgoStateFor('bw-delta', { unavailable: true, reason: 'http_404' }, now).state, 'not available');
  assert.equal(orgoStateFor('bw-delta', null, now).state, 'loading');
  assert.equal(specsText(null), null);
});

test('S3: the ORGO STATE and SPECS columns render and sort by the displayed value', async () => {
  const doc = installDom();
  root = doc.createElement('div');
  mount(h(BoxesTable, { rows, onAction: () => {}, orgo: shapeOrgoComputers(ORGO()) }), root);
  await flush();
  const hs = headers(root);
  const si = hs.indexOf('ORGO STATE');
  const pi = hs.indexOf('SPECS');
  assert.ok(si > 0 && pi > 0, `headers ${hs}`);
  assert.match(cellText(rowFor(root, 'bw-alpha-2'), si), /^running/);
  assert.match(cellText(rowFor(root, 'bw-beta'), si), /stopped.*stale/);
  assert.match(cellText(rowFor(root, 'bw-gamma'), si), /^gone/);
  assert.match(cellText(rowFor(root, 'bw-delta'), si), /^unknown/);
  assert.equal(cellText(rowFor(root, 'bw-alpha-2'), pi), '4c/16gb/100gb');
  assert.equal(cellText(rowFor(root, 'bw-delta'), pi), '—');

  const sortBtn = (label) => all(root).find((n) => n.localName === 'th' && n.textContent.trim().startsWith(label)).childNodes.find((c) => c.localName === 'button');
  fire(sortBtn('ORGO STATE'), 'click');
  await flush();
  const states = () => rowsOf(root).slice(1).map((tr) => cellText(tr, si).split(/\s/)[0]);
  const asc = states();
  assert.deepEqual(asc, [...asc].sort(), `ascending by the shown state: ${asc}`);
  fire(sortBtn('ORGO STATE'), 'click');
  await flush();
  const desc = states();
  assert.deepEqual(desc, [...asc].reverse(), 'a second click sorts descending');
  const th = all(root).find((n) => n.localName === 'th' && n.textContent.trim().startsWith('ORGO STATE'));
  assert.equal(th.attrs['aria-sort'], 'descending');

  fire(sortBtn('SPECS'), 'click');
  await flush();
  const specs = rowsOf(root).slice(1).map((tr) => cellText(tr, pi));
  assert.deepEqual(specs.filter((s) => s !== '—'), [...specs.filter((s) => s !== '—')].sort(), `specs sort: ${specs}`);
});

async function screenWith(orgoAnswer) {
  const doc = installDom();
  routedFetch((u) => {
    if (u === '/api/dash/machines') return [200, { boxes: Object.fromEntries(NAMES.map((n) => [n, '1m ago'])), fly: {}, fly_errors: [], snapshot_age_min: 1 }];
    if (u === '/api/coord/orgo-computers') return orgoAnswer;
    if (u.startsWith('/api/coord/box-commands')) return [200, { commands: [], truncated: false }];
    return [404, { error: 'not_found' }];
  });
  root = doc.createElement('div');
  mount(h(MachinesScreen, {}), root);
  await waitFor(() => rowFor(root, 'bw-delta') && !/loading/.test(rowFor(root, 'bw-delta').textContent), 'the rows with a settled Orgo read', () => root.textContent);
  return headers(root).indexOf('ORGO STATE');
}

test('S4: the real screen reads /api/coord/orgo-computers into the column', async () => {
  const si = await screenWith([200, ORGO()]);
  assert.match(cellText(rowFor(root, 'bw-alpha-2'), si), /^running/);
  assert.match(cellText(rowFor(root, 'bw-delta'), si), /^unknown/);
});

test('S5: a 404 or 503 route is "not available", distinct from unknown; a 500 is a read failure', async () => {
  for (const status of [404, 503]) {
    const si = await screenWith([status, { error: 'not_found' }]);
    assert.match(cellText(rowFor(root, 'bw-alpha-2'), si), /^not available/, `${status}`);
    assert.doesNotMatch(cellText(rowFor(root, 'bw-alpha-2'), si), /unknown/);
    mount(null, root); root = null;
  }
  const si = await screenWith([500, { error: 'boom' }]);
  assert.match(cellText(rowFor(root, 'bw-alpha-2'), si), /^read failed/);
});
