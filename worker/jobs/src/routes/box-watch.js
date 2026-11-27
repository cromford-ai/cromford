// box-watch routes — the restart rows of the hub box-watch duty (BH-10231,
// C1 of BH-9889). bin/box-watch.sh restarts a fleet box that failed
// box_watch.fail_probes ssh probes in a row; each restart attempt is one
// box_watch_actions row (schema.d/202611261440-bh-10231-box-watch.sql). The
// BOX WATCH section of /staff/quartermaster lists them.
// Note: docs/notes/2026-11-26-BH-10231-box-watch.md.
//
// POST /api/box-watch/claim {box, box_id?, probes}
//   The restart window, decided in ONE statement: INSERT ... WHERE NOT EXISTS
//   a row for the box with acted_at inside box_watch.restart_window_min (the
//   settings row, read here; fallback 120, a value outside 5..10080 is 120).
//   → 200 {claimed:true, id, window_min, as_of}, or
//   → 200 {claimed:false, id: <last id>, last_acted_at, window_min, as_of}.
//   Bad fields are 400, never clamped: box not [A-Za-z0-9._-]{1,64}, box_id
//   not ^[a-z][a-z0-9]*$ (or absent), probes not an integer 0..100000.
//   Statements: the settings row, the insert, and (refused only) the last row.
// POST /api/box-watch/actions/:id {box, probes, restart_rc, recovery_rc,
//   outcome, back_at, detail}
//   The end state, written once: UPDATE ... WHERE id AND box AND outcome
//   'claimed'. outcome one of refused, restart_failed, still_dark, back;
//   restart_rc and recovery_rc integers -1..255 or null; back_at
//   YYYY-MM-DDTHH:MM:SSZ or null (required for back, refused otherwise);
//   detail a string up to 500 chars or null. → 200 {id, outcome, as_of}; the
//   same body again → 200 {replay:true}; a row of another box or already
//   ended another way → 409; no such id → 404.
// GET /api/box-watch/actions?limit=<1..200, default 50>&box=<box>
//   → 200 {actions:[{id, box, box_id, probes, acted_at, outcome, restart_rc,
//   recovery_rc, back_at, detail, ended_at}], limit, as_of}, newest first.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";

export const WINDOW_KEY = "box_watch.restart_window_min";
// Fallback of the settings row WINDOW_KEY (seeded 120 in the schema fragment).
export const WINDOW_FALLBACK_MIN = 120;
const WINDOW_LO = 5;
const WINDOW_HI = 10080;
// Input validation of the list read, not a work knob: the route's page size.
export const LIST_DEFAULT = 50;
export const LIST_MAX = 200;
const DETAIL_MAX = 500;
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const BOX_ID_RE = /^[a-z][a-z0-9]*$/;
const END_OUTCOMES = new Set(["refused", "restart_failed", "still_dark", "back"]);

export const SQL = {
  window: `SELECT value FROM settings WHERE key = ?1`,
  // ?1 box, ?2 box_id, ?3 probes, ?4 t, ?5 the cutoff. idx_box_watch_actions_box
  // serves the NOT EXISTS.
  claim: `INSERT INTO box_watch_actions (box, box_id, probes, acted_at, outcome)
          SELECT ?1, ?2, ?3, ?4, 'claimed'
           WHERE NOT EXISTS (SELECT 1 FROM box_watch_actions WHERE box = ?1 AND acted_at > ?5)`,
  last: `SELECT id, acted_at FROM box_watch_actions WHERE box = ?1 ORDER BY acted_at DESC LIMIT 1`,
  end: `UPDATE box_watch_actions
           SET outcome = ?3, probes = ?4, restart_rc = ?5, recovery_rc = ?6, back_at = ?7, detail = ?8, ended_at = ?9
         WHERE id = ?1 AND box = ?2 AND outcome = 'claimed'`,
  one: `SELECT id, box, probes, outcome, restart_rc, recovery_rc, back_at, detail FROM box_watch_actions WHERE id = ?1`,
  list: `SELECT id, box, box_id, probes, acted_at, outcome, restart_rc, recovery_rc, back_at, detail, ended_at
           FROM box_watch_actions ORDER BY acted_at DESC, id DESC LIMIT ?1`,
  listBox: `SELECT id, box, box_id, probes, acted_at, outcome, restart_rc, recovery_rc, back_at, detail, ended_at
              FROM box_watch_actions WHERE box = ?2 ORDER BY acted_at DESC, id DESC LIMIT ?1`,
};

const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
const obj = (b) => (b && typeof b === "object" && !Array.isArray(b) ? b : {});
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

export function windowMin(raw) {
  const s = raw === null || raw === undefined ? "" : String(raw).trim();
  if (!/^\d{1,6}$/.test(s)) return WINDOW_FALLBACK_MIN;
  const n = Number(s);
  return n >= WINDOW_LO && n <= WINDOW_HI ? n : WINDOW_FALLBACK_MIN;
}

const nullableRc = (v) => v === null || v === undefined || isInt(v, -1, 255);

export const routes = [
  [
    "POST", "/api/box-watch/claim",
    ({ env, t, body }) => d1Guarded("box_watch_actions", async () => {
      const b = obj(body);
      const box = typeof b.box === "string" ? laneName(b.box) : "";
      if (!box || box !== b.box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
      const boxId = b.box_id === undefined || b.box_id === null ? null : b.box_id;
      if (boxId !== null && !(typeof boxId === "string" && boxId.length <= 64 && BOX_ID_RE.test(boxId))) {
        return json(400, { error: "box_id must match ^[a-z][a-z0-9]*$" });
      }
      if (!isInt(b.probes, 0, 100000)) return json(400, { error: "probes must be an integer 0..100000" });
      const row = await env.DB.prepare(SQL.window).bind(WINDOW_KEY).first();
      const win = windowMin(row ? row.value : null);
      const cutoff = iso(Date.parse(t) - win * 60000);
      const ins = await env.DB.prepare(SQL.claim).bind(box, boxId, b.probes, t, cutoff).run();
      if (ins.meta && ins.meta.changes === 1) {
        return json(200, { claimed: true, id: Number(ins.meta.last_row_id), window_min: win, as_of: t });
      }
      const last = await env.DB.prepare(SQL.last).bind(box).first();
      return json(200, {
        claimed: false, id: last ? Number(last.id) : null, last_acted_at: last ? last.acted_at : null,
        window_min: win, as_of: t,
      });
    }),
  ],
  [
    "POST", /^\/api\/box-watch\/actions\/(\d{1,15})$/,
    ({ env, t, body, m }) => d1Guarded("box_watch_actions", async () => {
      const id = Number(m[1]);
      const b = obj(body);
      if (!Number.isSafeInteger(id) || id < 1) return json(400, { error: "id must be a positive integer" });
      const box = typeof b.box === "string" ? laneName(b.box) : "";
      if (!box || box !== b.box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!END_OUTCOMES.has(b.outcome)) return json(400, { error: `outcome must be one of ${[...END_OUTCOMES].join(", ")}` });
      if (!isInt(b.probes, 0, 100000)) return json(400, { error: "probes must be an integer 0..100000" });
      if (!nullableRc(b.restart_rc)) return json(400, { error: "restart_rc must be an integer -1..255 or null" });
      if (!nullableRc(b.recovery_rc)) return json(400, { error: "recovery_rc must be an integer -1..255 or null" });
      const back = b.back_at === undefined || b.back_at === null ? null : b.back_at;
      if (back !== null && !(typeof back === "string" && ISO_RE.test(back))) return json(400, { error: "back_at must be YYYY-MM-DDTHH:MM:SSZ or null" });
      if ((b.outcome === "back") !== (back !== null)) return json(400, { error: "back_at is required for outcome back and refused for any other outcome" });
      const detail = b.detail === undefined || b.detail === null ? null : b.detail;
      if (detail !== null && !(typeof detail === "string" && detail.length <= DETAIL_MAX)) return json(400, { error: `detail must be a string up to ${DETAIL_MAX} chars or null` });
      const rrc = b.restart_rc ?? null;
      const vrc = b.recovery_rc ?? null;
      const up = await env.DB.prepare(SQL.end).bind(id, box, b.outcome, b.probes, rrc, vrc, back, detail, t).run();
      if (up.meta && up.meta.changes === 1) return json(200, { id, outcome: b.outcome, as_of: t });
      const row = await env.DB.prepare(SQL.one).bind(id).first();
      if (!row) return json(404, { error: "no such box-watch action", id });
      const same = row.box === box && row.outcome === b.outcome && Number(row.probes) === b.probes
        && (row.restart_rc ?? null) === rrc && (row.recovery_rc ?? null) === vrc
        && (row.back_at ?? null) === back && (row.detail ?? null) === detail;
      if (same) return json(200, { id, outcome: row.outcome, replay: true, as_of: t });
      return json(409, { error: `action ${id} is ${row.outcome} for box ${row.box}`, id, outcome: row.outcome, box: row.box });
    }),
  ],
  [
    "GET", "/api/box-watch/actions",
    ({ env, t, url }) => d1Guarded("box_watch_actions", async () => {
      const ls = url.searchParams.get("limit");
      let limit = LIST_DEFAULT;
      if (ls !== null) {
        if (!/^\d{1,4}$/.test(ls) || Number(ls) < 1 || Number(ls) > LIST_MAX) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });
        limit = Number(ls);
      }
      const bs = url.searchParams.get("box");
      let res;
      if (bs !== null) {
        const box = laneName(bs);
        if (!box || box !== bs) return json(400, { error: "box must match [A-Za-z0-9._-]{1,64}" });
        res = await env.DB.prepare(SQL.listBox).bind(limit, box).all();
      } else {
        res = await env.DB.prepare(SQL.list).bind(limit).all();
      }
      return json(200, { actions: res.results || [], limit, as_of: t });
    }),
  ],
];
