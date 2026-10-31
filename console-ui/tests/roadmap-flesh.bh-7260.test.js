import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, isDisabled, dialogOf, buttonIn, confirmOf, byTestId } from './helpers/fake-dom.bh-5750.js';

// BH-7260 (BH-7244.2): the PM FLESH-OUT section on /roadmap/:project/idea/:id.
//
// C1 RoadmapIdeaView renders the pm-flesh section (its own skeleton while the
//    read runs); FleshSection renders the seven headings of the stored result
//    as visible text and the runs table has aria-sort headers
// C2 no runs renders the empty state with the operator command
// C3 pmRuns calls /api/coord/pm/runs?project=&idea_id=; a 403 is an AuthError
// C4 the coord proxy forwards GET pm/runs and answers 405 to POST pm/claim and
//    POST pm/result, forwarding nothing
// C5 flesh-section.js has no native dialog and never sets HTML
// C6 FLESH OUT from the existing idea page: the in-app dialog, CANCEL sends
//    nothing, CONFIRM sends ONE exact run_script POST, the outcome is visible,
//    the button stays locked, RELOAD reads the runs again; a refusal is shown
//    and the button is enabled again; an id the launcher refuses gets no button
// C7 the Pages fallback queues only run_script pm-flesh-launch.sh [project, id]
//    (no --force, no other project, no other id shape), behind the auth probe

globalThis.window = globalThis.window || {
  location: { pathname: '/roadmap', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const LV = await import('../src/screens/roadmap/list-view.js');
const { AuthError } = await import('../src/api.js');
const FS = await import('../src/screens/roadmap/flesh-section.js').catch(() => ({}));
const PF = await import('../src/lib/roadmap-api/pm-flesh.js').catch(() => ({}));
const { onRequest } = await import('../functions/api/coord/[[path]].js');
const { onRequest: dash } = await import('../functions/api/[[path]].js');
const PFC = await import('../functions/_lib/pm-flesh-command.js').catch(() => ({}));

const P = 'cromford';
const ID = 'idea-fixture-1';
// A copy of worker/jobs/test/fixtures/pm-flesh-answer.bh-7260.md, the answer
// tests/pm-flesh.bh-7260-test.sh F1 drives through bin/pm-flesh.sh. It is
// inline because a console-ui test reads nothing outside console-ui/.
const ANSWER = `I read the idea and the evidence rows.

## Problem
Alerts rise and nobody owns the triage. The team reads the same alert twice.

## Evidence
- alerts.7d: 41 alerts in 7 days.

## User and job
The operator opens the alert list each morning. The job is to clear each alert once.

## Options
### Option A: an owner column
Each alert gets one owner.
### Option B: a daily digest
One message a day lists the open alerts.
Recommended: Option A, because it removes the double read.

## Scope cut
No paging. No new alert sources.

## Acceptance criteria
- An alert shows its owner.
- A second reader sees the owner before opening the alert.

## Risks
The owner can be away. A fallback owner is a later step.
PM_FLESH_DONE
`;
const RESULT = ANSWER.slice(ANSWER.indexOf('## ')).replace(/\nPM_FLESH_DONE\s*$/, '\n').trimEnd();
const HEADINGS = ['Problem', 'Evidence', 'User and job', 'Options', 'Scope cut', 'Acceptance criteria', 'Risks'];
const run = (id, status, extra = {}) => ({
  id, project: P, idea_id: ID, input_hash: 'a'.repeat(64), status, model: 'model-fixture', result_ref: null,
  draft: 'ok', cost_usd: 0.42, error: null, created_at: '2026-10-30T06:00:00Z', updated_at: '2026-10-30T06:01:00Z', ...extra
});
const PAYLOAD = {
  project: P,
  runs: [run('r2', 'failed', { draft: null, cost_usd: 0.1, created_at: '2026-10-29T06:00:00Z' }), run('r1', 'done')],
  latest: { ...run('r1', 'done'), result: RESULT },
  as_of: '2026-10-30T07:00:00Z'
};
const section = (f) => render(h(FS.FleshSection, { project: P, id: ID, f }));
const text = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');
const count = (s, re) => (s.match(re) || []).length;

test('C1 the idea page carries the pm-flesh section; the seven headings and a sortable runs table render', () => {
  assert.equal(typeof FS.FleshSection, 'function', 'FleshSection is exported');
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200, text: async () => JSON.stringify(PAYLOAD) });
  try {
    const page = render(h(LV.RoadmapIdeaView, { project: P, id: ID }));
    assert.match(page, /id="pm-flesh"/);
    assert.match(page, /data-testid="pm-flesh"/);
    assert.match(page, /PM FLESH-OUT/);
  } finally { globalThis.fetch = real; }

  const out = section({ loading: false, error: null, data: PAYLOAD });
  const result = out.slice(out.indexOf('data-testid="pm-flesh-result"'));
  assert.ok(out.includes('data-testid="pm-flesh-result"'), 'the result block renders');
  const shown = HEADINGS.map((hd) => result.indexOf(`<b>${hd}</b>`));
  for (const [i, at] of shown.entries()) assert.ok(at >= 0, `${HEADINGS[i]} is a visible bold label`);
  assert.deepEqual([...shown].sort((a, b) => a - b), shown, 'the headings keep their order');
  assert.equal(count(result, /data-testid="pm-flesh-block"/g), 7);
  assert.match(text(result), /alerts\.7d: 41 alerts in 7 days\./);
  assert.match(text(result), /Recommended: Option A/);
  assert.match(text(result), /PRD and mockup: drafted\./, 'the draft column shows in words');
  assert.doesNotMatch(result, /## /, 'the raw markdown marker is not shown');
  assert.match(out, /overflow-wrap:anywhere/);
  const table = out.slice(out.indexOf('data-testid="pm-flesh-runs"'));
  assert.ok(out.includes('data-testid="pm-flesh-runs"'), 'the runs table renders');
  assert.match(table, /aria-sort="descending"/, 'WHEN sorts newest first by default');
  assert.equal(count(table.split('<tbody>')[1] || '', /<tr/g), 2, 'one row per run');
  assert.match(table, /tablewrap/);
  for (const label of ['WHEN', 'STATUS', 'DRAFT', 'COST', 'MODEL']) assert.match(table, new RegExp(label));
  assert.match(text(table), /\$0\.42/);
  assert.match(text(table), / ok /, 'the DRAFT column shows the draft outcome');
  // An answered run (the result is stored, the draft is not finished) shows its result too.
  const answered = section({ loading: false, error: null, data: { ...PAYLOAD, latest: { ...PAYLOAD.latest, status: 'answered', draft: null } } });
  assert.equal(count(answered, /data-testid="pm-flesh-block"/g), 7);

  // Loading is a skeleton; a failed read is an error box in this section only.
  assert.match(section({ loading: true, error: null, data: null }), /class="skel"/);
  const failed = section({ loading: false, error: new Error('http_500'), data: null, reload() {} });
  assert.match(failed, /could not load/);
  assert.match(failed, /http_500/);
});

test('C1b a drafted run shows its kept PRD and links its mockup screenshots', () => {
  const out = section({ loading: false, error: null, data: { ...PAYLOAD, latest: { ...PAYLOAD.latest, prd: '# PRD\n\nThe kept PRD text.' } } });
  const draft = out.slice(out.indexOf('data-testid="pm-flesh-draft"'));
  assert.ok(out.includes('data-testid="pm-flesh-draft"'), 'the draft block renders');
  assert.match(draft, /<details data-testid="pm-flesh-prd"><summary[^>]*>PRD<\/summary>/, 'the PRD opens from a PRD summary');
  assert.match(text(draft), /The kept PRD text\./);
  assert.equal(FS.fleshAssetSlug('0123456789abcdef-xyz'), 'pmflesh-0123456789ab', 'the slug is bin/pm-flesh.sh SLUG');
  assert.ok(draft.includes(`href="/api/ideas/asset/${P}/pmflesh-r1/desktop"`), 'the desktop screenshot link');
  assert.ok(draft.includes(`href="/api/ideas/asset/${P}/pmflesh-r1/mobile"`), 'the mobile screenshot link');
  // A drafted run with no kept PRD says so; a run that was not drafted shows no draft block.
  const noPrd = section({ loading: false, error: null, data: PAYLOAD });
  assert.match(text(noPrd), /This run kept no PRD text\./);
  const notDrafted = section({ loading: false, error: null, data: { ...PAYLOAD, latest: { ...PAYLOAD.latest, draft: 'failed' } } });
  assert.ok(!notDrafted.includes('data-testid="pm-flesh-draft"'));
});

test('C2 no runs renders the empty state with the operator command', () => {
  const out = section({ loading: false, error: null, data: { project: P, runs: [], latest: null, as_of: 'x' } });
  assert.match(out, /No PM flesh-out yet\./);
  assert.match(text(out), new RegExp(`bin/pm-flesh\\.sh ${P} ${ID}`));
  assert.doesNotMatch(out, /data-testid="pm-flesh-result"/);
  // Runs but no done run: the table, and a line that no result is stored yet.
  const onlyFailed = section({ loading: false, error: null, data: { ...PAYLOAD, runs: [run('r2', 'failed')], latest: null } });
  assert.match(onlyFailed, /data-testid="pm-flesh-runs"/);
  assert.match(onlyFailed, /No finished flesh-out yet/);
});

test('C3 pmRuns calls the coord path; a 403 is an AuthError', async () => {
  assert.equal(typeof PF.pmRuns, 'function');
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || 'GET', credentials: init.credentials });
    return { ok: true, status: 200, text: async () => '{"runs":[],"latest":null}' };
  };
  try {
    await PF.pmRuns('p', 'i');
  } finally { globalThis.fetch = real; }
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, '/api/coord/pm/runs?project=p&idea_id=i');
  assert.equal(seen[0].method, 'GET');
  assert.equal(seen[0].credentials, 'same-origin');
  globalThis.fetch = async () => ({ ok: false, status: 403, text: async () => '{"error":"forbidden"}' });
  try {
    await assert.rejects(PF.pmRuns('p', 'i'), AuthError);
  } finally { globalThis.fetch = real; }
});

// ── C4: the coord proxy (same harness as roadmap-brief.bh-7261) ──
const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'fixture-harness-secret';
function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const call = (rest, method, payload, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=bh7260-${++cookieSeq}`, 'content-type': 'application/json' },
      body: payload
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('C4 the proxy forwards GET pm/runs; POST pm/claim and pm/result are 405 and forward nothing', async () => {
  const g = stubFetch();
  try {
    const res = await call('pm/runs', 'GET', undefined, `?project=${P}&idea_id=${ID}`);
    assert.equal(res.status, 200);
    assert.equal(g.seen.length, 1);
    assert.equal(g.seen[0].url, `${JOBS}/api/pm/runs?project=${P}&idea_id=${ID}`);
  } finally { g.restore(); }
  const w = stubFetch();
  try {
    for (const rest of ['pm/claim', 'pm/result']) {
      const body = JSON.stringify({ project: P, idea_id: ID, input_hash: 'a'.repeat(64), id: 'r1', status: 'done', result: 'x' });
      assert.equal((await call(rest, 'POST', body)).status, 405, rest);
    }
    assert.equal(w.seen.length, 0);
  } finally { w.restore(); }
});

test('C5 flesh-section.js has no native dialog and never sets HTML', () => {
  const src = readFileSync(new URL('../src/screens/roadmap/flesh-section.js', import.meta.url), 'utf8');
  assert.ok(src.includes('FleshSection'), 'the file is the section module');
  assert.doesNotMatch(src, /(^|[^.\w])(confirm|alert|prompt)\s*\(/m);
  assert.doesNotMatch(src, /window\.(confirm|alert|prompt)/);
  assert.doesNotMatch(src, /dangerouslySetInnerHTML|innerHTML/);
});

// ── C6: FLESH OUT on the mounted idea page ──
const IDEA = { id: ID, project: P, title: 'Alert owner', lane: 'ideas', source: 'pm-agent', note: '', link: null,
  version: 3, created_at: '2026-10-29T06:00:00Z', created_by: 'pm-agent', updated_at: '2026-10-29T06:00:00Z', discarded_at: null };
const EMPTY_RUNS = { project: P, idea_id: ID, runs: [], latest: null, as_of: 'x' };
function ideaPage(actionAnswer) {
  return routedFetch((u, method) => {
    if (u.startsWith(`/api/coord/roadmap/ideas/${ID}?`) && method === 'GET') return [200, { idea: IDEA, events: [], as_of: 'x' }];
    if (u.startsWith('/api/coord/pm/runs?') && method === 'GET') return [200, EMPTY_RUNS];
    if (u === '/api/dash/action' && method === 'POST') return actionAnswer;
    return [404, { error: 'nope' }];
  });
}
const actions = (calls) => calls.filter((c) => c.url === '/api/dash/action');
const runReads = (calls) => calls.filter((c) => c.url.startsWith('/api/coord/pm/runs?'));
const visible = (n) => {
  for (let p = n; p; p = p.parentNode) {
    if ('hidden' in (p.attrs || {}) || /display:\s*none/.test(String(p.attrs && p.attrs.style))) return false;
  }
  return true;
};

test('C6 FLESH OUT from the idea page: dialog, one exact command, a visible outcome, a locked button, RELOAD', async () => {
  const doc = installDom();
  const calls = ideaPage([200, { ok: true, type: 'run_script', ckey: 'k', command_id: 77 }]);
  const root = doc.createElement('div');
  mount(h(LV.RoadmapIdeaView, { project: P, id: ID }), root);
  try {
    await flush();
    const start = byTestId(root, 'pm-flesh-start')[0];
    assert.ok(start, 'the FLESH OUT button is on the idea page');
    assert.equal(start.textContent.trim(), 'FLESH OUT');
    assert.ok(visible(start), 'the button is visible');
    assert.equal(isDisabled(start), false);
    assert.match(root.textContent, /Press FLESH OUT to start one\./);

    fire(start, 'click');
    await flush();
    let dialog = dialogOf(root);
    assert.ok(dialog, 'the in-app dialog opened');
    assert.equal(dialog.attrs['aria-label'], 'FLESH OUT IDEA');
    assert.match(dialog.textContent, new RegExp(`one model call, billed to ${P}`));
    fire(buttonIn(dialog, 'CANCEL'), 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'CANCEL closes it');
    assert.equal(actions(calls).length, 0, 'a cancelled dialog sends nothing');

    fire(byTestId(root, 'pm-flesh-start')[0], 'click');
    await flush();
    dialog = dialogOf(root);
    fire(confirmOf(dialog), 'click');
    await flush();
    await flush();
    const sent = actions(calls);
    assert.equal(sent.length, 1, 'exactly one command');
    assert.equal(JSON.stringify(sent[0].body),
      `{"type":"run_script","project":"${P}","script":"pm-flesh-launch.sh","args":["${P}","${ID}"]}`);
    const outNode = byTestId(root, 'pm-flesh-outcome')[0];
    assert.ok(outNode && visible(outNode), 'the outcome is visible');
    assert.match(outNode.textContent, /FLESH OUT queued as command #77\./);
    const locked = byTestId(root, 'pm-flesh-start')[0];
    assert.equal(locked.textContent.trim(), 'FLESH OUT QUEUED #77');
    assert.equal(isDisabled(locked), true, 'a queued flesh-out locks the button');
    fire(locked, 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'a locked button opens nothing');
    assert.equal(actions(calls).length, 1, 'and sends nothing');

    const before = runReads(calls).length;
    fire(byTestId(root, 'pm-flesh-reload')[0], 'click');
    await flush();
    assert.equal(runReads(calls).length, before + 1, 'RELOAD reads the runs again');
  } finally { mount(null, root); }
});

test('C6b a refused command is shown and the button is enabled again; a bad id gets no button', async () => {
  const doc = installDom();
  const calls = ideaPage([400, { error: 'unknown action' }]);
  const root = doc.createElement('div');
  mount(h(LV.RoadmapIdeaView, { project: P, id: ID }), root);
  try {
    await flush();
    fire(byTestId(root, 'pm-flesh-start')[0], 'click');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    await flush();
    assert.equal(actions(calls).length, 1);
    const outNode = byTestId(root, 'pm-flesh-outcome')[0];
    assert.match(outNode.textContent, /FLESH OUT not sent: unknown action/);
    assert.equal(outNode.attrs['data-ok'], '0');
    assert.equal(isDisabled(byTestId(root, 'pm-flesh-start')[0]), false, 'a refusal leaves the button enabled');
  } finally { mount(null, root); }

  assert.deepEqual(PF.fleshOutcome({ ok: true }, null).ok, true);
  assert.equal(PF.fleshOutcome({}, null).ok, false, 'no command id is never "queued"');
  const bad = render(h(FS.FleshSection, { project: P, id: 'a b/c', f: { loading: false, error: null, data: EMPTY_RUNS } }));
  assert.doesNotMatch(bad, /data-testid="pm-flesh-start"/);
  assert.match(bad, /cannot be sent from here/);
});

// ── C7: the Pages fallback ──
function commandsDb() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(`CREATE TABLE commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ckey TEXT UNIQUE, type TEXT, project TEXT, payload TEXT,
    status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, lease_until TEXT, result TEXT,
    created_at TEXT, updated_at TEXT)`);
  const db = {
    prepare(sql) {
      const stmt = sqlite.prepare(sql);
      return {
        bind: (...args) => ({
          run: async () => ({ success: true, meta: { changes: Number(stmt.run(...args).changes) } }),
          first: async () => stmt.get(...args) || null,
          all: async () => ({ results: stmt.all(...args) })
        })
      };
    }
  };
  return { db, rows: () => sqlite.prepare('SELECT * FROM commands ORDER BY id').all() };
}

test('C7 pmFleshCommand admits one shape only', () => {
  assert.equal(typeof PFC.pmFleshCommand, 'function');
  const good = { type: 'run_script', project: P, script: 'pm-flesh-launch.sh', args: [P, ID], actor: 'console' };
  const cmd = PFC.pmFleshCommand(good);
  assert.equal(cmd.type, 'run_script');
  assert.equal(cmd.project, P);
  assert.deepEqual(cmd.payload, { script: 'pm-flesh-launch.sh', args: [P, ID], actor: 'console' });
  assert.match(cmd.ckey, new RegExp(`^${P}:run_script:pm-flesh:${ID}:\\d{4}-`));
  const refused = [
    { args: [P, ID, '--force'] },
    { args: [P, '--force'] },
    { args: ['other', ID] },
    { args: [P] },
    { args: [P, 'a/b'] },
    { args: [P, 'x'.repeat(81)] },
    { args: [P, 7] },
    { script: 'pm-flesh.sh' },
    { script: 'connection-probe.sh' },
    { type: 'run_triage' },
    { project: 'a/b', args: ['a/b', ID] }
  ];
  for (const over of refused) {
    assert.equal(PFC.pmFleshCommand({ ...good, ...over }).error, 'unknown action', JSON.stringify(over));
  }
});

test('C7b the Pages proxy queues FLESH OUT on the worker\'s unknown action; the probe arm is unchanged', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-30T08:00:30Z') });
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    if (new URL(String(url)).pathname === '/api/dash/fleet') {
      const good = new Headers(init && init.headers).get('cookie') === 'dash=good';
      return new Response('{}', { status: good ? 200 : 403 });
    }
    return new Response(JSON.stringify({ error: 'unknown action' }), { status: 400, headers: { 'content-type': 'application/json' } });
  });
  const w = commandsDb();
  const post = async (body, cookie = 'dash=good') => {
    const res = await dash({
      request: new Request('https://console.example/api/dash/action', {
        method: 'POST', headers: { 'content-type': 'application/json', cookie }, body: JSON.stringify(body)
      }),
      env: { CONSOLE_DB: w.db }
    });
    return { status: res.status, json: JSON.parse(await res.text()) };
  };
  const good = { type: 'run_script', project: P, script: 'pm-flesh-launch.sh', args: [P, ID], actor: 'browser-forged' };
  const r = await post(good);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.ckey, `${P}:run_script:pm-flesh:${ID}:2026-10-30T08:00`);
  const rows = w.rows();
  assert.equal(rows.length, 1);
  const p = JSON.parse(rows[0].payload);
  assert.deepEqual(p.args, [P, ID]);
  assert.equal(p.script, 'pm-flesh-launch.sh');
  assert.notEqual(p.actor, 'browser-forged', 'the proxy stamps the actor');
  assert.equal((await post({ ...good, args: [P, ID, '--force'] })).status, 400);
  assert.equal((await post(good, 'dash=bad')).status, 403);
  const probe = await post({ type: 'run_script', project: P, script: 'connection-probe.sh', args: [P] });
  assert.equal(probe.status, 200, 'PROBE NOW still queues');
  assert.equal(w.rows().length, 2);
});
