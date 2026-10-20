import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, routedFetch, all, fire, dialogOf, buttonIn, buttonsIn, confirmOf } from './helpers/fake-dom.bh-5750.js';

// BH-7267 (BH-7243.4): the wave file console half.
//
// C1 api.roadmapApproveWave / RejectWave / WaveIssues hit the coord proxy paths
// C2 the real App at /roadmap/cromford/wave/w1, draft wave: APPROVE AND
//    FILE opens a visible .modal that names "3 slices" and the repo
// C3 CANCEL closes the modal and posts nothing
// C4 CONFIRM posts the approve exactly once, even when fired again
// C5 the coord write fragment: approve and reject only, actor stamped; the
//    lane-only writes are 405 from a browser
// C6 a filed answer lists every issue link
// C7 approved then filed on the next poll: the links appear, the poll stops
// C8 a load failure renders an error line, not an empty bar

installDom();
window.location.pathname = '/roadmap/cromford/wave/w1';
window.location.search = '';

const { App } = await import('../src/app.js');
const { api } = await import('../src/api.js');
const WA = await import('../src/screens/roadmap/wave-actions.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');
const fragment = (await import('../functions/_lib/coord-writes.d/7243-roadmap-wave-file.js').catch(() => ({}))).default;

const REPO = 'example-org/cromford';
const ISSUES_URL = '/api/coord/roadmap/waves/issues?id=w1&project=cromford';
const wave = (status, extra = {}) => ({ id: 'w1', status, slice_count: 3, repo: REPO, error: null, approved_by: null, approved_at: null, ...extra });
const issues = [11, 12, 13].map((n) => ({ repo: REPO, issue: n, issue_state: n === 13 ? 'closed' : 'open', url: `https://github.com/${REPO}/issues/${n}` }));

const mounted = new Set();
test.afterEach(async () => {
  for (const r of mounted) mount(null, r);
  mounted.clear();
  await flush();
});

// Mount the real App (the production entry point) into a fresh fake DOM.
// `answers` is the queue of waves/issues answers; the last one repeats.
// The approve answer carries no repo: the bar keeps the one the issues read gave.
const APPROVED = { id: 'w1', project: 'cromford', status: 'approved', error: null, approved_by: 'console', approved_at: 't', updated_at: 't', slice_count: 3 };
function mountApp({ answers, approve = [200, { wave: APPROVED }] }) {
  const doc = installDom();
  doc.documentElement = doc.createElement('html');
  doc.querySelector = () => null;
  window.location.pathname = '/roadmap/cromford/wave/w1';
  const queue = [...answers];
  const calls = routedFetch((url, method) => {
    if (url === ISSUES_URL && method === 'GET') return queue.length > 1 ? queue.shift() : queue[0];
    if (url === '/api/coord/roadmap/waves/approve' && method === 'POST') return approve;
    if (url === '/api/coord/roadmap/waves/reject' && method === 'POST') return [200, { wave: wave('rejected') }];
    return [200, {}];
  });
  const root = doc.createElement('div');
  mounted.add(root);
  mount(h(App), root);
  return { root, calls };
}

const posts = (calls) => calls.filter((c) => c.method === 'POST');
const issueGets = (calls) => calls.filter((c) => c.url === ISSUES_URL && c.method === 'GET');
const section = (root) => all(root).find((n) => n.attrs && 'data-wave-actions' in n.attrs);

function visible(node, root) {
  for (let n = node; n; n = n.parentNode) {
    if (n.attrs && 'hidden' in n.attrs) return false;
    const css = `${(n.attrs && n.attrs.style) || ''};${(n.style && n.style.cssText) || ''}`;
    if (/display\s*:\s*none/.test(css) || (n.style && n.style.display === 'none')) return false;
    if (n === root) return true;
  }
  return false; // not attached under root
}

async function openApprove(root) {
  await waitFor(() => buttonIn(root, 'APPROVE AND FILE'), 'APPROVE AND FILE button', () => root.textContent);
  const btn = buttonIn(root, 'APPROVE AND FILE');
  assert.equal(btn.attrs['data-action'], 'approve');
  fire(btn, 'click');
  await waitFor(() => dialogOf(root), 'the approve modal', () => root.textContent);
  return dialogOf(root);
}

test('C1 the three wave calls hit the coord proxy paths', async () => {
  assert.equal(typeof api.roadmapApproveWave, 'function');
  assert.equal(typeof api.roadmapRejectWave, 'function');
  assert.equal(typeof api.roadmapWaveIssues, 'function');
  const calls = routedFetch(() => [200, { ok: true }]);
  await api.roadmapApproveWave({ id: 'w1', project: 'cromford' });
  await api.roadmapRejectWave({ id: 'w1', project: 'cromford', reason: 'too big' });
  await api.roadmapWaveIssues('w1', 'cromford');
  assert.deepEqual(calls, [
    { url: '/api/coord/roadmap/waves/approve', method: 'POST', body: { id: 'w1', project: 'cromford', expected_status: 'draft' } },
    { url: '/api/coord/roadmap/waves/reject', method: 'POST', body: { id: 'w1', project: 'cromford', reason: 'too big' } },
    { url: ISSUES_URL, method: 'GET', body: undefined }
  ]);
});

test('C2 App on a draft wave: APPROVE AND FILE opens a visible modal naming 3 slices and the repo', async () => {
  const { root, calls } = mountApp({ answers: [[200, { wave: wave('draft'), issues: [] }]] });
  const dialog = await openApprove(root);
  const modal = all(root).find((n) => n.attrs && (n.attrs.class || '').split(/\s+/).includes('modal'));
  assert.ok(modal, 'a .modal element exists');
  assert.equal(modal, dialog, 'the .modal is the role=dialog element');
  assert.ok(visible(modal, root), 'the modal is attached under root and not hidden');
  assert.match(modal.textContent, /File this wave\?/);
  assert.match(modal.textContent, /3 slices/);
  assert.match(modal.textContent, /example-org\/cromford/);
  assert.ok(section(root), 'the bar root is section[data-wave-actions]');
  assert.equal(section(root).localName, 'section');
  assert.equal(posts(calls).length, 0, 'opening the modal posts nothing');
});

test('C3 CANCEL closes the modal and posts nothing', async () => {
  const { root, calls } = mountApp({ answers: [[200, { wave: wave('draft'), issues: [] }]] });
  const dialog = await openApprove(root);
  fire(buttonIn(dialog, 'CANCEL'), 'click');
  await flush();
  assert.equal(dialogOf(root), undefined, 'the modal is gone');
  assert.equal(posts(calls).length, 0, 'cancel posts nothing');
  assert.ok(buttonIn(root, 'APPROVE AND FILE'), 'the bar is still there');
});

test('C4 CONFIRM posts the approve exactly once, even when fired again', async () => {
  const { root, calls } = mountApp({ answers: [[200, { wave: wave('draft'), issues: [] }]] });
  const dialog = await openApprove(root);
  const confirm = confirmOf(dialog);
  fire(confirm, 'click');
  fire(confirm, 'click');
  await flush();
  fire(confirm, 'click');
  await flush();
  const p = posts(calls);
  assert.equal(p.length, 1, JSON.stringify(p));
  assert.equal(p[0].url, '/api/coord/roadmap/waves/approve');
  assert.deepEqual(p[0].body, { id: 'w1', project: 'cromford', expected_status: 'draft' });
  await waitFor(() => /Approved\. Filing 3 issues\./.test(root.textContent), 'the approved status line', () => root.textContent);
  assert.equal(buttonIn(root, 'APPROVE AND FILE'), undefined, 'no approve button once approved');
});

test('C4b a 403 approve shows a refusal in the bar and keeps it for a retry', async () => {
  const { root, calls } = mountApp({
    answers: [[200, { wave: wave('draft'), issues: [] }]],
    approve: [403, { error: 'actor archie may not approve' }]
  });
  const dialog = await openApprove(root);
  fire(confirmOf(dialog), 'click');
  await waitFor(() => /refused/.test(section(root).textContent), 'the refusal text', () => root.textContent);
  assert.equal(posts(calls).length, 1);
  assert.ok(buttonIn(root, 'APPROVE AND FILE'), 'the bar stays for a retry');
  assert.doesNotMatch(root.textContent, /NOT SIGNED IN/, 'a refused write does not lock the console');
});

test('C4c a 409 approve shows the error and the wave as it is now', async () => {
  const { root, calls } = mountApp({
    answers: [[200, { wave: wave('draft'), issues: [] }]],
    approve: [409, { error: 'wave is approved, not draft', wave: APPROVED }]
  });
  const dialog = await openApprove(root);
  fire(confirmOf(dialog), 'click');
  await waitFor(() => /wave is approved, not draft/.test(section(root).textContent), 'the 409 text', () => root.textContent);
  assert.match(section(root).textContent, /Approved\. Filing 3 issues\./);
  assert.equal(posts(calls).length, 1);
});

test('C5 the coord fragment: approve and reject only, actor stamped; lane writes are 405', async () => {
  assert.ok(Array.isArray(fragment), 'the fragment exports an array');
  const row = (p) => fragment.find((r) => r.path === p);
  assert.deepEqual({ method: row('roadmap/waves/approve').method, body: row('roadmap/waves/approve').body },
    { method: 'POST', body: ['id', 'project', 'expected_status'] });
  assert.deepEqual({ method: row('roadmap/waves/reject').method, body: row('roadmap/waves/reject').body },
    { method: 'POST', body: ['id', 'project', 'reason'] });
  assert.equal(fragment.length, 2);
  for (const r of fragment) assert.equal(typeof r.ok, 'function');

  const JOBS = 'https://harness-jobs.operator.workers.dev';
  const CONSOLE = 'https://harness-console.operator.workers.dev';
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  let seq = 0;
  const call = (rest, method, body) => onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method, headers: { cookie: `dash=bh7267-${++seq}`, 'content-type': 'application/json' }, body: JSON.stringify(body)
    }),
    env: { HARNESS_SECRET: 'fixture-harness-secret' },
    params: { path: rest.split('/') }
  });
  try {
    let res = await call('roadmap/waves/approve', 'POST', { id: 'w1', project: 'cromford', expected_status: 'draft', actor: 'evil' });
    assert.equal(res.status, 200);
    res = await call('roadmap/waves/reject', 'POST', { id: 'w1', project: 'cromford', reason: 'no', actor: 'evil' });
    assert.equal(res.status, 200);
    assert.equal(seen.length, 2);
    assert.equal(seen[0].url, `${JOBS}/api/roadmap/waves/approve`);
    assert.deepEqual(JSON.parse(seen[0].body), { id: 'w1', project: 'cromford', expected_status: 'draft', actor: 'console' });
    assert.equal(seen[1].url, `${JOBS}/api/roadmap/waves/reject`);
    assert.deepEqual(JSON.parse(seen[1].body), { id: 'w1', project: 'cromford', reason: 'no', actor: 'console' });
    for (const [rest, method] of [['roadmap/waves/file-claim', 'POST'], ['roadmap/waves/filed', 'POST'],
      ['roadmap/waves/file-done', 'POST'], ['roadmap/links/state', 'PUT']]) {
      res = await call(rest, method, { id: 'w1', project: 'cromford' });
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(seen.length, 2, 'a refused write forwards nothing');
  } finally { globalThis.fetch = real; }
});

test('C6 a filed wave lists every issue link', async () => {
  const { root } = mountApp({ answers: [[200, { wave: wave('filed'), issues }]] });
  await waitFor(() => all(root).some((n) => n.attrs && 'data-wave-issues' in n.attrs), 'the issue list', () => root.textContent);
  const list = all(root).find((n) => n.attrs && 'data-wave-issues' in n.attrs);
  assert.equal(list.localName, 'ul');
  const links = all(list).filter((n) => n.localName === 'a');
  assert.deepEqual(links.map((a) => a.attrs.href), [11, 12, 13].map((n) => `https://github.com/${REPO}/issues/${n}`));
  for (const a of links) {
    assert.equal(a.attrs.target, '_blank');
    assert.equal(a.attrs.rel, 'noopener');
    assert.ok(visible(a, root));
  }
  assert.deepEqual(links.map((a) => a.textContent), [11, 12, 13].map((n) => `${REPO}#${n}`));
  assert.match(list.textContent, /closed/);
  assert.equal(buttonsIn(section(root)).length, 0, 'no buttons on a filed wave');
});

test('C7 approved, then filed on the next poll: the links appear and the poll stops', async () => {
  const saved = { ...WA.WAVE_POLL };
  WA.WAVE_POLL.ms = 15;
  try {
    const { root, calls } = mountApp({ answers: [
      [200, { wave: wave('approved', { error: 'gh rate limited' }), issues: [] }],
      [200, { wave: wave('filed'), issues }]
    ] });
    await waitFor(() => /Approved\. Filing 3 issues\./.test(root.textContent), 'the approved status line', () => root.textContent);
    assert.match(root.textContent, /gh rate limited/, 'the wave error is shown');
    await waitFor(() => all(root).filter((n) => n.localName === 'a' && /\/issues\/\d+$/.test(n.attrs.href || '')).length === 3,
      'the 3 issue links', () => root.textContent);
    const n = issueGets(calls).length;
    assert.equal(n, 2, 'one load and one poll');
    await flush(120); // fixed-wait: ok an observation window for "no GET after filed", not a render barrier
    assert.equal(issueGets(calls).length, n, 'no GET after filed');
  } finally { Object.assign(WA.WAVE_POLL, saved); }
});

test('C7b the poll stops after WAVE_POLL.max polls and says so', async () => {
  const saved = { ...WA.WAVE_POLL };
  Object.assign(WA.WAVE_POLL, { ms: 5, max: 3 });
  try {
    const { root, calls } = mountApp({ answers: [[200, { wave: wave('filing'), issues: [] }]] });
    await waitFor(() => /still filing, reload to check/.test(root.textContent), 'the give-up line', () => root.textContent);
    const n = issueGets(calls).length;
    assert.equal(n, 4, 'one load and 3 polls');
    await flush(60); // fixed-wait: ok an observation window for "no poll past WAVE_POLL.max", not a render barrier
    assert.equal(issueGets(calls).length, n);
  } finally { Object.assign(WA.WAVE_POLL, saved); }
});

test('C7c unmounting the screen stops the poll', async () => {
  const saved = { ...WA.WAVE_POLL };
  WA.WAVE_POLL.ms = 15;
  try {
    const { root, calls } = mountApp({ answers: [[200, { wave: wave('approved'), issues: [] }]] });
    await waitFor(() => issueGets(calls).length >= 2, 'one poll', () => root.textContent);
    mount(null, root);
    mounted.delete(root);
    const n = issueGets(calls).length;
    await flush(120); // fixed-wait: ok an observation window for "no GET after unmount", not a render barrier
    assert.equal(issueGets(calls).length, n, 'no GET after unmount');
  } finally { Object.assign(WA.WAVE_POLL, saved); }
});

test('C8 a load failure renders an error line, not an empty bar', async () => {
  const { root } = mountApp({ answers: [[500, { error: 'd1_overloaded' }]] });
  await waitFor(() => section(root) && /could not load/i.test(section(root).textContent), 'the error line', () => root.textContent);
  assert.match(section(root).textContent, /d1_overloaded/);
});

test('C9 REJECT opens a modal with an optional reason and posts it', async () => {
  const { root, calls } = mountApp({ answers: [[200, { wave: wave('draft'), issues: [] }]] });
  await waitFor(() => buttonIn(root, 'REJECT'), 'REJECT button', () => root.textContent);
  assert.equal(buttonIn(root, 'REJECT').attrs['data-action'], 'reject');
  fire(buttonIn(root, 'REJECT'), 'click');
  await waitFor(() => dialogOf(root), 'the reject modal');
  const field = all(dialogOf(root)).find((n) => n.localName === 'textarea');
  assert.ok(field, 'a reason field');
  field.value = 'not now';
  fire(field, 'input');
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => posts(calls).length === 1, 'the reject post');
  assert.deepEqual(posts(calls)[0], { url: '/api/coord/roadmap/waves/reject', method: 'POST', body: { id: 'w1', project: 'cromford', reason: 'not now' } });
  await waitFor(() => /rejected/i.test(section(root).textContent), 'the rejected line', () => root.textContent);
  assert.equal(buttonsIn(section(root)).length, 0);
});
