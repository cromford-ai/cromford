import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, installWindow, routedFetch, all, fire, isDisabled, dialogOf, confirmOf, buttonIn, type } from './helpers/fake-dom.bh-5750.js';

// BH-6825 (Staff in Mission Control 4/4): the LEARNING panel on /staff/:agent.
// The pure half (lib/staff-learning.js) is driven directly; the pure view
// (AgentLearningView) is rendered server-side; the routed /staff/watchman (the
// real ROUTES table, so StaffAgentScreen -> StaffAgentView mounts
// AgentLearning) is mounted into the fake DOM against a stubbed fetch, so the
// reads and the decide write go through the real api.js; and the coord
// proxy's new row is driven through onRequest.

installWindow();
const { render: mount } = await import('preact');
const { render } = await import('preact-render-to-string');
const lib = await import('../src/lib/staff-learning.js');
const { learningState, pct, outcomeHref, decideBody, errorText, readBackText } = lib;
const { AgentLearningView } = await import('../src/screens/staff/agent-learning.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');

// ---------------------------------------------------------------- fixtures
// The shapes GET /api/staff/learning and /api/staff/learning/outcomes answer
// (worker/jobs/src/routes/staff-learning.js).
const win = (days, merged, rejected, noise) => {
  const total = merged + rejected + noise;
  return {
    days, source: 'settings', merged, rejected, noise, total, agree: merged, overrule: rejected + noise,
    precision: total ? merged / total : null, noise_rate: total ? noise / total : null
  };
};
const outRow = (id, outcome, findingId) => ({
  id, class: 'leak', outcome, verdict: outcome === 'merged' ? 'agree' : 'overrule',
  ticket_url: `https://github.com/example-org/cromford/issues/${id}`, resolved_at: `2199-10-1${id % 6}T00:00:00Z`,
  finding_id: findingId
});
function payload({ promotion = true, empty = false, decisions = true } = {}) {
  const evidence = Array.from({ length: 20 }, (_, i) => outRow(500 - i, 'merged', 100 + i));
  return {
    agent: { name: 'watchman', autonomy: 'automation', cap: 'augmentation', status: 'active' },
    windows: empty ? [win(7, 0, 0, 0), win(30, 0, 0, 0)] : [win(7, 1, 0, 1), win(30, 2, 1, 1)],
    promotion: promotion ? {
      id: 41, agent: 'watchman', status: 'pending', from_level: 'automation', to_level: 'augmentation', agreements: 5,
      created_at: '2199-10-15T10:00:00Z', decided_at: null, stale: false,
      evidence: { rows: evidence, total: 25, truncated: true, since: '2199-10-01T00:00:00Z' }
    } : null,
    decisions: decisions ? [{ id: 3, promotion_id: 30, decision: 'void', from_level: 'automation', to_level: 'augmentation', reason: 'too early, fixture', actor: 'operator@example.com', decided_at: '2199-10-12T09:00:00Z' }] : [],
    decisions_more: false,
    page_max: { value: 100, source: 'settings' },
    retention_days: { value: 180, source: 'settings' },
    as_of: '2199-10-16T00:00:00Z'
  };
}
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (over = {}) => render(h(AgentLearningView, {
  agent: 'watchman', state: ok(payload()), drill: null, onCount() {}, onOlder() {}, onDecide() {}, busy: false, note: null, dialog: null, ...over
}));

// ---------------------------------------------------------------- U1-U3
test('U1 pct: null is "n/a (no outcomes)", never 0%; outcomeHref links a finding or is null', () => {
  assert.equal(pct(null), 'n/a (no outcomes)');
  assert.equal(pct(undefined), 'n/a (no outcomes)');
  assert.equal(pct(0), '0%');
  assert.equal(pct(0.5), '50%');
  assert.equal(pct(5 / 6), '83%');
  assert.equal(outcomeHref(12), '/staff/finding/12');
  assert.equal(outcomeHref(null), null);
});

test('U2 learningState: a body without windows is a failed read (null); decideBody refuses a blank or long reason', () => {
  assert.equal(learningState(null), null);
  assert.equal(learningState({ error: 'agent not found' }), null);
  assert.equal(learningState({ ...payload(), windows: undefined }), null);
  assert.equal(learningState({ ...payload(), decisions: undefined }), null);
  const s = learningState(payload({ promotion: false, decisions: false }));
  assert.equal(s.promotion, null);
  assert.deepEqual(s.decisions, []);
  assert.equal(s.windows.length, 2);
  assert.deepEqual(decideBody({ id: 41, decision: 'approve', reason: ' earned ' }), { id: 41, decision: 'approve', reason: 'earned' });
  assert.deepEqual(decideBody({ id: 41, decision: 'void', reason: 'no' }), { id: 41, decision: 'void', reason: 'no' });
  assert.equal(decideBody({ id: 41, decision: 'approve', reason: '   ' }), null);
  assert.equal(decideBody({ id: 41, decision: 'approve', reason: 'x'.repeat(501) }), null);
  assert.equal(decideBody({ id: '41', decision: 'approve', reason: 'r' }), null);
  assert.equal(decideBody({ id: 41, decision: 'applied', reason: 'r' }), null);
});

test('U3 errorText has one plain sentence per refusal; readBackText reads the answer, not the request', () => {
  const e = (error, extra = {}) => Object.assign(new Error(error), { status: 409, body: { error, ...extra } });
  assert.match(errorText(e('stale_level', { autonomy: 'augmentation', from_level: 'automation' })), /level moved to augmentation/);
  assert.match(errorText(e('above_cap', { to_level: 'augmentation', cap: 'automation' })), /above the cap \(automation\)/);
  assert.match(errorText(e('agent_not_active', { status: 'paused' })), /paused/);
  assert.match(errorText(e('not_pending', { status: 'void' })), /already void/);
  assert.match(errorText(e('agent_approver')), /a staff agent or archie/);
  assert.match(errorText(e('reason')), /reason/);
  assert.match(errorText(new Error('network unreachable')), /network unreachable/);
  const answer = {
    ok: true,
    promotion: { id: 41, status: 'applied', from_level: 'automation', to_level: 'augmentation', decided_at: '2199-10-16T00:10:00Z' },
    decision: { decision: 'approve', reason: 'earned', actor: 'operator@example.com', decided_at: '2199-10-16T00:10:00Z' },
    agent: { name: 'watchman', autonomy: 'augmentation', cap: 'augmentation', status: 'active' }
  };
  assert.equal(readBackText(answer), 'Approved. Watchman is now augmentation. Reason recorded for operator@example.com at 2199-10-16T00:10:00Z.');
  const voided = { ...answer, promotion: { ...answer.promotion, status: 'void' }, decision: { ...answer.decision, decision: 'void' }, agent: { ...answer.agent, autonomy: 'automation' } };
  assert.equal(readBackText(voided), 'Voided. Watchman stays automation. Reason recorded for operator@example.com at 2199-10-16T00:10:00Z.');
  assert.match(readBackText({ ...answer, existing: true }), /^Already approved\./);
  assert.equal(readBackText({ ok: true }), null, 'no read-back, no claim');
});

// ---------------------------------------------------------------- V1, V7
test('V1 the view: precision 50%, the counts as drill-down buttons, the proposal with 20 evidence rows linking findings', () => {
  const out = view();
  assert.match(out, /section__title">LEARNING</);
  for (const head of ['WINDOW', 'PRECISION', 'NOISE RATE', 'MERGED', 'REJECTED', 'NOISE', 'TOTAL']) {
    assert.match(out, new RegExp(`<th aria-sort="(none|ascending|descending)"[^>]*>\\s*<button[^>]*>\\s*${head}`), head);
  }
  assert.match(out, />50%</);
  assert.match(out, />25%</, 'the 30-day noise rate');
  assert.match(out, /aria-label="1 noise outcomes in 30 days"/);
  assert.match(out, /aria-label="4 outcomes in 30 days"/);
  assert.doesNotMatch(out, /aria-label="0 rejected outcomes in 7 days"/, 'a 0 count is not a button');
  const prop = out.slice(out.indexOf('PROMOTION PROPOSAL'));
  assert.match(prop, /automation → augmentation/);
  const links = prop.match(/href="\/staff\/finding\/\d+"/g) || [];
  assert.equal(links.length, 20);
  assert.match(prop, /href="\/staff\/finding\/100"/);
  assert.match(prop, /showing 20 of 25/);
  assert.match(prop, /<button[^>]*>APPROVE…<\/button>/);
  assert.match(prop, /<button[^>]*>VOID…<\/button>/);
  assert.match(out, /too early, fixture/);
  assert.match(view({ state: ok({ ...payload(), promotion: { ...payload().promotion, stale: true } }) }), /level moved since the proposal/);
});

test('V7 the empty state, the loading state and a failed read are three different screens', () => {
  const empty = view({ state: ok(payload({ empty: true, promotion: false, decisions: false })) });
  assert.match(empty, /no outcomes in the last 7 days/);
  assert.match(empty, /no outcomes in the last 30 days/);
  assert.match(empty, /no pending proposal/);
  assert.match(empty, /n\/a \(no outcomes\)/);
  assert.doesNotMatch(empty, /could not load/);
  assert.doesNotMatch(empty, /aria-label="0 /);
  const loading = view({ state: { data: null, error: null, loading: true, reload() {} } });
  assert.match(loading, /class="skel"/);
  assert.doesNotMatch(loading, /no pending proposal/);
  const failed = view({ state: { data: null, error: new Error('agent not found'), loading: false, reload() {} } });
  assert.match(failed, /could not load/);
  assert.match(failed, /agent not found/);
  assert.doesNotMatch(failed, /no pending proposal/);
  assert.doesNotMatch(failed, /no outcomes in the last/);
});

// ------------------------------------------------------------- routed mount
const ROSTER = {
  agents: [{ name: 'watchman', kind: 'staff', role: 'security', accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: 0, precision: null, spend_usd: null }],
  sources: {}, as_of: '2199-10-16T00:00:00Z'
};
const DECIDED = {
  ok: true,
  promotion: { id: 41, agent: 'watchman', status: 'applied', from_level: 'automation', to_level: 'augmentation', agreements: 5, created_at: '2199-10-15T10:00:00Z', decided_at: '2199-10-16T00:10:00Z' },
  decision: { id: 9, promotion_id: 41, decision: 'approve', from_level: 'automation', to_level: 'augmentation', reason: 'earned it', actor: 'operator@example.com', decided_at: '2199-10-16T00:10:00Z' },
  agent: { name: 'watchman', autonomy: 'augmentation', cap: 'augmentation', status: 'active' }
};
// The world: `decide` answers the POST, `pages` the drill-down by its before.
// After a 2xx decide the roster answers the agent at `rosterAfter` (the level
// the write left it at), as the real roster read would.
const rosterAt = (autonomy) => ({ ...ROSTER, agents: ROSTER.agents.map((a) => ({ ...a, autonomy })) });
function world({ decide = () => [200, DECIDED], pages = {}, rosterAfter = 'augmentation' } = {}) {
  let decided = false;
  const calls = routedFetch((u, method, body) => {
    if (u === '/api/coord/staff/roster') return [200, decided ? rosterAt(rosterAfter) : ROSTER];
    if (u === '/api/coord/staff/findings?agent=watchman') return [200, { agent: 'watchman', findings: [], truncated: false }];
    if (u === '/api/coord/staff/learning?agent=watchman') return [200, decided ? payload({ promotion: false }) : payload()];
    if (u.startsWith('/api/coord/staff/learning/outcomes?')) {
      const q = new URLSearchParams(u.split('?')[1]);
      return [200, pages[q.get('before') || ''] || { rows: [], truncated: false, next_before: null }];
    }
    if (u === '/api/coord/staff/promotions/decide' && method === 'POST') {
      const [status, ans] = decide(body);
      if (status === 200) decided = true;
      return [status, ans];
    }
    return [404, { error: 'unknown endpoint' }];
  });
  return calls;
}
let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });
async function mountAt(path) {
  const doc = installDom();
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  assert.ok(hit, `a route matches ${path}`);
  root = doc.createElement('div');
  mount(h(hit[1], hit[0]), root);
  await waitFor(() => root.textContent.includes('PROMOTION PROPOSAL') && root.textContent.includes('APPROVE…'), 'the learning panel', () => root.textContent.slice(0, 400));
  return root;
}
const byAria = (r, label) => all(r).find((n) => n.attrs && n.attrs['aria-label'] === label);
const learningGets = (calls) => calls.filter((c) => c.method === 'GET' && c.url === '/api/coord/staff/learning?agent=watchman');

test('W1 the routed /staff/watchman mounts the LEARNING panel and reads it through the coord proxy path', async () => {
  const calls = world();
  const r = await mountAt('/staff/watchman');
  assert.equal(learningGets(calls).length, 1);
  assert.ok(all(r).some((n) => n.attrs && n.attrs.class === 'section__title' && n.textContent === 'LEARNING'));
  assert.ok(byAria(r, '1 noise outcomes in 30 days'));
});

test('V2 clicking the 30-day NOISE count reads that count\'s rows and links each finding; a 0 count is not a button', async () => {
  const calls = world({ pages: { '': { rows: [outRow(7, 'noise', 70)], truncated: false, next_before: null } } });
  const r = await mountAt('/staff/watchman');
  assert.equal(byAria(r, '0 rejected outcomes in 7 days'), undefined);
  fire(byAria(r, '1 noise outcomes in 30 days'), 'click');
  await waitFor(() => r.textContent.includes('OUTCOMES'), 'the OUTCOMES list');
  await flush();
  const drill = calls.filter((c) => c.url.startsWith('/api/coord/staff/learning/outcomes'));
  assert.equal(drill.length, 1);
  assert.equal(drill[0].url, '/api/coord/staff/learning/outcomes?agent=watchman&days=30&outcome=noise');
  assert.ok(all(r).some((n) => n.localName === 'a' && n.attrs.href === '/staff/finding/70'), 'the row links its finding');
});

test('V3 OLDER sends the cursor and appends; a removed finding says so, with no link', async () => {
  const calls = world({
    pages: {
      '': { rows: [outRow(9, 'merged', 90), outRow(8, 'merged', null)], truncated: true, next_before: '2199-10-12T00:00:00Z|8' },
      '2199-10-12T00:00:00Z|8': { rows: [outRow(5, 'merged', 50)], truncated: false, next_before: null }
    }
  });
  const r = await mountAt('/staff/watchman');
  fire(byAria(r, '4 outcomes in 30 days'), 'click');
  await waitFor(() => buttonIn(r, 'OLDER'), 'the OLDER button');
  assert.match(r.textContent, /finding removed/);
  assert.match(r.textContent, /2 of 4 loaded; sort covers the loaded rows/);
  fire(buttonIn(r, 'OLDER'), 'click');
  await waitFor(() => all(r).some((n) => n.localName === 'a' && n.attrs.href === '/staff/finding/50'), 'the second page');
  const drill = calls.filter((c) => c.url.startsWith('/api/coord/staff/learning/outcomes'));
  assert.equal(drill.length, 2);
  assert.equal(drill[1].url, '/api/coord/staff/learning/outcomes?agent=watchman&days=30&outcome=all&before=2199-10-12T00%3A00%3A00Z%7C8');
  assert.ok(all(r).some((n) => n.localName === 'a' && n.attrs.href === '/staff/finding/90'), 'the first page stays');
  assert.equal(buttonIn(r, 'OLDER'), undefined, 'no OLDER on the last page');
  assert.match(r.textContent, /3 of 4 loaded/);
});

test('V3b a slow page never lands on a newer selection: the late answer of the first count is dropped', async () => {
  world({
    pages: { '': { rows: [outRow(9, 'merged', 90)], truncated: false, next_before: null } }
  });
  const fast = globalThis.fetch;
  let release = null;
  globalThis.fetch = async (url, init) => {
    if (String(url).includes('outcome=noise')) {
      await new Promise((r) => { release = r; });
      return { ok: true, status: 200, text: async () => JSON.stringify({ rows: [outRow(7, 'noise', 70)], truncated: false, next_before: null }) };
    }
    return fast(url, init);
  };
  const r = await mountAt('/staff/watchman');
  fire(byAria(r, '1 noise outcomes in 30 days'), 'click');
  await waitFor(() => release !== null, 'the slow noise read to start');
  fire(byAria(r, '4 outcomes in 30 days'), 'click');
  await waitFor(() => all(r).some((n) => n.localName === 'a' && n.attrs.href === '/staff/finding/90'), 'the newer selection');
  release();
  await flush();
  assert.ok(all(r).some((n) => n.localName === 'a' && n.attrs.href === '/staff/finding/90'), 'the newer rows stay');
  assert.ok(!all(r).some((n) => n.localName === 'a' && n.attrs.href === '/staff/finding/70'), 'the late answer is dropped');
  assert.match(r.textContent, /all outcomes in the last 30 days/);
});

test('V4 APPROVE… opens the in-app modal; confirm waits for a reason; one POST; the note is the read-back and the panel re-reads', async () => {
  const calls = world();
  const r = await mountAt('/staff/watchman');
  fire(buttonIn(r, 'APPROVE…'), 'click');
  await flush();
  const dlg = dialogOf(r);
  assert.ok(dlg, 'a role=dialog modal');
  assert.match(dlg.parentNode.attrs.class, /modal__scrim/);
  const reason = byAria(dlg, 'reason');
  assert.equal(reason && reason.localName, 'textarea');
  assert.equal(isDisabled(confirmOf(dlg)), true, 'confirm starts blocked');
  type(reason, '   ');
  await flush();
  assert.equal(isDisabled(confirmOf(dialogOf(r))), true, 'a blank reason keeps it blocked');
  type(byAria(dialogOf(r), 'reason'), 'earned it');
  await flush();
  assert.equal(isDisabled(confirmOf(dialogOf(r))), false);
  fire(confirmOf(dialogOf(r)), 'click');
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => !dialogOf(r), 'the modal to close');
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1, 'a double click writes once');
  assert.equal(posts[0].url, '/api/coord/staff/promotions/decide');
  assert.deepEqual(posts[0].body, { id: 41, decision: 'approve', reason: 'earned it' });
  await waitFor(() => r.textContent.includes(readBackText(DECIDED)), 'the read-back note', () => r.textContent.slice(0, 600));
  await waitFor(() => learningGets(calls).length === 2, 'the panel to re-read');
  await waitFor(() => r.textContent.includes('no pending proposal'), 'the re-read to render');
});

test('V5 a 409 stale_level keeps the modal open with the sentence; nothing says Approved', async () => {
  const calls = world({ decide: () => [409, { error: 'stale_level', autonomy: 'augmentation', from_level: 'automation' }] });
  const r = await mountAt('/staff/watchman');
  fire(buttonIn(r, 'APPROVE…'), 'click');
  await flush();
  type(byAria(dialogOf(r), 'reason'), 'late');
  await flush();
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => /level moved to augmentation/.test(dialogOf(r) ? dialogOf(r).textContent : ''), 'the refusal in the modal');
  assert.ok(dialogOf(r), 'the modal stays open');
  assert.doesNotMatch(r.textContent, /Approved/);
  assert.equal(byAria(dialogOf(r), 'reason').value, 'late', 'the typed reason stays');
  assert.equal(learningGets(calls).length, 1, 'no re-read on a refusal');
});

test('V6 VOID… posts decision void', async () => {
  const voided = { ...DECIDED, promotion: { ...DECIDED.promotion, status: 'void' }, decision: { ...DECIDED.decision, decision: 'void', reason: 'too early' }, agent: { ...DECIDED.agent, autonomy: 'automation' } };
  const calls = world({ decide: () => [200, voided] });
  const r = await mountAt('/staff/watchman');
  fire(buttonIn(r, 'VOID…'), 'click');
  await flush();
  type(byAria(dialogOf(r), 'reason'), 'too early');
  await flush();
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => !dialogOf(r), 'the modal to close');
  const posts = calls.filter((c) => c.method === 'POST');
  assert.deepEqual(posts.map((p) => p.body), [{ id: 41, decision: 'void', reason: 'too early' }]);
  await waitFor(() => r.textContent.includes('Voided. Watchman stays automation.'), 'the void read-back');
});

// QA FAIL on PR #7034: the AUTONOMY fact at the top of /staff/:agent comes from
// the roster read. A decide must re-read it, or the page shows the old level
// next to the "now augmentation" read-back until a full reload.
const factOf = (r, key) => {
  const dts = all(r).filter((n) => n.localName === 'dt' && n.textContent === key);
  assert.equal(dts.length, 1, `one ${key} fact`);
  const kids = dts[0].parentNode.childNodes;
  return kids[kids.indexOf(dts[0]) + 1].textContent;
};
const rosterGets = (calls) => calls.filter((c) => c.method === 'GET' && c.url === '/api/coord/staff/roster');

test('V8 after a 2xx APPROVE the AUTONOMY fact at the top of the page shows the new level with no reload', async () => {
  const calls = world();
  const r = await mountAt('/staff/watchman');
  assert.equal(factOf(r, 'AUTONOMY'), 'automation');
  assert.equal(rosterGets(calls).length, 1);
  fire(buttonIn(r, 'APPROVE…'), 'click');
  await flush();
  type(byAria(dialogOf(r), 'reason'), 'earned it');
  await flush();
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => r.textContent.includes(readBackText(DECIDED)), 'the read-back note');
  await waitFor(() => factOf(r, 'AUTONOMY') === 'augmentation', 'the AUTONOMY fact to update', () => `AUTONOMY=${factOf(r, 'AUTONOMY')} roster GETs=${rosterGets(calls).length}`);
  assert.equal(rosterGets(calls).length, 2, 'the roster is read once more, not polled');
});

test('V8b a VOID re-reads the roster too; a refused decide (409) does not', async () => {
  const voided = { ...DECIDED, promotion: { ...DECIDED.promotion, status: 'void' }, decision: { ...DECIDED.decision, decision: 'void' }, agent: { ...DECIDED.agent, autonomy: 'automation' } };
  let calls = world({ decide: () => [200, voided], rosterAfter: 'automation' });
  let r = await mountAt('/staff/watchman');
  fire(buttonIn(r, 'VOID…'), 'click');
  await flush();
  type(byAria(dialogOf(r), 'reason'), 'too early');
  await flush();
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => rosterGets(calls).length === 2, 'the roster re-read after a void');
  assert.equal(factOf(r, 'AUTONOMY'), 'automation');
  mount(null, root); root = null;

  calls = world({ decide: () => [409, { error: 'stale_level', autonomy: 'augmentation', from_level: 'automation' }] });
  r = await mountAt('/staff/watchman');
  fire(buttonIn(r, 'APPROVE…'), 'click');
  await flush();
  type(byAria(dialogOf(r), 'reason'), 'late');
  await flush();
  fire(confirmOf(dialogOf(r)), 'click');
  await waitFor(() => /level moved to augmentation/.test(dialogOf(r) ? dialogOf(r).textContent : ''), 'the refusal');
  await flush();
  assert.equal(rosterGets(calls).length, 1, 'no roster re-read on a refusal');
});

// ---------------------------------------------------------------- W2
const SECRET = 'fixture-harness-secret';
const CONSOLE = 'https://harness-console.operator.workers.dev';
let seq = 0;
const proxy = (rest, method, body) => onRequest({
  request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
    method, headers: { cookie: `dash=bh6825-${++seq}`, 'content-type': 'application/json' }, body
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: rest.split('/') }
});

test('W2 the coord proxy admits POST staff/promotions/decide with id, decision and reason only, the actor stamped; a blank reason is 400', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const res = await proxy('staff/promotions/decide', 'POST', JSON.stringify({ id: 41, decision: 'approve', reason: 'earned', actor: 'watchman', extra: 'x' }));
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, 'https://harness-jobs.operator.workers.dev/api/staff/promotions/decide');
    const fwd = JSON.parse(seen[0].body);
    assert.deepEqual(Object.keys(fwd).sort(), ['actor', 'decision', 'id', 'reason']);
    assert.equal(fwd.id, 41);
    assert.notEqual(fwd.actor, 'watchman', 'the browser actor is replaced by the stamp');
    const blank = await proxy('staff/promotions/decide', 'POST', JSON.stringify({ id: 41, decision: 'approve', reason: '  ' }));
    assert.equal(blank.status, 400);
    assert.equal((await proxy('staff/promotions/decide', 'PUT', JSON.stringify({ id: 41, decision: 'approve', reason: 'r' }))).status, 405);
    assert.equal(seen.length, 1, 'a refused write forwards nothing');
  } finally { globalThis.fetch = real; }
});
