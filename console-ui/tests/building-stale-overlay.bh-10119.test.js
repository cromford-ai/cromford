import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fetchStaleCount, overlayStale, _resetStaleCache } from '../functions/_lib/stale-overlay.js';
import {
  onRequest, _resetHeldCache, _resetClosedCache, _resetStageCache
} from '../functions/api/dash/kanban/pipeline.js';

// BH-10119 (item 5 of #10060) — the kanban's `building_stale` is the count of
// its detector, bin/stale-build-reaper.sh, not the console worker's raw count.
// The reaper writes ledgers(kind=building_stale, key=fleet) after each complete
// tick; the Pages function reads that row and overlays it while it is valid.
// fetch is stubbed: 0 network calls.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const LEDGER_URL = `${JOBS}/api/ledger?kind=building_stale&key=fleet`;
const ENV = { HARNESS_SECRET: 'secret-fixture' };

// The row in the exact shape the reaper PUTs (tests/stale-build-count.bh-10119-test.sh
// asserts the reaper's detail has these keys), plus the worker's timestamps.
const FIXTURE = JSON.parse(readFileSync(new URL('./fixtures/building-stale-ledger.bh-10119.json', import.meta.url), 'utf8'));
const VALID_UNTIL = Date.parse(JSON.parse(FIXTURE.detail).valid_until);
const row = (over = {}) => ({ ...FIXTURE, ...over });
const detail = (over = {}) => JSON.stringify({ ...JSON.parse(FIXTURE.detail), ...over });

const payload = () => ({
  columns: {
    queued: [{ id: 1, project: 'demo-os', ticket: 'DM-1', age_min: 5 }],
    building: [{ id: 7, project: 'demo-os', ticket: 'DM-7', age_min: 5 }],
    merge_queue: [], review: [], merged_deployed: [], dead_failed: []
  },
  counts: { queued: 1, building: 1, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: 0 },
  building_stale: 30,
  snapshot_age_min: 1
});

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function withFetch(route, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push(String(url));
    const a = route(String(url), init);
    if (a instanceof Error) throw a;
    return a;
  };
  const reset = () => { _resetHeldCache(); _resetClosedCache(); _resetStageCache(); _resetStaleCache(); };
  reset();
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; reset(); });
}

// ---------- 1. overlayStale, a valid row ----------
test('1 overlayStale: a valid row replaces building_stale and leaves every other field', () => {
  const p = payload();
  const out = overlayStale(p, { row: row() }, { now: VALID_UNTIL - 10 * 60000 });
  assert.equal(out.building_stale, 3);
  assert.equal(out.building_stale_source, 'reaper');
  assert.equal(out.building_stale_console, 30);
  assert.equal(out.building_stale_at, FIXTURE.updated_at);
  assert.equal(out.building_stale_reason, undefined);
  assert.deepEqual(out.counts, payload().counts);
  assert.deepEqual(out.columns, payload().columns);
  assert.equal(out.snapshot_age_min, 1);
  assert.equal(p.building_stale, 30, 'the input is not mutated');
});

// ---------- 2. the validity edge ----------
test('2 overlayStale: valid_until equal to now overlays; 1 s past keeps the console number, expired', () => {
  const at = overlayStale(payload(), { row: row() }, { now: VALID_UNTIL });
  assert.equal(at.building_stale, 3);
  assert.equal(at.building_stale_source, 'reaper');
  const past = overlayStale(payload(), { row: row() }, { now: VALID_UNTIL + 1000 });
  assert.equal(past.building_stale, 30);
  assert.equal(past.building_stale_source, 'console');
  assert.equal(past.building_stale_reason, 'expired');
});

// ---------- 3. every fallback ----------
test('3 overlayStale: no-row, unreadable and bad-row keep the console number, flagged', () => {
  const now = VALID_UNTIL - 60000;
  const cases = [
    [{ row: null }, 'no-row'],
    [null, 'unreadable'],
    [undefined, 'unreadable'],
    [{ row: row({ status: '3a' }) }, 'bad-row'],
    [{ row: row({ status: '-1' }) }, 'bad-row'],
    [{ row: row({ status: '' }) }, 'bad-row'],
    [{ row: row({ status: 3 }) }, 'bad-row'],
    [{ row: row({ detail: 'x' }) }, 'bad-row'],
    [{ row: row({ detail: null }) }, 'bad-row'],
    [{ row: row({ detail: JSON.stringify({ stale: 3 }) }) }, 'bad-row'],
    [{ row: row({ detail: detail({ valid_until: 'soon' }) }) }, 'bad-row'],
  ];
  for (const [answer, reason] of cases) {
    const out = overlayStale(payload(), answer, { now });
    assert.equal(out.building_stale, 30, `${JSON.stringify(answer)} keeps 30`);
    assert.equal(out.building_stale_source, 'console');
    assert.equal(out.building_stale_reason, reason, `${JSON.stringify(answer)} -> ${reason}`);
    assert.deepEqual(out.counts, payload().counts);
  }
  const zero = overlayStale(payload(), { row: row({ status: '0' }) }, { now });
  assert.equal(zero.building_stale, 0, 'a true zero is shown, not the console number');
  assert.equal(zero.building_stale_source, 'reaper');
});

// ---------- 4. a non-object payload ----------
test('4 overlayStale: a payload that is not an object comes back as it is', () => {
  for (const p of [null, 'x', 7, undefined]) assert.equal(overlayStale(p, { row: row() }, { now: 0 }), p);
  const arr = [1, 2];
  assert.equal(overlayStale(arr, { row: row() }, { now: 0 }), arr);
});

// ---------- 5. fetchStaleCount ----------
test('5a fetchStaleCount: no secret -> null, 0 fetches', () =>
  withFetch(() => jsonRes({ ledger: row() }), async (calls) => {
    assert.equal(await fetchStaleCount({}), null);
    assert.equal(await fetchStaleCount(undefined), null);
    assert.equal(calls.length, 0);
  }));

test('5b fetchStaleCount: 200 -> {row}, one PK GET with the secret; cached 60 s', () =>
  withFetch((u) => (u === LEDGER_URL ? jsonRes({ ledger: row() }) : new Error(`unexpected ${u}`)), async (calls) => {
    const a = await fetchStaleCount(ENV);
    assert.deepEqual(a, { row: row() });
    assert.deepEqual(calls, [LEDGER_URL]);
    const b = await fetchStaleCount(ENV);
    assert.deepEqual(b, { row: row() });
    assert.equal(calls.length, 1, 'a second call inside 60 s makes 0 more fetches');
  }));

test('5c fetchStaleCount: 404 -> {row:null}, cached', () =>
  withFetch(() => jsonRes({ error: 'not found' }, 404), async (calls) => {
    assert.deepEqual(await fetchStaleCount(ENV), { row: null });
    assert.deepEqual(await fetchStaleCount(ENV), { row: null });
    assert.equal(calls.length, 1);
  }));

test('5d fetchStaleCount: 500, a bad body and a throw -> null, not cached', async () => {
  await withFetch(() => jsonRes({ error: 'boom' }, 500), async (calls) => {
    assert.equal(await fetchStaleCount(ENV), null);
    assert.equal(await fetchStaleCount(ENV), null);
    assert.equal(calls.length, 2, 'after a 500 the next call fetches again');
  });
  await withFetch(() => new Response('<html>', { status: 200 }), async () => {
    assert.equal(await fetchStaleCount(ENV), null);
  });
  await withFetch(() => jsonRes({ nope: 1 }), async () => {
    assert.equal(await fetchStaleCount(ENV), null);
  });
  await withFetch(() => new Error('network down'), async () => {
    assert.equal(await fetchStaleCount(ENV), null);
  });
});

// ---------- 6. onRequest, the production entry point (REPRO) ----------
const req = () => new Request('https://console.example/api/dash/kanban/pipeline', { headers: { cookie: 'dash=tok' } });
const route = (ledger) => (u) => {
  if (u.startsWith('https://harness-console.operator.workers.dev/')) return jsonRes(payload());
  if (u === LEDGER_URL) return ledger();
  if (u.startsWith(`${JOBS}/api/ledger?`)) return jsonRes({ ledgers: [] });
  return new Error(`unexpected ${u}`);
};

test("6a onRequest replaces the console's building_stale with the reaper's valid row", () => {
  // The clock is pinned (Date only) 10 min before the fixture's valid_until.
  mock.timers.enable({ apis: ['Date'], now: VALID_UNTIL - 10 * 60000 });
  return withFetch(route(() => jsonRes({ ledger: row() })), async (calls) => {
    const res = await onRequest({ request: req(), env: ENV });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.building_stale, 3);
    assert.equal(body.building_stale_source, 'reaper');
    assert.equal(body.building_stale_console, 30);
    assert.deepEqual(body.counts, payload().counts, 'the counts do not change');
    assert.equal(calls.filter((u) => u === LEDGER_URL).length, 1);
  }).finally(() => mock.timers.reset());
});

test('6b onRequest: the ledger read answers 500 -> the console number, flagged unreadable', () =>
  withFetch(route(() => jsonRes({ error: 'boom' }, 500)), async () => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(body.building_stale, 30);
    assert.equal(body.building_stale_source, 'console');
    assert.equal(body.building_stale_reason, 'unreadable');
  }));

test('6c onRequest: an expired row -> the console number, flagged expired', () => {
  // The clock is pinned (Date only) 1 min after the fixture's valid_until.
  mock.timers.enable({ apis: ['Date'], now: VALID_UNTIL + 60000 });
  return withFetch(route(() => jsonRes({ ledger: row() })), async () => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(body.building_stale, 30);
    assert.equal(body.building_stale_reason, 'expired');
  }).finally(() => mock.timers.reset());
});

// ---------- 7. round-trip: the reaper's detail shape ----------
test("7 round-trip: the fixture's detail has the reaper's keys, and overlayStale reads stale and valid_until from it", () => {
  const d = JSON.parse(FIXTURE.detail);
  assert.deepEqual(Object.keys(d).sort(), ['at', 'candidates', 'held', 'mode', 'stale', 'valid_until', 'window_min']);
  assert.equal(String(d.stale), FIXTURE.status);
  const out = overlayStale(payload(), { row: FIXTURE }, { now: Date.parse(d.at) });
  assert.equal(out.building_stale, d.stale);
});
