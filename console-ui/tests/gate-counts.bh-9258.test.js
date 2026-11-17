import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { installDom, routedFetch, all, rowsOf } from './helpers/fake-dom.bh-5750.js';
import { flush } from './helpers/settle.js';
import GateCountsPanel, { shareLine } from '../src/screens/GateCountsPanel.js';

// BH-9258 (#9061 Fix 4): the SELECTION GATES TODAY section of /p/<project>.
// Its data is the gates_today of GET /api/coord/pool/status?project=<p>; the
// counts below are the ones the real lane posted
// (tests/fixtures/pool-tick-gate-counts.bh-9258/post.json, pinned by
// tests/pool-tick-gate-counts.bh-9258-test.sh P1 and round-tripped through the
// worker by worker/jobs/test/pool-tick-gates.bh-9258.test.js W1).
//   U1 the five numbers render as table-cell text under their header labels
//   U2 gates_today null (a project with no pool row) renders nothing
//   U3 before the answer: a skeleton inside the section; a failed read: an error box
//   U4 the headers are sortable (aria-sort); the share line
//   U5 the real Project page mounts the section and makes exactly one pool GET

const POSTED = JSON.parse(readFileSync(new URL('../../tests/fixtures/pool-tick-gate-counts.bh-9258/post.json', import.meta.url), 'utf8'));
const GATES = POSTED.rows.find((r) => r.project === 'p').gates_today;
const URL_P = '/api/coord/pool/status?project=cromford';
const answer = (o) => ({ project: 'cromford', version: 1, reported_at: '2026-11-08T12:00:00Z', tick: null, ...o });
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

async function mountPanel(route) {
  const doc = installDom();
  const calls = routedFetch(route);
  const root = doc.createElement('div');
  mount(h(GateCountsPanel, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  await flush();
  return { root, calls };
}
const titleOf = (root) => all(root).filter((n) => n.attrs && n.attrs.class === 'section__title').map((n) => n.textContent);
const cells = (tr) => all(tr).filter((n) => n.localName === 'td').map((n) => n.textContent.trim());
const heads = (root) => all(root).filter((n) => n.localName === 'th');

test('U1 the five numbers are table-cell text under their header labels', async () => {
  const { root, calls } = await mountPanel(() => [200, answer({ gates_today: GATES })]);
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), [`GET ${URL_P}`]);
  assert.deepEqual(titleOf(root), ['SELECTION GATES TODAY']);
  const labels = heads(root).map((n) => n.textContent.replace(/[▲▼↕\s]+$/u, '').trim());
  for (const l of ['DAY', 'GATES', 'RC 0', 'RED (ATTRIBUTED)', 'RED (UNATTRIBUTED)', 'COULD NOT RUN']) {
    assert.ok(labels.some((x) => x.startsWith(l)), `${l} in ${labels.join('|')}`);
  }
  const body = rowsOf(root).filter((tr) => cells(tr).length);
  assert.equal(body.length, 1);
  assert.deepEqual(cells(body[0]), ['2026-11-08', '4', '1', '1', '1', '1']);
});

test('U2 gates_today null, or absent (no pool row), renders nothing', async () => {
  for (const a of [answer({ gates_today: null }), answer({ reason: 'no summary row' })]) {
    const { root } = await mountPanel(() => [200, a]);
    assert.equal(root.textContent, '', JSON.stringify(a));
    assert.deepEqual(titleOf(root), []);
  }
});

test('U3 a skeleton before the answer; an error box on a failed read', async () => {
  const doc = installDom();
  globalThis.fetch = () => new Promise(() => {});
  const root = doc.createElement('div');
  mount(h(GateCountsPanel, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  assert.ok(all(root).some((n) => n.attrs && n.attrs.class === 'skel'), 'a skeleton while loading');
  assert.deepEqual(titleOf(root), ['SELECTION GATES TODAY']);
  const { root: r2 } = await mountPanel(() => [500, { error: 'boom' }]);
  assert.deepEqual(titleOf(r2), ['SELECTION GATES TODAY']);
  assert.equal(all(r2).some((n) => n.localName === 'td'), false, 'no table on a failed read');
  assert.ok(all(r2).some((n) => n.localName === 'button' && /RETRY/i.test(n.textContent)), r2.textContent);
});

test('U4 sortable headers, and the share line', async () => {
  const { root } = await mountPanel(() => [200, answer({ gates_today: { ...GATES, gates: 45, rc1_unattributed: 27 } })]);
  const th = heads(root);
  assert.equal(th.length, 6);
  assert.ok(th.every((n) => 'aria-sort' in n.attrs), th.map((n) => JSON.stringify(n.attrs)).join(' '));
  assert.match(root.textContent, /unattributed: 27 of 45 \(60%\)/);
  assert.equal(shareLine({ ...GATES, gates: 0, rc1_unattributed: 0 }), 'unattributed: n/a');
  assert.equal(shareLine(null), 'unattributed: n/a');
  assert.equal(shareLine(GATES), 'unattributed: 1 of 4 (25%)');
});

test('U5 the real Project page mounts SELECTION GATES TODAY and reads the pool row once', async () => {
  const doc = installDom();
  const calls = routedFetch((u) => [200, u.startsWith('/api/dash/p/') ? { board: {}, runs: [], builds: [], alerts: [], events: [] }
    : u === URL_P ? answer({ gates_today: GATES }) : {}]);
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  await flush();
  assert.equal(titleOf(root).filter((t) => t === 'SELECTION GATES TODAY').length, 1, titleOf(root).join(', '));
  const sec = all(root).find((n) => n.attrs && n.attrs.class === 'section__title' && n.textContent === 'SELECTION GATES TODAY')
    .parentNode.parentNode;
  assert.match(sec.textContent, /unattributed: 1 of 4 \(25%\)/);
  assert.deepEqual(calls.filter((c) => c.url.includes('/pool/status')).map((c) => `${c.method} ${c.url}`), [`GET ${URL_P}`]);
});
