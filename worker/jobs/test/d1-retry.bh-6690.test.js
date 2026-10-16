// BH-6690: the harness-jobs worker retries a D1 call that fails with
// "D1 DB is overloaded", at most 5 attempts (BH-6813; 3 in BH-6690) with
// exponential backoff and jitter, and rethrows every other error at once.
// On give-up the error carries d1Attempts, and the one Sentry event withSentry
// already sends carries it as tag d1_attempts. Sentry sends are counted through a stubbed globalThis.fetch,
// as in sentry.bh-5618.test.js; the DSN is a fixture on a reserved TLD.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

// Loaded per test, so the end-to-end cases run (and fail) against a tree
// without the lib, instead of the whole file failing to import.
const lib = () => import("../src/lib/d1-retry.js");
const sentryLib = () => import("../src/lib/sentry.js");

const DSN = "https://fixturepubkey@sentry.test/42";
const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";
const OVERLOAD_2 = "D1 DB is overloaded. Too many requests queued.";

// sleep records each wait and resolves at once; random is fixed.
function clock(r = 0.5) {
  const waits = [];
  return { waits, sleep: async (ms) => { waits.push(ms); }, random: () => r };
}

// fn throws the given values in order, then returns `value`.
function seq(throws, value = { ok: 1 }) {
  const f = async () => {
    f.calls += 1;
    if (f.calls <= throws.length) {
      const x = throws[f.calls - 1];
      throw typeof x === "string" ? new Error(x) : x;
    }
    return value;
  };
  f.calls = 0;
  return f;
}

test("A1: two overloads then success — returns the value after 3 calls, exponential waits", async () => {
  const { withD1Retry } = await lib();
  const c = clock(0.5);
  const fn = seq([OVERLOAD, OVERLOAD]);
  const got = await withD1Retry(fn, { sleep: c.sleep, random: c.random });
  assert.deepEqual(got, { ok: 1 });
  assert.equal(fn.calls, 3);
  assert.equal(c.waits.length, 2);
  assert.ok(c.waits[0] >= 50 && c.waits[0] <= 100, `wait 1 in [50,100]: ${c.waits[0]}`);
  assert.ok(c.waits[1] >= 100 && c.waits[1] <= 200, `wait 2 in [100,200]: ${c.waits[1]}`);
  assert.ok(c.waits[1] > 50, "wait 2 is above wait 1's lower bound");
});

test("A2: overload on every call — gives up after 5 attempts, same error, d1Attempts=5, onGiveUp once", async () => {
  const { withD1Retry } = await lib();
  const c = clock();
  const err = new Error(OVERLOAD);
  const fn = seq([err, err, err, err, err, err]);
  const gave = [];
  await assert.rejects(
    () => withD1Retry(fn, { sleep: c.sleep, random: c.random, onGiveUp: (e, n) => gave.push([e, n]) }),
    (e) => e === err,
  );
  assert.equal(fn.calls, 5);
  assert.equal(err.d1Attempts, 5);
  assert.equal(gave.length, 1);
  assert.equal(gave[0][0], err);
  assert.equal(gave[0][1], 5);
});

test("A3: a SQL syntax error — no retry, rethrown at once, no mark", async () => {
  const { withD1Retry } = await lib();
  const c = clock();
  const err = new Error('near "SELEC": syntax error');
  const fn = seq([err]);
  await assert.rejects(() => withD1Retry(fn, { sleep: c.sleep, random: c.random }), (e) => e === err);
  assert.equal(fn.calls, 1);
  assert.equal(c.waits.length, 0);
  assert.equal(err.d1Attempts, undefined);
});

// The decision table: retry if and only if the message holds
// "D1 DB is overloaded" and attempts < 5.
const TABLE = [
  ["D1", "Cloudflare text 1, always", [OVERLOAD, OVERLOAD, OVERLOAD, OVERLOAD, OVERLOAD], 5, false],
  ["D2", "Cloudflare text 2, always", [OVERLOAD_2, OVERLOAD_2, OVERLOAD_2, OVERLOAD_2, OVERLOAD_2], 5, false],
  ["D3", "overload on attempt 4 of 5 is still retried", [OVERLOAD, OVERLOAD, OVERLOAD, OVERLOAD], 5, true],
  ["D4", "one overload then success", [OVERLOAD_2], 2, true],
  ["D5", "syntax error", ['near "SELEC": syntax error'], 1, false],
  ["D6", "no such table", ["D1_ERROR: no such table: hub_lease"], 1, false],
  ["D7", "overload on attempt 5 of 5 gives up", [OVERLOAD, OVERLOAD, OVERLOAD, OVERLOAD, OVERLOAD, "never reached"], 5, false],
  ["D8", "a thrown non-Error string", ["__string__"], 1, false],
];

for (const [id, what, throws, calls, ok] of TABLE) {
  test(`${id}: ${what} — ${calls} call(s), ${ok ? "resolves" : "rejects"}`, async () => {
    const { withD1Retry, isD1Overloaded } = await lib();
    const c = clock();
    let fn;
    if (throws[0] === "__string__") {
      fn = async () => { fn.calls += 1; throw "boom"; };
      fn.calls = 0;
      assert.equal(isD1Overloaded("boom"), false);
    } else {
      fn = seq(throws);
    }
    const p = withD1Retry(fn, { sleep: c.sleep, random: c.random });
    if (ok) assert.deepEqual(await p, { ok: 1 });
    else await assert.rejects(p);
    assert.equal(fn.calls, calls);
  });
}

// A fake D1 binding. Each statement method runs through `exec`, which throws
// the next queued error (if any) and otherwise answers. `this` is recorded so
// a test can check the method ran on the RAW statement.
function fakeDb({ fail = [], row = { n: 1 } } = {}) {
  const queue = [...fail];
  const db = { execs: 0, thisSeen: [], batches: [] };
  const exec = (self) => {
    db.execs += 1;
    db.thisSeen.push(self);
    if (queue.length) throw new Error(queue.shift());
  };
  const stmt = (sql, args = []) => {
    const s = {
      sql, args,
      bind(...a) { return stmt(sql, a); },
      async first() { exec(this); return row; },
      async all() { exec(this); return { results: [row] }; },
      async run() { exec(this); return { success: true }; },
      async raw() { exec(this); return [[1]]; },
    };
    return s;
  };
  db.prepare = (sql) => stmt(sql);
  db.batch = async (stmts) => { db.batches.push(stmts); exec(db); return stmts.map(() => ({ success: true })); };
  db.exec = async () => { exec(db); return { count: 1 }; };
  return db;
}

test("P1: retryingDb is memoised per binding; null passes through", async () => {
  const { retryingDb } = await lib();
  const db = fakeDb();
  assert.equal(retryingDb(db), retryingDb(db));
  assert.notEqual(retryingDb(db), db);
  assert.equal(retryingDb(null), null);
  assert.equal(retryingDb(undefined), undefined);
});

test("P2: prepare().bind().first() retries two overloads; the method runs on the raw statement", async () => {
  const { retryingDb } = await lib();
  const db = fakeDb({ fail: [OVERLOAD, OVERLOAD], row: { id: 7 } });
  const p = retryingDb(db);
  const s = p.prepare("SELECT ?1");
  const b = s.bind(1);
  assert.deepEqual(b.args, [1], "plain fields read through");
  assert.deepEqual(await b.first(), { id: 7 });
  assert.equal(db.execs, 3);
  for (const self of db.thisSeen) {
    assert.equal(typeof self.first, "function");
    assert.notEqual(self, b, "`this` is the raw statement, not the proxy");
    assert.deepEqual(self.args, [1]);
  }
});

test("P3: batch hands the RAW statements to the binding and retries one overload", async () => {
  const { retryingDb } = await lib();
  const db = fakeDb({ fail: [OVERLOAD] });
  const raw = [];
  const realPrepare = db.prepare;
  db.prepare = (sql) => { const s = realPrepare(sql); raw.push(s); return s; };
  const p = retryingDb(db);
  const out = await p.batch([p.prepare("INSERT a"), p.prepare("INSERT b")]);
  assert.equal(out.length, 2);
  assert.equal(db.batches.length, 2, "first batch overloaded, second ran");
  for (const sent of db.batches) {
    assert.equal(sent[0], raw[0]);
    assert.equal(sent[1], raw[1]);
  }
});

test("P4: a sync throw in prepare passes through unchanged and is not retried", async () => {
  const { retryingDb } = await lib();
  let calls = 0;
  const err = new Error(OVERLOAD);
  const db = { prepare() { calls += 1; throw err; } };
  assert.throws(() => retryingDb(db).prepare("SELECT 1"), (e) => e === err);
  assert.equal(calls, 1);
  assert.equal(err.d1Attempts, undefined);
});

test("P5: the raw binding and its retry proxy share one ensureTable/ensureColumns cache entry", async () => {
  const { retryingDb, rawDb } = await lib();
  const { ensureTable, ensureColumns } = await import("../src/lib/core.js");
  const db = fakeDb();
  assert.equal(rawDb(retryingDb(db)), db);
  assert.equal(rawDb(db), db);
  await ensureTable({ DB: db }, "harness_flags");
  await ensureColumns({ DB: db }, "pause_flags");
  const warm = db.execs;
  assert.ok(warm > 0, "the warm-up ran statements");
  await ensureTable({ DB: retryingDb(db) }, "harness_flags");
  await ensureColumns({ DB: retryingDb(db) }, "pause_flags");
  assert.equal(db.execs, warm, "the proxy hit the cache the raw binding filled");
});

// A DB for the real worker: every statement method on any SQL answers empty,
// except the first `failFirst` executions, which throw the overload error.
function overloadedDb(failFirst) {
  const db = { execs: 0, failed: 0, sqls: [] };
  const exec = (sql) => {
    db.execs += 1;
    db.sqls.push(sql);
    if (db.failed < failFirst) { db.failed += 1; throw new Error(OVERLOAD); }
  };
  const stmt = (sql) => ({
    bind() { return stmt(sql); },
    async first() { exec(sql); return null; },
    async all() { exec(sql); return { results: [] }; },
    async run() { exec(sql); return { success: true, meta: { changes: 0 } }; },
    async raw() { exec(sql); return []; },
  });
  db.prepare = (sql) => stmt(sql);
  db.batch = async (stmts) => { exec("batch"); return stmts.map(() => ({ results: [] })); };
  return db;
}

const flagsReq = () => new Request("https://jobs.test/api/flags", { headers: { authorization: "Bearer test-secret" } });

test("E1: the real worker answers GET /api/flags 200 after two D1 overloads", async () => {
  const db = overloadedDb(2);
  const res = await worker.fetch(flagsReq(), { DB: db, HARNESS_SECRET: "test-secret" });
  assert.equal(res.status, 200);
  assert.equal(db.failed, 2);
  assert.equal(db.sqls.slice(0, 3).filter((s) => s === db.sqls[0]).length, 3,
    "the first statement ran 3 times: 2 overloads, then success");
});

test("E2: the real worker gives up after 5 attempts with d1Attempts=5 on the error", async () => {
  const db = overloadedDb(Infinity);
  await assert.rejects(
    () => worker.fetch(flagsReq(), { DB: db, HARNESS_SECRET: "test-secret" }),
    (e) => /D1 DB is overloaded/.test(e.message) && e.d1Attempts === 5,
  );
  assert.equal(db.execs, 5);
});

test("S1: beforeSend tags d1_attempts from the marked error", async () => {
  const { sentryOptions } = await sentryLib();
  const err = new Error(OVERLOAD + " S1");
  err.d1Attempts = 3;
  const ev = await sentryOptions({ HARNESS_SENTRY_MAX_PER_FP_HOUR: "100" }, "harness-jobs")
    .beforeSend({ exception: { values: [{ type: "Error", value: err.message }] } }, { originalException: err });
  assert.equal(ev.tags.d1_attempts, "3");
  assert.equal(ev.tags.lane, "harness-jobs");
});

test("S2: an unmarked error gets no d1_attempts tag", async () => {
  const { sentryOptions } = await sentryLib();
  const err = new Error("plain S2");
  const opts = sentryOptions({ HARNESS_SENTRY_MAX_PER_FP_HOUR: "100" }, "harness-jobs");
  const ev = await opts.beforeSend({ exception: { values: [{ type: "Error", value: err.message }] } }, { originalException: err });
  assert.equal("d1_attempts" in ev.tags, false);
  const ev2 = await opts.beforeSend({ message: "no hint S2" });
  assert.equal("d1_attempts" in ev2.tags, false);
});

class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}

async function settle(ctx) {
  for (let seen = -1; seen !== ctx.waits.length;) {
    seen = ctx.waits.length;
    await Promise.all(ctx.waits);
    await new Promise((r) => setTimeout(r, 5));
  }
}

test("S3: a give-up on the real worker sends exactly one event with d1_attempts=5", async (t) => {
  const real = globalThis.fetch;
  const posts = [];
  globalThis.fetch = async (url, init = {}) => {
    if (String(url).includes("sentry.test")) {
      const b = init.body;
      posts.push(typeof b === "string" ? b : new TextDecoder().decode(b));
    }
    return new Response("{}", { status: 200 });
  };
  t.after(() => { globalThis.fetch = real; });
  const db = overloadedDb(Infinity);
  // pause_flags is read through the same DB by the kill switch; that read
  // fails (overloaded), which is fail-open, so the event still sends.
  const ctx = new Ctx();
  await assert.rejects(
    () => worker.fetch(flagsReq(), { DB: db, HARNESS_SECRET: "test-secret", HARNESS_SENTRY_DSN: DSN }, ctx),
    /D1 DB is overloaded/,
  );
  await settle(ctx);
  assert.equal(posts.length, 1, "exactly one envelope reaches Sentry");
  assert.match(posts[0], /"d1_attempts":"5"/);
});
