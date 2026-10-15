// ci-durations routes — BH-5653 (BH-5637.2): per-suite CI wall seconds, so the
// shard balancer plans from a ledger of what CI measured.
//
// Writer: `bin/ci-durations.sh post` in the `ci-timings` job, one POST per green
// Mergify batch run (and `bin/ci-durations.sh seed` once, from the last
// committed durations file, with source "seed"). Reader: `bin/ci-durations.sh
// fetch`, which GETs every row and falls back to its cache, then to the CI
// artifact chain (docs/ci-durations.md).
//
// AUTH. Both routes sit in OPEN_ROUTES, so the main bearer check never runs for
// them: each handler checks its OWN bearer. It accepts CI_DURATIONS_TOKEN (the
// one secret CI holds, scoped to these two routes) or HARNESS_SECRET (a box).
// A secret that is unset or empty matches nothing, so a worker with neither set
// refuses every bearer, the empty one included.
//
// IDEMPOTENT PER RUN. ci_duration_runs.run_id is the key, bound to the sha256
// of the run's rows sorted by suite. The same run with the same rows is a
// duplicate (nothing written); the same run with other rows is a 409.
//
// The tables ship in schema.sql, which bin/harness-sync.sh applies before
// `wrangler deploy`; both handlers are d1Guarded so an unapplied table answers
// 503 "ci_suite_durations schema not applied", never a bodiless 500.

import { json, d1Guarded } from "../lib/http.js";

const SUITE_RE = /^tests\/[A-Za-z0-9._/-]+\.sh$/;
const SECONDS_MAX = 10800;
const ROWS_MAX = 5000;
// D1 refuses a statement with more than 100 bound values.
const SAMPLE_ROWS_PER_STMT = 33; // 3 binds per row
const MEDIAN_ROWS_PER_STMT = 20; // 5 binds per row
const IN_LIST_MAX = 99; // the prune binds the window as the 100th value
// The settings row `ci_suite_durations.window`; this is the documented fallback
// when the row is missing or is not an integer in 1..WINDOW_MAX.
const WINDOW_FALLBACK = 3;
const WINDOW_MAX = 15;

function authorized(req, env) {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.get("authorization") || "");
  if (!m) return false;
  const matches = (secret) => typeof secret === "string" && secret !== "" && m[1] === secret;
  return matches(env.CI_DURATIONS_TOKEN) || matches(env.HARNESS_SECRET);
}

const chunk = (list, n) => {
  const out = [];
  for (let i = 0; i < list.length; i += n) out.push(list.slice(i, i + n));
  return out;
};
const byCodeUnit = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// Every row is checked before anything is written: one bad row refuses the
// whole body. Returns { error } or the cleaned { runId, source, rows }.
function validate(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return { error: "body must be a JSON object" };
  const runId = body.run_id;
  if (typeof runId !== "number" || !Number.isSafeInteger(runId) || runId <= 0) {
    return { error: "run_id must be a positive integer" };
  }
  const source = body.source === undefined ? "ci" : body.source;
  if (source !== "ci" && source !== "seed") return { error: "source must be ci or seed" };
  if (!Array.isArray(body.rows) || body.rows.length === 0) return { error: "rows must be a non-empty array" };
  if (body.rows.length > ROWS_MAX) return { error: `rows over ${ROWS_MAX}` };
  const seen = new Set();
  const rows = [];
  for (let i = 0; i < body.rows.length; i++) {
    const r = body.rows[i];
    if (r === null || typeof r !== "object" || Array.isArray(r)) return { error: `rows[${i}] must be an object` };
    const { suite, seconds } = r;
    if (typeof suite !== "string" || !SUITE_RE.test(suite) || suite.includes("..")) {
      return { error: `rows[${i}].suite must be a tests/<path>.sh suite path` };
    }
    if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 0 || seconds > SECONDS_MAX) {
      return { error: `rows[${i}].seconds must be a number in 0..${SECONDS_MAX}` };
    }
    if (seen.has(suite)) return { error: `rows[${i}].suite ${suite} is a duplicate` };
    seen.add(suite);
    rows.push({ suite, seconds });
  }
  return { runId, source, rows };
}

// sha256 hex of the rows sorted by suite, one `suite<TAB>seconds<LF>` line each.
async function digestOf(rows) {
  const text = [...rows].sort((a, b) => byCodeUnit(a.suite, b.suite))
    .map((r) => `${r.suite}\t${r.seconds}\n`).join("");
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readWindow(db) {
  const v = await db.prepare("SELECT value FROM settings WHERE key = ?1").bind("ci_suite_durations.window").first("value");
  const n = typeof v === "string" && /^\d+$/.test(v.trim()) ? Number(v.trim()) : NaN;
  return Number.isInteger(n) && n >= 1 && n <= WINDOW_MAX ? n : WINDOW_FALLBACK;
}

// Sort by seconds (tie: run_id). Odd count: the middle sample. Even count: the
// mean of the two middle samples, named by the newer (larger) run of the two.
export function medianOf(samples) {
  const s = [...samples].sort((a, b) => a.seconds - b.seconds || a.run_id - b.run_id);
  const mid = Math.floor(s.length / 2);
  if (s.length % 2 === 1) return { seconds: s[mid].seconds, source_run: s[mid].run_id };
  const lo = s[mid - 1];
  const hi = s[mid];
  return { seconds: (lo.seconds + hi.seconds) / 2, source_run: Math.max(lo.run_id, hi.run_id) };
}

// Recompute and upsert the median of each suite in `suites` over its newest
// `window` samples. It reads the samples as they are now, so running it twice
// writes the same rows: that is what lets the duplicate path call it to heal a
// post whose sample batch committed but whose median batch did not.
async function settleMedians(db, suites, window, t) {
  const bySuite = new Map();
  for (const part of chunk(suites, IN_LIST_MAX)) {
    const marks = part.map((_, i) => `?${i + 1}`).join(",");
    // sql-ident-ok: marks is a ?N placeholder list built from the chunk index
    const { results } = await db.prepare(
      `SELECT suite, run_id, seconds FROM ci_suite_duration_samples WHERE suite IN (${marks}) ORDER BY suite, run_id DESC`,
    ).bind(...part).all();
    for (const r of results || []) {
      const list = bySuite.get(r.suite) || [];
      if (list.length < window) list.push({ run_id: Number(r.run_id), seconds: Number(r.seconds) });
      bySuite.set(r.suite, list);
    }
  }
  const rows = [...bySuite].map(([suite, samples]) => ({ suite, ...medianOf(samples), samples: samples.length }));
  // sql-ident-ok: each row adds the literal (?,?,?,?,?) placeholder tuple
  const stmts = chunk(rows, MEDIAN_ROWS_PER_STMT).map((part) => db.prepare(
    "INSERT INTO ci_suite_durations (suite, seconds, source_run, samples, updated_at) VALUES "
    + part.map(() => "(?,?,?,?,?)").join(",")
    + " ON CONFLICT(suite) DO UPDATE SET seconds = excluded.seconds, source_run = excluded.source_run,"
    + " samples = excluded.samples, updated_at = excluded.updated_at",
  ).bind(...part.flatMap((r) => [r.suite, r.seconds, r.source_run, r.samples, t])));
  // A throw here reaches d1Guarded and answers 503: a post is never reported
  // as stored when its medians were not written.
  if (stmts.length) await db.batch(stmts);
}

// The same run_id again: same rows is a duplicate, other rows is a conflict.
// The duplicate still re-runs the median upsert for the run's suites, so a
// retry heals an earlier attempt that failed between the two batches.
async function answerExisting(db, prior, v, digest, t) {
  if (prior !== digest) return json(409, { error: "run_id already posted with different rows", run_id: v.runId });
  await settleMedians(db, v.rows.map((r) => r.suite), await readWindow(db), t);
  return json(200, { ok: true, duplicate: true, written: 0, run_id: v.runId });
}

export const routes = [
  [
    "POST", "/api/ci/suite-durations",
    async ({ req, env, t }) => {
      if (!authorized(req, env)) return json(401, { error: "unauthorized" });
      // Open routes get no parsed body: read it here, and refuse a bad one.
      let body;
      try {
        body = await req.json();
      } catch {
        return json(400, { error: "body is not JSON" });
      }
      const v = validate(body);
      if (v.error) return json(400, { error: v.error });
      const digest = await digestOf(v.rows);
      const db = env.DB;
      return d1Guarded("ci_suite_durations", async () => {
        const prior = await db.prepare("SELECT digest FROM ci_duration_runs WHERE run_id = ?1").bind(v.runId).first("digest");
        if (prior !== null && prior !== undefined) return answerExisting(db, prior, v, digest, t);

        const window = await readWindow(db);
        const suites = v.rows.map((r) => r.suite);
        // One batch, so the run row never lands without its samples: the run
        // row, the samples, then the prune of each posted suite to its window.
        const stmts = [
          db.prepare("INSERT INTO ci_duration_runs (run_id, digest, suites, source, posted_at) VALUES (?1, ?2, ?3, ?4, ?5)")
            .bind(v.runId, digest, v.rows.length, v.source, t),
          // sql-ident-ok: each row adds the literal (?,?,?) placeholder tuple
          ...chunk(v.rows, SAMPLE_ROWS_PER_STMT).map((part) => db.prepare(
            "INSERT INTO ci_suite_duration_samples (suite, run_id, seconds) VALUES "
            + part.map(() => "(?,?,?)").join(","),
          ).bind(...part.flatMap((r) => [r.suite, v.runId, r.seconds]))),
          ...chunk(suites, IN_LIST_MAX).map((part) => {
            const marks = part.map((_, i) => `?${i + 1}`).join(",");
            // sql-ident-ok: marks is a ?N placeholder list built from the chunk index
            return db.prepare(
              "DELETE FROM ci_suite_duration_samples WHERE (suite, run_id) IN ("
              + "SELECT suite, run_id FROM (SELECT suite, run_id, ROW_NUMBER() OVER "
              + "(PARTITION BY suite ORDER BY run_id DESC) AS rn FROM ci_suite_duration_samples "
              + `WHERE suite IN (${marks})) WHERE rn > ?${part.length + 1})`,
            ).bind(...part, window);
          }),
        ];
        try {
          await db.batch(stmts);
        } catch (e) {
          // A concurrent post of the same run_id won the primary key. Its batch
          // committed whole, so answer as the second post would have.
          if (!/UNIQUE|PRIMARY KEY|constraint/i.test(String((e && e.message) || e))) throw e;
          const won = await db.prepare("SELECT digest FROM ci_duration_runs WHERE run_id = ?1").bind(v.runId).first("digest");
          if (won === null || won === undefined) throw e;
          return answerExisting(db, won, v, digest, t);
        }
        // The medians are recomputed after the batch, from the samples it left.
        await settleMedians(db, suites, window, t);
        return json(200, { ok: true, duplicate: false, written: v.rows.length, run_id: v.runId, suites: v.rows.length });
      });
    },
  ],
  [
    "GET", "/api/ci/suite-durations",
    // Every row, no cap: one row per suite, a few thousand at most. A cap added
    // later must answer `truncated: true`, or fetch would plan from a part.
    async ({ req, env }) => {
      if (!authorized(req, env)) return json(401, { error: "unauthorized" });
      return d1Guarded("ci_suite_durations", async () => {
        const { results } = await env.DB.prepare(
          "SELECT suite, seconds, source_run, samples, updated_at FROM ci_suite_durations ORDER BY suite ASC",
        ).all();
        const rows = results || [];
        return json(200, { rows, count: rows.length });
      });
    },
  ],
];
