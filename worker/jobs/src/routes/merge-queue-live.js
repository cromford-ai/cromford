// merge-queue-live routes — BH-5667 (BH-5008 child 1): GET /api/merge-queue/live,
// the Mergify batches the github receiver recorded (merge_queue_batches /
// merge_queue_checks, written by src/lib/merge-queue-intake.js).
//
// D1 reads only: no GitHub or Mergify call, so a console polling every 5 s
// costs four small D1 reads (the project, the window row, the batches and
// their checks, the last two LIMITed) and nothing metered. `max-age=4` lets
// the edge answer a burst of tabs once.
//
// The batch shape carries every field BH-5008's later children fill (stage,
// progress, eta, failing, bisect, waiting, prs), null or empty here. Those
// children fill them through the applyProgress / applyStages seams, which run
// last, so this file stays the one reader of the rows.
//
// Both reads are capped one past their limit, and either cap hit answers
// `complete: false` (D12). A table that is not applied answers 503 "schema not
// applied" through d1Guarded.

import { json, d1Guarded } from "../lib/http.js";
import { WAKE_REPO_RE } from "../lib/core.js";
import { applyProgress } from "../lib/merge-queue-live-progress.js";
import { applyStages } from "../lib/merge-queue-live-stages.js";

const BATCH_CAP = 50;
const CHECK_CAP = 3000;
const WINDOW_DEFAULT_S = 900;

const isoS = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

function membersOf(raw) {
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v.filter((n) => Number.isInteger(n) && n > 0) : [];
  } catch { return []; }
}

// The repo a ?project= names: a projects row, or a slug used as given. null =
// unknown. No param = every repo (undefined).
async function repoOf(env, project) {
  if (project === null || project === "") return undefined;
  const row = await env.DB.prepare(`SELECT repo FROM projects WHERE project = ?1`).bind(project).first();
  if (row && row.repo) return String(row.repo);
  return WAKE_REPO_RE.test(project) ? project : null;
}

async function windowOf(env) {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key = 'merge_queue_live_window_s'`).first();
  const raw = row ? String(row.value).trim() : "";
  const n = /^[0-9]{1,9}$/.test(raw) ? Number(raw) : NaN;
  return Number.isInteger(n) && n > 0 ? { s: n, source: "setting" } : { s: WINDOW_DEFAULT_S, source: "default" };
}

// → { status, body }
export async function readMergeQueueLive(env, { project, t }) {
  const repo = await repoOf(env, project);
  if (repo === null) return { status: 404, body: { error: "unknown project" } };
  const win = await windowOf(env);
  const cutoff = isoS(Date.parse(t) - win.s * 1000);
  const binds = [cutoff];
  let where = `(finished_at IS NULL OR finished_at >= ?1)`;
  if (repo) { binds.push(repo); where += ` AND lower(repo) = lower(?2)`; }
  binds.push(BATCH_CAP + 1);
  // sql-ident-ok: where holds literal clauses, repo and the limit bind as ?N
  const res = await env.DB.prepare(
    `SELECT repo, draft_pr, members_json, base_sha, started_at, finished_at, outcome FROM merge_queue_batches
      WHERE ${where} ORDER BY started_at DESC, draft_pr DESC LIMIT ?${binds.length}`
  ).bind(...binds).all();
  const rows = (res.results || []);
  let complete = rows.length <= BATCH_CAP;
  const kept = rows.slice(0, BATCH_CAP);

  // One read for every batch's checks. D1 binds 100 values at most, and the 50
  // drafts plus the limit fit; the repo filter is applied here, in JS.
  const counts = new Map();
  if (kept.length) {
    const drafts = [...new Set(kept.map((b) => b.draft_pr))];
    // sql-ident-ok: the IN list and the LIMIT are ?N placeholders built from the drafts index
    const cr = await env.DB.prepare(
      `SELECT repo, draft_pr, name, status, conclusion FROM merge_queue_checks
        WHERE draft_pr IN (${drafts.map((_, i) => `?${i + 1}`).join(",")}) LIMIT ?${drafts.length + 1}`
    ).bind(...drafts, CHECK_CAP + 1).all();
    const checks = cr.results || [];
    if (checks.length > CHECK_CAP) complete = false;
    for (const c of checks.slice(0, CHECK_CAP)) {
      const k = `${c.repo}#${c.draft_pr}`;
      const n = counts.get(k) || { done: 0, total: 0 };
      n.total += 1;
      if (c.status === "completed") n.done += 1;
      counts.set(k, n);
    }
  }

  const batches = kept.map((b) => ({
    repo: b.repo,
    draft: b.draft_pr,
    url: `https://github.com/${b.repo}/pull/${b.draft_pr}`,
    members: membersOf(b.members_json),
    base_sha: b.base_sha,
    stage: null,
    checks: counts.get(`${b.repo}#${b.draft_pr}`) || { done: 0, total: 0 },
    progress: null,
    eta_s: null,
    eta_basis: null,
    failing: null,
    bisect: null,
    outcome: b.outcome,
  }));
  const payload = {
    batches, waiting: [], prs: {}, as_of: t, complete, window_s: win.s, window_source: win.source,
  };
  return { status: 200, body: await applyStages(env, await applyProgress(env, payload), { repo }) };
}

export const routes = [
  [
    "GET", "/api/merge-queue/live",
    async ({ env, url, t }) => d1Guarded("merge_queue_batches/merge_queue_checks", async () => {
      const { status, body } = await readMergeQueueLive(env, { project: url.searchParams.get("project"), t });
      return new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json", "cache-control": "max-age=4" },
      });
    }),
  ],
];
