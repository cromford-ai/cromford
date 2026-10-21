import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-7711: the MCP's lead_review_request and lead_review_reset reach the jobs
// worker through the coord proxy. Two fragment rows
// (functions/_lib/coord-writes.d/7711-lead-reviews.js): POST lead-reviews and
// POST lead-reviews/<id>/reset, both with the Pages LEAD_VERDICT_TOKEN. Every
// other lead-reviews write stays 405 from the console.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'harness-secret-fixture';
const LEAD = 'lead-token-fixture';
const SHA = 'ab'.repeat(20);

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body, headers: init.headers || {} });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, { env = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: `${LEAD}\n` } } = {}) =>
  onRequest({
    request: new Request(`https://console.example.test/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh7711-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env,
    params: { path: rest.split('/') }
  });

test('C1 POST lead-reviews forwards the five fields, a console requested_by and the lead token', async () => {
  const f = stubFetch();
  try {
    const res = await call('lead-reviews', 'POST', JSON.stringify({
      repo: 'acme/app', pr: 7, head_sha: SHA, scope_notes: 'look at the cache', priority: 5,
      requested_by: 'inbuild:box-1:BH-1', head_authors: ['box-1'], prior_verdict_ref: 'x', actor: 'someone'
    }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    const s = f.seen[0];
    assert.equal(s.url, `${JOBS}/api/lead-reviews`);
    assert.equal(s.method, 'POST');
    assert.equal(s.headers['x-lead-verdict-token'], LEAD);
    assert.equal(s.headers.authorization, `Bearer ${SECRET}`);
    const body = JSON.parse(s.body);
    assert.equal(body.repo, 'acme/app');
    assert.equal(body.pr, 7);
    assert.equal(body.head_sha, SHA);
    assert.equal(body.scope_notes, 'look at the cache');
    assert.equal(body.priority, 5);
    assert.equal(body.requested_by, 'console:console');
    assert.equal(body.actor, 'console');
    for (const k of ['head_authors', 'prior_verdict_ref']) assert.equal(k in body, false, `${k} was forwarded`);
  } finally { f.restore(); }
});

test('C1b absent optional fields are not sent', async () => {
  const f = stubFetch();
  try {
    const res = await call('lead-reviews', 'POST', JSON.stringify({ repo: 'acme/app', pr: 7, head_sha: SHA }));
    assert.equal(res.status, 200);
    const body = JSON.parse(f.seen[0].body);
    assert.equal('scope_notes' in body, false);
    assert.equal('priority' in body, false);
    assert.equal(body.requested_by, 'console:console');
  } finally { f.restore(); }
});

test('C2 review-tier: and review-mode: in scope_notes are rewritten to =', async () => {
  const f = stubFetch();
  try {
    const res = await call('lead-reviews', 'POST', JSON.stringify({
      repo: 'acme/app', pr: 7, head_sha: SHA, scope_notes: 'review-tier:low review-mode:full and review-tier:high'
    }));
    assert.equal(res.status, 200);
    assert.equal(JSON.parse(f.seen[0].body).scope_notes, 'review-tier=low review-mode=full and review-tier=high');
  } finally { f.restore(); }
});

test('C3 POST lead-reviews/<id>/reset forwards {actor} with the lead token', async () => {
  const f = stubFetch();
  try {
    const id = 'lead-review-c3';
    const res = await call(`lead-reviews/${id}/reset`, 'POST', JSON.stringify({ smuggled: 1 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/lead-reviews/${id}/reset`);
    const body = JSON.parse(f.seen[0].body);
    assert.deepEqual(Object.keys(body), ['actor'], 'only the stamped actor is forwarded');
    assert.equal(body.actor, 'console');
    assert.equal(f.seen[0].headers['x-lead-verdict-token'], LEAD);
  } finally { f.restore(); }
});

test('C4 the other lead-reviews writes stay 405 and send nothing', async () => {
  const f = stubFetch();
  try {
    for (const rest of ['lead-reviews/reclaim-stale', 'lead-reviews/abc/claim', 'lead-reviews/abc/result',
      'lead-reviews/abc/heartbeat', 'lead-reviews/abc/promoted', 'lead-reviews/start', 'lead-reviews/../reset',
      'lead-reviews/./reset', 'lead-reviews/a/b/reset', 'lead-reviews//reset', 'lead-reviews/reset']) {
      const res = await call(rest, 'POST', '{}');
      assert.equal(res.status, 405, rest);
    }
    for (const method of ['PUT', 'PATCH', 'DELETE']) {
      const res = await call('lead-reviews', method, method === 'DELETE' ? undefined : '{}');
      assert.equal(res.status, 405, method);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('C5 no LEAD_VERDICT_TOKEN on the Pages env: 503, nothing forwarded', async () => {
  const f = stubFetch();
  try {
    for (const [rest, body] of [['lead-reviews', { repo: 'acme/app', pr: 7, head_sha: SHA }], ['lead-reviews/abc/reset', {}]]) {
      const res = await call(rest, 'POST', JSON.stringify(body), { env: { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: '  ' } });
      assert.equal(res.status, 503, rest);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});
