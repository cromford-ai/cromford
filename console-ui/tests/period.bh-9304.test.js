// BH-9304 (BH-9120.0): the pure period library (src/lib/period.js), the api.js
// period calls, and the report seams (src/screens/period-report.d/).
// One fixed clock per case (the determinism lint).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { routedFetch } from './helpers/fake-dom.bh-5750.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const L = await import('../src/lib/period.js');
const { api, resetPeriodKnobs } = await import('../src/api.js');
const { REPORTS } = await import('../src/screens/period-report.d/index.js');

const at = (s) => Date.parse(s);
const H = 3600e3;
const D = 24 * H;

test('R1 today: from 00:00Z of the clock day, open to', () => {
  assert.deepEqual(L.resolvePreset('today', at('2026-03-31T15:20:00Z')), { from: '2026-03-31T00:00:00Z', to: null });
});
test('R2 yesterday across a month edge', () => {
  assert.deepEqual(L.resolvePreset('yesterday', at('2026-03-01T05:00:00Z')),
    { from: '2026-02-28T00:00:00Z', to: '2026-03-01T00:00:00Z' });
});
test('R3 last_7_days: today and the 6 days before, open to', () => {
  assert.deepEqual(L.resolvePreset('last_7_days', at('2026-03-01T05:00:00Z')), { from: '2026-02-23T00:00:00Z', to: null });
});
test('R4 last_30_days', () => {
  assert.deepEqual(L.resolvePreset('last_30_days', at('2026-03-31T23:59:59Z')), { from: '2026-03-02T00:00:00Z', to: null });
});
test('R5 this_month on the 31st', () => {
  assert.deepEqual(L.resolvePreset('this_month', at('2026-03-31T15:20:00Z')), { from: '2026-03-01T00:00:00Z', to: null });
});
test('R6 last_month at 2026-03-01 and across a year edge', () => {
  assert.deepEqual(L.resolvePreset('last_month', at('2026-03-01T05:00:00Z')),
    { from: '2026-02-01T00:00:00Z', to: '2026-03-01T00:00:00Z' });
  assert.deepEqual(L.resolvePreset('last_month', at('2026-01-15T12:00:00Z')),
    { from: '2025-12-01T00:00:00Z', to: '2026-01-01T00:00:00Z' });
});
test('R7 custom and unknown names resolve to null; PRESETS is the ticket list, frozen', () => {
  assert.equal(L.resolvePreset('custom', at('2026-03-01T00:00:00Z')), null);
  assert.equal(L.resolvePreset('last_year', at('2026-03-01T00:00:00Z')), null);
  assert.deepEqual([...L.PRESETS], ['today', 'yesterday', 'last_7_days', 'last_30_days', 'this_month', 'last_month', 'custom']);
  assert.ok(Object.isFrozen(L.PRESETS));
});

test('R8 periodQuery round trip keeps other params and replaces the old period', () => {
  const p = { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z', bucket: 'day', compare: true };
  const qs = L.periodQuery(p, new URLSearchParams('agent=x&from=old&bucket=week'));
  const sp = new URLSearchParams(qs);
  assert.equal(sp.get('agent'), 'x');
  assert.deepEqual(sp.getAll('from'), ['2026-10-01T00:00:00Z']);
  assert.deepEqual(L.parsePeriodQuery('?' + qs), p);
  const open = { from: '2026-10-01T00:00:00Z', to: null, bucket: 'auto', compare: false };
  assert.equal(L.periodQuery(open, { project: 'x' }), 'project=x&from=2026-10-01T00%3A00%3A00Z');
  assert.deepEqual(L.parsePeriodQuery('?' + L.periodQuery(open)), open);
});

test('R8b parsePeriodQuery ignores junk and needs a from', () => {
  assert.equal(L.parsePeriodQuery('?from=junk&to=2026-10-08'), null);
  assert.equal(L.parsePeriodQuery('?to=2026-10-08'), null);
  assert.equal(L.parsePeriodQuery(''), null);
  assert.deepEqual(L.parsePeriodQuery('?from=2026-10-01&to=1&bucket=HOUR&compare=yes'),
    { from: '2026-10-01', to: null, bucket: 'auto', compare: false });
});

test('R9 previousPeriod: same length, ends at from; an open to uses the clock', () => {
  assert.deepEqual(L.previousPeriod({ from: '2026-10-08T00:00:00Z', to: '2026-10-15T00:00:00Z' }),
    { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z' });
  assert.deepEqual(L.previousPeriod({ from: '2026-10-08T00:00:00Z', to: null }, at('2026-10-08T12:00:00Z')),
    { from: '2026-10-07T12:00:00Z', to: '2026-10-08T00:00:00Z' });
});

test('R10 csvHref keeps the period and adds format=csv', () => {
  const href = L.csvHref('/api/x', { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z', keep: { agent: 'a' } });
  assert.ok(href.startsWith('/api/x?'));
  assert.ok(href.endsWith('&format=csv'));
  const sp = new URL(href, 'http://h').searchParams;
  assert.equal(sp.get('from'), '2026-10-01T00:00:00Z');
  assert.equal(sp.get('to'), '2026-10-08T00:00:00Z');
  assert.equal(sp.get('agent'), 'a');
});

const BUCKETS = [
  ['B1 1 h', H, 'hour'], ['B2 47 h 59 m', 47 * H + 59 * 60e3, 'hour'], ['B3 exactly 48 h', 48 * H, 'hour'],
  ['B4 48 h + 1 s', 48 * H + 1000, 'day'], ['B5 89 d', 89 * D, 'day'], ['B6 90 d', 90 * D, 'day'],
  ['B7 90 d + 1 s', 90 * D + 1000, 'week'], ['B8 366 d', 366 * D, 'week'],
];
for (const [name, ms, want] of BUCKETS) test(`${name} -> ${want}`, () => assert.equal(L.pickBucket(ms), want));

test('K1 defaultPeriod: the knob preset, else last_7_days', () => {
  const now = at('2026-03-31T15:20:00Z');
  const seven = L.resolvePreset('last_7_days', now);
  assert.deepEqual(L.PERIOD_UI_FALLBACKS, { default_preset: 'last_7_days' });
  const pick = (k) => { const p = L.defaultPeriod(k, now); return { from: p.from, to: p.to }; };
  assert.deepEqual(pick({}), seven);
  assert.deepEqual(pick(null), seven);
  assert.deepEqual(pick({ default_preset: 'last_30_days' }), L.resolvePreset('last_30_days', now));
  assert.deepEqual(pick({ default_preset: 'custom' }), seven);
  assert.deepEqual(pick({ default_preset: 'junk' }), seven);
  assert.equal(L.activePreset(L.defaultPeriod({}, now), now), 'last_7_days');
  assert.equal(L.activePreset({ from: '2026-03-02T00:00:00Z', to: '2026-03-03T00:00:00Z' }, now), 'custom');
});

test('W1-W3 withPeriod carries from/to only, and only valid ones', () => {
  assert.equal(L.withPeriod('/costs', '?from=2026-10-01T00:00:00Z&to=2026-10-08T00:00:00Z&agent=x'),
    '/costs?from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z');
  assert.equal(L.withPeriod('/costs', '?from=2026-10-01'), '/costs?from=2026-10-01');
  assert.equal(L.withPeriod('/costs', '?agent=x'), '/costs');
  assert.equal(L.withPeriod('/costs', '?from=junk&to=2026-10-08'), '/costs');
  assert.equal(L.withPeriod('/costs', ''), '/costs');
});

const ok = (payload) => [200, payload];

test('A1 api.jobs with no period keeps today\'s URL', async () => {
  const calls = routedFetch(() => ok({ jobs: [] }));
  await api.jobs({ limit: 200 });
  await api.jobs({ limit: 200, project: 'p' });
  assert.deepEqual(calls.map((c) => c.url), ['/api/coord/jobs?limit=200', '/api/coord/jobs?project=p&limit=200']);
});

test('A2 api.jobs carries from and to before limit', async () => {
  const calls = routedFetch(() => ok({ jobs: [] }));
  await api.jobs({ limit: 200, from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z' });
  await api.jobs({ limit: 200, from: '2026-10-01T00:00:00Z' });
  assert.deepEqual(calls.map((c) => c.url), [
    '/api/coord/jobs?from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z&limit=200',
    '/api/coord/jobs?from=2026-10-01T00%3A00%3A00Z&limit=200',
  ]);
});

test('A3 api.periodKnobs reads /api/coord/period/knobs once per page load; a failure is retried', async () => {
  resetPeriodKnobs();
  let fail = true;
  const calls = routedFetch(() => (fail ? [500, { error: 'boom' }] : ok({ knobs: { default_preset: 'today' } })));
  await assert.rejects(api.periodKnobs());
  fail = false;
  const a = await api.periodKnobs();
  const b = await api.periodKnobs();
  assert.equal(a.knobs.default_preset, 'today');
  assert.equal(a, b);
  assert.deepEqual(calls.map((c) => c.url), ['/api/coord/period/knobs', '/api/coord/period/knobs']);
  resetPeriodKnobs();
});

test('A4 api.periodGet builds the period URL and refuses a non-/api/ path', async () => {
  const calls = routedFetch(() => ok({}));
  await api.periodGet('/api/coord/x', { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z', keep: { agent: 'a' } });
  assert.deepEqual(calls.map((c) => c.url),
    ['/api/coord/x?agent=a&from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z']);
  assert.throws(() => api.periodGet('https://evil.example/api/x', {}), /\/api\//);
  assert.throws(() => api.periodGet('//evil.example/api/x', {}), /\/api\//);
  assert.equal(calls.length, 1);
});

const SEAM_OWNER = {
  costs: 'BH-9120.1', outcomes: 'BH-9120.2', dora: 'BH-9120.2', ci: 'BH-9120.3', utilization: 'BH-9120.3',
  jobs: 'BH-9120.4', lanes: 'BH-9120.4', history: 'BH-9120.4', commands: 'BH-9120.4'
};

test('SE1 REPORTS has exactly the 9 seams, each null, each file naming its owner', () => {
  assert.deepEqual(Object.keys(REPORTS).sort(), Object.keys(SEAM_OWNER).sort());
  for (const k of Object.keys(SEAM_OWNER)) assert.equal(REPORTS[k], null, k);
  const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../src/screens/period-report.d');
  for (const [k, owner] of Object.entries(SEAM_OWNER)) {
    const text = fs.readFileSync(path.join(dir, `${k}.js`), 'utf8').trim();
    assert.equal(text, `export const report = null; // ${owner} owns this file`, k);
  }
});
