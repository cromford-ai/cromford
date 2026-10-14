import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, fire, isDisabled, dialogOf, confirmOf, byName, byTestId, buttonIn, type, all } from './helpers/fake-dom.bh-5750.js';

// BH-5750 C6 (T6.3): each Fly project section on /machines. A project on the
// pool gets CAP (number + SET -> fly_pool_cap); one that is not gets ONBOARD
// TO POOL (fly_onboard). Both open the in-app modal with the A6 text: Fly
// bills per running machine, no fixed monthly price. A cap of 0, -1 or 2.5
// is refused, never clamped.

installWindow();
const { render: mount } = await import('preact');
const { MachinesScreen } = await import('../src/screens/Machines.js');
const { flyOnPool } = await import('../src/lib/orgo-state.js');

const block = (apps, machines = []) => ({ machine_count: machines.length, machines, apps, orphan_jobs: [], jobs: [] });
const FLY = {
  'proj-on': block(['pool-proj-on', 'builder-proj-on'], [{ id: 'm1aaaa', role: 'pool', state: 'started', region: 'iad', app: 'pool-proj-on' }]),
  'proj-off': block(['builder-proj-off'])
};
const A6 = 'Fly bills per running machine; no fixed monthly price';

let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });
async function screen(post) {
  const doc = installDom();
  const posted = [];
  routedFetch((u, method, body) => {
    if (u === '/api/dash/machines') return [200, { boxes: { 'bw-alpha': '1m ago' }, fly: FLY, fly_errors: [], snapshot_age_min: 1 }];
    if (u === '/api/coord/orgo-computers') return [404, { error: 'not_found' }];
    if (u.startsWith('/api/coord/box-commands') && method === 'GET') return [200, { commands: [], truncated: false }];
    if (method === 'POST') { posted.push(body); return post ? post(body) : [201, { id: 90, status: 'requested', deduped: false }]; }
    return [404, { error: 'not_found' }];
  });
  root = doc.createElement('div');
  mount(h(MachinesScreen, {}), root);
  await waitFor(() => byTestId(root, 'fly-pool-controls').length === 2, 'two Fly pool control rows', () => root.textContent);
  const ctl = (p) => byTestId(root, 'fly-pool-controls').find((n) => n.attrs['data-project'] === p);
  return { doc, posted, ctl };
}

test('F7: pool membership is read from the Fly block: a pool-<p> app or a pool machine', () => {
  assert.equal(flyOnPool('proj-on', FLY['proj-on']), true);
  assert.equal(flyOnPool('proj-off', FLY['proj-off']), false);
  assert.equal(flyOnPool('p', block(['p-pool'])), true);
  assert.equal(flyOnPool('p', block([], [{ id: 'x', role: 'pool' }])), true);
  assert.equal(flyOnPool('p', null), false);
});

test('F8: a pool project has CAP + SET (no ONBOARD); SET opens the A6 modal and posts fly_pool_cap with the number', async () => {
  const { posted, ctl } = await screen();
  const on = ctl('proj-on');
  assert.equal(buttonIn(on, 'ONBOARD TO POOL'), undefined);
  const set = () => buttonIn(ctl('proj-on'), 'SET');
  assert.equal(isDisabled(set()), true, 'blank cap');
  for (const bad of ['0', '-1', '2.5', 'x']) {
    type(byName(on, 'pool_cap'), bad);
    await flush();
    assert.equal(isDisabled(set()), true, `cap ${bad} is refused`);
  }
  type(byName(on, 'pool_cap'), '5');
  await flush();
  assert.equal(isDisabled(set()), false);
  fire(set(), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d, 'the in-app modal');
  assert.ok(d.textContent.includes(A6), d.textContent);
  assert.match(d.textContent, /\b5\b/);
  assert.match(d.textContent, /proj-on/);
  assert.doesNotMatch(d.textContent, /\$/, 'no price is shown');
  const reason = all(d).find((n) => n.localName === 'input');
  type(reason, 'more builds');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => posted.length === 1, 'the POST');
  assert.equal(posted[0].type, 'fly_pool_cap');
  assert.equal(posted[0].target, 'proj-on');
  assert.equal(posted[0].cap, 5);
  assert.equal(posted[0].box, 'hub');
  assert.equal('confirm_monthly_usd' in posted[0], false, 'no price token');
});

test('F9: a project off the pool has ONBOARD TO POOL; it opens the A6 modal and posts fly_onboard', async () => {
  const { posted, ctl } = await screen();
  const off = ctl('proj-off');
  assert.equal(byName(off, 'pool_cap'), undefined, 'no CAP for a project off the pool');
  fire(buttonIn(off, 'ONBOARD TO POOL'), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d.textContent.includes(A6));
  type(all(d).find((n) => n.localName === 'input'), 'ready for the pool');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => posted.length === 1, 'the POST');
  assert.equal(posted[0].type, 'fly_onboard');
  assert.equal(posted[0].target, 'proj-off');
});

test('F10: Escape on the CAP modal posts nothing', async () => {
  const { doc, posted, ctl } = await screen();
  type(byName(ctl('proj-on'), 'pool_cap'), '3');
  await flush();
  fire(buttonIn(ctl('proj-on'), 'SET'), 'click');
  await flush();
  fire(doc, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(dialogOf(root), undefined);
  assert.equal(posted.length, 0);
});
