// llm-site-rows routes — BH-2555 (BH-2540.2): GET /api/metrics/llm-sites/rows,
// one LLM site's cost rows, newest first, last 7 days, at most 200. The payload
// is documented in routes/llm-sites.js. Read-only.
// An unknown or missing ?site= is refused, never matched loosely. Which rows a
// site owns is siteAttribution() (lib/llm-sites-catalog.js); a site with no
// attributable stage answers reason 'no-stage' without reading the table.
// Every value reaches the SQL as a bound parameter.

import { json } from "../lib/http.js";
import { ensureColumns } from "../lib/core.js";
import { LLM_SITES, siteAttribution } from "../lib/llm-sites-catalog.js";

const WINDOW_MS = 7 * 86400000;
const LIMIT = 200;

export const routes = [
  ["GET", "/api/metrics/llm-sites/rows", async ({ env, url, t }) => {
    const id = url.searchParams.get("site");
    const site = LLM_SITES.find((s) => s.id === id);
    if (!site) return json(400, { error: "unknown site" });
    const a = siteAttribution(site);
    if (a.attribution === "none") return json(200, { site, rows: [], truncated: false, reason: "no-stage", incomplete: [] });
    await ensureColumns(env, "cost_rows");
    const binds = [new Date(Date.parse(t) - WINDOW_MS).toISOString()];
    let where = "ts >= ?1";
    if (!a.all) {
      where += " AND stage IN (" + a.stages.map((s) => { binds.push(s); return "?" + binds.length; }).join(",") + ")";
    }
    if (a.attribution === "lane") {
      binds.push(a.lane);
      where += ` AND (lane_id = ?${binds.length} OR lane_id IS NULL)`;
    }
    // sql-ident-ok: where holds literal clauses with ?N marks over the bound stages and lane; LIMIT is a module number const
    const r = await env.DB.prepare(
      "SELECT ts, box, project, ticket, pr, stage, lane_id, runner, model, billing_mode, rc, cost_usd, row_source, note" +
      ` FROM cost_rows WHERE ${where} ORDER BY ts DESC, box, line_no DESC LIMIT ${LIMIT}`
    ).bind(...binds).all();
    const rows = r.results || [];
    return json(200, { site, rows, truncated: rows.length === LIMIT, incomplete: [] });
  }],
];
