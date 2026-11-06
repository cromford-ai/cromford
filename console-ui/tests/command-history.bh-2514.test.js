import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';

// BH-2514: /history/commands, the table over GET /api/dash/commands. SSR runs
// no effects, so the screen body (CommandHistoryView) is rendered with each
// load state and filter set as props, the fetch is proved through the exported
// loader against a stubbed fetch, and the PAUSE row is built from the real
// pauseCommandFor and passed through the real Pages proxy before it is shown.

// The router reads window.location at first render; give SSR one.
globalThis.window = globalThis.window || {
  location: { pathname: '/history/commands', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { commandRows, commandTarget, filterCommands, facetValues } = await import('../src/lib/commands.js');
const { CommandHistoryView, CommandsTable, loadCommands, LIMIT } = await import('../src/screens/CommandHistory.js');
const { HistoryScreen } = await import('../src/screens/History.js');
const { ROUTES, NAV } = await import('../src/app.js');
const { CommandHistoryScreen } = await import('../src/screens/CommandHistory.js');
const { pauseCommandFor } = await import('../src/lib/pauses.js');
const { onRequest: dash } = await import('../functions/api/[[path]].js');
const { _resetCertsCache } = await import('../functions/_lib/access-identity.js');

const one = (raw) => commandRows([raw]).rows[0];
const to = (raw) => commandTarget(one(raw))?.to ?? null;

// ---------------------------------------------------------------- lib -----

test('lib: merge_pr → /pr/<p>/<n>', () => {
  assert.equal(to({ id: 1, type: 'merge_pr', project: 'project-3',
    payload: '{"pr_url":"https://github.com/example-org/project-3/pull/412"}' }), '/pr/project-3/412');
});

test('lib: lead_review → /pr/<p>/<n>', () => {
  assert.equal(to({ id: 2, type: 'lead_review', project: 'project-3', payload: { repo: 'example-org/project-3', pr: 88 } }),
    '/pr/project-3/88');
});

test('lib: proposal → /ideas/<p>/<slug>', () => {
  for (const type of ['chat_proposal', 'post_proposal', 'kill_proposal', 'revise_proposal']) {
    assert.equal(to({ id: 3, type, project: 'project-4', payload: { slug: 'dark-mode' } }), '/ideas/project-4/dark-mode', type);
  }
});

test('lib: payload.job_id → /jobs/<id>, over any other target', () => {
  assert.equal(to({ id: 4, type: 'fetch_log', project: 'project-4', payload: { job_id: 'j-77' } }), '/jobs/j-77');
  assert.equal(to({ id: 4, type: 'merge_pr', project: 'project-4',
    payload: { job_id: 12, pr_url: 'https://github.com/a/b/pull/3' } }), '/jobs/12');
});

test('lib: pause_set/pause_board/run_triage/fetch_log → /p/<project>', () => {
  for (const type of ['pause_set', 'pause_board', 'resume_board', 'pause_end', 'run_triage', 'fetch_log',
    'fetch_artifact', 'automerge_on', 'automerge_off', 'update_company_map']) {
    assert.equal(to({ id: 5, type, project: 'project-3', payload: '{}' }), '/p/project-3', type);
  }
  // project only in the payload still resolves
  assert.equal(to({ id: 5, type: 'pause_set', payload: { project: 'project-4' } }), '/p/project-4');
});

test('lib: fleet-scope pause → /jobs', () => {
  assert.equal(to({ id: 6, type: 'pause_end', payload: { id: 3, scope: 'fleet' } }), '/jobs');
  assert.equal(to({ id: 6, type: 'pause_set', payload: { scope: 'fleet', what: 'merges' } }), '/jobs');
});

test('lib: retry_command → /history/commands?id=<n>', () => {
  assert.equal(to({ id: 7, type: 'retry_command', payload: { cmd_id: 55 } }), '/history/commands?id=55');
});

test('lib: chat → /chat', () => {
  assert.equal(to({ id: 8, type: 'chat', payload: { text: 'hi' } }), '/chat');
});

test('lib: negative targets are null', () => {
  const cases = {
    'non-github pr_url': { type: 'merge_pr', project: 'p', payload: { pr_url: 'https://evil.example/pull/3' } },
    'malformed pr_url': { type: 'merge_pr', project: 'p', payload: { pr_url: 'not a url' } },
    'merge_pr without project': { type: 'merge_pr', payload: { pr_url: 'https://github.com/a/b/pull/3' } },
    'pr abc': { type: 'lead_review', project: 'p', payload: { pr: 'abc' } },
    'pr 0': { type: 'lead_review', project: 'p', payload: { pr: 0 } },
    'pr 1.5': { type: 'lead_review', project: 'p', payload: { pr: 1.5 } },
    'no slug': { type: 'kill_proposal', project: 'p', payload: {} },
    'unknown type': { type: 'foo', project: 'p', payload: {} },
    'retry without cmd_id': { type: 'retry_command', payload: {} },
    'pause without project or fleet scope': { type: 'pause_set', payload: { what: 'merges' } },
    'automerge without project': { type: 'automerge_off', payload: {} }
  };
  for (const [name, raw] of Object.entries(cases)) assert.equal(to({ id: 9, ...raw }), null, name);
  assert.equal(to({ id: 9, type: 'pause_set', project: 'a/b?c', payload: {} }), '/p/a%2Fb%3Fc');
  assert.equal(to({ id: 9, type: 'kill_proposal', project: 'p', payload: { slug: '../x' } }), '/ideas/p/..%2Fx');
});

test('lib: actor precedence', () => {
  assert.equal(one({ id: 1, type: 'chat', actor: 'a@x.com', payload: { actor: 'b@x.com' } }).actor, 'a@x.com');
  assert.equal(one({ id: 1, type: 'chat', payload: '{"actor":"b@x.com"}' }).actor, 'b@x.com');
  assert.equal(one({ id: 1, type: 'chat', payload: {} }).actor, null);
  assert.equal(one({ id: 1, type: 'chat', actor: 42, payload: { actor: { x: 1 } } }).actor, null);
});

test('lib: payload as object or string', () => {
  assert.equal(one({ id: 1, type: 'merge_pr', project: 'p', payload: { pr_url: 'https://github.com/a/b/pull/9' } }).payload.pr_url,
    'https://github.com/a/b/pull/9');
  assert.equal(one({ id: 1, type: 'x', payload: '{"a":1}' }).payload.a, 1);
  const bad = one({ id: 1, type: 'pause_set', project: 'p', payload: '{nope' });
  assert.equal(bad.payloadUnreadable, true);
  assert.deepEqual(bad.payload, {});
  const out = render(h(CommandsTable, { rows: [bad] }));
  assert.match(out, /pause_set/);
});

test('lib: commandRows', () => {
  assert.equal(commandRows({ commands: [{ id: 1, type: 'chat' }] }).rows.length, 1);
  assert.equal(commandRows({ commands: [{ id: 1, type: 'chat' }] }).malformed, false);
  assert.equal(commandRows([{ id: 1, type: 'chat' }, { id: 2, type: 'chat' }]).rows.length, 2);
  for (const body of [{ foo: 1 }, null, undefined, 'x', { commands: 'no' }]) {
    const r = commandRows(body);
    assert.equal(r.malformed, true, JSON.stringify(body));
    assert.deepEqual(r.rows, []);
  }
});

test('lib: status falls back to stage, outcome prefers refusal over result', () => {
  const r = one({ id: 1, type: 'pause_set', stage: 'dead_letter', result: 'r', refusal: 'refused: no', created_at: '2026-09-25T10:00:00Z' });
  assert.equal(r.status, 'dead_letter');
  assert.equal(r.outcome, 'refused: no');
  assert.equal(r.createdAt, '2026-09-25T10:00:00Z');
  assert.equal(one({ id: 1, type: 'x', status: 'done', stage: 'y', result: 'ok' }).status, 'done');
  assert.equal(one({ id: 1, type: 'x', status: 'done', result: 'ok' }).outcome, 'ok');
  assert.equal(one({ id: 1, type: 'x', status: 'pending' }).outcome, null);
});

const MIXED = commandRows({ commands: [
  { id: 1, type: 'pause_set', project: 'a', status: 'done', payload: { actor: 'x@y.com' } },
  { id: 2, type: 'merge_pr', project: 'b', status: 'refused', payload: {} },
  { id: 3, type: 'pause_set', project: 'b', status: 'refused', payload: { actor: 'x@y.com' } },
  { id: 4, type: 'chat', status: 'pending', payload: {} }
] }).rows;

test('lib: filterCommands', () => {
  assert.deepEqual(filterCommands(MIXED, { type: 'pause_set' }).map((r) => r.id), [1, 3]);
  assert.deepEqual(filterCommands(MIXED, { status: 'refused' }).map((r) => r.id), [2, 3]);
  assert.deepEqual(filterCommands(MIXED, { project: 'b' }).map((r) => r.id), [2, 3]);
  assert.deepEqual(filterCommands(MIXED, { actor: 'x@y.com' }).map((r) => r.id), [1, 3]);
  assert.deepEqual(filterCommands(MIXED, { type: 'pause_set', status: 'refused' }).map((r) => r.id), [3]);
  assert.deepEqual(filterCommands(MIXED, { type: null, status: null, project: null, actor: null }).map((r) => r.id), [1, 2, 3, 4]);
  assert.deepEqual(facetValues(MIXED, 'type'), ['chat', 'merge_pr', 'pause_set']);
  assert.deepEqual(facetValues(MIXED, 'project'), ['a', 'b']);
});

// ---------------------------------------------------------------- pause -----

// The Access assertion: a real RS256 JWT verified against a stubbed certs URL,
// the access-identity.bh-2515 fixture approach.
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud';
const ENV = { HARNESS_SECRET: 's', CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD };
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));
const KEY = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' };
// determinism: ok-file clock-now-js exp/iat are offsets from the real clock the
// verifier checks against; no case asserts a calendar date.
const nowS = Math.floor(Date.now() / 1000);
async function assertion(email) {
  const input = `${enc({ alg: 'RS256', kid: 'k1', typ: 'JWT' })}.${enc({
    aud: [AUD], iss: `https://${TEAM}`, email, exp: nowS + 600, iat: nowS - 5, sub: 'u1' })}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', KEY.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}

async function pauseClickThroughProxy() {
  const cmd = pauseCommandFor('project-3', { what: 'merges', reason: 'release freeze' });
  assert.equal(cmd.type, 'pause_set');
  _resetCertsCache();
  const sent = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url === CERTS) return new Response(JSON.stringify({ keys: [JWK] }), { status: 200 });
    if (url.startsWith('https://harness-console.operator.workers.dev/api/dash/fleet')) return new Response('{}', { status: 200 });
    if (url === 'https://harness-console.operator.workers.dev/api/dash/action') {
      sent.push(Buffer.from(init.body).toString('utf8'));
      return new Response('{"ok":true,"id":901}', { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  try {
    const res = await dash({
      request: new Request('https://mc.example.com/api/dash/action', {
        method: 'POST',
        headers: { cookie: 'dash=x', 'content-type': 'application/json',
          'cf-access-authenticated-user-email': 'operator@example.com', 'cf-access-jwt-assertion': await assertion('operator@example.com') },
        body: JSON.stringify(cmd)
      }),
      env: ENV, params: {}
    });
    assert.equal(res.status, 200);
  } finally { globalThis.fetch = real; }
  assert.equal(sent.length, 1);
  return sent[0];
}

const rowOf = (html, id) => {
  const trs = html.split('<tr').filter((t) => t.includes(`id="cmd-${id}"`));
  assert.equal(trs.length, 1, `exactly one row for #${id}`);
  return trs[0];
};

test('pause: a PAUSE click shows its actor and outcome on its own row', async () => {
  const body = await pauseClickThroughProxy();
  assert.equal(JSON.parse(body).actor, 'operator@example.com');
  const worker = { commands: [
    { id: 900, type: 'chat', status: 'done', result: 'answered', payload: '{}', created_at: '2026-09-25T09:00:00Z' },
    { id: 901, type: 'pause_set', project: 'project-3', payload: body, status: 'done',
      result: 'paused project-3 merges', created_at: '2026-09-25T10:00:00Z' }
  ] };
  const out = render(h(CommandsTable, { rows: commandRows(worker).rows }));
  const tr = rowOf(out, 901);
  for (const want of ['pause_set', 'operator@example.com', 'done', 'paused project-3 merges', 'href="/p/project-3"']) {
    assert.ok(tr.includes(want), `row 901 carries ${want}`);
  }
  assert.ok(!rowOf(out, 900).includes('operator@example.com'), 'the actor stays on its own row');
});

test('pause: a refused pause shows the refusal', () => {
  const rows = commandRows({ commands: [{ id: 902, type: 'pause_set', project: 'project-3', status: 'refused',
    refusal: 'refused: project-3 is already paused', payload: { actor: 'operator@example.com' }, created_at: '2026-09-25T10:00:00Z' }] }).rows;
  const tr = rowOf(render(h(CommandsTable, { rows })), 902);
  assert.match(tr, /tag--dead/);
  assert.match(tr, /refused: project-3 is already paused/);
});

// ---------------------------------------------------------------- render ----

test('render: actor cell is — not console', () => {
  const rows = commandRows([{ id: 903, type: 'pause_set', project: 'p', status: 'done', payload: {} }]).rows;
  const tr = rowOf(render(h(CommandsTable, { rows })), 903);
  assert.ok(!tr.includes('console'), 'no fabricated console actor');
  assert.match(tr, /<td[^>]*><span class="na">—<\/span><\/td>/);
});

test('render: every header is a sort button with aria-sort, newest row first', () => {
  const rows = commandRows([
    { id: 10, type: 'chat', created_at: '2026-09-25T08:00:00Z', payload: {} },
    { id: 11, type: 'chat', created_at: '2026-09-25T12:00:00Z', payload: {} },
    { id: 12, type: 'chat', created_at: '2026-09-25T10:00:00Z', payload: {} }
  ]).rows;
  const out = render(h(CommandsTable, { rows }));
  const ths = out.match(/<th[\s\S]*?<\/th>/g);
  assert.equal(ths.length, 8);
  for (const th of ths) {
    assert.match(th, /aria-sort="(none|ascending|descending)"/);
    assert.match(th, /<button type="button"/);
  }
  assert.match(ths[1], /aria-sort="descending"/);
  assert.match(ths[1], /WHEN/);
  const order = [...out.matchAll(/id="cmd-(\d+)"/g)].map((m) => Number(m[1]));
  assert.deepEqual(order, [11, 12, 10]);
});

const loaded = (body) => ({ data: body, error: null, loading: false, reload() {} });
const view = (state, filters = {}) => render(h(CommandHistoryView, { state, filters, setFilter() {} }));

test('render: ?status=refused shows only refused rows', () => {
  const body = { commands: [
    { id: 21, type: 'pause_set', project: 'a', status: 'done', payload: {} },
    { id: 22, type: 'merge_pr', project: 'b', status: 'refused', payload: {} },
    { id: 23, type: 'chat', status: 'refused', payload: {} }
  ] };
  const out = view(loaded(body), { status: 'refused' });
  assert.deepEqual([...out.matchAll(/id="cmd-(\d+)"/g)].map((m) => Number(m[1])).sort(), [22, 23]);
  assert.match(out, /status: refused/);
  // the unfiltered view carries all three
  assert.equal([...view(loaded(body)).matchAll(/id="cmd-(\d+)"/g)].length, 3);
});

test('render: empty state', () => {
  const none = view(loaded({ commands: [] }));
  assert.match(none, /no console or chat command on record/);
  assert.doesNotMatch(none, /class="banner"/);
  const filtered = view(loaded({ commands: [{ id: 1, type: 'chat', status: 'done', payload: {} }] }), { status: 'refused' });
  assert.match(filtered, /no command matches these filters/);
  assert.doesNotMatch(filtered, /no console or chat command on record/);
});

test('render: failed read shows ErrorBox, not the empty copy; malformed body says unexpected response', () => {
  const failed = view({ data: null, error: new Error('http_500'), loading: false, reload() {} });
  assert.match(failed, /class="banner"/);
  assert.match(failed, /http_500/);
  assert.match(failed, /RETRY/);
  assert.doesNotMatch(failed, /no console or chat command on record/);
  const bad = view(loaded({ rows: [] }));
  assert.match(bad, /unexpected response from \/api\/dash\/commands/);
  assert.doesNotMatch(bad, /no console or chat command on record/);
  const loading = view({ data: null, error: null, loading: true, reload() {} });
  assert.match(loading, /class="skel"/);
  assert.doesNotMatch(loading, /no console or chat command on record/);
});

test('render: the ≥LIMIT footnote says older commands are not shown', () => {
  assert.equal(LIMIT, 200);
  const full = { commands: Array.from({ length: LIMIT }, (_, i) => ({ id: i + 1, type: 'chat', status: 'done', payload: {} })) };
  const out = view(loaded(full));
  assert.match(out, /sorting and filters apply to these rows only/);
  assert.match(out, /older commands are not shown/);
  const few = view(loaded({ commands: [{ id: 1, type: 'chat', status: 'done', payload: {} }] }));
  assert.match(few, /sorting and filters apply to these rows only/);
  assert.doesNotMatch(few, /older commands are not shown/);
});

test('render: ?id=<n> highlights a loaded row, or says it is older than the window', () => {
  const body = { commands: [{ id: 31, type: 'chat', status: 'done', payload: {} }, { id: 32, type: 'chat', status: 'done', payload: {} }] };
  const hit = view(loaded(body), { id: '32' });
  assert.match(rowOf(hit, 32), /row--hl/);
  assert.doesNotMatch(rowOf(hit, 31), /row--hl/);
  assert.match(view(loaded(body), { id: '7' }), /command #7 is older than the loaded window/);
});

test('render: History tab strip carries a COMMANDS tab, and CommandHistory marks COMMANDS active', () => {
  const hist = render(h(HistoryScreen, {}));
  assert.match(hist, /<button type="button" class="tab"[^>]*>COMMANDS<\/button>/);
  const cmd = render(h(CommandHistoryScreen, {}));
  assert.match(cmd, /class="tab tab--on"[^>]*>COMMANDS</);
  assert.match(cmd, /href="\/history"[^>]*>RUNS</);
  assert.match(cmd, /href="\/history\?tab=builds"[^>]*>BUILDS</);
});

test('route: /history/commands is in ROUTES and maps to CommandHistoryScreen', () => {
  const hit = ROUTES.find(([p]) => p === '/history/commands');
  assert.ok(hit, 'route registered');
  assert.equal(hit[1], CommandHistoryScreen);
  // BH-9118: HISTORY and COMMAND LOG are their own side-menu entries; NOW no longer claims them.
  const lit = (p) => NAV.filter((n) => n.match(p)).map((n) => n.label);
  assert.deepEqual(lit('/history/commands'), ['COMMAND LOG']);
  assert.deepEqual(lit('/history'), ['HISTORY']);
});

test('wiring: CommandHistoryScreen reads api.commands', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(url); return new Response('{"commands":[]}', { status: 200 }); };
  try {
    assert.deepEqual(await loadCommands(), { commands: [] });
  } finally { globalThis.fetch = real; }
  assert.deepEqual(seen, ['/api/dash/commands?limit=200']);
});
