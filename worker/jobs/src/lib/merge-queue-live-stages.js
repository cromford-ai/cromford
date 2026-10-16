// BH-5669 (BH-5008 child 3): the stage fields of GET /api/merge-queue/live.
// readMergeQueueLive runs `await applyStages(env, payload, { repo })` last.
// It sets, on the SAME payload object:
//   batches[].stage    merged / failed / closed from the outcome; open:
//                      failing (a failed check), checking (any check), batched
//   batches[].failing  {name, url} of the first failed check, else null
//   batches[].bisect   {step, steps, parent} when the draft is a bisect child
//   prs["<repo>#<n>"]  {stage, detail, batch, at, key, project} from each PR's
//                      newest state='queue' row, if that row is from the last
//                      24 h; key/project from pr_owners when it maps the PR
//   waiting[]          {repo, pr, position, at, key} for prs at `queued (<n>)`,
//                      by position, then at
// `repo` is the route's ?project= repo (undefined = every repo). D1 reads
// only. More than PRS_CAP prs rows, or more failed checks than FAIL_CAP,
// answers complete:false (D12).

import { FAILED_CONCLUSIONS } from "./merge-queue-intake.js";

const PRS_WINDOW_S = 24 * 3600;
const PRS_CAP = 500;
const FAIL_CAP = 3000;
const REASON_RE = /^([a-z_]{1,32})(?: \((.*)\))?$/s;

const isoS = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

async function applyBatchStages(env, payload) {
  const batches = payload.batches;
  const drafts = [...new Set(batches.map((b) => b.draft))];
  const ph = drafts.map((_, i) => `?${i + 1}`).join(",");
  // sql-ident-ok: ph is ?N placeholder text
  const meta = await env.DB.prepare(
    `SELECT repo, draft_pr, bisect_parent, bisect_step, bisect_steps FROM merge_queue_batches WHERE draft_pr IN (${ph})`
  ).bind(...drafts).all();
  const bisect = new Map();
  for (const r of meta.results || []) {
    if (r.bisect_parent === null || r.bisect_parent === undefined) continue;
    bisect.set(`${r.repo}#${r.draft_pr}`, { step: r.bisect_step, steps: r.bisect_steps, parent: r.bisect_parent });
  }
  const fph = FAILED_CONCLUSIONS.map((_, i) => `?${drafts.length + i + 1}`).join(",");
  // sql-ident-ok: ph, fph and the LIMIT are ?N placeholder text
  const fr = await env.DB.prepare(
    `SELECT repo, draft_pr, name, url FROM merge_queue_checks
      WHERE draft_pr IN (${ph}) AND conclusion IN (${fph}) ORDER BY finished_at, name LIMIT ?${drafts.length + FAILED_CONCLUSIONS.length + 1}`
  ).bind(...drafts, ...FAILED_CONCLUSIONS, FAIL_CAP + 1).all();
  const fails = fr.results || [];
  if (fails.length > FAIL_CAP) payload.complete = false;
  const failing = new Map();
  for (const f of fails.slice(0, FAIL_CAP)) {
    const k = `${f.repo}#${f.draft_pr}`;
    if (!failing.has(k)) failing.set(k, { name: f.name, url: f.url ?? null });
  }
  for (const b of batches) {
    const k = `${b.repo}#${b.draft}`;
    b.failing = failing.get(k) || null;
    b.bisect = bisect.get(k) || null;
    if (b.outcome === "merged" || b.outcome === "failed" || b.outcome === "closed") b.stage = b.outcome;
    else if (b.failing) b.stage = "failing";
    else if (b.checks && b.checks.total > 0) b.stage = "checking";
    else b.stage = "batched";
  }
}

async function applyPrs(env, payload, repo) {
  const now = Date.parse(payload.as_of);
  if (!Number.isFinite(now)) return;
  const binds = [isoS(now - PRS_WINDOW_S * 1000)];
  let where = `e.state = 'queue' AND e.at >= ?1`;
  if (repo) { binds.push(repo); where += ` AND lower(e.repo) = lower(?2)`; }
  binds.push(PRS_CAP + 1);
  // sql-ident-ok: where holds literal predicates with ?N binds; the LIMIT is ?N text
  const res = await env.DB.prepare(
    `SELECT e.repo, e.number, e.reason, e.since, e.at, o.key, o.project
       FROM pr_state_events e LEFT JOIN pr_owners o ON o.repo = e.repo AND o.number = e.number
      WHERE ${where}
        AND e.id = (SELECT MAX(id) FROM pr_state_events x WHERE x.repo = e.repo AND x.number = e.number AND x.state = 'queue')
      ORDER BY e.id DESC LIMIT ?${binds.length}`
  ).bind(...binds).all();
  const rows = res.results || [];
  if (rows.length > PRS_CAP) payload.complete = false;
  const waiting = [];
  for (const r of rows.slice(0, PRS_CAP)) {
    const m = REASON_RE.exec(String(r.reason ?? ""));
    if (!m) continue;
    const b = /^[a-z_]+@(\d{1,9})$/.exec(String(r.since ?? ""));
    const entry = {
      stage: m[1], detail: m[2] ?? null, batch: b ? Number(b[1]) : null, at: r.at,
      key: r.key ?? null, project: r.project ?? null,
    };
    payload.prs[`${r.repo}#${r.number}`] = entry;
    if (entry.stage === "queued" && /^[0-9]{1,9}$/.test(entry.detail ?? "")) {
      waiting.push({ repo: r.repo, pr: r.number, position: Number(entry.detail), at: r.at, key: entry.key });
    }
  }
  waiting.sort((a, b) => a.position - b.position || String(a.at).localeCompare(String(b.at)));
  payload.waiting = waiting;
}

export async function applyStages(env, payload, { repo } = {}) {
  if (!Array.isArray(payload.waiting)) payload.waiting = [];
  if (!payload.prs || typeof payload.prs !== "object") payload.prs = {};
  if (Array.isArray(payload.batches) && payload.batches.length) await applyBatchStages(env, payload);
  await applyPrs(env, payload, repo);
  return payload;
}
