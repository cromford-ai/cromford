import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';
import { qaReadPolicy, projectQaBody, QA_READ_ROUTES } from '../functions/_lib/qa-read-policy.js';
import { qaReadDispatch } from '../../worker/jobs/src/lib/qa-read.js';

// BH-9263: a QA preview session (`dashqa` cookie, no `dash`) reads the coord
// proxy only on the QA allowlist (whoami, jobs, flags), and every answer is
// projected to the listed fields. The proxy sends QA_READ_TOKEN when the
// Pages project has it; until then it sends HARNESS_SECRET with a warn line,
// and projects the answer the same way.
//   P1-P4  the shared policy (allowlist, projection, jobs/Pages parity)
//   C1-C11 the coord proxy, driven through its real onRequest

const PREVIEW = 'https://ticket-bh-9263.console.example.pages.dev';
const SECRET = 'tok-fixture-bh9263-harness';
const QA_TOKEN = 'tok-fixture-bh9263-qa-read';
let n = 0;
// A fresh dashqa cookie per call: the coord signedIn cache is keyed by cookie.
const qaCookie = () => `dashqa=1791700000.${String(++n).padStart(64, 'a')}`;
const opCookie = () => `dash=${String(++n).padStart(64, 'c')}`;

const JOB_ROW = {
  id: 'job-bh9263', project: 'proj-bh9263', ticket_id: 'BH-9263', kind: 'build', box: 'box-fixture',
  stage: 'execute', status: 'running', created_at: '2026-11-13T10:00:00Z', updated_at: '2026-11-13T10:00:00Z',
  meta: '{"note":"opaque-meta-fixture"}', beat_note: 'beat-note-fixture', beat_box: 'box-fixture',
  future_column: 'unknown-col-fixture', heartbeating: false, spent_usd: 1.5,
};
const JOBS_BODY = { jobs: [JOB_ROW], as_of: '2026-11-13T10:00:01Z', debug: 'unknown-top-fixture' };
const FLAGS_BODY = {
  flags: [{ scope: 'fleet', name: 'wip-limit-x', value: 'secret-value-fixture', set_by: 'console', reason: 'r',
    set_at: '2026-11-13T10:00:00Z', cleared_at: null, active: 1, actor: 'console', updated_at: '2026-11-13T10:00:00Z' }],
  as_of: '2026-11-13T10:00:01Z',
};

// Mocks fetch: the console probe answers `probe`; the jobs worker answers
// `jobs(url, init)` (default: the fixture body for the route). Records calls.
function fakeFetch(t, { probe = 200, jobs } = {}) {
  const calls = { probe: 0, jobs: [] };
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    const u = new URL(String(url));
    if (u.pathname === '/api/dash/fleet') { calls.probe += 1; return new Response('{}', { status: probe }); }
    calls.jobs.push({ url: u, auth: (init.headers || {}).authorization, method: init.method || 'GET' });
    if (jobs) return jobs(u, init);
    const body = u.pathname === '/api/flags' ? FLAGS_BODY : u.pathname === '/api/jobs' ? JOBS_BODY : { secret: 'anything-fixture' };
    return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
  });
  return calls;
}
async function capture(fn) {
  const lines = []; const keep = {};
  for (const k of ['log', 'info', 'warn', 'error']) { keep[k] = console[k]; console[k] = (...a) => lines.push(a.map(String).join(' ')); }
  try { return { out: await fn(), lines }; } finally { Object.assign(console, keep); }
}
function get(rest, { cookie = qaCookie(), env = {}, query = '' } = {}) {
  const request = new Request(`${PREVIEW}/api/coord/${rest}${query}`, { headers: { cookie } });
  return coord({ request, env: { HARNESS_SECRET: SECRET, ...env }, params: { path: rest.split('/') } });
}

test('P1 qaReadPolicy: only jobs and flags, exact match', () => {
  assert.ok(qaReadPolicy('jobs'));
  assert.ok(qaReadPolicy('flags'));
  for (const r of ['otp', 'settings', 'settings/x', 'jobs/abc/events', 'flagsx', 'JOBS', 'jobs/', '../otp', '', 'whoami',
    'constructor', '__proto__', 'toString', undefined, null, 5]) {
    assert.equal(qaReadPolicy(r), null, String(r));
  }
  assert.deepEqual(Object.keys(QA_READ_ROUTES).sort(), ['flags', 'jobs']);
});

test('P2 projectQaBody jobs drops meta, beat_note and an unknown column', () => {
  const out = projectQaBody('jobs', JOBS_BODY);
  const row = out.jobs[0];
  assert.equal(row.id, 'job-bh9263');
  assert.equal(row.status, 'running');
  assert.equal(row.spent_usd, 1.5);
  assert.equal(row.heartbeating, false);
  for (const k of ['meta', 'beat_note', 'beat_box', 'future_column']) assert.equal(k in row, false, k);
  assert.equal(projectQaBody('otp', { code: '1' }), null);
  assert.equal(projectQaBody('jobs', null), null);
  assert.equal(projectQaBody('jobs', [1]), null);
});

test('P3 projectQaBody drops an unknown top key and keeps the listed ones', () => {
  const out = projectQaBody('jobs', JOBS_BODY);
  assert.deepEqual(Object.keys(out).sort(), ['as_of', 'jobs']);
  const f = projectQaBody('flags', { ...FLAGS_BODY, truncated: true, other: 1 });
  assert.deepEqual(Object.keys(f).sort(), ['as_of', 'flags', 'truncated']);
  assert.equal('value' in f.flags[0], false);
  assert.equal('actor' in f.flags[0], false);
});

test('P4 the jobs-side and the Pages-side projection give the same body for one fixture', async (t) => {
  const routes = [['GET', '/api/jobs', () => new Response(JSON.stringify(JOBS_BODY), { status: 200 })]];
  const req = new Request('https://jobs.test/api/jobs', { headers: { authorization: `Bearer ${QA_TOKEN}` } });
  const url = new URL(req.url);
  const jobsSide = await (await qaReadDispatch({ req, env: { HARNESS_SECRET: SECRET, QA_READ_TOKEN: QA_TOKEN }, url, path: '/api/jobs', t: 'x' }, routes)).json();
  fakeFetch(t);
  const { out } = await capture(() => get('jobs'));
  assert.equal(out.status, 200);
  assert.deepEqual(await out.json(), jobsSide);
});

test('C1 QA GET otp with a to and a since query: 403 and 0 jobs calls', async (t) => {
  const calls = fakeFetch(t);
  const { out } = await capture(() => get('otp', { query: '?to=a@otp.example.com&since=2026-11-13T00:00:00Z' }));
  assert.equal(out.status, 403);
  assert.equal((await out.json()).error, 'not available to a QA session');
  assert.equal(calls.jobs.length, 0);
});

test('C2 QA GET settings: 403 and 0 jobs calls', async (t) => {
  const calls = fakeFetch(t);
  const { out } = await capture(() => get('settings'));
  assert.equal(out.status, 403);
  assert.equal(calls.jobs.length, 0);
});

test('C3 QA GET settings/x and jobs/abc/events: 403', async (t) => {
  const calls = fakeFetch(t);
  for (const r of ['settings/x', 'jobs/abc/events']) {
    const { out } = await capture(() => get(r));
    assert.equal(out.status, 403, r);
  }
  assert.equal(calls.jobs.length, 0);
});

test('C4 the refused log line names the route, never the query', async (t) => {
  fakeFetch(t);
  const { lines } = await capture(() => get('otp', { query: '?to=a@otp.example.com&since=2026-11-13T00:00:00Z' }));
  assert.ok(lines.includes('qa-read: refused GET otp'), lines.join('\n'));
  assert.equal(lines.join('\n').includes('project-6'), false);
});

test('C5 QA_READ_TOKEN unset: QA GET jobs is 200 under HARNESS_SECRET, one warn, projected', async (t) => {
  const calls = fakeFetch(t);
  const { out, lines } = await capture(() => get('jobs'));
  assert.equal(out.status, 200);
  assert.equal(out.headers.get('cache-control'), 'no-store');
  assert.equal(calls.jobs.length, 1);
  assert.equal(calls.jobs[0].auth, `Bearer ${SECRET}`);
  assert.equal(lines.filter((l) => l.startsWith('qa-read: QA_READ_TOKEN unset')).length, 1, lines.join('\n'));
  assert.ok(lines.includes('qa-read: allowed GET jobs'), lines.join('\n'));
  const body = await out.json();
  assert.equal('meta' in body.jobs[0], false);
  assert.equal('debug' in body, false);
});

test('C6 QA_READ_TOKEN set: the forward bearer is the QA token; extra query params are dropped', async (t) => {
  const calls = fakeFetch(t);
  const { out, lines } = await capture(() => get('jobs', { env: { QA_READ_TOKEN: ` ${QA_TOKEN}\n` }, query: '?to=x&since=2026-11-13T00:00:00Z&limit=5' }));
  assert.equal(out.status, 200);
  assert.equal(calls.jobs[0].auth, `Bearer ${QA_TOKEN}`);
  assert.deepEqual([...calls.jobs[0].url.searchParams.keys()], ['limit']);
  assert.equal(lines.some((l) => l.includes('QA_READ_TOKEN unset')), false);
  // A token equal to HARNESS_SECRET counts as unset.
  const c2 = fakeFetch(t);
  const r2 = await capture(() => get('jobs', { env: { QA_READ_TOKEN: SECRET } }));
  assert.equal(c2.jobs[0].auth, `Bearer ${SECRET}`);
  assert.equal(r2.lines.filter((l) => l.startsWith('qa-read: QA_READ_TOKEN unset')).length, 1);
});

test('C7 the jobs answer carries meta: the client body does not', async (t) => {
  fakeFetch(t);
  const { out } = await capture(() => get('jobs', { env: { QA_READ_TOKEN: QA_TOKEN } }));
  const text = await out.text();
  assert.equal(text.includes('opaque-meta-fixture'), false);
  assert.equal(text.includes('beat-note-fixture'), false);
  assert.equal(text.includes('unknown-col-fixture'), false);
  assert.ok(text.includes('job-bh9263'));
});

test('C8 QA GET whoami: 200, answered by Pages', async (t) => {
  const calls = fakeFetch(t);
  const { out } = await capture(() => get('whoami'));
  assert.equal(out.status, 200);
  assert.equal(calls.jobs.length, 0);
  assert.equal(typeof (await out.json()).actor, 'string');
});

test('C9 QA GET flags: 200, projected (no value)', async (t) => {
  fakeFetch(t);
  const { out } = await capture(() => get('flags', { query: '?prefix=wip&value=1' }));
  assert.equal(out.status, 200);
  const text = await out.text();
  assert.equal(text.includes('secret-value-fixture'), false);
  assert.equal(JSON.parse(text).flags[0].name, 'wip-limit-x');
});

test('C10 jobs answers 401 to the QA token: one retry under HARNESS_SECRET, 200', async (t) => {
  const calls = fakeFetch(t, {
    jobs: (u, init) => init.headers.authorization === `Bearer ${QA_TOKEN}`
      ? new Response('{"error":"unauthorized"}', { status: 401 })
      : new Response(JSON.stringify(JOBS_BODY), { status: 200 }),
  });
  const { out, lines } = await capture(() => get('jobs', { env: { QA_READ_TOKEN: QA_TOKEN } }));
  assert.equal(out.status, 200);
  assert.deepEqual(calls.jobs.map((c) => c.auth), [`Bearer ${QA_TOKEN}`, `Bearer ${SECRET}`]);
  assert.ok(lines.some((l) => l.startsWith('qa-read: QA_READ_TOKEN refused by harness-jobs')), lines.join('\n'));
  assert.equal('meta' in (await out.json()).jobs[0], false);
});

test('C10b a non-200 passes its status with {error} only; a non-JSON 200 is 502', async (t) => {
  fakeFetch(t, { jobs: () => new Response(JSON.stringify({ error: 'jobs unavailable', detail: 'internal-fixture' }), { status: 503 }) });
  const { out } = await capture(() => get('jobs'));
  assert.equal(out.status, 503);
  assert.deepEqual(await out.json(), { error: 'jobs unavailable' });
  fakeFetch(t, { jobs: () => new Response('<html>not json</html>', { status: 200 }) });
  const r2 = await capture(() => get('jobs'));
  assert.equal(r2.out.status, 502);
});

test('C11 operator (dash only) GET settings: forwarded unchanged, query and all', async (t) => {
  const calls = fakeFetch(t);
  const { out } = await capture(() => get('settings', { cookie: opCookie(), env: { QA_READ_TOKEN: QA_TOKEN }, query: '?x=1' }));
  assert.equal(out.status, 200);
  assert.equal(calls.jobs[0].auth, `Bearer ${SECRET}`);
  assert.equal(calls.jobs[0].url.search, '?x=1');
  assert.equal((await out.json()).secret, 'anything-fixture');
});
