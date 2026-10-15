// cli-versions routes — which CLI build each box is running.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  intOrNull, str,
} from "../lib/core.js";

export const routes = [
  // ── Runner-CLI versions (2026-09-06) ────────────────────────────────────
  // bin/cli-update.sh (every box, daily) and bin/cli-version-check.sh (hub
  // sweep) push {rows:[{box, cli, at, source, version_before, version_after,
  // method, ok, path, note}]}. Two writes per row in one batch: the history
  // row (DO NOTHING on the (box, cli, at, source) PK, so a resend is a
  // no-op) and the box_status upsert that keeps the CURRENT version per box
  // — only moved forward in time: a late-arriving older row must not roll a
  // box's status back to what it was yesterday.
  //
  // grok (BH-1636) is history only. box_status has a column for claude and one
  // for codex and none for grok, so a grok row writes no box_status statement;
  // without that guard the claude-or-else ternary below would file grok's
  // version under codex_version.
  [
    "POST", "/api/metrics/cli-versions",
    async ({ env, path, t, body }) => {
      const rows = Array.isArray(body.rows) ? body.rows : (body.box && body.cli ? [body] : []);
      if (!rows.length) return json(400, { error: "rows[] required" });
      if (rows.length > 500) return json(400, { error: "at most 500 rows per request" });
      const stmts = [];
      let accepted = 0;
      for (const r of rows) {
        const box = str(r.box, 128);
        const cli = str(r.cli, 32);
        const at = str(r.at, 40);
        if (!box || !cli || !at) continue;
        if (!["claude", "codex", "grok"].includes(cli)) continue;
        const source = str(r.source, 16) || "update";
        const after = str(r.version_after, 64);
        accepted++;
        stmts.push(env.DB.prepare(
          `INSERT INTO cli_versions (box, cli, at, source, version_before, version_after, method, ok, path, note, inserted_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
           ON CONFLICT(box, cli, at, source) DO NOTHING`
        ).bind(box, cli, at, source, str(r.version_before, 64), after, str(r.method, 64),
               intOrNull(r.ok), str(r.path, 512), str(r.note, 2000), t));
        // A "missing" reading is a fact for the history row and NOT a version
        // for box_status: the column answers "what can this box run", and the
        // honest answer to a missing CLI is the last version it did have plus
        // the alert the check script already wrote.
        if (after && after !== "missing" && (cli === "claude" || cli === "codex")) {
          const col = cli === "claude" ? "cli_version" : "codex_version";
          // sql-ident-ok: col is a ternary of two literal column names
          stmts.push(env.DB.prepare(
            `INSERT INTO box_status (box, host, ${col}, cli_checked_at, actor, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6)
             ON CONFLICT(box) DO UPDATE SET
               ${col}=CASE WHEN box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4 THEN ?3 ELSE ${col} END,
               cli_checked_at=CASE WHEN box_status.cli_checked_at IS NULL OR box_status.cli_checked_at<=?4 THEN ?4 ELSE box_status.cli_checked_at END,
               host=COALESCE(?2, host), actor=?5, updated_at=?6`
          ).bind(box, str(r.host, 128), after, at, source, t));
        }
      }
      if (!stmts.length) return json(400, { error: "no row carried box, cli (claude|codex|grok) and at" });
      const results = await env.DB.batch(stmts);
      const inserted = (Array.isArray(results) ? results : [])
        .reduce((a, x) => a + ((x && x.meta && Number(x.meta.changes)) || 0), 0);
      return json(200, { accepted, inserted, as_of: t });
    },
  ],

  [
    "GET", "/api/metrics/cli-versions",
    async ({ env, url, t }) => {
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 2000);
      const where = [], binds = [];
      for (const [k, max] of [["box", 128], ["cli", 32], ["source", 16]]) {
        const v = str(url.searchParams.get(k), max);
        if (v) { binds.push(v); where.push(`${k}=?${binds.length}`); }
      }
      // sql-ident-ok: where uses column names from a literal list, values bound; lim is a clamped Number
      const rows = await env.DB.prepare(
        `SELECT * FROM cli_versions${where.length ? " WHERE " + where.join(" AND ") : ""}
         ORDER BY at DESC LIMIT ${lim}`
      ).bind(...binds).all();
      return json(200, { cli_versions: rows.results || [], as_of: t });
    },
  ],
];
