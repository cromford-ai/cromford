// Mission Control box controls (BH-5750): the owner gate, the per-type args
// and the price a quote row recorded. routes/box-commands.js calls these for
// the OWNER_ONLY types; the five BH-2518 types never reach them.
//
// OWNER. The coord proxy stamps `actor` from a verified Cloudflare Access
// email, else 'console'. An owner is an actor named in the worker secret
// BOX_OPS_OWNERS (a comma list). Both sides are trimmed and lower-cased once,
// here. An unset or blank secret means nobody is an owner (fail closed).
//
// PRICE. A costing type (QUOTE_OF) names a finished quote row of its quote
// type. The figure is read from that row's detail, which bin/box-ops.sh wrote
// from the script's own output; it is never a client value:
//   resize: the FIRST `COST: resize <id> +$<n>/mo` or `PLAN cost +$<n>/mo`
//           line (the dry run prints the PLAN form, an apply the COST form);
//           an ok quote with neither line costs 0 (a shrink or no change).
//   launch: `usd_mo=<n>` from the `box-launch: … usd_mo=<n> …` summary; none
//           is no figure, never 0.

import { QUOTE_OF } from "./box-command-types.js";

const ACTOR_RE = /^[a-z0-9._@-]{1,96}$/;
const BOX_ID_RE = /^[a-z][a-z0-9]{0,31}$/;
const NAME_RE = /^[A-Za-z0-9._-]{1,64}$/;
const IPV4_RE = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;
export const USD_RE = /^\d+(\.\d{1,2})?$/;
// Fallback for the operator's settings row box_ops_quote_ttl_s.
export const QUOTE_TTL_S = 900;

// The actor as the owner list compares it: trimmed, lower-cased, or "".
export function normActor(v) {
  const s = String(v === undefined || v === null ? "" : v).trim().toLowerCase();
  return ACTOR_RE.test(s) ? s : "";
}

export function isOwner(env, actor) {
  const a = normActor(actor);
  if (!a) return false;
  const owners = String(env?.BOX_OPS_OWNERS ?? "").split(",").map(normActor).filter(Boolean);
  return owners.includes(a);
}

const posInt = (v) => Number.isInteger(v) && v > 0;
const specs = ["vcpus", "mem_gb", "disk_gb"];

// → { target, args } or { error } (a 400).
export function orgoArgs(type, body) {
  if (body.box !== "hub") return { error: `${type} is addressed to box 'hub'` };
  const isFlyPool = type === "fly_pool_cap" || type === "fly_onboard";
  const target = body.target;
  if (isFlyPool) {
    if (!(typeof target === "string" && NAME_RE.test(target))) return { error: "target must be a project name [A-Za-z0-9._-]{1,64}" };
  } else if (!(typeof target === "string" && BOX_ID_RE.test(target) && target !== "hub")) {
    return { error: "target must be an Orgo box id ^[a-z][a-z0-9]{0,31}$ and not hub" };
  }
  const args = {};
  const account = () => {
    if (!(typeof body.account === "string" && NAME_RE.test(body.account))) return "account is required and must match [A-Za-z0-9._-]{1,64}";
    args.account = body.account;
    return null;
  };
  const spec = (need) => {
    let any = false;
    for (const k of specs) {
      if (body[k] === undefined || body[k] === null) {
        if (need === "all") return `${k} is required`;
        continue;
      }
      if (!posInt(body[k])) return `${k} must be a positive integer`;
      args[k] = body[k];
      any = true;
    }
    return any ? null : "at least one of vcpus, mem_gb, disk_gb is required";
  };
  let err = null;
  switch (type) {
    case "orgo_restart":
    case "orgo_stop":
      if (body.account !== undefined && body.account !== null && body.account !== "") err = account();
      break;
    case "orgo_resize_quote":
    case "orgo_resize":
      err = account() || spec("any");
      break;
    case "orgo_launch_quote":
    case "orgo_launch":
      err = account() || spec("all");
      if (!err) {
        if (!(typeof body.project === "string" && NAME_RE.test(body.project))) err = "project is required and must match [A-Za-z0-9._-]{1,64}";
        else args.project = body.project;
      }
      break;
    case "orgo_retire":
      if (body.to !== undefined && body.to !== null && body.to !== "") {
        if (!(typeof body.to === "string" && BOX_ID_RE.test(body.to) && body.to !== "hub" && body.to !== target)) err = "to must be another Orgo box id, not hub";
        else args.to = body.to;
      }
      if (!err && body.ip !== undefined && body.ip !== null && body.ip !== "") {
        if (!(typeof body.ip === "string" && IPV4_RE.test(body.ip))) err = "ip must be an IPv4 address";
        else args.ip = body.ip;
      }
      if (!err) {
        if (body.delete === undefined || body.delete === null) args.delete = false;
        else if (typeof body.delete !== "boolean") err = "delete must be true or false";
        else args.delete = body.delete;
      }
      break;
    case "fly_pool_cap":
      if (!posInt(body.cap)) err = "cap must be a positive integer";
      else args.cap = body.cap;
      break;
    case "fly_onboard":
      if (body.cap !== undefined && body.cap !== null) {
        if (!posInt(body.cap)) err = "cap must be a positive integer";
        else args.cap = body.cap;
      }
      break;
    default:
      err = `no args rule for ${type}`;
  }
  if (err) return { error: err };
  if (QUOTE_OF[type]) {
    if (!Number.isInteger(body.quote_id) || body.quote_id <= 0
        || !(typeof body.confirm_monthly_usd === "string" && USD_RE.test(body.confirm_monthly_usd))) {
      return { error: "confirm_token_required" };
    }
    args.quote_id = body.quote_id;
    args.confirm_monthly_usd = body.confirm_monthly_usd;
  }
  return { target, args };
}

// The monthly USD figure a finished quote row recorded, as a string, or null.
export function quoteFigure(quoteType, detail) {
  if (typeof detail !== "string") return null;
  if (quoteType === "orgo_resize_quote") {
    const m = /(?:COST: resize \S+|PLAN cost) \+\$(\d+(?:\.\d+)?)\/mo/.exec(detail);
    return m ? m[1] : "0";
  }
  if (quoteType === "orgo_launch_quote") {
    const m = /\busd_mo=(\d+(?:\.\d+)?)\b/.exec(detail);
    return m ? m[1] : null;
  }
  return null;
}

// Args a quote and its apply must share: everything but the token.
function boundArgs(a) {
  const { quote_id: _q, confirm_monthly_usd: _c, ...rest } = a || {};
  return JSON.stringify(Object.keys(rest).sort().map((k) => [k, rest[k]]));
}

// true when `quote` (a box_commands_v2 row, args parsed) prices this request.
export function quoteMatches(quote, { type, target, args, actor, cutoff }) {
  if (!quote || quote.type !== QUOTE_OF[type] || quote.target !== target || quote.status !== "ok") return false;
  if (typeof quote.finished_at !== "string" || quote.finished_at < cutoff) return false;
  if (normActor(quote.requested_by) !== normActor(actor)) return false;
  const qa = typeof quote.args === "string" ? (() => { try { return JSON.parse(quote.args); } catch { return null; } })() : quote.args;
  if (!qa || boundArgs(qa) !== boundArgs(args)) return false;
  const fig = quoteFigure(quote.type, quote.detail);
  return fig !== null && Number(fig) === Number(args.confirm_monthly_usd);
}
