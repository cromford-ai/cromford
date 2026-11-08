import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { Modal } from '../src/ui/Modal.js';
import {
  mainRedRows, mainRedForProject, clearFormState, ClearForm, runClear, MainRedBannerView
} from '../src/ui/MainRedBanner.js';

// BH-2329.3: the main-red banner on /p/<project>. preact-render-to-string runs
// no effects or handlers, so MainRedBannerView is driven with each load state
// directly, the modal body through the real Modal, and the confirm path
// through runClear — the one function CLEAR's confirm calls — against the real
// api.clearMainRed with fetch captured.

const NOW = Date.parse('2026-09-25T17:00:00Z');
const SHA = 'abcdef1234567890abcdef1234567890abcdef12';
const RUN = 'https://github.com/example-org/project-3/actions/runs/123456';
const FULL = {
  name: 'main-red-example-org-project-3', project: 'project-3', slug: 'example-org/project-3', active: 1,
  sha: SHA, workflow: 'CI', job: 'test', run_url: RUN, since: '2026-09-25T15:00:00Z',
  actor: 'detector', reason: 'main red'
};
const loaded = (data) => ({ data, error: null, loading: false });
const view = (state, project = 'project-3', msg = null) =>
  render(h(MainRedBannerView, { state, project, onClear: () => {}, msg, now: NOW }));

test('mainRedForProject matches on project or main-red-<project> and rejects every other row', () => {
  const keep = [{ project: 'project-3', name: 'main-red-example-org-project-3' }, { name: 'main-red-project-3', project: null }];
  const drop = [
    { project: 'project-4', name: 'main-red-example-org-project-4' },
    { name: 'main-red-project-3-2' },
    { project: 'fixture-other' },
    null
  ];
  assert.deepEqual(mainRedForProject([...keep, ...drop], 'project-3'), keep);
  // A pr-pair freeze is slug-named with no project: not a cromford banner.
  assert.deepEqual(mainRedForProject([{ name: 'main-red-example-org-cromford', project: null }], 'cromford'), []);
});

test('mainRedRows reads the envelope, the rows key or a bare array', () => {
  const rows = [FULL];
  assert.deepEqual(mainRedRows({ main_red: rows, truncated: false }), rows);
  assert.deepEqual(mainRedRows({ rows }), rows);
  assert.deepEqual(mainRedRows(rows), rows);
  assert.deepEqual(mainRedRows(null), []);
  assert.deepEqual(mainRedRows({}), []);
});

test('a full row renders one alert banner with workflow, job, sha8, since and both links', () => {
  const out = view(loaded({ main_red: [FULL] }));
  assert.equal((out.match(/role="alert"/g) || []).length, 1);
  assert.match(out, /MAIN IS RED/);
  assert.match(out, /example-org\/project-3/);
  assert.match(out, /CI failed \(job: test\)/);
  assert.match(out, />abcdef12</);
  assert.ok(out.includes(`href="https://github.com/example-org/project-3/commit/${SHA}"`), out);
  const run = out.match(/<a[^>]*>RUN<\/a>/);
  assert.ok(run, out);
  assert.ok(run[0].includes(`href="${RUN}"`));
  assert.match(run[0], /target="_blank"/);
  assert.match(run[0], /rel="noopener"/);
  assert.match(out, /since 2h/);
  assert.match(out, /<button[^>]*class="btn btn--warn"[^>]*>CLEAR<\/button>/);
});

test('two matching rows render two banners; another project sees none', () => {
  const other = { ...FULL, name: 'main-red-project-3', project: null };
  assert.equal((view(loaded({ main_red: [FULL, other] })).match(/role="alert"/g) || []).length, 2);
  assert.equal(view(loaded({ main_red: [FULL, other] }), 'project-4'), '');
});

test('links render only from the row\'s own fields', () => {
  const noRun = view(loaded({ main_red: [{ ...FULL, run_url: null }] }));
  assert.doesNotMatch(noRun, />RUN</);
  assert.match(noRun, /github\.com\/example-org\/project-3\/commit/);
  const noSlug = view(loaded({ main_red: [{ ...FULL, slug: null }] }));
  assert.doesNotMatch(noSlug, /\/commit\//);
  assert.match(noSlug, /abcdef12/);
  assert.match(noSlug, /main-red-example-org-project-3/);
  const noSince = view(loaded({ main_red: [{ ...FULL, since: null }] }));
  assert.doesNotMatch(noSince, /since|NaN|never/);
});

test('a row with no detail shows the pause_flags reason and actor', () => {
  const out = view(loaded([{ name: 'main-red-project-3', reason: 'red on main', actor: 'detector' }]));
  assert.match(out, /role="alert"/);
  assert.match(out, /red on main/);
  assert.match(out, /detector/);
  assert.doesNotMatch(out, /failed|undefined/);
});

test('zero matching rows, and loading with no data, render nothing', () => {
  assert.equal(view(loaded({ main_red: [] })), '');
  assert.equal(view({ data: null, error: null, loading: true }), '');
});

test('a load failure renders only the muted unavailable line, never a green claim', () => {
  for (const data of [null, { main_red: [FULL] }]) {
    const out = view({ data, error: new Error('http_404'), loading: false });
    assert.match(out, /main-red status unavailable/);
    assert.doesNotMatch(out, /role="alert"/);
    assert.doesNotMatch(out, /green|all clear/i);
  }
});

test('clearFormState blocks a blank or whitespace reason and allows a real one', () => {
  for (const reason of ['', '   ', '\t\n', undefined]) {
    const s = clearFormState({ reason });
    assert.equal(s.blocked, true, `reason=${JSON.stringify(reason)}`);
    assert.match(s.hint, /reason is required/i);
  }
  assert.deepEqual(clearFormState({ reason: 'flaky runner, rerun green' }), { blocked: false, hint: null });
});

test('the CLEAR dialog renders the reason field, the unfreeze line and a disabled CLEAR', () => {
  const out = render(h(Modal, {
    title: 'CLEAR MAIN-RED', tone: 'warn', confirmLabel: 'CLEAR', confirmBlocked: true,
    onConfirm: () => {}, onCancel: () => {},
    body: ({ setBlocked }) => h(ClearForm, { row: FULL, value: { reason: '' }, onBlocked: setBlocked })
  }));
  assert.match(out, /aria-label="CLEAR MAIN-RED"/);
  assert.match(out, /<textarea/);
  assert.match(out, /Merges unfreeze for this sha\. If main goes red on a new sha the freeze comes back\./);
  assert.match(out, /A reason is required/);
  const btn = out.match(/<button[^>]*>CLEAR<\/button>/);
  assert.ok(btn, out);
  assert.match(btn[0], /disabled/);
});

function captureFetch(status, payload) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url, method: init.method, body: init.body });
    return new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

test('runClear posts {name, reason, sha} through api.clearMainRed and reports success', async () => {
  const f = captureFetch(200, { cleared: true });
  try {
    const r = await runClear(FULL, { reason: '  trimmed  ' });
    assert.deepEqual(r, { ok: true, text: 'cleared' });
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, '/api/coord/main-red/clear');
    assert.equal(f.seen[0].method, 'POST');
    assert.deepEqual(JSON.parse(f.seen[0].body), { name: FULL.name, reason: 'trimmed', sha: SHA });
  } finally { f.restore(); }
});

test('runClear never reads a worker 409 or 400 as success', async () => {
  for (const [status, error] of [[409, 'moved to a new sha'], [409, 'not red'], [400, 'reason required']]) {
    const f = captureFetch(status, { error });
    try {
      assert.deepEqual(await runClear(FULL, { reason: 'x' }), { ok: false, text: error });
    } finally { f.restore(); }
  }
});

test('the success and error text renders under the banner', () => {
  const out = view(loaded({ main_red: [FULL] }), 'project-3', { ok: false, text: 'moved to a new sha' });
  assert.match(out, /moved to a new sha/);
  // After a clear the reload drops the row; the "cleared" line still shows.
  assert.match(view(loaded({ main_red: [] }), 'project-3', { ok: true, text: 'cleared' }), /cleared/);
});
