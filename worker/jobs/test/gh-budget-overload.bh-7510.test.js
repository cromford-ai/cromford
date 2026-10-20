// BH-7510: GET|POST /api/gh-budget on an overloaded D1 (Sentry CROMFORD-HARNESS-11).
//
// withD1Retry (BH-6690) already retries "D1 DB is overloaded" 5 times, then
// rethrows. The gh-budget routes had no guard, so that give-up escaped
// worker.fetch as an unhandled throw (a 500 with no body). And ghBudgetRow read
// D1 on every call, so every box's poll added load to a D1 that was already
// overloaded. This file pins the three answers:
//   * a per-isolate read-through cache: two GETs inside the TTL make one read;
//   * GET give-up: 200 with the last cached row and `stale: true` (entry at
//     most 120 s old), else 503 + Retry-After: 2;
//   * POST give-up: 503 + Retry-After: 2, never a stale row;
// and every non-overload error still rejects (Sentry still sees real bugs).
//
// The clock: node:test mock.timers on Date only, so the retry backoff's real
// setTimeout still runs and no assertion reads the wall clock.
import { test, mock } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { withD1Retry, D1_RETRY_ATTEMPTS } from "../src/lib/d1-retry.js";
import { openDb } from "./lib/d1-sqlite.bh-1030.js";

const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";
const OVERLOAD_2 = "D1 DB is overloaded. Too many requests queued.";
const SECRET = "test-secret";
const T0 = Date.parse("2026-10-19T12:00:00Z");
const SELECT = /^SELECT \* FROM gh_budget WHERE fingerprint=\?1$/;

// A gh_budget D1 stub. `rows` is the store of record. Set `db.fail` to a
// message to make every statement throw it; set `db.failSelect` to fail only
// the read. `db.reads` counts the SELECTs that reached the binding.
function budgetDb(rows = {}) {
  const db = { rows: { ...rows }, reads: 0, writes: 0, fail: null, failSelect: null };
  const stmt = (sql, binds = []) => ({
    bind: (...b) => stmt(sql, b),
    async first() {
      if (db.fail) throw new Error(db.fail);
      if (SELECT.test(sql)) {
        db.reads += 1;
        if (db.failSelect) throw new Error(db.failSelect);
        const r = db.rows[binds[0]];
        return r ? { ...r } : null;
      }
      return null;
    },
    async all() { if (db.fail) throw new Error(db.fail); return { results: [] }; },
    async run() {
      if (db.fail) throw new Error(db.fail);
      if (/^INSERT INTO gh_budget/.test(sql)) {
        db.writes += 1;
        const [fingerprint, cr, cl, crs, gr, gl, grs, fetched_at, box, updated_at] = binds;
        const old = db.rows[fingerprint];
        if (old && fetched_at < old.fetched_at) return { success: true, meta: { changes: 0 } };
        db.rows[fingerprint] = {
          fingerprint, core_remaining: cr, core_limit: cl, core_reset: crs,
          graphql_remaining: gr, graphql_limit: gl, graphql_reset: grs, fetched_at, box, updated_at,
        };
        return { success: true, meta: { changes: 1 } };
      }
      return { success: true, meta: { changes: 0 } };
    },
  });
  db.prepare = (sql) => stmt(sql);
  db.batch = async (s) => s.map(() => ({ results: [] }));
  return db;
}

const stored = (fp, fetched, remaining = 4200) => ({
  fingerprint: fp, core_remaining: remaining, core_limit: 5000, core_reset: 1,
  graphql_remaining: 4900, graphql_limit: 5000, graphql_reset: 1,
  fetched_at: fetched, box: "box-one", updated_at: "2026-10-19T11:59:00Z",
});

const req = (method, path, body) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const call = (db, method, path, body, extraEnv = {}) =>
  worker.fetch(req(method, path, body), { DB: db, HARNESS_SECRET: SECRET, ...extraEnv });
const get = (db, fp = "fp1", env) => call(db, "GET", `/api/gh-budget?fingerprint=${fp}`, undefined, env);
const post = (db, fp, fetched, remaining) => call(db, "POST", "/api/gh-budget", {
  fingerprint: fp, fetched_at: fetched, box: "box-one",
  core: { remaining, limit: 5000, reset: 1 }, graphql: { remaining: 4900, limit: 5000, reset: 1 },
});

// Runs fn with Date frozen at T0; fn gets tick(ms) to move it. console.warn
// lines are collected; a rejection is returned, not thrown.
async function withClock(fn) {
  mock.timers.enable({ apis: ["Date"], now: T0 });
  const lines = [];
  const orig = console.warn;
  console.warn = (...a) => { lines.push(a.join(" ")); };
  try {
    return { lines, out: await fn((ms) => mock.timers.tick(ms)) };
  } catch (err) {
    return { lines, err };
  } finally {
    console.warn = orig;
    mock.timers.reset();
  }
}

// ── T1: the read-through cache ───────────────────────────────────────────

test("C1: two GETs inside the 5 s window make one D1 read, same row", async () => {
  const db = budgetDb({ fp1: stored("fp1", 1758369600) });
  const { out, err } = await withClock(async (tick) => {
    const a = await get(db);
    tick(4000);
    const b = await get(db);
    return [a.status, b.status, (await a.json()).row, (await b.json()).row];
  });
  assert.equal(err, undefined);
  const [sa, sb, ra, rb] = out;
  assert.equal(sa, 200);
  assert.equal(sb, 200);
  assert.equal(ra.fetched_at, 1758369600);
  assert.equal(rb.fetched_at, 1758369600);
  assert.equal(rb.stale, undefined);
  assert.equal(db.reads, 1, "the second GET must come from the cache");
});

test("C2: a GET after the TTL reads D1 again", async () => {
  const db = budgetDb({ fp1: stored("fp1", 1758369600) });
  const { err } = await withClock(async (tick) => {
    await get(db);
    tick(6000);
    await get(db);
  });
  assert.equal(err, undefined);
  assert.equal(db.reads, 2);
});

test("C3: GH_BUDGET_CACHE_TTL_S=0 turns the cache off", async () => {
  const db = budgetDb({ fp1: stored("fp1", 1758369600) });
  await withClock(async () => {
    await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: "0" });
    await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: "0" });
    await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: "0" });
  });
  assert.equal(db.reads, 3);
});

for (const v of ["31", "abc", "-1", "2.5", ""]) {
  test(`C4: GH_BUDGET_CACHE_TTL_S=${JSON.stringify(v)} is ignored, the 5 s default applies`, async () => {
    const db = budgetDb({ fp1: stored("fp1", 1758369600) });
    await withClock(async (tick) => {
      await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: v });
      tick(4999);
      await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: v });
      tick(2);
      await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: v });
    });
    assert.equal(db.reads, 2, "2 reads: one cached hit inside 5 s, a re-read after it");
  });
}

test("C4b: GH_BUDGET_CACHE_TTL_S=30 is in range: 29 s later is still a cache hit", async () => {
  const db = budgetDb({ fp1: stored("fp1", 1758369600) });
  await withClock(async (tick) => {
    await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: "30" });
    tick(29000);
    await get(db, "fp1", { GH_BUDGET_CACHE_TTL_S: "30" });
  });
  assert.equal(db.reads, 1);
});

test("C4c: `row: null` is cached too (the first box after a deploy)", async () => {
  const db = budgetDb();
  await withClock(async () => {
    const a = await get(db, "nobody");
    assert.equal((await a.json()).row, null);
    await get(db, "nobody");
  });
  assert.equal(db.reads, 1);
});

test("C4d: a cached row is a copy: a caller cannot change the next answer", async () => {
  const { ghBudgetRow } = await import("../src/lib/core.js");
  const db = budgetDb({ fp1: stored("fp1", 1758369600) });
  const env = { DB: db };
  const a = await ghBudgetRow(env, "fp1", { nowMs: T0 });
  a.core.remaining = 0;
  const b = await ghBudgetRow(env, "fp1", { nowMs: T0 + 1000 });
  assert.equal(b.core.remaining, 4200);
  assert.equal(db.reads, 1);
});

test("C4e: the cache holds at most 256 fingerprints, oldest dropped first", async () => {
  const { ghBudgetRow, ghBudgetCached } = await import("../src/lib/core.js");
  const db = budgetDb();
  const env = { DB: db };
  for (let i = 0; i < 257; i++) await ghBudgetRow(env, `fp${i}`, { nowMs: T0 });
  assert.equal(ghBudgetCached(env, "fp0", 120000, T0), null, "the oldest entry is gone");
  assert.notEqual(ghBudgetCached(env, "fp1", 120000, T0), null);
  assert.notEqual(ghBudgetCached(env, "fp256", 120000, T0), null);
});

// ── T2: the degraded answers ─────────────────────────────────────────────

test("C5: GET give-up with a cached row answers 200 stale:true from that row, no throw, one warn", async () => {
  const db = budgetDb({ fp1: stored("fp1", 1758369600) });
  const { out, err, lines } = await withClock(async (tick) => {
    const a = await get(db);
    assert.equal(a.status, 200);
    tick(10000);
    db.fail = OVERLOAD;
    return get(db);
  });
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 200);
  const body = await out.json();
  assert.equal(body.stale, true);
  assert.equal(body.row.fingerprint, "fp1");
  assert.equal(body.row.fetched_at, 1758369600);
  assert.equal(body.cached_at, "2026-10-19T12:00:00Z");
  assert.equal(lines.length, 1);
  assert.match(lines[0], /gh_budget/);
  assert.match(lines[0], new RegExp(`${D1_RETRY_ATTEMPTS} attempt`));
});

for (const msg of [OVERLOAD, OVERLOAD_2]) {
  test(`C6: GET give-up with an empty cache is 503 + Retry-After: 2, retryable, d1_attempts (${msg.slice(-24)})`, async () => {
    const db = budgetDb({ fp1: stored("fp1", 1758369600) });
    db.fail = msg;
    const { out, err } = await withClock(() => get(db));
    assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
    assert.equal(out.status, 503);
    assert.equal(out.headers.get("retry-after"), "2");
    const body = await out.json();
    assert.equal(body.retryable, true);
    assert.equal(body.d1_attempts, D1_RETRY_ATTEMPTS);
    assert.match(body.detail, /overloaded/i, "the word bin/lib/jobs/req.sh retries on");
    assert.equal(body.stale, undefined);
  });
}

test("C7: POST whose read-back overloads is 503 + Retry-After, never 200 with wrote", async () => {
  const db = budgetDb();
  db.failSelect = OVERLOAD;
  const { out, err } = await withClock(() => post(db, "fp1", 1758369600, 4200));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 503);
  assert.equal(out.headers.get("retry-after"), "2");
  const body = await out.json();
  assert.equal(body.retryable, true);
  assert.equal(body.wrote, undefined);
  assert.equal(db.writes, 1, "the upsert ran once; the client's retry re-sends the same row");
});

test("C7b: POST whose upsert overloads is 503 + Retry-After", async () => {
  const db = budgetDb();
  db.fail = OVERLOAD;
  const { out, err } = await withClock(() => post(db, "fp1", 1758369600, 4200));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 503);
  assert.equal(out.headers.get("retry-after"), "2");
});

test("C7c: a good POST answers 200 wrote:true and refreshes the cache (the next GET reads 0 times)", async () => {
  const db = budgetDb();
  const { out } = await withClock(async () => {
    const p = await post(db, "fp1", 1758369600, 4200);
    const pb = await p.json();
    const readsAfterPost = db.reads;
    const g = await get(db);
    return { p, pb, readsAfterPost, gb: await g.json() };
  });
  assert.equal(out.p.status, 200);
  assert.equal(out.pb.wrote, true);
  assert.equal(out.pb.row.core.remaining, 4200);
  assert.equal(db.reads, out.readsAfterPost, "the GET was served from the POST's read-back");
  assert.equal(out.gb.row.core.remaining, 4200);
});

test("C8: a POST after a cached GET: the next GET shows the new fetched_at", async () => {
  const db = budgetDb({ fp1: stored("fp1", 1758369600, 4200) });
  const { out } = await withClock(async (tick) => {
    await get(db);
    tick(1000);
    await post(db, "fp1", 1758369660, 3100);
    tick(1000);
    return (await get(db)).json();
  });
  assert.equal(out.row.fetched_at, 1758369660);
  assert.equal(out.row.core.remaining, 3100);
});

for (const [age, status] of [[119000, 200], [120000, 200], [121000, 503]]) {
  test(`C9: stale-age edge: a cached row ${age / 1000} s old on a give-up answers ${status}`, async () => {
    const db = budgetDb({ fp1: stored("fp1", 1758369600) });
    const { out, err } = await withClock(async (tick) => {
      await get(db);
      tick(age);
      db.fail = OVERLOAD;
      return get(db);
    });
    assert.equal(err, undefined);
    assert.equal(out.status, status);
    if (status === 200) assert.equal((await out.json()).stale, true);
    else assert.equal(out.headers.get("retry-after"), "2");
  });
}

for (const msg of ["D1_ERROR: no such table: gh_budget", "D1_ERROR: database is locked", "DB is overload"]) {
  test(`C10: a non-overload error (${msg}) still rejects, even with a cached row`, async () => {
    const db = budgetDb({ fp1: stored("fp1", 1758369600) });
    const { err } = await withClock(async (tick) => {
      await get(db);
      tick(10000);
      db.fail = msg;
      return get(db);
    });
    assert.ok(err, "worker.fetch must reject");
    assert.equal(err.message, msg);
  });
  test(`C10b: POST with a non-overload error (${msg}) still rejects`, async () => {
    const db = budgetDb();
    db.fail = msg;
    const { err } = await withClock(() => post(db, "fp1", 1758369600, 4200));
    assert.ok(err, "worker.fetch must reject");
    assert.equal(err.message, msg);
  });
}

// ── T3: the index proof and the retry pin ────────────────────────────────

test("C11: the ghBudgetRow query uses the primary-key index on 2,000 seeded rows, no full SCAN", async (t) => {
  const opened = await openDb();
  if (!opened) { t.skip("node:sqlite not available"); return; }
  const { db } = opened;
  const ins = db.prepare("INSERT INTO gh_budget (fingerprint, core_remaining, fetched_at, updated_at) VALUES (?, ?, ?, ?)");
  db.exec("BEGIN");
  for (let i = 0; i < 2000; i++) ins.run(`fp${String(i).padStart(5, "0")}`, 4000, 1758369600 + i, "2026-10-19T12:00:00Z");
  db.exec("COMMIT");
  db.exec("ANALYZE");
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM gh_budget").get().n, 2000);
  // The exact string ghBudgetRow sends, read from a counting DB.
  const { ghBudgetRow } = await import("../src/lib/core.js");
  const seen = [];
  await ghBudgetRow({ DB: { prepare: (s) => { seen.push(s); return { bind: () => ({ first: async () => null }) }; } } }, "fp00007", { fresh: true });
  assert.equal(seen.length, 1);
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${seen[0]}`).all("fp00007").map((r) => r.detail).join(" | ");
  assert.match(plan, /sqlite_autoindex_gh_budget_1|PRIMARY KEY/, plan);
  assert.doesNotMatch(plan, /SCAN gh_budget(?! USING)/, plan);
});

test("C12: withD1Retry retries the overload message and returns the later success", async () => {
  let calls = 0;
  const sleeps = [];
  const v = await withD1Retry(async () => {
    calls += 1;
    if (calls <= 2) throw new Error(OVERLOAD);
    return 7;
  }, { sleep: async (ms) => { sleeps.push(ms); }, random: () => 0 });
  assert.equal(v, 7);
  assert.equal(calls, 3);
  assert.equal(sleeps.length, 2);
});
