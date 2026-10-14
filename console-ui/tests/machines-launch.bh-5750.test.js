import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, all, fire, isDisabled, dialogOf, confirmOf, byName, byTestId, buttonIn, type } from './helpers/fake-dom.bh-5750.js';

// BH-5750 C5 (L4, L5): the LAUNCH BOX section on /machines. id, project,
// account and specs; GET PRICE posts orgo_launch_quote; the modal shows the
// quote's usd_mo summary and capacity line verbatim; CONFIRM (LAUNCH) stays
// disabled until the quote is ok with a usd_mo, then posts orgo_launch with
// quote_id and that exact figure.

installWindow();
const { render: mount } = await import('preact');
const { MachinesScreen } = await import('../src/screens/Machines.js');

// One fixed clock for the whole file: the fixtures and the screen read the same now.
const FIXED_NOW = Date.parse('2026-10-10T12:00:00Z');
Date.now = () => FIXED_NOW;
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const OK_DETAIL = 'capacity: pool fits 2 more 4c boxes on acct-fixture | box-launch: box=gamma usd_mo=40 smoke=pending';
const NEEDS_DETAIL = 'box-launch: box=gamma result=fail rc=3 | NEEDS PURCHASE: acct-fixture has no free 8c slot';

function world(quote) {
  const posted = [];
  routedFetch((u, method, body) => {
    if (u === '/api/dash/machines') return [200, { boxes: { 'bw-alpha': '1m ago', 'bw-beta': '1m ago' }, fly: {}, fly_errors: [], snapshot_age_min: 1 }];
    if (u === '/api/coord/orgo-computers') return [200, { computers: [], accounts: { 'acct-fixture': { read_at: ago(1), ok: true, complete: true } }, as_of: ago(0) }];
    if (u.startsWith('/api/coord/box-commands') && method === 'GET') { const q = quote(); return [200, { commands: q ? [q] : [], truncated: false }]; }
    if (u === '/api/coord/box-commands' && method === 'POST') {
      posted.push(body);
      const id = 60 + posted.length;
      return [201, { id, status: 'requested', command: { id, ...body }, deduped: false }];
    }
    return [404, { error: 'not_found' }];
  });
  return posted;
}
let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });
async function screen() {
  const doc = installDom();
  root = doc.createElement('div');
  mount(h(MachinesScreen, { quotePoll: { intervalMs: 1, timeoutMs: 3000 } }), root);
  await waitFor(() => byTestId(root, 'launch-box').length === 1, 'the LAUNCH BOX section', () => root.textContent);
  return byTestId(root, 'launch-box')[0];
}
async function fill(sec) {
  type(byName(sec, 'launch_id'), 'gamma');
  type(byName(sec, 'launch_project'), 'proj-fixture');
  const acct = byName(sec, 'launch_account');
  acct.value = 'acct-fixture';
  fire(acct, acct.localName === 'select' ? 'change' : 'input');
  type(byName(sec, 'launch_vcpus'), '4');
  type(byName(sec, 'launch_mem_gb'), '16');
  type(byName(sec, 'launch_disk_gb'), '100');
  type(byName(sec, 'launch_reason'), 'new client');
  await flush();
}

test('L5: GET PRICE is disabled until every field is set; a bad spec is refused, not clamped', async () => {
  let quote = null;
  const posted = world(() => quote);
  const sec = await screen();
  const get = () => buttonIn(byTestId(root, 'launch-box')[0], 'GET PRICE');
  assert.ok(get(), 'GET PRICE');
  assert.equal(isDisabled(get()), true, 'empty form');
  await fill(sec);
  assert.equal(isDisabled(get()), false, 'a full form');
  type(byName(sec, 'launch_vcpus'), '0');
  await flush();
  assert.equal(isDisabled(get()), true, '0 vcpus is refused');
  assert.match(byTestId(root, 'launch-box')[0].textContent, /vcpus/);
  type(byName(sec, 'launch_vcpus'), '4.5');
  await flush();
  assert.equal(isDisabled(get()), true, '4.5 vcpus is refused');
  type(byName(sec, 'launch_vcpus'), '4');
  await flush();
  fire(get(), 'click');
  await waitFor(() => posted.length === 1 && dialogOf(root), 'the launch quote POST');
  assert.equal(posted[0].type, 'orgo_launch_quote');
  assert.equal(posted[0].target, 'gamma');
  assert.equal(posted[0].project, 'proj-fixture');
  assert.equal(posted[0].account, 'acct-fixture');
  assert.equal(posted[0].vcpus, 4);
  assert.equal(posted[0].mem_gb, 16);
  assert.equal(posted[0].disk_gb, 100);
  assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'LAUNCH is disabled while pricing');
  quote = { id: 61, box: 'hub', type: 'orgo_launch_quote', target: 'gamma', status: 'fail', detail: NEEDS_DETAIL, requested_at: ago(0), finished_at: ago(0) };
  await waitFor(() => /NEEDS PURCHASE/.test(dialogOf(root).textContent), 'the NEEDS PURCHASE line');
  assert.ok(dialogOf(root).textContent.includes('NEEDS PURCHASE: acct-fixture has no free 8c slot'));
  assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'NEEDS PURCHASE: LAUNCH stays disabled');
  fire(confirmOf(dialogOf(root)), 'click');
  await flush();
  assert.equal(posted.length, 1, 'nothing launched');
});

test('L4: the modal shows usd_mo and the capacity line; LAUNCH posts orgo_launch with the token', async () => {
  let quote = null;
  const posted = world(() => quote);
  const sec = await screen();
  await fill(sec);
  fire(buttonIn(sec, 'GET PRICE'), 'click');
  await waitFor(() => posted.length === 1 && dialogOf(root), 'the quote POST');
  assert.match(dialogOf(root).textContent, /pricing… queued for hub/);
  quote = { id: 61, box: 'hub', type: 'orgo_launch_quote', target: 'gamma', status: 'ok', detail: OK_DETAIL, requested_at: ago(0), finished_at: ago(0) };
  await waitFor(() => /usd_mo=40/.test(dialogOf(root).textContent), 'the priced modal', () => dialogOf(root).textContent);
  const d = dialogOf(root);
  assert.ok(d.textContent.includes('capacity: pool fits 2 more 4c boxes on acct-fixture'), 'the capacity line, verbatim');
  assert.ok(d.textContent.includes('box-launch: box=gamma usd_mo=40 smoke=pending'), 'the usd_mo summary, verbatim');
  assert.equal(confirmOf(d).textContent.trim(), 'LAUNCH');
  assert.equal(isDisabled(confirmOf(d)), false);
  fire(confirmOf(d), 'click');
  await waitFor(() => posted.length === 2, 'the launch POST');
  const p = posted[1];
  assert.equal(p.type, 'orgo_launch');
  assert.equal(p.target, 'gamma');
  assert.equal(p.project, 'proj-fixture');
  assert.equal(p.quote_id, 61);
  assert.equal(p.confirm_monthly_usd, '40');
  assert.equal(p.vcpus, 4);
  assert.equal(p.reason, 'new client');
  await flush();
  assert.match(root.textContent, /queued for hub/);
  assert.equal(all(root).some((n) => n.attrs && n.attrs.role === 'dialog'), false);
});
