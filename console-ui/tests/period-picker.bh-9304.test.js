// BH-9304 (BH-9120.0): the period picker, the chart, the side menu links and
// the JOBS screen, mounted into the shared fake DOM against a routed fetch.
//
// P*  PeriodPicker (src/ui/PeriodPicker.js) and its stylesheet.
// P6-P7 the real SideMenu carries from/to on Reports and Logs links only.
// C*  PeriodChart (src/ui/PeriodChart.js).
// S*  the real App and JobsScreen: side menu -> JOBS with a period, the
//     request the screen sends, the picker on it, polling, the knob default.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, type } from './helpers/fake-dom.bh-5750.js';

// The clock is pinned: every preset in this file resolves against NOW.
const NOW = Date.parse('2026-11-14T15:20:00Z');
Date.now = () => NOW;

const history = [];
const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
const store = new Map();
globalThis.window = {
  location: { pathname: '/jobs', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: {
    pushState(_s, _t, to) { history.push(['push', to]); setUrl(to); },
    replaceState(_s, _t, to) { history.push(['replace', to]); setUrl(to); }
  },
  scrollTo() {},
  localStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { PeriodPicker } = await import('../src/ui/PeriodPicker.js');
const { PeriodChart } = await import('../src/ui/PeriodChart.js');
const { SideMenu } = await import('../src/ui/SideMenu.js');
const { NAV, NAV_GROUPS, App } = await import('../src/app.js');
const { resolvePreset } = await import('../src/lib/period.js');
const { resetPeriodKnobs } = await import('../src/api.js');
const { parseRange } = await import('../../worker/jobs/src/lib/period.js');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); history.length = 0; resetPeriodKnobs(); });

function mountInto(vnode) {
  const doc = installDom();
  const el = doc.createElement('div');
  mounted.add(el);
  mount(vnode, el);
  return el;
}
const cls = (n) => ((n.attrs && n.attrs.class) || '').split(/\s+/).filter(Boolean);
const byCls = (r, c) => all(r).filter((n) => n.nodeType === 1 && cls(n).includes(c));
const byTag = (r, t) => all(r).filter((n) => n.localName === t);
const button = (r, label) => byTag(r, 'button').find((b) => b.textContent.trim() === label);
const text = (r) => r.textContent.replace(/\s+/g, ' ');
const WEEK = { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z', bucket: 'auto', compare: false };
const LABELS = ['Today', 'Yesterday', 'Last 7 days', 'Last 30 days', 'This month', 'Last month'];

// ------------------------------------------------------------------ P: picker

test('P1 the 6 preset buttons render; the active one is aria-pressed', async () => {
  const p = { ...resolvePreset('last_7_days', NOW), bucket: 'auto', compare: false };
  const el = mountInto(h(PeriodPicker, { period: p }));
  await flush();
  const presets = byCls(el, 'period-picker__preset').filter((b) => !cls(b).includes('period-picker__custom'));
  assert.deepEqual(presets.map((b) => b.textContent.trim()), LABELS);
  assert.deepEqual(presets.map((b) => b.attrs['aria-pressed']), ['false', 'false', 'true', 'false', 'false', 'false']);
  assert.ok(button(el, 'Custom'), 'a Custom button');
});

test('P2 Custom shows from/to datetime-local inputs and a visible UTC label', async () => {
  const el = mountInto(h(PeriodPicker, { period: { ...resolvePreset('today', NOW), bucket: 'auto', compare: false } }));
  await flush();
  assert.equal(byCls(el, 'period-picker__tz').length, 0, 'closed: no inputs yet');
  fire(button(el, 'Custom'), 'click');
  await flush();
  const tz = byCls(el, 'period-picker__tz');
  assert.equal(tz.length, 1);
  assert.equal(tz[0].textContent.trim(), 'UTC');
  const inputs = byTag(el, 'input').filter((i) => i.attrs.type === 'datetime-local');
  assert.deepEqual(inputs.map((i) => i.attrs.name), ['from', 'to']);
  // A custom URL period opens the inputs at once, filled with its values.
  const el2 = mountInto(h(PeriodPicker, { period: WEEK }));
  await flush();
  const vals = byTag(el2, 'input').filter((i) => i.attrs.type === 'datetime-local').map((i) => i.value ?? i.attrs.value);
  assert.deepEqual(vals, ['2026-10-01T00:00', '2026-10-08T00:00']);
});

test('P3 oldest shows "data from <date>"', async () => {
  const el = mountInto(h(PeriodPicker, { period: WEEK, oldest: '2026-09-01T10:00:00Z' }));
  await flush();
  assert.equal(byCls(el, 'period-picker__oldest')[0].textContent.trim(), 'data from 2026-09-01');
  const none = mountInto(h(PeriodPicker, { period: WEEK }));
  await flush();
  assert.equal(byCls(none, 'period-picker__oldest').length, 0);
});

test('P4 the stylesheet wraps and sets no fixed width over 375px; main.js loads it', () => {
  const css = read('src/period-picker.css');
  const block = /\.period-picker\s*\{([^}]*)\}/.exec(css);
  assert.ok(block, '.period-picker rule');
  assert.match(block[1], /flex-wrap:\s*wrap/);
  assert.match(block[1], /max-width:\s*100%/);
  for (const m of css.matchAll(/(?:^|[;{\s])(min-width|width):\s*(\d+)px/g)) {
    assert.ok(Number(m[2]) <= 375, `${m[1]}: ${m[2]}px`);
  }
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, 'theme variables only, no hex');
  assert.match(read('src/main.js'), /^import '\.\/period-picker\.css';$/m);
});

test('P5 a preset click writes from to the URL with replaceState and keeps other params', async () => {
  setUrl('/jobs?project=x&from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z');
  const el = mountInto(h(PeriodPicker, { period: WEEK }));
  await flush();
  fire(button(el, 'Last 30 days'), 'click');
  await flush();
  assert.deepEqual(history.map((x) => x[0]), ['replace']);
  const sp = new URLSearchParams(window.location.search);
  assert.equal(window.location.pathname, '/jobs');
  assert.equal(sp.get('project'), 'x');
  assert.equal(sp.get('from'), '2026-10-16T00:00:00Z');
  assert.equal(sp.get('to'), null, 'a rolling preset leaves the end open');
  fire(button(el, 'Yesterday'), 'click');
  await flush();
  assert.equal(new URLSearchParams(window.location.search).get('to'), '2026-11-14T00:00:00Z');
});

test('P8 bucket and compare: only when asked for; they write the URL', async () => {
  setUrl('/costs?from=2026-10-01T00:00:00Z');
  const plain = mountInto(h(PeriodPicker, { period: WEEK }));
  await flush();
  assert.equal(byCls(plain, 'period-picker__bucket').length, 0);
  assert.equal(byCls(plain, 'period-picker__compare').length, 0);
  const el = mountInto(h(PeriodPicker, { period: WEEK, bucket: true, compare: true }));
  await flush();
  const sel = byCls(el, 'period-picker__bucket')[0];
  assert.deepEqual(byTag(sel, 'option').map((o) => o.attrs.value ?? o.value), ['auto', 'hour', 'day', 'week']);
  sel.value = 'week';
  fire(sel, 'change');
  await flush();
  assert.equal(new URLSearchParams(window.location.search).get('bucket'), 'week');
  const box = byCls(el, 'period-picker__compare')[0];
  box.checked = true;
  fire(box, 'change');
  await flush();
  assert.equal(new URLSearchParams(window.location.search).get('compare'), '1');
});

test('P9 a custom start after the end shows an inline alert and does not navigate', async () => {
  setUrl('/jobs');
  const el = mountInto(h(PeriodPicker, { period: { ...resolvePreset('today', NOW), bucket: 'auto', compare: false } }));
  await flush();
  fire(button(el, 'Custom'), 'click');
  await flush();
  const [from, to] = byTag(el, 'input').filter((i) => i.attrs.type === 'datetime-local');
  type(from, '2026-10-08T00:00');
  type(to, '2026-10-01T00:00');
  await flush();
  fire(button(el, 'Apply'), 'click');
  await flush();
  const alert = all(el).find((n) => n.attrs && n.attrs.role === 'alert');
  assert.ok(alert, 'an inline role=alert message');
  assert.equal(alert.textContent.trim(), 'Start must be before end.');
  assert.equal(history.length, 0, 'no navigation');
  // A good range navigates, read as UTC.
  type(to, '2026-10-09T12:30');
  await flush();
  fire(button(el, 'Apply'), 'click');
  await flush();
  const sp = new URLSearchParams(window.location.search);
  assert.equal(sp.get('from'), '2026-10-08T00:00:00Z');
  assert.equal(sp.get('to'), '2026-10-09T12:30:00Z');
  const src = read('src/ui/PeriodPicker.js');
  assert.doesNotMatch(src, /\b(confirm|alert|prompt)\(/);
});

// ------------------------------------------------------------- P6-P7: menu

const menuProps = (over = {}) => ({ nav: NAV, groups: NAV_GROUPS, path: '/jobs', openAlerts: 0, open: false, onClose() {}, ...over });
const groupLinks = (el, g) => {
  const box = all(el).find((n) => n.attrs && n.attrs['data-group'] === g);
  return box ? byTag(box, 'a').map((a) => a.attrs.href) : [];
};

test('P6 the side menu: Reports and Logs links carry from/to, and nothing else does', async () => {
  setUrl('/jobs?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z&project=x');
  routedFetch(() => [200, { agents: [] }]);
  const el = mountInto(h(SideMenu, menuProps()));
  await flush();
  const q = '?from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z';
  for (const g of ['reports', 'logs']) {
    const hrefs = groupLinks(el, g);
    assert.ok(hrefs.length > 0, `${g} has links`);
    for (const href of hrefs) assert.ok(href.endsWith(q) && !href.includes('project='), `${g}: ${href}`);
  }
  assert.ok(groupLinks(el, 'logs').includes('/jobs' + q));
  for (const g of ['overview', 'system']) {
    for (const href of groupLinks(el, g)) assert.ok(!href.includes('?'), `${g}: ${href}`);
  }
});

test('P7 with no period in the URL every link is its NAV to', async () => {
  setUrl('/jobs?project=x');
  routedFetch(() => [200, { agents: [] }]);
  const el = mountInto(h(SideMenu, menuProps()));
  await flush();
  const hrefs = byTag(el, 'a').map((a) => a.attrs.href);
  const navTos = new Set(NAV.map((n) => n.to));
  for (const href of hrefs) assert.ok(navTos.has(href) || href.startsWith('/staff/'), href);
  assert.ok(hrefs.includes('/jobs') && hrefs.includes('/costs'));
});

// ------------------------------------------------------------------ C: chart

test('C1 an empty bucket is a gap labelled "no data", a real 0 is a zero bar labelled 0', async () => {
  const el = mountInto(h(PeriodChart, { series: [{ bucket: 'a', value: 3 }, { bucket: 'b', value: null }, { bucket: 'c', value: 0 }], bucket: 'day' }));
  await flush();
  const svg = byTag(el, 'svg')[0];
  assert.ok(svg && svg.attrs.role === 'img');
  const bars = byTag(svg, 'rect');
  assert.deepEqual(bars.map((r) => r.attrs['data-bucket']), ['a', 'c']);
  assert.equal(Number(bars[1].attrs.height), 0);
  assert.ok(Number(bars[0].attrs.height) > 0);
  const labels = byCls(svg, 'period-chart__value').map((t) => [t.attrs['data-bucket'], t.textContent]);
  assert.deepEqual(labels, [['a', '3'], ['b', 'no data'], ['c', '0']]);
});

test('C2 an empty series says "no data for this period"', async () => {
  const el = mountInto(h(PeriodChart, { series: [], bucket: 'day' }));
  await flush();
  assert.equal(byTag(el, 'svg').length, 0);
  assert.equal(byCls(el, 'period-chart__empty')[0].textContent.trim(), 'no data for this period');
});

test('C3 labels go through fmtNum by default, or the given format', async () => {
  const el = mountInto(h(PeriodChart, { series: [{ bucket: 'a', value: 1234 }], bucket: 'day' }));
  await flush();
  assert.equal(byCls(el, 'period-chart__value')[0].textContent, '1,234');
  const usd = mountInto(h(PeriodChart, { series: [{ bucket: 'a', value: 2 }], bucket: 'day', format: (v) => `$${v}` }));
  await flush();
  assert.equal(byCls(usd, 'period-chart__value')[0].textContent, '$2');
});

// --------------------------------------------------------- S: the JOBS screen

const JOB = (id, created) => ({
  id, project: 'project-3', kind: 'build', box: 'b1', stage: 'execute', status: 'done', heartbeating: false,
  age_s: 600, activity_age_s: 600, spent_usd: 1, budget_usd: 5, created_at: created, updated_at: created
});
// The open-claims read (status=running, no period) is a jobs URL with no from=.
const isOpenRead = (u) => u.startsWith('/api/coord/jobs?') && u.includes('status=running') && !u.includes('from=');
function screenFetch({ jobs = [JOB('job-in-week', '2026-10-03T00:00:00Z')], open = [200, { jobs: [], as_of: '2026-11-14T15:20:00Z' }], knobs = [200, { knobs: { default_preset: 'last_7_days' } }] } = {}) {
  return routedFetch((u) => {
    if (u.startsWith('/api/coord/period/knobs')) return knobs;
    if (isOpenRead(u)) return open;
    if (u.startsWith('/api/coord/jobs?')) return [200, { jobs, as_of: '2026-11-14T15:20:00Z' }];
    if (u.includes('/staff/roster')) return [200, { agents: [] }];
    if (u.includes('lanes')) return [200, { lanes: [] }];
    if (u.includes('burn')) return [200, { burn: [], days: 14 }];
    if (u.includes('flags')) return [200, { flags: [] }];
    return [200, {}];
  });
}
// The period reads only; the open-claims read is counted by openCalls.
const jobsCalls = (calls) => calls.filter((c) => c.url.startsWith('/api/coord/jobs?') && !isOpenRead(c.url)).map((c) => c.url);
const openCalls = (calls) => calls.filter((c) => isOpenRead(c.url)).map((c) => c.url);
const ENC = '?from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z';

async function mountApp(at, fetchOpts) {
  setUrl(at);
  const calls = screenFetch(fetchOpts);
  const el = mountInto(h(App));
  await flush();
  return { el, calls };
}

test('S1-S2 side menu Logs > JOBS with a period: the screen asks for that week and shows it', async () => {
  const { el, calls } = await mountApp('/nowhere?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z');
  const nav = all(el).find((n) => n.localName === 'nav' && n.attrs.id === 'sidemenu');
  const link = byTag(nav, 'a').find((a) => a.textContent.trim() === 'JOBS');
  assert.equal(link.attrs.href, '/jobs' + ENC);
  fire(link, 'click');
  await flush();
  assert.equal(window.location.pathname, '/jobs');
  assert.deepEqual(jobsCalls(calls), [`/api/coord/jobs${ENC}&limit=200`]);
  // S2: the rows, the picker on the custom range, the UTC label, the note.
  const pick = byCls(el, 'period-picker');
  assert.equal(pick.length, 1);
  assert.equal(byCls(el, 'period-picker__tz')[0].textContent.trim(), 'UTC');
  assert.equal(button(el, 'Custom').attrs['aria-pressed'], 'true');
  assert.ok(byTag(el, 'a').some((a) => a.attrs.href === '/jobs/job-in-week'), 'the row is listed');
  assert.match(text(el), /1 job created in this period/);
  assert.doesNotMatch(text(el), /newest 200 shown/);
});

test('S3 a picker click starts a new read whose range parseRange reads back the same', async () => {
  const { el, calls } = await mountApp('/jobs?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z');
  fire(button(el, 'Yesterday'), 'click');
  await flush();
  const urls = jobsCalls(calls);
  assert.equal(urls.length, 2);
  const want = resolvePreset('yesterday', NOW);
  const sp = new URL(urls[1], 'http://h').searchParams;
  assert.deepEqual({ from: sp.get('from'), to: sp.get('to') }, want);
  assert.deepEqual(parseRange(new URL(urls[1], 'http://h'), {}, NOW), want);
  assert.equal(button(el, 'Yesterday').attrs['aria-pressed'], 'true');
});

// The poll is a 20 s timer. Hold every 20 s timer instead of waiting for it,
// then run the held ones once: a polling read asks again, a stopped one does not.
async function pollOnce() {
  const real = globalThis.setTimeout;
  const held = [];
  globalThis.setTimeout = (fn, ms, ...a) => (ms === 20000 ? (held.push(fn), 0) : real(fn, ms, ...a));
  return {
    held,
    async run() { globalThis.setTimeout = real; held.splice(0).forEach((fn) => fn()); await flush(); },
    restore() { globalThis.setTimeout = real; }
  };
}

test('S4 a past closed range stops polling; an open range keeps polling; the cap note shows only at 200', async () => {
  let p = await pollOnce();
  try {
    const past = await mountApp('/jobs?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z');
    await p.run();
    assert.equal(jobsCalls(past.calls).length, 1, 'a past range reads once');
  } finally { p.restore(); }
  for (const r of mounted) mount(null, r);
  mounted.clear();
  p = await pollOnce();
  try {
    const many = Array.from({ length: 200 }, (_, i) => JOB(`job-${i}`, '2026-11-14T00:00:00Z'));
    const open = await mountApp('/jobs?from=2026-11-14T00:00:00Z', { jobs: many });
    await p.run();
    assert.equal(jobsCalls(open.calls).length, 2, 'an open range polls');
    assert.match(text(open.el), /200 jobs created in this period \(newest 200 shown\)/);
  } finally { p.restore(); }
});

test('S5 no URL period: the knob preset picks the read; a failed knob read falls back to last_7_days', async () => {
  const a = await mountApp('/jobs', { knobs: [200, { knobs: { default_preset: 'last_30_days' } }] });
  const sp = new URL(jobsCalls(a.calls)[0], 'http://h').searchParams;
  assert.equal(sp.get('from'), resolvePreset('last_30_days', NOW).from);
  assert.equal(sp.get('to'), null);
  assert.equal(button(a.el, 'Last 30 days').attrs['aria-pressed'], 'true');
  for (const r of mounted) mount(null, r);
  mounted.clear();
  resetPeriodKnobs();
  const b = await mountApp('/jobs', { knobs: [500, { error: 'boom' }], jobs: [] });
  const sp2 = new URL(jobsCalls(b.calls)[0], 'http://h').searchParams;
  assert.equal(sp2.get('from'), resolvePreset('last_7_days', NOW).from);
  assert.match(text(b.el), /No jobs created in this period\./);
  assert.equal(button(b.el, 'Last 7 days').attrs['aria-pressed'], 'true');
});

// ------------------------------------------- P10: the custom inputs resync

const customInputs = (el) => byTag(el, 'input').filter((i) => i.attrs.type === 'datetime-local');
const inputVals = (el) => customInputs(el).map((i) => i.value ?? i.attrs.value);

test('P10 the custom inputs follow a new active period', async () => {
  const doc = installDom();
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(PeriodPicker, { period: { ...resolvePreset('last_7_days', NOW), bucket: 'auto', compare: false } }), el);
  await flush();
  fire(button(el, 'Custom'), 'click');
  await flush();
  assert.deepEqual(inputVals(el), [resolvePreset('last_7_days', NOW).from.slice(0, 16), ''], 'opened on last_7_days (open end)');
  mount(h(PeriodPicker, { period: WEEK }), el);
  await flush();
  assert.deepEqual(inputVals(el), ['2026-10-01T00:00', '2026-10-08T00:00']);
});

test('P10b a re-render with the same period keeps what the user typed', async () => {
  const doc = installDom();
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(PeriodPicker, { period: WEEK }), el);
  await flush();
  type(customInputs(el)[0], '2026-10-02T06:00');
  await flush();
  mount(h(PeriodPicker, { period: { ...WEEK } }), el);
  await flush();
  assert.deepEqual(inputVals(el), ['2026-10-02T06:00', '2026-10-08T00:00']);
});

// ------------------------------------- OC: live tiles read the open claims

const statValue = (el, label) => {
  const lab = byCls(el, 'statgrid__label').find((n) => n.textContent.trim() === label);
  assert.ok(lab, `a "${label}" tile`);
  return byCls(lab.parentNode, 'statgrid__value')[0].textContent.trim();
};
const OLD_CLAIM = { ...JOB('job-old-claim', '2026-09-01T00:00:00Z'), status: 'running', heartbeating: true, activity_age_s: 30 };

test('OC1 a claim created before the period counts in "Claimed now" and "still claimed"', async () => {
  const { el, calls } = await mountApp('/jobs?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z&project=x', {
    open: [200, { jobs: [OLD_CLAIM], as_of: '2026-11-14T15:20:00Z' }]
  });
  assert.deepEqual(openCalls(calls), ['/api/coord/jobs?project=x&status=running&limit=200']);
  assert.equal(statValue(el, 'Claimed now'), '1');
  assert.match(text(el), /1 job created in this period · 1 still claimed/);
  // The period table still lists only the period's own row.
  assert.ok(byTag(el, 'a').some((a) => a.attrs.href === '/jobs/job-in-week'));
  assert.ok(!byTag(el, 'a').some((a) => a.attrs.href === '/jobs/job-old-claim'), 'the old claim is not a period row');
});

test('OC2 a past period reads once; the open-claims read keeps polling; a claim in both counts once', async () => {
  const inWeek = { ...OLD_CLAIM, id: 'job-both', created_at: '2026-10-03T00:00:00Z' };
  const p = await pollOnce();
  try {
    const { el, calls } = await mountApp('/jobs?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z', {
      jobs: [inWeek], open: [200, { jobs: [inWeek], as_of: '2026-11-14T15:20:00Z' }]
    });
    assert.equal(statValue(el, 'Claimed now'), '1');
    await p.run();
    assert.equal(jobsCalls(calls).length, 1, 'the past period reads once');
    assert.equal(openCalls(calls).length, 2, 'the open claims poll');
  } finally { p.restore(); }
});

test('OC3 a failed open-claims read: the tiles use the period rows and the table renders', async () => {
  const inWeek = { ...OLD_CLAIM, id: 'job-running-in-week', created_at: '2026-10-03T00:00:00Z' };
  const { el } = await mountApp('/jobs?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z', {
    jobs: [inWeek, JOB('job-done', '2026-10-04T00:00:00Z')], open: [500, { error: 'boom' }]
  });
  assert.equal(statValue(el, 'Claimed now'), '1');
  assert.match(text(el), /2 jobs created in this period · 1 still claimed/);
  assert.ok(byTag(el, 'a').some((a) => a.attrs.href === '/jobs/job-done'), 'the table renders');
  assert.doesNotMatch(text(el), /The jobs read failed/);
});
