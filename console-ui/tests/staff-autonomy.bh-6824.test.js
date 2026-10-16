import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-6824 (Staff in Mission Control 3/4): the AUTONOMY panel on /staff/:agent.
// The pure half (lib/staff-autonomy.js) is driven directly; the pure view is
// rendered server-side; the routed /staff/quartermaster (the real ROUTES table
// and matchRoute, so StaffAgentScreen mounts AgentAutonomy) is mounted into a
// small fake DOM against a stubbed fetch, so the two writes go through the
// real api.js; and the coord proxy's two new rows are driven through onRequest.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff/quartermaster', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const lib = await import('../src/lib/staff-autonomy.js');
const { autonomyState, levelOptions, autonomyBody, delegationBody, canEditClass, classTarget, delegateBlock, errorText } = lib;
const { AgentAutonomyView } = await import('../src/screens/staff/agent-autonomy.js');
const { StaffAgentView } = await import('../src/screens/Staff.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');
const { onRequest } = await import('../functions/api/coord/[[path]].js');

// ---------------------------------------------------------------- fixtures
// The shape GET /api/staff/autonomy answers (worker/jobs/src/routes/staff-autonomy.js).
const cls = (name, state, cap, effective, streak, prot = false) => ({
  class: name, cap, effective_cap: effective, state, streak, never_delegable: prot,
  protected: prot, display_state: prot ? 'never_delegable' : state
});
const change = (id, kind, klass, from, to, reason) => ({
  id, agent: 'quartermaster', kind, class: klass, from_value: from, to_value: to, actor: 'operator@example.com', reason, created_at: '2026-10-14T10:00:00Z'
});
function serverState() {
  return {
    agent: { name: 'quartermaster', autonomy: 'automation', cap: 'autonomy', status: 'active' },
    levels: ['automation', 'augmentation', 'autonomy'],
    classes: [
      cls('deploy', 'ask_first', 'autonomy', 'autonomy', 0, true),
      cls('rotate-key', 'ask_first', 'autonomy', 'autonomy', 9),
      cls('secret-ticket', 'ask_first', 'augmentation', 'augmentation', 3),
      cls('weekly-note', 'delegated', 'autonomy', 'autonomy', 12)
    ],
    delegate_after: { min: 5, source: 'settings' },
    changes: [change(2, 'delegation', 'weekly-note', 'ask_first', 'delegated', 'twelve agreements')],
    changes_limit: 20, changes_limit_source: 'settings', changes_truncated: false
  };
}
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (over = {}) => render(h(AgentAutonomyView, {
  agent: 'quartermaster', state: ok(serverState()), onEdit() {}, busy: false, note: null, dialog: null, ...over
}));

// ---------------------------------------------------------------- C1, C2
test('C1 autonomyState: a body without classes is a failed read (null); classes [] is the empty state', () => {
  assert.equal(autonomyState(null), null);
  assert.equal(autonomyState({ error: 'agent not found' }), null);
  const s = serverState();
  assert.equal(autonomyState({ ...s, classes: undefined }), null);
  assert.equal(autonomyState({ ...s, changes: undefined }), null);
  const empty = autonomyState({ ...s, classes: [], changes: [] });
  assert.deepEqual(empty.classes, []);
  assert.deepEqual(empty.changes, []);
  assert.equal(empty.agent.autonomy, 'automation');
});

test('C2 levelOptions stop at the cap; a body above the cap, a blank reason or a protected class is never sent', () => {
  assert.deepEqual(levelOptions('automation', 'autonomy'), ['augmentation', 'autonomy']);
  assert.deepEqual(levelOptions('automation', 'augmentation'), ['augmentation']);
  assert.deepEqual(levelOptions('automation', 'automation'), []);
  assert.deepEqual(levelOptions('augmentation', 'augmentation'), ['automation']);
  assert.deepEqual(levelOptions('automation', 'bogus'), []);
  assert.deepEqual(autonomyBody('watchman', 'augmentation', 'augmentation', ' earned '), { agent: 'watchman', autonomy: 'augmentation', reason: 'earned' });
  assert.equal(autonomyBody('watchman', 'autonomy', 'augmentation', 'too far'), null);
  assert.equal(autonomyBody('watchman', 'augmentation', 'augmentation', '   '), null);
  assert.equal(autonomyBody('watchman', 'augmentation', 'augmentation', 'x'.repeat(501)), null);
  assert.equal(autonomyBody('watchman', 'full', 'autonomy', 'r'), null);
  const [deploy, rotate, secret, weekly] = serverState().classes;
  assert.equal(canEditClass(deploy), false);
  assert.equal(delegationBody('quartermaster', deploy, 'try'), null);
  assert.deepEqual(delegationBody('quartermaster', rotate, 'nine in a row'),
    { agent: 'quartermaster', class: 'rotate-key', decision: 'delegate', reason: 'nine in a row' });
  assert.equal(delegationBody('quartermaster', rotate, ''), null);
  assert.equal(delegationBody('quartermaster', secret, 'capped'), null, 'a capped class is not offered for delegation');
  assert.match(delegateBlock(secret), /capped at augmentation/);
  assert.equal(classTarget(weekly), 'ask_first');
  assert.deepEqual(delegationBody('quartermaster', weekly, 'one miss'),
    { agent: 'quartermaster', class: 'weekly-note', decision: 'ask_first', reason: 'one miss' });
  assert.equal(errorText({ error: 'not_earned', streak: 2, min_streak: 5 }), 'refused: needs 5 agreements in a row, has 2.');
  assert.match(errorText({ error: 'never_delegable' }), /never delegable/);
  assert.match(errorText({ error: 'above_cap', autonomy: 'autonomy', cap: 'augmentation' }), /above the cap \(augmentation\)/);
});

// ---------------------------------------------------------------- C3
const rowText = (htmlText, name) => {
  // The class table's row: its CLASS cell (the LAST CHANGES table names classes too).
  const rows = htmlText.split('<tr').filter((r) => r.includes(`class="cell-name">${name}<`));
  assert.equal(rows.length, 1, `one row for ${name}`);
  return rows[0];
};
test('C3 the view: level and cap, the class table with sortable headers and states, the last changes', () => {
  const out = view();
  assert.match(out, /<dt>AUTONOMY<\/dt><dd>automation<\/dd>/);
  assert.match(out, /<dt>CAP<\/dt><dd>autonomy<\/dd>/);
  assert.match(out, /<dt>STATUS<\/dt><dd>active<\/dd>/);
  for (const head of ['CLASS', 'STATE', 'CAP', 'STREAK', 'WHEN', 'KIND', 'FROM', 'TO', 'BY', 'REASON']) {
    assert.match(out, new RegExp(`<th aria-sort="(none|ascending|descending)"[^>]*>\\s*<button[^>]*>\\s*${head}`), head);
  }
  const deploy = rowText(out, 'deploy');
  assert.match(deploy, />never_delegable</);
  assert.match(deploy, /never delegable/);
  assert.doesNotMatch(deploy, /<button/, 'no control on a protected row');
  const secret = rowText(out, 'secret-ticket');
  assert.match(secret, /<button[^>]*disabled[^>]*>DELEGATE…<\/button>/);
  assert.match(secret, /capped at augmentation/);
  const rotate = rowText(out, 'rotate-key');
  assert.match(rotate, />ask_first</);
  assert.match(rotate, /<button[^>]*>DELEGATE…<\/button>/);
  assert.doesNotMatch(rotate, /disabled/);
  const weekly = rowText(out, 'weekly-note');
  assert.match(weekly, />delegated</);
  assert.match(weekly, /ASK FIRST…/);
  assert.match(out, /twelve agreements/);
  assert.match(out, /operator@cto\.com/);
  assert.doesNotMatch(out, /capped at 20/);
  assert.match(view({ state: ok({ ...serverState(), changes_truncated: true }) }), /capped at 20/);
  // CHANGE LEVEL… is there and enabled; at the cap with nothing lower it is disabled.
  assert.match(out, /<button[^>]*>CHANGE LEVEL…<\/button>/);
  assert.doesNotMatch(out.match(/<button[^>]*>CHANGE LEVEL…/)[0], /disabled/);
  const pinned = { ...serverState(), agent: { name: 'quartermaster', autonomy: 'automation', cap: 'automation', status: 'active' } };
  assert.match(view({ state: ok(pinned) }).match(/<button[^>]*>CHANGE LEVEL…/)[0], /disabled/);
  // Loading, a failed read, and the empty state are three different screens.
  const loading = view({ state: { data: null, error: null, loading: true, reload() {} } });
  assert.match(loading, /class="skel"/);
  const failed = view({ state: { data: null, error: new Error('agent not found'), loading: false, reload() {} } });
  assert.match(failed, /could not load/);
  assert.match(failed, /agent not found/);
  assert.doesNotMatch(failed, /no action classes/);
  const empty = view({ state: ok({ ...serverState(), classes: [], changes: [] }) });
  assert.match(empty, /no action classes recorded yet/);
  assert.match(empty, /no changes yet/);
  assert.doesNotMatch(empty, /could not load/);
});

// ---------------------------------------------------------------- C7
test('C7 StaffAgentView renders the AUTONOMY section only when the slot is passed', () => {
  const props = { agent: 'quartermaster', roster: ok({ agents: [], sources: {}, as_of: 't' }), findings: ok({ agent: 'quartermaster', findings: [], truncated: false }) };
  const without = render(h(StaffAgentView, props));
  assert.doesNotMatch(without, /section__title">AUTONOMY</);
  assert.equal(render(h(StaffAgentView, { ...props, autonomySlot: null })), without);
  const withSlot = render(h(StaffAgentView, { ...props, autonomySlot: h('p', { id: 'slot-probe' }, 'probe') }));
  assert.match(withSlot, /section__title">AUTONOMY<\/span>[\s\S]*id="slot-probe"/);
});

// ------------------------------------------------------------- fake DOM
class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const sib = this.parentNode.childNodes;
    return sib[sib.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) {
    this.childNodes.splice(this.childNodes.indexOf(n), 1);
    n.parentNode = null;
    return n;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() { globalThis.document.activeElement = this; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
  // Only the two selectors Modal.js asks for.
  querySelectorAll(sel) {
    const tags = sel.split(',').map((x) => x.trim().split(/\s+/).pop());
    const within = sel.includes('.modal__body') ? all(this).filter((n) => /\bmodal__body\b/.test(n.attrs.class || '')) : [this];
    return within.flatMap((r) => all(r).slice(1)).filter((n) => tags.includes(n.localName));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}
function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  globalThis.document = doc;
  return doc;
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const fire = (node, type, extra = {}) => {
  const key = Object.keys(node.listeners).find((k) => k.toLowerCase() === type);
  assert.ok(key, `a ${type} listener on <${node.localName}>`);
  return node.listeners[key].call(node, { type: key, target: node, currentTarget: node, button: 0, preventDefault() {}, ...extra });
};
const buttons = (root, label) => all(root).filter((n) => n.localName === 'button' && n.textContent.trim() === label);
const byLabel = (root, tag, label) => all(root).find((n) => n.localName === tag && n.attrs['aria-label'] === label);
const typeInto = (node, v) => { node.value = v; fire(node, 'input'); };
const confirmBtn = (root) => {
  const actions = all(root).find((n) => /\bmodal__actions\b/.test(n.attrs.class || ''));
  return actions && actions.childNodes.filter((n) => n.localName === 'button').pop();
};
const modalOpen = (root) => all(root).some((n) => /\bmodal__body\b/.test(n.attrs.class || ''));
const modalText = (root) => all(root).filter((n) => /\bmodal\b/.test(n.attrs.class || '')).map((n) => n.textContent).join(' ');
const disabled = (n) => n.getAttribute('disabled') !== null && n.getAttribute('disabled') !== 'false';
const classRow = (root, name) => all(root).filter((n) => n.localName === 'tr')
  .find((tr) => tr.childNodes[0] && tr.childNodes[0].textContent.trim() === name);
// The AUTONOMY value in the panel's facts block (the second lanekv on the page).
const panelLevel = (root) => {
  const dls = all(root).filter((n) => n.localName === 'dl');
  const dl = dls[dls.length - 1];
  const dts = dl.childNodes.filter((n) => n.localName === 'dt');
  const dt = dts.find((n) => n.textContent.trim() === 'AUTONOMY');
  return dl.childNodes[dl.childNodes.indexOf(dt) + 1].textContent.trim();
};

const ROSTER = {
  agents: [{ name: 'quartermaster', kind: 'staff', role: 'cost', accountable: 'operator@example.com', autonomy: 'automation', cap: 'autonomy', status: 'active', open_findings: 0, precision: null, spend_usd: null }],
  sources: {}, as_of: '2026-10-15T00:00:00Z'
};
// The worker in memory: a write moves the state and adds a change row, and the
// next GET answers what the writes left. `refuse` refuses every write;
// `ignore` answers 200 and changes nothing (the read-back must win).
function stubFetch({ refuse = null, ignore = false } = {}) {
  const calls = [];
  const st = serverState();
  let nextId = 3;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url: u, method, body });
    let status = 200; let out = { ok: true };
    if (method !== 'GET' && refuse) [status, out] = refuse;
    else if (method === 'POST' && u === '/api/coord/staff/agents/autonomy') {
      if (!ignore) {
        st.changes.unshift(change(nextId, 'autonomy', null, st.agent.autonomy, body.autonomy, body.reason));
        st.agent.autonomy = body.autonomy;
      }
      out = { ok: true, change_id: nextId++ };
    } else if (method === 'POST' && u === '/api/coord/staff/classes/delegation') {
      const c = st.classes.find((x) => x.class === body.class);
      const to = body.decision === 'delegate' ? 'delegated' : 'ask_first';
      if (!ignore) {
        st.changes.unshift(change(nextId, 'delegation', c.class, c.state, to, body.reason));
        c.state = to; c.display_state = to;
      }
      out = { ok: true, change_id: nextId++ };
    } else if (u === '/api/coord/staff/autonomy?agent=quartermaster') out = JSON.parse(JSON.stringify(st));
    else if (u === '/api/coord/staff/roster') out = ROSTER;
    else if (u.startsWith('/api/coord/staff/findings?')) out = { agent: 'quartermaster', findings: [], truncated: false, as_of: 't' };
    else { status = 404; out = { error: 'unknown endpoint' }; }
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(out) };
  };
  return calls;
}

let mounted = null;
afterEach(() => { if (mounted) { mounted.unmount(); mounted = null; } });
async function mountAt(path) {
  const doc = installDom();
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  assert.ok(hit, `a route matches ${path}`);
  const root = doc.createElement('div');
  mount(h(hit[1], hit[0]), root);
  await flush();
  mounted = { root, unmount: () => mount(null, root) };
  return mounted;
}

test('C4 mounted /staff/quartermaster: CHANGE LEVEL… lists only levels up to the cap, needs a reason, posts once, shows the read-back', async () => {
  const calls = stubFetch();
  const c = await mountAt('/staff/quartermaster');
  assert.ok(calls.some((x) => x.method === 'GET' && x.url === '/api/coord/staff/autonomy?agent=quartermaster'));
  assert.equal(panelLevel(c.root), 'automation');
  fire(buttons(c.root, 'CHANGE LEVEL…')[0], 'click');
  await flush();
  assert.ok(modalOpen(c.root));
  const select = byLabel(c.root, 'select', 'level');
  assert.ok(select, 'a level select in the modal');
  const opts = all(select).filter((n) => n.localName === 'option').map((n) => n.attrs.value || n.value);
  assert.deepEqual(opts, ['augmentation', 'autonomy']);
  assert.ok(byLabel(c.root, 'input', 'reason'), 'a reason input');
  assert.ok(disabled(confirmBtn(c.root)), 'confirm starts blocked');
  typeInto(byLabel(c.root, 'input', 'reason'), '   ');
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'a blank reason keeps confirm blocked');
  select.value = 'augmentation';
  fire(select, 'change');
  typeInto(byLabel(c.root, 'input', 'reason'), 'trial week');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)));
  fire(confirmBtn(c.root), 'click');
  fire(confirmBtn(c.root), 'click');
  await flush();
  const posts = calls.filter((x) => x.method === 'POST');
  assert.equal(posts.length, 1, 'a double click writes once');
  assert.equal(posts[0].url, '/api/coord/staff/agents/autonomy');
  assert.deepEqual(posts[0].body, { agent: 'quartermaster', autonomy: 'augmentation', reason: 'trial week' });
  assert.ok(!modalOpen(c.root), 'a 2xx closes the modal');
  assert.equal(panelLevel(c.root), 'augmentation', 'the panel shows the re-read level');
  const gets = calls.filter((x) => x.method === 'GET' && x.url === '/api/coord/staff/autonomy?agent=quartermaster');
  assert.ok(gets.length >= 2, 'the panel re-read the GET after the write');
  assert.ok(all(c.root).some((n) => n.localName === 'td' && n.textContent.trim() === 'trial week'), 'LAST CHANGES has the new row');
});

test('C4b a class: DELEGATE… posts the delegation, the STATE column and LAST CHANGES show the read-back; a refusal keeps the modal', async () => {
  const calls = stubFetch();
  const c = await mountAt('/staff/quartermaster');
  const row = classRow(c.root, 'rotate-key');
  fire(all(row).find((n) => n.localName === 'button' && n.textContent.trim() === 'DELEGATE…'), 'click');
  await flush();
  assert.match(modalText(c.root), /rotate-key/);
  assert.equal(byLabel(c.root, 'select', 'level'), undefined, 'a class edit has no level select');
  typeInto(byLabel(c.root, 'input', 'reason'), 'nine in a row');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  const post = calls.filter((x) => x.method === 'POST').pop();
  assert.equal(post.url, '/api/coord/staff/classes/delegation');
  assert.deepEqual(post.body, { agent: 'quartermaster', class: 'rotate-key', decision: 'delegate', reason: 'nine in a row' });
  assert.ok(!modalOpen(c.root));
  assert.equal(classRow(c.root, 'rotate-key').childNodes[1].textContent.trim(), 'delegated');
  assert.ok(all(c.root).some((n) => n.localName === 'td' && n.textContent.trim() === 'nine in a row'));

  mounted.unmount(); mounted = null;
  const refused = stubFetch({ refuse: [409, { error: 'not_earned', streak: 2, min_streak: 5 }] });
  const r = await mountAt('/staff/quartermaster');
  fire(all(classRow(r.root, 'rotate-key')).find((n) => n.localName === 'button' && n.textContent.trim() === 'DELEGATE…'), 'click');
  await flush();
  typeInto(byLabel(r.root, 'input', 'reason'), 'try it');
  await flush();
  fire(confirmBtn(r.root), 'click');
  await flush();
  assert.equal(refused.filter((x) => x.method === 'POST').length, 1);
  assert.ok(modalOpen(r.root), 'a refusal keeps the modal open');
  assert.match(modalText(r.root), /needs 5 agreements in a row, has 2/);
  assert.equal(byLabel(r.root, 'input', 'reason').value, 'try it');
  assert.equal(classRow(r.root, 'rotate-key').childNodes[1].textContent.trim(), 'ask_first');
});

test('C5 read-back, not intent: a 2xx whose GET still says automation shows automation', async () => {
  stubFetch({ ignore: true });
  const c = await mountAt('/staff/quartermaster');
  fire(buttons(c.root, 'CHANGE LEVEL…')[0], 'click');
  await flush();
  const select = byLabel(c.root, 'select', 'level');
  select.value = 'augmentation';
  fire(select, 'change');
  typeInto(byLabel(c.root, 'input', 'reason'), 'trial');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  assert.ok(!modalOpen(c.root));
  assert.equal(panelLevel(c.root), 'automation');
});

// ---------------------------------------------------------------- C6
const CONSOLE = 'https://harness-console.operator.workers.dev';
let seq = 0;
const proxy = (rest, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method: 'POST', headers: { cookie: `dash=bh6824-${++seq}`, 'content-type': 'application/json' }, body: JSON.stringify(body)
    }),
    env: { HARNESS_SECRET: 'fixture-harness-secret' },
    params: { path: rest.split('/') }
  });
test('C6 the coord proxy: both writes need a reason; the actor is stamped and extra fields are dropped', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, body: JSON.parse(init.body) });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    for (const [rest, body] of [
      ['staff/classes/delegation', { agent: 'quartermaster', class: 'rotate-key', decision: 'delegate' }],
      ['staff/agents/autonomy', { agent: 'quartermaster', autonomy: 'augmentation' }]
    ]) {
      for (const reason of [undefined, '', '   ', 7]) {
        const r = await proxy(rest, { ...body, reason });
        assert.equal(r.status, 400, `${rest} reason ${JSON.stringify(reason)}`);
      }
      assert.equal(seen.length, 0, 'a refused write forwards nothing');
      const r = await proxy(rest, { ...body, reason: 'fine', actor: 'evil', extra: 'x' });
      assert.equal(r.status, 200, rest);
      const sent = seen.pop();
      assert.equal(sent.url, `https://harness-jobs.operator.workers.dev/api/${rest}`);
      assert.equal(sent.body.actor, 'console');
      assert.equal(sent.body.reason, 'fine');
      assert.equal(sent.body.extra, undefined);
      for (const k of Object.keys(body)) assert.equal(sent.body[k], body[k], k);
    }
  } finally { globalThis.fetch = real; }
});
