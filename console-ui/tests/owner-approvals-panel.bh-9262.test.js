import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import {
  installDom, installWindow, routedFetch, all, fire, isDisabled, dialogOf, buttonIn, confirmOf, rowsOf, type
} from './helpers/fake-dom.bh-5750.js';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';
import { _resetCertsCache } from '../functions/_lib/access-identity.js';

// BH-9262 (C1): the owner-approval inbox on /machines (#owner-approvals). A
// chat caller (bin/archie.sh delegate, bin/box-request.sh) that the worker
// refused for want of an owner proof files a row; the owner acts on it here.
//   - The panel is reached through the real MachinesScreen, with the real api
//     client and a routed fetch. Native dialogs throw.
//   - REVIEW on a box_command row runs the screen's own boxOp (the priced
//     launch dialog, the confirm+reason dialog), and decide `approved` is
//     posted only after that command was queued, with the command id.
//   - APPROVE on an archie_delegation row asks in an in-app modal, posts the
//     archie delegation, then decide `approved` with the class.
//   - A refusal (403 human_proof_required, 409 not_earned) is a banner and NO
//     decide; DECLINE posts decide `declined`.
//   - The two coord write rows carry the box-ops proof only for an Access
//     identity, and refuse a non-integer min_streak with a 400.

installWindow();
const { render: mount } = await import('preact');
const { MachinesScreen } = await import('../src/screens/Machines.js');

const FIXED_NOW = Date.parse('2026-11-16T12:00:00Z');
Date.now = () => FIXED_NOW;
const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
const LAUNCH_OK = 'capacity: pool fits 2 more 4c boxes on acct-fixture | box-launch: box=gamma usd_mo=40 smoke=pending';

const LAUNCH_ROW = {
  id: 7, kind: 'box_command', dedupe_key: 'box:orgo_launch_quote:gamma:cmd-fixture-1',
  payload: { box: 'hub', type: 'orgo_launch_quote', target: 'gamma', account: 'acct-fixture', project: 'proj-fixture', vcpus: 4, mem_gb: 16, disk_gb: 100, reason: 'chat: /box launch proj-fixture' },
  actor: 'operator@example.com', via: 'telegram:operator', status: 'pending', created_at: ago(30), decided_at: null, decided_by: null, result_ref: null
};
const ARCHIE_ROW = {
  id: 8, kind: 'archie_delegation', dedupe_key: 'archie-delegation:lint-fixes:cmd-fixture-2',
  payload: { class: 'lint-fixes', min_streak: 5 },
  actor: 'chat', via: 'telegram:operator', status: 'pending', created_at: ago(5), decided_at: null, decided_by: null, result_ref: null
};
const CAP_ROW = {
  id: 9, kind: 'box_command', dedupe_key: 'box:fly_pool_cap:proj-fixture:cmd-fixture-3',
  payload: { box: 'hub', type: 'fly_pool_cap', target: 'proj-fixture', cap: 3, reason: 'chat: yes' },
  actor: 'operator@example.com', via: 'telegram:operator', status: 'pending', created_at: ago(60), decided_at: null, decided_by: null, result_ref: null
};

// The world the screen reads. `approvals` is what GET owner-approvals answers;
// `delegation` and `decide` override those answers.
function world({ approvals = () => [LAUNCH_ROW, ARCHIE_ROW], approvalsStatus = 200, quote = () => null, delegation, decide, boxPost } = {}) {
  const posted = { box: [], decide: [], delegation: [] };
  const calls = routedFetch((u, method, body) => {
    if (u === '/api/dash/machines') return [200, { boxes: { 'bw-alpha': '1m ago' }, fly: {}, fly_errors: [], snapshot_age_min: 1 }];
    if (u === '/api/coord/orgo-computers') return [200, { computers: [], accounts: { 'acct-fixture': { read_at: ago(1), ok: true, complete: true } }, as_of: ago(0) }];
    if (u.startsWith('/api/coord/owner-approvals') && method === 'GET') {
      return approvalsStatus === 200 ? [200, { approvals: approvals(), truncated: false, as_of: ago(0) }] : [approvalsStatus, { error: 'owner_approvals unavailable' }];
    }
    const m = /^\/api\/coord\/owner-approvals\/(\d+)\/decide$/.exec(u);
    if (m && method === 'POST') {
      posted.decide.push({ id: Number(m[1]), ...body });
      if (decide) return decide(body);
      return [200, { ok: true, approval: { id: Number(m[1]), status: body.decision } }];
    }
    if (u === '/api/coord/archie/classes/delegation' && method === 'POST') {
      posted.delegation.push(body);
      if (delegation) return delegation(body);
      return [200, { ok: true, class_state: { class: body.class, state: 'delegated' } }];
    }
    if (u.startsWith('/api/coord/box-commands') && method === 'GET') { const q = quote(); return [200, { commands: q ? [q] : [], truncated: false }]; }
    if (u === '/api/coord/box-commands' && method === 'POST') {
      posted.box.push(body);
      if (boxPost) return boxPost(body);
      const id = 60 + posted.box.length;
      return [201, { id, status: 'requested', command: { id, ...body }, deduped: false }];
    }
    return [404, { error: 'not_found' }];
  });
  return { calls, posted };
}

let root = null;
const events = [];
afterEach(() => { if (root) { mount(null, root); root = null; } });
const panel = () => all(root).find((n) => n.attrs && n.attrs.id === 'owner-approvals');
const rowOf = (text) => rowsOf(panel()).find((tr) => tr.textContent.includes(text));
const bannerText = () => (all(root).find((n) => n.attrs && n.attrs.role === 'status' && /banner/.test(n.attrs.class || '')) || { textContent: '' }).textContent;
async function screen() {
  const doc = installDom();
  window.dispatchEvent = (e) => { events.push(e.type); };
  root = doc.createElement('div');
  mount(h(MachinesScreen, { quotePoll: { intervalMs: 1, timeoutMs: 3000 } }), root);
  await waitFor(() => panel() && !/loading/i.test(panel().attrs['data-state'] || ''), 'the OWNER APPROVALS panel', () => root.textContent);
  await flush();
  return doc;
}

test('O1: the panel is on /machines at #owner-approvals; rows show the action, who asked and how; the headers sort', async () => {
  world();
  await screen();
  await waitFor(() => rowOf('gamma') && rowOf('lint-fixes'), 'two approval rows', () => panel().textContent);
  const launch = rowOf('gamma').textContent;
  assert.match(launch, /LAUNCH PRICE/, 'the action label');
  assert.match(launch, /proj-fixture/);
  assert.match(launch, /4 vCPU/);
  assert.match(launch, /operator@example\.com/);
  assert.match(launch, /telegram:operator/, 'the verified sender the hub recorded');
  assert.match(launch, /PENDING/);
  assert.ok(buttonIn(rowOf('gamma'), 'REVIEW'), 'REVIEW on a box command');
  assert.ok(buttonIn(rowOf('lint-fixes'), 'APPROVE'), 'APPROVE on a delegation');
  assert.ok(buttonIn(rowOf('lint-fixes'), 'DECLINE'));
  assert.match(rowOf('lint-fixes').textContent, /delegate lint-fixes/i);
  // newest first by default; a header click flips the direction.
  const th = all(panel()).find((n) => n.localName === 'th' && /REQUESTED/.test(n.textContent));
  assert.equal(th.attrs['aria-sort'], 'descending');
  const order = () => rowsOf(panel()).slice(1).map((tr) => (tr.textContent.includes('gamma') ? 'launch' : 'archie'));
  assert.deepEqual(order(), ['archie', 'launch']);
  fire(all(th).find((n) => n.localName === 'button'), 'click');
  await flush();
  const th2 = all(panel()).find((n) => n.localName === 'th' && /REQUESTED/.test(n.textContent));
  assert.equal(th2.attrs['aria-sort'], 'ascending');
  assert.deepEqual(order(), ['launch', 'archie']);
});

test('O2: no pending row is the empty state; a failed read is an error, not "nothing waits"', async () => {
  world({ approvals: () => [] });
  await screen();
  await waitFor(() => /Nothing waits for your approval/.test(panel().textContent), 'the empty state', () => panel().textContent);
  mount(null, root); root = null;
  world({ approvalsStatus: 503 });
  await screen();
  await waitFor(() => /owner_approvals unavailable/.test(panel().textContent), 'the error', () => panel().textContent);
  assert.doesNotMatch(panel().textContent, /Nothing waits/);
});

test('O3: REVIEW on a launch request opens the priced launch dialog with its spec; decide approved carries the launch id', async () => {
  let quote = null;
  const w = world({ quote: () => quote });
  await screen();
  await waitFor(() => rowOf('gamma'), 'the launch row');
  fire(buttonIn(rowOf('gamma'), 'REVIEW'), 'click');
  await waitFor(() => w.posted.box.length === 1 && dialogOf(root), 'the launch quote POST and dialog');
  const q = w.posted.box[0];
  assert.equal(q.type, 'orgo_launch_quote');
  assert.equal(q.target, 'gamma');
  assert.equal(q.project, 'proj-fixture');
  assert.equal(q.account, 'acct-fixture');
  assert.equal(q.vcpus, 4);
  assert.equal(q.mem_gb, 16);
  assert.equal(q.disk_gb, 100);
  assert.equal(w.posted.decide.length, 0, 'no decide before the launch');
  quote = { id: 61, box: 'hub', type: 'orgo_launch_quote', target: 'gamma', status: 'ok', detail: LAUNCH_OK, requested_at: ago(0), finished_at: ago(0) };
  await waitFor(() => /usd_mo=40/.test(dialogOf(root).textContent) && !isDisabled(confirmOf(dialogOf(root))), 'the priced LAUNCH', () => dialogOf(root).textContent);
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => w.posted.decide.length === 1, 'the decide POST', () => root.textContent);
  assert.equal(w.posted.box[1].type, 'orgo_launch');
  assert.equal(w.posted.box[1].quote_id, 61);
  assert.equal(w.posted.box[1].confirm_monthly_usd, '40');
  assert.deepEqual(w.posted.decide[0], { id: 7, decision: 'approved', result_ref: '62' });
  await waitFor(() => /approval #7 approved/.test(bannerText()), 'the banner', () => root.textContent);
});

test('O4: APPROVE on a delegation asks in an in-app modal, posts the archie delegation, then decide approved', async () => {
  const w = world();
  await screen();
  await waitFor(() => rowOf('lint-fixes'), 'the delegation row');
  fire(buttonIn(rowOf('lint-fixes'), 'APPROVE'), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d, 'the in-app confirm');
  assert.match(d.textContent, /lint-fixes/);
  assert.equal(w.posted.delegation.length, 0, 'nothing before the confirm');
  fire(confirmOf(d), 'click');
  await waitFor(() => w.posted.decide.length === 1, 'the decide POST', () => root.textContent);
  assert.equal(w.posted.delegation.length, 1);
  assert.equal(w.posted.delegation[0].class, 'lint-fixes');
  assert.equal(w.posted.delegation[0].decision, 'delegate');
  assert.equal(w.posted.delegation[0].min_streak, 5);
  assert.deepEqual(w.posted.decide[0], { id: 8, decision: 'approved', result_ref: 'lint-fixes' });
  await waitFor(() => /approval #8 approved/.test(bannerText()), 'the banner', () => root.textContent);
});

test('O5: a refusal (409 not_earned, 403 human_proof_required) is a banner, the session stays, and no decide is posted', async () => {
  for (const [status, body, re] of [
    [409, { error: 'not_earned', streak: 2 }, /not_earned/],
    [403, { error: 'human_proof_required' }, /human_proof_required/]
  ]) {
    events.length = 0;
    const w = world({ delegation: () => [status, body] });
    await screen();
    await waitFor(() => rowOf('lint-fixes'), 'the delegation row');
    fire(buttonIn(rowOf('lint-fixes'), 'APPROVE'), 'click');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await waitFor(() => re.test(bannerText()), `the ${status} banner`, () => root.textContent);
    assert.equal(w.posted.delegation.length, 1);
    assert.equal(w.posted.decide.length, 0, `no decide after a ${status}`);
    assert.ok(rowOf('lint-fixes'), 'the row stays');
    assert.equal(events.includes('dash:unauthorized'), false, 'a proof refusal is not a lost session');
    mount(null, root); root = null;
  }
});

test('O6: DECLINE posts decide declined and runs no action', async () => {
  const w = world();
  await screen();
  await waitFor(() => rowOf('gamma'), 'the launch row');
  fire(buttonIn(rowOf('gamma'), 'DECLINE'), 'click');
  await waitFor(() => w.posted.decide.length === 1, 'the decide POST');
  assert.deepEqual(w.posted.decide[0], { id: 7, decision: 'declined' });
  assert.equal(w.posted.box.length, 0);
  assert.equal(w.posted.delegation.length, 0);
  await waitFor(() => /approval #7 declined/.test(bannerText()), 'the banner', () => root.textContent);
});

test('O7: REVIEW on a pool cap request opens the confirm+reason dialog; decide carries the command id', async () => {
  const w = world({ approvals: () => [CAP_ROW] });
  await screen();
  await waitFor(() => rowOf('proj-fixture'), 'the cap row');
  fire(buttonIn(rowOf('proj-fixture'), 'REVIEW'), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d);
  assert.match(d.textContent, /pool cap for proj-fixture to 3/);
  type(all(d).find((n) => n.localName === 'input'), 'owner ok');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => w.posted.decide.length === 1, 'the decide POST', () => root.textContent);
  assert.equal(w.posted.box[0].type, 'fly_pool_cap');
  assert.equal(w.posted.box[0].target, 'proj-fixture');
  assert.equal(w.posted.box[0].cap, 3);
  assert.deepEqual(w.posted.decide[0], { id: 9, decision: 'approved', result_ref: '61' });
});

test('O8: a refused REVIEW (403 owner_only, proof required) is a banner; the row stays and no decide is posted', async () => {
  events.length = 0;
  const w = world({ approvals: () => [CAP_ROW], boxPost: () => [403, { error: 'owner_only', proof: 'required' }] });
  await screen();
  await waitFor(() => rowOf('proj-fixture'), 'the cap row');
  fire(buttonIn(rowOf('proj-fixture'), 'REVIEW'), 'click');
  await flush();
  type(all(dialogOf(root)).find((n) => n.localName === 'input'), 'owner ok');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => /owner_only/.test(bannerText()), 'the refusal banner', () => root.textContent);
  assert.equal(w.posted.box.length, 1);
  assert.equal(w.posted.decide.length, 0, 'no decide after a refused command');
  assert.doesNotMatch(bannerText(), /no command id/, 'a refusal is reported as a refusal');
  assert.ok(rowOf('proj-fixture'), 'the row stays');
  assert.equal(events.includes('dash:unauthorized'), false);
});

// --- the coord proxy rows (the coord-box-ops.bh-9262 pattern) ---------------

const JOBS = 'https://harness-jobs.operator.workers.dev';
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud-9262-c1';
const SECRET = 'test-harness-secret-fixture-9262';
const BOX = 'box-ops-token-fixture-9262';
const ENV_ON = { HARNESS_SECRET: SECRET, CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD, BOX_OPS_TOKEN: BOX };
const ENV_OFF = { HARNESS_SECRET: SECRET, BOX_OPS_TOKEN: BOX };
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));
const KEY = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const KID = 'kid-9262-c1';
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: KID, alg: 'RS256', use: 'sig' };
// determinism: ok-file clock-now-js exp/iat are offsets from the real clock the verifier reads; no case asserts a date.
const REAL_NOW_S = Math.floor(performance.timeOrigin / 1000 + performance.now() / 1000);
async function jwt() {
  const input = `${enc({ alg: 'RS256', kid: KID, typ: 'JWT' })}.${enc({ aud: [AUD], iss: `https://${TEAM}`, email: 'operator@example.com', exp: REAL_NOW_S + 600, iat: REAL_NOW_S - 5, sub: 'u1' })}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', KEY.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}
let seq = 0;
async function forward(rest, { body, env = ENV_ON, access = true } = {}) {
  const jobs = [];
  const real = globalThis.fetch;
  const realNow = Date.now;
  Date.now = () => performance.timeOrigin + performance.now();
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url === CERTS) return new Response(JSON.stringify({ keys: [JWK] }), { status: 200 });
    if (url.startsWith(JOBS)) {
      jobs.push({ url, headers: Object.fromEntries(Object.entries(init.headers).map(([k, v]) => [k.toLowerCase(), v])), body: init.body });
      return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response('{}', { status: 200 });
  };
  try {
    const headers = { cookie: `dash=c1-${++seq}`, 'content-type': 'application/json' };
    if (access) Object.assign(headers, { 'cf-access-authenticated-user-email': 'operator@example.com', 'cf-access-jwt-assertion': await jwt() });
    const res = await coord({
      request: new Request(`https://mc.example.com/api/coord/${rest}`, { method: 'POST', headers, body: JSON.stringify(body) }),
      env, params: { path: rest.split('/') }
    });
    return { status: res.status, jobs };
  } finally { globalThis.fetch = real; Date.now = realNow; }
}

test('P1: decide and archie delegation carry the box-ops proof with an Access identity, and not without one', async () => {
  for (const [rest, body] of [
    ['owner-approvals/7/decide', { decision: 'approved', result_ref: '62', actor: 'mallory' }],
    ['archie/classes/delegation', { class: 'lint-fixes', decision: 'delegate', min_streak: 5, reason: 'owner approval #8' }]
  ]) {
    _resetCertsCache();
    const on = await forward(rest, { body });
    assert.equal(on.status, 200, rest);
    assert.equal(on.jobs.length, 1, rest);
    assert.equal(on.jobs[0].url, `${JOBS}/api/${rest}`);
    assert.equal(on.jobs[0].headers['x-box-ops-token'], BOX, rest);
    assert.equal(on.jobs[0].headers['x-box-ops-identity'], 'operator@example.com', rest);
    const sent = JSON.parse(on.jobs[0].body);
    assert.equal(sent.actor, 'operator@example.com', `${rest}: the actor is stamped, never the browser's`);
    for (const k of Object.keys(body)) if (k !== 'actor') assert.deepEqual(sent[k], body[k], `${rest} ${k}`);
    for (const [env, access] of [[ENV_OFF, true], [ENV_ON, false]]) {
      _resetCertsCache();
      const off = await forward(rest, { body, env, access });
      assert.equal(off.jobs.length, 1, rest);
      assert.equal(off.jobs[0].headers['x-box-ops-token'], undefined, rest);
      assert.equal(off.jobs[0].headers['x-box-ops-identity'], undefined, rest);
    }
  }
});

test('P2: a bad body is a 400 and nothing is forwarded', async () => {
  for (const [rest, body] of [
    ['archie/classes/delegation', { class: 'lint-fixes', decision: 'delegate', min_streak: '5' }],
    ['archie/classes/delegation', { class: 'lint-fixes', decision: 'delegate', min_streak: 5.5 }],
    ['archie/classes/delegation', { class: 7, decision: 'delegate', min_streak: 5 }],
    ['owner-approvals/7/decide', { decision: 'yes' }],
    ['owner-approvals/7/decide', { decision: 'approved', result_ref: 62 }]
  ]) {
    _resetCertsCache();
    const r = await forward(rest, { body });
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.jobs.length, 0, JSON.stringify(body));
  }
  for (const rest of ['owner-approvals/x/decide', 'owner-approvals/7/decide/more', 'owner-approvals']) {
    const r = await forward(rest, { body: { decision: 'approved' } });
    assert.equal(r.status, 405, rest);
    assert.equal(r.jobs.length, 0, rest);
  }
});
