// alerts routes — the fleet's incident rows (BH-1030.1 / BH-1068).
//
// The wire contract is worker/jobs/README.md `## Alerts table (2026-09-19)`.
// The fire/remind/suppress rule is the one bin/lib/alert-state.sh has been
// running on files since the beginning, moved to ISO time.
//
// Nothing on any box calls these until `flags/alerts-db` is set, which is the
// last step of the parent's rollout. Each route self-creates the table (the
// CREATED_TABLES.alerts mirror) so a deploy needs no d1 execute.
//
// Written against the route table BH-1195 left behind, not the flat chain: the
// handler bodies are the ones this slice was built with, moved under a
// `[method, matcher, handler]` row apiece. src/index.js holds the ordered table
// that decides which of these runs.

import { json } from "../lib/http.js";
import {
  ageSeconds, ensureTable, intOrNull, isoPlusSeconds, laneName, leaseWon,
  str, strictInt,
} from "../lib/core.js";

// Two boxes noticing the same outage in the same second is the NORMAL case
// here, not the edge, so every write below is a compare-and-swap whose WHERE
// carries the state the decision was made on, and a row is only ever reported
// as changed when its UPDATE said changes>0. No route waits, sleeps or polls.

export const ALERT_ID_RE = /^[A-Za-z0-9_.-]{1,120}$/;
const ALERT_FAMILY_RE = /^[0-9a-f]{12}$/;
// A claimant is `<lane>@<box>`, which laneName() rejects on the `@`, so the
// lanes that write claimed_by get their own class — same characters plus `@`.
export const ALERT_ACTOR_RE = /^[A-Za-z0-9._@-]{1,96}$/;
const ALERT_SEVERITIES = ["info", "warn", "critical"];
const ALERT_STATES = ["new", "quarantined", "triaged", "parked", "resolved"];
// No edge LEADS to `resolved`, and none leads out of it: a row is resolved
// only through POST /api/alerts/resolve, and reopened only by a note.
const ALERT_EDGES = {
  new: ["quarantined", "triaged", "parked"],
  quarantined: ["triaged", "parked", "new"],
  triaged: ["parked"],
  parked: [],
  resolved: [],
};
const ALERT_WINDOW_MIN_S = 60;
const ALERT_WINDOW_MAX_S = 604800;
const ALERT_WINDOW_DEFAULT_S = 21600;
// THE TWO KINDS OF NUMBER, AND WHY THEY ARE TREATED DIFFERENTLY. `reminder_s`,
// `close_s`, `severity`, `state` and `id` are business inputs a caller chose:
// out of range is a 400, never a clamp, because a silently adjusted threshold
// reads as the one that was asked for. `limit` is a page size — our capacity,
// not the caller's intent — so it clamps and `truncated` stays honest.
const ALERT_LIST_MAX = 500;
const ALERT_CLAIM_MAX = 200;
// D1 binds at most 100 parameters per statement (the /api/wakes/ack incident:
// Cloudflare 1101 on every ack once a loop drained 200 wakes a tick).
const ALERT_IDS_MAX = 99;
// ...which is why a candidate select that carries an id list AND its own
// predicates walks the ids in slices small enough to leave room for them.
const ALERT_IDS_SLICE = 90;
// Fallbacks for the two knobs an operator owns as `settings` rows
// (alert_flush_ttl_s, alert_claim_lease_s — seeded 2700/900 in schema.sql).
// THE ROW WINS whenever it parses as a positive int; these are what the routes
// use when it is missing, which is the only state a fresh D1 can be in.
const ALERT_FLUSH_TTL_S = 2700;
const ALERT_CLAIM_LEASE_S = 900;

export async function alertKnobs(env) {
  const knobs = { flush_ttl_s: ALERT_FLUSH_TTL_S, claim_lease_s: ALERT_CLAIM_LEASE_S };
  const rows = await env.DB.prepare(
    "SELECT key, value FROM settings WHERE key IN ('alert_flush_ttl_s','alert_claim_lease_s')"
  ).all();
  for (const r of rows.results || []) {
    const n = strictInt(r.value);
    // A knob nobody can parse is not a knob. Falling back is the documented
    // behaviour; taking NaN seconds as a TTL is an escalation that never fires.
    if (n === null || n <= 0) continue;
    if (r.key === "alert_flush_ttl_s") knobs.flush_ttl_s = n;
    if (r.key === "alert_claim_lease_s") knobs.claim_lease_s = n;
  }
  return knobs;
}

// undefined/absent is the documented default; anything else is the int or a
// 400 (null), never a clamp.
function alertWindow(v) {
  if (v === undefined || v === null || v === "") return ALERT_WINDOW_DEFAULT_S;
  const n = strictInt(v);
  if (n === null || n < ALERT_WINDOW_MIN_S || n > ALERT_WINDOW_MAX_S) return null;
  return n;
}

// An id list is bounded BY REFUSAL, not by a silent slice: a caller that sent
// 200 ids and got 99 resolved would read the 99 as all of them.
function alertIds(v) {
  if (!Array.isArray(v)) return null;
  const ids = [];
  for (const raw of v) {
    if (typeof raw !== "string" || !ALERT_ID_RE.test(raw)) return null;
    if (!ids.includes(raw)) ids.push(raw);
  }
  if (!ids.length || ids.length > ALERT_IDS_MAX) return null;
  return ids;
}

// ONE where-builder for claim, flush and list. Every VALUE is bound; the only
// strings built from code are the operators and the `IN (?k,...)` hole list,
// which is the /api/wakes precedent and never carries anything from a request.
function alertWhere(opts, t, knobs) {
  const where = [], binds = [];
  const hole = (v) => { binds.push(v); return `?${binds.length}`; };
  const lease = Number(knobs && knobs.claim_lease_s) > 0 ? knobs.claim_lease_s : ALERT_CLAIM_LEASE_S;
  if (opts.state) {
    const neg = String(opts.state).startsWith("!");
    where.push(`state${neg ? "<>" : "="}${hole(neg ? String(opts.state).slice(1) : String(opts.state))}`);
  }
  if (opts.family) where.push(`family=${hole(String(opts.family))}`);
  if (opts.box) where.push(`box=${hole(String(opts.box))}`);
  // Age is the INCIDENT's age (first_seen), the column idx_alerts_state was
  // built for: taking it from last_seen would let a chatty incident postpone
  // its own escalation forever.
  const age = Number(opts.older_than_s) > 0 ? Number(opts.older_than_s)
    : (Number(opts.min_age_s) > 0 ? Number(opts.min_age_s) : 0);
  if (age > 0) where.push(`first_seen<=${hole(isoPlusSeconds(t, -age))}`);
  if (Number(opts.since_s) > 0) where.push(`last_seen>=${hole(isoPlusSeconds(t, -opts.since_s))}`);
  if (Array.isArray(opts.ids) && opts.ids.length) {
    where.push(`id IN (${opts.ids.map((id) => hole(id)).join(",")})`);
  }
  if (opts.unclaimed) {
    where.push(`(claimed_by IS NULL OR claimed_at<=${hole(isoPlusSeconds(t, -lease))})`);
  }
  if (opts.claimed_by_prefix) {
    // substr, not LIKE: a prefix that arrived over the wire must not be able to
    // carry a `%`, and `medicine@a` must not answer for lane `medic`.
    const p = String(opts.claimed_by_prefix);
    where.push(`substr(claimed_by,1,${hole(p.length + 1)})=${hole(`${p}@`)}`);
  }
  if (Number(opts.claimed_since_s) > 0) {
    where.push(`claimed_at>=${hole(isoPlusSeconds(t, -opts.claimed_since_s))}`);
  }
  return { where: where.length ? where.join(" AND ") : "1=1", binds };
}

// THE DECISION, WITH NO SQL IN IT. `bin/lib/alert-state.sh` makes exactly this
// call against a JSON file; keeping it a pure function is what lets the rule be
// tested at its boundaries without a database, and what keeps the route below
// down to "read, decide, compare-and-swap".
//
// A NEW incident when: never seen, explicitly resolved, or quiet for longer
// than close_s. That last case is what stops a condition nobody ever resolves
// from being silenced forever.
export function alertDecision(row, body, t, knobs) {
  const sighting = {
    family: str(body.family, 64),
    box: str(body.box, 64),
    project: str(body.project, 64) || "",
    line: str(body.line, 2000) || "",
    severity: String(body.severity || ""),
    last_seen: t,
  };
  const quiet = row ? ageSeconds(row.last_seen, t) : null;
  if (!row || String(row.state) === "resolved" || quiet === null || quiet >= knobs.close_s) {
    return {
      ...sighting,
      decision: "fire",
      count: 1,
      first_seen: t,
      notified_at: t,
      // A producer may open an incident already quarantined; it may never walk
      // a LIVE row around the edge table from here (that is PATCH /state).
      state: body.state ? String(body.state) : "new",
      clearClaim: true,
    };
  }
  // A NULL notified_at has no age and is treated as due — the same as the
  // shell's notify=0, and the only honest reading of "nobody has been told".
  const notified = ageSeconds(row.notified_at, t);
  const due = notified === null || notified >= knobs.reminder_s;
  return {
    ...sighting,
    decision: due ? "remind" : "suppress",
    count: Number(row.count || 0) + 1,
    first_seen: row.first_seen,
    notified_at: due ? t : row.notified_at,
    state: String(row.state),
    clearClaim: false,
  };
}

// The claim half of both POST /api/alerts/claim and POST /api/alerts/flush: one
// CAS per candidate, and the row is RE-READ after the write so the caller is
// told what the table holds rather than what we hoped to write. A row that lost
// its race is simply absent from the answer — nothing waits for it.
async function alertClaimRows(env, candidates, by, state, t, knobs) {
  const claimed = [];
  const floor = isoPlusSeconds(t, -knobs.claim_lease_s);
  for (const cand of candidates) {
    const r = await env.DB.prepare(
      `UPDATE alerts SET claimed_by=?1, claimed_at=?2
       WHERE id=?3 AND state=?4 AND (claimed_by IS NULL OR claimed_at<=?5)`
    ).bind(by, t, cand.id, state, floor).run();
    if (!leaseWon(r)) continue;
    const row = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(cand.id).first();
    if (row) claimed.push(row);
  }
  return claimed;
}

export const routes = [
  [
    "POST", "/api/alerts/note",
    async ({ env, t, body }) => {
        await ensureTable(env, "alerts");
        const id = String(body.id === undefined || body.id === null ? "" : body.id);
        if (!ALERT_ID_RE.test(id)) return json(400, { error: "id must match ^[A-Za-z0-9_.-]{1,120}$" });
        const severity = String(body.severity || "");
        if (!ALERT_SEVERITIES.includes(severity)) {
          return json(400, { error: `severity must be one of ${ALERT_SEVERITIES.join("|")}` });
        }
        const family = body.family === undefined || body.family === null ? "" : String(body.family);
        if (family !== "" && !ALERT_FAMILY_RE.test(family)) {
          return json(400, { error: "family must match ^[0-9a-f]{12}$ or be empty" });
        }
        // Only the two OPENING states: a note may start an incident already
        // quarantined, it may never move a live one (that is PATCH /state).
        const state = body.state === undefined || body.state === null || body.state === "" ? "new" : String(body.state);
        if (state !== "new" && state !== "quarantined") return json(400, { error: "state must be new or quarantined" });
        const reminder_s = alertWindow(body.reminder_s);
        const close_s = alertWindow(body.close_s);
        if (reminder_s === null || close_s === null) {
          return json(400, { error: `reminder_s and close_s must be integers ${ALERT_WINDOW_MIN_S}..${ALERT_WINDOW_MAX_S}` });
        }
        const knobs = { reminder_s, close_s };

        // READ, DECIDE, COMPARE-AND-SWAP, at most three times. The CAS predicate
        // is the exact row the decision was made on, so a box that raced us in
        // between loses its write and re-decides on what the table now holds —
        // which is how two boxes emitting one family end as one row, count 2.
        // Three losses answer 409 rather than waiting: a queue here is an
        // afternoon spent in a retry loop.
        for (let attempt = 0; attempt < 3; attempt++) {
          const row = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
          const d = alertDecision(row, { ...body, state }, t, knobs);
          let r;
          if (!row) {
            r = await env.DB.prepare(
              `INSERT INTO alerts (id, family, box, project, line, severity, first_seen, last_seen,
                                   count, state, claimed_by, claimed_at, notified_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,NULL,NULL,?11)
               ON CONFLICT(id) DO NOTHING`
            ).bind(id, d.family, d.box, d.project, d.line, d.severity, d.first_seen, d.last_seen,
              d.count, d.state, d.notified_at).run();
          } else {
            r = await env.DB.prepare(
              `UPDATE alerts SET family=?2, box=?3, project=?4, line=?5, severity=?6,
                 first_seen=?7, last_seen=?8, count=?9, state=?10, notified_at=?11,
                 claimed_by=CASE WHEN ?12=1 THEN NULL ELSE claimed_by END,
                 claimed_at=CASE WHEN ?12=1 THEN NULL ELSE claimed_at END
               WHERE id=?1 AND count=?13 AND last_seen=?14 AND state=?15`
            ).bind(id, d.family, d.box, d.project, d.line, d.severity, d.first_seen, d.last_seen,
              d.count, d.state, d.notified_at, d.clearClaim ? 1 : 0,
              row.count, row.last_seen, row.state).run();
          }
          if (!leaseWon(r)) continue;
          const after = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
          // `count` rides at the top level as well as inside `alert` because
          // bin/jobs-client.sh's alert_note prints `.decision` and `.count`.
          return json(200, {
            alert: after, decision: d.decision,
            count: after ? Number(after.count) : d.count, as_of: t,
          });
        }
        return json(409, { error: "contended", id, as_of: t });
    },
  ],

  [
    "PATCH", "/api/alerts/state",
    async ({ env, t, body }) => {
        await ensureTable(env, "alerts");
        const id = String(body.id === undefined || body.id === null ? "" : body.id);
        if (!ALERT_ID_RE.test(id)) return json(400, { error: "id must match ^[A-Za-z0-9_.-]{1,120}$" });
        const next = String(body.state || "");
        if (!ALERT_STATES.includes(next)) return json(400, { error: `state must be one of ${ALERT_STATES.join("|")}` });
        // `actor` is validated and then dropped: the contract table has no column
        // for it, and writing it into claimed_by would make a lease field mean
        // two things. The client sends it; refusing it outright would be worse.
        const actor = body.actor === undefined || body.actor === null ? "" : String(body.actor);
        if (actor !== "" && !ALERT_ACTOR_RE.test(actor)) {
          return json(400, { error: "actor must match ^[A-Za-z0-9._@-]{1,96}$" });
        }
        const row = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
        if (!row) return json(404, { error: "no such alert" });
        const from = String(row.state);
        if (!(ALERT_EDGES[from] || []).includes(next)) {
          return json(409, { error: "disallowed edge", from, to: next, as_of: t });
        }
        // `quarantined -> new` is the flush delivery edge: the box PATCHes it
        // AFTER it has sent, which is why the stamp lands here and not in flush.
        const delivered = from === "quarantined" && next === "new" ? 1 : 0;
        const r = await env.DB.prepare(
          `UPDATE alerts SET state=?2, notified_at=CASE WHEN ?3=1 THEN ?4 ELSE notified_at END
           WHERE id=?1 AND state=?5`
        ).bind(id, next, delivered, t, from).run();
        if (!leaseWon(r)) return json(409, { error: "contended", id, as_of: t });
        const after = await env.DB.prepare("SELECT * FROM alerts WHERE id=?1").bind(id).first();
        return json(200, { alert: after, as_of: t });
    },
  ],

  [
    "POST", "/api/alerts/resolve",
    async ({ env, t, body }) => {
        await ensureTable(env, "alerts");
        const ids = alertIds(body.ids);
        if (!ids) {
          return json(400, { error: `ids must be 1..${ALERT_IDS_MAX} strings matching ^[A-Za-z0-9_.-]{1,120}$` });
        }
        const holes = ids.map((_, j) => `?${j + 1}`).join(",");
        // `resolved` counts the rows that MOVED — an unknown id and an already
        // resolved one both count zero, and neither is an error.
        // sql-ident-ok: holes is a ?N placeholder list built from the ids index
        const r = await env.DB.prepare(
          `UPDATE alerts SET state='resolved' WHERE state<>'resolved' AND id IN (${holes})`
        ).bind(...ids).run();
        return json(200, { resolved: (r.meta && r.meta.changes) || 0, as_of: t });
    },
  ],

  [
    "POST", "/api/alerts/claim",
    async ({ env, t, body }) => {
        await ensureTable(env, "alerts");
        const lane = String(body.lane || "");
        if (!ALERT_ACTOR_RE.test(lane)) return json(400, { error: "lane must match ^[A-Za-z0-9._@-]{1,96}$" });
        // THE CLAIMANT IS `<lane>@<box>`, composed here the way flush composes
        // its own below. It is the shape claimed_by is documented as, the shape
        // the 6h family brake matches on (`substr(claimed_by,1,n)='<lane>@'`),
        // and the shape the console renders. Filing the bare lane instead claims
        // the row, errors nowhere, and leaves GET /api/alerts/families?lane=
        // answering nothing forever. A box we cannot name is a 400, never a
        // claim quietly filed under the lane alone.
        const box = str(body.box, 64);
        if (box !== null && laneName(box) === "") return json(400, { error: "box must match ^[A-Za-z0-9._-]{1,64}$" });
        const by = box ? `${lane}@${box}` : lane;
        const state = String(body.state || "");
        if (state === "resolved" || !ALERT_STATES.includes(state)) {
          return json(400, { error: "state must be one of new|quarantined|triaged|parked" });
        }
        const minAge = intOrNull(body.min_age_s);
        if (body.min_age_s !== undefined && body.min_age_s !== null && body.min_age_s !== ""
            && (minAge === null || minAge < 0)) {
          return json(400, { error: "min_age_s must be a non-negative integer" });
        }
        let ids = null;
        if (body.ids !== undefined && body.ids !== null) {
          ids = alertIds(body.ids);
          if (!ids) return json(400, { error: `ids must be 1..${ALERT_IDS_MAX} strings matching ^[A-Za-z0-9_.-]{1,120}$` });
        }
        const asked = intOrNull(body.limit);
        const limit = asked === null ? 50 : Math.min(Math.max(1, asked), ALERT_CLAIM_MAX);
        const knobs = await alertKnobs(env);

        // One select per id slice (D1's bind ceiling, with room for the
        // predicates); no ids at all is one select.
        const slices = [];
        if (ids) for (let i = 0; i < ids.length; i += ALERT_IDS_SLICE) slices.push(ids.slice(i, i + ALERT_IDS_SLICE));
        else slices.push(null);
        const candidates = [];
        for (const slice of slices) {
          if (candidates.length >= limit) break;
          const w = alertWhere({ state, unclaimed: true, min_age_s: minAge || 0, ids: slice }, t, knobs);
          // sql-ident-ok: w.where comes from alertWhere(), every value a hole() bind; the LIMIT is a ?N index
          const rows = await env.DB.prepare(
            `SELECT * FROM alerts WHERE ${w.where} ORDER BY first_seen ASC LIMIT ?${w.binds.length + 1}`
          ).bind(...w.binds, limit - candidates.length).all();
          for (const row of rows.results || []) candidates.push(row);
        }
        const claimed = await alertClaimRows(env, candidates, by, state, t, knobs);
        return json(200, { alerts: claimed, truncated: candidates.length >= limit, as_of: t });
    },
  ],

  [
    "POST", "/api/alerts/flush",
    async ({ env, t, body }) => {
        await ensureTable(env, "alerts");
        // The box becomes half of `claimed_by`, so it is held to the same class
        // every other box name on the wire is (laneName), and a box we cannot
        // name is a 400 rather than a claim quietly filed as plain `flush`.
        const box = str(body.box, 64);
        if (box !== null && laneName(box) === "") return json(400, { error: "box must match ^[A-Za-z0-9._-]{1,64}$" });
        const by = box ? `flush@${box}` : "flush";
        const knobs = await alertKnobs(env);
        // Quarantined, older than the TTL, and nobody's. NOTHING IS SENT HERE and
        // notified_at is not stamped: the box delivers and then PATCHes
        // `quarantined -> new`, so "stamped delivered without a delivery" cannot
        // come from this route.
        const w = alertWhere(
          { state: "quarantined", unclaimed: true, older_than_s: knobs.flush_ttl_s }, t, knobs);
        // sql-ident-ok: w.where comes from alertWhere(), every value a hole() bind; the LIMIT is a ?N index
        const rows = await env.DB.prepare(
          `SELECT * FROM alerts WHERE ${w.where} ORDER BY first_seen ASC LIMIT ?${w.binds.length + 1}`
        ).bind(...w.binds, ALERT_CLAIM_MAX).all();
        const candidates = rows.results || [];
        const claimed = await alertClaimRows(env, candidates, by, "quarantined", t, knobs);
        return json(200, { alerts: claimed, truncated: candidates.length >= ALERT_CLAIM_MAX, as_of: t });
    },
  ],

  // GET /api/alerts — the list, and its `group=family` shape. The client's
  // own /api/alerts/families path is the same query with `lane` as the
  // claimed_by prefix, so it is a second path match rather than a second
  // implementation that could drift from it.
  [
    "GET", ["/api/alerts", "/api/alerts/families"],
    async ({ env, url, path, t }) => {
        await ensureTable(env, "alerts");
        const q = url.searchParams;
        const families = path === "/api/alerts/families";
        const prefix = families ? String(q.get("lane") || "") : String(q.get("claimed_by_prefix") || "");
        // A prefix-less family count answers a question nobody asked.
        if (families && !prefix) return json(400, { error: "lane is required" });
        const secs = (v) => { const n = intOrNull(v); return n !== null && n > 0 ? n : 0; };
        const knobs = { claim_lease_s: ALERT_CLAIM_LEASE_S };
        const w = alertWhere({
          state: q.get("state") || "",
          family: q.get("family") || "",
          box: q.get("box") || "",
          // The ticket writes older_than_s/since_s and the shipped client sends
          // older_than/since. Both are read, or the client's own flags would
          // filter nothing at all.
          older_than_s: secs(q.get("older_than_s") ?? q.get("older_than")),
          since_s: secs(q.get("since_s") ?? q.get("since")),
          claimed_by_prefix: prefix.slice(0, 96),
          claimed_since_s: secs(q.get("claimed_since_s")),
        }, t, knobs);

        if (families || q.get("group") === "family") {
          // sql-ident-ok: w.where comes from alertWhere(), every value a hole() bind; ALERT_LIST_MAX is a module number const
          const rows = await env.DB.prepare(
            `SELECT family, MAX(claimed_at) AS last_claimed_at, COUNT(*) AS n FROM alerts
             WHERE ${w.where} GROUP BY family ORDER BY last_claimed_at DESC LIMIT ${ALERT_LIST_MAX}`
          ).bind(...w.binds).all();
          return json(200, { families: rows.results || [], as_of: t });
        }
        const asked = intOrNull(q.get("limit"));
        const limit = asked === null || asked < 1 ? 200 : Math.min(asked, ALERT_LIST_MAX);
        // limit+1 rows, so `truncated` is measured rather than guessed.
        // sql-ident-ok: w.where comes from alertWhere(), every value a hole() bind; the LIMIT is a ?N index
        const rows = await env.DB.prepare(
          `SELECT * FROM alerts WHERE ${w.where} ORDER BY last_seen DESC, id ASC LIMIT ?${w.binds.length + 1}`
        ).bind(...w.binds, limit + 1).all();
        const page = rows.results || [];
        return json(200, { alerts: page.slice(0, limit), truncated: page.length > limit, as_of: t });
    },
  ],

];
