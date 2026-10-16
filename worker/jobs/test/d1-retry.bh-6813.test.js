// BH-6813: a D1 overload give-up (CROMFORD-HARNESS-19) came after at most
// 150 ms of sleep and named neither the build nor the query. The retry now
// makes at most 5 attempts at a 100 ms base (750..1500 ms of sleep in total),
// a give-up marks the error with d1Op ("<method> <VERB> <table>", never a
// literal), and lib/sentry.js tags it d1_op. Sentry sends are counted through
// a stubbed globalThis.fetch, as in d1-retry.bh-6690.test.js; the DSN is a
// fixture on a reserved TLD.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const lib = () => import("../src/lib/d1-retry.js");
const sentryLib = () => import("../src/lib/sentry.js");

const DSN = "https://fixturepubkey@sentry.test/43";
const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";

function clock(r) {
  const waits = [];
  return { waits, sleep: async (ms) => { waits.push(ms); }, random: () => r };
}

function seq(n, value = { ok: 1 }) {
  const f = async () => {
    f.calls += 1;
    if (f.calls <= n) throw new Error(OVERLOAD);
    return value;
  };
  f.calls = 0;
  return f;
}

test("R2: overload on every call — exactly 5 calls, the same error once, d1Attempts=5, total wait <= 1500 ms", async () => {
  const { withD1Retry } = await lib();
  const c = clock(1);
  const err = new Error(OVERLOAD);
  let calls = 0;
  const fn = async () => { calls += 1; throw err; };
  await assert.rejects(() => withD1Retry(fn, { sleep: c.sleep, random: c.random }), (e) => e === err);
  assert.equal(calls, 5);
  assert.equal(err.d1Attempts, 5);
  assert.equal(c.waits.length, 4);
  const total = c.waits.reduce((a, b) => a + b, 0);
  assert.ok(total <= 1500, `total wait ${total} <= 1500`);
  assert.equal(total, 1500, "random=1 gives the full wait d for each of the 4 waits");
});

test("R3: the waits grow, have jitter, and each is in [d/2, d] for d = 100, 200, 400, 800", async () => {
  const { withD1Retry } = await lib();
  const lo = clock(0);
  const hi = clock(1);
  await assert.rejects(withD1Retry(seq(Infinity), { sleep: lo.sleep, random: lo.random }));
  await assert.rejects(withD1Retry(seq(Infinity), { sleep: hi.sleep, random: hi.random }));
  for (const w of [lo.waits, hi.waits]) {
    assert.equal(w.length, 4);
    for (let i = 1; i < w.length; i++) assert.ok(w[i] > w[i - 1], `strictly growing: ${w}`);
  }
  assert.notDeepEqual(lo.waits, hi.waits, "random moves the wait (jitter)");
  [100, 200, 400, 800].forEach((d, i) => {
    for (const w of [lo.waits, hi.waits]) {
      assert.ok(w[i] >= d / 2 && w[i] <= d, `wait ${i + 1} in [${d / 2},${d}]: ${w[i]}`);
    }
  });
  assert.deepEqual(lo.waits, [50, 100, 200, 400]);
  assert.deepEqual(hi.waits, [100, 200, 400, 800]);
});

test("R4: four overloads then success resolves on the 5th call", async () => {
  const { withD1Retry } = await lib();
  const c = clock(0.5);
  const fn = seq(4);
  assert.deepEqual(await withD1Retry(fn, { sleep: c.sleep, random: c.random }), { ok: 1 });
  assert.equal(fn.calls, 5);
});

test("R5: withD1Retry with an op marks d1Op on give-up; with no op there is no mark", async () => {
  const { withD1Retry } = await lib();
  const c = clock(0);
  const e1 = new Error(OVERLOAD);
  await assert.rejects(withD1Retry(async () => { throw e1; }, { sleep: c.sleep, random: c.random, op: "run INSERT jobs" }));
  assert.equal(e1.d1Op, "run INSERT jobs");
  const e2 = new Error(OVERLOAD);
  await assert.rejects(withD1Retry(async () => { throw e2; }, { sleep: c.sleep, random: c.random }));
  assert.equal("d1Op" in e2, false);
  const e3 = new Error("D1_ERROR: no such table: x");
  await assert.rejects(withD1Retry(async () => { throw e3; }, { sleep: c.sleep, random: c.random, op: "run INSERT x" }));
  assert.equal("d1Op" in e3, false, "a non-overload error is not a give-up and gets no mark");
});

test("O1-O6: d1OpOf names the method, verb and table, never a literal, at most 80 chars", async () => {
  const { d1OpOf } = await lib();
  assert.equal(d1OpOf("first", "SELECT active FROM pause_flags WHERE name = ?1"), "first SELECT pause_flags");
  assert.equal(d1OpOf("run", "INSERT INTO jobs (id, kind) VALUES (?1, 'x')"), "run INSERT jobs");
  assert.equal(d1OpOf("run", "INSERT OR REPLACE INTO settings (k, v) VALUES (?1, ?2)"), "run INSERT settings");
  assert.equal(d1OpOf("run", "UPDATE stages SET state = 'done' WHERE id = ?1"), "run UPDATE stages");
  assert.equal(d1OpOf("run", "DELETE FROM leases WHERE until < ?1"), "run DELETE leases");
  assert.equal(d1OpOf("all", "  with x as (select id from runs) select * from x").split(" ")[1], "WITH");
  assert.equal(d1OpOf("exec", "CREATE TABLE IF NOT EXISTS t (a TEXT DEFAULT 'secret-literal')"), "exec CREATE t");
  assert.equal(d1OpOf("all", "PRAGMA table_info(pause_flags)"), "all PRAGMA pause_flags");
  assert.equal(d1OpOf("all", "-- lead\nSELECT 1"), "all SELECT -");
  const lit = d1OpOf("run", "UPDATE t SET v = 'secret-literal' WHERE k = 'FROM evil'");
  assert.equal(lit, "run UPDATE t");
  assert.equal(lit.includes("secret-literal") || lit.includes("evil"), false);
  assert.equal(d1OpOf("run", "SELECT * FROM 'secret_literal'"), "run SELECT -", "a quoted string is never a table");
  assert.equal(d1OpOf("all", "SELECT 'it''s FROM evil' AS a FROM real_t"), "all SELECT real_t",
    "a keyword inside a literal never picks the table");
  assert.equal(d1OpOf("first", ""), "first - -");
  assert.equal(d1OpOf("first", undefined), "first - -");
  assert.equal(d1OpOf("first", 42), "first - -");
  const long = d1OpOf("batch(9)", `SELECT x FROM ${"t".repeat(200)}`);
  assert.ok(long.length <= 80, `capped: ${long.length}`);
  assert.ok(long.startsWith("batch(9) SELECT t"));
});

// A fake D1 binding whose statement methods, batch and exec always overload.
function alwaysOverloaded() {
  const db = { calls: 0 };
  const fail = async () => { db.calls += 1; throw new Error(OVERLOAD); };
  const stmt = () => ({ bind() { return stmt(); }, first: fail, all: fail, run: fail, raw: fail });
  db.prepare = () => stmt();
  db.batch = fail;
  db.exec = fail;
  return db;
}

test("W1: retryingDb marks d1Op from prepare(sql) through bind, for batch, and for exec", async () => {
  const { retryingDb } = await lib();
  const db = alwaysOverloaded();
  const p = retryingDb(db);
  await assert.rejects(p.prepare("INSERT INTO jobs (id) VALUES (?1)").bind("j1").run(),
    (e) => e.d1Op === "run INSERT jobs" && e.d1Attempts === 5);
  await assert.rejects(p.batch([p.prepare("UPDATE stages SET s = ?1"), p.prepare("DELETE FROM jobs")]),
    (e) => e.d1Op === "batch(2) UPDATE stages");
  await assert.rejects(p.exec("CREATE TABLE IF NOT EXISTS t (a TEXT)"), (e) => e.d1Op === "exec CREATE t");
  assert.equal(db.calls, 15);
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

// A DB for the real worker: every statement answers empty, except the first
// `failFirst` executions, which overload.
function overloadedDb(failFirst) {
  const db = { execs: 0, failed: 0 };
  const exec = () => {
    db.execs += 1;
    if (db.failed < failFirst) { db.failed += 1; throw new Error(OVERLOAD); }
  };
  const stmt = () => ({
    bind() { return stmt(); },
    async first() { exec(); return null; },
    async all() { exec(); return { results: [] }; },
    async run() { exec(); return { success: true, meta: { changes: 0 } }; },
    async raw() { exec(); return []; },
  });
  db.prepare = () => stmt();
  db.batch = async (stmts) => { exec(); return stmts.map(() => ({ results: [] })); };
  return db;
}

function stubSentry(t) {
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
  return posts;
}

const flagsReq = () => new Request("https://jobs.test/api/flags", { headers: { authorization: "Bearer test-secret" } });

test("R1: the real worker answers GET /api/flags 200 after two overloads, and sends no Sentry event", async (t) => {
  const posts = stubSentry(t);
  const db = overloadedDb(2);
  const ctx = new Ctx();
  const res = await worker.fetch(flagsReq(), { DB: db, HARNESS_SECRET: "test-secret", HARNESS_SENTRY_DSN: DSN }, ctx);
  assert.equal(res.status, 200);
  assert.equal(db.failed, 2);
  await settle(ctx);
  assert.equal(posts.length, 0);
});

// The first query GET /api/flags runs is ensureColumns' read of pause_flags
// (lib/core.js), `all` on "PRAGMA table_info(pause_flags)". A fresh fake DB
// is a cold ensureColumns cache, so it is always the first. harness_sha comes
// from the env of the live invocation, which is what the deploy's --var sets.
test("S1: a give-up on the real worker sends one event with d1_attempts=5, d1_op and harness_sha", async (t) => {
  const posts = stubSentry(t);
  const db = overloadedDb(Infinity);
  const ctx = new Ctx();
  const env = { DB: db, HARNESS_SECRET: "test-secret", HARNESS_SENTRY_DSN: DSN, HARNESS_SHA: "abc123" };
  await assert.rejects(
    () => worker.fetch(flagsReq(), env, ctx),
    (e) => /D1 DB is overloaded/.test(e.message) && e.d1Attempts === 5 && e.d1Op === "all PRAGMA pause_flags",
  );
  await settle(ctx);
  // 5 attempts of the first statement, + 1: the kill switch reads pause_flags
  // once on the RAW binding (no retry), that read overloads too, and it fails open.
  assert.equal(db.execs, 6);
  assert.equal(posts.length, 1, "exactly one envelope reaches Sentry");
  assert.match(posts[0], /"d1_attempts":"5"/);
  assert.match(posts[0], /"d1_op":"all PRAGMA pause_flags"/);
  assert.match(posts[0], /"harness_sha":"abc123"/);
});

test("S2: beforeSend tags harness_sha from env, and d1_op only from a string mark", async () => {
  const { sentryOptions } = await sentryLib();
  const ev = (msg) => ({ exception: { values: [{ type: "Error", value: msg }] } });
  const shaOpts = sentryOptions({ HARNESS_SHA: "abc123", HARNESS_SENTRY_MAX_PER_FP_HOUR: "100" }, "harness-jobs");
  const s = await shaOpts.beforeSend({ message: "S2 sha" });
  assert.equal(s.tags.harness_sha, "abc123");
  const opts = sentryOptions({ HARNESS_SENTRY_MAX_PER_FP_HOUR: "100" }, "harness-jobs");
  const marked = new Error("S2 marked");
  marked.d1Op = "run INSERT jobs";
  const a = await opts.beforeSend(ev(marked.message), { originalException: marked });
  assert.equal(a.tags.d1_op, "run INSERT jobs");
  const odd = new Error("S2 odd");
  odd.d1Op = { sql: "x" };
  const b = await opts.beforeSend(ev(odd.message), { originalException: odd });
  assert.equal("d1_op" in b.tags, false);
  const c = await opts.beforeSend({ message: "S2 no hint" });
  assert.equal("d1_op" in c.tags, false);
});
