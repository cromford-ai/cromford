// box-commands routes — BH-2659 (BH-2518.1) on the BH-2658 contract; r2 rebuild of #2825.
//
// An operator asks for a box or machine op (backup now, stop or destroy a Fly
// machine, harness-sync, CLI update). The one store is box_commands
// (schema.sql); the box_commands_open partial unique index allows one open
// command per (box, type, target), and every claim is a compare-and-swap judged
// by meta.changes, never by a read before it. This slice only records requests:
// no box lane or console screen consumes it yet (BH-2518 siblings), and nothing
// here calls Fly.
//
// POST /api/box-commands   body {box, type, target, project, app, reason, actor, confirm}
//   Checks run in this order:
//   - confirm is not the literal true → 400 {error:"confirm_required"} and ONE
//     box_command_refused audit row (actor "unknown" when none is given). No
//     command row.
//   - reason missing or blank → 400 {error:"reason_required"}.
//   - type not one of TYPES (lib/box-command-types.js) → 400.
//   - an OWNER_ONLY type (the Orgo and Fly pool controls, BH-5750) from an
//     actor not in env.BOX_OPS_OWNERS → 403 {error:"owner_only"} and ONE
//     box_command_refused audit row (outcome refused:owner). No command row.
//   - box not [A-Za-z0-9._-]{1,64} → 400.
//   - box other than 'hub' without a box_status row → 409 {error:"unknown_box"}.
//   - Fly types: box must be 'hub', target a machine id ([0-9a-z]{8,32]), and
//     project and app [A-Za-z0-9._-]{1,64}; they are stored as args JSON.
//     OWNER_ONLY types: box 'hub' and the per-type args of
//     lib/box-command-args.js orgoArgs, stored as args JSON; each failure is
//     400. A costing type (orgo_resize, orgo_launch) needs quote_id and
//     confirm_monthly_usd (400 confirm_token_required without them), and the
//     quote must be an ok row of its quote type for the same target and args,
//     requested by the same actor, finished within settings
//     box_ops_quote_ttl_s (fallback 900 s), whose recorded figure equals
//     confirm_monthly_usd as a number; else 409 {error:"stale_quote"} and ONE
//     audit row (refused:quote). An open row of the same (box, type, target)
//     with other args is 409 {error:"open_command_differs", id}, never a
//     silent dedup.
//     Other types: target must be absent or '', args is null, project and app
//     are ignored. Each failure is 400.
//   - otherwise INSERT OR IGNORE the command and its box_command_request audit
//     row in ONE batch → 201 {id, status, command, deduped:false}. An open
//     command for the same (box, type, target) is not an error: 200
//     {id, status, command, deduped:true} with that command's id. The audit row
//     is written either way: it records the ask.
//
// GET /api/box-commands[?box=]
//   → 200 {commands:[…last 50, newest first…], truncated:boolean, as_of}.
//   An empty ?box= lists every box; an invalid one is 400.
//
// POST /api/box-commands/claim   body {claimer, boxes:[…]}
//   → 200 {command} for the oldest `requested` command on one of the listed
//   boxes, or a `claimed` one whose claimed_at is older than the settings row
//   box_commands_claim_ttl_s (fallback 1800 s); 200 {command:null} when there
//   is none or the CAS lost the race. boxes is 1..50 valid names; any bad entry
//   is a 400, never a silent drop.
//
// POST /api/box-commands/:id/result   (:id = \d+)   body {claimer, ok, detail}
//   - ok must be the JSON literal true or false; detail a string ≤500 or null.
//   → 200 {ok:true, command}, or 409 {error:"not_claimed_by_you"} unless the row
//     is `claimed` BY this claimer (a wrong claimer, a finished row, an unknown id).
//
// Every `command` in a response carries args parsed from its JSON; a row whose
// args does not parse is returned with the raw string rather than failing.
// `claim` is listed before the :id regexp; \d+ cannot match it either way.

import { json, d1Guarded } from "../lib/http.js";
import { laneName, strictInt, isoPlusSeconds } from "../lib/core.js";
import { confirmed, auditStmt, knownBox } from "../lib/hub-recovery.js";
import { TYPES, FLY, OWNER_ONLY, QUOTE_OF } from "../lib/box-command-types.js";
import { normActor, isOwner, orgoArgs, quoteMatches, QUOTE_TTL_S } from "../lib/box-command-args.js";
const MACHINE_RE = /^[0-9a-z]{8,32}$/;
const HISTORY_LIMIT = 50;
// Fallback for the operator's settings row. THE ROW WINS whenever it parses as
// a positive int; this is what a D1 without the row uses.
const CLAIM_TTL_S = 1800;
// A bound on the claim's IN list, well under D1's bind-parameter limit.
const MAX_BOXES = 50;
const NAME_ERR = "must match [A-Za-z0-9._-]{1,64}";

async function quoteTtl(env) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key='box_ops_quote_ttl_s'").first("value");
  const n = strictInt(v);
  return n !== null && n > 0 ? n : QUOTE_TTL_S;
}

async function claimTtl(env) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key='box_commands_claim_ttl_s'").first("value");
  const n = strictInt(v);
  return n !== null && n > 0 ? n : CLAIM_TTL_S;
}

const name = (v) => (typeof v === "string" ? laneName(v) : "");

function shape(row) {
  if (!row || row.args === null || row.args === undefined) return row;
  try { return { ...row, args: JSON.parse(row.args) }; } catch { return row; }
}

const byId = async (env, id) => shape(await env.DB.prepare("SELECT * FROM box_commands_v2 WHERE id=?1").bind(id).first());

export const routes = [
  ["POST", "/api/box-commands", ({ env, t, body }) => d1Guarded("box_commands", async () => {
    // An Access email has an '@', which laneName refuses; normActor keeps it.
    const actor = laneName(body.actor) || normActor(body.actor) || "unknown";
    const reason = typeof body.reason === "string" ? body.reason.trim().slice(0, 500) : null;
    if (!confirmed(body)) {
      const rawBox = typeof body.box === "string" ? body.box.slice(0, 64) : null;
      await env.DB.batch([auditStmt(env, {
        action: "box_command_refused", target: rawBox, actor, reason: reason || null, outcome: "refused:confirm",
      }, t)]);
      return json(400, { error: "confirm_required" });
    }
    if (!reason) return json(400, { error: "reason_required" });
    const type = body.type;
    if (!TYPES.includes(type)) return json(400, { error: `type must be one of ${TYPES.join(", ")}` });
    const refuse = async (status, error, outcome, extra = {}) => {
      await env.DB.batch([auditStmt(env, {
        action: "box_command_refused", target: typeof body.box === "string" ? body.box.slice(0, 64) : null, actor, reason, outcome,
      }, t)]);
      return json(status, { error, ...extra });
    };
    if (OWNER_ONLY.has(type) && !isOwner(env, actor)) return refuse(403, "owner_only", "refused:owner");
    const box = name(body.box);
    if (!box) return json(400, { error: `box is required and ${NAME_ERR}` });
    // The owner types are all addressed to 'hub'; orgoArgs refuses any other box.
    const a = OWNER_ONLY.has(type) ? orgoArgs(type, body) : null;
    if (a?.error) return json(400, { error: a.error });
    if (box !== "hub" && !(await knownBox(env, box))) return json(409, { error: "unknown_box" });
    let target = "";
    let args = null;
    if (a) {
      if (QUOTE_OF[type]) {
        const quote = await env.DB.prepare("SELECT * FROM box_commands_v2 WHERE id=?1").bind(a.args.quote_id).first();
        const cutoff = isoPlusSeconds(t, -(await quoteTtl(env)));
        if (!quoteMatches(quote, { type, target: a.target, args: a.args, actor, cutoff })) {
          return refuse(409, "stale_quote", "refused:quote");
        }
      }
      const open = await env.DB.prepare(
        "SELECT id, args FROM box_commands_v2 WHERE box=?1 AND type=?2 AND target=?3 AND status IN ('requested','claimed') LIMIT 1",
      ).bind(box, type, a.target).first();
      if (open && open.args !== JSON.stringify(a.args)) return json(409, { error: "open_command_differs", id: open.id });
      target = a.target;
      args = JSON.stringify(a.args);
    } else if (FLY.has(type)) {
      if (box !== "hub") return json(400, { error: "Fly machine commands are addressed to box 'hub'" });
      if (!(typeof body.target === "string" && MACHINE_RE.test(body.target))) {
        return json(400, { error: "target must be a Fly machine id ([0-9a-z]{8,32})" });
      }
      const project = name(body.project);
      const app = name(body.app);
      if (!project || !app) return json(400, { error: `project and app are required and ${NAME_ERR}` });
      target = body.target;
      args = JSON.stringify({ project, app });
    } else if ((body.target ?? "") !== "") {
      return json(400, { error: `target is only allowed for ${[...FLY].join(", ")}` });
    }
    const res = await env.DB.batch([
      env.DB.prepare(
        "INSERT OR IGNORE INTO box_commands_v2 (box,type,target,args,reason,status,requested_by,requested_at) VALUES (?1,?2,?3,?4,?5,'requested',?6,?7)",
      ).bind(box, type, target, args, reason, actor, t),
      auditStmt(env, { action: "box_command_request", target: box, actor, reason, outcome: "ok" }, t),
    ]);
    const deduped = Number(res[0]?.meta?.changes || 0) === 0;
    const row = await env.DB.prepare(
      "SELECT * FROM box_commands_v2 WHERE box=?1 AND type=?2 AND target=?3 AND status IN ('requested','claimed') ORDER BY id DESC LIMIT 1",
    ).bind(box, type, target).first();
    if (!row) return json(503, { error: "box_commands unavailable", detail: "the open command was not readable after its insert" });
    return json(deduped ? 200 : 201, { id: row.id, status: row.status, command: shape(row), deduped });
  })],

  ["GET", "/api/box-commands", ({ env, t, url }) => d1Guarded("box_commands", async () => {
    const raw = url.searchParams.get("box");
    const box = raw ? laneName(raw) : "";
    if (raw && !box) return json(400, { error: `box ${NAME_ERR}` });
    const stmt = box
      ? env.DB.prepare("SELECT * FROM box_commands_v2 WHERE box=?1 ORDER BY id DESC LIMIT ?2").bind(box, HISTORY_LIMIT + 1)
      : env.DB.prepare("SELECT * FROM box_commands_v2 ORDER BY id DESC LIMIT ?1").bind(HISTORY_LIMIT + 1);
    const rows = (await stmt.all()).results || [];
    return json(200, { commands: rows.slice(0, HISTORY_LIMIT).map(shape), truncated: rows.length > HISTORY_LIMIT, as_of: t });
  })],

  ["POST", "/api/box-commands/claim", ({ env, t, body }) => d1Guarded("box_commands", async () => {
    const claimer = name(body.claimer);
    if (!claimer) return json(400, { error: `claimer is required and ${NAME_ERR}` });
    const list = Array.isArray(body.boxes) ? body.boxes.map(name) : [];
    if (list.length === 0 || list.length > MAX_BOXES || list.includes("")) {
      return json(400, { error: `boxes must be 1..${MAX_BOXES} names that each ${NAME_ERR}` });
    }
    const boxes = [...new Set(list)];
    const cutoff = isoPlusSeconds(t, -(await claimTtl(env)));
    const cand = await env.DB.prepare(
      "SELECT id FROM box_commands_v2 WHERE box IN (SELECT value FROM json_each(?2)) AND (status='requested' OR (status='claimed' AND claimed_at < ?1)) ORDER BY id LIMIT 1",
    ).bind(cutoff, JSON.stringify(boxes)).first("id");
    if (cand === null) return json(200, { command: null });
    const r = await env.DB.prepare(
      "UPDATE box_commands_v2 SET status='claimed', claimed_by=?1, claimed_at=?2 WHERE id=?3 AND (status='requested' OR (status='claimed' AND claimed_at < ?4))",
    ).bind(claimer, t, cand, cutoff).run();
    if (Number(r?.meta?.changes || 0) === 0) return json(200, { command: null });
    return json(200, { command: await byId(env, cand) });
  })],

  ["POST", /^\/api\/box-commands\/(\d+)\/result$/, ({ env, t, body, m }) => d1Guarded("box_commands", async () => {
    const id = Number(m[1]);
    const claimer = name(body.claimer);
    if (!claimer) return json(400, { error: `claimer is required and ${NAME_ERR}` });
    if (body.ok !== true && body.ok !== false) return json(400, { error: "ok must be true or false" });
    const detail = body.detail ?? null;
    if (detail !== null && !(typeof detail === "string" && detail.length <= 500)) {
      return json(400, { error: "detail must be a string of at most 500 characters" });
    }
    const r = await env.DB.prepare(
      "UPDATE box_commands_v2 SET status=?1, finished_at=?2, detail=?3 WHERE id=?4 AND status='claimed' AND claimed_by=?5",
    ).bind(body.ok ? "ok" : "fail", t, detail, id, claimer).run();
    if (Number(r?.meta?.changes || 0) === 0) return json(409, { error: "not_claimed_by_you" });
    return json(200, { ok: true, command: await byId(env, id) });
  })],
];
