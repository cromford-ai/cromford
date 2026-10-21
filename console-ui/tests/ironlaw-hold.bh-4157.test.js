import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, all, fire, isDisabled, dialogOf, confirmOf, buttonIn, type } from './helpers/fake-dom.bh-5750.js';

// BH-4157 (slice C0): the IRON-LAW HOLD panel on /pr/:project/:number and its
// coord write row. The pure view is rendered server-side; the real PRScreen
// is mounted into the fake DOM against a stubbed fetch, so the hold read and
// the ACCEPT write go through the real api.js; the proxy row is driven
// through onRequest.
//   K1 the coord row: POST ironlaw-accept, repo/pr/head/reason only, reason
//      required, only an integer pr forwarded, the actor stamped
//   K2 api.ironLawHold's path encodes repo and pr
//   K3 the button only when the hold is iron-law AND on the live head
//   K4 "Accepted" needs a 200 whose accept is the posted head; a 409 shows
//      the worker's error text
//   K5 no hold and no rows renders nothing; a failed read is an ErrorBox

installWindow();
const { render: mount } = await import('preact');
const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { IronLawHoldView, ironLawState, hitNames, acceptBody, acceptNote } = await import('../src/ui/IronLawHold.js');
const { PRScreen } = await import('../src/screens/PR.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');

const REPO = 'example-org/Demo-OS';
const HEAD = 'b'.repeat(8) + '2'.repeat(32);
const OLD = 'a'.repeat(40);
const REASON = 'iron-law: 2 hit(s) on this head: src/ui.js (window.confirm();src/ui.js (window.confirm()';
// The shape GET /api/ironlaw-accept answers (worker/jobs/src/routes/ironlaw-accept.js).
const payload = ({ head = HEAD, ironLaw = true, accepts = [], hold = true } = {}) => ({
  hold: hold ? { head, status: 'hold', reason: REASON, updated_at: '2026-10-19T10:00:00Z' } : null,
  iron_law: hold ? ironLaw : false,
  accepts,
  as_of: '2026-10-19T10:01:00Z'
});
const ACC = { head: OLD, actor: 'ops@x', source: 'console', reason: 'read it, fixture', created_at: '2026-10-18T09:00:00Z' };
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (over = {}) => render(h(IronLawHoldView, {
  state: ok(payload()), liveHead: HEAD, onAccept() {}, busy: false, note: null, ...over
}));

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

// ---------------------------------------------------------------- pure half
test('K0 the pure half: state, hit names, the body, the note', () => {
  assert.equal(ironLawState(null), null);
  assert.equal(ironLawState({ error: 'x' }), null);
  assert.equal(ironLawState({ hold: null, iron_law: false }), null, 'no accepts list is a failed read');
  assert.deepEqual(ironLawState(payload({ hold: false })).accepts, []);
  assert.deepEqual(hitNames(REASON), ['src/ui.js (window.confirm()', 'src/ui.js (window.confirm()']);
  assert.deepEqual(hitNames('iron-law: 3 hit(s) on this head'), []);
  assert.deepEqual(acceptBody({ repo: REPO, pr: '11', head: HEAD, reason: ' looked ' }), { repo: REPO, pr: 11, head: HEAD, reason: 'looked' });
  assert.equal(acceptBody({ repo: REPO, pr: 11, head: HEAD, reason: '   ' }), null);
  assert.equal(acceptBody({ repo: REPO, pr: 11, head: HEAD, reason: 'x'.repeat(501) }), null);
  assert.equal(acceptBody({ repo: REPO, pr: 'x', head: HEAD, reason: 'r' }), null);
  assert.equal(acceptBody({ repo: REPO, pr: 11, head: HEAD.slice(0, 39), reason: 'r' }), null);
  assert.equal(acceptNote({ created: true, accept: { head: HEAD, actor: 'ops@x' } }, HEAD).text,
    'Accepted. The conductor unparks it on its next tick.');
  assert.match(acceptNote({ created: false, accept: { head: HEAD, actor: 'ops@x' } }, HEAD).text, /^Already accepted by ops@x\./);
  assert.equal(acceptNote({ created: true, accept: { head: OLD } }, HEAD), null, 'another head is no claim');
  assert.equal(acceptNote({ ok: true }, HEAD), null, 'no read-back, no claim');
});

// ---------------------------------------------------------------- K3, K5
test('K3 the button only when the hold is iron-law and on the live head', () => {
  const on = view();
  assert.match(on, /section__title">IRON-LAW HOLD</);
  assert.match(on, /<button[^>]*>ACCEPT THIS HEAD<\/button>/);
  assert.match(on, /src\/ui\.js \(window\.confirm\(\)/);
  const older = view({ state: ok(payload({ head: OLD })) });
  assert.doesNotMatch(older, /ACCEPT THIS HEAD/);
  assert.match(older, /the hold is on an older head/);
  const notIron = view({ state: ok(payload({ ironLaw: false })) });
  assert.doesNotMatch(notIron, /ACCEPT THIS HEAD/);
  assert.doesNotMatch(view({ liveHead: null }), /ACCEPT THIS HEAD/, 'no live head, no button');
});

test('K3b the ACCEPT history is a sortable table, newest first', () => {
  const rows = [ACC, { ...ACC, head: HEAD, actor: 'b@x', created_at: '2026-10-19T09:00:00Z' }];
  const out = view({ state: ok(payload({ accepts: rows })) });
  for (const head of ['HEAD', 'BY', 'SOURCE', 'REASON', 'WHEN']) {
    assert.match(out, new RegExp(`<th aria-sort="(none|ascending|descending)"[^>]*>\\s*<button[^>]*>\\s*${head}`), head);
  }
  assert.ok(out.indexOf('b@x') < out.indexOf('ops@x'), 'the newest accept is first');
  assert.match(out, /aria-sort="descending"[^>]*>\s*<button[^>]*>\s*WHEN/);
});

test('K5 no hold and no rows renders nothing; a failed read is an ErrorBox; loading is a skeleton', () => {
  assert.equal(view({ state: ok(payload({ hold: false })) }), '');
  const err = view({ state: { data: null, error: new Error('worker down'), loading: false, reload() {} } });
  assert.match(err, /IRON-LAW HOLD/);
  assert.match(err, /could not load — <b>worker down<\/b>/);
  const loading = view({ state: { data: null, error: null, loading: true, reload() {} } });
  assert.match(loading, /class="skel"/);
  const rowsOnly = view({ state: ok(payload({ hold: false, accepts: [ACC] })) });
  assert.match(rowsOnly, /ops@x/, 'history with no hold still shows');
});

// ---------------------------------------------------------------- K2, K4 (the real PR screen)
test('K2 api.ironLawHold reads through the coord proxy with repo and pr encoded', async () => {
  const calls = routedFetch(() => [200, payload()]);
  await api.ironLawHold(REPO, 11);
  assert.equal(calls[0].url, `/api/coord/ironlaw-accept?repo=${encodeURIComponent(REPO)}&pr=11`);
  assert.equal(calls[0].method, 'GET');
});

function prWorld({ hold = payload(), post = [200, { created: true, accept: { head: HEAD, actor: 'ops@x' } }] } = {}) {
  let held = hold;
  return (u, method, body) => {
    const p = new URL(u, 'https://mc.test').pathname;
    if (p === '/api/dash/pr/demo-os/11') return [200, { html_url: `https://github.com/${REPO}/pull/11`, head_sha: HEAD, builds: [] }];
    if (p === '/api/coord/ironlaw-accept' && method === 'POST') {
      if (post[0] === 200) held = payload({ accepts: [{ ...ACC, head: HEAD, created_at: '2026-10-19T10:02:00Z' }] });
      return post;
    }
    if (p === '/api/coord/ironlaw-accept') return [200, held];
    if (p === '/api/coord/verdicts') return [200, { rows: [], standing: null, truncated: false }];
    return [200, {}];
  };
}
async function mountPR() {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(PRScreen, { project: 'demo-os', number: '11' }), root);
  mounted = root;
  await flush();
  return root;
}
const holdGets = (calls) => calls.filter((c) => c.url.startsWith('/api/coord/ironlaw-accept?') && c.method === 'GET');
const byAria = (root, label) => all(root).find((n) => n.attrs && n.attrs['aria-label'] === label);

test('K4 the real PR screen: ACCEPT asks in the modal, needs a reason, posts the live head, and says Accepted', async () => {
  const calls = routedFetch(prWorld());
  const r = await mountPR();
  await waitFor(() => /ACCEPT THIS HEAD/.test(r.textContent), 'the panel');
  assert.equal(holdGets(calls).length, 1);
  assert.equal(holdGets(calls)[0].url, `/api/coord/ironlaw-accept?repo=${encodeURIComponent(REPO)}&pr=11`);
  fire(buttonIn(r, 'ACCEPT THIS HEAD'), 'click');
  await flush();
  const d = dialogOf(r);
  assert.ok(d, 'an in-app dialog, never a native confirm');
  assert.ok(isDisabled(confirmOf(d)), 'confirm is blocked until a reason is typed');
  type(byAria(d, 'Reason'), '  looked at both lines  ');
  await flush();
  assert.ok(!isDisabled(confirmOf(dialogOf(r))), 'a reason enables confirm');
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => /Accepted\. The conductor unparks it on its next tick\./.test(r.textContent), 'the read-back');
  const posts = calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/ironlaw-accept');
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, { repo: REPO, pr: 11, head: HEAD, reason: 'looked at both lines' });
  await waitFor(() => holdGets(calls).length === 2, 'the panel re-reads after a 200');
});

test('K4b a cancelled dialog posts nothing; a 409 shows the worker error and never says Accepted', async () => {
  let calls = routedFetch(prWorld());
  let r = await mountPR();
  await waitFor(() => /ACCEPT THIS HEAD/.test(r.textContent), 'the panel');
  fire(buttonIn(r, 'ACCEPT THIS HEAD'), 'click');
  await flush();
  fire(buttonIn(dialogOf(r), 'CANCEL'), 'click');
  await flush();
  assert.equal(calls.filter((c) => c.method === 'POST').length, 0);
  mount(null, mounted); mounted = null;

  calls = routedFetch(prWorld({ post: [409, { error: 'the hold is on aaaaaaaa, not bbbbbbbb' }] }));
  r = await mountPR();
  await waitFor(() => /ACCEPT THIS HEAD/.test(r.textContent), 'the panel');
  fire(buttonIn(r, 'ACCEPT THIS HEAD'), 'click');
  await flush();
  type(byAria(dialogOf(r), 'Reason'), 'looked');
  await flush();
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => /the hold is on aaaaaaaa, not bbbbbbbb/.test(r.textContent), 'the refusal');
  assert.doesNotMatch(r.textContent, /Accepted\./);
});

test('K4c a PR with no hold shows no panel', async () => {
  routedFetch(prWorld({ hold: payload({ hold: false }) }));
  const r = await mountPR();
  await waitFor(() => /VERDICTS/.test(r.textContent), 'the page');
  await flush();
  assert.doesNotMatch(r.textContent, /IRON-LAW HOLD/);
});

// ---------------------------------------------------------------- K1
const SECRET = 'fixture-harness-secret';
const CONSOLE = 'https://harness-console.operator.workers.dev';
let seq = 0;
const proxy = (rest, method, body) => onRequest({
  request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
    method, headers: { cookie: `dash=bh4157-${++seq}`, 'content-type': 'application/json' }, body
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: rest.split('/') }
});

test('K1 the coord proxy admits POST ironlaw-accept with repo, pr, head and reason, the actor stamped', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const res = await proxy('ironlaw-accept', 'POST', JSON.stringify({ repo: REPO, pr: 11, head: HEAD, reason: 'looked', actor: 'mallory', extra: 'x' }));
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, 'https://harness-jobs.operator.workers.dev/api/ironlaw-accept');
    const fwd = JSON.parse(seen[0].body);
    assert.deepEqual(Object.keys(fwd).sort(), ['actor', 'head', 'pr', 'reason', 'repo']);
    assert.equal(fwd.pr, 11);
    assert.notEqual(fwd.actor, 'mallory', 'the browser actor is replaced by the stamp');
    assert.equal((await proxy('ironlaw-accept', 'POST', JSON.stringify({ repo: REPO, pr: 11, head: HEAD, reason: '  ' }))).status, 400);
    assert.equal((await proxy('ironlaw-accept', 'PUT', JSON.stringify({ repo: REPO, pr: 11, head: HEAD, reason: 'r' }))).status, 405);
    assert.equal(seen.length, 1, 'a refused write forwards nothing');
    // A string pr is not narrowed to a number here: the row drops it, and the
    // worker answers that body with its own 400 (P1 in the worker suite).
    await proxy('ironlaw-accept', 'POST', JSON.stringify({ repo: REPO, pr: '11', head: HEAD, reason: 'r' }));
    assert.equal(seen.length, 2);
    assert.equal('pr' in JSON.parse(seen[1].body), false, 'a string pr is never forwarded');
  } finally { globalThis.fetch = real; }
});
