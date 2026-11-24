// claude-cli-smoke routes — BH-9911, the canary smoke of a new Claude Code CLI.
//
// NEW family (test/route-table.d/bh-9911-claude-cli-smoke.txt). Bearer-gated.
// bin/claude-cli-smoke.sh (the canary box) POSTs one row per smoke step; it
// and bin/claude-cli-pin.sh promote (hub) read the rows of one (box, version)
// back. Table claude_cli_smoke (schema.d/202611241159-bh-9911-claude-cli-smoke.sql).
//
//   POST /api/claude-cli/smoke {rows:[{box, version, run_id, step, ok, rc, ms,
//        detail, at}]} -> 200 {accepted, inserted}. 1..rows-max rows. Every row
//        must be valid or the whole request is 400 and nothing is written.
//        ON CONFLICT on (box, version, run_id, step) DO NOTHING, so a resend of
//        a pending file inserts 0.
//   GET  /api/claude-cli/smoke?box=&version=[&limit=] -> 200 {rows} newest at
//        first. box and version are required; limit 1..limit-max, default
//        limit-default. Served by idx_claude_cli_smoke_box_version_at.
//
// THE BOUNDS ARE KNOBS. Each is a settings row (seeded in
// schema.d/202611241200-bh-9911-claude-cli-smoke-caps.sql), read through the
// per-isolate settings snapshot (lib/settings-cache.js, no extra D1 read while
// it is fresh). The code constant beside each key is the documented fallback,
// used when the row is absent or not an integer in [1, hi]. The client's own
// knob (claude_cli.smoke_list_limit, default 200) picks the limit inside them;
// a smoke run writes six rows.

import { json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

const STEPS = new Set(["stdin", "late_stdin", "tool_call", "haiku", "lane_tick", "fail_classes"]);
const VERSION_RE = /^\d+\.\d+\.\d+$/;
// { key, def (the code fallback), hi }. hi is the accepted range of the
// settings row, [1, hi]: the same job as min/max in a knob registry row. A row
// outside it is a typo, so the code fallback applies instead.
export const ROWS_MAX = { key: "claude_cli.smoke_post_rows_max", def: 50, hi: 1000 };
export const DETAIL_MAX = { key: "claude_cli.smoke_detail_max", def: 500, hi: 10000 };
export const LIMIT_MAX = { key: "claude_cli.smoke_list_limit_max", def: 500, hi: 10000 };
export const LIMIT_DEFAULT = { key: "claude_cli.smoke_list_limit_default", def: 100, hi: 10000 };
export const BOX_MAX_LEN = { key: "claude_cli.smoke_box_max_len", def: 128, hi: 1000 };
export const RUN_ID_MAX_LEN = { key: "claude_cli.smoke_run_id_max_len", def: 80, hi: 1000 };
export const AT_MAX_LEN = { key: "claude_cli.smoke_at_max_len", def: 40, hi: 1000 };

// knob(byKey, k) -> the row as an integer in [1, k.hi], else k.def.
function knob(byKey, k) {
  const r = byKey.get(k.key);
  const s = r && r.value !== null && r.value !== undefined ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= 1 && n <= k.hi ? n : k.def;
}

// A non-empty string no longer than max, else null: an over-long value is
// refused, never cut.
const text = (v, max) => (typeof v === "string" && v !== "" && v.length <= max ? v : null);
const intOrNull = (v) => (v === null || v === undefined ? null : Number.isInteger(v) ? v : undefined);

// validRow(r, cap) -> the row to insert, or null when any field is out of
// shape. cap = {detail, box, runId, at}, each read through knob().
function validRow(r, cap) {
  if (!r || typeof r !== "object") return null;
  const box = text(r.box, cap.box);
  const version = typeof r.version === "string" ? r.version : "";
  const runId = text(r.run_id, cap.runId);
  const at = text(r.at, cap.at);
  if (!box || !runId || !at || !VERSION_RE.test(version)) return null;
  if (!STEPS.has(r.step)) return null;
  if (r.ok !== 0 && r.ok !== 1) return null;
  const rc = intOrNull(r.rc);
  const ms = intOrNull(r.ms);
  if (rc === undefined || ms === undefined) return null;
  const detail = r.detail === undefined || r.detail === null ? "" : r.detail;
  if (typeof detail !== "string" || detail.length > cap.detail) return null;
  return { box, version, runId, step: r.step, ok: r.ok, rc, ms, detail, at };
}

export const routes = [
  [
    "POST", "/api/claude-cli/smoke",
    async ({ env, t, body }) => {
      const rows = Array.isArray(body && body.rows) ? body.rows : null;
      if (!rows || rows.length === 0) return json(400, { error: "rows[] required" });
      const { byKey } = await settingsRows(env);
      const rowsMax = knob(byKey, ROWS_MAX);
      const detailMax = knob(byKey, DETAIL_MAX);
      if (rows.length > rowsMax) return json(400, { error: `at most ${rowsMax} rows per request` });
      const cap = { detail: detailMax, box: knob(byKey, BOX_MAX_LEN), runId: knob(byKey, RUN_ID_MAX_LEN), at: knob(byKey, AT_MAX_LEN) };
      const valid = rows.map((r) => validRow(r, cap));
      const badAt = valid.findIndex((v) => v === null);
      if (badAt !== -1) {
        return json(400, { error: `row ${badAt}: needs box, run_id, at, version x.y.z, step (${[...STEPS].join("|")}), ok 0|1, integer rc/ms, detail <= ${detailMax} chars` });
      }
      const stmts = valid.map((v) => env.DB.prepare(
        `INSERT INTO claude_cli_smoke (box, version, run_id, step, ok, rc, ms, detail, at, inserted_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
         ON CONFLICT(box, version, run_id, step) DO NOTHING`
      ).bind(v.box, v.version, v.runId, v.step, v.ok, v.rc, v.ms, v.detail, v.at, t));
      const results = await env.DB.batch(stmts);
      const inserted = (Array.isArray(results) ? results : [])
        .reduce((a, x) => a + ((x && x.meta && Number(x.meta.changes)) || 0), 0);
      return json(200, { accepted: valid.length, inserted, as_of: t });
    },
  ],

  [
    "GET", "/api/claude-cli/smoke",
    async ({ env, url, t }) => {
      const { byKey } = await settingsRows(env);
      const box = text(url.searchParams.get("box"), knob(byKey, BOX_MAX_LEN));
      const version = url.searchParams.get("version") || "";
      if (!box || !VERSION_RE.test(version)) return json(400, { error: "box and version (x.y.z) are required" });
      const limitMax = knob(byKey, LIMIT_MAX);
      const raw = Number(url.searchParams.get("limit"));
      const limit = Number.isInteger(raw) && raw > 0 ? Math.min(raw, limitMax) : Math.min(knob(byKey, LIMIT_DEFAULT), limitMax);
      const res = await env.DB.prepare(
        `SELECT box, version, run_id, step, ok, rc, ms, detail, at FROM claude_cli_smoke
         WHERE box = ?1 AND version = ?2 ORDER BY at DESC LIMIT ?3`
      ).bind(box, version, limit).all();
      return json(200, { rows: res.results || [], as_of: t });
    },
  ],
];
