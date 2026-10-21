// BH-7819: the LEGACY (non-ported) branch of PUT and DELETE /api/flags answers
// a D1 overload give-up with a 503, not an uncaught throw. Sentry
// CROMFORD-HARNESS-Y: putLegacy threw "D1_ERROR: D1 DB is overloaded. Requests
// queued for too long." after withD1Retry gave up (5 attempts, BH-6690 and
// BH-6813), so the box got a 500 and Sentry got an event. BH-6805 had guarded
// only the ported branch. Now the legacy branch answers the same 503
// "pause_flags unavailable" that bin/lib/jobs/req.sh retries once, with one warn
// line, and a read-back overload after a committed batch is a 200
// written:true, so the box never re-sends a write that landed.
// Every other error still rejects, so withSentry still sees a real bug.
//
// Every case drives the real worker.fetch, opens its own DB and uses its own
// flag name: no shared data, no order dependence.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { D1_RETRY_ATTEMPTS } from "../src/lib/d1-retry.js";
import { openDb } from "./lib/d1-sqlite.bh-1030.js";

const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";
const OVERLOAD_2 = "D1 DB is overloaded. Too many requests queued.";
const SECRET = "secret-fixture-bh7819";

// L8: no case in this file may reach the network (no vendor, no real D1).
const fetchCalls = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (...a) => { fetchCalls.push(String(a[0])); throw new Error("network call in a PR-path test"); };
after(() => {
  globalThis.fetch = realFetch;
  assert.deepEqual(fetchCalls, [], "L8: 0 network calls in this file");
});

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

// The failingDb shape of flags-overload.bh-6805: every statement answers
// empty, except the first `failFirst` executions, which throw `msg`.
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

// The node:sqlite shim (real schema.sql, real SQL) behind a counting wrapper.
// `batchFails` = how many batch calls throw the overload before one runs;
// `readBackFails` = the `SELECT * FROM pause_flags` read-back always throws it.
async function sqliteDb(t, { batchFails = 0, readBackFails = false } = {}) {
  const opened = await openDb();
  if (!opened) { t.skip("node:sqlite not available"); return null; }
  const inner = opened.DB;
  const c = { batches: 0, batchStmts: 0, runsOutside: 0 };
  const DB = {
    prepare(sql) {
      const s = inner.prepare(sql);
      const w = {
        _isRead: s._isRead,
        _inner: s,
        bind(...v) { s.bind(...v); return w; },
        async first(col) {
          if (readBackFails && /^\s*SELECT \* FROM pause_flags WHERE name=\?1\s*$/.test(sql)) throw new Error(OVERLOAD);
          return s.first(col);
        },
        async all() { return s.all(); },
        async run() { c.runsOutside += 1; return s.run(); },
      };
      return w;
    },
    async batch(stmts) {
      c.batches += 1;
      if (c.batches <= batchFails) throw new Error(OVERLOAD);
      c.batchStmts += stmts.length;
      return inner.batch(stmts.map((s) => s._inner));
    },
  };
  return { ...opened, DB, c };
}

const flagRows = (db, name) => db.prepare("SELECT * FROM pause_flags WHERE name=?").all(name);
const auditRows = (db, name) => db.prepare("SELECT * FROM config_changes WHERE kind='flag' AND name=?").all(name);

const req = (method, path, body) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const call = (db, method, path, body) => worker.fetch(req(method, path, body), { DB: db, HARNESS_SECRET: SECRET });

async function assert503(out, err) {
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 503);
  const body = await out.json();
  assert.equal(body.error, "pause_flags unavailable");
  assert.match(body.detail, /overloaded/i, "the body carries the word req.sh retries on");
  assert.equal(body.retryable, true);
  assert.equal(body.d1_attempts, D1_RETRY_ATTEMPTS);
  return body;
}

test("L1: two overloads then an answer: the legacy PUT retry wins, 200, no warn line", async () => {
  const db = failingDb(2);
  const { lines, out, err } = await warns(() => call(db, "PUT", "/api/flags", { name: "wip-limit-l1", active: 1 }));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 200);
  assert.equal(db.failed, 2, "the retry won through the legacy route");
  assert.equal(lines.length, 0);
});

for (const [id, msg] of [["L2", OVERLOAD], ["L2b", OVERLOAD_2]]) {
  test(`${id}: legacy PUT on an always-overloaded D1 is a 503 pause_flags unavailable, one warn line`, async () => {
    const name = `wip-limit-${id.toLowerCase()}`;
    const db = failingDb(Infinity, msg);
    const { lines, out, err } = await warns(() => call(db, "PUT", "/api/flags", { name, active: 1 }));
    await assert503(out, err);
    assert.equal(db.batches, 0, "nothing written");
    assert.equal(db.execs, D1_RETRY_ATTEMPTS, "the first statement ran 5 times, then the guard answered once");
    assert.equal(lines.length, 1);
    assert.match(lines[0], new RegExp(`pause_flags PUT ${name}`));
    assert.match(lines[0], new RegExp(`after ${D1_RETRY_ATTEMPTS} attempt\\(s\\)`));
  });
}

test("L3: legacy DELETE on an always-overloaded D1 is a 503, not a 404, not a reject", async () => {
  const db = failingDb(Infinity);
  const { lines, out, err } = await warns(() => call(db, "DELETE", "/api/flags?name=wip-limit-l3"));
  assert.notEqual(out && out.status, 404);
  await assert503(out, err);
  assert.equal(db.batches, 0);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /pause_flags DELETE wip-limit-l3/);
});

test("L3b: legacy DELETE of a name with no row is still a 404", async () => {
  const db = failingDb(0);
  const { out, err } = await warns(() => call(db, "DELETE", "/api/flags?name=wip-limit-l3b"));
  assert.equal(err, undefined);
  assert.equal(out.status, 404);
});

test("L4: a batch that gives up writes nothing; the re-send writes once; a third send adds no audit row", async (t) => {
  const s = await sqliteDb(t, { batchFails: D1_RETRY_ATTEMPTS });
  if (!s) return;
  const name = "wip-limit-l4";
  const put = () => warns(() => call(s.DB, "PUT", "/api/flags", { name, active: 1, actor: "l4" }));
  const first = await put();
  await assert503(first.out, first.err);
  assert.equal(flagRows(s.db, name).length, 0);
  assert.equal(auditRows(s.db, name).length, 0);
  const second = await put();
  assert.equal(second.err, undefined);
  assert.equal(second.out.status, 200);
  assert.equal(flagRows(s.db, name).length, 1);
  assert.equal(auditRows(s.db, name).length, 1);
  const third = await put();
  assert.equal(third.out.status, 200);
  assert.equal(flagRows(s.db, name).length, 1);
  assert.equal(auditRows(s.db, name).length, 1, "a same-value write is not a decision (BH-2377)");
});

test("L5: the batch commits, the read-back overloads: 200 written:true, the row and one audit row exist", async (t) => {
  const s = await sqliteDb(t, { readBackFails: true });
  if (!s) return;
  const name = "wip-limit-l5";
  const { lines, out, err } = await warns(() => call(s.DB, "PUT", "/api/flags", { name, active: 1 }));
  assert.equal(err, undefined, `worker.fetch must not throw: ${err && err.message}`);
  assert.equal(out.status, 200, "a committed write is not a retryable 503");
  const body = await out.json();
  assert.equal(body.written, true);
  assert.equal(body.flag, null);
  assert.equal("retryable" in body, false);
  assert.equal(s.c.batches, 1, "the write landed once");
  assert.equal(flagRows(s.db, name).length, 1);
  assert.equal(auditRows(s.db, name).length, 1);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /read-back wip-limit-l5/);
  assert.match(lines[0], /written:true/);
});

test("L6: one new-row legacy PUT sends exactly 1 batch of 2 statements and no write outside it", async (t) => {
  const s = await sqliteDb(t);
  if (!s) return;
  // Warm the per-binding ensureColumns/ensureTable caches, then count.
  assert.equal((await call(s.DB, "PUT", "/api/flags", { name: "wip-limit-l6-warm", active: 1 })).status, 200);
  Object.assign(s.c, { batches: 0, batchStmts: 0, runsOutside: 0 });
  const out = await call(s.DB, "PUT", "/api/flags", { name: "wip-limit-l6", active: 1 });
  assert.equal(out.status, 200);
  assert.equal(s.c.batches, 1);
  assert.equal(s.c.batchStmts, 2, "the upsert and its audit row");
  assert.equal(s.c.runsOutside, 0);
});

for (const msg of ["no such table: pause_flags", "SQLITE_ERROR: syntax error", "D1 DB is not overloaded"]) {
  test(`L7: a non-overload error (${msg}) on a legacy PUT still rejects, never a 503`, async () => {
    const db = failingDb(Infinity, msg);
    const { lines, out, err } = await warns(() => call(db, "PUT", "/api/flags", { name: "wip-limit-l7", active: 1 }));
    assert.equal(out, undefined, `no answer for a real error, got ${out && out.status}`);
    assert.ok(err instanceof Error);
    assert.equal(err.message, msg);
    assert.equal(db.execs, 1, "no retry for a non-overload error");
    assert.equal(lines.length, 0);
  });
}
