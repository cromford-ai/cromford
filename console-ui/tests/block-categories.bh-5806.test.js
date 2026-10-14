import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { BlockCategoriesSection, BlockCategoriesView, rowKeyOf } from '../src/screens/BlockCategories.js';

// BH-5806 (BH-5794.1): the BLOCKS BY CATEGORY section on /lead-reviews. The
// payload shapes are GET /api/block-findings/weekly's and GET /api/block-findings'
// (worker/jobs/src/routes/block-findings.js; its own test drives the server side).

const data = {
  weeks: 8, from: '2099-08-03', as_of: '2099-09-25T12:00:00Z',
  rows: [
    { week: '2099-09-14', category: 'ci-tests-skipped', name: 'CI skipped every test shard on the head', findings: 2, verdicts: 2, prs: 2 },
    { week: '2099-09-21', category: 'other', name: 'Other', findings: 1, verdicts: 1, prs: 1 },
    { week: '2099-09-21', category: 'ci-tests-skipped', name: 'CI skipped every test shard on the head', findings: 5, verdicts: 3, prs: 3 }
  ]
};
const kid = {
  data: {
    rows: [
      { id: 1, verdict_id: 77, n: 1, repo: 'example-org/cromford', pr: 5824, ticket: 'BH-5781', category: 'ci-tests-skipped',
        cause: 'CI skipped the shards', files: ['bin/a.sh'], infra_false: true, confidence: 0.8,
        report_url: 'https://github.com/example-org/cromford/pull/5824', verdict_at: '2099-09-22T10:00:00Z' },
      { id: 2, verdict_id: 78, n: 2, repo: 'example-org/cromford', pr: 5811, ticket: null, category: 'ci-tests-skipped',
        cause: 'no test ran', files: [], infra_false: false, confidence: null, report_url: null, verdict_at: '2099-09-23T10:00:00Z' }
    ]
  }
};
const noop = () => {};
const base = { data, error: null, loading: false, reload: noop, open: null, onOpen: noop, kid: null, onRetryChild: noop };
const view = (over = {}) => render(h(BlockCategoriesView, { ...base, ...over }));
const bodyRows = (out) => out.split('<tbody')[1].split('</tbody>')[0].split('<tr').slice(1);

test('B0: the api reads the coord block-findings routes', async () => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(String(url)); return new Response('{}', { status: 200 }); };
  try {
    await api.blockFindingsWeekly();
    await api.blockFindingsWeekly(4);
    await api.blockFindings({ category: 'ci-tests-skipped', week: '2099-09-21' });
  } finally { globalThis.fetch = prev; }
  assert.deepEqual(seen, [
    '/api/coord/block-findings/weekly?weeks=8',
    '/api/coord/block-findings/weekly?weeks=4',
    '/api/coord/block-findings?category=ci-tests-skipped&week=2099-09-21&limit=200'
  ]);
});

test('B1: sortable headers; newest week first, then the most findings; every row names its category', () => {
  const out = view();
  for (const label of ['WEEK', 'CATEGORY', 'FINDINGS', 'VERDICTS', 'PRS']) assert.ok(out.includes(label), label);
  assert.ok(out.includes('aria-sort'), 'headers sort');
  const rows = bodyRows(out);
  assert.equal(rows.length, 3);
  assert.ok(rows[0].includes('2099-09-21') && rows[0].includes('ci-tests-skipped') && rows[0].includes('>5<'), rows[0]);
  assert.ok(rows[1].includes('2099-09-21') && rows[1].includes('other'), rows[1]);
  assert.ok(rows[2].includes('2099-09-14'), rows[2]);
  assert.ok(rows[0].includes('CI skipped every test shard on the head'));
});

test('B2: an open row lists its findings, each linking the PR and the verdict', () => {
  const open = rowKeyOf(data.rows[2]);
  assert.equal(open, '2099-09-21|ci-tests-skipped');
  const out = view({ open, kid });
  assert.ok(out.includes('href="https://github.com/example-org/cromford/pull/5824"'), 'PR link');
  assert.ok(out.includes('verdict #77'), 'verdict id');
  assert.ok(out.includes('href="https://github.com/example-org/cromford/pull/5811"'), 'a verdict with no report_url links the PR');
  assert.ok(out.includes('verdict #78'));
  assert.ok(out.includes('BH-5781'));
  assert.ok(out.includes('CI skipped the shards'));
  assert.ok(out.includes('bin/a.sh'));
  assert.ok(out.includes('infra'), 'an infra or false BLOCK is marked');
});

test('B3: loading, error and empty states', () => {
  // The loading state is the 4-row Skeleton (class "skel"), not merely some output.
  const loadingOut = view({ data: null, loading: true });
  assert.equal((loadingOut.match(/class="skel"/g) || []).length, 4, loadingOut);
  assert.ok(!loadingOut.includes('no BLOCK classified'), 'loading is not the empty state');
  assert.ok(view({ data: null, error: new Error('boom') }).includes('boom'));
  assert.ok(view({ data: { ...data, rows: [] } }).includes('no BLOCK classified'));
});

test('B4: mounted on /lead-reviews; no native dialogs', () => {
  assert.ok(render(h(BlockCategoriesSection)).includes('BLOCKS BY CATEGORY'));
  const lr = readFileSync(new URL('../src/screens/LeadReviews.js', import.meta.url), 'utf8');
  assert.ok(lr.includes("import { BlockCategoriesSection } from './BlockCategories.js';"));
  assert.ok(lr.includes('<${BlockCategoriesSection}/>'));
  const src = readFileSync(new URL('../src/screens/BlockCategories.js', import.meta.url), 'utf8');
  assert.ok(!/\b(alert|confirm|prompt)\(/.test(src));
});
