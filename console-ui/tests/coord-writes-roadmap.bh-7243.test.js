import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-7263 (BH-7243.0): the roadmap idea add writes through the coord proxy as
// POST `roadmap/ideas` exactly (coord-writes.d/7243-roadmap-ideas.js). The
// proxy stamps the actor, forwards only the six idea fields as strings, and
// refuses a signed-out session. Same harness shape as
// coord-steer-allowlist.bh-5839.test.js: the real onRequest, fetch stubbed.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'fixture-harness-secret';

function stubFetch({ signedIn = true } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: signedIn ? 200 : 403 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 201, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh7243-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const IDEA = {
  project: 'cromford', title: 'Roadmap tracer', note: 'n', source: 'operator', link: 'https://example.com/a', idem_key: 't1'
};

test('C1 signed out: 403 and nothing is forwarded', async () => {
  const f = stubFetch({ signedIn: false });
  try {
    const res = await call('roadmap/ideas', 'POST', JSON.stringify(IDEA));
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('C2 signed in: the six fields travel to /api/roadmap/ideas and the browser actor is overwritten', async () => {
  const f = stubFetch();
  try {
    const res = await call('roadmap/ideas', 'POST', JSON.stringify({ ...IDEA, actor: 'evil' }));
    assert.equal(res.status, 201);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/roadmap/ideas`);
    assert.equal(f.seen[0].method, 'POST');
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.actor, 'console');
    for (const k of Object.keys(IDEA)) assert.equal(fwd[k], IDEA[k], k);
  } finally { f.restore(); }
});

test('C3 an extra field is dropped; other verbs and sub-paths are 405 and forward nothing', async () => {
  const f = stubFetch();
  try {
    await call('roadmap/ideas', 'POST', JSON.stringify({ ...IDEA, version: 9, lane: 'next' }));
    assert.equal(f.seen.length, 1);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal('version' in fwd, false);
    assert.equal('lane' in fwd, false);
    for (const [rest, method] of [['roadmap/ideas', 'PUT'], ['roadmap/ideas/delete', 'POST'], ['roadmap/ideas', 'DELETE']]) {
      const res = await call(rest, method, JSON.stringify(IDEA));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 1);
  } finally { f.restore(); }
});
