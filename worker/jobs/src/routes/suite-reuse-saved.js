// suite-reuse-saved routes — the suite ledger's READ half (BH-5354.3 / BH-5369).
//
// Mission Control's SUITE REUSE section reads the first two; the hub lane
// bin/impact-learn-lane.sh reads the third (BH-6460). All are bearer-only:
// they sit in ROUTES, after the bearer check, so an x-suite-ledger-token (the
// CI credential, which can only write) is a 401 here. The bearer is the builder
// class and sees both classes, which the console shows in separate rows.
//
//   GET /api/suite-results/saved?days=14[&repo=]  -> per (day, repo, class) sums
//   GET /api/suite-results/runs?day=YYYY-MM-DD[&repo=][&class=] -> that day's runs
//   GET /api/suite-results/passes?repo=R&since=YYYY-MM-DD -> per-suite passes and fails
//
// The table, its write route and its validation are the contract's
// (routes/suite-results.js, lib/suite-results.js); this file only reads.

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

export const SAVED_DAYS_DEFAULT = 14;
export const SAVED_DAYS_MAX = 60;
export const RUNS_LIMIT = 200;

// The contract's REPO_RE (lib/suite-results.js), which it does not export.
const REPO_RE = /^[A-Za-z0-9._/-]{1,100}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const CLASSES = new Set(["ci", "builder"]);
// A CI run key is `<run_id>-<attempt>-<shard>` (nightly runs prefix it). Only
// that shape on a ci row, in an owner/name repo, names a GitHub run (D26).
const CI_RUN_KEY_RE = /^(?:nightly-)?(\d+)-(\d+)-/;
const GH_REPO_RE = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/;

const bad = (error) => json(400, { error });
const utcDay = (ms) => new Date(ms).toISOString().slice(0, 10);

// The repo filter: absent is no filter, present must be a repo the ledger can hold.
function repoParam(q) {
  const repo = q.get("repo");
  if (repo === null) return { repo: null };
  return REPO_RE.test(repo) ? { repo } : { error: `repo must match ${REPO_RE}` };
}

// A real calendar day, or null. `2026-02-30` round-trips to a different day.
function parseDay(s) {
  if (typeof s !== "string" || !DAY_RE.test(s)) return null;
  const ms = Date.parse(`${s}T00:00:00Z`);
  return Number.isFinite(ms) && utcDay(ms) === s ? ms : null;
}

// Absent → the default. An integer clamps to 1..60 (the ticket's rule for this
// range); anything that is not an integer is refused, never read as a default.
function daysParam(q) {
  const raw = q.get("days");
  if (raw === null) return { days: SAVED_DAYS_DEFAULT };
  if (!/^-?\d{1,6}$/.test(raw)) return { error: "days must be an integer" };
  return { days: Math.min(Math.max(Number(raw), 1), SAVED_DAYS_MAX) };
}

export function runUrl(row) {
  if (typeof row.url === "string" && row.url) return row.url;
  if (row.class !== "ci" || typeof row.repo !== "string" || !GH_REPO_RE.test(row.repo)) return null;
  const m = CI_RUN_KEY_RE.exec(String(row.run_key || ""));
  return m ? `https://github.com/${row.repo}/actions/runs/${m[1]}/attempts/${m[2]}` : null;
}

// The table has no reused_suites column today; a row that carries one gets it
// parsed. Bad JSON or anything but an array of objects is "not recorded".
export function reusedSuites(row) {
  if (typeof row.reused_suites !== "string") return null;
  try {
    const v = JSON.parse(row.reused_suites);
    return Array.isArray(v) && v.every((x) => x && typeof x === "object" && !Array.isArray(x)) ? v : null;
  } catch {
    return null;
  }
}

export const routes = [
  [
    "GET", "/api/suite-results/saved",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      const d = daysParam(q);
      if (d.error) return bad(d.error);
      const r = repoParam(q);
      if (r.error) return bad(r.error);
      const cutoff = utcDay(Date.parse(t) - (d.days - 1) * 86400000);
      return d1Guarded("suite_reuse_runs", async () => {
        await ensureTable(env, "suite_reuse_runs");
        const binds = [cutoff];
        if (r.repo) binds.push(r.repo);
        const { results } = await env.DB.prepare(
          `SELECT substr(created_at, 1, 10) AS day, repo, class, COUNT(*) AS runs,
             SUM(ran) AS ran, SUM(reused) AS reused, SUM(saved_s) AS saved_s
           FROM suite_reuse_runs WHERE created_at >= ?1${r.repo ? " AND repo = ?2" : ""}
           GROUP BY day, repo, class ORDER BY day DESC, repo, class`
        ).bind(...binds).all();
        return json(200, { days: d.days, since: cutoff, rows: results || [] });
      });
    },
  ],

  [
    "GET", "/api/suite-results/runs",
    async ({ env, url }) => {
      const q = url.searchParams;
      const day = q.get("day");
      const dayMs = parseDay(day);
      if (dayMs === null) return bad("day must be a real YYYY-MM-DD date");
      const r = repoParam(q);
      if (r.error) return bad(r.error);
      const cls = q.get("class");
      if (cls !== null && !CLASSES.has(cls)) return bad("class must be ci or builder");
      const binds = [day, utcDay(dayMs + 86400000)];
      let where = "created_at >= ?1 AND created_at < ?2";
      if (r.repo) { binds.push(r.repo); where += ` AND repo = ?${binds.length}`; }
      if (cls) { binds.push(cls); where += ` AND class = ?${binds.length}`; }
      return d1Guarded("suite_reuse_runs", async () => {
        await ensureTable(env, "suite_reuse_runs");
        const { results } = await env.DB.prepare(
          `SELECT * FROM suite_reuse_runs WHERE ${where}
           ORDER BY created_at DESC, run_key LIMIT ${RUNS_LIMIT + 1}`
        ).bind(...binds).all();
        const all = results || [];
        const rows = all.slice(0, RUNS_LIMIT)
          .map((row) => ({ ...row, url: runUrl(row), reused_suites: reusedSuites(row) }));
        return json(200, { day, capped: all.length > RUNS_LIMIT, rows });
      });
    },
  ],

  // The learned-edge expiry read (BH-6460). passes: the runs of `ok` rows first
  // seen on or after `since`; fails: every fail on a row written on or after
  // `since`. A row that straddles `since` counts its fails but not its passes.
  // `since` is bound as the bare day: ISO stamps of that day sort after it. A
  // suite with no row since is absent, and the reader keeps its edge.
  [
    "GET", "/api/suite-results/passes",
    async ({ env, url }) => {
      const q = url.searchParams;
      const repo = q.get("repo");
      if (repo === null || repo === "") return bad("repo is required");
      if (!REPO_RE.test(repo)) return bad(`repo must match ${REPO_RE}`);
      const since = q.get("since");
      if (parseDay(since) === null) return bad("since must be a real YYYY-MM-DD date");
      return d1Guarded("suite_results", async () => {
        await ensureTable(env, "suite_results");
        const { results } = await env.DB.prepare(
          `SELECT suite,
             SUM(CASE WHEN status = 'ok' AND first_at >= ?2 THEN runs ELSE 0 END) AS passes,
             SUM(fails) AS fails
           FROM suite_results WHERE repo = ?1 AND updated_at >= ?2
           GROUP BY suite ORDER BY suite`
        ).bind(repo, since).all();
        return json(200, { repo, since, suites: results || [] });
      });
    },
  ],
];
