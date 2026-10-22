// pool-markers routes — BH-7431 (BH-6896 S4): the pool's once-markers and wait
// clocks as rows.
//
// bin/fly-pool.sh gates a spawn, a page or a comment on marker files that exist
// only on the hub (state/pool/<p>/<key>.terminal-noted, .terminal-alerted,
// .after-since, .after-released, .after-loop, .defer-to-human). A rebuilt hub
// read "never noted, never waited" and paged or commented again. Each file gets
// a pool_markers row; the file stays the fail-open copy. The writers and the
// union read go through bin/lib/pool-state-rows.sh; the read is the markers
// list of GET /api/pool-state (routes/pool-state.js), so a tick still makes
// one read.

import { json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";

// The marker names: the file suffix, except `cap-wait` for .defer-to-human.
const MARKERS = new Set(["terminal-noted", "terminal-alerted", "after-since", "after-released", "after-loop", "cap-wait"]);
const VALUE_MAX = 500;
// The same box shape routes/pool-state.js accepts.
const BOX_RE = /^[A-Za-z0-9._-]{1,64}(#[0-9]{1,6})?$/;

const boxOf = (v) => (typeof v === "string" && BOX_RE.test(v) ? v : "");
const isTrue = (v) => v === true || v === 1 || v === "1" || v === "true";
const bad = (error) => json(400, { error });

export const routes = [
  // One marker. value is stored as sent, tabs included. if_absent never
  // overwrites a row, so a heal from a file cannot undo a newer row.
  [
    "PUT", "/api/pool-state/markers",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key);
      if (!project || !key) return bad("project and key must match [A-Za-z0-9._-]{1,64}");
      const marker = typeof body.marker === "string" && MARKERS.has(body.marker) ? body.marker : "";
      if (!marker) return bad(`marker must be one of ${[...MARKERS].join(", ")}`);
      let value = "";
      if (body.value !== undefined && body.value !== null) {
        if (typeof body.value !== "string") return bad("value must be a string");
        if (body.value.length > VALUE_MAX) return bad(`value is over ${VALUE_MAX} characters`);
        value = body.value;
      }
      const box = body.box === undefined || body.box === null || body.box === "" ? null : boxOf(body.box);
      if (box === "") return bad("box is not a box name");
      await ensureTable(env, "pool_markers");
      const tail = isTrue(body.if_absent)
        ? "ON CONFLICT(project, ticket_key, marker) DO NOTHING"
        : "ON CONFLICT(project, ticket_key, marker) DO UPDATE SET value = excluded.value, box = excluded.box, "
          + "updated_at = excluded.updated_at";
      // sql-ident-ok: tail is one of two literal ON CONFLICT clauses
      const r = await env.DB.prepare(
        "INSERT INTO pool_markers (project, ticket_key, marker, value, box, updated_at) "
        + `VALUES (?1, ?2, ?3, ?4, ?5, ?6) ${tail}`
      ).bind(project, key, marker, value, box, t).run();
      return json(200, { ok: true, written: Number((r.meta && r.meta.changes) || 0) > 0 ? 1 : 0 });
    },
  ],

  // Clearing markers deletes their rows, as the files are deleted. Only the
  // named markers of this key; a marker with no row is not an error.
  [
    "PATCH", "/api/pool-state/markers",
    async ({ env, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key);
      if (!project || !key) return bad("project and key must match [A-Za-z0-9._-]{1,64}");
      if (!isTrue(body.clear)) return bad("send clear:true");
      const list = body.markers;
      if (!Array.isArray(list) || list.length === 0 || list.length > MARKERS.size) {
        return bad(`markers must be a non-empty array of at most ${MARKERS.size}`);
      }
      if (!list.every((m) => typeof m === "string" && MARKERS.has(m))) {
        return bad(`each marker must be one of ${[...MARKERS].join(", ")}`);
      }
      await ensureTable(env, "pool_markers");
      const r = await env.DB.prepare(
        "DELETE FROM pool_markers WHERE project = ?1 AND ticket_key = ?2 AND marker IN (SELECT value FROM json_each(?3))"
      ).bind(project, key, JSON.stringify([...new Set(list)])).run();
      return json(200, { ok: true, removed: Number((r.meta && r.meta.changes) || 0) });
    },
  ],
];
