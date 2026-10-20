// outcome-gap route — BH-4017 (BH-3987.3): per project, the tickets with
// priced build-stage spend over min_usd and no merged harness PR as of the
// day's end. Read by bin/daily-digest.sh into the digest's Outcome gap block.
// Read-only: it never writes and never calls ensureColumns (every column it
// reads is in the base schema.sql). A thrown read is not caught into a 200.
//
// The definition, params and SQL are in lib/outcome-gap.js.
//
// A lookback the archive can reach reads it too (lib/archive-read.js,
// BH-7035); the answer's `archive` says which.

import { json, overloadGuardedRoute } from "../lib/http.js";
import {
  parseGapParams, gapSql, unpricedSql, foldGap, GROUP_MAX, gapGroupsSql, gapUnmergedSql, mergeGapGroups,
} from "../lib/outcome-gap.js";
import { archiveReach, readHistory, mergeAggregate, worstState } from "../lib/archive-read.js";

const cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0);

// The cohort when the archive is in reach: groups from both stores, merged,
// then gapSql's HAVING and NOT EXISTS. Same rows out as gapSql on one store.
async function mergedGap(env, p, t, reach) {
  const { win, stages } = p;
  const [g, u] = await Promise.all([
    readHistory(env, { table: "cost_rows", since: p.from, now: t, reach,
      hot: { sql: gapGroupsSql(stages.length), binds: [p.from, win.to, ...stages, GROUP_MAX + 1] } }),
    readHistory(env, { table: "cost_rows", since: p.from, now: t, reach, method: "first",
      hot: { sql: unpricedSql(stages.length), binds: [p.from, win.to, ...stages] } }),
  ]);
  const hot = g.hot.results || [];
  const arch = g.archive ? g.archive.results || [] : null;
  const merged = mergeGapGroups(hot, arch, p);
  let rows = [];
  if (merged.length) {
    const keep = await env.DB.prepare(gapUnmergedSql())
      .bind(JSON.stringify(merged.map((r) => [r.project, r.ticket])), win.to).all();
    const kept = new Set((keep.results || []).map((r) => JSON.stringify([r.project, r.ticket])));
    rows = merged.filter((r) => kept.has(JSON.stringify([r.project, r.ticket])))
      .sort((a, b) => b.usd - a.usd || cmp(a.project, b.project) || cmp(a.ticket, b.ticket))
      .slice(0, GROUP_MAX + 1);
  }
  const up = mergeAggregate(u.hot, u.archive, { n: "sum" });
  return {
    rows,
    up,
    // A side at its cap may lack a group that belongs in the cohort (D12).
    sideTruncated: hot.length > GROUP_MAX || (arch !== null && arch.length > GROUP_MAX),
    archive: worstState([g.state, u.state]),
  };
}

export const routes = [
  [
    "GET", "/api/metrics/outcome-gap",
    overloadGuardedRoute("cost_rows", async ({ env, url, t }) => {
      const p = parseGapParams(url.searchParams, t);
      if (p.error) return json(400, { error: p.error });
      const { win, stages } = p;

      const reach = await archiveReach(env, { table: "cost_rows", since: p.from, now: t });
      let rows, up, sideTruncated = false, archive = reach;
      if (reach === "reach") {
        ({ rows, up, sideTruncated, archive } = await mergedGap(env, p, t, reach));
      } else {
        const [r, u] = await Promise.all([
          env.DB.prepare(gapSql(stages.length)).bind(p.from, win.to, p.minUsd, p.grace, ...stages, GROUP_MAX + 1).all(),
          env.DB.prepare(unpricedSql(stages.length)).bind(p.from, win.to, ...stages).first(),
        ]);
        rows = r.results || [];
        up = u;
      }
      if (typeof up?.n !== "number") throw new Error("outcome-gap: the unpriced count read returned no number");

      const fold = foldGap(rows, { limit: p.limit, groupMax: GROUP_MAX });
      return json(200, {
        ok: true,
        day: win.day,
        from: p.from,
        to: win.to,
        min_usd: p.minUsd,
        days: p.days,
        lookback: p.lookback,
        stages,
        total_usd: fold.total_usd,
        tickets_n: fold.tickets_n,
        unpriced_calls: up.n,
        projects: fold.projects,
        truncated: fold.truncated || sideTruncated,
        archive,
      });
    }),
  ],
];
