import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { bindingsView } from '../src/lib/chat-bindings.js';
import { ChatBindingsView, ChatBindingsPanel } from '../src/screens/hub/ChatBindings.js';
import { flush } from './helpers/settle.js';

// BH-2678 (BH-2521.3): the /hub CHAT BINDINGS panel. The payload is the
// GET /api/telegram-topics answer (worker/jobs/src/routes/telegram-topics.js)
// and every call goes through the real api object over a fake fetch.

const ROWS = [
  { project: 'project-3', thread_id: 7, actor: 'console:a@x', updated_at: '2026-09-26T09:00:00Z' },
  { project: 'cromford', thread_id: 6, actor: null, updated_at: '2026-09-26T08:00:00Z' },
];
const PAYLOAD = { topics: { 'project-3': 7, 'cromford': 6 }, rows: ROWS, as_of: '2026-09-26T09:05:00Z' };
const URL = '/api/coord/telegram-topics';

// One answer per call, in order; the last answer repeats.
function fakeFetch(...answers) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    const [status, body] = answers[Math.min(calls.length - 1, answers.length - 1)];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const noop = () => {};
const viewProps = (over = {}) => ({
  state: 'rows', view: bindingsView(PAYLOAD), error: null, editing: null, draft: '', inline: null,
  busy: false, outcome: null, onEdit: noop, onDraft: noop, onSave: noop, onCancel: noop, onRefresh: noop,
  ...over
});

test('P1: rows render in a sortable table inside .tablewrap; the edit column does not sort', () => {
  const out = render(h(ChatBindingsView, viewProps()));
  assert.match(out, /CHAT BINDINGS/);
  assert.match(out, /class="tablewrap"/);
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"[^>]*>\s*<button[^>]*>\s*([A-Z]+)/g) || [];
  assert.equal(ths.length, 4, `four sortable headers, got ${ths.length}`);
  for (const l of ['PROJECT', 'THREAD', 'ACTOR', 'UPDATED']) assert.ok(ths.some((t) => t.endsWith(l)), l);
  assert.equal((out.match(/<th\b/g) || []).length, 5, 'five columns');
  assert.match(out, /aria-sort="ascending"[^>]*>\s*<button[^>]*>\s*PROJECT\b/);
  // Default sort is project ascending: cromford before project-3.
  assert.ok(out.indexOf('>cromford<') < out.indexOf('>project-3<'), 'sorted by project');
  assert.match(out, /console:a@x/);
  assert.match(out, /<span class="na">—<\/span>/, 'a null actor renders as a dash');
});

test('P2: the project cell links to the project page', () => {
  const out = render(h(ChatBindingsView, viewProps()));
  assert.match(out, /<a href="\/p\/project-3"/);
  assert.match(out, /<a href="\/p\/cromford"/);
});

test('P3: loading, error and empty are three different renders', () => {
  const loading = render(h(ChatBindingsView, viewProps({ state: 'loading', view: null })));
  assert.match(loading, /class="skel"/);
  const err = render(h(ChatBindingsView, viewProps({ state: 'error', view: null, error: new Error('HTTP 502') })));
  assert.match(err, /could not load/);
  assert.match(err, /HTTP 502/);
  assert.match(err, /RETRY/);
  assert.doesNotMatch(err, /No chat bindings yet/);
  const empty = render(h(ChatBindingsView, viewProps({ state: 'empty', view: bindingsView({ rows: [] }) })));
  assert.match(empty, /No chat bindings yet/);
  assert.doesNotMatch(empty, /could not load/);
  const stale = render(h(ChatBindingsView, viewProps({ error: new Error('HTTP 502') })));
  assert.match(stale, /refresh failed: HTTP 502; showing the last answer/);
  assert.match(stale, /project-3/);
});

test('P3: the editing row shows a numeric input, SAVE/CANCEL and the inline refusal', () => {
  const out = render(h(ChatBindingsView, viewProps({ editing: 'project-3', draft: '0', inline: 'thread id must be a positive integer' })));
  assert.match(out, /<input[^>]*inputmode="numeric"[^>]*aria-label="new thread id for project-3"/);
  assert.match(out, />SAVE</);
  assert.match(out, />CANCEL</);
  assert.match(out, /thread id must be a positive integer/);
  assert.equal((out.match(/>EDIT</g) || []).length, 1, 'only the other row keeps its EDIT button');
});

// ---- the real ChatBindingsPanel, mounted and clicked (D2) -------------------
// The FakeNode DOM from restore-lab-panel.bh-1909.test.js, plus oninput so
// preact wires the input's event by its lowercase name.

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
  get onclick() { return null; }
  get onchange() { return null; }
  get oninput() { return null; }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
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
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const button = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const buttons = (root, label) => all(root).filter((n) => n.localName === 'button' && n.textContent.trim() === label);
const dialog = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const type = (el, value) => { el.value = value; el.listeners.input.call(el, { type: 'input', target: el, currentTarget: el }); };
const input = (root) => all(root).find((n) => n.localName === 'input');
// BH-2995: the dialog's REASON field (the row's thread input comes first in tree order).
const reasonInput = (root) => all(dialog(root)).find((n) => n.localName === 'input');
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
// The EDIT button on project-3's row: rows sort cromford, project-3.
const editproject_3 = (root) => buttons(root, 'EDIT')[1];

// Every timer longer than a second is captured instead of armed, so a panel
// that polls can be fast-forwarded past its interval on demand.
function captureLongTimers() {
  const real = globalThis.setTimeout;
  const long = [];
  globalThis.setTimeout = (fn, ms, ...a) => (ms >= 1000 ? (long.push(fn), long.length) : real(fn, ms, ...a));
  return { long, restore: () => { globalThis.setTimeout = real; } };
}

// Every mounted panel is unmounted when its test ends, so a panel that armed
// a timer fails its test instead of holding the runner open.
const mounted = [];
test.afterEach(() => { for (const r of mounted.splice(0)) mount(null, r); });

async function mountPanel(answers) {
  const doc = installDom();
  const calls = fakeFetch(...answers);
  const root = doc.createElement('div');
  mounted.push(root);
  mount(h(ChatBindingsPanel, null), root);
  await flush();
  return { root, calls };
}

test('P3: a 500 load and a payload with no rows render the error state, not empty', async () => {
  const failed = await mountPanel([[500, { error: 'boom' }]]);
  assert.match(failed.root.textContent, /could not load/);
  assert.doesNotMatch(failed.root.textContent, /No chat bindings yet/);
  const noRows = await mountPanel([[200, { topics: {} }]]);
  assert.match(noRows.root.textContent, /bad response/);
  assert.doesNotMatch(noRows.root.textContent, /No chat bindings yet/);
  const empty = await mountPanel([[200, { topics: {}, rows: [] }]]);
  assert.match(empty.root.textContent, /No chat bindings yet/);
});

test('P4: loads once on mount, never polls, and REFRESH loads once more', async (t) => {
  const timers = captureLongTimers();
  t.after(timers.restore);
  const { root, calls } = await mountPanel([[200, PAYLOAD]]);
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', URL]]);
  // Ten minutes pass: every long timer the panel armed fires now.
  for (const fn of timers.long.splice(0)) fn();
  await flush();
  assert.equal(calls.length, 1, 'no polling');
  click(button(root, 'REFRESH'));
  await flush();
  assert.deepEqual(calls.map((c) => c.method), ['GET', 'GET']);
  assert.match(root.textContent, /project-3/);
});

test('P5: EDIT, a new id, SAVE, the in-app dialog, CONFIRM: one PUT and a reload', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD], [200, { topic: { project: 'project-3', thread_id: 12 } }],
    [200, { ...PAYLOAD, rows: [ROWS[1], { ...ROWS[0], thread_id: 12 }] }]]);
  click(editproject_3(root));
  await flush();
  const box = input(root);
  assert.equal(box.attrs['aria-label'], 'new thread id for project-3');
  type(box, ' 12 ');
  await flush();
  click(button(root, 'SAVE'));
  await flush();
  const d = dialog(root);
  assert.ok(d, 'the in-app dialog opened');
  assert.match(d.textContent, /Move project-3 from thread 7 to 12\?/);
  assert.equal(calls.length, 1, 'opening the dialog sends nothing');
  // BH-2995: a required REASON; MOVE is disabled until it holds non-blank text.
  const reason = reasonInput(root);
  assert.ok(reason, 'the dialog holds a REASON input');
  assert.match(d.textContent, /REASON/);
  assert.equal(isDisabled(button(root, 'MOVE')), true, 'MOVE disabled while the reason is blank');
  click(button(root, 'MOVE'));
  await flush();
  type(reason, '  ');
  await flush();
  assert.equal(isDisabled(button(root, 'MOVE')), true, 'a whitespace reason still blocks');
  assert.equal(calls.length, 1, 'a blocked MOVE sends nothing');
  type(reason, ' new topic ');
  await flush();
  assert.equal(isDisabled(button(root, 'MOVE')), false, 'MOVE enabled once the reason is filled');
  click(button(root, 'MOVE'));
  await flush();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', URL], ['PUT', URL], ['GET', URL]]);
  assert.deepEqual(calls[1].body, { project: 'project-3', thread_id: 12, reason: 'new topic' }, 'no actor from the console');
  assert.match(root.textContent, /project-3 now posts to thread 12\./);
  assert.ok(!dialog(root), 'dialog closed');
  assert.ok(!input(root), 'the edit row closed after the move');
});

test('P5: CANCEL on the dialog sends nothing and leaves the row open', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD]]);
  click(editproject_3(root));
  await flush();
  type(input(root), '12');
  await flush();
  click(button(root, 'SAVE'));
  await flush();
  click(buttons(root, 'CANCEL').find((b) => dialog(root) && all(dialog(root)).includes(b)));
  await flush();
  assert.deepEqual(calls.map((c) => c.method), ['GET']);
  assert.ok(!dialog(root));
  assert.ok(input(root), 'still editing');
});

test('P6: an invalid id is refused inline with no dialog and no PUT', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD]]);
  click(editproject_3(root));
  await flush();
  for (const bad of ['0', '6.9', '']) {
    type(input(root), bad);
    await flush();
    click(button(root, 'SAVE'));
    await flush();
    assert.ok(!dialog(root), `no dialog for ${JSON.stringify(bad)}`);
    assert.match(root.textContent, /thread id must be a positive integer/);
  }
  type(input(root), '7');
  await flush();
  click(button(root, 'SAVE'));
  await flush();
  assert.match(root.textContent, /already thread 7/);
  assert.deepEqual(calls.map((c) => c.method), ['GET']);
});

test('P7: no add or delete surface; only GET and PUT are ever sent', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD], [200, { topic: { project: 'project-3', thread_id: 12 } }], [200, PAYLOAD]]);
  const labels = () => all(root).filter((n) => n.localName === 'button').map((b) => b.textContent.trim());
  assert.ok(!labels().some((l) => /ADD|DELETE|REMOVE/i.test(l)), labels().join(','));
  click(editproject_3(root));
  await flush();
  type(input(root), '12');
  await flush();
  click(button(root, 'SAVE'));
  await flush();
  assert.ok(!labels().some((l) => /ADD|DELETE|REMOVE/i.test(l)), labels().join(','));
  type(reasonInput(root), 'why');
  await flush();
  click(button(root, 'MOVE'));
  await flush();
  assert.ok(calls.every((c) => c.method === 'GET' || c.method === 'PUT'), calls.map((c) => c.method).join(','));
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 1);
});
