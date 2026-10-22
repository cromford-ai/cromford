// BH-7541: a single D1 overload give-up on a verdict route sends no Sentry
// event. The route still answers 503 retryable (BH-6807) and writes one warn
// line, and it upserts ONE row of d1_overload_streaks. Only every Nth
// consecutive give-up on a route (N = HARNESS_D1_GIVEUP_REPORT_AFTER, default
// 3) sends one Sentry event, tagged d1_giveups and d1_route next to lane,
// d1_attempts and d1_op. Sentry issue CROMFORD-HARNESS-1G opened on single
// give-ups that bin/lib/jobs/req.sh had already retried.
//
// The routes run through the real worker.fetch on the node:sqlite D1 of
// lib/d1-sqlite.bh-1030.js, so the upsert is the real SQL. The prLedgerJob
// read throws the D1 overload message while `ov.on` is set. Sentry sends are
// counted through a stubbed globalThis.fetch, as in verdict-overload.bh-6807.
//
// The SDK keeps one client per isolate, and its dedupe integration drops an
// event equal to the previous one (same message and stack) before beforeSend
// runs. So every case, and every phase of a case that expects a second event,
// throws the overload message with its own suffix (ov.tag). The spy counts
// only give-up envelopes (the ones that carry the d1_giveups tag).
//
// Give-ups in one case run concurrently: each one sleeps 750..1500 ms in
// withD1Retry, and the upsert is one atomic statement, so N concurrent
// give-ups still number 1..N.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { prLedgerJob } from "../src/routes/verdict.js";
import { withD1Retry, D1_RETRY_ATTEMPTS } from "../src/lib/d1-retry.js";
import { recordGiveUp, resetGiveUpStreaks, GIVEUP_UPSERT_SQL } from "../src/lib/d1-giveup.js";
import { openDb, d1 } from "./lib/d1-sqlite.bh-1030.js";
import { openVolumeDb, plan } from "./lib/d1-volume.bh-6727.js";

const DSN = "https://fixturepubkey@sentry.test/44";
const OVERLOAD = "D1_ERROR: D1 DB is overloaded. Requests queued for too long.";
const PR = "https://github.com/example-org/cromford/pull/7541";
const V = "GET /api/verdict";
const H = "GET /api/verdict/history";
const SQLITE = await openDb();

const isLedger = (sql) => /artifact_kind='pr_url'/.test(sql) && /LIMIT 1/.test(sql) && /LEFT JOIN jobs/.test(sql);

// A real sqlite D1 with one build job and its pr_url artifact. While ov.on is
// set, the prLedgerJob artifact read throws the overload message.
let cases = 0;
async function overloadable() {
  const { db } = await openDb();
  db.exec(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
           VALUES ('build-7541','cromford','BH-7541','build','box-1','done','done','2026-10-19T00:00:00Z','2026-10-19T00:00:00Z')`);
  db.exec(`INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, created_at, updated_at)
           VALUES ('build-7541','pr_url','${PR}','2026-10-19T00:00:00Z','2026-10-19T00:00:00Z')`);
  const inner = d1(db);
  const ov = { on: true, db, tag: ++cases, next() { ov.tag = ++cases; } };
  const overload = () => new Error(`${OVERLOAD} [case ${ov.tag}]`);
  ov.DB = {
    prepare(sql) {
      if (isLedger(sql) && ov.on) {
        const s = { bind() { return s; }, async first() { throw overload(); }, async all() { throw overload(); } };
        return s;
      }
      return inner.prepare(sql);
    },
    batch: (s) => inner.batch(s),
  };
  return ov;
}

class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}

// Counts Sentry envelopes and console.warn calls; both restored after the test.
function spies(t) {
  const real = globalThis.fetch;
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
  t.after(() => { globalThis.fetch = real; console.warn = realWarn; });
  return s;
}

// captureException flushes through the SDK transport, not ctx.waitUntil.
const settle = () => new Promise((r) => setTimeout(r, 300));

const pathOf = (route) => (route === H ? "/api/verdict/history" : "/api/verdict");
const env = (DB, extra = {}) => ({
  DB, HARNESS_SECRET: "test-secret", HARNESS_SENTRY_DSN: DSN,
  // Above every count here: the per-isolate cap is not what this file tests.
  HARNESS_SENTRY_MAX_PER_FP_HOUR: "1000", ...extra,
});

async function call(ov, route = V, extra = {}) {
  const res = await worker.fetch(new Request(`https://jobs.test${pathOf(route)}?pr=${encodeURIComponent(PR)}`, {
    headers: { authorization: "Bearer test-secret" },
  }), env(ov.DB, extra), new Ctx());
  return { status: res.status, body: await res.json() };
}

// n concurrent give-ups on `route`; every answer must be the 503 retryable.
async function giveUps(ov, n, route = V, extra = {}) {
  const out = await Promise.all(Array.from({ length: n }, () => call(ov, route, extra)));
  for (const r of out) {
    assert.equal(r.status, 503);
    assert.equal(r.body.retryable, true);
    assert.match(r.body.error, /overloaded/i);
  }
  await settle();
  return out;
}

const streak = (ov, route = V) => ov.db.prepare("SELECT * FROM d1_overload_streaks WHERE route=?").get(route);
const rowsOf = (ov) => ov.db.prepare("SELECT COUNT(*) AS n FROM d1_overload_streaks").get().n;

async function fresh(t) {
  resetGiveUpStreaks();
  return spies(t);
}

test("G0: withD1Retry, overload twice then a row -> the row, waits [100, 200] (increasing)", async () => {
  const waits = [];
  let calls = 0;
  const want = { ok: 1 };
  const r = await withD1Retry(async () => {
    calls += 1;
    if (calls <= 2) throw new Error(OVERLOAD);
    return want;
  }, { sleep: async (ms) => { waits.push(ms); }, random: () => 1 });
  assert.strictEqual(r, want);
  assert.deepEqual(waits, [100, 200]);
});

test("G1: 3 give-ups on GET /api/verdict -> one d1_overload_streaks row with consecutive = 3", { skip: !SQLITE }, async (t) => {
  await fresh(t);
  const ov = await overloadable();
  await giveUps(ov, 3);
  assert.equal(rowsOf(ov), 1);
  assert.equal(streak(ov).consecutive, 3);
});

test("G2: one give-up -> 503 retryable, 1 warn 'streak 1', 0 Sentry posts, 1 counter row", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  const [r] = await giveUps(ov, 1);
  assert.equal(r.body.d1_attempts, D1_RETRY_ATTEMPTS);
  assert.equal(s.posts.length, 0, "a single give-up sends no Sentry event");
  assert.equal(s.warns.length, 1);
  assert.match(s.warns[0], new RegExp(`GET /api/verdict gave up on D1 overload after ${D1_RETRY_ATTEMPTS} attempt\\(s\\), streak 1:`));
  assert.equal(rowsOf(ov), 1);
  assert.equal(streak(ov).consecutive, 1);
});

test("G3: a give-up, then a healthy request -> 200 with the ledger job; only d1_overload_streaks changed", { skip: !SQLITE }, async (t) => {
  await fresh(t);
  const ov = await overloadable();
  const counts = () => Object.fromEntries(
    ov.db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all()
      .map(({ name }) => [name, ov.db.prepare(`SELECT COUNT(*) AS n FROM "${name}"`).get().n]));
  const before = counts();
  await giveUps(ov, 1);
  ov.on = false;
  const ok = await call(ov);
  assert.equal(ok.status, 200);
  assert.equal(ok.body.job_id, "build-7541");
  const after = counts();
  assert.equal(after.d1_overload_streaks, before.d1_overload_streaks + 1);
  delete before.d1_overload_streaks;
  delete after.d1_overload_streaks;
  assert.deepEqual(after, before, "no other table changed");
});

test("G4: 3 consecutive give-ups -> exactly 1 Sentry post; 6 -> 2", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  await giveUps(ov, 2);
  assert.equal(s.posts.length, 0, "2 give-ups send nothing");
  await giveUps(ov, 1);
  assert.equal(s.posts.length, 1, "the 3rd sends one event");
  await giveUps(ov, 2);
  assert.equal(s.posts.length, 1, "4th and 5th send nothing");
  ov.next();
  await giveUps(ov, 1);
  assert.equal(s.posts.length, 2, "the 6th sends the second event");
  assert.equal(streak(ov).consecutive, 6);
});

test("G5a: a give-up after a gap longer than the window starts the streak at 1 and sends nothing", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  await giveUps(ov, 2);
  // A fixed stamp far older than any window: the route stamps with the server
  // clock, so the exact 900/901 s boundary is pinned in G5f with fixed times.
  const old = "2000-01-01T00:00:00Z";
  ov.db.prepare("UPDATE d1_overload_streaks SET last_at=? WHERE route=?").run(old, V);
  await giveUps(ov, 1);
  assert.equal(streak(ov).consecutive, 1, "the window reset the streak");
  assert.equal(s.posts.length, 0);
});

test("G5f: the window boundary, fixed times: 900 s after the last give-up continues the streak, 901 s resets it", { skip: !SQLITE }, async () => {
  for (const fallback of [false, true]) {
    resetGiveUpStreaks();
    const ov = await overloadable();
    if (fallback) ov.db.exec("DROP TABLE d1_overload_streaks");
    const e = { DB: ov.DB };
    const seq = [];
    for (const t of ["2026-10-19T15:36:00Z", "2026-10-19T15:51:00Z", "2026-10-19T16:06:00Z", "2026-10-19T16:21:01Z"]) {
      seq.push(await recordGiveUp(e, V, t));
    }
    const tag = fallback ? "in-isolate" : "db";
    assert.deepEqual(seq.map((g) => g.consecutive), [1, 2, 3, 1], tag);
    assert.deepEqual(seq.map((g) => g.report), [false, false, true, false], tag);
    assert.ok(seq.every((g) => g.recorded === !fallback), `${tag}: recorded is ${!fallback}`);
  }
});

test("G5b: 2 give-ups on each of the two routes -> per-route streaks, 0 posts", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  await Promise.all([giveUps(ov, 2, V), giveUps(ov, 2, H)]);
  assert.equal(streak(ov, V).consecutive, 2);
  assert.equal(streak(ov, H).consecutive, 2);
  assert.equal(s.posts.length, 0);
});

test("G5c: HARNESS_D1_GIVEUP_REPORT_AFTER=1 -> the first give-up sends", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  await giveUps(ov, 1, V, { HARNESS_D1_GIVEUP_REPORT_AFTER: "1" });
  assert.equal(s.posts.length, 1);
});

test("G5d: an invalid HARNESS_D1_GIVEUP_REPORT_AFTER ('abc', '0', '-1') -> the default 3", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  for (const bad of ["abc", "0", "-1"]) {
    const ov = await overloadable();
    await giveUps(ov, 2, V, { HARNESS_D1_GIVEUP_REPORT_AFTER: bad });
    assert.equal(s.posts.length, 0, `${bad}: 2 give-ups send nothing`);
    await giveUps(ov, 1, V, { HARNESS_D1_GIVEUP_REPORT_AFTER: bad });
    assert.equal(s.posts.length, 1, `${bad}: the 3rd sends`);
    s.posts.length = 0;
    resetGiveUpStreaks();
  }
});

test("G5e: the counter table is missing -> the in-isolate streak sends once at 3, every answer is 503, no throw", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  ov.db.exec("DROP TABLE d1_overload_streaks");
  await giveUps(ov, 2);
  assert.equal(s.posts.length, 0);
  await giveUps(ov, 1);
  assert.equal(s.posts.length, 1);
  assert.match(s.warns.at(-1), /streak 3:/);
});

test("G6: the event on the 3rd give-up carries lane, d1_giveups, d1_route and d1_attempts tags", { skip: !SQLITE }, async (t) => {
  const s = await fresh(t);
  const ov = await overloadable();
  await giveUps(ov, 3);
  assert.equal(s.posts.length, 1);
  const p = s.posts[0];
  assert.match(p, /"lane":"harness-jobs"/);
  assert.match(p, /"d1_giveups":"3"/);
  assert.match(p, /"d1_route":"GET \/api\/verdict"/);
  assert.match(p, new RegExp(`"d1_attempts":"${D1_RETRY_ATTEMPTS}"`));
});

// The SQL prLedgerJob sends, through a recording stub.
async function ledgerSql() {
  const log = [];
  const stmt = (sql) => ({
    bind(...b) { log.push({ sql, binds: b }); return stmt(sql); },
    async first() { return /FROM jobs WHERE id=/.test(sql) ? { id: "build-1" } : { job_id: "build-1" }; },
    async all() { throw new Error("prLedgerJob must not call all()"); },
    async run() { throw new Error("prLedgerJob must not call run()"); },
  });
  await prLedgerJob({ prepare: stmt }, PR);
  return log;
}

test("G7: prLedgerJob sends exactly 2 statements, both SELECT, no write", async () => {
  const log = await ledgerSql();
  assert.equal(log.length, 2);
  for (const { sql } of log) {
    assert.match(sql.trim(), /^SELECT\b/i);
    assert.doesNotMatch(sql, /\b(INSERT|UPDATE|DELETE|REPLACE)\b/i);
  }
});

const vol = await openVolumeDb();

test("G8: EXPLAIN QUERY PLAN at seeded volume: prLedgerJob, the history read and the upsert use an index", { skip: !vol }, async () => {
  const pr = "https://github.com/o/alpha/pull/0";
  const HOT = ["jobs", "job_artifacts", "verdict_history", "d1_overload_streaks", "a", "j"];
  const check = (sql, binds, want) => {
    const lines = plan(vol.db, sql, ...binds);
    const scans = lines.filter((l) => {
      const m = /^SCAN (\w+)/.exec(l);
      return m && HOT.includes(m[1]);
    });
    assert.deepEqual(scans, [], `full scan:\n  ${lines.join("\n  ")}`);
    assert.ok(!lines.some((l) => /CORRELATED/.test(l)), lines.join(" | "));
    assert.ok(lines.some((l) => want.test(l)), `${want}: ${lines.join(" | ")}`);
  };
  const [art, job] = await ledgerSql();
  check(art.sql, [pr], /idx_artifacts_ref/);
  check(job.sql, ["build-alpha-0"], /PRIMARY KEY|sqlite_autoindex_jobs/);
  check(`SELECT * FROM verdict_history
          WHERE job_id IN (SELECT job_id FROM job_artifacts
                            WHERE artifact_kind='pr_url' AND artifact_ref=?1)
          ORDER BY id ASC LIMIT 200`, [pr], /idx_artifacts_ref/);
  // An UPSERT's own plan is its conflict probe on the PK: read it as the
  // equivalent point SELECT, since EXPLAIN QUERY PLAN of an INSERT prints nothing.
  assert.match(GIVEUP_UPSERT_SQL, /ON CONFLICT\(route\)/);
  check("SELECT consecutive FROM d1_overload_streaks WHERE route=?1", [V], /sqlite_autoindex_d1_overload_streaks_1|PRIMARY KEY/);
});
