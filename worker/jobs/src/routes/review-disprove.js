// review-disprove routes — BH-9047: one row per disprove pass on a lead review
// BLOCK (bin/lib/review-disprove.sh dp_record is the writer).
//
//   POST /api/review-disprove   record one pass (INSERT OR IGNORE on the key)
//   GET  /api/review-disprove   read passes, newest first
//
// THE ROW is review_disprove_runs (schema.d/*-bh-9047-review-disprove.sql).
// The natural key (repo, pr, head_sha, review_id, lane) makes a retried post a
// no-op: 201 {row, existing:false} on a new row, 200 {row, existing:true} on a
// repeat. A bad field is 400 {error} that names the field, never clamped.
// detail is a JSON array of at most DETAIL_MAX {cls, loc, outcome, reason}.
// cost_usd is null when the caller sent none (never 0 for unknown).
//
// THE READ needs repo or since, so it always starts on an index (BH-6730):
// repo (+pr, +head_sha) is a prefix of idx_review_disprove_runs_key, since is
// idx_review_disprove_runs_created. test/review-disprove.bh-9047.test.js W4
// EXPLAINs listSql() at 20 000 rows. limit is 1..review.disprove.list_max
// (fallback 500), default review.disprove.list_limit (fallback 100).
//
// D1 has no RLS. Both routes sit behind the HARNESS_SECRET bearer (this family
// is not in OPEN_FAMILIES).
import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { REPO_RE, prOf, shaOf, optStr } from "./verdicts.js";

const TABLE = "review_disprove_runs";
export const LANES = ["lead", "conductor"];
export const MODES = ["shadow", "enforce"];
export const COUNTS = ["findings", "checked", "confirmed", "disproved", "kept_protected", "unchecked"];
// Input validation bounds, as TEXT_MAX in unblock-decisions.js.
export const DETAIL_MAX = 20;
const REASON_MAX = 300;
const FIELD_MAX = 200;
const VERDICT_MAX = 40;
// The code fallbacks of the settings rows review.disprove.list_limit and
// review.disprove.list_max (schema.d/*-bh-9047-review-disprove.sql seeds both).
const LIST_LIMIT_DEFAULT = 100;
const LIST_MAX_DEFAULT = 500;
const LIST_MAX_CEIL = 5000;

const COLS = "repo, pr, head_sha, review_id, lane, project, mode, verdict_before, verdict_after, "
  + `${COUNTS.join(", ")}, cost_usd, detail, actor, created_at`;
export const INSERT_SQL = `INSERT OR IGNORE INTO review_disprove_runs (${COLS})
  VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)`;
export const KEY_SQL =
  "SELECT * FROM review_disprove_runs WHERE repo = ?1 AND pr = ?2 AND head_sha = ?3 AND review_id = ?4 AND lane = ?5";

// The GET's SQL for the filters given, in a fixed order, so the same filters
// always produce the same text. The last bind is the limit.
export function listSql(f) {
  const where = [];
  const binds = [];
  for (const k of ["repo", "pr", "head_sha", "lane"]) {
    if (f[k] !== undefined && f[k] !== null) { binds.push(f[k]); where.push(`${k} = ?${binds.length}`); }
  }
  if (f.since !== undefined && f.since !== null) { binds.push(f.since); where.push(`created_at >= ?${binds.length}`); }
  binds.push(f.limit);
  const sql = `SELECT * FROM review_disprove_runs WHERE ${where.join(" AND ")} ORDER BY created_at DESC, id DESC LIMIT ?${binds.length}`;
  return { sql, binds };
}

const bad = (field, why) => json(400, { error: `${field} ${why}`, field });
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const nonEmpty = (v, max) => typeof v === "string" && v.trim() !== "" && v.length <= max;
const cut = (v, max) => (v === undefined || v === null ? null : String(v).slice(0, max));

function rowOut(r) {
  if (!r) return r;
  let detail = [];
  try { detail = JSON.parse(r.detail); } catch { detail = []; }
  return { ...r, detail: Array.isArray(detail) ? detail : [] };
}

// The body as a bind list, or {err} naming the first bad field.
export function validateRun(body) {
  const b = isObj(body) ? body : {};
  const repo = typeof b.repo === "string" ? b.repo.trim() : "";
  if (!REPO_RE.test(repo)) return { field: "repo", err: "must be owner/name" };
  const pr = prOf(b.pr);
  if (pr === null) return { field: "pr", err: "must be a positive integer" };
  const head = shaOf(b.head_sha);
  if (!head) return { field: "head_sha", err: "must be a full 40-hex commit sha" };
  if (!nonEmpty(b.review_id, FIELD_MAX)) return { field: "review_id", err: `must be a string, 1..${FIELD_MAX} chars` };
  if (!LANES.includes(b.lane)) return { field: "lane", err: `must be one of ${LANES.join(", ")}` };
  if (!nonEmpty(b.project, FIELD_MAX)) return { field: "project", err: `must be a string, 1..${FIELD_MAX} chars` };
  if (!MODES.includes(b.mode)) return { field: "mode", err: `must be one of ${MODES.join(", ")}` };
  for (const k of ["verdict_before", "verdict_after"]) {
    if (!nonEmpty(b[k], VERDICT_MAX)) return { field: k, err: `must be a string, 1..${VERDICT_MAX} chars` };
  }
  const counts = [];
  for (const k of COUNTS) {
    if (!(Number.isSafeInteger(b[k]) && b[k] >= 0)) return { field: k, err: "must be a non-negative integer" };
    counts.push(b[k]);
  }
  const cost = b.cost_usd ?? null;
  if (cost !== null && !(typeof cost === "number" && Number.isFinite(cost) && cost >= 0)) {
    return { field: "cost_usd", err: "must be a number >= 0 or null" };
  }
  const raw = b.detail ?? [];
  if (!Array.isArray(raw) || raw.length > DETAIL_MAX) return { field: "detail", err: `must be an array of at most ${DETAIL_MAX} items` };
  if (!raw.every(isObj)) return { field: "detail", err: "items must be objects" };
  const detail = raw.map((d) => ({
    cls: cut(d.cls, FIELD_MAX), loc: cut(d.loc, FIELD_MAX), outcome: cut(d.outcome, FIELD_MAX), reason: cut(d.reason, REASON_MAX),
  }));
  const actor = optStr(b, "actor", FIELD_MAX);
  if (!actor.ok) return { field: "actor", err: `must be a string, <= ${FIELD_MAX} chars` };
  return {
    key: [repo, pr, head, b.review_id, b.lane],
    binds: [repo, pr, head, b.review_id, b.lane, b.project, b.mode, b.verdict_before, b.verdict_after,
      ...counts, cost, JSON.stringify(detail), actor.v ?? "box"],
  };
}

export const routes = [
  // ── POST /api/review-disprove — record one disprove pass ───────────────────
  [
    "POST", "/api/review-disprove",
    async ({ env, t, body }) => {
      const v = validateRun(body);
      if (v.err) return bad(v.field, v.err);
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const res = await env.DB.prepare(INSERT_SQL).bind(...v.binds, t).run();
        const row = await env.DB.prepare(KEY_SQL).bind(...v.key).first();
        const created = Number(res?.meta?.changes) === 1;
        return json(created ? 201 : 200, { row: rowOut(row), existing: !created });
      });
    },
  ],

  // ── GET /api/review-disprove?repo=&pr=&head_sha=&since=&lane=&limit= ───────
  [
    "GET", "/api/review-disprove",
    async ({ env, url }) => {
      const q = (k) => url.searchParams.get(k);
      const f = {};
      if (q("repo") !== null) {
        if (!REPO_RE.test(q("repo"))) return bad("repo", "must be owner/name");
        f.repo = q("repo");
      }
      if (q("pr") !== null) {
        f.pr = prOf(q("pr"));
        if (f.pr === null) return bad("pr", "must be a positive integer");
      }
      if (q("head_sha") !== null) {
        f.head_sha = shaOf(q("head_sha"));
        if (!f.head_sha) return bad("head_sha", "must be a full 40-hex commit sha");
      }
      if (q("lane") !== null) {
        if (!LANES.includes(q("lane"))) return bad("lane", `must be one of ${LANES.join(", ")}`);
        f.lane = q("lane");
      }
      if (q("since") !== null) {
        const ms = Date.parse(q("since"));
        if (!/^\d{4}-\d{2}-\d{2}/.test(q("since")) || !Number.isFinite(ms)) return bad("since", "must be an ISO time");
        f.since = new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
      }
      if (f.repo === undefined && f.since === undefined) return bad("repo", "or since is required");
      return d1Guarded(TABLE, async () => {
        const [{ byKey }] = await Promise.all([settingsRows(env), ensureTable(env, TABLE)]);
        const max = intSetting(byKey, "review.disprove.list_max", LIST_MAX_DEFAULT, 1, LIST_MAX_CEIL);
        const def = Math.min(intSetting(byKey, "review.disprove.list_limit", LIST_LIMIT_DEFAULT, 1, LIST_MAX_CEIL), max);
        let limit = def;
        if (q("limit") !== null) {
          limit = /^\d+$/.test(q("limit")) ? Number(q("limit")) : NaN;
          if (!(limit >= 1 && limit <= max)) return bad("limit", `must be an integer 1..${max}`);
        }
        const { sql, binds } = listSql({ ...f, limit });
        const { results } = await env.DB.prepare(sql).bind(...binds).all();
        return json(200, { rows: (results || []).map(rowOut), limit });
      });
    },
  ],
];
