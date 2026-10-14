import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import {
  installDom, installWindow, routedFetch, all, fire, isDisabled, dialogOf, buttonIn, confirmOf, byName, rowFor, type
} from './helpers/fake-dom.bh-5750.js';

// BH-5750 C3 (M1-M5): the Orgo row controls on /machines. RESTART, RESIZE,
// STOP and RETIRE on every Orgo row but the hub; RESIZE prices first and only
// an ok quote with a figure enables its CONFIRM, which sends that exact figure
// with the quote id; the BOX COMMANDS table shows NEXT: lines and the
// WAITING / NEEDS PURCHASE / refused tags. Mounted through the real screen and
// the real api client with a routed fetch. Native dialogs throw.

installWindow();
const { render } = await import('preact-render-to-string');
const { render: mount } = await import('preact');
const { MachinesScreen, BoxesTable, BoxCommandsSection } = await import('../src/screens/Machines.js');
const { shapeBoxCommands } = await import('../src/lib/box-commands.js');
const { quoteFigure, pollQuote, quoteView, detailView, failTag } = await import('../src/lib/box-op-detail.js');
const worker = await import('../../worker/jobs/src/lib/box-command-args.js');

// One fixed anchor for the whole file: the fixtures and the screen read the same
// clock. It still moves with elapsed run time, because M4 waits for the screen's
// own poll window to end.
const FIXED_NOW = Date.parse('2026-10-10T12:00:00Z');
const T0 = performance.now();
Date.now = () => FIXED_NOW + Math.floor(performance.now() - T0);
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const MACHINES = { boxes: { hub: '1m ago', 'bw-1': '1m ago', 'bw-alpha-2': '2m ago', 'bw-beta': '3m ago' }, fly: {}, fly_errors: [], snapshot_age_min: 1 };
const ORGO = () => ({
  computers: [
    { orgo_id: 'oc-fixture-1', name: 'bw-alpha-2', account: 'acct-fixture', status: 'running', cpu: 4, ram_gb: 16, disk_gb: 100, seen_at: ago(2), gone_at: null },
    { orgo_id: 'oc-fixture-2', name: 'bw-beta', account: 'acct-fixture', status: 'stopped', cpu: 2, ram_gb: 8, disk_gb: 50, seen_at: ago(2), gone_at: null }
  ],
  accounts: { 'acct-fixture': { read_at: ago(2), ok: true, complete: true } },
  as_of: ago(0)
});
const RESIZE_PLAN = 'box-ops: verb=resize id=alpha result=plan rc=0 | PLAN cost +$12/mo (now $40/mo, after $52/mo); --apply needs --confirm-monthly-usd 12';
const NEEDS = 'box-ops: verb=resize id=alpha result=fail rc=3 | NEEDS PURCHASE: plan 8c/32gb needs an upgrade on acct-fixture';

// The world the screen reads: one quote row the test moves along.
function world({ quote = () => null, post } = {}) {
  let nextId = 41;
  const posted = [];
  const calls = routedFetch((u, method, body) => {
    if (u === '/api/dash/machines') return [200, MACHINES];
    if (u === '/api/coord/orgo-computers') return [200, ORGO()];
    if (u.startsWith('/api/coord/box-commands') && method === 'GET') {
      const q = quote();
      return [200, { commands: q ? [q] : [], truncated: false, as_of: ago(0) }];
    }
    if (u === '/api/coord/box-commands' && method === 'POST') {
      posted.push(body);
      if (post) { const r = post(body); if (r) return r; }
      const id = nextId++;
      return [201, { id, status: 'requested', command: { id, ...body }, deduped: false }];
    }
    return [404, { error: 'not_found' }];
  });
  return { calls, posted };
}

let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });
async function screen(props = {}) {
  const doc = installDom();
  root = doc.createElement('div');
  mount(h(MachinesScreen, { quotePoll: { intervalMs: 1, timeoutMs: 3000 }, ...props }), root);
  await waitFor(() => rowFor(root, 'bw-alpha-2'), 'the ORGO BOXES rows', () => root.textContent);
  return doc;
}
const orgoLabels = ['RESTART', 'RESIZE', 'STOP', 'RETIRE'];
const labelsIn = (tr) => all(tr).filter((n) => n.localName === 'button').map((b) => b.textContent.trim());

test('M1: every Orgo row but the hub has RESTART, RESIZE, STOP and RETIRE; RESIZE asks for orgo_resize_quote', async () => {
  const doc = installDom();
  const calls = [];
  const rows = Object.keys(MACHINES.boxes).map((name) => ({ name, ping: '1m ago', min: 1 }));
  root = doc.createElement('div');
  mount(h(BoxesTable, { rows, onAction: (...a) => calls.push(a) }), root);
  await flush();
  for (const name of ['bw-alpha-2', 'bw-beta']) {
    const labels = labelsIn(rowFor(root, name));
    for (const l of orgoLabels) assert.ok(labels.includes(l), `${name} has ${l}: ${labels}`);
  }
  for (const name of ['hub', 'bw-1']) {
    const labels = labelsIn(rowFor(root, name));
    for (const l of orgoLabels) assert.equal(labels.includes(l), false, `${name} has no ${l}: ${labels}`);
    assert.ok(labels.includes('BACKUP NOW'), `${name} keeps BACKUP NOW`);
  }
  fire(buttonIn(rowFor(root, 'bw-alpha-2'), 'RESIZE'), 'click');
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'orgo_resize_quote');
  assert.equal(calls[0][1].box, 'alpha');
  fire(buttonIn(rowFor(root, 'bw-beta'), 'STOP'), 'click');
  assert.equal(calls[1][0], 'orgo_stop');
  assert.equal(calls[1][1].box, 'beta');
});

test('M2: RESIZE prices first; CONFIRM is live only on the ok quote and sends its exact figure and id', async () => {
  let quote = null;
  const w = world({ quote: () => quote });
  await screen();
  fire(buttonIn(rowFor(root, 'bw-alpha-2'), 'RESIZE'), 'click');
  await flush();
  let d = dialogOf(root);
  assert.ok(d, 'the in-app resize dialog opened');
  assert.equal(byName(d, 'account').value ?? byName(d, 'account').attrs.value, 'acct-fixture', 'the account is the computer\'s own');
  assert.equal(isDisabled(confirmOf(d)), true, 'GET PRICE waits for a spec and a reason');
  type(byName(d, 'vcpus'), '8');
  type(byName(d, 'reason'), 'more room');
  await flush();
  d = dialogOf(root);
  assert.equal(confirmOf(d).textContent.trim(), 'GET PRICE');
  assert.equal(isDisabled(confirmOf(d)), false);
  fire(confirmOf(d), 'click');
  await waitFor(() => w.posted.length === 1 && /pricing/.test((dialogOf(root) || root).textContent), 'the quote POST and the pricing text');
  const q = w.posted[0];
  assert.equal(q.type, 'orgo_resize_quote');
  assert.equal(q.target, 'alpha');
  assert.equal(q.box, 'hub');
  assert.equal(q.vcpus, 8, 'a number, not a string');
  assert.equal(q.account, 'acct-fixture');
  assert.match(dialogOf(root).textContent, /pricing… queued for hub/);
  assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'no CONFIRM while pricing');

  quote = { id: 41, box: 'hub', type: 'orgo_resize_quote', target: 'alpha', status: 'claimed', detail: null, requested_at: ago(0) };
  await flush();
  assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'a claimed quote is not a price');
  quote = { ...quote, status: 'ok', detail: RESIZE_PLAN, finished_at: ago(0) };
  await waitFor(() => /PLAN cost/.test(dialogOf(root).textContent), 'the PLAN cost line', () => dialogOf(root).textContent);
  d = dialogOf(root);
  assert.ok(d.textContent.includes('PLAN cost +$12/mo (now $40/mo, after $52/mo); --apply needs --confirm-monthly-usd 12'), 'the line, verbatim');
  assert.equal(confirmOf(d).textContent.trim(), 'RESIZE');
  assert.equal(isDisabled(confirmOf(d)), false, 'the ok quote enables CONFIRM');
  fire(confirmOf(d), 'click');
  await waitFor(() => w.posted.length === 2, 'the resize POST');
  const r = w.posted[1];
  assert.equal(r.type, 'orgo_resize');
  assert.equal(r.target, 'alpha');
  assert.equal(r.quote_id, 41);
  assert.equal(r.confirm_monthly_usd, '12');
  assert.equal(r.vcpus, 8);
  assert.equal(r.account, 'acct-fixture');
  assert.equal(r.reason, 'more room');
  await flush();
  assert.equal(dialogOf(root), undefined);
  assert.match(root.textContent, /queued for hub/);
});

test('M3: a NEEDS PURCHASE quote shows the line and nothing can be confirmed', async () => {
  let quote = null;
  const w = world({ quote: () => quote });
  const doc = await screen();
  fire(buttonIn(rowFor(root, 'bw-alpha-2'), 'RESIZE'), 'click');
  await flush();
  type(byName(dialogOf(root), 'vcpus'), '8');
  type(byName(dialogOf(root), 'reason'), 'more room');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => w.posted.length === 1, 'the quote POST');
  quote = { id: 41, box: 'hub', type: 'orgo_resize_quote', target: 'alpha', status: 'fail', detail: NEEDS, requested_at: ago(0), finished_at: ago(0) };
  await waitFor(() => /NEEDS PURCHASE/.test(dialogOf(root).textContent), 'the NEEDS PURCHASE line');
  const d = dialogOf(root);
  assert.ok(d.textContent.includes('NEEDS PURCHASE: plan 8c/32gb needs an upgrade on acct-fixture'));
  assert.doesNotMatch(d.textContent, /pricing…/);
  assert.equal(isDisabled(confirmOf(d)), true);
  fire(confirmOf(d), 'click');
  await flush();
  assert.equal(w.posted.length, 1, 'nothing past the quote is posted');
  fire(doc, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(dialogOf(root), undefined, 'Escape closes it');
  assert.equal(w.posted.length, 1);
  assert.match(root.textContent, /NEEDS PURCHASE/, 'the banner carries why');
});

test('M4: a quote that never finishes says "no price yet" and posts nothing more', async () => {
  const w = world({ quote: () => ({ id: 41, box: 'hub', type: 'orgo_resize_quote', target: 'alpha', status: 'requested', detail: null, requested_at: ago(0) }) });
  await screen({ quotePoll: { intervalMs: 1, timeoutMs: 40 } });
  fire(buttonIn(rowFor(root, 'bw-alpha-2'), 'RESIZE'), 'click');
  await flush();
  type(byName(dialogOf(root), 'disk_gb'), '200');
  type(byName(dialogOf(root), 'reason'), 'disk');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => /no price yet/.test((dialogOf(root) || root).textContent), '"no price yet"', () => root.textContent);
  const d = dialogOf(root);
  assert.doesNotMatch(d.textContent, /\$\d/, 'a timeout never says a price');
  assert.equal(isDisabled(confirmOf(d)), true);
  fire(confirmOf(d), 'click');
  await flush();
  assert.equal(w.posted.length, 1, 'only the quote was posted');
});

test('M4b: pollQuote polls every 5 s for at most 180 s, then times out; an abort stops it', async () => {
  let t = 0;
  let lists = 0;
  const sleep = async (ms) => { t += ms; };
  const res = await pollQuote(41, {
    list: async () => { lists += 1; return { commands: [{ id: 41, status: 'requested' }] }; },
    now: () => t, sleep, signal: new AbortController().signal
  });
  assert.equal(res.timeout, true);
  assert.equal(lists, 36, '180 s / 5 s');
  assert.equal(t, 180000);

  const ac = new AbortController();
  let n = 0;
  const aborted = await pollQuote(41, {
    list: async () => { n += 1; if (n === 2) ac.abort(); return { commands: [] }; },
    now: () => 0, sleep: async () => {}, signal: ac.signal
  });
  assert.equal(aborted.aborted, true);
  assert.equal(n, 2, 'no list call after the abort');

  const done = await pollQuote(41, {
    list: async () => ({ commands: [{ id: 40, status: 'ok' }, { id: 41, status: 'ok', detail: RESIZE_PLAN }] }),
    now: () => 0, sleep: async () => {}, signal: new AbortController().signal
  });
  assert.equal(done.row.id, 41);
});

test('M2b: the figure parse is the worker\'s rule, case for case', () => {
  const cases = [
    ['orgo_resize_quote', RESIZE_PLAN, '12'],
    ['orgo_resize_quote', 'COST: resize alpha +$15/mo (now $40) | PLAN cost +$12/mo', '15'],
    ['orgo_resize_quote', 'PLAN cost +$12.50/mo | COST: resize alpha +$15/mo', '12.50'],
    ['orgo_resize_quote', 'box-ops: verb=resize id=alpha result=plan rc=0 | PLAN shrink', '0'],
    ['orgo_resize_quote', null, null],
    ['orgo_launch_quote', 'capacity: pool fits 2 more | box-launch: box=gamma usd_mo=40 smoke=pending', '40'],
    ['orgo_launch_quote', 'capacity: pool fits 2 more | box-launch: box=gamma smoke=pending', null],
    ['orgo_restart', 'PLAN cost +$12/mo', null]
  ];
  for (const [t, d, want] of cases) {
    assert.equal(quoteFigure(t, d), want, `${t} ${d}`);
    assert.equal(quoteFigure(t, d), worker.quoteFigure(t, d), `same as the worker: ${t} ${d}`);
  }
  assert.equal(quoteView({ id: 1, type: 'orgo_resize_quote', status: 'ok', detail: RESIZE_PLAN }).confirmable, true);
  assert.equal(quoteView({ id: 1, type: 'orgo_resize_quote', status: 'fail', detail: 'PLAN cost +$12/mo' }).confirmable, false, 'a fail quote with a cost line is not a price');
  assert.equal(quoteView({ id: 1, type: 'orgo_launch_quote', status: 'ok', detail: 'capacity: pool fits 1' }).confirmable, false, 'no usd_mo, no CONFIRM');
  assert.equal(quoteView({ id: 1, type: 'orgo_resize_quote', status: 'requested', detail: null }).phase, 'pending');
});

test('M5: NEXT: lines render one per <code> block; a fail row tags WAITING, NEEDS PURCHASE or REFUSED', () => {
  const NEXT1 = 'NEXT: lift with bin/jobs-client.sh flag-set paused-alpha off';
  const NEXT2 = 'NEXT: check the box answers before you lift it';
  const rows = [
    { id: 7, box: 'hub', type: 'orgo_stop', target: 'alpha', status: 'ok', detail: `box-ops: verb=stop id=alpha result=ok rc=0 | ${NEXT1} | ${NEXT2}`, requested_at: ago(1) },
    { id: 8, box: 'hub', type: 'orgo_launch', target: 'gamma', status: 'fail', detail: 'box-ops: verb=launch result=waiting rc=4 | WAITING: the fleet.conf PR must merge', requested_at: ago(1) },
    { id: 9, box: 'hub', type: 'orgo_resize', target: 'alpha', status: 'fail', detail: NEEDS, requested_at: ago(1) },
    { id: 10, box: 'hub', type: 'orgo_retire', target: 'beta', status: 'fail', detail: 'refused: BOX_OPS_REPO_ROOT not configured', requested_at: ago(1) },
    { id: 11, box: 'hub', type: 'orgo_restart', target: 'beta', status: 'fail', detail: 'box-ops: verb=restart result=fail rc=1', requested_at: ago(1) }
  ];
  const out = render(h(BoxCommandsSection, { state: { data: shapeBoxCommands({ commands: rows, truncated: false }) }, box: null }));
  const codes = out.match(/<code[^>]*>[^<]*<\/code>/g) || [];
  assert.ok(codes.some((c) => c.endsWith(`>${NEXT1}</code>`)), `NEXT1 in its own code block: ${codes}`);
  assert.ok(codes.some((c) => c.endsWith(`>${NEXT2}</code>`)), 'NEXT2 in its own code block');
  assert.ok(out.includes('box-ops: verb=stop id=alpha result=ok rc=0'), 'the summary line is still shown');
  const rowOf = (id) => out.match(new RegExp(`<tr[^>]*>(?:(?!</tr>).)*?<span>${id}</span>(?:(?!</tr>).)*</tr>`, 's'))[0];
  assert.match(rowOf(8), />WAITING</);
  assert.match(rowOf(9), />NEEDS PURCHASE</);
  assert.match(rowOf(10), />REFUSED</);
  assert.match(rowOf(11), />FAIL</);
  assert.match(rowOf(7), />OK</);
  assert.deepEqual(detailView(rows[0].detail).next, [NEXT1, NEXT2]);
  assert.equal(failTag(rows[0]), null, 'an ok row keeps its status');
});

test('M6: RETIRE with delete needs the box id typed; focus stays on it through the enabling keystroke and a rerender (D39)', async () => {
  const w = world();
  const doc = await screen();
  fire(buttonIn(rowFor(root, 'bw-alpha-2'), 'RETIRE'), 'click');
  await flush();
  let d = dialogOf(root);
  assert.ok(d);
  type(byName(d, 'reason'), 'moved off');
  type(byName(d, 'ip'), '192.0.2.10');
  const del = byName(d, 'delete');
  del.checked = true;
  fire(del, 'change');
  await flush();
  d = dialogOf(root);
  const typed = byName(d, 'confirm_id');
  assert.ok(typed, 'delete asks for the box id');
  assert.equal(isDisabled(confirmOf(d)), true, 'delete without the typed id is blocked');
  typed.focus();
  type(typed, 'alph');
  await flush();
  assert.equal(isDisabled(confirmOf(dialogOf(root))), true);
  type(typed, 'alpha');
  await flush();
  assert.equal(isDisabled(confirmOf(dialogOf(root))), false, 'the typed id enables RETIRE');
  assert.equal(doc.activeElement, typed, 'the enabling keystroke leaves focus on the input');
  mount(h(MachinesScreen, { quotePoll: { intervalMs: 1, timeoutMs: 3000 } }), root);
  await flush();
  assert.equal(doc.activeElement, typed, 'a parent rerender leaves focus on the input');
  assert.equal(byName(dialogOf(root), 'confirm_id'), typed, 'the same field');
  assert.equal(w.posted.length, 0, 'typing sends nothing');
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => w.posted.length === 1, 'the retire POST');
  const p = w.posted[0];
  assert.equal(p.type, 'orgo_retire');
  assert.equal(p.target, 'alpha');
  assert.equal(p.delete, true);
  assert.equal(p.ip, '192.0.2.10');
  assert.equal(p.reason, 'moved off');
});

test('M7: an owner_only answer shows in the warn banner, never as queued', async () => {
  const w = world({ post: () => [403, { error: 'owner_only' }] });
  await screen();
  fire(buttonIn(rowFor(root, 'bw-beta'), 'RESTART'), 'click');
  await flush();
  type(byName(dialogOf(root), 'reason') || all(dialogOf(root)).find((n) => n.localName === 'input'), 'wedged');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => w.posted.length === 1 && /owner_only/.test(root.textContent), 'the owner_only banner', () => root.textContent);
  assert.equal(w.posted[0].type, 'orgo_restart');
  assert.equal(w.posted[0].target, 'beta');
  assert.equal(w.posted[0].account, 'acct-fixture');
  const banner = all(root).find((n) => n.attrs && n.attrs.class === 'banner banner--warn' && /owner_only/.test(n.textContent));
  assert.ok(banner, 'the warn banner');
  assert.doesNotMatch(banner.textContent, /queued/);
});
