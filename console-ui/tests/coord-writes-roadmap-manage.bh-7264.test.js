import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-7264 (BH-7243.1): the roadmap move and edit write through the coord
// proxy as POST `roadmap/ideas/move` and `roadmap/ideas/edit`
// (coord-writes.d/7243-roadmap-ideas-manage.js). The proxy stamps the actor,
// forwards only the listed fields, keeps expected_version a number, and
// refuses a signed-out session. The harness is coord-writes-roadmap.bh-7243:
// the real onRequest, fetch stubbed.
//
// W1 move forwards id, project, to_lane, expected_version (a number) and
//    reason; an injected actor is overwritten and `version` is dropped
// W2 edit forwards its 7 fields
// W3 signed out: 403 and nothing is forwarded; an object value is refused

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
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh7264-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const MOVE = { id: 'i-1', project: 'cromford', to_lane: 'next', expected_version: 3, reason: 'top' };
const EDIT = { id: 'i-1', project: 'cromford', title: 'T', note: 'n', link: 'https://example.com/a', source: 'qa', expected_version: 2 };

test('W1 move forwards its 5 fields with expected_version a number, and stamps the actor', async () => {
  const f = stubFetch();
  try {
    const res = await call('roadmap/ideas/move', 'POST', JSON.stringify({ ...MOVE, actor: 'evil', version: 9, lane: 'x' }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/roadmap/ideas/move`);
    assert.equal(f.seen[0].method, 'POST');
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.actor, 'console');
    for (const k of Object.keys(MOVE)) assert.equal(fwd[k], MOVE[k], k);
    assert.equal(typeof fwd.expected_version, 'number');
    assert.equal('version' in fwd, false);
    assert.equal('lane' in fwd, false);
  } finally { f.restore(); }
});

test('W2 edit forwards its 7 fields and stamps the actor', async () => {
  const f = stubFetch();
  try {
    const res = await call('roadmap/ideas/edit', 'POST', JSON.stringify({ ...EDIT, idem_key: 'k', actor: 'evil' }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/roadmap/ideas/edit`);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.actor, 'console');
    for (const k of Object.keys(EDIT)) assert.equal(fwd[k], EDIT[k], k);
    assert.equal('idem_key' in fwd, false);
  } finally { f.restore(); }
});

test('W3 signed out is 403 and forwards nothing; other verbs are 405', async () => {
  const f = stubFetch({ signedIn: false });
  try {
    assert.equal((await call('roadmap/ideas/move', 'POST', JSON.stringify(MOVE))).status, 403);
    assert.equal((await call('roadmap/ideas/edit', 'POST', JSON.stringify(EDIT))).status, 403);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
  const g = stubFetch();
  try {
    for (const [rest, method] of [['roadmap/ideas/move', 'PUT'], ['roadmap/ideas/edit', 'DELETE']]) {
      assert.equal((await call(rest, method, JSON.stringify(MOVE))).status, 405, `${method} ${rest}`);
    }
    assert.equal(g.seen.length, 0);
  } finally { g.restore(); }
});
