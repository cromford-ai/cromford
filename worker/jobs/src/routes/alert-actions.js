// alert-actions routes — BH-2368 laid the contract, BH-2369 filled it in
// (both children of BH-2324). test/route-table.d/525-alert-actions.txt pins
// this route list.
//
// The store is alert_actions (schema.sql, CREATED_TABLES in lib/core.js): one
// append-only row per console action on an alerts row, refusals included.
//
// POST /api/alerts/actions   body {id, action, actor, note?}
//   action is one of ack | snooze | resolve | note. A bad body is a 400 that
//   writes nothing; an unknown id is a 404 with a `refused:no-such-alert` row;
//   a refusal is a 409 with one `refused:<why>` row; success is 200
//   {alert, action, as_of}.
//
// GET /api/alerts/actions?id=<alert id>&limit=<n>
//   the action log for one alert, newest first: {actions, truncated, as_of}.

import { json } from "../lib/http.js";
import { ensureTable, intOrNull, isoPlusSeconds, leaseWon } from "../lib/core.js";
import { ALERT_ID_RE, ALERT_ACTOR_RE, alertKnobs } from "./alerts.js";

const ACTIONS = ["ack", "snooze", "resolve", "note"];
const NOTE_MAX = 1000;
const LIST_DEFAULT = 50;
const LIST_MAX = 200;

const AUDIT_COLS = "alert_id, action, actor, note, before_state, after_state, until, outcome, at";

async function postAction({ env, t, body }) {
  const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
  const id = typeof b.id === "string" ? b.id : "";
  if (!ALERT_ID_RE.test(id)) return json(400, { error: "id must match ^[A-Za-z0-9_.-]{1,120}$" });
  // A string or nothing: String() would turn ["ack"] into "ack" (BH-2405).
  const action = typeof b.action === "string" ? b.action : "";
  if (!ACTIONS.includes(action)) return json(400, { error: `action must be one of ${ACTIONS.join("|")}` });
  const actor = typeof b.actor === "string" ? b.actor : "";
  if (!ALERT_ACTOR_RE.test(actor)) return json(400, { error: "actor must match ^[A-Za-z0-9._@-]{1,96}$" });
  if (b.note !== undefined && b.note !== null && typeof b.note !== "string") {
    return json(400, { error: "note must be a string" });
  }
  const trimmed = typeof b.note === "string" ? b.note.trim() : "";
  if (trimmed.length > NOTE_MAX) return json(400, { error: `note must be at most ${NOTE_MAX} characters` });
  if (action === "note" && !trimmed) return json(400, { error: `a note needs 1..${NOTE_MAX} characters` });
  const note = trimmed || null;

  await ensureTable(env, "alerts");
  await ensureTable(env, "alert_actions");
  const row = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();

  // sql-ident-ok: AUDIT_COLS is a module constant
  const audit = (outcome, before, after, until = null) => env.DB.prepare(
    `INSERT INTO alert_actions (${AUDIT_COLS}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)`
  ).bind(id, action, actor, note, before, after, until, outcome, t);
  // A refusal is recorded against the state it was decided on, and changes
  // nothing on the alerts row.
  const refuse = async (why, cur, reply, status = 409) => {
    const state = cur ? cur.state : null;
    await audit(`refused:${why}`, state, state).run();
    return json(status, { ...reply, as_of: t });
  };

  if (!row) return refuse("no-such-alert", null, { error: "no such alert" }, 404);

  if (action === "note") {
    // Only the audit row. POST /api/alerts/note is a producer sighting and
    // would bump count/last_seen on the incident, so it is never called here.
    const r = await audit("ok", row.state, row.state).run();
    return done(env, id, actor, r, t);
  }

  // ONE batch per action: the audit INSERT ... SELECT comes FIRST and carries
  // the IDENTICAL predicate and binds as the UPDATE, so it reads the row before
  // the UPDATE lands and the two match the same row or neither does. An `ok`
  // row without its state change (or the reverse) cannot exist.
  const pair = (cas, binds, afterSql, set, setBinds, until = null) => {
    const n = binds.length;
    // sql-ident-ok: AUDIT_COLS is a constant; cas and afterSql are literals from the pair() calls below
    const ins = env.DB.prepare(
      `INSERT INTO alert_actions (${AUDIT_COLS})
       SELECT ?${n + 1}, ?${n + 2}, ?${n + 3}, ?${n + 4}, state, ${afterSql}, ?${n + 5}, 'ok', ?${n + 6}
       FROM alerts WHERE ${cas}`
    ).bind(...binds, id, action, actor, note, until, t);
    // sql-ident-ok: set and cas are literals from the pair() calls below
    const upd = env.DB.prepare(`UPDATE alerts SET ${set} WHERE ${cas}`).bind(...binds, ...setBinds);
    return env.DB.batch([ins, upd]);
  };

  if (action === "ack") {
    const from = String(row.state);
    if (from !== "new" && from !== "quarantined") {
      return refuse("disallowed-edge", row, { error: "disallowed edge", from });
    }
    const r = await pair("id=?1 AND state=?2 AND ?2 IN ('new','quarantined')", [id, from],
      "'triaged'", "state='triaged'", []);
    if (!leaseWon(r[1])) return refuse("contended", row, { error: "contended" });
    return done(env, id, actor, r[0], t);
  }

  if (action === "resolve") {
    if (row.state === "resolved") return refuse("already-resolved", row, { error: "already resolved" });
    const r = await pair("id=?1 AND state<>'resolved'", [id], "'resolved'", "state='resolved'", []);
    if (!leaseWon(r[1])) {
      const cur = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
      return refuse("already-resolved", cur, { error: "already resolved" });
    }
    return done(env, id, actor, r[0], t);
  }

  // snooze: take the row's claim for one lease, the same lease the lanes'
  // /api/alerts/claim honours, so alert-triage and alerts-medic skip it until
  // then. A live claim held by anyone else refuses; it is never stolen.
  const lease = (await alertKnobs(env)).claim_lease_s;
  const floor = isoPlusSeconds(t, -lease);
  const until = isoPlusSeconds(t, lease);
  const classify = (cur) => {
    if (!cur) return refuse("no-such-alert", null, { error: "no such alert" }, 404);
    if (cur.state === "resolved") return refuse("resolved", cur, { error: "resolved" });
    if (cur.claimed_by && cur.claimed_by !== actor && String(cur.claimed_at || "") > floor) {
      return refuse(`claimed:${cur.claimed_by}`, cur, { error: "claimed", claimed_by: cur.claimed_by });
    }
    return null;
  };
  const pre = classify(row);
  if (pre) return pre;
  const r = await pair(
    "id=?1 AND state<>'resolved' AND (claimed_by IS NULL OR claimed_at<=?2 OR claimed_by=?3)",
    [id, floor, actor], "state", "claimed_by=?3, claimed_at=?4", [t], until);
  if (!leaseWon(r[1])) {
    const cur = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
    return (await classify(cur)) || refuse("contended", cur, { error: "contended" });
  }
  return done(env, id, actor, r[0], t);
}

// The answer is what the tables hold after the write, not what we hoped to
// write: the alerts row re-read, and the audit row by the id the INSERT got
// (or, where a runtime reports no last_row_id, this actor's newest ok row at t).
async function done(env, id, actor, ins, t) {
  const alert = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
  const rid = Number(ins && ins.meta && ins.meta.last_row_id) || 0;
  let action = rid > 0
    ? await env.DB.prepare("SELECT * FROM alert_actions WHERE id=?1 AND alert_id=?2").bind(rid, id).first()
    : null;
  if (!action) {
    action = await env.DB.prepare(
      `SELECT * FROM alert_actions WHERE alert_id=?1 AND actor=?2 AND at=?3 AND outcome='ok'
       ORDER BY id DESC LIMIT 1`
    ).bind(id, actor, t).first();
  }
  return json(200, { alert, action, as_of: t });
}

async function listActions({ env, t, url }) {
  const q = url.searchParams;
  const id = q.get("id") || "";
  if (!ALERT_ID_RE.test(id)) return json(400, { error: "id must match ^[A-Za-z0-9_.-]{1,120}$" });
  // A page size is our capacity, not the caller's intent: it clamps, and
  // `truncated` is measured from the one extra row.
  const asked = intOrNull(q.get("limit"));
  const limit = asked === null || asked < 1 ? LIST_DEFAULT : Math.min(asked, LIST_MAX);
  await ensureTable(env, "alert_actions");
  const rows = await env.DB.prepare(
    "SELECT * FROM alert_actions WHERE alert_id=?1 ORDER BY at DESC, id DESC LIMIT ?2"
  ).bind(id, limit + 1).all();
  const page = rows.results || [];
  return json(200, { actions: page.slice(0, limit), truncated: page.length > limit, as_of: t });
}

export const routes = [
  ["POST", "/api/alerts/actions", postAction],
  ["GET", "/api/alerts/actions", listActions],
];
