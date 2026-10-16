import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5567 (BH-5556.10): the /staff screen. The pure half (lib/staff.js) is
// driven directly, the three views are rendered server-side, and the routed
// StaffScreen (the real ROUTES table and matchRoute) is mounted into a small
// fake DOM against a stubbed fetch, so the kill switch's PUT and DELETE go
// through the real api.js and the real lib/flags.js bodies.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const lib = await import('../src/lib/staff.js');
const { displayName, rosterRows, killFlagName, killSetBody, killClearQuery, KILL_ALL, killState, na, findingRows } = lib;
const { setBody, clearQuery } = await import('../src/lib/flags.js');
const { StaffView, StaffAgentView, StaffFindingView, StaffScreen, StaffAgentScreen, StaffFindingScreen } = await import('../src/screens/Staff.js');
const { ROUTES, NAV } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

// ---------------------------------------------------------------- fixtures
// The shape GET /api/staff/roster answers (worker/jobs/src/routes/staff-screen.js).
const STAFF = [
  ['archivist', 'memory', 0], ['clerk', 'records', 1], ['dispatcher', 'health', 0], ['inspector', 'quality', 3],
  ['millwright', 'maintenance', 0], ['quartermaster', 'cost', 0], ['watchman', 'security', 2]
];
const SOURCES = { precision: 'not built: BH-5563 (#5563)', spend: 'not built: BH-5561 (#5561)' };
const ROSTER = {
  agents: [
    { name: 'archie', kind: 'overlooker', role: 'overlooker', accountable: 'operator@example.com', autonomy: 'per-class', cap: null, status: null, open_findings: 0, precision: null, spend_usd: null },
    ...STAFF.map(([name, role, n]) => ({ name, kind: 'staff', role, accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: n, precision: null, spend_usd: null }))
  ],
  sources: SOURCES,
  as_of: '2026-10-10T00:00:00Z'
};
const TICKET = 'https://github.com/example-org/cromford/issues/5567';
const FINDINGS = {
  agent: 'watchman',
  findings: [
    { id: 7, fingerprint: 'b'.repeat(64), agent: 'watchman', title: 'Token in a log line', source_kind: 'alert', source_url: 'https://example.com/alerts/fixture-7', status: 'claimed', ticket_url: null, observed_at: '2026-10-09T03:00:00Z', claimed_at: '2026-10-09T03:01:00Z', updated_at: '2026-10-09T03:01:00Z' },
    { id: 4, fingerprint: 'a'.repeat(64), agent: 'watchman', title: 'Secret in a public repo', source_kind: 'alert', source_url: 'https://example.com/alerts/fixture-4', status: 'filed', ticket_url: TICKET, observed_at: '2026-10-09T02:00:00Z', claimed_at: '2026-10-09T02:01:00Z', updated_at: '2026-10-09T02:30:00Z' }
  ],
  truncated: false,
  as_of: '2026-10-10T00:00:00Z'
};
const FINDING = { finding: { ...FINDINGS.findings[1], source_labels: ['ops', 'fixture'], source_filed_by: null } };
const flagRow = (name, on) => ({ scope: 'fleet', name, value: null, set_by: 'console', reason: 'r', set_at: '2026-10-09T00:00:00Z', cleared_at: on ? null : '2026-10-09T01:00:00Z', active: on ? 1 : 0 });
const FLAGS = { flags: [flagRow('staff-kill-clerk', true), flagRow('staff-kill-watchman', false)], as_of: '2026-10-10T00:00:00Z' };

const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const rosterView = (over = {}) => render(h(StaffView, {
  roster: ok(ROSTER), flags: ok(FLAGS), onKill() {}, busy: false, note: null, dialog: null, ...over
}));
const bodyRows = (out) => {
  const tb = out.split('<tbody>')[1] || '';
  return (tb.split('</tbody>')[0].match(/<tr[\s>]/g) || []).length;
};
const headers = (out) => [...out.matchAll(/<th\b([^>]*)>([\s\S]*?)<\/th>/g)].map((m) => ({ attrs: m[1], inner: m[2] }));
const labelOf = (inner) => inner.replace(/<[^>]+>/g, '').replace(/[↑↓]/g, '').trim();

// ------------------------------------------------------------ pure helpers
test('L1: displayName capitalizes the mill name', () => {
  assert.equal(displayName('quartermaster'), 'Quartermaster');
  assert.equal(displayName('archie'), 'Archie');
  assert.equal(displayName(''), '');
  assert.equal(displayName(null), '');
});

test('L2: rosterRows is null for an unreadable body, never []; it keeps the server order', () => {
  assert.equal(rosterRows(null), null);
  assert.equal(rosterRows({ error: 'x' }), null);
  assert.equal(rosterRows({ agents: {} }), null);
  const r = rosterRows(ROSTER);
  assert.deepEqual(r.rows.map((a) => a.name), ROSTER.agents.map((a) => a.name));
  assert.equal(r.rows[0].display, 'Archie');
  assert.deepEqual(r.sources, SOURCES);
  assert.deepEqual(rosterRows({ agents: [] }).rows, []);
});

test('L3: killFlagName names staff-kill-<agent> and refuses archie, all and junk; the bodies are the Flags bodies', () => {
  assert.equal(killFlagName('watchman'), 'staff-kill-watchman');
  assert.equal(killFlagName(' Watchman '), 'staff-kill-watchman');
  assert.equal(killFlagName('archie'), null);
  assert.equal(killFlagName('all'), null);
  assert.equal(killFlagName('../x'), null);
  assert.equal(killFlagName('A/B'), null);
  assert.equal(killFlagName(''), null);
  assert.equal(killFlagName(undefined), null);
  assert.equal(KILL_ALL, 'staff-kill-all');
  assert.deepEqual(killSetBody('staff-kill-watchman', 'r'), setBody({ name: 'staff-kill-watchman', scope: 'fleet', value: '', reason: 'r' }));
  assert.deepEqual(killSetBody('staff-kill-watchman', 'r'), { name: 'staff-kill-watchman', scope: 'fleet', value: null, active: 1, reason: 'r' });
  assert.equal(killClearQuery('staff-kill-all', 'back'), clearQuery({ name: 'staff-kill-all', scope: 'fleet', reason: 'back' }));
  assert.equal(killSetBody('paused-project-3', 'r'), null, 'a name outside the staff-kill family is refused');
  assert.equal(killClearQuery('lane-off-archie', 'r'), null);
});

test('L4: killState is on, off or unknown; a failed or truncated read is unknown, never off', () => {
  assert.equal(killState(FLAGS, 'staff-kill-clerk'), 'on');
  assert.equal(killState(FLAGS, 'staff-kill-watchman'), 'off', 'a cleared row is off');
  assert.equal(killState(FLAGS, 'staff-kill-inspector'), 'off', 'no row is off');
  assert.equal(killState(null, 'staff-kill-clerk'), 'unknown');
  assert.equal(killState({ error: 'x' }, 'staff-kill-clerk'), 'unknown');
  assert.equal(killState({ ...FLAGS, truncated: true }, 'staff-kill-inspector'), 'unknown');
  assert.equal(killState({ ...FLAGS, truncated: true }, 'staff-kill-clerk'), 'on');
  assert.equal(killState({ flags: [{ ...flagRow('staff-kill-clerk', true), scope: 'boxa' }] }, 'staff-kill-clerk'), 'off', 'a box-scope row is not the fleet flag');
});

test('L5: na renders n/a for absent, and keeps a real zero', () => {
  assert.equal(na(null), 'n/a');
  assert.equal(na(undefined), 'n/a');
  assert.equal(na(0), '0');
  assert.equal(na('x'), 'x');
});

test('L6: findingRows is null for an unreadable body and carries truncated', () => {
  assert.equal(findingRows(null), null);
  assert.equal(findingRows({ findings: 'x' }), null);
  assert.equal(findingRows(FINDINGS).truncated, false);
  assert.equal(findingRows({ ...FINDINGS, truncated: true }).truncated, true);
  assert.deepEqual(findingRows(FINDINGS).rows.map((f) => f.id), [7, 4]);
});

// ------------------------------------------------------------------ views
test('V1: the roster renders 8 rows with mill names, each AGENT cell linking to /staff/<name>', () => {
  const out = rosterView();
  assert.equal(bodyRows(out), 8);
  for (const a of ROSTER.agents) {
    assert.match(out, new RegExp(`<a[^>]*href="/staff/${a.name}"[^>]*>[\\s\\S]*?${displayName(a.name)}`), a.name);
  }
  assert.ok(out.indexOf('Archie') < out.indexOf('Archivist'), 'archie is the first row');
  assert.match(out, /operator@cto\.com/);
  assert.match(out, /overlooker/);
});

test('V2: every roster and findings header except ACTION sorts, with aria-sort', () => {
  const ths = headers(rosterView());
  const labels = ths.map((t) => labelOf(t.inner));
  assert.deepEqual(labels, ['AGENT', 'ROLE', 'ACCOUNTABLE', 'AUTONOMY', 'CAP', 'STATUS', 'OPEN FINDINGS', 'PRECISION', 'SPEND$', 'KILL', 'ACTION']);
  for (const t of ths) {
    const label = labelOf(t.inner);
    if (label === 'ACTION') { assert.doesNotMatch(t.attrs, /aria-sort/); continue; }
    assert.match(t.attrs, /aria-sort="(ascending|descending|none)"/, label);
    assert.match(t.inner, /<button/, label);
  }
  const fths = headers(render(h(StaffAgentView, { agent: 'watchman', roster: ok(ROSTER), findings: ok(FINDINGS) })));
  assert.deepEqual(fths.map((t) => labelOf(t.inner)), ['ID', 'TITLE', 'STATUS', 'SOURCE', 'OBSERVED', 'CLAIMED', 'TICKET']);
  for (const t of fths) {
    assert.match(t.attrs, /aria-sort=/, labelOf(t.inner));
    assert.match(t.inner, /<button/);
  }
});

test('V3: PRECISION and SPEND read n/a with the missing source as the tooltip', () => {
  const out = rosterView();
  assert.equal((out.match(/<span[^>]*title="not built: BH-5563 \(#5563\)"[^>]*>n\/a<\/span>/g) || []).length, 8);
  assert.equal((out.match(/<span[^>]*title="not built: BH-5561 \(#5561\)"[^>]*>n\/a<\/span>/g) || []).length, 8);
  assert.doesNotMatch(out, /\$0\.00/);
});

test('V4: the findings view links ID and TITLE to the detail; the detail links the ticket or says none yet', () => {
  const out = render(h(StaffAgentView, { agent: 'watchman', roster: ok(ROSTER), findings: ok(FINDINGS) }));
  assert.equal(bodyRows(out), 2);
  assert.match(out, /<a[^>]*href="\/staff\/finding\/7"[^>]*>7<\/a>/);
  assert.match(out, /<a[^>]*href="\/staff\/finding\/7"[^>]*>Token in a log line<\/a>/);
  assert.match(out, new RegExp(`<a[^>]*href="${TICKET}"`));
  assert.match(out, /none yet/);
  assert.match(out, /Watchman/);
  assert.match(out, /security/);

  const empty = render(h(StaffAgentView, { agent: 'clerk', roster: ok(ROSTER), findings: ok({ agent: 'clerk', findings: [], truncated: false }) }));
  assert.match(empty, /no open findings/);
  const capped = render(h(StaffAgentView, { agent: 'watchman', roster: ok(ROSTER), findings: ok({ ...FINDINGS, truncated: true }) }));
  assert.match(capped, /capped at 500/);
  const notFound = render(h(StaffAgentView, { agent: 'nobody', roster: ok(ROSTER), findings: failed('agent not found') }));
  assert.match(notFound, /agent not found/);
  assert.doesNotMatch(notFound, /no open findings/, 'a failed read is not the empty state');

  const det = render(h(StaffFindingView, { finding: ok(FINDING) }));
  assert.match(det, new RegExp(`<a[^>]*href="${TICKET}"[^>]*target="_blank"[^>]*rel="noopener"`));
  assert.match(det, /<a[^>]*href="\/staff\/watchman"/);
  assert.match(det, /<a[^>]*href="https:\/\/example\.com\/alerts\/fixture-4"/);
  assert.match(det, /ops, fixture/);
  assert.match(det, new RegExp('a'.repeat(64)));
  const noTicket = render(h(StaffFindingView, { finding: ok({ finding: { ...FINDING.finding, ticket_url: null } }) }));
  assert.match(noTicket, /no ticket filed yet/);
  assert.doesNotMatch(noTicket, /href="null"/);
  const missing = render(h(StaffFindingView, { finding: failed('finding not found') }));
  assert.match(missing, /finding not found/);
});

test('V5: the kill confirm is the in-app Modal; no Staff source calls a native dialog', async () => {
  const { Modal } = await import('../src/ui/Modal.js');
  const out = rosterView({ dialog: h(Modal, { title: 'KILL Watchman', body: 'x', onConfirm() {}, onCancel() {} }) });
  assert.match(out, /role="dialog"/);
  for (const f of ['../src/screens/Staff.js', '../src/lib/staff.js']) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    assert.ok(src.length > 0, f);
    const code = src.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
    assert.doesNotMatch(code, /window\.(confirm|alert|prompt)\s*\(|\b(confirm|alert|prompt)\s*\(/, f);
  }
});

test('V6: the Archie row has no kill button and links to lane-off-archie; staff rows get one each', () => {
  const out = rosterView();
  assert.match(out, /<a[^>]*href="\/config\/flag\/lane-off-archie"[^>]*>lane-off-archie<\/a>/);
  assert.equal((out.match(/>KILL…<\/button>/g) || []).length, 6, 'six staff rows are off');
  assert.equal((out.match(/>RESUME…<\/button>/g) || []).length, 1, 'clerk is on');
  assert.match(out, />STOP ALL STAFF…<\/button>/);
  // TEST-CHANGE (BH-6822): the ticket removes the stale "stops nothing today" text; the heartbeat now reads staff-kill-* flags.
  assert.match(out, /reads these flags at the start of every tick/);
  const odd = { ...ROSTER, agents: [...ROSTER.agents, { ...ROSTER.agents[1], name: 'all' }] };
  const oddOut = rosterView({ roster: ok(odd) });
  assert.equal((oddOut.match(/>KILL…<\/button>/g) || []).length, 6, 'a roster row named all gets no button');
  assert.equal((oddOut.match(/STOP ALL STAFF…/g) || []).length, 1);
});

test('V7: a failed flags read shows KILL unknown and disables every kill button', () => {
  const out = rosterView({ flags: failed('flags read failed') });
  assert.equal((out.match(/>unknown</g) || []).length, 7);
  const btns = [...out.matchAll(/<button([^>]*)>(KILL…|RESUME…|STOP ALL STAFF…|RESUME ALL STAFF…)<\/button>/g)];
  assert.equal(btns.length, 8);
  for (const b of btns) assert.match(b[1], /disabled/, b[2]);
  assert.match(out, /flags read failed/);
  const loading = rosterView({ flags: { data: null, error: null, loading: true, reload() {} } });
  assert.equal((loading.match(/>unknown</g) || []).length, 7);
});

test('V8: ROUTES resolves the three staff paths; the STAFF tab claims them; NAV still ends at /settings', () => {
  const resolve = (path) => ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  const [p1, c1] = resolve('/staff');
  assert.equal(c1, StaffScreen);
  assert.equal(Object.keys(p1).length, 0, '/staff takes no params');
  const [p2, c2] = resolve('/staff/watchman');
  assert.equal(c2, StaffAgentScreen);
  assert.equal(p2.agent, 'watchman');
  const [p3, c3] = resolve('/staff/finding/7');
  assert.equal(c3, StaffFindingScreen);
  assert.equal(p3.id, '7');
  const tabs = (p) => NAV.filter((n) => n.match(p)).map((n) => n.label);
  for (const p of ['/staff', '/staff/watchman', '/staff/finding/7']) assert.deepEqual(tabs(p), ['STAFF'], p);
  assert.deepEqual(tabs('/staffing'), [], 'only /staff and /staff/* are claimed');
  assert.equal(NAV[NAV.length - 1].to, '/settings');
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
const byLabel = (root, label) => all(root).find((n) => (n.localName === 'input') && n.attrs['aria-label'] === label);
const typeInto = (node, v) => { node.value = v; fire(node, 'input'); };
const confirmBtn = (root) => {
  const actions = all(root).find((n) => /\bmodal__actions\b/.test(n.attrs.class || ''));
  return actions && actions.childNodes.filter((n) => n.localName === 'button').pop();
};
const modalOpen = (root) => all(root).some((n) => /\bmodal__body\b/.test(n.attrs.class || ''));
const modalText = (root) => all(root).filter((n) => /\bmodal\b/.test(n.attrs.class || '')).map((n) => n.textContent).join(' ');
const disabled = (n) => n.getAttribute('disabled') !== null && n.getAttribute('disabled') !== 'false';
// The row whose AGENT cell links to /staff/<name>.
const rowOf = (root, name) => all(root).filter((n) => n.localName === 'tr')
  .find((tr) => all(tr).some((a) => a.localName === 'a' && a.attrs.href === `/staff/${name}`));
const killCell = (root, name) => rowOf(root, name).childNodes[9].textContent.trim();

// The flags store in memory: a PUT turns a row on, a DELETE clears it, and
// the next GET answers what the writes left. `write` can refuse.
function stubFetch({ refuse = null } = {}) {
  const calls = [];
  const rows = new Map(FLAGS.flags.map((r) => [r.name, { ...r }]));
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : null });
    let status = 200; let body = { ok: true };
    if (method !== 'GET' && refuse) [status, body] = refuse;
    else if (method === 'PUT' && u === '/api/coord/flags') {
      const b = JSON.parse(init.body);
      rows.set(b.name, { ...flagRow(b.name, true), reason: b.reason });
    } else if (method === 'DELETE' && u.startsWith('/api/coord/flags?')) {
      const q = new URLSearchParams(u.split('?')[1]);
      if (rows.has(q.get('name'))) rows.set(q.get('name'), flagRow(q.get('name'), false));
    } else if (u.startsWith('/api/coord/flags')) body = { flags: [...rows.values()], as_of: '2026-10-10T00:00:00Z' };
    else if (u === '/api/coord/staff/roster') body = ROSTER;
    else { status = 404; body = { error: 'unknown endpoint' }; }
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
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

test('M1: the mounted /staff reads the roster and the staff-kill flags through the coord proxy paths', async () => {
  const calls = stubFetch();
  const c = await mountAt('/staff');
  assert.ok(calls.some((x) => x.method === 'GET' && x.url === '/api/coord/staff/roster'));
  assert.ok(calls.some((x) => x.method === 'GET' && x.url === '/api/coord/flags?prefix=staff-kill-'));
  assert.equal(killCell(c.root, 'clerk'), 'ON');
  assert.equal(killCell(c.root, 'watchman'), 'off');
});

test('M2: KILL… opens the modal, confirm waits for a reason, one PUT writes staff-kill-<agent>, the read-back shows ON; RESUME… clears it', async () => {
  const calls = stubFetch();
  const c = await mountAt('/staff');
  const kill = all(rowOf(c.root, 'watchman')).find((n) => n.localName === 'button' && n.textContent.trim() === 'KILL…');
  assert.ok(kill, 'a KILL… button on the watchman row');
  fire(kill, 'click');
  await flush();
  assert.ok(modalOpen(c.root));
  assert.match(modalText(c.root), /staff-kill-watchman/);
  assert.ok(disabled(confirmBtn(c.root)), 'confirm starts blocked');
  typeInto(byLabel(c.root, 'reason'), 'noisy, fixture');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)));
  fire(confirmBtn(c.root), 'click');
  fire(confirmBtn(c.root), 'click');
  await flush();
  const puts = calls.filter((x) => x.method === 'PUT');
  assert.equal(puts.length, 1, 'a double click writes once');
  assert.equal(puts[0].url, '/api/coord/flags');
  const b = puts[0].body;
  assert.equal(b.name, 'staff-kill-watchman');
  assert.equal(b.scope, 'fleet');
  assert.equal(b.active, 1);
  assert.equal(b.value, null);
  assert.equal(b.reason, 'noisy, fixture');
  assert.ok(!modalOpen(c.root), 'a 2xx closes the modal');
  assert.equal(killCell(c.root, 'watchman'), 'ON', 'the KILL cell shows the read-back row');

  const resume = all(rowOf(c.root, 'watchman')).find((n) => n.localName === 'button' && n.textContent.trim() === 'RESUME…');
  fire(resume, 'click');
  await flush();
  typeInto(byLabel(c.root, 'reason'), 'quiet again');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  const dels = calls.filter((x) => x.method === 'DELETE');
  assert.equal(dels.length, 1);
  assert.equal(dels[0].url, '/api/coord/flags?name=staff-kill-watchman&scope=fleet&reason=quiet+again');
  assert.equal(killCell(c.root, 'watchman'), 'off');
});

test('M3: STOP ALL STAFF… writes staff-kill-all; a refusal stays in the modal with the reason typed', async () => {
  const calls = stubFetch({ refuse: [503, { error: 'HARNESS_SECRET is not set' }] });
  const c = await mountAt('/staff');
  fire(buttons(c.root, 'STOP ALL STAFF…')[0], 'click');
  await flush();
  typeInto(byLabel(c.root, 'reason'), 'stop everything');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  const put = calls.filter((x) => x.method === 'PUT').pop();
  assert.equal(put.body.name, 'staff-kill-all');
  assert.ok(modalOpen(c.root), 'a refusal keeps the modal open');
  assert.match(modalText(c.root), /refused: HARNESS_SECRET is not set/);
  assert.equal(byLabel(c.root, 'reason').value, 'stop everything');
});
