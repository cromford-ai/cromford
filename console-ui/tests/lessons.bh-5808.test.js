import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { LessonsSection, LessonsView, rateOf } from '../src/screens/Lessons.js';

// BH-5808 (BH-5794.3): the LESSONS section on /lead-reviews. The payload is
// GET /api/lessons/digest's (worker/jobs/src/routes/lessons.js; its own test
// drives the server side and builds this shape from real rows).

const data = {
  window: { since: '2099-09-18T12:00:00Z', days: 7 },
  overall: { blocks: 10, reviewed: 40, rate: 25 },
  categories: [
    { id: 'iron-law', name: 'An iron law was broken', blocks: 3, rate: 7.5, lesson_status: 'not-working' },
    { id: 'test-cannot-fail', name: 'A test that cannot fail', blocks: 6, rate: 15, lesson_status: 'measuring' },
    { id: 'other', name: 'Other', blocks: 1, rate: 2.5, lesson_status: null }
  ],
  lessons: {
    added: 1, measuring: 1, working: 0, not_working: 1, inconclusive: 0, retired: 1, removing: 2, list_truncated: false,
    list: [
      { id: 11, category: 'test-cannot-fail', change_type: 'plan-lesson', kind: 'pr', repo: 'example-org/cromford', number: 7101,
        url: 'https://github.com/example-org/cromford/pull/7101', title: 'Lesson: x [lesson:test-cannot-fail]', merged_at: '2099-09-22T10:00:00Z',
        status: 'measuring', before_blocks: 10, before_reviewed: 100, after_blocks: null, after_reviewed: null, cut_pct: null,
        escalation_number: null, removal_number: null },
      { id: 12, category: 'iron-law', change_type: 'check', kind: 'issue', repo: 'example-org/cromford', number: 7202,
        url: null, title: 'Lesson: y [lesson:iron-law]', merged_at: '2099-08-01T10:00:00Z',
        status: 'not-working', before_blocks: 10, before_reviewed: 100, after_blocks: 9, after_reviewed: 100, cut_pct: 10,
        escalation_stage: 'harness-bug', escalation_number: 8001, escalation_url: 'https://github.com/example-org/cromford/issues/8001',
        removal_number: null },
      { id: 13, category: 'no-test', change_type: 'plan-lesson', kind: 'pr', repo: 'example-org/cromford', number: 7301,
        url: 'https://github.com/example-org/cromford/pull/7301', merged_at: '2099-07-01T10:00:00Z', status: 'superseded',
        before_blocks: 4, before_reviewed: 50, after_blocks: 1, after_reviewed: 50, cut_pct: 75,
        removal_number: 8002, removal_url: 'https://github.com/example-org/cromford/pull/8002' }
    ]
  },
  uncovered: [{ id: 'iron-law', name: 'An iron law was broken', blocks: 3, rate: 7.5 }],
  other_blocks: 1,
  as_of: '2099-09-25T12:00:00Z'
};
const kid = {
  data: {
    rows: [
      { id: 1, verdict_id: 77, n: 1, repo: 'example-org/cromford', pr: 5824, ticket: 'BH-9001', category: 'iron-law',
        cause: 'the iron law', files: ['bin/a.sh'], infra_false: false, report_url: 'https://github.com/example-org/cromford/pull/5824#lr', verdict_at: '2099-09-22T10:00:00Z' }
    ]
  }
};
const noop = () => {};
const base = { data, error: null, loading: false, reload: noop, open: null, onOpen: noop, kid: null, onRetryChild: noop };
const view = (over = {}) => render(h(LessonsView, { ...base, ...over }));
const tables = (out) => out.split('<tbody').slice(1).map((t) => t.split('</tbody>')[0].split('<tr').slice(1));

test('V0: the api reads the coord lessons digest', async () => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(String(url)); return new Response('{}', { status: 200 }); };
  try {
    await api.lessonsDigest();
    await api.lessonsDigest(14);
  } finally { globalThis.fetch = prev; }
  assert.deepEqual(seen, ['/api/coord/lessons/digest?days=7', '/api/coord/lessons/digest?days=14']);  // determinism: ok clock-rolling-window fetch is stubbed; only the request URL is checked, no window is read
});

test('V1: the view renders the overall rate and the per-category rates, most BLOCKs first', () => {
  const out = view();
  assert.ok(out.includes('LESSONS'));
  assert.match(out, /BLOCK rate 25 per 100 reviewed PRs \(10 BLOCKs in 40 PRs\)/);
  assert.match(out, /lessons added 1/);
  assert.match(out, /retired 1/);
  assert.match(out, /removal PR open 2/);
  const [cats] = tables(out);
  assert.equal(cats.length, 3);
  assert.ok(cats[0].includes('test-cannot-fail') && cats[0].includes('>6<') && cats[0].includes('>15<') && cats[0].includes('measuring'), cats[0]);
  assert.ok(cats[1].includes('iron-law') && cats[1].includes('>7.5<') && cats[1].includes('not-working'), cats[1]);
  assert.ok(out.includes('An iron law was broken'));
  assert.match(out, /data-testid="lessons-uncovered"[^]*An iron law was broken[^]*3 BLOCKs/);
  assert.match(out, /other: 1 BLOCKs with no category/);
});

test('V2: each lesson row links its PR or issue, its escalation and its removal PR; before and after rates', () => {
  const out = view();
  const [, ls] = tables(out);
  assert.equal(ls.length, 3);
  // Newest merged first.
  assert.ok(ls[0].includes('href="https://github.com/example-org/cromford/pull/7101"') && ls[0].includes('PR #7101'), ls[0]);
  assert.ok(ls[1].includes('href="https://github.com/example-org/cromford/issues/7202"'), 'an issue with no url links by number');
  assert.ok(ls[1].includes('href="https://github.com/example-org/cromford/issues/8001"') && ls[1].includes('harness-bug'), ls[1]);
  assert.ok(ls[1].includes('>10<') && ls[1].includes('>9<'), 'before 10.0 and after 9.0 per 100');
  assert.ok(ls[2].includes('href="https://github.com/example-org/cromford/pull/8002"'), 'the removal PR');
  assert.equal(rateOf(10, 100), 10);
  assert.equal(rateOf(71, 1000), 7.1);
  assert.equal(rateOf(1, 0), null);
  assert.equal(rateOf(null, 100), null);
});

test('V3: every header sorts with aria-sort; a category row opens its findings with PR and verdict links', () => {
  const out = view();
  for (const label of ['CATEGORY', 'BLOCKS', 'RATE', 'LESSON', 'STAGE', 'MERGED', 'BEFORE', 'AFTER', 'CUT', 'STATUS', 'ESCALATION', 'REMOVAL']) {
    assert.ok(out.includes(label), label);
  }
  assert.ok((out.match(/aria-sort=/g) || []).length >= 14, 'every header of both tables carries aria-sort');
  assert.match(out, /aria-sort="descending"/);
  const opened = view({ open: 'iron-law', kid });
  assert.ok(opened.includes('newest findings'));
  assert.ok(opened.includes('href="https://github.com/example-org/cromford/pull/5824"'), 'PR link');
  assert.ok(opened.includes('verdict #77'), 'verdict link');
  assert.ok(opened.includes('aria-expanded="true"'));
});

test('V4: loading, error and empty states', () => {
  const loadingOut = view({ data: null, loading: true });
  assert.equal((loadingOut.match(/class="skel"/g) || []).length, 4, loadingOut);
  assert.ok(!loadingOut.includes('no lesson recorded'), 'loading is not the empty state');
  assert.ok(view({ data: null, error: new Error('boom') }).includes('boom'));
  const empty = view({ data: { ...data, categories: [], uncovered: [], other_blocks: 0, lessons: { ...data.lessons, list: [] } } });
  assert.ok(empty.includes('no BLOCK in this window'));
  assert.ok(empty.includes('no lesson recorded'));
  assert.ok(!empty.includes('<tbody><tr'), 'no blank table rows');
});

test('V5: mounted on /lead-reviews below BLOCKS BY CATEGORY; no native dialogs', () => {
  assert.ok(render(h(LessonsSection)).includes('LESSONS'));
  const lr = readFileSync(new URL('../src/screens/LeadReviews.js', import.meta.url), 'utf8');
  assert.ok(lr.includes("import { LessonsSection } from './Lessons.js';"));
  assert.ok(lr.indexOf('<${LessonsSection}/>') > lr.indexOf('<${BlockCategoriesSection}/>'));
  const src = readFileSync(new URL('../src/screens/Lessons.js', import.meta.url), 'utf8');
  assert.ok(!/\b(alert|confirm|prompt)\(/.test(src));
});
