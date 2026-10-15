// closeout-aged routes — the age-out audit (BH-1033).
//
// This family is NEW, not moved: BH-1195 split the flat chain into per-family
// modules, and BH-1033 lands its two routes here rather than back in the chain
// that no longer exists. src/index.js holds the ordered table that decides
// which of these runs, and test/route-table.test.js carries the same two
// entries in the position the table puts them.

import { json } from "../lib/http.js";
import { ensureTable, str } from "../lib/core.js";

export const routes = [
  // ── THE AGE-OUT AUDIT (BH-1033) ────────────────────────────────────────
  // state/closeout-aged-out.tsv as rows. See the `closeout_aged` comment in
  // schema.sql for why this one needs a table of its own while the ready
  // queue does not. THE INSERT IS THE DEDUPE: `ON CONFLICT DO NOTHING` on the
  // build_dir primary key, and the answer says which of the two happened, so
  // a caller can tell "we just decided this" from "we decided it in June"
  // without a second read. Never an error: deciding twice is not a failure.
  [
    "POST", "/api/closeout-aged",
    async ({ env, t, body }) => {
      // The belt, before anything else in the handler (BH-658/BH-1000): a D1
      // the schema apply never reached would otherwise throw `no such table`
      // here, and the shell side would read that as an outage rather than a
      // missing table. Cached per database, so it is one statement once.
      await ensureTable(env, "closeout_aged");
      const dir = str(body.build_dir, 256);
      if (!dir) return json(400, { error: "build_dir is required" });
      const res = await env.DB.prepare(
        `INSERT INTO closeout_aged (build_dir, project, result_head, reason, recorded_by, at)
         VALUES (?1,?2,?3,?4,?5,?6)
         ON CONFLICT(build_dir) DO NOTHING`
      ).bind(dir, str(body.project, 64), str(body.result_head, 500),
             str(body.reason, 500), str(body.actor, 64), t).run();
      const recorded = !!res.meta.changes;
      return json(recorded ? 201 : 200, {
        aged: { build_dir: dir, project: str(body.project, 64), at: t },
        recorded, duplicate: !recorded, as_of: t,
      });
    },
  ],

  [
    "GET", "/api/closeout-aged",
    async ({ env, url, t }) => {
      await ensureTable(env, "closeout_aged");
      const dir = url.searchParams.get("build_dir");
      const project = url.searchParams.get("project");
      const where = [], binds = [];
      if (dir) { binds.push(dir); where.push(`build_dir=?${binds.length}`); }
      if (project) { binds.push(project); where.push(`project=?${binds.length}`); }
      // Math.max(1, …): SQLite reads LIMIT -1 as UNBOUNDED, so junk here would
      // return the whole table instead of nothing.
      const limit = Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 200), 500);
      // sql-ident-ok: where holds literal column=?N clauses; limit is a clamped Number
      const rows = await env.DB.prepare(
        "SELECT * FROM closeout_aged"
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY at DESC LIMIT ${limit}`
      ).bind(...binds).all();
      return json(200, { aged: rows.results || [], as_of: t });
    },
  ],
];
