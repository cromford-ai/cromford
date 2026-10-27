// BH-7997 (BH-7935 wave 2, order 1): the six api.onboard* wrappers and the two
// onboarding ROUTES rows.
//   A1  each wrapper hits /api/coord/onboarding/... with its method and encoded params
//   A2  onboardRun and onboardRepoCreate send Idempotency-Key and a JSON body
//   A3  the four GET wrappers send no Idempotency-Key and no body
//   A4  a wrapper answers the worker's parsed body; an error status throws
//   U1  ROUTES resolves /projects/new and /projects/:project/ready, /p/x is
//       unchanged, and the placeholder screens render their headings
import test from 'node:test';
import assert from 'node:assert/strict';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const { h } = await import('preact');
const { api } = await import('../src/api.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { OnboardScreen } = await import('../src/screens/Onboard.js');
const { ProjectReadyScreen } = await import('../src/screens/ProjectReady.js');
const { ProjectScreen } = await import('../src/screens/Project.js');

// A fake fetch that records each call and answers `answer` (default 200 {ok:true}).
function recordFetch(t, answer = { status: 200, body: { ok: true } }) {
  const calls = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, method: init.method || 'GET', headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify(answer.body), { status: answer.status, headers: { 'content-type': 'application/json' } });
  };
  t.after(() => { globalThis.fetch = prev; });
  return calls;
}

const headerOf = (c, name) => {
  const k = Object.keys(c.headers).find((x) => x.toLowerCase() === name.toLowerCase());
  return k === undefined ? undefined : c.headers[k];
};

test('(A1) each wrapper hits /api/coord/onboarding/... with its method and encoded params', async (t) => {
  const calls = recordFetch(t);
  await api.onboardRepo('https://github.com/example-org/project-11?x=1&y');
  await api.onboardRepos();
  await api.onboardRun({ slug: 'example-org/project-11' }, 'k-run-1');
  await api.onboardReady('realtor ai/x');
  await api.onboardRepoCreate({ owner: 'example-org', name: 'x', template: 'nextjs' }, 'k-create-1');
  await api.onboardRepoCreateState('id/7?');
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/onboarding/repo?slug=https%3A%2F%2Fgithub.com%2Fexample-org%2Fproject-11%3Fx%3D1%26y'],
    ['GET', '/api/coord/onboarding/repos'],
    ['POST', '/api/coord/onboarding/runs'],
    ['GET', '/api/coord/onboarding/ready/realtor%20ai%2Fx'],
    ['POST', '/api/coord/onboarding/repo-create'],
    ['GET', '/api/coord/onboarding/repo-create/id%2F7%3F'],
  ]);
});

test('(A2) onboardRun and onboardRepoCreate send Idempotency-Key and a JSON body', async (t) => {
  const calls = recordFetch(t);
  await api.onboardRun({ slug: 'example-org/project-11', template: null }, 'k-run-1');
  await api.onboardRepoCreate({ owner: 'example-org', name: 'x', template: 'nextjs' }, 'k-create-1');
  assert.equal(headerOf(calls[0], 'Idempotency-Key'), 'k-run-1');
  assert.equal(headerOf(calls[0], 'content-type'), 'application/json');
  assert.deepEqual(JSON.parse(calls[0].body), { slug: 'example-org/project-11', template: null });
  assert.equal(headerOf(calls[1], 'Idempotency-Key'), 'k-create-1');
  assert.deepEqual(JSON.parse(calls[1].body), { owner: 'example-org', name: 'x', template: 'nextjs' });
});

test('(A3) the four GET wrappers send no Idempotency-Key and no body', async (t) => {
  const calls = recordFetch(t);
  await api.onboardRepo('example-org/project-11');
  await api.onboardRepos();
  await api.onboardReady('project-11');
  await api.onboardRepoCreateState('7');
  assert.equal(calls.length, 4);
  for (const c of calls) {
    assert.equal(c.method, 'GET');
    assert.equal(headerOf(c, 'Idempotency-Key'), undefined);
    assert.equal(c.body, undefined);
  }
});

test('(A4) a wrapper answers the parsed body; a 400 throws with the worker error', async (t) => {
  recordFetch(t, { status: 200, body: { state: 'pending' } });
  assert.deepEqual(await api.onboardRepo('example-org/project-11'), { state: 'pending' });
  globalThis.fetch = async () => new Response(JSON.stringify({ error: 'slug must be owner/repo or https://github.com/owner/repo' }), { status: 400 });
  await assert.rejects(api.onboardRepo('nope'), (e) => e.status === 400 && /slug must be/.test(e.message));
});

const resolve = (path) => {
  for (const [pattern, screen] of ROUTES) {
    const params = matchRoute(pattern, path);
    if (params) return { screen, params };
  }
  return null;
};

test('(U1) ROUTES resolves the two onboarding paths; /p/x is unchanged', () => {
  const a = resolve('/projects/new');
  assert.equal(a.screen, OnboardScreen);
  const b = resolve('/projects/project-11/ready');
  assert.equal(b.screen, ProjectReadyScreen);
  assert.deepEqual(b.params, { project: 'project-11' });
  const c = resolve('/p/x');
  assert.equal(c.screen, ProjectScreen);
  assert.deepEqual(c.params, { project: 'x' });
});

// The page headline's first line, as the h1 renders it.
const headline = (html) => (/<h1 class="line-headline">([^<]*)<br\/>/.exec(html) || [])[1];

test('(U1) the placeholder screens render their headings', () => {
  assert.equal(headline(render(h(OnboardScreen, {}))), 'New project');
  assert.equal(headline(render(h(ProjectReadyScreen, { project: 'project-11' }))), 'Ready: project-11');
  assert.equal(headline(render(h(ProjectReadyScreen, { project: '<b>x</b>' }))), 'Ready: &lt;b>x&lt;/b>');
});
