import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import ContractChangesPanel, { issueHref } from '../src/screens/ContractChangesPanel.js';
import { flush } from './helpers/settle.js';

// BH-9929: the CONTRACT CHANGES section of /p/<project>. Body shape from
// GET /api/contract-changes (worker/jobs): { rows: [{ id, project,
// parent_ticket, step, pr_url, head_sha, classes, backup_ref, restore_ref,
// verdict, approved_by, created_at, updated_at }], limit }. 0 network calls:
// fetch is a stub that answers from the fixture.

const NOW = Date.now();  // determinism: ok every fixture timestamp below is an offset from this one read
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
const URL_ONE = '/api/coord/contract-changes?project=project-6-os';

// ---- a minimal DOM (conflict-hotspots-panel.bh-5267 pattern) ----
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
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
  get onclick() { return null; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byTag = (root, tag) => all(root).filter((n) => n.localName === tag);
const click = (n) => n.listeners.click.call(n, { type: 'click', target: n, currentTarget: n });
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

function fakeDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

// answer(url, n) -> {status, body}; every call is recorded.
async function mountPanel(answer) {
  const doc = fakeDom();
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    const { status = 200, body: b } = answer(String(url), calls.length);
    return { ok: status < 400, status, text: async () => JSON.stringify(b) };
  };
  const root = doc.createElement('div');
  mount(h(ContractChangesPanel, { project: 'project-6-os' }), root);
  mounted.push(root);
  await flush();
  await flush();
  return { root, calls };
}

const PR = (n) => `https://github.com/example-org/project-6/pull/${n}`;
const row = (o) => ({ id: 1, project: 'project-6-os', parent_ticket: 41, step: 'expand', pr_url: PR(101), head_sha: 'abc1234',
  classes: null, backup_ref: null, restore_ref: null, verdict: null, approved_by: null, created_at: iso(300), updated_at: iso(300), ...o });
const THREE = [
  row({ id: 1, step: 'expand', pr_url: PR(101), updated_at: iso(300) }),
  row({ id: 3, step: 'contract', pr_url: PR(103), backup_ref: 'branch mk-pre-41', restore_ref: 'scratch rc 0',
    verdict: 'MERGE', approved_by: 'operator', updated_at: iso(10) }),
  row({ id: 2, step: 'migrate', pr_url: PR(102), updated_at: iso(100) }),
];

test('C1: rows render with step, backup, verdict, approver and links', async () => {
  const { root, calls } = await mountPanel(() => ({ body: { rows: THREE, limit: 100 } }));
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', URL_ONE]], 'one GET');
  const heads = byTag(root, 'th').map((t) => t.textContent.replace(/[↑↓]/g, '').trim());
  assert.deepEqual(heads, ['TICKET', 'STEP', 'PR', 'BACKUP', 'RESTORE', 'VERDICT', 'APPROVED BY', 'UPDATED']);
  const trs = byTag(byTag(root, 'tbody')[0], 'tr');
  assert.equal(trs.length, 3);
  const cells = (tr) => byTag(tr, 'td').map((td) => td.textContent.trim());
  // Default: UPDATED descending, newest first.
  assert.deepEqual(trs.map((tr) => cells(tr)[1]), ['contract', 'migrate', 'expand']);
  assert.deepEqual(cells(trs[0]).slice(1, 7), ['contract', '#103', 'branch mk-pre-41', 'scratch rc 0', 'MERGE', 'operator']);
  assert.equal(cells(trs[1])[5], 'pending', 'an empty verdict reads pending');
  const hrefs = byTag(root, 'a').map((a) => a.attrs.href);
  assert.ok(hrefs.includes('https://github.com/example-org/project-6/issues/41'), hrefs.join(' '));
  assert.ok(hrefs.includes(PR(103)), hrefs.join(' '));
  const wrap = all(root).find((n) => n.attrs && n.attrs.class === 'contract-changes');
  assert.ok(wrap && /overflow-x:\s*auto/.test(wrap.attrs.style || JSON.stringify(wrap.style)), 'the table scrolls inside its own wrapper');
  assert.doesNotMatch(root.textContent, /No contract changes|could not load/);
});

test('C6: the live verdict from the worker shows its source; a recorded one shows the word only', async () => {
  const rows = [
    row({ id: 1, step: 'expand', pr_url: PR(101), verdict: 'MERGE', verdict_source: 'lead', verdict_head: 'a'.repeat(40), updated_at: iso(300) }),
    row({ id: 3, step: 'contract', pr_url: PR(103), verdict: 'MERGE', verdict_source: 'human', verdict_head: 'b'.repeat(40), updated_at: iso(10) }),
    row({ id: 2, step: 'migrate', pr_url: PR(102), verdict: 'pending', verdict_source: 'recorded', updated_at: iso(100) }),
  ];
  const { root } = await mountPanel(() => ({ body: { rows, limit: 100 } }));
  const trs = byTag(byTag(root, 'tbody')[0], 'tr');
  const verdicts = trs.map((tr) => byTag(tr, 'td')[5].textContent.replace(/\s+/g, ' ').trim());
  assert.deepEqual(verdicts, ['MERGE (human)', 'pending', 'MERGE (lead)']);
});

test('C1: issueHref takes the repo from the PR URL; no PR URL is plain text', async () => {
  assert.equal(issueHref({ parent_ticket: 7, pr_url: PR(9) }), 'https://github.com/example-org/project-6/issues/7');
  assert.equal(issueHref({ parent_ticket: 7, pr_url: null }), null);
  assert.equal(issueHref({ parent_ticket: 7, pr_url: 'javascript:alert(1)' }), null);
  assert.equal(issueHref({ parent_ticket: 0, pr_url: PR(9) }), null);
  const { root } = await mountPanel(() => ({ body: { rows: [row({ pr_url: null })], limit: 100 } }));
  assert.equal(byTag(root, 'a').length, 0, 'no link without a repo');
  assert.match(root.textContent, /#41/);
});

test('C2: a header click sorts ascending, a second click descending, with aria-sort', async () => {
  const { root } = await mountPanel(() => ({ body: { rows: THREE, limit: 100 } }));
  const heads = () => byTag(root, 'th');
  const steps = () => byTag(byTag(root, 'tbody')[0], 'tr').map((tr) => byTag(tr, 'td')[1].textContent.trim());
  assert.ok(heads().every((t) => byTag(t, 'button').length === 1), 'every header sorts');
  assert.equal(heads()[7].attrs['aria-sort'], 'descending');
  click(byTag(heads()[1], 'button')[0]);
  await flush();
  assert.equal(heads()[1].attrs['aria-sort'], 'ascending');
  assert.equal(heads()[7].attrs['aria-sort'], 'none');
  assert.deepEqual(steps(), ['contract', 'expand', 'migrate']);
  click(byTag(heads()[1], 'button')[0]);
  await flush();
  assert.equal(heads()[1].attrs['aria-sort'], 'descending');
  assert.deepEqual(steps(), ['migrate', 'expand', 'contract']);
});

test('C3: zero rows is the empty state, not an error', async () => {
  const { root } = await mountPanel(() => ({ body: { rows: [], limit: 100 } }));
  assert.match(root.textContent, /No contract changes on this project\./);
  assert.doesNotMatch(root.textContent, /could not load/);
  assert.equal(byTag(root, 'table').length, 0);
});

for (const [name, answer] of [
  ['a 500', () => ({ status: 500, body: { error: 'boom' } })],
  ['a body without rows', () => ({ body: { limit: 100 } })],
]) {
  test(`C4: ${name} is an ErrorBox with RETRY, never the empty state`, async () => {
    const { root, calls } = await mountPanel(answer);
    assert.match(root.textContent, /could not load/);
    assert.doesNotMatch(root.textContent, /No contract changes/);
    assert.equal(byTag(root, 'table').length, 0);
    const retry = byTag(root, 'button').find((b) => b.textContent.trim() === 'RETRY');
    assert.ok(retry, 'a RETRY button');
    click(retry);
    await flush();
    assert.equal(calls.length, 2, 'RETRY issues a second read');
  });
}

test('C5: the real Project page mounts CONTRACT CHANGES after CONFLICT HOTSPOTS and reads the route once', async () => {
  const doc = fakeDom();
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET' });
    const b = u.startsWith('/api/dash/p/') ? { board: {}, runs: [], builds: [], alerts: [], events: [] }
      : u.startsWith('/api/coord/contract-changes?') ? { rows: THREE, limit: 100 } : {};
    return { ok: true, status: 200, text: async () => JSON.stringify(b) };
  };
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'project-6-os' }), root);
  mounted.push(root);
  await flush();
  await flush();
  const titles = all(root).filter((n) => n.attrs && n.attrs.class === 'section__title').map((n) => n.textContent);
  assert.equal(titles.filter((t) => t === 'CONTRACT CHANGES').length, 1, titles.join(', '));
  assert.equal(titles.indexOf('CONTRACT CHANGES'), titles.indexOf('CONFLICT HOTSPOTS') + 1, titles.join(', '));
  const section = all(root).find((n) => n.attrs && n.attrs.class === 'section__title'
    && n.textContent === 'CONTRACT CHANGES').parentNode.parentNode;
  assert.match(section.textContent, /branch mk-pre-41/);
  assert.deepEqual(calls.filter((c) => /contract-changes/.test(c.url)).map((c) => `${c.method} ${c.url}`), [`GET ${URL_ONE}`]);
});
