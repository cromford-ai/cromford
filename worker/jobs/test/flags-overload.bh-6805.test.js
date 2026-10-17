// BH-6805: the ported-flag routes answer a D1 overload with a 503, not an
// uncaught throw. withD1Retry (BH-6690) still gives up after D1_RETRY_ATTEMPTS
// attempts (5 since BH-6813) and
// rethrows; GET /api/flags/<name>, PUT /api/flags and DELETE /api/flags (the
// ported branch) now turn that give-up into "harness_flags unavailable" 503.
// Never a 404: the box caches a 404 as "off" (bin/lib/jobs/flags.sh
// flag_fetch), and a 503 whose body says "overloaded" is the answer
// bin/lib/jobs/req.sh retries once. Every other error still reaches withSentry.
// The exception: a read-back after a committed write answers 200 written:true
// (R7-R9), so req.sh never re-sends a write that landed.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { D1_RETRY_ATTEMPTS } from "../src/lib/d1-retry.js";

// Loaded per test, so the route cases run (and fail) against a tree without
// the guard, instead of the whole file failing to import.
const http = () => import("../src/lib/http.js");

const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";
const OVERLOAD_2 = "D1 DB is overloaded. Too many requests queued.";
const SECRET = "test-secret";

// Records console.warn lines for the length of fn, then restores it.
async function warns(fn) {
  const lines = [];
  const orig = console.warn;
  console.warn = (...a) => { lines.push(a.join(" ")); };
  try {
    return { lines, out: await fn() };
  } catch (e) {
    return { lines, err: e };
  } finally {
    console.warn = orig;
  }
}

// A DB for the real worker (the overloadedDb shape of d1-retry.bh-6690): every
// statement on any SQL answers empty, except the first `failFirst` executions,
// which throw `msg`.
function failingDb(failFirst, msg = OVERLOAD) {
  const db = { execs: 0, failed: 0, sqls: [], batches: 0 };
  const exec = (sql) => {
    db.execs += 1;
    db.sqls.push(sql);
    if (db.failed < failFirst) { db.failed += 1; throw new Error(msg); }
  };
  const stmt = (sql) => ({
    bind() { return stmt(sql); },
    async first() { exec(sql); return null; },
    async all() { exec(sql); return { results: [] }; },
    async run() { exec(sql); return { success: true, meta: { changes: 0 } }; },
    async raw() { exec(sql); return []; },
  });
  db.prepare = (sql) => stmt(sql);
  db.batch = async (stmts) => { db.batches += 1; exec("batch"); return stmts.map(() => ({ results: [] })); };
  return db;
}

const req = (method, path, body) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const call = (db, method, path, body) => worker.fetch(req(method, path, body), { DB: db, HARNESS_SECRET: SECRET });

// ── the guard ────────────────────────────────────────────────────────────

test("G1: an overload after retries is a 503 harness_flags unavailable, d1_attempts, one warn line", async () => {
  const { d1OverloadGuarded } = await http();
  const err = new Error(OVERLOAD);
  err.d1Attempts = 3;
  const { lines, out, err: thrown } = await warns(() => d1OverloadGuarded("harness_flags", async () => { throw err; }));
  assert.equal(thrown, undefined, "the guard does not throw on an overload");
  assert.ok(out instanceof Response);
  assert.equal(out.status, 503);
  const body = await out.json();
  assert.equal(body.error, "harness_flags unavailable");
  assert.match(body.detail, /overloaded/i);
  assert.equal(body.retryable, true, "same 503 body as the BH-6807 verdict give-up");
  assert.equal(body.d1_attempts, 3);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /harness_flags/);
  assert.match(lines[0], /3 attempt/);
});

test("G1b: the second wire message is an overload too", async () => {
  const { d1OverloadGuarded } = await http();
  const { out } = await warns(() => d1OverloadGuarded("harness_flags", async () => { throw new Error(OVERLOAD_2); }));
  assert.equal(out.status, 503);
  assert.equal((await out.json()).d1_attempts, null);
});

test("G1c: a success passes through untouched, no warn line", async () => {
  const { d1OverloadGuarded, json } = await http();
  const r = json(200, { ok: 1 });
  const { lines, out } = await warns(() => d1OverloadGuarded("harness_flags", async () => r));
  assert.equal(out, r);
  assert.equal(lines.length, 0);
});

for (const [id, label, make] of [
  ["G2", "a SQL error", () => new Error("D1_ERROR: no such column: x")],
  ["G2b", "database is locked", () => new Error("D1_ERROR: database is locked")],
  ["G2c", "a thrown {} with no message", () => ({})],
  ["G2d", "a TypeError", () => new TypeError("x is not a function")],
]) {
  test(`${id}: ${label} is rethrown, the same object, no 503, no warn line`, async () => {
    const { d1OverloadGuarded } = await http();
    const err = make();
    const { lines, out, err: thrown } = await warns(() => d1OverloadGuarded("harness_flags", async () => { throw err; }));
    assert.equal(out, undefined, "no Response for a non-overload error");
    assert.equal(thrown, err);
    assert.equal(lines.length, 0);
  });
}

// ── the routes, through the real worker.fetch ────────────────────────────

test("R1 + W1: GET /api/flags/paused-x on an overloaded D1 is a 503, never a 404, one warn line", async () => {
  const db = failingDb(Infinity);
  const { lines, out, err } = await warns(() => call(db, "GET", "/api/flags/paused-x"));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.notEqual(out.status, 404);
  assert.equal(out.status, 503);
  const text = await out.text();
  assert.match(text, /overloaded/i, "the body carries the word req.sh retries on");
  assert.equal(JSON.parse(text).error, "harness_flags unavailable");
  assert.equal(db.sqls.filter((s) => /INSERT/i.test(s)).length, 0, "no write after the failed read");
  assert.equal(lines.length, 1);
  assert.match(lines[0], /harness_flags/);
  assert.match(lines[0], /GET paused-x/);
});

test("R2: PUT /api/flags (ported, expected_set_at) on an overloaded D1 is a 503, not a 409, no batch", async () => {
  const db = failingDb(Infinity);
  const { out, err } = await warns(() => call(db, "PUT", "/api/flags", { name: "paused-x", active: 1, expected_set_at: "" }));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 503);
  assert.match(await out.text(), /overloaded/i);
  assert.equal(db.batches, 0);
});

test("R2b: PUT /api/flags overload in the write batch (writePorted) is a 503 too", async () => {
  // Every statement answers; only the upsert batch overloads.
  const db = failingDb(0);
  db.batch = async () => { db.batches += 1; throw new Error(OVERLOAD); };
  const { out, err } = await warns(() => call(db, "PUT", "/api/flags", { name: "paused-x", active: 1 }));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 503);
  assert.equal(db.batches, D1_RETRY_ATTEMPTS, `the batch ran ${D1_RETRY_ATTEMPTS} times (BH-6690/BH-6813 retry), then the guard answered`);
});

test("R3: DELETE /api/flags?name=paused-x on an overloaded D1 is a 503, not a 404", async () => {
  const db = failingDb(Infinity);
  const { out, err } = await warns(() => call(db, "DELETE", "/api/flags?name=paused-x"));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.notEqual(out.status, 404);
  assert.equal(out.status, 503);
  assert.match(await out.text(), /overloaded/i);
});

test("R4: two overloads then an answer: the retry wins, the normal 404 for no row, no warn line", async () => {
  const db = failingDb(2);
  const { lines, out, err } = await warns(() => call(db, "GET", "/api/flags/paused-x"));
  assert.equal(err, undefined);
  assert.equal(out.status, 404);
  assert.equal(db.failed, 2);
  assert.equal(lines.length, 0);
});

test("R5: a non-overload error on GET /api/flags/paused-x still rejects (Sentry sees real bugs)", async () => {
  const db = failingDb(Infinity, "D1_ERROR: no such column: x");
  await assert.rejects(() => call(db, "GET", "/api/flags/paused-x"), /no such column/);
  assert.equal(db.execs, 1, "no retry, no guard: one call");
});

test("R6: a non-ported name (wip-limit-x) is untouched: the overload still rejects", async () => {
  const db = failingDb(Infinity);
  await assert.rejects(() => call(db, "GET", "/api/flags/wip-limit-x"), /D1 DB is overloaded/);
});

// ── a committed write whose read-back overloads ──────────────────────────
// The upsert batch has landed. A 503 "overloaded" here would make req.sh
// re-send the write (a second audit row, or a false 409 "flag moved"), so the
// answer is a 200 that says the write landed and has no row to show.

// Every statement answers (`first()` gives `row` for a harness_flags select,
// else null) until the first batch() succeeds; after that every statement
// throws `after`.
function afterBatchDb({ row = null, after = OVERLOAD } = {}) {
  const db = { batches: 0, committed: false, sqls: [] };
  const exec = (sql) => {
    db.sqls.push(sql);
    if (db.committed) throw new Error(after);
  };
  const stmt = (sql) => ({
    bind() { return stmt(sql); },
    async first() { exec(sql); return /FROM harness_flags/i.test(sql) ? row : null; },
    async all() { exec(sql); return { results: [] }; },
    async run() { exec(sql); return { success: true, meta: { changes: 0 } }; },
    async raw() { exec(sql); return []; },
  });
  db.prepare = (sql) => stmt(sql);
  db.batch = async (stmts) => {
    exec("batch");
    db.batches += 1;
    db.committed = true;
    return stmts.map(() => ({ results: [] }));
  };
  return db;
}

async function assertWrittenNoRetry(out, db, err, label) {
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 200, `${label}: a committed write is not a retryable 503`);
  const text = await out.text();
  assert.doesNotMatch(text, /overloaded/i, "no word req.sh re-sends on");
  const body = JSON.parse(text);
  assert.equal(body.written, true);
  assert.equal(body.flag, null);
  assert.equal("retryable" in body, false);
  assert.equal(db.batches, 1, "one batch: the write landed once");
}

test("R7: PUT (no expected_set_at): batch commits, read-back overloads: 200 written:true, one warn line", async () => {
  const db = afterBatchDb();
  const { lines, out, err } = await warns(() => call(db, "PUT", "/api/flags", { name: "paused-x", active: 1 }));
  await assertWrittenNoRetry(out, db, err, "R7");
  assert.equal(lines.length, 1);
  assert.match(lines[0], /read-back paused-x/);
  assert.doesNotMatch(lines[0], /overloaded/i);
});

test("R7b: PUT with expected_set_at: batch commits, read-back overloads: 200 written:true", async () => {
  const db = afterBatchDb();
  const { out, err } = await warns(() => call(db, "PUT", "/api/flags", { name: "paused-x", active: 1, expected_set_at: "" }));
  await assertWrittenNoRetry(out, db, err, "R7b");
});

test("R8: DELETE: soft-clear commits, read-back overloads: 200 written:true", async () => {
  const db = afterBatchDb({
    row: { scope: "fleet", name: "paused-x", value: null, set_by: "operator", reason: "r", set_at: "2026-10-16T00:00:00Z", cleared_at: null },
  });
  const { out, err } = await warns(() => call(db, "DELETE", "/api/flags?name=paused-x"));
  await assertWrittenNoRetry(out, db, err, "R8");
});

test("R9: a non-overload error on the read-back after the batch still rejects (Sentry sees it)", async () => {
  const db = afterBatchDb({ after: "D1_ERROR: no such column: x" });
  await assert.rejects(() => call(db, "PUT", "/api/flags", { name: "paused-x", active: 1 }), /no such column/);
  assert.equal(db.batches, 1);
});
