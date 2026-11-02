// risk-tiers routes — BH-5022 (BH-4973.1): the record of the rule-based risk
// tier, one row per classified PR head (schema.sql's risk_tiers block, and the
// self-create copy in CREATED_TABLES).
//
// The writer is gate 60 (bin/lib/lead-gates.d/60-risk.sh): for every head it would ask the
// lead to review it classifies the diff (bin/lib/risk-tier.sh) and records the
// tier here in every mode except off. The readers are Mission Control's PR
// screen and the Merge Queue's RISK TIERS section, through the coord proxy.
//
// This row is a RECORD, not a credential. The sign-off itself is a
// source=risk-tier verdict row (routes/verdicts.js, lead token, MERGE only);
// nothing reads risk_tiers to decide a merge, so the bearer alone writes it.
//
// A head's diff never changes, so its first classification is kept: the same
// key again is 200 existing:true and the stored row is untouched.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { REPO_RE, optStr, prOf, shaOf } from "./verdicts.js";

export const RT_TIERS = ["low", "medium", "high"];
export const RT_MODES = ["off", "shadow", "enforce"];
const ACTION_RE = /^[a-z][a-z0-9-]{0,63}$/;
const PROJECT_RE = /^[A-Za-z0-9_.-]{1,100}$/;
const LIST_DEFAULT = 50;
const LIST_MAX = 200;

const guarded = (fn) => (ctx) =>
  d1Guarded("risk_tiers", async () => {
    await ensureTable(ctx.env, "risk_tiers");
    return fn(ctx);
  });

// optional non-negative integer: absent/null -> null; anything else refused
function optCount(body, key) {
  const v = body[key];
  if (v === undefined || v === null) return { ok: true, v: null };
  if (!Number.isInteger(v) || v < 0 || v > 1e9) return { ok: false, err: `${key} must be a non-negative integer` };
  return { ok: true, v };
}

export const routes = [
  [
    "POST", "/api/risk-tiers",
    guarded(async ({ env, t, body }) => {
      const b = body || {};
      const repo = typeof b.repo === "string" ? b.repo.trim() : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const pr = prOf(b.pr);
      if (pr === null) return json(400, { error: "pr must be a positive integer" });
      const head_sha = shaOf(b.head_sha);
      if (!head_sha) return json(400, { error: "head_sha must be a full 40-hex commit sha" });
      if (!RT_TIERS.includes(b.tier)) return json(400, { error: `tier must be one of ${RT_TIERS.join(", ")}` });
      if (!RT_MODES.includes(b.mode)) return json(400, { error: `mode must be one of ${RT_MODES.join(", ")}` });
      const action = b.action === undefined || b.action === null || b.action === "" ? null : b.action;
      if (action !== null && (typeof action !== "string" || !ACTION_RE.test(action))) {
        return json(400, { error: "action must be a short lowercase word (sign-off, would-sign-off, request, request-first)" });
      }
      const project = b.project === undefined || b.project === null || b.project === "" ? null : b.project;
      if (project !== null && (typeof project !== "string" || !PROJECT_RE.test(project))) {
        return json(400, { error: "project must be a project name, [A-Za-z0-9_.-], <= 100 chars" });
      }
      const reasons = optStr(b, "reasons", 1000);
      if (!reasons.ok) return json(400, { error: reasons.err });
      const lines = optCount(b, "lines");
      if (!lines.ok) return json(400, { error: lines.err });
      const files = optCount(b, "files");
      if (!files.ok) return json(400, { error: files.err });

      const res = await env.DB.prepare(
        `INSERT INTO risk_tiers (repo, pr, head_sha, project, tier, mode, action, reasons, lines, files, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
         ON CONFLICT(repo, pr, head_sha) DO NOTHING`
      ).bind(repo, pr, head_sha, project, b.tier, b.mode, action, reasons.v, lines.v, files.v, t).run();
      if (res.meta.changes === 1) return json(201, { ok: true, id: res.meta.last_row_id });
      return json(200, { ok: true, existing: true });
    }),
  ],

  // ?repo=&pr=&tier=&limit= — newest first (id DESC). The limit is refused
  // outside 1..200, never clamped, and `truncated` is measured by reading one
  // row past it. One constant statement: an absent filter binds NULL and its
  // clause is true.
  [
    "GET", "/api/risk-tiers",
    guarded(async ({ env, url, t }) => {
      const repo = (url.searchParams.get("repo") || "").trim();
      if (repo && !REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const rawPr = url.searchParams.get("pr");
      const pr = rawPr === null || rawPr === "" ? null : prOf(rawPr);
      if (rawPr && pr === null) return json(400, { error: "pr must be a positive integer" });
      const tier = url.searchParams.get("tier") || null;
      if (tier !== null && !RT_TIERS.includes(tier)) return json(400, { error: `tier must be one of ${RT_TIERS.join(", ")}` });
      const rawLimit = url.searchParams.get("limit");
      let limit = LIST_DEFAULT;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIST_MAX)) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });
      }
      const rows = (await env.DB.prepare(
        "SELECT * FROM risk_tiers" +
        " WHERE (?1 IS NULL OR repo = ?1)" +
        " AND (?2 IS NULL OR pr = ?2)" +
        " AND (?3 IS NULL OR tier = ?3)" +
        " ORDER BY id DESC LIMIT ?4"
      ).bind(repo || null, pr, tier, limit + 1).all()).results || [];
      return json(200, { rows: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
];
