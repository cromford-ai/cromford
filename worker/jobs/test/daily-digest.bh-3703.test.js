// BH-3703 (BH-3688 slice 1 of 5): the daily-digest contract.
//
// WHAT IS PINNED
//   P* (pure): shape.js — dayWindow's bounds and nulls, capList's truncated
//     flag, isEmptyDigest's strict-zero rule (absent is not zero), notBuilt,
//     and guardSections' throw and missing-key paths.
//   S1: the two readers answer exactly SECTION_KEYS; core (BH-3704) and state
//     (BH-3705) both answer {ok:false,error} per section on a null db.
//   W4/C1/D2 (route): GET /api/metrics/daily-digest through the real
//     worker.fetch on a REAL schema.sql database: 400 on every bad param
//     (never clamped), the 5 + 10 key skeleton, and no write.
//   SEED*: the two schema.sql seeds, on the real schema.
//   F*: the two committed fixtures are the shape the siblings render.
//
// The worker's clock is the real one. TODAY/YESTERDAY/TOMORROW come off the ONE
// anchor below; a run that straddles UTC midnight is the only way they drift.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import {
  dayWindow, capList, isEmptyDigest, notBuilt, guardSections, SECTION_KEYS,
} from '../src/lib/daily-digest/shape.js';
import { readCoreSections } from '../src/lib/daily-digest/core-sections.js';
import { readStateSections } from '../src/lib/daily-digest/state-sections.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const ANCHOR = Date.now();  // determinism: ok the single anchor; the route's own clock is compared against it
const DAY = 86400e3;
const ymd = (ms) => new Date(ms).toISOString().slice(0, 10);
const TODAY = ymd(ANCHOR);
const YESTERDAY = ymd(ANCHOR - DAY);
const TOMORROW = ymd(ANCHOR + DAY);

const fixture = (name) => JSON.parse(readFileSync(
  new URL(`../../../tests/fixtures/daily-digest/${name}`, import.meta.url), 'utf8'));
const EMPTY = fixture('empty-day.json');
const FULL = fixture('fixture-day.json');
const clone = (o) => JSON.parse(JSON.stringify(o));
const NOT_BUILT = { ok: false, error: 'not built yet (BH-3688)' };
const ALL_KEYS = [...SECTION_KEYS.core, ...SECTION_KEYS.state];

const call = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

// ── P1 isEmptyDigest ─────────────────────────────────────────────────────────
// Every counter the ticket lists, as a setter that makes it 1 (or pushes a row).
const COUNTERS = {
  'throughput.merged': (d) => { d.throughput.merged = 1; },
  'spend.calls': (d) => { d.spend.calls = 1; },
  'autonomy.batch_dequeues.n': (d) => { d.autonomy.batch_dequeues.n = 1; },
  'autonomy.manual_requeues.n': (d) => { d.autonomy.manual_requeues.n = 1; },
  'autonomy.rebuild_loops.n': (d) => { d.autonomy.rebuild_loops.n = 1; },
  'autonomy.rebuild_loops.abandoned': (d) => { d.autonomy.rebuild_loops.abandoned = 1; },
  'autonomy.human_interventions.n': (d) => { d.autonomy.human_interventions.n = 1; },
  'tripwires.n': (d) => { d.tripwires.n = 1; },
  'holds.n': (d) => { d.holds.n = 1; },
  'model_watch.rows': (d) => { d.model_watch.rows.push(FULL.model_watch.rows[0]); },
  'spotcheck_candidates.rows': (d) => { d.spotcheck_candidates.rows.push(FULL.spotcheck_candidates.rows[0]); },
};

test('P1: isEmptyDigest is true on the committed empty day and nowhere else', () => {
  assert.equal(isEmptyDigest(clone(EMPTY)), true);
  assert.equal(isEmptyDigest(clone(FULL)), false);
  assert.equal(Object.keys(COUNTERS).length, 11);
  for (const [name, set] of Object.entries(COUNTERS)) {
    const d = clone(EMPTY); set(d);
    assert.equal(isEmptyDigest(d), false, `${name} = 1 must not read as empty`);
  }
  for (const k of ALL_KEYS) {
    const d = clone(EMPTY); d[k].ok = false;
    assert.equal(isEmptyDigest(d), false, `${k}.ok=false must not read as empty`);
  }
  const absent = clone(EMPTY); delete absent.throughput.merged;
  assert.equal(isEmptyDigest(absent), false, 'an absent counter is not zero');
  const str = clone(EMPTY); str.spend.calls = '0';
  assert.equal(isEmptyDigest(str), false, 'a "0" string is not zero');
  const loops = clone(EMPTY); loops.autonomy.rebuild_loops.abandoned = 1;
  assert.equal(isEmptyDigest(loops), false, 'n=0 with abandoned=1 is not empty');
  assert.equal(isEmptyDigest(null), false);
  assert.equal(isEmptyDigest({}), false);
  assert.equal(isEmptyDigest(undefined), false);
});

// ── P2 capList ───────────────────────────────────────────────────────────────
test('P2: capList slices to limit and flags truncation; a non-array throws', () => {
  const rows = (n) => Array.from({ length: n }, (_, i) => ({ i }));
  const a = capList(rows(25), 20);
  assert.equal(a.rows.length, 20);
  assert.equal(a.truncated, true);
  assert.deepEqual(a.rows[19], { i: 19 });
  assert.deepEqual(capList(rows(20), 20), { rows: rows(20), truncated: false });
  assert.deepEqual(capList([], 20), { rows: [], truncated: false });
  assert.throws(() => capList(null, 20), TypeError);
  assert.throws(() => capList({ length: 3 }, 20), TypeError);
});

// ── P3/P4 dayWindow ──────────────────────────────────────────────────────────
test('P3: dayWindow gives [day, day+1) in UTC across month, leap and year edges', () => {
  const now = '2029-01-15T12:00:00.000Z';
  assert.deepEqual(dayWindow('2026-02-28', now),
    { day: '2026-02-28', from: '2026-02-28T00:00:00Z', to: '2026-03-01T00:00:00Z' });
  assert.equal(dayWindow('2028-02-28', now).to, '2028-02-29T00:00:00Z');
  assert.equal(dayWindow('2028-02-29', now).to, '2028-03-01T00:00:00Z');
  assert.equal(dayWindow('2026-12-31', now).to, '2027-01-01T00:00:00Z');
});

test('P4: dayWindow answers null for a bad, unreal or future day, and allows today', () => {
  const now = '2026-09-30T07:00:05.123Z';
  for (const bad of ['2026-02-29', '2026-13-01', '2026-00-10', '2026-04-31', '2026-9-29',
    ' 2026-09-29', 'tomorrow', '', undefined, null, 20260929, '2026-10-01']) {
    assert.equal(dayWindow(bad, now), null, `${JSON.stringify(bad)} must be null`);
  }
  assert.equal(dayWindow('2026-09-29', 'not a date'), null);
  assert.equal(dayWindow('2026-09-29', undefined), null);
  assert.equal(dayWindow('2026-09-30', now).day, '2026-09-30');
  assert.equal(dayWindow('2026-09-29', now).to, '2026-09-30T00:00:00Z');
});

// ── notBuilt / P5 / P6 guardSections ─────────────────────────────────────────
test('notBuilt answers a fresh ok:false object each call', () => {
  const a = notBuilt();
  assert.deepEqual(a, NOT_BUILT);
  a.error = 'mutated';
  assert.deepEqual(notBuilt(), NOT_BUILT);
});

test('P5: a reader that throws marks every one of its keys ok:false with the message', async () => {
  const out = await guardSections(SECTION_KEYS.core, async () => { throw new Error('boom'); });
  assert.deepEqual(Object.keys(out), SECTION_KEYS.core);
  for (const k of SECTION_KEYS.core) assert.deepEqual(out[k], { ok: false, error: 'boom' });
});

test('P6: a reader that leaves a key out gets that key ok:false, never absent', async () => {
  const out = await guardSections(SECTION_KEYS.core, async () => ({ throughput: { ok: true, merged: 0 } }));
  assert.deepEqual(out.throughput, { ok: true, merged: 0 });
  assert.deepEqual(out.spend, { ok: false, error: 'section missing from reader' });
  assert.deepEqual(out.autonomy, { ok: false, error: 'section missing from reader' });
});

// ── S1 stubs ─────────────────────────────────────────────────────────────────
test('S1: both readers answer exactly their SECTION_KEYS; core and state fail per section on a null db', async () => {
  const win = dayWindow('2026-09-29', '2026-09-30T00:00:00Z');
  const opts = { limit: 20, loopMin: 2, trip: 2, humanActors: [] };
  const core = await readCoreSections(null, win, opts);
  const state = await readStateSections(null, win, opts);
  assert.deepEqual(Object.keys(core), ['throughput', 'spend', 'autonomy']);
  assert.deepEqual(Object.keys(core), SECTION_KEYS.core);
  // TEST-CHANGE: BH-3936 — pr_health is a state section, read before past_sla.
  assert.deepEqual(Object.keys(state),
    ['tripwires', 'self_heals', 'holds', 'human_verdict_prs', 'model_watch', 'spotcheck_candidates', 'factory', 'pr_health', 'past_sla']);
  assert.deepEqual(Object.keys(state), SECTION_KEYS.state);
  // BH-3704 built core, BH-3705 built state: a null db throws inside each section's own try.
  for (const [k, v] of Object.entries({ ...core, ...state })) {
    assert.equal(v.ok, false, k);
    assert.equal(typeof v.error, 'string', k);
  }
});

// ── F* fixtures ──────────────────────────────────────────────────────────────
// Every key path in a JSON value, with array elements collapsed to [].
const keyPaths = (v, p = '', out = new Set()) => {
  if (Array.isArray(v)) { v.forEach((e) => keyPaths(e, `${p}[]`, out)); return out; }
  if (v && typeof v === 'object') {
    for (const [k, e] of Object.entries(v)) { out.add(`${p}.${k}`); keyPaths(e, `${p}.${k}`, out); }
  }
  return out;
};
const listsOf = (d) => {
  const lists = [];
  const walk = (v, p) => {
    if (Array.isArray(v)) { lists.push([p, v]); return; }
    if (v && typeof v === 'object') for (const [k, e] of Object.entries(v)) walk(e, `${p}.${k}`);
  };
  walk(d, '');
  return lists;
};

test('F1: the empty day has every counter 0, null ratios, empty lists and empty:true', () => {
  assert.equal(EMPTY.empty, true);
  assert.equal(EMPTY.spend.usd, 0);
  assert.equal(EMPTY.spend.calls, 0);
  assert.equal(EMPTY.spend.usd_per_merged_pr, null);
  assert.equal(EMPTY.throughput.filing_to_merge.p50_s, null);
  assert.equal(EMPTY.factory.factory_stop.set, false);
  assert.equal(EMPTY.factory.all_off.set, false);
  for (const k of ALL_KEYS) assert.equal(EMPTY[k].ok, true, k);
  for (const [p, list] of listsOf(EMPTY)) assert.equal(list.length, 0, `${p} must be []`);
  for (const v of Object.values(EMPTY.autonomy.human_interventions.by_table)) assert.equal(v, 0);
});

test('F2: the fixture day carries every case the renderer has to handle', () => {
  assert.equal(FULL.empty, false);
  for (const [p, list] of listsOf(FULL)) {
    // TEST-CHANGE: BH-3936 — fixture-day keeps pr_health.rows empty (its `<1d`/`>7d`
    // template text would trip R6); tests/daily-digest-pr-health.bh-3929-test.sh renders the rows.
    if (p === '.pr_health.rows') continue;
    if (p === '.throughput.by_project' || p.endsWith('.rows') || p === '.factory.fleet_pauses') {
      assert.ok(list.length > 0, `${p} must have a row`);
    }
  }
  assert.equal(FULL.tripwires.n, 8);
  assert.equal(FULL.tripwires.rows.length, 8);
  // Row fields exactly as #3705 emits them: model_watch reads only the
  // status='suggested' rows, and the renderer buckets spot-checks on head_sha.
  for (const r of FULL.model_watch.rows) assert.deepEqual(Object.keys(r).sort(), ['model_id', 'suggestion', 'vendor']);
  for (const r of FULL.spotcheck_candidates.rows) {
    assert.deepEqual(Object.keys(r).sort(), ['head_sha', 'pr', 'project', 'repo']);
    assert.match(r.head_sha, /^[0-9a-f]{40}$/);
  }
  const sug = FULL.model_watch.rows;
  assert.ok(sug.some((r) => r.suggestion.length > 0));
  assert.ok(sug.some((r) => r.suggestion === ''));
  assert.ok(FULL.human_verdict_prs.rows.some((r) => /BLOCKED_HUMAN/.test(r.reason)));
  const keys = [...FULL.tripwires.rows.map((r) => r.key), ...FULL.spend.top_tickets.rows.map((r) => r.ticket)];
  assert.ok(keys.some((k) => /</.test(k) && />/.test(k) && /&/.test(k)), 'a key with < > &');
  assert.equal(FULL.spend.usd_per_merged_pr, FULL.spend.usd / FULL.throughput.merged);
  assert.equal(FULL.factory.factory_stop.set, true);
  assert.ok(FULL.factory.factory_stop.actor && FULL.factory.factory_stop.updated_at);
});

test('F3: both fixtures have one shape', () => {
  // Every key path the empty day has, the full day has too, and every path the
  // full day adds is inside a list the empty day leaves [].
  const e = keyPaths(EMPTY);
  for (const p of e) assert.ok(keyPaths(FULL).has(p), `fixture-day lacks ${p}`);
  for (const p of keyPaths(FULL)) {
    // past_sla.by_state (BH-3793) is a map of only the states with items past SLA, so empty-day's is {};
    // self_heals.by_source (BH-4724) is a map of only the sources that self-healed that day, the same way.
    if (!e.has(p)) assert.match(p, /\[\]|^\.past_sla\.by_state\.[a-z:-]+$|^\.self_heals\.by_source\.[a-z-]+$/, `${p} is in fixture-day only and is not inside a list`);
  }
  assert.deepEqual(Object.keys(FULL), Object.keys(EMPTY));
});

// ── route, on a real schema ──────────────────────────────────────────────────
test('BH-3703 GET /api/metrics/daily-digest on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('W4: every bad param is a 400 with an error string, never clamped', async () => {
    const { DB } = await openDb();
    const base = `/api/metrics/daily-digest?day=${YESTERDAY}`;
    const bad = [
      '/api/metrics/daily-digest',
      '/api/metrics/daily-digest?day=',
      '/api/metrics/daily-digest?day=2026-13-01',
      '/api/metrics/daily-digest?day=tomorrow',
      '/api/metrics/daily-digest?day=2026-02-29',
      '/api/metrics/daily-digest?day=2026-9-29',
      `/api/metrics/daily-digest?day=${TOMORROW}`,
      `${base}&limit=0`, `${base}&limit=101`, `${base}&limit=abc`, `${base}&limit=`, `${base}&limit=2.5`,
      `${base}&loop_min=1`, `${base}&loop_min=21`,
      `${base}&trip=0`, `${base}&trip=101`,
      `${base}&human=${'a'.repeat(129)}`,
      `${base}&human=${Array.from({ length: 21 }, (_, i) => `u${i}`).join(',')}`,
    ];
    for (const path of bad) {
      const r = await call(DB, path);
      assert.equal(r.status, 400, `${path} -> ${r.status} ${JSON.stringify(r.body)}`);
      assert.equal(typeof r.body.error, 'string', path);
    }
    for (const ok of [`${base}&limit=1`, `${base}&limit=100`, `${base}&loop_min=20`, `${base}&trip=100`,
      `${base}&human=the operator,,%20%20bob%20`, `/api/metrics/daily-digest?day=${TODAY}`]) {
      const r = await call(DB, ok);
      assert.equal(r.status, 200, `${ok} -> ${JSON.stringify(r.body)}`);
    }
  });

  await t.test('C1: yesterday answers the 5 + 10 key skeleton, core and state both read', async () => {
    const { db, DB } = await openDb();
    // BH-3793: the stuck-work lane's snapshot row, fresh and empty, so past_sla reads ok and 0.
    db.prepare(`INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES ('stuck_work_snapshot', 'latest', 'ok', ?, ?, ?)`)
      .run(JSON.stringify({ at: Math.floor(ANCHOR / 1000), complete: true, by_state: {}, total: 0 }),
        new Date(ANCHOR).toISOString(), new Date(ANCHOR).toISOString());
    const r = await call(DB, `/api/metrics/daily-digest?day=${YESTERDAY}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const w = dayWindow(YESTERDAY, new Date(ANCHOR).toISOString());
    assert.equal(r.body.day, YESTERDAY);
    assert.equal(r.body.from, w.from);
    assert.equal(r.body.to, w.to);
    assert.equal(typeof r.body.as_of, 'string');
    // Both halves built and the real DB has no activity: every counter is 0, so empty.
    assert.equal(r.body.empty, true);
    assert.deepEqual(Object.keys(r.body).sort(),
      ['day', 'from', 'to', 'as_of', 'empty', ...ALL_KEYS].sort());
    // BH-3704 core and BH-3705 state read the empty real DB; their own suites pin the values.
    for (const k of SECTION_KEYS.core) assert.equal(r.body[k].ok, true, `${k}: ${JSON.stringify(r.body[k])}`);
    for (const k of SECTION_KEYS.state) assert.equal(r.body[k].ok, true, k);
    // D4: the classifier on the route's own answer, and F3's key set is this one.
    assert.equal(isEmptyDigest(r.body), true);
    assert.deepEqual(Object.keys(r.body).sort(), Object.keys(EMPTY).sort());
  });

  await t.test('D2: a GET writes nothing', async () => {
    const { db, DB } = await openDb();
    const count = (tbl) => db.prepare(`SELECT COUNT(*) AS n FROM ${tbl}`).get().n;
    const before = { s: count('settings'), m: count('model_routes') };
    await call(DB, `/api/metrics/daily-digest?day=${YESTERDAY}`);
    await call(DB, `/api/metrics/daily-digest?day=${TODAY}&limit=5&human=operator`);
    assert.deepEqual({ s: count('settings'), m: count('model_routes') }, before);
  });

  await t.test('SEED1: the send-hour setting is 7 and stage.daily-digest copies stage.execute rung 0', async () => {
    const { db } = await openDb();
    assert.equal(db.prepare(`SELECT value FROM settings WHERE key='lane.daily-digest.daily_digest_send_hour_utc'`).get()?.value, '7');
    const dd = db.prepare(`SELECT model, runner FROM model_routes WHERE project IS NULL AND role='stage.daily-digest' AND position=0`).get();
    const ex = db.prepare(`SELECT model, runner FROM model_routes WHERE project IS NULL AND role='stage.execute' AND position=0`).get();
    assert.ok(dd, 'stage.daily-digest rung 0 is seeded');
    assert.deepEqual({ ...dd }, { ...ex });
  });

  await t.test('SEED2: an operator decision in model_route_changes is never re-seeded', async () => {
    const { db } = await openDb();
    db.exec(`DELETE FROM model_routes WHERE role='stage.daily-digest'`);
    db.prepare(`INSERT INTO model_route_changes (scope, project, role, position, actor, reason, at)
                VALUES ('hub', NULL, 'stage.daily-digest', 0, 'operator', 'removed on purpose', '2026-09-30T00:00:00Z')`).run();
    const schema = jobsSchemaSql();
    const seed = schema.split(/;\s*\n/).find((s) => /'stage\.daily-digest', 0/.test(s));
    assert.ok(seed, 'the stage.daily-digest seed statement is in schema.sql');
    db.exec(seed);
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM model_routes WHERE role='stage.daily-digest'`).get().n, 0);
  });

  await t.test('SEED3: no CREATE or ALTER statement in schema.sql mentions daily-digest', () => {
    const schema = jobsSchemaSql();
    const ddl = schema.split(/;\s*\n/).filter((s) => /^\s*(CREATE|ALTER|DROP)\b/im.test(s.replace(/--.*$/gm, '')));
    for (const s of ddl) assert.doesNotMatch(s.replace(/--.*$/gm, ''), /daily[-_]digest/i);
  });
});
