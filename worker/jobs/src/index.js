// harness-jobs — coordination truth for the box fleet (phase 1).
// Spec: docs/DB-COORDINATION-SPEC.md (approved by the operator, 2026-08-27).
//
// Jobs, stage events and lane budgets live in ONE D1 database that the hub,
// every watcher box and every ephemeral fly builder reads over HTTPS. That
// kills three classes by construction:
//   * double-build — in-flight work on box A is invisible to box B, so both
//     build the same ticket. POST /api/jobs 409s the second claimant.
//   * budget-config — catalog/context-budgets.json never lands on a fly
//     builder (fly-sync tars bin/prompts/rules only), so build lanes fell
//     through to the hardcoded tier and budget-stopped mid-run (TK-109, $424).
//     GET /api/catalog/:lane answers from the DB, no file needed.
//   * split-brain flags — phase 3: pause flags are rows the console can set,
//     and the box files they drive stay the thing every existing reader tests.
//   * silent deaths — phase 3: a claimant heartbeats its row, so a SIGKILLed
//     run leaves an ORPHANED row with a last-beat time instead of nothing.
//   * unattributable failures — phase 5: a job row said "failed" and nothing
//     said WHICH stage failed. job_phases records one row per stage attempt
//     (runner, rc, spend, note), as a CHILD of the claim — coordination stays
//     per JOB, so no stage ever re-asks permission to continue.
//   * collisions the code could not describe — phase 6: the concurrency rules
//     are ROWS, checked INSIDE the claim, so "one build per repo" is an UPDATE
//     and not a deploy. No row for a scope means unlimited.
//   * failures with no defined end — phase 6: a dead claim is JUDGED against a
//     per-lane retry policy and lands in exactly one terminal state
//     (queued_for_retry / parked / orphaned). The watchdog asks; it never runs
//     anything, and the lane's own next tick picks a queued row up.
//   * done with nothing to show for it — phase 7: a phase declares the ARTIFACT
//     it must produce (phase_contracts) and cannot close `done` without it; the
//     close lands as `contract_unmet` instead, naming what was missing.
//   * histories that cannot be true — phase 7: status moves are checked against
//     a transition graph, so `done` never walks back to `running` and a parked
//     job cannot skip to done without going through an attempt.
//   * a pause that only reached the boxes that asked — phase 7: pause_flags are
//     consulted INSIDE the claim, so a paused project stops a fly builder that
//     has never reconciled a file in its life. The file stays the fallback.
//
// Iron constraints held here: additive-only schema, no secret ever written to a
// row (meta included), and boxes authenticate with HARNESS_SECRET alone — no
// Cloudflare credential ever leaves the hub.
//
// The DB is COORDINATION truth, not BUILD truth. PRs, board comments and
// ALERTS.log remain the client-facing record; nothing here replaces them.
//
// ── HOW A REQUEST FINDS ITS HANDLER (BH-1195) ──────────────────────────────
// This file used to hold every route body too: one flat
// `if (path === … && req.method === …)` chain, 3,497 lines of it inside
// `fetch`. It is now the ENTRY and nothing else. Each route family lives in
// ./routes/<family>.js and exports an ordered list of
// `[method, matcher, handler]` rows, and ./lib/router.js resolves the rows
// first-match-wins.
//
// A GATED FAMILY IS A MODULE PLUS A FRAGMENT, NEVER AN EDIT HERE (BH-4607).
// ROUTES is the `routes` lists of the families in test/route-table.d, in
// fragment-name order (<NNN>-<family>.txt; the number is the place in the
// table). It comes from "#routes": under wrangler that is the git-ignored
// ./routes.gen.js, which wrangler.jsonc's build.command renders with
// scripts/routes-build.mjs, and under node it is test/lib/routes.node.js,
// which reads the same fragments at load time. test/route-registry.bh-4607.test.js
// fails if a gated import or spread comes back to this file.
//
// THE ORDER IS LOAD-BEARING. `GET /api/jobs/:id` sits above `GET /api/jobs`
// and `GET /api/settings` above the `/api/settings/` prefix, exactly as the
// chain had them; re-numbering a fragment out of that order would re-point
// routes.
// test/route-table.test.js holds the pre-split chain as a fixture and compares
// the table against it, entry for entry, in order.
//
// THE BEARER STILL SITS BETWEEN THE TWO TABLES. OPEN_ROUTES is consulted
// FIRST and holds eight routes. Three are POST /webhooks/github, /webhooks/jira
// and /webhooks/linear (BH-4079). No vendor can send our bearer, so each carries
// its own HMAC, keyed on its own secret, instead. Two are POST and GET
// /api/ci/suite-durations (BH-5653). CI must not hold HARNESS_SECRET, so they
// check their own scoped bearer: CI_DURATIONS_TOKEN or HARNESS_SECRET. Three are
// the suite-ledger routes (BH-5366), for the same reason: each authenticates
// itself with credentialClass() (bearer or x-suite-ledger-token) before it reads
// the body. Everything
// in ROUTES is reached only after `bearerOk`, so a route in the wrong table is
// a route with the wrong credential.
import { bearerOk, json, nowIso, readBody } from "./lib/http.js";
import { CREATED_TABLES, MACHINE_STATES, MACHINE_TERMINAL } from "./lib/core.js";
import { matchRoute } from "./lib/router.js";
import { ROUTES } from "#routes";
import { withHarnessSentry } from "./lib/sentry.js";
import { retryingDb } from "./lib/d1-retry.js";

import { routes as webhooks } from "./routes/webhooks.js";
import { routes as suiteResults } from "./routes/suite-results.js";
import { routes as ciDurations } from "./routes/ci-durations.js";
import { routes as ciTestTiers } from "./routes/ci-test-tiers.js";

// The names this module has always exported. They live in ./lib/core.js now;
// console-ui, the tests and bin/ read them from here, so here is where they
// stay re-exported — a split is not a reason for a caller to change an import.
export {
  decorateLane, decorateLease, doraRepo, doraPrNumber, percentile,
  doraDeployRepo, computeDora, ANCHOR_DEFAULT_ACCOUNT_MAP,
  ANCHOR_DEFAULT_MAX_FACTOR, ANCHOR_OFF_FLAG, parseAccountMap, parseBuildDir,
  parseStageBreakdown, anchorWindow, meterAccounts, anchorSpanCandidates,
  computeAnchored,
} from "./lib/core.js";

// BH-1068: the alerts slice's schema suite drives ensureTable() off index.js
// and compares CREATED_TABLES.alerts with schema.sql, so both names are
// re-exported here — the same rule as the block above: a split is not a reason
// for a caller to change an import.
export { ensureTable } from "./lib/core.js";
export { CREATED_TABLES };
// ...and the pure decision function the alerts note route is built on, which
// its own suite drives at the boundaries without a database.
export { alertDecision } from "./routes/alerts.js";

// The routes the main bearer does not open. The three webhooks are matched on
// PATH ALONE (method "*"), so a GET reaches each and gets its 405 instead of
// falling through to a 401 that would tell an operator the hook was
// unauthorised rather than misused. The two ci-durations routes (BH-5653) are
// matched on method and path, and each checks its own scoped bearer
// (CI_DURATIONS_TOKEN or HARNESS_SECRET) before it reads anything. So do the
// two ci-test-tiers routes (BH-5653 C1); their PUT takes HARNESS_SECRET only.
// The three suite-ledger routes (BH-5366) each make their own credential check
// before they read anything.
export const OPEN_ROUTES = [...webhooks, ...ciDurations, ...ciTestTiers, ...suiteResults];

// Every other route: the gated families, in test/route-table.d fragment order.
// "#routes" builds the table (see HOW A REQUEST FINDS ITS HANDLER above).
export { ROUTES };

export default withHarnessSentry({
  CREATED_TABLES,
  MACHINE_STATES,
  MACHINE_TERMINAL,
  ROUTES,
  OPEN_ROUTES,
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname;
    // The server clock, taken ONCE per request and shared by every route. It is
    // hoisted above the bearer check because the /webhooks/* routes run before that
    // check and stamps rows with it; two clocks in one request would put two
    // different minutes on the dedupe key of a single delivery.
    const t = nowIso();
    // BH-6690: every D1 call retries a "D1 DB is overloaded" rejection.
    if (env && env.DB) env = { ...env, DB: retryingDb(env.DB) };

    // The open table first, and it never sees `body`: the raw TEXT is what the
    // webhook's signature covers, and re-serialising a parsed object would
    // verify a different string than the one that was signed.
    const open = matchRoute(OPEN_ROUTES, req.method, path);
    if (open) return open.handler({ req, env, url, path, t, m: open.m });

    if (!bearerOk(req, env)) return json(401, { error: "unauthorized" });

    const body = await readBody(req);

    const hit = matchRoute(ROUTES, req.method, path);
    if (hit) return hit.handler({ req, env, url, path, t, body, m: hit.m });

    // `worker` is this worker's identity on the one answer a client has to
    // tell apart from somebody else's 404 (BH-1525): bin/lib/verdicts.sh reads
    // THIS body as "the route is not deployed here", and any other 404 — a
    // Cloudflare 1042 for a deleted host, a proxy, an HTML page — as unknown.
    return json(404, { error: "unknown endpoint", worker: "harness-jobs" });
  },
}, { worker: "harness-jobs", pauseFlags: true });
