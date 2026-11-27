import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { onRequest as dash } from '../functions/api/[[path]].js';
import {
  shapePauses, endCommandFor, fleetPauseCommandFor, resumeCommandFor, pauseDetail, boardPauseLines
} from '../src/lib/pauses.js';
import { FleetPauseForm, PauseReasonForm } from '../src/ui/PauseForms.js';
import { ProjectsTable, PauseBanner, FleetScreen } from '../src/screens/Fleet.js';
import { PauseDetail } from '../src/screens/Project.js';
import { FleetContext } from '../src/app.js';

// BH-2509. The Fleet page can set a fleet-scope pause (pause_set scope=fleet)
// with a required reason and TTL; pause_board / resume_board need a non-blank
// reason in the console modal AND at the command route (400 on blank); every
// paused board shows its reason, actor and time on / and /p/<project>.
//
// R-cases go through the REAL Pages onRequest with globalThis.fetch stubbed,
// the access-identity.bh-2515 way. The rest render the real components.

const CONSOLE = 'https://harness-console.operator.workers.dev';

function stub() {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    calls.push({ url, method: init.method, body: init.body == null ? null : String(init.body) });
    return new Response('{"ok":true,"command_id":7}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}
function post(body, env = {}) {
  return dash({
    request: new Request('https://mc.example.com/api/dash/action', {
      method: 'POST',
      headers: { cookie: 'dash=x', 'content-type': 'application/json' },
      body: typeof body === 'string' ? body : JSON.stringify(body)
    }),
    env, params: {}
  });
}
async function refused(body, error) {
  const s = stub();
  try {
    const res = await post(body);
    assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(body)}`);
    assert.deepEqual(await res.json(), { error });
    assert.equal(s.calls.length, 0, `nothing may be forwarded for ${JSON.stringify(body)}`);
  } finally { s.restore(); }
}
async function forwarded(body) {
  const s = stub();
  try {
    const res = await post(body);
    assert.equal(res.status, 200, `expected a forward for ${JSON.stringify(body)}`);
    assert.equal(s.calls.length, 1);
    assert.equal(s.calls[0].url, `${CONSOLE}/api/dash/action`);
    return JSON.parse(s.calls[0].body);
  } finally { s.restore(); }
}

// --- R: the command route ---------------------------------------------------

test('R1 pause_board with a whitespace reason is a 400 and nothing is forwarded', async () => {
  await refused({ type: 'pause_board', project: 'p', reason: '   ' }, 'reason required');
});

test('R2 pause_board with the reason missing, null, a number or an array is a 400', async () => {
  for (const extra of [{}, { reason: null }, { reason: 5 }, { reason: [] }, { reason: '\t\n' }]) {
    await refused({ type: 'pause_board', project: 'p', ...extra }, 'reason required');
  }
});

test('R3 resume_board needs a reason too; with one it is forwarded', async () => {
  await refused({ type: 'resume_board', project: 'p' }, 'reason required');
  await refused({ type: 'pause_set', project: 'p', what: 'merges', reason: ' ' }, 'reason required');
  const sent = await forwarded({ type: 'resume_board', project: 'p', reason: 'fixed' });
  assert.equal(sent.reason, 'fixed');
});

test('R4 a fleet pause_set with no or a bad ttl_s is a 400; 1800 is forwarded', async () => {
  const base = { type: 'pause_set', scope: 'fleet', what: 'merges', reason: 'x' };
  for (const ttl of [undefined, null, 0, -1, 1.5, '1.5', '', '30m', '0', true]) {
    const body = ttl === undefined ? base : { ...base, ttl_s: ttl };
    await refused(body, 'ttl_s required for a fleet pause');
  }
  assert.equal((await forwarded({ ...base, ttl_s: 1800 })).ttl_s, 1800);
  assert.equal((await forwarded({ ...base, ttl_s: '1800' })).ttl_s, '1800');
});

test('R5 a valid fleet pause_set reaches the console worker intact, plus the resolved actor', async () => {
  const sent = { type: 'pause_set', scope: 'fleet', what: 'merges', reason: 'release freeze', ttl_s: 1800, actor: 'mallory' };
  // Access off (no CF_ACCESS_* env): the proxy stamps console over the browser value.
  assert.deepEqual(await forwarded(sent), { ...sent, actor: 'console' });
});

test('R6 commands the rule is not about are forwarded without a reason', async () => {
  for (const body of [
    { type: 'pause_end', id: 9, scope: 'fleet' },
    { type: 'run_triage', project: 'p' },
    { type: 'automerge_off', project: 'p' },
    { type: 'fetch_log', project: 'p', kind: 'triage' },
    { type: 'pause_set', project: 'p', what: 'merges', reason: 'x' },
    // Not the fleet (exact match, as the poller reads it): no TTL required.
    { type: 'pause_set', project: 'p', scope: 'Fleet', what: 'merges', reason: 'x' },
    { type: 'pause_set', project: 'p', scope: ' fleet', what: 'merges', reason: 'x' }
  ]) {
    const got = await forwarded(body);
    assert.deepEqual(got, { ...body, actor: 'console' });
  }
});

// --- B: the pure builders ---------------------------------------------------

const now = Date.parse('2026-09-26T12:00:00Z');
const iso = (minFromNow) => new Date(now + minFromNow * 60000).toISOString();
const payload = {
  pauses: [
    { id: 21, scope: 'fleet', what: 'merges', reason: 'release freeze', actor: 'operator@example.com',
      created_at: iso(-120), expires_at: iso(30), ended_at: null },
    { id: 22, scope: 'project-3', what: 'triage', reason: 'client asked to hold', actor: 'operator@example.com',
      created_at: iso(-90), expires_at: iso(60), ended_at: null },
    { id: 23, scope: 'project-5', what: 'builds', reason: null, actor: 'console',
      created_at: iso(-5), expires_at: iso(60), ended_at: null }
  ],
  truncated: false
};
const rows = shapePauses(payload, now).rows;
const byId = (id) => rows.find((r) => r.id === id);

test('B1 fleetPauseCommandFor builds the pause_set fleet command, trimmed, with no project', () => {
  assert.deepEqual(fleetPauseCommandFor({ what: 'merges', reason: '  release freeze ', ttlS: ' 1800 ' }),
    { type: 'pause_set', scope: 'fleet', what: 'merges', reason: 'release freeze', ttl_s: 1800 });
  assert.deepEqual(fleetPauseCommandFor({ what: 'builds', reason: 'x', ttlS: 60 }),
    { type: 'pause_set', scope: 'fleet', what: 'builds', reason: 'x', ttl_s: 60 });
  assert.match(fleetPauseCommandFor({ what: 'all', reason: 'x', ttlS: '60' }).error, /what must be one of/);
});

test('B2 fleetPauseCommandFor refuses a blank reason', () => {
  for (const reason of ['', '   ', undefined, null, 5]) {
    assert.deepEqual(fleetPauseCommandFor({ what: 'merges', reason, ttlS: '1800' }), { error: 'reason required' });
  }
});

test('B3 fleetPauseCommandFor refuses a blank or bad TTL, never clamps it', () => {
  for (const ttlS of ['', '  ', undefined, null]) {
    assert.deepEqual(fleetPauseCommandFor({ what: 'merges', reason: 'x', ttlS }), { error: 'ttl required' });
  }
  for (const ttlS of ['0', '-5', '1.5', '30m', 0, -5, 1.5]) {
    assert.match(fleetPauseCommandFor({ what: 'merges', reason: 'x', ttlS }).error || '', /whole number/, `ttl=${ttlS}`);
  }
});

test('B4 endCommandFor with one argument is exactly the BH-1685 shape', () => {
  assert.deepEqual(endCommandFor(byId(21)), { type: 'pause_end', id: 21, scope: 'fleet' });
  assert.deepEqual(endCommandFor(byId(22)), { type: 'resume_board', project: 'project-3' });
  assert.deepEqual(endCommandFor(byId(23)), { type: 'pause_end', id: 23, project: 'project-5' });
});

test('B5 endCommandFor with a reason adds it trimmed, and refuses a blank one', () => {
  assert.deepEqual(endCommandFor(byId(21), '  '), { error: 'reason required' });
  assert.deepEqual(endCommandFor(byId(22), ''), { error: 'reason required' });
  assert.deepEqual(endCommandFor(byId(21), ' ok '), { type: 'pause_end', id: 21, scope: 'fleet', reason: 'ok' });
  assert.deepEqual(endCommandFor(byId(22), 'done'), { type: 'resume_board', project: 'project-3', reason: 'done' });
});

test('B6 resumeCommandFor trims the reason and refuses a blank one', () => {
  assert.deepEqual(resumeCommandFor('project-3', '  fixed  '), { type: 'resume_board', project: 'project-3', reason: 'fixed' });
  for (const r of ['', ' ', undefined, null]) {
    assert.deepEqual(resumeCommandFor('project-3', r), { error: 'reason required' });
  }
});

test('B7 pauseDetail names the reason, the actor, the age and the time', () => {
  const d = pauseDetail(byId(21));
  assert.match(d, /release freeze/);
  assert.match(d, /by operator@example\.com/);
  assert.match(d, /2h ago/);
  assert.ok(d.includes(iso(-120)), `created_at in ${d}`);
  assert.match(d, /FLEET \(all projects\)/);
  const c = pauseDetail(byId(23));
  assert.match(c, /by console \(no verified identity\)/);
  assert.match(c, /no reason given/);
  assert.match(pauseDetail({ ...byId(21), actor: null }), /by unknown/);
});

test('B8 boardPauseLines lists every row covering the board, and names a flag-only pause', () => {
  const project_3 = boardPauseLines(rows, 'project-3', true);
  assert.deepEqual(project_3.map((l) => l.what), ['merges', 'triage']);
  assert.match(project_3[0].text, /release freeze/);
  assert.match(project_3[1].text, /client asked to hold/);
  // The flag is set but no triage row is on record for this board.
  const flagOnly = boardPauseLines([], 'project-3', true);
  assert.equal(flagOnly.length, 1);
  assert.equal(flagOnly[0].what, null);
  assert.equal(flagOnly[0].text, 'paused by flag file: no pause row on record, reason and actor unknown');
  const ts = boardPauseLines(rows, 'project-5', true);
  // project-5 has no triage row, so the flag line leads, then its rows by what.
  assert.deepEqual(ts.map((l) => l.what), [null, 'builds', 'merges']);
  // A fleet triage row does not explain a project's flag file.
  const fleetTriage = shapePauses({ pauses: [{ ...payload.pauses[0], id: 30, what: 'triage' }] }, now).rows;
  assert.deepEqual(boardPauseLines(fleetTriage, 'x', true).map((l) => l.what), [null, 'triage']);
  // Rows cover a board whose flag is not set: they are listed without the flag line.
  assert.deepEqual(boardPauseLines(rows, 'project-3', false).map((l) => l.what), ['merges', 'triage']);
  assert.deepEqual(boardPauseLines([], 'project-3', false), []);
  assert.deepEqual(boardPauseLines(null, 'project-3', false), []);
});

// --- U: the dialog bodies ---------------------------------------------------

const noop = () => {};

test('U1 FleetPauseForm shows WHAT, REASON and TTL, and the hint while blank', () => {
  const out = render(h(FleetPauseForm, { value: { what: 'merges', reason: '', ttlS: '' }, onBlocked: noop }));
  assert.match(out, /WHAT/);
  assert.match(out, /REASON/);
  assert.match(out, /TTL \(SECONDS\)/);
  assert.match(out, /placeholder="1800 = 30 min"/);
  assert.match(out, /knob__note--bad/);
  assert.match(out, /reason is required/i);
  assert.equal((out.match(/aria-required="true"/g) || []).length, 2);
});

test('U2 FleetPauseForm asks for the TTL once the reason is typed, and is quiet once valid', () => {
  const noTtl = render(h(FleetPauseForm, { value: { what: 'merges', reason: 'x', ttlS: '' }, onBlocked: noop }));
  assert.match(noTtl, /TTL is required/i);
  const ok = render(h(FleetPauseForm, { value: { what: 'merges', reason: 'x', ttlS: '1800' }, onBlocked: noop }));
  assert.doesNotMatch(ok, /knob__note--bad/);
});

test('U3 PauseReasonForm shows the text and a required reason field', () => {
  const out = render(h(PauseReasonForm, { text: 'End PAUSED(merges)?', value: { reason: '' }, onBlocked: noop }));
  assert.match(out, /End PAUSED\(merges\)\?/);
  assert.match(out, /REASON/);
  assert.match(out, /aria-required="true"/);
  assert.match(out, /knob__note--bad/);
  const typed = render(h(PauseReasonForm, { text: 't', value: { reason: 'done' }, onBlocked: noop }));
  assert.doesNotMatch(typed, /knob__note--bad/);
});

// --- F: the Fleet page ------------------------------------------------------

const project = (name, paused = false) => ({
  project: name, last_run_age_min: 3, last_summary: 'ok', last_rc: 0, paused, automerge: true, fleet: {}
});
const rowHtml = (out, name) => {
  const trs = out.match(/<tr[^>]*>[\s\S]*?<\/tr>/g) || [];
  return trs.find((t) => t.includes(`>${name}<`)) || '';
};

test('F1 the red PAUSED tag title carries the actor as well as the reason and age', () => {
  const out = render(h(ProjectsTable, { rows: [project('project-3')], recentRuns: {}, pauses: rows }));
  const tag = rowHtml(out, 'project-3').match(/<span class="tag tag--bad" title="([^"]*)"[^>]*>PAUSED\(merges\)/);
  assert.ok(tag, 'the merges tag has a title');
  assert.match(tag[1], /release freeze/);
  assert.match(tag[1], /by operator@example\.com/);
  assert.match(tag[1], /2h ago/);
});

test('F2 a flag-file PAUSED with no row says so in its title', () => {
  const out = render(h(ProjectsTable, { rows: [project('project-5', true)], recentRuns: {}, pauses: [] }));
  const tag = rowHtml(out, 'project-5').match(/<span class="tag tag--warn" title="([^"]*)"[^>]*>PAUSED<\/span>/);
  assert.ok(tag, `the amber tag has a title in ${rowHtml(out, 'project-5')}`);
  assert.match(tag[1], /no pause row on record/);
  // With its triage row on record, the amber tag names that row instead.
  const withRow = render(h(ProjectsTable, { rows: [project('project-3', true)], recentRuns: {}, pauses: rows }));
  const t2 = rowHtml(withRow, 'project-3').match(/<span class="tag tag--warn" title="([^"]*)"[^>]*>PAUSED<\/span>/);
  assert.ok(t2);
  assert.match(t2[1], /client asked to hold/);
  assert.doesNotMatch(t2[1], /no pause row on record/);
});

test('F3 the PAUSES banner AGE cell carries created_at, and a console actor is labelled', () => {
  const out = render(h(PauseBanner, { rows, truncated: false, onEnd: noop }));
  assert.ok(out.includes(`title="${iso(-120)}"`), 'AGE title is created_at');
  assert.match(out, /console \(no verified identity\)/);
  assert.match(out, /operator@example\.com/);
});

test('F4 the Fleet page renders PAUSE FLEET with zero pauses', () => {
  const out = render(h(FleetContext.Provider, { value: { data: null } }, h(FleetScreen)));
  const btn = out.match(/<button[^>]*>\s*PAUSE FLEET…\s*<\/button>/);
  assert.ok(btn, 'PAUSE FLEET button renders');
  assert.match(btn[0], /btn--warn/);
  assert.doesNotMatch(btn[0], /disabled/);
  assert.doesNotMatch(out, /title="PAUSES"|>PAUSES</);
});

// --- P: the Project page ----------------------------------------------------

test('P1 the Project pause detail shows reason, actor and time for a triage row', () => {
  const out = render(h(PauseDetail, { rows, project: 'project-3', paused: true }));
  assert.match(out, /PAUSED\(triage\)/);
  assert.match(out, /client asked to hold/);
  assert.match(out, /by operator@example\.com/);
  assert.ok(out.includes(iso(-90)), 'created_at shown');
  // The fleet row covers this board too.
  assert.match(out, /PAUSED\(merges\)/);
  assert.doesNotMatch(out, /no pause row on record/);
});

test('P2 a flag-only pause shows the unknown line', () => {
  const out = render(h(PauseDetail, { rows: [], project: 'project-3', paused: true }));
  assert.match(out, /paused by flag file: no pause row on record, reason and actor unknown/);
});

test('P3 nothing renders when the board is not paused', () => {
  assert.equal(render(h(PauseDetail, { rows: [], project: 'project-3', paused: false })), '');
});
