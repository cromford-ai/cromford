import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, options, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-6822: /staff/:agent is the agent detail page. The pure half
// (lib/staff-activity.js) is driven directly, AgentDetailView and
// StaffTickView render server-side, and the routed /staff/:agent is mounted in
// a small fake DOM against a stubbed fetch, so OLDER goes through the real
// api.js and the real paging state.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { activityRows, mergePages, heartbeatText, tickHref } = await import('../src/lib/staff-activity.js');
const { AgentDetailView, StaffAgentView, StaffView, KillForm, StaffTickView, StaffTickScreen, StaffAgentScreen } = await import('../src/screens/Staff.js');
const { AgentChat } = await import('../src/screens/staff/agent-chat.js');
const { AgentLearning } = await import('../src/screens/staff/agent-learning.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

// ---------------------------------------------------------------- fixtures
// The shapes worker/jobs/src/routes/staff-activity.js answers.
const NOW = Date.parse('2026-10-10T06:00:00Z');
const isoAgo = (min) => new Date(NOW - min * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const TICKET = 'https://github.com/example-org/cromford/issues/9';
const tick = (id, ts, over = {}) => ({
  kind: 'tick', ts, id, cursor: `${ts}~tick~${id}`, phase: 'done', duration_s: 42, collector_rc: 0, collector_s: 3, model_rc: 0,
  collected: 2, new_items: 1, deferred: 0, model_calls: 1, digested: 0, filed: 1, refused: 0, unsupported: 0, failed: 0, held: 0,
  cost_run_id: `staff-tick:watchman-${id}`, cost: { cost_usd: 0.0123, rows: 1, unpriced: 0 }, ...over
});
const EVENTS = [
  { kind: 'outcome', ts: '2026-10-10T05:00:00Z', id: 3, cursor: '2026-10-10T05:00:00Z~outcome~3', outcome: 'merged', verdict: 'agree', ticket_url: TICKET, finding_id: 11 },
  tick(21, '2026-10-10T04:00:00Z', { phase: 'model', model_rc: 1, cost: null }),
  { kind: 'finding.claimed', ts: '2026-10-10T03:00:00Z', id: 11, cursor: '2026-10-10T03:00:00Z~finding.claimed~11', finding_id: 11, title: 'Token in a log line', status: 'filed', ticket_url: TICKET },
  { kind: 'decision', ts: '2026-10-10T02:00:00Z', id: 5, cursor: '2026-10-10T02:00:00Z~decision~5', class: 'leak', mode: 'ask', recommendation: 'file it', choice: null, chosen_at: null, finding_id: 11 },
  { kind: 'decision', ts: '2026-10-10T01:30:00Z', id: 6, cursor: '2026-10-10T01:30:00Z~decision~6', class: 'other', mode: 'ask', recommendation: 'watch it', choice: 'approve', chosen_at: '2026-10-10T01:40:00Z', finding_id: null },
  tick(20, '2026-10-10T01:00:00Z')
];
const ACTIVITY = { agent: 'watchman', events: EVENTS, next: null, last_tick: { id: 21, started_at: '2026-10-10T04:00:00Z', ended_at: '2026-10-10T04:00:42Z', phase: 'model' }, cost_status: 'ok', as_of: '2026-10-10T06:00:00Z' };
const ROSTER = {
  agents: [
    { name: 'archie', kind: 'overlooker', role: 'overlooker', accountable: 'operator@example.com', autonomy: 'per-class', cap: null, status: null, open_findings: 0, precision: null, spend_usd: null, last_tick_at: null },
    { name: 'clerk', kind: 'staff', role: 'records', accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: 0, precision: null, spend_usd: null, last_tick_at: null },
    { name: 'watchman', kind: 'staff', role: 'security', accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: 1, precision: null, spend_usd: null, last_tick_at: isoAgo(12) }
  ],
  sources: {},
  as_of: '2026-10-10T06:00:00Z'
};
const FINDINGS = {
  agent: 'watchman',
  findings: [{ id: 11, fingerprint: 'b'.repeat(64), agent: 'watchman', title: 'Token in a log line', source_kind: 'alert', source_url: 'https://example.com/alerts/fixture-11', status: 'filed', ticket_url: TICKET, observed_at: '2026-10-10T02:59:00Z', claimed_at: '2026-10-10T03:00:00Z', updated_at: '2026-10-10T03:10:00Z' }],
  truncated: false
};
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const loading = { data: null, error: null, loading: true, reload() {} };
const detail = (over = {}) => render(h(AgentDetailView, { agent: 'watchman', roster: ok(ROSTER), findings: ok(FINDINGS), activity: ok(ACTIVITY), ...over }));
const section = (out, title) => {
  const i = out.indexOf(`>${title}</span>`);
  assert.ok(i >= 0, `section ${title}`);
  const j = out.indexOf('class="section"', i);
  return out.slice(i, j < 0 ? undefined : j);
};
const bodyRows = (out) => ((out.split('<tbody>')[1] || '').split('</tbody>')[0].match(/<tr[\s>]/g) || []).length;
const headers = (out) => [...out.matchAll(/<th\b([^>]*)>([\s\S]*?)<\/th>/g)].map((m) => ({ attrs: m[1], inner: m[2] }));
const labelOf = (inner) => inner.replace(/<[^>]+>/g, '').replace(/[↑↓]/g, '').trim();

// ------------------------------------------------------------ pure helpers
test('C2a: activityRows links every row to its record and keeps the server order', () => {
  assert.equal(activityRows(null), null);
  assert.equal(activityRows({ events: 'x' }), null, 'a body with no events array is a failed read, never empty');
  const res = activityRows(ACTIVITY);
  assert.deepEqual(res.rows.map((r) => r.key), EVENTS.map((e) => `${e.kind}:${e.id}`));
  const by = Object.fromEntries(res.rows.map((r) => [r.key, r]));
  assert.equal(by['tick:21'].href, '/staff/tick/21');
  assert.equal(by['tick:21'].result, 'stopped at model (rc 1)', 'a tick that did not finish never reads ok');
  assert.equal(by['tick:20'].result, 'done');
  assert.equal(by['tick:20'].cost, 0.0123);
  assert.equal(by['tick:21'].cost, null);
  assert.equal(by['finding.claimed:11'].href, '/staff/finding/11');
  assert.equal(by['outcome:3'].href, '/staff/finding/11');
  assert.equal(by['outcome:3'].ext, TICKET);
  assert.equal(by['decision:5'].href, '/staff/finding/11');
  assert.equal(by['decision:6'].href, null, 'a decision with no finding has no link');
  assert.match(by['decision:6'].summary, /watch it/);
  assert.equal(by['decision:6'].result, 'approve');
  assert.equal(by['decision:5'].result, 'no choice yet');
  assert.equal(activityRows({ ...ACTIVITY, events: [{ ...EVENTS[0], ticket_url: 'javascript:alert(1)' }] }).rows[0].ext, null);
  assert.equal(tickHref(7), '/staff/tick/7');
});

test('C2b: mergePages drops duplicates and keeps (ts, kind, id) newest first', () => {
  const first = activityRows({ events: EVENTS.slice(0, 3) }).rows;
  const second = activityRows({ events: EVENTS.slice(2) }).rows;
  const merged = mergePages(first, second);
  assert.deepEqual(merged.map((r) => r.key), EVENTS.map((e) => `${e.kind}:${e.id}`));
  assert.deepEqual(mergePages(second, first).map((r) => r.key), merged.map((r) => r.key));
});

test('C3a: heartbeatText names the age, the absence and the unknown apart', () => {
  assert.equal(heartbeatText(isoAgo(12), NOW), 'last tick 12m ago');
  assert.equal(heartbeatText(isoAgo(0), NOW), 'last tick now');
  assert.equal(heartbeatText(null, NOW), 'no tick recorded yet');
  assert.equal(heartbeatText(undefined, NOW), 'last tick unknown (the roster read did not say)');
  assert.equal(heartbeatText('not a time', NOW), 'last tick unknown (the roster read did not say)');
});

// ------------------------------------------------------------------ views
test('C1: the detail page renders the timeline newest first, and each read state apart', () => {
  const out = detail();
  const act = section(out, 'ACTIVITY');
  assert.equal(bodyRows(act), 6);
  const order = ['/staff/finding/11', '/staff/tick/21'].map((x) => act.indexOf(x));
  assert.ok(order[0] >= 0 && order[0] < order[1], 'the newest row first');
  assert.match(act, /sorts the 6 loaded rows; OLDER loads more/);
  assert.match(section(out, 'OPEN FINDINGS'), /Token in a log line/, 'the findings list stays');
  assert.equal(bodyRows(section(out, 'OPEN FINDINGS')), 1);

  const skel = section(detail({ activity: loading }), 'ACTIVITY');
  assert.match(skel, /class="skel"/);
  const err = section(detail({ activity: failed('activity read failed') }), 'ACTIVITY');
  assert.match(err, /activity read failed/);
  assert.doesNotMatch(err, /no activity recorded yet/, 'a failed read is not the empty state');
  const empty = section(detail({ activity: ok({ ...ACTIVITY, events: [], last_tick: null }) }), 'ACTIVITY');
  assert.match(empty, /no activity recorded yet/);
  const unread = section(detail({ activity: ok({ ...ACTIVITY, cost_status: 'unread' }) }), 'ACTIVITY');
  assert.match(unread, /cost unread/);
  // The BH-5567 call shape (no activity prop) still renders the findings table.
  assert.equal(bodyRows(section(render(h(StaffAgentView, { agent: 'watchman', roster: ok(ROSTER), findings: ok(FINDINGS) })), 'OPEN FINDINGS')), 1);
});

test('C2c: the rendered rows link out: tick, finding, ticket; the facts link the last heartbeat', () => {
  const out = detail();
  const act = section(out, 'ACTIVITY');
  assert.match(act, /<a[^>]*href="\/staff\/tick\/21"/);
  assert.match(act, /<a[^>]*href="\/staff\/finding\/11"/);
  assert.match(act, new RegExp(`<a[^>]*href="${TICKET}"[^>]*target="_blank"`));
  assert.match(act, /stopped at model \(rc 1\)/);
  const facts = out.slice(0, out.indexOf('>ACTIVITY</span>'));
  assert.match(facts, /LAST HEARTBEAT/);
  assert.match(facts, /<a[^>]*href="\/staff\/tick\/21"[^>]*>[\s\S]*?title="2026-10-10T04:00:00Z"/);
  const none = detail({ activity: ok({ ...ACTIVITY, events: [], last_tick: null }) });
  assert.match(none.slice(0, none.indexOf('>ACTIVITY</span>')), /no tick recorded yet/);
});

test('C3b: the roster and the kill modal say the heartbeat reads the flags; the modal shows the agent\'s last tick', () => {
  const roster = render(h(StaffView, { roster: ok(ROSTER), flags: ok({ flags: [] }), onKill() {} }));
  assert.doesNotMatch(roster, /not built yet/);
  assert.doesNotMatch(roster, /stops nothing/);
  assert.match(roster, /reads these flags at the start of every tick/);
  const form = (edit) => render(h(KillForm, { edit: { kind: 'kill', name: 'staff-kill-watchman', who: 'Watchman', nonce: 1, draft: { reason: '' }, ...edit }, serverError: null, onBlocked() {} }));
  const w = form({ beat: { at: isoAgo(12) } });
  assert.doesNotMatch(w, /not built yet|stops nothing/);
  assert.match(w, /reads it at the start of every tick/);
  assert.match(w, /last tick \d+(m|h|d) ago|last tick now/);
  assert.match(form({ beat: { at: null } }), /no tick recorded yet/);
  assert.doesNotMatch(form({ beat: null }), /last tick|no tick recorded/, 'STOP ALL shows no per-agent line');
});

test('C4a: every activity header sorts with aria-sort and a button', () => {
  const ths = headers(section(detail(), 'ACTIVITY'));
  assert.deepEqual(ths.map((t) => labelOf(t.inner)), ['WHEN', 'KIND', 'WHAT', 'RESULT', 'DURATION', 'COST$']);
  for (const t of ths) {
    assert.match(t.attrs, /aria-sort="(ascending|descending|none)"/, labelOf(t.inner));
    assert.match(t.inner, /<button/, labelOf(t.inner));
  }
});

test('C5: the seams render in their fixed spots, each with the agent', () => {
  const seen = [];
  const prev = options.vnode;
  options.vnode = (v) => {
    if (v.type === AgentChat) { seen.push(['chat', v.props.agent]); v.type = () => h('i', null, 'CHAT-MARKER'); }
    if (v.type === AgentLearning) { seen.push(['learning', v.props.agent]); v.type = () => h('i', null, 'LEARNING-MARKER'); }
    if (prev) prev(v);
  };
  let out;
  try {
    out = detail({ autonomySlot: h('i', null, 'AUTONOMY-MARKER') });
  } finally {
    options.vnode = prev;
  }
  assert.deepEqual(seen, [['chat', 'watchman'], ['learning', 'watchman']]);
  const at = (s) => { const i = out.indexOf(s); assert.ok(i >= 0, s); return i; };
  assert.ok(at('LAST HEARTBEAT') < at('CHAT-MARKER'), 'chat sits under the facts');
  assert.ok(at('CHAT-MARKER') < at('AUTONOMY-MARKER'), 'autonomy after chat');
  assert.ok(at('AUTONOMY-MARKER') < at('>ACTIVITY</span>'), 'autonomy before the timeline');
  assert.ok(at('>OPEN FINDINGS</span>') < at('LEARNING-MARKER'), 'learning after the findings');
  // The seams themselves render nothing until their slices land.
  assert.equal(render(h(AgentChat, { agent: 'watchman' })), '');
  assert.equal(render(h(AgentLearning, { agent: 'watchman' })), '');
});

test('C6: /staff/tick/:id maps to StaffTickScreen; the view shows the tick and its sessions', () => {
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/staff/tick/21'), C]).find(([params]) => params);
  assert.equal(hit[1], StaffTickScreen);
  assert.equal(hit[0].id, '21');
  const agentHit = ROUTES.map(([p, C]) => [matchRoute(p, '/staff/watchman'), C]).find(([params]) => params);
  assert.equal(agentHit[1], StaffAgentScreen, '/staff/:agent still reaches the agent page');
  const data = {
    tick: { id: 21, tick_key: 'watchman-20261010t040000z-77', agent: 'watchman', started_at: '2026-10-10T04:00:00Z', ended_at: '2026-10-10T04:00:42Z', duration_s: 42, phase: 'model', collector_rc: 0, collector_s: 3, model_rc: 1, collected: 2, new_items: 1, deferred: 0, model_calls: 1, digested: 0, filed: 0, refused: 0, unsupported: 0, failed: 0, held: 0, cost_run_id: 'staff-tick:watchman-20261010t040000z-77' },
    cost_rows: [{ ts: '2026-10-10T04:00:30Z', stage: 'staff-tick', model: 'stub-model', rc: 1, duration_s: 20, cost_usd: null, session_id: 'sess-fixture-1' }]
  };
  const out = render(h(StaffTickView, { id: '21', tick: ok(data) }));
  assert.match(out, /model/);
  assert.match(out, /COLLECTOR RC/);
  assert.match(out, /sess-fixture-1/);
  assert.match(out, /<a[^>]*href="\/staff\/watchman"/);
  assert.match(out, /unpriced/, 'a null cost is unpriced, never $0');
  for (const t of headers(out)) assert.match(t.attrs, /aria-sort=/, labelOf(t.inner));
  assert.match(render(h(StaffTickView, { id: '99', tick: failed('tick not found') })), /tick not found/);
  assert.match(render(h(StaffTickView, { id: '21', tick: ok({ ...data, cost_rows: [] }) })), /no cost rows/);
});

// ------------------------------------------------------------- fake DOM
class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() { globalThis.document.activeElement = this; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
  querySelectorAll() { return []; }
  querySelector() { return null; }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const fire = (node, type) => {
  const key = Object.keys(node.listeners).find((k) => k.toLowerCase() === type);
  assert.ok(key, `a ${type} listener on <${node.localName}>`);
  return node.listeners[key].call(node, { type: key, target: node, currentTarget: node, button: 0, preventDefault() {} });
};
const activityTable = (root) => {
  const head = all(root).find((n) => /\bsection__title\b/.test(n.attrs.class || '') && n.textContent === 'ACTIVITY');
  return head.parentNode.parentNode;
};
const timelineKeys = (root) => all(activityTable(root)).filter((n) => n.localName === 'tbody')
  .flatMap((tb) => tb.childNodes.filter((tr) => tr.localName === 'tr').map((tr) => tr.textContent));

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

test('C4b: the mounted /staff/watchman reads page one, and OLDER asks for before=<next> and appends without duplicates', async () => {
  const calls = [];
  const page1 = { ...ACTIVITY, events: EVENTS.slice(0, 3), next: EVENTS[2].cursor };
  const page2 = { ...ACTIVITY, events: EVENTS.slice(2), next: null };   // repeats EVENTS[2]
  // The cursor as the server reads it, whatever the URL encoding.
  const beforeOf = (u) => {
    const [path, q] = u.split('?');
    return path === '/api/coord/staff/agent/watchman/activity' && q ? new URLSearchParams(q).get('before') : null;
  };
  globalThis.fetch = async (url) => {
    const u = String(url);
    calls.push(u);
    let body;
    if (u === '/api/coord/staff/roster') body = ROSTER;
    else if (u.startsWith('/api/coord/staff/findings?agent=watchman')) body = FINDINGS;
    else if (u === '/api/coord/staff/agent/watchman/activity') body = page1;
    else if (beforeOf(u) === page1.next) body = page2;
    else return { ok: false, status: 404, text: async () => JSON.stringify({ error: 'unknown endpoint' }) };
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/staff/watchman'), C]).find(([params]) => params);
  const root = doc.createElement('div');
  mount(h(hit[1], hit[0]), root);
  mounted = root;
  await flush();
  assert.ok(calls.includes('/api/coord/staff/agent/watchman/activity'), calls.join(' '));
  assert.equal(timelineKeys(root).length, 3);
  const older = all(root).find((n) => n.localName === 'button' && n.textContent.trim() === 'OLDER');
  assert.ok(older, 'an OLDER button when next is set');
  fire(older, 'click');
  await flush();
  assert.ok(calls.some((u) => beforeOf(u) === page1.next), calls.join(' '));
  assert.equal(timelineKeys(root).length, 6, 'six unique rows, the repeated one once');
  assert.equal(all(root).find((n) => n.localName === 'button' && n.textContent.trim() === 'OLDER'), undefined, 'no OLDER after the last page');
});

test('C4c: a page-one refresh after OLDER keeps the boundary row (a new head event does not drop the last page-one row)', async () => {
  const head = { kind: 'outcome', ts: '2026-10-10T05:30:00Z', id: 4, cursor: '2026-10-10T05:30:00Z~outcome~4', outcome: 'merged', verdict: 'agree', ticket_url: TICKET, finding_id: 11 };
  const page1 = { ...ACTIVITY, events: EVENTS.slice(0, 3), next: EVENTS[2].cursor };
  const page2 = { ...ACTIVITY, events: EVENTS.slice(3), next: null };
  // After the refresh page one holds the new head event, and EVENTS[2] (the
  // boundary row) moved past its limit of 3.
  const page1After = { ...ACTIVITY, events: [head, ...EVENTS.slice(0, 2)], next: EVENTS[1].cursor };
  let served = page1;
  const beforeOf = (u) => {
    const [path, q] = u.split('?');
    return path === '/api/coord/staff/agent/watchman/activity' && q ? new URLSearchParams(q).get('before') : null;
  };
  globalThis.fetch = async (url) => {
    const u = String(url);
    let body;
    if (u === '/api/coord/staff/roster') body = ROSTER;
    else if (u.startsWith('/api/coord/staff/findings?agent=watchman')) body = FINDINGS;
    else if (u === '/api/coord/staff/agent/watchman/activity') body = served;
    else if (beforeOf(u) === page1.next) body = page2;
    else return { ok: false, status: 404, text: async () => JSON.stringify({ error: 'unknown endpoint' }) };
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  // Hold the 60 s refresh timers so the test fires them on demand.
  const realSetTimeout = globalThis.setTimeout;
  const refreshes = [];
  globalThis.setTimeout = (fn, ms, ...a) => {
    if (ms === 60000) { refreshes.push(fn); return 0; }
    return realSetTimeout(fn, ms, ...a);
  };
  try {
    const doc = new FakeNode(9, '#document');
    doc.createElement = (t) => new FakeNode(1, t);
    doc.createElementNS = (_, t) => new FakeNode(1, t);
    doc.createTextNode = (d) => new FakeNode(3, null, d);
    globalThis.document = doc;
    const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/staff/watchman'), C]).find(([params]) => params);
    const root = doc.createElement('div');
    mount(h(hit[1], hit[0]), root);
    mounted = root;
    await flush();
    assert.equal(timelineKeys(root).length, 3);
    fire(all(root).find((n) => n.localName === 'button' && n.textContent.trim() === 'OLDER'), 'click');
    await flush();
    assert.equal(timelineKeys(root).length, 6);
    const boundary = timelineKeys(root).find((t) => t.includes('Token in a log line') && /claimed/i.test(t));
    assert.ok(boundary, 'the boundary row (EVENTS[2], finding claimed) is on screen before the refresh');
    served = page1After;
    assert.ok(refreshes.length > 0, 'a 60 s refresh is scheduled');
    refreshes.splice(0).forEach((fn) => fn());
    await flush();
    const after = timelineKeys(root);
    assert.equal(after.length, 7, `the new head event plus all six earlier rows: ${after.join(' | ')}`);
    assert.ok(after.includes(boundary), 'the boundary row is still rendered after the refresh');
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
});
