import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/prompts/[[path]].js';

// BH-7969 (BH-7940.0): the /api/prompts proxy adds the bearer server side,
// admits only the known segment values and shapes, stamps `author` itself and
// never sends the browser cookie to harness-jobs. fetch is stubbed: 0 network.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'sec-fixture-1';

// probe: 200 | 401 | 'throw'. jobs: 'ok' | 'throw'.
function stubFetch({ probe = 200, jobs = 'ok' } = {}) {
  const probes = [];
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url.startsWith(CONSOLE)) {
      probes.push({ url, headers: init.headers || {} });
      if (probe === 'throw') throw new Error('console down');
      return new Response('', { status: probe });
    }
    seen.push({ url, method: init.method, headers: new Headers(init.headers || {}), body: init.body });
    if (jobs === 'throw') throw new Error('jobs down');
    return new Response('{"ok":true}', {
      status: 200,
      headers: { 'content-type': 'application/json', 'content-encoding': 'gzip', 'content-length': '11' }
    });
  };
  return { probes, seen, restore: () => { globalThis.fetch = real; } };
}

let seq = 0;
function call({ method = 'GET', segs = [], search = '', body, cookie, env } = {}) {
  const c = cookie === undefined ? `dash=bh7969-fixture-${++seq}` : cookie;
  const headers = { 'content-type': 'application/json' };
  if (c) headers.cookie = c;
  return onRequest({
    request: new Request(`https://console.example.pages.dev/api/prompts/${segs.join('/')}${search}`, { method, headers, body }),
    env: env || { HARNESS_SECRET: SECRET },
    params: { path: segs }
  });
}

test('no HARNESS_SECRET is 503 and sends nothing', async () => {
  const f = stubFetch();
  try {
    const res = await call({ env: {} });
    assert.equal(res.status, 503);
    assert.match((await res.json()).error, /HARNESS_SECRET/);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('console probe 401 is 403 unauthorized and no jobs fetch', async () => {
  const f = stubFetch({ probe: 401 });
  try {
    const res = await call({ search: '?project=alpha' });
    assert.equal(res.status, 403);
    assert.equal((await res.json()).error, 'unauthorized');
    assert.equal(f.probes.length, 1);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('console probe throw is 403 (fails closed)', async () => {
  const f = stubFetch({ probe: 'throw' });
  try {
    const res = await call({ segs: ['project', 'plan', '3'], search: '?project=alpha' });
    assert.equal(res.status, 403);
    assert.equal((await res.json()).error, 'unauthorized');
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('no cookie is 403 and no jobs fetch', async () => {
  const f = stubFetch();
  try {
    const res = await call({ cookie: '' });
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('GET list forwards ?project= only, with the bearer and no cookie', async () => {
  const f = stubFetch();
  try {
    const res = await call({ search: '?project=alpha-1&smuggled=1&author=mallory' });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/prompts?project=alpha-1`);
    assert.equal(f.seen[0].method, 'GET');
    assert.equal(f.seen[0].headers.get('authorization'), `Bearer ${SECRET}`);
    assert.equal(f.seen[0].headers.get('cookie'), null);
    assert.equal(res.headers.get('content-encoding'), null);
    assert.equal(res.headers.get('content-length'), null);
    assert.equal((await res.json()).ok, true);
  } finally { f.restore(); }
});

test('GET list with no project sends no query string', async () => {
  const f = stubFetch();
  try {
    const res = await call({ search: '?smuggled=1' });
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/prompts`);
  } finally { f.restore(); }
});

test('GET 3-segment version read is forwarded', async () => {
  const f = stubFetch();
  try {
    const res = await call({ segs: ['project', 'fix-round', '12'], search: '?project=a.b-c_1' });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/prompts/project/fix-round/12?project=a.b-c_1`);
    assert.equal(f.seen[0].headers.get('authorization'), `Bearer ${SECRET}`);
  } finally { f.restore(); }
});

test('POST forwards the resolved actor and only body, note, base_version', async () => {
  const f = stubFetch();
  try {
    const sent = { body: 'new prompt', note: 'why', base_version: 4, author: 'mallory', scope: 'fleet', smuggled: 1 };
    const res = await call({ method: 'POST', segs: ['project', 'review'], search: '?project=alpha&author=mallory', body: JSON.stringify(sent) });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/prompts/project/review?project=alpha`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.get('cookie'), null);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.author, 'console');
    assert.equal(fwd.body, 'new prompt');
    assert.equal(fwd.note, 'why');
    assert.equal(fwd.base_version, 4);
    assert.deepEqual(Object.keys(fwd).sort(), ['author', 'base_version', 'body', 'note']);
  } finally { f.restore(); }
});

test('POST omits absent keys', async () => {
  const f = stubFetch();
  try {
    const res = await call({ method: 'POST', segs: ['fleet', 'rules'], body: JSON.stringify({ body: 'x' }) });
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(JSON.parse(f.seen[0].body)).sort(), ['author', 'body']);
  } finally { f.restore(); }
});

test('POST with a non-object body is 400 and sends nothing', async () => {
  const f = stubFetch();
  try {
    for (const body of ['[{"body":"x"}]', 'null', '"str"', '7', 'not json']) {
      const res = await call({ method: 'POST', segs: ['fleet', 'qa'], body });
      assert.equal(res.status, 400, body);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('PUT, DELETE, GET 2-segment, GET 1-segment, POST 3-segment, POST 0-segment are 405', async () => {
  const f = stubFetch();
  try {
    const cases = [
      ['PUT', ['project', 'plan'], '{"body":"x"}'],
      ['DELETE', ['project', 'plan', '1'], undefined],
      ['GET', ['project', 'plan'], undefined],
      ['GET', ['project'], undefined],
      ['POST', ['project', 'plan', '1'], '{"body":"x"}'],
      ['POST', [], '{"body":"x"}']
    ];
    for (const [method, segs, body] of cases) {
      const res = await call({ method, segs, search: '?project=alpha', body });
      assert.equal(res.status, 405, `${method} ${segs.join('/')}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('bad segment values are 400 with 0 jobs fetches each', async () => {
  const bad = [
    ['GET', ['..', 'plan', '1']],
    ['GET', ['project', '..', '1']],
    ['GET', ['project', 'plan', '..']],
    ['GET', ['%2e%2e', 'plan', '1']],
    ['GET', ['project', '%252e%252e', '1']],
    ['GET', ['team', 'plan', '1']],
    ['GET', ['project', 'deploy', '1']],
    ['GET', ['project', 'plan', '0']],
    ['GET', ['project', 'plan', '01']],
    ['GET', ['project', 'plan', '1234567890']],
    ['GET', ['project', '', '1']],
    ['POST', ['team', 'plan']],
    ['POST', ['project', 'deploy']],
    ['POST', ['', 'plan']]
  ];
  for (const [method, segs] of bad) {
    const f = stubFetch();
    try {
      const res = await call({ method, segs, search: '?project=alpha', body: method === 'POST' ? '{"body":"x"}' : undefined });
      assert.equal(res.status, 400, `${method} ${JSON.stringify(segs)}`);
      assert.equal(f.seen.length, 0, `${method} ${JSON.stringify(segs)}`);
    } finally { f.restore(); }
  }
});

test('a bad project param is 400 with 0 jobs fetches each', async () => {
  for (const p of ['../x', '.x', '_fleet', '..', '', 'a/b', 'a'.repeat(101)]) {
    const f = stubFetch();
    try {
      const res = await call({ search: `?project=${encodeURIComponent(p)}` });
      assert.equal(res.status, 400, p);
      assert.equal(f.seen.length, 0, p);
    } finally { f.restore(); }
  }
});

test('a string params.path is split like the array form', async () => {
  const f = stubFetch();
  try {
    const res = await onRequest({
      request: new Request('https://console.example.pages.dev/api/prompts/fleet/watcher/2', { headers: { cookie: 'dash=bh7969-fixture-str' } }),
      env: { HARNESS_SECRET: SECRET },
      params: { path: 'fleet/watcher/2' }
    });
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/prompts/fleet/watcher/2`);
  } finally { f.restore(); }
});

test('a QA read-only session POST is refused before the probe', async () => {
  const f = stubFetch();
  try {
    const res = await call({ method: 'POST', segs: ['fleet', 'execute'], cookie: 'dashqa=bh7969-fixture-qa', body: '{"body":"x"}' });
    assert.equal(res.status, 403);
    assert.match((await res.json()).error, /read-only/);
    assert.equal(f.probes.length, 0);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('a jobs fetch throw is 502', async () => {
  const f = stubFetch({ jobs: 'throw' });
  try {
    const res = await call({ search: '?project=alpha' });
    assert.equal(res.status, 502);
    assert.equal(f.seen.length, 1);
  } finally { f.restore(); }
});
