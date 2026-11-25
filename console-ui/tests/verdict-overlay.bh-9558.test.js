import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { openPrUrls, fetchCurrentVerdicts, overlayVerdicts } from '../functions/_lib/verdict-overlay.js';
import {
  onRequest, _resetHeldCache, _resetClosedCache, _resetStageCache
} from '../functions/api/dash/kanban/pipeline.js';
import { pipelineRows } from '../src/lib/kanban.js';
import { verdictBadge } from '../src/lib/verdict-badge.js';
import { PipelineBoard, PipelineList } from '../src/screens/Kanban.js';

// BH-9558 — the kanban shows the CURRENT verdict. A PR the builder approved
// and the lead then blocked must read "lead-blocked", not "approved". The
// Pages Function reads POST /api/verdict/current (harness-jobs) and overlays it
// on the open build cards. fetch is stubbed: 0 network calls.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CURRENT = `${JOBS}/api/verdict/current`;
const ENV = { HARNESS_SECRET: 'secret-fixture' };
const P = (n) => `https://github.com/example-org/demo-os/pull/${n}`;

const payload = () => ({
  columns: {
    queued: [{ id: 1, project: 'demo-os', ticket: 'DM-1', pr_url: P(1), age_min: 5 }],
    building: [
      { command_id: 'c-1', project: 'demo-os', pr_url: P(5), verdict: 'APPROVE', age_min: 5 },
      { queue_depth: 3, project: 'demo-os' },
      { id: 7, project: 'demo-os', ticket: 'DM-7', age_min: 5 },
    ],
    merge_queue: [{ id: 6, project: 'demo-os', ticket: 'DM-6', pr_url: P(6), verdict: 'APPROVE', age_min: 5 }],
    review: [
      { id: 2, project: 'demo-os', ticket: 'DM-2', pr_url: P(2), verdict: 'APPROVE', age_min: 5 },
      { id: 8, project: 'demo-os', ticket: 'DM-8', pr_url: P(8), verdict: 'APPROVE', age_min: 5 },
    ],
    merged_deployed: [{ id: 3, project: 'demo-os', ticket: 'DM-3', pr_url: P(3), verdict: 'APPROVE', age_min: 5 }],
    dead_failed: [{ id: 4, project: 'demo-os', ticket: 'DM-4', pr_url: P(4), verdict: 'APPROVE', age_min: 5 }],
  },
  counts: { queued: 1, building: 3, merge_queue: 1, review: 2, merged_deployed: 1, dead_failed: 1 },
});

const leadBlock = { verdict: 'BLOCK', by: 'lead', state: 'lead_blocked', reviewed_sha: 'a'.repeat(40), at: '2026-11-24T16:00:00Z', rounds: 2 };
const answer = () => ({ verdicts: { [P(2)]: leadBlock }, truncated: false, cap: 200 });

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function withFetch(route, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const a = route(String(url), init);
    if (a instanceof Error) throw a;
    return a;
  };
  const reset = () => { _resetHeldCache(); _resetClosedCache(); _resetStageCache(); };
  reset();
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; reset(); });
}

const req = () => new Request('https://console.example/api/dash/kanban/pipeline', { headers: { cookie: 'dash=tok' } });
const routeWith = (current) => (u) => (u === CURRENT ? (typeof current === 'function' ? current() : current)
  : u.startsWith(`${JOBS}/api/ledger`) ? jsonRes({ ledgers: [] })
    : jsonRes(payload()));

test('O1 openPrUrls takes urls from open build cards only; the only verdict fetch is POST /api/verdict/current', () =>
  withFetch(() => jsonRes(answer()), async (calls) => {
    assert.deepEqual(openPrUrls(payload()).sort(), [P(1), P(2), P(6), P(8)].sort());
    const res = await fetchCurrentVerdicts(ENV, [P(2)]);
    assert.deepEqual(res.verdicts[P(2)], leadBlock);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, CURRENT);
    assert.equal(calls[0].init.method, 'POST');
    assert.equal(new Headers(calls[0].init.headers).get('authorization'), 'Bearer secret-fixture');
    assert.deepEqual(JSON.parse(calls[0].init.body), { prs: [P(2)] });
  }));

test('O2 onRequest: builder APPROVE + lead BLOCK reads lead-blocked on the card, the row and the badge', () =>
  withFetch(routeWith(jsonRes(answer())), async (calls) => {
    const res = await onRequest({ request: req(), env: ENV });
    assert.equal(res.status, 200);
    const body = await res.json();
    const card = body.columns.review[0];
    assert.equal(card.verdict, 'BLOCK');
    assert.equal(card.builder_verdict, 'APPROVE');
    assert.equal(card.verdict_state, 'lead_blocked');
    assert.equal(card.verdict_by, 'lead');
    assert.equal(card.verdict_sha, 'a'.repeat(40));
    assert.equal(body.verdict_known, true);
    assert.equal(body.verdict_overlaid, 1);
    assert.deepEqual(body.counts, payload().counts);
    assert.deepEqual(Object.keys(body.columns.review).length, 2);
    // The request asked for exactly the open build cards' urls.
    const asked = JSON.parse(calls.find((c) => c.url === CURRENT).init.body).prs.sort();
    assert.deepEqual(asked, [P(1), P(2), P(6), P(8)].sort());
    const row = pipelineRows(body).find((r) => r.card.id === 2);
    assert.equal(row.verdictState, 'lead_blocked');
    assert.equal(row.verdictBy, 'lead');
    // What a user sees: the card and the list cell both say lead-blocked.
    const board = render(h(PipelineBoard, { board: body, external: [], onToggleAudit: () => {} }));
    const i = board.indexOf('>DM-2<');
    assert.notEqual(i, -1);
    const cardHtml = board.slice(board.lastIndexOf('<a', i), board.indexOf('</a>', i));
    assert.match(cardHtml, /<span class="tag tag--warn" title="BLOCK by lead">lead-blocked<\/span>/);
    assert.doesNotMatch(cardHtml, />approved</);
    const list = render(h(PipelineList, { board: body, external: [], onToggleAudit: () => {} }));
    const tr = list.split('<tr').find((t) => t.includes('>DM-2<'));
    assert.match(tr, />lead-blocked</);
  }));

test('O3 merged and dead cards, command and queue cards are unchanged', () => {
  const ans = { verdicts: { [P(3)]: leadBlock, [P(4)]: leadBlock, [P(5)]: leadBlock }, truncated: false };
  const out = overlayVerdicts(payload(), ans);
  const before = payload();
  assert.deepEqual(out.columns.merged_deployed, before.columns.merged_deployed);
  assert.deepEqual(out.columns.dead_failed, before.columns.dead_failed);
  assert.deepEqual(out.columns.building, before.columns.building);
  assert.equal(out.verdict_overlaid, 0);
});

test('O4 a url absent from the answer leaves its card unchanged', () => {
  const out = overlayVerdicts(payload(), answer());
  assert.deepEqual(out.columns.review[1], payload().columns.review[1]);
  assert.deepEqual(out.columns.queued[0], payload().columns.queued[0]);
  assert.equal(out.verdict_truncated, undefined);
  const tr = overlayVerdicts(payload(), { ...answer(), truncated: true });
  assert.equal(tr.verdict_truncated, true);
});

for (const [name, current, env] of [
  ['fetch rejects', () => new Error('network down (fixture)'), ENV],
  ['the worker answers 503', () => jsonRes({ ...answer(), error: 'overloaded' }, 503), ENV],
  ['the worker answers junk', () => new Response('not json', { status: 200 }), ENV],
  ['no HARNESS_SECRET', () => jsonRes(answer()), {}],
]) {
  test(`O5/O6 ${name}: payload unchanged, verdict_known:false`, () =>
    withFetch(routeWith(current), async (calls) => {
      const body = await (await onRequest({ request: req(), env })).json();
      assert.equal(body.verdict_known, false);
      assert.equal(body.columns.review[0].verdict, 'APPROVE');
      assert.equal('verdict_state' in body.columns.review[0], false);
      if (!env.HARNESS_SECRET) assert.equal(calls.filter((c) => c.url === CURRENT).length, 0);
    }));
}

test('O7 no open build card with a PR url: no verdict read, no verdict keys on the payload', () => {
  const only = { columns: { review: [{ id: 9, project: 'demo-os', ticket: 'DM-9', age_min: 5 }], dead_failed: payload().columns.dead_failed }, counts: { review: 1, dead_failed: 1 } };
  return withFetch((u) => (u === CURRENT ? jsonRes(answer()) : u.startsWith(`${JOBS}/api/ledger`) ? jsonRes({ ledgers: [] }) : jsonRes(only)), async (calls) => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(calls.filter((c) => c.url === CURRENT).length, 0);
    assert.equal('verdict_known' in body, false);
    assert.equal(body.columns.dead_failed[0].verdict, 'APPROVE');
  });
});

test('B1 verdictBadge: a lead or human BLOCK is lead-blocked, warn', () => {
  assert.deepEqual(verdictBadge({ verdict: 'BLOCK', verdictBy: 'lead', verdictState: 'lead_blocked' }),
    { cls: 'tag tag--warn', text: 'lead-blocked', title: 'BLOCK by lead' });
  assert.equal(verdictBadge({ verdict: 'BLOCK', verdictBy: 'human', verdictState: 'lead_blocked' }).text, 'lead-blocked');
});

test('B2 verdictBadge: a builder BLOCK keeps today\'s label; no overlay keeps today\'s badge', () => {
  assert.deepEqual(verdictBadge({ verdict: 'BLOCK', verdictBy: 'builder', verdictState: 'blocked' }),
    { cls: 'tag tag--warn', text: 'blocked', title: 'BLOCK by builder' });
  assert.deepEqual(verdictBadge({ verdict: 'APPROVE' }), { cls: 'tag tag--green', text: 'approved', title: 'APPROVE' });
  assert.deepEqual(verdictBadge({ verdict: 'BLOCK' }), { cls: 'tag tag--warn', text: 'blocked', title: 'BLOCK' });
});

test('B3 verdictBadge: MERGE is lead approved, MERGE-WITH-NOTES is lead approved, notes, both green', () => {
  assert.deepEqual(verdictBadge({ verdict: 'MERGE', verdictBy: 'lead', verdictState: 'approved' }),
    { cls: 'tag tag--green', text: 'lead approved', title: 'MERGE by lead' });
  assert.deepEqual(verdictBadge({ verdict: 'MERGE-WITH-NOTES', verdictBy: 'lead', verdictState: 'approved' }),
    { cls: 'tag tag--green', text: 'lead approved, notes', title: 'MERGE-WITH-NOTES by lead' });
  assert.deepEqual(verdictBadge({ verdict: 'APPROVE', verdictBy: 'builder', verdictState: 'approved' }),
    { cls: 'tag tag--green', text: 'approved', title: 'APPROVE by builder' });
});

test('B4 verdictBadge: a risk-tier MERGE is low-risk sign-off, never lead approved', () => {
  assert.deepEqual(verdictBadge({ verdict: 'MERGE', verdictBy: 'risk-tier', verdictState: 'approved' }),
    { cls: 'tag tag--green', text: 'low-risk sign-off', title: 'MERGE by risk-tier' });
  assert.deepEqual(verdictBadge({ verdict: 'MERGE-WITH-NOTES', verdictBy: 'risk-tier', verdictState: 'approved' }),
    { cls: 'tag tag--green', text: 'low-risk sign-off, notes', title: 'MERGE-WITH-NOTES by risk-tier' });
  assert.doesNotMatch(verdictBadge({ verdict: 'MERGE', verdictBy: 'risk-tier', verdictState: 'approved' }).text, /lead/);
});
