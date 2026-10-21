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

// One row per PR that has any gate row in `repo`. approved_at is the EARLIEST
// `at` among that PR's gate rows carrying the current approve sha, so a
// reconcile re-send of the same approve does not make the PR look newer.
//
// ONE statement per call, folded here (BH-7764, Sentry CROMFORD-HARNESS-1P).
// The old SQL ran a correlated subquery per field per PR (14 x N), which kept
// D1 busy long enough to answer "overloaded". This is one range read on
// idx_pr_state_events_gate (repo, state, number, id): equality on repo and
// state, rows already in (number, id) order, so no temp b-tree.
const FOLDED = [...GATE_FIELDS, "url"];

export async function gateFacts(env, { repo }) {
  await ready(env);
  // sql-ident-ok: column names come from the GATE_FIELDS constant
  const res = await env.DB.prepare(
    `SELECT number, at, ${FOLDED.join(", ")} FROM pr_state_events
      WHERE repo=?1 AND state='gate' ORDER BY number, id`
  ).bind(repo).all();
  const out = [];
  let i = 0;
  const rows = res.results || [];
  while (i < rows.length) {
    const number = rows[i].number;
    let j = i;
    while (j < rows.length && rows[j].number === number) j++;
    const pr = rows.slice(i, j);
    const fact = { repo, number };
    for (const f of FOLDED) {
      let v = null;
      for (const r of pr) if (r[f] !== null && r[f] !== undefined) v = r[f];
      fact[f] = v;
    }
    // SQL `= NULL` matches nothing, so a null approve sha has no approved_at.
    let approvedAt = null;
    if (fact.builder_approved_sha !== null) {
      for (const r of pr) {
        if (r.builder_approved_sha === fact.builder_approved_sha && (approvedAt === null || r.at < approvedAt)) approvedAt = r.at;
      }
    }
    fact.approved_at = approvedAt;
    out.push(fact);
    i = j;
  }
  return out;
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
