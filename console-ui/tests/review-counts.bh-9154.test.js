import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { api } from '../src/api.js';
import { LeadReviewsScreen } from '../src/screens/LeadReviews.js';
import { ReviewCountsPanel, REVIEW_KINDS, perMergedText } from '../src/screens/ReviewCountsPanel.js';
import { installDom, routedFetch, all, fire } from './helpers/fake-dom.bh-5750.js';
import { flush } from './helpers/settle.js';

// BH-9154 (Fix 5 of BH-9066): the REVIEW COUNTS panel on the Lead reviews
// screen. The real LeadReviewsScreen is mounted in the shared fake DOM with
// fetch routed; the review-counts answer is shaped like GET /api/review-counts
// (worker/jobs/src/routes/review-counts.js). Every other route answers 404, so
// the rest of the screen renders its error boxes and the panel still shows.

const KINDS = ['lens', 'fix-rereview', 'lead', 'conductor', 'autopilot', 'rescue', 'resolver'];
const day = (d, lead, merged, rebinds) => ({
  day: d,
  kinds: { lens: 4, 'fix-rereview': null, lead, conductor: 1, autopilot: 0, rescue: 0, resolver: 2 },
  reviews: 7 + lead, merged_prs: merged, rebinds, per_merged: merged ? (7 + lead) / merged : null
});
const COUNTS = {
  kinds: KINDS, unmapped: ['fix-rereview'], max_days: 30, rolled_at: '2026-11-06T10:00:00Z',
  days: [day('2026-11-06', 3, 2, 1), day('2026-11-05', 9, 0, 4), day('2026-11-04', 1, 4, 0)]
};

let mounted = null;
const realFetch = globalThis.fetch;
afterEach(async () => {
  if (mounted) { const { render: m } = await import('preact'); m(null, mounted); mounted = null; }
  globalThis.fetch = realFetch;
});
async function mount(vnode) {
  const doc = installDom();
  const { render: m } = await import('preact');
  const root = doc.createElement('div');
  m(vnode, root);
  mounted = root;
  await flush();
  return root;
}
const route = (answer) => (u) => {
  const p = new URL(u, 'https://mc.test').pathname;
  if (p === '/api/coord/review-counts') return typeof answer === 'function' ? answer(u) : answer;
  return [404, { error: `unstubbed ${p}` }];
};
const panelOf = (root) => all(root).find((n) => n.attrs && n.attrs['data-panel'] === 'review-counts');
// Visible: in the mounted tree, and neither it nor an ancestor is hidden.
function visible(node) {
  if (!node) return false;
  for (let n = node; n; n = n.parentNode) {
    if (n.attrs && ('hidden' in n.attrs || /display:\s*none/.test(styleOf(n)))) return false;
    if (n.style && n.style.display === 'none') return false;
  }
  return true;
}
// preact sets a style string through style.cssText (no attribute on the fake node).
const styleOf = (n) => (n.attrs && n.attrs.style) || (n.style && n.style.cssText) || '';
const headers = (node) => all(node).filter((n) => n.localName === 'th');
const headText = (th) => th.textContent.replace(/[↑↓]/g, '').trim();
const bodyRows = (node) => all(node).filter((n) => n.localName === 'tr').slice(1);

test('P1 the panel is visible on the Lead reviews screen, with the 7 kind headers and a row per day', async () => {
  const calls = routedFetch(route([200, COUNTS]));
  const root = await mount(h(LeadReviewsScreen));
  const panel = panelOf(root);
  assert.ok(visible(panel), 'the review counts panel is mounted and visible');
  const heads = headers(panel).map(headText);
  for (const k of REVIEW_KINDS) assert.ok(heads.includes(k.label), `header ${k.label} in ${heads.join(',')}`);
  assert.deepEqual(REVIEW_KINDS.map((k) => k.key), KINDS);
  assert.ok(heads.includes('REVIEWS / MERGED PR'));
  assert.ok(heads.includes('REBINDS'));
  const rows = bodyRows(panel);
  assert.equal(rows.length, 3);
  assert.match(rows[0].textContent, /2026-11-06/, 'newest day first');
  assert.match(rows[0].textContent, /5\.0/, '10 reviews over 2 merged PRs');
  assert.ok(calls.some((c) => c.url === '/api/coord/review-counts'), calls.map((c) => c.url).join('\n'));
  // an unmapped kind is unknown, never 0
  const fixCol = heads.indexOf('FIX RE-REVIEW');
  const cells = all(rows[0]).filter((n) => n.localName === 'td');
  assert.equal(cells[fixCol].textContent.trim(), '—');
  // the overflow wrapper keeps a narrow screen from body scroll
  assert.ok(all(panel).some((n) => /overflow-x:\s*auto/.test(styleOf(n))));
});

test('P2 a header click sorts and moves aria-sort', async () => {
  routedFetch(route([200, COUNTS]));
  const root = await mount(h(LeadReviewsScreen));
  const panel = panelOf(root);
  const leadTh = () => headers(panel).find((th) => headText(th) === 'LEAD');
  const btn = all(leadTh()).find((n) => n.localName === 'button');
  fire(btn, 'click');
  await flush();
  assert.equal(leadTh().attrs['aria-sort'], 'ascending');
  assert.match(bodyRows(panel)[0].textContent, /2026-11-04/, 'lead 1 first');
  fire(all(leadTh()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(leadTh().attrs['aria-sort'], 'descending');
  assert.match(bodyRows(panel)[0].textContent, /2026-11-05/, 'lead 9 first');
});

test('P3 empty, loading and error are three different states', async () => {
  routedFetch(route([200, { ...COUNTS, days: [] }]));
  let root = await mount(h(ReviewCountsPanel));
  let panel = panelOf(root);
  assert.ok(visible(panel));
  assert.match(panel.textContent, /No review was counted in the last 30 days\./);
  const { render: m } = await import('preact'); m(null, mounted); mounted = null;

  routedFetch(route([503, { error: 'd1 down' }]));
  root = await mount(h(ReviewCountsPanel));
  panel = panelOf(root);
  assert.match(panel.textContent, /d1 down/);
  assert.doesNotMatch(panel.textContent, /No review was counted/);
  m(null, mounted); mounted = null;

  let release;
  routedFetch(route(() => [200, COUNTS]));
  const slow = globalThis.fetch;
  globalThis.fetch = (...a) => new Promise((res) => { release = () => res(slow(...a)); });
  root = await mount(h(ReviewCountsPanel));
  panel = panelOf(root);
  assert.ok(all(panel).some((n) => /\bskel\b/.test(n.attrs && n.attrs.class || '')), 'a skeleton while loading');
  release();
  await flush();
  assert.equal(bodyRows(panelOf(root)).length, 3);
});

test('P4 api.reviewCounts reads the coord proxy path', async () => {
  const calls = routedFetch(() => [200, COUNTS]);
  await api.reviewCounts();
  await api.reviewCounts({ days: 7 });
  await api.reviewCounts({ days: 7, project: 'cromford' });
  const want = ['/api/coord/review-counts', '/api/coord/review-counts?days=7', '/api/coord/review-counts?days=7&project=cromford'];  // determinism: ok URLs compared as strings; the stub applies no window and P4 reads no dated row
  assert.deepEqual(calls.map((c) => c.url), want);
});

test('P5 perMergedText: no merged PR is n/a, never infinity or 0', () => {
  assert.equal(perMergedText({ reviews: 10, merged_prs: 2, per_merged: 5 }), '5.0');
  assert.equal(perMergedText({ reviews: 3, merged_prs: 0, per_merged: null }), 'n/a');
  assert.equal(perMergedText({ reviews: 0, merged_prs: null, per_merged: null }), 'n/a');
});
