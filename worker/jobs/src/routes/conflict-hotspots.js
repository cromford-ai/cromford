// conflict-hotspots routes — BH-5267 (BH-5248.1): which files collide most,
// per project, as rows.
//
// bin/conflict-hotspots-fleet.sh runs bin/conflict-hotspots.sh weekly against
// each project checkout its box owns and PUTs the result here; Mission Control
// (/p/<project>) and the operator MCP's conflict_hotspots tool read it back with
// the GET. One window per project: an ok PUT replaces that project's rows and
// its conflict_hotspot_runs row in ONE batch, so a failed batch leaves the old
// window whole. A run that did not measure (shallow, no checkout, fetch failed,
// timeout, error) touches only the runs row: the last good window stays
// readable and last_ok_at says when it was taken.

import { json } from "../lib/http.js";
import { strictInt, str, ensureTable, laneName } from "../lib/core.js";

const STATUSES = new Set(["ok", "shallow", "no-checkout", "fetch-failed", "timeout", "error"]);
const ROWS_MAX = 500;
const FILE_MAX = 1024;
// A hot file in a busy repo is rebased under hundreds of PRs a month (`#5123,` is
// six characters each), so the cap is a sanity bound, not a display width.
const PRS_MAX = 65536;
const TEXT_MAX = 500;
const LIMIT_DEFAULT = 20;
const LIMIT_MAX = 200;
// D1 binds at most 100 parameters per statement; a row is 10 of them.
const ROWS_PER_INSERT = 10;
const BOX_RE = /^[A-Za-z0-9._-]{1,64}$/;
const REPO_RE = /^[A-Za-z0-9._-]{1,100}\/[A-Za-z0-9._-]{1,100}$/;
const SHA_RE = /^[0-9a-f]{7,64}$/;

const bad = (error) => json(400, { error });
const ensureAll = async (env) => {
  await ensureTable(env, "conflict_hotspots");
  await ensureTable(env, "conflict_hotspot_runs");
};
// A count is a non-negative whole number or it is absent; never 0 for absent.
const count = (v) => { const n = strictInt(v); return n !== null && n >= 0 ? n : null; };
const optCount = (v) => (v === undefined || v === null ? { ok: true, v: null } : { ok: count(v) !== null, v: count(v) });

function runOut(r) {
  if (!r) return null;
  return {
    project: r.project, repo: r.repo ?? null, box: r.box ?? null, status: r.status, detail: r.detail ?? null,
    window_days: r.window_days ?? null, since: r.since ?? null, until: r.until ?? null, ref_sha: r.ref_sha ?? null,
    pr_merges: r.pr_merges ?? null, sync_merges: r.sync_merges ?? null, merge_tree_errors: r.merge_tree_errors ?? null,
    files_total: r.files_total ?? null, rows_stored: r.rows_stored ?? null, run_at: r.run_at, last_ok_at: r.last_ok_at ?? null,
  };
}

const readRun = (env, project) => env.DB.prepare("SELECT * FROM conflict_hotspot_runs WHERE project = ?1").bind(project).first();

export const routes = [
  // A project's top N, conflicts desc, rebases desc, file asc. An unknown
  // project is "never measured" (run null), not a 404.
  [
    "GET", "/api/conflict-hotspots",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return bad("project must match [A-Za-z0-9._-]{1,64}");
      const lim = strictInt(url.searchParams.get("limit"));
      const limit = lim === null || lim < 1 ? LIMIT_DEFAULT : Math.min(lim, LIMIT_MAX);
      await ensureAll(env);
      const run = await readRun(env, project);
      const rows = await env.DB.prepare(
        "SELECT file, conflicts, rebases, prs, window_days, since, until, ref_sha, run_at FROM conflict_hotspots "
        + "WHERE project = ?1 ORDER BY conflicts DESC, rebases DESC, file ASC LIMIT ?2"
      ).bind(project, limit).all();
      const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM conflict_hotspots WHERE project = ?1").bind(project).first();
      const total = Number((c && c.n) || 0);
      return json(200, {
        project,
        run: runOut(run),
        hotspots: (rows.results || []).map((r) => ({
          file: r.file, conflicts: Number(r.conflicts), rebases: Number(r.rebases), prs: r.prs ?? null,
          window_days: Number(r.window_days), since: r.since, until: r.until, ref_sha: r.ref_sha ?? null, run_at: r.run_at,
        })),
        total,
        limit,
        truncated: total > limit,
        as_of: t,
      });
    },
  ],

  // One box's measurement of one project. Every field and every row is
  // validated before anything is written, so a bad body changes nothing.
  [
    "PUT", "/api/conflict-hotspots",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      if (!project) return bad("project must match [A-Za-z0-9._-]{1,64}");
      const status = typeof body.status === "string" ? body.status : "";
      if (!STATUSES.has(status)) return bad(`status must be one of ${[...STATUSES].join(", ")}`);
      let box = null;
      if (body.box !== undefined && body.box !== null && body.box !== "") {
        if (typeof body.box !== "string" || !BOX_RE.test(body.box)) return bad("box is not a box name");
        box = body.box;
      }
      const rows = body.rows === undefined || body.rows === null ? [] : body.rows;
      if (!Array.isArray(rows)) return bad("rows must be an array");

      if (status !== "ok") {
        if (rows.length) return bad("a run that did not measure carries no rows");
        await ensureAll(env);
        await env.DB.prepare(
          "INSERT INTO conflict_hotspot_runs (project, box, status, detail, run_at) VALUES (?1, ?2, ?3, ?4, ?5) "
          + "ON CONFLICT(project) DO UPDATE SET box = excluded.box, status = excluded.status, "
          + "detail = excluded.detail, run_at = excluded.run_at"
        ).bind(project, box, status, str(body.detail, TEXT_MAX), t).run();
        return json(200, { ok: true, stored: 0, run: runOut(await readRun(env, project)) });
      }

      if (rows.length > ROWS_MAX) return bad(`rows must be at most ${ROWS_MAX}`);
      const windowDays = count(body.window_days);
      if (windowDays === null || windowDays < 1) return bad("window_days must be a positive integer");
      const since = str(body.since, 64);
      const until = str(body.until, 64);
      if (!since || !until) return bad("since and until are required");
      const filesTotal = count(body.files_total);
      if (filesTotal === null || filesTotal < rows.length) return bad("files_total must be an integer at least the row count");
      let repo = null;
      if (body.repo !== undefined && body.repo !== null && body.repo !== "") {
        if (typeof body.repo !== "string" || !REPO_RE.test(body.repo)) return bad("repo must be owner/name");
        repo = body.repo;
      }
      let sha = null;
      if (body.ref_sha !== undefined && body.ref_sha !== null && body.ref_sha !== "") {
        if (typeof body.ref_sha !== "string" || !SHA_RE.test(body.ref_sha)) return bad("ref_sha must be a hex sha");
        sha = body.ref_sha;
      }
      const stats = {};
      for (const k of ["pr_merges", "sync_merges", "merge_tree_errors"]) {
        const o = optCount(body[k]);
        if (!o.ok) return bad(`${k} must be a non-negative integer`);
        stats[k] = o.v;
      }
      const seen = new Set();
      const clean = [];
      for (const r of rows) {
        const file = r && typeof r.file === "string" ? r.file : "";
        if (!file || file.length > FILE_MAX) return bad(`each row needs a file of at most ${FILE_MAX} characters`);
        if (seen.has(file)) return bad(`file ${file.slice(0, 200)} appears twice`);
        seen.add(file);
        const conflicts = count(r.conflicts);
        const rebases = count(r.rebases);
        if (conflicts === null || rebases === null) return bad("conflicts and rebases must be non-negative integers");
        let prs = null;
        if (r.prs !== undefined && r.prs !== null && r.prs !== "") {
          if (typeof r.prs !== "string" || r.prs.length > PRS_MAX) return bad(`prs must be a string of at most ${PRS_MAX}`);
          prs = r.prs;
        }
        clean.push([project, file, conflicts, rebases, prs, windowDays, since, until, sha, t]);
      }

      await ensureAll(env);
      const stmts = [env.DB.prepare("DELETE FROM conflict_hotspots WHERE project = ?1").bind(project)];
      for (let i = 0; i < clean.length; i += ROWS_PER_INSERT) {
        const chunk = clean.slice(i, i + ROWS_PER_INSERT);
        const values = chunk.map((_, j) => `(${Array.from({ length: 10 }, (_, k) => `?${j * 10 + k + 1}`).join(", ")})`);
        // sql-ident-ok: values is ?N placeholder tuples built from the chunk index
        stmts.push(env.DB.prepare(
          "INSERT INTO conflict_hotspots (project, file, conflicts, rebases, prs, window_days, since, until, ref_sha, run_at) "
          + `VALUES ${values.join(", ")}`
        ).bind(...chunk.flat()));
      }
      stmts.push(env.DB.prepare(
        "INSERT INTO conflict_hotspot_runs (project, repo, box, status, detail, window_days, since, until, ref_sha, "
        + "pr_merges, sync_merges, merge_tree_errors, files_total, rows_stored, run_at, last_ok_at) "
        + "VALUES (?1, ?2, ?3, 'ok', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?14) "
        + "ON CONFLICT(project) DO UPDATE SET repo = excluded.repo, box = excluded.box, status = excluded.status, "
        + "detail = excluded.detail, window_days = excluded.window_days, since = excluded.since, until = excluded.until, "
        + "ref_sha = excluded.ref_sha, pr_merges = excluded.pr_merges, sync_merges = excluded.sync_merges, "
        + "merge_tree_errors = excluded.merge_tree_errors, files_total = excluded.files_total, "
        + "rows_stored = excluded.rows_stored, run_at = excluded.run_at, last_ok_at = excluded.last_ok_at"
      ).bind(project, repo, box, str(body.detail, TEXT_MAX), windowDays, since, until, sha,
        stats.pr_merges, stats.sync_merges, stats.merge_tree_errors, filesTotal, clean.length, t));
      await env.DB.batch(stmts);
      return json(200, { ok: true, stored: clean.length, run: runOut(await readRun(env, project)) });
    },
  ],
];
