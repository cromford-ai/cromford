import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, all } from './helpers/fake-dom.bh-5750.js';

// BH-9901 (T6): WAITING FOR CLIENT APPROVAL in the console. The hub row is
// read by the real api.js through the coord proxy path; the PR page is the
// real PRScreen mounted into the fake DOM, the BUILDS table is the real
// BuildsTable rendered to a string.
//   V1 approvalOf pure cases          V2 approvalMap limit + lowercased keys
//   V3 BuildsTable STAGE cell tag      V4 PRScreen header tag (waiting, live head)
//   V5 status closed → no tag          V6 merged → no tag
//   V7 head moved / 404 / 500 → no tag, the screen still renders
//   V8 the shared fixture row          V9 BuildsTable without approvals unchanged

installWindow();
const { render: mount } = await import('preact');
const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { approvalOf, approvalMap, approvalKey, approvalKeyFromPrUrl } = await import('../src/lib/client-approval.js');
const { BuildsTable } = await import('../src/screens/Project.js');
const { PRScreen } = await import('../src/screens/PR.js');

const here = path.dirname(fileURLToPath(import.meta.url));
// V8: the exact row the box writes (RT1 asserts the box's PUT equals it).
const FIXTURE = JSON.parse(fs.readFileSync(path.join(here, '../../tests/fixtures/client-approval/ledger-row.bh-9901.json'), 'utf8'));
const FDETAIL = JSON.parse(FIXTURE.detail);
const HEAD = FDETAIL.head;
const OTHER = 'c'.repeat(40);
const NOW = Date.parse(FDETAIL.requested_at) + 125 * 60000; // 2h after the request
const TICKET_URL = 'https://os.project-3.example/feature-board?ticket=T-501';

const row = (over = {}, det = {}) => ({
  ...FIXTURE, ...over,
  detail: 'detail' in over ? over.detail : JSON.stringify({ ...FDETAIL, ...det })
});

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

// ---------------------------------------------------------------- V1, V8
test('V1 approvalOf: only a waiting v1 row with a readable requested_at is waiting', () => {
  const a = approvalOf(row(), NOW);
  assert.deepEqual(Object.keys(a).sort(), ['ageMin', 'head', 'since', 'ticketId', 'ticketUrl', 'waiting']);
  assert.equal(a.waiting, true);
  assert.equal(a.ticketId, 'T-501');
  assert.equal(a.ticketUrl, TICKET_URL);
  assert.equal(a.since, FDETAIL.requested_at);
  assert.equal(a.ageMin, 125);
  assert.equal(a.head, HEAD);
  assert.deepEqual(approvalOf({ ledger: row() }, NOW), a, 'the point-read body unwraps');
  for (const status of ['closed', 'approved', 'hold', 'mystery', '', null, 'WAITING']) {
    assert.equal(approvalOf(row({ status }), NOW), null, `status ${status}`);
  }
  assert.equal(approvalOf(row({ detail: 'not json {' }), NOW), null, 'detail not JSON');
  assert.equal(approvalOf(row({ detail: null }), NOW), null, 'no detail');
  assert.equal(approvalOf(row({}, { v: 2 }), NOW), null, 'v:2');
  assert.equal(approvalOf(row({}, { v: '1' }), NOW), null, 'v as a string');
  assert.equal(approvalOf(row({}, { requested_at: 'yesterday' }), NOW), null, 'bad date');
  assert.equal(approvalOf(row({}, { requested_at: '2026-13-45T99:99:99Z' }), NOW), null, 'impossible date');
  assert.equal(approvalOf(row({}, { requested_at: null }), NOW), null, 'no date');
  assert.equal(approvalOf(row({}, { ticket_url: 'http://os.project-3.example/x' }), NOW).ticketUrl, null, 'http is not a link');
  assert.equal(approvalOf(row({}, { ticket_url: 'javascript:alert(1)' }), NOW).ticketUrl, null);
  assert.equal(approvalOf(row({}, { ticket_url: '//evil.test/x' }), NOW).ticketUrl, null);
  assert.equal(approvalOf(row({}, { ticket_url: null }), NOW).ticketUrl, null);
  assert.equal(approvalOf(row({}, { head: 'abc' }), NOW).head, null, 'a short head is not a head');
  assert.equal(approvalOf(row({ kind: 'ticket_hold' }), NOW), null, 'another kind');
  assert.equal(approvalOf(null, NOW), null);
  assert.equal(approvalOf({ ledger: null }, NOW), null, 'the 404 answer');
  assert.equal(approvalOf({}, NOW), null, 'an empty body');
  assert.equal(approvalOf(new Error('x'), NOW), null);
});

test('V8 the shared fixture row is what the console reads', () => {
  assert.equal(FIXTURE.kind, 'client-approval');
  assert.equal(FIXTURE.key, approvalKey('example-org/project-3', 501));
  const a = approvalOf(FIXTURE, NOW);
  assert.ok(a && a.waiting, 'the fixture row is waiting');
  assert.equal(a.ticketId, 'T-501');
  assert.equal(a.ticketUrl, TICKET_URL);
  assert.equal(a.head, HEAD);
});

// ---------------------------------------------------------------- V2
test('V2 approvalMap: complete only below the limit; keys lowercased both ways', () => {
  const rows = (n) => Array.from({ length: n }, (_, i) => row({ key: `example-org/project-3#${i + 1}` }));
  assert.equal(approvalMap({ ledgers: rows(3) }, 3, NOW).complete, false, 'at the limit');
  assert.equal(approvalMap({ ledgers: rows(4) }, 3, NOW).complete, false, 'over the limit');
  const below = approvalMap({ ledgers: rows(2) }, 3, NOW);
  assert.equal(below.complete, true);
  assert.equal(below.map.size, 2);
  assert.equal(approvalMap(null, 3, NOW).complete, false, 'no payload is not complete');
  assert.equal(approvalMap({ error: 'x' }, 3, NOW).map.size, 0);

  const mixed = approvalMap({ ledgers: [row({ key: 'example-org/project-3#5' })] }, 200, NOW);
  assert.ok(mixed.map.get(approvalKey('example-org/project-3', 5)), 'a mixed-case row key is found');
  assert.ok(mixed.map.get(approvalKey('example-org/project-3', 5)), 'a mixed-case lookup finds it too');
  assert.equal(approvalKeyFromPrUrl('https://github.com/example-org/project-3/pull/5'), 'example-org/project-3#5');
  assert.equal(approvalKeyFromPrUrl('https://gitlab.com/example-org/project-3/pull/5'), null);

  const closed = approvalMap({ ledgers: [row({ key: 'a/b#1', status: 'closed' })] }, 200, NOW);
  assert.equal(closed.map.size, 0, 'a closed row in the list is not waiting');
  const dup = approvalMap({ ledgers: [row({ key: 'A/B#1' }), row({ key: 'a/b#1' })] }, 200, NOW);
  assert.equal(dup.map.size, 0, 'two rows on one normalized key are refused, never picked');
});

// ---------------------------------------------------------------- V3, V6, V9
const PR_URL = 'https://github.com/example-org/project-3/pull/501';
const build = (over = {}) => ({
  id: 77, ticket_key: 'T-501', bkey: 'T-501', stage: 'pr_created', merged: 0,
  pr_url: PR_URL, age_min: 5, tier: 2, verdict: 'APPROVE', ...over
});
const tds = (out) => [...out.matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1]);
const stageCell = (out) => tds(out)[1];
const mapOf = (rows) => approvalMap({ ledgers: rows }, 200, NOW).map;

test('V3 BuildsTable with approvals: the tag, the age and the ticket link replace the stage text', () => {
  const out = render(h(BuildsTable, { builds: [build()], project: 'project-3', approvals: mapOf([FIXTURE]) }));
  const cell = stageCell(out);
  assert.match(cell, /class="build__bar"/, 'the bar stays');
  assert.match(cell, /WAITING FOR CLIENT APPROVAL · 2h/);
  assert.match(cell, new RegExp(`<a href="${TICKET_URL.replace(/[?]/g, '\\?')}" target="_blank" rel="noopener noreferrer">ticket T-501 ↗</a>`));
  assert.doesNotMatch(cell, /pr_created/, 'the stage text is gone from the cell');
  assert.doesNotMatch(cell, /#[0-9a-fA-F]{3,8}\b/, 'no hex colours');

  const noUrl = render(h(BuildsTable, { builds: [build()], project: 'project-3', approvals: mapOf([row({}, { ticket_url: null })]) }));
  assert.match(stageCell(noUrl), /<span>ticket T-501<\/span>/);
  assert.doesNotMatch(stageCell(noUrl), /<a /, 'no URL, no link');

  const other = render(h(BuildsTable, { builds: [build({ pr_url: 'https://github.com/example-org/project-3/pull/502' })], project: 'project-3', approvals: mapOf([FIXTURE]) }));
  assert.doesNotMatch(other, /WAITING FOR CLIENT APPROVAL/, 'another PR is not tagged');
});

test('V6 a merged build is never tagged', () => {
  const out = render(h(BuildsTable, { builds: [build({ merged: 1, stage: 'pr_merged' })], project: 'project-3', approvals: mapOf([FIXTURE]) }));
  assert.doesNotMatch(out, /WAITING FOR CLIENT APPROVAL/);
  assert.match(stageCell(out), /pr_merged/);
});

test('V9 BuildsTable without approvals renders exactly as before', () => {
  const builds = [build(), build({ id: 78, ticket_key: 'T-9', bkey: 'T-9', stage: 'executing', pr_url: null })];
  const before = render(h(BuildsTable, { builds, project: 'project-3' }));
  assert.equal(render(h(BuildsTable, { builds, project: 'project-3', approvals: new Map() })), before, 'an empty map');
  assert.equal(render(h(BuildsTable, { builds, project: 'project-3', approvals: undefined })), before, 'undefined');
  assert.doesNotMatch(before, /WAITING FOR CLIENT APPROVAL|client-approval/);
  assert.match(stageCell(before), /pr_created/);
});

// ---------------------------------------------------------------- V4, V5, V6, V7 (the real PR screen)
const LEDGER_GET = `/api/coord/ledger?kind=client-approval&key=${encodeURIComponent('example-org/project-3#501')}`;

function prWorld({ ledger = [200, { ledger: FIXTURE }], state = 'open', head = HEAD } = {}) {
  return (u) => {
    const p = new URL(u, 'https://mc.test').pathname;
    if (p === '/api/dash/pr/project-3/501') {
      return [200, {
        html_url: PR_URL, head_sha: head, enriched: true,
        gh: { state, title: 'Feature board approval', draft: false, head_sha: head },
        builds: [build({ merged: state === 'merged' ? 1 : 0 })]
      }];
    }
    if (p === '/api/coord/ledger' && new URL(u, 'https://mc.test').searchParams.get('kind') === 'client-approval') return ledger;
    if (p === '/api/coord/verdicts') return [200, { rows: [], standing: null, truncated: false }];
    return [200, {}];
  };
}
async function mountPR(world) {
  const calls = routedFetch(world);
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(PRScreen, { project: 'project-3', number: '501' }), root);
  mounted = root;
  await waitFor(() => /Feature board approval/.test(root.textContent), 'the PR header');
  await waitFor(() => calls.some((c) => c.url === LEDGER_GET), 'the client-approval read', () => calls.map((c) => c.url).join('\n'));
  await flush();
  return { root, calls };
}
const tagNode = (root) => all(root).find((n) => n.localName === 'span' && (n.attrs.class || '') === 'tag tag--warn' &&
  /WAITING FOR CLIENT APPROVAL/.test(n.textContent));
const shown = (n) => {
  for (let p = n; p; p = p.parentNode) {
    const s = `${(p.attrs && p.attrs.style) || ''}`;
    if (/display:\s*none|visibility:\s*hidden/.test(s) || (p.attrs && 'hidden' in p.attrs)) return false;
  }
  return true;
};

test('V4 the real PR screen shows the tag in the header when the row waits on the live head', async () => {
  const { root, calls } = await mountPR(prWorld());
  await waitFor(() => tagNode(root), 'the tag');
  const tag = tagNode(root);
  assert.ok(shown(tag), 'the tag is visible in the mounted DOM');
  assert.match(tag.textContent, /WAITING FOR CLIENT APPROVAL · (now|\d+[mhd])/);
  const link = all(root).find((n) => n.localName === 'a' && n.attrs.href === TICKET_URL);
  assert.ok(link, 'the ticket link');
  assert.equal(link.attrs.target, '_blank');
  assert.equal(link.attrs.rel, 'noopener noreferrer');
  assert.match(link.textContent, /ticket T-501 ↗/);
  // It sits in the header row, next to the state pill.
  const pill = all(root).find((n) => n.localName === 'span' && /\bpill\b/.test(n.attrs.class || '') && /OPEN/.test(n.textContent));
  assert.ok(pill, 'the state pill');
  assert.ok(tag.parentNode.parentNode === pill.parentNode, 'the tag is in the same header row as the state pill');
  assert.equal(calls.filter((c) => c.url === LEDGER_GET).length, 1, 'one point read, the key lowercased');
});

test('V5 a closed row shows no tag', async () => {
  const { root } = await mountPR(prWorld({ ledger: [200, { ledger: row({ status: 'closed' }) }] }));
  assert.equal(Boolean(tagNode(root)), false);
});

test('V6 a merged PR shows no tag', async () => {
  const { root } = await mountPR(prWorld({ state: 'merged' }));
  assert.match(root.textContent, /MERGED/);
  assert.equal(Boolean(tagNode(root)), false);
});

test('V7 a moved head, a 404 and a 500 show no tag; the screen still renders', async () => {
  const moved = await mountPR(prWorld({ head: OTHER }));
  assert.equal(Boolean(tagNode(moved.root)), false, 'detail.head is not the live head');
  mount(null, mounted); mounted = null;

  const absent = await mountPR(prWorld({ ledger: [404, { error: 'not found' }] }));
  assert.equal(Boolean(tagNode(absent.root)), false, 'a 404');
  assert.match(absent.root.textContent, /Feature board approval/);
  mount(null, mounted); mounted = null;

  const failed = await mountPR(prWorld({ ledger: [500, { error: 'boom' }] }));
  assert.equal(Boolean(tagNode(failed.root)), false, 'a 500');
  assert.match(failed.root.textContent, /Feature board approval/, 'the screen still renders');
  assert.doesNotMatch(failed.root.textContent, /boom/, 'a failed read is no claim in the header');
});

test('V2b api.clientApprovalsWaiting reads the waiting list through the coord proxy', async () => {
  const calls = routedFetch(() => [200, { ledgers: [], as_of: 'x' }]);
  await api.clientApprovalsWaiting();
  await api.clientApprovalsWaiting(5);
  assert.equal(calls[0].url, '/api/coord/ledger?kind=client-approval&status=waiting&limit=200');
  assert.equal(calls[1].url, '/api/coord/ledger?kind=client-approval&status=waiting&limit=5');
  const one = routedFetch(() => [404, { error: 'not found' }]);
  assert.deepEqual(await api.clientApproval('example-org/project-3', 5), { ledger: null });
  assert.equal(one[0].url, `/api/coord/ledger?kind=client-approval&key=${encodeURIComponent('example-org/project-3#5')}`);
  routedFetch(() => [500, { error: 'boom' }]);
  await assert.rejects(api.clientApproval('a/b', 1), 'a 500 is not "not waiting" at the api layer');
});
