// BH-5668 (BH-5008 child 2): progress and ETA on GET /api/merge-queue/live.
// The route runs `await applyProgress(env, payload)` before it answers.
//
// Two D1 reads per repo on screen, nothing else (no fetch): the check rows of
// the drafts on screen, and the median rows of those checks' job classes (one
// read gives both the name medians and the class rows). Each batch then gets
// progress, eta_s and eta_basis from batchEta (lib/merge-queue-eta.js), with
// payload.as_of as "now". Every other field is left as it came in. A read
// that throws propagates to the route's d1Guarded: no invented progress.

import { batchEta } from "./merge-queue-eta.js";

const CHECK_CAP = 3000;

const repoOf = (b) => {
  if (b && typeof b.repo === "string" && b.repo) return b.repo;
  const m = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+/.exec(String((b && b.url) || ""));
  return m ? m[1] : null;
};

async function readRepo(env, repo, drafts) {
  const ph = drafts.map((_, i) => `?${i + 2}`).join(",");
  const [checks, medians] = await Promise.all([
    // sql-ident-ok: ph and the LIMIT are ?N placeholder text
    env.DB.prepare(
      `SELECT draft_pr, name, job_class, status, started_at FROM merge_queue_checks
        WHERE repo = ?1 AND draft_pr IN (${ph}) LIMIT ?${drafts.length + 2}`
    ).bind(repo, ...drafts, CHECK_CAP + 1).all(),
    // sql-ident-ok: ph is ?N placeholder text
    env.DB.prepare(
      `SELECT name, job_class, median_s FROM merge_queue_check_medians
        WHERE repo = ?1 AND job_class IN (
          SELECT DISTINCT job_class FROM merge_queue_checks WHERE repo = ?1 AND draft_pr IN (${ph}))`
    ).bind(repo, ...drafts).all(),
  ]);
  return { checks: checks.results || [], medians: medians.results || [] };
}

export async function applyProgress(env, payload) {
  const batches = payload && Array.isArray(payload.batches) ? payload.batches : [];
  if (!batches.length) return payload;
  const nowMs = Date.parse(payload.as_of);

  const byRepo = new Map();
  for (const b of batches) {
    const repo = repoOf(b);
    if (!repo) continue;
    if (!byRepo.has(repo)) byRepo.set(repo, new Set());
    byRepo.get(repo).add(b.draft);
  }
  const reads = await Promise.all([...byRepo].map(async ([repo, drafts]) => [repo, await readRepo(env, repo, [...drafts])]));
  const data = new Map(reads);

  for (const b of batches) {
    const finished = Boolean(b.finished_at || b.outcome);
    const d = data.get(repoOf(b));
    if (!d || d.checks.length > CHECK_CAP) {
      // No repo, or more check rows than one read holds: no estimate (D12).
      if (d) payload.complete = false;
      Object.assign(b, finished ? batchEta([], [], nowMs, { finished }) : { progress: null, eta_s: null, eta_basis: "partial" });
      continue;
    }
    const mine = d.checks.filter((c) => c.draft_pr === b.draft);
    Object.assign(b, batchEta(mine, d.medians, nowMs, { finished }));
  }
  return payload;
}
