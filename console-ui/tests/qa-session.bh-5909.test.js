import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest as qaLogin } from '../functions/qa-login/[token].js';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';
import { onRequest as dash } from '../functions/api/[[path]].js';
import { qaOnly } from '../functions/_lib/qa-session.js';

// cromford #5909, slice 1. Browser QA of a console preview signs in with
// a READ-ONLY session the hub mints from the console worker
// (POST /api/qa/session, Bearer HARNESS_SECRET; cromford-console #46),
// never with the operator's login link.
//
//   S1  /qa-login/<token> on a preview host is proxied to the worker's
//       /qa-login/<token>; its Set-Cookie (dashqa) lands on this origin and
//       the redirect goes to /
//   S2  /qa-login/ on the production host is refused (403) and the worker is
//       never asked: a QA session is for previews only
//   S3  a bad token: the worker's 403 comes through unchanged
//   S4  qaOnly: a `dashqa` cookie with no `dash` cookie is a QA session; a
//       `dash` cookie (with or without dashqa) is the operator
//   S5  /api/coord: a QA session's write (PUT flags) is refused 403 before the
//       jobs worker is called, although its read probe answers 200
//   S6  /api/coord: a QA session's GET still reads
//   S7  /api/*: a QA session's POST is refused 403 before the worker is called
//   S8  a production deployment's own <8-hex>.<project> host is refused
//   S9  with CF_PAGES_BRANCH set, the host must be that branch's alias, never main
//   S11 the production-branch alias main.<project> is refused with no
//       CF_PAGES_BRANCH (a direct-upload deploy does not set it at runtime)
//   S10 a write that carries dashqa is refused even beside a (forged) dash cookie

const PREVIEW = 'https://ticket-bh-5909.console.example.pages.dev';
const PROD = 'https://console.example.pages.dev';
const TOKEN = '1791700000.' + 'ab'.repeat(32);
const QA = `dashqa=${TOKEN}`;
const OP = 'dash=' + 'cd'.repeat(32);

function fakeFetch(t, { probe = 200, qaLoginStatus = 302 } = {}) {
  const seen = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    const u = new URL(String(url));
    seen.push({ url: u.href, path: u.pathname, method: init.method || 'GET' });
    if (u.pathname.startsWith('/qa-login/')) {
      const h = new Headers();
      if (qaLoginStatus === 302) {
        h.set('location', '/');
        h.set('set-cookie', `dashqa=${decodeURIComponent(u.pathname.slice(10))}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=1700`);
        return new Response(null, { status: 302, headers: h });
      }
      return new Response('nope', { status: qaLoginStatus });
    }
    if (u.pathname === '/api/dash/fleet') return new Response('{}', { status: probe });
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } });
  });
  return seen;
}

test('S1 a preview host proxies /qa-login/ and keeps the cookie on this origin', async (t) => {
  const seen = fakeFetch(t);
  const res = await qaLogin({ request: new Request(`${PREVIEW}/qa-login/${TOKEN}`), params: { token: TOKEN } });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/');
  assert.match(res.headers.get('set-cookie') || '', new RegExp(`^dashqa=${TOKEN.replace('.', '\\.')};`));
  assert.equal(seen.length, 1);
  assert.equal(seen[0].path, `/qa-login/${TOKEN}`);
  assert.equal(new URL(seen[0].url).host, 'harness-console.operator.workers.dev');
});

test('S2 the production host refuses /qa-login/ and never asks the worker', async (t) => {
  const seen = fakeFetch(t);
  for (const host of [PROD, 'https://evil.example', 'https://a.b.console.example.pages.dev']) {
    const res = await qaLogin({ request: new Request(`${host}/qa-login/${TOKEN}`), params: { token: TOKEN } });
    assert.equal(res.status, 403, host);
    assert.equal(res.headers.get('set-cookie'), null, host);
  }
  assert.equal(seen.length, 0);
});

test('S3 a bad token: the worker refusal comes through', async (t) => {
  fakeFetch(t, { qaLoginStatus: 403 });
  const res = await qaLogin({ request: new Request(`${PREVIEW}/qa-login/nope`), params: { token: 'nope' } });
  assert.equal(res.status, 403);
  assert.equal(res.headers.get('set-cookie'), null);
});

test('S4 qaOnly tells a QA session from the operator', () => {
  assert.equal(qaOnly(QA), true);
  assert.equal(qaOnly(`theme=dark; ${QA}`), true);
  assert.equal(qaOnly(`${QA}; ${OP}`), false);
  assert.equal(qaOnly(OP), false);
  assert.equal(qaOnly(''), false);
});

const ENV = { HARNESS_SECRET: 'fixture-pages-secret', QA_READ_TOKEN: 'fixture-qa-read-token' };

test('S5 /api/coord refuses a QA session write before the jobs worker', async (t) => {
  const seen = fakeFetch(t);
  const req = new Request(`${PREVIEW}/api/coord/flags`, {
    method: 'PUT', headers: { cookie: QA, 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'automerge-disabled', active: 1, reason: 'qa' })
  });
  const res = await coord({ request: req, env: ENV, params: { path: ['flags'] } });
  assert.equal(res.status, 403);
  assert.match(await res.text(), /read-only/);
  assert.equal(seen.filter((s) => s.method !== 'GET').length, 0, JSON.stringify(seen));
});

test('S6 /api/coord still serves a QA session read', async (t) => {
  fakeFetch(t);
  const req = new Request(`${PREVIEW}/api/coord/jobs?limit=5`, { headers: { cookie: QA } });
  const res = await coord({ request: req, env: ENV, params: { path: ['jobs'] } });
  assert.equal(res.status, 200);
});

test('S7 /api/* refuses a QA session POST before the worker', async (t) => {
  const seen = fakeFetch(t);
  const req = new Request(`${PREVIEW}/api/dash/action`, {
    method: 'POST', headers: { cookie: QA, 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'pause_board', project: 'cromford', reason: 'qa' })
  });
  const res = await dash({ request: req, env: {}, params: { path: ['dash', 'action'] } });
  assert.equal(res.status, 403);
  assert.equal(seen.length, 0, JSON.stringify(seen));
});

test('S8 a production deployment hash host refuses /qa-login/ and never asks the worker', async (t) => {
  const seen = fakeFetch(t);
  for (const host of ['https://a1b2c3d4.console.example.pages.dev', 'https://0f9e8d7c.console.example.pages.dev']) {
    const res = await qaLogin({ request: new Request(`${host}/qa-login/${TOKEN}`), params: { token: TOKEN }, env: {} });
    assert.equal(res.status, 403, host);
    assert.equal(res.headers.get('set-cookie'), null, host);
  }
  assert.equal(seen.length, 0);
});

test('S9 with CF_PAGES_BRANCH the host must be that branch alias, and never main', async (t) => {
  const seen = fakeFetch(t);
  const ok = await qaLogin({ request: new Request(`${PREVIEW}/qa-login/${TOKEN}`), params: { token: TOKEN }, env: { CF_PAGES_BRANCH: 'ticket-bh-5909' } });
  assert.equal(ok.status, 302);
  for (const branch of ['main', 'ticket-bh-1']) {
    const res = await qaLogin({ request: new Request(`${PREVIEW}/qa-login/${TOKEN}`), params: { token: TOKEN }, env: { CF_PAGES_BRANCH: branch } });
    assert.equal(res.status, 403, branch);
  }
  assert.equal(seen.length, 1);
});

test('S11 the main alias host refuses /qa-login/ with no CF_PAGES_BRANCH', async (t) => {
  const seen = fakeFetch(t);
  for (const host of ['https://main.console.example.pages.dev', 'https://MAIN.console.example.pages.dev']) {
    const res = await qaLogin({ request: new Request(`${host}/qa-login/${TOKEN}`), params: { token: TOKEN }, env: {} });
    assert.equal(res.status, 403, host);
  }
  assert.equal(seen.length, 0);
});

test('S10 a write that carries dashqa is refused even beside a dash cookie', async (t) => {
  const seen = fakeFetch(t);
  const req = new Request(`${PREVIEW}/api/dash/action`, {
    method: 'POST', headers: { cookie: `dash=x; ${QA}`, 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'pause_board', project: 'cromford', reason: 'qa' })
  });
  const res = await dash({ request: req, env: {}, params: { path: ['dash', 'action'] } });
  assert.equal(res.status, 403);
  assert.equal(seen.length, 0, JSON.stringify(seen));
});
