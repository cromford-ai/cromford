// verdict routes — the verdict lookup bin/merge-sweep.sh reads.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { isD1Overloaded } from "../lib/d1-retry.js";
import { captureException } from "../lib/sentry.js";
import { recordGiveUp } from "../lib/d1-giveup.js";

// BH-1024: WHICH JOB IS A PR'S LEDGER IDENTITY.
//
// `pr_url` is the only key the fleet has for "the verdict on this PR", and it
// was resolved by the newest artifact alone — fine while ONE job per PR wrote
// it. THREE jobs can now write it for one reviewed head, and they are written
// within a second of each other on a single bin/review-prs.sh tick:
//
//   1. the BUILD that opened the PR (`kind='build'`, `source:"run-build"`);
//   2. the REVIEW LANE claim, `kind='review'`, opened per (PR, sha) by
//      `review_claim` — the BH-1064 block writes the RAW `APPROVE` /
//      `REQUEST_CHANGES` onto it in a detail with NO `source`;
//   3. the short-lived `review-verdict` job this ticket's block opens, which is
//      the only row carrying `source:"review-prs"`, `served_by` and the ledger's
//      BLOCK vocabulary.
//
// A carve-out that named only `review-verdict` therefore answered (2) on every
// single tick: the lane row is not a build, is not a review-verdict, and is
// newer than the build's. That cost both directions at once — a harness PR's
// build verdict became unreachable (the disagreeing pair parks it permanently:
// `sweep_record … parked` is terminal), and an external PR answered with no
// `source`, so `job_verdict_covers <pr> <sha> review-prs` could never return 0
// and bin/review-autopilot.sh's skip was dead code in production.
//
// So the rule is a RANKING, in ONE query, and it is a tie-break rather than a
// filter — every row stays reachable when it is the only one:
//   a BUILD's row first   — the job that made the change owns its verdict;
//   then `review-verdict` — the row that carries the review lane's provenance;
//   then newest           — everything else, exactly as before.
// `COALESCE(j.kind,'')` and the LEFT JOIN keep an artifact whose job row is
// missing findable (it ranks last, which is what an orphan deserves), and
// `a.job_id DESC` is the final tie-break so two rows stamped in the same second
// resolve the same way on every read.
export async function prLedgerJob(db, pr) {
  const hit = await db.prepare(
    `SELECT a.* FROM job_artifacts a LEFT JOIN jobs j ON j.id=a.job_id
      WHERE a.artifact_kind='pr_url' AND a.artifact_ref=?1
      ORDER BY (COALESCE(j.kind,'')='build') DESC,
               (COALESCE(j.kind,'')='review-verdict') DESC,
               a.updated_at DESC, a.job_id DESC
      LIMIT 1`
  ).bind(pr).first();
  if (!hit) return { hit: null, job: null };
  const job = await db.prepare("SELECT * FROM jobs WHERE id=?1").bind(hit.job_id).first();
  return { hit, job: job || null };
}

// BH-6807: THE GIVE-UP ANSWER. lib/d1-retry.js tries a "D1 DB is
// overloaded" rejection D1_RETRY_ATTEMPTS times and then rethrows it. Out of a route, that
// rethrow left the worker as a 500 with no body, and bin/lib/jobs/req.sh
// (BH-5781) retries only a 503 whose body says "overloaded". So a verdict route
// that gives up answers exactly that: 503 {error, retryable:true, d1_attempts}
// and one warn line. Every other error rethrows unchanged. A 404 is NOT the
// answer here: a reader takes it as a real ledger miss.
//
// BH-7541: a single give-up is a transient the caller retries, so it sends no
// Sentry event. recordGiveUp (lib/d1-giveup.js) upserts the route's streak in
// one statement, and only every Nth give-up of a streak (default 3) sends one
// event, tagged d1_giveups and d1_route next to d1_attempts and d1_op.
async function overloadGiveUp(env, route, t, fn) {
  try {
    return await fn();
  } catch (e) {
    if (!isD1Overloaded(e)) throw e;
    const g = await recordGiveUp(env, route, t);
    console.warn(`harness-jobs: ${route} gave up on D1 overload after ${e.d1Attempts ?? "?"} attempt(s), streak ${g.consecutive}: ${e.message}`);
    e.d1GiveUps = g.consecutive;
    e.d1Route = route;
    if (g.report) await captureException(e, env);
    return json(503, {
      error: String(e.message), retryable: true,
      d1_attempts: typeof e.d1Attempts === "number" ? e.d1Attempts : null,
    });
  }
}

export const routes = [
  // ── Phase 7: the verdict lookup bin/merge-sweep.sh reads ───────────────
  // Given a PR url, the job that produced it and every artifact on that job.
  // ONE round trip on purpose: the sweep runs every ten minutes over a
  // directory of build records and must not pay three calls per PR to learn
  // what it can already scrape from a file. A 404 is a REAL answer — "no job
  // recorded this PR" — which the sweep maps to today's build-record
  // scraping, byte for byte.
  [
    "GET", "/api/verdict",
    async ({ env, url, t }) => overloadGiveUp(env, "GET /api/verdict", t, async () => {
      const pr = (url.searchParams.get("pr") || "").trim();
      if (!pr) return json(400, { error: "pr required" });
      // BH-1024: prLedgerJob, not the bare newest pr_url — a review-prs
      // `review-verdict` row must not become the standing verdict of a PR that
      // has a build.
      const { hit, job } = await prLedgerJob(env.DB, pr);
      if (!hit) return json(404, { error: "no job has recorded this PR" });
      const rows = await env.DB.prepare(
        "SELECT * FROM job_artifacts WHERE job_id=?1 ORDER BY artifact_kind ASC"
      ).bind(hit.job_id).all();
      const artifacts = rows.results || [];
      const byKind = {};
      for (const a of artifacts) byKind[a.artifact_kind] = a;
      const v = byKind.verdict || null;
      // The detail rides as JSON when the writer had it, but a caller that
      // wrote free text must not blank the verdict — parse defensively and let
      // tier/provenance be null rather than 500 on somebody's breadcrumb.
      let d = {};
      if (v && v.detail) { try { d = JSON.parse(v.detail) || {}; } catch { d = {}; } }
      return json(200, {
        pr, job_id: hit.job_id, job: job || null,
        verdict: v ? String(v.artifact_ref) : null,
        tier: d.tier !== undefined ? d.tier : null,
        provenance: d.provenance !== undefined ? d.provenance : null,
        record: d.record !== undefined ? d.record : null,
        // SDLC item 1: the head the approval was bound to. Absent on rows written
        // before it existed, and a merge gate reads that absence as "no claim" —
        // never as a mismatch, or the day this shipped would park the fleet.
        reviewed_sha: d.reviewed_sha !== undefined ? d.reviewed_sha : null,
        // SDLC item 3: how many times this build was sent back. Absent on rows
        // written before it existed, and null there means NOT MEASURED — a
        // reader that scored it as zero would report every old build as clean.
        repairs: d.repairs !== undefined ? d.repairs : null,
        // SDLC item 4: the scope gate's verdict on this diff (in-scope /
        // unplanned / protected / unavailable / not-recorded) and its counts
        // line. Absent on rows written before it existed — null means NOT
        // MEASURED, never "the diff stayed in scope".
        scope: d.scope !== undefined ? d.scope : null,
        scope_counts: d.scope_counts !== undefined ? d.scope_counts : null,
        merge_sha: byKind.merge_sha ? String(byKind.merge_sha.artifact_ref) : null,
        artifacts, as_of: t,
      });
    }),
  ],

  // ── BH-1024: every round this PR's verdict went through ────────────────
  // The SAME resolution /api/verdict uses — prLedgerJob, build job first — so
  // a caller that can read the standing verdict reads how it got there without
  // learning a second key. `job_id` in the answer is that STANDING owner.
  //
  // THE ROUNDS ARE KEYED ON THE PR, NOT ON THAT ONE JOB. bin/review-prs.sh
  // opens a `review-verdict` job per reviewed (PR, sha) and the worker mints a
  // fresh id whenever none is OPEN on that key, so a BLOCK → rebase → APPROVE
  // cycle on one external PR is two jobs. Reading only the job prLedgerJob
  // picks answered "one round, APPROVE" while the table held the BLOCK — the
  // opposite of what this route's README row promises. So the select takes
  // every job that carries this `pr_url`, and each round names its own
  // `job_id` so a reader can still tell the build's rounds from a review
  // lane's. Oldest first (`id` is a global AUTOINCREMENT, so it orders across
  // jobs as well as inside one): a history read backwards says "approved,
  // then blocked" about a PR that was blocked and then approved.
  [
    "GET", "/api/verdict/history",
    async ({ env, url, t }) => overloadGiveUp(env, "GET /api/verdict/history", t, async () => {
      const pr = (url.searchParams.get("pr") || "").trim();
      if (!pr) return json(400, { error: "pr required" });
      // This route can be the first thing to touch the table after a deploy.
      await ensureTable(env, "verdict_history");
      const { hit } = await prLedgerJob(env.DB, pr);
      if (!hit) return json(404, { error: "no job has recorded this PR" });
      const hrows = await env.DB.prepare(
        `SELECT * FROM verdict_history
          WHERE job_id IN (SELECT job_id FROM job_artifacts
                            WHERE artifact_kind='pr_url' AND artifact_ref=?1)
          ORDER BY id ASC LIMIT 200`
      ).bind(pr).all();
      const rounds = hrows.results || [];
      // The cap is NAMED rather than implied: a reader that got exactly 200
      // rounds has been handed a prefix, and a history silently missing its
      // tail reads as a complete one.
      return json(200, {
        pr, job_id: hit.job_id, rounds, truncated: rounds.length >= 200, as_of: t,
      });
    }),
  ],
];
