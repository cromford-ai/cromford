// lane-dedup — GET /api/metrics/lane-dedup (BH-2537: contract BH-2665,
// aggregation BH-2669).
//
// How many LLM calls each lane makes per distinct input: per lane, calls over
// the window divided by the distinct guard fingerprints (guard_fp), tickets and
// PRs those calls carried, plus the lane's most-repeated fingerprints. A lane
// with calls_per_fp well above 1 is paying repeatedly for the same input.
//
// Response: { days, lanes: [...], truncated: { fps: <bool> } }
//
// `lanes[]` element:
//   {lane, calls, distinct_fp, distinct_tickets, distinct_prs, no_fp_calls,
//    unidentified_calls, usd, calls_per_fp, calls_per_ticket, calls_per_pr,
//    fps: [{fp, calls, ticket, pr, project, usd}]}
//
// Two bounded D1 reads over cost_rows in the window, refused rows excluded
// (a refused row bought nothing, so it is not a call). Read 1 groups by lane
// and is uncapped (one row per lane). Read 2 groups by (lane, guard_fp) and is
// capped at FP_CAP rows across ALL lanes; it fetches one extra row so
// `truncated.fps` is true only when more groups existed than were returned.
// Each lane keeps its TOP_FPS most-called fingerprints. Rows with no
// fingerprint are counted in no_fp_calls, never listed in fps[]. An empty
// lane_id / guard_fp / ticket / pr / project reads the same as NULL, so the
// NULL lane_id group is `lane: null`. A calls_per_* ratio is null when its
// distinct count is 0; usd is null when no row in the group is priced. The
// window, TOP_FPS and FP_CAP are query bounds, not business knobs.
//
// `days` is the window: absent or empty means 7; otherwise it must be an
// integer 1..30. Anything else is a 400 — an explicit value is never clamped.
// A failed D1 read is not caught here: it reaches the router's error path
// rather than answering an empty 200.

import { json } from "./http.js";
import { ensureColumns } from "./core.js";

const TOP_FPS = 10;
const FP_CAP = 500;

const ratio = (calls, distinct) => (distinct > 0 ? calls / distinct : null);
const usdOf = (v) => (v === null || v === undefined ? null : Number(v));

export function shapeLaneDedup(laneRows, fpRows, days) {
  const kept = fpRows.slice(0, FP_CAP);
  const fpsByLane = new Map();
  for (const r of kept) {
    const lane = r.lane ?? null;
    let list = fpsByLane.get(lane);
    if (!list) { list = []; fpsByLane.set(lane, list); }
    if (list.length < TOP_FPS) {
      list.push({
        fp: r.fp, calls: Number(r.calls), ticket: r.ticket ?? null, pr: r.pr ?? null,
        project: r.project ?? null, usd: usdOf(r.usd),
      });
    }
  }
  const lanes = laneRows.map((r) => {
    const lane = r.lane ?? null;
    const calls = Number(r.calls);
    const distinct_fp = Number(r.distinct_fp);
    const distinct_tickets = Number(r.distinct_tickets);
    const distinct_prs = Number(r.distinct_prs);
    return {
      lane, calls, distinct_fp, distinct_tickets, distinct_prs,
      no_fp_calls: Number(r.no_fp_calls), unidentified_calls: Number(r.unidentified_calls),
      usd: usdOf(r.usd),
      calls_per_fp: ratio(calls, distinct_fp),
      calls_per_ticket: ratio(calls, distinct_tickets),
      calls_per_pr: ratio(calls, distinct_prs),
      fps: fpsByLane.get(lane) || [],
    };
  });
  lanes.sort((a, b) => b.calls - a.calls
    || (a.lane === null) - (b.lane === null)
    || String(a.lane).localeCompare(String(b.lane)));
  return { days, lanes, truncated: { fps: fpRows.length > FP_CAP } };
}

export async function laneDedupResponse(env, url) {
  const raw = url.searchParams.get("days");
  let days = 7;
  if (raw !== null && raw !== "") {
    if (!/^\d+$/.test(raw) || Number(raw) < 1 || Number(raw) > 30) {
      return json(400, { error: "days must be an integer 1..30" });
    }
    days = Number(raw);
  }
  // guard_fp is an ADDED_COLUMN: a D1 not yet migrated would throw on it.
  await ensureColumns(env, "cost_rows");
  const since = new Date(Date.now() - days * 86400 * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  const window = "ts>=?1 AND COALESCE(row_source,'')<>'refused'";
  // sql-ident-ok: window is a literal predicate
  const lanes = await env.DB.prepare(
    `SELECT NULLIF(lane_id,'') AS lane, COUNT(*) AS calls,
            COUNT(DISTINCT NULLIF(guard_fp,'')) AS distinct_fp,
            COUNT(DISTINCT NULLIF(ticket,'')) AS distinct_tickets,
            COUNT(DISTINCT NULLIF(pr,'')) AS distinct_prs,
            SUM(CASE WHEN COALESCE(guard_fp,'')='' THEN 1 ELSE 0 END) AS no_fp_calls,
            SUM(CASE WHEN COALESCE(ticket,'')='' AND COALESCE(pr,'')='' THEN 1 ELSE 0 END) AS unidentified_calls,
            SUM(cost_usd) AS usd
       FROM cost_rows WHERE ${window}
      GROUP BY NULLIF(lane_id,'')`
  ).bind(since).all();
  // sql-ident-ok: window is a literal predicate; FP_CAP is a code constant
  const fps = await env.DB.prepare(
    `SELECT NULLIF(lane_id,'') AS lane, guard_fp AS fp, COUNT(*) AS calls,
            MAX(NULLIF(ticket,'')) AS ticket, MAX(NULLIF(pr,'')) AS pr,
            MAX(NULLIF(project,'')) AS project, SUM(cost_usd) AS usd
       FROM cost_rows WHERE ${window} AND COALESCE(guard_fp,'')<>''
      GROUP BY NULLIF(lane_id,''), guard_fp
      ORDER BY calls DESC, lane, fp
      LIMIT ${FP_CAP + 1}`
  ).bind(since).all();
  return json(200, shapeLaneDedup(lanes.results, fps.results, days));
}
