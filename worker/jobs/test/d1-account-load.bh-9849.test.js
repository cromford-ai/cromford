// BH-9849 (Sentry CROMFORD-HARNESS-29): D1 rejected GET /api/routing/<p> with
// "D1_ERROR: Your account is generating too much load on D1 DBs". The overload
// matcher in lib/d1-retry.js knew only "D1 DB is overloaded", so withD1Retry
// threw after one call, withOverloadAnswer rethrew, and worker.fetch left an
// unhandled 500 (9 Sentry events in 24 h). isD1Overloaded now matches the
// account-load message too, so the existing retry, 503 answer and Sentry
// streak rule (BH-6690, BH-9190, BH-9249, BH-7541) apply to it.
//
//   M1-M9  the decision table of isD1Overloaded (plan, Failure modes).
//   R1-R2  the retry on the account-load message, knobs from settings rows.
//   G1-G2  the 503 answer through the real worker.fetch on GET and PUT.
//   E1     the route's one query uses the routing primary key at volume.
//   S1     GET /api/routing/<p> sends at most ROUTING_GET_STATEMENTS statements.
//
// Each case opens its own node:sqlite D1 and uses unique ids, so no case
// shares state with another. Sentry sends go to a stubbed globalThis.fetch:
// 0 network calls.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { isD1Overloaded, withD1Retry, retryingDb, D1_RETRY_ATTEMPTS } from "../src/lib/d1-retry.js";
import { isD1OverloadAnswer } from "../src/lib/d1-overload-answer.js";
import { settingsRows } from "../src/lib/settings-cache.js";
import { resetGiveUpStreaks } from "../src/lib/d1-giveup.js";
import { openDb, d1 } from "./lib/d1-sqlite.bh-1030.js";
import { plan, fullScans } from "./lib/d1-volume.bh-6727.js";

const LIVE = "D1_ERROR: Your account is generating too much load on D1 DBs. Please try again later.";
const BARE = "Your account is generating too much load on D1 DBs";
const SECRET = "test-secret-9849";
// The statement budget of GET /api/routing/<p>: a test bound, not a product
// limit (plan A7), like SETTINGS_FULL_READS_PER_BURST in d1-load.bh-9657.
const ROUTING_GET_STATEMENTS = 1;
const SQLITE = await openDb();

let seq = 0;
const uid = (tag) => `bh9849.${tag}.${process.pid}.${++seq}`;
const proj = (tag) => `bh9849-${tag}-${process.pid}-${++seq}`;

// ═══════════════════ M: the decision table ══════════════════════════════════
const MATCH = [
  ["M1", LIVE],
  ["M2", BARE],
  ["M3", `${BARE} [req abc123]`],
  ["M4", "D1_ERROR: D1 DB is overloaded. Requests queued for too long."],
];
const NO_MATCH = [
  ["M5", "your account is generating too much load on d1 dbs"],
  ["M6", "Your account is generating too much load"],
  ["M7", "D1_ERROR: no such table: routing"],
  ["M8", "D1_ERROR: Too many resources consumed within a 10 second window"],
];
for (const [id, msg] of MATCH) {
  test(`${id}: isD1Overloaded matches "${msg}"`, () => {
    assert.equal(isD1Overloaded(new Error(msg)), true);
  });
}
for (const [id, msg] of NO_MATCH) {
  test(`${id}: isD1Overloaded does not match "${msg}"`, () => {
    assert.equal(isD1Overloaded(new Error(msg)), false);
  });
}
test("M8: the resource-window error is answered but not retried (1 call)", async () => {
  const err = new Error(`D1_ERROR: Too many resources consumed within a 10 second window [${uid("m8")}]`);
  assert.equal(isD1OverloadAnswer(err), true);
  let calls = 0;
  await assert.rejects(withD1Retry(async () => { calls += 1; throw err; }, { sleep: async () => {} }), (e) => e === err);
  assert.equal(calls, 1);
});
test("M7: another D1 error rethrows after 1 call", async () => {
  const err = new Error("D1_ERROR: no such table: routing");
  let calls = 0;
  await assert.rejects(withD1Retry(async () => { calls += 1; throw err; }, { sleep: async () => {} }), (e) => e === err);
  assert.equal(calls, 1);
});
test("M9: a thrown string, null and { message: 42 } do not match", () => {
  for (const v of [BARE, LIVE, null, undefined, { message: 42 }, new Error()]) {
    assert.equal(isD1Overloaded(v), false, String(v));
  }
});

// ═══════════════════ R: the retry ═══════════════════════════════════════════
test("R1: the live message 2x then ok -> withD1Retry returns ok after 3 calls and 2 sleeps", async () => {
  let calls = 0;
  const sleeps = [];
  const out = await withD1Retry(async () => {
    calls += 1;
    if (calls <= 2) throw new Error(LIVE);
    return "ok";
  }, { sleep: async (ms) => { sleeps.push(ms); } });
  assert.equal(out, "ok");
  assert.equal(calls, 3);
  assert.equal(sleeps.length, 2);
});

// A binding whose every non-settings statement throws `msg`; counts calls.
async function accountLoaded(settings, msg = () => new Error(`${LIVE} [${uid("err")}]`)) {
  const { db } = await openDb();
  for (const [k, v] of Object.entries(settings || {})) {
    db.prepare("INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, '2026-11-20T00:00:00Z')").run(k, v);
  }
  const inner = d1(db);
  const st = { db, calls: 0, on: true };
  const passes = (sql) => /d1_overload_streaks/.test(sql) || /FROM settings/.test(sql);
  const throwing = () => {
    const s = { bind() { return s; } };
    for (const m of ["first", "all", "run", "raw"]) s[m] = async () => { st.calls += 1; throw msg(); };
    return s;
  };
  st.DB = {
    prepare: (sql) => (st.on && !passes(sql) ? throwing() : inner.prepare(sql)),
    batch: async (s) => { if (st.on) { st.calls += 1; throw msg(); } return inner.batch(s); },
  };
  return st;
}
const warm = (st) => settingsRows({ DB: retryingDb(st.DB), SETTINGS_CACHE_TTL_S: "60" });

async function waitsFor(random, settings) {
  const st = await accountLoaded(settings);
  if (settings) await warm(st);
  const waits = [];
  const realTimeout = globalThis.setTimeout;
  const realRandom = Math.random;
  globalThis.setTimeout = (fn, ms, ...a) => { waits.push(ms); return realTimeout(fn, 0, ...a); };
  Math.random = () => random;
  try {
    await assert.rejects(
      retryingDb(st.DB).prepare("SELECT * FROM routing WHERE project=?1").bind(proj("r2")).first(),
      (e) => isD1Overloaded(e) && typeof e.d1Attempts === "number",
    );
  } finally {
    globalThis.setTimeout = realTimeout;
    Math.random = realRandom;
  }
  return { calls: st.calls, waits };
}

test("R2: attempts=4, base_ms=40 from settings -> 4 calls, waits in the backoff bands, jittered; no snapshot -> fallback", { skip: !SQLITE }, async () => {
  const knobs = { "d1_retry.attempts": "4", "d1_retry.base_ms": "40" };
  const lo = await waitsFor(0.1, knobs);
  const hi = await waitsFor(0.9, knobs);
  for (const r of [lo, hi]) {
    assert.equal(r.calls, 4);
    assert.equal(r.waits.length, 3);
    for (const [i, [a, b]] of [[20, 40], [40, 80], [80, 160]].entries()) {
      assert.ok(r.waits[i] >= a && r.waits[i] <= b, `wait ${i} = ${r.waits[i]} in [${a}, ${b}]`);
    }
  }
  assert.notDeepEqual(lo.waits, hi.waits);
  const fb = await waitsFor(0.5, null);
  assert.equal(fb.calls, D1_RETRY_ATTEMPTS);
});

// ═══════════════════ G: the 503 answer through worker.fetch ═════════════════
function sentryStub(t) {
  resetGiveUpStreaks();
  const realFetch = globalThis.fetch;
  const realWarn = console.warn;
  globalThis.fetch = async () => new Response("{}", { status: 200 });
  console.warn = () => {};
  t.after(() => { globalThis.fetch = realFetch; console.warn = realWarn; });
}
const req = (path, init = {}) =>
  new Request(`https://jobs.test${path}`, { ...init, headers: { authorization: `Bearer ${SECRET}`, ...(init.headers || {}) } });
const KNOBS = { "d1_retry.attempts": "3", "d1_retry.base_ms": "10", "d1_overload.retry_after_s": "5" };
const streaks = (st) => st.db.prepare("SELECT * FROM d1_overload_streaks").all();

test("G1: GET /api/routing/<p> on the account-load rejection -> 503, retry-after 5, d1_attempts 3, one streak row", { skip: !SQLITE }, async (t) => {
  sentryStub(t);
  const st = await accountLoaded(KNOBS);
  await warm(st);
  const res = await worker.fetch(req(`/api/routing/${proj("g1")}`), { DB: st.DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 503);
  assert.equal(res.headers.get("retry-after"), "5");
  const body = await res.json();
  assert.equal(body.error, "D1 overloaded");
  assert.match(body.error, /overloaded/i);
  assert.equal(body.retryable, true);
  assert.equal(body.d1_attempts, 3);
  assert.match(body.route, /^GET \/api\/routing/);
  assert.equal(st.calls, 3);
  assert.equal(streaks(st).length, 1);
});

test("G2: PUT /api/routing on the account-load rejection -> 503 D1 unavailable, retryable false, no retry-after", { skip: !SQLITE }, async (t) => {
  sentryStub(t);
  const st = await accountLoaded(KNOBS);
  await warm(st);
  const res = await worker.fetch(req("/api/routing", {
    method: "PUT", headers: { "content-type": "application/json" },
    body: JSON.stringify({ project: proj("g2"), builder: "local" }),
  }), { DB: st.DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 503);
  assert.equal(res.headers.get("retry-after"), null);
  const body = await res.json();
  assert.equal(body.error, "D1 unavailable");
  assert.equal(body.retryable, false);
});

// ═══════════════════ E: the index ═══════════════════════════════════════════
test("E1: 1,000 routing rows -> SELECT * FROM routing WHERE project=?1 uses the primary key, no full scan", { skip: !SQLITE }, async () => {
  const { db } = await openDb();
  const ins = db.prepare("INSERT INTO routing (project, builder, updated_at) VALUES (?, 'local', '2026-11-20T00:00:00Z')");
  db.exec("BEGIN");
  for (let i = 0; i < 1000; i++) ins.run(`bh9849-p${i}-${process.pid}`);
  db.exec("COMMIT");
  db.exec("ANALYZE");
  const lines = plan(db, "SELECT * FROM routing WHERE project=?1", `bh9849-p7-${process.pid}`);
  assert.ok(lines.some((l) => /^SEARCH routing USING INDEX sqlite_autoindex_routing_1 \(project=\?\)/.test(l)), lines.join(" | "));
  assert.deepEqual(fullScans(lines, ["routing"]), []);
});

// ═══════════════════ S: the statement budget ════════════════════════════════
test("S1: GET /api/routing/<p> with a warm snapshot sends <= ROUTING_GET_STATEMENTS routing statements, 0 batches", { skip: !SQLITE }, async () => {
  const { db } = await openDb();
  const p = proj("s1");
  db.prepare("INSERT INTO routing (project, builder, updated_at) VALUES (?, 'local', '2026-11-20T00:00:00Z')").run(p);
  const inner = d1(db);
  const seen = [];
  let batches = 0;
  const DB = {
    prepare(sql) { seen.push(sql); return inner.prepare(sql); },
    batch(s) { batches += 1; return inner.batch(s); },
  };
  await settingsRows({ DB: retryingDb(DB), SETTINGS_CACHE_TTL_S: "60" });
  seen.length = 0;
  const res = await worker.fetch(req(`/api/routing/${p}`), { DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).routing.project, p);
  const routing = seen.filter((s) => /\brouting\b/.test(s));
  const other = seen.filter((s) => !/\brouting\b/.test(s) && !/FROM settings/.test(s));
  assert.ok(routing.length <= ROUTING_GET_STATEMENTS, `routing statements ${routing.length}: ${routing.join(" | ")}; other: ${other.join(" | ")}`);
  assert.equal(batches, 0);
});
