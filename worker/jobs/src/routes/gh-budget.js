// gh-budget routes — the GitHub API budget.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
//
// BH-7510 changed what they answer on a D1 overload give-up (Sentry
// CROMFORD-HARNESS-11): it was an uncaught throw, a 500 with no body. Now GET
// serves the isolate's cached row (at most GH_BUDGET_STALE_MAX_MS old) as
// `stale: true`, else both routes answer 503 + Retry-After. Every other error
// still throws, so withSentry still reports it.

import { json, d1OverloadGuarded } from "../lib/http.js";
import { isD1Overloaded } from "../lib/d1-retry.js";
import {
  intOrNull, strictInt, str, ensureTable, laneName, leaseWon, ghBudgetRow, ghBudgetCached,
} from "../lib/core.js";

// The oldest cached row GET serves during an overload. The client still applies
// its own max age to `row.fetched_at` (bin/lib/jobs/machines.sh gh_budget_row_get).
export const GH_BUDGET_STALE_MAX_MS = 120000;
export const GH_BUDGET_RETRY_AFTER_S = "2";

// d1OverloadGuarded's 503, plus the Retry-After header. A 503 here means the
// write never ran (D1 rejects at the queue) or ran idempotently: the client's
// one retry (bin/lib/jobs/req.sh) re-sends the same row, and the monotonic
// upsert writes the same values for the same fetched_at.
async function overloadGuarded(label, fn) {
  const res = await d1OverloadGuarded("gh_budget", fn, label);
  if (res.status === 503) res.headers.set("retry-after", GH_BUDGET_RETRY_AFTER_S);
  return res;
}

export const routes = [
  // ── SHARED FACTS: THE GITHUB BUDGET (BH-1043) ──────────────────────────
  // One row per TOKEN fingerprint, never per box. The upsert is MONOTONIC on
  // fetched_at: a slow box's older reading arriving late must not raise
  // `remaining` back up, or every lane reads a countdown that goes backwards
  // and the low-budget guard never fires.
  [
    "POST", "/api/gh-budget",
    async ({ env, t, body }) => overloadGuarded("POST", async () => {
      const fp = laneName(body.fingerprint);
      if (!fp) return json(400, { error: "fingerprint is required and must match [A-Za-z0-9._-]{1,64}" });
      const fetched = strictInt(body.fetched_at);
      if (fetched === null || fetched < 0) {
        return json(400, { error: "fetched_at must be a non-negative integer (epoch seconds)" });
      }
      const core = (body.core && typeof body.core === "object") ? body.core : {};
      const gql = (body.graphql && typeof body.graphql === "object") ? body.graphql : {};
      await ensureTable(env, "gh_budget");
      const r = await env.DB.prepare(
        "INSERT INTO gh_budget (fingerprint, core_remaining, core_limit, core_reset, "
        + "graphql_remaining, graphql_limit, graphql_reset, fetched_at, box, updated_at) "
        + "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) "
        + "ON CONFLICT(fingerprint) DO UPDATE SET core_remaining=excluded.core_remaining, "
        + "core_limit=excluded.core_limit, core_reset=excluded.core_reset, "
        + "graphql_remaining=excluded.graphql_remaining, graphql_limit=excluded.graphql_limit, "
        + "graphql_reset=excluded.graphql_reset, fetched_at=excluded.fetched_at, "
        + "box=excluded.box, updated_at=excluded.updated_at "
        + "WHERE excluded.fetched_at >= gh_budget.fetched_at"
      ).bind(
        fp, intOrNull(core.remaining), intOrNull(core.limit), intOrNull(core.reset),
        intOrNull(gql.remaining), intOrNull(gql.limit), intOrNull(gql.reset),
        fetched, str(body.box, 64), t
      ).run();
      // fresh: the answer must show this write, and it refreshes the cache.
      return json(200, { wrote: leaseWon(r), row: await ghBudgetRow(env, fp, { fresh: true }), as_of: t });
    }),
  ],

  [
    "GET", "/api/gh-budget",
    async ({ env, url, t }) => overloadGuarded("GET", async () => {
      const fp = laneName(url.searchParams.get("fingerprint"));
      if (!fp) return json(400, { error: "fingerprint is required and must match [A-Za-z0-9._-]{1,64}" });
      // ALWAYS 200 with `row: null` when nothing is stored: the client treats a
      // 404 as an outage, and "no reading yet" is not an outage — it is the
      // normal state of the first box to ask after a deploy.
      try {
        await ensureTable(env, "gh_budget");
        return json(200, { row: await ghBudgetRow(env, fp), as_of: t });
      } catch (e) {
        // Only an overload give-up falls back; the guard answers 503 when
        // no cached row is young enough, and any other error rethrows.
        if (!isD1Overloaded(e)) throw e;
        const c = ghBudgetCached(env, fp, GH_BUDGET_STALE_MAX_MS);
        if (!c) throw e;
        const cachedAt = new Date(c.at).toISOString().replace(/\.\d{3}Z$/, "Z");
        console.warn(`d1-overload: gh_budget GET served a stale row (cached_at ${cachedAt}) after ${e.d1Attempts ?? "?"} attempt(s)`);
        return json(200, { row: c.row, as_of: t, stale: true, cached_at: cachedAt });
      }
    }),
  ],
];
