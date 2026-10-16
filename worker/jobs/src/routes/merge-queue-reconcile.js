// merge-queue-reconcile routes — BH-5670 (BH-5008 child 4): the reconciler
// against Mergify's merge-queue API. bin/merge-queue-reconcile.sh (hub, every
// 2 min) is the one caller:
//
//   GET  /api/merge-queue/reconcile  the repos with an active row, each active
//        PR's current stage, and the per-tick repo cap. Active = an open
//        merge_queue_batches row, or a PR whose newest state='queue' row is not
//        merged / deploy_verified / dequeued, both from the last 24 h.
//   POST /api/merge-queue/reconcile  {answers:[{repo, status}]}, `status` the
//        raw merge-queue/status JSON Mergify answered for that repo. Where the
//        newest stage row disagrees with Mergify, one corrective row through
//        queueStageStmt, actor 'reconcile'; Mergify's estimated_time_of_merge
//        goes into merge_queue_batches.eta_at.
//
// What the POST never does (D11): a PR missing from Mergify's answer gets no
// row (absence is not proof of merged), a batch code outside
// MERGIFY_BATCH_CODES gets no row and is listed in `unknown_codes`, and a PR
// whose newest row is merged or deploy_verified is never walked back. A
// corrective row's `since` is `reconcile:<id of the row it corrects>`, so a
// repeat or an overlapping run is one row through idx_pr_state_events_dedupe,
// and live-stages' `<word>@<draft>` batch reading never matches it.
//
// Docs: docs/notes/2026-10-10-BH-5670-merge-queue-reconcile.md.

import { json, d1Guarded } from "../lib/http.js";
import { WAKE_REPO_RE } from "../lib/core.js";
import { queueStageStmt } from "../lib/merge-queue-stage.js";

const WINDOW_S = 24 * 3600;
const PR_CAP = 500;
const BATCH_CAP = 500;
const CAP_DEFAULT = 10;
const ANSWERS_MAX = 50;
const BATCHES_MAX = 100;
const WAITING_MAX = 500;
const IN_CHUNK = 90;
const TERMINAL = ["merged", "deploy_verified", "dequeued"];
const NEVER_BACK = ["merged", "deploy_verified"];

// Mergify batch status.code → our stage word. A vendor vocabulary, not a
// business parameter. `failed` and any code not listed map to nothing.
export const MERGIFY_BATCH_CODES = Object.freeze({
  running: "checking",
  bisecting: "checking",
  preparing: "batched",
  waiting_for_batch: "batched",
  waiting_for_previous_batches: "batched",
  waiting_schedule: "batched",
  frozen: "batched",
  waiting_for_merge: "merging",
  merging: "merging",
  merged: "merged",
});

const isoS = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const wordOf = (reason) => /^([a-z_]{1,32})(?: \(|$)/.exec(String(reason ?? ""))?.[1] ?? null;
const prOk = (n) => Number.isInteger(n) && n > 0 && n < 1e9;
const STAGE_WORD_SQL = `CASE WHEN instr(e.reason, ' ') > 0 THEN substr(e.reason, 1, instr(e.reason, ' ') - 1) ELSE e.reason END`;

async function capOf(env) {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key = 'merge_queue_reconcile_repos'`).first();
  const raw = row ? String(row.value).trim() : "";
  const n = /^[0-9]{1,9}$/.test(raw) ? Number(raw) : NaN;
  return Number.isInteger(n) && n > 0 ? { cap: n, source: "setting" } : { cap: CAP_DEFAULT, source: "default" };
}

function membersOf(raw) {
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v.filter(prOk) : [];
  } catch { return []; }
}

// → { repos: Map<lower repo, {repo, prs:[…], batches:[…]}>, complete }
async function activeOf(env, t) {
  const cutoff = isoS(Date.parse(t) - WINDOW_S * 1000);
  // sql-ident-ok: STAGE_WORD_SQL is a module const CASE expression; the IN list is ?N placeholders over the TERMINAL const
  const pr = await env.DB.prepare(
    `SELECT e.id, e.repo, e.number, e.reason, e.at FROM pr_state_events e
      WHERE e.state = 'queue' AND e.at >= ?1
        AND e.id = (SELECT MAX(id) FROM pr_state_events x WHERE x.repo = e.repo AND x.number = e.number AND x.state = 'queue')
        AND ${STAGE_WORD_SQL} NOT IN (${TERMINAL.map((_, i) => `?${i + 2}`).join(",")})
      ORDER BY e.id DESC LIMIT ?${TERMINAL.length + 2}`
  ).bind(cutoff, ...TERMINAL, PR_CAP + 1).all();
  const bt = await env.DB.prepare(
    `SELECT repo, draft_pr, members_json FROM merge_queue_batches
      WHERE finished_at IS NULL AND COALESCE(started_at, updated_at) >= ?1 ORDER BY draft_pr LIMIT ?2`
  ).bind(cutoff, BATCH_CAP + 1).all();
  const prRows = pr.results || [];
  const btRows = bt.results || [];
  const repos = new Map();
  const slot = (repo) => {
    const k = String(repo).toLowerCase();
    if (!repos.has(k)) repos.set(k, { repo: String(repo), prs: [], batches: [] });
    return repos.get(k);
  };
  for (const r of prRows.slice(0, PR_CAP)) {
    slot(r.repo).prs.push({ pr: r.number, stage: wordOf(r.reason), reason: r.reason, at: r.at });
  }
  for (const b of btRows.slice(0, BATCH_CAP)) {
    slot(b.repo).batches.push({ draft: b.draft_pr, repo: b.repo, members: membersOf(b.members_json) });
  }
  for (const v of repos.values()) v.prs.sort((a, b) => a.pr - b.pr);
  return { repos, complete: prRows.length <= PR_CAP && btRows.length <= BATCH_CAP };
}

// The newest state='queue' row of each PR in `prs` on `repo`, any age.
async function newestOf(env, repo, prs) {
  const out = new Map();
  for (let i = 0; i < prs.length; i += IN_CHUNK) {
    const part = prs.slice(i, i + IN_CHUNK);
    // sql-ident-ok: the IN list is ?N placeholders built from the part index; repo and numbers bind
    const res = await env.DB.prepare(
      `SELECT e.id, e.number, e.reason FROM pr_state_events e
        WHERE e.state = 'queue' AND lower(e.repo) = lower(?1) AND e.number IN (${part.map((_, j) => `?${j + 2}`).join(",")})
          AND e.id = (SELECT MAX(id) FROM pr_state_events x WHERE x.repo = e.repo AND x.number = e.number AND x.state = 'queue')`
    ).bind(repo, ...part).all();
    for (const r of res.results || []) {
      const cur = out.get(r.number);
      if (!cur || r.id > cur.id) out.set(r.number, { id: r.id, reason: r.reason });
    }
  }
  return out;
}

// A structural error in the body → the 400 message; else null.
function badBody(body) {
  const answers = body && body.answers;
  if (!Array.isArray(answers)) return "answers must be an array";
  if (answers.length > ANSWERS_MAX) return `answers: at most ${ANSWERS_MAX}`;
  for (let i = 0; i < answers.length; i += 1) {
    const a = answers[i];
    if (!a || typeof a !== "object" || !WAKE_REPO_RE.test(String(a.repo ?? ""))) return `answers[${i}].repo must be owner/name`;
    const st = a.status;
    if (!st || typeof st !== "object" || Array.isArray(st)) continue;
    if (st.batches !== undefined && (!Array.isArray(st.batches) || st.batches.length > BATCHES_MAX)) {
      return `answers[${i}].status.batches: an array of at most ${BATCHES_MAX}`;
    }
    if (st.waiting_pull_requests !== undefined
      && (!Array.isArray(st.waiting_pull_requests) || st.waiting_pull_requests.length > WAITING_MAX)) {
      return `answers[${i}].status.waiting_pull_requests: an array of at most ${WAITING_MAX}`;
    }
  }
  return null;
}

// Mergify's answer → Map<pr, target stage>. A waiting PR is `queued (<n>)`;
// a batch member takes the batch code's stage and wins over a waiting entry;
// a member of a batch with an unmapped code has no target at all.
function targetsOf(st, unknown) {
  const targets = new Map();
  (st.waiting_pull_requests || []).forEach((w, i) => {
    const n = w && w.number;
    if (prOk(n) && !targets.has(n)) targets.set(n, `queued (${i + 1})`);
  });
  for (const b of st.batches || []) {
    const code = String((b && b.status && b.status.code) ?? "");
    const stage = Object.hasOwn(MERGIFY_BATCH_CODES, code) ? MERGIFY_BATCH_CODES[code] : null;
    if (!stage) unknown.add(code.slice(0, 64));
    for (const p of (b && Array.isArray(b.pull_requests) ? b.pull_requests : [])) {
      const n = p && p.number;
      if (!prOk(n)) continue;
      if (stage) targets.set(n, stage); else targets.delete(n);
    }
  }
  return targets;
}

async function reconcile(env, body, t) {
  const err = badBody(body);
  if (err) return json(400, { error: err });
  const act = await activeOf(env, t);
  const out = {
    written: 0, unchanged: 0, absent: 0, skipped_inactive: 0, skipped_malformed: 0,
    eta_set: 0, eta_unmatched: 0, unknown_codes: [], complete: act.complete,
  };
  const unknown = new Set();
  const stmts = [];
  const kinds = [];
  for (const a of body.answers) {
    const entry = act.repos.get(String(a.repo).toLowerCase());
    if (!entry) { out.skipped_inactive += 1; continue; }
    const st = a.status;
    if (!st || typeof st !== "object" || Array.isArray(st)) { out.skipped_malformed += 1; continue; }
    const targets = targetsOf(st, unknown);
    out.absent += entry.prs.filter((p) => !targets.has(p.pr)).length;
    const newest = await newestOf(env, entry.repo, [...targets.keys()]);
    for (const [pr, target] of targets) {
      const prev = newest.get(pr);
      const prevWord = prev ? wordOf(prev.reason) : null;
      const word = wordOf(target);
      if (NEVER_BACK.includes(prevWord)
        || (word === "queued" ? prev && prev.reason === target : prevWord === word)) {
        out.unchanged += 1;
        continue;
      }
      const stage = word === "queued" ? target : `${target} (reconcile: was ${prevWord ?? "none"})`;
      stmts.push(queueStageStmt(env.DB, {
        repo: entry.repo, pr, stage, since: `reconcile:${prev ? prev.id : 0}`, at: t, actor: "reconcile",
      }));
      kinds.push("stage");
    }
    for (const b of st.batches || []) {
      const ms = Date.parse(b && b.estimated_time_of_merge);
      if (!b || b.estimated_time_of_merge == null || !Number.isFinite(ms)) continue;
      const set = [...new Set((Array.isArray(b.pull_requests) ? b.pull_requests : []).map((p) => p && p.number).filter(prOk))].sort((x, y) => x - y);
      const key = set.join(",");
      const hits = entry.batches.filter((ob) => [...new Set(ob.members)].sort((x, y) => x - y).join(",") === key);
      if (!set.length || hits.length !== 1) { out.eta_unmatched += 1; continue; }
      stmts.push(env.DB.prepare(
        `UPDATE merge_queue_batches SET eta_at = ?1, updated_at = ?2
          WHERE repo = ?3 AND draft_pr = ?4 AND finished_at IS NULL AND eta_at IS NOT ?1`
      ).bind(isoS(ms), t, hits[0].repo, hits[0].draft));
      kinds.push("eta");
    }
  }
  if (stmts.length) {
    const res = await env.DB.batch(stmts);
    res.forEach((r, i) => {
      const n = Number((r && r.meta && r.meta.changes) || 0);
      if (kinds[i] === "stage") { if (n > 0) out.written += n; else out.unchanged += 1; }
      else out.eta_set += n;
    });
  }
  out.unknown_codes = [...unknown].sort();
  return json(200, out);
}

export const routes = [
  [
    "GET", "/api/merge-queue/reconcile",
    async ({ env, t }) => d1Guarded("merge_queue_batches/pr_state_events", async () => {
      const act = await activeOf(env, t);
      const cap = await capOf(env);
      const repos = [...act.repos.values()]
        .sort((a, b) => a.repo.localeCompare(b.repo))
        .map((r) => ({ repo: r.repo, prs: r.prs }));
      return json(200, { repos, cap: cap.cap, cap_source: cap.source, complete: act.complete, as_of: t });
    }),
  ],
  [
    "POST", "/api/merge-queue/reconcile",
    async ({ env, body, t }) => d1Guarded("merge_queue_batches/pr_state_events", () => reconcile(env, body, t)),
  ],
];
