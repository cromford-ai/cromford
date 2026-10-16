// outcome-gap — BH-4017 (BH-3987.3): the pure half of GET
// /api/metrics/outcome-gap. Param validation, the SQL literals, the merge of
// the two stores (BH-7035), the fold.
// No clock: the route passes its `t` in.
//
// A (project, ticket) is in the gap when its priced spend in the given stages
// over [to - lookback, to) is over min_usd, its first priced row is older than
// to - days, and no harness PR of a jobs row with the same project + ticket_id
// had a `ledgers merge merged` row before `to` (readThroughput's join in
// lib/daily-digest/core-sections.js). Note: docs/notes/2026-10-03-BH-3987-outcome-gap.md.

import { dayWindow, capList } from "./daily-digest/shape.js";
import { mergeGroups } from "./archive-read.js";

// Read limits, not business parameters: the lane passes its knob values in.
export const GROUP_MAX = 5000;
const INTS = { days: [1, 60, 7], lookback: [1, 180, 30], limit: [1, 100, 20] };
const MIN_USD_MAX = 10000;
const MIN_USD_DEFAULT = 5;
const STAGES_MAX = 20;
const STAGE_RE = /^[a-z0-9._-]{1,32}$/;
const MONEY_RE = /^\d+(\.\d{1,2})?$/;
const DAY_MS = 86400000;

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// {win, from, grace, minUsd, days, lookback, stages, limit} or {error}.
// Every explicit bad value is an error, never clamped.
export function parseGapParams(q, nowIso) {
  const win = dayWindow(q.get("day"), nowIso);
  if (!win) return { error: "day must be YYYY-MM-DD, a real date, not after today UTC" };

  let minUsd = MIN_USD_DEFAULT;
  if (q.has("min_usd")) {
    const v = q.get("min_usd");
    if (!MONEY_RE.test(v) || Number(v) > MIN_USD_MAX) {
      return { error: `min_usd must be a number 0..${MIN_USD_MAX} with at most 2 decimals` };
    }
    minUsd = Number(v);
  }

  const n = {};
  for (const [k, [lo, hi, def]] of Object.entries(INTS)) {
    if (!q.has(k)) { n[k] = def; continue; }
    const v = q.get(k);
    if (!/^\d+$/.test(v) || Number(v) < lo || Number(v) > hi) return { error: `${k} must be an integer ${lo}..${hi}` };
    n[k] = Number(v);
  }
  if (n.lookback <= n.days) return { error: "lookback must be greater than days" };

  if (!q.has("stages")) return { error: "stages is required" };
  const list = q.get("stages").split(",");
  if (list.length > STAGES_MAX || list.some((s) => !STAGE_RE.test(s))) {
    return { error: `stages takes 1..${STAGES_MAX} comma-separated names matching [a-z0-9._-]{1,32}` };
  }

  const to = Date.parse(win.to);
  return {
    win,
    from: iso(to - n.lookback * DAY_MS),
    grace: iso(to - n.days * DAY_MS),
    minUsd,
    days: n.days,
    lookback: n.lookback,
    stages: [...new Set(list)],
    limit: n.limit,
  };
}

// ?1 from, ?2 to, ?3 min_usd, ?4 grace, ?5.. the stages, then the row cap.
// Only the placeholders are generated, from the validated count.
const stageIn = (first, n) => Array.from({ length: n }, (_, i) => `?${first + i}`).join(", ");

export function gapSql(nStages) {
  return `SELECT c.project AS project, c.ticket AS ticket, SUM(c.cost_usd) AS usd,
       SUM(c.cost_usd IS NULL) AS unpriced_calls,
       MIN(CASE WHEN c.cost_usd IS NOT NULL THEN c.ts END) AS first_ts, MAX(c.job_id) AS last_job_id
  FROM cost_rows c
 WHERE c.ts >= ?1 AND c.ts < ?2 AND c.project IS NOT NULL AND c.ticket IS NOT NULL
   AND c.stage IN (${stageIn(5, nStages)})
 GROUP BY c.project, c.ticket
HAVING SUM(c.cost_usd) > ?3
   AND MIN(CASE WHEN c.cost_usd IS NOT NULL THEN c.ts END) < ?4
   AND NOT EXISTS (SELECT 1 FROM jobs j
                     JOIN job_artifacts a ON a.job_id = j.id AND a.artifact_kind = 'pr_url'
                     JOIN ledgers l ON l.kind = 'merge' AND l.status = 'merged' AND l.key = a.artifact_ref
                    WHERE j.project = c.project AND j.ticket_id = c.ticket AND l.created_at < ?2)
 ORDER BY usd DESC, project, ticket
 LIMIT ?${5 + nStages}`;
}

// Every unpriced call in the stages and window, cohort or not: an
// unpriced-only ticket can never enter the cohort and would otherwise vanish.
// ?1 from, ?2 to, ?3.. the stages.
export function unpricedSql(nStages) {
  return `SELECT COUNT(*) AS n FROM cost_rows
 WHERE ts >= ?1 AND ts < ?2 AND cost_usd IS NULL AND stage IN (${stageIn(3, nStages)})`;
}

// The archive half (BH-7035). A ticket's sum can span the hot store and the
// archive, so HAVING cannot run per store. When the archive is in reach, the
// groups run on both stores with no HAVING and no merge check (jobs,
// job_artifacts and ledgers are hot only), are merged, and then
// passesHaving and gapUnmergedSql apply the same two conditions.
// ?1 from, ?2 to, ?3.. the stages, then the row cap.
export function gapGroupsSql(nStages) {
  return `SELECT c.project AS project, c.ticket AS ticket, SUM(c.cost_usd) AS usd,
       SUM(c.cost_usd IS NULL) AS unpriced_calls,
       MIN(CASE WHEN c.cost_usd IS NOT NULL THEN c.ts END) AS first_ts, MAX(c.job_id) AS last_job_id
  FROM cost_rows c
 WHERE c.ts >= ?1 AND c.ts < ?2 AND c.project IS NOT NULL AND c.ticket IS NOT NULL
   AND c.stage IN (${stageIn(3, nStages)})
 GROUP BY c.project, c.ticket
 ORDER BY project, ticket
 LIMIT ?${3 + nStages}`;
}

// gapSql's HAVING on one merged group. SQL's NULL > x is not true, so a NULL
// sum or a NULL first_ts never passes.
export function passesHaving(row, { minUsd, grace }) {
  return row.usd !== null && row.usd !== undefined && row.usd > minUsd
    && row.first_ts !== null && row.first_ts !== undefined && row.first_ts < grace;
}

// Pure. The gapGroupsSql rows of both stores as one group per (project,
// ticket), kept only when the merged group passes gapSql's HAVING. archRows
// null (no archive answer) runs the HAVING on hotRows alone.
export function mergeGapGroups(hotRows, archRows, { minUsd, grace }) {
  return mergeGroups(hotRows, archRows, {
    by: ["project", "ticket"],
    spec: { usd: "sum", unpriced_calls: "sum", first_ts: "min", last_job_id: "max" },
    pickBy: "last_job_id", compare: () => 0, limit: Infinity,
  }).rows.filter((r) => passesHaving(r, { minUsd, grace }));
}

// gapSql's NOT EXISTS over a list of candidates. ?1 a JSON array of
// [project, ticket] pairs, ?2 to. Returns the pairs with no harness PR merged
// before `to`.
export function gapUnmergedSql() {
  return `SELECT json_extract(v.value,'$[0]') AS project, json_extract(v.value,'$[1]') AS ticket
  FROM json_each(?1) v
 WHERE NOT EXISTS (SELECT 1 FROM jobs j
                     JOIN job_artifacts a ON a.job_id = j.id AND a.artifact_kind = 'pr_url'
                     JOIN ledgers l ON l.kind = 'merge' AND l.status = 'merged' AND l.key = a.artifact_ref
                    WHERE j.project = json_extract(v.value,'$[0]') AND j.ticket_id = json_extract(v.value,'$[1]')
                      AND l.created_at < ?2)`;
}

const byUsdThen = (key) => (a, b) => b.usd - a.usd || (a[key] < b[key] ? -1 : a[key] > b[key] ? 1 : 0);

// Pure. Rows past groupMax are not folded and the answer says truncated.
export function foldGap(rows, { limit, groupMax = GROUP_MAX }) {
  const by = new Map();
  for (const r of rows.slice(0, groupMax)) {
    let p = by.get(r.project);
    if (!p) by.set(r.project, (p = { project: r.project, usd: 0, list: [] }));
    const usd = Number(r.usd);
    p.usd += usd;
    p.list.push({
      ticket: r.ticket,
      usd,
      unpriced_calls: Number(r.unpriced_calls),
      first_ts: r.first_ts,
      last_job_id: r.last_job_id ?? null,
    });
  }
  const projects = [...by.values()].sort(byUsdThen("project")).map((p) => ({
    project: p.project,
    usd: p.usd,
    tickets_n: p.list.length,
    tickets: capList(p.list.sort(byUsdThen("ticket")), limit),
  }));
  return {
    total_usd: projects.reduce((s, p) => s + p.usd, 0),
    tickets_n: projects.reduce((s, p) => s + p.tickets_n, 0),
    projects,
    truncated: rows.length > groupMax,
  };
}
