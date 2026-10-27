// BH-7999 (BH-7935.2): /projects/new, the two-step onboarding form.
//   L1  deriveProject table
//   L2  parseSlug accept/refuse table; L2b the same answers as the worker's parseRepoSlug
//   L3  derivePrefix table, prefixOk per case
//   L4  defaultTracker table
//   L5  runInputs passes the worker's canonicalInputs; empty base and prod are absent
//   L6  reviewLines; L6b canContinue
//   L7  makeStarter: one run per in-flight start, one key per form state, navigate;
//       then the real api.onboardRun sends one POST with Idempotency-Key
//   L8  startError: 404/405 the wave-1 sentence, 400 names the field, a failure clears the flight
//   L9  onboard.css: tokens only, scoped to .onboard, the 720px bar rule; main.js imports it
//   L10 the settings fragment seeds 0, 3000, 120 with INSERT OR IGNORE; knobInt reads them
//   L11 OnboardScreen renders the headline, the slug input and a disabled Continue
//   M1  the real OnboardScreen in a fake DOM: slug -> detect card -> Continue ->
//       GitHub Issues checked -> a double Start setup sends ONE POST with an
//       Idempotency-Key and navigates to the setup line
//   M2  detect answers: visible:false shows Install, error shows Retry, Issues off
//       preselects nothing and Start setup stays disabled
//   M3  a 404 create shows the wave-1 sentence and Start setup is enabled again
//   P1  the coord proxy forwards the key and the stamped actor
//   P2  the proxy refuses a missing or bad key with 400 and 0 upstream fetches
//   P3  one POST onboarding/runs row, this fragment's; steer forwards no key
//   F1  Fleet PROJECTS has a NEW link to /projects/new; a click routes to OnboardScreen
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, all, fire, isDisabled, type } from './helpers/fake-dom.bh-5750.js';

installDom();
const pushed = [];
globalThis.window.history.pushState = (_s, _t, to) => { pushed.push(to); };

const { render } = await import('preact-render-to-string');
const L = await import('../src/lib/onboard.js');
const { OnboardScreen } = await import('../src/screens/Onboard.js');
const { FleetScreen } = await import('../src/screens/Fleet.js');
const { FleetContext, ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { api } = await import('../src/api.js');
const { onRequest, ROUTES: COORD_ROUTES } = await import('../functions/api/coord/[[path]].js');

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');

// The worker modules import catalog/lanes.json, a git-ignored render. Without
// it the parity cases skip and say why; the console-side tables still run.
let W = null;
let wSkip = '';
try {
  W = {
    ...(await import('../../worker/jobs/src/routes/onboarding-repo.js')),
    ...(await import('../../worker/jobs/src/routes/onboarding.js'))
  };
} catch (e) {
  wSkip = `the worker modules do not import here (${e.code || e.message}); render catalog/lanes.json to run this case`;
  console.log(`# SKIP worker parity: ${wSkip}`);
}

const REALTOR = { segment: 'existing', slug: 'example-org/project-11', project: 'project-11', prefix: 'RA', tracker: 'github-issues', base: '', prod: '' };

// ── L1 ────────────────────────────────────────────────────────────────────
test('L1 deriveProject: the repo part, lower case, [a-z0-9-], at most 19 chars', () => {
  const cases = [
    ['example-org/project-11', 'project-11'],
    ['example-org/project-11', 'project-11'],
    ['https://github.com/example-org/project-11.git', 'project-11'],
    ['o/my.repo_x', 'my-repo-x'],
    ['o/abcdefghijklmnopqr-tuvwxyz', 'abcdefghijklmnopqr'],
    ['o/abcdefghijklmnopqrstuvwxy', 'abcdefghijklmnopqrs'],
    ['o/.hidden', 'hidden'],
    ['project-11', '']
  ];
  for (const [slug, want] of cases) assert.equal(L.deriveProject(slug), want, slug);
  for (const [slug, want] of cases) if (want) assert.ok(L.projectOk(want), `${want} is a valid project`);
});

// ── L2 ────────────────────────────────────────────────────────────────────
const ACCEPT = [
  ['example-org/project-11', 'example-org/project-11'],
  [' example-org/project-11 ', 'example-org/project-11'],
  ['https://github.com/example-org/project-11', 'example-org/project-11'],
  ['https://github.com/example-org/project-11.git', 'example-org/project-11'],
  ['https://github.com/example-org/project-11/tree/main', 'example-org/project-11'],
  ['a/b.c_d-e', 'a/b.c_d-e']
];
const REFUSE = ['project-11', 'owner/name x', 'owner/../x', 'owner/x?y', 'https://gitlab.com/a/b', 'http://github.com/a/b',
  'https://a@github.com/x/y', '/x', 'owner/', 'owner/.', 'owner/..', 'own_er/x', 'o/' + 'a'.repeat(101), 'o/' + 'a'.repeat(2047),
  null, 42, undefined, ''];

test('L2 parseSlug accepts owner/repo and github URLs, refuses the near misses', () => {
  for (const [raw, slug] of ACCEPT) assert.equal(L.parseSlug(raw)?.slug, slug, JSON.stringify(raw));
  assert.deepEqual(L.parseSlug('https://github.com/example-org/project-11.git'), { owner: 'example-org', repo: 'project-11', slug: 'example-org/project-11' });
  for (const raw of REFUSE) assert.equal(L.parseSlug(raw), null, `refuses ${JSON.stringify(raw)?.slice(0, 40)}`);
});

test('L2b parseSlug answers what the worker\'s parseRepoSlug answers', { skip: W ? false : wSkip }, () => {
  for (const raw of [...ACCEPT.map((a) => a[0]), ...REFUSE]) {
    assert.deepEqual(L.parseSlug(raw), W.parseRepoSlug(raw), JSON.stringify(raw)?.slice(0, 40));
  }
});

// ── L3 ────────────────────────────────────────────────────────────────────
test('L3 derivePrefix copies load-project.sh; prefixOk is the worker\'s prefix rule', () => {
  const cases = [
    ['project-11', 'RA', true], ['project-16', 'SL', true], ['cromford', 'BH', true],
    ['harness', 'HA', true], ['a', 'A', false], ['a--b', 'AB', true], ['x-y-z', 'XYZ', true], ['3d-app', '3A', false]
  ];
  for (const [name, want, ok] of cases) {
    assert.equal(L.derivePrefix(name), want, name);
    assert.equal(L.prefixOk(L.derivePrefix(name)), ok, `prefixOk(${want})`);
  }
  assert.equal(L.prefixOk('ABCDEFGHIJK'), false, 'at most 10');
  assert.equal(L.prefixOk('ra'), false, 'upper case only');
});

// ── L4 ────────────────────────────────────────────────────────────────────
test('L4 defaultTracker: Issues on picks GitHub Issues; off picks the board only when it is ready; unknown is not off', () => {
  const cases = [
    [{ has_issues: true }, false, 'github-issues'],
    [{ has_issues: true }, true, 'github-issues'],
    [{ has_issues: false }, false, null],
    [{ has_issues: false }, true, 'board'],
    [null, false, 'github-issues'],
    [{}, true, 'github-issues'],
    [{ has_issues: 'false' }, false, 'github-issues']
  ];
  for (const [facts, ready, want] of cases) assert.equal(L.defaultTracker(facts, ready), want, JSON.stringify([facts, ready]));
});

// ── L5 ────────────────────────────────────────────────────────────────────
test('L5 runInputs: the fields the worker keeps; empty base and prod are absent', () => {
  const inputs = L.runInputs(REALTOR);
  for (const [k, v] of Object.entries({ repo: 'example-org/project-11', project: 'project-11', tracker: 'github-issues', box: 'shared', prefix: 'RA' })) {
    assert.equal(inputs[k], v, k);
  }
  assert.equal('base' in inputs, false, 'an empty base is absent');
  assert.equal('prod' in inputs, false, 'an empty prod is absent');
  const full = L.runInputs({ ...REALTOR, slug: 'https://github.com/example-org/project-11.git', base: ' main ', prod: 'https://realtor.example.com' });
  assert.equal(full.repo, 'example-org/project-11');
  assert.equal(full.base, 'main');
  assert.equal(full.prod, 'https://realtor.example.com');
});

test('L5b the worker\'s canonicalInputs accepts runInputs as is', { skip: W ? false : wSkip }, () => {
  const c = W.canonicalInputs(L.runInputs(REALTOR));
  assert.equal(c.error, undefined, JSON.stringify(c));
  assert.equal(c.inputs.box, 'shared');
  assert.equal(c.inputs.tracker, 'github-issues');
  assert.equal(c.inputs.prefix, 'RA');
  assert.equal('base' in c.inputs, false);
  assert.equal('prod' in c.inputs, false);
});

// ── L6 ────────────────────────────────────────────────────────────────────
test('L6 reviewLines: six lines in order, AI account fleet pool, the last line', () => {
  const lines = L.reviewLines(REALTOR);
  assert.deepEqual(lines.map((l) => l.label), ['Repo', 'Project', 'Tracker', 'Box', 'AI account', null]);
  assert.equal(lines[0].value, 'example-org/project-11');
  assert.equal(lines[1].value, 'project-11 · prefix RA');
  assert.equal(lines[2].value, 'GitHub Issues');
  assert.equal(lines[3].value, 'Shared');
  assert.equal(lines[4].value, 'fleet pool');
  assert.equal(lines[5].value, 'Nothing is built until a ticket is labeled.');
  assert.equal(L.reviewLines({ ...REALTOR, tracker: null })[2].value, 'not picked');
});

test('L6b canContinue needs only a slug parseSlug accepts, on the Existing segment', () => {
  assert.equal(L.canContinue({ segment: 'existing', slug: 'example-org/project-11' }), true);
  assert.equal(L.canContinue({ segment: 'existing', slug: 'project-11' }), false);
  assert.equal(L.canContinue({ segment: 'new', slug: 'example-org/project-11' }), false);
  assert.equal(L.canStart(REALTOR), true);
  assert.equal(L.canStart({ ...REALTOR, tracker: null }), false);
  assert.equal(L.canStart({ ...REALTOR, prefix: '3A' }), false);
  assert.equal(L.canStart({ ...REALTOR, project: 'Realtor' }), false);
  assert.equal(L.canStart({ ...REALTOR, inFlight: true }), false);
});

// ── L7 ────────────────────────────────────────────────────────────────────
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const tick = () => new Promise((r) => setTimeout(r, 0));

test('L7 makeStarter: a double start sends one run; the key is kept per form state; navigate gets the run id', async () => {
  const calls = [];
  const went = [];
  let answer = async () => { await tick(); return { id: 'ob_0123456789abcdef0123', state: 'queued', created: true }; };
  const start = L.makeStarter({ run: (inputs, key) => { calls.push({ inputs, key }); return answer(); }, navigate: (to) => went.push(to), uuid: () => crypto.randomUUID() });
  const a = start(REALTOR);
  const b = start(REALTOR);
  assert.equal(a, b, 'the second start returns the in-flight promise');
  const r = await a;
  assert.equal(r.id, 'ob_0123456789abcdef0123');
  assert.equal(calls.length, 1, 'one run for a double start');
  assert.match(calls[0].key, UUID_RE);
  assert.deepEqual(went, ['/projects/project-11/setup/ob_0123456789abcdef0123']);

  answer = async () => { await tick(); const e = new Error('boom'); e.status = 500; throw e; };
  const failed = await start(REALTOR);
  assert.match(failed.error, /Could not start setup: boom/);
  assert.equal(calls[1].key, calls[0].key, 'a retry of the same inputs reuses its key');
  await start({ ...REALTOR, prefix: 'RX' });
  assert.notEqual(calls[2].key, calls[0].key, 'a changed field gets a new key');
  assert.equal(went.length, 1, 'no navigate after a failure');
});

test('L7b through the real api.onboardRun: one POST to /api/coord/onboarding/runs with Idempotency-Key', async (t) => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url, init });
    await tick();
    return new Response(JSON.stringify({ id: 'ob_00000000000000000a01', state: 'queued', created: true }), { status: 201 });
  };
  t.after(() => { globalThis.fetch = prev; });
  const went = [];
  const start = L.makeStarter({ run: api.onboardRun, navigate: (to) => went.push(to), uuid: () => crypto.randomUUID() });
  await Promise.all([start(REALTOR), start(REALTOR)]);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, '/api/coord/onboarding/runs');
  assert.equal(seen[0].init.method, 'POST');
  assert.match(seen[0].init.headers['Idempotency-Key'], UUID_RE);
  assert.equal(JSON.parse(seen[0].init.body).project, 'project-11');
  assert.deepEqual(went, ['/projects/project-11/setup/ob_00000000000000000a01']);
});

// ── L8 ────────────────────────────────────────────────────────────────────
test('L8 startError: 404/405 are the wave-1 sentence; 400 names the field; a failure clears the flight', async () => {
  const err = (status, body = null) => Object.assign(new Error(body && body.error ? body.error : `http_${status}`), { status, body });
  assert.equal(L.startError(err(404)), 'Setup runs are not live yet (wave 1, #7934).');
  assert.equal(L.startError(err(405, { error: 'method POST not allowed on /api/coord/onboarding/runs' })), 'Setup runs are not live yet (wave 1, #7934).');
  assert.equal(L.startError(err(400, { error: 'invalid_field', field: 'prefix' })), 'The setup service refused the prefix field.');
  assert.equal(L.startError(err(409, { error: 'idempotency_key_reused' })), 'This form was already used for another run. Change a field or reload.');
  assert.notEqual(L.startError(err(400, { error: 'invalid_field', field: 'prefix' })), L.startError(err(404)));
  let n = 0;
  const start = L.makeStarter({ run: async () => { n += 1; await tick(); throw err(404); }, navigate: () => assert.fail('no navigate'), uuid: () => crypto.randomUUID() });
  assert.equal((await start(REALTOR)).error, 'Setup runs are not live yet (wave 1, #7934).');
  await start(REALTOR);
  assert.equal(n, 2, 'a second start after a failure calls run again');
  const authStart = L.makeStarter({ run: async () => { const e = new Error('unauthorized'); e.name = 'AuthError'; throw e; }, navigate: () => {}, uuid: () => crypto.randomUUID() });
  await assert.rejects(authStart(REALTOR), /unauthorized/, 'an AuthError goes to the app shell');
});

// ── L9 ────────────────────────────────────────────────────────────────────
test('L9 onboard.css: no hex, every rule scoped to .onboard, the 720px bar rule; main.js imports it, Onboard.js does not', () => {
  const css = read('../src/onboard.css').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/);
  assert.doesNotMatch(css, /\brgba?\(/);
  const selectors = [...css.matchAll(/([^{}]+)\{/g)].map((m) => m[1].trim()).filter((s) => !s.startsWith('@'));
  assert.ok(selectors.length > 10, `rules found: ${selectors.length}`);
  for (const s of selectors) for (const part of s.split(',')) assert.match(part.trim(), /^\.onboard/, part.trim());
  const media = /@media \(max-width: 720px\) \{([\s\S]*?)\n\}/.exec(css);
  assert.ok(media, 'a 720px block');
  assert.match(media[1], /\.onboard-bar[^{]*\.btn\s*\{[^}]*flex:\s*1/);
  assert.match(read('../src/main.js'), /^import '\.\/onboard\.css';$/m);
  assert.doesNotMatch(read('../src/screens/Onboard.js'), /import\s+['"][^'"]+\.css['"]/);
});

// ── L10 ───────────────────────────────────────────────────────────────────
test('L10 the settings fragment seeds the three knobs; knobInt reads each and falls back on absent or bad', () => {
  const sql = read('../../worker/jobs/schema.d/202610270351-bh-7935-onboarding-board-ready.sql');
  assert.match(sql, /INSERT OR IGNORE INTO settings/);
  const rows = Object.fromEntries([...sql.matchAll(/\('([a-z_.]+)','([^']*)'/g)].map((m) => [m[1], m[2]]));
  assert.equal(rows['onboarding.product_board_ready'], '0');
  assert.equal(rows['onboarding.detect_poll_ms'], '3000');
  assert.equal(rows['onboarding.detect_poll_max_s'], '120');
  assert.equal(L.KNOBS.boardReady.key, 'onboarding.product_board_ready');
  assert.equal(L.KNOBS.pollMs.key, 'onboarding.detect_poll_ms');
  assert.equal(L.KNOBS.pollMaxS.key, 'onboarding.detect_poll_max_s');
  assert.equal(L.knobInt({ value: rows['onboarding.product_board_ready'] }, L.KNOBS.boardReady.fallback, 0), 0);
  assert.equal(L.knobInt({ value: '1' }, 0, 0), 1);
  assert.equal(L.knobInt({ value: rows['onboarding.detect_poll_ms'] }, 1), 3000);
  assert.equal(L.knobInt({ value: rows['onboarding.detect_poll_max_s'] }, 1), 120);
  assert.equal(L.knobInt(null, 3000), 3000);
  assert.equal(L.knobInt({ value: 'x' }, 3000), 3000);
  assert.equal(L.knobInt({ value: '0' }, 3000), 3000, '0 ms is not a poll interval');
  assert.deepEqual([L.KNOBS.boardReady.fallback, L.KNOBS.pollMs.fallback, L.KNOBS.pollMaxS.fallback], [0, 3000, 120]);
});

// ── L11 ───────────────────────────────────────────────────────────────────
test('L11 OnboardScreen renders the headline, the slug input with its datalist, and a disabled Continue', () => {
  const out = render(h(OnboardScreen));
  assert.match(out, /New project/);
  assert.match(out, /<input[^>]*id="onboard-slug"[^>]*list="onboard-repos"|<input[^>]*list="onboard-repos"[^>]*id="onboard-slug"/);
  assert.match(out, /<datalist id="onboard-repos"/);
  assert.match(out, /<button[^>]*disabled[^>]*>Continue<\/button>/);
  assert.match(out, /class="onboard"/);
});

// ── M: the real screen in a fake DOM ────────────────────────────────────────
const RUN_ID = 'ob_0123456789abcdef0123';
const FACTS = { default_branch: 'main', has_issues: true, open_issues: 4 };
const SETTINGS = { 'onboarding.product_board_ready': '0', 'onboarding.detect_poll_ms': '1', 'onboarding.detect_poll_max_s': '120' };

// A fetch that answers by path and keeps every call with its headers.
function screenFetch({ detect = () => ({ state: 'ok', visible: true, facts: FACTS, install_url: 'https://github.com/apps/x/installations/new' }), create } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', headers: init.headers || {}, body: init.body });
    let status = 200;
    let body = {};
    const set = /^\/api\/coord\/settings\/(.+)$/.exec(u);
    if (set) {
      const key = decodeURIComponent(set[1]);
      body = { setting: key in SETTINGS ? { key, value: SETTINGS[key] } : null };
    } else if (u === '/api/coord/onboarding/repos') body = { state: 'ok', repos: ['example-org/project-11', 'example-org/project-16'] };
    else if (u.startsWith('/api/coord/onboarding/repo?')) body = detect(u);
    else if (u === '/api/coord/onboarding/runs' && init.method === 'POST') {
      await tick();
      [status, body] = create ? create() : [201, { id: RUN_ID, state: 'queued', created: true }];
    }
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const mounted = new Set();
test.afterEach(() => { for (const root of mounted) mount(null, root); mounted.clear(); });
async function mountScreen(node) {
  const doc = installDom();
  globalThis.window.history.pushState = (_s, _t, to) => { pushed.push(to); };
  const root = doc.createElement('div');
  doc.appendChild(root);
  mount(node, root);
  mounted.add(root);
  await flush();
  return root;
}
const byId = (root, id) => all(root).find((n) => n.attrs && n.attrs.id === id);
const btn = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const cls = (root, c) => all(root).filter((n) => n.attrs && (n.attrs.class || '').split(/\s+/).includes(c));
const radio = (root, value) => all(root).find((n) => n.attrs && n.attrs.role === 'radio' && n.attrs['data-value'] === value);

async function toStep2(root, slug = 'example-org/project-11') {
  type(byId(root, 'onboard-slug'), slug);
  await waitFor(() => Boolean(cls(root, 'onboard-facts')[0]), 'the detect facts');
  await flush();
  fire(btn(root, 'Continue'), 'click');
  await flush();
}

test('M1 slug -> detect facts -> Continue -> GitHub Issues -> a double Start setup sends one keyed POST and navigates', async () => {
  const calls = screenFetch();
  pushed.length = 0;
  const root = await mountScreen(h(OnboardScreen));
  const reads = calls.map((c) => c.url);
  for (const u of ['/api/coord/onboarding/repos', '/api/coord/settings/onboarding.product_board_ready',
    '/api/coord/settings/onboarding.detect_poll_ms', '/api/coord/settings/onboarding.detect_poll_max_s']) {
    assert.ok(reads.includes(u), `read on mount: ${u}`);
  }
  assert.deepEqual(all(byId(root, 'onboard-repos')).filter((n) => n.localName === 'option').map((n) => n.attrs.value),
    ['example-org/project-11', 'example-org/project-16']);
  assert.equal(isDisabled(btn(root, 'Continue')), true, 'Continue is disabled with no slug');
  type(byId(root, 'onboard-slug'), 'project-11');
  await flush();
  assert.equal(isDisabled(btn(root, 'Continue')), true, 'Continue is disabled for a bare name');
  assert.equal(calls.filter((c) => c.url.startsWith('/api/coord/onboarding/repo?')).length, 0, 'no detect for a refused slug');
  type(byId(root, 'onboard-slug'), 'example-org/project-11');
  await waitFor(() => Boolean(cls(root, 'onboard-facts')[0]), 'the detect facts');
  await flush();
  assert.equal(isDisabled(btn(root, 'Continue')), false, 'Continue is enabled with a slug');
  const detects = calls.filter((c) => c.url.startsWith('/api/coord/onboarding/repo?'));
  assert.equal(detects[0].url, '/api/coord/onboarding/repo?slug=example-org%2Fproject-11');
  const facts = cls(root, 'onboard-facts')[0];
  assert.ok(facts, 'the facts list renders');
  assert.match(facts.textContent, /main/);
  const gh = all(facts).find((n) => n.localName === 'a');
  assert.equal(gh.attrs.href, 'https://github.com/example-org/project-11');
  assert.equal(byId(root, 'onboard-project').attrs.value, 'project-11');
  assert.equal(byId(root, 'onboard-prefix').attrs.value, 'RA');
  assert.equal(byId(root, 'onboard-base').attrs.value, 'main');
  const boxes = all(root).filter((n) => n.attrs && n.attrs.name === 'onboard-box');
  assert.deepEqual(boxes.map((n) => [n.attrs.value, isDisabled(n)]), [['shared', false], ['dedicated', true], ['fly', true]]);
  assert.match(cls(root, 'onboard-adv')[0].textContent, /wave 6/);

  fire(btn(root, 'Continue'), 'click');
  await flush();
  assert.equal(radio(root, 'github-issues').attrs['aria-checked'], 'true', 'GitHub Issues is preselected');
  assert.equal(isDisabled(radio(root, 'board')), true, 'the board is disabled at product_board_ready 0');
  assert.match(radio(root, 'board').textContent, /soon/);
  for (const v of ['linear', 'jira', 'app-board']) {
    assert.equal(isDisabled(radio(root, v)), true, `${v} disabled`);
    assert.match(radio(root, v).textContent, /wave 3/);
  }
  const review = cls(root, 'onboard-review')[0];
  assert.match(review.textContent, /fleet pool/);
  assert.match(review.textContent, /project-11 · prefix RA/);
  assert.match(review.textContent, /Nothing is built until a ticket is labeled\.$/);
  assert.equal(all(review).filter((n) => n.localName === 'input').length, 0, 'the AI account has no input');

  const startBtn = btn(root, 'Start setup');
  assert.equal(isDisabled(startBtn), false);
  fire(startBtn, 'click');
  fire(startBtn, 'click');
  await waitFor(() => pushed.length === 1, 'the navigate');
  await flush();
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1, 'a double click sends one POST');
  assert.equal(posts[0].url, '/api/coord/onboarding/runs');
  assert.match(posts[0].headers['Idempotency-Key'], UUID_RE);
  const sent = JSON.parse(posts[0].body);
  for (const [k, v] of Object.entries({ repo: 'example-org/project-11', project: 'project-11', tracker: 'github-issues', box: 'shared', prefix: 'RA', base: 'main' })) {
    assert.equal(sent[k], v, k);
  }
  assert.equal('prod' in sent, false, 'an empty prod is not sent');
  assert.deepEqual(pushed, [`/projects/project-11/setup/${RUN_ID}`]);
});

test('M2 detect states: visible:false shows Install, error shows Retry; Issues off preselects nothing', async () => {
  screenFetch({ detect: () => ({ state: 'ok', visible: false, install_url: 'https://github.com/apps/x/installations/new' }) });
  let root = await mountScreen(h(OnboardScreen));
  type(byId(root, 'onboard-slug'), 'example-org/project-11');
  await waitFor(() => all(root).some((n) => n.localName === 'a' && /Install/.test(n.textContent)), 'the Install link');
  await flush();
  const install = all(root).find((n) => n.localName === 'a' && /Install/.test(n.textContent));
  assert.equal(install && install.attrs.href, 'https://github.com/apps/x/installations/new');
  assert.ok(btn(root, 'Retry'), 'Retry next to Install');
  mount(null, root);

  let n = 0;
  const calls = screenFetch({ detect: () => { n += 1; return n === 1 ? { state: 'error', error: 'gh: 404 Not Found' } : { state: 'ok', visible: true, facts: FACTS }; } });
  root = await mountScreen(h(OnboardScreen));
  type(byId(root, 'onboard-slug'), 'example-org/project-11');
  await waitFor(() => /gh: 404 Not Found/.test(cls(root, 'onboard-detect')[0]?.textContent || ''), 'the detect error');
  await flush();
  assert.match(cls(root, 'onboard-detect')[0].textContent, /gh: 404 Not Found/);
  fire(btn(root, 'Retry'), 'click');
  await waitFor(() => Boolean(cls(root, 'onboard-facts')[0]), 'the facts after Retry');
  await flush();
  assert.equal(calls.filter((c) => c.url.startsWith('/api/coord/onboarding/repo?')).length, 2, 'Retry polls again');
  assert.ok(cls(root, 'onboard-facts')[0], 'the facts after a retry');
  mount(null, root);

  screenFetch({ detect: () => ({ state: 'ok', visible: true, facts: { ...FACTS, has_issues: false } }) });
  root = await mountScreen(h(OnboardScreen));
  await toStep2(root);
  for (const v of ['github-issues', 'board']) assert.equal(radio(root, v).attrs['aria-checked'], 'false', `${v} not checked`);
  assert.match(radio(root, 'github-issues').textContent, /Issues are off in this repo\. Turn them on in the repo settings, then pick this card\./);
  assert.equal(isDisabled(btn(root, 'Start setup')), true, 'no tracker, no start');
  fire(radio(root, 'github-issues'), 'click');
  await flush();
  assert.equal(isDisabled(btn(root, 'Start setup')), false, 'a pick enables Start setup');
});

test('M2b a pending detect stays a skeleton; Continue does not wait for it; a bad prefix blocks Start setup', async () => {
  const calls = screenFetch({ detect: () => ({ state: 'pending' }) });
  const root = await mountScreen(h(OnboardScreen));
  type(byId(root, 'onboard-slug'), 'o/3d-app');
  await waitFor(() => calls.filter((c) => c.url.startsWith('/api/coord/onboarding/repo?')).length >= 2, 'a second pending poll');
  await flush();
  assert.ok(all(cls(root, 'onboard-detect')[0]).some((n) => (n.attrs?.class || '').includes('skel')), 'the skeleton while pending');
  assert.equal(isDisabled(btn(root, 'Continue')), false);
  assert.equal(byId(root, 'onboard-prefix').attrs.value, '3A');
  assert.ok(all(root).some((n) => n.attrs && n.attrs.id === 'onboard-prefix-err'), 'an inline prefix error');
  fire(btn(root, 'Continue'), 'click');
  await flush();
  assert.equal(radio(root, 'github-issues').attrs['aria-checked'], 'true', 'unknown facts preselect GitHub Issues');
  assert.equal(isDisabled(btn(root, 'Start setup')), true, 'a refused prefix blocks the start');
});

test('M3 a 404 create shows the wave-1 sentence and Start setup is enabled again', async () => {
  const calls = screenFetch({ create: () => [404, { error: 'not_found' }] });
  pushed.length = 0;
  const root = await mountScreen(h(OnboardScreen));
  await toStep2(root);
  fire(btn(root, 'Start setup'), 'click');
  await waitFor(() => all(root).some((n) => n.attrs && n.attrs.role === 'alert'), 'the start error');
  await flush();
  const alert = all(root).find((n) => n.attrs && n.attrs.role === 'alert');
  assert.equal(alert && alert.textContent.trim(), 'Setup runs are not live yet (wave 1, #7934).');
  assert.equal(isDisabled(btn(root, 'Start setup')), false);
  assert.deepEqual(pushed, []);
  fire(btn(root, 'Start setup'), 'click');
  await waitFor(() => calls.filter((c) => c.method === 'POST').length === 2, 'the second POST');
  await flush();
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 2, 'a retry sends again');
  assert.equal(posts[1].headers['Idempotency-Key'], posts[0].headers['Idempotency-Key'], 'with the same key');
});

// ── P: the coord proxy ──────────────────────────────────────────────────────
const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
function proxyFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ id: RUN_ID, state: 'queued', created: true }), { status: 201, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const proxy = (rest, body, key) => onRequest({
  request: new Request(`https://console.example.test/api/coord/${rest}`, {
    method: 'POST',
    headers: { cookie: `dash=bh7999-${++cookieSeq}`, 'content-type': 'application/json', ...(key === undefined ? {} : { 'Idempotency-Key': key }) },
    body: JSON.stringify(body)
  }),
  env: { HARNESS_SECRET: 'harness-secret-fixture' },
  params: { path: rest.split('/') }
});
const RUN_BODY = { repo: 'example-org/project-11', project: 'project-11', tracker: 'github-issues', box: 'shared', prefix: 'RA', token: 'tok-fixture-1', actor: 'evil' };

test('P1 POST onboarding/runs forwards the key and the stamped actor, and only the allowed fields', async () => {
  const f = proxyFetch();
  try {
    const key = crypto.randomUUID();
    const res = await proxy('onboarding/runs', RUN_BODY, key);
    assert.equal(res.status, 201);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/onboarding/runs`);
    assert.equal(f.seen[0].headers['idempotency-key'], key);
    assert.equal(f.seen[0].headers['x-harness-actor'], 'console');
    const sent = JSON.parse(f.seen[0].body);
    assert.equal('token' in sent, false);
    assert.equal(sent.actor, 'console');
    assert.equal(sent.project, 'project-11');
    for (const k of ['abcdefgh', 'a'.repeat(128), 'k.1_2:3-4']) {
      assert.equal((await proxy('onboarding/runs', RUN_BODY, k)).status, 201, `forwards ${k.slice(0, 12)}`);
    }
  } finally { f.restore(); }
});

test('P2 a missing or bad key is a 400 idempotency_key_required with 0 upstream fetches', async () => {
  const f = proxyFetch();
  try {
    for (const k of [undefined, '', '   ', 'abc', 'abcdefg', 'a'.repeat(129), 'a b c d e f', 'key/../x']) {
      const res = await proxy('onboarding/runs', RUN_BODY, k);
      assert.equal(res.status, 400, `refuses ${JSON.stringify(k)?.slice(0, 12)}`);
      assert.equal((await res.json()).error, 'idempotency_key_required');
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('P3 one POST onboarding/runs row, from this fragment; a row without the field forwards no key', async () => {
  const frag = (await import('../functions/_lib/coord-writes.d/7935-onboarding-runs.js')).default;
  const rows = COORD_ROUTES.filter((r) => r.method === 'POST' && r.path === 'onboarding/runs');
  assert.equal(rows.length, 1);
  assert.equal(rows[0], frag[0]);
  assert.equal(rows[0].idempotencyKey, true);
  assert.equal(COORD_ROUTES.filter((r) => r.idempotencyKey).length, 1, 'no other row opts in');
  const f = proxyFetch();
  try {
    await proxy('steer', { project: 'demo', text: 'hello' }, crypto.randomUUID());
    assert.equal(f.seen.length, 1);
    assert.equal('idempotency-key' in f.seen[0].headers, false);
    assert.equal('x-harness-actor' in f.seen[0].headers, false);
  } finally { f.restore(); }
});

// ── F1: the entry point ─────────────────────────────────────────────────────
test('F1 Fleet PROJECTS has a NEW link to /projects/new, and the click routes to OnboardScreen', async () => {
  globalThis.fetch = async (url) => {
    const u = String(url);
    const body = u === '/api/dash/projects' ? { projects: [], projects_source: 'fleet_status', snapshot_age_min: 1 } : {};
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  pushed.length = 0;
  const root = await mountScreen(h(FleetContext.Provider, { value: { data: null } }, h(FleetScreen)));
  const head = all(root).find((n) => (n.attrs?.class || '') === 'section__head' && /PROJECTS/.test(n.textContent) && !/MACHINES/.test(n.textContent));
  assert.ok(head, 'the PROJECTS section head');
  const link = all(head).find((n) => n.localName === 'a' && n.attrs.href === '/projects/new');
  assert.ok(link, 'a NEW link in the PROJECTS head');
  assert.equal(link.textContent.trim(), 'NEW');
  fire(link, 'click');
  assert.deepEqual(pushed, ['/projects/new']);
  const route = ROUTES.find(([p]) => matchRoute(p, pushed[0]));
  assert.equal(route && route[1], OnboardScreen, '/projects/new opens OnboardScreen');
});

