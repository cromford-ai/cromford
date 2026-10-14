import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  onRequest, ticketStages, surfaceStages, STAGE_LEDGER_KIND, ARCHIVE_AFTER_MIN,
  _resetStageCache, _resetHeldCache, _resetClosedCache
} from '../functions/api/dash/kanban/pipeline.js';
import { PipelineBoard, PipelineList } from '../src/screens/Kanban.js';

// BH-6536. bin/lib/needs-human/step-done.sh writes ledgers(kind=ticket_stage,
// key=<project>#<n>, status=<column>, detail '<state> by <lane> at <iso>:
// <reason>'). The pipeline function joins it at read time: a card for the key
// gets the reason, and a key with no card gets a synthetic one, so TK-232 is on
// the board with its reason in every state.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const isStage = (u) => u.startsWith(`${JOBS}/api/ledger?kind=ticket_stage`);
const isJobs = (u) => u.startsWith(JOBS);
const ENV = { HARNESS_SECRET: 's' };
const KEY = 'project-6-os#232';
const WHY = 'findings posted';

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function withFetch(route, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const a = route(String(url));
    if (a instanceof Error) throw a;
    return a;
  };
  const reset = () => { _resetStageCache(); _resetHeldCache(); _resetClosedCache(); };
  reset();
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; reset(); });
}

// A row as nh_sd_stage_put writes it: newest first, the column in status.
// One fixed anchor; the onRequest tests pin the clock to it with mock timers.
const ANCHOR = Date.parse('2026-10-13T21:00:00Z');
const isoAgo = (min) => new Date(ANCHOR - min * 60000).toISOString().replace(/\.\d+Z$/, 'Z');
const stageRow = (key, state, at, why = WHY, status = 'review') =>
  ({ kind: STAGE_LEDGER_KIND, key, status, updated_at: at, detail: `${state} by review-rescue at ${at}: ${why}` });

const build = (id, ticket, stage, extra = {}) =>
  ({ id, project: 'project-6-os', ticket, stage, age_min: 5, ...extra });
const payload = () => ({
  columns: {
    queued: [],
    building: [build(41, 'TK-7', 'executing')],
    merge_queue: [],
    review: [],
    merged_deployed: [],
    dead_failed: []
  },
  counts: { queued: 0, building: 1, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: 0 },
  building_stale: 0
});
const stage = (at, extra = {}) =>
  ({ column: 'review', state: 'rereview-block', by: 'review-rescue', at, why: WHY, ...extra });

// --- ticketStages, the ledger read -------------------------------------------

test('K1. ticketStages parses the newest row per key into column, state, by, at, why', () => {
  const at = '2026-10-13T20:38:00Z';
  return withFetch(() => jsonRes({ ledgers: [
    stageRow(KEY, 'rereview-block', at),
    stageRow(KEY, 'human-step-done', '2026-10-13T20:00:00Z', 'person applied it')
  ] }), async (calls) => {
    const m = await ticketStages(ENV);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, `${JOBS}/api/ledger?kind=ticket_stage&limit=1000`);
    assert.equal(calls[0].init.headers.authorization, 'Bearer s');
    assert.equal(m.size, 1);
    assert.deepEqual(m.get(KEY), { column: 'review', state: 'rereview-block', by: 'review-rescue', at, why: WHY });
  });
});

test('K1b. ticketStages fails open to null on a non-200, and caches nothing', () =>
  withFetch(() => new Response('boom', { status: 500 }), async (calls) => {
    assert.equal(await ticketStages(ENV), null);
    assert.equal(await ticketStages(ENV), null);
    assert.equal(calls.length, 2);
  }));

// --- surfaceStages, pure -----------------------------------------------------

test('K2. no card for the key: review gains one synthetic card with the reason', () => {
  const now = Date.parse('2026-10-13T21:00:00Z');
  const out = surfaceStages(payload(), new Map([[KEY, stage('2026-10-13T20:38:00Z')]]), { closed: new Set(), now });
  assert.equal(out.stage_known, true);
  assert.equal(out.stage_added, 1);
  assert.equal(out.columns.review.length, 1);
  const c = out.columns.review[0];
  assert.equal(c.ticket, 'TK-232');
  assert.match(c.ticket, /-232$/);
  assert.equal(c.project, 'project-6-os');
  assert.equal(c.stage, 'rereview-block');
  assert.equal(c.stage_why, WHY);
  assert.equal(c.synthetic, 'ticket_stage');
  assert.equal(c.id, `stage:${KEY}`);
  // The other columns are not touched.
  assert.deepEqual(out.columns.building, payload().columns.building);
  // The count beside the column moves with the card; the others do not.
  assert.equal(out.counts.review, 1);
  assert.equal(out.counts.building, payload().counts.building);
});

test('K2b. a project with no card gets a #<n> ticket', () => {
  const now = Date.parse('2026-10-13T21:00:00Z');
  const out = surfaceStages(payload(), new Map([['project-3#9', stage('2026-10-13T20:38:00Z')]]), { now });
  assert.equal(out.columns.review[0].ticket, '#9');
});

test('K3. a card already in building for the key gets the reason, and no card is added', () => {
  const now = Date.parse('2026-10-13T21:00:00Z');
  const p = payload();
  p.columns.building.push(build(42, 'TK-232', 'executing'));
  const out = surfaceStages(p, new Map([[KEY, stage('2026-10-13T20:38:00Z')]]), { closed: new Set(), now });
  assert.equal(out.stage_added, 0);
  assert.equal(out.columns.review.length, 0);
  assert.deepEqual(out.counts, p.counts);
  assert.equal(out.columns.building[1].stage_why, WHY);
  assert.equal(out.columns.building[1].stage_state, 'rereview-block');
  assert.equal(out.columns.building[1].stage, 'executing');
  assert.equal('stage_why' in out.columns.building[0], false);
});

test('K4. a closed key, an old row or an unknown column adds nothing', () => {
  const now = Date.parse('2026-10-13T21:00:00Z');
  const closed = surfaceStages(payload(), new Map([[KEY, stage('2026-10-13T20:38:00Z')]]),
    { closed: new Set([KEY]), now });
  assert.equal(closed.stage_added, 0);
  assert.equal(closed.columns.review.length, 0);

  const oldAt = new Date(now - (ARCHIVE_AFTER_MIN + 1) * 60000).toISOString();
  const old = surfaceStages(payload(), new Map([[KEY, stage(oldAt)]]), { closed: new Set(), now });
  assert.equal(old.stage_added, 0);
  assert.equal(old.columns.review.length, 0);

  const odd = surfaceStages(payload(), new Map([[KEY, stage('2026-10-13T20:38:00Z', { column: 'nowhere' })]]), { now });
  assert.equal(odd.stage_added, 0);
  assert.equal('nowhere' in odd.columns, false);
});

test('K5. null stages: stage_known false, columns unchanged', () => {
  const out = surfaceStages(payload(), null, { closed: new Set(), now: ANCHOR });
  assert.equal(out.stage_known, false);
  assert.deepEqual(out.columns, payload().columns);
});

// --- the screen ----------------------------------------------------------------

const staged = () => {
  const now = Date.parse('2026-10-13T21:00:00Z');
  const p = payload();
  p.columns.building.push(build(42, 'TK-300', 'executing'));
  return surfaceStages(p, new Map([
    [KEY, stage('2026-10-13T20:38:00Z')],
    ['project-6-os#300', stage('2026-10-13T20:30:00Z', { why: 'person applied migration 0020' })]
  ]), { now });
};

// The card's markup: the <a> that holds `>label<`, up to its closing tag.
const cardHtml = (out, label) => {
  const i = out.indexOf(`>${label}<`);
  assert.notEqual(i, -1, `no card for ${label}`);
  const start = out.lastIndexOf('<a', i);
  return out.slice(start, out.indexOf('</a>', i) + 4);
};

test('K6. the board card shows the reason, and the synthetic card links to its project', () => {
  const out = render(h(PipelineBoard, { board: staged(), external: [], onToggleAudit: () => {} }));
  const synth = cardHtml(out, 'TK-232');
  assert.match(synth, /href="\/p\/project-6-os"/);
  assert.match(synth, /<span class="card__body card__why" title="findings posted">findings posted<\/span>/);
  // The raw state shows when no label exists for it.
  assert.match(synth, />rereview-block</);
  const real = cardHtml(out, 'TK-300');
  assert.match(real, />person applied migration 0020</);
  assert.match(real, /href="\/builds\/42"/);
  assert.doesNotMatch(cardHtml(out, 'TK-7'), /card__why/);
});

test('K7. the list row shows the reason and the synthetic row links to its project', () => {
  const out = render(h(PipelineList, { board: staged(), external: [], onToggleAudit: () => {} }));
  const trs = out.split('<tr').slice(1).filter((t) => t.includes('<td'));
  const synth = trs.find((t) => />TK-232</.test(t));
  assert.ok(synth, 'no row for TK-232');
  assert.match(synth, />findings posted</);
  assert.match(synth, /href="\/p\/project-6-os"/);
  assert.doesNotMatch(synth, /\/builds\/stage/);
  assert.match(trs.find((t) => />TK-300</.test(t)), />person applied migration 0020</);
  assert.doesNotMatch(trs.find((t) => />TK-7</.test(t)), /card__why/);
});

// --- onRequest, the production entry point -----------------------------------

const req = () => new Request('https://console.example/api/dash/kanban/pipeline', { headers: { cookie: 'dash=tok' } });

test('K8. onRequest adds the synthetic card from the ledger row', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: ANCHOR });
  return withFetch((u) => (isStage(u) ? jsonRes({ ledgers: [stageRow(KEY, 'rereview-block', isoAgo(5))] })
    : isJobs(u) ? jsonRes({ ledgers: [] })
      : jsonRes(payload())), async (calls) => {
    const res = await onRequest({ request: req(), env: ENV });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.stage_known, true);
    assert.equal(body.stage_added, 1);
    assert.equal(body.columns.review[0].ticket, 'TK-232');
    assert.equal(body.columns.review[0].stage_why, WHY);
    assert.equal(body.columns.review[0].synthetic, 'ticket_stage');
    assert.equal(calls.filter((c) => isStage(c.url)).length, 1);
  });
});

test('K8b. onRequest: a closed issue gets no synthetic card', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: ANCHOR });
  return withFetch((u) => (isStage(u) ? jsonRes({ ledgers: [stageRow(KEY, 'rereview-block', isoAgo(5))] })
    : isJobs(u) ? jsonRes({ ledgers: [{ kind: 'issue_state', key: KEY, status: 'closed', updated_at: isoAgo(1) }] })
      : jsonRes(payload())), async () => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(body.stage_added, 0);
    assert.equal(body.columns.review.length, 0);
  });
});

test('K8c. onRequest with the stage read answering 500 changes no column', () =>
  withFetch((u) => (isStage(u) ? new Response('boom', { status: 500 })
    : isJobs(u) ? jsonRes({ ledgers: [] })
      : jsonRes(payload())), async () => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(body.stage_known, false);
    assert.deepEqual(body.columns, payload().columns);
  }));
