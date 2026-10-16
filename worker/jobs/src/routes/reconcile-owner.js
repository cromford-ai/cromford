// reconcile-prs owner routes (BH-1607 contract, BH-1608 bodies).
//
// The owner box's heartbeat, the stale-owner read and the "already paged"
// stamp, all on reconcile_owner_beat (schema.sql). The watchdog judges
// staleness from age_s, which is computed HERE on the server clock: box clocks
// ran minutes slow on 2026-09-14, so a box-side subtraction is not evidence.

import { d1Guarded, json } from "../lib/http.js";
import { laneName, LANES_REGISTRY, LANE_DEFAULT_CADENCE_MIN } from "../lib/core.js";

const LANE = "reconcile-prs";
const OWNER_KEY = "lane.reconcile-prs.reconcile_prs_owner";
const NOW = "strftime('%Y-%m-%dT%H:%M:%SZ','now')";

function registryLane() {
  return (LANES_REGISTRY.lanes || []).find((l) => l.id === LANE) || {};
}

function tickSeconds(lane) {
  const m = /^\*\/(\d+) /.exec(String(lane.cadence || ""));
  return (m ? Number(m[1]) : LANE_DEFAULT_CADENCE_MIN) * 60;
}

export const routes = [
  [
    "POST", "/api/reconcile-prs/beat",
    async ({ env, body }) => d1Guarded("reconcile_owner_beat", async () => {
      const box = laneName(body && body.box);
      if (!box) return json(400, { error: "box required ([A-Za-z0-9._-]{1,64})" });
      // sql-ident-ok: NOW is a module const strftime expression
      await env.DB.prepare(
        `INSERT INTO reconcile_owner_beat (lane, box, beat_at, expected_since, updated_at) VALUES (?, ?, ${NOW}, ${NOW}, ${NOW}) ` +
        "ON CONFLICT(lane) DO UPDATE SET box=excluded.box, beat_at=excluded.beat_at, updated_at=excluded.updated_at",
      ).bind(LANE, box).run();
      return json(200, { ok: true, lane: LANE, box });
    }),
  ],
  [
    "GET", "/api/reconcile-prs/owner",
    async ({ env, t }) => d1Guarded("reconcile_owner_beat", async () => {
      const lane = registryLane();
      const row = await env.DB.prepare(
        "SELECT box, beat_at, expected_since, alerted_at, " +
        "CAST(strftime('%s','now') AS INTEGER) - CAST(strftime('%s', COALESCE(beat_at, expected_since)) AS INTEGER) AS age_s " +
        "FROM reconcile_owner_beat WHERE lane=?",
      ).bind(LANE).first();
      const set = await env.DB.prepare("SELECT value FROM settings WHERE key=?").bind(OWNER_KEY).first();
      const setValue = set && String(set.value || "").trim();
      const knob = (lane.knobs || []).find((k) => k.env === "RECONCILE_PRS_OWNER") || {};
      const owner = setValue || (knob.default === undefined ? null : knob.default);
      return json(200, {
        owner,
        owner_source: setValue ? "settings" : "registry",
        beat: row ? {
          box: row.box || null,
          beat_at: row.beat_at || null,
          expected_since: row.expected_since,
          age_s: Number(row.age_s),
          alerted: row.alerted_at !== null && row.alerted_at !== undefined,
        } : null,
        tick_s: tickSeconds(lane),
        as_of: t,
      });
    }),
  ],
  [
    "PATCH", "/api/reconcile-prs/owner/alert",
    async ({ env, body }) => d1Guarded("reconcile_owner_beat", async () => {
      const alerted = body && body.alerted;
      if (typeof alerted !== "boolean") return json(400, { error: "alerted must be a boolean" });
      // sql-ident-ok: NOW is a module const strftime expression
      const r = await env.DB.prepare(
        `UPDATE reconcile_owner_beat SET alerted_at = CASE WHEN ? THEN ${NOW} ELSE NULL END, updated_at = ${NOW} WHERE lane=?`,
      ).bind(alerted ? 1 : 0, LANE).run();
      return json(200, { ok: true, alerted, changed: Number((r && r.meta && r.meta.changes) || 0) });
    }),
  ],
];
