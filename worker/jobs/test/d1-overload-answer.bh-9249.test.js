// BH-9249 (Sentry CROMFORD-HARNESS-24): a D1 overload give-up on a route with
// no guard of its own (GET /api/jobs, and most other routes) left worker.fetch
// as an unhandled Error: a 500 with no body and one Sentry event per give-up.
// withOverloadAnswer (lib/d1-overload-answer.js) wraps the whole fetch, so any
// route answers 503 {error, retryable:true, d1_attempts, route} with a
// retry-after header (settings row d1_overload.retry_after_s), upserts one
// d1_overload_streaks row, and sends Sentry only on every Nth give-up, tagged
// d1_route and d1_op. Every other error is rethrown as the same object.
//
//   R1-R2  the retry on the ticket's message, knobs from settings rows.
//   A1-A5  the 503 answer through the real worker.fetch (A5: an open route).
//   W1-W2  a write method answers a 503 that req.sh does NOT re-send.
//   D1-D8  the decision table of isD1OverloadAnswer.
//   N1     a non-overload error still rejects, no streak row.
//   K1-K3  the retry-after knob.
//   S1     a success sends no extra statement.
//   U1     overloadRouteKey is bounded.
//
// Each case opens its own node:sqlite D1 (lib/d1-sqlite.bh-1030.js) and its
// own error suffix, so no case shares state with another. Sentry sends are
// counted through a stubbed globalThis.fetch, as in d1-overload-giveup.bh-7541.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import worker, { ROUTES } from "../src/index.js";
import * as answerLib from "../src/lib/d1-overload-answer.js";
import { retryingDb } from "../src/lib/d1-retry.js";
import { settingsRows } from "../src/lib/settings-cache.js";
import { resetGiveUpStreaks } from "../src/lib/d1-giveup.js";
import { matchRoute } from "../src/lib/router.js";
import { openDb, d1 } from "./lib/d1-sqlite.bh-1030.js";

// A namespace import, so the file loads on a tree without the module and each
// case fails on its own assertion.
const { withOverloadAnswer, isD1OverloadAnswer, overloadRouteKey, retryAfterS } = answerLib;

const TICKET = "D1_ERROR: D1 DB is overloaded. Too many resources consumed within a 10 second window";
const SECRET = "test-secret-9249";
const DSN = "https://fixturepubkey@sentry.test/49";
const SQLITE = await openDb();
const SCHEMA_D = fileURLToPath(new URL("../schema.d/", import.meta.url));

let cases = 0;

// A real sqlite D1. While ov.on is set, every statement that is not the
// streak upsert or a settings read throws ov.err() (the ticket message with a
// per-case suffix, so the Sentry SDK's dedupe never drops an event).
// ov.prepares counts every prepare the worker sends.
async function overloadable({ settings = {}, err } = {}) {
  const { db } = await openDb();
  db.exec(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
           VALUES ('job-9249','cromford','BH-9249','build','box-1','done','done','2026-11-08T00:00:00Z','2026-11-08T00:00:00Z')`);
  for (const [k, v] of Object.entries(settings)) {
    db.prepare("INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, '2026-11-08T00:00:00Z')").run(k, v);
  }
  const inner = d1(db);
  const tag = ++cases;
  const ov = { on: true, db, prepares: 0, tag };
  ov.err = err || (() => new Error(`${TICKET} [case ${tag}]`));
  const passes = (sql) => /d1_overload_streaks/.test(sql) || /FROM settings/.test(sql);
  const throwing = () => {
    const s = { bind() { return s; } };
    for (const m of ["first", "all", "run", "raw"]) s[m] = async () => { throw ov.err(); };
    return s;
  };
  ov.DB = {
    prepare(sql) {
      ov.prepares += 1;
      return ov.on && !passes(sql) ? throwing() : inner.prepare(sql);
    },
    batch: async (s) => { if (ov.on) throw ov.err(); return inner.batch(s); },
  };
  return ov;
}

// Load the settings snapshot the worker peeks at (retry knobs, retry-after),
// keyed on the same retryingDb proxy worker.fetch builds for this binding.
async function seedSnapshot(ov) {
  await settingsRows({ DB: retryingDb(ov.DB), SETTINGS_CACHE_TTL_S: "60" });
}

// attempts=1 keeps the give-up fast; a case that tests the knob sets its own.
async function fastOverload(extra = {}, opts = {}) {
  const ov = await overloadable({ settings: { "d1_retry.attempts": "1", ...extra }, ...opts });
  await seedSnapshot(ov);
  return ov;
}

const req = (path, init = {}) =>
  new Request(`https://jobs.test${path}`, { ...init, headers: { authorization: `Bearer ${SECRET}`, ...(init.headers || {}) } });
const envOf = (ov, extra = {}) => ({ DB: ov.DB, HARNESS_SECRET: SECRET, ...extra });
const streaks = (ov) => ov.db.prepare("SELECT * FROM d1_overload_streaks ORDER BY route").all();

function spies(t) {
  resetGiveUpStreaks();
  const realFetch = globalThis.fetch;
  const realWarn = console.warn;
  const s = { posts: [], warns: [] };
  globalThis.fetch = async (url, init = {}) => {
    if (String(url).includes("sentry.test")) {
      const b = init.body;
      const text = typeof b === "string" ? b : new TextDecoder().decode(b);
      if (/"d1_giveups"/.test(text)) s.posts.push(text);
    }
    return new Response("{}", { status: 200 });
  };
  console.warn = (...a) => { s.warns.push(a.join(" ")); };
  t.after(() => { globalThis.fetch = realFetch; console.warn = realWarn; });
  return s;
}

class Ctx {
  waitUntil(p) { Promise.resolve(p).catch(() => {}); }
  passThroughOnException() {}
}

// ═══════════════════ R: the retry on the ticket's message ═══════════════════
test("R1: ticket message 2x then a row; attempts=3, base_ms=10 from settings -> row after 3 calls, jittered waits", { skip: !SQLITE }, async () => {
  const ov = await overloadable({ settings: { "d1_retry.attempts": "3", "d1_retry.base_ms": "10" } });
  await seedSnapshot(ov);
  let calls = 0;
  // The statement under test: throws the ticket message twice, then a row.
  ov.DB.prepare = (sql) => {
    if (/FROM settings/.test(sql)) return d1(ov.db).prepare(sql);
    const s = { bind() { return s; }, async first() { calls += 1; if (calls <= 2) throw new Error(TICKET); return { id: "job-9249" }; } };
    return s;
  };
  const waits = [];
  const realTimeout = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms, ...a) => { waits.push(ms); return realTimeout(fn, 0, ...a); };
  let row;
  try {
    row = await retryingDb(ov.DB).prepare("SELECT id FROM jobs WHERE id=?1").bind("job-9249").first();
  } finally {
    globalThis.setTimeout = realTimeout;
  }
  assert.deepEqual(row, { id: "job-9249" });
  assert.equal(calls, 3);
  assert.equal(waits.length, 2);
  assert.ok(waits[0] >= 5 && waits[0] <= 10, `first wait ${waits[0]} in [5, 10]`);
  assert.ok(waits[1] >= 10 && waits[1] <= 20, `second wait ${waits[1]} in [10, 20]`);
});

test("R2: same fake, attempts=2 from settings -> rejects after 2 calls with d1Attempts=2", { skip: !SQLITE }, async () => {
  const ov = await overloadable({ settings: { "d1_retry.attempts": "2", "d1_retry.base_ms": "10" } });
  await seedSnapshot(ov);
  let calls = 0;
  ov.DB.prepare = (sql) => {
    if (/FROM settings/.test(sql)) return d1(ov.db).prepare(sql);
    const s = { bind() { return s; }, async first() { calls += 1; throw new Error(TICKET); } };
    return s;
  };
  await assert.rejects(
    retryingDb(ov.DB).prepare("SELECT id FROM jobs WHERE id=?1").bind("job-9249").first(),
    (e) => e.message === TICKET && e.d1Attempts === 2,
  );
  assert.equal(calls, 2);
});

// ═══════════════════ A: the 503 answer through worker.fetch ═════════════════
test("A1: GET /api/jobs, every statement overloaded -> worker.fetch resolves 503 with retry-after", { skip: !SQLITE }, async (t) => {
  spies(t);
  const ov = await fastOverload();
  const res = await worker.fetch(req("/api/jobs"), envOf(ov));
  assert.equal(res.status, 503);
  assert.equal(res.headers.get("retry-after"), "2");
  assert.match(res.headers.get("content-type") || "", /application\/json/);
});

test("A2: one give-up -> one d1_overload_streaks row for GET /api/jobs, consecutive 1, one warn line", { skip: !SQLITE }, async (t) => {
  const s = spies(t);
  const ov = await fastOverload();
  const res = await worker.fetch(req("/api/jobs?project=cromford"), envOf(ov));
  assert.equal(res.status, 503);
  const rows = streaks(ov);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].route, "GET /api/jobs");
  assert.equal(rows[0].consecutive, 1);
  const lines = s.warns.filter((w) => /^d1-overload: /.test(w));
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^d1-overload: GET \/api\/jobs answered 503 after 1 attempt\(s\), streak 1/);
});

test("A3: the body is the shape bin/lib/jobs/req.sh retries", { skip: !SQLITE }, async (t) => {
  spies(t);
  const ov = await fastOverload();
  const res = await worker.fetch(req("/api/jobs"), envOf(ov));
  const body = await res.json();
  assert.match(body.error, /overloaded/i);
  assert.equal(body.retryable, true);
  assert.equal(typeof body.d1_attempts, "number");
  assert.equal(body.d1_attempts, 1);
  assert.equal(body.route, "GET /api/jobs");
  assert.match(body.detail, /Too many resources consumed within a 10 second window/);
});

test("A4: 3 give-ups with Sentry on -> exactly 1 envelope, tagged d1_route, d1_giveups=3 and d1_op", { skip: !SQLITE }, async (t) => {
  const s = spies(t);
  const ov = await fastOverload();
  const env = envOf(ov, { HARNESS_SENTRY_DSN: DSN, HARNESS_SENTRY_MAX_PER_FP_HOUR: "1000" });
  for (let i = 0; i < 3; i++) {
    const res = await worker.fetch(req("/api/jobs"), env, new Ctx());
    assert.equal(res.status, 503);
  }
  await new Promise((r) => setTimeout(r, 300)); // the SDK transport flushes on its own
  assert.equal(s.posts.length, 1);
  const p = s.posts[0];
  assert.match(p, /"d1_route":"GET \/api\/jobs"/);
  assert.match(p, /"d1_giveups":"3"/);
  assert.match(p, /"d1_op":"[^"]+"/);
  assert.equal(streaks(ov)[0].consecutive, 3);
});

test("A5: an open route (GET /api/ci/suite-durations) that throws the overload answers 503 too", { skip: !SQLITE }, async (t) => {
  spies(t);
  const ov = await fastOverload();
  // Every open route guards its own D1 reads today, so the open-route case is
  // driven through the wrapper: it must not care whether the bearer ran.
  const h = withOverloadAnswer({ async fetch() { throw ov.err(); } });
  const res = await h.fetch(new Request("https://jobs.test/api/ci/suite-durations"), envOf(ov));
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.equal(body.route, "GET /api/ci/suite-durations");
  assert.equal(body.retryable, true);
  assert.equal(streaks(ov)[0].route, "GET /api/ci/suite-durations");
});

// req.sh re-sends a 503 whose body matches /overloaded/i, for any method
// (bin/lib/jobs/req.sh, the overload retry). A write route can give up after
// an earlier statement committed, so a write's 503 must not match.
const reqShRetries = (status, text) => status === 503 && /overloaded/i.test(text);

test("W1: POST /api/jobs on an overloaded D1 -> 503 that req.sh does not re-send, no retry-after, one streak row", { skip: !SQLITE }, async (t) => {
  spies(t);
  const ov = await fastOverload();
  const res = await worker.fetch(req("/api/jobs", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: "job-w1", project: "cromford", kind: "build" }),
  }), envOf(ov));
  const text = await res.text();
  assert.equal(res.status, 503);
  assert.equal(reqShRetries(res.status, text), false, text);
  assert.equal(res.headers.get("retry-after"), null);
  const body = JSON.parse(text);
  assert.equal(body.retryable, false);
  assert.equal(body.written, "unknown");
  assert.equal(body.route, "POST /api/jobs");
  assert.equal(streaks(ov)[0].route, "POST /api/jobs");
});

test("W2: PUT, PATCH and DELETE answer the non-retryable 503; GET and HEAD the retryable one", { skip: !SQLITE }, async (t) => {
  spies(t);
  for (const method of ["PUT", "PATCH", "DELETE", "POST", "GET", "HEAD"]) {
    const ov = await fastOverload();
    const h = withOverloadAnswer({ async fetch() { throw ov.err(); } });
    const res = await h.fetch(new Request("https://jobs.test/api/leases/x", { method }), envOf(ov));
    const text = await res.text();
    assert.equal(res.status, 503, method);
    const safe = method === "GET" || method === "HEAD";
    assert.equal(reqShRetries(res.status, text), safe, method);
  }
});

// ═══════════════════ D: the decision table ══════════════════════════════════
const ANSWER = [
  ["D1", TICKET],
  ["D2", "D1_ERROR: D1 DB is overloaded. Requests queued for too long."],
  ["D3", "D1_ERROR: D1 DB is overloaded. Too many requests queued."],
  ["D4", "D1_ERROR: Too many resources consumed within a 10 second window"],
];
const RETHROW = [
  ["D5", "DB is overloaded"],
  ["D5", "d1 db is overloaded"],
  ["D6", "D1_ERROR: no such table: jobs"],
  ["D6", 'D1_ERROR: near "SELEC": syntax error'],
  ["D7", "UNIQUE constraint failed: jobs.id"],
  ["D7", "GitHub API: Too many requests"],
];

for (const [id, msg] of ANSWER) {
  test(`${id}: isD1OverloadAnswer answers "${msg}"`, () => {
    assert.equal(isD1OverloadAnswer(new Error(msg)), true);
  });
}
for (const [id, msg] of RETHROW) {
  test(`${id}: isD1OverloadAnswer rethrows "${msg}"`, () => {
    assert.equal(isD1OverloadAnswer(new Error(msg)), false);
  });
}
test("D8: a thrown string, null, undefined and an Error with no message are not answered", () => {
  for (const v of [TICKET, null, undefined, new Error(), {}, { message: 42 }]) {
    assert.equal(isD1OverloadAnswer(v), false, String(v));
  }
});

test("D4 through worker.fetch: the prefixless resource-window message answers 503", { skip: !SQLITE }, async (t) => {
  spies(t);
  const tag = ++cases;
  const ov = await fastOverload({}, { err: () => new Error(`D1_ERROR: Too many resources consumed within a 10 second window [${tag}]`) });
  const res = await worker.fetch(req("/api/jobs"), envOf(ov));
  assert.equal(res.status, 503);
  assert.equal((await res.json()).retryable, true);
});

// ═══════════════════ N: every other error still throws ═════════════════════
for (const msg of ["D1_ERROR: no such table: jobs", "DB is overloaded"]) {
  test(`N1: GET /api/jobs with "${msg}" -> worker.fetch rejects with the same error, 0 streak rows`, { skip: !SQLITE }, async (t) => {
    spies(t);
    const err = new Error(msg);
    const ov = await fastOverload({}, { err: () => err });
    await assert.rejects(worker.fetch(req("/api/jobs"), envOf(ov)), (e) => e === err);
    assert.equal(streaks(ov).length, 0);
  });
}

// ═══════════════════ K: the retry-after knob ════════════════════════════════
test("K1: settings row d1_overload.retry_after_s = 3 -> retry-after: 3", { skip: !SQLITE }, async (t) => {
  spies(t);
  const ov = await fastOverload({ "d1_overload.retry_after_s": "3" });
  assert.equal(retryAfterS(ov.DB), 3);
  const res = await worker.fetch(req("/api/jobs"), envOf(ov));
  assert.equal(res.headers.get("retry-after"), "3");
});

test("K2: 0, 61, abc, 2.5 -> the fallback 2", { skip: !SQLITE }, async () => {
  for (const v of ["0", "61", "abc", "2.5", "-1"]) {
    const ov = await fastOverload({ "d1_overload.retry_after_s": v });
    assert.equal(retryAfterS(ov.DB), 2, v);
  }
  const edge = await fastOverload({ "d1_overload.retry_after_s": "60" });
  assert.equal(retryAfterS(edge.DB), 60);
});

test("K3: no snapshot -> 2, and no D1 read is made for it", { skip: !SQLITE }, async () => {
  const ov = await overloadable();
  const before = ov.prepares;
  assert.equal(retryAfterS(ov.DB), 2);
  assert.equal(ov.prepares, before);
});

test("K4: the schema.d seed carries d1_overload.retry_after_s = 2 (equal to the code fallback)", () => {
  const f = readdirSync(SCHEMA_D).find((n) => /-bh-9249-d1-overload-retry-after\.sql$/.test(n));
  assert.ok(f, "seed fragment present");
  const sql = readFileSync(SCHEMA_D + f, "utf8");
  assert.match(sql, /INSERT OR IGNORE INTO settings[^;]*'d1_overload\.retry_after_s','2'/);
  assert.equal(answerLib.D1_OVERLOAD_RETRY_AFTER_S, 2);
});

// ═══════════════════ S: success adds no statement ═══════════════════════════
test("S1: a successful GET /api/jobs sends the same statement count with and without the wrapper", { skip: !SQLITE }, async (t) => {
  spies(t);
  const a = await overloadable();
  a.on = false;
  const res = await worker.fetch(req("/api/jobs"), envOf(a));
  assert.equal(res.status, 200);
  const wrapped = a.prepares;

  const b = await overloadable();
  b.on = false;
  const url = new URL("https://jobs.test/api/jobs");
  const hit = matchRoute(ROUTES, "GET", url.pathname);
  const direct = await hit.handler({ req: req("/api/jobs"), env: { DB: retryingDb(b.DB) }, url, path: url.pathname, t: "2026-11-08T00:00:00Z", body: {}, m: hit.m });
  assert.equal(direct.status, 200);
  assert.ok(wrapped > 0);
  assert.equal(wrapped, b.prepares);
});

// ═══════════════════ U: the route key is bounded ════════════════════════════
test("U1: overloadRouteKey keeps 3 segments, masks ids and long segments, caps at 80", () => {
  assert.equal(overloadRouteKey("GET", "/api/jobs"), "GET /api/jobs");
  assert.equal(overloadRouteKey("GET", "/api/jobs/job-123/artifacts/x"), "GET /api/jobs/:id");
  assert.equal(overloadRouteKey("POST", "/api/" + "a".repeat(40) + "/b"), "POST /api/:id/b");
  assert.equal(overloadRouteKey("GET", "/"), "GET /");
  const long = overloadRouteKey("X".repeat(100), "/api/jobs");
  assert.ok(long.length <= 80);
});
