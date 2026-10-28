// BH-7936: the tracker connect sheets (src/ui/TrackerSheets.js) and their
// pure half (src/lib/tracker-sheets.js): the fields per tracker, the Jira
// status map defaults, the refusal on a blank required field, the test run
// (one POST, then a poll while pending) and the coord proxy rows.
//   K1-K3 each sheet renders its fields, Later and Test and connect
//   K4 Jira: the four default status pairs, and a changed pair in the map
//   K5 an `error` answer renders its text in role=alert, the fields kept
//   K6 Test and connect is disabled while a required field is blank
//   K7 Escape calls onLater; Tab stays in the sheet
//   R1-R4 runTrackerTest: pending then ok; error; the deadline; one POST only
//   C1 the client calls the coord proxy paths
//   P1 the proxy admits POST onboarding/tracker-test and refuses the take route
// TEST-CHANGE (BH-7968): the start body is {project, kind, envelope_id}, not
// {project, kind, fields}, and runTrackerTest seals and stores the envelope
// before the start. R1-R4, C1 and P1 now build that premise; what each case
// pins (one start, the poll, the deadline, the abort, the proxy rows) is the
// same. The seal itself is pinned in tests/onboard-envelope.bh-7937.test.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const lib = await import('../src/lib/tracker-sheets.js');
const { TrackerSheet, TrackerSheetView } = await import('../src/ui/TrackerSheets.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');

const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');
const inputs = (s) => [...s.matchAll(/<input[^>]*>/g)].map((m) => m[0]);
const attr = (tag, name) => (tag.match(new RegExp(`\\s${name}="([^"]*)"`)) || [])[1];
const button = (s, label) => [...s.matchAll(/<button[^>]*>([^<]*)<\/button>/g)].find((m) => m[1].includes(label));

const FULL = {
  linear: { api_key: 'lin-api-fixture-1', team: 'CRO', label: 'ai-build' },
  jira: { site: 'sandbox-example.atlassian.net', email: 'bot@example.com', api_token: 'tok-fixture-jira', project_key: 'CROM' },
  board: { api_base: 'https://board.example.com/api/board', token: 'tok-fixture-board' }
};

const EXPECT = {
  linear: { names: ['api_key', 'team', 'label'], labels: ['API key', 'Team key', 'Build label'], secret: ['api_key'] },
  jira: { names: ['site', 'email', 'api_token', 'project_key'], labels: ['Site', 'Email', 'API token', 'Project key'], secret: ['api_token'] },
  board: { names: ['api_base', 'token'], labels: ['Board API base', 'Internal token'], secret: ['token'] }
};

for (const kind of ['linear', 'jira', 'board']) {
  test(`K1-K3 the ${kind} sheet renders its fields, Later and Test and connect, as a modal dialog`, () => {
    const out = render(h(TrackerSheet, { kind, project: 'newproj', onConnected() {}, onLater() {} }));
    assert.match(out, /role="dialog"/);
    assert.match(out, /aria-modal="true"/);
    const ins = inputs(out);
    const named = ins.filter((t) => attr(t, 'name') && !attr(t, 'name').startsWith('status_'));
    assert.deepEqual(named.map((t) => attr(t, 'name')), EXPECT[kind].names);
    for (const l of EXPECT[kind].labels) assert.ok(text(out).includes(l), `${kind}: label ${l}`);
    for (const t of named) {
      const secret = EXPECT[kind].secret.includes(attr(t, 'name'));
      assert.equal(attr(t, 'type'), secret ? 'password' : 'text', `${attr(t, 'name')} type`);
      if (secret) assert.equal(attr(t, 'autocomplete'), 'off');
    }
    assert.ok(button(out, 'Later'), 'a Later button');
    assert.ok(button(out, 'Test and connect'), 'a Test and connect button');
  });
}

test('K4 Jira: the status rows default to the four pairs, and a changed pair changes the map', () => {
  assert.deepEqual(lib.JIRA_STATUS_DEFAULTS, [
    { key: 'todo', label: 'ready', status: 'To Do' },
    { key: 'in_progress', label: 'building', status: 'In Progress' },
    { key: 'review', label: 'review', status: 'In Review' },
    { key: 'closed', label: 'closed', status: 'Done' }
  ]);
  const out = render(h(TrackerSheet, { kind: 'jira', project: 'p', onConnected() {}, onLater() {} }));
  const rows = inputs(out).filter((t) => (attr(t, 'name') || '').startsWith('status_'));
  assert.deepEqual(rows.map((t) => [attr(t, 'name'), attr(t, 'value')]), [
    ['status_todo', 'To Do'], ['status_in_progress', 'In Progress'], ['status_review', 'In Review'], ['status_closed', 'Done']
  ]);
  for (const l of ['ready', 'building', 'review', 'closed']) assert.ok(text(out).includes(l));
  assert.equal(lib.statusMapString(lib.defaultStatuses()), 'todo=To Do;in_progress=In Progress;review=In Review;closed=Done');
  const changed = { ...lib.defaultStatuses(), review: 'Code Review' };
  assert.equal(lib.statusMapString(changed), 'todo=To Do;in_progress=In Progress;review=Code Review;closed=Done');
  const sent = lib.sendFields('jira', FULL.jira, changed);
  assert.equal(sent.status_map, 'todo=To Do;in_progress=In Progress;review=Code Review;closed=Done');
  assert.deepEqual(lib.publicFields('jira', sent), {
    site: 'sandbox-example.atlassian.net', email: 'bot@example.com', project_key: 'CROM',
    status_map: 'todo=To Do;in_progress=In Progress;review=Code Review;closed=Done'
  });
});

test('K5 an error answer renders its text in role=alert, and the fields keep their values', () => {
  const out = render(h(TrackerSheetView, {
    kind: 'linear', values: FULL.linear, statuses: {}, phase: 'error',
    error: 'FAIL tracker list failed\ntracker: linear answered HTTP 401: Authentication required',
    onChange() {}, onStatus() {}, onTest() {}, onLater() {}
  }));
  const alert = out.match(/<div[^>]*role="alert"[^>]*>([\s\S]*?)<\/div>/);
  assert.ok(alert, 'a role=alert block');
  assert.match(text(alert[1]), /linear answered HTTP 401: Authentication required/);
  const team = inputs(out).find((t) => attr(t, 'name') === 'team');
  assert.equal(attr(team, 'value'), 'CRO');
  assert.ok(button(out, 'Test and connect'), 'the button is back for a retry');
  assert.equal(/disabled/.test(button(out, 'Test and connect')[0]), false);
});

test('K6 a blank required field disables Test and connect and names the field', () => {
  for (const kind of ['linear', 'jira', 'board']) {
    for (const f of EXPECT[kind].names) {
      for (const blank of ['', '   ']) {
        const values = { ...FULL[kind], [f]: blank };
        assert.equal(lib.missingField(kind, values, lib.defaultStatuses()).name, f, `${kind}.${f}`);
        const out = render(h(TrackerSheetView, { kind, values, statuses: lib.defaultStatuses(), phase: 'idle', onChange() {}, onStatus() {}, onTest() {}, onLater() {} }));
        assert.match(button(out, 'Test and connect')[0], /disabled/, `${kind}.${f} disables the button`);
        const label = lib.TRACKER_FIELDS[kind].find((x) => x.name === f).label;
        assert.ok(text(out).includes(`Fill in ${label}`), `${kind}.${f}: says which field`);
      }
    }
    assert.equal(lib.missingField(kind, FULL[kind], lib.defaultStatuses()), null);
    const ok = render(h(TrackerSheetView, { kind, values: FULL[kind], statuses: lib.defaultStatuses(), phase: 'idle', onChange() {}, onStatus() {}, onTest() {}, onLater() {} }));
    assert.equal(/disabled/.test(button(ok, 'Test and connect')[0]), false, `${kind}: all filled enables it`);
  }
  const noReview = { ...lib.defaultStatuses(), review: ' ' };
  assert.equal(lib.missingField('jira', FULL.jira, noReview).label, 'status for review');
  // a leading space is trimmed and accepted
  assert.equal(lib.sendFields('linear', { ...FULL.linear, team: '  CRO ' }).team, 'CRO');
});

test('K7 Escape calls onLater, other keys do not; Tab wraps inside the sheet', () => {
  let later = 0;
  const first = { id: 'first' }; const last = { id: 'last' };
  const box = { querySelectorAll: () => [first, first, last] };
  const doc = { activeElement: last };
  const on = lib.sheetKeyHandler(() => later++, () => box, doc);
  let prevented = 0;
  const ev = (key, shiftKey = false) => ({ key, shiftKey, preventDefault() { prevented++; } });
  on(ev('Enter'));
  assert.equal(later, 0);
  on(ev('Escape'));
  assert.equal(later, 1);
  let focused = null;
  first.focus = () => { focused = 'first'; }; last.focus = () => { focused = 'last'; };
  on(ev('Tab'));
  assert.equal(focused, 'first', 'Tab on the last control wraps to the first');
  doc.activeElement = first;
  on(ev('Tab', true));
  assert.equal(focused, 'last', 'Shift+Tab on the first wraps to the last');
  assert.ok(prevented >= 3);
});

const ENV_ID = crypto.randomUUID();
function fakeClient(answers) {
  const calls = { start: [], result: [], envelope: [] };
  return {
    calls,
    async publicKey() { return 'fixture-public-key'; },
    async postEnvelope(body) { calls.envelope.push(body); return { id: ENV_ID }; },
    async start(project, kind, envelopeId) { calls.start.push({ project, kind, envelopeId }); return { test_id: 'f'.repeat(32) }; },
    async result(project, id) { calls.result.push({ project, id }); return answers.length > 1 ? answers.shift() : answers[0]; }
  };
}
const seal = async (_key, text) => `sealed:${text.length}`;
const noSleep = async () => {};

test('R1 runTrackerTest: one POST, a poll while pending, then ok', async () => {
  const c = fakeClient([{ state: 'pending' }, { state: 'pending' }, { state: 'ok', detail: 'ok list=2 dry-write=ok' }]);
  const seen = [];
  const r = await lib.runTrackerTest({ client: c, seal, project: 'p', kind: 'linear', fields: FULL.linear, sleep: noSleep, onPending: (x) => seen.push(x.state) });
  assert.equal(r.state, 'ok');
  assert.equal(r.test_id, 'f'.repeat(32));
  assert.equal(c.calls.start.length, 1);
  assert.deepEqual(c.calls.start[0], { project: 'p', kind: 'linear', envelopeId: ENV_ID });
  assert.equal(c.calls.envelope.length, 1);
  assert.equal(c.calls.result.length, 3);
  assert.deepEqual(seen, ['pending', 'pending']);
});

test('R2 runTrackerTest: an error answer returns its text', async () => {
  const c = fakeClient([{ state: 'error', error: 'FAIL credential expired, test again' }]);
  const r = await lib.runTrackerTest({ client: c, seal, project: 'p', kind: 'board', fields: FULL.board, sleep: noSleep });
  assert.deepEqual([r.state, r.error], ['error', 'FAIL credential expired, test again']);
});

test('R3 runTrackerTest: no answer before the deadline is an error, never ok', async () => {
  let now = 0;
  const c = fakeClient([{ state: 'pending' }]);
  const r = await lib.runTrackerTest({
    client: c, seal, project: 'p', kind: 'board', fields: FULL.board, pollMs: 5000, maxWaitMs: 20000,
    sleep: async (ms) => { now += ms; if (now > 10 * 20000) throw new Error('runaway poll: no deadline'); }, now: () => now
  });
  assert.equal(r.state, 'error');
  assert.match(r.error, /no answer from the hub/);
  assert.ok(c.calls.result.length <= 6, `bounded polls: ${c.calls.result.length}`);
});

test('R4 runTrackerTest: a start the worker refuses is an error with its text; an abort stops the poll', async () => {
  const c = { ...fakeClient([]), async start() { const e = new Error('the hub-probe request could not be filed'); e.status = 503; throw e; }, async result() { throw new Error('never'); } };
  const r = await lib.runTrackerTest({ client: c, seal, project: 'p', kind: 'board', fields: FULL.board, sleep: noSleep });
  assert.deepEqual([r.state, r.error], ['error', 'the hub-probe request could not be filed']);
  const ac = new AbortController();
  const c2 = fakeClient([{ state: 'pending' }]);
  const run = lib.runTrackerTest({ client: c2, seal, project: 'p', kind: 'board', fields: FULL.board, signal: ac.signal, sleep: async () => { ac.abort(); } });
  const r2 = await run;
  assert.equal(r2.state, 'aborted');
  assert.equal(c2.calls.result.length, 1);
});

test('C1 the client posts the envelope, then {project, kind, envelope_id} to the coord proxy, and reads the result by id', async () => {
  const seen = [];
  const fetchImpl = async (url, init = {}) => {
    seen.push({ url, method: init.method || 'GET', body: init.body });
    if (url.endsWith('/secrets/envelope')) return new Response(JSON.stringify({ id: ENV_ID }), { status: 200 });
    const body = url.includes('/tracker-test/') ? { state: 'pending' } : { test_id: 'a'.repeat(32) };
    return new Response(JSON.stringify(body), { status: url.includes('/tracker-test/') ? 200 : 202 });
  };
  const c = lib.trackerClient(fetchImpl, { settings: async () => ({ settings: [] }) });
  assert.deepEqual(await c.postEnvelope({ scope: 'tracker:linear:newproj', ciphertext: 'QQ==' }), { id: ENV_ID });
  assert.deepEqual(await c.start('newproj', 'linear', ENV_ID), { test_id: 'a'.repeat(32) });
  assert.deepEqual(await c.result('newproj', 'a'.repeat(32)), { state: 'pending' });
  assert.equal(seen[0].url, '/api/coord/secrets/envelope');
  assert.equal(seen[1].url, '/api/coord/onboarding/tracker-test');
  assert.equal(seen[1].method, 'POST');
  const sb = JSON.parse(seen[1].body);
  assert.deepEqual(Object.keys(sb).sort(), ['envelope_id', 'kind', 'project']);
  assert.deepEqual([sb.project, sb.kind, sb.envelope_id], ['newproj', 'linear', ENV_ID]);
  assert.equal(seen[2].url, `/api/coord/onboarding/tracker-test/${'a'.repeat(32)}?project=newproj`);
  const failing = lib.trackerClient(async () => new Response(JSON.stringify({ error: 'no envelope with that id' }), { status: 400 }));
  await assert.rejects(failing.start('p', 'linear', ENV_ID), /no envelope with that id/);
});

test('P1 the coord proxy admits POST onboarding/tracker-test and refuses the take route', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url, method: init.method, body: init.body });
    return new Response('{"test_id":"x"}', { status: 202, headers: { 'content-type': 'application/json' } });
  };
  const call = (rest, method, body) => onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method, headers: { cookie: 'dash=trackersheets7936', 'content-type': 'application/json' }, body
    }),
    env: { HARNESS_SECRET: 'test-harness-secret' },
    params: { path: rest.split('/').filter(Boolean) }
  });
  try {
    const ok = await call('onboarding/tracker-test', 'POST', JSON.stringify({ project: 'p', kind: 'linear', envelope_id: ENV_ID, fields: FULL.linear, extra: 1 }));
    assert.equal(ok.status, 202);
    assert.equal(seen.length, 1);
    assert.match(seen[0].url, /\/api\/onboarding\/tracker-test$/);
    const fwd = JSON.parse(seen[0].body);
    assert.deepEqual([fwd.project, fwd.kind, fwd.envelope_id], ['p', 'linear', ENV_ID]);
    assert.equal('extra' in fwd, false);
    assert.equal('fields' in fwd, false, 'a field value is never forwarded');
    const notStr = await call('onboarding/tracker-test', 'POST', JSON.stringify({ project: 'p', kind: 'linear', envelope_id: 7 }));
    assert.equal(notStr.status, 202);
    assert.equal('envelope_id' in JSON.parse(seen[1].body), false, 'an envelope_id that is not a string is not forwarded');
    const take = await call('onboarding/tracker-secret/take', 'POST', JSON.stringify({ nonce: 'a'.repeat(32) }));
    assert.equal(take.status, 405);
    assert.equal(seen.length, 2, 'the take route never reached the worker');
  } finally { globalThis.fetch = real; }
});
