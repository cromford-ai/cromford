// PR gate facts (BH-4953 / BH-4950.0) — the substrate of "needs lead review".
//
// A gate fact is one `pr_state_events` row with state='gate' that carries only
// the fields its writer knew. NULL is "no news", never "false", so the facts
// FOLD per field: the latest non-null value by id, per (repo, number). The
// `pr_state` view cannot answer this — it is MAX(id) per PR, so the newest row
// would blank every fact it did not carry.
//
// Column names are interpolated, so they only ever come from GATE_FIELDS
// below, never from a request; every value is bound.

import { ensureColumns, ensureTable } from "./core.js";

export const GATE_FIELDS = [
  "head", "draft", "closed", "held", "hotfix", "ci_green_sha", "builder_approved_sha",
  "lead_verdict_sha", "lead_verdict_word", "reviewing_sha", "review_failed_sha", "nudged_sha",
];
export const INT_FIELDS = ["draft", "closed", "held", "hotfix"];
export const SHA_FIELDS = ["head", "ci_green_sha", "builder_approved_sha", "lead_verdict_sha",
  "reviewing_sha", "review_failed_sha", "nudged_sha"];

async function ready(env) {
  await ensureTable(env, "pr_state_events");
  await ensureColumns(env, "pr_state_events");
}

// ev = {repo, number, source, reason, actor, url?, ...fields}, already
// validated by the caller. `since` is the source, so a replayed delivery
// collides on idx_pr_state_events_dedupe and is a duplicate, not a second row.
export async function recordGateEvent(env, t, ev) {
  await ready(env);
  const cols = ["repo", "number", "state", "since", "alerted", "at", "reason", "actor", "url"];
  const vals = [ev.repo, ev.number, "gate", ev.source, "-", t, ev.reason ?? null, ev.actor ?? null, ev.url ?? null];
  for (const f of GATE_FIELDS) {
    if (ev[f] !== undefined && ev[f] !== null) { cols.push(f); vals.push(ev[f]); }
  }
  // sql-ident-ok: cols are literals plus names from the GATE_FIELDS constant; values are ?N text
  const res = await env.DB.prepare(
    `INSERT INTO pr_state_events (${cols.join(", ")}) VALUES (${cols.map((_, i) => `?${i + 1}`).join(",")})
     ON CONFLICT DO NOTHING`
  ).bind(...vals).run();
  return { recorded: !!res.meta.changes };
}

const latest = (f) =>
  `(SELECT e.${f} FROM pr_state_events e WHERE e.repo=p.repo AND e.number=p.number
     AND e.state='gate' AND e.${f} IS NOT NULL ORDER BY e.id DESC LIMIT 1) AS ${f}`;

// One row per PR that has any gate row in `repo`. approved_at is the EARLIEST
// `at` among that PR's gate rows carrying the current approve sha, so a
// reconcile re-send of the same approve does not make the PR look newer.
export async function gateFacts(env, { repo }) {
  await ready(env);
  // sql-ident-ok: latest() reads names from the GATE_FIELDS constant
  const rows = await env.DB.prepare(
    `SELECT f.*, (SELECT MIN(e.at) FROM pr_state_events e WHERE e.repo=f.repo AND e.number=f.number
                    AND e.state='gate' AND e.builder_approved_sha=f.builder_approved_sha) AS approved_at
       FROM (SELECT p.repo, p.number, ${[...GATE_FIELDS, "url"].map(latest).join(", ")}
               FROM (SELECT DISTINCT repo, number FROM pr_state_events WHERE state='gate' AND repo=?1) p) f
      ORDER BY f.number`
  ).bind(repo).all();
  return rows.results || [];
}

export async function needsReviewRows(env, { repo, limit }) {
  const facts = await gateFacts(env, { repo });
  const nudged = (r) => (r.nudged_sha === r.head ? 1 : 0);
  return facts
    .filter((r) => r.closed !== 1 && r.draft !== 1 && r.held !== 1 && r.head
      && r.head === r.builder_approved_sha && r.head === r.ci_green_sha
      && r.lead_verdict_sha !== r.head && r.review_failed_sha !== r.head)
    .sort((a, b) => nudged(b) - nudged(a)
      || (b.hotfix === 1) - (a.hotfix === 1)
      || String(a.approved_at).localeCompare(String(b.approved_at))
      || a.number - b.number)
    .slice(0, limit)
    .map((r) => ({
      repo: r.repo, number: r.number,
      url: r.url || `https://github.com/${r.repo}/pull/${r.number}`,
      head: r.head, hotfix: r.hotfix === 1 ? 1 : 0, nudged: nudged(r), approved_at: r.approved_at,
    }));
}
