import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-6823: talk to a staff agent. One thread per agent, read on its next
// tick. The pure half (lib/staff-chat.js) is driven directly; AgentChatView
// renders server-side; the production AgentChat (the BH-6822 seam) and the
// /chat STAFF tabs (ChatScreen) are mounted in a small fake DOM, against a fake
// api object or a stubbed fetch through the real api.js. The payloads are the
// shapes worker/jobs/src/routes/staff-chat.js answers.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff/quartermaster', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

// A native dialog anywhere in the flow is a failure, never a prompt.
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

const { render } = await import('preact-render-to-string');
const { chatBody, threadRows, noteState, tickHref, STAFF_CHAT_TEXT_MAX } = await import('../src/lib/staff-chat.js');
const { AgentChat, AgentChatView } = await import('../src/screens/staff/agent-chat.js');
const { buildTargets, staffAgentOf, STAFF_PREFIX } = await import('../src/lib/chat.js');
const { ChatScreen } = await import('../src/screens/Chat.js');
const { FleetContext } = await import('../src/app.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');

// ---------------------------------------------------------------- fixtures
const AGENT = 'quartermaster';
const KEY = 'quartermaster:20261015T1715Z';
const msg = (over) => ({
  id: 1, agent: AGENT, role: 'operator', text: 'what did you check last run?', actor: 'operator@example.com',
  state: 'pending', reply_to: null, tick_key: null, tick_id: null, attempts: 0, stopped_by: null,
  created_at: '2026-10-15T17:00:00Z', updated_at: '2026-10-15T17:00:00Z', ...over
});
const reply = (over) => msg({ id: 2, role: 'agent', actor: AGENT, state: 'sent', reply_to: 1, tick_key: KEY, tick_id: 7,
  text: 'I checked 3 lanes and the fly pool.', created_at: '2026-10-15T17:15:40Z', ...over });
const page = (messages, over = {}) => ({ agent: AGENT, messages, next: null, stopped: false, stopped_by: null, as_of: '2026-10-15T17:20:00Z', ...over });
const REPLIED = page([reply(), msg({ state: 'read', tick_key: KEY, attempts: 1 })]);
const ROW = { name: AGENT, kind: 'staff', role: 'inventory', status: 'active' };
const ARCHIE_ROW = { name: 'archie', kind: 'overlooker', role: 'overlooker', status: null };

const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = (m) => ({ data: null, error: new Error(m), loading: false, reload() {} });
const loading = { data: null, error: null, loading: true, reload() {} };
const view = (chat, over = {}) => render(h(AgentChatView, { agent: AGENT, chat, text: '', ...over }));
const visible = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ');

// ------------------------------------------------------------- fake DOM
class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
  }
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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() { globalThis.document.activeElement = this; }
  querySelectorAll() { return []; }
  querySelector() { return null; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  doc.getElementById = () => null;
  globalThis.document = doc;
  return doc;
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const fire = (el, type, extra = {}) => {
  const key = Object.keys(el.listeners).find((k) => k.toLowerCase() === type);
  assert.ok(key, `a ${type} listener on <${el.localName}>`);
  return el.listeners[key].call(el, { type: key, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {}, button: 0, ...extra });
};
const button = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const textBox = (root) => all(root).find((n) => n.localName === 'textarea' && n.attrs['aria-label'] === `message to ${AGENT}`);
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
const text = (root) => root.textContent.replace(/\s+/g, ' ');

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });
async function mountChat(props) {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(AgentChat, { agent: AGENT, row: ROW, ...props }), root);
  mounted = root;
  await flush();
  return root;
}
async function type(root, s) {
  const ta = textBox(root);
  assert.ok(ta, 'the composer textarea');
  ta.value = s;
  fire(ta, 'input');
  await flush();
}
function fakeApi({ head = page([]), send = (b) => ({ message: msg({ id: 9, text: b.text }), stopped: false, stopped_by: null }), older = {} } = {}) {
  const calls = { send: [], read: [] };
  return {
    calls,
    staffChat: async (agent, before) => {
      calls.read.push([agent, before]);
      if (before !== undefined && before !== null) return older[before];
      return typeof head === 'function' ? head() : head;
    },
    staffChatSend: async (b) => {
      calls.send.push(b);
      const a = await send(b);
      if (a instanceof Error) throw a;
      return a;
    }
  };
}

// ------------------------------------------------------------------- V1
test('V1a threadRows: oldest first, each operator note carries its reply; a bad body is null, not an empty thread', () => {
  const rows = threadRows([reply(), msg({ state: 'read', tick_key: KEY }), msg({ id: 3, text: 'and now?', created_at: '2026-10-15T17:30:00Z' })]);
  assert.deepEqual(rows.map((r) => [r.note ? r.note.id : null, r.reply ? r.reply.id : null]), [[1, 2], [3, null]]);
  assert.equal(threadRows(null), null);
  assert.equal(threadRows({}), null);
  assert.deepEqual(threadRows([]), []);
  // A reply whose note is not on a loaded page still shows, on its own.
  const orphan = threadRows([reply({ id: 40, reply_to: 39 })]);
  assert.equal(orphan.length, 1);
  assert.equal(orphan[0].note, null);
  assert.equal(orphan[0].reply.id, 40);
});

test('V1b AgentChatView renders the thread (the note and its reply), the empty state, the skeleton and a failed read distinctly', () => {
  const out = view(ok(REPLIED));
  assert.match(out, />CHAT</);
  assert.match(visible(out), /what did you check last run\?/);
  assert.match(visible(out), /I checked 3 lanes and the fly pool\./);
  assert.ok(out.indexOf('what did you check') < out.indexOf('I checked 3 lanes'), 'the note sits above its reply');
  assert.doesNotMatch(out, /no messages yet/);

  assert.match(view(ok(page([]))), /no messages yet/);

  const bad = view(failed('http_503'));
  assert.match(bad, /could not load/);
  assert.match(bad, /http_503/);
  assert.match(bad, />RETRY</);
  assert.doesNotMatch(bad, /no messages yet/, 'a failed read is not an empty thread');

  const noList = view(ok({ agent: AGENT }));
  assert.match(noList, /could not load/);
  assert.doesNotMatch(noList, /no messages yet/);

  const sk = view(loading);
  assert.match(sk, /class="skel"/);
  assert.doesNotMatch(sk, /no messages yet/);
});

test('V1c AgentChat renders nothing for Archie or a missing row; a staff row gets the CHAT pane', () => {
  assert.equal(render(h(AgentChat, { agent: 'archie', row: ARCHIE_ROW })), '');
  assert.equal(render(h(AgentChat, { agent: AGENT, row: null })), '');
  // The row kind decides, not only the name: a non-staff row gets no thread.
  assert.equal(render(h(AgentChat, { agent: 'scout', row: { name: 'scout', kind: 'overlooker' } })), '');
  assert.equal(render(h(AgentChat, { agent: AGENT })), '');
  const out = render(h(AgentChat, { agent: AGENT, row: ROW, apiObj: fakeApi() }));
  assert.match(out, />CHAT</);
  assert.match(out, /aria-label="message to quartermaster"/);
});

// ------------------------------------------------------------------- V2
test('V2a chatBody: trimmed {agent, text}; blank, over 4000 chars or a bad agent is null', () => {
  assert.deepEqual(chatBody(AGENT, '  hi there '), { agent: AGENT, text: 'hi there' });
  assert.equal(chatBody(AGENT, '   '), null);
  assert.equal(chatBody(AGENT, 'x'.repeat(STAFF_CHAT_TEXT_MAX + 1)), null);
  assert.deepEqual(chatBody(AGENT, 'x'.repeat(STAFF_CHAT_TEXT_MAX)).text.length, STAFF_CHAT_TEXT_MAX);
  assert.equal(chatBody('archie', 'hi'), null);
  assert.equal(chatBody('', 'hi'), null);
  assert.equal(STAFF_CHAT_TEXT_MAX, 4000);
});

test('V2b SEND posts {agent, text} once and shows the note as "waiting for the next tick"; the box clears and the thread reloads', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const apiObj = fakeApi({ send: async (b) => { await gate; return { message: msg({ id: 9, text: b.text }), stopped: false, stopped_by: null }; } });
  const root = await mountChat({ apiObj });
  assert.equal(apiObj.calls.read.length, 1, 'one thread read on mount');
  assert.ok(isDisabled(button(root, 'SEND')), 'SEND is off with an empty box');
  await type(root, '  what did you check last run? ');
  assert.equal(apiObj.calls.send.length, 0, 'typing sends nothing');
  fire(button(root, 'SEND'), 'click');
  await flush();
  // In flight: the note shows as sending, never as stored.
  assert.match(text(root), /what did you check last run\?/);
  assert.match(text(root), /sending/);
  assert.doesNotMatch(text(root), /waiting for the next tick/);
  fire(button(root, 'SENDING') || button(root, 'SEND'), 'click');
  await flush();
  assert.equal(apiObj.calls.send.length, 1, 'a second click while in flight sends nothing');
  release();
  await flush();
  assert.deepEqual(apiObj.calls.send, [{ agent: AGENT, text: 'what did you check last run?' }]);
  assert.match(text(root), /waiting for the next tick/);
  assert.equal(textBox(root).value, '', 'the box clears after a send');
  assert.ok(apiObj.calls.read.length >= 2, 'the thread reloads after a send');
  // The server row replaces the optimistic note: shown once.
  assert.equal(text(root).split('what did you check last run?').length - 1, 1);
});

test('V2c a refused send shows the error inline, keeps the text and leaves no note; a 2xx with no message is "bad response"', async () => {
  const apiObj = fakeApi({ send: () => new Error('agent not found') });
  const root = await mountChat({ apiObj });
  await type(root, 'hello');
  fire(button(root, 'SEND'), 'click');
  await flush();
  assert.equal(apiObj.calls.send.length, 1);
  const bad = all(root).find((n) => /\btag--bad\b/.test(n.attrs.class || ''));
  assert.ok(bad, 'an inline tag--bad line');
  assert.match(bad.textContent, /agent not found/);
  assert.equal(textBox(root).value, 'hello');
  assert.doesNotMatch(text(root), /waiting for the next tick/);
  mount(null, root); mounted = null;

  const api2 = fakeApi({ send: () => ({}) });
  const r2 = await mountChat({ apiObj: api2 });
  await type(r2, 'hello');
  fire(button(r2, 'SEND'), 'click');
  await flush();
  assert.match(text(r2), /bad response/);
  assert.doesNotMatch(text(r2), /waiting for the next tick/);
  assert.equal(textBox(r2).value, 'hello');
});

// ------------------------------------------------------------------- V3
test('V3a a reply shows its text and "answered in tick <key>" linked to /staff/tick/<id>', () => {
  const out = view(ok(REPLIED));
  assert.match(visible(out), new RegExp(`answered in tick ${KEY}`));
  assert.match(out, /href="\/staff\/tick\/7"/);
  // Before the tick row lands: the key as text, no dead link.
  const early = view(ok(page([reply({ tick_id: null }), msg({ state: 'read', tick_key: KEY })])));
  assert.match(visible(early), new RegExp(`answered in tick ${KEY}`));
  assert.doesNotMatch(early, /href="\/staff\/tick\//);
});

test('V3b noteState and tickHref: every state says only what the row proves', () => {
  const s = (note, opts) => { const r = noteState(note, opts); return r.tick ? `${r.text} ${r.tick}` : r.text; };
  assert.equal(s(msg()), 'waiting for the next tick');
  assert.equal(s(msg({ state: 'taken', tick_key: KEY })), `in tick ${KEY} now`);
  assert.equal(s(msg({ state: 'read', tick_key: KEY }), { reply: reply() }), `answered in tick ${KEY}`);
  // "answered" only off a reply row.
  assert.doesNotMatch(s(msg({ state: 'read', tick_key: KEY })), /answered/);
  assert.equal(s(msg({ state: 'unanswered', tick_key: KEY })), `no answer in tick ${KEY}`);
  assert.equal(s(msg({ state: 'failed', attempts: 2 })), 'not answered after 2 tries');
  assert.equal(s(msg({ id: null, state: 'sending', pending: true })), 'sending');
  assert.equal(tickHref(reply()), '/staff/tick/7');
  assert.equal(tickHref(reply({ tick_id: null })), null);
  assert.equal(tickHref(reply({ tick_id: 'x' })), null);
});

// ------------------------------------------------------------------- V4
test('V4a stopped: true shows the "agent stopped" banner with the flag; a held note says agent stopped; a running agent does not', () => {
  const out = view(ok(page([msg()], { stopped: true, stopped_by: 'staff-kill-quartermaster' })));
  assert.match(visible(out), /agent stopped \(staff-kill-quartermaster\)/);
  assert.match(visible(out), /agent stopped: kept, read when it resumes/);
  assert.doesNotMatch(visible(out), /waiting for the next tick/);

  const held = view(ok(page([msg({ state: 'held', stopped_by: 'status paused' })])));
  assert.match(visible(held), /agent stopped: kept, read when it resumes/);
  assert.doesNotMatch(visible(held), /agent stopped \(/, 'no banner when the live check says running');

  const running = view(ok(page([msg()])));
  assert.doesNotMatch(running, /agent stopped/);
});

test('V4b a send to a stopped agent shows "agent stopped" for the new note at once', async () => {
  const apiObj = fakeApi({ send: (b) => ({ message: msg({ id: 9, text: b.text, state: 'held', stopped_by: 'staff-kill-all' }), stopped: true, stopped_by: 'staff-kill-all' }) });
  const root = await mountChat({ apiObj });
  await type(root, 'are you there?');
  fire(button(root, 'SEND'), 'click');
  await flush();
  assert.match(text(root), /agent stopped: kept, read when it resumes/);
  assert.doesNotMatch(text(root), /waiting for the next tick/);
});

test('V4c OLDER asks for before=<next> and adds the older page above, without duplicates', async () => {
  const head = page([msg({ id: 12, text: 'newest note' })], { next: 12 });
  const older = { 12: page([msg({ id: 5, text: 'older note' }), msg({ id: 12, text: 'newest note' })], { next: null }) };
  const apiObj = fakeApi({ head, older });
  const root = await mountChat({ apiObj });
  fire(button(root, 'OLDER'), 'click');
  await flush();
  assert.deepEqual(apiObj.calls.read.find((c) => c[1] !== undefined), [AGENT, 12]);
  const t = text(root);
  assert.ok(t.indexOf('older note') >= 0 && t.indexOf('older note') < t.indexOf('newest note'), t);
  assert.equal(t.split('newest note').length - 1, 1);
  assert.equal(button(root, 'OLDER'), undefined, 'no OLDER after the last page');
});

test('V4d a head re-read after OLDER keeps the boundary row (a new note at the head does not drop the oldest head row)', async () => {
  // Head page of 2 (ids 11, 12); OLDER loads id 5. After the send the head
  // page holds 12 and the new 13, and 11 (the boundary row) moved past it.
  let head = page([msg({ id: 11, text: 'boundary note' }), msg({ id: 12, text: 'newest note' })], { next: 11 });
  const older = { 11: page([msg({ id: 5, text: 'older note' })], { next: null }) };
  const apiObj = fakeApi({
    head: () => head,
    older,
    send: (b) => {
      head = page([msg({ id: 12, text: 'newest note' }), msg({ id: 13, text: b.text })], { next: 12 });
      return { message: msg({ id: 13, text: b.text }), stopped: false, stopped_by: null };
    }
  });
  const root = await mountChat({ apiObj, pollMs: 0 });
  fire(button(root, 'OLDER'), 'click');
  await flush();
  assert.match(text(root), /boundary note/, 'the boundary row is on screen before the send');
  await type(root, 'a new note');
  fire(button(root, 'SEND'), 'click');
  await flush();
  const reads = apiObj.calls.read.filter((c) => c[1] === undefined).length;
  assert.ok(reads >= 2, `the head page was re-read after the send (${reads} reads)`);
  const t = text(root);
  for (const s of ['older note', 'boundary note', 'newest note', 'a new note']) assert.ok(t.includes(s), `${s} still renders: ${t}`);
  assert.ok(t.indexOf('older note') < t.indexOf('boundary note') && t.indexOf('boundary note') < t.indexOf('newest note'), t);
});

// ------------------------------------------------------------------- V5
test('V5a buildTargets lists staff:<agent> targets; one argument is unchanged; Archie and bad names are not targets', () => {
  assert.equal(STAFF_PREFIX, 'staff:');
  const one = buildTargets(['project-4']);
  assert.deepEqual(one.map((t) => t.key), ['orchestrator', 'project-4']);
  assert.equal(one.some((t) => t.kind === 'staff'), false);
  const two = buildTargets(['project-4'], ['quartermaster', 'archie', 'Bad Name', 'quartermaster']);
  assert.deepEqual(two.map((t) => t.key), ['orchestrator', 'project-4', 'staff:quartermaster']);
  const st = two.find((t) => t.key === 'staff:quartermaster');
  assert.equal(st.kind, 'staff');
  assert.equal(st.agent, 'quartermaster');
  assert.equal(st.label, 'STAFF QUARTERMASTER');
  assert.equal(staffAgentOf('staff:quartermaster'), 'quartermaster');
  assert.equal(staffAgentOf('staff:archie'), null);
  assert.equal(staffAgentOf('project-4'), null);
  assert.equal(staffAgentOf('orchestrator'), null);
});

// The routed /chat, mounted against a stubbed fetch: the roster read gives the
// STAFF tab, the tab renders the real AgentChat, and SEND goes out through the
// real api.js as POST /api/coord/staff/chat.
function stubFetch({ roster = { agents: [ARCHIE_ROW, ROW] }, chat = REPLIED } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body });
    let body;
    if (u.startsWith('/api/dash/chat')) body = { messages: [], last_id: 0 };
    else if (u.startsWith('/api/dash/commands')) body = { commands: [] };
    else if (u === '/api/coord/staff/roster') {
      if (roster instanceof Error) return { ok: false, status: 503, text: async () => JSON.stringify({ error: 'down' }) };
      body = roster;
    } else if (u === `/api/coord/staff/chat?agent=${AGENT}`) body = chat;
    else if (u === '/api/coord/staff/chat' && init.method === 'POST') {
      const b = JSON.parse(init.body);
      return { ok: true, status: 201, text: async () => JSON.stringify({ message: msg({ id: 30, text: b.text }), stopped: false, stopped_by: null }) };
    } else return { ok: false, status: 404, text: async () => JSON.stringify({ error: 'unknown endpoint' }) };
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  return calls;
}
async function mountChatScreen() {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(FleetContext.Provider, { value: { data: { projects: ['project-4'], snapshot_age_min: 1 } } }, h(ChatScreen, {})), root);
  mounted = root;
  await flush();
  return root;
}
const tab = (root, label) => all(root).find((n) => n.localName === 'button' && n.attrs.role === 'tab' && n.textContent.trim() === label);

test('V5b /chat lists a STAFF tab per staff agent; the tab renders the agent thread and sends through POST /api/coord/staff/chat', async () => {
  const calls = stubFetch();
  const root = await mountChatScreen();
  assert.ok(tab(root, 'HUB ORCHESTRATOR'));
  assert.ok(tab(root, 'project-4'));
  const st = tab(root, 'STAFF QUARTERMASTER');
  assert.ok(st, `a STAFF QUARTERMASTER tab: ${all(root).filter((n) => n.attrs.role === 'tab').map((n) => n.textContent.trim()).join(', ')}`);
  assert.equal(tab(root, 'STAFF ARCHIE'), undefined, 'Archie has no thread');
  fire(st, 'click');
  await flush();
  assert.ok(calls.some((c) => c.url === `/api/coord/staff/chat?agent=${AGENT}`), calls.map((c) => c.url).join(' '));
  assert.match(text(root), /I checked 3 lanes and the fly pool\./);
  assert.match(text(root), new RegExp(`answered in tick ${KEY}`));
  assert.ok(all(root).some((n) => n.localName === 'a' && n.attrs.href === `/staff/${AGENT}`), 'a link to the agent page');
  // The command composer is not on a staff tab.
  assert.equal(all(root).some((n) => n.localName === 'textarea' && /chat__input/.test(n.attrs.class || '') && !n.attrs['aria-label']), false);
  await type(root, 'what did you check last run?');
  fire(button(root, 'SEND'), 'click');
  await flush();
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1, posts.map((c) => c.url).join(' '));
  assert.equal(posts[0].url, '/api/coord/staff/chat');
  const sent = JSON.parse(posts[0].body);
  assert.equal(sent.agent, AGENT);
  assert.equal(sent.text, 'what did you check last run?');
});

test('V5c a failed roster read means no STAFF tabs and no error banner; the orchestrator tab still works', async () => {
  stubFetch({ roster: new Error('down') });
  const root = await mountChatScreen();
  assert.ok(tab(root, 'HUB ORCHESTRATOR'));
  assert.equal(all(root).some((n) => n.attrs.role === 'tab' && /^STAFF /.test(n.textContent.trim())), false);
  assert.doesNotMatch(text(root), /could not load|chat error/);
});

// ------------------------------------------------------------------- V6
test('V6 375 px: the composer is full width, nothing carries a fixed width over 375 px, long words wrap, SEND is 44 px tall', () => {
  const long = 'x'.repeat(600);
  const out = view(ok(page([reply({ text: long }), msg({ state: 'read', tick_key: KEY, text: long })])), { text: 'draft' });
  const ta = out.match(/<textarea\b[^>]*>/);
  assert.ok(ta, 'a textarea');
  assert.match(ta[0], /width:\s*100%/);
  for (const m of out.matchAll(/(?:^|[;"\s])(?:min-)?width:\s*(\d+)px/g)) assert.ok(Number(m[1]) <= 375, `fixed width ${m[1]}px`);
  assert.doesNotMatch(out, /white-space:\s*nowrap/);
  const items = [...out.matchAll(/<li\b[^>]*>/g)].map((m) => m[0]);
  assert.ok(items.length >= 2, 'the thread is a list');
  for (const li of items) {
    assert.match(li, /overflow-wrap:\s*anywhere/);
    assert.match(li, /max-width:\s*100%/);
  }
  const send = out.match(/<button\b[^>]*>\s*SEND\s*<\/button>/);
  assert.ok(send, 'a SEND button');
  assert.match(send[0], /min-height:\s*44px/);
});

// ----------------------------------------------------------- coord proxy
const SECRET = 'fixture-harness-secret';
function stubProxyFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const call = (rest, method, body, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method, headers: { cookie: `dash=bh6823-${++cookieSeq}`, 'content-type': 'application/json' }, body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('P1 the coord proxy forwards POST staff/chat with agent, text and the stamped actor; take and settle stay 405', async () => {
  const f = stubProxyFetch();
  try {
    const res = await call('staff/chat', 'POST', JSON.stringify({ agent: AGENT, text: 'hi', actor: 'mallory', smuggled: 1 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.match(f.seen[0].url, /\/api\/staff\/chat$/);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.agent, AGENT);
    assert.equal(fwd.text, 'hi');
    assert.notEqual(fwd.actor, 'mallory', 'the browser never sets the actor');
    assert.equal(typeof fwd.actor, 'string');
    assert.equal('smuggled' in fwd, false);
    // A non-string text never travels (the worker then answers 400 on the
    // missing text).
    await call('staff/chat', 'POST', JSON.stringify({ agent: AGENT, text: 5 }));
    assert.equal(f.seen.length, 2);
    assert.equal('text' in JSON.parse(f.seen[1].body), false, 'a number text is dropped');
    for (const rest of ['staff/chat/take', 'staff/chat/settle']) {
      const r = await call(rest, 'POST', JSON.stringify({ agent: AGENT, tick_key: KEY }));
      assert.equal(r.status, 405, rest);
    }
    assert.equal(f.seen.length, 2, 'take and settle forward nothing');
  } finally { f.restore(); }
});
