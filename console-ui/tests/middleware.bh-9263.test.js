import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest as middleware } from '../functions/_middleware.js';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';

// BH-9263: the Pages root middleware, in front of every /api/* function.
//   M1-M2  a request with both `dash` and `dashqa`: the console probes `dash`
//          alone; 200 keeps `dash` (operator), anything else keeps `dashqa`
//   M3-M7  a cookie write must be same-origin (Origin, else Sec-Fetch-Site)
//   M8     every /api/* response is no-store; other paths keep their headers
//   M9     end to end with the coord proxy: an operator with a stale dashqa
//          cookie can write again
//   M10    a one-cookie request never probes

const HOST = 'https://ticket-bh-9263.console.example.pages.dev';
let n = 0;
const DASH = () => `dash=${String(++n).padStart(64, 'c')}`;
const QA = () => `dashqa=1791700000.${String(++n).padStart(64, 'a')}`;

function fakeFetch(t, { probe = 200 } = {}) {
  const calls = { probe: [], jobs: [] };
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    const u = new URL(String(url));
    if (u.pathname === '/api/dash/fleet') {
      calls.probe.push((init.headers || {}).cookie);
      if (probe === 'throw') throw new Error('console down (fixture)');
      return new Response('{}', { status: probe });
    }
    calls.jobs.push({ url: u, method: init.method, body: init.body });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  });
  return calls;
}
// A recording `next`: what the downstream function would have seen.
function recorder(res = () => new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } })) {
  const seen = [];
  const next = async (req) => { seen.push(req); return res(req); };
  return { seen, next };
}
function run(path, { method = 'GET', cookie, headers = {}, body, next }) {
  const h = new Headers(headers);
  if (cookie) h.set('cookie', cookie);
  const request = new Request(`${HOST}${path}`, { method, headers: h, body });
  return middleware({ request, env: {}, params: {}, next });
}
const cookieOf = (req) => req.headers.get('cookie') || '';
const names = (c) => c.split(/;\s*/).filter(Boolean).map((p) => p.split('=')[0]);

test('M1 dash + dashqa, probe 200: next sees dash and no dashqa', async (t) => {
  const calls = fakeFetch(t, { probe: 200 });
  const r = recorder();
  const d = DASH();
  const res = await run('/api/coord/jobs', { cookie: `${QA()}; theme=dark; ${d}`, next: r.next });
  assert.equal(res.status, 200);
  assert.equal(r.seen.length, 1);
  assert.deepEqual(names(cookieOf(r.seen[0])).sort(), ['dash', 'theme']);
  assert.deepEqual(calls.probe, [d]);
});

test('M2 dash=x + dashqa, probe 403 or a throw: next sees dashqa only', async (t) => {
  for (const probe of [403, 401, 302, 500, 'throw']) {
    fakeFetch(t, { probe });
    const r = recorder();
    const q = QA();
    await run('/api/coord/jobs', { cookie: `dash=x; ${q}; dash=y`, next: r.next });
    assert.equal(cookieOf(r.seen[0]), q, String(probe));
    t.mock.restoreAll();
  }
});

test('M3 cookie POST with a cross Origin: 403, next not called', async (t) => {
  const calls = fakeFetch(t);
  const r = recorder();
  const res = await run('/api/coord/flags', { method: 'POST', cookie: DASH(), headers: { origin: 'https://evil.example' }, body: '{}', next: r.next });
  assert.equal(res.status, 403);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(r.seen.length, 0);
  assert.equal(calls.probe.length, 0);
});

test('M4 cookie POST with Origin: null: 403', async (t) => {
  fakeFetch(t);
  const r = recorder();
  const res = await run('/api/coord/flags', { method: 'PUT', cookie: QA(), headers: { origin: 'null' }, body: '{}', next: r.next });
  assert.equal(res.status, 403);
  assert.equal(r.seen.length, 0);
});

test('M5 no Origin + Sec-Fetch-Site cross-site or same-site: 403', async (t) => {
  fakeFetch(t);
  for (const site of ['cross-site', 'same-site', 'none']) {
    const r = recorder();
    const res = await run('/api/x', { method: 'DELETE', cookie: DASH(), headers: { 'sec-fetch-site': site }, next: r.next });
    assert.equal(res.status, 403, site);
    assert.equal(r.seen.length, 0, site);
  }
});

test('M6 same-origin cookie writes pass: same Origin, or no Origin + same-origin, or no headers', async (t) => {
  fakeFetch(t);
  for (const headers of [{ origin: HOST }, { 'sec-fetch-site': 'same-origin' }, {}]) {
    const r = recorder();
    const res = await run('/api/coord/flags', { method: 'POST', cookie: DASH(), headers, body: '{}', next: r.next });
    assert.equal(res.status, 200, JSON.stringify(headers));
    assert.equal(r.seen.length, 1);
  }
});

test('M7 a bearer POST with no cookie, and a cross-origin GET, are not checked', async (t) => {
  fakeFetch(t);
  const r = recorder();
  const a = await run('/api/x', { method: 'POST', headers: { authorization: 'Bearer tok-fixture', origin: 'https://evil.example' }, body: '{}', next: r.next });
  assert.equal(a.status, 200);
  const b = await run('/api/x', { method: 'GET', cookie: DASH(), headers: { origin: 'https://evil.example' }, next: r.next });
  assert.equal(b.status, 200);
  assert.equal(r.seen.length, 2);
});

test('M8 every /api/* response is no-store; a non-/api path keeps its headers', async (t) => {
  fakeFetch(t);
  const cached = () => new Response('png', { status: 200, headers: { 'cache-control': 'private, max-age=300', 'x-keep': '1' } });
  const a = await run('/api/ideas/asset', { cookie: DASH(), next: recorder(cached).next });
  assert.equal(a.headers.get('cache-control'), 'no-store');
  assert.equal(a.headers.get('x-keep'), '1');
  assert.equal(await a.text(), 'png');
  const b = await run('/api/coord/jobs', { next: recorder(() => new Response('{}', { status: 404 })).next });
  assert.equal(b.status, 404);
  assert.equal(b.headers.get('cache-control'), 'no-store');
  const c = await run('/assets/app.js', { next: recorder(cached).next });
  assert.equal(c.headers.get('cache-control'), 'private, max-age=300');
});

test('M9 end to end: operator with a stale dashqa cookie can PUT flags with a reason', async (t) => {
  const calls = fakeFetch(t, { probe: 200 });
  const next = (req) => coord({ request: req, env: { HARNESS_SECRET: 'tok-fixture-bh9263-harness' }, params: { path: ['flags'] } });
  const body = JSON.stringify({ name: 'paused-proj-bh9263', active: 1, reason: 'fixture reason' });
  const res = await run('/api/coord/flags', { method: 'PUT', cookie: `${DASH()}; ${QA()}`, headers: { origin: HOST }, body, next });
  assert.equal(res.status, 200, await res.clone().text());
  assert.equal(calls.jobs.length, 1);
  assert.equal(calls.jobs[0].method, 'PUT');
  assert.equal(JSON.parse(calls.jobs[0].body).reason, 'fixture reason');
  // Not vacuous: the same request with no middleware is refused today.
  const direct = await coord({
    request: new Request(`${HOST}/api/coord/flags`, { method: 'PUT', headers: { cookie: `${DASH()}; ${QA()}` }, body }),
    env: { HARNESS_SECRET: 'tok-fixture-bh9263-harness' }, params: { path: ['flags'] },
  });
  assert.equal(direct.status, 403);
});

test('M10 a one-cookie request makes 0 probe calls', async (t) => {
  const calls = fakeFetch(t);
  const r = recorder();
  for (const cookie of [DASH(), QA(), `xdash=1; ${QA()}`, `xdashqa=1; ${DASH()}`]) {
    await run('/api/coord/jobs', { cookie, next: r.next });
  }
  assert.equal(calls.probe.length, 0);
  assert.equal(r.seen.length, 4);
  assert.equal(cookieOf(r.seen[2]).includes('xdash=1'), true);
});
