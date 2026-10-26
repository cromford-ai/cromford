import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { onRequest, ROUTES } from '../functions/api/coord/[[path]].js';

// BH-7950 (BH-7934.3): the setup line screen at /projects/:project/setup/:runId
// (src/screens/SetupLine.js) and its two coord write rows
// (functions/_lib/coord-writes.d/7934-onboarding.js). The view model is fed
// the exact {run, steps} shape GET /api/onboarding/runs/:id answers
// (worker/jobs/src/routes/onboarding.js).
//   V1 eyebrow STATION n OF 7 per run state
//   V2 pill label and tone per step state
//   V3 formatDuration
//   V4 fix link map and a <script> excerpt rendered as text
//   V5 openEnabled, canCancel, nextPollMs
//   V6 acceptAnswer drops an older request's answer
//   W1 the two write rows, and nothing else of onboarding is writable
//   E1 the project page (/p/:project) links to the newest run's setup line,
//      and that href opens SetupLineScreen through the app's ROUTES

const SL = await import('../src/screens/SetupLine.js');
const { setupView, nextPollMs, formatDuration, FIX_LINKS, acceptAnswer, StationList } = SL;

const STATIONS = ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready'];
const RUN_ID = 'ob_0123456789abcdef0123';
const T0 = '2026-10-22T10:00:00Z';
const T1 = '2026-10-22T10:00:42Z';
const NOW = Date.parse('2026-10-22T10:03:05Z');

function fixture(runState, stepStates, over = {}) {
  return {
    run: {
      id: RUN_ID, project: 'demo', repo: 'example-org/demo', state: runState, station: null,
      created_by: null, created_at: T0, updated_at: T1, finished_at: null,
      inputs: { box: 'shared', project: 'demo', repo: 'example-org/demo', tracker: 'github-issues' }
    },
    steps: stepStates.map((st, i) => ({
      station: STATIONS[i], ord: i + 1, state: st,
      started_at: st === 'queued' || st === 'skipped' ? null : T0,
      finished_at: st === 'done' || st === 'failed' ? T1 : null,
      retries: 0, error_code: st === 'failed' ? 'app_no_issues_write' : null,
      log_excerpt: st === 'queued' ? null : `log of ${STATIONS[i]}`,
      ...(over[i] || {})
    }))
  };
}
const FX = {
  queued: fixture('queued', Array(7).fill('queued')),
  running: fixture('running', ['done', 'done', 'done', 'running', 'queued', 'queued', 'queued']),
  failed: fixture('failed', ['done', 'done', 'failed', 'skipped', 'skipped', 'skipped', 'skipped']),
  done: fixture('done', Array(7).fill('done')),
  cancelled: fixture('cancelled', ['done', 'done', 'skipped', 'skipped', 'skipped', 'skipped', 'skipped'])
};

test('V1 the eyebrow is STATION n OF 7, n the first step that is not done', () => {
  const want = { queued: 1, running: 4, failed: 3, done: 7, cancelled: 3 };
  for (const [k, n] of Object.entries(want)) {
    assert.equal(setupView(FX[k], NOW).eyebrow, `STATION ${n} OF 7`, k);
  }
});

test('V2 each step state has its pill label and tone', () => {
  const pills = (k) => setupView(FX[k], NOW).stations.map((s) => s.pill);
  assert.deepEqual(pills('running')[3], { label: 'RUNNING', tone: 'live' });
  assert.deepEqual(pills('running')[0], { label: 'DONE', tone: 'ok' });
  assert.deepEqual(pills('running')[4], { label: 'QUEUED', tone: 'muted' });
  assert.deepEqual(pills('failed')[2], { label: 'FAILED', tone: 'fail' });
  assert.deepEqual(pills('failed')[3], { label: 'SKIPPED', tone: 'muted' });
  const v = setupView(FX.failed, NOW);
  assert.equal(v.stations.length, 7);
  assert.deepEqual(v.stations.map((s) => s.station), STATIONS);
  // detail: the error code on a failed step, retry n after a retry, else the purpose
  assert.equal(v.stations[2].detail, 'app_no_issues_write');
  const retried = setupView(fixture('running', ['done', 'done', 'running', 'queued', 'queued', 'queued', 'queued'], { 2: { retries: 2 } }), NOW);
  assert.equal(retried.stations[2].detail, 'retry 2');
  assert.ok(v.stations[0].detail && v.stations[0].detail !== 'retry 0', v.stations[0].detail);
});

test('V3 formatDuration: seconds, minutes, hours; a running step uses now; no start is null', () => {
  assert.equal(formatDuration(T0, T1, NOW), '42s');
  assert.equal(formatDuration(T0, null, NOW), '3m 05s');
  assert.equal(formatDuration(T0, '2026-10-22T11:02:30Z', NOW), '1h 02m');
  assert.equal(formatDuration(null, null, NOW), null);
  const v = setupView(FX.running, NOW);
  assert.equal(v.stations[0].duration, '42s');
  assert.equal(v.stations[3].duration, '3m 05s');
  assert.equal(v.stations[4].duration, null);
});

test('V4 the fix link is only for app_no_issues_write; an excerpt is text, never HTML', () => {
  assert.equal(FIX_LINKS.app_no_issues_write, 'https://github.com/settings/installations');
  const linkFor = (code) => setupView(fixture('failed', ['done', 'done', 'failed', 'skipped', 'skipped', 'skipped', 'skipped'], { 2: { error_code: code } }), NOW).stations[2].fix;
  assert.equal(linkFor('app_no_issues_write').href, 'https://github.com/settings/installations');
  for (const code of ['station_failed', 'box_unreachable', 'tracker_not_built', null, '', 'APP_NO_ISSUES_WRITE', 'toString', '__proto__']) {
    const fix = linkFor(code);
    assert.ok(fix, `a failed step has a fix box (${code})`);
    assert.equal(fix.href, null, `no link for ${code}`);
    assert.equal(fix.retry, true);
  }
  // Only the failed step has a fix box.
  assert.deepEqual(setupView(FX.failed, NOW).stations.map((s) => Boolean(s.fix)), [false, false, true, false, false, false, false]);

  const evil = fixture('failed', ['done', 'done', 'failed', 'skipped', 'skipped', 'skipped', 'skipped'], {
    2: { log_excerpt: '<script>alert(1)</script> <img src=x onerror=alert(2)>' }
  });
  const view = setupView(evil, NOW);
  const out = render(h(StationList, { view, busy: null, onRetry: () => {} }));
  // Text is escaped at `<` (preact-render-to-string leaves `>` as is), which
  // is what keeps a tag from opening.
  assert.ok(out.includes('&lt;script>alert(1)&lt;/script>'), out);
  assert.ok(out.includes('&lt;img src=x onerror=alert(2)>'), out);
  assert.ok(!out.includes('<script'), 'a <script> tag rendered');
  assert.ok(!out.includes('<img'), 'an <img> tag rendered');
  assert.match(out, /<ol class="setup-stations"/);
  assert.equal((out.match(/<li\b/g) || []).length, 7);
  assert.match(out, /class="setup-fixbox"/);
  assert.match(out, /<button[^>]*class="btn setup-retry"/);
  assert.match(out, /<a[^>]*class="btn setup-fix"[^>]*href="https:\/\/github.com\/settings\/installations"/);
  // The log pane lists each step's excerpt.
  assert.deepEqual(view.log.map((l) => l.station), ['register', 'prompt', 'label', 'box', 'clone', 'smoke', 'ready']);
});

test('V5 Open only on done, Cancel on queued|running|failed, a poll only while live', () => {
  const pick = (k) => { const v = setupView(FX[k], NOW); return [v.openEnabled, v.canCancel, v.live]; };
  assert.deepEqual(pick('queued'), [false, true, true]);
  assert.deepEqual(pick('running'), [false, true, true]);
  assert.deepEqual(pick('failed'), [false, true, false]);
  assert.deepEqual(pick('done'), [true, false, false]);
  assert.deepEqual(pick('cancelled'), [false, false, false]);
  assert.equal(setupView(FX.done, NOW).openHref, '/p/demo');
  assert.equal(setupView(FX.running, NOW).openHref, null);
  // A retry button only on a failed run.
  assert.equal(setupView(FX.failed, NOW).stations[2].fix.retry, true);
  for (const s of ['queued', 'running']) assert.equal(nextPollMs(s), 5000, s);
  assert.equal(nextPollMs(undefined), 5000);
  assert.equal(nextPollMs(null), 5000);
  for (const s of ['done', 'failed', 'cancelled']) assert.equal(nextPollMs(s), 0, s);
});

test('V6 acceptAnswer: only the latest request paints', () => {
  assert.equal(acceptAnswer(3, 3), true);
  assert.equal(acceptAnswer(2, 3), false);
  assert.equal(acceptAnswer(1, 2), false);
});

// ── W1: the coord proxy rows ──────────────────────────────────────────────
const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'harness-secret-fixture';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{"id":"x","state":"queued"}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const call = (rest, method, body) => onRequest({
  request: new Request(`https://console.example.test/api/coord/${rest}`, {
    method, headers: { cookie: `dash=bh7950-${++cookieSeq}`, 'content-type': 'application/json' }, body
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: rest.split('/') }
});

test('W1 retry and cancel are two POST rows; create, beat and other shapes are not this fragment\'s', async () => {
  const frag = (await import('../functions/_lib/coord-writes.d/7934-onboarding.js')).default;
  assert.equal(frag.length, 2);
  const accepts = (row, rest) => row.method === 'POST' && (typeof row.path === 'function' ? row.path(rest) : row.path === rest);
  for (const verb of ['retry', 'cancel']) {
    const rest = `onboarding/runs/${RUN_ID}/${verb}`;
    assert.equal(ROUTES.filter((r) => accepts(r, rest)).length, 1, `${verb}: exactly one composed row`);
    assert.equal(frag.filter((r) => accepts(r, rest)).length, 1, `${verb}: the row is this fragment's`);
  }
  for (const r of frag) assert.deepEqual(r.body, []);
  for (const rest of ['onboarding/runs', `onboarding/runs/${RUN_ID}`, `onboarding/runs/${RUN_ID}/beat`,
    'onboarding/runs/../retry', 'onboarding/runs/./cancel', `onboarding/runs/${RUN_ID.toUpperCase().replace('OB_', 'ob_')}/retry`,
    `onboarding/runs/${RUN_ID}/retry/x`, `x/onboarding/runs/${RUN_ID}/retry`]) {
    assert.equal(frag.filter((r) => accepts(r, rest)).length, 0, `no row for ${rest}`);
  }
});

test('W1b through the proxy: retry forwards {actor} only; beat stays 405; a GET passes as-is', async () => {
  const f = stubFetch();
  try {
    const res = await call(`onboarding/runs/${RUN_ID}/retry`, 'POST', JSON.stringify({ state: 'done', retries: 9 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/onboarding/runs/${RUN_ID}/retry`);
    assert.equal(f.seen[0].method, 'POST');
    assert.deepEqual(Object.keys(JSON.parse(f.seen[0].body)), ['actor']);
    const c = await call(`onboarding/runs/${RUN_ID}/cancel`, 'POST', '{}');
    assert.equal(c.status, 200);
    assert.equal(f.seen[1].url, `${JOBS}/api/onboarding/runs/${RUN_ID}/cancel`);
    const beat = await call(`onboarding/runs/${RUN_ID}/beat`, 'POST', '{}');
    assert.equal(beat.status, 405);
    const g = await call(`onboarding/runs/${RUN_ID}`, 'GET');
    assert.equal(g.status, 200);
    assert.equal(f.seen.length, 3);
    assert.equal(f.seen[2].url, `${JOBS}/api/onboarding/runs/${RUN_ID}`);
  } finally {
    f.restore();
  }
});

test('W2 the screen route and the api methods are wired', async () => {
  const { ROUTES: APP_ROUTES } = await import('../src/app.js');
  const row = APP_ROUTES.find(([p]) => p === '/projects/:project/setup/:runId');
  assert.ok(row, 'the /projects/:project/setup/:runId route exists');
  assert.equal(row[1], SL.SetupLineScreen);
  const { api } = await import('../src/api.js');
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push([init.method || 'GET', url, init.body]);
    return new Response('{"ok":true}', { status: 200 });
  };
  try {
    await api.setupRun(RUN_ID);
    await api.setupRetry(RUN_ID);
    await api.setupCancel(RUN_ID);
  } finally {
    globalThis.fetch = real;
  }
  assert.deepEqual(seen, [
    ['GET', `/api/coord/onboarding/runs/${RUN_ID}`, undefined],
    ['POST', `/api/coord/onboarding/runs/${RUN_ID}/retry`, '{}'],
    ['POST', `/api/coord/onboarding/runs/${RUN_ID}/cancel`, '{}']
  ]);
});

test('E1 the project page reaches the setup line: its link opens SetupLineScreen with the run id', async () => {
  // app.js reads window at import; give it the least it needs.
  globalThis.window = globalThis.window || {
    location: { pathname: '/p/demo', search: '', hash: '' },
    dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
    history: { pushState() {}, replaceState() {} }, scrollTo() {},
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }
  };
  const { ROUTES: APP_ROUTES } = await import('../src/app.js');
  const { matchRoute } = await import('../src/router.js');
  const { SetupRunLinkView, setupLinkFor, SetupRunLink } = SL;

  const latest = { run: { id: RUN_ID, state: 'failed', created_at: T0 } };
  const out = render(h(SetupRunLinkView, { project: 'demo', data: latest }));
  const href = (out.match(/href="([^"]+)"/) || [])[1];
  assert.equal(href, `/projects/demo/setup/${RUN_ID}`);
  assert.match(out, />SETUP FAILED</);

  const hit = APP_ROUTES.map(([pat, C]) => [matchRoute(pat, href), C]).find(([m]) => m);
  assert.ok(hit, `${href} matches a route`);
  assert.equal(hit[1], SL.SetupLineScreen);
  assert.deepEqual(hit[0], { project: 'demo', runId: RUN_ID });

  // No run, or a failed read: no link, and nothing else on the page changes.
  assert.equal(setupLinkFor('demo', { run: null }), null);
  assert.equal(setupLinkFor('demo', null), null);
  assert.equal(render(h(SetupRunLinkView, { project: 'demo', data: { run: null } })), '');

  // The project page itself mounts the link next to its other header links.
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../src/screens/Project.js', import.meta.url), 'utf8');
  assert.match(src, /import \{ SetupRunLink \} from '\.\/SetupLine\.js';/);
  assert.match(src, /<\$\{SetupRunLink\} project=\$\{project\}\/>/);
  assert.equal(typeof SetupRunLink, 'function');
});
