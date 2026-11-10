import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-9117. NOW shows what NEEDS A HUMAN is made of: open alerts, parked builds,
// stale builds, failed commands and ideas at the gate, each part a link to the
// list that shows those rows. The parts add up to the NEEDS A HUMAN value. The
// home screen (NowView) is rendered, so the links are tested where a user
// meets them.

globalThis.window = globalThis.window || {
  location: { pathname: '/now', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { needsSplit } = await import('../src/lib/cockpit.js');
const { NowView } = await import('../src/screens/Now.js');
const { NeedsView } = await import('../src/screens/Needs.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

const NOW = Date.UTC(2026, 10, 5, 22, 30);
const ago = (s) => new Date(NOW - s * 1000).toISOString();
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = () => ({ data: null, error: new Error('down'), loading: false, reload() {} });
const loading = () => ({ data: null, error: null, loading: true, reload() {} });
const NEEDS = { alerts: 3, builds: 2, commands: 1, proposals: 4, total: 10 };
const staleRow = { id: 77, bkey: 'b77', project: 'project-3', ticket_key: 'TK-900', stage: 'planning', tier: 2,
  verdict: null, pr_url: null, merged: 0, updated_at: ago(7200) };
const nowPayload = (over = {}) => ({
  boards: [], active_builds: [staleRow], active_builds_truncated: false, recent_runs: [], events: [],
  needs: NEEDS, generated_at: new Date(NOW).toISOString(), ...over
});
const jobs = ok({ jobs: [], as_of: new Date(NOW).toISOString() });

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function statValue(out, label) {
  const m = out.match(new RegExp(`stat__label">${esc(label)}</span>\\s*<span class="stat__value[^"]*">([\\s\\S]*?)</span>`));
  assert.ok(m, `no ${label} stat in the render`);
  return m[1].replace(/<[^>]+>/g, '').trim();
}
function splitLine(out) {
  const m = out.match(/<div class="section__note" data-testid="needs-split"[\s\S]*?<\/div>/);
  assert.ok(m, 'the NEEDS split line renders on NOW');
  return m[0];
}
const linkOf = (line, kind) => {
  const m = line.match(new RegExp(`<a href="([^"]+)"[^>]*data-kind="${kind}"[^>]*>([\\s\\S]*?)</a>`));
  assert.ok(m, `no ${kind} link in: ${line}`);
  return { href: m[1].replace(/&amp;/g, '&'), text: m[2].replace(/<!--.*?-->/g, '').replace(/\s+/g, ' ').trim() };
};

test('needsSplit: five parts, the total is server total plus stale', () => {
  const s = needsSplit(NEEDS, 1);
  assert.deepEqual(s.parts.map((p) => [p.key, p.value, p.to]), [
    ['alerts', 3, '/alerts'],
    ['builds', 2, '/needs?kind=build'],
    ['stale', 1, '/needs?kind=stale'],
    ['commands', 1, '/needs?kind=command'],
    ['proposals', 4, '/ideas?status=gate_pending']
  ]);
  assert.equal(s.total, 11);
  assert.equal(s.parts.reduce((n, p) => n + p.value, 0), s.total, 'the parts add up to the total');
});

test('needsSplit: an unknown read is null, never an invented 0', () => {
  const none = needsSplit(null, 2);
  assert.equal(none.total, null);
  for (const p of none.parts.filter((x) => x.key !== 'stale')) assert.equal(p.value, null, p.key);
  assert.equal(needsSplit({ alerts: 1, total: null }, 0).total, null);
  const noJobs = needsSplit(NEEDS, null);
  assert.equal(noJobs.parts.find((p) => p.key === 'stale').value, null);
  // No jobs read adds no stale rows: the server total stands (building-now B5).
  assert.equal(noJobs.total, 10);
});

test('NOW renders the split line, each part a link to its list, and NEEDS A HUMAN is their sum', () => {
  const out = render(h(NowView, { data: ok(nowPayload()), jobs, nowMs: NOW }));
  const line = splitLine(out);
  const want = {
    alerts: ['/alerts', '3 open alerts'],
    builds: ['/needs?kind=build', '2 parked builds'],
    stale: ['/needs?kind=stale', '1 stale builds'],
    commands: ['/needs?kind=command', '1 failed commands'],
    proposals: ['/ideas?status=gate_pending', '4 ideas at the gate']
  };
  for (const [kind, [href, text]] of Object.entries(want)) {
    const l = linkOf(line, kind);
    assert.equal(l.href, href, kind);
    assert.equal(l.text, text, kind);
    const path = href.split('?')[0];
    assert.ok(ROUTES.some(([p]) => matchRoute(p, path)), `${path} is a real route`);
  }
  assert.equal(statValue(out, 'NEEDS A HUMAN'), '11');
  assert.match(line, /flex-wrap:wrap/, 'the line wraps at 375 px');
});

test('a failed jobs read: the stale part is a dash and NEEDS A HUMAN is the server total', () => {
  const out = render(h(NowView, { data: ok(nowPayload()), jobs: failed(), nowMs: NOW }));
  assert.equal(linkOf(splitLine(out), 'stale').text, '— stale builds');
  assert.equal(statValue(out, 'NEEDS A HUMAN'), '10');
});

test('before /now answers: every part reads … and no number is shown', () => {
  const out = render(h(NowView, { data: loading(), jobs: loading(), nowMs: NOW }));
  const line = splitLine(out);
  for (const kind of ['alerts', 'builds', 'stale', 'commands', 'proposals']) {
    assert.match(linkOf(line, kind).text, /^… /, kind);
  }
  assert.equal(statValue(out, 'NEEDS A HUMAN'), '…');
});

test('the parked-builds link lands on a NEEDS list that shows those rows', () => {
  const builds = [
    { id: 12, bkey: 'k12', project: 'project-3', ticket_key: 'TK-2', stage: 'plan_blocked', tier: 2, verdict: null, pr_url: '', merged: 0, updated_at: ago(90000) },
    { id: 14, bkey: 'k14', project: 'project-3', ticket_key: 'TK-3', stage: 'pr_created', tier: 2, verdict: 'APPROVE', pr_url: '', merged: 0, updated_at: ago(90000) }
  ];
  const payload = {
    project: null, alerts: [], commands: [], builds, proposals: [], unfinished_builds: [],
    counts: { alerts: 0, commands: 0, builds: 2, proposals: 0, total: 2 },
    truncated: { alerts: false, commands: false, builds: false, proposals: false, unfinished_builds: false },
    generated_at: new Date(NOW).toISOString()
  };
  const out = render(h(NeedsView, { needs: ok(payload), jobs, project: null, kindFilter: 'build', nowMs: NOW, setParam() {} }));
  for (const k of ['TK-2', 'TK-3']) assert.ok(out.includes(k), `${k} is on the list`);
});
